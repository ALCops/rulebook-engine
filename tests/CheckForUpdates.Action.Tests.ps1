# Action suite for WP07 (#9): actions/CheckForUpdates/action.yaml, its entry script CheckForUpdates.ps1 run in-process,
# and the template workflow template/.github/workflows/UpdateRulebookSystemFiles.yaml. The ci.yml job update-action
# runs the action itself on the fixtures; the update mode against a repository is in tests/Rulebook.Update.Tests.ps1.

BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:actionDir = Join-Path $script:repoRoot 'actions' 'CheckForUpdates'
    $script:entry = Join-Path $script:actionDir 'CheckForUpdates.ps1'
    $script:templates = Join-Path $PSScriptRoot 'fixtures' 'templates'
    $script:org = Join-Path $PSScriptRoot 'fixtures' 'repos' 'update-org'
    . (Join-Path $PSScriptRoot 'Helpers' 'RepoFixture.ps1')

    # On GitHub Actions these point at the real job; the tests must not write into them.
    $script:saved = @{ Output = $env:GITHUB_OUTPUT; Summary = $env:GITHUB_STEP_SUMMARY; Repository = $env:GITHUB_REPOSITORY; Token = $env:GITHUB_TOKEN }
    $env:GITHUB_OUTPUT = $null
    $env:GITHUB_STEP_SUMMARY = $null
    $env:GITHUB_TOKEN = $null

    function Get-TestFolder {
        return Join-Path $TestDrive ([guid]::NewGuid().ToString('n').Substring(0, 12))
    }

    function Invoke-Entry {
        # Runs CheckForUpdates.ps1 in-process; returns the result object, the console lines and the summary.
        param([hashtable]$Parameters)
        $folder = Get-TestFolder
        if (-not $Parameters.ContainsKey('SummaryPath')) { $Parameters.SummaryPath = "$folder.summary.md" }
        if (-not $Parameters.ContainsKey('WorkPath')) { $Parameters.WorkPath = Join-Path $folder 'work' }
        if (-not $Parameters.ContainsKey('Repository')) { $Parameters.Repository = 'Contoso/rulebook' }
        if (-not $Parameters.ContainsKey('UpdateBranch')) { $Parameters.UpdateBranch = 'main' }
        $output = @(& $script:entry @Parameters 6>&1)
        return [pscustomobject]@{
            Result  = $output | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] } | Select-Object -Last 1
            Lines   = @($output | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { [string]$_.MessageData })
            Summary = if (Test-Path -LiteralPath $Parameters.SummaryPath) { Get-Content -LiteralPath $Parameters.SummaryPath -Raw } else { '' }
        }
    }
}

AfterAll {
    $env:GITHUB_OUTPUT = $script:saved.Output
    $env:GITHUB_STEP_SUMMARY = $script:saved.Summary
    $env:GITHUB_REPOSITORY = $script:saved.Repository
    $env:GITHUB_TOKEN = $script:saved.Token
    Remove-Module Rulebook.Update, Rulebook.GitHub, Rulebook.Template, Rulebook.Validate, Rulebook.Generate -ErrorAction SilentlyContinue
}

Describe 'actions/CheckForUpdates/action.yaml' {
    BeforeAll {
        $script:yaml = Get-Content -LiteralPath (Join-Path $actionDir 'action.yaml') -Raw
    }

    It 'is a composite action' {
        $yaml | Should-MatchString '(?m)^  using: composite$'
    }

    It 'declares input <Name> with default <Default>' -ForEach @(
        @{ Name = 'templateUrl'; Default = "''" }
        @{ Name = 'templatePath'; Default = "''" }
        @{ Name = 'installedTemplatePath'; Default = "''" }
        @{ Name = 'templateSha'; Default = "''" }
        @{ Name = 'token'; Default = "''" }
        @{ Name = 'update'; Default = "'N'" }
        @{ Name = 'downloadLatest'; Default = "'true'" }
        @{ Name = 'directCommit'; Default = "'false'" }
        @{ Name = 'updateBranch'; Default = '${{ github.ref_name }}' }
        @{ Name = 'repositoryRoot'; Default = "'.'" }
        @{ Name = 'actor'; Default = '${{ github.actor }}' }
    ) {
        $yaml | Should-MatchString ("(?ms)^  {0}:\n.*?^    default: {1}$" -f $Name, [regex]::Escape($Default))
    }

    It 'declares the output <Name>' -ForEach @(
        @{ Name = 'updatesAvailable' }
        @{ Name = 'pullRequestUrl' }
        @{ Name = 'templateSha' }
        @{ Name = 'failure' }
    ) {
        $yaml | Should-MatchString ("(?m)^  {0}:\n.*\n    value: \$\{{\{{ steps\.update\.outputs\.{0} \}}\}}$" -f $Name)
    }

    It 'passes inputs through env and never interpolates them into run' {
        $run = [regex]::Match($yaml, '(?ms)^      run: \|\n(.*)').Groups[1].Value
        $run | Should-NotMatchString '\$\{\{'
        foreach ($name in 'TEMPLATEURL', 'TEMPLATEPATH', 'INSTALLEDTEMPLATEPATH', 'TEMPLATESHA', 'TOKEN', 'UPDATE', 'DOWNLOADLATEST', 'DIRECTCOMMIT', 'UPDATEBRANCH', 'REPOSITORYROOT', 'ACTOR') {
            $yaml | Should-MatchString "(?m)^        INPUT_$($name): \`$\{\{ inputs\.\w+ \}\}$"
        }
        $yaml | Should-MatchString '(?m)^        GITHUB_TOKEN: \$\{\{ github\.token \}\}$'
        $run | Should-MatchString 'GITHUB_ACTION_PATH'
        $run | Should-MatchString 'exit \$result\.ExitCode'
    }
}

Describe 'template/.github/workflows/UpdateRulebookSystemFiles.yaml' {
    BeforeAll {
        $script:workflow = Get-Content -LiteralPath (Join-Path $repoRoot 'template' '.github' 'workflows' 'UpdateRulebookSystemFiles.yaml') -Raw
    }

    It 'is named Update Rulebook System Files, without a leading space' {
        $workflow | Should-MatchString '(?m)^name: Update Rulebook System Files$'
    }

    It 'has the dispatch inputs templateUrl, downloadLatest and directCommit' {
        $workflow | Should-MatchString "(?ms)^      templateUrl:\n        description: 'Template repository URL \(current is \{TEMPLATEURL\}\)\. Empty uses the setting\.'\n        required: false\n        default: ''$"
        $workflow | Should-MatchString '(?ms)^      downloadLatest:\n.*?        type: boolean\n        default: true$'
        $workflow | Should-MatchString '(?ms)^      directCommit:\n.*?        type: boolean\n        default: false$'
    }

    It 'keeps the workflow token at contents and actions read' {
        $workflow | Should-MatchString '(?m)^permissions:\n  contents: read\n  actions: read\n\n'
    }

    It 'looks the secret up by the name from the settings and updates' {
        $workflow | Should-MatchString '(?m)^          token: \$\{\{ secrets\[steps\.settings\.outputs\.secretName\] \}\}$'
        $workflow | Should-MatchString "(?m)^          update: 'Y'$"
        $workflow | Should-MatchString '(?m)^        uses: ALCops/rulebook-engine/actions/CheckForUpdates@main$'
    }

    It 'ships no schedule (the update writes it from update.schedule)' {
        $workflow | Should-NotMatchString '(?m)^\s*schedule:'
    }

    It 'never interpolates an expression into run' {
        $run = [regex]::Match($workflow, '(?ms)^        run: \|\n(.*?)\n\n').Groups[1].Value
        $run | Should-MatchString 'ghTokenWorkflowSecretName'
        $run | Should-NotMatchString '\$\{\{'
    }

    It 'reads the settings step the way the update reads the settings' {
        $settingsStep = [regex]::Match($workflow, '(?ms)^        run: \|\n(.*?)\n\n').Groups[1].Value
        $script = Join-Path $TestDrive 'settings-step.ps1'
        [System.IO.File]::WriteAllText($script, ($settingsStep -replace '(?m)^          ', ''))
        $root = Get-TestFolder
        Write-FixtureText -Path (Join-Path $root '.github' 'Rulebook-Settings.json') -Text '{ "templateUrl": "x", "ghTokenWorkflowSecretName": "RULEBOOK_TOKEN", "commitOptions": { "createPullRequest": false } }'
        $output = Join-Path $TestDrive 'settings-output.txt'
        $saved = @{ Output = $env:GITHUB_OUTPUT; Event = $env:EVENT_NAME }
        try {
            $env:GITHUB_OUTPUT = $output
            $env:EVENT_NAME = 'schedule'
            Push-Location -LiteralPath $root
            try { $null = & $script 6>$null } finally { Pop-Location }
        } finally {
            $env:GITHUB_OUTPUT = $saved.Output
            $env:EVENT_NAME = $saved.Event
        }
        (Get-Content -LiteralPath $output) | Should-BeCollection @('secretName=RULEBOOK_TOKEN', 'directCommit=true', 'downloadLatest=true')
    }
}

Describe 'CheckForUpdates.ps1' {
    It 'notices no updates on update-org against v1 (installed v1)' {
        $run = Invoke-Entry @{ RepositoryRoot = $org; TemplatePath = (Join-Path $templates 'v1'); InstalledTemplatePath = (Join-Path $templates 'v1') }
        $run.Result.ExitCode | Should-Be 0
        $run.Result.UpdatesAvailable | Should-BeFalse
        @($run.Result.Annotations) | Should-BeCollection @("::notice title=CheckForUpdates::template commit $($run.Result.TemplateSha.Substring(0, 7)) not recorded; run Update Rulebook System Files once")
        $run.Summary | Should-MatchString '(?m)^## Template update check$'
    }

    It 'warns that updates are available against v2, with the class table' {
        $run = Invoke-Entry @{ RepositoryRoot = $org; TemplatePath = (Join-Path $templates 'v2'); InstalledTemplatePath = (Join-Path $templates 'v1') }
        $run.Result.ExitCode | Should-Be 0
        $run.Result.UpdatesAvailable | Should-BeTrue
        @($run.Result.Annotations) | Should-BeCollection @('::warning title=CheckForUpdates::Updates available: run the Update Rulebook System Files workflow (20 files)')
        $run.Summary | Should-MatchString '(?m)^\| `stages/ci\.json` \| overwrite \| modified \|$'
        $run.Summary | Should-MatchString '(?m)^\| `rulesets/house\.ruleset\.json` \| generated \| modified \|$'
    }

    It 'writes the outputs' {
        $file = Join-Path $TestDrive 'output.txt'
        $env:GITHUB_OUTPUT = $file
        try {
            $run = Invoke-Entry @{ RepositoryRoot = $org; TemplatePath = (Join-Path $templates 'v2'); InstalledTemplatePath = (Join-Path $templates 'v1'); TemplateSha = ('c' * 40) }
        } finally {
            $env:GITHUB_OUTPUT = $null
        }
        $run.Result.TemplateSha | Should-Be ('c' * 40)
        (Get-Content -LiteralPath $file -Raw) | Should-Be "updatesAvailable=true`npullRequestUrl=`ntemplateSha=$('c' * 40)`nfailure=`n"
    }

    It 'fails update mode without the token before any request, pointing at the docs (AC9)' {
        $run = Invoke-Entry @{ RepositoryRoot = $org; Update = $true; ApiUrl = 'http://127.0.0.1:9' }
        $run.Result.ExitCode | Should-Be 1
        $run.Result.Failure | Should-Be 'token'
        @($run.Result.Annotations) | Should-BeCollection @('::error title=CheckForUpdates::The GHTOKENWORKFLOW secret is needed to update system files. Read https://github.com/ALCops/rulebook/blob/main/docs/ghtokenworkflow.md')
        $run.Result.Plan | Should-BeNull
    }

    It 'names the secret from ghTokenWorkflowSecretName' {
        $root = New-FixtureRepo -Name 'update-org' -Destination (Get-TestFolder)
        Edit-FixtureJson -Path (Join-Path $root '.github' 'Rulebook-Settings.json') -Script { $_.ghTokenWorkflowSecretName = 'RULEBOOK_TOKEN' }
        $run = Invoke-Entry @{ RepositoryRoot = $root; Update = $true }
        $run.Result.Annotations[0] | Should-BeLikeString '*The RULEBOOK_TOKEN secret is needed*'
    }

    It 'skips the check with one warning when the template cannot be reached' {
        $run = Invoke-Entry @{ RepositoryRoot = $org; ApiUrl = 'http://127.0.0.1:9' }
        $run.Result.ExitCode | Should-Be 0
        $run.Result.UpdatesAvailable | Should-BeFalse
        $run.Result.Failure | Should-BeNull
        @($run.Result.Annotations).Count | Should-Be 1
        $run.Result.Annotations[0] | Should-BeLikeString '::warning title=CheckForUpdates::update check skipped: *'
    }

    It 'skips the check when the plan itself fails, and fails update mode the same way' {
        $file = Join-Path $TestDrive 'not-a-folder.txt'
        Write-FixtureText -Path $file -Text 'x'
        $parameters = @{ RepositoryRoot = $org; TemplatePath = (Join-Path $templates 'v2'); InstalledTemplatePath = (Join-Path $templates 'v1'); WorkPath = (Join-Path $file 'work') }
        $run = Invoke-Entry $parameters.Clone()
        $run.Result.ExitCode | Should-Be 0
        $run.Result.Failure | Should-BeNull
        $run.Result.UpdatesAvailable | Should-BeFalse
        @($run.Result.Annotations).Count | Should-Be 1
        $run.Result.Annotations[0] | Should-BeLikeString '::warning title=CheckForUpdates::update check skipped: *'
        $update = $parameters.Clone()
        $update.Update = $true
        $update.Token = 'ghp_test'
        (Invoke-Entry $update).Result.ExitCode | Should-Be 1
    }

    It 'masks the write token before any other output' {
        $run = Invoke-Entry @{ RepositoryRoot = $org; TemplatePath = (Join-Path $templates 'v2'); InstalledTemplatePath = (Join-Path $templates 'v1'); Update = $true; Token = 'ghp_secret_value'; RemoteUrl = (Join-Path (Get-TestFolder) 'never.git'); ApiUrl = 'http://127.0.0.1:9' }
        $run.Lines[0] | Should-Be '::add-mask::ghp_secret_value'
        @($run.Lines | Where-Object { $_ -like '*ghp_secret_value*' }) | Should-BeCollection @('::add-mask::ghp_secret_value')
    }

    It 'skips the check when the updated rulebook would not validate' {
        $template = Get-TestFolder
        Copy-FixtureTree -Source (Join-Path $templates 'v2') -Destination $template
        $strict = Join-Path $template 'base' 'strict.ruleset.json'
        [System.IO.File]::WriteAllText($strict, [System.IO.File]::ReadAllText($strict).Replace('"action": "Error" }', '"action": "Default" }'))
        $run = Invoke-Entry @{ RepositoryRoot = $org; TemplatePath = $template; InstalledTemplatePath = (Join-Path $templates 'v1') }
        $run.Result.ExitCode | Should-Be 0
        $run.Result.UpdatesAvailable | Should-BeFalse
        $run.Result.Annotations[0] | Should-BeLikeString '::warning title=CheckForUpdates::update check skipped: the updated rulebook would not validate (*'
    }

    It 'fails update mode on a template that would not validate and pushes nothing (decision 6)' {
        $template = Get-TestFolder
        Copy-FixtureTree -Source (Join-Path $templates 'v2') -Destination $template
        $strict = Join-Path $template 'base' 'strict.ruleset.json'
        [System.IO.File]::WriteAllText($strict, [System.IO.File]::ReadAllText($strict).Replace('"action": "Error" }', '"action": "Default" }'))
        $run = Invoke-Entry @{ RepositoryRoot = $org; WorkspaceRoot = $org; TemplatePath = $template; InstalledTemplatePath = (Join-Path $templates 'v1'); Update = $true; Token = 'ghp_test'; RemoteUrl = (Join-Path (Get-TestFolder) 'never.git') }
        $run.Result.ExitCode | Should-Be 1
        $run.Result.Failure | Should-Be 'validation'
        $run.Result.Result | Should-BeNull
        @($run.Result.Annotations | Where-Object { $_ -like '::error file=base/strict.ruleset.json,title=C*::*The updated rulebook would not validate*' }).Count | Should-BeGreaterThan 0
        $run.Summary | Should-MatchString 'nothing was pushed'
    }

    It 'leaves a work folder the caller passed in place' {
        $work = Join-Path (Get-TestFolder) 'work'
        $null = New-Item -ItemType Directory -Path $work
        Write-FixtureText -Path (Join-Path $work 'keep.txt') -Text 'mine'
        $null = Invoke-Entry @{ RepositoryRoot = $org; TemplatePath = (Join-Path $templates 'v2'); InstalledTemplatePath = (Join-Path $templates 'v1'); WorkPath = $work }
        Test-Path -LiteralPath (Join-Path $work 'keep.txt') -PathType Leaf | Should-BeTrue
    }

    It 'removes the work folder it names itself' {
        $runnerTemp = Get-TestFolder
        $null = New-Item -ItemType Directory -Path $runnerTemp
        $saved = $env:RUNNER_TEMP
        $env:RUNNER_TEMP = $runnerTemp
        try {
            $summary = "$(Get-TestFolder).summary.md"
            $null = & $script:entry -RepositoryRoot $org -TemplatePath (Join-Path $templates 'v2') -InstalledTemplatePath (Join-Path $templates 'v1') -SummaryPath $summary 6>$null
        } finally {
            $env:RUNNER_TEMP = $saved
        }
        @(Get-ChildItem -LiteralPath $runnerTemp -Force) | Should-BeCollection @()
    }
}
