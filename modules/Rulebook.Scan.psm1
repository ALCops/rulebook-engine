#requires -Version 7.4
# Rulebook.Scan: the daily diagnostic scan of an organization rulebook repository (WP08, R9; D10, D14, D24, D45, D46).
# Get-RulebookScanPlan reads the newest stable and prerelease versions of the two analyzer packages from NuGet, skips
# what catalog/scan-state.json recorded already, extracts the descriptors of every new version in its own pwsh
# process, applies them to the catalog, quarantines new ids by the organization's policy, releases adopted ids,
# regenerates the endpoints, validates the candidate tree and lists what changes. Publish-RulebookScan rebuilds the
# fixed branch scan-diagnostics/<base> from the base head and keeps one living pull request (create, or PATCH the
# open one), or pushes a direct commit. Contract: docs/reference/scan-mechanics.md. Design: docs/ARCHITECTURE.md 7.4.

Set-StrictMode -Version 3.0
Import-Module (Join-Path $PSScriptRoot 'Rulebook.Generate.psd1')
Import-Module (Join-Path $PSScriptRoot 'Rulebook.Validate.psd1')
Import-Module (Join-Path $PSScriptRoot 'Rulebook.GitHub.psd1')
Import-Module (Join-Path $PSScriptRoot 'Rulebook.Update.psd1')
Import-Module (Join-Path $PSScriptRoot 'Rulebook.NuGet.psd1')
Import-Module (Join-Path $PSScriptRoot 'Rulebook.Catalog.psd1')
Import-Module (Join-Path $PSScriptRoot 'Rulebook.Extract.psd1')
Import-Module (Join-Path $PSScriptRoot 'Rulebook.Quarantine.psd1')

$script:ToolsPackageId = 'microsoft.dynamics.businesscentral.development.tools'
$script:AlcopsPackageId = 'alcops.analyzers'
$script:Packages = @($script:ToolsPackageId, $script:AlcopsPackageId)
$script:Labels = @{ 'microsoft.dynamics.businesscentral.development.tools' = 'tools'; 'alcops.analyzers' = 'alcops' }
$script:SettingsPath = '.github/Rulebook-Settings.json'
$script:CatalogPath = 'catalog/diagnostics.json'
$script:ScanStatePath = 'catalog/scan-state.json'
$script:BranchPrefix = 'scan-diagnostics'
$script:BodyLimit = 60000
$script:NewRowLimit = 200
$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

#region Internal helpers

function Get-PackageLabel {
    param([Parameter(Mandatory)][string]$PackageId)
    if ($script:Labels.ContainsKey($PackageId)) { return $script:Labels[$PackageId] }
    return $PackageId
}

function Format-PackageText {
    # Text a package supplies (a title), for a Markdown table cell: Format-TableCell, and a zero-width space after every
    # '@' so a title cannot mention a GitHub user or team.
    param([AllowNull()][string]$Text)
    return (Format-TableCell $Text).Replace('@', "@$([char]0x200B)")
}

function Format-Count {
    # '1 new id', '3 new ids': Count, then the singular or the plural.
    param([int]$Count, [string]$Singular, [string]$Plural)
    return '{0} {1}' -f $Count, $(if ($Count -eq 1) { $Singular } else { $Plural })
}

function Join-AndList {
    # 'a', 'a and b', 'a, b and c'.
    param([AllowEmptyCollection()][string[]]$Items)
    if ($Items.Count -le 1) { return ($Items -join '') }
    return (($Items | Select-Object -First ($Items.Count - 1)) -join ', ') + ' and ' + $Items[-1]
}

function Get-Distinct {
    param([AllowNull()][AllowEmptyCollection()][object[]]$Items)
    # Always an array (the comma keeps an empty result from unrolling to $null on assignment).
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $result = [System.Collections.Generic.List[string]]::new()
    foreach ($item in @($Items)) { if ($null -ne $item -and $seen.Add([string]$item)) { $result.Add([string]$item) } }
    return , [string[]]$result.ToArray()
}

function Format-UtcTime {
    param([Parameter(Mandatory)][System.DateTimeOffset]$Value)
    return $Value.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
}

function Get-ScanFacts {
    # The derived lists of a plan the title, the body and the outputs share.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'One object of several lists')]
    param([Parameter(Mandatory)]$Plan)
    $diffs = @($Plan.Scanned | ForEach-Object { $_.Diff })
    $unadvertisedIds = Get-Distinct ($diffs | ForEach-Object { $_.Unadvertised })
    $unadvertised = [System.Collections.Generic.HashSet[string]]::new($unadvertisedIds, [System.StringComparer]::Ordinal)
    $newAll = Get-Distinct ($diffs | ForEach-Object { $_.NewIds })
    $newlyAdvertised = Get-Distinct ($diffs | ForEach-Object { if ($_.PSObject.Properties['NewlyAdvertised']) { $_.NewlyAdvertised } })
    # An id an analyzer advertises for the first time goes live like a new id and counts as one.
    $newIds = [string[]]@(@($newAll | Where-Object { -not $unadvertised.Contains($_) }) + @($newlyAdvertised | Where-Object { $_ -cnotin $newAll }))
    $added = Get-Distinct ($Plan.Quarantine.Added | ForEach-Object { $_.Id })
    $addedSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$added, [System.StringComparer]::Ordinal)
    return [pscustomobject]@{
        NewIds             = $newIds
        NewUnadvertised    = [string[]]@($newAll | Where-Object { $unadvertised.Contains($_) })
        NewlyAdvertised    = $newlyAdvertised
        QuarantinedNew     = [string[]]@($newIds | Where-Object { $addedSet.Contains($_) })
        RecordedNew        = [string[]]@($newIds | Where-Object { -not $addedSet.Contains($_) })
        Quarantined        = $added
        Promoted           = Get-Distinct ($diffs | ForEach-Object { $_.Promoted })
        ChangedDefaults    = @($diffs | ForEach-Object { $_.ChangedDefaults })
        PrereleaseDefaults = @($diffs | ForEach-Object { $_.PrereleaseDefaultChanges })
        Released           = @($Plan.Quarantine.Removed)
        Refreshed          = @($diffs | ForEach-Object { $_.Refreshed })
        Recorded           = Get-Distinct ($diffs | ForEach-Object { $_.Recorded })
        Vanished           = Get-Distinct ($diffs | ForEach-Object { $_.Vanished })
        Deprecated         = Get-Distinct ($diffs | ForEach-Object { $_.Deprecated })
        Unadvertised       = $unadvertisedIds
    }
}

#endregion

#region Plan

function Get-RulebookScanPlan {
    <#
    .SYNOPSIS
    What the diagnostic scan changes in -RepositoryRoot: a Rulebook.ScanPlan.
    .DESCRIPTION
    1. Settings and the quarantine policy (Get-QuarantinePolicy; throws with Data['Stage'] = 'policy').
    2. catalog/scan-state.json (absent: nothing scanned yet).
    3. The NuGet index of both packages, the newest stable and (with -IncludePrerelease) prerelease version, and the
       versions the state has not recorded (NewVersions).
    4. Housekeeping pre-check without a download: no new version and no quarantined id a level file mentions gives
       Mode nothing-new (returned at once); no new version but such ids gives Mode housekeeping (state untouched).
    5. The candidate tree <WorkPath>/candidate, a copy of the repository.
    6. Per new version: download, extraction in a child pwsh (an alcops.analyzers version is hosted by the tools
       version of the same channel, else the stable one), records of that package only.
    7. Update-CatalogFromScan per version, stable before prerelease per package.
    8. Update-QuarantineFromScan: new ids into the policy stages, adopted ids released.
    9. The catalog, the scan state (scannedAt -Now; not in housekeeping mode) and the endpoints written.
    10. Test-Rulebook on the candidate (with catalog/scan-state.json in place C7 is an error): Findings, Valid.
    11. The candidate compared with the repository (LF-normalised text, bytes for binaries): Changes.
    Never throws past step 1: a NuGet failure sets Failure nuget, an extraction failure extract, anything else error,
    each with FailureMessage. -Source is a flat container (a folder in the suites).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [bool]$IncludePrerelease = $true,
        [AllowNull()][AllowEmptyString()][string]$Source,
        [string]$WorkPath,
        [System.DateTimeOffset]$Now = [System.DateTimeOffset]::UtcNow,
        [int]$RuntimeMajor = [System.Environment]::Version.Major,
        [string]$PwshPath,
        [int]$ExtractionTimeoutSeconds = 300
    )
    $root = (Resolve-Path -LiteralPath $RepositoryRoot -ErrorAction Stop).ProviderPath
    if ([string]::IsNullOrEmpty($WorkPath)) { $WorkPath = Get-DefaultWorkPath -Prefix 'rulebook-scan' }
    $WorkPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($WorkPath)
    $notes = [System.Collections.Generic.List[string]]::new()
    $plan = [pscustomobject]@{
        PSTypeName     = 'Rulebook.ScanPlan'
        Root           = $root
        CandidatePath  = $null
        Policy         = $null
        Settings       = $null
        State          = $null
        StateAfter     = $null
        Channels       = @()
        NewVersions    = @()
        Scanned        = @()
        CatalogBefore  = $null
        CatalogAfter   = $null
        Quarantine     = [pscustomobject]@{ Added = @(); Removed = @(); Created = @() }
        Changes        = @()
        Findings       = @()
        Valid          = $false
        Notes          = @()
        Mode           = $null
        Counts         = $null
        Failure        = $null
        FailureMessage = $null
        Now            = $Now
        HeadSha        = $null
    }

    # 1. Settings and policy.
    $settingsFile = Join-Path $root $script:SettingsPath
    if (-not (Test-Path -LiteralPath $settingsFile -PathType Leaf)) { throw "Settings missing: $($script:SettingsPath) in $root" }
    try {
        $settings = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($settingsFile, $script:Utf8NoBom)) -AsHashtable -Depth 20 -ErrorAction Stop
    } catch {
        throw "Invalid JSON in $($script:SettingsPath): $($_.Exception.Message)"
    }
    $plan.Settings = $settings
    $plan.Policy = Get-QuarantinePolicy -Settings $settings

    # The checkout the plan reads; Publish-RulebookScan refuses a base branch that moved since (plan section 2).
    if (Get-Command git -ErrorAction SilentlyContinue) {
        $head = & git -C $root rev-parse HEAD 2>$null
        if ($LASTEXITCODE -eq 0 -and ([string]$head).Trim() -match '^[0-9a-f]{40}$') { $plan.HeadSha = ([string]$head).Trim() }
    }
    $stage = 'error'
    try {
        # 2. State.
        $state = Read-ScanState -Path (Join-Path $root $script:ScanStatePath)
        $plan.State = $state

        # 3. Package versions.
        $stage = 'nuget'
        $channels = foreach ($packageId in $script:Packages) {
            $index = Get-NuGetVersionIndex -PackageId $packageId -Source $Source
            $selected = Select-NuGetChannelVersion -Versions $index.Versions -IncludePrerelease:$IncludePrerelease
            if (@($selected.Invalid).Count -gt 0) { $notes.Add("The NuGet index of $packageId lists $(@($selected.Invalid).Count) entries that are not versions; they were skipped.") }
            if ($null -eq $selected.Stable) {
                $what = if (@($selected.Invalid).Count -gt 0) { " ($(@($selected.Invalid).Count) of its entries are not versions)" } else { '' }
                throw "The NuGet index of $packageId lists no stable version$what"
            }
            [pscustomobject]@{ PackageId = $packageId; Label = Get-PackageLabel $packageId; Stable = $selected.Stable; Prerelease = $selected.Prerelease }
        }
        $plan.Channels = @($channels)
        $skipped = [System.Collections.Generic.List[string]]::new()
        $plan.NewVersions = @(Get-NewPackageVersion -State $state -Channels $plan.Channels -Skipped $skipped)
        foreach ($item in $skipped) { $notes.Add("The NuGet index names $item, not newer than the recorded version; skipped.") }
        $stage = 'error'

        # 4. Housekeeping pre-check.
        try {
            $inputs = Read-RulebookInputs -RepositoryRoot $root
        } catch {
            throw "The rulebook cannot be read: $($_.Exception.Message)"
        }
        $quarantinedIds = Get-Distinct ($inputs.Quarantine.Values | ForEach-Object { $_.Keys })
        $candidates = @($quarantinedIds | Where-Object { $id = $_; @($inputs.Chains.Values | Where-Object { $_.Contains($id) }).Count -gt 0 })
        if ($plan.NewVersions.Count -eq 0) {
            if ($candidates.Count -eq 0) {
                $plan.Mode = 'nothing-new'
                $plan.Valid = $true
                $plan.Notes = $notes.ToArray()
                $plan.Counts = Get-ScanCount -Plan $plan
                return $plan
            }
            $plan.Mode = 'housekeeping'
        } else {
            $plan.Mode = 'scan'
        }

        # 5. Candidate tree.
        $candidate = Join-Path $WorkPath 'candidate'
        if (Test-Path -LiteralPath $candidate) { Remove-Item -LiteralPath $candidate -Recurse -Force }
        Copy-UpdateTree -Source $root -Destination $candidate
        $plan.CandidatePath = $candidate

        # 6. and 7. Download, extraction and catalog, version by version.
        $catalog = Read-CatalogFile -Path (Join-Path $candidate $script:CatalogPath)
        $plan.CatalogBefore = $catalog
        $packagesPath = Join-Path $WorkPath 'packages'
        $saved = @{}
        $save = {
            param([string]$PackageId, [string]$Version)
            $key = "$PackageId@$Version"
            if (-not $saved.ContainsKey($key)) { $saved[$key] = Save-NuGetPackage -PackageId $PackageId -Version $Version -Path $packagesPath -Source $Source }
            return $saved[$key]
        }
        $tools = @($plan.Channels | Where-Object PackageId -EQ $script:ToolsPackageId)[0]
        $scanned = [System.Collections.Generic.List[object]]::new()
        foreach ($version in $plan.NewVersions) {
            $stage = 'nuget'
            $package = & $save $version.PackageId $version.Version
            $hostVersion = $null
            if ($version.PackageId -ceq $script:AlcopsPackageId) {
                $hostVersion = if ($version.Channel -eq 'prerelease' -and $tools.Prerelease) { $tools.Prerelease } else { $tools.Stable }
                $hostPackage = & $save $script:ToolsPackageId $hostVersion
            }
            $stage = 'extract'
            if ($version.PackageId -ceq $script:AlcopsPackageId) {
                $toolsDir = Resolve-AnalyzerFolder -PackageRoot $hostPackage.ExtractPath -Kind tools -RuntimeMajor $RuntimeMajor
                $alcopsDir = Resolve-AnalyzerFolder -PackageRoot $package.ExtractPath -Kind alcops -RuntimeMajor $RuntimeMajor
            } else {
                $toolsDir = Resolve-AnalyzerFolder -PackageRoot $package.ExtractPath -Kind tools -RuntimeMajor $RuntimeMajor
                $alcopsDir = $null
            }
            $extractParameters = @{ ToolsDir = $toolsDir; ExpectedAssembly = (Get-ExpectedAssembly -PackageId $version.PackageId); WorkPath = (Join-Path $WorkPath 'extract'); TimeoutSeconds = $ExtractionTimeoutSeconds }
            if ($alcopsDir) { $extractParameters.AlcopsDir = $alcopsDir }
            if ($PwshPath) { $extractParameters.PwshPath = $PwshPath }
            $result = Invoke-DescriptorExtraction @extractParameters
            $records = ConvertTo-DiagnosticRecord -Result $result -PackageId $version.PackageId
            $stage = 'error'
            $diff = Update-CatalogFromScan -Catalog $catalog -Records $records.Records -PackageId $version.PackageId -Version $version.Version -Channel $version.Channel -QuarantinedIds $quarantinedIds
            $diff.Conflicts = @($records.Conflicts)
            $catalog = $diff.Catalog
            $label = "$($version.PackageId) $($version.Version) ($($version.Channel))"
            foreach ($conflict in $records.Conflicts) { $notes.Add("$label`: the descriptors of $($conflict.Id) disagree ($($conflict.Variants -join ', ')); the first one was used.") }
            foreach ($fieldError in $records.FieldErrors) { $notes.Add("$label`: a static descriptor member could not be read ($fieldError).") }
            if ($records.UnknownPrefixes.Count -gt 0) { $notes.Add("$label`: ids with a prefix the engine does not know: $($records.UnknownPrefixes -join ', ').") }
            if ($records.CompilerTitlesMissing -and $version.PackageId -ceq $script:ToolsPackageId) { $notes.Add("$label`: the compiler message resources were not found; AL titles were left as they are.") }
            $scanned.Add([pscustomobject]@{
                    PackageId  = $version.PackageId
                    Label      = Get-PackageLabel $version.PackageId
                    Version    = $version.Version
                    Channel    = $version.Channel
                    Records    = $records
                    Diff       = $diff
                    Extraction = [pscustomobject]@{ ToolsDir = $toolsDir; AlcopsDir = $alcopsDir; HostVersion = $hostVersion; Runtime = $result['runtime']; ElapsedSeconds = $result['elapsedSeconds']; Assemblies = @($result['assemblies']).Count }
                })
        }
        $plan.Scanned = $scanned.ToArray()
        $plan.CatalogAfter = $catalog

        # 8. Quarantine and housekeeping.
        $quarantine = Update-QuarantineFromScan -RepositoryRoot $candidate -Settings $settings -Policy $plan.Policy -Diffs @($scanned | ForEach-Object { $_.Diff }) -Chains $inputs.Chains -Now $Now -WhatIf:$false -Confirm:$false
        $plan.Quarantine = [pscustomobject]@{ Added = @($quarantine.Added); Removed = @($quarantine.Removed); Created = @($quarantine.Created) }

        # 9. Catalog, state, endpoints.
        $stateAfter = [pscustomobject]@{ PSTypeName = 'Rulebook.ScanState'; Schema = $state.Schema; Version = 1; Packages = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::Ordinal) }
        foreach ($key in $state.Packages.Keys) { $stateAfter.Packages[$key] = [pscustomobject]@{ Stable = $state.Packages[$key].Stable; Prerelease = $state.Packages[$key].Prerelease } }
        if ($plan.Mode -eq 'scan') {
            $null = Write-CatalogFile -Path (Join-Path $candidate $script:CatalogPath) -Catalog $catalog -WhatIf:$false -Confirm:$false
            $scannedAt = Format-UtcTime -Value $Now
            foreach ($item in $scanned) {
                if (-not $stateAfter.Packages.Contains($item.PackageId)) { $stateAfter.Packages[$item.PackageId] = [pscustomobject]@{ Stable = $null; Prerelease = $null } }
                $entry = [pscustomobject]@{ Version = $item.Version; ScannedAt = $scannedAt }
                if ($item.Channel -eq 'stable') { $stateAfter.Packages[$item.PackageId].Stable = $entry } else { $stateAfter.Packages[$item.PackageId].Prerelease = $entry }
            }
            $null = Write-ScanState -Path (Join-Path $candidate $script:ScanStatePath) -State $stateAfter -WhatIf:$false -Confirm:$false
            $unseen = @($catalog.Entries.Values | Where-Object { [string]::IsNullOrEmpty($_.Package) } | ForEach-Object Id)
            if ($unseen.Count -gt 0) { $notes.Add("Catalog ids no scanned package carries (they keep no package fields): $($unseen -join ', ').") }
        }
        $plan.StateAfter = $stateAfter
        $findings = [System.Collections.Generic.List[object]]::new()
        try {
            $null = Update-RulebookEndpoints -RepositoryRoot $candidate -WhatIf:$false -Confirm:$false
        } catch {
            $findings.Add([pscustomobject]@{ PSTypeName = 'Rulebook.Finding'; Rule = 'scan'; Severity = 'error'; File = $null; Id = $null; Message = "The scanned rulebook cannot be regenerated: $($_.Exception.Message)" })
        }

        # 10. Validate.
        foreach ($finding in @(Test-Rulebook -RepositoryRoot $candidate)) { $findings.Add($finding) }
        $plan.Findings = $findings.ToArray()
        $plan.Valid = @($findings | Where-Object Severity -EQ 'error').Count -eq 0

        # 11. Changes.
        [string[]]$orgFiles = @(Get-TreeFile -Root $root)
        [string[]]$candidateFiles = @(Get-TreeFile -Root $candidate)
        $orgSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$orgFiles, [System.StringComparer]::Ordinal)
        $candidateSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$candidateFiles, [System.StringComparer]::Ordinal)
        [string[]]$union = Get-Distinct (@($orgFiles) + @($candidateFiles))
        [System.Array]::Sort($union, [System.StringComparer]::Ordinal)
        $changes = foreach ($path in $union) {
            $change = $null
            if (-not $orgSet.Contains($path)) { $change = 'created' }
            elseif (-not $candidateSet.Contains($path)) { $change = 'deleted' }
            elseif ((Get-ComparableContent -Root $root -Path $path) -cne (Get-ComparableContent -Root $candidate -Path $path)) { $change = 'modified' }
            if ($null -eq $change) { continue }
            $bytes = if ($change -eq 'deleted') { $null } else { [System.IO.File]::ReadAllBytes((Join-Path $candidate $path)) }
            [pscustomobject]@{ File = $path; Change = $change; Bytes = $bytes }
        }
        $plan.Changes = @($changes)
    } catch {
        $exceptionStage = [string]$_.Exception.Data['Stage']
        $plan.Failure = if ($exceptionStage -cin 'nuget', 'extract') { $exceptionStage } elseif ($stage -cin 'nuget', 'extract') { $stage } else { 'error' }
        $plan.FailureMessage = $_.Exception.Message
        $plan.Valid = $false
    }
    $plan.Notes = $notes.ToArray()
    $plan.Counts = Get-ScanCount -Plan $plan
    return $plan
}

function Get-ScanCount {
    <#
    .SYNOPSIS
    The counts of a plan: { NewIds, Quarantined, RecordedNew, Unadvertised, Promoted, ChangedDefaults, Released,
    Refreshed, Recorded, Changes }.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)]$Plan)
    $facts = Get-ScanFacts -Plan $Plan
    return [pscustomobject]@{
        NewIds          = $facts.NewIds.Count
        Quarantined     = $facts.QuarantinedNew.Count
        RecordedNew     = $facts.RecordedNew.Count
        Unadvertised    = $facts.NewUnadvertised.Count
        Promoted        = $facts.Promoted.Count
        ChangedDefaults = $facts.ChangedDefaults.Count
        Released        = $facts.Released.Count
        Refreshed       = $facts.Refreshed.Count
        Recorded        = $facts.Recorded.Count
        Changes         = @($Plan.Changes).Count
    }
}

#endregion

#region Title, body, summary

function Get-ScanTitle {
    <#
    .SYNOPSIS
    The pull request title and commit message of a scan.
    .DESCRIPTION
    'Scan diagnostics: <parts> (<label> <version>, ...)' with the parts in the order '3 new ids quarantined' ('3 new
    ids recorded' for new ids no policy stage took), '2 ids promoted to stable', '1 default changed', '1 quarantine
    entry released', and the labels alcops and tools. A run with no part: 'Scan diagnostics: alcops 1.3.2 recorded,
    no new diagnostics'. A housekeeping run: 'Scan diagnostics: 1 quarantine entry released, no new package version'.
    Prerelease default changes do not count.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Plan)
    $facts = Get-ScanFacts -Plan $Plan
    $parts = [System.Collections.Generic.List[string]]::new()
    if ($facts.QuarantinedNew.Count -gt 0) { $parts.Add((Format-Count $facts.QuarantinedNew.Count 'new id quarantined' 'new ids quarantined')) }
    if ($facts.RecordedNew.Count -gt 0) { $parts.Add((Format-Count $facts.RecordedNew.Count 'new id recorded' 'new ids recorded')) }
    if ($facts.Promoted.Count -gt 0) { $parts.Add((Format-Count $facts.Promoted.Count 'id promoted to stable' 'ids promoted to stable')) }
    if ($facts.ChangedDefaults.Count -gt 0) { $parts.Add((Format-Count $facts.ChangedDefaults.Count 'default changed' 'defaults changed')) }
    if ($facts.Released.Count -gt 0) { $parts.Add((Format-Count $facts.Released.Count 'quarantine entry released' 'quarantine entries released')) }
    if ($Plan.Mode -eq 'housekeeping') {
        $what = if ($parts.Count -gt 0) { $parts -join ', ' } else { 'housekeeping' }
        return "Scan diagnostics: $what, no new package version"
    }
    $sorted = @($Plan.Scanned | Sort-Object { if ($_.Label -ceq 'alcops') { 0 } else { 1 } }, { if ($_.Channel -eq 'stable') { 0 } else { 1 } })
    [string[]]$versions = @($sorted | ForEach-Object { "$($_.Label) $($_.Version)" })
    if ($parts.Count -eq 0) { return "Scan diagnostics: $(Join-AndList $versions) recorded, no new diagnostics" }
    return "Scan diagnostics: $($parts -join ', ') ($($versions -join ', '))"
}

function Get-ScanSection {
    # The sections of a scan as Markdown strings, '' when empty, plus the effective diff blocks and the New
    # diagnostics rows (for the body limit).
    param([Parameter(Mandatory)]$Plan, [AllowNull()][AllowEmptyCollection()][object[]]$Diff, [string]$DiffNote)
    $Diff = @($Diff | Where-Object { $null -ne $_ })
    $facts = Get-ScanFacts -Plan $Plan
    $catalog = $Plan.CatalogAfter
    $entryOf = { param($Id) if ($null -ne $catalog -and $catalog.Entries.Contains($Id)) { $catalog.Entries[$Id] } else { $null } }
    $sections = [ordered]@{}

    $text = [System.Text.StringBuilder]::new()
    if (@($Plan.Scanned).Count -gt 0) {
        [void]$text.AppendLine('## Scanned versions').AppendLine()
        [void]$text.AppendLine('| Package | Channel | Version | Previously recorded | Ids | New | Changed defaults |').AppendLine('|---|---|---|---|---|---|---|')
        foreach ($item in $Plan.Scanned) {
            $before = if ($null -ne $Plan.State -and $Plan.State.Packages.Contains($item.PackageId)) { $Plan.State.Packages[$item.PackageId] } else { $null }
            $last = if ($null -eq $before) { $null } elseif ($item.Channel -eq 'stable') { $before.Stable } else { $before.Prerelease }
            $previous = if ($null -eq $last) { 'none' } else { $last.Version }
            $changed = if ($item.Channel -eq 'stable') { @($item.Diff.ChangedDefaults).Count } else { "$(@($item.Diff.PrereleaseDefaultChanges).Count) (not applied)" }
            [void]$text.AppendLine(('| {0} | {1} | {2} | {3} | {4} | {5} | {6} |' -f $item.PackageId, $item.Channel, $item.Version, $previous, $item.Records.Records.Count, @($item.Diff.NewIds).Count, $changed))
        }
        [void]$text.AppendLine()
    }
    $sections.Scanned = $text.ToString()

    # New diagnostics: one row per new id, quarantined or not.
    $rows = [System.Collections.Generic.List[string]]::new()
    foreach ($item in $Plan.Scanned) {
        $policy = if ($item.Channel -eq 'stable') { @($Plan.Policy.Stages) } else { @($Plan.Policy.PrereleaseStages) }
        foreach ($id in $item.Diff.NewIds) {
            $entry = & $entryOf $id
            $stages = @($Plan.Quarantine.Added | Where-Object Id -CEQ $id | ForEach-Object Stage)
            $where = if ($stages.Count -gt 0) { $stages -join ', ' }
            elseif ($id -cin $item.Diff.Unadvertised) { 'nowhere (not advertised)' }
            elseif ($policy.Count -eq 0) { 'nowhere (policy [])' }
            else { 'nowhere (a level file mentions it)' }
            $default = if ($null -eq $entry) { '' } elseif ($entry.EnabledByDefault) { $entry.DefaultSeverity } else { "$($entry.DefaultSeverity) (disabled)" }
            $docs = if ($null -ne $entry -and $entry.Docs) { "[docs](<$($entry.Docs)>)" } else { '' }
            $rows.Add(('| {0} | {1} | {2} | {3} | {4} | {5} {6} ({7}) | {8} |' -f $id, (Format-TableCell $entry.Analyzer), $default, (Format-PackageText $entry.Title), $docs, $item.PackageId, $item.Version, $item.Channel, $where))
        }
        # Ids an analyzer advertises for the first time: they go live at their default like a new id.
        foreach ($id in @(if ($item.Diff.PSObject.Properties['NewlyAdvertised']) { $item.Diff.NewlyAdvertised })) {
            $entry = & $entryOf $id
            $stages = @($Plan.Quarantine.Added | Where-Object Id -CEQ $id | ForEach-Object Stage)
            $where = if ($stages.Count -gt 0) { $stages -join ', ' } elseif (@($Plan.Policy.Stages).Count -eq 0) { 'nowhere (policy [])' } else { 'nowhere (a level file mentions it)' }
            $default = if ($null -eq $entry) { '' } elseif ($entry.EnabledByDefault) { $entry.DefaultSeverity } else { "$($entry.DefaultSeverity) (disabled)" }
            $docs = if ($null -ne $entry -and $entry.Docs) { "[docs](<$($entry.Docs)>)" } else { '' }
            $rows.Add(('| {0} | {1} | {2} | {3} | {4} | {5} {6} ({7}, now advertised) | {8} |' -f $id, (Format-TableCell $entry.Analyzer), $default, (Format-PackageText $entry.Title), $docs, $item.PackageId, $item.Version, $item.Channel, $where))
        }
    }
    $sections.NewHead = if ($rows.Count -gt 0) { "## New diagnostics`n`n| Id | Analyzer | Default | Title | Docs | Seen in | Quarantined in |`n|---|---|---|---|---|---|---|`n" } else { '' }
    $sections.NewRows = $rows.ToArray()

    $text = [System.Text.StringBuilder]::new()
    if ($facts.Promoted.Count -gt 0) {
        [void]$text.AppendLine('## Promoted to stable').AppendLine()
        [void]$text.AppendLine('| Id | Stable version | Quarantined in |').AppendLine('|---|---|---|')
        foreach ($id in $facts.Promoted) {
            $entry = & $entryOf $id
            $stages = @($Plan.Quarantine.Added | Where-Object Id -CEQ $id | ForEach-Object Stage)
            [void]$text.AppendLine(('| {0} | {1} | {2} |' -f $id, $(if ($entry) { $entry.FirstStableVersion } else { '' }), $(if ($stages.Count -gt 0) { $stages -join ', ' } else { 'no new stage' })))
        }
        [void]$text.AppendLine()
    }
    $sections.Promoted = $text.ToString()

    $text = [System.Text.StringBuilder]::new()
    if ($facts.ChangedDefaults.Count -gt 0) {
        [void]$text.AppendLine('## Changed defaults').AppendLine()
        [void]$text.AppendLine('The analyzer default moved; endpoints list only deviations from it (D22, D24), so an id can join or leave an endpoint.').AppendLine()
        [void]$text.AppendLine('| Id | Field | From | To | Version | Effect |').AppendLine('|---|---|---|---|---|---|')
        foreach ($change in $facts.ChangedDefaults) {
            $listing = @($Diff | Where-Object { $null -ne $_ -and $_.Id -ceq $change.Id -and $_.Change -eq 'listing' })
            $effects = [System.Collections.Generic.List[string]]::new()
            $listed = @($listing | Where-Object { $_.ListedAfter })
            $unlisted = @($listing | Where-Object { -not $_.ListedAfter })
            foreach ($group in @($listed | Group-Object After)) { $effects.Add("now listed at $($group.Name) in $(@($group.Group | ForEach-Object Endpoint) -join ', ')") }
            if ($unlisted.Count -gt 0) { $effects.Add("now unlisted in $(@($unlisted | ForEach-Object Endpoint) -join ', ')") }
            $effect = if ($effects.Count -gt 0) { $effects -join '; ' } else { 'no endpoint listing changes' }
            [void]$text.AppendLine(('| {0} | {1} | {2} | {3} | {4} | {5} |' -f $change.Id, $change.Field, $change.From, $change.To, $change.Version, $effect))
        }
        [void]$text.AppendLine()
    }
    $sections.Defaults = $text.ToString()

    $text = [System.Text.StringBuilder]::new()
    if ($facts.PrereleaseDefaults.Count -gt 0) {
        [void]$text.AppendLine('## Prerelease default changes (not applied)').AppendLine()
        [void]$text.AppendLine('A prerelease changes no catalog default; the change is applied when a stable version carries it.').AppendLine()
        [void]$text.AppendLine('| Id | Field | From | To | Version |').AppendLine('|---|---|---|---|---|')
        foreach ($change in $facts.PrereleaseDefaults) { [void]$text.AppendLine(('| {0} | {1} | {2} | {3} | {4} |' -f $change.Id, $change.Field, $change.From, $change.To, $change.Version)) }
        [void]$text.AppendLine()
    }
    $sections.Prerelease = $text.ToString()

    $text = [System.Text.StringBuilder]::new()
    if ($facts.Released.Count -gt 0) {
        [void]$text.AppendLine('## Released from quarantine').AppendLine()
        [void]$text.AppendLine('A level file mentions these ids now, so the chain decides (housekeeping, C13).').AppendLine()
        [void]$text.AppendLine('| Stage | Id | Mentioned by |').AppendLine('|---|---|---|')
        foreach ($item in $facts.Released) { [void]$text.AppendLine(('| {0} | {1} | {2} |' -f $item.Stage, $item.Id, (@($item.MentionedBy | ForEach-Object { '`' + $_ + '`' }) -join ', '))) }
        [void]$text.AppendLine()
    }
    $sections.Released = $text.ToString()

    $bullets = [System.Collections.Generic.List[string]]::new()
    if ($facts.NewUnadvertised.Count -gt 0) { $bullets.Add("New ids no analyzer advertises (cataloged with advertised false, never quarantined): $($facts.NewUnadvertised -join ', ').") }
    $known = @($facts.Unadvertised | Where-Object { $_ -cnotin $facts.NewUnadvertised })
    if ($known.Count -gt 0) { $bullets.Add("Known ids no analyzer advertises: $($known -join ', ').") }
    if ($facts.Deprecated.Count -gt 0) { $bullets.Add("Deprecated: $($facts.Deprecated -join ', ').") }
    if ($facts.Vanished.Count -gt 0) { $bullets.Add("Not in the scanned stable version any more (entries kept, lastSeenVersion stays): $($facts.Vanished -join ', ').") }
    if ($facts.Recorded.Count -gt 0) { $bullets.Add("$(Format-Count $facts.Recorded.Count 'seeded id' 'seeded ids') got their package fields.") }
    if ($facts.Refreshed.Count -gt 0) {
        $titles = @($facts.Refreshed | Where-Object Field -EQ 'title').Count
        $docs = @($facts.Refreshed | Where-Object Field -EQ 'docs').Count
        $bullets.Add("Refreshed from the stable descriptors: $(Format-Count $titles 'title' 'titles'), $(Format-Count $docs 'docs link' 'docs links').")
    }
    foreach ($note in $Plan.Notes) { $bullets.Add($note) }
    $sections.Notes = if ($bullets.Count -gt 0) { "## Catalog notes`n`n" + (($bullets | ForEach-Object { "- $_" }) -join "`n") + "`n`n" } else { '' }

    $text = [System.Text.StringBuilder]::new()
    [void]$text.AppendLine('## Changes').AppendLine()
    if (@($Plan.Changes).Count -eq 0) {
        [void]$text.AppendLine('No file changes.').AppendLine()
    } else {
        [void]$text.AppendLine('| File | Change |').AppendLine('|---|---|')
        foreach ($change in $Plan.Changes) { [void]$text.AppendLine(('| `{0}` | {1} |' -f $change.File, $change.Change)) }
        [void]$text.AppendLine()
    }
    $sections.Changes = $text.ToString()

    $sections.DiffHead = "## Effective diff`n`n"
    $sections.DiffEmpty = if ($DiffNote) { "$DiffNote`n`n" } elseif (@($Diff).Count -eq 0) { "No effective change.`n`n" } else { '' }
    # Assigned in two steps: an if expression would unroll an empty array into $null.
    [string[]]$blocks = @()
    # Get-EffectiveDiffBlock returns its array with a comma; @() around it would nest it.
    if (-not $DiffNote -and $Diff.Count -gt 0) { $blocks = Get-EffectiveDiffBlock -Diff $Diff }
    $sections.DiffBlocks = $blocks

    $text = [System.Text.StringBuilder]::new()
    $warnings = @($Plan.Findings | Where-Object Severity -EQ 'warning')
    if ($warnings.Count -gt 0) {
        [void]$text.AppendLine('## Validation warnings').AppendLine()
        [void]$text.AppendLine('| Rule | File | Id | Message |').AppendLine('|---|---|---|---|')
        foreach ($finding in $warnings) {
            $file = if ($finding.File) { '`' + $finding.File + '`' } else { '' }
            [void]$text.AppendLine(('| {0} | {1} | {2} | {3} |' -f $finding.Rule, $file, (Format-TableCell $finding.Id), (Format-TableCell $finding.Message)))
        }
        [void]$text.AppendLine()
    }
    $sections.Warnings = $text.ToString()
    return [pscustomobject]$sections
}

function ConvertTo-ScanPullRequestBody {
    <#
    .SYNOPSIS
    The pull request body of a scan.
    .DESCRIPTION
    The intro (date, base and its sha, scanned versions, how the branch is rebuilt), then '## Scanned versions',
    '## New diagnostics', '## Promoted to stable', '## Changed defaults', '## Prerelease default changes (not
    applied)', '## Released from quarantine', '## Catalog notes', '## Changes', '## Effective diff' and '## Validation
    warnings', each only when it has content (Changes and Effective diff always). Above -Limit (default 60000; GitHub
    allows 65536) the effective diff tables are dropped from the end, then the New diagnostics rows beyond 200, each
    with an italic line, and only then is the body cut at a line boundary.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]$Plan,
        [AllowNull()][AllowEmptyCollection()][object[]]$Diff,
        [string]$DiffNote,
        [string]$Base,
        [string]$BaseSha,
        [int]$Limit = $script:BodyLimit
    )
    $sections = Get-ScanSection -Plan $Plan -Diff $Diff -DiffNote $DiffNote
    $date = $Plan.Now.UtcDateTime.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
    $versions = @($Plan.Scanned | ForEach-Object { "$($_.PackageId) $($_.Version) ($($_.Channel))" })
    $what = if ($versions.Count -gt 0) { "Scanned $(Join-AndList $versions)." } else { 'No new package version; quarantine housekeeping only.' }
    $branch = "$($script:BranchPrefix)/$Base"
    $at = if ($BaseSha) { " at $(Get-ShortSha $BaseSha)" } else { '' }
    $intro = "Diagnostic scan of $date on ``$Base``$at. $what`n`nThis pull request is rebuilt from ``$Base`` on every run of the Scan Diagnostics workflow, on branch ``$branch``: do not push to that branch; merge this pull request or close it.`n`n"
    $build = {
        param([int]$BlockCount, [string]$DroppedBlocks, [int]$RowCount, [string]$DroppedRows)
        $new = ''
        if ($sections.NewHead) {
            $new = $sections.NewHead + ((@($sections.NewRows | Select-Object -First $RowCount) | ForEach-Object { "$_`n" }) -join '') + "`n"
            if ($DroppedRows) { $new += "$DroppedRows`n`n" }
        }
        $diffText = $sections.DiffHead + $sections.DiffEmpty + (@($sections.DiffBlocks | Select-Object -First $BlockCount) -join '')
        if ($DroppedBlocks) { $diffText += "$DroppedBlocks`n`n" }
        return ($intro + $sections.Scanned + $new + $sections.Promoted + $sections.Defaults + $sections.Prerelease + $sections.Released + $sections.Notes + $sections.Changes + $diffText + $sections.Warnings).Replace("`r`n", "`n")
    }
    $blocks = $sections.DiffBlocks.Count
    $rows = $sections.NewRows.Count
    $body = & $build $blocks $null $rows $null
    if ($body.Length -le $Limit) { return $body }
    $droppedBlocks = $null
    for ($count = $blocks - 1; $count -ge 0; $count--) {
        $droppedBlocks = "_$($blocks - $count) of $blocks endpoint tables of the effective diff were left out to keep this body below the GitHub limit; the job summary of the scan run has them._"
        $body = & $build $count $droppedBlocks $rows $null
        if ($body.Length -le $Limit) { return $body }
    }
    if ($rows -gt $script:NewRowLimit) {
        $droppedRows = "_$($rows - $script:NewRowLimit) more new ids are in catalog/diagnostics.json and the quarantine files of this pull request._"
        $body = & $build 0 $droppedBlocks $script:NewRowLimit $droppedRows
        if ($body.Length -le $Limit) { return $body }
    }
    $tail = "`n_The body was cut at a line boundary to stay below the GitHub limit; the job summary of the scan run has the full lists._`n"
    $cut = $body.LastIndexOf("`n", [math]::Max(0, $Limit - $tail.Length - 1), [System.StringComparison]::Ordinal)
    if ($cut -lt 0) { $cut = 0 }
    return $body.Substring(0, $cut + 1) + $tail
}

function ConvertTo-ScanSummary {
    <#
    .SYNOPSIS
    The job summary of a scan run: '## Diagnostic scan', the message and the result, then the body sections without
    a limit (the entry script caps the summary below the step summary limit).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Plan, [AllowNull()]$Result, [string]$Message)
    $text = [System.Text.StringBuilder]::new()
    [void]$text.AppendLine('## Diagnostic scan').AppendLine()
    if ($Message) { [void]$text.AppendLine("**$Message**").AppendLine() }
    # A failed plan has no result to show; its message is the summary.
    if ($Plan.PSObject.Properties['Failure'] -and $Plan.Failure) {
        if ($Plan.FailureMessage -and $Plan.FailureMessage -cne $Message) { [void]$text.AppendLine($Plan.FailureMessage).AppendLine() }
        return $text.ToString().Replace("`r`n", "`n")
    }
    $versions = @($Plan.Channels | ForEach-Object { "$($_.PackageId) $($_.Stable) stable" + $(if ($_.Prerelease) { ", $($_.Prerelease) prerelease" } else { '' }) })
    if ($versions.Count -gt 0) { [void]$text.AppendLine("Newest versions on NuGet: $($versions -join '; ').").AppendLine() }
    if ($null -ne $Result) {
        $line = switch ($Result.Result) {
            'pull-request' { "Pull request: $($Result.PullRequestUrl)" + $(if ($Result.Fallback) { ' (the direct commit was refused)' } else { '' }) }
            'pull-request-updated' { "Pull request updated: $($Result.PullRequestUrl)" }
            'direct-commit' { "Committed $(Get-ShortSha $Result.Sha) to $($Result.Branch)." }
            'no-changes' { 'No changes to commit.' }
            default { [string]$Result.Result }
        }
        [void]$text.AppendLine($line).AppendLine()
        if ($Result.PSObject.Properties['ClosedPullRequestUrl'] -and $Result.ClosedPullRequestUrl) { [void]$text.AppendLine("Pull request closed: $($Result.ClosedPullRequestUrl)").AppendLine() }
    }
    if ($Plan.Mode -eq 'nothing-new') { return $text.ToString().Replace("`r`n", "`n") }
    $diff = if ($null -ne $Result -and $Result.PSObject.Properties['Diff']) { @($Result.Diff) } else { @() }
    $diffNote = if ($null -ne $Result -and $Result.PSObject.Properties['DiffNote']) { [string]$Result.DiffNote } else { '' }
    if ($null -eq $Result) { $diffNote = 'The effective diff is computed when the scan is published.' }
    $sections = Get-ScanSection -Plan $Plan -Diff $diff -DiffNote $diffNote
    $new = if ($sections.NewHead) { $sections.NewHead + (($sections.NewRows | ForEach-Object { "$_`n" }) -join '') + "`n" } else { '' }
    [void]$text.Append($sections.Scanned).Append($new).Append($sections.Promoted).Append($sections.Defaults).Append($sections.Prerelease).Append($sections.Released).Append($sections.Notes).Append($sections.Changes)
    [void]$text.Append($sections.DiffHead).Append($sections.DiffEmpty).Append(($sections.DiffBlocks -join '')).Append($sections.Warnings)
    $errors = @($Plan.Findings | Where-Object Severity -EQ 'error')
    if ($errors.Count -gt 0) {
        [void]$text.AppendLine('## Validation errors of the scanned rulebook').AppendLine()
        [void]$text.AppendLine('| Rule | File | Id | Message |').AppendLine('|---|---|---|---|')
        foreach ($finding in $errors) {
            $file = if ($finding.File) { '`' + $finding.File + '`' } else { '' }
            [void]$text.AppendLine(('| {0} | {1} | {2} | {3} |' -f $finding.Rule, $file, (Format-TableCell $finding.Id), (Format-TableCell $finding.Message)))
        }
        [void]$text.AppendLine()
    }
    return $text.ToString().Replace("`r`n", "`n")
}

#endregion

#region Publish

function Publish-RulebookScan {
    <#
    .SYNOPSIS
    Applies a valid scan plan to a fresh clone and keeps the living pull request (or pushes a direct commit).
    .DESCRIPTION
    Refuses an invalid plan and a nothing-new plan. Clones -RemoteUrl (default <GITHUB_SERVER_URL>/<Repository>) at
    -BaseBranch, writes the plan's changes, commits with the title (Get-ScanTitle) and pushes
    scan-diagnostics/<base>, rebuilt from the base head with a lease push (Publish-GitHubChange -Force); with
    -DirectCommit it pushes to the base branch (a refused push falls back to the scan branch). The effective diff is
    computed against the cloned head. A plan that recorded the head of its checkout (HeadSha) refuses a base branch that
    moved since (stage push). With no changes or a direct commit an open scan pull request is closed
    (ClosedPullRequestUrl). Then the open pull request from that branch is updated (PATCH title and body,
    pull-request-updated) or a new one is opened with -Labels (pull-request). Returns { Result (pull-request,
    pull-request-updated, direct-commit, no-changes), PullRequestUrl, Number, Branch, Sha, Fallback, Diff, DiffNote,
    Body, Title }. A failure throws with Data['Stage']: push for the clone, commit and push; pull-request after the
    push, naming the pushed branch and its tree link.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]$Plan,
        [string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$Repository,
        [string]$RemoteUrl,
        [AllowNull()][AllowEmptyString()][string]$Token,
        [Parameter(Mandatory)][string]$BaseBranch,
        [switch]$DirectCommit,
        [AllowNull()][AllowEmptyString()][string]$Actor,
        [AllowNull()][AllowEmptyCollection()][string[]]$Labels,
        [string]$WorkPath,
        [AllowNull()][AllowEmptyString()][string]$ApiUrl
    )
    if (-not $Plan.Valid -or $Plan.Failure) { throw 'The scan plan does not validate; nothing is pushed.' }
    if ($Plan.Mode -eq 'nothing-new') { throw 'The scan found nothing new; nothing is pushed.' }
    if ([string]::IsNullOrEmpty($WorkPath)) { $WorkPath = Get-DefaultWorkPath -Prefix 'rulebook-scan' }
    $server = if ($env:GITHUB_SERVER_URL) { $env:GITHUB_SERVER_URL.TrimEnd('/') } else { 'https://github.com' }
    if ([string]::IsNullOrEmpty($RemoteUrl)) { $RemoteUrl = "$server/$Repository" }
    $title = Get-ScanTitle -Plan $Plan
    $branch = "$($script:BranchPrefix)/$BaseBranch"

    # The rulebook may sit in a folder of a bigger repository; the plan's paths are relative to that folder.
    $prefix = ''
    if ($RepositoryRoot -and (Get-Command git -ErrorAction SilentlyContinue)) {
        $show = & git -C $RepositoryRoot rev-parse --show-prefix 2>$null
        if ($LASTEXITCODE -eq 0 -and $show) { $prefix = ([string]$show).Trim() }
    }
    try {
        $clone = New-GitHubClone -RemoteUrl $RemoteUrl -Branch $BaseBranch -Path (Join-Path $WorkPath 'clone') -Token $Token -Actor $Actor
        $planned = if ($Plan.PSObject.Properties['HeadSha']) { [string]$Plan.HeadSha } else { '' }
        if ($planned -and $planned -cne $clone.BaseSha) {
            throw "The base branch moved during the scan ($BaseBranch was at $(Get-ShortSha $planned) when the scan started and is at $(Get-ShortSha $clone.BaseSha) now); nothing was pushed, the next run will pick it up."
        }
        $rulebookRoot = if ($prefix) { Join-Path $clone.Path $prefix.TrimEnd('/') } else { $clone.Path }
        foreach ($change in $Plan.Changes) {
            $target = Join-Path $rulebookRoot $change.File
            if ($change.Change -ceq 'deleted') {
                if (Test-Path -LiteralPath $target -PathType Leaf) { Remove-Item -LiteralPath $target -Force }
            } else {
                $parent = Split-Path -Parent $target
                if (-not (Test-Path -LiteralPath $parent -PathType Container)) { [void][System.IO.Directory]::CreateDirectory($parent) }
                [System.IO.File]::WriteAllBytes($target, [byte[]]$change.Bytes)
            }
        }
        $pushed = Publish-GitHubChange -Clone $clone -Message $title -NewBranch $branch -DirectCommit:$DirectCommit -Force
    } catch {
        $exception = [System.InvalidOperationException]::new($_.Exception.Message, $_.Exception)
        $exception.Data['Stage'] = 'push'
        throw $exception
    }
    $result = [pscustomobject]@{ Result = $null; PullRequestUrl = $null; Number = $null; Branch = $pushed.Branch; Sha = $pushed.Sha; Fallback = [bool]$pushed.Fallback; Diff = @(); DiffNote = $null; Body = $null; Title = $title; ClosedPullRequestUrl = $null }
    # An open scan pull request is stale once the base holds the result (no changes, or a direct commit): close it.
    $closeStale = {
        param([string]$Reason)
        try {
            $open = Find-GitHubPullRequestByHead -Repository $Repository -Head $branch -Base $BaseBranch -Token $Token -ApiUrl $ApiUrl
            if ($null -eq $open) { return }
            $date = $Plan.Now.UtcDateTime.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
            # A pull request reopened by hand and closed again carries the line once.
            $previous = [regex]::Replace([string]$open.Body, '^(Closed by the scan of [^\r\n]*\r?\n\r?\n)+', '')
            $closedBody = "Closed by the scan of $($date): $Reason`n`n$previous"
            $closed = Update-GitHubPullRequest -Repository $Repository -Number $open.Number -Title $open.Title -Body $closedBody -State closed -Token $Token -ApiUrl $ApiUrl
            $result.ClosedPullRequestUrl = if ($closed.Url) { $closed.Url } else { $open.Url }
        } catch {
            $exception = [System.InvalidOperationException]::new("The open scan pull request could not be closed: $($_.Exception.Message)", $_.Exception)
            $exception.Data['Stage'] = 'pull-request'
            throw $exception
        }
    }
    if (-not $pushed.Pushed) {
        $result.Result = 'no-changes'
        & $closeStale "the base branch $BaseBranch already contains its result."
        return $result
    }
    try {
        $result.Diff = @(Compare-RulebookEndpoints -RepositoryRoot $rulebookRoot -Ref $clone.BaseSha)
    } catch {
        $result.DiffNote = "The effective diff could not be computed: $($_.Exception.Message)"
    }
    if ($pushed.Direct) {
        $result.Result = 'direct-commit'
        & $closeStale "its result is on $BaseBranch already (direct commit $(Get-ShortSha $pushed.Sha))."
        return $result
    }
    try {
        $body = ConvertTo-ScanPullRequestBody -Plan $Plan -Diff $result.Diff -DiffNote $result.DiffNote -Base $BaseBranch -BaseSha $clone.BaseSha
        $result.Body = $body
        $open = Find-GitHubPullRequestByHead -Repository $Repository -Head $pushed.Branch -Base $BaseBranch -Token $Token -ApiUrl $ApiUrl
        if ($null -ne $open) {
            $updated = Update-GitHubPullRequest -Repository $Repository -Number $open.Number -Title $title -Body $body -Token $Token -ApiUrl $ApiUrl
            $result.Result = 'pull-request-updated'
            $result.Number = $open.Number
            $result.PullRequestUrl = if ($updated.Url) { $updated.Url } else { $open.Url }
        } else {
            $pull = New-GitHubPullRequest -Repository $Repository -Token $Token -Title $title -Body $body -Head $pushed.Branch -Base $BaseBranch -Labels $Labels -ApiUrl $ApiUrl -ServerUrl $server
            $result.Result = 'pull-request'
            $result.Number = $pull.Number
            $result.PullRequestUrl = $pull.Url
        }
    } catch {
        $segments = @(foreach ($part in @($Repository.Split('/')) + @('tree') + @($pushed.Branch.Split('/'))) { [System.Uri]::EscapeDataString($part) })
        $link = "$server/$($segments -join '/')"
        $message = "Branch $($pushed.Branch) was pushed. $($_.Exception.Message)"
        if (-not $message.Contains($link)) { $message += " Open the pull request by hand: $link" }
        $exception = [System.InvalidOperationException]::new($message, $_.Exception)
        $exception.Data['Stage'] = 'pull-request'
        $exception.Data['Branch'] = $pushed.Branch
        throw $exception
    }
    return $result
}

#endregion

Export-ModuleMember -Function @(
    'ConvertTo-ScanPullRequestBody'
    'ConvertTo-ScanSummary'
    'Get-RulebookScanPlan'
    'Get-ScanCount'
    'Get-ScanTitle'
    'Publish-RulebookScan'
)
