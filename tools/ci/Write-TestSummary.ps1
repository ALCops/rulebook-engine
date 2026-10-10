#requires -Version 7.4
<#
.SYNOPSIS
Writes the Pester and coverage tables of a CI run into the job summary and one error annotation per failed test.

.DESCRIPTION
Reads the NUnit 2.5 XML Pester writes (-TestResultsPath) and, when given and present, the JaCoCo XML of its code
coverage (-CoveragePath), and appends two Markdown sections to -SummaryPath (default GITHUB_STEP_SUMMARY; without one
the Markdown goes to the host):

- "## Pester": a totals line and one row per test file (Suite, Tests, Failed, Skipped, Seconds). Ignored and
  Inconclusive tests count as skipped. A file that failed outside its tests (a parse error, a failed BeforeAll at
  file level) counts as one failed test of that file.
- "## Coverage": one row per source file (File, Covered, Missed, Percent of lines) in ordinal order and a totals row,
  or "No coverage report" when the file is not given or missing.

Every failed test is one error annotation, ::error file=<suite path>,title=Pester::<test name>: <first message
line>, unless -NoAnnotations. Paths are relative to -RepositoryRoot with '/' separators.

The script never calls exit and never fails the step: Pester's Run.Exit already failed the job, and a missing
results file is one line in the summary. Coverage is a report, not a gate (D51). It returns { Suites, Totals, Files,
CoverageTotals, FailedTests, Summary }.

.EXAMPLE
./tools/ci/Write-TestSummary.ps1 -TestResultsPath testResults.xml -CoveragePath coverage.xml
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Mandatory)][string]$TestResultsPath,
    [AllowEmptyString()][string]$CoveragePath,
    [AllowEmptyString()][string]$SummaryPath = $env:GITHUB_STEP_SUMMARY,
    [string]$RepositoryRoot = (Join-Path $PSScriptRoot '..' '..'),
    [switch]$NoAnnotations
)

Set-StrictMode -Version 3.0
Import-Module (Join-Path $PSScriptRoot '..' '..' 'modules' 'Rulebook.Action.psd1') -Force

$invariant = [System.Globalization.CultureInfo]::InvariantCulture
$ctx = New-ActionContext -Title 'Pester'
$root = [System.IO.Path]::GetFullPath((Resolve-ActionPath $RepositoryRoot))

function Read-XmlFile {
    # The XML of Path; the DOCTYPE of the JaCoCo report names a DTD that is not there, so DTDs are ignored.
    param([Parameter(Mandatory)][string]$Path)
    $settings = [System.Xml.XmlReaderSettings]::new()
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Ignore
    $settings.XmlResolver = $null
    $reader = [System.Xml.XmlReader]::Create($Path, $settings)
    try {
        $document = [System.Xml.XmlDocument]::new()
        $document.Load($reader)
        return $document
    } finally {
        $reader.Dispose()
    }
}

function Get-RelativePath {
    # A path relative to the repository root with '/' separators; a path outside it keeps its full form.
    param([Parameter(Mandatory)][string]$Path)
    $relative = [System.IO.Path]::GetRelativePath($root, $Path)
    if ($relative.StartsWith('..') -or [System.IO.Path]::IsPathRooted($relative)) { $relative = $Path }
    return $relative.Replace('\', '/')
}

function Get-FirstLine {
    param([AllowNull()][AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    return $Text.Replace("`r", '').Split("`n")[0].Trim()
}

function Format-Number {
    param([double]$Value)
    return $Value.ToString('0.0', $invariant)
}

$summary = [System.Text.StringBuilder]::new()
$suites = [System.Collections.Generic.List[object]]::new()
$failedTests = [System.Collections.Generic.List[object]]::new()
$totals = [pscustomobject]@{ Tests = 0; Passed = 0; Failed = 0; Skipped = 0; Seconds = 0.0 }

# 1. Pester
[void]$summary.AppendLine('## Pester').AppendLine()
$resultsFile = Resolve-ActionPath $TestResultsPath
if (-not (Test-Path -LiteralPath $resultsFile -PathType Leaf)) {
    [void]$summary.AppendLine("No test results ($(Split-Path -Leaf $TestResultsPath) not found).").AppendLine()
} else {
    $results = Read-XmlFile -Path $resultsFile
    $failedCases = 0
    # The test files are the suites directly under the root suite 'Pester'.
    foreach ($fileSuite in @($results.SelectNodes('/test-results/test-suite/results/test-suite'))) {
        $path = Get-RelativePath -Path $fileSuite.GetAttribute('name')
        $seconds = 0.0
        [void][double]::TryParse($fileSuite.GetAttribute('time'), [System.Globalization.NumberStyles]::Float, $invariant, [ref]$seconds)
        $row = [pscustomobject]@{ Suite = $path; Tests = 0; Failed = 0; Skipped = 0; Seconds = $seconds }
        foreach ($case in @($fileSuite.SelectNodes('.//test-case'))) {
            $row.Tests++
            switch ($case.GetAttribute('result')) {
                'Failure' {
                    $row.Failed++
                    $failedCases++
                    $message = $case.SelectSingleNode('failure/message')
                    $failedTests.Add([pscustomobject]@{ Suite = $path; Name = $case.GetAttribute('name'); Message = Get-FirstLine $(if ($message) { $message.InnerText } else { '' }) })
                }
                { $_ -in 'Ignored', 'Inconclusive' } { $row.Skipped++ }
            }
        }
        # A file that failed outside its tests: a parse error or a failed setup at file level.
        $ownFailure = $fileSuite.SelectSingleNode('failure/message')
        if ($null -ne $ownFailure) {
            $row.Failed++
            $failedTests.Add([pscustomobject]@{ Suite = $path; Name = $path; Message = Get-FirstLine $ownFailure.InnerText })
        }
        $suites.Add($row)
        $totals.Tests += $row.Tests
        $totals.Failed += $row.Failed
        $totals.Skipped += $row.Skipped
        $totals.Seconds += $row.Seconds
    }
    $totals.Passed = $totals.Tests - $totals.Skipped - $failedCases
    [void]$summary.AppendLine(('**{0} tests**: {1} passed, {2} failed, {3} skipped in {4} s.' -f $totals.Tests, $totals.Passed, $totals.Failed, $totals.Skipped, (Format-Number $totals.Seconds))).AppendLine()
    [void]$summary.AppendLine('| Suite | Tests | Failed | Skipped | Seconds |').AppendLine('|---|---|---|---|---|')
    foreach ($row in $suites) {
        [void]$summary.AppendLine(('| `{0}` | {1} | {2} | {3} | {4} |' -f (Format-TableCell $row.Suite), $row.Tests, $row.Failed, $row.Skipped, (Format-Number $row.Seconds)))
    }
    [void]$summary.AppendLine()
    if (-not $NoAnnotations) {
        foreach ($failed in $failedTests) {
            Add-Annotation -Context $ctx -Command error -File $failed.Suite -Message "$($failed.Name): $($failed.Message)"
        }
    }
}

# 2. Coverage
$files = [System.Collections.Generic.List[object]]::new()
$coverageTotals = $null
[void]$summary.AppendLine('## Coverage').AppendLine()
$coverageFile = if ([string]::IsNullOrEmpty($CoveragePath)) { '' } else { Resolve-ActionPath $CoveragePath }
if ([string]::IsNullOrEmpty($coverageFile) -or -not (Test-Path -LiteralPath $coverageFile -PathType Leaf)) {
    $name = if ([string]::IsNullOrEmpty($CoveragePath)) { 'coverage.xml' } else { Split-Path -Leaf $CoveragePath }
    [void]$summary.AppendLine("No coverage report ($name not found).").AppendLine()
} else {
    $report = Read-XmlFile -Path $coverageFile
    $newRow = {
        param([string]$File, $Counter)
        $covered = if ($Counter) { [int]$Counter.GetAttribute('covered') } else { 0 }
        $missed = if ($Counter) { [int]$Counter.GetAttribute('missed') } else { 0 }
        $percent = if ($covered + $missed -eq 0) { $null } else { 100.0 * $covered / ($covered + $missed) }
        return [pscustomobject]@{ File = $File; Covered = $covered; Missed = $missed; Percent = $percent }
    }
    foreach ($package in @($report.SelectNodes('/report/package'))) {
        foreach ($source in @($package.SelectNodes('sourcefile'))) {
            $file = ($package.GetAttribute('name') + '/' + $source.GetAttribute('name')).Replace('\', '/').TrimStart('/')
            $files.Add((& $newRow $file $source.SelectSingleNode("counter[@type='LINE']")))
        }
    }
    $sorted = [System.Collections.Generic.List[object]]::new($files)
    $sorted.Sort([System.Comparison[object]] { param($a, $b) [string]::CompareOrdinal($a.File, $b.File) })
    $files = $sorted
    $coverageTotals = & $newRow 'Total' $report.SelectSingleNode("/report/counter[@type='LINE']")
    [void]$summary.AppendLine('Line coverage of the files Pester ran; a report, not a gate (D51).').AppendLine()
    [void]$summary.AppendLine('| File | Covered | Missed | Percent |').AppendLine('|---|---|---|---|')
    foreach ($row in @($files) + @($coverageTotals)) {
        $percent = if ($null -eq $row.Percent) { '-' } else { Format-Number $row.Percent }
        $name = if ($row -eq $coverageTotals) { '**Total**' } else { '`' + (Format-TableCell $row.File) + '`' }
        [void]$summary.AppendLine(('| {0} | {1} | {2} | {3} |' -f $name, $row.Covered, $row.Missed, $percent))
    }
    [void]$summary.AppendLine()
}

$text = $summary.ToString().Replace("`r`n", "`n")
if ([string]::IsNullOrEmpty($SummaryPath)) {
    Write-Host $text
} else {
    Write-Text -Path $SummaryPath -Text $text
}

[pscustomobject]@{
    Suites         = $suites.ToArray()
    Totals         = $totals
    Files          = @($files)
    CoverageTotals = $coverageTotals
    FailedTests    = $failedTests.ToArray()
    Summary        = $text
}
