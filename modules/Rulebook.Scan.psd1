@{
    RootModule           = 'Rulebook.Scan.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = 'e944586a-7299-4fa9-b39c-e5fc4d8280ce'
    Author               = 'ALCops'
    CompanyName          = 'ALCops'
    Copyright            = '(c) ALCops. MIT License.'
    Description          = 'Rulebook diagnostic scan: the scan plan (new package versions, extraction, catalog, quarantine, housekeeping, regenerated endpoints, validation), the title, body and summary, and the living pull request on scan-diagnostics/<base>. See docs/reference/scan-mechanics.md.'
    PowerShellVersion    = '7.4'
    CompatiblePSEditions = @('Core')
    FunctionsToExport    = @(
        'ConvertTo-ScanPullRequestBody'
        'ConvertTo-ScanSummary'
        'Get-RulebookScanPlan'
        'Get-ScanCount'
        'Get-ScanTitle'
        'Publish-RulebookScan'
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
