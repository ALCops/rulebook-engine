# Template content

What `template/` holds, where each file comes from, and how to regenerate it after a change to the level content in `docs/rulebook/`. WP13 deploys `template/` to `ALCops/rulebook`, and an organization creates its rulebook repository from that template.

> **Status:** written by WP04 ([#6](https://github.com/ALCops/rulebook-engine/issues/6)). The generator contract is [rulebook/composition.md](../rulebook/composition.md) section 3; file names and schemas are in [naming.md](naming.md); the module is described in [ARCHITECTURE.md](../ARCHITECTURE.md) section 5.6.

---

## Contents

1. [Files](#1-files)
2. [Derivations](#2-derivations)
3. [Build-Template.ps1](#3-build-templateps1)
4. [Keeping template/ current](#4-keeping-template-current)
5. [The seed catalog](#5-the-seed-catalog)
6. [The base URL and {BASEURL}](#6-the-base-url-and-baseurl)

---

## 1. Files

44 files: 12 written by hand, 32 generated. The class is what the update workflow does with the file in an organization repository ([ARCHITECTURE.md](../ARCHITECTURE.md) section 7.3).

| Path | Class | Origin |
|---|---|---|
| `.github/Rulebook-Settings.json` | settings | Hand-written: the `template-default.json` settings fixture with `"baseUrl": ""` |
| `.github/workflows/Validate.yaml` | system | Hand-written (WP03) |
| `.github/workflows/Publish.yaml` | system | Hand-written (WP05) |
| `.github/workflows/UpdateRulebookSystemFiles.yaml` | system | Hand-written (WP07): the update workflow with `{TEMPLATEURL}` and no `schedule:` (`update.schedule` ships `null`) |
| `.github/workflows/ScanDiagnostics.yaml` | system | Hand-written (WP08): the scan workflow with its `schedule:` as the last key under `on:`, the cron of `scan.schedule` (`17 4 * * *`), so the update's rewrite leaves it unchanged |
| `.github/workflows/ChangeRule.yaml` | system | Hand-written (WP09): the change form with the `levels` and `stages` choice lists of the shipped slugs, laid out so the update's rewrite (D30) reproduces it byte for byte with the shipped settings and adds an organization's own slugs; the later workflows come with their work packages |
| `README.md` | never touched after creation | Hand-written, organization-facing |
| `overrides.json` | org-owned | Hand-written: `$schema` and `"rules": []` |
| `quarantine.default.json`, `quarantine.ci.json`, `quarantine.vnext.json` | org-owned | Hand-written: `$schema` and `"rules": []` |
| `base/essential.ruleset.json`, `recommended`, `strict`, `complete` | system | `Build-RulebookBase` |
| `base/twins.json` | system | `Build-RulebookBase` |
| `stages/ci.json`, `stages/vnext.json` | system | `Build-RulebookStages` |
| `catalog/diagnostics.json` | org-owned | `Build-RulebookCatalog` (the seed, section 5) |
| `skeletons/<level>.<stage>.ruleset.json` (12) | generated | `New-RulebookSkeleton`, from the settings (the update regenerates them from the organization's settings) |
| `skeletons/README.md` | system | Hand-written (WP06): what the skeletons are, the init script, the settings and the exceptions; not published, exempt from C11. `New-RulebookSkeleton` deletes only `*.ruleset.json`, so it survives a regeneration |
| `rulesets/<level>[.<stage>].ruleset.json` (12) | generated | `Update-RulebookEndpoints` (Rulebook.Generate, WP03) |

There is no placeholder for files that later work packages own: no workflows besides Validate, Publish, UpdateRulebookSystemFiles, ScanDiagnostics and ChangeRule, no `catalog/scan-state.json` (the first scan creates it), no `.github/RELEASENOTES.copy.md` (the deploy step writes it, D38), no `docs/`, no `site/` (WP14). `docs/` lives in `ALCops/rulebook` ([D50](../adr/0050-docs-is-a-customizable-file-class-and-the-installed-commit-is-recovered.md)): the deploy workflow (WP13) keeps `docs/` in its keep list, and the update treats the shipped pages as customizable. The shipped README links those pages, so the deploy must keep `docs/` or the links 404.

Every generated file is UTF-8 without BOM, LF, with a trailing LF, and its text depends on the inputs only (no date, commit or machine path), so regenerating unchanged inputs gives the same bytes.

## 2. Derivations

Let `cell(id, level, stage)` be the value in `docs/rulebook/matrix/resolved.json`, and `default(id)` the inventory `Default` when `Enabled` is true, else `None` (composition.md section 3; the seed catalog gives the same value).

| File | Entries | Source |
|---|---|---|
| Root level (`essential`, no `basedOn`) | every id where `cell(id, level, default) != default(id)` | `resolved.json` key `<slug>.default` |
| Every other level | every id where `cell(id, level, default) != cell(id, basedOn, default)` | the same file |
| Stage file (`ci`, `vnext`) | every id whose `matrix.json` column named after the stage (`CI`, `vNext`) is not `=`, with that action | `matrix.json` |
| `base/twins.json` | the pairs of `matrix/twins.json`, sorted by `Get-DiagnosticSortKey` of the PTE side | `matrix/twins.json` |

- Entries follow the inventory order, which is ascending `Get-DiagnosticSortKey` (check V1). The generators never re-sort; the Template suite asserts the order of every file.
- Every level and stage entry carries the `Justification` of its matrix row, verbatim; a stage entry has the same text as the level entry of that id.
- Levels come from `matrix/levels.json` and stages from `matrix/stages.json`, in that order. `basedOn` holds the display name and is matched case-insensitively; the slug is the lowercased name.
- Why two sources for the stages: `resolved.json` cannot tell "the stage pins the id at the level action" from "no stage entry", while the stage column can. The level cells come from `resolved.json` because the V13 test compares the composed files against the same file.
- File-level text: a level file is named `Rulebook <Name>`, a stage file `Rulebook stage <Name>`, with the descriptions of composition.md section 5; both carry the delta profile URL in `$schema`. `base/twins.json` carries the twins schema URL and `"generatedBy": "tools/rulebook/Build-Template.ps1"`.

`Build-RulebookBase` checks its input and throws, as an engine tool, when the matrix rows do not mirror the inventory row by row, an id has no resolved cells, a level name is not a slug or disagrees with its `slug`, a `basedOn` names no level or forms a cycle, `stages.json` has no `default`, a stage names no matrix column, or a cell or stage column holds something other than an action (`=` allowed in a stage column).

## 3. Build-Template.ps1

```powershell
pwsh ./tools/rulebook/Build-Template.ps1            # writes the changed files, prints "template: <file> (<change>)", "level pages: <path> (<change>)" or "template: current"
pwsh ./tools/rulebook/Build-Template.ps1 -WhatIf    # writes nothing; an empty list means template/ and docs/levels/ are current
```

The wrapper runs, in this order:

1. `Build-RulebookBase -RulebookDir docs/rulebook -OutputPath template/base`
2. `Build-RulebookStages -RulebookDir docs/rulebook -OutputPath template/stages`
3. `Build-RulebookCatalog -RulebookDir docs/rulebook -OutputPath template/catalog/diagnostics.json`
4. `New-RulebookSkeleton -SettingsPath template/.github/Rulebook-Settings.json -OutputPath template/skeletons`
5. `Update-RulebookEndpoints -RepositoryRoot template`
6. `New-RulebookLevelDocs -RepositoryRoot template -OutputPath docs/levels -GeneratedBy tools/rulebook/Build-Template.ps1` (module `Rulebook.Levels`, WP10)

The endpoints come after the files they are generated from, and the level pages last because they read the regenerated template like an organization repository. Step 6 writes the one output outside `template/`: one page per shipped level and a `README.md` index in `docs/levels/` of this repository (`-LevelDocsDir`, default `docs/levels` next to the script; D49, [authoring-levels.md](../authoring-levels.md) section 4). Each function builds and checks all its texts before it writes the first file, but the steps run one after the other: a step that throws leaves the files of the earlier steps written, so fix the input and run the wrapper again. `-RulebookDir` and `-TemplateDir` default to `docs/rulebook` and `template` next to the script. Each function writes only files whose bytes differ, deletes the files of its folder that it no longer produces (`*.ruleset.json` in `base/`, `skeletons/` and `rulesets/`, `*.json` in `stages/`, `*.md` in `docs/levels/`), and returns one change object per file (`File`, `Change`: `created`, `modified`, `deleted`). The hand-written files are never touched.

Step 5 reads the settings as an organization repository would, so a settings file the generator cannot handle (a `basedOn` that names no level file, a `twins` value outside `both`, `appsource` and `pte`) stops the wrapper with the Rulebook.Generate error.

## 4. Keeping template/ current

`template/` is derived from `docs/rulebook/`, `modules/Rulebook.Template.psm1` and the template settings. `Build-Template.ps1 -WhatIf` reports the drift of `base/`, `stages/`, the catalog and `skeletons/` against the inputs on disk; `rulesets/` it compares with the level and stage files currently on disk, so after a matrix change the endpoint drift is caught by C12 (once `base/` and `stages/` are regenerated) and by the Pester drift test, which regenerates everything from scratch. After a change to any of the inputs:

```powershell
pwsh ./tools/rulebook/Build-Matrix.ps1      # when the placement rules or the inventory changed
pwsh ./tools/rulebook/Test-Rulebook.ps1     # V1 to V14
pwsh ./tools/rulebook/Build-Template.ps1    # regenerate template/ and docs/levels/
Invoke-Pester -Path ./tests -Output Detailed
```

Commit `docs/rulebook/`, `template/` and `docs/levels/` together. The checks that catch a forgotten regeneration:

- `tests/Rulebook.Template.Tests.ps1` runs `Build-Template.ps1 -WhatIf` on the committed `template/` and `docs/levels/` and expects no change. It also copies the 12 hand-written files into a scratch folder, runs the wrapper there with `-LevelDocsDir` pointing at a second folder outside the scratch copy, expects `levels + 1 + (stages - 1) + 1 + 2 x levels x stages + (levels + 1)` created files, and compares every file byte for byte with the committed `template/` and `docs/levels/`. A further case checks that `docs/levels/` holds exactly `README.md` and one page per template level and that each page's counts rows equal the rows of `docs/rulebook/README.md` section 4 (V14).
- The same suite composes every cell of `resolved.json` from the committed files with `Get-EffectiveAction` (V13 on disk), checks the entry counts against `matrix/counts.md` and the Listed column, and runs `Test-Rulebook` on `template/`.
- CI runs the Validate action on `template/` with `failOnWarning`, which includes the regeneration check C12 for `rulesets/`.

## 5. The seed catalog

`catalog/diagnostics.json` ships every inventory id so that C7 and the sparse rule work before the first scan (D24). An entry is `id`, `analyzer` (the inventory name, for example `Compiler`, `CodeCop`, `LinterCop`), `defaultSeverity`, `enabledByDefault`, `title` and `docs`, in that order, one entry per line; `title` and `docs` are left out when empty. It has no `package`, no versions and no channel: the catalog schema does not accept `null`, and the first scan (WP08) adds those fields. Titles are written as UTF-8 as they are, including the two non-ASCII titles of LC0009 and LC0089. The writer is `ConvertTo-CatalogJson` of `Rulebook.Catalog`, the one the scan uses; a seed entry is written byte for byte as before.

The seeded ids are known ids (D46): the scan never quarantines them. What the first scan changes in the seed, observed on 2026-10-07 in a dry run with the template settings and a policy against Development.Tools 18.0.43.1464 and 30.0.42.60748-beta and ALCops.Analyzers 1.3.1 (the numbers move with nuget.org; the CI job `scan-action` prints them on every run):

| Change | Ids |
|---|---|
| package fields (`package`, `firstSeenVersion`, `firstSeenChannel`, `firstStableVersion`, `lastSeenVersion`) | 625 of 628 |
| `advertised: false` (defined, returned by no analyzer) | 7: AS0141, AC0000, DC0000, FC0000, LC0000, PC0000, TA0000 |
| no package fields (in no released package) | 3: AC0033, AC0034, TA0002 |
| `title` refreshed from the descriptor | 1: DC0009 |
| `docs` refreshed (the TestAutomationCop link lowercased) | 2: TA0000, TA0001 |
| default severity or enablement changed | 0 |
| new ids | 0 |

The catalog is org-owned: an update from the template never overwrites it, so the seed matters for new repositories only. The engine regenerates it on every run of `Build-Template.ps1`.

## 6. The base URL and {BASEURL}

The template ships `"baseUrl": ""`. The settings schema accepts the empty string (an organization fills it in), C5 still rejects a trailing slash, and the Publish action (WP05) stops with a proposal until it is set. The skeletons in `skeletons/` keep the placeholder `{BASEURL}` in the repository; Publish renders the organization's URL into the published copy, so an update from the template never fights with the organization's URL.
