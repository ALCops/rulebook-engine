# Authoring levels

How level and stage content is maintained in the engine, how a placement change reaches organizations, what the generated level pages show, and the recipes an organization uses to pick a starting point and add, alias or remove levels and stages. The decisions are [D16](adr/0016-level-content-comes-from-a-markdown-matrix-target-and-stage.md) (the rule decisions live in `docs/rulebook/`), [D25](adr/0025-l0-is-removed-the-starting-point-is-the-closest-shipped.md) (no shipped everything-off level), [D26](adr/0026-levels-and-stages-are-configuration.md), [D27](adr/0027-source-files-are-deltas-level-chain-and-stage-deltas-flat.md), [D28](adr/0028-identity-is-one-name-the-slug-names-every-file-url-selector.md), [D29](adr/0029-basedon-references-any-level-file-removing-an-entry-stops.md), [D38](adr/0038-release-notes-are-generated-from-pull-request-labels.md) and [D49](adr/0049-shipped-level-pages-live-in-the-engine-docs.md).

> **Status:** written by WP10 ([#12](https://github.com/ALCops/rulebook-engine/issues/12)). Code: `modules/Rulebook.Levels.psm1`, `tools/rulebook/Build-Template.ps1`, `scripts/New-RulebookOffLevel.ps1`. Everything below is derived from that code and its tests unless it says *observed*; the live run is section 7. The user page for organizations is `docs/levels.md` in the ALCops/rulebook repository.

---

## Contents

1. [What a placement change is](#1-what-a-placement-change-is)
2. [Making a placement change](#2-making-a-placement-change)
3. [How a change reaches organizations](#3-how-a-change-reaches-organizations)
4. [The level pages](#4-the-level-pages)
5. [Organization recipes](#5-organization-recipes)
6. [Reference](#6-reference)
7. [Live run](#7-live-run)

---

## 1. What a placement change is

A placement change moves one or more diagnostic ids to another action at some level or stage of the shipped ladder. The placement is decided in exactly three places, all in this repository:

- the rule tables of `tools/rulebook/Build-Matrix.ps1`: override rows `OV-nn` (explicit ids), family rows `F-nn` (by family or flag) and decision rows `D-nn` (by analyzer, default severity and enablement), evaluated in that order, first match wins ([rulebook/02-placement-algorithm.md](rulebook/02-placement-algorithm.md) is generated from them);
- `docs/rulebook/inventory/annotations.json`: the hand-maintained family, configuration gate and twin or overlap flags per id, which the family rows read;
- an analyzer refresh ([rulebook/versions.md](rulebook/versions.md)): new ids and changed defaults enter the inventory and are placed by the same tables.

Nobody edits a level file (`template/base/`), a stage file (`template/stages/`), an endpoint (`template/rulesets/`) or a level page (`docs/levels/`) by hand: they are generated. A hand edit is caught by the Pester drift test (`tests/Rulebook.Template.Tests.ps1` regenerates everything and compares bytes) and, for the endpoints, by C12 in the Validate action on `template/`.

## 2. Making a placement change

1. **Edit and record.** Change the rule table row or the annotation. An override row names a decision record: add or supersede a `DR-nnn` record in [rulebook/decisions.md](rulebook/decisions.md) (decision, rationale, rule rows affected; a record is superseded, never edited). Respect the invariants of [rulebook/verification.md](rulebook/verification.md), in particular I3: `Error` only for the `runtime` family, the Error defaults of PerTenantExtensionCop and AppSourceCop and the `vNext` future errors.
2. **Rebuild the matrix and check it.**

   ```powershell
   pwsh ./tools/rulebook/Build-Matrix.ps1      # matrix/, 02-placement-algorithm.md, counts.md
   pwsh ./tools/rulebook/Test-Rulebook.ps1     # V1 to V14; V14 keeps the counts table of rulebook/README.md current
   ```

   When V14 fails, copy the regenerated count rows from `matrix/counts.md` into section 4 of [rulebook/README.md](rulebook/README.md).
3. **Regenerate the template and the pages.**

   ```powershell
   pwsh ./tools/rulebook/Build-Template.ps1
   ```

   The wrapper runs `Build-RulebookBase`, `Build-RulebookStages`, `Build-RulebookCatalog`, `New-RulebookSkeleton`, `Update-RulebookEndpoints` and, since WP10, `New-RulebookLevelDocs` ([reference/template-content.md](reference/template-content.md) section 3). Commit `docs/rulebook/`, `template/` and `docs/levels/` together. `Build-Template.ps1 -WhatIf` must then print `template: current`.
4. **Run the checks.** `Invoke-Pester -Path ./tests` and `Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1` ([CONTRIBUTING.md](../CONTRIBUTING.md) section 3).
5. **Open the pull request** with a title that names the ids and the file, for example `LC0031 Warning to Info in base/recommended.ruleset.json (OV-12)`, and one release label (`enhancement`, `bug`, `documentation`; D38). The title is what the generated release notes show, and the deploy step turns the same notes into the template's `RELEASENOTES.copy.md`, which an organization's update pull request quotes.

The issue text of #12 listed `Build-RulebookBase` and `Build-RulebookStages` as a separate step and asked for a "release notes line"; both are superseded: `Build-Template.ps1` runs every generator, and the release notes are generated from the pull request title and label (D38).

## 3. How a change reaches organizations

WP13 deploys `template/` to ALCops/rulebook. An organization's **Update Rulebook System Files** workflow ([ARCHITECTURE.md](ARCHITECTURE.md) section 7.3, [reference/update-mechanics.md](reference/update-mechanics.md)) then opens one pull request that:

- overwrites the shipped level and stage files (`base/essential.ruleset.json` and the others the template ships, `stages/ci.json`, `stages/vnext.json`) and `base/twins.json`, unless `unusedRulebookFiles` lists them;
- keeps every organization-owned file: `overrides.json`, the quarantine files, the catalog, `docs/**`, and every level or stage file the template does not ship (an organization's `base/off.ruleset.json` or `base/house.ruleset.json` is never touched);
- regenerates `rulesets/` and the skeletons from the new files and the organization's own inputs, and writes `templateSha`;
- shows the effective diff per endpoint, where a moved id appears with the provenance `level:<slug>` or `stage:<slug>` of the file that now decides it. A body that would exceed the GitHub limit drops endpoint tables from the end and says so; the job summary keeps them all (#75).

## 4. The level pages

`docs/levels/` holds one page per shipped level and a `README.md` index, generated by `Build-Template.ps1` from `template/` (the settings, the level files with their chain, and `catalog/diagnostics.json`). Each page shows:

- the slug, the `basedOn` level (a link, "the analyzer defaults (a root)", or a level file without a settings entry, which is a root for its chain, D29), the settings description, the file with its entry count and how many entries lower the action, and the chain of files from the root;
- **Counts per stage**: one row per settings stage with the number of catalog ids per action and `Listed`, the number of ids the endpoint writes. The counts are the endpoint the generator produces (overrides, the twins setting and quarantine included); for `template/`, whose overrides and quarantine files are empty and whose twins setting is `both`, they equal the matrix table in [rulebook/README.md](rulebook/README.md) section 4, and a Template test asserts it;
- **Entries**: the level file alone, grouped by analyzer in order of first appearance, one row per entry: id, title, From (the action the files below on the chain give, last file wins, else the analyzer default; "(not in the catalog)" for an unknown id), To (the entry), `lowered` when To ranks below From in the order None < Hidden < Info < Warning < Error, the justification and the docs link. An alias level (no entries) shows one sentence instead.

The pages are computed from repository inputs, not from the matrix, so `New-RulebookLevelDocs` describes any repository. The pages of the shipped levels live in the engine because they are the same for every organization and change with the matrix in the same pull request (D49); a `docs/` folder in the template would be written once and go stale. Neither `template/` nor an organization repository carries level pages, and Publish does not render them; an organization's own levels get their pages from the WP14 site, which builds them with `Get-RulebookLevelSummary`.

`New-RulebookLevelDocs` manages every `*.md` file of its output folder: it deletes the pages it no longer produces, and it refuses (before writing anything) a folder holding a Markdown file without its "Generated by ... (`New-RulebookLevelDocs`) ... do not edit." line, so it cannot delete hand-written pages. A level whose slug is `readme` cannot have a page (it would be the index).

The drift test regenerates the pages from the 12 hand-written template files into a folder outside its scratch template copy and compares them byte for byte with `docs/levels/`; `Build-Template.ps1 -WhatIf` on the committed tree reports a stale page.

## 5. Organization recipes

Levels and stages are configuration of the organization repository (D26); every recipe is a settings edit plus at most one file. After the change, the endpoints and skeletons are generated by the next run of **Update Rulebook System Files** (with "Resolve the latest commit" off when the template has not changed, so the run regenerates from the installed version) or by a local regeneration with `Update-RulebookEndpoints -RepositoryRoot .` (Rulebook.Generate) and `New-RulebookSkeleton -SettingsPath .github/Rulebook-Settings.json -OutputPath skeletons` (Rulebook.Template). Until then Validate reports C11 (skeletons missing or stray) and C12 (endpoints to create or delete). The Change Rule dropdowns follow after one update (D30).

| Goal | Settings | File | Notes |
|---|---|---|---|
| Add a level | `{ "name": "House", "basedOn": "Recommended", "description": "..." }` at its display position; point a higher level's `basedOn` at it to put it into the ladder | `base/house.ruleset.json` with the ids it changes | Org-owned file. Three endpoints and three skeletons per level with the shipped stages. |
| Alias or rename a level | `{ "name": "Baseline", "basedOn": "Essential" }`, then remove the Essential entry | `base/baseline.ruleset.json` with `"rules": []` | Shipped names are not edited (D28); the URLs change. The unpublished `base/essential.ruleset.json` stays a `basedOn` target, so no C9 while a chain reaches it. Overrides name slugs: an override scoped to `levels: ["essential"]` does not follow the alias, so the alias equals its `basedOn` level only when no override is scoped to that level's slug alone (retarget such overrides to the new slug). |
| Everything off (R6-A) | `{ "name": "Off", "description": "Every known diagnostic off. Opt in through overrides." }` first in `levels` | `base/off.ruleset.json`, written by `scripts/New-RulebookOffLevel.ps1` | Opt in with overrides scoped `levels: ["off"]` or by editing the file, which the repository owns. See the two interactions below. |
| Add a stage | `{ "name": "Nightly", "description": "..." }` after `CI` | `stages/nightly.json` with the ids it changes | Every published level gains `<level>.nightly`. A stage never activates a rule the level left at `None`. `quarantine.nightly.json` appears only when `quarantine.stages` names the stage and a scan finds new ids. |
| Remove a level or stage | delete the entry; list a shipped file in `unusedRulebookFiles` (`"base/complete.ruleset.json"`) | the update deletes the listed file | `default` cannot be removed. Overrides that name the slug fail C10 and must go; a quarantine file of a removed stage is reported by C16. |

The off-level script, run from the root of a clone:

```powershell
iwr https://raw.githubusercontent.com/ALCops/rulebook-engine/main/scripts/New-RulebookOffLevel.ps1 -OutFile ../New-RulebookOffLevel.ps1
../New-RulebookOffLevel.ps1
```

It writes `base/off.ruleset.json` (every id the catalog enables by default, at `None`, sorted, no justification), prints the settings entry to paste and the next steps, and never edits the settings. A second run against the same catalog says the file is current; a differing file (an older catalog or your own edits) needs `-Force`.

Two interactions are documented rather than checked:

- **Off as the only published level.** Every entry of `stages/ci.json` and `stages/vnext.json` is then a C8 warning (a stage entry on an id no published level enables). The warnings are expected; keep the stage files, since they are system files the update overwrites.
- **Housekeeping versus a root level.** The scan removes a quarantine entry as soon as a file on the chain of any published level mentions the id (C13, [reference/scan-mechanics.md](reference/scan-mechanics.md) section 5). When an update adds a new id to a shipped level file and the organization also publishes that level, the id leaves quarantine and goes live at its analyzer default in the organization's root level (D41, D29), unless the organization adds it to `base/off.ruleset.json`. The scan pull request does not yet list such ids (spin-off).

The user page `docs/levels.md` in ALCops/rulebook explains the same recipes for organizations, with the Validate messages to expect.

## 6. Reference

| Function (`Rulebook.Levels`) | Parameters | Result |
|---|---|---|
| `Get-RulebookOffLevelEntry` | `-Catalog` (a `Rulebook.Catalog` from `Read-CatalogFile`) | `{ Id, Action = 'None' }[]` for every id with `enabledByDefault` true (Hidden defaults, deprecated and unadvertised ids included), sorted by `Get-SortedCatalogEntry`. Pure. |
| `New-RulebookOffLevel` | `-RepositoryRoot`, `-Name` (default `Off`), `-Description` (of the printed entry), `-Force`, `-WhatIf` | Writes `base/<slug>.ruleset.json` (name `Rulebook <Name>`, delta `$schema`, a fixed description with the id count, no date). Returns nothing when the bytes are equal, else `Rulebook.OffLevel { File, Path, Change (created, modified), Name, Slug, Count, SettingsListed, SettingsEntry }`. A catalog without enabled ids writes `"rules": []` with a warning. |
| `Get-RulebookLevelSummary` | `-Inputs` (`Read-RulebookInputs`), `-Catalog`, `-Level` (a published slug) | `Rulebook.LevelSummary { Name, Slug, Description, BasedOn, BasedOnName, BasedOnPublished, ChainFiles, File, EntryCount, LoweredCount, TwinsSetting, OverrideCount, CatalogCount, Rows, Groups, Counts }`; rows `{ Id, Analyzer, Title, Docs, From, FromSource, To, Lowered, Justification }` (`Analyzer` falls back to the id prefix when the catalog has none), counts `{ Stage, Error, Warning, Info, Hidden, None, Listed }`. Throws `Unknown level slug '<slug>'`. |
| `ConvertTo-LevelDocsMarkdown` | `-Summary`, `-GeneratedBy` | The page text. |
| `ConvertTo-LevelDocsIndexMarkdown` | `-Summaries`, `-Inputs`, `-GeneratedBy` | The `README.md` text: one row per level and a line naming the stages with their file entry counts. |
| `New-RulebookLevelDocs` | `-RepositoryRoot`, `-OutputPath`, `-GeneratedBy` (default `New-RulebookLevelDocs`), `-WhatIf` | Writes `<slug>.md` per published level and `README.md` through `Sync-GeneratedFolder` (other `*.md` files deleted); `Rulebook.TemplateChange { File, Path, Change }` per change. Throws `Settings missing: .github/Rulebook-Settings.json in <root>`. |

`scripts/New-RulebookOffLevel.ps1 [-RepositoryRoot .] [-Name Off] [-Force]` writes the same bytes as `New-RulebookOffLevel` (a test pins both on the fixture and the shipped catalog) and returns `{ File, Count, Slug, SettingsEntry, SettingsListed }`.

| Message | Cause |
|---|---|
| `Run the script from the root of a clone of your rulebook repository (the folder with .github/Rulebook-Settings.json and catalog/diagnostics.json): <path>` | The script ran outside the repository root. |
| `Level name '<Name>' does not lowercase to a slug matching ^[a-z0-9-]+$ (C5)` | `-Name` has a space or another character a slug cannot hold. |
| `base/<slug>.ruleset.json exists and differs; it is owned by this repository. Use -Force to overwrite it (your own edits in it are lost)` | The file was written from another catalog or edited since. |
| `base/<slug>.ruleset.json is current (<n> ids at None)` | Nothing to do; the script printed the entry and the next steps again. |
| `catalog/diagnostics.json: <id> has no boolean enabledByDefault` | The catalog fails C14; fix it first. The script and `New-RulebookOffLevel` both refuse it. |
| `Cannot read .github/Rulebook-Settings.json (...); the level counts as not listed` | A warning: the settings are read only to say whether the level is listed; the file is written anyway. |

## 7. Live run

On the scratch repositories `Arthurvdv/rulebook-e2e-template` (re-seeded from the `wp10/levels` branch) and `Arthurvdv/rulebook-e2e-levels`. Pending: the cells are filled when the run is observed.

| Card | What | Observed | Links |
|---|---|---|---|
| (a) | A throwaway placement change on the branch, regenerated, and the update pull request in the organization; then reverted | pending | pending |
| (b) | Everything off with the script, then the update with "Resolve the latest commit" off | pending | pending |
| (c) | Custom level House basedOn Recommended under Strict, alias Baseline for Essential | pending | pending |
| (d) | Remove Complete with `unusedRulebookFiles` | pending | pending |
| (e) | Add stage Nightly, then a scan run with `quarantine.stages` naming it | pending | pending |
