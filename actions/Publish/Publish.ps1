#requires -Version 7.4
<#
.SYNOPSIS
Entry script of the Publish action: install Hugo (-Phase Install), stage the published files (-Phase Stage) or check
the deployed URLs (-Phase Check).
.DESCRIPTION
-Phase Install installs the Hugo the action pins (-HugoVersion, -HugoSha256; Install-Hugo) when site.enabled is true
in the settings and -HugoPath is the default 'hugo'; otherwise it prints why it skips. A failed install is failure
'site'.

-Phase Stage reads the settings, resolves the target (only 'pages' is implemented) and the base URL, runs the GitHub
Pages preflight when -Deploy is set (an empty base URL is then taken from html_url of the Pages site, D57; a private
site is a warning, the output private=true and no check), stages the endpoints, the rendered skeletons,
rulebook.json (with -Repository), catalog/diagnostics.json and the plain index.html into -StagingPath
(New-RulebookPublishStage, which refuses stale endpoints: Publish is a gate and never commits, D42). When
site.enabled is true it then copies the staged rulebook.json to site/data/rulebook.json and builds site/ with Hugo
into the staging folder (Build-RulebookSite), so the dashboard replaces the plain index.html; a target that cannot
serve HTML or a missing site/hugo.yaml is a warning and keeps the plain page, a missing Hugo or a failed build is
failure 'site'. It writes the manifest to -ManifestPath (with one page entry per stage and level page, the setup
page and the first rule page), the URL list to the job summary and the outputs stagingPath, manifestPath, pageUrl
and private to GITHUB_OUTPUT.

-Phase Check reads -ManifestPath and runs Test-RulebookEndpoints: one error annotation per URL that is missing or
differs after -WindowSeconds, and the result table in the job summary.

Both phases return { ExitCode, Phase, Annotations, Summary, ... } and never call exit, so tests run the script
in-process; action.yaml exits with ExitCode.
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [ValidateSet('Install', 'Stage', 'Check')][string]$Phase = 'Stage',
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
    [string]$WorkspaceRoot = $env:GITHUB_WORKSPACE,
    [string]$HugoPath = $(if ($env:INPUT_HUGOPATH) { $env:INPUT_HUGOPATH } else { 'hugo' }),
    [string]$HugoVersion = $env:HUGO_VERSION,
    [string]$HugoSha256 = $env:HUGO_SHA256
)

Set-StrictMode -Version 3.0
$modules = Join-Path $PSScriptRoot '..' '..' 'modules'
Import-Module (Join-Path $modules 'Rulebook.Generate.psd1') -Force
Import-Module (Join-Path $modules 'Rulebook.Publish.psd1') -Force
Import-Module (Join-Path $modules 'Rulebook.Site.psd1') -Force
Import-Module (Join-Path $modules 'Rulebook.Action.psd1') -Force

$tempRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [System.IO.Path]::GetTempPath() }
if ([string]::IsNullOrEmpty($StagingPath)) { $StagingPath = Join-Path $tempRoot 'rulebook-publish' }
# The manifest sits next to the staging folder, never inside it, so it is not published.
if ([string]::IsNullOrEmpty($ManifestPath)) { $ManifestPath = Join-Path $tempRoot 'rulebook-publish.manifest.json' }
$StagingPath = Resolve-ActionPath $StagingPath
$ManifestPath = Resolve-ActionPath $ManifestPath
# Failure is the first reason the run failed, written as the output 'failure': target, baseUrl-empty,
# baseUrl-invalid, preflight, stage, site or check (anything else is error).
$ctx = New-ActionContext -Title 'Publish'
$summary = [System.Text.StringBuilder]::new()

function Test-SiteEnabled {
    # site.enabled of the settings dictionary; only the boolean true turns the site on.
    param($Settings)
    $site = if ($Settings -is [System.Collections.IDictionary] -and $Settings.Contains('site')) { $Settings['site'] } else { $null }
    return $site -is [System.Collections.IDictionary] -and $site.Contains('enabled') -and $site['enabled'] -is [bool] -and $site['enabled']
}

if ($Phase -eq 'Install') {
    $failed = $false
    $hugo = $null
    try {
        $root = (Resolve-Path -LiteralPath $RepositoryRoot -ErrorAction Stop).ProviderPath
        $settingsFile = Join-Path $root '.github' 'Rulebook-Settings.json'
        $settings = $null
        if (Test-Path -LiteralPath $settingsFile -PathType Leaf) {
            try { $settings = Get-Content -LiteralPath $settingsFile -Raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop } catch { $settings = $null }
        }
        if (-not (Test-SiteEnabled $settings)) {
            Write-Host 'Hugo is not installed: site.enabled is not true in .github/Rulebook-Settings.json, so Publish stages the plain index.html.'
        } elseif ($HugoPath -cne 'hugo') {
            Write-Host "Hugo is not installed: the hugoPath input names $HugoPath."
        } else {
            try {
                $hugo = Install-Hugo -Version $HugoVersion -Sha256 $HugoSha256 -DownloadRoot $tempRoot
            } catch {
                Add-Annotation -Context $ctx -Message "Installing Hugo $HugoVersion failed: $($_.Exception.Message)"
                Add-Failure -Context $ctx -Kind 'site'
                $failed = $true
            }
            if ($hugo) { Write-Host $(if ($hugo.Installed) { "Installed $($hugo.Version)" } else { "Hugo is installed already: $($hugo.Version)" }) }
        }
    } catch {
        Add-Annotation -Context $ctx -Message $_.Exception.Message
        Add-Failure -Context $ctx -Kind 'error'
        $failed = $true
    }
    if ($failed) { Write-ActionOutput -Outputs ([ordered]@{ failure = $ctx.Failure }) }
    return [pscustomobject]@{
        ExitCode    = $(if ($failed) { 1 } else { 0 })
        Phase       = $Phase
        Failure     = $ctx.Failure
        Hugo        = $hugo
        Annotations = $ctx.Annotations.ToArray()
    }
}

if ($Phase -eq 'Stage') {
    $manifest = @()
    $resolvedBaseUrl = $null
    $preflight = $null
    $siteBuilt = $null
    $private = $false
    $failed = $false
    [void]$summary.AppendLine('## Rulebook publish').AppendLine()
    # Lines about the base URL and the Pages site, written above the URL table of a successful run.
    $notes = [System.Collections.Generic.List[string]]::new()
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
        # An empty base URL is allowed only with -Deploy, where the preflight answer carries the address of the
        # Pages site (D57); the dry run makes no API call, so it keeps the failure with the proposal.
        $configuredBaseUrl = $null
        try {
            $configuredBaseUrl = Resolve-RulebookBaseUrl -Settings $settings -Repository $Repository -Override $BaseUrl -AllowEmpty:$Deploy
        } catch {
            $empty = [string]::IsNullOrWhiteSpace($BaseUrl) -and [string]::IsNullOrEmpty([string]$settings['baseUrl'])
            $message = $_.Exception.Message
            # The dry run offers the other way out first: a deploy takes the address of the Pages site.
            if ($empty) { $message = $message.Replace('baseUrl is empty. Set ', 'baseUrl is empty. Leave it empty and run Publish with deploy true to take the address of the Pages site, or set ') }
            Add-Annotation -Context $ctx -File $(if ([string]::IsNullOrWhiteSpace($BaseUrl)) { $settingsFile }) -Message $message
            Add-Failure -Context $ctx -Kind $(if ($empty) { 'baseUrl-empty' } else { 'baseUrl-invalid' })
            $failed = $true
        }
        if (-not $failed) {
            $resolvedBaseUrl = if ($configuredBaseUrl) { $configuredBaseUrl } else { $null }
            if ($Deploy) {
                if ([string]::IsNullOrEmpty($Repository)) { throw 'The Pages preflight needs the repository (GITHUB_REPOSITORY) as owner/name.' }
                # The configured base URL is passed only for the custom-domain warning.
                $preflightParameters = @{ Repository = $Repository; ApiUrl = $ApiUrl; Token = $Token }
                if ($configuredBaseUrl) { $preflightParameters.BaseUrl = $configuredBaseUrl }
                $preflight = Invoke-PagesPreflight @preflightParameters
                Write-Host "Pages preflight: HTTP $($preflight.StatusCode). $($preflight.Message)"
                foreach ($warning in @($preflight.Warning | Where-Object { $_ })) { Add-Annotation -Context $ctx -Command warning -Message $warning }
                if (-not $preflight.Ok) {
                    Add-Annotation -Context $ctx -Message $preflight.Message; Add-Failure -Context $ctx -Kind 'preflight'; $failed = $true
                } else {
                    if (-not $configuredBaseUrl) {
                        if ([string]::IsNullOrEmpty($preflight.HtmlUrl)) {
                            $message = 'The Pages site answered without an address (html_url), so Publish cannot take the base URL from it.'
                            try { $null = Resolve-RulebookBaseUrl -Settings $settings -Repository $Repository -Override $BaseUrl } catch { $message += ' ' + $_.Exception.Message }
                            Add-Annotation -Context $ctx -File $(if ([string]::IsNullOrWhiteSpace($BaseUrl)) { $settingsFile }) -Message $message
                            Add-Failure -Context $ctx -Kind 'baseUrl-empty'
                            $failed = $true
                        } else {
                            # The address passes the same check as a set baseUrl: a custom domain without
                            # Enforce HTTPS answers with an http html_url, which the compiler must not be given.
                            try {
                                $resolvedBaseUrl = Resolve-RulebookBaseUrl -Settings $null -Override $preflight.HtmlUrl
                                Write-Host "Base URL from the Pages site: $resolvedBaseUrl"
                                $notes.Add("Base URL from the Pages site: ``$resolvedBaseUrl`` (baseUrl is empty).")
                            } catch {
                                # The message names the settings file as the module's messages do; the annotation
                                # carries no file attribute because the value came from the Pages API, not the file.
                                $fix = if ($preflight.HtmlUrl.StartsWith('http://', [System.StringComparison]::OrdinalIgnoreCase)) { 'Turn on Enforce HTTPS under Settings > Pages, or set baseUrl in .github/Rulebook-Settings.json.' } else { 'Set baseUrl in .github/Rulebook-Settings.json.' }
                                Add-Annotation -Context $ctx -Message "The address of the Pages site, ``$($preflight.HtmlUrl)``, cannot be the base URL: $($_.Exception.Message.Replace('The baseUrl input ', 'it ')) $fix"
                                Add-Failure -Context $ctx -Kind 'baseUrl-invalid'
                                $failed = $true
                            }
                        }
                    }
                    if ($preflight.Private) {
                        $private = $true
                        $notes.Add('The Pages site is private: no endpoint was checked, the AL compiler cannot fetch them from this site.')
                    }
                }
            }
            if (-not $failed) { Write-Host "Publish target: $resolvedTarget, base URL: $resolvedBaseUrl" }
        }
        if (-not $failed) {
            try {
                $siteModel = Read-RulebookSiteModel -RepositoryRoot $root -BaseUrl $resolvedBaseUrl -Inputs $inputs -Repository $Repository
                $manifest = @(New-RulebookPublishStage -RepositoryRoot $root -BaseUrl $resolvedBaseUrl -OutputPath $StagingPath -Inputs $inputs -Repository $Repository -SiteModel $siteModel)
            } catch {
                Add-Failure -Context $ctx -Kind 'stage'
                throw
            }
            $manifestParent = Split-Path -Parent $ManifestPath
            if (-not (Test-Path -LiteralPath $manifestParent)) { [void](New-Item -ItemType Directory -Path $manifestParent -Force) }
            Write-Host ('Staged {0} endpoints, {1} skeletons, rulebook.json, catalog/diagnostics.json and index.html in {2}' -f @($manifest | Where-Object Kind -CEQ 'endpoint').Count, @($manifest | Where-Object Kind -CEQ 'skeleton').Count, $StagingPath)
            if (Test-SiteEnabled $settings) {
                $siteDir = Join-Path $root 'site'
                if ($resolvedTarget -cne 'pages') {
                    Add-Annotation -Context $ctx -Command warning -Message "site.enabled is true, but the publish target '$resolvedTarget' serves HTML as plain text: this run publishes the plain index.html."
                } elseif (-not (Test-Path -LiteralPath (Join-Path $siteDir 'hugo.yaml') -PathType Leaf)) {
                    Add-Annotation -Context $ctx -Command warning -Message 'site.enabled is true, but site/hugo.yaml is missing: this run publishes the plain index.html. Run Update Rulebook System Files to get site/, or set site.enabled to false.'
                } elseif ($null -eq (Get-Command -Name $HugoPath -ErrorAction SilentlyContinue)) {
                    Add-Annotation -Context $ctx -Message "site.enabled is true, but Hugo was not found ('$HugoPath'). The Publish action installs it on Linux runners; elsewhere install Hugo 0.156.0 or later (extended) and pass its path as the hugoPath input, or set site.enabled to false."
                    Add-Failure -Context $ctx -Kind 'site'
                    $failed = $true
                } else {
                    $dataFile = Join-Path $root (Get-RulebookSiteDataPath)
                    [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $dataFile))
                    Copy-Item -LiteralPath (Join-Path $StagingPath 'rulebook.json') -Destination $dataFile -Force
                    $site = $null
                    try {
                        $site = Build-RulebookSite -SitePath $siteDir -BaseUrl $resolvedBaseUrl -Destination $StagingPath -HugoPath $HugoPath
                    } catch {
                        Add-Annotation -Context $ctx -Message "The site build failed: $($_.Exception.Message)"
                        Add-Failure -Context $ctx -Kind 'site'
                        $failed = $true
                    }
                    if ($site) {
                        Write-Host ('Built the site: {0} pages in {1} s' -f $site.PageCount, $site.Seconds.ToString([System.Globalization.CultureInfo]::InvariantCulture))
                        if (-not $site.MarkerPresent) { Add-Annotation -Context $ctx -Command warning -Message "The built $($site.MarkerPage) has no data-rulebook-matrix marker: site/layouts may have dropped the matrix. The site is published as built." }
                        # Hugo lowercases page paths; the check requests every stage and level page, the setup page and
                        # the first rule page.
                        $pagePaths = @(foreach ($stage in $inputs.Stages) { "stages/$($stage.Slug)/" }) + @(foreach ($level in $inputs.Levels) { "levels/$($level.Slug)/" }) + @('setup/')
                        $rules = @($siteModel.Document['rules'])
                        if ($rules.Count -gt 0) { $pagePaths += "rules/$(([string]$rules[0]['id']).ToLowerInvariant())/" }
                        foreach ($pagePath in $pagePaths) {
                            if ($site.Pages -cnotcontains "$($pagePath)index.html") { continue }
                            $manifest += [pscustomobject]@{ Path = "$($pagePath)index.html"; Url = "$resolvedBaseUrl/$pagePath"; Kind = 'page'; StagedFile = (Join-Path $StagingPath $pagePath 'index.html') }
                        }
                        $siteBuilt = $site
                    }
                }
            }
            if (-not $failed) {
                [System.IO.File]::WriteAllText($ManifestPath, (ConvertTo-Json -InputObject $manifest -Depth 3), [System.Text.UTF8Encoding]::new($false))
            }
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
        foreach ($note in $notes) { [void]$summary.AppendLine($note).AppendLine() }
        if ($siteBuilt) { [void]$summary.AppendLine(('The dashboard site: {0} pages built with Hugo in {1} s; the table lists the pages the check requests.' -f $siteBuilt.PageCount, $siteBuilt.Seconds.ToString([System.Globalization.CultureInfo]::InvariantCulture))).AppendLine() }
        [void]$summary.AppendLine('| Kind | URL |').AppendLine('|---|---|')
        foreach ($entry in $manifest) { [void]$summary.AppendLine(('| {0} | {1} |' -f $entry.Kind, $entry.Url)) }
        [void]$summary.AppendLine()
        Write-ActionOutput -Outputs ([ordered]@{ stagingPath = $StagingPath; manifestPath = $ManifestPath; pageUrl = "$resolvedBaseUrl/"; private = $(if ($private) { 'true' } else { 'false' }) })
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
        Private      = $private
        Site         = $siteBuilt
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
    Write-Host "Checking $(@($manifest | Where-Object Kind -CIn 'endpoint', 'skeleton', 'manifest', 'catalog', 'index', 'page').Count) URLs for up to $WindowSeconds s"
    $results = @(Test-RulebookEndpoints -Manifest $manifest -TimeoutSeconds $TimeoutSeconds -WindowSeconds $WindowSeconds -IntervalSeconds $IntervalSeconds)
    if ($results.Count -eq 0) { throw "No URL was checked: the manifest $ManifestPath lists no endpoint, skeleton, manifest, catalog, index or page." }
    foreach ($result in $results | Where-Object Reason -CNE 'ok') {
        $reason = switch ($result.Reason) {
            'missing' { 'is missing (HTTP 404)' }
            'different' { 'serves a different body than the committed file' }
            'timeout' { "timed out after $TimeoutSeconds s" }
            'redirect' { "answers with a redirect (HTTP $($result.Status)), which the compiler does not follow; set baseUrl to the final address, or leave it empty so Publish takes the address of the Pages site" }
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
