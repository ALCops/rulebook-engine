# Off-level script suite for WP10 (#12): scripts/New-RulebookOffLevel.ps1 run in-process (&) on copies of
# valid-minimal and of template/. The drift guard: the script writes the same bytes as New-RulebookOffLevel of
# Rulebook.Levels, on the fixture catalog (28 of 30 ids enabled) and on the shipped catalog (605 of 628).

BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:entry = Join-Path $script:repoRoot 'scripts' 'New-RulebookOffLevel.ps1'
    Import-Module (Join-Path $script:repoRoot 'modules' 'Rulebook.Generate.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'modules' 'Rulebook.Levels.psd1') -Force
    . (Join-Path $PSScriptRoot 'Helpers' 'RepoFixture.ps1')

    function Get-TestFolder {
        return Join-Path $TestDrive ([guid]::NewGuid().ToString('n').Substring(0, 12))
    }

    function Copy-Fixture {
        return New-FixtureRepo -Name 'valid-minimal' -Destination (Get-TestFolder)
    }

    function Copy-TemplateRepo {
        # The settings and the catalog of template/, all the script reads.
        $root = Get-TestFolder
        foreach ($file in '.github/Rulebook-Settings.json', 'catalog/diagnostics.json') {
            $target = Join-Path $root $file
            [void](New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force)
            Copy-Item -LiteralPath (Join-Path $script:repoRoot 'template' $file) -Destination $target
        }
        return (Resolve-Path -LiteralPath $root).ProviderPath
    }

    function Invoke-Script {
        # Runs the script in-process; returns the result objects and the console lines. Throws what the script throws.
        param([hashtable]$Parameters)
        $output = @(& $script:entry @Parameters 6>&1)
        return [pscustomobject]@{
            Result = @($output | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] })
            Lines  = @($output | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { [string]$_.MessageData })
        }
    }

    function Get-FileBase64 {
        param([Parameter(Mandatory)][string]$Path)
        return [System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes($Path))
    }

    function Assert-SameAsModule {
        # Runs the script on Root and New-RulebookOffLevel on a copy of Root; the two files must be byte-identical.
        param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][int]$Count)
        $copy = Get-TestFolder
        Copy-FixtureTree -Source $Root -Destination $copy
        $run = Invoke-Script @{ RepositoryRoot = $Root }
        $run.Result[0].Count | Should-Be $Count
        (New-RulebookOffLevel -RepositoryRoot $copy).Count | Should-Be $Count
        Get-FileBase64 (Join-Path $Root 'base' 'off.ruleset.json') | Should-Be (Get-FileBase64 (Join-Path $copy 'base' 'off.ruleset.json'))
    }
}

AfterAll {
    Remove-Module Rulebook.Levels -ErrorAction SilentlyContinue
}

Describe 'New-RulebookOffLevel.ps1' {
    It 'writes the 28 enabled ids of valid-minimal byte-identical to the module and prints the settings entry' {
        $root = Copy-Fixture
        Assert-SameAsModule -Root $root -Count 28
    }

    It 'writes the 605 enabled ids of the shipped catalog byte-identical to the module' {
        Assert-SameAsModule -Root (Copy-TemplateRepo) -Count 605
    }

    It 'prints the entry to paste, the next steps and returns the result object' {
        $run = Invoke-Script @{ RepositoryRoot = (Copy-Fixture) }
        $result = $run.Result[0]
        $result.File | Should-Be 'base/off.ruleset.json'
        $result.Slug | Should-Be 'off'
        $result.SettingsListed | Should-BeFalse
        $result.SettingsEntry | Should-Be '{ "name": "Off", "description": "Every known diagnostic off. Opt in through overrides." }'
        $run.Lines | Should-ContainCollection 'Wrote base/off.ruleset.json (28 ids at None)'
        $run.Lines | Should-ContainCollection '    { "name": "Off", "description": "Every known diagnostic off. Opt in through overrides." },'
        ($run.Lines -join "`n") | Should-MatchString 'Update Rulebook System Files" with "Resolve the latest commit" off'
        ($run.Lines -join "`n") | Should-MatchString 'https://github\.com/ALCops/rulebook/blob/main/docs/levels\.md'
    }

    It 'says the file is current on a second run and does not write it' {
        $root = Copy-Fixture
        $null = Invoke-Script @{ RepositoryRoot = $root }
        $path = Join-Path $root 'base' 'off.ruleset.json'
        $stamp = [datetime]::new(2020, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc)
        [System.IO.File]::SetLastWriteTimeUtc($path, $stamp)
        $run = Invoke-Script @{ RepositoryRoot = $root }
        $run.Lines | Should-ContainCollection 'base/off.ruleset.json is current (28 ids at None)'
        [System.IO.File]::GetLastWriteTimeUtc($path) | Should-Be $stamp
    }

    It 'says a CRLF working copy is current and does not rewrite it, but refuses a changed entry' {
        $root = Copy-Fixture
        $null = Invoke-Script @{ RepositoryRoot = $root }
        $path = Join-Path $root 'base' 'off.ruleset.json'
        $crlf = [System.IO.File]::ReadAllText($path).Replace("`n", "`r`n")
        [System.IO.File]::WriteAllText($path, $crlf, [System.Text.UTF8Encoding]::new($false))
        $run = Invoke-Script @{ RepositoryRoot = $root }
        $run.Lines | Should-ContainCollection 'base/off.ruleset.json is current (28 ids at None; only the line endings of the working copy differ)'
        [System.IO.File]::ReadAllText($path) | Should-Be $crlf
        [System.IO.File]::WriteAllText($path, $crlf.Replace('"AL0001", "action": "None"', '"AL0001", "action": "Info"'), [System.Text.UTF8Encoding]::new($false))
        { Invoke-Script @{ RepositoryRoot = $root } } | Should-Throw -ExceptionMessage 'base/off.ruleset.json exists and differs*'
    }

    It 'reports a level the settings list already' {
        $root = Copy-Fixture
        Edit-FixtureJson -Path (Join-Path $root '.github' 'Rulebook-Settings.json') -Script { $_['levels'] = @(@{ name = 'OFF' }) + @($_['levels']) }
        $run = Invoke-Script @{ RepositoryRoot = $root }
        $run.Result[0].SettingsListed | Should-BeTrue
        $run.Lines | Should-ContainCollection 'Already listed in the settings as OFF.'
    }

    It 'refuses a differing file without -Force and overwrites it with -Force' {
        $root = Copy-Fixture
        $null = Invoke-Script @{ RepositoryRoot = $root }
        $path = Join-Path $root 'base' 'off.ruleset.json'
        $original = Get-FileBase64 $path
        Write-FixtureText -Path $path -Text (([System.IO.File]::ReadAllText($path)) -replace '"AL0001", "action": "None"', '"AL0001", "action": "Error"')
        { Invoke-Script @{ RepositoryRoot = $root } } | Should-Throw -ExceptionMessage 'base/off.ruleset.json exists and differs; it is owned by this repository. Use -Force to overwrite it (your own edits in it are lost)'
        $null = Invoke-Script @{ RepositoryRoot = $root; Force = $true }
        Get-FileBase64 $path | Should-Be $original
        Test-Path -LiteralPath "$path.tmp" | Should-BeFalse
    }

    It 'refuses a folder that is not the root of a rulebook repository' {
        $folder = Get-TestFolder
        [void](New-Item -ItemType Directory -Path $folder -Force)
        { Invoke-Script @{ RepositoryRoot = $folder } } | Should-Throw -ExceptionMessage 'Run the script from the root of a clone of your rulebook repository (the folder with .github/Rulebook-Settings.json and catalog/diagnostics.json): *'
    }

    It 'warns before replacing the file of a published level, like the module' {
        $root = Copy-Fixture
        $message = "'Strict' is already a published level; -Force would replace base/strict.ruleset.json with an everything-off file"
        $output = @(& $script:entry -RepositoryRoot $root -Name 'Strict' -Force 6>$null 3>&1)
        @($output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { [string]$_.Message }) | Should-ContainCollection $message
        @($output | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] })[0].SettingsListed | Should-BeTrue
        $copy = Copy-Fixture
        $null = New-RulebookOffLevel -RepositoryRoot $copy -Name 'Strict' -Force -WarningVariable moduleWarnings -WarningAction SilentlyContinue
        @($moduleWarnings | ForEach-Object { [string]$_ }) | Should-ContainCollection $message
        [System.IO.File]::ReadAllText((Join-Path $root 'base' 'strict.ruleset.json')) | Should-Be ([System.IO.File]::ReadAllText((Join-Path $copy 'base' 'strict.ruleset.json')))
    }

    It 'refuses the slug readme like the module' {
        $message = "Level 'README' cannot have a page: its slug collides with the index README.md"
        { Invoke-Script @{ RepositoryRoot = (Copy-Fixture); Name = 'README' } } | Should-Throw -ExceptionMessage $message
        { New-RulebookOffLevel -RepositoryRoot (Copy-Fixture) -Name 'README' } | Should-Throw -ExceptionMessage $message
    }

    It 'refuses a catalog entry without an id (each with its own reader message)' {
        $root = Copy-Fixture
        Edit-FixtureJson -Path (Join-Path $root 'catalog' 'diagnostics.json') -Script { $_['diagnostics'][1].Remove('id') }
        { Invoke-Script @{ RepositoryRoot = $root } } | Should-Throw -ExceptionMessage 'catalog/diagnostics.json has an entry without an id'
        { New-RulebookOffLevel -RepositoryRoot $root } | Should-Throw -ExceptionMessage '*has an entry without an id'
    }

    It 'refuses a name that is not a slug' {
        { Invoke-Script @{ RepositoryRoot = (Copy-Fixture); Name = 'Bad Name' } } | Should-Throw -ExceptionMessage ([WildcardPattern]::Escape("Level name 'Bad Name' does not lowercase to a slug matching ^[a-z0-9-]+$ (C5)"))
    }

    It 'refuses a catalog entry without a boolean enabledByDefault, with the message of the module' {
        $root = Copy-Fixture
        Edit-FixtureJson -Path (Join-Path $root 'catalog' 'diagnostics.json') -Script { $_['diagnostics'][1].Remove('enabledByDefault') }
        $message = 'catalog/diagnostics.json: AL0200 has no boolean enabledByDefault'
        { Invoke-Script @{ RepositoryRoot = $root } } | Should-Throw -ExceptionMessage $message
        { New-RulebookOffLevel -RepositoryRoot $root } | Should-Throw -ExceptionMessage $message
        Test-Path -LiteralPath (Join-Path $root 'base' 'off.ruleset.json') | Should-BeFalse
    }

    It 'warns on unreadable settings, writes the file and still prints the entry and the next steps' {
        $root = Copy-Fixture
        Write-FixtureText -Path (Join-Path $root '.github' 'Rulebook-Settings.json') -Text '{ "levels": [ '
        $output = @(& $script:entry -RepositoryRoot $root 6>&1 3>&1)
        $warnings = @($output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { [string]$_.Message })
        $lines = @($output | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { [string]$_.MessageData })
        $result = @($output | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] -and $_ -isnot [System.Management.Automation.WarningRecord] })[0]
        $warnings | Should-BeLikeString 'Cannot read .github/Rulebook-Settings.json (*); the level counts as not listed'
        $result.SettingsListed | Should-BeFalse
        $lines | Should-ContainCollection '    { "name": "Off", "description": "Every known diagnostic off. Opt in through overrides." },'
        ($lines -join "`n") | Should-MatchString 'Next steps:'
        Test-Path -LiteralPath (Join-Path $root 'base' 'off.ruleset.json') | Should-BeTrue
    }

    It 'sorts like Get-DiagnosticSortKey: one id per known prefix, an i suffix and an unknown prefix, byte-identical to the module' {
        # The prefix list comes from Rulebook.Generate, so a prefix added there without updating the script fails here.
        $prefixes = @(& (Get-Module Rulebook.Generate) { $script:PrefixOrder })
        $prefixes.Count | Should-BeGreaterThan 0
        $ids = [System.Collections.Generic.List[string]]::new()
        $ids.Add('ZZ0001')
        foreach ($prefix in $prefixes) { $ids.Add('{0}0002' -f $prefix); $ids.Add('{0}0001' -f $prefix) }
        $ids.Add('LC0089i')
        $ids.Add('LC0089')
        # Seven digits and an id outside the pattern sort after every other id.
        $ids.Add('al-x')
        $ids.Add('AL1234567')
        $lines = @($ids | ForEach-Object { '    { "id": "' + $_ + '", "defaultSeverity": "Warning", "enabledByDefault": true }' })
        $root = Get-TestFolder
        Write-FixtureText -Path (Join-Path $root 'catalog' 'diagnostics.json') -Text ("{`n  `"version`": 1,`n  `"diagnostics`": [`n" + ($lines -join ",`n") + "`n  ]`n}")
        Write-FixtureText -Path (Join-Path $root '.github' 'Rulebook-Settings.json') -Text '{ "levels": [ { "name": "Essential" } ], "stages": [ { "name": "default" } ] }'
        Assert-SameAsModule -Root $root -Count $ids.Count
        $written = @((Get-Content -LiteralPath (Join-Path $root 'base' 'off.ruleset.json') -Raw | ConvertFrom-Json).rules | ForEach-Object id)
        $written[0] | Should-Be "$($prefixes[0])0001"
        $written[-3..-1] | Should-BeCollection @('ZZ0001', 'AL1234567', 'al-x')
        [array]::IndexOf($written, 'LC0089i') | Should-Be ([array]::IndexOf($written, 'LC0089') + 1)
    }
}
