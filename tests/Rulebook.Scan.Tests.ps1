# Scan suite for WP08 (#10): modules/Rulebook.Scan on copies of tests/fixtures/repos/valid-minimal with a quarantine
# policy, against flat containers of the stub analyzer packages (tests/Helpers/StubFeed.ps1). The GitHub API is mocked
# at Invoke-GitHubApi; the git side of Publish-RulebookScan runs against a bare repository.

BeforeDiscovery {
    $script:gitMissing = $null -eq (Get-Command git -ErrorAction SilentlyContinue)
}

BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $PSScriptRoot 'Helpers' 'RepoFixture.ps1')
    . (Join-Path $PSScriptRoot 'Helpers' 'StubFeed.ps1')
    Import-Module (Join-Path $repoRoot 'modules' 'Rulebook.Generate.psd1') -Force
    Import-Module (Join-Path $repoRoot 'modules' 'Rulebook.Catalog.psd1') -Force
    Import-Module (Join-Path $repoRoot 'modules' 'Rulebook.Quarantine.psd1') -Force
    Import-Module (Join-Path $repoRoot 'modules' 'Rulebook.GitHub.psd1') -Force
    Import-Module (Join-Path $repoRoot 'modules' 'Rulebook.Scan.psd1') -Force
    $script:tools = 'microsoft.dynamics.businesscentral.development.tools'
    $script:alcops = 'alcops.analyzers'
    $script:now = [System.DateTimeOffset]::new(2026, 10, 8, 4, 17, 31, [System.TimeSpan]::Zero)
    $script:utf8 = [System.Text.UTF8Encoding]::new($false)
    $script:savedServerUrl = $env:GITHUB_SERVER_URL
    $script:savedApiUrl = $env:GITHUB_API_URL
    $env:GITHUB_SERVER_URL = $null
    $env:GITHUB_API_URL = $null
    $script:feed = New-StubFeed -Variants 'tools-stable', 'tools-prerelease', 'alcops-v1', 'alcops-v2' -Destination (Join-Path $TestDrive 'feed') -IndexOnly @{ 'alcops.analyzers' = '1.3.0-beta.1' }
    $script:feedStable = New-StubFeed -Variants 'tools-stable', 'tools-prerelease', 'alcops-v1', 'alcops-v2', 'alcops-v3' -Destination (Join-Path $TestDrive 'feed-1.4.0')

    function Get-TestFolder {
        return Join-Path $TestDrive ([guid]::NewGuid().ToString('n').Substring(0, 12))
    }

    function New-Org {
        # valid-minimal with the policy default and ci for stable, ci for prerelease.
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helper; builds an object or writes only to TestDrive')]
        param()
        $root = New-FixtureRepo -Name 'valid-minimal' -Destination (Get-TestFolder)
        Edit-FixtureJson -Path (Join-Path $root '.github' 'Rulebook-Settings.json') -Script { $_.quarantine = [ordered]@{ stages = @('default', 'ci'); prereleaseStages = @('ci') } }
        return $root
    }

    function Get-Plan {
        param([string]$Root, [string]$Source = $script:feed, [bool]$IncludePrerelease = $true, [System.DateTimeOffset]$At = $script:now)
        return Get-RulebookScanPlan -RepositoryRoot $Root -Source $Source -WorkPath (Get-TestFolder) -Now $At -IncludePrerelease $IncludePrerelease
    }

    function Get-Rules {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Test helper; returns the rule ids')]
        param([string]$Root, [string]$Stage)
        return @((Read-QuarantineFile -Path (Join-Path $Root "quarantine.$Stage.json")).Rules.Keys)
    }

    function Copy-Candidate {
        # The candidate of a plan as a new repository root (the state after the scan pull request is merged).
        param($Plan)
        $root = Get-TestFolder
        Copy-FixtureTree -Source $Plan.CandidatePath -Destination $root
        return $root
    }

    function New-FakePlan {

        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helper; builds an object or writes only to TestDrive')]
        # A plan with only what the title needs.
        param([string]$Mode = 'scan', [object[]]$Scanned = @(), [object[]]$Added = @(), [object[]]$Removed = @())
        return [pscustomobject]@{ Mode = $Mode; Scanned = $Scanned; Quarantine = [pscustomobject]@{ Added = $Added; Removed = $Removed; Created = @() } }
    }

    function New-FakeScan {

        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helper; builds an object or writes only to TestDrive')]
        param([string]$Label = 'alcops', [string]$Version = '1.4.0', [string]$Channel = 'stable', [string[]]$NewIds = @(), [string[]]$Promoted = @(), [object[]]$ChangedDefaults = @(), [object[]]$PrereleaseDefaultChanges = @(), [string[]]$Unadvertised = @())
        $diff = [pscustomobject]@{ NewIds = $NewIds; Promoted = $Promoted; ChangedDefaults = $ChangedDefaults; PrereleaseDefaultChanges = $PrereleaseDefaultChanges; Unadvertised = $Unadvertised; Refreshed = @(); Recorded = @(); Vanished = @(); Deprecated = @() }
        return [pscustomobject]@{ Label = $Label; Version = $Version; Channel = $Channel; Diff = $diff }
    }

    $script:org = New-Org
    $script:first = Get-Plan -Root $org
}

AfterAll {
    $env:GITHUB_SERVER_URL = $script:savedServerUrl
    $env:GITHUB_API_URL = $script:savedApiUrl
    Remove-Module Rulebook.Scan, Rulebook.Quarantine, Rulebook.Extract, Rulebook.Catalog, Rulebook.NuGet, Rulebook.Update, Rulebook.Template, Rulebook.GitHub, Rulebook.Validate, Rulebook.Generate -ErrorAction SilentlyContinue
}

Describe 'Get-RulebookScanPlan, first run' {
    It 'scans the four new versions, tools before alcops, stable before prerelease' {
        $first.Failure | Should-BeNull
        $first.Mode | Should-Be 'scan'
        @($first.NewVersions | ForEach-Object { "$($_.PackageId) $($_.Channel) $($_.Version)" }) | Should-BeCollection @(
            "$tools stable 18.0.43.1464"
            "$tools prerelease 30.0.42.60748-beta"
            "$alcops stable 1.3.1"
            "$alcops prerelease 1.4.0-beta.1"
        )
        @($first.Scanned | Where-Object PackageId -EQ $alcops | ForEach-Object { $_.Extraction.HostVersion }) | Should-BeCollection @('18.0.43.1464', '30.0.42.60748-beta')
    }

    It 'quarantines new stable ids in stages and new prerelease ids in prereleaseStages' {
        Get-Rules $first.CandidatePath 'default' | Should-BeCollection @('LC0099', 'AL1027', 'AL1030', 'AA0003', 'ZZ0001')
        Get-Rules $first.CandidatePath 'ci' | Should-BeCollection @('LC0099', 'AL1027', 'AL1030', 'AA0003', 'ZZ0001', 'LC0100')
        Get-Rules $first.CandidatePath 'vnext' | Should-BeCollection @()
        (Read-QuarantineFile -Path (Join-Path $first.CandidatePath 'quarantine.ci.json')).Rules['LC0100'] | Should-Be 'New in alcops.analyzers 1.4.0-beta.1 (prerelease), quarantined 2026-10-08. Review and adopt.'
    }

    It 'catalogs the unadvertised ids without quarantining them' {
        $catalog = Read-CatalogFile -Path (Join-Path $first.CandidatePath 'catalog' 'diagnostics.json')
        $catalog.Entries['AA0002'].Advertised | Should-BeFalse
        $catalog.Entries['LC0000'].Advertised | Should-BeFalse
        $first.Counts.Unadvertised | Should-Be 2
        $first.Counts.NewIds | Should-Be 5
        $first.Counts.Quarantined | Should-Be 5
    }

    It 'records the seeded ids and fills the scan fields' {
        $catalog = Read-CatalogFile -Path (Join-Path $first.CandidatePath 'catalog' 'diagnostics.json')
        $entry = $catalog.Entries['LC0015']
        '{0} {1} {2} {3} {4}' -f $entry.Package, $entry.FirstSeenVersion, $entry.FirstSeenChannel, $entry.FirstStableVersion, $entry.LastSeenVersion | Should-Be 'alcops.analyzers 1.3.1 stable 1.3.1 1.4.0-beta.1'
        $entry.DefaultSeverity | Should-Be 'Info'
        $catalog.Entries['LC0100'].FirstSeenChannel | Should-Be 'prerelease'
        $catalog.Entries['TA0001'].Docs | Should-Be 'https://alcops.dev/docs/analyzers/testautomationcop/ta0001/'
        $catalog.Entries['AL0001'].Package | Should-BeNull
    }

    It 'lists the prerelease default change without applying it' {
        @($first.Scanned | ForEach-Object { $_.Diff.PrereleaseDefaultChanges } | ForEach-Object { "$($_.Id) $($_.From) $($_.To) $($_.Version)" }) | Should-BeCollection @('LC0015 Info Warning 1.4.0-beta.1')
    }

    It 'creates the scan state with the scanned versions' {
        $state = Read-ScanState -Path (Join-Path $first.CandidatePath 'catalog' 'scan-state.json')
        $state.Packages[$tools].Stable.Version | Should-Be '18.0.43.1464'
        $state.Packages[$tools].Prerelease.Version | Should-Be '30.0.42.60748-beta'
        $state.Packages[$alcops].Stable.Version | Should-Be '1.3.1'
        $state.Packages[$alcops].Prerelease.ScannedAt | Should-Be '2026-10-08T04:17:31Z'
    }

    It 'regenerates the endpoints, validates and lists the changes' {
        $first.Valid | Should-BeTrue
        @($first.Findings | Where-Object Severity -EQ 'error') | Should-BeCollection @()
        $files = @($first.Changes | ForEach-Object { "$($_.Change) $($_.File)" })
        $files | Should-ContainCollection @('modified catalog/diagnostics.json', 'created catalog/scan-state.json', 'modified quarantine.ci.json', 'modified quarantine.default.json', 'modified rulesets/strict.ci.ruleset.json')
        $files | Should-NotContainCollection @('modified quarantine.vnext.json')
        (Read-RulesetFile -Path (Join-Path $first.CandidatePath 'rulesets' 'strict.ci.ruleset.json')).Rules['LC0100'].Action | Should-Be 'None'
        (Read-RulesetFile -Path (Join-Path $first.CandidatePath 'rulesets' 'strict.ruleset.json')).Rules.Contains('LC0100') | Should-BeFalse
    }

    It 'titles the run' {
        Get-ScanTitle -Plan $first | Should-Be 'Scan diagnostics: 5 new ids quarantined (alcops 1.3.1, alcops 1.4.0-beta.1, tools 18.0.43.1464, tools 30.0.42.60748-beta)'
    }

    It 'leaves the repository alone' {
        Test-Path -LiteralPath (Join-Path $org 'catalog' 'scan-state.json') | Should-BeFalse
        Get-Rules $org 'default' | Should-BeCollection @('LC0099')
    }
}

Describe 'Get-RulebookScanPlan, later runs' {
    It 'finds nothing new on the merged result' {
        $plan = Get-Plan -Root (Copy-Candidate $first)
        $plan.Mode | Should-Be 'nothing-new'
        $plan.CandidatePath | Should-BeNull
        $plan.Valid | Should-BeTrue
        $plan.NewVersions | Should-BeCollection @()
    }

    It 'promotes the prerelease id and applies the stable default change of 1.4.0 (AC3, AC8)' {
        $plan = Get-Plan -Root (Copy-Candidate $first) -Source $feedStable -At $now.AddDays(5)
        @($plan.NewVersions | ForEach-Object { "$($_.PackageId) $($_.Channel) $($_.Version)" }) | Should-BeCollection @("$alcops stable 1.4.0")
        Get-Rules $plan.CandidatePath 'default' | Should-ContainCollection @('LC0100')
        (Read-QuarantineFile -Path (Join-Path $plan.CandidatePath 'quarantine.default.json')).Rules['LC0100'] | Should-BeLikeString 'New in alcops.analyzers 1.4.0 (stable), quarantined 2026-10-13*'
        (Read-QuarantineFile -Path (Join-Path $plan.CandidatePath 'quarantine.ci.json')).Rules['LC0100'] | Should-BeLikeString '*1.4.0-beta.1 (prerelease), quarantined 2026-10-08*'
        $entry = (Read-CatalogFile -Path (Join-Path $plan.CandidatePath 'catalog' 'diagnostics.json')).Entries['LC0015']
        $entry.DefaultSeverity | Should-Be 'Warning'
        @($entry.DefaultChanges | ForEach-Object { "$($_['version']) $($_['field']) $($_['from']) $($_['to'])" }) | Should-BeCollection @('1.4.0 defaultSeverity Info Warning')
        Get-ScanTitle -Plan $plan | Should-Be 'Scan diagnostics: 1 id promoted to stable, 1 default changed (alcops 1.4.0)'
        $plan.Valid | Should-BeTrue
    }

    It 'releases adopted ids without a new package version (housekeeping)' {
        $root = Copy-Candidate $first
        Edit-FixtureJson -Path (Join-Path $root 'base' 'complete.ruleset.json') -Script { $_.rules += @{ id = 'AL1027'; action = 'Warning' } }
        $plan = Get-Plan -Root $root
        $plan.Mode | Should-Be 'housekeeping'
        @($plan.Quarantine.Removed | ForEach-Object { "$($_.Stage) $($_.Id)" }) | Should-BeCollection @('default AL1027', 'ci AL1027')
        Get-ScanTitle -Plan $plan | Should-Be 'Scan diagnostics: 1 quarantine entry released, no new package version'
        $plan.Counts.Released | Should-Be 1
        @($plan.Changes | ForEach-Object File) | Should-NotContainCollection @('catalog/scan-state.json', 'catalog/diagnostics.json')
        $plan.Valid | Should-BeTrue
    }

    It 'leaves the prerelease channel alone with -IncludePrerelease $false' {
        $plan = Get-Plan -Root $org -IncludePrerelease $false
        @($plan.NewVersions | ForEach-Object Channel | Select-Object -Unique) | Should-BeCollection @('stable')
        $state = Read-ScanState -Path (Join-Path $plan.CandidatePath 'catalog' 'scan-state.json')
        $state.Packages[$alcops].Prerelease | Should-BeNull
    }

    It 'fails with failure extract on a package that does not load' {
        $broken = Join-Path $TestDrive 'feed-broken'
        Copy-FixtureTree -Source $feed -Destination $broken
        $nupkg = Join-Path $broken $tools '18.0.43.1464' "$tools.18.0.43.1464.nupkg"
        $zip = [System.IO.Compression.ZipFile]::Open($nupkg, 'Update')
        try {
            foreach ($entry in @($zip.Entries | Where-Object FullName -Like '*/Microsoft.Dynamics.Nav.UICop.dll')) {
                $name = $entry.FullName
                $entry.Delete()
                $writer = [System.IO.StreamWriter]::new($zip.CreateEntry($name).Open())
                try { $writer.Write('not an assembly') } finally { $writer.Dispose() }
            }
        } finally {
            $zip.Dispose()
        }
        $plan = Get-Plan -Root $org -Source $broken
        $plan.Failure | Should-Be 'extract'
        $plan.FailureMessage | Should-BeLikeString 'Extraction failed for*UICop*'
        $plan.Valid | Should-BeFalse
    }

    It 'fails with failure nuget when an index is missing' {
        $partial = New-StubFeed -Variants 'tools-stable' -Destination (Join-Path $TestDrive 'feed-partial')
        $plan = Get-Plan -Root $org -Source $partial
        $plan.Failure | Should-Be 'nuget'
        $plan.FailureMessage | Should-Be 'Could not read the NuGet index of alcops.analyzers (HTTP 404)'
    }

    It 'throws the policy message when the settings have none' {
        $root = New-FixtureRepo -Name 'valid-minimal' -Destination (Get-TestFolder)
        { Get-Plan -Root $root } | Should-Throw -ExceptionMessage 'Set quarantine.stages and quarantine.prereleaseStages*'
    }

    It 'does not validate when a level file names an id the catalog lacks (C7 is an error with the scan state)' {
        $root = New-Org
        Edit-FixtureJson -Path (Join-Path $root 'base' 'complete.ruleset.json') -Script { $_.rules += @{ id = 'LC0999'; action = 'Error' } }
        $plan = Get-Plan -Root $root
        $plan.Valid | Should-BeFalse
        @($plan.Findings | Where-Object Severity -EQ 'error' | ForEach-Object { "$($_.Rule) $($_.File) $($_.Id)" }) | Should-ContainCollection @('C7 base/complete.ruleset.json LC0999')
    }
}

Describe 'Get-ScanTitle' {
    It '<Case>' -ForEach @(
        @{ Case = 'one new id quarantined'; Expected = 'Scan diagnostics: 1 new id quarantined (alcops 1.4.0)'; Plan = { New-FakePlan -Scanned @(New-FakeScan -NewIds 'LC0100') -Added @([pscustomobject]@{ Stage = 'default'; Id = 'LC0100' }) } }
        @{ Case = 'new ids no policy stage took'; Expected = 'Scan diagnostics: 3 new ids recorded (alcops 1.4.0)'; Plan = { New-FakePlan -Scanned @(New-FakeScan -NewIds 'LC0100', 'LC0101', 'LC0102') } }
        @{ Case = 'unadvertised new ids do not count'; Expected = 'Scan diagnostics: alcops 1.4.0 recorded, no new diagnostics'; Plan = { New-FakePlan -Scanned @(New-FakeScan -NewIds 'LC0000' -Unadvertised 'LC0000') } }
        @{ Case = 'every part in order'; Expected = 'Scan diagnostics: 2 new ids quarantined, 1 new id recorded, 2 ids promoted to stable, 2 defaults changed, 1 quarantine entry released (alcops 1.4.0, tools 18.0.44.1)'; Plan = {
                New-FakePlan -Scanned @(
                    New-FakeScan -Label 'tools' -Version '18.0.44.1' -NewIds 'AL1100' -ChangedDefaults @([pscustomobject]@{ Id = 'AA0001' })
                    New-FakeScan -NewIds 'LC0100', 'LC0101' -Promoted 'LC0090', 'LC0091' -ChangedDefaults @([pscustomobject]@{ Id = 'LC0015' }) -PrereleaseDefaultChanges @([pscustomobject]@{ Id = 'LC0016' })
                ) -Added @([pscustomobject]@{ Stage = 'default'; Id = 'LC0100' }, [pscustomobject]@{ Stage = 'ci'; Id = 'LC0101' }) -Removed @([pscustomobject]@{ Stage = 'ci'; Id = 'LC0050' }) } }
        @{ Case = 'a record run of one version'; Expected = 'Scan diagnostics: alcops 1.3.2 recorded, no new diagnostics'; Plan = { New-FakePlan -Scanned @(New-FakeScan -Version '1.3.2') } }
        @{ Case = 'a record run of two versions'; Expected = 'Scan diagnostics: alcops 1.3.2 and tools 30.0.42.60748-beta recorded, no new diagnostics'; Plan = { New-FakePlan -Scanned @((New-FakeScan -Label 'tools' -Version '30.0.42.60748-beta' -Channel prerelease), (New-FakeScan -Version '1.3.2')) } }
        @{ Case = 'a prerelease default change alone'; Expected = 'Scan diagnostics: alcops 1.5.0-beta.1 recorded, no new diagnostics'; Plan = { New-FakePlan -Scanned @(New-FakeScan -Version '1.5.0-beta.1' -Channel prerelease -PrereleaseDefaultChanges @([pscustomobject]@{ Id = 'LC0016' })) } }
        @{ Case = 'housekeeping'; Expected = 'Scan diagnostics: 1 quarantine entry released, no new package version'; Plan = { New-FakePlan -Mode housekeeping -Removed @([pscustomobject]@{ Stage = 'ci'; Id = 'LC0050' }) } }
    ) {
        Get-ScanTitle -Plan (& $Plan) | Should-Be $Expected
    }
}

Describe 'ConvertTo-ScanPullRequestBody' {
    It 'has the sections of a first run in order' {
        $body = ConvertTo-ScanPullRequestBody -Plan $first -Base 'main' -BaseSha '0123456789abcdef0123456789abcdef01234567'
        @([regex]::Matches($body, '(?m)^## (.+)$') | ForEach-Object { $_.Groups[1].Value }) | Should-BeCollection @('Scanned versions', 'New diagnostics', 'Prerelease default changes (not applied)', 'Catalog notes', 'Changes', 'Effective diff')
        $body | Should-MatchString 'on branch `scan-diagnostics/main`: do not push to that branch'
        $body | Should-MatchString '(?m)^\| AA0002 \| CodeCop \| Info \(disabled\) \| Field-only descriptor \|  \| microsoft\.dynamics\.businesscentral\.development\.tools 18\.0\.43\.1464 \(stable\) \| nowhere \(not advertised\) \|$'
        $body | Should-MatchString '(?m)^\| LC0100 \| LinterCop \| Info \| A rule new in 1\.4\.0 \| \[docs\]\(<https://alcops\.dev/docs/analyzers/lintercop/lc0100/>\) \| alcops\.analyzers 1\.4\.0-beta\.1 \(prerelease\) \| ci \|$'
        $body.StartsWith('Diagnostic scan of 2026-10-08 on `main` at 0123456. Scanned ', [System.StringComparison]::Ordinal) | Should-BeTrue
    }

    It 'neutralises a mention in a package title' {
        $plan = Get-Plan -Root $org
        $plan.CatalogAfter.Entries['LC0100'].Title = 'Ping @octocat and @ALCops/team'
        $body = ConvertTo-ScanPullRequestBody -Plan $plan -Base 'main'
        $body | Should-MatchString ('Ping @{0}octocat and @{0}ALCops/team' -f [char]0x200B)
        $body | Should-NotMatchString '(?<!\u200B)@octocat'.Replace('\u200B', [string][char]0x200B)
    }

    It 'names the endpoints a changed default joins or leaves' {
        $plan = Get-Plan -Root (Copy-Candidate $first) -Source $feedStable
        $diff = @(
            [pscustomobject]@{ Endpoint = 'strict.default'; File = 'rulesets/strict.ruleset.json'; Id = 'LC0015'; Change = 'listing'; ListedAfter = $false; Before = 'Warning'; After = 'Warning'; BeforeSource = 'level'; AfterSource = 'level'; AfterDetail = $null }
            [pscustomobject]@{ Endpoint = 'strict.ci'; File = 'rulesets/strict.ci.ruleset.json'; Id = 'LC0015'; Change = 'listing'; ListedAfter = $true; Before = 'Info'; After = 'Info'; BeforeSource = 'stage'; AfterSource = 'stage'; AfterDetail = $null }
        )
        $body = ConvertTo-ScanPullRequestBody -Plan $plan -Diff $diff -Base 'main'
        $body | Should-MatchString '(?m)^\| LC0015 \| defaultSeverity \| Info \| Warning \| 1\.4\.0 \| now listed at Info in strict\.ci; now unlisted in strict\.default \|$'
        $body | Should-MatchString '(?m)^## Promoted to stable$'
    }

    It 'drops effective diff tables, then new diagnostics rows, then cuts, to stay below -Limit' {
        $diff = @(foreach ($endpoint in 'a', 'b', 'c') { [pscustomobject]@{ Endpoint = $endpoint; File = "rulesets/$endpoint.ruleset.json"; Id = 'LC0100'; Change = 'action'; ListedAfter = $true; Before = 'Info'; After = 'None'; BeforeSource = 'default'; AfterSource = 'quarantine'; AfterDetail = $null } })
        $full = ConvertTo-ScanPullRequestBody -Plan $first -Diff $diff -Base 'main'
        $limited = ConvertTo-ScanPullRequestBody -Plan $first -Diff $diff -Base 'main' -Limit ($full.Length - 10)
        $limited | Should-MatchString '_[12] of 3 endpoint tables of the effective diff were left out'
        $limited.Length | Should-BeLessThanOrEqual ($full.Length - 10)
        $tiny = ConvertTo-ScanPullRequestBody -Plan $first -Diff $diff -Base 'main' -Limit 900
        $tiny.Length | Should-BeLessThanOrEqual 900
        $tiny | Should-MatchString 'The body was cut at a line boundary'
    }
}

Describe 'Publish-RulebookScan against a bare repository' -Skip:$gitMissing {
    BeforeAll {
        $script:origin = New-BareFixtureRepo -Source $org -Destination (Join-Path (Get-TestFolder) 'origin.git')
        $script:originSha = (& git -C $origin rev-parse refs/heads/main).Trim()
        $script:plan = $first
    }

    BeforeEach {
        $script:openPulls = @()
        Mock Invoke-GitHubApi -ModuleName Rulebook.GitHub -ParameterFilter { $Method -eq 'GET' -and $Path -like 'repos/Contoso/rulebook/pulls?*' } {
            [pscustomobject]@{ StatusCode = 200; Body = @($script:openPulls); Text = ''; Headers = $null; RateLimitRemaining = $null }
        }
        Mock Invoke-GitHubApi -ModuleName Rulebook.GitHub -ParameterFilter { $Method -eq 'POST' -and $Path -eq 'repos/Contoso/rulebook/pulls' } {
            [pscustomobject]@{ StatusCode = 201; Body = @{ number = 21; html_url = 'https://github.com/Contoso/rulebook/pull/21' }; Text = ''; Headers = $null; RateLimitRemaining = $null }
        }
        Mock Invoke-GitHubApi -ModuleName Rulebook.GitHub -ParameterFilter { $Method -eq 'POST' -and $Path -eq 'repos/Contoso/rulebook/issues/21/labels' } {
            [pscustomobject]@{ StatusCode = 200; Body = @(); Text = '[]'; Headers = $null; RateLimitRemaining = $null }
        }
        Mock Invoke-GitHubApi -ModuleName Rulebook.GitHub -ParameterFilter { $Method -eq 'PATCH' -and $Path -eq 'repos/Contoso/rulebook/pulls/21' } {
            [pscustomobject]@{ StatusCode = 200; Body = @{ number = 21; html_url = 'https://github.com/Contoso/rulebook/pull/21' }; Text = ''; Headers = $null; RateLimitRemaining = $null }
        }
    }

    It 'opens the pull request from scan-diagnostics/main on the first run' {
        $result = Publish-RulebookScan -Plan $plan -Repository 'Contoso/rulebook' -RemoteUrl $origin -Token 'ghs_x' -BaseBranch 'main' -Actor 'octocat' -Labels @('rulebook') -WorkPath (Get-TestFolder)
        $result.Result | Should-Be 'pull-request'
        $result.Branch | Should-Be 'scan-diagnostics/main'
        $result.Title | Should-Be (Get-ScanTitle -Plan $plan)
        (& git -C $origin log -1 --format=%s scan-diagnostics/main) | Should-Be $result.Title
        (& git -C $origin rev-list --count main..scan-diagnostics/main).Trim() | Should-Be '1'
        @($result.Diff | Where-Object Id -EQ 'LC0100' | ForEach-Object Endpoint) | Should-ContainCollection @('strict.ci')
        Should-Invoke Invoke-GitHubApi -ModuleName Rulebook.GitHub -Times 1 -Exactly -ParameterFilter { $Method -eq 'POST' -and $Path -eq 'repos/Contoso/rulebook/pulls' -and $Body.head -eq 'scan-diagnostics/main' -and $Body.base -eq 'main' }
        Should-Invoke Invoke-GitHubApi -ModuleName Rulebook.GitHub -Times 1 -Exactly -ParameterFilter { $Method -eq 'GET' -and $Path -like '*head=Contoso%3Ascan-diagnostics%2Fmain*' }
    }

    It 'rebuilds the branch one commit above main and updates the open pull request on the next run' {
        $script:openPulls = @(@{ number = 21; title = 'old title'; html_url = 'https://github.com/Contoso/rulebook/pull/21' })
        $result = Publish-RulebookScan -Plan $plan -Repository 'Contoso/rulebook' -RemoteUrl $origin -Token 'ghs_x' -BaseBranch 'main' -WorkPath (Get-TestFolder)
        $result.Result | Should-Be 'pull-request-updated'
        $result.Number | Should-Be 21
        (& git -C $origin rev-list --count main..scan-diagnostics/main).Trim() | Should-Be '1'
        (& git -C $origin rev-parse scan-diagnostics/main).Trim() | Should-Be $result.Sha
        Should-Invoke Invoke-GitHubApi -ModuleName Rulebook.GitHub -Times 1 -Exactly -ParameterFilter { $Method -eq 'PATCH' -and $Body.title -eq (Get-ScanTitle -Plan $plan) -and $Body.body -like 'Diagnostic scan of 2026-10-08*' }
        Should-Invoke Invoke-GitHubApi -ModuleName Rulebook.GitHub -Times 0 -Exactly -ParameterFilter { $Method -eq 'POST' -and $Path -eq 'repos/Contoso/rulebook/pulls' }
    }

    It 'pushes a direct commit to main' {
        $bare = New-BareFixtureRepo -Source $org -Destination (Join-Path (Get-TestFolder) 'direct.git')
        $result = Publish-RulebookScan -Plan $plan -Repository 'Contoso/rulebook' -RemoteUrl $bare -Token 'ghs_x' -BaseBranch 'main' -DirectCommit -WorkPath (Get-TestFolder)
        $result.Result | Should-Be 'direct-commit'
        (& git -C $bare rev-parse refs/heads/main).Trim() | Should-Be $result.Sha
        Should-Invoke Invoke-GitHubApi -ModuleName Rulebook.GitHub -Times 0 -Exactly -ParameterFilter { $Method -eq 'POST' }
    }

    It 'falls back to the scan branch and a pull request when the direct push is refused' {
        $bare = New-BareFixtureRepo -Source $org -Destination (Join-Path (Get-TestFolder) 'protected.git')
        Add-RejectPushHook -BarePath $bare -Branch 'main'
        $result = Publish-RulebookScan -Plan $plan -Repository 'Contoso/rulebook' -RemoteUrl $bare -Token 'ghs_x' -BaseBranch 'main' -DirectCommit -WorkPath (Get-TestFolder) -WarningAction SilentlyContinue
        $result.Result | Should-Be 'pull-request'
        $result.Fallback | Should-BeTrue
        $result.Branch | Should-Be 'scan-diagnostics/main'
    }

    It 'names the pushed branch when the pull request cannot be opened' {
        $bare = New-BareFixtureRepo -Source $org -Destination (Join-Path (Get-TestFolder) 'refused.git')
        Mock Invoke-GitHubApi -ModuleName Rulebook.GitHub -ParameterFilter { $Method -eq 'POST' -and $Path -eq 'repos/Contoso/rulebook/pulls' } {
            [pscustomobject]@{ StatusCode = 403; Body = @{ message = 'GitHub Actions is not permitted to create or approve pull requests.' }; Text = ''; Headers = $null; RateLimitRemaining = $null }
        }
        $caught = $null
        try { $null = Publish-RulebookScan -Plan $plan -Repository 'Contoso/rulebook' -RemoteUrl $bare -Token 'ghs_x' -BaseBranch 'main' -WorkPath (Get-TestFolder) } catch { $caught = $_ }
        $caught.Exception.Data['Stage'] | Should-Be 'pull-request'
        $caught.Exception.Message | Should-BeLikeString 'Branch scan-diagnostics/main was pushed.*https://github.com/Contoso/rulebook/tree/scan-diagnostics/main*'
    }

    It 'closes the open scan pull request after a direct commit' {
        $bare = New-BareFixtureRepo -Source $org -Destination (Join-Path (Get-TestFolder) 'direct-close.git')
        $script:openPulls = @(@{ number = 21; title = 'Scan diagnostics: old'; html_url = 'https://github.com/Contoso/rulebook/pull/21'; body = 'old body' })
        $result = Publish-RulebookScan -Plan $plan -Repository 'Contoso/rulebook' -RemoteUrl $bare -Token 'ghs_x' -BaseBranch 'main' -DirectCommit -WorkPath (Get-TestFolder)
        $result.Result | Should-Be 'direct-commit'
        $result.ClosedPullRequestUrl | Should-Be 'https://github.com/Contoso/rulebook/pull/21'
        Should-Invoke Invoke-GitHubApi -ModuleName Rulebook.GitHub -Times 1 -Exactly -ParameterFilter { $Method -eq 'PATCH' -and $Body.state -eq 'closed' -and $Body.title -eq 'Scan diagnostics: old' -and $Body.body -like "Closed by the scan of 2026-10-08: its result is on main already (direct commit *).`n`nold body" }
    }

    It 'closes the open scan pull request when the base already contains the result' {
        $bare = New-BareFixtureRepo -Source (Copy-Candidate $plan) -Destination (Join-Path (Get-TestFolder) 'merged.git')
        $script:openPulls = @(@{ number = 21; title = 'Scan diagnostics: old'; html_url = 'https://github.com/Contoso/rulebook/pull/21'; body = 'old body' })
        $result = Publish-RulebookScan -Plan $plan -Repository 'Contoso/rulebook' -RemoteUrl $bare -Token 'ghs_x' -BaseBranch 'main' -WorkPath (Get-TestFolder)
        $result.Result | Should-Be 'no-changes'
        $result.ClosedPullRequestUrl | Should-Be 'https://github.com/Contoso/rulebook/pull/21'
        Should-Invoke Invoke-GitHubApi -ModuleName Rulebook.GitHub -Times 1 -Exactly -ParameterFilter { $Method -eq 'PATCH' -and $Body.state -eq 'closed' -and $Body.body -like 'Closed by the scan of 2026-10-08: the base branch main already contains its result.*' }
    }

    It 'writes the closing line once on a pull request closed before' {
        $bare = New-BareFixtureRepo -Source (Copy-Candidate $plan) -Destination (Join-Path (Get-TestFolder) 'merged-again.git')
        $script:openPulls = @(@{ number = 21; title = 'Scan diagnostics: old'; html_url = 'https://github.com/Contoso/rulebook/pull/21'; body = "Closed by the scan of 2026-10-01: the base branch main already contains its result.`n`nold body" })
        $null = Publish-RulebookScan -Plan $plan -Repository 'Contoso/rulebook' -RemoteUrl $bare -Token 'ghs_x' -BaseBranch 'main' -WorkPath (Get-TestFolder)
        Should-Invoke Invoke-GitHubApi -ModuleName Rulebook.GitHub -Times 1 -Exactly -ParameterFilter { $Method -eq 'PATCH' -and $Body.body -ceq "Closed by the scan of 2026-10-08: the base branch main already contains its result.`n`nold body" }
    }

    It 'closes nothing when no scan pull request is open' {
        $bare = New-BareFixtureRepo -Source (Copy-Candidate $plan) -Destination (Join-Path (Get-TestFolder) 'merged-none.git')
        $result = Publish-RulebookScan -Plan $plan -Repository 'Contoso/rulebook' -RemoteUrl $bare -Token 'ghs_x' -BaseBranch 'main' -WorkPath (Get-TestFolder)
        $result.ClosedPullRequestUrl | Should-BeNull
        Should-Invoke Invoke-GitHubApi -ModuleName Rulebook.GitHub -Times 0 -Exactly -ParameterFilter { $Method -eq 'PATCH' }
    }

    It 'refuses to push when the base branch moved after the plan' {
        $work = Get-TestFolder
        Copy-FixtureTree -Source $org -Destination $work
        $sha = New-FixtureGitRepo -Root $work -Message 'initial'
        $bare = Join-Path (Get-TestFolder) 'moving.git'
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $bare) -Force)
        $null = Invoke-FixtureGit -Root (Split-Path -Parent $bare) -Arguments @('clone', '-q', '--bare', $work, $bare)
        $moving = Get-Plan -Root $work
        $moving.HeadSha | Should-Be $sha
        Write-FixtureText -Path (Join-Path $work 'README.md') -Text 'moved'
        $moved = New-FixtureGitRepo -Root $work -Message 'moved'
        $null = Invoke-FixtureGit -Root $work -Arguments @('push', '-q', $bare, 'HEAD:refs/heads/main')
        $caught = $null
        try { $null = Publish-RulebookScan -Plan $moving -Repository 'Contoso/rulebook' -RemoteUrl $bare -Token 'ghs_x' -BaseBranch 'main' -WorkPath (Get-TestFolder) } catch { $caught = $_ }
        $caught.Exception.Data['Stage'] | Should-Be 'push'
        $caught.Exception.Message | Should-Be "The base branch moved during the scan (main $($sha.Substring(0, 7)) is now $($moved.Substring(0, 7))); nothing was pushed, the next run will pick it up."
        $caught.Exception.Data['Reason'] | Should-Be 'base-moved'
        (& git -C $bare branch --list 'scan-diagnostics/*') | Should-BeNull
    }

    It 'refuses an invalid or nothing-new plan' {
        { Publish-RulebookScan -Plan ([pscustomobject]@{ Valid = $false; Failure = $null; Mode = 'scan' }) -Repository 'Contoso/rulebook' -BaseBranch 'main' } | Should-Throw -ExceptionMessage 'The scan plan does not validate; nothing is pushed.'
        { Publish-RulebookScan -Plan ([pscustomobject]@{ Valid = $true; Failure = $null; Mode = 'nothing-new' }) -Repository 'Contoso/rulebook' -BaseBranch 'main' } | Should-Throw -ExceptionMessage 'The scan found nothing new; nothing is pushed.'
    }
}
