# Precedence, provenance and the effective diff

How `Rulebook.Generate` decides the action of one id in one endpoint, how it names the input that decided it, and how the effective diff shows a change in those terms. Every example below runs against the test fixture `tests/fixtures/repos/valid-minimal` and is asserted by `tests/Rulebook.Generate.Tests.ps1`.

> **Status:** written by WP03 ([#5](https://github.com/ALCops/rulebook-engine/issues/5)). The contract is [rulebook/composition.md](../rulebook/composition.md) section 3; this page works through it. Decisions D19, D22, D23, D27 and D41 in [adr/](../adr/README.md).

---

## Contents

1. [What the effective diff is](#1-what-the-effective-diff-is)
2. [Provenance tokens](#2-provenance-tokens)
3. [The fixture](#3-the-fixture)
4. [Precedence worked through](#4-precedence-worked-through)
5. [Diff examples](#5-diff-examples)
6. [Reading the output](#6-reading-the-output)

---

## 1. What the effective diff is

An endpoint is sparse: it lists only the ids whose effective action differs from the analyzer default (D22). A change to one input (an override, a level file, the catalog) can change many endpoints, and a changed catalog default can change what the compiler does without changing a single line in `rulesets/`. A JSON diff of `rulesets/` shows neither well. The effective diff compares, per endpoint and id, the effective action before and after, with the input that decided it on each side.

`Compare-RulebookEndpoints -RepositoryRoot <path> -Ref <git ref>` computes it between a git ref (before) and the working tree (after). The module takes the ref it is given and throws when the ref does not resolve. Choosing the ref is the Validate action's contract (WP03 PR2): the pull request's base branch on a pull request, `HEAD~1` on a push, and "no diff" in the job summary, never a failure, when the ref does not resolve ([ARCHITECTURE.md](../ARCHITECTURE.md) sections 5.3 and 7.1). Later workflows that open pull requests (scan, ChangeRule, update) can reuse it for their bodies.

## 2. Provenance tokens

`Get-EffectiveAction` returns `Id`, `Action`, `Source`, `Detail`, `Default` and `Listed`. `Source` is one of six tokens, in precedence order:

| Token | The action came from | `Detail` |
|---|---|---|
| `override` | The matching `overrides.json` entry with the most non-wildcard selectors; the later entry on a tie. | The entry's justification. |
| `twins` | The `twins` setting: `appsource` sets the PerTenantExtensionCop side of every pair in `base/twins.json` to `None`, `pte` the AppSourceCop side. | The pair's title. |
| `stage:<slug>` | `stages/<slug>.json`, applied because the level result is not `None` (S-4). | The stage entry's justification. |
| `level:<slug>` | The last file on the level chain that mentions the id; `<slug>` names that file, which may be a level the endpoint is based on. | The level entry's justification. |
| `quarantine` | `quarantine.<stage>.json`, for an id no file on the chain mentions. | The quarantine entry's justification. |
| `default` | Nothing else: the analyzer default from `catalog/diagnostics.json`. | none |

`Default` is the analyzer default (`defaultSeverity` when `enabledByDefault`, else `None`; `$null` for an id the catalog does not know). `Listed` is true when the endpoint file lists the id: the action differs from the default, and an unknown default never equals anything. The dashboard export uses the same tokens ([dashboard.md](../dashboard.md) section 5).

The precedence, in the two-step form of composition.md section 3:

```
levelResult = chain where a file mentions the id  -> level:<slug>
              else None if the stage quarantines it -> quarantine
              else the analyzer default            -> default

effective   = matching override                   -> override
              else None for the losing twin side    -> twins
              else the stage entry, if levelResult is not None (S-4, D41) -> stage:<slug>
              else levelResult
```

## 3. The fixture

`valid-minimal` ships the four levels Essential, Recommended (based on Essential), Strict (based on Recommended) and Complete (based on Strict), the stages `default`, `CI` and `vNext`, `twins: both`, and a 30-id catalog. The inputs used below:

| File | Entries used here |
|---|---|
| `base/essential.ruleset.json` | AL0200, AL0432, AA0001, AA0072, AS0084, LC0015, LC0029, LC0089i, DC0001 at `None` |
| `base/recommended.ruleset.json` | AL0200, AL0432, AA0001, AA0072, LC0029, DC0001 `Warning`; AS0084 `Error`; LC0015, LC0089i `Info`; AC0001 `Warning`; AW0006 `Error` |
| `base/strict.ruleset.json` | AL0603 `Info`, AA0137 `Error`, LC0015 `Warning`, FC0001 `Info`, CM0001 `Info` |
| `stages/ci.json` | AL0432, AL0603, AL1026 `Info` |
| `overrides.json` | AA0072 `Info` for `["*"]`/`["*"]` ("House style"); LC0029 `None` for `["recommended"]`/`["ci"]` ("Backlog DEV-1234") |
| `quarantine.ci.json`, `quarantine.default.json` | LC0099 |
| catalog defaults | AL0200, AL0432, AL0603, AL1026, AA0072, AW0006, LC0001, LC0029, LC0099 `Warning`; AC0001, LC0015 `Info`; LC0054 disabled (`None`) |

## 4. Precedence worked through

### 4.1 One endpoint, every rung: `recommended.ci`

Every candidate id (chain ids, stage ids, override ids, twin sides, the stage's quarantine ids) with its result:

| Id | Effective | Source | Default | Listed | Why |
|---|---|---|---|---|---|
| AA0072 | Info | `override` | Warning | yes | The `["*"]` override beats the chain's Warning. |
| LC0029 | None | `override` | Warning | yes | The override names `recommended` and `ci`. In `strict.ci` it does not match (an override matches only the endpoint's own level slug, never levels based on it). |
| AL0432 | Info | `stage:ci` | Warning | yes | Chain Warning is not `None`, so the stage entry applies. |
| AL0603 | Info | `stage:ci` | Warning | yes | No chain file mentions it; the level result is the default Warning, so the stage entry applies. |
| AL1026 | Info | `stage:ci` | Warning | yes | The same: a stage entry on an id enabled by default. |
| AW0006 | Error | `level:recommended` | Warning | yes | The chain raises it. |
| AC0001 | Warning | `level:recommended` | Info | yes | The chain raises it. |
| AL0200 | Warning | `level:recommended` | Warning | no | Recommended's delta replaces Essential's `None` with the default; nothing to write. |
| LC0099 | None | `quarantine` | Warning | yes | No chain file mentions it and `quarantine.ci.json` lists it. |
| PTE0003 | Error | `default` | Error | no | With `twins: both` the twin sides run at their default. |

The endpoint file lists the rows with "yes", sorted by id (prefix order `AL, AA, AW, PTE, AS, PC, AC, LC, DC, FC, TA, CM`, then number, then the `i` suffix):

```json
{
  "name": "Rulebook Recommended / CI",
  "description": "Level recommended, stage ci, twins both. Generated from base/essential.ruleset.json, base/recommended.ruleset.json plus stages/ci.json, overrides.json and quarantine.ci.json; do not edit. Ids at their analyzer default are not listed.",
  "rules": [
    { "id": "AL0432", "action": "Info" },
    { "id": "AL0603", "action": "Info" },
    { "id": "AL1026", "action": "Info" },
    { "id": "AA0072", "action": "Info" },
    { "id": "AW0006", "action": "Error" },
    { "id": "AC0001", "action": "Warning" },
    { "id": "LC0029", "action": "None" },
    { "id": "LC0099", "action": "None" }
  ]
}
```

### 4.2 S-4 at `essential.ci`

Essential sets AL0432 to `None`. `stages/ci.json` says `Info`, but a stage never activates a rule: the level result is `None`, so the stage entry is skipped and AL0432 stays `None` with `level:essential`. AL0603 and AL1026, which Essential does not mention, still get `Info` from the stage because their level result is the enabled default.

### 4.3 The #42 case: quarantine and a stage entry (D41)

The fixture `quarantined-stage-entry` adds `{ "id": "LC0099", "action": "Info" }` to `stages/ci.json`. LC0099 is in `quarantine.ci.json` and no level file mentions it. Its level result is `None` (`quarantine`), so the stage entry does not apply and LC0099 stays `None` in every `*.ci` endpoint; the endpoints are byte-identical to `valid-minimal`. Validation reports the stage entry as C15, a warning: it is dead until a level file adopts LC0099, after which the chain wins over quarantine and the stage entry applies to the chain's action.

The generator decides quarantine per endpoint, from that level's chain. So the same stage entry can be dead in one level (no file on its chain mentions the id) and live in another (a file on its chain does). C15 fires only when the entry is dead in every published level.

### 4.4 Specificity and ties

For one id and endpoint, every matching override entry is a candidate. The one with more non-wildcard selectors wins (`["recommended"]`/`["*"]` beats `["*"]`/`["*"]`, `["recommended"]`/`["ci"]` beats both), whatever the order in the file. Between equally specific entries the later one wins. An override whose action equals the analyzer default is valid and unlists the id: AA0072 `Warning` for `["essential"]` gives `Warning` (`override`), equal to the default, so `essential.*` stop listing it.

### 4.5 Twins: `appsource`

With `twins: appsource` (fixture `twins-appsource`) both PTE sides become `None` in all 12 endpoints, with `twins` as source and the pair title as detail; the AS sides stay at their default and are not listed. In `recommended.ci`:

| Id | Effective | Source | Detail |
|---|---|---|---|
| PTE0003 | None | `twins` | Procedures must not subscribe to CompanyOpen events |
| PTE0011 | None | `twins` | The publisher name is too long |

An override on a twin side beats the setting: PTE0003 `Warning` for `["*"]`/`["*"]` gives `Warning` (`override`).

## 5. Diff examples

Each example commits `valid-minimal`, changes one input in the working tree and runs `Compare-RulebookEndpoints -Ref HEAD`. The text column is each row's `Text` property.

| Change | Rows | Example row |
|---|---|---|
| The LC0029 override goes from `None` to `Info` | 1, `recommended.ci`, `action` | `LC0029: None (override, "Backlog DEV-1234") -> Info (override, "Backlog DEV-1234")` |
| The LC0029 override is removed | 1, `recommended.ci`, `action` | `LC0029: None (override, "Backlog DEV-1234") -> Warning (level:recommended)` |
| LC0001's catalog default goes from Warning to Info; no file mentions LC0001 | 12, one per endpoint, `action` | `LC0001: Warning (default) -> Info (default)` |
| AW0006's catalog default goes from Warning to Error, the action Recommended already sets | 9 `listing` rows (`recommended.*`, `strict.*`, `complete.*`), 3 `action` rows (`essential.*`) | `AW0006: Error (level:recommended, "...") -> Error (level:recommended, "...")` with `ListedBefore` true, `ListedAfter` false |
| A level Paranoid based on Complete is added | `endpoint-added` rows for `paranoid.default`, `paranoid.ci`, `paranoid.vnext`, one per listed id | `TA0001: (absent) -> Error (level:paranoid)` |

The changed default is why the diff compares effective actions: LC0001 changes what the compiler does in every endpoint while `rulesets/` stays byte-identical, and AW0006 leaves the effective action unchanged while nine endpoint files lose a line. Every catalog id whose default differs between the two sides is compared, mentioned by an input or not.

A ref without `.github/Rulebook-Settings.json` (a commit before the rulebook existed, or the first pull request of a fixture) is an empty rulebook: every endpoint is `endpoint-added`. An unknown ref, or one that starts with `-`, throws; the action reports that as "no diff" and does not fail.

## 6. Reading the output

`Compare-RulebookEndpoints` returns one row per endpoint and id, ordered by endpoint (settings order, then endpoints only the ref has) and then by id:

| Property | Meaning |
|---|---|
| `Endpoint`, `File` | `strict.ci` and `rulesets/strict.ci.ruleset.json` (the `default` stage has no suffix in `File`) |
| `Id` | The diagnostic id; `$null` only on the one row of an added or removed endpoint that lists nothing |
| `Before`, `After` | The effective action at the ref and in the working tree; `$null` on the side where the endpoint does not exist |
| `BeforeSource`, `AfterSource` | The provenance tokens of section 2 |
| `BeforeDetail`, `AfterDetail` | The deciding entry's justification or the twin pair title |
| `ListedBefore`, `ListedAfter` | Whether the endpoint file lists the id on each side |
| `Change` | `action` (the effective action changed), `listing` (same action, listed on one side only, which happens when the analyzer default moves), `endpoint-added`, `endpoint-removed` |
| `Text` | `<Id>: <Before> (<source>[, "<detail>"]) -> <After> (<source>[, "<detail>"])`, with `(absent)` for a missing side |

The Validate job summary groups the rows into one table per changed endpoint, `| Id | Before | After | Decided by |`, where "Decided by" is the after side's source and detail; "No effective change" when there are no rows.
