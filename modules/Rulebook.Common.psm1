#requires -Version 7.4
# Rulebook.Common: the leaf helpers several engine modules share (#78): the git runner with UTF-8 output decoding and
# a per-process environment, the ordinal collections (an insertion-ordered map and a set, both case-sensitive), and
# the engine ref with the URL builders for the schema, script and user docs URLs the engine prints or writes (D52,
# #63): an action at @v1 names v1 URLs, engine CI and a local run name main.
# Imports nothing; every module that calls one of these functions imports this module itself (a nested import is not
# transitive).

Set-StrictMode -Version 3.0

$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$script:DefaultEngineRef = 'main'
$script:EngineRawUrl = 'https://raw.githubusercontent.com/ALCops/rulebook-engine/{0}/{1}/{2}'
$script:DocsUrl = 'https://github.com/ALCops/rulebook/blob/{0}/docs/{1}'
# The checkout folder of an action used as ALCops/rulebook-engine/...@<ref>: <runner>/_actions/ALCops/rulebook-engine/<ref>/.
$script:ActionPathPattern = '[\\/]_actions[\\/]ALCops[\\/]rulebook-engine[\\/]([^\\/]+)[\\/]'

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

function Get-RulebookEngineRef {
    <#
    .SYNOPSIS
    The engine ref this run was called with: GITHUB_ACTION_REF trimmed when it is set, else the ref folder of
    GITHUB_ACTION_PATH when that is a checkout of ALCops/rulebook-engine, else main.
    .DESCRIPTION
    The runner sets both variables for a step of an action used as ALCops/rulebook-engine/actions/<Name>@<ref>
    (v1 for an organization, main for the canary rulebook). Engine CI runs the actions as ./actions/<Name>, where
    neither names a ref, and a local run has neither: both get main. Read at every call, never cached, so a test can
    set the variable after the import.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $ref = [string]$env:GITHUB_ACTION_REF
    if (-not [string]::IsNullOrWhiteSpace($ref)) { return $ref.Trim() }
    $path = [string]$env:GITHUB_ACTION_PATH
    if ($path -match $script:ActionPathPattern) { return $Matches[1] }
    return $script:DefaultEngineRef
}

function Get-RulebookSchemaUrl {
    <#
    .SYNOPSIS
    The URL of an engine schema file at a ref: https://raw.githubusercontent.com/ALCops/rulebook-engine/<Ref>/schemas/<Name>.
    .DESCRIPTION
    -Name is the file name, for example ruleset.delta.schema.json. Without -Ref (or with an empty one) the ref is
    Get-RulebookEngineRef.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]*\z')][string]$Name,
        [AllowEmptyString()][string]$Ref
    )
    if ([string]::IsNullOrWhiteSpace($Ref)) { $Ref = Get-RulebookEngineRef }
    return $script:EngineRawUrl -f $Ref.Trim(), 'schemas', $Name
}

function Get-RulebookScriptUrl {
    <#
    .SYNOPSIS
    The URL of an engine script at a ref: https://raw.githubusercontent.com/ALCops/rulebook-engine/<Ref>/scripts/<Name>.
    .DESCRIPTION
    -Name is the file name, for example Get-RulebookSkeletons.ps1. Without -Ref (or with an empty one) the ref is
    Get-RulebookEngineRef.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]*\z')][string]$Name,
        [AllowEmptyString()][string]$Ref
    )
    if ([string]::IsNullOrWhiteSpace($Ref)) { $Ref = Get-RulebookEngineRef }
    return $script:EngineRawUrl -f $Ref.Trim(), 'scripts', $Name
}

function Get-RulebookDocsUrl {
    <#
    .SYNOPSIS
    The URL of a user documentation page at a ref: https://github.com/ALCops/rulebook/blob/<Ref>/docs/<Page>.
    .DESCRIPTION
    -Page is the path under docs/, for example ghtokenworkflow.md. Without -Ref (or with an empty one) the ref is
    Get-RulebookEngineRef: the template repository carries the same branches and tags as the engine (main, v1,
    v1.x.y), so one ref serves both. A commit sha names an engine commit the template repository does not have and
    falls back to main.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._/-]*\z')][string]$Page,
        [AllowEmptyString()][string]$Ref
    )
    if ([string]::IsNullOrWhiteSpace($Ref)) { $Ref = Get-RulebookEngineRef }
    $Ref = $Ref.Trim()
    if ($Ref -match '^[0-9a-fA-F]{40}\z') { $Ref = $script:DefaultEngineRef }
    return $script:DocsUrl -f $Ref, $Page
}

#endregion

Export-ModuleMember -Function @(
    'Get-OrdinalMap', 'Get-OrdinalSet', 'Get-RulebookDocsUrl', 'Get-RulebookEngineRef', 'Get-RulebookSchemaUrl',
    'Get-RulebookScriptUrl', 'Invoke-Git'
)
