#requires -Version 7.4
# Rulebook.GitHub: the GitHub plumbing of the update workflow (WP07). One REST wrapper (Invoke-GitHubApi, the single
# mock point of the suites), the GHTOKENWORKFLOW exchange (a personal access token passes through, GitHub App JSON
# becomes a short-lived installation token, D44), the template download as a zipball, the pull request helpers,
# and the clone, commit and push of the update. No engine imports. The token never enters a git URL or git config:
# git receives it as an http.<server>/.extraheader through GIT_CONFIG_COUNT in the environment of each git call.
# Contract: docs/reference/update-mechanics.md section 6 and 8. Ported from AL-Go (Github-Helper.psm1,
# AL-Go-Helper.ps1), behaviour only: docs/reference/al-go-template-mechanics.md sections 5.5 and 8.

Set-StrictMode -Version 3.0

$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$script:DefaultPermissions = [ordered]@{
    contents      = 'write'
    pull_requests = 'write'
    workflows     = 'write'
    actions       = 'read'
    metadata      = 'read'
}
$script:TokenDocsUrl = 'https://github.com/ALCops/rulebook/blob/main/docs/ghtokenworkflow.md'

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

function Invoke-Git {
    # Runs git with UTF-8 output decoding, independent of the console code page, with extra environment variables
    # for this process only (the token header). A copy of the Rulebook.Generate helper plus the environment hook.
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string[]]$Arguments,
        [System.Collections.IDictionary]$Environment
    )
    $info = [System.Diagnostics.ProcessStartInfo]::new('git')
    $info.ArgumentList.Add('-C')
    $info.ArgumentList.Add($Root)
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.UseShellExecute = $false
    $info.StandardOutputEncoding = $script:Utf8NoBom
    $info.StandardErrorEncoding = $script:Utf8NoBom
    $info.Environment['GIT_TERMINAL_PROMPT'] = '0'
    if ($null -ne $Environment) {
        foreach ($key in $Environment.Keys) { $info.Environment[[string]$key] = [string]$Environment[$key] }
    }
    $process = [System.Diagnostics.Process]::Start($info)
    $errorTask = $process.StandardError.ReadToEndAsync()
    $output = $process.StandardOutput.ReadToEnd()
    $process.WaitForExit()
    return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $output; Error = $errorTask.Result }
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
        [ValidateSet('GET', 'POST', 'HEAD')][string]$Method = 'GET',
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
    try {
        $app = ConvertFrom-Json -InputObject $value -AsHashtable -ErrorAction Stop
    } catch {
        throw "The token secret starts with '{' but is not JSON. Use a personal access token or the compressed JSON {`"GitHubAppClientId`":`"...`",`"PrivateKey`":`"...`"}; see $script:TokenDocsUrl"
    }
    $clientId = [string](Get-DictionaryValue -Dictionary $app -Name 'GitHubAppClientId')
    $privateKey = [string](Get-DictionaryValue -Dictionary $app -Name 'PrivateKey')
    if ([string]::IsNullOrEmpty($clientId) -or [string]::IsNullOrEmpty($privateKey)) {
        throw "The GitHub App JSON in the token secret needs GitHubAppClientId and PrivateKey; see $script:TokenDocsUrl"
    }
    $jwt = New-GitHubAppJwt -ClientId $clientId -PrivateKey $privateKey
    $installation = Invoke-GitHubApi -Method GET -Path (Join-ApiPath -Part 'repos', $Repository, 'installation') -Token $jwt -ApiUrl $ApiUrl
    if ($installation.StatusCode -ne 200 -or $installation.Body -isnot [System.Collections.IDictionary] -or -not $installation.Body.Contains('access_tokens_url')) {
        throw "The GitHub App $clientId has no installation on $Repository (HTTP $($installation.StatusCode): $(Get-ApiMessage $installation)). Install the app on the repository; see $script:TokenDocsUrl"
    }
    $name = $Repository.Substring($Repository.LastIndexOf('/') + 1)
    $body = [ordered]@{ repositories = @($name); permissions = $Permissions }
    $access = Invoke-GitHubApi -Method POST -Uri ([string]$installation.Body['access_tokens_url']) -Token $jwt -Body $body
    if ($access.StatusCode -ne 201 -and $access.StatusCode -ne 200) {
        throw "The GitHub App $clientId could not get an installation token for $Repository (HTTP $($access.StatusCode): $(Get-ApiMessage $access)). Check the app's repository permissions; see $script:TokenDocsUrl"
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

#endregion

#region Git

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
    Commits everything in the clone and pushes it: { Pushed, Branch, Direct, Fallback, Sha, Reason }.
    .DESCRIPTION
    git add -A; nothing to commit gives Pushed $false and Reason no-changes. -DirectCommit commits on the cloned
    branch and pushes it; a rejected push (branch protection) moves the commit to -NewBranch (reset --soft HEAD~,
    checkout -b, commit) and pushes that instead, Fallback $true. Otherwise the commit goes to -NewBranch, pushed
    with -u. AL-Go behaviour (CommitFromNewFolder).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]$Clone,
        [Parameter(Mandatory)][string]$Message,
        [Parameter(Mandatory)][string]$NewBranch,
        [switch]$DirectCommit
    )
    $root = $Clone.Path
    $environment = $Clone.Environment
    $null = Assert-Git -Root $root -Arguments @('add', '-A') -Environment $environment -What 'git add'
    $status = Assert-Git -Root $root -Arguments @('status', '--porcelain=v1') -Environment $environment -What 'git status'
    if ([string]::IsNullOrWhiteSpace($status.Output)) {
        return [pscustomobject]@{ Pushed = $false; Branch = $Clone.Branch; Direct = [bool]$DirectCommit; Fallback = $false; Sha = $Clone.BaseSha; Reason = 'no-changes' }
    }
    $fallback = $false
    if ($DirectCommit) {
        $null = Assert-Git -Root $root -Arguments @('commit', '--quiet', '-m', $Message) -Environment $environment -What 'git commit'
        $push = Invoke-Git -Root $root -Arguments @('push', '--quiet', 'origin', "HEAD:refs/heads/$($Clone.Branch)") -Environment $environment
        if ($push.ExitCode -eq 0) {
            $sha = (Assert-Git -Root $root -Arguments @('rev-parse', 'HEAD') -What 'git rev-parse').Output.Trim()
            return [pscustomobject]@{ Pushed = $true; Branch = $Clone.Branch; Direct = $true; Fallback = $false; Sha = $sha; Reason = 'direct-commit' }
        }
        Write-Warning "The direct push to $($Clone.Branch) was refused; creating a pull request instead. ($(($push.Error + $push.Output).Trim()))"
        $null = Assert-Git -Root $root -Arguments @('reset', '--soft', 'HEAD~') -Environment $environment -What 'git reset'
        $fallback = $true
    }
    $null = Assert-Git -Root $root -Arguments @('checkout', '--quiet', '-b', $NewBranch) -Environment $environment -What 'git checkout -b'
    $null = Assert-Git -Root $root -Arguments @('commit', '--quiet', '-m', $Message) -Environment $environment -What 'git commit'
    $null = Assert-Git -Root $root -Arguments @('push', '--quiet', '-u', 'origin', $NewBranch) -Environment $environment -What "git push $NewBranch"
    $sha = (Assert-Git -Root $root -Arguments @('rev-parse', 'HEAD') -What 'git rev-parse').Output.Trim()
    return [pscustomobject]@{ Pushed = $true; Branch = $NewBranch; Direct = $false; Fallback = $fallback; Sha = $sha; Reason = 'branch' }
}

#endregion

Export-ModuleMember -Function @(
    'Find-GitHubPullRequest'
    'Get-GitHubAccessToken'
    'Get-GitHubBranchSha'
    'Invoke-GitHubApi'
    'New-GitHubAppJwt'
    'New-GitHubClone'
    'New-GitHubPullRequest'
    'Publish-GitHubChange'
    'Save-GitHubZipball'
)
