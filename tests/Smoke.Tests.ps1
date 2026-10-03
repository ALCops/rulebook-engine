Describe 'Smoke' {
    It 'runs on PowerShell 7 or later' {
        $PSVersionTable.PSVersion.Major | Should-BeGreaterThanOrEqual 7
    }

    It 'runs on Linux when executed in CI' -Skip:(-not $env:CI) {
        $IsLinux | Should-BeTrue
    }
}
