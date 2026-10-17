# Site suite for WP14 (#16, #62, #51): modules/Rulebook.Site (the site data model, its writer and the export of
# site/data/rulebook.json). Cases run on the repository fixtures under tests/fixtures/repos/ (valid-minimal and the
# twins-appsource and unknown-id overlays), on a repository built from the tiny matrix, and on the committed export
# tests/fixtures/site-data/rulebook.json (regeneration command in its README). generatedAt is checked on the text:
# ConvertFrom-Json turns it into a DateTime (#62).

BeforeAll {
    # docsUrl follows the engine ref: clear what a runner step would set, restore it in AfterAll.
    . (Join-Path $PSScriptRoot 'Helpers' 'EngineRef.ps1')
    $script:savedEngineRef = Clear-EngineRefEnvironment
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:repoRoot 'modules' 'Rulebook.Generate.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'modules' 'Rulebook.Template.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'modules' 'Rulebook.Catalog.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'modules' 'Rulebook.Levels.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'modules' 'Rulebook.Site.psd1') -Force
    . (Join-Path $PSScriptRoot 'Helpers' 'RepoFixture.ps1')

    $script:baseUrl = 'https://contoso.github.io/rulebook'
    $script:siteFixture = Join-Path $PSScriptRoot 'fixtures' 'site-data' 'rulebook.json'
    $script:generatedAtLine = '(?m)\A\{\n  "generatedAt": "\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z",\n'

    function Get-TestFolder {
        return Join-Path $TestDrive ([guid]::NewGuid().ToString('n').Substring(0, 12))
    }

    function Copy-Fixture {
        param([string]$Name = 'valid-minimal')
        return New-FixtureRepo -Name $Name -Destination (Get-TestFolder)
    }

    function Get-Model {
        param([Parameter(Mandatory)][string]$Root, [switch]$IncludeJustifications, [string]$EngineRef, [string]$Repository = 'contoso/rulebook')
        $inputs = Read-RulebookInputs -RepositoryRoot $Root
        $catalog = Read-CatalogFile -Path (Join-Path $Root 'catalog' 'diagnostics.json')
        return Get-RulebookSiteModel -Inputs $inputs -Catalog $catalog -BaseUrl $baseUrl -Repository $Repository -IncludeJustifications:$IncludeJustifications `
            -GeneratedAt ([datetime]'2026-10-17T00:00:00Z') -EngineRef $EngineRef
    }

    function Get-Rule {
        param([Parameter(Mandatory)]$Model, [Parameter(Mandatory)][string]$Id)
        foreach ($rule in $Model.Document['rules']) { if ($rule['id'] -ceq $Id) { return $rule } }
        throw "No rule $Id in the model"
    }

    function Get-CellText {
        # 'action source [override] [fallback fallbackSource]' of one cell, for exact comparisons.
        param([Parameter(Mandatory)]$Cell)
        return @($Cell.Values | ForEach-Object { if ($null -eq $_) { 'null' } else { [string]$_ } }) -join ' '
    }

    function Read-Text {
        param([Parameter(Mandatory)][string]$Path)
        return [System.IO.File]::ReadAllText($Path)
    }
}

AfterAll {
    Restore-EngineRefEnvironment -Saved $script:savedEngineRef
    Remove-Module Rulebook.Site, Rulebook.Levels, Rulebook.Catalog, Rulebook.Template, Rulebook.Generate, Rulebook.Common -ErrorAction SilentlyContinue
}

Describe 'Get-RulebookSiteModel' {
    BeforeAll {
        $script:validRoot = Copy-Fixture
        $script:validInputs = Read-RulebookInputs -RepositoryRoot $validRoot
        $script:validModel = Get-Model -Root $validRoot
        $script:cellKeys = [string[]]@(foreach ($level in 'essential', 'recommended', 'strict', 'complete') { foreach ($stage in 'default', 'ci', 'vnext') { "$level.$stage" } })
    }

    It 'has one cell per level and stage for every id of valid-minimal, keyed <level>.<stage> in settings order' {
        $validModel.RuleCount | Should-Be 30
        $validModel.CellCount | Should-Be 360
        foreach ($rule in $validModel.Document['rules']) {
            Should-BeCollection -Actual ([string[]]@($rule['cells'].Keys)) -Expected $cellKeys
        }
        $validModel.UnknownIds | Should-BeCollection @()
    }

    It 'takes every cell from the generator: action and source equal Get-EffectiveAction' {
        foreach ($rule in $validModel.Document['rules']) {
            foreach ($key in $cellKeys) {
                $level, $stage = $key.Split('.')
                $expected = Get-EffectiveAction -Inputs $validInputs -Id $rule['id'] -Level $level -Stage $stage
                '{0} {1}' -f $rule['cells'][$key]['action'], $rule['cells'][$key]['source'] | Should-Be ('{0} {1}' -f $expected.Action, $expected.Source) -Because "$($rule['id']) $key"
            }
        }
    }

    It 'records <Source> for <Id> in <Cell>' -ForEach @(
        @{ Id = 'AA0072'; Cell = 'essential.default'; Source = 'override'; Text = 'Info override 0 None level:essential' }
        @{ Id = 'LC0029'; Cell = 'recommended.ci'; Source = 'override'; Text = 'None override 1 Warning level:recommended' }
        @{ Id = 'LC0099'; Cell = 'complete.ci'; Source = 'quarantine'; Text = 'None quarantine Warning default' }
        @{ Id = 'AL0603'; Cell = 'recommended.ci'; Source = 'stage:ci'; Text = 'Info stage:ci' }
        @{ Id = 'AL0200'; Cell = 'essential.default'; Source = 'level:essential'; Text = 'None level:essential' }
        @{ Id = 'AL0001'; Cell = 'strict.vnext'; Source = 'default'; Text = 'Error default' }
    ) {
        Get-CellText (Get-Rule -Model $validModel -Id $Id)['cells'][$Cell] | Should-Be $Text
    }

    It 'records twins for the PTE side under twins appsource, with no fallback and no override index' {
        $model = Get-Model -Root (Copy-Fixture 'twins-appsource')
        $rule = Get-Rule -Model $model -Id 'PTE0003'
        foreach ($cell in $rule['cells'].Values) { Get-CellText $cell | Should-Be 'None twins' }
        Get-CellText (Get-Rule -Model $model -Id 'AS0061')['cells']['essential.default'] | Should-Be 'Error default'
    }

    It 'gives an id no input mentions default cells only (AL0001)' {
        $rule = Get-Rule -Model $validModel -Id 'AL0001'
        foreach ($cell in $rule['cells'].Values) { Get-CellText $cell | Should-Be 'Error default' }
        $rule['justifications'].Count | Should-Be 0
        Should-BeCollection -Actual ([string[]]@($rule.Keys)) -Expected @('id', 'analyzer', 'title', 'docsUrl', 'default', 'enabledByDefault', 'justifications', 'cells')
    }

    It 'sorts the rules by the diagnostic sort key, an id outside the catalog by the same key with unknown true' {
        $model = Get-Model -Root (Copy-Fixture 'unknown-id')
        [string[]]$ids = @($model.Document['rules'] | ForEach-Object { $_['id'] })
        $ids.Count | Should-Be 31
        [string[]]$expected = @($ids | Sort-Object -CaseSensitive { (Get-DiagnosticSortKey -Id $_) + '|' + $_ })
        Should-BeCollection -Actual $ids -Expected $expected
        # LC0999 sorts among the LC ids, after LC0099 and before DC0001, not after the known ids.
        $ids[([array]::IndexOf($ids, 'LC0999') - 1)] | Should-Be 'LC0099'
        $ids[([array]::IndexOf($ids, 'LC0999') + 1)] | Should-Be 'DC0001'
        $model.UnknownIds | Should-BeCollection @('LC0999')
        $rule = Get-Rule -Model $model -Id 'LC0999'
        $rule['unknown'] | Should-BeTrue
        $rule['default'] | Should-BeNull
        $rule['enabledByDefault'] | Should-BeNull
        Get-CellText $rule['cells']['complete.ci'] | Should-Be 'Info level:complete'
        Get-CellText $rule['cells']['essential.default'] | Should-Be 'null default'
        (Get-Rule -Model $model -Id 'LC0099').Contains('unknown') | Should-BeFalse
    }

    It 'computes the fallback of an override cell with Get-EffectiveAction without that entry and writes its index' {
        $root = Copy-Fixture
        # Index 2, more specific than the AA0072 entry at index 0: it wins strict.ci, the entry at index 0 is the fallback.
        Edit-FixtureJson -Path (Join-Path $root 'overrides.json') -Script { $_['rules'] = @($_['rules']) + @{ id = 'AA0072'; action = 'Error'; levels = @('strict'); stages = @('ci') } }
        $inputs = Read-RulebookInputs -RepositoryRoot $root
        $model = Get-Model -Root $root
        $cell = (Get-Rule -Model $model -Id 'AA0072')['cells']['strict.ci']
        Get-CellText $cell | Should-Be 'Error override 2 Info override'
        $others = @($inputs.OverridesById['AA0072'] | Where-Object Index -NE 2)
        $expected = Get-EffectiveAction -Id 'AA0072' -Level 'strict' -Stage 'ci' -Chain $inputs.Chains['strict'] -StageDelta $inputs.StageDeltas['ci'] `
            -Twins $inputs.Twins -TwinsSetting $inputs.TwinsSetting -Overrides $others -Quarantine $inputs.Quarantine['ci'] -Catalog $inputs.Catalog
        '{0} {1}' -f $cell['fallback'], $cell['fallbackSource'] | Should-Be ('{0} {1}' -f $expected.Action, $expected.Source)
        Get-CellText (Get-Rule -Model $model -Id 'AA0072')['cells']['strict.default'] | Should-Be 'Info override 0 Warning level:recommended'
    }

    It 'gives a quarantine cell the level result or the default, with the stage entry on top, as fallback (tiny repository)' {
        $root = New-TinyFixtureRepo -Destination (Get-TestFolder)
        # AL0432: no level file of the tiny matrix mentions it (Warning at its default), stages/ci.json sets Info.
        Write-FixtureText -Path (Join-Path $root 'quarantine.ci.json') -Text '{ "rules": [ { "id": "AL0432" }, { "id": "AS0084" } ] }'
        $model = Get-Model -Root $root
        $rule = Get-Rule -Model $model -Id 'AL0432'
        Get-CellText $rule['cells']['core.ci'] | Should-Be 'None quarantine Info stage:ci'
        Get-CellText $rule['cells']['extended.ci'] | Should-Be 'None quarantine Info stage:ci'
        Get-CellText $rule['cells']['core.default'] | Should-Be 'Warning default'
        # AS0084: the chain mentions it, so the chain wins over the quarantine and the cell has no fallback (D41).
        Get-CellText (Get-Rule -Model $model -Id 'AS0084')['cells']['extended.ci'] | Should-Be 'Warning level:extended'
        @($model.Document['quarantine']['ci'] | ForEach-Object { $_['id'] }) | Should-BeCollection @('AL0432', 'AS0084')
        $model.Document['quarantine']['default'] | Should-BeCollection @()
    }

    It 'keys the justifications by source token and writes them with and without IncludeJustifications' {
        foreach ($model in $validModel, (Get-Model -Root $validRoot -IncludeJustifications)) {
            $rule = Get-Rule -Model $model -Id 'AL0603'
            Should-BeCollection -Actual ([string[]]@($rule['justifications'].Keys)) -Expected @('level:strict', 'stage:ci')
            $rule['justifications']['level:strict'] | Should-Be 'Fixture: a level lowers an id that is enabled by default'
            $rule['justifications']['stage:ci'] | Should-Be 'Implicit conversion is advisory in CI; S-2'
            (Get-Rule -Model $model -Id 'AS0084')['justifications']['level:essential'] | Should-Be 'Needs AppSourceCop.json or marketplace manifest fields; off at Essential'
        }
    }

    It 'writes the override and quarantine justifications only with IncludeJustifications (D36)' {
        $text = ConvertTo-RulebookSiteDataJson -Model $validModel
        $text | Should-NotMatchString 'House style|Backlog DEV-1234|quarantined 2026-10-01'
        Should-BeCollection -Actual ([string[]]@($validModel.Document['overrides'][0].Keys)) -Expected @('id', 'action', 'levels', 'stages')
        $with = Get-Model -Root $validRoot -IncludeJustifications
        $with.Document['overrides'][0]['justification'] | Should-Be 'House style'
        $with.Document['overrides'][1]['justification'] | Should-Be 'Backlog DEV-1234'
        $with.Document['quarantine']['ci'][0]['justification'] | Should-Be 'New in alcops.analyzers 1.4.0-beta.1 (prerelease), quarantined 2026-10-01. Review and adopt.'
        $with.Document['quarantine']['vnext'] | Should-BeCollection @()
    }

    It 'writes issueTemplate, repository and the docsUrl of engine ref <Ref>' -ForEach @(
        @{ Ref = ''; Expected = 'https://github.com/ALCops/rulebook/blob/preview/docs/dashboard.md' }
        @{ Ref = 'main'; Expected = 'https://github.com/ALCops/rulebook/blob/preview/docs/dashboard.md' }
        @{ Ref = 'v1'; Expected = 'https://github.com/ALCops/rulebook/blob/main/docs/dashboard.md' }
        @{ Ref = 'v1.0.0-beta.4'; Expected = 'https://github.com/ALCops/rulebook/blob/v1.0.0-beta.4/docs/dashboard.md' }
    ) {
        $model = Get-Model -Root $validRoot -EngineRef $Ref
        $document = $model.Document
        Should-BeCollection -Actual ([string[]]@($document.Keys)) -Expected @('generatedAt', 'repository', 'baseUrl', 'issueTemplate', 'docsUrl', 'levels', 'stages', 'rules', 'overrides', 'quarantine')
        $document['issueTemplate'] | Should-Be 'rulebook-change.yml'
        $document['repository'] | Should-Be 'contoso/rulebook'
        $document['baseUrl'] | Should-Be $baseUrl
        $document['docsUrl'] | Should-Be $Expected
    }

    It 'leaves repository out when it is not known' {
        (Get-Model -Root $validRoot -Repository '').Document.Contains('repository') | Should-BeFalse
    }

    It 'embeds the level and stage summaries in settings order' {
        $catalog = Read-CatalogFile -Path (Join-Path $validRoot 'catalog' 'diagnostics.json')
        $levels = @($validModel.Document['levels'])
        @($levels | ForEach-Object { $_['slug'] }) | Should-BeCollection @('essential', 'recommended', 'strict', 'complete')
        Should-BeCollection -Actual ([string[]]@($levels[1].Keys)) -Expected @('name', 'slug', 'basedOn', 'description', 'file', 'chain', 'basedOnName', 'basedOnPublished', 'entryCount', 'loweredCount', 'overrideCount', 'counts', 'entries')
        foreach ($level in $levels) {
            $summary = Get-RulebookLevelSummary -Inputs $validInputs -Catalog $catalog -Level $level['slug']
            $level['entryCount'] | Should-Be $summary.EntryCount
            @($level['entries'] | ForEach-Object { '{0} {1} {2}' -f $_['id'], $_['from'], $_['to'] }) | Should-BeCollection @($summary.Rows | ForEach-Object { '{0} {1} {2}' -f $_.Id, $_.From, $_.To })
            @($level['counts'] | ForEach-Object { '{0} {1} {2} {3} {4} {5} {6}' -f $_['stage'], $_['error'], $_['warning'], $_['info'], $_['hidden'], $_['none'], $_['listed'] }) |
                Should-BeCollection @($summary.Counts | ForEach-Object { '{0} {1} {2} {3} {4} {5} {6}' -f $_.Stage, $_.Error, $_.Warning, $_.Info, $_.Hidden, $_.None, $_.Listed })
        }
        $stages = @($validModel.Document['stages'])
        @($stages | ForEach-Object { $_['slug'] }) | Should-BeCollection @('default', 'ci', 'vnext')
        Should-BeCollection -Actual ([string[]]@($stages[0].Keys)) -Expected @('name', 'slug', 'description', 'entryCount', 'quarantineCount', 'overrideCount', 'counts', 'entries')
        Should-BeCollection -Actual ([string[]]@($stages[1].Keys)) -Expected @('name', 'slug', 'description', 'file', 'entryCount', 'quarantineCount', 'overrideCount', 'counts', 'entries')
        $stages[1]['file'] | Should-Be 'stages/ci.json'
        @($stages[1]['entries'] | ForEach-Object { '{0} {1} [{2}]' -f $_['id'], $_['action'], ($_['noEffect'] -join ',') }) | Should-BeCollection @('AL0432 Info [essential]', 'AL0603 Info []', 'AL1026 Info []')
    }
}

Describe 'ConvertTo-RulebookSiteDataJson' {
    BeforeAll {
        $script:validRoot = Copy-Fixture
        $script:validText = ConvertTo-RulebookSiteDataJson -Model (Get-Model -Root $validRoot)
    }

    It 'is byte-stable: the same inputs give the same text, apart from generatedAt' {
        ConvertTo-RulebookSiteDataJson -Model (Get-Model -Root $validRoot) | Should-Be $validText
        $inputs = Read-RulebookInputs -RepositoryRoot $validRoot
        $catalog = Read-CatalogFile -Path (Join-Path $validRoot 'catalog' 'diagnostics.json')
        $later = ConvertTo-RulebookSiteDataJson -Model (Get-RulebookSiteModel -Inputs $inputs -Catalog $catalog -BaseUrl $baseUrl -Repository 'contoso/rulebook' -GeneratedAt ([datetime]'2026-10-18T09:30:00Z'))
        $later | Should-NotBe $validText
        $later.Replace('"generatedAt": "2026-10-18T09:30:00Z"', '"generatedAt": "2026-10-17T00:00:00Z"') | Should-Be $validText
    }

    It 'writes LF, no BOM, two-space indent, generatedAt first as a string and flat objects on one line' {
        $validText | Should-MatchString $generatedAtLine
        $validText | Should-MatchString '\A\{\n  "generatedAt": "2026-10-17T00:00:00Z",\n  "repository": "contoso/rulebook",\n  "baseUrl": "https://contoso\.github\.io/rulebook",\n  "issueTemplate": "rulebook-change\.yml",\n'
        $validText.Contains("`r") | Should-BeFalse
        $validText.EndsWith("}`n") | Should-BeTrue
        $validText.EndsWith("`n`n") | Should-BeFalse
        [int][char]$validText[0] | Should-Be ([int][char]'{')
        $validText | Should-MatchString '(?m)^        "essential\.default": \{ "action": "Error", "source": "default" \},$'
        $validText | Should-MatchString '(?m)^        "complete\.vnext": \{ "action": "Info", "source": "override", "override": 0, "fallback": "Warning", "fallbackSource": "level:recommended" \}$'
        $validText | Should-MatchString '(?m)^        \{ "stage": "default", "error": 7, "warning": 9, "info": 2, "hidden": 1, "none": 11, "listed": 10 \},$'
        $validText | Should-MatchString '(?m)^    \{ "id": "AA0072", "action": "Info", "levels": \["\*"\], "stages": \["\*"\] \},$'
        $validText | Should-MatchString '(?m)^      "chain": \["essential", "recommended"\],$'
        $validText | Should-MatchString '(?m)^      "justifications": \{\},$'
        $validText | Should-MatchString '(?m)^    "vnext": \[\]$'
        foreach ($line in $validText.TrimEnd("`n").Split("`n")) { $line | Should-MatchString '^(  )*[^ ]' }
        Test-Json -Json $validText | Should-BeTrue
    }

    It 'escapes quotes and backslashes and writes null for the default of an unknown id' {
        $root = Copy-Fixture 'unknown-id'
        $complete = Join-Path $root 'base' 'complete.ruleset.json'
        Write-FixtureText -Path $complete -Text ((Read-Text $complete).Replace('Fixture: an id the catalog does not know', 'Say \"no\" to C:\\temp'))
        $text = ConvertTo-RulebookSiteDataJson -Model (Get-Model -Root $root)
        $text | Should-MatchString ([regex]::Escape('"level:complete": "Say \"no\" to C:\\temp"'))
        $text | Should-MatchString '(?m)^      "default": null,\n      "enabledByDefault": null,\n      "unknown": true,$'
        $parsed = $text | ConvertFrom-Json -AsHashtable
        @($parsed['rules'] | Where-Object { $_['id'] -ceq 'LC0999' })[0]['justifications']['level:complete'] | Should-Be 'Say "no" to C:\temp'
    }
}

Describe 'Export-RulebookSiteData' {
    It 'writes site/data/rulebook.json with its folder and returns what it wrote' {
        $root = Copy-Fixture
        $result = Export-RulebookSiteData -RepositoryRoot $root -BaseUrl $baseUrl -Repository 'contoso/rulebook' -GeneratedAt '2026-10-17T00:00:00Z'
        $path = Join-Path $root 'site' 'data' 'rulebook.json'
        $result.Path | Should-Be $path
        $bytes = [System.IO.File]::ReadAllBytes($path)
        $result.Bytes | Should-Be $bytes.Length
        $bytes[0] | Should-Be ([byte][char]'{')
        '{0} {1} {2} {3} {4}' -f $result.RuleCount, $result.LevelCount, $result.StageCount, $result.IncludeJustifications, $result.GeneratedAt | Should-Be '30 4 3 False 2026-10-17T00:00:00Z'
        $result.GeneratedAt -is [string] | Should-BeTrue
        Read-Text $path | Should-MatchString $generatedAtLine
    }

    It 'includes the override and quarantine justifications only when site.includeJustifications is the boolean true (<Value>)' -ForEach @(
        @{ Value = 'true'; Setting = $true; Included = $true }
        @{ Value = 'the string true'; Setting = 'true'; Included = $false }
        @{ Value = 'absent'; Setting = $null; Included = $false }
    ) {
        $root = Copy-Fixture
        Edit-FixtureJson -Path (Join-Path $root '.github' 'Rulebook-Settings.json') -Script {
            if ($null -eq $Setting) { $_['site'].Remove('includeJustifications') } else { $_['site']['includeJustifications'] = $Setting }
        }
        $out = Join-Path (Get-TestFolder) 'rulebook.json'
        $result = Export-RulebookSiteData -RepositoryRoot $root -BaseUrl $baseUrl -OutFile $out
        $result.IncludeJustifications | Should-Be $Included
        (Read-Text $out).Contains('"justification": "House style"') | Should-Be $Included
    }

    It 'throws when the settings are missing' {
        $root = Copy-Fixture
        Remove-Item -LiteralPath (Join-Path $root '.github' 'Rulebook-Settings.json')
        { Export-RulebookSiteData -RepositoryRoot $root -BaseUrl $baseUrl } | Should-Throw -ExceptionMessage 'Settings missing: .github/Rulebook-Settings.json*'
    }

    It 'writes nothing under -WhatIf' {
        $root = Copy-Fixture
        $result = Export-RulebookSiteData -RepositoryRoot $root -BaseUrl $baseUrl -WhatIf
        $result.RuleCount | Should-Be 30
        Test-Path -LiteralPath (Join-Path $root 'site') | Should-BeFalse
    }

    It 'gives tests/fixtures/site-data/rulebook.json byte for byte (regenerate it with the command in its README)' {
        $out = Join-Path (Get-TestFolder) 'rulebook.json'
        $null = Export-RulebookSiteData -RepositoryRoot (Join-Path $PSScriptRoot 'fixtures' 'repos' 'valid-minimal') -BaseUrl $baseUrl -Repository 'contoso/rulebook' `
            -GeneratedAt '2026-10-17T00:00:00Z' -OutFile $out
        $expected = [System.IO.File]::ReadAllBytes($siteFixture)
        $actual = [System.IO.File]::ReadAllBytes($out)
        [System.Linq.Enumerable]::SequenceEqual($expected, $actual) | Should-BeTrue -Because 'the committed export must equal the export of valid-minimal; regenerate it with the command in tests/fixtures/site-data/README.md'
        Read-Text $siteFixture | Should-MatchString '\A\{\n  "generatedAt": "2026-10-17T00:00:00Z",\n'
    }
}
