#requires -Version 7.4
# Rulebook.Common: the leaf helpers several engine modules share (#78): the git runner with UTF-8 output decoding and
# a per-process environment, the ordinal collections (an insertion-ordered map and a set, both case-sensitive), the
# JSON element reader that keeps strings as strings, the JSON schema evaluator (Test-RulebookSchema: JsonSchema.Net as
# shipped inside pwsh, one parsed schema per file per session, D56), and the engine ref with the URL builders for the schema, script and user docs URLs the engine prints or writes (D52,
# #63): the ref is GITHUB_ACTION_REF, else the ref folder of GITHUB_ACTION_PATH, else main, so an action at @v1
# names v1 URLs and engine CI and a local run name main. The user docs live in the template repository, whose
# branches differ from the engine's (D53): the engine ref is mapped to a template ref first (ConvertTo-TemplateRef).
# Imports nothing; every module that calls one of these functions imports this module itself (a nested import is not
# transitive).

Set-StrictMode -Version 3.0

$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$script:DefaultEngineRef = 'main'
$script:EngineRawUrl = 'https://raw.githubusercontent.com/ALCops/rulebook-engine/{0}/{1}/{2}'
$script:DocsUrl = 'https://github.com/ALCops/rulebook/blob/{0}/docs/{1}'
# The checkout folder of an action used as ALCops/rulebook-engine/actions/<Name>@<ref>:
# <runner>/_actions/ALCops/rulebook-engine/<ref>/actions/<Name>; a ref with a slash spans several folders.
$script:ActionPathPattern = '[\\/]_actions[\\/]ALCops[\\/]rulebook-engine[\\/](.+?)[\\/]actions[\\/]'
# A ref or a docs page: starts with a letter or digit, then letters, digits, dot, underscore, slash and hyphen.
$script:PathTextPattern = '^[A-Za-z0-9][A-Za-z0-9._/-]*\z'
# JsonSchema.Net ships inside pwsh ($PSHOME/JsonSchema.Net.dll). Product version of the build the suites and CI run
# on (pwsh 7.6.7, ubuntu-latest image 20261018); assembly version 7.0.0.0. Rulebook.Common.Tests.ps1 checks the
# version (CI only) and the API members used below (always), so another build fails a test, never Validate.
$script:JsonSchemaNetTested = '7.4.0'
$script:SchemaCache = $null      # Dictionary[string, Json.Schema.JsonSchema], key = full path, ordinal
$script:SchemaOptions = $null    # one Json.Schema.EvaluationOptions: OutputFormat List, Fetch through the cache

#region Internal helpers

function Test-RulebookPathText {
    # True when Value is a usable ref or docs page: the path text pattern, no '..' (git refuses it in a ref name, and
    # in a page it would leave docs/), no empty segment ('//', a trailing '/') and no segment starting with '.' (git
    # refuses both in a ref name).
    param([AllowNull()][AllowEmptyString()][string]$Value)
    if ([string]::IsNullOrEmpty($Value) -or $Value -notmatch $script:PathTextPattern) { return $false }
    return -not ($Value.Contains('..') -or $Value.Contains('//') -or $Value.EndsWith('/') -or $Value.Contains('/.'))
}

function Resolve-RulebookRef {
    # The ref a builder uses: -Ref trimmed, or Get-RulebookEngineRef when it is empty; an unusable -Ref throws.
    param([AllowNull()][AllowEmptyString()][string]$Ref)
    if ([string]::IsNullOrWhiteSpace($Ref)) { return Get-RulebookEngineRef }
    $value = $Ref.Trim()
    if (-not (Test-RulebookPathText $value)) { throw "'$Ref' is not a usable engine ref" }
    return $value
}

function ConvertTo-TemplateRef {
    # The ref of ALCops/rulebook that holds the user docs for an engine ref (D53): the floating major v<n> -> main
    # (the release), main -> preview (the canary at engine main reads the preview docs), a release tag vX.Y.Z[-pre]
    # -> the same tag (tagged on both repositories), a commit sha -> main (an engine commit the template does not
    # have), anything else (a feature branch in engine CI) -> preview.
    param([Parameter(Mandatory)][string]$Ref)
    if ($Ref -cmatch '^v\d+\z') { return 'main' }
    if ($Ref -ceq 'main') { return 'preview' }
    if ($Ref -cmatch '^v\d+\.\d+\.\d+(?:-[0-9A-Za-z]+(?:\.[0-9A-Za-z]+)*)?\z') { return $Ref }
    if ($Ref -match '^[0-9a-fA-F]{40}\z') { return 'main' }
    return 'preview'
}

function Format-EngineRawUrl {
    # https://raw.githubusercontent.com/ALCops/rulebook-engine/<ref>/<Folder>/<Name>, the ref from Resolve-RulebookRef.
    param([Parameter(Mandatory)][string]$Folder, [Parameter(Mandatory)][string]$Name, [AllowNull()][AllowEmptyString()][string]$Ref)
    return $script:EngineRawUrl -f (Resolve-RulebookRef $Ref), $Folder, $Name
}

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

function Initialize-SchemaEvaluator {
    # Creates the schema cache and the one set of evaluation options on first use; a no-op afterwards. Every
    # [Json.Schema.*] literal stays inside a function body, and the Add-Type covers a host that has not loaded the
    # Utility module (whose JSON cmdlets load JsonSchema.Net). The options carry their own registry, never
    # SchemaRegistry.Global; its Fetch resolves a file URI (the sibling $ref of a profile schema) through the cache, so
    # the hub is parsed once per session too. The Fetch script block runs on the calling thread in this module's
    # session state: never use the options from a background job or another runspace.
    if ($null -ne $script:SchemaOptions) { return }
    if (-not ('Json.Schema.JsonSchema' -as [type])) { Add-Type -LiteralPath (Join-Path $PSHOME 'JsonSchema.Net.dll') }
    $script:SchemaCache = [System.Collections.Generic.Dictionary[string, Json.Schema.JsonSchema]]::new([System.StringComparer]::Ordinal)
    $options = [Json.Schema.EvaluationOptions]::new()
    $options.OutputFormat = [Json.Schema.OutputFormat]::List
    $options.SchemaRegistry.Fetch = [Func[[Uri], [Json.Schema.IBaseDocument]]] {
        param($uri)
        if ($uri.IsFile) { Get-CachedSchema -Path $uri.LocalPath } else { $null }
    }
    $script:SchemaOptions = $options
}

function Get-CachedSchema {
    # The parsed schema of the file at Path, read once per session (key: the full path, ordinal). FromFile sets the
    # base URI to the file URI, which makes a relative $ref resolve to the sibling file through Fetch. A schema that
    # cannot be read or parsed throws. A relative Path resolves against the PowerShell location (GetFullPath alone
    # would use the process directory).
    param([Parameter(Mandatory)][string]$Path)
    $full = [System.IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path))
    $schema = $null
    if ($script:SchemaCache.TryGetValue($full, [ref]$schema)) { return $schema }
    try {
        $schema = [Json.Schema.JsonSchema]::FromFile($full)
    } catch {
        $inner = if ($null -ne $_.Exception.InnerException) { $_.Exception.InnerException } else { $_.Exception }
        throw [System.InvalidOperationException]::new("The schema $full cannot be read: $($inner.Message)", $_.Exception)
    }
    $script:SchemaCache[$full] = $schema
    return $schema
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

function ConvertFrom-JsonElement {
    <#
    .SYNOPSIS
    A System.Text.Json element as PowerShell values: ordered dictionaries with ordinal keys, object arrays, strings,
    doubles, booleans and $null.
    .DESCRIPTION
    Strings stay strings: ConvertFrom-Json would turn an ISO date in a justification into a [DateTime] (pwsh 7.4 has
    no -DateKind), and writing it back would change its text. Used by the readers of overrides.json, the quarantine
    files and the change set of an issue.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Text.Json.JsonElement]$Element)
    switch ($Element.ValueKind) {
        'Object' {
            $map = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::Ordinal)
            foreach ($property in $Element.EnumerateObject()) { $map[$property.Name] = ConvertFrom-JsonElement $property.Value }
            return , $map
        }
        'Array' {
            $list = [System.Collections.Generic.List[object]]::new()
            foreach ($item in $Element.EnumerateArray()) { $list.Add((ConvertFrom-JsonElement $item)) }
            return , $list.ToArray()
        }
        'String' { return $Element.GetString() }
        'Number' { return $Element.GetDouble() }
        'True' { return $true }
        'False' { return $false }
        default { return $null }
    }
}

function Test-RulebookSchema {
    <#
    .SYNOPSIS
    Evaluates a JSON text against a Rulebook schema file and returns { IsValid, Errors }.
    .DESCRIPTION
    Errors is one line per distinct schema error, '<text> at <JSON pointer>' ('at the root' for the empty pointer), in
    evaluation order (outermost failing keyword first); a text that is not strict JSON (a comment, a trailing comma)
    gives the one line 'the text is not valid JSON: <reason>'. The evaluator is JsonSchema.Net as shipped inside pwsh
    (D56), called directly rather than through the cmdlet of the Utility module: each schema file is parsed once per
    session and its relative $ref resolves to the sibling file through its own file location. Throws when the schema itself cannot be read, parsed or resolved (an engine defect,
    never a rulebook input error).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Json,
        [Parameter(Mandatory)][string]$SchemaPath
    )
    Initialize-SchemaEvaluator
    $schema = Get-CachedSchema -Path $SchemaPath
    try {
        $node = [System.Text.Json.Nodes.JsonNode]::Parse($Json)
    } catch {
        $inner = if ($null -ne $_.Exception.InnerException) { $_.Exception.InnerException } else { $_.Exception }
        return [pscustomobject]@{
            PSTypeName = 'Rulebook.SchemaResult'; IsValid = $false; Errors = [string[]]@("the text is not valid JSON: $($inner.Message)")
        }
    }
    try {
        $results = $schema.Evaluate($node, $script:SchemaOptions)
    } catch {
        $inner = if ($null -ne $_.Exception.InnerException) { $_.Exception.InnerException } else { $_.Exception }
        throw [System.InvalidOperationException]::new("The schema $SchemaPath cannot be evaluated: $($inner.Message)", $_.Exception)
    }
    if ($results.IsValid) {
        return [pscustomobject]@{ PSTypeName = 'Rulebook.SchemaResult'; IsValid = $true; Errors = [string[]]@() }
    }
    # List output: the root result plus one flat entry per evaluated location; a oneOf miss repeats branch lines, so
    # each line is added once. JsonSchema.Net writes a quote in a 'const' text as ": read back as ".
    $lines = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($detail in @(@($results) + @($results.Details))) {
        if ($null -eq $detail -or -not $detail.HasErrors -or $null -eq $detail.Errors) { continue }
        $where = $detail.InstanceLocation.ToString()
        if ($where -eq '') { $where = 'the root' }
        foreach ($entry in $detail.Errors.GetEnumerator()) {
            # A string const comes back as "\u0022x\u0022" (the serialised value inside the quotes of the text): one pair.
            $text = ([string]$entry.Value) -replace '"\\u0022(.*?)\\u0022"', '"$1"'
            $line = "$($text.Replace('\u0022', '"').Trim()) at $where"
            if ($seen.Add($line)) { $lines.Add($line) }
        }
    }
    # Callers index Errors[0] under strict mode: an invalid result always carries one line.
    if ($lines.Count -eq 0) { $lines.Add('the document does not match the schema') }
    return [pscustomobject]@{ PSTypeName = 'Rulebook.SchemaResult'; IsValid = $false; Errors = [string[]]$lines.ToArray() }
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
    GITHUB_ACTION_PATH when that is a checkout of ALCops/rulebook-engine, else main. A value that is no usable ref
    (a character other than letters, digits, '.', '_', '/' and '-', a leading punctuation mark, or '..') is skipped.
    .DESCRIPTION
    The runner sets both variables for a step of an action used as ALCops/rulebook-engine/actions/<Name>@<ref>
    (v1 for an organization, main for the canary rulebook). Engine CI runs the actions as ./actions/<Name>, where
    neither names a ref, and a local run has neither: both get main. Read at every call, never cached, so a test can
    set the variable after the import.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $ref = ([string]$env:GITHUB_ACTION_REF).Trim()
    if (Test-RulebookPathText $ref) { return $ref }
    $path = [string]$env:GITHUB_ACTION_PATH
    if ($path -match $script:ActionPathPattern) {
        $ref = $Matches[1].Replace('\', '/')
        if (Test-RulebookPathText $ref) { return $ref }
    }
    return $script:DefaultEngineRef
}

function Get-RulebookSchemaUrl {
    <#
    .SYNOPSIS
    The URL of an engine schema file at a ref: https://raw.githubusercontent.com/ALCops/rulebook-engine/<Ref>/schemas/<Name>.
    .DESCRIPTION
    -Name is the file name, for example ruleset.delta.schema.json. Without -Ref (or with an empty one) the ref is
    Get-RulebookEngineRef; an unusable -Ref throws.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]*\z')][string]$Name,
        [AllowEmptyString()][string]$Ref
    )
    return Format-EngineRawUrl -Folder 'schemas' -Name $Name -Ref $Ref
}

function Get-RulebookScriptUrl {
    <#
    .SYNOPSIS
    The URL of an engine script at a ref: https://raw.githubusercontent.com/ALCops/rulebook-engine/<Ref>/scripts/<Name>.
    .DESCRIPTION
    -Name is the file name, for example Get-RulebookSkeletons.ps1. Without -Ref (or with an empty one) the ref is
    Get-RulebookEngineRef; an unusable -Ref throws.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]*\z')][string]$Name,
        [AllowEmptyString()][string]$Ref
    )
    return Format-EngineRawUrl -Folder 'scripts' -Name $Name -Ref $Ref
}

function Get-RulebookDocsUrl {
    <#
    .SYNOPSIS
    The URL of a user docs page for an engine ref: https://github.com/ALCops/rulebook/blob/<template ref>/docs/<Page>.
    .DESCRIPTION
    -Page is the path under docs/, for example ghtokenworkflow.md. -Ref is an engine ref; without -Ref (or with an
    empty one) it is Get-RulebookEngineRef. The template repository has other branches than the engine (D53), so the
    engine ref is mapped: v<n> (the floating major) -> main, the release; main -> preview, the bleeding edge; a
    release tag vX.Y.Z -> the same tag; a commit sha -> main; anything else (a feature branch) -> preview.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][ValidateScript({ Test-RulebookPathText $_ })][string]$Page,
        [AllowEmptyString()][string]$Ref
    )
    return $script:DocsUrl -f (ConvertTo-TemplateRef (Resolve-RulebookRef $Ref)), $Page
}

#endregion

Export-ModuleMember -Function @(
    'ConvertFrom-JsonElement', 'Get-OrdinalMap', 'Get-OrdinalSet', 'Get-RulebookDocsUrl', 'Get-RulebookEngineRef', 'Get-RulebookSchemaUrl',
    'Get-RulebookScriptUrl', 'Invoke-Git', 'Test-RulebookSchema'
)
