#requires -Version 7.0
<#
.SYNOPSIS
  Extracts every diagnostic id of the AL compiler, the four Microsoft cops and the seven ALCops cops
  into docs/rulebook/inventory/<PREFIX>.md and a machine-readable docs/rulebook/inventory/inventory.json.
.DESCRIPTION
  Sources (sibling repos of rulebook-engine):
    ../nav-sdk-source   decompiled Microsoft.Dynamics.BusinessCentral.Development.Tools
    ../Analyzers        ALCops analyzers
  This script is the refresh procedure described in docs/rulebook/versions.md. It only reads the sources.
  Hand-maintained columns (Family, Config, extra Flags) are merged from docs/rulebook/inventory/annotations.json
  so a refresh never loses a judgment.
#>
[CmdletBinding()]
param(
    [string]$SdkRoot = (Join-Path $PSScriptRoot '..\..\..\nav-sdk-source'),
    [string]$AnalyzersRoot = (Join-Path $PSScriptRoot '..\..\..\Analyzers'),
    [string]$OutDir = (Join-Path $PSScriptRoot '..\..\docs\rulebook\inventory'),
    [string]$StableTag = 'v18.0.41.62505'
)
$ErrorActionPreference = 'Stop'
$SdkRoot = (Resolve-Path $SdkRoot).Path
$AnalyzersRoot = (Resolve-Path $AnalyzersRoot).Path
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

function Read-Resx([string]$path) {
    $xml = [xml](Get-Content -Raw -LiteralPath $path)
    $map = @{}
    foreach ($d in $xml.root.data) { $map[[string]$d.name] = [string]$d.value }
    return $map
}
function Clean([string]$s) {
    if ($null -eq $s) { return '' }
    return ($s -replace '\s+', ' ' -replace '\|', '\|').Trim()
}
function Get-GitFile([string]$repo, [string]$ref, [string]$relPath) {
    $p = $relPath -replace '\\', '/'
    $out = & git -C $repo show "${ref}:${p}" 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    return ($out -join "`n")
}

$rows = [System.Collections.Generic.List[object]]::new()

# ---------- 1. AL compiler ----------
$caDir = Join-Path $SdkRoot 'Microsoft.Dynamics.Nav.CodeAnalysis\net10.0'
$errorCodeCs = Get-Content -Raw (Join-Path $caDir 'Microsoft.Dynamics.Nav.CodeAnalysis\ErrorCode.cs')
$errorFactsCs = Get-Content -Raw (Join-Path $caDir 'Microsoft.Dynamics.Nav.CodeAnalysis\ErrorFacts.cs')
$compilerResx = Read-Resx (Join-Path $caDir 'Microsoft.Dynamics.Nav.CodeAnalysis.CompilerDiagnosticsResources.resx')

$futureErrorBlock = [regex]::Match($errorFactsCs, 'IsWarningFutureError\(ErrorCode code\)\s*\{\s*switch \(code\)\s*\{(.*?)\}\s*\}', 'Singleline').Groups[1].Value
$futureErrors = [regex]::Matches($futureErrorBlock, 'ErrorCode\.(WRN_ERR_\w+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique

$stableErrorCodeCs = Get-GitFile $SdkRoot $StableTag 'Microsoft.Dynamics.Nav.CodeAnalysis/net10.0/Microsoft.Dynamics.Nav.CodeAnalysis/ErrorCode.cs'
if (-not $stableErrorCodeCs) { $stableErrorCodeCs = Get-GitFile $SdkRoot $StableTag 'Microsoft.Dynamics.Nav.CodeAnalysis/net8.0/Microsoft.Dynamics.Nav.CodeAnalysis/ErrorCode.cs' }
$stableAlNumbers = @{}
if ($stableErrorCodeCs) {
    foreach ($m in [regex]::Matches($stableErrorCodeCs, '^\s*(\w+)\s*=\s*(\d+),?', 'Multiline')) { $stableAlNumbers[[int]$m.Groups[2].Value] = $true }
}

$alErrorCount = 0
foreach ($m in [regex]::Matches($errorCodeCs, '^\s*(\w+)\s*=\s*(-?\d+),?', 'Multiline')) {
    $name = $m.Groups[1].Value; $num = [int]$m.Groups[2].Value
    if ($num -lt 100) { continue }
    $sev = switch -Regex ($name) { '^WRN_' { 'Warning' } '^INF_' { 'Info' } '^HDN_' { 'Hidden' } default { 'Error' } }
    if ($sev -eq 'Error') { $alErrorCount++; continue }
    $msgKey = $name
    if ($name -like 'WRN_ERR_*') { $msgKey = $name.Substring(4) }
    $msg = $compilerResx[$msgKey]
    if (-not $msg -and $name -like 'WRN_PERS_*') { $msg = $compilerResx['ERR_' + $name.Substring(9)]; if (-not $msg) { $msg = $compilerResx['WRN_' + $name.Substring(9)] } }
    $flags = @()
    if ($futureErrors -contains $name) { $flags += 'future-error' }
    if ($name -like 'WRN_PERS_*' -or $name -like 'INF_PERS_*') { $flags += 'pers' }
    if ($name -eq 'HDN_UnusedUsing') { $flags += 'unnecessary' }
    $since = if ($stableErrorCodeCs) { if ($stableAlNumbers.ContainsKey($num)) { 'stable' } else { 'prerelease' } } else { 'unknown' }
    $rows.Add([ordered]@{
        id = 'AL{0:0000}' -f $num; prefix = 'AL'; analyzer = 'Compiler'; symbol = $name; title = Clean $msg
        category = 'Compiler'; default = $sev; enabled = $true; flags = $flags; since = $since
        docs = "https://learn.microsoft.com/dynamics365/business-central/dev-itpro/developer/diagnostics/diagnostic-al$num"
    })
}

# ---------- 2. Microsoft cops ----------
$msCops = @(
    @{ prefix = 'AA';  analyzer = 'CodeCop';               dir = 'Microsoft.Dynamics.Nav.CodeCop';               resx = 'Microsoft.Dynamics.Nav.CodeCop.CodeCopAnalyzers.resx' }
    @{ prefix = 'AW';  analyzer = 'UICop';                 dir = 'Microsoft.Dynamics.Nav.UICop';                 resx = 'Microsoft.Dynamics.Nav.UICop.UICopAnalyzers.resx' }
    @{ prefix = 'PTE'; analyzer = 'PerTenantExtensionCop'; dir = 'Microsoft.Dynamics.Nav.PerTenantExtensionCop'; resx = 'Microsoft.Dynamics.Nav.PerTenantExtensionCop.PerTenantExtensionAnalyzers.resx' }
    @{ prefix = 'AS';  analyzer = 'AppSourceCop';          dir = 'Microsoft.Dynamics.Nav.AppSourceCop';          resx = 'Microsoft.Dynamics.Nav.AppSourceCop.AppSourceCopAnalyzers.resx' }
)
$msDescRegex = 'DiagnosticDescriptor\s+(?<sym>\w+)\s*=\s*new DiagnosticDescriptor\(\w+\.AnalyzerPrefix \+ "(?<num>\d{4})",\s*new LocalizableResourceString\("(?<titleKey>\w+)".*?,\s*"(?<cat>\w+)",\s*DiagnosticSeverity\.(?<sev>\w+),\s*(?<enabled>true|false),.*?"(?<help>https://[^"]+)",\s*(?<unnecessary>true|false),\s*(?<deprecated>true|false)\)'
foreach ($cop in $msCops) {
    $descRel = "$($cop.dir)/net10.0/$($cop.dir)/DiagnosticDescriptors.cs"
    $descCs = Get-Content -Raw (Join-Path $SdkRoot $descRel)
    $resx = Read-Resx (Join-Path $SdkRoot "$($cop.dir)/net10.0/$($cop.resx)")
    $stableCs = Get-GitFile $SdkRoot $StableTag $descRel
    if (-not $stableCs) { $stableCs = Get-GitFile $SdkRoot $StableTag ($descRel -replace 'net10.0', 'net8.0') }
    $stableIds = @{}
    if ($stableCs) { foreach ($m in [regex]::Matches($stableCs, 'AnalyzerPrefix \+ "(\d{4})"')) { $stableIds[$m.Groups[1].Value] = $true } }
    foreach ($m in [regex]::Matches($descCs, $msDescRegex, 'Singleline')) {
        $num = $m.Groups['num'].Value
        $flags = @()
        if ($m.Groups['unnecessary'].Value -eq 'true') { $flags += 'unnecessary' }
        if ($m.Groups['deprecated'].Value -eq 'true') { $flags += 'deprecated' }
        $since = if ($stableCs) { if ($stableIds.ContainsKey($num)) { 'stable' } else { 'prerelease' } } else { 'unknown' }
        $rows.Add([ordered]@{
            id = $cop.prefix + $num; prefix = $cop.prefix; analyzer = $cop.analyzer; symbol = $m.Groups['sym'].Value
            title = Clean $resx[$m.Groups['titleKey'].Value]; category = $m.Groups['cat'].Value
            default = $m.Groups['sev'].Value; enabled = ($m.Groups['enabled'].Value -eq 'true'); flags = $flags; since = $since
            docs = ($m.Groups['help'].Value -replace '\?wt\.mc_id=.*$', '')
        })
    }
}

# ---------- 3. ALCops ----------
$alcops = @(
    @{ prefix = 'PC'; analyzer = 'PlatformCop';       proj = 'ALCops.PlatformCop';       resx = 'ALCops.PlatformCopAnalyzers.resx' }
    @{ prefix = 'AC'; analyzer = 'ApplicationCop';    proj = 'ALCops.ApplicationCop';    resx = 'ALCops.ApplicationCopAnalyzers.resx' }
    @{ prefix = 'LC'; analyzer = 'LinterCop';         proj = 'ALCops.LinterCop';         resx = 'ALCops.LinterCopAnalyzers.resx' }
    @{ prefix = 'DC'; analyzer = 'DocumentationCop';  proj = 'ALCops.DocumentationCop';  resx = 'ALCops.DocumentationCopAnalyzers.resx' }
    @{ prefix = 'FC'; analyzer = 'FormattingCop';     proj = 'ALCops.FormattingCop';     resx = 'ALCops.FormattingCopAnalyzers.resx' }
    @{ prefix = 'TA'; analyzer = 'TestAutomationCop'; proj = 'ALCops.TestAutomationCop'; resx = 'ALCops.TestAutomationCopAnalyzers.resx' }
    @{ prefix = 'CM'; analyzer = 'Common';            proj = 'ALCops.Common';            resx = 'ALCops.CommonAnalyzers.resx' }
)
foreach ($cop in $alcops) {
    $projDir = Join-Path $AnalyzersRoot "src\$($cop.proj)"
    $idsCs = Get-Content -Raw (Join-Path $projDir 'DiagnosticIds.cs')
    $descCs = Get-Content -Raw (Join-Path $projDir 'DiagnosticDescriptors.cs')
    $resx = Read-Resx (Join-Path $projDir $cop.resx)
    $idMap = @{}
    foreach ($m in [regex]::Matches($idsCs, 'string\s+(\w+)\s*=\s*"([A-Z]+\d{4}i?)"')) { $idMap[$m.Groups[1].Value] = $m.Groups[2].Value }
    $helpUri = [regex]::Match($descCs, 'string\.Format\(CultureInfo\.InvariantCulture,\s*"([^"]+)"').Groups[1].Value
    $seen = @{}
    foreach ($m in [regex]::Matches($descCs, 'DiagnosticDescriptor\s+(?<sym>\w+)\s*=\s*new\((?<body>.*?)\);', 'Singleline')) {
        $body = $m.Groups['body'].Value
        $idName = [regex]::Match($body, 'id:\s*DiagnosticIds\.(\w+)').Groups[1].Value
        $id = $idMap[$idName]
        if (-not $id) { throw "No id for $($cop.proj).$idName" }
        $titleKey = [regex]::Match($body, 'title:\s*\w+\.(\w+)').Groups[1].Value
        $cat = [regex]::Match($body, 'category:\s*Category\.(\w+)').Groups[1].Value
        $sev = [regex]::Match($body, 'defaultSeverity:\s*DiagnosticSeverity\.(\w+)').Groups[1].Value
        $enabled = [regex]::Match($body, 'isEnabledByDefault:\s*(true|false)').Groups[1].Value -eq 'true'
        $customTags = [regex]::Match($body, 'customTags:\s*(.*)$', 'Singleline').Groups[1].Value
        $flags = @()
        if ($customTags -match 'Unnecessary') { $flags += 'unnecessary' }
        if ($seen.ContainsKey($id)) {
            # second descriptor sharing the id (AC0032, LC0003): keep the first, record the alias
            $existing = $rows | Where-Object { $_.id -eq $id } | Select-Object -First 1
            $existing.symbol = "$($existing.symbol);$($m.Groups['sym'].Value)"
            if ($existing.default -ne $sev -or $existing.enabled -ne $enabled) { throw "Descriptor pair for $id disagrees on severity or enablement" }
            continue
        }
        $seen[$id] = $true
        $docs = if ($helpUri) { $helpUri -replace '\{0\}', $id.ToLowerInvariant() } else { '' }
        $rows.Add([ordered]@{
            id = $id; prefix = $cop.prefix; analyzer = $cop.analyzer; symbol = $m.Groups['sym'].Value
            title = Clean $resx[$titleKey]; category = $cat; default = $sev; enabled = $enabled; flags = $flags; since = 'stable'
            docs = $docs
        })
    }
}

# ---------- 4. merge annotations, sort, write ----------
$annPath = Join-Path $OutDir 'annotations.json'
$ann = @{}
if (Test-Path $annPath) { (Get-Content -Raw $annPath | ConvertFrom-Json -AsHashtable).GetEnumerator() | ForEach-Object { $ann[$_.Key] = $_.Value } }
$prefixOrder = @('AL','AA','AW','PTE','AS','PC','AC','LC','DC','FC','TA','CM')
function Get-SortKey($r) {
    $p = [array]::IndexOf($prefixOrder, $r.prefix)
    $n = [int]($r.id -replace '^[A-Z]+', '' -replace 'i$', '')
    $suffix = if ($r.id.EndsWith('i')) { 1 } else { 0 }
    return ('{0:00}{1:0000}{2}' -f $p, $n, $suffix)
}
$sorted = @($rows | Sort-Object { Get-SortKey $_ })
foreach ($r in $sorted) {
    $a = $ann[$r.id]
    $r['family'] = if ($a -and $a.family) { $a.family } else { 'general' }
    $r['config'] = if ($a -and $a.config) { $a.config } else { '-' }
    $extra = if ($a -and $a.flags) { @($a.flags) } else { @() }
    $r['flags'] = @(@($r.flags) + $extra | Sort-Object -Unique)
}
$sorted | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $OutDir 'inventory.json') -Encoding utf8NoBOM

$sourceNote = @{
    AL = "``Microsoft.Dynamics.Nav.CodeAnalysis\net10.0\Microsoft.Dynamics.Nav.CodeAnalysis\ErrorCode.cs`` (enum; prefix ``WRN_``/``INF_``/``HDN_`` means Warning/Info/Hidden, everything else Error), ``ErrorFacts.cs`` (``IsWarningFutureError``), ``Microsoft.Dynamics.Nav.CodeAnalysis.CompilerDiagnosticsResources.resx`` (message format keyed by enum member; the compiler has no titles, so the Title column holds the message format). The $alErrorCount Error codes are ``NotConfigurable`` and are not listed."
}
foreach ($cop in $msCops) { $sourceNote[$cop.prefix] = "``$($cop.dir)\net10.0\$($cop.dir)\DiagnosticDescriptors.cs`` (id, category, severity, enabled, help link, isUnnecessary, isDeprecated) and ``$($cop.dir)\net10.0\$($cop.resx)`` (title)." }
foreach ($cop in $alcops) { $sourceNote[$cop.prefix] = "``src\$($cop.proj)\DiagnosticIds.cs``, ``src\$($cop.proj)\DiagnosticDescriptors.cs`` (category, severity, enabled) and ``src\$($cop.proj)\$($cop.resx)`` (title)." }
$repoOf = @{ AL = 'nav-sdk-source'; AA = 'nav-sdk-source'; AW = 'nav-sdk-source'; PTE = 'nav-sdk-source'; AS = 'nav-sdk-source'; PC = 'Analyzers'; AC = 'Analyzers'; LC = 'Analyzers'; DC = 'Analyzers'; FC = 'Analyzers'; TA = 'Analyzers'; CM = 'Analyzers' }

foreach ($p in $prefixOrder) {
    $set = @($sorted | Where-Object prefix -eq $p)
    $analyzer = $set[0].analyzer
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("# Inventory: $analyzer ($p)")
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("Generated by ``tools/rulebook/Extract-Inventory.ps1`` from repo ``$($repoOf[$p])``: $($sourceNote[$p]) Columns are defined in [00-conventions.md](../00-conventions.md). ``Family``, ``Config`` and hand-added ``Flags`` come from ``annotations.json``.")
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('| ID | Symbol | Title | Category | Default | Enabled | Family | Config | Flags | Since | Docs |')
    [void]$sb.AppendLine('|---|---|---|---|---|---|---|---|---|---|---|')
    foreach ($r in $set) {
        $flags = if ($r.flags.Count) { ($r.flags -join ';') } else { '-' }
        $title = if ($r.title) { $r.title } else { '-' }
        $docs = if ($r.docs) { $r.docs } else { '-' }
        [void]$sb.AppendLine("| $($r.id) | $($r.symbol) | $title | $($r.category) | $($r.default) | $($r.enabled.ToString().ToLower()) | $($r.family) | $($r.config) | $flags | $($r.since) | $docs |")
    }
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("Count: $($set.Count)")
    Set-Content -LiteralPath (Join-Path $OutDir "$p.md") -Value $sb.ToString() -Encoding utf8NoBOM -NoNewline
}
$summary = $sorted | Group-Object { $_.prefix } | ForEach-Object { [pscustomobject]@{ Prefix = $_.Name; Count = $_.Count; Error = @($_.Group | Where-Object default -eq 'Error').Count; Warning = @($_.Group | Where-Object default -eq 'Warning').Count; Info = @($_.Group | Where-Object default -eq 'Info').Count; Hidden = @($_.Group | Where-Object default -eq 'Hidden').Count; Disabled = @($_.Group | Where-Object enabled -eq $false).Count; Prerelease = @($_.Group | Where-Object since -eq 'prerelease').Count } }
$summary | Sort-Object { [array]::IndexOf($prefixOrder, $_.Prefix) } | Format-Table -AutoSize | Out-String | Write-Output
Write-Output "Total: $($sorted.Count)  (compiler Error codes not listed: $alErrorCount)"
