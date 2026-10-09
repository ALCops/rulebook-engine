# Documentation suite for WP11 (#13): every Markdown page of the engine (README.md, CONTRIBUTING.md, docs/**) and of
# the organization documentation in ALCops/rulebook (README.md, docs/**) has relative links that resolve and fenced
# JSON that parses; every user page in docs/ except README.md has the Status line, a Contents section whose entries
# name headings, and a final troubleshooting table. The user documentation is found through RULEBOOK_DOCS_PATH, else a
# sibling clone ../rulebook of this repository (ci.yml clones ALCops/rulebook@main there); without either it is skipped.
# The checks are in tests/Helpers/MarkdownCheck.ps1; each page is read once, during discovery.

BeforeDiscovery {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $PSScriptRoot 'Helpers' 'MarkdownCheck.ps1')

    # The troubleshooting rule of the user pages is pending until PR B of WP11 (#13) brings the existing pages to the
    # required shape (overrides.md has no troubleshooting section, ghtokenworkflow.md and hosting.md name theirs
    # differently, hosting.md and quarantine.md have two-column tables). PR B sets this to $false.
    $troubleshootingPending = $true

    $userRoot = $null
    $userReason = $null
    if (-not [string]::IsNullOrWhiteSpace($env:RULEBOOK_DOCS_PATH)) {
        $userRoot = $env:RULEBOOK_DOCS_PATH
        if (-not (Test-Path -LiteralPath (Join-Path $userRoot 'docs' 'README.md') -PathType Leaf)) {
            throw "RULEBOOK_DOCS_PATH is '$userRoot', which holds no docs/README.md; point it at a clone of ALCops/rulebook."
        }
        $userRoot = (Resolve-Path -LiteralPath $userRoot).ProviderPath
    } else {
        $sibling = Join-Path (Split-Path -Parent $repoRoot) 'rulebook'
        if (Test-Path -LiteralPath (Join-Path $sibling 'docs' 'README.md') -PathType Leaf) {
            $userRoot = (Resolve-Path -LiteralPath $sibling).ProviderPath
        } else {
            $userReason = "no user documentation: set RULEBOOK_DOCS_PATH to a clone of ALCops/rulebook, or clone it next to this repository as ../rulebook"
        }
    }

    function Get-PageCase {
        param([string]$Root, [string[]]$Files, [switch]$User)
        foreach ($file in $Files) {
            $text = [System.IO.File]::ReadAllText($file)
            $relative = [System.IO.Path]::GetRelativePath($Root, $file).Replace('\', '/')
            $shaped = $User -and $relative -like 'docs/*' -and $relative -cne 'docs/README.md'
            # Typed assignments: an if expression would unroll the results.
            [string[]]$troubleshooting = @()
            [string[]]$shape = @()
            if ($shaped) {
                [string[]]$troubleshooting = @(Test-MarkdownTroubleshooting -Text $text)
                [string[]]$shape = @(Test-MarkdownShape -Text $text)
            }
            [string[]]$broken = @(Test-MarkdownLink -Root $Root -Path $file -Text $text)
            [string[]]$badJson = @(Test-MarkdownJson -Text $text)
            @{ Page = $relative; Broken = $broken; BadJson = $badJson; Shaped = $shaped; Troubleshooting = $troubleshooting; Shape = $shape }
        }
    }

    [string[]]$engineFiles = @(
        (Join-Path $repoRoot 'README.md')
        (Join-Path $repoRoot 'CONTRIBUTING.md')
        Get-ChildItem -LiteralPath (Join-Path $repoRoot 'docs') -Recurse -File -Filter '*.md' | Sort-Object FullName | ForEach-Object FullName
    )
    $script:roots = @(@{ Name = 'engine'; Pages = @(Get-PageCase -Root $repoRoot -Files $engineFiles); Pending = $false })
    if ($null -ne $userRoot) {
        [string[]]$userFiles = @(
            (Join-Path $userRoot 'README.md')
            Get-ChildItem -LiteralPath (Join-Path $userRoot 'docs') -Recurse -File -Filter '*.md' | Sort-Object FullName | ForEach-Object FullName
        )
        $script:roots += @{ Name = 'user documentation'; Pages = @(Get-PageCase -Root $userRoot -Files $userFiles -User); Pending = $troubleshootingPending }
    }
    $script:userMissing = @(if ($null -eq $userRoot) { @{ Reason = $userReason } })
}

Describe 'Documentation pages' {
    Context '<Name>' -ForEach $roots {
        It '<Page>: relative links resolve' -ForEach $Pages {
            $Broken | Should-BeCollection @()
        }

        It '<Page>: fenced JSON parses' -ForEach $Pages {
            $BadJson | Should-BeCollection @()
        }

        It '<Page>: troubleshooting section present' -ForEach @($Pages | Where-Object { $_.Shaped }) -AllowNullOrEmptyForEach {
            if ($Pending) { Set-ItResult -Skipped -Because 'pending until PR B of WP11 (#13) brings the existing user pages to the troubleshooting shape' }
            $Troubleshooting | Should-BeCollection @()
        }

        It '<Page>: user-page shape' -ForEach @($Pages | Where-Object { $_.Shaped }) -AllowNullOrEmptyForEach {
            $Shape | Should-BeCollection @()
        }
    }

    It 'checks the user documentation' -ForEach $userMissing -AllowNullOrEmptyForEach {
        Set-ItResult -Skipped -Because $Reason
    }
}

Describe 'Markdown checks' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'Helpers' 'MarkdownCheck.ps1')
        $script:root = Join-Path $TestDrive 'site'
        $null = New-Item -ItemType Directory -Path (Join-Path $root 'docs' 'images') -Force
        foreach ($file in 'docs/other.md', 'docs/images/a b.png', 'README.md') { [System.IO.File]::WriteAllText((Join-Path $root $file), 'x') }
        $script:page = Join-Path $root 'docs' 'page.md'
    }

    It 'finds a missing file, a missing heading and nothing else' {
        $text = @(
            '# Page', '', '## 1. Some `code` here', ''
            '[ok](other.md#anything) ![ok](images/a%20b.png) [ok](../README.md) [ok](/README.md) [ok](#1-some-code-here) [ok](images/)'
            '[gone](missing.md) [gone](#2-nothing) [web](https://example.com/x.md) [mail](mailto:a@b.c)'
            '`[code](ignored.md)`', '', '```', '[fenced](ignored.md)', '```'
            '[ref]: ./also-missing.md'
        ) -join "`n"
        Test-MarkdownLink -Root $root -Path $page -Text $text | Should-BeCollection @('missing.md', '#2-nothing (no such heading on this page)', './also-missing.md')
    }

    It 'numbers repeated headings the way GitHub does' {
        $anchors = Get-MarkdownAnchor -Text "## Notes`n## Notes`n## Route B: suppressWarnings in ``app.json```n"
        foreach ($anchor in 'notes', 'notes-1', 'route-b-suppresswarnings-in-appjson') { $anchors.Contains($anchor) | Should-BeTrue -Because $anchor }
    }

    It 'parses JSON blocks, split at // lines, an excerpt of an object wrapped in braces' {
        $text = @(
            '```json', '{ "a": 1 }', '```'
            '```json', '// one.json', '{ "a": 1 }', '// two.json', '{ "b": 2 }', '```'
            '```json', '"update": { "schedule": null }', '```'
            '```json', '{ "a": 1, }', '```'
        ) -join "`n"
        Test-MarkdownJson -Text $text | Should-BeCollection @('json block 4 ({ "a": 1, } ...)')
    }

    It 'wants the troubleshooting table with three columns' {
        Test-MarkdownTroubleshooting -Text "## 1. A`n`n## 2. Troubleshooting`n`n| Symptom | Cause | Fix |`n|---|---|---|`n" | Should-BeCollection @()
        Test-MarkdownTroubleshooting -Text "## 2. Troubleshooting`n`n| Message | What to do |`n" | Should-BeCollection @("the troubleshooting table header is '| Message | What to do |', not | Message (or Symptom) | Cause | Fix |")
        Test-MarkdownTroubleshooting -Text "## 2. When it fails`n" | Should-BeCollection @('no "## N. Troubleshooting" section')
    }

    It 'wants the Status line and Contents entries that name headings' {
        $good = "# P`n`n> **Status:** written.`n`n## Contents`n`n1. [One](#1-one)`n`n## 1. One`n"
        Test-MarkdownShape -Text $good | Should-BeCollection @()
        Test-MarkdownShape -Text $good.Replace('(#1-one)', '(#1-two)').Replace('> **Status:**', '> Status:') | Should-BeCollection @('no "> **Status:**" line', 'Contents entry #1-two names no heading of this page')
    }
}
