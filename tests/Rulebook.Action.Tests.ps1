# Action helper suite for #58: modules/Rulebook.Action, the helpers the entry scripts under actions/ share. The four
# action suites cover the helpers again through the exact lines, summaries and outputs of each action.

BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $repoRoot 'modules' 'Rulebook.Action.psd1') -Force
    $script:utf8 = [System.Text.UTF8Encoding]::new($false)

    function Get-TestFile {
        return Join-Path $TestDrive ('{0}.txt' -f [guid]::NewGuid().ToString('n').Substring(0, 12))
    }

    function Invoke-Annotation {
        # Runs Add-Annotation; returns the console lines (information stream).
        param([hashtable]$Parameters)
        return @(Add-Annotation @Parameters 6>&1 | ForEach-Object { [string]$_.MessageData })
    }
}

AfterAll {
    Remove-Module Rulebook.Action -ErrorAction SilentlyContinue
}

Describe 'Rulebook.Action manifest' {
    It 'exports exactly the ten helpers' {
        $module = Get-Module Rulebook.Action
        @($module.ExportedFunctions.Keys | Sort-Object) | Should-BeCollection @('Add-Annotation', 'Add-Failure', 'ConvertTo-SingleLine', 'Format-AnnotationText', 'Format-TableCell', 'Limit-SummaryText', 'New-ActionContext', 'Resolve-ActionPath', 'Write-ActionOutput', 'Write-Text')
    }

    It 'imports no other engine module' {
        $text = Get-Content -LiteralPath (Join-Path $repoRoot 'modules' 'Rulebook.Action.psm1') -Raw
        $text | Should-NotMatchString '(?m)^\s*Import-Module'
    }
}

Describe 'Format-AnnotationText' {
    It 'escapes %, CR and LF in a message' {
        Format-AnnotationText "100% done`r`nnext" | Should-Be '100%25 done%0D%0Anext'
    }

    It 'keeps : and , in a message' {
        Format-AnnotationText 'C3: a, b' | Should-Be 'C3: a, b'
    }

    It 'also escapes : and , in a property value' {
        Format-AnnotationText "a:b,c%`n" -Property | Should-Be 'a%3Ab%2Cc%25%0A'
    }

    It 'escapes % before the other characters, so an escape is not escaped twice' {
        Format-AnnotationText '%0A' | Should-Be '%250A'
    }

    It 'returns an empty string for $null' {
        Format-AnnotationText $null | Should-Be ''
        Format-AnnotationText $null -Property | Should-Be ''
    }
}

Describe 'ConvertTo-SingleLine and Format-TableCell' {
    It 'turns CR and LF into spaces without table escaping' {
        ConvertTo-SingleLine "a|b`r`nc" | Should-Be 'a|b  c'
        ConvertTo-SingleLine $null | Should-Be ''
    }

    It 'escapes | and turns CR and LF into spaces in a table cell' {
        Format-TableCell "a|b`nc" | Should-Be 'a\|b c'
        Format-TableCell $null | Should-Be ''
    }
}

Describe 'Add-Annotation' {
    BeforeEach {
        $script:ctx = New-ActionContext -Title 'Publish'
    }

    It 'writes the line with the title of the context and collects it' {
        $lines = Invoke-Annotation @{ Context = $ctx; Message = "boom`nline 2" }
        $lines | Should-BeCollection @('::error title=Publish::boom%0Aline 2')
        $ctx.Annotations.ToArray() | Should-BeCollection @('::error title=Publish::boom%0Aline 2')
    }

    It 'writes file= before the title, both escaped as properties' {
        $lines = Invoke-Annotation @{ Context = $ctx; Command = 'warning'; File = 'levels/a,b.json'; Title = 'C3: x'; Message = 'm' }
        $lines | Should-BeCollection @('::warning file=levels/a%2Cb.json,title=C3%3A x::m')
    }

    It 'leaves file= out for an empty or $null file' {
        $lines = @(Invoke-Annotation @{ Context = $ctx; File = ''; Message = 'a' }) + @(Invoke-Annotation @{ Context = $ctx; File = $null; Message = 'b' })
        $lines | Should-BeCollection @('::error title=Publish::a', '::error title=Publish::b')
    }

    It 'collects the unescaped message of an error, not of a warning or notice' {
        $null = Invoke-Annotation @{ Context = $ctx; Message = "first`nsecond" }
        $null = Invoke-Annotation @{ Context = $ctx; Command = 'warning'; Message = 'w' }
        $null = Invoke-Annotation @{ Context = $ctx; Command = 'notice'; Message = 'n' }
        $ctx.ErrorMessages.ToArray() | Should-BeCollection @("first`nsecond")
        $ctx.Annotations.Count | Should-Be 3
    }

    It 'writes an explicit empty title as an empty title' {
        $lines = Invoke-Annotation @{ Context = $ctx; Title = ''; Command = 'notice'; Message = 'm' }
        $lines | Should-BeCollection @('::notice title=::m')
    }
}

Describe 'Add-Failure' {
    It 'keeps the first kind' {
        $ctx = New-ActionContext -Title 'Scan'
        $ctx.Failure | Should-BeNull
        Add-Failure -Context $ctx -Kind 'token'
        Add-Failure -Context $ctx -Kind 'error'
        $ctx.Failure | Should-Be 'token'
    }
}

Describe 'Write-Text' {
    It 'appends, writes CRLF as LF and writes no BOM' {
        $path = Get-TestFile
        Write-Text -Path $path -Text "a`r`nb`n"
        Write-Text -Path $path -Text "c`r`n"
        $bytes = [System.IO.File]::ReadAllBytes($path)
        $bytes[0] | Should-Be ([byte][char]'a')
        $utf8.GetString($bytes) | Should-Be "a`nb`nc`n"
    }

    It 'writes nothing for an empty or $null path' {
        Write-Text -Path '' -Text 'x'
        Write-Text -Path $null -Text 'x'
    }

    It 'resolves a relative path against the PowerShell location' {
        $folder = Join-Path $TestDrive 'relative-write'
        $null = New-Item -ItemType Directory -Path $folder -Force
        Push-Location -LiteralPath $folder
        try {
            Write-Text -Path 'out.txt' -Text 'x'
        } finally {
            Pop-Location
        }
        Get-Content -LiteralPath (Join-Path $folder 'out.txt') -Raw | Should-Be 'x'
    }
}

Describe 'Resolve-ActionPath' {
    It 'resolves a relative path against the PowerShell location, not the process directory' {
        $folder = Join-Path $TestDrive 'relative-resolve'
        $null = New-Item -ItemType Directory -Path $folder -Force
        Push-Location -LiteralPath $folder
        try {
            $resolved = Resolve-ActionPath (Join-Path 'sub' 'file.md')
        } finally {
            Pop-Location
        }
        $resolved | Should-Be (Join-Path ((Resolve-Path -LiteralPath $folder).ProviderPath) 'sub' 'file.md')
    }

    It 'returns an empty or $null path as it is' {
        Resolve-ActionPath '' | Should-Be ''
        Resolve-ActionPath $null | Should-Be ''
    }
}

Describe 'Write-ActionOutput' {
    It 'writes key=value lines in the order of the dictionary, $null as empty' {
        $path = Get-TestFile
        Write-ActionOutput -Path $path -Outputs ([ordered]@{ zeta = 1; alpha = 'two'; failure = $null; flag = $false.ToString().ToLowerInvariant() })
        Get-Content -LiteralPath $path -Raw | Should-Be "zeta=1`nalpha=two`nfailure=`nflag=false`n"
    }

    It 'writes a value with CR or LF in the heredoc form and a plain value on one line' {
        $path = Get-TestFile
        Write-ActionOutput -Path $path -Outputs ([ordered]@{ body = "line 1`nforged=1`r`nline 3"; plain = 'x' })
        $text = Get-Content -LiteralPath $path -Raw
        $text | Should-MatchString '\Abody<<(ghadelim_[0-9a-f]{32})\nline 1\nforged=1\nline 3\n\1\nplain=x\n\z'
    }

    It 'defaults to GITHUB_OUTPUT and writes nothing without it' {
        $saved = $env:GITHUB_OUTPUT
        try {
            $path = Get-TestFile
            $env:GITHUB_OUTPUT = $path
            Write-ActionOutput -Outputs ([ordered]@{ errors = 0 })
            Get-Content -LiteralPath $path -Raw | Should-Be "errors=0`n"
            $env:GITHUB_OUTPUT = $null
            Write-ActionOutput -Outputs ([ordered]@{ errors = 0 })
        } finally {
            $env:GITHUB_OUTPUT = $saved
        }
    }

    It 'writes nothing for an empty dictionary' {
        $path = Get-TestFile
        Write-ActionOutput -Path $path -Outputs ([ordered]@{})
        Test-Path -LiteralPath $path | Should-BeFalse
    }
}

Describe 'Limit-SummaryText' {
    BeforeAll {
        $script:text = "## Title`n`nintro`n`n``````powershell`n" + (@(1..200 | ForEach-Object { "line $_" }) -join "`n") + "`n```````n`nafter`n"
    }

    It 'cuts a summary at a line boundary, closes an open fence and adds the footer' {
        $cut = Limit-SummaryText -Text $text -MaxBytes 400 -Footer 'The summary was cut at 0 KiB; the full lists are in the job log.'
        [System.Text.Encoding]::UTF8.GetByteCount($cut) | Should-BeLessThanOrEqual 400
        $cut | Should-MatchString '(?s)\A## Title\n'
        $cut | Should-MatchString '\n```\n\n_The summary was cut at 0 KiB; the full lists are in the job log\._\n\z'
        @($cut.Split("`n") | Where-Object { $_ -match '^```' }).Count % 2 | Should-Be 0
    }

    It 'returns text within the limit as it is' {
        Limit-SummaryText -Text $text -MaxBytes 1000000 -Footer 'x' | Should-Be $text
    }

    It 'keeps a summary over the 900 KiB the actions pass below it' {
        $row = '| C3 | error | `levels/a.json` | ALC0001 | ' + ('x' * 100) + ' |'
        $big = "## Rulebook validation`n`n" + (@(1..10000 | ForEach-Object { $row }) -join "`n") + "`n"
        [System.Text.Encoding]::UTF8.GetByteCount($big) | Should-BeGreaterThan 900KB
        $cut = Limit-SummaryText -Text $big -MaxBytes 900KB -Footer 'The summary was truncated at 900 KiB; the -JsonPath file and the annotations above have the findings.'
        [System.Text.Encoding]::UTF8.GetByteCount($cut) | Should-BeLessThanOrEqual 900KB
        $cut | Should-MatchString '\|\n\n_The summary was truncated at 900 KiB; the -JsonPath file and the annotations above have the findings\._\n\z'
    }
}
