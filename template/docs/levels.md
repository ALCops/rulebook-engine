# Levels and starting points

A level is a named set of rule decisions your AL projects build against: Essential, Recommended, Strict and Complete ship with the template, and you can add your own, publish one under another name, turn everything off as a starting point, add a stage or stop publishing one. This page explains what each shipped level contains, how to pick a starting point, and the exact steps and messages for every change to the set.

> **Status:** written 2026-10-09 with WP10 of the engine ([#12](https://github.com/ALCops/rulebook-engine/issues/12)). The pages of the shipped levels are generated in the engine ([docs/levels/](https://github.com/ALCops/rulebook-engine/blob/main/docs/levels/README.md)); the maintainer side is [authoring-levels.md](https://github.com/ALCops/rulebook-engine/blob/main/docs/authoring-levels.md). Statements marked *observed* were seen in the live run on a scratch repository on 2026-10-09; the rest is stated by the engine's code and its tests.

## Contents

1. [What a level is](#1-what-a-level-is)
2. [Picking a starting point](#2-picking-a-starting-point)
3. [Changing the set: the branch route](#3-changing-the-set-the-branch-route)
4. [Adding a level](#4-adding-a-level)
5. [Publishing a level under another name](#5-publishing-a-level-under-another-name)
6. [Everything off](#6-everything-off)
7. [Adding a stage](#7-adding-a-stage)
8. [Removing a level or stage](#8-removing-a-level-or-stage)
9. [How your levels show up](#9-how-your-levels-show-up)
10. [Troubleshooting](#10-troubleshooting)

## 1. What a level is

Levels form a ladder. Each level is the level it is based on plus the rules it changes: its file `base/<slug>.ruleset.json` lists only those changes, and `basedOn` in the settings names the level below. A level without `basedOn` is a root: it changes the analyzer defaults directly. The slug is the lowercased name (`Strict` becomes `strict`) and names every file, endpoint URL and override selector. A level's own file may set any rule higher or lower than the level below; `basedOn` is only the starting point.

The template ships four levels in one ladder:

| Level | Intent | What is on | Default-stage counts (628 diagnostics) | Page |
|---|---|---|---|---|
| Essential (root) | You cannot ship without this. | Definite runtime failures, the Error defaults of PerTenantExtensionCop and AppSourceCop except the marketplace and baseline checks, compiler warnings that become errors later, PlatformCop, a few blockers; everything else off. | 119 Error, 124 Warning, 10 Info, 375 None; the endpoint lists 353 | [essential.md](https://github.com/ALCops/rulebook-engine/blob/main/docs/levels/essential.md) |
| Recommended | What a healthy project runs. | Every rule its analyzer enables by default, at the author's severity, with nine documented deviations. | 128 Error, 391 Warning, 68 Info, 18 Hidden, 23 None; lists 9 | [recommended.md](https://github.com/ALCops/rulebook-engine/blob/main/docs/levels/recommended.md) |
| Strict | The quality gate. | Recommended with default-on Info rules raised to Warning and Hidden ones to Info. | 128 Error, 443 Warning, 29 Info, 5 Hidden, 23 None; lists 68 | [strict.md](https://github.com/ALCops/rulebook-engine/blob/main/docs/levels/strict.md) |
| Complete | Everything the analyzers can tell you. | Strict plus every opt-in rule; off only LC0054 and LC0089i. | 128 Error, 445 Warning, 51 Info, 2 Hidden, 2 None; lists 92 | [complete.md](https://github.com/ALCops/rulebook-engine/blob/main/docs/levels/complete.md) |

Each engine page lists the entries of the level file grouped by analyzer, with the action of the level below ("From"), the new action ("To"), a `lowered` mark where the action goes down, the justification and the docs link, and the counts for every stage. The "lists" figure is the number of diagnostics the endpoint writes: an endpoint names only the rules whose action differs from the analyzer default. The engine pages describe the shipped levels; your own levels get their pages with the dashboard site (WP14). The links resolve once the engine change that adds the pages is merged.

Stages modify the level result per rule: `default` is the level as it is, `CI` relaxes a few postponable diagnostics to Info, `vNext` raises compiler future errors to Error and obsolete-pending diagnostics to Warning. Each stage other than `default` is one file `stages/<slug>.json`, applied on top of every level, and never turns on a rule the level left off.

## 2. Picking a starting point

| You want | Start with | Then |
|---|---|---|
| A sensible baseline with little effort | The closest shipped level | Adjust single rules with overrides through the **Change Rule** workflow ([changing-a-rule.md](changing-a-rule.md), [overrides.md](overrides.md)). |
| Nothing on, and to opt in rule by rule | An everything-off root level of your own (section 6) | Opt in with overrides scoped to `levels: ["off"]`, or move projects to a shipped level later. |
| No maintenance | Any shipped level | Let the update keep it current on a schedule with `update.schedule`, and set `commitOptions.createPullRequest` to `false` if the scheduled run should commit directly instead of opening a pull request ([updating.md](updating.md) section 6; section 7 for the push input). |

Projects choose a level when they download their skeletons (section 9); different projects can use different levels of the same rulebook.

## 3. Changing the set: the branch route

Every change in sections 4 to 8 is a settings edit plus at most one file. The endpoints in `rulesets/`, the skeletons in `skeletons/` and the level and stage lists of the Change Rule form are generated from them. Until they match the settings, Validate fails the pull request with C11 and C12 (*observed* in cards (b) to (e) of the live run), for example:

```text
skeletons/off.default.ruleset.json is missing; every levels x stages entry has one
rulesets/off.ruleset.json would be created; run Update-RulebookEndpoints and commit the result
```

A repository with Validate as a required check cannot merge such a pull request. The way to get the generated files onto it before the merge:

1. Make the change on a branch, push it and open the pull request. Validate fails as expected.
2. Run **Update Rulebook System Files** with "Use workflow from" set to **that branch** and "Resolve the latest commit of the template branch" **off** (the run regenerates from the template version you have, without pulling a new one).
   - With "Push to this branch instead of opening a pull request" **on**, the run commits the endpoints, the skeletons and the form lists directly to the branch (*observed*, card (c)).
   - With it **off**, the run opens its own pull request into that branch; merge that one first (*observed*, cards (d) and (e)).
3. Validate runs again on your pull request and passes (*observed*: 0 errors, 0 warnings). Merge it.

The update pushes to the branch, or opens its pull request, with the write token of the `GHTOKENWORKFLOW` secret ([updating.md](updating.md) section 2, [ghtokenworkflow.md](ghtokenworkflow.md)); because that token and not the workflow's own one is used, Validate runs again on the new head (*observed* with a GitHub App; code-derived for a personal access token).

Alternatives: where merging with a failing check is allowed, merge first and run the update on the default branch; `main` is red until it ran, and Publish stops at its Validate gate in between without publishing anything (*observed*). Or regenerate locally and commit to the branch: clone the `main` branch of [ALCops/rulebook-engine](https://github.com/ALCops/rulebook-engine) next to your repository (as in [quarantine.md](quarantine.md) section 4) and run, in PowerShell 7.4 or newer from the root of your rulebook repository:

```powershell
Import-Module ../rulebook-engine/modules/Rulebook.Generate.psd1
Import-Module ../rulebook-engine/modules/Rulebook.Template.psd1
Update-RulebookEndpoints -RepositoryRoot .
New-RulebookSkeleton -SettingsPath .github/Rulebook-Settings.json -OutputPath skeletons
```

The Change Rule form lists then follow with the next update ([changing-a-rule.md](changing-a-rule.md) section 7).

The update's own pull request or commit may say "No effective change." under its effective diff even though it creates or deletes endpoint files (*observed*): the effective diff compares the inputs of the two commits, and your branch already declares the change. The files are in its change list.

## 4. Adding a level

Add an entry to `levels` at the position where it should appear, and create its file with the rules it changes. To put it into the ladder, point the next level's `basedOn` at it. In the live run a level House between Recommended and Strict (*observed*):

```json
  "levels": [
    { "name": "Essential", "description": "Cannot ship without: runtime failures, the deployment blockers of both Microsoft cops, compiler future errors, PlatformCop." },
    { "name": "Recommended", "basedOn": "Essential", "description": "Every default-on rule at its author severity; marketplace checks join here." },
    { "name": "House", "basedOn": "Recommended", "description": "Recommended plus the house rules." },
    { "name": "Strict", "basedOn": "House", "description": "Recommended with advisory rules promoted to Warning." },
    { "name": "Complete", "basedOn": "Strict", "description": "Strict plus every opt-in rule." }
  ]
```

`base/house.ruleset.json`:

```json
{
  "$schema": "https://raw.githubusercontent.com/ALCops/rulebook-engine/v1/schemas/ruleset.delta.schema.json",
  "name": "Rulebook House",
  "description": "Level house, basedOn recommended. The house rules of this organization.",
  "rules": [
    { "id": "AA0021", "action": "Info", "justification": "House rule: variable order is advisory" }
  ]
}
```

Then take the branch route (section 3). The update added `rulesets/house.ruleset.json`, `house.ci` and `house.vnext`, three skeletons, and `house` to the form; `strict` and `complete` gained AA0021 Info because the last file on the chain that mentions a rule wins and neither Strict nor Complete mentions AA0021 (*observed*). A rule that a higher level's own file sets keeps that level's action: put a house rule there only if no level above it mentions the rule, or use an override.

The file is yours: the update never overwrites a level file the template does not ship.

## 5. Publishing a level under another name

Shipped names are not edited: the shipped file name is what the update overwrites. To publish Essential as Baseline, add this entry to `levels` where Essential was (with a comma between entries) and remove the Essential entry:

```json
    { "name": "Baseline", "basedOn": "Essential", "description": "Essential under the organization's own name (an alias)." }
```

`base/baseline.ruleset.json`:

```json
{
  "$schema": "https://raw.githubusercontent.com/ALCops/rulebook-engine/v1/schemas/ruleset.delta.schema.json",
  "name": "Rulebook Baseline",
  "description": "Level baseline, basedOn essential. Essential under another name: an alias.",
  "rules": []
}
```

Keep the other levels' `basedOn` as they are: Recommended stays based on Essential, whose file stays as an unpublished starting point, so Validate gives no C9 for it (*observed*). After the branch route, the `baseline` endpoints and skeletons replace the `essential` ones; GitHub shows them as renames that change only the name and description lines, because the rules are identical (*observed*). The endpoint URLs change from `essential` to `baseline`: update the projects that used Essential (section 9).

An alias does not inherit overrides scoped to the original slug (code-derived): overrides name slugs, so an entry with `levels: ["essential"]` no longer applies once Essential is not published, and Validate reports it (C10). Retarget such entries to the new slug ([overrides.md](overrides.md) section 2).

## 6. Everything off

There is no shipped everything-off level. You add your own root level with a script that writes `base/off.ruleset.json`: every diagnostic the analyzers enable by default, at None, sorted, without justifications. Run it from the root of a clone of your rulebook repository, with the script saved next to the clone (there is no `.gitignore` to keep it out of a commit):

```powershell
Invoke-WebRequest https://raw.githubusercontent.com/ALCops/rulebook-engine/main/scripts/New-RulebookOffLevel.ps1 -OutFile ../New-RulebookOffLevel.ps1
../New-RulebookOffLevel.ps1
```

It prints (*observed*, 605 of the 628 diagnostics are on by default):

```text
Wrote base/off.ruleset.json (605 ids at None)

Paste this entry first into "levels" of .github/Rulebook-Settings.json:
    { "name": "Off", "description": "Every known diagnostic off. Opt in through overrides." },
```

followed by the next steps of section 3. The script never edits the settings. Paste the entry first in `levels`, then take the branch route. Run it again at any time: it says `base/off.ruleset.json is current (605 ids at None)` and "Already listed in the settings as Off." In a clone with `core.autocrlf` true the file is checked out with CRLF line endings; the script treats that copy as current too and says so (`... only the line endings of the working copy differ`). A file that differs in content (an older catalog, your own edits) is refused unless you pass `-Force`, which overwrites your edits. `-Name` gives the level another name.

The update created `rulesets/off.ruleset.json`, `off.ci` and `off.vnext` with 605 entries each, three skeletons and `'off'` in the form, and left `base/off.ruleset.json` alone (*observed*): the file belongs to your repository.

Opt in with overrides scoped to `levels: ["off"]` ([overrides.md](overrides.md)), or by editing `base/off.ruleset.json`. Diagnostics that appear after the file was written are not in it. In the stages your quarantine policy names they arrive through quarantine and stay `None` ([quarantine.md](quarantine.md) section 2); in a stage the policy does not name, a new default-on rule is active at its analyzer default in Off until you add it to `base/off.ruleset.json` or override it. Two things to know:

- When Off is the only published level, every entry of `stages/ci.json` and `stages/vnext.json` is a C8 warning ("... is None in every published level, so this stage entry never applies"). The stage files are system files; keep them.
- The scan removes a quarantine entry as soon as a file on the chain of any published level mentions the rule. If you also publish a shipped level and an update adds a new rule to its file, the rule leaves quarantine and is active at its analyzer default in Off, unless you add it to `base/off.ruleset.json` ([quarantine.md](quarantine.md) section 4).

## 7. Adding a stage

Add an entry to `stages` and create `stages/<slug>.json` with the rules it changes. In the live run a stage Nightly, inserted in `stages` after CI (*observed*):

```json
    { "name": "Nightly", "description": "Nightly builds: two diagnostics treated differently from the level, for the WP10 live run." }
```

`stages/nightly.json`:

```json
{
  "$schema": "https://raw.githubusercontent.com/ALCops/rulebook-engine/v1/schemas/ruleset.delta.schema.json",
  "name": "Rulebook stage Nightly",
  "description": "Stage nightly. Applied on top of every level where the level result is not None. Organization stage.",
  "rules": [
    { "id": "AW0001", "action": "Info", "justification": "Nightly: web-client layout warnings are advisory" },
    { "id": "LC0043", "action": "Error", "justification": "Nightly: SecretText misuse fails the nightly build" }
  ]
}
```

After the branch route every published level had a `<level>.nightly` endpoint and skeleton and the form listed `nightly`; `strict.nightly` was `strict` plus the two rules, and `off.nightly` equalled `off` because a stage never turns on a rule the level left off (*observed*).

A stage gets a quarantine file `quarantine.<slug>.json` only when `quarantine.stages` or `quarantine.prereleaseStages` names it and a scan finds a new diagnostic ([quarantine.md](quarantine.md) section 2). In the live run the first scan after adding `nightly` to the policy found no new diagnostic and created no file; it created `catalog/scan-state.json`, and from then on Validate treats a rule that is not in the catalog as an error (C7) (*observed*).

## 8. Removing a level or stage

Delete the entry from `levels` or `stages`. The shipped file stays, and the next update would bring it back changed; list it in `unusedRulebookFiles` to have the update delete it and leave it out from then on ([updating.md](updating.md) section 5):

```json
  "unusedRulebookFiles": ["base/complete.ruleset.json"]
```

Then take the branch route. Removing Complete (*observed*): Validate on the pull request reported `skeletons/complete.default.ruleset.json matches no levels x stages entry` and `rulesets/complete.ruleset.json would be deleted; run Update-RulebookEndpoints and commit the result` for each stage, and no C9 because the file was listed; the update deleted `base/complete.ruleset.json`, the three `complete` endpoints and skeletons and `complete` from the form, and no other file changed.

`default` cannot be removed. Do not list a file that a remaining level is based on. Overrides that name a removed slug fail C10 and must go ([overrides.md](overrides.md) section 2); a quarantine file of a removed stage is reported by C16 until you delete it. Projects that used the removed level or stage get a 404 for its endpoint: move them first.

## 9. How your levels show up

After the update (or a local regeneration and the next update for the form):

- **Endpoints**: `rulesets/<level>.ruleset.json` for `default` and `rulesets/<level>.<stage>.ruleset.json` for the other stages, published by the Publish workflow at `<baseUrl>/rulesets/...`.
- **Skeletons**: `skeletons/<level>.<stage>.ruleset.json`, one per stage, offered on the index page at `baseUrl`.
- **Index page and `rulebook.json`**: one row per level in settings order. In the live run `rulebook.json` listed off, baseline, recommended, house, strict and complete (*observed*).
- **Change Rule form**: the level and stage choices follow the settings after one update ([changing-a-rule.md](changing-a-rule.md) section 7). `off` is written quoted (`'off'`) because a bare `off` is a boolean in YAML (*observed*).
- **Init script**: `Get-RulebookSkeletons.ps1 -Level <slug or name>` downloads the skeletons of a published level ([al-project.md](al-project.md)). For a level that is not published it stops with "Level 'essential' is not published at https://arthurvdv.github.io/rulebook-e2e-levels. Published levels: off, baseline, recommended, house, strict, complete (use the slug or the name)." (*observed*).

## 10. Troubleshooting

| Message | Cause | Fix |
|---|---|---|
| "`<path>` is missing; every levels x stages entry has one" (C11) | A level or stage was added; its skeletons do not exist yet. | Take the branch route (section 3). |
| "`<path>` matches no levels x stages entry" (C11) | A level or stage was removed or renamed; its skeletons are still there. | Take the branch route; the update deletes them. |
| "`<path>` would be created; run Update-RulebookEndpoints and commit the result" (also "would be modified", "would be deleted") (C12) | The endpoints do not match the settings and the level and stage files. | Take the branch route, or regenerate locally and commit. |
| "`<path>` is neither a published level nor on the chain of one; publish it, remove it or list it in unusedRulebookFiles" (C9, warning) | A level file without a settings entry that no published level is based on, for example `base/off.ruleset.json` committed before its entry (*observed*). | Add the entry, delete the file, or list it in `unusedRulebookFiles`. |
| "`<path>` is not a stage in the settings; publish it, remove it or list it in unusedRulebookFiles" (C9, warning) | A stage file without a settings entry. | The same. |
| "`<path>` is missing for level '`<Name>`'" (C6) | A settings entry without its `base/<slug>.ruleset.json`. | Create the file (sections 4 to 6). |
| "Unresolved basedOn '`<slug>`' of level '`<Name>`'" or "basedOn cycle: ..." (C5) | `basedOn` names a level file that does not exist, or the chain loops. | Point `basedOn` at an existing `base/<slug>.ruleset.json`. |
| "levels entry '`<Name>`' does not lowercase to a slug matching ^[a-z0-9-]+$" (C5) | A name with a space or another character a slug cannot hold. | Use letters, digits and hyphens. |
| "entry `<n>` names unknown level '`<slug>`'; use a slug from the settings or ["*"]" (or "unknown stage '`<slug>`'") (C10) | An override names a removed or renamed level or stage (also an alias's original slug, section 5). | Retarget or remove the entry. |
| "`<id>` is None in every published level, so this stage entry never applies (S-4)" (C8, warning) | A stage entry for a rule no published level turns on, for example with Off as the only level. | Expected with Off alone; otherwise remove the entry. |
| "`<file>` names no stage of the settings, so its ids are not quarantined anywhere; ..." (C16, warning) | The quarantine file of a removed stage. | Delete it, or add the stage back. |
| "`<id>` is `<Action>`, which level `<slug>` already gives" or "`<id>` is `<Action>`, which the analyzer default already gives" (C9, warning) | An entry in your level file repeats what the level below gives (for example in a House or alias file), or, in a root level file such as `base/off.ruleset.json`, what the analyzer default gives (for example after the catalog changed a default). | Remove the entry. |
| "Updates available: run the Update Rulebook System Files workflow (`<n>` files)" (a warning annotation that does not fail Validate and does not count for `failOnWarning`, [updating.md](updating.md) section 3) | The settings changed the set and the generated files do not follow yet, or the template moved ([updating.md](updating.md) section 3). In the live run the change pull requests showed it with 7, 25, 8 and 11 files (*observed*). | Take the branch route (section 3). |
| "_N of M endpoint tables of the effective diff were left out to keep this body below the GitHub limit; the job summary of the update run has them all._" | Large endpoints (an Off level lists 605 rules) in an update pull request. | Read the job summary of the update run. |
| "No effective change." in an update that creates or deletes endpoints | The branch already declared the change; the effective diff compares inputs, not files (*observed*). | Nothing to fix; the change list shows the files. |
| "Run the script from the root of a clone of your rulebook repository (the folder with .github/Rulebook-Settings.json and catalog/diagnostics.json): `<path>`" | `New-RulebookOffLevel.ps1` ran in another folder. | Change to the clone root, or pass `-RepositoryRoot`. |
| "base/off.ruleset.json exists and differs; it is owned by this repository. Use -Force to overwrite it (your own edits in it are lost)" | The file was written from another catalog or edited since. | Keep it, or rerun with `-Force` to rewrite it from the current catalog. |
| "Cannot read .github/Rulebook-Settings.json (...); the level counts as not listed" (warning) | The settings file is not valid JSON. | The script still writes the file; fix the settings and paste the entry. |
| "base/off.ruleset.json is current (`<n>` ids at None; only the line endings of the working copy differ)" | A clone with `core.autocrlf` true; the content is current. | Nothing to do. |
| "'`<Name>`' is already a published level; -Force would replace base/`<slug>`.ruleset.json with an everything-off file" (warning) | `-Name` names one of your levels, for example `-Name Strict`. | Use another name; `-Force` would replace that level's rules. |
| "Level '`<Name>`' cannot have a page: its slug collides with the index README.md" | A level named README. | Choose another name. |
| "Level '`<slug>`' is not published at `<baseUrl>`. Published levels: ... (use the slug or the name)." | The init script was given a level the settings do not publish, for example after an alias (*observed*). | Use one of the listed levels. |
| The Change Rule form does not offer your new level or stage | The update that rewrites the form lists has not run since the settings change. | Run the update (section 3); [changing-a-rule.md](changing-a-rule.md) section 7. |
