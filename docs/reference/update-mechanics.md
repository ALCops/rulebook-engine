# Update mechanics

How the update of an organization rulebook repository from its template works: which files it manages and how, what the check in Validate reports, how the update pull request is built, and which token it writes with. The design is in [ARCHITECTURE.md](../ARCHITECTURE.md) section 7.3, the AL-Go original in [al-go-template-mechanics.md](al-go-template-mechanics.md) sections 5, 6 and 8, the site rule in [dashboard.md](../dashboard.md) section 9 and [D35](../adr/0035-site-is-a-customizable-file-class-overwritten-only-when.md), the secret in [D44](../adr/0044-the-write-token-secret-is-ghtokenworkflow-in-al-go-format.md).

> **Status:** written by WP07 ([#9](https://github.com/ALCops/rulebook-engine/issues/9)). Code: `modules/Rulebook.Update.psm1`, `modules/Rulebook.GitHub.psm1`, `actions/CheckForUpdates/`, `template/.github/workflows/UpdateRulebookSystemFiles.yaml`. Everything below is derived from that code and its tests unless it says *observed*; the live run is section 12.

---

## Contents

1. [File classes](#1-file-classes)
2. [The candidate tree and the change list](#2-the-candidate-tree-and-the-change-list)
3. [Customizable files](#3-customizable-files)
4. [The settings edit](#4-the-settings-edit)
5. [The workflow rewrite](#5-the-workflow-rewrite)
6. [Token and secret](#6-token-and-secret)
7. [Check mode](#7-check-mode)
8. [Update mode](#8-update-mode)
9. [Pull request body and job summary](#9-pull-request-body-and-job-summary)
10. [Action reference](#10-action-reference)
11. [Engine proof](#11-engine-proof)
12. [Live run](#12-live-run)

---

## 1. File classes

`Get-RulebookFileClass` gives every repository-relative path one class. The **include-list rule** of AL-Go holds: only a path that matches a managed pattern **and** that the template ships is compared, written or removed. A file only the organization has is never touched, whatever its name.

| Class | Paths | On update |
|---|---|---|
| overwrite | shipped `.github/workflows/*.yaml` and `*.yml` (kind workflow), `.github/*.copy.md`, `.github/ISSUE_TEMPLATE/*`, `base/*.ruleset.json`, `base/twins.json`, `stages/*.json`, `skeletons/README.md` | Replaced by the template version, LF-normalised; a workflow first goes through the rewrite of section 5. The pull request shows reverted hand edits. |
| settings | `.github/Rulebook-Settings.json` | The organization's text, with `$schema`, `templateUrl` and `templateSha` edited in place (section 4). |
| generated | `rulesets/*.ruleset.json`, `skeletons/*.ruleset.json` | Regenerated on the candidate: `New-RulebookSkeleton` from the organization's settings (when `skeletons/` exists), then `Update-RulebookEndpoints`. The template's own copies are never used. |
| customizable | shipped `site/**` except `site/data/**` | The three-way decision of section 3; with `site.updateMode` `"overwrite"` the overwrite class. |
| org-owned | everything else: `README.md`, `overrides.json`, `quarantine.*.json`, `catalog/**`, `docs/**`, `site/data/**`, level and stage files and workflows the template does not ship | Never compared, written or removed. |

The skeletons are **generated**, not overwrite as the issue table had it: their content depends only on the organization's levels and stages, so the update writes them from the settings, and a custom level gets its skeletons in the same pull request.

**`unusedRulebookFiles`** entries are repository-relative paths with `/` (`stages/vnext.json`, not `vnext.json`; the schema rejects a bare name, [#49](https://github.com/ALCops/rulebook-engine/issues/49)). C9 matches them the same way. A listed path is never written; when it is present, matches an overwrite or customizable pattern and the new or the installed template ships it, the update deletes it. A listed path that is absent and that the new template does not ship gets the note "listed in unusedRulebookFiles but the template does not ship it; the entry can be removed". A listed path the template does not manage (an organization's own unpublished level file, listed to silence C9) is left alone with a note.

A file the installed template shipped and the new one does not, present and not listed, stays and gets the note "The template no longer ships <path>; list it in unusedRulebookFiles to remove it". Removing a dropped file therefore needs the installed template (section 6 on when it is downloaded).

## 2. The candidate tree and the change list

`Get-RulebookUpdatePlan` never writes into the repository:

1. Read `.github/Rulebook-Settings.json` (missing or not JSON: one finding `update`, error).
2. Copy the working tree to `<work>/candidate`, without `.git`, `site/data` and any `node_modules`.
3. For every template path by class: write the overwrite files (bytes for a binary file: a known image, font, PDF or zip extension, or a NUL byte in the first 8 KB), decide the customizable ones, skip the listed ones; then the settings edit.
4. Delete the listed managed files; collect the notes of section 1.
5. Regenerate `skeletons/` and `rulesets/` on the candidate. An exception there is one finding `update`.
6. Run `Test-Rulebook` on the candidate. `Valid` means no error finding.
7. Compare the candidate with the working tree over both file lists: text LF-normalised with one trailing LF and compared case-sensitively (`-cne`), binaries (same rule as step 3) by bytes. Each difference is a change `{ File, Class, Kind, Change (created, modified, deleted), Bytes }`.
8. The release notes delta (section 9).

**Sha-only.** When every change is bookkeeping, `templateSha` in the settings and the `{TEMPLATEURL}` placeholder of a workflow, the plan is `ShaOnly` and `UpdatesAvailable` is false. That is the state of a repository fresh from the template and of one whose template has not moved since it recorded another sha. Any other change makes `UpdatesAvailable` true.

## 3. Customizable files

`Compare-CustomizableFile` decides every `site/**` file the new template ships and `unusedRulebookFiles` does not list. It takes the organization's file, the template file at the installed `templateSha` (old) and the new template file, each `$null` when absent (D35, dashboard.md section 9):

| Organization | Old template | New template | Decision |
|---|---|---|---|
| absent | any | present | `add` |
| equal to new | any | present | `none` |
| differs | any | present, `updateMode` `overwrite` | `overwrite` (the pull request shows the revert) |
| differs | absent (empty `templateSha`, or a file the organization made) | present | `skip`, listed with reason `no installed template` or `local file` |
| equal to old | present | changed | `overwrite` |
| differs from old | present | equal to old | `keep`, no diff |
| differs from old | present | changed | `skip`, listed with reason `local changes` |

Skipped files are listed in the pull request under "Skipped: local changes in site/", with the template's compare link when the installed commit is known. Removal follows the one rule of section 1 for every managed class: a site file listed in `unusedRulebookFiles` is deleted when present and shipped by the new or the installed template; a site file the template dropped and nobody listed stays, with the note "The template no longer ships ...".

## 4. The settings edit

`Update-RulebookSettingsText` edits three string values in the organization's text and leaves every other byte alone; AL-Go round-trips the JSON, which would reformat the file.

- `templateUrl` and `templateSha` get the template URL and commit; `$schema` gets the template settings' `$schema` (left alone when the template has none).
- `templateSha` absent: inserted on its own line after the `templateUrl` line when that line ends with a comma, else directly after the `templateUrl` value (a minified file).
- `$schema` absent: inserted as the first property.
- No `templateUrl`: the plan is invalid ("No templateUrl in .github/Rulebook-Settings.json").

Line endings become LF. Keys the engine does not know survive; the schema rejects them in Validate.

## 5. The workflow rewrite

`ConvertTo-UpdatedWorkflowText` runs on every shipped workflow, line based, with a small editor ported from AL-Go's `yamlclass.ps1` (paths like `on:/workflow_dispatch:/inputs:`, two spaces per level, no YAML parser, so the template's formatting survives):

1. `{TEMPLATEURL}` becomes the template URL, so the dispatch form shows the current template.
2. Where `on:/workflow_dispatch:/inputs:/levels:/options:` (or `stages:`) exists, its items become `- '*'` and the level (stage) slugs of the organization's settings in settings order (D30). The items must be indented below `options:`. A slug YAML would read as another type (`yes`, `null`, `2026`) is quoted.
3. In `UpdateRulebookSystemFiles.yaml`: settings `update.schedule` (a five-field cron string) adds or replaces `schedule:` with `- cron: '<cron>'` at the end of `on:`; `null` or absent removes it. The template ships no schedule. A scheduled run has no inputs: the settings step takes `downloadLatest` true and `directCommit` = not `commitOptions.createPullRequest`.

## 6. Token and secret

| Step | Token |
|---|---|
| Template download (check and update mode) | `GITHUB_TOKEN` of the run (read-only). On HTTP 401, 403 or 404 with a write token given, that token is exchanged for `contents: read` and the request repeated: a private template is read with the GitHub App or PAT, which must then reach the template repository. |
| Duplicate guard, clone, push, pull request | The write token from the secret. |

**Secret lookup.** The workflow step `Read the settings` reads `ghTokenWorkflowSecretName` (default `GHTOKENWORKFLOW`, must match `^[A-Za-z_][A-Za-z0-9_]*$`) and outputs it; the action receives `${{ secrets[steps.settings.outputs.secretName] }}`. The name and the value format are AL-Go's, so an organization that runs AL-Go reuses its organization secret and GitHub App (D44).

**Exchange.** `Get-GitHubAccessToken`: an empty value is no token; a value that does not start with `{` is a personal access token, used as it is; compressed JSON `{"GitHubAppClientId":"...","PrivateKey":"..."}` is exchanged: an RS256 JWT (`iat` now-60 s, `exp` now+600 s, `iss` the client id; a PEM whose lines were joined is accepted), `GET /repos/{repo}/installation`, then `POST <access_tokens_url>` for this repository only with `contents`, `pull_requests`, `workflows` write and `actions`, `metadata` read. The installation token lives one hour. The action prints `::add-mask::<token>` before any other output after the exchange.

**Git.** The token never enters a URL or git config: every git call gets `GIT_CONFIG_COUNT=1`, `GIT_CONFIG_KEY_0=http.<server>/.extraheader` and `GIT_CONFIG_VALUE_0=AUTHORIZATION: basic <base64(x-access-token:<token>)>` in its process environment (git 2.31 or later). The clone's local config holds only `user.name` (the actor), `user.email` (`<actor>@users.noreply.github.com`), `core.autocrlf false` and `commit.gpgsign false`.

**Why not `GITHUB_TOKEN`.** It can never get the `workflows` permission, so a push that changes `.github/workflows/` is refused; a pull request it opens starts no workflow, so Validate would not run on the update; and organizations can forbid Actions to open pull requests ([al-go-template-mechanics.md](al-go-template-mechanics.md) section 8.1).

**Installed template.** The second zipball (at the recorded `templateSha`) is downloaded only when it differs from the new commit and is needed: the new template ships `site/**` and `site.updateMode` is not `overwrite`, or `unusedRulebookFiles` lists a path the new template does not ship. A 404 there is a note, and the site files that differ are skipped.

## 7. Check mode

The Validate action runs the check when `checkForUpdates` is `'true'` (the default); CheckForUpdates runs it with `update` other than `'Y'`. Validate downloads the template of the settings at the head of its branch, always with `GITHUB_TOKEN`.

| Outcome | Annotation |
|---|---|
| No change | notice `No updates available` |
| Sha-only | notice `template commit <sha7> not recorded; run Update Rulebook System Files once` |
| Changes | warning `Updates available: run the Update Rulebook System Files workflow (<n> files)` |
| Template unreachable, no `.github/workflows` in the zip, rate limit, settings missing | warning `update check skipped: <reason>` |
| The candidate would not validate | warning `update check skipped: the updated rulebook would not validate (<first error>)` |

Neither annotation counts towards `warnings=` or `failOnWarning`, and the check never fails the step. The engine CI passes `checkForUpdates: 'false'` on its fixture steps.

## 8. Update mode

1. No token: `failure=token`, error `The <secretName> secret is needed to update system files. Read https://github.com/ALCops/rulebook/blob/main/docs/ghtokenworkflow.md`, before any request.
2. The template: with `downloadLatest` the branch head, else the recorded `templateSha`; an empty `templateSha` or another template URL than the recorded one always resolves the head. Failure: `failure=template`.
3. The plan. Not valid: one error annotation per error finding ("The updated rulebook would not validate: ..."), `failure=validation`, nothing pushed. The findings come from the repository after the update, so an error the repository already has fails the update too.
4. The write token (exchange failure: `failure=token`), masked.
5. Title `[<branch>@<sha7>] Update Rulebook System Files from <owner>/<repo> - <templateSha7>`, `<sha7>` the branch head from the API. An open pull request into the branch with exactly this title: warning `Pull request already exists: <url>`, exit 0, nothing cloned. **Known limitation (AL-Go behaviour, accepted):** the title carries the branch head, so a push to the branch while the update pull request is open changes `<sha7>`, the guard no longer matches, and the next run opens a second update pull request; close the older one.
6. Clone the branch (`--single-branch`), write the plan's changes, commit with the title. Pull request: push `update-rulebook-system-files/<branch>/<yyMMddHHmmss UTC>`, open the pull request with the body of section 9 and add `commitOptions.pullRequestLabels`. Direct commit: push the branch; a refused push (branch protection) moves the commit to the timestamped branch and opens the pull request instead. Nothing to commit: notice `No updates available`.
7. A failure while cloning or pushing is `failure=push`, while listing or opening the pull request `failure=pull-request`, both with the hint "Make sure that the token in the secret <name> is not expired and may write contents, pull requests and workflows of <repo>".

No auto-merge and no `includeBranches` in v1.

## 9. Pull request body and job summary

The body, in this order:

- An opening line: the branch, the template repository and commit.
- `## Changes`: `| File | Class | Change |`.
- `## Effective diff`: `Compare-RulebookEndpoints` on the clone against the cloned head, one `| Id | Before | After | Decided by |` table per endpoint (the rendering of the Validate summary), or "No effective change.".
- `## Skipped: local changes in site/` when files were skipped, with the reasons and the compare link.
- `## Notes` when there are notes.
- `## Validation warnings` when the candidate has warnings.
- `## Release notes`: the part of the template's `.github/RELEASENOTES.copy.md` above the first `## v*.*` heading of the installed copy, its title line dropped and the other headings moved one level down (lines inside ``` or ~~~ fences stay as they are); "No release notes available" when nothing is new; left out when the template ships no release notes.

The body stays below the 65536-character limit (60000 characters): when it is longer, the release notes go first (a line points at `.github/RELEASENOTES.copy.md` of the pull request), then endpoint tables of the effective diff from the end (a line says how many are left out); only when that is not enough is the body cut at a line boundary, with a closing note. The job summary always has the full lists. The job summary is `## Template update check` (check mode) or `## Rulebook system files update`, the result line and the same tables, plus the validation errors of an invalid candidate.

## 10. Action reference

`actions/CheckForUpdates/action.yaml`, one `pwsh` step, inputs through `INPUT_*` environment variables, `GITHUB_TOKEN` from `github.token`:

| Input | Default | Meaning |
|---|---|---|
| `templateUrl` | `''` | `owner/repo[@branch]` or `https://github.com/owner/repo@branch`; empty uses the setting. Normalised AL-Go style (append `@main`, prepend `https://github.com/`, strip `www.`). |
| `templatePath`, `installedTemplatePath`, `templateSha` | `''` | Local template folders instead of the download (engine tests and CI); `templateSha` empty uses a content sha of the folder. |
| `token` | `''` | The secret value. |
| `update` | `'N'` | `'Y'` writes. |
| `downloadLatest` | `'true'` | `'false'` re-applies the recorded `templateSha`. |
| `directCommit` | `'false'` | Push to `updateBranch`. |
| `updateBranch` | `${{ github.ref_name }}` | |
| `repositoryRoot` | `'.'` | |
| `actor` | `${{ github.actor }}` | Git author of the commit. |

Outputs: `updatesAvailable` (`true`/`false`), `pullRequestUrl`, `templateSha`, `failure` (`token`, `template`, `validation`, `push`, `pull-request`, `error`; empty on success).

## 11. Engine proof

- Fixtures (derivation in [tests/fixtures/templates/README.md](../../tests/fixtures/templates/README.md)): `tests/fixtures/templates/v1` and `v2`, a mini template on the 30-id catalog of `valid-minimal` with workflows, release notes and a small site, and `tests/fixtures/repos/update-org`, created from v1 with a custom level `House`, an override on an id v2 changes, a quarantine entry, an own workflow, a schedule and two locally changed site files.
- `tests/Rulebook.Update.Tests.ps1`: classes, settings edit, workflow rewrite, release notes, the customizable table, the plan of `update-org` against v2 and its variants (stage-only, `unusedRulebookFiles`, empty `templateSha`, `updateMode` overwrite, CRLF, invalid template), the download with a mocked API, and `Publish-RulebookUpdate` against a bare git repository (branch, commit, tree, body, labels, duplicate guard, direct commit, refused push).
- `tests/Rulebook.GitHub.Tests.ps1`: the JWT verified with the public key, the exchange, pagination, and clone and push against bare repositories with a `pre-receive` hook as branch protection; the token is in neither `git remote -v` nor `git config --list`.
- `tests/CheckForUpdates.Action.Tests.ps1` and `tests/Validate.Action.Tests.ps1`: the action files, the template workflow, both entry scripts in-process.
- CI job `update-action`: the action on `update-org` against v1 (`updatesAvailable` false), against v2 (true), and in update mode without a token (`failure` `token`).

## 12. Live run

Pending: the live run on scratch repositories (`Arthurvdv/rulebook-e2e-template` and `Arthurvdv/rulebook-e2e-update`) with a GitHub App as `GHTOKENWORKFLOW` is recorded here with its run and pull request URLs once it has run.
