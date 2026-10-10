@{
    RootModule           = 'Rulebook.Common.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = 'f8f36d8b-0cab-4908-bd04-15a398840d95'
    Author               = 'ALCops'
    CompanyName          = 'ALCops'
    Copyright            = '(c) ALCops. MIT License.'
    Description          = 'Rulebook common helpers: the git runner with UTF-8 output and a per-process environment, and the ordinal (case-sensitive) map and set several engine modules share. Imports nothing.'
    PowerShellVersion    = '7.4'
    CompatiblePSEditions = @('Core')
    FunctionsToExport    = @(
        'Get-OrdinalMap'
        'Get-OrdinalSet'
        'Invoke-Git'
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
