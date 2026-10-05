# Action suite for WP03 (#5): actions/Validate/action.yaml, its entry script Validate.ps1 run in-process, and the
# template workflow template/.github/workflows/Validate.yaml. The ci.yml job validate-action runs the action itself.

BeforeDiscovery {
    $script:gitMissing = $null -eq (Get-Command git -ErrorAction SilentlyContinue)
}

BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:actionDir = Join-Path $script:repoRoot 'actions' 'Validate'
    $script:entry = Join-Path $script:actionDir 'Validate.ps1'
    $script:fixtures = Join-Path $PSScriptRoot 'fixtures' 'repos'
    . (Join-Path $PSScriptRoot 'Helpers' 'RepoFixture.ps1')

    # On GitHub Actions these point at the real job; the tests must not write into them.
    $script:savedOutput = $env:GITHUB_OUTPUT
    $script:savedSummary = $env:GITHUB_STEP_SUMMARY
    $env:GITHUB_OUTPUT = $null
    $env:GITHUB_STEP_SUMMARY = $null

    function Invoke-Entry {
        # Runs Validate.ps1 in-process; returns the result object and the console lines (information stream).
        param([hashtable]$Parameters)
        if (-not $Parameters.ContainsKey('SummaryPath')) { $Parameters.SummaryPath = Join-Path $TestDrive ('summary-{0}.md' -f [guid]::NewGuid().ToString('n')) }
        if (-not $Parameters.ContainsKey('DiffRef')) { $Parameters.DiffRef = '' }
        $output = @(& $script:entry @Parameters 6>&1)
        return [pscustomobject]@{
            Result = $output | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] } | Select-Object -Last 1
            Lines  = @($output | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { [string]$_.MessageData })
            Summary = if (Test-Path -LiteralPath $Parameters.SummaryPath) { Get-Content -LiteralPath $Parameters.SummaryPath -Raw } else { '' }
        }
    }
}

AfterAll {
    $env:GITHUB_OUTPUT = $script:savedOutput
    $env:GITHUB_STEP_SUMMARY = $script:savedSummary
    Remove-Module Rulebook.Validate, Rulebook.Generate -ErrorAction SilentlyContinue
}

Describe 'actions/Validate/action.yaml' {
    BeforeAll {
        $script:yaml = Get-Content -LiteralPath (Join-Path $actionDir 'action.yaml') -Raw
    }

    It 'is a composite action' {
        $yaml | Should-MatchString '(?m)^  using: composite$'
    }

    It 'declares input <Name> with default <Default>' -ForEach @(
        @{ Name = 'repositoryRoot'; Default = "'.'" }
        @{ Name = 'failOnWarning'; Default = "'false'" }
        @{ Name = 'checkForUpdates'; Default = "'true'" }
    ) {
        $yaml | Should-MatchString ("(?ms)^  {0}:\n.*?^    default: {1}$" -f $Name, [regex]::Escape($Default))
    }

    It 'declares the outputs errors and warnings' {
        $yaml | Should-MatchString '(?m)^  errors:$'
        $yaml | Should-MatchString '(?m)^  warnings:$'
    }

    It 'passes inputs through env and never interpolates them into run' {
        $run = [regex]::Match($yaml, '(?ms)^      run: \|\n(.*)').Groups[1].Value
        $run | Should-NotMatchString '\$\{\{'
        $yaml | Should-MatchString 'INPUT_REPOSITORYROOT: \$\{\{ inputs\.repositoryRoot \}\}'
        $run | Should-MatchString 'GITHUB_ACTION_PATH'
        $run | Should-MatchString 'exit \$result\.ExitCode'
    }
}

Describe 'template/.github/workflows/Validate.yaml' {
    BeforeAll {
        $script:workflow = Get-Content -LiteralPath (Join-Path $repoRoot 'template' '.github' 'workflows' 'Validate.yaml') -Raw
    }

    It 'runs on pull requests and pushes to main' {
        $workflow | Should-MatchString '(?m)^  pull_request:$'
        $workflow | Should-MatchString '(?m)^    branches: \[ main \]$'
    }

    It 'has a read-only token' {
        $workflow | Should-MatchString '(?ms)^permissions:\n  contents: read$'
    }

    It 'checks out the full history and calls the engine action' {
        $workflow | Should-MatchString 'fetch-depth: 0'
        $workflow | Should-MatchString 'uses: ALCops/rulebook-engine/actions/Validate@main'
    }
}

Describe 'Validate.ps1' {
    It 'passes valid-minimal' {
        $run = Invoke-Entry @{ RepositoryRoot = (Join-Path $fixtures 'valid-minimal') }
        $run.Result.ExitCode | Should-Be 0
        @($run.Result.Findings).Count | Should-Be 0
        $run.Summary | Should-MatchString 'No findings\.'
        @($run.Lines | Where-Object { $_ -like '::error*' }).Count | Should-Be 0
    }

    It 'fails stale-endpoints with a C12 annotation relative to the workspace' {
        $run = Invoke-Entry @{ RepositoryRoot = (Join-Path $fixtures 'stale-endpoints'); WorkspaceRoot = $repoRoot }
        $run.Result.ExitCode | Should-Be 1
        $line = '::error file=tests/fixtures/repos/stale-endpoints/rulesets/recommended.ci.ruleset.json,title=C12::rulesets/recommended.ci.ruleset.json would be modified'
        @($run.Result.Annotations | Where-Object { $_.StartsWith($line) }).Count | Should-Be 1
        $run.Lines | Should-ContainCollection @($run.Result.Annotations[0])
        $run.Summary | Should-MatchString '\| C12 \| error \| `rulesets/recommended\.ci\.ruleset\.json` \|'
        $run.Summary | Should-MatchString '\*\*1 error\(s\), 0 warning\(s\)\*\* in `tests/fixtures/repos/stale-endpoints`'
    }

    It 'passes warnings unless -FailOnWarning (quarantined-stage-entry)' {
        $root = New-FixtureRepo -Name 'quarantined-stage-entry' -Destination (Join-Path $TestDrive 'quarantined')
        $run = Invoke-Entry @{ RepositoryRoot = $root; WorkspaceRoot = $TestDrive }
        $run.Result.ExitCode | Should-Be 0
        $run.Result.Annotations[0] | Should-BeLikeString '::warning file=quarantined/stages/ci.json,title=C15::LC0099: *'
        (Invoke-Entry @{ RepositoryRoot = $root; FailOnWarning = $true }).Result.ExitCode | Should-Be 1
    }

    It 'escapes newlines and percent signs in annotations' {
        $root = New-FixtureRepo -Name 'valid-minimal' -Destination (Join-Path $TestDrive 'escape')
        Remove-Item -LiteralPath (Join-Path $root 'catalog' 'diagnostics.json')
        $run = Invoke-Entry @{ RepositoryRoot = $root; WorkspaceRoot = $root }
        foreach ($line in $run.Result.Annotations) { $line.Contains("`n") | Should-BeFalse }
        @($run.Result.Annotations | Where-Object { $_ -like '::warning title=C12::*' }).Count | Should-Be 1
    }

    It 'writes the findings to -JsonPath and the outputs to GITHUB_OUTPUT' {
        $json = Join-Path $TestDrive 'findings.json'
        $outputFile = Join-Path $TestDrive 'github-output.txt'
        $env:GITHUB_OUTPUT = $outputFile
        try {
            $null = Invoke-Entry @{ RepositoryRoot = (Join-Path $fixtures 'stale-endpoints'); JsonPath = $json }
        } finally {
            $env:GITHUB_OUTPUT = $null
        }
        @(Get-Content -LiteralPath $json -Raw | ConvertFrom-Json).Count | Should-Be 1
        (Get-Content -LiteralPath $outputFile -Raw) | Should-Be "errors=1`nwarnings=0`n"
    }

    It 'notes that the diff is disabled with -DiffRef empty' {
        $run = Invoke-Entry @{ RepositoryRoot = (Join-Path $fixtures 'valid-minimal'); DiffRef = '' }
        $run.Result.DiffRef | Should-Be ''
        $run.Summary | Should-MatchString '(?m)^## Effective diff$'
        $run.Summary | Should-MatchString 'No diff: no reference to compare against'
    }

    It 'prints the update check placeholder with -CheckForUpdates' {
        $run = Invoke-Entry @{ RepositoryRoot = (Join-Path $fixtures 'valid-minimal'); CheckForUpdates = $true }
        $run.Lines | Should-ContainCollection @('Update check: not wired yet (WP07, #9).')
    }

    It 'shows the effective diff against -DiffRef HEAD~1' -Skip:$gitMissing {
        $root = New-FixtureRepo -Name 'valid-minimal' -Destination (Join-Path $TestDrive 'diff')
        $null = New-FixtureGitRepo -Root $root -Message 'before'
        Edit-FixtureJson -Path (Join-Path $root 'overrides.json') -Script { $_.rules = @($_.rules | Where-Object { $_.id -ne 'LC0029' }) }
        Import-Module (Join-Path $repoRoot 'modules' 'Rulebook.Generate.psd1') -Force
        $null = Update-RulebookEndpoints -RepositoryRoot $root
        $null = New-FixtureGitRepo -Root $root -Message 'after'
        $run = Invoke-Entry @{ RepositoryRoot = $root; DiffRef = 'HEAD~1' }
        $run.Result.ExitCode | Should-Be 0
        @($run.Result.Diff).Count | Should-Be 1
        $run.Summary | Should-MatchString '(?m)^## Effective diff against HEAD~1$'
        $run.Summary | Should-MatchString '(?m)^### `recommended\.ci` \(`rulesets/recommended\.ci\.ruleset\.json`\)$'
        $run.Summary | Should-MatchString '(?m)^\| LC0029 \| None \| Warning \| level:recommended \|$'
    }

    It 'notes a ref that does not resolve instead of failing' -Skip:$gitMissing {
        $root = New-FixtureRepo -Name 'valid-minimal' -Destination (Join-Path $TestDrive 'noref')
        $null = New-FixtureGitRepo -Root $root -Message 'only'
        $run = Invoke-Entry @{ RepositoryRoot = $root; DiffRef = 'HEAD~5' }
        $run.Result.ExitCode | Should-Be 0
        $run.Summary | Should-MatchString 'No diff: HEAD~5 does not resolve'
    }
}
