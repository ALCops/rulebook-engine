#requires -Version 7.4
<#
.SYNOPSIS
Entry script of the Validate action: checks C1 to C15, GitHub annotations, the job summary with the effective diff.
.DESCRIPTION
Runs Test-Rulebook on -RepositoryRoot, prints one annotation per finding (file paths relative to -WorkspaceRoot),
appends a Markdown summary to -SummaryPath, writes the errors and warnings outputs to GITHUB_OUTPUT and returns
{ ExitCode, Findings, Diff, Summary, Annotations, DiffRef, UpdateCheck }. ExitCode is 1 when there are errors, or
warnings with -FailOnWarning. The script never calls exit, so tests run it in-process; action.yaml exits with ExitCode.

-CheckForUpdates runs the template update check in check mode (Rulebook.Update): the template of the settings at the
head of its branch, downloaded with GITHUB_TOKEN (never the write token), or -TemplatePath and -InstalledTemplatePath
as local folders. One notice (no updates, templateSha not recorded) or warning (updates available, check skipped) and
the section '## Template update check' in the summary. Neither counts towards warnings= or -FailOnWarning, and the
check never fails the step. UpdateCheck is { Status (none, sha-only, available, skipped), Reason, Plan }. The check works
in -UpdateWorkPath when given (left in place afterwards), else in a temporary folder it removes.

The effective diff compares against -DiffRef. Without -DiffRef it is origin/<GITHUB_BASE_REF> on a pull_request or
pull_request_target event (fetched when absent); on a push, the commit before the push from the event payload
(GITHUB_EVENT_PATH, 'before'), else HEAD~1 (fetched or deepened when absent). -DiffRef '' disables it. Any other
event, a ref that does not resolve, or a diff that fails is a note in the summary, never a failure.
#>
[CmdletBinding()]
param(
    [string]$RepositoryRoot = '.',
    [switch]$FailOnWarning,
    [switch]$CheckForUpdates,
    [AllowEmptyString()][string]$DiffRef,
    [string]$SummaryPath = $env:GITHUB_STEP_SUMMARY,
    [string]$JsonPath,
    [string]$WorkspaceRoot = $env:GITHUB_WORKSPACE,
    [AllowEmptyString()][string]$TemplatePath,
    [AllowEmptyString()][string]$InstalledTemplatePath,
    [string]$ApiUrl = $(if ($env:GITHUB_API_URL) { $env:GITHUB_API_URL } else { 'https://api.github.com' }),
    [string]$UpdateWorkPath,
    [int]$SummaryLimit = 900KB
)

Set-StrictMode -Version 3.0
$modules = Join-Path $PSScriptRoot '..' '..' 'modules'
Import-Module (Join-Path $modules 'Rulebook.Generate.psd1') -Force
Import-Module (Join-Path $modules 'Rulebook.Validate.psd1') -Force

function Format-AnnotationText {
    # Workflow command escaping: the message part escapes %, CR and LF; a property value also : and ,.
    param([AllowNull()][string]$Text, [switch]$Property)
    if ($null -eq $Text) { return '' }
    $escaped = $Text.Replace('%', '%25').Replace("`r", '%0D').Replace("`n", '%0A')
    if ($Property) { $escaped = $escaped.Replace(':', '%3A').Replace(',', '%2C') }
    return $escaped
}

function Format-TableCell {
    param([AllowNull()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    return $Text.Replace('|', '\|').Replace("`r", ' ').Replace("`n", ' ')
}

function Test-GitRef {
    param([string]$Root, [string]$Ref)
    if ([string]::IsNullOrEmpty($Ref) -or $Ref.StartsWith('-')) { return $false }
    $null = & git -C $Root rev-parse --verify --quiet "$Ref^{commit}" 2>&1
    return $LASTEXITCODE -eq 0
}

# [System.IO.File] resolves a relative path against the process directory, not the PowerShell location.
$resolvePath = { param($Path) if ([string]::IsNullOrEmpty($Path)) { $Path } else { $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path) } }
$SummaryPath = & $resolvePath $SummaryPath
$JsonPath = & $resolvePath $JsonPath
$root = (Resolve-Path -LiteralPath $RepositoryRoot).ProviderPath
$workspace = if ([string]::IsNullOrEmpty($WorkspaceRoot)) { $root } else { (Resolve-Path -LiteralPath $WorkspaceRoot).ProviderPath }
$separator = [System.IO.Path]::DirectorySeparatorChar
$relativeRoot = [System.IO.Path]::GetRelativePath($workspace, $root).Replace($separator, '/')

# 1. Checks
$testParameters = @{ RepositoryRoot = $root }
if ($JsonPath) { $testParameters.Json = $JsonPath }
$findings = @(Test-Rulebook @testParameters)
$errorCount = @($findings | Where-Object Severity -EQ 'error').Count
$warningCount = @($findings | Where-Object Severity -EQ 'warning').Count

# 2. Annotations
$annotations = [System.Collections.Generic.List[string]]::new()
foreach ($finding in $findings) {
    $command = if ($finding.Severity -eq 'error') { 'error' } else { 'warning' }
    $message = if ($finding.Id) { "$($finding.Id): $($finding.Message)" } else { $finding.Message }
    $properties = "title=$(Format-AnnotationText $finding.Rule -Property)"
    if ($finding.File) {
        $path = [System.IO.Path]::GetRelativePath($workspace, (Join-Path $root $finding.File)).Replace($separator, '/')
        $properties = "file=$(Format-AnnotationText $path -Property),$properties"
    }
    $line = "::$command $properties::$(Format-AnnotationText $message)"
    $annotations.Add($line)
    Write-Host $line
}
Write-Host ('Rulebook validation: {0} error(s), {1} warning(s) in {2}' -f $errorCount, $warningCount, $relativeRoot)

# 3. Effective diff
$eventName = $env:GITHUB_EVENT_NAME
$isPullRequest = $eventName -cin 'pull_request', 'pull_request_target'
$derived = -not $PSBoundParameters.ContainsKey('DiffRef')
if ($derived) {
    $DiffRef = ''
    if ($isPullRequest -and $env:GITHUB_BASE_REF) {
        $DiffRef = "origin/$($env:GITHUB_BASE_REF)"
    } elseif ($eventName -ceq 'push') {
        $DiffRef = 'HEAD~1'
        # The commit before the push covers a push of several commits; all zeros means a new branch.
        if ($env:GITHUB_EVENT_PATH -and (Test-Path -LiteralPath $env:GITHUB_EVENT_PATH -PathType Leaf)) {
            try {
                $before = [string](Get-Content -LiteralPath $env:GITHUB_EVENT_PATH -Raw | ConvertFrom-Json -AsHashtable)['before']
                if ($before -match '^[0-9a-f]{40,64}$' -and $before -notmatch '^0+$') { $DiffRef = $before }
            } catch {
                Write-Verbose "Event payload not readable: $($_.Exception.Message)"
            }
        }
    }
}
$diff = @()
$diffNote = $null
if ([string]::IsNullOrEmpty($DiffRef)) {
    $diffNote = 'No diff: no reference to compare against (pass -DiffRef, or run on a pull_request or push event).'
} elseif ($null -eq (Get-Command git -ErrorAction SilentlyContinue)) {
    $diffNote = "No diff: git is not available to read $DiffRef."
} else {
    if (-not (Test-GitRef $root $DiffRef) -and $derived) {
        if ($isPullRequest -and $env:GITHUB_BASE_REF) {
            $base = $env:GITHUB_BASE_REF
            $null = & git -C $root fetch --no-tags --depth=1 origin "+refs/heads/$($base):refs/remotes/origin/$($base)" 2>&1
        } elseif ($eventName -ceq 'push' -and $DiffRef -ne 'HEAD~1') {
            $null = & git -C $root fetch --no-tags --depth=1 origin $DiffRef 2>&1
        } elseif ($eventName -ceq 'push') {
            $null = & git -C $root fetch --no-tags --deepen=1 2>&1
        }
    }
    if (-not (Test-GitRef $root $DiffRef)) {
        $diffNote = "No diff: $DiffRef does not resolve in this checkout."
    } else {
        try {
            $diff = @(Compare-RulebookEndpoints -RepositoryRoot $root -Ref $DiffRef)
        } catch {
            $diffNote = "No diff: the comparison with $DiffRef failed: $($_.Exception.Message)"
        }
    }
}

# 4. Summary
$summary = [System.Text.StringBuilder]::new()
[void]$summary.AppendLine('## Rulebook validation').AppendLine()
[void]$summary.AppendLine(('**{0} error(s), {1} warning(s)** in `{2}`.' -f $errorCount, $warningCount, $relativeRoot)).AppendLine()
if ($findings.Count -eq 0) {
    [void]$summary.AppendLine('No findings.').AppendLine()
} else {
    [void]$summary.AppendLine('The runner shows at most 10 error and 10 warning annotations per step; this table is the full list.').AppendLine()
    [void]$summary.AppendLine('| Rule | Severity | File | Id | Message |').AppendLine('|---|---|---|---|---|')
    foreach ($finding in $findings) {
        $file = if ($finding.File) { '`' + $finding.File + '`' } else { '' }
        [void]$summary.AppendLine(('| {0} | {1} | {2} | {3} | {4} |' -f $finding.Rule, $finding.Severity, $file, (Format-TableCell $finding.Id), (Format-TableCell $finding.Message)))
    }
    [void]$summary.AppendLine()
}
$diffTitle = if ([string]::IsNullOrEmpty($DiffRef)) { '## Effective diff' } else { "## Effective diff against $DiffRef" }
[void]$summary.AppendLine($diffTitle).AppendLine()
if ($null -ne $diffNote) {
    [void]$summary.AppendLine($diffNote).AppendLine()
} elseif ($diff.Count -eq 0) {
    [void]$summary.AppendLine('No effective change.').AppendLine()
} else {
    foreach ($group in ($diff | Group-Object Endpoint)) {
        $first = $group.Group[0]
        [void]$summary.AppendLine(('### `{0}` (`{1}`)' -f $first.Endpoint, $first.File)).AppendLine()
        [void]$summary.AppendLine('| Id | Before | After | Decided by |').AppendLine('|---|---|---|---|')
        foreach ($row in $group.Group) {
            $before = if ($row.Before) { $row.Before } elseif ($row.BeforeSource) { '(unknown default)' } else { '(absent)' }
            $after = if ($row.After) { $row.After } elseif ($row.AfterSource) { '(unknown default)' } else { '(absent)' }
            $decidedBy = if (-not $row.AfterSource) { '' } elseif ($row.AfterDetail) { '{0}, "{1}"' -f $row.AfterSource, $row.AfterDetail } else { $row.AfterSource }
            if ($row.Change -eq 'listing') {
                $decidedBy += $(if ($row.ListedAfter) { ' (the analyzer default moved; now listed)' } else { ' (now the analyzer default; no longer listed)' })
            }
            [void]$summary.AppendLine(('| {0} | {1} | {2} | {3} |' -f (Format-TableCell $row.Id), $before, $after, (Format-TableCell $decidedBy)))
        }
        [void]$summary.AppendLine()
    }
}
$summaryText = $summary.ToString().Replace("`r`n", "`n")
# The runner caps a step summary at 1 MiB; stay well below it.
$summaryLimit = $SummaryLimit
if ([System.Text.Encoding]::UTF8.GetByteCount($summaryText) -gt $summaryLimit) {
    $cut = [math]::Min($summaryText.Length, $summaryLimit)
    while ([System.Text.Encoding]::UTF8.GetByteCount($summaryText.Substring(0, $cut)) -gt $summaryLimit) { $cut = [int]($cut * 0.9) }
    $summaryText = $summaryText.Substring(0, $cut) + "`n`n_The summary was truncated at 900 KiB; the -JsonPath file and the annotations above have the findings._`n"
}
if ($SummaryPath) { [System.IO.File]::AppendAllText($SummaryPath, $summaryText, [System.Text.UTF8Encoding]::new($false)) }

# 5. Update check (WP07): check mode only, never counted, never failing.
$updateCheck = $null
if ($CheckForUpdates) {
    $updateCheck = [pscustomobject]@{ Status = 'skipped'; Reason = $null; Plan = $null }
    $command = 'warning'
    $message = $null
    # Only a work folder this script names itself is removed afterwards; a caller's -UpdateWorkPath is left alone.
    $work = $null
    $ownWork = $false
    try {
        Import-Module (Join-Path $modules 'Rulebook.GitHub.psd1') -Force
        Import-Module (Join-Path $modules 'Rulebook.Update.psd1') -Force
        if ($UpdateWorkPath) {
            $work = & $resolvePath $UpdateWorkPath
        } else {
            $work = Join-Path $(if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [System.IO.Path]::GetTempPath() }) ('rulebook-update-check-' + [guid]::NewGuid().ToString('n').Substring(0, 8))
            $ownWork = $true
        }
        $settingsFile = Join-Path $root '.github' 'Rulebook-Settings.json'
        if (-not (Test-Path -LiteralPath $settingsFile -PathType Leaf)) { throw 'Settings missing: .github/Rulebook-Settings.json' }
        $settings = Get-Content -LiteralPath $settingsFile -Raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        $value = { param([string[]]$Path) $item = $settings; foreach ($key in $Path) { if ($item -isnot [System.Collections.IDictionary] -or -not $item.Contains($key)) { return $null }; $item = $item[$key] }; return $item }
        $templateUrl = [string](& $value 'templateUrl')
        if ($TemplatePath) {
            $template = Get-RulebookTemplate -TemplatePath $TemplatePath -InstalledTemplatePath $InstalledTemplatePath -TemplateUrl $templateUrl
        } else {
            $template = Get-RulebookTemplate -TemplateUrl $templateUrl -GitHubToken $env:GITHUB_TOKEN -DownloadLatest -InstalledSha ([string](& $value 'templateSha')) -WorkPath $work -ApiUrl $ApiUrl
        }
        $plan = Get-RulebookUpdatePlan -RepositoryRoot $root -Template $template -WorkPath $work
        $status = Get-RulebookUpdateStatus -Plan $plan
        $updateCheck = [pscustomobject]@{ Status = $status.Status; Reason = $(if ($status.Status -eq 'skipped') { $status.Message }); Plan = $plan }
        $command = $status.Command
        $message = $status.Message
    } catch {
        $message = "update check skipped: $($_.Exception.Message)"
        $updateCheck.Reason = $message
    } finally {
        if ($ownWork -and (Test-Path -LiteralPath $work)) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
    }
    $line = "::$command title=Update check::$(Format-AnnotationText $message)"
    $annotations.Add($line)
    Write-Host $line
    $updateSummary = if ($null -ne $updateCheck.Plan) { ConvertTo-UpdateSummary -Plan $updateCheck.Plan -Mode check -Message $message } else { "## Template update check`n`n$message`n`n" }
    $updateSummary = $updateSummary.Replace("`r`n", "`n")
    # Within what the validation summary leaves of the cap: cut at a line boundary, never dropped.
    $budget = $summaryLimit - [System.Text.Encoding]::UTF8.GetByteCount($summaryText)
    $footer = "The update check summary was cut at $([math]::Floor($summaryLimit / 1KB)) KiB; the full lists are in the job log."
    if (Get-Command Limit-SummaryText -ErrorAction SilentlyContinue) {
        $updateSummary = Limit-SummaryText -Text $updateSummary -MaxBytes ([math]::Max(0, $budget)) -Footer $footer
    } elseif ([System.Text.Encoding]::UTF8.GetByteCount($updateSummary) -gt $budget) {
        $updateSummary = "## Template update check`n`n_$($footer)_`n"
    }
    $summaryText += $updateSummary
    if ($SummaryPath) { [System.IO.File]::AppendAllText($SummaryPath, $updateSummary, [System.Text.UTF8Encoding]::new($false)) }
}

# 6. Outputs
if ($env:GITHUB_OUTPUT) {
    [System.IO.File]::AppendAllText($env:GITHUB_OUTPUT, "errors=$errorCount`nwarnings=$warningCount`n", [System.Text.UTF8Encoding]::new($false))
}

$exitCode = if ($errorCount -gt 0 -or ($FailOnWarning -and $warningCount -gt 0)) { 1 } else { 0 }
[pscustomobject]@{
    ExitCode    = $exitCode
    Findings    = $findings
    Diff        = $diff
    Summary     = $summaryText
    Annotations = $annotations.ToArray()
    DiffRef     = $DiffRef
    UpdateCheck = $updateCheck
}
