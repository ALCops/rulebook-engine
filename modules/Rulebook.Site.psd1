@{
    RootModule           = 'Rulebook.Site.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = '623bf735-0091-4cf4-811d-5e146cc0a580'
    Author               = 'ALCops'
    CompanyName          = 'ALCops'
    Copyright            = '(c) ALCops. MIT License.'
    Description          = 'Rulebook site: the data of the dashboard site, site/data/rulebook.json and <baseUrl>/rulebook.json (Get-RulebookSiteModel, ConvertTo-RulebookSiteDataJson, Export-RulebookSiteData): every id with its cell per level and stage, the deciding input and the fallback of override and quarantine cells, the level and stage page models; the Hugo install and build of site/ (Install-Hugo, Build-RulebookSite). See docs/dashboard.md sections 4 and 5.'
    PowerShellVersion    = '7.4'
    CompatiblePSEditions = @('Core')
    FunctionsToExport    = @(
        'Build-RulebookSite'
        'ConvertTo-RulebookSiteDataJson'
        'Export-RulebookSiteData'
        'Get-RulebookSiteDataPath'
        'Get-RulebookSiteModel'
        'Install-Hugo'
        'Read-RulebookSiteModel'
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
