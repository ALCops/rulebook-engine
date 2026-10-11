# Releasing the engine and the template

How a version of Rulebook reaches organizations: the branches that move, cutting a release, a hotfix, what a release promises, deprecations instead of majors, the refresh of the bleeding-edge branch, the one-time repository settings and what to do when the deploy refuses.

> **Status:** written by WP13 ([#15](https://github.com/ALCops/rulebook-engine/issues/15)), rewritten by [#104](https://github.com/ALCops/rulebook-engine/issues/104) for the model of [D53](adr/0053-template-main-is-the-release-preview-the-bleeding-edge-and-deprecations-replace-majors.md) (template `main` is the release, `preview` the bleeding edge, tags the pin, deprecations instead of majors), which supersedes [D52](adr/0052-releases-are-a-floating-major-branch-cut-from-hand-written-release-notes.md). Code: `modules/Rulebook.Deploy.psm1`, `tools/deploy/Invoke-Deploy.ps1`, `tools/deploy/keep.txt`, `.github/workflows/Deploy.yaml`, `.github/workflows/RefreshTemplate.yaml`; tests: `tests/Rulebook.Deploy.Tests.ps1`. The user-facing page is [template/docs/versioning.md](../template/docs/versioning.md).

## Contents

1. [The branches and what moves](#1-the-branches-and-what-moves)
2. [Cutting a release](#2-cutting-a-release)
3. [A hotfix](#3-a-hotfix)
4. [What a release promises](#4-what-a-release-promises)
5. [Deprecations instead of majors](#5-deprecations-instead-of-majors)
6. [The refresh and the canary](#6-the-refresh-and-the-canary)
7. [Repository settings and human steps](#7-repository-settings-and-human-steps)
8. [Troubleshooting](#8-troubleshooting)

## 1. The branches and what moves

| Repository | Branch or tag | What it is | Moved by |
|---|---|---|---|
| `ALCops/rulebook-engine` | `main` | Development. Pull requests only. | merges |
| `ALCops/rulebook-engine` | `v1` | The released engine every organization's workflows run (`uses: ALCops/rulebook-engine/actions/<Name>@v1`). Always a commit that was the head of `main` or of a pull request branch when it was released. | the Deploy workflow |
| `ALCops/rulebook-engine` | `v1.x.y` tags | One per release, with a GitHub Release whose body is the notes section. | the Deploy workflow |
| `ALCops/rulebook` | `main` (the default branch) | The release: the engine's `template/` with every engine reference rewritten to `v1` and the template references left at `main`, plus `.github/RELEASENOTES.copy.md` and the kept files. "Use this template" copies it; `templateUrl` of an organization ends in `@main`. | the Deploy workflow |
| `ALCops/rulebook` | `v1.x.y` tags | The template commit of each release (no GitHub Release); an organization pins a release with `templateUrl` ending in the tag. | the Deploy workflow |
| `ALCops/rulebook` | `preview` | The bleeding edge: the engine's `template/` with the engine references left at `main` and the template references rewritten to `preview`, plus the release notes copy. The canary rulebook follows it. | the Refresh Template workflow |

Engine and template share one version number because they are released together. The version is the top heading of [RELEASENOTES.md](../RELEASENOTES.md): `## v1.0.1`, or with a prerelease suffix `## v1.1.0-beta.1`. Nothing else names the version; the deploy derives the engine branch (`v<major>`) and the tag from it.

The engine's `template/` says `main` in every reference. The deploy rewrites it with two rules (`Convert-DeployReference -EngineBranch -TemplateBranch`), one per repository:

| Target | What it matches | Release | Refresh |
|---|---|---|---|
| Engine | `main` after `ALCops/rulebook-engine` as `@main`, `/main/` (raw URLs), `/blob/main/`, `/raw/main/`, `/tree/main/` or `/actions/<Name>@main` | `v1` | `main` (unchanged) |
| Template | `main` after `ALCops/rulebook` as `@main` (`templateUrl`), `/main/`, `/blob/main/`, `/raw/main/` or `/tree/main/` | `main` (unchanged) | `preview` |

The two rules match disjoint positions (the template rule cannot match `ALCops/rulebook-engine/...`: `-engine` sits between `rulebook` and the `/` or `@` it needs). `branches: [ main ]`, "the main branch", `maintain`, `rulebook-engine-main` and a bare `@main` stay. The rewrite runs on `.md`, `.yaml`, `.yml`, `.json`, `.ps1`, `.txt` and `.html` files and keeps their encoding and line endings; binary files are copied as they are. The engine's own `v1` is never rewritten: code names no branch and builds every URL from the ref it runs at (`Get-RulebookEngineRef` of `Rulebook.Common`); the user docs URL maps that engine ref to the template ref that holds the page (`Get-RulebookDocsUrl`: `v1` to `main`, `main` to `preview`, a release tag to the same tag, a commit sha to `main`, anything else to `preview`).

**Writer rule for `template/docs`.** A full template URL in the prose (`https://github.com/ALCops/rulebook@main`, `https://github.com/ALCops/rulebook/blob/main/docs/...`) becomes `preview` on the refresh. Write it in full only where that is right, for example the form default in `updating.md`, which on `preview` shows the canary's own value. Where `main` means the release literally (the sentence that tells a `preview` follower how to switch back), write the bare `@main`. A Deploy test checks that `versioning.md` still names the release as a bare `@main` after the refresh rewrite, and another one that the shipped pages never say "the `main` branch" of the engine, which no rewrite reaches.

## 2. Cutting a release

1. **Notes.** Every pull request adds its line under the top heading of `RELEASENOTES.md` (CONTRIBUTING section 7). To release, make sure the top heading is the version to release and its section lists what changed in words an organization understands, with a "Deprecations" line for every deprecation the release starts (section 5). The first pull request after a release adds the next heading. For a release that only changes the engine (a fix), the section says so: organizations still get an update pull request whose only change is the notes copy.
2. **Merge** the last pull request. CI must be green on the commit you release: the deploy refuses a commit whose latest check runs are not all completed with success or skipped, or that has no check run named `test`.
3. **Dry run.** Actions > Deploy > Run workflow with *dryRun* on, or `gh workflow run Deploy.yaml -R ALCops/rulebook-engine -f dryRun=true`. The job summary shows the version, the engine branch, the template branch `main`, the files the rewrite changes under "Rewritten (engine -> `v1`, template -> `main`, N files)" and the notes section, and "DRY RUN: nothing pushed". The dry run exchanges the App tokens and runs every check, so a missing setting shows up here.
4. **Release.** The same without *dryRun*: `gh workflow run Deploy.yaml -R ALCops/rulebook-engine`. The run, in this order: clones `ALCops/rulebook@main`, replaces everything but `.git` and the keep list `tools/deploy/keep.txt` with `template/`, writes `.github/RELEASENOTES.copy.md`, rewrites the engine references to `v1` (the template references stay at `main`), commits `Release <version> from ALCops/rulebook-engine@<sha7>` when something changed, pushes `main` and tags its head; then moves the engine's `v1` to the released commit (a push forced under a lease: it refuses when someone else moved `v1` since the run read it), tags it, and creates the GitHub Release (marked prerelease when the version has a suffix).
5. **Verify** the summary table (engine branch and tag, template branch, commit and tag, release URL). Then a scratch repository on `@main`: run **Update Rulebook System Files** there; the pull request body's release notes section is the new section.

GitHub registers a `workflow_dispatch` workflow only once its file is on the default branch: a new or renamed deploy workflow is merged first and dispatched afterwards (a dispatch before that answers HTTP 404). Once registered, a dispatch with `--ref <branch>` (`gh workflow run Deploy.yaml --ref <branch>`) runs the workflow file of that branch and releases that branch's head, whose pull request CI must be green. That is how a prerelease is cut from a pull request before its merge; the next release from `main` moves `v1` to the squash commit, which is not a descendant of the branch commit, so the engine push is forced (under the lease).

## 3. A hotfix

There is no maintenance branch and no fix of an old tag: support is latest only. A fix goes to `main` through a pull request like any change, with its line under a new patch heading (`## v1.0.2`), and the deploy releases `main`. The engine's `v1` and the template's `main` are always moves of engine `main`; work on `main` that is not ready to be released waits behind a feature switch or in its pull request.

## 4. What a release promises

The engine's `v1` floats: a release reaches every organization's workflows at their next run, and the template's `main` reaches them with their next update pull request. That works only while every release is safe for every organization, so a release:

- Starts a new Validate check as a warning; it becomes an error only through a deprecation (section 5).
- Only adds settings keys, each with a default that keeps today's behaviour; renaming or removing one is a deprecation.
- Moves no file between the file classes of the update (system, settings, generated, org-owned, customizable) without a deprecation.
- Only loosens schemas: a file that validated keeps validating.
- Keeps the published endpoint URL layout and the secret contract (`GHTOKENWORKFLOW`, D44), or changes them through a deprecation.

Prereleases are releases too: a `## v1.1.0-beta.1` heading moves the floating `v1` and the template's `main` like a stable version, so every organization runs the beta at its next workflow run and gets its template content with the next update. Cut a prerelease only when it is as safe as a patch.

This is a written policy, not a CI check (the compatibility job of [#106](https://github.com/ALCops/rulebook-engine/issues/106) would check it). A reviewer who sees a pull request break one of these asks for a deprecation (section 5) or a different design.

## 5. Deprecations instead of majors

Rulebook has no major versions (D53, after AL-Go). A change that would break an organization (a settings key renamed or removed, a file changing its class, a new endpoint URL layout, a new secret contract) ships as a deprecation:

1. **Honour the old form.** The engine keeps reading the old key, file or layout and behaves as before, translating it to the new form where it can.
2. **Warn with the date and the replacement.** Every run that meets the old form prints a warning annotation naming the replacement and the date after which the old form stops working ("`<old>` is deprecated; use `<new>`. After <date> it is an error."). Validate shows it on every pull request.
3. **Write it down.** The release that starts the deprecation has a line under "Deprecations" in its `RELEASENOTES.md` section with the same date and replacement, so the update pull request of every organization quotes it.
4. **Pick the date.** At least one release later and some months away, so an organization that runs the update on its own schedule sees the warning first.
5. **Remove after the date.** The first release after the date turns the warning into an error that still names the replacement, with a release line that says so.

Support is latest only: an organization on an old tag gets no fixes, and a support question is answered with "update first". The engine's `v1` floats for the lifetime of the action contract (the `uses:` inputs, the outputs, the `GHTOKENWORKFLOW` secret). Its major is bumped only if that contract itself breaks, and then through the same route: the new contract next to the old one, a deprecation of the old one, removal after the date. Versions stay `v1.x.y`.

The first deprecation brings the deprecation helper (one function that prints the warning or, after the date, throws), its registry (the deprecated forms with replacement and date), a user page `template/docs/deprecations.md` listing them by date, and the "Deprecations" section in the notes. None of these exist before that.

## 6. The refresh and the canary

The Refresh Template workflow (concurrency group `deploy-refresh`) runs on every push to engine `main` that touches `template/**`, `RELEASENOTES.md` or the workflow file, and by hand (Actions > Refresh Template). It clones `ALCops/rulebook@preview` (the first run after #104, when `preview` does not exist yet, clones `main` and pushes its head as `preview`, so the history continues), copies `template/` and the release notes copy with the same keep list, rewrites the template references to `preview` (the engine references stay at `main`), and commits `Refresh from ALCops/rulebook-engine@<sha7>` only when something changed: a run on unchanged content makes no commit. It needs no version and checks only that the checkout is clean and at the pushed commit. The Deploy workflow has its own group, `deploy-release`, so a release and a refresh may run side by side: they write different branches of the template (`main` and `preview`), and a push to engine `main` never cancels a waiting release.

The maintainers' own rulebook is the canary: an ordinary organization repository whose `templateUrl` ends in `@preview`. Its update pull request keeps its workflows on the engine at `main`, so it runs unreleased engine code on every run and receives template content minutes after a merge. Its docs links point at `preview` too (`Get-RulebookDocsUrl` maps engine `main` to `preview`). An engine branch cannot be run this way (the update rewrites the `uses:` lines back); a risky change is tried in pull request CI and in a scratch repository.

## 7. Repository settings and human steps

The deploy authenticates as a GitHub App owned by the ALCops organization and pushes directly; it changes no setting itself. These are done by an organization owner:

| Setting | Value |
|---|---|
| GitHub App (Org settings > Developer settings > GitHub Apps > New) | Any name (for example "Rulebook Deploy"); homepage `https://github.com/ALCops/rulebook-engine`; webhook off; repository permissions **Contents: Read and write**, **Workflows: Read and write**, **Checks: Read**, Metadata: Read (implied); installable on this account only. Generate a private key (a `.pem` download). Install it on `ALCops/rulebook-engine` and `ALCops/rulebook` only. |
| Engine variable `DEPLOY_APP_ID` | The App's **Client ID** (`Iv23li...`), not the numeric App ID. `gh variable set DEPLOY_APP_ID -R ALCops/rulebook-engine --body <client-id>` |
| Engine secret `DEPLOY_APP_PRIVATE_KEY` | The whole PEM. `gh secret set DEPLOY_APP_PRIVATE_KEY -R ALCops/rulebook-engine < key.pem` |
| Default branch of `ALCops/rulebook` | `main`. |
| `ALCops/rulebook` ruleset `protect-main` | Targets the default branch, `main`, which the release pushes: restrict deletions, block force pushes, require a pull request; the App as the only bypass actor (`actor_type` `Integration`, `actor_id` the numeric App ID, `bypass_mode` `always`). |
| `ALCops/rulebook` branch `preview` | Unprotected; only the refresh writes it. |
| Ruleset `protect-release-tags` on both repositories | Tags `refs/tags/v[0-9]*`: restrict creations, updates and deletions; bypass: the App only. |
| Engine ruleset `protect-release` | Branches `refs/heads/v[0-9]*`: restrict updates, restrict deletions, block force pushes; bypass: the App only. The engine push is forced and still passes, because the App bypasses. The template has no release branch and no such ruleset. |
| Engine ruleset `protect-main` | Unchanged: `main` keeps taking pull requests only. |
| Actions on `ALCops/rulebook` | Disabled (Settings > Actions > General > Disable actions, or `gh api -X PUT repos/ALCops/rulebook/actions/permissions -F enabled=false`). Its shipped workflows are meant for organization repositories: Publish would fail at the Pages preflight on every push and the scan would open pull requests in the template. |

The rulesets are created with `gh api --method POST repos/<owner>/<repo>/rulesets --input <file>.json`; a change to an existing one is a PUT of the full ruleset as a GET returns it (`gh api repos/ALCops/rulebook/rulesets/24422193`). The CONTRIBUTING section 6 table records what is applied.

**The switch from D52 (2026-10-11).** Under D52 the template's default branch was `v1`, protected by `protect-release` (24876041). The switch, by an organization owner and in this order, after the merge of #104 and the first refresh (which creates `preview` from `main`):

1. `gh api --method PATCH repos/ALCops/rulebook -f default_branch=main`: `protect-main` (24422193) targets `~DEFAULT_BRANCH`, so from then on it protects `main`.
2. `gh api --method DELETE repos/ALCops/rulebook/rulesets/24876041`: the template's `protect-release`, which would block the deletion of `v1`.
3. After the first release on `main` and once the repositories created from `v1` are gone: `gh api --method DELETE repos/ALCops/rulebook/git/refs/heads/v1`. The tags keep the released commits reachable.

Nothing changes on the engine.

## 8. Troubleshooting

| Message | Cause | Fix |
|---|---|---|
| "The top heading of RELEASENOTES.md is '...'; it must read '## vX.Y.Z' ..." | The first `## ` line is prose, misses the `v`, the patch number or has a trailing dash. | Make the first `## ` heading the version, for example `## v1.0.1`. |
| "RELEASENOTES.md has no '## vX.Y.Z' heading" | The file has no `## ` heading at all. | Add the version heading and its lines. |
| "The section '## vX.Y.Z' of RELEASENOTES.md is empty; add the release lines first" | The heading has no lines under it. | Add the release lines; a release without notes is refused. |
| "The tag vX.Y.Z exists on ALCops/...; add a new '## vX.Y.Z' heading to RELEASENOTES.md" | That version was released already (or a tag was created by hand). | Add the next version heading. Never move or delete a released tag: organizations pin to it. |
| "The commit ... has no check run named test: CI has not run on it" | CI did not run on the commit: a dispatch from a branch without a pull request, or a commit whose CI was cancelled. | Open the pull request (or wait for the push CI on `main`) and run the deploy again. |
| "The check run X of ... is in_progress; wait for CI to finish" / "... concluded failure" | CI is running or failed on the commit. | Wait, or fix CI first. |
| "The commit ... has N check runs, more than the M one page returns; check them by hand" | More than 100 check runs on one commit (the deploy reads one page). | Check the runs on the commit page; reduce re-runs, or release a commit with fewer runs. |
| "The checkout has uncommitted changes: ..." / "The checkout is at ..., not at the commit to deploy ..." | Something in the job changed the checkout, or `GITHUB_SHA` is not the checked-out commit. | Should not happen with the shipped workflow; check edits to `Deploy.yaml`. |
| "The deploy needs the variable DEPLOY_APP_ID ... and the secret DEPLOY_APP_PRIVATE_KEY" | The variable or the secret is missing or empty. | Section 7. |
| "The GitHub App ... has no installation on ALCops/..." | The App is not installed on that repository, or the Client ID or the key is wrong. | Install it on both repositories; check the variable and the secret. |
| "The GitHub App ... could not get an installation token for ALCops/... (HTTP 422: ...)" | The App lacks one of the requested permissions (Contents and Workflows write, Checks read). | Add the permission and accept it on the installation. |
| "git push main failed: ... protected ..." on `ALCops/rulebook` | A ruleset refuses the App on the template's `main`: it is not a bypass actor of `protect-main`. Nothing was tagged and no release was created. | Add the App as bypass actor and run the deploy again. |
| "git push preview failed" or "git push preview (create) failed" on `ALCops/rulebook` | The refresh could not write `preview`: a ruleset or a branch protection that targets it, or the App lost access. | `preview` must stay unprotected (section 7); check the App installation, then run the refresh again. |
| "git push v1 failed: ... protected ..." or "git push tag ... failed" on the engine | The template is already pushed and tagged; a ruleset of the engine refused the App. | Add the App as bypass actor, add the next patch heading to `RELEASENOTES.md` and release that (the template tag of this version exists, so the same version is refused). |
| "git push v1 failed: ... stale info" on the engine | Someone moved the engine's `v1` while the run was going (the lease). The template is already pushed and tagged. | Find out who moved `v1`; then release the next patch version (the template tag of this version exists, so the same version is refused). |
| "Could not create the release vX.Y.Z on ALCops/rulebook-engine (HTTP ...)" | Everything was pushed and tagged; only the GitHub Release failed. | Create the release by hand from the tag with the notes section as body (`gh release create vX.Y.Z --notes-file ...`, `--prerelease` for a suffix); both tags exist, so a rerun of the same version is refused. |
| The refresh made no commit | `template/` and the notes did not change since the last refresh. | Nothing to do. |
