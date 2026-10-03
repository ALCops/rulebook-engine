# Levels, stages and severities

What each level means, what an action means in the editor and in a pipeline, how stages modify a level, why there is no target dimension, and the invariants every matrix row must satisfy. Levels and stages are configuration in a Rulebook repository (D26); this file describes the shipped set that the matrix defines.

## Contents

1. [Severity model](#1-severity-model)
2. [Levels](#2-levels)
3. [Project kinds and opt-out](#3-project-kinds-and-opt-out)
4. [Stages](#4-stages)
5. [Generation](#5-generation)
6. [Invariants](#6-invariants)

## 1. Severity model

Pipelines compile with warnings treated as errors. That makes the action a rule gets the real decision about whether a pull request can merge:

| Action | Editor | Pipeline (warnings as errors) | Used for |
|---|---|---|---|
| `None` | nothing | nothing | Rules the level does not adopt. |
| `Hidden` | nothing, but code actions stay available | nothing | Only where an analyzer ships a rule as Hidden for its code fix. |
| `Info` | blue squiggle | build succeeds | Advice, metrics, and rules a team cannot always fix in the same change. |
| `Warning` | yellow squiggle | **build fails** | The normal enforcement level. |
| `Error` | red squiggle, **local build fails** | build fails | Definite runtime failures and the deployment blockers of PerTenantExtensionCop and AppSourceCop. |

Two consequences drive the whole matrix:

- The meaningful dial is Info versus Warning. Raising a rule to Error buys nothing in a pipeline and costs the developer a red local build, so the ladder uses Error only for the `runtime` family and for the Error defaults of the two Microsoft cops, which block deployment or submission anyway.
- Local development and pipelines run the same ruleset file per stage. A developer sees exactly what will block the pull request; nothing is hidden in the editor and sprung in CI.

Downgrades relative to an analyzer's own default are allowed and documented per row: a diagnostic that cannot always be fixed now (an obsolete-pending object whose replacement has not shipped) is advisory in CI rather than blocking.

## 2. Levels

Four shipped levels in one ladder. Each level is the level below plus a delta; moving up never re-decides what the level below decided (invariant I2). In the files this is literal: Essential is a root, a delta against the analyzer defaults, and every other level is `basedOn` the one below and lists only what it changes (D27). There is no "everything off" level; an organization that wants one adds its own root level (D25).

| Slug | Name | Intent | What is on |
|---|---|---|---|
| `essential` | **Essential** | You cannot ship without this. | Definite runtime failures (Error); the Error defaults of PerTenantExtensionCop and AppSourceCop (Error), except the marketplace and baseline-missing checks; compiler warnings that become errors on a later platform; every default-on PlatformCop rule; the UICop "web client does not support" rules; SecretText for secrets; the ALCops configuration and analyzer-exception rules. Everything else is `None`. |
| `recommended` | **Recommended** | What a healthy project runs. | Every rule that its analyzer author enables by default, at the author's severity. The marketplace and baseline-missing checks join here. Obsolete-pending at Info. This level is the analyzer defaults with nine documented deviations, which is why its endpoint is tiny. |
| `strict` | **Strict** | The quality gate. | Same rule set as Recommended; default-on Info rules become Warning, Hidden ones become Info. Compiler Info stays Info and metrics stay off. |
| `complete` | **Complete** | Everything the analyzers can tell you. | Adds every opt-in rule at its author's severity, and Hidden-by-default rules as Info. Excludes LC0089i and the loser of every contradiction (LC0054). |

The slug is the lowercased name and is what file names, URLs and override selectors use (D28). An organization lists the levels it publishes in `settings.levels`, in display order, and may add a level (`basedOn` any existing level file plus a delta file), alias one (a new name `basedOn` a shipped level with an empty delta) or stop publishing one (D29). `basedOn` is only the starting point: a level's own file may set any id higher or lower than the level it is based on.

## 3. Project kinds and opt-out

The matrix does not know whether a project is a per-tenant extension or an AppSource app, and it does not try to (D21). All ten analyzers are assumed to be enabled in `al.codeAnalyzers` for every project, both Microsoft cops included, and every rule runs at the ladder above. Two groups of rules therefore fire in projects they were not written for:

| Group | Rules | Hits | From level |
|---|---|---|---|
| PerTenantExtensionCop blockers | PTE0001, PTE0002 (ids in 50000..99999), PTE0009 (`helpBaseUrl`, `supportedLocales`), PTE0013 (entitlements), PTE0024 (moved tables), PTE0010 (name length 50) | AppSource apps | Essential |
| AppSourceCop id-range blockers | AS0084, AS0013 (ids in the partner's AppSource range, outside 50000..99999) | Per-tenant extensions | Essential (AS0013), Recommended (AS0084) |
| Marketplace checks | AS0011, AS0054, AS0098 (affixes), AS0051, AS0052, AS0092, AS0015 (manifest fields), supported countries | Per-tenant extensions, and AppSource apps without `AppSourceCop.json` | Recommended |
| Twins | 17 pairs with the identical check in both cops (`overlaps.md` section 2) | Every project: two diagnostics per finding | per pair |

The project, or the organization, opts out of the side that does not apply. Rulebook supports three routes and documents them in the template (`ALCops/rulebook`, `docs/pte-or-appsource.md`):

- **A. Disable a cop** in `al.codeAnalyzers` or the pipeline's analyzer list. Coarse; loses every check of that cop, including the twins' other side. If you do this, keep the `twins` setting at `both`.
- **B. `suppressWarnings` in `app.json`.** Works for any analyzer rule the endpoint does not list, Error defaults included, because the compiler merges it strictest-wins against the ruleset and the endpoint is sparse (D22): a rule at its native severity is not listed. This is the simple route for the blockers above.
- **C. A project ruleset file** that includes the endpoint and carries its own `rules`. Works for every id, listed or not, because a file's own rules beat its includes. This is the flexible route and the one to use when the project also needs exceptions to rules the endpoint lists.

An organization that builds only one kind of extension sets `twins` to `appsource` or `pte` in its Rulebook settings; the generator then writes the other side of every twin at `None` (D23).

## 4. Stages

| Stage | Consumer | Intent | Modification |
|---|---|---|---|
| `default` | Editor (`al.ruleSetPath`) and any consumer without its own stage | Show what the pipeline will show. | None: `Default` is `=` for every rule and the stage has no file; its endpoint is the level result. |
| `CI` | Pull request and release builds | Never block on a diagnostic the team has consciously postponed. | `stages/ci.json`, 10 ids at `Info`: obsolete-pending (AL0432, AL0801, AL1412), implicit conversions (AL0603), XML validation (AL1026) and translation-file mismatches (AL0472, AL0473, AL0479, AL1029, AL1030). |
| `vNext` | Builds against the next major or minor platform | Preview what will hit `CI` next. | `stages/vnext.json`, 95 ids: `Error` for compiler future errors (`WRN_ERR_*`, 92 rules) because the next platform raises them as errors; `Warning` for the 3 obsolete-pending ids because removal is one release closer. |

Every stage, shipped or custom, is one delta file applied on top of every level's default result (D27). A stage token never enables a rule that the level left at `None` (invariant I5, stage rule S-4); that binds custom stage files too. New diagnostic ids that a prerelease compiler introduces are handled by the daily scan and quarantine (WP08), not by the matrix: a quarantined id is written at `None` into the endpoints of the quarantined stages until a base mentions it.

## 5. Generation

The matrix becomes four level files (Essential as a root delta against the analyzer defaults, then one delta per level on the level below) and two stage files (`stages/ci.json`, `stages/vnext.json`), each entry with action and justification. The generator composes them per (level, stage) and writes one flat endpoint that lists only the ids whose action differs from the analyzer default (D22): 12 endpoints for the shipped set, no includes between files. An organization's `twins` setting, overrides and quarantine are folded in when the endpoint is generated. `composition.md` is the generator's contract; `docs/adr/` D18, D19, D21, D22, D23 and D27 record why.

## 6. Invariants

| # | Invariant | Checked by |
|---|---|---|
| I1 | Every inventoried id has exactly one matrix row and resolves to one action in every (level, stage). | V1, V2 |
| I2 | Cumulative: for every stage, the set of enabled ids at a level contains the set at the level below, and no id gets a looser action at a higher level (shipped set; not enforced in an organization repository, D26). | V3, V11 |
| I3 | `Error` appears only for family `runtime`, for the Error defaults of PerTenantExtensionCop and AppSourceCop, and on `vNext` for family `future-error`. | V4, V7 |
| I4 | Contradiction losers are `None` everywhere; LC0089i is `None` everywhere; every twin pair is declared in the inventory, exported to `twins.json` and both sides follow their native ladder. | V5, V6 |
| I5 | A stage token never activates an id whose level action is `None`. | V10 |
| I6 | Every matrix row names a rule row that exists in `02-placement-algorithm.md`; every rule row names a decision record that is not superseded. | V8 |
| I7 | The root level file lists exactly the ids whose Essential action differs from the analyzer default; every other level file lists exactly the ids whose action differs from its `basedOn` level; every stage file lists exactly the ids whose stage column is not `=`; composing them reproduces every resolved cell; every endpoint lists exactly the ids that differ from the analyzer default; no file has includes. | V13 |
