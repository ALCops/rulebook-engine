@{
    RootModule           = 'Rulebook.Catalog.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = 'bff9c35b-cf48-4385-b0ae-da5704a72ea1'
    Author               = 'ALCops'
    CompanyName          = 'ALCops'
    Copyright            = '(c) ALCops. MIT License.'
    Description          = 'Rulebook catalog and scan state: catalog/diagnostics.json with every scan field, the docs URL rule, one scanned package version applied to the catalog, and catalog/scan-state.json. See docs/reference/scan-mechanics.md.'
    PowerShellVersion    = '7.4'
    CompatiblePSEditions = @('Core')
    FunctionsToExport    = @(
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
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags       = @('ALCops', 'Rulebook', 'AL', 'BusinessCentral', 'ruleset')
            LicenseUri = 'https://github.com/ALCops/rulebook-engine/blob/main/LICENSE'
            ProjectUri = 'https://github.com/ALCops/rulebook-engine'
        }
    }
}
