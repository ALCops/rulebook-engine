#requires -Version 7.4
# Rulebook.Deploy: the release of the engine and the template (WP13, D52). A release reads the version and the notes
# from the top heading of RELEASENOTES.md, copies template/ into a clone of ALCops/rulebook@v<major> with every
# ALCops/rulebook and ALCops/rulebook-engine reference on main rewritten to that branch, writes the release notes
# copy, commits and tags there, moves the engine's floating branch v<major> to the released commit and tags it, and
# creates the GitHub Release on the engine. The refresh copies template/ verbatim to ALCops/rulebook@main (no
# rewrite, no tag, no release). Both authenticate as the ALCops GitHub App and commit directly.
# Contract: docs/releasing.md. Imports Rulebook.Common (git runner) and Rulebook.GitHub (token exchange, REST, clone).

Set-StrictMode -Version 3.0
Import-Module (Join-Path $PSScriptRoot 'Rulebook.Common.psd1')
Import-Module (Join-Path $PSScriptRoot 'Rulebook.GitHub.psd1')

$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$script:EngineRepository = 'ALCops/rulebook-engine'
$script:TemplateRepository = 'ALCops/rulebook'
$script:ReleaseNotesFile = 'RELEASENOTES.md'
$script:ReleaseNotesCopy = '.github/RELEASENOTES.copy.md'
$script:VersionPattern = '^## v(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z]+(?:\.[0-9A-Za-z]+)*))?\s*$'
# A main that names a branch of the engine or the template: @main (templateUrl), /main/ of a raw URL, /blob/main/,
# /raw/main/, /tree/main/, and actions/<Name>@main of a uses: line. Not "the main branch", maintain or
# rulebook-engine-main.
$script:ReferencePattern = '(?<=ALCops/rulebook(?:-engine)?(?:/blob|/raw|/tree|/actions/[A-Za-z0-9._-]+)?[/@])main(?![\w-])'
$script:RewriteExtensions = @('.md', '.yaml', '.yml', '.json', '.ps1', '.txt', '.html')
$script:DeployPermissions = [ordered]@{ contents = 'write'; workflows = 'write'; checks = 'read'; metadata = 'read' }
# Check runs of the deploy itself on the released commit; they are running while the precondition is checked.
$script:OwnCheckRuns = @('deploy', 'refresh')

#region Internal helpers

function Assert-DeployGit {
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

function Get-RemoteRefSha {
    # The sha of Ref (refs/heads/x, refs/tags/x) on RemoteUrl from git ls-remote, $null when it does not exist.
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$RemoteUrl, [Parameter(Mandatory)][string]$Ref, [System.Collections.IDictionary]$Environment)
    $result = Assert-DeployGit -Root $Root -Arguments @('ls-remote', $RemoteUrl, $Ref) -Environment $Environment -What "git ls-remote $Ref"
    foreach ($line in $result.Output.Split("`n")) {
        $parts = @($line.Trim() -split '\s+')
        if ($parts.Count -ge 2 -and $parts[1] -ceq $Ref) { return $parts[0] }
    }
    return $null
}

function Get-KeepList {
    # The relative paths of a keep file: one per line, '#' comments and blank lines ignored, '\' read as '/'.
    param([AllowNull()][AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrEmpty($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return , @() }
    $entries = foreach ($line in [System.IO.File]::ReadAllLines($Path, $script:Utf8NoBom)) {
        $value = $line.Trim()
        if ($value -eq '' -or $value.StartsWith('#')) { continue }
        $value.Replace('\', '/').Trim('/')
    }
    return , @($entries)
}

function Test-KeptPath {
    param([Parameter(Mandatory)][string]$Relative, [string[]]$Keep)
    foreach ($entry in $Keep) {
        if ($Relative -ceq $entry -or $Relative.StartsWith("$entry/", [System.StringComparison]::Ordinal)) { return $true }
    }
    return $false
}

function Get-TreeFile {
    # The files under Root as sorted '/'-separated relative paths, without .git.
    param([Parameter(Mandatory)][string]$Root)
    $full = (Resolve-Path -LiteralPath $Root).ProviderPath
    [string[]]$files = @(Get-ChildItem -LiteralPath $full -Recurse -File -Force | ForEach-Object {
            $relative = [System.IO.Path]::GetRelativePath($full, $_.FullName).Replace('\', '/')
            if ($relative -cne '.git' -and -not $relative.StartsWith('.git/', [System.StringComparison]::Ordinal)) { $relative }
        })
    [System.Array]::Sort($files, [System.StringComparer]::Ordinal)
    return , $files
}

function Get-Sha7 {
    param([AllowNull()][AllowEmptyString()][string]$Sha)
    if ([string]::IsNullOrEmpty($Sha)) { return '' }
    return $Sha.Substring(0, [Math]::Min(7, $Sha.Length))
}

function ConvertTo-AnnotationText {
    # A message for one workflow command line (::error::): '%', CR and LF escaped as the runner expects.
    param([AllowNull()][AllowEmptyString()][string]$Text)
    return ([string]$Text).Replace('%', '%25').Replace("`r", '%0D').Replace("`n", '%0A')
}

function Get-ApiText {
    param($Response)
    if ($null -ne $Response.Body -and $Response.Body -is [System.Collections.IDictionary] -and $Response.Body.Contains('message')) { return [string]$Response.Body['message'] }
    return [string]$Response.Text
}

function Invoke-DeployPublish {
    # The writing part of Invoke-RulebookDeploy after the preconditions; fills Result (an ordered dictionary).
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Result,
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$WorkPath,
        [AllowNull()][AllowEmptyString()][string]$KeepPath,
        [AllowNull()][AllowEmptyString()][string]$ApiUrl,
        [AllowNull()][AllowEmptyString()][string]$EngineToken,
        [AllowNull()][AllowEmptyString()][string]$TemplateToken,
        [Parameter(Mandatory)][string]$EngineRemoteUrl,
        [Parameter(Mandatory)][string]$TemplateRemoteUrl
    )
    [void][System.IO.Directory]::CreateDirectory($WorkPath)
    $clonePath = Join-Path $WorkPath 'template'
    $templateEnvironment = Get-GitHubPushEnvironment -RemoteUrl $TemplateRemoteUrl -Token $TemplateToken
    $existing = Get-RemoteRefSha -Root $WorkPath -RemoteUrl $TemplateRemoteUrl -Ref "refs/heads/$($Plan.Branch)" -Environment $templateEnvironment
    if ($null -ne $existing) {
        $clone = New-GitHubClone -RemoteUrl $TemplateRemoteUrl -Branch $Plan.Branch -Path $clonePath -Token $TemplateToken
    } else {
        # The first release of a major: the branch starts at the head of main (the canary's branch), so its history continues.
        $clone = New-GitHubClone -RemoteUrl $TemplateRemoteUrl -Branch 'main' -Path $clonePath -Token $TemplateToken
        $null = Assert-DeployGit -Root $clone.Path -Arguments @('push', '--quiet', 'origin', "HEAD:refs/heads/$($Plan.Branch)") -Environment $clone.Environment -What "git push $($Plan.Branch) (create)"
    }
    $Result.Copy = Copy-DeployTemplate -Source (Join-Path $Root 'template') -Destination $clone.Path -KeepPath $KeepPath -ReleaseNotesPath (Join-Path $Root $script:ReleaseNotesFile)
    $sha7 = Get-Sha7 $Plan.SourceSha
    if ($Plan.Mode -eq 'release') {
        $null = Update-DeployReference -Root $clone.Path -Branch $Plan.Branch
        $message = "Release $($Plan.Version) from $($Plan.EngineRepo)@$sha7"
        $Result.Template = Publish-TemplateRelease -Clone $clone -Message $message -TargetBranch $Plan.Branch -Tag $Plan.Tag
        $engineEnvironment = Get-GitHubPushEnvironment -RemoteUrl $EngineRemoteUrl -Token $EngineToken
        $Result.Engine = Publish-EngineRelease -Root $Root -RemoteUrl $EngineRemoteUrl -Sha $Plan.SourceSha -Branch $Plan.Branch -Tag $Plan.Tag -Environment $engineEnvironment
        $release = New-GitHubRelease -Repository $Plan.EngineRepo -Tag $Plan.Tag -Name $Plan.Version -Body $Plan.Notes -Prerelease:$Plan.Prerelease -Token $EngineToken -ApiUrl $ApiUrl
        $Result.ReleaseUrl = $release.Url
    } else {
        $Result.Template = Publish-TemplateRelease -Clone $clone -Message "Refresh from $($Plan.EngineRepo)@$sha7" -TargetBranch 'main'
    }
    $Result.Pushed = $true
    $Result.ExitCode = 0
}

#endregion

#region Exported functions

function Get-ReleaseVersion {
    <#
    .SYNOPSIS
    The version of the top heading of RELEASENOTES.md: { Version, Tag, Major, Branch, Prerelease, Line }.
    .DESCRIPTION
    The first line that starts with '## ' must read '## vX.Y.Z' or '## vX.Y.Z-<prerelease>' (dot-separated
    alphanumeric identifiers). Tag is the version with the v, Branch is v<major>. Anything else throws, naming the
    line.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "No release notes file at $Path" }
    $heading = $null
    foreach ($line in [System.IO.File]::ReadAllLines($Path, $script:Utf8NoBom)) {
        if ($line.StartsWith('## ', [System.StringComparison]::Ordinal)) { $heading = $line; break }
    }
    if ($null -eq $heading) { throw "$($script:ReleaseNotesFile) has no '## vX.Y.Z' heading" }
    if ($heading -cnotmatch $script:VersionPattern) { throw "The top heading of $($script:ReleaseNotesFile) is '$heading'; it must read '## vX.Y.Z' or '## vX.Y.Z-prerelease', for example '## v1.0.1' or '## v1.1.0-beta.1'" }
    $prerelease = if ($Matches[4]) { $Matches[4] } else { $null }
    $version = "v$($Matches[1]).$($Matches[2]).$($Matches[3])" + $(if ($prerelease) { "-$prerelease" } else { '' })
    return [pscustomobject]@{
        Version    = $version
        Tag        = $version
        Major      = [int]$Matches[1]
        Branch     = "v$($Matches[1])"
        Prerelease = $null -ne $prerelease
        Line       = $heading.TrimEnd()
    }
}

function Get-ReleaseNotesSection {
    <#
    .SYNOPSIS
    The text under the '## <Version>' heading of RELEASENOTES.md up to the next '## ' heading, trimmed.
    .DESCRIPTION
    An empty section, or no heading for -Version, throws: a release needs notes.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Version)
    $lines = [System.IO.File]::ReadAllLines($Path, $script:Utf8NoBom)
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].TrimEnd() -ceq "## $Version") { $start = $i; break }
    }
    if ($start -lt 0) { throw "$($script:ReleaseNotesFile) has no '## $Version' heading" }
    $section = [System.Collections.Generic.List[string]]::new()
    for ($i = $start + 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i].StartsWith('## ', [System.StringComparison]::Ordinal)) { break }
        $section.Add($lines[$i])
    }
    $text = ($section -join "`n").Trim()
    if ($text -eq '') { throw "The section '## $Version' of $($script:ReleaseNotesFile) is empty; add the release lines first" }
    return $text
}

function Convert-DeployReference {
    <#
    .SYNOPSIS
    -Text with every ALCops/rulebook and ALCops/rulebook-engine reference to main pointed at -Branch.
    .DESCRIPTION
    Rewrites @main, /main/ of a raw URL, /blob/main, /raw/main, /tree/main and actions/<Name>@main after
    ALCops/rulebook or ALCops/rulebook-engine; leaves 'branches: [ main ]', 'the main branch', maintain and
    rulebook-engine-main alone. Pure.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [Parameter(Mandatory)][string]$Branch)
    return [regex]::Replace($Text, $script:ReferencePattern, $Branch)
}

function Update-DeployReference {
    <#
    .SYNOPSIS
    Applies Convert-DeployReference to every text file under -Root; returns the changed relative paths, sorted.
    .DESCRIPTION
    Text files are .md, .yaml, .yml, .json, .ps1, .txt and .html; .git is skipped. A file is read as UTF-8 and
    written back only when its text changed, with its BOM (if it had one) and its line endings as they were.
    -Branch main changes nothing.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Writes only the work copy the caller names')]
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Branch)
    $full = (Resolve-Path -LiteralPath $Root).ProviderPath
    $changed = [System.Collections.Generic.List[string]]::new()
    foreach ($relative in (Get-TreeFile -Root $full)) {
        if ($script:RewriteExtensions -notcontains [System.IO.Path]::GetExtension($relative).ToLowerInvariant()) { continue }
        $path = Join-Path $full $relative
        $bytes = [System.IO.File]::ReadAllBytes($path)
        $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
        $offset = if ($bom) { 3 } else { 0 }
        $text = $script:Utf8NoBom.GetString($bytes, $offset, $bytes.Length - $offset)
        $new = Convert-DeployReference -Text $text -Branch $Branch
        if ($new -ceq $text) { continue }
        $out = $script:Utf8NoBom.GetBytes($new)
        if ($bom) { $out = [byte[]](@(0xEF, 0xBB, 0xBF) + $out) }
        [System.IO.File]::WriteAllBytes($path, $out)
        $changed.Add($relative)
    }
    [string[]]$result = $changed.ToArray()
    [System.Array]::Sort($result, [System.StringComparer]::Ordinal)
    return $result
}

function Copy-DeployTemplate {
    <#
    .SYNOPSIS
    Makes -Destination (a clone of the template repository) hold exactly -Source plus the kept files and the release
    notes copy: { Copied, Removed, Kept }.
    .DESCRIPTION
    Deletes every file of the clone except .git and the entries of -KeepPath (one relative path per line, '#'
    comments; a folder entry keeps everything under it), copies every file of -Source (template/) byte for byte and
    writes .github/RELEASENOTES.copy.md as a byte copy of -ReleaseNotesPath when it exists. Empty folders left behind
    are removed. Copied is the number of files written, Removed the sorted paths that no longer exist, Kept the sorted
    kept paths. A second run on the result changes nothing.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Writes only the work clone the caller names')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [AllowNull()][AllowEmptyString()][string]$KeepPath,
        [AllowNull()][AllowEmptyString()][string]$ReleaseNotesPath
    )
    $sourceFull = (Resolve-Path -LiteralPath $Source).ProviderPath
    $destinationFull = (Resolve-Path -LiteralPath $Destination).ProviderPath
    $keep = Get-KeepList -Path $KeepPath
    [string[]]$sourceFiles = Get-TreeFile -Root $sourceFull
    $incoming = Get-OrdinalSet -Items $sourceFiles
    $hasNotes = -not [string]::IsNullOrEmpty($ReleaseNotesPath) -and (Test-Path -LiteralPath $ReleaseNotesPath -PathType Leaf)
    if ($hasNotes) { [void]$incoming.Add($script:ReleaseNotesCopy) }
    $removed = [System.Collections.Generic.List[string]]::new()
    $kept = [System.Collections.Generic.List[string]]::new()
    foreach ($relative in (Get-TreeFile -Root $destinationFull)) {
        if (Test-KeptPath -Relative $relative -Keep $keep) { $kept.Add($relative); continue }
        [System.IO.File]::Delete((Join-Path $destinationFull $relative))
        if (-not $incoming.Contains($relative)) { $removed.Add($relative) }
    }
    # Empty folders, deepest first; .git and its content are never touched.
    $folders = @(Get-ChildItem -LiteralPath $destinationFull -Recurse -Directory -Force | Where-Object {
            $relative = [System.IO.Path]::GetRelativePath($destinationFull, $_.FullName).Replace('\', '/')
            $relative -cne '.git' -and -not $relative.StartsWith('.git/', [System.StringComparison]::Ordinal)
        } | Sort-Object { $_.FullName.Length } -Descending)
    foreach ($folder in $folders) {
        if (@(Get-ChildItem -LiteralPath $folder.FullName -Force).Count -eq 0) { [System.IO.Directory]::Delete($folder.FullName) }
    }
    $copied = 0
    foreach ($relative in $sourceFiles) {
        $target = Join-Path $destinationFull $relative
        $parent = Split-Path -Parent $target
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) { [void][System.IO.Directory]::CreateDirectory($parent) }
        [System.IO.File]::Copy((Join-Path $sourceFull $relative), $target, $true)
        $copied++
    }
    if ($hasNotes) {
        $target = Join-Path $destinationFull $script:ReleaseNotesCopy
        $parent = Split-Path -Parent $target
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) { [void][System.IO.Directory]::CreateDirectory($parent) }
        [System.IO.File]::Copy((Resolve-Path -LiteralPath $ReleaseNotesPath).ProviderPath, $target, $true)
        $copied++
    }
    [string[]]$removedSorted = $removed.ToArray()
    [System.Array]::Sort($removedSorted, [System.StringComparer]::Ordinal)
    [string[]]$keptSorted = $kept.ToArray()
    [System.Array]::Sort($keptSorted, [System.StringComparer]::Ordinal)
    return [pscustomobject]@{ Copied = $copied; Removed = $removedSorted; Kept = $keptSorted }
}

function Get-DeployPlan {
    <#
    .SYNOPSIS
    What a deploy of -RepositoryRoot (an engine checkout) would do: { Mode, Version, Tag, Branch, Prerelease,
    SourceSha, Notes, TemplateFiles, Rewritten, EngineRepo, TemplateRepo, RepositoryRoot }.
    .DESCRIPTION
    Release: the version, tag, branch and prerelease flag from the top heading of RELEASENOTES.md (Get-ReleaseVersion,
    which throws on a bad heading), the notes of that section (throws when empty), and Rewritten: the template files
    the rewrite to the branch changes, computed on a temporary copy of template/. Refresh: Branch main, no version,
    tag or notes, nothing rewritten. TemplateFiles is the number of files in template/.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][ValidateSet('release', 'refresh')][string]$Mode,
        [AllowNull()][AllowEmptyString()][string]$Sha
    )
    $root = (Resolve-Path -LiteralPath $RepositoryRoot).ProviderPath
    $template = Join-Path $root 'template'
    if (-not (Test-Path -LiteralPath $template -PathType Container)) { throw "No template/ folder in $root" }
    $notesPath = Join-Path $root $script:ReleaseNotesFile
    [string[]]$files = Get-TreeFile -Root $template
    $plan = [ordered]@{
        Mode = $Mode; Version = $null; Tag = $null; Branch = 'main'; Prerelease = $false; SourceSha = $Sha; Notes = $null
        TemplateFiles = $files.Count; Rewritten = [string[]]@(); EngineRepo = $script:EngineRepository; TemplateRepo = $script:TemplateRepository
        RepositoryRoot = $root
    }
    if ($Mode -eq 'release') {
        $version = Get-ReleaseVersion -Path $notesPath
        $plan.Version = $version.Version
        $plan.Tag = $version.Tag
        $plan.Branch = $version.Branch
        $plan.Prerelease = $version.Prerelease
        $plan.Notes = Get-ReleaseNotesSection -Path $notesPath -Version $version.Version
        $scratch = Join-Path ([System.IO.Path]::GetTempPath()) ('rulebook-deploy-plan-' + [guid]::NewGuid().ToString('n').Substring(0, 12))
        try {
            [void][System.IO.Directory]::CreateDirectory($scratch)
            foreach ($relative in $files) {
                $target = Join-Path $scratch $relative
                [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $target))
                [System.IO.File]::Copy((Join-Path $template $relative), $target)
            }
            $plan.Rewritten = [string[]]@(Update-DeployReference -Root $scratch -Branch $version.Branch)
        } finally {
            if (Test-Path -LiteralPath $scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force }
        }
    }
    return [pscustomobject]$plan
}

function Test-DeployPrecondition {
    <#
    .SYNOPSIS
    The refusals of a deploy: an empty list means it may go ahead.
    .DESCRIPTION
    Both modes: the checkout is clean (git status --porcelain is empty) and its HEAD is the plan's SourceSha.
    Release also: the tag exists on neither repository (GET repos/{r}/git/ref/tags/{tag} answers 404), and the latest
    check runs of SourceSha on the engine are all completed with success or skipped, one of them named test (the
    deploy's own check runs, deploy and refresh, are left out).
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]$Plan,
        [AllowNull()][AllowEmptyString()][string]$EngineToken,
        [AllowNull()][AllowEmptyString()][string]$TemplateToken,
        [AllowNull()][AllowEmptyString()][string]$ApiUrl
    )
    $refusals = [System.Collections.Generic.List[string]]::new()
    $root = $Plan.RepositoryRoot
    $status = Invoke-Git -Root $root -Arguments @('status', '--porcelain=v1')
    if ($status.ExitCode -ne 0) {
        $refusals.Add("git status failed in the checkout: $(($status.Error + $status.Output).Trim())")
    } elseif (-not [string]::IsNullOrWhiteSpace($status.Output)) {
        $refusals.Add("The checkout has uncommitted changes: $((@($status.Output.Trim().Split("`n") | ForEach-Object { $_.Trim() }) -join ', '))")
    }
    $head = Invoke-Git -Root $root -Arguments @('rev-parse', 'HEAD')
    if ([string]::IsNullOrEmpty($Plan.SourceSha)) {
        $refusals.Add('No commit to deploy: GITHUB_SHA is not set')
    } elseif ($head.ExitCode -ne 0 -or $head.Output.Trim() -cne $Plan.SourceSha) {
        $refusals.Add("The checkout is at $(Get-Sha7 $head.Output.Trim()), not at the commit to deploy $(Get-Sha7 $Plan.SourceSha)")
    }
    if ($Plan.Mode -ne 'release') { return $refusals.ToArray() }

    foreach ($pair in @(@($Plan.EngineRepo, $EngineToken), @($Plan.TemplateRepo, $TemplateToken))) {
        $response = Invoke-GitHubApi -Method GET -Path "repos/$($pair[0])/git/ref/tags/$($Plan.Tag)" -Token $pair[1] -ApiUrl $ApiUrl
        if ($response.StatusCode -eq 200) {
            $refusals.Add("The tag $($Plan.Tag) exists on $($pair[0]); add a new '## vX.Y.Z' heading to $($script:ReleaseNotesFile)")
        } elseif ($response.StatusCode -ne 404) {
            $refusals.Add("Could not check the tag $($Plan.Tag) on $($pair[0]) (HTTP $($response.StatusCode): $(Get-ApiText $response))")
        }
    }
    if (-not [string]::IsNullOrEmpty($Plan.SourceSha)) {
        $response = Invoke-GitHubApi -Method GET -Path "repos/$($Plan.EngineRepo)/commits/$($Plan.SourceSha)/check-runs?filter=latest&per_page=100" -Token $EngineToken -ApiUrl $ApiUrl
        if ($response.StatusCode -ne 200 -or $response.Body -isnot [System.Collections.IDictionary]) {
            $refusals.Add("Could not read the check runs of $(Get-Sha7 $Plan.SourceSha) (HTTP $($response.StatusCode): $(Get-ApiText $response))")
        } else {
            $allRuns = @($response.Body['check_runs'] | Where-Object { $null -ne $_ })
            $total = $response.Body['total_count']
            if ($null -ne $total -and [int]$total -gt $allRuns.Count) {
                $refusals.Add("The commit $(Get-Sha7 $Plan.SourceSha) has $total check runs, more than the $($allRuns.Count) one page returns; check them by hand")
            }
            $runs = @($allRuns | Where-Object { $script:OwnCheckRuns -notcontains [string]$_['name'] })
            if (-not @($runs | Where-Object { [string]$_['name'] -ceq 'test' })) {
                $refusals.Add("The commit $(Get-Sha7 $Plan.SourceSha) has no check run named test: CI has not run on it")
            }
            foreach ($run in $runs) {
                $name = [string]$run['name']
                if ([string]$run['status'] -cne 'completed') {
                    $refusals.Add("The check run $name of $(Get-Sha7 $Plan.SourceSha) is $($run['status']); wait for CI to finish")
                } elseif (@('success', 'skipped') -notcontains [string]$run['conclusion']) {
                    $refusals.Add("The check run $name of $(Get-Sha7 $Plan.SourceSha) concluded $($run['conclusion'])")
                }
            }
        }
    }
    return $refusals.ToArray()
}

function Publish-EngineRelease {
    <#
    .SYNOPSIS
    Moves the engine's floating branch to -Sha and pushes the tag: { OldSha, Sha, Branch, Tag, Created }.
    .DESCRIPTION
    git push <remote> <sha>:refs/heads/<Branch> --force-with-lease=refs/heads/<Branch>:<old>, old read with git
    ls-remote (absent: the branch is created and must still be absent). Forced because a prerelease deployed from a
    pull request branch is not an ancestor of the squash commit that follows; the lease still refuses a move made by
    someone else in between. Then <sha>:refs/tags/<Tag>. A refused push throws.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'The deploy is the change; its dry run stops before this')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$RemoteUrl,
        [Parameter(Mandatory)][string]$Sha,
        [Parameter(Mandatory)][string]$Branch,
        [Parameter(Mandatory)][string]$Tag,
        [System.Collections.IDictionary]$Environment
    )
    $old = Get-RemoteRefSha -Root $Root -RemoteUrl $RemoteUrl -Ref "refs/heads/$Branch" -Environment $Environment
    $lease = if ($null -eq $old) { '' } else { $old }
    $null = Assert-DeployGit -Root $Root -Arguments @('push', '--quiet', "--force-with-lease=refs/heads/$($Branch):$lease", $RemoteUrl, "$($Sha):refs/heads/$Branch") -Environment $Environment -What "git push $Branch"
    $null = Assert-DeployGit -Root $Root -Arguments @('push', '--quiet', $RemoteUrl, "$($Sha):refs/tags/$Tag") -Environment $Environment -What "git push tag $Tag"
    return [pscustomobject]@{ OldSha = $old; Sha = $Sha; Branch = $Branch; Tag = $Tag; Created = $null -eq $old }
}

function Publish-TemplateRelease {
    <#
    .SYNOPSIS
    Commits the template clone when it changed, pushes -TargetBranch and, with -Tag, tags the head: { Pushed, Sha, Tagged }.
    .DESCRIPTION
    git add -A; a commit only when git status --porcelain is non-empty; a plain push of HEAD to
    refs/heads/<TargetBranch> (never forced: the branch only moves forward). With -Tag the head (the new commit, or
    the unchanged head) is tagged and the tag pushed. A refused push throws, before any tag.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'The deploy is the change; its dry run stops before this')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]$Clone,
        [Parameter(Mandatory)][string]$Message,
        [Parameter(Mandatory)][string]$TargetBranch,
        [AllowNull()][AllowEmptyString()][string]$Tag
    )
    $root = $Clone.Path
    $environment = $Clone.Environment
    $null = Assert-DeployGit -Root $root -Arguments @('add', '-A') -What 'git add'
    $status = Assert-DeployGit -Root $root -Arguments @('status', '--porcelain=v1') -What 'git status'
    $committed = $false
    if (-not [string]::IsNullOrWhiteSpace($status.Output)) {
        $null = Assert-DeployGit -Root $root -Arguments @('commit', '--quiet', '-m', $Message) -What 'git commit'
        $committed = $true
    }
    $null = Assert-DeployGit -Root $root -Arguments @('push', '--quiet', 'origin', "HEAD:refs/heads/$TargetBranch") -Environment $environment -What "git push $TargetBranch"
    $sha = (Assert-DeployGit -Root $root -Arguments @('rev-parse', 'HEAD') -What 'git rev-parse').Output.Trim()
    $tagged = $false
    if (-not [string]::IsNullOrEmpty($Tag)) {
        $null = Assert-DeployGit -Root $root -Arguments @('push', '--quiet', 'origin', "$($sha):refs/tags/$Tag") -Environment $environment -What "git push tag $Tag"
        $tagged = $true
    }
    return [pscustomobject]@{ Pushed = $committed; Sha = $sha; Tagged = $tagged }
}

function New-GitHubRelease {
    <#
    .SYNOPSIS
    Creates a GitHub Release for an existing tag: POST repos/{r}/releases. Returns { Url, Id }.
    .DESCRIPTION
    A status other than 201 throws with the API message.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'The deploy is the change; its dry run stops before this')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Tag,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Body,
        [switch]$Prerelease,
        [AllowNull()][AllowEmptyString()][string]$Token,
        [AllowNull()][AllowEmptyString()][string]$ApiUrl
    )
    $payload = [ordered]@{ tag_name = $Tag; name = $Name; body = $Body; draft = $false; prerelease = [bool]$Prerelease }
    $response = Invoke-GitHubApi -Method POST -Path "repos/$Repository/releases" -Token $Token -Body $payload -ApiUrl $ApiUrl
    if ($response.StatusCode -ne 201) { throw "Could not create the release $Tag on $Repository (HTTP $($response.StatusCode): $(Get-ApiText $response))" }
    return [pscustomobject]@{ Url = [string]$response.Body['html_url']; Id = $response.Body['id'] }
}

function ConvertTo-DeploySummary {
    <#
    .SYNOPSIS
    The Markdown job summary of a deploy result (Invoke-RulebookDeploy).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Result)
    $plan = $Result.Plan
    $lines = [System.Collections.Generic.List[string]]::new()
    $sha7 = if ($null -ne $plan) { Get-Sha7 $plan.SourceSha } else { '' }
    if ($null -eq $plan) {
        $lines.Add('## Deploy')
    } elseif ($plan.Mode -eq 'release') {
        $lines.Add("## Release $($plan.Version)$(if ($plan.Prerelease) { ' (prerelease)' }) from $sha7")
    } else {
        $lines.Add("## Refresh of $($plan.TemplateRepo)@main from $sha7")
    }
    $lines.Add('')
    if ($Result.DryRun) { $lines.Add('> **DRY RUN: nothing pushed.**'); $lines.Add('') }
    if (@($Result.Refusals).Count -gt 0) {
        $lines.Add('### Refused or failed')
        $lines.Add('')
        foreach ($refusal in $Result.Refusals) { $lines.Add("- $refusal") }
        $lines.Add('')
    }
    if ($null -ne $plan) {
        $lines.Add('| | |')
        $lines.Add('|---|---|')
        if ($plan.Mode -eq 'release') {
            $lines.Add("| Engine branch | ``$($plan.Branch)`` -> ``$sha7``$(if ($null -ne $Result.Engine) { ' (moved)' }) |")
            $lines.Add("| Engine tag | ``$($plan.Tag)`` |")
        }
        $templateCommit = if ($null -ne $Result.Template) { "``$(Get-Sha7 $Result.Template.Sha)``$(if (-not $Result.Template.Pushed) { ' (unchanged)' })" } else { '-' }
        $lines.Add("| Template branch | ``$($plan.TemplateRepo)@$($plan.Branch)`` |")
        $lines.Add("| Template commit | $templateCommit |")
        if ($plan.Mode -eq 'release') {
            $lines.Add("| Template tag | ``$($plan.Tag)`` |")
            $lines.Add("| Release | $(if ($Result.ReleaseUrl) { $Result.ReleaseUrl } else { '-' }) |")
        }
        $lines.Add("| Template files | $($plan.TemplateFiles)$(if ($null -ne $Result.Copy) { ", $($Result.Copy.Copied) copied, $(@($Result.Copy.Removed).Count) removed" }) |")
        $lines.Add('')
        if ($plan.Mode -eq 'release') {
            $lines.Add("### Rewritten to $($plan.Branch) ($(@($plan.Rewritten).Count) files)")
            $lines.Add('')
            foreach ($file in $plan.Rewritten) { $lines.Add("- ``$file``") }
            $lines.Add('')
            $lines.Add('### Release notes')
            $lines.Add('')
            $lines.Add([string]$plan.Notes)
            $lines.Add('')
        }
        if ($null -ne $Result.Copy -and @($Result.Copy.Removed).Count -gt 0) {
            $lines.Add('### Removed from the template repository')
            $lines.Add('')
            foreach ($file in $Result.Copy.Removed) { $lines.Add("- ``$file``") }
            $lines.Add('')
        }
    }
    return ($lines -join "`n")
}

function Invoke-RulebookDeploy {
    <#
    .SYNOPSIS
    Runs a release or a refresh of the template repository from an engine checkout: { ExitCode, Plan, Refusals,
    Pushed, ReleaseUrl, Summary, DryRun, Copy, Template, Engine }.
    .DESCRIPTION
    Plan (Get-DeployPlan), then one token exchange per repository with the GitHub App JSON built from -AppClientId and
    -AppPrivateKey (contents and workflows write, checks and metadata read; both tokens masked), then the preconditions
    (Test-DeployPrecondition). -DryRun stops there. Release: clone ALCops/rulebook@<branch> (when the branch does
    not exist yet: clone main and push its head as <branch>, so the history continues), copy
    template/ (Copy-DeployTemplate with -KeepPath), rewrite the references (Update-DeployReference), commit, push and
    tag (Publish-TemplateRelease), move the engine branch and tag it (Publish-EngineRelease) and create the GitHub
    Release with the notes section as its body. Refresh: clone main, copy, commit and push, no rewrite, tag or release.
    Writes the summary to -SummaryPath when set. Never calls exit; a failure is ExitCode 1 with one ::error:: line.
    -EngineRemoteUrl and -TemplateRemoteUrl default to the github.com URLs of the two repositories (test seams).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidateSet('release', 'refresh')][string]$Mode,
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [AllowNull()][AllowEmptyString()][string]$Sha,
        [AllowNull()][AllowEmptyString()][string]$AppClientId,
        [AllowNull()][AllowEmptyString()][string]$AppPrivateKey,
        [switch]$DryRun,
        [AllowNull()][AllowEmptyString()][string]$WorkPath,
        [AllowNull()][AllowEmptyString()][string]$SummaryPath,
        [AllowNull()][AllowEmptyString()][string]$ApiUrl,
        [AllowNull()][AllowEmptyString()][string]$KeepPath,
        [AllowNull()][AllowEmptyString()][string]$EngineRemoteUrl,
        [AllowNull()][AllowEmptyString()][string]$TemplateRemoteUrl
    )
    $server = if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_SERVER_URL)) { $env:GITHUB_SERVER_URL.TrimEnd('/') } else { 'https://github.com' }
    if ([string]::IsNullOrEmpty($EngineRemoteUrl)) { $EngineRemoteUrl = "$server/$($script:EngineRepository).git" }
    if ([string]::IsNullOrEmpty($TemplateRemoteUrl)) { $TemplateRemoteUrl = "$server/$($script:TemplateRepository).git" }
    $result = [ordered]@{
        ExitCode = 1; Plan = $null; Refusals = [string[]]@(); Pushed = $false; ReleaseUrl = $null; Summary = $null
        DryRun = [bool]$DryRun; Copy = $null; Template = $null; Engine = $null
    }
    $ownWork = [string]::IsNullOrEmpty($WorkPath)
    if ($ownWork) {
        $tempRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [System.IO.Path]::GetTempPath() }
        $WorkPath = Join-Path $tempRoot ('rulebook-deploy-' + [guid]::NewGuid().ToString('n').Substring(0, 8))
    }
    try {
        $root = (Resolve-Path -LiteralPath $RepositoryRoot).ProviderPath
        $plan = Get-DeployPlan -RepositoryRoot $root -Mode $Mode -Sha $Sha
        $result.Plan = $plan
        if ([string]::IsNullOrWhiteSpace($AppClientId) -or [string]::IsNullOrWhiteSpace($AppPrivateKey)) {
            throw 'The deploy needs the variable DEPLOY_APP_ID (the Client ID of the ALCops deploy App) and the secret DEPLOY_APP_PRIVATE_KEY; see docs/releasing.md section 7'
        }
        $appJson = ConvertTo-Json -InputObject ([ordered]@{ GitHubAppClientId = $AppClientId.Trim(); PrivateKey = $AppPrivateKey }) -Compress
        $engineToken = (Get-GitHubAccessToken -Token $appJson -Repository $plan.EngineRepo -ApiUrl $ApiUrl -Permissions $script:DeployPermissions).Token
        if (-not [string]::IsNullOrEmpty($engineToken)) { Write-Host "::add-mask::$engineToken" }
        $templateToken = (Get-GitHubAccessToken -Token $appJson -Repository $plan.TemplateRepo -ApiUrl $ApiUrl -Permissions $script:DeployPermissions).Token
        if (-not [string]::IsNullOrEmpty($templateToken)) { Write-Host "::add-mask::$templateToken" }

        $refusals = @(Test-DeployPrecondition -Plan $plan -EngineToken $engineToken -TemplateToken $templateToken -ApiUrl $ApiUrl)
        $result.Refusals = [string[]]$refusals
        if ($refusals.Count -gt 0) {
            foreach ($refusal in $refusals) { Write-Host "::error title=Deploy::$(ConvertTo-AnnotationText $refusal)" }
        } elseif ($DryRun) {
            $result.ExitCode = 0
        } else {
            $publish = @{
                Result = $result; Plan = $plan; Root = $root; WorkPath = $WorkPath; KeepPath = $KeepPath; ApiUrl = $ApiUrl
                EngineToken = $engineToken; TemplateToken = $templateToken; EngineRemoteUrl = $EngineRemoteUrl
                TemplateRemoteUrl = $TemplateRemoteUrl
            }
            Invoke-DeployPublish @publish
        }
    } catch {
        $message = $_.Exception.Message
        Write-Host "::error title=Deploy::$(ConvertTo-AnnotationText $message)"
        $result.Refusals = [string[]](@($result.Refusals) + $message)
    } finally {
        $result.Summary = ConvertTo-DeploySummary -Result ([pscustomobject]$result)
        if (-not [string]::IsNullOrEmpty($SummaryPath)) { [System.IO.File]::AppendAllText($SummaryPath, $result.Summary + "`n", $script:Utf8NoBom) }
        if ($ownWork -and (Test-Path -LiteralPath $WorkPath)) { Remove-Item -LiteralPath $WorkPath -Recurse -Force -ErrorAction SilentlyContinue }
    }
    return [pscustomobject]$result
}

#endregion

Export-ModuleMember -Function @(
    'ConvertTo-DeploySummary'
    'Convert-DeployReference'
    'Copy-DeployTemplate'
    'Get-DeployPlan'
    'Get-ReleaseNotesSection'
    'Get-ReleaseVersion'
    'Invoke-RulebookDeploy'
    'New-GitHubRelease'
    'Publish-EngineRelease'
    'Publish-TemplateRelease'
    'Test-DeployPrecondition'
    'Update-DeployReference'
)
