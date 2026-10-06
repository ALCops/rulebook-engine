#requires -Version 7.4
# Rulebook.Publish: stages what an organization publishes (the levels x stages endpoints of rulesets/, the skeletons
# with {BASEURL} rendered, a plain index.html), explains a missing or misconfigured GitHub Pages site, and checks
# after the deploy that every published URL serves the staged bytes. Publish is a gate and never commits (D42): the
# staging refuses endpoints that differ from what Rulebook.Generate produces.
# Contract: docs/ARCHITECTURE.md sections 7.2 and 9. Setup per target: docs/reference/publish-targets.md.

Set-StrictMode -Version 3.0
Import-Module (Join-Path $PSScriptRoot 'Rulebook.Generate.psd1')

$script:SettingsPath = '.github/Rulebook-Settings.json'
$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$script:BaseUrlPattern = '^https://[^\s/]+(/[^\s/]+)*\z'
$script:Placeholder = '{BASEURL}'
# The targets of the settings schema that WP05 does not implement, with their backlog issues.
$script:PendingTargets = [ordered]@{
    'dist-repo'  = 'https://github.com/ALCops/rulebook-engine/issues/55'
    'azure-blob' = 'https://github.com/ALCops/rulebook-engine/issues/56'
    'gist'       = 'https://github.com/ALCops/rulebook-engine/issues/57'
}

#region Internal helpers

function Get-SettingValue {
    # A key of the settings dictionary, or a nested key ('site', 'enabled'); $null when absent (StrictMode safe).
    param($Settings, [Parameter(Mandatory)][string[]]$Path)
    $value = $Settings
    foreach ($key in $Path) {
        if ($value -isnot [System.Collections.IDictionary] -or -not $value.Contains($key)) { return $null }
        $value = $value[$key]
    }
    return $value
}

function Get-BaseUrlProposal {
    # https://<owner>.github.io/<repo>, lowercased; a repository named <owner>.github.io is served at the root.
    param([AllowNull()][AllowEmptyString()][string]$Repository)
    if ([string]::IsNullOrEmpty($Repository) -or $Repository -notmatch '^([^/\s]+)/([^/\s]+)$') {
        return 'https://<owner>.github.io/<repository>'
    }
    $owner = $Matches[1].ToLowerInvariant()
    $name = $Matches[2].ToLowerInvariant()
    if ($name -ceq "$owner.github.io") { return "https://$owner.github.io" }
    return "https://$owner.github.io/$name"
}

function ConvertTo-HtmlText {
    param([AllowNull()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    return [System.Net.WebUtility]::HtmlEncode($Text)
}

function Write-StagedFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][byte[]]$Bytes)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { [void][System.IO.Directory]::CreateDirectory($parent) }
    [System.IO.File]::WriteAllBytes($Path, $Bytes)
}

function Get-ResponseText {
    # The body of an Invoke-WebRequest response as UTF-8 text; Content is a string for text types, else bytes.
    param($Response)
    if ($null -eq $Response -or $null -eq $Response.PSObject.Properties['Content']) { return '' }
    # A direct assignment: an if expression would unroll a byte[] into object[].
    $content = $Response.Content
    if ($null -eq $content) { return '' }
    if ($content -is [byte[]]) { return $script:Utf8NoBom.GetString($content) }
    return [string]$content
}

function Test-TimeoutError {
    param([Parameter(Mandatory)][System.Exception]$Exception)
    for ($current = $Exception; $null -ne $current; $current = $current.InnerException) {
        if ($current -is [System.TimeoutException] -or $current -is [System.Threading.Tasks.TaskCanceledException]) { return $true }
        if ($current.Message -match 'time(d)?\s?out|timeout') { return $true }
    }
    return $false
}

#endregion

#region Settings

function Resolve-RulebookPublishTarget {
    <#
    .SYNOPSIS
    The publish target: -Override when set, else settings.publish.target, else pages. Throws for a target that is
    not implemented yet, with its backlog issue.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowNull()]$Settings, [AllowNull()][AllowEmptyString()][string]$Override)
    $target = if (-not [string]::IsNullOrWhiteSpace($Override)) { $Override.Trim() } else { [string](Get-SettingValue $Settings 'publish', 'target') }
    if ([string]::IsNullOrEmpty($target)) { $target = 'pages' }
    if ($target -ceq 'pages') { return $target }
    if ($script:PendingTargets.Contains($target)) {
        throw "Publish target '$target' is not implemented yet; see $($script:PendingTargets[$target]). Use publish.target 'pages' in $($script:SettingsPath) until then."
    }
    throw "Unknown publish target '$target'; allowed are pages, dist-repo, azure-blob and gist (only pages is implemented)."
}

function Resolve-RulebookBaseUrl {
    <#
    .SYNOPSIS
    The base URL the endpoints are served from: -Override when set, else settings.baseUrl.
    .DESCRIPTION
    An empty value throws with a proposal for GitHub Pages derived from -Repository (owner/name):
    https://<owner>.github.io/<repo>, lowercased, or https://<owner>.github.io for a repository named
    <owner>.github.io. A value that is not https or ends with a slash throws too (C5 checks the settings; this
    guards the override input).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowNull()]$Settings,
        [AllowNull()][AllowEmptyString()][string]$Repository,
        [AllowNull()][AllowEmptyString()][string]$Override
    )
    $fromOverride = -not [string]::IsNullOrWhiteSpace($Override)
    $value = if ($fromOverride) { $Override.Trim() } else { [string](Get-SettingValue $Settings 'baseUrl') }
    $where = if ($fromOverride) { 'The baseUrl input' } else { "baseUrl in $($script:SettingsPath)" }
    if ([string]::IsNullOrEmpty($value)) {
        $proposal = Get-BaseUrlProposal -Repository $Repository
        throw "baseUrl is empty. Set `"baseUrl`": `"$proposal`" in $($script:SettingsPath) (the GitHub Pages address of this repository; use your custom domain instead if the Pages site has one), commit it in a pull request and run Publish again."
    }
    if ($value.EndsWith('/')) { throw "$where ends with a slash: '$value'. Remove the trailing slash." }
    if ($value -cnotmatch $script:BaseUrlPattern) { throw "$where must be an https URL without spaces or a trailing slash: '$value'." }
    return $value
}

#endregion

#region Staging

function ConvertTo-RulebookIndexHtml {
    <#
    .SYNOPSIS
    The static index.html of the published site: one table per stage, one row per level, in settings order.
    .DESCRIPTION
    Each row has the level's display name, the endpoint URL as a link (each endpoint URL appears exactly once as
    link text), the number of ids the endpoint lists and the skeleton download link. All text is HTML-encoded. No
    JavaScript. -Endpoints are Rulebook.Endpoint objects (Get-RulebookEndpoint) for every level x stage.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Inputs, [Parameter(Mandatory)][string]$BaseUrl, [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Endpoints)
    $byKey = @{}
    foreach ($endpoint in $Endpoints) { $byKey[$endpoint.Key] = $endpoint }
    $h = { param($Text) ConvertTo-HtmlText $Text }
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('<!DOCTYPE html>')
    $lines.Add('<html lang="en">')
    $lines.Add('<head>')
    $lines.Add('<meta charset="utf-8">')
    $lines.Add('<meta name="viewport" content="width=device-width, initial-scale=1">')
    $lines.Add('<title>Rulebook endpoints</title>')
    $lines.Add('<style>')
    $lines.Add('body { font-family: system-ui, sans-serif; margin: 2rem auto; max-width: 64rem; padding: 0 1rem; line-height: 1.5; }')
    $lines.Add('table { border-collapse: collapse; width: 100%; margin-bottom: 2rem; }')
    $lines.Add('th, td { border: 1px solid #ccc; padding: .4rem .6rem; text-align: left; vertical-align: top; }')
    $lines.Add('td.count { text-align: right; }')
    $lines.Add('code { word-break: break-all; }')
    $lines.Add('</style>')
    $lines.Add('</head>')
    $lines.Add('<body>')
    $lines.Add('<h1>Rulebook endpoints</h1>')
    $lines.Add('<p>Point <code>al.ruleSetPath</code>, the AL-Go <code>rulesetFile</code> or your compile task at an endpoint URL, or download a skeleton into your AL project to add project exceptions. An endpoint lists only the ids whose action differs from the analyzer default.</p>')
    $lines.Add('<h2>Levels</h2>')
    $lines.Add('<dl>')
    foreach ($level in $Inputs.Levels) {
        $lines.Add('<dt>' + (& $h $level.Name) + '</dt>')
        $lines.Add('<dd>' + (& $h $level.Description) + '</dd>')
    }
    $lines.Add('</dl>')
    foreach ($stage in $Inputs.Stages) {
        $lines.Add('<h2 id="stage-' + (& $h $stage.Slug) + '">Stage ' + (& $h $stage.Name) + '</h2>')
        if (-not [string]::IsNullOrEmpty($stage.Description)) { $lines.Add('<p>' + (& $h $stage.Description) + '</p>') }
        $lines.Add('<table>')
        $lines.Add('<thead><tr><th>Level</th><th>Endpoint</th><th>Listed ids</th><th>Skeleton</th></tr></thead>')
        $lines.Add('<tbody>')
        foreach ($level in $Inputs.Levels) {
            $endpoint = $byKey["$($level.Slug).$($stage.Slug)"]
            if ($null -eq $endpoint) { throw "ConvertTo-RulebookIndexHtml: no endpoint for $($level.Slug).$($stage.Slug)" }
            $url = "$BaseUrl/$($endpoint.File)"
            $skeleton = "$($level.Slug).$($stage.Slug).ruleset.json"
            $skeletonUrl = "$BaseUrl/skeletons/$skeleton"
            $lines.Add(('<tr><td>{0}</td><td><a href="{1}"><code>{1}</code></a></td><td class="count">{2}</td><td><a href="{3}" download="{4}">{4}</a></td></tr>' -f
                    (& $h $level.Name), (& $h $url), @($endpoint.Entries).Count, (& $h $skeletonUrl), (& $h $skeleton)))
        }
        $lines.Add('</tbody>')
        $lines.Add('</table>')
    }
    $lines.Add('</body>')
    $lines.Add('</html>')
    return ($lines -join "`n") + "`n"
}

function New-RulebookPublishStage {
    <#
    .SYNOPSIS
    Writes the folder Publish deploys: the levels x stages endpoints, the rendered skeletons and index.html.
    .DESCRIPTION
    Clears and creates -OutputPath. Copies exactly the expected rulesets/<endpoint> files (never a folder glob, so
    a stray or removed file is not published) after checking that each equals what Update-RulebookEndpoints would
    write (Publish is a gate, D42); a missing or stale endpoint throws with the fix. Writes
    skeletons/<level>.<stage>.ruleset.json with {BASEURL} replaced by -BaseUrl (ordinal; the repository copy is
    untouched; a missing skeleton throws) and index.html. Returns one manifest entry per file in settings order:
    Path (relative, '/'), Url, Kind (endpoint, skeleton, index) and StagedFile (full path).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Writes only the staging folder the caller names; -WhatIf would stage nothing to check')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$RepositoryRoot, [Parameter(Mandatory)][string]$BaseUrl, [Parameter(Mandatory)][string]$OutputPath)
    if ($BaseUrl -cnotmatch $script:BaseUrlPattern) { throw "BaseUrl must be an https URL without a trailing slash: '$BaseUrl'" }
    $inputs = Read-RulebookInputs -RepositoryRoot $RepositoryRoot
    if (-not $inputs.SettingsPresent) { throw "Settings missing: $($script:SettingsPath) in $($inputs.Root)" }
    if ($inputs.Levels.Count -eq 0 -or $inputs.Stages.Count -eq 0) { throw "$($script:SettingsPath): levels and stages must each list at least one entry (C5)" }

    $endpoints = [System.Collections.Generic.List[object]]::new()
    $problems = [System.Collections.Generic.List[string]]::new()
    foreach ($level in $inputs.Levels) {
        foreach ($stage in $inputs.Stages) {
            $endpoint = Get-RulebookEndpoint -Inputs $inputs -Level $level.Slug -Stage $stage.Slug
            $endpoints.Add($endpoint)
            $source = Join-Path $inputs.Root $endpoint.File
            if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { $problems.Add("$($endpoint.File) is missing"); continue }
            $expected = $script:Utf8NoBom.GetBytes((ConvertTo-RulesetJson -Name $endpoint.Name -Description $endpoint.Description -Rules $endpoint.Entries))
            if (-not [System.Linq.Enumerable]::SequenceEqual([byte[]][System.IO.File]::ReadAllBytes($source), [byte[]]$expected)) {
                $problems.Add("$($endpoint.File) is stale")
            }
        }
    }
    if ($problems.Count -gt 0) {
        throw ('The committed endpoints do not match their inputs (C12): {0}. Publish never commits (D42): regenerate rulesets/ with Update-RulebookEndpoints (or run the Validate workflow), commit the result in a pull request and publish after it is merged.' -f ($problems -join '; '))
    }

    $skeletonSources = [System.Collections.Generic.List[object]]::new()
    foreach ($level in $inputs.Levels) {
        foreach ($stage in $inputs.Stages) {
            $leaf = "$($level.Slug).$($stage.Slug).ruleset.json"
            $source = Join-Path $inputs.Root 'skeletons' $leaf
            if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
                throw "skeletons/$leaf is missing. The skeletons come with the template (New-RulebookSkeleton); restore the file from the template or the git history."
            }
            $skeletonSources.Add([pscustomobject]@{ Leaf = $leaf; Source = $source })
        }
    }

    if (Test-Path -LiteralPath $OutputPath) { Remove-Item -LiteralPath $OutputPath -Recurse -Force }
    $output = [System.IO.Directory]::CreateDirectory($OutputPath).FullName
    $manifest = [System.Collections.Generic.List[object]]::new()
    foreach ($endpoint in $endpoints) {
        $staged = Join-Path $output $endpoint.File
        Write-StagedFile -Path $staged -Bytes ([System.IO.File]::ReadAllBytes((Join-Path $inputs.Root $endpoint.File)))
        $manifest.Add([pscustomobject]@{ Path = $endpoint.File; Url = "$BaseUrl/$($endpoint.File)"; Kind = 'endpoint'; StagedFile = $staged })
    }
    foreach ($skeleton in $skeletonSources) {
        $path = "skeletons/$($skeleton.Leaf)"
        $staged = Join-Path $output $path
        $text = [System.IO.File]::ReadAllText($skeleton.Source, $script:Utf8NoBom)
        Write-StagedFile -Path $staged -Bytes ($script:Utf8NoBom.GetBytes($text.Replace($script:Placeholder, $BaseUrl, [System.StringComparison]::Ordinal)))
        $manifest.Add([pscustomobject]@{ Path = $path; Url = "$BaseUrl/$path"; Kind = 'skeleton'; StagedFile = $staged })
    }
    $index = Join-Path $output 'index.html'
    Write-StagedFile -Path $index -Bytes ($script:Utf8NoBom.GetBytes((ConvertTo-RulebookIndexHtml -Inputs $inputs -BaseUrl $BaseUrl -Endpoints $endpoints.ToArray())))
    $manifest.Add([pscustomobject]@{ Path = 'index.html'; Url = "$BaseUrl/"; Kind = 'index'; StagedFile = $index })
    return $manifest.ToArray()
}

#endregion

#region Pages and the reachability check

function Get-PagesPreflightResult {
    <#
    .SYNOPSIS
    Maps the answer of GET /repos/{owner}/{repo}/pages to Ok, Message and Warning; never creates a site.
    .DESCRIPTION
    200 with build_type workflow is Ok; Warning is set when html_url (without its trailing slash) differs from
    -BaseUrl, which is the custom-domain case. Every other answer is not Ok, with a Message that says what to do: a
    legacy (branch) source, no site yet (404), the plan or organization policy gates of spike (d), and a token
    without pages permission.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][int]$StatusCode,
        [AllowNull()][AllowEmptyString()][string]$Body,
        [AllowNull()][AllowEmptyString()][string]$BaseUrl,
        [AllowNull()][AllowEmptyString()][string]$Repository
    )
    $json = $null
    if (-not [string]::IsNullOrWhiteSpace($Body)) {
        try { $json = $Body | ConvertFrom-Json -AsHashtable -ErrorAction Stop } catch { $json = $null }
    }
    $apiMessage = [string](Get-SettingValue $json 'message')
    $settingsPage = if ([string]::IsNullOrEmpty($Repository)) { 'Settings > Pages' } else { "https://github.com/$Repository/settings/pages" }
    $result = { param($Ok, $Message, $Warning) [pscustomobject]@{ Ok = $Ok; Message = $Message; Warning = $Warning } }

    if ($StatusCode -eq 200) {
        $buildType = [string](Get-SettingValue $json 'build_type')
        if ($buildType -cne 'workflow') {
            return & $result $false "The GitHub Pages site of this repository builds from a branch (build_type '$buildType'). Set Source to 'GitHub Actions' once in $settingsPage; Publish deploys with actions/deploy-pages." $null
        }
        $htmlUrl = ([string](Get-SettingValue $json 'html_url')).TrimEnd('/')
        $warning = $null
        if (-not [string]::IsNullOrEmpty($BaseUrl) -and -not [string]::IsNullOrEmpty($htmlUrl) -and -not [string]::Equals($htmlUrl, $BaseUrl, [System.StringComparison]::OrdinalIgnoreCase)) {
            $warning = "The Pages site is served at $htmlUrl, but baseUrl is $BaseUrl. The skeletons and the reachability check use baseUrl; if the site has a custom domain, set baseUrl to it in $($script:SettingsPath)."
        }
        return & $result $true 'GitHub Pages is enabled with Source GitHub Actions.' $warning
    }
    if ($apiMessage -like '*current plan does not support GitHub Pages*') {
        return & $result $false 'The plan of this account does not support GitHub Pages for a private repository. Make the repository public, upgrade to GitHub Pro, Team or Enterprise Cloud, or wait for the dist-repo target (https://github.com/ALCops/rulebook-engine/issues/55).' $null
    }
    if ($apiMessage -like '*administrators disabled Pages creation*') {
        return & $result $false 'An organization administrator has disabled Pages creation. Ask an owner to allow it under Organization settings > Member privileges > Pages creation (Public), then enable Pages for this repository once.' $null
    }
    if ($apiMessage -like '*Resource not accessible by integration*' -or $StatusCode -eq 403) {
        return & $result $false "The workflow token cannot read the Pages site (HTTP $StatusCode$(if ($apiMessage) { ": $apiMessage" })). Give the job 'pages: write' and 'id-token: write' permissions, and make sure Pages is enabled once in $settingsPage." $null
    }
    if ($StatusCode -eq 404) {
        return & $result $false "GitHub Pages is not enabled for this repository. Enable it once: $settingsPage, Source 'GitHub Actions'. On a Free organization the repository must be public and an organization owner must allow Pages creation (Member privileges). Publish never creates the site itself." $null
    }
    $detail = if ($apiMessage) { ": $apiMessage" } else { '' }
    return & $result $false "Reading the GitHub Pages site failed with HTTP $StatusCode$detail." $null
}

function Test-RulebookEndpoints {
    <#
    .SYNOPSIS
    GETs every endpoint and skeleton URL of a staging manifest until each serves the staged bytes or the window ends.
    .DESCRIPTION
    One pass requests every pending URL with -TimeoutSeconds per request (the compiler uses 15 s). A URL passes on
    HTTP 200 with a body equal to the staged file (both UTF-8 decoded, compared ordinally). Pending URLs are
    retried every -IntervalSeconds until -WindowSeconds of waiting is used up (GitHub Pages serves with
    max-age=600, hence 660 s). Returns one result per URL: Path, Url, Kind, Status (HTTP status or 0), Reason
    (ok, missing, different, timeout, error), Attempts and Seconds (elapsed when it passed or was last tried).
    Never throws; the caller decides the exit code.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Checks the whole published set')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Manifest,
        [ValidateRange(1, 300)][int]$TimeoutSeconds = 15,
        [ValidateRange(0, 3600)][int]$WindowSeconds = 660,
        [ValidateRange(1, 600)][int]$IntervalSeconds = 30
    )
    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in $Manifest) {
        if ($entry.Kind -cnotin 'endpoint', 'skeleton') { continue }
        $expected = [System.IO.File]::ReadAllText($entry.StagedFile, $script:Utf8NoBom)
        $results.Add([pscustomobject]@{
                Path = $entry.Path; Url = $entry.Url; Kind = $entry.Kind; Status = 0; Reason = 'pending'; Attempts = 0; Seconds = 0.0
                Expected = $expected
            })
    }
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    # The pass limit keeps the loop finite when Start-Sleep is mocked; the clock ends it when requests are slow.
    $maxPasses = 1 + [math]::Floor($WindowSeconds / $IntervalSeconds)
    for ($pass = 1; $pass -le $maxPasses; $pass++) {
        $pending = @($results | Where-Object { $_.Reason -cne 'ok' })
        if ($pending.Count -eq 0) { break }
        if ($pass -gt 1) {
            if ($clock.Elapsed.TotalSeconds -ge $WindowSeconds) { break }
            Start-Sleep -Seconds $IntervalSeconds
        }
        foreach ($item in $pending) {
            $item.Attempts++
            try {
                $response = Invoke-WebRequest -Uri $item.Url -Method Get -TimeoutSec $TimeoutSeconds -SkipHttpErrorCheck -ErrorAction Stop
                $item.Status = [int]$response.StatusCode
                if ($item.Status -eq 200) {
                    $item.Reason = if ([string]::Equals((Get-ResponseText $response), $item.Expected, [System.StringComparison]::Ordinal)) { 'ok' } else { 'different' }
                } elseif ($item.Status -eq 404) {
                    $item.Reason = 'missing'
                } else {
                    $item.Reason = 'error'
                }
            } catch {
                $item.Status = 0
                $item.Reason = if (Test-TimeoutError $_.Exception) { 'timeout' } else { 'error' }
            }
            $item.Seconds = [math]::Round($clock.Elapsed.TotalSeconds, 1)
        }
    }
    foreach ($item in $results) {
        [pscustomobject]@{ Path = $item.Path; Url = $item.Url; Kind = $item.Kind; Status = $item.Status; Reason = $item.Reason; Attempts = $item.Attempts; Seconds = $item.Seconds }
    }
}

#endregion

Export-ModuleMember -Function @(
    'ConvertTo-RulebookIndexHtml'
    'Get-PagesPreflightResult'
    'New-RulebookPublishStage'
    'Resolve-RulebookBaseUrl'
    'Resolve-RulebookPublishTarget'
    'Test-RulebookEndpoints'
)
