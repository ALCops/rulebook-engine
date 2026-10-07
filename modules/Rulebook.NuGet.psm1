#requires -Version 7.4
# Rulebook.NuGet: the NuGet side of the diagnostic scan (WP08, R9). Version comparison and channel selection by
# NuGet semantic versioning, the flat-container index of a package, and the download and extraction of one package
# version. No engine imports. Invoke-NuGetRequest is the single web request point, the mock point of the suites; a
# -Source that is an existing folder is read as a flat container on disk (the offline seam of the suites).
# Contract: docs/reference/scan-mechanics.md section 1.

Set-StrictMode -Version 3.0

$script:DefaultSource = 'https://api.nuget.org/v3-flatcontainer'
$script:VersionPattern = '^(?<numbers>\d+(\.\d+){0,3})(-(?<label>[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*))?(\+[0-9A-Za-z.-]+)?$'

#region Internal helpers

# Seconds to wait before the second, third and fourth attempt of a request (a test sets them to 0).
$script:RetryDelaySeconds = @(2, 5, 10)

function Invoke-NuGetRequest {
    # The single Invoke-WebRequest of the module: a non-2xx answer is returned, not thrown. A 5xx or 429 answer and a
    # request without an answer (timeout, connection) are retried three times with a short backoff; a 404 is not.
    param([Parameter(Mandatory)][string]$Uri, [string]$OutFile, [int]$TimeoutSec = 120)
    $request = @{ Uri = $Uri; TimeoutSec = $TimeoutSec; SkipHttpErrorCheck = $true; ErrorAction = 'Stop' }
    if ($OutFile) {
        $request.OutFile = $OutFile
        $request.PassThru = $true
    }
    for ($attempt = 0; ; $attempt++) {
        $last = $attempt -ge $script:RetryDelaySeconds.Count
        try {
            $response = Invoke-WebRequest @request
        } catch {
            if ($last) { throw }
            Write-Verbose "NuGet request $Uri failed ($($_.Exception.Message)); retrying"
            Start-Sleep -Seconds $script:RetryDelaySeconds[$attempt]
            continue
        }
        $status = [int]$response.StatusCode
        if ($last -or ($status -lt 500 -and $status -ne 429)) { return $response }
        Write-Verbose "NuGet request $Uri answered HTTP $status; retrying"
        Start-Sleep -Seconds $script:RetryDelaySeconds[$attempt]
    }
}

function Get-SourceRoot {
    param([AllowNull()][AllowEmptyString()][string]$Source)
    if ([string]::IsNullOrWhiteSpace($Source)) { return $script:DefaultSource }
    return $Source.TrimEnd('/', '\')
}

function Test-FolderSource {
    param([Parameter(Mandatory)][string]$Source)
    return $Source -notmatch '^https?://' -and (Test-Path -LiteralPath $Source -PathType Container)
}

function New-NuGetException {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an exception; changes no state')]
    param([Parameter(Mandatory)][string]$Message, [int]$StatusCode)
    $exception = [System.InvalidOperationException]::new($Message)
    $exception.Data['Stage'] = 'nuget'
    if ($StatusCode) { $exception.Data['StatusCode'] = $StatusCode }
    return $exception
}

function Test-NuGetVersion {
    # True when Version parses as a NuGet version (the parser of Compare-NuGetVersion).
    param([AllowNull()][AllowEmptyString()][string]$Version)
    if ([string]::IsNullOrWhiteSpace($Version)) { return $false }
    return [regex]::IsMatch($Version.Trim(), $script:VersionPattern)
}

function ConvertTo-VersionPart {
    # { Numbers (four longs), Label (string[]) } of a NuGet version; throws on anything else.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Version)
    $match = [regex]::Match($Version.Trim(), $script:VersionPattern)
    if (-not $match.Success) { throw "'$Version' is not a NuGet version" }
    $numbers = [long[]]::new(4)
    $parts = $match.Groups['numbers'].Value.Split('.')
    for ($i = 0; $i -lt $parts.Count; $i++) { $numbers[$i] = [long]$parts[$i] }
    # An if expression would unroll an empty array into $null.
    [string[]]$label = @()
    if ($match.Groups['label'].Success) { $label = $match.Groups['label'].Value.Split('.') }
    return [pscustomobject]@{ Numbers = $numbers; Label = $label }
}

function Compare-LabelPart {
    # One release-label identifier: numeric against numeric by value, numeric before alphanumeric, else ordinal
    # ignoring case.
    param([Parameter(Mandatory)][string]$Left, [Parameter(Mandatory)][string]$Right)
    $leftNumeric = $Left -match '^\d+$'
    $rightNumeric = $Right -match '^\d+$'
    if ($leftNumeric -and $rightNumeric) { return [math]::Sign(([System.Numerics.BigInteger]::Parse($Left)).CompareTo([System.Numerics.BigInteger]::Parse($Right))) }
    if ($leftNumeric) { return -1 }
    if ($rightNumeric) { return 1 }
    return [math]::Sign([string]::Compare($Left, $Right, [System.StringComparison]::OrdinalIgnoreCase))
}

#endregion

function Compare-NuGetVersion {
    <#
    .SYNOPSIS
    -1, 0 or 1 as -Reference sorts before, equal to or after -Difference by NuGet semantic versioning.
    .DESCRIPTION
    Up to four numeric parts (a missing part is 0, so 1.0 equals 1.0.0.0); a version without a release label sorts
    after the same numbers with one; labels compare identifier by identifier (numeric by value, numeric before
    alphanumeric, else ordinal ignoring case; a shorter prefix sorts first); build metadata is ignored. A string that
    is not a NuGet version throws.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][string]$Reference, [Parameter(Mandatory)][string]$Difference)
    $left = ConvertTo-VersionPart -Version $Reference
    $right = ConvertTo-VersionPart -Version $Difference
    for ($i = 0; $i -lt 4; $i++) {
        if ($left.Numbers[$i] -ne $right.Numbers[$i]) { return [math]::Sign($left.Numbers[$i].CompareTo($right.Numbers[$i])) }
    }
    if ($left.Label.Count -eq 0 -and $right.Label.Count -eq 0) { return 0 }
    if ($left.Label.Count -eq 0) { return 1 }
    if ($right.Label.Count -eq 0) { return -1 }
    for ($i = 0; $i -lt [math]::Min($left.Label.Count, $right.Label.Count); $i++) {
        $result = Compare-LabelPart -Left $left.Label[$i] -Right $right.Label[$i]
        if ($result -ne 0) { return $result }
    }
    return [math]::Sign($left.Label.Count.CompareTo($right.Label.Count))
}

function Select-NuGetChannelVersion {
    <#
    .SYNOPSIS
    The newest stable and prerelease version of a version list: { Stable, Prerelease, Invalid }.
    .DESCRIPTION
    Every entry goes through the parser of Compare-NuGetVersion first; an entry that is not a NuGet version (an empty
    string, '../x') is skipped and listed in Invalid, so a sole entry is validated too. Stable is the highest version
    without a release label. Prerelease is the highest version with one, only with
    -IncludePrerelease and only when it sorts after Stable (an ALCops prerelease older than the stable release is
    not current); else $null. The order of -Versions does not matter.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Versions, [switch]$IncludePrerelease)
    $stable = $null
    $prerelease = $null
    $invalid = [System.Collections.Generic.List[string]]::new()
    foreach ($version in $Versions) {
        if (-not (Test-NuGetVersion -Version $version)) {
            $invalid.Add([string]$version)
            continue
        }
        if (($version -split '\+')[0].Contains('-')) {
            if ($null -eq $prerelease -or (Compare-NuGetVersion -Reference $version -Difference $prerelease) -gt 0) { $prerelease = $version }
        } elseif ($null -eq $stable -or (Compare-NuGetVersion -Reference $version -Difference $stable) -gt 0) {
            $stable = $version
        }
    }
    if (-not $IncludePrerelease) { $prerelease = $null }
    if ($null -ne $prerelease -and $null -ne $stable -and (Compare-NuGetVersion -Reference $prerelease -Difference $stable) -le 0) { $prerelease = $null }
    return [pscustomobject]@{ Stable = $stable; Prerelease = $prerelease; Invalid = $invalid.ToArray() }
}

function Get-NuGetVersionIndex {
    <#
    .SYNOPSIS
    The versions of a package from the flat container: { PackageId, Versions, Source }.
    .DESCRIPTION
    GET <Source>/<id>/index.json with the id lowercased (Source default https://api.nuget.org/v3-flatcontainer). A
    Source that is an existing folder is read from disk. A missing index or a non-200 answer throws 'Could not read
    the NuGet index of <id> (HTTP <status>)' with Data['Stage'] = 'nuget'.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$PackageId, [AllowNull()][AllowEmptyString()][string]$Source)
    $id = $PackageId.ToLowerInvariant()
    $root = Get-SourceRoot -Source $Source
    if (Test-FolderSource -Source $root) {
        $path = Join-Path $root $id 'index.json'
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw (New-NuGetException -Message "Could not read the NuGet index of $id (HTTP 404)" -StatusCode 404) }
        $text = [System.IO.File]::ReadAllText($path)
    } else {
        $response = Invoke-NuGetRequest -Uri "$root/$id/index.json" -TimeoutSec 60
        $status = [int]$response.StatusCode
        if ($status -ne 200) { throw (New-NuGetException -Message "Could not read the NuGet index of $id (HTTP $status)" -StatusCode $status) }
        $text = if ($response.Content -is [byte[]]) { [System.Text.Encoding]::UTF8.GetString($response.Content) } else { [string]$response.Content }
    }
    try {
        $json = ConvertFrom-Json -InputObject $text -AsHashtable -ErrorAction Stop
    } catch {
        throw (New-NuGetException -Message "The NuGet index of $id is not JSON: $($_.Exception.Message)")
    }
    if ($json -isnot [System.Collections.IDictionary] -or $json['versions'] -isnot [System.Collections.IList]) {
        throw (New-NuGetException -Message "The NuGet index of $id has no versions array")
    }
    return [pscustomobject]@{ PackageId = $id; Versions = [string[]]@($json['versions'] | ForEach-Object { [string]$_ }); Source = $root }
}

function Get-NuGetPackageUrl {
    <#
    .SYNOPSIS
    <Source>/<id>/<version>/<id>.<version>.nupkg, id and version lowercased.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$PackageId, [Parameter(Mandatory)][string]$Version, [AllowNull()][AllowEmptyString()][string]$Source)
    return '{0}/{1}/{2}/{1}.{2}.nupkg' -f (Get-SourceRoot -Source $Source), $PackageId.ToLowerInvariant(), $Version.ToLowerInvariant()
}

function Save-NuGetPackage {
    <#
    .SYNOPSIS
    Downloads one package version and extracts it: { PackageId, Version, NupkgPath, ExtractPath, Bytes }.
    .DESCRIPTION
    The nupkg goes to <Path>/<id>.<version>.nupkg and is extracted into <Path>/<id>.<version>/, which is deleted
    first when present. A folder -Source is copied from disk. A missing package or a non-200 answer throws with
    Data['Stage'] = 'nuget'. A version that is not a NuGet version, a nupkg or extract path outside -Path, or a zip
    entry that would land outside the extract folder throws before anything is written there.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$PackageId,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$Path,
        [AllowNull()][AllowEmptyString()][string]$Source
    )
    $id = $PackageId.ToLowerInvariant()
    $v = $Version.ToLowerInvariant()
    if (-not (Test-NuGetVersion -Version $v)) { throw (New-NuGetException -Message "'$Version' is not a NuGet version; $id is not downloaded") }
    # [System.IO] resolves a relative path against the process directory, not the PowerShell location.
    $Path = [System.IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path))
    $nupkg = [System.IO.Path]::GetFullPath((Join-Path $Path "$id.$v.nupkg"))
    $extract = [System.IO.Path]::GetFullPath((Join-Path $Path "$id.$v"))
    $prefix = $Path.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    foreach ($target in $nupkg, $extract) {
        if (-not $target.StartsWith($prefix, [System.StringComparison]::Ordinal)) { throw (New-NuGetException -Message "$id $Version would be written outside $Path ($target)") }
    }
    [void][System.IO.Directory]::CreateDirectory($Path)
    $url = Get-NuGetPackageUrl -PackageId $id -Version $v -Source $Source
    if (Test-FolderSource -Source (Get-SourceRoot -Source $Source)) {
        if (-not (Test-Path -LiteralPath $url -PathType Leaf)) { throw (New-NuGetException -Message "Could not download $id $v (HTTP 404)" -StatusCode 404) }
        [System.IO.File]::Copy($url, $nupkg, $true)
    } else {
        $response = Invoke-NuGetRequest -Uri $url -OutFile $nupkg -TimeoutSec 300
        $status = [int]$response.StatusCode
        if ($status -ne 200) {
            if (Test-Path -LiteralPath $nupkg) { Remove-Item -LiteralPath $nupkg -Force }
            throw (New-NuGetException -Message "Could not download $id $v (HTTP $status)" -StatusCode $status)
        }
    }
    if (Test-Path -LiteralPath $extract) { Remove-Item -LiteralPath $extract -Recurse -Force }
    # ExtractToDirectory refuses an entry that would land outside the folder (a '../' name); the folder is removed then.
    try {
        [System.IO.Compression.ZipFile]::ExtractToDirectory($nupkg, $extract)
    } catch {
        if (Test-Path -LiteralPath $extract) { Remove-Item -LiteralPath $extract -Recurse -Force }
        throw (New-NuGetException -Message "$id $v is not a readable package: $($_.Exception.Message)")
    }
    return [pscustomobject]@{ PackageId = $id; Version = $Version; NupkgPath = $nupkg; ExtractPath = $extract; Bytes = (Get-Item -LiteralPath $nupkg).Length }
}

Export-ModuleMember -Function @(
    'Compare-NuGetVersion'
    'Get-NuGetPackageUrl'
    'Get-NuGetVersionIndex'
    'Save-NuGetPackage'
    'Select-NuGetChannelVersion'
)
