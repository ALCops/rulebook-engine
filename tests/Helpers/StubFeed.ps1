# Helpers for the suites that need the stub analyzer packages of tests/fixtures/stub-analyzers/. Dot-source in
# BeforeAll. New-StubFeed builds a NuGet flat container with the requested variants; each variant is compiled once per
# machine and stub-source hash into a cache under the temp folder (Build-StubPackage.ps1 in its own pwsh process), so
# the Extract, Scan and action suites share one build.

$script:StubRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'fixtures' 'stub-analyzers'
$script:StubPackageIds = @{
    'tools-stable'     = @('microsoft.dynamics.businesscentral.development.tools', '18.0.43.1464')
    'tools-prerelease' = @('microsoft.dynamics.businesscentral.development.tools', '30.0.42.60748-beta')
    'alcops-v1'        = @('alcops.analyzers', '1.3.1')
    'alcops-v2'        = @('alcops.analyzers', '1.4.0-beta.1')
    'alcops-v3'        = @('alcops.analyzers', '1.4.0')
}

function Get-TestPwshPath {
    # The pwsh of this session from $PSHOME (the process path is dotnet under a .NET global tool install).
    foreach ($name in 'pwsh.exe', 'pwsh') {
        $candidate = Join-Path $PSHOME $name
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
}

function Get-StubCacheRoot {
    # The cache folder for the current stub sources and runtime.
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $stream = [System.IO.MemoryStream]::new()
        foreach ($file in Get-ChildItem -LiteralPath $script:StubRoot -File | Sort-Object Name) {
            $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
            $stream.Write($bytes, 0, $bytes.Length)
        }
        $runtime = [System.Text.Encoding]::UTF8.GetBytes([System.Environment]::Version.ToString())
        $stream.Write($runtime, 0, $runtime.Length)
        $hash = [System.Convert]::ToHexString($sha.ComputeHash($stream.ToArray())).Substring(0, 16).ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
    return Join-Path ([System.IO.Path]::GetTempPath()) 'rulebook-stub-feeds' $hash
}

function Get-StubVariant {
    # The cached flat container holding one variant (built on first use); returns its folder.
    param([Parameter(Mandatory)][string]$Variant)
    $folder = Join-Path (Get-StubCacheRoot) $Variant
    if (Test-Path -LiteralPath (Join-Path $folder 'done.txt') -PathType Leaf) { return $folder }
    $staging = "$folder.$([guid]::NewGuid().ToString('n').Substring(0, 8))"
    $output = & (Get-TestPwshPath) -NoProfile -NonInteractive -File (Join-Path $script:StubRoot 'Build-StubPackage.ps1') -Variant $Variant -OutputPath $staging 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Build-StubPackage.ps1 -Variant $Variant failed: $($output -join "`n")" }
    [System.IO.File]::WriteAllText((Join-Path $staging 'done.txt'), 'ok')
    if (Test-Path -LiteralPath $folder) { Remove-Item -LiteralPath $staging -Recurse -Force } else { Move-Item -LiteralPath $staging -Destination $folder }
    return $folder
}

function New-StubFeed {
    # A flat container at Destination with the packages of Variants and an index.json per package that lists them
    # (plus IndexOnly versions without a package). Returns the destination path.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helper; writes only to TestDrive')]
    param([Parameter(Mandatory)][string[]]$Variants, [Parameter(Mandatory)][string]$Destination, [hashtable]$IndexOnly = @{})
    $versions = @{}
    foreach ($variant in $Variants) {
        $source = Get-StubVariant -Variant $variant
        $id, $version = $script:StubPackageIds[$variant]
        $target = Join-Path $Destination $id $version
        [void](New-Item -ItemType Directory -Path $target -Force)
        Copy-Item -Path (Join-Path $source $id $version '*') -Destination $target -Force
        if (-not $versions.ContainsKey($id)) { $versions[$id] = [System.Collections.Generic.List[string]]::new() }
        $versions[$id].Add($version)
    }
    foreach ($id in $IndexOnly.Keys) {
        if (-not $versions.ContainsKey($id)) { $versions[$id] = [System.Collections.Generic.List[string]]::new() }
        foreach ($version in @($IndexOnly[$id])) { $versions[$id].Add($version) }
    }
    foreach ($id in $versions.Keys) {
        $folder = Join-Path $Destination $id
        [void](New-Item -ItemType Directory -Path $folder -Force)
        $json = ConvertTo-Json -InputObject ([ordered]@{ versions = $versions[$id].ToArray() }) -Depth 3
        [System.IO.File]::WriteAllText((Join-Path $folder 'index.json'), $json, [System.Text.UTF8Encoding]::new($false))
    }
    return (Resolve-Path -LiteralPath $Destination).ProviderPath
}

function Expand-StubPackage {
    # The extracted folder of one variant's nupkg under Destination; returns { Root, ToolsDir or AlcopsDir }.
    param([Parameter(Mandatory)][string]$Variant, [Parameter(Mandatory)][string]$Destination)
    $source = Get-StubVariant -Variant $Variant
    $id, $version = $script:StubPackageIds[$Variant]
    $root = Join-Path $Destination "$id.$version"
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    [System.IO.Compression.ZipFile]::ExtractToDirectory((Join-Path $source $id $version "$id.$version.nupkg"), $root)
    return $root
}
