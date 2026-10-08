@{
    RootModule           = 'Rulebook.Action.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = '570fccc7-5902-4294-a9ee-6537554ffd8e'
    Author               = 'ALCops'
    CompanyName          = 'ALCops'
    Copyright            = '(c) ALCops. MIT License.'
    Description          = 'Rulebook action helpers shared by the entry scripts under actions/: workflow command escaping and annotations, the run context, the job summary and GITHUB_OUTPUT writers, path resolution and the Markdown helpers for summaries. A leaf module without engine imports.'
    PowerShellVersion    = '7.4'
    CompatiblePSEditions = @('Core')
    FunctionsToExport    = @(
        'Add-Annotation'
        'Add-Failure'
        'ConvertTo-SingleLine'
        'Format-AnnotationText'
        'Format-TableCell'
        'Limit-SummaryText'
        'New-ActionContext'
        'Resolve-ActionPath'
        'Write-ActionOutput'
        'Write-Text'
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
