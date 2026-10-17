#requires -Version 7.4
# Rulebook.Site: the data side of the dashboard site (WP14, #16, D31, D36). Get-RulebookSiteModel turns the generator's
# inputs into one document: every catalog and input id with its cell per level and stage, the input that decided it
# and, for an override or quarantine cell, the action the cell would have without that input; the level and stage page
# models (Get-RulebookLevelSummary, Get-RulebookStageSummary); the overrides and the quarantine lists.
# ConvertTo-RulebookSiteDataJson writes it, and Export-RulebookSiteData writes site/data/rulebook.json, the file Hugo
# reads and the Publish action serves at <baseUrl>/rulebook.json. Contract: docs/dashboard.md section 5.
# Install-Hugo installs the pinned Hugo on a Linux runner and Build-RulebookSite builds site/ into the staging folder
# of Publish (docs/dashboard.md section 4).

Set-StrictMode -Version 3.0
Import-Module (Join-Path $PSScriptRoot 'Rulebook.Common.psd1')
Import-Module (Join-Path $PSScriptRoot 'Rulebook.Generate.psd1')
Import-Module (Join-Path $PSScriptRoot 'Rulebook.Catalog.psd1')
Import-Module (Join-Path $PSScriptRoot 'Rulebook.Levels.psd1')

$script:SettingsPath = '.github/Rulebook-Settings.json'
$script:CatalogPath = 'catalog/diagnostics.json'
# The data file of the site, relative to the repository root; site/data/ is excluded from the update comparison
# (Rulebook.Update) and gitignored once site/ ships.
$script:SiteDataPath = 'site/data/rulebook.json'
# The issue form the cart opens (template/.github/ISSUE_TEMPLATE/); a constant, no settings key.
$script:IssueTemplate = 'rulebook-change.yml'
# The attribute of the matrix root; Build-RulebookSite reports whether the built index.html carries it.
$script:MatrixMarker = 'data-rulebook-matrix'
# The user page the site links, on the template ref the engine ref maps to (Get-RulebookDocsUrl, D53).
$script:DashboardDocsPage = 'dashboard.md'
$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$script:Invariant = [System.Globalization.CultureInfo]::InvariantCulture
# Top-level keys whose object the writer puts one member per line by structure, not by content.
$script:MultiLineKeys = @('quarantine')

#region Internal helpers

function Get-SettingValue {
    # A key of the settings dictionary, or a nested key ('site', 'includeJustifications'); $null when absent.
    param($Settings, [Parameter(Mandatory)][string[]]$Path)
    $value = $Settings
    foreach ($key in $Path) {
        if ($value -isnot [System.Collections.IDictionary] -or -not $value.Contains($key)) { return $null }
        $value = $value[$key]
    }
    return $value
}

function Test-FlatJsonValue {
    # Whether a value is written inline: a scalar, or an array of scalars.
    param($Value)
    if ($null -eq $Value -or $Value -is [string] -or $Value -is [System.ValueType]) { return $true }
    if ($Value -is [System.Collections.IDictionary]) { return $false }
    if ($Value -is [System.Collections.IList]) {
        foreach ($item in $Value) {
            if (-not ($null -eq $item -or $item -is [string] -or $item -is [System.ValueType])) { return $false }
        }
        return $true
    }
    return $true
}

function ConvertTo-SiteJsonText {
    # The JSON text of a value of the site document at an indent. Objects whose values are all scalars or arrays of
    # scalars, and arrays of scalars, are written on one line; everything else one member or element per line, two
    # spaces deeper. Strings through ConvertTo-JsonString, like every engine writer. -MultiLine writes an object one
    # member per line whatever its values are: the quarantine object keeps its layout when every list is empty.
    param($Value, [int]$Indent = 0, [switch]$MultiLine)
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { return $(if ($Value) { 'true' } else { 'false' }) }
    if ($Value -is [string]) { return ConvertTo-JsonString $Value }
    if ($Value -is [System.ValueType]) { return [System.Convert]::ToString($Value, $script:Invariant) }
    $inner = ' ' * ($Indent + 2)
    $outer = ' ' * $Indent
    if ($Value -is [System.Collections.IDictionary]) {
        if ($Value.Count -eq 0) { return '{}' }
        $flat = -not $MultiLine
        foreach ($key in $Value.Keys) { if ($flat -and -not (Test-FlatJsonValue $Value[$key])) { $flat = $false } }
        if ($flat) {
            $members = foreach ($key in $Value.Keys) { (ConvertTo-JsonString ([string]$key)) + ': ' + (ConvertTo-SiteJsonText $Value[$key]) }
            return '{ ' + (@($members) -join ', ') + ' }'
        }
        $members = foreach ($key in $Value.Keys) {
            $inner + (ConvertTo-JsonString ([string]$key)) + ': ' + (ConvertTo-SiteJsonText $Value[$key] ($Indent + 2) -MultiLine:($Indent -eq 0 -and $key -cin $script:MultiLineKeys))
        }
        return "{`n" + (@($members) -join ",`n") + "`n$outer}"
    }
    if ($Value -is [System.Collections.IList]) {
        if ($Value.Count -eq 0) { return '[]' }
        if (Test-FlatJsonValue $Value) {
            $items = foreach ($item in $Value) { ConvertTo-SiteJsonText $item }
            return '[' + (@($items) -join ', ') + ']'
        }
        $items = foreach ($item in $Value) { $inner + (ConvertTo-SiteJsonText $item ($Indent + 2)) }
        return "[`n" + (@($items) -join ",`n") + "`n$outer]"
    }
    throw "The site document holds a value of type $($Value.GetType().FullName), which has no JSON form"
}

function Get-RuleJustification {
    # The level and stage justifications of one id from the engine's files, keyed by the source token of the file
    # (level:<slug>, stage:<slug>): the chain files of every published level root first, in settings order, then the
    # stage files in settings order. Public in every case (D36).
    param([Parameter(Mandatory)]$Inputs, [Parameter(Mandatory)][string]$Id)
    $result = [ordered]@{}
    foreach ($level in $Inputs.Levels) {
        foreach ($file in @($Inputs.ChainFiles[$level.Slug])) {
            $token = "level:$file"
            if ($result.Contains($token) -or -not $Inputs.LevelFiles.Contains($file)) { continue }
            $rules = $Inputs.LevelFiles[$file].Rules
            if ($rules.Contains($Id) -and -not [string]::IsNullOrEmpty($rules[$Id].Justification)) { $result[$token] = [string]$rules[$Id].Justification }
        }
    }
    foreach ($stage in $Inputs.Stages) {
        if (-not $Inputs.StageDeltas.Contains($stage.Slug)) { continue }
        $rules = $Inputs.StageDeltas[$stage.Slug]
        if ($rules.Contains($Id) -and -not [string]::IsNullOrEmpty($rules[$Id].Justification)) { $result["stage:$($stage.Slug)"] = [string]$rules[$Id].Justification }
    }
    return $result
}

function Get-CellFallback {
    # The action an override or quarantine cell would have without that input, from the generator's own resolver
    # (Get-EffectiveAction, Explicit set): the overrides of the id without the winning entry, or no quarantine.
    param([Parameter(Mandatory)]$Inputs, [Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$Level, [Parameter(Mandatory)][string]$Stage, [Parameter(Mandatory)]$Result)
    $stageDelta = if ($Inputs.StageDeltas.Contains($Stage)) { $Inputs.StageDeltas[$Stage] } else { $null }
    $quarantine = if ($Inputs.Quarantine.Contains($Stage)) { $Inputs.Quarantine[$Stage] } else { $null }
    $overrides = @(if ($Inputs.OverridesById.ContainsKey($Id)) { $Inputs.OverridesById[$Id] })
    if ($Result.Source -ceq 'override') {
        $overrides = @($overrides | Where-Object { -not [object]::ReferenceEquals($_, $Result.Entry) })
    } else {
        $quarantine = $null
    }
    return Get-EffectiveAction -Id $Id -Level $Level -Stage $Stage -Chain $Inputs.Chains[$Level] -StageDelta $stageDelta -Twins $Inputs.Twins `
        -TwinsSetting $Inputs.TwinsSetting -Overrides $overrides -Quarantine $quarantine -Catalog $Inputs.Catalog
}

function ConvertTo-CountsList {
    # The counts rows of a level or stage summary as document objects; Key is 'stage' or 'level'.
    param([AllowEmptyCollection()][object[]]$Counts, [Parameter(Mandatory)][string]$Key)
    return , @(foreach ($count in $Counts) {
            $name = if ($Key -ceq 'stage') { $count.Stage } else { $count.Level }
            [ordered]@{ $Key = $name; error = $count.Error; warning = $count.Warning; info = $count.Info; hidden = $count.Hidden; none = $count.None; listed = $count.Listed }
        })
}

#endregion

#region Model

function Get-RulebookSiteModel {
    <#
    .SYNOPSIS
    The document of rulebook.json (docs/dashboard.md section 5) for one organization repository, as ordered dictionaries.
    .DESCRIPTION
    -Inputs is a Rulebook.Inputs (Read-RulebookInputs), -Catalog the Rulebook.Catalog of the same repository
    (Read-CatalogFile, for analyzer, title and docs). Returns a Rulebook.SiteModel { Document, RuleCount, CellCount,
    UnknownIds }.

    Document keys in order: generatedAt (UTC, yyyy-MM-ddTHH:mm:ssZ; a -GeneratedAt of kind Unspecified, such as
    [datetime]'2026-10-17T00:00:00', is read as UTC, not as local time), repository (only when -Repository is set),
    baseUrl, issueTemplate (rulebook-change.yml), docsUrl (the dashboard user page for -EngineRef, Get-RulebookDocsUrl),
    levels (the keys of the minimal form, then the Get-RulebookLevelSummary model), stages (the same, then the
    Get-RulebookStageSummary model), rules, overrides, quarantine (every settings stage, empty arrays written).

    rules: the catalog ids and every id an endpoint lists as a candidate, sorted once by Get-DiagnosticSortKey; an id
    outside the catalog has unknown true and default null. Each rule has one cell per level and stage, keyed
    <level>.<stage>: { action, source } from the generator (Get-RulebookEndpoint, Get-EffectiveAction for an id the
    endpoint does not consider), plus override (the index of the winning entry in overrides.json), fallback and
    fallbackSource on an override cell and fallback and fallbackSource on a quarantine cell: the action the cell would
    have without that entry or that quarantine, computed by Get-EffectiveAction. justifications holds the level and
    stage justifications of the id keyed by source token (level:<slug>, stage:<slug>); the override and quarantine
    justifications are written only with -IncludeJustifications (D36). Pure.
    #>
    [CmdletBinding()]
    [OutputType('Rulebook.SiteModel')]
    param(
        [Parameter(Mandatory)]$Inputs,
        [Parameter(Mandatory)]$Catalog,
        [Parameter(Mandatory)][string]$BaseUrl,
        [AllowNull()][AllowEmptyString()][string]$Repository,
        [switch]$IncludeJustifications,
        [datetime]$GeneratedAt = [datetime]::UtcNow,
        [AllowEmptyString()][string]$EngineRef
    )
    $levels = @($Inputs.Levels)
    $stages = @($Inputs.Stages)
    $endpoints = Get-OrdinalMap
    foreach ($level in $levels) {
        foreach ($stage in $stages) { $endpoints["$($level.Slug).$($stage.Slug)"] = Get-RulebookEndpoint -Inputs $Inputs -Level $level.Slug -Stage $stage.Slug }
    }

    # One sort over the catalog ids and the input ids (#51): the key of the endpoints, whatever input produced the id.
    $sortedIds = [System.Collections.Generic.SortedDictionary[string, string]]::new([System.StringComparer]::Ordinal)
    foreach ($id in $Inputs.Catalog.Keys) { $sortedIds[(Get-DiagnosticSortKey -Id $id) + '|' + $id] = $id }
    foreach ($endpoint in $endpoints.Values) {
        foreach ($id in $endpoint.Table.Keys) { $sortedIds[(Get-DiagnosticSortKey -Id $id) + '|' + $id] = $id }
    }

    $rules = [System.Collections.Generic.List[object]]::new()
    $unknownIds = [System.Collections.Generic.List[string]]::new()
    $cellCount = 0
    foreach ($id in $sortedIds.Values) {
        $known = $Inputs.Catalog.ContainsKey($id)
        $info = Get-CatalogRowInfo -Catalog $Catalog -Id $id
        $rule = [ordered]@{
            id               = $id
            analyzer         = $info.Analyzer
            title            = $info.Title
            docsUrl          = $info.Docs
            default          = if ($known) { $Inputs.Catalog[$id].DefaultSeverity } else { $null }
            enabledByDefault = if ($known) { [bool]$Inputs.Catalog[$id].EnabledByDefault } else { $null }
        }
        if (-not $known) {
            $rule['unknown'] = $true
            $unknownIds.Add($id)
        }
        $rule['justifications'] = Get-RuleJustification -Inputs $Inputs -Id $id
        $cells = [ordered]@{}
        foreach ($level in $levels) {
            foreach ($stage in $stages) {
                $key = "$($level.Slug).$($stage.Slug)"
                $table = $endpoints[$key].Table
                $result = if ($table.Contains($id)) { $table[$id] } else { Get-EffectiveAction -Inputs $Inputs -Id $id -Level $level.Slug -Stage $stage.Slug }
                $cell = [ordered]@{ action = $result.Action; source = $result.Source }
                if ($result.Source -ceq 'override') { $cell['override'] = $result.Entry.Index }
                if ($result.Source -ceq 'override' -or $result.Source -ceq 'quarantine') {
                    $fallback = Get-CellFallback -Inputs $Inputs -Id $id -Level $level.Slug -Stage $stage.Slug -Result $result
                    $cell['fallback'] = $fallback.Action
                    $cell['fallbackSource'] = $fallback.Source
                }
                $cells[$key] = $cell
                $cellCount++
            }
        }
        $rule['cells'] = $cells
        $rules.Add($rule)
    }

    $levelItems = @(foreach ($level in $levels) {
            $summary = Get-RulebookLevelSummary -Inputs $Inputs -Catalog $Catalog -Level $level.Slug
            $item = [ordered]@{ name = [string]$level.Name; slug = [string]$level.Slug }
            if (-not [string]::IsNullOrEmpty([string]$level.BasedOn)) { $item['basedOn'] = [string]$level.BasedOn }
            if (-not [string]::IsNullOrEmpty([string]$level.Description)) { $item['description'] = [string]$level.Description }
            $item['file'] = $summary.File
            $item['chain'] = [string[]]@($summary.ChainFiles)
            $item['basedOnName'] = $summary.BasedOnName
            $item['basedOnPublished'] = [bool]$summary.BasedOnPublished
            $item['entryCount'] = $summary.EntryCount
            $item['loweredCount'] = $summary.LoweredCount
            $item['overrideCount'] = $summary.OverrideCount
            $item['counts'] = ConvertTo-CountsList -Counts @($summary.Counts) -Key 'stage'
            $item['entries'] = @(foreach ($row in $summary.Rows) {
                    [ordered]@{ id = $row.Id; analyzer = $row.Analyzer; title = $row.Title; from = $row.From; fromSource = $row.FromSource; to = $row.To; lowered = [bool]$row.Lowered; justification = $row.Justification }
                })
            $item
        })

    $stageItems = @(foreach ($stage in $stages) {
            $summary = Get-RulebookStageSummary -Inputs $Inputs -Catalog $Catalog -Stage $stage.Slug
            $item = [ordered]@{ name = [string]$stage.Name; slug = [string]$stage.Slug }
            if (-not [string]::IsNullOrEmpty([string]$stage.Description)) { $item['description'] = [string]$stage.Description }
            if ($null -ne $summary.File) { $item['file'] = $summary.File }
            $item['entryCount'] = $summary.EntryCount
            $item['quarantineCount'] = $summary.QuarantineCount
            $item['overrideCount'] = $summary.OverrideCount
            $item['counts'] = ConvertTo-CountsList -Counts @($summary.Counts) -Key 'level'
            $item['entries'] = @(foreach ($row in $summary.Rows) {
                    [ordered]@{
                        id = $row.Id; analyzer = $row.Analyzer; title = $row.Title; action = $row.Action; justification = $row.Justification
                        noEffect = [string[]]@($row.NoEffect); quarantined = [bool]$row.Quarantined; overridden = [string[]]@($row.Overridden)
                    }
                })
            $item
        })

    $overrideItems = @(foreach ($override in $Inputs.Overrides) {
            $item = [ordered]@{ id = $override.Id; action = $override.Action; levels = [string[]]@($override.Levels); stages = [string[]]@($override.Stages) }
            if ($IncludeJustifications -and -not [string]::IsNullOrEmpty($override.Justification)) { $item['justification'] = [string]$override.Justification }
            $item
        })

    $quarantine = [ordered]@{}
    foreach ($stage in $stages) {
        $map = if ($Inputs.Quarantine.Contains($stage.Slug)) { $Inputs.Quarantine[$stage.Slug] } else { $null }
        $quarantine[$stage.Slug] = @(if ($null -ne $map) {
                foreach ($pair in $map.GetEnumerator()) {
                    $item = [ordered]@{ id = [string]$pair.Key }
                    if ($IncludeJustifications -and -not [string]::IsNullOrEmpty([string]$pair.Value)) { $item['justification'] = [string]$pair.Value }
                    $item
                }
            })
    }

    # Unspecified is UTC: ToUniversalTime would read it as local time and shift the date on a machine east of UTC.
    if ($GeneratedAt.Kind -eq [System.DateTimeKind]::Unspecified) { $GeneratedAt = [datetime]::SpecifyKind($GeneratedAt, [System.DateTimeKind]::Utc) }
    $document = [ordered]@{ generatedAt = $GeneratedAt.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', $script:Invariant) }
    if (-not [string]::IsNullOrEmpty($Repository)) { $document['repository'] = $Repository }
    $document['baseUrl'] = $BaseUrl
    $document['issueTemplate'] = $script:IssueTemplate
    $document['docsUrl'] = Get-RulebookDocsUrl -Page $script:DashboardDocsPage -Ref $EngineRef
    $document['levels'] = $levelItems
    $document['stages'] = $stageItems
    $document['rules'] = $rules.ToArray()
    $document['overrides'] = $overrideItems
    $document['quarantine'] = $quarantine

    return [pscustomobject]@{
        PSTypeName = 'Rulebook.SiteModel'
        Document   = $document
        RuleCount  = $rules.Count
        CellCount  = $cellCount
        UnknownIds = $unknownIds.ToArray()
    }
}

function ConvertTo-RulebookSiteDataJson {
    <#
    .SYNOPSIS
    The text of rulebook.json from a Rulebook.SiteModel (Get-RulebookSiteModel).
    .DESCRIPTION
    Hand-rolled like the other engine writers: keys in the order of the document, generatedAt first as a string,
    two-space indent, objects whose values are all scalars or arrays of scalars on one line (a cell, a counts row, an
    entry, an override), arrays of scalars on one line, LF, one trailing LF. Strings through ConvertTo-JsonString.
    Byte-stable: the same model gives the same text, and two models of the same inputs differ only in generatedAt.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Model)
    return (ConvertTo-SiteJsonText $Model.Document 0) + "`n"
}

#endregion

#region Export

function Export-RulebookSiteData {
    <#
    .SYNOPSIS
    Writes site/data/rulebook.json of an organization repository: the document of Get-RulebookSiteModel.
    .DESCRIPTION
    Reads the inputs (or takes -Inputs, a Read-RulebookInputs result of the same root), the catalog (Read-CatalogFile)
    and site.includeJustifications from the settings (only the boolean true includes the override and quarantine
    justifications, D36). Writes UTF-8 without BOM to -OutFile (default <RepositoryRoot>/site/data/rulebook.json),
    creating the folder. Throws when the settings or the catalog are missing. -Inputs must be read from the same
    -RepositoryRoot: the model takes the defaults and the cells from it and the analyzer, title and docs from the
    catalog file of that root. -WhatIf writes nothing and still returns
    the object. Returns { Path, Bytes, RuleCount, LevelCount, StageCount, IncludeJustifications, GeneratedAt (the
    written text) }. Readers parse generatedAt as text (ConvertFrom-Json turns it into a DateTime, #62). A
    -GeneratedAt of kind Unspecified is read as UTC (Get-RulebookSiteModel).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$BaseUrl,
        [string]$OutFile,
        $Inputs,
        [AllowNull()][AllowEmptyString()][string]$Repository,
        [datetime]$GeneratedAt = [datetime]::UtcNow,
        [AllowEmptyString()][string]$EngineRef
    )
    $root = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RepositoryRoot)
    if ($null -eq $Inputs) { $Inputs = Read-RulebookInputs -RepositoryRoot $root }
    if (-not $Inputs.SettingsPresent) { throw "Settings missing: $($script:SettingsPath) in $root" }
    $include = (Get-SettingValue $Inputs.Settings @('site', 'includeJustifications')) -is [bool] -and (Get-SettingValue $Inputs.Settings @('site', 'includeJustifications'))
    $catalog = Read-CatalogFile -Path (Join-Path $root $script:CatalogPath)
    $model = Get-RulebookSiteModel -Inputs $Inputs -Catalog $catalog -BaseUrl $BaseUrl -Repository $Repository -IncludeJustifications:$include -GeneratedAt $GeneratedAt -EngineRef $EngineRef
    $bytes = $script:Utf8NoBom.GetBytes((ConvertTo-RulebookSiteDataJson -Model $model))
    $path = if ([string]::IsNullOrEmpty($OutFile)) { Join-Path $root $script:SiteDataPath } else { $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutFile) }

    if ($PSCmdlet.ShouldProcess($path, 'Write the site data')) {
        $parent = Split-Path -Parent $path
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) { [void][System.IO.Directory]::CreateDirectory($parent) }
        [System.IO.File]::WriteAllBytes($path, $bytes)
    }
    return [pscustomobject]@{
        Path                  = $path
        Bytes                 = $bytes.Length
        RuleCount             = $model.RuleCount
        LevelCount            = @($Inputs.Levels).Count
        StageCount            = @($Inputs.Stages).Count
        IncludeJustifications = [bool]$include
        GeneratedAt           = $model.Document['generatedAt']
    }
}

#endregion

#region Hugo

function Get-HugoVersionText {
    # The first line of 'hugo version', or $null when the command is not found or fails.
    param([Parameter(Mandatory)][string]$HugoPath)
    if ($null -eq (Get-Command -Name $HugoPath -ErrorAction SilentlyContinue)) { return $null }
    try {
        $text = @(& $HugoPath version 2>&1 | ForEach-Object { [string]$_ })
    } catch {
        return $null
    }
    if ($text.Count -eq 0) { return $null }
    return $text[0]
}

function Test-HugoInstallPlatform {
    # Install-Hugo installs the Debian package: Linux only (ubuntu-latest). A seam for the tests.
    return [bool]$IsLinux
}

function Invoke-HugoInstallCommand {
    # sudo dpkg -i <deb>; returns the exit code and the output. A seam for the tests.
    param([Parameter(Mandatory)][string]$Deb)
    $output = @(& sudo dpkg -i $Deb 2>&1 | ForEach-Object { [string]$_ })
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
}

function Install-Hugo {
    <#
    .SYNOPSIS
    Installs the pinned Hugo extended from its GitHub release on a Linux runner, checked against a pinned sha256.
    .DESCRIPTION
    Does nothing when 'hugo version' already reports v<Version> extended (Installed false). Otherwise, on Linux only,
    downloads hugo_extended_<Version>_linux-amd64.deb from -BaseUrl/v<Version>/ into -DownloadRoot (default the
    temporary folder), compares its SHA256 with -Sha256 (a mismatch deletes the file and throws naming both values),
    installs it with sudo dpkg -i and checks that 'hugo version' then reports v<Version> and extended. The action pins
    both values in actions/Publish/action.yaml (HUGO_VERSION, HUGO_SHA256). Returns { Path, Version (the version
    line), Installed, Deb (the downloaded file, $null when nothing was installed) }.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Runs on a disposable runner; the action step is the confirmation')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version,
        [Parameter(Mandatory)][ValidatePattern('^[0-9A-Fa-f]{64}$')][string]$Sha256,
        [string]$DownloadRoot = [System.IO.Path]::GetTempPath(),
        [string]$BaseUrl = 'https://github.com/gohugoio/hugo/releases/download'
    )
    $isPinned = { param($Text) -not [string]::IsNullOrEmpty($Text) -and $Text.Contains("v$Version") -and $Text.Contains('extended') }
    $current = Get-HugoVersionText -HugoPath 'hugo'
    if (& $isPinned $current) {
        return [pscustomobject]@{ Path = (Get-Command -Name 'hugo').Source; Version = $current; Installed = $false; Deb = $null }
    }
    if (-not (Test-HugoInstallPlatform)) {
        throw "Install-Hugo installs the Debian package of Hugo and runs on Linux only (found: $(if ($current) { $current } else { 'no hugo' })). Install Hugo $Version extended yourself and pass its path as the hugoPath input."
    }
    $name = "hugo_extended_$($Version)_linux-amd64.deb"
    $deb = Join-Path $DownloadRoot $name
    [void][System.IO.Directory]::CreateDirectory($DownloadRoot)
    Invoke-WebRequest -Uri "$($BaseUrl.TrimEnd('/'))/v$Version/$name" -OutFile $deb -TimeoutSec 120 -ErrorAction Stop
    $actual = (Get-FileHash -LiteralPath $deb -Algorithm SHA256).Hash
    if (-not [string]::Equals($actual, $Sha256, [System.StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $deb -Force
        throw "$name has SHA256 $($actual.ToLowerInvariant()), expected $($Sha256.ToLowerInvariant()); the file was deleted and Hugo is not installed."
    }
    $install = Invoke-HugoInstallCommand -Deb $deb
    if ($install.ExitCode -ne 0) { throw "sudo dpkg -i $name failed with exit code $($install.ExitCode): $(@($install.Output | Select-Object -Last 5) -join ' ')" }
    $after = Get-HugoVersionText -HugoPath 'hugo'
    if (-not (& $isPinned $after)) { throw "After installing $name, 'hugo version' reports '$after', not v$Version extended." }
    return [pscustomobject]@{ Path = (Get-Command -Name 'hugo').Source; Version = $after; Installed = $true; Deb = $deb }
}

function Build-RulebookSite {
    <#
    .SYNOPSIS
    Builds the site/ folder of an organization repository with Hugo into the staging folder of Publish.
    .DESCRIPTION
    Requires <SitePath>/hugo.yaml and <SitePath>/data/rulebook.json (Export-RulebookSiteData, or the staged copy).
    Runs <HugoPath> --source <SitePath> --destination <Destination> --baseURL <BaseUrl>/ --quiet --noBuildLock:
    without --cleanDestinationDir, because the staging folder already holds the endpoints, skeletons and data files;
    Hugo writes only what it renders, and its index.html replaces the plain one. -HugoPath is a command name or a path
    (a .ps1 stand-in works too). A missing command, a missing file or a non-zero exit throws; the exit message carries
    the last 20 lines of Hugo's output. Returns { Pages (every index.html under Destination, relative with '/', sorted
    ordinally), PageCount, Assets (the files under css/ and js/), MarkerPresent (index.html carries
    data-rulebook-matrix, the marker of the matrix page), Seconds, Output (Hugo's lines) }.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Writes only the staging folder the caller names')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$SitePath,
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][string]$Destination,
        [string]$HugoPath = 'hugo'
    )
    $site = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($SitePath)
    $target = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Destination)
    foreach ($required in 'hugo.yaml', 'data/rulebook.json') {
        if (-not (Test-Path -LiteralPath (Join-Path $site $required) -PathType Leaf)) { throw "The site has no $required in $site" }
    }
    $command = Get-Command -Name $HugoPath -ErrorAction SilentlyContinue
    if ($null -eq $command) { throw "Hugo was not found: '$HugoPath' is not a command or a file" }
    $arguments = @('--source', $site, '--destination', $target, '--baseURL', "$($BaseUrl.TrimEnd('/'))/", '--quiet', '--noBuildLock')
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $output = @(& $command @arguments 2>&1 | ForEach-Object { [string]$_ })
    $exitCode = $LASTEXITCODE
    $clock.Stop()
    if ($exitCode -ne 0) {
        $tail = @($output | Select-Object -Last 20) -join "`n"
        throw "Hugo failed with exit code $exitCode building $site`n$tail"
    }
    $relative = { param($Root, $Files) [string[]]$list = @($Files | ForEach-Object { [System.IO.Path]::GetRelativePath($Root, $_.FullName).Replace('\', '/') }); [System.Array]::Sort($list, [System.StringComparer]::Ordinal); , $list }
    $pages = & $relative $target @(Get-ChildItem -LiteralPath $target -Recurse -File -Filter 'index.html')
    $assets = & $relative $target @(foreach ($folder in 'css', 'js') { $path = Join-Path $target $folder; if (Test-Path -LiteralPath $path -PathType Container) { Get-ChildItem -LiteralPath $path -Recurse -File } })
    $index = Join-Path $target 'index.html'
    $marker = (Test-Path -LiteralPath $index -PathType Leaf) -and [System.IO.File]::ReadAllText($index).Contains($script:MatrixMarker)
    return [pscustomobject]@{
        Pages         = $pages
        PageCount     = $pages.Count
        Assets        = $assets
        MarkerPresent = [bool]$marker
        Seconds       = [math]::Round($clock.Elapsed.TotalSeconds, 2)
        Output        = $output
    }
}

#endregion

Export-ModuleMember -Function @(
    'Build-RulebookSite'
    'ConvertTo-RulebookSiteDataJson'
    'Export-RulebookSiteData'
    'Get-RulebookSiteModel'
    'Install-Hugo'
)
