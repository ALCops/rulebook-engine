# Rulebook level content

The source of truth for what every code-analysis diagnostic of Microsoft Dynamics 365 Business Central does at every Rulebook level and stage. It covers the AL compiler's configurable diagnostics, the four Microsoft cops (CodeCop, UICop, PerTenantExtensionCop, AppSourceCop) and the seven ALCops cops (PlatformCop, ApplicationCop, LinterCop, DocumentationCop, FormattingCop, TestAutomationCop, Common): 628 diagnostic ids.

An agent that generates the `.ruleset.json` files of the Rulebook template reads this folder and nothing else. A maintainer who wants to change a placement changes the rule tables in `tools/rulebook/Build-Matrix.ps1` or the annotations in `inventory/annotations.json`, regenerates, and runs the checks.

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
| [02-placement-algorithm.md](02-placement-algorithm.md) | Generated. Override rows, family rows, decision rows, project kinds and twins, stage rules. Every matrix row names one of them. |
| [versions.md](versions.md) | Analyzer versions the inventory was read from, drift policy, refresh procedure. |
| `inventory/<PREFIX>.md` | Generated. One row per diagnostic: symbol, title, category, default severity, enabled, family, configuration gates, flags, since, docs link. |
| `inventory/inventory.json` | Generated. The same rows as JSON. |
| `inventory/annotations.json` | Hand-maintained. Family, configuration gates and twin, extends, complements, contradicts and code-fix flags per id. |
| `matrix/<PREFIX>.md` | Generated. One row per diagnostic: the ladder, the Default, CI and vNext columns, basis and justification. |
| `matrix/matrix.json`, `matrix/resolved.json`, `matrix/twins.json`, `matrix/levels.json`, `matrix/stages.json`, `matrix/counts.md` | Generated. Matrix rows as JSON; every resolved cell; the twin pairs; the shipped levels and stages in order; the count tables below. |
| [overlaps.md](overlaps.md) | Twins, related pairs, contradictions between the two cops, extends, complements and contradictions with their resolution. |
| [config-dependencies.md](config-dependencies.md) | Rules gated by `AppSourceCop.json`, `app.json`, `alcops.json` or XLIFF files, and what happens without the configuration. |
| [composition.md](composition.md) | The generator contract: four level files (a root and three deltas), two stage files and 12 sparse endpoints per set, the twins setting, the overrides and quarantine inputs, precedence, entry formats, examples, consumption. |
| [decisions.md](decisions.md) | DR-001 to DR-021: the rationale behind every override and every membership judgment, with superseded records kept. |
| [verification.md](verification.md) | Checks V1 to V14 and how to run them. |

## 3. Model in one paragraph

Four shipped levels (Essential, Recommended, Strict, Complete) decide which diagnostics are on and at which action, for every AL project regardless of where it ships. Each level is the level below plus a delta, in the matrix and in the files: Essential is a root against the analyzer defaults, every other level is `basedOn` the one below. Pipelines treat warnings as errors, so the dial is Info (advisory) versus Warning (blocks CI); Error is reserved for definite runtime failures and for the Error defaults of PerTenantExtensionCop and AppSourceCop, the deployment blockers of either kind of extension. Both Microsoft cops run; a rule that only makes sense for one kind of extension runs at its author's severity and the project that does not want it opts out, by disabling a cop, by `suppressWarnings` in `app.json` or by a rule in its project ruleset file. Three shipped stages modify the result per rule: `default` never differs, `CI` relaxes a short list of postponable diagnostics to Info, `vNext` raises compiler future errors to Error; each stage other than `default` is one delta file applied on top of every level. Levels and stages are configuration in a Rulebook repository, which may add, alias or remove them. Each (level, stage) is generated as one flat endpoint that lists only the ids whose action differs from the analyzer default, so the compiler fetches one small file and `suppressWarnings` keeps working for everything Rulebook leaves at default.

## 4. Counts

Number of diagnostics per resolved action for every level and stage (628 ids each row), and the number of ids the sparse endpoint lists because their action differs from the analyzer default. Generated into `matrix/counts.md` by `Build-Matrix.ps1` together with the entry counts of the level and stage files; check V14 keeps this copy current.

| Level | Stage | Error | Warning | Info | Hidden | None | Listed |
|---|---|---|---|---|---|---|---|
| Essential | default | 119 | 124 | 10 | 0 | 375 | 353 |
| Essential | ci | 119 | 124 | 10 | 0 | 375 | 353 |
| Essential | vnext | 211 | 32 | 10 | 0 | 375 | 445 |
| Recommended | default | 128 | 390 | 69 | 18 | 23 | 10 |
| Recommended | ci | 128 | 383 | 76 | 18 | 23 | 17 |
| Recommended | vnext | 220 | 301 | 66 | 18 | 23 | 99 |
| Strict | default | 128 | 443 | 29 | 5 | 23 | 68 |
| Strict | ci | 128 | 433 | 39 | 5 | 23 | 78 |
| Strict | vnext | 220 | 351 | 29 | 5 | 23 | 160 |
| Complete | default | 128 | 445 | 51 | 2 | 2 | 92 |
| Complete | ci | 128 | 435 | 61 | 2 | 2 | 102 |
| Complete | vnext | 220 | 353 | 51 | 2 | 2 | 184 |

| File | Entries |
|---|---|
| `base/essential.ruleset.json` | 353 |
| `base/recommended.ruleset.json` | 352 |
| `base/strict.ruleset.json` | 66 |
| `base/complete.ruleset.json` | 24 |
| `stages/ci.json` | 10 |
| `stages/vnext.json` | 95 |

Reading the table: at Essential the ladder blocks CI on 243 diagnostics (119 Error, 124 Warning) and leaves 375 off; the 119 Errors are the 14 runtime failures and the 105 Error defaults of PerTenantExtensionCop and AppSourceCop that are not marketplace or baseline-missing checks. On vNext 92 Warnings become Errors because the next platform raises them as compile errors. Recommended is the analyzer defaults with nine deviations (three CodeCop Error downgrades, three obsolete-pending at Info, AS0075 and AS0099 hidden, AS0089 lowered), which is what its `Listed` column shows. The two ids that stay off even in Complete are LC0054 (contradiction loser) and LC0089i (noise).

## 5. Regenerating

```powershell
pwsh tools/rulebook/Extract-Inventory.ps1   # from ../nav-sdk-source and ../Analyzers
pwsh tools/rulebook/Build-Matrix.ps1
pwsh tools/rulebook/Test-Rulebook.ps1
pwsh tools/rulebook/Build-Template.ps1      # regenerates template/ and docs/levels/; commit them with docs/rulebook
```

See [versions.md](versions.md) for the full refresh procedure when a new analyzer version ships.
