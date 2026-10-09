# Update mechanics

How the update of an organization rulebook repository from its template works: which files it manages and how, what the check in Validate reports, how the update pull request is built, and which token it writes with. The design is in [ARCHITECTURE.md](../ARCHITECTURE.md) section 7.3, the AL-Go original in [al-go-template-mechanics.md](al-go-template-mechanics.md) sections 5, 6 and 8, the site rule in [dashboard.md](../dashboard.md) section 9 and [D35](../adr/0035-site-is-a-customizable-file-class-overwritten-only-when.md), the documentation class and the recovery of an unrecorded installed commit in [D50](../adr/0050-docs-is-a-customizable-file-class-and-the-installed-commit-is-recovered.md), the secret in [D44](../adr/0044-the-write-token-secret-is-ghtokenworkflow-in-al-go-format.md).

> **Status:** written by WP07 ([#9](https://github.com/ALCops/rulebook-engine/issues/9)); the `docs/**` class and the installed-commit recovery by WP11 ([#13](https://github.com/ALCops/rulebook-engine/issues/13)). Code: `modules/Rulebook.Update.psm1`, `modules/Rulebook.GitHub.psm1`, `actions/CheckForUpdates/`, `template/.github/workflows/UpdateRulebookSystemFiles.yaml`. Everything below is derived from that code and its tests unless it says *observed*; the live run is section 12.

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
| customizable | shipped `site/**` except `site/data/**` (kind site, D35), shipped `docs/**` (kind docs, D50) | The three-way decision of section 3; with `site.updateMode` `"overwrite"` (for site) or `docs.updateMode` `"overwrite"` (for docs) the overwrite class. The two keys are independent. |
| org-owned | everything else: `README.md`, `overrides.json`, `quarantine.*.json`, `catalog/**`, `site/data/**`, a `docs/` page the template does not ship, level and stage files and workflows the template does not ship | Never compared, written or removed. |

The skeletons are **generated**, not overwrite as the issue table had it: their content depends only on the organization's levels and stages, so the update writes them from the settings, and a custom level gets its skeletons in the same pull request.

**`unusedRulebookFiles`** entries are repository-relative paths with `/` (`stages/vnext.json`, not `vnext.json`; the schema rejects a bare name, [#49](https://github.com/ALCops/rulebook-engine/issues/49)). C9 matches them the same way. A listed path is never written; when it is present, matches an overwrite or customizable pattern and the new or the installed template ships it, the update deletes it. A listed path that is absent and that the new template does not ship gets the note "listed in unusedRulebookFiles but the template does not ship it; the entry can be removed". A listed path the template does not manage (an organization's own unpublished level file, listed to silence C9) is left alone with a note.

A file the installed template shipped and the new one does not, present and not listed, stays and gets the note "The template no longer ships <path>; list it in unusedRulebookFiles to remove it". The installed template is downloaded on every run whose recorded commit differs from the new one (section 6), so every dropped managed file gets the note or, when listed, is removed; only when that commit is gone (HTTP 404) are there no such notes.

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

`Compare-CustomizableFile` decides every `site/**` and `docs/**` file the new template ships and `unusedRulebookFiles` does not list. It takes the organization's file, the template file at the installed commit (old) and the new template file, each `$null` when absent (D35, D50, dashboard.md section 9). The update mode is the key of the file's kind: `site.updateMode` or `docs.updateMode`, absent meaning `skip`:

| Organization | Old template | New template | Decision |
|---|---|---|---|
| absent | any | present | `add` |
| equal to new | any | present | `none` |
| differs | any | present, `updateMode` `overwrite` | `overwrite` (the pull request shows the revert) |
| differs | absent (no installed commit, or a file the organization made) | present | `skip`, listed with reason `no installed template` or `local file` |
| equal to old | present | changed | `overwrite` |
| differs from old | present | equal to old | `keep`, no diff |
| differs from old | present | changed | `skip`, listed with reason `local changes` |

Skipped files are listed in the pull request under "Skipped: local changes", with the reason per file, the keys of the kinds present ("set docs.updateMode or site.updateMode to overwrite") and the template's compare link when the installed commit is known; when a file was skipped for want of an installed commit, one more line says the commit is not recorded in `templateSha` and could not be recovered. Text compares LF-normalised (a CRLF copy of an unchanged page is equal), binaries such as `docs/images/*.png` by bytes. Removal follows the one rule of section 1 for every managed class: a site or docs file listed in `unusedRulebookFiles` is deleted when present and shipped by the new or the installed template; a site or docs file the template dropped and nobody listed stays, with the note "The template no longer ships ...". A shipped page the organization deletes without listing it is added again by the next update.

**The installed commit (D50).** The old side is the template at `templateSha` (`InstalledSource` `recorded`). When `templateSha` is empty (a repository fresh from "Use this template" that never ran the update) and the stored `templateUrl` names the same template, the update recovers it: "Use this template" creates one root commit whose tree is the tree of the template commit it copied, so the newest commit of the template branch with the tree of the repository's root commit is the installed one (`recovered`, note "templateSha is empty; the installed template commit <sha7> was recovered from the repository's root commit (tree <tree7>)."). No match, or any failure on the way, keeps the old behaviour (`none`): the files that differ are skipped with reason `no installed template` and the note says why ("templateSha is empty and the installed template commit could not be recovered: ..."). The recovered commit is only the old side; `templateSha` records the new head as always. Section 6 has the requests.

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
2. Where `on:/workflow_dispatch:/inputs:/levels:/options:` (or `stages:`) exists, its items become `- '*'` and the level (stage) slugs of the organization's settings in settings order (D30). The items must be indented below `options:`. A slug YAML would read as another type (`yes`, `null`, `2026`) is quoted. The template ships `ChangeRule.yaml` (WP09) with the shipped slugs in exactly this layout, so its rewrite with the shipped settings changes nothing and an organization's own level or stage appears in the form after its next update.
3. In `UpdateRulebookSystemFiles.yaml` settings `update.schedule`, in `ScanDiagnostics.yaml` (WP08) settings `scan.schedule` (a five-field cron string) adds or replaces `schedule:` with `- cron: '<cron>'` at the end of `on:`; `null` removes it. Absent differs: an absent `update.schedule` removes the update schedule, while an absent `scan` key or `scan.schedule` keeps the schedule `ScanDiagnostics.yaml` ships (`KeepWhenAbsent`, so an organization from before WP08, whose settings have no `scan` key, keeps its daily scan). The two keys never cross files, and any other workflow keeps its triggers. The template ships no update schedule and the scan schedule `17 4 * * *` already in place, so the rewrite of the shipped `ScanDiagnostics.yaml` with the shipped settings changes nothing. A scheduled update has no inputs: the settings step takes `downloadLatest` true and `directCommit` = not `commitOptions.createPullRequest` (the scan's settings step does the same with `includePrerelease` true).

## 6. Token and secret

| Step | Token |
|---|---|
| Template download (check and update mode) | `GITHUB_TOKEN` of the run (read-only). On HTTP 401, 403 or 404 with a write token given (update mode only; check mode never passes one), the request is repeated with that token: GitHub App JSON is exchanged for an installation token with `contents: read` on the template repository (the App must be installed there), a personal access token is used as it is. If the exchange fails, the original answer stands and the exchange error is added to its message. The installed template is read with the same token as the new one, without a second exchange; any failure there is a note. |
| Duplicate guard, clone, push, pull request | The write token from the secret. |

**Secret lookup.** The workflow step `Read the settings` reads `ghTokenWorkflowSecretName` (default `GHTOKENWORKFLOW`; a GitHub secret name: `^[A-Za-z_][A-Za-z0-9_]*$` and not starting with `GITHUB_` in any case) and outputs it. An invalid name is rejected by the schema (C5), fails the settings step with "ghTokenWorkflowSecretName '<name>' is not a valid secret name", and fails the action in update mode with `failure=token` naming the value, never falling back to the default; the action receives `${{ secrets[steps.settings.outputs.secretName] }}`. The name and the value format are AL-Go's, so an organization that runs AL-Go reuses its organization secret and GitHub App (D44).

**Exchange.** `Get-GitHubAccessToken`: an empty value is no token; a value that does not start with `{` is a personal access token, used as it is; compressed JSON `{"GitHubAppClientId":"...","PrivateKey":"..."}` is exchanged: an RS256 JWT (`iat` now-60 s, `exp` now+600 s, `iss` the client id; a PEM whose lines were joined is accepted), `GET /repos/{repo}/installation`, then `POST <access_tokens_url>` for this repository only with `contents`, `pull_requests`, `workflows` write and `actions`, `metadata` read. The installation token lives one hour. Every token an exchange returns is masked (`::add-mask::<token>`) the moment it is obtained, before anything else runs: the write token right after the token guard, before the template download and the plan, and the read token of a private template inside `Get-RulebookTemplate` through its `-OnToken` callback.

**Git.** The token never enters a URL or git config: every git call gets `GIT_CONFIG_COUNT=1`, `GIT_CONFIG_KEY_0=http.<server>/.extraheader` and `GIT_CONFIG_VALUE_0=AUTHORIZATION: basic <base64(x-access-token:<token>)>` in its process environment (git 2.31 or later). The clone's local config holds only `user.name` (the actor), `user.email` (`<actor>@users.noreply.github.com`), `core.autocrlf false` and `commit.gpgsign false`.

**Why not `GITHUB_TOKEN`.** It can never get the `workflows` permission, so a push that changes `.github/workflows/` is refused; a pull request it opens starts no workflow, so Validate would not run on the update; and organizations can forbid Actions to open pull requests ([al-go-template-mechanics.md](al-go-template-mechanics.md) section 8.1).

**Installed template.** The second zipball (at the recorded or recovered installed commit) is downloaded whenever that commit differs from the new one: the three-way comparison of site and docs files and the notes on dropped files need it. Any failure there (404, 5xx, timeout) is a note; the site and docs files that differ are then skipped and dropped files get no note.

**Recovery of an empty `templateSha` (D50).** `Get-RulebookTemplate` gets the checkout (`-RepositoryRoot`), the repository (`GITHUB_REPOSITORY`), the ref (`GITHUB_SHA`) and `GITHUB_TOKEN` from both entry scripts; CheckForUpdates passes them only when the stored `templateUrl` names the template being read (the root of a repository moved to another template belongs to the old one). `Get-RepositoryRootTree` reads the root tree locally first (`Get-GitRootTree`: `git rev-list --max-parents=0 HEAD`, then `rev-parse <sha>^{tree}`; skipped for a shallow clone, which is why the shipped `UpdateRulebookSystemFiles.yaml` checks out with `fetch-depth: 0` and Validate already did), else walks `GET /repos/{repo}/commits?sha=<GITHUB_SHA>&per_page=100&page=N` with `GITHUB_TOKEN` to the last page (at most 10 pages; a repository with at least 1000 commits is a note). The git route returns every root commit and a folder inside another repository counts as no repository (`rev-parse --show-prefix` must be empty). The API route takes the last commit of the last page as the root and says so in a note: a repository with more than one root commit, or with commit dates out of order, may not match. `Get-GitHubCommitList` then lists the template branch (`GET /repos/{template}/commits?sha=<branch>`, at most 1000 commits, stopping after the page that holds a commit with a root tree) with the token that read the new template, without a second exchange, and the newest commit with the root tree wins; without a match on a capped list the note says "(list capped at <n> commits)". Both entry scripts log `Installed template: recorded <sha7>`, `recovered <sha7> from the root commit` or `not known` after the download. Off GitHub (`GITHUB_REPOSITORY` empty) only the local route runs; with local template folders (`-TemplatePath`) there is no recovery.

## 7. Check mode

The Validate action runs the check when `checkForUpdates` is `'true'`, or when it is empty (the default) and `update.check` of the settings is not `false`; CheckForUpdates runs it with `update` other than `'Y'`. Validate downloads the template of the settings at the head of its branch, and both read it with `GITHUB_TOKEN` only (CheckForUpdates passes no write token in check mode); a template that token cannot read (a private template, or a pull request from a fork with a restricted token) gives "update check skipped".

| Outcome | Annotation |
|---|---|
| No change | notice `No updates available` |
| Sha-only | notice `template commit <sha7> not recorded; run Update Rulebook System Files once` |
| Changes | warning `Updates available: run the Update Rulebook System Files workflow (<n> files)` |
| Template unreachable, no `.github/workflows` in the zip, rate limit, settings missing, any other failure of the plan | warning `update check skipped: <reason>` |
| The candidate would not validate | warning `update check skipped: the updated rulebook would not validate (<first error>)` |

Neither annotation counts towards `warnings=` or `failOnWarning`, and the check never fails the step. The engine CI passes `checkForUpdates: 'false'` on its fixture steps.

**Turning it off (#67).** `update.check: false` in `.github/Rulebook-Settings.json` turns the check off for every Validate run; the log says `Update check off (update.check is false)` and the summary has no update section. The key lives in the settings, so it survives updates, where an edited `checkForUpdates` input in `Validate.yaml` (a system file) would be overwritten. The template does not ship the key; absent means `true`. Precedence: an explicit `checkForUpdates` input (`'true'` or `'false'`) wins over the setting, an empty input follows it. Validate reads the setting leniently: a missing or unreadable settings file, or a value that is not a boolean, leaves the check on (the checks report the settings themselves). A caller of `Validate.ps1` that omits `-CheckForUpdates` follows the setting too; pass `'false'` to skip the check. Any other non-empty input turns the check off with the log line `checkForUpdates '<value>' is not 'true' or 'false'; the update check is off`.

## 8. Update mode

1. No token: `failure=token`, error `The <secretName> secret is needed to update system files. Read https://github.com/ALCops/rulebook/blob/main/docs/ghtokenworkflow.md`, before any request.
2. The write token, exchanged and masked before anything else (exchange failure: `failure=token`).
3. The template: with `downloadLatest` the branch head, else the recorded `templateSha`; an empty `templateSha` or another template URL than the recorded one always resolves the head. An empty `templateSha` of the same template is recovered for the comparison (section 6). Failure: `failure=template`.
4. The plan. Not valid: one error annotation per error finding ("The updated rulebook would not validate: ..."), `failure=validation`, nothing pushed. The findings come from the repository after the update, so an error the repository already has fails the update too.
5. Title `[<branch>@<sha7>] Update Rulebook System Files from <owner>/<repo> - <templateSha7>`, `<sha7>` the branch head from the API (for a direct commit the cloned head). Pull request mode only: an open pull request into the branch with exactly this title: warning `Pull request already exists: <url>`, exit 0, nothing cloned. **Known limitation (AL-Go behaviour, accepted):** the title carries the branch head, so a push to the branch while the update pull request is open changes `<sha7>`, the guard no longer matches, and the next run opens a second update pull request; close the older one.
6. Clone the branch (`--single-branch`), write the plan's changes, commit with the title. Pull request: push `update-rulebook-system-files/<branch>/<yyMMddHHmmss UTC>`, open the pull request with the body of section 9 and add `commitOptions.pullRequestLabels`. Direct commit (no duplicate guard, as in AL-Go): push the branch; a refused push (branch protection) moves the commit to the timestamped branch and opens the pull request instead. Nothing to commit: notice `No updates available`.
7. Failure stages, both with the hint "Make sure that the token in the secret <name> is not expired and may write contents, pull requests and workflows of <repo>":

   | `failure` | Steps |
   |---|---|
   | `push` | clone, write, commit, push |
   | `pull-request` | duplicate guard (branch head, open pull requests), the body, opening the pull request and its labels; after the push the message starts with "Branch `<name>` was pushed." and carries its `tree/<branch>` link once, so the pull request can be opened by hand; before the push (guard, branch lookup) nothing was pushed |

No auto-merge and no `includeBranches` in v1.

## 9. Pull request body and job summary

The body, in this order:

- An opening line: the branch, the template repository and commit.
- `## Changes`: `| File | Class | Change |`.
- `## Effective diff`: `Compare-RulebookEndpoints` on the clone against the cloned head, one `| Id | Before | After | Decided by |` table per endpoint (the rendering of the Validate summary), or "No effective change.".
- `## Skipped: local changes` when site or docs files were skipped, with the reasons, the `updateMode` keys of the kinds present and the compare link.
- `## Notes` when there are notes.
- `## Validation warnings` when the candidate has warnings.
- `## Release notes`: the part of the template's `.github/RELEASENOTES.copy.md` above the first `## v*.*` heading of the installed copy, its title line dropped and the other headings moved one level down (lines inside ``` or ~~~ fences stay as they are); "No release notes available" when nothing is new; left out when the template ships no release notes.

The body stays below the 65536-character limit (60000 characters): when it is longer, the release notes go first (a line points at `.github/RELEASENOTES.copy.md` of the pull request), then endpoint tables of the effective diff from the end (a line says how many are left out); only when that is not enough is the body cut at a line boundary, with a closing note. The job summary is `## Template update check` (check mode) or `## Rulebook system files update`: the message and result line, the same tables, the validation errors of an invalid candidate, the effective diff (or why it could not be computed) when a commit was pushed, and the new release notes. There is no effective diff for an existing pull request or nothing to commit, and the summary is capped at 900 KiB: cut at a line boundary, an open code fence closed, and a closing line saying where the full lists are (the pull request body, or the job log). Validate cuts its update-check section the same way instead of dropping it.

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

- Fixtures (derivation in [tests/fixtures/templates/README.md](../../tests/fixtures/templates/README.md)): `tests/fixtures/templates/v1` and `v2`, a mini template on the 30-id catalog of `valid-minimal` with workflows, release notes, a small site and two documentation pages with an image, and `tests/fixtures/repos/update-org`, created from v1 with a custom level `House`, an override on an id v2 changes, a quarantine entry, an own workflow, a schedule, two locally changed site files and two locally changed documentation pages.
- `tests/Rulebook.Update.Tests.ps1`: classes, settings edit, workflow rewrite, release notes, the customizable table, the plan of `update-org` against v2 and its variants (stage-only, `unusedRulebookFiles`, empty `templateSha`, `site.updateMode` and `docs.updateMode` overwrite, docs pages and images, CRLF, invalid template), the download with a mocked API (including the recovery of an empty `templateSha`: the newest commit with the root tree, the head short cut, no match, failures, the token), `Get-RepositoryRootTree` on real git repositories (local route, shallow clone and the REST walk, page cap), and `Publish-RulebookUpdate` against a bare git repository (branch, commit, tree, body, labels, duplicate guard, direct commit, refused push).
- `tests/Rulebook.GitHub.Tests.ps1`: the JWT verified with the public key, the exchange, pagination, `Get-GitHubCommitList` (pages, cap, 404), `Get-GitRootTree` (root tree, shallow clone, no repository), and clone and push against bare repositories with a `pre-receive` hook as branch protection; the token is in neither `git remote -v` nor `git config --list`.
- `tests/CheckForUpdates.Action.Tests.ps1` and `tests/Validate.Action.Tests.ps1`: the action files, the template workflow, both entry scripts in-process, and the recovery parameters both pass to the download.
- CI job `update-action`: the action on `update-org` against v1 (`updatesAvailable` false), against v2 (true), and in update mode without a token (`failure` `token`).

## 12. Live run

2026-10-07, all *observed*. Template [Arthurvdv/rulebook-e2e-template](https://github.com/Arthurvdv/rulebook-e2e-template) (seeded from engine `template/`, engine actions at `@wp07/update`, `templateUrl` pointing at itself, marked template); organization repository [Arthurvdv/rulebook-e2e-update](https://github.com/Arthurvdv/rulebook-e2e-update) created from it; a GitHub App on the Arthurvdv account (Contents, Pull requests, Workflows read and write, Actions read) installed on the organization repository only, its compressed JSON as `GHTOKENWORKFLOW`.

| Step | Run | Pull request | Outcome |
|---|---|---|---|
| Validate on the fresh repository | [37608785783](https://github.com/Arthurvdv/rulebook-e2e-update/actions/runs/37608785783) | | notice "template commit f57a43a not recorded; run Update Rulebook System Files once" (the public template read with `GITHUB_TOKEN`) |
| Update, run 1 | [37626804285](https://github.com/Arthurvdv/rulebook-e2e-update/actions/runs/37626804285) | [#1](https://github.com/Arthurvdv/rulebook-e2e-update/pull/1) | settings step "Secret: GHTOKENWORKFLOW", `secrets[steps.settings.outputs.secretName]` resolved (the input shows `***`, "Write token: app"); the PR changes `templateSha` and `{TEMPLATEURL}` only, label `rulebook`, author the App, Validate ran on it and passed. No `ghs_`, private key or JSON in the log. Merged. |
| Update, run 2 | [37627024897](https://github.com/Arthurvdv/rulebook-e2e-update/actions/runs/37627024897) | | notice "No updates available" (AC1) |
| Template: AL0235 at Error in `base/recommended.ruleset.json` | | | |
| Validate on a pull request | [37627303796](https://github.com/Arthurvdv/rulebook-e2e-update/actions/runs/37627303796) | (probe, closed) | warning "Updates available: run the Update Rulebook System Files workflow (11 files)", exit 0, `warnings=0` (AC10) |
| Update, run 3 | [37627396348](https://github.com/Arthurvdv/rulebook-e2e-update/actions/runs/37627396348) | [#3](https://github.com/Arthurvdv/rulebook-e2e-update/pull/3) | the level file, `recommended.*`, `strict.*`, `complete.*` and the settings; `essential.*` untouched (AC2); the body's effective diff shows AL0235 Warning -> Error decided by `level:recommended` |
| Update, run 4 (#3 open) | [37627519342](https://github.com/Arthurvdv/rulebook-e2e-update/actions/runs/37627519342) | | warning "Pull request already exists: .../pull/3", nothing created (AC8). #3 merged. |
| Template: AL1026 Hidden in `stages/ci.json`; organization: override AL0235 Info, `quarantine.ci.json` entry LC0043, `MyNightly.yaml` on `main` | | | |
| Update, run 5 | [37627798536](https://github.com/Arthurvdv/rulebook-e2e-update/actions/runs/37627798536) | [#4](https://github.com/Arthurvdv/rulebook-e2e-update/pull/4) | `stages/ci.json`, `recommended.ci`, `strict.ci`, `complete.ci` and the settings only (AC3); AL0235 stays Info in the regenerated endpoints although the level says Error (AC6); `overrides.json`, `quarantine.ci.json`, `MyNightly.yaml` untouched (AC7). Merged. |
| `update.schedule` "0 6 * * 1", update | [37628127815](https://github.com/Arthurvdv/rulebook-e2e-update/actions/runs/37628127815) | [#5](https://github.com/Arthurvdv/rulebook-e2e-update/pull/5) | `schedule:` with `- cron: '0 6 * * 1'` added at the end of `on:`. Merged. |
| `update.schedule` null, update | [37628315392](https://github.com/Arthurvdv/rulebook-e2e-update/actions/runs/37628315392) | [#6](https://github.com/Arthurvdv/rulebook-e2e-update/pull/6) | `schedule:` removed. Merged. |
| A ruleset requiring pull requests on `main`, template change, update with `directCommit` true | [37628547393](https://github.com/Arthurvdv/rulebook-e2e-update/actions/runs/37628547393) | [#7](https://github.com/Arthurvdv/rulebook-e2e-update/pull/7) | push refused with GH013, warning "The direct push to main was refused; creating a pull request instead", notice "Pull request: .../pull/7 (the direct commit was refused)". Ruleset removed, #7 merged. |
| Secret deleted, update | [37645738825](https://github.com/Arthurvdv/rulebook-e2e-update/actions/runs/37645738825) | | step failed with the error annotation "The GHTOKENWORKFLOW secret is needed to update system files. Read https://github.com/ALCops/rulebook/blob/main/docs/ghtokenworkflow.md" before any request (AC9) |

Observations: the effective-diff tables came out in endpoint-name order (Group-Object sorts); fixed to settings order, in the Validate summary too. A Windows clone without `core.autocrlf false` committed CRLF endpoints in a probe pull request, which C12 reported for all 12 endpoints; recreated with LF.
