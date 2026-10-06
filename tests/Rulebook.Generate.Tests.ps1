# Generate suite for WP03 (#5) and #42: modules/Rulebook.Generate against the repository fixtures under
# tests/fixtures/repos/ (see tests/Helpers/RepoFixture.ps1). Expected endpoint contents are derived by hand from the
# precedence in docs/rulebook/composition.md section 3 (D41); worked through in docs/reference/effective-diff.md.

BeforeDiscovery {
    $script:gitMissing = $null -eq (Get-Command git -ErrorAction SilentlyContinue)

    # Precedence table (criterion 1 of #5): each case builds the explicit inputs of Get-EffectiveAction.
    # Chain and StageDelta map id -> action; Quarantine lists ids; Overrides are entries for the case's id in file order.
    $script:precedenceCases = @(
        @{ Name = 'override beats twins'; Id = 'PTE0003'; Level = 'recommended'; Stage = 'ci'; TwinsSetting = 'appsource'
            Overrides = @(@{ action = 'Warning'; levels = @('*'); stages = @('*'); justification = 'Keep the PTE side' })
            Action = 'Warning'; Source = 'override'; Detail = 'Keep the PTE side'
        }
        @{ Name = 'twins beats the stage delta'; Id = 'PTE0003'; Level = 'recommended'; Stage = 'ci'; TwinsSetting = 'appsource'
            StageDelta = @{ PTE0003 = 'Info' }; Action = 'None'; Source = 'twins'; Detail = 'Procedures must not subscribe to CompanyOpen events'
        }
        @{ Name = 'the stage delta beats the level chain'; Id = 'AL0432'; Level = 'recommended'; Stage = 'ci'
            Chain = @{ AL0432 = 'Warning' }; StageDelta = @{ AL0432 = 'Info' }; Action = 'Info'; Source = 'stage:ci'; Detail = 'stage entry'
        }
        @{ Name = 'the chain beats quarantine'; Id = 'AL0200'; Level = 'recommended'; Stage = 'ci'
            Chain = @{ AL0200 = 'Warning' }; Quarantine = @('AL0200'); Action = 'Warning'; Source = 'level:recommended'; Detail = 'level entry'
        }
        @{ Name = 'quarantine applies to an id no chain file mentions'; Id = 'LC0099'; Level = 'recommended'; Stage = 'ci'
            Quarantine = @('LC0099'); Action = 'None'; Source = 'quarantine'; Detail = 'quarantined'
        }
        @{ Name = 'quarantine beats a stage entry for an id no chain file mentions (#42, D41)'; Id = 'LC0099'; Level = 'recommended'; Stage = 'ci'
            StageDelta = @{ LC0099 = 'Info' }; Quarantine = @('LC0099'); Action = 'None'; Source = 'quarantine'
        }
        @{ Name = 'a stage entry applies to a quarantined id a chain file mentions'; Id = 'LC0099'; Level = 'recommended'; Stage = 'ci'
            Chain = @{ LC0099 = 'Warning' }; StageDelta = @{ LC0099 = 'Info' }; Quarantine = @('LC0099'); Action = 'Info'; Source = 'stage:ci'
        }
        @{ Name = 'a stage entry is skipped where the chain result is None (S-4)'; Id = 'AL0432'; Level = 'essential'; Stage = 'ci'
            Chain = @{ AL0432 = 'None' }; StageDelta = @{ AL0432 = 'Info' }; Action = 'None'; Source = 'level:essential'
        }
        @{ Name = 'a stage entry applies to an unmentioned id enabled by default (AL1026)'; Id = 'AL1026'; Level = 'recommended'; Stage = 'ci'
            StageDelta = @{ AL1026 = 'Info' }; Action = 'Info'; Source = 'stage:ci'
        }
        @{ Name = 'a stage entry never activates an unmentioned id disabled by default (S-4)'; Id = 'LC0054'; Level = 'recommended'; Stage = 'ci'
            StageDelta = @{ LC0054 = 'Info' }; Action = 'None'; Source = 'default'
        }
        @{ Name = 'a stage entry does not apply in the default stage'; Id = 'AL0432'; Level = 'recommended'; Stage = 'default'
            Chain = @{ AL0432 = 'Warning' }; StageDelta = @{ AL0432 = 'Info' }; Action = 'Warning'; Source = 'level:recommended'
        }
        @{ Name = '["recommended"] beats ["*"] whatever the order'; Id = 'AA0072'; Level = 'recommended'; Stage = 'ci'
            Overrides = @(
                @{ action = 'Warning'; levels = @('recommended'); stages = @('*'); justification = 'specific' }
                @{ action = 'Info'; levels = @('*'); stages = @('*'); justification = 'wildcard' }
            ); Action = 'Warning'; Source = 'override'; Detail = 'specific'
        }
        @{ Name = 'two selectors beat one'; Id = 'AA0072'; Level = 'recommended'; Stage = 'ci'
            Overrides = @(
                @{ action = 'Hidden'; levels = @('recommended'); stages = @('ci'); justification = 'both' }
                @{ action = 'Info'; levels = @('*'); stages = @('ci'); justification = 'stage only' }
            ); Action = 'Hidden'; Source = 'override'; Detail = 'both'
        }
        @{ Name = 'on a tie the later entry wins'; Id = 'AA0072'; Level = 'recommended'; Stage = 'ci'
            Overrides = @(
                @{ action = 'Info'; levels = @('recommended'); stages = @('*'); justification = 'first' }
                @{ action = 'Error'; levels = @('recommended'); stages = @('*'); justification = 'second' }
            ); Action = 'Error'; Source = 'override'; Detail = 'second'
        }
        @{ Name = 'an override on another level does not match'; Id = 'LC0029'; Level = 'strict'; Stage = 'ci'
            Chain = @{ LC0029 = 'Warning' }; Overrides = @(@{ action = 'None'; levels = @('recommended'); stages = @('ci') })
            Action = 'Warning'; Source = 'level:strict'
        }
        @{ Name = 'the default stage selector matches the default stage'; Id = 'AL0200'; Level = 'recommended'; Stage = 'default'
            Chain = @{ AL0200 = 'Warning' }; Overrides = @(@{ action = 'Info'; levels = @('*'); stages = @('default') })
            Action = 'Info'; Source = 'override'
        }
        @{ Name = 'the default stage selector does not match ci'; Id = 'AL0200'; Level = 'recommended'; Stage = 'ci'
            Chain = @{ AL0200 = 'Warning' }; Overrides = @(@{ action = 'Info'; levels = @('*'); stages = @('default') })
            Action = 'Warning'; Source = 'level:recommended'
        }
        @{ Name = 'an override beats quarantine'; Id = 'LC0099'; Level = 'recommended'; Stage = 'ci'
            Quarantine = @('LC0099'); Overrides = @(@{ action = 'Warning'; levels = @('*'); stages = @('*') })
            Action = 'Warning'; Source = 'override'
        }
        @{ Name = 'twins pte lowers the AppSource side'; Id = 'AS0061'; Level = 'recommended'; Stage = 'default'; TwinsSetting = 'pte'
            Action = 'None'; Source = 'twins'
        }
        @{ Name = 'twins pte leaves the PTE side'; Id = 'PTE0003'; Level = 'recommended'; Stage = 'default'; TwinsSetting = 'pte'
            Action = 'Error'; Source = 'default'
        }
        @{ Name = 'twins both changes nothing'; Id = 'PTE0003'; Level = 'recommended'; Stage = 'default'; TwinsSetting = 'both'
            Action = 'Error'; Source = 'default'
        }
        @{ Name = 'nothing decides: the analyzer default'; Id = 'AL0001'; Level = 'recommended'; Stage = 'ci'
            Action = 'Error'; Source = 'default'
        }
        @{ Name = 'an id absent from the catalog has no default'; Id = 'LC0999'; Level = 'recommended'; Stage = 'ci'
            Action = $null; Source = 'default'
        }
        @{ Name = 'a stage entry applies to an id absent from the catalog'; Id = 'LC0999'; Level = 'recommended'; Stage = 'ci'
            StageDelta = @{ LC0999 = 'Info' }; Action = 'Info'; Source = 'stage:ci'
        }
    )

    # The four endpoint tables of the WP03 plan section 6.2, re-derived by hand: "Id Action Source".
    $script:fixtureTables = @(
        @{ Key = 'recommended.ci'; Expected = @(
                'AL0432 Info stage:ci', 'AL0603 Info stage:ci', 'AL1026 Info stage:ci', 'AA0072 Info override',
                'AW0006 Error level:recommended', 'AC0001 Warning level:recommended', 'LC0029 None override', 'LC0099 None quarantine')
        }
        @{ Key = 'essential.ci'; Expected = @(
                'AL0200 None level:essential', 'AL0432 None level:essential', 'AL0603 Info stage:ci', 'AL1026 Info stage:ci',
                'AA0001 None level:essential', 'AA0072 Info override', 'AS0084 None level:essential', 'LC0015 None level:essential',
                'LC0029 None level:essential', 'LC0089i None level:essential', 'LC0099 None quarantine', 'DC0001 None level:essential')
        }
        @{ Key = 'recommended.default'; Expected = @(
                'AA0072 Info override', 'AW0006 Error level:recommended', 'AC0001 Warning level:recommended', 'LC0099 None quarantine')
        }
        @{ Key = 'complete.vnext'; Expected = @(
                'AL0603 Info level:strict', 'AL0604 Error stage:vnext', 'AA0072 Info override', 'AA0137 Error level:strict',
                'AW0006 Error level:recommended', 'PC0001 Error level:complete', 'AC0001 Warning level:recommended',
                'LC0015 Warning level:strict', 'LC0029 Error stage:vnext', 'LC0054 Info level:complete', 'FC0001 Info level:strict',
                'CM0001 Warning level:complete')
        }
    )

    $script:shippedKeys = foreach ($level in 'essential', 'recommended', 'strict', 'complete') {
        foreach ($stage in 'default', 'ci', 'vnext') { @{ Level = $level; Stage = $stage } }
    }
}

BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:repoRoot 'modules' 'Rulebook.Generate.psd1') -Force
    . (Join-Path $PSScriptRoot 'Helpers' 'RepoFixture.ps1')

    $script:validMinimal = Join-Path $PSScriptRoot 'fixtures' 'repos' 'valid-minimal'
    $script:inputs = Read-RulebookInputs -RepositoryRoot $script:validMinimal
    $script:catalog = Read-Catalog -Path (Join-Path $script:validMinimal 'catalog' 'diagnostics.json')
    $script:twins = Read-Twins -Path (Join-Path $script:validMinimal 'base' 'twins.json')
    $script:shippedFiles = @(
        'complete.ci.ruleset.json', 'complete.ruleset.json', 'complete.vnext.ruleset.json',
        'essential.ci.ruleset.json', 'essential.ruleset.json', 'essential.vnext.ruleset.json',
        'recommended.ci.ruleset.json', 'recommended.ruleset.json', 'recommended.vnext.ruleset.json',
        'strict.ci.ruleset.json', 'strict.ruleset.json', 'strict.vnext.ruleset.json')

    function Copy-Fixture {
        param([string]$Name = 'valid-minimal')
        return New-FixtureRepo -Name $Name -Destination (Join-Path $TestDrive ([guid]::NewGuid().ToString('n').Substring(0, 12)))
    }

    function Get-EntryText {
        param($Endpoint, [switch]$WithSource)
        return @($Endpoint.Entries | ForEach-Object {
                if ($WithSource) { '{0} {1} {2}' -f $_.Id, $_.Action, $_.Source } else { '{0} {1}' -f $_.Id, $_.Action }
            })
    }

    function Get-FileEntryText {
        param([string]$Root, [string]$Leaf)
        $json = Get-Content -LiteralPath (Join-Path $Root 'rulesets' $Leaf) -Raw | ConvertFrom-Json
        return @($json.rules | ForEach-Object { '{0} {1}' -f $_.id, $_.action })
    }

    function Get-RulesetFileName {
        param([string]$Root)
        return @(Get-ChildItem -LiteralPath (Join-Path $Root 'rulesets') -File | ForEach-Object Name | Sort-Object)
    }

    function Assert-ContainsAll {
        # Should-ContainCollection expects the items in order; this checks membership only.
        param([object[]]$Actual, [object[]]$Expected)
        foreach ($item in $Expected) { ($Actual -ccontains $item) | Should-BeTrue -Because "'$item' is expected in: $($Actual -join ', ')" }
    }

    function Get-TreeHash {
        param([string]$Root)
        return @(Get-ChildItem -LiteralPath (Join-Path $Root 'rulesets') -File | Sort-Object Name | ForEach-Object {
                '{0}={1}' -f $_.Name, (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
            }) -join ';'
    }

    function Invoke-PrecedenceCase {
        param([hashtable]$Case)
        $chain = [ordered]@{}
        if ($Case.ContainsKey('Chain')) {
            foreach ($id in $Case.Chain.Keys) { $chain[$id] = [pscustomobject]@{ Action = $Case.Chain[$id]; Slug = $Case.Level; Justification = 'level entry' } }
        }
        $stageDelta = [ordered]@{}
        if ($Case.ContainsKey('StageDelta')) {
            foreach ($id in $Case.StageDelta.Keys) { $stageDelta[$id] = [pscustomobject]@{ Action = $Case.StageDelta[$id]; Justification = 'stage entry' } }
        }
        $quarantine = [ordered]@{}
        if ($Case.ContainsKey('Quarantine')) { foreach ($id in $Case.Quarantine) { $quarantine[$id] = 'quarantined' } }
        $overrides = @()
        if ($Case.ContainsKey('Overrides')) {
            $rules = @(foreach ($entry in $Case.Overrides) {
                    $rule = [ordered]@{ id = $Case.Id; action = $entry.action; levels = @($entry.levels); stages = @($entry.stages) }
                    if ($entry.ContainsKey('justification')) { $rule.justification = $entry.justification }
                    $rule
                })
            $path = Join-Path $TestDrive ('overrides-{0}.json' -f [guid]::NewGuid().ToString('n'))
            Write-FixtureText -Path $path -Text (@{ rules = $rules } | ConvertTo-Json -Depth 5)
            $overrides = Read-Overrides -Path $path
        }
        $twinsSetting = if ($Case.ContainsKey('TwinsSetting')) { $Case.TwinsSetting } else { 'both' }
        return Get-EffectiveAction -Id $Case.Id -Level $Case.Level -Stage $Case.Stage -Chain $chain -StageDelta $stageDelta `
            -Twins $script:twins -TwinsSetting $twinsSetting -Overrides $overrides -Quarantine $quarantine -Catalog $script:catalog
    }
}

AfterAll {
    Remove-Module Rulebook.Generate -ErrorAction SilentlyContinue
}

Describe 'Read-RulesetFile and Read-StageFile' {
    It 'keeps the order of the file' {
        $file = Read-RulesetFile -Path (Join-Path $validMinimal 'base' 'recommended.ruleset.json')
        (@($file.Rules.Keys) -join ',') | Should-Be 'AL0200,AL0432,AA0001,AA0072,AS0084,LC0015,LC0029,LC0089i,DC0001,AC0001,AW0006'
        $file.Name | Should-Be 'Rulebook Recommended'
        $file.Rules['AW0006'].Justification | Should-Be 'Fixture: raised above its Warning default from Recommended'
    }

    It 'throws on invalid JSON' {
        $path = Join-Path $TestDrive 'broken.ruleset.json'
        Write-FixtureText -Path $path -Text '{ "name": "x", "rules": [ '
        { Read-RulesetFile -Path $path } | Should-Throw -ExceptionMessage '*Invalid JSON*broken.ruleset.json*'
    }

    It 'throws on the action Default' {
        $path = Join-Path $TestDrive 'default-action.ruleset.json'
        Write-FixtureText -Path $path -Text '{ "name": "x", "rules": [ { "id": "AL0200", "action": "Default" } ] }'
        { Read-RulesetFile -Path $path } | Should-Throw -ExceptionMessage "*AL0200 has action 'Default'*"
    }

    It 'throws on <Key> in a level file' -ForEach @(
        @{ Key = 'includedRuleSets'; Json = '"includedRuleSets": [ { "action": "Default", "path": "x.json" } ],' }
        @{ Key = 'generalAction'; Json = '"generalAction": "Warning",' }
    ) {
        $path = Join-Path $TestDrive "with-$Key.ruleset.json"
        Write-FixtureText -Path $path -Text ('{ "name": "x", ' + $Json + ' "rules": [] }')
        { Read-RulesetFile -Path $path } | Should-Throw -ExceptionMessage "*has '$Key'*"
    }

    It 'keeps ids that differ only in case apart (ordinal keys)' {
        $path = Join-Path $TestDrive 'case.ruleset.json'
        Write-FixtureText -Path $path -Text '{ "name": "x", "rules": [ { "id": "AL0001", "action": "Info" }, { "id": "al0001", "action": "None" } ] }'
        $file = Read-RulesetFile -Path $path
        $file.Rules.Count | Should-Be 2
        $file.Rules['AL0001'].Action | Should-Be 'Info'
        $file.Rules['al0001'].Action | Should-Be 'None'
    }

    It 'reads a justification that looks like a date as text (<Json>)' -ForEach @(
        @{ Json = '2026-10-03'; Expected = '2026-10-03' }
        @{ Json = '2026-10-03T10:00:00'; Expected = '2026-10-03T10:00:00' }
        @{ Json = '2026-10-03T10:00:00Z'; Expected = '2026-10-03T10:00:00Z' }
        @{ Json = '2026-10-03T12:00:00+02:00'; Expected = '2026-10-03T10:00:00Z' }
    ) {
        $path = Join-Path $TestDrive 'date.ruleset.json'
        Write-FixtureText -Path $path -Text ('{ "name": "x", "rules": [ { "id": "AL0001", "action": "Info", "justification": "' + $Json + '" } ] }')
        $justification = (Read-RulesetFile -Path $path).Rules['AL0001'].Justification
        $justification | Should-HaveType ([string])
        $justification | Should-Be $Expected
    }

    It 'throws on an id listed twice' {
        $root = Copy-Fixture 'duplicate-id'
        { Read-RulesetFile -Path (Join-Path $root 'base' 'strict.ruleset.json') } | Should-Throw -ExceptionMessage '*lists AA0137 twice*'
    }

    It 'Read-StageFile reads a stage file with its justifications' {
        $stage = Read-StageFile -Path (Join-Path $validMinimal 'stages' 'ci.json')
        (@($stage.Rules.Keys) -join ',') | Should-Be 'AL0432,AL0603,AL1026'
        $stage.Rules['AL0432'].Action | Should-Be 'Info'
        $stage.Rules['AL0432'].Justification | Should-Be 'Replacement may not exist yet; advisory in CI; S-2'
        $stage.Rules['AL1026'].Justification | Should-BeNull
    }

    It 'Read-StageFile rejects stages/default.json' {
        $path = Join-Path $TestDrive 'stages' 'default.json'
        Write-FixtureText -Path $path -Text '{ "name": "x", "rules": [] }'
        { Read-StageFile -Path $path } | Should-Throw -ExceptionMessage '*stages/default.json must not exist*'
    }
}

Describe 'Resolve-LevelChain' {
    It 'the root file applies alone for the root level' {
        (@($inputs.ChainFiles['essential']) -join ',') | Should-Be 'essential'
        (@($inputs.Chains['essential'].Keys) -join ',') | Should-Be 'AL0200,AL0432,AA0001,AA0072,AS0084,LC0015,LC0029,LC0089i,DC0001'
        @($inputs.Chains['essential'].Values | Where-Object { $_.Action -ne 'None' }).Count | Should-Be 0
    }

    It 'lists the chain files root first' {
        (@($inputs.ChainFiles['complete']) -join ',') | Should-Be 'essential,recommended,strict,complete'
    }

    It 'a delta entry replaces the value of its basedOn level (AL0200)' {
        $inputs.Chains['essential']['AL0200'].Action | Should-Be 'None'
        $inputs.Chains['recommended']['AL0200'].Action | Should-Be 'Warning'
        $inputs.Chains['recommended']['AL0200'].Slug | Should-Be 'recommended'
        $inputs.Chains['complete']['AL0200'].Slug | Should-Be 'recommended'
    }

    It 'a level may lower an id its basedOn level enables (AL0603 at strict)' {
        $inputs.Chains['recommended'].Contains('AL0603') | Should-BeFalse
        $inputs.Chains['strict']['AL0603'].Action | Should-Be 'Info'
        (Get-AnalyzerDefault -Catalog $inputs.Catalog -Id 'AL0603') | Should-Be 'Warning'
    }

    It 'an alias level with an empty file equals its basedOn level' {
        $alias = Read-RulebookInputs -RepositoryRoot (Copy-Fixture 'alias-level')
        $baseline = @($alias.Chains['baseline'].GetEnumerator() | ForEach-Object { '{0} {1}' -f $_.Key, $_.Value.Action }) -join ','
        $recommended = @($alias.Chains['recommended'].GetEnumerator() | ForEach-Object { '{0} {1}' -f $_.Key, $_.Value.Action }) -join ','
        $baseline | Should-Be $recommended
        (@($alias.ChainFiles['baseline']) -join ',') | Should-Be 'essential,recommended,baseline'
    }

    It 'a basedOn file without a settings entry is a root (D29), read from -BaseDir' {
        $result = Resolve-LevelChain -Levels @(@{ name = 'Strict'; basedOn = 'Recommended' }) -BaseDir (Join-Path $validMinimal 'base')
        (@($result.ChainFiles['strict']) -join ',') | Should-Be 'recommended,strict'
        $result.Chains['strict']['AL0200'].Action | Should-Be 'Warning'
        $result.Chains['strict'].Contains('AL0001') | Should-BeFalse
        @($result.Chains.Keys).Count | Should-Be 1
    }

    It 'throws on an unresolved basedOn' {
        { Resolve-LevelChain -Levels @(@{ name = 'Strict'; basedOn = 'Paranoid' }) -BaseDir (Join-Path $validMinimal 'base') } |
            Should-Throw -ExceptionMessage "Unresolved basedOn 'paranoid' of level 'Strict'"
    }

    It 'throws on a basedOn cycle with the path' {
        { Read-RulebookInputs -RepositoryRoot (Copy-Fixture 'basedon-cycle') } | Should-Throw -ExceptionMessage 'basedOn cycle: recommended -> strict -> recommended'
    }

    It 'throws on a published level without its file' {
        { Resolve-LevelChain -Levels @(@{ name = 'Paranoid' }) -BaseDir (Join-Path $validMinimal 'base') } |
            Should-Throw -ExceptionMessage "Missing level file base/paranoid.ruleset.json for level 'Paranoid'"
    }
}

Describe 'Read-Overrides' {
    It 'scores specificity 0, 1 and 2 and keeps the file index' {
        $path = Join-Path $TestDrive 'overrides-specificity.json'
        Write-FixtureText -Path $path -Text @'
{
  "rules": [
    { "id": "AA0072", "action": "Info", "levels": ["*"], "stages": ["*"] },
    { "id": "AA0072", "action": "Info", "levels": ["recommended"], "stages": ["*"] },
    { "id": "AA0072", "action": "Info", "levels": ["*"], "stages": ["ci"] },
    { "id": "AA0072", "action": "Info", "levels": ["recommended", "strict"], "stages": ["ci"], "justification": "x" }
  ]
}
'@
        $entries = Read-Overrides -Path $path
        (@($entries | ForEach-Object Specificity) -join ',') | Should-Be '0,1,1,2'
        (@($entries | ForEach-Object Index) -join ',') | Should-Be '0,1,2,3'
        (@($entries[3].Levels) -join ',') | Should-Be 'recommended,strict'
        $entries[3].Justification | Should-Be 'x'
        $entries[0].Justification | Should-BeNull
    }

    It 'accepts default as a stage selector' {
        $path = Join-Path $TestDrive 'overrides-default.json'
        Write-FixtureText -Path $path -Text '{ "rules": [ { "id": "AL0200", "action": "Info", "levels": ["*"], "stages": ["default"] } ] }'
        $entries = Read-Overrides -Path $path -Inputs $inputs -Strict
        $entries[0].UnknownSelectors.Count | Should-Be 0
        $entries[0].Specificity | Should-Be 1
    }

    It 'throws on a selector that mixes * with slugs' {
        $path = Join-Path $TestDrive 'overrides-mixed.json'
        Write-FixtureText -Path $path -Text '{ "rules": [ { "id": "AL0200", "action": "Info", "levels": ["*", "strict"], "stages": ["*"] } ] }'
        { Read-Overrides -Path $path } | Should-Throw -ExceptionMessage "*mixes '*' with other values in levels*"
    }

    It 'reports an unknown slug, and throws on it with -Strict' {
        $root = Copy-Fixture 'bad-selector'
        $path = Join-Path $root 'overrides.json'
        $entries = Read-Overrides -Path $path -Inputs $inputs
        $entries.Count | Should-Be 3
        (@($entries[2].UnknownSelectors) -join ',') | Should-Be "level 'paranoid'"
        $entries[0].UnknownSelectors.Count | Should-Be 0
        { Read-Overrides -Path $path -Inputs $inputs -Strict } | Should-Throw -ExceptionMessage "*unknown level 'paranoid'*"
    }

    It 'an override on an unknown slug matches no endpoint' {
        $bad = Read-RulebookInputs -RepositoryRoot (Copy-Fixture 'bad-selector')
        foreach ($key in $shippedKeys) {
            (Get-EffectiveAction -Inputs $bad -Id 'LC0001' -Level $key.Level -Stage $key.Stage).Source | Should-Be 'default'
        }
    }
}

Describe 'Read-RulebookInputs checks' {
    It 'throws when stages/default.json exists' {
        $root = Copy-Fixture
        Write-FixtureText -Path (Join-Path $root 'stages' 'default.json') -Text '{ "name": "x", "rules": [] }'
        { Read-RulebookInputs -RepositoryRoot $root } | Should-Throw -ExceptionMessage 'stages/default.json must not exist*'
    }

    It 'throws on a twins value outside both, appsource and pte' {
        { Read-RulebookInputs -RepositoryRoot (Copy-Fixture 'bad-twins-value') } | Should-Throw -ExceptionMessage "*twins is 'all'*"
    }

    It 'reads a missing twins setting as both' {
        $root = Copy-Fixture
        Edit-FixtureJson -Path (Join-Path $root '.github' 'Rulebook-Settings.json') -Script { $_.Remove('twins') }
        (Read-RulebookInputs -RepositoryRoot $root).TwinsSetting | Should-Be 'both'
    }

    It 'throws on a <Kind> name that is not a slug' -ForEach @(@{ Kind = 'levels'; Name = 'Very.Strict' }, @{ Kind = 'stages'; Name = '../ci' }) {
        $root = Copy-Fixture
        $kind = $Kind; $name = $Name
        Edit-FixtureJson -Path (Join-Path $root '.github' 'Rulebook-Settings.json') -Script { $_[$kind] += @{ name = $name } }
        { Read-RulebookInputs -RepositoryRoot $root } | Should-Throw -ExceptionMessage "*$Kind entry '$Name' does not lowercase to a slug*"
    }

    It 'throws on a slug used twice' {
        $root = Copy-Fixture
        Edit-FixtureJson -Path (Join-Path $root '.github' 'Rulebook-Settings.json') -Script { $_.levels += @{ name = 'STRICT'; basedOn = 'Recommended' } }
        { Read-RulebookInputs -RepositoryRoot $root } | Should-Throw -ExceptionMessage "*levels slug 'strict' is used twice*"
    }

    It 'Read-Twins throws on a side in two pairs' {
        $path = Join-Path $TestDrive 'twins-duplicate.json'
        Write-FixtureText -Path $path -Text '{ "pairs": [ { "pte": "PTE0003", "appsource": "AS0061" }, { "pte": "PTE0003", "appsource": "AS0048" } ] }'
        { Read-Twins -Path $path } | Should-Throw -ExceptionMessage '*lists PTE0003 in two pairs*'
    }

    It 'Get-EffectiveAction -Inputs throws on an unknown <What> slug' -ForEach @(
        @{ What = 'level'; Level = 'paranoid'; Stage = 'ci' }
        @{ What = 'stage'; Level = 'strict'; Stage = 'nightly' }
    ) {
        { Get-EffectiveAction -Inputs $inputs -Id 'AL0200' -Level $Level -Stage $Stage } | Should-Throw -ExceptionMessage "Unknown $What slug*"
    }
}

Describe 'Get-EffectiveAction precedence' {
    It '<Name>' -ForEach $precedenceCases {
        $result = Invoke-PrecedenceCase -Case $_
        if ($null -eq $_.Action) { $result.Action | Should-BeNull } else { $result.Action | Should-Be $_.Action }
        $result.Source | Should-Be $_.Source
        $result.Id | Should-Be $_.Id
        if ($_.ContainsKey('Detail')) { $result.Detail | Should-Be $_.Detail }
    }

    It 'the Inputs parameter set returns <Id> <Action> (<Source>) in <Level>.<Stage>' -ForEach @(
        @{ Id = 'LC0029'; Level = 'recommended'; Stage = 'ci'; Action = 'None'; Source = 'override'; Detail = 'Backlog DEV-1234' }
        @{ Id = 'AA0072'; Level = 'essential'; Stage = 'default'; Action = 'Info'; Source = 'override'; Detail = 'House style' }
        @{ Id = 'AL0432'; Level = 'recommended'; Stage = 'ci'; Action = 'Info'; Source = 'stage:ci'; Detail = 'Replacement may not exist yet; advisory in CI; S-2' }
        @{ Id = 'AL0432'; Level = 'essential'; Stage = 'ci'; Action = 'None'; Source = 'level:essential'; Detail = $null }
        @{ Id = 'AW0006'; Level = 'strict'; Stage = 'default'; Action = 'Error'; Source = 'level:recommended'; Detail = 'Fixture: raised above its Warning default from Recommended' }
        @{ Id = 'LC0099'; Level = 'complete'; Stage = 'default'; Action = 'None'; Source = 'quarantine'; Detail = 'New in alcops.analyzers 1.4.0-beta.1 (prerelease), quarantined 2026-10-01. Review and adopt.' }
        @{ Id = 'LC0099'; Level = 'complete'; Stage = 'vnext'; Action = 'Warning'; Source = 'default'; Detail = $null }
        @{ Id = 'AL0604'; Level = 'essential'; Stage = 'vnext'; Action = 'Error'; Source = 'stage:vnext'; Detail = 'Future error on the next platform; S-1' }
    ) {
        $result = Get-EffectiveAction -Inputs $inputs -Id $Id -Level $Level -Stage $Stage
        $result.Action | Should-Be $Action
        $result.Source | Should-Be $Source
        if ($null -eq $Detail) { $result.Detail | Should-BeNull } else { $result.Detail | Should-Be $Detail }
    }
}

Describe 'Sparse endpoints' {
    It 'an id at its analyzer default is not written (AL0200 in recommended)' {
        $endpoint = Get-RulebookEndpoint -Inputs $inputs -Level 'recommended' -Stage 'default'
        $endpoint.Table['AL0200'].Action | Should-Be 'Warning'
        $endpoint.Table['AL0200'].Listed | Should-BeFalse
        @($endpoint.Entries | Where-Object Id -EQ 'AL0200').Count | Should-Be 0
    }

    It 'a disabled-by-default id at None is not written (LC0054 in strict)' {
        $endpoint = Get-RulebookEndpoint -Inputs $inputs -Level 'strict' -Stage 'default'
        (Get-EffectiveAction -Inputs $inputs -Id 'LC0054' -Level 'strict' -Stage 'default').Action | Should-Be 'None'
        @($endpoint.Entries | Where-Object Id -EQ 'LC0054').Count | Should-Be 0
    }

    It 'a quarantined id with an enabled default is written (LC0099)' {
        $endpoint = Get-RulebookEndpoint -Inputs $inputs -Level 'strict' -Stage 'default'
        Assert-ContainsAll -Actual @(Get-EntryText $endpoint -WithSource) -Expected @('LC0099 None quarantine')
    }

    It 'an override that restores the default unlists the id (AA0072 Warning at essential)' {
        $root = Copy-Fixture
        Edit-FixtureJson -Path (Join-Path $root 'overrides.json') -Script {
            $_.rules += @{ id = 'AA0072'; action = 'Warning'; levels = @('essential'); stages = @('*') }
        }
        $endpoint = Get-RulebookEndpoint -RepositoryRoot $root -Level 'essential' -Stage 'default'
        $endpoint.Table['AA0072'].Action | Should-Be 'Warning'
        $endpoint.Table['AA0072'].Source | Should-Be 'override'
        $endpoint.Table['AA0072'].Listed | Should-BeFalse
        @($endpoint.Entries | Where-Object Id -EQ 'AA0072').Count | Should-Be 0
    }

    It 'an id absent from the catalog is always written (LC0999)' {
        $unknown = Read-RulebookInputs -RepositoryRoot (Copy-Fixture 'unknown-id')
        foreach ($stage in 'default', 'ci', 'vnext') {
            Assert-ContainsAll -Actual @(Get-EntryText (Get-RulebookEndpoint -Inputs $unknown -Level 'complete' -Stage $stage)) -Expected @('LC0999 Info')
        }
        (Get-RulebookEndpoint -Inputs $unknown -Level 'complete' -Stage 'default').Table['LC0999'].Default | Should-BeNull
    }

    It 'no endpoint lists an id at its catalog default (<Level>.<Stage>)' -ForEach $shippedKeys {
        $endpoint = Get-RulebookEndpoint -Inputs $inputs -Level $Level -Stage $Stage
        foreach ($entry in $endpoint.Entries) {
            $entry.Action | Should-NotBe (Get-AnalyzerDefault -Catalog $inputs.Catalog -Id $entry.Id)
        }
    }
}

Describe 'Twins' {
    It 'both writes nothing extra' {
        foreach ($key in $shippedKeys) {
            $ids = @((Get-RulebookEndpoint -Inputs $inputs -Level $key.Level -Stage $key.Stage).Entries | ForEach-Object Id)
            @($ids | Where-Object { $_ -in 'PTE0003', 'PTE0011', 'AS0061', 'AS0048' }).Count | Should-Be 0
        }
    }

    It 'appsource lists every PTE side at None in all 12 endpoints (criterion 4)' {
        $root = Copy-Fixture 'twins-appsource'
        $null = Update-RulebookEndpoints -RepositoryRoot $root
        $appsource = Read-RulebookInputs -RepositoryRoot $root
        @(Get-RulesetFileName $root).Count | Should-Be 12
        foreach ($key in $shippedKeys) {
            $endpoint = Get-RulebookEndpoint -Inputs $appsource -Level $key.Level -Stage $key.Stage
            Assert-ContainsAll -Actual @(Get-EntryText $endpoint -WithSource) -Expected @('PTE0003 None twins', 'PTE0011 None twins')
            @($endpoint.Entries | Where-Object { $_.Id -in 'AS0061', 'AS0048' }).Count | Should-Be 0
            Assert-ContainsAll -Actual @(Get-FileEntryText $root (Split-Path -Leaf $endpoint.File)) -Expected @('PTE0003 None', 'PTE0011 None')
            $endpoint.Description | Should-MatchString ', twins appsource\. '
        }
        (Get-EffectiveAction -Inputs $appsource -Id 'PTE0011' -Level 'strict' -Stage 'ci').Detail | Should-Be 'The publisher name is too long'
    }

    It 'pte lists every AppSource side at None in all 12 endpoints (criterion 4)' {
        $pte = Read-RulebookInputs -RepositoryRoot (Copy-Fixture 'twins-pte')
        foreach ($key in $shippedKeys) {
            $endpoint = Get-RulebookEndpoint -Inputs $pte -Level $key.Level -Stage $key.Stage
            Assert-ContainsAll -Actual @(Get-EntryText $endpoint -WithSource) -Expected @('AS0061 None twins', 'AS0048 None twins')
            @($endpoint.Entries | Where-Object { $_.Id -in 'PTE0003', 'PTE0011' }).Count | Should-Be 0
        }
    }

    It 'an override on a twin side beats the setting' {
        $root = Copy-Fixture 'twins-appsource'
        Edit-FixtureJson -Path (Join-Path $root 'overrides.json') -Script {
            $_.rules += @{ id = 'PTE0003'; action = 'Warning'; levels = @('*'); stages = @('*'); justification = 'We ship PTEs too' }
        }
        $endpoint = Get-RulebookEndpoint -RepositoryRoot $root -Level 'recommended' -Stage 'ci'
        Assert-ContainsAll -Actual @(Get-EntryText $endpoint -WithSource) -Expected @('PTE0003 Warning override', 'PTE0011 None twins')
    }

    It 'a missing base/twins.json with twins both is fine' {
        $root = Copy-Fixture
        Remove-Item -LiteralPath (Join-Path $root 'base' 'twins.json')
        @(Update-RulebookEndpoints -RepositoryRoot $root -WhatIf).Count | Should-Be 0
        (Read-RulebookInputs -RepositoryRoot $root).Twins.Pairs.Count | Should-Be 0
    }
}

Describe 'Entry order' {
    It 'sorts by prefix order, then number, then the i suffix, unknown prefixes last' {
        $ordered = @('AL0001', 'AL0200', 'AL1026', 'AA0001', 'AW0006', 'PTE0003', 'AS0001', 'PC0001', 'AC0001', 'LC0029',
            'LC0089', 'LC0089i', 'LC0099', 'LC0999', 'DC0001', 'FC0001', 'TA0001', 'CM0001', 'XY0001', 'ZZ0001')
        for ($i = 0; $i -lt $ordered.Count - 1; $i++) {
            $left = Get-DiagnosticSortKey -Id $ordered[$i]
            $right = Get-DiagnosticSortKey -Id $ordered[$i + 1]
            [string]::CompareOrdinal($left, $right) | Should-BeLessThan 0 -Because "$($ordered[$i]) sorts before $($ordered[$i + 1])"
        }
    }

    It 'puts LC0089 before LC0089i' {
        Get-DiagnosticSortKey -Id 'LC0089' | Should-Be '070000890'
        Get-DiagnosticSortKey -Id 'LC0089i' | Should-Be '070000891'
    }

    It 'sorts AL10000 after AL9999 and never throws on a long or malformed id' {
        [string]::CompareOrdinal((Get-DiagnosticSortKey -Id 'AL9999'), (Get-DiagnosticSortKey -Id 'AL10000')) | Should-BeLessThan 0
        $long = 'AL' + ('9' * 20)
        $key = Get-DiagnosticSortKey -Id $long
        $key | Should-Be ('99~' + $long)
        [string]::CompareOrdinal((Get-DiagnosticSortKey -Id 'ZZ0001'), $key) | Should-BeLessThan 0
        Get-DiagnosticSortKey -Id 'not an id' | Should-Be '99~not an id'
    }

    It 'sorts override-only and quarantine-only ids in place' {
        $root = Copy-Fixture
        Edit-FixtureJson -Path (Join-Path $root 'overrides.json') -Script {
            $_.rules += @{ id = 'TA0001'; action = 'Error'; levels = @('*'); stages = @('*') }
            $_.rules += @{ id = 'AL0001'; action = 'Warning'; levels = @('*'); stages = @('*') }
        }
        $endpoint = Get-RulebookEndpoint -RepositoryRoot $root -Level 'recommended' -Stage 'default'
        ((Get-EntryText $endpoint) -join ',') | Should-Be 'AL0001 Warning,AA0072 Info,AW0006 Error,AC0001 Warning,LC0099 None,TA0001 Error'
    }

    It 'lists every chain id that differs from its default exactly once (<Level>.<Stage>)' -ForEach $shippedKeys {
        $endpoint = Get-RulebookEndpoint -Inputs $inputs -Level $Level -Stage $Stage
        $ids = @($endpoint.Entries | ForEach-Object Id)
        @($ids | Select-Object -Unique).Count | Should-Be $ids.Count
        foreach ($id in $inputs.Chains[$Level].Keys) {
            $expected = if ($endpoint.Table[$id].Listed) { 1 } else { 0 }
            @($ids | Where-Object { $_ -ceq $id }).Count | Should-Be $expected
        }
    }
}

Describe 'Endpoint metadata' {
    It 'names the endpoint with the settings casing' {
        (Get-RulebookEndpoint -Inputs $inputs -Level 'recommended' -Stage 'ci').Name | Should-Be 'Rulebook Recommended / CI'
        (Get-RulebookEndpoint -Inputs $inputs -Level 'strict' -Stage 'default').Name | Should-Be 'Rulebook Strict / default'
        (Get-RulebookEndpoint -Inputs $inputs -Level 'complete' -Stage 'vnext').Name | Should-Be 'Rulebook Complete / vNext'
    }

    It 'the strict.ci description equals the naming.md fixture byte for byte' {
        $fixture = Join-Path $repoRoot 'tests' 'fixtures' 'schemas' 'valid' 'ruleset.endpoint' 'endpoint-strict-ci.json'
        $expected = (Get-Content -LiteralPath $fixture -Raw | ConvertFrom-Json).description
        (Get-RulebookEndpoint -Inputs $inputs -Level 'strict' -Stage 'ci').Description | Should-Be $expected
    }

    It 'the default-stage description names no stage file' {
        $description = (Get-RulebookEndpoint -Inputs $inputs -Level 'strict' -Stage 'default').Description
        $description | Should-Be 'Level strict, stage default, twins both. Generated from base/essential.ruleset.json, base/recommended.ruleset.json, base/strict.ruleset.json plus overrides.json and quarantine.default.json; do not edit. Ids at their analyzer default are not listed.'
        $description | Should-NotMatchString 'stages/'
    }

    It 'Key and File use the slug and forward slashes (<Level>.<Stage>)' -ForEach $shippedKeys {
        $endpoint = Get-RulebookEndpoint -Inputs $inputs -Level $Level -Stage $Stage
        $endpoint.Key | Should-Be "$Level.$Stage"
        $leaf = if ($Stage -eq 'default') { "$Level.ruleset.json" } else { "$Level.$Stage.ruleset.json" }
        $endpoint.File | Should-Be "rulesets/$leaf"
    }
}

Describe 'ConvertTo-RulesetJson' {
    It 'writes an empty rules array on one line' {
        ConvertTo-RulesetJson -Name 'Rulebook X / default' -Description 'd' -Rules @() |
            Should-Be "{`n  `"name`": `"Rulebook X / default`",`n  `"description`": `"d`",`n  `"rules`": []`n}`n"
    }

    It 'escapes only backslash, double quote and control characters' {
        $accent = [string][char]0x00E9
        $text = ConvertTo-RulesetJson -Name ('a"b\c' + "`t<&>'" + $accent) -Rules @([pscustomobject]@{ Id = 'AL0001'; Action = 'Error' })
        $text | Should-Be ("{`n  `"name`": `"a\`"b\\c\t<&>'" + $accent + "`",`n  `"rules`": [`n    { `"id`": `"AL0001`", `"action`": `"Error`" }`n  ]`n}`n")
    }

    It 'writes justifications only with -IncludeJustification' {
        $rules = @([pscustomobject]@{ Id = 'AL0200'; Action = 'Warning'; Justification = 'Why' }, @{ Id = 'AL0432'; Action = 'Info' })
        $with = ConvertTo-RulesetJson -Name 'n' -Rules $rules -IncludeJustification
        $with | Should-MatchString '\{ "id": "AL0200", "action": "Warning", "justification": "Why" \},\n    \{ "id": "AL0432", "action": "Info" \}\n'
        ConvertTo-RulesetJson -Name 'n' -Rules $rules | Should-NotMatchString 'justification'
    }

    It 'writes -Schema as the first property and changes nothing else' {
        $rules = @([pscustomobject]@{ Id = 'AL0200'; Action = 'Warning'; Justification = 'Why' })
        $without = ConvertTo-RulesetJson -Name 'n' -Description 'd' -Rules $rules -IncludeJustification
        $with = ConvertTo-RulesetJson -Name 'n' -Description 'd' -Rules $rules -IncludeJustification -Schema 'https://example.invalid/s.json'
        $lines = $with.Split("`n")
        $lines[0] | Should-Be '{'
        $lines[1] | Should-Be '  "$schema": "https://example.invalid/s.json",'
        (@($lines[0]) + @($lines | Select-Object -Skip 2)) -join "`n" | Should-Be $without
    }

    It 'writes no $schema for an empty -Schema' {
        ConvertTo-RulesetJson -Name 'n' -Rules @() -Schema '' | Should-Be (ConvertTo-RulesetJson -Name 'n' -Rules @())
    }
}

Describe 'ConvertTo-JsonString' {
    It 'is exported' {
        (Get-Command ConvertTo-JsonString -Module Rulebook.Generate).Name | Should-Be 'ConvertTo-JsonString'
    }

    It 'escapes backslash, double quote and control characters only' {
        ConvertTo-JsonString ('a"b\c' + "`t<&>'") | Should-Be '"a\"b\\c\t<&>''"'
    }
}

Describe 'Update-RulebookEndpoints' {
    It 'writes exactly the levels x stages files' {
        $root = Copy-Fixture
        Remove-Item -LiteralPath (Join-Path $root 'rulesets') -Recurse
        $changes = @(Update-RulebookEndpoints -RepositoryRoot $root)
        $changes.Count | Should-Be 12
        @($changes | Where-Object Change -NE 'created').Count | Should-Be 0
        (@(Get-RulesetFileName $root) -join ',') | Should-Be ($shippedFiles -join ',')
        foreach ($change in $changes) { $change.File | Should-MatchString '^rulesets/[a-z0-9.-]+\.ruleset\.json$' }
    }

    It 'reproduces the committed valid-minimal endpoints' {
        $root = Copy-Fixture
        Remove-Item -LiteralPath (Join-Path $root 'rulesets') -Recurse
        $null = Update-RulebookEndpoints -RepositoryRoot $root
        foreach ($leaf in $shippedFiles) {
            $expected = [System.IO.File]::ReadAllBytes((Join-Path $validMinimal 'rulesets' $leaf))
            $actual = [System.IO.File]::ReadAllBytes((Join-Path $root 'rulesets' $leaf))
            [System.Convert]::ToBase64String($actual) | Should-Be ([System.Convert]::ToBase64String($expected)) -Because $leaf
        }
    }

    It 'removes endpoint files no entry produces and leaves other files' {
        $root = Copy-Fixture
        Write-FixtureText -Path (Join-Path $root 'rulesets' 'extra.ruleset.json') -Text '{ "name": "x", "rules": [] }'
        Write-FixtureText -Path (Join-Path $root 'rulesets' 'notes.txt') -Text 'kept'
        $changes = @(Update-RulebookEndpoints -RepositoryRoot $root)
        $changes.Count | Should-Be 1
        $changes[0].File | Should-Be 'rulesets/extra.ruleset.json'
        $changes[0].Change | Should-Be 'deleted'
        Test-Path -LiteralPath (Join-Path $root 'rulesets' 'extra.ruleset.json') | Should-BeFalse
        Test-Path -LiteralPath (Join-Path $root 'rulesets' 'notes.txt') | Should-BeTrue
    }

    It 'a second run returns nothing and leaves the bytes identical (criterion 5)' {
        $root = Copy-Fixture 'custom-level'
        @(Update-RulebookEndpoints -RepositoryRoot $root).Count | Should-BeGreaterThan 0
        $before = Get-TreeHash $root
        @(Update-RulebookEndpoints -RepositoryRoot $root).Count | Should-Be 0
        Get-TreeHash $root | Should-Be $before
    }

    It '-WhatIf returns the changes and writes nothing' {
        $root = Copy-Fixture 'stale-endpoints'
        $before = Get-TreeHash $root
        $changes = @(Update-RulebookEndpoints -RepositoryRoot $root -WhatIf)
        $changes.Count | Should-Be 1
        $changes[0].File | Should-Be 'rulesets/recommended.ci.ruleset.json'
        $changes[0].Change | Should-Be 'modified'
        Get-TreeHash $root | Should-Be $before

        Remove-Item -LiteralPath (Join-Path $root 'rulesets') -Recurse
        @(Update-RulebookEndpoints -RepositoryRoot $root -WhatIf).Count | Should-Be 12
        Test-Path -LiteralPath (Join-Path $root 'rulesets') | Should-BeFalse
    }

    It 'the committed valid-minimal endpoints are current' {
        @(Update-RulebookEndpoints -RepositoryRoot $validMinimal -WhatIf).Count | Should-Be 0
    }

    It 'writes <Leaf> without BOM, with LF only, a trailing LF, two-space indent and one rule per line' -ForEach @(
        'complete.ci.ruleset.json', 'complete.ruleset.json', 'complete.vnext.ruleset.json',
        'essential.ci.ruleset.json', 'essential.ruleset.json', 'essential.vnext.ruleset.json',
        'recommended.ci.ruleset.json', 'recommended.ruleset.json', 'recommended.vnext.ruleset.json',
        'strict.ci.ruleset.json', 'strict.ruleset.json', 'strict.vnext.ruleset.json' | ForEach-Object { @{ Leaf = $_ } }
    ) {
        $bytes = [System.IO.File]::ReadAllBytes((Join-Path $validMinimal 'rulesets' $Leaf))
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should-BeFalse
        @($bytes | Where-Object { $_ -eq 13 }).Count | Should-Be 0
        $bytes[-1] | Should-Be ([byte]10)
        $bytes[-2] | Should-NotBe ([byte]10)
        $lines = [System.Text.Encoding]::UTF8.GetString($bytes).TrimEnd("`n").Split("`n")
        $lines[0] | Should-Be '{'
        $lines[-1] | Should-Be '}'
        foreach ($line in $lines[1..($lines.Count - 2)]) {
            $line | Should-MatchString '^(  "(name|description)": ".*",|  "rules": \[\]|  "rules": \[|    \{ "id": "[A-Z]{2,3}[0-9]{4}i?", "action": "(Error|Warning|Info|Hidden|None)" \},?|  \])$'
        }
        Test-Json -Path (Join-Path $validMinimal 'rulesets' $Leaf) -SchemaFile (Join-Path $repoRoot 'schemas' 'ruleset.endpoint.schema.json') | Should-BeTrue
    }

    It 'throws without settings' {
        $root = Join-Path $TestDrive 'empty'
        $null = New-Item -ItemType Directory -Path $root
        { Update-RulebookEndpoints -RepositoryRoot $root } | Should-Throw -ExceptionMessage 'Settings missing*'
    }
}

Describe 'Fixtures' {
    It 'valid-minimal <Key> lists exactly the derived entries' -ForEach $fixtureTables {
        $level, $stage = $Key.Split('.')
        $endpoint = Get-RulebookEndpoint -Inputs $inputs -Level $level -Stage $stage
        ((Get-EntryText $endpoint -WithSource) -join ', ') | Should-Be ($Expected -join ', ')
        $plain = @($Expected | ForEach-Object { ($_ -split ' ')[0..1] -join ' ' })
        ((Get-FileEntryText $validMinimal (Split-Path -Leaf $endpoint.File)) -join ', ') | Should-Be ($plain -join ', ')
    }

    It 'custom-level generates 15 endpoints with TA0001 Error from strict on' {
        $root = Copy-Fixture 'custom-level'
        $null = Update-RulebookEndpoints -RepositoryRoot $root
        $names = @(Get-RulesetFileName $root)
        $names.Count | Should-Be 15
        Assert-ContainsAll -Actual @($names) -Expected @('custom.ruleset.json', 'custom.ci.ruleset.json', 'custom.vnext.ruleset.json')
        foreach ($level in 'custom', 'strict', 'complete') {
            foreach ($leaf in "$level.ruleset.json", "$level.ci.ruleset.json", "$level.vnext.ruleset.json") {
                Assert-ContainsAll -Actual @(Get-FileEntryText $root $leaf) -Expected @('TA0001 Error')
            }
        }
        foreach ($leaf in 'essential.ruleset.json', 'recommended.ruleset.json', 'recommended.ci.ruleset.json') {
            @(Get-FileEntryText $root $leaf | Where-Object { $_ -like 'TA0001 *' }).Count | Should-Be 0
        }
        $custom = Read-RulebookInputs -RepositoryRoot $root
        (@($custom.ChainFiles['strict']) -join ',') | Should-Be 'essential,recommended,custom,strict'
        (Get-EffectiveAction -Inputs $custom -Id 'TA0001' -Level 'complete' -Stage 'ci').Source | Should-Be 'level:custom'
    }

    It 'alias-level endpoints equal Recommended under the alias name (<Stage>, criterion 3)' -ForEach @(@{ Stage = 'default' }, @{ Stage = 'ci' }, @{ Stage = 'vnext' }) {
        # The level content only: valid-minimal's LC0029 override is scoped to recommended, see the next test.
        $root = Copy-Fixture 'alias-level'
        Edit-FixtureJson -Path (Join-Path $root 'overrides.json') -Script { $_.rules = @($_.rules | Where-Object { $_.id -ne 'LC0029' }) }
        $alias = Read-RulebookInputs -RepositoryRoot $root
        $baseline = Get-RulebookEndpoint -Inputs $alias -Level 'baseline' -Stage $Stage
        $recommended = Get-RulebookEndpoint -Inputs $alias -Level 'recommended' -Stage $Stage
        ((Get-EntryText $baseline) -join ',') | Should-Be ((Get-EntryText $recommended) -join ',')
        $baseline.Name | Should-BeLikeString 'Rulebook Baseline / *'
    }

    It 'an override scoped to a level does not reach a level based on it (LC0029 in baseline.ci)' {
        $alias = Read-RulebookInputs -RepositoryRoot (Copy-Fixture 'alias-level')
        $result = Get-EffectiveAction -Inputs $alias -Id 'LC0029' -Level 'baseline' -Stage 'ci'
        "$($result.Action) $($result.Source)" | Should-Be 'Warning level:recommended'
        (Get-EffectiveAction -Inputs $alias -Id 'LC0029' -Level 'recommended' -Stage 'ci').Source | Should-Be 'override'
    }

    It 'quarantined-stage-entry keeps LC0099 at None in every ci endpoint and changes no endpoint' {
        $root = Copy-Fixture 'quarantined-stage-entry'
        $quarantined = Read-RulebookInputs -RepositoryRoot $root
        foreach ($level in 'essential', 'recommended', 'strict', 'complete') {
            $result = Get-EffectiveAction -Inputs $quarantined -Id 'LC0099' -Level $level -Stage 'ci'
            $result.Action | Should-Be 'None'
            $result.Source | Should-Be 'quarantine'
        }
        @(Update-RulebookEndpoints -RepositoryRoot $root -WhatIf).Count | Should-Be 0
    }

    It 'stale-endpoints differs from the generator in recommended.ci only' {
        $changes = @(Update-RulebookEndpoints -RepositoryRoot (Copy-Fixture 'stale-endpoints') -WhatIf)
        (@($changes | ForEach-Object { '{0} {1}' -f $_.File, $_.Change }) -join ',') | Should-Be 'rulesets/recommended.ci.ruleset.json modified'
    }

    It 'the overlay <Name> leaves the endpoints current' -ForEach @(@{ Name = 'unknown-id' }, @{ Name = 'bad-selector' }) {
        @(Update-RulebookEndpoints -RepositoryRoot (Copy-Fixture $Name) -WhatIf).Count | Should-Be 0
    }
}

Describe 'Compare-RulebookEndpoints' -Skip:$gitMissing {
    BeforeAll {
        function Initialize-DiffRepo {
            param([string]$Name = 'valid-minimal')
            $root = Copy-Fixture $Name
            $null = New-FixtureGitRepo -Root $root -Message 'before'
            return $root
        }
    }

    It 'returns no rows when nothing changed' {
        $root = Initialize-DiffRepo
        @(Compare-RulebookEndpoints -RepositoryRoot $root -Ref 'HEAD').Count | Should-Be 0
    }

    It 'shows an override change with its provenance' {
        $root = Initialize-DiffRepo
        Edit-FixtureJson -Path (Join-Path $root 'overrides.json') -Script { $_.rules = @($_.rules | Where-Object { $_.id -ne 'LC0029' }) }
        $rows = @(Compare-RulebookEndpoints -RepositoryRoot $root -Ref 'HEAD')
        $rows.Count | Should-Be 1
        $row = $rows[0]
        $row.Endpoint | Should-Be 'recommended.ci'
        $row.File | Should-Be 'rulesets/recommended.ci.ruleset.json'
        $row.Id | Should-Be 'LC0029'
        $row.Change | Should-Be 'action'
        $row.Before | Should-Be 'None'
        $row.BeforeSource | Should-Be 'override'
        $row.BeforeDetail | Should-Be 'Backlog DEV-1234'
        $row.After | Should-Be 'Warning'
        $row.AfterSource | Should-Be 'level:recommended'
        $row.ListedBefore | Should-BeTrue
        $row.ListedAfter | Should-BeFalse
        $row.Text | Should-Be 'LC0029: None (override, "Backlog DEV-1234") -> Warning (level:recommended)'
    }

    It 'shows a changed catalog default on an unmentioned id with default provenance on both sides (LC0001)' {
        $root = Initialize-DiffRepo
        Edit-FixtureJson -Path (Join-Path $root 'catalog' 'diagnostics.json') -Script {
            ($_.diagnostics | Where-Object { $_.id -eq 'LC0001' }).defaultSeverity = 'Info'
        }
        $rows = @(Compare-RulebookEndpoints -RepositoryRoot $root -Ref 'HEAD')
        $rows.Count | Should-Be 12
        foreach ($row in $rows) {
            $row.Id | Should-Be 'LC0001'
            $row.Change | Should-Be 'action'
            "$($row.Before) $($row.BeforeSource) -> $($row.After) $($row.AfterSource)" | Should-Be 'Warning default -> Info default'
            $row.ListedBefore | Should-BeFalse
            $row.ListedAfter | Should-BeFalse
        }
    }

    It 'shows a default moving onto the level action as a listing change (AW0006)' {
        $root = Initialize-DiffRepo
        Edit-FixtureJson -Path (Join-Path $root 'catalog' 'diagnostics.json') -Script {
            ($_.diagnostics | Where-Object { $_.id -eq 'AW0006' }).defaultSeverity = 'Error'
        }
        $rows = @(Compare-RulebookEndpoints -RepositoryRoot $root -Ref 'HEAD')
        $listing = @($rows | Where-Object Change -EQ 'listing')
        $listing.Count | Should-Be 9
        $row = $listing | Where-Object Endpoint -EQ 'recommended.ci'
        "$($row.Before) $($row.BeforeSource) -> $($row.After) $($row.AfterSource)" | Should-Be 'Error level:recommended -> Error level:recommended'
        $row.ListedBefore | Should-BeTrue
        $row.ListedAfter | Should-BeFalse
        @($rows | Where-Object Change -EQ 'action' | ForEach-Object Endpoint) | Should-BeCollection @('essential.default', 'essential.ci', 'essential.vnext')
    }

    It 'shows an added level as endpoint-added rows' {
        $root = Initialize-DiffRepo
        Edit-FixtureJson -Path (Join-Path $root '.github' 'Rulebook-Settings.json') -Script {
            $_.levels += @{ name = 'Paranoid'; basedOn = 'Complete'; description = 'Everything' }
        }
        Write-FixtureText -Path (Join-Path $root 'base' 'paranoid.ruleset.json') -Text '{ "name": "Rulebook Paranoid", "rules": [ { "id": "TA0001", "action": "Error" } ] }'
        $rows = @(Compare-RulebookEndpoints -RepositoryRoot $root -Ref 'HEAD')
        @($rows | ForEach-Object Endpoint | Select-Object -Unique) | Should-BeCollection @('paranoid.default', 'paranoid.ci', 'paranoid.vnext')
        @($rows | Where-Object Change -NE 'endpoint-added').Count | Should-Be 0
        $row = $rows | Where-Object { $_.Endpoint -eq 'paranoid.ci' -and $_.Id -eq 'TA0001' }
        $row.After | Should-Be 'Error'
        $row.AfterSource | Should-Be 'level:paranoid'
        $row.Before | Should-BeNull
        $row.File | Should-Be 'rulesets/paranoid.ci.ruleset.json'
    }

    It 'treats a ref without settings as an empty rulebook' {
        $root = Join-Path $TestDrive 'late'
        $null = New-Item -ItemType Directory -Path $root
        Write-FixtureText -Path (Join-Path $root 'README.md') -Text 'empty'
        $null = New-FixtureGitRepo -Root $root -Message 'empty'
        $null = New-FixtureRepo -Name 'valid-minimal' -Destination $root
        $rows = @(Compare-RulebookEndpoints -RepositoryRoot $root -Ref 'HEAD')
        @($rows | ForEach-Object Endpoint | Select-Object -Unique).Count | Should-Be 12
        @($rows | Where-Object Change -NE 'endpoint-added').Count | Should-Be 0
    }

    It 'resolves a rulebook nested under sub/dir of a bigger repository' {
        $outer = Join-Path $TestDrive 'outer'
        $root = New-FixtureRepo -Name 'valid-minimal' -Destination (Join-Path $outer 'sub' 'dir')
        Write-FixtureText -Path (Join-Path $outer 'README.md') -Text 'outer'
        $null = New-FixtureGitRepo -Root $outer -Message 'outer'
        Edit-FixtureJson -Path (Join-Path $root 'overrides.json') -Script { $_.rules = @($_.rules | Where-Object { $_.id -ne 'LC0029' }) }
        $rows = @(Compare-RulebookEndpoints -RepositoryRoot $root -Ref 'HEAD')
        $rows.Count | Should-Be 1
        $rows[0].Text | Should-Be 'LC0029: None (override, "Backlog DEV-1234") -> Warning (level:recommended)'
        (Read-RulebookInputs -RepositoryRoot $root -Ref 'HEAD').Source | Should-Be 'ref:HEAD'
    }

    It 'throws on an unknown ref and on a ref that looks like an option (<Ref>)' -ForEach @(@{ Ref = 'no-such-ref' }, @{ Ref = '--all' }, @{ Ref = '-p' }) {
        $root = Initialize-DiffRepo
        { Compare-RulebookEndpoints -RepositoryRoot $root -Ref $Ref } | Should-Throw -ExceptionMessage "Unknown git ref '$Ref'*"
    }

    It 'shows a justification that looks like a date as that date' {
        $root = Initialize-DiffRepo
        Edit-FixtureJson -Path (Join-Path $root 'overrides.json') -Script {
            ($_.rules | Where-Object { $_.id -eq 'LC0029' }).justification = '2026-10-03T00:00:00'
        }
        $null = New-FixtureGitRepo -Root $root -Message 'dated'
        Edit-FixtureJson -Path (Join-Path $root 'overrides.json') -Script { $_.rules = @($_.rules | Where-Object { $_.id -ne 'LC0029' }) }
        $rows = @(Compare-RulebookEndpoints -RepositoryRoot $root -Ref 'HEAD')
        $rows.Count | Should-Be 1
        $rows[0].Text | Should-Be 'LC0029: None (override, "2026-10-03") -> Warning (level:recommended)'
        $rows[0].BeforeDetail | Should-HaveType ([string])
    }

    It 'reads a committed file with a byte order mark like the working tree does' {
        $root = Copy-Fixture
        $path = Join-Path $root 'overrides.json'
        $bytes = [byte[]](@(0xEF, 0xBB, 0xBF) + [System.IO.File]::ReadAllBytes($path))
        [System.IO.File]::WriteAllBytes($path, $bytes)
        $null = New-FixtureGitRepo -Root $root -Message 'bom'
        $atRef = Read-RulebookInputs -RepositoryRoot $root -Ref 'HEAD'
        $atRef.Overrides.Count | Should-Be 2
        @(Compare-RulebookEndpoints -RepositoryRoot $root -Ref 'HEAD').Count | Should-Be 0
    }
}

Describe 'Performance' {
    It 'regenerates a 650-id synthetic rulebook in under 60 seconds (soft guard; the 30 s criterion on real content is WP04)' {
        $root = New-SyntheticRulebook -IdCount 650 -Destination (Join-Path $TestDrive 'synthetic')
        $elapsed = Measure-Command { $script:syntheticChanges = @(Update-RulebookEndpoints -RepositoryRoot $root) }
        Write-Host ('Update-RulebookEndpoints on 650 synthetic ids: {0:N2} s' -f $elapsed.TotalSeconds)
        $script:syntheticChanges.Count | Should-Be 9
        $elapsed.TotalSeconds | Should-BeLessThan 60
        @(Update-RulebookEndpoints -RepositoryRoot $root -WhatIf).Count | Should-Be 0
    }
}
