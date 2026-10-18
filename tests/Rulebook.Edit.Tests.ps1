# Edit suite for WP09 (#11) and WP15 (#17): modules/Rulebook.Edit on copies of tests/fixtures/repos/valid-minimal in
# TestDrive (docs/reference/change-mechanics.md), the issue bodies of tests/fixtures/issues/ and the change set schema.
# The GitHub API is mocked at Invoke-GitHubApi; the git side of Publish-RulebookChange runs against a bare repository.

BeforeDiscovery {
    $script:gitMissing = $null -eq (Get-Command git -ErrorAction SilentlyContinue)
}

BeforeAll {
    # The docs, schema and script URLs follow the engine ref: clear what a runner step would set, restore it in AfterAll.
    . (Join-Path $PSScriptRoot 'Helpers' 'EngineRef.ps1')
    $script:savedEngineRef = Clear-EngineRefEnvironment
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $PSScriptRoot 'Helpers' 'RepoFixture.ps1')
    Import-Module (Join-Path $repoRoot 'modules' 'Rulebook.Generate.psd1') -Force
    Import-Module (Join-Path $repoRoot 'modules' 'Rulebook.GitHub.psd1') -Force
    Import-Module (Join-Path $repoRoot 'modules' 'Rulebook.Edit.psd1') -Force
    $script:minimal = Join-Path $PSScriptRoot 'fixtures' 'repos' 'valid-minimal'
    $script:utf8 = [System.Text.UTF8Encoding]::new($false)
    $script:savedApiUrl = $env:GITHUB_API_URL
    $script:savedServerUrl = $env:GITHUB_SERVER_URL
    $env:GITHUB_API_URL = $null
    $env:GITHUB_SERVER_URL = $null

    function Get-TestFolder {
        return Join-Path $TestDrive ([guid]::NewGuid().ToString('n').Substring(0, 12))
    }

    function Copy-Minimal {
        return New-FixtureRepo -Name 'valid-minimal' -Destination (Get-TestFolder)
    }

    function Get-TreeHash {
        # '<relative path>=<SHA-256>' for every file under Root, to prove a folder was not touched.
        param([string]$Root)
        return @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force | Sort-Object FullName | ForEach-Object {
                '{0}={1}' -f [System.IO.Path]::GetRelativePath($Root, $_.FullName).Replace('\', '/'), (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
            })
    }

    function Invoke-Change {
        # Plans one form change on Root: Invoke-RulebookChangeSet with a work folder in TestDrive.
        param([string]$Root, [string]$RuleId, [string]$Action, [string[]]$Levels = @('*'), [string[]]$Stages = @('*'), [string]$Justification)
        $set = ConvertTo-RulebookChangeSet -RuleId $RuleId -Action $Action -Levels $Levels -Stages $Stages -Justification $Justification
        return Invoke-RulebookChangeSet -RepositoryRoot $Root -ChangeSet $set -WorkPath (Get-TestFolder) -Now ([System.DateTimeOffset]::new(2026, 10, 8, 9, 0, 0, [System.TimeSpan]::Zero))
    }

    function Get-EmptyFile {
        return Read-OverridesFile -Path (Join-Path (Get-TestFolder) 'overrides.json')
    }
}

AfterAll {
    Restore-EngineRefEnvironment -Saved $script:savedEngineRef
    $env:GITHUB_API_URL = $script:savedApiUrl
    $env:GITHUB_SERVER_URL = $script:savedServerUrl
    Remove-Module Rulebook.Edit, Rulebook.Quarantine, Rulebook.Update, Rulebook.Template, Rulebook.GitHub, Rulebook.Validate, Rulebook.Generate, Rulebook.Action, Rulebook.Common -ErrorAction SilentlyContinue
}

Describe 'overrides.json I/O' {
    It 'round-trips <Name> byte for byte' -ForEach @(
        @{ Name = 'template/overrides.json'; Path = (Join-Path (Split-Path -Parent $PSScriptRoot) 'template' 'overrides.json') }
        @{ Name = 'valid-minimal/overrides.json'; Path = (Join-Path $PSScriptRoot 'fixtures' 'repos' 'valid-minimal' 'overrides.json') }
    ) {
        $file = Read-OverridesFile -Path $Path
        $file.Exists | Should-BeTrue
        ConvertTo-OverridesJson -File $file | Should-Be ([System.IO.File]::ReadAllText($Path, $utf8))
    }

    It 'reads a missing file as empty, with the schema URL' {
        $file = Get-EmptyFile
        $file.Exists | Should-BeFalse
        $file.Rules.Count | Should-Be 0
        $file.Schema | Should-Be 'https://raw.githubusercontent.com/ALCops/rulebook-engine/main/schemas/rulebook-overrides.schema.json'
    }

    It 'reads comments and trailing commas as ConvertFrom-Json does' {
        $path = Join-Path (Get-TestFolder) 'overrides.json'
        Write-FixtureText -Path $path -Text ('{' + "`n" + '  // organization overrides' + "`n" + '  "rules": [' + "`n" + '    { "id": "LC0015", "action": "None", "levels": ["*"], "stages": ["ci"], },' + "`n" + '  ],' + "`n" + '}')
        $file = Read-OverridesFile -Path $path
        $file.Rules.Count | Should-Be 1
        ConvertTo-OverridesJson -File $file | Should-NotMatchString 'organization overrides'
    }

    It 'keeps a justification that looks like a date as text' {
        $path = Join-Path (Get-TestFolder) 'overrides.json'
        Write-FixtureText -Path $path -Text "{`n  `"rules`": [`n    { `"id`": `"LC0015`", `"action`": `"None`", `"levels`": [`"*`"], `"stages`": [`"ci`"], `"justification`": `"2026-10-03T10:00:00`" }`n  ]`n}"
        (Read-OverridesFile -Path $path).Rules[0].Justification | Should-Be '2026-10-03T10:00:00'
    }

    It 'writes only on a byte change, and -WhatIf reports without writing' {
        $root = Copy-Minimal
        $path = Join-Path $root 'overrides.json'
        $file = Read-OverridesFile -Path $path
        Write-OverridesFile -Path $path -File $file | Should-BeNull
        $null = Set-RulebookOverride -File $file -Id 'LC0015' -Action 'None' -Levels 'strict' -Stages 'ci'
        $before = [System.IO.File]::ReadAllText($path)
        $planned = Write-OverridesFile -Path $path -File $file -WhatIf
        $planned.Change | Should-Be 'modified'
        [System.IO.File]::ReadAllText($path) | Should-Be $before
        (Write-OverridesFile -Path $path -File $file).Change | Should-Be 'modified'
        [System.IO.File]::ReadAllText($path) | Should-Be (ConvertTo-OverridesJson -File $file)
    }
}

Describe 'Set-RulebookOverride and Remove-RulebookOverride' {
    It 'sets an entry on an empty rules array' {
        $file = Get-EmptyFile
        $result = Set-RulebookOverride -File $file -Id 'LC0015' -Action 'None' -Levels 'strict' -Stages 'ci' -Justification 'Legacy tables'
        $result.Change | Should-Be 'added'
        ConvertTo-OverridesJson -File $file | Should-Be "{`n  `"`$schema`": `"https://raw.githubusercontent.com/ALCops/rulebook-engine/main/schemas/rulebook-overrides.schema.json`",`n  `"rules`": [`n    { `"id`": `"LC0015`", `"action`": `"None`", `"levels`": [`"strict`"], `"stages`": [`"ci`"], `"justification`": `"Legacy tables`" }`n  ]`n}`n"
    }

    It 'replaces action and justification of an entry with the same selectors in place (order-insensitive)' {
        $file = Get-EmptyFile
        $null = Set-RulebookOverride -File $file -Id 'LC0015' -Action 'None' -Levels 'strict', 'complete' -Stages 'ci'
        $null = Set-RulebookOverride -File $file -Id 'AA0001' -Action 'Info' -Levels '*' -Stages '*'
        $result = Set-RulebookOverride -File $file -Id 'LC0015' -Action 'Warning' -Levels 'complete', 'strict' -Stages 'ci' -Justification 'Why'
        $result.Change | Should-Be 'replaced'
        $result.Previous.Action | Should-Be 'None'
        @($file.Rules | ForEach-Object Id) | Should-BeCollection @('LC0015', 'AA0001')
        $file.Rules[0].Action | Should-Be 'Warning'
        $file.Rules[0].Justification | Should-Be 'Why'
        # The selector order of the file is kept.
        $file.Rules[0].Levels | Should-BeCollection @('strict', 'complete')
    }

    It 'keeps the justification when the new one is empty' {
        $file = Get-EmptyFile
        $null = Set-RulebookOverride -File $file -Id 'LC0015' -Action 'None' -Levels 'strict' -Stages 'ci' -Justification 'Old'
        (Set-RulebookOverride -File $file -Id 'LC0015' -Action 'None' -Levels 'strict' -Stages 'ci' -Justification '').Change | Should-Be 'unchanged'
        $result = Set-RulebookOverride -File $file -Id 'LC0015' -Action 'Info' -Levels 'strict' -Stages 'ci'
        $result.Change | Should-Be 'replaced'
        $result.Previous.Justification | Should-Be 'Old'
        $file.Rules[0].Justification | Should-Be 'Old'
        ConvertTo-OverridesJson -File $file | Should-MatchString '"action": "Info", "levels": \["strict"\], "stages": \["ci"\], "justification": "Old" \}'
    }

    It 'adds an entry without a justification when none is given' {
        $file = Get-EmptyFile
        $null = Set-RulebookOverride -File $file -Id 'LC0015' -Action 'None' -Levels 'strict' -Stages 'ci'
        ConvertTo-OverridesJson -File $file | Should-NotMatchString 'justification'
    }

    It 'reports unchanged for the same action and justification' {
        $file = Get-EmptyFile
        $null = Set-RulebookOverride -File $file -Id 'LC0015' -Action 'None' -Levels 'strict' -Stages 'ci' -Justification 'Same'
        (Set-RulebookOverride -File $file -Id 'LC0015' -Action 'None' -Levels 'strict' -Stages 'ci' -Justification 'Same').Change | Should-Be 'unchanged'
        $file.Rules.Count | Should-Be 1
    }

    It 'keeps one entry per selector set: duplicates collapse into the last one (effective), at its position' {
        $file = Get-EmptyFile
        $file.Rules.Add([pscustomobject]@{ Id = 'LC0015'; Action = 'None'; Levels = [string[]]@('strict'); Stages = [string[]]@('ci'); Justification = 'First' })
        $file.Rules.Add([pscustomobject]@{ Id = 'AA0001'; Action = 'Info'; Levels = [string[]]@('*'); Stages = [string[]]@('*'); Justification = $null })
        $file.Rules.Add([pscustomobject]@{ Id = 'LC0015'; Action = 'Info'; Levels = [string[]]@('strict'); Stages = [string[]]@('ci'); Justification = 'Last' })
        $result = Set-RulebookOverride -File $file -Id 'LC0015' -Action 'Info' -Levels 'strict' -Stages 'ci'
        $result.Change | Should-Be 'deduplicated'
        $result.Previous.Justification | Should-Be 'Last'
        @($file.Rules | ForEach-Object Id) | Should-BeCollection @('AA0001', 'LC0015')
        $file.Rules[1].Action | Should-Be 'Info'
        $file.Rules[1].Justification | Should-Be 'Last'
    }

    It 'reports deduplicated when only duplicates of the effective entry go' {
        $file = Get-EmptyFile
        $file.Rules.Add([pscustomobject]@{ Id = 'LC0015'; Action = 'None'; Levels = [string[]]@('strict'); Stages = [string[]]@('ci'); Justification = 'Same' })
        $file.Rules.Add([pscustomobject]@{ Id = 'LC0015'; Action = 'None'; Levels = [string[]]@('strict'); Stages = [string[]]@('ci'); Justification = 'Same' })
        (Set-RulebookOverride -File $file -Id 'LC0015' -Action 'None' -Levels 'strict' -Stages 'ci').Change | Should-Be 'deduplicated'
        $file.Rules.Count | Should-Be 1
    }

    It 'appends an entry with different selectors' {
        $file = Get-EmptyFile
        $null = Set-RulebookOverride -File $file -Id 'LC0015' -Action 'None' -Levels 'strict' -Stages 'ci'
        (Set-RulebookOverride -File $file -Id 'LC0015' -Action 'None' -Levels '*' -Stages 'ci').Change | Should-Be 'added'
        $file.Rules.Count | Should-Be 2
    }

    It 'rejects <Name>' -ForEach @(
        @{ Name = 'an action outside the five'; Action = 'Default'; Levels = @('strict'); Message = "*action 'Default'*" }
        @{ Name = 'an empty selector'; Action = 'None'; Levels = @(); Message = '*levels is empty*' }
        @{ Name = "'*' mixed with slugs"; Action = 'None'; Levels = @('*', 'strict'); Message = "*levels mixes '*'*" }
    ) {
        $file = Get-EmptyFile
        { Set-RulebookOverride -File $file -Id 'LC0015' -Action $Action -Levels $Levels -Stages 'ci' } | Should-Throw -ExceptionMessage $Message
    }

    It 'removes the entry and leaves the file otherwise byte-identical (AC4)' {
        $root = Copy-Minimal
        $path = Join-Path $root 'overrides.json'
        $file = Read-OverridesFile -Path $path
        $result = Remove-RulebookOverride -File $file -Id 'LC0029' -Levels 'recommended' -Stages 'ci'
        $result.Change | Should-Be 'removed'
        $result.Entry.Justification | Should-Be 'Backlog DEV-1234'
        $null = Write-OverridesFile -Path $path -File $file
        $expected = [System.IO.File]::ReadAllText((Join-Path $minimal 'overrides.json')).Replace(",`n    { `"id`": `"LC0029`", `"action`": `"None`", `"levels`": [`"recommended`"], `"stages`": [`"ci`"], `"justification`": `"Backlog DEV-1234`" }", '')
        [System.IO.File]::ReadAllText($path) | Should-Be $expected
        $expected | Should-MatchString '\A\{\n  "\$schema": .*\n  "rules": \[\n    \{ "id": "AA0072", .* \}\n  \]\n\}\n\z'
    }

    It 'lists the entries of the id when nothing matches the selectors' {
        $file = Get-EmptyFile
        $null = Set-RulebookOverride -File $file -Id 'LC0015' -Action 'None' -Levels '*' -Stages 'ci'
        $null = Set-RulebookOverride -File $file -Id 'LC0015' -Action 'Info' -Levels 'strict' -Stages '*'
        $thrown = $null
        try { $null = Remove-RulebookOverride -File $file -Id 'LC0015' -Levels 'strict' -Stages 'ci' } catch { $thrown = $_.Exception }
        $thrown.Message | Should-Be 'overrides.json has no entry for LC0015 with levels [strict] and stages [ci]; existing entries for LC0015: None (levels: *, stages: ci), Info (levels: strict, stages: *)'
        $thrown.Data['Stage'] | Should-Be 'validation'
        { Remove-RulebookOverride -File $file -Id 'AA0001' -Levels '*' -Stages '*' } | Should-Throw -ExceptionMessage 'overrides.json has no entry for AA0001'
    }
}

Describe 'ConvertTo-RulebookChangeSet and Test-RulebookChangeSet' {
    BeforeAll {
        $script:inputs = Read-RulebookInputs -RepositoryRoot $minimal
    }

    It 'builds a one-item set of version 1; Remove becomes op remove without an action' {
        $set = ConvertTo-RulebookChangeSet -RuleId 'LC0015' -Action 'none' -Levels 'strict' -Stages 'ci' -Justification ' Legacy ' -Note ' Agreed '
        @($set.Keys) | Should-BeCollection @('version', 'note', 'changes')
        $set['version'] | Should-Be 1
        $set['note'] | Should-Be 'Agreed'
        $set['changes'].Count | Should-Be 1
        $set['changes'][0]['op'] | Should-Be 'set'
        $set['changes'][0]['action'] | Should-Be 'None'
        $set['changes'][0]['justification'] | Should-Be 'Legacy'
        $remove = ConvertTo-RulebookChangeSet -RuleId 'LC0015' -Action 'Remove' -Levels '*' -Stages '*'
        $remove['changes'][0]['op'] | Should-Be 'remove'
        $remove['changes'][0].Contains('action') | Should-BeFalse
    }

    It 'drops repeated slugs and reports an empty selector as a finding' {
        $set = ConvertTo-RulebookChangeSet -RuleId 'LC0015' -Action 'None' -Levels 'strict', 'strict', 'complete' -Stages ''
        $set['changes'][0]['levels'] | Should-BeCollection @('strict', 'complete')
        $findings = @(Test-RulebookChangeSet -ChangeSet $set -Inputs $inputs)
        $findings[0].Message | Should-Be 'change 1 has no stages; use a slug from the settings or ["*"]'
    }

    It 'accepts a valid set' {
        @(Test-RulebookChangeSet -ChangeSet (ConvertTo-RulebookChangeSet -RuleId 'LC0015' -Action 'None' -Levels 'strict' -Stages 'ci') -Inputs $inputs) | Should-BeCollection @()
    }

    It 'reports <Name>' -ForEach @(
        @{ Name = 'a bad id'; Set = @{ changes = @(@{ op = 'set'; id = 'lc15'; action = 'None'; levels = @('*'); stages = @('*') }) }; Message = "'lc15' is not a diagnostic id*" }
        @{ Name = 'an id outside the catalog'; Set = @{ changes = @(@{ op = 'set'; id = 'LC9999'; action = 'None'; levels = @('*'); stages = @('*') }) }; Message = 'LC9999 is not in catalog/diagnostics.json' }
        @{ Name = 'a bad action'; Set = @{ changes = @(@{ op = 'set'; id = 'LC0015'; action = 'Default'; levels = @('*'); stages = @('*') }) }; Message = "action 'Default': use Error, Warning, Info, Hidden or None" }
        @{ Name = 'an unknown slug (C10 wording)'; Set = @{ changes = @(@{ op = 'set'; id = 'LC0015'; action = 'None'; levels = @('house'); stages = @('*') }) }; Message = "change 1 names unknown level 'house'; use a slug from the settings or *" }
        @{ Name = 'a release with levels'; Set = @{ changes = @(@{ op = 'release'; id = 'LC0099'; levels = @('*'); stages = @('*') }) }; Message = "change 1: op 'release' takes no levels; it releases the id from the quarantine of the listed stages" }
        @{ Name = 'an unsupported op'; Set = @{ changes = @(@{ op = 'rename'; id = 'LC0015'; levels = @('*'); stages = @('*') }) }; Message = "change 1: op 'rename' is not supported; use set, remove or release" }
        @{ Name = 'a wildcard mixed with slugs'; Set = @{ changes = @(@{ op = 'set'; id = 'LC0015'; action = 'None'; levels = @('*', 'strict'); stages = @('ci') }) }; Message = "change 1 mixes '*' with other values in levels; use *" }
        @{ Name = 'an empty change list'; Set = @{ changes = @() }; Message = 'The change set has no changes.' }
        @{ Name = 'a duplicate'; Set = @{ changes = @(@{ op = 'set'; id = 'LC0015'; action = 'None'; levels = @('strict', 'complete'); stages = @('ci') }, @{ op = 'set'; id = 'LC0015'; action = 'Info'; levels = @('complete', 'strict'); stages = @('ci') }) }; Message = 'change 2 repeats an earlier change*' }
    ) {
        $findings = @(Test-RulebookChangeSet -ChangeSet $Set -Inputs $inputs)
        $findings.Count | Should-Be 1
        $findings[0].Rule | Should-Be 'change'
        $findings[0].File | Should-Be 'overrides.json'
        $findings[0].Message | Should-BeLikeString $Message
    }
}

Describe 'Invoke-RulebookChangeSet' {
    It 'regenerates exactly one endpoint for strict/ci (AC1)' {
        $root = Copy-Minimal
        $before = Get-TreeHash -Root $root
        $plan = Invoke-Change -Root $root -RuleId 'LC0015' -Action 'None' -Levels 'strict' -Stages 'ci'
        $plan.Valid | Should-BeTrue
        $plan.NoOp | Should-BeFalse
        @($plan.Changes | ForEach-Object File) | Should-BeCollection @('overrides.json', 'rulesets/strict.ci.ruleset.json')
        $plan.Items[0].Entry.Change | Should-Be 'added'
        $plan.Items[0].ChangedEndpoints | Should-BeCollection @('strict.ci')
        $row = $plan.Items[0].Rows[0]
        $row.Before | Should-Be 'Warning'
        $row.BeforeSource | Should-Be 'level:strict'
        $row.After | Should-Be 'None'
        $row.AfterSource | Should-Be 'override'
        $plan.Title | Should-Be 'Change LC0015 to None (levels: strict, stages: ci)'
        # The repository itself is never written.
        Get-TreeHash -Root $root | Should-BeCollection $before
    }

    It 'changes all 12 endpoints with * and * and validates (AC2)' {
        $plan = Invoke-Change -Root (Copy-Minimal) -RuleId 'LC0015' -Action 'Error'
        $plan.Valid | Should-BeTrue
        $plan.Items[0].Rows.Count | Should-Be 12
        $plan.Items[0].ChangedEndpoints.Count | Should-Be 12
        @($plan.Changes | Where-Object { $_.File -like 'rulesets/*' }).Count | Should-Be 12
    }

    It 'unlists an id set to its analyzer default where the base deviates, and says so (AC3)' {
        $plan = Invoke-Change -Root (Copy-Minimal) -RuleId 'AA0001' -Action 'Warning' -Levels 'essential' -Stages 'default'
        $row = $plan.Items[0].Rows[0]
        $row.Changed | Should-BeTrue
        $row.ListedBefore | Should-BeTrue
        $row.ListedAfter | Should-BeFalse
        $row.Note | Should-Be 'now unlisted in essential.default: Warning equals the analyzer default'
        $endpoint = [System.IO.File]::ReadAllText((Join-Path $plan.CandidatePath 'rulesets' 'essential.ruleset.json'))
        $endpoint | Should-NotMatchString '"AA0001"'
        ConvertTo-ChangePullRequestBody -Plan $plan | Should-MatchString '(?m)^- AA0001 now unlisted in essential\.default: Warning equals the analyzer default\.$'
    }

    It 'is a no-op when nothing changes: nothing written, Changes empty (AC6)' {
        $plan = Invoke-Change -Root (Copy-Minimal) -RuleId 'AA0072' -Action 'Info'
        $plan.NoOp | Should-BeTrue
        $plan.Valid | Should-BeTrue
        $plan.OverridesChange | Should-BeNull
        @($plan.Changes) | Should-BeCollection @()
        @($plan.Items[0].Rows | Where-Object Note -NE 'unchanged') | Should-BeCollection @()
        [System.IO.File]::ReadAllText((Join-Path $plan.CandidatePath 'overrides.json')) | Should-Be ([System.IO.File]::ReadAllText((Join-Path $minimal 'overrides.json')))
        # The entry keeps its text, and the body says so.
        ConvertTo-ChangePullRequestBody -Plan $plan | Should-MatchString '\AJustification: House style\n'
    }

    It 'is a no-op for a new entry that changes no endpoint (a dead entry is not written)' {
        # AA0001 is Warning on strict.ci already (level:recommended).
        $plan = Invoke-Change -Root (Copy-Minimal) -RuleId 'AA0001' -Action 'Warning' -Levels 'strict' -Stages 'ci'
        $plan.NoOp | Should-BeTrue
        $plan.Items[0].Entry.Change | Should-Be 'added'
        @($plan.Changes) | Should-BeCollection @()
        $plan.Items[0].Rows[0].Note | Should-Be 'unchanged'
        # The rows show the real state: the level decides, no override was stored.
        $plan.Items[0].Rows[0].AfterSource | Should-Be 'level:recommended'
        $plan.OverridesChange | Should-BeNull
        ConvertTo-ChangeSummary -Plan $plan -Message 'x' | Should-MatchString '(?m)^Leaves AA0001 at Warning for levels strict, stages ci \(every matching endpoint has that action already; no entry is written\)\.$'
    }

    It 'words the sentence of a masked dead entry from the rows' {
        $root = Copy-Minimal
        $path = Join-Path $root 'overrides.json'
        $text = [System.IO.File]::ReadAllText($path)
        $extra = ',' + "`n" + '    { "id": "LC0015", "action": "None", "levels": ["strict"], "stages": ["ci"] }'
        Write-FixtureText -Path $path -Text $text.Replace('"justification": "Backlog DEV-1234" }', '"justification": "Backlog DEV-1234" }' + $extra)
        $plan = Invoke-Change -Root $root -RuleId 'LC0015' -Action 'Warning' -Levels 'strict' -Stages '*'
        $plan.NoOp | Should-BeTrue
        @($plan.Items[0].Rows | Where-Object Endpoint -EQ 'strict.ci' | ForEach-Object AfterSource) | Should-BeCollection @('override')
        ConvertTo-ChangeSummary -Plan $plan -Message 'x' | Should-MatchString '(?m)^Leaves LC0015 as it is for levels strict, stages \* \(2 at Warning; 1 decided by a more specific entry or input; no entry is written\)\.$'
    }

    It 'keeps the precedence when it collapses duplicates (the survivor takes the last position)' {
        $root = Copy-Minimal
        $lines = @(
            '{'
            '  "rules": ['
            '    { "id": "AA0072", "action": "Error", "levels": ["strict"], "stages": ["*"], "justification": "d1" },'
            '    { "id": "AA0072", "action": "None", "levels": ["*"], "stages": ["ci"], "justification": "X" },'
            '    { "id": "AA0072", "action": "Error", "levels": ["strict"], "stages": ["*"], "justification": "d2" }'
            '  ]'
            '}'
        )
        Write-FixtureText -Path (Join-Path $root 'overrides.json') -Text ($lines -join "`n")
        $null = Update-RulebookEndpoints -RepositoryRoot $root
        $plan = Invoke-Change -Root $root -RuleId 'AA0072' -Action 'Error' -Levels 'strict' -Stages '*'
        $plan.Items[0].Entry.Change | Should-Be 'deduplicated'
        $plan.Items[0].ChangedEndpoints | Should-BeCollection @()
        @($plan.Changes | ForEach-Object File) | Should-BeCollection @('overrides.json')
        $file = Read-OverridesFile -Path (Join-Path $plan.CandidatePath 'overrides.json')
        @($file.Rules | ForEach-Object Justification) | Should-BeCollection @('X', 'd2')
    }

    It 'says a given justification was not stored when the new entry is dead' {
        $plan = Invoke-Change -Root (Copy-Minimal) -RuleId 'AA0001' -Action 'Warning' -Levels 'strict' -Stages 'ci' -Justification 'Why'
        $plan.NoOp | Should-BeTrue
        ConvertTo-ChangeSummary -Plan $plan -Message 'x' | Should-MatchString '(?m)^Justification given but not stored \(no entry was written\): Why$'
    }

    It 'writes only the live item of a set with a dead new entry and a real change' {
        $root = Copy-Minimal
        $set = @{ changes = @(
                [ordered]@{ op = 'set'; id = 'AA0001'; action = 'Warning'; levels = @('strict'); stages = @('ci') }
                [ordered]@{ op = 'set'; id = 'LC0015'; action = 'None'; levels = @('strict'); stages = @('ci') }
            ) }
        $plan = Invoke-RulebookChangeSet -RepositoryRoot $root -ChangeSet $set -WorkPath (Get-TestFolder)
        $plan.NoOp | Should-BeFalse
        $plan.Items[0].NoOp | Should-BeTrue
        $plan.Items[1].ChangedEndpoints | Should-BeCollection @('strict.ci')
        $written = [System.IO.File]::ReadAllText((Join-Path $plan.CandidatePath 'overrides.json'))
        $written | Should-MatchString '"id": "LC0015"'
        $written | Should-NotMatchString '"id": "AA0001"'
        $plan.Title | Should-Be 'Rulebook change: 2 changes'
    }

    It 'writes the removal of duplicate entries with the note duplicate entries removed' {
        $root = Copy-Minimal
        $path = Join-Path $root 'overrides.json'
        $text = [System.IO.File]::ReadAllText($path)
        $line = '    { "id": "AA0072", "action": "Info", "levels": ["*"], "stages": ["*"], "justification": "House style" },'
        Write-FixtureText -Path $path -Text $text.Replace($line, $line + "`n" + $line)
        $plan = Invoke-Change -Root $root -RuleId 'AA0072' -Action 'Info'
        $plan.NoOp | Should-BeFalse
        $plan.Items[0].Entry.Change | Should-Be 'deduplicated'
        @($plan.Items[0].Rows | ForEach-Object Note | Select-Object -Unique) | Should-BeCollection @('duplicate entries removed')
        @($plan.Changes | ForEach-Object File) | Should-BeCollection @('overrides.json')
        ConvertTo-ChangePullRequestBody -Plan $plan | Should-MatchString '(?m)^Removes the duplicate entries of AA0072 for levels \*, stages \* \(the action stays Info\)\.$'
    }

    It 'is a no-op for a narrower entry that repeats an existing broader one' {
        $plan = Invoke-Change -Root (Copy-Minimal) -RuleId 'AA0072' -Action 'Info' -Levels 'strict' -Stages 'ci'
        $plan.NoOp | Should-BeTrue
        @($plan.Changes) | Should-BeCollection @()
    }

    It 'is a no-op with the same justification given again' {
        (Invoke-Change -Root (Copy-Minimal) -RuleId 'AA0072' -Action 'Info' -Justification 'House style').NoOp | Should-BeTrue
    }

    It 'writes a justification-only edit, rows unchanged with the note, no ruleset change' {
        $plan = Invoke-Change -Root (Copy-Minimal) -RuleId 'AA0072' -Action 'Info' -Justification 'Team decision'
        $plan.NoOp | Should-BeFalse
        $plan.Valid | Should-BeTrue
        @($plan.Changes | ForEach-Object File) | Should-BeCollection @('overrides.json')
        @($plan.Items[0].Rows | ForEach-Object Note | Select-Object -Unique) | Should-BeCollection @('justification updated')
        ConvertTo-ChangePullRequestBody -Plan $plan | Should-MatchString '(?m)^Updates the justification of the AA0072 entry for levels \*, stages \* \(the action stays Info\)\.$'
    }

    It 'writes a partial change with the unchanged rows marked' {
        $plan = Invoke-Change -Root (Copy-Minimal) -RuleId 'AA0001' -Action 'None'
        $plan.NoOp | Should-BeFalse
        @($plan.Items[0].Rows | Where-Object { $_.Endpoint -like 'essential.*' } | ForEach-Object Note | Select-Object -Unique) | Should-BeCollection @('unchanged')
        $plan.Items[0].ChangedEndpoints.Count | Should-Be 9
        ConvertTo-ChangePullRequestBody -Plan $plan | Should-MatchString '(?m)^- 3 of 12 matching endpoints are unchanged\.$'
    }

    It 'expands * in settings order' {
        $plan = Invoke-Change -Root (Copy-Minimal) -RuleId 'LC0015' -Action 'Error'
        @($plan.Items[0].Rows | ForEach-Object Endpoint | Select-Object -First 4) | Should-BeCollection @('essential.default', 'essential.ci', 'essential.vnext', 'recommended.default')
    }

    It 'stops an invalid id before anything is copied, the repository untouched (AC5)' {
        $root = Copy-Minimal
        $before = Get-TreeHash -Root $root
        $work = Get-TestFolder
        $set = ConvertTo-RulebookChangeSet -RuleId 'LC9999' -Action 'Warning' -Levels '*' -Stages '*'
        $plan = Invoke-RulebookChangeSet -RepositoryRoot $root -ChangeSet $set -WorkPath $work
        $plan.Failure | Should-Be 'validation'
        $plan.Valid | Should-BeFalse
        $plan.CandidatePath | Should-BeNull
        Test-Path -LiteralPath (Join-Path $work 'candidate') | Should-BeFalse
        Get-TreeHash -Root $root | Should-BeCollection $before
    }

    It 'fails validation on a remove without a matching entry' {
        $plan = Invoke-Change -Root (Copy-Minimal) -RuleId 'AA0001' -Action 'Remove' -Levels 'strict' -Stages 'ci'
        $plan.Failure | Should-Be 'validation'
        $plan.Findings[0].Message | Should-Be 'overrides.json has no entry for AA0001'
    }

    It 'removes an entry: never a no-op, the endpoint regenerated' {
        $plan = Invoke-Change -Root (Copy-Minimal) -RuleId 'LC0029' -Action 'Remove' -Levels 'recommended' -Stages 'ci'
        $plan.Valid | Should-BeTrue
        $plan.NoOp | Should-BeFalse
        $plan.Title | Should-Be 'Remove override for LC0029 (levels: recommended, stages: ci)'
        @($plan.Changes | ForEach-Object File) | Should-BeCollection @('overrides.json', 'rulesets/recommended.ci.ruleset.json')
        # A remove has no justification paragraph.
        ConvertTo-ChangePullRequestBody -Plan $plan | Should-MatchString '\ARemoves the override entry for LC0029 with levels recommended, stages ci \(it was None\)\.\n'
    }
}

Describe 'Rendering' {
    BeforeAll {
        $script:plan = Invoke-Change -Root (Copy-Minimal) -RuleId 'LC0015' -Action 'None' -Levels 'strict' -Stages 'ci' -Justification 'Legacy tables | tracked in issue 42'
    }

    It 'renders the table with provenance and escaped free text' {
        $table = ConvertTo-ChangeTable -Rows $plan.Items[0].Rows
        $table | Should-Be "| Endpoint | Before | After | Note |`n|---|---|---|---|`n| strict.ci | Warning (level:strict) | None (override, `"Legacy tables \| tracked in issue 42`") |  |`n"
    }

    It 'opens the body with the justification and one sentence per item' {
        $body = ConvertTo-ChangePullRequestBody -Plan $plan
        $body | Should-MatchString '\AJustification: Legacy tables \| tracked in issue 42\n\nSets LC0015 to None for levels strict, stages ci \(adds an entry\)\.\n\n\| Endpoint \| Before \| After \| Note \|\n'
        $body | Should-MatchString '[^\n]\n\z'
    }

    It 'keeps a multi-line justification on one line in the body' {
        $multi = Invoke-Change -Root (Copy-Minimal) -RuleId 'LC0015' -Action 'None' -Levels 'strict' -Stages 'ci' -Justification "Legacy`n## Effective diff"
        $body = ConvertTo-ChangePullRequestBody -Plan $multi
        $body | Should-MatchString '\AJustification: Legacy ## Effective diff\n'
        $body | Should-NotMatchString '(?m)^## '
    }

    It 'says when no justification is given' {
        $bare = Invoke-Change -Root (Copy-Minimal) -RuleId 'LC0015' -Action 'None' -Levels 'strict' -Stages 'ci'
        ConvertTo-ChangePullRequestBody -Plan $bare | Should-MatchString '\ANo justification given\.\n'
    }

    It 'leaves the table out above the limit, with a line saying so' {
        $wide = Invoke-Change -Root (Copy-Minimal) -RuleId 'LC0015' -Action 'Error'
        $body = ConvertTo-ChangePullRequestBody -Plan $wide -Limit 500
        $body | Should-NotMatchString '\| Endpoint \|'
        $body | Should-MatchString '_1 of 1 change tables were left out to keep this body below the GitHub limit; the job summary of the change run has them all\._\n\z'
    }

    It 'writes the summary with the result, the table and the effective diff' {
        $diff = @([pscustomobject]@{ Endpoint = 'strict.ci'; File = 'rulesets/strict.ci.ruleset.json'; Id = 'LC0015'; Before = 'Warning'; After = 'None'; BeforeSource = 'level:strict'; AfterSource = 'override'; BeforeDetail = $null; AfterDetail = 'Legacy'; ListedBefore = $true; ListedAfter = $true; Change = 'action' })
        $result = [pscustomobject]@{ Result = 'pull-request'; PullRequestUrl = 'https://github.com/Contoso/rulebook/pull/7'; Branch = 'change-rule/LC0015/261008090000'; Sha = 'a' * 40; Fallback = $false; Diff = $diff; DiffNote = $null }
        $summary = ConvertTo-ChangeSummary -Plan $plan -Result $result -Message 'Pull request: https://github.com/Contoso/rulebook/pull/7'
        $summary | Should-MatchString '\A## Rule change\n\nPull request: https://github\.com/Contoso/rulebook/pull/7\n\nPull request: https://github\.com/Contoso/rulebook/pull/7 \(branch `change-rule/LC0015/261008090000`\)\n'
        $summary | Should-MatchString '(?m)^\| strict\.ci \| Warning \(level:strict\) \|'
        $summary | Should-MatchString '(?m)^## Effective diff\n\n### `strict\.ci` \(`rulesets/strict\.ci\.ruleset\.json`\)$'
        ConvertTo-ChangePullRequestBody -Plan $plan | Should-NotMatchString 'Effective diff'
    }

    It 'writes the summary of a change with an empty effective diff' {
        $justification = Invoke-Change -Root (Copy-Minimal) -RuleId 'AA0072' -Action 'Info' -Justification 'Team decision'
        $result = [pscustomobject]@{ Result = 'pull-request'; PullRequestUrl = 'https://github.com/Contoso/rulebook/pull/8'; Branch = 'change-rule/AA0072/261008090000'; Sha = 'b' * 40; Fallback = $false; Diff = @(); DiffNote = $null }
        $summary = ConvertTo-ChangeSummary -Plan $justification -Result $result -Message 'm'
        $summary | Should-MatchString '(?m)^Justification: Team decision$'
        $summary | Should-MatchString '(?m)^\| essential\.default \| Info \(override, "House style"\) \| Info \(override, "Team decision"\) \| justification updated \|$'
        $summary | Should-NotMatchString 'Effective diff'
    }

    It 'lists validation errors in the summary' {
        $invalid = Invoke-Change -Root (Copy-Minimal) -RuleId 'LC9999' -Action 'None'
        ConvertTo-ChangeSummary -Plan $invalid -Message 'x' | Should-MatchString '(?m)^\| change \| `overrides\.json` \| LC9999 \| LC9999 is not in catalog/diagnostics\.json \|$'
    }
}

Describe 'Publish-RulebookChange against a bare repository' -Skip:$gitMissing {
    BeforeAll {
        $script:now = [System.DateTimeOffset]::new(2026, 10, 8, 9, 15, 30, [System.TimeSpan]::Zero)
        function New-Origin {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helper; writes only to TestDrive')]
            param([switch]$Reject)
            $bare = New-BareFixtureRepo -Source $minimal -Destination (Join-Path (Get-TestFolder) 'origin.git')
            if ($Reject) { Add-RejectPushHook -BarePath $bare -Branch 'main' }
            return $bare
        }
    }

    BeforeEach {
        Mock Invoke-GitHubApi -ModuleName Rulebook.GitHub -ParameterFilter { $Method -eq 'POST' -and $Path -eq 'repos/Contoso/rulebook/pulls' } {
            [pscustomobject]@{ StatusCode = 201; Body = @{ number = 7; html_url = 'https://github.com/Contoso/rulebook/pull/7' }; Text = ''; Headers = $null; RateLimitRemaining = $null }
        }
        Mock Invoke-GitHubApi -ModuleName Rulebook.GitHub -ParameterFilter { $Method -eq 'POST' -and $Path -eq 'repos/Contoso/rulebook/issues/7/labels' } {
            [pscustomobject]@{ StatusCode = 200; Body = @(); Text = '[]'; Headers = $null; RateLimitRemaining = $null }
        }
        $script:plan = Invoke-Change -Root (Copy-Minimal) -RuleId 'LC0015' -Action 'None' -Levels 'strict' -Stages 'ci' -Justification 'Legacy tables'
    }

    It 'pushes change-rule/<id>/<timestamp> and opens the labelled pull request with the body' {
        $bare = New-Origin
        $originSha = (& git -C $bare rev-parse refs/heads/main).Trim()
        $result = Publish-RulebookChange -Plan $plan -Repository 'Contoso/rulebook' -RemoteUrl $bare -Token 'ghs_x' -BaseBranch 'main' -BranchPrefix 'change-rule/LC0015' -Actor 'octocat' -Labels @('rulebook') -WorkPath (Get-TestFolder) -Now $now
        $result.Result | Should-Be 'pull-request'
        $result.Branch | Should-Be 'change-rule/LC0015/261008091530'
        $result.Number | Should-Be 7
        $result.PullRequestUrl | Should-Be 'https://github.com/Contoso/rulebook/pull/7'
        (& git -C $bare log -1 --format=%s $result.Branch) | Should-Be 'Change LC0015 to None (levels: strict, stages: ci)'
        (& git -C $bare rev-parse refs/heads/main).Trim() | Should-Be $originSha
        @(& git -C $bare diff --name-only "main..$($result.Branch)") | Should-BeCollection @('overrides.json', 'rulesets/strict.ci.ruleset.json')
        @($result.Diff | ForEach-Object Endpoint) | Should-BeCollection @('strict.ci')
        $result.Body | Should-MatchString '\AJustification: Legacy tables\n'
        Should-Invoke Invoke-GitHubApi -ModuleName Rulebook.GitHub -Times 1 -Exactly -ParameterFilter { $Method -eq 'POST' -and $Path -eq 'repos/Contoso/rulebook/pulls' -and $Body.title -eq 'Change LC0015 to None (levels: strict, stages: ci)' -and $Body.head -eq 'change-rule/LC0015/261008091530' -and $Body.base -eq 'main' }
        Should-Invoke Invoke-GitHubApi -ModuleName Rulebook.GitHub -Times 1 -Exactly -ParameterFilter { $Path -eq 'repos/Contoso/rulebook/issues/7/labels' -and (@($Body.labels) -join ',') -eq 'rulebook' }
    }

    It 'pushes a direct commit to the base branch' {
        $bare = New-Origin
        $result = Publish-RulebookChange -Plan $plan -Repository 'Contoso/rulebook' -RemoteUrl $bare -Token 'ghs_x' -BaseBranch 'main' -BranchPrefix 'change-rule/LC0015' -DirectCommit -WorkPath (Get-TestFolder) -Now $now
        $result.Result | Should-Be 'direct-commit'
        $result.Branch | Should-Be 'main'
        (& git -C $bare rev-parse refs/heads/main).Trim() | Should-Be $result.Sha
        Should-Invoke Invoke-GitHubApi -ModuleName Rulebook.GitHub -Times 0 -Exactly
    }

    It 'falls back to the pull request when the direct push is refused' {
        $bare = New-Origin -Reject
        $result = Publish-RulebookChange -Plan $plan -Repository 'Contoso/rulebook' -RemoteUrl $bare -Token 'ghs_x' -BaseBranch 'main' -BranchPrefix 'change-rule/LC0015' -DirectCommit -WorkPath (Get-TestFolder) -Now $now
        $result.Result | Should-Be 'pull-request'
        $result.Fallback | Should-BeTrue
        $result.FallbackReason | Should-BeLikeString '*main is protected*'
        $result.Branch | Should-Be 'change-rule/LC0015/261008091530'
    }

    It 'keeps the refusal on the push-stage failure when the change branch is refused too' {
        $bare = New-Origin
        Add-RejectPushHook -BarePath $bare -All
        $caught = $null
        try { $null = Publish-RulebookChange -Plan $plan -Repository 'Contoso/rulebook' -RemoteUrl $bare -Token 'ghs_x' -BaseBranch 'main' -BranchPrefix 'change-rule/LC0015' -DirectCommit -WorkPath (Get-TestFolder) -Now $now } catch { $caught = $_ }
        $caught | Should-NotBeNull
        $caught.Exception.Data['Stage'] | Should-Be 'push'
        $caught.Exception.Data['FallbackReason'] | Should-BeLikeString '*every branch is protected*'
    }

    It 'refuses a base branch that moved since the plan' {
        $bare = New-Origin
        $plan.HeadSha = 'f' * 40
        $thrown = $null
        try { $null = Publish-RulebookChange -Plan $plan -Repository 'Contoso/rulebook' -RemoteUrl $bare -Token 'ghs_x' -BaseBranch 'main' -BranchPrefix 'change-rule/LC0015' -WorkPath (Get-TestFolder) -Now $now } catch { $thrown = $_.Exception }
        $thrown.Data['Stage'] | Should-Be 'push'
        $thrown.Data['Reason'] | Should-Be 'base-moved'
        $thrown.Message | Should-BeLikeString 'The base branch moved since the change was planned (main ffffff* is now *); nothing was pushed. Run the workflow again.'
    }

    It 'names the pushed branch when the pull request cannot be opened' {
        $bare = New-Origin
        Mock Invoke-GitHubApi -ModuleName Rulebook.GitHub -ParameterFilter { $Method -eq 'POST' -and $Path -eq 'repos/Contoso/rulebook/pulls' } {
            [pscustomobject]@{ StatusCode = 422; Body = @{ message = 'Validation Failed' }; Text = ''; Headers = $null; RateLimitRemaining = $null }
        }
        $thrown = $null
        try { $null = Publish-RulebookChange -Plan $plan -Repository 'Contoso/rulebook' -RemoteUrl $bare -Token 'ghs_x' -BaseBranch 'main' -BranchPrefix 'change-rule/LC0015' -WorkPath (Get-TestFolder) -Now $now } catch { $thrown = $_.Exception }
        $thrown.Data['Stage'] | Should-Be 'pull-request'
        $thrown.Data['Branch'] | Should-Be 'change-rule/LC0015/261008091530'
        $thrown.Message | Should-BeLikeString 'Branch change-rule/LC0015/261008091530 was pushed.*'
    }

    It 'commits and opens the pull request with -Title, the body ending with -BodySuffix' {
        $bare = New-Origin
        $title = 'Change LC0015 to None (levels: strict, stages: ci) (#12)'
        $result = Publish-RulebookChange -Plan $plan -Repository 'Contoso/rulebook' -RemoteUrl $bare -Token 'ghs_x' -BaseBranch 'main' -BranchPrefix 'rulebook-change/12' -Title $title -BodySuffix 'Closes #12' -WorkPath (Get-TestFolder) -Now $now
        $result.Branch | Should-Be 'rulebook-change/12/261008091530'
        $result.Title | Should-Be $title
        # The commit message is the title alone: a closing keyword in a direct commit would close the issue twice.
        ((& git -C $bare log -1 --format=%B $result.Branch) -join "`n").Trim() | Should-Be $title
        $result.Body | Should-MatchString '\AJustification: Legacy tables\n'
        $result.Body | Should-MatchString '\|\n\nCloses #12\n\z'
        Should-Invoke Invoke-GitHubApi -ModuleName Rulebook.GitHub -Times 1 -Exactly -ParameterFilter { $Method -eq 'POST' -and $Path -eq 'repos/Contoso/rulebook/pulls' -and $Body.title -eq $title -and $Body.body -eq $result.Body }
    }

    It 'commits a direct commit with -Title and without the suffix' {
        $bare = New-Origin
        $title = 'Change LC0015 to None (levels: strict, stages: ci) (#12)'
        $result = Publish-RulebookChange -Plan $plan -Repository 'Contoso/rulebook' -RemoteUrl $bare -Token 'ghs_x' -BaseBranch 'main' -BranchPrefix 'rulebook-change/12' -Title $title -BodySuffix 'Closes #12' -DirectCommit -WorkPath (Get-TestFolder) -Now $now
        $result.Result | Should-Be 'direct-commit'
        $result.Body | Should-BeNull
        ((& git -C $bare log -1 --format=%B main) -join "`n").Trim() | Should-Be $title
    }

    It 'refuses an invalid or a no-op plan' {
        $invalid = Invoke-Change -Root (Copy-Minimal) -RuleId 'LC9999' -Action 'None'
        { Publish-RulebookChange -Plan $invalid -Repository 'Contoso/rulebook' -BaseBranch 'main' -BranchPrefix 'change-rule/LC9999' } | Should-Throw -ExceptionMessage 'The change plan does not validate; nothing is pushed.'
        $noop = Invoke-Change -Root (Copy-Minimal) -RuleId 'AA0072' -Action 'Info' -Justification 'House style'
        { Publish-RulebookChange -Plan $noop -Repository 'Contoso/rulebook' -BaseBranch 'main' -BranchPrefix 'change-rule/AA0072' } | Should-Throw -ExceptionMessage 'The change is a no-op; nothing is pushed.'
    }
}

Describe 'Get-RulebookChangeTitle' {
    It 'titles <Case>' -ForEach @(
        @{ Case = 'a set'; Items = @([pscustomobject]@{ Op = 'set'; Id = 'LC0015'; Action = 'None'; Levels = @('strict'); Stages = @('ci') }); Expected = 'Change LC0015 to None (levels: strict, stages: ci)' }
        @{ Case = 'a remove'; Items = @([pscustomobject]@{ Op = 'remove'; Id = 'LC0015'; Action = $null; Levels = @('strict', 'complete'); Stages = @('ci') }); Expected = 'Remove override for LC0015 (levels: strict, complete, stages: ci)' }
        @{ Case = 'every level and stage'; Items = @([pscustomobject]@{ Op = 'set'; Id = 'AA0072'; Action = 'Info'; Levels = @('*'); Stages = @('*') }); Expected = 'Change AA0072 to Info (levels: *, stages: *)' }
        @{ Case = 'several items'; Items = @([pscustomobject]@{ Op = 'set'; Id = 'A' }, [pscustomobject]@{ Op = 'set'; Id = 'B' }); Expected = 'Rulebook change: 2 changes' }
    ) {
        Get-RulebookChangeTitle -Plan ([pscustomobject]@{ Items = $Items }) | Should-Be $Expected
    }
}

Describe 'Test-RulebookChangeSet: version and release' {
    BeforeAll {
        $script:inputs = Read-RulebookInputs -RepositoryRoot $minimal
        function Get-ChangeSetValue {
            param([object[]]$Changes, $Version = 1, [switch]$NoVersion)
            $set = [ordered]@{}
            if (-not $NoVersion) { $set['version'] = $Version }
            $set['changes'] = $Changes
            return $set
        }
    }

    It 'accepts version <Name>' -ForEach @(
        @{ Name = '1 (int)'; Version = 1 }
        @{ Name = '1 (double, as JSON reads it)'; Version = [double]1 }
        @{ Name = '1 (long)'; Version = [long]1 }
    ) {
        $set = Get-ChangeSetValue -Version $Version -Changes @([ordered]@{ op = 'set'; id = 'LC0015'; action = 'None'; levels = @('strict'); stages = @('ci') })
        @(Test-RulebookChangeSet -ChangeSet $set -Inputs $inputs) | Should-BeCollection @()
    }

    It 'accepts a set without a version (an in-memory set)' {
        $set = Get-ChangeSetValue -NoVersion -Changes @([ordered]@{ op = 'set'; id = 'LC0015'; action = 'None'; levels = @('strict'); stages = @('ci') })
        @(Test-RulebookChangeSet -ChangeSet $set -Inputs $inputs) | Should-BeCollection @()
    }

    It 'refuses version <Name> with one finding' -ForEach @(
        @{ Name = '2'; Version = 2; Text = '2' }
        @{ Name = '"1" (a string)'; Version = '1'; Text = '1' }
        @{ Name = '1.5'; Version = 1.5; Text = '1.5' }
        @{ Name = 'true'; Version = $true; Text = 'True' }
        @{ Name = 'null'; Version = $null; Text = '' }
    ) {
        # An invalid change list too: the version stops the check first.
        $set = Get-ChangeSetValue -Version $Version -Changes @()
        $findings = @(Test-RulebookChangeSet -ChangeSet $set -Inputs $inputs)
        $findings.Count | Should-Be 1
        $findings[0].Message | Should-Be "version '$Text' is not supported; this engine applies change sets of version 1"
    }

    It 'accepts a release with stages only, and releases of one id for different stages' {
        $set = Get-ChangeSetValue -Changes @([ordered]@{ op = 'release'; id = 'LC0099'; stages = @('ci') }, [ordered]@{ op = 'release'; id = 'LC0099'; stages = @('default', 'vnext') }, [ordered]@{ op = 'release'; id = 'AA0001'; stages = @('*') })
        @(Test-RulebookChangeSet -ChangeSet $set -Inputs $inputs) | Should-BeCollection @()
    }

    It 'reports a remove with <Key>' -ForEach @(
        @{ Key = 'action'; Value = 'None' }
        @{ Key = 'justification'; Value = 'Why' }
    ) {
        $change = [ordered]@{ op = 'remove'; id = 'LC0029'; levels = @('recommended'); stages = @('ci') }
        $change[$Key] = $Value
        $findings = @(Test-RulebookChangeSet -ChangeSet (Get-ChangeSetValue -Changes @($change)) -Inputs $inputs)
        $findings.Count | Should-Be 1
        $findings[0].Message | Should-Be "change 1: op 'remove' takes no $Key; it deletes the override entry with these levels and stages"
    }

    It 'reports a release <Name>' -ForEach @(
        @{ Name = 'with levels'; Changes = @([ordered]@{ op = 'release'; id = 'LC0099'; levels = @('*'); stages = @('ci') }); Message = "change 1: op 'release' takes no levels; it releases the id from the quarantine of the listed stages" }
        @{ Name = 'with an action'; Changes = @([ordered]@{ op = 'release'; id = 'LC0099'; action = 'None'; stages = @('ci') }); Message = "change 1: op 'release' takes no action; it releases the id from the quarantine of the listed stages" }
        @{ Name = 'without stages'; Changes = @([ordered]@{ op = 'release'; id = 'LC0099' }); Message = 'change 1 has no stages; use a slug from the settings or ["*"]' }
        @{ Name = 'with an unknown stage'; Changes = @([ordered]@{ op = 'release'; id = 'LC0099'; stages = @('house') }); Message = "change 1 names unknown stage 'house'; use a slug from the settings or [`"*`"]" }
        @{ Name = 'with an id outside the catalog'; Changes = @([ordered]@{ op = 'release'; id = 'LC9999'; stages = @('ci') }); Message = 'LC9999 is not in catalog/diagnostics.json' }
        @{ Name = 'with a justification'; Changes = @([ordered]@{ op = 'release'; id = 'LC0099'; stages = @('ci'); justification = 'x' }); Message = "change 1: op 'release' takes no justification; it releases the id from the quarantine of the listed stages" }
        @{ Name = 'twice for one stage (ci and *)'; Changes = @([ordered]@{ op = 'release'; id = 'LC0099'; stages = @('ci') }, [ordered]@{ op = 'release'; id = 'LC0099'; stages = @('*') }); Message = 'change 2: release LC0099 appears twice for stage ci' }
        @{ Name = 'twice for two stages'; Changes = @([ordered]@{ op = 'release'; id = 'LC0099'; stages = @('*') }, [ordered]@{ op = 'release'; id = 'LC0099'; stages = @('ci', 'vnext') }); Message = 'change 2: release LC0099 appears twice for stages ci, vnext' }
        @{ Name = 'twice (same stage set, any order)'; Changes = @([ordered]@{ op = 'release'; id = 'LC0099'; stages = @('ci', 'default') }, [ordered]@{ op = 'release'; id = 'LC0099'; stages = @('default', 'ci') }); Message = 'change 2 repeats an earlier change (same op, id, levels and stages)' }
    ) {
        $findings = @(Test-RulebookChangeSet -ChangeSet (Get-ChangeSetValue -Changes $Changes) -Inputs $inputs)
        $findings.Count | Should-Be 1
        $findings[0].Message | Should-Be $Message
    }
}

Describe 'Remove-RulebookQuarantine' {
    BeforeAll {
        Import-Module (Join-Path $repoRoot 'modules' 'Rulebook.Quarantine.psd1') -Force
        function Get-QuarantineFileMap {
            param([string]$Root = $minimal)
            $files = [ordered]@{}
            foreach ($slug in 'default', 'ci', 'vnext') { $files[$slug] = Read-QuarantineFile -Path (Join-Path $Root "quarantine.$slug.json") }
            return $files
        }
    }

    It 'releases the id from one stage' {
        $files = Get-QuarantineFileMap
        $result = Remove-RulebookQuarantine -Files $files -Id 'LC0099' -Stages 'ci'
        @($result.Removed).Count | Should-Be 1
        $result.Removed[0].Stage | Should-Be 'ci'
        $result.Removed[0].Id | Should-Be 'LC0099'
        $result.Removed[0].Justification | Should-BeLikeString 'New in alcops.analyzers 1.4.0-beta.1*'
        @($result.Unlisted) | Should-BeCollection @()
        $files['ci'].Rules.Contains('LC0099') | Should-BeFalse
        $files['default'].Rules.Contains('LC0099') | Should-BeTrue
    }

    It "releases '*' in settings order and lists the stages without the id" {
        $files = Get-QuarantineFileMap
        $result = Remove-RulebookQuarantine -Files $files -Id 'LC0099' -Stages '*'
        @($result.Removed | ForEach-Object Stage) | Should-BeCollection @('default', 'ci')
        $result.Unlisted | Should-BeCollection @('vnext')
    }

    It 'lists every stage as unlisted for an id no file has' {
        $result = Remove-RulebookQuarantine -Files (Get-QuarantineFileMap) -Id 'AA0001' -Stages '*'
        @($result.Removed) | Should-BeCollection @()
        $result.Unlisted | Should-BeCollection @('default', 'ci', 'vnext')
    }

    It 'throws <Name> before anything changes' -ForEach @(
        @{ Name = 'on an empty selector'; Stages = @(); Message = 'stages is empty*' }
        @{ Name = "on '*' mixed with slugs"; Stages = @('*', 'ci'); Message = "stages mixes '*'*" }
        @{ Name = 'on an unknown slug'; Stages = @('default', 'house'); Message = "stages names unknown stage 'house'; use a slug from the settings or *" }
    ) {
        $files = Get-QuarantineFileMap
        $thrown = $null
        try { $null = Remove-RulebookQuarantine -Files $files -Id 'LC0099' -Stages $Stages } catch { $thrown = $_.Exception }
        $thrown.Message | Should-BeLikeString $Message
        $thrown.Data['Stage'] | Should-Be 'validation'
        $files['default'].Rules.Contains('LC0099') | Should-BeTrue
    }

    It 'leaves the other entries byte for byte when the file is written' {
        $root = Get-TestFolder
        $path = Join-Path $root 'quarantine.ci.json'
        $other = '    { "id": "AA0001", "justification": "New in alcops.analyzers 1.4.0 (stable), quarantined 2026-10-02. Review and adopt." }'
        $lines = @(
            '{'
            '  "$schema": "https://raw.githubusercontent.com/ALCops/rulebook-engine/main/schemas/rulebook-quarantine.schema.json",'
            '  "rules": ['
            '    { "id": "LC0099", "justification": "Quarantined by hand" },'
            $other
            '  ]'
            '}'
        )
        Write-FixtureText -Path $path -Text (($lines -join "`n") + "`n")
        $files = [ordered]@{ ci = Read-QuarantineFile -Path $path }
        $null = Remove-RulebookQuarantine -Files $files -Id 'LC0099' -Stages 'ci'
        (Write-QuarantineFile -Path $path -File $files['ci']).Change | Should-Be 'modified'
        $expected = @($lines[0], $lines[1], $lines[2], $other, $lines[5], $lines[6]) -join "`n"
        [System.IO.File]::ReadAllText($path) | Should-Be ($expected + "`n")
    }
}

Describe 'Invoke-RulebookChangeSet: release' {
    BeforeAll {
        function Invoke-Release {
            param([string]$Root, [object[]]$Changes, [string]$Note)
            $set = [ordered]@{ version = 1 }
            if ($Note) { $set['note'] = $Note }
            $set['changes'] = $Changes
            return Invoke-RulebookChangeSet -RepositoryRoot $Root -ChangeSet $set -WorkPath (Get-TestFolder)
        }
        $script:ciEndpoints = @('rulesets/complete.ci.ruleset.json', 'rulesets/essential.ci.ruleset.json', 'rulesets/recommended.ci.ruleset.json', 'rulesets/strict.ci.ruleset.json')
    }

    It 'releases LC0099 from ci: four endpoints and quarantine.ci.json, the repository untouched' {
        $root = Copy-Minimal
        $before = Get-TreeHash -Root $root
        $plan = Invoke-Release -Root $root -Changes @([ordered]@{ op = 'release'; id = 'LC0099'; stages = @('ci') })
        $plan.Valid | Should-BeTrue
        $plan.NoOp | Should-BeFalse
        $item = $plan.Items[0]
        $item.Levels | Should-BeCollection @('*')
        $item.Action | Should-BeNull
        $item.Entry.Change | Should-Be 'released'
        $item.Released | Should-BeCollection @('ci')
        @($item.Unlisted) | Should-BeCollection @()
        $item.ChangedEndpoints | Should-BeCollection @('essential.ci', 'recommended.ci', 'strict.ci', 'complete.ci')
        @($plan.Changes | ForEach-Object File) | Should-BeCollection (@('quarantine.ci.json') + $ciEndpoints)
        @($plan.QuarantineChanges | ForEach-Object { '{0} {1}' -f $_.File, $_.Change }) | Should-BeCollection @('quarantine.ci.json modified')
        $plan.OverridesChange | Should-BeNull
        $row = $item.Rows[0]
        $row.Endpoint | Should-Be 'essential.ci'
        $row.BeforeSource | Should-Be 'quarantine'
        $row.After | Should-Be 'Warning'
        $row.AfterSource | Should-Be 'default'
        $row.Note | Should-Be 'now unlisted in essential.ci: Warning equals the analyzer default'
        (ConvertTo-ChangeTable -Rows $item.Rows) | Should-MatchString '(?m)^\| essential\.ci \| None \(quarantine, "New in alcops\.analyzers [^|]*"\) \| Warning \(default\) \| now unlisted in essential\.ci: Warning equals the analyzer default \|$'
        [System.IO.File]::ReadAllText((Join-Path $plan.CandidatePath 'quarantine.ci.json')) | Should-Be "{`n  `"`$schema`": `"https://raw.githubusercontent.com/ALCops/rulebook-engine/main/schemas/rulebook-quarantine.schema.json`",`n  `"rules`": []`n}`n"
        $plan.Title | Should-Be 'Release LC0099 from quarantine (stages: ci)'
        Get-TreeHash -Root $root | Should-BeCollection $before
    }

    It "releases '*': eight endpoints, the vnext rows not quarantined" {
        $plan = Invoke-Release -Root (Copy-Minimal) -Changes @([ordered]@{ op = 'release'; id = 'LC0099'; stages = @('*') })
        $item = $plan.Items[0]
        $item.Released | Should-BeCollection @('default', 'ci')
        $item.Unlisted | Should-BeCollection @('vnext')
        $item.Rows.Count | Should-Be 12
        $item.ChangedEndpoints.Count | Should-Be 8
        @($item.Rows | Where-Object { $_.Endpoint -like '*.vnext' } | ForEach-Object Note | Select-Object -Unique) | Should-BeCollection @('not quarantined in vnext')
        @($plan.Changes | ForEach-Object File | Where-Object { $_ -like 'quarantine.*' }) | Should-BeCollection @('quarantine.ci.json', 'quarantine.default.json')
        @($plan.Changes | Where-Object { $_.File -like 'rulesets/*' }).Count | Should-Be 8
        $item.Notes[0] | Should-Be 'LC0099 is not quarantined in vnext; nothing to release there.'
        $body = ConvertTo-ChangePullRequestBody -Plan $plan
        $body | Should-MatchString '\AReleases LC0099 from the quarantine of stages default, ci \(removes the entry from quarantine\.default\.json, quarantine\.ci\.json\)\.\n'
        $body | Should-MatchString '(?m)^- 4 of 12 matching endpoints are unchanged\.$'
    }

    It 'is a no-op for a stage whose file does not list the id: nothing written' {
        $plan = Invoke-Release -Root (Copy-Minimal) -Changes @([ordered]@{ op = 'release'; id = 'LC0099'; stages = @('vnext') })
        $plan.Valid | Should-BeTrue
        $plan.NoOp | Should-BeTrue
        $plan.Items[0].Entry.Change | Should-Be 'unchanged'
        @($plan.Changes) | Should-BeCollection @()
        @($plan.QuarantineChanges) | Should-BeCollection @()
        @($plan.Items[0].Notes) | Should-BeCollection @()
        ConvertTo-ChangeItemList -Plan $plan | Should-Be "- Leaves LC0099 as it is for stages vnext (no quarantine file of these stages lists it; nothing is written).`n"
    }

    It 'applies a set next to a release no-op: not a no-op, the release item is' {
        $plan = Invoke-Release -Root (Copy-Minimal) -Changes @(
            [ordered]@{ op = 'set'; id = 'LC0015'; action = 'None'; levels = @('strict'); stages = @('ci') }
            [ordered]@{ op = 'release'; id = 'LC0099'; stages = @('vnext') }
        )
        $plan.NoOp | Should-BeFalse
        $plan.Items[0].NoOp | Should-BeFalse
        $plan.Items[1].NoOp | Should-BeTrue
        $plan.Title | Should-Be 'Rulebook change: 2 changes'
        @($plan.Changes | ForEach-Object File) | Should-BeCollection @('overrides.json', 'rulesets/strict.ci.ruleset.json')
        ConvertTo-ChangeItemList -Plan $plan | Should-Be ("- Sets LC0015 to None for levels strict, stages ci (adds an entry).`n" + "- Leaves LC0099 as it is for stages vnext (no quarantine file of these stages lists it; nothing is written).`n")
    }

    It 'writes a release that an override masks: the file changes, no endpoint does' {
        $root = Copy-Minimal
        $path = Join-Path $root 'overrides.json'
        $text = [System.IO.File]::ReadAllText($path)
        Write-FixtureText -Path $path -Text $text.Replace('"justification": "Backlog DEV-1234" }', '"justification": "Backlog DEV-1234" },' + "`n" + '    { "id": "LC0099", "action": "None", "levels": ["*"], "stages": ["ci"], "justification": "Kept off in CI" }')
        $null = Update-RulebookEndpoints -RepositoryRoot $root
        $plan = Invoke-Release -Root $root -Changes @([ordered]@{ op = 'release'; id = 'LC0099'; stages = @('ci') })
        $plan.Valid | Should-BeTrue
        $plan.NoOp | Should-BeFalse
        $plan.Items[0].NoOp | Should-BeFalse
        @($plan.Items[0].ChangedEndpoints) | Should-BeCollection @()
        @($plan.Items[0].Rows | ForEach-Object Note | Select-Object -Unique) | Should-BeCollection @('unchanged')
        @($plan.Changes | ForEach-Object File) | Should-BeCollection @('quarantine.ci.json')
    }

    It 'keeps a date-like justification of another entry as it is written' {
        $root = Copy-Minimal
        $schema = '  "$schema": "https://raw.githubusercontent.com/ALCops/rulebook-engine/main/schemas/rulebook-quarantine.schema.json",'
        $dated = '    { "id": "AA0001", "justification": "2026-10-18T10:00:00Z" }'
        Write-FixtureText -Path (Join-Path $root 'quarantine.ci.json') -Text ((@('{', $schema, '  "rules": [', '    { "id": "LC0099" },', $dated, '  ]', '}') -join "`n") + "`n")
        $null = Update-RulebookEndpoints -RepositoryRoot $root
        $plan = Invoke-Release -Root $root -Changes @([ordered]@{ op = 'release'; id = 'LC0099'; stages = @('ci') })
        $plan.Valid | Should-BeTrue
        [System.IO.File]::ReadAllText((Join-Path $plan.CandidatePath 'quarantine.ci.json')) | Should-Be ((@('{', $schema, '  "rules": [', $dated, '  ]', '}') -join "`n") + "`n")
    }

    It 'normalises a hand-edited quarantine file to the template layout' {
        $root = Copy-Minimal
        $lines = @(
            '{'
            '    "rules": ['
            '        {'
            '            "id": "AA0001",'
            '            "justification": "Watch it"'
            '        },'
            '        { "justification": "x", "id": "LC0099" }'
            '    ]'
            '}'
        )
        Write-FixtureText -Path (Join-Path $root 'quarantine.ci.json') -Text ($lines -join "`r`n")
        $null = Update-RulebookEndpoints -RepositoryRoot $root
        $plan = Invoke-Release -Root $root -Changes @([ordered]@{ op = 'release'; id = 'LC0099'; stages = @('ci') })
        $plan.Valid | Should-BeTrue
        [System.IO.File]::ReadAllText((Join-Path $plan.CandidatePath 'quarantine.ci.json')) | Should-Be "{`n  `"`$schema`": `"https://raw.githubusercontent.com/ALCops/rulebook-engine/main/schemas/rulebook-quarantine.schema.json`",`n  `"rules`": [`n    { `"id`": `"AA0001`", `"justification`": `"Watch it`" }`n  ]`n}`n"
    }

    It 'keeps a hand-formatted overrides.json when only a dead entry touched it next to a release' {
        $root = Copy-Minimal
        $path = Join-Path $root 'overrides.json'
        $custom = [System.IO.File]::ReadAllText($path).Replace('  "rules": [', '  "rules":    [')
        Write-FixtureText -Path $path -Text $custom
        # AA0001 is Warning on strict.ci already (level:recommended): a dead entry.
        $plan = Invoke-Release -Root $root -Changes @(
            [ordered]@{ op = 'set'; id = 'AA0001'; action = 'Warning'; levels = @('strict'); stages = @('ci') }
            [ordered]@{ op = 'release'; id = 'LC0099'; stages = @('ci') }
        )
        $plan.NoOp | Should-BeFalse
        $plan.Items[0].NoOp | Should-BeTrue
        $plan.OverridesChange | Should-BeNull
        @($plan.Changes | ForEach-Object File) | Should-BeCollection (@('quarantine.ci.json') + $ciEndpoints)
        [System.IO.File]::ReadAllText((Join-Path $plan.CandidatePath 'overrides.json')) | Should-Be $custom
    }

    It 'writes no overrides.json the repository does not have when only a dead entry touched it' {
        $root = Copy-Minimal
        Remove-Item -LiteralPath (Join-Path $root 'overrides.json')
        $null = Update-RulebookEndpoints -RepositoryRoot $root
        $plan = Invoke-Release -Root $root -Changes @(
            [ordered]@{ op = 'set'; id = 'AA0001'; action = 'Warning'; levels = @('strict'); stages = @('ci') }
            [ordered]@{ op = 'release'; id = 'LC0099'; stages = @('ci') }
        )
        $plan.Valid | Should-BeTrue
        $plan.OverridesChange | Should-BeNull
        Test-Path -LiteralPath (Join-Path $plan.CandidatePath 'overrides.json') | Should-BeFalse
        @($plan.Changes | ForEach-Object File) | Should-BeCollection (@('quarantine.ci.json') + $ciEndpoints)
    }

    It 'stops on a quarantine file that cannot be read, before anything is copied' {
        $root = Copy-Minimal
        Write-FixtureText -Path (Join-Path $root 'quarantine.ci.json') -Text '{ "rules": [ '
        $work = Get-TestFolder
        $set = [ordered]@{ version = 1; changes = @([ordered]@{ op = 'release'; id = 'LC0099'; stages = @('default') }) }
        $plan = Invoke-RulebookChangeSet -RepositoryRoot $root -ChangeSet $set -WorkPath $work
        $plan.Failure | Should-Be 'validation'
        $plan.Findings[0].Message | Should-BeLikeString 'The rulebook cannot be read: *quarantine.ci.json*'
        Test-Path -LiteralPath (Join-Path $work 'candidate') | Should-BeFalse
    }
}

Describe 'Rendering: notes, releases and the issue path' {
    It 'puts the note first and the one-item justification after it' {
        $set = [ordered]@{ version = 1; note = "Agreed in the meeting`n## not a heading"; changes = @([ordered]@{ op = 'set'; id = 'LC0015'; action = 'None'; levels = @('strict'); stages = @('ci'); justification = 'Legacy tables' }) }
        $plan = Invoke-RulebookChangeSet -RepositoryRoot (Copy-Minimal) -ChangeSet $set -WorkPath (Get-TestFolder)
        ConvertTo-ChangePullRequestBody -Plan $plan | Should-MatchString '\AAgreed in the meeting ## not a heading\n\nJustification: Legacy tables\n\nSets LC0015 to None'
    }

    It 'opens a release-only body with the note, or with the sentence' {
        $plan = Invoke-RulebookChangeSet -RepositoryRoot (Copy-Minimal) -ChangeSet ([ordered]@{ version = 1; changes = @([ordered]@{ op = 'release'; id = 'LC0099'; stages = @('ci') }) }) -WorkPath (Get-TestFolder)
        ConvertTo-ChangePullRequestBody -Plan $plan | Should-MatchString '\AReleases LC0099 from the quarantine of stages ci \(removes the entry from quarantine\.ci\.json\)\.\n'
        $noted = Invoke-RulebookChangeSet -RepositoryRoot (Copy-Minimal) -ChangeSet ([ordered]@{ version = 1; note = 'Adopted'; changes = @([ordered]@{ op = 'release'; id = 'LC0099'; stages = @('ci') }) }) -WorkPath (Get-TestFolder)
        ConvertTo-ChangePullRequestBody -Plan $noted | Should-MatchString '\AAdopted\n\nReleases LC0099'
    }

    It 'opens a set of several items without a note with the first item, no justification sentence' {
        $set = [ordered]@{ version = 1; changes = @(
                [ordered]@{ op = 'set'; id = 'LC0015'; action = 'None'; levels = @('strict'); stages = @('ci'); justification = 'One' }
                [ordered]@{ op = 'release'; id = 'LC0099'; stages = @('ci') }
            ) }
        $plan = Invoke-RulebookChangeSet -RepositoryRoot (Copy-Minimal) -ChangeSet $set -WorkPath (Get-TestFolder)
        $body = ConvertTo-ChangePullRequestBody -Plan $plan
        $body | Should-MatchString '\ASets LC0015'
        $body | Should-NotMatchString 'No justification given'
        $set['note'] = 'Agreed'
        $noted = Invoke-RulebookChangeSet -RepositoryRoot (Copy-Minimal) -ChangeSet $set -WorkPath (Get-TestFolder)
        ConvertTo-ChangePullRequestBody -Plan $noted | Should-MatchString '\AAgreed\n\nSets LC0015'
    }

    It 'adds the prefix and the suffix around the generated body, and only the generated part is shortened' {
        $wide = Invoke-Change -Root (Copy-Minimal) -RuleId 'LC0015' -Action 'Error'
        $body = ConvertTo-ChangePullRequestBody -Plan $wide -BodyPrefix "From issue #12`n" -BodySuffix 'Closes #12'
        $body | Should-MatchString '\AFrom issue #12\n\nNo justification given\.\n'
        $body | Should-MatchString '\| complete\.vnext \|[^\n]*\|\n\nCloses #12\n\z'
        $short = ConvertTo-ChangePullRequestBody -Plan $wide -Limit 500 -BodyPrefix 'From issue #12' -BodySuffix 'Closes #12'
        $short.Length | Should-BeLessThanOrEqual 500
        $short | Should-MatchString '\AFrom issue #12\n\n'
        $short | Should-MatchString '_1 of 1 change tables were left out[^\n]*_\n\nCloses #12\n\z'
        ConvertTo-ChangePullRequestBody -Plan $wide | Should-Be (ConvertTo-ChangePullRequestBody -Plan $wide -BodyPrefix '' -BodySuffix $null)
    }

    It 'writes the summary under -Heading' {
        $plan = Invoke-Change -Root (Copy-Minimal) -RuleId 'LC0015' -Action 'None' -Levels 'strict' -Stages 'ci'
        ConvertTo-ChangeSummary -Plan $plan -Message 'm' -Heading 'Rulebook change (#12)' | Should-MatchString '\A## Rulebook change \(#12\)\n\nm\n'
        ConvertTo-ChangeSummary -Plan $plan -Message 'm' | Should-MatchString '\A## Rule change\n'
    }

    It 'lists one line per item, and nothing for a plan without items' {
        $plan = Invoke-Change -Root (Copy-Minimal) -RuleId 'AA0072' -Action 'Info'
        ConvertTo-ChangeItemList -Plan $plan | Should-Be "- Leaves AA0072 at Info for levels *, stages * (the entry is unchanged).`n"
        ConvertTo-ChangeItemList -Plan ([pscustomobject]@{ Items = @() }) | Should-Be ''
    }
}

Describe 'ConvertFrom-RulebookIssueBody' {
    BeforeAll {
        $script:issues = Join-Path $PSScriptRoot 'fixtures' 'issues'
        function Get-IssueText {
            param([string]$Name)
            return [System.IO.File]::ReadAllText((Join-Path $issues $Name), $utf8)
        }
    }

    It 'reads the change set and the note of the submitted form (issues/rulebook-change-opened.md)' {
        $parsed = ConvertFrom-RulebookIssueBody -Body (Get-IssueText 'rulebook-change-opened.md')
        @($parsed.Errors) | Should-BeCollection @()
        $parsed.ChangesText | Should-MatchString '\A\{.*\}\z'
        $parsed.Note | Should-NotBe ''
        $read = Read-RulebookChangeSetText -Text $parsed.ChangesText
        @($read.Errors) | Should-BeCollection @()
        $read.ChangeSet['version'] | Should-Be 1
        @($read.ChangeSet['changes']).Count | Should-BeGreaterThan 0
    }

    It 'reads a CRLF body as the LF body' {
        $text = Get-IssueText 'rulebook-change-opened.md'
        $lf = ConvertFrom-RulebookIssueBody -Body $text
        $crlf = ConvertFrom-RulebookIssueBody -Body $text.Replace("`n", "`r`n")
        $crlf.ChangesText | Should-Be $lf.ChangesText
        $crlf.Note | Should-Be $lf.Note
        @($crlf.Errors) | Should-BeCollection @()
    }

    It 'reads _No response_ as an empty note (issues/note-no-response.md)' {
        $parsed = ConvertFrom-RulebookIssueBody -Body (Get-IssueText 'note-no-response.md')
        $parsed.Note | Should-Be ''
        $parsed.ChangesText | Should-Be '{"version":1,"changes":[{"op":"set","id":"AA0072","action":"Info","levels":["*"],"stages":["*"]}]}'
    }

    It 'takes only the first fenced block of Changes, ignores prose and deeper headings (issues/prose-and-two-fences.md)' {
        $parsed = ConvertFrom-RulebookIssueBody -Body (Get-IssueText 'prose-and-two-fences.md')
        @($parsed.Errors) | Should-BeCollection @()
        $parsed.ChangesText | Should-Be "{`n  `"version`": 1,`n  `"note`": `"From the JSON`",`n  `"changes`": [`n    { `"op`": `"release`", `"id`": `"LC0099`", `"stages`": [`"*`"] }`n  ]`n}"
        $parsed.Note | Should-MatchString '\ARelease it everywhere\.\n'
        $parsed.Note | Should-MatchString '(?m)^#### Not a field$'
        $parsed.Note | Should-MatchString '\{"version":3\}\n```\z'
    }

    It 'applies a parsed body to valid-minimal (issues/prose-and-two-fences.md)' {
        $parsed = ConvertFrom-RulebookIssueBody -Body (Get-IssueText 'prose-and-two-fences.md')
        $read = Read-RulebookChangeSetText -Text $parsed.ChangesText
        $read.ChangeSet['note'] | Should-Be 'From the JSON'
        $plan = Invoke-RulebookChangeSet -RepositoryRoot (Copy-Minimal) -ChangeSet $read.ChangeSet -WorkPath (Get-TestFolder)
        $plan.Valid | Should-BeTrue
        $plan.Items[0].ChangedEndpoints.Count | Should-Be 8
    }

    It 'reads a section without a fence as the change set, and an absent Note as empty (issues/no-fence.md)' {
        $parsed = ConvertFrom-RulebookIssueBody -Body (Get-IssueText 'no-fence.md')
        $parsed.ChangesText | Should-Be '{"version":1,"changes":[{"op":"remove","id":"LC0029","levels":["recommended"],"stages":["ci"]}]}'
        $parsed.Note | Should-Be ''
        @($parsed.Errors) | Should-BeCollection @()
    }

    It 'takes the first ### Changes section, also when an earlier Note holds one' {
        $body = "### Note`n`nSee below.`n`n### Changes`n`n``````json`n{`"first`":1}`n```````n`n### Changes`n`n``````json`n{`"second`":2}`n```````n"
        $parsed = ConvertFrom-RulebookIssueBody -Body $body
        $parsed.ChangesText | Should-Be '{"first":1}'
        $parsed.Note | Should-Be 'See below.'
    }

    It 'reads a heading line with a long run of blanks in linear time' {
        $body = '### ' + (' ' * 8000) + "x`n`n### Changes`n`n{}`n" + ('### Note' + (' ' * 8000) + "`n`nkept`n")
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $parsed = ConvertFrom-RulebookIssueBody -Body $body
        $watch.Stop()
        $watch.Elapsed.TotalSeconds | Should-BeLessThan 1
        $parsed.ChangesText | Should-Be '{}'
        $parsed.Note | Should-Be 'kept'
    }

    It 'reads an unclosed fence to the end of its section' {
        $parsed = ConvertFrom-RulebookIssueBody -Body "### Changes`n`n``````json`n{`"version`":1}`n`n### Note`n`nKept"
        $parsed.ChangesText | Should-Be '{"version":1}'
        $parsed.Note | Should-Be 'Kept'
    }

    It 'reports a body without a Changes section: <Name>' -ForEach @(
        @{ Name = 'issues/no-changes-section.md'; File = 'no-changes-section.md' }
        @{ Name = 'an empty body'; File = $null; Body = '' }
        @{ Name = 'a null body'; File = $null; Body = $null }
    ) {
        $text = if ($File) { Get-IssueText $File } else { $Body }
        $parsed = ConvertFrom-RulebookIssueBody -Body $text
        $parsed.Errors | Should-BeCollection @('The issue body has no "### Changes" section; submit the Rulebook change form from the dashboard, or add the section with the change set in a json code block.')
        $parsed.ChangesText | Should-Be ''
        $parsed.Note | Should-Be ''
    }

    It 'reports an empty Changes field: <Name>' -ForEach @(
        @{ Name = '_No response_'; Body = "### Changes`n`n_No response_`n`n### Note`n`nx" }
        @{ Name = 'an empty fence'; Body = "### Changes`n`n``````json`n``````" }
        @{ Name = 'nothing'; Body = "### Changes`n`n### Note`n`nx" }
    ) {
        (ConvertFrom-RulebookIssueBody -Body $Body).Errors | Should-BeCollection @('The Changes field is empty.')
    }
}

Describe 'Read-RulebookChangeSetText' {
    It 'reads a valid change set with strings kept as strings' {
        $read = Read-RulebookChangeSetText -Text '{"version":1,"note":"n","changes":[{"op":"set","id":"LC0015","action":"None","levels":["*"],"stages":["ci"],"justification":"2026-10-03T10:00:00"},{"op":"release","id":"LC0099","stages":["*"]}]}'
        @($read.Errors) | Should-BeCollection @()
        $read.ChangeSet -is [System.Collections.IDictionary] | Should-BeTrue
        @($read.ChangeSet.Keys) | Should-BeCollection @('version', 'note', 'changes')
        $read.ChangeSet['changes'][0]['justification'] | Should-BeString '2026-10-03T10:00:00'
        $read.ChangeSet['changes'][1]['stages'] | Should-BeCollection @('*')
    }

    It 'reads every valid schema fixture' {
        foreach ($file in Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'fixtures' 'schemas' 'valid' 'rulebook-changeset') -File) {
            @((Read-RulebookChangeSetText -Text ([System.IO.File]::ReadAllText($file.FullName))).Errors) | Should-BeCollection @() -Because $file.Name
        }
    }

    It 'names the line and position of a JSON error' {
        $read = Read-RulebookChangeSetText -Text "{`n  `"version`": 1,`n  `"changes`": [1,]`n}"
        $read.ChangeSet | Should-BeNull
        $read.Errors.Count | Should-Be 1
        $read.Errors[0] | Should-BeLikeString 'The change set is not valid JSON (line 3, byte position *): *'
        $read.Errors[0] | Should-NotMatchString 'LineNumber'
    }

    It 'prints the quotes of a schema error as quotes, not JSON escapes' {
        $read = Read-RulebookChangeSetText -Text '{"version":1,"changes":[{"op":"rename","id":"LC0015","levels":["*"],"stages":["ci"]}]}'
        $read.Errors.Count | Should-BeGreaterThan 0
        foreach ($line in $read.Errors) { $line.Contains('\u0022') | Should-BeFalse -Because $line }
    }

    It 'reports a schema that cannot be read' {
        $read = Read-RulebookChangeSetText -Text '{"version":1}' -SchemaPath (Join-Path (Get-TestFolder) 'missing.schema.json')
        $read.ChangeSet | Should-BeNull
        $read.Errors.Count | Should-Be 1
        $read.Errors[0] | Should-BeLikeString 'The change set cannot be checked against the schema: *'
    }

    It 'refuses comments and an empty text' {
        (Read-RulebookChangeSetText -Text '{"version":1, /* c */ "changes":[]}').Errors[0] | Should-BeLikeString 'The change set is not valid JSON (line 1, byte position *'
        (Read-RulebookChangeSetText -Text ' ').Errors | Should-BeCollection @('The change set is empty.')
    }

    It 'reports schema errors one line each: <Name>' -ForEach @(
        @{ Name = 'a root array'; Text = '[1,2]' }
        @{ Name = 'version 2 and no changes'; Text = '{"version":2,"changes":[]}' }
        @{ Name = 'version "1"'; Text = '{"version":"1","changes":[{"op":"set","id":"LC0001","action":"None","levels":["*"],"stages":["ci"]}]}' }
        @{ Name = 'a release with levels'; Text = '{"version":1,"changes":[{"op":"release","id":"LC0099","levels":["*"],"stages":["ci"]}]}' }
        @{ Name = 'a lowercase id'; Text = '{"version":1,"changes":[{"op":"set","id":"lc15","action":"None","levels":["*"],"stages":["ci"]}]}' }
    ) {
        $read = Read-RulebookChangeSetText -Text $Text
        $read.ChangeSet | Should-BeNull
        $read.Errors.Count | Should-BeGreaterThan 0
        foreach ($line in $read.Errors) {
            $line | Should-BeLikeString 'The change set does not match the schema: *'
            $line | Should-NotMatchString '[\r\n]'
        }
    }
}
