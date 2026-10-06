#requires -Version 7
<#
.SYNOPSIS
Downloads the published skeletons of one Rulebook level into an AL project, one ruleset file per stage.

.DESCRIPTION
Reads <BaseUrl>/rulebook.json, the list of the levels and stages a Rulebook site publishes, checks that -Level is
one of them, and downloads <BaseUrl>/skeletons/<level>.<stage>.ruleset.json for every stage into
<OutputPath>/<stage>.ruleset.json: .rulebook/default.ruleset.json, .rulebook/ci.ruleset.json and so on. Each file
includes the endpoint of its stage; the project's own exceptions go into its rules. The files are written exactly as
the site serves them, so they are the same files a manual download gives.

Nothing is written until every download and check has succeeded; the files are then written one by one next to their
targets (<file>.tmp) and moved into place. The manifest is read and -Level is resolved before any skeleton is
requested, an existing target file stops the script unless -Force is set, every skeleton is downloaded and checked
(one include, of the endpoint of its level and stage), and the output folder and every existing target are checked
for writing before the first file is written. Redirects are not followed, because the AL compiler does not follow
them either: -BaseUrl must be the final address of the site. Every failure throws, so 'pwsh -File' exits with 1.

The script is self-contained (PowerShell 7, no module) and only downloads: it does not change any settings file. It
prints the settings that point VS Code and AL-Go at the files, with paths relative to the current folder: run it from
the AL project root, the folder with app.json. The details are on the user page docs/al-project.md in the
ALCops/rulebook repository (written with WP06), linked below.

.PARAMETER BaseUrl
The address of the published Rulebook site, the baseUrl of the organization's rulebook repository, for example
https://contoso.github.io/rulebook. A trailing slash is ignored. https is required; http is accepted only for a
loopback host (127.0.0.1, localhost, [::1]), for a site served locally.

.PARAMETER Level
The level to download, by its slug (strict) or its name (Strict, any casing).

.PARAMETER OutputPath
The folder that receives one <stage>.ruleset.json per stage, relative to the current location. Default: .rulebook

.PARAMETER Force
Overwrites existing files. Without it the script stops when any target file exists, because a downloaded skeleton
replaces the project exceptions in the existing file's rules.

.EXAMPLE
./Get-RulebookSkeletons.ps1 -BaseUrl https://contoso.github.io/rulebook -Level strict

Writes .rulebook/default.ruleset.json, .rulebook/ci.ruleset.json and .rulebook/vnext.ruleset.json in the current
folder, each including the strict endpoint of its stage.

.EXAMPLE
Set-Location ./MyApp
./Get-RulebookSkeletons.ps1 -BaseUrl https://contoso.github.io/rulebook -Level Recommended -Force

Replaces the files in .rulebook/ of the AL project in ./MyApp with the skeletons of the Recommended level. The
settings it prints are relative to ./MyApp, for example "al.ruleSetPath": ".rulebook/default.ruleset.json".

.LINK
https://github.com/ALCops/rulebook/blob/main/docs/al-project.md
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BaseUrl,
    [Parameter(Mandatory)][string]$Level,
    [string]$OutputPath = '.rulebook',
    [switch]$Force
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$docsUrl = 'https://github.com/ALCops/rulebook/blob/main/docs/al-project.md'
$utf8 = [System.Text.UTF8Encoding]::new($false)

function Get-RulebookResponse {
    # GET without following redirects: { Status, Bytes, Location }. With -MaximumRedirection 0 Invoke-WebRequest
    # returns the 3xx response and also writes an error; -ErrorAction Stop would turn that into an exception without
    # the response, so the error is collected and rethrown only when there is no response at all.
    # A refused connection, a DNS or a TLS failure terminates the statement despite SilentlyContinue, hence the catch.
    param([Parameter(Mandatory)][string]$Uri)
    $requestErrors = $null
    try {
        $response = Invoke-WebRequest -Uri $Uri -Method Get -TimeoutSec 15 -MaximumRedirection 0 -SkipHttpErrorCheck -ErrorAction SilentlyContinue -ErrorVariable requestErrors
    } catch {
        throw "Cannot read ${Uri}: $($_.Exception.Message)"
    }
    if ($null -eq $response) {
        $reason = if (@($requestErrors).Count -gt 0) { @($requestErrors)[0].Exception.Message } else { 'no response' }
        throw "Cannot read ${Uri}: $reason"
    }
    # The bytes as served: RawContentStream on a real response (Content is a decoded string for text types), else
    # Content as bytes or as text (a test double). Direct assignments: an if expression would unroll a byte[].
    [byte[]]$bytes = @()
    $stream = $response.PSObject.Properties['RawContentStream']
    $content = $response.PSObject.Properties['Content']
    if ($null -ne $stream -and $stream.Value -is [System.IO.MemoryStream]) {
        $bytes = $stream.Value.ToArray()
    } elseif ($null -ne $content -and $content.Value -is [byte[]]) {
        $bytes = $content.Value
    } elseif ($null -ne $content -and $null -ne $content.Value) {
        $bytes = $utf8.GetBytes([string]$content.Value)
    }
    # Headers is a Dictionary[string, IEnumerable[string]] on a real response; matched case-insensitively.
    $location = $null
    $headers = $response.PSObject.Properties['Headers']
    if ($null -ne $headers -and $headers.Value -is [System.Collections.IDictionary]) {
        foreach ($key in @($headers.Value.Keys)) {
            if ([string]::Equals([string]$key, 'Location', [System.StringComparison]::OrdinalIgnoreCase)) { $location = [string](@($headers.Value[$key])[0]) }
        }
    }
    return [pscustomobject]@{ Status = [int]$response.StatusCode; Bytes = $bytes; Location = $location }
}

function ConvertTo-UrlKey {
    # A URL with its scheme and host (and port) lowercased and its path as it is, for comparing addresses.
    param([Parameter(Mandatory)][string]$Url)
    if ($Url -match '^([A-Za-z][A-Za-z0-9+.-]*://[^/]*)(.*)\z') { return $Matches[1].ToLowerInvariant() + $Matches[2] }
    return $Url
}

function Get-ResponseFailure {
    # The reason a response is not a 200, as a sentence about Uri; $null for a 200.
    param([Parameter(Mandatory)]$Response, [Parameter(Mandatory)][string]$Uri)
    if ($Response.Status -eq 200) { return $null }
    if ($Response.Status -ge 300 -and $Response.Status -lt 400) {
        $target = if ($Response.Location) { " to $($Response.Location)" } else { '' }
        return "$Uri answers with a redirect (HTTP $($Response.Status))$target; the AL compiler does not follow redirects, so use the final address as -BaseUrl."
    }
    return "$Uri answers with HTTP $($Response.Status)."
}

function ConvertFrom-ResponseJson {
    # The body parsed as JSON into hashtables; a UTF-8 byte order mark is skipped for parsing only.
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes)
    $text = $utf8.GetString($Bytes)
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
    return ConvertFrom-Json -InputObject $text -AsHashtable -NoEnumerate -ErrorAction Stop
}

function Get-ManifestEntry {
    # The levels or stages of the manifest as { Name, Slug }; throws with the reason when the shape is wrong. Slugs
    # become file names and URL segments, so anything but ^[a-z0-9-]+$ is refused. Unknown keys are ignored.
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Manifest, [Parameter(Mandatory)][string]$Key)
    if (-not $Manifest.Contains($Key) -or $Manifest[$Key] -isnot [System.Collections.IList] -or $Manifest[$Key].Count -eq 0) {
        throw "'$Key' is missing or not a non-empty array"
    }
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($item in $Manifest[$Key]) {
        if ($item -isnot [System.Collections.IDictionary] -or $item['name'] -isnot [string] -or $item['slug'] -isnot [string]) {
            throw "every entry of '$Key' needs a name and a slug"
        }
        if ($item['slug'] -cnotmatch '^[a-z0-9-]+\z') { throw "'$Key' has the slug '$($item['slug'])', which is not ^[a-z0-9-]+$" }
        if (-not $seen.Add($item['slug'])) { throw "'$Key' lists the slug '$($item['slug'])' twice" }
        [pscustomobject]@{ Name = $item['name']; Slug = $item['slug'] }
    }
}

# 1. The base URL: https, or http for a loopback host only (a site served locally, as the engine CI does); a host, no
#    query, fragment, whitespace, quote or backslash; one trailing slash dropped.
$BaseUrl = $BaseUrl.Trim()
if ($BaseUrl.EndsWith('/')) { $BaseUrl = $BaseUrl.Substring(0, $BaseUrl.Length - 1) }
$baseUrlError = "-BaseUrl must be the address of the published Rulebook site, for example https://contoso.github.io/rulebook (https; http only for 127.0.0.1, localhost or [::1]; no query or fragment): '$BaseUrl'"
if ($BaseUrl -notmatch '^(https?)://([^\s/?#"\\]+)(/[^\s?#"\\]+)*\z') { throw $baseUrlError }
if ($Matches[1] -eq 'http') {
    $authority = $Matches[2]
    $hostName = if ($authority.StartsWith('[')) { $authority.Substring(0, $authority.IndexOf(']') + 1) } else { $authority.Split(':')[0] }
    if ($hostName -notin '127.0.0.1', 'localhost', '[::1]') { throw $baseUrlError }
}

# 2. The manifest.
$manifestUrl = "$BaseUrl/rulebook.json"
$response = Get-RulebookResponse -Uri $manifestUrl
if ($response.Status -eq 404) {
    throw "$manifestUrl is missing: the site was published before rulebook.json existed, or -BaseUrl is wrong. Check -BaseUrl against the baseUrl of the rulebook repository; if it is right, run its Publish workflow once with an engine that publishes rulebook.json."
}
$failure = Get-ResponseFailure -Response $response -Uri $manifestUrl
if ($failure) { throw $failure }

# 3. Its shape.
try {
    $manifest = ConvertFrom-ResponseJson -Bytes $response.Bytes
    if ($manifest -isnot [System.Collections.IDictionary]) { throw 'the root is not an object' }
    $levels = @(Get-ManifestEntry -Manifest $manifest -Key 'levels')
    $stages = @(Get-ManifestEntry -Manifest $manifest -Key 'stages')
} catch {
    throw "$manifestUrl is not a Rulebook manifest: $($_.Exception.Message)"
}
$publishedBaseUrl = if ($manifest['baseUrl'] -is [string]) { $manifest['baseUrl'] } else { $null }

# 4. The level, by slug or by name, before any skeleton is requested.
$wanted = $Level.Trim()
$selected = @($levels | Where-Object { [string]::Equals($_.Slug, $wanted, [System.StringComparison]::Ordinal) })
if ($selected.Count -eq 0) { $selected = @($levels | Where-Object { [string]::Equals($_.Name, $wanted, [System.StringComparison]::OrdinalIgnoreCase) }) }
if ($selected.Count -eq 0) {
    throw "Level '$Level' is not published at $BaseUrl. Published levels: $(($levels | ForEach-Object Slug) -join ', ') (use the slug or the name)."
}
$levelSlug = $selected[0].Slug

# 5. The targets, relative to the PowerShell location ([System.IO.File] would resolve against the process folder).
$outputFull = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath).TrimEnd('\', '/')
$here = (Get-Location).ProviderPath
$targets = foreach ($stage in $stages) {
    $file = Join-Path $outputFull "$($stage.Slug).ruleset.json"
    # The written file is shown relative to the current location, or as the full path when outside it.
    $display = [System.IO.Path]::GetRelativePath($here, $file).Replace('\', '/')
    if ($display.StartsWith('../', [System.StringComparison]::Ordinal) -or [System.IO.Path]::IsPathRooted($display)) { $display = $file }
    # The endpoint the skeleton must include: the default stage has no suffix (as Get-EndpointFileName in the engine).
    $endpoint = if ($stage.Slug -ceq 'default') { "rulesets/$levelSlug.ruleset.json" } else { "rulesets/$levelSlug.$($stage.Slug).ruleset.json" }
    [pscustomobject]@{
        Stage    = $stage.Slug
        Url      = "$BaseUrl/skeletons/$levelSlug.$($stage.Slug).ruleset.json"
        File     = $file
        Display  = $display
        # The path in the settings: relative to the current folder, which the output asks to be the AL project root.
        Setting  = [System.IO.Path]::GetRelativePath($here, $file).Replace('\', '/')
        Endpoint = $endpoint
        Bytes    = $null
    }
}

# 6. Existing files stop the run before any download.
$existing = @($targets | Where-Object { Test-Path -LiteralPath $_.File } | ForEach-Object Display)
if ($existing.Count -gt 0 -and -not $Force) {
    throw "These files exist already: $($existing -join ', '). Use -Force to overwrite them (your project exceptions in rules would be lost; copy them first)."
}

# 7. Every skeleton into memory and checked, before the first write.
foreach ($target in $targets) {
    $response = Get-RulebookResponse -Uri $target.Url
    $failure = Get-ResponseFailure -Response $response -Uri $target.Url
    if ($failure) { throw "Nothing was written. $failure" }
    try {
        $skeleton = ConvertFrom-ResponseJson -Bytes $response.Bytes
    } catch {
        throw "Nothing was written. $($target.Url) is not JSON: $($_.Exception.Message)"
    }
    # A direct assignment: an if expression would unroll a one-entry array into the entry.
    $includes = $null
    if ($skeleton -is [System.Collections.IDictionary] -and $skeleton.Contains('includedRuleSets')) { $includes = $skeleton['includedRuleSets'] }
    if ($includes -isnot [System.Collections.IList] -or $includes.Count -ne 1 -or $includes[0] -isnot [System.Collections.IDictionary] -or $includes[0]['path'] -isnot [string]) {
        throw "Nothing was written. $($target.Url) is not a Rulebook skeleton: it needs exactly one entry in includedRuleSets with a path."
    }
    $include = $includes[0]['path']
    # The include must be the endpoint of this level and stage under the base URL the site was published with or under
    # -BaseUrl. An include under neither points at another site; one with another path is a wrong or stale skeleton.
    # Scheme and host compare case-insensitively, the path ordinally.
    $includeBase = if ($publishedBaseUrl) { $publishedBaseUrl } else { $BaseUrl }
    $includeKey = ConvertTo-UrlKey $include
    $prefix = $null
    foreach ($candidate in $includeBase, $BaseUrl) {
        $key = (ConvertTo-UrlKey $candidate) + '/'
        if ($includeKey.StartsWith($key, [System.StringComparison]::Ordinal)) { $prefix = $key; break }
    }
    if ($null -eq $prefix) {
        throw "Nothing was written. $($target.Url) includes $include, which points at another site than $includeBase; the skeleton was not written."
    }
    if ($includeKey.Substring($prefix.Length) -cne $target.Endpoint) {
        throw "Nothing was written. $($target.Url) includes $include, but the skeleton of level $levelSlug and stage $($target.Stage) must include $includeBase/$($target.Endpoint): the site serves a wrong or stale skeleton."
    }
    # A site read through another address than its baseUrl (a local copy, a proxy) still includes the published URL.
    if ($publishedBaseUrl -and (ConvertTo-UrlKey $publishedBaseUrl) -cne (ConvertTo-UrlKey $BaseUrl)) {
        Write-Warning "$($target.Display): the site was published with baseUrl $publishedBaseUrl, not $BaseUrl; the compiler will fetch $include."
    }
    $target.Bytes = $response.Bytes
}

# 8. The files, byte for byte as served, after a check that each can be written: first every file as <file>.tmp
#    next to its target, then moved into place. Leftover .tmp files are removed when writing fails.
try {
    [void][System.IO.Directory]::CreateDirectory($outputFull)
} catch {
    throw "No file was written. The folder $outputFull cannot be created: $($_.Exception.Message)"
}
foreach ($target in $targets) {
    if (Test-Path -LiteralPath $target.File -PathType Container) { throw "No file was written. $($target.Display) is a folder, not a file." }
    $item = Get-Item -LiteralPath $target.File -Force -ErrorAction SilentlyContinue
    if ($null -ne $item -and $item.IsReadOnly) { throw "No file was written. $($target.Display) is read-only." }
}
$replaced = [System.Collections.Generic.List[string]]::new()
try {
    foreach ($target in $targets) { [System.IO.File]::WriteAllBytes("$($target.File).tmp", $target.Bytes) }
    foreach ($target in $targets) {
        [System.IO.File]::Move("$($target.File).tmp", $target.File, $true)
        $replaced.Add($target.Display)
        Write-Host "$($target.Display) <- $($target.Url)"
    }
} catch {
    foreach ($target in $targets) { Remove-Item -LiteralPath "$($target.File).tmp" -Force -ErrorAction SilentlyContinue }
    $untouched = @($targets | Where-Object { $_.Display -cnotin $replaced } | ForEach-Object Display)
    $done = if ($replaced.Count -gt 0) { $replaced -join ', ' } else { 'none' }
    $left = if ($untouched.Count -gt 0) { $untouched -join ', ' } else { 'none' }
    throw "Writing the files failed: $($_.Exception.Message). Written: $done. Left untouched: $left."
}

# 9. The settings that use the files, and one result per file.
Write-Host ''
Write-Host 'Settings paths are relative to the current folder; run the script from the AL project root (the folder with app.json).'
foreach ($target in $targets) {
    switch -CaseSensitive ($target.Stage) {
        'default' { Write-Host "VS Code, .vscode/settings.json: `"al.ruleSetPath`": `"$($target.Setting)`"" }
        'ci' { Write-Host "AL-Go, .AL-Go/settings.json: `"rulesetFile`": `"$($target.Setting)`", `"enableExternalRulesets`": true" }
        'vnext' { Write-Host "AL-Go next major, .github/NextMajor.settings.json: `"rulesetFile`": `"$($target.Setting)`"" }
        default { Write-Host "Stage $($target.Stage): point the build of that stage at $($target.Setting)" }
    }
}
Write-Host 'Exceptions go into rules of each file. Reload the VS Code window after changing a file.'
Write-Host "Details: the user page docs/al-project.md in the ALCops/rulebook repository (written with WP06), $docsUrl"
foreach ($target in $targets) {
    [pscustomobject]@{ Stage = $target.Stage; File = $target.File; Url = $target.Url; Bytes = $target.Bytes.Length }
}
