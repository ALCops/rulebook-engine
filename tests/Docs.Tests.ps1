# Documentation suite for WP11 (#13): every Markdown page of the engine (README.md, CONTRIBUTING.md, docs/**) and of
# the organization documentation in ALCops/rulebook (README.md, docs/**) has relative links that resolve and fenced
# JSON that parses; every user page in docs/ except README.md has the Status line, a Contents section whose entries
# name headings, and a final troubleshooting table. The user documentation is found through RULEBOOK_DOCS_PATH, else a
# sibling clone ../rulebook of this repository (ci.yml clones ALCops/rulebook@main there); without either, or when the
# folder holds no docs/README.md (a failed clone), it is skipped with the reason. template/README.md ships into the
# organization repository next to the user docs/ (WP13), so its relative links resolve in template/ with the user
# documentation laid over it.
# The checks are in tests/Helpers/MarkdownCheck.ps1; each page is read once, during discovery.

BeforeDiscovery {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $PSScriptRoot 'Helpers' 'MarkdownCheck.ps1')

    # The troubleshooting rule of the user pages is on since PR B of WP11 (#13, ALCops/rulebook#8) brought every user
    # page to the required shape; $true skips it with the reason below.
    $troubleshootingPending = $false

    $userRoot = $null
    $userReason = $null
    if (-not [string]::IsNullOrWhiteSpace($env:RULEBOOK_DOCS_PATH)) {
        if (Test-Path -LiteralPath (Join-Path $env:RULEBOOK_DOCS_PATH 'docs' 'README.md') -PathType Leaf) {
            $userRoot = (Resolve-Path -LiteralPath $env:RULEBOOK_DOCS_PATH).ProviderPath
        } else {
            $userReason = "RULEBOOK_DOCS_PATH is '$($env:RULEBOOK_DOCS_PATH)', which holds no docs/README.md (the clone failed, or the variable points at the wrong folder)"
        }
    } else {
        $sibling = Join-Path (Split-Path -Parent $repoRoot) 'rulebook'
        if (Test-Path -LiteralPath (Join-Path $sibling 'docs' 'README.md') -PathType Leaf) {
            $userRoot = (Resolve-Path -LiteralPath $sibling).ProviderPath
        } else {
            $userReason = "no user documentation: set RULEBOOK_DOCS_PATH to a clone of ALCops/rulebook, or clone it next to this repository as ../rulebook"
        }
    }

    function Get-PageCase {
        param([string]$Root, [string[]]$Files, [switch]$User, [string[]]$Overlay = @(), [string[]]$Pending = @(), [string]$Name, [switch]$NoEscape)
        foreach ($file in $Files) {
            $text = [System.IO.File]::ReadAllText($file)
            $relative = if ($Name) { $Name } else { [System.IO.Path]::GetRelativePath($Root, $file).Replace('\', '/') }
            $shaped = $User -and $relative -like 'docs/*' -and $relative -cne 'docs/README.md'
            # Typed assignments: an if expression would unroll the results.
            [string[]]$troubleshooting = @()
            [string[]]$shape = @()
            if ($shaped) {
                [string[]]$troubleshooting = @(Test-MarkdownTroubleshooting -Text $text)
                [string[]]$shape = @(Test-MarkdownShape -Text $text)
            }
            [string[]]$broken = @(Test-MarkdownLink -Root $Root -Path $file -Text $text -Overlay $Overlay -Pending $Pending -NoEscape:$NoEscape)
            [string[]]$badJson = @(Test-MarkdownJson -Text $text)
            @{ Page = $relative; Broken = $broken; BadJson = $badJson; Shaped = $shaped; Troubleshooting = $troubleshooting; Shape = $shape }
        }
    }

    [string[]]$engineFiles = @(
        (Join-Path $repoRoot 'README.md')
        (Join-Path $repoRoot 'CONTRIBUTING.md')
        Get-ChildItem -LiteralPath (Join-Path $repoRoot 'docs') -Recurse -File -Filter '*.md' | Sort-Object FullName | ForEach-Object FullName
    )
    $templateRoot = Join-Path $repoRoot 'template'
    # A template page must not point outside template/ (it ships as the organization repository). Without the user
    # documentation its docs/* targets cannot be checked; everything else still is.
    $templateCase = @{
        Root = $templateRoot; Files = @(Join-Path $templateRoot 'README.md'); Name = 'template/README.md'; NoEscape = $true
        Overlay = @(if ($null -ne $userRoot) { $userRoot }); Pending = @(if ($null -eq $userRoot) { 'docs/*' })
    }
    $script:roots = @(@{ Name = 'engine'; Pages = @(Get-PageCase -Root $repoRoot -Files $engineFiles) + @(Get-PageCase @templateCase); Pending = $false })
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
            if ($Pending) { Set-ItResult -Skipped -Because 'the troubleshooting rule is switched off ($troubleshootingPending in BeforeDiscovery)' }
            $Troubleshooting | Should-BeCollection @()
        }

        It '<Page>: user-page shape' -ForEach @($Pages | Where-Object { $_.Shaped }) -AllowNullOrEmptyForEach {
            $Shape | Should-BeCollection @()
        }
    }

    It 'checks the user documentation' -ForEach $userMissing -AllowNullOrEmptyForEach {
        # A workflow annotation, so a failed clone in CI is visible on the run and not just a skipped test.
        Write-Host "::warning title=Docs.Tests::The user documentation was not checked: $Reason"
        Set-ItResult -Skipped -Because $Reason
    }
}

Describe 'Markdown checks' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'Helpers' 'MarkdownCheck.ps1')
        $script:root = Join-Path $TestDrive 'site'
        $null = New-Item -ItemType Directory -Path (Join-Path $root 'docs' 'images') -Force
        foreach ($file in 'docs/images/a b.png', 'docs/x(1).md', 'README.md') { [System.IO.File]::WriteAllText((Join-Path $root $file), 'x') }
        [System.IO.File]::WriteAllText((Join-Path $root 'docs' 'other.md'), "# Other`n`n## 2. The part`n")
        $script:page = Join-Path $root 'docs' 'page.md'
        $script:overlay = Join-Path $TestDrive 'overlay'
        $null = New-Item -ItemType Directory -Path (Join-Path $overlay 'docs') -Force
        [System.IO.File]::WriteAllText((Join-Path $overlay 'docs' 'laid-over.md'), "# Laid over`n")
    }

    It 'finds a missing file, a missing heading and nothing else' {
        $text = @(
            '# Page', '', '## 1. Some `code` here', ''
            '[ok](other.md) ![ok](images/a%20b.png) [ok](../README.md) [ok](/README.md) [ok](#1-some-code-here) [ok](images/)'
            '[gone](missing.md) [gone](#2-nothing) [web](https://example.com/x.md) [mail](mailto:a@b.c)'
            '`[code](ignored.md)`', '', '```', '[fenced](ignored.md)', '```'
            '[ref]: ./also-missing.md'
        ) -join "`n"
        Test-MarkdownLink -Root $root -Path $page -Text $text | Should-BeCollection @('missing.md', '#2-nothing (no such heading on this page)', './also-missing.md')
    }

    It 'balances one level of parentheses in a target' {
        Test-MarkdownLink -Root $root -Path $page -Text '[ok](x(1).md) [gone](y(2).md "title")' | Should-BeCollection @('y(2).md')
    }

    It 'checks the heading of a link to another page' {
        Test-MarkdownLink -Root $root -Path $page -Text '[ok](other.md#2-the-part) [gone](other.md#3-no-part) [image](images/a%20b.png#x)' | Should-BeCollection @('other.md#3-no-part (no such heading on that page)')
    }

    It 'resolves reference links through their definitions and reports a label without one' {
        $text = "[ok][good] [ok too][] [gone][bad] [missing][nowhere]`n`n[good]: other.md`n[ok too]: ../README.md`n[bad]: gone.md"
        Test-MarkdownLink -Root $root -Path $page -Text $text | Should-BeCollection @('gone.md', '[nowhere] (no reference definition)', 'gone.md')
    }

    It 'checks HTML a href and img src, and treats <x.md> in prose as no link' {
        $text = '<a href="other.md">ok</a> <img src="images/a b.png" alt="ok"> <a href="gone.md">x</a> <img src=''gone.png''> <your-file.json> <https://example.com/y.md> <br/>'
        Test-MarkdownLink -Root $root -Path $page -Text $text | Should-BeCollection @('gone.md', 'gone.png')
    }

    It 'checks an image nested in a link' {
        Test-MarkdownLink -Root $root -Path $page -Text '[![ok](images/a%20b.png)](other.md) [![b](gone.png)](other.md) ![top](gone-too.png)' | Should-BeCollection @('gone.png', 'gone-too.png')
    }

    It 'ignores footnote definitions' {
        Test-MarkdownLink -Root $root -Path $page -Text "Text.[^1]`n`n[^1]: See docs." | Should-BeCollection @()
    }

    It 'compares anchors case-sensitively, as GitHub writes them in lowercase' {
        Test-MarkdownLink -Root $root -Path $page -Text "# Top`n`n[ok](#top) [gone](#Top)" | Should-BeCollection @('#Top (no such heading on this page)')
    }

    It 'flags a target outside the root with -NoEscape and takes wildcards in -Pending' {
        Test-MarkdownLink -Root $root -Path (Join-Path $root 'README.md') -Text '[out](../outside.md) [up](docs/../../x.md) [later](docs/any.md) [in](docs/other.md)' -NoEscape -Pending @('docs/*') |
            Should-BeCollection @('../outside.md (outside the repository)', 'docs/../../x.md (outside the repository)')
    }

    It 'looks a path up in the overlay roots and tolerates pending pages' {
        $text = '[ok](laid-over.md) [pending](later.md) [gone](never.md)'
        Test-MarkdownLink -Root $root -Path $page -Text $text -Overlay @($overlay) -Pending @('docs/later.md') | Should-BeCollection @('never.md')
    }

    It 'numbers repeated headings the way GitHub does and keeps tag-like text in code spans' {
        $anchors = Get-MarkdownAnchor -Text "## Notes`n## Notes`n## Route B: suppressWarnings in ``app.json```n## Using ``List<T>```n## A <em>b</em> c`n"
        foreach ($anchor in 'notes', 'notes-1', 'route-b-suppresswarnings-in-appjson', 'using-listt', 'a-b-c') { $anchors.Contains($anchor) | Should-BeTrue -Because $anchor }
    }

    It 'parses JSON blocks, comment lines removed, an excerpt of an object wrapped in braces' {
        $text = @(
            '```json', '{ "a": 1 }', '```'
            '```json', '// one.json', '{ "a": 1 }', '// two.json', '{ "b": 2 }', '```'
            '```json', '"update": { "schedule": null }', '```'
            '```jsonc', '{', '  "a": 1,', '  // c', '  "b": 2', '}', '```'
            '~~~json title="settings"', '{ "c": [1, 2] }', '~~~'
            '```json', '{ "a": 1, }', '```'
        ) -join "`n"
        Test-MarkdownJson -Text $text | Should-BeCollection @('json block 6 ({ "a": 1, } ...)')
    }

    It 'reports an indented broken block and the invalid part of a split block' {
        $text = @(
            '1. A step:', '', '   ```json', '   { "a": }', '   ```'
            '```json', '// one.json', '{ "a": 1 }', '// two.json', '{ "b": 2', '```'
        ) -join "`n"
        Test-MarkdownJson -Text $text | Should-BeCollection @('json block 1 ({ "a": } ...)', 'json block 2 ({ "b": 2 ...)')
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
