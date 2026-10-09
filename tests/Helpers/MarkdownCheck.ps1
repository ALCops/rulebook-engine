# Markdown checks of tests/Docs.Tests.ps1 (WP11, #13): relative links, heading anchors, fenced JSON, the
# troubleshooting table and the page shape. Dot-sourced in BeforeDiscovery; every function works on the text of one
# page, read once, and returns the problems as strings (nothing when the page passes).

function Get-MarkdownProse {
    # The page without fenced code blocks (``` or ~~~, the closing fence at least as long) and, unless
    # -KeepInlineCode, without inline code spans; line count kept, so a link example inside code is never checked.
    # Headings keep their inline code (GitHub drops only the backticks from the anchor).
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [switch]$KeepInlineCode)
    $lines = $Text.Replace("`r`n", "`n").Split("`n")
    $fence = $null
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $marker = [regex]::Match($lines[$i], '^[ ]{0,3}(`{3,}|~{3,})')
        if ($null -ne $fence) {
            if ($marker.Success -and $marker.Groups[1].Value[0] -ceq $fence[0] -and $marker.Groups[1].Value.Length -ge $fence.Length -and $lines[$i].Trim() -ceq $marker.Groups[1].Value) { $fence = $null }
            $lines[$i] = ''
            continue
        }
        if ($marker.Success) {
            $fence = $marker.Groups[1].Value
            $lines[$i] = ''
            continue
        }
        # Inline code: a run of backticks up to the same run.
        if (-not $KeepInlineCode) { $lines[$i] = [regex]::Replace($lines[$i], '(`+)(?:(?!\1).)+?\1', '') }
    }
    return ($lines -join "`n")
}

function ConvertTo-HeadingSlug {
    # The anchor GitHub gives a heading: links reduced to their text, HTML tags removed, lowercase, every character
    # other than a letter, a digit, a mark, '_', '-' or a space removed, spaces to '-'.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Heading)
    $text = [regex]::Replace($Heading, '!?\[([^\]]*)\]\([^)]*\)', '$1')
    $text = [regex]::Replace($text, '<[^>]+>', '')
    $text = $text.ToLowerInvariant()
    $text = [regex]::Replace($text, '[^\p{L}\p{N}\p{M}_\- ]', '')
    return $text.Replace(' ', '-')
}

function Get-MarkdownAnchor {
    # Every anchor of a page: the heading slugs (a repeated slug gets -1, -2, ...) and explicit <a name|id="...">.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $Prose = Get-MarkdownProse -Text $Text -KeepInlineCode
    $anchors = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $seen = @{}
    foreach ($match in [regex]::Matches($Prose, '(?m)^[ ]{0,3}#{1,6}[ \t]+(.+?)[ \t]*#*[ \t]*$')) {
        $slug = ConvertTo-HeadingSlug -Heading $match.Groups[1].Value
        if ($seen.ContainsKey($slug)) {
            $seen[$slug]++
            [void]$anchors.Add("$slug-$($seen[$slug])")
        } else {
            $seen[$slug] = 0
            [void]$anchors.Add($slug)
        }
    }
    foreach ($match in [regex]::Matches($Prose, '<a\s+(?:name|id)="([^"]+)"')) { [void]$anchors.Add($match.Groups[1].Value) }
    return , $anchors
}

function Get-MarkdownLinkTarget {
    # The targets of inline links and images ([text](target), ![alt](target), an optional "title") and of reference
    # definitions ([label]: target), in page order.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Prose)
    $targets = [System.Collections.Generic.List[string]]::new()
    foreach ($match in [regex]::Matches($Prose, '!?\[(?:[^\[\]]|\[[^\[\]]*\])*\]\(\s*(?:<([^>]*)>|([^\s)]+))(?:\s+(?:"[^"]*"|''[^'']*''))?\s*\)')) {
        $targets.Add($(if ($match.Groups[1].Success) { $match.Groups[1].Value } else { $match.Groups[2].Value }))
    }
    foreach ($match in [regex]::Matches($Prose, '(?m)^[ ]{0,3}\[[^\]]+\]:[ \t]*<?([^\s>]+)>?')) { $targets.Add($match.Groups[1].Value) }
    return , $targets.ToArray()
}

function Test-MarkdownLink {
    # The broken relative links of the page -Path under -Root: a target without a scheme whose file or folder does not
    # exist (fragment stripped, URL-decoded, relative to the page's folder, or to -Root with a leading '/'), and a
    # '#fragment' link that names no anchor of the page itself.
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text
    )
    $Prose = Get-MarkdownProse -Text $Text
    $broken = [System.Collections.Generic.List[string]]::new()
    $anchors = $null
    $folder = Split-Path -Parent $Path
    foreach ($target in (Get-MarkdownLinkTarget -Prose $Prose)) {
        if ($target -match '^[A-Za-z][A-Za-z0-9+.-]*:' -or $target -like '//*') { continue }
        if ($target.StartsWith('#')) {
            if ($null -eq $anchors) { $anchors = Get-MarkdownAnchor -Text $Text }
            $fragment = [System.Uri]::UnescapeDataString($target.Substring(1))
            if (-not $anchors.Contains($fragment)) { $broken.Add("$target (no such heading on this page)") }
            continue
        }
        $relative = [System.Uri]::UnescapeDataString(($target -split '[#?]', 2)[0])
        if ($relative -eq '') { continue }
        $full = if ($relative.StartsWith('/')) { Join-Path $Root $relative.TrimStart('/') } else { Join-Path $folder $relative }
        if (-not (Test-Path -LiteralPath $full)) { $broken.Add($target) }
    }
    return $broken.ToArray()
}

function Test-MarkdownJson {
    # The fenced json blocks (a ```json line at the start of a line up to the next ``` line) that do not parse. A line
    # starting with // names the file of the part below it: the block is split there and each part parsed on its own.
    # A part that is an excerpt of an object (one or more "key": value pairs, as the settings pages show) parses
    # when wrapped in braces.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $failures = [System.Collections.Generic.List[string]]::new()
    $test = { param([string]$Json) try { return [bool](Test-Json -Json $Json -ErrorAction Stop) } catch { return $false } }
    $index = 0
    foreach ($match in [regex]::Matches($Text.Replace("`r`n", "`n"), '(?ms)^```json\n(.*?)^```')) {
        $index++
        $parts = [System.Collections.Generic.List[string]]::new()
        $current = [System.Collections.Generic.List[string]]::new()
        foreach ($line in $match.Groups[1].Value.Split("`n")) {
            if ($line -match '^\s*//') {
                if (($current -join '').Trim()) { $parts.Add(($current -join "`n")) }
                $current.Clear()
            } else {
                $current.Add($line)
            }
        }
        if (($current -join '').Trim()) { $parts.Add(($current -join "`n")) }
        foreach ($part in $parts) {
            if ((& $test $part) -or ($part.TrimStart() -match '^"' -and (& $test "{`n$part`n}"))) { continue }
            $first = ($part.Trim().Split("`n") | Select-Object -First 1)
            $failures.Add("json block $index ($first ...)")
        }
    }
    return $failures.ToArray()
}

function Get-MarkdownSection {
    # The lines of the H2 section whose heading matches -Pattern, without the heading; $null when there is none.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Prose, [Parameter(Mandatory)][string]$Pattern)
    $lines = $Prose.Split("`n")
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -notmatch $Pattern) { continue }
        $section = [System.Collections.Generic.List[string]]::new()
        for ($j = $i + 1; $j -lt $lines.Count -and $lines[$j] -notmatch '^## '; $j++) { $section.Add($lines[$j]) }
        return , $section.ToArray()
    }
    return $null
}

function Test-MarkdownTroubleshooting {
    # A user page ends its numbered sections with '## N. Troubleshooting' and a table whose header is
    # | Message or Symptom | Cause | Fix |.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $Prose = Get-MarkdownProse -Text $Text -KeepInlineCode
    $section = Get-MarkdownSection -Prose $Prose -Pattern '^## \d+\. Troubleshooting\s*$'
    if ($null -eq $section) { return 'no "## N. Troubleshooting" section' }
    $header = @($section | Where-Object { $_ -match '^\s*\|' } | Select-Object -First 1)
    if ($header.Count -eq 0) { return 'the troubleshooting section has no table' }
    [string[]]$cells = @($header[0].Trim().Trim('|').Split('|') | ForEach-Object { $_.Trim() })
    if ($cells.Count -ne 3 -or $cells[0] -cnotin 'Message', 'Symptom' -or $cells[1] -cne 'Cause' -or $cells[2] -cne 'Fix') {
        return ("the troubleshooting table header is '$($header[0].Trim())', not | Message (or Symptom) | Cause | Fix |")
    }
    return @()
}

function Test-MarkdownShape {
    # A user page has the '> **Status:**' line and '## Contents', and every link in Contents names a heading.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $Prose = Get-MarkdownProse -Text $Text -KeepInlineCode
    $problems = [System.Collections.Generic.List[string]]::new()
    if ($Prose -notmatch '(?m)^> \*\*Status:\*\*') { $problems.Add('no "> **Status:**" line') }
    $contents = Get-MarkdownSection -Prose $Prose -Pattern '^## Contents\s*$'
    if ($null -eq $contents) {
        $problems.Add('no "## Contents" section')
    } else {
        $anchors = Get-MarkdownAnchor -Text $Text
        # Get-MarkdownLinkTarget returns its array with a comma; @() around it would nest it.
        [string[]]$entries = Get-MarkdownLinkTarget -Prose ($contents -join "`n")
        if ($entries.Count -eq 0) { $problems.Add('"## Contents" links no heading') }
        foreach ($entry in $entries) {
            if (-not $entry.StartsWith('#') -or -not $anchors.Contains([System.Uri]::UnescapeDataString($entry.Substring(1)))) { $problems.Add("Contents entry $entry names no heading of this page") }
        }
    }
    return $problems.ToArray()
}
