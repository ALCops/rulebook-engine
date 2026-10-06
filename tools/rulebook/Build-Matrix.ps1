#requires -Version 7.4
<#
.SYNOPSIS
  Applies the placement algorithm to docs/rulebook/inventory/inventory.json and writes
  docs/rulebook/matrix/<PREFIX>.md, docs/rulebook/matrix/resolved.json, docs/rulebook/matrix/twins.json,
  docs/rulebook/matrix/levels.json, docs/rulebook/matrix/stages.json, docs/rulebook/matrix/counts.md and
  docs/rulebook/02-placement-algorithm.md.
.DESCRIPTION
  The rule tables below ARE the placement algorithm. 02-placement-algorithm.md is generated from them so the
  documentation can never drift from what produced the matrix. Evaluation order per id:
    1. override rows  (OV-nn)  explicit ids
    2. family rows    (F-nn)   by Family or flag
    3. decision rows  (D-nn)   by analyzer, default severity and enablement
  The first matching row gives the ladder (one action per level). The stage columns (Default, CI, vNext) are
  then derived by the stage rules (S-n) unless the matched row pins them. There is no target dimension (D21):
  every rule has one ladder for every AL project. Levels and stages are named by their slug (lowercased name)
  in every generated key and file name (D28): essential, recommended, strict, complete; default, ci, vnext.
#>
[CmdletBinding()]
param(
    [string]$RulebookDir = (Join-Path $PSScriptRoot '..' '..' 'docs' 'rulebook')
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' '..' 'modules' 'Rulebook.Generate.psd1') -Function Get-DiagnosticSortKey -Force
$RulebookDir = (Resolve-Path $RulebookDir).Path
$inv = Get-Content -Raw (Join-Path $RulebookDir 'inventory' 'inventory.json') | ConvertFrom-Json
# Prefixes in inventory order (the inventory is sorted by Get-DiagnosticSortKey of Rulebook.Generate).
$prefixes = @($inv | ForEach-Object { $_.prefix } | Select-Object -Unique)
$levelNames = @('Essential','Recommended','Strict','Complete')
$levelSlugs = @($levelNames | ForEach-Object { $_.ToLowerInvariant() })
$stageNames = @('default','CI','vNext')
$stageSlugs = @($stageNames | ForEach-Object { $_.ToLowerInvariant() })

function L([string]$s) { return $s }   # readability marker for ladders

# ---------------------------------------------------------------------------------------------
# Native ladder: what a rule's own author severity gives at each level (DR-018).
# ---------------------------------------------------------------------------------------------
function Get-NativeLadder($row) {
    switch ($row.default) {
        'Error'   { return 'Error/Error/Error/Error' }
        'Warning' { return 'None/Warning/Warning/Warning' }
        'Info'    { return $(if ($row.enabled) { 'None/Info/Warning/Warning' } else { 'None/None/None/Info' }) }
        'Hidden'  { return 'None/Hidden/Info/Info' }
    }
}
function Get-DeferredNativeLadder($row) {
    # native ladder with Essential forced to None (DR-019: marketplace checks start at Recommended)
    $lad = (Get-NativeLadder $row) -split '/'
    $lad[0] = 'None'
    return ($lad -join '/')
}
function Get-AnalyzerDefault($row) { if ($row.enabled) { return $row.default } else { return 'None' } }

# ---------------------------------------------------------------------------------------------
# Override rows: explicit ids. A $null ladder means "the ladder of the decision row that would match".
# ---------------------------------------------------------------------------------------------
$OvRows = @(
    @{ id='OV-01'; ids=@('AS0075','AS0099'); ladder='None/Hidden/Hidden/Hidden'; dr='DR-021'
       why='navcontainerhelper appsource.default.ruleset.json hides these two in AppSource validation' }
    @{ id='OV-02'; ids=@('AS0089'); ladder='Warning/Warning/Warning/Warning'; dr='DR-021'
       why='navcontainerhelper appsource.default.ruleset.json lowers AS0089 to Warning (AL cannot obsolete these objects)' }
    @{ id='OV-03'; ids=@('AW0001','AW0002','AW0003','AW0004','AW0008','AW0012','AW0016','AW0017'); ladder='Warning/Warning/Warning/Warning'; dr='DR-003'
       why='Web client silently drops or breaks the control; treated as a blocker from Essential' }
    @{ id='OV-04'; ids=@('LC0043'); ladder='Warning/Warning/Warning/Warning'; dr='DR-004'
       why='Secrets in Text leak through debugger and telemetry; security rule from Essential' }
    @{ id='OV-05'; ids=@('LC0054'); ladder='None/None/None/None'; dr='DR-005'
       why='Contradicts the mandatory-affix rules AS0011/AS0098; opinionated elsewhere' }
    @{ id='OV-06'; ids=@('LC0089i'); ladder='None/None/None/None'; dr='DR-006'
       why='Per-increment complexity noise; LC0089 and LC0090 carry the signal' }
    @{ id='OV-07'; ids=@('LC0097','FC0007'); ladder='None/None/None/Info'; dr='DR-007'
       why='Evaluated for contradictions, none found; opt-in style stays Info in Complete' }
    @{ id='OV-08'; ids=@('AS0003','AS0091'); ladder='None/Error/Error/Error'; dr='DR-019'
       why='Baseline-missing diagnostics need a configured baseline; off at Essential, native from Recommended' }
)

# ---------------------------------------------------------------------------------------------
# Family rows. `match` receives the inventory row. `ladderText` is what the docs print for scriptblock ladders.
# ---------------------------------------------------------------------------------------------
$FamilyRows = @(
    @{ id='F-01'; dr='DR-012'; name='Analyzer exception (X0000)';      match={ $args[0].family -eq 'internal' };      ladder='Info/Info/Info/Info'
       why='Only signal that an analyzer crashed; always visible, never blocking' }
    @{ id='F-02'; dr='DR-012'; name='Configuration cannot be loaded';  match={ $args[0].id -eq 'CM0001' };            ladder='Warning/Warning/Warning/Warning'
       why='A broken alcops.json silently disables rules; must block CI at every level' }
    @{ id='F-03'; dr='DR-009'; name='Definite runtime failure';        match={ $args[0].family -eq 'runtime' };       ladder='Error/Error/Error/Error'
       why='Construct always fails at runtime; blocks the local build at every level' }
    @{ id='F-04'; dr='DR-017'; name='Compiler future error';           match={ $args[0].family -eq 'future-error' };  ladder='Warning/Warning/Warning/Warning'; vnext='Error'
       why='Becomes a compile error on a later platform; Warning now, Error on vNext' }
    @{ id='F-05'; dr='DR-016'; name='Obsolete pending';                match={ $args[0].family -eq 'obsolete' };      ladder='None/Info/Warning/Warning'; ci='Info'; vnext='Warning'
       why='Replacement may not exist yet; advisory in CI, Warning on vNext where removal is near' }
    @{ id='F-06'; dr='DR-012'; name='Metric';                          match={ $args[0].family -eq 'metric' };        ladder='None/None/None/Info'
       why='Reports a number, not a defect; Complete shows it as Info' }
    @{ id='F-07'; dr='DR-019'; name='Marketplace-only check';          match={ $args[0].family -eq 'marketplace' };   ladder={ Get-DeferredNativeLadder $args[0] }; ladderText='None/native/native/native'
       why='Needs AppSourceCop.json or marketplace manifest fields; off at Essential, native from Recommended' }
    @{ id='F-08'; dr='DR-018'; name='PTE-only check';                  match={ $args[0].family -eq 'pte-only' };      ladder={ Get-NativeLadder $args[0] }; ladderText='native'
       why='Deployment blocker of a per-tenant extension at its native severity; AppSource projects opt out' }
    @{ id='F-09'; dr='DR-012'; name='Personalization diagnostics';     match={ $args[0].family -eq 'personalization' }; ladder=$null
       why='Page customization and profile warnings; treated like the other compiler warnings' }
)

# ---------------------------------------------------------------------------------------------
# Decision rows: analyzer x default x enabled -> ladder. First match wins.
# ---------------------------------------------------------------------------------------------
$msCops = @('AA','AW','PTE','AS')
$DecisionRows = @(
    @{ id='D-01'; dr='DR-012'; name='Compiler warning';                    match={ $args[0].prefix -eq 'AL' -and $args[0].default -eq 'Warning' };  ladder='None/Warning/Warning/Warning'
       why='Compiler warning at author severity from Recommended' }
    @{ id='D-02'; dr='DR-015'; name='Compiler info';                       match={ $args[0].prefix -eq 'AL' -and $args[0].default -eq 'Info' };     ladder='None/Info/Info/Info'
       why='Compiler information; never escalated, it describes the build rather than a defect' }
    @{ id='D-03'; dr='DR-015'; name='Compiler hidden';                     match={ $args[0].prefix -eq 'AL' -and $args[0].default -eq 'Hidden' };   ladder='None/Hidden/Hidden/Info'
       why='Hidden compiler diagnostics feed editor code actions; visible as Info only in Complete' }
    @{ id='D-04'; dr='DR-009'; name='CodeCop or UICop Error, not runtime'; match={ $args[0].prefix -in 'AA','AW' -and $args[0].default -eq 'Error' }; ladder='None/Warning/Warning/Warning'
       why='Author chose Error but the construct does not fail at runtime; Warning keeps local builds green' }
    @{ id='D-05'; dr='DR-018'; name='PerTenantExtensionCop or AppSourceCop Error'; match={ $args[0].prefix -in 'PTE','AS' -and $args[0].default -eq 'Error' }; ladder='Error/Error/Error/Error'
       why='Deployment blocker of one kind of extension at its native severity; the other kind opts out' }
    @{ id='D-06'; dr='DR-012'; name='Microsoft cop Warning';               match={ $args[0].prefix -in $msCops -and $args[0].default -eq 'Warning' -and $args[0].enabled }; ladder='None/Warning/Warning/Warning'
       why='Author severity from Recommended' }
    @{ id='D-07'; dr='DR-012'; name='Microsoft cop Info, enabled';         match={ $args[0].prefix -in $msCops -and $args[0].default -eq 'Info' -and $args[0].enabled }; ladder='None/Info/Warning/Warning'
       why='Advisory at Recommended, blocks CI from Strict' }
    @{ id='D-08'; dr='DR-012'; name='Microsoft cop Hidden';                match={ $args[0].prefix -in $msCops -and $args[0].default -eq 'Hidden' }; ladder='None/Hidden/Info/Info'
       why='Hidden keeps the code action available; visible from Strict' }
    @{ id='D-09'; dr='DR-012'; name='Microsoft cop disabled by default';   match={ $args[0].prefix -in $msCops -and -not $args[0].enabled };       ladder='None/None/None/Info'
       why='Opt-in rule; Complete enables it at Info' }
    @{ id='D-10'; dr='DR-013'; name='PlatformCop Warning, enabled';        match={ $args[0].prefix -eq 'PC' -and $args[0].default -eq 'Warning' -and $args[0].enabled }; ladder='Warning/Warning/Warning/Warning'
       why='Platform rejects or misexecutes the construct; blocks CI from Essential' }
    @{ id='D-11'; dr='DR-013'; name='PlatformCop Info, enabled';           match={ $args[0].prefix -eq 'PC' -and $args[0].default -eq 'Info' -and $args[0].enabled };    ladder='Info/Info/Warning/Warning'
       why='Platform advice visible from Essential, blocks CI from Strict' }
    @{ id='D-12'; dr='DR-012'; name='ALCops Warning, enabled';             match={ $args[0].prefix -in 'AC','LC','DC','FC','TA' -and $args[0].default -eq 'Warning' -and $args[0].enabled }; ladder='None/Warning/Warning/Warning'
       why='Author severity from Recommended' }
    @{ id='D-13'; dr='DR-012'; name='ALCops Info, enabled';                match={ $args[0].prefix -in 'AC','LC','DC','FC','TA' -and $args[0].default -eq 'Info' -and $args[0].enabled };    ladder='None/Info/Warning/Warning'
       why='Advisory at Recommended, blocks CI from Strict' }
    @{ id='D-14'; dr='DR-012'; name='ALCops disabled by default';          match={ $args[0].prefix -in 'PC','AC','LC','DC','FC','TA' -and -not $args[0].enabled }; ladder={ "None/None/None/$($args[0].default)" }; ladderText='None/None/None/default'
       why='Opt-in rule; Complete enables it at its author severity' }
)

# ---------------------------------------------------------------------------------------------
# Stage rules (S): derive Default, CI, vNext when the matched row did not pin them.
# ---------------------------------------------------------------------------------------------
$ciRelaxed = @('AL0603','AL1026','AL0472','AL0473','AL0479','AL1029','AL1030')
function Get-StageColumn($row, $pinnedCi, $pinnedVnext) {
    $ci = '='; $vnext = '='
    if ($row.id -in $ciRelaxed) { $ci = 'Info' }                                        # S-2
    if ($null -ne $pinnedCi) { $ci = $pinnedCi }
    if ($null -ne $pinnedVnext) { $vnext = $pinnedVnext }
    return @('=', $ci, $vnext)
}
$StageRules = @(
    @{ id='S-1'; text='The default stage equals the level action; developers see exactly what the pipeline sees. It has no stage file.' }
    @{ id='S-2'; text="CI = Info for diagnostics a team cannot always fix in the same change: family obsolete (F-05) and $($ciRelaxed -join ', ') (implicit conversions, XML validation, translation file mismatches). Shipped as ``stages/ci.json``." }
    @{ id='S-3'; text='vNext = Error for family future-error (F-04) and Warning for family obsolete (F-05); everything else equals the level action. Shipped as `stages/vnext.json`.' }
    @{ id='S-4'; text='A stage entry never enables an id the level left at None (see the resolution recipe in 00-conventions.md); this binds every stage file, shipped or custom (D27). New ids that appear in a prerelease compiler are a scan-time concern of WP08, not of the matrix.' }
)

# ---------------------------------------------------------------------------------------------
# Apply
# ---------------------------------------------------------------------------------------------
function Expand-Ladder([string]$s) { if ($s -match '/') { return $s -split '/' } else { return @($s, $s, $s, $s) } }
function Resolve-Ladder($row, $ladderSpec) {
    if ($ladderSpec -is [scriptblock]) { return (& $ladderSpec $row) }
    if ($null -ne $ladderSpec) { return $ladderSpec }
    # $null ladder: fall through to the decision rows
    foreach ($d in $DecisionRows) { if (& $d.match $row) { return $(if ($d.ladder -is [scriptblock]) { & $d.ladder $row } else { $d.ladder }) } }
    throw "No decision row for $($row.id)"
}
$matrix = [System.Collections.Generic.List[object]]::new()
foreach ($row in $inv) {
    $hit = $null; $basis = $null; $why = $null; $pinCi = $null; $pinVnext = $null; $ladder = $null
    foreach ($o in $OvRows) { if ($row.id -in $o.ids) { $hit = $o; break } }
    if ($hit) {
        $basis = $hit.id; $why = $hit.why
        $ladder = Resolve-Ladder $row $hit.ladder
        # an override keeps the stage pins of the family row it would otherwise have matched
        foreach ($f in $FamilyRows) { if (& $f.match $row) { $pinCi = $f.ci; $pinVnext = $f.vnext; break } }
    } else {
        foreach ($f in $FamilyRows) { if (& $f.match $row) { $hit = $f; break } }
        if ($hit) {
            $basis = $hit.id; $why = $hit.why; $pinCi = $hit.ci; $pinVnext = $hit.vnext
            $ladder = Resolve-Ladder $row $hit.ladder
        } else {
            foreach ($d in $DecisionRows) { if (& $d.match $row) { $hit = $d; break } }
            if (-not $hit) { throw "No rule matched $($row.id)" }
            $basis = $hit.id; $why = $hit.why
            $ladder = Resolve-Ladder $row $hit.ladder
        }
    }
    $lad = Expand-Ladder $ladder
    $sc = Get-StageColumn $row $pinCi $pinVnext
    $max = 120 - ("; $basis").Length
    if ($why.Length -gt $max) { $why = $why.Substring(0, $max - 3).TrimEnd() + '...' }
    $just = "$why; $basis"
    $matrix.Add([ordered]@{
        id = $row.id; prefix = $row.prefix; Essential = $lad[0]; Recommended = $lad[1]; Strict = $lad[2]; Complete = $lad[3]
        Default = $sc[0]; CI = $sc[1]; vNext = $sc[2]; Basis = $basis; Justification = $just
    })
}

# ---------------------------------------------------------------------------------------------
# Resolve every cell and write outputs
# ---------------------------------------------------------------------------------------------
function Resolve-Cell($m, [int]$levelIndex, [string]$stage) {
    $lad = @($m.Essential, $m.Recommended, $m.Strict, $m.Complete)
    $a = $lad[$levelIndex]
    $st = switch ($stage) { 'default' { $m.Default } 'ci' { $m.CI } 'vnext' { $m.vNext } }
    if ($st -ne '=' -and $a -ne 'None') { $a = $st }
    return $a
}
$stages = $stageSlugs; $levelIds = $levelSlugs   # resolved.json keys are <levelSlug>.<stageSlug>, e.g. essential.default
$resolved = [ordered]@{}
foreach ($m in $matrix) {
    $cells = [ordered]@{}
    foreach ($li in 0..3) { foreach ($s in $stages) { $cells["$($levelIds[$li]).$s"] = Resolve-Cell $m $li $s } }
    $resolved[$m.id] = $cells
}
$matrixDir = Join-Path $RulebookDir 'matrix'
New-Item -ItemType Directory -Force -Path $matrixDir | Out-Null
$resolved | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $matrixDir 'resolved.json') -Encoding utf8NoBOM
($matrix | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath (Join-Path $matrixDir 'matrix.json') -Encoding utf8NoBOM

# ---------------------------------------------------------------------------------------------
# twins.json: the PerTenantExtensionCop / AppSourceCop pairs the `twins` setting of an organization acts on (D23)
# ---------------------------------------------------------------------------------------------
$byId = @{}; foreach ($r in $inv) { $byId[$r.id] = $r }
$pairs = [System.Collections.Generic.List[object]]::new()
foreach ($r in ($inv | Where-Object prefix -eq 'PTE')) {
    $twinFlags = @($r.flags | Where-Object { $_ -match '^twin:' })
    if ($twinFlags.Count -eq 0) { continue }
    if ($twinFlags.Count -gt 1) { throw "$($r.id) has more than one twin flag" }
    $as = $twinFlags[0].Substring(5)
    if (-not $byId.ContainsKey($as) -or $byId[$as].prefix -ne 'AS') { throw "$($r.id) twin $as is not an AppSourceCop id" }
    if (@($byId[$as].flags | Where-Object { $_ -eq "twin:$($r.id)" }).Count -ne 1) { throw "twin flag of $($r.id) is not mirrored on $as" }
    $pairs.Add([ordered]@{ pte = $r.id; appsource = $as; title = $r.title })
}
# Pairs in id order of the PTE side: Get-DiagnosticSortKey, compared ordinally.
$sortedPairs = [System.Collections.Generic.SortedDictionary[string, object]]::new([System.StringComparer]::Ordinal)
foreach ($pair in $pairs) { $sortedPairs.Add((Get-DiagnosticSortKey -Id $pair['pte']), $pair) }
$twins = [ordered]@{
    generatedBy = 'tools/rulebook/Build-Matrix.ps1'
    setting     = 'twins'
    values      = @('both','appsource','pte')
    count       = $pairs.Count
    pairs       = @($sortedPairs.Values)
}
$twins | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $matrixDir 'twins.json') -Encoding utf8NoBOM

# ---------------------------------------------------------------------------------------------
# levels.json and stages.json: the shipped level ladder and stage set as the template generator reads them (D26, D27).
# Each level after the first is basedOn the previous one; the default stage has no file.
# ---------------------------------------------------------------------------------------------
$levelList = [System.Collections.Generic.List[object]]::new()
for ($li = 0; $li -lt $levelNames.Count; $li++) {
    $entry = [ordered]@{ name = $levelNames[$li]; slug = $levelSlugs[$li] }
    if ($li -gt 0) { $entry['basedOn'] = $levelNames[$li - 1] }
    $entry['file'] = "base/$($levelSlugs[$li]).ruleset.json"
    $levelList.Add($entry)
}
$levelsOut = [ordered]@{ generatedBy = 'tools/rulebook/Build-Matrix.ps1'; setting = 'levels'; count = $levelList.Count; levels = @($levelList) }
$levelsOut | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $matrixDir 'levels.json') -Encoding utf8NoBOM
$stageList = [System.Collections.Generic.List[object]]::new()
for ($si = 0; $si -lt $stageNames.Count; $si++) {
    $entry = [ordered]@{ name = $stageNames[$si]; slug = $stageSlugs[$si] }
    if ($si -gt 0) { $entry['file'] = "stages/$($stageSlugs[$si]).json" }
    $stageList.Add($entry)
}
$stagesOut = [ordered]@{ generatedBy = 'tools/rulebook/Build-Matrix.ps1'; setting = 'stages'; count = $stageList.Count; stages = @($stageList) }
$stagesOut | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $matrixDir 'stages.json') -Encoding utf8NoBOM

foreach ($p in $prefixes) {
    $set = @($matrix | Where-Object prefix -eq $p)
    $analyzer = ($inv | Where-Object prefix -eq $p | Select-Object -First 1).analyzer
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("# Matrix: $analyzer ($p)")
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("Generated by ``tools/rulebook/Build-Matrix.ps1`` from [inventory/$p.md](../inventory/$p.md) and the rules in [02-placement-algorithm.md](../02-placement-algorithm.md). Columns and the resolution recipe are defined in [00-conventions.md](../00-conventions.md).")
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('| ID | Essential | Recommended | Strict | Complete | Default | CI | vNext | Basis | Justification |')
    [void]$sb.AppendLine('|---|---|---|---|---|---|---|---|---|---|')
    foreach ($m in $set) { [void]$sb.AppendLine("| $($m.id) | $($m.Essential) | $($m.Recommended) | $($m.Strict) | $($m.Complete) | $($m.Default) | $($m.CI) | $($m.vNext) | $($m.Basis) | $($m.Justification) |") }
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("Count: $($set.Count)")
    Set-Content -LiteralPath (Join-Path $matrixDir "$p.md") -Value $sb.ToString() -Encoding utf8NoBOM -NoNewline
}

# ---------------------------------------------------------------------------------------------
# 02-placement-algorithm.md
# ---------------------------------------------------------------------------------------------
function Format-Ladder($row) { if ($row.ladder -is [scriptblock]) { return $row.ladderText } elseif ($row.ladder) { return $row.ladder } else { return 'by decision row' } }
$doc = [System.Text.StringBuilder]::new()
[void]$doc.AppendLine('# Placement algorithm')
[void]$doc.AppendLine()
[void]$doc.AppendLine('Generated by `tools/rulebook/Build-Matrix.ps1`; the tables below are the rule tables inside that script, printed so the documentation cannot drift from the matrix. To change a placement, change the script and rebuild.')
[void]$doc.AppendLine()
[void]$doc.AppendLine('## 1. Evaluation order')
[void]$doc.AppendLine()
[void]$doc.AppendLine('For every id in the inventory, in this order, the first matching row gives the ladder and the `Basis` token:')
[void]$doc.AppendLine()
[void]$doc.AppendLine('1. **Override rows** `OV-nn`: explicit ids.')
[void]$doc.AppendLine('2. **Family rows** `F-nn`: by `Family` or flag from the inventory. A row whose ladder is "by decision row" keeps the ladder of the decision row that would otherwise match.')
[void]$doc.AppendLine('3. **Decision rows** `D-nn`: by analyzer, default severity and enablement.')
[void]$doc.AppendLine()
[void]$doc.AppendLine('Then the **stage rules** `S-n` fill `Default`, `CI` and `vNext`, unless the matched row pins a value. The resolution recipe in [00-conventions.md](00-conventions.md) turns a row into 12 cells, one per level and stage, keyed `<level>.<stage>` by slug (`essential.default`, `recommended.ci`). In an organization repository the `CI` and `vNext` columns become the stage files `stages/ci.json` and `stages/vnext.json`, applied on top of every level (D27); the `Default` column is always `=` and has no file. There is no target dimension: every rule has one ladder for every AL project (D21).')
[void]$doc.AppendLine()
[void]$doc.AppendLine('Ladders are written `Essential/Recommended/Strict/Complete`. `native` stands for the ladder derived from the author severity: Error -> `Error/Error/Error/Error`, Warning -> `None/Warning/Warning/Warning`, Info -> `None/Info/Warning/Warning`, Hidden -> `None/Hidden/Info/Info`.')
[void]$doc.AppendLine()
[void]$doc.AppendLine('## 2. Override rows')
[void]$doc.AppendLine()
[void]$doc.AppendLine('| Row | Ids | Ladder | Decision record | Reason |')
[void]$doc.AppendLine('|---|---|---|---|---|')
foreach ($o in $OvRows) { [void]$doc.AppendLine("| $($o.id) | $($o.ids -join ', ') | $(Format-Ladder $o) | $($o.dr) | $($o.why) |") }
[void]$doc.AppendLine()
[void]$doc.AppendLine('## 3. Family rows')
[void]$doc.AppendLine()
[void]$doc.AppendLine('| Row | Selector | Ladder | CI | vNext | Decision record | Reason |')
[void]$doc.AppendLine('|---|---|---|---|---|---|---|')
foreach ($f in $FamilyRows) { [void]$doc.AppendLine("| $($f.id) | $($f.name) | $(Format-Ladder $f) | $(if ($f.ci) { $f.ci } else { '=' }) | $(if ($f.vnext) { $f.vnext } else { '=' }) | $($f.dr) | $($f.why) |") }
[void]$doc.AppendLine()
[void]$doc.AppendLine('Family membership is assigned by hand in `inventory/annotations.json` and printed in the `Family` and `Flags` columns of the inventory. The `runtime` whitelist is: ' + (($inv | Where-Object family -eq 'runtime' | ForEach-Object id) -join ', ') + '.')
[void]$doc.AppendLine()
[void]$doc.AppendLine('## 4. Decision rows')
[void]$doc.AppendLine()
[void]$doc.AppendLine('| Row | Selector | Ladder | Decision record | Reason |')
[void]$doc.AppendLine('|---|---|---|---|---|')
foreach ($d in $DecisionRows) { [void]$doc.AppendLine("| $($d.id) | $($d.name) | $(Format-Ladder $d) | $($d.dr) | $($d.why) |") }
[void]$doc.AppendLine()
[void]$doc.AppendLine('The level intent behind the rows:')
[void]$doc.AppendLine()
[void]$doc.AppendLine('| Level | What is on | Severity rule |')
[void]$doc.AppendLine('|---|---|---|')
[void]$doc.AppendLine('| Essential | Runtime failures, the Error defaults of PerTenantExtensionCop and AppSourceCop (deployment blockers of either kind of extension, except the marketplace and baseline-missing checks), compiler future errors, every default-on PlatformCop rule, the web-client and security overrides, CM0001 and the X0000 rules. Everything else is None. | Error only for family runtime and the PerTenantExtensionCop and AppSourceCop Error defaults; the rest Warning (Info for PlatformCop Info rules). |')
[void]$doc.AppendLine('| Recommended | Every default-on rule of every analyzer at its author severity; the marketplace and baseline-missing checks join here; obsolete-pending at Info. | Author default, except the documented downgrades. |')
[void]$doc.AppendLine('| Strict | Same set; default-on Info becomes Warning, default-on Hidden becomes Info. Compiler Info stays Info. | Advisory rules become CI-blocking. |')
[void]$doc.AppendLine('| Complete | Adds every opt-in rule at its author severity, except LC0089i and contradiction losers; Hidden-by-default rules appear as Info. | No further escalation. |')
[void]$doc.AppendLine()
[void]$doc.AppendLine('## 5. Project kinds and twins')
[void]$doc.AppendLine()
[void]$doc.AppendLine('The matrix does not know whether a project is a per-tenant extension or an AppSource app (D21). Both Microsoft cops run at their native severity, so a per-tenant project sees the AppSourceCop blockers (AS0084 and AS0013 on id ranges, the marketplace manifest checks from Recommended) and an AppSource project sees the PerTenantExtensionCop blockers (PTE0001, PTE0002, PTE0009, PTE0013, PTE0024). The project opts out of the side that does not apply: by disabling a cop in `al.codeAnalyzers`, by `suppressWarnings` in `app.json` (which works because a rule at its native severity is not listed in the endpoint, D22), or by a rule in its project ruleset file. The user documentation of the Rulebook template (`docs/pte-or-appsource.md`) carries the ready-made lists. DR-018 and DR-019 record the placements.')
[void]$doc.AppendLine()
[void]$doc.AppendLine("The $($pairs.Count) twin pairs (identical check in both cops, listed in [overlaps.md](overlaps.md) and exported to ``matrix/twins.json``) are both active at their native ladder. An organization that builds only one kind of extension picks a side with the ``twins`` setting of its Rulebook repository (``both``, ``appsource`` or ``pte``); the generator writes the losing side at ``None``. DR-020 records the policy.")
[void]$doc.AppendLine()
[void]$doc.AppendLine('## 6. Stage rules')
[void]$doc.AppendLine()
foreach ($s in $StageRules) { [void]$doc.AppendLine("- **$($s.id)** $($s.text)") }
[void]$doc.AppendLine()
[void]$doc.AppendLine('## 7. Justification')
[void]$doc.AppendLine()
[void]$doc.AppendLine('Every matrix row carries `<reason of the matched row>; <Basis>` as its justification, at most 120 characters, and the generated level and stage file entries copy it verbatim into the `justification` property.')
Set-Content -LiteralPath (Join-Path $RulebookDir '02-placement-algorithm.md') -Value $doc.ToString() -Encoding utf8NoBOM -NoNewline

# ---------------------------------------------------------------------------------------------
# Count summary (pasted into README.md). "Listed" = ids whose action differs from the analyzer default (D22).
# The second table gives the size of the shipped delta files (D27): the root level lists the ids that differ
# from the analyzer default, every other level the ids that differ from its basedOn level, a stage file the ids
# whose stage column is not "=".
# ---------------------------------------------------------------------------------------------
$lines = @('| Level | Stage | Error | Warning | Info | Hidden | None | Listed |', '|---|---|---|---|---|---|---|---|')
foreach ($li in 0..3) { foreach ($s in $stages) {
    $key = "$($levelIds[$li]).$s"
    $c = @{ Error = 0; Warning = 0; Info = 0; Hidden = 0; None = 0 }; $listed = 0
    foreach ($id in $resolved.Keys) { $a = $resolved[$id][$key]; $c[$a]++; if ($a -ne (Get-AnalyzerDefault $byId[$id])) { $listed++ } }
    $lines += "| $($levelNames[$li]) | $s | $($c.Error) | $($c.Warning) | $($c.Info) | $($c.Hidden) | $($c.None) | $listed |"
} }
$fileCounts = [ordered]@{}
foreach ($li in 0..3) {
    $n = 0
    foreach ($m in $matrix) {
        $lad = @($m.Essential, $m.Recommended, $m.Strict, $m.Complete)
        $below = if ($li -eq 0) { Get-AnalyzerDefault $byId[$m.id] } else { $lad[$li - 1] }
        if ($lad[$li] -ne $below) { $n++ }
    }
    $fileCounts["base/$($levelSlugs[$li]).ruleset.json"] = $n
}
$fileCounts['stages/ci.json'] = @($matrix | Where-Object { $_.CI -ne '=' }).Count
$fileCounts['stages/vnext.json'] = @($matrix | Where-Object { $_.vNext -ne '=' }).Count
$lines += ''
$lines += '| File | Entries |'
$lines += '|---|---|'
foreach ($k in $fileCounts.Keys) { $lines += "| ``$k`` | $($fileCounts[$k]) |" }
$lines -join "`n" | Set-Content -LiteralPath (Join-Path $matrixDir 'counts.md') -Encoding utf8NoBOM
Write-Host "matrix rows: $($matrix.Count); twin pairs: $($pairs.Count)"
$matrix | Group-Object { $_.Basis } | Sort-Object Name | ForEach-Object { Write-Host ("{0,-6} {1,4}" -f $_.Name, $_.Count) }
