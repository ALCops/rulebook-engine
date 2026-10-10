# Suite for tools/ci/Write-TestSummary.ps1 (WP12, #14, D51): the Pester and coverage tables of the CI job summary and
# the error annotations, on trimmed real captures in tests/fixtures/ci/ (NUnit 2.5 and JaCoCo as Pester 6 writes them).
# The script runs in-process; its suite paths in the fixture start with /repo, the -RepositoryRoot of every case.

BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:entry = Join-Path $repoRoot 'tools' 'ci' 'Write-TestSummary.ps1'
    $script:fixtures = Join-Path $PSScriptRoot 'fixtures' 'ci'
    $script:results = Join-Path $fixtures 'testResults.xml'
    $script:coverage = Join-Path $fixtures 'coverage.xml'
    $script:savedSummary = $env:GITHUB_STEP_SUMMARY
    $env:GITHUB_STEP_SUMMARY = $null

    function Get-TestFolder {
        $folder = Join-Path $TestDrive ([guid]::NewGuid().ToString('n').Substring(0, 12))
        $null = New-Item -ItemType Directory -Path $folder
        return $folder
    }

    function Invoke-Entry {
        # Runs the script in-process; returns its result object and the host lines (annotations, the printed summary).
        param([hashtable]$Parameters)
        if (-not $Parameters.ContainsKey('RepositoryRoot')) { $Parameters.RepositoryRoot = '/repo' }
        if (-not $Parameters.ContainsKey('SummaryPath')) { $Parameters.SummaryPath = Join-Path (Get-TestFolder) 'summary.md' }
        $output = @(& $script:entry @Parameters 6>&1)
        return [pscustomobject]@{
            Result = $output | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] } | Select-Object -Last 1
            Lines  = @($output | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { [string]$_.MessageData })
            Path   = $Parameters.SummaryPath
        }
    }
}

AfterAll {
    $env:GITHUB_STEP_SUMMARY = $script:savedSummary
    Remove-Module Rulebook.Action -ErrorAction SilentlyContinue
}

Describe 'Write-TestSummary.ps1 Pester section' {
    It 'writes one row per suite and the totals line' {
        $run = Invoke-Entry @{ TestResultsPath = $results; CoveragePath = $coverage }
        @($run.Result.Suites | ForEach-Object { '{0} {1} {2} {3}' -f $_.Suite, $_.Tests, $_.Failed, $_.Skipped }) | Should-BeCollection @(
            'tests/Smoke.Tests.ps1 2 0 1'
            'tests/Rulebook.Action.Tests.ps1 3 1 1'
            'tests/Rulebook.Common.Tests.ps1 2 0 0'
        )
        $run.Result.Totals.Tests | Should-Be 7
        $run.Result.Totals.Passed | Should-Be 4
        $run.Result.Totals.Failed | Should-Be 1
        $run.Result.Totals.Skipped | Should-Be 2
        $run.Result.Summary | Should-MatchString '(?m)^## Pester\n\n\*\*7 tests\*\*: 4 passed, 1 failed, 2 skipped in 2\.5 s\.\n\n\| Suite \| Tests \| Failed \| Skipped \| Seconds \|\n\|---\|---\|---\|---\|---\|\n'
        $run.Result.Summary | Should-MatchString '(?m)^\| `tests/Rulebook\.Action\.Tests\.ps1` \| 3 \| 1 \| 1 \| 1\.2 \|$'
    }

    It 'counts an ignored test as skipped' {
        $run = Invoke-Entry @{ TestResultsPath = $results; CoveragePath = '' }
        ($run.Result.Suites | Where-Object Suite -EQ 'tests/Smoke.Tests.ps1').Skipped | Should-Be 1
        $run.Result.Summary | Should-MatchString '(?m)^\| `tests/Smoke\.Tests\.ps1` \| 2 \| 0 \| 1 \| 0\.6 \|$'
    }

    It 'writes one error annotation per failed test with the relative suite path and the first message line escaped' {
        $run = Invoke-Entry @{ TestResultsPath = $results; CoveragePath = $coverage }
        @($run.Lines | Where-Object { $_ -like '::*' }) | Should-BeCollection @(
            '::error file=tests/Rulebook.Action.Tests.ps1,title=Pester::ConvertTo-SingleLine.keeps a percent sign: RuntimeException: 100%25 broken: first line'
        )
        $run.Result.FailedTests[0].Message | Should-Be 'RuntimeException: 100% broken: first line'
    }

    It 'writes no annotation with -NoAnnotations' {
        $run = Invoke-Entry @{ TestResultsPath = $results; CoveragePath = $coverage; NoAnnotations = $true }
        @($run.Lines | Where-Object { $_ -like '::*' }) | Should-BeCollection @()
        $run.Result.FailedTests.Count | Should-Be 1
    }

    It 'counts a file that failed outside its tests as one failed test of that file' {
        $folder = Get-TestFolder
        $broken = Join-Path $folder 'testResults.xml'
        $xml = @'
<?xml version="1.0" encoding="utf-8" standalone="no"?>
<test-results name="Pester" total="0">
  <test-suite type="TestFixture" name="Pester" executed="True" result="Failure" success="False" time="0.012">
    <results>
      <test-suite type="TestFixture" name="/repo/tests/Broken.Tests.ps1" executed="True" result="Failure" success="False" time="0.012">
        <failure>
          <message>ParseException: At /repo/tests/Broken.Tests.ps1:1 char:18
Missing closing '}' in statement block or type definition.</message>
          <stack-trace />
        </failure>
        <results />
      </test-suite>
    </results>
  </test-suite>
</test-results>
'@
        [System.IO.File]::WriteAllText($broken, $xml.Replace("`r`n", "`n"))
        $run = Invoke-Entry @{ TestResultsPath = $broken; CoveragePath = '' }
        $run.Result.Totals.Failed | Should-Be 1
        $run.Result.Totals.Passed | Should-Be 0
        @($run.Lines | Where-Object { $_ -like '::*' }) | Should-BeCollection @('::error file=tests/Broken.Tests.ps1,title=Pester::tests/Broken.Tests.ps1: ParseException: At /repo/tests/Broken.Tests.ps1:1 char:18')
    }

    It 'reports a missing results file in the summary without throwing or exiting' {
        $missing = Join-Path (Get-TestFolder) 'testResults.xml'
        $run = Invoke-Entry @{ TestResultsPath = $missing; CoveragePath = $coverage }
        $run.Result | Should-NotBeNull
        $run.Result.Suites.Count | Should-Be 0
        $run.Result.Summary | Should-MatchString '(?m)^No test results \(testResults\.xml not found\)\.$'
        $run.Result.Summary | Should-MatchString '(?m)^## Coverage$'
        @($run.Lines | Where-Object { $_ -like '::*' }) | Should-BeCollection @()
    }
}

Describe 'Write-TestSummary.ps1 Coverage section' {
    It 'lists the files in ordinal order with the line counts and the totals row last' {
        $run = Invoke-Entry @{ TestResultsPath = $results; CoveragePath = $coverage }
        @($run.Result.Files | ForEach-Object File) | Should-BeCollection @('modules/Rulebook.Action.psm1', 'modules/Rulebook.Common.psm1', 'scripts/New-RulebookOffLevel.ps1')
        $run.Result.CoverageTotals.Covered | Should-Be 6
        $run.Result.CoverageTotals.Missed | Should-Be 6
        $table = "| File | Covered | Missed | Percent |`n|---|---|---|---|`n" +
        "| ``modules/Rulebook.Action.psm1`` | 2 | 1 | 66.7 |`n" +
        "| ``modules/Rulebook.Common.psm1`` | 4 | 0 | 100.0 |`n" +
        "| ``scripts/New-RulebookOffLevel.ps1`` | 0 | 5 | 0.0 |`n" +
        "| **Total** | 6 | 6 | 50.0 |`n"
        $run.Result.Summary.Contains($table) | Should-BeTrue
    }

    It 'says there is no coverage report when -CoveragePath is <Case>' -ForEach @(
        @{ Case = 'empty'; Path = ''; Name = 'coverage.xml' }
        @{ Case = 'a missing file'; Path = 'missing/cover.xml'; Name = 'cover.xml' }
    ) {
        $path = if ($Path) { Join-Path (Get-TestFolder) $Path } else { '' }
        $run = Invoke-Entry @{ TestResultsPath = $results; CoveragePath = $path }
        $run.Result.Files.Count | Should-Be 0
        $run.Result.CoverageTotals | Should-BeNull
        $run.Result.Summary | Should-MatchString "(?m)^No coverage report \($([regex]::Escape($Name)) not found\)\.$"
    }
}

Describe 'Write-TestSummary.ps1 output' {
    It 'appends to -SummaryPath and keeps what is there' {
        $path = Join-Path (Get-TestFolder) 'summary.md'
        [System.IO.File]::WriteAllText($path, "# Earlier step`n`n")
        $run = Invoke-Entry @{ TestResultsPath = $results; CoveragePath = $coverage; SummaryPath = $path }
        $text = [System.IO.File]::ReadAllText($path)
        $text | Should-Be ("# Earlier step`n`n" + $run.Result.Summary)
        @($run.Lines | Where-Object { $_ -like '## *' -or $_ -like '*## Pester*' }) | Should-BeCollection @()
    }

    It 'appends to GITHUB_STEP_SUMMARY by default' {
        $path = Join-Path (Get-TestFolder) 'step-summary.md'
        $env:GITHUB_STEP_SUMMARY = $path
        try {
            $output = @(& $script:entry -TestResultsPath $results -CoveragePath $coverage -RepositoryRoot '/repo' -NoAnnotations 6>&1)
        } finally {
            $env:GITHUB_STEP_SUMMARY = $null
        }
        $result = $output | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] } | Select-Object -Last 1
        [System.IO.File]::ReadAllText($path) | Should-Be $result.Summary
    }

    It 'prints the Markdown to the host without a summary path' {
        $run = Invoke-Entry @{ TestResultsPath = $results; CoveragePath = $coverage; SummaryPath = ''; NoAnnotations = $true }
        ($run.Lines -join "`n") | Should-MatchString '(?m)^## Pester$'
        ($run.Lines -join "`n") | Should-MatchString '(?m)^## Coverage$'
    }
}

Describe 'Write-TestSummary.ps1 parameter binding' {
    It 'rejects a stray positional value' {
        # PositionalBinding = $false (#61): every caller binds by name.
        { & $script:entry -TestResultsPath $results 'stray' } | Should-Throw -ExceptionType ([System.Management.Automation.ParameterBindingException]) -ExceptionMessage '*positional parameter*stray*'
    }
}
