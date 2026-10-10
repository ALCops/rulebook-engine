# Fixture guard suite (WP12, #14): what every fixture under tests/fixtures/ proves, in one place. The table below is
# the one place that says it for the repository fixtures: its kind (complete on disk, or an overlay New-FixtureRepo
# lays over valid-minimal), the exact unique findings of Test-Rulebook ("<Rule> <severity>" in rule order) and what
# Get-RulebookEndpointChange would regenerate. The template fixtures validate and stay in step with the engine, and
# every fixture folder is used somewhere. Schema fixtures are checked by tests/Schemas.Tests.ps1.

BeforeDiscovery {
    # Endpoint change lists, '<file> <change>' in the order of the Update-RulebookEndpoints -WhatIf list.
    function Get-EndpointList {
        param([string[]]$Levels, [string]$Change)
        return @(foreach ($level in $Levels) { foreach ($stage in '', '.ci', '.vnext') { "rulesets/$level$stage.ruleset.json $Change" } })
    }

    $script:repoCases = @(
        @{ Name = 'valid-minimal'; Kind = 'complete'; Findings = @(); Regenerate = @() }
        @{ Name = 'update-org'; Kind = 'complete'; Findings = @(); Regenerate = @() }
        @{ Name = 'stale-endpoints'; Kind = 'complete'; Findings = @('C12 error'); Regenerate = @('rulesets/recommended.ci.ruleset.json modified') }
        @{ Name = 'scan-org'; Kind = 'overlay'; Findings = @(); Regenerate = @() }
        @{ Name = 'alias-level'; Kind = 'overlay'; Findings = @('C12 error'); Regenerate = @(Get-EndpointList -Levels 'baseline' -Change 'created') }
        @{ Name = 'custom-level'; Kind = 'overlay'; Findings = @('C12 error'); Regenerate = @(Get-EndpointList -Levels 'custom' -Change 'created') + @(Get-EndpointList -Levels 'strict', 'complete' -Change 'modified') }
        @{ Name = 'twins-appsource'; Kind = 'overlay'; Findings = @('C12 error'); Regenerate = @(Get-EndpointList -Levels 'essential', 'recommended', 'strict', 'complete' -Change 'modified') }
        @{ Name = 'twins-pte'; Kind = 'overlay'; Findings = @('C12 error'); Regenerate = @(Get-EndpointList -Levels 'essential', 'recommended', 'strict', 'complete' -Change 'modified') }
        @{ Name = 'bad-selector'; Kind = 'overlay'; Findings = @('C10 error'); Regenerate = @() }
        @{ Name = 'unknown-id'; Kind = 'overlay'; Findings = @('C7 warning'); Regenerate = @() }
        @{ Name = 'quarantined-stage-entry'; Kind = 'overlay'; Findings = @('C15 warning'); Regenerate = @() }
        @{ Name = 'duplicate-id'; Kind = 'overlay'; Findings = @('C2 error', 'C12 warning'); Throws = 'base/strict.ruleset.json lists AA0137 twice (C2)' }
        @{ Name = 'endpoint-lists-default'; Kind = 'overlay'; Findings = @('C11 error', 'C12 error'); Regenerate = @('rulesets/recommended.ruleset.json modified') }
        @{ Name = 'endpoint-with-include'; Kind = 'overlay'; Findings = @('C1 error', 'C3 error', 'C12 error'); Regenerate = @('rulesets/strict.ruleset.json modified') }
        @{ Name = 'unknown-quarantine-stage'; Kind = 'overlay'; Findings = @('C16 warning'); Regenerate = @() }
        @{ Name = 'bad-twins-value'; Kind = 'overlay'; Findings = @('C5 error', 'C12 warning'); Throws = "*twins is 'all'*" }
        @{ Name = 'basedon-cycle'; Kind = 'overlay'; Findings = @('C5 error', 'C12 warning'); Throws = 'basedOn cycle: recommended -> strict -> recommended' }
        @{ Name = 'missing-default-stage'; Kind = 'overlay'; Findings = @('C5 error', 'C12 warning'); Regenerate = @(foreach ($level in 'complete', 'essential', 'recommended', 'strict') { "rulesets/$level.ruleset.json deleted" }) }
    )
    foreach ($case in $script:repoCases) {
        if (-not $case.ContainsKey('Throws')) { $case.Throws = $null }
        if (-not $case.ContainsKey('Regenerate')) { $case.Regenerate = @() }
        $case.FindingsText = if ($case.Findings.Count) { $case.Findings -join ', ' } else { 'nothing' }
        $case.RegenerateText = if ($null -ne $case.Throws) { 'an error' } elseif ($case.Regenerate.Count) { "$($case.Regenerate.Count) change(s)" } else { 'nothing' }
    }

    $fixturesRoot = Join-Path $PSScriptRoot 'fixtures'
    $script:folderCases = @(foreach ($group in 'repos', 'templates', 'matrix') {
            foreach ($folder in Get-ChildItem -LiteralPath (Join-Path $fixturesRoot $group) -Directory) { @{ Group = $group; Name = $folder.Name } }
        })
    $script:repoFolderCases = @($folderCases | Where-Object { $_.Group -eq 'repos' })
}

BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $PSScriptRoot 'Helpers' 'RepoFixture.ps1')
    Import-Module (Join-Path $repoRoot 'modules' 'Rulebook.Generate.psd1') -Force
    Import-Module (Join-Path $repoRoot 'modules' 'Rulebook.Validate.psd1') -Force
    Import-Module (Join-Path $repoRoot 'modules' 'Rulebook.Template.psd1') -Force
    $script:fixturesRoot = Join-Path $PSScriptRoot 'fixtures'
    $script:templates = Join-Path $fixturesRoot 'templates'
    $script:v1 = Join-Path $templates 'v1'
    $script:v2 = Join-Path $templates 'v2'
    $script:orgFixture = Join-Path $fixturesRoot 'repos' 'update-org'

    function Get-TestFolder {
        return Join-Path $TestDrive ([guid]::NewGuid().ToString('n').Substring(0, 12))
    }

    function Get-RelativeFileList {
        param([string]$Root)
        [string[]]$files = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force | ForEach-Object { [System.IO.Path]::GetRelativePath($Root, $_.FullName).Replace('\', '/') } | Where-Object { -not $_.StartsWith('.git/') })
        [System.Array]::Sort($files, [System.StringComparer]::Ordinal)
        return $files
    }

    function Get-UniqueFinding {
        # "<Rule> <severity>" once each, in the order Test-Rulebook returns them (rule order). The comma keeps an
        # empty or one-item list a collection.
        param([string]$Root)
        $list = [System.Collections.Generic.List[string]]::new()
        foreach ($finding in @(Test-Rulebook -RepositoryRoot $Root)) {
            $text = '{0} {1}' -f $finding.Rule, $finding.Severity
            if (-not $list.Contains($text)) { $list.Add($text) }
        }
        return , [string[]]$list.ToArray()
    }
}

AfterAll {
    Remove-Module Rulebook.Template, Rulebook.Catalog, Rulebook.NuGet, Rulebook.Validate, Rulebook.Generate, Rulebook.Common -ErrorAction SilentlyContinue
}

Describe 'Repository fixtures' {
    It '<Name> is a <Kind> fixture' -ForEach $repoCases {
        $folder = Join-Path $fixturesRoot 'repos' $Name
        $hasCatalog = Test-Path -LiteralPath (Join-Path $folder 'catalog' 'diagnostics.json') -PathType Leaf
        if ($Kind -eq 'complete') {
            # Complete on disk: New-FixtureRepo copies the folder alone, and it holds its generated endpoints.
            $Name -in $CompleteFixtures | Should-BeTrue
            $hasCatalog | Should-BeTrue
            Test-Path -LiteralPath (Join-Path $folder 'rulesets') -PathType Container | Should-BeTrue
        } else {
            # An overlay holds only the files it changes; without a catalog it cannot stand alone.
            $Name -in $CompleteFixtures | Should-BeFalse
            $hasCatalog | Should-BeFalse
        }
    }

    It '<Name> reports exactly <FindingsText>' -ForEach $repoCases {
        $root = New-FixtureRepo -Name $Name -Destination (Get-TestFolder)
        Should-BeCollection -Actual (Get-UniqueFinding -Root $root) -Expected ([string[]]$Findings)
    }

    It '<Name> regenerates to <RegenerateText>' -ForEach $repoCases {
        $root = New-FixtureRepo -Name $Name -Destination (Get-TestFolder)
        if ($null -ne $Throws) {
            { Get-RulebookEndpointChange -RepositoryRoot $root } | Should-Throw -ExceptionMessage $Throws
        } else {
            $changes = [string[]]@(Get-RulebookEndpointChange -RepositoryRoot $root | ForEach-Object { '{0} {1}' -f $_.File, $_.Change })
            Should-BeCollection -Actual $changes -Expected ([string[]]$Regenerate)
        }
    }
}

Describe 'Template fixtures' {
    It '<Name> validates without errors' -ForEach @(
        @{ Name = 'templates/v1'; Path = (Join-Path $PSScriptRoot 'fixtures' 'templates' 'v1') }
        @{ Name = 'templates/v2'; Path = (Join-Path $PSScriptRoot 'fixtures' 'templates' 'v2') }
        @{ Name = 'repos/update-org'; Path = (Join-Path $PSScriptRoot 'fixtures' 'repos' 'update-org') }
    ) {
        @(Test-Rulebook -RepositoryRoot $Path | Where-Object Severity -EQ 'error') | Should-BeCollection @()
    }

    It 'v1 and v2 differ in exactly the paths the README lists' {
        $readme = [System.IO.File]::ReadAllText((Join-Path $templates 'README.md'))
        $section = [regex]::Match($readme, '(?ms)^## v2\n(.*?)^## ').Groups[1].Value
        [string[]]$listed = @([regex]::Matches($section, '(?m)^\| `([^`]+)` \|') | ForEach-Object { $_.Groups[1].Value })
        [System.Array]::Sort($listed, [System.StringComparer]::Ordinal)
        $one = Get-RelativeFileList -Root $v1
        $two = Get-RelativeFileList -Root $v2
        [string[]]$differing = @(@($one) + @($two) | Sort-Object -Unique -CaseSensitive | Where-Object {
                $a = Join-Path $v1 $_
                $b = Join-Path $v2 $_
                -not (Test-Path -LiteralPath $a) -or -not (Test-Path -LiteralPath $b) -or
                -not [System.Linq.Enumerable]::SequenceEqual([byte[]][System.IO.File]::ReadAllBytes($a), [byte[]][System.IO.File]::ReadAllBytes($b))
            })
        [System.Array]::Sort($differing, [System.StringComparer]::Ordinal)
        $listed.Count | Should-BeGreaterThan 0
        $differing | Should-BeCollection $listed
    }

    It 'the generated folders of v1, v2 and update-org equal what the engine writes' {
        foreach ($root in $v1, $v2, $orgFixture) {
            $copy = Get-TestFolder
            Copy-FixtureTree -Source $root -Destination $copy
            @(New-RulebookSkeleton -SettingsPath (Join-Path $copy '.github' 'Rulebook-Settings.json') -OutputPath (Join-Path $copy 'skeletons') -WhatIf:$false) | Should-BeCollection @()
            @(Update-RulebookEndpoints -RepositoryRoot $copy) | Should-BeCollection @()
        }
    }
}

Describe 'Fixture folders' {
    BeforeAll {
        # Where a fixture folder can be used: the suites (this one aside, it lists every folder), the helpers and the
        # CI workflow (scan-org is used by the scan-action job only).
        $sources = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.Tests.ps1' -File | Where-Object Name -NE 'Fixtures.Tests.ps1') +
        @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'Helpers') -Filter '*.ps1' -File) +
        @(Get-Item -LiteralPath (Join-Path $repoRoot '.github' 'workflows' 'ci.yml'))
        $script:sourceText = ($sources | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) }) -join "`n"
        $script:tableNames = [string[]]@($repoCases | ForEach-Object { $_.Name })
    }

    It 'repos/<Name> has a row in the fixture table' -ForEach $repoFolderCases {
        $Name -cin $tableNames | Should-BeTrue
    }

    It 'every row of the fixture table names a folder under repos/' {
        foreach ($name in $tableNames) {
            Test-Path -LiteralPath (Join-Path $fixturesRoot 'repos' $name) -PathType Container | Should-BeTrue -Because "the table lists $name"
        }
    }

    It '<Group>/<Name> is used by a suite, a helper or ci.yml' -ForEach $folderCases {
        # A use is the quoted name ('v1', "v1") or a path to the folder (templates/v1, 'templates' 'v1',
        # 'templates', 'v1'), not the bare word, which comments and unrelated text contain too.
        $name = [regex]::Escape($Name)
        $group = [regex]::Escape($Group)
        $pattern = "(['`"])$name\1|$group/$name(?![\w-])|'$group',?\s+'$name'"
        $sourceText | Should-MatchString $pattern
    }
}
