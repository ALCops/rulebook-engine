@{
    RootModule           = 'Rulebook.Extract.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = '15da7f9e-bea7-4bf9-94e4-9ac09c04ce56'
    Author               = 'ALCops'
    CompanyName          = 'ALCops'
    Copyright            = '(c) ALCops. MIT License.'
    Description          = 'Rulebook descriptor extraction for the diagnostic scan: the analyzer folder of a package, every diagnostic descriptor by reflection in a child pwsh per package version, and one record per id. See docs/reference/scan-mechanics.md.'
    PowerShellVersion    = '7.4'
    CompatiblePSEditions = @('Core')
    FunctionsToExport    = @(
        'ConvertTo-DiagnosticRecord'
        'Get-AnalyzerDescriptor'
        'Get-ExpectedAssembly'
        'Invoke-DescriptorExtraction'
        'Resolve-AnalyzerFolder'
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
