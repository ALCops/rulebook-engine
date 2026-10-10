# NuGet suite for WP08 (#10): modules/Rulebook.NuGet. The web side is mocked at Invoke-NuGetRequest (the module's
# single Invoke-WebRequest); the folder source runs against a flat container in TestDrive.

BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $PSScriptRoot 'Helpers' 'RepoFixture.ps1')
    Import-Module (Join-Path $repoRoot 'modules' 'Rulebook.NuGet.psd1') -Force
    # No waiting between retries in the suite.
    & (Get-Module Rulebook.NuGet) { $script:RetryDelaySeconds = @(0, 0, 0) }

    function New-ZipPackage {

        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helper; builds an object or writes only to TestDrive')]
        # A nupkg-shaped zip at Path holding tools/net8.0/any/readme.txt.
        param([Parameter(Mandatory)][string]$Path)
        $content = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
        Write-FixtureText -Path (Join-Path $content 'tools' 'net8.0' 'any' 'readme.txt') -Text 'stub'
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force)
        [System.IO.Compression.ZipFile]::CreateFromDirectory($content, $Path)
    }
}

AfterAll {
    Remove-Module Rulebook.NuGet -ErrorAction SilentlyContinue
}

Describe 'Compare-NuGetVersion' {
    It '<Reference> sorts before <Difference>' -ForEach @(
        @{ Reference = '1.3.0-beta.1'; Difference = '1.3.1' }
        @{ Reference = '1.4.0-beta.1'; Difference = '1.4.0' }
        @{ Reference = '18.0.43.1464'; Difference = '30.0.42.60748-beta' }
        @{ Reference = '1.4.0-beta.2'; Difference = '1.4.0-beta.10' }
        @{ Reference = '1.4.0-alpha'; Difference = '1.4.0-beta' }
        @{ Reference = '1.4.0-beta'; Difference = '1.4.0-beta.1' }
        @{ Reference = '1.4.0-1'; Difference = '1.4.0-alpha' }
        @{ Reference = '1.9'; Difference = '1.10' }
    ) {
        Compare-NuGetVersion -Reference $Reference -Difference $Difference | Should-Be -1
        Compare-NuGetVersion -Reference $Difference -Difference $Reference | Should-Be 1
    }

    It 'treats <Reference> and <Difference> as equal' -ForEach @(
        @{ Reference = '1.0'; Difference = '1.0.0.0' }
        @{ Reference = '1.3.1+build.7'; Difference = '1.3.1' }
        @{ Reference = '1.4.0-BETA.1'; Difference = '1.4.0-beta.1' }
    ) {
        Compare-NuGetVersion -Reference $Reference -Difference $Difference | Should-Be 0
    }

    It 'throws on <Version>' -ForEach @(@{ Version = 'latest' }, @{ Version = '1.2.3.4.5' }, @{ Version = '' }) {
        { Compare-NuGetVersion -Reference $Version -Difference '1.0' } | Should-Throw
    }
}

Describe 'Select-NuGetChannelVersion' {
    It 'drops a prerelease older than the stable version (ALCops 1.3.0-beta.1 after 1.3.1)' {
        $selected = Select-NuGetChannelVersion -Versions @('1.2.0', '1.3.0-beta.1', '1.3.1') -IncludePrerelease
        $selected.Stable | Should-Be '1.3.1'
        $selected.Prerelease | Should-BeNull
    }

    It 'keeps a newer prerelease' {
        $selected = Select-NuGetChannelVersion -Versions @('1.3.1', '1.4.0-beta.1', '1.4.0-beta.2') -IncludePrerelease
        $selected.Stable | Should-Be '1.3.1'
        $selected.Prerelease | Should-Be '1.4.0-beta.2'
    }

    It 'leaves the prerelease out without -IncludePrerelease' {
        (Select-NuGetChannelVersion -Versions @('1.3.1', '1.4.0-beta.1')).Prerelease | Should-BeNull
    }

    It 'never trusts the index order' {
        $selected = Select-NuGetChannelVersion -Versions @('30.0.42.60748-beta', '18.0.43.1464', '9.0.1', '18.0.41.62505', '30.0.40.1-beta') -IncludePrerelease
        $selected.Stable | Should-Be '18.0.43.1464'
        $selected.Prerelease | Should-Be '30.0.42.60748-beta'
    }

    It 'skips and lists entries that are not versions, a sole one included' {
        $selected = Select-NuGetChannelVersion -Versions @('../../evil', '', '1.3.1', '1.4.0-beta.1/../x') -IncludePrerelease
        $selected.Stable | Should-Be '1.3.1'
        $selected.Prerelease | Should-BeNull
        $selected.Invalid | Should-BeCollection @('../../evil', '', '1.4.0-beta.1/../x')
        $sole = Select-NuGetChannelVersion -Versions @('../../evil')
        $sole.Stable | Should-BeNull
        $sole.Invalid | Should-BeCollection @('../../evil')
    }

    It 'has no stable version for an index of prereleases' {
        $selected = Select-NuGetChannelVersion -Versions @('1.0.0-beta.1') -IncludePrerelease
        $selected.Stable | Should-BeNull
        $selected.Prerelease | Should-Be '1.0.0-beta.1'
    }
}

Describe 'Get-NuGetVersionIndex' {
    It 'requests the lowercased id from nuget.org' {
        Mock Invoke-NuGetRequest -ModuleName Rulebook.NuGet { [pscustomobject]@{ StatusCode = 200; Content = '{ "versions": ["1.3.1", "1.4.0-beta.1"] }' } }
        $index = Get-NuGetVersionIndex -PackageId 'ALCops.Analyzers'
        $index.PackageId | Should-Be 'alcops.analyzers'
        $index.Versions | Should-BeCollection @('1.3.1', '1.4.0-beta.1')
        Should-Invoke Invoke-NuGetRequest -ModuleName Rulebook.NuGet -Times 1 -Exactly -ParameterFilter { $Uri -eq 'https://api.nuget.org/v3-flatcontainer/alcops.analyzers/index.json' }
    }

    It 'reads a folder source from disk' {
        $feed = Join-Path $TestDrive 'feed'
        Write-FixtureText -Path (Join-Path $feed 'alcops.analyzers' 'index.json') -Text '{ "versions": ["1.3.1"] }'
        Mock Invoke-NuGetRequest -ModuleName Rulebook.NuGet { throw 'must not request' }
        (Get-NuGetVersionIndex -PackageId 'alcops.analyzers' -Source $feed).Versions | Should-BeCollection @('1.3.1')
    }

    It 'throws on a 404 with the status and the nuget stage' {
        Mock Invoke-NuGetRequest -ModuleName Rulebook.NuGet { [pscustomobject]@{ StatusCode = 404; Content = 'Not Found' } }
        $caught = $null
        try { $null = Get-NuGetVersionIndex -PackageId 'alcops.analyzers' } catch { $caught = $_ }
        $caught.Exception.Message | Should-Be 'Could not read the NuGet index of alcops.analyzers (HTTP 404)'
        $caught.Exception.Data['Stage'] | Should-Be 'nuget'
    }

    It 'throws with the nuget stage on an index that is <Case>' -ForEach @(
        @{ Case = 'not JSON'; Text = '{ "versions": '; Message = 'The NuGet index of alcops.analyzers is not JSON:*' }
        @{ Case = 'without a versions array'; Text = '{ "items": [] }'; Message = 'The NuGet index of alcops.analyzers has no versions array' }
    ) {
        $feed = Join-Path $TestDrive ('bad-feed-' + [guid]::NewGuid().ToString('n').Substring(0, 8))
        Write-FixtureText -Path (Join-Path $feed 'alcops.analyzers' 'index.json') -Text $Text
        $caught = $null
        try { $null = Get-NuGetVersionIndex -PackageId 'alcops.analyzers' -Source $feed } catch { $caught = $_ }
        $caught.Exception.Message | Should-BeLikeString $Message
        $caught.Exception.Data['Stage'] | Should-Be 'nuget'
    }
    It 'throws on a missing index in a folder source' {
        { Get-NuGetVersionIndex -PackageId 'missing.package' -Source $TestDrive } | Should-Throw -ExceptionMessage 'Could not read the NuGet index of missing.package (HTTP 404)'
    }
}

Describe 'Get-NuGetPackageUrl' {
    It 'lowercases id and version' {
        Get-NuGetPackageUrl -PackageId 'Microsoft.Dynamics.BusinessCentral.Development.Tools' -Version '30.0.42.60748-Beta' |
            Should-Be 'https://api.nuget.org/v3-flatcontainer/microsoft.dynamics.businesscentral.development.tools/30.0.42.60748-beta/microsoft.dynamics.businesscentral.development.tools.30.0.42.60748-beta.nupkg'
    }
}

Describe 'Save-NuGetPackage' {
    It 'downloads and extracts, replacing a stale folder' {
        $path = Join-Path $TestDrive 'packages'
        Write-FixtureText -Path (Join-Path $path 'alcops.analyzers.1.3.1' 'stale.txt') -Text 'old'
        Mock Invoke-NuGetRequest -ModuleName Rulebook.NuGet {
            New-ZipPackage -Path $OutFile
            [pscustomobject]@{ StatusCode = 200; Content = '' }
        }
        $saved = Save-NuGetPackage -PackageId 'ALCops.Analyzers' -Version '1.3.1' -Path $path
        $saved.ExtractPath | Should-Be (Join-Path $path 'alcops.analyzers.1.3.1')
        Test-Path -LiteralPath (Join-Path $saved.ExtractPath 'tools' 'net8.0' 'any' 'readme.txt') | Should-BeTrue
        Test-Path -LiteralPath (Join-Path $saved.ExtractPath 'stale.txt') | Should-BeFalse
        $saved.Bytes | Should-BeGreaterThan 0
        Should-Invoke Invoke-NuGetRequest -ModuleName Rulebook.NuGet -Times 1 -Exactly -ParameterFilter { $Uri -like '*/alcops.analyzers/1.3.1/alcops.analyzers.1.3.1.nupkg' }
    }

    It 'throws on a 404 and leaves no file' {
        $path = Join-Path $TestDrive 'packages-404'
        Mock Invoke-NuGetRequest -ModuleName Rulebook.NuGet { [System.IO.File]::WriteAllText($OutFile, 'Not Found'); [pscustomobject]@{ StatusCode = 404; Content = '' } }
        { Save-NuGetPackage -PackageId 'alcops.analyzers' -Version '9.9.9' -Path $path } | Should-Throw -ExceptionMessage 'Could not download alcops.analyzers 9.9.9 (HTTP 404)'
        Test-Path -LiteralPath (Join-Path $path 'alcops.analyzers.9.9.9.nupkg') | Should-BeFalse
    }

    It 'refuses a version that is not a NuGet version before writing anything' {
        $path = Join-Path $TestDrive 'packages-evil'
        { Save-NuGetPackage -PackageId 'alcops.analyzers' -Version '../../evil' -Path $path } | Should-Throw -ExceptionMessage "'../../evil' is not a NuGet version*"
        Test-Path -LiteralPath $path | Should-BeFalse
    }

    It 'refuses a package with an entry outside its folder and writes nothing outside' {
        $feed = Join-Path $TestDrive 'slip-feed'
        $nupkg = Join-Path $feed 'alcops.analyzers' '1.4.0' 'alcops.analyzers.1.4.0.nupkg'
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $nupkg) -Force)
        $zip = [System.IO.Compression.ZipFile]::Open($nupkg, 'Create')
        try {
            $writer = [System.IO.StreamWriter]::new($zip.CreateEntry('../escape.txt').Open())
            try { $writer.Write('escaped') } finally { $writer.Dispose() }
        } finally {
            $zip.Dispose()
        }
        $path = Join-Path $TestDrive 'slip' 'packages'
        { Save-NuGetPackage -PackageId 'alcops.analyzers' -Version '1.4.0' -Path $path -Source $feed } | Should-Throw -ExceptionMessage 'alcops.analyzers 1.4.0 is not a readable package*'
        Test-Path -LiteralPath (Join-Path $path 'escape.txt') | Should-BeFalse
        Test-Path -LiteralPath (Join-Path $TestDrive 'slip' 'escape.txt') | Should-BeFalse
        Test-Path -LiteralPath (Join-Path $path 'alcops.analyzers.1.4.0') | Should-BeFalse
    }

    It 'copies from a folder source' {
        $feed = Join-Path $TestDrive 'folder-feed'
        New-ZipPackage -Path (Join-Path $feed 'alcops.analyzers' '1.4.0' 'alcops.analyzers.1.4.0.nupkg')
        $saved = Save-NuGetPackage -PackageId 'alcops.analyzers' -Version '1.4.0' -Path (Join-Path $TestDrive 'from-folder') -Source $feed
        Test-Path -LiteralPath (Join-Path $saved.ExtractPath 'tools' 'net8.0' 'any' 'readme.txt') | Should-BeTrue
    }
}

Describe 'Invoke-NuGetRequest retries' {
    It 'retries a 503 and a 429 and returns the first good answer' {
        $script:answers = [System.Collections.Generic.Queue[int]]::new([int[]]@(503, 429, 200))
        Mock Invoke-WebRequest -ModuleName Rulebook.NuGet { [pscustomobject]@{ StatusCode = $script:answers.Dequeue(); Content = '{ "versions": ["1.3.1"] }' } }
        (Get-NuGetVersionIndex -PackageId 'alcops.analyzers').Versions | Should-BeCollection @('1.3.1')
        Should-Invoke Invoke-WebRequest -ModuleName Rulebook.NuGet -Times 3 -Exactly
    }

    It 'retries a request without an answer' {
        $script:calls = 0
        Mock Invoke-WebRequest -ModuleName Rulebook.NuGet {
            $script:calls++
            if ($script:calls -eq 1) { throw [System.Net.Http.HttpRequestException]::new('timed out') }
            [pscustomobject]@{ StatusCode = 200; Content = '{ "versions": ["1.3.1"] }' }
        }
        (Get-NuGetVersionIndex -PackageId 'alcops.analyzers').Versions | Should-BeCollection @('1.3.1')
        Should-Invoke Invoke-WebRequest -ModuleName Rulebook.NuGet -Times 2 -Exactly
    }

    It 'does not retry a 404' {
        Mock Invoke-WebRequest -ModuleName Rulebook.NuGet { [pscustomobject]@{ StatusCode = 404; Content = '' } }
        { Get-NuGetVersionIndex -PackageId 'alcops.analyzers' } | Should-Throw -ExceptionMessage '*(HTTP 404)'
        Should-Invoke Invoke-WebRequest -ModuleName Rulebook.NuGet -Times 1 -Exactly
    }

    It 'gives up after four attempts' {
        Mock Invoke-WebRequest -ModuleName Rulebook.NuGet { [pscustomobject]@{ StatusCode = 502; Content = '' } }
        { Get-NuGetVersionIndex -PackageId 'alcops.analyzers' } | Should-Throw -ExceptionMessage '*(HTTP 502)'
        Should-Invoke Invoke-WebRequest -ModuleName Rulebook.NuGet -Times 4 -Exactly
    }
}
