# Common suite for #78: modules/Rulebook.Common, the git runner and the ordinal collections several engine modules
# share. The git cases run against repositories in TestDrive (tests/Helpers/RepoFixture.ps1) and are skipped without
# git.

BeforeDiscovery {
    $script:gitMissing = $null -eq (Get-Command git -ErrorAction SilentlyContinue)
}

BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $PSScriptRoot 'Helpers' 'RepoFixture.ps1')
    Import-Module (Join-Path $repoRoot 'modules' 'Rulebook.Common.psd1') -Force

    function Get-TestFolder {
        $folder = Join-Path $TestDrive ([guid]::NewGuid().ToString('n').Substring(0, 12))
        $null = New-Item -ItemType Directory -Path $folder
        return $folder
    }
}

AfterAll {
    Remove-Module Rulebook.Common -ErrorAction SilentlyContinue
}

Describe 'Invoke-Git' -Skip:$gitMissing {
    BeforeAll {
        $script:root = Get-TestFolder
        Write-FixtureText -Path (Join-Path $root 'README.md') -Text "fixture`n"
        $script:head = New-FixtureGitRepo -Root $root -Message 'first'
    }

    It 'returns exit code 0 and the output' {
        $result = Invoke-Git -Root $root -Arguments @('rev-parse', 'HEAD')
        $result.ExitCode | Should-Be 0
        $result.Output.Trim() | Should-Be $head
    }

    It 'decodes UTF-8 output independent of the console code page' {
        $unicodeRoot = Get-TestFolder
        $null = New-FixtureGitRepo -Root $unicodeRoot -Message 'Ünïcödé ✓'
        $result = Invoke-Git -Root $unicodeRoot -Arguments @('log', '-1', '--format=%s')
        $result.ExitCode | Should-Be 0
        $result.Output.Trim() | Should-Be 'Ünïcödé ✓'
    }

    It 'returns a non-zero exit code with the error text and does not throw' {
        $result = Invoke-Git -Root $root -Arguments @('show', 'no-such-ref')
        $result.ExitCode | Should-NotBe 0
        $result.Error | Should-BeLikeString '*no-such-ref*'
    }

    It 'sets -Environment for that git process only' {
        $saved = $env:GIT_CONFIG_COUNT
        $env:GIT_CONFIG_COUNT = $null
        try {
            $environment = [ordered]@{ GIT_CONFIG_COUNT = '1'; GIT_CONFIG_KEY_0 = 'rulebook.probe'; GIT_CONFIG_VALUE_0 = 'from-environment' }
            $result = Invoke-Git -Root $root -Arguments @('config', '--get', 'rulebook.probe') -Environment $environment
            $result.ExitCode | Should-Be 0
            $result.Output.Trim() | Should-Be 'from-environment'
            $env:GIT_CONFIG_COUNT | Should-BeNull
            $env:GIT_CONFIG_KEY_0 | Should-BeNull
        } finally {
            $env:GIT_CONFIG_COUNT = $saved
        }
    }

    It 'starts git with -C and the root first and without a credential prompt' {
        $info = InModuleScope Rulebook.Common { New-GitStartInfo -Root 'some/root' -Arguments @('status') }
        $info.FileName | Should-Be 'git'
        @($info.ArgumentList) | Should-BeCollection @('-C', 'some/root', 'status')
        $info.Environment['GIT_TERMINAL_PROMPT'] | Should-Be '0'
    }
}

Describe 'Get-OrdinalMap' {
    It 'keeps AL0001 and al0001 as two keys' {
        $map = Get-OrdinalMap
        $map['AL0001'] = 'upper'
        $map['al0001'] = 'lower'
        $map.Count | Should-Be 2
        $map['AL0001'] | Should-Be 'upper'
        $map['al0001'] | Should-Be 'lower'
    }

    It 'keeps the insertion order' {
        $map = Get-OrdinalMap
        foreach ($key in 'PTE0001', 'AA0001', 'LC0001') { $map[$key] = $key.Length }
        @($map.Keys) | Should-BeCollection @('PTE0001', 'AA0001', 'LC0001')
    }

    It 'returns an empty map, not $null' {
        $map = Get-OrdinalMap
        $map | Should-HaveType ([System.Collections.Specialized.OrderedDictionary])
        $map.Count | Should-Be 0
    }
}

Describe 'Get-OrdinalSet' {
    It 'returns an empty set, not $null, <Case>' -ForEach @(
        @{ Case = 'without -Items'; Splat = @{} }
        @{ Case = 'with $null'; Splat = @{ Items = $null } }
        @{ Case = 'with an empty array'; Splat = @{ Items = @() } }
    ) {
        $set = Get-OrdinalSet @Splat
        $null -eq $set | Should-BeFalse
        Should-HaveType -Actual $set -Expected ([System.Collections.Generic.HashSet[string]])
        $set.Count | Should-Be 0
    }

    It 'compares members case-sensitively' {
        $set = Get-OrdinalSet -Items @('AL0001')
        $set.Contains('AL0001') | Should-BeTrue
        $set.Contains('al0001') | Should-BeFalse
    }

    It 'drops null items and duplicates' {
        $set = Get-OrdinalSet -Items @('AA0001', $null, 'AA0001', 'aa0001')
        $set.Count | Should-Be 2
        $set.Contains('AA0001') | Should-BeTrue
        $set.Contains('aa0001') | Should-BeTrue
    }
}
