#requires -Version 7.4
<#
.SYNOPSIS
Entry script of the ScanDiagnostics action: scan the analyzer packages and publish the result as the living pull
request of an organization rulebook repository (or a direct commit).
.DESCRIPTION
1. Reads the settings and the secret name (ghTokenWorkflowSecretName).
2. Reads the quarantine policy (Get-QuarantinePolicy): no policy is one error annotation with the documented
   message, failure policy, before any request.
3. Unless -DryRun: the token guard (The <secret> secret is needed to scan diagnostics), the exchange and the mask.
4. Get-RulebookScanPlan: a NuGet, extraction or other failure is one error annotation (failure nuget, extract,
   error).
5. Mode nothing-new: one notice, result nothing-new, exit code 0.
6. A candidate that does not validate: one error annotation per finding, failure validation, nothing pushed.
7. -DryRun: the summary and the outputs (candidatePath included; the work folder is kept), result dry-run.
8. Publish-RulebookScan (or -PublishCommand): pull-request, pull-request-updated, direct-commit or no-changes.
9. The job summary (capped at -SummaryLimit) and GITHUB_OUTPUT: result, newIds, quarantined, changedDefaults,
   released, scannedVersions (<package>@<version>:<channel>, comma separated), pullRequestUrl, candidatePath,
   elapsedSeconds, failure (policy, token, nuget, extract, validation, push, pull-request, error; empty on success).
Returns { ExitCode, Result, Failure, Plan, Publish, Annotations, Summary, Outputs } and never calls exit, so tests run
it in-process; action.yaml exits with ExitCode. -PackageSource (a flat container folder), -RemoteUrl, -ApiUrl,
-WorkPath, -SummaryLimit, -Now and -PublishCommand are test seams; a -WorkPath the caller passes is left in place,
the temporary work folder the script names itself is removed at the end except after a dry run.
#>
[CmdletBinding()]
param(
    [string]$RepositoryRoot = '.',
    [AllowEmptyString()][string]$Token,
    [bool]$IncludePrerelease = $true,
    [switch]$DirectCommit,
    [switch]$DryRun,
    [AllowEmptyString()][string]$BaseBranch = $env:GITHUB_REF_NAME,
    [AllowEmptyString()][string]$Actor = $env:GITHUB_ACTOR,
    [AllowEmptyString()][string]$Repository = $env:GITHUB_REPOSITORY,
    [AllowEmptyString()][string]$RemoteUrl,
    [string]$ApiUrl = $(if ($env:GITHUB_API_URL) { $env:GITHUB_API_URL } else { 'https://api.github.com' }),
    [AllowEmptyString()][string]$PackageSource,
    [string]$WorkPath,
    [string]$SummaryPath = $env:GITHUB_STEP_SUMMARY,
    [string]$WorkspaceRoot = $env:GITHUB_WORKSPACE,
    [int]$SummaryLimit = 900KB,
    [System.DateTimeOffset]$Now = [System.DateTimeOffset]::UtcNow,
    # Test seam: runs instead of Publish-RulebookScan with the same parameters (the script re-imports the modules,
    # so a Pester mock of the function does not reach it).
    [scriptblock]$PublishCommand
)

Set-StrictMode -Version 3.0
$watch = [System.Diagnostics.Stopwatch]::StartNew()
$modules = Join-Path $PSScriptRoot '..' '..' 'modules'
Import-Module (Join-Path $modules 'Rulebook.Generate.psd1') -Force
Import-Module (Join-Path $modules 'Rulebook.GitHub.psd1') -Force
Import-Module (Join-Path $modules 'Rulebook.Update.psd1') -Force
Import-Module (Join-Path $modules 'Rulebook.Quarantine.psd1') -Force
Import-Module (Join-Path $modules 'Rulebook.Scan.psd1') -Force

$docsUrl = 'https://github.com/ALCops/rulebook/blob/main/docs/ghtokenworkflow.md'

# The helpers below are copies of CheckForUpdates.ps1 (a shared action helper module is #58, WP12).
function Format-AnnotationText {
    # Workflow command escaping: the message part escapes %, CR and LF; a property value also : and ,.
    param([AllowNull()][string]$Text, [switch]$Property)
    if ($null -eq $Text) { return '' }
    $escaped = $Text.Replace('%', '%25').Replace("`r", '%0D').Replace("`n", '%0A')
    if ($Property) { $escaped = $escaped.Replace(':', '%3A').Replace(',', '%2C') }
    return $escaped
}

function ConvertTo-SingleLine {
    # A message on one Markdown line (list item or paragraph); no table escaping.
    param([AllowNull()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    return $Text.Replace("`r", ' ').Replace("`n", ' ')
}

function Add-Annotation {
    param([ValidateSet('error', 'warning', 'notice')][string]$Command = 'error', [string]$File, [string]$Title = 'ScanDiagnostics', [Parameter(Mandatory)][string]$Message)
    $properties = "title=$(Format-AnnotationText $Title -Property)"
    if ($File) { $properties = "file=$(Format-AnnotationText $File -Property),$properties" }
    $line = "::$Command $properties::$(Format-AnnotationText $Message)"
    $script:annotations.Add($line)
    Write-Host $line
}

function Write-Text {
    param([AllowNull()][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrEmpty($Path)) { return }
    [System.IO.File]::AppendAllText($Path, $Text.Replace("`r`n", "`n"), [System.Text.UTF8Encoding]::new($false))
}

# [System.IO.File] resolves a relative path against the process directory, not the PowerShell location.
$resolvePath = { param($Path) if ([string]::IsNullOrEmpty($Path)) { $Path } else { $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path) } }
$SummaryPath = & $resolvePath $SummaryPath
$ownWork = [string]::IsNullOrEmpty($WorkPath)
if ($ownWork) {
    $tempRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [System.IO.Path]::GetTempPath() }
    $WorkPath = Join-Path $tempRoot ('rulebook-scan-' + [guid]::NewGuid().ToString('n').Substring(0, 8))
}
$WorkPath = & $resolvePath $WorkPath
$script:annotations = [System.Collections.Generic.List[string]]::new()
$script:failure = $null
function Add-Failure {
    param([Parameter(Mandatory)][string]$Kind)
    if ($null -eq $script:failure) { $script:failure = $Kind }
}

# Every token obtained by an exchange is masked before anything can print it.
$maskToken = { param([string]$Value) if (-not [string]::IsNullOrEmpty($Value)) { Write-Host "::add-mask::$Value" } }
$plan = $null
$publish = $null
$result = $null
$summaryMessage = $null
$failed = $false
$secretName = 'GHTOKENWORKFLOW'

try {
    # 1. Settings and the secret name.
    $root = (Resolve-Path -LiteralPath $RepositoryRoot -ErrorAction Stop).ProviderPath
    $workspace = if ([string]::IsNullOrEmpty($WorkspaceRoot)) { $root } else { (Resolve-Path -LiteralPath $WorkspaceRoot -ErrorAction Stop).ProviderPath }
    $separator = [System.IO.Path]::DirectorySeparatorChar
    $settingsFile = Join-Path $root '.github' 'Rulebook-Settings.json'
    if (-not (Test-Path -LiteralPath $settingsFile -PathType Leaf)) { throw "Settings missing: .github/Rulebook-Settings.json in $root" }
    try {
        $settings = Get-Content -LiteralPath $settingsFile -Raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    } catch {
        throw "Invalid JSON in .github/Rulebook-Settings.json: $($_.Exception.Message)"
    }
    $setting = { param([string[]]$Path) $value = $settings; foreach ($key in $Path) { if ($value -isnot [System.Collections.IDictionary] -or -not $value.Contains($key)) { return $null }; $value = $value[$key] }; return $value }
    $name = [string](& $setting 'ghTokenWorkflowSecretName')
    $nameValid = $name -cmatch '^[A-Za-z_][A-Za-z0-9_]*$' -and $name -inotmatch '^GITHUB_'
    if (-not [string]::IsNullOrEmpty($name) -and $nameValid) { $secretName = $name }

    # 2. The quarantine policy, before any request (D14: no default).
    try {
        $null = Get-QuarantinePolicy -Settings $settings
    } catch {
        Add-Failure 'policy'
        throw
    }

    # 3. The write token, unless this is a dry run.
    $access = $null
    if (-not $DryRun) {
        if (-not [string]::IsNullOrEmpty($name) -and -not $nameValid) {
            Add-Failure 'token'
            throw "ghTokenWorkflowSecretName '$name' in .github/Rulebook-Settings.json is not a valid secret name (letters, digits and underscores, not starting with a digit or GITHUB_). Read $docsUrl"
        }
        if ([string]::IsNullOrWhiteSpace($Token)) {
            Add-Failure 'token'
            throw "The $secretName secret is needed to scan diagnostics. Read $docsUrl"
        }
        if ([string]::IsNullOrEmpty($Repository)) { throw 'The scan needs the repository (GITHUB_REPOSITORY) as owner/name.' }
        if ([string]::IsNullOrEmpty($BaseBranch)) { throw 'The scan needs baseBranch.' }
        try {
            $access = Get-GitHubAccessToken -Token $Token -Repository $Repository -ApiUrl $ApiUrl
        } catch {
            Add-Failure 'token'
            throw "The $secretName secret could not be used: $($_.Exception.Message)"
        }
        if (-not [string]::IsNullOrEmpty($access.Token)) { & $maskToken $access.Token }
        Write-Host "Write token: $($access.Kind)"
    }

    # 4. The plan.
    $plan = Get-RulebookScanPlan -RepositoryRoot $root -IncludePrerelease $IncludePrerelease -Source $PackageSource -WorkPath (Join-Path $WorkPath 'plan') -Now $Now
    foreach ($channel in $plan.Channels) { Write-Host "NuGet: $($channel.PackageId) stable $($channel.Stable), prerelease $(if ($channel.Prerelease) { $channel.Prerelease } else { '-' })" }
    foreach ($item in $plan.Scanned) { Write-Host "Scanned $($item.PackageId) $($item.Version) ($($item.Channel)): $($item.Records.Records.Count) ids, $(@($item.Diff.NewIds).Count) new, $($item.Extraction.ElapsedSeconds) s in the child process on .NET $($item.Extraction.Runtime)" }
    foreach ($note in $plan.Notes) { Write-Host "Note: $note" }
    if ($plan.Failure) {
        Add-Failure $plan.Failure
        $what = switch ($plan.Failure) { 'nuget' { 'The NuGet packages could not be read' } 'extract' { 'The diagnostics could not be extracted' } default { 'The scan failed' } }
        throw "$what`: $($plan.FailureMessage)"
    }

    if ($plan.Mode -eq 'nothing-new') {
        # 5. Nothing new.
        $versions = @($plan.Channels | ForEach-Object { "$($_.PackageId) $($_.Stable) stable" + $(if ($_.Prerelease) { ", $($_.Prerelease) prerelease" } else { '' }) })
        $summaryMessage = "No new package version ($($versions -join '; ')); nothing to do"
        Add-Annotation -Command notice -Message $summaryMessage
        $result = 'nothing-new'
    } elseif (-not $plan.Valid) {
        # 6. The candidate does not validate.
        foreach ($finding in @($plan.Findings | Where-Object Severity -EQ 'error')) {
            $message = if ($finding.Id) { "$($finding.Id): $($finding.Message)" } else { $finding.Message }
            # C7 is a warning before the first scan and an error after it; name the remedy.
            if ($finding.Rule -ceq 'C7' -and $finding.Id) {
                $message += "; add $($finding.Id) to catalog/diagnostics.json or remove it from $($finding.File); the scan writes catalog/scan-state.json, which turns the C7 warning into an error"
            }
            $file = if ($finding.File) { [System.IO.Path]::GetRelativePath($workspace, (Join-Path $root $finding.File)).Replace($separator, '/') } else { $null }
            Add-Annotation -File $file -Title $finding.Rule -Message "The scanned rulebook would not validate: $message"
        }
        Add-Failure 'validation'
        $summaryMessage = 'The scanned rulebook does not validate; nothing was pushed. The findings come from the repository after the scan.'
        $failed = $true
    } elseif ($DryRun) {
        # 7. Dry run.
        $summaryMessage = "Dry run: $(Get-ScanTitle -Plan $plan); nothing was pushed"
        Add-Annotation -Command notice -Message $summaryMessage
        $result = 'dry-run'
    } else {
        # 8. Publish.
        if (-not $plan.HeadSha) { Add-Annotation -Command warning -Message 'base-move guard inactive: the checkout HEAD could not be read' }
        $labels = [string[]]@(& $setting 'commitOptions', 'pullRequestLabels' | Where-Object { $_ -is [string] -and $_ -ne '' })
        try {
            $publishParameters = @{
                Plan = $plan; RepositoryRoot = $root; Repository = $Repository; RemoteUrl = $RemoteUrl; Token = $access.Token; BaseBranch = $BaseBranch
                DirectCommit = [bool]$DirectCommit; Actor = $Actor; Labels = $labels; WorkPath = (Join-Path $WorkPath 'publish'); ApiUrl = $ApiUrl
            }
            $publish = if ($null -ne $PublishCommand) { & $PublishCommand @publishParameters } else { Publish-RulebookScan @publishParameters }
        } catch {
            $stage = [string]$_.Exception.Data['Stage']
            if ($stage -cnotin 'push', 'pull-request') { $stage = 'push' }
            Add-Failure $stage
            $what = if ($stage -eq 'pull-request') { 'Failed to create or update the scan pull request' } else { 'Failed to push the scan' }
            throw "$what. Make sure that the token in the secret $secretName is not expired and may write contents and pull requests of $Repository. Read $docsUrl (Error was: $($_.Exception.Message))"
        }
        $result = $publish.Result
        switch ($publish.Result) {
            'no-changes' { $summaryMessage = 'No changes to commit' }
            'direct-commit' { $summaryMessage = "Scan committed to $($publish.Branch) ($(Get-ShortSha $publish.Sha))" }
            'pull-request-updated' { $summaryMessage = "Pull request updated: $($publish.PullRequestUrl)" }
            default { $summaryMessage = "Pull request: $($publish.PullRequestUrl)" + $(if ($publish.Fallback) { ' (the direct commit was refused)' } else { '' }) }
        }
        Add-Annotation -Command notice -Message $summaryMessage
        if ($publish.PSObject.Properties['ClosedPullRequestUrl'] -and $publish.ClosedPullRequestUrl) { Add-Annotation -Command notice -Message "Pull request closed: $($publish.ClosedPullRequestUrl)" }
    }
} catch {
    Add-Annotation -Message $_.Exception.Message
    Add-Failure 'error'
    $summaryMessage = $_.Exception.Message
    $failed = $true
} finally {
    if ($ownWork -and -not ($DryRun -and $result -eq 'dry-run') -and (Test-Path -LiteralPath $WorkPath)) { Remove-Item -LiteralPath $WorkPath -Recurse -Force -ErrorAction SilentlyContinue }
}

# 9. Summary and outputs.
$summary = "## Diagnostic scan`n`n$(ConvertTo-SingleLine $summaryMessage)`n`n"
if ($null -ne $plan) {
    try {
        $summary = ConvertTo-ScanSummary -Plan $plan -Result $publish -Message $summaryMessage
    } catch {
        Write-Host "The summary could not be written in full: $($_.Exception.Message)"
    }
}
$summary = $summary.Replace("`r`n", "`n")
# The runner caps a step summary at 1 MiB; stay well below it (-SummaryLimit, 900 KiB).
$where = if ($null -ne $publish -and $publish.PSObject.Properties['Body'] -and $publish.Body) { 'the pull request body' } else { 'the job log' }
$summary = Limit-SummaryText -Text $summary -MaxBytes $SummaryLimit -Footer "The summary was cut at $([math]::Floor($SummaryLimit / 1KB)) KiB; the full lists are in $where."
Write-Text -Path $SummaryPath -Text $summary
$counts = if ($null -ne $plan -and $null -ne $plan.Counts) { $plan.Counts } else { $null }
$outputs = [ordered]@{
    result          = $(if ($failed) { '' } elseif ($result) { $result } else { '' })
    newIds          = $(if ($counts) { $counts.NewIds } else { 0 })
    quarantined     = $(if ($counts) { $counts.Quarantined } else { 0 })
    changedDefaults = $(if ($counts) { $counts.ChangedDefaults } else { 0 })
    released        = $(if ($counts) { $counts.Released } else { 0 })
    scannedVersions = $(if ($null -ne $plan) { @($plan.Scanned | ForEach-Object { "$($_.PackageId)@$($_.Version):$($_.Channel)" }) -join ',' } else { '' })
    pullRequestUrl  = $(if ($null -ne $publish -and $publish.PullRequestUrl) { $publish.PullRequestUrl } elseif ($null -ne $publish -and $publish.PSObject.Properties['ClosedPullRequestUrl'] -and $publish.ClosedPullRequestUrl) { $publish.ClosedPullRequestUrl } else { '' })
    candidatePath   = $(if ($null -ne $plan -and $plan.CandidatePath -and $result -eq 'dry-run') { $plan.CandidatePath } else { '' })
    elapsedSeconds  = [math]::Round($watch.Elapsed.TotalSeconds, 1).ToString([System.Globalization.CultureInfo]::InvariantCulture)
    failure         = $script:failure
}
if ($env:GITHUB_OUTPUT) {
    Write-Text -Path $env:GITHUB_OUTPUT -Text ((@($outputs.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "`n") + "`n")
}
[pscustomobject]@{
    ExitCode    = $(if ($failed) { 1 } else { 0 })
    Result      = $outputs.result
    Failure     = $script:failure
    Plan        = $plan
    Publish     = $publish
    Annotations = $script:annotations.ToArray()
    Summary     = $summary
    Outputs     = $outputs
}
