@{
    RootModule           = 'Rulebook.Levels.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = '6d0f4b7e-2c4a-4f0e-9b61-58a3c2e7d915'
    Author               = 'ALCops'
    CompanyName          = 'ALCops'
    Copyright            = '(c) ALCops. MIT License.'
    Description          = 'Rulebook levels: the everything-off root level of an organization (New-RulebookOffLevel) and the generated level pages (New-RulebookLevelDocs) with their model (Get-RulebookLevelSummary). See docs/authoring-levels.md.'
    PowerShellVersion    = '7.4'
    CompatiblePSEditions = @('Core')
    FunctionsToExport    = @(
        'ConvertTo-LevelDocsIndexMarkdown'
        'ConvertTo-LevelDocsMarkdown'
        'Get-RulebookLevelSummary'
        'Get-RulebookOffLevelEntry'
        'New-RulebookLevelDocs'
        'New-RulebookOffLevel'
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
