# GitHub suite for WP07 (#9): modules/Rulebook.GitHub. The HTTP side is mocked at Invoke-WebRequest; the git side
# runs against bare repositories in TestDrive (tests/Helpers/RepoFixture.ps1) and is skipped without git.

BeforeDiscovery {
    $script:gitMissing = $null -eq (Get-Command git -ErrorAction SilentlyContinue)
}

BeforeAll {
    # The docs, schema and script URLs follow the engine ref: clear what a runner step would set, restore it in AfterAll.
    $script:savedActionRef = $env:GITHUB_ACTION_REF
    $script:savedActionPath = $env:GITHUB_ACTION_PATH
    Remove-Item Env:GITHUB_ACTION_REF, Env:GITHUB_ACTION_PATH -ErrorAction SilentlyContinue
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $PSScriptRoot 'Helpers' 'RepoFixture.ps1')
    Import-Module (Join-Path $repoRoot 'modules' 'Rulebook.GitHub.psd1') -Force
    $script:utf8 = [System.Text.UTF8Encoding]::new($false)
    $script:savedApiUrl = $env:GITHUB_API_URL
    $env:GITHUB_API_URL = $null

    function Get-TestFolder {
        return Join-Path $TestDrive ([guid]::NewGuid().ToString('n').Substring(0, 12))
    }

    function Get-MockResponse {
        # A response of the shape Invoke-WebRequest returns: the header type is a generic dictionary without a
        # one-argument Contains.
        param([int]$Status = 200, $Json, [hashtable]$Headers = @{})
        $dictionary = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.IEnumerable[string]]]::new()
        foreach ($key in $Headers.Keys) { $dictionary[$key] = [string[]]@($Headers[$key]) }
        $content = if ($null -eq $Json) { '' } elseif ($Json -is [string]) { $Json } else { ConvertTo-Json -InputObject $Json -Depth 10 -Compress }
        return [pscustomobject]@{ StatusCode = $Status; Content = $content; Headers = $dictionary }
    }

    function ConvertFrom-Base64Url {
        param([string]$Text)
        $padded = $Text.Replace('-', '+').Replace('_', '/')
        switch ($padded.Length % 4) { 2 { $padded += '==' } 3 { $padded += '=' } }
        return [System.Convert]::FromBase64String($padded)
    }

    function Get-GitText {
        param([string]$Root, [string[]]$Arguments)
        return (& git -C $Root @Arguments 2>&1) -join "`n"
    }
}

AfterAll {
    $env:GITHUB_ACTION_REF = $script:savedActionRef
    $env:GITHUB_ACTION_PATH = $script:savedActionPath
    $env:GITHUB_API_URL = $script:savedApiUrl
    Remove-Module Rulebook.GitHub, Rulebook.Common -ErrorAction SilentlyContinue
}

Describe 'New-GitHubAppJwt' {
    BeforeAll {
        $script:rsa = [System.Security.Cryptography.RSA]::Create(2048)
        $script:pem = $rsa.ExportRSAPrivateKeyPem()
        $script:now = [System.DateTimeOffset]::FromUnixTimeSeconds(1790000000)
    }

    AfterAll {
        $script:rsa.Dispose()
    }

    It 'has three base64url segments with the RS256 header and the iat, exp and iss claims' {
        $jwt = New-GitHubAppJwt -ClientId 'Iv23liAbc' -PrivateKey $pem -Now $now
        $parts = $jwt.Split('.')
        $parts.Count | Should-Be 3
        foreach ($part in $parts) { $part | Should-MatchString '^[A-Za-z0-9_-]+$' }
        $header = $utf8.GetString((ConvertFrom-Base64Url $parts[0])) | ConvertFrom-Json
        $header.alg | Should-Be 'RS256'
        $header.typ | Should-Be 'JWT'
        $claims = $utf8.GetString((ConvertFrom-Base64Url $parts[1])) | ConvertFrom-Json
        $claims.iat | Should-Be 1789999940
        $claims.exp | Should-Be 1790000600
        $claims.iss | Should-Be 'Iv23liAbc'
    }

    It 'signs with the private key (the public half verifies)' {
        $jwt = New-GitHubAppJwt -ClientId 'Iv23liAbc' -PrivateKey $pem -Now $now
        $parts = $jwt.Split('.')
        $verified = $rsa.VerifyData($utf8.GetBytes("$($parts[0]).$($parts[1])"), (ConvertFrom-Base64Url $parts[2]),
            [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $verified | Should-BeTrue
    }

    It 'accepts a PEM whose lines were joined (the AL-Go compressed JSON one-liner)' {
        $joined = [string]::Join('', $pem.Split("`n"))
        $joined.Contains("`n") | Should-BeFalse
        $jwt = New-GitHubAppJwt -ClientId 'Iv23liAbc' -PrivateKey $joined -Now $now
        $jwt | Should-Be (New-GitHubAppJwt -ClientId 'Iv23liAbc' -PrivateKey $pem -Now $now)
    }

    It 'refuses a value that is not a PEM key' {
        { New-GitHubAppJwt -ClientId 'Iv23liAbc' -PrivateKey 'not a key' } | Should-Throw -ExceptionMessage '*Iv23liAbc is not a PEM key*'
    }
}

Describe 'Get-GitHubAccessToken' {
    BeforeAll {
        $script:appRsa = [System.Security.Cryptography.RSA]::Create(2048)
        $script:appJson = @{ GitHubAppClientId = 'Iv23liApp'; PrivateKey = [string]::Join('', $appRsa.ExportRSAPrivateKeyPem().Split("`n")) } | ConvertTo-Json -Compress
    }

    AfterAll {
        $script:appRsa.Dispose()
    }

    BeforeEach {
        Mock Invoke-WebRequest -ModuleName Rulebook.GitHub { Get-MockResponse -Status 500 -Json @{ message = 'unexpected call' } }
    }

    It 'gives Kind none for an empty value' {
        $result = Get-GitHubAccessToken -Token '' -Repository 'Contoso/rulebook'
        $result.Kind | Should-Be 'none'
        $result.Token | Should-Be ''
        Should-Invoke Invoke-WebRequest -ModuleName Rulebook.GitHub -Times 0 -Exactly
    }

    It 'passes a personal access token through without a request' {
        $result = Get-GitHubAccessToken -Token 'github_pat_11ABC' -Repository 'Contoso/rulebook'
        $result.Kind | Should-Be 'pat'
        $result.Token | Should-Be 'github_pat_11ABC'
        Should-Invoke Invoke-WebRequest -ModuleName Rulebook.GitHub -Times 0 -Exactly
    }

    It 'exchanges GitHub App JSON for an installation token limited to the repository and the permissions' {
        Mock Invoke-WebRequest -ModuleName Rulebook.GitHub -ParameterFilter { $Uri -eq 'https://api.github.com/repos/Contoso/rulebook/installation' } {
            Get-MockResponse -Json @{ id = 42; access_tokens_url = 'https://api.github.com/app/installations/42/access_tokens' }
        }
        Mock Invoke-WebRequest -ModuleName Rulebook.GitHub -ParameterFilter { $Uri -eq 'https://api.github.com/app/installations/42/access_tokens' } {
            Get-MockResponse -Status 201 -Json @{ token = 'ghs_installation'; expires_at = '2026-10-07T12:00:00Z' }
        }
        $result = Get-GitHubAccessToken -Token $appJson -Repository 'Contoso/rulebook'
        $result.Kind | Should-Be 'app'
        $result.Token | Should-Be 'ghs_installation'
        Should-Invoke Invoke-WebRequest -ModuleName Rulebook.GitHub -Times 1 -Exactly -ParameterFilter {
            $Uri -eq 'https://api.github.com/repos/Contoso/rulebook/installation' -and $Method -eq 'GET' -and $Headers.Authorization -like 'Bearer *.*.*'
        }
        Should-Invoke Invoke-WebRequest -ModuleName Rulebook.GitHub -Times 1 -Exactly -ParameterFilter {
            if ($null -eq $Body) { return $false }
            $sent = $Body | ConvertFrom-Json
            $Method -eq 'POST' -and (@($sent.repositories) -join ',') -eq 'rulebook' -and $sent.permissions.contents -eq 'write' -and
            $sent.permissions.pull_requests -eq 'write' -and $sent.permissions.workflows -eq 'write' -and $sent.permissions.actions -eq 'read' -and $sent.permissions.metadata -eq 'read'
        }
    }

    It 'throws with the status and the client id when the app is not installed' {
        Mock Invoke-WebRequest -ModuleName Rulebook.GitHub { Get-MockResponse -Status 404 -Json @{ message = 'Not Found' } }
        { Get-GitHubAccessToken -Token $appJson -Repository 'Contoso/rulebook' } | Should-Throw -ExceptionMessage '*Iv23liApp has no installation on Contoso/rulebook (HTTP 404: Not Found)*'
    }

    It 'throws when the token request is refused' {
        Mock Invoke-WebRequest -ModuleName Rulebook.GitHub -ParameterFilter { $Uri -like '*/installation' } {
            Get-MockResponse -Json @{ access_tokens_url = 'https://api.github.com/app/installations/42/access_tokens' }
        }
        Mock Invoke-WebRequest -ModuleName Rulebook.GitHub -ParameterFilter { $Uri -like '*/access_tokens' } { Get-MockResponse -Status 422 -Json @{ message = 'The permissions requested are not granted to this installation.' } }
        { Get-GitHubAccessToken -Token $appJson -Repository 'Contoso/rulebook' } | Should-Throw -ExceptionMessage '*Iv23liApp could not get an installation token*HTTP 422*not granted*'
    }

    It 'refuses JSON without the app fields' {
        { Get-GitHubAccessToken -Token '{"clientId":"x"}' -Repository 'Contoso/rulebook' } | Should-Throw -ExceptionMessage '*needs GitHubAppClientId and PrivateKey*'
    }

    It 'points at the user page on main, or on the branch the action runs from (GITHUB_ACTION_REF v1)' {
        { Get-GitHubAccessToken -Token '{"clientId":"x"}' -Repository 'Contoso/rulebook' } | Should-Throw -ExceptionMessage '*; see https://github.com/ALCops/rulebook/blob/main/docs/ghtokenworkflow.md'
        $saved = $env:GITHUB_ACTION_REF
        try {
            $env:GITHUB_ACTION_REF = 'v1'
            { Get-GitHubAccessToken -Token '{"clientId":"x"}' -Repository 'Contoso/rulebook' } | Should-Throw -ExceptionMessage '*; see https://github.com/ALCops/rulebook/blob/v1/docs/ghtokenworkflow.md'
        } finally {
            $env:GITHUB_ACTION_REF = $saved
        }
    }
}

Describe 'Invoke-GitHubApi' {
    It 'sends the GitHub headers and the bearer token and parses JSON' {
        Mock Invoke-WebRequest -ModuleName Rulebook.GitHub { Get-MockResponse -Json @{ name = 'rulebook' } -Headers @{ 'X-RateLimit-Remaining' = '4999' } }
        $result = Invoke-GitHubApi -Path '/repos/Contoso/rulebook' -Token 'tok' -ApiUrl 'https://api.example.com/'
        $result.StatusCode | Should-Be 200
        $result.Body['name'] | Should-Be 'rulebook'
        $result.RateLimitRemaining | Should-Be '4999'
        Should-Invoke Invoke-WebRequest -ModuleName Rulebook.GitHub -Times 1 -Exactly -ParameterFilter {
            $Uri -eq 'https://api.example.com/repos/Contoso/rulebook' -and $Headers.Accept -eq 'application/vnd.github+json' -and
            $Headers['X-GitHub-Api-Version'] -eq '2022-11-28' -and $Headers.Authorization -eq 'Bearer tok' -and $SkipHttpErrorCheck
        }
    }

    It 'sends no Authorization header without a token' {
        Mock Invoke-WebRequest -ModuleName Rulebook.GitHub { Get-MockResponse -Json @{} }
        $null = Invoke-GitHubApi -Path 'repos/Contoso/rulebook'
        Should-Invoke Invoke-WebRequest -ModuleName Rulebook.GitHub -Times 1 -Exactly -ParameterFilter { -not $Headers.ContainsKey('Authorization') -and $Uri -eq 'https://api.github.com/repos/Contoso/rulebook' }
    }

    It 'returns a non-2xx answer instead of throwing' {
        Mock Invoke-WebRequest -ModuleName Rulebook.GitHub { Get-MockResponse -Status 404 -Json @{ message = 'Not Found' } }
        (Invoke-GitHubApi -Path 'repos/Contoso/missing').StatusCode | Should-Be 404
    }

    It 'follows Link rel="next" with -Paginate and concatenates the pages' {
        Mock Invoke-WebRequest -ModuleName Rulebook.GitHub -ParameterFilter { $Uri -eq 'https://api.github.com/repos/Contoso/rulebook/pulls?state=open' } {
            Get-MockResponse -Json '[{"number":1},{"number":2}]' -Headers @{ Link = '<https://api.github.com/repositories/9/pulls?state=open&page=2>; rel="next", <https://api.github.com/repositories/9/pulls?state=open&page=2>; rel="last"' }
        }
        Mock Invoke-WebRequest -ModuleName Rulebook.GitHub -ParameterFilter { $Uri -eq 'https://api.github.com/repositories/9/pulls?state=open&page=2' } {
            Get-MockResponse -Json '[{"number":3}]' -Headers @{ Link = '<https://api.github.com/repositories/9/pulls?state=open&page=1>; rel="first"' }
        }
        $result = Invoke-GitHubApi -Path 'repos/Contoso/rulebook/pulls?state=open' -Paginate
        @($result.Body | ForEach-Object { $_['number'] }) | Should-BeCollection @(1, 2, 3)
        Should-Invoke Invoke-WebRequest -ModuleName Rulebook.GitHub -Times 2 -Exactly
    }

    It 'keeps a one-element array an array' {
        Mock Invoke-WebRequest -ModuleName Rulebook.GitHub { Get-MockResponse -Json '[{"number":7}]' }
        $result = Invoke-GitHubApi -Path 'repos/Contoso/rulebook/pulls'
        $result.Body -is [System.Collections.IList] | Should-BeTrue
        @($result.Body).Count | Should-Be 1
    }

    It 'writes the answer to -OutFile' {
        $file = Join-Path $TestDrive 'download.zip'
        Mock Invoke-WebRequest -ModuleName Rulebook.GitHub { [System.IO.File]::WriteAllText($OutFile, 'zip'); Get-MockResponse }
        $result = Invoke-GitHubApi -Path 'repos/Contoso/rulebook/zipball/abc' -OutFile $file
        $result.StatusCode | Should-Be 200
        Get-Content -LiteralPath $file -Raw | Should-Be 'zip'
        Should-Invoke Invoke-WebRequest -ModuleName Rulebook.GitHub -Times 1 -Exactly -ParameterFilter { $OutFile -eq $file -and $PassThru }
    }

    It 'sends -Body as compressed JSON' {
        Mock Invoke-WebRequest -ModuleName Rulebook.GitHub { Get-MockResponse -Status 201 -Json @{} }
        $null = Invoke-GitHubApi -Method POST -Path 'repos/Contoso/rulebook/pulls' -Body ([ordered]@{ title = 'T'; base = 'main' })
        Should-Invoke Invoke-WebRequest -ModuleName Rulebook.GitHub -Times 1 -Exactly -ParameterFilter { $Body -eq '{"title":"T","base":"main"}' -and $ContentType -like 'application/json*' }
    }

    It 'throws when there is no HTTP answer' {
        Mock Invoke-WebRequest -ModuleName Rulebook.GitHub { throw [System.Net.Http.HttpRequestException]::new('Connection refused') }
        { Invoke-GitHubApi -Path 'repos/Contoso/rulebook' } | Should-Throw -ExceptionMessage '*Connection refused*'
    }
}

Describe 'Get-GitHubBranchSha and Save-GitHubZipball' {
    It 'returns the head commit of the branch' {
        $sha = 'a' * 40
        Mock Invoke-WebRequest -ModuleName Rulebook.GitHub { Get-MockResponse -Json @{ name = 'main'; commit = @{ sha = $sha } } }
        Get-GitHubBranchSha -Repository 'ALCops/rulebook' -Branch 'main' | Should-Be $sha
        Should-Invoke Invoke-WebRequest -ModuleName Rulebook.GitHub -Times 1 -Exactly -ParameterFilter { $Uri -eq 'https://api.github.com/repos/ALCops/rulebook/branches/main' }
    }

    It 'escapes each segment of the branch and the repository and keeps the slashes' {
        $sha = 'c' * 40
        Mock Invoke-WebRequest -ModuleName Rulebook.GitHub { Get-MockResponse -Json @{ commit = @{ sha = $sha } } }
        Get-GitHubBranchSha -Repository 'Contoso/rule%book' -Branch 'feature/x#1?y' | Should-Be $sha
        Should-Invoke Invoke-WebRequest -ModuleName Rulebook.GitHub -Times 1 -Exactly -ParameterFilter { $Uri -ceq 'https://api.github.com/repos/Contoso/rule%25book/branches/feature/x%231%3Fy' }
    }

    It 'escapes the commit segment of the zipball path' {
        Mock Invoke-WebRequest -ModuleName Rulebook.GitHub { Get-MockResponse -Status 404 }
        { Save-GitHubZipball -Repository 'Contoso/rulebook' -Sha 'v1#x' -Path (Get-TestFolder) } | Should-Throw -ExceptionMessage '*HTTP 404*'
        Should-Invoke Invoke-WebRequest -ModuleName Rulebook.GitHub -Times 1 -Exactly -ParameterFilter { $Uri -ceq 'https://api.github.com/repos/Contoso/rulebook/zipball/v1%23x' }
    }

    It 'throws naming the template branch when the branch is missing' {
        Mock Invoke-WebRequest -ModuleName Rulebook.GitHub { Get-MockResponse -Status 404 -Json @{ message = 'Branch not found' } }
        { Get-GitHubBranchSha -Repository 'ALCops/rulebook' -Branch 'v9' } | Should-Throw -ExceptionMessage 'Could not get the latest commit of https://github.com/ALCops/rulebook@v9 (HTTP 404: Branch not found)'
    }

    It 'extracts the zipball and returns its root folder' {
        $source = Get-TestFolder
        Write-FixtureText -Path (Join-Path $source 'ALCops-rulebook-abc1234' '.github' 'workflows' 'Validate.yaml') -Text 'name: Validate'
        $zipSource = Join-Path $TestDrive 'source.zip'
        [System.IO.Compression.ZipFile]::CreateFromDirectory($source, $zipSource)
        Mock Invoke-WebRequest -ModuleName Rulebook.GitHub { Copy-Item -LiteralPath $zipSource -Destination $OutFile; Get-MockResponse }
        $target = Get-TestFolder
        $root = Save-GitHubZipball -Repository 'ALCops/rulebook' -Sha ('a' * 40) -Path $target
        Split-Path -Leaf $root | Should-Be 'ALCops-rulebook-abc1234'
        Test-Path -LiteralPath (Join-Path $root '.github' 'workflows' 'Validate.yaml') | Should-BeTrue
        Test-Path -LiteralPath "$target.zip" | Should-BeFalse
    }

    It 'throws with the status on a 404 download' {
        Mock Invoke-WebRequest -ModuleName Rulebook.GitHub { Get-MockResponse -Status 404 }
        { Save-GitHubZipball -Repository 'ALCops/private' -Sha ('a' * 40) -Path (Get-TestFolder) } | Should-Throw -ExceptionMessage '*HTTP 404*'
    }
}

Describe 'Get-GitHubCommitList' {
    BeforeAll {
        function Get-CommitPage {
            param([int]$Count, [int]$Offset = 0)
            return @(for ($i = 1; $i -le $Count; $i++) { @{ sha = ('{0:x40}' -f ($Offset + $i)); commit = @{ tree = @{ sha = ('{0:x40}' -f (1000 + $Offset + $i)) } } } })
        }
    }

    It 'reads pages of 100 until a shorter page and keeps the order' {
        Mock Invoke-WebRequest -ModuleName Rulebook.GitHub -ParameterFilter { $Uri -like '*&page=1' } { Get-MockResponse -Json (Get-CommitPage -Count 100) }
        Mock Invoke-WebRequest -ModuleName Rulebook.GitHub -ParameterFilter { $Uri -like '*&page=2' } { Get-MockResponse -Json (Get-CommitPage -Count 3 -Offset 100) }
        $list = Get-GitHubCommitList -Repository 'Contoso/rule%book' -Ref 'feature/x#1' -Token 'gh'
        $list.Commits.Count | Should-Be 103
        $list.Commits[0].Sha | Should-Be ('{0:x40}' -f 1)
        $list.Commits[-1].Sha | Should-Be ('{0:x40}' -f 103)
        $list.Commits[-1].TreeSha | Should-Be ('{0:x40}' -f 1103)
        $list.Truncated | Should-BeFalse
        Should-Invoke Invoke-WebRequest -ModuleName Rulebook.GitHub -Times 1 -Exactly -ParameterFilter { $Uri -ceq 'https://api.github.com/repos/Contoso/rule%25book/commits?sha=feature%2Fx%231&per_page=100&page=1' }
        Should-Invoke Invoke-WebRequest -ModuleName Rulebook.GitHub -Times 2 -Exactly
    }

    It 'stops after the page that holds one of -TreeSha' {
        Mock Invoke-WebRequest -ModuleName Rulebook.GitHub { Get-MockResponse -Json (Get-CommitPage -Count 100) }
        $list = Get-GitHubCommitList -Repository 'Contoso/rulebook' -Ref 'main' -TreeSha @('nothing', ('{0:x40}' -f 1050))
        $list.Commits.Count | Should-Be 100
        $list.Truncated | Should-BeFalse
        Should-Invoke Invoke-WebRequest -ModuleName Rulebook.GitHub -Times 1 -Exactly
    }

    It 'stops at -MaxPages and says the list is truncated' {
        Mock Invoke-WebRequest -ModuleName Rulebook.GitHub { Get-MockResponse -Json (Get-CommitPage -Count 100) }
        $list = Get-GitHubCommitList -Repository 'Contoso/rulebook' -Ref 'main' -MaxPages 2
        $list.Commits.Count | Should-Be 200
        $list.Truncated | Should-BeTrue
        Should-Invoke Invoke-WebRequest -ModuleName Rulebook.GitHub -Times 2 -Exactly
    }

    It 'ends on an empty page and leaves sha= out without a ref' {
        Mock Invoke-WebRequest -ModuleName Rulebook.GitHub { Get-MockResponse -Json '[]' }
        $list = Get-GitHubCommitList -Repository 'Contoso/rulebook' -Ref ''
        @($list.Commits) | Should-BeCollection @()
        $list.Truncated | Should-BeFalse
        Should-Invoke Invoke-WebRequest -ModuleName Rulebook.GitHub -Times 1 -Exactly -ParameterFilter { $Uri -ceq 'https://api.github.com/repos/Contoso/rulebook/commits?per_page=100&page=1' }
    }

    It 'throws with the status on a 404' {
        Mock Invoke-WebRequest -ModuleName Rulebook.GitHub { Get-MockResponse -Status 404 -Json @{ message = 'Not Found' } }
        $caught = $null
        try { $null = Get-GitHubCommitList -Repository 'Contoso/rulebook' -Ref 'main' } catch { $caught = $_ }
        $caught.Exception.Message | Should-Be 'Could not list the commits of https://github.com/Contoso/rulebook@main (HTTP 404: Not Found)'
        $caught.Exception.Data['StatusCode'] | Should-Be 404
    }
}

Describe 'Get-GitRootTree' -Skip:$gitMissing {
    BeforeAll {
        $script:repo = Get-TestFolder
        Write-FixtureText -Path (Join-Path $repo 'README.md') -Text "# root`n"
        $null = New-FixtureGitRepo -Root $repo -Message 'Initial commit'
        $script:tree = (Get-GitText -Root $repo -Arguments @('rev-parse', 'HEAD^{tree}')).Trim()
        Write-FixtureText -Path (Join-Path $repo 'README.md') -Text "# changed`n"
        $null = New-FixtureGitRepo -Root $repo -Message 'Second commit'
    }

    It 'gives the tree of the root commit, not of the head' {
        Get-GitRootTree -Root $repo | Should-BeCollection @($tree)
        (Get-GitText -Root $repo -Arguments @('rev-parse', 'HEAD^{tree}')).Trim() | Should-NotBe $tree
    }

    It 'gives $null for a shallow clone' {
        $parent = Get-TestFolder
        $null = New-Item -ItemType Directory -Path $parent
        Invoke-FixtureGit -Root $parent -Arguments @('clone', '--quiet', '--depth', '1', ([System.Uri]::new($repo)).AbsoluteUri, 'shallow') | Out-Null
        Get-GitRootTree -Root (Join-Path $parent 'shallow') | Should-BeNull
    }

    It 'gives the root tree of a bare clone and of a detached HEAD' {
        $parent = Get-TestFolder
        $null = New-Item -ItemType Directory -Path $parent
        Invoke-FixtureGit -Root $parent -Arguments @('clone', '--quiet', '--bare', ([System.Uri]::new($repo)).AbsoluteUri, 'bare.git') | Out-Null
        Get-GitRootTree -Root (Join-Path $parent 'bare.git') | Should-BeCollection @($tree)
        Invoke-FixtureGit -Root $parent -Arguments @('clone', '--quiet', ([System.Uri]::new($repo)).AbsoluteUri, 'detached') | Out-Null
        Invoke-FixtureGit -Root (Join-Path $parent 'detached') -Arguments @('checkout', '--quiet', '--detach', 'HEAD~1') | Out-Null
        Get-GitRootTree -Root (Join-Path $parent 'detached') | Should-BeCollection @($tree)
    }

    It 'gives $null for a folder inside a repository' {
        $sub = Join-Path $repo 'sub'
        $null = New-Item -ItemType Directory -Path $sub -Force
        Get-GitRootTree -Root $sub | Should-BeNull
    }

    It 'gives $null for a folder that is not a repository or does not exist' {
        $plain = Get-TestFolder
        $null = New-Item -ItemType Directory -Path $plain
        Get-GitRootTree -Root $plain | Should-BeNull
        Get-GitRootTree -Root (Join-Path $plain 'missing') | Should-BeNull
    }
}

Describe 'Find-GitHubPullRequest and New-GitHubPullRequest' {
    It 'finds the open pull request with the same title across pages, ordinally' {
        $title = '[main@1234567] Update Rulebook System Files from ALCops/rulebook - abcdef0'
        Mock Invoke-WebRequest -ModuleName Rulebook.GitHub -ParameterFilter { $Uri -like '*/repos/Contoso/rulebook/pulls?*' } {
            Get-MockResponse -Json (ConvertTo-Json -Compress -InputObject @(@{ number = 1; title = $title.ToUpperInvariant(); html_url = 'u1' })) -Headers @{ Link = '<https://api.github.com/next-page>; rel="next"' }
        }
        Mock Invoke-WebRequest -ModuleName Rulebook.GitHub -ParameterFilter { $Uri -eq 'https://api.github.com/next-page' } {
            Get-MockResponse -Json (ConvertTo-Json -Compress -InputObject @(@{ number = 2; title = $title; html_url = 'https://github.com/Contoso/rulebook/pull/2' }))
        }
        $found = Find-GitHubPullRequest -Repository 'Contoso/rulebook' -Base 'main' -Title $title -Token 'tok'
        $found.Number | Should-Be 2
        $found.Url | Should-Be 'https://github.com/Contoso/rulebook/pull/2'
        Should-Invoke Invoke-WebRequest -ModuleName Rulebook.GitHub -Times 1 -Exactly -ParameterFilter { $Uri -eq 'https://api.github.com/repos/Contoso/rulebook/pulls?base=main&state=open&per_page=100' }
    }

    It 'returns nothing when no title matches' {
        Mock Invoke-WebRequest -ModuleName Rulebook.GitHub { Get-MockResponse -Json '[]' }
        Find-GitHubPullRequest -Repository 'Contoso/rulebook' -Base 'main' -Title 'x' | Should-BeNull
    }

    It 'creates a pull request and adds the labels' {
        Mock Invoke-WebRequest -ModuleName Rulebook.GitHub -ParameterFilter { $Uri -like '*/pulls' } { Get-MockResponse -Status 201 -Json @{ number = 5; html_url = 'https://github.com/Contoso/rulebook/pull/5' } }
        Mock Invoke-WebRequest -ModuleName Rulebook.GitHub -ParameterFilter { $Uri -like '*/issues/5/labels' } { Get-MockResponse -Json '[]' }
        $pull = New-GitHubPullRequest -Repository 'Contoso/rulebook' -Token 'tok' -Title 'T' -Body 'B' -Head 'update/x' -Base 'main' -Labels @('rulebook')
        $pull.Number | Should-Be 5
        $pull.Url | Should-Be 'https://github.com/Contoso/rulebook/pull/5'
        Should-Invoke Invoke-WebRequest -ModuleName Rulebook.GitHub -Times 1 -Exactly -ParameterFilter { $Uri -like '*/pulls' -and ($Body | ConvertFrom-Json).head -eq 'update/x' }
        Should-Invoke Invoke-WebRequest -ModuleName Rulebook.GitHub -Times 1 -Exactly -ParameterFilter { $Uri -like '*/issues/5/labels' -and $Body -eq '{"labels":["rulebook"]}' }
    }

    It 'makes no label call without labels' {
        Mock Invoke-WebRequest -ModuleName Rulebook.GitHub { Get-MockResponse -Status 201 -Json @{ number = 6; html_url = 'u' } }
        $null = New-GitHubPullRequest -Repository 'Contoso/rulebook' -Token 'tok' -Title 'T' -Body 'B' -Head 'h' -Base 'main' -Labels @()
        Should-Invoke Invoke-WebRequest -ModuleName Rulebook.GitHub -Times 1 -Exactly
    }

    It 'explains a 403 with the token, the Actions setting and the branch link' {
        Mock Invoke-WebRequest -ModuleName Rulebook.GitHub { Get-MockResponse -Status 403 -Json @{ message = 'GitHub Actions is not permitted to create or approve pull requests.' } }
        { New-GitHubPullRequest -Repository 'Contoso/rulebook' -Token 'tok' -Title 'T' -Body 'B' -Head 'update/x' -Base 'main' -ServerUrl 'https://github.com' } |
            Should-Throw -ExceptionMessage '*not allowed to create pull requests*Settings > Actions > General*https://github.com/Contoso/rulebook/tree/update/x'
    }
}

Describe 'The living pull request of the scan' {
    It 'sends PATCH with the JSON body' {
        Mock Invoke-WebRequest -ModuleName Rulebook.GitHub { Get-MockResponse -Status 200 -Json @{ number = 7; html_url = 'https://github.com/Contoso/rulebook/pull/7' } }
        $response = Invoke-GitHubApi -Method PATCH -Path 'repos/Contoso/rulebook/pulls/7' -Token 'tok' -Body @{ title = 'T' }
        $response.StatusCode | Should-Be 200
        Should-Invoke Invoke-WebRequest -ModuleName Rulebook.GitHub -Times 1 -Exactly -ParameterFilter { $Method -eq 'PATCH' -and $Uri -eq 'https://api.github.com/repos/Contoso/rulebook/pulls/7' -and $Body -eq '{"title":"T"}' }
    }

    It 'finds the open pull request by its head branch and base, the first one' {
        Mock Invoke-WebRequest -ModuleName Rulebook.GitHub { Get-MockResponse -Status 200 -Json @(@{ number = 9; html_url = 'https://github.com/Contoso/rulebook/pull/9'; title = 'Scan diagnostics: x' }, @{ number = 3; html_url = 'u3'; title = 'y' }) }
        $pull = Find-GitHubPullRequestByHead -Repository 'Contoso/rulebook' -Head 'scan-diagnostics/main' -Base 'main' -Token 'tok'
        "$($pull.Number) $($pull.Url)" | Should-Be '9 https://github.com/Contoso/rulebook/pull/9'
        Should-Invoke Invoke-WebRequest -ModuleName Rulebook.GitHub -Times 1 -Exactly -ParameterFilter { $Method -eq 'GET' -and $Uri -eq 'https://api.github.com/repos/Contoso/rulebook/pulls?state=open&head=Contoso%3Ascan-diagnostics%2Fmain&base=main&per_page=100' }
    }

    It 'returns $null when no pull request is open from the branch' {
        Mock Invoke-WebRequest -ModuleName Rulebook.GitHub { Get-MockResponse -Status 200 -Json '[]' }
        Find-GitHubPullRequestByHead -Repository 'Contoso/rulebook' -Head 'scan-diagnostics/main' -Base 'main' | Should-BeNull
    }

    It 'updates title and body with PATCH' {
        Mock Invoke-WebRequest -ModuleName Rulebook.GitHub { Get-MockResponse -Status 200 -Json @{ number = 9; html_url = 'https://github.com/Contoso/rulebook/pull/9' } }
        $updated = Update-GitHubPullRequest -Repository 'Contoso/rulebook' -Number 9 -Title 'New title' -Body 'New body' -Token 'tok'
        $updated.Url | Should-Be 'https://github.com/Contoso/rulebook/pull/9'
        Should-Invoke Invoke-WebRequest -ModuleName Rulebook.GitHub -Times 1 -Exactly -ParameterFilter { $Method -eq 'PATCH' -and $Uri -like '*/repos/Contoso/rulebook/pulls/9' -and $Body -eq '{"title":"New title","body":"New body"}' }
    }

    It 'throws when the update is refused' {
        Mock Invoke-WebRequest -ModuleName Rulebook.GitHub { Get-MockResponse -Status 422 -Json @{ message = 'Validation Failed' } }
        { Update-GitHubPullRequest -Repository 'Contoso/rulebook' -Number 9 -Title 'T' -Body 'B' } | Should-Throw -ExceptionMessage 'Could not update pull request #9 of Contoso/rulebook (HTTP 422: Validation Failed)'
    }
}

Describe 'git: New-GitHubClone and Publish-GitHubChange' -Skip:$gitMissing {
    BeforeEach {
        $script:source = Get-TestFolder
        Write-FixtureText -Path (Join-Path $source 'README.md') -Text '# Rulebook'
        $script:bare = New-BareFixtureRepo -Source $source -Destination (Join-Path (Get-TestFolder) 'origin.git')
        $script:mainSha = (Get-GitText -Root $bare -Arguments @('rev-parse', 'refs/heads/main')).Trim()
    }

    It 'clones an https remote with the token in the git environment only, never in the remote, the config or .git' {
        # url.<bare>.insteadOf sends the https remote to the bare repository; git runs with the header environment,
        # but the local transport sends no header, so the test proves that nothing is written, not that it is sent.
        $remote = 'https://github.com/Contoso/org-repo'
        $clone = New-GitHubClone -RemoteUrl $remote -Branch 'main' -Path (Get-TestFolder) -Token 'ghs_secret_token' -Actor 'octocat' -ExtraConfig @{ "url.$($bare.Replace('\', '/')).insteadOf" = $remote }
        $clone.BaseSha | Should-Be $mainSha
        $clone.Environment['GIT_CONFIG_KEY_0'] | Should-Be 'http.https://github.com/.extraheader'
        (Get-GitText -Root $clone.Path -Arguments @('remote', 'get-url', 'origin')).Trim() | Should-Be $remote
        (Get-GitText -Root $clone.Path -Arguments @('remote', '-v')) | Should-NotMatchString 'ghs_secret_token'
        (Get-GitText -Root $clone.Path -Arguments @('config', '--list', '--show-origin')) | Should-NotMatchString 'ghs_secret_token|extraheader|insteadOf'
        $basic = [System.Convert]::ToBase64String($utf8.GetBytes('x-access-token:ghs_secret_token'))
        foreach ($file in Get-ChildItem -LiteralPath (Join-Path $clone.Path '.git') -Recurse -File -Force) {
            $text = [System.Text.Encoding]::Latin1.GetString([System.IO.File]::ReadAllBytes($file.FullName))
            ($text.Contains('ghs_secret_token') -or $text.Contains($basic)) | Should-BeFalse -Because $file.FullName
        }
    }

    It 'clones main, records the base commit and the identity, and keeps the token out of the remote and the config' {
        $clone = New-GitHubClone -RemoteUrl $bare -Branch 'main' -Path (Get-TestFolder) -Token 'ghs_secret_token' -Actor 'octocat'
        $clone.BaseSha | Should-Be $mainSha
        (Get-GitText -Root $clone.Path -Arguments @('config', 'user.name')).Trim() | Should-Be 'octocat'
        (Get-GitText -Root $clone.Path -Arguments @('config', 'user.email')).Trim() | Should-Be 'octocat@users.noreply.github.com'
        (Get-GitText -Root $clone.Path -Arguments @('config', 'core.autocrlf')).Trim() | Should-Be 'false'
        (Get-GitText -Root $clone.Path -Arguments @('remote', '-v')) | Should-NotMatchString 'ghs_secret_token'
        (Get-GitText -Root $clone.Path -Arguments @('config', '--list', '--show-origin')) | Should-NotMatchString 'ghs_secret_token|extraheader'
    }

    It 'passes the token as an extra header in the git environment for an https remote, never in clear' {
        $environment = InModuleScope Rulebook.GitHub { Get-GitAuthEnvironment -RemoteUrl 'https://github.com/Contoso/rulebook' -Token 'ghs_secret_token' }
        $environment['GIT_CONFIG_COUNT'] | Should-Be '1'
        $environment['GIT_CONFIG_KEY_0'] | Should-Be 'http.https://github.com/.extraheader'
        $expected = 'AUTHORIZATION: basic ' + [System.Convert]::ToBase64String($utf8.GetBytes('x-access-token:ghs_secret_token'))
        $environment['GIT_CONFIG_VALUE_0'] | Should-Be $expected
        (InModuleScope Rulebook.GitHub { Get-GitAuthEnvironment -RemoteUrl 'C:/repos/origin.git' -Token 'x' }).Count | Should-Be 0
    }

    It 'names the branch when the clone fails' {
        { New-GitHubClone -RemoteUrl $bare -Branch 'release' -Path (Get-TestFolder) } | Should-Throw -ExceptionMessage "Could not clone branch 'release'*"
    }

    It 'commits to a new branch and pushes it, main unchanged' {
        $clone = New-GitHubClone -RemoteUrl $bare -Branch 'main' -Path (Get-TestFolder) -Actor 'octocat'
        Write-FixtureText -Path (Join-Path $clone.Path 'base' 'house.ruleset.json') -Text '{ "name": "Rulebook House", "rules": [] }'
        $result = Publish-GitHubChange -Clone $clone -Message 'Update' -NewBranch 'update-rulebook-system-files/main/261007120000'
        $result.Pushed | Should-BeTrue
        $result.Direct | Should-BeFalse
        $result.Branch | Should-Be 'update-rulebook-system-files/main/261007120000'
        (Get-GitText -Root $bare -Arguments @('rev-parse', 'refs/heads/update-rulebook-system-files/main/261007120000')).Trim() | Should-Be $result.Sha
        (Get-GitText -Root $bare -Arguments @('rev-parse', 'refs/heads/main')).Trim() | Should-Be $mainSha
        (Get-GitText -Root $bare -Arguments @('log', '-1', '--format=%s%n%an', $result.Sha)) | Should-Be "Update`noctocat"
    }

    It 'pushes a direct commit to main' {
        $clone = New-GitHubClone -RemoteUrl $bare -Branch 'main' -Path (Get-TestFolder)
        Write-FixtureText -Path (Join-Path $clone.Path 'overrides.json') -Text '{ "rules": [] }'
        $result = Publish-GitHubChange -Clone $clone -Message 'Direct' -NewBranch 'unused' -DirectCommit
        $result.Direct | Should-BeTrue
        $result.Fallback | Should-BeFalse
        $result.FallbackReason | Should-BeNull
        $result.Branch | Should-Be 'main'
        (Get-GitText -Root $bare -Arguments @('rev-parse', 'refs/heads/main')).Trim() | Should-Be $result.Sha
    }

    It 'falls back to a branch when the direct push is refused' {
        Add-RejectPushHook -BarePath $bare -Branch 'main'
        $clone = New-GitHubClone -RemoteUrl $bare -Branch 'main' -Path (Get-TestFolder)
        Write-FixtureText -Path (Join-Path $clone.Path 'overrides.json') -Text '{ "rules": [] }'
        $result = Publish-GitHubChange -Clone $clone -Message 'Direct' -NewBranch 'update-rulebook-system-files/main/261007120001' -DirectCommit -WarningVariable warnings
        $result.Fallback | Should-BeTrue
        $result.FallbackReason | Should-BeLikeString '*main is protected*'
        # The module writes no warning; the action reports the refusal as an annotation (#77).
        @($warnings).Count | Should-Be 0
        $result.Direct | Should-BeFalse
        $result.Branch | Should-Be 'update-rulebook-system-files/main/261007120001'
        (Get-GitText -Root $bare -Arguments @('rev-parse', 'refs/heads/main')).Trim() | Should-Be $mainSha
        (Get-GitText -Root $bare -Arguments @('rev-parse', 'refs/heads/update-rulebook-system-files/main/261007120001')).Trim() | Should-Be $result.Sha
        (Get-GitText -Root $bare -Arguments @('rev-parse', "$($result.Sha)~1")).Trim() | Should-Be $mainSha
    }

    It 'carries the refusal on the exception when the fallback branch is refused too' {
        Add-RejectPushHook -BarePath $bare -All
        $clone = New-GitHubClone -RemoteUrl $bare -Branch 'main' -Path (Get-TestFolder)
        Write-FixtureText -Path (Join-Path $clone.Path 'overrides.json') -Text '{ "rules": [] }'
        $caught = $null
        try { $null = Publish-GitHubChange -Clone $clone -Message 'Direct' -NewBranch 'update-rulebook-system-files/main/261007120003' -DirectCommit } catch { $caught = $_ }
        $caught | Should-NotBeNull
        $caught.Exception.Message | Should-BeLikeString 'git push update-rulebook-system-files/main/261007120003 failed*'
        $caught.Exception.Data['FallbackReason'] | Should-BeLikeString '*every branch is protected*'
    }

    It 'carries no refusal when a branch push fails without -DirectCommit' {
        Add-RejectPushHook -BarePath $bare -All
        $clone = New-GitHubClone -RemoteUrl $bare -Branch 'main' -Path (Get-TestFolder)
        Write-FixtureText -Path (Join-Path $clone.Path 'overrides.json') -Text '{ "rules": [] }'
        $caught = $null
        try { $null = Publish-GitHubChange -Clone $clone -Message 'Branch' -NewBranch 'update-rulebook-system-files/main/261007120004' } catch { $caught = $_ }
        $caught | Should-NotBeNull
        $caught.Exception.Data.Contains('FallbackReason') | Should-BeFalse
    }

    It 'reports no-changes and pushes nothing when the clone is unchanged' {
        $clone = New-GitHubClone -RemoteUrl $bare -Branch 'main' -Path (Get-TestFolder)
        $result = Publish-GitHubChange -Clone $clone -Message 'Nothing' -NewBranch 'update-rulebook-system-files/main/261007120002'
        $result.Pushed | Should-BeFalse
        $result.Reason | Should-Be 'no-changes'
        $result.FallbackReason | Should-BeNull
        (Get-GitText -Root $bare -Arguments @('branch', '--list')) | Should-NotMatchString 'update-rulebook-system-files'
    }

    It 'creates the scan branch with -Force' {
        $clone = New-GitHubClone -RemoteUrl $bare -Branch 'main' -Path (Get-TestFolder)
        Write-FixtureText -Path (Join-Path $clone.Path 'catalog' 'scan-state.json') -Text '{ "version": 1, "packages": {} }'
        $result = Publish-GitHubChange -Clone $clone -Message 'Scan 1' -NewBranch 'scan-diagnostics/main' -Force
        $result.Branch | Should-Be 'scan-diagnostics/main'
        (Get-GitText -Root $bare -Arguments @('rev-parse', 'refs/heads/scan-diagnostics/main')).Trim() | Should-Be $result.Sha
        (Get-GitText -Root $bare -Arguments @('rev-parse', "$($result.Sha)~1")).Trim() | Should-Be $mainSha
    }

    It 'replaces the scan branch with one commit above main' {
        $first = New-GitHubClone -RemoteUrl $bare -Branch 'main' -Path (Get-TestFolder)
        Write-FixtureText -Path (Join-Path $first.Path 'a.txt') -Text 'first'
        $null = Publish-GitHubChange -Clone $first -Message 'Scan 1' -NewBranch 'scan-diagnostics/main' -Force
        $second = New-GitHubClone -RemoteUrl $bare -Branch 'main' -Path (Get-TestFolder)
        Write-FixtureText -Path (Join-Path $second.Path 'b.txt') -Text 'second'
        $result = Publish-GitHubChange -Clone $second -Message 'Scan 2' -NewBranch 'scan-diagnostics/main' -Force
        (Get-GitText -Root $bare -Arguments @('rev-parse', 'refs/heads/scan-diagnostics/main')).Trim() | Should-Be $result.Sha
        (Get-GitText -Root $bare -Arguments @('rev-list', '--count', 'main..scan-diagnostics/main')).Trim() | Should-Be '1'
        (Get-GitText -Root $bare -Arguments @('ls-tree', '--name-only', 'scan-diagnostics/main')) | Should-NotMatchString 'a\.txt'
    }

    It 'rejects the push when the branch moved after the lease was read' {
        $first = New-GitHubClone -RemoteUrl $bare -Branch 'main' -Path (Get-TestFolder)
        Write-FixtureText -Path (Join-Path $first.Path 'a.txt') -Text 'first'
        $pushed = Publish-GitHubChange -Clone $first -Message 'Scan 1' -NewBranch 'scan-diagnostics/main' -Force
        $second = New-GitHubClone -RemoteUrl $bare -Branch 'main' -Path (Get-TestFolder)
        Write-FixtureText -Path (Join-Path $second.Path 'b.txt') -Text 'second'
        # Someone pushes to the branch after the lease was read: the pre-push hook of the clone moves the remote
        # branch back to main (with hooks off, so it does not run itself), so the lease no longer matches.
        $hook = Join-Path $second.Path '.git' 'hooks' 'pre-push'
        $script = "#!/bin/sh`ngit -c core.hooksPath=no-hooks push -q --force origin $($mainSha):refs/heads/scan-diagnostics/main`n"
        [System.IO.File]::WriteAllText($hook, $script, $utf8)
        if (-not $IsWindows) { [System.IO.File]::SetUnixFileMode($hook, [System.IO.UnixFileMode]'UserRead, UserWrite, UserExecute, GroupRead, GroupExecute, OtherRead, OtherExecute') }
        { Publish-GitHubChange -Clone $second -Message 'Scan 2' -NewBranch 'scan-diagnostics/main' -Force } | Should-Throw -ExceptionMessage 'git push --force-with-lease scan-diagnostics/main failed*'
        (Get-GitText -Root $bare -Arguments @('rev-parse', 'refs/heads/scan-diagnostics/main')).Trim() | Should-Be $mainSha
        $pushed.Sha | Should-NotBe $mainSha
    }

    It 'falls back to the scan branch with -Force when the direct push is refused' {
        Add-RejectPushHook -BarePath $bare -Branch 'main'
        $clone = New-GitHubClone -RemoteUrl $bare -Branch 'main' -Path (Get-TestFolder)
        Write-FixtureText -Path (Join-Path $clone.Path 'c.txt') -Text 'direct'
        $result = Publish-GitHubChange -Clone $clone -Message 'Scan' -NewBranch 'scan-diagnostics/main' -DirectCommit -Force
        $result.Fallback | Should-BeTrue
        $result.FallbackReason | Should-BeLikeString '*main is protected*'
        $result.Branch | Should-Be 'scan-diagnostics/main'
        (Get-GitText -Root $bare -Arguments @('rev-parse', 'refs/heads/main')).Trim() | Should-Be $mainSha
    }
}
