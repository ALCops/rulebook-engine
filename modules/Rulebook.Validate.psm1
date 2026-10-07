#requires -Version 7.4
# Rulebook.Validate: checks C1 to C15 of docs/ARCHITECTURE.md section 5.3 on an organization rulebook repository.
# Each check reads the files on its own and never throws on bad input: a problem is a finding. The readers and the
# precedence come from Rulebook.Generate; the regeneration check C12 is Update-RulebookEndpoints -WhatIf, run only
# when the generator's prerequisites have no error findings.

Set-StrictMode -Version 3.0
Import-Module (Join-Path $PSScriptRoot 'Rulebook.Generate.psd1')

$script:SchemaDir = Join-Path $PSScriptRoot '..' 'schemas'
$script:Actions = @('Error', 'Warning', 'Info', 'Hidden', 'None')
$script:SettingsPath = '.github/Rulebook-Settings.json'
$script:CatalogPath = 'catalog/diagnostics.json'
$script:ScanStatePath = 'catalog/scan-state.json'
$script:TwinsPath = 'base/twins.json'
$script:OverridesPath = 'overrides.json'
$script:ProfileSchemas = @{
    delta    = 'ruleset.delta.schema.json'
    endpoint = 'ruleset.endpoint.schema.json'
    skeleton = 'ruleset.skeleton.schema.json'
}

#region Helpers

function Add-Finding {
    # Blocking marks a finding that makes the generator unable to run (assumption 11): C12 is then skipped.
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Rule,
        [Parameter(Mandatory)][ValidateSet('error', 'warning')][string]$Severity,
        [AllowNull()][AllowEmptyString()][string]$File,
        [AllowNull()][AllowEmptyString()][string]$Id,
        [Parameter(Mandatory)][string]$Message,
        [switch]$Blocking
    )
    $Context.Findings.Add([pscustomobject]@{
            PSTypeName = 'Rulebook.Finding'
            Rule       = $Rule
            Severity   = $Severity
            File       = if ([string]::IsNullOrEmpty($File)) { $null } else { $File }
            Id         = if ([string]::IsNullOrEmpty($Id)) { $null } else { $Id }
            Message    = $Message
        })
    if ($Blocking -and $Severity -eq 'error' -and -not $Context.Blocking.Contains($Rule)) { $Context.Blocking.Add($Rule) }
}

function Get-FullPath {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Path)
    return Join-Path $Context.Root $Path
}

function Test-RepoFile {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Path)
    return Test-Path -LiteralPath (Get-FullPath $Context $Path) -PathType Leaf
}

function Read-JsonOrNull {
    # The parsed file as a hashtable, or $null when it is not a JSON object (no finding; the caller decides).
    # The text is kept in the context, so Test-SchemaFile validates it without reading the file again.
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Path)
    $text = Get-Content -LiteralPath (Get-FullPath $Context $Path) -Raw
    $Context.Texts[$Path] = $text
    try {
        $json = $text | ConvertFrom-Json -AsHashtable -Depth 20 -ErrorAction Stop
    } catch {
        return $null
    }
    if ($json -isnot [System.Collections.IDictionary]) { return $null }
    return $json
}

function Test-SchemaFile {
    # Validates a file against a profile file under schemas/ (never the hub). Adds one finding with the first
    # schema error and returns $false when the file does not match.
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Schema,
        [Parameter(Mandatory)][string]$Rule,
        [switch]$Blocking
    )
    $schemaErrors = $null
    $schemaFile = Join-Path $script:SchemaDir $Schema
    $valid = if ($Context.Texts.ContainsKey($Path)) {
        Test-Json -Json $Context.Texts[$Path] -SchemaFile $schemaFile -ErrorAction SilentlyContinue -ErrorVariable schemaErrors
    } else {
        Test-Json -Path (Get-FullPath $Context $Path) -SchemaFile $schemaFile -ErrorAction SilentlyContinue -ErrorVariable schemaErrors
    }
    if ($valid) { return $true }
    $first = if ($schemaErrors -and $schemaErrors.Count -gt 0) { $schemaErrors[0].Exception.Message } else { 'unknown schema error' }
    Add-Finding -Context $Context -Rule $Rule -Severity error -File $Path -Message "$Path does not match $Schema`: $first" -Blocking:$Blocking
    return $false
}

function Get-RulesFiles {
    # The ruleset files by folder, with the schema profile of the folder (naming.md section 2).
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Returns the list of rules files')]
    param([Parameter(Mandatory)][string]$Root)
    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($folder in @(
            @{ Name = 'base'; Filter = '*.ruleset.json'; Profile = 'delta' }
            @{ Name = 'stages'; Filter = '*.json'; Profile = 'delta' }
            @{ Name = 'rulesets'; Filter = '*.json'; Profile = 'endpoint' }
            @{ Name = 'skeletons'; Filter = '*.json'; Profile = 'skeleton' }
        )) {
        $dir = Join-Path $Root $folder.Name
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
        $names = [string[]]@(Get-ChildItem -LiteralPath $dir -File -Filter $folder.Filter | Where-Object { $_.Name -like $folder.Filter } | ForEach-Object Name)
        [System.Array]::Sort($names, [System.StringComparer]::Ordinal)
        foreach ($name in $names) { $result.Add([pscustomobject]@{ Path = "$($folder.Name)/$name"; Profile = $folder.Profile }) }
    }
    return $result.ToArray()
}

function Get-FolderFileName {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Folder)
    $dir = Join-Path $Root $Folder
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return [string[]]@() }
    $names = [string[]]@(Get-ChildItem -LiteralPath $dir -File | ForEach-Object Name)
    [System.Array]::Sort($names, [System.StringComparer]::Ordinal)
    return $names
}

function ConvertTo-LenientRuleMap {
    # id -> { Action, Justification } from a parsed ruleset, skipping malformed rules; the first entry of an id wins.
    # Only for the analysis checks (C5 chain, C7, C8, C9, C13, C15); the strict reader is Read-RulesetFile.
    param($Json)
    $map = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::Ordinal)
    if ($null -eq $Json -or $Json['rules'] -isnot [System.Collections.IList]) { return , $map }
    foreach ($rule in $Json['rules']) {
        if ($rule -isnot [System.Collections.IDictionary]) { continue }
        $id = [string]$rule['id']
        $action = [string]$rule['action']
        if ([string]::IsNullOrEmpty($id) -or $action -cnotin $script:Actions -or $map.Contains($id)) { continue }
        $map[$id] = [pscustomobject]@{ Action = $action; Justification = $rule['justification'] }
    }
    return , $map
}

function Get-RuleIdList {
    param($Json)
    if ($null -eq $Json -or $Json['rules'] -isnot [System.Collections.IList]) { return [string[]]@() }
    return [string[]]@($Json['rules'] | Where-Object { $_ -is [System.Collections.IDictionary] -and -not [string]::IsNullOrEmpty([string]$_['id']) } | ForEach-Object { [string]$_['id'] })
}

function Test-UnusedListed {
    param([string[]]$Unused, [Parameter(Mandatory)][string]$Path)
    return $Path -cin $Unused
}

function Get-SortedFinding {
    # By rule number, then file ($null first), then id, ordinally; the insertion index keeps equal keys stable.
    param([object[]]$Findings)
    $sorted = [System.Collections.Generic.SortedDictionary[string, object]]::new([System.StringComparer]::Ordinal)
    for ($i = 0; $i -lt $Findings.Count; $i++) {
        $finding = $Findings[$i]
        $number = [int]($finding.Rule -replace '[^0-9]', '')
        # [char]0 sorts below every character, so 'stages/ci.json' comes before 'stages/ci.json.bak'.
        $separator = [char]0
        $key = '{0:000}{4}{1}{4}{2}{4}{3:000000}' -f $number, [string]$finding.File, [string]$finding.Id, $i, $separator
        $sorted[$key] = $finding
    }
    return $sorted.Values
}

#endregion

#region Checks

function Test-SettingsFile {
    # C5. Returns the normalised settings, or $null when the file is missing or not JSON (validation stops).
    param([Parameter(Mandatory)]$Context)
    $path = $script:SettingsPath
    if (-not (Test-RepoFile $Context $path)) {
        Add-Finding -Context $Context -Rule C5 -Severity error -File $path -Message "$path is missing; nothing else can be checked" -Blocking
        return $null
    }
    $raw = Read-JsonOrNull $Context $path
    if ($null -eq $raw) {
        Add-Finding -Context $Context -Rule C5 -Severity error -File $path -Message "$path is not valid JSON; nothing else can be checked" -Blocking
        return $null
    }
    $before = $Context.Findings.Count
    $normalise = {
        param($items, [bool]$isLevel)
        @(foreach ($item in @($items)) {
                if ($item -isnot [System.Collections.IDictionary] -or $item['name'] -isnot [string]) { continue }
                $name = [string]$item['name']
                $basedOn = if ($isLevel -and $item['basedOn'] -is [string]) { [string]$item['basedOn'] } else { $null }
                [pscustomobject]@{
                    Name        = $name
                    Slug        = $name.ToLowerInvariant()
                    BasedOn     = if ($basedOn) { $basedOn.ToLowerInvariant() } else { $null }
                    Description = $item['description']
                }
            })
    }
    $levels = @(& $normalise $raw['levels'] $true)
    $stages = @(& $normalise $raw['stages'] $false)

    foreach ($kind in @(@{ Name = 'levels'; Items = $levels }, @{ Name = 'stages'; Items = $stages })) {
        $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        foreach ($item in $kind.Items) {
            if ($item.Slug -cnotmatch '^[a-z0-9-]+\z') {
                Add-Finding -Context $Context -Rule C5 -Severity error -File $path -Message "$($kind.Name) entry '$($item.Name)' does not lowercase to a slug matching ^[a-z0-9-]+$" -Blocking
            } elseif (-not $seen.Add($item.Slug)) {
                Add-Finding -Context $Context -Rule C5 -Severity error -File $path -Message "$($kind.Name) slug '$($item.Slug)' is used twice" -Blocking
            }
        }
    }
    $stageSlugs = [string[]]@($stages | ForEach-Object Slug)
    if ($stages.Count -gt 0 -and 'default' -cnotin $stageSlugs) {
        Add-Finding -Context $Context -Rule C5 -Severity error -File $path -Message 'stages has no default stage; it is mandatory (D26)' -Blocking
    }
    $twinsSetting = 'both'
    if ($raw.Contains('twins') -and $null -ne $raw['twins']) {
        $twinsSetting = [string]$raw['twins']
        if ($twinsSetting -cnotin 'both', 'appsource', 'pte') {
            Add-Finding -Context $Context -Rule C5 -Severity error -File $path -Message "twins is '$twinsSetting'; allowed are both, appsource and pte" -Blocking
        }
    }
    if ($raw['quarantine'] -is [System.Collections.IDictionary]) {
        foreach ($key in 'stages', 'prereleaseStages') {
            $values = $raw['quarantine'][$key]
            if ($values -isnot [System.Collections.IList]) { continue }
            foreach ($value in $values) {
                if ([string]$value -cnotin $stageSlugs) {
                    Add-Finding -Context $Context -Rule C5 -Severity error -File $path -Message "quarantine.$key names '$value', which is not a stage slug" -Blocking
                }
            }
        }
    }
    if ($raw['baseUrl'] -is [string] -and ([string]$raw['baseUrl']).EndsWith('/')) {
        Add-Finding -Context $Context -Rule C5 -Severity error -File $path -Message 'baseUrl ends with a slash' -Blocking
    }
    # The schema reports only what the explicit checks above did not: one finding per cause.
    if ($Context.Findings.Count -eq $before) {
        $null = Test-SchemaFile -Context $Context -Path $path -Schema 'rulebook-settings.schema.json' -Rule C5 -Blocking
    }
    $unused = [string[]]@(if ($raw['unusedRulebookFiles'] -is [System.Collections.IList]) { $raw['unusedRulebookFiles'] | ForEach-Object { [string]$_ } })
    return [pscustomobject]@{
        Levels       = $levels
        Stages       = $stages
        StageSlugs   = $stageSlugs
        LevelSlugs   = [string[]]@($levels | ForEach-Object Slug)
        TwinsSetting = $twinsSetting
        Unused       = $unused
        Valid        = ($Context.Findings.Count -eq $before)
    }
}

function Test-CatalogFile {
    # C14 for the catalog. Returns the catalog map from Read-Catalog, or $null.
    param([Parameter(Mandatory)]$Context)
    $path = $script:CatalogPath
    if (-not (Test-RepoFile $Context $path)) {
        Add-Finding -Context $Context -Rule C14 -Severity error -File $path -Message "$path is missing; C7, the default part of C11 and C12 are skipped" -Blocking
        return $null
    }
    if ($null -eq (Read-JsonOrNull $Context $path)) {
        Add-Finding -Context $Context -Rule C14 -Severity error -File $path -Message "$path is not valid JSON" -Blocking
        return $null
    }
    if (-not (Test-SchemaFile -Context $Context -Path $path -Schema 'rulebook-catalog.schema.json' -Rule C14 -Blocking)) { return $null }
    try {
        return Read-Catalog -Path (Get-FullPath $Context $path)
    } catch {
        Add-Finding -Context $Context -Rule C14 -Severity error -File $path -Message $_.Exception.Message -Blocking
        return $null
    }
}

function Test-TwinsFile {
    # C14 and C2 for base/twins.json. Returns the twin ids for C7.
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$TwinsSetting)
    $path = $script:TwinsPath
    if (-not (Test-RepoFile $Context $path)) {
        if ($TwinsSetting -cin 'appsource', 'pte') {
            Add-Finding -Context $Context -Rule C14 -Severity error -File $path -Message "$path is missing and twins is '$TwinsSetting'" -Blocking
        }
        return [string[]]@()
    }
    $json = Read-JsonOrNull $Context $path
    if ($null -eq $json) {
        Add-Finding -Context $Context -Rule C14 -Severity error -File $path -Message "$path is not valid JSON" -Blocking
        return [string[]]@()
    }
    $null = Test-SchemaFile -Context $Context -Path $path -Schema 'rulebook-twins.schema.json' -Rule C14 -Blocking
    # @(if ...) and not if { @(...) }: an if statement unrolls a one-element array into its element.
    $pairs = @(if ($json['pairs'] -is [System.Collections.IList]) { $json['pairs'] | Where-Object { $_ -is [System.Collections.IDictionary] } })
    if ($json.Contains('count') -and $json['count'] -ne $pairs.Count) {
        Add-Finding -Context $Context -Rule C14 -Severity error -File $path -Message "count is $($json['count']) but there are $($pairs.Count) pairs" -Blocking
    }
    $ids = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($pair in $pairs) {
        foreach ($side in [string]$pair['pte'], [string]$pair['appsource']) {
            if ([string]::IsNullOrEmpty($side)) { continue }
            if (-not $seen.Add($side)) {
                Add-Finding -Context $Context -Rule C2 -Severity error -File $path -Id $side -Message "$side is in two pairs" -Blocking
            } else {
                $ids.Add($side)
            }
        }
    }
    return $ids.ToArray()
}

function Test-RulesFileStructure {
    # C1 to C4 on one ruleset file. Returns the parsed file, or $null when it is not JSON (excluded from later
    # checks). A file that parses but fails its schema still gets C2 to C4, which name the cause precisely.
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$File)
    $blocking = $File.Profile -eq 'delta'
    $json = Read-JsonOrNull $Context $File.Path
    if ($null -eq $json) {
        Add-Finding -Context $Context -Rule C1 -Severity error -File $File.Path -Message "$($File.Path) is not valid JSON" -Blocking:$blocking
        return $null
    }
    $null = Test-SchemaFile -Context $Context -Path $File.Path -Schema $script:ProfileSchemas[$File.Profile] -Rule C1 -Blocking:$blocking
    $rules = @(if ($json['rules'] -is [System.Collections.IList]) { $json['rules'] | Where-Object { $_ -is [System.Collections.IDictionary] } })

    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $reported = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($rule in $rules) {
        $id = [string]$rule['id']
        if ([string]::IsNullOrEmpty($id)) { continue }
        if (-not $seen.Add($id) -and $reported.Add($id)) {
            Add-Finding -Context $Context -Rule C2 -Severity error -File $File.Path -Id $id -Message "$id is listed more than once" -Blocking:$blocking
        }
    }

    if ($File.Profile -eq 'skeleton') {
        if ($json.Contains('generalAction')) {
            Add-Finding -Context $Context -Rule C3 -Severity error -File $File.Path -Message 'a skeleton has no generalAction'
        }
        $includes = @(if ($json['includedRuleSets'] -is [System.Collections.IList]) { $json['includedRuleSets'] })
        if ($includes.Count -ne 1) {
            Add-Finding -Context $Context -Rule C3 -Severity error -File $File.Path -Message "a skeleton has exactly one include; this one has $($includes.Count)"
        }
        foreach ($include in $includes) {
            if ($include -isnot [System.Collections.IDictionary] -or [string]$include['action'] -cne 'Default') {
                Add-Finding -Context $Context -Rule C3 -Severity error -File $File.Path -Message 'the include of a skeleton has action Default'
            }
        }
    } else {
        foreach ($key in 'includedRuleSets', 'generalAction') {
            if ($json.Contains($key)) {
                Add-Finding -Context $Context -Rule C3 -Severity error -File $File.Path -Message "$key is not allowed in $($File.Path); $($File.Profile) files are flat" -Blocking:$blocking
            }
        }
    }

    foreach ($rule in $rules) {
        $action = [string]$rule['action']
        if ($action -cin $script:Actions) { continue }
        $hint = if ($action -eq 'Default') { 'Default is not a rule action (the compiler fails to read it); ' } else { '' }
        Add-Finding -Context $Context -Rule C4 -Severity error -File $File.Path -Id ([string]$rule['id']) -Message "action '$action': $($hint)use Error, Warning, Info, Hidden or None" -Blocking:$blocking
    }
    return $json
}

function Test-QuarantineFiles {
    # C1 and C2 for quarantine.<stage>.json. Returns stage slug -> parsed file.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Checks every quarantine file')]
    param([Parameter(Mandatory)]$Context)
    $result = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::Ordinal)
    $names = [string[]]@(Get-ChildItem -LiteralPath $Context.Root -File -Filter 'quarantine.*.json' | Where-Object { $_.Name -like 'quarantine.*.json' } | ForEach-Object Name)
    [System.Array]::Sort($names, [System.StringComparer]::Ordinal)
    foreach ($name in $names) {
        $json = Read-JsonOrNull $Context $name
        if ($null -eq $json) {
            Add-Finding -Context $Context -Rule C1 -Severity error -File $name -Message "$name is not valid JSON" -Blocking
            continue
        }
        $null = Test-SchemaFile -Context $Context -Path $name -Schema 'rulebook-quarantine.schema.json' -Rule C1 -Blocking
        $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        foreach ($id in Get-RuleIdList $json) {
            if (-not $seen.Add($id)) { Add-Finding -Context $Context -Rule C2 -Severity error -File $name -Id $id -Message "$id is listed more than once" -Blocking }
        }
        $result[($name -replace '^quarantine\.', '' -replace '\.json$', '')] = $json
    }
    return , $result
}

function Test-OverridesFile {
    # C10 (and C4) for overrides.json. Returns the parsed file, or $null.
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Settings)
    $path = $script:OverridesPath
    if (-not (Test-RepoFile $Context $path)) { return $null }
    $json = Read-JsonOrNull $Context $path
    if ($null -eq $json) {
        Add-Finding -Context $Context -Rule C10 -Severity error -File $path -Message "$path is not valid JSON" -Blocking
        return $null
    }
    $schemaValid = Test-SchemaFile -Context $Context -Path $path -Schema 'rulebook-overrides.schema.json' -Rule C10 -Blocking
    # The overrides schema already rejects an action outside the five; C4 adds a finding only when it passed,
    # so an override with action Default is one C10 finding.
    if ($schemaValid -and $json['rules'] -is [System.Collections.IList]) {
        foreach ($rule in @($json['rules'] | Where-Object { $_ -is [System.Collections.IDictionary] })) {
            $action = [string]$rule['action']
            if ($action -cnotin $script:Actions) {
                $hint = if ($action -eq 'Default') { 'Default is not a rule action; ' } else { '' }
                Add-Finding -Context $Context -Rule C4 -Severity error -File $path -Id ([string]$rule['id']) -Message "action '$action': $($hint)use Error, Warning, Info, Hidden or None" -Blocking
            }
        }
    }
    if ($schemaValid -and $Settings.Valid) {
        $selectorInputs = [pscustomobject]@{ Levels = $Settings.Levels; Stages = $Settings.Stages }
        $entries = Read-Overrides -Path (Get-FullPath $Context $path) -Inputs $selectorInputs
        foreach ($entry in $entries) {
            foreach ($unknown in $entry.UnknownSelectors) {
                Add-Finding -Context $Context -Rule C10 -Severity error -File $path -Id $entry.Id -Message "entry $($entry.Index) names unknown $unknown; use a slug from the settings or [`"*`"]"
            }
        }
    }
    return $json
}

#endregion

function Test-Rulebook {
    <#
    .SYNOPSIS
    Runs checks C1 to C15 (docs/ARCHITECTURE.md section 5.3) on an organization rulebook repository.
    .DESCRIPTION
    Returns findings { Rule, Severity ('error' or 'warning'), File (repository-relative with '/', $null for the
    repository), Id ($null when the finding is not about one id), Message }, ordered by rule, file and id. With
    -Json the list is also written to that path. Never throws on bad repository content.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepositoryRoot, [string]$Json)
    if (-not (Test-Path -LiteralPath $RepositoryRoot -PathType Container)) { throw "Repository root not found: $RepositoryRoot" }
    $context = [pscustomobject]@{
        Root     = (Resolve-Path -LiteralPath $RepositoryRoot).ProviderPath
        Findings = [System.Collections.Generic.List[object]]::new()
        Blocking = [System.Collections.Generic.List[string]]::new()
        Texts    = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
    }
    $settings = Test-SettingsFile -Context $context
    if ($null -ne $settings) { Invoke-RulebookChecks -Context $context -Settings $settings }

    $findings = @(Get-SortedFinding -Findings $context.Findings.ToArray())
    if ($Json) {
        # [System.IO.File] resolves a relative path against the process directory, not the PowerShell location.
        $Json = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Json)
        $text = (ConvertTo-Json -InputObject $findings -Depth 3) -replace "`r`n", "`n"
        $parent = Split-Path -Parent $Json
        if ($parent -and -not (Test-Path -LiteralPath $parent)) { [void][System.IO.Directory]::CreateDirectory($parent) }
        [System.IO.File]::WriteAllText($Json, $text + "`n", [System.Text.UTF8Encoding]::new($false))
    }
    return $findings
}

function Invoke-RulebookChecks {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Runs every check after C5')]
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Settings)
    $root = $Context.Root

    # C14: catalog and twins
    $catalog = Test-CatalogFile -Context $Context
    $twinIds = Test-TwinsFile -Context $Context -TwinsSetting $Settings.TwinsSetting

    # C1 to C4: every ruleset file; quarantine files; C10 and C4: overrides
    $parsed = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::Ordinal)
    foreach ($file in Get-RulesFiles -Root $root) {
        $json = Test-RulesFileStructure -Context $Context -File $file
        if ($null -ne $json) { $parsed[$file.Path] = $json }
    }
    $quarantineFiles = Test-QuarantineFiles -Context $Context
    $overrides = Test-OverridesFile -Context $Context -Settings $Settings

    # C6: files the settings name; stages/default.json
    if (Test-RepoFile $Context 'stages/default.json') {
        Add-Finding -Context $Context -Rule C6 -Severity error -File 'stages/default.json' -Message 'stages/default.json must not exist; the default stage is the level result' -Blocking
    }
    $missingLevels = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    if ($Settings.Valid) {
        foreach ($level in $Settings.Levels) {
            $path = "base/$($level.Slug).ruleset.json"
            if (-not (Test-RepoFile $Context $path)) {
                [void]$missingLevels.Add($level.Slug)
                Add-Finding -Context $Context -Rule C6 -Severity error -File $path -Message "$path is missing for level '$($level.Name)'" -Blocking
            }
        }
        foreach ($stage in $Settings.Stages) {
            if ($stage.Slug -eq 'default') { continue }
            $path = "stages/$($stage.Slug).json"
            if (-not (Test-RepoFile $Context $path)) {
                Add-Finding -Context $Context -Rule C6 -Severity error -File $path -Message "$path is missing for stage '$($stage.Name)'" -Blocking
            }
        }
    }

    # Lenient level files for the analysis checks. Every base file that exists but is not JSON, and every published
    # level whose file is missing, gets an empty placeholder: C5 reports only real basedOn problems, and C1 or C6
    # the file itself (one finding per cause).
    $levelFiles = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::Ordinal)
    foreach ($path in @($parsed.Keys | Where-Object { $_ -like 'base/*.ruleset.json' })) {
        $levelFiles[($path.Substring(5) -replace '\.ruleset\.json$', '')] = [pscustomobject]@{ Rules = ConvertTo-LenientRuleMap $parsed[$path] }
    }
    foreach ($name in Get-FolderFileName -Root $root -Folder 'base') {
        if ($name -notlike '*.ruleset.json') { continue }
        $slug = $name -replace '\.ruleset\.json$', ''
        if (-not $levelFiles.Contains($slug)) { $levelFiles[$slug] = [pscustomobject]@{ Rules = ConvertTo-LenientRuleMap $null } }
    }
    foreach ($level in $Settings.Levels) {
        if (-not $levelFiles.Contains($level.Slug)) { $levelFiles[$level.Slug] = [pscustomobject]@{ Rules = ConvertTo-LenientRuleMap $null } }
    }
    $chains = $null
    $chainFiles = $null
    if ($Settings.Valid) {
        try {
            $resolved = Resolve-LevelChain -Levels $Settings.Levels -LevelFiles $levelFiles
            $chains = $resolved.Chains
            $chainFiles = $resolved.ChainFiles
        } catch {
            Add-Finding -Context $Context -Rule C5 -Severity error -File $script:SettingsPath -Message $_.Exception.Message -Blocking
        }
    }
    $stageMaps = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::Ordinal)
    foreach ($stage in $Settings.Stages) {
        $path = "stages/$($stage.Slug).json"
        if ($stage.Slug -ne 'default' -and $parsed.Contains($path)) { $stageMaps[$stage.Slug] = ConvertTo-LenientRuleMap $parsed[$path] }
    }
    $getDefault = { param($id) if ($null -eq $catalog) { return $null }; return Get-AnalyzerDefault -Catalog $catalog -Id $id }
    $chainMentions = {
        param($id)
        if ($null -eq $chains) { return $false }
        foreach ($chain in $chains.Values) { if ($chain.Contains($id)) { return $true } }
        return $false
    }

    # C7: ids the catalog does not know
    if ($null -ne $catalog) {
        $severity = if (Test-RepoFile $Context $script:ScanStatePath) { 'error' } else { 'warning' }
        $sources = [System.Collections.Generic.List[object]]::new()
        foreach ($path in $parsed.Keys) { if ($path -like 'base/*' -or $path -like 'stages/*') { $sources.Add(@{ Path = $path; Ids = Get-RuleIdList $parsed[$path] }) } }
        $sources.Add(@{ Path = $script:TwinsPath; Ids = $twinIds })
        if ($null -ne $overrides) { $sources.Add(@{ Path = $script:OverridesPath; Ids = Get-RuleIdList $overrides }) }
        foreach ($key in $quarantineFiles.Keys) { $sources.Add(@{ Path = "quarantine.$key.json"; Ids = Get-RuleIdList $quarantineFiles[$key] }) }
        foreach ($source in $sources) {
            $reported = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
            foreach ($id in $source.Ids) {
                if (-not $catalog.ContainsKey($id) -and $reported.Add($id)) {
                    $hint = if ($severity -eq 'warning') { 'a warning until the first scan writes catalog/scan-state.json' } else { 'catalog/scan-state.json exists' }
                    Add-Finding -Context $Context -Rule C7 -Severity $severity -File $source.Path -Id $id -Message "$id is not in $($script:CatalogPath) ($hint)"
                }
            }
        }
    }

    if ($null -ne $chains) {
        # C8: a stage entry no published level enables (quarantine ignored; that is C15)
        foreach ($stageSlug in $stageMaps.Keys) {
            foreach ($id in $stageMaps[$stageSlug].Keys) {
                $enabled = $false
                foreach ($level in $Settings.Levels) {
                    $chain = $chains[$level.Slug]
                    $result = if ($chain.Contains($id)) { $chain[$id].Action } else { & $getDefault $id }
                    if ($result -cne 'None') { $enabled = $true; break }
                }
                if (-not $enabled -and $Settings.Levels.Count -gt 0) {
                    Add-Finding -Context $Context -Rule C8 -Severity warning -File "stages/$stageSlug.json" -Id $id -Message "$id is None in every published level, so this stage entry never applies (S-4)"
                }
            }
        }

        # C9 (a): a level entry equal to what its basedOn level (root: the analyzer default) already gives
        foreach ($level in $Settings.Levels) {
            if ($missingLevels.Contains($level.Slug) -or -not $levelFiles.Contains($level.Slug)) { continue }
            $baseChain = $null
            if ($null -ne $level.BasedOn) {
                $baseChain = if ($chains.Contains($level.BasedOn)) { $chains[$level.BasedOn] } else { $levelFiles[$level.BasedOn].Rules }
            }
            foreach ($id in $levelFiles[$level.Slug].Rules.Keys) {
                $action = $levelFiles[$level.Slug].Rules[$id].Action
                $expected = if ($null -ne $baseChain -and $baseChain.Contains($id)) { $baseChain[$id].Action } else { & $getDefault $id }
                if ($null -ne $expected -and $action -ceq $expected) {
                    $what = if ($null -ne $baseChain -and $baseChain.Contains($id)) { "level $($level.BasedOn)" } else { 'the analyzer default' }
                    Add-Finding -Context $Context -Rule C9 -Severity warning -File "base/$($level.Slug).ruleset.json" -Id $id -Message "$id is $action, which $what already gives"
                }
            }
        }
    }

    # C9 (b): files no settings entry references, no published chain reaches and unusedRulebookFiles does not list.
    # Needs the resolved chains; after a C5 chain failure every file would look unreferenced.
    if ($Settings.Valid -and $null -ne $chainFiles) {
        $reached = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        foreach ($slug in $Settings.LevelSlugs) { [void]$reached.Add($slug) }
        foreach ($files in $chainFiles.Values) { foreach ($slug in $files) { [void]$reached.Add($slug) } }
        foreach ($name in Get-FolderFileName -Root $root -Folder 'base') {
            if ($name -notlike '*.ruleset.json') { continue }
            $path = "base/$name"
            if (-not $reached.Contains(($name -replace '\.ruleset\.json$', '')) -and -not (Test-UnusedListed $Settings.Unused $path)) {
                Add-Finding -Context $Context -Rule C9 -Severity warning -File $path -Message "$path is neither a published level nor on the chain of one; publish it, remove it or list it in unusedRulebookFiles"
            }
        }
        foreach ($name in Get-FolderFileName -Root $root -Folder 'stages') {
            if ($name -notlike '*.json' -or $name -eq 'default.json') { continue }
            $path = "stages/$name"
            if (($name -replace '\.json$', '') -cnotin $Settings.StageSlugs -and -not (Test-UnusedListed $Settings.Unused $path)) {
                Add-Finding -Context $Context -Rule C9 -Severity warning -File $path -Message "$path is not a stage in the settings; publish it, remove it or list it in unusedRulebookFiles"
            }
        }
    }

    # C11: endpoint entries at their default; exactly levels x stages endpoints and skeletons
    if ($null -ne $catalog) {
        foreach ($path in @($parsed.Keys | Where-Object { $_ -like 'rulesets/*' })) {
            foreach ($id in (ConvertTo-LenientRuleMap $parsed[$path]).GetEnumerator()) {
                $default = & $getDefault $id.Key
                if ($null -ne $default -and $id.Value.Action -ceq $default) {
                    Add-Finding -Context $Context -Rule C11 -Severity error -File $path -Id $id.Key -Message "$($id.Key) is listed at $default, its analyzer default; an endpoint lists only deviations (D22)"
                }
            }
        }
    }
    # The C11 file set: any file in rulesets/ or skeletons/ whose name is not an expected endpoint or skeleton name,
    # and any expected name that is missing. While C12 runs, a missing or stray *.ruleset.json in rulesets/ is left
    # to C12 ('would be created' or 'would be deleted'): one finding per cause. skeletons/ is checked only when it
    # exists; the template ships them since WP04 (assumption 9 of WP03). README.md (exact name, ordinal) is exempt in
    # both folders: the template ships skeletons/README.md since WP06, and Publish copies by expected name only, so a
    # README is never published.
    if ($Settings.Valid) {
        $c12Runs = $Context.Blocking.Count -eq 0
        foreach ($folder in @(@{ Name = 'rulesets'; Skeleton = $false }, @{ Name = 'skeletons'; Skeleton = $true })) {
            if ($folder.Skeleton -and -not (Test-Path -LiteralPath (Join-Path $root $folder.Name) -PathType Container)) { continue }
            $leftToC12 = (-not $folder.Skeleton) -and $c12Runs
            $expected = [System.Collections.Generic.List[string]]::new()
            foreach ($level in $Settings.Levels) {
                foreach ($stage in $Settings.Stages) {
                    $expected.Add($(if ($folder.Skeleton -or $stage.Slug -ne 'default') { "$($level.Slug).$($stage.Slug).ruleset.json" } else { "$($level.Slug).ruleset.json" }))
                }
            }
            $actual = Get-FolderFileName -Root $root -Folder $folder.Name
            foreach ($name in $expected) {
                if ($name -cnotin $actual -and -not $leftToC12) {
                    Add-Finding -Context $Context -Rule C11 -Severity error -File "$($folder.Name)/$name" -Message "$($folder.Name)/$name is missing; every levels x stages entry has one"
                }
            }
            foreach ($name in $actual) {
                if ($name -cin $expected -or $name -ceq 'README.md' -or ($leftToC12 -and $name -like '*.ruleset.json')) { continue }
                Add-Finding -Context $Context -Rule C11 -Severity error -File "$($folder.Name)/$name" -Message "$($folder.Name)/$name matches no levels x stages entry"
            }
        }
    }

    if ($null -ne $chains) {
        # C13: a quarantined id a file on a published chain mentions
        foreach ($stageSlug in $quarantineFiles.Keys) {
            foreach ($id in Get-RuleIdList $quarantineFiles[$stageSlug]) {
                if (& $chainMentions $id) {
                    Add-Finding -Context $Context -Rule C13 -Severity warning -File "quarantine.$stageSlug.json" -Id $id -Message "$id is mentioned by a level file, so the chain wins; remove the quarantine entry"
                }
            }
        }
        # C15: a stage entry dead while quarantined (D41)
        foreach ($stageSlug in $stageMaps.Keys) {
            if (-not $quarantineFiles.Contains($stageSlug)) { continue }
            $quarantined = Get-RuleIdList $quarantineFiles[$stageSlug]
            foreach ($id in $stageMaps[$stageSlug].Keys) {
                if ($id -cin $quarantined -and -not (& $chainMentions $id)) {
                    Add-Finding -Context $Context -Rule C15 -Severity warning -File "stages/$stageSlug.json" -Id $id -Message "$id is in quarantine.$stageSlug.json and no level file mentions it, so quarantine wins and this stage entry does not apply until a level file adopts $id (D41)"
                }
            }
        }
    }

    # C12: the regeneration check, only when the generator's prerequisites have no errors (assumption 11)
    if ($Context.Blocking.Count -gt 0) {
        $rules = @($Context.Blocking | Sort-Object { [int]($_ -replace '[^0-9]', '') }) -join ', '
        Add-Finding -Context $Context -Rule C12 -Severity warning -Message "Regeneration check skipped: fix the $rules errors first; the generator cannot run on these inputs"
    } else {
        try {
            foreach ($change in @(Update-RulebookEndpoints -RepositoryRoot $root -WhatIf)) {
                Add-Finding -Context $Context -Rule C12 -Severity error -File $change.File -Message "$($change.File) would be $($change.Change); run Update-RulebookEndpoints and commit the result"
            }
        } catch {
            Add-Finding -Context $Context -Rule C12 -Severity error -Message "Regeneration check failed: $($_.Exception.Message)"
        }
    }
}

Export-ModuleMember -Function 'Test-Rulebook'
