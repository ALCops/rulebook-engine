@{
    RootModule           = 'Rulebook.Generate.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = '9e3b00cc-1865-49c0-b00a-41fd0f8affb3'
    Author               = 'ALCops'
    CompanyName          = 'ALCops'
    Copyright            = '(c) ALCops. MIT License.'
    Description          = 'Rulebook generator: level chain, stage deltas, twins setting, overrides, quarantine and catalog defaults to the sparse flat endpoints in rulesets/, plus the effective diff. See docs/rulebook/composition.md.'
    PowerShellVersion    = '7.4'
    CompatiblePSEditions = @('Core')
    FunctionsToExport    = @(
        'Compare-RulebookEndpoints'
        'ConvertTo-JsonString'
        'ConvertTo-RulesetJson'
        'Get-AnalyzerDefault'
        'Get-DiagnosticSortKey'
        'Get-EffectiveAction'
        'Get-EndpointFileName'
        'Get-RulebookEndpoint'
        'Read-Catalog'
        'Read-Overrides'
        'Read-Quarantine'
        'Read-RulebookInputs'
        'Read-RulesetFile'
        'Read-StageFile'
        'Read-Twins'
        'Resolve-LevelChain'
        'Update-RulebookEndpoints'
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
