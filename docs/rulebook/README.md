# Rulebook level content

The source of truth for what every code-analysis diagnostic of Microsoft Dynamics 365 Business Central does at every Rulebook level and stage. It covers the AL compiler's configurable diagnostics, the four Microsoft cops (CodeCop, UICop, PerTenantExtensionCop, AppSourceCop) and the seven ALCops cops (PlatformCop, ApplicationCop, LinterCop, DocumentationCop, FormattingCop, TestAutomationCop, Common): 628 diagnostic ids.

An agent that generates the `.ruleset.json` files of the Rulebook template reads this folder and nothing else. A maintainer who wants to change a placement edits the entry of the id in `inventory/placements.json` (ladder, stage actions and their sentences), regenerates, and runs the checks.

## Contents

1. [How to consume this folder](#1-how-to-consume-this-folder)
2. [Files](#2-files)
3. [Model in one paragraph](#3-model-in-one-paragraph)
4. [Counts](#4-counts)
5. [Regenerating](#5-regenerating)

## 1. How to consume this folder

1. Read [00-conventions.md](00-conventions.md) for the enumerations, the table schemas, the resolution recipe and the sparse rule.
2. Read [01-levels.md](01-levels.md) for what each level and stage means, why there is no target, and the invariants.
3. Parse `inventory/<PREFIX>.md` (what exists, including each id's default severity and enablement) and `matrix/<PREFIX>.md` (what to do with it). `matrix/resolved.json` already holds every resolved cell, keyed `<id>` then `<level>.<stage>` (`recommended.ci`), if you prefer JSON to Markdown. `matrix/twins.json` lists the twin pairs the `twins` setting acts on; `matrix/levels.json` and `matrix/stages.json` give the shipped ladder and stages in order.
4. Produce the files that [composition.md](composition.md) specifies, using its queries and entry format. The `Justification` column becomes the `justification` property of the level and stage files; endpoints list only the ids whose action differs from the analyzer default. In the engine, `modules/Rulebook.Template` does this for `template/`, run by `tools/rulebook/Build-Template.ps1` ([../reference/template-content.md](../reference/template-content.md)).
5. Run the checks in [verification.md](verification.md); V13 states that the delta files must compose back to every resolved cell and that every endpoint lists exactly the deviations from the defaults.

Everything outside a table is written for humans; only the tables and the JSON files are contracts.

## 2. Files

| File | Content |
|---|---|
| [00-conventions.md](00-conventions.md) | Vocabulary, enumerations, id format, inventory and matrix column schemas, resolution recipe, sparse rule, parse rules. |
| [01-levels.md](01-levels.md) | Severity model, the four shipped levels, project kinds and the three opt-out routes, the three shipped stages, how endpoints are generated, invariants I1 to I7. |
| [02-placement-algorithm.md](02-placement-algorithm.md) | Generated. How an id is placed, the placed ids per decision record, the level and severity intent, project kinds and twins, stages, and the fallback override, family, decision and stage rows for an id without a placement. |
| [versions.md](versions.md) | Analyzer versions the inventory was read from, drift policy, refresh procedure. |
| `inventory/<PREFIX>.md` | Generated. One row per diagnostic: symbol, title, category, default severity, enabled, family, configuration gates, flags, since, docs link. |
| `inventory/inventory.json` | Generated. The same rows as JSON. |
| `inventory/annotations.json` | Hand-maintained. Family, configuration gates and twin, extends, complements, contradicts and code-fix flags per id. |
| `inventory/placements.json` | Hand-maintained. One entry per id in inventory order: the ladder, the `ci` and `vnext` actions each with its sentence, the justification and the decision record (`dr`, DR-022 when absent). The source of every matrix row (D60). |
| `matrix/<PREFIX>.md` | Generated. One row per diagnostic: the ladder, the Default, CI and vNext columns, basis, justification and the CI and vNext sentences. |
| `matrix/matrix.json`, `matrix/resolved.json`, `matrix/twins.json`, `matrix/levels.json`, `matrix/stages.json`, `matrix/counts.md` | Generated. Matrix rows as JSON; every resolved cell; the twin pairs; the shipped levels and stages in order; the count tables below. |
| [overlaps.md](overlaps.md) | Twins, related pairs, contradictions between the two cops, extends, complements and contradictions with their resolution. |
| [config-dependencies.md](config-dependencies.md) | Rules gated by `AppSourceCop.json`, `app.json`, `alcops.json` or XLIFF files, and what happens without the configuration. |
| [composition.md](composition.md) | The generator contract: four level files (a root and three deltas), two stage files and 12 sparse endpoints per set, the twins setting, the overrides and quarantine inputs, precedence, entry formats, examples, consumption. |
| [decisions.md](decisions.md) | DR-001 to DR-022: the rationale behind the per-rule placements (DR-022), the records older placements cite, and every membership judgment, with superseded records kept. |
| [verification.md](verification.md) | Checks V1 to V15 and how to run them. |

## 3. Model in one paragraph

Four shipped levels (Essential, Recommended, Strict, Complete) decide which diagnostics are on and at which action, for every AL project regardless of where it ships. Each level is the level below plus a delta, in the matrix and in the files: Essential is a root against the analyzer defaults, every other level is `basedOn` the one below. Every rule is placed on its own, with a one-sentence justification of what it catches and why it sits where it sits. Pipelines treat warnings as errors, so the dial is Info (advisory) versus Warning (blocks CI); Error is reserved for a definite defect: a runtime failure, a definite wrong result, data loss, a security leak, or a deployment or submission blocker of either kind of extension. Both Microsoft cops run; a rule that only makes sense for one kind of extension runs at its author's severity and the project that does not want it opts out, by disabling a cop, by `suppressWarnings` in `app.json` or by a rule in its project ruleset file. Three shipped stages modify the result per rule: `default` never differs, `CI` relaxes to Info a short list of diagnostics a team cannot fix in the same change, `vNext` raises compiler future errors to Error; each stage other than `default` is one delta file applied on top of every level. Levels and stages are configuration in a Rulebook repository, which may add, alias or remove them. Each (level, stage) is generated as one flat endpoint that lists only the ids whose action differs from the analyzer default, so the compiler fetches one small file and `suppressWarnings` keeps working for everything Rulebook leaves at default.

## 4. Counts

Number of diagnostics per resolved action for every level and stage (628 ids each row), and the number of ids the sparse endpoint lists because their action differs from the analyzer default. Generated into `matrix/counts.md` by `Build-Matrix.ps1` together with the entry counts of the level and stage files; check V14 keeps this copy current.

| Level | Stage | Error | Warning | Info | Hidden | None | Listed |
|---|---|---|---|---|---|---|---|
| Essential | default | 127 | 127 | 6 | 0 | 368 | 356 |
| Essential | ci | 127 | 127 | 6 | 0 | 368 | 356 |
| Essential | vnext | 219 | 35 | 6 | 0 | 368 | 448 |
| Recommended | default | 138 | 304 | 120 | 17 | 49 | 114 |
| Recommended | ci | 138 | 296 | 128 | 17 | 49 | 122 |
| Recommended | vnext | 230 | 215 | 117 | 17 | 49 | 203 |
| Strict | default | 138 | 415 | 44 | 4 | 27 | 89 |
| Strict | ci | 138 | 404 | 55 | 4 | 27 | 100 |
| Strict | vnext | 230 | 323 | 44 | 4 | 27 | 181 |
| Complete | default | 138 | 431 | 56 | 1 | 2 | 105 |
| Complete | ci | 138 | 420 | 67 | 1 | 2 | 116 |
| Complete | vnext | 230 | 339 | 56 | 1 | 2 | 197 |

| File | Entries |
|---|---|
| `base/essential.ruleset.json` | 356 |
| `base/recommended.ruleset.json` | 319 |
| `base/strict.ruleset.json` | 134 |
| `base/complete.ruleset.json` | 42 |
| `stages/ci.json` | 11 |
| `stages/vnext.json` | 95 |

Reading the table: at Essential the ladder blocks CI on 254 diagnostics (127 Error, 127 Warning) and leaves 368 off; the 127 Errors are the 105 Error defaults of PerTenantExtensionCop and AppSourceCop that are not marketplace or baseline-missing checks, the 13 runtime failures of the `runtime` family, and nine rules placed above their author default because each proves a definite defect (AL0821, AA0211, AA0243, AS0103, PC0012, PC0017, PC0019, PC0020, PC0036). Recommended adds 11 Errors: the marketplace and baseline-missing checks and two rules whose failure only hits test code (AA0476, TA0002). On vNext 92 Warnings become Errors because the next platform raises them as compile errors. Recommended is the Rulebook opinion per rule, so its `Listed` column counts the 114 rules placed away from the analyzer default, most of them advice at Info where the author chose Warning. The two ids that stay off even in Complete are LC0054 (contradiction loser) and LC0089i (noise).

## 5. Regenerating

```powershell
pwsh tools/rulebook/Extract-Inventory.ps1   # from ../nav-sdk-source and ../Analyzers
pwsh tools/rulebook/Build-Matrix.ps1
pwsh tools/rulebook/Test-Rulebook.ps1
pwsh tools/rulebook/Build-Template.ps1      # regenerates template/ and docs/levels/; commit them with docs/rulebook
```

See [versions.md](versions.md) for the full refresh procedure when a new analyzer version ships.
