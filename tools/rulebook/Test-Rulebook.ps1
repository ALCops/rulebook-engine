#requires -Version 7.4
<#
.SYNOPSIS
  Runs the checks V1 to V14 from docs/rulebook/verification.md against the inventory, the matrix and the docs.
  Exit code 1 when any check fails.
#>
[CmdletBinding()]
param(
    [string]$RulebookDir = (Join-Path $PSScriptRoot '..' '..' 'docs' 'rulebook')
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' '..' 'modules' 'Rulebook.Generate.psd1') -Function Get-DiagnosticSortKey -Force
$RulebookDir = (Resolve-Path $RulebookDir).Path
$strict = @{ None = 0; Hidden = 1; Info = 2; Warning = 3; Error = 4 }
$levelNames = @('Essential','Recommended','Strict','Complete')
$stages = @('default','ci','vnext'); $levelIds = @('essential','recommended','strict','complete')   # slugs; resolved.json keys are <level>.<stage>
$failures = [System.Collections.Generic.List[string]]::new()
function Fail([string]$check, [string]$msg) { $script:failures.Add("$check  $msg") }

function Read-Table([string]$path) {
    # returns rows as ordered hashtables keyed by header, plus the Count line
    $lines = Get-Content -LiteralPath $path
    $header = $null; $rows = [System.Collections.Generic.List[object]]::new(); $count = $null
    foreach ($line in $lines) {
        if ($line -match '^Count:\s*(\d+)') { $count = [int]$Matches[1]; continue }
        if ($line -notmatch '^\|') { continue }
        $cells = @(($line.Trim() -replace '^\|', '' -replace '\|$', '') -split '(?<!\\)\|' | ForEach-Object { $_.Trim() })
        if (-not $header) { $header = $cells; continue }
        if ($cells[0] -match '^-+$') { continue }
        $r = [ordered]@{}
        for ($i = 0; $i -lt $header.Count; $i++) { $r[$header[$i]] = $cells[$i] }
        $rows.Add($r)
    }
    return @{ header = $header; rows = $rows; count = $count }
}
function Get-AnalyzerDefault($r) { if ($r.enabled) { return $r.default } else { return 'None' } }
function Get-NativeLadder($r) {
    switch ($r.default) {
        'Error'   { return @('Error','Error','Error','Error') }
        'Warning' { return @('None','Warning','Warning','Warning') }
        'Info'    { return $(if ($r.enabled) { @('None','Info','Warning','Warning') } else { @('None','None','None','Info') }) }
        'Hidden'  { return @('None','Hidden','Info','Info') }
    }
}

$inv = Get-Content -Raw (Join-Path $RulebookDir 'inventory' 'inventory.json') | ConvertFrom-Json
$matrix = Get-Content -Raw (Join-Path $RulebookDir 'matrix' 'matrix.json') | ConvertFrom-Json
$resolved = Get-Content -Raw (Join-Path $RulebookDir 'matrix' 'resolved.json') | ConvertFrom-Json -AsHashtable
$twins = Get-Content -Raw (Join-Path $RulebookDir 'matrix' 'twins.json') | ConvertFrom-Json
$levelsJson = Get-Content -Raw (Join-Path $RulebookDir 'matrix' 'levels.json') | ConvertFrom-Json
$stagesJson = Get-Content -Raw (Join-Path $RulebookDir 'matrix' 'stages.json') | ConvertFrom-Json
$byId = @{}; foreach ($r in $inv) { $byId[$r.id] = $r }
$mById = @{}; foreach ($m in $matrix) { $mById[$m.id] = $m }
$algorithmDoc = Get-Content -Raw (Join-Path $RulebookDir '02-placement-algorithm.md')
$decisionsDoc = Get-Content -Raw (Join-Path $RulebookDir 'decisions.md')
$overlapsDoc = Get-Content -Raw (Join-Path $RulebookDir 'overlaps.md')
$readmeDoc = Get-Content -Raw (Join-Path $RulebookDir 'README.md')
$matrixColumns = @('ID','Essential','Recommended','Strict','Complete','Default','CI','vNext','Basis','Justification')

# ---- V1 inventory files vs json, inventory order ----
# Expected ids per prefix: a check input. Its keys are the prefixes in inventory order and name the per-prefix files.
$expected = [ordered]@{ AL = 219; AA = 93; AW = 17; PTE = 26; AS = 143; PC = 38; AC = 35; LC = 34; DC = 11; FC = 8; TA = 3; CM = 1 }
$seen = @{}
foreach ($p in $expected.Keys) {
    $t = Read-Table (Join-Path $RulebookDir 'inventory' "$p.md")
    $jsonRows = @($inv | Where-Object prefix -eq $p)
    if ($t.rows.Count -ne $jsonRows.Count) { Fail 'V1' "$p.md has $($t.rows.Count) rows, inventory.json has $($jsonRows.Count)" }
    if ($t.count -ne $t.rows.Count) { Fail 'V1' "$p.md Count line $($t.count) != rows $($t.rows.Count)" }
    foreach ($r in $t.rows) { if ($seen.ContainsKey($r.ID)) { Fail 'V1' "duplicate id $($r.ID)" }; $seen[$r.ID] = $true; if ($r.ID -notmatch '^(AL|AA|AW|PTE|AS|PC|AC|LC|DC|FC|TA|CM)[0-9]{4}i?$') { Fail 'V1' "bad id format $($r.ID)" } }
}
if ($inv.Count -ne 628) { Fail 'V1' "total inventory is $($inv.Count), expected 628" }
# the shared sort key (Rulebook.Generate) reproduces the inventory order: strictly ascending, compared ordinally
for ($i = 1; $i -lt $inv.Count; $i++) { if ([string]::CompareOrdinal((Get-DiagnosticSortKey -Id $inv[$i - 1].id), (Get-DiagnosticSortKey -Id $inv[$i].id)) -ge 0) { Fail 'V1' "inventory.json is not in ascending Get-DiagnosticSortKey order at $($inv[$i - 1].id), $($inv[$i].id)" } }
foreach ($p in $expected.Keys) { $n = @($inv | Where-Object prefix -eq $p).Count; if ($n -ne $expected[$p]) { Fail 'V1' "$p has $n ids, expected $($expected[$p])" } }

# ---- V2 matrix rows == inventory rows, same order, md == json; levels.json and stages.json describe the shipped set ----
if ($matrix.Count -ne $inv.Count) { Fail 'V2' "matrix has $($matrix.Count) rows, inventory $($inv.Count)" }
for ($i = 0; $i -lt [Math]::Min($matrix.Count, $inv.Count); $i++) { if ($matrix[$i].id -ne $inv[$i].id) { Fail 'V2' "row $i is $($matrix[$i].id) in matrix, $($inv[$i].id) in inventory"; break } }
foreach ($p in $expected.Keys) {
    $t = Read-Table (Join-Path $RulebookDir 'matrix' "$p.md")
    if (($t.header -join ',') -ne ($matrixColumns -join ',')) { Fail 'V2' "$p.md has unexpected columns" }
    foreach ($r in $t.rows) {
        $m = $mById[$r.ID]
        if (-not $m) { Fail 'V2' "$($r.ID) in matrix/$p.md but not in matrix.json"; continue }
        foreach ($c in ($matrixColumns | Select-Object -Skip 1)) { if ($r[$c] -ne $m.$c) { Fail 'V2' "$($r.ID) column $c differs between md and json" } }
    }
}
foreach ($id in $resolved.Keys) { if (@($resolved[$id].Keys).Count -ne 12) { Fail 'V2' "$id has $(@($resolved[$id].Keys).Count) resolved cells, expected 12" } }
if ((@($levelsJson.levels | ForEach-Object slug) -join ',') -ne ($levelIds -join ',')) { Fail 'V2' "levels.json slugs are $(@($levelsJson.levels | ForEach-Object slug) -join ','), expected $($levelIds -join ',')" }
if ((@($levelsJson.levels | ForEach-Object name) -join ',') -ne ($levelNames -join ',')) { Fail 'V2' 'levels.json names do not match the shipped level names' }
for ($i = 0; $i -lt @($levelsJson.levels).Count; $i++) {
    $l = $levelsJson.levels[$i]
    if ($i -eq 0 -and $l.PSObject.Properties['basedOn']) { Fail 'V2' 'levels.json: the root level must not have basedOn' }
    if ($i -gt 0 -and $l.basedOn -ne $levelNames[$i - 1]) { Fail 'V2' "levels.json: $($l.name) basedOn $($l.basedOn), expected $($levelNames[$i - 1])" }
    if ($l.file -ne "base/$($levelIds[$i]).ruleset.json") { Fail 'V2' "levels.json: $($l.name) file is $($l.file)" }
}
if ((@($stagesJson.stages | ForEach-Object slug) -join ',') -ne ($stages -join ',')) { Fail 'V2' "stages.json slugs are $(@($stagesJson.stages | ForEach-Object slug) -join ','), expected $($stages -join ',')" }
if ($stagesJson.stages[0].PSObject.Properties['file']) { Fail 'V2' 'stages.json: the default stage must not have a file' }
foreach ($st in @($stagesJson.stages | Select-Object -Skip 1)) { if ($st.file -ne "stages/$($st.slug).json") { Fail 'V2' "stages.json: $($st.name) file is $($st.file)" } }

# ---- V3 monotonic ladders (shipped set; I2 is a property of the shipped matrix, not enforced in org repos, D26) ----
foreach ($m in $matrix) {
    $lad = @($m.Essential, $m.Recommended, $m.Strict, $m.Complete)
    for ($i = 1; $i -lt 4; $i++) { if ($strict[$lad[$i]] -lt $strict[$lad[$i-1]]) { Fail 'V3' "$($m.id) ladder $($lad -join '/') is not monotonic" } }
}

# ---- V4 Error placement ----
foreach ($m in $matrix) {
    $r = $byId[$m.id]
    $mayError = ($r.family -eq 'runtime') -or ($r.prefix -in 'PTE','AS' -and $r.default -eq 'Error')
    foreach ($a in $m.Essential, $m.Recommended, $m.Strict, $m.Complete) { if ($a -eq 'Error' -and -not $mayError) { Fail 'V4' "$($m.id) has Error in the ladder but is neither runtime nor a PTE/AS Error default" } }
    if ($m.vNext -eq 'Error' -and $r.family -ne 'future-error') { Fail 'V4' "$($m.id) vNext Error outside family future-error" }
    if ($m.Default -ne '=') { Fail 'V4' "$($m.id) Default column must be =" }
}

# ---- V5 LC0089i and contradictions ----
$x = $resolved['LC0089i']; foreach ($k in $x.Keys) { if ($x[$k] -ne 'None') { Fail 'V5' "LC0089i is $($x[$k]) at $k" } }
foreach ($r in $inv) {
    foreach ($fl in $r.flags) {
        if ($fl -match '^contradicts:(\w+)$') {
            $other = $Matches[1]
            if ($overlapsDoc -notmatch [regex]::Escape($r.id)) { Fail 'V5' "$($r.id) has contradicts flag but no row in overlaps.md" }
            # exactly one side of a contradiction may be active in any cell
            foreach ($k in $resolved[$r.id].Keys) { if ($resolved[$r.id][$k] -ne 'None' -and $resolved[$other][$k] -ne 'None') { Fail 'V5' "$($r.id) and $other both active at $k" } }
        }
    }
}

# ---- V6 twins: declared, symmetric, exported, both sides at their native ladder ----
$flagPairs = @{}
foreach ($r in $inv | Where-Object prefix -eq 'PTE') {
    $tw = @($r.flags | Where-Object { $_ -match '^twin:' } | ForEach-Object { $_.Substring(5) })
    if ($tw.Count -gt 1) { Fail 'V6' "$($r.id) has more than one twin flag" }
    if ($tw.Count -eq 0) { continue }
    $as = $tw[0]
    if (-not $byId.ContainsKey($as) -or $byId[$as].prefix -ne 'AS') { Fail 'V6' "$($r.id) twin $as is not an AppSourceCop id"; continue }
    if ("twin:$($r.id)" -notin @($byId[$as].flags)) { Fail 'V6' "twin flag of $($r.id) is not mirrored on $as" }
    $flagPairs[$r.id] = $as
    if ($overlapsDoc -notmatch "\| $($r.id) \| $as \|") { Fail 'V6' "$($r.id) / $as not in the twins table of overlaps.md" }
    foreach ($id in $r.id, $as) {
        $nat = Get-NativeLadder $byId[$id]; $m = $mById[$id]
        $lad = @($m.Essential, $m.Recommended, $m.Strict, $m.Complete)
        if ($m.Basis -notmatch '^OV-' -and (($lad -join '/') -ne ($nat -join '/'))) { Fail 'V6' "twin side $id is $($lad -join '/') but its native ladder is $($nat -join '/')" }
    }
}
if ($twins.count -ne $flagPairs.Count -or @($twins.pairs).Count -ne $flagPairs.Count) { Fail 'V6' "twins.json lists $($twins.count) pairs, inventory flags give $($flagPairs.Count)" }
foreach ($p in $twins.pairs) { if ($flagPairs[$p.pte] -ne $p.appsource) { Fail 'V6' "twins.json pair $($p.pte)/$($p.appsource) does not match the inventory flags" } }
if (($twins.values -join ',') -ne 'both,appsource,pte') { Fail 'V6' 'twins.json values must be both, appsource, pte' }

# ---- V7 native severity of the cop-specific families ----
foreach ($r in $inv) {
    $nat = Get-NativeLadder $r
    if ($r.family -eq 'marketplace' -or $r.id -in 'AS0003','AS0091') {
        foreach ($s in $stages) { if ($resolved[$r.id]["essential.$s"] -ne 'None') { Fail 'V7' "$($r.id) must be None at essential.$s" } }
        if ($resolved[$r.id]['recommended.default'] -ne $nat[1]) { Fail 'V7' "$($r.id) is $($resolved[$r.id]['recommended.default']) at recommended.default, native is $($nat[1])" }
    }
    if ($r.family -eq 'pte-only') {
        $m = $mById[$r.id]; $lad = @($m.Essential, $m.Recommended, $m.Strict, $m.Complete)
        if (($lad -join '/') -ne ($nat -join '/')) { Fail 'V7' "pte-only $($r.id) is $($lad -join '/'), native is $($nat -join '/')" }
    }
    if ($r.prefix -in 'PTE','AS' -and $r.default -eq 'Error' -and $r.family -ne 'marketplace' -and $mById[$r.id].Basis -notmatch '^OV-') {
        foreach ($k in $resolved[$r.id].Keys) { if ($resolved[$r.id][$k] -ne 'Error') { Fail 'V7' "$($r.id) is a PTE/AS Error default but $($resolved[$r.id][$k]) at $k" } }
    }
}

# ---- V8 basis tokens and decision records ----
$drs = @([regex]::Matches($decisionsDoc, '^### (DR-\d{3})', 'Multiline') | ForEach-Object { $_.Groups[1].Value })
$superseded = @(($decisionsDoc -split '(?m)^### ') | Where-Object { $_ -match '^(DR-\d{3})' -and $_ -match '\*\*Superseded\*\*' } | ForEach-Object { ($_ -split '\s')[0] })
foreach ($m in $matrix) {
    if ($m.Basis -notmatch '^(OV|F|D)-\d{2}$') { Fail 'V8' "$($m.id) basis $($m.Basis) malformed" }
    if ($algorithmDoc -notmatch "\| $([regex]::Escape($m.Basis)) \|") { Fail 'V8' "$($m.id) basis $($m.Basis) not in 02-placement-algorithm.md" }
}
foreach ($rowm in [regex]::Matches($algorithmDoc, '\| ((?:OV|F|D)-\d{2}) \|[^\n]*\| (DR-\d{3}) \|')) {
    if ($rowm.Groups[2].Value -notin $drs) { Fail 'V8' "$($rowm.Groups[1].Value) references $($rowm.Groups[2].Value) which is not in decisions.md" }
    if ($rowm.Groups[2].Value -in $superseded) { Fail 'V8' "$($rowm.Groups[1].Value) references superseded $($rowm.Groups[2].Value)" }
}
foreach ($dr in $drs) { if ($dr -notin $superseded -and $algorithmDoc -notmatch "\b$dr\b") { Fail 'V8' "$dr is not referenced in 02-placement-algorithm.md" } }

# ---- V9 justification ----
foreach ($m in $matrix) { $j = $m.Justification; if (-not $j -or $j.Length -gt 120 -or $j -match '\||\r|\n') { Fail 'V9' "$($m.id) justification invalid" }; if ($j -notmatch "; $([regex]::Escape($m.Basis))$") { Fail 'V9' "$($m.id) justification does not end with its basis" } }

# ---- V10 stages never activate a None ----
foreach ($m in $matrix) {
    foreach ($l in $levelIds) {
        $base = $resolved[$m.id]["$l.default"]
        if ($base -eq 'None') { foreach ($s in $stages) { if ($resolved[$m.id]["$l.$s"] -ne 'None') { Fail 'V10' "$($m.id) $l.$s activated by stage" } } }
    }
}

# ---- V11 each shipped level a superset of the level it is based on (enabled set) ----
foreach ($s in $stages) { for ($i = 1; $i -lt 4; $i++) {
    foreach ($id in $resolved.Keys) {
        $lo = $resolved[$id]["$($levelIds[$i-1]).$s"]; $hi = $resolved[$id]["$($levelIds[$i]).$s"]
        if ($lo -ne 'None' -and $hi -eq 'None') { Fail 'V11' "$id enabled at $($levelIds[$i-1]).$s but None at $($levelIds[$i])" }
        if ($strict[$hi] -lt $strict[$lo]) { Fail 'V11' "$id is $lo at $($levelIds[$i-1]).$s but $hi at $($levelIds[$i])" }
    }
} }

# ---- V12 same fixed basis -> same ladder ----
$fixedBases = @('F-01','F-02','F-03','F-04','F-05','F-06','D-01','D-02','D-03','D-04','D-05','D-06','D-07','D-08','D-09','D-10','D-11','D-12','D-13')
foreach ($g in $matrix | Group-Object { $_.Basis } | Where-Object { $_.Name -in $fixedBases }) {
    $sig = $g.Group | ForEach-Object { "$($_.Essential)/$($_.Recommended)/$($_.Strict)/$($_.Complete)" } | Sort-Object -Unique
    if ($sig.Count -gt 1) { Fail 'V12' "basis $($g.Name) produces $($sig.Count) different ladders" }
}

# ---- V13 delta files compose to every cell, endpoints are sparse ----
# Level files (D27): the root lists the ids whose Essential action differs from the analyzer default; every other
# level lists the ids whose action differs from the level it is based on. Stage files: the ids whose stage column
# is not "=". Composition: chain = last level file on the basedOn path that mentions the id, else the analyzer
# default; then the stage entry applies when the chain result is not None (S-4). The result must equal resolved.json.
function Get-StageColumn($m, [string]$s) { switch ($s) { 'default' { return $m.Default } 'ci' { return $m.CI } 'vnext' { return $m.vNext } } }
$levelFiles = [ordered]@{}
foreach ($li in 0..3) {
    $f = [ordered]@{}
    foreach ($m in $matrix) {
        $lad = @($m.Essential, $m.Recommended, $m.Strict, $m.Complete)
        $below = if ($li -eq 0) { Get-AnalyzerDefault $byId[$m.id] } else { $lad[$li - 1] }
        if ($lad[$li] -ne $below) { $f[$m.id] = $lad[$li] }
    }
    $levelFiles[$levelIds[$li]] = $f
}
$stageFiles = [ordered]@{}
foreach ($s in ($stages | Select-Object -Skip 1)) {
    $f = [ordered]@{}
    foreach ($m in $matrix) { $col = Get-StageColumn $m $s; if ($col -ne '=') { $f[$m.id] = $col } }
    $stageFiles[$s] = $f
}
if ($levelFiles.Count -ne 4) { Fail 'V13' "expected 4 level files, built $($levelFiles.Count)" }
if ($stageFiles.Count -ne 2) { Fail 'V13' "expected 2 stage files, built $($stageFiles.Count)" }
foreach ($key in $levelFiles.Keys) { foreach ($id in $levelFiles[$key].Keys) {
    if (-not $byId.ContainsKey($id)) { Fail 'V13' "level file $key lists unknown id $id" }
    if ($levelFiles[$key][$id] -notin 'None','Hidden','Info','Warning','Error') { Fail 'V13' "level file $key has invalid action $($levelFiles[$key][$id]) for $id" }
} }
# a delta entry that equals what the chain already gives is redundant
foreach ($li in 1..3) {
    foreach ($id in $levelFiles[$levelIds[$li]].Keys) {
        $lad = @($mById[$id].Essential, $mById[$id].Recommended, $mById[$id].Strict, $mById[$id].Complete)
        if ($levelFiles[$levelIds[$li]][$id] -eq $lad[$li - 1]) { Fail 'V13' "delta $($levelIds[$li]) lists $id at the action of $($levelIds[$li-1])" }
    }
}
foreach ($s in $stageFiles.Keys) {
    $expectedIds = @($matrix | Where-Object { (Get-StageColumn $_ $s) -ne '=' } | ForEach-Object id)
    if ((@($stageFiles[$s].Keys) -join ',') -ne ($expectedIds -join ',')) { Fail 'V13' "stage file $s does not list exactly the non-= ids of its column" }
    foreach ($id in $stageFiles[$s].Keys) { if ($stageFiles[$s][$id] -eq '=' -or $stageFiles[$s][$id] -eq 'None') { Fail 'V13' "stage file $s has $($stageFiles[$s][$id]) for $id; a stage entry replaces an enabled action" } }
}
$endpoints = [ordered]@{}
foreach ($li in 0..3) { foreach ($s in $stages) {
    $key = "$($levelIds[$li]).$s"
    $ep = [ordered]@{}
    foreach ($m in $matrix) {
        $id = $m.id
        # chain: walk the level files from the root to this level; the last one mentioning the id wins
        $chain = $null
        foreach ($ci in 0..$li) { if ($levelFiles[$levelIds[$ci]].Contains($id)) { $chain = $levelFiles[$levelIds[$ci]][$id] } }
        $default = Get-AnalyzerDefault $byId[$id]
        $eff = if ($null -ne $chain) { $chain } else { $default }
        if ($s -ne 'default' -and $stageFiles[$s].Contains($id) -and $eff -ne 'None') { $eff = $stageFiles[$s][$id] }
        if ($eff -ne $resolved[$id][$key]) { Fail 'V13' "$id composes to $eff, matrix says $($resolved[$id][$key]) at $key" }
        if ($eff -ne $default) { $ep[$id] = $eff }
    }
    $endpoints[$key] = $ep
    foreach ($id in $ep.Keys) { if ($ep[$id] -eq (Get-AnalyzerDefault $byId[$id])) { Fail 'V13' "$key lists $id at its analyzer default" } }
    foreach ($id in 'LC0054','LC0089i') { if ($ep.Contains($id)) { Fail 'V13' "$key lists $id, which is None and disabled by default" } }
} }
if ($endpoints.Count -ne 12) { Fail 'V13' "expected 12 endpoints, built $($endpoints.Count)" }
$fileSizes = (@($levelFiles.Keys | ForEach-Object { "base/$_.ruleset.json=$($levelFiles[$_].Count)" }) + @($stageFiles.Keys | ForEach-Object { "stages/$_.json=$($stageFiles[$_].Count)" })) -join ' '
$sizes = ($endpoints.Keys | ForEach-Object { "$_=$($endpoints[$_].Count)" }) -join ' '

# ---- V14 README counts ----
$countsLines = Get-Content -LiteralPath (Join-Path $RulebookDir 'matrix' 'counts.md') | Where-Object { $_ -match '^\| (Essential|Recommended|Strict|Complete) \|' }
if ($countsLines.Count -ne 12) { Fail 'V14' "counts.md has $($countsLines.Count) count rows, expected 12" }
foreach ($line in $countsLines) { if ($readmeDoc -notmatch [regex]::Escape($line)) { Fail 'V14' "README.md is missing count row: $line" } }
$fileLines = Get-Content -LiteralPath (Join-Path $RulebookDir 'matrix' 'counts.md') | Where-Object { $_ -match '^\| `(base|stages)/' }
if ($fileLines.Count -ne 6) { Fail 'V14' "counts.md has $($fileLines.Count) file rows, expected 6" }
foreach ($line in $fileLines) { if ($readmeDoc -notmatch [regex]::Escape($line)) { Fail 'V14' "README.md is missing file row: $line" } }

# ---- report ----
if ($failures.Count) {
    Write-Host "FAILED: $($failures.Count) finding(s)" -ForegroundColor Red
    $failures | Select-Object -First 60 | ForEach-Object { Write-Host "  $_" }
    exit 1
}
Write-Host "All checks V1-V14 passed. Inventory $($inv.Count) ids, matrix $($matrix.Count) rows, $($twins.count) twin pairs."
Write-Host "Delta files (entries per file): $fileSizes"
Write-Host "Sparse endpoints (listed ids per file): $sizes"
exit 0
