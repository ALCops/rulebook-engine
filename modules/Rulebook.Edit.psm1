#requires -Version 7.4
# Rulebook.Edit: changes to overrides.json and the quarantine files as change sets (WP09, WP15, R10, D32, D33, D47,
# D48). Reads and writes overrides.json in the template layout, sets and removes entries and releases quarantined ids
# in memory, applies a change set { version, note?, changes[] } all or nothing on a candidate copy of the repository
# (never the repository itself), regenerates and validates the candidate, works out the effective change per endpoint
# and whether the change is a no-op, renders the table, the pull request body and the job summary, and lands the
# change as a pull request or a direct commit through Rulebook.GitHub. ChangeRule is a one-item client; the issue path
# of the dashboard (WP15) reads the change set from the body of a rulebook-change issue and checks it against
# schemas/rulebook-changeset.schema.json first. Contract: docs/reference/change-mechanics.md.

Set-StrictMode -Version 3.0
Import-Module (Join-Path $PSScriptRoot 'Rulebook.Common.psd1')
Import-Module (Join-Path $PSScriptRoot 'Rulebook.Generate.psd1')
Import-Module (Join-Path $PSScriptRoot 'Rulebook.Validate.psd1')
Import-Module (Join-Path $PSScriptRoot 'Rulebook.Update.psd1')
Import-Module (Join-Path $PSScriptRoot 'Rulebook.GitHub.psd1')
Import-Module (Join-Path $PSScriptRoot 'Rulebook.Action.psd1')
Import-Module (Join-Path $PSScriptRoot 'Rulebook.Quarantine.psd1')

# The change set version this engine applies (the schema's version const).
$script:ChangeSetVersion = 1
$script:ChangeSetSchemaPath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' 'schemas' 'rulebook-changeset.schema.json'))
$script:NoResponse = '_No response_'
# The schema file name; the URL is built at call time from the engine ref (Get-RulebookSchemaUrl, D52).
$script:OverridesSchemaName = 'rulebook-overrides.schema.json'
$script:OverridesFile = 'overrides.json'
$script:Actions = @('Error', 'Warning', 'Info', 'Hidden', 'None')
$script:IdPattern = '^[A-Z]{2,3}\d{4}i?\z'
$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
# A pull request body is limited to 65536 characters; stay below it.
$script:BodyLimit = 60000

#region Internal helpers

function New-ValidationException {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an exception; changes no state')]
    param([Parameter(Mandatory)][string]$Message)
    $exception = [System.InvalidOperationException]::new($Message)
    $exception.Data['Stage'] = 'validation'
    return $exception
}

function New-ChangeFinding {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an object; changes no state')]
    param([AllowNull()][string]$Id, [Parameter(Mandatory)][string]$Message, [AllowNull()][string]$File = $script:OverridesFile)
    return [pscustomobject]@{ PSTypeName = 'Rulebook.Finding'; Rule = 'change'; Severity = 'error'; File = $File; Id = $(if ($Id) { $Id } else { $null }); Message = $Message }
}

function Get-SelectorKey {
    # A selector as a set: distinct values, sorted ordinally, joined. ['strict', 'ci'] and ['ci', 'strict'] are equal.
    param([AllowNull()][AllowEmptyCollection()][string[]]$Values)
    $set = [System.Collections.Generic.SortedSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($value in @($Values)) { if ($null -ne $value) { [void]$set.Add($value) } }
    return (@($set) -join "`u{1F}")
}

function Format-Selector {
    param([AllowNull()][AllowEmptyCollection()][string[]]$Values)
    return (@($Values) -join ', ')
}

function Format-EntryText {
    # 'None (levels: *, stages: ci)', for the remove-miss message.
    param([Parameter(Mandatory)]$Entry)
    return '{0} (levels: {1}, stages: {2})' -f $Entry.Action, (Format-Selector $Entry.Levels), (Format-Selector $Entry.Stages)
}

function Format-ChangeSide {
    # An effective action with its provenance: 'Warning (level:recommended)', 'None (override, "Legacy tables")';
    # the format of the effective diff (Format-DiffSide in Rulebook.Generate).
    param($Action, $Source, $Detail)
    if ($null -eq $Source) { return '(absent)' }
    $actionText = if ($null -ne $Action) { $Action } else { 'unknown' }
    $inner = if ([string]::IsNullOrEmpty($Detail)) { $Source } else { '{0}, "{1}"' -f $Source, $Detail }
    return '{0} ({1})' -f $actionText, $inner
}

function Test-Wildcard {
    param([AllowNull()][AllowEmptyCollection()][string[]]$Values)
    $list = @($Values)
    return $list.Count -eq 1 -and $list[0] -ceq '*'
}

function Get-ExpandedSelector {
    # '*' expands to every slug in settings order; a list of slugs keeps its order.
    param([AllowNull()][AllowEmptyCollection()][string[]]$Values, [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Slugs)
    if (Test-Wildcard $Values) { return , [string[]]$Slugs }
    return , [string[]]@($Values)
}

function ConvertTo-OverrideEntry {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an object; changes no state')]
    param([string]$Id, [string]$Action, [string[]]$Levels, [string[]]$Stages, [AllowNull()][string]$Justification)
    return [pscustomobject]@{
        PSTypeName    = 'Rulebook.OverrideEntry'
        Id            = $Id
        Action        = $Action
        Levels        = [string[]]@($Levels)
        Stages        = [string[]]@($Stages)
        Justification = $(if ([string]::IsNullOrEmpty($Justification)) { $null } else { $Justification })
    }
}

function Assert-Selector {
    param([Parameter(Mandatory)][string]$Name, [AllowNull()][AllowEmptyCollection()][string[]]$Values)
    $list = @($Values | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($list.Count -eq 0) { throw (New-ValidationException "$Name is empty; use a slug from the settings or [`"*`"]") }
    if ($list.Count -gt 1 -and $list -contains '*') { throw (New-ValidationException "$Name mixes '*' with other values; use [`"*`"] alone or a list of slugs") }
}

function Get-RowNote {
    param([Parameter(Mandatory)]$Row, [string]$EntryChange, [bool]$JustificationOnly)
    if (-not $Row.Changed) {
        if ($JustificationOnly) { return 'justification updated' }
        if ($EntryChange -ceq 'deduplicated') { return 'duplicate entries removed' }
        return 'unchanged'
    }
    # Listed before, unlisted after while the id still has an action: the endpoint drops it because the action now
    # equals the analyzer default (an override to the default, or a removed entry falling back to it).
    if ($Row.ListedBefore -and -not $Row.ListedAfter -and $null -ne $Row.After) {
        return 'now unlisted in {0}: {1} equals the analyzer default' -f $Row.Endpoint, $Row.After
    }
    return ''
}

function Get-ItemSentence {
    param([Parameter(Mandatory)]$Item)
    if ($Item.Op -ceq 'release') {
        $released = @($Item.Released)
        if ($released.Count -eq 0) { return "Leaves $($Item.Id) as it is for stages $(Format-Selector $Item.Stages) (no quarantine file of these stages lists it; nothing is written)." }
        $files = @($released | ForEach-Object { "quarantine.$_.json" }) -join ', '
        return "Releases $($Item.Id) from the quarantine of stages $(Format-Selector $released) (removes the entry from $files)."
    }
    $where = 'levels {0}, stages {1}' -f (Format-Selector $Item.Levels), (Format-Selector $Item.Stages)
    $previous = $Item.Entry.Previous
    if ($Item.Op -ceq 'set' -and $Item.NoOp) {
        if ($Item.Entry.Change -ceq 'added') {
            $other = @($Item.Rows | Where-Object { $_.After -cne $Item.Action })
            if ($other.Count -eq 0) { return "Leaves $($Item.Id) at $($Item.Action) for $where (every matching endpoint has that action already; no entry is written)." }
            $same = @($Item.Rows).Count - $other.Count
            return "Leaves $($Item.Id) as it is for $where ($same at $($Item.Action); $($other.Count) decided by a more specific entry or input; no entry is written)."
        }
        return "Leaves $($Item.Id) at $($Item.Action) for $where (the entry is unchanged)."
    }
    if ($Item.Op -ceq 'remove') {
        $was = if ($null -ne $previous) { " (it was $($previous.Action))" } else { '' }
        return "Removes the override entry for $($Item.Id) with $where$was."
    }
    switch ($Item.Entry.Change) {
        'added' { return "Sets $($Item.Id) to $($Item.Action) for $where (adds an entry)." }
        'unchanged' { return "Leaves $($Item.Id) at $($Item.Action) for $where (the entry is unchanged)." }
        'deduplicated' { return "Removes the duplicate entries of $($Item.Id) for $where (the action stays $($Item.Action))." }
        default {
            if ($null -ne $previous -and $previous.Action -ceq $Item.Action) {
                return "Updates the justification of the $($Item.Id) entry for $where (the action stays $($Item.Action))."
            }
            return "Sets $($Item.Id) to $($Item.Action) for $where (replaces the entry that was $($previous.Action))."
        }
    }
}

function Get-ItemNote {
    # The notes under an item's table: the ids that become unlisted, and how many matching endpoints stay the same.
    param([Parameter(Mandatory)]$Item)
    $notes = [System.Collections.Generic.List[string]]::new()
    # A release that frees the id in some stages: the selected stages whose file does not list it (a release that
    # frees nothing says so in its sentence).
    if ($Item.Op -ceq 'release' -and @($Item.Released).Count -gt 0) {
        foreach ($stage in @($Item.Unlisted)) { $notes.Add("$($Item.Id) is not quarantined in $stage; nothing to release there.") }
    }
    foreach ($row in @($Item.Rows | Where-Object { $_.Note -like 'now unlisted in *' })) { $notes.Add("$($row.Id) $($row.Note).") }
    $unchanged = @($Item.Rows | Where-Object { -not $_.Changed }).Count
    $total = @($Item.Rows).Count
    if ($unchanged -gt 0 -and $unchanged -lt $total) { $notes.Add("$unchanged of $total matching endpoints are unchanged.") }
    return , $notes.ToArray()
}

function Get-ItemBlock {
    # One item for the body and the summary: the sentence, the table and its notes.
    param([Parameter(Mandatory)]$Item)
    $text = [System.Text.StringBuilder]::new()
    [void]$text.AppendLine((Get-ItemSentence -Item $Item)).AppendLine()
    [void]$text.Append((ConvertTo-ChangeTable -Rows $Item.Rows)).AppendLine()
    $notes = @($Item.Notes)
    if ($notes.Count -gt 0) {
        foreach ($note in $notes) { [void]$text.AppendLine("- $note") }
        [void]$text.AppendLine()
    }
    return $text.ToString().Replace("`r`n", "`n")
}

function Get-JustificationParagraph {
    param([Parameter(Mandatory)]$Plan)
    # The note of the change set comes first; the justification of a one-item set follows it: the entry's text
    # after the change (given or kept). A change set of removes and releases only has no paragraph unless it carries
    # a note; any other one-item set without either says 'No justification given.' (a set of several items says
    # nothing: the justification of each item is in its own section).
    $items = @($Plan.Items)
    $paragraphs = [System.Collections.Generic.List[string]]::new()
    $note = if ($null -ne $Plan.ChangeSet -and $Plan.ChangeSet.Contains('note')) { [string]$Plan.ChangeSet['note'] } else { '' }
    # One line each (ConvertTo-SingleLine drops the line breaks); what the line says, a leading '#' or a closing
    # keyword included, is the submitter's, who may push to the repository anyway.
    if (-not [string]::IsNullOrWhiteSpace($note)) { $paragraphs.Add((ConvertTo-SingleLine $note)) }
    if ($items.Count -eq 1 -and -not [string]::IsNullOrEmpty($items[0].Justification)) {
        if ($items[0].NoOp -and $items[0].Entry.Change -ceq 'added') {
            $paragraphs.Add("Justification given but not stored (no entry was written): $(ConvertTo-SingleLine $items[0].Justification)")
        } else {
            $paragraphs.Add("Justification: $(ConvertTo-SingleLine $items[0].Justification)")
        }
    }
    if ($paragraphs.Count -gt 0) { return ($paragraphs -join "`n`n") }
    if ($items.Count -gt 0 -and @($items | Where-Object { $_.Op -cnotin 'remove', 'release' }).Count -eq 0) { return '' }
    # A set of several items shows each entry's justification in its own section: no summary sentence.
    if ($items.Count -gt 1) { return '' }
    return 'No justification given.'
}

function Test-ChangeSetVersion {
    # The version of a change set is the number 1: an integer or a whole double from JSON, never a string or a bool.
    # The numeric type codes run from SByte to Decimal; Boolean, Char and DateTime lie outside.
    param($Value)
    if ($null -eq $Value) { return $false }
    $code = [System.Type]::GetTypeCode($Value.GetType())
    if ($code -lt [System.TypeCode]::SByte -or $code -gt [System.TypeCode]::Decimal) { return $false }
    return [double]$Value -eq [double]$script:ChangeSetVersion
}

function Get-FencedBlock {
    # The content of the first fenced code block in -Lines (the CommonMark fence rule of Limit-SummaryText: up to
    # three spaces, three or more backticks or tildes, an info string after it, closed by a line of the same character
    # at least as long and nothing else). An unclosed fence runs to the end; $null when there is no fence.
    param([AllowEmptyCollection()][string[]]$Lines)
    $fence = $null
    $content = [System.Collections.Generic.List[string]]::new()
    foreach ($line in @($Lines)) {
        $marker = [regex]::Match($line, '^[ ]{0,3}(`{3,}|~{3,})')
        if ($null -eq $fence) {
            if ($marker.Success -and -not ($marker.Groups[1].Value[0] -ceq '`' -and $line.Substring($marker.Length).Contains('`'))) { $fence = $marker.Groups[1].Value }
            continue
        }
        if ($marker.Success -and $marker.Groups[1].Value[0] -ceq $fence[0] -and $marker.Groups[1].Value.Length -ge $fence.Length -and $line.Trim() -ceq $marker.Groups[1].Value) {
            return ($content -join "`n")
        }
        $content.Add($line)
    }
    if ($null -eq $fence) { return $null }
    return ($content -join "`n")
}

#endregion

#region overrides.json

function Read-OverridesFile {
    <#
    .SYNOPSIS
    Reads overrides.json: { Schema, Rules (a list of { Id, Action, Levels, Stages, Justification }), Path, Exists }.
    .DESCRIPTION
    A missing file is { Exists $false } with the schema URL and no rules. Strings are read as they are (a justification
    that looks like a date stays text). Throws when the file is not JSON or has no rules array.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'The file is overrides.json')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Path)
    $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $rules = [System.Collections.Generic.List[object]]::new()
    $file = [pscustomobject]@{ PSTypeName = 'Rulebook.OverridesFile'; Schema = (Get-RulebookSchemaUrl -Name $script:OverridesSchemaName); Rules = $rules; Path = $full; Exists = $false }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { return $file }
    $file.Exists = $true
    try {
        # Comments and trailing commas are accepted as ConvertFrom-Json accepts them (Rulebook.Generate reads the
        # same file); the writer drops them.
        $options = [System.Text.Json.JsonDocumentOptions]::new()
        $options.CommentHandling = [System.Text.Json.JsonCommentHandling]::Skip
        $options.AllowTrailingCommas = $true
        $document = [System.Text.Json.JsonDocument]::Parse([System.IO.File]::ReadAllText($full, $script:Utf8NoBom), $options)
    } catch {
        throw "$($script:OverridesFile) is not valid JSON: $($_.Exception.InnerException.Message)"
    }
    try {
        $json = ConvertFrom-JsonElement $document.RootElement
    } finally {
        $document.Dispose()
    }
    if ($json -isnot [System.Collections.IDictionary] -or -not $json.Contains('rules') -or $json['rules'] -isnot [array]) { throw "$($script:OverridesFile) has no rules array" }
    if ($json.Contains('$schema') -and $json['$schema'] -is [string]) { $file.Schema = $json['$schema'] }
    foreach ($rule in $json['rules']) {
        if ($rule -isnot [System.Collections.IDictionary]) { throw "$($script:OverridesFile) has an entry that is not an object" }
        $value = { param([string]$Key) if ($rule.Contains($Key)) { $rule[$Key] } else { $null } }
        $rules.Add((ConvertTo-OverrideEntry -Id ([string](& $value 'id')) -Action ([string](& $value 'action')) -Levels ([string[]]@(& $value 'levels')) -Stages ([string[]]@(& $value 'stages')) -Justification ([string](& $value 'justification'))))
    }
    return $file
}

function ConvertTo-OverridesJson {
    <#
    .SYNOPSIS
    The text of overrides.json in the template layout: $schema, then one entry per line ("rules": [] when empty).
    .DESCRIPTION
    Each entry is { "id", "action", "levels", "stages", "justification" } in that order on one line; justification is
    left out when empty. Two-space indent, LF line ends and one trailing LF, the JSON string escaping of
    ConvertTo-JsonString.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'The file is overrides.json')]
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$File)
    $schema = if ([string]::IsNullOrEmpty($File.Schema)) { Get-RulebookSchemaUrl -Name $script:OverridesSchemaName } else { $File.Schema }
    $array = { param([string[]]$Values) '[' + (@($Values | ForEach-Object { ConvertTo-JsonString $_ }) -join ', ') + ']' }
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('{')
    $lines.Add('  "$schema": ' + (ConvertTo-JsonString $schema) + ',')
    $entries = @($File.Rules)
    if ($entries.Count -eq 0) {
        $lines.Add('  "rules": []')
    } else {
        $lines.Add('  "rules": [')
        for ($i = 0; $i -lt $entries.Count; $i++) {
            $entry = $entries[$i]
            $item = '{ "id": ' + (ConvertTo-JsonString $entry.Id) + ', "action": ' + (ConvertTo-JsonString $entry.Action) + ', "levels": ' + (& $array $entry.Levels) + ', "stages": ' + (& $array $entry.Stages)
            if (-not [string]::IsNullOrEmpty($entry.Justification)) { $item += ', "justification": ' + (ConvertTo-JsonString $entry.Justification) }
            $lines.Add('    ' + $item + ' }' + $(if ($i -lt $entries.Count - 1) { ',' } else { '' }))
        }
        $lines.Add('  ]')
    }
    $lines.Add('}')
    return ($lines -join "`n") + "`n"
}

function Write-OverridesFile {
    <#
    .SYNOPSIS
    Writes overrides.json when the bytes differ: { File, Change (created, modified) } or nothing.
    .DESCRIPTION
    With -WhatIf nothing is written and the change is returned.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'The file is overrides.json')]
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$File, [string]$Name = $script:OverridesFile)
    $Path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $bytes = $script:Utf8NoBom.GetBytes((ConvertTo-OverridesJson -File $File))
    $exists = Test-Path -LiteralPath $Path -PathType Leaf
    if ($exists -and [System.Linq.Enumerable]::SequenceEqual([byte[]][System.IO.File]::ReadAllBytes($Path), [byte[]]$bytes)) { return }
    $change = if ($exists) { 'modified' } else { 'created' }
    if ($PSCmdlet.ShouldProcess($Name, "Write ($change)")) {
        $parent = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) { [void][System.IO.Directory]::CreateDirectory($parent) }
        [System.IO.File]::WriteAllBytes($Path, $bytes)
    } elseif (-not $WhatIfPreference) {
        return
    }
    return [pscustomobject]@{ PSTypeName = 'Rulebook.FileChange'; File = $Name; Change = $change }
}

#endregion

#region Entry operations

function Set-RulebookOverride {
    <#
    .SYNOPSIS
    Sets the override of -Id for a level and stage selection in an overrides file object: { Entry, Change, Previous }.
    .DESCRIPTION
    An entry with the same id and the same level and stage sets (ordinal, order and duplicates ignored) gets the new
    action in place, its selector order kept; a non-empty -Justification replaces the entry's text, an
    empty one keeps it (clearing a justification is a hand edit). Change is replaced, or unchanged when the action is
    the same and the justification is empty or the same already; otherwise the entry is appended (added, with the
    justification when one is given). Previous is a copy of the entry before (or $null). Throws (Data['Stage'] = 'validation') on an
    action outside the five and on an empty selector or one that mixes '*' with slugs. Changes the object passed in;
    writes no file.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Changes the object passed in; writes no file')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]$File,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Levels,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Stages,
        [AllowNull()][AllowEmptyString()][string]$Justification
    )
    if ($Action -cnotin $script:Actions) { throw (New-ValidationException "action '$Action': use Error, Warning, Info, Hidden or None") }
    Assert-Selector -Name 'levels' -Values $Levels
    Assert-Selector -Name 'stages' -Values $Stages
    if ([string]::IsNullOrWhiteSpace($Justification)) { $Justification = '' }
    $levelKey = Get-SelectorKey $Levels
    $stageKey = Get-SelectorKey $Stages
    $hits = [System.Collections.Generic.List[int]]::new()
    for ($i = 0; $i -lt $File.Rules.Count; $i++) {
        $entry = $File.Rules[$i]
        if ($entry.Id -ceq $Id -and (Get-SelectorKey $entry.Levels) -ceq $levelKey -and (Get-SelectorKey $entry.Stages) -ceq $stageKey) { $hits.Add($i) }
    }
    if ($hits.Count -eq 0) {
        $new = ConvertTo-OverrideEntry -Id $Id -Action $Action -Levels $Levels -Stages $Stages -Justification $Justification
        $File.Rules.Add($new)
        return [pscustomobject]@{ Entry = $new; Change = 'added'; Previous = $null }
    }
    # Duplicates a hand edit left are collapsed into the last of them, the effective one (on equal specificity the
    # later entry wins), at its position, so the precedence against other entries stays; it is the Previous.
    $old = $File.Rules[$hits[$hits.Count - 1]]
    $previous = ConvertTo-OverrideEntry -Id $old.Id -Action $old.Action -Levels $old.Levels -Stages $old.Stages -Justification $old.Justification
    for ($k = $hits.Count - 2; $k -ge 0; $k--) { $File.Rules.RemoveAt($hits[$k]) }
    $index = $hits[$hits.Count - 1] - ($hits.Count - 1)
    $first = $File.Rules[$index]
    # An empty justification keeps the entry's text; only a non-empty one replaces it.
    if ([string]::IsNullOrEmpty($Justification)) { $Justification = $old.Justification }
    $same = $old.Action -ceq $Action -and [string]$old.Justification -ceq [string]$Justification
    if ($hits.Count -eq 1 -and $same) {
        return [pscustomobject]@{ Entry = $first; Change = 'unchanged'; Previous = $previous }
    }
    $new = ConvertTo-OverrideEntry -Id $first.Id -Action $Action -Levels $first.Levels -Stages $first.Stages -Justification $Justification
    $File.Rules[$index] = $new
    # Only duplicates went: the effective entry is the same, the file is shorter.
    $change = if ($same) { 'deduplicated' } else { 'replaced' }
    return [pscustomobject]@{ Entry = $new; Change = $change; Previous = $previous }
}

function Remove-RulebookOverride {
    <#
    .SYNOPSIS
    Removes the override entry of -Id with these level and stage sets from an overrides file object: { Entry, Change }.
    .DESCRIPTION
    Selector sets compare as in Set-RulebookOverride; every entry with the same id and sets goes. Change is removed.
    No such entry throws (Data['Stage'] = 'validation') with the entries that exist for the id. Changes the object
    passed in; writes no file.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Changes the object passed in; writes no file')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]$File,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Levels,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Stages
    )
    Assert-Selector -Name 'levels' -Values $Levels
    Assert-Selector -Name 'stages' -Values $Stages
    $levelKey = Get-SelectorKey $Levels
    $stageKey = Get-SelectorKey $Stages
    $removed = $null
    for ($i = $File.Rules.Count - 1; $i -ge 0; $i--) {
        $entry = $File.Rules[$i]
        if ($entry.Id -ceq $Id -and (Get-SelectorKey $entry.Levels) -ceq $levelKey -and (Get-SelectorKey $entry.Stages) -ceq $stageKey) {
            if ($null -eq $removed) { $removed = $entry }
            $File.Rules.RemoveAt($i)
        }
    }
    if ($null -ne $removed) { return [pscustomobject]@{ Entry = $removed; Change = 'removed' } }
    $existing = @($File.Rules | Where-Object { $_.Id -ceq $Id })
    $message = "$($script:OverridesFile) has no entry for $Id"
    if ($existing.Count -gt 0) {
        $message = "$($script:OverridesFile) has no entry for $Id with levels [$(Format-Selector $Levels)] and stages [$(Format-Selector $Stages)]; existing entries for $($Id): $((@($existing | ForEach-Object { Format-EntryText $_ })) -join ', ')"
    }
    throw (New-ValidationException $message)
}

function Remove-RulebookQuarantine {
    <#
    .SYNOPSIS
    Releases -Id from the quarantine files of the -Stages selection: { Removed = @({ Stage, Id, Justification }),
    Unlisted = stage slugs }.
    .DESCRIPTION
    -Files maps every stage slug of the settings, in settings order, to its quarantine file object (Read-QuarantineFile);
    '*' is every key of -Files in that order. A selected stage whose file lists the id loses the entry (Removed, with
    the justification it had); a selected stage whose file does not list it goes to Unlisted, never an error. Throws
    (Data['Stage'] = 'validation') on an empty selector, one that mixes '*' with slugs, and a slug that is not a key
    of -Files, before anything changes. Changes the objects passed in; writes no file (Write-QuarantineFile does).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Changes the objects passed in; writes no file')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Files,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Stages
    )
    Assert-Selector -Name 'stages' -Values $Stages
    $targets = Get-ExpandedSelector $Stages ([string[]]@($Files.Keys))
    foreach ($stage in $targets) {
        if (-not $Files.Contains($stage)) { throw (New-ValidationException "stages names unknown stage '$stage'; use a slug from the settings or [`"*`"]") }
    }
    $removed = [System.Collections.Generic.List[object]]::new()
    $unlisted = [System.Collections.Generic.List[string]]::new()
    foreach ($stage in $targets) {
        $rules = $Files[$stage].Rules
        if ($rules.Contains($Id)) {
            $removed.Add([pscustomobject]@{ Stage = $stage; Id = $Id; Justification = $rules[$Id] })
            $rules.Remove($Id)
        } else {
            $unlisted.Add($stage)
        }
    }
    return [pscustomobject]@{ Removed = $removed.ToArray(); Unlisted = [string[]]$unlisted.ToArray() }
}

#endregion

#region Change set

function ConvertTo-RulebookChangeSet {
    <#
    .SYNOPSIS
    A one-item change set from the ChangeRule form: { version = 1, note?, changes = @({ op, id, action?, levels, stages,
    justification? }) }.
    .DESCRIPTION
    -Action Remove (any case) becomes op remove without an action; a known action is written in its canonical case.
    -Levels and -Stages are '*' or slugs. Validation is Test-RulebookChangeSet.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$RuleId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Action,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][AllowEmptyString()][string[]]$Levels,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][AllowEmptyString()][string[]]$Stages,
        [AllowNull()][AllowEmptyString()][string]$Justification,
        [AllowNull()][AllowEmptyString()][string]$Note
    )
    $change = [ordered]@{}
    if ($Action.Trim() -ieq 'Remove') {
        $change['op'] = 'remove'
        $change['id'] = $RuleId.Trim()
    } else {
        $change['op'] = 'set'
        $change['id'] = $RuleId.Trim()
        $canonical = @($script:Actions | Where-Object { $_ -ieq $Action.Trim() })
        $change['action'] = if ($canonical.Count -eq 1) { $canonical[0] } else { $Action }
    }
    # Trimmed, empty values dropped, repeated slugs once (ordinal, order kept).
    $selector = {
        param([string[]]$Values)
        $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        return , [string[]]@($Values | Where-Object { $null -ne $_ } | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' -and $seen.Add($_) })
    }
    $change['levels'] = & $selector $Levels
    $change['stages'] = & $selector $Stages
    if ($change['op'] -ceq 'set' -and -not [string]::IsNullOrWhiteSpace($Justification)) { $change['justification'] = $Justification.Trim() }
    $set = [ordered]@{}
    $set['version'] = $script:ChangeSetVersion
    if (-not [string]::IsNullOrWhiteSpace($Note)) { $set['note'] = $Note.Trim() }
    $set['changes'] = @(, $change)
    return $set
}

function Test-RulebookChangeSet {
    <#
    .SYNOPSIS
    Checks a change set against the settings and the catalog: findings { Rule 'change', Severity 'error', File, Id, Message }.
    .DESCRIPTION
    A version, when present, is the number 1 (a string "1" is refused, as by the schema's const; an in-memory set
    without one is accepted, the issue path checks the schema first); another version stops the check with that one
    finding. changes is not empty; op is set, remove or release; the id matches ^[A-Z]{2,3}\d{4}i?$ and is in the
    catalog; a set has one of the five actions; levels and stages are ["*"] or slugs of the settings (the wording of
    C10); a release has stages only (levels, an action or a justification on it is a finding) and a remove has no
    action or justification; no two changes have the same op, id, level set and stage set, and no two releases of
    one id name the same stage. An empty list means valid.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$ChangeSet, [Parameter(Mandatory)]$Inputs)
    $findings = [System.Collections.Generic.List[object]]::new()
    if ($ChangeSet.Contains('version') -and -not (Test-ChangeSetVersion $ChangeSet['version'])) {
        $findings.Add((New-ChangeFinding -Message "version '$(ConvertTo-SingleLine ([string]$ChangeSet['version']))' is not supported; this engine applies change sets of version $($script:ChangeSetVersion)"))
        return $findings.ToArray()
    }
    [object[]]$changes = @(if ($ChangeSet.Contains('changes')) { $ChangeSet['changes'] | Where-Object { $null -ne $_ } })
    if ($changes.Count -eq 0) {
        $findings.Add((New-ChangeFinding -Message 'The change set has no changes.'))
        return $findings.ToArray()
    }
    $levelSlugs = [string[]]@($Inputs.Levels | ForEach-Object { $_.Slug })
    $stageSlugs = [string[]]@($Inputs.Stages | ForEach-Object { $_.Slug })
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    # '<id>|<stage>' of every stage an earlier release of the id names.
    $released = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    for ($index = 0; $index -lt $changes.Count; $index++) {
        $change = $changes[$index]
        $value = { param([string]$Key) if ($change -is [System.Collections.IDictionary] -and $change.Contains($Key)) { $change[$Key] } else { $null } }
        $has = { param([string]$Key) $change -is [System.Collections.IDictionary] -and $change.Contains($Key) }
        $op = [string](& $value 'op')
        $id = [string](& $value 'id')
        # 1-based, as a reader counts the changes of the set.
        $label = "change $($index + 1)"
        if ($op -cnotin 'set', 'remove', 'release') {
            $findings.Add((New-ChangeFinding -Id $id -Message "$label`: op '$op' is not supported; use set, remove or release"))
            continue
        }
        if ($id -cnotmatch $script:IdPattern) {
            $findings.Add((New-ChangeFinding -Id $id -Message "'$id' is not a diagnostic id: two or three capital letters, four digits and an optional i, for example LC0015"))
        } elseif (-not $Inputs.Catalog.ContainsKey($id)) {
            $findings.Add((New-ChangeFinding -Id $id -Message "$id is not in catalog/diagnostics.json"))
        }
        if ($op -ceq 'set') {
            $action = [string](& $value 'action')
            if ($action -cnotin $script:Actions) { $findings.Add((New-ChangeFinding -Id $id -Message "action '$action': use Error, Warning, Info, Hidden or None")) }
        }
        $kinds = @(@{ Name = 'levels'; Single = 'level'; Slugs = $levelSlugs }, @{ Name = 'stages'; Single = 'stage'; Slugs = $stageSlugs })
        # The keys an op does not take, as the schema closes each shape: a release frees the id in whole stages (the
        # quarantine files have no levels, no action and no justification); a remove deletes an entry as it is.
        $forbidden = switch ($op) {
            'release' { @{ Names = @('levels', 'action', 'justification'); Why = 'it releases the id from the quarantine of the listed stages' } }
            'remove' { @{ Names = @('action', 'justification'); Why = 'it deletes the override entry with these levels and stages' } }
            default { @{ Names = @(); Why = '' } }
        }
        foreach ($key in $forbidden.Names) {
            if (& $has $key) { $findings.Add((New-ChangeFinding -Id $id -Message "$label`: op '$op' takes no $key; $($forbidden.Why)")) }
        }
        if ($op -ceq 'release') { $kinds = @($kinds[1]) }
        $selectorErrors = $findings.Count
        foreach ($kind in $kinds) {
            $values = @(& $value $kind.Name | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
            if ($values.Count -eq 0) {
                $findings.Add((New-ChangeFinding -Id $id -Message "$label has no $($kind.Name); use a slug from the settings or [`"*`"]"))
            } elseif ($values.Count -gt 1 -and $values -contains '*') {
                $findings.Add((New-ChangeFinding -Id $id -Message "$label mixes '*' with other values in $($kind.Name); use [`"*`"] alone or a list of slugs"))
            } elseif (-not (Test-Wildcard $values)) {
                foreach ($slug in $values) {
                    if ($slug -cnotin $kind.Slugs) { $findings.Add((New-ChangeFinding -Id $id -Message "$label names unknown $($kind.Single) '$slug'; use a slug from the settings or [`"*`"]")) }
                }
            }
        }
        # A release has no level set: its key keeps an empty one.
        $levelKey = if ($op -ceq 'release') { '' } else { Get-SelectorKey ([string[]]@(& $value 'levels')) }
        $key = '{0}|{1}|{2}|{3}' -f $op, $id, $levelKey, (Get-SelectorKey ([string[]]@(& $value 'stages')))
        if (-not $seen.Add($key)) {
            $findings.Add((New-ChangeFinding -Id $id -Message "$label repeats an earlier change (same op, id, levels and stages)"))
        } elseif ($op -ceq 'release' -and $findings.Count -eq $selectorErrors) {
            # Two releases of one id may name different stages (one per stage cell of the cart), never the same stage:
            # the later one would find the id gone and report it as not quarantined.
            $twice = foreach ($stage in (Get-ExpandedSelector ([string[]]@(& $value 'stages')) $stageSlugs)) {
                if (-not $released.Add("$id|$stage")) { $stage }
            }
            $twice = @($twice)
            if ($twice.Count -gt 0) {
                $noun = if ($twice.Count -eq 1) { 'stage' } else { 'stages' }
                $findings.Add((New-ChangeFinding -Id $id -Message "$label`: release $id appears twice for $noun $($twice -join ', ')"))
            }
        }
    }
    return $findings.ToArray()
}

function Invoke-RulebookChangeSet {
    <#
    .SYNOPSIS
    Applies a change set to a candidate copy of the repository and plans the change: a Rulebook.ChangePlan.
    .DESCRIPTION
    Never writes into -RepositoryRoot. Reads the inputs, checks the change set (Test-RulebookChangeSet) and applies
    every operation in memory: set and remove to overrides.json, release to the quarantine.<stage>.json files of every
    stage of the settings (read only when the set has a release; Remove-RulebookQuarantine). A finding, a remove
    without a matching entry or an unreadable quarantine file stops there with Valid $false and Failure validation,
    before anything is copied. Otherwise the repository is copied to <WorkPath>/candidate, overrides.json is written
    there (unless every override entry is unchanged), the quarantine file of every stage a release freed the id in is
    written in the template layout (QuarantineChanges), and every matching endpoint of every item gets a row: the
    effective action before and after with provenance, Changed and a Note (unchanged, justification updated, now
    unlisted, or not quarantined in <stage> for a released stage whose file did not list the id). A release item has
    Levels '*', no Action, Released and Unlisted (stage slugs) and Entry.Change released or unchanged. NoOp is true
    when every item is a no-op (D48): a set that changes no endpoint and whose entry is unchanged or would be new, a
    release that frees the id nowhere; a no-op stops before the regeneration with Changes empty. Otherwise the
    candidate is regenerated and validated (Findings, Valid) and Changes lists every file that differs from the
    repository { File, Change, Bytes }. HeadSha is the checked-out commit (Publish-RulebookChange refuses a base
    branch that moved since).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][System.Collections.IDictionary]$ChangeSet,
        [string]$WorkPath,
        [System.DateTimeOffset]$Now = [System.DateTimeOffset]::UtcNow
    )
    $root = (Resolve-Path -LiteralPath $RepositoryRoot -ErrorAction Stop).ProviderPath
    if ([string]::IsNullOrEmpty($WorkPath)) { $WorkPath = Get-DefaultWorkPath -Prefix 'rulebook-change' }
    $WorkPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($WorkPath)
    $plan = [pscustomobject]@{
        PSTypeName        = 'Rulebook.ChangePlan'
        Root              = $root
        CandidatePath     = $null
        HeadSha           = $null
        Now               = $Now
        ChangeSet         = $ChangeSet
        Items             = @()
        OverridesChange   = $null
        QuarantineChanges = @()
        Changes           = @()
        Findings          = @()
        Valid             = $false
        Failure           = $null
        NoOp              = $false
        Title             = $null
    }
    if (Get-Command git -ErrorAction SilentlyContinue) {
        $head = & git -C $root rev-parse HEAD 2>$null
        if ($LASTEXITCODE -eq 0 -and ([string]$head).Trim() -match '^[0-9a-f]{40}$') { $plan.HeadSha = ([string]$head).Trim() }
    }

    # 1. The inputs and the change set.
    try {
        $before = Read-RulebookInputs -RepositoryRoot $root
        if (-not $before.SettingsPresent) { throw 'Settings missing: .github/Rulebook-Settings.json' }
    } catch {
        $plan.Findings = @(New-ChangeFinding -File $null -Message "The rulebook cannot be read: $($_.Exception.Message)")
        $plan.Failure = 'validation'
        return $plan
    }
    $findings = @(Test-RulebookChangeSet -ChangeSet $ChangeSet -Inputs $before)
    if ($findings.Count -gt 0) {
        $plan.Findings = $findings
        $plan.Failure = 'validation'
        return $plan
    }

    # 2. The operations, in memory.
    $levelSlugs = [string[]]@($before.Levels | ForEach-Object { $_.Slug })
    $stageSlugs = [string[]]@($before.Stages | ForEach-Object { $_.Slug })
    try {
        $file = Read-OverridesFile -Path (Join-Path $root $script:OverridesFile)
    } catch {
        $plan.Findings = @(New-ChangeFinding -Message $_.Exception.Message)
        $plan.Failure = 'validation'
        return $plan
    }
    # A release reads the quarantine file of every stage of the settings, in settings order.
    $quarantine = Get-OrdinalMap
    if (@(@($ChangeSet['changes']) | Where-Object { $_ -is [System.Collections.IDictionary] -and [string]$_['op'] -ceq 'release' }).Count -gt 0) {
        foreach ($slug in $stageSlugs) {
            try {
                $quarantine[$slug] = Read-QuarantineFile -Path (Join-Path $root "quarantine.$slug.json")
            } catch {
                $plan.Findings = @(New-ChangeFinding -File "quarantine.$slug.json" -Message $_.Exception.Message)
                $plan.Failure = 'validation'
                return $plan
            }
        }
    }
    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($change in @($ChangeSet['changes'])) {
        $op = [string]$change['op']
        $item = [pscustomobject]@{
            Op               = $op
            Id               = [string]$change['id']
            Action           = $(if ($op -cne 'release' -and $change.Contains('action')) { [string]$change['action'] } else { $null })
            # A release frees the id in whole stages: its rows cover every level of the selected stages.
            Levels           = $(if ($op -ceq 'release') { [string[]]@('*') } else { [string[]]@($change['levels']) })
            Stages           = [string[]]@($change['stages'])
            Justification    = $(if ($op -cne 'release' -and $change.Contains('justification')) { [string]$change['justification'] } else { $null })
            Entry            = $null
            Released         = [string[]]@()
            Unlisted         = [string[]]@()
            Rows             = @()
            ChangedEndpoints = @()
            NoOp             = $false
            Notes            = @()
        }
        try {
            if ($item.Op -ceq 'release') {
                $result = Remove-RulebookQuarantine -Files $quarantine -Id $item.Id -Stages $item.Stages
                $item.Released = [string[]]@($result.Removed | ForEach-Object { $_.Stage })
                $item.Unlisted = [string[]]@($result.Unlisted)
                $released = if ($item.Released.Count -gt 0) { 'released' } else { 'unchanged' }
                $item.Entry = [pscustomobject]@{ Change = $released; Previous = $null; Entry = $null; Removed = @($result.Removed) }
            } elseif ($item.Op -ceq 'remove') {
                $result = Remove-RulebookOverride -File $file -Id $item.Id -Levels $item.Levels -Stages $item.Stages
                $item.Entry = [pscustomobject]@{ Change = 'removed'; Previous = $result.Entry; Entry = $null }
            } else {
                $result = Set-RulebookOverride -File $file -Id $item.Id -Action $item.Action -Levels $item.Levels -Stages $item.Stages -Justification $item.Justification
                $item.Entry = [pscustomobject]@{ Change = $result.Change; Previous = $result.Previous; Entry = $result.Entry }
                # The justification the entry carries after the change: the given text, or the kept one.
                $item.Justification = $result.Entry.Justification
            }
        } catch {
            $plan.Findings = @(New-ChangeFinding -Id $item.Id -Message $_.Exception.Message)
            $plan.Failure = 'validation'
            return $plan
        }
        $items.Add($item)
    }
    $plan.Items = $items.ToArray()
    $plan.Title = Get-RulebookChangeTitle -Plan $plan

    # 3. The candidate.
    $candidate = Join-Path $WorkPath 'candidate'
    if (Test-Path -LiteralPath $candidate) { Remove-Item -LiteralPath $candidate -Recurse -Force }
    Copy-UpdateTree -Source $root -Destination $candidate
    $plan.CandidatePath = $candidate
    # overrides.json only for an override item that changes its entry: a release alone never rewrites it.
    if (@($items | Where-Object { $_.Op -cne 'release' -and $_.Entry.Change -cne 'unchanged' }).Count -gt 0) {
        $plan.OverridesChange = Write-OverridesFile -Path (Join-Path $candidate $script:OverridesFile) -File $file -WhatIf:$false -Confirm:$false
    }
    # The quarantine file of every stage a release freed the id in, in the template layout (written only when the
    # bytes differ; a file that lists the id exists, so nothing is created).
    $releasedSlugs = [System.Collections.Generic.List[string]]::new()
    foreach ($item in $items) { foreach ($slug in $item.Released) { if (-not $releasedSlugs.Contains($slug)) { $releasedSlugs.Add($slug) } } }
    $quarantineChanges = foreach ($slug in $stageSlugs) {
        if (-not $releasedSlugs.Contains($slug)) { continue }
        Write-QuarantineFile -Path (Join-Path $candidate "quarantine.$slug.json") -File $quarantine[$slug] -Name "quarantine.$slug.json" -WhatIf:$false -Confirm:$false
    }
    $plan.QuarantineChanges = @($quarantineChanges | Where-Object { $null -ne $_ })
    try {
        $after = Read-RulebookInputs -RepositoryRoot $candidate
    } catch {
        $plan.Findings = @(New-ChangeFinding -File $null -Message "The changed rulebook cannot be read: $($_.Exception.Message)")
        $plan.Failure = 'validation'
        return $plan
    }

    # 4. Rows per item and endpoint.
    $computeRows = {
        param($Item, $After)
        $justificationOnly = $Item.Entry.Change -ceq 'replaced' -and $null -ne $Item.Entry.Previous -and $Item.Entry.Previous.Action -ceq $Item.Action
        $rows = [System.Collections.Generic.List[object]]::new()
        foreach ($level in (Get-ExpandedSelector $Item.Levels $levelSlugs)) {
            foreach ($stage in (Get-ExpandedSelector $Item.Stages $stageSlugs)) {
                $b = Get-EffectiveAction -Inputs $before -Id $Item.Id -Level $level -Stage $stage
                $a = Get-EffectiveAction -Inputs $After -Id $Item.Id -Level $level -Stage $stage
                $row = [pscustomobject]@{
                    PSTypeName   = 'Rulebook.ChangeRow'
                    Endpoint     = "$level.$stage"
                    File         = 'rulesets/' + (Get-EndpointFileName -Level $level -Stage $stage)
                    Id           = $Item.Id
                    Before       = $b.Action
                    After        = $a.Action
                    BeforeSource = $b.Source
                    AfterSource  = $a.Source
                    BeforeDetail = $b.Detail
                    AfterDetail  = $a.Detail
                    ListedBefore = [bool]$b.Listed
                    ListedAfter  = [bool]$a.Listed
                    Changed      = ($b.Action -cne $a.Action) -or ([bool]$b.Listed -ne [bool]$a.Listed)
                    Note         = $null
                }
                $row.Note = if ($Item.Op -ceq 'release' -and $stage -cin $Item.Unlisted) { "not quarantined in $stage" } else { Get-RowNote -Row $row -EntryChange $Item.Entry.Change -JustificationOnly $justificationOnly }
                $rows.Add($row)
            }
        }
        $Item.Rows = $rows.ToArray()
        $Item.ChangedEndpoints = [string[]]@($rows | Where-Object Changed | ForEach-Object Endpoint)
        # D48: a set that changes no endpoint is a no-op when the entry is unchanged or would be new (a dead entry
        # that only repeats what the base gives is not written); a replaced or deduplicated entry is written. A
        # release is a no-op when no selected quarantine file lists the id; one that frees it is written, also when
        # an override or a level decides every endpoint and none changes.
        $Item.NoOp = ($Item.Op -ceq 'set' -and $Item.ChangedEndpoints.Count -eq 0 -and $Item.Entry.Change -cin 'unchanged', 'added') -or
        ($Item.Op -ceq 'release' -and @($Item.Released).Count -eq 0)
        $Item.Notes = Get-ItemNote -Item $Item
    }
    foreach ($item in $items) { & $computeRows $item $after }

    # A dead new entry is never written, also when another item of the set changes something: drop it, write the
    # file again and recompute the other items, whose effective actions the dropped entry could have masked.
    $dead = @($items | Where-Object { $_.NoOp -and $_.Entry.Change -ceq 'added' })
    if ($dead.Count -gt 0) {
        foreach ($item in $dead) { [void]$file.Rules.Remove($item.Entry.Entry) }
        $overridesPath = Join-Path $candidate $script:OverridesFile
        $live = @($items | Where-Object { $_.Op -cne 'release' -and $_.Entry.Change -cne 'unchanged' -and $dead -notcontains $_ })
        if ($live.Count -gt 0) {
            $plan.OverridesChange = Write-OverridesFile -Path $overridesPath -File $file -WhatIf:$false -Confirm:$false
        } else {
            # Only dead entries touched overrides.json (next to a release): the file of the repository stays as it
            # was, not rewritten in the template layout.
            $original = Join-Path $root $script:OverridesFile
            if (Test-Path -LiteralPath $original -PathType Leaf) {
                Copy-Item -LiteralPath $original -Destination $overridesPath -Force
            } elseif (Test-Path -LiteralPath $overridesPath -PathType Leaf) {
                Remove-Item -LiteralPath $overridesPath -Force
            }
            $plan.OverridesChange = $null
        }
        try {
            $after = Read-RulebookInputs -RepositoryRoot $candidate
        } catch {
            $plan.Findings = @(New-ChangeFinding -File $null -Message "The changed rulebook cannot be read: $($_.Exception.Message)")
            $plan.Failure = 'validation'
            return $plan
        }
        # Every item against the final state, so the rows of a dead entry show what really decides each endpoint;
        # a dead entry stays a no-op.
        foreach ($item in $items) { & $computeRows $item $after }
        foreach ($item in $dead) { $item.NoOp = $true }
    }
    $plan.NoOp = @($items | Where-Object { -not $_.NoOp }).Count -eq 0
    if ($plan.NoOp) {
        $plan.OverridesChange = $null
        $plan.Valid = $true
        return $plan
    }

    # 5. Regenerate and validate the candidate.
    $all = [System.Collections.Generic.List[object]]::new()
    try {
        $null = Update-RulebookEndpoints -RepositoryRoot $candidate -WhatIf:$false -Confirm:$false
    } catch {
        $all.Add((New-ChangeFinding -File $null -Message "The changed rulebook cannot be regenerated: $($_.Exception.Message)"))
    }
    foreach ($finding in @(Test-Rulebook -RepositoryRoot $candidate)) { $all.Add($finding) }
    $plan.Findings = $all.ToArray()
    $plan.Valid = @($all | Where-Object Severity -EQ 'error').Count -eq 0
    if (-not $plan.Valid) { $plan.Failure = 'validation' }

    # 6. The files that differ from the repository.
    [string[]]$rootFiles = @(Get-TreeFile -Root $root)
    [string[]]$candidateFiles = @(Get-TreeFile -Root $candidate)
    $rootSet = [System.Collections.Generic.HashSet[string]]::new($rootFiles, [System.StringComparer]::Ordinal)
    $candidateSet = [System.Collections.Generic.HashSet[string]]::new($candidateFiles, [System.StringComparer]::Ordinal)
    $union = [System.Collections.Generic.SortedSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($path in @($rootFiles) + @($candidateFiles)) { [void]$union.Add($path) }
    $changes = foreach ($path in $union) {
        $change = $null
        if (-not $rootSet.Contains($path)) { $change = 'created' }
        elseif (-not $candidateSet.Contains($path)) { $change = 'deleted' }
        elseif ((Get-ComparableContent -Root $root -Path $path) -cne (Get-ComparableContent -Root $candidate -Path $path)) { $change = 'modified' }
        if ($null -eq $change) { continue }
        $bytes = if ($change -eq 'deleted') { $null } else { [System.IO.File]::ReadAllBytes((Join-Path $candidate $path)) }
        [pscustomobject]@{ File = $path; Change = $change; Bytes = $bytes }
    }
    $plan.Changes = @($changes)
    return $plan
}

#endregion

#region Rendering

function Get-RulebookChangeTitle {
    <#
    .SYNOPSIS
    The commit and pull request title of a change plan.
    .DESCRIPTION
    One item: 'Change LC0015 to None (levels: strict, stages: ci)', 'Remove override for LC0015 (levels: strict,
    stages: ci)' or 'Release LC0099 from quarantine (stages: ci)'. Several items: 'Rulebook change: <n> changes'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Plan)
    $items = @($Plan.Items)
    if ($items.Count -ne 1) { return "Rulebook change: $($items.Count) changes" }
    $item = $items[0]
    if ($item.Op -ceq 'release') { return "Release $($item.Id) from quarantine (stages: $(Format-Selector $item.Stages))" }
    $where = '(levels: {0}, stages: {1})' -f (Format-Selector $item.Levels), (Format-Selector $item.Stages)
    if ($item.Op -ceq 'remove') { return "Remove override for $($item.Id) $where" }
    return "Change $($item.Id) to $($item.Action) $where"
}

function ConvertTo-ChangeTable {
    <#
    .SYNOPSIS
    | Endpoint | Before | After | Note |: one row per matching endpoint, the effective action with its provenance.
    .DESCRIPTION
    A side reads 'Warning (level:recommended)' or 'None (override, "Legacy tables")', the provenance format of the
    effective diff. Free text goes through Format-TableCell.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyCollection()][object[]]$Rows)
    $text = [System.Text.StringBuilder]::new()
    [void]$text.AppendLine('| Endpoint | Before | After | Note |').AppendLine('|---|---|---|---|')
    foreach ($row in @($Rows)) {
        $before = Format-ChangeSide $row.Before $row.BeforeSource $row.BeforeDetail
        $after = Format-ChangeSide $row.After $row.AfterSource $row.AfterDetail
        [void]$text.AppendLine(('| {0} | {1} | {2} | {3} |' -f (Format-TableCell $row.Endpoint), (Format-TableCell $before), (Format-TableCell $after), (Format-TableCell $row.Note)))
    }
    return $text.ToString().Replace("`r`n", "`n")
}

function ConvertTo-ChangePullRequestBody {
    <#
    .SYNOPSIS
    The pull request body of a change: the note and the justification, then per item one sentence, its table and its
    notes.
    .DESCRIPTION
    The opening paragraphs are the note of the change set (on one line), then 'Justification: <text>' for a one-item
    set whose entry has a justification (given or kept); without either, nothing for a change set of removes and
    releases only or of several items, else 'No justification given.'. Above -Limit (default 60000 characters, GitHub allows 65536) the
    item tables are left out from the end with one italic line; only when that is not enough is the body cut at a line
    boundary. -BodyPrefix opens the body and -BodySuffix (the 'Closes #<n>' line of the issue path) ends it, each
    separated by a blank line. Their length is taken from -Limit first, but they are never shortened: -Limit bounds
    the generated part between them, so the suffix is never cut, and a caller keeps both short (a prefix longer than
    -Limit makes the body longer than -Limit).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]$Plan,
        [int]$Limit = $script:BodyLimit,
        [AllowNull()][AllowEmptyString()][string]$BodyPrefix,
        [AllowNull()][AllowEmptyString()][string]$BodySuffix
    )
    $head = if ([string]::IsNullOrWhiteSpace($BodyPrefix)) { '' } else { $BodyPrefix.Replace("`r`n", "`n").Trim("`n") + "`n`n" }
    $foot = if ([string]::IsNullOrWhiteSpace($BodySuffix)) { '' } else { "`n" + $BodySuffix.Replace("`r`n", "`n").Trim("`n") + "`n" }
    $generated = ConvertTo-GeneratedChangeBody -Plan $Plan -Limit ([math]::Max(0, $Limit - $head.Length - $foot.Length))
    return $head + $generated + $foot
}

function ConvertTo-GeneratedChangeBody {
    # The generated part of the pull request body (ConvertTo-ChangePullRequestBody), kept below -Limit.
    param([Parameter(Mandatory)]$Plan, [Parameter(Mandatory)][int]$Limit)
    $paragraph = Get-JustificationParagraph -Plan $Plan
    $intro = if ($paragraph) { $paragraph + "`n`n" } else { '' }
    $items = @($Plan.Items)
    [string[]]$blocks = @($items | ForEach-Object { Get-ItemBlock -Item $_ })
    [string[]]$short = @($items | ForEach-Object { (Get-ItemSentence -Item $_) + "`n`n" })
    $build = {
        param([int]$Full, [string]$Dropped)
        $parts = for ($i = 0; $i -lt $blocks.Count; $i++) { if ($i -lt $Full) { $blocks[$i] } else { $short[$i] } }
        $text = $intro + (@($parts) -join '')
        $text = $text.Replace("`r`n", "`n").TrimEnd("`n") + "`n"
        if ($Dropped) { $text += "`n$Dropped`n" }
        return $text
    }
    $body = & $build $blocks.Count $null
    if ($body.Length -le $Limit) { return $body }
    for ($count = $blocks.Count - 1; $count -ge 0; $count--) {
        $dropped = "_$($blocks.Count - $count) of $($blocks.Count) change tables were left out to keep this body below the GitHub limit; the job summary of the change run has them all._"
        $body = & $build $count $dropped
        if ($body.Length -le $Limit) { return $body }
    }
    $tail = "`n_The body was cut at a line boundary to stay below the GitHub limit; the job summary of the change run has the full tables._`n"
    $cut = $body.LastIndexOf("`n", [math]::Max(0, $Limit - $tail.Length - 1), [System.StringComparison]::Ordinal)
    if ($cut -lt 0) { $cut = 0 }
    return $body.Substring(0, $cut + 1) + $tail
}

function ConvertTo-ChangeSummary {
    <#
    .SYNOPSIS
    The job summary of a change: '## <Heading>' (default 'Rule change'), the message, the result, the item tables,
    validation errors and the effective diff.
    .DESCRIPTION
    The effective diff ('## Effective diff', one table per endpoint) is the git-based diff of the pushed commit
    against the cloned head (-Result.Diff, or -Result.DiffNote when it could not be computed); it appears only here,
    never in the pull request body (decision 14). The issue path passes -Heading 'Rulebook change (#<n>)'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]$Plan,
        $Result,
        [AllowNull()][AllowEmptyString()][string]$Message,
        [ValidateNotNullOrEmpty()][string]$Heading = 'Rule change'
    )
    $text = [System.Text.StringBuilder]::new()
    [void]$text.AppendLine("## $(ConvertTo-SingleLine $Heading)").AppendLine()
    if ($Message) { [void]$text.AppendLine((ConvertTo-SingleLine $Message)).AppendLine() }
    if ($null -ne $Result) {
        $line = switch ([string]$Result.Result) {
            'pull-request' { "Pull request: $($Result.PullRequestUrl) (branch ``$($Result.Branch)``)" + $(if ($Result.Fallback) { '; the direct commit was refused' } else { '' }) }
            'direct-commit' { "Committed to ``$($Result.Branch)`` ($(Get-ShortSha $Result.Sha))" }
            default { $null }
        }
        if ($line) { [void]$text.AppendLine($line).AppendLine() }
    }
    if (@($Plan.Items).Count -gt 0) {
        $paragraph = Get-JustificationParagraph -Plan $Plan
        if ($paragraph) { [void]$text.AppendLine($paragraph).AppendLine() }
        foreach ($item in @($Plan.Items)) { [void]$text.Append((Get-ItemBlock -Item $item)) }
    }
    $errors = @($Plan.Findings | Where-Object Severity -EQ 'error')
    if ($errors.Count -gt 0) {
        [void]$text.AppendLine('## Validation errors').AppendLine()
        [void]$text.AppendLine('| Rule | File | Id | Message |').AppendLine('|---|---|---|---|')
        foreach ($finding in $errors) {
            $file = if ($finding.File) { '`' + $finding.File + '`' } else { '' }
            [void]$text.AppendLine(('| {0} | {1} | {2} | {3} |' -f $finding.Rule, $file, (Format-TableCell $finding.Id), (Format-TableCell $finding.Message)))
        }
        [void]$text.AppendLine()
    }
    if ($null -ne $Result) {
        $note = if ($Result.PSObject.Properties['DiffNote']) { $Result.DiffNote } else { $null }
        # @() around the if: an if expression unrolls an empty array to $null.
        $diff = @(if ($Result.PSObject.Properties['Diff']) { $Result.Diff })
        if ($note) {
            [void]$text.AppendLine('## Effective diff').AppendLine().AppendLine($note).AppendLine()
        } elseif ($diff.Count -gt 0) {
            [void]$text.AppendLine('## Effective diff').AppendLine()
            # Get-EffectiveDiffBlock returns its array with a comma; @() around it would nest it.
            $blocks = Get-EffectiveDiffBlock -Diff $diff
            [void]$text.Append(($blocks -join ''))
        }
    }
    return $text.ToString().Replace("`r`n", "`n")
}

function ConvertTo-ChangeItemList {
    <#
    .SYNOPSIS
    One Markdown list line '- <sentence>' per item of a change plan, for the no-op comment of the issue path.
    .DESCRIPTION
    The sentence of each item as in the pull request body ('Leaves LC0015 at None for levels strict, stages ci (...).'),
    LF line ends and one trailing LF; '' for a plan without items.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Plan)
    $lines = @(@($Plan.Items) | ForEach-Object { '- ' + (ConvertTo-SingleLine (Get-ItemSentence -Item $_)) })
    if ($lines.Count -eq 0) { return '' }
    return ($lines -join "`n") + "`n"
}

#endregion

#region Issue body

function ConvertFrom-RulebookIssueBody {
    <#
    .SYNOPSIS
    The change set text and the note of a rulebook-change issue body: { ChangesText, Note, Errors }.
    .DESCRIPTION
    The body as GitHub renders the issue form: one '### <label>' section per field. CRLF becomes LF; a $null body is
    ''. Sections split at a line '### <label>' (trailing blanks ignored; other heading levels do not split); text above
    the first one is ignored. ChangesText is the content of the first fenced code block (``` or ~~~, info string
    optional, an unclosed fence runs to the end of the section) in the first section headed exactly 'Changes', or the
    section text itself when it has no fence, trimmed. Note is the first section headed 'Note', trimmed; GitHub's
    '_No response_' for an empty field and an absent section are ''. Errors lists a missing Changes section and an empty
    Changes field; every other section and every later code block is ignored. Returns data, never throws.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([AllowNull()][AllowEmptyString()][string]$Body)
    $errors = [System.Collections.Generic.List[string]]::new()
    # A [string] parameter is never $null: an absent body arrives as ''.
    $text = $Body.Replace("`r`n", "`n").Replace("`r", "`n")
    $sections = [System.Collections.Generic.List[object]]::new()
    $current = $null
    foreach ($line in $text.Split("`n")) {
        # A prefix test and a trim, not a regex: a lazy group before trailing blanks is quadratic on a long line.
        $heading = if ($line.StartsWith('### ', [System.StringComparison]::Ordinal)) { $line.Substring(4).TrimEnd() } else { '' }
        if ($heading -ne '') {
            $current = [pscustomobject]@{ Heading = $heading; Lines = [System.Collections.Generic.List[string]]::new() }
            $sections.Add($current)
        } elseif ($null -ne $current) {
            $current.Lines.Add($line)
        }
    }
    $changes = @($sections | Where-Object { $_.Heading -ceq 'Changes' } | Select-Object -First 1)
    $changesText = ''
    if ($changes.Count -eq 0) {
        $errors.Add('The issue body has no "### Changes" section; submit the Rulebook change form from the dashboard, or add the section with the change set in a json code block.')
    } else {
        $lines = [string[]]$changes[0].Lines.ToArray()
        $block = Get-FencedBlock -Lines $lines
        $changesText = if ($null -ne $block) { $block.Trim() } else { ($lines -join "`n").Trim() }
        if ($changesText -eq '' -or $changesText -ceq $script:NoResponse) {
            $changesText = ''
            $errors.Add('The Changes field is empty.')
        }
    }
    $note = ''
    $noteSection = @($sections | Where-Object { $_.Heading -ceq 'Note' } | Select-Object -First 1)
    if ($noteSection.Count -gt 0) {
        $note = ($noteSection[0].Lines -join "`n").Trim()
        if ($note -ceq $script:NoResponse) { $note = '' }
    }
    return [pscustomobject]@{ PSTypeName = 'Rulebook.IssueBody'; ChangesText = $changesText; Note = $note; Errors = [string[]]$errors.ToArray() }
}

function Read-RulebookChangeSetText {
    <#
    .SYNOPSIS
    Parses and checks change set JSON against the change set schema: { ChangeSet, Errors }.
    .DESCRIPTION
    Strict JSON (System.Text.Json: no comments, no trailing commas); a syntax error is one error 'The change set is not
    valid JSON (line <l>, byte position <p>): <reason>' (both 1-based; the position counts UTF-8 bytes). Then
    Test-RulebookSchema of Rulebook.Common (JsonSchema.Net, D56) against -SchemaPath (default
    schemas/rulebook-changeset.schema.json of the engine): every distinct schema error is one line 'The change set does
    not match the schema: <error> at <JSON pointer>', in evaluation order, a failing parent before its children (a
    change that matches none of the set, remove and release shapes gives 'Expected 1 matching subschema but found 0
    at /changes/<n>', then what each shape missed); a property name repeated in one object gives the line 'The change
    set does not match the schema: the text is not valid JSON: the property name '<name>' is repeated at <pointer>'.
    A schema that cannot be read or resolved gives the one line 'The change set cannot be checked against the schema:
    <reason>'. Only a text without errors gets a ChangeSet: ordered dictionaries with ordinal keys, arrays, and
    strings kept as strings (a justification that looks like a date stays text). The catalog, the slugs and repeated changes are checked by Test-RulebookChangeSet.
    Returns data, never throws.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()][AllowEmptyString()][string]$Text,
        [string]$SchemaPath = $script:ChangeSetSchemaPath
    )
    $result = [pscustomobject]@{ PSTypeName = 'Rulebook.ChangeSetText'; ChangeSet = $null; Errors = [string[]]@() }
    $prefix = 'The change set does not match the schema: '
    if ([string]::IsNullOrWhiteSpace($Text)) {
        $result.Errors = [string[]]@('The change set is empty.')
        return $result
    }
    $document = $null
    try {
        $document = [System.Text.Json.JsonDocument]::Parse($Text)
    } catch {
        $exception = $_.Exception
        while ($null -ne $exception -and $exception -isnot [System.Text.Json.JsonException]) { $exception = $exception.InnerException }
        if ($null -ne $exception -and $null -ne $exception.LineNumber) {
            $reason = ($exception.Message -replace '\s*LineNumber: \d+ \| BytePositionInLine: \d+\.\s*\z', '').Trim()
            $result.Errors = [string[]]@("The change set is not valid JSON (line $($exception.LineNumber + 1), byte position $($exception.BytePositionInLine + 1)): $(ConvertTo-SingleLine $reason)")
        } else {
            $message = if ($null -ne $exception) { $exception.Message } else { $_.Exception.Message }
            $result.Errors = [string[]]@("The change set is not valid JSON: $(ConvertTo-SingleLine $message)")
        }
        return $result
    }
    try {
        try {
            $check = Test-RulebookSchema -Json $Text -SchemaPath $SchemaPath
        } catch {
            $result.Errors = [string[]]@("The change set cannot be checked against the schema: $(ConvertTo-SingleLine $_.Exception.Message)")
            return $result
        }
        if (-not $check.IsValid) {
            $result.Errors = [string[]]@($check.Errors | ForEach-Object { $prefix + (ConvertTo-SingleLine $_) })
            return $result
        }
        $result.ChangeSet = ConvertFrom-JsonElement $document.RootElement
    } finally {
        $document.Dispose()
    }
    return $result
}

#endregion

#region Publishing

function Publish-RulebookChange {
    <#
    .SYNOPSIS
    Applies a valid change plan to a fresh clone and opens the pull request (or pushes the direct commit).
    .DESCRIPTION
    Refuses an invalid plan and a no-op plan. Clones -RemoteUrl (default <GITHUB_SERVER_URL>/<Repository>) at
    -BaseBranch; a plan that recorded the head of its checkout (HeadSha) refuses a base branch that moved since (stage
    push, Data['Reason'] = 'base-moved'). Writes the plan's changes, commits with the title (-Title, default
    Get-RulebookChangeTitle; the commit message is the title alone, never a closing keyword) and pushes <BranchPrefix>/<yyMMddHHmmss UTC> (-Now), or -BaseBranch with -DirectCommit, falling back to the new
    branch when the push is refused (D47). Diff is the effective diff of the commit against the cloned head. Opens
    the pull request with the same title, -Labels and the body of ConvertTo-ChangePullRequestBody with -BodyPrefix and
    -BodySuffix (the suffix is added after the body limit is applied to the generated part, so it is never cut).
    Returns { Result (pull-request,
    direct-commit, no-changes), PullRequestUrl, Number, Branch, Sha, Fallback, FallbackReason (the git output of a
    refused direct push, else $null), Diff, DiffNote, Body (the pull request body sent, $null without a pull
    request), Title }. A failure throws with Data['Stage']: push for the
    clone, commit and push; pull-request for the opening, naming the pushed branch and its tree link (Data['Branch'],
    and after a refused direct push Data['FallbackReason'], also on the push stage when the fallback branch failed).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][string]$Repository,
        [string]$RepositoryRoot,
        [string]$RemoteUrl,
        [AllowNull()][AllowEmptyString()][string]$Token,
        [Parameter(Mandatory)][string]$BaseBranch,
        [Parameter(Mandatory)][string]$BranchPrefix,
        [switch]$DirectCommit,
        [AllowNull()][AllowEmptyString()][string]$Actor,
        [AllowNull()][AllowEmptyCollection()][string[]]$Labels,
        [string]$WorkPath,
        [AllowNull()][AllowEmptyString()][string]$ApiUrl,
        [AllowNull()][AllowEmptyString()][string]$Title,
        [AllowNull()][AllowEmptyString()][string]$BodyPrefix,
        [AllowNull()][AllowEmptyString()][string]$BodySuffix,
        [System.DateTimeOffset]$Now = [System.DateTimeOffset]::UtcNow
    )
    if (-not $Plan.Valid -or $Plan.Failure) { throw 'The change plan does not validate; nothing is pushed.' }
    if ($Plan.NoOp) { throw 'The change is a no-op; nothing is pushed.' }
    if ([string]::IsNullOrEmpty($WorkPath)) { $WorkPath = Get-DefaultWorkPath -Prefix 'rulebook-change' }
    $server = if ($env:GITHUB_SERVER_URL) { $env:GITHUB_SERVER_URL.TrimEnd('/') } else { 'https://github.com' }
    if ([string]::IsNullOrEmpty($RemoteUrl)) { $RemoteUrl = "$server/$Repository" }
    # A name of its own: PowerShell variables are case-insensitive, and -Title is a parameter.
    $commitTitle = if ([string]::IsNullOrWhiteSpace($Title)) { Get-RulebookChangeTitle -Plan $Plan } else { ConvertTo-SingleLine $Title.Trim() }
    $branch = '{0}/{1}' -f $BranchPrefix.TrimEnd('/'), $Now.UtcDateTime.ToString('yyMMddHHmmss', [System.Globalization.CultureInfo]::InvariantCulture)

    # The rulebook may sit in a folder of a bigger repository; the plan's paths are relative to that folder.
    $prefix = ''
    $gitRoot = if ($RepositoryRoot) { $RepositoryRoot } else { $Plan.Root }
    if ($gitRoot -and (Get-Command git -ErrorAction SilentlyContinue)) {
        $show = & git -C $gitRoot rev-parse --show-prefix 2>$null
        if ($LASTEXITCODE -eq 0 -and $show) { $prefix = ([string]$show).Trim() }
    }
    try {
        $clone = New-GitHubClone -RemoteUrl $RemoteUrl -Branch $BaseBranch -Path (Join-Path $WorkPath 'clone') -Token $Token -Actor $Actor
        $planned = [string]$Plan.HeadSha
        if ($planned -and $planned -cne $clone.BaseSha) {
            $moved = [System.InvalidOperationException]::new("The base branch moved since the change was planned ($BaseBranch $(Get-ShortSha $planned) is now $(Get-ShortSha $clone.BaseSha)); nothing was pushed. Run the workflow again.")
            $moved.Data['Reason'] = 'base-moved'
            throw $moved
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
        $pushed = Publish-GitHubChange -Clone $clone -Message $commitTitle -NewBranch $branch -DirectCommit:$DirectCommit
    } catch {
        $exception = [System.InvalidOperationException]::new($_.Exception.Message, $_.Exception)
        $exception.Data['Stage'] = 'push'
        if ($_.Exception.Data['Reason']) { $exception.Data['Reason'] = $_.Exception.Data['Reason'] }
        # A refused direct push whose fallback branch failed too (#77).
        if ($_.Exception.Data.Contains('FallbackReason')) { $exception.Data['FallbackReason'] = $_.Exception.Data['FallbackReason'] }
        throw $exception
    }
    $result = [pscustomobject]@{ Result = $null; PullRequestUrl = $null; Number = $null; Branch = $pushed.Branch; Sha = $pushed.Sha; Fallback = [bool]$pushed.Fallback; FallbackReason = $pushed.FallbackReason; Diff = @(); DiffNote = $null; Body = $null; Title = $commitTitle }
    if (-not $pushed.Pushed) {
        $result.Result = 'no-changes'
        return $result
    }
    try {
        $result.Diff = @(Compare-RulebookEndpoints -RepositoryRoot $rulebookRoot -Ref $clone.BaseSha)
    } catch {
        $result.DiffNote = "The effective diff could not be computed: $($_.Exception.Message)"
    }
    if ($pushed.Direct) {
        $result.Result = 'direct-commit'
        return $result
    }
    # The branch is pushed from here on: a failure names it, so the pull request can be opened by hand.
    try {
        $body = ConvertTo-ChangePullRequestBody -Plan $Plan -BodyPrefix $BodyPrefix -BodySuffix $BodySuffix
        $result.Body = $body
        $pull = New-GitHubPullRequest -Repository $Repository -Token $Token -Title $commitTitle -Body $body -Head $pushed.Branch -Base $BaseBranch -Labels $Labels -ApiUrl $ApiUrl -ServerUrl $server
    } catch {
        $segments = @(foreach ($part in @($Repository.Split('/')) + @('tree') + @($pushed.Branch.Split('/'))) { [System.Uri]::EscapeDataString($part) })
        $link = "$server/$($segments -join '/')"
        $message = "Branch $($pushed.Branch) was pushed. $($_.Exception.Message)"
        if (-not $message.Contains($link)) { $message += " Open the pull request by hand: $link" }
        $exception = [System.InvalidOperationException]::new($message, $_.Exception)
        $exception.Data['Stage'] = 'pull-request'
        $exception.Data['Branch'] = $pushed.Branch
        # The refused direct push is reported even when the pull request then fails (#77).
        if ($pushed.Fallback) { $exception.Data['FallbackReason'] = $pushed.FallbackReason }
        throw $exception
    }
    $result.Result = 'pull-request'
    $result.PullRequestUrl = $pull.Url
    $result.Number = $pull.Number
    return $result
}

#endregion

Export-ModuleMember -Function @(
    'ConvertFrom-RulebookIssueBody'
    'ConvertTo-ChangeItemList'
    'ConvertTo-ChangePullRequestBody'
    'ConvertTo-ChangeSummary'
    'ConvertTo-ChangeTable'
    'ConvertTo-OverridesJson'
    'ConvertTo-RulebookChangeSet'
    'Get-RulebookChangeTitle'
    'Invoke-RulebookChangeSet'
    'Publish-RulebookChange'
    'Read-OverridesFile'
    'Read-RulebookChangeSetText'
    'Remove-RulebookOverride'
    'Remove-RulebookQuarantine'
    'Set-RulebookOverride'
    'Test-RulebookChangeSet'
    'Write-OverridesFile'
)
