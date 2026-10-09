#requires -Version 7.4
# Rulebook.Template: generates the template content (template/ in this repository, deployed to ALCops/rulebook)
# from the engine's level content in docs/rulebook/: the level files and base/twins.json, the stage files, the seed
# catalog and the skeletons. The endpoints in rulesets/ come from Update-RulebookEndpoints of Rulebook.Generate.
# Contract: docs/rulebook/composition.md section 3. File by file: docs/reference/template-content.md.

Set-StrictMode -Version 3.0
Import-Module (Join-Path $PSScriptRoot 'Rulebook.Generate.psd1')
# The catalog writer (ConvertTo-CatalogJson) is shared with the scan.
Import-Module (Join-Path $PSScriptRoot 'Rulebook.Catalog.psd1')

$script:Actions = @('Error', 'Warning', 'Info', 'Hidden', 'None')
$script:Severities = @('Error', 'Warning', 'Info', 'Hidden')
$script:DeltaSchemaUrl = 'https://raw.githubusercontent.com/ALCops/rulebook-engine/v1/schemas/ruleset.delta.schema.json'
$script:TwinsSchemaUrl = 'https://raw.githubusercontent.com/ALCops/rulebook-engine/v1/schemas/rulebook-twins.schema.json'
$script:GeneratedNote = 'Generated from docs/rulebook; do not edit.'
$script:SkeletonDescription = 'Copy into your AL project and point al.ruleSetPath or the AL-Go rulesetFile at it. Add project exceptions to rules; they override the endpoint.'
$script:TwinsGeneratedBy = 'tools/rulebook/Build-Template.ps1'
$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

#region Internal helpers

function Get-OrdinalMap {
    # An insertion-ordered map with ordinal keys ([ordered]@{} compares keys case-insensitively).
    return , [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::Ordinal)
}

function Get-TextValue {
    # A text field of the matrix input. ConvertFrom-Json -AsHashtable turns an ISO date-time string into a
    # [DateTime] (pwsh 7.4 has no -DateKind); such a value would be written in a culture format, so it is refused.
    param($Value, [Parameter(Mandatory)][string]$What)
    if ($null -eq $Value) { return '' }
    if ($Value -isnot [string]) { throw "$What is not text; ConvertFrom-Json read it as $($Value.GetType().Name)" }
    return $Value
}

function Read-JsonFile {
    # Parses a JSON file into hashtables; throws 'File not found' or 'Invalid JSON in <path>'. An array is
    # enumerated into the pipeline; the callers collect it with @().
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "File not found: $Path" }
    try {
        $json = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable -Depth 10 -ErrorAction Stop
    } catch {
        throw "Invalid JSON in ${Path}: $($_.Exception.Message)"
    }
    return $json
}

function Read-MatrixObject {
    # A matrix file whose root is an object holding Keys.
    param([Parameter(Mandatory)][string]$RulebookDir, [Parameter(Mandatory)][string]$RelativePath, [string[]]$Keys = @())
    $json = Read-JsonFile -Path (Join-Path $RulebookDir $RelativePath)
    if ($json -isnot [System.Collections.IDictionary]) { throw "${RelativePath}: the root is not an object" }
    foreach ($key in $Keys) {
        if (-not $json.Contains($key)) { throw "${RelativePath} has no '$key'" }
    }
    return , $json
}

function Join-JsonLine {
    # The text of a hand-rolled JSON file: LF line ends and one trailing LF.
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Lines)
    return ($Lines -join "`n") + "`n"
}

function Add-JsonArrayLine {
    # Appends "  "<Key>": [" with one item per line and the commas, then "  ]"; "  "<Key>": []" without items. The
    # array is the last property of its object (no comma after it).
    param([Parameter(Mandatory)][System.Collections.Generic.List[string]]$Lines, [Parameter(Mandatory)][string]$Key, [AllowEmptyCollection()][string[]]$Items = @())
    if ($Items.Count -eq 0) {
        $Lines.Add('  "' + $Key + '": []')
        return
    }
    $Lines.Add('  "' + $Key + '": [')
    for ($i = 0; $i -lt $Items.Count; $i++) {
        $Lines.Add('    ' + $Items[$i] + $(if ($i -lt $Items.Count - 1) { ',' } else { '' }))
    }
    $Lines.Add('  ]')
}

function Get-InventoryDefault {
    # default(id) of composition.md section 3 before a catalog exists: the inventory Default when Enabled, else None.
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Row)
    if ($Row['enabled'] -eq $true) { return [string]$Row['default'] }
    return 'None'
}

function ConvertTo-SlugEntry {
    # Name and slug of a level or stage entry; the slug is the lowercased name and must match ^[a-z0-9-]+$ (C5).
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Name, [Parameter(Mandatory)][string]$Kind, [Parameter(Mandatory)][string]$Source)
    $slug = $Name.ToLowerInvariant()
    if ($slug -cnotmatch '^[a-z0-9-]+\z') {
        throw "${Source}: $Kind entry '$Name' does not lowercase to a slug matching ^[a-z0-9-]+$ (C5)"
    }
    return [pscustomobject]@{ Name = $Name; Slug = $slug }
}

function Assert-UniqueSlug {
    param([object[]]$Entries, [Parameter(Mandatory)][string]$Kind, [Parameter(Mandatory)][string]$Source)
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($entry in $Entries) {
        if (-not $seen.Add($entry.Slug)) { throw "${Source}: $Kind slug '$($entry.Slug)' is used twice (C5)" }
    }
}

function Read-MatrixInput {
    # Reads the engine's level content and checks what the generators rely on. Throws (an engine tool, not a
    # validation): the matrix must mirror the inventory row by row, every id must have its resolved cells, the
    # levels must form a basedOn tree of slugs, the stages must include default and name a matrix column each.
    param([Parameter(Mandatory)][string]$RulebookDir)
    $inventory = @(Read-JsonFile -Path (Join-Path $RulebookDir 'inventory/inventory.json'))
    $matrix = @(Read-JsonFile -Path (Join-Path $RulebookDir 'matrix/matrix.json'))
    $resolved = Read-MatrixObject -RulebookDir $RulebookDir -RelativePath 'matrix/resolved.json'
    $levelsJson = Read-MatrixObject -RulebookDir $RulebookDir -RelativePath 'matrix/levels.json' -Keys 'levels'
    $stagesJson = Read-MatrixObject -RulebookDir $RulebookDir -RelativePath 'matrix/stages.json' -Keys 'stages'
    $twinsJson = Read-MatrixObject -RulebookDir $RulebookDir -RelativePath 'matrix/twins.json' -Keys 'pairs', 'values'

    if ($matrix.Count -ne $inventory.Count) {
        throw "matrix/matrix.json has $($matrix.Count) rows, inventory/inventory.json $($inventory.Count); run Build-Matrix.ps1"
    }
    $byMatrixId = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
    for ($i = 0; $i -lt $inventory.Count; $i++) {
        if ($inventory[$i] -isnot [System.Collections.IDictionary] -or $matrix[$i] -isnot [System.Collections.IDictionary]) {
            throw "inventory/inventory.json or matrix/matrix.json: row $i is not an object"
        }
        $id = [string]$inventory[$i]['id']
        if ($inventory[$i]['enabled'] -isnot [bool]) { throw "inventory/inventory.json: $id has no boolean enabled" }
        if ([string]$inventory[$i]['default'] -cnotin $script:Severities) {
            throw "inventory/inventory.json: $id has default '$($inventory[$i]['default'])'; allowed are Error, Warning, Info and Hidden"
        }
        if ([string]$matrix[$i]['id'] -cne $id) {
            throw "matrix/matrix.json row $i is $($matrix[$i]['id']), inventory/inventory.json row $i is $id; the order must match (run Build-Matrix.ps1)"
        }
        if (-not $resolved.Contains($id)) { throw "matrix/resolved.json has no cells for $id" }
        $byMatrixId[$id] = $matrix[$i]
    }

    $levels = @(foreach ($level in @($levelsJson['levels'])) {
            $entry = ConvertTo-SlugEntry -Name ([string]$level['name']) -Kind 'levels' -Source 'matrix/levels.json'
            if ($level.Contains('slug') -and [string]$level['slug'] -cne $entry.Slug) {
                throw "matrix/levels.json: level '$($entry.Name)' has slug '$($level['slug'])', expected '$($entry.Slug)'"
            }
            $entry | Add-Member -NotePropertyName BasedOnName -NotePropertyValue $(if ($level.Contains('basedOn')) { [string]$level['basedOn'] } else { $null })
            $entry
        })
    if ($levels.Count -eq 0) { throw 'matrix/levels.json lists no level' }
    Assert-UniqueSlug -Entries $levels -Kind 'levels' -Source 'matrix/levels.json'
    foreach ($level in $levels) {
        $basedOn = $null
        if (-not [string]::IsNullOrEmpty($level.BasedOnName)) {
            # basedOn holds the display name; it is matched case-insensitively, like the settings (naming.md section 1).
            $target = @($levels | Where-Object { $_.Slug -ceq $level.BasedOnName.ToLowerInvariant() })
            if ($target.Count -eq 0) { throw "matrix/levels.json: unresolved basedOn '$($level.BasedOnName)' of level '$($level.Name)'" }
            $basedOn = $target[0].Slug
        }
        $level | Add-Member -NotePropertyName BasedOn -NotePropertyValue $basedOn
    }
    foreach ($level in $levels) {
        $path = [System.Collections.Generic.List[string]]::new()
        $current = $level
        while ($null -ne $current) {
            if ($path.Contains($current.Slug)) { throw "matrix/levels.json: basedOn cycle: $((@($path) + $current.Slug) -join ' -> ')" }
            $path.Add($current.Slug)
            $next = $current.BasedOn
            $current = if ($null -eq $next) { $null } else { @($levels | Where-Object { $_.Slug -ceq $next })[0] }
        }
    }

    $stages = @(foreach ($stage in @($stagesJson['stages'])) { ConvertTo-SlugEntry -Name ([string]$stage['name']) -Kind 'stages' -Source 'matrix/stages.json' })
    Assert-UniqueSlug -Entries $stages -Kind 'stages' -Source 'matrix/stages.json'
    if (@($stages | Where-Object { $_.Slug -ceq 'default' }).Count -eq 0) { throw 'matrix/stages.json has no default stage' }

    foreach ($row in $inventory) {
        $id = [string]$row['id']
        $cells = $resolved[$id]
        if ($cells -isnot [System.Collections.IDictionary]) { throw "matrix/resolved.json: the cells of $id are not an object" }
        foreach ($level in $levels) {
            $key = "$($level.Slug).default"
            if (-not $cells.Contains($key)) { throw "matrix/resolved.json has no cell $key for $id" }
            if ([string]$cells[$key] -cnotin $script:Actions) { throw "matrix/resolved.json: $id has action '$($cells[$key])' at $key; allowed are Error, Warning, Info, Hidden and None" }
        }
        foreach ($stage in @($stages | Where-Object { $_.Slug -cne 'default' })) {
            $matrixRow = $byMatrixId[$id]
            if (-not $matrixRow.Contains($stage.Name)) { throw "matrix/matrix.json: $id has no column '$($stage.Name)' for stage '$($stage.Slug)'" }
            $column = [string]$matrixRow[$stage.Name]
            if ($column -cne '=' -and $column -cnotin $script:Actions) {
                throw "matrix/matrix.json: $id has '$column' in column $($stage.Name); allowed are =, Error, Warning, Info, Hidden and None"
            }
        }
    }

    # Twin pairs sorted by Get-DiagnosticSortKey of the PTE side; a side in two pairs throws.
    $sortedPairs = [System.Collections.Generic.SortedDictionary[string, object]]::new([System.StringComparer]::Ordinal)
    $sides = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($pair in @($twinsJson['pairs'] | Where-Object { $null -ne $_ })) {
        if ($pair -isnot [System.Collections.IDictionary]) { throw 'matrix/twins.json has a pair that is not an object' }
        $item = [pscustomobject]@{
            Pte       = [string]$pair['pte']
            AppSource = [string]$pair['appsource']
            Title     = Get-TextValue $pair['title'] -What "matrix/twins.json: the title of the pair $($pair['pte'])"
        }
        if ([string]::IsNullOrEmpty($item.Pte) -or [string]::IsNullOrEmpty($item.AppSource)) { throw 'matrix/twins.json has a pair without a pte or an appsource id' }
        foreach ($side in $item.Pte, $item.AppSource) {
            if (-not $sides.Add($side)) { throw "matrix/twins.json lists $side in two pairs" }
        }
        $sortedPairs.Add((Get-DiagnosticSortKey -Id $item.Pte), $item)
    }

    return [pscustomobject]@{
        Inventory   = $inventory
        Matrix      = $matrix
        ByMatrixId  = $byMatrixId
        Resolved    = $resolved
        Levels      = $levels
        Stages      = $stages
        TwinPairs   = @($sortedPairs.Values)
        TwinsValues = @($twinsJson['values'] | ForEach-Object { [string]$_ })
    }
}

function Write-GeneratedFile {
    # Writes Text (UTF-8 without BOM) to Path when the bytes differ. Returns a Rulebook.TemplateChange, or nothing
    # when the file is current. Under -WhatIf nothing is written and the change is still returned; a change declined
    # at a -Confirm prompt is not returned (as Update-RulebookEndpoints does). -WhatIf and -Confirm reach it from the
    # calling generator through the preference variables.
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$File,
        [Parameter(Mandatory)][string]$Text,
        [Nullable[bool]]$Exists
    )
    $bytes = $script:Utf8NoBom.GetBytes($Text)
    $present = if ($null -ne $Exists) { [bool]$Exists } else { Test-Path -LiteralPath $Path -PathType Leaf }
    $change = $null
    if (-not $present) {
        $change = 'created'
    } elseif (-not [System.Linq.Enumerable]::SequenceEqual([byte[]][System.IO.File]::ReadAllBytes($Path), [byte[]]$bytes)) {
        $change = 'modified'
    }
    if ($null -eq $change) { return }
    if ($PSCmdlet.ShouldProcess($File, "Write template file ($change)")) {
        $parent = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) { [void][System.IO.Directory]::CreateDirectory($parent) }
        [System.IO.File]::WriteAllBytes($Path, $bytes)
    } elseif (-not $WhatIfPreference) {
        return
    }
    return [pscustomobject]@{ PSTypeName = 'Rulebook.TemplateChange'; File = $File; Path = $Path; Change = $change }
}

function Remove-OrphanFile {
    # Deletes a generated file no input produces any more; same reporting rules as Write-GeneratedFile.
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$File
    )
    if ($PSCmdlet.ShouldProcess($File, 'Delete template file no input produces')) {
        [System.IO.File]::Delete($Path)
    } elseif (-not $WhatIfPreference) {
        return
    }
    return [pscustomobject]@{ PSTypeName = 'Rulebook.TemplateChange'; File = $File; Path = $Path; Change = 'deleted' }
}

function Sync-GeneratedFolder {
    <#
    .SYNOPSIS
    Makes a folder hold exactly the given generated files among the files matching -Filter.
    .DESCRIPTION
    -Files maps a leaf name to its text. Deletes the other files matching -Filter first (on a case-insensitive file
    system an orphan 'Strict.ruleset.json' is the file 'strict.ruleset.json' written next), then writes the files
    whose bytes differ (UTF-8 without BOM), in the order of -Files. Returns one Rulebook.TemplateChange { File
    (<folder leaf>/<leaf>), Path, Change (created, modified, deleted) } per change; -WhatIf writes nothing and returns
    the same list. Shared by the generators of this module and New-RulebookLevelDocs (Rulebook.Levels).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType('Rulebook.TemplateChange')]
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$Filter,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Files
    )
    $folder = Split-Path -Leaf $Directory
    $existing = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
    if (Test-Path -LiteralPath $Directory -PathType Container) {
        foreach ($file in Get-ChildItem -LiteralPath $Directory -File -Filter $Filter) {
            if ($file.Name -like $Filter) { $existing[$file.Name] = $file.FullName }
        }
    }
    [string[]]$orphans = @($existing.Keys | Where-Object { -not $Files.Contains($_) })
    [System.Array]::Sort($orphans, [System.StringComparer]::Ordinal)
    foreach ($leaf in $orphans) {
        Remove-OrphanFile -Path $existing[$leaf] -File "$folder/$leaf"
    }
    foreach ($leaf in $Files.Keys) {
        Write-GeneratedFile -Path (Join-Path $Directory $leaf) -File "$folder/$leaf" -Text $Files[$leaf] -Exists $existing.ContainsKey($leaf)
    }
}

function ConvertTo-TwinsJson {
    # base/twins.json in the layout of the test fixtures: one pair per line, $schema first, title only when set.
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Values, [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Pairs)
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('{')
    $lines.Add('  "$schema": ' + (ConvertTo-JsonString $script:TwinsSchemaUrl) + ',')
    $lines.Add('  "generatedBy": ' + (ConvertTo-JsonString $script:TwinsGeneratedBy) + ',')
    $lines.Add('  "setting": "twins",')
    $lines.Add('  "values": [' + (@($Values | ForEach-Object { ConvertTo-JsonString $_ }) -join ', ') + '],')
    $lines.Add('  "count": ' + $Pairs.Count + ',')
    $items = foreach ($pair in $Pairs) {
        $item = '{ "pte": ' + (ConvertTo-JsonString $pair.Pte) + ', "appsource": ' + (ConvertTo-JsonString $pair.AppSource)
        if (-not [string]::IsNullOrEmpty($pair.Title)) { $item += ', "title": ' + (ConvertTo-JsonString $pair.Title) }
        $item + ' }'
    }
    Add-JsonArrayLine -Lines $lines -Key 'pairs' -Items @($items)
    $lines.Add('}')
    return Join-JsonLine -Lines $lines
}

function ConvertTo-SkeletonJson {
    # A skeleton: one include of the endpoint with {BASEURL}, rendered by Publish into the published copy (WP05).
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$EndpointFile)
    $include = '{ "action": "Default", "path": ' + (ConvertTo-JsonString "{BASEURL}/rulesets/$EndpointFile") + ' }'
    return Join-JsonLine -Lines @(
        '{'
        '  "name": ' + (ConvertTo-JsonString $Name) + ','
        '  "description": ' + (ConvertTo-JsonString $script:SkeletonDescription) + ','
        '  "includedRuleSets": [ ' + $include + ' ],'
        '  "rules": []'
        '}'
    )
}

#endregion

#region Generators

function Build-RulebookBase {
    <#
    .SYNOPSIS
    Writes one base/<slug>.ruleset.json per entry of matrix/levels.json, and base/twins.json.
    .DESCRIPTION
    A root level lists the ids whose default-stage cell in matrix/resolved.json differs from the analyzer default
    (inventory Default when Enabled, else None); every other level the ids whose cell differs from the cell of its
    basedOn level. Entries in inventory order with the action and the matrix row Justification; the files carry
    the delta profile URL in $schema. base/twins.json is matrix/twins.json with $schema, the pairs sorted by
    Get-DiagnosticSortKey of the PTE side. Other *.ruleset.json files in the folder are deleted. Every text is built
    and checked before the first write. Writes only files whose bytes differ and returns one Rulebook.TemplateChange
    per change; -WhatIf writes nothing.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType('Rulebook.TemplateChange')]
    param([Parameter(Mandatory)][string]$RulebookDir, [Parameter(Mandatory)][string]$OutputPath)
    $matrixInput = Read-MatrixInput -RulebookDir $RulebookDir

    $files = Get-OrdinalMap
    foreach ($level in $matrixInput.Levels) {
        $key = "$($level.Slug).default"
        $rules = [System.Collections.Generic.List[object]]::new()
        foreach ($row in $matrixInput.Inventory) {
            $id = [string]$row['id']
            $cells = $matrixInput.Resolved[$id]
            $below = if ($null -eq $level.BasedOn) { Get-InventoryDefault -Row $row } else { [string]$cells["$($level.BasedOn).default"] }
            $action = [string]$cells[$key]
            if ($action -cne $below) {
                $justification = Get-TextValue $matrixInput.ByMatrixId[$id]['Justification'] -What "matrix/matrix.json: the justification of $id"
                $rules.Add([pscustomobject]@{ Id = $id; Action = $action; Justification = $justification })
            }
        }
        $description = if ($null -eq $level.BasedOn) {
            "Level $($level.Slug), the root. Lists the ids whose action differs from the analyzer default. $($script:GeneratedNote)"
        } else {
            "Level $($level.Slug), basedOn $($level.BasedOn). Lists the ids whose action differs from $($level.BasedOn). $($script:GeneratedNote)"
        }
        $files["$($level.Slug).ruleset.json"] = ConvertTo-RulesetJson -Name "Rulebook $($level.Name)" -Description $description `
            -Rules $rules.ToArray() -IncludeJustification -Schema $script:DeltaSchemaUrl
    }
    $twinsText = ConvertTo-TwinsJson -Values $matrixInput.TwinsValues -Pairs $matrixInput.TwinPairs

    Sync-GeneratedFolder -Directory $OutputPath -Filter '*.ruleset.json' -Files $files
    Write-GeneratedFile -Path (Join-Path $OutputPath 'twins.json') -File "$(Split-Path -Leaf $OutputPath)/twins.json" -Text $twinsText
}

function Build-RulebookStages {
    <#
    .SYNOPSIS
    Writes one stages/<slug>.json per non-default entry of matrix/stages.json.
    .DESCRIPTION
    Lists the ids whose matrix.json column named after the stage (CI, vNext) is not '=', in inventory order, with
    that action and the matrix row Justification, and the delta profile URL in $schema. There is no file for the
    default stage; other *.json files in the folder are deleted. Same change reporting and -WhatIf as
    Build-RulebookBase.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Writes the whole stage set; name fixed by issue #6')]
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType('Rulebook.TemplateChange')]
    param([Parameter(Mandatory)][string]$RulebookDir, [Parameter(Mandatory)][string]$OutputPath)
    $matrixInput = Read-MatrixInput -RulebookDir $RulebookDir
    $files = Get-OrdinalMap
    foreach ($stage in @($matrixInput.Stages | Where-Object { $_.Slug -cne 'default' })) {
        $rules = [System.Collections.Generic.List[object]]::new()
        foreach ($row in $matrixInput.Inventory) {
            $id = [string]$row['id']
            $matrixRow = $matrixInput.ByMatrixId[$id]
            $column = [string]$matrixRow[$stage.Name]
            if ($column -cne '=') {
                $justification = Get-TextValue $matrixRow['Justification'] -What "matrix/matrix.json: the justification of $id"
                $rules.Add([pscustomobject]@{ Id = $id; Action = $column; Justification = $justification })
            }
        }
        $description = "Stage $($stage.Slug). Applied on top of every level where the level result is not None. $($script:GeneratedNote)"
        $files["$($stage.Slug).json"] = ConvertTo-RulesetJson -Name "Rulebook stage $($stage.Name)" -Description $description `
            -Rules $rules.ToArray() -IncludeJustification -Schema $script:DeltaSchemaUrl
    }
    Sync-GeneratedFolder -Directory $OutputPath -Filter '*.json' -Files $files
}

function Build-RulebookCatalog {
    <#
    .SYNOPSIS
    Writes the seed catalog/diagnostics.json: one entry per inventory id with its analyzer default.
    .DESCRIPTION
    Entries in inventory order with id, analyzer, defaultSeverity, enabledByDefault, title and docs (the last two only
    when not empty), one per line, under $schema and "version": 1. No package, version or channel keys: the first
    scan (WP08) adds them. -OutputPath is the file. Same change reporting and -WhatIf as Build-RulebookBase.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType('Rulebook.TemplateChange')]
    param([Parameter(Mandatory)][string]$RulebookDir, [Parameter(Mandatory)][string]$OutputPath)
    $matrixInput = Read-MatrixInput -RulebookDir $RulebookDir
    $entries = foreach ($row in $matrixInput.Inventory) {
        $id = [string]$row['id']
        # default and enabled are checked by Read-MatrixInput.
        [pscustomobject]@{
            Id               = $id
            Analyzer         = Get-TextValue $row['analyzer'] -What "inventory/inventory.json: the analyzer of $id"
            DefaultSeverity  = [string]$row['default']
            EnabledByDefault = [bool]$row['enabled']
            Title            = Get-TextValue $row['title'] -What "inventory/inventory.json: the title of $id"
            Docs             = Get-TextValue $row['docs'] -What "inventory/inventory.json: the docs URL of $id"
        }
    }
    $text = ConvertTo-CatalogJson -Entries @($entries)
    $file = '{0}/{1}' -f (Split-Path -Leaf (Split-Path -Parent $OutputPath)), (Split-Path -Leaf $OutputPath)
    Write-GeneratedFile -Path $OutputPath -File $file -Text $text
}

function New-RulebookSkeleton {
    <#
    .SYNOPSIS
    Writes one skeletons/<level>.<stage>.ruleset.json per level and stage of the settings.
    .DESCRIPTION
    Each skeleton includes {BASEURL}/rulesets/<level>[.<stage>].ruleset.json (the default stage drops the suffix
    in the endpoint name only) with action Default and has an empty rules array; name 'Rulebook <Level> / <Stage>'
    with the settings casing, no $schema. Other *.ruleset.json files in the folder are deleted. Does not check
    basedOn or twins; Update-RulebookEndpoints does. Same change reporting and -WhatIf as Build-RulebookBase.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType('Rulebook.TemplateChange')]
    param([Parameter(Mandatory)][string]$SettingsPath, [Parameter(Mandatory)][string]$OutputPath)
    $settings = Read-JsonFile -Path $SettingsPath
    if ($settings -isnot [System.Collections.IDictionary]) { throw "${SettingsPath}: the root is not an object" }
    $levels = @(foreach ($level in @($settings['levels'] | Where-Object { $null -ne $_ })) { ConvertTo-SlugEntry -Name ([string]$level['name']) -Kind 'levels' -Source $SettingsPath })
    $stages = @(foreach ($stage in @($settings['stages'] | Where-Object { $null -ne $_ })) { ConvertTo-SlugEntry -Name ([string]$stage['name']) -Kind 'stages' -Source $SettingsPath })
    # No levels or stages would delete every skeleton; refuse instead (C5 reports the settings).
    if ($levels.Count -eq 0 -or $stages.Count -eq 0) { throw "${SettingsPath}: levels and stages must each list at least one entry (C5)" }
    Assert-UniqueSlug -Entries $levels -Kind 'levels' -Source $SettingsPath
    Assert-UniqueSlug -Entries $stages -Kind 'stages' -Source $SettingsPath

    $files = Get-OrdinalMap
    foreach ($level in $levels) {
        foreach ($stage in $stages) {
            $endpoint = Get-EndpointFileName -Level $level.Slug -Stage $stage.Slug
            $files[(Get-SkeletonFileName -Level $level.Slug -Stage $stage.Slug)] = ConvertTo-SkeletonJson -Name "Rulebook $($level.Name) / $($stage.Name)" -EndpointFile $endpoint
        }
    }
    Sync-GeneratedFolder -Directory $OutputPath -Filter '*.ruleset.json' -Files $files
}

#endregion

Export-ModuleMember -Function @(
    'Build-RulebookBase'
    'Build-RulebookCatalog'
    'Build-RulebookStages'
    'New-RulebookSkeleton'
    'Sync-GeneratedFolder'
)
