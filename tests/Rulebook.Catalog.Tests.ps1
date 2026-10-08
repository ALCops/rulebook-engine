# Catalog suite for WP08 (#10): modules/Rulebook.Catalog. The seed catalog of template/ round trips byte for byte, the
# scan rules of Update-CatalogFromScan run on hand-built records (docs/reference/scan-mechanics.md section 3), and the
# scan state round trips with the schema fixtures.

BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $PSScriptRoot 'Helpers' 'RepoFixture.ps1')
    Import-Module (Join-Path $repoRoot 'modules' 'Rulebook.Catalog.psd1') -Force
    $script:seedPath = Join-Path $repoRoot 'template' 'catalog' 'diagnostics.json'
    $script:utf8 = [System.Text.UTF8Encoding]::new($false)
    $script:alcops = 'alcops.analyzers'

    function New-Record {

        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helper; builds an object or writes only to TestDrive')]
        param([string]$Id, [string]$Severity = 'Warning', [bool]$Enabled = $true, [string]$Title = 'A rule', [string]$Docs, [bool]$Advertised = $true, [bool]$Deprecated = $false, [string]$Analyzer = 'LinterCop')
        return [pscustomobject]@{ Id = $Id; Analyzer = $Analyzer; DefaultSeverity = $Severity; EnabledByDefault = $Enabled; Title = $Title; Docs = $(if ($Docs) { $Docs } else { $null }); Advertised = $Advertised; Deprecated = $Deprecated }
    }

    function New-Records {

        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helper; builds an object or writes only to TestDrive')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Test helper; builds a map of records')]
        param([object[]]$Items)
        $map = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::Ordinal)
        foreach ($item in $Items) { $map[$item.Id] = $item }
        return , $map
    }

    function New-TestCatalog {

        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helper; builds an object or writes only to TestDrive')]
        param([string]$Text)
        return ConvertFrom-CatalogFileText -Text $Text -Path 'catalog/diagnostics.json'
    }

    $script:smallCatalog = @'
{
  "version": 1,
  "diagnostics": [
    { "id": "LC0015", "analyzer": "LinterCop", "defaultSeverity": "Info", "enabledByDefault": true, "title": "Old title", "docs": "https://alcops.dev/docs/analyzers/lintercop/lc0015/" },
    { "id": "LC0001", "analyzer": "LinterCop", "defaultSeverity": "Warning", "enabledByDefault": true, "package": "alcops.analyzers", "firstSeenVersion": "1.3.1", "firstSeenChannel": "stable", "firstStableVersion": "1.3.1", "lastSeenVersion": "1.3.1" },
    { "id": "LC0099", "analyzer": "LinterCop", "defaultSeverity": "Warning", "enabledByDefault": true, "package": "alcops.analyzers", "firstSeenVersion": "1.4.0-beta.1", "firstSeenChannel": "prerelease", "lastSeenVersion": "1.4.0-beta.1" }
  ]
}
'@
}

AfterAll {
    Remove-Module Rulebook.Catalog, Rulebook.NuGet -ErrorAction SilentlyContinue
}

Describe 'Catalog file' {
    It 'round trips the seed catalog of template/ byte for byte' {
        $catalog = Read-CatalogFile -Path $seedPath
        $catalog.Entries.Count | Should-Be 628
        $text = ConvertTo-CatalogJson -Entries (Get-SortedCatalogEntry -Catalog $catalog) -Schema $catalog.Schema
        $text | Should-Be ([System.IO.File]::ReadAllText($seedPath, $utf8))
    }

    It 'writes a shuffled copy back in the order of the seed' {
        $catalog = Read-CatalogFile -Path $seedPath
        $keys = @($catalog.Entries.Keys)
        $shuffled = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::Ordinal)
        foreach ($key in ($keys | Sort-Object { [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($_))[0] }, { $_ })) { $shuffled[$key] = $catalog.Entries[$key] }
        $catalog.Entries = $shuffled
        $path = Join-Path $TestDrive 'shuffled' 'diagnostics.json'
        $change = Write-CatalogFile -Path $path -Catalog $catalog
        $change.Change | Should-Be 'created'
        [System.Linq.Enumerable]::SequenceEqual([byte[]][System.IO.File]::ReadAllBytes($path), [byte[]][System.IO.File]::ReadAllBytes($seedPath)) | Should-BeTrue
        Write-CatalogFile -Path $path -Catalog $catalog | Should-BeNull
    }

    It 'keeps unknown keys and writes every scan field in its place' {
        $text = @'
{
  "version": 1,
  "diagnostics": [
    { "id": "LC0099", "analyzer": "LinterCop", "defaultSeverity": "Warning", "enabledByDefault": true, "note": { "by": "org" }, "deprecated": true, "package": "alcops.analyzers", "defaultChanges": [ { "version": "1.5.0", "field": "enabledByDefault", "from": false, "to": true } ], "advertised": false, "lastSeenVersion": "1.5.0" }
  ]
}
'@
        $catalog = New-TestCatalog $text
        $line = (ConvertTo-CatalogJson -Entries @($catalog.Entries.Values)).Split("`n")[4]
        $line | Should-Be '    { "id": "LC0099", "analyzer": "LinterCop", "defaultSeverity": "Warning", "enabledByDefault": true, "package": "alcops.analyzers", "lastSeenVersion": "1.5.0", "advertised": false, "deprecated": true, "defaultChanges": [ { "version": "1.5.0", "field": "enabledByDefault", "from": false, "to": true } ], "note": {"by":"org"} }'
    }

    It 'throws on an id listed twice' {
        { New-TestCatalog '{ "version": 1, "diagnostics": [ { "id": "LC0001", "defaultSeverity": "Info", "enabledByDefault": true }, { "id": "LC0001", "defaultSeverity": "Info", "enabledByDefault": true } ] }' } |
            Should-Throw -ExceptionMessage 'catalog/diagnostics.json lists LC0001 twice'
    }

    It 'throws on an entry without an id' {
        { New-TestCatalog '{ "version": 1, "diagnostics": [ { "defaultSeverity": "Info", "enabledByDefault": true } ] }' } | Should-Throw -ExceptionMessage '*entry without an id'
    }
}

Describe 'Get-CatalogDocsUrl' {
    It '<Id> gives <Expected>' -ForEach @(
        @{ Id = 'AL0200'; Link = $null; Expected = 'https://learn.microsoft.com/dynamics365/business-central/dev-itpro/developer/diagnostics/diagnostic-al200' }
        @{ Id = 'AL1003'; Link = $null; Expected = 'https://learn.microsoft.com/dynamics365/business-central/dev-itpro/developer/diagnostics/diagnostic-al1003' }
        @{ Id = 'AA0137'; Link = 'https://learn.microsoft.com/dynamics365/business-central/dev-itpro/developer/analyzers/codecop-aa0137?wt.mc_id=d365bc_inproduct_alextension'; Expected = 'https://learn.microsoft.com/dynamics365/business-central/dev-itpro/developer/analyzers/codecop-aa0137' }
        @{ Id = 'TA0001'; Link = 'https://alcops.dev/docs/analyzers/testautomationCop/ta0001/'; Expected = 'https://alcops.dev/docs/analyzers/testautomationcop/ta0001/' }
        @{ Id = 'LC0089i'; Link = 'https://alcops.dev/docs/analyzers/lintercop/lc0089/'; Expected = 'https://alcops.dev/docs/analyzers/lintercop/lc0089/' }
        @{ Id = 'ZZ0001'; Link = ''; Expected = $null }
    ) {
        Get-CatalogDocsUrl -Id $Id -HelpLinkUri $Link | Should-Be $Expected
    }
}

Describe 'Update-CatalogFromScan' {
    BeforeEach {
        $script:catalog = New-TestCatalog $smallCatalog
    }

    It 'adds a new stable id with every field and leaves the input alone' {
        $records = New-Records @((New-Record -Id 'LC0100' -Severity 'Info' -Title 'New' -Docs 'https://alcops.dev/docs/analyzers/lintercop/lc0100/'))
        $diff = Update-CatalogFromScan -Catalog $catalog -Records $records -PackageId $alcops -Version '1.4.0' -Channel stable
        $diff.NewIds | Should-BeCollection @('LC0100')
        $entry = $diff.Catalog.Entries['LC0100']
        '{0} {1} {2} {3} {4} {5} {6}' -f $entry.Analyzer, $entry.DefaultSeverity, $entry.Package, $entry.FirstSeenVersion, $entry.FirstSeenChannel, $entry.FirstStableVersion, $entry.LastSeenVersion |
            Should-Be 'LinterCop Info alcops.analyzers 1.4.0 stable 1.4.0 1.4.0'
        $catalog.Entries.Contains('LC0100') | Should-BeFalse
    }

    It 'adds a new prerelease id without a stable version' {
        $diff = Update-CatalogFromScan -Catalog $catalog -Records (New-Records @((New-Record -Id 'LC0101'))) -PackageId $alcops -Version '1.4.0-beta.1' -Channel prerelease
        $diff.NewIds | Should-BeCollection @('LC0101')
        $diff.Catalog.Entries['LC0101'].FirstSeenChannel | Should-Be 'prerelease'
        $diff.Catalog.Entries['LC0101'].FirstStableVersion | Should-BeNull
    }

    It 'promotes a quarantined prerelease id once' {
        $records = New-Records @((New-Record -Id 'LC0099'))
        $diff = Update-CatalogFromScan -Catalog $catalog -Records $records -PackageId $alcops -Version '1.4.0' -Channel stable -QuarantinedIds @('LC0099')
        $diff.Promoted | Should-BeCollection @('LC0099')
        $diff.Catalog.Entries['LC0099'].FirstStableVersion | Should-Be '1.4.0'
        $again = Update-CatalogFromScan -Catalog $diff.Catalog -Records $records -PackageId $alcops -Version '1.4.1' -Channel stable -QuarantinedIds @('LC0099')
        $again.Promoted | Should-BeCollection @()
        $again.Catalog.Entries['LC0099'].FirstStableVersion | Should-Be '1.4.0'
    }

    It 'does not promote an id that is no longer quarantined' {
        $diff = Update-CatalogFromScan -Catalog $catalog -Records (New-Records @((New-Record -Id 'LC0099'))) -PackageId $alcops -Version '1.4.0' -Channel stable
        $diff.Promoted | Should-BeCollection @()
    }

    It 'records a seeded id without making it new' {
        $diff = Update-CatalogFromScan -Catalog $catalog -Records (New-Records @((New-Record -Id 'LC0015' -Severity 'Info' -Title 'Old title' -Docs 'https://alcops.dev/docs/analyzers/lintercop/lc0015/'))) -PackageId $alcops -Version '1.3.1' -Channel stable
        $diff.NewIds | Should-BeCollection @()
        $diff.Recorded | Should-BeCollection @('LC0015')
        $entry = $diff.Catalog.Entries['LC0015']
        '{0} {1} {2} {3}' -f $entry.Package, $entry.FirstSeenVersion, $entry.FirstSeenChannel, $entry.LastSeenVersion | Should-Be 'alcops.analyzers 1.3.1 stable 1.3.1'
        $diff.Refreshed | Should-BeCollection @()
    }

    It 'applies a stable default change once (AC8: LC0015 Info to Warning)' {
        $records = New-Records @((New-Record -Id 'LC0015' -Severity 'Warning' -Title 'Old title' -Docs 'https://alcops.dev/docs/analyzers/lintercop/lc0015/'))
        $diff = Update-CatalogFromScan -Catalog $catalog -Records $records -PackageId $alcops -Version '1.4.0' -Channel stable
        $entry = $diff.Catalog.Entries['LC0015']
        $entry.DefaultSeverity | Should-Be 'Warning'
        @($entry.DefaultChanges | ForEach-Object { '{0} {1} {2} {3}' -f $_['version'], $_['field'], $_['from'], $_['to'] }) | Should-BeCollection @('1.4.0 defaultSeverity Info Warning')
        @($diff.ChangedDefaults | ForEach-Object { "$($_.Id) $($_.Field) $($_.From) $($_.To) $($_.Version)" }) | Should-BeCollection @('LC0015 defaultSeverity Info Warning 1.4.0')
        $again = Update-CatalogFromScan -Catalog $diff.Catalog -Records $records -PackageId $alcops -Version '1.4.0' -Channel stable
        $again.ChangedDefaults | Should-BeCollection @()
        @($again.Catalog.Entries['LC0015'].DefaultChanges).Count | Should-Be 1
        (ConvertTo-CatalogJson -Entries @($again.Catalog.Entries['LC0015'])).Split("`n")[4] | Should-MatchString '"defaultChanges": \[ \{ "version": "1\.4\.0", "field": "defaultSeverity", "from": "Info", "to": "Warning" \} \]'
    }

    It 'applies an enablement change' {
        $diff = Update-CatalogFromScan -Catalog $catalog -Records (New-Records @((New-Record -Id 'LC0001' -Enabled $false))) -PackageId $alcops -Version '1.4.0' -Channel stable
        $diff.Catalog.Entries['LC0001'].EnabledByDefault | Should-BeFalse
        @($diff.ChangedDefaults | ForEach-Object { "$($_.Field) $($_.From) $($_.To)" }) | Should-BeCollection @('enabledByDefault True False')
    }

    It 'lists a prerelease default change without applying it' {
        $diff = Update-CatalogFromScan -Catalog $catalog -Records (New-Records @((New-Record -Id 'LC0015' -Severity 'Error' -Title 'New text'))) -PackageId $alcops -Version '1.4.0-beta.1' -Channel prerelease
        $diff.Catalog.Entries['LC0015'].DefaultSeverity | Should-Be 'Info'
        @($diff.PrereleaseDefaultChanges | ForEach-Object { "$($_.Id) $($_.From) $($_.To)" }) | Should-BeCollection @('LC0015 Info Error')
        $diff.ChangedDefaults | Should-BeCollection @()
        $diff.Catalog.Entries['LC0015'].Title | Should-Be 'Old title'
        $diff.Refreshed | Should-BeCollection @()
    }

    It 'refreshes title and docs from a stable descriptor' {
        $diff = Update-CatalogFromScan -Catalog $catalog -Records (New-Records @((New-Record -Id 'LC0015' -Severity 'Info' -Title 'New title' -Docs 'https://alcops.dev/docs/analyzers/lintercop/lc0015-new/'))) -PackageId $alcops -Version '1.4.0' -Channel stable
        @($diff.Refreshed | ForEach-Object { "$($_.Field): $($_.From) -> $($_.To)" }) | Should-BeCollection @('title: Old title -> New title', 'docs: https://alcops.dev/docs/analyzers/lintercop/lc0015/ -> https://alcops.dev/docs/analyzers/lintercop/lc0015-new/')
        $diff.Catalog.Entries['LC0015'].Title | Should-Be 'New title'
    }

    It 'sets advertised false and clears it when a later version advertises the id' {
        $hidden = Update-CatalogFromScan -Catalog $catalog -Records (New-Records @((New-Record -Id 'LC0000' -Advertised $false))) -PackageId $alcops -Version '1.3.1' -Channel stable
        $hidden.Unadvertised | Should-BeCollection @('LC0000')
        $hidden.Catalog.Entries['LC0000'].Advertised | Should-BeFalse
        (ConvertTo-CatalogJson -Entries @($hidden.Catalog.Entries['LC0000'])) | Should-MatchString '"advertised": false'
        $shown = Update-CatalogFromScan -Catalog $hidden.Catalog -Records (New-Records @((New-Record -Id 'LC0000'))) -PackageId $alcops -Version '1.4.0' -Channel stable
        $shown.Catalog.Entries['LC0000'].Advertised | Should-BeTrue
        (ConvertTo-CatalogJson -Entries @($shown.Catalog.Entries['LC0000'])) | Should-NotMatchString 'advertised'
    }

    It 'lists an id that only a field defined and an analyzer returns now as newly advertised (stable only)' {
        $v1 = Update-CatalogFromScan -Catalog $catalog -Records (New-Records @((New-Record -Id 'LC0000' -Advertised $false))) -PackageId $alcops -Version '1.3.1' -Channel stable
        $v1.NewlyAdvertised | Should-BeCollection @()
        $pre = Update-CatalogFromScan -Catalog $v1.Catalog -Records (New-Records @((New-Record -Id 'LC0000'))) -PackageId $alcops -Version '1.4.0-beta.1' -Channel prerelease
        $pre.NewlyAdvertised | Should-BeCollection @()
        $v3 = Update-CatalogFromScan -Catalog $pre.Catalog -Records (New-Records @((New-Record -Id 'LC0000'))) -PackageId $alcops -Version '1.4.0' -Channel stable
        $v3.NewlyAdvertised | Should-BeCollection @('LC0000')
        $v3.NewIds | Should-BeCollection @()
        $v3.Catalog.Entries['LC0000'].Advertised | Should-BeTrue
        (Update-CatalogFromScan -Catalog $v3.Catalog -Records (New-Records @((New-Record -Id 'LC0000'))) -PackageId $alcops -Version '1.4.1' -Channel stable).NewlyAdvertised | Should-BeCollection @()
    }

    It 'sets deprecated from the stable descriptor' {
        $diff = Update-CatalogFromScan -Catalog $catalog -Records (New-Records @((New-Record -Id 'LC0001' -Deprecated $true))) -PackageId $alcops -Version '1.4.0' -Channel stable
        $diff.Deprecated | Should-BeCollection @('LC0001')
        $diff.Catalog.Entries['LC0001'].Deprecated | Should-BeTrue
    }

    It 'keeps a vanished id with its old lastSeenVersion' {
        $diff = Update-CatalogFromScan -Catalog $catalog -Records (New-Records @((New-Record -Id 'LC0099'))) -PackageId $alcops -Version '1.5.0' -Channel stable
        $diff.Vanished | Should-BeCollection @('LC0001')
        $diff.Catalog.Entries['LC0001'].LastSeenVersion | Should-Be '1.3.1'
    }

    It 'takes over the defaults of an id first seen in a prerelease silently on its first stable version' {
        $pre = Update-CatalogFromScan -Catalog $catalog -Records (New-Records @((New-Record -Id 'LC0101' -Severity 'Warning'))) -PackageId $alcops -Version '1.4.0-beta.1' -Channel prerelease
        $stable = Update-CatalogFromScan -Catalog $pre.Catalog -Records (New-Records @((New-Record -Id 'LC0101' -Severity 'Info'))) -PackageId $alcops -Version '1.4.0' -Channel stable
        $entry = $stable.Catalog.Entries['LC0101']
        $entry.DefaultSeverity | Should-Be 'Info'
        $entry.FirstStableVersion | Should-Be '1.4.0'
        @($entry.DefaultChanges) | Should-BeCollection @()
        $stable.ChangedDefaults | Should-BeCollection @()
    }

    It 'does not report an id only a prerelease carried as vanished from a stable version' {
        $pre = Update-CatalogFromScan -Catalog $catalog -Records (New-Records @((New-Record -Id 'LC0101'))) -PackageId $alcops -Version '1.4.0-beta.1' -Channel prerelease
        $stable = Update-CatalogFromScan -Catalog $pre.Catalog -Records (New-Records @((New-Record -Id 'LC0001'), (New-Record -Id 'LC0099'))) -PackageId $alcops -Version '1.4.0' -Channel stable
        $stable.Vanished | Should-BeCollection @()
    }

    It 'moves lastSeenVersion forward only' {
        $records = New-Records @((New-Record -Id 'LC0001'))
        $newer = Update-CatalogFromScan -Catalog $catalog -Records $records -PackageId $alcops -Version '1.4.0' -Channel stable
        $newer.Catalog.Entries['LC0001'].LastSeenVersion | Should-Be '1.4.0'
        $older = Update-CatalogFromScan -Catalog $newer.Catalog -Records $records -PackageId $alcops -Version '1.4.0-beta.1' -Channel prerelease
        $older.Catalog.Entries['LC0001'].LastSeenVersion | Should-Be '1.4.0'
    }
}

Describe 'Scan state' {
    BeforeAll {
        $script:validDir = Join-Path $PSScriptRoot 'fixtures' 'schemas' 'valid' 'rulebook-scan-state'
    }

    It 'round trips <Name> byte for byte' -ForEach @(@{ Name = 'one-package.json' }, @{ Name = 'two-packages.json' }) {
        $path = Join-Path $validDir $Name
        ConvertTo-ScanStateJson -State (Read-ScanState -Path $path) | Should-Be ([System.IO.File]::ReadAllText($path, $utf8))
    }

    It 'reads a missing file as an empty state' {
        $state = Read-ScanState -Path (Join-Path $TestDrive 'none' 'scan-state.json')
        $state.Packages.Count | Should-Be 0
        ConvertTo-ScanStateJson -State $state | Should-Be "{`n  `"`$schema`": `"https://raw.githubusercontent.com/ALCops/rulebook-engine/v1/schemas/rulebook-scan-state.schema.json`",`n  `"version`": 1,`n  `"packages`": {}`n}`n"
    }

    It 'writes the tools package first and reports the change' {
        $state = Read-ScanState -Path (Join-Path $validDir 'two-packages.json')
        $reordered = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::Ordinal)
        foreach ($key in @($state.Packages.Keys | Sort-Object)) { $reordered[$key] = $state.Packages[$key] }
        $state.Packages = $reordered
        $path = Join-Path $TestDrive 'state' 'scan-state.json'
        (Write-ScanState -Path $path -State $state).Change | Should-Be 'created'
        [System.IO.File]::ReadAllText($path, $utf8) | Should-Be ([System.IO.File]::ReadAllText((Join-Path $validDir 'two-packages.json'), $utf8))
        Write-ScanState -Path $path -State $state | Should-BeNull
    }

    It 'orders the new versions tools first, stable before prerelease, and skips recorded ones' {
        $state = Read-ScanState -Path (Join-Path $validDir 'one-package.json')
        $channels = @(
            [pscustomobject]@{ PackageId = 'alcops.analyzers'; Stable = '1.3.1'; Prerelease = '1.4.0-beta.1' }
            [pscustomobject]@{ PackageId = 'microsoft.dynamics.businesscentral.development.tools'; Stable = '18.0.43.1464'; Prerelease = '30.0.42.60748-beta' }
        )
        @(Get-NewPackageVersion -State $state -Channels $channels | ForEach-Object { "$($_.PackageId) $($_.Channel) $($_.Version)" }) | Should-BeCollection @(
            'microsoft.dynamics.businesscentral.development.tools stable 18.0.43.1464'
            'microsoft.dynamics.businesscentral.development.tools prerelease 30.0.42.60748-beta'
            'alcops.analyzers prerelease 1.4.0-beta.1'
        )
    }

    It 'skips a version that is not newer than the recorded one and lists it' {
        $state = Read-ScanState -Path (Join-Path $validDir 'two-packages.json')
        $channels = @(
            [pscustomobject]@{ PackageId = 'microsoft.dynamics.businesscentral.development.tools'; Stable = '18.0.41.1'; Prerelease = '30.0.42.60748-beta' }
            [pscustomobject]@{ PackageId = 'alcops.analyzers'; Stable = '1.3.2'; Prerelease = $null }
        )
        $skipped = [System.Collections.Generic.List[string]]::new()
        @(Get-NewPackageVersion -State $state -Channels $channels -Skipped $skipped | ForEach-Object { "$($_.PackageId) $($_.Channel) $($_.Version)" }) | Should-BeCollection @('alcops.analyzers stable 1.3.2')
        @($skipped) | Should-BeCollection @('microsoft.dynamics.businesscentral.development.tools stable 18.0.41.1 (recorded 18.0.43.1464)')
    }

    It 'skips a channel without a version' {
        $state = Read-ScanState -Path (Join-Path $TestDrive 'none.json')
        @(Get-NewPackageVersion -State $state -Channels @([pscustomobject]@{ PackageId = 'alcops.analyzers'; Stable = '1.3.1'; Prerelease = $null })).Count | Should-Be 1
    }
}
