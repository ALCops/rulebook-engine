@{
    RootModule           = 'Rulebook.NuGet.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = 'b64dfd40-5b3b-4c87-b95f-e7aaec3f23a0'
    Author               = 'ALCops'
    CompanyName          = 'ALCops'
    Copyright            = '(c) ALCops. MIT License.'
    Description          = 'Rulebook NuGet plumbing for the diagnostic scan: NuGet version comparison and channel selection, the flat-container index, and the download and extraction of a package version. See docs/reference/scan-mechanics.md.'
    PowerShellVersion    = '7.4'
    CompatiblePSEditions = @('Core')
    FunctionsToExport    = @(
        'Compare-NuGetVersion'
        'Get-NuGetPackageUrl'
        'Get-NuGetVersionIndex'
        'Save-NuGetPackage'
        'Select-NuGetChannelVersion'
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
