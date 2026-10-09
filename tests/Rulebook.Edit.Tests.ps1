# Edit suite for WP09 (#11): modules/Rulebook.Edit on copies of tests/fixtures/repos/valid-minimal in TestDrive
# (docs/reference/change-mechanics.md). The GitHub API is mocked at Invoke-GitHubApi; the git side of
# Publish-RulebookChange runs against a bare repository.

BeforeDiscovery {
    $script:gitMissing = $null -eq (Get-Command git -ErrorAction SilentlyContinue)
}

BeforeAll {
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
    $env:GITHUB_API_URL = $script:savedApiUrl
    $env:GITHUB_SERVER_URL = $script:savedServerUrl
    Remove-Module Rulebook.Edit, Rulebook.Update, Rulebook.Template, Rulebook.GitHub, Rulebook.Validate, Rulebook.Generate, Rulebook.Action -ErrorAction SilentlyContinue
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
        $file.Schema | Should-Be 'https://raw.githubusercontent.com/ALCops/rulebook-engine/v1/schemas/rulebook-overrides.schema.json'
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
        ConvertTo-OverridesJson -File $file | Should-Be "{`n  `"`$schema`": `"https://raw.githubusercontent.com/ALCops/rulebook-engine/v1/schemas/rulebook-overrides.schema.json`",`n  `"rules`": [`n    { `"id`": `"LC0015`", `"action`": `"None`", `"levels`": [`"strict`"], `"stages`": [`"ci`"], `"justification`": `"Legacy tables`" }`n  ]`n}`n"
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

    It 'builds a one-item set; Remove becomes op remove without an action' {
        $set = ConvertTo-RulebookChangeSet -RuleId 'LC0015' -Action 'none' -Levels 'strict' -Stages 'ci' -Justification ' Legacy '
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
        $findings[0].Message | Should-Be 'change 0 has no stages; use a slug from the settings or ["*"]'
    }

    It 'accepts a valid set' {
        @(Test-RulebookChangeSet -ChangeSet (ConvertTo-RulebookChangeSet -RuleId 'LC0015' -Action 'None' -Levels 'strict' -Stages 'ci') -Inputs $inputs) | Should-BeCollection @()
    }

    It 'reports <Name>' -ForEach @(
        @{ Name = 'a bad id'; Set = @{ changes = @(@{ op = 'set'; id = 'lc15'; action = 'None'; levels = @('*'); stages = @('*') }) }; Message = "'lc15' is not a diagnostic id*" }
        @{ Name = 'an id outside the catalog'; Set = @{ changes = @(@{ op = 'set'; id = 'LC9999'; action = 'None'; levels = @('*'); stages = @('*') }) }; Message = 'LC9999 is not in catalog/diagnostics.json' }
        @{ Name = 'a bad action'; Set = @{ changes = @(@{ op = 'set'; id = 'LC0015'; action = 'Default'; levels = @('*'); stages = @('*') }) }; Message = "action 'Default': use Error, Warning, Info, Hidden or None" }
        @{ Name = 'an unknown slug (C10 wording)'; Set = @{ changes = @(@{ op = 'set'; id = 'LC0015'; action = 'None'; levels = @('house'); stages = @('*') }) }; Message = "change 0 names unknown level 'house'; use a slug from the settings or *" }
        @{ Name = 'the reserved release op'; Set = @{ changes = @(@{ op = 'release'; id = 'LC0015'; levels = @('*'); stages = @('*') }) }; Message = "*op 'release' is reserved; it arrives with WP15" }
        @{ Name = 'an empty change list'; Set = @{ changes = @() }; Message = 'The change set has no changes.' }
        @{ Name = 'a duplicate'; Set = @{ changes = @(@{ op = 'set'; id = 'LC0015'; action = 'None'; levels = @('strict', 'complete'); stages = @('ci') }, @{ op = 'set'; id = 'LC0015'; action = 'Info'; levels = @('complete', 'strict'); stages = @('ci') }) }; Message = 'change 1 repeats an earlier change*' }
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
        $result = Publish-RulebookChange -Plan $plan -Repository 'Contoso/rulebook' -RemoteUrl $bare -Token 'ghs_x' -BaseBranch 'main' -BranchPrefix 'change-rule/LC0015' -DirectCommit -WorkPath (Get-TestFolder) -Now $now 3>$null
        $result.Result | Should-Be 'pull-request'
        $result.Fallback | Should-BeTrue
        $result.Branch | Should-Be 'change-rule/LC0015/261008091530'
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

    It 'refuses an invalid or a no-op plan' {
        $invalid = Invoke-Change -Root (Copy-Minimal) -RuleId 'LC9999' -Action 'None'
        { Publish-RulebookChange -Plan $invalid -Repository 'Contoso/rulebook' -BaseBranch 'main' -BranchPrefix 'change-rule/LC9999' } | Should-Throw -ExceptionMessage 'The change plan does not validate; nothing is pushed.'
        $noop = Invoke-Change -Root (Copy-Minimal) -RuleId 'AA0072' -Action 'Info' -Justification 'House style'
        { Publish-RulebookChange -Plan $noop -Repository 'Contoso/rulebook' -BaseBranch 'main' -BranchPrefix 'change-rule/AA0072' } | Should-Throw -ExceptionMessage 'The change is a no-op; nothing is pushed.'
    }
}
