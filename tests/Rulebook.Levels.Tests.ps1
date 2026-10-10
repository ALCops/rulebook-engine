# Levels suite for WP10 (#12): modules/Rulebook.Levels (the off level, the level summary and the level pages).
# Cases run on the repository fixtures under tests/fixtures/repos/ (valid-minimal and the custom-level and alias-level
# overlays), on a repository built from the tiny matrix (levels Core and Extended, stages default and CI; the
# expected Extended page was derived by hand from tests/fixtures/matrix/tiny/matrix/resolved.json) and on the
# committed template/ with docs/levels/.

BeforeAll {
    # The docs, schema and script URLs follow the engine ref: clear what a runner step would set, restore it in AfterAll.
    . (Join-Path $PSScriptRoot 'Helpers' 'EngineRef.ps1')
    $script:savedEngineRef = Clear-EngineRefEnvironment
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:repoRoot 'modules' 'Rulebook.Generate.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'modules' 'Rulebook.Validate.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'modules' 'Rulebook.Template.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'modules' 'Rulebook.Catalog.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'modules' 'Rulebook.Levels.psd1') -Force
    . (Join-Path $PSScriptRoot 'Helpers' 'RepoFixture.ps1')

    $script:templateDir = Join-Path $script:repoRoot 'template'
    $script:levelDocsDir = Join-Path $script:repoRoot 'docs' 'levels'
    $script:deltaUrl = 'https://raw.githubusercontent.com/ALCops/rulebook-engine/main/schemas/ruleset.delta.schema.json'

    function Get-TestFolder {
        return Join-Path $TestDrive ([guid]::NewGuid().ToString('n').Substring(0, 12))
    }

    function Copy-Fixture {
        param([string]$Name = 'valid-minimal')
        return New-FixtureRepo -Name $Name -Destination (Get-TestFolder)
    }

    function New-TinyRepo {
        # A repository built from the tiny matrix: level files, twins.json, stages/ci.json, the catalog and a
        # settings file with Core, Extended basedOn Core and the stages default and CI.
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helper; writes only to TestDrive')]
        param()
        $root = Get-TestFolder
        $tiny = Join-Path $PSScriptRoot 'fixtures' 'matrix' 'tiny'
        $null = Build-RulebookBase -RulebookDir $tiny -OutputPath (Join-Path $root 'base')
        $null = Build-RulebookStages -RulebookDir $tiny -OutputPath (Join-Path $root 'stages')
        $null = Build-RulebookCatalog -RulebookDir $tiny -OutputPath (Join-Path $root 'catalog' 'diagnostics.json')
        Write-FixtureText -Path (Join-Path $root '.github' 'Rulebook-Settings.json') -Text @'
{
  "twins": "both",
  "levels": [
    { "name": "Core", "description": "The tiny root." },
    { "name": "Extended", "basedOn": "Core" }
  ],
  "stages": [ { "name": "default" }, { "name": "CI" } ]
}
'@
        return (Resolve-Path -LiteralPath $root).ProviderPath
    }

    function Get-Summary {
        param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Level)
        $inputs = Read-RulebookInputs -RepositoryRoot $Root
        $catalog = Read-CatalogFile -Path (Join-Path $Root 'catalog' 'diagnostics.json')
        return Get-RulebookLevelSummary -Inputs $inputs -Catalog $catalog -Level $Level
    }

    function Get-CountText {
        # 'stage E W I H N L' per counts row.
        param([Parameter(Mandatory)]$Summary)
        return @($Summary.Counts | ForEach-Object { '{0} {1} {2} {3} {4} {5} {6}' -f $_.Stage, $_.Error, $_.Warning, $_.Info, $_.Hidden, $_.None, $_.Listed })
    }

    function Edit-SettingsFile {
        param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][scriptblock]$Script)
        Edit-FixtureJson -Path (Join-Path $Root '.github' 'Rulebook-Settings.json') -Script $Script
    }

    function Update-Repository {
        # Regenerates the endpoints and the skeletons of a repository; returns the change objects.
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helper; writes only to TestDrive')]
        param([Parameter(Mandatory)][string]$Root)
        @(Update-RulebookEndpoints -RepositoryRoot $Root)
        @(New-RulebookSkeleton -SettingsPath (Join-Path $Root '.github' 'Rulebook-Settings.json') -OutputPath (Join-Path $Root 'skeletons'))
    }

    function Get-FileBase64 {
        # The bytes of a file as one string, for exact comparisons.
        param([Parameter(Mandatory)][string]$Path)
        return [System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes($Path))
    }

    function Read-Text {
        param([Parameter(Mandatory)][string]$Path)
        return [System.IO.File]::ReadAllText($Path)
    }
}

AfterAll {
    Restore-EngineRefEnvironment -Saved $script:savedEngineRef
    Remove-Module Rulebook.Levels, Rulebook.Catalog, Rulebook.Template, Rulebook.Validate, Rulebook.Generate, Rulebook.Common -ErrorAction SilentlyContinue
}

Describe 'Get-RulebookOffLevelEntry' {
    It 'lists the 28 ids valid-minimal enables by default at None, in sort-key order, without the disabled ones' {
        $catalog = Read-CatalogFile -Path (Join-Path $PSScriptRoot 'fixtures' 'repos' 'valid-minimal' 'catalog' 'diagnostics.json')
        $entries = Get-RulebookOffLevelEntry -Catalog $catalog
        $entries.Count | Should-Be 28
        $ids = @($entries | ForEach-Object Id)
        $ids | Should-NotContainCollection 'LC0054'
        $ids | Should-NotContainCollection 'CM0001'
        $ids | Should-ContainCollection 'FC0001'
        @($entries | Where-Object Action -CNE 'None') | Should-BeCollection @()
        @($entries | Where-Object { $_.PSObject.Properties['Justification'] }) | Should-BeCollection @()
        $keys = @($ids | ForEach-Object { (Get-DiagnosticSortKey -Id $_) + '|' + $_ })
        $sorted = [string[]]$keys.Clone()
        [System.Array]::Sort($sorted, [System.StringComparer]::Ordinal)
        $keys | Should-BeCollection $sorted
    }

    It 'includes deprecated and unadvertised ids that are enabled by default' {
        $root = Copy-Fixture
        $path = Join-Path $root 'catalog' 'diagnostics.json'
        Edit-FixtureJson -Path $path -Script {
            foreach ($entry in $_['diagnostics']) {
                if ($entry['id'] -ceq 'LC0001') { $entry['deprecated'] = $true }
                if ($entry['id'] -ceq 'AS0001') { $entry['advertised'] = $false }
            }
        }
        $ids = @((Get-RulebookOffLevelEntry -Catalog (Read-CatalogFile -Path $path)) | ForEach-Object Id)
        $ids | Should-ContainCollection 'LC0001'
        $ids | Should-ContainCollection 'AS0001'
        $ids.Count | Should-Be 28
    }

    It 'returns an empty array for a catalog without an enabled id' {
        $root = Copy-Fixture
        $path = Join-Path $root 'catalog' 'diagnostics.json'
        Edit-FixtureJson -Path $path -Script { foreach ($entry in $_['diagnostics']) { $entry['enabledByDefault'] = $false } }
        $entries = Get-RulebookOffLevelEntry -Catalog (Read-CatalogFile -Path $path)
        $entries -is [object[]] | Should-BeTrue
        $entries.Count | Should-Be 0
    }
}

Describe 'New-RulebookOffLevel' {
    It 'writes base/off.ruleset.json with the schema, the name, the description and no justification' {
        $root = Copy-Fixture
        $result = New-RulebookOffLevel -RepositoryRoot $root
        $result.File | Should-Be 'base/off.ruleset.json'
        $result.Change | Should-Be 'created'
        $result.Slug | Should-Be 'off'
        $result.Count | Should-Be 28
        $result.SettingsListed | Should-BeFalse
        $result.SettingsEntry | Should-Be '{ "name": "Off", "description": "Every known diagnostic off. Opt in through overrides." }'
        $path = Join-Path $root 'base' 'off.ruleset.json'
        $json = Read-Text $path | ConvertFrom-Json -AsHashtable
        $json['$schema'] | Should-Be $deltaUrl
        $json['name'] | Should-Be 'Rulebook Off'
        $json['description'] | Should-Be 'Level off, the root. Every diagnostic the analyzers enable by default, at None (28 ids from catalog/diagnostics.json). Written once by New-RulebookOffLevel and owned by this repository: opt in with overrides scoped to levels ["off"] or by editing this file. Ids newer than this file arrive through quarantine.'
        @($json['rules'] | Where-Object { $_.Contains('justification') }) | Should-BeCollection @()
        (Read-RulesetFile -Path $path).Rules.Count | Should-Be 28
        $bytes = [System.IO.File]::ReadAllBytes($path)
        $bytes[0] | Should-Be ([byte][char]'{')
        @($bytes | Where-Object { $_ -eq 13 }) | Should-BeCollection @()
        $bytes[-1] | Should-Be 10
    }

    It 'returns nothing when the file is current and throws on a differing file without -Force' {
        $root = Copy-Fixture
        $null = New-RulebookOffLevel -RepositoryRoot $root
        $path = Join-Path $root 'base' 'off.ruleset.json'
        $before = Get-FileBase64 $path
        @(New-RulebookOffLevel -RepositoryRoot $root) | Should-BeCollection @()
        Get-FileBase64 $path | Should-Be $before

        Write-FixtureText -Path $path -Text ((Read-Text $path) -replace '"AL0001", "action": "None"', '"AL0001", "action": "Error"')
        { New-RulebookOffLevel -RepositoryRoot $root } | Should-Throw -ExceptionMessage 'base/off.ruleset.json exists and differs; it is owned by this repository. Use -Force to overwrite it (your own edits in it are lost)'
        (New-RulebookOffLevel -RepositoryRoot $root -Force).Change | Should-Be 'modified'
        Get-FileBase64 $path | Should-Be $before
    }

    It 'treats a CRLF working copy of a current file as current and leaves it alone, but not a changed entry' {
        $root = Copy-Fixture
        $null = New-RulebookOffLevel -RepositoryRoot $root
        $path = Join-Path $root 'base' 'off.ruleset.json'
        $crlf = [System.IO.File]::ReadAllText($path).Replace("`n", "`r`n")
        [System.IO.File]::WriteAllText($path, $crlf, [System.Text.UTF8Encoding]::new($false))
        @(New-RulebookOffLevel -RepositoryRoot $root) | Should-BeCollection @()
        [System.IO.File]::ReadAllText($path) | Should-Be $crlf
        [System.IO.File]::WriteAllText($path, $crlf.TrimEnd("`r", "`n"), [System.Text.UTF8Encoding]::new($false))
        @(New-RulebookOffLevel -RepositoryRoot $root) | Should-BeCollection @()
        [System.IO.File]::WriteAllText($path, $crlf.Replace('"AL0001", "action": "None"', '"AL0001", "action": "Info"'), [System.Text.UTF8Encoding]::new($false))
        { New-RulebookOffLevel -RepositoryRoot $root } | Should-Throw -ExceptionMessage 'base/off.ruleset.json exists and differs*'
    }

    It 'decides <Case> by content, not bytes: current <Current>' -ForEach @(
            @{ Case = 'a CRLF copy'; Current = $true; Edit = { param($t) $t.Replace("`n", "`r`n") } }
            @{ Case = 'a copy without the final newline'; Current = $true; Edit = { param($t) $t.TrimEnd("`n") } }
            @{ Case = 'a copy with a UTF-8 BOM'; Current = $true; Edit = { param($t) [string][char]0xFEFF + $t } }
            @{ Case = 'a copy with an extra trailing blank line'; Current = $false; Edit = { param($t) $t + "`n" } }
            @{ Case = 'a copy with a lone CR line end'; Current = $false; Edit = { param($t) $t.Replace("{`n", "{`r") } }
            @{ Case = 'a CRLF copy with a changed entry'; Current = $false; Edit = { param($t) $t.Replace("`n", "`r`n").Replace('"AL0001", "action": "None"', '"AL0001", "action": "Info"') } }
        ) {
        $root = Copy-Fixture
        $null = New-RulebookOffLevel -RepositoryRoot $root
        $path = Join-Path $root 'base' 'off.ruleset.json'
        $edited = & $Edit ([System.IO.File]::ReadAllText($path))
        [System.IO.File]::WriteAllText($path, $edited, [System.Text.UTF8Encoding]::new($false))
        $before = Get-FileBase64 $path
        if ($Current) {
            @(New-RulebookOffLevel -RepositoryRoot $root) | Should-BeCollection @()
            Get-FileBase64 $path | Should-Be $before
        } else {
            { New-RulebookOffLevel -RepositoryRoot $root } | Should-Throw -ExceptionMessage 'base/off.ruleset.json exists and differs*'
        }
    }

    It 'returns the change under -WhatIf and writes nothing' {
        $root = Copy-Fixture
        $result = New-RulebookOffLevel -RepositoryRoot $root -WhatIf
        $result.Change | Should-Be 'created'
        Test-Path -LiteralPath (Join-Path $root 'base' 'off.ruleset.json') | Should-BeFalse
    }

    It 'refuses a name that is not a slug' {
        { New-RulebookOffLevel -RepositoryRoot (Copy-Fixture) -Name 'Bad Name' } | Should-Throw -ExceptionMessage ([WildcardPattern]::Escape("Level name 'Bad Name' does not lowercase to a slug matching ^[a-z0-9-]+$ (C5)"))
    }

    It 'warns and reports the level as not listed when the settings cannot be read, and still writes the file' {
        $root = Copy-Fixture
        Write-FixtureText -Path (Join-Path $root '.github' 'Rulebook-Settings.json') -Text '{ "levels": [ '
        $result = New-RulebookOffLevel -RepositoryRoot $root -WarningVariable warnings -WarningAction SilentlyContinue
        $result.SettingsListed | Should-BeFalse
        $result.Change | Should-Be 'created'
        @($warnings | ForEach-Object { [string]$_ }) | Should-BeLikeString 'Cannot read .github/Rulebook-Settings.json (*); the level counts as not listed'
        Test-Path -LiteralPath (Join-Path $root 'base' 'off.ruleset.json') | Should-BeTrue
        Test-Path -LiteralPath (Join-Path $root 'base' 'off.ruleset.json.tmp') | Should-BeFalse
    }

    It 'refuses a catalog entry without a boolean enabledByDefault' {
        $root = Copy-Fixture
        Edit-FixtureJson -Path (Join-Path $root 'catalog' 'diagnostics.json') -Script { $_['diagnostics'][1].Remove('enabledByDefault') }
        { New-RulebookOffLevel -RepositoryRoot $root } | Should-Throw -ExceptionMessage 'catalog/diagnostics.json: AL0200 has no boolean enabledByDefault'
        Test-Path -LiteralPath (Join-Path $root 'base' 'off.ruleset.json') | Should-BeFalse
    }

    It 'warns before replacing the file of a published level and refuses the slug readme' {
        $root = Copy-Fixture
        { New-RulebookOffLevel -RepositoryRoot $root -Name 'Strict' -WarningVariable warnings -WarningAction SilentlyContinue } |
            Should-Throw -ExceptionMessage 'base/strict.ruleset.json exists and differs; it is owned by this repository. Use -Force to overwrite it (your own edits in it are lost)'
        $result = New-RulebookOffLevel -RepositoryRoot $root -Name 'Strict' -Force -WarningVariable forced -WarningAction SilentlyContinue
        $result.Change | Should-Be 'modified'
        @($forced | ForEach-Object { [string]$_ }) | Should-ContainCollection "'Strict' is already a published level; -Force would replace base/strict.ruleset.json with an everything-off file"
        { New-RulebookOffLevel -RepositoryRoot $root -Name 'README' } | Should-Throw -ExceptionMessage "Level 'README' cannot have a page: its slug collides with the index README.md"
    }

    It 'leaves a catalog entry without an id to the catalog reader' {
        $root = Copy-Fixture
        Edit-FixtureJson -Path (Join-Path $root 'catalog' 'diagnostics.json') -Script { $_['diagnostics'][1].Remove('id'); $_['diagnostics'][1].Remove('enabledByDefault') }
        { New-RulebookOffLevel -RepositoryRoot $root } | Should-Throw -ExceptionMessage '*has an entry without an id'
    }

    It 'uses -Name for the file and the entry, -Description for the entry, and reports a listed level' {
        $root = Copy-Fixture
        Edit-SettingsFile -Root $root -Script { $_['levels'] = @(@{ name = 'Quiet' }) + @($_['levels']) }
        $result = New-RulebookOffLevel -RepositoryRoot $root -Name 'Quiet' -Description 'Nothing on.'
        $result.File | Should-Be 'base/quiet.ruleset.json'
        $result.SettingsListed | Should-BeTrue
        $result.SettingsEntry | Should-Be '{ "name": "Quiet", "description": "Nothing on." }'
        (Read-RulesetFile -Path (Join-Path $root 'base' 'quiet.ruleset.json')).Name | Should-Be 'Rulebook Quiet'
    }

    It 'gives a repository that passes Validate once the entry is first in the settings and the endpoints are regenerated' {
        $root = Copy-Fixture
        $result = New-RulebookOffLevel -RepositoryRoot $root
        Edit-SettingsFile -Root $root -Script { $_['levels'] = @(@{ name = 'Off'; description = 'Every known diagnostic off. Opt in through overrides.' }) + @($_['levels']) }
        $null = Update-Repository -Root $root
        @(Test-Rulebook -RepositoryRoot $root | Where-Object Severity -EQ 'error') | Should-BeCollection @()
        # A stage never activates a rule the level left at None (S-4), so the CI endpoint lists the same 28 ids.
        (Read-RulesetFile -Path (Join-Path $root 'rulesets' 'off.ruleset.json')).Rules.Count | Should-Be $result.Count
        (Read-RulesetFile -Path (Join-Path $root 'rulesets' 'off.ci.ruleset.json')).Rules.Count | Should-Be $result.Count
    }
}

Describe 'Get-RulebookLevelSummary' {
    It 'names the basedOn of a custom level between Recommended and Strict and composes From from the chain' {
        $summary = Get-Summary -Root (Copy-Fixture 'custom-level') -Level 'custom'
        $summary.BasedOn | Should-Be 'recommended'
        $summary.BasedOnName | Should-Be 'Recommended'
        $summary.BasedOnPublished | Should-BeTrue
        $summary.ChainFiles | Should-BeCollection @('essential', 'recommended', 'custom')
        $summary.EntryCount | Should-Be 1
        $row = $summary.Rows[0]
        '{0} {1} {2} {3} {4}' -f $row.Id, $row.From, $row.FromSource, $row.To, $row.Lowered | Should-Be 'TA0001 Warning default Error False'
        @($summary.Counts | ForEach-Object Stage) | Should-BeCollection @('default', 'ci', 'vnext')
    }

    It 'throws on a slug the settings do not publish' {
        { Get-Summary -Root (Copy-Fixture) -Level 'paranoid' } | Should-Throw -ExceptionMessage "Unknown level slug 'paranoid'"
    }

    It 'marks lowered rows on valid-minimal Strict, falls back to the id prefix and leaves an id outside the catalog out of the counts' {
        $root = Copy-Fixture
        $strict = Join-Path $root 'base' 'strict.ruleset.json'
        Write-FixtureText -Path $strict -Text ((Read-Text $strict) -replace '\{ "id": "CM0001", "action": "Info" \}', '{ "id": "CM0001", "action": "Info" }, { "id": "LC0999", "action": "Warning" }')
        $summary = Get-Summary -Root $root -Level 'strict'
        $byId = @{}
        foreach ($row in $summary.Rows) { $byId[$row.Id] = $row }
        '{0} {1} {2} {3}' -f $byId['AL0603'].From, $byId['AL0603'].To, $byId['AL0603'].Lowered, $byId['AL0603'].Analyzer | Should-Be 'Warning Info True AL'
        '{0} {1} {2} {3}' -f $byId['AA0137'].From, $byId['AA0137'].To, $byId['AA0137'].Lowered, $byId['AA0137'].Analyzer | Should-Be 'Warning Error False AA'
        # LC0015: Recommended sets Info, Strict Warning: From comes from the level below.
        '{0} {1}' -f $byId['LC0015'].From, $byId['LC0015'].FromSource | Should-Be 'Info level:recommended'
        $byId['LC0999'].From | Should-BeNull
        $byId['LC0999'].Lowered | Should-BeFalse
        @($summary.Groups | ForEach-Object Analyzer) | Should-BeCollection @('AL', 'AA', 'LC', 'FC', 'CM')
        foreach ($count in $summary.Counts) { $count.Error + $count.Warning + $count.Info + $count.Hidden + $count.None | Should-Be 30 }
        $page = ConvertTo-LevelDocsMarkdown -Summary $summary
        $page | Should-MatchString '(?m)^\| LC0999 \|  \| \(not in the catalog\) \| Warning \|  \|  \|  \|$'
        $page | Should-MatchString '(?m)^\| AL0603 \|  \| Warning \| Info \| lowered \| Fixture: a level lowers an id that is enabled by default \|  \|$'
    }

    It 'takes From from a level file without a settings entry and says so on the page (D29)' {
        $root = Copy-Fixture
        Edit-SettingsFile -Root $root -Script { $_['levels'] = @($_['levels'] | Select-Object -Skip 1) }
        $summary = Get-Summary -Root $root -Level 'recommended'
        $summary.BasedOn | Should-Be 'essential'
        $summary.BasedOnPublished | Should-BeFalse
        $summary.ChainFiles | Should-BeCollection @('essential', 'recommended')
        $row = @($summary.Rows | Where-Object Id -CEQ 'AL0200')[0]
        '{0} {1}' -f $row.From, $row.FromSource | Should-Be 'None level:essential'
        $page = ConvertTo-LevelDocsMarkdown -Summary $summary
        $page | Should-MatchString '(?m)^- \*\*Based on:\*\* `essential` \(a level file without a settings entry; a root for this chain, D29\)$'
        $page | Should-NotMatchString '\(essential\.md\)'
    }
}

Describe 'Level pages' {
    It 'writes the Extended page of the tiny repository as derived by hand (one lowered row)' {
        $root = New-TinyRepo
        $out = Get-TestFolder
        $changes = @(New-RulebookLevelDocs -RepositoryRoot $root -OutputPath $out)
        @($changes | ForEach-Object { '{0} {1}' -f (Split-Path -Leaf $_.Path), $_.Change }) | Should-BeCollection @('core.md created', 'extended.md created', 'README.md created')
        $expected = @'
# Level Extended

Generated by `New-RulebookLevelDocs` from the settings, `base/extended.ruleset.json`, the chain below it and `catalog/diagnostics.json`; do not edit.

- **Slug:** `extended`
- **Based on:** [Core](core.md)
- **Description:** (none)
- **File:** `base/extended.ruleset.json`, 4 entries, 1 of them lower the action relative to Core
- **Chain:** `base/core.ruleset.json` -> `base/extended.ruleset.json`

## Counts per stage

| Stage | Error | Warning | Info | Hidden | None | Listed |
|---|---|---|---|---|---|---|
| default | 2 | 3 | 1 | 0 | 0 | 2 |
| ci | 2 | 2 | 2 | 0 | 0 | 3 |

6 catalog ids per row. Listed is the number of ids the endpoint writes (`rulesets/extended.ruleset.json` for default, `rulesets/extended.<stage>.ruleset.json` for the others): ids whose action differs from the analyzer default, plus ids the level file mentions that are not in the catalog. The counts include this repository's overrides (0 match this level), the twins setting `both` and the quarantine files; the entries below are the level file alone.

## Entries

### Compiler (2)

| Id | Title | From | To | Change | Justification | Docs |
|---|---|---|---|---|---|---|
| AL0200 | Property is obsolete | None | Warning |  | Advisory below Extended; D-01 | [docs](https://example.invalid/al0200) |
| AL0603 | Implicit conversion | None | Info |  | Opt-in rule enabled from Extended; D-09 |  |

### AppSourceCop (2)

| Id | Title | From | To | Change | Justification | Docs |
|---|---|---|---|---|---|---|
| AS0061 | Procedures must not subscribe to CompanyOpen events | None | Error |  | Marketplace check from Extended; F-07 | [docs](https://example.invalid/as0061) |
| AS0084 | Set the "idRanges" in app.json | Error | Warning | lowered | Lowered at Extended for the fixture; OV-01 | [docs](https://example.invalid/as0084) |

'@
        # The here-string ends with an empty line, so the expected text ends with one LF.
        Read-Text (Join-Path $out 'extended.md') | Should-Be ($expected -replace "`r`n", "`n")
    }

    It 'marks both rows of the tiny root Core as lowered against the analyzer default' {
        $summary = Get-Summary -Root (New-TinyRepo) -Level 'core'
        @($summary.Rows | ForEach-Object { '{0} {1} {2} {3} {4}' -f $_.Id, $_.From, $_.FromSource, $_.To, $_.Lowered }) |
            Should-BeCollection @('AL0200 Warning default None True', 'AS0061 Error default None True')
        $summary.LoweredCount | Should-Be 2
        Get-CountText -Summary $summary | Should-BeCollection @('default 2 1 0 0 3 2', 'ci 2 0 1 0 3 3')
    }

    It 'writes the page of a custom level with a link to its basedOn, next to the regenerated endpoints and skeletons' {
        $root = Copy-Fixture 'custom-level'
        $null = Update-Repository -Root $root
        $out = Get-TestFolder
        $null = New-RulebookLevelDocs -RepositoryRoot $root -OutputPath $out
        @(Get-ChildItem -LiteralPath (Join-Path $root 'rulesets') -Filter '*.ruleset.json').Count | Should-Be 15
        @(Get-ChildItem -LiteralPath (Join-Path $root 'skeletons') -Filter '*.ruleset.json').Count | Should-Be 15
        [string[]]$pages = @(Get-ChildItem -LiteralPath $out -File | ForEach-Object Name)
        [System.Array]::Sort($pages, [System.StringComparer]::Ordinal)
        $pages | Should-BeCollection @('README.md', 'complete.md', 'custom.md', 'essential.md', 'recommended.md', 'strict.md')
        $custom = Read-Text (Join-Path $out 'custom.md')
        $custom | Should-MatchString '(?m)^- \*\*Based on:\*\* \[Recommended\]\(recommended\.md\)$'
        $custom | Should-MatchString '(?m)^\| TA0001 \|  \| Warning \| Error \|  \| House rule: tests are mandatory \|  \|$'
        Read-Text (Join-Path $out 'strict.md') | Should-MatchString '(?m)^- \*\*Based on:\*\* \[Custom\]\(custom\.md\)$'
        @(Test-Rulebook -RepositoryRoot $root | Where-Object Severity -EQ 'error') | Should-BeCollection @()
    }

    It 'writes an alias level with no rows and the counts of its basedOn once no override is scoped to one of them' {
        $root = Copy-Fixture 'alias-level'
        $summary = Get-Summary -Root $root -Level 'baseline'
        $summary.Rows.Count | Should-Be 0
        $page = ConvertTo-LevelDocsMarkdown -Summary $summary
        $page | Should-MatchString '(?m)^`base/baseline\.ruleset\.json` lists no entry: this level is an alias of \[Recommended\]\(recommended\.md\) and its endpoints equal that level''s\.$'
        $page | Should-NotMatchString '(?m)^### '
        # valid-minimal scopes LC0029 None to levels ["recommended"], stages ["ci"]: an override names slugs, so the
        # alias does not inherit it and the ci rows differ by that one id.
        $recommended = Get-Summary -Root $root -Level 'recommended'
        (Get-CountText -Summary $summary)[0] | Should-Be (Get-CountText -Summary $recommended)[0]
        (Get-CountText -Summary $summary)[1] | Should-NotBe (Get-CountText -Summary $recommended)[1]
        Edit-FixtureJson -Path (Join-Path $root 'overrides.json') -Script { $_['rules'] = @($_['rules'] | Where-Object { $_['id'] -cne 'LC0029' }) }
        Get-CountText -Summary (Get-Summary -Root $root -Level 'baseline') | Should-BeCollection (Get-CountText -Summary (Get-Summary -Root $root -Level 'recommended'))
    }

    It 'deletes the endpoints, skeletons and page of a removed level and leaves the other pages byte-identical' {
        $root = Copy-Fixture
        $null = Update-Repository -Root $root
        $out = Get-TestFolder
        $null = New-RulebookLevelDocs -RepositoryRoot $root -OutputPath $out
        $before = @{}
        foreach ($name in 'essential.md', 'recommended.md', 'strict.md') { $before[$name] = Get-FileBase64 (Join-Path $out $name) }
        Edit-SettingsFile -Root $root -Script { $_['levels'] = @($_['levels'] | Where-Object { $_['name'] -cne 'Complete' }); $_['unusedRulebookFiles'] = @('base/complete.ruleset.json') }
        $changes = @(Update-Repository -Root $root)
        @($changes | Where-Object Change -EQ 'deleted' | ForEach-Object File | Sort-Object) | Should-BeCollection @(
            'rulesets/complete.ci.ruleset.json', 'rulesets/complete.ruleset.json', 'rulesets/complete.vnext.ruleset.json'
            'skeletons/complete.ci.ruleset.json', 'skeletons/complete.default.ruleset.json', 'skeletons/complete.vnext.ruleset.json'
        )
        @($changes | Where-Object Change -NE 'deleted') | Should-BeCollection @()
        $pageChanges = @(New-RulebookLevelDocs -RepositoryRoot $root -OutputPath $out)
        @($pageChanges | ForEach-Object { '{0} {1}' -f (Split-Path -Leaf $_.Path), $_.Change }) | Should-BeCollection @('complete.md deleted', 'README.md modified')
        foreach ($name in $before.Keys) { Get-FileBase64 (Join-Path $out $name) | Should-Be $before[$name] }
        @(Test-Rulebook -RepositoryRoot $root | Where-Object Severity -EQ 'error') | Should-BeCollection @()
    }

    It 'returns the change list under -WhatIf without writing, and reports an orphan page as deleted' {
        $out = Get-TestFolder
        Write-FixtureText -Path (Join-Path $out 'paranoid.md') -Text "# Level Paranoid`n`nGenerated by ``New-RulebookLevelDocs`` from the settings, ``base/paranoid.ruleset.json``, the chain below it and ``catalog/diagnostics.json``; do not edit."
        $changes = @(New-RulebookLevelDocs -RepositoryRoot (Copy-Fixture) -OutputPath $out -WhatIf)
        @($changes | ForEach-Object { '{0} {1}' -f (Split-Path -Leaf $_.Path), $_.Change }) | Should-BeCollection @(
            'paranoid.md deleted', 'essential.md created', 'recommended.md created', 'strict.md created', 'complete.md created', 'README.md created'
        )
        @(Get-ChildItem -LiteralPath $out -File | ForEach-Object Name) | Should-BeCollection @('paranoid.md')
        $null = New-RulebookLevelDocs -RepositoryRoot (Copy-Fixture) -OutputPath $out
        Test-Path -LiteralPath (Join-Path $out 'paranoid.md') | Should-BeFalse
    }

    It 'refuses an output folder holding a Markdown file that is not a generated page, before writing anything' {
        $out = Get-TestFolder
        Write-FixtureText -Path (Join-Path $out 'foo.md') -Text "# Foo`n`nHand-written."
        { New-RulebookLevelDocs -RepositoryRoot (Copy-Fixture) -OutputPath $out } | Should-Throw -ExceptionMessage "New-RulebookLevelDocs refuses to manage $(Split-Path -Leaf $out)/foo.md: it is not a generated level page"
        @(Get-ChildItem -LiteralPath $out -File | ForEach-Object Name) | Should-BeCollection @('foo.md')
    }

    It 'refuses a level whose slug is readme' {
        $root = Copy-Fixture
        Edit-SettingsFile -Root $root -Script { $_['levels'] = @($_['levels']) + @(@{ name = 'README'; basedOn = 'Strict' }) }
        Write-FixtureText -Path (Join-Path $root 'base' 'readme.ruleset.json') -Text '{ "name": "Rulebook README", "rules": [] }'
        $out = Get-TestFolder
        { New-RulebookLevelDocs -RepositoryRoot $root -OutputPath $out } | Should-Throw -ExceptionMessage "Level 'README' cannot have a page: its slug collides with the index README.md"
        Test-Path -LiteralPath $out | Should-BeFalse
    }

    It 'folds a lone carriage return and escapes HTML characters in a title, and encodes a docs URL' {
        $root = Copy-Fixture
        Edit-FixtureJson -Path (Join-Path $root 'catalog' 'diagnostics.json') -Script {
            foreach ($entry in $_['diagnostics']) {
                if ($entry['id'] -ceq 'AA0137') { $entry['title'] = "First`rsecond | third <b> & c"; $entry['docs'] = 'https://example.invalid/rules (draft)/a|b<c>]/aa0137' }
            }
        }
        $page = ConvertTo-LevelDocsMarkdown -Summary (Get-Summary -Root $root -Level 'strict')
        $page | Should-MatchString '(?m)^\| AA0137 \| First second \\\| third &lt;b&gt; &amp; c \| Warning \| Error \|  \|  \| \[docs\]\(https://example\.invalid/rules%20%28draft%29/a%7Cb%3Cc%3E%5D/aa0137\) \|$'
        $page | Should-NotMatchString "`r"
    }

    It 'escapes the basedOn name in link labels and table cells' {
        $root = Copy-Fixture 'custom-level'
        $summary = Get-Summary -Root $root -Level 'custom'
        # Names are C5-checked slugs in a real repository; the escaping is defensive, so the summary is edited here.
        $summary.BasedOnName = 'My|Level [x]'
        ConvertTo-LevelDocsMarkdown -Summary $summary | Should-MatchString '(?m)^- \*\*Based on:\*\* \[My\\\|Level \\\[x\\\]\]\(recommended\.md\)$'
        $index = ConvertTo-LevelDocsIndexMarkdown -Summaries @($summary) -Inputs (Read-RulebookInputs -RepositoryRoot $root)
        $index | Should-MatchString '(?m)^\| Custom \| `custom` \| \[My\\\|Level \\\[x\\\]\]\(recommended\.md\) \| 1 \| '
    }

    It 'throws on an action outside the strictness order, naming the id' {
        $root = Copy-Fixture
        $inputs = Read-RulebookInputs -RepositoryRoot $root
        $inputs.LevelFiles['strict'].Rules['AA0137'].Action = 'Severe'
        { Get-RulebookLevelSummary -Inputs $inputs -Catalog (Read-CatalogFile -Path (Join-Path $root 'catalog' 'diagnostics.json')) -Level 'strict' } | Should-Throw -ExceptionMessage "Unknown action 'Severe' for AA0137"
    }

    It 'throws when the settings are missing' {
        $root = Copy-Fixture
        Remove-Item -LiteralPath (Join-Path $root '.github' 'Rulebook-Settings.json')
        { New-RulebookLevelDocs -RepositoryRoot $root -OutputPath (Get-TestFolder) } | Should-Throw -ExceptionMessage 'Settings missing: .github/Rulebook-Settings.json in *'
    }
}

Describe 'Level pages of template/' {
    It 'gives the four shipped levels a page with a justification on every row, identical to the committed docs/levels/' {
        $inputs = Read-RulebookInputs -RepositoryRoot $templateDir
        $catalog = Read-CatalogFile -Path (Join-Path $templateDir 'catalog' 'diagnostics.json')
        foreach ($level in $inputs.Levels) {
            $summary = Get-RulebookLevelSummary -Inputs $inputs -Catalog $catalog -Level $level.Slug
            $summary.EntryCount | Should-BeGreaterThan 0
            @($summary.Rows | Where-Object { [string]::IsNullOrWhiteSpace($_.Justification) } | ForEach-Object Id) | Should-BeCollection @()
        }
        $out = Get-TestFolder
        $changes = @(New-RulebookLevelDocs -RepositoryRoot $templateDir -OutputPath $out -GeneratedBy 'tools/rulebook/Build-Template.ps1')
        $changes.Count | Should-Be 5
        foreach ($name in 'README.md', 'essential.md', 'recommended.md', 'strict.md', 'complete.md') {
            Get-FileBase64 (Join-Path $out $name) | Should-Be (Get-FileBase64 (Join-Path $levelDocsDir $name))
        }
    }
}
