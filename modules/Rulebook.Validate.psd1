@{
    RootModule           = 'Rulebook.Validate.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = 'd533bf8d-fda5-42e7-9613-e43255cdc2b4'
    Author               = 'ALCops'
    CompanyName          = 'ALCops'
    Copyright            = '(c) ALCops. MIT License.'
    Description          = 'Rulebook validator: checks C1 to C16 on an organization rulebook repository, including the regeneration check C12. See docs/ARCHITECTURE.md section 5.3.'
    PowerShellVersion    = '7.4'
    CompatiblePSEditions = @('Core')
    FunctionsToExport    = @('Test-Rulebook')
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
