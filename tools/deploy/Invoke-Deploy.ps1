#requires -Version 7.4
<#
.SYNOPSIS
Releases the engine and the template, or refreshes ALCops/rulebook@main, from this checkout (D52).

.DESCRIPTION
The entry script of .github/workflows/Deploy.yaml (-Mode release) and .github/workflows/RefreshTemplate.yaml (-Mode
refresh). It reads the GitHub App from DEPLOY_APP_ID (the Client ID) and DEPLOY_APP_PRIVATE_KEY, the commit to deploy
from GITHUB_SHA and the summary file from GITHUB_STEP_SUMMARY, runs Invoke-RulebookDeploy of modules/Rulebook.Deploy
and exits with its exit code: 0 when the deploy (or the dry run) went through, 1 on a refusal or a failure, each one
an error annotation and a line in the job summary.

Release: the version and the notes come from the top heading of RELEASENOTES.md; the template repository gets
template/ on v<major> with every engine and template reference rewritten to that branch and the tag; the engine gets
v<major> moved to GITHUB_SHA and the tag; the engine gets a GitHub Release with the notes. Refresh: template/ is
copied verbatim to ALCops/rulebook@main, without tag or release. -DryRun stops after the checks and prints the plan.
The procedure is docs/releasing.md.

.PARAMETER Mode
release or refresh.

.PARAMETER DryRun
Checks everything (the App, the tags, CI of the commit, the checkout) and writes the plan to the summary; pushes
nothing. Also set by DRY_RUN=true.

.EXAMPLE
./tools/deploy/Invoke-Deploy.ps1 -Mode release -DryRun
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Mandatory)][ValidateSet('release', 'refresh')][string]$Mode,
    [switch]$DryRun
)

Set-StrictMode -Version 3.0
$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..' '..')).ProviderPath
Import-Module (Join-Path $repositoryRoot 'modules' 'Rulebook.Deploy.psd1') -Force

$deploy = @{
    Mode           = $Mode
    RepositoryRoot = $repositoryRoot
    Sha            = $env:GITHUB_SHA
    AppClientId    = $env:DEPLOY_APP_ID
    AppPrivateKey  = $env:DEPLOY_APP_PRIVATE_KEY
    DryRun         = $DryRun -or $env:DRY_RUN -eq 'true'
    SummaryPath    = $env:GITHUB_STEP_SUMMARY
    KeepPath       = (Join-Path $PSScriptRoot 'keep.txt')
}
# The App key is in $deploy now; git and every other child process of the deploy must not inherit it.
Remove-Item Env:DEPLOY_APP_ID, Env:DEPLOY_APP_PRIVATE_KEY -ErrorAction SilentlyContinue
$result = Invoke-RulebookDeploy @deploy
if ([string]::IsNullOrEmpty($env:GITHUB_STEP_SUMMARY)) { Write-Host $result.Summary }
exit $result.ExitCode
