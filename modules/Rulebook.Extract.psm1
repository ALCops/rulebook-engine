#requires -Version 7.4
# Rulebook.Extract: the diagnostic descriptors of the analyzer packages by reflection in pwsh (WP08, R9; spike (b),
# docs/reference/spikes/b-analyzer-dll-extraction.md). Get-AnalyzerDescriptor loads the compiler and the cop DLLs of
# one package version and reads every advertised descriptor, the compiler's configurable ids and the descriptors
# defined as static fields only; it runs in a child pwsh started by Invoke-DescriptorExtraction, one process per
# package version and channel, so two versions of Microsoft.Dynamics.Nav.CodeAnalysis never meet in one process.
# ConvertTo-DiagnosticRecord turns a result into one record per id of one package. Imports Rulebook.Catalog for the
# docs URL rule only. Contract: docs/reference/scan-mechanics.md section 2.

Set-StrictMode -Version 3.0
Import-Module (Join-Path $PSScriptRoot 'Rulebook.Catalog.psd1')

$script:ToolsPackageId = 'microsoft.dynamics.businesscentral.development.tools'
$script:AlcopsPackageId = 'alcops.analyzers'
# The minimum expected set: a package version without one of these fails the extraction. Further cop DLLs are
# scanned by the file pattern.
$script:ToolsAssemblies = @(
    'Microsoft.Dynamics.Nav.CodeAnalysis'
    'Microsoft.Dynamics.Nav.CodeCop'
    'Microsoft.Dynamics.Nav.UICop'
    'Microsoft.Dynamics.Nav.AppSourceCop'
    'Microsoft.Dynamics.Nav.PerTenantExtensionCop'
)
$script:AlcopsAssemblies = @(
    'ALCops.ApplicationCop'
    'ALCops.Common'
    'ALCops.DocumentationCop'
    'ALCops.FormattingCop'
    'ALCops.LinterCop'
    'ALCops.PlatformCop'
    'ALCops.TestAutomationCop'
)
$script:KnownPrefixes = @('AL', 'AA', 'AW', 'PTE', 'AS', 'PC', 'AC', 'LC', 'DC', 'FC', 'TA', 'CM')
$script:CompilerAssembly = 'Microsoft.Dynamics.Nav.CodeAnalysis'
$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
# The folders the AssemblyResolve handler probes, in order (ALCops first, then the tools folder).
$script:ResolveDirs = @()

#region Internal helpers

function Get-PropertyValue {
    # A property of a .NET object, $null when the type has none (StrictMode safe: IsDeprecated is not on every build).
    param($Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function New-ExtractException {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an exception; changes no state')]
    param([Parameter(Mandatory)][string]$Message, [System.Exception]$Inner)
    $exception = if ($Inner) { [System.InvalidOperationException]::new($Message, $Inner) } else { [System.InvalidOperationException]::new($Message) }
    $exception.Data['Stage'] = 'extract'
    return $exception
}

function Get-DefaultPwshPath {
    # The pwsh of this session from $PSHOME. Under a .NET global tool install the process path is dotnet, so the
    # process path is never used; Get-Command pwsh is the fallback.
    foreach ($name in 'pwsh.exe', 'pwsh') {
        $candidate = Join-Path $PSHOME $name
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    $command = Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $command) { throw (New-ExtractException -Message "No pwsh found in $PSHOME or on the PATH; pass -PwshPath") }
    return $command.Source
}

# The runner's command files: a DLL that appends to them (NODE_OPTIONS, a PATH entry) would poison the later steps.
$script:RunnerFileVariables = @('GITHUB_ENV', 'GITHUB_PATH', 'GITHUB_OUTPUT', 'GITHUB_STATE', 'GITHUB_STEP_SUMMARY')

function Test-SecretVariable {
    # A variable the extraction child must not see: the action inputs, every token, secret, password, key or PAT, and
    # the runner's command files.
    param([Parameter(Mandatory)][string]$Name)
    foreach ($pattern in 'INPUT_*', '*TOKEN', '*_SECRET', '*_PASSWORD', '*_KEY', '*_PAT') { if ($Name -like $pattern) { return $true } }
    return $Name -in @('GITHUB_TOKEN', 'GH_TOKEN', 'ACTIONS_RUNTIME_TOKEN', 'ACTIONS_ID_TOKEN_REQUEST_TOKEN') + $script:RunnerFileVariables
}

function New-ExtractionStartInfo {
    # The start info of the extraction child, its environment without secrets (Test-SecretVariable).
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an object; changes no state')]
    param([Parameter(Mandatory)][string]$PwshPath, [Parameter(Mandatory)][string]$EncodedCommand, [string]$WorkingDirectory)
    $info = [System.Diagnostics.ProcessStartInfo]::new($PwshPath)
    if ($WorkingDirectory) { $info.WorkingDirectory = $WorkingDirectory }
    foreach ($argument in '-NoProfile', '-NonInteractive', '-OutputFormat', 'Text', '-EncodedCommand', $EncodedCommand) { $info.ArgumentList.Add($argument) }
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.UseShellExecute = $false
    $info.StandardOutputEncoding = $script:Utf8NoBom
    $info.StandardErrorEncoding = $script:Utf8NoBom
    foreach ($name in @($info.Environment.Keys)) {
        if (Test-SecretVariable -Name ([string]$name)) { [void]$info.Environment.Remove($name) }
    }
    return $info
}

function ConvertTo-DescriptorRow {
    param($Descriptor, [Parameter(Mandatory)][string]$Assembly, [Parameter(Mandatory)][string]$Source, [bool]$Advertised)
    $link = Get-PropertyValue $Descriptor 'HelpLinkUri'
    return [ordered]@{
        id               = [string]$Descriptor.Id
        assembly         = $Assembly
        analyzerType     = $Source
        defaultSeverity  = [string]$Descriptor.DefaultSeverity
        enabledByDefault = [bool]$Descriptor.IsEnabledByDefault
        # Title is a LocalizableString in the real compiler, a string in the stubs; [string] reads both.
        title            = [string](Get-PropertyValue $Descriptor 'Title')
        helpLinkUri      = $(if ([string]::IsNullOrEmpty([string]$link)) { $null } else { [string]$link })
        isDeprecated     = [bool](Get-PropertyValue $Descriptor 'IsDeprecated')
        advertised       = $Advertised
    }
}

function Get-AnalyzerName {
    # Compiler for the compiler assembly, else the last part of Microsoft.Dynamics.Nav.<X> or ALCops.<X>.
    param([Parameter(Mandatory)][string]$Assembly)
    if ($Assembly -ceq $script:CompilerAssembly) { return 'Compiler' }
    if ($Assembly -cmatch '^Microsoft\.Dynamics\.Nav\.(.+)$') { return $Matches[1] }
    if ($Assembly -cmatch '^ALCops\.(.+)$') { return $Matches[1] }
    return $Assembly
}

function Test-PackageAssembly {
    param([Parameter(Mandatory)][string]$Assembly, [Parameter(Mandatory)][string]$PackageId)
    if ($PackageId -ceq $script:AlcopsPackageId) { return $Assembly -clike 'ALCops.*' }
    if ($PackageId -ceq $script:ToolsPackageId) { return $Assembly -clike 'Microsoft.Dynamics.Nav.*' }
    return $false
}

#endregion

function Resolve-AnalyzerFolder {
    <#
    .SYNOPSIS
    The analyzer folder of an extracted package for this runtime: tools/<tfm>/any (tools) or lib/<tfm> (alcops).
    .DESCRIPTION
    Among the subfolders named net<N>.0 the one with the highest N that is not newer than -RuntimeMajor (default
    the major version of the running .NET); netstandard* is never chosen. Throws, naming the folders found, when
    none qualifies.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$PackageRoot,
        [Parameter(Mandatory)][ValidateSet('tools', 'alcops')][string]$Kind,
        [int]$RuntimeMajor = [System.Environment]::Version.Major
    )
    $base = Join-Path $PackageRoot $(if ($Kind -eq 'tools') { 'tools' } else { 'lib' })
    $names = @(if (Test-Path -LiteralPath $base -PathType Container) { Get-ChildItem -LiteralPath $base -Directory | ForEach-Object Name | Sort-Object })
    $best = $null
    $bestMajor = -1
    foreach ($name in $names) {
        if ($name -cnotmatch '^net(\d+)\.0$') { continue }
        $major = [int]$Matches[1]
        if ($major -le $RuntimeMajor -and $major -gt $bestMajor) {
            $best = $name
            $bestMajor = $major
        }
    }
    $layout = if ($Kind -eq 'tools') { 'tools/<tfm>/any' } else { 'lib/<tfm>' }
    if ($null -eq $best) {
        $found = if ($names.Count -gt 0) { $names -join ', ' } else { 'none' }
        throw (New-ExtractException -Message "No $layout folder for .NET $RuntimeMajor in $PackageRoot (found: $found)")
    }
    $folder = if ($Kind -eq 'tools') { Join-Path $base $best 'any' } else { Join-Path $base $best }
    if (-not (Test-Path -LiteralPath $folder -PathType Container)) { throw (New-ExtractException -Message "No $layout folder for .NET $RuntimeMajor in $PackageRoot (found: $($names -join ', '))") }
    return $folder
}

function Get-AnalyzerDescriptor {
    <#
    .SYNOPSIS
    Every diagnostic descriptor of one package version by reflection; run it in a child process only.
    .DESCRIPTION
    Loads Microsoft.Dynamics.Nav.CodeAnalysis.dll from -ToolsDir, then every Microsoft.Dynamics.Nav.*Cop.dll there and
    every ALCops.*.dll in -AlcopsDir, with an AssemblyResolve handler that probes -AlcopsDir and then -ToolsDir.
    Compiler ids: the internal ErrorCode enum, members of 100 and up named WRN_, INF_ or HDN_, titles from the
    CompilerDiagnosticsResources resource (a missing resource sets compilerTitlesMissing and leaves the titles null).
    Cop ids: every non-abstract DiagnosticAnalyzer with a parameterless constructor is instantiated and its
    SupportedDiagnostics read; a second pass reads the static fields and properties of type DiagnosticDescriptor
    (fieldOnly: defined, advertised by no analyzer). Fails loudly: an assembly that does not load, a
    ReflectionTypeLoadException, an analyzer that cannot be instantiated or a missing -ExpectedAssembly throws.
    Writes the result to -OutFile (UTF-8 without BOM) and returns it: { runtime, toolsDir, alcopsDir, assemblies
    [{ name, path, types, analyzers, descriptors }], rows [...], fieldOnly [...], compilerTitlesMissing,
    elapsedSeconds }.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][string]$ToolsDir,
        [string]$AlcopsDir,
        [string[]]$ExpectedAssembly,
        [string]$OutFile
    )
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $ToolsDir = (Resolve-Path -LiteralPath $ToolsDir -ErrorAction Stop).ProviderPath
    if ($AlcopsDir) { $AlcopsDir = (Resolve-Path -LiteralPath $AlcopsDir -ErrorAction Stop).ProviderPath }
    $script:ResolveDirs = @(@($AlcopsDir, $ToolsDir) | Where-Object { $_ })
    # The handler reads $script:ResolveDirs and makes only .NET calls. A handler built with GetNewClosure() that
    # called Join-Path and Test-Path overflowed the stack of the child process (WP08 smoke test), so it stays this
    # plain form.
    $handler = [System.ResolveEventHandler] {
        $name = ([System.Reflection.AssemblyName]$args[1].Name).Name
        foreach ($dir in $script:ResolveDirs) {
            $candidate = [System.IO.Path]::Combine($dir, $name + '.dll')
            if ([System.IO.File]::Exists($candidate)) { return [System.Reflection.Assembly]::LoadFrom($candidate) }
        }
        return $null
    }
    [System.AppDomain]::CurrentDomain.add_AssemblyResolve($handler)
    try {
        $compilerPath = Join-Path $ToolsDir "$($script:CompilerAssembly).dll"
        if (-not (Test-Path -LiteralPath $compilerPath -PathType Leaf)) { throw (New-ExtractException -Message "$($script:CompilerAssembly).dll is not in $ToolsDir") }
        try {
            $compiler = [System.Reflection.Assembly]::LoadFrom($compilerPath)
        } catch {
            throw (New-ExtractException -Message "Could not load $compilerPath`: $($_.Exception.GetBaseException().Message)" -Inner $_.Exception)
        }
        $analyzerBase = $compiler.GetType('Microsoft.Dynamics.Nav.CodeAnalysis.Diagnostics.DiagnosticAnalyzer', $true)
        $descriptorType = $compiler.GetType('Microsoft.Dynamics.Nav.CodeAnalysis.Diagnostics.DiagnosticDescriptor', $true)
        $rows = [System.Collections.Generic.List[object]]::new()
        $assemblies = [System.Collections.Generic.List[object]]::new()

        # The compiler's configurable ids.
        $errorCode = $compiler.GetType('Microsoft.Dynamics.Nav.CodeAnalysis.ErrorCode', $true)
        $resources = [System.Resources.ResourceManager]::new('Microsoft.Dynamics.Nav.CodeAnalysis.CompilerDiagnosticsResources', $compiler)
        $titlesMissing = $false
        $compilerCount = 0
        foreach ($name in [System.Enum]::GetNames($errorCode)) {
            $value = [int][System.Enum]::Parse($errorCode, $name)
            if ($value -lt 100) { continue }
            $severity = switch -CaseSensitive -Regex ($name) { '^WRN_' { 'Warning' } '^INF_' { 'Info' } '^HDN_' { 'Hidden' } default { $null } }
            if ($null -eq $severity) { continue }
            $title = $null
            if (-not $titlesMissing) {
                $key = if ($name -clike 'WRN_ERR_*') { $name.Substring(4) } else { $name }
                try { $title = $resources.GetString($key) } catch [System.Resources.MissingManifestResourceException] { $titlesMissing = $true }
            }
            $rows.Add([ordered]@{
                    id = 'AL{0:0000}' -f $value; assembly = $script:CompilerAssembly; analyzerType = "ErrorCode.$name"; defaultSeverity = $severity
                    enabledByDefault = $true; title = $title; helpLinkUri = $null; isDeprecated = $false; advertised = $true
                })
            $compilerCount++
        }
        $assemblies.Add([ordered]@{ name = $script:CompilerAssembly; path = $compilerPath; types = 0; analyzers = 0; descriptors = $compilerCount })

        # The cops.
        $dlls = @(Get-ChildItem -LiteralPath $ToolsDir -File -Filter 'Microsoft.Dynamics.Nav.*Cop.dll' | Sort-Object Name)
        if ($AlcopsDir) { $dlls += @(Get-ChildItem -LiteralPath $AlcopsDir -File -Filter 'ALCops.*.dll' | Sort-Object Name) }
        $found = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        [void]$found.Add($script:CompilerAssembly)
        foreach ($dll in $dlls) { [void]$found.Add([System.IO.Path]::GetFileNameWithoutExtension($dll.Name)) }
        foreach ($expected in @($ExpectedAssembly | Where-Object { $_ })) {
            if (-not $found.Contains($expected)) { throw (New-ExtractException -Message "Expected assembly $expected.dll is missing (searched $($script:ResolveDirs -join ', '))") }
        }
        $fieldRows = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::Ordinal)
        $fieldErrors = [System.Collections.Generic.List[string]]::new()
        $flags = [System.Reflection.BindingFlags]'Static, Public, NonPublic, DeclaredOnly'
        foreach ($dll in $dlls) {
            try {
                $assembly = [System.Reflection.Assembly]::LoadFrom($dll.FullName)
            } catch {
                throw (New-ExtractException -Message "Could not load $($dll.FullName): $($_.Exception.GetBaseException().Message)" -Inner $_.Exception)
            }
            $assemblyName = $assembly.GetName().Name
            try {
                $types = $assembly.GetTypes()
            } catch [System.Reflection.ReflectionTypeLoadException] {
                $loaded = @($_.Exception.Types | Where-Object { $null -ne $_ }).Count
                $first = @($_.Exception.LoaderExceptions | Where-Object { $null -ne $_ } | Select-Object -First 1)
                $reason = if ($first.Count -gt 0) { $first[0].Message } else { 'unknown' }
                throw (New-ExtractException -Message "$($dll.Name): $($_.Exception.Types.Count - $loaded) of $($_.Exception.Types.Count) types could not be loaded ($reason)" -Inner $_.Exception)
            }
            $analyzerCount = 0
            $descriptorCount = 0
            foreach ($type in $types) {
                if (-not $type.IsClass -or $type.IsAbstract -or -not $analyzerBase.IsAssignableFrom($type) -or $null -eq $type.GetConstructor([type]::EmptyTypes)) { continue }
                try {
                    $instance = [System.Activator]::CreateInstance($type)
                    $supported = $instance.SupportedDiagnostics
                } catch {
                    throw (New-ExtractException -Message "Could not instantiate $($type.FullName) of $($dll.Name): $($_.Exception.GetBaseException().Message)" -Inner $_.Exception)
                }
                $analyzerCount++
                # foreach enumerates an ImmutableArray<T> and an array alike.
                foreach ($descriptor in $supported) {
                    $rows.Add((ConvertTo-DescriptorRow -Descriptor $descriptor -Assembly $assemblyName -Source $type.FullName -Advertised $true))
                    $descriptorCount++
                }
            }
            # Second pass: descriptors defined as static members, whether or not an analyzer returns them.
            foreach ($type in $types) {
                if ($type.ContainsGenericParameters) { continue }
                $members = @($type.GetFields($flags) | Where-Object { $_.FieldType -eq $descriptorType }) + @($type.GetProperties($flags) | Where-Object { $_.PropertyType -eq $descriptorType -and $_.GetIndexParameters().Count -eq 0 })
                foreach ($member in $members) {
                    # A getter that throws does not fail the run (the descriptor is not needed for the advertised
                    # ones), but it is reported.
                    try {
                        $descriptor = $member.GetValue($null)
                    } catch {
                        $fieldErrors.Add("$($type.FullName).$($member.Name): $($_.Exception.GetBaseException().Message)")
                        continue
                    }
                    if ($null -eq $descriptor -or $fieldRows.Contains([string]$descriptor.Id)) { continue }
                    $fieldRows[[string]$descriptor.Id] = ConvertTo-DescriptorRow -Descriptor $descriptor -Assembly $assemblyName -Source "$($type.FullName).$($member.Name)" -Advertised $false
                }
            }
            $assemblies.Add([ordered]@{ name = $assemblyName; path = $dll.FullName; types = $types.Count; analyzers = $analyzerCount; descriptors = $descriptorCount })
        }
        $advertised = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        foreach ($row in $rows) { [void]$advertised.Add($row.id) }
        $fieldOnly = @($fieldRows.Values | Where-Object { -not $advertised.Contains($_.id) })
        $result = [ordered]@{
            runtime               = [System.Environment]::Version.ToString()
            toolsDir              = $ToolsDir
            alcopsDir             = $(if ($AlcopsDir) { $AlcopsDir } else { $null })
            assemblies            = $assemblies.ToArray()
            rows                  = $rows.ToArray()
            fieldOnly             = $fieldOnly
            fieldErrors           = $fieldErrors.ToArray()
            compilerTitlesMissing = $titlesMissing
            elapsedSeconds        = [math]::Round($watch.Elapsed.TotalSeconds, 2)
        }
    } finally {
        [System.AppDomain]::CurrentDomain.remove_AssemblyResolve($handler)
    }
    if ($OutFile) {
        $OutFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutFile)
        [System.IO.File]::WriteAllText($OutFile, (ConvertTo-Json -InputObject $result -Depth 6), $script:Utf8NoBom)
    }
    return $result
}

function Invoke-DescriptorExtraction {
    <#
    .SYNOPSIS
    Runs Get-AnalyzerDescriptor in a child pwsh and returns its result (a dictionary).
    .DESCRIPTION
    pwsh -NoProfile -NonInteractive -EncodedCommand imports this module and writes the result to
    <WorkPath>/descriptors-<guid>.json. -PwshPath defaults to the pwsh in $PSHOME (Get-Command pwsh as the fallback).
    A non-zero exit, a timeout (-TimeoutSeconds, default 300; the child is killed) or a missing result file throws
    'Extraction failed for <ToolsDir>: <the last 20 output lines>' with Data['Stage'] = 'extract' (and Data['ProcessId']).
    The child gets no secret: every INPUT_* variable, GITHUB_TOKEN, GH_TOKEN, ACTIONS_RUNTIME_TOKEN,
    ACTIONS_ID_TOKEN_REQUEST_TOKEN, any name ending in TOKEN, _SECRET, _PASSWORD, _KEY or _PAT, and the runner's
    command files (GITHUB_ENV, GITHUB_PATH, GITHUB_OUTPUT, GITHUB_STATE, GITHUB_STEP_SUMMARY) are removed from its
    environment, and it runs in -WorkPath, because it loads the downloaded DLLs and runs their analyzer constructors.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)][string]$ToolsDir,
        [string]$AlcopsDir,
        [string[]]$ExpectedAssembly,
        [Parameter(Mandatory)][string]$WorkPath,
        [string]$PwshPath,
        [int]$TimeoutSeconds = 300
    )
    if ([string]::IsNullOrEmpty($PwshPath)) { $PwshPath = Get-DefaultPwshPath }
    $WorkPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($WorkPath)
    [void][System.IO.Directory]::CreateDirectory($WorkPath)
    $outFile = Join-Path $WorkPath ('descriptors-' + [guid]::NewGuid().ToString('n') + '.json')
    $quote = { param([string]$Value) "'" + $Value.Replace("'", "''") + "'" }
    $command = [System.Text.StringBuilder]::new()
    # The failure goes to stderr as one line: the error view of pwsh wraps at the console width, which would cut the
    # message the scan reports in the middle of a name.
    [void]$command.Append("`$ErrorActionPreference = 'Stop'; `$PSStyle.OutputRendering = 'PlainText'; try { ")
    [void]$command.Append("Import-Module $(& $quote (Join-Path $PSScriptRoot 'Rulebook.Extract.psd1')); ")
    [void]$command.Append("`$null = Get-AnalyzerDescriptor -ToolsDir $(& $quote $ToolsDir) -OutFile $(& $quote $outFile)")
    if ($AlcopsDir) { [void]$command.Append(" -AlcopsDir $(& $quote $AlcopsDir)") }
    $expected = @($ExpectedAssembly | Where-Object { $_ })
    if ($expected.Count -gt 0) { [void]$command.Append(' -ExpectedAssembly @(' + (@($expected | ForEach-Object { & $quote $_ }) -join ', ') + ')') }
    [void]$command.Append(" } catch { [Console]::Error.WriteLine(`$_.Exception.Message); exit 1 }")
    $encoded = [System.Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($command.ToString()))

    $info = New-ExtractionStartInfo -PwshPath $PwshPath -EncodedCommand $encoded -WorkingDirectory $WorkPath
    $process = [System.Diagnostics.Process]::Start($info)
    $outputTask = $process.StandardOutput.ReadToEndAsync()
    $errorTask = $process.StandardError.ReadToEndAsync()
    $tail = {
        $lines = @(($outputTask.Result + "`n" + $errorTask.Result).Split("`n") | ForEach-Object { $_.TrimEnd() } | Where-Object { $_ })
        return (@($lines | Select-Object -Last 20) -join "`n")
    }
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        try { $process.Kill($true) } catch { Write-Verbose "The extraction process could not be killed: $($_.Exception.Message)" }
        $process.WaitForExit()
        $exception = New-ExtractException -Message "Extraction failed for $ToolsDir`: no result after $TimeoutSeconds s (the process was stopped)"
        $exception.Data['ProcessId'] = $process.Id
        throw $exception
    }
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) { throw (New-ExtractException -Message "Extraction failed for $ToolsDir`: $(& $tail)") }
    if (-not (Test-Path -LiteralPath $outFile -PathType Leaf)) { throw (New-ExtractException -Message "Extraction failed for $ToolsDir`: no result file. $(& $tail)") }
    try {
        return ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($outFile, $script:Utf8NoBom)) -AsHashtable -Depth 20 -ErrorAction Stop
    } catch {
        throw (New-ExtractException -Message "Extraction failed for $ToolsDir`: the result is not JSON ($($_.Exception.Message))")
    } finally {
        Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
    }
}

function ConvertTo-DiagnosticRecord {
    <#
    .SYNOPSIS
    One record per diagnostic id of -PackageId from an extraction result: { PackageId, Records, Conflicts,
    UnknownPrefixes, CompilerTitlesMissing }.
    .DESCRIPTION
    Keeps the rows of the package's assemblies (ALCops.* for alcops.analyzers, Microsoft.Dynamics.Nav.* for the
    Development.Tools package). Records is an ordinal ordered map id -> { Id, Analyzer (Compiler, or <X> of
    Microsoft.Dynamics.Nav.<X> and ALCops.<X>), DefaultSeverity, EnabledByDefault, Title (white space folded to one
    space, $null when empty), HelpLinkUri, Docs (Get-CatalogDocsUrl), Advertised ($false for a descriptor no analyzer
    returns), Deprecated, DescriptorCount (analyzer types returning it), Assembly }. Duplicates are merged; when
    they disagree on severity or enablement the id is added to Conflicts { Id, Variants } and the first row wins.
    UnknownPrefixes lists the ids whose prefix the engine does not know; they are kept, never dropped.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Result, [Parameter(Mandatory)][string]$PackageId)
    $groups = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::Ordinal)
    foreach ($row in @(@($Result['rows']) + @($Result['fieldOnly']))) {
        if ($row -isnot [System.Collections.IDictionary] -or -not (Test-PackageAssembly -Assembly ([string]$row['assembly']) -PackageId $PackageId)) { continue }
        $id = [string]$row['id']
        if (-not $groups.Contains($id)) { $groups[$id] = [System.Collections.Generic.List[object]]::new() }
        $groups[$id].Add($row)
    }
    $records = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::Ordinal)
    $conflicts = [System.Collections.Generic.List[object]]::new()
    $unknown = [System.Collections.Generic.List[string]]::new()
    foreach ($id in $groups.Keys) {
        $all = @($groups[$id])
        $advertisedRows = @($all | Where-Object { [bool]$_['advertised'] })
        $used = @(if ($advertisedRows.Count -gt 0) { $advertisedRows } else { $all })
        $first = $used[0]
        $variants = @($used | ForEach-Object { '{0}/{1}' -f $_['defaultSeverity'], ([bool]$_['enabledByDefault']).ToString().ToLowerInvariant() } | Sort-Object -Unique)
        if ($variants.Count -gt 1) { $conflicts.Add([pscustomobject]@{ Id = $id; Variants = $variants }) }
        $title = ([regex]::Replace([string]$first['title'], '\s+', ' ')).Trim()
        $analyzer = Get-AnalyzerName -Assembly ([string]$first['assembly'])
        $link = if ([string]::IsNullOrEmpty([string]$first['helpLinkUri'])) { $null } else { [string]$first['helpLinkUri'] }
        $records[$id] = [pscustomobject]@{
            PSTypeName       = 'Rulebook.DiagnosticRecord'
            Id               = $id
            Analyzer         = $analyzer
            DefaultSeverity  = [string]$first['defaultSeverity']
            EnabledByDefault = [bool]$first['enabledByDefault']
            Title            = $(if ($title) { $title } else { $null })
            HelpLinkUri      = $link
            Docs             = Get-CatalogDocsUrl -Id $id -HelpLinkUri $link -Analyzer $analyzer
            Advertised       = $advertisedRows.Count -gt 0
            Deprecated       = @($used | Where-Object { [bool]$_['isDeprecated'] }).Count -gt 0
            DescriptorCount  = $advertisedRows.Count
            Assembly         = [string]$first['assembly']
        }
        $prefix = if ($id -cmatch '^([A-Z]+)[0-9]') { $Matches[1] } else { '' }
        if ($prefix -cnotin $script:KnownPrefixes) { $unknown.Add($id) }
    }
    return [pscustomobject]@{
        PSTypeName            = 'Rulebook.DiagnosticRecords'
        PackageId             = $PackageId
        Records               = $records
        Conflicts             = $conflicts.ToArray()
        UnknownPrefixes       = $unknown.ToArray()
        CompilerTitlesMissing = [bool]$Result['compilerTitlesMissing']
        FieldErrors           = [string[]]@($Result['fieldErrors'] | Where-Object { $_ })
    }
}

function Get-ExpectedAssembly {
    <#
    .SYNOPSIS
    The minimum set of assembly names an extraction of -PackageId must find (alcops includes its tools host).
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$PackageId)
    if ($PackageId -ceq $script:AlcopsPackageId) { return [string[]]($script:ToolsAssemblies + $script:AlcopsAssemblies) }
    return [string[]]$script:ToolsAssemblies
}

Export-ModuleMember -Function @(
    'ConvertTo-DiagnosticRecord'
    'Get-AnalyzerDescriptor'
    'Get-ExpectedAssembly'
    'Invoke-DescriptorExtraction'
    'Resolve-AnalyzerFolder'
)
