# Engine ref isolation for the suites that assert URLs built by the Rulebook.Common builders (D52): the builders read
# GITHUB_ACTION_REF and GITHUB_ACTION_PATH at every call, and a runner step of an action sets both. A suite clears
# them in its BeforeAll and restores them in its AfterAll, so its literal main URLs hold wherever it runs:
#
#   BeforeAll { . (Join-Path $PSScriptRoot 'Helpers' 'EngineRef.ps1'); $script:savedEngineRef = Clear-EngineRefEnvironment }
#   AfterAll { Restore-EngineRefEnvironment -Saved $script:savedEngineRef }

function Clear-EngineRefEnvironment {
    # Removes GITHUB_ACTION_REF and GITHUB_ACTION_PATH from the process environment and returns their old values.
    $saved = @{ Ref = $env:GITHUB_ACTION_REF; Path = $env:GITHUB_ACTION_PATH }
    Remove-Item Env:GITHUB_ACTION_REF, Env:GITHUB_ACTION_PATH -ErrorAction SilentlyContinue
    return $saved
}

function Restore-EngineRefEnvironment {
    # Puts back the values Clear-EngineRefEnvironment returned (a null value leaves the variable unset).
    param([Parameter(Mandatory)][hashtable]$Saved)
    $env:GITHUB_ACTION_REF = $Saved['Ref']
    $env:GITHUB_ACTION_PATH = $Saved['Path']
}
