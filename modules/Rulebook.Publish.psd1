@{
    RootModule           = 'Rulebook.Publish.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = '5f0c3a9e-7d41-4b6e-9a2f-1c8e6b3d4a75'
    Author               = 'ALCops'
    CompanyName          = 'ALCops'
    Copyright            = '(c) ALCops. MIT License.'
    Description          = 'Rulebook publisher: stages the endpoints, the rendered skeletons and index.html, explains the GitHub Pages preflight and checks that every published URL serves the staged file. See docs/reference/publish-targets.md.'
    PowerShellVersion    = '7.4'
    CompatiblePSEditions = @('Core')
    FunctionsToExport    = @(
        'ConvertTo-RulebookIndexHtml'
        'Get-PagesPreflightResult'
        'Invoke-PagesPreflight'
        'New-RulebookPublishStage'
        'Resolve-RulebookBaseUrl'
        'Resolve-RulebookPublishTarget'
        'Test-RulebookEndpoints'
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
