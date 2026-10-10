# Action suite for WP08 (#10): actions/ScanDiagnostics/action.yaml, its entry script ScanDiagnostics.ps1 run in-process
# against the stub analyzer packages (-PackageSource), and the template workflow
# template/.github/workflows/ScanDiagnostics.yaml. The ci.yml job scan-action runs the action on the real packages.

BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:actionDir = Join-Path $script:repoRoot 'actions' 'ScanDiagnostics'
    $script:entry = Join-Path $script:actionDir 'ScanDiagnostics.ps1'
    . (Join-Path $PSScriptRoot 'Helpers' 'RepoFixture.ps1')
    . (Join-Path $PSScriptRoot 'Helpers' 'StubFeed.ps1')
    $script:policyMessage = 'Set quarantine.stages and quarantine.prereleaseStages in .github/Rulebook-Settings.json. Typical choice: quarantine default and ci, leave vnext out so it shows new rules at their default severity.'

    # On GitHub Actions these point at the real job; the tests must not write into them.
    $script:saved = @{ Output = $env:GITHUB_OUTPUT; Summary = $env:GITHUB_STEP_SUMMARY; Repository = $env:GITHUB_REPOSITORY; Token = $env:GITHUB_TOKEN; RunnerTemp = $env:RUNNER_TEMP }
    $env:GITHUB_OUTPUT = $null
    $env:GITHUB_STEP_SUMMARY = $null
    $env:GITHUB_TOKEN = $null

    function Get-TestFolder {
        return Join-Path $TestDrive ([guid]::NewGuid().ToString('n').Substring(0, 12))
    }

    function New-Org {

        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helper; builds an object or writes only to TestDrive')]
        param([switch]$WithoutPolicy)
        $root = New-FixtureRepo -Name 'valid-minimal' -Destination (Get-TestFolder)
        if (-not $WithoutPolicy) {
            Edit-FixtureJson -Path (Join-Path $root '.github' 'Rulebook-Settings.json') -Script { $_.quarantine = [ordered]@{ stages = @('default', 'ci'); prereleaseStages = @('ci') } }
        }
        return $root
    }

    function Invoke-Entry {
        # Runs ScanDiagnostics.ps1 in-process; returns the result object, the console lines and the summary.
        param([hashtable]$Parameters)
        $folder = Get-TestFolder
        if (-not $Parameters.ContainsKey('SummaryPath')) { $Parameters.SummaryPath = "$folder.summary.md" }
        if (-not $Parameters.ContainsKey('WorkPath') -and -not $Parameters.ContainsKey('NoWorkPath')) { $Parameters.WorkPath = Join-Path $folder 'work' }
        $Parameters.Remove('NoWorkPath')
        if (-not $Parameters.ContainsKey('Repository')) { $Parameters.Repository = 'Contoso/rulebook' }
        if (-not $Parameters.ContainsKey('BaseBranch')) { $Parameters.BaseBranch = 'main' }
        if (-not $Parameters.ContainsKey('PackageSource')) { $Parameters.PackageSource = $script:feed }
        if (-not $Parameters.ContainsKey('Now')) { $Parameters.Now = [System.DateTimeOffset]::new(2026, 10, 8, 4, 17, 0, [System.TimeSpan]::Zero) }
        $output = @(& $script:entry @Parameters 6>&1)
        return [pscustomobject]@{
            Result  = $output | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] } | Select-Object -Last 1
            Lines   = @($output | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { [string]$_.MessageData })
            Summary = if (Test-Path -LiteralPath $Parameters.SummaryPath) { Get-Content -LiteralPath $Parameters.SummaryPath -Raw } else { '' }
        }
    }

    $script:feed = New-StubFeed -Variants 'tools-stable', 'tools-prerelease', 'alcops-v1', 'alcops-v2' -Destination (Join-Path $TestDrive 'feed')
}

AfterAll {
    $env:GITHUB_OUTPUT = $script:saved.Output
    $env:GITHUB_STEP_SUMMARY = $script:saved.Summary
    $env:GITHUB_REPOSITORY = $script:saved.Repository
    $env:GITHUB_TOKEN = $script:saved.Token
    $env:RUNNER_TEMP = $script:saved.RunnerTemp
    Remove-Module Rulebook.Scan, Rulebook.Quarantine, Rulebook.Extract, Rulebook.Catalog, Rulebook.NuGet, Rulebook.Update, Rulebook.Template, Rulebook.GitHub, Rulebook.Validate, Rulebook.Generate, Rulebook.Action, Rulebook.Common -ErrorAction SilentlyContinue
}

Describe 'actions/ScanDiagnostics/action.yaml' {
    BeforeAll {
        $script:yaml = Get-Content -LiteralPath (Join-Path $actionDir 'action.yaml') -Raw
    }

    It 'is a composite action' {
        $yaml | Should-MatchString '(?m)^  using: composite$'
    }

    It 'declares input <Name> with default <Default>' -ForEach @(
        @{ Name = 'token'; Default = "''" }
        @{ Name = 'includePrerelease'; Default = "'true'" }
        @{ Name = 'directCommit'; Default = "'false'" }
        @{ Name = 'dryRun'; Default = "'false'" }
        @{ Name = 'baseBranch'; Default = '${{ github.ref_name }}' }
        @{ Name = 'repositoryRoot'; Default = "'.'" }
        @{ Name = 'actor'; Default = '${{ github.actor }}' }
        @{ Name = 'packageSource'; Default = "''" }
    ) {
        $yaml | Should-MatchString ("(?ms)^  {0}:\n.*?^    default: {1}$" -f $Name, [regex]::Escape($Default))
    }

    It 'declares the output <Name>' -ForEach @(
        @{ Name = 'result' }, @{ Name = 'newIds' }, @{ Name = 'quarantined' }, @{ Name = 'changedDefaults' }, @{ Name = 'released' }
        @{ Name = 'scannedVersions' }, @{ Name = 'pullRequestUrl' }, @{ Name = 'candidatePath' }, @{ Name = 'elapsedSeconds' }, @{ Name = 'failure' }
    ) {
        $yaml | Should-MatchString ("(?m)^  {0}:\n.*\n    value: \$\{{\{{ steps\.scan\.outputs\.{0} \}}\}}$" -f $Name)
    }

    It 'passes inputs through env and never interpolates them into run' {
        $run = [regex]::Match($yaml, '(?ms)^      run: \|\n(.*)').Groups[1].Value
        $run | Should-NotMatchString '\$\{\{'
        foreach ($name in 'TOKEN', 'INCLUDEPRERELEASE', 'DIRECTCOMMIT', 'DRYRUN', 'BASEBRANCH', 'REPOSITORYROOT', 'ACTOR', 'PACKAGESOURCE') {
            $yaml | Should-MatchString "(?m)^        INPUT_$($name): \`$\{\{ inputs\.\w+ \}\}$"
        }
        # The scan needs no workflow token; the extraction child must not inherit one either.
        $yaml | Should-NotMatchString 'GITHUB_TOKEN'
        $run | Should-MatchString 'GITHUB_ACTION_PATH'
        $run | Should-MatchString 'exit \$result\.ExitCode'
    }
}

Describe 'template/.github/workflows/ScanDiagnostics.yaml' {
    BeforeAll {
        $script:workflow = (Get-Content -LiteralPath (Join-Path $repoRoot 'template' '.github' 'workflows' 'ScanDiagnostics.yaml') -Raw).Replace("`r`n", "`n")
    }

    It 'is named Scan Diagnostics' {
        $workflow | Should-MatchString '(?m)^name: Scan Diagnostics$'
    }

    It 'has the dispatch inputs includePrerelease and directCommit' {
        $workflow | Should-MatchString '(?ms)^      includePrerelease:\n.*?        type: boolean\n        default: true$'
        $workflow | Should-MatchString '(?ms)^      directCommit:\n.*?        type: boolean\n        default: false$'
    }

    It 'ships the schedule of the template settings as the last key under on:' {
        $cron = (Get-Content -LiteralPath (Join-Path $repoRoot 'template' '.github' 'Rulebook-Settings.json') -Raw | ConvertFrom-Json).scan.schedule
        $workflow | Should-MatchString ("(?m)^  schedule:\n    - cron: '{0}'\n\n" -f [regex]::Escape($cron))
    }

    It 'keeps the workflow token at contents and actions read and runs one scan per branch at a time' {
        $workflow | Should-MatchString '(?m)^permissions:\n  contents: read\n  actions: read\n\n'
        $workflow | Should-MatchString '(?m)^  group: scan-diagnostics-\$\{\{ github\.ref \}\}\n  cancel-in-progress: false$'
    }

    It 'looks the secret up by the name from the settings and uses the action from main' {
        $workflow | Should-MatchString '(?m)^          token: \$\{\{ secrets\[steps\.settings\.outputs\.secretName\] \}\}$'
        $workflow | Should-MatchString '(?m)^        uses: ALCops/rulebook-engine/actions/ScanDiagnostics@main$'
    }

    It 'never interpolates an expression into run' {
        $run = [regex]::Match($workflow, '(?ms)^        run: \|\n(.*?)\n\n').Groups[1].Value
        $run | Should-MatchString 'ghTokenWorkflowSecretName'
        $run | Should-NotMatchString '\$\{\{'
    }

    It 'reads the settings step for a <Event> run' -ForEach @(
        @{ Event = 'schedule'; Settings = '{ "ghTokenWorkflowSecretName": "RULEBOOK_TOKEN", "commitOptions": { "createPullRequest": false } }'; Inputs = @{}; Expected = @('secretName=RULEBOOK_TOKEN', 'directCommit=true', 'includePrerelease=true') }
        @{ Event = 'workflow_dispatch'; Settings = '{ }'; Inputs = @{ INPUT_INCLUDEPRERELEASE = 'false'; INPUT_DIRECTCOMMIT = 'true' }; Expected = @('secretName=GHTOKENWORKFLOW', 'directCommit=true', 'includePrerelease=false') }
    ) {
        $settingsStep = [regex]::Match($workflow, '(?ms)^        run: \|\n(.*?)\n\n').Groups[1].Value
        $script = Join-Path $TestDrive "settings-step-$Event.ps1"
        [System.IO.File]::WriteAllText($script, ($settingsStep -replace '(?m)^          ', ''))
        $root = Get-TestFolder
        Write-FixtureText -Path (Join-Path $root '.github' 'Rulebook-Settings.json') -Text $Settings
        $output = Join-Path $TestDrive "settings-output-$Event.txt"
        $saved = @{ Output = $env:GITHUB_OUTPUT; Event = $env:EVENT_NAME; Prerelease = $env:INPUT_INCLUDEPRERELEASE; Direct = $env:INPUT_DIRECTCOMMIT }
        try {
            $env:GITHUB_OUTPUT = $output
            $env:EVENT_NAME = $Event
            $env:INPUT_INCLUDEPRERELEASE = $Inputs['INPUT_INCLUDEPRERELEASE']
            $env:INPUT_DIRECTCOMMIT = $Inputs['INPUT_DIRECTCOMMIT']
            Push-Location -LiteralPath $root
            try { $null = & $script 6>$null } finally { Pop-Location }
        } finally {
            $env:GITHUB_OUTPUT = $saved.Output
            $env:EVENT_NAME = $saved.Event
            $env:INPUT_INCLUDEPRERELEASE = $saved.Prerelease
            $env:INPUT_DIRECTCOMMIT = $saved.Direct
        }
        (Get-Content -LiteralPath $output) | Should-BeCollection $Expected
    }
}

Describe 'ScanDiagnostics.ps1' {
    It 'stops before any request when the settings have no policy (AC4)' {
        $run = Invoke-Entry @{ RepositoryRoot = (New-Org -WithoutPolicy); Token = 'ghp_x'; PackageSource = (Join-Path $TestDrive 'no-such-feed') }
        $run.Result.ExitCode | Should-Be 1
        $run.Result.Failure | Should-Be 'policy'
        @($run.Result.Annotations) | Should-BeCollection @("::error title=ScanDiagnostics::$policyMessage")
        $run.Result.Plan | Should-BeNull
    }

    It 'fails with failure token before any request when the secret is empty' {
        $run = Invoke-Entry @{ RepositoryRoot = (New-Org); Token = ''; PackageSource = (Join-Path $TestDrive 'no-such-feed') }
        $run.Result.ExitCode | Should-Be 1
        $run.Result.Failure | Should-Be 'token'
        $run.Result.Annotations[0] | Should-BeLikeString '*The GHTOKENWORKFLOW secret is needed to scan diagnostics. Read https://github.com/ALCops/rulebook/blob/main/docs/ghtokenworkflow.md'
    }

    It 'runs a dry run without a token: outputs, summary and the kept candidate' {
        $run = Invoke-Entry @{ RepositoryRoot = (New-Org); DryRun = $true; NoWorkPath = $true }
        $run.Result.ExitCode | Should-Be 0
        $run.Result.Result | Should-Be 'dry-run'
        $outputs = $run.Result.Outputs
        $outputs.newIds | Should-Be 5
        $outputs.quarantined | Should-Be 5
        $outputs.failure | Should-BeNull
        $outputs.scannedVersions | Should-Be 'microsoft.dynamics.businesscentral.development.tools@18.0.43.1464:stable,microsoft.dynamics.businesscentral.development.tools@30.0.42.60748-beta:prerelease,alcops.analyzers@1.3.1:stable,alcops.analyzers@1.4.0-beta.1:prerelease'
        Test-Path -LiteralPath (Join-Path $outputs.candidatePath 'catalog' 'scan-state.json') | Should-BeTrue
        $run.Summary | Should-MatchString '(?m)^## Diagnostic scan$'
        $run.Summary | Should-MatchString '(?m)^## New diagnostics$'
        $run.Result.Annotations[0] | Should-BeLikeString '::notice title=ScanDiagnostics::Dry run: Scan diagnostics: 5 new ids quarantined (*; nothing was pushed'
        Remove-Item -LiteralPath (Split-Path -Parent (Split-Path -Parent $outputs.candidatePath)) -Recurse -Force
    }

    It 'reports nothing-new on a scanned repository' {
        $dry = Invoke-Entry @{ RepositoryRoot = (New-Org); DryRun = $true }
        $root = Get-TestFolder
        Copy-FixtureTree -Source $dry.Result.Outputs.candidatePath -Destination $root
        $run = Invoke-Entry @{ RepositoryRoot = $root; Token = 'ghp_x' }
        $run.Result.ExitCode | Should-Be 0
        $run.Result.Result | Should-Be 'nothing-new'
        $run.Result.Annotations[0] | Should-BeLikeString '::notice title=ScanDiagnostics::No new package version (microsoft.dynamics.businesscentral.development.tools 18.0.43.1464 stable, 30.0.42.60748-beta prerelease; alcops.analyzers 1.3.1 stable, 1.4.0-beta.1 prerelease); nothing to do'
    }

    It 'fails with failure validation and annotates the findings when the scanned rulebook does not validate' {
        $root = New-Org
        Edit-FixtureJson -Path (Join-Path $root 'base' 'complete.ruleset.json') -Script { $_.rules += @{ id = 'LC0999'; action = 'Error' } }
        $run = Invoke-Entry @{ RepositoryRoot = $root; DryRun = $true; WorkspaceRoot = (Split-Path -Parent $root) }
        $run.Result.ExitCode | Should-Be 1
        $run.Result.Failure | Should-Be 'validation'
        $leaf = Split-Path -Leaf $root
        @($run.Result.Annotations) | Should-ContainCollection @("::error file=$leaf/base/complete.ruleset.json,title=C7::The scanned rulebook would not validate: LC0999: LC0999 is not in catalog/diagnostics.json (catalog/scan-state.json exists); add LC0999 to catalog/diagnostics.json or remove it from base/complete.ruleset.json; the scan writes catalog/scan-state.json, which turns the C7 warning into an error")
    }

    It 'fails with failure nuget when the package source has no index' {
        $run = Invoke-Entry @{ RepositoryRoot = (New-Org); DryRun = $true; PackageSource = (New-StubFeed -Variants 'tools-stable' -Destination (Get-TestFolder)) }
        $run.Result.Failure | Should-Be 'nuget'
        $run.Result.Annotations[-1] | Should-BeLikeString '::error title=ScanDiagnostics::The NuGet packages could not be read: Could not read the NuGet index of alcops.analyzers (HTTP 404)'
    }

    It 'publishes, masks the token and removes its own work folder' {
        $env:RUNNER_TEMP = Get-TestFolder
        [void](New-Item -ItemType Directory -Path $env:RUNNER_TEMP -Force)
        $publish = {
            param([Parameter(ValueFromRemainingArguments)][object[]]$Ignored)
            $null = $Ignored
            [pscustomobject]@{ Result = 'pull-request'; PullRequestUrl = 'https://github.com/Contoso/rulebook/pull/21'; Number = 21; Branch = 'scan-diagnostics/main'; Sha = '0123456789abcdef'; Fallback = $false; Diff = @(); DiffNote = $null; Body = 'body'; Title = 'T' } }
        try {
            $run = Invoke-Entry @{ RepositoryRoot = (New-Org); Token = 'ghp_secret'; PublishCommand = $publish; NoWorkPath = $true }
            $run.Result.ExitCode | Should-Be 0
            $run.Result.Result | Should-Be 'pull-request'
            $run.Result.Outputs.pullRequestUrl | Should-Be 'https://github.com/Contoso/rulebook/pull/21'
            $run.Lines | Should-ContainCollection @('::add-mask::ghp_secret')
            # The org copy in TestDrive is no git checkout, so the base-move guard says it cannot work.
            $run.Result.Annotations | Should-ContainCollection @('::warning title=ScanDiagnostics::base-move guard inactive: the checkout HEAD could not be read')
            @(Get-ChildItem -LiteralPath $env:RUNNER_TEMP -Directory -Filter 'rulebook-scan-*') | Should-BeCollection @()
            $run.Summary | Should-MatchString '(?m)^Pull request: https://github.com/Contoso/rulebook/pull/21$'
        } finally {
            $env:RUNNER_TEMP = $script:saved.RunnerTemp
        }
    }

    It 'reports a refused direct push as one single-line warning annotation and keeps the notice suffix' {
        $reason = "remote: error: GH006: Protected branch update failed for refs/heads/main.`nremote: error: Changes must be made through a pull request.`nTo https://github.com/Contoso/rulebook`n ! [remote rejected] HEAD -> main (protected branch hook declined)`nerror: failed to push some refs to 'https://github.com/Contoso/rulebook'"
        $publish = {
            param([Parameter(ValueFromRemainingArguments)][object[]]$Ignored)
            $null = $Ignored
            [pscustomobject]@{ Result = 'pull-request'; PullRequestUrl = 'https://github.com/Contoso/rulebook/pull/21'; Number = 21; Branch = 'scan-diagnostics/main'; Sha = '0123456789abcdef'; Fallback = $true; FallbackReason = $reason; Diff = @(); DiffNote = $null; Body = 'body'; Title = 'T' }
        }.GetNewClosure()
        $run = Invoke-Entry @{ RepositoryRoot = (New-Org); Token = 'ghp_x'; DirectCommit = $true; PublishCommand = $publish }
        $run.Result.ExitCode | Should-Be 0
        $refused = @($run.Result.Annotations | Where-Object { $_ -like '::warning title=ScanDiagnostics::The direct push to *' })
        $refused | Should-BeCollection @('::warning title=ScanDiagnostics::The direct push to main was refused; a pull request was created instead. (' + $reason.Replace("`n", ' ') + ')')
        $run.Result.Annotations[-1] | Should-Be '::notice title=ScanDiagnostics::Pull request: https://github.com/Contoso/rulebook/pull/21 (the direct commit was refused)'
    }

    It 'reports a base branch that moved as it is, without the token advice' {
        $publish = {
            param([Parameter(ValueFromRemainingArguments)][object[]]$Ignored)
            $null = $Ignored
            $exception = [System.InvalidOperationException]::new('The base branch moved during the scan (main 1111111 is now 2222222); nothing was pushed, the next run will pick it up.')
            $exception.Data['Stage'] = 'push'
            $exception.Data['Reason'] = 'base-moved'
            throw $exception }
        $run = Invoke-Entry @{ RepositoryRoot = (New-Org); Token = 'ghp_x'; PublishCommand = $publish }
        $run.Result.ExitCode | Should-Be 1
        $run.Result.Failure | Should-Be 'push'
        $run.Result.Annotations[-1] | Should-Be '::error title=ScanDiagnostics::The base branch moved during the scan (main 1111111 is now 2222222); nothing was pushed, the next run will pick it up.'
    }

    It 'wraps any other push failure in the token advice' {
        $publish = {
            param([Parameter(ValueFromRemainingArguments)][object[]]$Ignored)
            $null = $Ignored
            $exception = [System.InvalidOperationException]::new('git push --force-with-lease scan-diagnostics/main failed: stale info')
            $exception.Data['Stage'] = 'push'
            throw $exception }
        $run = Invoke-Entry @{ RepositoryRoot = (New-Org); Token = 'ghp_x'; PublishCommand = $publish }
        $run.Result.Failure | Should-Be 'push'
        $run.Result.Annotations[-1] | Should-BeLikeString '::error title=ScanDiagnostics::Failed to push the scan. Make sure that the token in the secret GHTOKENWORKFLOW is not expired*(Error was: git push --force-with-lease scan-diagnostics/main failed: stale info)'
    }

    It 'names the pushed branch and fails with failure pull-request when the pull request cannot be opened' {
        $publish = {
            param([Parameter(ValueFromRemainingArguments)][object[]]$Ignored)
            $null = $Ignored
            $exception = [System.InvalidOperationException]::new('Branch scan-diagnostics/main was pushed. Open the pull request by hand: https://github.com/Contoso/rulebook/tree/scan-diagnostics/main')
            $exception.Data['Stage'] = 'pull-request'
            throw $exception }
        $run = Invoke-Entry @{ RepositoryRoot = (New-Org); Token = 'ghp_x'; PublishCommand = $publish }
        $run.Result.ExitCode | Should-Be 1
        $run.Result.Failure | Should-Be 'pull-request'
        $run.Result.Annotations[-1] | Should-BeLikeString '::error title=ScanDiagnostics::Failed to create or update the scan pull request.*https://github.com/Contoso/rulebook/tree/scan-diagnostics/main*'
    }
}
