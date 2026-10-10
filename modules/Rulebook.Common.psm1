#requires -Version 7.4
# Rulebook.Common: the leaf helpers several engine modules share (#78): the git runner with UTF-8 output decoding and
# a per-process environment, and the ordinal collections (an insertion-ordered map and a set, both case-sensitive).
# Imports nothing; every module that calls one of these functions imports this module itself (a nested import is not
# transitive).

Set-StrictMode -Version 3.0

$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

#region Internal helpers

function New-GitStartInfo {
    # The start info of one git process: 'git -C <Root> <Arguments>', output and error redirected and decoded as UTF-8
    # independent of the console code page, no credential prompt, then the extra environment of this process only
    # (the token header of Rulebook.GitHub).
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds a ProcessStartInfo object; changes no state')]
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
    return $info
}

#endregion

#region Exported functions

function Invoke-Git {
    <#
    .SYNOPSIS
    Runs git in Root and returns { ExitCode, Output, Error }; a non-zero exit code does not throw.
    .DESCRIPTION
    Output and error are decoded as UTF-8 independent of the console code page. GIT_TERMINAL_PROMPT is 0, and the
    entries of -Environment are set for this git process only, never in the session.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string[]]$Arguments,
        [System.Collections.IDictionary]$Environment
    )
    $info = New-GitStartInfo -Root $Root -Arguments $Arguments -Environment $Environment
    $process = [System.Diagnostics.Process]::Start($info)
    $errorTask = $process.StandardError.ReadToEndAsync()
    $output = $process.StandardOutput.ReadToEnd()
    $process.WaitForExit()
    return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $output; Error = $errorTask.Result }
}

function Get-OrdinalMap {
    <#
    .SYNOPSIS
    An empty insertion-ordered map with ordinal keys. [ordered]@{} compares keys case-insensitively, so AL0001 and
    al0001 would collide.
    #>
    [CmdletBinding()]
    param()
    # The comma keeps PowerShell from unrolling the empty map into $null.
    return , [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::Ordinal)
}

function Get-OrdinalSet {
    <#
    .SYNOPSIS
    A case-sensitive string set of Items without null and empty items (the [string[]] binding turns a null item
    into an empty string); empty without -Items.
    #>
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyCollection()][string[]]$Items)
    $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($item in @($Items)) { if (-not [string]::IsNullOrEmpty($item)) { [void]$set.Add($item) } }
    # The comma keeps PowerShell from unrolling the set.
    return , $set
}

#endregion

Export-ModuleMember -Function @('Get-OrdinalMap', 'Get-OrdinalSet', 'Invoke-Git')
