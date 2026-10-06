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
| `.github/workflows/ci.yml` | PSScriptAnalyzer and Pester on every pull request and every push to `main` and to a release branch (`v*`); the Validate action on two fixtures. | WP00, WP03 |
| `.github/workflows/` (deploy) | Copies `template/` into `ALCops/rulebook` and pins action references to `@v1`. | WP13 ([#15](https://github.com/ALCops/rulebook-engine/issues/15)) |
| `.github/release.yml` | Maps pull request labels to release-note sections ([D38](docs/adr/0038-release-notes-are-generated-from-pull-request-labels.md)). | WP00 |
| `.github/dependabot.yml` | Weekly, grouped updates of the GitHub Actions used by the workflows. | WP00 |
| `.github/ISSUE_TEMPLATE/` | Issue forms: work package, task or spin-off. | written |
| `PSScriptAnalyzerSettings.psd1` | Analyzer settings: errors and warnings, default rules, justified exclusions only. | WP00 |
| `schemas/` | JSON schemas for every file in an organization rulebook repository, draft 2020-12, no `$id`; names and URLs in [docs/reference/naming.md](docs/reference/naming.md). | WP02 ([#4](https://github.com/ALCops/rulebook-engine/issues/4)) |
| `tests/` | `Smoke.Tests.ps1`, `Schemas.Tests.ps1`, `Rulebook.Generate.Tests.ps1`, `Rulebook.Validate.Tests.ps1` and `Validate.Action.Tests.ps1` now; later one suite per module and action, with fixtures under `tests/fixtures/`. | WP00, WP02, WP03; WP12 ([#14](https://github.com/ALCops/rulebook-engine/issues/14)) and every module work package |
| `tests/fixtures/schemas/` | One file per case: `<valid\|invalid>/<schema-basename>/<reason>.json`, each invalid file a one-change mutation of a valid one. | WP02 |
| `tests/fixtures/repos/` | Organization rulebook repositories for the module suites. `valid-minimal` (30-id catalog, four levels, three stages) and `stale-endpoints` are complete on disk, their `rulesets/` written by `Update-RulebookEndpoints`; every other folder is an overlay holding only the files it changes, copied over `valid-minimal` by `New-FixtureRepo`. | WP03 |
| `tests/Helpers/` | Helpers the suites dot-source in `BeforeAll`: `RepoFixture.ps1` copies a fixture into `TestDrive`, edits its JSON, creates git repositories and the synthetic performance rulebook. | WP03 |
| `modules/` | PowerShell modules shared by the actions, each a `.psm1` with a `.psd1` manifest: `Rulebook.Generate` and `Rulebook.Validate` (written). | WP03 to WP09 |
| `actions/` | Composite actions, one folder each with `action.yaml` and its entry script. | WP03 to WP09 |
| `actions/Validate/` | `action.yaml` and `Validate.ps1`: checks C1 to C15, annotations, the job summary with the effective diff ([ARCHITECTURE.md](docs/ARCHITECTURE.md) section 5.5). | WP03 |
| `template/` | Source of the template content deployed to `ALCops/rulebook`: `.github/workflows/Validate.yaml` now; the content with WP04. | WP03, WP04, WP13 |
| `docs/`, `tools/rulebook/` | Architecture, decision records, level content and the scripts that build it. | written |

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

When a change touches `tools/rulebook/` or `docs/rulebook/`, also run `pwsh ./tools/rulebook/Test-Rulebook.ps1`. Regenerating the level content with `Extract-Inventory.ps1` needs the sibling clones `../Analyzers` and `../nav-sdk-source`.

## 4. CI

`.github/workflows/ci.yml` has two jobs on `ubuntu-latest` with a 15-minute timeout each, `test` and `validate-action`. Both run on every pull request and on every push to `main` or a release branch (`v*`). `test` installs PSScriptAnalyzer and Pester 6, runs the analyzer over the whole repository and fails on any finding (after printing the findings table), runs Pester from `tests/`, and uploads `testResults.xml` (NUnit) as the `testResults` artifact, also when a step failed. The workflow token is read-only, and a new push to a pull request cancels its running job; pushes to `main` and release branches always finish.

`validate-action` runs the composite action from the checkout (`uses: ./actions/Validate`) the way an organization workflow does: it must pass on `tests/fixtures/repos/valid-minimal` and fail on `tests/fixtures/repos/stale-endpoints`, and the job fails otherwise. Its step on `stale-endpoints` prints one expected C12 error annotation. The ruleset requires both checks (section 6).

The module versions are pinned in `ci.yml` (PSScriptAnalyzer 1.25.0, Pester 6.2.0) and bumped by hand, because Dependabot does not cover the PowerShell Gallery; it only updates the action tags.

## 5. Branches and releases

`main` is the development branch. Organization repositories never run `main`: the deploy workflow pins the template's action references to a release branch, the first being `v1` (O3, [#27](https://github.com/ALCops/rulebook-engine/issues/27); WP13, [#15](https://github.com/ALCops/rulebook-engine/issues/15)). Fixes reach `v1` without touching any organization repository.

Release notes are not written by hand. GitHub generates them from the merged pull requests, grouped by label through `.github/release.yml`, and the deploy step writes the same text into the template's `RELEASENOTES.copy.md` ([D38](docs/adr/0038-release-notes-are-generated-from-pull-request-labels.md)).

## 6. Repository settings

Applied on 2026-10-03 by the WP00 pull request ([#2](https://github.com/ALCops/rulebook-engine/issues/2)) with the commands below. Changing a setting means changing this section in the same pull request.

| Setting | Value | Command |
|---|---|---|
| Ruleset `protect-main` on the default branch | Pull request required, 0 approvals, deletion and force-push blocked, checks `test` and `validate-action` from GitHub Actions required, no bypass actors. `validate-action` was added on 2026-10-06 with the WP03 pull request ([#46](https://github.com/ALCops/rulebook-engine/pull/46)) through a PUT of the same JSON. | `gh api --method POST ... rulesets --input ruleset-engine.json`, later `gh api --method PUT ... rulesets/24420852 --input ruleset-engine.json` |
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
          { "context": "validate-action", "integration_id": 15368 } ] } }
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
