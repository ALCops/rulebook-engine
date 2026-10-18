#requires -Version 7.4
# Rulebook.GitHub: the GitHub plumbing of the update workflow (WP07). One REST wrapper (Invoke-GitHubApi, the single
# mock point of the suites), the GHTOKENWORKFLOW exchange (a personal access token passes through, GitHub App JSON
# becomes a short-lived installation token, D44), the template download as a zipball, the pull request helpers,
# and the clone, commit and push of the update and of the scan (WP08: the living pull request, a lease push). The
# issue path of the dashboard (WP15) adds the issue helpers: read an issue, the author's permission, comment, close,
# the rulebook-change label, and the duplicate guard over open pull requests by head prefix.
# Imports only Rulebook.Common (git runner, ordinal collections), nothing from the rulebook logic or the action
# layer. The token never enters a git URL or git config:
# git receives it as an http.<server>/.extraheader through GIT_CONFIG_COUNT in the environment of each git call.
# Contract: docs/reference/update-mechanics.md section 6 and 8. Ported from AL-Go (Github-Helper.psm1,
# AL-Go-Helper.ps1), behaviour only: docs/reference/al-go-template-mechanics.md sections 5.5 and 8.

Set-StrictMode -Version 3.0
Import-Module (Join-Path $PSScriptRoot 'Rulebook.Common.psd1')

$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$script:DefaultPermissions = [ordered]@{
    contents      = 'write'
    pull_requests = 'write'
    workflows     = 'write'
    actions       = 'read'
    metadata      = 'read'
}
# The user page the token errors point to; the URL is built at call time from the engine ref (Get-RulebookDocsUrl,
# D52, D53: main at @v1, preview at @main).
$script:TokenDocsPage = 'ghtokenworkflow.md'

#region Internal helpers

function Get-ResponseText {
    # The body of an Invoke-WebRequest response as UTF-8 text; Content is a string for text types, else bytes.
    param($Response)
    if ($null -eq $Response -or $null -eq $Response.PSObject.Properties['Content']) { return '' }
    # A direct assignment: an if expression would unroll a byte[] into object[].
    $content = $Response.Content
    if ($null -eq $content) { return '' }
    if ($content -is [byte[]]) { return $script:Utf8NoBom.GetString($content) }
    return [string]$content
}

function Get-ResponseHeader {
    # The first value of a response header, matched case-insensitively; $null when absent. Invoke-WebRequest returns
    # a Dictionary[string, IEnumerable[string]], which has no one-argument Contains, so the keys are enumerated.
    param($Response, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Response) { return $null }
    $property = $Response.PSObject.Properties['Headers']
    if ($null -eq $property -or $property.Value -isnot [System.Collections.IDictionary]) { return $null }
    foreach ($key in @($property.Value.Keys)) {
        if ([string]::Equals([string]$key, $Name, [System.StringComparison]::OrdinalIgnoreCase)) { return [string](@($property.Value[$key])[0]) }
    }
    return $null
}

function Get-DefaultApiUrl {
    param([AllowNull()][AllowEmptyString()][string]$ApiUrl)
    if (-not [string]::IsNullOrWhiteSpace($ApiUrl)) { return $ApiUrl.TrimEnd('/') }
    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_API_URL)) { return $env:GITHUB_API_URL.TrimEnd('/') }
    return 'https://api.github.com'
}

function Get-DefaultServerUrl {
    param([AllowNull()][AllowEmptyString()][string]$ServerUrl)
    if (-not [string]::IsNullOrWhiteSpace($ServerUrl)) { return $ServerUrl.TrimEnd('/') }
    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_SERVER_URL)) { return $env:GITHUB_SERVER_URL.TrimEnd('/') }
    return 'https://github.com'
}

function ConvertTo-Base64Url {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    return [System.Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function Get-ApiMessage {
    # The message of a GitHub error answer, or the start of the text when it is not JSON.
    param($Response)
    if ($null -eq $Response) { return '' }
    $body = $Response.Body
    if ($body -is [System.Collections.IDictionary] -and $body.Contains('message')) { return [string]$body['message'] }
    $text = [string]$Response.Text
    if ($text.Length -gt 200) { $text = $text.Substring(0, 200) }
    return $text.Trim()
}

function New-ApiException {
    # '<Message> (HTTP <status>: <GitHub message>)' with the status in Data['StatusCode'], as Get-GitHubBranchSha throws.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an exception; changes no state')]
    param([Parameter(Mandatory)][string]$Message, [Parameter(Mandatory)]$Response)
    $exception = [System.InvalidOperationException]::new("$Message (HTTP $($Response.StatusCode): $(Get-ApiMessage $Response))")
    $exception.Data['StatusCode'] = $Response.StatusCode
    return $exception
}

function Test-LabelExistsAnswer {
    # A 422 answer whose errors name the code already_exists (a label created in between).
    param([Parameter(Mandatory)]$Response)
    $errors = if ($Response.Body -is [System.Collections.IDictionary]) { @($Response.Body['errors']) } else { @() }
    return @($errors | Where-Object { $_ -is [System.Collections.IDictionary] -and [string]$_['code'] -ceq 'already_exists' }).Count -gt 0
}

function Get-DictionaryValue {
    # A key of a dictionary matched case-insensitively; $null when absent.
    param([System.Collections.IDictionary]$Dictionary, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Dictionary) { return $null }
    foreach ($key in @($Dictionary.Keys)) {
        if ([string]::Equals([string]$key, $Name, [System.StringComparison]::OrdinalIgnoreCase)) { return $Dictionary[$key] }
    }
    return $null
}

function Join-ApiPath {
    # A REST path from parts; each part is split at '/' and every segment escaped (EscapeDataString), so a branch such
    # as feature/x#1 or a name with '?' or '%' cannot end the path early or change the query.
    param([Parameter(Mandatory)][string[]]$Part)
    $segments = foreach ($item in $Part) { foreach ($segment in $item.Split('/')) { [System.Uri]::EscapeDataString($segment) } }
    return ($segments -join '/')
}

function Get-NextLink {
    # The rel="next" URL of a Link header, $null when there is none.
    param([AllowNull()][string]$Link)
    if ([string]::IsNullOrEmpty($Link)) { return $null }
    foreach ($part in $Link.Split(',')) {
        if ($part -match '<([^>]+)>\s*;\s*rel="next"') { return $Matches[1] }
    }
    return $null
}

function Assert-Git {
    # Invoke-Git that throws with the git error when the exit code is not 0.
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string[]]$Arguments,
        [System.Collections.IDictionary]$Environment,
        [Parameter(Mandatory)][string]$What
    )
    $result = Invoke-Git -Root $Root -Arguments $Arguments -Environment $Environment
    if ($result.ExitCode -ne 0) { throw "$What failed: $(($result.Error + $result.Output).Trim())" }
    return $result
}

function Get-GitAuthEnvironment {
    # The environment that gives git the token as an extra header for the server of RemoteUrl. Nothing for a local
    # path or an empty token.
    param([Parameter(Mandatory)][string]$RemoteUrl, [AllowNull()][AllowEmptyString()][string]$Token)
    $environment = [ordered]@{}
    if ([string]::IsNullOrEmpty($Token) -or $RemoteUrl -notmatch '^(https?://[^/]+)') { return $environment }
    $server = $Matches[1]
    $basic = [System.Convert]::ToBase64String($script:Utf8NoBom.GetBytes("x-access-token:$Token"))
    $environment['GIT_CONFIG_COUNT'] = '1'
    $environment['GIT_CONFIG_KEY_0'] = "http.$server/.extraheader"
    $environment['GIT_CONFIG_VALUE_0'] = "AUTHORIZATION: basic $basic"
    return $environment
}

#endregion

#region REST

function Invoke-GitHubApi {
    <#
    .SYNOPSIS
    One GitHub REST call: { StatusCode, Body, Text, Headers, RateLimitRemaining }.
    .DESCRIPTION
    -Path is relative to -ApiUrl (default GITHUB_API_URL, else https://api.github.com); -Uri is absolute (an
    access_tokens_url). Sends Accept application/vnd.github+json, X-GitHub-Api-Version 2022-11-28 and Bearer -Token
    when set; -Body is sent as compressed JSON (a string as it is). Body is the parsed JSON (dictionaries, arrays kept)
    when the answer is JSON, else $null. -OutFile writes the answer to that file. -Paginate follows Link rel="next"
    and concatenates the arrays. A non-2xx answer is returned, not thrown; only a request without an HTTP answer
    (DNS, connection refused, timeout) throws. The single mock point of the suites.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    [OutputType([pscustomobject])]
    param(
        [ValidateSet('GET', 'POST', 'PATCH', 'HEAD')][string]$Method = 'GET',
        [Parameter(Mandatory, ParameterSetName = 'Path')][string]$Path,
        [Parameter(Mandatory, ParameterSetName = 'Uri')][string]$Uri,
        [AllowNull()][AllowEmptyString()][string]$Token,
        [AllowNull()]$Body,
        [AllowNull()][AllowEmptyString()][string]$ApiUrl,
        [string]$OutFile,
        [switch]$Paginate,
        [int]$TimeoutSec = 30
    )
    $target = if ($PSCmdlet.ParameterSetName -eq 'Uri') { $Uri } else { (Get-DefaultApiUrl -ApiUrl $ApiUrl) + '/' + $Path.TrimStart('/') }
    $headers = @{ Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28' }
    if (-not [string]::IsNullOrEmpty($Token)) { $headers.Authorization = "Bearer $Token" }
    $request = @{ Method = $Method; Headers = $headers; TimeoutSec = $TimeoutSec; SkipHttpErrorCheck = $true; ErrorAction = 'Stop' }
    if ($null -ne $Body) {
        $request.Body = if ($Body -is [string]) { $Body } else { ConvertTo-Json -InputObject $Body -Compress -Depth 10 }
        $request.ContentType = 'application/json; charset=utf-8'
    }
    if ($OutFile) {
        $request.OutFile = $OutFile
        $request.PassThru = $true
    }

    $items = [System.Collections.Generic.List[object]]::new()
    while ($true) {
        $response = Invoke-WebRequest -Uri $target @request
        $status = [int]$response.StatusCode
        $text = if ($OutFile) { '' } else { Get-ResponseText $response }
        $parsed = $null
        $trimmed = $text.TrimStart()
        if ($trimmed.StartsWith('{') -or $trimmed.StartsWith('[')) {
            try { $parsed = ConvertFrom-Json -InputObject $text -AsHashtable -NoEnumerate -Depth 20 -ErrorAction Stop } catch { $parsed = $null }
        }
        $remaining = Get-ResponseHeader $response 'X-RateLimit-Remaining'
        $result = [pscustomobject]@{
            StatusCode         = $status
            Body               = $parsed
            Text               = $text
            Headers            = $response.Headers
            RateLimitRemaining = $remaining
        }
        # A failing page ends the walk with that answer; the caller sees its status.
        if (-not $Paginate -or $status -lt 200 -or $status -ge 300) { return $result }
        if ($parsed -is [System.Collections.IList]) { foreach ($item in $parsed) { $items.Add($item) } } elseif ($null -ne $parsed) { $items.Add($parsed) }
        $next = Get-NextLink -Link (Get-ResponseHeader $response 'Link')
        if ($null -eq $next) { break }
        $target = $next
    }
    $result.Body = $items.ToArray()
    return $result
}

#endregion

#region Token

function New-GitHubAppJwt {
    <#
    .SYNOPSIS
    The JWT a GitHub App signs to ask for an installation token: base64url header.payload.signature.
    .DESCRIPTION
    Header { alg RS256, typ JWT }, payload { iat now-60, exp now+600, iss -ClientId }, RSASSA-PKCS1-v1_5 SHA-256 with
    -PrivateKey (PEM; the line breaks of the AL-Go compressed-JSON secret may be missing). -Now is a test seam.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Computes a string; changes no state')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$PrivateKey,
        [System.DateTimeOffset]$Now = [System.DateTimeOffset]::UtcNow
    )
    $pem = $PrivateKey.Trim()
    # A PEM joined into one line (AL-Go's one-liner) gets its line breaks back; the base64 body ignores whitespace.
    if ($pem -match '(?s)^(-----BEGIN [A-Z0-9 ]+-----)\s*(.*?)\s*(-----END [A-Z0-9 ]+-----)$') {
        $pem = "$($Matches[1])`n$(($Matches[2] -replace '\s', ''))`n$($Matches[3])"
    } else {
        throw "The PrivateKey of the GitHub App $ClientId is not a PEM key (-----BEGIN ... PRIVATE KEY-----)."
    }
    $header = ConvertTo-Base64Url -Bytes $script:Utf8NoBom.GetBytes('{"alg":"RS256","typ":"JWT"}')
    $claims = '{{"iat":{0},"exp":{1},"iss":{2}}}' -f $Now.AddSeconds(-60).ToUnixTimeSeconds(), $Now.AddSeconds(600).ToUnixTimeSeconds(), (ConvertTo-Json -InputObject $ClientId -Compress)
    $payload = ConvertTo-Base64Url -Bytes $script:Utf8NoBom.GetBytes($claims)
    $rsa = [System.Security.Cryptography.RSA]::Create()
    try {
        try {
            $rsa.ImportFromPem($pem)
        } catch {
            throw "The PrivateKey of the GitHub App $ClientId cannot be read: $($_.Exception.Message)"
        }
        $signature = $rsa.SignData($script:Utf8NoBom.GetBytes("$header.$payload"), [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    } finally {
        $rsa.Dispose()
    }
    return "$header.$payload.$(ConvertTo-Base64Url -Bytes $signature)"
}

function Get-GitHubAccessToken {
    <#
    .SYNOPSIS
    The write token from the GHTOKENWORKFLOW value: { Token, Kind (none, pat, app), ExpiresAt }.
    .DESCRIPTION
    Empty gives Kind none. A value that does not start with '{' is a personal access token and is returned as it is,
    without a request. GitHub App JSON { GitHubAppClientId, PrivateKey } (AL-Go format, D44) is exchanged: GET
    /repos/{repository}/installation with the app JWT, then POST its access_tokens_url limited to this repository and
    -Permissions (default contents, pull_requests, workflows write; actions, metadata read). A failed exchange throws
    with the HTTP status, the message and the client id. Never prints the token; the caller masks it.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()][AllowEmptyString()][string]$Token,
        [Parameter(Mandatory)][string]$Repository,
        [AllowNull()][AllowEmptyString()][string]$ApiUrl,
        [System.Collections.IDictionary]$Permissions = $script:DefaultPermissions
    )
    $value = if ($null -eq $Token) { '' } else { $Token.Trim() }
    if ($value -eq '') { return [pscustomobject]@{ Token = ''; Kind = 'none'; ExpiresAt = $null } }
    if (-not $value.StartsWith('{')) { return [pscustomobject]@{ Token = $value; Kind = 'pat'; ExpiresAt = $null } }
    $docsUrl = Get-RulebookDocsUrl -Page $script:TokenDocsPage
    try {
        $app = ConvertFrom-Json -InputObject $value -AsHashtable -ErrorAction Stop
    } catch {
        throw "The token secret starts with '{' but is not JSON. Use a personal access token or the compressed JSON {`"GitHubAppClientId`":`"...`",`"PrivateKey`":`"...`"}; see $docsUrl"
    }
    $clientId = [string](Get-DictionaryValue -Dictionary $app -Name 'GitHubAppClientId')
    $privateKey = [string](Get-DictionaryValue -Dictionary $app -Name 'PrivateKey')
    if ([string]::IsNullOrEmpty($clientId) -or [string]::IsNullOrEmpty($privateKey)) {
        throw "The GitHub App JSON in the token secret needs GitHubAppClientId and PrivateKey; see $docsUrl"
    }
    $jwt = New-GitHubAppJwt -ClientId $clientId -PrivateKey $privateKey
    $installation = Invoke-GitHubApi -Method GET -Path (Join-ApiPath -Part 'repos', $Repository, 'installation') -Token $jwt -ApiUrl $ApiUrl
    if ($installation.StatusCode -ne 200 -or $installation.Body -isnot [System.Collections.IDictionary] -or -not $installation.Body.Contains('access_tokens_url')) {
        throw "The GitHub App $clientId has no installation on $Repository (HTTP $($installation.StatusCode): $(Get-ApiMessage $installation)). Install the app on the repository; see $docsUrl"
    }
    $name = $Repository.Substring($Repository.LastIndexOf('/') + 1)
    $body = [ordered]@{ repositories = @($name); permissions = $Permissions }
    $access = Invoke-GitHubApi -Method POST -Uri ([string]$installation.Body['access_tokens_url']) -Token $jwt -Body $body
    if ($access.StatusCode -ne 201 -and $access.StatusCode -ne 200) {
        throw "The GitHub App $clientId could not get an installation token for $Repository (HTTP $($access.StatusCode): $(Get-ApiMessage $access)). Check the app's repository permissions; see $docsUrl"
    }
    $installationToken = [string](Get-DictionaryValue -Dictionary $access.Body -Name 'token')
    if ([string]::IsNullOrEmpty($installationToken)) { throw "The GitHub App $clientId got an answer without a token for $Repository." }
    return [pscustomobject]@{ Token = $installationToken; Kind = 'app'; ExpiresAt = (Get-DictionaryValue -Dictionary $access.Body -Name 'expires_at') }
}

#endregion

#region Template download

function Get-GitHubBranchSha {
    <#
    .SYNOPSIS
    The head commit (40 hex) of -Branch in -Repository (owner/name), from GET /repos/{r}/branches/{b}.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Branch,
        [AllowNull()][AllowEmptyString()][string]$Token,
        [AllowNull()][AllowEmptyString()][string]$ApiUrl
    )
    $response = Invoke-GitHubApi -Method GET -Path (Join-ApiPath -Part 'repos', $Repository, 'branches', $Branch) -Token $Token -ApiUrl $ApiUrl
    $sha = $null
    if ($response.StatusCode -eq 200 -and $response.Body -is [System.Collections.IDictionary]) {
        $commit = $response.Body['commit']
        if ($commit -is [System.Collections.IDictionary]) { $sha = [string]$commit['sha'] }
    }
    if ($response.StatusCode -ne 200 -or $sha -notmatch '^[0-9a-f]{40}$') {
        # The status travels in Data, so the caller can retry a private template with another token.
        $exception = [System.InvalidOperationException]::new("Could not get the latest commit of $(Get-DefaultServerUrl)/$Repository@$Branch (HTTP $($response.StatusCode): $(Get-ApiMessage $response))")
        $exception.Data['StatusCode'] = $response.StatusCode
        throw $exception
    }
    return $sha
}

function Get-GitHubRefSha {
    <#
    .SYNOPSIS
    The commit (40 hex) a template ref names in -Repository (owner/name): a branch first, then a tag.
    .DESCRIPTION
    Resolves -Ref as a branch (Get-GitHubBranchSha). Only when the branch answers 404 is it looked up as a tag through
    GET /repos/{r}/git/ref/tags/{ref}: a lightweight tag points at its commit, an annotated tag (object type 'tag') is
    dereferenced once through GET /repos/{r}/git/tags/{sha}. Any other branch status (401, 403, 5xx) throws at once,
    and a tag lookup that does not answer 200 rethrows the branch error unchanged (message and Data['StatusCode']
    404), so a private template is retried with another token as before. A failed dereference of an annotated tag
    throws with its own status in Data['StatusCode']. The organization branch keeps Get-GitHubBranchSha: a tag is no
    target there.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Ref,
        [AllowNull()][AllowEmptyString()][string]$Token,
        [AllowNull()][AllowEmptyString()][string]$ApiUrl
    )
    try {
        return Get-GitHubBranchSha -Repository $Repository -Branch $Ref -Token $Token -ApiUrl $ApiUrl
    } catch {
        $branchError = $_
        if ($branchError.Exception.Data['StatusCode'] -ne 404) { throw }
    }
    $response = Invoke-GitHubApi -Method GET -Path (Join-ApiPath -Part 'repos', $Repository, 'git/ref/tags', $Ref) -Token $Token -ApiUrl $ApiUrl
    $object = $null
    if ($response.StatusCode -eq 200 -and $response.Body -is [System.Collections.IDictionary] -and $response.Body['object'] -is [System.Collections.IDictionary]) {
        $object = $response.Body['object']
    }
    if ($null -eq $object) { throw $branchError }
    $type = [string]$object['type']
    $sha = [string]$object['sha']
    $status = $response.StatusCode
    $what = $null
    if ($type -ceq 'tag' -and $sha -match '^[0-9a-f]{40}$') {
        # An annotated tag: its tag object names the commit (one level; a tag of a tag is not followed).
        $response = Invoke-GitHubApi -Method GET -Path (Join-ApiPath -Part 'repos', $Repository, 'git/tags', $sha) -Token $Token -ApiUrl $ApiUrl
        $status = $response.StatusCode
        $type = $null
        $sha = $null
        if ($status -ne 200) {
            $what = "HTTP $($status): $(Get-ApiMessage $response)"
        } elseif ($response.Body -isnot [System.Collections.IDictionary] -or $response.Body['object'] -isnot [System.Collections.IDictionary]) {
            $what = 'HTTP 200: an unexpected answer without the object of the annotated tag'
        } else {
            $type = [string]$response.Body['object']['type']
            $sha = [string]$response.Body['object']['sha']
            if ($type -ceq 'tag') { $what = "HTTP 200: the tag points to another tag object $sha, which is not supported" }
        }
    }
    if ($null -ne $what -or $type -cne 'commit' -or $sha -notmatch '^[0-9a-f]{40}$') {
        if ($null -eq $what) { $what = "HTTP $($status): the tag points to '$type' $sha, not a commit" }
        $exception = [System.InvalidOperationException]::new("Could not get the commit of the tag $(Get-DefaultServerUrl)/$Repository@$Ref ($what)")
        $exception.Data['StatusCode'] = $status
        throw $exception
    }
    return $sha
}

function Get-GitHubCommitList {
    <#
    .SYNOPSIS
    The commits of -Ref in -Repository (owner/name), newest first: { Commits = @({ Sha, TreeSha }), Truncated }.
    .DESCRIPTION
    GET /repos/{r}/commits?sha=<ref>&per_page=100&page=N for N = 1 to -MaxPages (no sha= for an empty -Ref: the
    default branch); a page with fewer than 100 commits is the last one. With -TreeSha the walk also stops after the
    page that holds a commit with one of those trees (the newest match is on the first such page). Truncated is $true
    when -MaxPages full pages were read without such a stop, so older commits may exist. A non-2xx
    answer throws with the status in Data['StatusCode'], as Get-GitHubBranchSha does. Used to recover the installed
    template commit from the tree of an organization repository's root commit (D50).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Repository,
        [AllowNull()][AllowEmptyString()][string]$Ref,
        [AllowNull()][AllowEmptyString()][string]$Token,
        [AllowNull()][AllowEmptyString()][string]$ApiUrl,
        [ValidateRange(1, 1000)][int]$MaxPages = 10,
        [AllowNull()][AllowEmptyCollection()][string[]]$TreeSha
    )
    $pageSize = 100
    $wanted = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($tree in @($TreeSha)) { if (-not [string]::IsNullOrEmpty($tree)) { [void]$wanted.Add($tree) } }
    $matched = $false
    $commits = [System.Collections.Generic.List[object]]::new()
    $truncated = $false
    for ($page = 1; $page -le $MaxPages; $page++) {
        $query = if ([string]::IsNullOrWhiteSpace($Ref)) { '' } else { "sha=$([System.Uri]::EscapeDataString($Ref.Trim()))&" }
        $path = (Join-ApiPath -Part 'repos', $Repository, 'commits') + "?$($query)per_page=$pageSize&page=$page"
        $response = Invoke-GitHubApi -Method GET -Path $path -Token $Token -ApiUrl $ApiUrl
        if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300 -or $response.Body -isnot [System.Collections.IList]) {
            $exception = [System.InvalidOperationException]::new("Could not list the commits of $(Get-DefaultServerUrl)/$Repository$(if ($Ref) { "@$Ref" }) (HTTP $($response.StatusCode): $(Get-ApiMessage $response))")
            $exception.Data['StatusCode'] = $response.StatusCode
            throw $exception
        }
        foreach ($item in $response.Body) {
            if ($item -isnot [System.Collections.IDictionary]) { continue }
            $commit = $item['commit']
            $tree = if ($commit -is [System.Collections.IDictionary] -and $commit['tree'] -is [System.Collections.IDictionary]) { [string]$commit['tree']['sha'] } else { $null }
            $commits.Add([pscustomobject]@{ Sha = [string]$item['sha']; TreeSha = $tree })
            if ($null -ne $tree -and $wanted.Contains($tree)) { $matched = $true }
        }
        if ($matched -or $response.Body.Count -lt $pageSize) { break }
        if ($page -eq $MaxPages) { $truncated = $true }
    }
    return [pscustomobject]@{ Commits = $commits.ToArray(); Truncated = $truncated }
}

function Save-GitHubZipball {
    <#
    .SYNOPSIS
    Downloads GET /repos/{r}/zipball/{sha} and extracts it into -Path; returns the extracted root folder.
    .DESCRIPTION
    The zip is written to <Path>.zip, extracted with ZipFile.ExtractToDirectory and deleted. GitHub puts everything
    under one folder <owner>-<repo>-<sha7>/; that folder is returned (-Path itself when the zip has another shape).
    A non-2xx answer throws with the status, so the caller can retry with another token.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Sha,
        [AllowNull()][AllowEmptyString()][string]$Token,
        [Parameter(Mandatory)][string]$Path,
        [AllowNull()][AllowEmptyString()][string]$ApiUrl
    )
    $Path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $zip = "$Path.zip"
    $parent = Split-Path -Parent $zip
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { [void][System.IO.Directory]::CreateDirectory($parent) }
    try {
        $response = Invoke-GitHubApi -Method GET -Path (Join-ApiPath -Part 'repos', $Repository, 'zipball', $Sha) -Token $Token -ApiUrl $ApiUrl -OutFile $zip -TimeoutSec 120
        if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) {
            $exception = [System.InvalidOperationException]::new("Could not download $Repository at $Sha (HTTP $($response.StatusCode))")
            $exception.Data['StatusCode'] = $response.StatusCode
            throw $exception
        }
        if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Recurse -Force }
        [void][System.IO.Directory]::CreateDirectory($Path)
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $Path)
    } finally {
        if (Test-Path -LiteralPath $zip -PathType Leaf) { Remove-Item -LiteralPath $zip -Force }
    }
    $folders = @(Get-ChildItem -LiteralPath $Path -Directory -Force)
    $files = @(Get-ChildItem -LiteralPath $Path -File -Force)
    if ($folders.Count -eq 1 -and $files.Count -eq 0) { return $folders[0].FullName }
    return $Path
}

#endregion

#region Pull requests

function Find-GitHubPullRequest {
    <#
    .SYNOPSIS
    The first open pull request into -Base whose title equals -Title (ordinal), or $null: { Number, Url, Title }.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Base,
        [Parameter(Mandatory)][string]$Title,
        [AllowNull()][AllowEmptyString()][string]$Token,
        [AllowNull()][AllowEmptyString()][string]$ApiUrl
    )
    $query = 'base={0}&state=open&per_page=100' -f [System.Uri]::EscapeDataString($Base)
    $response = Invoke-GitHubApi -Method GET -Path ((Join-ApiPath -Part 'repos', $Repository, 'pulls') + "?$query") -Token $Token -ApiUrl $ApiUrl -Paginate
    if ($response.StatusCode -ne 200) { throw "Could not list the pull requests of $Repository (HTTP $($response.StatusCode): $(Get-ApiMessage $response))" }
    foreach ($pull in @($response.Body)) {
        if ($pull -is [System.Collections.IDictionary] -and [string]::Equals([string]$pull['title'], $Title, [System.StringComparison]::Ordinal)) {
            return [pscustomobject]@{ Number = [int]$pull['number']; Url = [string]$pull['html_url']; Title = [string]$pull['title'] }
        }
    }
    return $null
}

function Find-GitHubPullRequestByHead {
    <#
    .SYNOPSIS
    The open pull request from branch -Head of -Repository into -Base, or $null: { Number, Url, Title, Body }.
    .DESCRIPTION
    GET /repos/{r}/pulls?state=open&head=<owner>:<head>&base=<base>; the first item wins. Used by the scan, whose
    living pull request is found by its fixed branch, not by its title.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Head,
        [Parameter(Mandatory)][string]$Base,
        [AllowNull()][AllowEmptyString()][string]$Token,
        [AllowNull()][AllowEmptyString()][string]$ApiUrl
    )
    $owner = $Repository.Substring(0, $Repository.IndexOf([char]'/'))
    $query = 'state=open&head={0}&base={1}&per_page=100' -f [System.Uri]::EscapeDataString("$($owner):$Head"), [System.Uri]::EscapeDataString($Base)
    $response = Invoke-GitHubApi -Method GET -Path ((Join-ApiPath -Part 'repos', $Repository, 'pulls') + "?$query") -Token $Token -ApiUrl $ApiUrl
    if ($response.StatusCode -ne 200) { throw "Could not list the pull requests of $Repository (HTTP $($response.StatusCode): $(Get-ApiMessage $response))" }
    foreach ($pull in @($response.Body)) {
        if ($pull -is [System.Collections.IDictionary]) {
            return [pscustomobject]@{ Number = [int]$pull['number']; Url = [string]$pull['html_url']; Title = [string]$pull['title']; Body = [string]$pull['body'] }
        }
    }
    return $null
}

function Update-GitHubPullRequest {
    <#
    .SYNOPSIS
    Replaces the title and body of pull request -Number, and with -State opens or closes it: { Number, Url }.
    .DESCRIPTION
    PATCH /repos/{r}/pulls/{n} with { title, body[, state] }; an answer other than 200 throws with the status and the
    message.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Called only by a scan that validated and pushed; a dry run never calls it')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][int]$Number,
        [Parameter(Mandatory)][string]$Title,
        [AllowNull()][AllowEmptyString()][string]$Body,
        [ValidateSet('open', 'closed')][string]$State,
        [AllowNull()][AllowEmptyString()][string]$Token,
        [AllowNull()][AllowEmptyString()][string]$ApiUrl
    )
    $request = [ordered]@{ title = $Title; body = $(if ($null -eq $Body) { '' } else { $Body }) }
    if ($State) { $request.state = $State }
    $response = Invoke-GitHubApi -Method PATCH -Path (Join-ApiPath -Part 'repos', $Repository, 'pulls', ([string]$Number)) -Token $Token -ApiUrl $ApiUrl -Body $request
    if ($response.StatusCode -ne 200) { throw "Could not update pull request #$Number of $Repository (HTTP $($response.StatusCode): $(Get-ApiMessage $response))" }
    $url = if ($response.Body -is [System.Collections.IDictionary]) { [string]$response.Body['html_url'] } else { '' }
    return [pscustomobject]@{ Number = $Number; Url = $url }
}

function New-GitHubPullRequest {
    <#
    .SYNOPSIS
    Opens a pull request from -Head into -Base and adds -Labels: { Number, Url }.
    .DESCRIPTION
    POST /repos/{r}/pulls, then POST /repos/{r}/issues/{n}/labels when labels are given (a failure there is a
    warning; the pull request exists). A refused creation throws; a 403 names the token and the settings that allow
    pull requests from GitHub Actions, and links <server>/<r>/tree/<head> so the pull request can be opened by hand.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Called only in update mode, after the plan validated; check mode never calls it')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Repository,
        [AllowNull()][AllowEmptyString()][string]$Token,
        [Parameter(Mandatory)][string]$Title,
        [AllowNull()][AllowEmptyString()][string]$Body,
        [Parameter(Mandatory)][string]$Head,
        [Parameter(Mandatory)][string]$Base,
        [AllowNull()][AllowEmptyCollection()][string[]]$Labels,
        [AllowNull()][AllowEmptyString()][string]$ApiUrl,
        [AllowNull()][AllowEmptyString()][string]$ServerUrl
    )
    $request = [ordered]@{ title = $Title; head = $Head; base = $Base; body = $(if ($null -eq $Body) { '' } else { $Body }) }
    $response = Invoke-GitHubApi -Method POST -Path (Join-ApiPath -Part 'repos', $Repository, 'pulls') -Token $Token -ApiUrl $ApiUrl -Body $request
    if ($response.StatusCode -ne 201) {
        $manual = "$(Get-DefaultServerUrl -ServerUrl $ServerUrl)/$(Join-ApiPath -Part $Repository, 'tree', $Head)"
        if ($response.StatusCode -eq 403) {
            throw "The token is not allowed to create pull requests in $Repository (HTTP 403: $(Get-ApiMessage $response)). Check that it has pull_requests write, or that GitHub Actions may create pull requests (organization and repository Settings > Actions > General). You can create the pull request by hand from $manual"
        }
        throw "Could not create the pull request in $Repository (HTTP $($response.StatusCode): $(Get-ApiMessage $response)). You can create it by hand from $manual"
    }
    $number = [int]$response.Body['number']
    $url = [string]$response.Body['html_url']
    $labelList = @($Labels | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($labelList.Count -gt 0) {
        $labelResponse = Invoke-GitHubApi -Method POST -Path (Join-ApiPath -Part 'repos', $Repository, 'issues', ([string]$number), 'labels') -Token $Token -ApiUrl $ApiUrl -Body ([ordered]@{ labels = $labelList })
        if ($labelResponse.StatusCode -lt 200 -or $labelResponse.StatusCode -ge 300) {
            Write-Warning "Pull request $url was created, but the labels $($labelList -join ', ') were not added (HTTP $($labelResponse.StatusCode): $(Get-ApiMessage $labelResponse))."
        }
    }
    return [pscustomobject]@{ Number = $number; Url = $url }
}

function Find-GitHubPullRequestByHeadPrefix {
    <#
    .SYNOPSIS
    The first open pull request into -Base whose head branch starts with -HeadPrefix (ordinal), or $null:
    { Number, Url, Title, Head }.
    .DESCRIPTION
    GET /repos/{r}/pulls?base=<base>&state=open&per_page=100, every page (Link rel="next"); the prefix is matched on
    head.ref on this side, because the API filters the head by its exact name only, and only for a head branch of
    -Repository itself (head.repo.full_name, ignoring case as GitHub does; a fork's branch or a deleted fork never
    matches). The duplicate guard of the issue path (rulebook-change/<issue>/): end the prefix with '/' so issue 12
    does not match rulebook-change/123/. An answer other than 200 throws with the status in Data['StatusCode'].
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Base,
        [Parameter(Mandatory)][string]$HeadPrefix,
        [AllowNull()][AllowEmptyString()][string]$Token,
        [AllowNull()][AllowEmptyString()][string]$ApiUrl
    )
    $query = 'base={0}&state=open&per_page=100' -f [System.Uri]::EscapeDataString($Base)
    $response = Invoke-GitHubApi -Method GET -Path ((Join-ApiPath -Part 'repos', $Repository, 'pulls') + "?$query") -Token $Token -ApiUrl $ApiUrl -Paginate
    if ($response.StatusCode -ne 200) { throw (New-ApiException -Message "Could not list the pull requests of $Repository" -Response $response) }
    foreach ($pull in @($response.Body)) {
        if ($pull -isnot [System.Collections.IDictionary] -or $pull['head'] -isnot [System.Collections.IDictionary]) { continue }
        # Only a branch of this repository: a fork may name a branch rulebook-change/12/x too, and a pull request
        # whose fork was deleted has no head repository.
        $headRepository = $pull['head']['repo']
        if ($headRepository -isnot [System.Collections.IDictionary] -or -not [string]::Equals([string]$headRepository['full_name'], $Repository, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        $head = [string]$pull['head']['ref']
        if ($head.StartsWith($HeadPrefix, [System.StringComparison]::Ordinal)) {
            return [pscustomobject]@{ Number = [int]$pull['number']; Url = [string]$pull['html_url']; Title = [string]$pull['title']; Head = $head }
        }
    }
    return $null
}

#endregion

#region Issues

function Get-GitHubIssue {
    <#
    .SYNOPSIS
    Issue -Number of -Repository: { Number, Title, Body, State, StateReason, Author, AuthorType, AuthorAssociation,
    Labels, Url, IsPullRequest }.
    .DESCRIPTION
    GET /repos/{r}/issues/{n}. Body is '' for an issue without one; Labels are the label names; Author and AuthorType
    are user.login and user.type (User, Bot); IsPullRequest is true when the number is a pull request (the issues API
    answers for both). An answer other than 200 throws with the status in Data['StatusCode'].
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][int]$Number,
        [AllowNull()][AllowEmptyString()][string]$Token,
        [AllowNull()][AllowEmptyString()][string]$ApiUrl
    )
    $response = Invoke-GitHubApi -Method GET -Path (Join-ApiPath -Part 'repos', $Repository, 'issues', ([string]$Number)) -Token $Token -ApiUrl $ApiUrl
    if ($response.StatusCode -ne 200 -or $response.Body -isnot [System.Collections.IDictionary]) { throw (New-ApiException -Message "Could not read issue #$Number of $Repository" -Response $response) }
    $issue = $response.Body
    $user = if ($issue['user'] -is [System.Collections.IDictionary]) { $issue['user'] } else { @{} }
    $labels = [string[]]@(@($issue['labels']) | ForEach-Object {
            if ($_ -is [System.Collections.IDictionary]) { [string]$_['name'] } elseif ($null -ne $_) { [string]$_ }
        })
    return [pscustomobject]@{
        PSTypeName        = 'Rulebook.GitHubIssue'
        Number            = [int]$issue['number']
        Title             = [string]$issue['title']
        Body              = [string]$issue['body']
        State             = [string]$issue['state']
        StateReason       = $(if ($null -eq $issue['state_reason']) { $null } else { [string]$issue['state_reason'] })
        Author            = [string]$user['login']
        AuthorType        = [string]$user['type']
        AuthorAssociation = [string]$issue['author_association']
        Labels            = $labels
        Url               = [string]$issue['html_url']
        IsPullRequest     = $issue.Contains('pull_request') -and $null -ne $issue['pull_request']
    }
}

function Get-GitHubUserPermission {
    <#
    .SYNOPSIS
    The permission of -User on -Repository: { Permission (admin, write, read, none), RoleName }.
    .DESCRIPTION
    GET /repos/{r}/collaborators/{user}/permission. As GitHub documents it (not observed here): the highest grant
    across the repository, its teams, the organization and the enterprise, maintain reported as write and triage as
    read (RoleName is the exact role), readable with metadata read. A 404 (the user is no collaborator or does not
    exist, or, by the same documentation, the token cannot read the collaborators, which would refuse everyone) is
    Permission none and RoleName $null, so a gate on it fails closed; any other answer than 200 throws with the status
    in Data['StatusCode'].
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$User,
        [AllowNull()][AllowEmptyString()][string]$Token,
        [AllowNull()][AllowEmptyString()][string]$ApiUrl
    )
    $response = Invoke-GitHubApi -Method GET -Path (Join-ApiPath -Part 'repos', $Repository, 'collaborators', $User, 'permission') -Token $Token -ApiUrl $ApiUrl
    if ($response.StatusCode -eq 404) { return [pscustomobject]@{ Permission = 'none'; RoleName = $null } }
    if ($response.StatusCode -ne 200 -or $response.Body -isnot [System.Collections.IDictionary]) { throw (New-ApiException -Message "Could not read the permission of $User on $Repository" -Response $response) }
    $permission = [string]$response.Body['permission']
    if ([string]::IsNullOrEmpty($permission)) { $permission = 'none' }
    $role = if ($null -eq $response.Body['role_name']) { $null } else { [string]$response.Body['role_name'] }
    return [pscustomobject]@{ Permission = $permission; RoleName = $role }
}

function Add-GitHubIssueComment {
    <#
    .SYNOPSIS
    Comments -Body on issue -Number of -Repository: { Id, Url }.
    .DESCRIPTION
    POST /repos/{r}/issues/{n}/comments with { body }. An answer other than 201 throws with the status in
    Data['StatusCode'].
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][int]$Number,
        [Parameter(Mandatory)][string]$Body,
        [AllowNull()][AllowEmptyString()][string]$Token,
        [AllowNull()][AllowEmptyString()][string]$ApiUrl
    )
    $response = Invoke-GitHubApi -Method POST -Path (Join-ApiPath -Part 'repos', $Repository, 'issues', ([string]$Number), 'comments') -Token $Token -ApiUrl $ApiUrl -Body ([ordered]@{ body = $Body })
    if ($response.StatusCode -ne 201) { throw (New-ApiException -Message "Could not comment on issue #$Number of $Repository" -Response $response) }
    $answer = if ($response.Body -is [System.Collections.IDictionary]) { $response.Body } else { @{} }
    return [pscustomobject]@{ Id = $answer['id']; Url = [string]$answer['html_url'] }
}

function Get-GitHubIssueComments {
    <#
    .SYNOPSIS
    The comments of issue -Number of -Repository, oldest first, one object each: { Id, Author, AuthorType, Body, Url };
    nothing for an issue without comments.
    .DESCRIPTION
    GET /repos/{r}/issues/{n}/comments?per_page=100, every page (Link rel="next"), in the order GitHub lists them
    (ascending by creation). Body is '' for a comment without one; Author and AuthorType are user.login and user.type
    (User, Bot). The repeat check of the issue path reads the most recent one. An answer other than 200 throws with
    the status in Data['StatusCode'].
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Returns every comment of the issue')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][int]$Number,
        [AllowNull()][AllowEmptyString()][string]$Token,
        [AllowNull()][AllowEmptyString()][string]$ApiUrl
    )
    $path = (Join-ApiPath -Part 'repos', $Repository, 'issues', ([string]$Number), 'comments') + '?per_page=100'
    $response = Invoke-GitHubApi -Method GET -Path $path -Token $Token -ApiUrl $ApiUrl -Paginate
    if ($response.StatusCode -ne 200) { throw (New-ApiException -Message "Could not read the comments of issue #$Number of $Repository" -Response $response) }
    foreach ($comment in @($response.Body)) {
        if ($comment -isnot [System.Collections.IDictionary]) { continue }
        $user = if ($comment['user'] -is [System.Collections.IDictionary]) { $comment['user'] } else { @{} }
        [pscustomobject]@{
            Id         = $comment['id']
            Author     = [string]$user['login']
            AuthorType = [string]$user['type']
            Body       = [string]$comment['body']
            Url        = [string]$comment['html_url']
        }
    }
}

function Close-GitHubIssue {
    <#
    .SYNOPSIS
    Closes issue -Number of -Repository with -StateReason completed or not_planned: { Number, Url }.
    .DESCRIPTION
    PATCH /repos/{r}/issues/{n} with { state closed, state_reason }. An answer other than 200 throws with the status
    in Data['StatusCode'].
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][int]$Number,
        [Parameter(Mandatory)][ValidateSet('completed', 'not_planned')][string]$StateReason,
        [AllowNull()][AllowEmptyString()][string]$Token,
        [AllowNull()][AllowEmptyString()][string]$ApiUrl
    )
    $response = Invoke-GitHubApi -Method PATCH -Path (Join-ApiPath -Part 'repos', $Repository, 'issues', ([string]$Number)) -Token $Token -ApiUrl $ApiUrl -Body ([ordered]@{ state = 'closed'; state_reason = $StateReason })
    if ($response.StatusCode -ne 200) { throw (New-ApiException -Message "Could not close issue #$Number of $Repository" -Response $response) }
    $url = if ($response.Body -is [System.Collections.IDictionary]) { [string]$response.Body['html_url'] } else { '' }
    return [pscustomobject]@{ Number = $Number; Url = $url }
}

function Confirm-GitHubLabel {
    <#
    .SYNOPSIS
    Makes sure label -Name exists in -Repository, and with -IssueNumber adds it to that issue: { Created, Added }.
    .DESCRIPTION
    GET /repos/{r}/labels/{name}; a 404 creates it with POST /repos/{r}/labels { name, color, description } (Created
    $true; a 422 already_exists, a run that created it in between, is accepted). With -IssueNumber the label is added
    with POST /repos/{r}/issues/{n}/labels (Added $true). Any other answer throws with the status in
    Data['StatusCode']. The rulebook-change label of the issue path: an issue opened from the form carries it only once
    it exists.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Name,
        [ValidatePattern('^[0-9A-Fa-f]{6}$')][string]$Color = '1D76DB',
        [AllowEmptyString()][string]$Description = 'A change set submitted from the Rulebook dashboard',
        [ValidateRange(1, [int]::MaxValue)][int]$IssueNumber,
        [AllowNull()][AllowEmptyString()][string]$Token,
        [AllowNull()][AllowEmptyString()][string]$ApiUrl
    )
    $result = [pscustomobject]@{ Created = $false; Added = $false }
    $existing = Invoke-GitHubApi -Method GET -Path (Join-ApiPath -Part 'repos', $Repository, 'labels', $Name) -Token $Token -ApiUrl $ApiUrl
    if ($existing.StatusCode -eq 404) {
        $created = Invoke-GitHubApi -Method POST -Path (Join-ApiPath -Part 'repos', $Repository, 'labels') -Token $Token -ApiUrl $ApiUrl -Body ([ordered]@{ name = $Name; color = $Color; description = $Description })
        if ($created.StatusCode -eq 201) {
            $result.Created = $true
        } elseif (-not ($created.StatusCode -eq 422 -and (Test-LabelExistsAnswer -Response $created))) {
            throw (New-ApiException -Message "Could not create the label $Name in $Repository" -Response $created)
        }
    } elseif ($existing.StatusCode -ne 200) {
        throw (New-ApiException -Message "Could not read the label $Name of $Repository" -Response $existing)
    }
    if ($PSBoundParameters.ContainsKey('IssueNumber')) {
        $added = Invoke-GitHubApi -Method POST -Path (Join-ApiPath -Part 'repos', $Repository, 'issues', ([string]$IssueNumber), 'labels') -Token $Token -ApiUrl $ApiUrl -Body ([ordered]@{ labels = @($Name) })
        if ($added.StatusCode -ne 200) { throw (New-ApiException -Message "Could not add the label $Name to issue #$IssueNumber of $Repository" -Response $added) }
        $result.Added = $true
    }
    return $result
}

#endregion

#region Git

function Get-GitRootTree {
    <#
    .SYNOPSIS
    The tree shas of every root commit reachable from HEAD in the git repository -Root; $null when there is none.
    .DESCRIPTION
    git rev-list --max-parents=0 HEAD, then rev-parse <sha>^{tree} for each. $null when git is not installed, -Root
    is not a git repository, the repository is shallow (rev-parse --is-shallow-repository; its oldest commit is not
    the root), -Root is a folder inside a repository rather than its top level, or any git call fails. A repository created with "Use this template" has one root commit whose tree is
    the tree of the template commit it copied (D50). A bare repository answers like a clone. Tree ids are compared as
    git prints them, so a SHA-256 repository never matches the SHA-1 trees of the REST API (accepted limitation).
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$Root)
    if ($null -eq (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) { return $null }
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return $null }
    try {
        # A folder inside another repository is not the repository: its root commit would be the other one's. The
        # prefix of the top level is empty (a path comparison with --show-toplevel trips over 8.3 names and links).
        $prefix = Invoke-Git -Root $Root -Arguments @('rev-parse', '--show-prefix')
        if ($prefix.ExitCode -ne 0 -or $prefix.Output.Trim() -ne '') { return $null }
        $shallow = Invoke-Git -Root $Root -Arguments @('rev-parse', '--is-shallow-repository')
        if ($shallow.ExitCode -ne 0 -or $shallow.Output.Trim() -cne 'false') { return $null }
        $roots = Invoke-Git -Root $Root -Arguments @('rev-list', '--max-parents=0', 'HEAD')
        if ($roots.ExitCode -ne 0) { return $null }
        $trees = [System.Collections.Generic.List[string]]::new()
        foreach ($sha in @($roots.Output -split '\r?\n' | Where-Object { $_ -match '^[0-9a-f]{40}$' })) {
            $tree = Invoke-Git -Root $Root -Arguments @('rev-parse', "$sha^{tree}")
            if ($tree.ExitCode -ne 0) { return $null }
            $trees.Add($tree.Output.Trim())
        }
        if ($trees.Count -eq 0) { return $null }
        return [string[]]$trees.ToArray()
    } catch {
        return $null
    }
}

function New-GitHubClone {
    <#
    .SYNOPSIS
    Clones -Branch of -RemoteUrl (https or a local path) into -Path: { Path, RemoteUrl, Branch, BaseSha, Environment }.
    .DESCRIPTION
    git clone --branch <b> --single-branch, then the local identity user.name <actor>, user.email
    <actor>@users.noreply.github.com and core.autocrlf false. The token reaches git as
    http.<server>/.extraheader through GIT_CONFIG_COUNT in Environment, which every later git call of this module
    passes; it is never in the URL or in git config. BaseSha is the cloned head.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Writes only the work folder the caller names')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RemoteUrl,
        [Parameter(Mandatory)][string]$Branch,
        [Parameter(Mandatory)][string]$Path,
        [AllowNull()][AllowEmptyString()][string]$Token,
        [AllowNull()][AllowEmptyString()][string]$Actor,
        # Test seam: more key = value pairs for the GIT_CONFIG_* environment (url.<path>.insteadOf in the suite).
        [System.Collections.IDictionary]$ExtraConfig
    )
    $Path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { [void][System.IO.Directory]::CreateDirectory($parent) }
    if (Test-Path -LiteralPath $Path) { throw "The clone folder exists already: $Path" }
    $environment = Get-GitAuthEnvironment -RemoteUrl $RemoteUrl -Token $Token
    if ($null -ne $ExtraConfig) {
        $count = if ($environment.Contains('GIT_CONFIG_COUNT')) { [int]$environment['GIT_CONFIG_COUNT'] } else { 0 }
        foreach ($key in $ExtraConfig.Keys) {
            $environment["GIT_CONFIG_KEY_$count"] = [string]$key
            $environment["GIT_CONFIG_VALUE_$count"] = [string]$ExtraConfig[$key]
            $count++
        }
        $environment['GIT_CONFIG_COUNT'] = [string]$count
    }
    $clone = Invoke-Git -Root $parent -Arguments @('clone', '--quiet', '--config', 'core.autocrlf=false', '--branch', $Branch, '--single-branch', '--', $RemoteUrl, $Path) -Environment $environment
    if ($clone.ExitCode -ne 0) { throw "Could not clone branch '$Branch' of $RemoteUrl`: $(($clone.Error + $clone.Output).Trim())" }
    $name = if ([string]::IsNullOrWhiteSpace($Actor)) { 'github-actions[bot]' } else { $Actor }
    $null = Assert-Git -Root $Path -Arguments @('config', 'user.name', $name) -What 'git config user.name'
    $null = Assert-Git -Root $Path -Arguments @('config', 'user.email', "$name@users.noreply.github.com") -What 'git config user.email'
    $null = Assert-Git -Root $Path -Arguments @('config', 'core.autocrlf', 'false') -What 'git config core.autocrlf'
    $null = Assert-Git -Root $Path -Arguments @('config', 'commit.gpgsign', 'false') -What 'git config commit.gpgsign'
    $head = Assert-Git -Root $Path -Arguments @('rev-parse', 'HEAD') -What 'git rev-parse HEAD'
    return [pscustomobject]@{
        Path        = $Path
        RemoteUrl   = $RemoteUrl
        Branch      = $Branch
        BaseSha     = $head.Output.Trim()
        Environment = $environment
    }
}

function Publish-GitHubChange {
    <#
    .SYNOPSIS
    Commits everything in the clone and pushes it: { Pushed, Branch, Direct, Fallback, FallbackReason, Sha, Reason }.
    .DESCRIPTION
    git add -A; nothing to commit gives Pushed $false and Reason no-changes. -DirectCommit commits on the cloned
    branch and pushes it; a rejected push (branch protection) moves the commit to -NewBranch (reset --soft HEAD~,
    checkout -b, commit) and pushes that instead, Fallback $true and FallbackReason the trimmed git error and output
    of the refused push ($null without a fallback; nothing is written here, the caller reports it, #77). When that
    fallback branch fails too, the exception carries the refusal in Data['FallbackReason']. Otherwise the commit
    goes to -NewBranch, pushed with -u. AL-Go behaviour (CommitFromNewFolder). -Force rebuilds -NewBranch from the
    cloned head instead (the scan's living branch, also after a refused direct push): the remote head of
    -NewBranch is read with git ls-remote, the branch is created with checkout -B and pushed with --force-with-lease
    against that head (absent: the branch must not exist), so a push someone made in between is rejected, never
    overwritten.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]$Clone,
        [Parameter(Mandatory)][string]$Message,
        [Parameter(Mandatory)][string]$NewBranch,
        [switch]$DirectCommit,
        [switch]$Force
    )
    $root = $Clone.Path
    $environment = $Clone.Environment
    $null = Assert-Git -Root $root -Arguments @('add', '-A') -Environment $environment -What 'git add'
    $status = Assert-Git -Root $root -Arguments @('status', '--porcelain=v1') -Environment $environment -What 'git status'
    if ([string]::IsNullOrWhiteSpace($status.Output)) {
        return [pscustomobject]@{ Pushed = $false; Branch = $Clone.Branch; Direct = [bool]$DirectCommit; Fallback = $false; FallbackReason = $null; Sha = $Clone.BaseSha; Reason = 'no-changes' }
    }
    $fallback = $false
    $fallbackReason = $null
    if ($DirectCommit) {
        $null = Assert-Git -Root $root -Arguments @('commit', '--quiet', '-m', $Message) -Environment $environment -What 'git commit'
        $push = Invoke-Git -Root $root -Arguments @('push', '--quiet', 'origin', "HEAD:refs/heads/$($Clone.Branch)") -Environment $environment
        if ($push.ExitCode -eq 0) {
            $sha = (Assert-Git -Root $root -Arguments @('rev-parse', 'HEAD') -What 'git rev-parse').Output.Trim()
            return [pscustomobject]@{ Pushed = $true; Branch = $Clone.Branch; Direct = $true; Fallback = $false; FallbackReason = $null; Sha = $sha; Reason = 'direct-commit' }
        }
        $fallbackReason = ($push.Error + $push.Output).Trim()
        $fallback = $true
    }
    try {
        # The refused commit moves to the new branch; inside the try, so a failed reset keeps the refusal too.
        if ($fallback) { $null = Assert-Git -Root $root -Arguments @('reset', '--soft', 'HEAD~') -Environment $environment -What 'git reset' }
        if ($Force) {
            $remote = Assert-Git -Root $root -Arguments @('ls-remote', '--heads', 'origin', "refs/heads/$NewBranch") -Environment $environment -What 'git ls-remote'
            $lease = ''
            foreach ($line in $remote.Output.Split("`n")) {
                $parts = @($line.Trim() -split '\s+')
                if ($parts.Count -ge 2 -and $parts[1] -ceq "refs/heads/$NewBranch") { $lease = $parts[0] }
            }
            $null = Assert-Git -Root $root -Arguments @('checkout', '--quiet', '-B', $NewBranch) -Environment $environment -What 'git checkout -B'
            $null = Assert-Git -Root $root -Arguments @('commit', '--quiet', '-m', $Message) -Environment $environment -What 'git commit'
            $null = Assert-Git -Root $root -Arguments @('push', '--quiet', "--force-with-lease=refs/heads/$($NewBranch):$lease", 'origin', "HEAD:refs/heads/$NewBranch") -Environment $environment -What "git push --force-with-lease $NewBranch"
        } else {
            $null = Assert-Git -Root $root -Arguments @('checkout', '--quiet', '-b', $NewBranch) -Environment $environment -What 'git checkout -b'
            $null = Assert-Git -Root $root -Arguments @('commit', '--quiet', '-m', $Message) -Environment $environment -What 'git commit'
            $null = Assert-Git -Root $root -Arguments @('push', '--quiet', '-u', 'origin', $NewBranch) -Environment $environment -What "git push $NewBranch"
        }
    } catch {
        # After a refused direct push the refusal is reported even when the fallback branch fails too (#77).
        if ($fallback) { $_.Exception.Data['FallbackReason'] = $fallbackReason }
        throw
    }
    $sha = (Assert-Git -Root $root -Arguments @('rev-parse', 'HEAD') -What 'git rev-parse').Output.Trim()
    return [pscustomobject]@{ Pushed = $true; Branch = $NewBranch; Direct = $false; Fallback = $fallback; FallbackReason = $fallbackReason; Sha = $sha; Reason = 'branch' }
}

function Get-GitHubPushEnvironment {
    <#
    .SYNOPSIS
    The per-process git environment that sends -Token to the server of -RemoteUrl: GIT_CONFIG_COUNT with an
    http.<server>/.extraheader, empty for a local path or an empty token.
    .DESCRIPTION
    For callers that run git themselves (the deploy, WP13) and must not use Publish-GitHubChange, whose branch
    fallback is wrong for them. Pass the result as -Environment of Invoke-Git; the token never enters a URL or git
    config.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)][string]$RemoteUrl, [AllowNull()][AllowEmptyString()][string]$Token)
    return Get-GitAuthEnvironment -RemoteUrl $RemoteUrl -Token $Token
}

#endregion

Export-ModuleMember -Function @(
    'Add-GitHubIssueComment'
    'Close-GitHubIssue'
    'Confirm-GitHubLabel'
    'Find-GitHubPullRequest'
    'Find-GitHubPullRequestByHead'
    'Find-GitHubPullRequestByHeadPrefix'
    'Get-GitHubAccessToken'
    'Get-GitHubBranchSha'
    'Get-GitHubCommitList'
    'Get-GitHubIssue'
    'Get-GitHubIssueComments'
    'Get-GitHubPushEnvironment'
    'Get-GitHubRefSha'
    'Get-GitHubUserPermission'
    'Get-GitRootTree'
    'Invoke-GitHubApi'
    'New-GitHubAppJwt'
    'New-GitHubClone'
    'New-GitHubPullRequest'
    'Publish-GitHubChange'
    'Save-GitHubZipball'
    'Update-GitHubPullRequest'
)
