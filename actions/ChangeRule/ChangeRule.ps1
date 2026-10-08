#requires -Version 7.4
<#
.SYNOPSIS
Entry script of the ChangeRule action: set or remove one override entry for a level and stage selection and land it
as a pull request (or a direct commit).
.DESCRIPTION
1. Reads the settings: the secret name (ghTokenWorkflowSecretName) and the labels (commitOptions.pullRequestLabels).
2. Builds a one-item change set (ConvertTo-RulebookChangeSet; -Action Remove deletes the matching entry) and plans it
   on a candidate copy (Invoke-RulebookChangeSet; the repository itself is never written). A finding (rule id,
   action, selectors, a remove without a matching entry) is one error annotation each, failure validation; a
   candidate that does not validate gives one error annotation per finding, "The changed rulebook would not validate:".
3. A no-op (no endpoint changes, overrides.json would not change, D48) is one notice, result no-op, noop true and exit
   code 0; it needs no token.
4. The token guard: an invalid ghTokenWorkflowSecretName or an empty -Token is failure token; the token is exchanged
   (Get-GitHubAccessToken) and masked before anything else runs.
5. Publish-RulebookChange (or -PublishCommand) on change-rule/<ruleId>/<yyMMddHHmmss UTC>: pull-request, or
   direct-commit with -DirectCommit (the workflow derives it from commitOptions.createPullRequest, D47; a refused
   push falls back to the pull request). Failures are push or pull-request with the token hint.
6. The job summary (ConvertTo-ChangeSummary, capped at -SummaryLimit) and GITHUB_OUTPUT: result (pull-request,
   direct-commit, no-op), noop, changedEndpoints (comma separated), pullRequestUrl, branch and failure (validation,
   token, push, pull-request, error; empty on success).
Returns { ExitCode, Result, NoOp, Failure, Plan, Publish, Annotations, Summary, Outputs } and never calls exit, so tests
run it in-process; action.yaml exits with ExitCode. -RemoteUrl, -ApiUrl, -WorkPath, -SummaryLimit, -Now and
-PublishCommand are test seams; a -WorkPath the caller passes is left in place, the temporary work folder the script
names itself is removed at the end.
#>
[CmdletBinding()]
param(
    [string]$RepositoryRoot = '.',
    [AllowEmptyString()][string]$RuleId,
    [AllowEmptyString()][string]$Action,
    [AllowEmptyString()][string]$Levels = '*',
    [AllowEmptyString()][string]$Stages = '*',
    [AllowEmptyString()][string]$Justification,
    [AllowEmptyString()][string]$Token,
    [switch]$DirectCommit,
    [AllowEmptyString()][string]$BaseBranch = $env:GITHUB_REF_NAME,
    [AllowEmptyString()][string]$Actor = $env:GITHUB_ACTOR,
    [AllowEmptyString()][string]$Repository = $env:GITHUB_REPOSITORY,
    [AllowEmptyString()][string]$RemoteUrl,
    [string]$ApiUrl = $(if ($env:GITHUB_API_URL) { $env:GITHUB_API_URL } else { 'https://api.github.com' }),
    [string]$WorkPath,
    [string]$SummaryPath = $env:GITHUB_STEP_SUMMARY,
    [string]$WorkspaceRoot = $env:GITHUB_WORKSPACE,
    [int]$SummaryLimit = 900KB,
    [System.DateTimeOffset]$Now = [System.DateTimeOffset]::UtcNow,
    # Test seam: runs instead of Publish-RulebookChange with the same parameters (the script re-imports the modules,
    # so a Pester mock of the function does not reach it).
    [scriptblock]$PublishCommand
)

Set-StrictMode -Version 3.0
$modules = Join-Path $PSScriptRoot '..' '..' 'modules'
Import-Module (Join-Path $modules 'Rulebook.Generate.psd1') -Force
Import-Module (Join-Path $modules 'Rulebook.GitHub.psd1') -Force
Import-Module (Join-Path $modules 'Rulebook.Update.psd1') -Force
Import-Module (Join-Path $modules 'Rulebook.Edit.psd1') -Force
Import-Module (Join-Path $modules 'Rulebook.Action.psd1') -Force

$docsUrl = 'https://github.com/ALCops/rulebook/blob/main/docs/ghtokenworkflow.md'

$ownWork = [string]::IsNullOrEmpty($WorkPath)
if ($ownWork) {
    $tempRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [System.IO.Path]::GetTempPath() }
    $WorkPath = Join-Path $tempRoot ('rulebook-change-' + [guid]::NewGuid().ToString('n').Substring(0, 8))
}
$WorkPath = Resolve-ActionPath $WorkPath
$ctx = New-ActionContext -Title 'ChangeRule'

# Every token obtained by an exchange is masked before anything can print it.
$maskToken = { param([string]$Value) if (-not [string]::IsNullOrEmpty($Value)) { Write-Host "::add-mask::$Value" } }
$plan = $null
$publish = $null
$result = $null
$summaryMessage = $null
$failed = $false
$secretName = 'GHTOKENWORKFLOW'
$split = { param([string]$Value) [string[]]@($Value.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }) }

try {
    # 1. Settings: the secret name and the labels.
    $root = (Resolve-Path -LiteralPath $RepositoryRoot -ErrorAction Stop).ProviderPath
    $workspace = if ([string]::IsNullOrEmpty($WorkspaceRoot)) { $root } else { (Resolve-Path -LiteralPath $WorkspaceRoot -ErrorAction Stop).ProviderPath }
    $separator = [System.IO.Path]::DirectorySeparatorChar
    $settingsFile = Join-Path $root '.github' 'Rulebook-Settings.json'
    $settings = $null
    if (Test-Path -LiteralPath $settingsFile -PathType Leaf) {
        try { $settings = Get-Content -LiteralPath $settingsFile -Raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop } catch { $settings = $null }
    }
    $setting = { param([string[]]$Path) $value = $settings; foreach ($key in $Path) { if ($value -isnot [System.Collections.IDictionary] -or -not $value.Contains($key)) { return $null }; $value = $value[$key] }; return $value }
    $name = [string](& $setting 'ghTokenWorkflowSecretName')
    $nameValid = $name -cmatch '^[A-Za-z_][A-Za-z0-9_]*$' -and $name -inotmatch '^GITHUB_'
    if (-not [string]::IsNullOrEmpty($name) -and $nameValid) { $secretName = $name }
    $labels = [string[]]@(& $setting 'commitOptions', 'pullRequestLabels' | Where-Object { $_ -is [string] -and $_ -ne '' })

    # 2. The change set and the plan, on a candidate copy.
    $changeSet = ConvertTo-RulebookChangeSet -RuleId ([string]$RuleId) -Action ([string]$Action) -Levels (& $split ([string]$Levels)) -Stages (& $split ([string]$Stages)) -Justification $Justification
    $plan = Invoke-RulebookChangeSet -RepositoryRoot $root -ChangeSet $changeSet -WorkPath (Join-Path $WorkPath 'plan') -Now $Now
    if ($plan.Failure -or -not $plan.Valid) {
        $prefix = if ($null -ne $plan.CandidatePath) { 'The changed rulebook would not validate: ' } else { '' }
        foreach ($finding in @($plan.Findings | Where-Object Severity -EQ 'error')) {
            $message = if ($finding.Id -and $finding.Rule -cne 'change') { "$($finding.Id): $($finding.Message)" } else { $finding.Message }
            $file = if ($finding.File) { [System.IO.Path]::GetRelativePath($workspace, (Join-Path $root $finding.File)).Replace($separator, '/') } else { $null }
            Add-Annotation -Context $ctx -File $file -Title $(if ($finding.Rule -ceq 'change') { 'ChangeRule' } else { $finding.Rule }) -Message "$prefix$message"
        }
        Add-Failure -Context $ctx -Kind 'validation'
        $summaryMessage = if ($prefix) { 'The changed rulebook does not validate; nothing was pushed.' } else { 'The change is not valid; nothing was written.' }
        $failed = $true
    } elseif ($plan.NoOp) {
        # 3. Nothing would change (D48).
        $item = @($plan.Items)[0]
        $endpoints = @($item.Rows | ForEach-Object Endpoint) -join ', '
        $summaryMessage = "No change: $($item.Id) is already $($item.Action) on every matching endpoint ($endpoints); overrides.json was not written"
        Add-Annotation -Context $ctx -Command notice -Message $summaryMessage
        $result = 'no-op'
    } else {
        # 4. The token guard, after the local plan: a validation error or a no-op needs no secret.
        if (-not [string]::IsNullOrEmpty($name) -and -not $nameValid) {
            Add-Failure -Context $ctx -Kind 'token'
            throw "ghTokenWorkflowSecretName '$name' in .github/Rulebook-Settings.json is not a valid secret name (letters, digits and underscores, not starting with a digit or GITHUB_). Read $docsUrl"
        }
        if ([string]::IsNullOrWhiteSpace($Token)) {
            Add-Failure -Context $ctx -Kind 'token'
            throw "The $secretName secret is needed to change a rule. Read $docsUrl"
        }
        if ([string]::IsNullOrEmpty($Repository)) { throw 'The change needs the repository (GITHUB_REPOSITORY) as owner/name.' }
        if ([string]::IsNullOrEmpty($BaseBranch)) { throw 'The change needs baseBranch.' }
        try {
            $access = Get-GitHubAccessToken -Token $Token -Repository $Repository -ApiUrl $ApiUrl
        } catch {
            Add-Failure -Context $ctx -Kind 'token'
            throw "The $secretName secret could not be used: $($_.Exception.Message)"
        }
        if (-not [string]::IsNullOrEmpty($access.Token)) { & $maskToken $access.Token }
        Write-Host "Write token: $($access.Kind)"

        # 5. Publish.
        try {
            $publishParameters = @{
                Plan = $plan; RepositoryRoot = $root; Repository = $Repository; RemoteUrl = $RemoteUrl; Token = $access.Token; BaseBranch = $BaseBranch
                BranchPrefix = "change-rule/$($plan.Items[0].Id)"; DirectCommit = [bool]$DirectCommit; Actor = $Actor; Labels = $labels
                WorkPath = (Join-Path $WorkPath 'publish'); ApiUrl = $ApiUrl; Now = $Now
            }
            $publish = if ($null -ne $PublishCommand) { & $PublishCommand @publishParameters } else { Publish-RulebookChange @publishParameters }
        } catch {
            $stage = [string]$_.Exception.Data['Stage']
            if ($stage -cnotin 'push', 'pull-request') { $stage = 'push' }
            Add-Failure -Context $ctx -Kind $stage
            # The base branch moved between plan and publish: nothing is wrong with the token; run the workflow again.
            if ([string]$_.Exception.Data['Reason'] -ceq 'base-moved') { throw $_.Exception.Message }
            $what = if ($stage -eq 'pull-request') { 'Failed to create the pull request for the rule change' } else { 'Failed to push the rule change' }
            throw "$what. Make sure that the token in the secret $secretName is not expired and may write contents and pull requests of $Repository. Read $docsUrl (Error was: $($_.Exception.Message))"
        }
        $result = $publish.Result
        switch ($publish.Result) {
            'direct-commit' { $summaryMessage = "Rule change committed to $($publish.Branch) ($(Get-ShortSha $publish.Sha))" }
            'no-changes' { $summaryMessage = 'No changes to commit' }
            default { $summaryMessage = "Pull request: $($publish.PullRequestUrl)" + $(if ($publish.Fallback) { ' (the direct commit was refused)' } else { '' }) }
        }
        Add-Annotation -Context $ctx -Command notice -Message $summaryMessage
    }
} catch {
    Add-Annotation -Context $ctx -Message $_.Exception.Message
    Add-Failure -Context $ctx -Kind 'error'
    $summaryMessage = $_.Exception.Message
    $failed = $true
} finally {
    if ($ownWork -and (Test-Path -LiteralPath $WorkPath)) { Remove-Item -LiteralPath $WorkPath -Recurse -Force -ErrorAction SilentlyContinue }
}

# 6. Summary and outputs.
$summary = "## Rule change`n`n$(ConvertTo-SingleLine $summaryMessage)`n`n"
if ($null -ne $plan) {
    try {
        $summary = ConvertTo-ChangeSummary -Plan $plan -Result $publish -Message $summaryMessage
    } catch {
        Write-Host "The summary could not be written in full: $($_.Exception.Message)"
    }
}
$summary = $summary.Replace("`r`n", "`n")
# The runner caps a step summary at 1 MiB; stay well below it (-SummaryLimit, 900 KiB).
$where = if ($null -ne $publish -and $publish.PSObject.Properties['Body'] -and $publish.Body) { 'the pull request body' } else { 'the job log' }
$summary = Limit-SummaryText -Text $summary -MaxBytes $SummaryLimit -Footer "The summary was cut at $([math]::Round($SummaryLimit / 1KB)) KiB; the full tables are in $where."
Write-Text -Path $SummaryPath -Text $summary
$changed = if ($null -ne $plan -and -not $failed) { @($plan.Items | ForEach-Object { $_.ChangedEndpoints } | Select-Object -Unique) -join ',' } else { '' }
$outputs = [ordered]@{
    result           = $(if ($failed -or -not $result) { '' } else { $result })
    noop             = $(if (-not $failed -and $result -eq 'no-op') { 'true' } else { 'false' })
    changedEndpoints = $changed
    pullRequestUrl   = $(if ($null -ne $publish -and $publish.PullRequestUrl) { $publish.PullRequestUrl } else { '' })
    branch           = $(if ($null -ne $publish -and $publish.Branch) { $publish.Branch } else { '' })
    failure          = $ctx.Failure
}
Write-ActionOutput -Outputs $outputs
[pscustomobject]@{
    ExitCode    = $(if ($failed) { 1 } else { 0 })
    Result      = $outputs.result
    NoOp        = $outputs.noop -eq 'true'
    Failure     = $ctx.Failure
    Plan        = $plan
    Publish     = $publish
    Annotations = $ctx.Annotations.ToArray()
    Summary     = $summary
    Outputs     = $outputs
}
