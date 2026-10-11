# Migrating an existing ruleset

How to move an organization that already keeps its rules in ruleset files onto your rulebook: work out what the old files make the compiler do, pick the shipped level that is closest, write the differences as overrides, and compare before you switch the projects over.

> **Status:** written 2026-10-10 with WP11 of the engine ([#13](https://github.com/ALCops/rulebook-engine/issues/13)). The method is manual; there is no migration script yet. It was exercised once on a real layered setup (a shared base and two per-kind overlays, in use by the projects of one organization): after the import the old effective rules and the new endpoint agreed for both kinds of project on the default stage, and the lessons are in section 7. The compiler behaviour is the engine's [compiler-ruleset-internals.md](https://github.com/ALCops/rulebook-engine/blob/main/docs/reference/compiler-ruleset-internals.md).

## Contents

1. [Starting points](#1-starting-points)
2. [What you need](#2-what-you-need)
3. [How the compiler reads your old files](#3-how-the-compiler-reads-your-old-files)
4. [The method](#4-the-method)
5. [Per-kind and stage overlays](#5-per-kind-and-stage-overlays)
6. [Worked example](#6-worked-example)
7. [Lessons from a real migration](#7-lessons-from-a-real-migration)
8. [Troubleshooting](#8-troubleshooting)

## 1. Starting points

| You have | Typical layout |
|---|---|
| A layered tree in blob storage or a folder | A base file every project includes, an overlay per kind of extension (per-tenant, AppSource) and maybe one per stage (CI, next major), and small root files that include the right combination. |
| [StefanMaron/RulesetFiles](https://github.com/StefanMaron/RulesetFiles) or a copy of it | The community files, included by URL, with or without your own additions. |
| One flat ruleset | A single file with `rules` and no includes, copied into the projects or served from a URL. |

All three go the same way: every root file a project points at is one "old effective ruleset" to reproduce.

## 2. What you need

- Your rulebook repository, created and published ([getting-started.md](getting-started.md)).
- Every **root** file a project points at today (`al.ruleSetPath`, `rulesetFile`, `/ruleset:`), and every file they include.
- Which root each kind of project and each pipeline uses, so you know what each one must keep doing.
- The engine's level pages, one per shipped level with every listed rule and its action: [docs/levels](https://github.com/ALCops/rulebook-engine/blob/main/docs/levels/README.md).

## 3. How the compiler reads your old files

The compiler flattens a ruleset tree into one list before it applies it ([compiler-ruleset-internals.md](https://github.com/ALCops/rulebook-engine/blob/main/docs/reference/compiler-ruleset-internals.md) sections 4 to 7). What matters for a migration:

| Rule | Consequence |
|---|---|
| A file's own `rules` beat everything it includes, in both directions. | An entry in the root decides, whatever the includes say. |
| Between sibling includes the **strictest** action wins: Error > Warning > Info > Hidden > Default > None. `None` never wins. | An overlay that sets a rule to `None` cannot switch off a rule a sibling sets; check your overlays for that. |
| An include with action `None` is not loaded at all. | Leave such an include out when you resolve. |
| An include with action `Error`, `Warning`, `Info` or `Hidden` rewrites every rule of that file (and its includes) that is not `None` to that action. | Resolve the child first, then rewrite. |
| A file included twice is read once (the first time); a cycle is cut. | Resolve each file once. |
| `generalAction` sets the action of every id the tree does not list, and can only be raised by includes. | Check every root: Rulebook endpoints cannot carry it. Reproduce it per project with the consumer's own switch (`/warnaserror` for `Error`; the other values have no switch, so list the ids or accept the difference). |
| Any error anywhere in the tree drops the whole tree (AL1033). | In VS Code the editor falls back to the analyzer defaults and shows AL1033 on `app.json`; `alc`, and so AL-Go and other pipelines, stops with exit code 1 and writes no `.app`. |
| Without a `generalAction`, an id the tree does not mention runs at its analyzer default. | "Not mentioned" is a decision too: the default. |

## 4. The method

1. **Resolve each root.** Apply section 3 by hand, depth first: resolve each included file, merge siblings strictest-wins, then write the root's own `rules` on top. Or let the compiler do it: compile a small sample project with `alc` against the root and the analyzers and read the reported actions from the diagnostics; that only shows the ids your sample code triggers, and never shows an id the tree set to `None` or `Hidden`, which is exactly what a migration must carry over; the paper method is the complete one.
2. **Write the old effective list** per root as a table, `id | old action`. Rename the ids of analyzers that changed their numbering first (section 7: BusinessCentral.LinterCop ids are ALCops ids now).
3. **Compare with each shipped level.** For each level, take its endpoint for the stage this root served (`<baseUrl>/rulesets/<level>.ruleset.json` for the editor, `<baseUrl>/rulesets/<level>.ci.ruleset.json` for pipelines) and fill in every unlisted id with its analyzer default (`defaultSeverity` in `catalog/diagnostics.json` of your rulebook, shipped from the engine's [template/catalog/diagnostics.json](https://github.com/ALCops/rulebook-engine/blob/main/template/catalog/diagnostics.json); an id with `enabledByDefault: false` is off). Count the ids where old and new differ, in both directions: an id your tree sets that the level does not, and an id the level lists that your tree left at the default. Pick the level with the fewest differences. A tree that switches nearly everything off starts from an everything-off level instead ([levels.md](levels.md) section 6).
4. **Decide each difference** and write the ones you keep:
   - An id your old tree decided: an entry in `overrides.json` scoped to the level you picked, `levels: ["<slug>"]`, with the stages it applied to (`["*"]` when the old root served every build) ([overrides.md](overrides.md)), or one by one with the Change Rule workflow ([changing-a-rule.md](changing-a-rule.md)).
   - An id the level lists that your tree left at the default: either adopt the level's decision (no entry), or keep the old behaviour with an override at the analyzer default, which makes the id unlisted ([overrides.md](overrides.md) section 5).
   - Per-kind and stage overlays: section 5.
5. **Validate and publish.** Open the change as a pull request; Validate checks the file and the regenerated endpoints (regenerate them in the same pull request, [overrides.md](overrides.md) section 6). Merge, and Publish deploys.
6. **Check one project.** Switch one project to its new skeleton files ([al-project.md](al-project.md) section 3), compile it once against the old root and once against the new skeleton, and compare the diagnostics. They should agree on every id you decided to keep; the ids you adopted from the level, and the stage changes of your rulebook, are the expected differences. Where another id differs, go back to step 4.
7. **Switch the rest**, one consumer at a time, and remove the old files once nothing points at them.

## 5. Per-kind and stage overlays

**Per-tenant versus AppSource.** Rulebook has no per-kind dimension: one rulebook serves both kinds, and both Microsoft cops run at their native severity ([pte-or-appsource.md](pte-or-appsource.md)). So an old overlay that switches off the rules written for the other kind of extension does not become a level or a per-level override:

- If every project of the organization is of one kind, set `twins` (`pte` or `appsource`): the losing side of the 17 rule pairs that check the same thing goes to `None` in every endpoint ([pte-or-appsource.md](pte-or-appsource.md) section 7). The blockers that are not pairs (AS0084, AS0013 and the others of [pte-or-appsource.md](pte-or-appsource.md) section 2) are not covered by `twins`; write them as `overrides.json` entries with `levels: ["*"]`, or use the project-side routes below.
- Otherwise keep `twins` at `both`, and move the overlay into the projects: don't run the other kind's cop (route A), list the ids in `suppressWarnings` when the endpoint does not list them (route B), or put them into the `rules` of each stage file (route C, exact; [pte-or-appsource.md](pte-or-appsource.md) sections 3 to 6, with ready-made lists).
- An overlay entry that is not about the other kind (a CodeCop or ALCops rule set differently for one kind) belongs in the projects of that kind too, in their stage files.

**Stage overlays.** An overlay for CI or next-major builds maps onto the stages of your rulebook: write its differences as overrides with `stages: ["ci"]` (or the stage it served). Resolve it inside its old root first: an overlay entry that a sibling out-ranks (section 3) never had an effect, and reproducing the old behaviour means leaving it out.

## 6. Worked example

A synthetic tree of three rule files and two root files, all includes with action `Default`:

```json
// editor.ruleset.json
{
  "name": "Contoso editor",
  "includedRuleSets": [
    { "action": "Default", "path": "./base.ruleset.json" },
    { "action": "Default", "path": "./pte.ruleset.json" }
  ]
}
// build.ruleset.json
{
  "name": "Contoso build",
  "includedRuleSets": [
    { "action": "Default", "path": "./base.ruleset.json" },
    { "action": "Default", "path": "./pte.ruleset.json" },
    { "action": "Default", "path": "./ci.ruleset.json" }
  ]
}
// base.ruleset.json
{
  "name": "Contoso base",
  "rules": [
    { "id": "AA0137", "action": "Error" },
    { "id": "AA0021", "action": "None" },
    { "id": "AA0247", "action": "Warning" },
    { "id": "AA0215", "action": "Warning" },
    { "id": "AL0432", "action": "Warning" },
    { "id": "AA0072", "action": "Warning" }
  ]
}
// pte.ruleset.json
{
  "name": "Contoso per-tenant overlay",
  "rules": [
    { "id": "AS0084", "action": "None" },
    { "id": "AS0013", "action": "None" }
  ]
}
// ci.ruleset.json
{
  "name": "Contoso CI overlay",
  "rules": [
    { "id": "AL0432", "action": "None" },
    { "id": "AA0215", "action": "None" },
    { "id": "AA0206", "action": "Info" }
  ]
}
```

**Step 1, resolve.** `editor` is base plus pte; no id is in both. In `build`, the ci overlay is a sibling of base: AL0432 and AA0215 are `Warning` in base and `None` in ci, and `None` never wins, so both stay `Warning`. The ci overlay only adds AA0206.

**Step 2 and 3, compare with Recommended** (its `recommended` and `recommended.ci` endpoints, unlisted ids at their analyzer default from the catalog):

| Id | Old `editor` | Old `build` | Analyzer default | Recommended | Recommended CI | Decision |
|---|---|---|---|---|---|---|
| AA0137 | Error | Error | Warning | (default) | (default) | override `Error`, every stage |
| AA0021 | None | None | Warning | (default) | (default) | override `None`, every stage |
| AA0247 | Warning | Warning | Info | (default) | (default) | override `Warning`, every stage |
| AA0215 | Warning | Warning | Warning | (default) | (default) | nothing: equal |
| AL0432 | Warning | Warning | Warning | Info | Info | override `Warning`, every stage (keeps the old behaviour; the ci overlay never had an effect) |
| AA0072 | Warning | Warning | off | (default) | (default) | override `Warning`, every stage |
| AA0206 | (default) | Info | Warning | (default) | (default) | override `Info`, stage `ci` |
| AS0084, AS0013 | None | None | Error | (default) | (default) | per-tenant projects: `suppressWarnings` (the endpoint does not list them, section 5) |
| AL0801, AL1412, AA0251, AA0252, AA0476, AS0075, AS0089, AS0099 | (default) | (default) | various | listed | listed | adopt the level (no entry) |
| AL0472, AL0473, AL0479, AL0603, AL1026, AL1029, AL1030 | (default) | (default) | Warning | (default) | Info | adopt the stage (no entry) |

Recommended differs in 15 ids for `editor` and 23 for `build`; the other shipped levels differ in many more, so Recommended is the starting point. Eight of the differences are decisions of the level that the old tree never made, and for `build` seven more come from the CI stage file (compiler warnings at Info); the example adopts them.

**Step 4, the overrides:**

```json
{
  "$schema": "https://raw.githubusercontent.com/ALCops/rulebook-engine/v1/schemas/rulebook-overrides.schema.json",
  "rules": [
    { "id": "AA0137", "action": "Error", "levels": ["recommended"], "stages": ["*"], "justification": "Migrated: base" },
    { "id": "AA0021", "action": "None", "levels": ["recommended"], "stages": ["*"], "justification": "Migrated: base" },
    { "id": "AA0247", "action": "Warning", "levels": ["recommended"], "stages": ["*"], "justification": "Migrated: base" },
    { "id": "AL0432", "action": "Warning", "levels": ["recommended"], "stages": ["*"], "justification": "Migrated: base; the ci overlay never applied" },
    { "id": "AA0072", "action": "Warning", "levels": ["recommended"], "stages": ["*"], "justification": "Migrated: base" },
    { "id": "AA0206", "action": "Info", "levels": ["recommended"], "stages": ["ci"], "justification": "Migrated: ci overlay" }
  ]
}
```

The per-tenant projects add `"suppressWarnings": ["AS0084", "AS0013"]` to their `app.json`. Then step 5 to 7.

## 7. Lessons from a real migration

The exercise on a real setup (a shared base, a per-tenant overlay with mostly AppSourceCop entries, an AppSource overlay with a handful; two roots, no stages) gave:

- **Rename LinterCop ids first.** The old tree used BusinessCentral.LinterCop ids. Of 48, only 12 kept their number in ALCops; 36 moved to another analyzer (ApplicationCop, DocumentationCop, FormattingCop, PlatformCop, TestAutomationCop) or to another LinterCop number, and across the whole table a few split in two or were dropped. Translate them with the [LinterCop migration table](https://alcops.dev/docs/lintercop-migration/) before step 3, or let the [migration script](https://alcops.dev/docs/lintercop-migration-script/) rewrite the ids in your ruleset files, then check the split and merged rules by hand; otherwise Validate reports them as unknown (C7), or worse, an unchanged number now means another rule.
- **Count differences in both directions.** Most of the differences to the closest level were ids the level lists and the old tree never mentioned. Decide those deliberately (section 4, step 4); reproducing the old tree exactly took one override per difference.
- **One rulebook for both kinds.** With per-tenant and AppSource projects in one organization, `twins` stays `both`, the organization overrides follow the AppSource root (the per-tenant cop's ids follow the per-tenant root), AppSource projects simply do not run the per-tenant cop, and per-tenant projects carry the per-tenant overlay in their stage files: about 130 entries, nearly all AppSourceCop. Disabling AppSourceCop in those projects instead (route A) is shorter, but it would also switch off the AppSourceCop rules that are newer than the old overlay, which the old setup still ran.
- **Old trees have no stages.** Scoping every override to `stages: ["*"]` keeps the old behaviour for those ids in every build; the ids you did not override pick up the stage changes of your rulebook (CI relaxes postponable diagnostics), which is usually wanted but is a change.
- **Compare against the regenerated endpoint, not the files.** After writing the overrides, regenerate and compare the old effective list with the new endpoint plus the catalog defaults (and, per kind, the project's own rules): zero differences for both roots on the default stage was the exit criterion (the ci and vnext endpoints differ by design and were not compared).

## 8. Troubleshooting

| Message | Cause | Fix |
|---|---|---|
| C7 "`<id>` is not in catalog/diagnostics.json (...)" on your `overrides.json` | An id you copied from the old tree is unknown to your catalog: a renamed LinterCop id, a typo, or a rule the analyzers no longer ship (a warning until the first scan, an error after). | Rename it (section 7), fix it, or drop it. |
| The Change Rule run reports a no-op for an entry you expected | The level already gives that action: the entry would be dead ([changing-a-rule.md](changing-a-rule.md) section 4). | Nothing to do; it was not a difference. |
| A project reports a rule stricter than the old tree seemed to say | A sibling include out-ranked the overlay you read (strictest wins, section 3), so the old effective action was stricter than its overlay. | Resolve the old root again; reproduce the effective action, not the overlay. |
| An overlay's rules never applied in the old setup | It was included with action `None`, which does not load the file. | Leave it out of the resolution. |
| The old root fails with AL1033 when you compile against it | One file of the old tree cannot be loaded and the compiler discards the whole tree: the editor then runs on the analyzer defaults, while `alc` and pipelines stop with exit code 1. | Repair the old file and resolve the repaired tree; use the analyzer defaults as the old effective list only for a root you know ran that way (editor only). |
| Step 6 shows differences in one kind of project only | The per-kind overlay was not moved into those projects. | Add the project-side entries of section 5. |
