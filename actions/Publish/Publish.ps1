#requires -Version 7.4
<#
.SYNOPSIS
Entry script of the Publish action: stage the published files (-Phase Stage) or check the deployed URLs (-Phase Check).
.DESCRIPTION
-Phase Stage reads the settings, resolves the target (only 'pages' is implemented) and the base URL, prints a notice
when site.enabled is set (the dashboard arrives with WP14), runs the GitHub Pages preflight when -Deploy is set,
stages the endpoints, the rendered skeletons and index.html into -StagingPath (New-RulebookPublishStage, which
refuses stale endpoints: Publish is a gate and never commits, D42), writes the manifest to -ManifestPath, the URL
list to the job summary and the outputs stagingPath, manifestPath and pageUrl to GITHUB_OUTPUT.

-Phase Check reads -ManifestPath and runs Test-RulebookEndpoints: one error annotation per URL that is missing or
differs after -WindowSeconds, and the result table in the job summary.

Both phases return { ExitCode, Phase, Annotations, Summary, ... } and never call exit, so tests run the script
in-process; action.yaml exits with ExitCode.
#>
[CmdletBinding()]
param(
    [ValidateSet('Stage', 'Check')][string]$Phase = 'Stage',
    [string]$RepositoryRoot = '.',
    [AllowEmptyString()][string]$BaseUrl,
    [AllowEmptyString()][string]$Target,
    [switch]$Deploy,
    [string]$StagingPath,
    [string]$ManifestPath,
    [int]$WindowSeconds = 660,
    [int]$IntervalSeconds = 30,
    [int]$TimeoutSeconds = 15,
    [string]$Repository = $env:GITHUB_REPOSITORY,
    [string]$ApiUrl = $(if ($env:GITHUB_API_URL) { $env:GITHUB_API_URL } else { 'https://api.github.com' }),
    [string]$Token = $env:INPUT_TOKEN,
    [string]$SummaryPath = $env:GITHUB_STEP_SUMMARY,
    [string]$WorkspaceRoot = $env:GITHUB_WORKSPACE
)

Set-StrictMode -Version 3.0
$modules = Join-Path $PSScriptRoot '..' '..' 'modules'
Import-Module (Join-Path $modules 'Rulebook.Generate.psd1') -Force
Import-Module (Join-Path $modules 'Rulebook.Publish.psd1') -Force

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

function Add-Annotation {
    param([ValidateSet('error', 'warning', 'notice')][string]$Command = 'error', [string]$File, [Parameter(Mandatory)][string]$Message)
    $properties = 'title=Publish'
    if ($File) { $properties = "file=$(Format-AnnotationText $File -Property),$properties" }
    $line = "::$Command $properties::$(Format-AnnotationText $Message)"
    $script:annotations.Add($line)
    if ($Command -eq 'error') { $script:errorMessages.Add($Message) }
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
$tempRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [System.IO.Path]::GetTempPath() }
if ([string]::IsNullOrEmpty($StagingPath)) { $StagingPath = Join-Path $tempRoot 'rulebook-publish' }
# The manifest sits next to the staging folder, never inside it, so it is not published.
if ([string]::IsNullOrEmpty($ManifestPath)) { $ManifestPath = Join-Path $tempRoot 'rulebook-publish.manifest.json' }
$StagingPath = & $resolvePath $StagingPath
$ManifestPath = & $resolvePath $ManifestPath
$script:annotations = [System.Collections.Generic.List[string]]::new()
$script:errorMessages = [System.Collections.Generic.List[string]]::new()
$summary = [System.Text.StringBuilder]::new()

if ($Phase -eq 'Stage') {
    $root = (Resolve-Path -LiteralPath $RepositoryRoot).ProviderPath
    $workspace = if ([string]::IsNullOrEmpty($WorkspaceRoot)) { $root } else { (Resolve-Path -LiteralPath $WorkspaceRoot).ProviderPath }
    $separator = [System.IO.Path]::DirectorySeparatorChar
    $settingsFile = [System.IO.Path]::GetRelativePath($workspace, (Join-Path $root '.github' 'Rulebook-Settings.json')).Replace($separator, '/')
    $manifest = @()
    $resolvedBaseUrl = $null
    $preflight = $null
    $failed = $false
    [void]$summary.AppendLine('## Rulebook publish').AppendLine()
    try {
        $inputs = Read-RulebookInputs -RepositoryRoot $root
        if (-not $inputs.SettingsPresent) { throw "Settings missing: .github/Rulebook-Settings.json in $root" }
        $settings = $inputs.Settings
        try {
            $resolvedTarget = Resolve-RulebookPublishTarget -Settings $settings -Override $Target
            $resolvedBaseUrl = Resolve-RulebookBaseUrl -Settings $settings -Repository $Repository -Override $BaseUrl
        } catch {
            Add-Annotation -File $settingsFile -Message $_.Exception.Message
            $failed = $true
        }
        if (-not $failed) {
            Write-Host "Publish target: $resolvedTarget, base URL: $resolvedBaseUrl"
            $site = $settings['site']
            if ($site -is [System.Collections.IDictionary] -and $site.Contains('enabled') -and $site['enabled'] -eq $true) {
                Add-Annotation -Command notice -Message 'site.enabled is true: the dashboard site arrives with WP14 (https://github.com/ALCops/rulebook-engine/issues/16). This run publishes the plain index.html.'
            }
            if ($Deploy) {
                if ([string]::IsNullOrEmpty($Repository)) { throw 'The Pages preflight needs the repository (GITHUB_REPOSITORY) as owner/name.' }
                $headers = @{ Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28' }
                if (-not [string]::IsNullOrEmpty($Token)) { $headers.Authorization = "Bearer $Token" }
                $response = Invoke-WebRequest -Uri "$($ApiUrl.TrimEnd('/'))/repos/$Repository/pages" -Headers $headers -TimeoutSec 30 -SkipHttpErrorCheck -ErrorAction Stop
                $body = if ($response.Content -is [byte[]]) { [System.Text.Encoding]::UTF8.GetString($response.Content) } else { [string]$response.Content }
                $preflight = Get-PagesPreflightResult -StatusCode ([int]$response.StatusCode) -Body $body -BaseUrl $resolvedBaseUrl -Repository $Repository
                Write-Host "Pages preflight: HTTP $([int]$response.StatusCode). $($preflight.Message)"
                if ($preflight.Warning) { Add-Annotation -Command warning -Message $preflight.Warning }
                if (-not $preflight.Ok) { Add-Annotation -Message $preflight.Message; $failed = $true }
            }
        }
        if (-not $failed) {
            $manifest = @(New-RulebookPublishStage -RepositoryRoot $root -BaseUrl $resolvedBaseUrl -OutputPath $StagingPath)
            $manifestParent = Split-Path -Parent $ManifestPath
            if (-not (Test-Path -LiteralPath $manifestParent)) { [void](New-Item -ItemType Directory -Path $manifestParent -Force) }
            [System.IO.File]::WriteAllText($ManifestPath, (ConvertTo-Json -InputObject $manifest -Depth 3), [System.Text.UTF8Encoding]::new($false))
            $counts = $manifest | Group-Object Kind -NoElement | ForEach-Object { '{0} {1}' -f $_.Count, $_.Name }
            Write-Host "Staged $($counts -join ', ') in $StagingPath"
        }
    } catch {
        Add-Annotation -Message $_.Exception.Message
        $failed = $true
    }

    if ($failed) {
        [void]$summary.AppendLine('Publish stopped before deploying:').AppendLine()
        foreach ($message in $script:errorMessages) { [void]$summary.AppendLine('- ' + (Format-TableCell $message)) }
        [void]$summary.AppendLine()
    } else {
        $mode = if ($Deploy) { 'Deploying to GitHub Pages' } else { 'Staged only (deploy is off)' }
        [void]$summary.AppendLine(('{0}: {1} files for `{2}`.' -f $mode, $manifest.Count, $resolvedBaseUrl)).AppendLine()
        [void]$summary.AppendLine('| Kind | URL |').AppendLine('|---|---|')
        foreach ($entry in $manifest) { [void]$summary.AppendLine(('| {0} | {1} |' -f $entry.Kind, $entry.Url)) }
        [void]$summary.AppendLine()
        if ($env:GITHUB_OUTPUT) {
            Write-Text -Path $env:GITHUB_OUTPUT -Text "stagingPath=$StagingPath`nmanifestPath=$ManifestPath`npageUrl=$resolvedBaseUrl/`n"
        }
    }
    $summaryText = $summary.ToString().Replace("`r`n", "`n")
    Write-Text -Path $SummaryPath -Text $summaryText
    return [pscustomobject]@{
        ExitCode     = $(if ($failed) { 1 } else { 0 })
        Phase        = $Phase
        BaseUrl      = $resolvedBaseUrl
        StagingPath  = $StagingPath
        ManifestPath = $ManifestPath
        Manifest     = $manifest
        Preflight    = $preflight
        Annotations  = $script:annotations.ToArray()
        Summary      = $summaryText
    }
}

# Phase Check
$results = @()
$failed = $false
[void]$summary.AppendLine('## Rulebook reachability check').AppendLine()
try {
    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { throw "Manifest not found: $ManifestPath (run -Phase Stage first)" }
    $manifest = @(Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json)
    Write-Host "Checking $(@($manifest | Where-Object Kind -CIn 'endpoint', 'skeleton').Count) URLs for up to $WindowSeconds s"
    $results = @(Test-RulebookEndpoints -Manifest $manifest -TimeoutSeconds $TimeoutSeconds -WindowSeconds $WindowSeconds -IntervalSeconds $IntervalSeconds)
    foreach ($result in $results | Where-Object Reason -CNE 'ok') {
        $reason = switch ($result.Reason) {
            'missing' { 'is missing (HTTP 404)' }
            'different' { 'serves a different body than the committed file' }
            'timeout' { "timed out after $TimeoutSeconds s" }
            default { "failed (HTTP $($result.Status))" }
        }
        Add-Annotation -Message ('{0} {1} after {2} attempt(s) in {3} s. Consumers of this URL compile with AL1033 (alc aborts; VS Code falls back to the analyzer defaults).' -f $result.Url, $reason, $result.Attempts, $result.Seconds)
        $failed = $true
    }
    $okCount = @($results | Where-Object Reason -CEQ 'ok').Count
    $slowest = ($results | Measure-Object Seconds -Maximum).Maximum
    Write-Host ('Reachability: {0} of {1} URLs serve the committed file (last one after {2} s)' -f $okCount, $results.Count, $slowest)
    [void]$summary.AppendLine(('**{0} of {1} URLs** serve the committed file; the last one after {2} s.' -f $okCount, $results.Count, $slowest)).AppendLine()
    [void]$summary.AppendLine('| URL | Result | HTTP | Attempts | Seconds |').AppendLine('|---|---|---|---|---|')
    foreach ($result in $results) {
        [void]$summary.AppendLine(('| {0} | {1} | {2} | {3} | {4} |' -f $result.Url, $result.Reason, $result.Status, $result.Attempts, $result.Seconds))
    }
    [void]$summary.AppendLine()
} catch {
    Add-Annotation -Message $_.Exception.Message
    [void]$summary.AppendLine((Format-TableCell $_.Exception.Message)).AppendLine()
    $failed = $true
}
$summaryText = $summary.ToString().Replace("`r`n", "`n")
Write-Text -Path $SummaryPath -Text $summaryText
[pscustomobject]@{
    ExitCode    = $(if ($failed) { 1 } else { 0 })
    Phase       = $Phase
    Results     = $results
    Annotations = $script:annotations.ToArray()
    Summary     = $summaryText
}
