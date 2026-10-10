# Init script suite for WP06 (#8): scripts/Get-RulebookSkeletons.ps1 run in-process against a site staged by
# New-RulebookPublishStage from a copy of template/. Invoke-WebRequest is mocked without -ModuleName: the script is
# invoked with & from this file, so it resolves the command in this session state and finds the mock. The real HTTP
# path is exercised by the publish-action job in ci.yml, which serves the staged site with python3 -m http.server.

BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:entry = Join-Path $script:repoRoot 'scripts' 'Get-RulebookSkeletons.ps1'
    . (Join-Path $PSScriptRoot 'Helpers' 'RepoFixture.ps1')
    Import-Module (Join-Path $script:repoRoot 'modules' 'Rulebook.Generate.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'modules' 'Rulebook.Publish.psd1') -Force
    $script:baseUrl = 'https://contoso.github.io/rulebook'
    $script:utf8 = [System.Text.UTF8Encoding]::new($false)

    function Get-TestFolder {
        return Join-Path $TestDrive ([guid]::NewGuid().ToString('n').Substring(0, 12))
    }

    # The served site: every staged file by its URL, as bytes.
    $template = Get-TestFolder
    Copy-FixtureTree -Source (Join-Path $script:repoRoot 'template') -Destination $template
    $script:stage = Get-TestFolder
    $script:served = @{}
    foreach ($item in New-RulebookPublishStage -RepositoryRoot $template -BaseUrl $script:baseUrl -OutputPath $script:stage -Repository 'Contoso/Rulebook') {
        $script:served[$item.Url] = [System.IO.File]::ReadAllBytes($item.StagedFile)
    }

    function Invoke-Script {
        # Runs the script in-process; returns the result objects, the console lines and the warnings. Throws what
        # the script throws.
        param([hashtable]$Parameters)
        $output = @(& $script:entry @Parameters 6>&1 3>&1)
        return [pscustomobject]@{
            Result   = @($output | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] -and $_ -isnot [System.Management.Automation.WarningRecord] })
            Lines    = @($output | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { [string]$_.MessageData })
            Warnings = @($output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { [string]$_.Message })
        }
    }

    function Get-StagedContent {
        param([string]$Path)
        return [System.IO.File]::ReadAllBytes((Join-Path $script:stage $Path))
    }

    function Test-SameContent {
        param([byte[]]$Left, [byte[]]$Right)
        return [System.Linq.Enumerable]::SequenceEqual($Left, $Right)
    }
}

AfterAll {
    Remove-Module Rulebook.Publish, Rulebook.Generate, Rulebook.Common -ErrorAction SilentlyContinue
}

Describe 'Get-RulebookSkeletons.ps1' {
    BeforeEach {
        # A copy per test, so a test can remove or replace a URL.
        $script:siteResponses = @{}
        foreach ($url in $script:served.Keys) { $script:siteResponses[$url] = $script:served[$url] }
        # The mock body runs while the script runs, so $script: inside it is the script's own scope; it reads
        # $siteResponses unqualified, which dynamic scoping resolves to this file's variable (the script has none).
        Mock Invoke-WebRequest {
            $body = $siteResponses[[string]$Uri]
            if ($body -is [scriptblock]) { return & $body }
            if ($null -eq $body) { return [pscustomobject]@{ StatusCode = 404; Content = [byte[]][System.Text.Encoding]::UTF8.GetBytes('Not Found') } }
            return [pscustomobject]@{ StatusCode = 200; Content = [byte[]]$body }
        }
    }

    It 'reaches the mock from a script invoked with &' {
        $null = Invoke-Script @{ BaseUrl = $baseUrl; Level = 'strict'; OutputPath = (Get-TestFolder) }
        Should-Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { [string]$Uri -eq "$baseUrl/rulebook.json" }
    }

    It 'writes one file per stage with the bytes of the published skeleton' {
        $folder = Get-TestFolder
        $null = Invoke-Script @{ BaseUrl = $baseUrl; Level = 'strict'; OutputPath = $folder }
        $names = @(Get-ChildItem -LiteralPath $folder -File | ForEach-Object Name)
        [System.Array]::Sort($names, [System.StringComparer]::Ordinal)
        $names | Should-BeCollection @('ci.ruleset.json', 'default.ruleset.json', 'vnext.ruleset.json')
        foreach ($stage in 'default', 'ci', 'vnext') {
            $written = [System.IO.File]::ReadAllBytes((Join-Path $folder "$stage.ruleset.json"))
            Test-SameContent $written (Get-StagedContent "skeletons/strict.$stage.ruleset.json") | Should-BeTrue -Because $stage
            $include = (ConvertFrom-Json -InputObject $utf8.GetString($written)).includedRuleSets[0].path
            $include | Should-BeLikeString "$baseUrl/rulesets/strict*"
        }
        ((ConvertFrom-Json -InputObject $utf8.GetString([System.IO.File]::ReadAllBytes((Join-Path $folder 'ci.ruleset.json')))).includedRuleSets[0].path) | Should-Be "$baseUrl/rulesets/strict.ci.ruleset.json"
    }

    It 'resolves the level <Level> by slug or name and accepts a trailing slash on the base URL' -ForEach @(
        @{ Level = 'Strict'; Base = 'https://contoso.github.io/rulebook' }
        @{ Level = 'STRICT'; Base = 'https://contoso.github.io/rulebook' }
        @{ Level = 'strict'; Base = 'https://contoso.github.io/rulebook/' }
    ) {
        $folder = Get-TestFolder
        $run = Invoke-Script @{ BaseUrl = $Base; Level = $Level; OutputPath = $folder }
        @($run.Result | ForEach-Object Url) | Should-BeCollection @("$baseUrl/skeletons/strict.default.ruleset.json", "$baseUrl/skeletons/strict.ci.ruleset.json", "$baseUrl/skeletons/strict.vnext.ruleset.json")
        $run.Warnings | Should-BeCollection @()
    }

    It 'rejects a level the site does not publish before any skeleton request' {
        $folder = Get-TestFolder
        { Invoke-Script @{ BaseUrl = $baseUrl; Level = 'paranoid'; OutputPath = $folder } } | Should-Throw -ExceptionMessage "Level 'paranoid' is not published at $baseUrl. Published levels: essential, recommended, strict, complete (use the slug or the name)."
        Should-Invoke Invoke-WebRequest -Times 1 -Exactly
        Should-Invoke Invoke-WebRequest -Times 0 -Exactly -ParameterFilter { [string]$Uri -like '*/skeletons/*' }
        Test-Path -LiteralPath $folder | Should-BeFalse
    }

    It 'explains a missing rulebook.json and requests no skeleton' {
        $script:siteResponses.Remove("$baseUrl/rulebook.json")
        { Invoke-Script @{ BaseUrl = $baseUrl; Level = 'strict'; OutputPath = (Get-TestFolder) } } | Should-Throw -ExceptionMessage "$baseUrl/rulebook.json is missing*Publish workflow*"
        Should-Invoke Invoke-WebRequest -Times 0 -Exactly -ParameterFilter { [string]$Uri -like '*/skeletons/*' }
    }

    It 'refuses a redirect of the manifest and names its target' {
        $script:siteResponses["$baseUrl/rulebook.json"] = {
            $headers = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.IEnumerable[string]]]::new()
            $headers['Location'] = [string[]]@('https://rules.contoso.com/rulebook.json')
            [pscustomobject]@{ StatusCode = 301; Content = ''; Headers = $headers }
        }
        { Invoke-Script @{ BaseUrl = $baseUrl; Level = 'strict'; OutputPath = (Get-TestFolder) } } | Should-Throw -ExceptionMessage '*redirect (HTTP 301) to https://rules.contoso.com/rulebook.json*does not follow redirects*'
        Should-Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $MaximumRedirection -eq 0 -and $SkipHttpErrorCheck -and $TimeoutSec -eq 15 }
    }

    It 'refuses to overwrite an existing file without -Force and overwrites all with it' {
        $folder = Get-TestFolder
        $existing = Join-Path $folder 'ci.ruleset.json'
        Write-FixtureText -Path $existing -Text '{ "name": "mine", "rules": [ { "id": "AA0137", "action": "None" } ] }'
        $before = [System.IO.File]::ReadAllBytes($existing)
        { Invoke-Script @{ BaseUrl = $baseUrl; Level = 'strict'; OutputPath = $folder } } | Should-Throw -ExceptionMessage '*ci.ruleset.json*Use -Force*project exceptions*'
        Test-SameContent ([System.IO.File]::ReadAllBytes($existing)) $before | Should-BeTrue
        @(Get-ChildItem -LiteralPath $folder -File).Count | Should-Be 1
        Should-Invoke Invoke-WebRequest -Times 0 -Exactly -ParameterFilter { [string]$Uri -like '*/skeletons/*' }
        $null = Invoke-Script @{ BaseUrl = $baseUrl; Level = 'strict'; OutputPath = $folder; Force = $true }
        @(Get-ChildItem -LiteralPath $folder -File).Count | Should-Be 3
        Test-SameContent ([System.IO.File]::ReadAllBytes($existing)) (Get-StagedContent 'skeletons/strict.ci.ruleset.json') | Should-BeTrue
    }

    It 'writes nothing when one skeleton is missing' {
        $script:siteResponses.Remove("$baseUrl/skeletons/strict.vnext.ruleset.json")
        $folder = Get-TestFolder
        { Invoke-Script @{ BaseUrl = $baseUrl; Level = 'strict'; OutputPath = $folder } } | Should-Throw -ExceptionMessage "Nothing was written. $baseUrl/skeletons/strict.vnext.ruleset.json answers with HTTP 404."
        Test-Path -LiteralPath $folder | Should-BeFalse
    }

    It 'writes the bytes as served: byte order mark, CRLF and non-ASCII text included' {
        $script:siteResponses["$baseUrl/rulebook.json"] = $utf8.GetBytes('{ "baseUrl": "' + $baseUrl + '", "levels": [ { "name": "Strict", "slug": "strict" } ], "stages": [ { "name": "default", "slug": "default" } ], "rules": [] }')
        $name = 'Rulebook Stra' + [char]0x00DF + 'e / default'
        $text = "{`r`n  `"name`": `"$name`",`r`n  `"includedRuleSets`": [ { `"action`": `"Default`", `"path`": `"$baseUrl/rulesets/strict.ruleset.json`" } ],`r`n  `"rules`": []`r`n}`r`n"
        [byte[]]$body = [byte[]](0xEF, 0xBB, 0xBF) + $utf8.GetBytes($text)
        $script:siteResponses["$baseUrl/skeletons/strict.default.ruleset.json"] = $body
        $folder = Get-TestFolder
        $run = Invoke-Script @{ BaseUrl = $baseUrl; Level = 'strict'; OutputPath = $folder }
        Test-SameContent ([System.IO.File]::ReadAllBytes((Join-Path $folder 'default.ruleset.json'))) $body | Should-BeTrue
        $run.Result[0].Bytes | Should-Be $body.Length
    }

    It 'warns when the site was published with another baseUrl and still writes the files' {
        $folder = Get-TestFolder
        $local = 'http://127.0.0.1:8787'
        foreach ($url in @($script:served.Keys)) { $script:siteResponses[$url.Replace($baseUrl, $local)] = $script:served[$url] }
        $run = Invoke-Script @{ BaseUrl = $local; Level = 'strict'; OutputPath = $folder }
        $run.Warnings.Count | Should-Be 3
        $run.Warnings[0] | Should-BeLikeString "*published with baseUrl $baseUrl, not $local*compiler will fetch $baseUrl/rulesets/strict.ruleset.json*"
        @(Get-ChildItem -LiteralPath $folder -File).Count | Should-Be 3
    }

    It 'prints the settings relative to the current folder, run from the AL project root <Name>' -ForEach @(
        @{ Name = 'MyApp with the default output'; OutputPath = $null; Setting = '.rulebook/default.ruleset.json' }
        @{ Name = 'MyApp with -OutputPath .'; OutputPath = '.'; Setting = 'default.ruleset.json' }
        @{ Name = 'MyApp with -OutputPath tools/.rulebook'; OutputPath = 'tools/.rulebook'; Setting = 'tools/.rulebook/default.ruleset.json' }
    ) {
        $project = Join-Path (Get-TestFolder) 'MyApp'
        [void](New-Item -ItemType Directory -Path $project)
        $parameters = @{ BaseUrl = $baseUrl; Level = 'strict' }
        if ($OutputPath) { $parameters.OutputPath = $OutputPath }
        Push-Location -LiteralPath $project
        try {
            $run = Invoke-Script $parameters
        } finally {
            Pop-Location
        }
        $text = $run.Lines -join "`n"
        $text | Should-MatchString ([regex]::Escape('Settings paths are relative to the current folder; run the script from the AL project root (the folder with app.json).'))
        $text | Should-MatchString ([regex]::Escape("`"al.ruleSetPath`": `"$Setting`""))
        $text | Should-NotMatchString '\\'
        @(Get-ChildItem -LiteralPath $project -Recurse -Filter '*.tmp').Count | Should-Be 0
    }

    It 'names the URL when the connection fails' {
        $script:siteResponses["$baseUrl/rulebook.json"] = { throw [System.Net.Http.HttpRequestException]::new('No connection could be made because the target machine actively refused it.') }
        { Invoke-Script @{ BaseUrl = $baseUrl; Level = 'strict'; OutputPath = (Get-TestFolder) } } | Should-Throw -ExceptionMessage "Cannot read $baseUrl/rulebook.json: No connection could be made*"
    }

    It 'refuses a skeleton whose include is not the endpoint of its level and stage' {
        $text = $utf8.GetString($script:served["$baseUrl/skeletons/strict.ci.ruleset.json"]).Replace('rulesets/strict.ci.ruleset.json', 'rulesets/recommended.ci.ruleset.json')
        $script:siteResponses["$baseUrl/skeletons/strict.ci.ruleset.json"] = $utf8.GetBytes($text)
        $folder = Get-TestFolder
        { Invoke-Script @{ BaseUrl = $baseUrl; Level = 'strict'; OutputPath = $folder } } | Should-Throw -ExceptionMessage "Nothing was written. $baseUrl/skeletons/strict.ci.ruleset.json includes $baseUrl/rulesets/recommended.ci.ruleset.json, but the skeleton of level strict and stage ci must include $baseUrl/rulesets/strict.ci.ruleset.json*wrong or stale*"
        Test-Path -LiteralPath $folder | Should-BeFalse
    }

    It 'compares the scheme and host of the base URL case-insensitively and does not warn' {
        $run = Invoke-Script @{ BaseUrl = 'HTTPS://Contoso.GitHub.io/rulebook'; Level = 'strict'; OutputPath = (Get-TestFolder) }
        $run.Warnings | Should-BeCollection @()
        $run.Result.Count | Should-Be 3
    }

    It 'still warns when the path of the base URL differs in case' {
        $local = 'https://contoso.github.io/Rulebook'
        foreach ($url in @($script:served.Keys)) { $script:siteResponses[$url.Replace($baseUrl, $local)] = $script:served[$url] }
        $run = Invoke-Script @{ BaseUrl = $local; Level = 'strict'; OutputPath = (Get-TestFolder) }
        $run.Warnings.Count | Should-Be 3
    }

    It 'refuses with -Force a target that is <Name> before writing any file' -ForEach @(
        @{ Name = 'a folder'; Message = '*No file was written.*ci.ruleset.json is a folder, not a file.' }
        @{ Name = 'read-only'; Message = '*No file was written.*ci.ruleset.json is read-only.' }
    ) {
        $folder = Get-TestFolder
        $target = Join-Path $folder 'ci.ruleset.json'
        if ($Name -eq 'a folder') {
            [void](New-Item -ItemType Directory -Path $target -Force)
        } else {
            Write-FixtureText -Path $target -Text '{}'
            (Get-Item -LiteralPath $target).IsReadOnly = $true
        }
        try {
            { Invoke-Script @{ BaseUrl = $baseUrl; Level = 'strict'; OutputPath = $folder; Force = $true } } | Should-Throw -ExceptionMessage $Message
            Test-Path -LiteralPath (Join-Path $folder 'default.ruleset.json') | Should-BeFalse
        } finally {
            if ($Name -eq 'read-only') { (Get-Item -LiteralPath $target).IsReadOnly = $false }
        }
    }

    It 'refuses an include that points at another site' {
        $text = $utf8.GetString($script:served["$baseUrl/skeletons/strict.ci.ruleset.json"]).Replace("$baseUrl/rulesets/", 'https://elsewhere.example.com/rulesets/')
        $script:siteResponses["$baseUrl/skeletons/strict.ci.ruleset.json"] = $utf8.GetBytes($text)
        $folder = Get-TestFolder
        { Invoke-Script @{ BaseUrl = $baseUrl; Level = 'strict'; OutputPath = $folder } } | Should-Throw -ExceptionMessage "Nothing was written. $baseUrl/skeletons/strict.ci.ruleset.json includes https://elsewhere.example.com/rulesets/strict.ci.ruleset.json, which points at another site than $baseUrl; the skeleton was not written."
        Test-Path -LiteralPath $folder | Should-BeFalse
    }

    It 'accepts the include Get-EndpointFileName of the engine names, for every level and stage of the template' {
        # The script keeps its own copy of the endpoint name rule; this pins it to Rulebook.Generate.
        $inputs = Read-RulebookInputs -RepositoryRoot (Join-Path $repoRoot 'template')
        foreach ($level in $inputs.Levels) {
            foreach ($stage in $inputs.Stages) {
                $endpoint = "$baseUrl/rulesets/$(Get-EndpointFileName -Level $level.Slug -Stage $stage.Slug)"
                $body = "{ `"name`": `"x`", `"includedRuleSets`": [ { `"action`": `"Default`", `"path`": `"$endpoint`" } ], `"rules`": [] }`n"
                $script:siteResponses["$baseUrl/skeletons/$($level.Slug).$($stage.Slug).ruleset.json"] = $utf8.GetBytes($body)
            }
            $run = Invoke-Script @{ BaseUrl = $baseUrl; Level = $level.Slug; OutputPath = (Get-TestFolder) }
            $run.Result.Count | Should-Be $inputs.Stages.Count -Because $level.Slug
        }
    }

    It 'refuses a manifest whose <Name>' -ForEach @(
        @{ Name = 'stage slug is a path'; Json = '{ "levels": [ { "name": "Strict", "slug": "strict" } ], "stages": [ { "name": "x", "slug": "../x" } ] }'; Message = "*is not a Rulebook manifest: 'stages' has the slug '../x'*" }
        @{ Name = 'levels are missing'; Json = '{ "stages": [ { "name": "default", "slug": "default" } ] }'; Message = "*is not a Rulebook manifest: 'levels' is missing*" }
        @{ Name = 'entry has no slug'; Json = '{ "levels": [ { "name": "Strict" } ], "stages": [ { "name": "default", "slug": "default" } ] }'; Message = "*is not a Rulebook manifest: every entry of 'levels' needs a name and a slug*" }
        @{ Name = 'body is not JSON'; Json = '<html></html>'; Message = '*is not a Rulebook manifest*' }
    ) {
        $script:siteResponses["$baseUrl/rulebook.json"] = $utf8.GetBytes($Json)
        $folder = Get-TestFolder
        { Invoke-Script @{ BaseUrl = $baseUrl; Level = 'strict'; OutputPath = $folder } } | Should-Throw -ExceptionMessage $Message
        Test-Path -LiteralPath $folder | Should-BeFalse
        Should-Invoke Invoke-WebRequest -Times 0 -Exactly -ParameterFilter { [string]$Uri -like '*/skeletons/*' }
    }

    It 'writes .rulebook/ in the current location by default and prints the settings for each stage' {
        $project = Get-TestFolder
        [void](New-Item -ItemType Directory -Path $project)
        Push-Location -LiteralPath $project
        try {
            $run = Invoke-Script @{ BaseUrl = $baseUrl; Level = 'recommended' }
        } finally {
            Pop-Location
        }
        foreach ($stage in 'default', 'ci', 'vnext') { Test-Path -LiteralPath (Join-Path $project '.rulebook' "$stage.ruleset.json") -PathType Leaf | Should-BeTrue }
        @($run.Result | ForEach-Object Stage) | Should-BeCollection @('default', 'ci', 'vnext')
        $run.Result[1].File | Should-Be (Join-Path $project '.rulebook' 'ci.ruleset.json')
        $run.Result[1].Url | Should-Be "$baseUrl/skeletons/recommended.ci.ruleset.json"
        $text = $run.Lines -join "`n"
        $text | Should-MatchString ([regex]::Escape(".rulebook/ci.ruleset.json <- $baseUrl/skeletons/recommended.ci.ruleset.json"))
        $text | Should-MatchString ([regex]::Escape('"al.ruleSetPath": ".rulebook/default.ruleset.json"'))
        $text | Should-MatchString ([regex]::Escape('"rulesetFile": ".rulebook/ci.ruleset.json", "enableExternalRulesets": true'))
        $text | Should-MatchString ([regex]::Escape('.github/NextMajor.settings.json: "rulesetFile": ".rulebook/vnext.ruleset.json"'))
        $text | Should-MatchString ([regex]::Escape('https://github.com/ALCops/rulebook/blob/v1/docs/al-project.md'))
    }

    It 'links the user page on the -Ref branch' {
        $run = Invoke-Script @{ BaseUrl = $baseUrl; Level = 'strict'; OutputPath = (Get-TestFolder); Ref = 'v2' }
        $text = $run.Lines -join "`n"
        $text | Should-MatchString ([regex]::Escape('https://github.com/ALCops/rulebook/blob/v2/docs/al-project.md'))
        $text | Should-NotMatchString ([regex]::Escape('/blob/v1/'))
    }

    It 'defaults -Ref to the major of the top heading of RELEASENOTES.md' {
        # The default is the literal current major (D52), raised by hand at a major: this guard fails until it is.
        $heading = @(Get-Content -LiteralPath (Join-Path $script:repoRoot 'RELEASENOTES.md') | Where-Object { $_ -like '## *' })[0]
        $heading | Should-MatchString '^## v(\d+)\.\d+\.\d+'
        $null = $heading -match '^## v(\d+)\.'
        $major = 'v' + $Matches[1]
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:entry, [ref]$tokens, [ref]$parseErrors)
        $parameter = @($ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Ref' })
        $parameter.Count | Should-Be 1
        $parameter[0].DefaultValue.Value | Should-Be $major
    }

    It 'accepts http for the loopback host <Value>' -ForEach @(
        @{ Value = 'http://127.0.0.1:8787' }
        @{ Value = 'http://localhost:8787/site' }
        @{ Value = 'http://[::1]:8787' }
    ) {
        foreach ($url in @($script:served.Keys)) { $script:siteResponses[$url.Replace($baseUrl, $Value)] = $script:served[$url] }
        $run = Invoke-Script @{ BaseUrl = $Value; Level = 'strict'; OutputPath = (Get-TestFolder) }
        $run.Result.Count | Should-Be 3
    }

    It 'rejects the base URL <Value> before any request' -ForEach @(
        @{ Value = 'http://contoso.github.io/rulebook' }
        @{ Value = 'http://127.0.0.2/rulebook' }
        @{ Value = 'ftp://contoso.github.io/rulebook' }
        @{ Value = 'contoso.github.io/rulebook' }
        @{ Value = 'https://contoso.github.io/rulebook?v=1' }
        @{ Value = 'https://contoso.github.io/rule book' }
    ) {
        { Invoke-Script @{ BaseUrl = $Value; Level = 'strict'; OutputPath = (Get-TestFolder) } } | Should-Throw -ExceptionMessage '-BaseUrl must be the address of the published Rulebook site, for example https://contoso.github.io/rulebook (https; http only for 127.0.0.1, localhost or [[]::1]; no query or fragment)*'
        Should-Invoke Invoke-WebRequest -Times 0 -Exactly
    }
}

Describe 'Get-RulebookSkeletons.ps1 source' {
    BeforeAll {
        $script:bytes = [System.IO.File]::ReadAllBytes($entry)
        $script:source = $utf8.GetString($bytes)
    }

    It 'requires PowerShell 7 and imports no module' {
        $source | Should-MatchString '(?m)\A#requires -Version 7\n'
        $source | Should-NotMatchString 'Import-Module'
    }

    It 'is ASCII with LF line ends and never calls exit' {
        @($bytes | Where-Object { $_ -gt 0x7F }).Count | Should-Be 0
        $source.Contains("`r") | Should-BeFalse
        $source | Should-NotMatchString '(?m)^\s*exit\b'
    }
}

Describe 'Get-RulebookSkeletons.ps1 parameter binding' {
    It 'rejects a stray positional value' {
        # PositionalBinding = $false (#61): every caller binds by name, so a stray value fails before the script runs.
        { & $script:entry -BaseUrl 'https://127.0.0.1:9/rulebook' -Level strict -OutputPath $TestDrive 'stray' } | Should-Throw -ExceptionType ([System.Management.Automation.ParameterBindingException]) -ExceptionMessage '*positional parameter*stray*'
    }
}
