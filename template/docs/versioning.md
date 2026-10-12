# Versions of the template

Your rulebook repository follows the template's `main`, which is always the latest release. What following `main` gives you, how to pin a release with a tag, how to read the release notes, what `preview` is, and how a breaking change reaches you as a deprecation instead of a new major version.

> **Status:** written 2026-10-11 with the release work package of the engine ([WP13, #15](https://github.com/ALCops/rulebook-engine/issues/15)) and rewritten the same day for [#104](https://github.com/ALCops/rulebook-engine/issues/104); the decision is [D53](https://github.com/ALCops/rulebook-engine/blob/main/docs/adr/0053-template-main-is-the-release-preview-the-bleeding-edge-and-deprecations-replace-majors.md). How a release is cut is the engine's [releasing.md](https://github.com/ALCops/rulebook-engine/blob/main/docs/releasing.md).

## Contents

1. [What following main means](#1-what-following-main-means)
2. [Pinning a release](#2-pinning-a-release)
3. [Reading the release notes](#3-reading-the-release-notes)
4. [Trying what comes next: preview](#4-trying-what-comes-next-preview)
5. [No major versions: deprecations](#5-no-major-versions-deprecations)
6. [Troubleshooting](#6-troubleshooting)

## 1. What following main means

Two things in your repository name what you run:

- The workflows call the engine's actions as `ALCops/rulebook-engine/actions/<Name>@v1`. Every release moves the engine's `v1`, so an engine fix reaches your workflows at their next run, without a pull request in your repository.
- `templateUrl` in `.github/Rulebook-Settings.json` ends in `@main`. Template content (level and stage files, workflows, this documentation) reaches you through the **Update Rulebook System Files** pull request ([updating.md](updating.md)), which compares your repository with the head of the template's `main`. Every release writes `main`, so following it means taking each release when you merge its update pull request.

Both repositories also carry a tag per release, `v1.0.0`, `v1.0.1` and so on, and the engine's [releases page](https://github.com/ALCops/rulebook-engine/releases) lists each with its notes.

Every release keeps a compatibility promise: a new check of the Validate workflow starts as a warning, settings keys are only added, and no file moves between the classes of [updating.md](updating.md) section 1. A change that cannot keep it arrives as a deprecation (section 5). Only the latest release is supported: a fix lands in the next release, never in an old tag.

## 2. Pinning a release

To stay on one release, set `templateUrl` to end in that release's tag instead of `@main`, for example `@v1.0.0`, and keep `update.schedule` at `null` (the shipped value) so the update only runs when you start it. You can make the change in the run form: Actions > **Update Rulebook System Files** > Run workflow with the template repository URL ending in `@v1.0.0`; the run records the new value in your settings ([updating.md](updating.md) section 2). The update resolves the part after `@` as a branch first and as a tag only when no branch has that name, so a tag pins exactly the commit of that release; tags are never moved.

What a pin holds back, and what it does not:

- Template content stays at the tag until you change `templateUrl` again. To move on, set it to a later tag or back to `@main` and run the update.
- Engine fixes still arrive through `@v1` in your workflows: the pin is on the template, not on the engine.
- Changing `templateUrl` counts as a change of template for the update, so the next run compares with the tag's content without the recorded `templateSha` of the old value. Site and documentation files you customized that differ from the tag are kept and listed in the pull request instead of being compared three ways.

A pin is for holding still while you prepare, not for staying behind: an old tag gets no fixes, and deprecations (section 5) keep their removal dates whether you follow `@main` or not.

## 3. Reading the release notes

Engine fixes always arrive with the next workflow run; template content arrives only when you merge the update pull request. To take template content on your own schedule, keep `update.schedule` at `null` and run the update by hand when you are ready ([updating.md](updating.md) section 6). Validate tells you on every pull request when an update is available.

Every release writes the notes of all versions into `.github/RELEASENOTES.copy.md` of the template. The update pull request quotes the part that is new since the version you have, under "Release notes", so you read what changed before you merge, including any "Deprecations" line. An engine-only release produces a small update pull request too: its only change is that file.

## 4. Trying what comes next: preview

The template's `preview` is the engine's template source as it is right now: its workflows call the engine at `main`, so they run code that is not released yet. The ALCops maintainers run their own rulebook on it as the canary, which receives every change minutes after it is merged and before any release.

You can follow it too: set `templateUrl` to end in `@preview` and run the update. Its pull request switches your workflows to the engine at `main` and records `@preview`. Expect breaking changes without notice. To switch back, set `templateUrl` to end in `@main` again and run the update; its pull request moves your workflows back to `@v1`.

## 5. No major versions: deprecations

The template has no major versions to move between. No deprecation exists today; the warning below appears with the first one. When something has to change in a way your repository would notice (a settings key renamed or removed, a file changing its class, the layout of the published URLs, the secret), it goes through a deprecation:

1. The release that starts it keeps the old form working and says so under "Deprecations" in its release notes, with the replacement and a date some months away.
2. From that release on, every run that meets the old form prints a warning annotation naming the replacement and the date. Validate shows it on your pull requests.
3. You make the change the warning names, at a time that suits you before the date.
4. The first release after the date turns the warning into an error that still names the replacement.

So the only thing to watch is the warnings and the "Deprecations" lines of the update pull requests. The engine's `@v1` in your workflows stays; you do not edit `uses:` lines for a release.

## 6. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| "Could not get the latest commit of https://github.com/ALCops/rulebook@v9.9.9 (HTTP 404: ...)" in the update | `templateUrl` ends in a tag or branch that does not exist: a typo, or a version that was never released. | Check the tags on the engine's [releases page](https://github.com/ALCops/rulebook-engine/releases) and set `templateUrl` to an existing tag, or back to end in `@main`. |
| A workflow fails with "Unable to resolve action `ALCops/rulebook-engine/actions/<Name>@v2`" | The workflow names an engine ref that does not exist, or a typo in the `uses:` line. | Use `@v1`. |
| Your workflows break after an update from `@preview` | `preview` runs unreleased engine code and changes without notice (section 4). | Set `templateUrl` to end in `@main` and run the update, or wait for the fix on `preview`. |
| A warning "... is deprecated; use ... After <date> it is an error." | Your repository uses a form a release deprecated (section 5). | Make the change the warning names before the date; the release notes line has the details. |
| A fix from the release notes is in effect although you did not merge an update | Engine fixes reach your workflows through `@v1` directly (section 1). | Nothing to do; the update pull request still brings the notes and any template content. |
| The update pull request has no "Release notes" section | The template's release notes copy did not change since your installed version, for example after a documentation-only change of `preview` that you follow. | Nothing to do. |
| Validate warns "Updates available" right after you changed `templateUrl` | Your files differ from the template content you now follow. | Run the update and merge its pull request. |
| The update after pinning a tag lists customized files as kept instead of merging them | A change of `templateUrl` is a change of template: the recorded `templateSha` of the old value is not used (section 2). | Merge the listed files by hand if you want the tag's version, or keep yours. |
