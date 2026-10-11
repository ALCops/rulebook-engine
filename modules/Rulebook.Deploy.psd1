@{
    RootModule           = 'Rulebook.Deploy.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = '7ed1f543-0708-4d6d-b063-0b5cbb2bf5bc'
    Author               = 'ALCops'
    CompanyName          = 'ALCops'
    Copyright            = '(c) ALCops. MIT License.'
    Description          = 'Rulebook deploy: the release of the engine and the template from RELEASENOTES.md (floating branch v<major>, tags, the reference rewrite, the release notes copy, the GitHub Release) and the refresh of ALCops/rulebook@main (D52). See docs/releasing.md.'
    PowerShellVersion    = '7.4'
    CompatiblePSEditions = @('Core')
    FunctionsToExport    = @(
        'ConvertTo-DeploySummary'
        'Convert-DeployReference'
        'Copy-DeployTemplate'
        'Get-DeployPlan'
        'Get-ReleaseNotesSection'
        'Get-ReleaseVersion'
        'Invoke-RulebookDeploy'
        'New-GitHubRelease'
        'Publish-EngineRelease'
        'Publish-TemplateRelease'
        'Test-DeployPrecondition'
        'Update-DeployReference'
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
