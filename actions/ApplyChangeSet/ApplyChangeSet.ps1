#requires -Version 7.4
<#
.SYNOPSIS
Entry script of the ApplyChangeSet action: apply the change set of a rulebook-change issue and land it as a pull
request (or a direct commit), reporting the outcome on the issue.
.DESCRIPTION
0. Reads the settings: the secret name (ghTokenWorkflowSecretName) and the labels (commitOptions.pullRequestLabels).
1. Reads the issue (Get-GitHubIssue with GITHUB_TOKEN, or -IssuePath). A pull request or an issue that is not open is
   skipped: one notice, result skipped, no comment (an edit of a closed issue never applies it again).
2. The gate (D55): the issue author must be able to push (Get-GitHubUserPermission answers admin or write), and so
   must -Editor, the account that edited the body, when it is another account. Anyone else gets the refusal comment
   and the issue is closed as not planned, result refused, before the body is read.
3. The duplicate guard (D33): an open pull request from a branch rulebook-change/<issue>/ gets a comment with its
   link, result pull-request-exists. A listing that fails is one warning.
4. The body: ConvertFrom-RulebookIssueBody and Read-RulebookChangeSetText (schemas/rulebook-changeset.schema.json of
   this engine); a non-empty Note field replaces the change set's note. Errors: one error annotation each, one
   comment with one line per error, failure validation; the issue stays open (an edit of the body runs it again).
5. The label: once the body parsed, when the issue does not carry -Label (rulebook-change), Confirm-GitHubLabel
   creates it when missing and adds it; a failure is one warning.
6. The plan (Invoke-RulebookChangeSet on a candidate copy): findings as ChangeRule plus one comment, failure
   validation.
7. A no-op (D48): the comment 'Nothing to change.' with one line per item, the issue closed as completed, result
   no-op; it needs no token.
8. The token guard as ChangeRule (mask first); a failure is failure token and a comment that points at the
   ghtokenworkflow page.
9. Publish-RulebookChange (or -PublishCommand) on rulebook-change/<issue>/<yyMMddHHmmss UTC> with the title
   '<Get-RulebookChangeTitle> (#<issue>)' (the engine title capped at 200 characters) and 'Closes #<issue>' at the
   end of the pull request body. Pull request: a comment with the link and the body, the issue stays open until the
   merge closes it. Direct commit: a comment with the commit link and the body, the issue closed as completed.
10. The job summary (ConvertTo-ChangeSummary -Heading 'Rulebook change (#<issue>)') and GITHUB_OUTPUT: result
   (pull-request, direct-commit, no-op, refused, pull-request-exists, skipped; empty on failure), noop,
   changedEndpoints, pullRequestUrl, branch, issue, issueState (open, closed-completed, closed-not-planned; the state
   read for a skipped issue) and failure (validation, token, push, pull-request, issue, error).
Every issue read and write goes through GITHUB_TOKEN (-GitHubToken); the push and the pull request use the exchanged
GHTOKENWORKFLOW token. A failed issue read, gate or write before the change landed fails the run (failure issue,
unless an earlier failure kind was recorded); after the pull request or the direct commit exists it is a warning. An
unexpected failure (failure error) after the issue was read gets one generic comment with the run link, best effort.
Every comment stays below 60000 characters: a long list is cut with one line that points at the job log.
With -IssuePath (a JSON file shaped like GET /repos/{r}/issues/{n}, plus an optional top-level permission of the
author, default none, and editorPermission of -Editor, default none) no GitHub call is made for the issue: the gate
reads the permissions from the file, the duplicate guard is skipped and every issue write is recorded in
IssueActions with Posted $false.
Returns { ExitCode, Result, NoOp, Failure, Issue, IssueActions, Plan, Publish, Annotations, Summary, Outputs } and
never calls exit, so tests run it in-process; action.yaml exits with ExitCode. -RemoteUrl, -ApiUrl, -WorkPath,
-SummaryLimit, -Now, -PublishCommand, -IssuePath and -GitHubToken are test seams; a -WorkPath the caller passes is
left in place, the temporary work folder the script names itself is removed at the end.
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$RepositoryRoot = '.',
    [AllowEmptyString()][string]$IssueNumber,
    [AllowEmptyString()][string]$Token,
    [switch]$DirectCommit,
    [AllowEmptyString()][string]$BaseBranch = $env:GITHUB_REF_NAME,
    [AllowEmptyString()][string]$Actor = $env:GITHUB_ACTOR,
    [AllowEmptyString()][string]$Label = 'rulebook-change',
    # The account that triggered the run (the sender of the event): on an edit by another account it is gated too.
    [AllowEmptyString()][string]$Editor,
    [AllowEmptyString()][string]$Repository = $env:GITHUB_REPOSITORY,
    # Test seam: the issue as a JSON file instead of the API (the engine's CI); never set in a workflow.
    [AllowEmptyString()][string]$IssuePath,
    # The workflow token (GITHUB_TOKEN): reads the issue and the permission, writes the comments, the label and the state.
    [AllowEmptyString()][string]$GitHubToken = $env:GITHUB_TOKEN,
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
Import-Module (Join-Path $modules 'Rulebook.Common.psd1') -Force
Import-Module (Join-Path $modules 'Rulebook.Generate.psd1') -Force
Import-Module (Join-Path $modules 'Rulebook.GitHub.psd1') -Force
Import-Module (Join-Path $modules 'Rulebook.Update.psd1') -Force
Import-Module (Join-Path $modules 'Rulebook.Edit.psd1') -Force
Import-Module (Join-Path $modules 'Rulebook.Action.psd1') -Force

# The user page of the token, on the template ref of the engine ref this action runs from (D53).
$docsUrl = Get-RulebookDocsUrl -Page 'ghtokenworkflow.md'
$schemaPath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..' 'schemas' 'rulebook-changeset.schema.json'))
# GitHub refuses a pull request title above 256 characters; the engine title is capped before ' (#<n>)'.
$titleLimit = 200
# A comment is limited to 65536 characters; every comment stays below this.
$commentLimit = 60000
$refusal = 'Only repository collaborators with write access can submit or edit Rulebook changes.'
$rerun = 'Edit the issue body to run it again.'

$ownWork = [string]::IsNullOrEmpty($WorkPath)
if ($ownWork) {
    $tempRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [System.IO.Path]::GetTempPath() }
    $WorkPath = Join-Path $tempRoot ('rulebook-apply-' + [guid]::NewGuid().ToString('n').Substring(0, 8))
}
$WorkPath = Resolve-ActionPath $WorkPath
$ctx = New-ActionContext -Title 'ApplyChangeSet'

# Every token obtained by an exchange is masked before anything can print it.
$maskToken = { param([string]$Value) if (-not [string]::IsNullOrEmpty($Value)) { Write-Host "::add-mask::$Value" } }
$fileMode = -not [string]::IsNullOrEmpty($IssuePath)
$server = if ($env:GITHUB_SERVER_URL) { $env:GITHUB_SERVER_URL.TrimEnd('/') } else { 'https://github.com' }
$plan = $null
$publish = $null
$issue = $null
$result = $null
$summaryMessage = $null
$failed = $false
$number = 0
$secretName = 'GHTOKENWORKFLOW'
$issueActions = [System.Collections.Generic.List[object]]::new()
# What the issue writes change: the state after the run, and whether the change landed (a failed write is then a
# warning: the pull request or the commit exists).
$state = @{ IssueState = ''; Landed = $false }

function New-StopException {
    # An exception whose message is annotated already: the catch below records the failure, not a second annotation.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an exception; changes no state')]
    param([Parameter(Mandatory)][string]$Message)
    $exception = [System.InvalidOperationException]::new($Message)
    $exception.Data['Annotated'] = $true
    return $exception
}

function Format-CodeSpan {
    # User-derived text (an error line, a finding) as one inline code span: no Markdown, mention or link in it acts.
    param([AllowNull()][AllowEmptyString()][string]$Text)
    $line = (ConvertTo-SingleLine $Text).Replace('`', '').Trim()
    if ($line.Length -gt 1000) { $line = $line.Substring(0, 997) + '...' }
    if ($line -eq '') { $line = '-' }
    return '`' + $line + '`'
}

function Format-ListComment {
    # The heading, the list lines while the comment stays below the limit (then one line that names how many more are
    # in the job log), and the closing sentence. -CodeSpan makes each line '- `<text>`'.
    param(
        [Parameter(Mandatory)][string]$Heading,
        [AllowEmptyCollection()][string[]]$Lines,
        [string]$Closing,
        [switch]$CodeSpan,
        [string]$Noun = 'errors'
    )
    $text = [System.Text.StringBuilder]::new()
    [void]$text.Append($Heading).Append("`n`n")
    $all = @($Lines)
    $shown = 0
    foreach ($line in $all) {
        $entry = $(if ($CodeSpan) { '- ' + (Format-CodeSpan $line) } else { $line }) + "`n"
        if ($text.Length + $entry.Length -gt $commentLimit - 500) { break }
        [void]$text.Append($entry)
        $shown++
    }
    if ($shown -lt $all.Count) { [void]$text.Append("- _$($all.Count - $shown) more $Noun are in the job log._`n") }
    if ($Closing) { [void]$text.Append("`n").Append($Closing).Append("`n") }
    return $text.ToString()
}

function Format-ChangeComment {
    # The first line (the pull request or the commit), a blank line and the pull request body without the closing
    # keyword, the body cut so the comment stays below the limit.
    param([Parameter(Mandatory)][string]$Heading)
    return "$Heading`n`n" + (ConvertTo-ChangePullRequestBody -Plan $plan -Limit ($commentLimit - $Heading.Length - 2))
}

function Invoke-IssueWrite {
    # Posts one comment, label or close on the issue (or records it with -IssuePath) and adds it to IssueActions.
    # -BestEffort makes a failure a warning, as after the landing.
    param(
        [Parameter(Mandatory)][ValidateSet('comment', 'close', 'label')][string]$Kind,
        [string]$Body,
        [ValidateSet('completed', 'not_planned')][string]$StateReason,
        [switch]$BestEffort
    )
    $action = [pscustomobject]@{
        Kind        = $Kind
        Body        = $(if ($Kind -eq 'comment') { $Body } else { $null })
        StateReason = $(if ($Kind -eq 'close') { $StateReason } else { $null })
        Label       = $(if ($Kind -eq 'label') { $Label } else { $null })
        Posted      = $false
    }
    $issueActions.Add($action)
    if ($fileMode) {
        # The body is not printed: a line of it could read as a workflow command.
        Write-Host "Issue #$($number): $Kind recorded, not posted (issuePath)"
    } else {
        try {
            switch ($Kind) {
                'comment' { $null = Add-GitHubIssueComment -Repository $Repository -Number $number -Body $Body -Token $GitHubToken -ApiUrl $ApiUrl }
                'close' { $null = Close-GitHubIssue -Repository $Repository -Number $number -StateReason $StateReason -Token $GitHubToken -ApiUrl $ApiUrl }
                'label' { $null = Confirm-GitHubLabel -Repository $Repository -Name $Label -IssueNumber $number -Token $GitHubToken -ApiUrl $ApiUrl }
            }
            $action.Posted = $true
        } catch {
            $what = switch ($Kind) { 'comment' { "comment on issue #$number" } 'close' { "close issue #$number" } default { "add the label $Label to issue #$number" } }
            $message = "Could not $($what): $($_.Exception.Message)"
            # The label only serves the workflow filter; after the landing the pull request or the commit exists.
            if ($Kind -eq 'label' -or $state.Landed -or $BestEffort) {
                Add-Annotation -Context $ctx -Command warning -Message $message
                return
            }
            Add-Annotation -Context $ctx -Message $message
            Add-Failure -Context $ctx -Kind 'issue'
            throw (New-StopException $message)
        }
    }
    if ($Kind -eq 'close') { $state.IssueState = if ($StateReason -eq 'not_planned') { 'closed-not-planned' } else { 'closed-completed' } }
}

function ConvertTo-IssueObject {
    # The issue JSON of -IssuePath as Get-GitHubIssue returns it, plus Permission (default none) and EditorPermission
    # ($null when the file has none).
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Data)
    $user = if ($Data['user'] -is [System.Collections.IDictionary]) { $Data['user'] } else { @{} }
    $names = [string[]]@(@($Data['labels']) | ForEach-Object {
            if ($_ -is [System.Collections.IDictionary]) { [string]$_['name'] } elseif ($null -ne $_) { [string]$_ }
        })
    return [pscustomobject]@{
        Number            = $(if ($null -ne $Data['number']) { [int]$Data['number'] } else { $number })
        Title             = [string]$Data['title']
        Body              = [string]$Data['body']
        State             = $(if ($null -ne $Data['state']) { [string]$Data['state'] } else { 'open' })
        StateReason       = $(if ($null -eq $Data['state_reason']) { $null } else { [string]$Data['state_reason'] })
        Author            = [string]$user['login']
        AuthorType        = [string]$user['type']
        AuthorAssociation = [string]$Data['author_association']
        Labels            = $names
        Url               = [string]$Data['html_url']
        IsPullRequest     = $Data.Contains('pull_request') -and $null -ne $Data['pull_request']
        Permission        = $(if ($null -ne $Data['permission']) { [string]$Data['permission'] } else { 'none' })
        EditorPermission  = $(if ($null -ne $Data['editorPermission']) { [string]$Data['editorPermission'] } else { $null })
    }
}

function Get-Permission {
    # The permission of -User for the gate: from the issue file with -IssuePath, else from the API; a failed read
    # stops the run (failure issue), so the gate is never skipped.
    param([AllowEmptyString()][string]$User, [AllowNull()][AllowEmptyString()][string]$FromFile)
    if ($fileMode) { return $(if ([string]::IsNullOrEmpty($FromFile)) { 'none' } else { $FromFile }) }
    if ([string]::IsNullOrEmpty($User)) { return 'none' }
    try {
        return [string](Get-GitHubUserPermission -Repository $Repository -User $User -Token $GitHubToken -ApiUrl $ApiUrl).Permission
    } catch {
        $message = "Could not read the permission of $User on the repository, so the change set was not applied: $($_.Exception.Message)"
        Add-Annotation -Context $ctx -Message $message
        Add-Failure -Context $ctx -Kind 'issue'
        throw (New-StopException $message)
    }
}

try {
    if ($IssueNumber -cnotmatch '^\s*[1-9][0-9]{0,8}\s*$') { throw "issueNumber '$(ConvertTo-SingleLine $IssueNumber)' is not an issue number." }
    $number = [int]$IssueNumber.Trim()
    if (-not $fileMode -and [string]::IsNullOrEmpty($Repository)) { throw 'The change needs the repository (GITHUB_REPOSITORY) as owner/name.' }

    # 0. Settings: the secret name and the labels.
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

    # 1. The issue, read again: the API has the current body and state, not those of the event.
    try {
        if ($fileMode) {
            $data = Get-Content -LiteralPath $IssuePath -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            if ($data -isnot [System.Collections.IDictionary]) { throw 'the file is not a JSON object' }
            $issue = ConvertTo-IssueObject -Data $data
        } else {
            $issue = Get-GitHubIssue -Repository $Repository -Number $number -Token $GitHubToken -ApiUrl $ApiUrl
        }
    } catch {
        $message = "Could not read issue #$($number): $($_.Exception.Message)"
        Add-Annotation -Context $ctx -Message $message
        Add-Failure -Context $ctx -Kind 'issue'
        throw (New-StopException $message)
    }
    $state.IssueState = if ($issue.State -ceq 'open') { 'open' } elseif ($issue.StateReason) { 'closed-' + $issue.StateReason.Replace('_', '-') } else { [string]$issue.State }
    if ($issue.IsPullRequest -or $issue.State -cne 'open') {
        $summaryMessage = if ($issue.IsPullRequest) { "#$number is a pull request, not an issue; nothing was done." } else { "Issue #$number is $($issue.State); nothing was done." }
        Add-Annotation -Context $ctx -Command notice -Message $summaryMessage
        $result = 'skipped'
    } else {
        # 2. The gate (D55): the author, and an editor who is another account, can push to the repository. It runs
        # before the body is read.
        $author = [string]$issue.Author
        $denied = $null
        $permission = Get-Permission -User $author -FromFile $(if ($fileMode) { [string]$issue.Permission } else { $null })
        if ($permission -cnotin 'admin', 'write') {
            $denied = "the author $author has the permission '$permission' on the repository"
        } elseif (-not [string]::IsNullOrEmpty($Editor) -and -not [string]::Equals($Editor, $author, [System.StringComparison]::OrdinalIgnoreCase)) {
            # GitHub logins compare without case. In the issue file an editor without editorPermission is 'none'.
            $editorPermission = Get-Permission -User $Editor -FromFile $(if ($fileMode) { [string]$issue.EditorPermission } else { $null })
            if ($editorPermission -cnotin 'admin', 'write') { $denied = "the editor $Editor of the issue has the permission '$editorPermission' on the repository" }
        }
        if ($null -ne $denied) {
            Invoke-IssueWrite -Kind comment -Body "$refusal`n"
            Invoke-IssueWrite -Kind close -StateReason not_planned
            $summaryMessage = "Refused: $denied; only admin and write may submit or edit Rulebook changes (D55). The issue was closed as not planned."
            Add-Annotation -Context $ctx -Command notice -Message $summaryMessage
            $result = 'refused'
        } else {
            # 3. The duplicate guard (D33): one open pull request per issue.
            $existing = $null
            if (-not $fileMode) {
                try {
                    $existing = Find-GitHubPullRequestByHeadPrefix -Repository $Repository -Base $BaseBranch -HeadPrefix "rulebook-change/$number/" -Token $GitHubToken -ApiUrl $ApiUrl
                } catch {
                    Add-Annotation -Context $ctx -Command warning -Message "duplicate guard inactive: the open pull requests could not be listed: $($_.Exception.Message)"
                }
            }
            if ($null -ne $existing) {
                Invoke-IssueWrite -Kind comment -Body "The pull request already exists: $($existing.Url). Edits of this issue are not applied to it; close the pull request first to apply the edited change set.`n"
                $summaryMessage = "Pull request already exists: $($existing.Url)"
                Add-Annotation -Context $ctx -Command notice -Message $summaryMessage
                $result = 'pull-request-exists'
            } else {
                # 4. The body: the change set and the note.
                $body = ConvertFrom-RulebookIssueBody -Body $issue.Body
                [string[]]$readErrors = @($body.Errors)
                $changeSet = $null
                if ($readErrors.Count -eq 0) {
                    $read = Read-RulebookChangeSetText -Text $body.ChangesText -SchemaPath $schemaPath
                    [string[]]$readErrors = @($read.Errors)
                    $changeSet = $read.ChangeSet
                }
                if ($readErrors.Count -gt 0) {
                    foreach ($line in $readErrors) { Add-Annotation -Context $ctx -Message $line }
                    $summaryMessage = 'The change set could not be read; nothing was written.'
                    $failed = $true
                    Add-Failure -Context $ctx -Kind 'validation'
                    Invoke-IssueWrite -Kind comment -Body (Format-ListComment -Heading 'The change set could not be read:' -Lines $readErrors -CodeSpan -Closing "Nothing was written. $rerun")
                } else {
                    # The Note field is what the submitter edits on the issue page; the cart writes both alike.
                    if (-not [string]::IsNullOrEmpty($body.Note)) { $changeSet['note'] = $body.Note }

                    # 5. The label, only on a body that parsed: the workflow filter knows an issue opened before the
                    # label existed by the form markers.
                    if (-not [string]::IsNullOrEmpty($Label) -and @($issue.Labels) -cnotcontains $Label) { Invoke-IssueWrite -Kind label }

                    # 6. The plan, on a candidate copy.
                    $plan = Invoke-RulebookChangeSet -RepositoryRoot $root -ChangeSet $changeSet -WorkPath (Join-Path $WorkPath 'plan') -Now $Now
                    if ($plan.Failure -or -not $plan.Valid) {
                        $candidate = $null -ne $plan.CandidatePath
                        $prefix = if ($candidate) { 'The changed rulebook would not validate: ' } else { '' }
                        $lines = [System.Collections.Generic.List[string]]::new()
                        foreach ($finding in @($plan.Findings | Where-Object Severity -EQ 'error')) {
                            $message = if ($finding.Id -and $finding.Rule -cne 'change') { "$($finding.Id): $($finding.Message)" } else { [string]$finding.Message }
                            $file = if ($finding.File) { [System.IO.Path]::GetRelativePath($workspace, (Join-Path $root $finding.File)).Replace($separator, '/') } else { $null }
                            Add-Annotation -Context $ctx -File $file -Title $(if ($finding.Rule -ceq 'change') { 'ApplyChangeSet' } else { $finding.Rule }) -Message "$prefix$message"
                            $lines.Add($message)
                        }
                        $summaryMessage = if ($candidate) { 'The changed rulebook would not validate; nothing was pushed.' } else { 'The change set is not valid; nothing was written.' }
                        $failed = $true
                        Add-Failure -Context $ctx -Kind 'validation'
                        Invoke-IssueWrite -Kind comment -Body (Format-ListComment -Heading $summaryMessage -Lines $lines.ToArray() -CodeSpan -Closing $rerun)
                    } elseif ($plan.NoOp) {
                        # 7. Nothing would change (D48).
                        $summaryMessage = 'Nothing to change: every change of the change set is a no-op; nothing was written.'
                        Add-Annotation -Context $ctx -Command notice -Message $summaryMessage
                        [string[]]$items = @((ConvertTo-ChangeItemList -Plan $plan).Split("`n") | Where-Object { $_ -ne '' })
                        Invoke-IssueWrite -Kind comment -Body (Format-ListComment -Heading 'Nothing to change.' -Lines $items -Noun 'items')
                        Invoke-IssueWrite -Kind close -StateReason completed
                        $result = 'no-op'
                    } else {
                        # 8. The token guard, after the plan: a validation error or a no-op needs no secret.
                        if ([string]::IsNullOrEmpty($BaseBranch)) { throw 'The change needs baseBranch.' }
                        $tokenReason = $null
                        $tokenMessage = $null
                        $access = $null
                        if (-not [string]::IsNullOrEmpty($name) -and -not $nameValid) {
                            $tokenReason = "ghTokenWorkflowSecretName '$name' in .github/Rulebook-Settings.json is not a valid secret name"
                            $tokenMessage = "$tokenReason (letters, digits and underscores, not starting with a digit or GITHUB_). Read $docsUrl"
                        } elseif ([string]::IsNullOrWhiteSpace($Token)) {
                            $tokenReason = 'the secret is empty or not set'
                            $tokenMessage = "The $secretName secret is needed to apply a change set. Read $docsUrl"
                        } else {
                            if ([string]::IsNullOrEmpty($Repository)) { throw 'The change needs the repository (GITHUB_REPOSITORY) as owner/name.' }
                            try {
                                $access = Get-GitHubAccessToken -Token $Token -Repository $Repository -ApiUrl $ApiUrl
                            } catch {
                                $tokenReason = ConvertTo-SingleLine $_.Exception.Message
                                $tokenMessage = "The $secretName secret could not be used: $($_.Exception.Message)"
                            }
                        }
                        if ($null -ne $tokenMessage) {
                            Add-Annotation -Context $ctx -Message $tokenMessage
                            Add-Failure -Context $ctx -Kind 'token'
                            $summaryMessage = $tokenMessage
                            $failed = $true
                            Invoke-IssueWrite -Kind comment -Body "The change set is valid, but the $secretName secret is missing or cannot be used, so nothing was pushed ($tokenReason). A maintainer sets it as described in $docsUrl; then edit the issue body to run it again.`n"
                        } else {
                            if (-not [string]::IsNullOrEmpty($access.Token)) { & $maskToken $access.Token }
                            Write-Host "Write token: $($access.Kind)"

                            # 9. Publish.
                            if (-not $plan.HeadSha) { Add-Annotation -Context $ctx -Command warning -Message 'base-move guard inactive: the checkout HEAD could not be read' }
                            $title = Get-RulebookChangeTitle -Plan $plan
                            if ($title.Length -gt $titleLimit) { $title = $title.Substring(0, $titleLimit - 3) + '...' }
                            $title = "$title (#$number)"
                            $publishFailure = $null
                            try {
                                $publishParameters = @{
                                    Plan = $plan; RepositoryRoot = $root; Repository = $Repository; RemoteUrl = $RemoteUrl; Token = $access.Token; BaseBranch = $BaseBranch
                                    BranchPrefix = "rulebook-change/$number"; DirectCommit = [bool]$DirectCommit; Actor = $Actor; Labels = $labels
                                    Title = $title; BodySuffix = "Closes #$number"; WorkPath = (Join-Path $WorkPath 'publish'); ApiUrl = $ApiUrl; Now = $Now
                                }
                                $publish = if ($null -ne $PublishCommand) { & $PublishCommand @publishParameters } else { Publish-RulebookChange @publishParameters }
                            } catch {
                                $publishFailure = $_
                            }
                            if ($null -ne $publishFailure) {
                                $exception = $publishFailure.Exception
                                $stage = [string]$exception.Data['Stage']
                                if ($stage -cnotin 'push', 'pull-request') { $stage = 'push' }
                                # A refused direct push is reported even when the fallback branch or the pull request then failed (#77).
                                if ($exception.Data.Contains('FallbackReason')) {
                                    $fallbackReason = [string]$exception.Data['FallbackReason']
                                    $fallbackSuffix = if ($fallbackReason) { " ($(ConvertTo-SingleLine $fallbackReason))" } else { '' }
                                    $fallbackOutcome = if ($stage -eq 'pull-request') { 'the branch was pushed instead.' } else { 'the fallback branch could not be pushed.' }
                                    Add-Annotation -Context $ctx -Command warning -Message "The direct push to $BaseBranch was refused; $fallbackOutcome$fallbackSuffix"
                                }
                                # The base branch moved between plan and publish: nothing is wrong with the token; run it again.
                                if ([string]$exception.Data['Reason'] -ceq 'base-moved') {
                                    $message = $exception.Message
                                    $commentBody = "$(ConvertTo-SingleLine $message)`n`n$rerun`n"
                                } else {
                                    $what = if ($stage -eq 'pull-request') { 'Failed to create the pull request for the change set' } else { 'Failed to push the change set' }
                                    $hint = "$what. Make sure that the token in the secret $secretName is not expired and may write contents and pull requests of $Repository. Read $docsUrl"
                                    $message = "$hint (Error was: $($exception.Message))"
                                    # The raw error inside a code span, as every other error line of a comment.
                                    $commentBody = "$hint.`n`nError: $(Format-CodeSpan $exception.Message)`n`n$rerun`n"
                                }
                                Add-Annotation -Context $ctx -Message $message
                                Add-Failure -Context $ctx -Kind $stage
                                $summaryMessage = $message
                                $failed = $true
                                Invoke-IssueWrite -Kind comment -Body $commentBody
                            } else {
                                $fellBack = $publish.PSObject.Properties['Fallback'] -and $publish.Fallback
                                # The refused direct push as one warning annotation with the git output (#77).
                                if ($fellBack) {
                                    $fallbackReason = if ($publish.PSObject.Properties['FallbackReason'] -and $publish.FallbackReason) { " ($(ConvertTo-SingleLine $publish.FallbackReason))" } else { '' }
                                    Add-Annotation -Context $ctx -Command warning -Message "The direct push to $BaseBranch was refused; a pull request was created instead.$fallbackReason"
                                }
                                $result = $publish.Result
                                switch ($publish.Result) {
                                    'direct-commit' {
                                        $state.Landed = $true
                                        $commitUrl = '{0}/{1}/commit/{2}' -f $server, $Repository, $publish.Sha
                                        $summaryMessage = "Change set committed to $($publish.Branch) ($(Get-ShortSha $publish.Sha))"
                                        Add-Annotation -Context $ctx -Command notice -Message $summaryMessage
                                        Invoke-IssueWrite -Kind comment -Body (Format-ChangeComment -Heading "Committed to $($publish.Branch) ($commitUrl)")
                                        Invoke-IssueWrite -Kind close -StateReason completed
                                    }
                                    'no-changes' {
                                        # The plan saw a change but the clone of the base branch holds it already (pushed in between).
                                        $result = 'no-op'
                                        $summaryMessage = "No change: $BaseBranch already holds this change; nothing was pushed"
                                        Add-Annotation -Context $ctx -Command notice -Message $summaryMessage
                                        Invoke-IssueWrite -Kind comment -Body "Nothing to change: $BaseBranch already holds this change.`n"
                                        Invoke-IssueWrite -Kind close -StateReason completed
                                    }
                                    default {
                                        $state.Landed = $true
                                        $refused = if ($fellBack) { ' (the direct commit was refused)' } else { '' }
                                        $summaryMessage = "Pull request: $($publish.PullRequestUrl)$refused"
                                        Add-Annotation -Context $ctx -Command notice -Message $summaryMessage
                                        # The body without the closing keyword: the merge of the pull request closes the issue.
                                        Invoke-IssueWrite -Kind comment -Body (Format-ChangeComment -Heading "Pull request: $($publish.PullRequestUrl)$refused")
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
} catch {
    $annotated = [bool]$_.Exception.Data['Annotated']
    if (-not $annotated) { Add-Annotation -Context $ctx -Message $_.Exception.Message }
    Add-Failure -Context $ctx -Kind 'error'
    # A failed comment of an earlier failure keeps that failure's message in the summary.
    if (-not ($annotated -and $summaryMessage)) { $summaryMessage = $_.Exception.Message }
    $failed = $true
    # An unexpected failure after the issue was read gets one comment, best effort, unless the change landed.
    if ($ctx.Failure -ceq 'error' -and $null -ne $issue -and -not $state.Landed) {
        $runUrl = if ($env:GITHUB_RUN_ID -and $Repository) { " ($server/$Repository/actions/runs/$env:GITHUB_RUN_ID)" } else { '' }
        Invoke-IssueWrite -Kind comment -Body "The Apply Rulebook Change run failed before anything was written; see the job log$runUrl.`n" -BestEffort
    }
} finally {
    if ($ownWork -and (Test-Path -LiteralPath $WorkPath)) { Remove-Item -LiteralPath $WorkPath -Recurse -Force -ErrorAction SilentlyContinue }
}

# 10. Summary and outputs.
$heading = if ($number -gt 0) { "Rulebook change (#$number)" } else { 'Rulebook change' }
$summary = "## $heading`n`n$(ConvertTo-SingleLine $summaryMessage)`n`n"
if ($null -ne $plan) {
    try {
        $summary = ConvertTo-ChangeSummary -Plan $plan -Result $publish -Message $summaryMessage -Heading $heading
    } catch {
        Write-Host "The summary could not be written in full: $($_.Exception.Message)"
    }
}
$summary = $summary.Replace("`r`n", "`n")
# The runner caps a step summary at 1 MiB; stay well below it (-SummaryLimit, 900 KiB).
$where = if ($null -ne $publish -and $publish.PSObject.Properties['Body'] -and $publish.Body) { 'the pull request body' } else { 'the job log' }
$summary = Limit-SummaryText -Text $summary -MaxBytes $SummaryLimit -Footer "The summary was cut at $([math]::Round($SummaryLimit / 1KB)) KiB; the full tables are in $where."
Write-Text -Path $SummaryPath -Text $summary
# The endpoints the change set changes, also when the landing failed (the token guard, a push); empty for a no-op.
$changed = if ($null -ne $plan -and $plan.Valid -and -not $plan.Failure -and -not $plan.NoOp -and $result -ne 'no-op') { @($plan.Items | ForEach-Object { $_.ChangedEndpoints } | Select-Object -Unique) -join ',' } else { '' }
$outputs = [ordered]@{
    result           = $(if ($failed -or -not $result) { '' } else { $result })
    noop             = $(if (-not $failed -and $result -eq 'no-op') { 'true' } else { 'false' })
    changedEndpoints = $changed
    pullRequestUrl   = $(if ($null -ne $publish -and $publish.PullRequestUrl) { $publish.PullRequestUrl } else { '' })
    branch           = $(if ($null -ne $publish -and $publish.Branch) { $publish.Branch } else { '' })
    issue            = $(if ($number -gt 0) { [string]$number } else { '' })
    issueState       = $state.IssueState
    failure          = $ctx.Failure
}
Write-ActionOutput -Outputs $outputs
[pscustomobject]@{
    ExitCode     = $(if ($failed) { 1 } else { 0 })
    Result       = $outputs.result
    NoOp         = $outputs.noop -eq 'true'
    Failure      = $ctx.Failure
    Issue        = $issue
    IssueActions = $issueActions.ToArray()
    Plan         = $plan
    Publish      = $publish
    Annotations  = $ctx.Annotations.ToArray()
    Summary      = $summary
    Outputs      = $outputs
}
