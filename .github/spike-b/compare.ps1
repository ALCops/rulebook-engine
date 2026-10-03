#requires -Version 7.0
# Compares an id set (JSON array of objects with .id, or a text file of ids) with inventory.json, per prefix.
param([Parameter(Mandatory)][string]$Inventory, [Parameter(Mandatory)][string]$Ids, [string]$Label = 'method', [switch]$Defaults)
$inv = Get-Content -Raw $Inventory | ConvertFrom-Json
$found = if ($Ids -like '*.json') { Get-Content -Raw $Ids | ConvertFrom-Json } else { Get-Content $Ids | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ id = $_ } } }
$invIds = [Collections.Generic.HashSet[string]]::new([string[]]@($inv.id))
$gotIds = [Collections.Generic.HashSet[string]]::new([string[]]@($found.id))
$pfx = { param($i) ($i -replace '\d.*$', '') }
$prefixes = @($inv.id + $found.id | ForEach-Object { & $pfx $_ } | Sort-Object -Unique)
Write-Host "## $Label : $($gotIds.Count) ids, inventory $($invIds.Count), common $(@($found.id | Where-Object { $invIds.Contains($_) } | Sort-Object -Unique).Count)"
foreach ($p in $prefixes) {
    $i = @($inv.id | Where-Object { (& $pfx $_) -eq $p })
    $g = @($found.id | Where-Object { (& $pfx $_) -eq $p } | Sort-Object -Unique)
    $missing = @($i | Where-Object { -not $gotIds.Contains($_) })
    $extra = @($g | Where-Object { -not $invIds.Contains($_) })
    Write-Host ("{0,-4} inventory {1,4} found {2,4} missing {3,3} [{4}] extra {5,3} [{6}]" -f $p, $i.Count, $g.Count, $missing.Count, ($missing -join ' '), $extra.Count, ($extra -join ' '))
}
if ($Defaults) {
    $byId = @{}; foreach ($f in $found) { $byId[$f.id] = $f }
    $diff = foreach ($r in $inv) {
        $f = $byId[$r.id]; if (-not $f) { continue }
        if ($f.defaultSeverity -ne $r.default -or [bool]$f.enabledByDefault -ne [bool]$r.enabled) { "$($r.id): inventory $($r.default)/$($r.enabled) vs $($f.defaultSeverity)/$($f.enabledByDefault)" }
    }
    Write-Host "default/enabled differences vs inventory: $(@($diff).Count)"
    $diff | ForEach-Object { Write-Host "  $_" }
    $t = @($found | Where-Object { -not $_.title }).Count; $h = @($found | Where-Object { -not $_.helpLinkUri }).Count
    Write-Host "ids without title: $t; without helpLinkUri: $h"
}
