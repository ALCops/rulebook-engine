# Publish suite for WP05 (#7): modules/Rulebook.Publish on a copy of the engine's template/ and the repository
# fixtures (tests/Helpers/RepoFixture.ps1). The HTTP side of the reachability check is mocked; the live run is in
# docs/reference/publish-targets.md.

BeforeAll {
    # The docs, schema and script URLs follow the engine ref: clear what a runner step would set, restore it in AfterAll.
    $script:savedActionRef = $env:GITHUB_ACTION_REF
    $script:savedActionPath = $env:GITHUB_ACTION_PATH
    Remove-Item Env:GITHUB_ACTION_REF, Env:GITHUB_ACTION_PATH -ErrorAction SilentlyContinue
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:templateDir = Join-Path $repoRoot 'template'
    . (Join-Path $PSScriptRoot 'Helpers' 'RepoFixture.ps1')
    Import-Module (Join-Path $repoRoot 'modules' 'Rulebook.Generate.psd1') -Force
    Import-Module (Join-Path $repoRoot 'modules' 'Rulebook.Publish.psd1') -Force
    $script:baseUrl = 'https://contoso.github.io/rulebook'
    $script:utf8 = [System.Text.UTF8Encoding]::new($false)

    function Get-TestFolder {
        return Join-Path $TestDrive ([guid]::NewGuid().ToString('n').Substring(0, 12))
    }

    function Copy-Template {
        $destination = Get-TestFolder
        Copy-FixtureTree -Source $script:templateDir -Destination $destination
        return (Resolve-Path -LiteralPath $destination).ProviderPath
    }

    function Get-RelativeFileList {
        param([string]$Root)
        $files = @(Get-ChildItem -LiteralPath $Root -Recurse -File | ForEach-Object { [System.IO.Path]::GetRelativePath($Root, $_.FullName).Replace('\', '/') })
        [System.Array]::Sort($files, [System.StringComparer]::Ordinal)
        return $files
    }

    function New-TestManifest {
        # Staged files and manifest entries for the reachability check; Bodies maps a relative path to its text.
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helper; writes only to TestDrive')]
        param([System.Collections.IDictionary]$Bodies)
        $folder = Get-TestFolder
        foreach ($path in $Bodies.Keys) {
            $file = Join-Path $folder $path
            [void](New-Item -ItemType Directory -Path (Split-Path -Parent $file) -Force)
            [System.IO.File]::WriteAllText($file, $Bodies[$path], $script:utf8)
            $kind = if ($path -like 'skeletons/*') { 'skeleton' } elseif ($path -eq 'index.html') { 'index' } elseif ($path -eq 'rulebook.json') { 'manifest' } else { 'endpoint' }
            [pscustomobject]@{ Path = $path; Url = "$script:baseUrl/$path"; Kind = $kind; StagedFile = $file }
        }
    }
}

AfterAll {
    $env:GITHUB_ACTION_REF = $script:savedActionRef
    $env:GITHUB_ACTION_PATH = $script:savedActionPath
    Remove-Module Rulebook.Publish, Rulebook.Generate, Rulebook.Common -ErrorAction SilentlyContinue
}

Describe 'New-RulebookPublishStage on template/' {
    BeforeAll {
        $script:stageRoot = Copy-Template
        $script:output = Get-TestFolder
        $script:manifest = @(New-RulebookPublishStage -RepositoryRoot $stageRoot -BaseUrl $baseUrl -OutputPath $output)
    }

    It 'stages exactly the 12 endpoints, the 12 skeletons, rulebook.json and index.html' {
        $files = Get-RelativeFileList -Root $output
        $files.Count | Should-Be 26
        @($files | Where-Object { $_ -like 'rulesets/*' }).Count | Should-Be 12
        @($files | Where-Object { $_ -like 'skeletons/*' }).Count | Should-Be 12
        foreach ($file in 'index.html', 'rulebook.json', 'rulesets/strict.ruleset.json', 'rulesets/strict.ci.ruleset.json', 'skeletons/strict.default.ruleset.json') { $files -ccontains $file | Should-BeTrue }
        @($files | Where-Object { $_ -match '^(base|catalog|site|stages)/' -or $_ -like '.github/*' }).Count | Should-Be 0
        # The template ships skeletons/README.md; staging copies by expected name, so it is not published.
        Test-Path -LiteralPath (Join-Path $stageRoot 'skeletons' 'README.md') -PathType Leaf | Should-BeTrue
        $files -ccontains 'skeletons/README.md' | Should-BeFalse
    }

    It 'returns a manifest in settings order with URLs under the base URL' {
        $manifest.Count | Should-Be 26
        @($manifest | Where-Object Kind -EQ 'endpoint').Count | Should-Be 12
        @($manifest | Where-Object Kind -EQ 'skeleton').Count | Should-Be 12
        $manifest[0].Path | Should-Be 'rulesets/essential.ruleset.json'
        $manifest[1].Path | Should-Be 'rulesets/essential.ci.ruleset.json'
        $manifest[0].Url | Should-Be "$baseUrl/rulesets/essential.ruleset.json"
        $manifest[12].Path | Should-Be 'skeletons/essential.default.ruleset.json'
        $manifest[-2].Kind | Should-Be 'manifest'
        $manifest[-2].Path | Should-Be 'rulebook.json'
        $manifest[-2].Url | Should-Be "$baseUrl/rulebook.json"
        $manifest[-1].Kind | Should-Be 'index'
        $manifest[-1].Url | Should-Be "$baseUrl/"
        foreach ($entry in $manifest) { Test-Path -LiteralPath $entry.StagedFile -PathType Leaf | Should-BeTrue }
    }

    It 'copies the endpoints byte for byte' {
        foreach ($entry in $manifest | Where-Object Kind -EQ 'endpoint') {
            $source = [System.IO.File]::ReadAllBytes((Join-Path $stageRoot $entry.Path))
            [System.Linq.Enumerable]::SequenceEqual([byte[]][System.IO.File]::ReadAllBytes($entry.StagedFile), [byte[]]$source) | Should-BeTrue
        }
    }

    It 'renders the base URL into the staged skeletons and leaves the repository copy alone' {
        $staged = [System.IO.File]::ReadAllText((Join-Path $output 'skeletons' 'strict.ci.ruleset.json'), $utf8)
        $staged | Should-MatchString ([regex]::Escape('"path": "https://contoso.github.io/rulebook/rulesets/strict.ci.ruleset.json"'))
        $staged.Contains('{BASEURL}') | Should-BeFalse
        $repo = [System.IO.File]::ReadAllText((Join-Path $stageRoot 'skeletons' 'strict.ci.ruleset.json'), $utf8)
        $repo.Contains('{BASEURL}/rulesets/strict.ci.ruleset.json') | Should-BeTrue
        $staged | Should-Be $repo.Replace('{BASEURL}', $baseUrl)
        $default = [System.IO.File]::ReadAllText((Join-Path $output 'skeletons' 'strict.default.ruleset.json'), $utf8)
        $default.Contains("$baseUrl/rulesets/strict.ruleset.json") | Should-BeTrue
    }

    It 'writes rulebook.json with the levels and stages in settings order and no repository without -Repository' {
        $json = [System.IO.File]::ReadAllText((Join-Path $output 'rulebook.json'), $utf8) | ConvertFrom-Json -AsHashtable
        $json['baseUrl'] | Should-Be $baseUrl
        # ConvertFrom-Json turns the date into a DateTime, so the text is checked.
        [System.IO.File]::ReadAllText((Join-Path $output 'rulebook.json'), $utf8) | Should-MatchString '(?m)^  "generatedAt": "\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z",$'
        $json.Contains('repository') | Should-BeFalse
        @($json['levels'] | ForEach-Object { $_['slug'] }) | Should-BeCollection @('essential', 'recommended', 'strict', 'complete')
        @($json['levels'] | ForEach-Object { $_['name'] }) | Should-BeCollection @('Essential', 'Recommended', 'Strict', 'Complete')
        $json['levels'][0].Contains('basedOn') | Should-BeFalse
        @($json['levels'] | Select-Object -Skip 1 | ForEach-Object { $_['basedOn'] }) | Should-BeCollection @('essential', 'recommended', 'strict')
        @($json['stages'] | ForEach-Object { $_['slug'] }) | Should-BeCollection @('default', 'ci', 'vnext')
        @($json['stages'] | ForEach-Object { $_['name'] }) | Should-BeCollection @('default', 'CI', 'vNext')
        $json['stages'][1]['description'] | Should-BeLikeString 'Pull request and release builds*'
    }

    It 'writes the repository into rulebook.json with -Repository' {
        $folder = Get-TestFolder
        $null = New-RulebookPublishStage -RepositoryRoot $stageRoot -BaseUrl $baseUrl -OutputPath $folder -Repository 'Contoso/Rulebook'
        ([System.IO.File]::ReadAllText((Join-Path $folder 'rulebook.json'), $utf8) | ConvertFrom-Json -AsHashtable)['repository'] | Should-Be 'Contoso/Rulebook'
    }

    It 'writes LF and no BOM' {
        foreach ($entry in $manifest) {
            $bytes = [System.IO.File]::ReadAllBytes($entry.StagedFile)
            ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should-BeFalse
            $utf8.GetString($bytes).Contains("`r") | Should-BeFalse
        }
    }

    It 'clears the output folder of an earlier run' {
        $folder = Get-TestFolder
        [void](New-Item -ItemType Directory -Path (Join-Path $folder 'rulesets') -Force)
        Set-Content -LiteralPath (Join-Path $folder 'rulesets' 'removed.vnext.ruleset.json') -Value '{}'
        $null = New-RulebookPublishStage -RepositoryRoot $stageRoot -BaseUrl $baseUrl -OutputPath $folder
        Test-Path -LiteralPath (Join-Path $folder 'rulesets' 'removed.vnext.ruleset.json') | Should-BeFalse
        (Get-RelativeFileList -Root $folder).Count | Should-Be 26
    }
}

Describe 'New-RulebookPublishStage guards' {
    It 'does not stage a stray file in rulesets/' {
        $root = Copy-Template
        Write-FixtureText -Path (Join-Path $root 'rulesets' 'old.ruleset.json') -Text '{ "name": "old", "rules": [] }'
        $output = Get-TestFolder
        $manifest = @(New-RulebookPublishStage -RepositoryRoot $root -BaseUrl $baseUrl -OutputPath $output)
        Test-Path -LiteralPath (Join-Path $output 'rulesets' 'old.ruleset.json') | Should-BeFalse
        @($manifest | Where-Object Path -Like '*old*').Count | Should-Be 0
    }

    It 'stages only the remaining stage after a stage is removed from the settings' {
        $root = Copy-Template
        Edit-FixtureJson -Path (Join-Path $root '.github' 'Rulebook-Settings.json') -Script { $_.stages = @($_.stages | Where-Object { $_.name -ne 'vNext' }) }
        Remove-Item -LiteralPath (Join-Path $root 'stages' 'vnext.json'), (Join-Path $root 'quarantine.vnext.json')
        $null = Update-RulebookEndpoints -RepositoryRoot $root
        $output = Get-TestFolder
        $manifest = @(New-RulebookPublishStage -RepositoryRoot $root -BaseUrl $baseUrl -OutputPath $output)
        @($manifest | Where-Object Path -Like '*vnext*').Count | Should-Be 0
        @($manifest | Where-Object Kind -EQ 'endpoint').Count | Should-Be 8
    }

    It 'refuses a stale endpoint and names it (D42)' {
        $root = Copy-Template
        $file = Join-Path $root 'rulesets' 'strict.ci.ruleset.json'
        Write-FixtureText -Path $file -Text ((Get-Content -LiteralPath $file -Raw).Replace('"Info"', '"Warning"'))
        $output = Get-TestFolder
        { New-RulebookPublishStage -RepositoryRoot $root -BaseUrl $baseUrl -OutputPath $output } | Should-Throw -ExceptionMessage '*rulesets/strict.ci.ruleset.json is stale*Publish never commits*'
        Test-Path -LiteralPath $output | Should-BeFalse
    }

    It 'names the same stale and missing endpoints as Update-RulebookEndpoints -WhatIf (C12) on <Name>' -ForEach @(
        @{ Name = 'stale-endpoints'; Mutate = $false }
        @{ Name = 'a template copy with one edited and one deleted endpoint'; Mutate = $true }
    ) {
        if ($Mutate) {
            $root = Copy-Template
            $file = Join-Path $root 'rulesets' 'recommended.vnext.ruleset.json'
            Write-FixtureText -Path $file -Text ((Get-Content -LiteralPath $file -Raw).Replace('"name": "Rulebook ', '"name": "Edited '))
            Remove-Item -LiteralPath (Join-Path $root 'rulesets' 'essential.ruleset.json')
        } else {
            $root = New-FixtureRepo -Name 'stale-endpoints' -Destination (Get-TestFolder)
        }
        # Deletions are strays, which Publish never stages; created and modified are what both must refuse.
        $c12 = @(Update-RulebookEndpoints -RepositoryRoot $root -WhatIf | Where-Object Change -CIn 'created', 'modified' | ForEach-Object File)
        $c12.Count | Should-BeGreaterThan 0
        $message = $null
        try { $null = New-RulebookPublishStage -RepositoryRoot $root -BaseUrl $baseUrl -OutputPath (Get-TestFolder) } catch { $message = $_.Exception.Message }
        $refused = @([regex]::Matches([string]$message, '(rulesets/[a-z0-9.-]+\.ruleset\.json) is (stale|missing)') | ForEach-Object { $_.Groups[1].Value })
        [System.Array]::Sort($c12, [System.StringComparer]::Ordinal)
        [System.Array]::Sort($refused, [System.StringComparer]::Ordinal)
        $refused | Should-BeCollection $c12
    }

    It 'refuses a missing endpoint' {
        $root = Copy-Template
        Remove-Item -LiteralPath (Join-Path $root 'rulesets' 'complete.vnext.ruleset.json')
        { New-RulebookPublishStage -RepositoryRoot $root -BaseUrl $baseUrl -OutputPath (Get-TestFolder) } | Should-Throw -ExceptionMessage '*rulesets/complete.vnext.ruleset.json is missing*'
    }

    It 'refuses a skeleton without {BASEURL}' {
        $root = Copy-Template
        $file = Join-Path $root 'skeletons' 'strict.ci.ruleset.json'
        Write-FixtureText -Path $file -Text ((Get-Content -LiteralPath $file -Raw).Replace('{BASEURL}', 'https://hardcoded.example.com'))
        { New-RulebookPublishStage -RepositoryRoot $root -BaseUrl $baseUrl -OutputPath (Get-TestFolder) } | Should-Throw -ExceptionMessage '*skeletons/strict.ci.ruleset.json does not contain {BASEURL}*'
    }

    It 'refuses a skeleton that is not valid JSON after rendering' {
        $root = Copy-Template
        Write-FixtureText -Path (Join-Path $root 'skeletons' 'strict.ci.ruleset.json') -Text '{ "includedRuleSets": [ { "path": "{BASEURL}/rulesets/strict.ci.ruleset.json" } ]'
        { New-RulebookPublishStage -RepositoryRoot $root -BaseUrl $baseUrl -OutputPath (Get-TestFolder) } | Should-Throw -ExceptionMessage '*skeletons/strict.ci.ruleset.json is not valid JSON after rendering*'
    }

    It 'refuses an output folder that is the repository or contains it' {
        $root = Copy-Template
        { New-RulebookPublishStage -RepositoryRoot $root -BaseUrl $baseUrl -OutputPath $root } | Should-Throw -ExceptionMessage '*is the repository, a folder that contains it, or a drive root*'
        { New-RulebookPublishStage -RepositoryRoot $root -BaseUrl $baseUrl -OutputPath (Split-Path -Parent $root) } | Should-Throw -ExceptionMessage '*folder that contains it*'
        { New-RulebookPublishStage -RepositoryRoot $root -BaseUrl $baseUrl -OutputPath ([System.IO.Path]::GetPathRoot($root)) } | Should-Throw -ExceptionMessage '*drive root*'
        Test-Path -LiteralPath (Join-Path $root '.github' 'Rulebook-Settings.json') | Should-BeTrue
        # A sibling whose name starts with the repository's name is not a parent.
        $output = "$root-stage"
        @(New-RulebookPublishStage -RepositoryRoot $root -BaseUrl $baseUrl -OutputPath $output).Count | Should-Be 26
    }

    It 'resolves a relative output path against the current location' {
        $root = Copy-Template
        Push-Location -LiteralPath $root
        try {
            { New-RulebookPublishStage -RepositoryRoot $root -BaseUrl $baseUrl -OutputPath '.' } | Should-Throw -ExceptionMessage '*is the repository*'
            { New-RulebookPublishStage -RepositoryRoot '.' -BaseUrl $baseUrl -OutputPath '..' } | Should-Throw -ExceptionMessage '*folder that contains it*'
            $manifest = @(New-RulebookPublishStage -RepositoryRoot '.' -BaseUrl $baseUrl -OutputPath '../relative-stage')
        } finally {
            Pop-Location
        }
        $manifest.Count | Should-Be 26
        $expected = Join-Path (Split-Path -Parent $root) 'relative-stage'
        Test-Path -LiteralPath (Join-Path $expected 'index.html') | Should-BeTrue
        $manifest[0].StagedFile | Should-BeLikeString "$expected*"
        Test-Path -LiteralPath (Join-Path $root '.github' 'Rulebook-Settings.json') | Should-BeTrue
    }

    It 'reuses -Inputs' {
        $root = Copy-Template
        $inputs = Read-RulebookInputs -RepositoryRoot $root
        Mock Read-RulebookInputs -ModuleName Rulebook.Publish { throw 'read again' }
        @(New-RulebookPublishStage -RepositoryRoot $root -BaseUrl $baseUrl -OutputPath (Get-TestFolder) -Inputs $inputs).Count | Should-Be 26
    }

    It 'refuses a missing skeleton' {
        $root = Copy-Template
        Remove-Item -LiteralPath (Join-Path $root 'skeletons' 'essential.vnext.ruleset.json')
        { New-RulebookPublishStage -RepositoryRoot $root -BaseUrl $baseUrl -OutputPath (Get-TestFolder) } | Should-Throw -ExceptionMessage '*skeletons/essential.vnext.ruleset.json is missing*'
    }

    It 'refuses a base URL with a trailing slash' {
        { New-RulebookPublishStage -RepositoryRoot (Copy-Template) -BaseUrl "$baseUrl/" -OutputPath (Get-TestFolder) } | Should-Throw -ExceptionMessage '*trailing slash*'
    }
}

Describe 'Resolve-RulebookBaseUrl' {
    It 'returns the setting' {
        Resolve-RulebookBaseUrl -Settings @{ baseUrl = $baseUrl } -Repository 'Contoso/Rulebook' | Should-Be $baseUrl
    }

    It 'accepts a port and an uppercase host' {
        Resolve-RulebookBaseUrl -Settings @{ baseUrl = 'https://Rules.Contoso.com:8443/rulebook' } | Should-Be 'https://Rules.Contoso.com:8443/rulebook'
    }

    It 'accepts dots inside a segment' {
        Resolve-RulebookBaseUrl -Settings @{ baseUrl = 'https://rules.contoso.com/v1.2/..rulebook' } | Should-Be 'https://rules.contoso.com/v1.2/..rulebook'
    }

    It 'lets the override win' {
        Resolve-RulebookBaseUrl -Settings @{ baseUrl = $baseUrl } -Override 'https://rules.contoso.com' | Should-Be 'https://rules.contoso.com'
    }

    It 'proposes <Proposal> for <Repository> when baseUrl is empty' -ForEach @(
        @{ Repository = 'Contoso/Rulebook'; Proposal = 'https://contoso.github.io/rulebook' }
        @{ Repository = 'Contoso/Contoso.github.io'; Proposal = 'https://contoso.github.io' }
        @{ Repository = 'Arthurvdv/rulebook-e2e-publish'; Proposal = 'https://arthurvdv.github.io/rulebook-e2e-publish' }
        @{ Repository = ''; Proposal = 'https://<owner>.github.io/<repository>' }
    ) {
        $message = $null
        try { Resolve-RulebookBaseUrl -Settings @{ baseUrl = '' } -Repository $Repository } catch { $message = $_.Exception.Message }
        $message | Should-BeLikeString "baseUrl is empty*`"baseUrl`": `"$Proposal`"*.github/Rulebook-Settings.json*"
    }

    It 'rejects <Value>' -ForEach @(
        @{ Value = 'https://contoso.github.io/rulebook/'; Message = '*ends with a slash*' }
        @{ Value = 'http://contoso.github.io/rulebook'; Message = '*must be an https URL*' }
        @{ Value = 'https://contoso.github.io/rule book'; Message = '*must be an https URL*' }
        @{ Value = 'https://contoso.github.io/rulebook?v=1'; Message = '*must be an https URL*query*' }
        @{ Value = 'https://contoso.github.io/rulebook#top'; Message = '*must be an https URL*fragment*' }
        @{ Value = 'https://contoso.github.io/./rulebook'; Message = '*must be an https URL*segments*' }
        @{ Value = 'https://contoso.github.io/rulebook/..'; Message = '*must be an https URL*segments*' }
        @{ Value = 'https://contoso.github.io/rule"book'; Message = '*must be an https URL*quotes*' }
        @{ Value = 'https://contoso.github.io/rule\book'; Message = '*must be an https URL*backslashes*' }
        # {BEL} stands for the control character U+0007 in the test name, which the NUnit XML report cannot hold.
        @{ Value = 'https://contoso.github.io/rule{BEL}book'; Message = '*must be an https URL*' }
        @{ Value = 'https://..'; Message = '*must be an https URL with a host name*' }
        @{ Value = 'https://user:secret@contoso.github.io/rulebook'; Message = '*must be an https URL with a host name*' }
        @{ Value = 'https://contoso.github.io:abc/rulebook'; Message = '*must be an https URL with a host name*' }
        @{ Value = 'https://-contoso.github.io'; Message = '*must be an https URL with a host name*' }
    ) {
        $Value = $Value.Replace('{BEL}', [string][char]0x7)
        { Resolve-RulebookBaseUrl -Settings @{ baseUrl = $Value } -Repository 'Contoso/Rulebook' } | Should-Throw -ExceptionMessage $Message
        { Resolve-RulebookBaseUrl -Settings @{ baseUrl = $baseUrl } -Override $Value } | Should-Throw -ExceptionMessage $Message
    }
}

Describe 'Get-SkeletonFileName' {
    It 'always writes the stage, default included' {
        Get-SkeletonFileName -Level 'strict' -Stage 'default' | Should-Be 'strict.default.ruleset.json'
        Get-SkeletonFileName -Level 'strict' -Stage 'ci' | Should-Be 'strict.ci.ruleset.json'
        Get-EndpointFileName -Level 'strict' -Stage 'default' | Should-Be 'strict.ruleset.json'
    }
}

Describe 'Resolve-RulebookPublishTarget' {
    It 'returns pages from the settings, the override or the default' {
        Resolve-RulebookPublishTarget -Settings @{ publish = @{ target = 'pages' } } | Should-Be 'pages'
        Resolve-RulebookPublishTarget -Settings @{ publish = @{ target = 'gist' } } -Override 'pages' | Should-Be 'pages'
        Resolve-RulebookPublishTarget -Settings @{} | Should-Be 'pages'
    }

    It 'fails <Target> as not implemented with issue <Issue>' -ForEach @(
        @{ Target = 'dist-repo'; Issue = 55 }
        @{ Target = 'azure-blob'; Issue = 56 }
        @{ Target = 'gist'; Issue = 57 }
    ) {
        { Resolve-RulebookPublishTarget -Settings @{ publish = @{ target = $Target } } } | Should-Throw -ExceptionMessage "*'$Target' is not implemented yet*issues/$Issue*"
    }

    It 'fails an unknown target' {
        { Resolve-RulebookPublishTarget -Settings @{} -Override 'ftp' } | Should-Throw -ExceptionMessage "*Unknown publish target 'ftp'*"
    }
}

Describe 'ConvertTo-RulebookIndexHtml' {
    BeforeAll {
        $script:inputs = Read-RulebookInputs -RepositoryRoot $templateDir
        $script:endpoints = foreach ($level in $inputs.Levels) { foreach ($stage in $inputs.Stages) { Get-RulebookEndpoint -Inputs $inputs -Level $level.Slug -Stage $stage.Slug } }
        $script:html = ConvertTo-RulebookIndexHtml -Inputs $inputs -BaseUrl $baseUrl -Endpoints @($endpoints)
    }

    It 'shows every endpoint URL exactly once as link text, with its count of listed ids' {
        foreach ($endpoint in $endpoints) {
            $url = "$baseUrl/$($endpoint.File)"
            [regex]::Matches($html, '<code>' + [regex]::Escape($url) + '</code>').Count | Should-Be 1
            $html | Should-MatchString ('<code>' + [regex]::Escape($url) + '</code></a></td><td class="count">' + @($endpoint.Entries).Count + '</td>')
        }
    }

    It 'links every skeleton' {
        foreach ($level in $inputs.Levels) {
            foreach ($stage in $inputs.Stages) {
                $html | Should-MatchString ([regex]::Escape("href=`"$baseUrl/skeletons/$($level.Slug).$($stage.Slug).ruleset.json`""))
            }
        }
    }

    It 'has no script and declares UTF-8' {
        $html | Should-NotMatchString '<script'
        $html | Should-MatchString '<meta charset="utf-8">'
    }

    It 'has the AL project section before the stage tables, with the init script, the settings and the links' {
        $section = $html.IndexOf('<h2 id="al-project">Set up an AL project</h2>')
        $section | Should-BeGreaterThan $html.IndexOf('</dl>')
        $section | Should-BeLessThan $html.IndexOf('<h2 id="stage-default">')
        $html | Should-MatchString ([regex]::Escape('<pre><code>Invoke-WebRequest https://raw.githubusercontent.com/ALCops/rulebook-engine/main/scripts/Get-RulebookSkeletons.ps1 -OutFile Get-RulebookSkeletons.ps1'))
        $html | Should-MatchString ([regex]::Escape("./Get-RulebookSkeletons.ps1 -BaseUrl $baseUrl -Level essential -Ref main</code></pre>"))
        $html | Should-MatchString ([regex]::Escape('<code>"al.ruleSetPath": ".rulebook/default.ruleset.json"</code>'))
        $html | Should-MatchString ([regex]::Escape('<code>"rulesetFile": ".rulebook/ci.ruleset.json"</code>'))
        $html | Should-MatchString ([regex]::Escape('<a href="https://github.com/ALCops/rulebook/blob/main/docs/al-project.md">'))
        $html | Should-MatchString ([regex]::Escape("<a href=`"$baseUrl/rulebook.json`"><code>$baseUrl/rulebook.json</code></a>"))
    }

    It 'names the init script and the user page on the branch Publish runs from (GITHUB_ACTION_REF v1)' {
        $saved = $env:GITHUB_ACTION_REF
        try {
            $env:GITHUB_ACTION_REF = 'v1'
            $v1Html = ConvertTo-RulebookIndexHtml -Inputs $inputs -BaseUrl $baseUrl -Endpoints @($endpoints)
        } finally {
            $env:GITHUB_ACTION_REF = $saved
        }
        $v1Html | Should-MatchString ([regex]::Escape('<pre><code>Invoke-WebRequest https://raw.githubusercontent.com/ALCops/rulebook-engine/v1/scripts/Get-RulebookSkeletons.ps1 -OutFile Get-RulebookSkeletons.ps1'))
        $v1Html | Should-MatchString ([regex]::Escape("./Get-RulebookSkeletons.ps1 -BaseUrl $baseUrl -Level essential -Ref v1</code></pre>"))
        $v1Html | Should-MatchString ([regex]::Escape('<a href="https://github.com/ALCops/rulebook/blob/v1/docs/al-project.md">'))
    }

    It 'encodes the base URL and the level in the AL project section' {
        $custom = Read-RulebookInputs -RepositoryRoot $templateDir
        $page = ConvertTo-RulebookIndexHtml -Inputs $custom -BaseUrl 'https://contoso.github.io/a&b' -Endpoints @($endpoints)
        $page | Should-MatchString ([regex]::Escape('-BaseUrl https://contoso.github.io/a&amp;b -Level essential'))
        $page | Should-MatchString ([regex]::Escape('href="https://contoso.github.io/a&amp;b/rulebook.json"'))
        $page.Contains('a&b') | Should-BeFalse
    }

    It 'encodes text and keeps a custom level and stage in settings order' {
        $root = New-FixtureRepo -Name 'custom-level' -Destination (Get-TestFolder)
        Edit-FixtureJson -Path (Join-Path $root '.github' 'Rulebook-Settings.json') -Script {
            $_.levels[2].description = 'House <rules> & more'
            $_.stages = @($_.stages[0], @{ name = 'Nightly'; description = 'Nightly "builds"' }, $_.stages[1], $_.stages[2])
        }
        Copy-Item -LiteralPath (Join-Path $root 'stages' 'ci.json') -Destination (Join-Path $root 'stages' 'nightly.json')
        $custom = Read-RulebookInputs -RepositoryRoot $root
        $list = foreach ($level in $custom.Levels) { foreach ($stage in $custom.Stages) { Get-RulebookEndpoint -Inputs $custom -Level $level.Slug -Stage $stage.Slug } }
        $page = ConvertTo-RulebookIndexHtml -Inputs $custom -BaseUrl $baseUrl -Endpoints @($list)
        $page | Should-MatchString ([regex]::Escape('House &lt;rules&gt; &amp; more'))
        $page | Should-MatchString ([regex]::Escape('Nightly &quot;builds&quot;'))
        $page.Contains('<rules>') | Should-BeFalse
        $stages = @([regex]::Matches($page, '<h2 id="stage-([a-z0-9-]+)">') | ForEach-Object { $_.Groups[1].Value })
        $stages | Should-BeCollection @('default', 'nightly', 'ci', 'vnext')
        $rows = @([regex]::Matches($page, '<tr><td>([^<]+)</td><td><a href="[^"]+/rulesets/[a-z-]+\.nightly\.ruleset\.json"') | ForEach-Object { $_.Groups[1].Value })
        $rows | Should-BeCollection @('Essential', 'Recommended', 'Custom', 'Strict', 'Complete')
    }
}

Describe 'ConvertTo-RulebookManifestJson' {
    BeforeAll {
        $script:inputs = Read-RulebookInputs -RepositoryRoot $templateDir
        $script:pinned = [datetime]::new(2026, 10, 6, 12, 0, 0, [System.DateTimeKind]::Utc)
    }

    It 'writes the same bytes for the same inputs and time' {
        $first = ConvertTo-RulebookManifestJson -Inputs $inputs -BaseUrl $baseUrl -Repository 'Contoso/Rulebook' -GeneratedAt $pinned
        $second = ConvertTo-RulebookManifestJson -Inputs $inputs -BaseUrl $baseUrl -Repository 'Contoso/Rulebook' -GeneratedAt $pinned
        $second | Should-Be $first
        $lines = $first.Split("`n")
        $lines[0..3] | Should-BeCollection @('{', '  "generatedAt": "2026-10-06T12:00:00Z",', '  "repository": "Contoso/Rulebook",', "  `"baseUrl`": `"$baseUrl`",")
        $lines | Should-ContainCollection @('    { "name": "Recommended", "slug": "recommended", "basedOn": "essential", "description": "Every default-on rule at its author severity; marketplace checks join here." },')
        $first.EndsWith("}`n") | Should-BeTrue
        $first.Contains("`r") | Should-BeFalse
        $first.Contains("`n`n") | Should-BeFalse
        $utf8.GetBytes($first)[0] | Should-Be ([byte][char]'{')
    }

    It 'writes generatedAt in UTC and leaves out an empty repository' {
        $local = [datetime]::new(2026, 10, 6, 14, 30, 5, [System.DateTimeKind]::Utc).ToLocalTime()
        $text = ConvertTo-RulebookManifestJson -Inputs $inputs -BaseUrl $baseUrl -Repository '' -GeneratedAt $local
        $json = $text | ConvertFrom-Json -AsHashtable
        $text | Should-MatchString '(?m)^  "generatedAt": "2026-10-06T14:30:05Z",$'
        $json.Contains('repository') | Should-BeFalse
    }

    It 'escapes quotes and backslashes and keeps a custom level and stage in settings order' {
        $root = New-FixtureRepo -Name 'custom-level' -Destination (Get-TestFolder)
        Edit-FixtureJson -Path (Join-Path $root '.github' 'Rulebook-Settings.json') -Script {
            $_.levels[2].description = 'House "rules" in C:\rules & <more>'
            $_.stages = @($_.stages[0], @{ name = 'Nightly' }, $_.stages[1], $_.stages[2])
        }
        Copy-Item -LiteralPath (Join-Path $root 'stages' 'ci.json') -Destination (Join-Path $root 'stages' 'nightly.json')
        $custom = Read-RulebookInputs -RepositoryRoot $root
        $text = ConvertTo-RulebookManifestJson -Inputs $custom -BaseUrl $baseUrl -GeneratedAt $pinned
        $text | Should-MatchString ([regex]::Escape('"description": "House \"rules\" in C:\\rules & <more>"'))
        $json = $text | ConvertFrom-Json -AsHashtable
        $json['levels'][2]['description'] | Should-Be 'House "rules" in C:\rules & <more>'
        @($json['levels'] | ForEach-Object { $_['slug'] }) | Should-BeCollection @('essential', 'recommended', 'custom', 'strict', 'complete')
        @($json['stages'] | ForEach-Object { $_['slug'] }) | Should-BeCollection @('default', 'nightly', 'ci', 'vnext')
        $json['stages'][1].Contains('description') | Should-BeFalse
    }
}

Describe 'Test-RulebookEndpoints' {
    BeforeAll {
        $script:bodies = [ordered]@{
            'rulesets/strict.ruleset.json'           = "{`n  `"name`": `"Rulebook Strict / default`",`n  `"rules`": []`n}`n"
            'rulesets/strict.ci.ruleset.json'        = "{`n  `"name`": `"Rulebook Strict / CI`",`n  `"rules`": []`n}`n"
            'skeletons/strict.ci.ruleset.json'       = "{ `"name`": `"skeleton`" }`n"
            'rulebook.json'                          = "{`n  `"baseUrl`": `"https://contoso.github.io/rulebook`"`n}`n"
            'index.html'                             = "<html></html>`n"
        }
    }

    BeforeEach {
        $script:served = @{}
        foreach ($path in $bodies.Keys) { $script:served["$baseUrl/$path"] = $bodies[$path] }
        $script:calls = @{}
        Mock Start-Sleep -ModuleName Rulebook.Publish { }
        Mock Invoke-WebRequest -ModuleName Rulebook.Publish {
            $script:calls[$Uri] = 1 + $(if ($script:calls.ContainsKey($Uri)) { $script:calls[$Uri] } else { 0 })
            $body = $script:served[[string]$Uri]
            if ($body -is [scriptblock]) { $body = & $body $script:calls[$Uri] }
            if ($null -eq $body) { return [pscustomobject]@{ StatusCode = 404; Content = 'Not Found' } }
            if ($body -is [System.Exception]) { throw $body }
            return [pscustomobject]@{ StatusCode = 200; Content = $body }
        }
    }

    It 'passes every endpoint, skeleton, rulebook.json and index.html on the first pass' {
        $results = @(Test-RulebookEndpoints -Manifest @(New-TestManifest -Bodies $bodies))
        $results.Count | Should-Be 5
        @($results | Where-Object Reason -NE 'ok').Count | Should-Be 0
        @($results | ForEach-Object Attempts) | Should-BeCollection @(1, 1, 1, 1, 1)
        ($results | Where-Object Kind -EQ 'index').Url | Should-Be "$baseUrl/index.html"
        ($results | Where-Object Kind -EQ 'manifest').Url | Should-Be "$baseUrl/rulebook.json"
        $results[0].Status | Should-Be 200
        Should-Invoke Start-Sleep -ModuleName Rulebook.Publish -Times 0 -Exactly
    }

    It 'skips an entry of another kind' {
        $manifest = @(New-TestManifest -Bodies $bodies) + [pscustomobject]@{ Path = 'notes.txt'; Url = "$baseUrl/notes.txt"; Kind = 'other'; StagedFile = (Join-Path $TestDrive 'notes.txt') }
        @(Test-RulebookEndpoints -Manifest $manifest -WindowSeconds 0).Count | Should-Be 5
        Should-Invoke Invoke-WebRequest -ModuleName Rulebook.Publish -Times 0 -Exactly -ParameterFilter { $Uri -eq "$baseUrl/notes.txt" }
    }

    It 'reports an endpoint that stays 404 as missing and names its URL' {
        $script:served.Remove("$baseUrl/rulesets/strict.ci.ruleset.json")
        $results = @(Test-RulebookEndpoints -Manifest @(New-TestManifest -Bodies $bodies) -WindowSeconds 90 -IntervalSeconds 30)
        $failed = @($results | Where-Object Reason -NE 'ok')
        $failed.Count | Should-Be 1
        $failed[0].Url | Should-Be "$baseUrl/rulesets/strict.ci.ruleset.json"
        $failed[0].Reason | Should-Be 'missing'
        $failed[0].Status | Should-Be 404
        $failed[0].Attempts | Should-Be 4
        Should-Invoke Start-Sleep -ModuleName Rulebook.Publish -Times 3 -Exactly
    }

    It 'reports a body that differs from the staged file as different' {
        $script:served["$baseUrl/rulesets/strict.ruleset.json"] = "{`n  `"name`": `"Rulebook Strict / default`",`n  `"rules`": [ { `"id`": `"AA0001`", `"action`": `"None`" } ]`n}`n"
        $results = @(Test-RulebookEndpoints -Manifest @(New-TestManifest -Bodies $bodies) -WindowSeconds 0)
        ($results | Where-Object Path -EQ 'rulesets/strict.ruleset.json').Reason | Should-Be 'different'
        ($results | Where-Object Path -EQ 'rulesets/strict.ruleset.json').Attempts | Should-Be 1
    }

    It 'compares a CRLF body as different (LF is preserved)' {
        $script:served["$baseUrl/rulesets/strict.ruleset.json"] = $bodies['rulesets/strict.ruleset.json'].Replace("`n", "`r`n")
        $results = @(Test-RulebookEndpoints -Manifest @(New-TestManifest -Bodies $bodies) -WindowSeconds 0)
        ($results | Where-Object Path -EQ 'rulesets/strict.ruleset.json').Reason | Should-Be 'different'
    }

    It 'accepts a byte body' {
        $script:served["$baseUrl/rulesets/strict.ruleset.json"] = [byte[]]$utf8.GetBytes($bodies['rulesets/strict.ruleset.json'])
        $results = @(Test-RulebookEndpoints -Manifest @(New-TestManifest -Bodies $bodies) -WindowSeconds 0)
        ($results | Where-Object Path -EQ 'rulesets/strict.ruleset.json').Reason | Should-Be 'ok'
    }

    It 'passes a URL that serves the new body on the second attempt' {
        $old = "{ `"name`": `"old`" }`n"
        $new = $bodies['rulesets/strict.ci.ruleset.json']
        $script:served["$baseUrl/rulesets/strict.ci.ruleset.json"] = { param($attempt) if ($attempt -lt 2) { $old } else { $new } }.GetNewClosure()
        $results = @(Test-RulebookEndpoints -Manifest @(New-TestManifest -Bodies $bodies) -IntervalSeconds 30)
        @($results | Where-Object Reason -NE 'ok').Count | Should-Be 0
        ($results | Where-Object Path -EQ 'rulesets/strict.ci.ruleset.json').Attempts | Should-Be 2
        ($results | Where-Object Path -EQ 'rulesets/strict.ruleset.json').Attempts | Should-Be 1
        Should-Invoke Start-Sleep -ModuleName Rulebook.Publish -Times 1 -Exactly -ParameterFilter { $Seconds -eq 30 }
    }

    It 'classifies the exception by type: a timeout, a cancellation and a connection failure' {
        # Invoke-WebRequest -TimeoutSec throws a TaskCanceledException whose inner exception is a TimeoutException.
        $script:served["$baseUrl/rulesets/strict.ruleset.json"] = [System.Threading.Tasks.TaskCanceledException]::new('The request was canceled due to the configured HttpClient.Timeout of 15 seconds elapsing.', [System.TimeoutException]::new('A task was canceled.'))
        $script:served["$baseUrl/rulesets/strict.ci.ruleset.json"] = [System.Net.Http.HttpRequestException]::new('No such host is known.')
        $script:served["$baseUrl/skeletons/strict.ci.ruleset.json"] = [System.Threading.Tasks.TaskCanceledException]::new('A timeout word in a plain cancellation')
        $results = @(Test-RulebookEndpoints -Manifest @(New-TestManifest -Bodies $bodies) -WindowSeconds 0)
        ($results | Where-Object Path -EQ 'rulesets/strict.ruleset.json').Reason | Should-Be 'timeout'
        ($results | Where-Object Path -EQ 'rulesets/strict.ruleset.json').Detail | Should-BeLikeString '*HttpClient.Timeout*'
        ($results | Where-Object Path -EQ 'rulesets/strict.ci.ruleset.json').Reason | Should-Be 'error'
        ($results | Where-Object Path -EQ 'rulesets/strict.ci.ruleset.json').Status | Should-Be 0
        ($results | Where-Object Path -EQ 'rulesets/strict.ci.ruleset.json').Detail | Should-Be 'No such host is known.'
        ($results | Where-Object Path -EQ 'skeletons/strict.ci.ruleset.json').Reason | Should-Be 'error'
    }

    It 'starts no request after the window once the first pass is done' {
        # rulesets/strict.ruleset.json takes 1.6 s and both endpoints stay 404: pass 1 takes them both, pass 2 starts
        # inside the 2 s window and its first request ends at 3.2 s, past window plus timeout (3 s), so the second
        # endpoint is not requested again.
        $script:served.Remove("$baseUrl/rulesets/strict.ruleset.json")
        $script:served.Remove("$baseUrl/rulesets/strict.ci.ruleset.json")
        $slow = "$baseUrl/rulesets/strict.ruleset.json"
        Mock Invoke-WebRequest -ModuleName Rulebook.Publish -ParameterFilter { $Uri -eq $slow } { [System.Threading.Thread]::Sleep(1600); [pscustomobject]@{ StatusCode = 404; Content = 'Not Found' } }
        $manifest = @(New-TestManifest -Bodies ([ordered]@{ 'rulesets/strict.ruleset.json' = 'a'; 'rulesets/strict.ci.ruleset.json' = 'b' }))
        $results = @(Test-RulebookEndpoints -Manifest $manifest -WindowSeconds 2 -IntervalSeconds 1 -TimeoutSeconds 1)
        ($results | Where-Object Path -EQ 'rulesets/strict.ruleset.json').Attempts | Should-Be 2
        ($results | Where-Object Path -EQ 'rulesets/strict.ci.ruleset.json').Attempts | Should-Be 1
        @($results | ForEach-Object Reason) | Should-BeCollection @('missing', 'missing')
    }

    It 'reports a redirect as redirect with its target and never follows it' {
        Mock Invoke-WebRequest -ModuleName Rulebook.Publish -ParameterFilter { $Uri -eq "$baseUrl/rulesets/strict.ruleset.json" } {
            $headers = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.IEnumerable[string]]]::new()
            $headers['Location'] = [string[]]@('https://rules.contoso.com/rulesets/strict.ruleset.json')
            [pscustomobject]@{ StatusCode = 301; Content = ''; Headers = $headers }
        }
        $results = @(Test-RulebookEndpoints -Manifest @(New-TestManifest -Bodies $bodies) -WindowSeconds 0)
        $redirect = $results | Where-Object Path -EQ 'rulesets/strict.ruleset.json'
        $redirect.Attempts | Should-Be 1
        $redirect.Reason | Should-Be 'redirect'
        $redirect.Status | Should-Be 301
        $redirect.Detail | Should-Be 'redirects to https://rules.contoso.com/rulesets/strict.ruleset.json'
        Should-Invoke Invoke-WebRequest -ModuleName Rulebook.Publish -Times 5 -Exactly -ParameterFilter { $MaximumRedirection -eq 0 }
    }

    It 'does not retry a redirect' {
        Mock Invoke-WebRequest -ModuleName Rulebook.Publish {
            $headers = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.IEnumerable[string]]]::new()
            $headers['Location'] = [string[]]@('https://rules.contoso.com/')
            [pscustomobject]@{ StatusCode = 301; Content = ''; Headers = $headers }
        }
        $results = @(Test-RulebookEndpoints -Manifest @(New-TestManifest -Bodies $bodies) -WindowSeconds 660 -IntervalSeconds 30)
        @($results | ForEach-Object Reason) | Should-BeCollection @('redirect', 'redirect', 'redirect', 'redirect', 'redirect')
        @($results | ForEach-Object Attempts) | Should-BeCollection @(1, 1, 1, 1, 1)
        Should-Invoke Start-Sleep -ModuleName Rulebook.Publish -Times 0 -Exactly
    }

    It 'runs the last pass that starts when the waits reach the window' {
        # Real waits: pass 1 at 0 s, pass 2 after 1 s, pass 3 after the wait that ends at the 2 s window.
        Mock Start-Sleep -ModuleName Rulebook.Publish { [System.Threading.Thread]::Sleep([int]($Seconds * 1000)) }
        $script:served.Remove("$baseUrl/rulesets/strict.ruleset.json")
        $results = @(Test-RulebookEndpoints -Manifest @(New-TestManifest -Bodies ([ordered]@{ 'rulesets/strict.ruleset.json' = 'a' })) -WindowSeconds 2 -IntervalSeconds 1)
        $results[0].Reason | Should-Be 'missing'
        $results[0].Attempts | Should-Be 3
        $results[0].Seconds | Should-BeGreaterThanOrEqual 2
    }

    It 'reports a staged file that cannot be read without requesting its URL' {
        $manifest = @(New-TestManifest -Bodies $bodies)
        $manifest[0].StagedFile = Join-Path $TestDrive 'gone' 'strict.ruleset.json'
        $results = @(Test-RulebookEndpoints -Manifest $manifest -WindowSeconds 0)
        $results[0].Reason | Should-Be 'error'
        $results[0].Attempts | Should-Be 0
        $results[0].Detail | Should-BeLikeString 'the staged file cannot be read*'
        @($results | Where-Object Reason -EQ 'ok').Count | Should-Be 4
        Should-Invoke Invoke-WebRequest -ModuleName Rulebook.Publish -Times 0 -Exactly -ParameterFilter { $Uri -eq "$baseUrl/rulesets/strict.ruleset.json" }
    }

    It 'requests with the compiler timeout of 15 s by default' {
        $null = Test-RulebookEndpoints -Manifest @(New-TestManifest -Bodies $bodies)
        Should-Invoke Invoke-WebRequest -ModuleName Rulebook.Publish -Times 5 -Exactly -ParameterFilter { $TimeoutSec -eq 15 -and $SkipHttpErrorCheck }
    }
}

Describe 'Invoke-PagesPreflight rate limit' {
    It 'reads X-RateLimit-Remaining 0 on a 403 as the rate limit' {
        # The header type of Invoke-WebRequest: a generic dictionary without a one-argument Contains.
        Mock Invoke-WebRequest -ModuleName Rulebook.Publish {
            $headers = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.IEnumerable[string]]]::new()
            $headers['x-ratelimit-remaining'] = [string[]]@('0')
            [pscustomobject]@{ StatusCode = 403; Content = '{"message":"Forbidden"}'; Headers = $headers }
        }
        $result = Invoke-PagesPreflight -Repository 'Contoso/Rulebook' -BaseUrl $baseUrl
        $result.Ok | Should-BeFalse
        $result.Message | Should-BeLikeString '*rate limit is exhausted*'
    }
}

Describe 'Invoke-PagesPreflight' {
    It 'calls GET /repos/{owner}/{repo}/pages with the token and maps the answer' {
        Mock Invoke-WebRequest -ModuleName Rulebook.Publish {
            $headers = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.IEnumerable[string]]]::new()
            $headers['X-RateLimit-Remaining'] = [string[]]@('4999')
            [pscustomobject]@{ StatusCode = 404; Content = [System.Text.Encoding]::UTF8.GetBytes('{"message":"Not Found","status":"404"}'); Headers = $headers }
        }
        $result = Invoke-PagesPreflight -Repository 'Contoso/Rulebook' -ApiUrl 'https://api.example.com/' -Token 'secret' -BaseUrl $baseUrl
        $result.Ok | Should-BeFalse
        $result.StatusCode | Should-Be 404
        $result.Message | Should-BeLikeString '*not enabled*'
        Should-Invoke Invoke-WebRequest -ModuleName Rulebook.Publish -Times 1 -Exactly -ParameterFilter {
            $Uri -eq 'https://api.example.com/repos/Contoso/Rulebook/pages' -and $Headers.Authorization -eq 'Bearer secret' -and $SkipHttpErrorCheck
        }
    }
}

Describe 'Get-PagesPreflightResult' {
    It 'accepts a workflow site at the base URL' {
        $result = Get-PagesPreflightResult -StatusCode 200 -Body '{"build_type":"workflow","html_url":"https://contoso.github.io/rulebook/"}' -BaseUrl $baseUrl
        $result.Ok | Should-BeTrue
        $result.Warning | Should-BeNull
    }

    It 'warns when the site is served elsewhere (custom domain)' {
        $result = Get-PagesPreflightResult -StatusCode 200 -Body '{"build_type":"workflow","html_url":"https://rules.contoso.com/"}' -BaseUrl $baseUrl
        $result.Ok | Should-BeTrue
        $result.Warning | Should-BeLikeString '*served at https://rules.contoso.com, but baseUrl is https://contoso.github.io/rulebook*custom domain*'
    }

    It 'maps <Name>' -ForEach @(
        @{ Name = 'a branch-built site'; Status = 200; Body = '{"build_type":"legacy","html_url":"https://contoso.github.io/rulebook/"}'; Message = "*build_type 'legacy'*Source to 'GitHub Actions'*https://github.com/Contoso/Rulebook/settings/pages*" }
        @{ Name = 'no site (404)'; Status = 404; Body = '{"message":"Not Found","status":"404"}'; Message = "*not enabled*Source 'GitHub Actions'*must be public*Pages creation*never creates*" }
        @{ Name = 'the plan gate'; Status = 422; Body = '{"message":"Your current plan does not support GitHub Pages for this repository.","status":"422"}'; Message = '*Make the repository public*upgrade*issues/55*' }
        @{ Name = 'the organization policy'; Status = 422; Body = '{"message":"GitHub organization administrators disabled Pages creation.","status":"422"}'; Message = '*organization administrator*Member privileges > Pages creation*' }
        @{ Name = 'an exhausted rate limit (message)'; Status = 403; Body = '{"message":"API rate limit exceeded for installation.","status":"403"}'; Message = '*rate limit is exhausted*again later*' }
        @{ Name = 'a secondary rate limit (429)'; Status = 429; Body = '{"message":"You have exceeded a secondary rate limit."}'; Message = '*rate limit is exhausted*' }
        @{ Name = 'a token without pages permission'; Status = 403; Body = '{"message":"Resource not accessible by integration","status":"403"}'; Message = "*pages: write*id-token: write*" }
        @{ Name = 'any other status'; Status = 500; Body = 'oops'; Message = '*HTTP 500*' }
    ) {
        $result = Get-PagesPreflightResult -StatusCode $Status -Body $Body -BaseUrl $baseUrl -Repository 'Contoso/Rulebook'
        $result.Ok | Should-BeFalse
        $result.Message | Should-BeLikeString $Message
    }
}
