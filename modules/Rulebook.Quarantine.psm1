#requires -Version 7.4
# Rulebook.Quarantine: the quarantine policy of the settings and the quarantine.<stage>.json files the diagnostic scan
# writes (WP08, R9, D14, D41). Reads the policy (no default: a missing policy stops the scan), reads and writes the
# quarantine files in the layout of the template, adds the new ids of a scan to the policy stages and releases the
# ids a level file has adopted (housekeeping, the rule of C13). Never writes a file for a slug that is not a stage of
# the settings (#48, C16). Contract: docs/reference/scan-mechanics.md section 4.

Set-StrictMode -Version 3.0
Import-Module (Join-Path $PSScriptRoot 'Rulebook.Common.psd1')
Import-Module (Join-Path $PSScriptRoot 'Rulebook.Generate.psd1')

$script:QuarantineSchemaUrl = 'https://raw.githubusercontent.com/ALCops/rulebook-engine/v1/schemas/rulebook-quarantine.schema.json'
$script:PolicyMessage = 'Set quarantine.stages and quarantine.prereleaseStages in .github/Rulebook-Settings.json. Typical choice: quarantine default and ci, leave vnext out so it shows new rules at their default severity.'
$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

#region Internal helpers

function New-PolicyException {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an exception; changes no state')]
    param([Parameter(Mandatory)][string]$Message)
    $exception = [System.InvalidOperationException]::new($Message)
    $exception.Data['Stage'] = 'policy'
    return $exception
}

function Get-SettingsStageSlug {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Settings)
    return [string[]]@($Settings['stages'] | Where-Object { $_ -is [System.Collections.IDictionary] -and $_['name'] -is [string] } | ForEach-Object { ([string]$_['name']).ToLowerInvariant() })
}

#endregion

function Get-QuarantinePolicy {
    <#
    .SYNOPSIS
    The quarantine policy of the settings: { Stages, PrereleaseStages } (stage slugs; empty arrays are valid).
    .DESCRIPTION
    There is no default (D14): quarantine absent, or either key absent or null, throws the message that tells the
    organization what to set, with Data['Stage'] = 'policy'. A slug that is not a stage of the settings throws in the
    wording of C5.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Settings)
    $quarantine = $Settings['quarantine']
    if ($quarantine -isnot [System.Collections.IDictionary]) { throw (New-PolicyException -Message $script:PolicyMessage) }
    foreach ($key in 'stages', 'prereleaseStages') {
        if (-not $quarantine.Contains($key) -or $null -eq $quarantine[$key]) { throw (New-PolicyException -Message $script:PolicyMessage) }
    }
    $slugs = Get-SettingsStageSlug -Settings $Settings
    $result = [ordered]@{}
    foreach ($key in 'stages', 'prereleaseStages') {
        $values = [string[]]@($quarantine[$key] | ForEach-Object { [string]$_ })
        foreach ($value in $values) {
            if ($value -cnotin $slugs) { throw (New-PolicyException -Message "quarantine.$key names '$value', which is not a stage slug") }
        }
        $result[$key] = $values
    }
    return [pscustomobject]@{ PSTypeName = 'Rulebook.QuarantinePolicy'; Stages = $result['stages']; PrereleaseStages = $result['prereleaseStages'] }
}

function ConvertFrom-QuarantineFileText {
    <#
    .SYNOPSIS
    A quarantine file as { Schema, Rules (ordinal ordered map id -> justification or $null), Path, Exists }.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [Parameter(Mandatory)][string]$Path)
    try {
        $json = ConvertFrom-Json -InputObject $Text -AsHashtable -Depth 10 -ErrorAction Stop
    } catch {
        throw "Invalid JSON in $Path`: $($_.Exception.Message)"
    }
    if ($json -isnot [System.Collections.IDictionary] -or $json['rules'] -isnot [System.Collections.IList]) { throw "$Path has no rules array" }
    $rules = Get-OrdinalMap
    foreach ($rule in $json['rules']) {
        if ($rule -isnot [System.Collections.IDictionary] -or [string]::IsNullOrEmpty([string]$rule['id'])) { throw "$Path has an entry without an id" }
        $id = [string]$rule['id']
        if ($rules.Contains($id)) { throw "$Path lists $id twice (C2)" }
        $rules[$id] = if ($null -eq $rule['justification']) { $null } else { [string]$rule['justification'] }
    }
    $schema = if ($json['$schema'] -is [string]) { [string]$json['$schema'] } else { $null }
    return [pscustomobject]@{ PSTypeName = 'Rulebook.QuarantineFile'; Schema = $schema; Rules = $rules; Path = $Path; Exists = $true }
}

function Read-QuarantineFile {
    <#
    .SYNOPSIS
    Reads quarantine.<stage>.json; a missing file is { Exists $false } with the schema URL and no rules.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Path)
    $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        return [pscustomobject]@{ PSTypeName = 'Rulebook.QuarantineFile'; Schema = $script:QuarantineSchemaUrl; Rules = (Get-OrdinalMap); Path = $full; Exists = $false }
    }
    $file = ConvertFrom-QuarantineFileText -Text ([System.IO.File]::ReadAllText($full, $script:Utf8NoBom)) -Path $full
    return $file
}

function ConvertTo-QuarantineJson {
    <#
    .SYNOPSIS
    The text of a quarantine file in the template layout: $schema, then one { "id", "justification" } per line
    ("rules": [] when empty). LF line ends and one trailing LF.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$File)
    $schema = if ([string]::IsNullOrEmpty($File.Schema)) { $script:QuarantineSchemaUrl } else { $File.Schema }
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('{')
    $lines.Add('  "$schema": ' + (ConvertTo-JsonString $schema) + ',')
    $ids = @($File.Rules.Keys)
    if ($ids.Count -eq 0) {
        $lines.Add('  "rules": []')
    } else {
        $lines.Add('  "rules": [')
        for ($i = 0; $i -lt $ids.Count; $i++) {
            $item = '{ "id": ' + (ConvertTo-JsonString $ids[$i])
            $justification = $File.Rules[$ids[$i]]
            if ($null -ne $justification) { $item += ', "justification": ' + (ConvertTo-JsonString $justification) }
            $lines.Add('    ' + $item + ' }' + $(if ($i -lt $ids.Count - 1) { ',' } else { '' }))
        }
        $lines.Add('  ]')
    }
    $lines.Add('}')
    return ($lines -join "`n") + "`n"
}

function Write-QuarantineFile {
    <#
    .SYNOPSIS
    Writes a quarantine file when the bytes differ: { File, Change (created, modified) } or nothing.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$File, [string]$Name)
    $Path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    if ([string]::IsNullOrEmpty($Name)) { $Name = Split-Path -Leaf $Path }
    $bytes = $script:Utf8NoBom.GetBytes((ConvertTo-QuarantineJson -File $File))
    $exists = Test-Path -LiteralPath $Path -PathType Leaf
    if ($exists -and [System.Linq.Enumerable]::SequenceEqual([byte[]][System.IO.File]::ReadAllBytes($Path), [byte[]]$bytes)) { return }
    $change = if ($exists) { 'modified' } else { 'created' }
    if ($PSCmdlet.ShouldProcess($Name, "Write ($change)")) { [System.IO.File]::WriteAllBytes($Path, $bytes) }
    return [pscustomobject]@{ PSTypeName = 'Rulebook.FileChange'; File = $Name; Change = $change }
}

function New-QuarantineJustification {
    <#
    .SYNOPSIS
    'New in <package> <version> (<channel>), quarantined <yyyy-MM-dd>. Review and adopt.' (UTC date).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Returns a string; changes no state')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$PackageId,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][ValidateSet('stable', 'prerelease')][string]$Channel,
        [Parameter(Mandatory)][System.DateTimeOffset]$Date
    )
    return 'New in {0} {1} ({2}), quarantined {3}. Review and adopt.' -f $PackageId, $Version, $Channel, $Date.UtcDateTime.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Add-QuarantineEntry {
    <#
    .SYNOPSIS
    Adds -Id to the file of every stage in -Stages that does not list it yet: { Stage, Id }[] of the additions.
    .DESCRIPTION
    -Files maps a stage slug to a quarantine file object; a stage without an entry in -Files is skipped. Idempotent.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Changes the objects passed in; writes no file')]
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Files,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Stages,
        [Parameter(Mandatory)][string]$Id,
        [AllowNull()][AllowEmptyString()][string]$Justification
    )
    $added = foreach ($stage in $Stages) {
        if (-not $Files.Contains($stage)) { continue }
        $rules = $Files[$stage].Rules
        if ($rules.Contains($Id)) { continue }
        $rules[$Id] = if ([string]::IsNullOrEmpty($Justification)) { $null } else { $Justification }
        [pscustomobject]@{ Stage = $stage; Id = $Id }
    }
    return @($added)
}

function Invoke-QuarantineHousekeeping {
    <#
    .SYNOPSIS
    Removes every quarantined id that a level file on a published chain mentions (the rule of C13):
    { Stage, Id, Justification, MentionedBy }[].
    .DESCRIPTION
    -Chains is Rulebook.Inputs.Chains (level slug -> ordered id -> { Action, Slug }); MentionedBy lists the level files
    (base/<slug>.ruleset.json) that set the id on some chain.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Changes the objects passed in; writes no file')]
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Files, [Parameter(Mandatory)][System.Collections.IDictionary]$Chains)
    $removed = foreach ($stage in @($Files.Keys)) {
        $rules = $Files[$stage].Rules
        foreach ($id in @($rules.Keys)) {
            $mentionedBy = [System.Collections.Generic.SortedSet[string]]::new([System.StringComparer]::Ordinal)
            foreach ($chain in $Chains.Values) {
                if ($chain.Contains($id)) { [void]$mentionedBy.Add("base/$($chain[$id].Slug).ruleset.json") }
            }
            if ($mentionedBy.Count -eq 0) { continue }
            $justification = $rules[$id]
            $rules.Remove($id)
            [pscustomobject]@{ Stage = $stage; Id = $id; Justification = $justification; MentionedBy = [string[]]@($mentionedBy) }
        }
    }
    return @($removed)
}

function Update-QuarantineFromScan {
    <#
    .SYNOPSIS
    Quarantines the new ids of a scan and releases the adopted ones in -RepositoryRoot: { Added, Removed, Created,
    Changes }.
    .DESCRIPTION
    Reads quarantine.<slug>.json for every stage of -Settings. NewIds of a stable diff go to Policy.Stages, of a
    prerelease diff to Policy.PrereleaseStages, Promoted and NewlyAdvertised ids (an id an analyzer returns for the first
    time) to Policy.Stages; an id no analyzer advertises
    (Unadvertised) and an id a chain mentions already are never quarantined. Each addition carries
    New-QuarantineJustification of its diff; an existing entry keeps its text. Then housekeeping
    (Invoke-QuarantineHousekeeping). Only files whose rules changed are written (a policy stage without a file gets
    one, Created); a slug that is not a stage of the settings never gets a file.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Settings,
        [Parameter(Mandatory)]$Policy,
        [AllowNull()][AllowEmptyCollection()][object[]]$Diffs,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Chains,
        [System.DateTimeOffset]$Now = [System.DateTimeOffset]::UtcNow
    )
    $root = (Resolve-Path -LiteralPath $RepositoryRoot -ErrorAction Stop).ProviderPath
    $files = Get-OrdinalMap
    $before = @{}
    foreach ($slug in Get-SettingsStageSlug -Settings $Settings) {
        $files[$slug] = Read-QuarantineFile -Path (Join-Path $root "quarantine.$slug.json")
        $before[$slug] = (@($files[$slug].Rules.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "`n")
    }
    $mentioned = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($chain in $Chains.Values) { foreach ($id in $chain.Keys) { [void]$mentioned.Add($id) } }
    $added = [System.Collections.Generic.List[object]]::new()
    foreach ($diff in @($Diffs | Where-Object { $null -ne $_ })) {
        $justification = New-QuarantineJustification -PackageId $diff.PackageId -Version $diff.Version -Channel $diff.Channel -Date $Now
        $unadvertised = [System.Collections.Generic.HashSet[string]]::new([string[]]@($diff.Unadvertised), [System.StringComparer]::Ordinal)
        $newStages = if ($diff.Channel -eq 'stable') { $Policy.Stages } else { $Policy.PrereleaseStages }
        $newlyAdvertised = if ($diff.PSObject.Properties['NewlyAdvertised']) { @($diff.NewlyAdvertised) } else { @() }
        $targets = @(@($diff.NewIds | ForEach-Object { @{ Id = $_; Stages = $newStages } }) + @($diff.Promoted | ForEach-Object { @{ Id = $_; Stages = $Policy.Stages } }) + @($newlyAdvertised | ForEach-Object { @{ Id = $_; Stages = $Policy.Stages } }))
        foreach ($target in $targets) {
            if ($unadvertised.Contains($target.Id) -or $mentioned.Contains($target.Id)) { continue }
            $additions = Add-QuarantineEntry -Files $files -Stages ([string[]]@($target.Stages)) -Id $target.Id -Justification $justification
            foreach ($item in $additions) { $added.Add($item) }
        }
    }
    $removed = Invoke-QuarantineHousekeeping -Files $files -Chains $Chains
    $changes = [System.Collections.Generic.List[object]]::new()
    $created = [System.Collections.Generic.List[string]]::new()
    foreach ($slug in $files.Keys) {
        $file = $files[$slug]
        $current = (@($file.Rules.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "`n")
        if ($file.Exists -and $current -ceq $before[$slug]) { continue }
        if (-not $file.Exists -and $file.Rules.Count -eq 0) { continue }
        $change = Write-QuarantineFile -Path (Join-Path $root "quarantine.$slug.json") -File $file -Name "quarantine.$slug.json" -WhatIf:$WhatIfPreference -Confirm:$false
        if ($null -ne $change) {
            $changes.Add($change)
            if ($change.Change -eq 'created') { $created.Add($change.File) }
        }
    }
    return [pscustomobject]@{
        PSTypeName = 'Rulebook.QuarantineUpdate'
        Added      = $added.ToArray()
        Removed    = @($removed)
        Created    = $created.ToArray()
        Changes    = $changes.ToArray()
    }
}

Export-ModuleMember -Function @(
    'Add-QuarantineEntry'
    'ConvertFrom-QuarantineFileText'
    'ConvertTo-QuarantineJson'
    'Get-QuarantinePolicy'
    'Invoke-QuarantineHousekeeping'
    'New-QuarantineJustification'
    'Read-QuarantineFile'
    'Update-QuarantineFromScan'
    'Write-QuarantineFile'
)
