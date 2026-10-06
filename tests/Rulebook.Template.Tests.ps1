# Template suite for WP04 (#6): modules/Rulebook.Template and tools/rulebook/Build-Template.ps1.
# Unit cases run on the tiny matrix under tests/fixtures/matrix/tiny/ (six ids over three prefixes, levels Core and
# Extended, stages default and CI, one twin pair); the expected files are derived by hand from
# docs/rulebook/composition.md section 3. The shipped-content cases run on docs/rulebook and the committed template/.

BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:repoRoot 'modules' 'Rulebook.Generate.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'modules' 'Rulebook.Validate.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'modules' 'Rulebook.Template.psd1') -Force
    . (Join-Path $PSScriptRoot 'Helpers' 'RepoFixture.ps1')

    $script:tiny = Join-Path $PSScriptRoot 'fixtures' 'matrix' 'tiny'
    $script:rulebookDir = Join-Path $script:repoRoot 'docs' 'rulebook'
    $script:templateDir = Join-Path $script:repoRoot 'template'
    $script:schemaDir = Join-Path $script:repoRoot 'schemas'
    $script:settingsFixture = Join-Path $PSScriptRoot 'fixtures' 'schemas' 'valid' 'rulebook-settings' 'template-default.json'
    $script:deltaUrl = 'https://raw.githubusercontent.com/ALCops/rulebook-engine/v1/schemas/ruleset.delta.schema.json'

    function Get-TestFolder {
        return Join-Path $TestDrive ([guid]::NewGuid().ToString('n').Substring(0, 12))
    }

    function Copy-Tiny {
        # A writable copy of the tiny matrix, for the cases that mutate it.
        $destination = Get-TestFolder
        Copy-FixtureTree -Source $script:tiny -Destination $destination
        return $destination
    }

    function Copy-Template {
        # A writable copy of the committed template/.
        $destination = Get-TestFolder
        Copy-FixtureTree -Source $script:templateDir -Destination $destination
        return $destination
    }

    function Get-TemplateHash {
        # name=sha256 per file under Root, names relative with '/', sorted ordinally.
        param([Parameter(Mandatory)][string]$Root)
        $full = (Resolve-Path -LiteralPath $Root).ProviderPath
        [string[]]$lines = @(Get-ChildItem -LiteralPath $full -Recurse -File -Force | ForEach-Object {
                '{0}={1}' -f ([System.IO.Path]::GetRelativePath($full, $_.FullName) -replace '\\', '/'), (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
            })
        [System.Array]::Sort($lines, [System.StringComparer]::Ordinal)
        return $lines
    }

    function Get-RuleText {
        # 'id action' or 'id action justification' per rule of a ruleset file.
        param([Parameter(Mandatory)][string]$Path, [switch]$WithJustification)
        $json = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
        return @($json['rules'] | ForEach-Object {
                if ($WithJustification) { '{0} {1} {2}' -f $_['id'], $_['action'], $_['justification'] } else { '{0} {1}' -f $_['id'], $_['action'] }
            })
    }

    function Get-Line {
        param([Parameter(Mandatory)][string]$Path)
        return @(([System.IO.File]::ReadAllText($Path)).Split("`n"))
    }

    function Read-CountsTable {
        # matrix/counts.md: Listed per <level>.<stage> (12 rows) and Entries per base/stage file (6 rows).
        $lines = Get-Content -LiteralPath (Join-Path $script:rulebookDir 'matrix' 'counts.md')
        $listed = [ordered]@{}
        $entries = [ordered]@{}
        foreach ($line in $lines) {
            if ($line -match '^\| (Essential|Recommended|Strict|Complete) \| (\w+) \|.* (\d+) \|$') {
                $listed["$($Matches[1].ToLowerInvariant()).$($Matches[2].ToLowerInvariant())"] = [int]$Matches[3]
            } elseif ($line -match '^\| `((?:base|stages)/[^`]+)` \| (\d+) \|$') {
                $entries[$Matches[1]] = [int]$Matches[2]
            }
        }
        return [pscustomobject]@{ Listed = $listed; Entries = $entries }
    }
}

AfterAll {
    Remove-Module Rulebook.Template, Rulebook.Validate, Rulebook.Generate -ErrorAction SilentlyContinue
}

Describe 'Build-RulebookBase' {
    BeforeAll {
        $script:baseOut = Get-TestFolder
        $script:baseChanges = @(Build-RulebookBase -RulebookDir $tiny -OutputPath $baseOut)
    }

    It 'writes one file per level of levels.json and twins.json' {
        @($baseChanges | ForEach-Object { '{0} {1}' -f $_.File, $_.Change }) |
            Should-BeCollection @("$(Split-Path -Leaf $baseOut)/core.ruleset.json created", "$(Split-Path -Leaf $baseOut)/extended.ruleset.json created", "$(Split-Path -Leaf $baseOut)/twins.json created")
        @(Get-ChildItem -LiteralPath $baseOut -File | ForEach-Object Name | Sort-Object) | Should-BeCollection @('core.ruleset.json', 'extended.ruleset.json', 'twins.json')
    }

    It 'writes $schema first, then the name and the description' {
        $root = Get-Line (Join-Path $baseOut 'core.ruleset.json')
        $root[1] | Should-Be "  `"`$schema`": `"$deltaUrl`","
        $root[2] | Should-Be '  "name": "Rulebook Core",'
        $root[3] | Should-Be '  "description": "Level core, the root. Lists the ids whose action differs from the analyzer default. Generated from docs/rulebook; do not edit.",'
        $delta = Get-Line (Join-Path $baseOut 'extended.ruleset.json')
        $delta[2] | Should-Be '  "name": "Rulebook Extended",'
        $delta[3] | Should-Be '  "description": "Level extended, basedOn core. Lists the ids whose action differs from core. Generated from docs/rulebook; do not edit.",'
    }

    It 'lists in the root only the ids that differ from the analyzer default' {
        # AL0432 Warning, PTE0003 Error and AS0084 Error equal their defaults; AL0603 is None and disabled by default.
        Get-RuleText -Path (Join-Path $baseOut 'core.ruleset.json') -WithJustification |
            Should-BeCollection @('AL0200 None Advisory below Extended; D-01', 'AS0061 None Marketplace check from Extended; F-07')
    }

    It 'lists in a delta only the ids that differ from the basedOn cell' {
        Get-RuleText -Path (Join-Path $baseOut 'extended.ruleset.json') -WithJustification | Should-BeCollection @(
            'AL0200 Warning Advisory below Extended; D-01'
            'AL0603 Info Opt-in rule enabled from Extended; D-09'
            'AS0061 Error Marketplace check from Extended; F-07'
            'AS0084 Warning Lowered at Extended for the fixture; OV-01')
    }

    It 'writes base/twins.json with $schema, one pair per line' {
        [System.IO.File]::ReadAllText((Join-Path $baseOut 'twins.json')) | Should-Be (@(
                '{'
                '  "$schema": "https://raw.githubusercontent.com/ALCops/rulebook-engine/v1/schemas/rulebook-twins.schema.json",'
                '  "generatedBy": "tools/rulebook/Build-Template.ps1",'
                '  "setting": "twins",'
                '  "values": ["both", "appsource", "pte"],'
                '  "count": 1,'
                '  "pairs": ['
                '    { "pte": "PTE0003", "appsource": "AS0061", "title": "Procedures must not subscribe to CompanyOpen events" }'
                '  ]'
                '}'
                ''
            ) -join "`n")
        Test-Json -Path (Join-Path $baseOut 'twins.json') -SchemaFile (Join-Path $schemaDir 'rulebook-twins.schema.json') | Should-BeTrue
    }

    It 'sorts the twin pairs by the sort key of the PTE side' {
        $copy = Copy-Tiny
        Edit-FixtureJson -Path (Join-Path $copy 'matrix' 'twins.json') -Script {
            $_['pairs'] = @(@{ pte = 'PTE0011'; appsource = 'AS0048' }) + @($_['pairs'])
        }
        $out = Get-TestFolder
        $null = Build-RulebookBase -RulebookDir $copy -OutputPath $out
        $twins = Get-Content -LiteralPath (Join-Path $out 'twins.json') -Raw | ConvertFrom-Json
        @($twins.pairs | ForEach-Object pte) | Should-BeCollection @('PTE0003', 'PTE0011')
        (Get-Line (Join-Path $out 'twins.json'))[8] | Should-Be '    { "pte": "PTE0011", "appsource": "AS0048" }'
    }

    It 'writes valid delta files' {
        foreach ($name in 'core.ruleset.json', 'extended.ruleset.json') {
            Test-Json -Path (Join-Path $baseOut $name) -SchemaFile (Join-Path $schemaDir 'ruleset.delta.schema.json') | Should-BeTrue
        }
    }

    It 'returns nothing on a second run' {
        @(Build-RulebookBase -RulebookDir $tiny -OutputPath $baseOut).Count | Should-Be 0
    }

    It 'writes nothing with -WhatIf and reports the same changes' {
        $out = Get-TestFolder
        @(Build-RulebookBase -RulebookDir $tiny -OutputPath $out -WhatIf | ForEach-Object Change) | Should-BeCollection @('created', 'created', 'created')
        Test-Path -LiteralPath $out | Should-BeFalse
    }

    It 'deletes a level file no level produces and keeps other files' {
        $out = Get-TestFolder
        $null = Build-RulebookBase -RulebookDir $tiny -OutputPath $out
        Write-FixtureText -Path (Join-Path $out 'old.ruleset.json') -Text '{ "name": "Old", "rules": [] }'
        Write-FixtureText -Path (Join-Path $out 'notes.txt') -Text 'kept'
        $changes = @(Build-RulebookBase -RulebookDir $tiny -OutputPath $out)
        @($changes | ForEach-Object { '{0} {1}' -f (Split-Path -Leaf $_.File), $_.Change }) | Should-BeCollection @('old.ruleset.json deleted')
        Test-Path -LiteralPath (Join-Path $out 'old.ruleset.json') | Should-BeFalse
        Test-Path -LiteralPath (Join-Path $out 'notes.txt') | Should-BeTrue
    }

    It 'rewrites a file whose bytes differ' {
        $out = Get-TestFolder
        $null = Build-RulebookBase -RulebookDir $tiny -OutputPath $out
        $path = Join-Path $out 'core.ruleset.json'
        [System.IO.File]::WriteAllText($path, [System.IO.File]::ReadAllText($path).Replace("`n", "`r`n"))
        @(Build-RulebookBase -RulebookDir $tiny -OutputPath $out | ForEach-Object { '{0} {1}' -f (Split-Path -Leaf $_.File), $_.Change }) |
            Should-BeCollection @('core.ruleset.json modified')
        [System.IO.File]::ReadAllText($path) | Should-NotMatchString "`r"
    }

    It 'throws when <Name>' -ForEach @(
        @{ Name = 'the matrix order differs from the inventory'; File = 'matrix/matrix.json'; Edit = { $first = $_[0]; $_[0] = $_[1]; $_[1] = $first }; Message = '*row 0 is AL0432*the order must match*' }
        @{ Name = 'a basedOn names no level'; File = 'matrix/levels.json'; Edit = { $_['levels'][1]['basedOn'] = 'Missing' }; Message = "*unresolved basedOn 'Missing' of level 'Extended'*" }
        @{ Name = 'a level name is not a slug'; File = 'matrix/levels.json'; Edit = { $_['levels'][0]['name'] = 'Core Rules'; $_['levels'][0].Remove('slug') }; Message = "*levels entry 'Core Rules' does not lowercase to a slug*" }
        @{ Name = 'a level slug disagrees with its name'; File = 'matrix/levels.json'; Edit = { $_['levels'][0]['slug'] = 'base' }; Message = "*has slug 'base', expected 'core'*" }
        @{ Name = 'basedOn forms a cycle'; File = 'matrix/levels.json'; Edit = { $_['levels'][0]['basedOn'] = 'Extended' }; Message = '*basedOn cycle*' }
        @{ Name = 'a resolved cell is not an action'; File = 'matrix/resolved.json'; Edit = { $_['AL0200']['core.default'] = 'Default' }; Message = "*AL0200 has action 'Default' at core.default*" }
        @{ Name = 'an id has no resolved cells'; File = 'matrix/resolved.json'; Edit = { $_.Remove('AS0084') }; Message = '*no cells for AS0084*' }
        @{ Name = 'a twin side is in two pairs'; File = 'matrix/twins.json'; Edit = { $_['pairs'] = @($_['pairs']) + @(@{ pte = 'PTE0004'; appsource = 'AS0061' }) }; Message = '*lists AS0061 in two pairs*' }
    ) {
        $copy = Copy-Tiny
        Edit-FixtureJson -Path (Join-Path $copy $File) -Script $Edit
        { Build-RulebookBase -RulebookDir $copy -OutputPath (Get-TestFolder) } | Should-Throw -ExceptionMessage $Message
    }
}

Describe 'Build-RulebookStages' {
    BeforeAll {
        $script:stagesOut = Get-TestFolder
        $script:stageChanges = @(Build-RulebookStages -RulebookDir $tiny -OutputPath $stagesOut)
    }

    It 'writes one file per non-default stage and none for default' {
        @($stageChanges | ForEach-Object { (Split-Path -Leaf $_.File) + ' ' + $_.Change }) | Should-BeCollection @('ci.json created')
        Test-Path -LiteralPath (Join-Path $stagesOut 'default.json') | Should-BeFalse
    }

    It 'lists exactly the ids whose stage column is not = with that action and the row justification' {
        Get-RuleText -Path (Join-Path $stagesOut 'ci.json') -WithJustification | Should-BeCollection @('AL0432 Info Advisory in CI; F-05')
    }

    It 'names the stage with the settings casing and carries the delta profile URL' {
        $lines = Get-Line (Join-Path $stagesOut 'ci.json')
        $lines[1] | Should-Be "  `"`$schema`": `"$deltaUrl`","
        $lines[2] | Should-Be '  "name": "Rulebook stage CI",'
        $lines[3] | Should-Be '  "description": "Stage ci. Applied on top of every level where the level result is not None. Generated from docs/rulebook; do not edit.",'
        Test-Json -Path (Join-Path $stagesOut 'ci.json') -SchemaFile (Join-Path $schemaDir 'ruleset.delta.schema.json') | Should-BeTrue
    }

    It 'returns nothing on a second run and deletes a stray default.json' {
        @(Build-RulebookStages -RulebookDir $tiny -OutputPath $stagesOut).Count | Should-Be 0
        Write-FixtureText -Path (Join-Path $stagesOut 'default.json') -Text '{ "name": "x", "rules": [] }'
        @(Build-RulebookStages -RulebookDir $tiny -OutputPath $stagesOut | ForEach-Object { (Split-Path -Leaf $_.File) + ' ' + $_.Change }) |
            Should-BeCollection @('default.json deleted')
    }

    It 'throws when a stage names no matrix column' {
        $copy = Copy-Tiny
        Edit-FixtureJson -Path (Join-Path $copy 'matrix' 'stages.json') -Script { $_['stages'] = @($_['stages']) + @(@{ name = 'Nightly'; slug = 'nightly' }) }
        { Build-RulebookStages -RulebookDir $copy -OutputPath (Get-TestFolder) } | Should-Throw -ExceptionMessage "*has no column 'Nightly' for stage 'nightly'*"
    }

    It 'throws when a stage column holds no action' {
        $copy = Copy-Tiny
        Edit-FixtureJson -Path (Join-Path $copy 'matrix' 'matrix.json') -Script { $_[1]['CI'] = 'Default' }
        { Build-RulebookStages -RulebookDir $copy -OutputPath (Get-TestFolder) } | Should-Throw -ExceptionMessage "*AL0432 has 'Default' in column CI*"
    }

    It 'throws when there is no default stage' {
        $copy = Copy-Tiny
        Edit-FixtureJson -Path (Join-Path $copy 'matrix' 'stages.json') -Script { $_['stages'] = @($_['stages'] | Select-Object -Skip 1) }
        { Build-RulebookStages -RulebookDir $copy -OutputPath (Get-TestFolder) } | Should-Throw -ExceptionMessage '*has no default stage*'
    }
}

Describe 'Build-RulebookCatalog' {
    BeforeAll {
        $script:catalogPath = Join-Path (Get-TestFolder) 'catalog' 'diagnostics.json'
        $script:catalogChanges = @(Build-RulebookCatalog -RulebookDir $tiny -OutputPath $catalogPath)
        $script:catalogLines = Get-Line $catalogPath
    }

    It 'reports catalog/diagnostics.json' {
        @($catalogChanges | ForEach-Object { '{0} {1}' -f $_.File, $_.Change }) | Should-BeCollection @('catalog/diagnostics.json created')
    }

    It 'writes $schema and version 1 before the entries' {
        $catalogLines[1] | Should-Be '  "$schema": "https://raw.githubusercontent.com/ALCops/rulebook-engine/v1/schemas/rulebook-catalog.schema.json",'
        $catalogLines[2] | Should-Be '  "version": 1,'
        $catalogLines[3] | Should-Be '  "diagnostics": ['
    }

    It 'writes one entry per line with the keys in order' {
        $entries = @($catalogLines | Where-Object { $_ -like '    {*' })
        $entries.Count | Should-Be 6
        foreach ($line in $entries) {
            $line | Should-MatchString '^    \{ "id": "[A-Z]+[0-9]{4}i?", "analyzer": "[^"]+", "defaultSeverity": "(Error|Warning|Info|Hidden)", "enabledByDefault": (true|false)(, "title": "(?:[^"\\]|\\.)*")?(, "docs": "[^"]*")? \},?$'
        }
    }

    It 'writes the inventory order, the defaults and no null' {
        $json = Get-Content -LiteralPath $catalogPath -Raw | ConvertFrom-Json -AsHashtable
        @($json['diagnostics'] | ForEach-Object { '{0} {1} {2}' -f $_['id'], $_['defaultSeverity'], $_['enabledByDefault'] }) |
            Should-BeCollection @('AL0200 Warning True', 'AL0432 Warning True', 'AL0603 Info False', 'PTE0003 Error True', 'AS0061 Error True', 'AS0084 Error True')
        [System.IO.File]::ReadAllText($catalogPath) | Should-NotMatchString 'null'
    }

    It 'leaves out an empty docs URL and escapes a double quote in a title' {
        @($catalogLines | Where-Object { $_ -like '*"AL0603"*' })[0] | Should-Be '    { "id": "AL0603", "analyzer": "Compiler", "defaultSeverity": "Info", "enabledByDefault": false, "title": "Implicit conversion" },'
        @($catalogLines | Where-Object { $_ -like '*"AS0084"*' })[0] | Should-MatchString ([regex]::Escape('"title": "Set the \"idRanges\" in app.json"'))
    }

    It 'passes the catalog schema and Read-Catalog' {
        Test-Json -Path $catalogPath -SchemaFile (Join-Path $schemaDir 'rulebook-catalog.schema.json') | Should-BeTrue
        (Read-Catalog -Path $catalogPath)['AL0603'].Default | Should-Be 'None'
    }

    It 'returns nothing on a second run' {
        @(Build-RulebookCatalog -RulebookDir $tiny -OutputPath $catalogPath).Count | Should-Be 0
    }
}

Describe 'New-RulebookSkeleton' {
    BeforeAll {
        $script:skeletonOut = Get-TestFolder
        $script:skeletonChanges = @(New-RulebookSkeleton -SettingsPath $settingsFixture -OutputPath $skeletonOut)
        $script:skeletonNames = foreach ($level in 'essential', 'recommended', 'strict', 'complete') {
            foreach ($stage in 'default', 'ci', 'vnext') { "$level.$stage.ruleset.json" }
        }
    }

    It 'writes levels x stages skeletons named <level>.<stage>.ruleset.json' {
        $skeletonChanges.Count | Should-Be 12
        [string[]]$actual = @(Get-ChildItem -LiteralPath $skeletonOut -File | ForEach-Object Name)
        [System.Array]::Sort($actual, [System.StringComparer]::Ordinal)
        [string[]]$expected = @($skeletonNames)
        [System.Array]::Sort($expected, [System.StringComparer]::Ordinal)
        $actual | Should-BeCollection $expected
    }

    It 'writes strict.ci byte for byte as the schema fixture' {
        $fixture = Join-Path $PSScriptRoot 'fixtures' 'schemas' 'valid' 'ruleset.skeleton' 'skeleton-baseurl-placeholder.json'
        (Get-FileHash -LiteralPath (Join-Path $skeletonOut 'strict.ci.ruleset.json')).Hash | Should-Be (Get-FileHash -LiteralPath $fixture).Hash
    }

    It 'includes the endpoint without a suffix for the default stage' {
        $json = Get-Content -LiteralPath (Join-Path $skeletonOut 'strict.default.ruleset.json') -Raw | ConvertFrom-Json -AsHashtable
        $json['name'] | Should-Be 'Rulebook Strict / default'
        $json['includedRuleSets'][0]['path'] | Should-Be '{BASEURL}/rulesets/strict.ruleset.json'
        $json['includedRuleSets'][0]['action'] | Should-Be 'Default'
    }

    It 'writes skeletons that pass the skeleton profile and carry no $schema' {
        foreach ($name in $skeletonNames) {
            $path = Join-Path $skeletonOut $name
            Test-Json -Path $path -SchemaFile (Join-Path $schemaDir 'ruleset.skeleton.schema.json') | Should-BeTrue
            [System.IO.File]::ReadAllText($path) | Should-NotMatchString 'schema'
        }
    }

    It 'returns nothing on a second run and deletes a skeleton no level and stage produces' {
        @(New-RulebookSkeleton -SettingsPath $settingsFixture -OutputPath $skeletonOut).Count | Should-Be 0
        Write-FixtureText -Path (Join-Path $skeletonOut 'paranoid.ci.ruleset.json') -Text '{}'
        @(New-RulebookSkeleton -SettingsPath $settingsFixture -OutputPath $skeletonOut | ForEach-Object { '{0} {1}' -f (Split-Path -Leaf $_.File), $_.Change }) |
            Should-BeCollection @('paranoid.ci.ruleset.json deleted')
    }

    It 'rejects a level name that is not a slug' {
        $settings = Join-Path (Get-TestFolder) 'Rulebook-Settings.json'
        Write-FixtureText -Path $settings -Text ([System.IO.File]::ReadAllText($settingsFixture))
        Edit-FixtureJson -Path $settings -Script { $_['levels'][0]['name'] = 'Very Strict' }
        { New-RulebookSkeleton -SettingsPath $settings -OutputPath (Get-TestFolder) } | Should-Throw -ExceptionMessage "*levels entry 'Very Strict' does not lowercase to a slug matching*(C5)"
    }

    It 'rejects a duplicate stage slug' {
        $settings = Join-Path (Get-TestFolder) 'Rulebook-Settings.json'
        Write-FixtureText -Path $settings -Text ([System.IO.File]::ReadAllText($settingsFixture))
        Edit-FixtureJson -Path $settings -Script { $_['stages'][2]['name'] = 'ci' }
        { New-RulebookSkeleton -SettingsPath $settings -OutputPath (Get-TestFolder) } | Should-Throw -ExceptionMessage "*stages slug 'ci' is used twice (C5)"
    }
}
