# Action suite for WP15 (#17): actions/ApplyChangeSet/action.yaml, its entry script ApplyChangeSet.ps1 run in-process,
# and the template workflow template/.github/workflows/ApplyRulebookChange.yaml. The issue comes from a JSON file per
# test (-IssuePath) or from a local fake of the GitHub API (an HttpListener on localhost); the push goes to a bare
# remote or the -PublishCommand seam. The ci.yml job applychangeset-action runs the action itself on valid-minimal;
# the modules are covered by tests/Rulebook.Edit.Tests.ps1 and tests/Rulebook.GitHub.Tests.ps1.

BeforeDiscovery {
    $script:gitMissing = $null -eq (Get-Command git -ErrorAction SilentlyContinue)
}

BeforeAll {
    # The docs URL follows the engine ref: clear what a runner step would set, restore it in AfterAll.
    . (Join-Path $PSScriptRoot 'Helpers' 'EngineRef.ps1')
    $script:savedEngineRef = Clear-EngineRefEnvironment
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:actionDir = Join-Path $script:repoRoot 'actions' 'ApplyChangeSet'
    $script:entry = Join-Path $script:actionDir 'ApplyChangeSet.ps1'
    $script:minimal = Join-Path $PSScriptRoot 'fixtures' 'repos' 'valid-minimal'
    $script:issues = Join-Path $PSScriptRoot 'fixtures' 'issues'
    . (Join-Path $PSScriptRoot 'Helpers' 'RepoFixture.ps1')

    # On GitHub Actions these point at the real job; the tests must not write into them or post with them.
    $script:saved = @{ Output = $env:GITHUB_OUTPUT; Summary = $env:GITHUB_STEP_SUMMARY; Repository = $env:GITHUB_REPOSITORY; Token = $env:GITHUB_TOKEN; Server = $env:GITHUB_SERVER_URL }
    $env:GITHUB_OUTPUT = $null
    $env:GITHUB_STEP_SUMMARY = $null
    $env:GITHUB_TOKEN = $null
    $env:GITHUB_SERVER_URL = $null
    $script:now = [System.DateTimeOffset]::new(2026, 10, 8, 9, 15, 30, [System.TimeSpan]::Zero)
    $script:fence = '```'

    # Change sets on valid-minimal.
    $script:setStrict = '{"version":1,"changes":[{"op":"set","id":"LC0015","action":"None","levels":["strict"],"stages":["ci"]}]}'
    $script:setAll = '{"version":1,"changes":[{"op":"set","id":"AA0001","action":"None","levels":["*"],"stages":["*"]}]}'
    $script:noop = '{"version":1,"changes":[{"op":"set","id":"AA0072","action":"Info","levels":["*"],"stages":["*"]}]}'
    $script:releaseCi = '{"version":1,"changes":[{"op":"release","id":"LC0099","stages":["ci"]}]}'
    $script:releaseVnext = '{"version":1,"changes":[{"op":"release","id":"LC0099","stages":["vnext"]}]}'

    function Get-TestFolder {
        return Join-Path $TestDrive ([guid]::NewGuid().ToString('n').Substring(0, 12))
    }

    function Copy-Minimal {
        return New-FixtureRepo -Name 'valid-minimal' -Destination (Get-TestFolder)
    }

    function New-IssueBody {
        # The body GitHub renders from the issue form: the change set in a json fence under ### Changes, the note.
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helper; builds a string')]
        param([string]$Changes, [string]$Note = '_No response_')
        return "### Changes`n`n$($fence)json`n$Changes`n$fence`n`n### Note`n`n$Note`n"
    }

    function New-IssueData {
        # An issue as GET /repos/{r}/issues/{n} answers it (the fields the action reads).
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helper; builds a dictionary')]
        param(
            [string]$Changes = $script:setStrict,
            [string]$Note = '_No response_',
            [AllowNull()][string]$Body,
            [string]$State = 'open',
            [AllowNull()][string]$StateReason,
            [string[]]$Labels = @('rulebook-change'),
            [string]$Author = 'octo',
            [switch]$PullRequest
        )
        if (-not $PSBoundParameters.ContainsKey('Body')) { $Body = New-IssueBody -Changes $Changes -Note $Note }
        $data = [ordered]@{
            number             = 12
            title              = 'Rulebook change'
            state              = $State
            state_reason       = $(if ($StateReason) { $StateReason } else { $null })
            body               = $Body
            user               = [ordered]@{ login = $Author; type = 'User' }
            author_association = 'MEMBER'
            labels             = @($Labels | ForEach-Object { [ordered]@{ name = $_ } })
            html_url           = 'https://github.com/Contoso/rulebook/issues/12'
        }
        if ($PullRequest) { $data['pull_request'] = [ordered]@{ url = 'https://api.github.com/repos/Contoso/rulebook/pulls/12' } }
        return $data
    }

    function New-IssueFile {
        # The -IssuePath file: the issue plus the permission of its author (left out with -NoPermission).
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helper; writes only to TestDrive')]
        param([hashtable]$Issue = @{}, [string]$Permission = 'write', [switch]$NoPermission)
        $data = New-IssueData @Issue
        if (-not $NoPermission) { $data['permission'] = $Permission }
        $path = "$(Get-TestFolder).issue.json"
        Write-FixtureText -Path $path -Text (ConvertTo-Json -InputObject $data -Depth 6)
        return $path
    }

    function Invoke-Entry {
        # Runs ApplyChangeSet.ps1 in-process; returns the result object, the console lines, the summary and the outputs.
        param([hashtable]$Parameters)
        $folder = Get-TestFolder
        if (-not $Parameters.ContainsKey('RepositoryRoot')) { $Parameters.RepositoryRoot = Copy-Minimal }
        if (-not $Parameters.ContainsKey('IssueNumber')) { $Parameters.IssueNumber = '12' }
        if (-not $Parameters.ContainsKey('SummaryPath')) { $Parameters.SummaryPath = "$folder.summary.md" }
        if (-not $Parameters.ContainsKey('WorkPath')) { $Parameters.WorkPath = Join-Path $folder 'work' }
        if (-not $Parameters.ContainsKey('Repository')) { $Parameters.Repository = 'Contoso/rulebook' }
        if (-not $Parameters.ContainsKey('BaseBranch')) { $Parameters.BaseBranch = 'main' }
        if (-not $Parameters.ContainsKey('Now')) { $Parameters.Now = $script:now }
        if (-not $Parameters.ContainsKey('GitHubToken')) { $Parameters.GitHubToken = 'ghs_workflow' }
        # No request leaves the test: an unmocked GitHub call fails fast.
        if (-not $Parameters.ContainsKey('ApiUrl')) { $Parameters.ApiUrl = 'http://127.0.0.1:9' }
        $outputFile = "$folder.output.txt"
        $env:GITHUB_OUTPUT = $outputFile
        try {
            $output = @(& $script:entry @Parameters 6>&1 3>$null)
        } finally {
            $env:GITHUB_OUTPUT = $null
        }
        return [pscustomobject]@{
            Result  = $output | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] } | Select-Object -Last 1
            Lines   = @($output | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { [string]$_.MessageData })
            Summary = if (Test-Path -LiteralPath $Parameters.SummaryPath) { Get-Content -LiteralPath $Parameters.SummaryPath -Raw } else { '' }
            Output  = if (Test-Path -LiteralPath $outputFile) { Get-Content -LiteralPath $outputFile -Raw } else { '' }
        }
    }

    function Get-IssueAction {
        # The issue writes of a run as 'kind' strings: 'comment', 'close completed', 'label rulebook-change'.
        param([Parameter(Mandatory)]$Run)
        return @($Run.Result.IssueActions | ForEach-Object {
                # Inside switch, $_ is the switch value: keep the action.
                $action = $_
                switch ($action.Kind) { 'close' { "close $($action.StateReason)" } 'label' { "label $($action.Label)" } default { $action.Kind } }
            })
    }

    function Get-Comment {
        # The body of the only comment of a run.
        param([Parameter(Mandatory)]$Run)
        $comments = @($Run.Result.IssueActions | Where-Object Kind -EQ 'comment')
        $comments.Count | Should-Be 1
        return $comments[0].Body
    }

    $script:pullRequestResult = {
        param([Parameter(ValueFromRemainingArguments)][object[]]$Ignored)
        $null = $Ignored
        [pscustomobject]@{ Result = 'pull-request'; PullRequestUrl = 'https://github.com/Contoso/rulebook/pull/7'; Number = 7; Branch = 'rulebook-change/12/261008091530'; Sha = 'a' * 40; Fallback = $false; FallbackReason = $null; Diff = @(); DiffNote = $null; Body = 'body'; Title = 't' }
    }

    function Start-FakeApi {
        # A local stand-in for the GitHub API: -Routes maps 'METHOD /path' to @{ Status; Body (JSON text) }, anything
        # else answers 404. Requests lists every request as { Key, Query, Body }. Stop it with Stop-FakeApi.
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helper; a local listener for the suite')]
        param([Parameter(Mandatory)][hashtable]$Routes)
        $probe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $probe.Start()
        $port = ([System.Net.IPEndPoint]$probe.LocalEndpoint).Port
        $probe.Stop()
        $listener = [System.Net.HttpListener]::new()
        $listener.Prefixes.Add("http://localhost:$port/")
        $listener.Start()
        $requests = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
        $shell = [powershell]::Create()
        $null = $shell.AddScript({
                param($Listener, $Routes, $Requests)
                while ($Listener.IsListening) {
                    try { $context = $Listener.GetContext() } catch { break }
                    $request = $context.Request
                    $reader = [System.IO.StreamReader]::new($request.InputStream)
                    $text = $reader.ReadToEnd()
                    $reader.Dispose()
                    $key = '{0} {1}' -f $request.HttpMethod, $request.Url.AbsolutePath
                    $Requests.Enqueue([pscustomobject]@{ Key = $key; Query = $request.Url.Query; Body = $text })
                    $route = $Routes[$key]
                    $status = if ($null -ne $route) { [int]$route.Status } else { 404 }
                    $answer = if ($null -ne $route) { [string]$route.Body } else { '{"message":"Not Found"}' }
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes($answer)
                    $context.Response.StatusCode = $status
                    $context.Response.ContentType = 'application/json'
                    $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                    $context.Response.Close()
                }
            }).AddArgument($listener).AddArgument($Routes).AddArgument($requests)
        $handle = $shell.BeginInvoke()
        return [pscustomobject]@{ Url = "http://localhost:$port"; Listener = $listener; Shell = $shell; Handle = $handle; Requests = $requests }
    }

    function Stop-FakeApi {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helper; stops the local listener')]
        param([Parameter(Mandatory)]$Api)
        $Api.Listener.Stop()
        $Api.Listener.Close()
        try { $null = $Api.Shell.EndInvoke($Api.Handle) } catch { $null = $_ }
        $Api.Shell.Dispose()
    }

    function Get-ApiRoute {
        # The routes of an issue run: the issue, the permission, the label, the pull request list, the writes.
        param(
            [hashtable]$Issue = @{},
            [string]$Permission = 'write',
            [int]$PermissionStatus = 200,
            [int]$LabelStatus = 200,
            [string]$Pulls = '[]',
            [int]$PullsStatus = 200,
            [int]$CommentStatus = 201,
            [int]$CloseStatus = 200
        )
        $base = '/repos/Contoso/rulebook'
        return @{
            "GET $base/issues/12"                         = @{ Status = 200; Body = (ConvertTo-Json -InputObject (New-IssueData @Issue) -Depth 6) }
            "GET $base/collaborators/octo/permission"     = @{ Status = $PermissionStatus; Body = $(if ($PermissionStatus -eq 200) { "{`"permission`":`"$Permission`",`"role_name`":`"$Permission`"}" } else { '{"message":"Server Error"}' }) }
            "GET $base/labels/rulebook-change"            = @{ Status = $LabelStatus; Body = '{"name":"rulebook-change"}' }
            "POST $base/labels"                           = @{ Status = 201; Body = '{"name":"rulebook-change"}' }
            "POST $base/issues/12/labels"                 = @{ Status = 200; Body = '[{"name":"rulebook-change"}]' }
            "GET $base/pulls"                             = @{ Status = $PullsStatus; Body = $Pulls }
            "POST $base/issues/12/comments"               = @{ Status = $CommentStatus; Body = '{"id":1,"html_url":"https://github.com/Contoso/rulebook/issues/12#issuecomment-1"}' }
            "PATCH $base/issues/12"                       = @{ Status = $CloseStatus; Body = '{"number":12,"html_url":"https://github.com/Contoso/rulebook/issues/12"}' }
        }
    }
}

AfterAll {
    Restore-EngineRefEnvironment -Saved $script:savedEngineRef
    $env:GITHUB_OUTPUT = $script:saved.Output
    $env:GITHUB_STEP_SUMMARY = $script:saved.Summary
    $env:GITHUB_REPOSITORY = $script:saved.Repository
    $env:GITHUB_TOKEN = $script:saved.Token
    $env:GITHUB_SERVER_URL = $script:saved.Server
    Remove-Module Rulebook.Edit, Rulebook.Update, Rulebook.GitHub, Rulebook.Template, Rulebook.Validate, Rulebook.Generate, Rulebook.Quarantine, Rulebook.Action, Rulebook.Common -ErrorAction SilentlyContinue
}

Describe 'actions/ApplyChangeSet/action.yaml' {
    BeforeAll {
        $script:yaml = Get-Content -LiteralPath (Join-Path $actionDir 'action.yaml') -Raw
    }

    It 'is a composite action' {
        $yaml | Should-MatchString '(?m)^  using: composite$'
    }

    It 'requires issueNumber' {
        $yaml | Should-MatchString '(?ms)^  issueNumber:\n[^\n]*\n    required: true$'
    }

    It 'declares input <Name> with default <Default>' -ForEach @(
        @{ Name = 'token'; Default = "''" }
        @{ Name = 'directCommit'; Default = "'false'" }
        @{ Name = 'baseBranch'; Default = '${{ github.ref_name }}' }
        @{ Name = 'repositoryRoot'; Default = "'.'" }
        @{ Name = 'actor'; Default = '${{ github.actor }}' }
        @{ Name = 'label'; Default = "'rulebook-change'" }
        @{ Name = 'issuePath'; Default = "''" }
    ) {
        $yaml | Should-MatchString ("(?ms)^  {0}:\n.*?^    default: {1}$" -f $Name, [regex]::Escape($Default))
    }

    It 'marks issuePath as the CI seam' {
        $yaml | Should-MatchString '(?m)^  issuePath:\n    description: .*For the engine''s CI; do not set in a workflow\.$'
    }

    It 'declares the output <Name>' -ForEach @(
        @{ Name = 'result' }
        @{ Name = 'noop' }
        @{ Name = 'changedEndpoints' }
        @{ Name = 'pullRequestUrl' }
        @{ Name = 'branch' }
        @{ Name = 'issue' }
        @{ Name = 'issueState' }
        @{ Name = 'failure' }
    ) {
        $yaml | Should-MatchString ("(?m)^  {0}:\n.*\n    value: \$\{{\{{ steps\.apply\.outputs\.{0} \}}\}}$" -f $Name)
    }

    It 'passes inputs and the workflow token through env and never interpolates them into run' {
        $run = [regex]::Match($yaml, '(?ms)^      run: \|\n(.*)').Groups[1].Value
        $run | Should-NotMatchString '\$\{\{'
        foreach ($name in 'ISSUENUMBER', 'TOKEN', 'DIRECTCOMMIT', 'BASEBRANCH', 'REPOSITORYROOT', 'ACTOR', 'LABEL', 'ISSUEPATH') {
            $yaml | Should-MatchString "(?m)^        INPUT_$($name): \`$\{\{ inputs\.\w+ \}\}$"
        }
        # The issue is read and written with the workflow token, the change pushed with the secret's token.
        $yaml | Should-MatchString '(?m)^        GITHUB_TOKEN: \$\{\{ github\.token \}\}$'
        $run | Should-MatchString '(?m)^          GitHubToken    = \$env:GITHUB_TOKEN$'
        $run | Should-MatchString '(?m)^        Remove-Item -LiteralPath Env:GITHUB_TOKEN, Env:INPUT_TOKEN -ErrorAction SilentlyContinue$'
        $run | Should-MatchString 'GITHUB_ACTION_PATH'
        $run | Should-MatchString 'exit \$result\.ExitCode'
    }
}

Describe 'template/.github/workflows/ApplyRulebookChange.yaml' {
    BeforeAll {
        $script:workflow = Get-Content -LiteralPath (Join-Path $repoRoot 'template' '.github' 'workflows' 'ApplyRulebookChange.yaml') -Raw
        $script:settingsStep = [regex]::Match($workflow, '(?ms)^        run: \|\n(.*?)\n      - name:').Groups[1].Value
        $changeRule = Get-Content -LiteralPath (Join-Path $repoRoot 'template' '.github' 'workflows' 'ChangeRule.yaml') -Raw
        $script:changeRuleStep = [regex]::Match($changeRule, '(?ms)^        run: \|\n(.*?)\n\n').Groups[1].Value

        function Invoke-SettingsStep {
            # Runs the settings step in-process on a folder with -Settings as .github/Rulebook-Settings.json.
            param([string]$Settings)
            $script = Join-Path $TestDrive 'apply-settings-step.ps1'
            [System.IO.File]::WriteAllText($script, ($settingsStep -replace '(?m)^          ', ''))
            $root = Get-TestFolder
            Write-FixtureText -Path (Join-Path $root '.github' 'Rulebook-Settings.json') -Text $Settings
            $output = Join-Path $root 'settings-output.txt'
            $saved = $env:GITHUB_OUTPUT
            try {
                $env:GITHUB_OUTPUT = $output
                Push-Location -LiteralPath $root
                try { $null = & $script 6>$null } finally { Pop-Location }
            } finally {
                $env:GITHUB_OUTPUT = $saved
            }
            return @(Get-Content -LiteralPath $output)
        }
    }

    It 'is named Apply Rulebook Change and runs only on opened and edited issues' {
        $workflow | Should-MatchString '(?m)^name: Apply Rulebook Change$'
        $workflow | Should-MatchString '(?m)^on:\n  issues:\n    types: \[opened, edited\]\n\n'
        $workflow | Should-NotMatchString '(?m)^  (push|pull_request|schedule|workflow_dispatch|issue_comment):'
    }

    It 'runs on the label or the form marker, and on an edit only when the body changed' {
        $expected = @(
            '    if: >-'
            "      (contains(github.event.issue.labels.*.name, 'rulebook-change') || contains(github.event.issue.body, '### Changes'))"
            "      && (github.event.action == 'opened' || contains(toJSON(github.event.changes), '`"body`"'))"
        ) -join "`n"
        $workflow.Contains("  apply:`n    # An issue from the Rulebook change form") | Should-BeTrue
        $workflow.Contains($expected + "`n    runs-on: ubuntu-latest`n") | Should-BeTrue
    }

    It 'writes the issue with the workflow token and lists pull requests, one run per issue at a time' {
        $workflow | Should-MatchString '(?m)^permissions:\n  contents: read\n  issues: write\n  pull-requests: read\n\n'
        $workflow | Should-MatchString '(?m)^concurrency:\n  group: apply-rulebook-change-\$\{\{ github\.event\.issue\.number \}\}\n  cancel-in-progress: false$'
        $workflow | Should-MatchString '(?m)^        uses: actions/checkout@v7\n        with:\n          persist-credentials: false$'
    }

    It 'looks the secret up by the name from the settings and calls the engine action at main' {
        $workflow | Should-MatchString '(?m)^        uses: ALCops/rulebook-engine/actions/ApplyChangeSet@main$'
        $workflow | Should-MatchString '(?m)^          issueNumber: \$\{\{ github\.event\.issue\.number \}\}$'
        $workflow | Should-MatchString '(?m)^          token: \$\{\{ secrets\[steps\.settings\.outputs\.secretName\] \}\}$'
        $workflow | Should-MatchString '(?m)^          directCommit: \$\{\{ steps\.settings\.outputs\.directCommit \}\}$'
        # issuePath is the engine CI's seam; the workflow never sets it.
        $workflow | Should-NotMatchString 'issuePath'
    }

    It 'reads the settings with the step of Change Rule, never interpolating an expression into run' {
        $settingsStep | Should-MatchString 'ghTokenWorkflowSecretName'
        $settingsStep | Should-NotMatchString '\$\{\{'
        $settingsStep | Should-Be $changeRuleStep
    }

    It 'derives directCommit from commitOptions.createPullRequest: <Name>' -ForEach @(
        @{ Name = 'false gives a direct commit'; Settings = '{ "ghTokenWorkflowSecretName": "RULEBOOK_TOKEN", "commitOptions": { "createPullRequest": false } }'; Expected = @('secretName=RULEBOOK_TOKEN', 'directCommit=true') }
        @{ Name = 'true gives a pull request'; Settings = '{ "commitOptions": { "createPullRequest": true } }'; Expected = @('secretName=GHTOKENWORKFLOW', 'directCommit=false') }
        @{ Name = 'absent gives a pull request'; Settings = '{ "templateUrl": "x" }'; Expected = @('secretName=GHTOKENWORKFLOW', 'directCommit=false') }
    ) {
        Invoke-SettingsStep -Settings $Settings | Should-BeCollection $Expected
    }
}

Describe 'ApplyChangeSet.ps1 with an issue file' {
    Context 'the gate (D55)' {
        It 'applies the change set of an author with <Permission> permission' -ForEach @(
            @{ Permission = 'admin' }
            @{ Permission = 'write' }
        ) {
            $run = Invoke-Entry @{ IssuePath = (New-IssueFile -Permission $Permission) }
            # The plan ran; without a token the run stops at the token guard.
            $run.Result.Failure | Should-Be 'token'
            $run.Result.Plan.Valid | Should-BeTrue
        }

        It 'reads a missing permission as write' {
            $run = Invoke-Entry @{ IssuePath = (New-IssueFile -NoPermission) }
            $run.Result.Failure | Should-Be 'token'
        }

        It 'refuses an author with <Permission> permission before reading the body' -ForEach @(
            @{ Permission = 'read' }
            @{ Permission = 'none' }
            @{ Permission = 'maintain' }
            @{ Permission = 'triage' }
        ) {
            # A body that would not parse: the gate never reads it.
            $run = Invoke-Entry @{ IssuePath = (New-IssueFile -Permission $Permission -Issue @{ Body = 'not a form' }) }
            $run.Result.ExitCode | Should-Be 0
            $run.Result.Result | Should-Be 'refused'
            $run.Result.Plan | Should-BeNull
            Get-IssueAction $run | Should-BeCollection @('comment', 'close not_planned')
            Get-Comment $run | Should-Be "Only repository collaborators with write access can submit Rulebook changes.`n"
            @($run.Result.IssueActions | Where-Object Posted) | Should-BeCollection @()
            $run.Result.Annotations[-1] | Should-Be "::notice title=ApplyChangeSet::Refused: the author octo has the permission '$Permission' on the repository; only admin and write may submit Rulebook changes (D55). The issue was closed as not planned."
            $run.Output | Should-Be "result=refused`nnoop=false`nchangedEndpoints=`npullRequestUrl=`nbranch=`nissue=12`nissueState=closed-not-planned`nfailure=`n"
        }
    }

    Context 'skipped issues' {
        It 'skips a closed issue without a comment' {
            $run = Invoke-Entry @{ IssuePath = (New-IssueFile -Issue @{ State = 'closed'; StateReason = 'completed' }) }
            $run.Result.ExitCode | Should-Be 0
            $run.Result.Result | Should-Be 'skipped'
            @($run.Result.IssueActions) | Should-BeCollection @()
            $run.Result.Annotations | Should-BeCollection @('::notice title=ApplyChangeSet::Issue #12 is closed; nothing was done.')
            $run.Output | Should-Be "result=skipped`nnoop=false`nchangedEndpoints=`npullRequestUrl=`nbranch=`nissue=12`nissueState=closed-completed`nfailure=`n"
        }

        It 'skips a pull request' {
            $run = Invoke-Entry @{ IssuePath = (New-IssueFile -Issue @{ PullRequest = $true }) }
            $run.Result.Result | Should-Be 'skipped'
            @($run.Result.IssueActions) | Should-BeCollection @()
            $run.Result.Annotations | Should-BeCollection @('::notice title=ApplyChangeSet::#12 is a pull request, not an issue; nothing was done.')
        }
    }

    Context 'the label' {
        It 'adds the label only when the issue does not carry it' {
            $with = Invoke-Entry @{ IssuePath = (New-IssueFile) }
            @(Get-IssueAction $with | Where-Object { $_ -like 'label*' }) | Should-BeCollection @()
            $without = Invoke-Entry @{ IssuePath = (New-IssueFile -Issue @{ Labels = @('other') }) }
            (Get-IssueAction $without)[0] | Should-Be 'label rulebook-change'
        }

        It 'uses the label input and skips the label with an empty one' {
            $custom = Invoke-Entry @{ IssuePath = (New-IssueFile); Label = 'dashboard' }
            (Get-IssueAction $custom)[0] | Should-Be 'label dashboard'
            $none = Invoke-Entry @{ IssuePath = (New-IssueFile -Issue @{ Labels = @() }); Label = '' }
            @(Get-IssueAction $none | Where-Object { $_ -like 'label*' }) | Should-BeCollection @()
        }
    }

    Context 'a change set that cannot be read' {
        It 'comments the missing Changes section and fails validation with the issue left open' {
            $body = [System.IO.File]::ReadAllText((Join-Path $issues 'no-changes-section.md'))
            $run = Invoke-Entry @{ IssuePath = (New-IssueFile -Issue @{ Body = $body }) }
            $run.Result.ExitCode | Should-Be 1
            $run.Result.Failure | Should-Be 'validation'
            Get-IssueAction $run | Should-BeCollection @('comment')
            Get-Comment $run | Should-Be ("The change set could not be read:`n`n" +
                '- `The issue body has no "### Changes" section; submit the Rulebook change form from the dashboard, or add the section with the change set in a json code block.`' +
                "`n`nNothing was written. Edit the issue body to run it again.`n")
            $run.Output | Should-Be "result=`nnoop=false`nchangedEndpoints=`npullRequestUrl=`nbranch=`nissue=12`nissueState=open`nfailure=validation`n"
        }

        It 'comments a JSON error with its position' {
            $run = Invoke-Entry @{ IssuePath = (New-IssueFile -Issue @{ Changes = '{"version":1,' }) }
            $run.Result.Failure | Should-Be 'validation'
            Get-Comment $run | Should-MatchString '(?m)^- `The change set is not valid JSON \(line \d+, byte position \d+\): [^`]+`$'
            $run.Result.Annotations[0] | Should-BeLikeString '::error title=ApplyChangeSet::The change set is not valid JSON (line *'
        }

        It 'comments every schema error on a line of its own' {
            $run = Invoke-Entry @{ IssuePath = (New-IssueFile -Issue @{ Changes = '{"version":2,"changes":[],"extra":true}' }) }
            $run.Result.Failure | Should-Be 'validation'
            $comment = Get-Comment $run
            $lines = @($comment.Split("`n") | Where-Object { $_.StartsWith('- ') })
            $lines.Count | Should-BeGreaterThan 1
            $lines.Count | Should-Be $run.Result.Annotations.Count
            foreach ($line in $lines) { $line | Should-MatchString '\A- `The change set does not match the schema: [^`]+`\z' }
            @($run.Result.IssueActions | Where-Object Kind -EQ 'close') | Should-BeCollection @()
        }

        It 'keeps the text of a hostile body inside the code span (backticks dropped)' {
            $run = Invoke-Entry @{ IssuePath = (New-IssueFile -Issue @{ Changes = '`@octo [x](https://example.com)' }) }
            $line = @((Get-Comment $run).Split("`n") | Where-Object { $_.StartsWith('- ') })
            $line.Count | Should-Be 1
            $line[0] | Should-MatchString '\A- `[^`]+`\z'
        }
    }

    Context 'a change set that does not validate' {
        It 'comments an unknown id and an unknown slug, one line each, and writes nothing' {
            $changes = '{"version":1,"changes":[{"op":"set","id":"LC9999","action":"None","levels":["*"],"stages":["*"]},{"op":"set","id":"LC0015","action":"None","levels":["nightly"],"stages":["ci"]}]}'
            $root = Copy-Minimal
            $before = Get-FileHash -LiteralPath (Join-Path $root 'overrides.json')
            $run = Invoke-Entry @{ RepositoryRoot = $root; WorkspaceRoot = $root; IssuePath = (New-IssueFile -Issue @{ Changes = $changes }) }
            $run.Result.ExitCode | Should-Be 1
            $run.Result.Failure | Should-Be 'validation'
            $comment = Get-Comment $run
            $comment | Should-MatchString '\AThe change set is not valid; nothing was written\.\n\n'
            $comment | Should-MatchString '(?m)^- `LC9999 is not in catalog/diagnostics\.json`$'
            @($comment.Split("`n") | Where-Object { $_.StartsWith('- ') }).Count | Should-Be 2
            $comment | Should-MatchString '(?m)^Edit the issue body to run it again\.\n\z'
            @($run.Result.Annotations | Where-Object { $_ -like '::error file=overrides.json,title=ApplyChangeSet::*' }).Count | Should-Be 2
            (Get-FileHash -LiteralPath (Join-Path $root 'overrides.json')).Hash | Should-Be $before.Hash
            Get-IssueAction $run | Should-BeCollection @('comment')
        }

        It 'comments a repeated change' {
            $changes = '{"version":1,"changes":[{"op":"release","id":"LC0099","stages":["ci"]},{"op":"release","id":"LC0099","stages":["ci"]}]}'
            $run = Invoke-Entry @{ IssuePath = (New-IssueFile -Issue @{ Changes = $changes }) }
            $run.Result.Failure | Should-Be 'validation'
            @((Get-Comment $run).Split("`n") | Where-Object { $_.StartsWith('- ') }).Count | Should-Be 1
        }
    }

    Context 'no-ops (D48)' {
        It 'comments Nothing to change and closes the issue as completed, without a token: <Name>' -ForEach @(
            @{ Name = 'a set that changes nothing'; Changes = '{"version":1,"changes":[{"op":"set","id":"AA0072","action":"Info","levels":["*"],"stages":["*"]}]}'; Line = '- Leaves AA0072 at Info for levels *, stages * (the entry is unchanged).' }
            @{ Name = 'a release of an id no stage quarantines'; Changes = '{"version":1,"changes":[{"op":"release","id":"LC0099","stages":["vnext"]}]}'; Line = '- Leaves LC0099 as it is for stages vnext (no quarantine file of these stages lists it; nothing is written).' }
        ) {
            $run = Invoke-Entry @{ IssuePath = (New-IssueFile -Issue @{ Changes = $Changes }) }
            $run.Result.ExitCode | Should-Be 0
            $run.Result.NoOp | Should-BeTrue
            Get-IssueAction $run | Should-BeCollection @('comment', 'close completed')
            Get-Comment $run | Should-Be "Nothing to change.`n`n$Line`n"
            $run.Output | Should-Be "result=no-op`nnoop=true`nchangedEndpoints=`npullRequestUrl=`nbranch=`nissue=12`nissueState=closed-completed`nfailure=`n"
        }
    }

    Context 'the token guard' {
        It 'comments the missing secret with the ghtokenworkflow page and leaves the issue open' {
            $run = Invoke-Entry @{ IssuePath = (New-IssueFile) }
            $run.Result.ExitCode | Should-Be 1
            $run.Result.Failure | Should-Be 'token'
            $run.Result.Annotations | Should-BeCollection @('::error title=ApplyChangeSet::The GHTOKENWORKFLOW secret is needed to apply a change set. Read https://github.com/ALCops/rulebook/blob/preview/docs/ghtokenworkflow.md')
            Get-IssueAction $run | Should-BeCollection @('comment')
            Get-Comment $run | Should-Be "The change set is valid, but the GHTOKENWORKFLOW secret is missing or cannot be used, so nothing was pushed (the secret is empty or not set). A maintainer sets it as described in https://github.com/ALCops/rulebook/blob/preview/docs/ghtokenworkflow.md; edit the issue to run again.`n"
            $run.Output | Should-Be "result=`nnoop=false`nchangedEndpoints=strict.ci`npullRequestUrl=`nbranch=`nissue=12`nissueState=open`nfailure=token`n"
        }

        It 'lists the endpoints a release changes when the token is missing (the CI release case)' {
            $run = Invoke-Entry @{ IssuePath = (New-IssueFile -Issue @{ Changes = $releaseCi }) }
            $run.Result.Failure | Should-Be 'token'
            # The ci.yml job applychangeset-action asserts this exact string.
            $run.Result.Outputs.changedEndpoints | Should-Be 'essential.ci,recommended.ci,strict.ci,complete.ci'
        }

        It 'comments a secret that cannot be exchanged' {
            $run = Invoke-Entry @{ IssuePath = (New-IssueFile); Token = '{not json' }
            $run.Result.Failure | Should-Be 'token'
            $run.Result.Annotations[-1] | Should-BeLikeString "::error title=ApplyChangeSet::The GHTOKENWORKFLOW secret could not be used: The token secret starts with '{' but is not JSON.*"
            Get-Comment $run | Should-BeLikeString "The change set is valid, but the GHTOKENWORKFLOW secret is missing or cannot be used, so nothing was pushed (The token secret starts with '{' but is not JSON.*). A maintainer sets it*"
        }

        It 'masks the write token before any output names it' {
            $run = Invoke-Entry @{ IssuePath = (New-IssueFile); Token = 'ghp_secret_value'; RemoteUrl = (Join-Path (Get-TestFolder) 'never.git') }
            @($run.Lines | Where-Object { $_ -like '*ghp_secret_value*' }) | Should-BeCollection @('::add-mask::ghp_secret_value')
            @($run.Result.IssueActions | Where-Object { $_.Body -like '*ghp_secret_value*' }) | Should-BeCollection @()
        }
    }

    Context 'the publish seam' {
        It 'opens the pull request with the engine title and Closes, and comments the link and the body' {
            # The seam runs in the scope of ApplyChangeSet.ps1, where $script: is that script's scope: a local copy.
            $pullRequest = $script:pullRequestResult
            $seen = @{}
            $publish = {
                param($BranchPrefix, $DirectCommit, $Labels, $Title, $BodySuffix, $BodyPrefix, [Parameter(ValueFromRemainingArguments)][object[]]$Rest)
                $null = $Rest
                $seen['BranchPrefix'] = $BranchPrefix
                $seen['DirectCommit'] = $DirectCommit
                $seen['Labels'] = $Labels
                $seen['Title'] = $Title
                $seen['BodySuffix'] = $BodySuffix
                $seen['BodyPrefix'] = $BodyPrefix
                & $pullRequest
            }
            $run = Invoke-Entry @{ IssuePath = (New-IssueFile -Issue @{ Note = 'Strict CI is too noisy.' }); Token = 'ghp_x'; PublishCommand = $publish }
            $run.Result.ExitCode | Should-Be 0
            $seen.BranchPrefix | Should-Be 'rulebook-change/12'
            $seen.DirectCommit | Should-BeFalse
            $seen.Labels | Should-BeCollection @('rulebook')
            $seen.Title | Should-Be 'Change LC0015 to None (levels: strict, stages: ci) (#12)'
            $seen.BodySuffix | Should-Be 'Closes #12'
            $seen.BodyPrefix | Should-BeNull
            Get-IssueAction $run | Should-BeCollection @('comment')
            $comment = Get-Comment $run
            $comment | Should-MatchString '\APull request: https://github\.com/Contoso/rulebook/pull/7\n\nStrict CI is too noisy\.\n\n'
            $comment | Should-MatchString '(?m)^\| strict\.ci \| Warning \(level:strict\) \| None \(override\) \|'
            $comment | Should-NotMatchString 'Closes'
            $run.Result.Annotations[-1] | Should-Be '::notice title=ApplyChangeSet::Pull request: https://github.com/Contoso/rulebook/pull/7'
            $run.Output | Should-Be "result=pull-request`nnoop=false`nchangedEndpoints=strict.ci`npullRequestUrl=https://github.com/Contoso/rulebook/pull/7`nbranch=rulebook-change/12/261008091530`nissue=12`nissueState=open`nfailure=`n"
            $run.Summary | Should-MatchString '\A## Rulebook change \(#12\)\n\nPull request: https://github\.com/Contoso/rulebook/pull/7\n'
        }

        It 'titles a change set of several items Rulebook change: <n> changes (#<issue>)' {
            # The seam runs in the scope of ApplyChangeSet.ps1, where $script: is that script's scope: a local copy.
            $pullRequest = $script:pullRequestResult
            $seen = @{}
            $publish = { param($Title, [Parameter(ValueFromRemainingArguments)][object[]]$Rest) $null = $Rest; $seen['Title'] = $Title; & $pullRequest }
            $changes = '{"version":1,"changes":[{"op":"set","id":"LC0015","action":"None","levels":["strict"],"stages":["ci"]},{"op":"release","id":"LC0099","stages":["ci"]}]}'
            $null = Invoke-Entry @{ IssuePath = (New-IssueFile -Issue @{ Changes = $changes }); Token = 'ghp_x'; PublishCommand = $publish }
            $seen.Title | Should-Be 'Rulebook change: 2 changes (#12)'
        }

        It 'caps the engine title at 200 characters before the issue number' {
            # Long level slugs: the title of a set on every level runs past 200 characters.
            $root = Copy-Minimal
            $pad = 'x' * 40
            foreach ($file in @(Get-ChildItem -LiteralPath $root -Recurse -File -Force)) {
                $text = [System.IO.File]::ReadAllText($file.FullName)
                foreach ($level in 'essential', 'recommended', 'strict', 'complete') {
                    $text = $text.Replace($level, "$level$pad").Replace((Get-Culture).TextInfo.ToTitleCase($level), (Get-Culture).TextInfo.ToTitleCase($level) + $pad)
                }
                [System.IO.File]::WriteAllText($file.FullName, $text)
                $name = $file.Name
                foreach ($level in 'essential', 'recommended', 'strict', 'complete') { $name = $name.Replace("$level.", "$level$pad.") }
                if ($name -cne $file.Name) { Rename-Item -LiteralPath $file.FullName -NewName $name }
            }
            $levels = (@('essential', 'recommended', 'strict', 'complete') | ForEach-Object { "`"$_$pad`"" }) -join ','
            # The seam runs in the scope of ApplyChangeSet.ps1, where $script: is that script's scope: a local copy.
            $pullRequest = $script:pullRequestResult
            $seen = @{}
            $publish = { param($Title, [Parameter(ValueFromRemainingArguments)][object[]]$Rest) $null = $Rest; $seen['Title'] = $Title; & $pullRequest }
            $changes = '{"version":1,"changes":[{"op":"set","id":"AA0001","action":"None","levels":[' + $levels + '],"stages":["ci"]}]}'
            $run = Invoke-Entry @{ RepositoryRoot = $root; IssuePath = (New-IssueFile -Issue @{ Changes = $changes }); Token = 'ghp_x'; PublishCommand = $publish }
            $run.Result.ExitCode | Should-Be 0
            $seen.Title.Length | Should-Be 206
            $seen.Title | Should-MatchString '\AChange AA0001 to None \(levels: essentialx+, .*\.\.\. \(#12\)\z'
        }

        It 'lets a non-empty Note field win over the note of the change set' {
            $changes = '{"version":1,"note":"From the JSON","changes":[{"op":"set","id":"LC0015","action":"None","levels":["strict"],"stages":["ci"]}]}'
            $run = Invoke-Entry @{ IssuePath = (New-IssueFile -Issue @{ Changes = $changes; Note = 'From the form' }); Token = 'ghp_x'; PublishCommand = $script:pullRequestResult }
            $run.Result.Plan.ChangeSet['note'] | Should-Be 'From the form'
            Get-Comment $run | Should-MatchString '\APull request: \S+\n\nFrom the form\n\n'
        }

        It 'keeps the note of the change set when the Note field is empty' {
            $changes = '{"version":1,"note":"From the JSON","changes":[{"op":"set","id":"LC0015","action":"None","levels":["strict"],"stages":["ci"]}]}'
            $run = Invoke-Entry @{ IssuePath = (New-IssueFile -Issue @{ Changes = $changes }); Token = 'ghp_x'; PublishCommand = $script:pullRequestResult }
            $run.Result.Plan.ChangeSet['note'] | Should-Be 'From the JSON'
            Get-Comment $run | Should-MatchString '\APull request: \S+\n\nFrom the JSON\n\n'
        }

        It 'comments a direct commit with its link and closes the issue as completed' {
            $publish = {
                param([Parameter(ValueFromRemainingArguments)][object[]]$Ignored)
                $null = $Ignored
                [pscustomobject]@{ Result = 'direct-commit'; PullRequestUrl = $null; Number = $null; Branch = 'main'; Sha = 'b' * 40; Fallback = $false; FallbackReason = $null; Diff = @(); DiffNote = $null; Body = $null; Title = 't' }
            }
            $run = Invoke-Entry @{ IssuePath = (New-IssueFile); Token = 'ghp_x'; DirectCommit = $true; PublishCommand = $publish }
            $run.Result.ExitCode | Should-Be 0
            $run.Result.Result | Should-Be 'direct-commit'
            Get-IssueAction $run | Should-BeCollection @('comment', 'close completed')
            Get-Comment $run | Should-MatchString "\ACommitted to main \(https://github\.com/Contoso/rulebook/commit/$('b' * 40)\)\n\nNo justification given\.\n\n"
            $run.Output | Should-Be "result=direct-commit`nnoop=false`nchangedEndpoints=strict.ci`npullRequestUrl=`nbranch=main`nissue=12`nissueState=closed-completed`nfailure=`n"
        }

        It 'reports a base branch that already holds the change as a no-op and closes the issue' {
            $publish = {
                param([Parameter(ValueFromRemainingArguments)][object[]]$Ignored)
                $null = $Ignored
                [pscustomobject]@{ Result = 'no-changes'; PullRequestUrl = $null; Number = $null; Branch = 'main'; Sha = 'a' * 40; Fallback = $false; FallbackReason = $null; Diff = @(); DiffNote = $null; Body = $null; Title = 't' }
            }
            $run = Invoke-Entry @{ IssuePath = (New-IssueFile); Token = 'ghp_x'; PublishCommand = $publish }
            $run.Result.ExitCode | Should-Be 0
            $run.Result.NoOp | Should-BeTrue
            Get-IssueAction $run | Should-BeCollection @('comment', 'close completed')
            Get-Comment $run | Should-Be "Nothing to change: main already holds this change.`n"
            $run.Output | Should-Be "result=no-op`nnoop=true`nchangedEndpoints=`npullRequestUrl=`nbranch=main`nissue=12`nissueState=closed-completed`nfailure=`n"
        }

        It 'maps a <Stage> failure of the seam with the token hint and comments it' -ForEach @(
            @{ Stage = 'pull-request'; What = 'Failed to create the pull request for the change set' }
            @{ Stage = 'push'; What = 'Failed to push the change set' }
        ) {
            $publish = {
                param([Parameter(ValueFromRemainingArguments)][object[]]$Ignored)
                $null = $Ignored
                $exception = [System.InvalidOperationException]::new('Branch rulebook-change/12/261008091530 was pushed. Could not create the pull request (HTTP 422).')
                $exception.Data['Stage'] = $Stage
                throw $exception
            }
            $run = Invoke-Entry @{ IssuePath = (New-IssueFile); Token = 'ghp_x'; PublishCommand = $publish }
            $run.Result.ExitCode | Should-Be 1
            $run.Result.Failure | Should-Be $Stage
            $run.Result.Annotations[-1] | Should-BeLikeString "::error title=ApplyChangeSet::$What. Make sure that the token in the secret GHTOKENWORKFLOW*"
            Get-IssueAction $run | Should-BeCollection @('comment')
            Get-Comment $run | Should-BeLikeString "$What. Make sure that the token*(Error was: Branch rulebook-change/12/261008091530 was pushed.*)`n`nEdit the issue to run it again.`n"
            $run.Output | Should-MatchString "(?m)^issueState=open\nfailure=$Stage\n\z"
        }

        It 'reports a base branch that moved without the token hint' {
            $publish = {
                param([Parameter(ValueFromRemainingArguments)][object[]]$Ignored)
                $null = $Ignored
                $exception = [System.InvalidOperationException]::new('The base branch moved since the change was planned (main aaaaaaa is now bbbbbbb); nothing was pushed. Run the workflow again.')
                $exception.Data['Stage'] = 'push'
                $exception.Data['Reason'] = 'base-moved'
                throw $exception
            }
            $run = Invoke-Entry @{ IssuePath = (New-IssueFile); Token = 'ghp_x'; PublishCommand = $publish }
            $run.Result.Failure | Should-Be 'push'
            $run.Result.Annotations[-1] | Should-Be '::error title=ApplyChangeSet::The base branch moved since the change was planned (main aaaaaaa is now bbbbbbb); nothing was pushed. Run the workflow again.'
            Get-Comment $run | Should-BeLikeString 'The base branch moved since the change was planned*'
        }
    }

    Context 'against a bare remote' -Skip:$gitMissing {
        It 'pushes a direct commit titled with the issue number' {
            $bare = New-BareFixtureRepo -Source $minimal -Destination (Join-Path (Get-TestFolder) 'origin.git')
            $run = Invoke-Entry @{ IssuePath = (New-IssueFile); Token = 'ghp_x'; DirectCommit = $true; RemoteUrl = $bare }
            $run.Result.ExitCode | Should-Be 0
            $run.Result.Result | Should-Be 'direct-commit'
            $sha = (& git -C $bare rev-parse refs/heads/main).Trim()
            (& git -C $bare log -1 --format=%s main) | Should-Be 'Change LC0015 to None (levels: strict, stages: ci) (#12)'
            Get-Comment $run | Should-MatchString "\ACommitted to main \(https://github\.com/Contoso/rulebook/commit/$sha\)\n\n"
            Get-IssueAction $run | Should-BeCollection @('comment', 'close completed')
        }

        It 'falls back to the issue branch when the direct push is refused and names it when the pull request cannot be opened' {
            $bare = New-BareFixtureRepo -Source $minimal -Destination (Join-Path (Get-TestFolder) 'origin.git')
            Add-RejectPushHook -BarePath $bare -Branch 'main'
            $originSha = (& git -C $bare rev-parse refs/heads/main).Trim()
            $run = Invoke-Entry @{ IssuePath = (New-IssueFile); Token = 'ghp_x'; DirectCommit = $true; RemoteUrl = $bare }
            (& git -C $bare rev-parse refs/heads/main).Trim() | Should-Be $originSha
            (& git -C $bare rev-parse --verify --quiet refs/heads/rulebook-change/12/261008091530) | Should-NotBeNull
            # The pull request call goes nowhere in the test.
            $run.Result.Failure | Should-Be 'pull-request'
            @($run.Result.Annotations | Where-Object { $_ -like '::warning title=ApplyChangeSet::The direct push to main was refused; the branch was pushed instead.*' }).Count | Should-Be 1
            Get-Comment $run | Should-BeLikeString '*Branch rulebook-change/12/261008091530 was pushed*'
            Get-IssueAction $run | Should-BeCollection @('comment')
        }
    }

    Context 'the work folder and the issue number' {
        It 'leaves a work folder the caller passed in place' {
            $work = Join-Path (Get-TestFolder) 'work'
            $null = New-Item -ItemType Directory -Path $work
            Write-FixtureText -Path (Join-Path $work 'keep.txt') -Text 'mine'
            $null = Invoke-Entry @{ IssuePath = (New-IssueFile); WorkPath = $work }
            Test-Path -LiteralPath (Join-Path $work 'keep.txt') -PathType Leaf | Should-BeTrue
        }

        It 'removes the work folder it names itself' {
            $runnerTemp = Get-TestFolder
            $null = New-Item -ItemType Directory -Path $runnerTemp
            $saved = $env:RUNNER_TEMP
            $env:RUNNER_TEMP = $runnerTemp
            try {
                $null = & $script:entry -RepositoryRoot (Copy-Minimal) -IssueNumber 12 -IssuePath (New-IssueFile) -SummaryPath "$(Get-TestFolder).summary.md" 6>$null
            } finally {
                $env:RUNNER_TEMP = $saved
            }
            @(Get-ChildItem -LiteralPath $runnerTemp -Force) | Should-BeCollection @()
        }

        It 'refuses an issue number that is not one: <Value>' -ForEach @(
            @{ Value = '' }
            @{ Value = '0' }
            @{ Value = '12a' }
            @{ Value = '-3' }
        ) {
            $run = Invoke-Entry @{ IssuePath = (New-IssueFile); IssueNumber = $Value }
            $run.Result.ExitCode | Should-Be 1
            $run.Result.Failure | Should-Be 'error'
            @($run.Result.IssueActions) | Should-BeCollection @()
            $run.Summary | Should-MatchString '\A## Rulebook change\n\n'
        }

        It 'fails with failure issue when the issue file cannot be read' {
            $run = Invoke-Entry @{ IssuePath = (Join-Path (Get-TestFolder) 'missing.json') }
            $run.Result.ExitCode | Should-Be 1
            $run.Result.Failure | Should-Be 'issue'
            @($run.Result.Annotations).Count | Should-Be 1
            $run.Result.Annotations[0] | Should-BeLikeString '::error title=ApplyChangeSet::Could not read issue #12: *'
        }
    }
}

Describe 'ApplyChangeSet.ps1 against the GitHub API' {
    BeforeEach {
        $script:api = $null
    }

    AfterEach {
        if ($null -ne $script:api) { Stop-FakeApi -Api $script:api }
    }

    It 'posts the refusal and closes the issue as not planned for an author with <Permission>' -ForEach @(
        @{ Permission = 'read'; PermissionStatus = 200 }
        @{ Permission = 'none'; PermissionStatus = 404 }
    ) {
        $script:api = Start-FakeApi -Routes (Get-ApiRoute -Permission $Permission -PermissionStatus $PermissionStatus)
        $run = Invoke-Entry @{ ApiUrl = $api.Url }
        $run.Result.Result | Should-Be 'refused'
        @($run.Result.IssueActions | ForEach-Object Posted) | Should-BeCollection @($true, $true)
        $requests = @($api.Requests.ToArray())
        @($requests | ForEach-Object Key) | Should-BeCollection @('GET /repos/Contoso/rulebook/issues/12', 'GET /repos/Contoso/rulebook/collaborators/octo/permission', 'POST /repos/Contoso/rulebook/issues/12/comments', 'PATCH /repos/Contoso/rulebook/issues/12')
        ($requests[3].Body | ConvertFrom-Json -AsHashtable)['state_reason'] | Should-Be 'not_planned'
    }

    It 'fails closed with failure issue when the permission cannot be read' {
        $script:api = Start-FakeApi -Routes (Get-ApiRoute -PermissionStatus 500)
        $run = Invoke-Entry @{ ApiUrl = $api.Url }
        $run.Result.ExitCode | Should-Be 1
        $run.Result.Failure | Should-Be 'issue'
        $run.Result.Plan | Should-BeNull
        @($run.Result.IssueActions) | Should-BeCollection @()
        @($run.Result.Annotations).Count | Should-Be 1
        $run.Result.Annotations[0] | Should-BeLikeString '::error title=ApplyChangeSet::Could not read the permission of octo on the repository, so the change set was not applied: *'
    }

    It 'fails with failure issue when the issue cannot be read' {
        $routes = Get-ApiRoute
        $routes.Remove('GET /repos/Contoso/rulebook/issues/12')
        $script:api = Start-FakeApi -Routes $routes
        $run = Invoke-Entry @{ ApiUrl = $api.Url }
        $run.Result.Failure | Should-Be 'issue'
        $run.Output | Should-MatchString '(?m)^issue=12\nissueState=\nfailure=issue\n\z'
    }

    It 'creates and adds a missing label' {
        $script:api = Start-FakeApi -Routes (Get-ApiRoute -LabelStatus 404 -Issue @{ Labels = @() })
        $run = Invoke-Entry @{ ApiUrl = $api.Url }
        $keys = @($api.Requests.ToArray() | ForEach-Object Key)
        $keys | Should-ContainCollection @('GET /repos/Contoso/rulebook/labels/rulebook-change', 'POST /repos/Contoso/rulebook/labels', 'POST /repos/Contoso/rulebook/issues/12/labels')
        @($run.Result.IssueActions)[0].Posted | Should-BeTrue
    }

    It 'warns and goes on when the label cannot be added' {
        $script:api = Start-FakeApi -Routes (Get-ApiRoute -LabelStatus 500 -Issue @{ Labels = @() })
        $run = Invoke-Entry @{ ApiUrl = $api.Url }
        @($run.Result.Annotations | Where-Object { $_ -like '::warning title=ApplyChangeSet::Could not add the label rulebook-change to issue #12: *' }).Count | Should-Be 1
        $run.Result.Failure | Should-Be 'token'
    }

    It 'comments the open pull request of the issue and creates nothing' {
        $pulls = '[{"number":5,"html_url":"https://github.com/Contoso/rulebook/pull/5","title":"t","head":{"ref":"rulebook-change/12/261001000000","repo":{"full_name":"Contoso/rulebook"}}}]'
        $script:api = Start-FakeApi -Routes (Get-ApiRoute -Pulls $pulls)
        $run = Invoke-Entry @{ ApiUrl = $api.Url; Token = 'ghp_x'; PublishCommand = { throw 'never' } }
        $run.Result.ExitCode | Should-Be 0
        $run.Result.Result | Should-Be 'pull-request-exists'
        $run.Result.Plan | Should-BeNull
        Get-Comment $run | Should-Be "Pull request already exists: https://github.com/Contoso/rulebook/pull/5`n"
        $run.Output | Should-Be "result=pull-request-exists`nnoop=false`nchangedEndpoints=`npullRequestUrl=`nbranch=`nissue=12`nissueState=open`nfailure=`n"
        @($api.Requests.ToArray() | Where-Object Key -EQ 'GET /repos/Contoso/rulebook/pulls')[0].Query | Should-BeLikeString '*base=main*'
    }

    It 'does not count a pull request of issue 123 as one of issue 12' {
        $pulls = '[{"number":5,"html_url":"https://github.com/Contoso/rulebook/pull/5","title":"t","head":{"ref":"rulebook-change/123/261001000000","repo":{"full_name":"Contoso/rulebook"}}}]'
        $script:api = Start-FakeApi -Routes (Get-ApiRoute -Pulls $pulls)
        $run = Invoke-Entry @{ ApiUrl = $api.Url; Token = 'ghp_x'; PublishCommand = $script:pullRequestResult }
        $run.Result.Result | Should-Be 'pull-request'
    }

    It 'warns that the duplicate guard is inactive when the pull requests cannot be listed' {
        $script:api = Start-FakeApi -Routes (Get-ApiRoute -PullsStatus 500)
        $run = Invoke-Entry @{ ApiUrl = $api.Url }
        @($run.Result.Annotations | Where-Object { $_ -like '::warning title=ApplyChangeSet::duplicate guard inactive: *' }).Count | Should-Be 1
        $run.Result.Failure | Should-Be 'token'
    }

    It 'fails with failure issue when the comment of a no-op cannot be posted' {
        $script:api = Start-FakeApi -Routes (Get-ApiRoute -Issue @{ Changes = $noop } -CommentStatus 500)
        $run = Invoke-Entry @{ ApiUrl = $api.Url }
        $run.Result.ExitCode | Should-Be 1
        $run.Result.Failure | Should-Be 'issue'
        $run.Result.Annotations[-1] | Should-BeLikeString '::error title=ApplyChangeSet::Could not comment on issue #12: *'
        # The close is not tried after the comment failed.
        @($api.Requests.ToArray() | Where-Object Key -EQ 'PATCH /repos/Contoso/rulebook/issues/12') | Should-BeCollection @()
    }

    It 'keeps the failure kind of a validation error when its comment cannot be posted' {
        $script:api = Start-FakeApi -Routes (Get-ApiRoute -Issue @{ Changes = '{' } -CommentStatus 500)
        $run = Invoke-Entry @{ ApiUrl = $api.Url }
        $run.Result.Failure | Should-Be 'validation'
        $run.Result.Annotations[-1] | Should-BeLikeString '::error title=ApplyChangeSet::Could not comment on issue #12: *'
    }

    It 'only warns when the comment after the pull request cannot be posted' {
        $script:api = Start-FakeApi -Routes (Get-ApiRoute -CommentStatus 500)
        $run = Invoke-Entry @{ ApiUrl = $api.Url; Token = 'ghp_x'; PublishCommand = $script:pullRequestResult }
        $run.Result.ExitCode | Should-Be 0
        $run.Result.Result | Should-Be 'pull-request'
        @($run.Result.Annotations | Where-Object { $_ -like '::warning title=ApplyChangeSet::Could not comment on issue #12: *' }).Count | Should-Be 1
        @($run.Result.IssueActions)[0].Posted | Should-BeFalse
    }
}

Describe 'ApplyChangeSet.ps1 parameter binding' {
    It 'rejects a stray positional value' {
        # PositionalBinding = $false (#61): every caller binds by name, so a stray value fails before the script runs.
        { & $script:entry -RepositoryRoot $TestDrive 'stray' } | Should-Throw -ExceptionType ([System.Management.Automation.ParameterBindingException]) -ExceptionMessage '*positional parameter*stray*'
    }
}
