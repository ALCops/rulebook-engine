# Quarantine suite for WP08 (#10): modules/Rulebook.Quarantine on copies of tests/fixtures/repos/valid-minimal in
# TestDrive (docs/reference/scan-mechanics.md section 4).

BeforeAll {
    # The docs, schema and script URLs follow the engine ref: clear what a runner step would set, restore it in AfterAll.
    . (Join-Path $PSScriptRoot 'Helpers' 'EngineRef.ps1')
    $script:savedEngineRef = Clear-EngineRefEnvironment
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $PSScriptRoot 'Helpers' 'RepoFixture.ps1')
    Import-Module (Join-Path $repoRoot 'modules' 'Rulebook.Generate.psd1') -Force
    Import-Module (Join-Path $repoRoot 'modules' 'Rulebook.Quarantine.psd1') -Force
    $script:utf8 = [System.Text.UTF8Encoding]::new($false)
    $script:now = [System.DateTimeOffset]::new(2026, 10, 8, 4, 17, 0, [System.TimeSpan]::Zero)
    $script:policyMessage = 'Set quarantine.stages and quarantine.prereleaseStages in .github/Rulebook-Settings.json. Typical choice: quarantine default and ci, leave vnext out so it shows new rules at their default severity.'

    function Copy-Fixture {
        return New-FixtureRepo -Name 'valid-minimal' -Destination (Join-Path $TestDrive ([guid]::NewGuid().ToString('n').Substring(0, 12)))
    }

    function Read-SettingsFile {
        param([string]$Root)
        return Get-Content -LiteralPath (Join-Path $Root '.github' 'Rulebook-Settings.json') -Raw | ConvertFrom-Json -AsHashtable
    }

    function New-Diff {

        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helper; builds an object or writes only to TestDrive')]
        param([string]$Version = '1.4.0', [string]$Channel = 'stable', [string[]]$NewIds = @(), [string[]]$Promoted = @(), [string[]]$Unadvertised = @(), [string[]]$NewlyAdvertised = @())
        return [pscustomobject]@{ PackageId = 'alcops.analyzers'; Version = $Version; Channel = $Channel; NewIds = $NewIds; Promoted = $Promoted; Unadvertised = $Unadvertised; NewlyAdvertised = $NewlyAdvertised }
    }

    function Get-Rules {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Test helper; returns the rule ids')]
        param([string]$Root, [string]$Stage)
        return @((Read-QuarantineFile -Path (Join-Path $Root "quarantine.$Stage.json")).Rules.Keys)
    }
}

AfterAll {
    Restore-EngineRefEnvironment -Saved $script:savedEngineRef
    Remove-Module Rulebook.Quarantine, Rulebook.Generate, Rulebook.Common -ErrorAction SilentlyContinue
}

Describe 'Get-QuarantinePolicy' {
    It 'refuses <Case> with the documented message' -ForEach @(
        @{ Case = 'the template policy (both null)'; Quarantine = @{ stages = $null; prereleaseStages = $null } }
        @{ Case = 'a missing prereleaseStages'; Quarantine = @{ stages = @('default') } }
        @{ Case = 'no quarantine key'; Quarantine = $null }
    ) {
        $settings = Read-SettingsFile (Copy-Fixture)
        if ($null -eq $Quarantine) { $settings.Remove('quarantine') } else { $settings['quarantine'] = $Quarantine }
        $caught = $null
        try { $null = Get-QuarantinePolicy -Settings $settings } catch { $caught = $_ }
        $caught.Exception.Message | Should-Be $policyMessage
        $caught.Exception.Data['Stage'] | Should-Be 'policy'
    }

    It 'accepts empty arrays' {
        $settings = Read-SettingsFile (Copy-Fixture)
        $settings['quarantine'] = @{ stages = @(); prereleaseStages = @() }
        $policy = Get-QuarantinePolicy -Settings $settings
        $policy.Stages | Should-BeCollection @()
        $policy.PrereleaseStages | Should-BeCollection @()
    }

    It 'refuses a slug that is not a stage, in the wording of C5' {
        $settings = Read-SettingsFile (Copy-Fixture)
        $settings['quarantine'] = @{ stages = @('default', 'nightly'); prereleaseStages = @() }
        { Get-QuarantinePolicy -Settings $settings } | Should-Throw -ExceptionMessage "quarantine.stages names 'nightly', which is not a stage slug"
    }
}

Describe 'Quarantine files' {
    It 'writes the template layout and round trips valid-minimal byte for byte' {
        $root = Copy-Fixture
        foreach ($stage in 'default', 'ci', 'vnext') {
            $path = Join-Path $root "quarantine.$stage.json"
            ConvertTo-QuarantineJson -File (Read-QuarantineFile -Path $path) | Should-Be ([System.IO.File]::ReadAllText($path, $utf8))
        }
    }

    It 'reads a missing file as empty, with the schema URL' {
        $file = Read-QuarantineFile -Path (Join-Path $TestDrive 'quarantine.none.json')
        $file.Exists | Should-BeFalse
        $file.Rules.Count | Should-Be 0
        ConvertTo-QuarantineJson -File $file | Should-Be "{`n  `"`$schema`": `"https://raw.githubusercontent.com/ALCops/rulebook-engine/main/schemas/rulebook-quarantine.schema.json`",`n  `"rules`": []`n}`n"
    }

    It 'writes the justification of New-QuarantineJustification' {
        New-QuarantineJustification -PackageId 'alcops.analyzers' -Version '1.4.0-beta.1' -Channel prerelease -Date $now |
            Should-Be 'New in alcops.analyzers 1.4.0-beta.1 (prerelease), quarantined 2026-10-08. Review and adopt.'
    }

    It 'adds an id once per stage' {
        $root = Copy-Fixture
        $files = [ordered]@{ default = Read-QuarantineFile -Path (Join-Path $root 'quarantine.default.json'); ci = Read-QuarantineFile -Path (Join-Path $root 'quarantine.ci.json') }
        @(Add-QuarantineEntry -Files $files -Stages @('default', 'ci', 'unknown') -Id 'LC0100' -Justification 'x' | ForEach-Object { "$($_.Stage) $($_.Id)" }) | Should-BeCollection @('default LC0100', 'ci LC0100')
        @(Add-QuarantineEntry -Files $files -Stages @('default', 'ci') -Id 'LC0100' -Justification 'x') | Should-BeCollection @()
        @($files.default.Rules.Keys) | Should-BeCollection @('LC0099', 'LC0100')
    }
}

Describe 'Invoke-QuarantineHousekeeping' {
    It 'releases a quarantined id a level file mentions and names the files' {
        $root = Copy-Fixture
        Edit-FixtureJson -Path (Join-Path $root 'quarantine.ci.json') -Script { $_.rules += @{ id = 'AL0200'; justification = 'old' } }
        $inputs = Read-RulebookInputs -RepositoryRoot $root
        $files = [ordered]@{ ci = Read-QuarantineFile -Path (Join-Path $root 'quarantine.ci.json') }
        $removed = @(Invoke-QuarantineHousekeeping -Files $files -Chains $inputs.Chains)
        @($removed | ForEach-Object { "$($_.Stage) $($_.Id) $($_.Justification)" }) | Should-BeCollection @('ci AL0200 old')
        $removed[0].MentionedBy | Should-BeCollection @('base/essential.ruleset.json', 'base/recommended.ruleset.json')
        @($files.ci.Rules.Keys) | Should-BeCollection @('LC0099')
    }
}

Describe 'Update-QuarantineFromScan' {
    BeforeEach {
        $script:root = Copy-Fixture
        Edit-SettingsQuarantine -Root $root -Stages @('default', 'ci') -Prerelease @('ci')
        $script:settings = Read-SettingsFile $root
        $script:policy = Get-QuarantinePolicy -Settings $settings
        $script:chains = (Read-RulebookInputs -RepositoryRoot $root).Chains
    }

    BeforeAll {
        function Edit-SettingsQuarantine {
            param([string]$Root, [string[]]$Stages, [string[]]$Prerelease)
            $quarantinePolicy = [ordered]@{ stages = @($Stages); prereleaseStages = @($Prerelease) }
            Edit-FixtureJson -Path (Join-Path $Root '.github' 'Rulebook-Settings.json') -Script { $_.quarantine = $quarantinePolicy }
        }
    }

    It 'quarantines a stable id in stages and a prerelease id in prereleaseStages' {
        $result = Update-QuarantineFromScan -RepositoryRoot $root -Settings $settings -Policy $policy -Diffs @((New-Diff -NewIds 'LC0100'), (New-Diff -Version '1.5.0-beta.1' -Channel prerelease -NewIds 'LC0101')) -Chains $chains -Now $now
        @($result.Added | ForEach-Object { "$($_.Stage) $($_.Id)" }) | Should-BeCollection @('default LC0100', 'ci LC0100', 'ci LC0101')
        Get-Rules $root 'default' | Should-BeCollection @('LC0099', 'LC0100')
        Get-Rules $root 'ci' | Should-BeCollection @('LC0099', 'LC0100', 'LC0101')
        Get-Rules $root 'vnext' | Should-BeCollection @()
        (Read-QuarantineFile -Path (Join-Path $root 'quarantine.ci.json')).Rules['LC0101'] | Should-Be 'New in alcops.analyzers 1.5.0-beta.1 (prerelease), quarantined 2026-10-08. Review and adopt.'
        @($result.Changes | ForEach-Object { "$($_.Change) $($_.File)" }) | Should-BeCollection @('modified quarantine.default.json', 'modified quarantine.ci.json')
    }

    It 'adds a promoted id to stages and keeps the prerelease entry text' {
        $null = Update-QuarantineFromScan -RepositoryRoot $root -Settings $settings -Policy $policy -Diffs @(New-Diff -Version '1.4.0-beta.1' -Channel prerelease -NewIds 'LC0100') -Chains $chains -Now $now
        $later = $now.AddDays(3)
        $result = Update-QuarantineFromScan -RepositoryRoot $root -Settings $settings -Policy $policy -Diffs @(New-Diff -Version '1.4.0' -Promoted 'LC0100') -Chains $chains -Now $later
        @($result.Added | ForEach-Object { "$($_.Stage) $($_.Id)" }) | Should-BeCollection @('default LC0100')
        (Read-QuarantineFile -Path (Join-Path $root 'quarantine.ci.json')).Rules['LC0100'] | Should-BeLikeString '*1.4.0-beta.1 (prerelease), quarantined 2026-10-08*'
        (Read-QuarantineFile -Path (Join-Path $root 'quarantine.default.json')).Rules['LC0100'] | Should-BeLikeString '*1.4.0 (stable), quarantined 2026-10-11*'
    }

    It 'quarantines a newly advertised id in stages, seed or not' {
        $result = Update-QuarantineFromScan -RepositoryRoot $root -Settings $settings -Policy $policy -Diffs @(New-Diff -NewlyAdvertised 'LC0000', 'AL0200') -Chains $chains -Now $now
        @($result.Added | ForEach-Object { "$($_.Stage) $($_.Id)" }) | Should-BeCollection @('default LC0000', 'ci LC0000')
        (Read-QuarantineFile -Path (Join-Path $root 'quarantine.default.json')).Rules['LC0000'] | Should-Be 'New in alcops.analyzers 1.4.0 (stable), quarantined 2026-10-08. Review and adopt.'
    }

    It 'never quarantines an unadvertised id or one a level file mentions' {
        $result = Update-QuarantineFromScan -RepositoryRoot $root -Settings $settings -Policy $policy -Diffs @(New-Diff -NewIds 'LC0000', 'AL0200' -Unadvertised 'LC0000') -Chains $chains -Now $now
        $result.Added | Should-BeCollection @()
        $result.Changes | Should-BeCollection @()
    }

    It 'quarantines nowhere with the policy []' {
        Edit-SettingsQuarantine -Root $root -Stages @() -Prerelease @()
        $empty = Get-QuarantinePolicy -Settings (Read-SettingsFile $root)
        $result = Update-QuarantineFromScan -RepositoryRoot $root -Settings $settings -Policy $empty -Diffs @(New-Diff -NewIds 'LC0100') -Chains $chains -Now $now
        $result.Added | Should-BeCollection @()
    }

    It 'creates the file of a policy stage that has none (nightly)' {
        Edit-FixtureJson -Path (Join-Path $root '.github' 'Rulebook-Settings.json') -Script { $_.stages += @{ name = 'Nightly' } }
        Write-FixtureText -Path (Join-Path $root 'stages' 'nightly.json') -Text '{ "name": "Rulebook stage Nightly", "rules": [] }'
        Edit-SettingsQuarantine -Root $root -Stages @('default', 'nightly') -Prerelease @()
        $nightlySettings = Read-SettingsFile $root
        $result = Update-QuarantineFromScan -RepositoryRoot $root -Settings $nightlySettings -Policy (Get-QuarantinePolicy -Settings $nightlySettings) -Diffs @(New-Diff -NewIds 'LC0100') -Chains $chains -Now $now
        $result.Created | Should-BeCollection @('quarantine.nightly.json')
        $text = [System.IO.File]::ReadAllText((Join-Path $root 'quarantine.nightly.json'), $utf8)
        $text | Should-BeLikeString '*"$schema": "https://raw.githubusercontent.com/ALCops/rulebook-engine/main/schemas/rulebook-quarantine.schema.json"*'
        Get-Rules $root 'nightly' | Should-BeCollection @('LC0100')
    }

    It 'never writes a file for a slug that is not a stage of the settings (#48)' {
        $bad = [pscustomobject]@{ Stages = @('default', 'staging'); PrereleaseStages = @() }
        $null = Update-QuarantineFromScan -RepositoryRoot $root -Settings $settings -Policy $bad -Diffs @(New-Diff -NewIds 'LC0100') -Chains $chains -Now $now
        Test-Path -LiteralPath (Join-Path $root 'quarantine.staging.json') | Should-BeFalse
    }

    It 'is byte-stable on a second run' {
        $diffs = @(New-Diff -NewIds 'LC0100')
        $null = Update-QuarantineFromScan -RepositoryRoot $root -Settings $settings -Policy $policy -Diffs $diffs -Chains $chains -Now $now
        $again = Update-QuarantineFromScan -RepositoryRoot $root -Settings $settings -Policy $policy -Diffs $diffs -Chains $chains -Now $now.AddDays(1)
        $again.Added | Should-BeCollection @()
        $again.Changes | Should-BeCollection @()
    }

    It 'leaves the id None in exactly the quarantined stages after regeneration (a disabled id stays unlisted)' {
        Edit-FixtureJson -Path (Join-Path $root 'catalog' 'diagnostics.json') -Script {
            $_.diagnostics += [ordered]@{ id = 'LC0100'; defaultSeverity = 'Info'; enabledByDefault = $true }
            $_.diagnostics += [ordered]@{ id = 'LC0102'; defaultSeverity = 'Info'; enabledByDefault = $false }
        }
        $null = Update-QuarantineFromScan -RepositoryRoot $root -Settings $settings -Policy $policy -Diffs @(New-Diff -NewIds 'LC0100', 'LC0102') -Chains $chains -Now $now
        $null = Update-RulebookEndpoints -RepositoryRoot $root
        foreach ($file in Get-ChildItem -LiteralPath (Join-Path $root 'rulesets') -Filter '*.ruleset.json') {
            $rules = (Read-RulesetFile -Path $file.FullName).Rules
            $expected = if ($file.Name -like '*.vnext.ruleset.json') { $null } else { 'None' }
            $(if ($rules.Contains('LC0100')) { $rules['LC0100'].Action } else { $null }) | Should-Be $expected -Because $file.Name
            $rules.Contains('LC0102') | Should-BeFalse -Because $file.Name
        }
    }
}

Describe 'ConvertFrom-QuarantineFileText' {
    It 'reads the ids in file order with their justifications' {
        $file = ConvertFrom-QuarantineFileText -Text '{ "$schema": "s", "rules": [ { "id": "LC0100", "justification": "New in 1.4.0" }, { "id": "AA0003" } ] }' -Path 'quarantine.ci.json'
        @($file.Rules.Keys) | Should-BeCollection @('LC0100', 'AA0003')
        $file.Rules['LC0100'] | Should-Be 'New in 1.4.0'
        $file.Rules['AA0003'] | Should-BeNull
        $file.Schema | Should-Be 's'
        $file.Exists | Should-BeTrue
    }

    It 'throws on <Case>' -ForEach @(
        @{ Case = 'text that is not JSON'; Text = '{ "rules": '; Message = 'Invalid JSON in quarantine.ci.json*' }
        @{ Case = 'no rules array'; Text = '{ "rules": {} }'; Message = 'quarantine.ci.json has no rules array' }
        @{ Case = 'an entry without an id'; Text = '{ "rules": [ { "justification": "x" } ] }'; Message = 'quarantine.ci.json has an entry without an id' }
        @{ Case = 'an id listed twice'; Text = '{ "rules": [ { "id": "LC0100" }, { "id": "LC0100" } ] }'; Message = 'quarantine.ci.json lists LC0100 twice (C2)' }
    ) {
        { ConvertFrom-QuarantineFileText -Text $Text -Path 'quarantine.ci.json' } | Should-Throw -ExceptionMessage $Message
    }
}

Describe 'Write-QuarantineFile' {
    BeforeAll {
        $script:sample = ConvertFrom-QuarantineFileText -Text '{ "rules": [ { "id": "LC0100", "justification": "New in 1.4.0" } ] }' -Path 'quarantine.ci.json'
    }

    It 'creates the file, then finds it current and leaves the bytes alone' {
        $path = Join-Path $TestDrive "created-$([guid]::NewGuid().ToString('n')).json"
        $change = Write-QuarantineFile -Path $path -File $sample -Name 'quarantine.ci.json'
        "$($change.File) $($change.Change)" | Should-Be 'quarantine.ci.json created'
        $bytes = [System.IO.File]::ReadAllBytes($path)
        Write-QuarantineFile -Path $path -File $sample | Should-BeNull
        [System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes($path)) | Should-Be ([System.Convert]::ToBase64String($bytes))
    }

    It 'round-trips what it wrote' {
        $path = Join-Path $TestDrive "round-$([guid]::NewGuid().ToString('n')).json"
        $null = Write-QuarantineFile -Path $path -File $sample
        $back = ConvertFrom-QuarantineFileText -Text ([System.IO.File]::ReadAllText($path)) -Path 'quarantine.ci.json'
        @($back.Rules.Keys) | Should-BeCollection @('LC0100')
        $back.Rules['LC0100'] | Should-Be 'New in 1.4.0'
    }

    It 'reports a modified file and writes nothing with -WhatIf' {
        $path = Join-Path $TestDrive "whatif-$([guid]::NewGuid().ToString('n')).json"
        [System.IO.File]::WriteAllText($path, '{ "rules": [] }')
        $change = Write-QuarantineFile -Path $path -File $sample -WhatIf
        $change.Change | Should-Be 'modified'
        [System.IO.File]::ReadAllText($path) | Should-Be '{ "rules": [] }'
    }
}
