# Action suite for WP09 (#11): actions/ChangeRule/action.yaml, its entry script ChangeRule.ps1 run in-process, and the
# template workflow template/.github/workflows/ChangeRule.yaml. The ci.yml job changerule-action runs the action
# itself on valid-minimal; the module is covered by tests/Rulebook.Edit.Tests.ps1.

BeforeDiscovery {
    $script:gitMissing = $null -eq (Get-Command git -ErrorAction SilentlyContinue)
}

BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:actionDir = Join-Path $script:repoRoot 'actions' 'ChangeRule'
    $script:entry = Join-Path $script:actionDir 'ChangeRule.ps1'
    $script:minimal = Join-Path $PSScriptRoot 'fixtures' 'repos' 'valid-minimal'
    . (Join-Path $PSScriptRoot 'Helpers' 'RepoFixture.ps1')

    # On GitHub Actions these point at the real job; the tests must not write into them.
    $script:saved = @{ Output = $env:GITHUB_OUTPUT; Summary = $env:GITHUB_STEP_SUMMARY; Repository = $env:GITHUB_REPOSITORY; Token = $env:GITHUB_TOKEN }
    $env:GITHUB_OUTPUT = $null
    $env:GITHUB_STEP_SUMMARY = $null
    $env:GITHUB_TOKEN = $null
    $script:now = [System.DateTimeOffset]::new(2026, 10, 8, 9, 15, 30, [System.TimeSpan]::Zero)

    function Get-TestFolder {
        return Join-Path $TestDrive ([guid]::NewGuid().ToString('n').Substring(0, 12))
    }

    function Copy-Minimal {
        return New-FixtureRepo -Name 'valid-minimal' -Destination (Get-TestFolder)
    }

    function Invoke-Entry {
        # Runs ChangeRule.ps1 in-process; returns the result object, the console lines, the summary and the outputs.
        param([hashtable]$Parameters)
        $folder = Get-TestFolder
        if (-not $Parameters.ContainsKey('SummaryPath')) { $Parameters.SummaryPath = "$folder.summary.md" }
        if (-not $Parameters.ContainsKey('WorkPath')) { $Parameters.WorkPath = Join-Path $folder 'work' }
        if (-not $Parameters.ContainsKey('Repository')) { $Parameters.Repository = 'Contoso/rulebook' }
        if (-not $Parameters.ContainsKey('BaseBranch')) { $Parameters.BaseBranch = 'main' }
        if (-not $Parameters.ContainsKey('Now')) { $Parameters.Now = $script:now }
        # No request leaves the test: an unmocked GitHub call fails fast.
        if (-not $Parameters.ContainsKey('ApiUrl')) { $Parameters.ApiUrl = 'http://127.0.0.1:9' }
        $outputFile = "$folder.output.txt"
        $env:GITHUB_OUTPUT = $outputFile
        try {
            $output = @(& $script:entry @Parameters 6>&1 3>$null)
        } finally {
            $env:GITHUB_OUTPUT = $null
        }
        return [pscustomobject]@{
            Result  = $output | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] } | Select-Object -Last 1
            Lines   = @($output | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { [string]$_.MessageData })
            Summary = if (Test-Path -LiteralPath $Parameters.SummaryPath) { Get-Content -LiteralPath $Parameters.SummaryPath -Raw } else { '' }
            Output  = if (Test-Path -LiteralPath $outputFile) { Get-Content -LiteralPath $outputFile -Raw } else { '' }
        }
    }
}

AfterAll {
    $env:GITHUB_OUTPUT = $script:saved.Output
    $env:GITHUB_STEP_SUMMARY = $script:saved.Summary
    $env:GITHUB_REPOSITORY = $script:saved.Repository
    $env:GITHUB_TOKEN = $script:saved.Token
    Remove-Module Rulebook.Edit, Rulebook.Update, Rulebook.GitHub, Rulebook.Template, Rulebook.Validate, Rulebook.Generate, Rulebook.Action -ErrorAction SilentlyContinue
}

Describe 'actions/ChangeRule/action.yaml' {
    BeforeAll {
        $script:yaml = Get-Content -LiteralPath (Join-Path $actionDir 'action.yaml') -Raw
    }

    It 'is a composite action' {
        $yaml | Should-MatchString '(?m)^  using: composite$'
    }

    It 'requires ruleId and action' {
        $yaml | Should-MatchString '(?ms)^  ruleId:\n[^\n]*\n    required: true$'
        $yaml | Should-MatchString '(?ms)^  action:\n[^\n]*\n    required: true$'
    }

    It 'declares input <Name> with default <Default>' -ForEach @(
        @{ Name = 'levels'; Default = "'*'" }
        @{ Name = 'stages'; Default = "'*'" }
        @{ Name = 'justification'; Default = "''" }
        @{ Name = 'token'; Default = "''" }
        @{ Name = 'directCommit'; Default = "'false'" }
        @{ Name = 'baseBranch'; Default = '${{ github.ref_name }}' }
        @{ Name = 'repositoryRoot'; Default = "'.'" }
        @{ Name = 'actor'; Default = '${{ github.actor }}' }
    ) {
        $yaml | Should-MatchString ("(?ms)^  {0}:\n.*?^    default: {1}$" -f $Name, [regex]::Escape($Default))
    }

    It 'declares the output <Name>' -ForEach @(
        @{ Name = 'result' }
        @{ Name = 'noop' }
        @{ Name = 'changedEndpoints' }
        @{ Name = 'pullRequestUrl' }
        @{ Name = 'branch' }
        @{ Name = 'failure' }
    ) {
        $yaml | Should-MatchString ("(?m)^  {0}:\n.*\n    value: \$\{{\{{ steps\.change\.outputs\.{0} \}}\}}$" -f $Name)
    }

    It 'passes inputs through env and never interpolates them into run' {
        $run = [regex]::Match($yaml, '(?ms)^      run: \|\n(.*)').Groups[1].Value
        $run | Should-NotMatchString '\$\{\{'
        foreach ($name in 'RULEID', 'ACTION', 'LEVELS', 'STAGES', 'JUSTIFICATION', 'TOKEN', 'DIRECTCOMMIT', 'BASEBRANCH', 'REPOSITORYROOT', 'ACTOR') {
            $yaml | Should-MatchString "(?m)^        INPUT_$($name): \`$\{\{ inputs\.\w+ \}\}$"
        }
        $yaml | Should-MatchString '(?m)^        GITHUB_TOKEN: \$\{\{ github\.token \}\}$'
        $run | Should-MatchString 'GITHUB_ACTION_PATH'
        $run | Should-MatchString 'exit \$result\.ExitCode'
    }
}

Describe 'template/.github/workflows/ChangeRule.yaml' {
    BeforeAll {
        $script:workflow = Get-Content -LiteralPath (Join-Path $repoRoot 'template' '.github' 'workflows' 'ChangeRule.yaml') -Raw
        $script:settingsStep = [regex]::Match($workflow, '(?ms)^        run: \|\n(.*?)\n\n').Groups[1].Value

        function Invoke-SettingsStep {
            # Runs the settings step in-process on a folder with -Settings as .github/Rulebook-Settings.json.
            param([string]$Settings)
            $script = Join-Path $TestDrive 'settings-step.ps1'
            [System.IO.File]::WriteAllText($script, ($settingsStep -replace '(?m)^          ', ''))
            $root = Get-TestFolder
            Write-FixtureText -Path (Join-Path $root '.github' 'Rulebook-Settings.json') -Text $Settings
            $output = Join-Path $root 'settings-output.txt'
            $saved = $env:GITHUB_OUTPUT
            try {
                $env:GITHUB_OUTPUT = $output
                Push-Location -LiteralPath $root
                try { $null = & $script 6>$null } finally { Pop-Location }
            } finally {
                $env:GITHUB_OUTPUT = $saved
            }
            return @(Get-Content -LiteralPath $output)
        }
    }

    It 'is named Change Rule and runs only on workflow_dispatch' {
        $workflow | Should-MatchString '(?m)^name: Change Rule$'
        $workflow | Should-MatchString '(?m)^on:\n  workflow_dispatch:\n'
        $workflow | Should-NotMatchString '(?m)^  (push|pull_request|schedule):'
    }

    It 'has the five inputs with the exact option lists' {
        $workflow | Should-MatchString "(?ms)^      ruleId:\n        description: 'Diagnostic id, for example LC0015\.'\n        type: string\n        required: true$"
        $workflow | Should-MatchString "(?ms)^      action:\n        description: 'The new action; Remove deletes the matching override entry\.'\n        type: choice\n        options:\n          - Error\n          - Warning\n          - Info\n          - Hidden\n          - None\n          - Remove\n"
        $workflow | Should-MatchString "(?ms)^      levels:\n[^\n]*\n        type: choice\n        default: '\*'\n        options:\n          - '\*'\n          - essential\n          - recommended\n          - strict\n          - complete\n"
        $workflow | Should-MatchString "(?ms)^      stages:\n[^\n]*\n        type: choice\n        default: '\*'\n        options:\n          - '\*'\n          - default\n          - ci\n          - vnext\n"
        $workflow | Should-MatchString "(?ms)^      justification:\n[^\n]*\n        type: string\n        required: false\n        default: ''$"
        $workflow | Should-NotMatchString '(?m)^      directCommit:'
    }

    It 'keeps the workflow token at contents read and runs one change per ref at a time' {
        $workflow | Should-MatchString '(?m)^permissions:\n  contents: read\n\n'
        $workflow | Should-MatchString '(?m)^concurrency:\n  group: change-rule-\$\{\{ github\.ref \}\}\n  cancel-in-progress: false$'
        $workflow | Should-MatchString '(?m)^          persist-credentials: false$'
    }

    It 'looks the secret up by the name from the settings and calls the engine action at main' {
        $workflow | Should-MatchString '(?m)^        uses: ALCops/rulebook-engine/actions/ChangeRule@main$'
        $workflow | Should-MatchString '(?m)^          token: \$\{\{ secrets\[steps\.settings\.outputs\.secretName\] \}\}$'
        $workflow | Should-MatchString '(?m)^          directCommit: \$\{\{ steps\.settings\.outputs\.directCommit \}\}$'
        foreach ($name in 'ruleId', 'action', 'levels', 'stages', 'justification') {
            $workflow | Should-MatchString "(?m)^          $($name): \`$\{\{ inputs\.$name \}\}$"
        }
    }

    It 'never interpolates an expression into run' {
        $settingsStep | Should-MatchString 'ghTokenWorkflowSecretName'
        $settingsStep | Should-NotMatchString '\$\{\{'
    }

    It 'derives directCommit from commitOptions.createPullRequest: <Name>' -ForEach @(
        @{ Name = 'false gives a direct commit'; Settings = '{ "ghTokenWorkflowSecretName": "RULEBOOK_TOKEN", "commitOptions": { "createPullRequest": false } }'; Expected = @('secretName=RULEBOOK_TOKEN', 'directCommit=true') }
        @{ Name = 'true gives a pull request'; Settings = '{ "commitOptions": { "createPullRequest": true } }'; Expected = @('secretName=GHTOKENWORKFLOW', 'directCommit=false') }
        @{ Name = 'absent gives a pull request'; Settings = '{ "templateUrl": "x" }'; Expected = @('secretName=GHTOKENWORKFLOW', 'directCommit=false') }
    ) {
        Invoke-SettingsStep -Settings $Settings | Should-BeCollection $Expected
    }
}

Describe 'ChangeRule.ps1' {
    It 'annotates an invalid id and fails validation before any file is touched (AC5)' {
        $root = Copy-Minimal
        $run = Invoke-Entry @{ RepositoryRoot = $root; WorkspaceRoot = $root; RuleId = 'LC9999'; Action = 'Warning' }
        $run.Result.ExitCode | Should-Be 1
        $run.Result.Failure | Should-Be 'validation'
        @($run.Result.Annotations) | Should-BeCollection @('::error file=overrides.json,title=ChangeRule::LC9999 is not in catalog/diagnostics.json')
        $run.Output | Should-Be "result=`nnoop=false`nchangedEndpoints=`npullRequestUrl=`nbranch=`nfailure=validation`n"
    }

    It 'lists the existing entries when Remove finds no matching entry' {
        $root = Copy-Minimal
        $run = Invoke-Entry @{ RepositoryRoot = $root; WorkspaceRoot = $root; RuleId = 'LC0029'; Action = 'Remove'; Levels = 'strict'; Stages = 'ci' }
        $run.Result.Failure | Should-Be 'validation'
        $run.Result.Annotations[0] | Should-Be '::error file=overrides.json,title=ChangeRule::overrides.json has no entry for LC0029 with levels [strict] and stages [ci]; existing entries for LC0029: None (levels: recommended, stages: ci)'
    }

    It 'reports a no-op with a notice and exit code 0, without a token (AC6)' {
        $run = Invoke-Entry @{ RepositoryRoot = (Copy-Minimal); RuleId = 'LC0029'; Action = 'None'; Levels = 'recommended'; Stages = 'ci'; Justification = 'Backlog DEV-1234' }
        $run.Result.ExitCode | Should-Be 0
        $run.Result.NoOp | Should-BeTrue
        @($run.Result.Annotations) | Should-BeCollection @('::notice title=ChangeRule::No change: LC0029 is already None on every matching endpoint (recommended.ci); overrides.json was not written')
        $run.Output | Should-Be "result=no-op`nnoop=true`nchangedEndpoints=`npullRequestUrl=`nbranch=`nfailure=`n"
        $run.Summary | Should-MatchString '(?m)^\| recommended\.ci \| None \(override, "Backlog DEV-1234"\) \| None \(override, "Backlog DEV-1234"\) \| unchanged \|$'
    }

    It 'needs the token for a real change, after the plan' {
        $run = Invoke-Entry @{ RepositoryRoot = (Copy-Minimal); RuleId = 'AA0001'; Action = 'None' }
        $run.Result.ExitCode | Should-Be 1
        $run.Result.Failure | Should-Be 'token'
        @($run.Result.Annotations) | Should-BeCollection @('::error title=ChangeRule::The GHTOKENWORKFLOW secret is needed to change a rule. Read https://github.com/ALCops/rulebook/blob/main/docs/ghtokenworkflow.md')
        $run.Result.Plan.Valid | Should-BeTrue
    }

    It 'fails validation on an invalid ghTokenWorkflowSecretName (the settings schema, before the token guard)' {
        $root = Copy-Minimal
        Edit-FixtureJson -Path (Join-Path $root '.github' 'Rulebook-Settings.json') -Script { $_.ghTokenWorkflowSecretName = 'github_token' }
        $run = Invoke-Entry @{ RepositoryRoot = $root; WorkspaceRoot = $root; RuleId = 'AA0001'; Action = 'None'; Token = 'ghp_x' }
        $run.Result.Failure | Should-Be 'validation'
        @($run.Result.Annotations | Where-Object { $_ -like '::error file=.github/Rulebook-Settings.json,title=C5::The changed rulebook would not validate:*' }).Count | Should-BeGreaterThan 0
    }

    It 'masks the write token before any other output' {
        $run = Invoke-Entry @{ RepositoryRoot = (Copy-Minimal); RuleId = 'AA0001'; Action = 'None'; Token = 'ghp_secret_value'; RemoteUrl = (Join-Path (Get-TestFolder) 'never.git') }
        $run.Lines[0] | Should-Be '::add-mask::ghp_secret_value'
        @($run.Lines | Where-Object { $_ -like '*ghp_secret_value*' }) | Should-BeCollection @('::add-mask::ghp_secret_value')
    }

    It 'passes the plan to the publish seam and writes outputs and the summary with the effective diff' {
        # A hashtable from this scope: the seam runs in a child scope of ChangeRule.ps1 and sees it.
        $seen = @{}
        $publish = {
            param($BranchPrefix, $DirectCommit, $Labels, [Parameter(ValueFromRemainingArguments)][object[]]$Rest)
            $null = $Rest
            $seen['BranchPrefix'] = $BranchPrefix
            $seen['Labels'] = $Labels
            $seen['DirectCommit'] = $DirectCommit
            $diff = @([pscustomobject]@{ Endpoint = 'strict.ci'; File = 'rulesets/strict.ci.ruleset.json'; Id = 'LC0015'; Before = 'Warning'; After = 'None'; BeforeSource = 'level:strict'; AfterSource = 'override'; BeforeDetail = $null; AfterDetail = $null; ListedBefore = $true; ListedAfter = $true; Change = 'action' })
            [pscustomobject]@{ Result = 'pull-request'; PullRequestUrl = 'https://github.com/Contoso/rulebook/pull/7'; Number = 7; Branch = 'change-rule/LC0015/261008091530'; Sha = 'a' * 40; Fallback = $false; Diff = $diff; DiffNote = $null; Body = 'body'; Title = 't' }
        }
        $run = Invoke-Entry @{ RepositoryRoot = (Copy-Minimal); RuleId = 'LC0015'; Action = 'None'; Levels = 'strict'; Stages = 'ci'; Token = 'ghp_x'; PublishCommand = $publish }
        $run.Result.ExitCode | Should-Be 0
        $seen.BranchPrefix | Should-Be 'change-rule/LC0015'
        $seen.Labels | Should-BeCollection @('rulebook')
        $seen.DirectCommit | Should-BeFalse
        $run.Result.Annotations[-1] | Should-Be '::notice title=ChangeRule::Pull request: https://github.com/Contoso/rulebook/pull/7'
        $run.Output | Should-Be "result=pull-request`nnoop=false`nchangedEndpoints=strict.ci`npullRequestUrl=https://github.com/Contoso/rulebook/pull/7`nbranch=change-rule/LC0015/261008091530`nfailure=`n"
        $run.Summary | Should-MatchString '(?m)^## Effective diff\n\n### `strict\.ci` \(`rulesets/strict\.ci\.ruleset\.json`\)$'
    }

    It 'maps a pull request failure of the seam to failure pull-request with the token hint' {
        $publish = {
            param([Parameter(ValueFromRemainingArguments)][object[]]$Ignored)
            $null = $Ignored
            $exception = [System.InvalidOperationException]::new('Branch change-rule/LC0015/261008091530 was pushed. Could not create the pull request (HTTP 422).')
            $exception.Data['Stage'] = 'pull-request'
            throw $exception
        }
        $run = Invoke-Entry @{ RepositoryRoot = (Copy-Minimal); RuleId = 'LC0015'; Action = 'None'; Levels = 'strict'; Stages = 'ci'; Token = 'ghp_x'; PublishCommand = $publish }
        $run.Result.Failure | Should-Be 'pull-request'
        $run.Result.Annotations[-1] | Should-BeLikeString '::error title=ChangeRule::Failed to create the pull request for the rule change. Make sure that the token in the secret GHTOKENWORKFLOW*Branch change-rule/LC0015/261008091530 was pushed*'
    }

    It 'reports a base branch that moved without the token hint' {
        $publish = {
            param([Parameter(ValueFromRemainingArguments)][object[]]$Ignored)
            $null = $Ignored
            $exception = [System.InvalidOperationException]::new('The base branch moved since the change was planned (main aaaaaaa is now bbbbbbb); nothing was pushed. Run the workflow again.')
            $exception.Data['Stage'] = 'push'
            $exception.Data['Reason'] = 'base-moved'
            throw $exception
        }
        $run = Invoke-Entry @{ RepositoryRoot = (Copy-Minimal); RuleId = 'LC0015'; Action = 'None'; Levels = 'strict'; Stages = 'ci'; Token = 'ghp_x'; PublishCommand = $publish }
        $run.Result.Failure | Should-Be 'push'
        $run.Result.Annotations[-1] | Should-Be '::error title=ChangeRule::The base branch moved since the change was planned (main aaaaaaa is now bbbbbbb); nothing was pushed. Run the workflow again.'
    }

    It 'reports failure push with the token hint when the clone fails' {
        $run = Invoke-Entry @{ RepositoryRoot = (Copy-Minimal); RuleId = 'LC0015'; Action = 'None'; Levels = 'strict'; Stages = 'ci'; Token = 'ghp_x'; RemoteUrl = (Join-Path (Get-TestFolder) 'missing.git') }
        $run.Result.Failure | Should-Be 'push'
        $run.Result.Annotations[-1] | Should-BeLikeString "::error title=ChangeRule::Failed to push the rule change. Make sure that the token in the secret GHTOKENWORKFLOW is not expired*Could not clone branch 'main'*"
    }

    It 'leaves a work folder the caller passed in place' {
        $work = Join-Path (Get-TestFolder) 'work'
        $null = New-Item -ItemType Directory -Path $work
        Write-FixtureText -Path (Join-Path $work 'keep.txt') -Text 'mine'
        $null = Invoke-Entry @{ RepositoryRoot = (Copy-Minimal); RuleId = 'AA0001'; Action = 'None'; WorkPath = $work }
        Test-Path -LiteralPath (Join-Path $work 'keep.txt') -PathType Leaf | Should-BeTrue
    }

    It 'removes the work folder it names itself' {
        $runnerTemp = Get-TestFolder
        $null = New-Item -ItemType Directory -Path $runnerTemp
        $saved = $env:RUNNER_TEMP
        $env:RUNNER_TEMP = $runnerTemp
        try {
            $null = & $script:entry -RepositoryRoot (Copy-Minimal) -RuleId 'AA0001' -Action 'None' -SummaryPath "$(Get-TestFolder).summary.md" 6>$null
        } finally {
            $env:RUNNER_TEMP = $saved
        }
        @(Get-ChildItem -LiteralPath $runnerTemp -Force) | Should-BeCollection @()
    }

    Context 'against a bare remote' -Skip:$gitMissing {
        BeforeAll {
            function New-Origin {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helper; writes only to TestDrive')]
                param([switch]$Reject)
                $bare = New-BareFixtureRepo -Source $minimal -Destination (Join-Path (Get-TestFolder) 'origin.git')
                if ($Reject) { Add-RejectPushHook -BarePath $bare -Branch 'main' }
                return $bare
            }
        }

        It 'pushes a direct commit to the base branch' {
            $bare = New-Origin
            $run = Invoke-Entry @{ RepositoryRoot = (Copy-Minimal); RuleId = 'LC0015'; Action = 'None'; Levels = 'strict'; Stages = 'ci'; Token = 'ghp_x'; DirectCommit = $true; RemoteUrl = $bare }
            $run.Result.ExitCode | Should-Be 0
            $run.Result.Result | Should-Be 'direct-commit'
            $sha = (& git -C $bare rev-parse refs/heads/main).Trim()
            $run.Result.Annotations[-1] | Should-Be "::notice title=ChangeRule::Rule change committed to main ($($sha.Substring(0, 7)))"
            (& git -C $bare log -1 --format=%s main) | Should-Be 'Change LC0015 to None (levels: strict, stages: ci)'
        }

        It 'pushes the change branch and names it when the pull request cannot be opened' {
            $bare = New-Origin
            $run = Invoke-Entry @{ RepositoryRoot = (Copy-Minimal); RuleId = 'LC0015'; Action = 'None'; Levels = 'strict'; Stages = 'ci'; Token = 'ghp_x'; RemoteUrl = $bare }
            $run.Result.Failure | Should-Be 'pull-request'
            (& git -C $bare rev-parse --verify --quiet refs/heads/change-rule/LC0015/261008091530) | Should-NotBeNull
            $run.Result.Annotations[-1] | Should-BeLikeString '*Branch change-rule/LC0015/261008091530 was pushed*'
        }

        It 'falls back to the change branch when the direct push is refused' {
            $bare = New-Origin -Reject
            $originSha = (& git -C $bare rev-parse refs/heads/main).Trim()
            $run = Invoke-Entry @{ RepositoryRoot = (Copy-Minimal); RuleId = 'LC0015'; Action = 'None'; Levels = 'strict'; Stages = 'ci'; Token = 'ghp_x'; DirectCommit = $true; RemoteUrl = $bare }
            (& git -C $bare rev-parse refs/heads/main).Trim() | Should-Be $originSha
            (& git -C $bare rev-parse --verify --quiet refs/heads/change-rule/LC0015/261008091530) | Should-NotBeNull
            # The pull request call goes nowhere in the test; the branch is named for opening it by hand.
            $run.Result.Failure | Should-Be 'pull-request'
        }
    }
}
