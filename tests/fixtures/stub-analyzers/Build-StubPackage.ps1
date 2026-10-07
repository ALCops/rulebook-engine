#requires -Version 7.4
<#
.SYNOPSIS
Builds one stub analyzer package variant into a NuGet flat container folder for the Extract and Scan suites.
.DESCRIPTION
Compiles the C# stubs next to this script with the Roslyn compiler that ships with pwsh (the one Add-Type uses;
Add-Type -OutputAssembly gives the assembly a random name, and the cops must reference the compiler stub by its real
name Microsoft.Dynamics.Nav.CodeAnalysis): the compiler stub first, then every cop referencing it. Lays them out
like the real package (tools/<tfm>/any/ for the
Development.Tools package, lib/<tfm>/ for ALCops.Analyzers), writes a minimal nuspec, zips the result to
<OutputPath>/<id>/<version>/<id>.<version>.nupkg and adds the version to <OutputPath>/<id>/index.json.
A variant selects the package, the version and the sources; '#define STUB_<VARIANT>' is prepended to every source
so one file can carry the differences between versions. Run it in its own pwsh process (the suites do): the
compiled types must not be loaded into the test session. -ExtraTfm adds folders the resolver must never pick
(tools/net99.0/any/, lib/netstandard2.1/) holding text files named like the DLLs. Returns the nupkg path.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('tools-stable', 'tools-prerelease', 'alcops-v1', 'alcops-v2', 'alcops-v3')][string]$Variant,
    [Parameter(Mandatory)][string]$OutputPath,
    [string[]]$Tfm = @('net8.0', 'net10.0'),
    [switch]$ExtraTfm,
    # Versions added to index.json without a package (the alcops index lists 1.3.0-beta.1, never requested).
    [string[]]$IndexOnly = @(),
    # An assembly name whose DLL is written as a text file: the extraction must fail loudly on it.
    [string]$BreakAssembly
)
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$toolsId = 'microsoft.dynamics.businesscentral.development.tools'
$alcopsId = 'alcops.analyzers'
$learn = 'https://learn.microsoft.com/dynamics365/business-central/dev-itpro/developer/analyzers/'
# Assembly name -> a source file, or the parameters of OneIdCop.cs.
$toolsCops = [ordered]@{
    'Microsoft.Dynamics.Nav.CodeCop'               = 'CodeCop.cs'
    'Microsoft.Dynamics.Nav.UICop'                 = @{ Id = 'AW0006'; Severity = 'Warning'; Enabled = $true; Title = 'Use the Caption property'; Link = "$($learn)uicop-aw0006?wt.mc_id=stub" }
    'Microsoft.Dynamics.Nav.AppSourceCop'          = @{ Id = 'AS0001'; Severity = 'Error'; Enabled = $true; Title = 'Tables cannot be deleted'; Link = "$($learn)appsourcecop-as0001?wt.mc_id=stub" }
    'Microsoft.Dynamics.Nav.PerTenantExtensionCop' = @{ Id = 'PTE0001'; Severity = 'Error'; Enabled = $true; Title = 'Object ID must be in free range'; Link = "$($learn)pertenantextensioncop-pte0001?wt.mc_id=stub" }
}
$alcopsCops = [ordered]@{
    'ALCops.ApplicationCop'    = @{ Id = 'AC0001'; Severity = 'Info'; Enabled = $true; Title = 'Application rule'; Link = 'https://alcops.dev/docs/analyzers/applicationcop/ac0001/' }
    'ALCops.Common'            = 'Common.cs'
    'ALCops.DocumentationCop'  = @{ Id = 'DC0001'; Severity = 'Warning'; Enabled = $true; Title = 'Documentation rule'; Link = 'https://alcops.dev/docs/analyzers/documentationcop/dc0001/' }
    'ALCops.FormattingCop'     = @{ Id = 'FC0001'; Severity = 'Hidden'; Enabled = $true; Title = 'Formatting rule'; Link = 'https://alcops.dev/docs/analyzers/formattingcop/fc0001/' }
    'ALCops.LinterCop'         = 'LinterCop.cs'
    'ALCops.PlatformCop'       = @{ Id = 'PC0001'; Severity = 'Warning'; Enabled = $true; Title = 'Platform rule'; Link = 'https://alcops.dev/docs/analyzers/platformcop/pc0001/' }
    'ALCops.TestAutomationCop' = 'TestAutomationCop.cs'
}
$variants = @{
    'tools-stable'     = @{ Id = $toolsId; Version = '18.0.43.1464'; Layout = 'tools'; Cops = $toolsCops }
    'tools-prerelease' = @{ Id = $toolsId; Version = '30.0.42.60748-beta'; Layout = 'tools'; Cops = $toolsCops }
    'alcops-v1'        = @{ Id = $alcopsId; Version = '1.3.1'; Layout = 'lib'; Cops = $alcopsCops }
    'alcops-v2'        = @{ Id = $alcopsId; Version = '1.4.0-beta.1'; Layout = 'lib'; Cops = $alcopsCops }
    'alcops-v3'        = @{ Id = $alcopsId; Version = '1.4.0'; Layout = 'lib'; Cops = $alcopsCops }
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
    $roslyn = Join-Path $PSHOME 'Microsoft.CodeAnalysis.CSharp.dll'
    if (Test-Path -LiteralPath $roslyn -PathType Leaf) { Add-Type -Path $roslyn } else { Add-Type -AssemblyName Microsoft.CodeAnalysis.CSharp }
    $runtimeDir = [System.Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()
    $compile = {
        param($Source, [string]$AssemblyName, [string[]]$References)
        if ($Source -is [System.Collections.IDictionary]) {
            $link = if ($Source.Link) { '"' + $Source.Link + '"' } else { 'null' }
            $text = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'OneIdCop.cs')).Replace('__NAMESPACE__', $AssemblyName).Replace('__ID__', $Source.Id).Replace('__SEVERITY__', $Source.Severity).Replace('__ENABLED__', $Source.Enabled.ToString().ToLowerInvariant()).Replace('__TITLE__', $Source.Title).Replace('__LINK__', $link)
        } else {
            $text = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot $Source))
        }
        $out = Join-Path $bin "$AssemblyName.dll"
        $tree = [Microsoft.CodeAnalysis.CSharp.CSharpSyntaxTree]::ParseText($define + $text)
        $metadata = [System.Collections.Generic.List[Microsoft.CodeAnalysis.MetadataReference]]::new()
        foreach ($name in 'System.Private.CoreLib.dll', 'System.Runtime.dll', 'System.Collections.Immutable.dll', 'netstandard.dll') {
            $metadata.Add([Microsoft.CodeAnalysis.MetadataReference]::CreateFromFile((Join-Path $runtimeDir $name)))
        }
        foreach ($reference in $References) { $metadata.Add([Microsoft.CodeAnalysis.MetadataReference]::CreateFromFile($reference)) }
        $options = [Microsoft.CodeAnalysis.CSharp.CSharpCompilationOptions]::new([Microsoft.CodeAnalysis.OutputKind]::DynamicallyLinkedLibrary)
        $compilation = [Microsoft.CodeAnalysis.CSharp.CSharpCompilation]::Create($AssemblyName, [Microsoft.CodeAnalysis.SyntaxTree[]]@($tree), $metadata, $options)
        $stream = [System.IO.File]::Create($out)
        try { $emitted = $compilation.Emit($stream) } finally { $stream.Dispose() }
        if (-not $emitted.Success) { throw "$AssemblyName does not compile: $(@($emitted.Diagnostics | Where-Object { $_.Severity -eq 'Error' } | ForEach-Object { $_.ToString() }) -join '; ')" }
        return $out
    }
    # The ALCops package references the CodeAnalysis stub but does not ship it (the tools package hosts it).
    $codeAnalysis = & $compile 'CodeAnalysis.cs' 'Microsoft.Dynamics.Nav.CodeAnalysis' @()
    $built = [System.Collections.Generic.List[string]]::new()
    if ($spec.Layout -eq 'tools') { $built.Add($codeAnalysis) }
    foreach ($cop in $spec.Cops.GetEnumerator()) { $built.Add((& $compile $cop.Value $cop.Key @($codeAnalysis))) }
    if ($BreakAssembly) {
        $broken = Join-Path $bin "$BreakAssembly.dll"
        if (-not (Test-Path -LiteralPath $broken)) { throw "BreakAssembly $BreakAssembly is not part of $Variant" }
        [System.IO.File]::WriteAllText($broken, "not an assembly`n")
    }

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
    foreach ($v in @($versionLower) + @($IndexOnly | ForEach-Object { $_.ToLowerInvariant() })) { if ($v -notin $versions) { $versions.Add($v) } }
    $index = ConvertTo-Json -InputObject ([ordered]@{ versions = $versions.ToArray() }) -Depth 3
    [System.IO.File]::WriteAllText($indexPath, ($index -replace "`r`n", "`n") + "`n", [System.Text.UTF8Encoding]::new($false))
    return $nupkg
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
