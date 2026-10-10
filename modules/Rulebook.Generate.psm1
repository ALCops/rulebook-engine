#requires -Version 7.4
# Rulebook.Generate: turns the level chain, the stage files, the twins setting, overrides.json, the quarantine
# files and the catalog defaults into the sparse flat endpoints in rulesets/ (D18, D19, D22, D23, D27, D41), and
# computes the effective diff between the working tree and a git ref.
# Contract: docs/rulebook/composition.md. Worked examples: docs/reference/effective-diff.md.

Set-StrictMode -Version 3.0
Import-Module (Join-Path $PSScriptRoot 'Rulebook.Common.psd1')

$script:Actions = @('Error', 'Warning', 'Info', 'Hidden', 'None')
# Prefix order of Get-DiagnosticSortKey, the inventory order. The tools under tools/rulebook/ import this module
# for the key instead of keeping their own copy of this list.
$script:PrefixOrder = @('AL', 'AA', 'AW', 'PTE', 'AS', 'PC', 'AC', 'LC', 'DC', 'FC', 'TA', 'CM')
$script:SettingsPath = '.github/Rulebook-Settings.json'
$script:CatalogPath = 'catalog/diagnostics.json'
$script:TwinsPath = 'base/twins.json'
$script:OverridesPath = 'overrides.json'
$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

#region Internal helpers

function Get-Slug {
    param([AllowNull()][string]$Name)
    if ([string]::IsNullOrEmpty($Name)) { return $null }
    return $Name.ToLowerInvariant()
}

function ConvertTo-TextValue {
    # ConvertFrom-Json -AsHashtable turns an ISO date-time string such as "2026-10-03T10:00:00" into a [DateTime]
    # (pwsh 7.4 has no -DateKind). Justifications and titles are text, so such a value is formatted back,
    # culture-free and independent of the machine's time zone: a value with an offset or Z (Local or Utc kind)
    # as the UTC instant with Z, a value without one as written, a midnight value as the date alone.
    param($Value)
    if ($Value -is [System.DateTimeOffset]) { $Value = $Value.UtcDateTime }
    if ($Value -is [System.DateTime]) {
        $invariant = [System.Globalization.CultureInfo]::InvariantCulture
        if ($Value.Kind -ne [System.DateTimeKind]::Unspecified) {
            return $Value.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", $invariant)
        }
        if ($Value.TimeOfDay -eq [System.TimeSpan]::Zero) { return $Value.ToString('yyyy-MM-dd', $invariant) }
        return $Value.ToString('s', $invariant)
    }
    if ($null -eq $Value) { return $null }
    return [string]$Value
}

function Get-MemberValue {
    # Reads a property of a pscustomobject or a key of a dictionary; $null when absent (StrictMode safe).
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}

function ConvertFrom-JsonText {
    param([AllowNull()][string]$Text, [string]$Path)
    if ([string]::IsNullOrWhiteSpace($Text)) { throw "Invalid JSON in ${Path}: the file is empty" }
    try {
        $json = $Text | ConvertFrom-Json -AsHashtable -Depth 10 -ErrorAction Stop
    } catch {
        throw "Invalid JSON in ${Path}: $($_.Exception.Message)"
    }
    if ($json -isnot [System.Collections.IDictionary]) { throw "Invalid JSON in ${Path}: the root is not an object" }
    return $json
}

function Assert-RuleAction {
    param([AllowNull()][string]$Action, [string]$Id, [string]$Path)
    if ($Action -cnotin $script:Actions) {
        throw "$Path`: rule $Id has action '$Action'; allowed are Error, Warning, Info, Hidden and None, never Default (C4)"
    }
}

function ConvertFrom-RulesetText {
    param([AllowNull()][string]$Text, [Parameter(Mandatory)][string]$Path)
    $json = ConvertFrom-JsonText -Text $Text -Path $Path
    foreach ($forbidden in 'includedRuleSets', 'generalAction') {
        if ($json.Contains($forbidden)) {
            throw "$Path has '$forbidden'; level, stage and endpoint files are flat (C3)"
        }
    }
    if (-not $json.Contains('rules') -or $json['rules'] -isnot [System.Collections.IList]) {
        throw "$Path has no rules array"
    }
    $rules = Get-OrdinalMap
    foreach ($rule in $json['rules']) {
        if ($rule -isnot [System.Collections.IDictionary]) { throw "$Path has a rule that is not an object" }
        $id = [string]$rule['id']
        if ([string]::IsNullOrEmpty($id)) { throw "$Path has a rule without an id" }
        $action = [string]$rule['action']
        Assert-RuleAction -Action $action -Id $id -Path $Path
        if ($rules.Contains($id)) { throw "$Path lists $id twice (C2)" }
        $rules[$id] = [pscustomobject]@{ Action = $action; Justification = ConvertTo-TextValue $rule['justification'] }
    }
    return [pscustomobject]@{
        PSTypeName  = 'Rulebook.RulesetFile'
        Name        = $json['name']
        Description = $json['description']
        Rules       = $rules
        Path        = $Path
    }
}

function Assert-NotDefaultStageFile {
    param([string]$Path)
    if ((Split-Path -Leaf $Path) -eq 'default.json') {
        throw "$Path`: stages/default.json must not exist; the default stage is the level result (C6)"
    }
}

function ConvertFrom-OverridesText {
    param(
        [AllowNull()][string]$Text,
        [Parameter(Mandatory)][string]$Path,
        [AllowNull()][string[]]$LevelSlugs,
        [AllowNull()][string[]]$StageSlugs,
        [switch]$Strict
    )
    $json = ConvertFrom-JsonText -Text $Text -Path $Path
    if (-not $json.Contains('rules') -or $json['rules'] -isnot [System.Collections.IList]) {
        throw "$Path has no rules array"
    }
    $entries = [System.Collections.Generic.List[object]]::new()
    $index = 0
    foreach ($rule in $json['rules']) {
        if ($rule -isnot [System.Collections.IDictionary]) { throw "$Path has an entry that is not an object" }
        $id = [string]$rule['id']
        if ([string]::IsNullOrEmpty($id)) { throw "$Path entry $index has no id" }
        $action = [string]$rule['action']
        Assert-RuleAction -Action $action -Id $id -Path $Path
        $levels = @($rule['levels'] | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
        $stages = @($rule['stages'] | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
        if ($levels.Count -eq 0) { throw "$Path entry $index ($id) has no levels selector" }
        if ($stages.Count -eq 0) { throw "$Path entry $index ($id) has no stages selector" }
        foreach ($selector in @(@{ Name = 'levels'; Values = $levels }, @{ Name = 'stages'; Values = $stages })) {
            if ($selector.Values.Count -gt 1 -and $selector.Values -contains '*') {
                throw "$Path entry $index ($id) mixes '*' with other values in $($selector.Name); use ['*'] alone or a list of slugs"
            }
        }
        $levelWildcard = $levels.Count -eq 1 -and $levels[0] -eq '*'
        $stageWildcard = $stages.Count -eq 1 -and $stages[0] -eq '*'
        $specificity = 0
        if (-not $levelWildcard) { $specificity++ }
        if (-not $stageWildcard) { $specificity++ }

        $unknown = [System.Collections.Generic.List[string]]::new()
        if ($null -ne $LevelSlugs -and -not $levelWildcard) {
            foreach ($slug in $levels) { if ($slug -cnotin $LevelSlugs) { $unknown.Add("level '$slug'") } }
        }
        if ($null -ne $StageSlugs -and -not $stageWildcard) {
            foreach ($slug in $stages) { if ($slug -cnotin $StageSlugs) { $unknown.Add("stage '$slug'") } }
        }
        if ($Strict -and $unknown.Count -gt 0) {
            throw "$Path entry $index ($id) names an unknown $($unknown -join ', ') (C10)"
        }

        $entries.Add([pscustomobject]@{
                PSTypeName       = 'Rulebook.Override'
                Id               = $id
                Action           = $action
                Levels           = $levels
                Stages           = $stages
                Justification    = ConvertTo-TextValue $rule['justification']
                Specificity      = $specificity
                Index            = $index
                UnknownSelectors = $unknown.ToArray()
            })
        $index++
    }
    return , $entries.ToArray()
}

function ConvertFrom-QuarantineText {
    param([AllowNull()][string]$Text, [Parameter(Mandatory)][string]$Path)
    $json = ConvertFrom-JsonText -Text $Text -Path $Path
    if (-not $json.Contains('rules') -or $json['rules'] -isnot [System.Collections.IList]) {
        throw "$Path has no rules array"
    }
    $ids = Get-OrdinalMap
    foreach ($rule in $json['rules']) {
        if ($rule -isnot [System.Collections.IDictionary]) { throw "$Path has an entry that is not an object" }
        $id = [string]$rule['id']
        if ([string]::IsNullOrEmpty($id)) { throw "$Path has an entry without an id" }
        if ($ids.Contains($id)) { throw "$Path lists $id twice (C2)" }
        $ids[$id] = ConvertTo-TextValue $rule['justification']
    }
    return $ids
}

function Get-EmptyTwinSet {
    return [pscustomobject]@{
        PSTypeName     = 'Rulebook.Twins'
        Pairs          = @()
        PteSides       = Get-OrdinalSet
        AppSourceSides = Get-OrdinalSet
        BySide         = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
        Count          = 0
        Path           = $null
    }
}

function ConvertFrom-TwinsText {
    param([AllowNull()][string]$Text, [Parameter(Mandatory)][string]$Path)
    $json = ConvertFrom-JsonText -Text $Text -Path $Path
    $twins = Get-EmptyTwinSet
    $twins.Path = $Path
    $pairs = [System.Collections.Generic.List[object]]::new()
    foreach ($pair in @($json['pairs'] | Where-Object { $null -ne $_ })) {
        if ($pair -isnot [System.Collections.IDictionary]) { throw "$Path has a pair that is not an object" }
        $item = [pscustomobject]@{ Pte = [string]$pair['pte']; AppSource = [string]$pair['appsource']; Title = ConvertTo-TextValue $pair['title'] }
        if ([string]::IsNullOrEmpty($item.Pte) -or [string]::IsNullOrEmpty($item.AppSource)) {
            throw "$Path has a pair without a pte or an appsource id"
        }
        foreach ($side in $item.Pte, $item.AppSource) {
            if ($twins.BySide.ContainsKey($side)) { throw "$Path lists $side in two pairs (C2)" }
        }
        $pairs.Add($item)
        [void]$twins.PteSides.Add($item.Pte)
        [void]$twins.AppSourceSides.Add($item.AppSource)
        $twins.BySide[$item.Pte] = $item
        $twins.BySide[$item.AppSource] = $item
    }
    $twins.Pairs = $pairs.ToArray()
    $twins.Count = if ($json.Contains('count')) { $json['count'] } else { $pairs.Count }
    return $twins
}

function ConvertFrom-CatalogText {
    param([AllowNull()][string]$Text, [Parameter(Mandatory)][string]$Path)
    $json = ConvertFrom-JsonText -Text $Text -Path $Path
    if (-not $json.Contains('diagnostics') -or $json['diagnostics'] -isnot [System.Collections.IList]) {
        throw "$Path has no diagnostics array"
    }
    $catalog = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
    foreach ($entry in $json['diagnostics']) {
        if ($entry -isnot [System.Collections.IDictionary]) { throw "$Path has an entry that is not an object" }
        $id = [string]$entry['id']
        if ([string]::IsNullOrEmpty($id)) { throw "$Path has an entry without an id" }
        if (-not $entry.Contains('defaultSeverity')) { throw "$Path`: $id has no defaultSeverity (C14)" }
        if (-not $entry.Contains('enabledByDefault') -or $entry['enabledByDefault'] -isnot [bool]) {
            throw "$Path`: $id has no boolean enabledByDefault (C14)"
        }
        $severity = [string]$entry['defaultSeverity']
        $enabled = [bool]$entry['enabledByDefault']
        $catalog[$id] = [pscustomobject]@{
            Id               = $id
            DefaultSeverity  = $severity
            EnabledByDefault = $enabled
            Default          = if ($enabled) { $severity } else { 'None' }
        }
    }
    return , $catalog
}

function ConvertTo-LevelEntry {
    # Accepts a settings entry (dictionary with name, basedOn, description) or an already normalised level.
    param($Level)
    $slug = Get-MemberValue $Level 'Slug'
    $name = Get-MemberValue $Level 'Name'
    if ($null -eq $name) { $name = Get-MemberValue $Level 'name' }
    if ($null -eq $slug) { $slug = Get-Slug $name }
    $basedOn = Get-MemberValue $Level 'BasedOn'
    if ($null -eq $basedOn) { $basedOn = Get-MemberValue $Level 'basedOn' }
    return [pscustomobject]@{
        Name        = [string]$name
        Slug        = $slug
        BasedOn     = Get-Slug $basedOn
        Description = Get-MemberValue $Level 'description'
    }
}

function Get-FileSource {
    # One reader for the working tree and for a git ref, so both share every code path. Paths are relative to
    # the rulebook root with '/' separators. For a ref, 'rev-parse --show-prefix' makes a rulebook nested in a
    # bigger repository (the test fixtures) resolve.
    param([Parameter(Mandatory)][string]$Root, [string]$Ref)
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { throw "Repository root not found: $Root" }
    $full = (Resolve-Path -LiteralPath $Root).ProviderPath
    if ([string]::IsNullOrEmpty($Ref)) {
        return [pscustomobject]@{ Root = $full; Ref = $null; Sha = $null; Prefix = ''; Paths = $null; Source = 'worktree' }
    }
    $prefixResult = Invoke-Git -Root $full -Arguments @('rev-parse', '--show-prefix')
    if ($prefixResult.ExitCode -ne 0) { throw "Not a git repository: $full ($($prefixResult.Error.Trim()))" }
    $prefix = $prefixResult.Output.Trim()
    # A ref that starts with '-' would reach git as an option; resolve the ref once and use the sha from then on.
    if ($Ref.StartsWith('-')) { throw "Unknown git ref '$Ref' in $full" }
    $verify = Invoke-Git -Root $full -Arguments @('rev-parse', '--verify', '--quiet', "$Ref^{commit}")
    $sha = $verify.Output.Trim()
    if ($verify.ExitCode -ne 0 -or $sha -notmatch '^[0-9a-f]{40,64}$') { throw "Unknown git ref '$Ref' in $full" }
    $tree = Invoke-Git -Root $full -Arguments @('ls-tree', '-r', '-z', '--name-only', '--full-tree', $sha, '--')
    if ($tree.ExitCode -ne 0) { throw "git ls-tree $Ref failed: $($tree.Error.Trim())" }
    $paths = Get-OrdinalSet
    foreach ($line in $tree.Output.Split([char]0)) {
        if ($line.Length -gt $prefix.Length -and $line.StartsWith($prefix, [System.StringComparison]::Ordinal)) {
            [void]$paths.Add($line.Substring($prefix.Length))
        }
    }
    return [pscustomobject]@{ Root = $full; Ref = $Ref; Sha = $sha; Prefix = $prefix; Paths = $paths; Source = "ref:$Ref" }
}

function Read-SourceText {
    param([Parameter(Mandatory)]$Source, [Parameter(Mandatory)][string]$Path)
    if ($null -eq $Source.Ref) {
        $full = Join-Path $Source.Root $Path
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { return $null }
        return Get-Content -LiteralPath $full -Raw
    }
    if (-not $Source.Paths.Contains($Path)) { return $null }
    $show = Invoke-Git -Root $Source.Root -Arguments @('show', "$($Source.Sha):$($Source.Prefix)$Path", '--')
    if ($show.ExitCode -ne 0) { throw "git show $($Source.Ref):$Path failed: $($show.Error.Trim())" }
    # Get-Content drops a byte order mark on the worktree side; do the same here so both sides parse alike.
    return $show.Output.TrimStart([char]0xFEFF)
}

function Get-SourcePath {
    # Relative paths of the files directly in Directory ('' for the rulebook root) whose name is -like Filter.
    param([Parameter(Mandatory)]$Source, [AllowEmptyString()][string]$Directory, [Parameter(Mandatory)][string]$Filter)
    $result = [System.Collections.Generic.List[string]]::new()
    if ($null -eq $Source.Ref) {
        $dir = if ($Directory) { Join-Path $Source.Root $Directory } else { $Source.Root }
        if (Test-Path -LiteralPath $dir -PathType Container) {
            foreach ($file in Get-ChildItem -LiteralPath $dir -File -Filter $Filter) {
                if ($file.Name -notlike $Filter) { continue }
                $result.Add($(if ($Directory) { "$Directory/$($file.Name)" } else { $file.Name }))
            }
        }
    } else {
        $head = if ($Directory) { "$Directory/" } else { '' }
        foreach ($path in $Source.Paths) {
            if (-not $path.StartsWith($head, [System.StringComparison]::Ordinal)) { continue }
            $leaf = $path.Substring($head.Length)
            if ($leaf.Contains('/') -or $leaf -notlike $Filter) { continue }
            $result.Add($path)
        }
    }
    $sorted = $result.ToArray()
    [System.Array]::Sort($sorted, [System.StringComparer]::Ordinal)
    return $sorted
}

function Get-EndpointDescription {
    param([Parameter(Mandatory)]$Inputs, [Parameter(Mandatory)][string]$Level, [Parameter(Mandatory)][string]$Stage)
    $chainFiles = @($Inputs.ChainFiles[$Level] | ForEach-Object { "base/$_.ruleset.json" }) -join ', '
    $stageFile = if ($Stage -ne 'default') { "stages/$Stage.json, " } else { '' }
    return ('Level {0}, stage {1}, twins {2}. Generated from {3} plus {4}{5} and quarantine.{1}.json; do not edit. Ids at their analyzer default are not listed.' -f
        $Level, $Stage, $Inputs.TwinsSetting, $chainFiles, $stageFile, $script:OverridesPath)
}

function Test-OverrideMatch {
    param([Parameter(Mandatory)]$Override, [Parameter(Mandatory)][string]$Level, [Parameter(Mandatory)][string]$Stage)
    $levelMatch = ($Override.Levels.Count -eq 1 -and $Override.Levels[0] -eq '*') -or ($Level -cin $Override.Levels)
    if (-not $levelMatch) { return $false }
    return ($Override.Stages.Count -eq 1 -and $Override.Stages[0] -eq '*') -or ($Stage -cin $Override.Stages)
}

function ConvertTo-EffectiveResult {
    # Action and Default stay untyped: a [string] parameter would turn $null (unknown default) into ''.
    param([string]$Id, $Action, [string]$Source, $Detail, $Default)
    if ([string]::IsNullOrEmpty($Action)) { $Action = $null }
    if ([string]::IsNullOrEmpty($Default)) { $Default = $null }
    # An unknown default ($null) never equals anything, so an id absent from the catalog is always written.
    $listed = ($null -ne $Action) -and (($null -eq $Default) -or ($Action -cne $Default))
    return [pscustomobject]@{
        PSTypeName = 'Rulebook.EffectiveAction'
        Id         = $Id
        Action     = $Action
        Source     = $Source
        Detail     = $Detail
        Default    = $Default
        Listed     = $listed
    }
}

function Resolve-Effective {
    # The precedence of D41 (composition.md section 3), in one place for both parameter sets of Get-EffectiveAction.
    param(
        [string]$Id,
        [string]$Level,
        [string]$Stage,
        [AllowNull()][System.Collections.IDictionary]$Chain,
        [AllowNull()][System.Collections.IDictionary]$StageDelta,
        [AllowNull()]$Twins,
        [string]$TwinsSetting,
        [AllowNull()][object[]]$Overrides,
        [AllowNull()][System.Collections.IDictionary]$Quarantine,
        [AllowNull()]$Catalog
    )
    $default = $null
    if ($null -ne $Catalog -and $Catalog.ContainsKey($Id)) { $default = $Catalog[$Id].Default }

    # 1. override: highest specificity, then the later entry
    $best = $null
    foreach ($override in $Overrides) {
        if ($null -eq $override -or $override.Id -cne $Id) { continue }
        if (-not (Test-OverrideMatch -Override $override -Level $Level -Stage $Stage)) { continue }
        if ($null -eq $best -or $override.Specificity -gt $best.Specificity -or
            ($override.Specificity -eq $best.Specificity -and $override.Index -gt $best.Index)) {
            $best = $override
        }
    }
    if ($null -ne $best) { return ConvertTo-EffectiveResult $Id $best.Action 'override' $best.Justification $default }

    # 2. twins: the losing side of every pair is None
    if ($null -ne $Twins) {
        if (($TwinsSetting -eq 'appsource' -and $Twins.PteSides.Contains($Id)) -or
            ($TwinsSetting -eq 'pte' -and $Twins.AppSourceSides.Contains($Id))) {
            return ConvertTo-EffectiveResult $Id 'None' 'twins' $Twins.BySide[$Id].Title $default
        }
    }

    # level result: the chain where a file mentions the id, else quarantine None, else the analyzer default (D41)
    if ($null -ne $Chain -and $Chain.Contains($Id)) {
        $hit = $Chain[$Id]
        $levelResult = ConvertTo-EffectiveResult $Id $hit.Action "level:$($hit.Slug)" $hit.Justification $default
    } elseif ($null -ne $Quarantine -and $Quarantine.Contains($Id)) {
        $levelResult = ConvertTo-EffectiveResult $Id 'None' 'quarantine' $Quarantine[$Id] $default
    } else {
        $levelResult = ConvertTo-EffectiveResult $Id $default 'default' $null $default
    }

    # 3. stage delta, only where the level result is not None (a stage never activates a rule, S-4)
    if ($Stage -ne 'default' -and $null -ne $StageDelta -and $StageDelta.Contains($Id) -and $levelResult.Action -cne 'None') {
        $entry = $StageDelta[$Id]
        return ConvertTo-EffectiveResult $Id $entry.Action "stage:$Stage" $entry.Justification $default
    }
    return $levelResult
}

function Get-InputsLevel {
    param([Parameter(Mandatory)]$Inputs, [Parameter(Mandatory)][string]$Level)
    foreach ($item in $Inputs.Levels) { if ($item.Slug -ceq $Level) { return $item } }
    return $null
}

function Get-InputsStage {
    param([Parameter(Mandatory)]$Inputs, [Parameter(Mandatory)][string]$Stage)
    foreach ($item in $Inputs.Stages) { if ($item.Slug -ceq $Stage) { return $item } }
    return $null
}

function Get-OverridesForId {
    param([Parameter(Mandatory)]$Inputs, [Parameter(Mandatory)][string]$Id)
    if ($Inputs.OverridesById.ContainsKey($Id)) { return , $Inputs.OverridesById[$Id].ToArray() }
    return , @()
}

function Resolve-EffectiveFromInput {
    param([Parameter(Mandatory)]$Inputs, [string]$Id, [string]$Level, [string]$Stage)
    $chain = if ($Inputs.Chains.Contains($Level)) { $Inputs.Chains[$Level] } else { $null }
    $stageDelta = if ($Inputs.StageDeltas.Contains($Stage)) { $Inputs.StageDeltas[$Stage] } else { $null }
    $quarantine = if ($Inputs.Quarantine.Contains($Stage)) { $Inputs.Quarantine[$Stage] } else { $null }
    return Resolve-Effective -Id $Id -Level $Level -Stage $Stage -Chain $chain -StageDelta $stageDelta `
        -Twins $Inputs.Twins -TwinsSetting $Inputs.TwinsSetting -Overrides (Get-OverridesForId -Inputs $Inputs -Id $Id) `
        -Quarantine $quarantine -Catalog $Inputs.Catalog
}

function Get-SortedById {
    # Sorts items (strings or objects with an Id) by Get-DiagnosticSortKey, ordinally. Unrolled: wrap in @().
    # A SortedDictionary with an ordinal comparer, because [Array]::Sort(keys, items) through PowerShell's argument
    # conversion can sort copies and leave the arrays unchanged.
    param([AllowNull()][object[]]$Items)
    if ($null -eq $Items -or $Items.Count -eq 0) { return }
    $sorted = [System.Collections.Generic.SortedDictionary[string, object]]::new([System.StringComparer]::Ordinal)
    foreach ($item in $Items) {
        $id = if ($item -is [string]) { $item } else { $item.Id }
        $sorted[(Get-DiagnosticSortKey -Id $id) + '|' + $id] = $item
    }
    return $sorted.Values
}

function Format-DiffSide {
    param($Action, $Source, $Detail)
    if ($null -eq $Source) { return '(absent)' }
    $actionText = if ($null -ne $Action) { $Action } else { 'unknown' }
    $inner = if ([string]::IsNullOrEmpty($Detail)) { $Source } else { '{0}, "{1}"' -f $Source, $Detail }
    return '{0} ({1})' -f $actionText, $inner
}

function ConvertTo-DiffRow {
    param([string]$Endpoint, [string]$File, [AllowNull()][string]$Id, $Before, $After, [string]$Change)
    $row = [pscustomobject]@{
        PSTypeName    = 'Rulebook.DiffRow'
        Endpoint      = $Endpoint
        File          = $File
        Id            = $Id
        Before        = Get-MemberValue $Before 'Action'
        After         = Get-MemberValue $After 'Action'
        BeforeSource  = Get-MemberValue $Before 'Source'
        AfterSource   = Get-MemberValue $After 'Source'
        BeforeDetail  = Get-MemberValue $Before 'Detail'
        AfterDetail   = Get-MemberValue $After 'Detail'
        ListedBefore  = [bool](Get-MemberValue $Before 'Listed')
        ListedAfter   = [bool](Get-MemberValue $After 'Listed')
        Change        = $Change
        Text          = $null
    }
    $label = if ($null -ne $Id) { $Id } else { $Endpoint }
    $row.Text = '{0}: {1} -> {2}' -f $label, (Format-DiffSide $row.Before $row.BeforeSource $row.BeforeDetail), (Format-DiffSide $row.After $row.AfterSource $row.AfterDetail)
    return $row
}

#endregion

#region Readers

function Read-RulesetFile {
    <#
    .SYNOPSIS
    Parses a level, stage or endpoint file into Name, Description, Rules (ordered id -> Action, Justification) and Path.
    .DESCRIPTION
    Throws on invalid JSON, an action outside Error, Warning, Info, Hidden and None, an includedRuleSets or
    generalAction property, and an id listed twice.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "File not found: $Path" }
    return ConvertFrom-RulesetText -Text (Get-Content -LiteralPath $Path -Raw) -Path $Path
}

function Read-StageFile {
    <#
    .SYNOPSIS
    Parses one stages/<stage>.json like Read-RulesetFile; throws for stages/default.json (C6).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    Assert-NotDefaultStageFile -Path $Path
    return Read-RulesetFile -Path $Path
}

function Resolve-LevelChain {
    <#
    .SYNOPSIS
    Walks basedOn from each published level to its root and composes the chain, root file first, last file wins.
    .DESCRIPTION
    Returns Chains (slug -> ordered id -> Action, Slug, Justification; Slug is the file that set the id) and
    ChainFiles (slug -> the slugs of the files on the chain, root first). A level file that basedOn reaches but
    that has no settings entry is a root (D29). Throws on an unresolved basedOn or a cycle (C5).
    #>
    [CmdletBinding(DefaultParameterSetName = 'Files')]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Levels,
        [Parameter(Mandatory, ParameterSetName = 'Files')][System.Collections.IDictionary]$LevelFiles,
        [Parameter(Mandatory, ParameterSetName = 'Directory')][string]$BaseDir
    )
    if ($PSCmdlet.ParameterSetName -eq 'Directory') {
        $LevelFiles = Get-OrdinalMap
        if (Test-Path -LiteralPath $BaseDir -PathType Container) {
            foreach ($file in Get-ChildItem -LiteralPath $BaseDir -File -Filter '*.ruleset.json') {
                $LevelFiles[$file.Name -replace '\.ruleset\.json$', ''] = Read-RulesetFile -Path $file.FullName
            }
        }
    }
    $entries = @($Levels | ForEach-Object { ConvertTo-LevelEntry $_ })
    $basedOn = @{}
    $names = @{}
    foreach ($entry in $entries) {
        $basedOn[$entry.Slug] = $entry.BasedOn
        $names[$entry.Slug] = $entry.Name
    }

    $chains = Get-OrdinalMap
    $chainFiles = Get-OrdinalMap
    foreach ($entry in $entries) {
        if (-not $LevelFiles.Contains($entry.Slug)) {
            throw "Missing level file base/$($entry.Slug).ruleset.json for level '$($entry.Name)'"
        }
        $path = [System.Collections.Generic.List[string]]::new()
        $current = $entry.Slug
        while ($null -ne $current) {
            if ($path.Contains($current)) {
                throw "basedOn cycle: $((@($path) + $current) -join ' -> ')"
            }
            $path.Add($current)
            $next = if ($basedOn.ContainsKey($current)) { $basedOn[$current] } else { $null }
            if ($null -ne $next -and -not $LevelFiles.Contains($next)) {
                $label = if ($names.ContainsKey($current)) { $names[$current] } else { $current }
                throw "Unresolved basedOn '$next' of level '$label'"
            }
            $current = $next
        }
        $path.Reverse()
        $chain = Get-OrdinalMap
        foreach ($slug in $path) {
            foreach ($rule in $LevelFiles[$slug].Rules.GetEnumerator()) {
                $chain[$rule.Key] = [pscustomobject]@{ Action = $rule.Value.Action; Slug = $slug; Justification = $rule.Value.Justification }
            }
        }
        $chains[$entry.Slug] = $chain
        $chainFiles[$entry.Slug] = $path.ToArray()
    }
    return [pscustomobject]@{ PSTypeName = 'Rulebook.LevelChains'; Chains = $chains; ChainFiles = $chainFiles }
}

function Read-Overrides {
    <#
    .SYNOPSIS
    Parses overrides.json into entries with Id, Action, Levels, Stages, Justification, Specificity (0 to 2) and Index.
    .DESCRIPTION
    With -Inputs every entry gets UnknownSelectors (selector values that are not a settings slug); -Strict makes an
    unknown slug throw. Validate reads without -Strict and reports C10.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Name fixed by issue #5; the file is overrides.json')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, $Inputs, [switch]$Strict)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "File not found: $Path" }
    $levelSlugs = if ($null -ne $Inputs) { [string[]]@($Inputs.Levels | ForEach-Object { $_.Slug }) } else { $null }
    $stageSlugs = if ($null -ne $Inputs) { [string[]]@($Inputs.Stages | ForEach-Object { $_.Slug }) } else { $null }
    return ConvertFrom-OverridesText -Text (Get-Content -LiteralPath $Path -Raw) -Path $Path -LevelSlugs $levelSlugs -StageSlugs $stageSlugs -Strict:$Strict
}

function Read-Quarantine {
    <#
    .SYNOPSIS
    Parses one quarantine.<stage>.json into an ordered map id -> justification ($null when absent).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "File not found: $Path" }
    return ConvertFrom-QuarantineText -Text (Get-Content -LiteralPath $Path -Raw) -Path $Path
}

function Read-Twins {
    <#
    .SYNOPSIS
    Parses base/twins.json into Pairs (Pte, AppSource, Title), the PteSides and AppSourceSides sets and Count.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Name fixed by issue #5; the file is twins.json')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "File not found: $Path" }
    return ConvertFrom-TwinsText -Text (Get-Content -LiteralPath $Path -Raw) -Path $Path
}

function Read-Catalog {
    <#
    .SYNOPSIS
    Parses catalog/diagnostics.json into a map id -> DefaultSeverity, EnabledByDefault, Default.
    .DESCRIPTION
    Default is the severity when the id is enabled by default, else None. Throws on an entry without
    defaultSeverity or enabledByDefault (C14).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "File not found: $Path" }
    return ConvertFrom-CatalogText -Text (Get-Content -LiteralPath $Path -Raw) -Path $Path
}

function Get-AnalyzerDefault {
    <#
    .SYNOPSIS
    The analyzer default of an id: the default severity when enabled by default, else None; $null for an unknown id.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowNull()]$Catalog, [Parameter(Mandatory)][string]$Id)
    if ($null -eq $Catalog -or -not $Catalog.ContainsKey($Id)) { return $null }
    return $Catalog[$Id].Default
}

function Read-RulebookInputs {
    <#
    .SYNOPSIS
    Reads every generator input of an organization rulebook repository, from the working tree or from a git ref.
    .DESCRIPTION
    Returns a Rulebook.Inputs object (docs/rulebook/composition.md). Missing overrides.json, quarantine files or
    base/twins.json count as empty. Absent settings give an empty rulebook (SettingsPresent false), which is how
    Compare-RulebookEndpoints treats a ref that predates the rulebook. Throws on a missing catalog, level file or
    stage file and on an unresolved basedOn or a cycle.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'The inputs are one object of many files')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepositoryRoot, [string]$Ref)
    $source = Get-FileSource -Root $RepositoryRoot -Ref $Ref
    $inputs = [pscustomobject]@{
        PSTypeName      = 'Rulebook.Inputs'
        Root            = $source.Root
        Source          = $source.Source
        SettingsPresent = $false
        Settings        = $null
        Levels          = @()
        Stages          = @()
        TwinsSetting    = 'both'
        Twins           = Get-EmptyTwinSet
        LevelFiles      = Get-OrdinalMap
        Chains          = Get-OrdinalMap
        ChainFiles      = Get-OrdinalMap
        StageDeltas     = Get-OrdinalMap
        Overrides       = @()
        OverridesById   = @{}
        Quarantine      = Get-OrdinalMap
        Catalog         = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
    }

    $settingsText = Read-SourceText -Source $source -Path $script:SettingsPath
    if ($null -eq $settingsText) {
        $catalogText = Read-SourceText -Source $source -Path $script:CatalogPath
        if ($null -ne $catalogText) { $inputs.Catalog = ConvertFrom-CatalogText -Text $catalogText -Path $script:CatalogPath }
        return $inputs
    }
    $settings = ConvertFrom-JsonText -Text $settingsText -Path $script:SettingsPath
    $inputs.SettingsPresent = $true
    $inputs.Settings = $settings
    $inputs.Levels = @($settings['levels'] | Where-Object { $null -ne $_ } | ForEach-Object { ConvertTo-LevelEntry $_ })
    $inputs.Stages = @($settings['stages'] | Where-Object { $null -ne $_ } | ForEach-Object {
            [pscustomobject]@{ Name = [string]$_['name']; Slug = Get-Slug $_['name']; Description = $_['description'] }
        })
    foreach ($kind in @(@{ Name = 'levels'; Items = $inputs.Levels }, @{ Name = 'stages'; Items = $inputs.Stages })) {
        # The slug becomes a file name and a URL segment: no dots, no slashes, unique per array (C5).
        $seen = Get-OrdinalSet
        foreach ($item in $kind.Items) {
            if ($null -eq $item.Slug -or $item.Slug -cnotmatch '^[a-z0-9-]+\z') {
                throw "$($script:SettingsPath)`: $($kind.Name) entry '$($item.Name)' does not lowercase to a slug matching ^[a-z0-9-]+$ (C5)"
            }
            if (-not $seen.Add($item.Slug)) { throw "$($script:SettingsPath)`: $($kind.Name) slug '$($item.Slug)' is used twice (C5)" }
        }
    }
    if ($settings.Contains('twins') -and $null -ne $settings['twins']) {
        $twinsSetting = [string]$settings['twins']
        if ($twinsSetting -cnotin 'both', 'appsource', 'pte') {
            throw "$($script:SettingsPath)`: twins is '$twinsSetting'; allowed are both, appsource and pte (C5)"
        }
        $inputs.TwinsSetting = $twinsSetting
    }

    $twinsText = Read-SourceText -Source $source -Path $script:TwinsPath
    if ($null -ne $twinsText) { $inputs.Twins = ConvertFrom-TwinsText -Text $twinsText -Path $script:TwinsPath }

    foreach ($path in Get-SourcePath -Source $source -Directory 'base' -Filter '*.ruleset.json') {
        $slug = (Split-Path -Leaf $path) -replace '\.ruleset\.json$', ''
        $inputs.LevelFiles[$slug] = ConvertFrom-RulesetText -Text (Read-SourceText -Source $source -Path $path) -Path $path
    }
    $resolved = Resolve-LevelChain -Levels $inputs.Levels -LevelFiles $inputs.LevelFiles
    $inputs.Chains = $resolved.Chains
    $inputs.ChainFiles = $resolved.ChainFiles

    if (@(Get-SourcePath -Source $source -Directory 'stages' -Filter 'default.json').Count -gt 0) {
        throw 'stages/default.json must not exist; the default stage is the level result (C6)'
    }
    foreach ($stage in $inputs.Stages) {
        if ($stage.Slug -eq 'default') { continue }
        $path = "stages/$($stage.Slug).json"
        $text = Read-SourceText -Source $source -Path $path
        if ($null -eq $text) { throw "Missing stage file $path for stage '$($stage.Name)'" }
        $inputs.StageDeltas[$stage.Slug] = (ConvertFrom-RulesetText -Text $text -Path $path).Rules
    }

    $overridesText = Read-SourceText -Source $source -Path $script:OverridesPath
    if ($null -ne $overridesText) {
        $inputs.Overrides = ConvertFrom-OverridesText -Text $overridesText -Path $script:OverridesPath `
            -LevelSlugs ([string[]]@($inputs.Levels | ForEach-Object { $_.Slug })) -StageSlugs ([string[]]@($inputs.Stages | ForEach-Object { $_.Slug }))
        foreach ($override in $inputs.Overrides) {
            if (-not $inputs.OverridesById.ContainsKey($override.Id)) {
                $inputs.OverridesById[$override.Id] = [System.Collections.Generic.List[object]]::new()
            }
            $inputs.OverridesById[$override.Id].Add($override)
        }
    }

    foreach ($stage in $inputs.Stages) {
        $path = "quarantine.$($stage.Slug).json"
        $text = Read-SourceText -Source $source -Path $path
        $inputs.Quarantine[$stage.Slug] = if ($null -ne $text) { ConvertFrom-QuarantineText -Text $text -Path $path } else { Get-OrdinalMap }
    }

    $catalogText = Read-SourceText -Source $source -Path $script:CatalogPath
    if ($null -eq $catalogText) { throw "Catalog missing: $($script:CatalogPath) in $($source.Source) of $($source.Root)" }
    $inputs.Catalog = ConvertFrom-CatalogText -Text $catalogText -Path $script:CatalogPath
    return $inputs
}

#endregion

#region Precedence and endpoints

function Get-EffectiveAction {
    <#
    .SYNOPSIS
    The effective action of one id in one endpoint, with the input that decided it.
    .DESCRIPTION
    Precedence (D19, D23, D27, D41): matching override (highest specificity, then the later entry), else None for the
    losing twin side, else the stage entry where the level result is not None (S-4), else the level result. The level
    result is the chain where a file mentions the id, else None when the stage's quarantine lists it, else the
    analyzer default. Returns Id, Action, Source (override, twins, stage:<slug>, level:<slug>, quarantine, default),
    Detail (the deciding entry's justification or the twin pair title), Default and Listed.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Inputs')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Inputs')]$Inputs,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Level,
        [Parameter(Mandatory)][string]$Stage,
        [Parameter(ParameterSetName = 'Explicit')][AllowNull()][System.Collections.IDictionary]$Chain,
        [Parameter(ParameterSetName = 'Explicit')][AllowNull()][System.Collections.IDictionary]$StageDelta,
        [Parameter(ParameterSetName = 'Explicit')][AllowNull()]$Twins,
        [Parameter(ParameterSetName = 'Explicit')][ValidateSet('both', 'appsource', 'pte')][string]$TwinsSetting = 'both',
        [Parameter(ParameterSetName = 'Explicit')][AllowNull()][AllowEmptyCollection()][object[]]$Overrides,
        [Parameter(ParameterSetName = 'Explicit')][AllowNull()][System.Collections.IDictionary]$Quarantine,
        [Parameter(Mandatory, ParameterSetName = 'Explicit')][AllowNull()]$Catalog
    )
    if ($PSCmdlet.ParameterSetName -eq 'Inputs') {
        if ($null -eq (Get-InputsLevel -Inputs $Inputs -Level $Level)) { throw "Unknown level slug '$Level'" }
        if ($null -eq (Get-InputsStage -Inputs $Inputs -Stage $Stage)) { throw "Unknown stage slug '$Stage'" }
        return Resolve-EffectiveFromInput -Inputs $Inputs -Id $Id -Level $Level -Stage $Stage
    }
    return Resolve-Effective -Id $Id -Level $Level -Stage $Stage -Chain $Chain -StageDelta $StageDelta -Twins $Twins `
        -TwinsSetting $TwinsSetting -Overrides $Overrides -Quarantine $Quarantine -Catalog $Catalog
}

function Get-EndpointFileName {
    <#
    .SYNOPSIS
    The file name of an endpoint in rulesets/: <level>.ruleset.json for the default stage, else <level>.<stage>.ruleset.json.
    .DESCRIPTION
    -Level and -Stage are slugs. The literal 'default' is dropped only here (ARCHITECTURE.md section 6.1); a
    skeleton is always <level>.<stage>.ruleset.json. Rulebook.Template and Rulebook.Publish use this name too.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Level, [Parameter(Mandatory)][string]$Stage)
    if ($Stage -ceq 'default') { return "$Level.ruleset.json" }
    return "$Level.$Stage.ruleset.json"
}

function Get-SkeletonFileName {
    <#
    .SYNOPSIS
    The file name of a skeleton in skeletons/: always <level>.<stage>.ruleset.json, the default stage included.
    .DESCRIPTION
    -Level and -Stage are slugs. Rulebook.Template writes the skeletons under this name and Rulebook.Publish stages
    and links them under it.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Level, [Parameter(Mandatory)][string]$Stage)
    return "$Level.$Stage.ruleset.json"
}

function Get-RulebookEndpoint {
    <#
    .SYNOPSIS
    Computes one endpoint: Level, Stage, Key, File, Name, Description, Entries and Table.
    .DESCRIPTION
    Entries are the candidate ids whose effective action differs from the analyzer default, sorted by
    Get-DiagnosticSortKey. Candidates are the chain ids, the stage file ids, the override ids, the twin sides and the
    stage's quarantine ids. Table holds the result for every candidate. -Level and -Stage are slugs.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Root')]
    param(
        [Parameter(Mandatory)][string]$Level,
        [Parameter(Mandatory)][string]$Stage,
        [Parameter(Mandatory, ParameterSetName = 'Root')][string]$RepositoryRoot,
        [Parameter(Mandatory, ParameterSetName = 'Inputs')]$Inputs
    )
    if ($PSCmdlet.ParameterSetName -eq 'Root') { $Inputs = Read-RulebookInputs -RepositoryRoot $RepositoryRoot }
    $levelEntry = Get-InputsLevel -Inputs $Inputs -Level $Level
    if ($null -eq $levelEntry) { throw "Unknown level slug '$Level'" }
    $stageEntry = Get-InputsStage -Inputs $Inputs -Stage $Stage
    if ($null -eq $stageEntry) { throw "Unknown stage slug '$Stage'" }

    $chain = $Inputs.Chains[$Level]
    $stageDelta = if ($Inputs.StageDeltas.Contains($Stage)) { $Inputs.StageDeltas[$Stage] } else { $null }
    $quarantine = if ($Inputs.Quarantine.Contains($Stage)) { $Inputs.Quarantine[$Stage] } else { $null }

    $seen = Get-OrdinalSet
    $candidates = [System.Collections.Generic.List[string]]::new()
    $sources = @(
        @($chain.Keys)
        $(if ($null -ne $stageDelta) { @($stageDelta.Keys) })
        @($Inputs.OverridesById.Keys)
        @($Inputs.Twins.Pairs | ForEach-Object { $_.Pte; $_.AppSource })
        $(if ($null -ne $quarantine) { @($quarantine.Keys) })
    )
    foreach ($id in $sources) { if ($null -ne $id -and $seen.Add([string]$id)) { $candidates.Add([string]$id) } }

    $table = Get-OrdinalMap
    $listed = [System.Collections.Generic.List[object]]::new()
    foreach ($id in $candidates) {
        $overrides = @(if ($Inputs.OverridesById.ContainsKey($id)) { $Inputs.OverridesById[$id] })
        $result = Resolve-Effective -Id $id -Level $Level -Stage $Stage -Chain $chain -StageDelta $stageDelta `
            -Twins $Inputs.Twins -TwinsSetting $Inputs.TwinsSetting -Overrides $overrides -Quarantine $quarantine -Catalog $Inputs.Catalog
        $table[$id] = $result
        if ($result.Listed) { $listed.Add($result) }
    }

    return [pscustomobject]@{
        PSTypeName  = 'Rulebook.Endpoint'
        Level       = $Level
        Stage       = $Stage
        Key         = "$Level.$Stage"
        File        = 'rulesets/' + (Get-EndpointFileName -Level $Level -Stage $Stage)
        Name        = "Rulebook $($levelEntry.Name) / $($stageEntry.Name)"
        Description = Get-EndpointDescription -Inputs $Inputs -Level $Level -Stage $Stage
        Entries     = @(Get-SortedById -Items $listed.ToArray())
        Table       = $table
    }
}

function Get-EndpointPlan {
    # The plan of Update-RulebookEndpoints and Get-RulebookEndpointChange for one Rulebook.Inputs of the working
    # tree: Existing (file name to full path of each rulesets/*.ruleset.json), Planned ({File, Change, Path, Bytes}
    # per levels x stages endpoint whose bytes differ, in levels x stages order), Orphans (the existing file names no
    # endpoint produces, ordinal order) and Directory. Reads the existing endpoints, writes nothing.
    param([Parameter(Mandatory)]$Inputs)
    if (-not $Inputs.SettingsPresent) { throw "Settings missing: $($script:SettingsPath) in $($Inputs.Root)" }
    $directory = Join-Path $Inputs.Root 'rulesets'

    $existing = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
    if (Test-Path -LiteralPath $directory -PathType Container) {
        foreach ($file in Get-ChildItem -LiteralPath $directory -File -Filter '*.ruleset.json') {
            if ($file.Name -like '*.ruleset.json') { $existing[$file.Name] = $file.FullName }
        }
    }

    $planned = [System.Collections.Generic.List[object]]::new()
    $expected = Get-OrdinalSet
    foreach ($level in $Inputs.Levels) {
        foreach ($stage in $Inputs.Stages) {
            $endpoint = Get-RulebookEndpoint -Inputs $Inputs -Level $level.Slug -Stage $stage.Slug
            $text = ConvertTo-RulesetJson -Name $endpoint.Name -Description $endpoint.Description -Rules $endpoint.Entries
            $bytes = $script:Utf8NoBom.GetBytes($text)
            $leaf = Split-Path -Leaf $endpoint.File
            [void]$expected.Add($leaf)
            $change = $null
            if (-not $existing.ContainsKey($leaf)) {
                $change = 'created'
            } elseif (-not [System.Linq.Enumerable]::SequenceEqual([byte[]][System.IO.File]::ReadAllBytes($existing[$leaf]), [byte[]]$bytes)) {
                $change = 'modified'
            }
            if ($null -ne $change) {
                $planned.Add([pscustomobject]@{ File = $endpoint.File; Change = $change; Path = (Join-Path $directory $leaf); Bytes = $bytes })
            }
        }
    }
    [string[]]$orphans = @($existing.Keys | Where-Object { -not $expected.Contains($_) })
    [System.Array]::Sort($orphans, [System.StringComparer]::Ordinal)
    return [pscustomobject]@{ Existing = $existing; Planned = $planned.ToArray(); Orphans = $orphans; Directory = $directory }
}

function Get-RulebookEndpointChange {
    <#
    .SYNOPSIS
    The endpoint files Update-RulebookEndpoints would write or delete, without writing anything: the regeneration
    check C12.
    .DESCRIPTION
    Returns one Rulebook.EndpointChange per file, File (repository-relative, '/') and Change (created, modified,
    deleted), in the order of the Update-RulebookEndpoints -WhatIf list: the written endpoints in levels x stages
    order, the deletions last. -Inputs reuses a Read-RulebookInputs result of the working tree of the same
    repository; without it the inputs are read. Throws when the settings file is missing.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepositoryRoot, [AllowNull()]$Inputs)
    if ($null -eq $Inputs) { $Inputs = Read-RulebookInputs -RepositoryRoot $RepositoryRoot }
    $plan = Get-EndpointPlan -Inputs $Inputs
    $changes = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $plan.Planned) {
        $changes.Add([pscustomobject]@{ PSTypeName = 'Rulebook.EndpointChange'; File = $item.File; Change = $item.Change })
    }
    foreach ($leaf in $plan.Orphans) {
        $changes.Add([pscustomobject]@{ PSTypeName = 'Rulebook.EndpointChange'; File = "rulesets/$leaf"; Change = 'deleted' })
    }
    return $changes.ToArray()
}

function Update-RulebookEndpoints {
    <#
    .SYNOPSIS
    Regenerates every levels x stages endpoint in rulesets/ and removes the endpoint files no entry produces.
    .DESCRIPTION
    Writes only files whose bytes differ (UTF-8 without BOM, LF, trailing newline). Returns one object per changed
    file: File (repository-relative, '/') and Change (created, modified, deleted). With -WhatIf nothing is written
    and the same list is returned (the list Get-RulebookEndpointChange returns without the What if lines). -Inputs
    reuses a Read-RulebookInputs result of the working tree of the same repository.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Name fixed by issue #5; it writes the whole endpoint set')]
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$RepositoryRoot, [AllowNull()]$Inputs)
    if ($null -eq $Inputs) { $Inputs = Read-RulebookInputs -RepositoryRoot $RepositoryRoot }
    $plan = Get-EndpointPlan -Inputs $Inputs
    $directory = $plan.Directory
    $existing = $plan.Existing

    $changes = [System.Collections.Generic.List[object]]::new()
    # Deletions first: on a case-insensitive file system an orphan 'Strict.ruleset.json' is the same file as the
    # 'strict.ruleset.json' written below.
    # A change is reported when it was made, or under -WhatIf (that list is the C12 contract); a change declined at
    # a -Confirm prompt is not reported.
    $deleted = [System.Collections.Generic.List[string]]::new()
    foreach ($leaf in $plan.Orphans) {
        $file = "rulesets/$leaf"
        if ($PSCmdlet.ShouldProcess($file, 'Delete endpoint no levels x stages entry produces')) {
            [System.IO.File]::Delete($existing[$leaf])
            $deleted.Add($file)
        } elseif ($WhatIfPreference) {
            $deleted.Add($file)
        }
    }
    foreach ($item in $plan.Planned) {
        if ($PSCmdlet.ShouldProcess($item.File, "Write endpoint ($($item.Change))")) {
            if (-not (Test-Path -LiteralPath $directory -PathType Container)) { [void][System.IO.Directory]::CreateDirectory($directory) }
            [System.IO.File]::WriteAllBytes($item.Path, $item.Bytes)
        } elseif (-not $WhatIfPreference) {
            continue
        }
        $changes.Add([pscustomobject]@{ PSTypeName = 'Rulebook.EndpointChange'; File = $item.File; Change = $item.Change })
    }
    foreach ($file in $deleted) {
        $changes.Add([pscustomobject]@{ PSTypeName = 'Rulebook.EndpointChange'; File = $file; Change = 'deleted' })
    }
    return $changes.ToArray()
}

function Compare-RulebookEndpoints {
    <#
    .SYNOPSIS
    The effective diff per endpoint between a git ref (before) and the working tree (after).
    .DESCRIPTION
    Compares effective actions, not JSON lines. One row per endpoint and id whose action changed (Change 'action') or
    whose listed status changed while the action stayed (Change 'listing'). An endpoint only on one side gives one row
    per listed id with Change 'endpoint-added' or 'endpoint-removed' (one row with Id $null when it lists none).
    Every catalog id whose default differs between the two sides is compared too, so a changed default surfaces with
    'default' provenance on both sides. Rows are ordered by endpoint (settings order) and Get-DiagnosticSortKey.
    -Inputs reuses a Read-RulebookInputs result of the working tree (the after side); the ref side is always read.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Name fixed by issue #5; it compares the whole endpoint set')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepositoryRoot, [Parameter(Mandatory)][string]$Ref, [AllowNull()]$Inputs)
    $after = if ($null -ne $Inputs) { $Inputs } else { Read-RulebookInputs -RepositoryRoot $RepositoryRoot }
    $before = Read-RulebookInputs -RepositoryRoot $RepositoryRoot -Ref $Ref

    $changedDefaults = [System.Collections.Generic.List[string]]::new()
    $allIds = Get-OrdinalSet
    foreach ($id in @($before.Catalog.Keys) + @($after.Catalog.Keys)) {
        if (-not $allIds.Add($id)) { continue }
        if ((Get-AnalyzerDefault -Catalog $before.Catalog -Id $id) -cne (Get-AnalyzerDefault -Catalog $after.Catalog -Id $id)) {
            $changedDefaults.Add($id)
        }
    }

    # Endpoint keys: settings order of the working tree, then the endpoints only the ref has.
    $keys = [System.Collections.Generic.List[object]]::new()
    $seenKeys = Get-OrdinalSet
    foreach ($side in $after, $before) {
        foreach ($level in $side.Levels) {
            foreach ($stage in $side.Stages) {
                if ($seenKeys.Add("$($level.Slug).$($stage.Slug)")) {
                    $keys.Add([pscustomobject]@{ Level = $level.Slug; Stage = $stage.Slug })
                }
            }
        }
    }

    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($key in $keys) {
        $inBefore = $null -ne (Get-InputsLevel -Inputs $before -Level $key.Level) -and $null -ne (Get-InputsStage -Inputs $before -Stage $key.Stage)
        $inAfter = $null -ne (Get-InputsLevel -Inputs $after -Level $key.Level) -and $null -ne (Get-InputsStage -Inputs $after -Stage $key.Stage)
        $endpointKey = "$($key.Level).$($key.Stage)"
        $file = 'rulesets/' + (Get-EndpointFileName -Level $key.Level -Stage $key.Stage)

        if ($inBefore -and $inAfter) {
            $old = Get-RulebookEndpoint -Inputs $before -Level $key.Level -Stage $key.Stage
            $new = Get-RulebookEndpoint -Inputs $after -Level $key.Level -Stage $key.Stage
            $universe = Get-OrdinalSet
            foreach ($id in @($old.Table.Keys) + @($new.Table.Keys) + $changedDefaults.ToArray()) { [void]$universe.Add($id) }
            foreach ($id in Get-SortedById -Items ([string[]]@($universe))) {
                $b = if ($old.Table.Contains($id)) { $old.Table[$id] } else { Resolve-EffectiveFromInput -Inputs $before -Id $id -Level $key.Level -Stage $key.Stage }
                $a = if ($new.Table.Contains($id)) { $new.Table[$id] } else { Resolve-EffectiveFromInput -Inputs $after -Id $id -Level $key.Level -Stage $key.Stage }
                $change = if ($b.Action -cne $a.Action) { 'action' } elseif ($b.Listed -ne $a.Listed) { 'listing' } else { $null }
                if ($null -ne $change) { $rows.Add((ConvertTo-DiffRow -Endpoint $endpointKey -File $file -Id $id -Before $b -After $a -Change $change)) }
            }
        } elseif ($inAfter) {
            $new = Get-RulebookEndpoint -Inputs $after -Level $key.Level -Stage $key.Stage
            if ($new.Entries.Count -eq 0) { $rows.Add((ConvertTo-DiffRow -Endpoint $endpointKey -File $file -Id $null -Before $null -After $null -Change 'endpoint-added')) }
            foreach ($entry in $new.Entries) { $rows.Add((ConvertTo-DiffRow -Endpoint $endpointKey -File $file -Id $entry.Id -Before $null -After $entry -Change 'endpoint-added')) }
        } else {
            $old = Get-RulebookEndpoint -Inputs $before -Level $key.Level -Stage $key.Stage
            if ($old.Entries.Count -eq 0) { $rows.Add((ConvertTo-DiffRow -Endpoint $endpointKey -File $file -Id $null -Before $null -After $null -Change 'endpoint-removed')) }
            foreach ($entry in $old.Entries) { $rows.Add((ConvertTo-DiffRow -Endpoint $endpointKey -File $file -Id $entry.Id -Before $entry -After $null -Change 'endpoint-removed')) }
        }
    }
    return $rows.ToArray()
}

#endregion

#region Writer

function ConvertTo-JsonString {
    <#
    .SYNOPSIS
    A JSON string literal, quotes included; null for $null.
    .DESCRIPTION
    Escapes only backslash, double quote and control characters; < > & ' and non-ASCII characters are written as
    they are (ConvertTo-Json would escape them). Shared by every hand-rolled writer of the engine, so a title or a
    justification is written the same way in every file.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) { return 'null' }
    if ($Value -notmatch '[\\"\x00-\x1f]') { return '"' + $Value + '"' }
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

function ConvertTo-RulesetJson {
    <#
    .SYNOPSIS
    The deterministic text of a ruleset file: $schema (optional), name, description, rules with one rule per line.
    .DESCRIPTION
    Hand-rolled rather than ConvertTo-Json: the documented examples and fixtures use one rule per line, and
    ConvertTo-Json uses the platform newline and cannot emit one-line objects. Two-space indent, LF line ends, one
    trailing LF; an empty rules array is written as []. Rules are objects or dictionaries with Id and Action (and
    Justification, written with -IncludeJustification when set). The order of -Rules is kept. -Schema writes a
    "$schema" line before name (the shipped level and stage files carry the delta profile URL); without it the text
    has no $schema, which is what endpoints and skeletons need.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()][AllowEmptyString()][string]$Description,
        [AllowNull()][AllowEmptyCollection()][object[]]$Rules = @(),
        [switch]$IncludeJustification,
        [AllowNull()][AllowEmptyString()][string]$Schema
    )
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('{')
    if (-not [string]::IsNullOrEmpty($Schema)) { $lines.Add('  "$schema": ' + (ConvertTo-JsonString $Schema) + ',') }
    $lines.Add('  "name": ' + (ConvertTo-JsonString $Name) + ',')
    if (-not [string]::IsNullOrEmpty($Description)) { $lines.Add('  "description": ' + (ConvertTo-JsonString $Description) + ',') }
    $items = @($Rules | Where-Object { $null -ne $_ })
    if ($items.Count -eq 0) {
        $lines.Add('  "rules": []')
    } else {
        $lines.Add('  "rules": [')
        for ($i = 0; $i -lt $items.Count; $i++) {
            $rule = $items[$i]
            $line = '    { "id": ' + (ConvertTo-JsonString ([string](Get-MemberValue $rule 'Id'))) + ', "action": ' + (ConvertTo-JsonString ([string](Get-MemberValue $rule 'Action')))
            $justification = Get-MemberValue $rule 'Justification'
            if ($IncludeJustification -and -not [string]::IsNullOrEmpty($justification)) {
                $line += ', "justification": ' + (ConvertTo-JsonString ([string]$justification))
            }
            $line += ' }'
            if ($i -lt $items.Count - 1) { $line += ',' }
            $lines.Add($line)
        }
        $lines.Add('  ]')
    }
    $lines.Add('}')
    return ($lines -join "`n") + "`n"
}

function Get-DiagnosticSortKey {
    <#
    .SYNOPSIS
    Sort key of a diagnostic id: prefix in the fixed order AL, AA, AW, PTE, AS, PC, AC, LC, DC, FC, TA, CM, then the
    number, then the i suffix. Unknown prefixes sort last, by prefix.
    .DESCRIPTION
    The key is fixed-width ASCII and is compared ordinally: culture-aware sorting would depend on the runner's
    locale. The tools under tools/rulebook/ import this module for the key: Extract-Inventory sorts the inventory
    with it and Test-Rulebook (V1) checks that the inventory is in ascending key order.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Id)
    # Never throws: an id that does not match the pattern, or whose number has more than six digits, sorts after
    # every other id ('~' is above every letter and digit in ASCII).
    $match = [regex]::Match($Id, '^([A-Z]+)([0-9]+)(i?)$')
    if (-not $match.Success -or $match.Groups[2].Value.Length -gt 6) { return '99~' + $Id }
    $index = [System.Array]::IndexOf($script:PrefixOrder, $match.Groups[1].Value)
    $head = if ($index -ge 0) { '{0:00}' -f $index } else { '99' + $match.Groups[1].Value }
    $suffix = if ($match.Groups[3].Value -ceq 'i') { '1' } else { '0' }
    return $head + ('{0:000000}' -f [long]$match.Groups[2].Value) + $suffix
}

#endregion

Export-ModuleMember -Function @(
    'Compare-RulebookEndpoints'
    'ConvertTo-JsonString'
    'ConvertTo-RulesetJson'
    'Get-AnalyzerDefault'
    'Get-DiagnosticSortKey'
    'Get-EffectiveAction'
    'Get-EndpointFileName'
    'Get-RulebookEndpoint'
    'Get-RulebookEndpointChange'
    'Get-SkeletonFileName'
    'Read-Catalog'
    'Read-Overrides'
    'Read-Quarantine'
    'Read-RulebookInputs'
    'Read-RulesetFile'
    'Read-StageFile'
    'Read-Twins'
    'Resolve-LevelChain'
    'Update-RulebookEndpoints'
)
