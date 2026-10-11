# Releasing the engine and the template

How a version of Rulebook reaches organizations: the branches that move, cutting a release, a hotfix, what `v1` promises, majors, the refresh of the bleeding-edge branch, the one-time repository settings and what to do when the deploy refuses.

> **Status:** written by WP13 ([#15](https://github.com/ALCops/rulebook-engine/issues/15)). The decision is [D52](adr/0052-releases-are-a-floating-major-branch-cut-from-hand-written-release-notes.md). Code: `modules/Rulebook.Deploy.psm1`, `tools/deploy/Invoke-Deploy.ps1`, `tools/deploy/keep.txt`, `.github/workflows/Deploy.yaml`, `.github/workflows/RefreshTemplate.yaml`; tests: `tests/Rulebook.Deploy.Tests.ps1`. The user-facing page is [template/docs/versioning.md](../template/docs/versioning.md).

## Contents

1. [The branches and what moves](#1-the-branches-and-what-moves)
2. [Cutting a release](#2-cutting-a-release)
3. [A hotfix](#3-a-hotfix)
4. [What v1 promises](#4-what-v1-promises)
5. [Majors](#5-majors)
6. [The refresh and the canary](#6-the-refresh-and-the-canary)
7. [Repository settings and human steps](#7-repository-settings-and-human-steps)
8. [Troubleshooting](#8-troubleshooting)

## 1. The branches and what moves

| Repository | Branch or tag | What it is | Moved by |
|---|---|---|---|
| `ALCops/rulebook-engine` | `main` | Development. Pull requests only. | merges |
| `ALCops/rulebook-engine` | `v1` | The released engine every organization's workflows run (`uses: ALCops/rulebook-engine/actions/<Name>@v1`). Always a commit that was the head of `main` or of a pull request branch when it was released. | the Deploy workflow |
| `ALCops/rulebook-engine` | `v1.x.y` tags | One per release, with a GitHub Release whose body is the notes section. | the Deploy workflow |
| `ALCops/rulebook` | `v1` (the default branch) | The engine's `template/` with every reference to the engine and the template on `main` rewritten to `v1`, plus `.github/RELEASENOTES.copy.md` and the kept files. "Use this template" copies it; `templateUrl` of an organization ends in `@v1`. | the Deploy workflow |
| `ALCops/rulebook` | `v1.x.y` tags | The template commit of each release (no GitHub Release). | the Deploy workflow |
| `ALCops/rulebook` | `main` | The engine's `template/` verbatim (it says `main` everywhere) plus the release notes copy: the bleeding edge the canary rulebook follows. | the Refresh Template workflow |

Engine and template share one version number because they are released together. The version is the top heading of [RELEASENOTES.md](../RELEASENOTES.md): `## v1.0.1`, or with a prerelease suffix `## v1.1.0-beta.1`. Nothing else names the version; the deploy derives the branch (`v<major>`) and the tag from it.

The rewrite is one rule (`Convert-DeployReference`): `main` after `ALCops/rulebook` or `ALCops/rulebook-engine` as `@main`, `/main/` (raw URLs), `/blob/main/`, `/raw/main/`, `/tree/main/` or `/actions/<Name>@main` becomes the branch. `branches: [ main ]`, "the main branch", `maintain` and `rulebook-engine-main` stay. It runs on `.md`, `.yaml`, `.yml`, `.json`, `.ps1`, `.txt` and `.html` files and keeps their encoding and line endings; binary files are copied as they are. The engine's own `v1` is never rewritten: code names no branch and builds every URL from the ref it runs at (`Get-RulebookEngineRef` of `Rulebook.Common`).

## 2. Cutting a release

1. **Notes.** Every pull request adds its line under the top heading of `RELEASENOTES.md` (CONTRIBUTING section 7). To release, make sure the top heading is the version to release and its section lists what changed in words an organization understands. The first pull request after a release adds the next heading. For a release that only changes the engine (a fix), the section says so: organizations still get an update pull request whose only change is the notes copy.
2. **Merge** the last pull request. CI must be green on the commit you release: the deploy refuses a commit whose latest check runs are not all completed with success or skipped, or that has no check run named `test`.
3. **Dry run.** Actions > Deploy > Run workflow with *dryRun* on, or `gh workflow run Deploy.yaml -R ALCops/rulebook-engine -f dryRun=true`. The job summary shows the version, the branch, the files the rewrite changes and the notes section, and "DRY RUN: nothing pushed". The dry run exchanges the App tokens and runs every check, so a missing setting shows up here.
4. **Release.** The same without *dryRun*: `gh workflow run Deploy.yaml -R ALCops/rulebook-engine`. The run, in this order: clones `ALCops/rulebook@v1` (the first release of a major: clones the default branch and pushes its head as `v1`, so the history continues), replaces everything but `.git` and the keep list `tools/deploy/keep.txt` with `template/`, writes `.github/RELEASENOTES.copy.md`, rewrites the references to `v1`, commits `Release <version> from ALCops/rulebook-engine@<sha7>` when something changed, pushes `v1` and tags its head; then moves the engine's `v1` to the released commit (a push forced under a lease: it refuses when someone else moved `v1` since the run read it), tags it, and creates the GitHub Release (marked prerelease when the version has a suffix).
5. **Verify** the summary table (engine branch and tag, template commit and tag, release URL). Then the canary and any scratch repository: run **Update Rulebook System Files** there; the pull request body's release notes section is the new section.

A dispatch with `--ref <branch>` (`gh workflow run Deploy.yaml --ref <branch>`) runs the workflow file of that branch and releases that branch's head, whose pull request CI must be green. That is how a prerelease is cut from a pull request before its merge; the next release from `main` moves `v1` to the squash commit, which is not a descendant of the branch commit, so the engine push is forced (under the lease).

## 3. A hotfix

There is no maintenance branch within a major. A fix goes to `main` through a pull request like any change, with its line under a new patch heading (`## v1.0.2`), and the deploy releases `main`. `v1` is always a move of `main` within a major; work on `main` that is not ready to be released waits behind a feature switch or in its pull request.

## 4. What v1 promises

`v1` floats: a release reaches every organization's workflows at their next run. That works only while every 1.x release is safe for every organization on 1.x, so within a major:

- A new Validate check starts as a warning; it becomes an error only in a new major.
- Settings keys are only added, never renamed or removed, and a new key has a default that keeps today's behaviour.
- No file moves between the file classes of the update (system, settings, generated, org-owned, customizable).
- Schemas only loosen: a file that validated keeps validating.
- The published endpoint URL layout and the secret contract (`GHTOKENWORKFLOW`, D44) do not change.

This is a written policy, not a CI check. A reviewer who sees a pull request break one of these asks for a major (section 5) or a different design.

## 5. Majors

A new major is triggered by content: a change the update pull request alone cannot carry an organization across safely (a settings key renamed or removed, a file changing its class, a new endpoint URL layout, a new secret contract). New levels, rules, optional settings keys, workflows and fixes stay 1.x. Only the latest major gets releases.

1. The last 1.x release before `v2` starts its section with the note that `v2` is available and what moving needs; organizations pinned to `v1` read it in their update pull request.
2. The `v2` work happens on `main`; the heading becomes `## v2.0.0` (or `## v2.0.0-beta.1` first), and the deploy creates `v2` on both repositories from that heading.
3. A human switches the default branch of `ALCops/rulebook` to `v2` (section 7), so "Use this template" gives `v2`.
4. `v1` stays where it is on both repositories and receives nothing more. Organizations move by editing `templateUrl` and the five `uses:` lines and running the update ([versioning.md](../template/docs/versioning.md) section 4).

## 6. The refresh and the canary

The Refresh Template workflow runs on every push to engine `main` that touches `template/**`, `RELEASENOTES.md` or the workflow file, and by hand (Actions > Refresh Template). It copies `template/` and the release notes copy to `ALCops/rulebook@main` with the same keep list, rewrites nothing, and commits `Refresh from ALCops/rulebook-engine@<sha7>` only when something changed: a run on unchanged content makes no commit. It needs no version and checks only that the checkout is clean and at the pushed commit.

The maintainers' own rulebook is the canary: an ordinary organization repository whose `templateUrl` ends in `@main`. Its update pull request keeps its workflows on the engine at `main`, so it runs unreleased engine code on every run and receives template content minutes after a merge. An engine branch cannot be run this way (the update rewrites the `uses:` lines back); a risky change is tried in pull request CI and in a scratch repository.

## 7. Repository settings and human steps

The deploy authenticates as a GitHub App owned by the ALCops organization and pushes directly; it changes no setting itself. These are done once, by an organization owner, before the first release:

| Setting | Value |
|---|---|
| GitHub App (Org settings > Developer settings > GitHub Apps > New) | Any name (for example "Rulebook Deploy"); homepage `https://github.com/ALCops/rulebook-engine`; webhook off; repository permissions **Contents: Read and write**, **Workflows: Read and write**, **Checks: Read**, Metadata: Read (implied); installable on this account only. Generate a private key (a `.pem` download). Install it on `ALCops/rulebook-engine` and `ALCops/rulebook` only. |
| Engine variable `DEPLOY_APP_ID` | The App's **Client ID** (`Iv23li...`), not the numeric App ID. `gh variable set DEPLOY_APP_ID -R ALCops/rulebook-engine --body <client-id>` |
| Engine secret `DEPLOY_APP_PRIVATE_KEY` | The whole PEM. `gh secret set DEPLOY_APP_PRIVATE_KEY -R ALCops/rulebook-engine < key.pem` |
| `ALCops/rulebook` ruleset `protect-main` | The App as the only bypass actor (`actor_type` `Integration`, `actor_id` the numeric App ID, `bypass_mode` `always`). The ruleset targets the default branch: today `main`, which the refresh pushes; after the switch below `v1`, which the release pushes. |
| Ruleset `protect-release` on both repositories | Branches `refs/heads/v*`: restrict updates, restrict deletions, block force pushes; bypass: the App only. The engine push is forced and still passes, because the App bypasses. |
| Ruleset `protect-release-tags` on both repositories | Tags `refs/tags/v*`: restrict creations, updates and deletions; bypass: the App only. |
| Actions on `ALCops/rulebook` | Disabled (Settings > Actions > General > Disable actions, or `gh api -X PUT repos/ALCops/rulebook/actions/permissions -F enabled=false`). Its shipped workflows are meant for organization repositories: Publish would fail at the Pages preflight on every push and the scan would open pull requests in the template. |
| Default branch of `ALCops/rulebook` | `v1`, switched after the first release has created it (`gh api -X PATCH repos/ALCops/rulebook -f default_branch=v1`). |
| Engine ruleset `protect-main` | Unchanged: `main` keeps taking pull requests only. |

The rulesets are created with `gh api --method POST repos/<owner>/<repo>/rulesets --input <file>.json`; a change to an existing one is a PUT of the full ruleset as a GET returns it (`gh api repos/ALCops/rulebook/rulesets/24422193`). The CONTRIBUTING section 6 table records what is applied.

## 8. Troubleshooting

| Message | Cause | Fix |
|---|---|---|
| "The top heading of RELEASENOTES.md is '...'; it must read '## vX.Y.Z' ..." | The first `## ` line is prose, misses the `v`, the patch number or has a trailing dash. | Make the first `## ` heading the version, for example `## v1.0.1`. |
| "RELEASENOTES.md has no '## vX.Y.Z' heading" | The file has no `## ` heading at all. | Add the version heading and its lines. |
| "The section '## vX.Y.Z' of RELEASENOTES.md is empty; add the release lines first" | The heading has no lines under it. | Add the release lines; a release without notes is refused. |
| "The tag vX.Y.Z exists on ALCops/...; add a new '## vX.Y.Z' heading to RELEASENOTES.md" | That version was released already (or a tag was created by hand). | Add the next version heading. Never move or delete a released tag. |
| "The commit ... has no check run named test: CI has not run on it" | CI did not run on the commit: a dispatch from a branch without a pull request, or a commit whose CI was cancelled. | Open the pull request (or wait for the push CI on `main`) and run the deploy again. |
| "The check run X of ... is in_progress; wait for CI to finish" / "... concluded failure" | CI is running or failed on the commit. | Wait, or fix CI first. |
| "The checkout has uncommitted changes: ..." / "The checkout is at ..., not at the commit to deploy ..." | Something in the job changed the checkout, or `GITHUB_SHA` is not the checked-out commit. | Should not happen with the shipped workflow; check edits to `Deploy.yaml`. |
| "The deploy needs the variable DEPLOY_APP_ID ... and the secret DEPLOY_APP_PRIVATE_KEY" | The variable or the secret is missing or empty. | Section 7. |
| "The GitHub App ... has no installation on ALCops/..." | The App is not installed on that repository, or the Client ID or the key is wrong. | Install it on both repositories; check the variable and the secret. |
| "The GitHub App ... could not get an installation token for ALCops/... (HTTP 422: ...)" | The App lacks one of the requested permissions (Contents and Workflows write, Checks read). | Add the permission and accept it on the installation. |
| "git push v1 failed: ... protected ..." on `ALCops/rulebook` or the engine | A ruleset refuses the App: it is not a bypass actor of `protect-main` (template) or `protect-release`. Nothing was tagged and no release was created when the template push failed. | Add the App as bypass actor and run the deploy again. |
| "git push v1 failed: ... stale info" on the engine | Someone moved the engine's `v1` while the run was going (the lease). The template is already pushed and tagged. | Find out who moved `v1`; when the template tag exists, release the next patch version instead of retrying the same one. |
| "Could not create the release vX.Y.Z on ALCops/rulebook-engine (HTTP ...)" | Everything was pushed and tagged; only the GitHub Release failed. | Create the release by hand from the tag with the notes section as body (`gh release create vX.Y.Z --notes-file ...`, `--prerelease` for a suffix). |
| The refresh made no commit | `template/` and the notes did not change since the last refresh. | Nothing to do. |
