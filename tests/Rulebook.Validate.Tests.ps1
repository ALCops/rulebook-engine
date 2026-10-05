# Validate suite for WP03 (#5): Test-Rulebook checks C1 to C15 (docs/ARCHITECTURE.md section 5.3) against the
# repository fixtures under tests/fixtures/repos/ and mutations of valid-minimal in TestDrive.

BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:repoRoot 'modules' 'Rulebook.Generate.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'modules' 'Rulebook.Validate.psd1') -Force
    . (Join-Path $PSScriptRoot 'Helpers' 'RepoFixture.ps1')

    function Copy-Fixture {
        param([string]$Name = 'valid-minimal')
        return New-FixtureRepo -Name $Name -Destination (Join-Path $TestDrive ([guid]::NewGuid().ToString('n').Substring(0, 12)))
    }

    function Get-FindingText {
        # "Rule severity file id" per finding; '-' for a $null file or id.
        param([object[]]$Findings)
        return @($Findings | ForEach-Object {
                '{0} {1} {2} {3}' -f $_.Rule, $_.Severity, $(if ($_.File) { $_.File } else { '-' }), $(if ($_.Id) { $_.Id } else { '-' })
            })
    }

    function Get-RuleList {
        param([object[]]$Findings)
        return @($Findings | ForEach-Object Rule | Select-Object -Unique)
    }

    function Edit-SettingsFile {
        param([string]$Root, [scriptblock]$Script)
        Edit-FixtureJson -Path (Join-Path $Root '.github' 'Rulebook-Settings.json') -Script $Script
    }

    $script:skipMessage = 'Regeneration check skipped*'
}

AfterAll {
    Remove-Module Rulebook.Validate, Rulebook.Generate -ErrorAction SilentlyContinue
}

Describe 'Test-Rulebook on valid-minimal' {
    It 'reports no finding' {
        @(Test-Rulebook -RepositoryRoot (Join-Path $PSScriptRoot 'fixtures' 'repos' 'valid-minimal')).Count | Should-Be 0
    }

    It 'writes the findings as a JSON array with -Json' {
        $path = Join-Path $TestDrive 'findings.json'
        $findings = @(Test-Rulebook -RepositoryRoot (Copy-Fixture 'stale-endpoints') -Json $path)
        $json = @(Get-Content -LiteralPath $path -Raw | ConvertFrom-Json)
        $json.Count | Should-Be $findings.Count
        (@($json[0].PSObject.Properties.Name) -join ',') | Should-Be 'Rule,Severity,File,Id,Message'
        $json[0].File | Should-Be 'rulesets/recommended.ci.ruleset.json'
        [System.IO.File]::ReadAllText($path).Contains("`r") | Should-BeFalse
    }

    It 'writes an empty array when there is no finding' {
        $path = Join-Path $TestDrive 'empty.json'
        $null = Test-Rulebook -RepositoryRoot (Copy-Fixture) -Json $path
        (Get-Content -LiteralPath $path -Raw).Trim() | Should-Be '[]'
    }

    It 'orders findings by rule, file and id' {
        $root = Copy-Fixture 'unknown-id'
        Edit-FixtureJson -Path (Join-Path $root 'stages' 'ci.json') -Script { $_.rules += @{ id = 'AA0999'; action = 'Info' } }
        $null = Update-RulebookEndpoints -RepositoryRoot $root
        $text = Get-FindingText (Test-Rulebook -RepositoryRoot $root)
        ($text -join ',') | Should-Be 'C7 warning base/complete.ruleset.json LC0999,C7 warning stages/ci.json AA0999'
    }
}

Describe 'C1 parse and schema profile' {
    It 'reports a file that is not JSON once and excludes it from later checks' {
        $root = Copy-Fixture
        Write-FixtureText -Path (Join-Path $root 'base' 'strict.ruleset.json') -Text '{ "name": "Rulebook Strict", "rules": [ '
        $findings = @(Test-Rulebook -RepositoryRoot $root)
        (Get-FindingText ($findings | Where-Object File -EQ 'base/strict.ruleset.json')) | Should-BeCollection @('C1 error base/strict.ruleset.json -')
        $skip = $findings | Where-Object Rule -EQ 'C12'
        $skip.Severity | Should-Be 'warning'
        $skip.Message | Should-BeLikeString $skipMessage
    }

    It 'reports a schema failure in an endpoint (endpoint-with-include)' {
        $findings = @(Test-Rulebook -RepositoryRoot (Copy-Fixture 'endpoint-with-include'))
        $c1 = $findings | Where-Object Rule -EQ 'C1'
        $c1.File | Should-Be 'rulesets/strict.ruleset.json'
        $c1.Message | Should-BeLikeString '*ruleset.endpoint.schema.json*includedRuleSets*'
    }

    It 'reports a quarantine entry with an action' {
        $root = Copy-Fixture
        Write-FixtureText -Path (Join-Path $root 'quarantine.ci.json') -Text '{ "rules": [ { "id": "LC0099", "action": "None" } ] }'
        (Get-FindingText (Test-Rulebook -RepositoryRoot $root)) | Should-BeCollection @('C1 error quarantine.ci.json -', 'C12 warning - -')
    }
}

Describe 'C2 duplicate ids' {
    It 'reports an id listed twice (duplicate-id)' {
        (Get-FindingText (Test-Rulebook -RepositoryRoot (Copy-Fixture 'duplicate-id'))) | Should-BeCollection @('C2 error base/strict.ruleset.json AA0137', 'C12 warning - -')
    }

    It 'reports a twin side in two pairs' {
        $root = Copy-Fixture
        Edit-FixtureJson -Path (Join-Path $root 'base' 'twins.json') -Script {
            $_.pairs += @{ pte = 'PTE0003'; appsource = 'AS0001'; title = 'again' }
            $_.count = 3
        }
        $findings = @(Test-Rulebook -RepositoryRoot $root)
        (Get-FindingText ($findings | Where-Object Rule -EQ 'C2')) | Should-BeCollection @('C2 error base/twins.json PTE0003')
    }
}

Describe 'C3 includes and generalAction' {
    It 'reports an include in an endpoint (endpoint-with-include)' {
        $findings = @(Test-Rulebook -RepositoryRoot (Copy-Fixture 'endpoint-with-include'))
        (Get-RuleList $findings) | Should-BeCollection @('C1', 'C3', 'C12')
        ($findings | Where-Object Rule -EQ 'C3').Message | Should-BeLikeString 'includedRuleSets is not allowed*'
        ($findings | Where-Object Rule -EQ 'C12').Message | Should-BeLikeString '*would be modified*'
    }

    It 'reports generalAction in a level file' {
        $root = Copy-Fixture
        Edit-FixtureJson -Path (Join-Path $root 'base' 'strict.ruleset.json') -Script { $_.generalAction = 'Warning' }
        $c3 = @(Test-Rulebook -RepositoryRoot $root | Where-Object Rule -EQ 'C3')
        $c3.Count | Should-Be 1
        $c3[0].File | Should-Be 'base/strict.ruleset.json'
    }

    It 'reports a skeleton with two includes' {
        $root = Copy-Fixture
        Write-FixtureText -Path (Join-Path $root 'skeletons' 'strict.ci.ruleset.json') -Text @'
{
  "name": "Rulebook Strict / CI",
  "includedRuleSets": [ { "action": "Default", "path": "{BASEURL}/rulesets/strict.ci.ruleset.json" }, { "action": "Default", "path": "{BASEURL}/rulesets/strict.ruleset.json" } ],
  "rules": []
}
'@
        $c3 = @(Test-Rulebook -RepositoryRoot $root | Where-Object Rule -EQ 'C3')
        $c3.Count | Should-Be 1
        $c3[0].Message | Should-BeLikeString '*exactly one include*2*'
    }
}

Describe 'C4 rule actions' {
    It 'reports action Default and names it' {
        $root = Copy-Fixture
        Edit-FixtureJson -Path (Join-Path $root 'stages' 'ci.json') -Script { ($_.rules | Where-Object { $_.id -eq 'AL1026' }).action = 'Default' }
        $findings = @(Test-Rulebook -RepositoryRoot $root)
        $c4 = @($findings | Where-Object Rule -EQ 'C4')
        (Get-FindingText $c4) | Should-BeCollection @('C4 error stages/ci.json AL1026')
        $c4[0].Message | Should-BeLikeString "*'Default'*Default is not a rule action*"
        ($findings | Where-Object Rule -EQ 'C12').Message | Should-BeLikeString $skipMessage
    }

    It 'checks overrides.json too' {
        $root = Copy-Fixture
        Edit-FixtureJson -Path (Join-Path $root 'overrides.json') -Script { $_.rules[0].action = 'Default' }
        (Get-FindingText (Test-Rulebook -RepositoryRoot $root | Where-Object Rule -EQ 'C4')) | Should-BeCollection @('C4 error overrides.json AA0072')
    }
}

Describe 'C5 settings' {
    It 'reports <Name> with one C5 finding and skips C12' -ForEach @(
        @{ Name = 'missing-default-stage'; Message = 'stages has no default stage*' }
        @{ Name = 'basedon-cycle'; Message = 'basedOn cycle: recommended -> strict -> recommended' }
        @{ Name = 'bad-twins-value'; Message = "twins is 'all'*" }
    ) {
        $findings = @(Test-Rulebook -RepositoryRoot (Copy-Fixture $Name))
        (Get-FindingText $findings) | Should-BeCollection @('C5 error .github/Rulebook-Settings.json -', 'C12 warning - -')
        ($findings | Where-Object Rule -EQ 'C5').Message | Should-BeLikeString $Message
        ($findings | Where-Object Rule -EQ 'C12').Message | Should-BeLikeString 'Regeneration check skipped: fix the C5 errors first*'
    }

    It 'reports <Case> once' -ForEach @(
        @{ Case = 'a duplicate slug'; Message = "levels slug 'strict' is used twice"; Edit = { $_.levels += @{ name = 'STRICT'; basedOn = 'Recommended' } } }
        @{ Case = 'a name that is not a slug'; Message = "stages entry 'Night.ly' does not lowercase to a slug*"; Edit = { $_.stages += @{ name = 'Night.ly' } } }
        @{ Case = 'a quarantine value that is not a stage'; Message = "quarantine.stages names 'nightly'*"; Edit = { $_.quarantine.stages = @('nightly') } }
        @{ Case = 'a baseUrl with a trailing slash'; Message = 'baseUrl ends with a slash'; Edit = { $_.baseUrl = 'https://contoso.github.io/rulebook/' } }
        @{ Case = 'an unresolved basedOn'; Message = "Unresolved basedOn 'paranoid' of level 'Complete'"; Edit = { $_.levels[3].basedOn = 'Paranoid' } }
        @{ Case = 'a schema failure the explicit checks do not cover'; Message = '*rulebook-settings.schema.json*'; Edit = { $_.unknownKey = 1 } }
    ) {
        $root = Copy-Fixture
        Edit-SettingsFile -Root $root -Script $Edit
        $c5 = @(Test-Rulebook -RepositoryRoot $root | Where-Object Rule -EQ 'C5')
        $c5.Count | Should-Be 1
        $c5[0].Message | Should-BeLikeString $Message
    }

    It 'stops after a missing settings file' {
        $root = Copy-Fixture
        Remove-Item -LiteralPath (Join-Path $root '.github' 'Rulebook-Settings.json')
        (Get-FindingText (Test-Rulebook -RepositoryRoot $root)) | Should-BeCollection @('C5 error .github/Rulebook-Settings.json -')
    }
}

Describe 'C6 files the settings name' {
    It 'reports stages/default.json once' {
        $root = Copy-Fixture
        Write-FixtureText -Path (Join-Path $root 'stages' 'default.json') -Text '{ "name": "Rulebook stage default", "rules": [] }'
        (Get-FindingText (Test-Rulebook -RepositoryRoot $root)) | Should-BeCollection @('C6 error stages/default.json -', 'C12 warning - -')
    }

    It 'reports a missing level file once, not as an unresolved basedOn' {
        $root = Copy-Fixture
        Remove-Item -LiteralPath (Join-Path $root 'base' 'strict.ruleset.json')
        (Get-FindingText (Test-Rulebook -RepositoryRoot $root)) | Should-BeCollection @('C6 error base/strict.ruleset.json -', 'C12 warning - -')
    }

    It 'reports a missing stage file' {
        $root = Copy-Fixture
        Remove-Item -LiteralPath (Join-Path $root 'stages' 'vnext.json')
        (Get-FindingText (Test-Rulebook -RepositoryRoot $root)) | Should-BeCollection @('C6 error stages/vnext.json -', 'C12 warning - -')
    }
}

Describe 'C7 catalog coverage' {
    It 'is a warning while catalog/scan-state.json is absent (unknown-id)' {
        (Get-FindingText (Test-Rulebook -RepositoryRoot (Copy-Fixture 'unknown-id'))) | Should-BeCollection @('C7 warning base/complete.ruleset.json LC0999')
    }

    It 'is an error once catalog/scan-state.json exists' {
        $root = Copy-Fixture 'unknown-id'
        Write-FixtureText -Path (Join-Path $root 'catalog' 'scan-state.json') -Text '{}'
        (Get-FindingText (Test-Rulebook -RepositoryRoot $root)) | Should-BeCollection @('C7 error base/complete.ruleset.json LC0999')
    }

    It 'covers overrides, quarantine and twins' {
        $root = Copy-Fixture
        Edit-FixtureJson -Path (Join-Path $root 'overrides.json') -Script { $_.rules += @{ id = 'TA0999'; action = 'Info'; levels = @('strict'); stages = @('*') } }
        Edit-FixtureJson -Path (Join-Path $root 'quarantine.default.json') -Script { $_.rules += @{ id = 'CM0999' } }
        $null = Update-RulebookEndpoints -RepositoryRoot $root
        (Get-FindingText (Test-Rulebook -RepositoryRoot $root)) | Should-BeCollection @('C7 warning overrides.json TA0999', 'C7 warning quarantine.default.json CM0999')
    }
}

Describe 'C8 stage entry no published level enables' {
    It 'reports a stage entry that is None in every published level' {
        $root = Copy-Fixture
        Edit-SettingsFile -Root $root -Script { $_.levels = @($_.levels[0]) }
        Edit-FixtureJson -Path (Join-Path $root 'stages' 'ci.json') -Script { $_.rules += @{ id = 'AL0200'; action = 'Info' } }
        $c8 = @(Test-Rulebook -RepositoryRoot $root | Where-Object Rule -EQ 'C8')
        (Get-FindingText $c8) | Should-BeCollection @('C8 warning stages/ci.json AL0200', 'C8 warning stages/ci.json AL0432', 'C8 warning stages/vnext.json LC0029')
    }
}

Describe 'C9 dead weight' {
    It 'reports a level entry equal to what its basedOn level gives' {
        $root = Copy-Fixture
        Edit-FixtureJson -Path (Join-Path $root 'base' 'recommended.ruleset.json') -Script { $_.rules += @{ id = 'AL0001'; action = 'Error' } }
        (Get-FindingText (Test-Rulebook -RepositoryRoot $root)) | Should-BeCollection @('C9 warning base/recommended.ruleset.json AL0001')
    }

    It 'reports a level file nobody references, and clears with unusedRulebookFiles' {
        $root = Copy-Fixture
        Write-FixtureText -Path (Join-Path $root 'base' 'orphan.ruleset.json') -Text '{ "name": "Rulebook Orphan", "rules": [] }'
        (Get-FindingText (Test-Rulebook -RepositoryRoot $root)) | Should-BeCollection @('C9 warning base/orphan.ruleset.json -')
        Edit-SettingsFile -Root $root -Script { $_.unusedRulebookFiles = @('base/orphan.ruleset.json') }
        @(Test-Rulebook -RepositoryRoot $root).Count | Should-Be 0
    }

    It 'does not report a level file a published chain reaches' {
        $root = Copy-Fixture
        Edit-SettingsFile -Root $root -Script { $_.levels = @($_.levels | Where-Object { $_.name -ne 'Essential' }) }
        $null = Update-RulebookEndpoints -RepositoryRoot $root
        @(Test-Rulebook -RepositoryRoot $root | Where-Object Rule -EQ 'C9').Count | Should-Be 0
    }
}

Describe 'C10 override selectors' {
    It 'reports an unknown level slug (bad-selector)' {
        $findings = @(Test-Rulebook -RepositoryRoot (Copy-Fixture 'bad-selector'))
        (Get-FindingText $findings) | Should-BeCollection @('C10 error overrides.json LC0001')
        $findings[0].Message | Should-BeLikeString "*unknown level 'paranoid'*"
    }

    It 'reports a schema failure' {
        $root = Copy-Fixture
        Edit-FixtureJson -Path (Join-Path $root 'overrides.json') -Script { $_.rules[0].levels = @('*', 'strict') }
        (Get-FindingText (Test-Rulebook -RepositoryRoot $root)) | Should-BeCollection @('C10 error overrides.json -', 'C12 warning - -')
    }
}

Describe 'C11 sparse and complete endpoints' {
    It 'reports an endpoint entry at its catalog default (endpoint-lists-default)' {
        $findings = @(Test-Rulebook -RepositoryRoot (Copy-Fixture 'endpoint-lists-default'))
        (Get-FindingText $findings) | Should-BeCollection @('C11 error rulesets/recommended.ruleset.json AL0200', 'C12 error rulesets/recommended.ruleset.json -')
    }

    It 'leaves a missing or extra endpoint to C12 when C12 runs (one finding per cause)' {
        $root = Copy-Fixture
        Remove-Item -LiteralPath (Join-Path $root 'rulesets' 'strict.ci.ruleset.json')
        Write-FixtureText -Path (Join-Path $root 'rulesets' 'extra.ruleset.json') -Text '{ "name": "x", "rules": [] }'
        $findings = @(Test-Rulebook -RepositoryRoot $root)
        (Get-FindingText $findings) | Should-BeCollection @('C12 error rulesets/extra.ruleset.json -', 'C12 error rulesets/strict.ci.ruleset.json -')
        (@($findings | ForEach-Object Message) -join ' ') | Should-BeLikeString '*would be deleted*would be created*'
    }

    It 'reports a missing or extra endpoint when C12 is skipped' {
        $root = Copy-Fixture
        Edit-FixtureJson -Path (Join-Path $root 'base' 'twins.json') -Script { $_.count = 3 }
        Remove-Item -LiteralPath (Join-Path $root 'rulesets' 'strict.ci.ruleset.json')
        Write-FixtureText -Path (Join-Path $root 'rulesets' 'extra.ruleset.json') -Text '{ "name": "x", "rules": [] }'
        (Get-FindingText (Test-Rulebook -RepositoryRoot $root | Where-Object Rule -EQ 'C11')) |
            Should-BeCollection @('C11 error rulesets/extra.ruleset.json -', 'C11 error rulesets/strict.ci.ruleset.json -')
    }

    It 'checks skeletons/ when it exists' {
        $root = Copy-Fixture
        Write-FixtureText -Path (Join-Path $root 'skeletons' 'strict.ci.ruleset.json') -Text '{ "name": "Rulebook Strict / CI", "includedRuleSets": [ { "action": "Default", "path": "{BASEURL}/rulesets/strict.ci.ruleset.json" } ], "rules": [] }'
        $c11 = @(Test-Rulebook -RepositoryRoot $root | Where-Object Rule -EQ 'C11')
        $c11.Count | Should-Be 11
        @($c11 | Where-Object File -EQ 'skeletons/strict.default.ruleset.json').Count | Should-Be 1
    }
}

Describe 'C12 regeneration check' {
    It 'reports a stale endpoint (stale-endpoints)' {
        $findings = @(Test-Rulebook -RepositoryRoot (Copy-Fixture 'stale-endpoints'))
        (Get-FindingText $findings) | Should-BeCollection @('C12 error rulesets/recommended.ci.ruleset.json -')
        $findings[0].Message | Should-BeLikeString 'rulesets/recommended.ci.ruleset.json would be modified*'
    }

    It '<Name> reports C12 only before regeneration and nothing after' -ForEach @(@{ Name = 'custom-level' }, @{ Name = 'alias-level' }, @{ Name = 'twins-appsource' }, @{ Name = 'twins-pte' }) {
        $root = Copy-Fixture $Name
        $before = @(Test-Rulebook -RepositoryRoot $root)
        $before.Count | Should-BeGreaterThan 0
        (Get-RuleList $before) | Should-BeCollection @('C12')
        $null = Update-RulebookEndpoints -RepositoryRoot $root
        @(Test-Rulebook -RepositoryRoot $root).Count | Should-Be 0
    }

    It 'is skipped with one warning when the catalog is missing' {
        $root = Copy-Fixture
        Remove-Item -LiteralPath (Join-Path $root 'catalog' 'diagnostics.json')
        (Get-FindingText (Test-Rulebook -RepositoryRoot $root)) | Should-BeCollection @('C12 warning - -', 'C14 error catalog/diagnostics.json -')
    }
}

Describe 'C13 quarantine housekeeping' {
    It 'reports a quarantined id a level file mentions' {
        $root = Copy-Fixture
        Edit-FixtureJson -Path (Join-Path $root 'quarantine.ci.json') -Script { $_.rules += @{ id = 'AL0200' } }
        (Get-FindingText (Test-Rulebook -RepositoryRoot $root)) | Should-BeCollection @('C13 warning quarantine.ci.json AL0200')
    }
}

Describe 'C14 catalog and twins' {
    It 'reports <Case>' -ForEach @(
        @{ Case = 'a twins count that differs from the pairs'; File = 'base/twins.json'; Edit = { param($root) Edit-FixtureJson -Path (Join-Path $root 'base' 'twins.json') -Script { $_.count = 3 } } }
        @{ Case = 'a catalog entry without enabledByDefault'; File = 'catalog/diagnostics.json'; Edit = { param($root) Edit-FixtureJson -Path (Join-Path $root 'catalog' 'diagnostics.json') -Script { $_.diagnostics[0].Remove('enabledByDefault') } } }
        @{ Case = 'a missing twins file with twins appsource'; File = 'base/twins.json'; Edit = { param($root) Remove-Item -LiteralPath (Join-Path $root 'base' 'twins.json'); Edit-SettingsFile -Root $root -Script { $_.twins = 'appsource' } } }
    ) {
        $root = Copy-Fixture
        & $Edit $root
        $findings = @(Test-Rulebook -RepositoryRoot $root)
        (Get-FindingText ($findings | Where-Object Rule -EQ 'C14')) | Should-BeCollection @("C14 error $File -")
        ($findings | Where-Object Rule -EQ 'C12').Message | Should-BeLikeString $skipMessage
    }

    It 'accepts a missing twins file with twins both' {
        $root = Copy-Fixture
        Remove-Item -LiteralPath (Join-Path $root 'base' 'twins.json')
        @(Test-Rulebook -RepositoryRoot $root).Count | Should-Be 0
    }
}

Describe 'C15 stage entry dead while quarantined' {
    It 'reports the stage entry and no C12 (quarantined-stage-entry)' {
        $findings = @(Test-Rulebook -RepositoryRoot (Copy-Fixture 'quarantined-stage-entry'))
        (Get-FindingText $findings) | Should-BeCollection @('C15 warning stages/ci.json LC0099')
        $findings[0].Message | Should-BeLikeString '*D41*'
    }

    It 'does not report it once a level file mentions the id' {
        $root = Copy-Fixture 'quarantined-stage-entry'
        Edit-FixtureJson -Path (Join-Path $root 'base' 'complete.ruleset.json') -Script { $_.rules += @{ id = 'LC0099'; action = 'Error' } }
        $null = Update-RulebookEndpoints -RepositoryRoot $root
        (Get-RuleList (Test-Rulebook -RepositoryRoot $root)) | Should-BeCollection @('C13')
    }
}
