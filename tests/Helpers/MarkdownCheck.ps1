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
    # The anchor GitHub gives a heading: links reduced to their text, HTML tags removed outside code spans (a code
    # span keeps its content: `List<T>` gives listt), lowercase, every character other than a letter, a digit, a
    # mark, '_', '-' or a space removed, spaces to '-'.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Heading)
    $linked = [regex]::Replace($Heading, '!?\[([^\]]*)\]\([^)]*\)', '$1')
    $builder = [System.Text.StringBuilder]::new()
    $position = 0
    foreach ($span in [regex]::Matches($linked, '(`+)(.+?)\1')) {
        [void]$builder.Append([regex]::Replace($linked.Substring($position, $span.Index - $position), '<[^>]+>', ''))
        [void]$builder.Append($span.Groups[2].Value)
        $position = $span.Index + $span.Length
    }
    [void]$builder.Append([regex]::Replace($linked.Substring($position), '<[^>]+>', ''))
    $text = $builder.ToString()
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
    # The link targets of a page, in kind order: inline links ([text](target)) and, separately, images
    # (![alt](target), also an image inside a link's text), each with an optional "title" and one level of balanced
    # parentheses in the target; reference links ([text][label], [label][]) resolved through their definitions (a label
    # without a definition gives '[label]', reported as broken); the reference definitions themselves ([label]:
    # target, not a footnote [^1]: ...); HTML <a href> and <img src>. GitHub autolinks only absolute URIs, so <x.md>
    # in prose is not a link.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Prose)
    $targets = [System.Collections.Generic.List[string]]::new()
    $text = '(?:[^\[\]]|\[[^\[\]]*\])*'
    $destination = '\(\s*(?:<([^>]*)>|((?:[^\s()]|\([^\s()]*\))+))(?:\s+(?:"[^"]*"|''[^'']*''))?\s*\)'
    foreach ($pattern in ('(?<!!)\[' + $text + '\]' + $destination), ('!\[[^\[\]]*\]' + $destination)) {
        foreach ($match in [regex]::Matches($Prose, $pattern)) {
            $targets.Add($(if ($match.Groups[1].Success) { $match.Groups[1].Value } else { $match.Groups[2].Value }))
        }
    }
    $definitions = [ordered]@{}
    foreach ($match in [regex]::Matches($Prose, '(?m)^[ ]{0,3}\[([^\]^][^\]]*)\]:[ \t]*<?([^\s>]+)>?')) {
        $label = $match.Groups[1].Value.Trim().ToLowerInvariant()
        if (-not $definitions.Contains($label)) { $definitions[$label] = $match.Groups[2].Value }
    }
    foreach ($match in [regex]::Matches($Prose, '!?\[(' + $text + ')\]\[([^\[\]]*)\](?![(:])')) {
        $label = $(if ($match.Groups[2].Value.Trim()) { $match.Groups[2].Value } else { $match.Groups[1].Value }).Trim().ToLowerInvariant()
        $targets.Add($(if ($definitions.Contains($label)) { $definitions[$label] } else { "[$label]" }))
    }
    foreach ($value in $definitions.Values) { $targets.Add($value) }
    foreach ($match in [regex]::Matches($Prose, '<(?:a|img)\b[^>]*?\s(?:href|src)\s*=\s*["'']([^"'']+)["'']', 'IgnoreCase')) { $targets.Add($match.Groups[1].Value) }
    return , $targets.ToArray()
}

function Test-MarkdownLink {
    # The broken relative links of the page -Path under -Root: a target without a scheme whose file or folder does not
    # exist (URL-decoded, relative to the page's folder, or to -Root with a leading '/'), a '#fragment' that names no
    # anchor of the page itself or, for a link to another Markdown page, of that page, and a reference link without a
    # definition. -Overlay: further roots a path is looked up in, at the same place relative to -Root (the template
    # README resolves docs/ in the user documentation). -Pending: root-relative paths (wildcards allowed) that may be
    # missing (pages not written yet, or docs/* without the user documentation). -NoEscape: a target whose path leaves
    # -Root is broken (a template page would point outside the organization repository once shipped).
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [string[]]$Overlay = @(),
        [string[]]$Pending = @(),
        [switch]$NoEscape
    )
    if ($null -eq (Get-Variable -Name MarkdownAnchorCache -Scope Script -ErrorAction SilentlyContinue)) { $script:MarkdownAnchorCache = @{} }
    $Prose = Get-MarkdownProse -Text $Text
    $broken = [System.Collections.Generic.List[string]]::new()
    $anchors = $null
    $folder = Split-Path -Parent $Path
    foreach ($target in (Get-MarkdownLinkTarget -Prose $Prose)) {
        if ($target.StartsWith('[')) { $broken.Add("$target (no reference definition)"); continue }
        if ($target -match '^[A-Za-z][A-Za-z0-9+.-]*:' -or $target -like '//*') { continue }
        if ($target.StartsWith('#')) {
            if ($null -eq $anchors) { $anchors = Get-MarkdownAnchor -Text $Text }
            $fragment = [System.Uri]::UnescapeDataString($target.Substring(1))
            if (-not $anchors.Contains($fragment)) { $broken.Add("$target (no such heading on this page)") }
            continue
        }
        $parts = $target -split '#', 2
        $relative = [System.Uri]::UnescapeDataString(($parts[0] -split '\?', 2)[0])
        if ($relative -eq '') { continue }
        $full = [System.IO.Path]::GetFullPath($(if ($relative.StartsWith('/')) { Join-Path $Root $relative.TrimStart('/') } else { Join-Path $folder $relative }))
        $fromRoot = [System.IO.Path]::GetRelativePath($Root, $full).Replace('\', '/')
        if ($NoEscape -and ($fromRoot -eq '..' -or $fromRoot.StartsWith('../') -or [System.IO.Path]::IsPathRooted($fromRoot))) { $broken.Add("$target (outside the repository)"); continue }
        $found = $null
        foreach ($candidate in @($full) + @($Overlay | ForEach-Object { Join-Path $_ $fromRoot })) {
            if (Test-Path -LiteralPath $candidate) { $found = $candidate; break }
        }
        if ($null -eq $found) {
            if (-not @($Pending | Where-Object { $fromRoot -clike $_ })) { $broken.Add($target) }
            continue
        }
        if ($parts.Count -eq 2 -and $parts[1] -ne '' -and $found -like '*.md' -and (Test-Path -LiteralPath $found -PathType Leaf)) {
            if (-not $script:MarkdownAnchorCache.ContainsKey($found)) { $script:MarkdownAnchorCache[$found] = Get-MarkdownAnchor -Text ([System.IO.File]::ReadAllText($found)) }
            if (-not $script:MarkdownAnchorCache[$found].Contains([System.Uri]::UnescapeDataString($parts[1]))) { $broken.Add("$target (no such heading on that page)") }
        }
    }
    return $broken.ToArray()
}

function Test-MarkdownJson {
    # The fenced JSON blocks that do not parse: a fence of ``` or ~~~ indented up to three spaces whose info string
    # starts with json (json, jsonc, json title=...), up to the closing fence of the same kind. Full-line // comments
    # are removed and the whole block parsed; an excerpt of an object (it starts with a "key") parses wrapped in
    # braces. When that fails, the block is split at the comment lines (a page showing two files, each under a
    # // file name) and each part must parse on its own.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $failures = [System.Collections.Generic.List[string]]::new()
    $test = {
        param([string]$Json)
        foreach ($candidate in @($Json) + @(if ($Json.TrimStart().StartsWith('"')) { "{`n$Json`n}" })) {
            try { if (Test-Json -Json $candidate -ErrorAction Stop) { return $true } } catch { $null = $_ }
        }
        return $false
    }
    $index = 0
    foreach ($match in [regex]::Matches($Text.Replace("`r`n", "`n"), '(?ms)^[ ]{0,3}(`{3,}|~{3,})[ \t]*json[^\n]*\n(.*?)^[ ]{0,3}\1[`~]*[ \t]*$')) {
        $index++
        [string[]]$lines = $match.Groups[2].Value.Split("`n")
        if (& $test ((@($lines | Where-Object { $_ -notmatch '^\s*//' })) -join "`n")) { continue }
        $parts = [System.Collections.Generic.List[string]]::new()
        $current = [System.Collections.Generic.List[string]]::new()
        foreach ($line in $lines) {
            if ($line -match '^\s*//') {
                if (($current -join '').Trim()) { $parts.Add(($current -join "`n")) }
                $current.Clear()
            } else {
                $current.Add($line)
            }
        }
        if (($current -join '').Trim()) { $parts.Add(($current -join "`n")) }
        foreach ($part in $parts) {
            if (& $test $part) { continue }
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
