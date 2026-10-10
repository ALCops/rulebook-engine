#requires -Version 7.4
# Rulebook.Catalog: catalog/diagnostics.json and catalog/scan-state.json of an organization rulebook repository
# (WP08, R9, D24, D46). Reads and writes the catalog with every scan field and unknown keys preserved, normalises
# docs URLs, applies one scanned package version to the catalog (Update-CatalogFromScan, pure) and keeps the scan
# state (which version of each package and channel was scanned last). ConvertTo-CatalogJson is the one catalog
# writer; Rulebook.Template uses it for the seed. Contract: docs/reference/scan-mechanics.md section 3.

Set-StrictMode -Version 3.0
Import-Module (Join-Path $PSScriptRoot 'Rulebook.Common.psd1')
Import-Module (Join-Path $PSScriptRoot 'Rulebook.Generate.psd1')
Import-Module (Join-Path $PSScriptRoot 'Rulebook.NuGet.psd1')

# The schema file names; the URL is built at call time from the engine ref (Get-RulebookSchemaUrl, D52).
$script:CatalogSchemaName = 'rulebook-catalog.schema.json'
$script:ScanStateSchemaName = 'rulebook-scan-state.schema.json'
$script:ToolsPackageId = 'microsoft.dynamics.businesscentral.development.tools'
$script:AlcopsPackageId = 'alcops.analyzers'
$script:PackageOrder = @($script:ToolsPackageId, $script:AlcopsPackageId)
$script:KnownKeys = @('id', 'analyzer', 'defaultSeverity', 'enabledByDefault', 'title', 'docs', 'package', 'firstSeenVersion', 'firstSeenChannel', 'firstStableVersion', 'lastSeenVersion', 'advertised', 'deprecated', 'defaultChanges')
$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$script:AlDocsUrl = 'https://learn.microsoft.com/dynamics365/business-central/dev-itpro/developer/diagnostics/diagnostic-al{0}'

#region Internal helpers

function Get-EntryValue {
    # A property of an entry object, $null when it has none (the seed entries of Rulebook.Template carry six).
    param($Entry, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Entry) { return $null }
    $property = $Entry.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function ConvertTo-TextOrNull {
    # A JSON value as text: ConvertFrom-Json -AsHashtable turns an ISO date-time string into a [DateTime] (pwsh 7.4 has
    # no -DateKind), which is written back as UTC with seconds.
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture) }
    if ($Value -is [System.DateTimeOffset]) { return $Value.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture) }
    return [string]$Value
}

function ConvertTo-JsonValue {
    # A JSON literal of a scalar or a structure; strings through ConvertTo-JsonString like every engine writer.
    param($Value)
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [string]) { return ConvertTo-JsonString -Value $Value }
    if ($Value -is [bool]) { return $Value.ToString().ToLowerInvariant() }
    if ($Value -is [datetime] -or $Value -is [System.DateTimeOffset]) { return ConvertTo-JsonString -Value (ConvertTo-TextOrNull $Value) }
    return ConvertTo-Json -InputObject $Value -Compress -Depth 10
}

function New-CatalogEntry {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an object; changes no state')]
    param([Parameter(Mandatory)][string]$Id)
    return [pscustomobject]@{
        PSTypeName         = 'Rulebook.CatalogEntry'
        Id                 = $Id
        Analyzer           = $null
        DefaultSeverity    = $null
        EnabledByDefault   = $true
        Title              = $null
        Docs               = $null
        Package            = $null
        FirstSeenVersion   = $null
        FirstSeenChannel   = $null
        FirstStableVersion = $null
        LastSeenVersion    = $null
        Advertised         = $true
        Deprecated         = $false
        DefaultChanges     = @()
        Extra              = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::Ordinal)
    }
}

function Copy-CatalogEntry {
    param([Parameter(Mandatory)]$Entry)
    $copy = New-CatalogEntry -Id $Entry.Id
    foreach ($name in 'Analyzer', 'DefaultSeverity', 'EnabledByDefault', 'Title', 'Docs', 'Package', 'FirstSeenVersion', 'FirstSeenChannel', 'FirstStableVersion', 'LastSeenVersion', 'Advertised', 'Deprecated') {
        $copy.$name = $Entry.$name
    }
    $copy.DefaultChanges = @($Entry.DefaultChanges | ForEach-Object { [ordered]@{ version = $_['version']; field = $_['field']; from = $_['from']; to = $_['to'] } })
    foreach ($key in $Entry.Extra.Keys) { $copy.Extra[$key] = $Entry.Extra[$key] }
    return $copy
}

function Get-FileChange {
    # created or modified when Bytes differ from the file at Path, else $null.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][byte[]]$Bytes)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return 'created' }
    if ([System.Linq.Enumerable]::SequenceEqual([byte[]][System.IO.File]::ReadAllBytes($Path), $Bytes)) { return $null }
    return 'modified'
}

function Write-FileByte {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][byte[]]$Bytes)
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) { [void][System.IO.Directory]::CreateDirectory($parent) }
    [System.IO.File]::WriteAllBytes($Path, $Bytes)
}

function Get-PackageRank {
    param([string]$PackageId)
    $index = [System.Array]::IndexOf($script:PackageOrder, $PackageId)
    if ($index -lt 0) { return $script:PackageOrder.Count }
    return $index
}

#endregion

#region Catalog

function ConvertFrom-CatalogFileText {
    <#
    .SYNOPSIS
    A catalog text as a Rulebook.Catalog { Schema, Version, Entries (ordinal ordered map id -> entry), Path }.
    .DESCRIPTION
    Entry { Id, Analyzer, DefaultSeverity, EnabledByDefault, Title, Docs, Package, FirstSeenVersion,
    FirstSeenChannel, FirstStableVersion, LastSeenVersion, Advertised (default $true), Deprecated (default $false),
    DefaultChanges, Extra (unknown keys in file order) }. An entry without an id or an id listed twice throws.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [string]$Path = 'catalog/diagnostics.json')
    try {
        $json = ConvertFrom-Json -InputObject $Text -AsHashtable -Depth 20 -ErrorAction Stop
    } catch {
        throw "Invalid JSON in $Path`: $($_.Exception.Message)"
    }
    if ($json -isnot [System.Collections.IDictionary] -or $json['diagnostics'] -isnot [System.Collections.IList]) { throw "$Path has no diagnostics array" }
    $entries = Get-OrdinalMap
    foreach ($item in $json['diagnostics']) {
        if ($item -isnot [System.Collections.IDictionary]) { throw "$Path has an entry that is not an object" }
        $id = [string]$item['id']
        if ([string]::IsNullOrEmpty($id)) { throw "$Path has an entry without an id" }
        if ($entries.Contains($id)) { throw "$Path lists $id twice" }
        $entry = New-CatalogEntry -Id $id
        $entry.Analyzer = ConvertTo-TextOrNull $item['analyzer']
        $entry.DefaultSeverity = ConvertTo-TextOrNull $item['defaultSeverity']
        $entry.EnabledByDefault = if ($item.Contains('enabledByDefault')) { [bool]$item['enabledByDefault'] } else { $true }
        $entry.Title = ConvertTo-TextOrNull $item['title']
        $entry.Docs = ConvertTo-TextOrNull $item['docs']
        $entry.Package = ConvertTo-TextOrNull $item['package']
        $entry.FirstSeenVersion = ConvertTo-TextOrNull $item['firstSeenVersion']
        $entry.FirstSeenChannel = ConvertTo-TextOrNull $item['firstSeenChannel']
        $entry.FirstStableVersion = ConvertTo-TextOrNull $item['firstStableVersion']
        $entry.LastSeenVersion = ConvertTo-TextOrNull $item['lastSeenVersion']
        $entry.Advertised = -not ($item.Contains('advertised') -and $item['advertised'] -eq $false)
        $entry.Deprecated = $item.Contains('deprecated') -and $item['deprecated'] -eq $true
        $entry.DefaultChanges = @(foreach ($change in @($item['defaultChanges'] | Where-Object { $_ -is [System.Collections.IDictionary] })) {
                [ordered]@{ version = ConvertTo-TextOrNull $change['version']; field = ConvertTo-TextOrNull $change['field']; from = $change['from']; to = $change['to'] }
            })
        foreach ($key in $item.Keys) { if ($key -cnotin $script:KnownKeys) { $entry.Extra[$key] = $item[$key] } }
        $entries[$id] = $entry
    }
    return [pscustomobject]@{
        PSTypeName = 'Rulebook.Catalog'
        Schema     = ConvertTo-TextOrNull $json['$schema']
        Version    = $json['version']
        Entries    = $entries
        Path       = $Path
    }
}

function Read-CatalogFile {
    <#
    .SYNOPSIS
    Reads catalog/diagnostics.json into a Rulebook.Catalog (ConvertFrom-CatalogFileText); throws when it is missing.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Path)
    $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "Catalog missing: $Path" }
    $catalog = ConvertFrom-CatalogFileText -Text ([System.IO.File]::ReadAllText($full, $script:Utf8NoBom)) -Path $Path
    $catalog.Path = $full
    return $catalog
}

function ConvertTo-CatalogJson {
    <#
    .SYNOPSIS
    The text of catalog/diagnostics.json: $schema, version 1 and one entry per line in the given order.
    .DESCRIPTION
    Keys in the order id, analyzer, defaultSeverity, enabledByDefault, title, docs (the seed keys, title and docs only
    when not empty), then the scan keys when set: package, firstSeenVersion, firstSeenChannel, firstStableVersion,
    lastSeenVersion, advertised (only false), deprecated (only true), defaultChanges (only when not empty, inline),
    then the unknown keys of Extra. A seed entry of Rulebook.Template (six properties) is written byte for byte as
    before. LF line ends and one trailing LF.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Entries, [AllowNull()][AllowEmptyString()][string]$Schema)
    if ([string]::IsNullOrEmpty($Schema)) { $Schema = Get-RulebookSchemaUrl -Name $script:CatalogSchemaName }
    $items = foreach ($entry in $Entries) {
        $item = '{ "id": ' + (ConvertTo-JsonString $entry.Id)
        $analyzer = Get-EntryValue $entry 'Analyzer'
        if ($null -ne $analyzer) { $item += ', "analyzer": ' + (ConvertTo-JsonString $analyzer) }
        $item += ', "defaultSeverity": ' + (ConvertTo-JsonString (Get-EntryValue $entry 'DefaultSeverity'))
        $item += ', "enabledByDefault": ' + $(if (Get-EntryValue $entry 'EnabledByDefault') { 'true' } else { 'false' })
        foreach ($pair in @(@('title', 'Title'), @('docs', 'Docs'), @('package', 'Package'), @('firstSeenVersion', 'FirstSeenVersion'), @('firstSeenChannel', 'FirstSeenChannel'), @('firstStableVersion', 'FirstStableVersion'), @('lastSeenVersion', 'LastSeenVersion'))) {
            $value = Get-EntryValue $entry $pair[1]
            if (-not [string]::IsNullOrEmpty($value)) { $item += ', "' + $pair[0] + '": ' + (ConvertTo-JsonString $value) }
        }
        if ((Get-EntryValue $entry 'Advertised') -eq $false) { $item += ', "advertised": false' }
        if ((Get-EntryValue $entry 'Deprecated') -eq $true) { $item += ', "deprecated": true' }
        $changes = @(Get-EntryValue $entry 'DefaultChanges' | Where-Object { $null -ne $_ })
        if ($changes.Count -gt 0) {
            $elements = foreach ($change in $changes) {
                '{ "version": ' + (ConvertTo-JsonValue $change['version']) + ', "field": ' + (ConvertTo-JsonValue $change['field']) + ', "from": ' + (ConvertTo-JsonValue $change['from']) + ', "to": ' + (ConvertTo-JsonValue $change['to']) + ' }'
            }
            $item += ', "defaultChanges": [ ' + ($elements -join ', ') + ' ]'
        }
        $extra = Get-EntryValue $entry 'Extra'
        if ($extra -is [System.Collections.IDictionary]) {
            foreach ($key in $extra.Keys) { $item += ', ' + (ConvertTo-JsonString ([string]$key)) + ': ' + (ConvertTo-JsonValue $extra[$key]) }
        }
        $item + ' }'
    }
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('{')
    $lines.Add('  "$schema": ' + (ConvertTo-JsonString $Schema) + ',')
    $lines.Add('  "version": 1,')
    $items = @($items)
    if ($items.Count -eq 0) {
        $lines.Add('  "diagnostics": []')
    } else {
        $lines.Add('  "diagnostics": [')
        for ($i = 0; $i -lt $items.Count; $i++) { $lines.Add('    ' + $items[$i] + $(if ($i -lt $items.Count - 1) { ',' } else { '' })) }
        $lines.Add('  ]')
    }
    $lines.Add('}')
    return ($lines -join "`n") + "`n"
}

function Get-SortedCatalogEntry {
    <#
    .SYNOPSIS
    The entries of a catalog sorted by Get-DiagnosticSortKey and then the id, ordinal (the order of the seed).
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)]$Catalog)
    # A Comparison sort: [System.Array]::Sort(keys, items, comparer) called from PowerShell leaves the items array
    # in its order.
    $keyed = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in $Catalog.Entries.Values) { $keyed.Add([pscustomobject]@{ Key = (Get-DiagnosticSortKey -Id $entry.Id) + '|' + $entry.Id; Entry = $entry }) }
    $keyed.Sort([System.Comparison[object]] { param($left, $right) [string]::CompareOrdinal($left.Key, $right.Key) })
    return , [object[]]@($keyed | ForEach-Object Entry)
}

function Write-CatalogFile {
    <#
    .SYNOPSIS
    Writes -Catalog to -Path sorted (Get-SortedCatalogEntry) when the bytes differ: { File, Change } or nothing.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Catalog, [string]$File = 'catalog/diagnostics.json')
    $Path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $bytes = $script:Utf8NoBom.GetBytes((ConvertTo-CatalogJson -Entries (Get-SortedCatalogEntry -Catalog $Catalog) -Schema $Catalog.Schema))
    $change = Get-FileChange -Path $Path -Bytes $bytes
    if ($null -eq $change) { return }
    if ($PSCmdlet.ShouldProcess($File, "Write ($change)")) { Write-FileByte -Path $Path -Bytes $bytes }
    return [pscustomobject]@{ PSTypeName = 'Rulebook.FileChange'; File = $File; Change = $change }
}

function Get-CatalogDocsUrl {
    <#
    .SYNOPSIS
    The docs URL the catalog records for an id, $null when there is none.
    .DESCRIPTION
    Compiler ids (AL<n>, or -Analyzer Compiler) get the Learn page diagnostic-al<n> (no leading zeros). Otherwise
    -HelpLinkUri without its query string (the Microsoft links carry ?wt.mc_id=...), with the path lowercased for
    alcops.dev (the TestAutomationCop links of the package say testautomationCop, which is a 404).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Id, [AllowNull()][AllowEmptyString()][string]$HelpLinkUri, [AllowNull()][AllowEmptyString()][string]$Analyzer)
    if ($Id -cmatch '^AL0*([0-9]+)$') { return $script:AlDocsUrl -f $Matches[1] }
    if ($Analyzer -ceq 'Compiler' -and $Id -cmatch '^[A-Z]+0*([0-9]+)$') { return $script:AlDocsUrl -f $Matches[1] }
    if ([string]::IsNullOrWhiteSpace($HelpLinkUri)) { return $null }
    $link = $HelpLinkUri.Trim()
    $query = $link.IndexOf([char]'?')
    if ($query -ge 0) { $link = $link.Substring(0, $query) }
    if ($link -match '^(https?://(www\.)?alcops\.dev)(/.*)?$') { $link = $Matches[1] + $(if ($Matches[3]) { $Matches[3].ToLowerInvariant() } else { '' }) }
    if ($link -eq '') { return $null }
    return $link
}

function Update-CatalogFromScan {
    <#
    .SYNOPSIS
    Applies the records of one scanned package version to a catalog: a Rulebook.CatalogDiff with the new catalog.
    .DESCRIPTION
    Pure: -Catalog is not changed. Rules (docs/reference/scan-mechanics.md section 3):
    - A new id gets a full entry (analyzer, defaults, title, docs, package, firstSeenVersion and firstSeenChannel of
      this version, firstStableVersion when stable, advertised false when no analyzer returns it): NewIds.
    - A catalog id without package (a seeded id) gets the package fields: Recorded, never NewIds.
    - Stable: firstStableVersion is set once; Promoted when the id was first seen in a prerelease and -QuarantinedIds
      lists it (quarantined by an earlier scan). An existing entry with advertised false that an analyzer returns now:
      NewlyAdvertised. Defaults that differ are overwritten and one defaultChanges element
      per field and version is appended: ChangedDefaults. Title and docs are refreshed: Refreshed. advertised and
      deprecated follow the descriptor. Catalog ids of this package that the version does not carry: Vanished (kept).
    - Prerelease: differing defaults are listed in PrereleaseDefaultChanges only; text is never changed.
    - lastSeenVersion is the highest version carrying the id (any channel) and only moves forward.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Pure: returns a new catalog, writes nothing')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]$Catalog,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Records,
        [Parameter(Mandatory)][string]$PackageId,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][ValidateSet('stable', 'prerelease')][string]$Channel,
        [AllowNull()][AllowEmptyCollection()][string[]]$QuarantinedIds
    )
    $stable = $Channel -eq 'stable'
    $quarantined = [System.Collections.Generic.HashSet[string]]::new([string[]]@($QuarantinedIds | Where-Object { $_ }), [System.StringComparer]::Ordinal)
    $entries = Get-OrdinalMap
    foreach ($key in $Catalog.Entries.Keys) { $entries[$key] = Copy-CatalogEntry -Entry $Catalog.Entries[$key] }
    $lists = @{}
    foreach ($name in 'NewIds', 'NewlyAdvertised', 'Promoted', 'ChangedDefaults', 'PrereleaseDefaultChanges', 'Refreshed', 'Vanished', 'Unadvertised', 'Deprecated', 'Recorded') { $lists[$name] = [System.Collections.Generic.List[object]]::new() }

    foreach ($id in $Records.Keys) {
        $record = $Records[$id]
        if (-not $record.Advertised) { $lists.Unadvertised.Add($id) }
        if ($record.Deprecated) { $lists.Deprecated.Add($id) }
        if (-not $entries.Contains($id)) {
            $entry = New-CatalogEntry -Id $id
            $entry.Analyzer = $record.Analyzer
            $entry.DefaultSeverity = $record.DefaultSeverity
            $entry.EnabledByDefault = $record.EnabledByDefault
            $entry.Title = $record.Title
            $entry.Docs = $record.Docs
            $entry.Package = $PackageId
            $entry.FirstSeenVersion = $Version
            $entry.FirstSeenChannel = $Channel
            $entry.FirstStableVersion = if ($stable) { $Version } else { $null }
            $entry.LastSeenVersion = $Version
            $entry.Advertised = [bool]$record.Advertised
            $entry.Deprecated = [bool]$record.Deprecated
            $entries[$id] = $entry
            $lists.NewIds.Add($id)
            continue
        }
        $entry = $entries[$id]
        if ([string]::IsNullOrEmpty($entry.Package)) {
            $entry.Package = $PackageId
            $entry.FirstSeenVersion = $Version
            $entry.FirstSeenChannel = $Channel
            $lists.Recorded.Add($id)
        }
        if ([string]::IsNullOrEmpty($entry.LastSeenVersion) -or (Compare-NuGetVersion -Reference $Version -Difference $entry.LastSeenVersion) -gt 0) { $entry.LastSeenVersion = $Version }
        # The first stable version of an id first seen in a prerelease: its defaults are what the id ships with, not a
        # change of a released default, so they are taken over without a defaultChanges element.
        $firstStable = $stable -and [string]::IsNullOrEmpty($entry.FirstStableVersion) -and $entry.FirstSeenChannel -ceq 'prerelease'
        $fields = @(
            @{ Field = 'defaultSeverity'; Property = 'DefaultSeverity'; Value = $record.DefaultSeverity }
            @{ Field = 'enabledByDefault'; Property = 'EnabledByDefault'; Value = [bool]$record.EnabledByDefault }
        )
        foreach ($field in $fields) {
            $current = $entry.($field.Property)
            if ($null -eq $field.Value -or ($null -ne $current -and $current -ceq $field.Value) -or ($current -is [bool] -and $current -eq $field.Value)) { continue }
            if ($firstStable) {
                $entry.($field.Property) = $field.Value
                continue
            }
            $change = [pscustomobject]@{ Id = $id; Field = $field.Field; From = $current; To = $field.Value; Version = $Version }
            if (-not $stable) {
                $lists.PrereleaseDefaultChanges.Add($change)
                continue
            }
            $entry.($field.Property) = $field.Value
            $known = @($entry.DefaultChanges | Where-Object { $_['version'] -ceq $Version -and $_['field'] -ceq $field.Field })
            if ($known.Count -eq 0) { $entry.DefaultChanges = @($entry.DefaultChanges) + @([ordered]@{ version = $Version; field = $field.Field; from = $current; to = $field.Value }) }
            $lists.ChangedDefaults.Add($change)
        }
        if (-not $stable) { continue }
        if ([string]::IsNullOrEmpty($entry.FirstStableVersion)) {
            $entry.FirstStableVersion = $Version
            if ($entry.FirstSeenChannel -ceq 'prerelease' -and $quarantined.Contains($id)) { $lists.Promoted.Add($id) }
        }
        foreach ($text in @(@{ Field = 'title'; Property = 'Title'; Value = $record.Title }, @{ Field = 'docs'; Property = 'Docs'; Value = $record.Docs })) {
            if ([string]::IsNullOrEmpty($text.Value) -or $entry.($text.Property) -ceq $text.Value) { continue }
            $lists.Refreshed.Add([pscustomobject]@{ Id = $id; Field = $text.Field; From = $entry.($text.Property); To = $text.Value })
            $entry.($text.Property) = $text.Value
        }
        # An id that was only a field and is returned by an analyzer now goes live at its default: NewlyAdvertised, which
        # the quarantine treats like a promoted id (seed or not; D46 covers the first scan).
        if ($entry.Advertised -eq $false -and [bool]$record.Advertised) { $lists.NewlyAdvertised.Add($id) }
        $entry.Advertised = [bool]$record.Advertised
        $entry.Deprecated = [bool]$record.Deprecated
    }
    if ($stable) {
        foreach ($entry in $entries.Values) {
            # An id only a prerelease carried has not vanished from a stable version.
            if ($entry.Package -ceq $PackageId -and -not [string]::IsNullOrEmpty($entry.FirstStableVersion) -and -not $Records.Contains($entry.Id)) { $lists.Vanished.Add($entry.Id) }
        }
    }
    $after = [pscustomobject]@{ PSTypeName = 'Rulebook.Catalog'; Schema = $Catalog.Schema; Version = $Catalog.Version; Entries = $entries; Path = $Catalog.Path }
    return [pscustomobject]@{
        PSTypeName               = 'Rulebook.CatalogDiff'
        PackageId                = $PackageId
        Version                  = $Version
        Channel                  = $Channel
        NewIds                   = [string[]]@($lists.NewIds)
        NewlyAdvertised          = [string[]]@($lists.NewlyAdvertised)
        Promoted                 = [string[]]@($lists.Promoted)
        ChangedDefaults          = $lists.ChangedDefaults.ToArray()
        PrereleaseDefaultChanges = $lists.PrereleaseDefaultChanges.ToArray()
        Refreshed                = $lists.Refreshed.ToArray()
        Vanished                 = [string[]]@($lists.Vanished)
        Unadvertised             = [string[]]@($lists.Unadvertised)
        Deprecated               = [string[]]@($lists.Deprecated)
        Recorded                 = [string[]]@($lists.Recorded)
        Conflicts                = @()
        Catalog                  = $after
    }
}

#endregion

#region Scan state

function ConvertFrom-ScanStateText {
    <#
    .SYNOPSIS
    A scan-state text as a Rulebook.ScanState { Schema, Version, Packages (id -> { Stable, Prerelease }, each $null or
    { Version, ScannedAt }) }.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [string]$Path = 'catalog/scan-state.json')
    try {
        $json = ConvertFrom-Json -InputObject $Text -AsHashtable -Depth 10 -ErrorAction Stop
    } catch {
        throw "Invalid JSON in $Path`: $($_.Exception.Message)"
    }
    if ($json -isnot [System.Collections.IDictionary]) { throw "$Path is not a JSON object" }
    $packages = Get-OrdinalMap
    if ($json['packages'] -is [System.Collections.IDictionary]) {
        foreach ($id in $json['packages'].Keys) {
            $item = $json['packages'][$id]
            $channels = [ordered]@{ Stable = $null; Prerelease = $null }
            foreach ($channel in 'stable', 'prerelease') {
                $value = if ($item -is [System.Collections.IDictionary]) { $item[$channel] } else { $null }
                if ($value -is [System.Collections.IDictionary] -and $value['version']) {
                    $channels[$(if ($channel -eq 'stable') { 'Stable' } else { 'Prerelease' })] = [pscustomobject]@{ Version = ConvertTo-TextOrNull $value['version']; ScannedAt = ConvertTo-TextOrNull $value['scannedAt'] }
                }
            }
            $packages[[string]$id] = [pscustomobject]$channels
        }
    }
    return [pscustomobject]@{ PSTypeName = 'Rulebook.ScanState'; Schema = ConvertTo-TextOrNull $json['$schema']; Version = $(if ($json.Contains('version')) { $json['version'] } else { 1 }); Packages = $packages }
}

function Read-ScanState {
    <#
    .SYNOPSIS
    Reads catalog/scan-state.json; a missing file is an empty state (nothing scanned yet).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Path)
    $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        return [pscustomobject]@{ PSTypeName = 'Rulebook.ScanState'; Schema = (Get-RulebookSchemaUrl -Name $script:ScanStateSchemaName); Version = 1; Packages = (Get-OrdinalMap) }
    }
    return ConvertFrom-ScanStateText -Text ([System.IO.File]::ReadAllText($full, $script:Utf8NoBom)) -Path $Path
}

function ConvertTo-ScanStateJson {
    <#
    .SYNOPSIS
    The text of catalog/scan-state.json: the tools package first, then alcops.analyzers, then any other id ordinal.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$State)
    $schema = if ([string]::IsNullOrEmpty($State.Schema)) { Get-RulebookSchemaUrl -Name $script:ScanStateSchemaName } else { $State.Schema }
    $ordered = [System.Collections.Generic.List[object]]::new()
    foreach ($id in $State.Packages.Keys) { $ordered.Add([pscustomobject]@{ Key = ('{0:00}|{1}' -f (Get-PackageRank $id), $id); Id = [string]$id }) }
    $ordered.Sort([System.Comparison[object]] { param($left, $right) [string]::CompareOrdinal($left.Key, $right.Key) })
    [string[]]$ids = @($ordered | ForEach-Object Id)
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('{')
    $lines.Add('  "$schema": ' + (ConvertTo-JsonString $schema) + ',')
    $lines.Add('  "version": 1,')
    if ($ids.Count -eq 0) {
        $lines.Add('  "packages": {}')
    } else {
        $lines.Add('  "packages": {')
        for ($i = 0; $i -lt $ids.Count; $i++) {
            $package = $State.Packages[$ids[$i]]
            $lines.Add('    ' + (ConvertTo-JsonString $ids[$i]) + ': {')
            $channel = { param($Value) if ($null -eq $Value) { 'null' } else { '{ "version": ' + (ConvertTo-JsonString $Value.Version) + ', "scannedAt": ' + (ConvertTo-JsonString $Value.ScannedAt) + ' }' } }
            $lines.Add('      "stable": ' + (& $channel $package.Stable) + ',')
            $lines.Add('      "prerelease": ' + (& $channel $package.Prerelease))
            $lines.Add('    }' + $(if ($i -lt $ids.Count - 1) { ',' } else { '' }))
        }
        $lines.Add('  }')
    }
    $lines.Add('}')
    return ($lines -join "`n") + "`n"
}

function Write-ScanState {
    <#
    .SYNOPSIS
    Writes the scan state when the bytes differ: { File, Change } or nothing.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$State, [string]$File = 'catalog/scan-state.json')
    $Path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $bytes = $script:Utf8NoBom.GetBytes((ConvertTo-ScanStateJson -State $State))
    $change = Get-FileChange -Path $Path -Bytes $bytes
    if ($null -eq $change) { return }
    if ($PSCmdlet.ShouldProcess($File, "Write ($change)")) { Write-FileByte -Path $Path -Bytes $bytes }
    return [pscustomobject]@{ PSTypeName = 'Rulebook.FileChange'; File = $File; Change = $change }
}

function Get-NewPackageVersion {
    <#
    .SYNOPSIS
    The package versions the scan has not recorded yet: { PackageId, Channel, Version }[].
    .DESCRIPTION
    -Channels holds { PackageId, Stable, Prerelease } (Select-NuGetChannelVersion per package). A channel whose
    version sorts after the recorded one (Compare-NuGetVersion) is new; an equal or older version (an index behind the
    state) is skipped and, with -Skipped, added there as '<package> <channel> <version> (recorded <version>)'; a
    $null version (no prerelease, or prerelease not included) is skipped. A recorded version that does not parse counts
    as older. Ordered tools before alcops.analyzers, stable before prerelease.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Channels, [AllowNull()][System.Collections.Generic.List[string]]$Skipped)
    $sorted = @($Channels | Sort-Object { Get-PackageRank $_.PackageId }, { $_.PackageId })
    $result = foreach ($item in $sorted) {
        $recorded = if ($State.Packages.Contains($item.PackageId)) { $State.Packages[$item.PackageId] } else { $null }
        foreach ($channel in 'stable', 'prerelease') {
            $version = if ($channel -eq 'stable') { $item.Stable } else { $item.Prerelease }
            if ([string]::IsNullOrEmpty($version)) { continue }
            $last = if ($null -eq $recorded) { $null } elseif ($channel -eq 'stable') { $recorded.Stable } else { $recorded.Prerelease }
            if ($null -ne $last -and -not [string]::IsNullOrEmpty($last.Version)) {
                $newer = try { (Compare-NuGetVersion -Reference $version -Difference $last.Version) -gt 0 } catch { $true }
                if (-not $newer) {
                    if ($null -ne $Skipped -and $last.Version -cne $version) { $Skipped.Add("$($item.PackageId) $channel $version (recorded $($last.Version))") }
                    continue
                }
            }
            [pscustomobject]@{ PackageId = $item.PackageId; Channel = $channel; Version = $version }
        }
    }
    # Unrolled on purpose: callers collect it with @().
    return @($result)
}

#endregion

Export-ModuleMember -Function @(
    'ConvertFrom-CatalogFileText'
    'ConvertFrom-ScanStateText'
    'ConvertTo-CatalogJson'
    'ConvertTo-ScanStateJson'
    'Get-CatalogDocsUrl'
    'Get-NewPackageVersion'
    'Get-SortedCatalogEntry'
    'Read-CatalogFile'
    'Read-ScanState'
    'Update-CatalogFromScan'
    'Write-CatalogFile'
    'Write-ScanState'
)
