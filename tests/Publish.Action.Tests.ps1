# Action suite for WP05 (#7) and WP14 (#16): actions/Publish/action.yaml, its entry script Publish.ps1 run in-process,
# and the template workflow template/.github/workflows/Publish.yaml. The site is built with the stand-in
# tests/Helpers/HugoStub.ps1 (-HugoPath), so the suite needs no Hugo. The ci.yml job publish-action runs the action
# itself with deploy off and the real Hugo; the live deploy is recorded in docs/reference/publish-targets.md.

BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:actionDir = Join-Path $script:repoRoot 'actions' 'Publish'
    $script:entry = Join-Path $script:actionDir 'Publish.ps1'
    $script:templateDir = Join-Path $script:repoRoot 'template'
    $script:stub = Join-Path $PSScriptRoot 'Helpers' 'HugoStub.ps1'
    # Loaded here too, so the mocks of Install-Hugo and Resolve-RulebookPublishTarget find them in a filtered run.
    Import-Module (Join-Path $script:repoRoot 'modules' 'Rulebook.Publish.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'modules' 'Rulebook.Site.psd1') -Force
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
        # A copy of template/ with baseUrl set, or left empty with -EmptyBaseUrl; -NoSite sets site.enabled to false.
        param([switch]$EmptyBaseUrl, [switch]$NoSite)
        $destination = Get-TestFolder
        Copy-FixtureTree -Source $script:templateDir -Destination $destination
        $data = Join-Path $destination 'site' 'data'
        if (Test-Path -LiteralPath $data) { Remove-Item -LiteralPath $data -Recurse -Force }
        $setBaseUrl = -not $EmptyBaseUrl
        $siteOff = [bool]$NoSite
        Edit-FixtureJson -Path (Join-Path $destination '.github' 'Rulebook-Settings.json') -Script {
            if ($setBaseUrl) { $_.baseUrl = 'https://contoso.github.io/rulebook' }
            if ($siteOff) { $_.site.enabled = $false }
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
        if (-not $Parameters.ContainsKey('HugoPath')) { $Parameters.HugoPath = $script:stub }
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
    Remove-Module Rulebook.Publish, Rulebook.Site, Rulebook.Levels, Rulebook.Catalog, Rulebook.Generate, Rulebook.Action, Rulebook.Common -ErrorAction SilentlyContinue
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
        @{ Name = 'hugoPath'; Default = "'hugo'" }
    ) {
        $yaml | Should-MatchString ("(?ms)^  {0}:\n.*?^    default: {1}$" -f $Name, [regex]::Escape($Default))
    }

    It 'declares the outputs stagingPath, failure and pageUrl' {
        $yaml | Should-MatchString '(?m)^  failure:\n.*\n    value: \$\{\{ steps\.hugo\.outputs\.failure \|\| steps\.stage\.outputs\.failure \}\}$'
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

    It 'installs the pinned Hugo in a step before the stage step' {
        $yaml | Should-MatchString "(?ms)^    - name: Install Hugo\n      id: hugo\n      shell: pwsh\n      env:\n        INPUT_REPOSITORYROOT: \$\{\{ inputs\.repositoryRoot \}\}\n        INPUT_HUGOPATH: \$\{\{ inputs\.hugoPath \}\}\n        HUGO_VERSION: '0\.167\.0'\n        HUGO_SHA256: '2d012c4490248195e2db07e89ce7f76af8bead93233e930bdf3733c53acd3b23'\n      run: \|\n        \`$parameters = @\{\n          Phase          = 'Install'"
        $yaml.IndexOf('- name: Install Hugo') | Should-BeLessThan $yaml.IndexOf('- name: Stage the published files')
        $yaml | Should-MatchString '(?ms)id: stage\n.*?INPUT_HUGOPATH: \$\{\{ inputs\.hugoPath \}\}\n      run:'
    }

    It 'uploads and deploys with the pinned Pages actions only when deploy is true' {
        $yaml | Should-MatchString '(?ms)if: inputs\.deploy == ''true''\n      uses: actions/upload-pages-artifact@v5\n      with:\n        path: \$\{\{ steps\.stage\.outputs\.stagingPath \}\}'
        $yaml | Should-MatchString '(?ms)id: deploy\n      if: inputs\.deploy == ''true''\n      uses: actions/deploy-pages@v5'
        $yaml | Should-MatchString "(?m)^      if: inputs\.deploy == 'true' && inputs\.skipCheck != 'true' && steps\.stage\.outputs\.private != 'true'$"
    }

    It 'declares the output private from the stage step and skips the check on a private site' {
        $yaml | Should-MatchString '(?m)^  private:\n.*\n    value: \$\{\{ steps\.stage\.outputs\.private \}\}$'
        $yaml | Should-MatchString "(?ms)- name: Check every published URL\n      if: [^\n]*steps\.stage\.outputs\.private != 'true'"
    }
}

Describe 'template/.github/workflows/Publish.yaml' {
    BeforeAll {
        $script:workflow = Get-Content -LiteralPath (Join-Path $repoRoot 'template' '.github' 'workflows' 'Publish.yaml') -Raw
    }

    It 'runs on pushes to main that change what is published or builds the site, and on demand' {
        $workflow | Should-MatchString '(?ms)^on:\n  push:\n    branches: \[ main \]\n.*?    paths:\n      - ''rulesets/\*\*''\n      - ''skeletons/\*\*''\n      - ''\.github/Rulebook-Settings\.json''\n      - ''\.github/workflows/Publish\.yaml''\n      - ''site/\*\*''\n      - ''catalog/diagnostics\.json''\n  workflow_dispatch:$'
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
    It 'stages a template copy with the site without deploying and writes the outputs and the summary' {
        # The dry run makes no API call.
        Mock Invoke-PagesPreflight { throw 'must not run' }
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
        # 12 endpoints, 12 skeletons, rulebook.json, the catalog, index.html; 3 stage, 4 level and 628 rule pages; 4 assets.
        @(Get-ChildItem -LiteralPath $run.Result.StagingPath -Recurse -File).Count | Should-Be 667
        Test-Path -LiteralPath $run.Result.ManifestPath -PathType Leaf | Should-BeTrue
        @(Get-Content -LiteralPath $run.Result.ManifestPath -Raw | ConvertFrom-Json).Count | Should-Be 36
        $outputs = Get-Content -LiteralPath $outputFile -Raw
        $outputs | Should-MatchString ('(?m)^stagingPath=' + [regex]::Escape($run.Result.StagingPath) + '$')
        $outputs | Should-MatchString ('(?m)^manifestPath=' + [regex]::Escape($run.Result.ManifestPath) + '$')
        $outputs | Should-MatchString '(?m)^pageUrl=https://contoso\.github\.io/rulebook/$'
        $outputs | Should-MatchString '(?m)^private=false$'
        $run.Result.Private | Should-BeFalse
        Should-Invoke Invoke-PagesPreflight -Times 0 -Exactly
        $run.Summary | Should-MatchString 'Staged only \(deploy is off\): 36 files'
        $run.Summary | Should-MatchString 'The dashboard site: 637 pages built with Hugo in [0-9.]+ s'
        $run.Summary | Should-MatchString '\| catalog \| https://contoso\.github\.io/rulebook/catalog/diagnostics\.json \|'
        $run.Summary | Should-MatchString '\| page \| https://contoso\.github\.io/rulebook/stages/ci/ \|'
        $run.Summary | Should-MatchString '\| skeleton \| https://contoso\.github\.io/rulebook/skeletons/strict\.ci\.ruleset\.json \|'
        $run.Summary | Should-MatchString '\| manifest \| https://contoso\.github\.io/rulebook/rulebook\.json \|'
        $run.Lines | Should-ContainCollection @("Staged 12 endpoints, 12 skeletons, rulebook.json, catalog/diagnostics.json and index.html in $($run.Result.StagingPath)")
        @($run.Lines | Where-Object { $_ -like 'Built the site: 637 pages in * s' }).Count | Should-Be 1
        @($run.Result.Annotations) | Should-BeCollection @()
        # The repository reaches rulebook.json (GITHUB_REPOSITORY in the action, -Repository here).
        (Get-Content -LiteralPath (Join-Path $run.Result.StagingPath 'rulebook.json') -Raw | ConvertFrom-Json).repository | Should-Be 'Contoso/Rulebook'
    }

    It 'copies the staged rulebook.json to site/data/, builds the site into the staging folder and lists the pages to check' {
        $root = Copy-Template
        $run = Invoke-Entry @{ RepositoryRoot = $root }
        $staging = $run.Result.StagingPath
        [System.IO.File]::ReadAllText((Join-Path $root 'site' 'data' 'rulebook.json')) | Should-Be ([System.IO.File]::ReadAllText((Join-Path $staging 'rulebook.json')))
        Get-Content -LiteralPath (Join-Path $staging 'index.html') -Raw | Should-MatchString 'data-rulebook-matrix="default"'
        $pages = @($run.Result.Manifest | Where-Object Kind -CEQ 'page')
        @($pages | ForEach-Object Url) | Should-BeCollection @(
            'https://contoso.github.io/rulebook/stages/default/', 'https://contoso.github.io/rulebook/stages/ci/', 'https://contoso.github.io/rulebook/stages/vnext/'
            'https://contoso.github.io/rulebook/levels/essential/', 'https://contoso.github.io/rulebook/levels/recommended/', 'https://contoso.github.io/rulebook/levels/strict/'
            'https://contoso.github.io/rulebook/levels/complete/', 'https://contoso.github.io/rulebook/setup/', 'https://contoso.github.io/rulebook/rules/al0200/')
        foreach ($page in $pages) {
            $page.Path | Should-Be ($page.Url.Substring('https://contoso.github.io/rulebook/'.Length) + 'index.html')
            Test-Path -LiteralPath $page.StagedFile -PathType Leaf | Should-BeTrue
        }
        $run.Result.Site.PageCount | Should-Be 637
        $run.Result.Manifest[-10].Kind | Should-Be 'index'
    }

    It 'stages the plain index.html, both data files and no page with site.enabled false' {
        $run = Invoke-Entry @{ RepositoryRoot = (Copy-Template -NoSite); HugoPath = (Join-Path $TestDrive 'no-hugo.exe') }
        $run.Result.ExitCode | Should-Be 0
        @(Get-ChildItem -LiteralPath $run.Result.StagingPath -Recurse -File).Count | Should-Be 27
        Get-Content -LiteralPath (Join-Path $run.Result.StagingPath 'index.html') -Raw | Should-MatchString '<h2 id="al-project">'
        Test-Path -LiteralPath (Join-Path $run.Result.StagingPath 'catalog' 'diagnostics.json') -PathType Leaf | Should-BeTrue
        @($run.Result.Manifest | Where-Object Kind -CEQ 'page').Count | Should-Be 0
        $run.Result.Site | Should-BeNull
        @($run.Result.Annotations) | Should-BeCollection @()
    }

    It 'warns and stages the plain index.html when site/hugo.yaml is missing' {
        $root = Copy-Template
        Remove-Item -LiteralPath (Join-Path $root 'site' 'hugo.yaml')
        $run = Invoke-Entry @{ RepositoryRoot = $root }
        $run.Result.ExitCode | Should-Be 0
        @($run.Result.Annotations) | Should-BeCollection @('::warning title=Publish::site.enabled is true, but site/hugo.yaml is missing: this run publishes the plain index.html. Run Update Rulebook System Files to get site/, or set site.enabled to false.')
        Get-Content -LiteralPath (Join-Path $run.Result.StagingPath 'index.html') -Raw | Should-MatchString '<h2 id="al-project">'
        @($run.Result.Manifest | Where-Object Kind -CEQ 'page').Count | Should-Be 0
    }

    It 'warns and stages the plain index.html for a target that cannot serve HTML' {
        Mock Resolve-RulebookPublishTarget { 'dist-repo' }
        $run = Invoke-Entry @{ RepositoryRoot = (Copy-Template) }
        $run.Result.ExitCode | Should-Be 0
        @($run.Result.Annotations) | Should-BeCollection @("::warning title=Publish::site.enabled is true, but the publish target 'dist-repo' serves HTML as plain text: this run publishes the plain index.html.")
        Get-Content -LiteralPath (Join-Path $run.Result.StagingPath 'index.html') -Raw | Should-MatchString '<h2 id="al-project">'
    }

    It 'fails with site when Hugo is not found' {
        $outputFile = Join-Path $TestDrive 'site-output.txt'
        $env:GITHUB_OUTPUT = $outputFile
        try {
            $run = Invoke-Entry @{ RepositoryRoot = (Copy-Template); HugoPath = (Join-Path $TestDrive 'no-hugo.exe') }
        } finally {
            $env:GITHUB_OUTPUT = $null
        }
        $run.Result.ExitCode | Should-Be 1
        $run.Result.Failure | Should-Be 'site'
        Get-Content -LiteralPath $outputFile -Raw | Should-MatchString '(?m)^failure=site$'
        @($run.Result.Annotations) | Should-BeCollection @("::error title=Publish::site.enabled is true, but Hugo was not found ('$(Join-Path $TestDrive 'no-hugo.exe')'). The Publish action installs it on Linux runners; elsewhere install Hugo 0.156.0 or later (extended) and pass its path as the hugoPath input, or set site.enabled to false.")
        Test-Path -LiteralPath $run.Result.ManifestPath | Should-BeFalse
        $run.Summary | Should-MatchString 'Publish stopped before deploying'
    }

    It 'fails with site and the tail of the output when the build fails' {
        $env:HUGO_STUB_EXIT = '3'
        try {
            $run = Invoke-Entry @{ RepositoryRoot = (Copy-Template) }
        } finally {
            $env:HUGO_STUB_EXIT = $null
        }
        $run.Result.ExitCode | Should-Be 1
        $run.Result.Failure | Should-Be 'site'
        $errors = @($run.Result.Annotations | Where-Object { $_.StartsWith('::error') })
        $errors.Count | Should-Be 1
        $errors[0] | Should-BeLikeString '::error title=Publish::The site build failed: Hugo failed with exit code 3 building *stub line 6*stub line 25'
        Test-Path -LiteralPath $run.Result.ManifestPath | Should-BeFalse
    }

    It 'warns when the built index.html has no matrix marker and publishes it as built' {
        $env:HUGO_STUB_NOMARKER = '1'
        try {
            $run = Invoke-Entry @{ RepositoryRoot = (Copy-Template) }
        } finally {
            $env:HUGO_STUB_NOMARKER = $null
        }
        $run.Result.ExitCode | Should-Be 0
        @($run.Result.Annotations) | Should-BeCollection @('::warning title=Publish::The built index.html has no data-rulebook-matrix marker: site/layouts may have dropped the matrix. The site is published as built.')
        @($run.Result.Manifest | Where-Object Kind -CEQ 'page').Count | Should-Be 9
    }

    It 'lets the baseUrl input override the setting' {
        $run = Invoke-Entry @{ RepositoryRoot = (Copy-Template); BaseUrl = 'https://rules.contoso.com' }
        $run.Result.ExitCode | Should-Be 0
        Get-Content -LiteralPath (Join-Path $run.Result.StagingPath 'skeletons' 'strict.ci.ruleset.json') -Raw | Should-MatchString ([regex]::Escape('https://rules.contoso.com/rulesets/strict.ci.ruleset.json'))
    }

    It 'fails an empty baseUrl with the proposal on the settings file and the failure output' {
        $root = Copy-Template -EmptyBaseUrl
        $outputFile = Join-Path $TestDrive 'failure-output.txt'
        $env:GITHUB_OUTPUT = $outputFile
        try {
            $run = Invoke-Entry @{ RepositoryRoot = $root; WorkspaceRoot = (Split-Path -Parent $root); Repository = 'Contoso/Rulebook' }
        } finally {
            $env:GITHUB_OUTPUT = $null
        }
        $run.Result.ExitCode | Should-Be 1
        $run.Result.Failure | Should-Be 'baseUrl-empty'
        Get-Content -LiteralPath $outputFile -Raw | Should-MatchString '(?m)^failure=baseUrl-empty$'
        $leaf = Split-Path -Leaf $root
        $errors = @($run.Result.Annotations | Where-Object { $_.StartsWith('::error') })
        $errors.Count | Should-Be 1
        $errors[0] | Should-BeLikeString "::error file=$leaf/.github/Rulebook-Settings.json,title=Publish::baseUrl is empty. Leave it empty and run Publish with deploy true to take the address of the Pages site, or set `"baseUrl`": `"https://contoso.github.io/rulebook`" in .github/Rulebook-Settings.json*commit it in a pull request and run Publish again."
        # The dry run makes no API call.
        $run.Result.Preflight | Should-BeNull
        $run.Lines | Should-ContainCollection @($errors[0])
        $run.Summary | Should-MatchString 'Publish stopped before deploying'
        Test-Path -LiteralPath $run.Result.StagingPath | Should-BeFalse
    }

    It 'fails target dist-repo as not implemented' {
        $run = Invoke-Entry @{ RepositoryRoot = (Copy-Template); Target = 'dist-repo' }
        $run.Result.ExitCode | Should-Be 1
        $run.Result.Failure | Should-Be 'target'
        @($run.Result.Annotations | Where-Object { $_ -like "::error *::Publish target 'dist-repo' is not implemented yet; see https://github.com/ALCops/rulebook-engine/issues/55*" }).Count | Should-Be 1
    }

    It 'reports a wrong target and an empty baseUrl together' {
        Mock Invoke-PagesPreflight { throw 'must not run' }
        $outputFile = Join-Path $TestDrive 'together-output.txt'
        $env:GITHUB_OUTPUT = $outputFile
        try {
            $run = Invoke-Entry @{ RepositoryRoot = (Copy-Template -EmptyBaseUrl); Target = 'gist' }
        } finally {
            $env:GITHUB_OUTPUT = $null
        }
        $run.Result.ExitCode | Should-Be 1
        # A failed stage step writes only the failure output; private is not written, and the check step does not run.
        $outputs = Get-Content -LiteralPath $outputFile -Raw
        $outputs | Should-MatchString '(?m)^failure=target$'
        $outputs | Should-NotMatchString '(?m)^private='
        $run.Result.Private | Should-BeFalse
        Should-Invoke Invoke-PagesPreflight -Times 0 -Exactly
        $errors = @($run.Result.Annotations | Where-Object { $_.StartsWith('::error') })
        $errors.Count | Should-Be 2
        $errors[0] | Should-BeLikeString "*Publish target 'gist' is not implemented yet*issues/57*"
        $errors[1] | Should-BeLikeString '*baseUrl is empty*'
        $run.Summary | Should-MatchString '(?m)^- Publish target ''gist'''
        $run.Summary | Should-MatchString '(?m)^- baseUrl is empty'
    }

    It 'does not point an error from an action input at the settings file' {
        $run = Invoke-Entry @{ RepositoryRoot = (Copy-Template); Target = 'gist'; BaseUrl = 'https://contoso.github.io/rulebook/' }
        $run.Result.ExitCode | Should-Be 1
        $errors = @($run.Result.Annotations | Where-Object { $_.StartsWith('::error') })
        $errors.Count | Should-Be 2
        foreach ($line in $errors) { $line | Should-BeLikeString '::error title=Publish::*' }
        $errors[1] | Should-BeLikeString '*The baseUrl input ends with a slash*'
        $run.Result.Failure | Should-Be 'target'
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
        $run.Result.Failure | Should-Be 'stage'
        @($run.Result.Annotations | Where-Object { $_ -like '::error title=Publish::*rulesets/essential.ruleset.json is stale*' }).Count | Should-Be 1
    }

    It 'with deploy and an empty baseUrl stages against html_url of the Pages site (D57)' {
        Mock Invoke-PagesPreflight {
            Get-PagesPreflightResult -StatusCode 200 -Body '{"build_type":"workflow","html_url":"https://contoso.github.io/rulebook/","public":true}' -BaseUrl $BaseUrl -Repository $Repository |
                Add-Member -NotePropertyName StatusCode -NotePropertyValue 200 -PassThru
        }
        $outputFile = Join-Path $TestDrive 'derived-output.txt'
        $env:GITHUB_OUTPUT = $outputFile
        try {
            $run = Invoke-Entry @{ RepositoryRoot = (Copy-Template -EmptyBaseUrl); Deploy = $true }
        } finally {
            $env:GITHUB_OUTPUT = $null
        }
        $run.Result.ExitCode | Should-Be 0
        $run.Result.BaseUrl | Should-Be 'https://contoso.github.io/rulebook'
        $run.Result.Private | Should-BeFalse
        # The configured base URL is passed only for the custom-domain warning; an empty one is not passed.
        Should-Invoke Invoke-PagesPreflight -Times 1 -Exactly -ParameterFilter { [string]::IsNullOrEmpty($BaseUrl) -and $Repository -eq 'Contoso/Rulebook' }
        $run.Lines | Should-ContainCollection @('Base URL from the Pages site: https://contoso.github.io/rulebook')
        $run.Summary | Should-MatchString 'Base URL from the Pages site: `https://contoso\.github\.io/rulebook` \(baseUrl is empty\)\.'
        $run.Summary | Should-MatchString 'Deploying to GitHub Pages: 36 files for `https://contoso\.github\.io/rulebook`\.'
        Get-Content -LiteralPath (Join-Path $run.Result.StagingPath 'skeletons' 'strict.ci.ruleset.json') -Raw | Should-MatchString ([regex]::Escape('https://contoso.github.io/rulebook/rulesets/strict.ci.ruleset.json'))
        (Get-Content -LiteralPath (Join-Path $run.Result.StagingPath 'rulebook.json') -Raw | ConvertFrom-Json).baseUrl | Should-Be 'https://contoso.github.io/rulebook'
        @(Get-Content -LiteralPath $run.Result.ManifestPath -Raw | ConvertFrom-Json | Where-Object { -not $_.Url.StartsWith('https://contoso.github.io/rulebook/') }) | Should-BeCollection @()
        $outputs = Get-Content -LiteralPath $outputFile -Raw
        $outputs | Should-MatchString '(?m)^pageUrl=https://contoso\.github\.io/rulebook/$'
        $outputs | Should-MatchString '(?m)^private=false$'
        @($run.Result.Annotations) | Should-BeCollection @()
    }

    It 'ends green on a private Pages site with the warning, the output private and the summary line' {
        Mock Invoke-PagesPreflight {
            Get-PagesPreflightResult -StatusCode 200 -Body '{"build_type":"workflow","html_url":"https://upgraded-fiesta-x1.pages.github.io/","public":false}' -BaseUrl $BaseUrl -Repository $Repository |
                Add-Member -NotePropertyName StatusCode -NotePropertyValue 200 -PassThru
        }
        $outputFile = Join-Path $TestDrive 'private-output.txt'
        $env:GITHUB_OUTPUT = $outputFile
        try {
            $run = Invoke-Entry @{ RepositoryRoot = (Copy-Template -EmptyBaseUrl); Deploy = $true }
        } finally {
            $env:GITHUB_OUTPUT = $null
        }
        $run.Result.ExitCode | Should-Be 0
        $run.Result.Failure | Should-BeNull
        $run.Result.Private | Should-BeTrue
        $run.Result.BaseUrl | Should-Be 'https://upgraded-fiesta-x1.pages.github.io'
        $outputs = Get-Content -LiteralPath $outputFile -Raw
        $outputs | Should-MatchString '(?m)^private=true$'
        $outputs | Should-MatchString '(?m)^pageUrl=https://upgraded-fiesta-x1\.pages\.github\.io/$'
        $warnings = @($run.Result.Annotations | Where-Object { $_.StartsWith('::warning') })
        $warnings.Count | Should-Be 1
        $warnings[0] | Should-BeLikeString '::warning title=Publish::The Pages site is published privately at https://upgraded-fiesta-x1.pages.github.io:*AL compiler cannot fetch*https://github.com/Contoso/Rulebook/settings/pages*Enterprise Managed Users*issues/56*'
        @($run.Result.Annotations | Where-Object { $_.StartsWith('::error') }) | Should-BeCollection @()
        $run.Summary | Should-MatchString 'The Pages site is private: no endpoint was checked, the AL compiler cannot fetch them from this site\.'
    }

    It 'warns twice on a private site served away from a configured baseUrl' {
        Mock Invoke-PagesPreflight {
            Get-PagesPreflightResult -StatusCode 200 -Body '{"build_type":"workflow","html_url":"https://upgraded-fiesta-x1.pages.github.io/","public":false}' -BaseUrl $BaseUrl -Repository $Repository |
                Add-Member -NotePropertyName StatusCode -NotePropertyValue 200 -PassThru
        }
        $run = Invoke-Entry @{ RepositoryRoot = (Copy-Template); Deploy = $true }
        $run.Result.ExitCode | Should-Be 0
        $run.Result.BaseUrl | Should-Be 'https://contoso.github.io/rulebook'
        $run.Result.Private | Should-BeTrue
        Should-Invoke Invoke-PagesPreflight -Times 1 -Exactly -ParameterFilter { $BaseUrl -eq 'https://contoso.github.io/rulebook' }
        $warnings = @($run.Result.Annotations | Where-Object { $_.StartsWith('::warning') })
        $warnings.Count | Should-Be 2
        $warnings[0] | Should-BeLikeString '*published privately at https://upgraded-fiesta-x1.pages.github.io:*'
        $warnings[1] | Should-BeLikeString '*served at https://upgraded-fiesta-x1.pages.github.io, but baseUrl is https://contoso.github.io/rulebook*'
        $run.Summary | Should-NotMatchString 'Base URL from the Pages site'
    }

    It 'fails baseUrl-empty with the proposal when the Pages site answers without html_url' {
        Mock Invoke-PagesPreflight { [pscustomobject]@{ Ok = $true; Message = 'GitHub Pages is enabled with Source GitHub Actions.'; Warning = $null; HtmlUrl = $null; Private = $false; StatusCode = 200 } }
        $run = Invoke-Entry @{ RepositoryRoot = (Copy-Template -EmptyBaseUrl); Deploy = $true }
        $run.Result.ExitCode | Should-Be 1
        $run.Result.Failure | Should-Be 'baseUrl-empty'
        $errors = @($run.Result.Annotations | Where-Object { $_.StartsWith('::error') })
        $errors.Count | Should-Be 1
        $errors[0] | Should-BeLikeString '*The Pages site answered without an address (html_url)*baseUrl is empty*"https://contoso.github.io/rulebook"*'
        Test-Path -LiteralPath $run.Result.StagingPath | Should-BeFalse
    }

    It 'fails baseUrl-invalid when the Pages site answers with an http address' {
        Mock Invoke-PagesPreflight {
            Get-PagesPreflightResult -StatusCode 200 -Body '{"build_type":"workflow","html_url":"http://rules.contoso.com/","public":true}' -BaseUrl $BaseUrl -Repository $Repository |
                Add-Member -NotePropertyName StatusCode -NotePropertyValue 200 -PassThru
        }
        $run = Invoke-Entry @{ RepositoryRoot = (Copy-Template -EmptyBaseUrl); Deploy = $true }
        $run.Result.ExitCode | Should-Be 1
        $run.Result.Failure | Should-Be 'baseUrl-invalid'
        $errors = @($run.Result.Annotations | Where-Object { $_.StartsWith('::error') })
        $errors.Count | Should-Be 1
        $errors[0] | Should-MatchString 'The address of the Pages site, `http://rules\.contoso\.com`, cannot be the base URL: it must be an https URL.*Enforce HTTPS'
        Test-Path -LiteralPath $run.Result.StagingPath | Should-BeFalse
    }

    It 'fails baseUrl-invalid without the Enforce HTTPS hint for an https address that fails the check' {
        Mock Invoke-PagesPreflight { [pscustomobject]@{ Ok = $true; Message = 'GitHub Pages is enabled with Source GitHub Actions.'; Warning = $null; HtmlUrl = 'https://rules.contoso.com/rule book'; Private = $false; StatusCode = 200 } }
        $run = Invoke-Entry @{ RepositoryRoot = (Copy-Template -EmptyBaseUrl); Deploy = $true }
        $run.Result.ExitCode | Should-Be 1
        $run.Result.Failure | Should-Be 'baseUrl-invalid'
        $errors = @($run.Result.Annotations | Where-Object { $_.StartsWith('::error') })
        $errors.Count | Should-Be 1
        $errors[0] | Should-MatchString 'cannot be the base URL: it must be an https URL.* Set baseUrl in \.github/Rulebook-Settings\.json\.$'
        $errors[0] | Should-NotMatchString 'Enforce HTTPS'
    }

    It 'stops a wrong target with deploy and an empty baseUrl before the preflight' {
        Mock Invoke-PagesPreflight { throw 'must not run' }
        $run = Invoke-Entry @{ RepositoryRoot = (Copy-Template -EmptyBaseUrl); Target = 'gist'; Deploy = $true }
        $run.Result.ExitCode | Should-Be 1
        $run.Result.Failure | Should-Be 'target'
        $errors = @($run.Result.Annotations | Where-Object { $_.StartsWith('::error') })
        $errors.Count | Should-Be 1
        $errors[0] | Should-BeLikeString "*Publish target 'gist' is not implemented yet*"
        Should-Invoke Invoke-PagesPreflight -Times 0 -Exactly
    }

    It 'fails the preflight when the Pages API cannot be reached' {
        $run = Invoke-Entry @{ RepositoryRoot = (Copy-Template); Deploy = $true; ApiUrl = 'http://127.0.0.1:9' }
        $run.Result.ExitCode | Should-Be 1
        @($run.Result.Annotations | Where-Object { $_ -like '::error title=Publish::*' }).Count | Should-Be 1
        Test-Path -LiteralPath $run.Result.StagingPath | Should-BeFalse
    }
}

Describe 'Publish.ps1 -Phase Install' {
    It 'skips with site.enabled false and prints why' {
        Mock Install-Hugo { throw 'must not run' }
        $run = Invoke-Entry @{ Phase = 'Install'; RepositoryRoot = (Copy-Template -NoSite); HugoPath = 'hugo' }
        $run.Result.ExitCode | Should-Be 0
        $run.Lines | Should-ContainCollection @('Hugo is not installed: site.enabled is not true in .github/Rulebook-Settings.json, so Publish stages the plain index.html.')
        Should-Invoke Install-Hugo -Times 0 -Exactly
    }

    It 'skips when the hugoPath input names another Hugo' {
        Mock Install-Hugo { throw 'must not run' }
        $run = Invoke-Entry @{ Phase = 'Install'; RepositoryRoot = (Copy-Template); HugoPath = '/opt/hugo/hugo' }
        $run.Result.ExitCode | Should-Be 0
        $run.Lines | Should-ContainCollection @('Hugo is not installed: the hugoPath input names /opt/hugo/hugo.')
    }

    It 'installs the pinned version and prints it' {
        Mock Install-Hugo { [pscustomobject]@{ Path = '/usr/local/bin/hugo'; Version = "hugo v$Version+extended linux/amd64"; Installed = $true; Deb = 'x.deb' } }
        $run = Invoke-Entry @{ Phase = 'Install'; RepositoryRoot = (Copy-Template); HugoPath = 'hugo'; HugoVersion = '0.167.0'; HugoSha256 = ('a' * 64) }
        $run.Result.ExitCode | Should-Be 0
        $run.Lines | Should-ContainCollection @('Installed hugo v0.167.0+extended linux/amd64')
        Should-Invoke Install-Hugo -Times 1 -Exactly -ParameterFilter { $Version -eq '0.167.0' -and $Sha256 -eq ('a' * 64) }
    }

    It 'fails a repository root that does not exist with error' {
        $run = Invoke-Entry @{ Phase = 'Install'; RepositoryRoot = (Join-Path $TestDrive 'no-such-repo') }
        $run.Result.ExitCode | Should-Be 1
        $run.Result.Failure | Should-Be 'error'
        $run.Result.Annotations[0] | Should-BeLikeString '::error title=Publish::*no-such-repo*'
    }

    It 'fails with site when the install fails' {
        Mock Install-Hugo { throw 'SHA256 mismatch' }
        $outputFile = Join-Path $TestDrive 'install-output.txt'
        $env:GITHUB_OUTPUT = $outputFile
        try {
            $run = Invoke-Entry @{ Phase = 'Install'; RepositoryRoot = (Copy-Template); HugoPath = 'hugo'; HugoVersion = '0.167.0'; HugoSha256 = ('a' * 64) }
        } finally {
            $env:GITHUB_OUTPUT = $null
        }
        $run.Result.ExitCode | Should-Be 1
        $run.Result.Failure | Should-Be 'site'
        @($run.Result.Annotations) | Should-BeCollection @('::error title=Publish::Installing Hugo 0.167.0 failed: SHA256 mismatch')
        Get-Content -LiteralPath $outputFile -Raw | Should-MatchString '(?m)^failure=site$'
    }
}

Describe 'Publish.ps1 -Phase Check' {
    It 'fails and names each unreachable URL' {
        $stage = Invoke-Entry @{ RepositoryRoot = (Copy-Template); BaseUrl = 'https://127.0.0.1:9/rulebook' }
        $stage.Result.ExitCode | Should-Be 0
        $run = Invoke-Entry @{ Phase = 'Check'; ManifestPath = $stage.Result.ManifestPath; WindowSeconds = 0; TimeoutSeconds = 5 }
        $run.Result.ExitCode | Should-Be 1
        @($run.Result.Results).Count | Should-Be 36
        @($run.Result.Annotations | Where-Object { $_ -like '::error title=Publish::https://127.0.0.1:9/rulebook/rulesets/strict.ci.ruleset.json failed (*) after 1 attempt(s)*AL1033*' }).Count | Should-Be 1
        @($run.Result.Annotations | Where-Object { $_ -like '::error title=Publish::https://127.0.0.1:9/rulebook/ failed*' }).Count | Should-Be 1
        $run.Summary | Should-MatchString '\*\*0 of 36 URLs\*\*'
        @($run.Result.Annotations | Where-Object { $_ -like '::error title=Publish::https://127.0.0.1:9/rulebook/catalog/diagnostics.json failed*' }).Count | Should-Be 1
        @($run.Result.Annotations | Where-Object { $_ -like '::error title=Publish::https://127.0.0.1:9/rulebook/stages/ci/ failed*' }).Count | Should-Be 1
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

    It 'fails when the manifest lists no URL' {
        $manifestPath = Join-Path $TestDrive 'empty-manifest.json'
        Set-Content -LiteralPath $manifestPath -Value '[]'
        $run = Invoke-Entry @{ Phase = 'Check'; ManifestPath = $manifestPath; WindowSeconds = 0 }
        $run.Result.ExitCode | Should-Be 1
        $run.Result.Annotations[0] | Should-BeLikeString '::error title=Publish::No URL was checked*'
    }

    It 'fails without a manifest' {
        $run = Invoke-Entry @{ Phase = 'Check'; ManifestPath = (Join-Path $TestDrive 'missing.json') }
        $run.Result.ExitCode | Should-Be 1
        $run.Result.Annotations[0] | Should-BeLikeString '::error title=Publish::Manifest not found*'
    }
}

Describe 'Publish.ps1 parameter binding' {
    It 'rejects a stray positional value' {
        # PositionalBinding = $false (#61): every caller binds by name, so a stray value fails before the script runs.
        { & $script:entry -RepositoryRoot $TestDrive 'stray' } | Should-Throw -ExceptionType ([System.Management.Automation.ParameterBindingException]) -ExceptionMessage '*positional parameter*stray*'
    }
}
