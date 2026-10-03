#requires -Version 7.0
# Method 1: reflection in pwsh. Loads Microsoft.Dynamics.Nav.CodeAnalysis.dll from $ToolsDir, then each analyzer DLL,
# instantiates every non-abstract DiagnosticAnalyzer subclass and reads SupportedDiagnostics.
# Also reads the compiler's internal ErrorCode enum (configurable AL ids: WRN_/INF_/HDN_ members >= 100).
param(
    [Parameter(Mandatory)][string]$ToolsDir,     # tools/<tfm>/any of the Development.Tools package
    [string]$AlcopsDir,                          # lib/<tfm> of ALCops.Analyzers (optional)
    [Parameter(Mandatory)][string]$OutFile
)
$ErrorActionPreference = 'Stop'
$sw = [Diagnostics.Stopwatch]::StartNew()
Write-Host "pwsh $($PSVersionTable.PSVersion) on $([Runtime.InteropServices.RuntimeInformation]::FrameworkDescription)"
$searchDirs = @($AlcopsDir, $ToolsDir) | Where-Object { $_ }
[AppDomain]::CurrentDomain.add_AssemblyResolve({
    param($s, $e)
    $name = ([Reflection.AssemblyName]$e.Name).Name
    foreach ($d in $searchDirs) {
        $p = Join-Path $d "$name.dll"
        if (Test-Path $p) { return [Reflection.Assembly]::LoadFrom($p) }
    }
    return $null
})
$ca = [Reflection.Assembly]::LoadFrom((Join-Path $ToolsDir 'Microsoft.Dynamics.Nav.CodeAnalysis.dll'))
Write-Host "loaded $($ca.FullName) from $($ca.Location)"
$baseType = $ca.GetType('Microsoft.Dynamics.Nav.CodeAnalysis.Diagnostics.DiagnosticAnalyzer', $true)
$rows = [Collections.Generic.List[object]]::new()

# compiler ids
$ec = $ca.GetType('Microsoft.Dynamics.Nav.CodeAnalysis.ErrorCode', $true)
$rm = [Resources.ResourceManager]::new('Microsoft.Dynamics.Nav.CodeAnalysis.CompilerDiagnosticsResources', $ca)
foreach ($n in [Enum]::GetNames($ec)) {
    $v = [int][Enum]::Parse($ec, $n)
    if ($v -lt 100) { continue }
    $sev = switch -Regex ($n) { '^WRN_' { 'Warning' } '^INF_' { 'Info' } '^HDN_' { 'Hidden' } default { 'Error' } }
    if ($sev -eq 'Error') { continue }
    $key = if ($n -like 'WRN_ERR_*') { $n.Substring(4) } else { $n }
    $t = try { $rm.GetString($key) } catch { $null }
    $rows.Add([ordered]@{ id = ('AL{0:0000}' -f $v); assembly = 'Microsoft.Dynamics.Nav.CodeAnalysis'; analyzerType = 'ErrorCode.' + $n; defaultSeverity = $sev; enabledByDefault = $true; title = $t; helpLinkUri = $null; category = 'Compiler'; isDeprecated = $false })
}
Write-Host "compiler: $($rows.Count) configurable ids"

$dlls = @(Get-ChildItem $ToolsDir -Filter 'Microsoft.Dynamics.Nav.*Cop.dll')
if ($AlcopsDir) { $dlls += Get-ChildItem $AlcopsDir -Filter 'ALCops.*.dll' }
$fail = 0
$fieldIds = @{}
foreach ($dll in $dlls) {
    $asm = [Reflection.Assembly]::LoadFrom($dll.FullName)
    try { $types = $asm.GetTypes() }
    catch [Reflection.ReflectionTypeLoadException] {
        $types = $_.Exception.Types | Where-Object { $_ }
        Write-Host "::warning::$($dll.Name): ReflectionTypeLoadException, $(@($_.Exception.LoaderExceptions)[0].Message)"
    }
    $an = $types | Where-Object { $_.IsClass -and -not $_.IsAbstract -and $baseType.IsAssignableFrom($_) -and $_.GetConstructor([Type]::EmptyTypes) }
    $n0 = $rows.Count
    foreach ($t in $an) {
        try {
            $inst = [Activator]::CreateInstance($t)
            foreach ($d in $inst.SupportedDiagnostics) {
                $rows.Add([ordered]@{ id = $d.Id; assembly = $asm.GetName().Name; analyzerType = $t.FullName; defaultSeverity = $d.DefaultSeverity.ToString(); enabledByDefault = $d.IsEnabledByDefault; title = $d.Title.ToString(); helpLinkUri = $d.HelpLinkUri; category = $d.Category; isDeprecated = $d.IsDeprecated })
            }
        } catch { $fail++; Write-Host "::warning::$($t.FullName): $($_.Exception.GetBaseException().Message)" }
    }
    Write-Host ("{0}: {1} analyzer types, {2} descriptors" -f $dll.Name, @($an).Count, ($rows.Count - $n0))
    # secondary pass: static DiagnosticDescriptor fields/properties anywhere in the assembly (ids defined but never returned)
    $descType = $ca.GetType('Microsoft.Dynamics.Nav.CodeAnalysis.Diagnostics.DiagnosticDescriptor', $true)
    $bf = [Reflection.BindingFlags]'Static,Public,NonPublic'
    foreach ($t in $types) {
        if ($t.ContainsGenericParameters) { continue }
        foreach ($f in $t.GetFields($bf)) {
            if ($f.FieldType -ne $descType) { continue }
            try { $d = $f.GetValue($null) } catch { continue }
            if ($d -and -not $fieldIds.ContainsKey($d.Id)) { $fieldIds[$d.Id] = [ordered]@{ id = $d.Id; assembly = $asm.GetName().Name; field = "$($t.FullName).$($f.Name)"; defaultSeverity = $d.DefaultSeverity.ToString(); enabledByDefault = $d.IsEnabledByDefault } }
        }
    }
}
$returned = [Collections.Generic.HashSet[string]]::new([string[]]@($rows | ForEach-Object { $_.id }))
$fieldOnly = @($fieldIds.Values | Where-Object { -not $returned.Contains($_.id) } | Sort-Object { $_.id })
Write-Host "static descriptor fields: $($fieldIds.Count) ids; defined but not returned by any analyzer: $($fieldOnly.Count)"
$fieldOnly | ForEach-Object { Write-Host "  field-only $($_.id) $($_.defaultSeverity)/$($_.enabledByDefault) $($_.field)" }
# dedupe by id, flag disagreeing duplicates
$out = foreach ($g in ($rows | Group-Object { $_.id })) {
    $first = $g.Group[0]
    $variants = @($g.Group | ForEach-Object { "$($_.defaultSeverity)/$($_.enabledByDefault)" } | Sort-Object -Unique)
    if ($variants.Count -gt 1) { Write-Host "::warning::$($g.Name) descriptors disagree: $($variants -join ', ')" }
    $first['descriptorCount'] = $g.Count
    [pscustomobject]$first
}
$out = $out | Sort-Object id
$out | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $OutFile -Encoding utf8NoBOM
Write-Host ("unique ids: {0}; instantiation failures: {1}; elapsed {2:n1} s" -f @($out).Count, $fail, $sw.Elapsed.TotalSeconds)
