# Testing

How the engine is tested: the conventions the Pester suites follow, the fixtures and helpers they share, what CI reports, the no-network rule, the code paths no test reaches and why, and the heavier test layers that v1 leaves out. The decisions are [D9](../adr/0009-tooling-powershell-7-and-pester-on-ubuntu-runners.md), [D12](../adr/0012-testing-scope-for-v1-is-pester-unit-tests.md), [D39](../adr/0039-test-framework-is-pester-6.md) and [D51](../adr/0051-test-coverage-is-a-report-not-a-gate.md); the commands are in [CONTRIBUTING.md](../../CONTRIBUTING.md) sections 3 and 4.

> **Status:** written by WP12 ([#14](https://github.com/ALCops/rulebook-engine/issues/14)). Code: `tests/`, `tools/ci/Write-TestSummary.ps1`, the `test` job of `.github/workflows/ci.yml`. Everything below is derived from that code unless it says otherwise.

---

## Contents

1. [Conventions](#1-conventions)
2. [Fixtures](#2-fixtures)
3. [Helpers](#3-helpers)
4. [CI reporting and coverage](#4-ci-reporting-and-coverage)
5. [No network](#5-no-network)
6. [Accepted untested paths](#6-accepted-untested-paths)
7. [Later layers](#7-later-layers)

---

## 1. Conventions

- **Framework.** Pester 6 with the `Should-*` assertions ([D39](../adr/0039-test-framework-is-pester-6.md)): `Should-Be`, `Should-BeCollection`, `Should-MatchString`, `Should-Throw -ExceptionMessage`, `Should-Invoke` (not `Should -Invoke`). A filtered mock has no fall-through: a call that matches no filter runs the real command.
- **One suite per unit.** `tests/<Module>.Tests.ps1` per module (`Rulebook.Generate.Tests.ps1`), `tests/<Action>.Action.Tests.ps1` per action entry script, `tests/<Script>.Tests.ps1` per script under `scripts/` and `tools/ci/`, plus `Schemas.Tests.ps1`, `Fixtures.Tests.ps1`, `Docs.Tests.ps1` and `Smoke.Tests.ps1`. Inside a suite there is one `Describe` per function, or per check or topic where that reads better (the Validate suite has one `Describe` per check, `C1` to `C16`).
- **Module lifetime.** `BeforeAll` imports the modules with `Import-Module -Force` and dot-sources the helpers; `AfterAll` removes the modules, `Rulebook.Common` included, so the next suite starts clean.
- **Files.** A case works on a copy in `TestDrive`, in a folder of its own (`Get-TestFolder`: `Join-Path $TestDrive <12 hex>`), never on the fixtures themselves.
- **Action entry scripts** run in-process: `& $script:entry @Parameters 6>&1` with the console lines collected from the information stream, `GITHUB_OUTPUT`, `GITHUB_STEP_SUMMARY`, `GITHUB_REPOSITORY` and the token variables saved in `BeforeAll` and restored in `AfterAll`. The scripts re-import their modules with `-Force`, so a `Mock` does not reach them: the scripts have seams instead (`-PublishCommand`, `-TemplatePath` and `-InstalledTemplatePath`, `-PackageSource`, `-ApiUrl 'http://127.0.0.1:9'`). A seam scriptblock that needs a test value captures it with `.GetNewClosure()`.
- **Time and randomness.** Functions that stamp a date take `-Now`; branch names and justifications in the suites are fixed by it.
- **git.** Cases that need git are skipped without it (`-Skip:$gitMissing`, set in `BeforeDiscovery`).
- **Paths.** `Join-Path` with segments, `/` in every comparison of a repository-relative path: the suites run on Linux in CI and on Windows locally.
- **Names.** Test names hold no control characters (they would break the NUnit XML); a `-ForEach` case names its data in the title (`<Name> reports exactly <FindingsText>`).
- **Strict mode.** The modules run with `Set-StrictMode -Version 3.0`; a seam object that may lack a member is read through `PSObject.Properties['Name']`.

## 2. Fixtures

Everything under `tests/fixtures/`:

| Folder | Content | Used by |
|---|---|---|
| `repos/` | Organization rulebook repositories. `valid-minimal`, `stale-endpoints` and `update-org` are complete on disk (`$CompleteFixtures` in `RepoFixture.ps1`); every other folder is an overlay holding only the files it changes, laid over `valid-minimal` by `New-FixtureRepo`. | The module and action suites; `scan-org` by the `scan-action` job. |
| `templates/` | `v1` and `v2`, two versions of a mini template, with the exact difference list and the derivation of `repos/update-org` in its [README](../../tests/fixtures/templates/README.md). | The update suites, the `update-action` job. |
| `schemas/` | `<valid\|invalid>/<schema>/<reason>.json`, each invalid file a one-change mutation of a valid one. | `Schemas.Tests.ps1`. |
| `stub-analyzers/` | C# stubs of the compiler and the cop assemblies, compiled with the Roslyn of pwsh into fixture packages once per source hash into the temp folder ([README](../../tests/fixtures/stub-analyzers/README.md)). | The Extract and Scan module suites and the ScanDiagnostics action suite. |
| `matrix/tiny` | A six-id level content in the layout of `docs/rulebook/`. | The Template and Levels suites. |
| `ci/` | Trimmed captures of the NUnit and JaCoCo files Pester writes. | `Write-TestSummary.Tests.ps1`. |

`tests/Fixtures.Tests.ps1` is the one place that says what each repository fixture is and proves: its kind, the exact unique findings of `Test-Rulebook`, and the list `Get-RulebookEndpointChange` would regenerate (or the error the generator throws). It also checks that the template fixtures validate and stay in step with the engine, that every folder under `repos/` has a row in that table and every row a folder, and that every fixture folder is used by a suite, a helper or `ci.yml`.

## 3. Helpers

The suites dot-source these in `BeforeAll`:

| Helper | Main functions |
|---|---|
| `tests/Helpers/RepoFixture.ps1` | `New-FixtureRepo` (a fixture copied into a folder, an overlay over `valid-minimal`), `Copy-FixtureTree`, `Write-FixtureText`, `Edit-FixtureJson` (edit a JSON file with a scriptblock), `New-FixtureGitRepo` (init, add, commit; returns the sha), `New-BareFixtureRepo`, `Add-RejectPushHook` (a pre-receive hook that refuses `main`, or every push with `-All`: the stand-in for branch protection), `Copy-FixtureTemplate`, `New-SyntheticRulebook` (the 650-id performance rulebook). |
| `tests/Helpers/StubFeed.ps1` | `New-StubFeed` (a NuGet flat container of stub packages), `Expand-StubPackage`, `Get-FaultyToolsFolder`; builds the stubs in a child pwsh and caches them by source hash. |
| `tests/Helpers/MarkdownCheck.ps1` | The checks of `Docs.Tests.ps1`: relative links and anchors (`Test-MarkdownLink`), fenced JSON (`Test-MarkdownJson`), the page shape of the user documentation (`Test-MarkdownShape`, `Test-MarkdownTroubleshooting`). |

## 4. CI reporting and coverage

The `test` job of `.github/workflows/ci.yml` runs PSScriptAnalyzer, the matrix checks V1 to V14 and then Pester from `tests/` with `Normal` verbosity, NUnit results in `testResults.xml` and JaCoCo line coverage of `modules/`, `actions/` and `scripts/` in `coverage.xml` (profiler tracer, `UseBreakpoints` false). Coverage is a report, not a gate ([D51](../adr/0051-test-coverage-is-a-report-not-a-gate.md)): `CoveragePercentTarget` is 0, so Pester's console line ends in `/ 0%` and is always met. `tools/rulebook/` is not measured; `Test-Rulebook.ps1` and the template drift test prove it.

The `Test summary` step runs `tools/ci/Write-TestSummary.ps1` with `if: always()`:

- **Pester table:** one row per test file (Tests, Failed, Skipped, Seconds) under a totals line. Ignored and Inconclusive tests count as skipped; a file that failed outside its tests (a parse error, a failed file-level setup) counts as one failed test.
- **Coverage table:** one row per source file (Covered, Missed, Percent of lines, rounded down so only a fully covered file shows 100.0) in ordinal order, and a totals row.
- **Annotations:** one `::error file=<suite path>,title=Pester::<test name>: <first message line>` per failed test; they show on the run page and in the pull request's Files changed tab.

A missing or unreadable results or coverage file is one line in its section; the script never fails the step (Pester's `Run.Exit` already failed the job). The `testResults` artifact holds `testResults.xml` and `coverage.xml`, also after a failure. Read the tables on the run's Summary tab: `gh` does not show the job summary. The local command (the same configuration into a scratch folder, then the summary on the console) is in [CONTRIBUTING.md](../../CONTRIBUTING.md) section 3.

## 5. No network

No test talks to a server outside the runner. That is a rule kept by review, not a property a run verifies (a decision of the WP12 planning interview). The seams that make it possible:

- **GitHub:** `Invoke-GitHubApi` of `Rulebook.GitHub` is the one mock point of every REST call the other modules make, the template zipball included (`Mock Invoke-GitHubApi -ModuleName Rulebook.GitHub`); the GitHub suite tests `Invoke-GitHubApi` itself and the GitHub App token exchange with `Invoke-WebRequest` mocked.
- **NuGet:** `Invoke-NuGetRequest` of `Rulebook.NuGet` is mocked, or `-Source` points at a folder (a stub feed from `New-StubFeed`, built offline).
- **Publish and the init script:** the reachability and preflight requests of `Rulebook.Publish` and the downloads of `scripts/Get-RulebookSkeletons.ps1` are mocked at `Invoke-WebRequest`.
- **Actions:** four of the five action suites pass `-ApiUrl 'http://127.0.0.1:9'` (a port that refuses every connection), so an unmocked call fails at once; the ScanDiagnostics suite stops before any request, at the token guard, an earlier outcome or the `-PublishCommand` seam. The update reads `-TemplatePath` folders instead of downloading.
- **git:** real git runs only against repositories in `TestDrive`: bare origins from `New-BareFixtureRepo`, with `Add-RejectPushHook` standing in for branch protection. The token reaches git only as an environment header, and the GitHub suite checks that it never lands in the git config of a clone.

Real packages and real deploys run only in CI jobs and live runs: `scan-action` scans the real packages on nuget.org, `publish-action` stages without deploying and serves the site on `127.0.0.1`, and the live runs of the mechanics pages ([update](update-mechanics.md), [scan](scan-mechanics.md), [change](change-mechanics.md)) exercised GitHub itself.

## 6. Accepted untested paths

Every line the coverage report lists as missed, with the reason no test reaches it. The list is the coverage pass of WP12: the paths worth a test got one (the exported functions no suite named, the in-process `Get-AnalyzerDescriptor` call, the publish results and token failures of the action scripts, the reader errors and the files that are not JSON), one function nobody called was removed (`ConvertFrom-JsonFile` of `Rulebook.Generate`), and what is left is defensive (a fault after an earlier check passed), platform or runner-dependent, interactive, or a live-run path. Spin-offs for the gaps worth closing later: sharing the effective-diff renderer of `Validate.ps1` with `Get-EffectiveDiffBlock`, and a stub scenario for the scan body sections.

The line numbers are those of the WP12 testing-docs pull request on a local Windows run (171 of 5720 lines, 97.0 percent). The Linux CI report can differ by a few platform-dependent lines; when this table and the job summary of a later run disagree, the job summary is the current picture and this table is the reasoning.

| File | Lines | Missed | Reason |
|---|---|---|---|
| `actions/ChangeRule/ChangeRule.ps1` | 41 | 1 | A param-block default (`GITHUB_API_URL`); the profiler tracer does not record default expressions. |
| `actions/ChangeRule/ChangeRule.ps1` | 127-128 | 2 | Defensive: the settings schema check of the plan rejects the name first (the ChangeRule suite proves that order). |
| `actions/ChangeRule/ChangeRule.ps1` | 202 | 1 | The job summary file cannot be written (a runner fault); not reproducible in-process. |
| `actions/CheckForUpdates/CheckForUpdates.ps1` | 40 | 1 | A param-block default (`GITHUB_API_URL`); the profiler tracer does not record default expressions. |
| `actions/CheckForUpdates/CheckForUpdates.ps1` | 246 | 1 | The job summary file cannot be written (a runner fault); not reproducible in-process. |
| `actions/Publish/Publish.ps1` | 32 | 1 | A param-block default (`GITHUB_API_URL`); the profiler tracer does not record default expressions. |
| `actions/Publish/Publish.ps1` | 95-97 | 3 | Pages preflight of a real deploy (`-Deploy`); the module function is tested, the action branch runs in the live publish runs only. |
| `actions/Publish/Publish.ps1` | 159-162 | 4 | Reachability reasons of a deployed site; `Test-PublishedEndpoint` is tested in the Publish suite, the action wording only in live runs. |
| `actions/ScanDiagnostics/ScanDiagnostics.ps1` | 36 | 1 | A param-block default (`GITHUB_API_URL`); the profiler tracer does not record default expressions. |
| `actions/ScanDiagnostics/ScanDiagnostics.ps1` | 218 | 1 | The job summary file cannot be written (a runner fault); not reproducible in-process. |
| `actions/Validate/Validate.ps1` | 39 | 1 | A param-block default (`GITHUB_API_URL`); the profiler tracer does not record default expressions. |
| `actions/Validate/Validate.ps1` | 78, 123 | 2 | Verbose note when an optional file is unreadable; the check goes on without it. |
| `actions/Validate/Validate.ps1` | 114, 136-142 | 8 | Event-derived refs and their fetches (`pull_request` base, `push` before-sha) need the GitHub checkout and its remote; the `validate-action` job runs the pull request path. |
| `actions/Validate/Validate.ps1` | 133 | 1 | git missing from the path; every runner and the suites have git. |
| `actions/Validate/Validate.ps1` | 151 | 1 | The effective diff throws after the ref resolved (an unreadable rulebook at that ref); defensive. |
| `actions/Validate/Validate.ps1` | 193 | 1 | Listing note in the action's own copy of the effective-diff renderer; `Get-EffectiveDiffBlock` has the tested copy (spin-off: share it). |
| `modules/Rulebook.Catalog.psm1` | 128 | 1 | Invalid JSON in a file the schema or Validate check reports first; the reader's own message is defensive. |
| `modules/Rulebook.Catalog.psm1` | 226 | 1 | Writer branch for an empty array; no shipped or fixture file has one. |
| `modules/Rulebook.Edit.psm1` | 119-122 | 4 | JSON value kinds in a change set the dashboard form will send (WP15); the ChangeRule inputs are strings. |
| `modules/Rulebook.Edit.psm1` | 160, 166 | 2 | Describe texts for an unchanged entry and a replaced entry with another action; the rendered cases cover the other branches. |
| `modules/Rulebook.Edit.psm1` | 241 | 1 | overrides.json that is not JSON at change time; Validate reports it first (C10) and the change plan stops on validation. |
| `modules/Rulebook.Edit.psm1` | 583-585, 600-602, 650-652, 702-704 | 12 | The rulebook cannot be read at plan time after Validate passed; defensive. |
| `modules/Rulebook.Edit.psm1` | 723 | 1 | Regeneration throws after the plan validated; defensive. |
| `modules/Rulebook.Edit.psm1` | 826-829 | 4 | A change pull request body over the GitHub limit; one change cannot produce one. |
| `modules/Rulebook.Edit.psm1` | 876 | 1 | Rendering of a diff note (the effective diff failed after the push, a path listed as defensive in this table). |
| `modules/Rulebook.Edit.psm1` | 951 | 1 | A planned deletion whose file is already gone in the clone (someone deleted it in between). |
| `modules/Rulebook.Edit.psm1` | 969-970 | 2 | Nothing to commit after the plan saw changes (the base moved to the same content in between). |
| `modules/Rulebook.Edit.psm1` | 975 | 1 | The effective diff fails in the clone after the push; the result carries a note instead. |
| `modules/Rulebook.Extract.psm1` | 65-67 | 3 | pwsh not in `$PSHOME` (a .NET global tool install); the suites run the pwsh of `$PSHOME`. |
| `modules/Rulebook.Extract.psm1` | 122, 129 | 2 | Defensive fallbacks for an assembly or package id outside the two known packages. |
| `modules/Rulebook.Extract.psm1` | 219, 265, 271-274, 284 | 7 | An assembly that does not load or a type that cannot be instantiated, in the in-process call; the child-process cases (BrokenCop, MissingDependency) prove the same failures, but the coverage tracer does not see the child. |
| `modules/Rulebook.Extract.psm1` | 401 | 1 | The child wrote a result file that is not JSON; not reproducible with the stubs. |
| `modules/Rulebook.Generate.psm1` | 1008 | 1 | A change declined at a `-Confirm` prompt; interactive only. |
| `modules/Rulebook.GitHub.psm1` | 76-78 | 3 | An API error answer without a JSON message; every mocked error has one. |
| `modules/Rulebook.GitHub.psm1` | 242 | 1 | A GitHub App private key that is JSON but not PEM; the token tests use a generated key. |
| `modules/Rulebook.GitHub.psm1` | 419 | 1 | A zipball without the single top folder GitHub always writes. |
| `modules/Rulebook.GitHub.psm1` | 546 | 1 | Labels not added after the pull request was created (HTTP error on the labels call); a warning only. |
| `modules/Rulebook.GitHub.psm1` | 590 | 1 | The tree listing of the API throws; the caller then falls back to the root commit walk. |
| `modules/Rulebook.Levels.psm1` | 144, 446 | 2 | Level page of a level based on an unpublished level, or of a root level with no entries; no shipped or fixture level has one. |
| `modules/Rulebook.Levels.psm1` | 252-253 | 2 | Writing the temp file or the move fails (disk full, permissions); cleanup and rethrow. |
| `modules/Rulebook.NuGet.psm1` | 24-25 | 2 | `Invoke-NuGetRequest -OutFile`, the real package download; the suites read packages from stub folders. |
| `modules/Rulebook.Publish.psm1` | 89 | 1 | A response without the requested header; the mocked responses always send it. |
| `modules/Rulebook.Publish.psm1` | 512-513 | 2 | `Invoke-WebRequest` returned nothing (a network fault); the suites mock a response. |
| `modules/Rulebook.Publish.psm1` | 525 | 1 | An HTTP status other than 200, 30x or 404 from the published site. |
| `modules/Rulebook.Scan.psm1` | 38 | 1 | Scan package label of an unknown package id. |
| `modules/Rulebook.Scan.psm1` | 183, 221 | 2 | An input the plan cannot read after the settings passed (C5 or later); the Validate suite covers the same inputs. |
| `modules/Rulebook.Scan.psm1` | 206-207 | 2 | A NuGet index without a stable version; both real packages have one. |
| `modules/Rulebook.Scan.psm1` | 324 | 1 | Regeneration throws after the plan validated; defensive. |
| `modules/Rulebook.Scan.psm1` | 453-454, 461-466, 516-520, 561-565, 567, 624-626 | 22 | Scan body sections for newly advertised ids, released quarantine entries, validation warnings and more than the row limit of new ids; the stub packages produce none of these (spin-off: a stub variant for them). |
| `modules/Rulebook.Scan.psm1` | 542 | 1 | Rendering of a plan with no file changes; no suite renders the sections of such a plan (the runs end as nothing-new or no-op first). |
| `modules/Rulebook.Scan.psm1` | 733-734 | 2 | A rulebook nested below the repository root at publish time; the scan always runs at the root. |
| `modules/Rulebook.Scan.psm1` | 748 | 1 | A planned deletion whose file is already gone in the clone (someone deleted it in between). |
| `modules/Rulebook.Scan.psm1` | 779-781 | 3 | Closing a stale scan pull request fails (API error); the failure path of the living pull request. |
| `modules/Rulebook.Scan.psm1` | 792 | 1 | The effective diff fails in the clone after the push; the result carries a note instead. |
| `modules/Rulebook.Template.psm1` | 41, 116, 121 | 3 | Malformed `docs/rulebook/` input; `Test-Rulebook.ps1` (V1 to V14) rejects it before the template build. |
| `modules/Rulebook.Template.psm1` | 68 | 1 | Writer branch for an empty array; no shipped or fixture file has one. |
| `modules/Rulebook.Update.psm1` | 171 | 1 | A template folder whose workflows sit one or two levels down (the zipball layout); the suites pass the folder itself. |
| `modules/Rulebook.Update.psm1` | 203 | 1 | `templateSha` not on a line of its own; the settings writer always puts it on its own line. |
| `modules/Rulebook.Update.psm1` | 258 | 1 | A one-line YAML key at the path the workflow edit looks for; the shipped workflows use a block. |
| `modules/Rulebook.Update.psm1` | 429 | 1 | The REST commit list returns no commits; a repository always has one. |
| `modules/Rulebook.Update.psm1` | 658 | 1 | `.github/ISSUE_TEMPLATE/` files: the template ships none yet (the dashboard, WP14). |
| `modules/Rulebook.Update.psm1` | 922-923, 985-986 | 4 | An input the plan cannot read after the settings passed (C5 or later); the Validate suite covers the same inputs. |
| `modules/Rulebook.Update.psm1` | 1000 | 1 | An `unusedRulebookFiles` entry for a file present but not managed by the template; no fixture has one. |
| `modules/Rulebook.Update.psm1` | 1151 | 1 | Rendering of a plan with no file changes; no suite renders the sections of such a plan (the runs end as nothing-new or no-op first). |
| `modules/Rulebook.Update.psm1` | 1257 | 1 | Rendering of a diff note (the effective diff failed after the push, a path listed as defensive in this table). |
| `modules/Rulebook.Update.psm1` | 1325 | 1 | Fallback text for an unknown result kind. |
| `modules/Rulebook.Update.psm1` | 1436 | 1 | A planned deletion whose file is already gone in the clone (someone deleted it in between). |
| `modules/Rulebook.Update.psm1` | 1446 | 1 | Nothing to commit after the plan saw changes (the base moved to the same content in between). |
| `modules/Rulebook.Update.psm1` | 1454 | 1 | The effective diff fails in the clone after the push; the result carries a note instead. |
| `modules/Rulebook.Validate.psm1` | 88 | 1 | Schema check on a file whose text was not read first; every caller reads the text first. |
| `modules/Rulebook.Validate.psm1` | 269-270 | 2 | `Read-Catalog` throws after the catalog schema passed; defensive. |
| `modules/Rulebook.Validate.psm1` | 422-423 | 2 | C4 hint for `Default` in overrides.json; the overrides schema rejects it first (C10). |
| `modules/Rulebook.Validate.psm1` | 703 | 1 | The regeneration check throws after its prerequisites passed; defensive. |
| `scripts/Get-RulebookSkeletons.ps1` | 83-84, 92 | 3 | A download that fails without an error record, or answers with a stream; the suites mock text responses. |
| `scripts/Get-RulebookSkeletons.ps1` | 113 | 1 | An address that is not an absolute URL; the script builds every address from `-BaseUrl`. |
| `scripts/Get-RulebookSkeletons.ps1` | 230, 236 | 2 | A served skeleton that is not JSON or not a Rulebook skeleton; the publish job serves only generated skeletons. |
| `scripts/Get-RulebookSkeletons.ps1` | 267 | 1 | The output folder cannot be created (permissions). |
| `scripts/Get-RulebookSkeletons.ps1` | 283-287 | 5 | Writing the skeletons fails halfway (disk full, permissions); cleanup and the message of what was written. |
| `scripts/Get-RulebookSkeletons.ps1` | 298 | 1 | Hint for a stage other than default, ci and vnext; the published fixtures have only those. |
| `scripts/New-RulebookOffLevel.ps1` | 114 | 1 | Invalid JSON in a file the schema or Validate check reports first; the reader's own message is defensive. |
| `scripts/New-RulebookOffLevel.ps1` | 138 | 1 | Writer branch for an empty array; no shipped or fixture file has one. |
| `scripts/New-RulebookOffLevel.ps1` | 194-195 | 2 | Writing the temp file or the move fails (disk full, permissions); cleanup and rethrow. |

## 7. Later layers

D12 keeps v1 at Pester unit tests. Three heavier layers were considered and are documented here, not built.

### 7.1 End-to-end compile

Compile a fixture AL project against the published endpoints with the real compiler, so that a ruleset the compiler rejects fails CI. [Spike (c)](spikes/c-alc-on-ubuntu.md) has the recipe and the observed results; it is not repeated here. The organization documentation in ALCops/rulebook (`docs/azure-devops.md`) carries the plain-`alc` version for pipelines. In short:

- Install the stable `Microsoft.Dynamics.BusinessCentral.Development.Tools` as a global dotnet tool, pinned.
- Download `System.app` from the MSSymbols flat2 feed (the index lists the newest version first).
- Take the analyzers from the same TFM folder as the `alc.dll` the shim loads, resolved at run time.
- AL1003 (an analyzer instance that cannot be created, for example analyzers taken from another TFM folder than the running `alc.dll`) leaves the exit code at 0 and drops the rules of that analyzer: grep the compile log for it. AL1022, AL1033 and AL0767 end the compile with exit 1 on their own.
- Re-check the recipe after `ubuntu-latest` moves to Ubuntu 26 on 2026-10-19.

Spin-off: [#92](https://github.com/ALCops/rulebook-engine/issues/92), post-v1.

### 7.2 Endpoint snapshots

Comparing generated endpoints with committed snapshots adds nothing: the committed `rulesets/` of every rulebook repository are that snapshot, C12 fails when they drift from their inputs, and the effective diff of the Validate action shows every change of an effective action in the pull request. No issue.

### 7.3 Template smoke test

Create a repository from the template (`gh repo create --template`), run its four workflows, assert their results, and delete the repository. It needs a token that may create and delete repositories, and the ALCops organization policy does not allow GitHub Actions to create or approve pull requests, so the test would run under a personal account, as the live runs of WP07 to WP11 did.

Spin-off: [#93](https://github.com/ALCops/rulebook-engine/issues/93), post-v1.
