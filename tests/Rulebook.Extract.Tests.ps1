# Extract suite for WP08 (#10): the stub analyzer packages of tests/fixtures/stub-analyzers/ and the descriptor
# extraction of Rulebook.Extract (docs/reference/scan-mechanics.md). Offline: the real packages run only in CI job
# scan-action.

BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:stubRoot = Join-Path $PSScriptRoot 'fixtures' 'stub-analyzers'
    # The process path is dotnet when pwsh runs as a .NET global tool (the WSL check); prefer the pwsh in $PSHOME.
    $script:pwsh = @((Join-Path $PSHOME 'pwsh.exe'), (Join-Path $PSHOME 'pwsh')) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if (-not $pwsh) { $script:pwsh = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source }
    $script:feed = Join-Path $TestDrive 'feed'
    $build = & $pwsh -NoProfile -NonInteractive -File (Join-Path $stubRoot 'Build-StubPackage.ps1') -Variant tools-stable -OutputPath $feed 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Build-StubPackage failed: $($build -join "`n")" }
}

Describe 'stub packages' {
    It 'writes a flat container with the index and the nupkg' {
        $id = 'microsoft.dynamics.businesscentral.development.tools'
        (Get-Content -Raw (Join-Path $feed $id 'index.json') | ConvertFrom-Json).versions | Should-BeCollection @('18.0.43.1464')
        Test-Path -LiteralPath (Join-Path $feed $id '18.0.43.1464' "$id.18.0.43.1464.nupkg") | Should-BeTrue
    }

    It 'loads in a child pwsh and advertises the stub descriptors' {
        $id = 'microsoft.dynamics.businesscentral.development.tools'
        $extract = Join-Path $TestDrive 'extract'
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory((Join-Path $feed $id '18.0.43.1464' "$id.18.0.43.1464.nupkg"), $extract)
        $dir = Join-Path $extract 'tools' 'net8.0' 'any'
        $probe = {
            param($dir)
            $ErrorActionPreference = 'Stop'
            # A handler built with GetNewClosure and calling Join-Path/Test-Path overflowed the stack; keep it to .NET calls.
            $script:StubDir = $dir
            [AppDomain]::CurrentDomain.add_AssemblyResolve({
                    $p = [System.IO.Path]::Combine($script:StubDir, ([Reflection.AssemblyName]$args[1].Name).Name + '.dll')
                    if ([System.IO.File]::Exists($p)) { return [Reflection.Assembly]::LoadFrom($p) }
                    return $null
                })
            $ca = [Reflection.Assembly]::LoadFrom((Join-Path $dir 'Microsoft.Dynamics.Nav.CodeAnalysis.dll'))
            $base = $ca.GetType('Microsoft.Dynamics.Nav.CodeAnalysis.Diagnostics.DiagnosticAnalyzer', $true)
            $codes = [Enum]::GetNames($ca.GetType('Microsoft.Dynamics.Nav.CodeAnalysis.ErrorCode', $true))
            $cop = [Reflection.Assembly]::LoadFrom((Join-Path $dir 'Microsoft.Dynamics.Nav.CodeCop.dll'))
            $rows = foreach ($t in $cop.GetTypes()) {
                if (-not $t.IsClass -or $t.IsAbstract -or -not $base.IsAssignableFrom($t) -or -not $t.GetConstructor([Type]::EmptyTypes)) { continue }
                foreach ($d in ([Activator]::CreateInstance($t)).SupportedDiagnostics) { '{0}:{1}:{2}:{3}' -f $d.Id, $d.DefaultSeverity, $d.IsEnabledByDefault, $d.IsDeprecated }
            }
            [pscustomobject]@{ Codes = $codes; Rows = @($rows | Sort-Object) } | ConvertTo-Json -Compress
        }
        $command = "& { $probe } '$($dir -replace "'", "''")'"
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        $output = & $pwsh -NoProfile -NonInteractive -EncodedCommand $encoded 2>&1
        $LASTEXITCODE | Should-Be 0 -Because ($output -join "`n")
        $result = ($output | Select-Object -Last 1) | ConvertFrom-Json
        $result.Codes | Should-ContainCollection @('WRN_StubWarning', 'INF_StubInfo', 'HDN_StubHidden')
        $result.Rows | Should-BeCollection @('AA0001:Warning:True:False', 'AA0001:Warning:True:False', 'AA0003:Warning:True:True')
    }
}
