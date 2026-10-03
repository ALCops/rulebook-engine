# Conventions

Vocabulary, enumerations and table schemas used by every file under `docs/rulebook/`. An agent that generates ruleset files parses the tables in `inventory/` and `matrix/` with the rules stated here and nothing else. Prose never appears inside a table cell.

## Contents

1. [Vocabulary](#1-vocabulary)
2. [Enumerations](#2-enumerations)
3. [Diagnostic ID format and sort order](#3-diagnostic-id-format-and-sort-order)
4. [Inventory table schema](#4-inventory-table-schema)
5. [Matrix table schema](#5-matrix-table-schema)
6. [Resolution recipe](#6-resolution-recipe)
7. [Parse rules](#7-parse-rules)

## 1. Vocabulary

| Term | Meaning |
|---|---|
| Diagnostic, id | One rule of one analyzer, identified by its id such as `AA0001`, `AS0105`, `LC0089i`, `AL0432`. |
| Analyzer | The compiler itself (`AL`) or one of the ten cops: CodeCop `AA`, UICop `AW`, PerTenantExtensionCop `PTE`, AppSourceCop `AS`, PlatformCop `PC`, ApplicationCop `AC`, LinterCop `LC`, DocumentationCop `DC`, FormattingCop `FC`, TestAutomationCop `TA`, plus the shared ALCops diagnostic `CM`. |
| Action | What the ruleset tells the compiler to do with a diagnostic: `None`, `Hidden`, `Info`, `Warning`, `Error`. |
| Analyzer default | The action the compiler applies without any ruleset: the descriptor's default severity when `isEnabledByDefault` is true, `None` otherwise. |
| Level | One entry of the ordered ladder in `settings.levels` of a Rulebook repository. The shipped four are Essential, Recommended, Strict and Complete; an organization may add, alias or remove entries (D26). Every level except a root is `basedOn` another level and its file lists only what it changes. |
| Stage | Where the ruleset is consumed. The shipped three are `default` (editor and any consumer without its own stage), `CI` (pull request and release pipelines) and `vNext` (builds against the next major or minor platform). Stages are configurable; `default` is mandatory. Every stage except `default` is one delta file applied on top of every level. |
| Slug | The lowercased `name` of a level or stage (`essential`, `ci`, `vnext`), matching `^[a-z0-9-]+$`. The only spelling used in file names, URLs, override selectors and JSON keys; the `name` keeps its casing in prose (D28). |
| Delta | A level or stage file that lists only the ids it changes: a root level relative to the analyzer defaults, any other level relative to its `basedOn` level, a stage relative to the level result (D27). |
| Cell | The resolved action of one id for one (level, stage), keyed `<level slug>.<stage slug>` in `resolved.json`. |
| Ladder | Four actions, one per shipped level, written `E/R/S/C`, for example `None/Info/Warning/Warning`. |
| Native ladder | The ladder derived from the analyzer default alone: Error -> `Error/Error/Error/Error`, Warning -> `None/Warning/Warning/Warning`, Info -> `None/Info/Warning/Warning`, Hidden -> `None/Hidden/Info/Info`, disabled -> `None/None/None/<default>`. |
| Twin | A PerTenantExtensionCop rule and an AppSourceCop rule with the identical check. Both are active; an organization picks a side with the `twins` setting (D23). |
| Listed | An id is listed in a generated endpoint when its cell differs from the analyzer default (D22). |
| Basis | The row of the placement algorithm that produced a matrix row. |

There is no target dimension. Every rule has one ladder for every AL project, whether it is a per-tenant extension or an AppSource app (D21). The project opts out of rules that do not apply to it; the user documentation of the template (`docs/pte-or-appsource.md` in `ALCops/rulebook`) describes how.

## 2. Enumerations

Spellings are exact and case-sensitive.

| Enumeration | Values | Notes |
|---|---|---|
| Action | `None`, `Hidden`, `Info`, `Warning`, `Error` | Strictness order for comparisons: `None` < `Hidden` < `Info` < `Warning` < `Error`. `None` disables; `Hidden` runs the analyzer and hides the output, used only where a code action depends on the diagnostic. |
| Level | `Essential`, `Recommended`, `Strict`, `Complete` | The shipped ladder; slugs `essential`, `recommended`, `strict`, `complete`. The matrix columns carry the names. |
| Stage | `default`, `CI`, `vNext` | The shipped stages; slugs `default`, `ci`, `vnext`. Matrix columns `Default`, `CI`, `vNext`; `Default` is always `=`. |
| Default | `Error`, `Warning`, `Info`, `Hidden` | The severity the analyzer author chose. |
| Family | `runtime`, `future-error`, `obsolete`, `personalization`, `breaking-change`, `marketplace`, `pte-only`, `metric`, `internal`, `config`, `general` | Assigned by hand in `inventory/annotations.json`; drives the family rows of the placement algorithm. |
| Since | `stable`, `prerelease` | `prerelease` marks an id absent from the latest stable compiler tag named in `versions.md`. |
| Twins setting | `both`, `appsource`, `pte` | Organization setting, not a matrix value. `both` is the default and the only valid choice for a project that runs just one of the two cops. |

Family meanings:

| Family | Meaning |
|---|---|
| `runtime` | The construct fails at runtime in every case. Only these and the Error defaults of PerTenantExtensionCop and AppSourceCop may be `Error` in a ladder. |
| `future-error` | Compiler `WRN_ERR_*` warnings that the runtime turns into a compile error from a later platform version. |
| `obsolete` | "Marked for removal" warnings that a team often cannot fix before the replacement ships. |
| `personalization` | Compiler `WRN_PERS_*` and `INF_PERS_*` diagnostics about page customizations and profiles. |
| `breaking-change` | AppSourceCop rules that compare against the previous version (baseline). Silent without a configured baseline. |
| `marketplace` | Checks that only make sense for a marketplace submission: mandatory affixes, supported countries, marketplace manifest fields, AppSource ID ranges. `None` at Essential, native from Recommended (DR-019). |
| `pte-only` | PerTenantExtensionCop rules that only hold for per-tenant extensions (50000 ID range, no entitlements, no moved tables). Native at every level (DR-018). |
| `metric` | Measurement rules that report a number rather than a defect. |
| `internal` | `X0000` analyzer-exception rules. |
| `config` | Diagnostics that report a missing or broken configuration file. |
| `general` | Everything else; placed by the per-analyzer decision rows. |

## 3. Diagnostic ID format and sort order

- Format: `^(AL|AA|AW|PTE|AS|PC|AC|LC|DC|FC|TA|CM)[0-9]{4}i?$`. The only id with the `i` suffix is `LC0089i`.
- Compiler ids are `AL` followed by the zero-padded `ErrorCode` enum value.
- Sort order everywhere: by prefix in the order `AL, AA, AW, PTE, AS, PC, AC, LC, DC, FC, TA, CM`, then by number, with `LC0089i` directly after `LC0089`.
- Ids that share one descriptor pair (`AC0032`, `LC0003`) are one row; the `Symbol` column lists both descriptors separated by `;`.

## 4. Inventory table schema

Files: `inventory/<PREFIX>.md`, one per analyzer, generated by `tools/rulebook/Extract-Inventory.ps1`. The last non-empty line is `Count: N`.

| Column | Content |
|---|---|
| `ID` | The diagnostic id. |
| `Symbol` | The descriptor field name in source (`Rule0131...`, `PlaceholderArgumentCountMismatch`, `WRN_ObsoleteStatePending`). |
| `Title` | The descriptor title. Compiler diagnostics have no title, so the message format is shown with its `{n}` placeholders. Pipes are escaped as `\|`. |
| `Category` | The descriptor category string. `Compiler` for `AL`. |
| `Default` | Default severity. |
| `Enabled` | `true` or `false`, the descriptor's `isEnabledByDefault`. Together with `Default` this gives the analyzer default. |
| `Family` | One Family token. |
| `Config` | `-` or `;`-separated configuration gates: `AppSourceCop.json:baseline`, `AppSourceCop.json:mandatoryAffixes`, `AppSourceCop.json:supportedCountries`, `AppSourceCop.json:additiveChangeValidation`, `AppSourceCop.json:obsoleteTag`, `alcops.json:<Key>`, `app.json`, `xliff`. See `config-dependencies.md`. |
| `Flags` | `-` or `;`-separated: `twin:<ID>`, `extends:<ID>`, `complements:<ID>`, `contradicts:<ID>`, `codefix`, `future-error`, `pers`, `unnecessary`, `deprecated`. See `overlaps.md`. |
| `Since` | `stable` or `prerelease`. |
| `Docs` | The help link from the descriptor, tracking query removed. |

## 5. Matrix table schema

Files: `matrix/<PREFIX>.md`, one per analyzer, generated by `tools/rulebook/Build-Matrix.ps1` from the inventory and the placement algorithm. One row per id, same order as the inventory.

| Column | Content |
|---|---|
| `ID` | The diagnostic id. |
| `Essential`, `Recommended`, `Strict`, `Complete` | The ladder: the action at each level. |
| `Default`, `CI`, `vNext` | `=` when the stage keeps the level action; otherwise the action that replaces it whenever the resolved action is not `None`. `Default` is always `=`. |
| `Basis` | Exactly one token: `F-nn` (family row), `D-nn` (decision row), `OV-nn` (override). Stage rules are recorded in the stage columns themselves. |
| `Justification` | 1 to 120 characters, no `|`, no line break. Copied verbatim into the generated `justification` property of the base files. |

Companion files in `matrix/`: `matrix.json` (the same rows), `resolved.json` (every cell, keyed `<id>` then `<level slug>.<stage slug>`, for example `recommended.ci`), `twins.json` (the twin pairs with the values of the `twins` setting), `levels.json` (the shipped levels in ladder order with their `basedOn`), `stages.json` (the shipped stages), `counts.md` (the count tables of `README.md`).

## 6. Resolution recipe

For one id, one level `L` and one stage `S`:

```
ladder   = row.Essential / row.Recommended / row.Strict / row.Complete
action   = ladder[L]
stage    = row.Default | row.CI | row.vNext   (by S)
if stage != "=" and action != None: action = stage
```

Sparse rule for the generated endpoint (D22):

```
default(id) = inventory.Default   if inventory.Enabled
            = None                otherwise
listed(id, L, S) = action(id, L, S) != default(id)
```

File derivation (D27). The shipped ladder becomes four level files and two stage files, all deltas, each entry with action and justification:

```
root     base/essential.ruleset.json    ids where ladder[Essential] != default(id)
delta    base/<level>.ruleset.json      ids where ladder[level] != ladder[basedOn(level)]
                                        (recommended on essential, strict on recommended, complete on strict)
stage    stages/<stage>.json            ids where the stage column != "="   (ci, vnext)
default  no file: the default stage is the level result
```

Composing the chain (the last file on the `basedOn` path that mentions an id wins, else the analyzer default) and then the stage file (only where the chain result is not `None`) reproduces every cell of `resolved.json`. The endpoint for (L, S) lists only the ids where `listed` is true; an unlisted id runs at the analyzer default, which is by construction the action the matrix chose.

Endpoint names use slugs: `rulesets/<level>.<stage>.ruleset.json`, and `rulesets/<level>.ruleset.json` for the `default` stage. That is the only place where `default` drops its suffix; every other file, selector and key writes it (`quarantine.default.json`, `skeletons/strict.default.ruleset.json`, `"stages": ["default"]`, key `strict.default`).

## 7. Parse rules

- Tables are GitHub-flavored Markdown with a header row and a `|---|` separator row. Cells are trimmed. Escaped pipes `\|` inside `Title` are literal pipes.
- Column order is fixed as listed above. A generator must fail on an unknown column, not skip it.
- Empty cells do not occur; absence is written as `-` (inventory) or `=` (matrix).
- `Count: N` at the end of an inventory file must equal the number of data rows.
- Everything outside a table is documentation for humans and is not parsed.
