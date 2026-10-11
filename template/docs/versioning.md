# Versions of the template

Your rulebook repository follows a release branch of the template, `v1` today. What that branch gives you, how to hold content back, what the development branch `main` is, and how you move to a new major version.

> **Status:** written 2026-10-11 with the release work package of the engine ([WP13, #15](https://github.com/ALCops/rulebook-engine/issues/15)); the decision is [D52](https://github.com/ALCops/rulebook-engine/blob/main/docs/adr/0052-releases-are-a-floating-major-branch-cut-from-hand-written-release-notes.md). How a release is cut is the engine's [releasing.md](https://github.com/ALCops/rulebook-engine/blob/main/docs/releasing.md).

## Contents

1. [What v1 means](#1-what-v1-means)
2. [Holding content back and reading the release notes](#2-holding-content-back-and-reading-the-release-notes)
3. [The development branch main](#3-the-development-branch-main)
4. [Moving to a new major version](#4-moving-to-a-new-major-version)
5. [Troubleshooting](#5-troubleshooting)

## 1. What v1 means

Two things in your repository name the release branch:

- The workflows call the engine's actions as `ALCops/rulebook-engine/actions/<Name>@v1`. Every 1.x release moves the engine's `v1` branch, so an engine fix reaches your workflows at their next run, without a pull request in your repository.
- `templateUrl` in `.github/Rulebook-Settings.json` ends in `@v1`. Template content (level and stage files, workflows, this documentation) reaches you through the **Update Rulebook System Files** pull request ([updating.md](updating.md)), which compares your repository with the head of the template's `v1` branch.

Both repositories also carry a tag per release, `v1.0.0`, `v1.0.1` and so on, and the engine's [releases page](https://github.com/ALCops/rulebook-engine/releases) lists each with its notes.

Within a major version the template keeps a compatibility promise: a new check of the Validate workflow starts as a warning, settings keys are only added, and no file moves between the classes of [updating.md](updating.md) section 1. A change that breaks one of these is a new major version (section 4). Only the latest major version gets releases: when `v2` ships, `v1` stays where it is and receives no more fixes.

## 2. Holding content back and reading the release notes

Engine fixes always arrive with the next workflow run; template content arrives only when you merge the update pull request. To take template content on your own schedule, keep `update.schedule` at `null` (the shipped value) and run the update by hand when you are ready ([updating.md](updating.md) section 6). Validate tells you on every pull request when an update is available.

Every release writes the notes of all versions into `.github/RELEASENOTES.copy.md` of the template. The update pull request quotes the part that is new since the version you have, under "Release notes", so you read what changed before you merge. An engine-only release produces a small update pull request too: its only change is that file.

## 3. The development branch main

The template's `main` branch is the engine's template source as it is right now: its workflows call the engine at `main`, so they run code that is not released yet. The ALCops maintainers run their own rulebook on it as the canary, which receives every change minutes after it is merged and before any organization gets it.

You can follow it too, to try what comes next: set `templateUrl` to the same template repository with `@main` instead of `@v1` at the end and run the update. Its pull request switches your workflows to the engine at `main`. Expect breaking changes without notice; switch back by setting `templateUrl` to end in `@v1` again and running the update.

## 4. Moving to a new major version

A major version exists because the update alone cannot carry a repository across: a settings key was renamed or removed, a file changed its class, the layout of the published URLs changed, or the secret changed. The last 1.x release notes say that `v2` is available and what it needs from you; the `v2` notes list each step. In outline:

1. Read the notes of the new major version and make the changes they name in your settings.
2. Set `templateUrl` to end in `@v2`, and change the five `uses:` lines of your workflows from `@v1` to `@v2`, so that the new engine runs the update.
3. Run **Update Rulebook System Files** and review the pull request: it brings the workflows, the level and stage files and the documentation of `v2`.

Until you do, your repository keeps running `v1`, which keeps working but receives no fixes.

## 5. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| "Could not get the latest commit of https://github.com/ALCops/rulebook@v2 (HTTP 404: ...)" in the update | `v2` is not released yet. | Set `templateUrl` back to end in `@v1`. |
| A workflow fails with "Unable to resolve action `ALCops/rulebook-engine/actions/<Name>@v2`" | The workflow names an engine branch that does not exist yet, or a typo in the `uses:` line. | Use `@v1` until the release notes announce `v2`. |
| A fix from the release notes is in effect although you did not merge an update | Engine fixes reach your workflows through `@v1` directly (section 1). | Nothing to do; the update pull request still brings the notes and any template content. |
| The update pull request has no "Release notes" section | The template's release notes copy did not change since your installed version, for example after a documentation-only change of `main` that you follow. | Nothing to do. |
| Validate warns "Updates available" right after you changed `templateUrl` | Your files differ from the branch you now follow. | Run the update and merge its pull request. |
