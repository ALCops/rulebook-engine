# Helpers for the suites that work on organization rulebook repositories (tests/fixtures/repos/).
# Dot-source in BeforeAll. Complete fixtures (valid-minimal, stale-endpoints, update-org) are full repositories on disk; every
# other folder is an overlay that New-FixtureRepo copies over valid-minimal. Variants that need no folder are
# mutations in TestDrive with Edit-FixtureJson. The template fixtures (tests/fixtures/templates/v1, v2) are copied with
# Copy-FixtureTemplate; New-BareFixtureRepo and Add-RejectPushHook stand in for the GitHub side of the update.

$script:FixtureReposRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'fixtures' 'repos'

function Copy-FixtureTree {
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Destination)
    $sourceFull = (Resolve-Path -LiteralPath $Source).ProviderPath
    foreach ($file in Get-ChildItem -LiteralPath $sourceFull -Recurse -File -Force) {
        $relative = [System.IO.Path]::GetRelativePath($sourceFull, $file.FullName)
        $target = Join-Path $Destination $relative
        $parent = Split-Path -Parent $target
        if (-not (Test-Path -LiteralPath $parent)) { [void](New-Item -ItemType Directory -Path $parent -Force) }
        Copy-Item -LiteralPath $file.FullName -Destination $target -Force
    }
}

function New-FixtureRepo {
    # Copies valid-minimal to Destination, then the overlay folder Name over it (Name 'valid-minimal' or a complete
    # fixture copies just that folder). Returns the destination path.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helper; writes only to TestDrive')]
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Destination)
    $complete = @('valid-minimal', 'stale-endpoints', 'update-org')
    if (-not (Test-Path -LiteralPath $Destination)) { [void](New-Item -ItemType Directory -Path $Destination -Force) }
    if ($Name -in $complete) {
        Copy-FixtureTree -Source (Join-Path $script:FixtureReposRoot $Name) -Destination $Destination
    } else {
        $overlay = Join-Path $script:FixtureReposRoot $Name
        if (-not (Test-Path -LiteralPath $overlay -PathType Container)) { throw "Unknown fixture '$Name'" }
        Copy-FixtureTree -Source (Join-Path $script:FixtureReposRoot 'valid-minimal') -Destination $Destination
        Copy-FixtureTree -Source $overlay -Destination $Destination
    }
    return (Resolve-Path -LiteralPath $Destination).ProviderPath
}

function Write-FixtureText {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { [void](New-Item -ItemType Directory -Path $parent -Force) }
    $normalized = $Text -replace "`r`n", "`n"
    if (-not $normalized.EndsWith("`n")) { $normalized += "`n" }
    [System.IO.File]::WriteAllText($Path, $normalized, [System.Text.UTF8Encoding]::new($false))
}

function Edit-FixtureJson {
    # Reads Path as a hashtable, runs Script with it as $args[0] (and $_), writes it back with ConvertTo-Json.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][scriptblock]$Script)
    $json = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable -Depth 10
    $null = ForEach-Object -InputObject $json -Process $Script
    Write-FixtureText -Path $Path -Text ($json | ConvertTo-Json -Depth 10)
}

function Invoke-FixtureGit {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string[]]$Arguments)
    $output = & git -C $Root -c user.name=Fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false -c core.autocrlf=false @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed: $output" }
    return $output
}

function New-FixtureGitRepo {
    # git init in Root (when it is not a repository yet), stage everything and commit. Returns the commit sha.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helper; writes only to TestDrive')]
    param([Parameter(Mandatory)][string]$Root, [string]$Message = 'fixture')
    if (-not (Test-Path -LiteralPath (Join-Path $Root '.git'))) {
        $null = Invoke-FixtureGit -Root $Root -Arguments @('init', '-q', '-b', 'main')
    }
    $null = Invoke-FixtureGit -Root $Root -Arguments @('add', '-A')
    $null = Invoke-FixtureGit -Root $Root -Arguments @('commit', '-q', '--allow-empty', '-m', $Message)
    return (Invoke-FixtureGit -Root $Root -Arguments @('rev-parse', 'HEAD')) | Select-Object -Last 1
}

function New-SyntheticRulebook {
    # A synthetic rulebook for the performance smoke test: IdCount catalog ids over the 12 prefixes, a root level
    # with about 55 percent of them, two further levels, stages default, CI and vNext, a few overrides and
    # quarantine entries. Deterministic. Returns the destination path.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helper; writes only to TestDrive')]
    param([int]$IdCount = 650, [Parameter(Mandatory)][string]$Destination)
    $prefixes = @('AL', 'AA', 'AW', 'PTE', 'AS', 'PC', 'AC', 'LC', 'DC', 'FC', 'TA', 'CM')
    $severities = @('Error', 'Warning', 'Info', 'Hidden')
    $actions = @('Error', 'Warning', 'Info', 'Hidden', 'None')
    $ids = for ($i = 0; $i -lt $IdCount; $i++) { '{0}{1:0000}' -f $prefixes[$i % $prefixes.Count], ([math]::Floor($i / $prefixes.Count) + 1) }

    $rule = { param($id, $action) '    { "id": "' + $id + '", "action": "' + $action + '" }' }
    $writeRuleset = {
        param($path, $name, $lines)
        $body = if ($lines.Count -eq 0) { '  "rules": []' } else { "  `"rules`": [`n" + ($lines -join ",`n") + "`n  ]" }
        Write-FixtureText -Path $path -Text ("{`n  `"name`": `"$name`",`n$body`n}")
    }

    $catalog = for ($i = 0; $i -lt $ids.Count; $i++) {
        '    { "id": "' + $ids[$i] + '", "defaultSeverity": "' + $severities[$i % 4] + '", "enabledByDefault": ' + $(if ($i % 9 -eq 0) { 'false' } else { 'true' }) + ' }'
    }
    Write-FixtureText -Path (Join-Path $Destination 'catalog' 'diagnostics.json') -Text ("{`n  `"version`": 1,`n  `"diagnostics`": [`n" + ($catalog -join ",`n") + "`n  ]`n}")

    $root = @(); $mid = @(); $top = @(); $ci = @(); $vnext = @()
    for ($i = 0; $i -lt $ids.Count; $i++) {
        if ($i % 20 -lt 11) { $root += & $rule $ids[$i] $actions[($i + 1) % 5] }
        if ($i % 7 -eq 0) { $mid += & $rule $ids[$i] $actions[($i + 2) % 5] }
        if ($i % 11 -eq 0) { $top += & $rule $ids[$i] $actions[($i + 3) % 5] }
        if ($i % 13 -eq 0) { $ci += & $rule $ids[$i] 'Info' }
        if ($i % 6 -eq 0) { $vnext += & $rule $ids[$i] 'Error' }
    }
    & $writeRuleset (Join-Path $Destination 'base' 'base.ruleset.json') 'Rulebook Base' $root
    & $writeRuleset (Join-Path $Destination 'base' 'mid.ruleset.json') 'Rulebook Mid' $mid
    & $writeRuleset (Join-Path $Destination 'base' 'top.ruleset.json') 'Rulebook Top' $top
    & $writeRuleset (Join-Path $Destination 'stages' 'ci.json') 'Rulebook stage CI' $ci
    & $writeRuleset (Join-Path $Destination 'stages' 'vnext.json') 'Rulebook stage vNext' $vnext

    $overrides = for ($i = 3; $i -lt $ids.Count; $i += 97) {
        '    { "id": "' + $ids[$i] + '", "action": "Warning", "levels": ["*"], "stages": ["ci"], "justification": "Synthetic" }'
    }
    Write-FixtureText -Path (Join-Path $Destination 'overrides.json') -Text ("{`n  `"rules`": [`n" + ($overrides -join ",`n") + "`n  ]`n}")
    $quarantine = for ($i = 5; $i -lt $ids.Count; $i += 61) { '    { "id": "' + $ids[$i] + '" }' }
    foreach ($stage in 'default', 'ci', 'vnext') {
        Write-FixtureText -Path (Join-Path $Destination "quarantine.$stage.json") -Text ("{`n  `"rules`": [`n" + ($quarantine -join ",`n") + "`n  ]`n}")
    }
    $settings = @'
{
  "templateUrl": "https://github.com/ALCops/rulebook@main",
  "baseUrl": "https://contoso.github.io/rulebook",
  "publish": { "target": "pages" },
  "twins": "both",
  "quarantine": { "stages": null, "prereleaseStages": null },
  "levels": [
    { "name": "Base" },
    { "name": "Mid", "basedOn": "Base" },
    { "name": "Top", "basedOn": "Mid" }
  ],
  "stages": [ { "name": "default" }, { "name": "CI" }, { "name": "vNext" } ]
}
'@
    Write-FixtureText -Path (Join-Path $Destination '.github' 'Rulebook-Settings.json') -Text $settings
    return (Resolve-Path -LiteralPath $Destination).ProviderPath
}

$script:FixtureTemplatesRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'fixtures' 'templates'

function Copy-FixtureTemplate {
    # Copies the template fixture Name (v1, v2) to Destination. Returns the destination path.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helper; writes only to TestDrive')]
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Destination)
    $source = Join-Path $script:FixtureTemplatesRoot $Name
    if (-not (Test-Path -LiteralPath $source -PathType Container)) { throw "Unknown template fixture '$Name'" }
    if (-not (Test-Path -LiteralPath $Destination)) { [void](New-Item -ItemType Directory -Path $Destination -Force) }
    Copy-FixtureTree -Source $source -Destination $Destination
    return (Resolve-Path -LiteralPath $Destination).ProviderPath
}

function New-BareFixtureRepo {
    # A bare repository at Destination whose main branch holds the files of Source (one commit), the stand-in for an
    # organization repository on GitHub. Returns the bare path.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helper; writes only to TestDrive')]
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Destination)
    $work = "$Destination.work"
    Copy-FixtureTree -Source $Source -Destination $work
    $null = New-FixtureGitRepo -Root $work -Message 'initial'
    $parent = Split-Path -Parent $Destination
    $null = Invoke-FixtureGit -Root $parent -Arguments @('clone', '-q', '--bare', $work, $Destination)
    Remove-Item -LiteralPath $work -Recurse -Force
    return (Resolve-Path -LiteralPath $Destination).ProviderPath
}

function Add-RejectPushHook {
    # A pre-receive hook in the bare repository BarePath that refuses every push to refs/heads/<Branch>, the stand-in
    # for branch protection.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helper; writes only to TestDrive')]
    param([Parameter(Mandatory)][string]$BarePath, [string]$Branch = 'main')
    $hook = Join-Path $BarePath 'hooks' 'pre-receive'
    $script = "#!/bin/sh`nwhile read old new ref; do`n  if [ `"`$ref`" = `"refs/heads/$Branch`" ]; then echo `"$Branch is protected`" >&2; exit 1; fi`ndone`nexit 0`n"
    [System.IO.File]::WriteAllText($hook, $script, [System.Text.UTF8Encoding]::new($false))
    if (-not $IsWindows) { [System.IO.File]::SetUnixFileMode($hook, [System.IO.UnixFileMode]'UserRead, UserWrite, UserExecute, GroupRead, GroupExecute, OtherRead, OtherExecute') }
}
