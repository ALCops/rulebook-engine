@{
    RootModule           = 'Rulebook.GitHub.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = '9fcb1574-4aa2-4afc-a4ca-9bd38489b229'
    Author               = 'ALCops'
    CompanyName          = 'ALCops'
    Copyright            = '(c) ALCops. MIT License.'
    Description          = 'Rulebook GitHub plumbing for the update workflow: one REST wrapper, the GHTOKENWORKFLOW exchange (personal access token or GitHub App JSON), the template zipball, pull requests (the living pull request of the scan included), and the clone, commit and push (a lease push for the scan branch) with the token in the git environment only. See docs/reference/update-mechanics.md.'
    PowerShellVersion    = '7.4'
    CompatiblePSEditions = @('Core')
    FunctionsToExport    = @(
        'Find-GitHubPullRequest'
        'Find-GitHubPullRequestByHead'
        'Get-GitHubAccessToken'
        'Get-GitHubBranchSha'
        'Get-GitHubCommitList'
        'Get-GitRootTree'
        'Invoke-GitHubApi'
        'New-GitHubAppJwt'
        'New-GitHubClone'
        'New-GitHubPullRequest'
        'Publish-GitHubChange'
        'Save-GitHubZipball'
        'Update-GitHubPullRequest'
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
