@{
    RootModule           = 'Rulebook.Update.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = '0ede9150-451b-40b8-911f-7a37ee67d3e8'
    Author               = 'ALCops'
    CompanyName          = 'ALCops'
    Copyright            = '(c) ALCops. MIT License.'
    Description          = 'Rulebook update: builds the candidate tree of an organization rulebook repository from its template by file class, regenerates and validates it, lists the changes and opens the update pull request. See docs/reference/update-mechanics.md.'
    PowerShellVersion    = '7.4'
    CompatiblePSEditions = @('Core')
    FunctionsToExport    = @(
        'Compare-CustomizableFile'
        'ConvertTo-TemplateUrl'
        'ConvertTo-UpdatedWorkflowText'
        'ConvertTo-UpdatePullRequestBody'
        'ConvertTo-UpdateSummary'
        'Get-ReleaseNotesDelta'
        'Get-RulebookFileClass'
        'Get-RulebookTemplate'
        'Get-RulebookUpdatePlan'
        'Get-RulebookUpdateStatus'
        'Get-TemplateContentSha'
        'Limit-SummaryText'
        'Publish-RulebookUpdate'
        'Update-RulebookSettingsText'
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
