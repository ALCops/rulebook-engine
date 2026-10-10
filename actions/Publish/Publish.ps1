#requires -Version 7.4
<#
.SYNOPSIS
Entry script of the Publish action: stage the published files (-Phase Stage) or check the deployed URLs (-Phase Check).
.DESCRIPTION
-Phase Stage reads the settings, resolves the target (only 'pages' is implemented) and the base URL, prints a notice
when site.enabled is set (the dashboard arrives with WP14), runs the GitHub Pages preflight when -Deploy is set,
stages the endpoints, the rendered skeletons, rulebook.json (with -Repository) and index.html into -StagingPath
(New-RulebookPublishStage, which refuses stale endpoints: Publish is a gate and never commits, D42), writes the
manifest to -ManifestPath, the URL list to the job summary and the outputs stagingPath, manifestPath and pageUrl to
GITHUB_OUTPUT.

-Phase Check reads -ManifestPath and runs Test-RulebookEndpoints: one error annotation per URL that is missing or
differs after -WindowSeconds, and the result table in the job summary.

Both phases return { ExitCode, Phase, Annotations, Summary, ... } and never call exit, so tests run the script
in-process; action.yaml exits with ExitCode.
#>
[CmdletBinding(PositionalBinding = $false)]
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
Import-Module (Join-Path $modules 'Rulebook.Action.psd1') -Force

$tempRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [System.IO.Path]::GetTempPath() }
if ([string]::IsNullOrEmpty($StagingPath)) { $StagingPath = Join-Path $tempRoot 'rulebook-publish' }
# The manifest sits next to the staging folder, never inside it, so it is not published.
if ([string]::IsNullOrEmpty($ManifestPath)) { $ManifestPath = Join-Path $tempRoot 'rulebook-publish.manifest.json' }
$StagingPath = Resolve-ActionPath $StagingPath
$ManifestPath = Resolve-ActionPath $ManifestPath
# Failure is the first reason the run failed, written as the output 'failure': target, baseUrl-empty,
# baseUrl-invalid, preflight, stage or check (anything else is error).
$ctx = New-ActionContext -Title 'Publish'
$summary = [System.Text.StringBuilder]::new()

if ($Phase -eq 'Stage') {
    $manifest = @()
    $resolvedBaseUrl = $null
    $preflight = $null
    $failed = $false
    [void]$summary.AppendLine('## Rulebook publish').AppendLine()
    try {
        $root = (Resolve-Path -LiteralPath $RepositoryRoot -ErrorAction Stop).ProviderPath
        $workspace = if ([string]::IsNullOrEmpty($WorkspaceRoot)) { $root } else { (Resolve-Path -LiteralPath $WorkspaceRoot -ErrorAction Stop).ProviderPath }
        $separator = [System.IO.Path]::DirectorySeparatorChar
        $settingsFile = [System.IO.Path]::GetRelativePath($workspace, (Join-Path $root '.github' 'Rulebook-Settings.json')).Replace($separator, '/')
        $inputs = Read-RulebookInputs -RepositoryRoot $root
        if (-not $inputs.SettingsPresent) { throw "Settings missing: .github/Rulebook-Settings.json in $root" }
        $settings = $inputs.Settings
        # Target and base URL are reported independently, so one run names both problems.
        # The annotation points at the settings file only when the value came from it, not from an action input.
        try {
            $resolvedTarget = Resolve-RulebookPublishTarget -Settings $settings -Override $Target
        } catch {
            Add-Annotation -Context $ctx -File $(if ([string]::IsNullOrWhiteSpace($Target)) { $settingsFile }) -Message $_.Exception.Message
            Add-Failure -Context $ctx -Kind 'target'
            $failed = $true
        }
        try {
            $resolvedBaseUrl = Resolve-RulebookBaseUrl -Settings $settings -Repository $Repository -Override $BaseUrl
        } catch {
            Add-Annotation -Context $ctx -File $(if ([string]::IsNullOrWhiteSpace($BaseUrl)) { $settingsFile }) -Message $_.Exception.Message
            $empty = [string]::IsNullOrWhiteSpace($BaseUrl) -and [string]::IsNullOrEmpty([string]$settings['baseUrl'])
            Add-Failure -Context $ctx -Kind $(if ($empty) { 'baseUrl-empty' } else { 'baseUrl-invalid' })
            $failed = $true
        }
        if (-not $failed) {
            Write-Host "Publish target: $resolvedTarget, base URL: $resolvedBaseUrl"
            $site = $settings['site']
            if ($site -is [System.Collections.IDictionary] -and $site.Contains('enabled') -and $site['enabled'] -eq $true) {
                Add-Annotation -Context $ctx -Command notice -Message 'site.enabled is true: the dashboard site arrives with WP14 (https://github.com/ALCops/rulebook-engine/issues/16). This run publishes the plain index.html.'
            }
            if ($Deploy) {
                if ([string]::IsNullOrEmpty($Repository)) { throw 'The Pages preflight needs the repository (GITHUB_REPOSITORY) as owner/name.' }
                $preflight = Invoke-PagesPreflight -Repository $Repository -ApiUrl $ApiUrl -Token $Token -BaseUrl $resolvedBaseUrl
                Write-Host "Pages preflight: HTTP $($preflight.StatusCode). $($preflight.Message)"
                if ($preflight.Warning) { Add-Annotation -Context $ctx -Command warning -Message $preflight.Warning }
                if (-not $preflight.Ok) { Add-Annotation -Context $ctx -Message $preflight.Message; Add-Failure -Context $ctx -Kind 'preflight'; $failed = $true }
            }
        }
        if (-not $failed) {
            try {
                $manifest = @(New-RulebookPublishStage -RepositoryRoot $root -BaseUrl $resolvedBaseUrl -OutputPath $StagingPath -Inputs $inputs -Repository $Repository)
            } catch {
                Add-Failure -Context $ctx -Kind 'stage'
                throw
            }
            $manifestParent = Split-Path -Parent $ManifestPath
            if (-not (Test-Path -LiteralPath $manifestParent)) { [void](New-Item -ItemType Directory -Path $manifestParent -Force) }
            [System.IO.File]::WriteAllText($ManifestPath, (ConvertTo-Json -InputObject $manifest -Depth 3), [System.Text.UTF8Encoding]::new($false))
            Write-Host ('Staged {0} endpoints, {1} skeletons, rulebook.json and index.html in {2}' -f @($manifest | Where-Object Kind -CEQ 'endpoint').Count, @($manifest | Where-Object Kind -CEQ 'skeleton').Count, $StagingPath)
        }
    } catch {
        Add-Annotation -Context $ctx -Message $_.Exception.Message
        Add-Failure -Context $ctx -Kind 'error'
        $failed = $true
    }

    if ($failed) {
        Write-ActionOutput -Outputs ([ordered]@{ failure = $ctx.Failure })
        [void]$summary.AppendLine('Publish stopped before deploying:').AppendLine()
        foreach ($message in $ctx.ErrorMessages) { [void]$summary.AppendLine('- ' + (ConvertTo-SingleLine $message)) }
        [void]$summary.AppendLine()
    } else {
        $mode = if ($Deploy) { 'Deploying to GitHub Pages' } else { 'Staged only (deploy is off)' }
        [void]$summary.AppendLine(('{0}: {1} files for `{2}`.' -f $mode, $manifest.Count, $resolvedBaseUrl)).AppendLine()
        [void]$summary.AppendLine('| Kind | URL |').AppendLine('|---|---|')
        foreach ($entry in $manifest) { [void]$summary.AppendLine(('| {0} | {1} |' -f $entry.Kind, $entry.Url)) }
        [void]$summary.AppendLine()
        Write-ActionOutput -Outputs ([ordered]@{ stagingPath = $StagingPath; manifestPath = $ManifestPath; pageUrl = "$resolvedBaseUrl/" })
    }
    $summaryText = $summary.ToString().Replace("`r`n", "`n")
    Write-Text -Path $SummaryPath -Text $summaryText
    return [pscustomobject]@{
        ExitCode     = $(if ($failed) { 1 } else { 0 })
        Phase        = $Phase
        Failure      = $ctx.Failure
        BaseUrl      = $resolvedBaseUrl
        StagingPath  = $StagingPath
        ManifestPath = $ManifestPath
        Manifest     = $manifest
        Preflight    = $preflight
        Annotations  = $ctx.Annotations.ToArray()
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
    Write-Host "Checking $(@($manifest | Where-Object Kind -CIn 'endpoint', 'skeleton', 'manifest', 'index').Count) URLs for up to $WindowSeconds s"
    $results = @(Test-RulebookEndpoints -Manifest $manifest -TimeoutSeconds $TimeoutSeconds -WindowSeconds $WindowSeconds -IntervalSeconds $IntervalSeconds)
    if ($results.Count -eq 0) { throw "No URL was checked: the manifest $ManifestPath lists no endpoint, skeleton, manifest or index." }
    foreach ($result in $results | Where-Object Reason -CNE 'ok') {
        $reason = switch ($result.Reason) {
            'missing' { 'is missing (HTTP 404)' }
            'different' { 'serves a different body than the committed file' }
            'timeout' { "timed out after $TimeoutSeconds s" }
            'redirect' { "answers with a redirect (HTTP $($result.Status)), which the compiler does not follow; set baseUrl to the final address" }
            default { if ($result.Status -gt 0) { "failed (HTTP $($result.Status))" } else { 'failed' } }
        }
        if ($result.Detail) { $reason += " ($($result.Detail))" }
        Add-Annotation -Context $ctx -Message ('{0} {1} after {2} attempt(s) in {3} s. Consumers of this URL compile with AL1033 (alc aborts; VS Code falls back to the analyzer defaults).' -f $result.Url, $reason, $result.Attempts, $result.Seconds)
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
    Add-Annotation -Context $ctx -Message $_.Exception.Message
    [void]$summary.AppendLine((ConvertTo-SingleLine $_.Exception.Message)).AppendLine()
    $failed = $true
}
$summaryText = $summary.ToString().Replace("`r`n", "`n")
Write-Text -Path $SummaryPath -Text $summaryText
[pscustomobject]@{
    ExitCode    = $(if ($failed) { 1 } else { 0 })
    Phase       = $Phase
    Failure     = $(if ($failed) { 'check' })
    Results     = $results
    Annotations = $ctx.Annotations.ToArray()
    Summary     = $summaryText
}
