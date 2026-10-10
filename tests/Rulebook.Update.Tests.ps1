# Update suite for WP07 (#9): modules/Rulebook.Update on the template fixtures tests/fixtures/templates/v1 and v2 and
# the organization fixture tests/fixtures/repos/update-org (derivation in tests/fixtures/templates/README.md). The
# GitHub API is mocked at Invoke-GitHubApi; the git side of Publish-RulebookUpdate runs against a bare repository.

BeforeDiscovery {
    $script:gitMissing = $null -eq (Get-Command git -ErrorAction SilentlyContinue)
}

BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $PSScriptRoot 'Helpers' 'RepoFixture.ps1')
    Import-Module (Join-Path $repoRoot 'modules' 'Rulebook.Generate.psd1') -Force
    Import-Module (Join-Path $repoRoot 'modules' 'Rulebook.Validate.psd1') -Force
    Import-Module (Join-Path $repoRoot 'modules' 'Rulebook.Template.psd1') -Force
    Import-Module (Join-Path $repoRoot 'modules' 'Rulebook.GitHub.psd1') -Force
    Import-Module (Join-Path $repoRoot 'modules' 'Rulebook.Update.psd1') -Force
    $script:templates = Join-Path $PSScriptRoot 'fixtures' 'templates'
    $script:v1 = Join-Path $templates 'v1'
    $script:v2 = Join-Path $templates 'v2'
    $script:orgFixture = Join-Path $PSScriptRoot 'fixtures' 'repos' 'update-org'
    $script:fakeSha = '0123456789abcdef0123456789abcdef01234567'
    $script:utf8 = [System.Text.UTF8Encoding]::new($false)
    $script:savedApiUrl = $env:GITHUB_API_URL
    $script:savedServerUrl = $env:GITHUB_SERVER_URL
    $env:GITHUB_API_URL = $null
    $env:GITHUB_SERVER_URL = $null

    function Get-TestFolder {
        return Join-Path $TestDrive ([guid]::NewGuid().ToString('n').Substring(0, 12))
    }

    function Copy-Org {
        # A writable copy of update-org; -WithLegacy puts back the two files the first update removed.
        param([switch]$WithLegacy)
        $root = New-FixtureRepo -Name 'update-org' -Destination (Get-TestFolder)
        if ($WithLegacy) {
            Copy-Item -LiteralPath (Join-Path $v1 '.github' 'workflows' 'Legacy.yaml') -Destination (Join-Path $root '.github' 'workflows' 'Legacy.yaml')
            Copy-Item -LiteralPath (Join-Path $v1 'site' 'layouts' 'legacy.html') -Destination (Join-Path $root 'site' 'layouts' 'legacy.html')
        }
        return $root
    }

    function Get-Plan {
        # The plan of Org against the template folder Template, with Installed as the installed template (none with '').
        param([string]$Org = $script:orgFixture, [string]$Template = $script:v2, [string]$Installed = $script:v1, [string]$TemplateSha)
        $parameters = @{ TemplatePath = $Template; TemplateUrl = 'https://github.com/Contoso/rulebook-template@main' }
        if ($Installed) { $parameters.InstalledTemplatePath = $Installed }
        if ($TemplateSha) { $parameters.TemplateSha = $TemplateSha }
        $info = Get-RulebookTemplate @parameters
        return Get-RulebookUpdatePlan -RepositoryRoot $Org -Template $info -WorkPath (Get-TestFolder)
    }

    function Get-ChangeList {
        param($Plan)
        return @($Plan.Changes | ForEach-Object { '{0} {1}' -f $_.Change, $_.File })
    }

    function Get-CandidateText {
        param($Plan, [string]$Path)
        return [System.IO.File]::ReadAllText((Join-Path $Plan.CandidatePath $Path), $utf8)
    }

    function Edit-OrgSetting {
        param([string]$Root, [scriptblock]$Script)
        Edit-FixtureJson -Path (Join-Path $Root '.github' 'Rulebook-Settings.json') -Script $Script
    }

    function Test-SameContent {
        param([string]$Left, [string]$Right)
        return [System.Linq.Enumerable]::SequenceEqual([byte[]][System.IO.File]::ReadAllBytes($Left), [byte[]][System.IO.File]::ReadAllBytes($Right))
    }

    function Assert-ItemPresent {
        # Every item of Expected is in Actual, in any order.
        param([string[]]$Actual, [string[]]$Expected)
        foreach ($item in $Expected) { $item -cin $Actual | Should-BeTrue -Because "'$item' is expected in: $($Actual -join '; ')" }
    }

    function Get-RelativeFileList {
        param([string]$Root)
        [string[]]$files = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force | ForEach-Object { [System.IO.Path]::GetRelativePath($Root, $_.FullName).Replace('\', '/') } | Where-Object { -not $_.StartsWith('.git/') })
        [System.Array]::Sort($files, [System.StringComparer]::Ordinal)
        return $files
    }
}

AfterAll {
    $env:GITHUB_API_URL = $script:savedApiUrl
    $env:GITHUB_SERVER_URL = $script:savedServerUrl
    Remove-Module Rulebook.Update, Rulebook.GitHub, Rulebook.Template, Rulebook.Validate, Rulebook.Generate, Rulebook.Action, Rulebook.Common -ErrorAction SilentlyContinue
}

Describe 'Fixture consistency' {
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

    It 'the generated folders equal what the engine writes' {
        foreach ($root in $v1, $v2, $orgFixture) {
            $copy = Get-TestFolder
            Copy-FixtureTree -Source $root -Destination $copy
            @(New-RulebookSkeleton -SettingsPath (Join-Path $copy '.github' 'Rulebook-Settings.json') -OutputPath (Join-Path $copy 'skeletons') -WhatIf:$false) | Should-BeCollection @()
            @(Update-RulebookEndpoints -RepositoryRoot $copy) | Should-BeCollection @()
        }
    }
}

Describe 'ConvertTo-TemplateUrl' {
    It 'normalises <Value>' -ForEach @(
        @{ Value = 'ALCops/rulebook'; Url = 'https://github.com/ALCops/rulebook@main'; Branch = 'main' }
        @{ Value = 'ALCops/rulebook@v1'; Url = 'https://github.com/ALCops/rulebook@v1'; Branch = 'v1' }
        @{ Value = 'https://github.com/ALCops/rulebook'; Url = 'https://github.com/ALCops/rulebook@main'; Branch = 'main' }
        @{ Value = 'https://www.github.com/ALCops/rulebook@main'; Url = 'https://github.com/ALCops/rulebook@main'; Branch = 'main' }
        @{ Value = ' https://github.com/Contoso/rulebook-template@release/v2 '; Url = 'https://github.com/Contoso/rulebook-template@release/v2'; Branch = 'release/v2' }
    ) {
        $result = ConvertTo-TemplateUrl -Url $Value
        $result.Url | Should-Be $Url
        $result.Branch | Should-Be $Branch
        $result.Repo | Should-Be ($Url -replace '^https://github\.com/([^@]+)@.*$', '$1')
    }

    It 'rejects <Value>' -ForEach @(
        @{ Value = 'rulebook' }
        @{ Value = 'https://gitlab.com/ALCops/rulebook@main' }
        @{ Value = 'http://github.com/ALCops/rulebook' }
        @{ Value = 'ALCops/rulebook@main@v1' }
        @{ Value = 'ALCops/rule book' }
    ) {
        { ConvertTo-TemplateUrl -Url $Value } | Should-Throw -ExceptionMessage "*'$Value'*"
    }

    It 'rejects an empty value' {
        { ConvertTo-TemplateUrl -Url '' } | Should-Throw -ExceptionMessage '*empty*'
    }
}

Describe 'Get-RulebookFileClass' {
    BeforeAll {
        [string[]]$script:v2Paths = Get-RelativeFileList -Root $v2
        $script:settings = @{ site = @{ updateMode = 'skip' } }
    }

    It 'classifies the v2 path <Path> as <Class>' -ForEach @(
        @{ Path = '.github/Rulebook-Settings.json'; Class = 'settings' }
        @{ Path = '.github/RELEASENOTES.copy.md'; Class = 'overwrite' }
        @{ Path = '.github/workflows/ChangeRule.yaml'; Class = 'overwrite' }
        @{ Path = '.github/workflows/Publish.yaml'; Class = 'overwrite' }
        @{ Path = '.github/workflows/UpdateRulebookSystemFiles.yaml'; Class = 'overwrite' }
        @{ Path = '.github/workflows/Validate.yaml'; Class = 'overwrite' }
        @{ Path = 'README.md'; Class = 'org-owned' }
        @{ Path = 'base/complete.ruleset.json'; Class = 'overwrite' }
        @{ Path = 'base/essential.ruleset.json'; Class = 'overwrite' }
        @{ Path = 'base/recommended.ruleset.json'; Class = 'overwrite' }
        @{ Path = 'base/strict.ruleset.json'; Class = 'overwrite' }
        @{ Path = 'base/twins.json'; Class = 'overwrite' }
        @{ Path = 'catalog/diagnostics.json'; Class = 'org-owned' }
        @{ Path = 'docs/README.md'; Class = 'customizable' }
        @{ Path = 'docs/getting-started.md'; Class = 'customizable' }
        @{ Path = 'docs/images/badge.png'; Class = 'customizable' }
        @{ Path = 'docs/images/logo.png'; Class = 'customizable' }
        @{ Path = 'overrides.json'; Class = 'org-owned' }
        @{ Path = 'quarantine.ci.json'; Class = 'org-owned' }
        @{ Path = 'quarantine.default.json'; Class = 'org-owned' }
        @{ Path = 'quarantine.vnext.json'; Class = 'org-owned' }
        @{ Path = 'rulesets/strict.ci.ruleset.json'; Class = 'generated' }
        @{ Path = 'site/config.yaml'; Class = 'customizable' }
        @{ Path = 'site/layouts/footer.html'; Class = 'customizable' }
        @{ Path = 'site/static/logo.png'; Class = 'customizable' }
        @{ Path = 'skeletons/README.md'; Class = 'overwrite' }
        @{ Path = 'skeletons/strict.default.ruleset.json'; Class = 'generated' }
        @{ Path = 'stages/ci.json'; Class = 'overwrite' }
        @{ Path = 'stages/vnext.json'; Class = 'overwrite' }
    ) {
        $Path -cin $v2Paths | Should-BeTrue -Because 'the case is a v2 path'
        (Get-RulebookFileClass -Path $Path -TemplatePaths $v2Paths -Settings $settings).Class | Should-Be $Class
    }

    It 'gives every v2 path one of the five classes' {
        foreach ($path in $v2Paths) {
            (Get-RulebookFileClass -Path $path -TemplatePaths $v2Paths -Settings $settings).Class -cin @('settings', 'overwrite', 'generated', 'customizable', 'org-owned') | Should-BeTrue -Because $path
        }
    }

    It 'treats the organization path <Path> as <Class>' -ForEach @(
        @{ Path = 'base/house.ruleset.json'; Class = 'org-owned' }
        @{ Path = 'base/paranoid.ruleset.json'; Class = 'org-owned' }
        @{ Path = 'stages/nightly.json'; Class = 'org-owned' }
        @{ Path = '.github/workflows/MyNightly.yaml'; Class = 'org-owned' }
        @{ Path = 'site/data/rules.json'; Class = 'org-owned' }
        @{ Path = 'docs/notes.md'; Class = 'org-owned' }
        @{ Path = 'rulesets/house.ruleset.json'; Class = 'generated' }
        @{ Path = 'skeletons/house.ci.ruleset.json'; Class = 'generated' }
    ) {
        (Get-RulebookFileClass -Path $Path -TemplatePaths $v2Paths -Settings $settings).Class | Should-Be $Class
    }

    It 'makes site/** overwrite with site.updateMode overwrite, never site/data/**' {
        $overwrite = @{ site = @{ updateMode = 'overwrite' } }
        (Get-RulebookFileClass -Path 'site/layouts/index.html' -TemplatePaths $v2Paths -Settings $overwrite).Class | Should-Be 'overwrite'
        (Get-RulebookFileClass -Path 'site/data/x.json' -TemplatePaths @('site/data/x.json') -Settings $overwrite).Class | Should-Be 'org-owned'
        (Get-RulebookFileClass -Path 'docs/README.md' -TemplatePaths $v2Paths -Settings $overwrite).Class | Should-Be 'customizable'
    }

    It 'gives docs/** the kind docs and README.md stays org-owned (D50)' {
        Get-RulebookFileClass -Path 'docs/images/logo.png' -TemplatePaths $v2Paths -Settings $settings | Should-BeEquivalent ([pscustomobject]@{ Class = 'customizable'; Kind = 'docs' })
        Get-RulebookFileClass -Path 'README.md' -TemplatePaths $v2Paths -Settings $settings | Should-BeEquivalent ([pscustomobject]@{ Class = 'org-owned'; Kind = 'org' })
        (Get-RulebookFileClass -Path 'docs/README.md' -TemplatePaths $v2Paths -Settings $null).Class | Should-Be 'customizable'
    }

    It 'makes docs/** overwrite with docs.updateMode overwrite and leaves site/** alone' {
        $overwrite = @{ site = @{ updateMode = 'skip' }; docs = @{ updateMode = 'overwrite' } }
        Get-RulebookFileClass -Path 'docs/getting-started.md' -TemplatePaths $v2Paths -Settings $overwrite | Should-BeEquivalent ([pscustomobject]@{ Class = 'overwrite'; Kind = 'docs' })
        (Get-RulebookFileClass -Path 'site/layouts/index.html' -TemplatePaths $v2Paths -Settings $overwrite).Class | Should-Be 'customizable'
    }
}

Describe 'Update-RulebookSettingsText' {
    BeforeAll {
        $script:schema = 'https://raw.githubusercontent.com/ALCops/rulebook-engine/v1/schemas/rulebook-settings.schema.json'
        $script:url = 'https://github.com/Contoso/rulebook-template@main'
    }

    It 'changes only the three values, byte for byte, and keeps unknown keys' {
        $text = "{`n  `"`$schema`": `"https://example.invalid/old.json`",`n  `"templateUrl`": `"ALCops/rulebook`",`n  `"templateSha`": `"`",`n  `"baseUrl`": `"https://contoso.github.io/rulebook`",`n  `"site`":   { `"enabled`": true },`n  `"futureKey`": [1, 2]`n}`n"
        $expected = "{`n  `"`$schema`": `"$schema`",`n  `"templateUrl`": `"$url`",`n  `"templateSha`": `"$fakeSha`",`n  `"baseUrl`": `"https://contoso.github.io/rulebook`",`n  `"site`":   { `"enabled`": true },`n  `"futureKey`": [1, 2]`n}`n"
        Update-RulebookSettingsText -Text $text -SchemaUrl $schema -TemplateUrl $url -TemplateSha $fakeSha | Should-Be $expected
    }

    It 'inserts templateSha after the templateUrl line' {
        $text = "{`n  `"`$schema`": `"$schema`",`n    `"templateUrl`": `"$url`",`n  `"baseUrl`": `"`"`n}`n"
        $expected = "{`n  `"`$schema`": `"$schema`",`n    `"templateUrl`": `"$url`",`n    `"templateSha`": `"$fakeSha`",`n  `"baseUrl`": `"`"`n}`n"
        Update-RulebookSettingsText -Text $text -SchemaUrl $schema -TemplateUrl $url -TemplateSha $fakeSha | Should-Be $expected
    }

    It 'inserts templateSha on the same line in a minified file' {
        $text = '{"$schema":"' + $schema + '","templateUrl":"' + $url + '","baseUrl":""}'
        $expected = '{"$schema":"' + $schema + '","templateUrl":"' + $url + '","templateSha":"' + $fakeSha + '","baseUrl":""}'
        Update-RulebookSettingsText -Text $text -SchemaUrl $schema -TemplateUrl $url -TemplateSha $fakeSha | Should-Be $expected
    }

    It 'inserts $schema as the first property when it is absent' {
        $text = "{`n  `"templateUrl`": `"$url`",`n  `"templateSha`": `"`"`n}`n"
        $expected = "{`n  `"`$schema`": `"$schema`",`n  `"templateUrl`": `"$url`",`n  `"templateSha`": `"$fakeSha`"`n}`n"
        Update-RulebookSettingsText -Text $text -SchemaUrl $schema -TemplateUrl $url -TemplateSha $fakeSha | Should-Be $expected
    }

    It 'inserts $schema into a minified file' {
        $text = '{"templateUrl":"' + $url + '"}'
        $expected = '{"$schema":"' + $schema + '","templateUrl":"' + $url + '","templateSha":"' + $fakeSha + '"}'
        Update-RulebookSettingsText -Text $text -SchemaUrl $schema -TemplateUrl $url -TemplateSha $fakeSha | Should-Be $expected
    }

    It 'keeps $schema when the template has none' {
        $text = "{`n  `"`$schema`": `"https://example.invalid/own.json`",`n  `"templateUrl`": `"$url`",`n  `"templateSha`": `"`"`n}`n"
        Update-RulebookSettingsText -Text $text -SchemaUrl '' -TemplateUrl $url -TemplateSha $fakeSha | Should-MatchString 'example\.invalid/own\.json'
    }

    It 'turns CRLF into LF and the result parses' {
        $text = "{`r`n  `"templateUrl`": `"$url`",`r`n  `"templateSha`": `"`"`r`n}`r`n"
        $result = Update-RulebookSettingsText -Text $text -SchemaUrl $schema -TemplateUrl $url -TemplateSha $fakeSha
        $result.Contains("`r") | Should-BeFalse
        ($result | ConvertFrom-Json).templateSha | Should-Be $fakeSha
    }

    It 'throws without templateUrl' {
        { Update-RulebookSettingsText -Text '{ "baseUrl": "" }' -SchemaUrl $schema -TemplateUrl $url -TemplateSha $fakeSha } | Should-Throw -ExceptionMessage '*No templateUrl*'
    }
}

Describe 'ConvertTo-UpdatedWorkflowText' {
    BeforeAll {
        $script:orgSettings = Get-Content -LiteralPath (Join-Path $orgFixture '.github' 'Rulebook-Settings.json') -Raw | ConvertFrom-Json -AsHashtable
        $script:updateText = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'template' '.github' 'workflows' 'UpdateRulebookSystemFiles.yaml'))
        $script:scanText = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'template' '.github' 'workflows' 'ScanDiagnostics.yaml')).Replace("`r`n", "`n")
        $script:withoutSchedule = @{ levels = $orgSettings.levels; stages = $orgSettings.stages; update = @{ schedule = $null } }
        $script:url = 'https://github.com/Contoso/rulebook-template@main'
    }

    It 'replaces {TEMPLATEURL}' {
        $result = ConvertTo-UpdatedWorkflowText -Text $updateText -FileName 'UpdateRulebookSystemFiles.yaml' -Settings $withoutSchedule -TemplateUrl $url
        $result | Should-Be $updateText.Replace('{TEMPLATEURL}', $url)
    }

    It 'rewrites the levels and stages choice lists of ChangeRule.yaml from the settings (AC4)' {
        $text = [System.IO.File]::ReadAllText((Join-Path $v2 '.github' 'workflows' 'ChangeRule.yaml'))
        $result = ConvertTo-UpdatedWorkflowText -Text $text -FileName 'ChangeRule.yaml' -Settings $orgSettings -TemplateUrl $url
        $levels = [regex]::Match($result, "(?m)^      levels:\n(?:.*\n)*?        options:\n((?:          - .*\n)+)").Groups[1].Value
        @($levels.TrimEnd("`n").Split("`n") | ForEach-Object { $_.Trim().Substring(2) }) | Should-BeCollection @("'*'", 'essential', 'recommended', 'house', 'strict', 'complete')
        $stages = [regex]::Match($result, "(?m)^      stages:\n(?:.*\n)*?        options:\n((?:          - .*\n)+)").Groups[1].Value
        @($stages.TrimEnd("`n").Split("`n") | ForEach-Object { $_.Trim().Substring(2) }) | Should-BeCollection @("'*'", 'default', 'ci', 'vnext')
        # Everything outside the two lists is the template text.
        $result.Replace("          - house`n", '') | Should-Be $text
    }

    It 'rewrites the shipped ChangeRule.yaml: a no-op with the template settings, house in settings order with it (WP09)' {
        $text = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'template' '.github' 'workflows' 'ChangeRule.yaml')).Replace("`r`n", "`n")
        $templateSettings = Get-Content -LiteralPath (Join-Path $repoRoot 'template' '.github' 'Rulebook-Settings.json') -Raw | ConvertFrom-Json -AsHashtable
        ConvertTo-UpdatedWorkflowText -Text $text -FileName 'ChangeRule.yaml' -Settings $templateSettings -TemplateUrl $url | Should-Be $text
        $house = @{ levels = @(@{ name = 'Essential' }, @{ name = 'Recommended' }, @{ name = 'House' }, @{ name = 'Strict' }, @{ name = 'Complete' }); stages = $templateSettings.stages }
        $result = ConvertTo-UpdatedWorkflowText -Text $text -FileName 'ChangeRule.yaml' -Settings $house -TemplateUrl $url
        $result | Should-Be $text.Replace("          - recommended`n", "          - recommended`n          - house`n")
    }

    It 'quotes a slug YAML would read as another type' {
        $text = [System.IO.File]::ReadAllText((Join-Path $v1 '.github' 'workflows' 'ChangeRule.yaml'))
        $settings = @{ levels = @(@{ name = 'Yes' }, @{ name = '2026' }); stages = @(@{ name = 'default' }) }
        $result = ConvertTo-UpdatedWorkflowText -Text $text -FileName 'ChangeRule.yaml' -Settings $settings -TemplateUrl $url
        $result | Should-MatchString "(?m)^          - 'yes'$"
        $result | Should-MatchString "(?m)^          - '2026'$"
    }

    It 'adds the schedule under on: and removes it again, byte for byte' {
        $settings = @{ update = @{ schedule = '0 6 * * 1' } }
        $base = $updateText.Replace('{TEMPLATEURL}', $url)
        $added = ConvertTo-UpdatedWorkflowText -Text $updateText -FileName 'UpdateRulebookSystemFiles.yaml' -Settings $settings -TemplateUrl $url
        $expected = $base.Replace("        default: false`n`n# The workflow token", "        default: false`n  schedule:`n    - cron: '0 6 * * 1'`n`n# The workflow token")
        $added | Should-Be $expected
        ConvertTo-UpdatedWorkflowText -Text $added -FileName 'UpdateRulebookSystemFiles.yaml' -Settings @{ update = @{ schedule = $null } } -TemplateUrl $url | Should-Be $base
        ConvertTo-UpdatedWorkflowText -Text $added -FileName 'UpdateRulebookSystemFiles.yaml' -Settings @{} -TemplateUrl $url | Should-Be $base
    }

    It 'replaces an existing schedule' {
        $added = ConvertTo-UpdatedWorkflowText -Text $updateText -FileName 'UpdateRulebookSystemFiles.yaml' -Settings @{ update = @{ schedule = '0 6 * * 1' } } -TemplateUrl $url
        $replaced = ConvertTo-UpdatedWorkflowText -Text $added -FileName 'UpdateRulebookSystemFiles.yaml' -Settings @{ update = @{ schedule = '30 5 * * *' } } -TemplateUrl $url
        $replaced | Should-Be $added.Replace("- cron: '0 6 * * 1'", "- cron: '30 5 * * *'")
    }

    It 'leaves the schedule of another workflow alone' {
        $text = [System.IO.File]::ReadAllText((Join-Path $orgFixture '.github' 'workflows' 'MyNightly.yaml'))
        ConvertTo-UpdatedWorkflowText -Text $text -FileName 'MyNightly.yaml' -Settings @{ update = @{ schedule = $null } } -TemplateUrl $url | Should-Be $text
    }

    It 'leaves a workflow without inputs or placeholder unchanged' {
        $text = [System.IO.File]::ReadAllText((Join-Path $v2 '.github' 'workflows' 'Validate.yaml'))
        ConvertTo-UpdatedWorkflowText -Text $text -FileName 'Validate.yaml' -Settings $orgSettings -TemplateUrl $url | Should-Be $text
    }

    It 'leaves the template ScanDiagnostics.yaml unchanged with the template settings (WP08)' {
        $templateSettings = Get-Content -LiteralPath (Join-Path $repoRoot 'template' '.github' 'Rulebook-Settings.json') -Raw | ConvertFrom-Json -AsHashtable
        ConvertTo-UpdatedWorkflowText -Text $scanText -FileName 'ScanDiagnostics.yaml' -Settings $templateSettings -TemplateUrl $url | Should-Be $scanText
    }

    It 'replaces the scan schedule from scan.schedule' {
        $result = ConvertTo-UpdatedWorkflowText -Text $scanText -FileName 'ScanDiagnostics.yaml' -Settings @{ scan = @{ schedule = '5 3 * * 1-5' } } -TemplateUrl $url
        $result | Should-Be $scanText.Replace("- cron: '17 4 * * *'", "- cron: '5 3 * * 1-5'")
    }

    It 'removes the scan schedule byte for byte when scan.schedule is null' {
        $result = ConvertTo-UpdatedWorkflowText -Text $scanText -FileName 'ScanDiagnostics.yaml' -Settings @{ scan = @{ schedule = $null } } -TemplateUrl $url
        $result | Should-Be $scanText.Replace("  schedule:`n    - cron: '17 4 * * *'`n", '')
        ConvertTo-UpdatedWorkflowText -Text $result -FileName 'ScanDiagnostics.yaml' -Settings @{ scan = @{ schedule = '17 4 * * *' } } -TemplateUrl $url | Should-Be $scanText
    }

    It 'keeps the shipped scan schedule when the settings have <Case> (an organization from before WP08)' -ForEach @(
        @{ Case = 'no scan key'; Settings = @{ update = @{ schedule = $null } } }
        @{ Case = 'a scan key without schedule'; Settings = @{ scan = @{} } }
    ) {
        ConvertTo-UpdatedWorkflowText -Text $scanText -FileName 'ScanDiagnostics.yaml' -Settings $Settings -TemplateUrl $url | Should-Be $scanText
    }

    It 'still removes the update schedule when update.schedule is absent' {
        $added = ConvertTo-UpdatedWorkflowText -Text $updateText -FileName 'UpdateRulebookSystemFiles.yaml' -Settings @{ update = @{ schedule = '0 6 * * 1' } } -TemplateUrl $url
        ConvertTo-UpdatedWorkflowText -Text $added -FileName 'UpdateRulebookSystemFiles.yaml' -Settings @{} -TemplateUrl $url | Should-Be $updateText.Replace('{TEMPLATEURL}', $url)
    }

    It 'never crosses the two schedule keys' {
        $settings = @{ update = @{ schedule = '0 6 * * 1' }; scan = @{ schedule = $null } }
        ConvertTo-UpdatedWorkflowText -Text $scanText -FileName 'ScanDiagnostics.yaml' -Settings $settings -TemplateUrl $url | Should-NotMatchString 'cron'
        ConvertTo-UpdatedWorkflowText -Text $updateText -FileName 'UpdateRulebookSystemFiles.yaml' -Settings @{ update = @{ schedule = $null }; scan = @{ schedule = '17 4 * * *' } } -TemplateUrl $url | Should-NotMatchString 'cron'
    }

    It 'leaves an unknown workflow with a schedule untouched by scan.schedule' {
        $text = [System.IO.File]::ReadAllText((Join-Path $orgFixture '.github' 'workflows' 'MyNightly.yaml'))
        ConvertTo-UpdatedWorkflowText -Text $text -FileName 'MyNightly.yaml' -Settings @{ scan = @{ schedule = $null } } -TemplateUrl $url | Should-Be $text
    }
}

Describe 'Get-ReleaseNotesDelta' {
    It 'cuts the new notes at the first version heading of the installed copy' {
        $new = "# Release notes`n`n## v1.1`n`n- New.`n`n## v1.0`n`n- First.`n"
        Get-ReleaseNotesDelta -New $new -Installed "# Release notes`n`n## v1.0`n`n- First.`n" | Should-Be "# Release notes`n`n## v1.1`n`n- New.`n"
    }

    It 'gives the whole text without an installed copy' {
        Get-ReleaseNotesDelta -New "## v1.0`n- First.`n" -Installed $null | Should-Be "## v1.0`n- First.`n"
    }

    It 'gives the whole text when the installed copy has no version heading' {
        Get-ReleaseNotesDelta -New "## v1.1`n- New.`n## v1.0`n" -Installed "Notes without headings`n" | Should-Be "## v1.1`n- New.`n## v1.0`n"
    }

    It 'gives an empty text when nothing is new and $null for empty notes' {
        $same = "# Release notes`n`n## v1.0`n`n- First.`n"
        Get-ReleaseNotesDelta -New $same -Installed $same | Should-Be ''
        Get-ReleaseNotesDelta -New '' -Installed $same | Should-BeNull
    }
}

Describe 'Compare-CustomizableFile' {
    It '<Name> gives <Decision>' -ForEach @(
        @{ Name = 'org equal to old, new changed'; Org = 'a'; Old = 'a'; New = 'b'; Mode = 'skip'; Decision = 'overwrite' }
        @{ Name = 'org changed, new equal to old'; Org = 'x'; Old = 'a'; New = 'a'; Mode = 'skip'; Decision = 'keep' }
        @{ Name = 'both changed'; Org = 'x'; Old = 'a'; New = 'b'; Mode = 'skip'; Decision = 'skip' }
        @{ Name = 'org absent, new file'; Org = $null; Old = $null; New = 'b'; Mode = 'skip'; Decision = 'add' }
        @{ Name = 'not shipped by the new template'; Org = 'a'; Old = 'a'; New = $null; Mode = 'skip'; Decision = 'none' }
        @{ Name = 'org equal to new'; Org = 'b'; Old = 'a'; New = 'b'; Mode = 'skip'; Decision = 'none' }
        @{ Name = 'no installed template, org differs'; Org = 'x'; Old = $null; New = 'b'; Mode = 'skip'; Decision = 'skip' }
        @{ Name = 'no installed template, org equal'; Org = 'b'; Old = $null; New = 'b'; Mode = 'skip'; Decision = 'none' }
        @{ Name = 'overwrite mode, both changed'; Org = 'x'; Old = 'a'; New = 'b'; Mode = 'overwrite'; Decision = 'overwrite' }
        @{ Name = 'overwrite mode, org changed only'; Org = 'x'; Old = 'a'; New = 'a'; Mode = 'overwrite'; Decision = 'overwrite' }
        @{ Name = 'overwrite mode, no installed template'; Org = 'x'; Old = $null; New = 'b'; Mode = 'overwrite'; Decision = 'overwrite' }
        @{ Name = 'overwrite mode, org absent'; Org = $null; Old = 'a'; New = 'b'; Mode = 'overwrite'; Decision = 'add' }
    ) {
        Compare-CustomizableFile -Org $Org -Old $Old -New $New -UpdateMode $Mode | Should-Be $Decision
    }
}

Describe 'Get-RulebookUpdatePlan: update-org against v2 (installed v1)' {
    BeforeAll {
        $script:plan = Get-Plan
        $script:changes = Get-ChangeList $plan
    }

    It 'is valid and has updates' {
        $plan.Valid | Should-BeTrue
        $plan.UpdatesAvailable | Should-BeTrue
        $plan.ShaOnly | Should-BeFalse
    }

    It 'changes exactly the expected files' {
        $expected = @(
            'modified .github/RELEASENOTES.copy.md'
            'modified .github/Rulebook-Settings.json'
            'modified .github/workflows/ChangeRule.yaml'
            'modified base/recommended.ruleset.json'
            'created docs/images/badge.png'
            'modified rulesets/complete.ci.ruleset.json'
            'modified rulesets/complete.ruleset.json'
            'modified rulesets/complete.vnext.ruleset.json'
            'modified rulesets/house.ci.ruleset.json'
            'modified rulesets/house.ruleset.json'
            'modified rulesets/house.vnext.ruleset.json'
            'modified rulesets/recommended.ci.ruleset.json'
            'modified rulesets/recommended.ruleset.json'
            'modified rulesets/recommended.vnext.ruleset.json'
            'modified rulesets/strict.ci.ruleset.json'
            'modified rulesets/strict.ruleset.json'
            'modified rulesets/strict.vnext.ruleset.json'
            'created site/layouts/footer.html'
            'modified site/layouts/rule.html'
            'modified skeletons/README.md'
            'modified stages/ci.json'
        )
        $changes | Should-BeCollection $expected
    }

    It 'leaves the essential endpoints alone: only the levels chained above Recommended move (AC2)' {
        @($changes | Where-Object { $_ -like '* rulesets/essential*' }) | Should-BeCollection @()
    }

    It 'never touches overrides.json, the quarantine files, MyNightly.yaml, base/house.ruleset.json or catalog/ (AC7)' {
        foreach ($path in 'overrides.json', 'quarantine.ci.json', '.github/workflows/MyNightly.yaml', 'base/house.ruleset.json', 'catalog/diagnostics.json', 'README.md') {
            @($plan.Changes | Where-Object File -CEQ $path) | Should-BeCollection @() -Because $path
            Test-SameContent -Left (Join-Path $plan.CandidatePath $path) -Right (Join-Path $orgFixture $path) | Should-BeTrue -Because $path
        }
    }

    It 'keeps the override on AL0200 in the regenerated endpoints although v2 moved it in Recommended (AC6)' {
        $endpoint = Get-CandidateText -Plan $plan -Path 'rulesets/recommended.ruleset.json' | ConvertFrom-Json
        @($endpoint.rules | Where-Object id -EQ 'AL0200').action | Should-Be 'Info'
        @($endpoint.rules | Where-Object id -EQ 'AC0001').action | Should-Be 'Error'
    }

    It 'skips the site and docs files changed on both sides and lists them, keeps style.css' {
        @($plan.Skipped | ForEach-Object { "$($_.File) $($_.Kind) $($_.Reason)" }) | Should-BeCollection @('docs/getting-started.md docs local changes', 'site/layouts/index.html site local changes')
        Get-CandidateText -Plan $plan -Path 'docs/getting-started.md' | Should-BeLikeString '*Tell the platform team.*'
        Get-CandidateText -Plan $plan -Path 'site/layouts/index.html' | Should-BeLikeString '*Contoso banner*'
        Get-CandidateText -Plan $plan -Path 'site/static/style.css' | Should-BeLikeString '*Contoso Sans*'
        Get-CandidateText -Plan $plan -Path 'site/layouts/rule.html' | Should-BeLikeString '*Rule page, v2.*'
    }

    It 'keeps the organization settings and writes the template sha' {
        $settings = Get-CandidateText -Plan $plan -Path '.github/Rulebook-Settings.json'
        $original = [System.IO.File]::ReadAllText((Join-Path $orgFixture '.github' 'Rulebook-Settings.json'))
        $settings | Should-Be $original.Replace($fakeSha, $plan.TemplateSha)
        $plan.TemplateSha | Should-Be (Get-TemplateContentSha -Path $v2)
    }

    It 'rewrites ChangeRule.yaml from the template with the house level' {
        Get-CandidateText -Plan $plan -Path '.github/workflows/ChangeRule.yaml' | Should-MatchString "(?m)^      # The level and stage lists are rewritten.*\n      levels:\n(?:.*\n)*?          - house\n"
    }

    It 'keeps the schedule of the update workflow' {
        Get-CandidateText -Plan $plan -Path '.github/workflows/UpdateRulebookSystemFiles.yaml' | Should-MatchString "(?m)^  schedule:\n    - cron: '0 6 \* \* 1'$"
    }

    It 'notes the entries of unusedRulebookFiles that the template no longer ships' {
        $plan.Notes | Should-ContainCollection @('.github/workflows/Legacy.yaml is listed in unusedRulebookFiles but the template does not ship it; the entry can be removed.')
    }

    It 'gives the release notes newer than the installed copy' {
        $plan.ReleaseNotesShipped | Should-BeTrue
        $plan.ReleaseNotes | Should-BeLikeString '*## v1.1*AL0432 at Hidden.*'
        $plan.ReleaseNotes | Should-NotMatchString 'v1\.0'
    }

    It 'gives every change its class and the bytes to write' {
        ($plan.Changes | Where-Object File -CEQ 'site/layouts/footer.html').Class | Should-Be 'customizable'
        ($plan.Changes | Where-Object File -CEQ 'rulesets/house.ruleset.json').Class | Should-Be 'generated'
        ($plan.Changes | Where-Object File -CEQ 'stages/ci.json').Class | Should-Be 'overwrite'
        $utf8.GetString(($plan.Changes | Where-Object File -CEQ 'stages/ci.json').Bytes) | Should-Be (Get-CandidateText -Plan $plan -Path 'stages/ci.json')
    }
}

Describe 'Get-RulebookUpdatePlan: variants' {
    It 'update-org against v1 is sha-only: no updates (AC1)' {
        $plan = Get-Plan -Template $v1
        $plan.Valid | Should-BeTrue
        Get-ChangeList $plan | Should-BeCollection @('modified .github/Rulebook-Settings.json')
        $plan.ShaOnly | Should-BeTrue
        $plan.UpdatesAvailable | Should-BeFalse
        (Get-RulebookUpdateStatus -Plan $plan).Status | Should-Be 'sha-only'
    }

    It 'a repository created from v1 has templateSha set and no diff after one run (AC1)' {
        $root = Get-TestFolder
        Copy-FixtureTree -Source $v1 -Destination $root
        # The first run records the sha and replaces {TEMPLATEURL} in the update workflow (AL-Go does the same).
        $first = Get-Plan -Org $root -Template $v1 -Installed '' -TemplateSha $fakeSha
        Get-ChangeList $first | Should-BeCollection @('modified .github/Rulebook-Settings.json', 'modified .github/workflows/UpdateRulebookSystemFiles.yaml')
        $first.ShaOnly | Should-BeTrue
        (Get-RulebookUpdateStatus -Plan $first).Status | Should-Be 'sha-only'
        foreach ($change in $first.Changes) { [System.IO.File]::WriteAllBytes((Join-Path $root $change.File), $change.Bytes) }
        (Get-Content -LiteralPath (Join-Path $root '.github' 'Rulebook-Settings.json') -Raw | ConvertFrom-Json).templateSha | Should-Be $fakeSha
        $second = Get-Plan -Org $root -Template $v1 -Installed $v1 -TemplateSha $fakeSha
        @($second.Changes) | Should-BeCollection @()
        (Get-RulebookUpdateStatus -Plan $second).Status | Should-Be 'none'
    }

    It 'a stage-only template change regenerates only the *.ci endpoints (AC3)' {
        $template = Get-TestFolder
        Copy-FixtureTree -Source $v1 -Destination $template
        Copy-Item -LiteralPath (Join-Path $v2 'stages' 'ci.json') -Destination (Join-Path $template 'stages' 'ci.json') -Force
        $null = Update-RulebookEndpoints -RepositoryRoot $template
        $plan = Get-Plan -Template $template
        $endpoints = @($plan.Changes | Where-Object Class -CEQ 'generated' | ForEach-Object File)
        $endpoints.Count | Should-BeGreaterThan 0
        foreach ($file in $endpoints) { $file | Should-BeLikeString 'rulesets/*.ci.ruleset.json' }
        @($plan.Changes | Where-Object Class -CNE 'generated' | ForEach-Object File) | Should-BeCollection @('.github/Rulebook-Settings.json', 'stages/ci.json')
    }

    It 'removes a shipped file listed in unusedRulebookFiles and the template dropped' {
        $plan = Get-Plan -Org (Copy-Org -WithLegacy)
        Assert-ItemPresent -Actual (Get-ChangeList $plan) -Expected @('deleted .github/workflows/Legacy.yaml', 'deleted site/layouts/legacy.html')
        ($plan.Changes | Where-Object File -CEQ '.github/workflows/Legacy.yaml').Class | Should-Be 'overwrite'
    }

    It 'keeps a dropped file that unusedRulebookFiles does not list, with a note' {
        $root = Copy-Org -WithLegacy
        Edit-OrgSetting -Root $root -Script { $_.unusedRulebookFiles = @() }
        $plan = Get-Plan -Org $root
        @($plan.Changes | Where-Object { $_.File -like '*egacy*' }) | Should-BeCollection @()
        Assert-ItemPresent -Actual $plan.Notes -Expected @(
            'The template no longer ships .github/workflows/Legacy.yaml; list it in unusedRulebookFiles to remove it.'
            'The template no longer ships site/layouts/legacy.html; list it in unusedRulebookFiles to remove it.'
        )
    }

    It 'does not match a bare file name in unusedRulebookFiles (#49)' {
        $root = Copy-Org -WithLegacy
        Edit-OrgSetting -Root $root -Script { $_.unusedRulebookFiles = @('Legacy.yaml') }
        $plan = Get-Plan -Org $root
        @($plan.Changes | Where-Object File -CEQ '.github/workflows/Legacy.yaml') | Should-BeCollection @()
        $plan.Notes | Should-ContainCollection @('The template no longer ships .github/workflows/Legacy.yaml; list it in unusedRulebookFiles to remove it.')
    }

    It 'does not re-add a shipped level listed in unusedRulebookFiles (AC5)' {
        $root = Copy-Org
        Edit-OrgSetting -Root $root -Script {
            $_.levels = @($_.levels | Where-Object { $_.name -ne 'Complete' })
            $_.unusedRulebookFiles = @('base/complete.ruleset.json')
        }
        $plan = Get-Plan -Org $root
        $plan.Valid | Should-BeTrue
        $changes = Get-ChangeList $plan
        Assert-ItemPresent -Actual $changes -Expected @('deleted base/complete.ruleset.json', 'deleted skeletons/complete.default.ruleset.json', 'deleted rulesets/complete.ruleset.json')
        Test-Path -LiteralPath (Join-Path $plan.CandidatePath 'base' 'complete.ruleset.json') | Should-BeFalse
        @($changes | Where-Object { $_ -like '*complete*' -and $_ -notlike 'deleted *' }) | Should-BeCollection @()

        # Once deleted, the next update leaves it out.
        foreach ($change in $plan.Changes) {
            $target = Join-Path $root $change.File
            if ($change.Change -eq 'deleted') { Remove-Item -LiteralPath $target } else { [System.IO.File]::WriteAllBytes($target, $change.Bytes) }
        }
        $again = Get-Plan -Org $root -TemplateSha $plan.TemplateSha
        @($again.Changes) | Should-BeCollection @()
    }

    It 'skips every differing site file without an installed template' {
        $root = Copy-Org
        Edit-OrgSetting -Root $root -Script { $_.templateSha = '' }
        $plan = Get-Plan -Org $root -Installed ''
        @($plan.Skipped | ForEach-Object { "$($_.File) $($_.Reason)" }) | Should-BeCollection @(
            'docs/README.md no installed template', 'docs/getting-started.md no installed template'
            'site/layouts/index.html no installed template', 'site/layouts/rule.html no installed template', 'site/static/style.css no installed template'
        )
        $plan.InstalledSource | Should-Be 'none'
        Assert-ItemPresent -Actual (Get-ChangeList $plan) -Expected @('created site/layouts/footer.html')
        @($plan.Changes | Where-Object File -CEQ 'site/layouts/rule.html') | Should-BeCollection @()
    }

    It 'overwrites locally changed site files with site.updateMode overwrite (AC11, AC12)' {
        $root = Copy-Org
        Edit-OrgSetting -Root $root -Script { $_.site.updateMode = 'overwrite' }
        $plan = Get-Plan -Org $root
        Assert-ItemPresent -Actual (Get-ChangeList $plan) -Expected @('modified site/layouts/index.html', 'modified site/static/style.css', 'modified site/layouts/rule.html')
        # The two keys are independent: the docs page changed on both sides is still skipped.
        @($plan.Skipped | ForEach-Object File) | Should-BeCollection @('docs/getting-started.md')
        Get-CandidateText -Plan $plan -Path 'site/static/style.css' | Should-Be ([System.IO.File]::ReadAllText((Join-Path $v2 'site' 'static' 'style.css')))
    }

    It 'keeps a site file changed only by the organization without a diff (AC11)' {
        $plan = Get-Plan
        @($plan.Changes | Where-Object File -CEQ 'site/static/style.css') | Should-BeCollection @()
    }

    It 'keeps a docs page changed only by the organization without a diff (D50)' {
        $plan = Get-Plan
        @($plan.Changes | Where-Object File -CEQ 'docs/README.md') | Should-BeCollection @()
        Get-CandidateText -Plan $plan -Path 'docs/README.md' | Should-BeLikeString '*Ask the platform team*'
    }

    It 'copies a docs image the template added by its bytes (D50)' {
        $plan = Get-Plan
        $change = $plan.Changes | Where-Object File -CEQ 'docs/images/badge.png'
        $change.Class | Should-Be 'customizable'
        $change.Kind | Should-Be 'docs'
        [System.Linq.Enumerable]::SequenceEqual([byte[]]$change.Bytes, [byte[]][System.IO.File]::ReadAllBytes((Join-Path $v2 'docs' 'images' 'badge.png'))) | Should-BeTrue
    }

    It 'overwrites a locally changed docs page with docs.updateMode overwrite and still skips the site page' {
        $root = Copy-Org
        Edit-OrgSetting -Root $root -Script { $_.docs.updateMode = 'overwrite' }
        $plan = Get-Plan -Org $root
        ($plan.Changes | Where-Object File -CEQ 'docs/getting-started.md').Class | Should-Be 'overwrite'
        Get-CandidateText -Plan $plan -Path 'docs/getting-started.md' | Should-Be ([System.IO.File]::ReadAllText((Join-Path $v2 'docs' 'getting-started.md')))
        # docs/README.md: v2 did not change it, but overwrite means the template version (the pull request shows the revert).
        Assert-ItemPresent -Actual (Get-ChangeList $plan) -Expected @('modified docs/getting-started.md', 'modified docs/README.md')
        @($plan.Skipped | ForEach-Object File) | Should-BeCollection @('site/layouts/index.html')
    }

    It 'removes a shipped docs page listed in unusedRulebookFiles' {
        $root = Copy-Org
        Edit-OrgSetting -Root $root -Script { $_.unusedRulebookFiles = @($_.unusedRulebookFiles) + 'docs/README.md' }
        $plan = Get-Plan -Org $root
        Assert-ItemPresent -Actual (Get-ChangeList $plan) -Expected @('deleted docs/README.md')
        Test-Path -LiteralPath (Join-Path $plan.CandidatePath 'docs' 'README.md') | Should-BeFalse
    }

    It 'lists skipped site and docs files under one heading that names both keys' {
        $plan = Get-Plan
        $body = ConvertTo-UpdatePullRequestBody -Plan $plan -Diff @() -Branch 'main'
        $body | Should-BeLikeString '*## Skipped: local changes*'
        $body | Should-BeLikeString '*set docs.updateMode or site.updateMode to overwrite.*'
        $body | Should-MatchString '(?m)^- `docs/getting-started\.md`: local changes$'
        $body | Should-NotMatchString 'could not be recovered'
    }

    It 'names only the key of the kinds that were skipped' {
        $root = Copy-Org
        Edit-OrgSetting -Root $root -Script { $_.site.updateMode = 'overwrite' }
        $summary = ConvertTo-UpdateSummary -Plan (Get-Plan -Org $root)
        $summary | Should-BeLikeString '*set docs.updateMode to overwrite.*'
        $summary | Should-NotMatchString 'site\.updateMode'
    }

    It 'says that the installed commit could not be recovered when files were skipped for that reason' {
        $root = Copy-Org
        Edit-OrgSetting -Root $root -Script { $_.templateSha = '' }
        $summary = ConvertTo-UpdateSummary -Plan (Get-Plan -Org $root -Installed '')
        $summary | Should-BeLikeString '*The installed template commit is not recorded in templateSha and could not be recovered*'
    }

    It 'ignores CRLF in the organization copy of an unchanged file' {
        $root = Copy-Org
        # The docs pages back at v1 (the organization edited both), then CRLF like the other files.
        foreach ($page in 'README.md', 'getting-started.md') { Copy-Item -LiteralPath (Join-Path $v1 'docs' $page) -Destination (Join-Path $root 'docs' $page) -Force }
        foreach ($path in '.github/workflows/Validate.yaml', 'base/essential.ruleset.json', 'site/layouts/rule.html', 'docs/README.md', 'docs/getting-started.md') {
            $full = Join-Path $root $path
            [System.IO.File]::WriteAllText($full, [System.IO.File]::ReadAllText($full).Replace("`n", "`r`n"))
        }
        $plan = Get-Plan -Org $root -Template $v1
        $plan.ShaOnly | Should-BeTrue
    }

    It 'is invalid with the finding when the new template does not validate' {
        $template = Get-TestFolder
        Copy-FixtureTree -Source $v2 -Destination $template
        $strict = Join-Path $template 'base' 'strict.ruleset.json'
        [System.IO.File]::WriteAllText($strict, [System.IO.File]::ReadAllText($strict).Replace('{ "id": "AA0137", "action": "Error" }', '{ "id": "AA0137", "action": "Default" }'))
        $plan = Get-Plan -Template $template
        $plan.Valid | Should-BeFalse
        @($plan.Findings | Where-Object { $_.Severity -eq 'error' -and $_.File -eq 'base/strict.ruleset.json' }).Count | Should-BeGreaterThan 0
        (Get-RulebookUpdateStatus -Plan $plan).Message | Should-BeLikeString 'update check skipped: the updated rulebook would not validate (*'
    }

    It 'is invalid with one update finding when the settings are missing' {
        $root = Copy-Org
        Remove-Item -LiteralPath (Join-Path $root '.github' 'Rulebook-Settings.json')
        $plan = Get-Plan -Org $root
        $plan.Valid | Should-BeFalse
        @($plan.Findings | ForEach-Object { "$($_.Rule) $($_.Severity)" }) | Should-BeCollection @('update error')
    }

    It 'copies a binary file by its bytes, whatever its extension (a font and a NUL-sniffed file)' {
        # CR LF, a lone CR, a trailing LF, a NUL and an invalid UTF-8 byte: the text path would change every one.
        [byte[]]$bytes = 0x00, 0x01, 0x0D, 0x0A, 0x41, 0x0D, 0x42, 0xFF, 0xFE, 0x0A, 0x0A
        $template = Get-TestFolder
        Copy-FixtureTree -Source $v2 -Destination $template
        foreach ($name in 'site/static/font.ttf', 'site/static/data.blob') {
            $target = Join-Path $template $name
            [System.IO.File]::WriteAllBytes($target, $bytes)
        }
        $plan = Get-Plan -Template $template
        Assert-ItemPresent -Actual (Get-ChangeList $plan) -Expected @('created site/static/font.ttf', 'created site/static/data.blob')
        foreach ($name in 'site/static/font.ttf', 'site/static/data.blob') {
            [System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes((Join-Path $plan.CandidatePath $name))) | Should-Be ([System.Convert]::ToBase64String($bytes)) -Because $name
            [System.Convert]::ToBase64String(($plan.Changes | Where-Object File -CEQ $name).Bytes) | Should-Be ([System.Convert]::ToBase64String($bytes)) -Because $name
        }
    }

    It 'hashes a binary file by its bytes in the content sha' {
        $one = Get-TestFolder
        $two = Get-TestFolder
        Write-FixtureText -Path (Join-Path $one '.github' 'workflows' 'x.yaml') -Text 'name: x'
        Write-FixtureText -Path (Join-Path $two '.github' 'workflows' 'x.yaml') -Text 'name: x'
        [System.IO.File]::WriteAllBytes((Join-Path $one 'font.ttf'), [byte[]](0x00, 0x0D, 0x0A))
        [System.IO.File]::WriteAllBytes((Join-Path $two 'font.ttf'), [byte[]](0x00, 0x0A))
        (Get-TemplateContentSha -Path $one) | Should-NotBe (Get-TemplateContentSha -Path $two)
        # Text files still compare LF-normalised.
        [System.IO.File]::WriteAllText((Join-Path $two '.github' 'workflows' 'x.yaml'), "name: x`r`n")
        [System.IO.File]::WriteAllBytes((Join-Path $two 'font.ttf'), [byte[]](0x00, 0x0D, 0x0A))
        (Get-TemplateContentSha -Path $one) | Should-Be (Get-TemplateContentSha -Path $two)
    }

    It 'does not follow a directory link back to the root' {
        $root = Copy-Org
        $link = Join-Path $root 'site' 'loop'
        $made = $false
        try {
            $type = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
            $null = New-Item -ItemType $type -Path $link -Target $root -ErrorAction Stop
            $made = $true
        } catch {
            Set-ItResult -Skipped -Because "no directory link could be created: $($_.Exception.Message)"
        }
        if ($made) {
            try {
                $files = @(InModuleScope Rulebook.Update -Parameters @{ Root = $root } { param($Root) Get-TreeFile -Root $Root })
                @($files | Where-Object { $_ -like 'site/loop*' }) | Should-BeCollection @()
                $files.Count | Should-Be @(Get-ChildItem -LiteralPath $orgFixture -Recurse -File -Force).Count
            } finally {
                # Remove the link itself (not its target), or the TestDrive cleanup walks the loop.
                [System.IO.Directory]::Delete($link, $false)
            }
        }
    }

    It 'leaves node_modules out of the candidate and the comparison' {
        $root = Copy-Org
        Write-FixtureText -Path (Join-Path $root 'site' 'node_modules' 'x' 'index.js') -Text 'x'
        Write-FixtureText -Path (Join-Path $root 'node_modules' 'y.js') -Text 'y'
        $plan = Get-Plan -Org $root
        Test-Path -LiteralPath (Join-Path $plan.CandidatePath 'node_modules') | Should-BeFalse
        Test-Path -LiteralPath (Join-Path $plan.CandidatePath 'site' 'node_modules') | Should-BeFalse
        @($plan.Changes | Where-Object { $_.File -like '*node_modules*' }) | Should-BeCollection @()
    }

    It 'leaves site/data out of the candidate and the comparison' {
        $root = Copy-Org
        Write-FixtureText -Path (Join-Path $root 'site' 'data' 'rules.json') -Text '{}'
        $plan = Get-Plan -Org $root
        Test-Path -LiteralPath (Join-Path $plan.CandidatePath 'site' 'data') | Should-BeFalse
        @($plan.Changes | Where-Object { $_.File -like 'site/data/*' }) | Should-BeCollection @()
    }
}

Describe 'Get-RulebookTemplate (download)' {
    BeforeAll {
        $script:headSha = 'b' * 40
        $script:oldSha = 'a' * 40
        function New-TemplateZip {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helper; writes only to TestDrive')]
            param([string]$Source, [string]$RootName)
            $staging = Get-TestFolder
            Copy-FixtureTree -Source $Source -Destination (Join-Path $staging $RootName)
            $zip = "$staging.zip"
            [System.IO.Compression.ZipFile]::CreateFromDirectory($staging, $zip)
            return $zip
        }
        $script:v2Zip = New-TemplateZip -Source $v2 -RootName 'Contoso-rulebook-template-bbbbbbb'
        $script:v1Zip = New-TemplateZip -Source $v1 -RootName 'Contoso-rulebook-template-aaaaaaa'
        $noWorkflows = Get-TestFolder
        Write-FixtureText -Path (Join-Path $noWorkflows 'README.md') -Text '# no workflows'
        $script:emptyZip = New-TemplateZip -Source $noWorkflows -RootName 'Contoso-rulebook-template-ccccccc'
        function Get-AppJson {
            $rsa = [System.Security.Cryptography.RSA]::Create(2048)
            try {
                return @{ GitHubAppClientId = 'Iv23liApp'; PrivateKey = [string]::Join('', $rsa.ExportRSAPrivateKeyPem().Split("`n")) } | ConvertTo-Json -Compress
            } finally {
                $rsa.Dispose()
            }
        }
    }

    BeforeEach {
        Mock Invoke-GitHubApi -ModuleName Rulebook.GitHub -ParameterFilter { $Path -eq 'repos/Contoso/rulebook-template/branches/main' } {
            [pscustomobject]@{ StatusCode = 200; Body = @{ commit = @{ sha = $script:headSha } }; Text = ''; Headers = $null; RateLimitRemaining = $null }
        }
        Mock Invoke-GitHubApi -ModuleName Rulebook.GitHub -ParameterFilter { $Path -eq "repos/Contoso/rulebook-template/zipball/$($script:headSha)" } {
            Copy-Item -LiteralPath $script:v2Zip -Destination $OutFile
            [pscustomobject]@{ StatusCode = 200; Body = $null; Text = ''; Headers = $null; RateLimitRemaining = $null }
        }
        Mock Invoke-GitHubApi -ModuleName Rulebook.GitHub -ParameterFilter { $Path -eq "repos/Contoso/rulebook-template/zipball/$($script:oldSha)" } {
            Copy-Item -LiteralPath $script:v1Zip -Destination $OutFile
            [pscustomobject]@{ StatusCode = 200; Body = $null; Text = ''; Headers = $null; RateLimitRemaining = $null }
        }
    }

    It 'downloads the branch head and the installed commit and finds the folder with .github/workflows' {
        $template = Get-RulebookTemplate -TemplateUrl 'Contoso/rulebook-template' -GitHubToken 'gh' -DownloadLatest -InstalledSha $oldSha -WorkPath (Get-TestFolder)
        $template.Sha | Should-Be $headSha
        $template.Url | Should-Be 'https://github.com/Contoso/rulebook-template@main'
        Split-Path -Leaf $template.Path | Should-Be 'Contoso-rulebook-template-bbbbbbb'
        Split-Path -Leaf $template.InstalledPath | Should-Be 'Contoso-rulebook-template-aaaaaaa'
        $template.Source | Should-Be 'download'
        Should-Invoke Invoke-GitHubApi -ModuleName Rulebook.GitHub -Times 3 -Exactly
        Should-Invoke Invoke-GitHubApi -ModuleName Rulebook.GitHub -Times 3 -Exactly -ParameterFilter { $Token -eq 'gh' }
    }

    It 're-applies the installed commit without the branch call when downloadLatest is off' {
        $template = Get-RulebookTemplate -TemplateUrl 'Contoso/rulebook-template' -GitHubToken 'gh' -InstalledSha $headSha -WorkPath (Get-TestFolder)
        $template.Sha | Should-Be $headSha
        $template.InstalledPath | Should-Be $template.Path
        Should-Invoke Invoke-GitHubApi -ModuleName Rulebook.GitHub -Times 0 -Exactly -ParameterFilter { $Path -like '*/branches/*' }
        Should-Invoke Invoke-GitHubApi -ModuleName Rulebook.GitHub -Times 1 -Exactly
    }

    It 'downloads the installed commit whenever it differs, so dropped files get their note' {
        $template = Get-RulebookTemplate -TemplateUrl 'Contoso/rulebook-template' -GitHubToken 'gh' -DownloadLatest -InstalledSha $oldSha -WorkPath (Get-TestFolder)
        $template.InstalledPath | Should-NotBeNull
        Should-Invoke Invoke-GitHubApi -ModuleName Rulebook.GitHub -Times 1 -Exactly -ParameterFilter { $Path -like "*/zipball/$($script:oldSha)" }
        $root = Copy-Org -WithLegacy
        Edit-OrgSetting -Root $root -Script { $_.unusedRulebookFiles = @(); $_.site.updateMode = 'overwrite' }
        $plan = Get-RulebookUpdatePlan -RepositoryRoot $root -Template $template -WorkPath (Get-TestFolder)
        Assert-ItemPresent -Actual $plan.Notes -Expected @('The template no longer ships .github/workflows/Legacy.yaml; list it in unusedRulebookFiles to remove it.')
    }

    It 'turns any failure of the installed zipball into a note, without an exchange (<Status>)' -ForEach @(
        @{ Status = 404; Note = '*aaaaaaa*not available (HTTP 404)*' }
        @{ Status = 502; Note = '*aaaaaaa*was not downloaded (*HTTP 502*' }
    ) {
        $code = $Status
        Mock Invoke-GitHubApi -ModuleName Rulebook.GitHub -ParameterFilter { $Path -eq "repos/Contoso/rulebook-template/zipball/$($script:oldSha)" } {
            [pscustomobject]@{ StatusCode = $code; Body = $null; Text = ''; Headers = $null; RateLimitRemaining = $null }
        }.GetNewClosure()
        $template = Get-RulebookTemplate -TemplateUrl 'Contoso/rulebook-template' -Token (Get-AppJson) -GitHubToken 'gh' -DownloadLatest -InstalledSha $oldSha -WorkPath (Get-TestFolder)
        $template.Sha | Should-Be $headSha
        $template.InstalledPath | Should-BeNull
        @($template.Notes | Where-Object { $_ -like $Note }).Count | Should-Be 1
        Should-Invoke Invoke-GitHubApi -ModuleName Rulebook.GitHub -Times 0 -Exactly -ParameterFilter { $Path -like '*/installation' -or $Uri -like '*access_tokens*' }
    }

    It 'reads the installed zipball with the token the new template needed' {
        Mock Invoke-GitHubApi -ModuleName Rulebook.GitHub -ParameterFilter { $Path -like '*/branches/main' -and $Token -eq 'gh' } {
            [pscustomobject]@{ StatusCode = 404; Body = @{ message = 'Not Found' }; Text = ''; Headers = $null; RateLimitRemaining = $null }
        }
        $template = Get-RulebookTemplate -TemplateUrl 'Contoso/rulebook-template' -Token 'ghp_write' -GitHubToken 'gh' -DownloadLatest -InstalledSha $oldSha -WorkPath (Get-TestFolder)
        $template.InstalledPath | Should-NotBeNull
        Should-Invoke Invoke-GitHubApi -ModuleName Rulebook.GitHub -Times 1 -Exactly -ParameterFilter { $Path -like "*/zipball/$($script:oldSha)" -and $Token -eq 'ghp_write' }
    }

    It 'names the failed exchange together with the original answer of the new template' {
        Mock Invoke-GitHubApi -ModuleName Rulebook.GitHub -ParameterFilter { $Path -like '*/branches/main' } {
            [pscustomobject]@{ StatusCode = 404; Body = @{ message = 'Not Found' }; Text = ''; Headers = $null; RateLimitRemaining = $null }
        }
        Mock Invoke-GitHubApi -ModuleName Rulebook.GitHub -ParameterFilter { $Path -eq 'repos/Contoso/rulebook-template/installation' } {
            [pscustomobject]@{ StatusCode = 404; Body = @{ message = 'Not Found' }; Text = ''; Headers = $null; RateLimitRemaining = $null }
        }
        $caught = $null
        try { $null = Get-RulebookTemplate -TemplateUrl 'Contoso/rulebook-template' -Token (Get-AppJson) -GitHubToken 'gh' -DownloadLatest -WorkPath (Get-TestFolder) } catch { $caught = $_ }
        $caught.Exception.Message | Should-BeLikeString 'Could not get the latest commit of https://github.com/Contoso/rulebook-template@main (HTTP 404: Not Found)*could not be used to read Contoso/rulebook-template*Iv23liApp has no installation*'
        $caught.Exception.Data['StatusCode'] | Should-Be 404
    }

    It 'notes an installed commit that is gone and goes on without it' {
        Mock Invoke-GitHubApi -ModuleName Rulebook.GitHub -ParameterFilter { $Path -eq "repos/Contoso/rulebook-template/zipball/$($script:oldSha)" } {
            [pscustomobject]@{ StatusCode = 404; Body = $null; Text = ''; Headers = $null; RateLimitRemaining = $null }
        }
        $template = Get-RulebookTemplate -TemplateUrl 'Contoso/rulebook-template' -GitHubToken 'gh' -DownloadLatest -InstalledSha $oldSha -WorkPath (Get-TestFolder)
        $template.InstalledPath | Should-BeNull
        $template.Notes[0] | Should-BeLikeString '*aaaaaaa*not available (HTTP 404)*'
    }

    It 'throws when the zip has no .github/workflows' {
        Mock Invoke-GitHubApi -ModuleName Rulebook.GitHub -ParameterFilter { $Path -like '*/zipball/*' } {
            Copy-Item -LiteralPath $script:emptyZip -Destination $OutFile
            [pscustomobject]@{ StatusCode = 200; Body = $null; Text = ''; Headers = $null; RateLimitRemaining = $null }
        }
        { Get-RulebookTemplate -TemplateUrl 'Contoso/rulebook-template' -GitHubToken 'gh' -DownloadLatest -WorkPath (Get-TestFolder) } | Should-Throw -ExceptionMessage 'no .github/workflows in the template'
    }

    It 'reads a private template with the exchanged write token after a 404' {
        Mock Invoke-GitHubApi -ModuleName Rulebook.GitHub -ParameterFilter { $Path -like '*/branches/main' -and $Token -eq 'gh' } {
            [pscustomobject]@{ StatusCode = 404; Body = @{ message = 'Not Found' }; Text = '{"message":"Not Found"}'; Headers = $null; RateLimitRemaining = $null }
        }
        $masked = [System.Collections.Generic.List[string]]::new()
        $template = Get-RulebookTemplate -TemplateUrl 'Contoso/rulebook-template' -Token 'ghp_write' -GitHubToken 'gh' -DownloadLatest -WorkPath (Get-TestFolder) -OnToken { param($Value) $masked.Add($Value) }.GetNewClosure()
        $template.Sha | Should-Be $headSha
        @($masked) | Should-BeCollection @('ghp_write')
        Should-Invoke Invoke-GitHubApi -ModuleName Rulebook.GitHub -Times 1 -Exactly -ParameterFilter { $Path -like '*/branches/main' -and $Token -eq 'ghp_write' }
        Should-Invoke Invoke-GitHubApi -ModuleName Rulebook.GitHub -Times 1 -Exactly -ParameterFilter { $Path -like '*/zipball/*' -and $Token -eq 'ghp_write' }
    }

    It 'fails on a 404 without a write token' {
        Mock Invoke-GitHubApi -ModuleName Rulebook.GitHub -ParameterFilter { $Path -like '*/branches/main' } {
            [pscustomobject]@{ StatusCode = 404; Body = @{ message = 'Not Found' }; Text = ''; Headers = $null; RateLimitRemaining = $null }
        }
        { Get-RulebookTemplate -TemplateUrl 'Contoso/rulebook-template' -GitHubToken 'gh' -DownloadLatest -WorkPath (Get-TestFolder) } | Should-Throw -ExceptionMessage 'Could not get the latest commit of https://github.com/Contoso/rulebook-template@main (HTTP 404: Not Found)'
    }

    Context 'recovery of the installed commit from the root tree (D50)' {
        BeforeAll {
            $script:recover = @{ TemplateUrl = 'Contoso/rulebook-template'; GitHubToken = 'gh'; DownloadLatest = $true; InstalledSha = ''; RepositoryRoot = 'C:\org'; Repository = 'Contoso/rulebook'; Ref = 'f' * 40; RepositoryToken = 'gh-org' }
            function Get-CommitItem {
                param([string]$Sha, [string]$Tree)
                return @{ sha = $Sha; commit = @{ tree = @{ sha = $Tree } } }
            }
        }

        BeforeEach {
            Mock Invoke-GitHubApi -ModuleName Rulebook.GitHub -ParameterFilter { $Path -like 'repos/Contoso/rulebook-template/commits?*' } {
                [pscustomobject]@{ StatusCode = 200; Body = @((Get-CommitItem $script:headSha 'T2'), (Get-CommitItem $script:oldSha 'T1')); Text = ''; Headers = $null; RateLimitRemaining = $null }
            }
            Mock Get-RepositoryRootTree -ModuleName Rulebook.Update { [pscustomobject]@{ TreeShas = [string[]]@('T1'); Source = 'git'; Note = $null } }
        }

        It 'recovers the installed commit and downloads its zipball once' {
            $template = Get-RulebookTemplate @recover -WorkPath (Get-TestFolder)
            $template.Sha | Should-Be $headSha
            $template.InstalledSha | Should-Be $oldSha
            $template.InstalledSource | Should-Be 'recovered'
            Split-Path -Leaf $template.InstalledPath | Should-Be 'Contoso-rulebook-template-aaaaaaa'
            @($template.Notes) | Should-BeCollection @("templateSha is empty; the installed template commit aaaaaaa was recovered from the repository's root commit (tree T1).")
            Should-Invoke Invoke-GitHubApi -ModuleName Rulebook.GitHub -Times 1 -Exactly -ParameterFilter { $Path -eq "repos/Contoso/rulebook-template/zipball/$($script:oldSha)" }
            Should-Invoke Invoke-GitHubApi -ModuleName Rulebook.GitHub -Times 1 -Exactly -ParameterFilter { $Path -eq 'repos/Contoso/rulebook-template/commits?sha=main&per_page=100&page=1' -and $Token -eq 'gh' }
            Should-Invoke Get-RepositoryRootTree -ModuleName Rulebook.Update -Times 1 -Exactly -ParameterFilter { $RepositoryRoot -eq 'C:\org' -and $Repository -eq 'Contoso/rulebook' -and $Ref -eq ('f' * 40) -and $Token -eq 'gh-org' }
        }

        It 'takes the newest commit when two share the root tree' {
            $middle = 'c' * 40
            Mock Invoke-GitHubApi -ModuleName Rulebook.GitHub -ParameterFilter { $Path -like 'repos/Contoso/rulebook-template/commits?*' } {
                [pscustomobject]@{ StatusCode = 200; Body = @((Get-CommitItem $script:headSha 'T2'), (Get-CommitItem ('c' * 40) 'T1'), (Get-CommitItem $script:oldSha 'T1')); Text = ''; Headers = $null; RateLimitRemaining = $null }
            }
            Mock Invoke-GitHubApi -ModuleName Rulebook.GitHub -ParameterFilter { $Path -eq "repos/Contoso/rulebook-template/zipball/$('c' * 40)" } {
                Copy-Item -LiteralPath $script:v1Zip -Destination $OutFile
                [pscustomobject]@{ StatusCode = 200; Body = $null; Text = ''; Headers = $null; RateLimitRemaining = $null }
            }
            $template = Get-RulebookTemplate @recover -WorkPath (Get-TestFolder)
            $template.InstalledSha | Should-Be $middle
            Should-Invoke Invoke-GitHubApi -ModuleName Rulebook.GitHub -Times 0 -Exactly -ParameterFilter { $Path -like "*/zipball/$($script:oldSha)" }
        }

        It 'takes the head path when the root tree is the tree of the head' {
            Mock Get-RepositoryRootTree -ModuleName Rulebook.Update { [pscustomobject]@{ TreeShas = [string[]]@('T2'); Source = 'api'; Note = $null } }
            $template = Get-RulebookTemplate @recover -WorkPath (Get-TestFolder)
            $template.InstalledSha | Should-Be $headSha
            $template.InstalledSource | Should-Be 'recovered'
            $template.InstalledPath | Should-Be $template.Path
            Should-Invoke Invoke-GitHubApi -ModuleName Rulebook.GitHub -Times 1 -Exactly -ParameterFilter { $Path -like '*/zipball/*' }
        }

        It 'names the API route in the notes and stops the template walk at the page with the match' {
            Mock Get-RepositoryRootTree -ModuleName Rulebook.Update { [pscustomobject]@{ TreeShas = [string[]]@('T1'); Source = 'api'; Note = 'root from the last page' } }
            $template = Get-RulebookTemplate @recover -WorkPath (Get-TestFolder)
            $template.InstalledSource | Should-Be 'recovered'
            $template.Notes[0] | Should-Be 'root from the last page'
            $template.Notes[1] | Should-BeLikeString '*was recovered*'
            Should-Invoke Invoke-GitHubApi -ModuleName Rulebook.GitHub -Times 1 -Exactly -ParameterFilter { $Path -like '*/commits?*' }
        }

        It 'says the template commit list was capped when no commit matched' {
            Mock Get-RepositoryRootTree -ModuleName Rulebook.Update { [pscustomobject]@{ TreeShas = [string[]]@('T9'); Source = 'git'; Note = $null } }
            Mock Invoke-GitHubApi -ModuleName Rulebook.GitHub -ParameterFilter { $Path -like 'repos/Contoso/rulebook-template/commits?*' } {
                [pscustomobject]@{ StatusCode = 200; Body = @(for ($i = 0; $i -lt 100; $i++) { Get-CommitItem ('{0:x40}' -f $i) 'Tx' }); Text = ''; Headers = $null; RateLimitRemaining = $null }
            }
            $template = Get-RulebookTemplate @recover -WorkPath (Get-TestFolder)
            $template.InstalledSource | Should-Be 'none'
            $template.Notes[0] | Should-BeLikeString '*in the last 1000 commits of the list (capped) has the tree*'
            Should-Invoke Invoke-GitHubApi -ModuleName Rulebook.GitHub -Times 10 -Exactly -ParameterFilter { $Path -like '*/commits?*' }
        }

        It 'leaves out the not-recovered line when a recorded commit failed to download' {
            Mock Invoke-GitHubApi -ModuleName Rulebook.GitHub -ParameterFilter { $Path -eq "repos/Contoso/rulebook-template/zipball/$($script:oldSha)" } {
                [pscustomobject]@{ StatusCode = 404; Body = $null; Text = ''; Headers = $null; RateLimitRemaining = $null }
            }
            $recorded = $recover.Clone()
            $recorded.InstalledSha = $oldSha
            $template = Get-RulebookTemplate @recorded -WorkPath (Get-TestFolder)
            $plan = Get-RulebookUpdatePlan -RepositoryRoot (Copy-Org) -Template $template -WorkPath (Get-TestFolder)
            $plan.InstalledSource | Should-Be 'recorded'
            @($plan.Skipped | Where-Object Reason -CEQ 'no installed template').Count | Should-BeGreaterThan 0
            $summary = ConvertTo-UpdateSummary -Plan $plan
            $summary | Should-NotMatchString 'could not be recovered'
            $summary | Should-BeLikeString '*aaaaaaa*not available (HTTP 404)*'
        }

        It 'gives the log line on the installed template' -ForEach @(
            @{ Source = 'recorded'; Sha = 'a' * 40; Line = 'Installed template: recorded aaaaaaa' }
            @{ Source = 'recovered'; Sha = 'b' * 40; Line = 'Installed template: recovered bbbbbbb from the root commit' }
            @{ Source = 'none'; Sha = $null; Line = 'Installed template: not known' }
        ) {
            Get-InstalledTemplateLine -Template ([pscustomobject]@{ InstalledSource = $Source; InstalledSha = $Sha }) | Should-Be $Line
        }

        It 'keeps the behaviour without an installed template when no commit has the root tree' {
            Mock Get-RepositoryRootTree -ModuleName Rulebook.Update { [pscustomobject]@{ TreeShas = [string[]]@('T9'); Source = 'git'; Note = $null } }
            $template = Get-RulebookTemplate @recover -WorkPath (Get-TestFolder)
            $template.InstalledSha | Should-BeNull
            $template.InstalledPath | Should-BeNull
            $template.InstalledSource | Should-Be 'none'
            @($template.Notes) | Should-BeCollection @("templateSha is empty and the installed template commit could not be recovered: no commit of Contoso/rulebook-template@main in the last 2 commits has the tree of the repository's root commit; site and docs files that differ from the new template are kept and listed, and files the template dropped get no note.")
            Should-Invoke Invoke-GitHubApi -ModuleName Rulebook.GitHub -Times 1 -Exactly -ParameterFilter { $Path -like '*/zipball/*' }
        }

        It 'notes a root commit that could not be found' {
            Mock Get-RepositoryRootTree -ModuleName Rulebook.Update { [pscustomobject]@{ TreeShas = $null; Source = $null; Note = "The repository's root commit could not be found (HTTP 403)." } }
            $template = Get-RulebookTemplate @recover -WorkPath (Get-TestFolder)
            $template.InstalledSource | Should-Be 'none'
            $template.Notes[0] | Should-BeLikeString "templateSha is empty and the installed template commit could not be recovered: The repository's root commit could not be found (HTTP 403). The site and docs files*"
            Should-Invoke Invoke-GitHubApi -ModuleName Rulebook.GitHub -Times 0 -Exactly -ParameterFilter { $Path -like '*/commits?*' }
        }

        It 'turns a failing commits call into a note' {
            Mock Invoke-GitHubApi -ModuleName Rulebook.GitHub -ParameterFilter { $Path -like 'repos/Contoso/rulebook-template/commits?*' } {
                [pscustomobject]@{ StatusCode = 500; Body = @{ message = 'Server Error' }; Text = ''; Headers = $null; RateLimitRemaining = $null }
            }
            $template = Get-RulebookTemplate @recover -WorkPath (Get-TestFolder)
            $template.InstalledSource | Should-Be 'none'
            $template.Notes[0] | Should-BeLikeString '*could not be recovered: the commits of Contoso/rulebook-template@main could not be listed (*HTTP 500: Server Error*'
        }

        It 'lists the template commits with the write token the template needed' {
            Mock Invoke-GitHubApi -ModuleName Rulebook.GitHub -ParameterFilter { $Path -like '*/branches/main' -and $Token -eq 'gh' } {
                [pscustomobject]@{ StatusCode = 404; Body = @{ message = 'Not Found' }; Text = ''; Headers = $null; RateLimitRemaining = $null }
            }
            $template = Get-RulebookTemplate @recover -Token 'ghp_write' -WorkPath (Get-TestFolder)
            $template.InstalledSource | Should-Be 'recovered'
            Should-Invoke Invoke-GitHubApi -ModuleName Rulebook.GitHub -Times 1 -Exactly -ParameterFilter { $Path -like '*/commits?*' -and $Token -eq 'ghp_write' }
            Should-Invoke Invoke-GitHubApi -ModuleName Rulebook.GitHub -Times 0 -Exactly -ParameterFilter { $Path -like '*/commits?*' -and $Token -eq 'gh' }
        }

        It 'does not look for the root without the repository (another template)' {
            $template = Get-RulebookTemplate -TemplateUrl 'Contoso/rulebook-template' -GitHubToken 'gh' -DownloadLatest -InstalledSha '' -WorkPath (Get-TestFolder)
            $template.InstalledSource | Should-Be 'none'
            @($template.Notes) | Should-BeCollection @()
            Should-Invoke Get-RepositoryRootTree -ModuleName Rulebook.Update -Times 0 -Exactly
        }

        It 'never looks for the root when templateSha is recorded' {
            $recorded = $recover.Clone()
            $recorded.InstalledSha = $oldSha
            $template = Get-RulebookTemplate @recorded -WorkPath (Get-TestFolder)
            $template.InstalledSource | Should-Be 'recorded'
            Should-Invoke Get-RepositoryRootTree -ModuleName Rulebook.Update -Times 0 -Exactly
        }

        It 'compares three ways with the recovered commit and writes the head into templateSha' {
            $root = Copy-Org
            Edit-OrgSetting -Root $root -Script { $_.templateSha = '' }
            $template = Get-RulebookTemplate @recover -WorkPath (Get-TestFolder)
            $plan = Get-RulebookUpdatePlan -RepositoryRoot $root -Template $template -WorkPath (Get-TestFolder)
            $plan.InstalledSource | Should-Be 'recovered'
            $plan.InstalledSha | Should-Be $oldSha
            @($plan.Skipped | ForEach-Object { "$($_.File) $($_.Reason)" }) | Should-BeCollection @('docs/getting-started.md local changes', 'site/layouts/index.html local changes')
            (Get-CandidateText -Plan $plan -Path '.github/Rulebook-Settings.json' | ConvertFrom-Json).templateSha | Should-Be $headSha
            ConvertTo-UpdatePullRequestBody -Plan $plan -Diff @() -Branch 'main' | Should-BeLikeString "*/compare/$($oldSha)...$($headSha)*the installed template commit aaaaaaa was recovered from the repository's root commit*"
        }
    }
}

Describe 'Get-RepositoryRootTree' -Skip:$gitMissing {
    BeforeAll {
        function New-GitCopy {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helper; writes only to TestDrive')]
            param()
            # A copy of the v1 template as a git repository with one root commit; returns the folder.
            $root = Get-TestFolder
            Copy-FixtureTree -Source $v1 -Destination $root
            $null = New-FixtureGitRepo -Root $root -Message 'Initial commit'
            return $root
        }
        $script:orgRepo = New-GitCopy
        $script:rootTree = ([string](Invoke-FixtureGit -Root $orgRepo -Arguments @('rev-parse', 'HEAD^{tree}'))).Trim()
        $script:otherRepo = New-GitCopy
        # The organization's own edits as a second commit, as update-org has them.
        Copy-Item -LiteralPath (Join-Path $orgFixture 'docs' 'README.md') -Destination (Join-Path $orgRepo 'docs' 'README.md') -Force
        $null = New-FixtureGitRepo -Root $orgRepo -Message 'Contoso edits'
        $script:shallowRepo = Join-Path (Get-TestFolder) 'shallow'
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $shallowRepo) -Force
        Invoke-FixtureGit -Root (Split-Path -Parent $shallowRepo) -Arguments @('clone', '--quiet', '--depth', '1', ([System.Uri]::new($orgRepo)).AbsoluteUri, $shallowRepo) | Out-Null
        function Get-PageItem {
            param([int]$Count, [string]$LastTree = 'Tx')
            return @(for ($i = 1; $i -le $Count; $i++) { @{ sha = ('{0:x40}' -f $i); commit = @{ tree = @{ sha = $(if ($i -eq $Count) { $LastTree } else { 'Tx' }) } } } })
        }
    }

    BeforeEach {
        Mock Invoke-GitHubApi -ModuleName Rulebook.GitHub -ParameterFilter { $Path -like 'repos/Contoso/rulebook/commits?*page=1' } {
            [pscustomobject]@{ StatusCode = 200; Body = (Get-PageItem -Count 100); Text = ''; Headers = $null; RateLimitRemaining = $null }
        }
        Mock Invoke-GitHubApi -ModuleName Rulebook.GitHub -ParameterFilter { $Path -like 'repos/Contoso/rulebook/commits?*page=2' } {
            [pscustomobject]@{ StatusCode = 200; Body = (Get-PageItem -Count 7 -LastTree $script:rootTree); Text = ''; Headers = $null; RateLimitRemaining = $null }
        }
    }

    It 'gives the same root tree for every repository created from the same template commit' {
        $script:rootTree | Should-MatchString '^[0-9a-f]{40}$'
        (Get-RepositoryRootTree -RepositoryRoot $otherRepo).TreeShas | Should-BeCollection @($rootTree)
    }

    It 'finds the root tree in the local history without an API call' {
        $result = Get-RepositoryRootTree -RepositoryRoot $orgRepo -Repository 'Contoso/rulebook' -Ref 'main' -Token 'gh'
        $result.TreeShas | Should-BeCollection @($rootTree)
        $result.Source | Should-Be 'git'
        $result.Note | Should-BeNull
        Should-Invoke Invoke-GitHubApi -ModuleName Rulebook.GitHub -Times 0 -Exactly
    }

    It 'walks the commits of the repository to the last page when the clone is shallow' {
        Get-GitRootTree -Root $shallowRepo | Should-BeNull
        $result = Get-RepositoryRootTree -RepositoryRoot $shallowRepo -Repository 'Contoso/rulebook' -Ref ('f' * 40) -Token 'gh'
        $result.TreeShas | Should-BeCollection @($rootTree)
        $result.Source | Should-Be 'api'
        $result.Note | Should-Be "The repository's root commit was taken from the last page of its commits list (no full git history in the checkout); a repository with more than one root commit, or with commit dates out of order, may not match."
        Should-Invoke Invoke-GitHubApi -ModuleName Rulebook.GitHub -Times 1 -Exactly -ParameterFilter { $Path -eq "repos/Contoso/rulebook/commits?sha=$('f' * 40)&per_page=100&page=2" -and $Token -eq 'gh' }
    }

    It 'notes the page cap instead of guessing a root, as at least N commits when exactly N were read' {
        $result = Get-RepositoryRootTree -RepositoryRoot $shallowRepo -Repository 'Contoso/rulebook' -Ref 'main' -MaxPages 1
        $result.TreeShas | Should-BeNull
        $result.Source | Should-BeNull
        $result.Note | Should-Be "The repository's root commit could not be found (Contoso/rulebook has at least 100 commits, the most the update reads)."
    }

    It 'notes a failing API call' {
        Mock Invoke-GitHubApi -ModuleName Rulebook.GitHub -ParameterFilter { $Path -like 'repos/Contoso/rulebook/commits?*' } {
            [pscustomobject]@{ StatusCode = 403; Body = @{ message = 'Resource not accessible by integration' }; Text = ''; Headers = $null; RateLimitRemaining = $null }
        }
        $result = Get-RepositoryRootTree -RepositoryRoot $shallowRepo -Repository 'Contoso/rulebook' -Ref 'main'
        $result.TreeShas | Should-BeNull
        $result.Note | Should-BeLikeString "The repository's root commit could not be found (Could not list the commits of https://github.com/Contoso/rulebook@main (HTTP 403: Resource not accessible by integration))."
    }

    It 'gives no tree and a note without git history and without a repository name' {
        $plain = Get-TestFolder
        $null = New-Item -ItemType Directory -Path $plain
        foreach ($folder in $plain, '') {
            $result = Get-RepositoryRootTree -RepositoryRoot $folder
            $result.TreeShas | Should-BeNull
            $result.Note | Should-BeLikeString "The repository's root commit could not be found (no full git history*"
        }
        Should-Invoke Invoke-GitHubApi -ModuleName Rulebook.GitHub -Times 0 -Exactly
    }
}

Describe 'Publish-RulebookUpdate against a bare repository' -Skip:$gitMissing {
    BeforeAll {
        function New-Origin {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helper; writes only to TestDrive')]
            # A bare origin holding update-org on main, the API mocked around it. Returns the bare path.
            param([switch]$Reject)
            $bare = New-BareFixtureRepo -Source $orgFixture -Destination (Join-Path (Get-TestFolder) 'origin.git')
            if ($Reject) { Add-RejectPushHook -BarePath $bare -Branch 'main' }
            $script:originSha = (& git -C $bare rev-parse refs/heads/main).Trim()
            return $bare
        }
        $script:now = [System.DateTimeOffset]::new(2026, 10, 7, 12, 30, 45, [System.TimeSpan]::Zero)
    }

    BeforeEach {
        $script:openPulls = @()
        Mock Invoke-GitHubApi -ModuleName Rulebook.GitHub -ParameterFilter { $Method -eq 'GET' -and $Path -eq 'repos/Contoso/rulebook/branches/main' } {
            [pscustomobject]@{ StatusCode = 200; Body = @{ commit = @{ sha = $script:originSha } }; Text = ''; Headers = $null; RateLimitRemaining = $null }
        }
        Mock Invoke-GitHubApi -ModuleName Rulebook.GitHub -ParameterFilter { $Method -eq 'GET' -and $Path -like 'repos/Contoso/rulebook/pulls?*' } {
            [pscustomobject]@{ StatusCode = 200; Body = @($script:openPulls); Text = ''; Headers = $null; RateLimitRemaining = $null }
        }
        Mock Invoke-GitHubApi -ModuleName Rulebook.GitHub -ParameterFilter { $Method -eq 'POST' -and $Path -eq 'repos/Contoso/rulebook/pulls' } {
            [pscustomobject]@{ StatusCode = 201; Body = @{ number = 12; html_url = 'https://github.com/Contoso/rulebook/pull/12' }; Text = ''; Headers = $null; RateLimitRemaining = $null }
        }
        Mock Invoke-GitHubApi -ModuleName Rulebook.GitHub -ParameterFilter { $Method -eq 'POST' -and $Path -eq 'repos/Contoso/rulebook/issues/12/labels' } {
            [pscustomobject]@{ StatusCode = 200; Body = @(); Text = '[]'; Headers = $null; RateLimitRemaining = $null }
        }
        $script:plan = Get-Plan
    }

    It 'pushes a timestamped branch with the planned tree and opens the labelled pull request (AC2)' {
        $bare = New-Origin
        $result = Publish-RulebookUpdate -Plan $plan -Repository 'Contoso/rulebook' -RemoteUrl $bare -Token 'ghs_x' -UpdateBranch 'main' -Actor 'octocat' -Labels @('rulebook') -WorkPath (Get-TestFolder) -Now $now
        $result.Result | Should-Be 'pull-request'
        $result.PullRequestUrl | Should-Be 'https://github.com/Contoso/rulebook/pull/12'
        $result.Branch | Should-Be 'update-rulebook-system-files/main/261007123045'
        $result.Branch | Should-MatchString '^update-rulebook-system-files/main/\d{12}$'
        $title = "[main@$($originSha.Substring(0, 7))] Update Rulebook System Files from Contoso/rulebook-template - $($plan.TemplateSha.Substring(0, 7))"
        $result.Title | Should-Be $title
        (& git -C $bare log -1 --format=%s $result.Branch) | Should-Be $title
        (& git -C $bare rev-parse refs/heads/main).Trim() | Should-Be $originSha

        # The pushed tree is the candidate.
        $check = Get-TestFolder
        $null = & git clone -q --branch $result.Branch -c core.autocrlf=false $bare $check 2>&1
        Get-RelativeFileList -Root $check | Should-BeCollection (Get-RelativeFileList -Root $plan.CandidatePath)
        foreach ($path in Get-RelativeFileList -Root $check) {
            Test-SameContent -Left (Join-Path $check $path) -Right (Join-Path $plan.CandidatePath $path) | Should-BeTrue -Because $path
        }

        Assert-ItemPresent -Actual @($result.Diff | ForEach-Object Endpoint) -Expected @('recommended.default', 'recommended.ci', 'house.default', 'strict.default', 'complete.default')
        @($result.Diff | Where-Object { $_.Endpoint -like 'essential.*' }) | Should-BeCollection @()
        # Endpoint tables in settings order (recommended before house before strict before complete), not by name.
        $tables = @([regex]::Matches($result.Body, '(?m)^### `([^`]+)`') | ForEach-Object { $_.Groups[1].Value })
        $tables | Should-BeCollection @($result.Diff | ForEach-Object Endpoint | Select-Object -Unique)
        [array]::IndexOf($tables, 'recommended.default') | Should-BeLessThan ([array]::IndexOf($tables, 'complete.default'))
        $headings = @([regex]::Matches($result.Body, '(?m)^## (.+)$') | ForEach-Object { $_.Groups[1].Value })
        $headings | Should-BeCollection @('Changes', 'Effective diff', 'Skipped: local changes', 'Notes', 'Release notes')
        $result.Body | Should-MatchString '(?m)^\| AC0001 \| Warning \| Error \| level:recommended \|$'
        Should-Invoke Invoke-GitHubApi -ModuleName Rulebook.GitHub -Times 1 -Exactly -ParameterFilter { $Method -eq 'POST' -and $Path -eq 'repos/Contoso/rulebook/pulls' -and $Body.title -eq $title -and $Body.head -eq 'update-rulebook-system-files/main/261007123045' -and $Body.base -eq 'main' }
        Should-Invoke Invoke-GitHubApi -ModuleName Rulebook.GitHub -Times 1 -Exactly -ParameterFilter { $Path -eq 'repos/Contoso/rulebook/issues/12/labels' -and (@($Body.labels) -join ',') -eq 'rulebook' }
    }

    It 'reports an open pull request with the same title and clones nothing (AC8)' {
        $bare = New-Origin
        $title = "[main@$($originSha.Substring(0, 7))] Update Rulebook System Files from Contoso/rulebook-template - $($plan.TemplateSha.Substring(0, 7))"
        $script:openPulls = @(@{ number = 11; title = $title; html_url = 'https://github.com/Contoso/rulebook/pull/11' })
        Mock New-GitHubClone -ModuleName Rulebook.Update { throw 'must not clone' }
        $result = Publish-RulebookUpdate -Plan $plan -Repository 'Contoso/rulebook' -RemoteUrl $bare -Token 'ghs_x' -UpdateBranch 'main' -WorkPath (Get-TestFolder) -Now $now
        $result.Result | Should-Be 'exists'
        $result.PullRequestUrl | Should-Be 'https://github.com/Contoso/rulebook/pull/11'
        Should-Invoke New-GitHubClone -ModuleName Rulebook.Update -Times 0 -Exactly
        Should-Invoke Invoke-GitHubApi -ModuleName Rulebook.GitHub -Times 0 -Exactly -ParameterFilter { $Method -eq 'POST' }
    }

    It 'pushes a direct commit to main' {
        $bare = New-Origin
        $result = Publish-RulebookUpdate -Plan $plan -Repository 'Contoso/rulebook' -RemoteUrl $bare -Token 'ghs_x' -UpdateBranch 'main' -DirectCommit -WorkPath (Get-TestFolder) -Now $now
        $result.Result | Should-Be 'direct-commit'
        (& git -C $bare rev-parse refs/heads/main).Trim() | Should-Be $result.Sha
        $result.Title | Should-BeLikeString "``[main@$($originSha.Substring(0, 7))``]*"
        $result.Body | Should-BeNull
        # No duplicate guard for a direct commit: no API call at all.
        Should-Invoke Invoke-GitHubApi -ModuleName Rulebook.GitHub -Times 0 -Exactly
    }

    It 'falls back to a pull request when the direct push is refused' {
        $bare = New-Origin -Reject
        $result = Publish-RulebookUpdate -Plan $plan -Repository 'Contoso/rulebook' -RemoteUrl $bare -Token 'ghs_x' -UpdateBranch 'main' -DirectCommit -WorkPath (Get-TestFolder) -Now $now
        $result.Result | Should-Be 'pull-request'
        $result.Fallback | Should-BeTrue
        $result.FallbackReason | Should-BeLikeString '*main is protected*'
        (& git -C $bare rev-parse refs/heads/main).Trim() | Should-Be $originSha
        (& git -C $bare rev-parse "refs/heads/$($result.Branch)").Trim() | Should-Be $result.Sha
    }

    It 'keeps the refusal on the push-stage failure when the fallback branch is refused too' {
        $bare = New-Origin
        Add-RejectPushHook -BarePath $bare -All
        $caught = $null
        try { $null = Publish-RulebookUpdate -Plan $plan -Repository 'Contoso/rulebook' -RemoteUrl $bare -Token 'ghs_x' -UpdateBranch 'main' -DirectCommit -WorkPath (Get-TestFolder) -Now $now } catch { $caught = $_ }
        $caught | Should-NotBeNull
        $caught.Exception.Data['Stage'] | Should-Be 'push'
        $caught.Exception.Data['FallbackReason'] | Should-BeLikeString '*every branch is protected*'
    }

    It 'refuses an invalid plan before anything else' {
        Mock New-GitHubClone -ModuleName Rulebook.Update { throw 'must not clone' }
        $invalid = $plan.PSObject.Copy()
        $invalid.Valid = $false
        { Publish-RulebookUpdate -Plan $invalid -Repository 'Contoso/rulebook' -Token 'ghs_x' -UpdateBranch 'main' } | Should-Throw -ExceptionMessage '*does not validate*'
        Should-Invoke New-GitHubClone -ModuleName Rulebook.Update -Times 0 -Exactly
        Should-Invoke Invoke-GitHubApi -ModuleName Rulebook.GitHub -Times 0 -Exactly
    }

    It 'names the pushed branch when the pull request cannot be opened' {
        $bare = New-Origin
        Mock Invoke-GitHubApi -ModuleName Rulebook.GitHub -ParameterFilter { $Method -eq 'POST' -and $Path -eq 'repos/Contoso/rulebook/pulls' } {
            [pscustomobject]@{ StatusCode = 422; Body = @{ message = 'Validation Failed' }; Text = ''; Headers = $null; RateLimitRemaining = $null }
        }
        $caught = $null
        try {
            Publish-RulebookUpdate -Plan $plan -Repository 'Contoso/rulebook' -RemoteUrl $bare -Token 'ghs_x' -UpdateBranch 'main' -WorkPath (Get-TestFolder) -Now $now
        } catch {
            $caught = $_
        }
        $caught.Exception.Data['Stage'] | Should-Be 'pull-request'
        $caught.Exception.Data['Branch'] | Should-Be 'update-rulebook-system-files/main/261007123045'
        $caught.Exception.Message | Should-BeLikeString 'Branch update-rulebook-system-files/main/261007123045 was pushed. *HTTP 422*https://github.com/Contoso/rulebook/tree/update-rulebook-system-files/main/261007123045*'
        ([regex]::Matches($caught.Exception.Message, [regex]::Escape('https://github.com/Contoso/rulebook/tree/'))).Count | Should-Be 1
        (& git -C $bare rev-parse --verify --quiet refs/heads/update-rulebook-system-files/main/261007123045) | Should-NotBeNull
    }

    It 'tags the duplicate guard as the pull request stage' {
        Mock Invoke-GitHubApi -ModuleName Rulebook.GitHub -ParameterFilter { $Method -eq 'GET' -and $Path -eq 'repos/Contoso/rulebook/branches/main' } {
            [pscustomobject]@{ StatusCode = 500; Body = @{ message = 'boom' }; Text = ''; Headers = $null; RateLimitRemaining = $null }
        }
        $caught = $null
        try { Publish-RulebookUpdate -Plan $plan -Repository 'Contoso/rulebook' -Token 'ghs_x' -UpdateBranch 'main' -WorkPath (Get-TestFolder) } catch { $caught = $_ }
        $caught.Exception.Data['Stage'] | Should-Be 'pull-request'
    }

    It 'names the stage when the push fails' {
        $caught = $null
        try {
            Publish-RulebookUpdate -Plan $plan -Repository 'Contoso/rulebook' -RemoteUrl (Join-Path (Get-TestFolder) 'missing.git') -Token 'ghs_x' -UpdateBranch 'main' -WorkPath (Get-TestFolder)
        } catch {
            $caught = $_
        }
        $caught | Should-NotBeNull
        $caught.Exception.Data['Stage'] | Should-Be 'push'
    }
}

Describe 'ConvertTo-UpdatePullRequestBody and ConvertTo-UpdateSummary' {
    BeforeAll {
        $script:plan = Get-Plan
    }

    It 'says there is no effective change and leaves the release notes out when the template ships none' {
        $copy = $plan.PSObject.Copy()
        $copy.ReleaseNotesShipped = $false
        $copy.Skipped = @()
        $copy.Notes = @()
        $body = ConvertTo-UpdatePullRequestBody -Plan $copy -Diff @() -Branch 'main'
        $body | Should-MatchString '(?m)^No effective change\.$'
        $body | Should-NotMatchString '## Release notes'
        $body | Should-NotMatchString '## Skipped'
    }

    It 'writes No release notes available when nothing is new' {
        $copy = $plan.PSObject.Copy()
        $copy.ReleaseNotes = ''
        ConvertTo-UpdatePullRequestBody -Plan $copy -Diff @() -Branch 'main' | Should-MatchString '(?m)^## Release notes\n\nNo release notes available$'
    }

    It 'keeps fenced code in the release notes as it is and moves the other headings down' {
        $copy = $plan.PSObject.Copy()
        $copy.ReleaseNotes = "# Release notes`n`n## v1.1`n`n``````powershell`n# comment`n## heading`n```````n`n~~~`n# tilde`n~~~`n`n### Detail`n"
        $body = ConvertTo-UpdatePullRequestBody -Plan $copy -Diff @() -Branch 'main'
        $notes = $body.Substring($body.IndexOf("## Release notes`n", [System.StringComparison]::Ordinal))
        $notes | Should-Be "## Release notes`n`n### v1.1`n`n``````powershell`n# comment`n## heading`n```````n`n~~~`n# tilde`n~~~`n`n#### Detail`n`n"
    }

    It 'drops the release notes first, then endpoint tables from the end, when the body is too long' {
        $diff = @(foreach ($endpoint in 'a.default', 'b.default', 'c.default') {
                foreach ($i in 1..20) { [pscustomobject]@{ Endpoint = $endpoint; File = "rulesets/$endpoint.json"; Id = ('LC{0:0000}' -f $i); Before = 'None'; After = 'Error'; BeforeSource = 'default'; AfterSource = 'level:x'; AfterDetail = $null; Change = 'action'; ListedAfter = $true } }
            })
        $copy = $plan.PSObject.Copy()
        $copy.ReleaseNotes = "## v1.1`n`n" + ('- a long line of release notes' * 200) + "`n"
        $full = ConvertTo-UpdatePullRequestBody -Plan $copy -Diff $diff -Branch 'main' -Limit 1000000
        $full | Should-MatchString 'a long line of release notes'

        $withoutNotes = ConvertTo-UpdatePullRequestBody -Plan $copy -Diff $diff -Branch 'main' -Limit ($full.Length - 1000)
        $withoutNotes.Length | Should-BeLessThanOrEqual ($full.Length - 1000)
        $withoutNotes | Should-NotMatchString 'a long line of release notes'
        $withoutNotes | Should-MatchString '(?m)^_The release notes were left out'
        $withoutNotes | Should-MatchString '(?m)^### `c\.default`'

        $limit = $withoutNotes.Length - 500
        $short = ConvertTo-UpdatePullRequestBody -Plan $copy -Diff $diff -Branch 'main' -Limit $limit
        $short.Length | Should-BeLessThanOrEqual $limit
        $short | Should-MatchString '(?m)^### `a\.default`'
        $short | Should-NotMatchString '(?m)^### `c\.default`'
        $short | Should-MatchString '(?m)^_1 of 3 endpoint tables of the effective diff were left out'
        # Whole rows only.
        foreach ($line in $short.Split("`n")) { if ($line.StartsWith('| LC')) { $line | Should-MatchString '^\| LC\d{4} \| None \| Error \| level:x \|$' } }
    }

    It 'cuts at a line boundary when dropping parts is not enough' {
        $copy = $plan.PSObject.Copy()
        $body = ConvertTo-UpdatePullRequestBody -Plan $copy -Diff @() -Branch 'main' -Limit 600
        $body.Length | Should-BeLessThanOrEqual 600
        $body | Should-MatchString '\n_The body was cut at a line boundary[^\n]*_\n$'
        $kept = $body.Substring(0, $body.IndexOf("`n_The body was cut", [System.StringComparison]::Ordinal))
        $full = ConvertTo-UpdatePullRequestBody -Plan $copy -Diff @() -Branch 'main'
        $kept.EndsWith("`n", [System.StringComparison]::Ordinal) | Should-BeTrue
        $full.StartsWith($kept, [System.StringComparison]::Ordinal) | Should-BeTrue
    }

    It 'writes why the effective diff is missing and the release notes into the summary' {
        $result = [pscustomobject]@{ Result = 'pull-request'; PullRequestUrl = 'https://github.com/Contoso/rulebook/pull/3'; Fallback = $false; Diff = @(); DiffNote = 'The effective diff could not be computed: boom' }
        $summary = ConvertTo-UpdateSummary -Plan $plan -Result $result -Mode update
        $summary | Should-MatchString '(?m)^## Effective diff\n\nThe effective diff could not be computed: boom$'
        $summary | Should-MatchString '(?m)^## Release notes\n\n### v1\.1$'
    }

    It 'writes the effective diff tables into the summary, not System.String[] (#75)' {
        $row = [pscustomobject]@{ Endpoint = 'recommended.default'; File = 'rulesets/recommended.ruleset.json'; Id = 'LC0031'; Before = 'Warning'; After = 'Error'; BeforeSource = 'default'; AfterSource = 'level:recommended'; AfterDetail = $null; Change = 'action'; ListedAfter = $true }
        $result = [pscustomobject]@{ Result = 'pull-request'; PullRequestUrl = 'https://github.com/Contoso/rulebook/pull/3'; Fallback = $false; Diff = @($row) }
        $summary = ConvertTo-UpdateSummary -Plan $plan -Result $result -Mode update
        $summary | Should-MatchString '(?m)^## Effective diff\n\n### `recommended\.default` \(`rulesets/recommended\.ruleset\.json`\)\n\n\| Id \| Before \| After \| Decided by \|\n\|---\|---\|---\|---\|\n\| LC0031 \| Warning \| Error \| level:recommended \|$'
        $summary | Should-NotMatchString 'System\.String\[\]'
    }

    It 'writes the check summary with the change table' {
        $summary = ConvertTo-UpdateSummary -Plan $plan -Mode check -Message 'Updates available'
        $summary | Should-MatchString '(?m)^## Template update check$'
        $summary | Should-MatchString '(?m)^\| `base/recommended\.ruleset\.json` \| overwrite \| modified \|$'
        $summary | Should-MatchString '(?m)^- `site/layouts/index\.html`: local changes$'
    }
}
