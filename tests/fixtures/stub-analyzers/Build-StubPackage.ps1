#requires -Version 7.4
<#
.SYNOPSIS
Builds one stub analyzer package variant into a NuGet flat container folder for the Extract and Scan suites.
.DESCRIPTION
Compiles the C# stubs next to this script with Add-Type -OutputAssembly (Microsoft.Dynamics.Nav.CodeAnalysis.dll
first, then every cop referencing it), lays them out like the real package (tools/<tfm>/any/ for the
Development.Tools package, lib/<tfm>/ for ALCops.Analyzers), writes a minimal nuspec, zips the result to
<OutputPath>/<id>/<version>/<id>.<version>.nupkg and adds the version to <OutputPath>/<id>/index.json.
A variant selects the package, the version and the sources; '#define STUB_<VARIANT>' is prepended to every source
so one file can carry the differences between versions. Run it in its own pwsh process (the suites do): the
compiled types must not be loaded into the test session. -ExtraTfm adds folders the resolver must never pick
(tools/net99.0/any/, lib/netstandard2.1/) holding text files named like the DLLs. Returns the nupkg path.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('tools-stable', 'tools-prerelease')][string]$Variant,
    [Parameter(Mandatory)][string]$OutputPath,
    [string[]]$Tfm = @('net8.0', 'net10.0'),
    [switch]$ExtraTfm
)
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$toolsId = 'microsoft.dynamics.businesscentral.development.tools'
$toolsCops = [ordered]@{ 'Microsoft.Dynamics.Nav.CodeCop' = 'CodeCop.cs' }
$variants = @{
    'tools-stable'     = @{ Id = $toolsId; Version = '18.0.43.1464'; Layout = 'tools'; WithCodeAnalysis = $true; Cops = $toolsCops }
    'tools-prerelease' = @{ Id = $toolsId; Version = '30.0.42.60748-beta'; Layout = 'tools'; WithCodeAnalysis = $true; Cops = $toolsCops }
}
$spec = $variants[$Variant]
$define = "#define STUB_$(($Variant -replace '[^A-Za-z0-9]', '_').ToUpperInvariant())`n"

# [System.IO] resolves relative paths against the process directory, not the PowerShell location.
$OutputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
$work = Join-Path ([System.IO.Path]::GetTempPath()) ('stub-' + [guid]::NewGuid().ToString('n'))
$bin = Join-Path $work 'bin'
$pkg = Join-Path $work 'pkg'
[void](New-Item -ItemType Directory -Path $bin, $pkg -Force)
try {
    $compile = {
        param([string]$Source, [string]$AssemblyName, [string[]]$References)
        $text = $define + [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot $Source))
        $out = Join-Path $bin "$AssemblyName.dll"
        Add-Type -TypeDefinition $text -OutputAssembly $out -OutputType Library -ReferencedAssemblies (@('System.Runtime', 'System.Collections.Immutable') + $References)
        return $out
    }
    # The ALCops variants reference the CodeAnalysis stub but do not ship it (the tools package hosts it).
    $codeAnalysis = & $compile 'CodeAnalysis.cs' 'Microsoft.Dynamics.Nav.CodeAnalysis' @()
    $built = [System.Collections.Generic.List[string]]::new()
    if ($spec.WithCodeAnalysis) { $built.Add($codeAnalysis) }
    foreach ($cop in $spec.Cops.GetEnumerator()) { $built.Add((& $compile $cop.Value $cop.Key @($codeAnalysis))) }

    $folderOf = { param([string]$Framework) if ($spec.Layout -eq 'tools') { Join-Path $pkg 'tools' $Framework 'any' } else { Join-Path $pkg 'lib' $Framework } }
    foreach ($framework in $Tfm) {
        $folder = & $folderOf $framework
        [void](New-Item -ItemType Directory -Path $folder -Force)
        foreach ($dll in $built) { Copy-Item -LiteralPath $dll -Destination $folder }
    }
    if ($ExtraTfm) {
        foreach ($framework in 'net99.0', 'netstandard2.1') {
            $folder = & $folderOf $framework
            [void](New-Item -ItemType Directory -Path $folder -Force)
            foreach ($dll in $built) { [System.IO.File]::WriteAllText((Join-Path $folder (Split-Path -Leaf $dll)), "not an assembly`n") }
        }
    }
    $nuspec = @"
<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://schemas.microsoft.com/packaging/2013/05/nuspec.xsd">
  <metadata>
    <id>$($spec.Id)</id>
    <version>$($spec.Version)</version>
    <authors>ALCops test stub</authors>
    <description>Stub package built by tests/fixtures/stub-analyzers/Build-StubPackage.ps1 ($Variant).</description>
  </metadata>
</package>
"@
    [System.IO.File]::WriteAllText((Join-Path $pkg "$($spec.Id).nuspec"), ($nuspec -replace "`r`n", "`n"), [System.Text.UTF8Encoding]::new($false))

    $versionLower = $spec.Version.ToLowerInvariant()
    $packageDir = Join-Path $OutputPath $spec.Id $versionLower
    [void](New-Item -ItemType Directory -Path $packageDir -Force)
    $nupkg = Join-Path $packageDir "$($spec.Id).$versionLower.nupkg"
    if (Test-Path -LiteralPath $nupkg) { Remove-Item -LiteralPath $nupkg -Force }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::CreateFromDirectory($pkg, $nupkg)

    $indexPath = Join-Path $OutputPath $spec.Id 'index.json'
    $versions = [System.Collections.Generic.List[string]]::new()
    if (Test-Path -LiteralPath $indexPath) {
        foreach ($v in (Get-Content -Raw -LiteralPath $indexPath | ConvertFrom-Json).versions) { $versions.Add([string]$v) }
    }
    if ($versionLower -notin $versions) { $versions.Add($versionLower) }
    $index = ConvertTo-Json -InputObject ([ordered]@{ versions = $versions.ToArray() }) -Depth 3
    [System.IO.File]::WriteAllText($indexPath, ($index -replace "`r`n", "`n") + "`n", [System.Text.UTF8Encoding]::new($false))
    return $nupkg
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
