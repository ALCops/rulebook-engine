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

    function Invoke-WithoutHost {
        # Runs Script in a new runspace without a host, so the 'What if:' lines of -WhatIf are not printed. Imports the
        # Template module there; returns the output and rethrows the first error.
        param([Parameter(Mandatory)][scriptblock]$Script, [object[]]$ArgumentList = @())
        $shell = [powershell]::Create()
        try {
            $null = $shell.AddCommand('Import-Module').AddArgument((Join-Path $script:repoRoot 'modules' 'Rulebook.Template.psd1')).AddStatement().AddScript($Script.ToString())
            foreach ($argument in $ArgumentList) { $null = $shell.AddArgument($argument) }
            $output = $shell.Invoke()
            if ($shell.Streams.Error.Count -gt 0) { throw $shell.Streams.Error[0] }
            return $output
        } finally {
            $shell.Dispose()
        }
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
        $changes = Invoke-WithoutHost -Script { param($rulebookDir, $outputPath) Build-RulebookBase -RulebookDir $rulebookDir -OutputPath $outputPath -WhatIf } -ArgumentList $tiny, $out
        @($changes | ForEach-Object Change) | Should-BeCollection @('created', 'created', 'created')
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
        @{ Name = 'twins.json has no values'; File = 'matrix/twins.json'; Edit = { $_.Remove('values') }; Message = "matrix/twins.json has no 'values'" }
        @{ Name = 'levels.json has no levels'; File = 'matrix/levels.json'; Edit = { $_.Remove('levels') }; Message = "matrix/levels.json has no 'levels'" }
        @{ Name = 'an inventory row has no boolean enabled'; File = 'inventory/inventory.json'; Edit = { $_[2]['enabled'] = 'false' }; Message = 'inventory/inventory.json: AL0603 has no boolean enabled' }
        @{ Name = 'an inventory default is not a severity'; File = 'inventory/inventory.json'; Edit = { $_[0]['default'] = 'None' }; Message = "inventory/inventory.json: AL0200 has default 'None'*" }
    ) {
        $copy = Copy-Tiny
        Edit-FixtureJson -Path (Join-Path $copy $File) -Script $Edit
        $out = Get-TestFolder
        { Build-RulebookBase -RulebookDir $copy -OutputPath $out } | Should-Throw -ExceptionMessage $Message
        Test-Path -LiteralPath $out | Should-BeFalse -Because 'nothing is written when an input throws'
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
        $script:tinyIds = @(Get-Content -LiteralPath (Join-Path $tiny 'inventory' 'inventory.json') -Raw | ConvertFrom-Json | ForEach-Object id)
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
        $entries.Count | Should-Be $tinyIds.Count
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
        $fixtureSettings = Get-Content -LiteralPath $settingsFixture -Raw | ConvertFrom-Json
        $script:skeletonNames = foreach ($level in $fixtureSettings.levels) {
            foreach ($stage in $fixtureSettings.stages) { '{0}.{1}.ruleset.json' -f $level.name.ToLowerInvariant(), $stage.name.ToLowerInvariant() }
        }
    }

    It 'writes levels x stages skeletons named <level>.<stage>.ruleset.json' {
        $skeletonChanges.Count | Should-Be @($skeletonNames).Count
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

Describe 'Validate on template/' {
    It 'Test-Rulebook reports nothing, C12 included' {
        $findings = @(Test-Rulebook -RepositoryRoot $templateDir)
        @($findings | ForEach-Object { '{0} {1} {2} {3}' -f $_.Rule, $_.File, $_.Id, $_.Message }) | Should-BeCollection @()
    }
}

Describe 'Shipped template content' {
    BeforeAll {
        $script:inventory = @(Get-Content -LiteralPath (Join-Path $rulebookDir 'inventory' 'inventory.json') -Raw | ConvertFrom-Json -AsHashtable)
        $script:counts = Read-CountsTable
        $script:shippedLevels = @('essential', 'recommended', 'strict', 'complete')
        $script:shippedStages = @('default', 'ci', 'vnext')
        $script:endpointNames = foreach ($level in $shippedLevels) {
            foreach ($stage in $shippedStages) { if ($stage -eq 'default') { "$level.ruleset.json" } else { "$level.$stage.ruleset.json" } }
        }
        $script:templateInputs = Read-RulebookInputs -RepositoryRoot $templateDir
        $script:levelCount = @($templateInputs.Levels).Count
        $script:stageCount = @($templateInputs.Stages).Count
        $script:matrixTwins = Get-Content -LiteralPath (Join-Path $rulebookDir 'matrix' 'twins.json') -Raw | ConvertFrom-Json

        function Get-SortedName {
            # The names sorted ordinally, joined with ', '.
            param([string[]]$Names)
            [string[]]$copy = @($Names)
            [System.Array]::Sort($copy, [System.StringComparer]::Ordinal)
            return $copy -join ', '
        }

        function Get-FolderName {
            param([string]$Folder)
            return Get-SortedName @(Get-ChildItem -LiteralPath (Join-Path $templateDir $Folder) -File | ForEach-Object Name)
        }
    }

    It 'has exactly 4 level files, base/twins.json, 2 stage files, 12 endpoints, 12 skeletons and the skeletons README with the naming.md names' {
        Get-FolderName 'base' | Should-Be (Get-SortedName (@($shippedLevels | ForEach-Object { "$_.ruleset.json" }) + 'twins.json'))
        Get-FolderName 'stages' | Should-Be 'ci.json, vnext.json'
        Get-FolderName 'rulesets' | Should-Be (Get-SortedName $endpointNames)
        Get-FolderName 'skeletons' | Should-Be (Get-SortedName (@(foreach ($level in $shippedLevels) { foreach ($stage in $shippedStages) { "$level.$stage.ruleset.json" } }) + 'README.md'))
    }

    It 'ships settings with quarantine unset, twins both and an empty baseUrl that pass the settings schema' {
        $path = Join-Path $templateDir '.github' 'Rulebook-Settings.json'
        $settings = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
        $settings['quarantine'].Contains('stages') | Should-BeTrue
        $settings['quarantine']['stages'] | Should-BeNull
        $settings['quarantine']['prereleaseStages'] | Should-BeNull
        $settings['twins'] | Should-Be 'both'
        $settings['baseUrl'] | Should-Be ''
        Test-Json -Path $path -SchemaFile (Join-Path $schemaDir 'rulebook-settings.schema.json') | Should-BeTrue
    }

    It 'has the entry counts of the file table in matrix/counts.md' {
        $counts.Entries.Count | Should-Be ($levelCount + $stageCount - 1)
        foreach ($file in $counts.Entries.Keys) {
            @(Get-RuleText -Path (Join-Path $templateDir $file)).Count | Should-Be $counts.Entries[$file] -Because $file
        }
    }

    It 'lists in every endpoint the number of ids of the Listed column in matrix/counts.md' {
        $counts.Listed.Count | Should-Be ($levelCount * $stageCount)
        foreach ($key in $counts.Listed.Keys) {
            $level, $stage = $key -split '\.'
            $file = if ($stage -eq 'default') { "$level.ruleset.json" } else { "$level.$stage.ruleset.json" }
            @(Get-RuleText -Path (Join-Path $templateDir 'rulesets' $file)).Count | Should-Be $counts.Listed[$key] -Because $file
        }
    }

    It 'writes every generated file in ascending Get-DiagnosticSortKey order' {
        $files = @(
            Get-ChildItem -LiteralPath (Join-Path $templateDir 'base') -Filter '*.ruleset.json' -File
            Get-ChildItem -LiteralPath (Join-Path $templateDir 'stages') -File
            Get-ChildItem -LiteralPath (Join-Path $templateDir 'rulesets') -File
        )
        $unsorted = foreach ($file in $files) {
            $keys = @((Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json).rules | ForEach-Object { Get-DiagnosticSortKey -Id $_.id })
            for ($i = 1; $i -lt $keys.Count; $i++) { if ([string]::CompareOrdinal($keys[$i - 1], $keys[$i]) -ge 0) { $file.Name; break } }
        }
        @($unsorted) | Should-BeCollection @()
        $catalogKeys = @((Get-Content -LiteralPath (Join-Path $templateDir 'catalog' 'diagnostics.json') -Raw | ConvertFrom-Json).diagnostics | ForEach-Object { Get-DiagnosticSortKey -Id $_.id })
        for ($i = 1; $i -lt $catalogKeys.Count; $i++) { [string]::CompareOrdinal($catalogKeys[$i - 1], $catalogKeys[$i]) | Should-BeLessThan 0 }
    }

    It 'ships base/twins.json with the pairs of matrix/twins.json (17 today) and their count' {
        $twins = Get-Content -LiteralPath (Join-Path $templateDir 'base' 'twins.json') -Raw | ConvertFrom-Json
        $twins.count | Should-Be $matrixTwins.count
        @($twins.pairs).Count | Should-Be @($matrixTwins.pairs).Count
        @($twins.pairs | ForEach-Object { $_.pte + '/' + $_.appsource } | Sort-Object) | Should-BeCollection @($matrixTwins.pairs | ForEach-Object { $_.pte + '/' + $_.appsource } | Sort-Object)
        $twins.'$schema' | Should-Be 'https://raw.githubusercontent.com/ALCops/rulebook-engine/v1/schemas/rulebook-twins.schema.json'
    }

    It 'seeds the catalog with every inventory id in inventory order at its analyzer default' {
        $catalogPath = Join-Path $templateDir 'catalog' 'diagnostics.json'
        $ids = @((Get-Content -LiteralPath $catalogPath -Raw | ConvertFrom-Json).diagnostics | ForEach-Object id)
        $ids.Count | Should-Be $inventory.Count
        $ids | Should-BeCollection @($inventory | ForEach-Object { $_['id'] })
        $catalog = Read-Catalog -Path $catalogPath
        $wrong = foreach ($row in $inventory) {
            $default = if ($row['enabled']) { $row['default'] } else { 'None' }
            if ($catalog[$row['id']].Default -cne $default) { $row['id'] }
        }
        @($wrong) | Should-BeCollection @()
    }

    It 'composes <Id> to <Action> on strict from <Source>' -ForEach @(
        @{ Id = 'PC0002'; Action = 'Error'; Source = 'default' }
        @{ Id = 'AS0001'; Action = 'Error'; Source = 'default' }
        @{ Id = 'PTE0001'; Action = 'Error'; Source = 'default' }
        @{ Id = 'AS0084'; Action = 'Error'; Source = 'level:recommended' }
    ) {
        $result = Get-EffectiveAction -Inputs $templateInputs -Id $Id -Level 'strict' -Stage 'default'
        '{0} {1}' -f $result.Action, $result.Source | Should-Be "$Action $Source"
    }

    It 'holds AL0432 at Info in stages/ci.json' {
        Get-RuleText -Path (Join-Path $templateDir 'stages' 'ci.json') | Should-ContainCollection @('AL0432 Info')
    }

    It 'lists AL0432 Info in rulesets/strict.ci.ruleset.json and not AS0001, PTE0001 or AS0084' {
        $entries = Get-RuleText -Path (Join-Path $templateDir 'rulesets' 'strict.ci.ruleset.json')
        $entries -ccontains 'AL0432 Info' | Should-BeTrue
        @($entries | Where-Object { $_ -match '^(AS0001|PTE0001|AS0084) ' }) | Should-BeCollection @()
    }

    It 'lists AS0084 None in rulesets/essential.ci.ruleset.json' {
        (Get-RuleText -Path (Join-Path $templateDir 'rulesets' 'essential.ci.ruleset.json')) -ccontains 'AS0084 None' | Should-BeTrue
    }

    It 'lists no endpoint entry at its catalog default' {
        $atDefault = foreach ($name in $endpointNames) {
            $json = Get-Content -LiteralPath (Join-Path $templateDir 'rulesets' $name) -Raw | ConvertFrom-Json
            foreach ($rule in $json.rules) { if ($rule.action -ceq $templateInputs.Catalog[$rule.id].Default) { "$name $($rule.id)" } }
        }
        @($atDefault) | Should-BeCollection @()
    }

    It 'has no carriage return in any file under template/' {
        $withCr = foreach ($file in Get-ChildItem -LiteralPath $templateDir -Recurse -File -Force) {
            if ([System.Array]::IndexOf([System.IO.File]::ReadAllBytes($file.FullName), [byte]13) -ge 0) { $file.FullName }
        }
        @($withCr) | Should-BeCollection @()
    }

    It 'composes every cell of matrix/resolved.json from the files on disk (V13)' {
        $resolved = Get-Content -LiteralPath (Join-Path $rulebookDir 'matrix' 'resolved.json') -Raw | ConvertFrom-Json -AsHashtable
        $mismatches = [System.Collections.Generic.List[string]]::new()
        $calls = 0
        $elapsed = Measure-Command {
            foreach ($id in $resolved.Keys) {
                foreach ($key in $resolved[$id].Keys) {
                    $level, $stage = $key -split '\.'
                    $calls++
                    $action = (Get-EffectiveAction -Inputs $templateInputs -Id $id -Level $level -Stage $stage).Action
                    if ($action -cne $resolved[$id][$key]) { $mismatches.Add("$id $key composes to $action, resolved.json says $($resolved[$id][$key])") }
                }
            }
        }
        Write-Host ('V13 on template/: {0} Get-EffectiveAction calls in {1:N2} s' -f $calls, $elapsed.TotalSeconds)
        $calls | Should-Be ($inventory.Count * $levelCount * $stageCount)
        @($mismatches) | Should-BeCollection @()
    }
}

Describe 'Build-Template.ps1' {
    BeforeAll {
        $script:wrapper = Join-Path $repoRoot 'tools' 'rulebook' 'Build-Template.ps1'
        $script:handWritten = @(
            '.github/Rulebook-Settings.json'
            '.github/workflows/ChangeRule.yaml'
            '.github/workflows/Publish.yaml'
            '.github/workflows/ScanDiagnostics.yaml'
            '.github/workflows/UpdateRulebookSystemFiles.yaml'
            '.github/workflows/Validate.yaml'
            'README.md'
            'overrides.json'
            'quarantine.default.json'
            'quarantine.ci.json'
            'quarantine.vnext.json'
            'skeletons/README.md'
        )
    }

    It 'reports no change with -WhatIf on the committed template/' {
        @(& $wrapper -WhatIf 6>$null) | Should-BeCollection @()
    }

    It 'regenerates template/ byte for byte from the 12 hand-written files' {
        $scratch = Get-TestFolder
        foreach ($file in $handWritten) {
            $target = Join-Path $scratch $file
            [void](New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force)
            Copy-Item -LiteralPath (Join-Path $templateDir $file) -Destination $target
        }
        $changes = @(& $wrapper -TemplateDir $scratch 6>$null)
        # Generated: the level files, twins.json, the non-default stage files, the catalog, the skeletons and endpoints.
        $settings = Get-Content -LiteralPath (Join-Path $scratch '.github' 'Rulebook-Settings.json') -Raw | ConvertFrom-Json
        $levelTotal = @((Get-Content -LiteralPath (Join-Path $rulebookDir 'matrix' 'levels.json') -Raw | ConvertFrom-Json).levels).Count
        $stageTotal = @((Get-Content -LiteralPath (Join-Path $rulebookDir 'matrix' 'stages.json') -Raw | ConvertFrom-Json).stages).Count
        $changes.Count | Should-Be ($levelTotal + 1 + ($stageTotal - 1) + 1 + 2 * @($settings.levels).Count * @($settings.stages).Count)
        @($changes | Where-Object Change -ne 'created') | Should-BeCollection @()
        Get-TemplateHash -Root $scratch | Should-BeCollection (Get-TemplateHash -Root $templateDir)
        @(& $wrapper -TemplateDir $scratch 6>$null) | Should-BeCollection @()
        $elapsed = Measure-Command { $script:endpointChanges = @(Update-RulebookEndpoints -RepositoryRoot $scratch) }
        Write-Host ('Update-RulebookEndpoints on template/ ({0} catalog ids): {1:N2} s' -f (Read-Catalog -Path (Join-Path $scratch 'catalog' 'diagnostics.json')).Count, $elapsed.TotalSeconds)
        $endpointChanges.Count | Should-Be 0
        $elapsed.TotalSeconds | Should-BeLessThan 30
    }

    It 'rejects settings whose basedOn names no level file' {
        $copy = Copy-Template
        Edit-FixtureJson -Path (Join-Path $copy '.github' 'Rulebook-Settings.json') -Script { $_['levels'][2]['basedOn'] = 'Paranoid' }
        { & $wrapper -TemplateDir $copy 6>$null } | Should-Throw -ExceptionMessage "*Unresolved basedOn 'paranoid' of level 'Strict'*"
    }

    It 'rejects settings with an unknown twins value' {
        $copy = Copy-Template
        Edit-FixtureJson -Path (Join-Path $copy '.github' 'Rulebook-Settings.json') -Script { $_['twins'] = 'all' }
        { & $wrapper -TemplateDir $copy 6>$null } | Should-Throw -ExceptionMessage "*twins is 'all'*"
    }
}
