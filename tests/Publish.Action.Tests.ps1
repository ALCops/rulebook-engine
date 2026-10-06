# Action suite for WP05 (#7): actions/Publish/action.yaml, its entry script Publish.ps1 run in-process, and the
# template workflow template/.github/workflows/Publish.yaml. The ci.yml job publish-action runs the action itself
# with deploy off; the live deploy is recorded in docs/reference/publish-targets.md.

BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:actionDir = Join-Path $script:repoRoot 'actions' 'Publish'
    $script:entry = Join-Path $script:actionDir 'Publish.ps1'
    $script:templateDir = Join-Path $script:repoRoot 'template'
    . (Join-Path $PSScriptRoot 'Helpers' 'RepoFixture.ps1')

    # On GitHub Actions these point at the real job; the tests must not write into them.
    $script:saved = @{ Output = $env:GITHUB_OUTPUT; Summary = $env:GITHUB_STEP_SUMMARY; Repository = $env:GITHUB_REPOSITORY; Token = $env:INPUT_TOKEN }
    $env:GITHUB_OUTPUT = $null
    $env:GITHUB_STEP_SUMMARY = $null
    $env:INPUT_TOKEN = $null

    function Get-TestFolder {
        return Join-Path $TestDrive ([guid]::NewGuid().ToString('n').Substring(0, 12))
    }

    function Copy-Template {
        # A copy of template/ with baseUrl set, or left empty with -EmptyBaseUrl.
        param([switch]$EmptyBaseUrl)
        $destination = Get-TestFolder
        Copy-FixtureTree -Source $script:templateDir -Destination $destination
        if (-not $EmptyBaseUrl) {
            Edit-FixtureJson -Path (Join-Path $destination '.github' 'Rulebook-Settings.json') -Script { $_.baseUrl = 'https://contoso.github.io/rulebook' }
        }
        return (Resolve-Path -LiteralPath $destination).ProviderPath
    }

    function Invoke-Entry {
        # Runs Publish.ps1 in-process; returns the result object, the console lines and the summary.
        param([hashtable]$Parameters)
        $folder = Get-TestFolder
        if (-not $Parameters.ContainsKey('SummaryPath')) { $Parameters.SummaryPath = "$folder.summary.md" }
        if (-not $Parameters.ContainsKey('StagingPath')) { $Parameters.StagingPath = Join-Path $folder 'stage' }
        if (-not $Parameters.ContainsKey('ManifestPath')) { $Parameters.ManifestPath = Join-Path $folder 'manifest.json' }
        if (-not $Parameters.ContainsKey('Repository')) { $Parameters.Repository = 'Contoso/Rulebook' }
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
    $env:INPUT_TOKEN = $script:saved.Token
    Remove-Module Rulebook.Publish, Rulebook.Generate -ErrorAction SilentlyContinue
}

Describe 'actions/Publish/action.yaml' {
    BeforeAll {
        $script:yaml = Get-Content -LiteralPath (Join-Path $actionDir 'action.yaml') -Raw
    }

    It 'is a composite action' {
        $yaml | Should-MatchString '(?m)^  using: composite$'
    }

    It 'declares input <Name> with default <Default>' -ForEach @(
        @{ Name = 'repositoryRoot'; Default = "'.'" }
        @{ Name = 'baseUrl'; Default = "''" }
        @{ Name = 'target'; Default = "''" }
        @{ Name = 'deploy'; Default = "'true'" }
        @{ Name = 'skipCheck'; Default = "'false'" }
        @{ Name = 'checkWindowSeconds'; Default = "'660'" }
        @{ Name = 'token'; Default = '${{ github.token }}' }
    ) {
        $yaml | Should-MatchString ("(?ms)^  {0}:\n.*?^    default: {1}$" -f $Name, [regex]::Escape($Default))
    }

    It 'declares the outputs stagingPath and pageUrl' {
        $yaml | Should-MatchString '(?m)^  stagingPath:$'
        $yaml | Should-MatchString '(?m)^  pageUrl:$'
    }

    It 'passes inputs through env and never interpolates them into run' {
        foreach ($run in [regex]::Matches($yaml, '(?ms)^      run: \|\n(.*?)(?=^    - |\z)')) {
            $run.Groups[1].Value | Should-NotMatchString '\$\{\{'
            $run.Groups[1].Value | Should-MatchString 'GITHUB_ACTION_PATH'
            $run.Groups[1].Value | Should-MatchString 'exit \$result\.ExitCode'
        }
        $yaml | Should-MatchString 'INPUT_BASEURL: \$\{\{ inputs\.baseUrl \}\}'
    }

    It 'uploads and deploys with the pinned Pages actions only when deploy is true' {
        $yaml | Should-MatchString '(?ms)if: inputs\.deploy == ''true''\n      uses: actions/upload-pages-artifact@v5\n      with:\n        path: \$\{\{ steps\.stage\.outputs\.stagingPath \}\}'
        $yaml | Should-MatchString '(?ms)id: deploy\n      if: inputs\.deploy == ''true''\n      uses: actions/deploy-pages@v5'
        $yaml | Should-MatchString "if: inputs\.deploy == 'true' && inputs\.skipCheck != 'true'"
    }
}

Describe 'template/.github/workflows/Publish.yaml' {
    BeforeAll {
        $script:workflow = Get-Content -LiteralPath (Join-Path $repoRoot 'template' '.github' 'workflows' 'Publish.yaml') -Raw
    }

    It 'runs on pushes to main and on demand' {
        $workflow | Should-MatchString '(?ms)^on:\n  push:\n    branches: \[ main \]\n  workflow_dispatch:$'
    }

    It 'grants pages and id-token write and nothing else that writes (D42)' {
        $workflow | Should-MatchString '(?ms)^permissions:\n  contents: read\n  pages: write\n  id-token: write\n\n'
        $workflow | Should-NotMatchString 'contents: write'
    }

    It 'never cancels a running deploy' {
        $workflow | Should-MatchString '(?ms)^concurrency:\n  group: publish-pages\n  cancel-in-progress: false$'
    }

    It 'deploys to the github-pages environment with the page URL' {
        $workflow | Should-MatchString '(?ms)environment:\n      name: github-pages\n      url: \$\{\{ steps\.publish\.outputs\.pageUrl \}\}'
    }

    It 'validates before it publishes' {
        $workflow | Should-MatchString 'fetch-depth: 0'
        $validate = $workflow.IndexOf('uses: ALCops/rulebook-engine/actions/Validate@main')
        $publish = $workflow.IndexOf('uses: ALCops/rulebook-engine/actions/Publish@main')
        $validate | Should-BeGreaterThan 0
        $publish | Should-BeGreaterThan $validate
        $workflow | Should-MatchString '(?ms)id: publish\n        uses: ALCops/rulebook-engine/actions/Publish@main'
    }
}

Describe 'Publish.ps1 -Phase Stage' {
    It 'stages a template copy without deploying and writes the outputs and the summary' {
        $root = Copy-Template
        $outputFile = Join-Path $TestDrive 'github-output.txt'
        $env:GITHUB_OUTPUT = $outputFile
        try {
            $run = Invoke-Entry @{ RepositoryRoot = $root; WorkspaceRoot = $root }
        } finally {
            $env:GITHUB_OUTPUT = $null
        }
        $run.Result.ExitCode | Should-Be 0
        $run.Result.BaseUrl | Should-Be 'https://contoso.github.io/rulebook'
        $run.Result.Preflight | Should-BeNull
        @(Get-ChildItem -LiteralPath $run.Result.StagingPath -Recurse -File).Count | Should-Be 25
        Test-Path -LiteralPath $run.Result.ManifestPath -PathType Leaf | Should-BeTrue
        @(Get-Content -LiteralPath $run.Result.ManifestPath -Raw | ConvertFrom-Json).Count | Should-Be 25
        $outputs = Get-Content -LiteralPath $outputFile -Raw
        $outputs | Should-MatchString ('(?m)^stagingPath=' + [regex]::Escape($run.Result.StagingPath) + '$')
        $outputs | Should-MatchString ('(?m)^manifestPath=' + [regex]::Escape($run.Result.ManifestPath) + '$')
        $outputs | Should-MatchString '(?m)^pageUrl=https://contoso\.github\.io/rulebook/$'
        $run.Summary | Should-MatchString 'Staged only \(deploy is off\): 25 files'
        $run.Summary | Should-MatchString '\| skeleton \| https://contoso\.github\.io/rulebook/skeletons/strict\.ci\.ruleset\.json \|'
    }

    It 'prints the site notice when site.enabled is true' {
        $run = Invoke-Entry @{ RepositoryRoot = (Copy-Template) }
        @($run.Result.Annotations | Where-Object { $_ -like '::notice title=Publish::site.enabled is true*WP14*issues/16*' }).Count | Should-Be 1
    }

    It 'lets the baseUrl input override the setting' {
        $run = Invoke-Entry @{ RepositoryRoot = (Copy-Template); BaseUrl = 'https://rules.contoso.com' }
        $run.Result.ExitCode | Should-Be 0
        Get-Content -LiteralPath (Join-Path $run.Result.StagingPath 'skeletons' 'strict.ci.ruleset.json') -Raw | Should-MatchString ([regex]::Escape('https://rules.contoso.com/rulesets/strict.ci.ruleset.json'))
    }

    It 'fails an empty baseUrl with the proposal on the settings file' {
        $root = Copy-Template -EmptyBaseUrl
        $run = Invoke-Entry @{ RepositoryRoot = $root; WorkspaceRoot = (Split-Path -Parent $root); Repository = 'Contoso/Rulebook' }
        $run.Result.ExitCode | Should-Be 1
        $leaf = Split-Path -Leaf $root
        $errors = @($run.Result.Annotations | Where-Object { $_.StartsWith('::error') })
        $errors.Count | Should-Be 1
        $errors[0] | Should-BeLikeString "::error file=$leaf/.github/Rulebook-Settings.json,title=Publish::baseUrl is empty*`"https://contoso.github.io/rulebook`"*"
        $run.Lines | Should-ContainCollection @($errors[0])
        $run.Summary | Should-MatchString 'Publish stopped before deploying'
        Test-Path -LiteralPath $run.Result.StagingPath | Should-BeFalse
    }

    It 'fails target dist-repo as not implemented' {
        $run = Invoke-Entry @{ RepositoryRoot = (Copy-Template); Target = 'dist-repo' }
        $run.Result.ExitCode | Should-Be 1
        @($run.Result.Annotations | Where-Object { $_ -like "::error *::Publish target 'dist-repo' is not implemented yet; see https://github.com/ALCops/rulebook-engine/issues/55*" }).Count | Should-Be 1
    }

    It 'reports a wrong target and an empty baseUrl together' {
        $run = Invoke-Entry @{ RepositoryRoot = (Copy-Template -EmptyBaseUrl); Target = 'gist' }
        $run.Result.ExitCode | Should-Be 1
        $errors = @($run.Result.Annotations | Where-Object { $_.StartsWith('::error') })
        $errors.Count | Should-Be 2
        $errors[0] | Should-BeLikeString "*Publish target 'gist' is not implemented yet*issues/57*"
        $errors[1] | Should-BeLikeString '*baseUrl is empty*'
        $run.Summary | Should-MatchString '(?m)^- Publish target ''gist'''
        $run.Summary | Should-MatchString '(?m)^- baseUrl is empty'
    }

    It 'fails a repository root that does not exist with an annotation and a result' {
        $run = Invoke-Entry @{ RepositoryRoot = (Join-Path $TestDrive 'no-such-repo') }
        $run.Result.ExitCode | Should-Be 1
        $run.Result.Annotations[0] | Should-BeLikeString '::error title=Publish::*no-such-repo*'
        $run.Summary | Should-MatchString 'Publish stopped before deploying'
    }

    It 'fails stale endpoints before staging (D42)' {
        $root = Copy-Template
        $file = Join-Path $root 'rulesets' 'essential.ruleset.json'
        Write-FixtureText -Path $file -Text ((Get-Content -LiteralPath $file -Raw).Replace('"name": "Rulebook ', '"name": "Stale '))
        $run = Invoke-Entry @{ RepositoryRoot = $root }
        $run.Result.ExitCode | Should-Be 1
        @($run.Result.Annotations | Where-Object { $_ -like '::error title=Publish::*rulesets/essential.ruleset.json is stale*' }).Count | Should-Be 1
    }

    It 'fails the preflight when the Pages API cannot be reached' {
        $run = Invoke-Entry @{ RepositoryRoot = (Copy-Template); Deploy = $true; ApiUrl = 'http://127.0.0.1:9' }
        $run.Result.ExitCode | Should-Be 1
        @($run.Result.Annotations | Where-Object { $_ -like '::error title=Publish::*' }).Count | Should-Be 1
        Test-Path -LiteralPath $run.Result.StagingPath | Should-BeFalse
    }
}

Describe 'Publish.ps1 -Phase Check' {
    It 'fails and names each unreachable URL' {
        $stage = Invoke-Entry @{ RepositoryRoot = (Copy-Template); BaseUrl = 'https://127.0.0.1:9/rulebook' }
        $stage.Result.ExitCode | Should-Be 0
        $run = Invoke-Entry @{ Phase = 'Check'; ManifestPath = $stage.Result.ManifestPath; WindowSeconds = 0; TimeoutSeconds = 5 }
        $run.Result.ExitCode | Should-Be 1
        @($run.Result.Results).Count | Should-Be 25
        @($run.Result.Annotations | Where-Object { $_ -like '::error title=Publish::https://127.0.0.1:9/rulebook/rulesets/strict.ci.ruleset.json failed (*) after 1 attempt(s)*AL1033*' }).Count | Should-Be 1
        @($run.Result.Annotations | Where-Object { $_ -like '::error title=Publish::https://127.0.0.1:9/rulebook/ failed*' }).Count | Should-Be 1
        $run.Summary | Should-MatchString '\*\*0 of 25 URLs\*\*'
    }

    It 'reports a staged file that is gone as a failed URL, not an exception' {
        $manifestPath = Join-Path $TestDrive 'gone-manifest.json'
        $entry = [pscustomobject]@{ Path = 'rulesets/strict.ruleset.json'; Url = 'https://127.0.0.1:9/rulebook/rulesets/strict.ruleset.json'; Kind = 'endpoint'; StagedFile = (Join-Path $TestDrive 'gone' 'strict.ruleset.json') }
        Set-Content -LiteralPath $manifestPath -Value (ConvertTo-Json -InputObject @($entry))
        $run = Invoke-Entry @{ Phase = 'Check'; ManifestPath = $manifestPath; WindowSeconds = 0 }
        $run.Result.ExitCode | Should-Be 1
        @($run.Result.Results)[0].Reason | Should-Be 'error'
        $run.Result.Annotations[0] | Should-BeLikeString '::error title=Publish::https://127.0.0.1:9/rulebook/rulesets/strict.ruleset.json failed (the staged file cannot be read*) after 0 attempt(s)*'
    }

    It 'fails without a manifest' {
        $run = Invoke-Entry @{ Phase = 'Check'; ManifestPath = (Join-Path $TestDrive 'missing.json') }
        $run.Result.ExitCode | Should-Be 1
        $run.Result.Annotations[0] | Should-BeLikeString '::error title=Publish::Manifest not found*'
    }
}
