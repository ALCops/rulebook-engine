@{
    RootModule           = 'Rulebook.Quarantine.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = 'd199d13c-a5fa-4c84-af8c-bd2a75f0be1d'
    Author               = 'ALCops'
    CompanyName          = 'ALCops'
    Copyright            = '(c) ALCops. MIT License.'
    Description          = 'Rulebook quarantine for the diagnostic scan: the quarantine policy of the settings, the quarantine.<stage>.json files in the template layout, new ids added to the policy stages and housekeeping. See docs/reference/scan-mechanics.md.'
    PowerShellVersion    = '7.4'
    CompatiblePSEditions = @('Core')
    FunctionsToExport    = @(
        'Add-QuarantineEntry'
        'ConvertFrom-QuarantineFileText'
        'ConvertTo-QuarantineJson'
        'Get-QuarantinePolicy'
        'Invoke-QuarantineHousekeeping'
        'New-QuarantineJustification'
        'Read-QuarantineFile'
        'Update-QuarantineFromScan'
        'Write-QuarantineFile'
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
