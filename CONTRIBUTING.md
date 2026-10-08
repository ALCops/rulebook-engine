# Contributing to the Rulebook engine

How the engine repository is laid out, how to run its checks, and what a pull request needs. Status, size and order of the work live on the [Rulebook v1 project board](https://github.com/orgs/ALCops/projects/1) only; the [definition of done](README.md#definition-of-done) is in the README.

---

## Contents

1. [Repository layout](#1-repository-layout)
2. [Conventions](#2-conventions)
3. [Running the checks locally](#3-running-the-checks-locally)
4. [CI](#4-ci)
5. [Branches and releases](#5-branches-and-releases)
6. [Repository settings](#6-repository-settings)
7. [Pull requests](#7-pull-requests)

---

## 1. Repository layout

What exists today, and the work package that adds the rest. A folder is created by the work package that fills it; there are no empty placeholder folders.

| Path | Content | Added by |
|---|---|---|
| `.github/workflows/ci.yml` | PSScriptAnalyzer, the matrix checks V1 to V14 and Pester on every pull request and every push to `main` and to a release branch (`v*`); the Validate action on two fixtures and on `template/`; the Publish action on `template/` without deploying, and the init script against the staged site served over HTTP; the CheckForUpdates action on `tests/fixtures/repos/update-org` against the local templates; the ScanDiagnostics action in dry runs against nuget.org; the ChangeRule action on a copy of `tests/fixtures/repos/valid-minimal` without a token. | WP00, WP03, WP04, WP05, WP06, WP07, WP08, WP09 |
| `.github/workflows/` (deploy) | Copies `template/` into `ALCops/rulebook` and pins action references to `@v1`. | WP13 ([#15](https://github.com/ALCops/rulebook-engine/issues/15)) |
| `.github/release.yml` | Maps pull request labels to release-note sections ([D38](docs/adr/0038-release-notes-are-generated-from-pull-request-labels.md)). | WP00 |
| `.github/dependabot.yml` | Weekly, grouped updates of the GitHub Actions used by the workflows. | WP00 |
| `.github/ISSUE_TEMPLATE/` | Issue forms: work package, task or spin-off. | written |
| `PSScriptAnalyzerSettings.psd1` | Analyzer settings: errors and warnings, default rules, justified exclusions only. | WP00 |
| `schemas/` | JSON schemas for every file in an organization rulebook repository, draft 2020-12, no `$id`; names and URLs in [docs/reference/naming.md](docs/reference/naming.md). | WP02 ([#4](https://github.com/ALCops/rulebook-engine/issues/4)) |
| `tests/` | `Smoke.Tests.ps1`, `Schemas.Tests.ps1`, `Rulebook.Generate.Tests.ps1`, `Rulebook.Validate.Tests.ps1`, `Validate.Action.Tests.ps1`, `Rulebook.Template.Tests.ps1`, `Rulebook.Publish.Tests.ps1`, `Publish.Action.Tests.ps1`, `Get-RulebookSkeletons.Tests.ps1`, `Rulebook.GitHub.Tests.ps1`, `Rulebook.Update.Tests.ps1`, `CheckForUpdates.Action.Tests.ps1`, `Rulebook.NuGet.Tests.ps1`, `Rulebook.Extract.Tests.ps1`, `Rulebook.Catalog.Tests.ps1`, `Rulebook.Quarantine.Tests.ps1`, `Rulebook.Scan.Tests.ps1`, `ScanDiagnostics.Action.Tests.ps1`, `Rulebook.Action.Tests.ps1`, `Rulebook.Edit.Tests.ps1` and `ChangeRule.Action.Tests.ps1` now; later one suite per module and action, with fixtures under `tests/fixtures/`. | WP00, WP02, WP03, WP04, WP05, WP06, WP07, WP08, WP09; WP12 ([#14](https://github.com/ALCops/rulebook-engine/issues/14)) and every module work package |
| `tests/fixtures/schemas/` | One file per case: `<valid\|invalid>/<schema-basename>/<reason>.json`, each invalid file a one-change mutation of a valid one. | WP02 |
| `tests/fixtures/repos/` | Organization rulebook repositories for the module suites. `valid-minimal` (30-id catalog, four levels, three stages), `stale-endpoints` and `update-org` (WP07) are complete on disk, their `rulesets/` written by `Update-RulebookEndpoints`; every other folder is an overlay holding only the files it changes, copied over `valid-minimal` by `New-FixtureRepo`. | WP03 |
| `tests/fixtures/templates/` | `v1` and `v2`: two versions of a mini template for the update suites, with the exact difference list and the derivation of `repos/update-org` in its README. | WP07 |
| `tests/fixtures/stub-analyzers/` | C# stubs of the compiler and the twelve cop assemblies and `Build-StubPackage.ps1`, which compiles them with the Roslyn of pwsh into fixture nupkgs (variants tools 18.0.43.1464 and 30.0.42.60748-beta, ALCops 1.3.1, 1.4.0-beta.1 and 1.4.0) for the scan suites; `tests/Helpers/StubFeed.ps1` builds them once per source hash. | WP08 |
| `tests/fixtures/matrix/` | `tiny`: a six-id level content in the layout of `docs/rulebook/` (inventory, matrix, resolved cells, levels, stages, twins) for the unit cases of the Template suite. | WP04 |
| `tests/Helpers/` | Helpers the suites dot-source in `BeforeAll`: `RepoFixture.ps1` copies a fixture into `TestDrive`, edits its JSON, creates git repositories, bare origins with a push-refusing hook and the synthetic performance rulebook; `StubFeed.ps1` builds NuGet flat containers of the stub analyzer packages. | WP03, WP08 |
| `modules/` | PowerShell modules shared by the actions, each a `.psm1` with a `.psd1` manifest: `Rulebook.Generate`, `Rulebook.Validate`, `Rulebook.Template`, `Rulebook.Publish`, `Rulebook.GitHub`, `Rulebook.Update`, `Rulebook.NuGet`, `Rulebook.Extract`, `Rulebook.Catalog`, `Rulebook.Quarantine`, `Rulebook.Scan`, `Rulebook.Action` and `Rulebook.Edit` (written). | WP03 to WP09 |
| `actions/` | Composite actions, one folder each with `action.yaml` and its entry script. | WP03 to WP09 |
| `actions/Validate/` | `action.yaml` and `Validate.ps1`: checks C1 to C16, annotations, the job summary with the effective diff ([ARCHITECTURE.md](docs/ARCHITECTURE.md) section 5.5). | WP03 |
| `actions/Publish/` | `action.yaml` and `Publish.ps1`: stage the endpoints, the rendered skeletons and `index.html`, the Pages preflight, deploy to GitHub Pages, the reachability check ([ARCHITECTURE.md](docs/ARCHITECTURE.md) section 7.2, [docs/reference/publish-targets.md](docs/reference/publish-targets.md)). | WP05 |
| `actions/CheckForUpdates/` | `action.yaml` and `CheckForUpdates.ps1`: the template update check (`update` other than `'Y'`) and the update pull request or direct commit (`update: 'Y'`), with the token from `GHTOKENWORKFLOW` ([docs/reference/update-mechanics.md](docs/reference/update-mechanics.md)). | WP07 |
| `actions/ScanDiagnostics/` | `action.yaml` and `ScanDiagnostics.ps1`: the diagnostic scan, its living pull request on `scan-diagnostics/<branch>` or a direct commit, and the dry run ([docs/reference/scan-mechanics.md](docs/reference/scan-mechanics.md)). | WP08 |
| `actions/ChangeRule/` | `action.yaml` and `ChangeRule.ps1`: set or remove one override entry for a level and stage selection, regenerate and validate, and open the pull request on `change-rule/<ruleId>/<yyMMddHHmmss>` or push a direct commit ([docs/reference/change-mechanics.md](docs/reference/change-mechanics.md)). | WP09 |
| `scripts/` | User-facing scripts an AL project downloads and runs, self-contained (no engine module, PowerShell 7): `Get-RulebookSkeletons.ps1` downloads the published skeletons of a level into `.rulebook/`, one per stage ([ARCHITECTURE.md](docs/ARCHITECTURE.md) section 6.3). | WP06 ([#8](https://github.com/ALCops/rulebook-engine/issues/8)) |
| `template/` | Source of the template content deployed to `ALCops/rulebook`, 44 files: 12 hand-written files (settings, `Validate.yaml`, `Publish.yaml`, `UpdateRulebookSystemFiles.yaml`, `ScanDiagnostics.yaml`, `ChangeRule.yaml`, `README.md`, `skeletons/README.md`, `overrides.json`, three quarantine files) and 32 files generated by `tools/rulebook/Build-Template.ps1` (`base/`, `stages/`, `catalog/`, `skeletons/`, `rulesets/`), see [docs/reference/template-content.md](docs/reference/template-content.md). | WP03, WP04, WP05, WP06, WP07, WP08, WP09, WP13 |
| `docs/`, `tools/rulebook/` | Architecture, decision records, level content and the scripts that build it and the template content (`Build-Template.ps1`, WP04). | written |

## 2. Conventions

- **Line endings and encoding:** UTF-8, LF, a final newline, no trailing whitespace (except in Markdown). `.gitattributes` enforces LF in the index; `.editorconfig` tells the editor.
- **Indentation:** 4 spaces; 2 spaces in `.yml`, `.yaml` and `.json`.
- **Workflow files:** lowercase kebab-case with the `.yml` extension (`ci.yml`), as in the other ALCops repositories. Files under `template/` follow AL-Go naming instead, because an organization repository sits next to AL-Go: PascalCase with the `.yaml` extension (`template/.github/workflows/Validate.yaml`).
- **Check names:** a job has an id and no `name:`, so the check run is named after the id (`test`). The ruleset requires checks by that name; renaming a job id means updating the ruleset in the same pull request.
- **PowerShell:** PowerShell 7.4 or later, runs on Linux, no Windows-only dependency ([D9](docs/adr/0009-tooling-powershell-7-and-pester-on-ubuntu-runners.md)). Tests are Pester 6 with `Should-*` assertions ([D39](docs/adr/0039-test-framework-is-pester-6.md)).
- **Analyzer exclusions:** a rule is excluded in `PSScriptAnalyzerSettings.psd1` only with its reason on the same line, and a non-trivial finding left unfixed gets a spin-off issue.

## 3. Running the checks locally

Requirements: PowerShell 7.4 or later, Pester 6, PSScriptAnalyzer.

```powershell
Install-Module Pester -MinimumVersion 6.0 -Scope CurrentUser
Install-Module PSScriptAnalyzer -Scope CurrentUser
Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
Invoke-Pester -Path ./tests -Output Detailed
```

The analyzer must print nothing. Outside GitHub Actions the Linux smoke case is skipped (it runs only when `$env:GITHUB_ACTIONS` is set). The effective-diff tests of the Generate suite and the diff tests of the Validate action suite need `git` on the path and are skipped without it.

When a change touches `tools/rulebook/` or `docs/rulebook/`, also run `pwsh ./tools/rulebook/Test-Rulebook.ps1` (checks V1 to V14 of [docs/rulebook/verification.md](docs/rulebook/verification.md); CI runs it too). The three scripts in `tools/rulebook/` import `modules/Rulebook.Generate.psd1` for the diagnostic sort key (`Get-DiagnosticSortKey`) and build paths with `Join-Path` segments, never a Windows separator. Regenerating the level content with `Extract-Inventory.ps1` needs the sibling clones `../Analyzers` and `../nav-sdk-source`.

After any change to `docs/rulebook/`, `modules/Rulebook.Template.psm1` or `template/.github/Rulebook-Settings.json`, run `pwsh ./tools/rulebook/Build-Template.ps1` and commit `template/` with the change; the drift test in `tests/Rulebook.Template.Tests.ps1` fails otherwise. `Build-Template.ps1 -WhatIf` lists what is out of date without writing.

## 4. CI

`.github/workflows/ci.yml` has six jobs on `ubuntu-latest`, `test`, `validate-action`, `publish-action`, `update-action` and `changerule-action` with a 15-minute timeout and `scan-action` with 20 minutes. All six run on every pull request and on every push to `main` or a release branch (`v*`). `test` installs PSScriptAnalyzer and Pester 6, runs the analyzer over the whole repository and fails on any finding (after printing the findings table), runs the matrix checks V1 to V14 (`tools/rulebook/Test-Rulebook.ps1`, which exits 1 on a failed check), runs Pester from `tests/`, and uploads `testResults.xml` (NUnit) as the `testResults` artifact, also when a step failed. The workflow token is read-only, and a new push to a pull request cancels its running job; pushes to `main` and release branches always finish.

`validate-action` runs the composite action from the checkout (`uses: ./actions/Validate`) the way an organization workflow does: it must pass on `tests/fixtures/repos/valid-minimal`, pass on `template/` with `failOnWarning` (no warning either), and fail on `tests/fixtures/repos/stale-endpoints`, and the job fails otherwise. Its three steps pass `checkForUpdates: 'false'`, so the fixtures are not compared with `ALCops/rulebook`. On a pull request its `template/` step shows the effective diff of the template endpoints against the base branch. Its step on `stale-endpoints` prints one expected C12 error annotation.

`publish-action` runs `uses: ./actions/Publish` on `template/` with `baseUrl: https://example.github.io/rulebook` and `deploy: 'false'` (staging only: no Pages preflight, no deploy, no reachability check), asserts the 26 staged files (12 endpoints, 12 skeletons, `rulebook.json` with its base URL, repository, level and stage slugs, and `index.html` with its "Set up an AL project" section), the rendered URL in `skeletons/strict.ci.ruleset.json` and that `skeletons/README.md` is not staged, then serves the staging folder with `python3 -m http.server` on `127.0.0.1`, runs `scripts/Get-RulebookSkeletons.ps1 -Level strict` against it over real HTTP (with three expected warnings, because the site was staged for another base URL) and compares the SHA-256 of the three written files with the staged skeletons and with `curl` downloads of the same URLs (the server is stopped in an `if: always()` step), uploads the staging folder as the `publish-staging` artifact, and requires the action to fail on `template/` without the `baseUrl` input with its `failure` output `baseUrl-empty`, so a crash or another error does not pass (the step prints one expected error annotation with the proposed URL). A real deploy needs a Pages site and runs in an organization repository; the live run is in [docs/reference/publish-targets.md](docs/reference/publish-targets.md) section 6.

`update-action` runs `uses: ./actions/CheckForUpdates` in check mode on `tests/fixtures/repos/update-org` with the local templates of `tests/fixtures/templates/` (no download, no token): against `v1` it must report `updatesAvailable` `false`, against `v2` `true`, and in update mode without a token it must fail with the `failure` output `token`; a guard step fails the job on any other outcome (it prints one expected error annotation, the missing secret).

`changerule-action` runs `uses: ./actions/ChangeRule` on a copy of `tests/fixtures/repos/valid-minimal` in `RUNNER_TEMP` (no token, nothing pushed): `AA0001` `None` for every level and stage must fail with the `failure` output `token` (the change is valid and changes nine endpoints, so the token guard, which runs after the local plan, fires); `AA0072` `Info` for every level and stage without a justification must succeed with `noop` `true` (the fixture has exactly that entry, and an empty justification keeps its text); `LC9999` must fail with `validation`. A guard step fails the job on any other outcome (the run prints two expected error annotations).

`scan-action` runs `uses: ./actions/ScanDiagnostics` with `dryRun: 'true'` against the real packages on nuget.org (no token, nothing pushed; the unit suites use stub packages): on `template/` without a policy it must fail with the `failure` output `policy` (one expected error annotation); on a copy of `template/` with a policy it must scan both stable versions, give at least 600 catalog entries a package, write a valid `catalog/scan-state.json` and leave a candidate without validation errors, and it prints the new ids, the refreshed titles and docs links and the ids without a package; on `tests/fixtures/repos/scan-org` (30 catalog ids) it must quarantine at least 500 new ids in `default` and `ci` and leave `quarantine.vnext.json` alone; a second dry run on the scanned template must give `nothing-new` in under 60 s. nuget.org moves, so the checks are lower bounds.

The ruleset requires the checks of section 6.

The module versions are pinned in `ci.yml` (PSScriptAnalyzer 1.25.0, Pester 6.2.0) and bumped by hand, because Dependabot does not cover the PowerShell Gallery; it only updates the action tags.

## 5. Branches and releases

`main` is the development branch. Organization repositories never run `main`: the deploy workflow pins the template's action references to a release branch, the first being `v1` (O3, [#27](https://github.com/ALCops/rulebook-engine/issues/27); WP13, [#15](https://github.com/ALCops/rulebook-engine/issues/15)). Fixes reach `v1` without touching any organization repository.

Release notes are not written by hand. GitHub generates them from the merged pull requests, grouped by label through `.github/release.yml`, and the deploy step writes the same text into the template's `RELEASENOTES.copy.md` ([D38](docs/adr/0038-release-notes-are-generated-from-pull-request-labels.md)).

## 6. Repository settings

Applied on 2026-10-03 by the WP00 pull request ([#2](https://github.com/ALCops/rulebook-engine/issues/2)) with the commands below. Changing a setting means changing this section in the same pull request.

| Setting | Value | Command |
|---|---|---|
| Ruleset `protect-main` on the default branch | Pull request required, 0 approvals, deletion and force-push blocked, checks `test`, `validate-action`, `publish-action`, `update-action`, `scan-action` and `changerule-action` from GitHub Actions required, no bypass actors. `validate-action` was added on 2026-10-06 with the WP03 pull request ([#46](https://github.com/ALCops/rulebook-engine/pull/46)) through a PUT of the same JSON. `publish-action` was added the same way on 2026-10-06, after the first CI run of the WP05 pull request ([#59](https://github.com/ALCops/rulebook-engine/pull/59)) had reported the check; the PUT kept the other rules as the GET returned them. `update-action` is added the same way after the first CI run of the WP07 pull request ([#9](https://github.com/ALCops/rulebook-engine/issues/9)) has reported the check, and `scan-action` after the first CI run of the WP08 pull request ([#10](https://github.com/ALCops/rulebook-engine/issues/10)), `changerule-action` after the first CI run of the WP09 pull request ([#11](https://github.com/ALCops/rulebook-engine/issues/11)). | `gh api --method POST ... rulesets --input ruleset-engine.json`, later `gh api --method PUT ... rulesets/24420852 --input ruleset-engine.json` |
| Workflow permissions | Read-only `GITHUB_TOKEN` (applied). "Actions may create and approve pull requests" is not applied yet: the repository-level PUT is refused (409) while the organization policy "Allow GitHub Actions to create and approve pull requests" is off. An org admin enables it under Org Settings > Actions > General; then the PUT below applies. | `gh api --method PUT ... actions/permissions/workflow` |
| Labels | `dependencies` and `skip-changelog`, next to the defaults (`enhancement`, `bug`, `documentation`). | `gh label create` |

The ruleset, saved as `ruleset-engine.json` outside the repository (`integration_id` 15368 is the GitHub Actions app, so a commit status of the same name from another source does not count):

```json
{
  "name": "protect-main",
  "target": "branch",
  "enforcement": "active",
  "bypass_actors": [],
  "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    { "type": "pull_request", "parameters": {
        "required_approving_review_count": 0,
        "dismiss_stale_reviews_on_push": false,
        "require_code_owner_review": false,
        "require_last_push_approval": false,
        "required_review_thread_resolution": false } },
    { "type": "required_status_checks", "parameters": {
        "strict_required_status_checks_policy": false,
        "do_not_enforce_on_create": false,
        "required_status_checks": [
          { "context": "test", "integration_id": 15368 },
          { "context": "validate-action", "integration_id": 15368 },
          { "context": "publish-action", "integration_id": 15368 },
          { "context": "update-action", "integration_id": 15368 },
          { "context": "scan-action", "integration_id": 15368 },
          { "context": "changerule-action", "integration_id": 15368 } ] } }
  ]
}
```

The commands:

```sh
gh api --method POST -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" \
  repos/ALCops/rulebook-engine/rulesets --input ruleset-engine.json
gh api repos/ALCops/rulebook-engine/rulesets --jq '.[] | {id,name,enforcement}'

gh api --method PUT repos/ALCops/rulebook-engine/actions/permissions/workflow \
  -f default_workflow_permissions=read -F can_approve_pull_request_reviews=true

gh label create dependencies -R ALCops/rulebook-engine --color 0366d6 --description "Dependency updates (Dependabot)"
gh label create skip-changelog -R ALCops/rulebook-engine --color cfd3d7 --description "Exclude from release notes"
```

`ALCops/rulebook` gets the same ruleset without the `required_status_checks` rule (it has no CI) and the same workflow permissions.

## 7. Pull requests

- One release-note label: `enhancement`, `bug`, `documentation`, `dependencies`, or `skip-changelog` to leave the pull request out of the notes. An unlabelled pull request lands under "Other changes"; one with several labels is filed under the first matching category in `.github/release.yml`.
- A title that reads as a release line, because it becomes one. A change to level content names the diagnostic ids and the file.
- `Closes #n` for the issue it finishes.
- Reviewed before merge: by another maintainer, or by an automated code review whose outcome is recorded in the PR body. The ruleset requires no approval, so this rule is kept by convention.
- Work found on the way becomes its own issue through the *Task or spin-off* form, linked from the originating issue; it is not added to the current pull request.
- The [definition of done](README.md#definition-of-done) in the README applies.
