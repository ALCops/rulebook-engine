#requires -Version 7.4
# Rulebook.Update: the update of an organization rulebook repository from its template (WP07, R5), a port of AL-Go's
# CheckForUpdates. Builds a candidate tree from the organization's working tree and the template, file class by file
# class (overwrite, settings, generated, customizable, org-owned), regenerates the skeletons and the endpoints on it,
# validates it with Test-Rulebook and lists what changes. Publish-RulebookUpdate clones the repository, applies the
# change list and opens the pull request (or pushes a direct commit) through Rulebook.GitHub.
# Contract: docs/reference/update-mechanics.md. Design: docs/ARCHITECTURE.md section 7.3, docs/dashboard.md section 9.

Set-StrictMode -Version 3.0
Import-Module (Join-Path $PSScriptRoot 'Rulebook.Common.psd1')
Import-Module (Join-Path $PSScriptRoot 'Rulebook.Generate.psd1')
Import-Module (Join-Path $PSScriptRoot 'Rulebook.Validate.psd1')
Import-Module (Join-Path $PSScriptRoot 'Rulebook.Template.psd1')
Import-Module (Join-Path $PSScriptRoot 'Rulebook.GitHub.psd1')
Import-Module (Join-Path $PSScriptRoot 'Rulebook.Action.psd1')

$script:SettingsPath = '.github/Rulebook-Settings.json'
$script:ReleaseNotesPath = '.github/RELEASENOTES.copy.md'
# The workflows whose schedule: trigger comes from a settings key. KeepWhenAbsent: an absent key keeps the schedule the
# template ships (an organization from before WP08 has no scan key, and the scan is daily by design); only an explicit
# null removes it. update.schedule keeps its WP07 rule: absent or null removes the schedule.
$script:ScheduledWorkflows = [ordered]@{
    'UpdateRulebookSystemFiles.yaml' = @{ Path = @('update', 'schedule'); KeepWhenAbsent = $false }
    'ScanDiagnostics.yaml'           = @{ Path = @('scan', 'schedule'); KeepWhenAbsent = $true }
}
$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
# Extensions that are always binary (a fast path); any other file is binary when its first 8 KB hold a NUL byte.
$script:BinaryExtensions = @('.png', '.jpg', '.jpeg', '.gif', '.ico', '.bmp', '.webp', '.avif', '.pdf', '.woff', '.woff2', '.ttf', '.otf', '.eot', '.zip')
$script:BinarySniffBytes = 8192
# Folders of the working tree that are never compared or copied: git, the site data written at publish time (D35),
# and a local npm install.
$script:ExcludedPrefixes = @('.git/', 'site/data/')
$script:ExcludedSegment = 'node_modules'
$script:TemplateUrlPattern = '^https://github\.com/([^/@\s]+)/([^/@\s]+)@([^@\s]+)$'
$script:TitlePrefix = 'Update Rulebook System Files from'
$script:BranchPrefix = 'update-rulebook-system-files'
# YAML 1.1 words GitHub would read as a boolean or null; a slug spelled like one is quoted in a choice list.
$script:YamlReserved = @('y', 'n', 'yes', 'no', 'on', 'off', 'true', 'false', 'null')
# A pull request body is limited to 65536 characters; stay below it.
$script:BodyLimit = 60000

#region Internal helpers

function Get-SettingValue {
    # A key of the settings dictionary, or a nested key ('site', 'updateMode'); $null when absent (StrictMode safe).
    param($Settings, [Parameter(Mandatory)][string[]]$Path)
    $value = $Settings
    foreach ($key in $Path) {
        if ($value -isnot [System.Collections.IDictionary] -or -not $value.Contains($key)) { return $null }
        $value = $value[$key]
    }
    return $value
}

function Test-BinaryFile {
    # The one binary rule of the update: a known binary extension, or a NUL byte in the first 8 KB. A binary file is
    # compared, hashed and copied by its bytes, never through the LF and UTF-8 text path.
    param([Parameter(Mandatory)][string]$Path)
    if ([System.IO.Path]::GetExtension($Path).ToLowerInvariant() -cin $script:BinaryExtensions) { return $true }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $buffer = [byte[]]::new($script:BinarySniffBytes)
        $read = $stream.Read($buffer, 0, $buffer.Length)
    } finally {
        $stream.Dispose()
    }
    return [System.Array]::IndexOf($buffer, [byte]0, 0, $read) -ge 0
}

function ConvertTo-UpdateText {
    # The text the update writes and compares: LF line endings, exactly one trailing LF (none for an empty text).
    param([AllowNull()][AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $normalized = $Text.Replace("`r`n", "`n").TrimEnd("`n")
    if ($normalized.Length -eq 0) { return '' }
    return $normalized + "`n"
}

function Read-UpdateText {
    # A file as normalised text (UTF-8, a byte order mark dropped); $null when the file does not exist.
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    return ConvertTo-UpdateText -Text ([System.IO.File]::ReadAllText($Path, $script:Utf8NoBom))
}

function Get-ComparableContent {
    # What the comparison looks at: normalised text, or base64 of the bytes for a binary file; $null when absent.
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Path)
    $full = Join-Path $Root $Path
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { return $null }
    if (Test-BinaryFile -Path $full) { return [System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes($full)) }
    return Read-UpdateText -Path $full
}

function Write-UpdateText {
    # UTF-8 without BOM, LF, one trailing LF; creates the folder.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { [void][System.IO.Directory]::CreateDirectory($parent) }
    [System.IO.File]::WriteAllBytes($Path, $script:Utf8NoBom.GetBytes((ConvertTo-UpdateText -Text $Text)))
}

function Write-UpdateBinary {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { [void][System.IO.Directory]::CreateDirectory($parent) }
    [System.IO.File]::WriteAllBytes($Path, $Bytes)
}

function Test-ExcludedPath {
    param([Parameter(Mandatory)][string]$Path)
    foreach ($prefix in $script:ExcludedPrefixes) {
        if ($Path.StartsWith($prefix, [System.StringComparison]::Ordinal) -or $Path -ceq $prefix.TrimEnd('/')) { return $true }
    }
    return $Path -cmatch "(^|/)$($script:ExcludedSegment)(/|$)"
}

function Get-TreeFile {
    # Relative paths ('/') of every file under Root, sorted ordinally. The excluded folders (.git, site/data,
    # node_modules) are pruned during the walk, so their content is never enumerated; directory symlinks and junctions
    # are skipped.
    param([Parameter(Mandatory)][string]$Root)
    $full = (Resolve-Path -LiteralPath $Root).ProviderPath
    $paths = [System.Collections.Generic.List[string]]::new()
    $pending = [System.Collections.Generic.Stack[object]]::new()
    $pending.Push([pscustomobject]@{ Path = $full; Relative = '' })
    while ($pending.Count -gt 0) {
        $folder = $pending.Pop()
        foreach ($item in Get-ChildItem -LiteralPath $folder.Path -Force) {
            $relative = if ($folder.Relative) { "$($folder.Relative)/$($item.Name)" } else { $item.Name }
            if ($item.PSIsContainer) {
                # A directory symlink or junction is not followed (one to the root would loop).
                if ($item.LinkType -or ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { continue }
                if (-not (Test-ExcludedPath -Path "$relative/")) { $pending.Push([pscustomobject]@{ Path = $item.FullName; Relative = $relative }) }
            } elseif (-not (Test-ExcludedPath -Path $relative)) {
                $paths.Add($relative)
            }
        }
    }
    [string[]]$sorted = $paths.ToArray()
    [System.Array]::Sort($sorted, [System.StringComparer]::Ordinal)
    return $sorted
}

function Copy-UpdateTree {
    # Copies the files of Source to Destination, without the excluded folders.
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Destination)
    $full = (Resolve-Path -LiteralPath $Source).ProviderPath
    [void][System.IO.Directory]::CreateDirectory($Destination)
    foreach ($path in Get-TreeFile -Root $full) {
        $target = Join-Path $Destination $path
        $parent = Split-Path -Parent $target
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) { [void][System.IO.Directory]::CreateDirectory($parent) }
        [System.IO.File]::Copy((Join-Path $full $path), $target, $true)
    }
}

function Get-DefaultWorkPath {
    # A fresh work folder name under RUNNER_TEMP (else the temp folder): <Prefix>-<8 hex>. Shared with Rulebook.Scan.
    param([string]$Prefix = 'rulebook-update')
    $temp = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [System.IO.Path]::GetTempPath() }
    return Join-Path $temp ($Prefix + '-' + [guid]::NewGuid().ToString('n').Substring(0, 8))
}

function Find-TemplateRoot {
    # The folder that holds .github/workflows: Path itself or a folder below it (AL-Go GetSrcFolder).
    param([Parameter(Mandatory)][string]$Path)
    if (Test-Path -LiteralPath (Join-Path $Path '.github' 'workflows') -PathType Container) { return (Resolve-Path -LiteralPath $Path).ProviderPath }
    foreach ($folder in @(Get-ChildItem -LiteralPath $Path -Directory -Force -Recurse -Depth 2 | Where-Object { $_.Name -ceq 'workflows' -and $_.Parent.Name -ceq '.github' })) {
        return $folder.Parent.Parent.FullName
    }
    throw 'no .github/workflows in the template'
}

function Get-JsonStringMatch {
    # The first "key": "value" pair of Key in Text; groups 1 (up to the opening quote), 2 (the value), 3 (the quote).
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [Parameter(Mandatory)][string]$Key)
    $pattern = '("' + [regex]::Escape($Key) + '"[ \t]*:[ \t]*")((?:[^"\\\r\n]|\\.)*)(")'
    return [regex]::Match($Text, $pattern)
}

function Get-JsonStringContent {
    # A JSON string literal without its quotes.
    param([AllowNull()][AllowEmptyString()][string]$Value)
    $literal = ConvertTo-JsonString -Value $(if ($null -eq $Value) { '' } else { $Value })
    return $literal.Substring(1, $literal.Length - 2)
}

function Get-TextWithValue {
    # Text with group 2 of Match replaced by Value.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [Parameter(Mandatory)]$Match, [Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    $group = $Match.Groups[2]
    return $Text.Substring(0, $group.Index) + $Value + $Text.Substring($group.Index + $group.Length)
}

function Get-TextWithoutSha {
    # The settings text without its templateSha property, for the sha-only comparison.
    param([AllowNull()][AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $ownLine = '(?m)^[ \t]*"templateSha"[ \t]*:[ \t]*"[^"\r\n]*"[ \t]*,?[ \t]*\n'
    if ($Text -match $ownLine) { return [regex]::Replace($Text, $ownLine, '') }
    return [regex]::Replace($Text, ',?[ \t]*"templateSha"[ \t]*:[ \t]*"[^"\r\n]*"', '')
}

function Format-YamlScalar {
    # A slug as a YAML scalar: plain when it reads as a string, else single-quoted.
    param([Parameter(Mandatory)][string]$Value)
    if ($Value -cmatch '^[a-z][a-z0-9-]*$' -and $Value -cnotin $script:YamlReserved) { return $Value }
    return "'" + $Value.Replace("'", "''") + "'"
}

function Get-ShortSha {
    param([AllowNull()][AllowEmptyString()][string]$Sha)
    if ([string]::IsNullOrEmpty($Sha)) { return '' }
    return $Sha.Substring(0, [math]::Min(7, $Sha.Length))
}

function New-UpdateFinding {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an object; changes no state')]
    param([Parameter(Mandatory)][string]$Message)
    return [pscustomobject]@{ PSTypeName = 'Rulebook.Finding'; Rule = 'update'; Severity = 'error'; File = $null; Id = $null; Message = $Message }
}

#endregion

#region YAML line editor
# A port of the behaviour of AL-Go's yamlclass.ps1: a line-based editor addressing a block by a '/' path of keys
# ('on:/workflow_dispatch:/inputs:'), with two spaces of indentation per level and no YAML parser, so the
# formatting of the template survives. A path ending with '/' addresses the lines below the key only; without it
# the key line is included. Keys match case-insensitively at the start of a line of their level.

function Find-YamlPath {
    # { Start, Count } of the block Path addresses in Lines, or $null.
    param([AllowEmptyCollection()][string[]]$Lines, [Parameter(Mandatory)][string]$Path)
    $slash = $Path.IndexOf([char]'/')
    if ($slash -ge 0) {
        $head = $Path.Substring(0, $slash)
        $rest = $Path.Substring($slash + 1)
        if ($rest -eq '') {
            $block = Find-YamlPath -Lines $Lines -Path $head
            if ($null -eq $block -or $block.Count -lt 1) { return $null }
            return [pscustomobject]@{ Start = $block.Start + 1; Count = $block.Count - 1 }
        }
        $section = Find-YamlPath -Lines $Lines -Path "$head/"
        if ($null -eq $section) { return $null }
        $inner = Get-YamlBlock -Lines $Lines -Block $section -Depth 1
        $found = Find-YamlPath -Lines $inner -Path $rest
        if ($null -eq $found) { return $null }
        return [pscustomobject]@{ Start = $section.Start + $found.Start; Count = $found.Count }
    }
    $start = -1
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $padded = "$($Lines[$i])  "
        if ($padded.StartsWith($Path, [System.StringComparison]::OrdinalIgnoreCase)) {
            # 'key:' opens a block; 'key: value' is one line.
            if ($Lines[$i].TrimEnd() -ieq $Path) { $start = $i; continue }
            return [pscustomobject]@{ Start = $i; Count = 1 }
        }
        if ($start -ne -1 -and -not $padded.StartsWith('  ')) {
            # A blank line before the next key belongs to the gap, not to the block.
            $count = if ($Lines[$i - 1].Trim() -eq '') { $i - $start - 1 } else { $i - $start }
            return [pscustomobject]@{ Start = $start; Count = $count }
        }
    }
    if ($start -ne -1) { return [pscustomobject]@{ Start = $start; Count = $Lines.Count - $start } }
    return $null
}

function Get-YamlBlock {
    # The lines of Block with Depth levels of indentation removed.
    param([AllowEmptyCollection()][string[]]$Lines, [Parameter(Mandatory)]$Block, [int]$Depth)
    $result = [System.Collections.Generic.List[string]]::new()
    for ($i = $Block.Start; $i -lt $Block.Start + $Block.Count; $i++) {
        $result.Add(("$($Lines[$i])$('  ' * $Depth)").Substring(2 * $Depth).TrimEnd())
    }
    return , [string[]]$result.ToArray()
}

function Get-YamlPath {
    # The lines Path addresses, unindented to its level; $null when the path does not exist.
    param([AllowEmptyCollection()][string[]]$Lines, [Parameter(Mandatory)][string]$Path)
    $block = Find-YamlPath -Lines $Lines -Path $Path
    if ($null -eq $block) { return $null }
    return Get-YamlBlock -Lines $Lines -Block $block -Depth ($Path.Split('/').Count - 1)
}

function Set-YamlPath {
    # Lines with the block Path addresses replaced by Content (indented to the level of Path); unchanged when the
    # path does not exist. An empty Content removes the block.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Returns a new line array; changes no state')]
    param([AllowEmptyCollection()][string[]]$Lines, [Parameter(Mandatory)][string]$Path, [AllowEmptyCollection()][string[]]$Content)
    $block = Find-YamlPath -Lines $Lines -Path $Path
    if ($null -eq $block) { return , $Lines }
    $depth = $Path.Split('/').Count - 1
    $result = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $block.Start; $i++) { $result.Add($Lines[$i]) }
    foreach ($line in @($Content)) { $result.Add(("$('  ' * $depth)$line").TrimEnd()) }
    for ($i = $block.Start + $block.Count; $i -lt $Lines.Count; $i++) { $result.Add($Lines[$i]) }
    return , [string[]]$result.ToArray()
}

function Add-YamlContent {
    # Lines with Content appended to the block Path addresses (AL-Go Add).
    param([AllowEmptyCollection()][string[]]$Lines, [Parameter(Mandatory)][string]$Path, [AllowEmptyCollection()][string[]]$Content)
    $current = Get-YamlPath -Lines $Lines -Path $Path
    if ($null -eq $current) { return , $Lines }
    return Set-YamlPath -Lines $Lines -Path $Path -Content (@($current) + @($Content))
}

function Set-YamlKey {
    # Lines with Key (and its Content, one level deeper) removed from the block Path addresses and appended at its
    # end (AL-Go ReplaceOrAdd).
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Returns a new line array; changes no state')]
    param([AllowEmptyCollection()][string[]]$Lines, [Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Key, [AllowEmptyCollection()][string[]]$Content)
    $without = Set-YamlPath -Lines $Lines -Path "$Path$Key" -Content @()
    return Add-YamlContent -Lines $without -Path $Path -Content (@($Key) + @($Content | ForEach-Object { "  $_" }))
}

function Remove-YamlPath {
    # Lines without the block Path addresses.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Returns a new line array; changes no state')]
    param([AllowEmptyCollection()][string[]]$Lines, [Parameter(Mandatory)][string]$Path)
    return Set-YamlPath -Lines $Lines -Path $Path -Content @()
}

#endregion

#region Template

function ConvertTo-TemplateUrl {
    <#
    .SYNOPSIS
    Normalises a template URL AL-Go style: { Url, Owner, Repository, Repo ('owner/name'), Branch }.
    .DESCRIPTION
    Appends @main when there is no '@', prepends https://github.com/ when the value does not start with https://,
    strips www. Throws, naming the value, when the result is not https://github.com/<owner>/<repo>@<branch>.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Url)
    $value = $Url.Trim()
    if ($value -eq '') { throw 'The template URL is empty; set templateUrl in .github/Rulebook-Settings.json or pass the templateUrl input.' }
    if (-not $value.Contains('@')) { $value += '@main' }
    if (-not $value.StartsWith('https://', [System.StringComparison]::OrdinalIgnoreCase)) { $value = "https://github.com/$value" }
    $value = [regex]::Replace($value, '^https://www\.', 'https://', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($value -notmatch $script:TemplateUrlPattern) {
        throw "The template URL '$Url' is not of the form https://github.com/<owner>/<repository>@<branch> (or <owner>/<repository>[@<branch>])."
    }
    return [pscustomobject]@{
        Url        = "https://github.com/$($Matches[1])/$($Matches[2])@$($Matches[3])"
        Owner      = $Matches[1]
        Repository = $Matches[2]
        Repo       = "$($Matches[1])/$($Matches[2])"
        Branch     = $Matches[3]
    }
}

function Get-TemplateContentSha {
    <#
    .SYNOPSIS
    A content sha of a template folder: SHA-1 over the sorted path NUL content (text LF-normalised) of every file.
    .DESCRIPTION
    Stands in for the commit sha of a local template (-TemplatePath without -TemplateSha), so the same content always
    gives the same templateSha.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)
    $root = (Resolve-Path -LiteralPath $Path).ProviderPath
    $sha1 = [System.Security.Cryptography.SHA1]::Create()
    try {
        $stream = [System.IO.MemoryStream]::new()
        foreach ($file in Get-TreeFile -Root $root) {
            $bytes = $script:Utf8NoBom.GetBytes($file + [char]0)
            $stream.Write($bytes, 0, $bytes.Length)
            $content = if (Test-BinaryFile -Path (Join-Path $root $file)) { [System.IO.File]::ReadAllBytes((Join-Path $root $file)) } else { $script:Utf8NoBom.GetBytes((Read-UpdateText -Path (Join-Path $root $file))) }
            $stream.Write($content, 0, $content.Length)
            $stream.WriteByte(10)
        }
        $hash = $sha1.ComputeHash($stream.ToArray())
    } finally {
        $sha1.Dispose()
    }
    return [System.Convert]::ToHexString($hash).ToLowerInvariant()
}

function Get-RepositoryRootTree {
    <#
    .SYNOPSIS
    The tree of the organization repository's root commit: { TreeShas, Source ('git', 'api' or $null), Note }.
    .DESCRIPTION
    The local route first: Get-GitRootTree on -RepositoryRoot (a full clone; a shallow one is skipped). Else, with
    -Repository (owner/name), the REST walk of its commits at -Ref (empty: the default branch) to the last page with
    -Token, at most -MaxPages pages of 100; the last commit of the last page is taken as the root, and Note says so
    (a repository with several root commits, or with commit dates out of order, may not match). Else TreeShas is
    $null and Note says why ("The repository's root commit could not be found (...)."); a failing call becomes that
    note, it never throws. Off GitHub (-Repository empty) only the local route runs. Used by Get-RulebookTemplate (D50).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()][AllowEmptyString()][string]$RepositoryRoot,
        [AllowNull()][AllowEmptyString()][string]$Repository,
        [AllowNull()][AllowEmptyString()][string]$Ref,
        [AllowNull()][AllowEmptyString()][string]$Token,
        [AllowNull()][AllowEmptyString()][string]$ApiUrl,
        [ValidateRange(1, 1000)][int]$MaxPages = 10
    )
    $result = { param($Trees, $Source, $Note) [pscustomobject]@{ TreeShas = $Trees; Source = $Source; Note = $Note } }
    if (-not [string]::IsNullOrWhiteSpace($RepositoryRoot)) {
        # Get-GitRootTree returns $null for no answer; @() around it would count that $null as one tree.
        $trees = Get-GitRootTree -Root $RepositoryRoot
        if ($null -ne $trees -and @($trees).Count -gt 0) { return & $result ([string[]]@($trees)) 'git' $null }
    }
    if ([string]::IsNullOrWhiteSpace($Repository)) {
        return & $result $null $null "The repository's root commit could not be found (no full git history in the working folder and no repository name to ask the API)."
    }
    try {
        $list = Get-GitHubCommitList -Repository $Repository -Ref $Ref -Token $Token -ApiUrl $ApiUrl -MaxPages $MaxPages
    } catch {
        return & $result $null $null "The repository's root commit could not be found ($($_.Exception.Message))."
    }
    if ($list.Truncated) {
        return & $result $null $null "The repository's root commit could not be found ($Repository has at least $($MaxPages * 100) commits, the most the update reads)."
    }
    $commits = @($list.Commits)
    if ($commits.Count -eq 0 -or [string]::IsNullOrEmpty($commits[-1].TreeSha)) {
        return & $result $null $null "The repository's root commit could not be found (the API listed no commits of $Repository)."
    }
    return & $result ([string[]]@($commits[-1].TreeSha)) 'api' "The repository's root commit was taken from the last page of its commits list (no full git history in the checkout); a repository with more than one root commit, or with commit dates out of order, may not match."
}

function Get-RulebookTemplate {
    <#
    .SYNOPSIS
    The new template and, when needed, the installed one: { Url, Repo, Branch, Sha, Path, InstalledPath, InstalledSha,
    InstalledSource, Source, Notes }.
    .DESCRIPTION
    Download: resolves the branch head of -TemplateUrl when -DownloadLatest or -InstalledSha is empty (else uses
    -InstalledSha) and downloads that zipball into -WorkPath. The requests use -GitHubToken (GITHUB_TOKEN) first; on
    HTTP 401, 403 or 404 with a -Token (the GHTOKENWORKFLOW value) the request is repeated with that token (GitHub App
    JSON exchanged for contents read, a personal access token as it is), which is how a private template is read. A
    failed exchange rethrows the original error (its status kept) with the exchange error added to the message. -OnToken runs with every token
    obtained by an exchange before it is used (the action masks it). Path is the folder of the zip that holds
    .github/workflows (none throws 'no .github/workflows in the template'). The installed template (a second zipball
    at -InstalledSha) is downloaded whenever it differs from Sha: the three-way comparison of site and docs files (D35, D50) and the
    notes on files the template dropped need it, with the token that read the new template; any failure there is a note,
    and InstalledPath is $null.
    Recovery (D50): when -InstalledSha is empty and -RepositoryRoot or -Repository is given (the caller passes them
    only when the stored templateUrl names this template), the tree of the organization repository's root commit
    (Get-RepositoryRootTree: the local clone, else the REST walk of -Repository at -Ref with -RepositoryToken) is
    looked up among the commits of the template branch (Get-GitHubCommitList, with the token that read the new
    template); the newest commit with that tree becomes the installed commit. Every outcome is a note; no match or a
    failure keeps the behaviour without an installed template. InstalledSource is recorded (-InstalledSha), recovered
    or none.
    Local: -TemplatePath (and -InstalledTemplatePath) are folders; Sha is -TemplateSha or Get-TemplateContentSha;
    InstalledSource is recorded with -InstalledTemplatePath, else none (no recovery).
    #>
    [CmdletBinding(DefaultParameterSetName = 'Download')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Download')]
        [Parameter(ParameterSetName = 'Local')]
        [AllowEmptyString()][string]$TemplateUrl,
        [Parameter(ParameterSetName = 'Download')][AllowNull()][AllowEmptyString()][string]$Token,
        [Parameter(ParameterSetName = 'Download')][AllowNull()][AllowEmptyString()][string]$GitHubToken,
        [Parameter(ParameterSetName = 'Download')][switch]$DownloadLatest,
        [Parameter(ParameterSetName = 'Download')][AllowNull()][AllowEmptyString()][string]$InstalledSha,
        [Parameter(ParameterSetName = 'Download')][string]$WorkPath,
        [Parameter(ParameterSetName = 'Download')][AllowNull()][AllowEmptyString()][string]$ApiUrl,
        [Parameter(ParameterSetName = 'Download')][scriptblock]$OnToken,
        [Parameter(ParameterSetName = 'Download')][AllowNull()][AllowEmptyString()][string]$RepositoryRoot,
        [Parameter(ParameterSetName = 'Download')][AllowNull()][AllowEmptyString()][string]$Repository,
        [Parameter(ParameterSetName = 'Download')][AllowNull()][AllowEmptyString()][string]$Ref,
        [Parameter(ParameterSetName = 'Download')][AllowNull()][AllowEmptyString()][string]$RepositoryToken,
        [Parameter(Mandatory, ParameterSetName = 'Local')][string]$TemplatePath,
        [Parameter(ParameterSetName = 'Local')][AllowNull()][AllowEmptyString()][string]$InstalledTemplatePath,
        [Parameter(ParameterSetName = 'Local')][AllowNull()][AllowEmptyString()][string]$TemplateSha
    )
    $notes = [System.Collections.Generic.List[string]]::new()
    if ($PSCmdlet.ParameterSetName -eq 'Local') {
        $info = if ([string]::IsNullOrWhiteSpace($TemplateUrl)) { $null } else { ConvertTo-TemplateUrl -Url $TemplateUrl }
        if (-not (Test-Path -LiteralPath $TemplatePath -PathType Container)) { throw "Template folder not found: $TemplatePath" }
        $path = Find-TemplateRoot -Path $TemplatePath
        $sha = if ([string]::IsNullOrWhiteSpace($TemplateSha)) { Get-TemplateContentSha -Path $path } else { $TemplateSha.Trim() }
        $installedPath = $null
        $installed = $null
        if (-not [string]::IsNullOrWhiteSpace($InstalledTemplatePath)) {
            if (-not (Test-Path -LiteralPath $InstalledTemplatePath -PathType Container)) { throw "Installed template folder not found: $InstalledTemplatePath" }
            $installedPath = (Resolve-Path -LiteralPath $InstalledTemplatePath).ProviderPath
            $installed = Get-TemplateContentSha -Path $installedPath
        }
        return [pscustomobject]@{
            PSTypeName      = 'Rulebook.Template'
            Url             = $(if ($info) { $info.Url } else { $null })
            Repo            = $(if ($info) { $info.Repo } else { 'local template' })
            Branch          = $(if ($info) { $info.Branch } else { $null })
            Sha             = $sha
            Path            = $path
            InstalledPath   = $installedPath
            InstalledSha    = $installed
            InstalledSource = $(if ($null -ne $installedPath) { 'recorded' } else { 'none' })
            Source          = 'local'
            Notes           = @()
        }
    }

    $info = ConvertTo-TemplateUrl -Url $TemplateUrl
    if ([string]::IsNullOrEmpty($WorkPath)) { $WorkPath = Get-DefaultWorkPath }
    # Runs Action with the read token; on 401, 403 or 404 exchanges -Token once and keeps using the result.
    $state = @{ Token = $GitHubToken; Exchanged = $false; WriteToken = $Token; ApiUrl = $ApiUrl; Repo = $info.Repo; OnToken = $OnToken; Notes = $notes }
    $withToken = {
        param([scriptblock]$Action)
        try {
            return & $Action $state.Token
        } catch {
            $original = $_
            $status = $original.Exception.Data['StatusCode']
            if ($state.Exchanged -or [string]::IsNullOrWhiteSpace($state.WriteToken) -or $status -notin 401, 403, 404) { throw }
            $state.Exchanged = $true
            try {
                $exchanged = (Get-GitHubAccessToken -Token $state.WriteToken -Repository $state.Repo -ApiUrl $state.ApiUrl -Permissions ([ordered]@{ contents = 'read'; metadata = 'read' })).Token
            } catch {
                # The original answer (and its status) is what the caller decides on; the exchange error joins its message.
                $wrapped = [System.InvalidOperationException]::new("$($original.Exception.Message). The token could not be used to read $($state.Repo) either: $($_.Exception.Message)", $original.Exception)
                $wrapped.Data['StatusCode'] = $status
                throw $wrapped
            }
            if ($null -ne $state.OnToken -and -not [string]::IsNullOrEmpty($exchanged)) { & $state.OnToken $exchanged }
            $state.Token = $exchanged
            return & $Action $state.Token
        }
    }
    $sha = if ($DownloadLatest -or [string]::IsNullOrWhiteSpace($InstalledSha)) {
        & $withToken { param($t) Get-GitHubBranchSha -Repository $info.Repo -Branch $info.Branch -Token $t -ApiUrl $state.ApiUrl }
    } else {
        $InstalledSha.Trim()
    }
    $extracted = & $withToken { param($t) Save-GitHubZipball -Repository $info.Repo -Sha $sha -Token $t -Path (Join-Path $WorkPath 'template') -ApiUrl $ApiUrl }
    $path = Find-TemplateRoot -Path $extracted

    $installedPath = $null
    $installed = if ([string]::IsNullOrWhiteSpace($InstalledSha)) { $null } else { $InstalledSha.Trim() }
    $installedSource = if ($null -ne $installed) { 'recorded' } else { 'none' }
    $consequence = 'site and docs files that differ from the new template are kept and listed, and files the template dropped get no note.'
    if ($null -eq $installed -and (-not [string]::IsNullOrWhiteSpace($RepositoryRoot) -or -not [string]::IsNullOrWhiteSpace($Repository))) {
        # D50: "Use this template" copies one template commit into a root commit with the same tree; the newest
        # template commit with the tree of the repository's root commit is the installed one.
        $unrecovered = 'templateSha is empty and the installed template commit could not be recovered:'
        $rootTree = Get-RepositoryRootTree -RepositoryRoot $RepositoryRoot -Repository $Repository -Ref $Ref -Token $RepositoryToken -ApiUrl $ApiUrl
        if ($null -eq $rootTree.TreeShas -or @($rootTree.TreeShas).Count -eq 0) {
            $notes.Add("$unrecovered $($rootTree.Note) The $consequence")
        } else {
            if ($rootTree.Note) { $notes.Add($rootTree.Note) }
            try {
                # The token that read the new template; no second exchange. The walk stops at the page with a match.
                $list = Get-GitHubCommitList -Repository $info.Repo -Ref $info.Branch -Token $state.Token -ApiUrl $ApiUrl -TreeSha @($rootTree.TreeShas)
                $match = @($list.Commits | Where-Object { $_.TreeSha -cin @($rootTree.TreeShas) } | Select-Object -First 1)
                if ($match.Count -eq 1) {
                    $installed = $match[0].Sha
                    $installedSource = 'recovered'
                    $notes.Add("templateSha is empty; the installed template commit $(Get-ShortSha $installed) was recovered from the repository's root commit (tree $(Get-ShortSha $match[0].TreeSha)).")
                } else {
                    $cap = if ($list.Truncated) { ' of the list (capped)' } else { '' }
                    $notes.Add("$unrecovered no commit of $($info.Repo)@$($info.Branch) in the last $(@($list.Commits).Count) commits$cap has the tree of the repository's root commit; $consequence")
                }
            } catch {
                $notes.Add("$unrecovered the commits of $($info.Repo)@$($info.Branch) could not be listed ($($_.Exception.Message)); $consequence")
            }
        }
    }
    if ($null -ne $installed) {
        if ($installed -ceq $sha) {
            $installedPath = $path
        } else {
            # With the token that read the new template (exchanged only when that needed it). Any failure here is a
            # note: the update goes on without the three-way comparison and the notes on dropped files.
            try {
                $old = Save-GitHubZipball -Repository $info.Repo -Sha $installed -Token $state.Token -Path (Join-Path $WorkPath 'installed') -ApiUrl $ApiUrl
                $installedPath = Find-TemplateRoot -Path $old
            } catch {
                if ($_.Exception.Data['StatusCode'] -eq 404) {
                    $notes.Add("The installed template commit $(Get-ShortSha $installed) of $($info.Repo) is not available (HTTP 404); $consequence")
                } else {
                    $notes.Add("The installed template commit $(Get-ShortSha $installed) of $($info.Repo) was not downloaded ($($_.Exception.Message)); $consequence")
                }
            }
        }
    }
    return [pscustomobject]@{
        PSTypeName      = 'Rulebook.Template'
        Url             = $info.Url
        Repo            = $info.Repo
        Branch          = $info.Branch
        Sha             = $sha
        Path            = $path
        InstalledPath   = $installedPath
        InstalledSha    = $installed
        InstalledSource = $installedSource
        Source          = 'download'
        Notes           = $notes.ToArray()
    }
}

function Get-InstalledTemplateLine {
    <#
    .SYNOPSIS
    The log line on the installed template of a Rulebook.Template: 'Installed template: recorded <sha7>',
    'Installed template: recovered <sha7> from the root commit' or 'Installed template: not known' (D50).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Template)
    $source = if ($Template.PSObject.Properties['InstalledSource']) { [string]$Template.InstalledSource } else { '' }
    $sha = Get-ShortSha ([string]$Template.InstalledSha)
    switch ($source) {
        'recorded' { return "Installed template: recorded $sha" }
        'recovered' { return "Installed template: recovered $sha from the root commit" }
        default { return 'Installed template: not known' }
    }
}

#endregion

#region File classes and content

function Get-RulebookFileClass {
    <#
    .SYNOPSIS
    The update class of a repository-relative path: { Class, Kind }.
    .DESCRIPTION
    settings: .github/Rulebook-Settings.json. generated: rulesets/*.ruleset.json and skeletons/*.ruleset.json (both
    regenerated on every update). For a path -TemplatePaths contains (shipped): overwrite for
    .github/workflows/*.yml|yaml (kind workflow), .github/*.copy.md (release-notes), .github/ISSUE_TEMPLATE/*,
    base/*.ruleset.json (level), base/twins.json, stages/*.json (stage), skeletons/README.md; customizable for
    site/** except site/data/** (kind site; overwrite when site.updateMode is 'overwrite', D35) and for docs/**
    (kind docs; overwrite when docs.updateMode is 'overwrite', D50). Everything else is org-owned: a path the
    template does not ship, or one outside these patterns (README.md, overrides.json, the quarantine files,
    catalog/**).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [AllowNull()][AllowEmptyCollection()][string[]]$TemplatePaths,
        [AllowNull()]$Settings
    )
    $result = { param($Class, $Kind) [pscustomobject]@{ Class = $Class; Kind = $Kind } }
    if ($Path -ceq $script:SettingsPath) { return & $result 'settings' 'settings' }
    if ($Path -cmatch '^rulesets/[^/]+\.ruleset\.json$') { return & $result 'generated' 'endpoint' }
    if ($Path -cmatch '^skeletons/[^/]+\.ruleset\.json$') { return & $result 'generated' 'skeleton' }
    $shipped = $Path -cin @($TemplatePaths)
    if ($shipped) {
        switch -CaseSensitive -Regex ($Path) {
            '^\.github/workflows/[^/]+\.ya?ml$' { return & $result 'overwrite' 'workflow' }
            '^\.github/[^/]+\.copy\.md$' { return & $result 'overwrite' 'release-notes' }
            '^\.github/ISSUE_TEMPLATE/[^/]+$' { return & $result 'overwrite' 'issue-template' }
            '^base/twins\.json$' { return & $result 'overwrite' 'twins' }
            '^base/[^/]+\.ruleset\.json$' { return & $result 'overwrite' 'level' }
            '^stages/[^/]+\.json$' { return & $result 'overwrite' 'stage' }
            '^skeletons/README\.md$' { return & $result 'overwrite' 'readme' }
            '^site/data/' { return & $result 'org-owned' 'org' }
            '^site/' {
                if ([string](Get-SettingValue $Settings 'site', 'updateMode') -ceq 'overwrite') { return & $result 'overwrite' 'site' }
                return & $result 'customizable' 'site'
            }
            '^docs/' {
                if ([string](Get-SettingValue $Settings 'docs', 'updateMode') -ceq 'overwrite') { return & $result 'overwrite' 'docs' }
                return & $result 'customizable' 'docs'
            }
        }
    }
    return & $result 'org-owned' 'org'
}

function Update-RulebookSettingsText {
    <#
    .SYNOPSIS
    The organization's settings text with $schema, templateUrl and templateSha set, everything else byte for byte.
    .DESCRIPTION
    Edits the three string values in place (never a JSON round trip, which would reformat the file). templateSha
    absent: inserted on its own line after the templateUrl line when that line ends with a comma, else right after
    the templateUrl value on the same line (minified files). $schema absent: inserted as the first property; an
    empty -SchemaUrl leaves $schema alone. No templateUrl throws. Line endings become LF.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Returns a string; changes no state')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [AllowNull()][AllowEmptyString()][string]$SchemaUrl,
        [Parameter(Mandatory)][string]$TemplateUrl,
        [Parameter(Mandatory)][AllowEmptyString()][string]$TemplateSha
    )
    $result = $Text.Replace("`r`n", "`n")
    $url = Get-JsonStringMatch -Text $result -Key 'templateUrl'
    if (-not $url.Success) { throw "No templateUrl in $($script:SettingsPath); the update needs it to know the template." }
    $result = Get-TextWithValue -Text $result -Match $url -Value (Get-JsonStringContent $TemplateUrl)

    $shaValue = Get-JsonStringContent $TemplateSha
    $sha = Get-JsonStringMatch -Text $result -Key 'templateSha'
    if ($sha.Success) {
        $result = Get-TextWithValue -Text $result -Match $sha -Value $shaValue
    } else {
        $url = Get-JsonStringMatch -Text $result -Key 'templateUrl'
        $end = $url.Index + $url.Length
        $lineEnd = $result.IndexOf([char]10, $end)
        if ($lineEnd -lt 0) { $lineEnd = $result.Length }
        $tail = $result.Substring($end, $lineEnd - $end)
        if ($tail -match '^[ \t]*,[ \t]*$') {
            $lineStart = $result.LastIndexOf([char]10, [math]::Max(0, $url.Index - 1)) + 1
            $indent = [regex]::Match($result.Substring($lineStart), '^[ \t]*').Value
            $result = $result.Insert($lineEnd, "`n$indent`"templateSha`": `"$shaValue`",")
        } else {
            $separator = if ($url.Groups[1].Value -match ':[ \t]') { ': ' } else { ':' }
            $space = if ($separator -eq ': ') { ' ' } else { '' }
            $result = $result.Insert($end, ",$space`"templateSha`"$separator`"$shaValue`"")
        }
    }

    if (-not [string]::IsNullOrEmpty($SchemaUrl)) {
        $schemaValue = Get-JsonStringContent $SchemaUrl
        $schema = Get-JsonStringMatch -Text $result -Key '$schema'
        if ($schema.Success) {
            $result = Get-TextWithValue -Text $result -Match $schema -Value $schemaValue
        } else {
            $brace = $result.IndexOf([char]'{')
            if ($brace -lt 0) { throw "$($script:SettingsPath) has no JSON object." }
            $after = $result.Substring($brace + 1)
            $multiLine = [regex]::Match($after, '^[ \t]*\n([ \t]*)')
            if ($multiLine.Success) {
                $result = $result.Insert($brace + 1, "`n$($multiLine.Groups[1].Value)`"`$schema`": `"$schemaValue`",")
            } else {
                $separator = if ($url.Groups[1].Value -match ':[ \t]') { ': ' } else { ':' }
                $space = if ($separator -eq ': ') { ' ' } else { '' }
                $lead = [regex]::Match($after, '^[ \t]*').Value
                $result = $result.Insert($brace + 1 + $lead.Length, "`"`$schema`"$separator`"$schemaValue`",$space")
            }
        }
    }
    return $result
}

function ConvertTo-UpdatedWorkflowText {
    <#
    .SYNOPSIS
    A template workflow as the update writes it into the organization repository.
    .DESCRIPTION
    1. {TEMPLATEURL} becomes -TemplateUrl. 2. Where on:/workflow_dispatch:/inputs:/levels:/options: (or stages:)
    exists, its items become '*' and the level (stage) slugs of -Settings in settings order (D30); the items must be
    indented below options:. 3. For UpdateRulebookSystemFiles.yaml settings update.schedule, for ScanDiagnostics.yaml
    settings scan.schedule (a cron string) adds or replaces schedule: under on:; null removes it. Absent removes it for
    the update workflow and keeps the shipped schedule for the scan workflow. Any other workflow keeps its triggers. Line-based (no YAML parser); output LF, one trailing LF.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string]$FileName,
        [AllowNull()]$Settings,
        [AllowNull()][AllowEmptyString()][string]$TemplateUrl
    )
    $normalized = ConvertTo-UpdateText -Text $Text
    if (-not [string]::IsNullOrEmpty($TemplateUrl)) { $normalized = $normalized.Replace('{TEMPLATEURL}', $TemplateUrl) }
    if ($normalized.Length -eq 0) { return '' }
    [string[]]$lines = $normalized.Substring(0, $normalized.Length - 1).Split("`n")

    foreach ($kind in 'levels', 'stages') {
        $path = "on:/workflow_dispatch:/inputs:/$($kind):/options:/"
        if ($null -eq (Find-YamlPath -Lines $lines -Path $path)) { continue }
        $slugs = @(Get-SettingValue $Settings $kind | Where-Object { $_ -is [System.Collections.IDictionary] -and -not [string]::IsNullOrEmpty([string]$_['name']) } | ForEach-Object { ([string]$_['name']).ToLowerInvariant() })
        $items = @("- '*'") + @($slugs | ForEach-Object { '- ' + (Format-YamlScalar -Value $_) })
        $lines = Set-YamlPath -Lines $lines -Path $path -Content $items
    }

    foreach ($workflow in $script:ScheduledWorkflows.GetEnumerator()) {
        if ($FileName -ine $workflow.Key) { continue }
        $section = Get-SettingValue $Settings $workflow.Value.Path[0]
        $present = $section -is [System.Collections.IDictionary] -and $section.Contains($workflow.Value.Path[1])
        if ($workflow.Value.KeepWhenAbsent -and -not $present) { continue }
        $cron = Get-SettingValue $Settings $workflow.Value.Path
        if ($cron -is [string] -and -not [string]::IsNullOrWhiteSpace($cron)) {
            $lines = Set-YamlKey -Lines $lines -Path 'on:/' -Key 'schedule:' -Content @("- cron: '$($cron.Trim().Replace("'", "''"))'")
        } else {
            $lines = Remove-YamlPath -Lines $lines -Path 'on:/schedule:'
        }
    }
    return ($lines -join "`n") + "`n"
}

function Get-ReleaseNotesDelta {
    <#
    .SYNOPSIS
    The part of the new release notes that is newer than the installed copy.
    .DESCRIPTION
    The new text up to the first '## v*.*' heading of the installed copy (AL-Go): the whole new text when there is
    no installed copy or it has no such heading, an empty string when nothing but a title stands above that heading
    (nothing new), $null when the new text is empty.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$New, [AllowNull()][AllowEmptyString()][string]$Installed)
    $newText = ConvertTo-UpdateText -Text $New
    if ($newText -eq '') { return $null }
    $installedText = ConvertTo-UpdateText -Text $Installed
    if ($installedText -eq '') { return $newText }
    $version = @($installedText.Split("`n") | Where-Object { $_ -like '## v*.*' } | Select-Object -First 1)
    if ($version.Count -eq 0) { return $newText }
    $index = ("`n" + $newText).IndexOf("`n$($version[0])`n", [System.StringComparison]::Ordinal)
    if ($index -lt 0) { return $newText }
    $delta = ConvertTo-UpdateText -Text $newText.Substring(0, $index)
    # Only a title above the installed heading ('# Release notes') is nothing new.
    if ($delta -cnotmatch '(?m)^## ') { return '' }
    return $delta
}

function Compare-CustomizableFile {
    <#
    .SYNOPSIS
    The decision for one customizable (site/**, docs/**) file the new template ships: overwrite, keep, skip, add or none.
    .DESCRIPTION
    -Org, -Old (the template at the installed templateSha) and -New are the normalised contents or $null when the
    file does not exist on that side (D35, D50, dashboard.md section 9). Org absent: add. Org equal to New: none.
    -UpdateMode overwrite: overwrite. Old absent (no installed template, or a file the organization made itself):
    skip. Org equal to Old: overwrite; else New equal to Old: keep; else skip. A file the new template does not ship
    is never decided here (-New $null gives none): removal goes only through unusedRulebookFiles, which
    Get-RulebookUpdatePlan applies to every managed class alike.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        # Untyped: a [string] parameter would turn $null (absent) into '' (empty file).
        [AllowNull()][AllowEmptyString()]$Org,
        [AllowNull()][AllowEmptyString()]$Old,
        [AllowNull()][AllowEmptyString()]$New,
        [AllowNull()][AllowEmptyString()][string]$UpdateMode
    )
    if ($null -eq $New) { return 'none' }
    if ($null -eq $Org) { return 'add' }
    if ($Org -ceq $New) { return 'none' }
    if ($UpdateMode -ceq 'overwrite') { return 'overwrite' }
    if ($null -eq $Old) { return 'skip' }
    if ($Org -ceq $Old) { return 'overwrite' }
    if ($New -ceq $Old) { return 'keep' }
    return 'skip'
}

#endregion

#region Plan

function Get-RulebookUpdatePlan {
    <#
    .SYNOPSIS
    What the update changes in -RepositoryRoot with -Template (Get-RulebookTemplate): a Rulebook.UpdatePlan.
    .DESCRIPTION
    Copies the working tree to <WorkPath>/candidate (without .git, site/data, node_modules), writes the template's
    managed files there by class (Get-RulebookFileClass; only paths the template ships are compared, written or
    removed), edits the settings (Update-RulebookSettingsText), deletes the managed files unusedRulebookFiles lists,
    regenerates skeletons/ (New-RulebookSkeleton, when the folder exists) and rulesets/ (Update-RulebookEndpoints),
    runs Test-Rulebook on the candidate and compares it with the working tree (LF-normalised text, bytes for
    binaries). Returns { TemplateUrl, TemplateRepo, TemplateSha, InstalledSha, InstalledSource, CandidatePath, Changes
    { File, Class, Kind, Change, Bytes }, Skipped { File, Kind, Reason }, Notes, Findings, Valid, ReleaseNotes, ReleaseNotesShipped,
    ShaOnly (only templateSha and the {TEMPLATEURL} placeholder change), UpdatesAvailable }. Never throws on repository content: a settings or generator failure is a Finding with
    Rule 'update' and Severity error.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)]$Template,
        [string]$WorkPath
    )
    $root = (Resolve-Path -LiteralPath $RepositoryRoot -ErrorAction Stop).ProviderPath
    if ([string]::IsNullOrEmpty($WorkPath)) { $WorkPath = Get-DefaultWorkPath }
    $WorkPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($WorkPath)
    $changes = [System.Collections.Generic.List[object]]::new()
    $skipped = [System.Collections.Generic.List[object]]::new()
    $notes = [System.Collections.Generic.List[string]]::new()
    $findings = [System.Collections.Generic.List[object]]::new()
    foreach ($note in @($Template.Notes)) { if ($note) { $notes.Add([string]$note) } }
    $plan = [pscustomobject]@{
        PSTypeName          = 'Rulebook.UpdatePlan'
        TemplateUrl         = $Template.Url
        TemplateRepo        = $Template.Repo
        TemplateSha         = $Template.Sha
        InstalledSha        = $Template.InstalledSha
        InstalledSource     = $(if ($Template.PSObject.Properties['InstalledSource']) { $Template.InstalledSource } else { $null })
        TemplateSource      = $Template.Source
        CandidatePath       = $null
        Changes             = @()
        Skipped             = @()
        Notes               = @()
        Findings            = @()
        Valid               = $false
        ReleaseNotes        = $null
        ReleaseNotesShipped = $false
        ShaOnly             = $false
        UpdatesAvailable    = $false
    }
    $finish = {
        $plan.Changes = $changes.ToArray()
        $plan.Skipped = $skipped.ToArray()
        $plan.Notes = $notes.ToArray()
        $plan.Findings = $findings.ToArray()
        $plan.Valid = @($findings | Where-Object Severity -EQ 'error').Count -eq 0
        return $plan
    }

    # 1. Settings
    $settingsFile = Join-Path $root $script:SettingsPath
    $orgSettingsText = Read-UpdateText -Path $settingsFile
    if ($null -eq $orgSettingsText) {
        $findings.Add((New-UpdateFinding -Message "Settings missing: $($script:SettingsPath) in $root"))
        return & $finish
    }
    try {
        $settings = ConvertFrom-Json -InputObject $orgSettingsText -AsHashtable -Depth 20 -ErrorAction Stop
        if ($settings -isnot [System.Collections.IDictionary]) { throw 'the root is not an object' }
    } catch {
        $findings.Add((New-UpdateFinding -Message "Invalid JSON in $($script:SettingsPath): $($_.Exception.Message)"))
        return & $finish
    }
    [string[]]$unused = @(Get-SettingValue $settings 'unusedRulebookFiles' | Where-Object { $_ -is [string] -and $_ -ne '' })

    # 2. Candidate tree
    $candidate = Join-Path $WorkPath 'candidate'
    if (Test-Path -LiteralPath $candidate) { Remove-Item -LiteralPath $candidate -Recurse -Force }
    Copy-UpdateTree -Source $root -Destination $candidate
    $plan.CandidatePath = $candidate

    $templateRoot = $Template.Path
    [string[]]$newFiles = @(Get-TreeFile -Root $templateRoot)
    $newSet = Get-OrdinalSet -Items $newFiles
    $installedRoot = $Template.InstalledPath
    [string[]]$oldFiles = @(if ($installedRoot) { Get-TreeFile -Root $installedRoot })
    $oldSet = Get-OrdinalSet -Items $oldFiles
    $orgSet = Get-OrdinalSet -Items (Get-TreeFile -Root $root)
    $managedPaths = Get-OrdinalSet -Items ($newFiles + $oldFiles)

    # 3. Managed files the template ships
    foreach ($path in $newFiles) {
        $class = Get-RulebookFileClass -Path $path -TemplatePaths $newFiles -Settings $settings
        if ($class.Class -cin 'org-owned', 'generated', 'settings') { continue }
        if ($path -cin $unused) { continue }
        $target = Join-Path $candidate $path
        $source = Join-Path $templateRoot $path
        if ($class.Class -ceq 'customizable') {
            $org = Get-ComparableContent -Root $root -Path $path
            $old = if ($installedRoot -and $oldSet.Contains($path)) { Get-ComparableContent -Root $installedRoot -Path $path } else { $null }
            $new = Get-ComparableContent -Root $templateRoot -Path $path
            # Each kind has its own key: site.updateMode, docs.updateMode (D50).
            $decision = Compare-CustomizableFile -Org $org -Old $old -New $new -UpdateMode ([string](Get-SettingValue $settings $class.Kind, 'updateMode'))
            if ($decision -cin 'add', 'overwrite') {
                if (Test-BinaryFile -Path $source) { Write-UpdateBinary -Path $target -Bytes ([System.IO.File]::ReadAllBytes($source)) } else { Write-UpdateText -Path $target -Text $new }
            } elseif ($decision -ceq 'skip') {
                $reason = if (-not $installedRoot) { 'no installed template' } elseif (-not $oldSet.Contains($path)) { 'local file' } else { 'local changes' }
                $skipped.Add([pscustomobject]@{ File = $path; Kind = $class.Kind; Reason = $reason })
            }
            continue
        }
        if (Test-BinaryFile -Path $source) {
            Write-UpdateBinary -Path $target -Bytes ([System.IO.File]::ReadAllBytes($source))
        } elseif ($class.Kind -ceq 'workflow') {
            $text = ConvertTo-UpdatedWorkflowText -Text (Read-UpdateText -Path $source) -FileName (Split-Path -Leaf $path) -Settings $settings -TemplateUrl $Template.Url
            Write-UpdateText -Path $target -Text $text
        } else {
            Write-UpdateText -Path $target -Text (Read-UpdateText -Path $source)
        }
    }

    # The settings: the organization's content, $schema of the template, templateUrl and templateSha.
    $schemaUrl = $null
    $templateSettingsText = Read-UpdateText -Path (Join-Path $templateRoot $script:SettingsPath)
    if ($null -ne $templateSettingsText) {
        $schemaMatch = Get-JsonStringMatch -Text $templateSettingsText -Key '$schema'
        if ($schemaMatch.Success) { $schemaUrl = $schemaMatch.Groups[2].Value }
    }
    $templateUrlValue = if ($Template.Url) { [string]$Template.Url } else { [string](Get-SettingValue $settings 'templateUrl') }
    try {
        $settingsText = Update-RulebookSettingsText -Text $orgSettingsText -SchemaUrl $schemaUrl -TemplateUrl $templateUrlValue -TemplateSha ([string]$Template.Sha)
        Write-UpdateText -Path (Join-Path $candidate $script:SettingsPath) -Text $settingsText
    } catch {
        $findings.Add((New-UpdateFinding -Message $_.Exception.Message))
        return & $finish
    }

    # 4. unusedRulebookFiles and files the template dropped
    foreach ($path in $unused) {
        $shipped = $newSet.Contains($path) -or $oldSet.Contains($path)
        $class = Get-RulebookFileClass -Path $path -TemplatePaths @($path) -Settings $settings
        $managed = $shipped -and $class.Class -cin 'overwrite', 'customizable'
        $present = $orgSet.Contains($path)
        if ($present -and $managed) {
            Remove-Item -LiteralPath (Join-Path $candidate $path) -Force
        } elseif (-not $present -and -not $newSet.Contains($path)) {
            $notes.Add("$path is listed in unusedRulebookFiles but the template does not ship it; the entry can be removed.")
        } elseif ($present -and -not $managed) {
            $notes.Add("$path is listed in unusedRulebookFiles, but the template does not manage it; the update leaves it alone.")
        }
    }
    foreach ($path in $oldFiles) {
        if ($newSet.Contains($path) -or $path -cin $unused -or -not $orgSet.Contains($path)) { continue }
        $class = Get-RulebookFileClass -Path $path -TemplatePaths @($path) -Settings $settings
        if ($class.Class -cin 'overwrite', 'customizable') {
            $notes.Add("The template no longer ships $path; list it in unusedRulebookFiles to remove it.")
        }
    }

    # 5. Regenerate the skeletons and the endpoints from the candidate's inputs.
    try {
        $candidateSettings = Join-Path $candidate $script:SettingsPath
        if (Test-Path -LiteralPath (Join-Path $candidate 'skeletons') -PathType Container) {
            $null = New-RulebookSkeleton -SettingsPath $candidateSettings -OutputPath (Join-Path $candidate 'skeletons') -WhatIf:$false -Confirm:$false
        }
        $null = Update-RulebookEndpoints -RepositoryRoot $candidate -WhatIf:$false -Confirm:$false
    } catch {
        $findings.Add((New-UpdateFinding -Message "The updated rulebook cannot be regenerated: $($_.Exception.Message)"))
    }

    # 6. Validate the candidate.
    foreach ($finding in @(Test-Rulebook -RepositoryRoot $candidate)) { $findings.Add($finding) }

    # 7. Compare the candidate with the working tree.
    $candidateSet = Get-OrdinalSet -Items (Get-TreeFile -Root $candidate)
    [string[]]$union = @(@($orgSet) + @($candidateSet) | Sort-Object -Unique -CaseSensitive)
    [System.Array]::Sort($union, [System.StringComparer]::Ordinal)
    foreach ($path in $union) {
        $inOrg = $orgSet.Contains($path)
        $inCandidate = $candidateSet.Contains($path)
        $change = $null
        if ($inCandidate -and -not $inOrg) {
            $change = 'created'
        } elseif ($inOrg -and -not $inCandidate) {
            $change = 'deleted'
        } elseif ((Get-ComparableContent -Root $root -Path $path) -cne (Get-ComparableContent -Root $candidate -Path $path)) {
            $change = 'modified'
        }
        if ($null -eq $change) { continue }
        $class = Get-RulebookFileClass -Path $path -TemplatePaths $(if ($managedPaths.Contains($path) -or $path -cin $unused) { @($path) } else { @() }) -Settings $settings
        $bytes = if ($change -ceq 'deleted') { $null } else { [System.IO.File]::ReadAllBytes((Join-Path $candidate $path)) }
        $changes.Add([pscustomobject]@{ File = $path; Class = $class.Class; Kind = $class.Kind; Change = $change; Bytes = $bytes })
    }
    # Sha-only: nothing but the bookkeeping of a first run changes, that is templateSha in the settings and the
    # {TEMPLATEURL} placeholder of a workflow (a repository fresh from the template has both).
    $bookkeeping = $changes.Count -gt 0
    foreach ($change in $changes) {
        if ($change.Change -cne 'modified') { $bookkeeping = $false; break }
        # Text is read only for the two bookkeeping kinds; anything else (a binary included) is a real change.
        if ($change.File -ceq $script:SettingsPath) {
            $candidateText = Read-UpdateText -Path (Join-Path $candidate $change.File)
            if ((Get-TextWithoutSha -Text $orgSettingsText) -cne (Get-TextWithoutSha -Text $candidateText)) { $bookkeeping = $false; break }
        } elseif ($change.Kind -ceq 'workflow' -and $templateUrlValue -and -not (Test-BinaryFile -Path (Join-Path $candidate $change.File))) {
            $candidateText = Read-UpdateText -Path (Join-Path $candidate $change.File)
            if ((Read-UpdateText -Path (Join-Path $root $change.File)).Replace('{TEMPLATEURL}', $templateUrlValue) -cne $candidateText) { $bookkeeping = $false; break }
        } else {
            $bookkeeping = $false
            break
        }
    }
    $plan.ShaOnly = $bookkeeping
    $plan.UpdatesAvailable = $changes.Count -gt 0 -and -not $plan.ShaOnly

    # 8. Release notes
    $newNotes = Read-UpdateText -Path (Join-Path $templateRoot $script:ReleaseNotesPath)
    $plan.ReleaseNotesShipped = $null -ne $newNotes
    if ($plan.ReleaseNotesShipped) {
        $plan.ReleaseNotes = Get-ReleaseNotesDelta -New $newNotes -Installed (Read-UpdateText -Path (Join-Path $root $script:ReleaseNotesPath))
    }
    return & $finish
}

function Get-RulebookUpdateStatus {
    <#
    .SYNOPSIS
    The check-mode outcome of a plan: { Status (none, sha-only, available, skipped), Command (notice, warning), Message }.
    .DESCRIPTION
    One wording for the Validate action and the CheckForUpdates action. An invalid plan is skipped with its first
    error; updates available name the number of files.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)]$Plan)
    if (-not $Plan.Valid) {
        $first = @($Plan.Findings | Where-Object Severity -EQ 'error' | Select-Object -First 1)
        $what = if ($first.Count -gt 0) { $(if ($first[0].File) { "$($first[0].Rule) $($first[0].File): $($first[0].Message)" } else { "$($first[0].Rule): $($first[0].Message)" }) } else { 'unknown error' }
        return [pscustomobject]@{ Status = 'skipped'; Command = 'warning'; Message = "update check skipped: the updated rulebook would not validate ($what)" }
    }
    if ($Plan.UpdatesAvailable) {
        return [pscustomobject]@{ Status = 'available'; Command = 'warning'; Message = "Updates available: run the Update Rulebook System Files workflow ($(@($Plan.Changes).Count) files)" }
    }
    if ($Plan.ShaOnly) {
        return [pscustomobject]@{ Status = 'sha-only'; Command = 'notice'; Message = "template commit $(Get-ShortSha $Plan.TemplateSha) not recorded; run Update Rulebook System Files once" }
    }
    return [pscustomobject]@{ Status = 'none'; Command = 'notice'; Message = 'No updates available' }
}

#endregion

#region Pull request

function Get-EffectiveDiffBlock {
    <#
    .SYNOPSIS
    One Markdown block per endpoint: a heading and a | Id | Before | After | Decided by | table.
    .DESCRIPTION
    The rendering of Validate.ps1, shared by the update and the scan pull request bodies. Endpoints in the order of
    -Diff (settings order).
    .NOTES
    The array is returned with a leading comma so that a one-element result stays an array. Callers assign it
    directly or to [string[]] and never wrap the call in @(), which would nest it and print System.String[] (#75).
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([AllowNull()][AllowEmptyCollection()][object[]]$Diff, [string]$Heading = '###')
    $blocks = [System.Collections.Generic.List[string]]::new()
    # Endpoints in the order of the diff (settings order); Group-Object would sort them by name.
    $groups = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::Ordinal)
    foreach ($row in @($Diff)) {
        if (-not $groups.Contains([string]$row.Endpoint)) { $groups[[string]$row.Endpoint] = [System.Collections.Generic.List[object]]::new() }
        $groups[[string]$row.Endpoint].Add($row)
    }
    foreach ($group in @($groups.Values | ForEach-Object { [pscustomobject]@{ Group = $_.ToArray() } })) {
        $first = $group.Group[0]
        $text = [System.Text.StringBuilder]::new()
        [void]$text.AppendLine(('{0} `{1}` (`{2}`)' -f $Heading, $first.Endpoint, $first.File)).AppendLine()
        [void]$text.AppendLine('| Id | Before | After | Decided by |').AppendLine('|---|---|---|---|')
        foreach ($row in $group.Group) {
            $before = if ($row.Before) { $row.Before } elseif ($row.BeforeSource) { '(unknown default)' } else { '(absent)' }
            $after = if ($row.After) { $row.After } elseif ($row.AfterSource) { '(unknown default)' } else { '(absent)' }
            $decidedBy = if (-not $row.AfterSource) { '' } elseif ($row.AfterDetail) { '{0}, "{1}"' -f $row.AfterSource, $row.AfterDetail } else { $row.AfterSource }
            if ($row.Change -eq 'listing') {
                $decidedBy += $(if ($row.ListedAfter) { ' (the analyzer default moved; now listed)' } else { ' (now the analyzer default; no longer listed)' })
            }
            [void]$text.AppendLine(('| {0} | {1} | {2} | {3} |' -f (Format-TableCell $row.Id), $before, $after, (Format-TableCell $decidedBy)))
        }
        [void]$text.AppendLine()
        $blocks.Add($text.ToString())
    }
    return , [string[]]$blocks.ToArray()
}

function Get-PlanSection {
    # The sections of a plan as separate Markdown strings ('' when a section is empty): Changes, Skipped, Notes,
    # Warnings. The body and the summary concatenate them in their own order.
    param([Parameter(Mandatory)]$Plan, [string]$CompareUrl)
    $changes = [System.Text.StringBuilder]::new()
    [void]$changes.AppendLine('## Changes').AppendLine()
    if (@($Plan.Changes).Count -eq 0) {
        [void]$changes.AppendLine('No file changes.').AppendLine()
    } else {
        [void]$changes.AppendLine('| File | Class | Change |').AppendLine('|---|---|---|')
        foreach ($change in $Plan.Changes) { [void]$changes.AppendLine(('| `{0}` | {1} | {2} |' -f $change.File, $change.Class, $change.Change)) }
        [void]$changes.AppendLine()
    }
    $skipped = [System.Text.StringBuilder]::new()
    if (@($Plan.Skipped).Count -gt 0) {
        # The key of every kind present (site.updateMode, docs.updateMode, D50); an item without Kind is a site file.
        [string[]]$keys = @(@($Plan.Skipped | ForEach-Object { if ($_.PSObject.Properties['Kind'] -and $_.Kind) { [string]$_.Kind } else { 'site' } }) |
                Sort-Object -Unique -CaseSensitive | ForEach-Object { "$_.updateMode" })
        [void]$skipped.AppendLine('## Skipped: local changes').AppendLine()
        [void]$skipped.AppendLine("These files differ from the template and were kept. Compare them with the template and take over what you need, or set $($keys -join ' or ') to overwrite.").AppendLine()
        # Only when no installed commit is known at all; a recorded or recovered commit whose zipball failed has its
        # own note.
        $source = if ($Plan.PSObject.Properties['InstalledSource']) { [string]$Plan.InstalledSource } else { '' }
        if ($source -ceq 'none' -and @($Plan.Skipped | Where-Object Reason -CEQ 'no installed template').Count -gt 0) {
            [void]$skipped.AppendLine('The installed template commit is not recorded in templateSha and could not be recovered, so every file that differs from the template counts as changed here.').AppendLine()
        }
        foreach ($item in $Plan.Skipped) { [void]$skipped.AppendLine(('- `{0}`: {1}' -f $item.File, $item.Reason)) }
        if ($CompareUrl) { [void]$skipped.AppendLine().AppendLine("Template changes since the installed version: $CompareUrl") }
        [void]$skipped.AppendLine()
    }
    $notes = [System.Text.StringBuilder]::new()
    if (@($Plan.Notes).Count -gt 0) {
        [void]$notes.AppendLine('## Notes').AppendLine()
        foreach ($note in $Plan.Notes) { [void]$notes.AppendLine("- $note") }
        [void]$notes.AppendLine()
    }
    $warnings = [System.Text.StringBuilder]::new()
    $warningFindings = @($Plan.Findings | Where-Object Severity -EQ 'warning')
    if ($warningFindings.Count -gt 0) {
        [void]$warnings.AppendLine('## Validation warnings').AppendLine()
        [void]$warnings.AppendLine('| Rule | File | Id | Message |').AppendLine('|---|---|---|---|')
        foreach ($finding in $warningFindings) {
            $file = if ($finding.File) { '`' + $finding.File + '`' } else { '' }
            [void]$warnings.AppendLine(('| {0} | {1} | {2} | {3} |' -f $finding.Rule, $file, (Format-TableCell $finding.Id), (Format-TableCell $finding.Message)))
        }
        [void]$warnings.AppendLine()
    }
    return [pscustomobject]@{ Changes = $changes.ToString(); Skipped = $skipped.ToString(); Notes = $notes.ToString(); Warnings = $warnings.ToString() }
}

function ConvertTo-ReleaseNotesMarkdown {
    # Release notes placed below a '## Release notes' heading: outside fenced code blocks (``` or ~~~) a title line
    # ('# ...') goes and every other heading moves one level down; fenced lines stay as they are.
    param([Parameter(Mandatory)][string]$Text)
    $result = [System.Collections.Generic.List[string]]::new()
    $fence = $null
    foreach ($line in $Text.TrimEnd().Split("`n")) {
        $marker = [regex]::Match($line, '^[ ]{0,3}(`{3,}|~{3,})')
        if ($null -ne $fence) {
            if ($marker.Success -and $marker.Groups[1].Value[0] -ceq $fence[0] -and $marker.Groups[1].Value.Length -ge $fence.Length -and $line.Trim() -ceq $marker.Groups[1].Value) { $fence = $null }
            $result.Add($line)
            continue
        }
        if ($marker.Success) {
            $fence = $marker.Groups[1].Value
            $result.Add($line)
            continue
        }
        if ($line -cmatch '^# ') { continue }
        if ($line -cmatch '^#{2,5} ') { $result.Add("#$line"); continue }
        $result.Add($line)
    }
    return ($result -join "`n").Trim()
}

function Get-CompareUrl {
    param([Parameter(Mandatory)]$Plan)
    if ($Plan.TemplateSource -cne 'download' -or [string]::IsNullOrEmpty($Plan.InstalledSha) -or $Plan.InstalledSha -ceq $Plan.TemplateSha) { return $null }
    $server = if ($env:GITHUB_SERVER_URL) { $env:GITHUB_SERVER_URL.TrimEnd('/') } else { 'https://github.com' }
    return "$server/$($Plan.TemplateRepo)/compare/$($Plan.InstalledSha)...$($Plan.TemplateSha)"
}

function ConvertTo-UpdatePullRequestBody {
    <#
    .SYNOPSIS
    The pull request body of an update: the changes, the effective diff, skipped customizable files, validation
    warnings and the release notes.
    .DESCRIPTION
    Sections in order: '## Changes' (| File | Class | Change |), '## Effective diff' (one | Id | Before | After |
    Decided by | table per endpoint, or 'No effective change.'), '## Skipped: local changes' and '## Notes'
    when there are any, '## Validation warnings' when there are any, '## Release notes' with the new part of
    RELEASENOTES.copy.md or 'No release notes available' (left out when the template ships no release notes).
    Above the 65536-character limit of GitHub (-Limit, default 60000) whole parts are dropped, the release notes
    first, then endpoint tables of the effective diff from the end, each with one italic line saying what is missing;
    only when that is not enough is the body cut, at a line boundary.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]$Plan,
        [AllowNull()][AllowEmptyCollection()][object[]]$Diff,
        [string]$TemplateRepo,
        [string]$Branch,
        [string]$DiffNote,
        [int]$Limit = $script:BodyLimit
    )
    if ([string]::IsNullOrEmpty($TemplateRepo)) { $TemplateRepo = $Plan.TemplateRepo }
    $intro = ('Updates the Rulebook system files of `{0}` from {1} at {2}. The endpoints in rulesets/ and the skeletons are regenerated from the new level and stage files and this repository''s settings, overrides and quarantine; the effective diff below is what changes for the AL projects.' -f $Branch, $TemplateRepo, (Get-ShortSha $Plan.TemplateSha)) + "`n`n"
    $sections = Get-PlanSection -Plan $Plan -CompareUrl (Get-CompareUrl -Plan $Plan)
    $diffHead = "## Effective diff`n`n"
    [string[]]$diffBlocks = @()
    $diffEmpty = ''
    if ($DiffNote) {
        $diffEmpty = "$DiffNote`n`n"
    } elseif (@($Diff).Count -eq 0) {
        $diffEmpty = "No effective change.`n`n"
    } else {
        $diffBlocks = Get-EffectiveDiffBlock -Diff $Diff
    }
    $notes = ''
    if ($Plan.ReleaseNotesShipped) {
        $content = if ([string]::IsNullOrWhiteSpace($Plan.ReleaseNotes)) { 'No release notes available' } else { ConvertTo-ReleaseNotesMarkdown -Text $Plan.ReleaseNotes }
        $notes = "## Release notes`n`n$content`n`n"
    }

    $build = {
        param([string]$ReleaseNotes, [int]$BlockCount, [string]$DroppedNote)
        $diffText = $diffHead + $diffEmpty + (@($diffBlocks | Select-Object -First $BlockCount) -join '')
        if ($DroppedNote) { $diffText += "$DroppedNote`n`n" }
        return ($intro + $sections.Changes + $diffText + $sections.Skipped + $sections.Notes + $sections.Warnings + $ReleaseNotes).Replace("`r`n", "`n")
    }
    $body = & $build $notes $diffBlocks.Count $null
    if ($body.Length -le $Limit) { return $body }

    # Too long: the release notes go first (they are in .github/RELEASENOTES.copy.md of this pull request).
    $notesDropped = if ($notes) { "## Release notes`n`n_The release notes were left out to keep this body below the GitHub limit; they are in .github/RELEASENOTES.copy.md of this pull request._`n`n" } else { '' }
    $body = & $build $notesDropped $diffBlocks.Count $null
    if ($body.Length -le $Limit) { return $body }

    # Then endpoint tables of the effective diff, from the end.
    for ($count = $diffBlocks.Count - 1; $count -ge 0; $count--) {
        $dropped = "_$($diffBlocks.Count - $count) of $($diffBlocks.Count) endpoint tables of the effective diff were left out to keep this body below the GitHub limit; the job summary of the update run has them all._"
        $body = & $build $notesDropped $count $dropped
        if ($body.Length -le $Limit) { return $body }
    }

    # Still too long (a huge change table): cut at a line boundary.
    $tail = "`n_The body was cut at a line boundary to stay below the GitHub limit; the job summary of the update run has the full lists._`n"
    $cut = $body.LastIndexOf("`n", [math]::Max(0, $Limit - $tail.Length - 1), [System.StringComparison]::Ordinal)
    if ($cut -lt 0) { $cut = 0 }
    return $body.Substring(0, $cut + 1) + $tail
}

function ConvertTo-UpdateSummary {
    <#
    .SYNOPSIS
    The job summary of an update run: '## Template update check' (-Mode check) or '## Rulebook system files update'.
    .DESCRIPTION
    The message and result line, the change table, skipped customizable files, notes, validation warnings and errors, the
    effective diff (or why it could not be computed) when -Result carries one, and the new release notes. The
    entry script caps it below the step summary limit.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]$Plan,
        [AllowNull()]$Result,
        [ValidateSet('check', 'update')][string]$Mode = 'check',
        [string]$Message
    )
    $text = [System.Text.StringBuilder]::new()
    $title = if ($Mode -eq 'check') { '## Template update check' } else { '## Rulebook system files update' }
    [void]$text.AppendLine($title).AppendLine()
    [void]$text.AppendLine(('Template {0} at `{1}`.' -f $Plan.TemplateRepo, (Get-ShortSha $Plan.TemplateSha))).AppendLine()
    if ($Message) { [void]$text.AppendLine("**$Message**").AppendLine() }
    if ($null -ne $Result) {
        $line = switch ($Result.Result) {
            'pull-request' { "Pull request: $($Result.PullRequestUrl)" + $(if ($Result.Fallback) { ' (the direct commit was refused)' } else { '' }) }
            'direct-commit' { "Committed $(Get-ShortSha $Result.Sha) to $($Result.Branch)." }
            'exists' { "Pull request already exists: $($Result.PullRequestUrl)" }
            'no-changes' { 'No changes to commit.' }
            default { [string]$Result.Result }
        }
        [void]$text.AppendLine($line).AppendLine()
    }
    $sections = Get-PlanSection -Plan $Plan -CompareUrl (Get-CompareUrl -Plan $Plan)
    [void]$text.Append($sections.Changes).Append($sections.Skipped).Append($sections.Notes).Append($sections.Warnings)
    $errors = @($Plan.Findings | Where-Object Severity -EQ 'error')
    if ($errors.Count -gt 0) {
        [void]$text.AppendLine('## Validation errors of the updated rulebook').AppendLine()
        [void]$text.AppendLine('| Rule | File | Id | Message |').AppendLine('|---|---|---|---|')
        foreach ($finding in $errors) {
            $file = if ($finding.File) { '`' + $finding.File + '`' } else { '' }
            [void]$text.AppendLine(('| {0} | {1} | {2} | {3} |' -f $finding.Rule, $file, (Format-TableCell $finding.Id), (Format-TableCell $finding.Message)))
        }
        [void]$text.AppendLine()
    }
    $diffNote = if ($null -ne $Result -and $Result.PSObject.Properties['DiffNote']) { [string]$Result.DiffNote } else { '' }
    if ($diffNote) {
        [void]$text.AppendLine('## Effective diff').AppendLine().AppendLine($diffNote).AppendLine()
    } elseif ($null -ne $Result -and @($Result.Diff).Count -gt 0) {
        [void]$text.AppendLine('## Effective diff').AppendLine()
        # Get-EffectiveDiffBlock returns its array with a comma; @() around it would nest it and print System.String[] (#75).
        [string[]]$blocks = Get-EffectiveDiffBlock -Diff @($Result.Diff)
        [void]$text.Append(($blocks -join ''))
    }
    if ($Plan.ReleaseNotesShipped -and -not [string]::IsNullOrWhiteSpace($Plan.ReleaseNotes)) {
        [void]$text.AppendLine('## Release notes').AppendLine().AppendLine((ConvertTo-ReleaseNotesMarkdown -Text $Plan.ReleaseNotes)).AppendLine()
    }
    return $text.ToString().Replace("`r`n", "`n")
}

function Publish-RulebookUpdate {
    <#
    .SYNOPSIS
    Applies a valid plan to a fresh clone and opens the pull request (or pushes the direct commit).
    .DESCRIPTION
    Refuses an invalid plan. The title is [<branch>@<sha7>] Update Rulebook System Files from <owner>/<repo> -
    <templateSha7>, <sha7> the branch head; for a pull request an open one with that title into -UpdateBranch gives
    Result exists before anything is cloned (no guard for -DirectCommit, whose <sha7> is the cloned head). Clones
    -RemoteUrl (default <GITHUB_SERVER_URL>/<Repository>) at -UpdateBranch, writes the plan's changes,
    commits with the title and pushes update-rulebook-system-files/<branch>/<yyMMddHHmmss UTC> (or -UpdateBranch
    with -DirectCommit, falling back to the branch when the push is refused). Diff is the effective diff of the
    commit against the cloned head. Returns { Result (pull-request, direct-commit, exists, no-changes),
    PullRequestUrl, Branch, Sha, Fallback, FallbackReason, Diff, DiffNote, Body, Title }; FallbackReason is the git
    output of the refused direct push ($null without a fallback). A failure throws with Data['Stage']: push for the
    clone, commit and push; pull-request for the duplicate guard, the body and the opening (then naming the pushed
    branch and its tree link, with Data['Branch']). After a refused direct push both stages carry
    Data['FallbackReason'] (push: the fallback branch failed too).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]$Plan,
        [string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$Repository,
        [string]$RemoteUrl,
        [AllowNull()][AllowEmptyString()][string]$Token,
        [Parameter(Mandatory)][string]$UpdateBranch,
        [switch]$DirectCommit,
        [AllowNull()][AllowEmptyString()][string]$Actor,
        [AllowNull()][AllowEmptyCollection()][string[]]$Labels,
        [string]$TemplateRepo,
        [string]$WorkPath,
        [AllowNull()][AllowEmptyString()][string]$ApiUrl,
        [System.DateTimeOffset]$Now = [System.DateTimeOffset]::UtcNow
    )
    if (-not $Plan.Valid) { throw 'The update plan does not validate; nothing is pushed.' }
    if ([string]::IsNullOrEmpty($TemplateRepo)) { $TemplateRepo = $Plan.TemplateRepo }
    if ([string]::IsNullOrEmpty($WorkPath)) { $WorkPath = Get-DefaultWorkPath }
    $server = if ($env:GITHUB_SERVER_URL) { $env:GITHUB_SERVER_URL.TrimEnd('/') } else { 'https://github.com' }
    if ([string]::IsNullOrEmpty($RemoteUrl)) { $RemoteUrl = "$server/$Repository" }
    $stageError = {
        param([string]$Stage, [System.Management.Automation.ErrorRecord]$Record)
        $exception = [System.InvalidOperationException]::new($Record.Exception.Message, $Record.Exception)
        $exception.Data['Stage'] = $Stage
        # A refused direct push whose fallback branch failed too (#77).
        if ($Record.Exception.Data.Contains('FallbackReason')) { $exception.Data['FallbackReason'] = $Record.Exception.Data['FallbackReason'] }
        return $exception
    }

    # The rulebook may sit in a folder of a bigger repository; the plan's paths are relative to that folder.
    $prefix = ''
    if ($RepositoryRoot -and (Get-Command git -ErrorAction SilentlyContinue)) {
        $show = & git -C $RepositoryRoot rev-parse --show-prefix 2>$null
        if ($LASTEXITCODE -eq 0 -and $show) { $prefix = ([string]$show).Trim() }
    }

    $newTitle = { param([string]$Sha) "[$UpdateBranch@$(Get-ShortSha $Sha)] $($script:TitlePrefix) $TemplateRepo - $(Get-ShortSha $Plan.TemplateSha)" }
    $title = $null
    if (-not $DirectCommit) {
        # The duplicate guard (branch head for the title, open pull requests) belongs to the pull request stage. A
        # direct commit has no guard (AL-Go does not dedupe them either); its title takes the cloned head.
        try {
            $title = & $newTitle (Get-GitHubBranchSha -Repository $Repository -Branch $UpdateBranch -Token $Token -ApiUrl $ApiUrl)
            $existing = Find-GitHubPullRequest -Repository $Repository -Base $UpdateBranch -Title $title -Token $Token -ApiUrl $ApiUrl
        } catch {
            throw (& $stageError 'pull-request' $_)
        }
        if ($null -ne $existing) {
            return [pscustomobject]@{ Result = 'exists'; PullRequestUrl = $existing.Url; Branch = $null; Sha = $null; Fallback = $false; FallbackReason = $null; Diff = @(); DiffNote = $null; Body = $null; Title = $title }
        }
    }

    $newBranch = '{0}/{1}/{2}' -f $script:BranchPrefix, $UpdateBranch, $Now.UtcDateTime.ToString('yyMMddHHmmss', [System.Globalization.CultureInfo]::InvariantCulture)
    try {
        $clone = New-GitHubClone -RemoteUrl $RemoteUrl -Branch $UpdateBranch -Path (Join-Path $WorkPath 'clone') -Token $Token -Actor $Actor
        if ($null -eq $title) { $title = & $newTitle $clone.BaseSha }
        $rulebookRoot = if ($prefix) { Join-Path $clone.Path $prefix.TrimEnd('/') } else { $clone.Path }
        foreach ($change in $Plan.Changes) {
            $target = Join-Path $rulebookRoot $change.File
            if ($change.Change -ceq 'deleted') {
                if (Test-Path -LiteralPath $target -PathType Leaf) { Remove-Item -LiteralPath $target -Force }
            } else {
                Write-UpdateBinary -Path $target -Bytes $change.Bytes
            }
        }
        $pushed = Publish-GitHubChange -Clone $clone -Message $title -NewBranch $newBranch -DirectCommit:$DirectCommit
    } catch {
        throw (& $stageError 'push' $_)
    }
    if (-not $pushed.Pushed) {
        return [pscustomobject]@{ Result = 'no-changes'; PullRequestUrl = $null; Branch = $pushed.Branch; Sha = $pushed.Sha; Fallback = $false; FallbackReason = $null; Diff = @(); DiffNote = $null; Body = $null; Title = $title }
    }

    $diff = @()
    $diffNote = $null
    try {
        $diff = @(Compare-RulebookEndpoints -RepositoryRoot $rulebookRoot -Ref $clone.BaseSha)
    } catch {
        $diffNote = "The effective diff could not be computed: $($_.Exception.Message)"
    }
    if ($pushed.Direct) {
        return [pscustomobject]@{ Result = 'direct-commit'; PullRequestUrl = $null; Branch = $pushed.Branch; Sha = $pushed.Sha; Fallback = $false; FallbackReason = $null; Diff = $diff; DiffNote = $diffNote; Body = $null; Title = $title }
    }
    # The branch is pushed from here on: a failure names it, so the pull request can be opened by hand.
    try {
        $body = ConvertTo-UpdatePullRequestBody -Plan $Plan -Diff $diff -TemplateRepo $TemplateRepo -Branch $UpdateBranch -DiffNote $diffNote
        $pull = New-GitHubPullRequest -Repository $Repository -Token $Token -Title $title -Body $body -Head $pushed.Branch -Base $UpdateBranch -Labels $Labels -ApiUrl $ApiUrl -ServerUrl $server
    } catch {
        $segments = @(foreach ($part in @($Repository.Split('/')) + @('tree') + @($pushed.Branch.Split('/'))) { [System.Uri]::EscapeDataString($part) })
        $link = "$server/$($segments -join '/')"
        # Always say that the branch is pushed; the link to open the pull request by hand is added unless the API
        # message (New-GitHubPullRequest) carries it already.
        $message = "Branch $($pushed.Branch) was pushed. $($_.Exception.Message)"
        if (-not $message.Contains($link)) { $message += " Open the pull request by hand: $link" }
        $exception = [System.InvalidOperationException]::new($message, $_.Exception)
        $exception.Data['Stage'] = 'pull-request'
        $exception.Data['Branch'] = $pushed.Branch
        # The refused direct push is reported even when the pull request then fails (#77).
        if ($pushed.Fallback) { $exception.Data['FallbackReason'] = $pushed.FallbackReason }
        throw $exception
    }
    return [pscustomobject]@{ Result = 'pull-request'; PullRequestUrl = $pull.Url; Branch = $pushed.Branch; Sha = $pushed.Sha; Fallback = $pushed.Fallback; FallbackReason = $pushed.FallbackReason; Diff = $diff; DiffNote = $diffNote; Body = $body; Title = $title }
}

#endregion

Export-ModuleMember -Function @(
    'Compare-CustomizableFile'
    'Get-ShortSha'
    'Copy-UpdateTree'
    'Get-ComparableContent'
    'Get-DefaultWorkPath'
    'Get-TreeFile'
    'Test-BinaryFile'
    'ConvertTo-TemplateUrl'
    'ConvertTo-UpdatedWorkflowText'
    'ConvertTo-UpdatePullRequestBody'
    'ConvertTo-UpdateSummary'
    'Get-ReleaseNotesDelta'
    'Get-EffectiveDiffBlock'
    'Get-RulebookFileClass'
    'Get-InstalledTemplateLine'
    'Get-RepositoryRootTree'
    'Get-RulebookTemplate'
    'Get-RulebookUpdatePlan'
    'Get-RulebookUpdateStatus'
    'Get-TemplateContentSha'
    'Publish-RulebookUpdate'
    'Update-RulebookSettingsText'
)
