# Common suite for #78: modules/Rulebook.Common, the git runner and the ordinal collections several engine modules
# share, the JSON schema evaluator (D56), and the engine ref with the URL builders (D52, #63). The git cases run
# against repositories in TestDrive (tests/Helpers/RepoFixture.ps1) and are skipped without git. The ref cases set
# GITHUB_ACTION_REF and GITHUB_ACTION_PATH and restore them after every case. The JsonSchema.Net build check runs in
# CI only; the member check runs everywhere.

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
        # A subject with Latin-1 letters and a check mark (U+2713), from code points: the suite stays ASCII
        # (PSUseBOMForUnicodeEncodedFile).
        $subject = -join ([char[]]@(0x00DC, 0x6E, 0x00EF, 0x63, 0x00F6, 0x64, 0x00E9, 0x20, 0x2713))
        $unicodeRoot = Get-TestFolder
        $null = New-FixtureGitRepo -Root $unicodeRoot -Message $subject
        $result = Invoke-Git -Root $unicodeRoot -Arguments @('log', '-1', '--format=%s')
        $result.ExitCode | Should-Be 0
        $result.Output.Trim() | Should-Be $subject
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

Describe 'ConvertFrom-JsonElement' {
    It 'reads every JSON kind, keys ordinal and in order, strings kept as strings' {
        $document = [System.Text.Json.JsonDocument]::Parse('{"b":"2026-10-18T10:00:00Z","a":[1.5,true,false,null],"B":{}}')
        try {
            $value = ConvertFrom-JsonElement $document.RootElement
        } finally {
            $document.Dispose()
        }
        $value | Should-HaveType ([System.Collections.Specialized.OrderedDictionary])
        @($value.Keys) | Should-BeCollection @('b', 'a', 'B')
        $value['b'] | Should-BeString '2026-10-18T10:00:00Z'
        $value['a'][0] | Should-Be 1.5
        $value['a'][1] | Should-BeTrue
        $value['a'][2] | Should-BeFalse
        $value['a'][3] | Should-BeNull
        $value['B'].Count | Should-Be 0
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

Describe 'Get-RulebookEngineRef and the URL builders' {
    BeforeEach {
        $script:savedRef = $env:GITHUB_ACTION_REF
        $script:savedPath = $env:GITHUB_ACTION_PATH
        Remove-Item Env:GITHUB_ACTION_REF, Env:GITHUB_ACTION_PATH -ErrorAction SilentlyContinue
    }

    AfterEach {
        $env:GITHUB_ACTION_REF = $script:savedRef
        $env:GITHUB_ACTION_PATH = $script:savedPath
    }

    It 'is main when GITHUB_ACTION_REF is <Case>' -ForEach @(
        @{ Case = 'not set'; Value = $null }
        @{ Case = 'empty'; Value = '' }
        @{ Case = 'whitespace'; Value = '  ' }
    ) {
        $env:GITHUB_ACTION_REF = $Value
        Get-RulebookEngineRef | Should-Be 'main'
    }

    It 'is GITHUB_ACTION_REF trimmed when it is set' {
        $env:GITHUB_ACTION_REF = " v1`t"
        Get-RulebookEngineRef | Should-Be 'v1'
    }

    It 'is read at every call, not at the import' {
        $env:GITHUB_ACTION_REF = 'v1'
        Get-RulebookEngineRef | Should-Be 'v1'
        $env:GITHUB_ACTION_REF = 'v2'
        Get-RulebookEngineRef | Should-Be 'v2'
    }

    It 'is the ref folder of GITHUB_ACTION_PATH for a checkout of the engine when GITHUB_ACTION_REF is empty (<Case>)' -ForEach @(
        @{ Case = 'Linux runner'; Path = '/home/runner/work/_actions/ALCops/rulebook-engine/v1/actions/Publish'; Expected = 'v1' }
        @{ Case = 'Windows runner'; Path = 'D:\a\_actions\ALCops\rulebook-engine\v2\actions\Validate'; Expected = 'v2' }
        @{ Case = 'engine CI, ./actions/Validate'; Path = '/home/runner/work/rulebook-engine/rulebook-engine/./actions/Validate'; Expected = 'main' }
        @{ Case = 'another repository'; Path = '/home/runner/work/_actions/contoso/rulebook-engine/v9/actions/Publish'; Expected = 'main' }
        @{ Case = 'Linux runner, a ref with a slash'; Path = '/home/runner/work/_actions/ALCops/rulebook-engine/wp13/references/actions/Publish'; Expected = 'wp13/references' }
        @{ Case = 'Windows runner, a ref with a slash'; Path = 'D:\a\_actions\ALCops\rulebook-engine\wp13\references\actions\Publish'; Expected = 'wp13/references' }
        @{ Case = 'a folder that is no usable ref'; Path = '/home/runner/work/_actions/ALCops/rulebook-engine/v1/../x/actions/Publish'; Expected = 'main' }
    ) {
        $env:GITHUB_ACTION_PATH = $Path
        Get-RulebookEngineRef | Should-Be $Expected
    }

    It 'prefers GITHUB_ACTION_REF over GITHUB_ACTION_PATH' {
        $env:GITHUB_ACTION_PATH = '/home/runner/work/_actions/ALCops/rulebook-engine/v1/actions/Publish'
        $env:GITHUB_ACTION_REF = 'v1.0.0-beta.1'
        Get-RulebookEngineRef | Should-Be 'v1.0.0-beta.1'
    }

    It 'skips a GITHUB_ACTION_REF that is no usable ref (<Value>) and falls through to GITHUB_ACTION_PATH, then main' -ForEach @(
        @{ Value = 'v1 x' }
        @{ Value = '../v1' }
        @{ Value = 'v1/../main' }
        @{ Value = '-v1' }
        @{ Value = 'v1"' }
        @{ Value = 'v1/' }
        @{ Value = 'wp13//references' }
        @{ Value = 'wp13/.references' }
    ) {
        $env:GITHUB_ACTION_REF = $Value
        Get-RulebookEngineRef | Should-Be 'main'
        $env:GITHUB_ACTION_PATH = '/home/runner/work/_actions/ALCops/rulebook-engine/v1/actions/Publish'
        Get-RulebookEngineRef | Should-Be 'v1'
    }

    It 'refuses an unusable -Ref in every builder: <Value>' -ForEach @(
        @{ Value = 'v1 x' }
        @{ Value = 'v1/../main' }
        @{ Value = 'v1/' }
        @{ Value = 'wp13//references' }
        @{ Value = 'wp13/.references' }
    ) {
        { Get-RulebookSchemaUrl -Name 'rulebook-settings.schema.json' -Ref $Value } | Should-Throw -ExceptionMessage '*is not a usable engine ref*'
        { Get-RulebookScriptUrl -Name 'Get-RulebookSkeletons.ps1' -Ref $Value } | Should-Throw -ExceptionMessage '*is not a usable engine ref*'
        { Get-RulebookDocsUrl -Page 'al-project.md' -Ref $Value } | Should-Throw -ExceptionMessage '*is not a usable engine ref*'
    }

    It 'builds the schema URL from the engine ref, or from -Ref' {
        Get-RulebookSchemaUrl -Name 'ruleset.delta.schema.json' | Should-Be 'https://raw.githubusercontent.com/ALCops/rulebook-engine/main/schemas/ruleset.delta.schema.json'
        $env:GITHUB_ACTION_REF = 'v1'
        Get-RulebookSchemaUrl -Name 'rulebook-settings.schema.json' | Should-Be 'https://raw.githubusercontent.com/ALCops/rulebook-engine/v1/schemas/rulebook-settings.schema.json'
        Get-RulebookSchemaUrl -Name 'rulebook-settings.schema.json' -Ref 'v2' | Should-Be 'https://raw.githubusercontent.com/ALCops/rulebook-engine/v2/schemas/rulebook-settings.schema.json'
        Get-RulebookSchemaUrl -Name 'rulebook-settings.schema.json' -Ref '' | Should-Be 'https://raw.githubusercontent.com/ALCops/rulebook-engine/v1/schemas/rulebook-settings.schema.json'
    }

    It 'builds the script URL from the engine ref, or from -Ref' {
        Get-RulebookScriptUrl -Name 'Get-RulebookSkeletons.ps1' | Should-Be 'https://raw.githubusercontent.com/ALCops/rulebook-engine/main/scripts/Get-RulebookSkeletons.ps1'
        $env:GITHUB_ACTION_REF = 'v1'
        Get-RulebookScriptUrl -Name 'Get-RulebookSkeletons.ps1' | Should-Be 'https://raw.githubusercontent.com/ALCops/rulebook-engine/v1/scripts/Get-RulebookSkeletons.ps1'
        Get-RulebookScriptUrl -Name 'New-RulebookOffLevel.ps1' -Ref 'main' | Should-Be 'https://raw.githubusercontent.com/ALCops/rulebook-engine/main/scripts/New-RulebookOffLevel.ps1'
    }

    It 'builds the docs URL on ALCops/rulebook from the engine ref, or from -Ref, mapped to the template ref' {
        Get-RulebookDocsUrl -Page 'ghtokenworkflow.md' | Should-Be 'https://github.com/ALCops/rulebook/blob/preview/docs/ghtokenworkflow.md'
        $env:GITHUB_ACTION_REF = 'v1'
        Get-RulebookDocsUrl -Page 'ghtokenworkflow.md' | Should-Be 'https://github.com/ALCops/rulebook/blob/main/docs/ghtokenworkflow.md'
        Get-RulebookDocsUrl -Page 'levels/strict.md' -Ref 'v1.0.0' | Should-Be 'https://github.com/ALCops/rulebook/blob/v1.0.0/docs/levels/strict.md'
    }

    It 'maps the engine ref <Ref> to the template ref <Expected> (GITHUB_ACTION_REF set and as -Ref)' -ForEach @(
        @{ Ref = 'v1'; Expected = 'main' }
        @{ Ref = 'v2'; Expected = 'main' }
        @{ Ref = 'main'; Expected = 'preview' }
        @{ Ref = 'v1.0.0'; Expected = 'v1.0.0' }
        @{ Ref = 'v1.0.0-beta.3'; Expected = 'v1.0.0-beta.3' }
        @{ Ref = '0123456789abcdef0123456789abcdef01234567'; Expected = 'main' }
        @{ Ref = 'issue-104/main-is-the-release'; Expected = 'preview' }
        @{ Ref = 'v1x'; Expected = 'preview' }
        @{ Ref = 'v1.0'; Expected = 'preview' }
    ) {
        Get-RulebookDocsUrl -Page 'al-project.md' -Ref $Ref | Should-Be "https://github.com/ALCops/rulebook/blob/$Expected/docs/al-project.md"
        $env:GITHUB_ACTION_REF = $Ref
        Get-RulebookDocsUrl -Page 'al-project.md' | Should-Be "https://github.com/ALCops/rulebook/blob/$Expected/docs/al-project.md"
    }

    It 'maps the ref folder of GITHUB_ACTION_PATH when GITHUB_ACTION_REF is unset' {
        $env:GITHUB_ACTION_PATH = Join-Path 'runner' '_actions' 'ALCops' 'rulebook-engine' 'v1' 'actions' 'Validate'
        Get-RulebookDocsUrl -Page 'al-project.md' | Should-Be 'https://github.com/ALCops/rulebook/blob/main/docs/al-project.md'
    }

    It 'falls back to main in the docs URL for a commit sha, which names no commit of the template repository' {
        $env:GITHUB_ACTION_REF = '0123456789abcdef0123456789abcdef01234567'
        Get-RulebookDocsUrl -Page 'al-project.md' | Should-Be 'https://github.com/ALCops/rulebook/blob/main/docs/al-project.md'
        Get-RulebookSchemaUrl -Name 'rulebook-twins.schema.json' | Should-Be 'https://raw.githubusercontent.com/ALCops/rulebook-engine/0123456789abcdef0123456789abcdef01234567/schemas/rulebook-twins.schema.json'
    }

    It 'refuses a name or page that is not a plain file path: <Value>' -ForEach @(
        @{ Value = '../x.json' }
        @{ Value = 'a b.json' }
        @{ Value = '' }
    ) {
        { Get-RulebookSchemaUrl -Name $Value } | Should-Throw
        { Get-RulebookScriptUrl -Name $Value } | Should-Throw
        { Get-RulebookDocsUrl -Page $Value } | Should-Throw
    }

    It 'refuses a docs page that leaves docs/' {
        { Get-RulebookDocsUrl -Page 'levels/../../README.md' } | Should-Throw
    }
}

Describe 'Test-RulebookSchema' {
    BeforeAll {
        $script:schemaDir = Join-Path $repoRoot 'schemas'
        $script:delta = Join-Path $schemaDir 'ruleset.delta.schema.json'
        # The first call loads JsonSchema.Net when this host has not yet (the Add-Type fallback of the module).
        $null = Test-RulebookSchema -Json '{}' -SchemaPath $delta
    }

    It 'runs on the JsonSchema.Net build the module names (CI only)' -Skip:(-not $env:GITHUB_ACTIONS) {
        $tested = InModuleScope Rulebook.Common { $script:JsonSchemaNetTested }
        $location = ('Json.Schema.JsonSchema' -as [type]).Assembly.Location
        ([System.Diagnostics.FileVersionInfo]::GetVersionInfo($location).ProductVersion -split '\+')[0] | Should-Be $tested
    }

    It 'finds the JsonSchema.Net members the module uses' {
        $schemaType = 'Json.Schema.JsonSchema' -as [type]
        $schemaType | Should-NotBeNull
        $schemaType.GetMethod('FromFile', [type[]]@([string])) | Should-NotBeNull
        $schemaType.GetMethod('Evaluate', [type[]]@([System.Text.Json.Nodes.JsonNode], ('Json.Schema.EvaluationOptions' -as [type]))) | Should-NotBeNull
        $optionsType = 'Json.Schema.EvaluationOptions' -as [type]
        $optionsType.GetProperty('OutputFormat').CanWrite | Should-BeTrue
        $optionsType.GetProperty('SchemaRegistry') | Should-NotBeNull
        $fetch = ('Json.Schema.SchemaRegistry' -as [type]).GetProperty('Fetch')
        $fetch.CanWrite | Should-BeTrue
        $fetch.PropertyType | Should-Be ([Func[[Uri], [Json.Schema.IBaseDocument]]])
        [enum]::GetNames(('Json.Schema.OutputFormat' -as [type])) | Should-ContainCollection @('List')
        $resultsType = 'Json.Schema.EvaluationResults' -as [type]
        foreach ($name in 'IsValid', 'Details', 'HasErrors', 'Errors', 'InstanceLocation') {
            $resultsType.GetProperty($name) | Should-NotBeNull -Because "EvaluationResults.$name"
        }
        $resultsType.GetProperty('Errors').PropertyType | Should-Be ([System.Collections.Generic.IReadOnlyDictionary[string, string]])
        # The members as the module calls them, on a real result: the pointer of the first detail with errors.
        $detail = InModuleScope Rulebook.Common -Parameters @{ Path = $delta } {
            param($Path)
            $node = [System.Text.Json.Nodes.JsonNode]::Parse('{ "name": "Rulebook Strict", "rules": [ { "id": "lc0015", "action": "None" } ] }')
            $results = (Get-CachedSchema -Path $Path).Evaluate($node, $script:SchemaOptions)
            @($results.Details | Where-Object HasErrors)[0]
        }
        $detail.InstanceLocation.ToString() | Should-Be '/rules/0/id'
        $pairs = @($detail.Errors.GetEnumerator())
        $pairs[0].Key | Should-Be 'pattern'
        $pairs[0].Value | Should-Be 'The string value is not a match for the indicated regular expression'
    }

    It 'prints a string const as one quoted value' {
        $changeSet = Join-Path $schemaDir 'rulebook-changeset.schema.json'
        $result = Test-RulebookSchema -Json '{"version":1,"changes":[{"op":"zzz"}]}' -SchemaPath $changeSet
        $result.Errors | Should-ContainCollection @('Expected "remove" at /changes/0/op')
    }

    It 'keeps an empty string const as an empty quoted value' {
        $path = Join-Path (Get-TestFolder) 'empty-const.schema.json'
        Write-FixtureText -Path $path -Text '{ "$schema": "https://json-schema.org/draft/2020-12/schema", "properties": { "x": { "const": "" } } }'
        (Test-RulebookSchema -Json '{ "x": "y" }' -SchemaPath $path).Errors[0] | Should-Be 'Expected "" at /x'
    }

    It 'accepts a valid text' {
        $result = Test-RulebookSchema -Json '{ "name": "Rulebook Strict", "rules": [ { "id": "LC0015", "action": "None" } ] }' -SchemaPath $delta
        $result.IsValid | Should-BeTrue
        @($result.Errors).Count | Should-Be 0
    }

    It 'names an error below the root with its JSON pointer' {
        $result = Test-RulebookSchema -Json '{ "name": "Rulebook Strict", "rules": [ { "id": "LC0015", "action": "Off" } ] }' -SchemaPath $delta
        $result.IsValid | Should-BeFalse
        $result.Errors[0] | Should-Be 'Value should match one of the values specified by the enum at /rules/0/action'
    }

    It 'names an error at the root as at the root' {
        $result = Test-RulebookSchema -Json '{}' -SchemaPath $delta
        $result.IsValid | Should-BeFalse
        $result.Errors[0] | Should-BeLikeString 'Required properties * are not present at the root'
    }

    It 'refuses a text that is not strict JSON' {
        $result = Test-RulebookSchema -Json '{ /* c */ "name": "x", "rules": [] }' -SchemaPath $delta
        $result.IsValid | Should-BeFalse
        @($result.Errors).Count | Should-Be 1
        $result.Errors[0] | Should-BeLikeString 'the text is not valid JSON: *'
    }

    It 'throws when the schema file is missing' {
        { Test-RulebookSchema -Json '{}' -SchemaPath (Join-Path (Get-TestFolder) 'missing.schema.json') } | Should-Throw -ExceptionMessage 'The schema * cannot be read: *'
    }

    It 'throws when the schema file is not JSON' {
        $path = Join-Path (Get-TestFolder) 'broken.schema.json'
        Write-FixtureText -Path $path -Text '{ "type": '
        { Test-RulebookSchema -Json '{}' -SchemaPath $path } | Should-Throw -ExceptionMessage 'The schema * cannot be read: *'
    }

    It 'throws when the sibling schema of a $ref is missing' {
        $path = Join-Path (Get-TestFolder) 'ruleset.delta.schema.json'
        Copy-Item -LiteralPath $delta -Destination $path
        { Test-RulebookSchema -Json '{}' -SchemaPath $path } | Should-Throw -ExceptionMessage 'The schema * cannot be evaluated: *'
    }

    It 'parses a schema file once per session' {
        $path = Join-Path (Get-TestFolder) 'rulebook-twins.schema.json'
        Copy-Item -LiteralPath (Join-Path $schemaDir 'rulebook-twins.schema.json') -Destination $path
        $before = InModuleScope Rulebook.Common { $script:SchemaCache.Count }
        $null = Test-RulebookSchema -Json '{}' -SchemaPath $path
        InModuleScope Rulebook.Common { $script:SchemaCache.Count } | Should-Be ($before + 1)
        $null = Test-RulebookSchema -Json '{}' -SchemaPath $path
        InModuleScope Rulebook.Common { $script:SchemaCache.Count } | Should-Be ($before + 1)
    }
}