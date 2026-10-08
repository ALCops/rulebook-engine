#requires -Version 7.4
<#
.SYNOPSIS
Entry script of the Validate action: checks C1 to C16, GitHub annotations, the job summary with the effective diff.
.DESCRIPTION
Runs Test-Rulebook on -RepositoryRoot, prints one annotation per finding (file paths relative to -WorkspaceRoot),
appends a Markdown summary to -SummaryPath, writes the errors and warnings outputs to GITHUB_OUTPUT and returns
{ ExitCode, Findings, Diff, Summary, Annotations, DiffRef, UpdateCheck }. ExitCode is 1 when there are errors, or
warnings with -FailOnWarning. The script never calls exit, so tests run it in-process; action.yaml exits with ExitCode.

-CheckForUpdates 'true' or 'false' (case-insensitive; $true and $false work too) runs or skips the template update
check; '' (the default) follows update.check of the settings, true when absent. Omitting -CheckForUpdates follows
update.check of the settings; pass 'false' to skip the check. Any other value turns the check off and says so in the
log. The check runs in check mode (Rulebook.Update): the template of the settings at the head of its branch,
downloaded with GITHUB_TOKEN (never the write token), or -TemplatePath and -InstalledTemplatePath as local folders.
One notice (no updates, templateSha not recorded) or warning (updates available, check skipped) and the section
'## Template update check' in the summary. Neither counts towards warnings= or -FailOnWarning, and the check never
fails the step. UpdateCheck is { Status (none, sha-only, available, skipped), Reason, Plan }. The check works
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
    [AllowEmptyString()][string]$CheckForUpdates = '',
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
Import-Module (Join-Path $modules 'Rulebook.Action.psd1') -Force

function Test-GitRef {
    param([string]$Root, [string]$Ref)
    if ([string]::IsNullOrEmpty($Ref) -or $Ref.StartsWith('-')) { return $false }
    $null = & git -C $Root rev-parse --verify --quiet "$Ref^{commit}" 2>&1
    return $LASTEXITCODE -eq 0
}

# Test-Rulebook writes -Json with [System.IO.File], which resolves a relative path against the process directory.
$JsonPath = Resolve-ActionPath $JsonPath
$ctx = New-ActionContext -Title 'Validate'
$root = (Resolve-Path -LiteralPath $RepositoryRoot).ProviderPath
$workspace = if ([string]::IsNullOrEmpty($WorkspaceRoot)) { $root } else { (Resolve-Path -LiteralPath $WorkspaceRoot).ProviderPath }
$separator = [System.IO.Path]::DirectorySeparatorChar
$relativeRoot = [System.IO.Path]::GetRelativePath($workspace, $root).Replace($separator, '/')

# The update check: an explicit -CheckForUpdates wins; '' follows update.check of the settings, read leniently (a
# missing or unreadable settings file, or a value that is not a boolean, leaves the check on; the checks report them).
$runUpdateCheck = $true
if (-not [string]::IsNullOrWhiteSpace($CheckForUpdates)) {
    $runUpdateCheck = $CheckForUpdates.Trim() -ieq 'true'
    if ($CheckForUpdates.Trim() -inotin 'true', 'false') { Write-Host "checkForUpdates '$CheckForUpdates' is not 'true' or 'false'; the update check is off" }
} else {
    try {
        $settingsForCheck = Get-Content -LiteralPath (Join-Path $root '.github' 'Rulebook-Settings.json') -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        if ($settingsForCheck -is [System.Collections.IDictionary] -and $settingsForCheck['update'] -is [System.Collections.IDictionary] -and $settingsForCheck['update']['check'] -is [bool]) {
            $runUpdateCheck = $settingsForCheck['update']['check']
        }
    } catch {
        Write-Verbose "Settings not readable for update.check: $($_.Exception.Message)"
    }
    if (-not $runUpdateCheck) { Write-Host 'Update check off (update.check is false)' }
}

# 1. Checks
$testParameters = @{ RepositoryRoot = $root }
if ($JsonPath) { $testParameters.Json = $JsonPath }
$findings = @(Test-Rulebook @testParameters)
$errorCount = @($findings | Where-Object Severity -EQ 'error').Count
$warningCount = @($findings | Where-Object Severity -EQ 'warning').Count

# 2. Annotations
foreach ($finding in $findings) {
    $command = if ($finding.Severity -eq 'error') { 'error' } else { 'warning' }
    $message = if ($finding.Id) { "$($finding.Id): $($finding.Message)" } else { $finding.Message }
    $path = if ($finding.File) { [System.IO.Path]::GetRelativePath($workspace, (Join-Path $root $finding.File)).Replace($separator, '/') } else { $null }
    Add-Annotation -Context $ctx -Command $command -File $path -Title $finding.Rule -Message $message
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
    # Endpoints in the order of the diff (settings order); Group-Object would sort them by name.
    $groups = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::Ordinal)
    foreach ($row in $diff) {
        if (-not $groups.Contains([string]$row.Endpoint)) { $groups[[string]$row.Endpoint] = [System.Collections.Generic.List[object]]::new() }
        $groups[[string]$row.Endpoint].Add($row)
    }
    foreach ($group in @($groups.Values | ForEach-Object { [pscustomobject]@{ Group = $_.ToArray() } })) {
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
# The limit in KiB for the footers of both summary parts.
$limitLabel = [math]::Round($summaryLimit / 1KB)
$summaryText = Limit-SummaryText -Text $summaryText -MaxBytes $summaryLimit -Footer "The summary was truncated at $limitLabel KiB; the -JsonPath file and the annotations above have the findings."
Write-Text -Path $SummaryPath -Text $summaryText

# 5. Update check (WP07): check mode only, never counted, never failing.
$updateCheck = $null
if ($runUpdateCheck) {
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
            $work = Resolve-ActionPath $UpdateWorkPath
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
    Add-Annotation -Context $ctx -Command $command -Title 'Update check' -Message $message
    $updateSummary = if ($null -ne $updateCheck.Plan) { ConvertTo-UpdateSummary -Plan $updateCheck.Plan -Mode check -Message $message } else { "## Template update check`n`n$message`n`n" }
    $updateSummary = $updateSummary.Replace("`r`n", "`n")
    # Within what the validation summary leaves of the cap: cut at a line boundary, never dropped.
    $budget = $summaryLimit - [System.Text.Encoding]::UTF8.GetByteCount($summaryText)
    $footer = "The update check summary was cut at $limitLabel KiB; the full lists are in the job log."
    $updateSummary = Limit-SummaryText -Text $updateSummary -MaxBytes ([math]::Max(0, $budget)) -Footer $footer
    $summaryText += $updateSummary
    Write-Text -Path $SummaryPath -Text $updateSummary
}

# 6. Outputs
Write-ActionOutput -Outputs ([ordered]@{ errors = $errorCount; warnings = $warningCount })

$exitCode = if ($errorCount -gt 0 -or ($FailOnWarning -and $warningCount -gt 0)) { 1 } else { 0 }
[pscustomobject]@{
    ExitCode    = $exitCode
    Findings    = $findings
    Diff        = $diff
    Summary     = $summaryText
    Annotations = $ctx.Annotations.ToArray()
    DiffRef     = $DiffRef
    UpdateCheck = $updateCheck
}
