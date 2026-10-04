# Composition: the generated ruleset files

Contract for the generator that turns the matrix into ruleset files. The sources are **deltas**: a level file lists only the ids it changes relative to the level it is `basedOn` (a root relative to the analyzer defaults), a stage file lists only the ids it changes on top of every level. Every endpoint is **one flat, self-contained, sparse file**: a `rules` array that lists every diagnostic id whose effective action differs from the analyzer default, no `includedRuleSets`, no `generalAction`. Decisions D18, D21, D22, D23, D25, D27 and D28 in `docs/adr/`.

## Contents

1. [Why flat and sparse](#1-why-flat-and-sparse)
2. [Files](#2-files)
3. [Generator contract](#3-generator-contract)
4. [Entry formats](#4-entry-formats)
5. [Examples](#5-examples)
6. [Consumption](#6-consumption)
7. [Relation to the Rulebook architecture](#7-relation-to-the-rulebook-architecture)

## 1. Why flat and sparse

- **One fetch per compile.** The compiler fetches every included file separately, with a 15 second timeout, no cache and no retry; any failure discards the whole ruleset (AL1033). A flat endpoint is one request.
- **No merge semantics.** Siblings merge strictest-wins and `None` never wins; own rules beat includes. None of that applies to a file without includes. What the file says is what the compiler does.
- **Sparse by design.** An id the file does not mention runs at the analyzer default. The matrix decides every id, but it writes only the ids where its decision differs from that default (D22). Three things follow: the fetched file is small (Recommended lists nine ids); `suppressWarnings` in `app.json` keeps working for everything at default, which is how a project opts out of the other cop's blockers; and where a client falls back to defaults (the VS Code language server, per the code; alc aborts with AL1033) the result is close to what Rulebook intended.
- **Defaults are tracked, not assumed.** The organization's catalog records every id's default severity and enablement; the daily scan reports changes and regenerates (D24).
- **Sources are deltas too.** Nothing is repeated across levels or stages (D27). A custom level is one file plus one settings entry; so is a custom stage.

The matrix in `matrix/` remains the only place where a shipped placement is decided. The generator is a projection of it.

## 2. Files

`<level>` is a level slug (`essential`, `recommended`, `strict`, `complete` for the shipped set), `<stage>` is a stage slug other than `default` (`ci`, `vnext` shipped). The `default` stage has no file of its own and no suffix in `rulesets/`; everywhere else it is written out (`quarantine.default.json`, `skeletons/<level>.default.ruleset.json`).

| Where | File | Content | Shipped count |
|---|---|---|---|
| Engine, template | `base/<level>.ruleset.json` | One per level. The root (`essential`) lists every id whose action differs from the analyzer default; every other level lists every id whose action differs from its `basedOn` level. Entries carry action and justification. System file in an organization repository; a level the template does not ship is org-owned. | 4 |
| Engine, template | `stages/<stage>.json` | One per non-default stage: every id whose stage column is not `=`, with action and justification. Applied on top of every level where the level result is not `None`. System file; a custom stage is org-owned. | 2 |
| Engine, template | `base/twins.json` | The twin pairs the `twins` setting acts on. System file; generated from `matrix/twins.json`. | 1 |
| Organization repository | `.github/Rulebook-Settings.json` | `levels` (ordered, `name`, `description`, `basedOn`), `stages` (ordered, `name`, `description`, `default` mandatory), `twins` (`both`, `appsource`, `pte`), quarantine policy. | 1 |
| Organization repository | `overrides.json` | Organization overrides with scope selectors. Org-owned, written by ChangeRule. | 1 |
| Organization repository | `quarantine.<stage>.json` | Ids held at `None` for that stage until a level file mentions them. One per stage in the settings, `default` included. Org-owned, written by the scan. | 3 |
| Organization repository | `catalog/diagnostics.json` | Every known id with `defaultSeverity` and `enabledByDefault`; the source of the analyzer default at generation time. | 1 |
| Organization repository, published | `rulesets/<level>.ruleset.json`, `rulesets/<level>.<stage>.ruleset.json` | The generated endpoints: the ids whose effective action differs from the analyzer default, no justification. One per level for the `default` stage, one per level and other stage. Committed and published. | 12 |
| Organization repository, published | `skeletons/<level>.<stage>.ruleset.json` | The file an AL project copies: one include of the endpoint URL, project exceptions in `rules`. The stage suffix is always present here. | 12 |

The shipped files today: `essential` 353 entries, `recommended` 352, `strict` 65, `complete` 24, `stages/ci.json` 10, `stages/vnext.json` 95 (the file table in `matrix/counts.md`).

## 3. Generator contract

Let `cell(id, level, stage)` be the resolved action from `matrix/resolved.json` (key `<level>.<stage>`), which is the resolution recipe of `00-conventions.md` applied to the matrix row. Let `default(id)` be `catalog.defaultSeverity` when `catalog.enabledByDefault` is true and `None` otherwise (in the engine, before a catalog exists, the inventory's `Default` and `Enabled` columns).

**Level files:** `base/essential.ruleset.json` has one entry per id where `cell(id, essential, default) != default(id)`, in inventory order, with that action and the matrix `Justification`. `base/<level>.ruleset.json` for every other shipped level has one entry per id where `cell(id, level, default) != cell(id, basedOn(level), default)`. The file-level `description` names the `basedOn` level.

**Stage files:** `stages/<stage>.json` has one entry per id whose stage column is not `=`, with that action and the justification of the stage rule. There is no file for `default`.

**Level chain** for an id and a level: walk `basedOn` from the root to the level; the last file on the path that mentions the id gives `chain(id, level)`. If no file mentions it, the chain is undefined. `basedOn` may name any level file in `base/`, listed in the settings or not; cycles are a validation error. A level file may set any id higher or lower than its `basedOn` level; nothing compares the two.

**Effective action** for an id in endpoint (level, stage):

```
effective(id, level, stage) =
    overrides entry action   if an entry matches id, level and stage
                             (most specific selector wins; on a tie the last entry in the file wins)
    None                     else if settings.twins == "appsource" and id is the pte side of a twin,
                             or settings.twins == "pte" and id is the appsource side of a twin
    stage action             else if stage != default, stages/<stage>.json mentions the id
                             and the level result (chain(id, level) if defined,
                             else default(id)) != None                                       (S-4)
    chain(id, level)         else if chain(id, level) is defined
    None                     else if quarantine.<stage>.json lists the id
    default(id)              else: the compiler applies the analyzer default
```

Precedence in one line: override, then twins, then stage delta, then level chain, then quarantine, then the analyzer default.

**Endpoint:** `rulesets/<level>.ruleset.json` (stage `default`) or `rulesets/<level>.<stage>.ruleset.json` has one entry per id in the union of the level chain, the stage file, overrides, twins and quarantine **where `effective(id) != default(id)`**, in inventory order (unknown ids after the known ones, sorted by id). An id whose effective action equals its default is not written; the compiler applies the default on its own.

An override entry: `{ "id": "AA0001", "action": "Info", "levels": ["recommended", "strict"], "stages": ["ci"], "justification": "..." }`. `levels` and `stages` accept explicit lists of slugs or `["*"]`; `"default"` is a valid stage selector. Specificity is the number of non-wildcard selectors. An override may raise or lower any id, including one the chain sets to `None`, one the twins setting lowers, and one only quarantine mentions. An override whose action equals the default is valid and results in the id being unlisted.

Quarantine entries carry `id` and an optional `justification` only; the action is always `None`. A quarantined id is always written (unless its default is already `None`), because `None` differs from an enabled default. Once a level file on the chain mentions the id, the chain wins and the scan's housekeeping removes the quarantine entry.

**Skeleton:** `skeletons/<level>.<stage>.ruleset.json` includes the endpoint URL with include action `Default` and has an empty `rules` array. Project exceptions added there beat the endpoint because a file's own rules overwrite its includes.

**Invariants the generator must keep:** every `basedOn` resolves and the chain has no cycle; `stages/default.json` does not exist; no endpoint entry equals the catalog default; endpoint plus defaults reproduces the effective action of every id; no endpoint, level or stage file has `includedRuleSets` or `generalAction`; exactly `levels x stages` endpoints and skeletons exist; the committed endpoint equals the regenerated endpoint (validation check). A level entry equal to what the chain already gives, or a stage entry no listed level enables, is a warning, not an error.

## 4. Entry formats

| File | Entry |
|---|---|
| `base/<level>.ruleset.json` | `{ "id": "AL0200", "action": "Warning", "justification": "Compiler warning at author severity from Recommended; D-01" }` |
| `stages/<stage>.json` | `{ "id": "AL0432", "action": "Info", "justification": "Replacement may not exist yet; advisory in CI; S-2" }` |
| `rulesets/` | `{ "id": "AL0432", "action": "Info" }` |
| `base/twins.json` | `{ "pte": "PTE0011", "appsource": "AS0048", "title": "The publisher name is too long" }` inside `pairs` |
| `overrides.json` | `{ "id": "AL0432", "action": "None", "levels": ["*"], "stages": ["ci"], "justification": "Obsoletion backlog tracked in DEV-1234" }` |
| `quarantine.<stage>.json` | `{ "id": "LC0099", "justification": "New in alcops.analyzers 1.4.0-beta.1 (prerelease), quarantined 2026-10-01. Review and adopt." }` |
| `catalog/diagnostics.json` | `{ "id": "AL0432", "analyzer": "Compiler", "defaultSeverity": "Warning", "enabledByDefault": true, ... }` |

- `action` is one of `Error`, `Warning`, `Info`, `Hidden`, `None`; never `Default`.
- The compiler ignores `justification`; level, stage and override files keep it for readers, endpoints drop it. It is optional in every file that may carry one (D37, D40); the engine always writes one into the shipped level and stage files.
- File-level fields: `name` is `Rulebook <Level> / <Stage>` with the display names (for example `Rulebook Recommended / CI`); `description` names the level and stage by slug and, for generated endpoints, the template sha the sources came from, the files folded in and the `twins` setting in effect.

## 5. Examples

`base/recommended.ruleset.json` (excerpt), a delta on `essential`:

```json
{
  "name": "Rulebook Recommended",
  "description": "Level recommended, basedOn essential. Lists the ids whose action differs from essential. Generated from docs/rulebook; do not edit.",
  "rules": [
    { "id": "AL0200", "action": "Warning", "justification": "Compiler warning at author severity from Recommended; D-01" },
    { "id": "AL0432", "action": "Info",    "justification": "Replacement may not exist yet; advisory in CI, Warning on vNext where removal is near; F-05" },
    { "id": "AS0003", "action": "Error",   "justification": "Baseline-missing diagnostics need a configured baseline; off at Essential, native from Recommended; OV-08" },
    { "id": "AS0084", "action": "Error",   "justification": "Needs AppSourceCop.json or marketplace manifest fields; off at Essential, native from Recommended; F-07" }
  ]
}
```

AS0001 and PTE0001 are absent from this file because Recommended does not change them, and absent from `base/essential.ruleset.json` because `Error` is their analyzer default. No file mentions them; the compiler runs them at their native severity. LC0054 is absent everywhere for the same reason, `None` being its default.

`stages/ci.json` (excerpt):

```json
{
  "name": "Rulebook stage CI",
  "description": "Stage ci. Applied on top of every level where the level result is not None. Generated from docs/rulebook; do not edit.",
  "rules": [
    { "id": "AL0432", "action": "Info", "justification": "Replacement may not exist yet; advisory in CI; S-2" },
    { "id": "AL0603", "action": "Info", "justification": "Implicit conversion is advisory in CI; S-2" }
  ]
}
```

`overrides.json` in an organization repository:

```json
{
  "rules": [
    { "id": "AA0072", "action": "Warning", "levels": ["*"], "stages": ["*"], "justification": "House style: type suffix on variables" },
    { "id": "AL0432", "action": "None", "levels": ["essential", "recommended"], "stages": ["ci"], "justification": "Obsoletion backlog tracked in DEV-1234 until 2027-01" }
  ]
}
```

`rulesets/recommended.ci.ruleset.json`, the generated endpoint the compiler fetches, with `twins` at `both`:

```json
{
  "name": "Rulebook Recommended / CI",
  "description": "Level recommended, stage ci, twins both. Generated from base@a1b2c3d (essential, recommended) plus stages/ci.json, overrides.json and quarantine.ci.json; do not edit. Ids at their analyzer default are not listed.",
  "rules": [
    { "id": "AL0432", "action": "None" },
    { "id": "AL0603", "action": "Info" },
    { "id": "AA0072", "action": "Warning" },
    { "id": "LC0099", "action": "None" }
  ]
}
```

AL0200, AS0003, AS0084, AS0001 and PTE0001 are absent: Warning, Error, Error, Error and Error are their analyzer defaults. AL0603 is listed because the stage file lowers it from its Warning default. AL0432 is listed because the override set it to `None` and its default is Warning. LC0099 is a quarantined prerelease id. A per-tenant project that wants AS0084 gone adds it to `suppressWarnings` in `app.json`, or to the `rules` of its skeleton; both work because the endpoint does not list it.

`skeletons/recommended.ci.ruleset.json`, copied into an AL project as `.rulebook/ci.ruleset.json`:

```json
{
  "name": "Rulebook Recommended / CI",
  "description": "Copy into your AL project and point al.ruleSetPath or the AL-Go rulesetFile at it. Add project exceptions to rules; they override the endpoint.",
  "includedRuleSets": [ { "action": "Default", "path": "https://contoso.github.io/rulebook/rulesets/recommended.ci.ruleset.json" } ],
  "rules": []
}
```

The `default` stage skeleton `skeletons/recommended.default.ruleset.json` includes `https://contoso.github.io/rulebook/rulesets/recommended.ruleset.json` and is copied as `.rulebook/default.ruleset.json`.

## 6. Consumption

| Consumer | Setting | Value |
|---|---|---|
| VS Code | `al.ruleSetPath` | `.rulebook/default.ruleset.json` (the skeleton, one include) or the endpoint URL directly |
| AL-Go | `rulesetFile` in `.AL-Go/settings.json` and `.github/NextMajor.settings.json` | the `ci` and `vnext` skeletons |
| `alc` | `/ruleset:<path>` with `/enableexternalrulesets` | any endpoint URL or skeleton |

External rulesets must be enabled in every consumer that fetches over HTTP. If the endpoint is unreachable or invalid the compiler discards the ruleset and reports AL1033: `alc` stops the build with exit code 1 ([spike a](../reference/spikes/a-hosts-and-skeleton-include.md)), the VS Code language server shows AL1033 on `app.json` and runs the analyzers at their default severities ([spike e](../reference/spikes/e-vscode-refetch.md)).

`suppressWarnings` in `app.json` is merged strictest-wins after the ruleset, so it switches off exactly the ids the endpoint does not list: every id at its analyzer default, which includes the cop-specific blockers a project most often wants gone. It cannot switch off an id the endpoint lists; those go into the skeleton's `rules`. The template's `docs/pte-or-appsource.md` has the ready-made lists for per-tenant and AppSource projects.

## 7. Relation to the Rulebook architecture

This contract implements D18, D19, D21, D22, D23, D25, D27 and D28 of `docs/adr/`: flat endpoints, sparse by analyzer default, level chain plus stage deltas plus twins setting plus overrides plus quarantine as inputs, committed outputs, slug-named files. "Each level includes the level below" is back as a relation between source files (`basedOn`, D27) and remains invariant I2 of the matrix for the shipped set (check V11); it is not an include the compiler follows, and an organization repository does not enforce it (D26). "Target" is no longer a dimension at all, and the everything-off starting level is gone (D25). `docs/ARCHITECTURE.md` section 5 describes where these files live in an organization repository and which workflow regenerates them.
