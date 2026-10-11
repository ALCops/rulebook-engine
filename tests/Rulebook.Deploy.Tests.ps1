# Deploy suite for WP13 (#15) and #104 (D53): modules/Rulebook.Deploy. The version and the notes from RELEASENOTES.md,
# the two-target reference rewrite on tests/fixtures/deploy/template-main and on the real template/, the copy into a
# template clone with the keep list tests/fixtures/deploy/keep.txt, the plan, the preconditions, the git side on bare
# fixture repositories (engine branch and tag, template main and preview, commit and tag, refusals) and the
# orchestrator. Offline: the token exchange and the REST calls are mocked in Rulebook.Deploy; git runs against local
# bare repositories.

BeforeDiscovery {
    $script:gitMissing = $null -eq (Get-Command git -ErrorAction SilentlyContinue)
}

BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $PSScriptRoot 'Helpers' 'RepoFixture.ps1')
    . (Join-Path $PSScriptRoot 'Helpers' 'EngineRef.ps1')
    $script:savedEngineRef = Clear-EngineRefEnvironment
    Import-Module (Join-Path $repoRoot 'modules' 'Rulebook.Common.psd1') -Force
    Import-Module (Join-Path $repoRoot 'modules' 'Rulebook.GitHub.psd1') -Force
    Import-Module (Join-Path $repoRoot 'modules' 'Rulebook.Deploy.psd1') -Force
    $script:fixture = Join-Path $PSScriptRoot 'fixtures' 'deploy' 'template-main'
    $script:keepFile = Join-Path $PSScriptRoot 'fixtures' 'deploy' 'keep.txt'
    $script:utf8 = [System.Text.UTF8Encoding]::new($false)
    $script:notes = @(
        '# Release notes', ''
        '## v1.2.0-beta.1', ''
        '- Deploy: the release pipeline (#1)'
        '- Docs: versioning (#2)', ''
        '## v1.1.0', ''
        '- Older line (#0)'
    ) -join "`n"

    function Get-TestFolder {
        $folder = Join-Path $TestDrive ([guid]::NewGuid().ToString('n').Substring(0, 12))
        [void](New-Item -ItemType Directory -Path $folder)
        return (Resolve-Path -LiteralPath $folder).ProviderPath
    }

    function New-NotesFile {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helper; writes only to TestDrive or mocks')]
        param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
        $path = Join-Path (Get-TestFolder) 'RELEASENOTES.md'
        Write-FixtureText -Path $path -Text $Text
        return $path
    }

    function Get-Text {
        param([Parameter(Mandatory)][string]$Path)
        return [System.IO.File]::ReadAllText($Path, $utf8)
    }

    function New-EngineCheckout {
        # An engine checkout (template/ = the fixture, RELEASENOTES.md) committed on main, and a bare clone of it as
        # the engine remote: { Root, Bare, Sha }.
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helper; writes only to TestDrive or mocks')]
        param([string]$Notes = $script:notes)
        $folder = Get-TestFolder
        $root = Join-Path $folder 'engine'
        Copy-FixtureTree -Source $fixture -Destination (Join-Path $root 'template')
        Write-FixtureText -Path (Join-Path $root 'RELEASENOTES.md') -Text $Notes
        $sha = New-FixtureGitRepo -Root $root -Message 'engine'
        $bare = Join-Path $folder 'engine.git'
        $null = Invoke-FixtureGit -Root $folder -Arguments @('clone', '-q', '--bare', $root, $bare)
        return [pscustomobject]@{ Root = (Resolve-Path -LiteralPath $root).ProviderPath; Bare = (Resolve-Path -LiteralPath $bare).ProviderPath; Sha = $sha }
    }

    function New-TemplateRemote {
        # The template repository: a bare repository whose main holds LICENSE, .github/CODEOWNERS (both kept), a stale
        # page and an old README.
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helper; writes only to TestDrive or mocks')]
        param()
        $source = Get-TestFolder
        Write-FixtureText -Path (Join-Path $source 'LICENSE') -Text 'MIT'
        Write-FixtureText -Path (Join-Path $source '.github' 'CODEOWNERS') -Text '* @ALCops/maintainers'
        Write-FixtureText -Path (Join-Path $source 'docs' 'stale.md') -Text '# Stale'
        Write-FixtureText -Path (Join-Path $source 'README.md') -Text '# Old README'
        return New-BareFixtureRepo -Source $source -Destination (Join-Path (Get-TestFolder) 'rulebook.git')
    }

    function Get-RemoteRef {
        # The sha of Ref in the bare repository, $null when absent.
        param([Parameter(Mandatory)][string]$Bare, [Parameter(Mandatory)][string]$Ref)
        $output = & git -C $Bare rev-parse --verify --quiet "$Ref^{commit}" 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        return ([string]$output).Trim()
    }

    function Get-RemoteFile {
        param([Parameter(Mandatory)][string]$Bare, [Parameter(Mandatory)][string]$Ref, [Parameter(Mandatory)][string]$Path)
        $output = & git -C $Bare show "$($Ref):$Path" 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        return ($output -join "`n")
    }

    function Get-FileBase64 {
        param([Parameter(Mandatory)][string]$Path)
        return [System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes($Path))
    }

    function New-ApiResponse {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helper; writes only to TestDrive or mocks')]
        param([int]$Status, $Body)
        return [pscustomobject]@{ StatusCode = $Status; Body = $Body; Text = ''; Headers = @{}; RateLimitRemaining = $null }
    }

    function Set-DeployApiMock {
        # The token exchange and the REST calls of a deploy: tags absent (or -TagOn names the repositories that have
        # it), the check runs of -Runs, a release POST answered 201.
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helper; writes only to TestDrive or mocks')]
        param([string[]]$TagOn = @(), [object[]]$Runs = @(@{ name = 'test'; status = 'completed'; conclusion = 'success' }))
        Mock Get-GitHubAccessToken -ModuleName Rulebook.Deploy { [pscustomobject]@{ Token = "token-for-$Repository"; Kind = 'app'; ExpiresAt = $null } }
        $script:mockTagOn = $TagOn
        $script:mockRuns = $Runs
        Mock Invoke-GitHubApi -ModuleName Rulebook.Deploy -ParameterFilter { $Path -like '*/git/ref/tags/*' } {
            $repository = ($Path -split '/git/')[0].Substring('repos/'.Length)
            if ($script:mockTagOn -contains $repository) { New-ApiResponse 200 @{ ref = 'refs/tags/x' } } else { New-ApiResponse 404 @{ message = 'Not Found' } }
        }
        Mock Invoke-GitHubApi -ModuleName Rulebook.Deploy -ParameterFilter { $Path -like '*/check-runs*' } {
            New-ApiResponse 200 @{ total_count = $script:mockRuns.Count; check_runs = $script:mockRuns }
        }
        Mock Invoke-GitHubApi -ModuleName Rulebook.Deploy -ParameterFilter { $Method -eq 'POST' -and $Path -like '*/releases' } {
            New-ApiResponse 201 @{ id = 7; html_url = "https://github.com/ALCops/rulebook-engine/releases/tag/$($Body['tag_name'])" }
        }
    }
}

AfterAll {
    Restore-EngineRefEnvironment -Saved $script:savedEngineRef
    Remove-Module Rulebook.Deploy, Rulebook.GitHub, Rulebook.Common -ErrorAction SilentlyContinue
}

Describe 'Get-ReleaseVersion' {
    It 'reads a prerelease heading' {
        $version = Get-ReleaseVersion -Path (New-NotesFile $notes)
        $version.Version | Should-Be 'v1.2.0-beta.1'
        $version.Tag | Should-Be 'v1.2.0-beta.1'
        $version.Major | Should-Be 1
        $version.Branch | Should-Be 'v1'
        $version.Prerelease | Should-BeTrue
        $version.Line | Should-Be '## v1.2.0-beta.1'
    }

    It 'reads a stable heading of a new major' {
        $version = Get-ReleaseVersion -Path (New-NotesFile "# Release notes`n`n## v2.0.0`n`n- Line")
        $version.Version | Should-Be 'v2.0.0'
        $version.Branch | Should-Be 'v2'
        $version.Prerelease | Should-BeFalse
    }

    It 'refuses <Case>' -ForEach @(
        @{ Case = 'a file without a heading'; Text = "# Release notes`n`n- Line"; Message = '*has no*heading*' }
        @{ Case = 'a version without the v'; Text = "## 1.0.0`n`n- Line"; Message = "*is '## 1.0.0'*" }
        @{ Case = 'a version without a patch number'; Text = "## v1.0`n`n- Line"; Message = "*is '## v1.0'*" }
        @{ Case = 'a prose heading first'; Text = "## Unreleased`n`n- Line`n`n## v1.0.0`n`n- Line"; Message = "*is '## Unreleased'*" }
        @{ Case = 'a trailing dash'; Text = "## v1.0.0-`n`n- Line"; Message = "*is '## v1.0.0-'*" }
    ) {
        { Get-ReleaseVersion -Path (New-NotesFile $Text) } | Should-Throw -ExceptionMessage $Message
    }
}

Describe 'Get-ReleaseNotesSection' {
    It 'returns the lines of a section in the middle, up to the next heading' {
        Get-ReleaseNotesSection -Path (New-NotesFile $notes) -Version 'v1.2.0-beta.1' | Should-Be "- Deploy: the release pipeline (#1)`n- Docs: versioning (#2)"
    }

    It 'returns the last section up to the end of the file' {
        Get-ReleaseNotesSection -Path (New-NotesFile $notes) -Version 'v1.1.0' | Should-Be '- Older line (#0)'
    }

    It 'refuses an empty section' {
        { Get-ReleaseNotesSection -Path (New-NotesFile "## v1.3.0`n`n## v1.2.0`n`n- Line") -Version 'v1.3.0' } | Should-Throw -ExceptionMessage "*'## v1.3.0'*is empty*"
    }
}

Describe 'Convert-DeployReference and Update-DeployReference' {
    BeforeAll {
        $script:enginePattern = & (Get-Module Rulebook.Deploy) { $script:EngineReferencePattern }
        $script:templatePattern = & (Get-Module Rulebook.Deploy) { $script:TemplateReferencePattern }
        $script:releaseSet = @('.github/Rulebook-Settings.json', '.github/workflows/Publish.yaml', '.github/workflows/Validate.yaml', 'README.md', 'base/x.json', 'docs/page.md')
        $script:refreshSet = @('.github/Rulebook-Settings.json', 'README.md')
    }

    It 'rewrites <Case>' -ForEach @(
        @{ Case = 'a uses: line'; Text = '      - uses: ALCops/rulebook-engine/actions/Validate@main'; Expected = '      - uses: ALCops/rulebook-engine/actions/Validate@v1' }
        @{ Case = 'templateUrl'; Text = '"templateUrl": "https://github.com/ALCops/rulebook@main",'; Expected = '"templateUrl": "https://github.com/ALCops/rulebook@preview",' }
        @{ Case = 'a raw schema URL'; Text = 'https://raw.githubusercontent.com/ALCops/rulebook-engine/main/schemas/x.json'; Expected = 'https://raw.githubusercontent.com/ALCops/rulebook-engine/v1/schemas/x.json' }
        @{ Case = 'a blob docs link'; Text = '(https://github.com/ALCops/rulebook/blob/main/docs/a.md)'; Expected = '(https://github.com/ALCops/rulebook/blob/preview/docs/a.md)' }
        @{ Case = 'a tree docs link'; Text = 'https://github.com/ALCops/rulebook/tree/main/docs.'; Expected = 'https://github.com/ALCops/rulebook/tree/preview/docs.' }
        @{ Case = 'a raw template link'; Text = 'ALCops/rulebook/raw/main/x'; Expected = 'ALCops/rulebook/raw/preview/x' }
        @{ Case = 'an engine docs link'; Text = 'https://github.com/ALCops/rulebook-engine/blob/main/docs/ARCHITECTURE.md'; Expected = 'https://github.com/ALCops/rulebook-engine/blob/v1/docs/ARCHITECTURE.md' }
        @{ Case = 'a line with both'; Text = 'https://github.com/ALCops/rulebook@main and https://raw.githubusercontent.com/ALCops/rulebook-engine/main/schemas/x.json'; Expected = 'https://github.com/ALCops/rulebook@preview and https://raw.githubusercontent.com/ALCops/rulebook-engine/v1/schemas/x.json' }
    ) {
        Convert-DeployReference -Text $Text -EngineBranch 'v1' -TemplateBranch 'preview' | Should-Be $Expected
    }

    It 'rewrites only the engine references for a release (engine v1, template main)' {
        $text = 'uses: ALCops/rulebook-engine/actions/Validate@main; templateUrl https://github.com/ALCops/rulebook@main; https://github.com/ALCops/rulebook/blob/main/docs/a.md'
        Convert-DeployReference -Text $text -EngineBranch 'v1' -TemplateBranch 'main' | Should-Be 'uses: ALCops/rulebook-engine/actions/Validate@v1; templateUrl https://github.com/ALCops/rulebook@main; https://github.com/ALCops/rulebook/blob/main/docs/a.md'
    }

    It 'rewrites only the template references for a refresh (engine main, template preview)' {
        $text = 'uses: ALCops/rulebook-engine/actions/Validate@main; templateUrl https://github.com/ALCops/rulebook@main; https://raw.githubusercontent.com/ALCops/rulebook-engine/main/schemas/x.json'
        Convert-DeployReference -Text $text -EngineBranch 'main' -TemplateBranch 'preview' | Should-Be 'uses: ALCops/rulebook-engine/actions/Validate@main; templateUrl https://github.com/ALCops/rulebook@preview; https://raw.githubusercontent.com/ALCops/rulebook-engine/main/schemas/x.json'
    }

    It 'never matches an engine reference with the template pattern' {
        foreach ($text in 'ALCops/rulebook-engine@main', 'ALCops/rulebook-engine/main/x', 'ALCops/rulebook-engine/blob/main/x', 'ALCops/rulebook-engine/actions/Validate@main') {
            $text | Should-NotMatchString $templatePattern
            $text | Should-MatchString $enginePattern
        }
    }

    It 'leaves <Case> alone' -ForEach @(
        @{ Case = 'a branch filter'; Text = '    branches: [ main ]' }
        @{ Case = 'the prose main branch'; Text = 'the main branch of your repository' }
        @{ Case = 'maintain'; Text = 'ALCops/rulebook@maintain' }
        @{ Case = 'maintain on the engine'; Text = 'ALCops/rulebook-engine@maintain' }
        @{ Case = 'a longer repository name'; Text = 'ALCops/rulebook-engine-main' }
        @{ Case = 'another owner'; Text = 'contoso/rulebook@main' }
        @{ Case = 'a bare @main'; Text = 'set templateUrl back to `@main`' }
    ) {
        Convert-DeployReference -Text $Text -EngineBranch 'v1' -TemplateBranch 'preview' | Should-Be $Text
    }

    It 'rewrites exactly the files of the fixture with an engine reference for a release, skips the PNG, keeps CRLF and a BOM, and finds nothing on a second run' {
        $root = Get-TestFolder
        Copy-FixtureTree -Source $fixture -Destination $root
        $png = Join-Path $root 'docs' 'images' 'pixel.png'
        $pngBase64 = Get-FileBase64 $png
        $crlfPath = Join-Path $root 'docs' 'page.md'
        [System.IO.File]::WriteAllText($crlfPath, (Get-Text $crlfPath).Replace("`n", "`r`n"), $utf8)
        $bomPath = Join-Path $root 'base' 'x.json'
        [System.IO.File]::WriteAllText($bomPath, (Get-Text $bomPath), [System.Text.UTF8Encoding]::new($true))
        $changed = Update-DeployReference -Root $root -EngineBranch 'v1' -TemplateBranch 'main'
        $changed | Should-BeCollection $releaseSet
        Get-FileBase64 $png | Should-Be $pngBase64
        (Get-Text $crlfPath) | Should-Be "# Page`r`n`r`nThe engine's [architecture](https://github.com/ALCops/rulebook-engine/blob/v1/docs/ARCHITECTURE.md).`r`n"
        $bomBytes = [System.IO.File]::ReadAllBytes($bomPath)
        ('{0:X2}{1:X2}{2:X2}' -f $bomBytes[0], $bomBytes[1], $bomBytes[2]) | Should-Be 'EFBBBF'
        $validate = Get-Text (Join-Path $root '.github' 'workflows' 'Validate.yaml')
        $validate | Should-MatchString 'branches: \[ main \]'
        $validate | Should-MatchString 'actions/CheckForUpdates@v1'
        $readme = Get-Text (Join-Path $root 'README.md')
        $readme | Should-MatchString 'Left alone: the main branch of your repository, maintain, ALCops/rulebook-engine-main\.'
        $readme | Should-MatchString 'rulebook-engine/v1/scripts/Get-RulebookSkeletons\.ps1'
        $readme | Should-MatchString 'rulebook/blob/main/docs/ghtokenworkflow\.md'
        (Get-Text (Join-Path $root '.github' 'Rulebook-Settings.json')) | Should-MatchString 'ALCops/rulebook@main"'
        @(Update-DeployReference -Root $root -EngineBranch 'v1' -TemplateBranch 'main') | Should-BeCollection @()
    }

    It 'rewrites exactly the files of the fixture with a template reference for a refresh, and finds nothing on a second run' {
        $root = Get-TestFolder
        Copy-FixtureTree -Source $fixture -Destination $root
        $changed = Update-DeployReference -Root $root -EngineBranch 'main' -TemplateBranch 'preview'
        $changed | Should-BeCollection $refreshSet
        $readme = Get-Text (Join-Path $root 'README.md')
        $readme | Should-MatchString 'rulebook/blob/preview/docs/ghtokenworkflow\.md'
        $readme | Should-MatchString 'rulebook/tree/preview/docs'
        $readme | Should-MatchString 'rulebook-engine/main/scripts/Get-RulebookSkeletons\.ps1'
        (Get-Text (Join-Path $root '.github' 'Rulebook-Settings.json')) | Should-MatchString 'ALCops/rulebook@preview"'
        (Get-Text (Join-Path $root '.github' 'workflows' 'Validate.yaml')) | Should-MatchString 'actions/Validate@main'
        @(Update-DeployReference -Root $root -EngineBranch 'main' -TemplateBranch 'preview') | Should-BeCollection @()
    }

    It 'changes nothing with main for both targets' {
        $root = Get-TestFolder
        Copy-FixtureTree -Source $fixture -Destination $root
        @(Update-DeployReference -Root $root -EngineBranch 'main' -TemplateBranch 'main') | Should-BeCollection @()
    }

    It 'leaves no engine main in the real template/ after the release rewrite, and the template links at main' {
        $root = Get-TestFolder
        Copy-FixtureTree -Source (Join-Path $repoRoot 'template') -Destination $root
        $changed = Update-DeployReference -Root $root -EngineBranch 'v1' -TemplateBranch 'main'
        foreach ($file in 'skeletons/README.md', 'docs/al-project.md') { $changed | Should-ContainCollection $file }
        $left = foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -File -Include '*.md', '*.yaml', '*.json') {
            $text = Get-Text $file.FullName
            if ($text -match $enginePattern) { "$($file.Name): $($Matches[0])" }
        }
        @($left) | Should-BeCollection @()
        $docs = (Get-ChildItem -LiteralPath (Join-Path $root 'docs') -Recurse -File -Filter '*.md' | ForEach-Object { Get-Text $_.FullName }) -join "`n"
        $docs | Should-MatchString 'raw\.githubusercontent\.com/ALCops/rulebook-engine/v1/scripts/'
        $docs | Should-MatchString 'github\.com/ALCops/rulebook/blob/main/docs/'
        (Get-Text (Join-Path $root '.github' 'Rulebook-Settings.json')) | Should-MatchString 'ALCops/rulebook@main"'
        (Get-Text (Join-Path $root 'skeletons' 'README.md')) | Should-MatchString 'raw\.githubusercontent\.com/ALCops/rulebook-engine/v1/scripts/Get-RulebookSkeletons\.ps1'
    }

    It 'leaves no template main in the real template/ after the refresh rewrite, and the engine references at main' {
        $root = Get-TestFolder
        Copy-FixtureTree -Source (Join-Path $repoRoot 'template') -Destination $root
        $changed = Update-DeployReference -Root $root -EngineBranch 'main' -TemplateBranch 'preview'
        foreach ($file in '.github/Rulebook-Settings.json', 'docs/README.md') { $changed | Should-ContainCollection $file }
        $left = foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -File -Include '*.md', '*.yaml', '*.json') {
            $text = Get-Text $file.FullName
            if ($text -match $templatePattern) { "$($file.Name): $($Matches[0])" }
        }
        @($left) | Should-BeCollection @()
        $docs = (Get-ChildItem -LiteralPath (Join-Path $root 'docs') -Recurse -File -Filter '*.md' | ForEach-Object { Get-Text $_.FullName }) -join "`n"
        $docs | Should-MatchString 'github\.com/ALCops/rulebook/blob/preview/docs/'
        $docs | Should-MatchString 'raw\.githubusercontent\.com/ALCops/rulebook-engine/main/scripts/'
        (Get-Text (Join-Path $root '.github' 'Rulebook-Settings.json')) | Should-MatchString 'ALCops/rulebook@preview"'
    }

    It 'keeps the release named as a bare @main in versioning.md after the refresh rewrite (the writer rule)' {
        $root = Get-TestFolder
        Copy-FixtureTree -Source (Join-Path $repoRoot 'template') -Destination $root
        $null = Update-DeployReference -Root $root -EngineBranch 'main' -TemplateBranch 'preview'
        $text = Get-Text (Join-Path $root 'docs' 'versioning.md')
        $text | Should-MatchString '(?<!ALCops/rulebook)`@main`'
        $text | Should-MatchString '`@preview`'
    }

    It 'spells out no engine branch in the prose of the shipped pages, which the rewrite cannot reach' {
        # "the main branch of ALCops/rulebook-engine" would still say main on a release; name the branch through the uses: lines.
        $pages = @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'template' 'docs') -Recurse -File -Filter '*.md') +
        @(Get-Item -LiteralPath (Join-Path $repoRoot 'template' 'README.md'), (Join-Path $repoRoot 'template' 'skeletons' 'README.md'))
        $hits = foreach ($page in $pages) {
            $number = 0
            foreach ($line in [System.IO.File]::ReadAllLines($page.FullName)) {
                $number++
                if ($line -match 'the `main` branch|main branch of') { "$($page.Name):$number" }
            }
        }
        @($hits) | Should-BeCollection @()
    }

    It 'gives the URLs the engine builds at v1: every schema URL of the released template is what Get-RulebookSchemaUrl returns under GITHUB_ACTION_REF v1' {
        $root = Get-TestFolder
        Copy-FixtureTree -Source (Join-Path $repoRoot 'template') -Destination $root
        $null = Update-DeployReference -Root $root -EngineBranch 'v1' -TemplateBranch 'main'
        $saved = Clear-EngineRefEnvironment
        try {
            $env:GITHUB_ACTION_REF = 'v1'
            $checked = 0
            foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.json') {
                $text = Get-Text $file.FullName
                if ($text -match '"\$schema": "([^"]+)"') {
                    $url = $Matches[1]
                    $url | Should-Be (Get-RulebookSchemaUrl -Name ($url.Substring($url.LastIndexOf('/') + 1))) -Because $file.Name
                    $checked++
                }
            }
            $checked | Should-BeGreaterThan 10
            $scripts = (Get-Text (Join-Path $root 'skeletons' 'README.md'))
            $scripts | Should-MatchString ([regex]::Escape((Get-RulebookScriptUrl -Name 'Get-RulebookSkeletons.ps1')))
            # The docs of an engine at v1 are the template's release, main (D53).
            Get-RulebookDocsUrl -Page 'ghtokenworkflow.md' | Should-Be 'https://github.com/ALCops/rulebook/blob/main/docs/ghtokenworkflow.md'
            (Get-Text (Join-Path $root 'docs' 'changing-a-rule.md')) | Should-MatchString ([regex]::Escape((Get-RulebookDocsUrl -Page 'ghtokenworkflow.md')))
        } finally {
            Restore-EngineRefEnvironment -Saved $saved
        }
    }
}

Describe 'Copy-DeployTemplate' -Skip:$gitMissing {
    BeforeEach {
        $script:source = Get-TestFolder
        Copy-FixtureTree -Source $fixture -Destination $source
        $script:clone = Join-Path (Get-TestFolder) 'clone'
        $null = Invoke-FixtureGit -Root (Split-Path -Parent $clone) -Arguments @('clone', '-q', (New-TemplateRemote), $clone)
        $script:notesPath = New-NotesFile $notes
    }

    It 'removes the stale files, keeps .git and the keep entries (a nested one too) and copies template/ with the release notes copy' {
        $result = Copy-DeployTemplate -Source $source -Destination $clone -KeepPath $keepFile -ReleaseNotesPath $notesPath
        $result.Removed | Should-BeCollection @('docs/stale.md')
        $result.Kept | Should-BeCollection @('.github/CODEOWNERS', 'LICENSE')
        $result.Copied | Should-Be 8
        Test-Path -LiteralPath (Join-Path $clone '.git' 'HEAD') | Should-BeTrue
        Test-Path -LiteralPath (Join-Path $clone 'docs' 'stale.md') | Should-BeFalse
        (Get-Text (Join-Path $clone 'LICENSE')) | Should-Be "MIT`n"
        (Get-Text (Join-Path $clone 'README.md')) | Should-Be (Get-Text (Join-Path $fixture 'README.md'))
        Get-FileBase64 (Join-Path $clone '.github' 'RELEASENOTES.copy.md') | Should-Be (Get-FileBase64 $notesPath)
        Get-FileBase64 (Join-Path $clone 'docs' 'images' 'pixel.png') | Should-Be (Get-FileBase64 (Join-Path $fixture 'docs' 'images' 'pixel.png'))
    }

    It 'changes nothing on a second run: git status stays empty after a commit' {
        $null = Copy-DeployTemplate -Source $source -Destination $clone -KeepPath $keepFile -ReleaseNotesPath $notesPath
        $null = Invoke-FixtureGit -Root $clone -Arguments @('add', '-A')
        $null = Invoke-FixtureGit -Root $clone -Arguments @('commit', '-q', '-m', 'first')
        $second = Copy-DeployTemplate -Source $source -Destination $clone -KeepPath $keepFile -ReleaseNotesPath $notesPath
        $second.Removed | Should-BeCollection @()
        @(Invoke-FixtureGit -Root $clone -Arguments @('status', '--porcelain')) | Should-BeCollection @()
    }

    It 'removes a folder that only held stale files and keeps everything without a keep file except .git' {
        $result = Copy-DeployTemplate -Source $source -Destination $clone -KeepPath '' -ReleaseNotesPath ''
        $result.Removed | Should-BeCollection @('.github/CODEOWNERS', 'LICENSE', 'docs/stale.md')
        Test-Path -LiteralPath (Join-Path $clone '.github' 'RELEASENOTES.copy.md') | Should-BeFalse
    }
}

Describe 'Get-DeployPlan' -Skip:$gitMissing {
    It 'plans a release: version, tag, the two targets, prerelease, notes and the rewritten files, computed on a copy' {
        $engine = New-EngineCheckout
        $plan = Get-DeployPlan -RepositoryRoot $engine.Root -Mode release -Sha $engine.Sha
        $plan.Version | Should-Be 'v1.2.0-beta.1'
        $plan.EngineBranch | Should-Be 'v1'
        $plan.TemplateBranch | Should-Be 'main'
        $plan.PSObject.Properties['Branch'] | Should-BeNull
        $plan.Prerelease | Should-BeTrue
        $plan.Notes | Should-Be "- Deploy: the release pipeline (#1)`n- Docs: versioning (#2)"
        $plan.TemplateFiles | Should-Be 7
        $plan.Rewritten | Should-BeCollection @('.github/Rulebook-Settings.json', '.github/workflows/Publish.yaml', '.github/workflows/Validate.yaml', 'README.md', 'base/x.json', 'docs/page.md')
        (Get-Text (Join-Path $engine.Root 'template' 'README.md')) | Should-MatchString 'rulebook-engine/main/scripts'
    }

    It 'plans a refresh of preview without version or notes, with the template references rewritten' {
        $engine = New-EngineCheckout -Notes "# Release notes`n`n## Unreleased`n"
        $plan = Get-DeployPlan -RepositoryRoot $engine.Root -Mode refresh -Sha $engine.Sha
        $plan.EngineBranch | Should-Be 'main'
        $plan.TemplateBranch | Should-Be 'preview'
        $plan.Version | Should-BeNull
        $plan.Rewritten | Should-BeCollection @('.github/Rulebook-Settings.json', 'README.md')
        (Get-Text (Join-Path $engine.Root 'template' 'README.md')) | Should-MatchString 'rulebook/blob/main/docs'
    }
}

Describe 'Test-DeployPrecondition' -Skip:$gitMissing {
    BeforeAll {
        $script:engine = New-EngineCheckout
        $script:plan = Get-DeployPlan -RepositoryRoot $engine.Root -Mode release -Sha $engine.Sha
    }

    It 'passes with no tag, green check runs and a clean checkout at the commit, leaving out the deploy''s own run' {
        Set-DeployApiMock -Runs @(
            @{ name = 'test'; status = 'completed'; conclusion = 'success' }
            @{ name = 'scan-action'; status = 'completed'; conclusion = 'skipped' }
            @{ name = 'deploy'; status = 'in_progress'; conclusion = $null }
        )
        @(Test-DeployPrecondition -Plan $plan -EngineToken 'e' -TemplateToken 't') | Should-BeCollection @()
    }

    It 'refuses a tag that exists on <Repository>' -ForEach @(@{ Repository = 'ALCops/rulebook-engine' }, @{ Repository = 'ALCops/rulebook' }) {
        Set-DeployApiMock -TagOn @($Repository)
        @(Test-DeployPrecondition -Plan $plan -EngineToken 'e' -TemplateToken 't') | Should-BeCollection @("The tag v1.2.0-beta.1 exists on $Repository; add a new '## vX.Y.Z' heading to RELEASENOTES.md")
    }

    It 'refuses when the commit has more check runs than one page returns' {
        Set-DeployApiMock
        Mock Invoke-GitHubApi -ModuleName Rulebook.Deploy -ParameterFilter { $Path -like '*/check-runs*' } {
            New-ApiResponse 200 @{ total_count = 101; check_runs = @(@{ name = 'test'; status = 'completed'; conclusion = 'success' }) }
        }
        @(Test-DeployPrecondition -Plan $plan -EngineToken 'e' -TemplateToken 't') | Should-BeCollection @("The commit $($engine.Sha.Substring(0, 7)) has 101 check runs, more than the 1 one page returns; check them by hand")
    }

    It 'refuses check runs that <Case>' -ForEach @(
        @{ Case = 'failed'; Runs = @(@{ name = 'test'; status = 'completed'; conclusion = 'failure' }); Expected = '*check run test*concluded failure' }
        @{ Case = 'are in progress'; Runs = @(@{ name = 'test'; status = 'in_progress'; conclusion = $null }); Expected = '*check run test*is in_progress*' }
        @{ Case = 'do not exist'; Runs = @(); Expected = '*has no check run named test*' }
    ) {
        Set-DeployApiMock -Runs $Runs
        $refusals = @(Test-DeployPrecondition -Plan $plan -EngineToken 'e' -TemplateToken 't')
        $refusals.Count | Should-Be 1
        $refusals[0] | Should-BeLikeString $Expected
    }

    It 'refuses a dirty checkout and a HEAD that is not the commit, in both modes' {
        Set-DeployApiMock
        $dirty = New-EngineCheckout
        Write-FixtureText -Path (Join-Path $dirty.Root 'stray.txt') -Text 'x'
        $dirtyPlan = Get-DeployPlan -RepositoryRoot $dirty.Root -Mode refresh -Sha ('a' * 40)
        $refusals = @(Test-DeployPrecondition -Plan $dirtyPlan)
        $refusals.Count | Should-Be 2
        $refusals[0] | Should-BeLikeString 'The checkout has uncommitted changes: ?? stray.txt'
        $refusals[1] | Should-BeLikeString 'The checkout is at *, not at the commit to deploy aaaaaaa'
        Should-Invoke Invoke-GitHubApi -ModuleName Rulebook.Deploy -Times 0 -Exactly
    }
}

Describe 'Publish-EngineRelease' -Skip:$gitMissing {
    It 'creates v1 and the tag, then moves v1 to a later commit' {
        $engine = New-EngineCheckout
        $first = Publish-EngineRelease -Root $engine.Root -RemoteUrl $engine.Bare -Sha $engine.Sha -Branch 'v1' -Tag 'v1.0.0'
        $first.Created | Should-BeTrue
        Get-RemoteRef -Bare $engine.Bare -Ref 'refs/heads/v1' | Should-Be $engine.Sha
        Get-RemoteRef -Bare $engine.Bare -Ref 'refs/tags/v1.0.0' | Should-Be $engine.Sha
        Write-FixtureText -Path (Join-Path $engine.Root 'later.txt') -Text 'x'
        $later = New-FixtureGitRepo -Root $engine.Root -Message 'later'
        $second = Publish-EngineRelease -Root $engine.Root -RemoteUrl $engine.Bare -Sha $later -Branch 'v1' -Tag 'v1.0.1'
        $second.OldSha | Should-Be $engine.Sha
        Get-RemoteRef -Bare $engine.Bare -Ref 'refs/heads/v1' | Should-Be $later
        Get-RemoteRef -Bare $engine.Bare -Ref 'refs/tags/v1.0.1' | Should-Be $later
    }

    It 'moves v1 to a commit that is not a descendant (a prerelease from a branch, then the squash commit)' {
        $engine = New-EngineCheckout
        $null = Invoke-FixtureGit -Root $engine.Root -Arguments @('checkout', '-q', '-b', 'feature')
        Write-FixtureText -Path (Join-Path $engine.Root 'feature.txt') -Text 'x'
        $feature = New-FixtureGitRepo -Root $engine.Root -Message 'feature'
        $null = Publish-EngineRelease -Root $engine.Root -RemoteUrl $engine.Bare -Sha $feature -Branch 'v1' -Tag 'v1.0.0-beta.1'
        $null = Invoke-FixtureGit -Root $engine.Root -Arguments @('checkout', '-q', 'main')
        Write-FixtureText -Path (Join-Path $engine.Root 'squash.txt') -Text 'x'
        $squash = New-FixtureGitRepo -Root $engine.Root -Message 'squash'
        $null = Publish-EngineRelease -Root $engine.Root -RemoteUrl $engine.Bare -Sha $squash -Branch 'v1' -Tag 'v1.0.0-beta.2'
        Get-RemoteRef -Bare $engine.Bare -Ref 'refs/heads/v1' | Should-Be $squash
    }

    It 'refuses a move when v1 moved since it was read (the lease), and pushes no tag' {
        $engine = New-EngineCheckout
        $null = Publish-EngineRelease -Root $engine.Root -RemoteUrl $engine.Bare -Sha $engine.Sha -Branch 'v1' -Tag 'v1.0.0'
        Write-FixtureText -Path (Join-Path $engine.Root 'later.txt') -Text 'x'
        $later = New-FixtureGitRepo -Root $engine.Root -Message 'later'
        # What the deploy read before someone else moved v1: a commit that is not the branch head any more.
        Mock Get-RemoteRefSha -ModuleName Rulebook.Deploy { $later }
        { Publish-EngineRelease -Root $engine.Root -RemoteUrl $engine.Bare -Sha $later -Branch 'v1' -Tag 'v1.0.1' } | Should-Throw -ExceptionMessage 'git push v1 failed*'
        Get-RemoteRef -Bare $engine.Bare -Ref 'refs/heads/v1' | Should-Be $engine.Sha
        Get-RemoteRef -Bare $engine.Bare -Ref 'refs/tags/v1.0.1' | Should-BeNull
    }
}

Describe 'Publish-TemplateRelease' -Skip:$gitMissing {
    It 'commits a change, pushes main and tags the commit; an unchanged second run still tags the head' {
        $bare = New-TemplateRemote
        $clone = New-GitHubClone -RemoteUrl $bare -Branch 'main' -Path (Join-Path (Get-TestFolder) 'clone')
        $before = Get-RemoteRef -Bare $bare -Ref 'refs/heads/main'
        Write-FixtureText -Path (Join-Path $clone.Path 'README.md') -Text '# New README'
        $first = Publish-TemplateRelease -Clone $clone -Message 'Release v1.0.0' -TargetBranch 'main' -Tag 'v1.0.0'
        $first.Pushed | Should-BeTrue
        $first.Tagged | Should-BeTrue
        Get-RemoteRef -Bare $bare -Ref 'refs/heads/main' | Should-Be $first.Sha
        (& git -C $bare rev-parse "$($first.Sha)~1").Trim() | Should-Be $before
        Get-RemoteRef -Bare $bare -Ref 'refs/tags/v1.0.0' | Should-Be $first.Sha
        $second = Publish-TemplateRelease -Clone $clone -Message 'Release v1.0.1' -TargetBranch 'main' -Tag 'v1.0.1'
        $second.Pushed | Should-BeFalse
        $second.Sha | Should-Be $first.Sha
        Get-RemoteRef -Bare $bare -Ref 'refs/tags/v1.0.1' | Should-Be $first.Sha
    }

    It 'pushes preview without a tag for a refresh, leaving main alone' {
        $bare = New-TemplateRemote
        $main = Get-RemoteRef -Bare $bare -Ref 'refs/heads/main'
        $clone = New-GitHubClone -RemoteUrl $bare -Branch 'main' -Path (Join-Path (Get-TestFolder) 'clone')
        Write-FixtureText -Path (Join-Path $clone.Path 'README.md') -Text '# Refreshed'
        $result = Publish-TemplateRelease -Clone $clone -Message 'Refresh' -TargetBranch 'preview'
        $result.Tagged | Should-BeFalse
        Get-RemoteRef -Bare $bare -Ref 'refs/heads/preview' | Should-Be $result.Sha
        Get-RemoteRef -Bare $bare -Ref 'refs/heads/main' | Should-Be $main
        @(& git -C $bare tag) | Should-BeCollection @()
    }
}

Describe 'New-GitHubRelease' {
    It 'posts the tag, the name, the body and the prerelease flag and returns the release URL' {
        Set-DeployApiMock
        $release = New-GitHubRelease -Repository 'ALCops/rulebook-engine' -Tag 'v1.0.0-beta.1' -Name 'v1.0.0-beta.1' -Body '- Line' -Prerelease -Token 't'
        $release.Url | Should-Be 'https://github.com/ALCops/rulebook-engine/releases/tag/v1.0.0-beta.1'
        Should-Invoke Invoke-GitHubApi -ModuleName Rulebook.Deploy -Times 1 -Exactly -ParameterFilter { $Method -eq 'POST' -and $Body['prerelease'] -eq $true -and $Body['body'] -eq '- Line' -and $Body['draft'] -eq $false }
    }

    It 'throws with the API message on another status' {
        Mock Invoke-GitHubApi -ModuleName Rulebook.Deploy { New-ApiResponse 422 @{ message = 'Validation Failed' } }
        { New-GitHubRelease -Repository 'ALCops/rulebook-engine' -Tag 'v1' -Name 'v1' -Body '' -Token 't' } | Should-Throw -ExceptionMessage '*HTTP 422: Validation Failed*'
    }
}

Describe 'Invoke-RulebookDeploy' -Skip:$gitMissing {
    BeforeEach {
        $script:engine = New-EngineCheckout
        $script:templateBare = New-TemplateRemote
        $script:summary = Join-Path (Get-TestFolder) 'summary.md'
        $script:deploy = @{
            RepositoryRoot = $engine.Root; Sha = $engine.Sha; AppClientId = 'Iv23liDeploy'; AppPrivateKey = 'pem'
            EngineRemoteUrl = $engine.Bare; TemplateRemoteUrl = $templateBare; KeepPath = $keepFile; SummaryPath = $summary
            WorkPath = (Join-Path (Get-TestFolder) 'work')
        }
    }

    It 'stops a dry run after the preconditions: the plan and the summary with both targets, no push, no release' {
        Set-DeployApiMock
        $mainBefore = Get-RemoteRef -Bare $templateBare -Ref 'refs/heads/main'
        $result = Invoke-RulebookDeploy -Mode release -DryRun @deploy 6>$null
        $result.ExitCode | Should-Be 0
        $result.Pushed | Should-BeFalse
        Should-Invoke Get-GitHubAccessToken -ModuleName Rulebook.Deploy -Times 2 -Exactly
        Should-Invoke Invoke-GitHubApi -ModuleName Rulebook.Deploy -Times 0 -Exactly -ParameterFilter { $Method -eq 'POST' }
        Get-RemoteRef -Bare $templateBare -Ref 'refs/heads/main' | Should-Be $mainBefore
        Get-RemoteRef -Bare $engine.Bare -Ref 'refs/heads/v1' | Should-BeNull
        $text = Get-Text $summary
        $text | Should-MatchString '## Release v1\.2\.0-beta\.1 \(prerelease\) from '
        $text | Should-MatchString 'DRY RUN: nothing pushed'
        $text | Should-MatchString '### Rewritten \(engine -> `v1`, template -> `main`, 6 files\)'
        $text | Should-MatchString '\| Template branch \| `ALCops/rulebook@main` \|'
        $text | Should-MatchString '- `README\.md`'
        $text | Should-MatchString '- Docs: versioning \(#2\)'
    }

    It 'releases: one commit on template main with the engine references at v1, tags on both, v1 on the engine and a prerelease Release' {
        Set-DeployApiMock
        $mainBefore = Get-RemoteRef -Bare $templateBare -Ref 'refs/heads/main'
        $result = Invoke-RulebookDeploy -Mode release @deploy 6>$null
        $result.ExitCode | Should-Be 0
        $result.ReleaseUrl | Should-Be 'https://github.com/ALCops/rulebook-engine/releases/tag/v1.2.0-beta.1'
        Should-Invoke Get-GitHubAccessToken -ModuleName Rulebook.Deploy -Times 1 -Exactly -ParameterFilter { $Repository -eq 'ALCops/rulebook-engine' -and $Permissions['workflows'] -eq 'write' -and $Permissions['checks'] -eq 'read' -and $Token -like '{"GitHubAppClientId":"Iv23liDeploy"*' }
        Should-Invoke Get-GitHubAccessToken -ModuleName Rulebook.Deploy -Times 1 -Exactly -ParameterFilter { $Repository -eq 'ALCops/rulebook' }
        Should-Invoke Invoke-GitHubApi -ModuleName Rulebook.Deploy -Times 1 -Exactly -ParameterFilter { $Method -eq 'POST' -and $Body['prerelease'] -eq $true -and $Body['body'] -eq "- Deploy: the release pipeline (#1)`n- Docs: versioning (#2)" }
        $main = Get-RemoteRef -Bare $templateBare -Ref 'refs/heads/main'
        $main | Should-NotBe $mainBefore
        (& git -C $templateBare rev-parse "$main~1").Trim() | Should-Be $mainBefore
        (& git -C $templateBare log -1 --format=%s $main).Trim() | Should-Be "Release v1.2.0-beta.1 from ALCops/rulebook-engine@$($engine.Sha.Substring(0, 7))"
        Get-RemoteRef -Bare $templateBare -Ref 'refs/tags/v1.2.0-beta.1' | Should-Be $main
        Get-RemoteRef -Bare $templateBare -Ref 'refs/heads/v1' | Should-BeNull
        Get-RemoteFile -Bare $templateBare -Ref 'main' -Path '.github/workflows/Validate.yaml' | Should-MatchString 'actions/Validate@v1'
        $settings = Get-RemoteFile -Bare $templateBare -Ref 'main' -Path '.github/Rulebook-Settings.json'
        $settings | Should-MatchString 'ALCops/rulebook@main"'
        $settings | Should-MatchString 'rulebook-engine/v1/schemas/'
        Get-RemoteFile -Bare $templateBare -Ref 'main' -Path 'README.md' | Should-MatchString 'ALCops/rulebook/blob/main/docs/'
        Get-RemoteFile -Bare $templateBare -Ref 'main' -Path '.github/RELEASENOTES.copy.md' | Should-MatchString '## v1\.2\.0-beta\.1'
        Get-RemoteFile -Bare $templateBare -Ref 'main' -Path 'LICENSE' | Should-Be 'MIT'
        Get-RemoteFile -Bare $templateBare -Ref 'main' -Path 'docs/stale.md' | Should-BeNull
        Get-RemoteRef -Bare $engine.Bare -Ref 'refs/heads/v1' | Should-Be $engine.Sha
        Get-RemoteRef -Bare $engine.Bare -Ref 'refs/tags/v1.2.0-beta.1' | Should-Be $engine.Sha
        (Get-Text $summary) | Should-MatchString 'Release \| https://github\.com/ALCops/rulebook-engine/releases/tag/v1\.2\.0-beta\.1'
    }

    It 'releases the next version on top of template main: one commit with the notes copy, both tags' {
        Set-DeployApiMock
        $null = Invoke-RulebookDeploy -Mode release @deploy 6>$null
        $first = Get-RemoteRef -Bare $templateBare -Ref 'refs/heads/main'
        Write-FixtureText -Path (Join-Path $engine.Root 'RELEASENOTES.md') -Text ("# Release notes`n`n## v1.2.0-beta.2`n`n- Fix (#3)`n`n" + $notes.Substring('# Release notes'.Length + 2))
        $next = New-FixtureGitRepo -Root $engine.Root -Message 'beta.2'
        $deploy.Sha = $next
        $deploy.WorkPath = Join-Path (Get-TestFolder) 'work'
        $result = Invoke-RulebookDeploy -Mode release @deploy 6>$null
        $result.ExitCode | Should-Be 0
        $second = Get-RemoteRef -Bare $templateBare -Ref 'refs/heads/main'
        (& git -C $templateBare rev-parse "$second~1").Trim() | Should-Be $first
        @(& git -C $templateBare diff --name-only $first $second) | Should-BeCollection @('.github/RELEASENOTES.copy.md')
        Get-RemoteRef -Bare $templateBare -Ref 'refs/tags/v1.2.0-beta.2' | Should-Be $second
        Get-RemoteRef -Bare $engine.Bare -Ref 'refs/heads/v1' | Should-Be $next
    }

    It 'fails without a tag or a release when template main refuses the push' {
        Set-DeployApiMock
        Add-RejectPushHook -BarePath $templateBare -Branch 'main'
        $result = Invoke-RulebookDeploy -Mode release @deploy 6>$null
        $result.ExitCode | Should-Be 1
        $result.Refusals[-1] | Should-BeLikeString 'git push main failed*'
        Get-RemoteRef -Bare $templateBare -Ref 'refs/tags/v1.2.0-beta.1' | Should-BeNull
        Get-RemoteRef -Bare $engine.Bare -Ref 'refs/heads/v1' | Should-BeNull
        Should-Invoke Invoke-GitHubApi -ModuleName Rulebook.Deploy -Times 0 -Exactly -ParameterFilter { $Method -eq 'POST' }
        (Get-Text $summary) | Should-MatchString '### Refused or failed'
    }

    It 'refuses before any push when a precondition fails, with one error line per refusal' {
        Set-DeployApiMock -TagOn @('ALCops/rulebook')
        $mainBefore = Get-RemoteRef -Bare $templateBare -Ref 'refs/heads/main'
        $result = Invoke-RulebookDeploy -Mode release @deploy 6>$null
        $result.ExitCode | Should-Be 1
        @($result.Refusals) | Should-BeCollection @("The tag v1.2.0-beta.1 exists on ALCops/rulebook; add a new '## vX.Y.Z' heading to RELEASENOTES.md")
        Get-RemoteRef -Bare $templateBare -Ref 'refs/heads/main' | Should-Be $mainBefore
    }

    It 'refuses without the App credentials' {
        Set-DeployApiMock
        $deploy.AppClientId = ''
        $result = Invoke-RulebookDeploy -Mode release @deploy 6>$null
        $result.ExitCode | Should-Be 1
        $result.Refusals[0] | Should-BeLikeString '*DEPLOY_APP_ID*DEPLOY_APP_PRIVATE_KEY*'
        Should-Invoke Get-GitHubAccessToken -ModuleName Rulebook.Deploy -Times 0 -Exactly
    }

    It 'refreshes preview, created from the head of main on the first run: template references at preview, engine at main, no tag, no release, and a second run makes no commit' {
        Set-DeployApiMock
        $main = Get-RemoteRef -Bare $templateBare -Ref 'refs/heads/main'
        $result = Invoke-RulebookDeploy -Mode refresh @deploy 6>$null
        $result.ExitCode | Should-Be 0
        $result.Template.Pushed | Should-BeTrue
        $preview = Get-RemoteRef -Bare $templateBare -Ref 'refs/heads/preview'
        (& git -C $templateBare rev-parse "$preview~1").Trim() | Should-Be $main
        Get-RemoteRef -Bare $templateBare -Ref 'refs/heads/main' | Should-Be $main
        Get-RemoteFile -Bare $templateBare -Ref 'preview' -Path '.github/workflows/Validate.yaml' | Should-MatchString 'actions/Validate@main'
        $settings = Get-RemoteFile -Bare $templateBare -Ref 'preview' -Path '.github/Rulebook-Settings.json'
        $settings | Should-MatchString 'ALCops/rulebook@preview"'
        $settings | Should-MatchString 'rulebook-engine/main/schemas/'
        Get-RemoteFile -Bare $templateBare -Ref 'preview' -Path 'README.md' | Should-MatchString 'ALCops/rulebook/blob/preview/docs/'
        Get-RemoteFile -Bare $templateBare -Ref 'preview' -Path '.github/RELEASENOTES.copy.md' | Should-MatchString '## v1\.2\.0-beta\.1'
        Get-RemoteRef -Bare $templateBare -Ref 'refs/heads/v1' | Should-BeNull
        @(& git -C $templateBare tag) | Should-BeCollection @()
        Should-Invoke Invoke-GitHubApi -ModuleName Rulebook.Deploy -Times 0 -Exactly
        $text = Get-Text $summary
        $text | Should-MatchString '## Refresh of ALCops/rulebook@preview from '
        $text | Should-MatchString '### Rewritten \(engine -> `main`, template -> `preview`, 2 files\)'
        $deploy.WorkPath = Join-Path (Get-TestFolder) 'work'
        $again = Invoke-RulebookDeploy -Mode refresh @deploy 6>$null
        $again.ExitCode | Should-Be 0
        $again.Template.Pushed | Should-BeFalse
        Get-RemoteRef -Bare $templateBare -Ref 'refs/heads/preview' | Should-Be $preview
    }

    It 'gives main the release and preview the bleeding edge when a release and a refresh run on one remote' {
        Set-DeployApiMock
        $released = Invoke-RulebookDeploy -Mode release @deploy 6>$null
        $released.ExitCode | Should-Be 0
        $deploy.WorkPath = Join-Path (Get-TestFolder) 'work'
        $refreshed = Invoke-RulebookDeploy -Mode refresh @deploy 6>$null
        $refreshed.ExitCode | Should-Be 0
        $main = Get-RemoteRef -Bare $templateBare -Ref 'refs/heads/main'
        $preview = Get-RemoteRef -Bare $templateBare -Ref 'refs/heads/preview'
        (& git -C $templateBare rev-parse "$preview~1").Trim() | Should-Be $main
        Get-RemoteFile -Bare $templateBare -Ref 'main' -Path '.github/workflows/Validate.yaml' | Should-MatchString 'actions/Validate@v1'
        Get-RemoteFile -Bare $templateBare -Ref 'main' -Path '.github/Rulebook-Settings.json' | Should-MatchString 'ALCops/rulebook@main"'
        Get-RemoteFile -Bare $templateBare -Ref 'preview' -Path '.github/workflows/Validate.yaml' | Should-MatchString 'actions/Validate@main'
        Get-RemoteFile -Bare $templateBare -Ref 'preview' -Path '.github/Rulebook-Settings.json' | Should-MatchString 'ALCops/rulebook@preview"'
        @(& git -C $templateBare tag) | Should-BeCollection @('v1.2.0-beta.1')
    }
}

Describe 'Annotation text' {
    It 'escapes percent, carriage return and line feed for a workflow command' {
        & (Get-Module Rulebook.Deploy) { ConvertTo-AnnotationText "100% done`r`nnext line" } | Should-Be '100%25 done%0D%0Anext line'
    }

    It 'writes a multi-line failure as one ::error line' -Skip:$gitMissing {
        Mock Get-DeployPlan -ModuleName Rulebook.Deploy { throw "first line`nsecond line" }
        $root = (New-EngineCheckout).Root
        $output = @(Invoke-RulebookDeploy -Mode release -RepositoryRoot $root -Sha 'x' -AppClientId 'a' -AppPrivateKey 'b' 6>&1 | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { [string]$_.MessageData })
        $output | Should-ContainCollection '::error title=Deploy::first line%0Asecond line'
    }
}

Describe 'tools/deploy/Invoke-Deploy.ps1' {
    It 'exits 1 without the App credentials, after the plan, with the error annotation and the summary on the host' {
        # A child pwsh: the script ends with exit. It plans on this checkout and stops before any request.
        $entry = Join-Path $repoRoot 'tools' 'deploy' 'Invoke-Deploy.ps1'
        $command = "`$env:DEPLOY_APP_ID = ''; `$env:DEPLOY_APP_PRIVATE_KEY = ''; `$env:GITHUB_STEP_SUMMARY = ''; & '$($entry.Replace("'", "''"))' -Mode release -DryRun"
        $output = @(& pwsh -NoProfile -NonInteractive -Command $command 2>&1) -join "`n"
        $LASTEXITCODE | Should-Be 1
        $output | Should-MatchString '::error title=Deploy::The deploy needs the variable DEPLOY_APP_ID'
        $output | Should-MatchString '## Release v\d+\.\d+\.\d+'
    }
}
