# Schema suite for WP02 (#4): every schema under schemas/ against its fixtures under tests/fixtures/schemas/.
# Fixture convention: tests/fixtures/schemas/<valid|invalid>/<schema-basename>/<reason>.json, where
# schemas/<schema-basename>.schema.json is the schema. See docs/reference/naming.md section 7.

BeforeDiscovery {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $schemaDir = Join-Path $repoRoot 'schemas'
    $fixtureDir = Join-Path $PSScriptRoot 'fixtures' 'schemas'

    $script:schemaCases = @(Get-ChildItem -Path $schemaDir -Filter '*.schema.json' | Sort-Object Name | ForEach-Object {
            @{ Name = $_.Name; Path = $_.FullName; Base = $_.Name -replace '\.schema\.json$', '' }
        })
    $script:profileCases = @($script:schemaCases | Where-Object { $_.Name -ne 'ruleset.schema.json' })

    $script:fixtureCases = @(Get-ChildItem -Path $fixtureDir -Recurse -Filter '*.json' | Sort-Object FullName | ForEach-Object {
            @{
                Name   = '{0}/{1}/{2}' -f $_.Directory.Parent.Name, $_.Directory.Name, $_.Name
                Path   = $_.FullName
                Kind   = $_.Directory.Parent.Name
                Base   = $_.Directory.Name
                Schema = Join-Path $schemaDir "$($_.Directory.Name).schema.json"
            }
        })

    $script:suites = @($script:profileCases | ForEach-Object {
            $base = $_.Base
            @{
                Base    = $base
                Valid   = @($script:fixtureCases | Where-Object { $_.Base -eq $base -and $_.Kind -eq 'valid' } | ForEach-Object { @{ Name = [System.IO.Path]::GetFileNameWithoutExtension($_.Path); Path = $_.Path; Schema = $_.Schema } })
                Invalid = @($script:fixtureCases | Where-Object { $_.Base -eq $base -and $_.Kind -eq 'invalid' } | ForEach-Object { @{ Name = [System.IO.Path]::GetFileNameWithoutExtension($_.Path); Path = $_.Path; Schema = $_.Schema } })
            }
        })

    $hub = Join-Path $schemaDir 'ruleset.schema.json'
    $script:hubValidCases = @($script:fixtureCases | Where-Object { $_.Kind -eq 'valid' -and $_.Base -like 'ruleset.*' } | ForEach-Object {
            @{ Name = $_.Name; Path = $_.Path; Hub = $hub }
        })
    $script:hubDefaultCases = @(
        'invalid/ruleset.delta/rule-action-default.json',
        'invalid/ruleset.endpoint/action-default.json',
        'invalid/ruleset.skeleton/rule-action-default.json'
    ) | ForEach-Object { @{ Name = $_; Path = Join-Path $fixtureDir $_; Hub = $hub } }

    $namingPath = Join-Path $repoRoot 'docs' 'reference' 'naming.md'
    $namingText = (Get-Content -Path $namingPath -Raw) -replace "`r`n", "`n"
    $index = 0
    $script:namingBlocks = @([regex]::Matches($namingText, '(?ms)^```json\n(.*?)^```') | ForEach-Object {
            $index++
            @{ Name = "block $index"; Json = $_.Groups[1].Value }
        })
}

BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:schemaDir = Join-Path $script:repoRoot 'schemas'
    $script:fixtureDir = Join-Path $PSScriptRoot 'fixtures' 'schemas'
}

Describe 'Schema files' {
    It '<Name> parses and declares draft 2020-12' -ForEach $schemaCases {
        $json = Get-Content -Path $Path -Raw | ConvertFrom-Json -AsHashtable
        $json['$schema'] | Should-Be 'https://json-schema.org/draft/2020-12/schema'
    }

    It '<Name> has no $id' -ForEach $schemaCases {
        $json = Get-Content -Path $Path -Raw | ConvertFrom-Json -AsHashtable
        $json.ContainsKey('$id') | Should-BeFalse
    }

    It '<Name> has valid and invalid fixtures' -ForEach $profileCases {
        Test-Path -Path (Join-Path $fixtureDir 'valid' $Base) -PathType Container | Should-BeTrue
        Test-Path -Path (Join-Path $fixtureDir 'invalid' $Base) -PathType Container | Should-BeTrue
    }
}

Describe 'Shared definitions' {
    BeforeAll {
        $script:defs = foreach ($file in Get-ChildItem -Path $schemaDir -Filter '*.schema.json') {
            $json = Get-Content -Path $file.FullName -Raw | ConvertFrom-Json -AsHashtable
            if ($json.ContainsKey('$defs')) { $json['$defs'] }
        }
    }

    It 'diagnosticId is the same pattern in every schema that defines it' {
        $patterns = @($defs | Where-Object { $_.ContainsKey('diagnosticId') } | ForEach-Object { $_['diagnosticId']['pattern'] })
        $patterns.Count | Should-BeGreaterThan 1
        @($patterns | Sort-Object -Unique) | Should-BeCollection @('^[A-Z]{2,3}[0-9]{4}i?$')
    }

    It 'ruleAction is the same enum in every schema that defines it' {
        $enums = @($defs | Where-Object { $_.ContainsKey('ruleAction') } | ForEach-Object { $_['ruleAction']['enum'] -join ',' })
        $enums.Count | Should-BeGreaterThan 1
        @($enums | Sort-Object -Unique) | Should-BeCollection @('Error,Warning,Info,Hidden,None')
    }

    It 'slug is the same pattern in every schema that defines it' {
        $patterns = @($defs | Where-Object { $_.ContainsKey('slug') } | ForEach-Object { $_['slug']['pattern'] })
        $patterns.Count | Should-BeGreaterThan 1
        @($patterns | Sort-Object -Unique) | Should-BeCollection @('^[a-z0-9-]+$')
    }
}

Describe 'Fixtures' {
    It '<Name> is well-formed JSON' -ForEach $fixtureCases {
        Test-Json -Path $Path | Should-BeTrue
    }

    It '<Name> sits in a folder named after a schema' -ForEach $fixtureCases {
        $Kind | Should-MatchString '^(valid|invalid)$'
        Test-Path -Path $Schema -PathType Leaf | Should-BeTrue
    }
}

Describe '<Base>' -ForEach $suites {
    It 'accepts <Name>' -ForEach $Valid {
        Test-Json -Path $Path -SchemaFile $Schema | Should-BeTrue
    }

    It 'rejects <Name>' -ForEach $Invalid {
        Test-Json -Path $Path -SchemaFile $Schema -ErrorAction SilentlyContinue | Should-BeFalse
    }
}

Describe 'ruleset.schema.json (hub)' {
    It 'accepts <Name>' -ForEach $hubValidCases {
        Test-Json -Path $Path -SchemaFile $Hub | Should-BeTrue
    }

    It 'accepts an endpoint rule with a justification, because the delta profile allows it (anyOf)' {
        $path = Join-Path $fixtureDir 'invalid' 'ruleset.endpoint' 'with-justification.json'
        Test-Json -Path $path -SchemaFile (Join-Path $schemaDir 'ruleset.schema.json') | Should-BeTrue
    }

    It 'rejects <Name>' -ForEach $hubDefaultCases {
        Test-Json -Path $Path -SchemaFile $Hub -ErrorAction SilentlyContinue | Should-BeFalse
    }
}

Describe 'Live files' {
    It 'docs/rulebook/matrix/twins.json matches rulebook-twins.schema.json' {
        $path = Join-Path $repoRoot 'docs' 'rulebook' 'matrix' 'twins.json'
        Test-Json -Path $path -SchemaFile (Join-Path $schemaDir 'rulebook-twins.schema.json') | Should-BeTrue
    }
}

Describe 'docs/reference/naming.md' {
    It 'has JSON examples' -ForEach @(@{ Count = $namingBlocks.Count }) {
        $Count | Should-BeGreaterThan 0
    }

    It 'json <Name> parses' -ForEach $namingBlocks {
        Test-Json -Json $Json | Should-BeTrue
    }
}
