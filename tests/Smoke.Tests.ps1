Describe 'Smoke' {
    It 'runs on PowerShell 7 or later' {
        $PSVersionTable.PSVersion.Major | Should-BeGreaterThanOrEqual 7
    }

    It 'runs on Linux when executed on GitHub Actions' -Skip:(-not $env:GITHUB_ACTIONS) {
        $IsLinux | Should-BeTrue
    }
}
