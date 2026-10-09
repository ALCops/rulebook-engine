#requires -Version 7
<#
.SYNOPSIS
Writes base/off.ruleset.json in a clone of a Rulebook repository: a root level that turns every diagnostic the
analyzers enable by default off.

.DESCRIPTION
Rulebook ships no everything-off level (D25). An organization that wants to start with nothing on and opt in rule by
rule adds its own root level with this script. Run it from the root of a clone of the organization's rulebook
repository (the folder with .github/Rulebook-Settings.json and catalog/diagnostics.json).

The script reads catalog/diagnostics.json and writes base/<slug>.ruleset.json with one entry per diagnostic whose
enabledByDefault is true, at None, sorted like the catalog, without justifications. Diagnostics that are disabled by
default are off already and are not listed. The file belongs to the repository: the update workflow never overwrites
it, and diagnostics that appear in the catalog after it was written arrive through quarantine.

The output is byte-stable: a second run against the same catalog finds the file current and writes nothing. A file
that differs (an older catalog, or your own edits) stops the script unless -Force is set. The file is written next to
its target (<file>.tmp) and moved into place.

The script does not change the settings. It prints the entry to paste first into "levels" of
.github/Rulebook-Settings.json (or says that the settings list the level already) and the next steps: open a pull
request, then let the update workflow, or a local regeneration, add the endpoints, the skeletons and the Change Rule
dropdown line of the new level.

The script is self-contained (PowerShell 7, no module, no download) and writes the same bytes as the function
New-RulebookOffLevel of the engine module Rulebook.Levels. The details are on the user page docs/levels.md in the
ALCops/rulebook repository, linked below.

.PARAMETER RepositoryRoot
The root of the clone. Default: the current folder.

.PARAMETER Name
The display name of the level. Its lowercase form is the slug that names the file and the endpoints, so it must match
^[a-z0-9-]+$ once lowercased. Default: Off

.PARAMETER Force
Overwrites a differing base/<slug>.ruleset.json. Your own edits in that file are lost.

.EXAMPLE
iwr https://raw.githubusercontent.com/ALCops/rulebook-engine/main/scripts/New-RulebookOffLevel.ps1 -OutFile ../New-RulebookOffLevel.ps1
../New-RulebookOffLevel.ps1

Downloads the script next to the clone and writes base/off.ruleset.json in the current folder.

.LINK
https://github.com/ALCops/rulebook/blob/main/docs/levels.md
#>
[CmdletBinding()]
param(
    [string]$RepositoryRoot = '.',
    [string]$Name = 'Off',
    [switch]$Force
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$docsUrl = 'https://github.com/ALCops/rulebook/blob/main/docs/levels.md'
$deltaSchemaUrl = 'https://raw.githubusercontent.com/ALCops/rulebook-engine/v1/schemas/ruleset.delta.schema.json'
$settingsDescription = 'Every known diagnostic off. Opt in through overrides.'
$utf8 = [System.Text.UTF8Encoding]::new($false)
# Prefix order of the diagnostic sort key (Get-DiagnosticSortKey of Rulebook.Generate).
$prefixOrder = @('AL', 'AA', 'AW', 'PTE', 'AS', 'PC', 'AC', 'LC', 'DC', 'FC', 'TA', 'CM')

function ConvertTo-JsonString {
    # A JSON string literal like ConvertTo-JsonString of Rulebook.Generate: only backslash, double quote and control
    # characters are escaped.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    $builder = [System.Text.StringBuilder]::new($Value.Length + 8)
    [void]$builder.Append('"')
    foreach ($character in $Value.ToCharArray()) {
        $code = [int]$character
        if ($code -eq 0x22) { [void]$builder.Append('\"') }
        elseif ($code -eq 0x5C) { [void]$builder.Append('\\') }
        elseif ($code -eq 0x08) { [void]$builder.Append('\b') }
        elseif ($code -eq 0x09) { [void]$builder.Append('\t') }
        elseif ($code -eq 0x0A) { [void]$builder.Append('\n') }
        elseif ($code -eq 0x0C) { [void]$builder.Append('\f') }
        elseif ($code -eq 0x0D) { [void]$builder.Append('\r') }
        elseif ($code -lt 0x20) { [void]$builder.Append(('\u{0:x4}' -f $code)) }
        else { [void]$builder.Append($character) }
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Get-DiagnosticSortKey {
    # The sort key of Rulebook.Generate: prefix in the fixed order, then the number, then the i suffix.
    param([Parameter(Mandatory)][string]$Id)
    $match = [regex]::Match($Id, '^([A-Z]+)([0-9]+)(i?)$')
    if (-not $match.Success -or $match.Groups[2].Value.Length -gt 6) { return '99~' + $Id }
    $index = [System.Array]::IndexOf($prefixOrder, $match.Groups[1].Value)
    $head = if ($index -ge 0) { '{0:00}' -f $index } else { '99' + $match.Groups[1].Value }
    $suffix = if ($match.Groups[3].Value -ceq 'i') { '1' } else { '0' }
    return $head + ('{0:000000}' -f [long]$match.Groups[2].Value) + $suffix
}

# 1. The repository root and the slug.
$root = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RepositoryRoot)
$settingsPath = Join-Path $root '.github' 'Rulebook-Settings.json'
$catalogPath = Join-Path $root 'catalog' 'diagnostics.json'
if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf) -or -not (Test-Path -LiteralPath $catalogPath -PathType Leaf)) {
    throw "Run the script from the root of a clone of your rulebook repository (the folder with .github/Rulebook-Settings.json and catalog/diagnostics.json): $root"
}
$slug = $Name.ToLowerInvariant()
if ($slug -cnotmatch '^[a-z0-9-]+\z') { throw "Level name '$Name' does not lowercase to a slug matching ^[a-z0-9-]+$ (C5)" }

# 2. The catalog: every id enabled by default, sorted by the diagnostic sort key.
try {
    $catalog = [System.IO.File]::ReadAllText($catalogPath, $utf8) | ConvertFrom-Json -AsHashtable -Depth 20 -ErrorAction Stop
} catch {
    throw "Invalid JSON in catalog/diagnostics.json: $($_.Exception.Message)"
}
if ($catalog -isnot [System.Collections.IDictionary] -or $catalog['diagnostics'] -isnot [System.Collections.IList]) { throw 'catalog/diagnostics.json has no diagnostics array' }
$sorted = [System.Collections.Generic.SortedDictionary[string, string]]::new([System.StringComparer]::Ordinal)
$seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
foreach ($entry in $catalog['diagnostics']) {
    if ($entry -isnot [System.Collections.IDictionary]) { throw 'catalog/diagnostics.json has an entry that is not an object' }
    $id = [string]$entry['id']
    if ([string]::IsNullOrEmpty($id)) { throw 'catalog/diagnostics.json has an entry without an id' }
    if (-not $seen.Add($id)) { throw "catalog/diagnostics.json lists $id twice" }
    if (-not $entry.Contains('enabledByDefault') -or $entry['enabledByDefault'] -isnot [bool]) { throw "catalog/diagnostics.json: $id has no boolean enabledByDefault" }
    if ($entry['enabledByDefault']) { $sorted[(Get-DiagnosticSortKey -Id $id) + '|' + $id] = $id }
}
$ids = @($sorted.Values)
if ($ids.Count -eq 0) { Write-Warning "catalog/diagnostics.json lists no diagnostic enabled by default; base/$slug.ruleset.json gets an empty rules array" }

# 3. The text, line for line as ConvertTo-RulesetJson writes it.
$description = 'Level {0}, the root. Every diagnostic the analyzers enable by default, at None ({1} ids from catalog/diagnostics.json). Written once by New-RulebookOffLevel and owned by this repository: opt in with overrides scoped to levels ["{0}"] or by editing this file. Ids newer than this file arrive through quarantine.' -f $slug, $ids.Count
$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add('{')
$lines.Add('  "$schema": ' + (ConvertTo-JsonString $deltaSchemaUrl) + ',')
$lines.Add('  "name": ' + (ConvertTo-JsonString "Rulebook $Name") + ',')
$lines.Add('  "description": ' + (ConvertTo-JsonString $description) + ',')
if ($ids.Count -eq 0) {
    $lines.Add('  "rules": []')
} else {
    $lines.Add('  "rules": [')
    for ($i = 0; $i -lt $ids.Count; $i++) {
        $lines.Add('    { "id": ' + (ConvertTo-JsonString $ids[$i]) + ', "action": "None" }' + $(if ($i -lt $ids.Count - 1) { ',' } else { '' }))
    }
    $lines.Add('  ]')
}
$lines.Add('}')
$bytes = $utf8.GetBytes(($lines -join "`n") + "`n")

# 4. Write, unless the file is current; a differing file needs -Force.
$file = "base/$slug.ruleset.json"
$target = Join-Path $root 'base' "$slug.ruleset.json"
$current = $false
if (Test-Path -LiteralPath $target -PathType Leaf) {
    if ([System.Linq.Enumerable]::SequenceEqual([byte[]][System.IO.File]::ReadAllBytes($target), [byte[]]$bytes)) {
        $current = $true
    } elseif (-not $Force) {
        throw "$file exists and differs; it is owned by this repository. Use -Force to overwrite it (your own edits in it are lost)"
    }
}
if ($current) {
    Write-Host "$file is current ($($ids.Count) ids at None)"
} else {
    $parent = Split-Path -Parent $target
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { [void][System.IO.Directory]::CreateDirectory($parent) }
    try {
        [System.IO.File]::WriteAllBytes("$target.tmp", $bytes)
        [System.IO.File]::Move("$target.tmp", $target, $true)
    } catch {
        Remove-Item -LiteralPath "$target.tmp" -Force -ErrorAction SilentlyContinue
        throw
    }
    Write-Host "Wrote $file ($($ids.Count) ids at None)"
}

# 5. The settings entry and the next steps.
$settingsEntry = '{ "name": ' + (ConvertTo-JsonString $Name) + ', "description": ' + (ConvertTo-JsonString $settingsDescription) + ' }'
$listedAs = $null
try {
    $settings = [System.IO.File]::ReadAllText($settingsPath, $utf8) | ConvertFrom-Json -AsHashtable -Depth 10 -ErrorAction Stop
} catch {
    throw "Invalid JSON in .github/Rulebook-Settings.json: $($_.Exception.Message)"
}
if ($settings -is [System.Collections.IDictionary]) {
    foreach ($level in @($settings['levels'] | Where-Object { $_ -is [System.Collections.IDictionary] })) {
        $levelName = [string]$level['name']
        if ($levelName -and $levelName.ToLowerInvariant() -ceq $slug) { $listedAs = $levelName }
    }
}
Write-Host ''
if ($null -ne $listedAs) {
    Write-Host "Already listed in the settings as $listedAs."
} else {
    Write-Host 'Paste this entry first into "levels" of .github/Rulebook-Settings.json:'
    Write-Host "    $settingsEntry,"
}
Write-Host ''
Write-Host 'Next steps:'
Write-Host "  1. Commit $file and the settings change and open a pull request. Validate reports C11 and C12 until the endpoints and skeletons of the level exist."
Write-Host '  2. After the merge, run the workflow "Update Rulebook System Files" with "Resolve the latest commit" off. Its pull request adds'
Write-Host "     rulesets/$slug*.ruleset.json, the skeletons and the '- $slug' line of the Change Rule form."
Write-Host '     Or regenerate locally and commit the result: Update-RulebookEndpoints -RepositoryRoot . (module Rulebook.Generate) and'
Write-Host '     New-RulebookSkeleton -SettingsPath .github/Rulebook-Settings.json -OutputPath skeletons (module Rulebook.Template).'
Write-Host "Details: the user page docs/levels.md in the ALCops/rulebook repository, $docsUrl"

[pscustomobject]@{
    File           = $file
    Count          = $ids.Count
    Slug           = $slug
    SettingsEntry  = $settingsEntry
    SettingsListed = $null -ne $listedAs
}
