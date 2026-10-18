@{
    RootModule           = 'Rulebook.Edit.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = '43be2693-8cbe-4092-a9e9-53eb1903c922'
    Author               = 'ALCops'
    CompanyName          = 'ALCops'
    Copyright            = '(c) ALCops. MIT License.'
    Description          = 'Rulebook edit: reads and writes overrides.json, reads a change set from the body of a rulebook-change issue and checks it against the change set schema, applies it (set, remove, release from quarantine) to a candidate copy of an organization rulebook repository, plans the effective change per endpoint and the no-op rule, renders the table, pull request body and summary, and lands the change as a pull request or direct commit. See docs/reference/change-mechanics.md.'
    PowerShellVersion    = '7.4'
    CompatiblePSEditions = @('Core')
    FunctionsToExport    = @(
        'ConvertFrom-RulebookIssueBody'
        'ConvertTo-ChangeItemList'
        'ConvertTo-ChangePullRequestBody'
        'ConvertTo-ChangeSummary'
        'ConvertTo-ChangeTable'
        'ConvertTo-OverridesJson'
        'ConvertTo-RulebookChangeSet'
        'Get-RulebookChangeTitle'
        'Invoke-RulebookChangeSet'
        'Publish-RulebookChange'
        'Read-OverridesFile'
        'Read-RulebookChangeSetText'
        'Remove-RulebookOverride'
        'Remove-RulebookQuarantine'
        'Set-RulebookOverride'
        'Test-RulebookChangeSet'
        'Write-OverridesFile'
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
