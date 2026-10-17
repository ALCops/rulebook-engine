@{
    RootModule           = 'Rulebook.Site.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = '623bf735-0091-4cf4-811d-5e146cc0a580'
    Author               = 'ALCops'
    CompanyName          = 'ALCops'
    Copyright            = '(c) ALCops. MIT License.'
    Description          = 'Rulebook site: the data of the dashboard site, site/data/rulebook.json and <baseUrl>/rulebook.json (Get-RulebookSiteModel, ConvertTo-RulebookSiteDataJson, Export-RulebookSiteData): every id with its cell per level and stage, the deciding input and the fallback of override and quarantine cells, the level and stage page models. See docs/dashboard.md section 5.'
    PowerShellVersion    = '7.4'
    CompatiblePSEditions = @('Core')
    FunctionsToExport    = @(
        'ConvertTo-RulebookSiteDataJson'
        'Export-RulebookSiteData'
        'Get-RulebookSiteModel'
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
