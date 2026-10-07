# Extract suite for WP08 (#10): modules/Rulebook.Extract on the stub analyzer packages of
# tests/fixtures/stub-analyzers/ (compiled at test time, tests/Helpers/StubFeed.ps1). Offline: the real packages run
# only in the CI job scan-action and the live end-to-end run (docs/reference/scan-mechanics.md section 10).

BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $PSScriptRoot 'Helpers' 'RepoFixture.ps1')
    . (Join-Path $PSScriptRoot 'Helpers' 'StubFeed.ps1')
    Import-Module (Join-Path $repoRoot 'modules' 'Rulebook.Extract.psd1') -Force
    $script:tools = 'microsoft.dynamics.businesscentral.development.tools'
    $script:alcops = 'alcops.analyzers'
    $script:packages = Join-Path $TestDrive 'packages'
    $script:toolsStable = Resolve-AnalyzerFolder -PackageRoot (Expand-StubPackage -Variant 'tools-stable' -Destination $packages) -Kind tools
    $script:alcopsV1 = Resolve-AnalyzerFolder -PackageRoot (Expand-StubPackage -Variant 'alcops-v1' -Destination $packages) -Kind alcops
    $script:alcopsV2 = Resolve-AnalyzerFolder -PackageRoot (Expand-StubPackage -Variant 'alcops-v2' -Destination $packages) -Kind alcops
    $script:work = Join-Path $TestDrive 'work'
    # One extraction per package version, shared by the cases below.
    $script:toolsResult = Invoke-DescriptorExtraction -ToolsDir $toolsStable -ExpectedAssembly (Get-ExpectedAssembly -PackageId $tools) -WorkPath $work
    $script:toolsRecords = ConvertTo-DiagnosticRecord -Result $toolsResult -PackageId $tools
    $script:v1Result = Invoke-DescriptorExtraction -ToolsDir $toolsStable -AlcopsDir $alcopsV1 -ExpectedAssembly (Get-ExpectedAssembly -PackageId $alcops) -WorkPath $work
    $script:v1Records = ConvertTo-DiagnosticRecord -Result $v1Result -PackageId $alcops

    function New-Row {

        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helper; builds an object or writes only to TestDrive')]
        # A row of an extraction result, for the ConvertTo-DiagnosticRecord cases.
        param([string]$Id, [string]$Assembly, [string]$Severity = 'Warning', [bool]$Enabled = $true, [string]$Title = 'Title', [string]$Link, [bool]$Advertised = $true)
        return [ordered]@{ id = $Id; assembly = $Assembly; analyzerType = 'X'; defaultSeverity = $Severity; enabledByDefault = $Enabled; title = $Title; helpLinkUri = $(if ($Link) { $Link } else { $null }); isDeprecated = $false; advertised = $Advertised }
    }
}

AfterAll {
    Remove-Module Rulebook.Extract, Rulebook.Catalog -ErrorAction SilentlyContinue
}

Describe 'stub packages' {
    It 'builds a flat container with the index and the nupkg' {
        $feed = New-StubFeed -Variants 'tools-stable' -Destination (Join-Path $TestDrive 'feed') -IndexOnly @{ $alcops = '1.3.0-beta.1' }
        (Get-Content -Raw (Join-Path $feed $tools 'index.json') | ConvertFrom-Json).versions | Should-BeCollection @('18.0.43.1464')
        (Get-Content -Raw (Join-Path $feed $alcops 'index.json') | ConvertFrom-Json).versions | Should-BeCollection @('1.3.0-beta.1')
        Test-Path -LiteralPath (Join-Path $feed $tools '18.0.43.1464' "$tools.18.0.43.1464.nupkg") | Should-BeTrue
    }

    It 'names every assembly after its file (the cops reference Microsoft.Dynamics.Nav.CodeAnalysis by name)' {
        foreach ($dll in @(Get-ChildItem -LiteralPath $toolsStable -Filter '*.dll') + @(Get-ChildItem -LiteralPath $alcopsV1 -Filter '*.dll')) {
            [System.Reflection.AssemblyName]::GetAssemblyName($dll.FullName).Name | Should-Be $dll.BaseName
        }
    }
}

Describe 'Resolve-AnalyzerFolder' {
    BeforeAll {
        $script:fake = Join-Path $TestDrive 'fake'
        foreach ($folder in 'tools/net8.0/any', 'tools/net10.0/any', 'tools/net99.0/any', 'tools/netstandard2.1', 'lib/net8.0', 'lib/net10.0', 'lib/net99.0', 'lib/netstandard2.1') {
            [void](New-Item -ItemType Directory -Path (Join-Path $fake $folder) -Force)
        }
    }

    It 'picks <Expected> of <Kind> for .NET <Major>' -ForEach @(
        @{ Kind = 'tools'; Major = 10; Expected = 'tools/net10.0/any' }
        @{ Kind = 'tools'; Major = 9; Expected = 'tools/net8.0/any' }
        @{ Kind = 'alcops'; Major = 10; Expected = 'lib/net10.0' }
        @{ Kind = 'alcops'; Major = 8; Expected = 'lib/net8.0' }
        @{ Kind = 'alcops'; Major = 200; Expected = 'lib/net99.0' }
    ) {
        $path = Resolve-AnalyzerFolder -PackageRoot $fake -Kind $Kind -RuntimeMajor $Major
        [System.IO.Path]::GetRelativePath($fake, $path).Replace('\', '/') | Should-Be $Expected
    }

    It 'never picks netstandard and names the folders when none qualifies' {
        { Resolve-AnalyzerFolder -PackageRoot $fake -Kind alcops -RuntimeMajor 7 } | Should-Throw -ExceptionMessage '*lib/<tfm> folder for .NET 7*(found: net10.0, net8.0, net99.0, netstandard2.1)'
        $caught = $null
        try { Resolve-AnalyzerFolder -PackageRoot $fake -Kind tools -RuntimeMajor 7 } catch { $caught = $_ }
        $caught.Exception.Data['Stage'] | Should-Be 'extract'
    }
}

Describe 'Invoke-DescriptorExtraction on the tools package' {
    It 'reads the compiler ids of 100 and up named WRN_, INF_ or HDN_ with their severity' {
        $compiler = @($toolsRecords.Records.Values | Where-Object Analyzer -EQ 'Compiler')
        @($compiler | ForEach-Object { "$($_.Id) $($_.DefaultSeverity)" }) | Should-BeCollection @('AL0200 Warning', 'AL1027 Info', 'AL1030 Hidden')
        $toolsResult['compilerTitlesMissing'] | Should-BeTrue
        @($compiler | Where-Object { $null -ne $_.Title }) | Should-BeCollection @()
    }

    It 'merges an id two analyzers advertise and counts them' {
        $toolsRecords.Records['AA0001'].DescriptorCount | Should-Be 2
        @($toolsResult['rows'] | Where-Object { $_['id'] -eq 'AA0001' }).Count | Should-Be 2
        @($toolsRecords.Conflicts) | Should-BeCollection @()
    }

    It 'reports a descriptor no analyzer returns as field-only, not advertised' {
        @($toolsResult['fieldOnly'] | ForEach-Object { $_['id'] }) | Should-BeCollection @('AA0002')
        $toolsRecords.Records['AA0002'].Advertised | Should-BeFalse
        $toolsRecords.Records['AA0002'].EnabledByDefault | Should-BeFalse
    }

    It 'flags a deprecated descriptor' {
        $toolsRecords.Records['AA0003'].Deprecated | Should-BeTrue
        $toolsRecords.Records['AA0001'].Deprecated | Should-BeFalse
    }

    It 'reports a static descriptor getter that throws without failing' {
        @($toolsResult['fieldErrors']) | Should-BeCollection @('Microsoft.Dynamics.Nav.CodeCop.Descriptors.Broken: stub getter failure')
        @($toolsRecords.FieldErrors) | Should-BeCollection @('Microsoft.Dynamics.Nav.CodeCop.Descriptors.Broken: stub getter failure')
    }

    It 'skips abstract analyzers and analyzers without a parameterless constructor' {
        $codeCop = @($toolsResult['assemblies'] | Where-Object { $_['name'] -eq 'Microsoft.Dynamics.Nav.CodeCop' })[0]
        $codeCop['analyzers'] | Should-Be 2
    }

    It 'lists every expected tools assembly' {
        @($toolsResult['assemblies'] | ForEach-Object { $_['name'] } | Sort-Object) | Should-BeCollection @(Get-ExpectedAssembly -PackageId $tools | Sort-Object)
    }
}

Describe 'Invoke-DescriptorExtraction on ALCops' {
    It 'reads 1.3.1 hosted by the tools package' {
        $v1Records.Records['LC0015'].DefaultSeverity | Should-Be 'Info'
        $v1Records.Records['CM0001'].EnabledByDefault | Should-BeFalse
        $v1Records.Records['LC0000'].Advertised | Should-BeFalse
        $v1Records.Records['TA0001'].HelpLinkUri | Should-Be 'https://alcops.dev/docs/analyzers/testautomationCop/ta0001/'
        $v1Records.Records['TA0001'].Docs | Should-Be 'https://alcops.dev/docs/analyzers/testautomationcop/ta0001/'
        $v1Records.Records.Contains('LC0100') | Should-BeFalse
        @($v1Records.Records.Values | Where-Object { $_.Assembly -notlike 'ALCops.*' }) | Should-BeCollection @()
    }

    It 'reads 1.4.0-beta.1 right after 1.3.1 in a process of its own' {
        $result = Invoke-DescriptorExtraction -ToolsDir $toolsStable -AlcopsDir $alcopsV2 -ExpectedAssembly (Get-ExpectedAssembly -PackageId $alcops) -WorkPath $work
        $records = ConvertTo-DiagnosticRecord -Result $result -PackageId $alcops
        $records.Records['LC0015'].DefaultSeverity | Should-Be 'Warning'
        $records.Records.Contains('LC0100') | Should-BeTrue
    }

    It 'keeps an id with an unknown prefix and lists it' {
        $v1Records.Records.Contains('ZZ0001') | Should-BeTrue
        @($v1Records.UnknownPrefixes) | Should-BeCollection @('ZZ0001')
    }
}

Describe 'Invoke-DescriptorExtraction failures' {
    It 'fails when an expected assembly is missing, naming it' {
        { Invoke-DescriptorExtraction -ToolsDir $toolsStable -ExpectedAssembly @('Microsoft.Dynamics.Nav.CodeCop', 'Microsoft.Dynamics.Nav.LegacyCop') -WorkPath $work } |
            Should-Throw -ExceptionMessage '*Expected assembly Microsoft.Dynamics.Nav.LegacyCop.dll is missing*'
    }

    It 'fails loudly on a DLL that is not an assembly, with the output of the child process' {
        $broken = Join-Path $TestDrive 'broken'
        Copy-FixtureTree -Source $toolsStable -Destination $broken
        [System.IO.File]::WriteAllText((Join-Path $broken 'Microsoft.Dynamics.Nav.UICop.dll'), "not an assembly`n")
        $caught = $null
        try { $null = Invoke-DescriptorExtraction -ToolsDir $broken -WorkPath $work } catch { $caught = $_ }
        $caught.Exception.Message | Should-BeLikeString "Extraction failed for $broken*Microsoft.Dynamics.Nav.UICop.dll*"
        $caught.Exception.Data['Stage'] | Should-Be 'extract'
    }

    It 'stops a child process that does not finish in time' {
        $caught = $null
        try { $null = Invoke-DescriptorExtraction -ToolsDir $toolsStable -WorkPath $work -TimeoutSeconds 0 } catch { $caught = $_ }
        $caught.Exception.Message | Should-BeLikeString '*no result after 0 s (the process was stopped)'
        $caught.Exception.Data['ProcessId'] | Should-BeGreaterThan 0
        Get-Process -Id $caught.Exception.Data['ProcessId'] -ErrorAction SilentlyContinue | Should-BeNull
    }

    It 'fails naming the loader exception when a cop references an assembly the package does not ship' {
        $root = Get-FaultyToolsFolder -Fault MissingDependency -Destination (Join-Path $TestDrive 'missing-dependency')
        $caught = $null
        try { $null = Invoke-DescriptorExtraction -ToolsDir (Resolve-AnalyzerFolder -PackageRoot $root -Kind tools) -WorkPath $work } catch { $caught = $_ }
        $caught.Exception.Message | Should-BeLikeString '*Microsoft.Dynamics.Nav.BrokenCop.dll: * types could not be loaded (*Stub.Missing*'
    }

    It 'fails naming the analyzer whose constructor throws' {
        $root = Get-FaultyToolsFolder -Fault ThrowingConstructor -Destination (Join-Path $TestDrive 'throwing-constructor')
        $caught = $null
        try { $null = Invoke-DescriptorExtraction -ToolsDir (Resolve-AnalyzerFolder -PackageRoot $root -Kind tools) -WorkPath $work } catch { $caught = $_ }
        $caught.Exception.Message | Should-BeLikeString '*: Could not instantiate Microsoft.Dynamics.Nav.ThrowingCop.ThrowingAnalyzer of Microsoft.Dynamics.Nav.ThrowingCop.dll: stub constructor failure'
    }

    It 'starts the child without the tokens and action inputs of the parent' {
        $saved = @{ Input = $env:INPUT_TOKEN; Gh = $env:GH_TOKEN; Custom = $env:RULEBOOK_SECRET_TOKEN; Plain = $env:RULEBOOK_PLAIN }
        try {
            $env:INPUT_TOKEN = 'ghp_parent'
            $env:GH_TOKEN = 'ghp_parent'
            $env:RULEBOOK_SECRET_TOKEN = 'ghp_parent'
            $env:RULEBOOK_PLAIN = 'kept'
            $info = InModuleScope Rulebook.Extract { New-ExtractionStartInfo -PwshPath 'pwsh' -EncodedCommand 'AA==' }
            $names = @($info.Environment.Keys)
            foreach ($name in 'INPUT_TOKEN', 'GH_TOKEN', 'RULEBOOK_SECRET_TOKEN', 'GITHUB_TOKEN', 'ACTIONS_RUNTIME_TOKEN', 'ACTIONS_ID_TOKEN_REQUEST_TOKEN') { $names -contains $name | Should-BeFalse -Because $name }
            $info.Environment['RULEBOOK_PLAIN'] | Should-Be 'kept'
        } finally {
            $env:INPUT_TOKEN = $saved.Input
            $env:GH_TOKEN = $saved.Gh
            $env:RULEBOOK_SECRET_TOKEN = $saved.Custom
            $env:RULEBOOK_PLAIN = $saved.Plain
        }
    }

    It 'leaves no result file behind' {
        @(Get-ChildItem -LiteralPath $work -Filter 'descriptors-*.json') | Should-BeCollection @()
    }
}

Describe 'ConvertTo-DiagnosticRecord' {
    BeforeAll {
        $script:result = [ordered]@{
            rows                  = @(
                New-Row -Id 'AL0200' -Assembly 'Microsoft.Dynamics.Nav.CodeAnalysis' -Title "Property  '{0}'`n is obsolete "
                New-Row -Id 'AA0137' -Assembly 'Microsoft.Dynamics.Nav.CodeCop' -Link 'https://learn.microsoft.com/dynamics365/business-central/dev-itpro/developer/analyzers/codecop-aa0137?wt.mc_id=d365bc_inproduct_alextension'
                New-Row -Id 'AS0001' -Assembly 'Microsoft.Dynamics.Nav.AppSourceCop' -Severity 'Error'
                New-Row -Id 'AS0001' -Assembly 'Microsoft.Dynamics.Nav.AppSourceCop' -Severity 'Warning'
                New-Row -Id 'TA0001' -Assembly 'ALCops.TestAutomationCop' -Link 'https://alcops.dev/docs/analyzers/testautomationCop/ta0001/'
                New-Row -Id 'LC0001' -Assembly 'ALCops.LinterCop' -Title ''
            )
            fieldOnly             = @(New-Row -Id 'PC0000' -Assembly 'ALCops.PlatformCop' -Advertised $false)
            compilerTitlesMissing = $false
        }
    }

    It 'keeps the rows of the package only and names the analyzers' {
        $toolRecords = ConvertTo-DiagnosticRecord -Result $result -PackageId 'microsoft.dynamics.businesscentral.development.tools'
        @($toolRecords.Records.Values | ForEach-Object { "$($_.Id) $($_.Analyzer)" }) | Should-BeCollection @('AL0200 Compiler', 'AA0137 CodeCop', 'AS0001 AppSourceCop')
        $alcopsRecords = ConvertTo-DiagnosticRecord -Result $result -PackageId 'alcops.analyzers'
        @($alcopsRecords.Records.Values | ForEach-Object { "$($_.Id) $($_.Analyzer)" }) | Should-BeCollection @('TA0001 TestAutomationCop', 'LC0001 LinterCop', 'PC0000 PlatformCop')
    }

    It 'folds white space in a title and keeps no empty title' {
        $toolRecords = ConvertTo-DiagnosticRecord -Result $result -PackageId 'microsoft.dynamics.businesscentral.development.tools'
        $toolRecords.Records['AL0200'].Title | Should-Be "Property '{0}' is obsolete"
        (ConvertTo-DiagnosticRecord -Result $result -PackageId 'alcops.analyzers').Records['LC0001'].Title | Should-BeNull
    }

    It 'normalises the docs links' {
        $toolRecords = ConvertTo-DiagnosticRecord -Result $result -PackageId 'microsoft.dynamics.businesscentral.development.tools'
        $toolRecords.Records['AL0200'].Docs | Should-Be 'https://learn.microsoft.com/dynamics365/business-central/dev-itpro/developer/diagnostics/diagnostic-al200'
        $toolRecords.Records['AA0137'].Docs | Should-Be 'https://learn.microsoft.com/dynamics365/business-central/dev-itpro/developer/analyzers/codecop-aa0137'
        (ConvertTo-DiagnosticRecord -Result $result -PackageId 'alcops.analyzers').Records['TA0001'].Docs | Should-Be 'https://alcops.dev/docs/analyzers/testautomationcop/ta0001/'
    }

    It 'lists disagreeing duplicates as a conflict and keeps the first' {
        $toolRecords = ConvertTo-DiagnosticRecord -Result $result -PackageId 'microsoft.dynamics.businesscentral.development.tools'
        @($toolRecords.Conflicts | ForEach-Object { "$($_.Id): $($_.Variants -join ', ')" }) | Should-BeCollection @('AS0001: Error/true, Warning/true')
        $toolRecords.Records['AS0001'].DefaultSeverity | Should-Be 'Error'
    }

    It 'marks a field-only id as not advertised' {
        $record = (ConvertTo-DiagnosticRecord -Result $result -PackageId 'alcops.analyzers').Records['PC0000']
        $record.Advertised | Should-BeFalse
        $record.DescriptorCount | Should-Be 0
    }
}
