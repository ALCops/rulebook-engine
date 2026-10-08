#requires -Version 7.4
# Rulebook.Action: the helpers the entry scripts under actions/ share (#58). Workflow command escaping and the
# annotation lines, the run context (annotations, error messages, the first failure kind), the job summary and
# GITHUB_OUTPUT writers, path resolution against the PowerShell location, and the Markdown helpers for summaries and
# pull request bodies (Format-TableCell, ConvertTo-SingleLine, Limit-SummaryText). A leaf module: it imports no other
# engine module, so every module and entry script can import it.

Set-StrictMode -Version 3.0

function Format-AnnotationText {
    <#
    .SYNOPSIS
    Workflow command escaping: the message part escapes %, CR and LF; a property value (-Property) also : and ,.
    .DESCRIPTION
    $null comes back as ''.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowNull()][AllowEmptyString()][string]$Text, [switch]$Property)
    if ($null -eq $Text) { return '' }
    $escaped = $Text.Replace('%', '%25').Replace("`r", '%0D').Replace("`n", '%0A')
    if ($Property) { $escaped = $escaped.Replace(':', '%3A').Replace(',', '%2C') }
    return $escaped
}

function ConvertTo-SingleLine {
    <#
    .SYNOPSIS
    A message on one Markdown line (list item or paragraph): CR and LF become spaces; no table escaping.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowNull()][AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    return $Text.Replace("`r", ' ').Replace("`n", ' ')
}

function Format-TableCell {
    <#
    .SYNOPSIS
    Text for a Markdown table cell: | escaped, CR and LF become spaces.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowNull()][AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    return $Text.Replace('|', '\|').Replace("`r", ' ').Replace("`n", ' ')
}

function New-ActionContext {
    <#
    .SYNOPSIS
    The run context of an entry script: { Title, Annotations, ErrorMessages, Failure }.
    .DESCRIPTION
    Title is the default annotation title (the action name). Annotations collects every workflow command line
    Add-Annotation writes, ErrorMessages the message of every error annotation (unescaped), and Failure holds the
    first failure kind Add-Failure records ($null until then). Publish lists ErrorMessages in its failure summary.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an object; changes no state')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Title)
    return [pscustomobject]@{
        Title         = $Title
        Annotations   = [System.Collections.Generic.List[string]]::new()
        ErrorMessages = [System.Collections.Generic.List[string]]::new()
        Failure       = $null
    }
}

function Add-Annotation {
    <#
    .SYNOPSIS
    Writes one workflow command, ::<command> [file=<file>,]title=<title>::<message>, and collects it in -Context.
    .DESCRIPTION
    -Title defaults to the title of the context. File and title are escaped as property values, the message as the
    message part. An error annotation also adds -Message (unescaped) to Context.ErrorMessages. Returns nothing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Context,
        [ValidateSet('error', 'warning', 'notice')][string]$Command = 'error',
        [AllowNull()][AllowEmptyString()][string]$File,
        [AllowNull()][AllowEmptyString()][string]$Title,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$Message
    )
    if (-not $PSBoundParameters.ContainsKey('Title')) { $Title = $Context.Title }
    $properties = "title=$(Format-AnnotationText $Title -Property)"
    if ($File) { $properties = "file=$(Format-AnnotationText $File -Property),$properties" }
    $line = "::$Command $properties::$(Format-AnnotationText $Message)"
    $Context.Annotations.Add($line)
    if ($Command -eq 'error') { $Context.ErrorMessages.Add($Message) }
    Write-Host $line
}

function Add-Failure {
    <#
    .SYNOPSIS
    Records the failure kind of the run in -Context; the first kind wins.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject]$Context, [Parameter(Mandatory)][string]$Kind)
    if ($null -eq $Context.Failure) { $Context.Failure = $Kind }
}

function Resolve-ActionPath {
    <#
    .SYNOPSIS
    A path made absolute against the PowerShell location ([System.IO.File] would resolve it against the process
    directory). An empty path comes back as it is; the path need not exist.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowNull()][AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return $Path }
    return $PSCmdlet.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Write-Text {
    <#
    .SYNOPSIS
    Appends -Text to the file -Path (UTF-8 without BOM, CRLF written as LF); nothing when -Path is empty.
    #>
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrEmpty($Path)) { return }
    [System.IO.File]::AppendAllText((Resolve-ActionPath $Path), $Text.Replace("`r`n", "`n"), [System.Text.UTF8Encoding]::new($false))
}

function Write-ActionOutput {
    <#
    .SYNOPSIS
    Appends one key=value line per entry of -Outputs, in its order, to -Path (default GITHUB_OUTPUT).
    .DESCRIPTION
    A value is written as PowerShell interpolates it ($null as ''). A value with CR or LF is written in the
    heredoc form, key<<ghadelim_<guid>, the value, the delimiter, so it cannot forge another output line. Nothing
    is written when -Path is empty or -Outputs has no entry.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Outputs,
        [AllowNull()][AllowEmptyString()][string]$Path = $env:GITHUB_OUTPUT
    )
    if ([string]::IsNullOrEmpty($Path) -or $Outputs.Count -eq 0) { return }
    $text = [System.Text.StringBuilder]::new()
    foreach ($entry in $Outputs.GetEnumerator()) {
        $value = "$($entry.Value)"
        if ($value.Contains("`r") -or $value.Contains("`n")) {
            $delimiter = 'ghadelim_' + [guid]::NewGuid().ToString('n')
            [void]$text.Append("$($entry.Key)<<$delimiter`n$value`n$delimiter`n")
        } else {
            [void]$text.Append("$($entry.Key)=$value`n")
        }
    }
    Write-Text -Path $Path -Text $text.ToString()
}

function Limit-SummaryText {
    <#
    .SYNOPSIS
    Markdown cut below -MaxBytes (UTF-8) at a line boundary, an open code fence closed, and -Footer as an italic line.
    .DESCRIPTION
    Text within the limit comes back as it is. Otherwise whole lines are kept from the start (the first line, a
    heading, always), an open ``` or ~~~ fence in the kept part is closed, and '_<Footer>_' ends the text. Used for
    the job summaries of the CheckForUpdates and Validate actions.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][int]$MaxBytes,
        [Parameter(Mandatory)][string]$Footer
    )
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    if ($utf8.GetByteCount($Text) -le $MaxBytes) { return $Text }
    $footerText = "`n_$($Footer)_`n"
    $lines = $Text.Split("`n")
    $kept = [System.Collections.Generic.List[string]]::new()
    $fence = $null
    $used = 0
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        # Room for this line, the footer and a fence closer of the current or a newly opened fence.
        $closer = if ($null -ne $fence) { $fence.Length + 1 } else { $line.Length + 1 }
        if ($i -gt 0 -and $used + $utf8.GetByteCount($line) + 1 + $closer + $utf8.GetByteCount($footerText) -gt $MaxBytes) { break }
        $kept.Add($line)
        $used += $utf8.GetByteCount($line) + 1
        $marker = [regex]::Match($line, '^[ ]{0,3}(`{3,}|~{3,})')
        if ($null -ne $fence) {
            if ($marker.Success -and $marker.Groups[1].Value[0] -ceq $fence[0] -and $marker.Groups[1].Value.Length -ge $fence.Length -and $line.Trim() -ceq $marker.Groups[1].Value) { $fence = $null }
        } elseif ($marker.Success) {
            $fence = $marker.Groups[1].Value
        }
    }
    $result = ($kept -join "`n") + "`n"
    if ($null -ne $fence) { $result += "$fence`n" }
    return $result + $footerText
}

Export-ModuleMember -Function @(
    'Add-Annotation'
    'Add-Failure'
    'ConvertTo-SingleLine'
    'Format-AnnotationText'
    'Format-TableCell'
    'Limit-SummaryText'
    'New-ActionContext'
    'Resolve-ActionPath'
    'Write-ActionOutput'
    'Write-Text'
)
