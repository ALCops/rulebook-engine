#requires -Version 7.4
<#
.SYNOPSIS
Entry script of the CheckForUpdates action: check an organization rulebook repository against its template, or pull
the new template version into a pull request (-Update).
.DESCRIPTION
Resolves the template URL (-TemplateUrl, else templateUrl of the settings) and the template (Get-RulebookTemplate:
the zipball download, or -TemplatePath and -InstalledTemplatePath as local folders), builds the update plan
(Get-RulebookUpdatePlan) and then:

- check mode: one notice (no updates; templateSha not recorded) or warning (updates available; check skipped) and the
  summary. A template that cannot be read or a plan that does not validate is the warning 'update check skipped:
  <reason>' with exit code 0.
- update mode (-Update): needs -Token (the GHTOKENWORKFLOW value) before any request; a plan that does not validate
  fails with one error annotation per finding and pushes nothing; otherwise the token is exchanged and masked and
  Publish-RulebookUpdate opens the pull request (or pushes the direct commit).

Writes the outputs updatesAvailable, pullRequestUrl, templateSha and failure (token, template, validation, push,
pull-request, error; empty on success) to GITHUB_OUTPUT and returns { ExitCode, Mode, Failure, UpdatesAvailable,
TemplateSha, PullRequestUrl, Plan, Result, Annotations, Summary }. Never calls exit, so tests run it in-process;
action.yaml exits with ExitCode. -RemoteUrl, -ApiUrl, -GitHubToken, -WorkPath, -SummaryLimit (bytes) and -PublishCommand are test seams; a -WorkPath the caller
passes is left in place, the temporary work folder the script names itself is removed at the end.
#>
[CmdletBinding()]
param(
    [string]$RepositoryRoot = '.',
    [AllowEmptyString()][string]$TemplateUrl,
    [AllowEmptyString()][string]$TemplatePath,
    [AllowEmptyString()][string]$InstalledTemplatePath,
    [AllowEmptyString()][string]$TemplateSha,
    [AllowEmptyString()][string]$Token,
    [switch]$Update,
    [bool]$DownloadLatest = $true,
    [switch]$DirectCommit,
    [AllowEmptyString()][string]$UpdateBranch = $env:GITHUB_REF_NAME,
    [AllowEmptyString()][string]$Actor = $env:GITHUB_ACTOR,
    [AllowEmptyString()][string]$Repository = $env:GITHUB_REPOSITORY,
    [AllowEmptyString()][string]$RemoteUrl,
    [string]$ApiUrl = $(if ($env:GITHUB_API_URL) { $env:GITHUB_API_URL } else { 'https://api.github.com' }),
    [AllowEmptyString()][string]$GitHubToken = $env:GITHUB_TOKEN,
    [string]$WorkPath,
    [string]$SummaryPath = $env:GITHUB_STEP_SUMMARY,
    [string]$WorkspaceRoot = $env:GITHUB_WORKSPACE,
    [int]$SummaryLimit = 900KB,
    # Test seam: runs instead of Publish-RulebookUpdate with the same parameters (the script re-imports the modules,
    # so a Pester mock of the function does not reach it).
    [scriptblock]$PublishCommand
)

Set-StrictMode -Version 3.0
$modules = Join-Path $PSScriptRoot '..' '..' 'modules'
Import-Module (Join-Path $modules 'Rulebook.Generate.psd1') -Force
Import-Module (Join-Path $modules 'Rulebook.GitHub.psd1') -Force
Import-Module (Join-Path $modules 'Rulebook.Update.psd1') -Force

$docsUrl = 'https://github.com/ALCops/rulebook/blob/main/docs/ghtokenworkflow.md'

function Format-AnnotationText {
    # Workflow command escaping: the message part escapes %, CR and LF; a property value also : and ,.
    param([AllowNull()][string]$Text, [switch]$Property)
    if ($null -eq $Text) { return '' }
    $escaped = $Text.Replace('%', '%25').Replace("`r", '%0D').Replace("`n", '%0A')
    if ($Property) { $escaped = $escaped.Replace(':', '%3A').Replace(',', '%2C') }
    return $escaped
}

function ConvertTo-SingleLine {
    # A message on one Markdown line (list item or paragraph); no table escaping.
    param([AllowNull()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    return $Text.Replace("`r", ' ').Replace("`n", ' ')
}

function Add-Annotation {
    param([ValidateSet('error', 'warning', 'notice')][string]$Command = 'error', [string]$File, [string]$Title = 'CheckForUpdates', [Parameter(Mandatory)][string]$Message)
    $properties = "title=$(Format-AnnotationText $Title -Property)"
    if ($File) { $properties = "file=$(Format-AnnotationText $File -Property),$properties" }
    $line = "::$Command $properties::$(Format-AnnotationText $Message)"
    $script:annotations.Add($line)
    if ($Command -eq 'error') { $script:errorMessages.Add($Message) }
    Write-Host $line
}

function Write-Text {
    param([AllowNull()][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrEmpty($Path)) { return }
    [System.IO.File]::AppendAllText($Path, $Text.Replace("`r`n", "`n"), [System.Text.UTF8Encoding]::new($false))
}

# [System.IO.File] resolves a relative path against the process directory, not the PowerShell location.
$resolvePath = { param($Path) if ([string]::IsNullOrEmpty($Path)) { $Path } else { $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path) } }
$SummaryPath = & $resolvePath $SummaryPath
$ownWork = [string]::IsNullOrEmpty($WorkPath)
if ($ownWork) {
    $tempRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [System.IO.Path]::GetTempPath() }
    $WorkPath = Join-Path $tempRoot ('rulebook-update-' + [guid]::NewGuid().ToString('n').Substring(0, 8))
}
$WorkPath = & $resolvePath $WorkPath
$script:annotations = [System.Collections.Generic.List[string]]::new()
$script:errorMessages = [System.Collections.Generic.List[string]]::new()
$script:failure = $null
function Add-Failure {
    param([Parameter(Mandatory)][string]$Kind)
    if ($null -eq $script:failure) { $script:failure = $Kind }
}

# Every token obtained by an exchange is masked before anything can print it.
$maskToken = { param([string]$Value) if (-not [string]::IsNullOrEmpty($Value)) { Write-Host "::add-mask::$Value" } }
$mode = if ($Update) { 'update' } else { 'check' }
$plan = $null
$publish = $null
$template = $null
$updatesAvailable = $false
$summaryMessage = $null
$failed = $false
$secretName = 'GHTOKENWORKFLOW'

try {
    $root = (Resolve-Path -LiteralPath $RepositoryRoot -ErrorAction Stop).ProviderPath
    $workspace = if ([string]::IsNullOrEmpty($WorkspaceRoot)) { $root } else { (Resolve-Path -LiteralPath $WorkspaceRoot -ErrorAction Stop).ProviderPath }
    $separator = [System.IO.Path]::DirectorySeparatorChar
    $settingsFile = Join-Path $root '.github' 'Rulebook-Settings.json'
    $settings = $null
    if (Test-Path -LiteralPath $settingsFile -PathType Leaf) {
        try { $settings = Get-Content -LiteralPath $settingsFile -Raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop } catch { $settings = $null }
    }
    $setting = { param([string[]]$Path) $value = $settings; foreach ($key in $Path) { if ($value -isnot [System.Collections.IDictionary] -or -not $value.Contains($key)) { return $null }; $value = $value[$key] }; return $value }
    # The secret name: the setting when present (an invalid one is an error in update mode, never a silent default).
    $name = [string](& $setting 'ghTokenWorkflowSecretName')
    $nameValid = $name -cmatch '^[A-Za-z_][A-Za-z0-9_]*$' -and $name -inotmatch '^GITHUB_'
    if (-not [string]::IsNullOrEmpty($name) -and $nameValid) { $secretName = $name }

    # 1. Template URL and the token guard (before any request).
    $requested = if (-not [string]::IsNullOrWhiteSpace($TemplateUrl)) { $TemplateUrl } else { [string](& $setting 'templateUrl') }
    if ($Update -and -not [string]::IsNullOrEmpty($name) -and -not $nameValid) {
        Add-Failure 'token'
        throw "ghTokenWorkflowSecretName '$name' in .github/Rulebook-Settings.json is not a valid secret name (letters, digits and underscores, not starting with a digit or GITHUB_). Read $docsUrl"
    }
    if ($Update -and [string]::IsNullOrWhiteSpace($Token)) {
        Add-Failure 'token'
        throw "The $secretName secret is needed to update system files. Read $docsUrl"
    }

    # 2. Update mode: the write token, exchanged and masked before anything else runs.
    $access = $null
    if ($Update) {
        if ([string]::IsNullOrEmpty($Repository)) { throw 'The update needs the repository (GITHUB_REPOSITORY) as owner/name.' }
        if ([string]::IsNullOrEmpty($UpdateBranch)) { throw 'The update needs updateBranch.' }
        try {
            $access = Get-GitHubAccessToken -Token $Token -Repository $Repository -ApiUrl $ApiUrl
        } catch {
            Add-Failure 'token'
            throw "The $secretName secret could not be used: $($_.Exception.Message)"
        }
        if (-not [string]::IsNullOrEmpty($access.Token)) { & $maskToken $access.Token }
        Write-Host "Write token: $($access.Kind)"
    }

    # 3. The template and the plan. Check mode never fails Validate: any failure here is one warning.
    try {
        if (-not [string]::IsNullOrWhiteSpace($TemplatePath)) {
            $template = Get-RulebookTemplate -TemplatePath $TemplatePath -InstalledTemplatePath $InstalledTemplatePath -TemplateSha $TemplateSha -TemplateUrl $requested
        } else {
            $info = ConvertTo-TemplateUrl -Url $requested
            $installedSha = [string](& $setting 'templateSha')
            $storedUrl = [string](& $setting 'templateUrl')
            $sameTemplate = $false
            if (-not [string]::IsNullOrWhiteSpace($storedUrl)) {
                try { $sameTemplate = (ConvertTo-TemplateUrl -Url $storedUrl).Url -ceq $info.Url } catch { $sameTemplate = $false }
            }
            # Another template, or no recorded commit: resolve the branch head (AL-Go does the same).
            if (-not $sameTemplate) { $installedSha = '' }
            $latest = $DownloadLatest -or [string]::IsNullOrWhiteSpace($installedSha)
            # Check mode reads with GITHUB_TOKEN only, as Validate does; the write token is for update mode.
            $readToken = if ($Update) { $Token } else { '' }
            $template = Get-RulebookTemplate -TemplateUrl $info.Url -Token $readToken -GitHubToken $GitHubToken -DownloadLatest:$latest -InstalledSha $installedSha -WorkPath $WorkPath -ApiUrl $ApiUrl -OnToken $maskToken
        }
        Write-Host "Template: $($template.Repo) at $($template.Sha) ($($template.Source))"
        $plan = Get-RulebookUpdatePlan -RepositoryRoot $root -Template $template -WorkPath $WorkPath
    } catch {
        if ($Update) {
            if ($null -eq $template) { Add-Failure 'template' }
            throw
        }
        Add-Annotation -Command warning -Message "update check skipped: $($_.Exception.Message)"
        $summaryMessage = "update check skipped: $($_.Exception.Message)"
        $plan = $null
    }

    if ($null -ne $plan) {
        foreach ($note in $plan.Notes) { Write-Host "Note: $note" }
        foreach ($change in $plan.Changes) { Write-Host "$($change.Change): $($change.File) ($($change.Class))" }
        $status = Get-RulebookUpdateStatus -Plan $plan
        $updatesAvailable = $plan.Valid -and $plan.UpdatesAvailable

        if (-not $Update) {
            Add-Annotation -Command $status.Command -Message $status.Message
            $summaryMessage = $status.Message
        } else {
            # 4. Update mode.
            if (-not $plan.Valid) {
                foreach ($finding in @($plan.Findings | Where-Object Severity -EQ 'error')) {
                    $message = if ($finding.Id) { "$($finding.Id): $($finding.Message)" } else { $finding.Message }
                    $file = if ($finding.File) { [System.IO.Path]::GetRelativePath($workspace, (Join-Path $root $finding.File)).Replace($separator, '/') } else { $null }
                    Add-Annotation -File $file -Title $finding.Rule -Message "The updated rulebook would not validate: $message"
                }
                Add-Failure 'validation'
                $summaryMessage = 'The updated rulebook does not validate; nothing was pushed. The findings come from the repository after the update.'
                $failed = $true
            } else {
                $labels = [string[]]@(& $setting 'commitOptions', 'pullRequestLabels' | Where-Object { $_ -is [string] -and $_ -ne '' })
                try {
                    $publishParameters = @{
                        Plan = $plan; RepositoryRoot = $root; Repository = $Repository; RemoteUrl = $RemoteUrl; Token = $access.Token; UpdateBranch = $UpdateBranch
                        DirectCommit = [bool]$DirectCommit; Actor = $Actor; Labels = $labels; TemplateRepo = $template.Repo; WorkPath = (Join-Path $WorkPath 'publish'); ApiUrl = $ApiUrl
                    }
                    $publish = if ($null -ne $PublishCommand) { & $PublishCommand @publishParameters } else { Publish-RulebookUpdate @publishParameters }
                } catch {
                    $stage = [string]$_.Exception.Data['Stage']
                    if ($stage -cnotin 'push', 'pull-request') { $stage = 'push' }
                    Add-Failure $stage
                    $what = if ($stage -eq 'pull-request') { 'Failed to create the pull request for the Rulebook system files' } else { 'Failed to update the Rulebook system files' }
                    throw "$what. Make sure that the token in the secret $secretName is not expired and may write contents, pull requests and workflows of $Repository. Read $docsUrl (Error was: $($_.Exception.Message))"
                }
                switch ($publish.Result) {
                    'exists' {
                        Add-Annotation -Command warning -Message "Pull request already exists: $($publish.PullRequestUrl)"
                        $summaryMessage = "Pull request already exists: $($publish.PullRequestUrl)"
                    }
                    'no-changes' {
                        Add-Annotation -Command notice -Message 'No updates available'
                        $summaryMessage = 'No updates available'
                    }
                    'direct-commit' {
                        Add-Annotation -Command notice -Message "Rulebook system files updated in $($publish.Branch) ($($publish.Sha))"
                        $summaryMessage = "Committed to $($publish.Branch)"
                    }
                    default {
                        $suffix = if ($publish.Fallback) { ' (the direct commit was refused)' } else { '' }
                        Add-Annotation -Command notice -Message "Pull request: $($publish.PullRequestUrl)$suffix"
                        $summaryMessage = "Pull request: $($publish.PullRequestUrl)$suffix"
                    }
                }
            }
        }
    }
} catch {
    Add-Annotation -Message $_.Exception.Message
    Add-Failure 'error'
    $summaryMessage = $_.Exception.Message
    $failed = $true
} finally {
    if ($ownWork -and (Test-Path -LiteralPath $WorkPath)) { Remove-Item -LiteralPath $WorkPath -Recurse -Force -ErrorAction SilentlyContinue }
}

# 5. Summary and outputs.
$title = if ($mode -eq 'check') { '## Template update check' } else { '## Rulebook system files update' }
$summary = "$title`n`n$(ConvertTo-SingleLine $summaryMessage)`n`n"
if ($null -ne $plan) {
    try {
        $summary = ConvertTo-UpdateSummary -Plan $plan -Result $publish -Mode $mode -Message $summaryMessage
    } catch {
        Write-Host "The summary could not be written in full: $($_.Exception.Message)"
    }
}
$summary = $summary.Replace("`r`n", "`n")
# The runner caps a step summary at 1 MiB; stay well below it (-SummaryLimit, 900 KiB).
$where = if ($null -ne $publish -and $publish.Body) { 'the pull request body' } else { 'the job log' }
$summary = Limit-SummaryText -Text $summary -MaxBytes $SummaryLimit -Footer "The summary was cut at $([math]::Floor($SummaryLimit / 1KB)) KiB; the full lists are in $where."
Write-Text -Path $SummaryPath -Text $summary
$pullRequestUrl = if ($null -ne $publish -and $publish.PullRequestUrl) { $publish.PullRequestUrl } else { '' }
$sha = if ($null -ne $template) { $template.Sha } else { '' }
if ($env:GITHUB_OUTPUT) {
    Write-Text -Path $env:GITHUB_OUTPUT -Text ("updatesAvailable={0}`npullRequestUrl={1}`ntemplateSha={2}`nfailure={3}`n" -f $updatesAvailable.ToString().ToLowerInvariant(), $pullRequestUrl, $sha, $script:failure)
}
[pscustomobject]@{
    ExitCode         = $(if ($failed) { 1 } else { 0 })
    Mode             = $mode
    Failure          = $script:failure
    UpdatesAvailable = $updatesAvailable
    TemplateSha      = $sha
    PullRequestUrl   = $pullRequestUrl
    Plan             = $plan
    Result           = $publish
    Annotations      = $script:annotations.ToArray()
    Summary          = $summary
}
