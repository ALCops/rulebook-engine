# Site suite for WP14 (#16, #62, #51): modules/Rulebook.Site (the site data model, its writer, the export of
# site/data/rulebook.json, the Hugo install with mocks and the site build with the stand-in tests/Helpers/HugoStub.ps1;
# one build of template/site runs the real Hugo and is skipped when hugo is not on PATH). Cases run on the repository fixtures under tests/fixtures/repos/ (valid-minimal and the
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

    It 'writes issueTemplate, repository, the docsUrl, the setup URLs and the docs map of engine ref <Ref>' -ForEach @(
        @{ Ref = ''; Engine = 'main'; Template = 'preview' }
        @{ Ref = 'main'; Engine = 'main'; Template = 'preview' }
        @{ Ref = 'v1'; Engine = 'v1'; Template = 'main' }
        @{ Ref = 'v1.0.0-beta.4'; Engine = 'v1.0.0-beta.4'; Template = 'v1.0.0-beta.4' }
    ) {
        $model = Get-Model -Root $validRoot -EngineRef $Ref
        $document = $model.Document
        Should-BeCollection -Actual ([string[]]@($document.Keys)) -Expected @('generatedAt', 'repository', 'baseUrl', 'issueTemplate', 'docsUrl', 'initScriptUrl', 'engineRef', 'alProjectDocsUrl', 'docs', 'levels', 'stages', 'rules', 'overrides', 'quarantine')
        $document['issueTemplate'] | Should-Be 'rulebook-change.yml'
        $document['repository'] | Should-Be 'contoso/rulebook'
        $document['baseUrl'] | Should-Be $baseUrl
        $document['docsUrl'] | Should-Be "https://github.com/ALCops/rulebook/blob/$Template/docs/dashboard.md"
        # The setup page: the same init script, ref and user page as the plain index page.
        $document['initScriptUrl'] | Should-Be "https://raw.githubusercontent.com/ALCops/rulebook-engine/$Engine/scripts/Get-RulebookSkeletons.ps1"
        $document['engineRef'] | Should-Be $Engine
        $document['alProjectDocsUrl'] | Should-Be "https://github.com/ALCops/rulebook/blob/$Template/docs/al-project.md"
        # The docs map (D58): home, then one user page per concept on the same template ref; the two older keys equal
        # their entries.
        $docs = $document['docs']
        Should-BeCollection -Actual ([string[]]@($docs.Keys)) -Expected @('home', 'dashboard', 'levels', 'overrides', 'quarantine', 'twins', 'changingARule', 'alProject')
        $docs['home'] | Should-Be 'https://alcops.dev'
        $pages = @{ dashboard = 'dashboard'; levels = 'levels'; overrides = 'overrides'; quarantine = 'quarantine'; twins = 'pte-or-appsource'; changingARule = 'changing-a-rule'; alProject = 'al-project' }
        foreach ($key in $pages.Keys) { $docs[$key] | Should-Be "https://github.com/ALCops/rulebook/blob/$Template/docs/$($pages[$key]).md" }
        $docs['dashboard'] | Should-Be $document['docsUrl']
        $docs['alProject'] | Should-Be $document['alProjectDocsUrl']
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

    It 'reads a GeneratedAt of kind Unspecified as UTC, like the same value with Z' {
        $inputs = Read-RulebookInputs -RepositoryRoot $validRoot
        $catalog = Read-CatalogFile -Path (Join-Path $validRoot 'catalog' 'diagnostics.json')
        $unspecified = [datetime]::new(2026, 10, 17, 0, 0, 0, [System.DateTimeKind]::Unspecified)
        $model = Get-RulebookSiteModel -Inputs $inputs -Catalog $catalog -BaseUrl $baseUrl -GeneratedAt $unspecified
        $model.Document['generatedAt'] | Should-Be '2026-10-17T00:00:00Z'
        $zulu = Get-RulebookSiteModel -Inputs $inputs -Catalog $catalog -BaseUrl $baseUrl -GeneratedAt ([datetime]'2026-10-17T00:00:00Z')
        $zulu.Document['generatedAt'] | Should-Be $model.Document['generatedAt']
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
        # The docs map is one link per line although every value is a string.
        $validText | Should-MatchString '(?m)^  "docs": \{\n    "home": "https://alcops\.dev",\n    "dashboard": "[^"]+",\n'
        foreach ($line in $validText.TrimEnd("`n").Split("`n")) { $line | Should-MatchString '^(  )*[^ ]' }
        Test-Json -Json $validText | Should-BeTrue
    }

    It 'writes the quarantine object one stage per line also when every list is empty, in file order otherwise' {
        $root = Copy-Fixture
        foreach ($stage in 'default', 'ci') { Write-FixtureText -Path (Join-Path $root "quarantine.$stage.json") -Text '{ "rules": [] }' }
        $text = ConvertTo-RulebookSiteDataJson -Model (Get-Model -Root $root)
        $text | Should-MatchString '(?m)^  "quarantine": \{\n    "default": \[\],\n    "ci": \[\],\n    "vnext": \[\]\n  \}\n\}\n\z'
        Write-FixtureText -Path (Join-Path $root 'quarantine.ci.json') -Text '{ "rules": [ { "id": "LC0099" }, { "id": "AL0001" } ] }'
        @((Get-Model -Root $root).Document['quarantine']['ci'] | ForEach-Object { $_['id'] }) | Should-BeCollection @('LC0099', 'AL0001')
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

    It 'builds the same model as Read-RulebookSiteModel, which names the data path' {
        $root = Copy-Fixture
        $model = Read-RulebookSiteModel -RepositoryRoot $root -BaseUrl $baseUrl -Repository 'contoso/rulebook' -GeneratedAt '2026-10-17T00:00:00Z'
        $model.IncludeJustifications | Should-BeFalse
        $out = Join-Path (Get-TestFolder) 'rulebook.json'
        $null = Export-RulebookSiteData -RepositoryRoot $root -BaseUrl $baseUrl -Repository 'contoso/rulebook' -GeneratedAt '2026-10-17T00:00:00Z' -OutFile $out
        (ConvertTo-RulebookSiteDataJson -Model $model) | Should-Be ([System.IO.File]::ReadAllText($out))
        Get-RulebookSiteDataPath | Should-Be 'site/data/rulebook.json'
        $inputs = Read-RulebookInputs -RepositoryRoot $root
        Remove-Item -LiteralPath (Join-Path $root 'catalog' 'diagnostics.json')
        { Read-RulebookSiteModel -RepositoryRoot $root -BaseUrl $baseUrl -Inputs $inputs } | Should-Throw -ExceptionMessage 'catalog/diagnostics.json is missing*'
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

Describe 'Install-Hugo' {
    BeforeAll {
        $script:pin = '0.167.0'
        $script:debBytes = [System.Text.Encoding]::ASCII.GetBytes('not a real package')
        $script:debHash = [System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::HashData($debBytes)).Replace('-', '').ToLowerInvariant()
    }

    BeforeEach {
        $script:versions = [System.Collections.Generic.Queue[object]]::new()
        Mock Get-HugoVersionText -ModuleName Rulebook.Site { $script:versions.Dequeue() }
        Mock Get-Command -ModuleName Rulebook.Site -ParameterFilter { $Name -eq 'hugo' } { [pscustomobject]@{ Source = '/usr/local/bin/hugo' } }
        Mock Test-HugoInstallPlatform -ModuleName Rulebook.Site { $true }
        Mock Invoke-WebRequest -ModuleName Rulebook.Site { [System.IO.File]::WriteAllBytes($OutFile, $script:debBytes) }
        Mock Invoke-HugoInstallCommand -ModuleName Rulebook.Site { [pscustomobject]@{ ExitCode = 0; Output = @('Setting up hugo') } }
    }

    It 'does nothing when hugo version reports the pinned extended version' {
        $versions.Enqueue('hugo v0.167.0-3fff6fb5+extended linux/amd64 BuildDate=2026-09-28T14:50:38Z')
        $result = Install-Hugo -Version $pin -Sha256 $debHash -DownloadRoot (Get-TestFolder)
        $result.Installed | Should-BeFalse
        $result.Deb | Should-BeNull
        $result.Path | Should-Be '/usr/local/bin/hugo'
        Should-Invoke Invoke-WebRequest -ModuleName Rulebook.Site -Times 0 -Exactly
        Should-Invoke Invoke-HugoInstallCommand -ModuleName Rulebook.Site -Times 0 -Exactly
    }

    It 'downloads the release package, checks its sha256, installs it and checks the version' {
        $versions.Enqueue('hugo v0.165.0+extended linux/amd64')
        $versions.Enqueue('hugo v0.167.0-3fff6fb5+extended linux/amd64')
        $folder = Get-TestFolder
        $result = Install-Hugo -Version $pin -Sha256 $debHash.ToUpperInvariant() -DownloadRoot $folder
        $result.Installed | Should-BeTrue
        $result.Version | Should-BeLikeString 'hugo v0.167.0*extended*'
        $result.Deb | Should-Be (Join-Path $folder 'hugo_extended_0.167.0_linux-amd64.deb')
        Should-Invoke Invoke-WebRequest -ModuleName Rulebook.Site -Times 1 -Exactly -ParameterFilter { $Uri -eq 'https://github.com/gohugoio/hugo/releases/download/v0.167.0/hugo_extended_0.167.0_linux-amd64.deb' }
        Should-Invoke Invoke-HugoInstallCommand -ModuleName Rulebook.Site -Times 1 -Exactly -ParameterFilter { $Deb -eq $result.Deb }
    }

    It 'refuses a package with another sha256 and deletes it' {
        $versions.Enqueue($null)
        $folder = Get-TestFolder
        $wrong = '0' * 64
        { Install-Hugo -Version $pin -Sha256 $wrong -DownloadRoot $folder } | Should-Throw -ExceptionMessage "hugo_extended_0.167.0_linux-amd64.deb has SHA256 $debHash, expected $wrong; the file was deleted*"
        Test-Path -LiteralPath (Join-Path $folder 'hugo_extended_0.167.0_linux-amd64.deb') | Should-BeFalse
        Should-Invoke Invoke-HugoInstallCommand -ModuleName Rulebook.Site -Times 0 -Exactly
    }

    It 'throws when dpkg fails or the installed hugo is not the pin' {
        $versions.Enqueue($null)
        Mock Invoke-HugoInstallCommand -ModuleName Rulebook.Site { [pscustomobject]@{ ExitCode = 1; Output = @('dpkg: error') } }
        { Install-Hugo -Version $pin -Sha256 $debHash -DownloadRoot (Get-TestFolder) } | Should-Throw -ExceptionMessage '*dpkg -i hugo_extended_0.167.0_linux-amd64.deb failed with exit code 1: dpkg: error'
        Mock Invoke-HugoInstallCommand -ModuleName Rulebook.Site { [pscustomobject]@{ ExitCode = 0; Output = @() } }
        $versions.Enqueue($null)
        $versions.Enqueue('hugo v0.167.0 linux/amd64')
        { Install-Hugo -Version $pin -Sha256 $debHash -DownloadRoot (Get-TestFolder) } | Should-Throw -ExceptionMessage "*'hugo version' reports 'hugo v0.167.0 linux/amd64', not v0.167.0 extended."
    }

    It 'accepts an extended Hugo at or above the floor off Linux without downloading' {
        Mock Test-HugoInstallPlatform -ModuleName Rulebook.Site { $false }
        $versions.Enqueue('hugo v0.165.0-76a5e188+extended windows/amd64 BuildDate=2026-08-12T14:26:28Z')
        $result = Install-Hugo -Version $pin -Sha256 $debHash -DownloadRoot (Get-TestFolder)
        $result.Installed | Should-BeFalse
        $result.Version | Should-BeLikeString 'hugo v0.165.0*'
        Should-Invoke Invoke-WebRequest -ModuleName Rulebook.Site -Times 0 -Exactly
    }

    It 'throws off Linux for <Name>, naming the hugoPath input' -ForEach @(
        @{ Name = 'a Hugo below the floor'; Line = 'hugo v0.150.0+extended windows/amd64' }
        @{ Name = 'a Hugo that is not extended'; Line = 'hugo v0.167.0 windows/amd64' }
        @{ Name = 'no Hugo'; Line = $null }
    ) {
        Mock Test-HugoInstallPlatform -ModuleName Rulebook.Site { $false }
        $versions.Enqueue($Line)
        { Install-Hugo -Version $pin -Sha256 $debHash -DownloadRoot (Get-TestFolder) } | Should-Throw -ExceptionMessage '*runs on Linux only, and no extended Hugo 0.156.0 or later is installed (found: *)*hugoPath input.'
        Should-Invoke Invoke-WebRequest -ModuleName Rulebook.Site -Times 0 -Exactly
    }

    It 'replaces <Name> with the pin on Linux' -ForEach @(
        @{ Name = 'a Hugo below the floor'; Line = 'hugo v0.150.0+extended linux/amd64' }
        @{ Name = 'a newer Hugo'; Line = 'hugo v0.170.0+extended linux/amd64' }
    ) {
        $versions.Enqueue($Line)
        $versions.Enqueue('hugo v0.167.0-3fff6fb5+extended linux/amd64')
        (Install-Hugo -Version $pin -Sha256 $debHash -DownloadRoot (Get-TestFolder)).Installed | Should-BeTrue
        Should-Invoke Invoke-HugoInstallCommand -ModuleName Rulebook.Site -Times 1 -Exactly
    }

    It 'refuses a version or a hash of the wrong shape' {
        { Install-Hugo -Version 'latest' -Sha256 $debHash } | Should-Throw -ExceptionType ([System.Management.Automation.ParameterBindingException])
        { Install-Hugo -Version $pin -Sha256 'abc' } | Should-Throw -ExceptionType ([System.Management.Automation.ParameterBindingException])
    }
}

Describe 'Build-RulebookSite' {
    BeforeAll {
        $script:stub = Join-Path $PSScriptRoot 'Helpers' 'HugoStub.ps1'

        function New-SiteCopy {
            # template/site with the committed site data fixture as data/rulebook.json.
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helper; writes only to TestDrive')]
            param()
            $site = Join-Path (Get-TestFolder) 'site'
            Copy-FixtureTree -Source (Join-Path $repoRoot 'template' 'site') -Destination $site
            if (Test-Path -LiteralPath (Join-Path $site 'data')) { Remove-Item -LiteralPath (Join-Path $site 'data') -Recurse -Force }
            [void](New-Item -ItemType Directory -Path (Join-Path $site 'data'))
            Copy-Item -LiteralPath $siteFixture -Destination (Join-Path $site 'data' 'rulebook.json')
            return $site
        }

        function New-Staging {
            # A staging folder that already holds what New-RulebookPublishStage writes before the build.
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helper; writes only to TestDrive')]
            param()
            $staging = Get-TestFolder
            [void](New-Item -ItemType Directory -Path (Join-Path $staging 'rulesets'), (Join-Path $staging 'catalog') -Force)
            Set-Content -LiteralPath (Join-Path $staging 'rulesets' 'strict.ruleset.json') -Value '{}' -NoNewline
            Set-Content -LiteralPath (Join-Path $staging 'catalog' 'diagnostics.json') -Value '{}' -NoNewline
            Set-Content -LiteralPath (Join-Path $staging 'index.html') -Value 'plain' -NoNewline
            return $staging
        }
    }

    AfterEach {
        $env:HUGO_STUB_LOG = $null
        $env:HUGO_STUB_EXIT = $null
        $env:HUGO_STUB_NOMARKER = $null
    }

    It 'runs Hugo with the source, the destination, the base URL with a slash, --quiet and --noBuildLock, and no clean' {
        $site = New-SiteCopy
        $staging = New-Staging
        $env:HUGO_STUB_LOG = Join-Path (Get-TestFolder) 'args.log'
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $env:HUGO_STUB_LOG))
        $null = Build-RulebookSite -SitePath $site -BaseUrl $baseUrl -Destination $staging -HugoPath $stub
        $arguments = @((Get-Content -LiteralPath $env:HUGO_STUB_LOG -Raw).TrimEnd("`n").Split("`t"))
        $arguments | Should-BeCollection @('--source', $site, '--destination', $staging, '--baseURL', "$baseUrl/", '--quiet', '--noBuildLock')
    }

    It 'keeps the staged files, replaces index.html and lists the pages and assets' {
        $site = New-SiteCopy
        $staging = New-Staging
        $result = Build-RulebookSite -SitePath $site -BaseUrl $baseUrl -Destination $staging -HugoPath $stub
        Get-Content -LiteralPath (Join-Path $staging 'rulesets' 'strict.ruleset.json') -Raw | Should-Be '{}'
        Get-Content -LiteralPath (Join-Path $staging 'catalog' 'diagnostics.json') -Raw | Should-Be '{}'
        Get-Content -LiteralPath (Join-Path $staging 'index.html') -Raw | Should-MatchString 'data-rulebook-matrix="default"'
        $result.MarkerPresent | Should-BeTrue
        $result.PageCount | Should-Be 39
        $result.Pages[0] | Should-Be 'index.html'
        foreach ($page in 'stages/ci/index.html', 'levels/strict/index.html', 'rules/lc0089i/index.html') { $result.Pages -ccontains $page | Should-BeTrue }
        $result.Assets | Should-BeCollection @('css/site.css', 'js/cart-core.mjs', 'js/cart.mjs', 'js/matrix.js', 'js/shell.js')
        $result.Output | Should-ContainCollection @('Start building sites (stub)')
    }

    It 'reports an index.html without the matrix marker' {
        $env:HUGO_STUB_NOMARKER = '1'
        (Build-RulebookSite -SitePath (New-SiteCopy) -BaseUrl $baseUrl -Destination (New-Staging) -HugoPath $stub).MarkerPresent | Should-BeFalse
    }

    It 'throws with the exit code and the last 20 lines of the output when Hugo fails' {
        $env:HUGO_STUB_EXIT = '2'
        $site = New-SiteCopy
        $message = try { Build-RulebookSite -SitePath $site -BaseUrl $baseUrl -Destination (New-Staging) -HugoPath $stub; '' } catch { $_.Exception.Message }
        $lines = $message.Split("`n")
        $lines[0] | Should-Be "Hugo failed with exit code 2 building $site"
        $lines.Count | Should-Be 21
        $lines[1] | Should-Be 'stub line 6'
        $lines[-1] | Should-Be 'stub line 25'
    }

    It 'refuses a site without <File>' -ForEach @(@{ File = 'hugo.yaml' }, @{ File = 'data/rulebook.json' }) {
        $site = New-SiteCopy
        Remove-Item -LiteralPath (Join-Path $site $File)
        { Build-RulebookSite -SitePath $site -BaseUrl $baseUrl -Destination (New-Staging) -HugoPath $stub } | Should-Throw -ExceptionMessage "The site has no $File in *"
    }

    It 'throws when the Hugo command does not exist' {
        { Build-RulebookSite -SitePath (New-SiteCopy) -BaseUrl $baseUrl -Destination (New-Staging) -HugoPath (Join-Path $TestDrive 'no-hugo.exe') } | Should-Throw -ExceptionMessage "Hugo was not found: '*no-hugo.exe' is not a command or a file"
    }

    It 'builds the shipped site with the real Hugo: every page, the cells and no list page' -Skip:($null -eq (Get-Command -Name 'hugo' -ErrorAction SilentlyContinue)) {
        $site = New-SiteCopy
        $staging = New-Staging
        $result = Build-RulebookSite -SitePath $site -BaseUrl $baseUrl -Destination $staging
        $result.MarkerPresent | Should-BeTrue
        # 30 rules, 3 stages, 4 levels, the setup page and the home page; no list page for rules/, levels/ or stages/
        # and no 404 page.
        $result.PageCount | Should-Be 39
        foreach ($page in 'rules/index.html', 'levels/index.html', 'stages/index.html', '404.html', 'sitemap.xml', 'index.xml') { Test-Path -LiteralPath (Join-Path $staging $page) | Should-BeFalse }
        Test-Path -LiteralPath (Join-Path $site '.hugo_build.lock') | Should-BeFalse
        $result.Assets | Should-BeCollection @('css/site.css', 'js/cart-core.mjs', 'js/cart.mjs', 'js/matrix.js', 'js/shell.js')
        Get-Content -LiteralPath (Join-Path $staging 'rulesets' 'strict.ruleset.json') -Raw | Should-Be '{}'
        $index = Get-Content -LiteralPath (Join-Path $staging 'index.html') -Raw
        $ci = Get-Content -LiteralPath (Join-Path $staging 'stages' 'ci' 'index.html') -Raw
        $index | Should-MatchString '<section class="matrix-root" data-rulebook-matrix="default">'
        # The cart's values sit on the body of every page, the level pages included; no generator meta tag.
        foreach ($page in 'index.html', 'levels/strict/index.html', 'rules/lc0029/index.html') {
            Get-Content -LiteralPath (Join-Path $staging $page) -Raw | Should-MatchString ([regex]::Escape('<body data-repository="contoso/rulebook" data-issue-template="rulebook-change.yml" data-rulebook-json="/rulebook/rulebook.json">'))
        }
        $index | Should-NotMatchString 'name="generator"'
        # A JSON number compares as an int: one override reads in the singular, two in the plural.
        Get-Content -LiteralPath (Join-Path $staging 'levels' 'essential' 'index.html') -Raw | Should-MatchString '<dd>1 override decides a cell of this level</dd>'
        $ci | Should-MatchString '<dd>2 overrides decide a cell of this stage</dd>'
        # Without JavaScript the filters stay hidden: the stylesheet lets the hidden attribute win.
        $index | Should-MatchString '<form class="filters" role="search" hidden>'
        Get-Content -LiteralPath (Join-Path $staging 'css' 'site.css') -Raw | Should-MatchString '(?m)^\[hidden\] \{ display: none !important; \}$'
        ([regex]::Matches($index, '<tr data-id=')).Count | Should-Be 30
        # The override cell of LC0029 on recommended.ci, on the stage page and on the rule page, with the real id.
        # The action sits in a chip (D59); a grid is one Tab stop (#113), so only its first cell has tabindex 0.
        $cell = '<td class="a-none" data-id="LC0029" data-level="recommended" data-stage="ci" data-action="None" data-source="override" data-fallback="Warning" data-fallback-source="level:recommended" data-override="1" tabindex="-1"><span class="chip">None</span>'
        Get-Content -LiteralPath (Join-Path $staging 'stages' 'ci' 'index.html') -Raw | Should-MatchString ([regex]::Escape($cell))
        Get-Content -LiteralPath (Join-Path $staging 'rules' 'lc0029' 'index.html') -Raw | Should-MatchString ([regex]::Escape($cell))
        # A quarantine cell has its fallback and no override index; the stage page lists it with a Release button.
        $ci | Should-MatchString ([regex]::Escape('data-id="LC0099" data-level="strict" data-stage="ci" data-action="None" data-source="quarantine" data-fallback="Warning" data-fallback-source="default" tabindex="-1"><span class="chip">None</span><span class="mark mark-quarantine"'))
        $ci | Should-MatchString ([regex]::Escape('<button type="button" data-release data-id="LC0099" data-stage="ci" hidden>Release</button>'))
        $ci | Should-MatchString '<h2 id="stage-summary">What the stage CI changes</h2>'
        # The first stage link points at / on every page; the stage page marks its own link (the landing page of #139
        # moves it to stages/<first>/).
        $ci | Should-MatchString ([regex]::Escape('<a href="/rulebook/" data-stage-link="default">default</a>'))
        $ci | Should-MatchString ([regex]::Escape('<a href="/rulebook/stages/ci/" data-stage-link="ci" aria-current="page">CI</a>'))
        $index | Should-MatchString ([regex]::Escape('<a href="/rulebook/" data-stage-link="default" aria-current="page">default</a>'))
        Get-Content -LiteralPath (Join-Path $staging 'levels' 'recommended' 'index.html') -Raw | Should-MatchString ([regex]::Escape('<a href="/rulebook/levels/essential/">Essential</a>'))
        # setup/: the "Set up an AL project" section of the plain index, from the data file, with the al-project anchor.
        $setup = Get-Content -LiteralPath (Join-Path $staging 'setup' 'index.html') -Raw
        $setup | Should-MatchString '<h1 id="al-project">Set up an AL project</h1>'
        $setup | Should-MatchString ([regex]::Escape('Invoke-WebRequest https://raw.githubusercontent.com/ALCops/rulebook-engine/main/scripts/Get-RulebookSkeletons.ps1 -OutFile Get-RulebookSkeletons.ps1'))
        $setup | Should-MatchString ([regex]::Escape('./Get-RulebookSkeletons.ps1 -BaseUrl https://contoso.github.io/rulebook -Level essential -Ref main'))
        $setup | Should-MatchString ([regex]::Escape('<a href="https://github.com/ALCops/rulebook/blob/preview/docs/al-project.md">docs/al-project.md</a>'))
        $setup | Should-MatchString ([regex]::Escape('<a href="https://contoso.github.io/rulebook/rulesets/strict.ruleset.json"><code>https://contoso.github.io/rulebook/rulesets/strict.ruleset.json</code></a></td><td class="count">9</td><td><a href="https://contoso.github.io/rulebook/skeletons/strict.default.ruleset.json"'))
        $setup | Should-MatchString ([regex]::Escape('href="https://contoso.github.io/rulebook/rulesets/strict.ci.ruleset.json"'))
        $index | Should-MatchString ([regex]::Escape('<a class="nav-setup" href="/rulebook/setup/">Set up</a>'))
        $index | Should-MatchString ([regex]::Escape('<a href="/rulebook/setup/#al-project">Set up an AL project</a>'))
        # The two URLs the site shows come from the data file.
        $index | Should-MatchString ([regex]::Escape('href="https://github.com/ALCops/rulebook/blob/preview/docs/dashboard.md"'))
        $index | Should-MatchString ([regex]::Escape('href="https://github.com/contoso/rulebook/issues/new?template=rulebook-change.yml"'))
        # The shell (#138): the favicons, the head tags from the content adapter, the header, the lead under every
        # title, the main kind and the footer with the facts and the two links of the data file.
        foreach ($icon in 'favicon.svg', 'favicon.png') { Test-Path -LiteralPath (Join-Path $staging $icon) -PathType Leaf | Should-BeTrue }
        $level = Get-Content -LiteralPath (Join-Path $staging 'levels' 'strict' 'index.html') -Raw
        $rule = Get-Content -LiteralPath (Join-Path $staging 'rules' 'lc0029' 'index.html') -Raw
        foreach ($text in $index, $ci, $level, $rule, $setup) {
            $text | Should-MatchString '<script>document\.documentElement\.classList\.add\(''has-js''\);try\{var t=localStorage\.getItem\(''rulebook-theme''\)'
            foreach ($tag in 'name="description"', 'property="og:title"', 'property="og:description"', 'property="og:type" content="website"', 'property="og:url"', 'property="og:site_name" content="Rulebook \| contoso"', 'rel="icon" href="/rulebook/favicon\.png"', 'rel="icon" href="/rulebook/favicon\.svg"') { $text | Should-MatchString "<(meta|link) $tag" }
            $text | Should-MatchString '<a class="brand" href="/rulebook/"><svg class="logo"'
            $text | Should-MatchString '<span class="brand-name">Rulebook</span><span class="brand-org">contoso</span>'
            $text | Should-MatchString '<span class="nav-label" id="nav-stage">Stage</span><ul class="stage-switcher" aria-labelledby="nav-stage">'
            $text | Should-MatchString '<ul class="nav-levels" aria-labelledby="nav-level">'
            $text | Should-MatchString '<button type="button" class="theme-toggle" aria-pressed="false"'
            # The toggle, the cart and the menu button sit outside the navigation, so they stay in view when it folds.
            $text | Should-MatchString '</nav>\s*<div class="header-tools">\s*<button type="button" class="theme-toggle"[^\n]*\n\s*<button type="button" class="cart-toggle"[^\n]*\n\s*<button type="button" class="menu-toggle" aria-controls="site-nav" aria-expanded="false">'
            $text | Should-MatchString ([regex]::Escape('<button type="button" class="cart-toggle" aria-controls="cart" aria-expanded="false" hidden>Cart <span class="cart-count">0</span></button>'))
            $text | Should-MatchString '</h1>\n<p class="lead">[^<]+</p>'
            $text | Should-MatchString ([regex]::Escape('<span>Generated <time datetime="2026-10-17T00:00:00Z">2026-10-17T00:00:00Z</time></span>'))
            $text | Should-MatchString ([regex]::Escape('<span>engine <code>main</code></span>'))
            $text | Should-MatchString ([regex]::Escape('<span><a href="https://github.com/contoso/rulebook">contoso/rulebook</a></span>'))
            $text | Should-MatchString ([regex]::Escape('<span class="powered">Powered by <a href="https://alcops.dev">ALCops</a></span>'))
            $text | Should-MatchString ([regex]::Escape('<script src="/rulebook/js/shell.js" defer></script>'))
        }
        $index | Should-MatchString '<title>Rulebook \| contoso</title>'
        $ci | Should-MatchString '<title>Stage CI \| Rulebook</title>'
        $ci | Should-MatchString ([regex]::Escape('<meta name="description" content="Pull request and release builds. Postponable diagnostics relaxed to Info.">'))
        $ci | Should-MatchString ([regex]::Escape('<meta property="og:url" content="https://contoso.github.io/rulebook/stages/ci/">'))
        $rule | Should-MatchString ([regex]::Escape('<meta name="description" content="The action of LC0029 on every level and stage of this rulebook.">'))
        $setup | Should-MatchString '<meta name="description" content="How an AL project uses the rulesets of this rulebook'
        $index | Should-MatchString '<main id="content" class="page page-matrix">'
        $ci | Should-MatchString '<main id="content" class="page page-stage">'
        $level | Should-MatchString '<main id="content" class="page page-level">'
        $rule | Should-MatchString '<main id="content" class="page page-rule">'
        $setup | Should-MatchString '<main id="content" class="page page-setup">'
        $index | Should-MatchString '<div class="matrix-scroll">\n<table class="matrix" role="grid">'
        $rule | Should-MatchString '<table class="matrix rule-matrix" role="grid">'
        # One Tab stop per grid (#113): the first cell of the first rule row, on a stage page and on a rule page.
        foreach ($text in $index, $ci, $rule) {
            ([regex]::Matches($text, '<td [^>]*tabindex="0"')).Count | Should-Be 1
            ([regex]::Matches($text, '<td [^>]*tabindex="-1"')).Count | Should-Be $(if ($text -ceq $rule) { 11 } else { 119 })
        }
        $ci | Should-MatchString 'data-id="AL0001" data-level="essential" data-stage="ci" [^>]*tabindex="0">'
        $rule | Should-MatchString 'data-id="LC0029" data-level="essential" data-stage="default" [^>]*tabindex="0">'
    }

    It 'ships equal dark token sets for the toggle and the system setting, and the light set for print' {
        # site.css sets the dark tokens twice (D59): [data-theme="dark"] for the toggle and a prefers-color-scheme block
        # for the system setting without JavaScript. The two must stay the same, line for line.
        $css = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'template' 'site' 'assets' 'css' 'site.css')).Replace("`r`n", "`n")
        $toggle = [regex]::Match($css, '(?ms)^\[data-theme="dark"\] \{\n(.*?)^\}').Groups[1].Value
        $system = [regex]::Match($css, '(?ms)^@media \(prefers-color-scheme: dark\) \{\n  :root:not\(\[data-theme="light"\]\) \{\n(.*?)^  \}\n\}').Groups[1].Value
        $toggle | Should-MatchString '--bg: '
        $lines = { param($Text) , [string[]]@($Text.TrimEnd("`n").Split("`n") | ForEach-Object { $_.Trim() }) }
        Should-BeCollection -Actual (& $lines $system) -Expected (& $lines $toggle)
        # Every colour token of the light set has a dark value.
        $light = [regex]::Match($css, '(?ms)^:root \{\n(.*?)^\}').Groups[1].Value
        $names = { param($Text) , [string[]]@([regex]::Matches($Text, '(?m)^\s*(--[a-z0-9-]+):') | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -notin '--font', '--mono', '--header-h' }) }
        Should-BeCollection -Actual (& $names $toggle) -Expected (& $names $light)
        # Print uses the light set, line for line, whatever the screen shows.
        $print = [regex]::Match($css, '(?ms)^@media print \{\n  :root:not\(\[data-theme="light"\]\), :root\[data-theme\] \{\n(.*?)^  \}').Groups[1].Value
        $colours = { param($Text) , [string[]]@((& $lines $Text) -match '^--' -notmatch '^--(font|mono|header-h):') }
        Should-BeCollection -Actual (& $colours $print) -Expected (& $colours $light)
    }
}
