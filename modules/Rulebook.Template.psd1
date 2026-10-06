@{
    RootModule           = 'Rulebook.Template.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = '3b670575-29ec-4e20-8ca6-23f211a81661'
    Author               = 'ALCops'
    CompanyName          = 'ALCops'
    Copyright            = '(c) ALCops. MIT License.'
    Description          = 'Rulebook template generators: the level files, base/twins.json, the stage files, the seed catalog and the skeletons of template/, from the level content in docs/rulebook. See docs/reference/template-content.md.'
    PowerShellVersion    = '7.4'
    CompatiblePSEditions = @('Core')
    FunctionsToExport    = @(
        'Build-RulebookBase'
        'Build-RulebookCatalog'
        'Build-RulebookStages'
        'New-RulebookSkeleton'
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
