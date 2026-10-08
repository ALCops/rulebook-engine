# Change mechanics

How a rule change reaches an organization rulebook repository: the change set the Change Rule workflow builds, how an entry of `overrides.json` is set, replaced or removed, what is validated and in which order, when a change is a no-op, how the candidate is planned without touching the repository, how the table and the pull request body are written, and how the change lands. The design is in [ARCHITECTURE.md](../ARCHITECTURE.md) sections 7.5 and 7.6, the decisions in [D11](../adr/0011-rule-changes-go-through-a-workflow-dispatch-form.md), [D19](../adr/0019-organization-overrides-and-quarantine-are-generator-inputs.md), [D30](../adr/0030-changerule-dropdowns-are-rewritten-from-the-settings-by-the.md), [D32](../adr/0032-dashboard-writes-go-through-a-prefilled-github-issue-form.md), [D33](../adr/0033-one-submission-is-a-change-set-many-changes-one-issue-one.md), [D37](../adr/0037-justification-is-optional-in-every-change-path.md), [D47](../adr/0047-changerule-follows-commitoptions-and-has-no-directcommit-input.md) and [D48](../adr/0048-no-op-changes-are-reported-and-never-written.md).

> **Status:** written by WP09 ([#11](https://github.com/ALCops/rulebook-engine/issues/11)). Code: `modules/Rulebook.Edit.psm1`, `actions/ChangeRule/`, `template/.github/workflows/ChangeRule.yaml`. Everything below is derived from that code and its tests unless it says *observed*; the live run is section 11.

---

## Contents

1. [The change set](#1-the-change-set)
2. [Setting, replacing and removing an entry](#2-setting-replacing-and-removing-an-entry)
3. [Validation](#3-validation)
4. [No-op and partial changes](#4-no-op-and-partial-changes)
5. [Plan and candidate](#5-plan-and-candidate)
6. [Table, pull request body and job summary](#6-table-pull-request-body-and-job-summary)
7. [Branch, title and landing](#7-branch-title-and-landing)
8. [Action reference](#8-action-reference)
9. [The workflow and its choice lists](#9-the-workflow-and-its-choice-lists)
10. [Tests and CI](#10-tests-and-ci)
11. [Live run](#11-live-run)
12. [Hooks for WP15](#12-hooks-for-wp15)

---

## 1. The change set

A change set is an in-memory dictionary `{ note?, changes[] }` (D32). Each change is `{ op, id, action?, levels, stages, justification? }`:

| `op` | Meaning |
|---|---|
| `set` | Write the override entry of `id` for the `levels` and `stages` selection with `action` (Error, Warning, Info, Hidden, None) and an optional `justification` (D37). |
| `remove` | Delete the entry of `id` with exactly these `levels` and `stages`. No `action`. |
| `release` | Reserved for WP15 (remove an id from the quarantine of the listed stages); refused today with "op 'release' is reserved; it arrives with WP15". |

`levels` and `stages` are `["*"]` or a list of slugs of the settings, the selector format of `overrides.json` (D19). A change set is applied all or nothing and regenerated once.

The Change Rule form is a one-item client: `ConvertTo-RulebookChangeSet -RuleId -Action -Levels -Stages [-Justification] [-Note]` builds `{ changes = @({ op = 'set', id, action, levels, stages, justification? }) }`, and `Action Remove` (any case) becomes `op remove` without an action. A known action is written in its canonical case (`none` becomes `None`), surrounding blanks are trimmed, an empty justification is left out. The action input `levels` and `stages` take one slug or `*`; a comma-separated list also works for a hand-run of the action.

## 2. Setting, replacing and removing an entry

`overrides.json` is read with `Read-OverridesFile` (strings stay strings, so a justification that looks like a date is not turned into a date) and written with `ConvertTo-OverridesJson` in the template layout: `$schema`, then one entry per line in the key order `id`, `action`, `levels`, `stages`, `justification` (left out when empty), two-space indent, LF, one trailing LF, `"rules": []` when empty. `template/overrides.json` and the fixture `valid-minimal/overrides.json` round-trip byte for byte. A file that was formatted differently by hand is rewritten in this layout the first time a change writes it.

| Function | Rule |
|---|---|
| `Set-RulebookOverride` | An entry with the same id and the **same level set and stage set** (ordinal, order and duplicates ignored: `["strict", "complete"]` equals `["complete", "strict"]`) is replaced in place: new action, new justification (an empty one drops the key), its position and its own selector order kept. Change `replaced`, or `unchanged` when action and justification are equal already. Any other selection appends a new entry (`added`), so the file never collects two entries with the same selectors. |
| `Remove-RulebookOverride` | Removes the entry (every entry, should a hand edit have left duplicates) with the same id and selector sets. Everything else in the file stays byte-identical (AC4). |

An entry with a different selection is a separate entry: a later `strict`/`ci` entry next to an existing `*`/`ci` entry wins on `strict.ci` by specificity, as [composition.md](../rulebook/composition.md) defines.

## 3. Validation

In this order; the first stage that finds something stops the run before anything is copied or written (AC5):

1. The repository: `Read-RulebookInputs` must read it (settings present, chain resolvable). A failure is one finding "The rulebook cannot be read: ...".
2. `Test-RulebookChangeSet` against the settings and the catalog, findings `{ Rule 'change', Severity 'error', File 'overrides.json', Id, Message }`:

| Check | Message |
|---|---|
| `changes` is empty | `The change set has no changes.` |
| `op` | `change <n>: op 'release' is reserved; it arrives with WP15`, or `change <n>: op '<op>' is not supported; use set or remove` |
| id pattern `^[A-Z]{2,3}\d{4}i?$` | `'<id>' is not a diagnostic id: two or three capital letters, four digits and an optional i, for example LC0015` |
| id in `catalog/diagnostics.json` | `<id> is not in catalog/diagnostics.json` |
| action of a `set` | `action '<action>': use Error, Warning, Info, Hidden or None` (the C4 wording) |
| selectors | `change <n> has no levels; ...`, `change <n> mixes '*' with other values in levels; ...`, `change <n> names unknown level '<slug>'; use a slug from the settings or ["*"]` (the C10 wording) |
| duplicates | `change <n> repeats an earlier change (same op, id, levels and stages)` |

3. The operations in memory. A `remove` without a matching entry is a finding: `overrides.json has no entry for LC0015 with levels [strict] and stages [ci]; existing entries for LC0015: None (levels: *, stages: ci), Info (levels: strict, stages: *)`, or `overrides.json has no entry for LC0015` when the id has none (D48).
4. After the regeneration, `Test-Rulebook` on the candidate (checks C1 to C16). An error there fails the run with every finding, each prefixed "The changed rulebook would not validate:", and nothing is pushed.

The form's dropdowns can be stale between a settings change and the next update (D30); the slug check keeps such a value from being written.

## 4. No-op and partial changes

D48, per change set:

| Situation | Result |
|---|---|
| No matching endpoint changes and `overrides.json` would not change (same action, same justification) | **No-op**: notice `No change: LC0015 is already None on every matching endpoint (strict.ci); overrides.json was not written`, the table in the job summary with every row `unchanged`, outputs `result=no-op` and `noop=true`, exit code 0, nothing written, no token needed. |
| At least one endpoint changes | Written. The table lists every matching endpoint; rows that stay the same say `unchanged`, and the body adds `<k> of <n> matching endpoints are unchanged.` |
| Same action, different justification | Written: the file changes, no endpoint does. Every row `unchanged` with the note `justification updated`, no file in `rulesets/` changes. |
| An id set to its analyzer default where the base deviates | Written (AC3): the id is no longer listed in that endpoint, the row note is `now unlisted in <endpoint>: <action> equals the analyzer default` and the body repeats it as a sentence. |
| `remove` | Never a no-op: the file always changes. |
| `remove` without a matching entry | Validation error (section 3). |

The endpoint comparison uses the effective action and the listed status (`Get-EffectiveAction` on the working tree and on the candidate), the two things an endpoint file depends on.

## 5. Plan and candidate

`Invoke-RulebookChangeSet -RepositoryRoot -ChangeSet [-WorkPath] [-Now]` returns a `Rulebook.ChangePlan` and **never writes into the repository**:

1. The head of the checkout (`HeadSha`, for the base-moved guard of section 7) and the inputs of the working tree.
2. Validation (section 3, steps 1 to 3). A finding returns `Valid $false`, `Failure validation`, no candidate.
3. The repository is copied to `<WorkPath>/candidate` (`Copy-UpdateTree`, without `.git`), and `overrides.json` is written there unless every entry is unchanged (`OverridesChange`).
4. One row per item and matching endpoint (`*` expanded in settings order): `{ Endpoint, File, Id, Before, After, BeforeSource, AfterSource, BeforeDetail, AfterDetail, ListedBefore, ListedAfter, Changed, Note }`, from the inputs of the working tree and of the candidate, both in memory. Rows are not taken from `Compare-RulebookEndpoints`, which lists changed rows only and needs a git ref.
5. `NoOp` (section 4). A no-op returns here: `Valid $true`, `Changes` empty, no regeneration.
6. `Update-RulebookEndpoints` on the candidate (a failure is the finding "The changed rulebook cannot be regenerated: ..."), then `Test-Rulebook`: `Findings`, `Valid`.
7. `Changes`: every file that differs between the repository and the candidate, `{ File, Change (created, modified, deleted), Bytes }`, the list `Publish-RulebookChange` writes into its clone.

The plan carries `Root`, `CandidatePath`, `HeadSha`, `Now`, `ChangeSet`, `Items[]` (`Op`, `Id`, `Action`, `Levels`, `Stages`, `Justification`, `Entry { Change, Previous }`, `Rows[]`, `ChangedEndpoints`, `NoOp`, `Notes[]`), `OverridesChange`, `Changes[]`, `Findings[]`, `Valid`, `Failure`, `NoOp` and `Title`.

## 6. Table, pull request body and job summary

`ConvertTo-ChangeTable` writes `| Endpoint | Before | After | Note |`, one row per matching endpoint. A side is the effective action with its provenance, the tokens of [effective-diff.md](effective-diff.md) section 2: `Warning (level:recommended)`, `None (override)`, `None (override, "Legacy tables")` with a justification, `Info (stage:ci)`, `None (twins, "<pair title>")`, `None (quarantine)`, `Warning (default)`. Free text goes through `Format-TableCell` (a `|` is escaped).

The pull request body (`ConvertTo-ChangePullRequestBody`):

```
Justification: Legacy tables, tracked in issue 42

Sets LC0015 to None for levels strict, stages ci (replaces the entry that was Warning).

| Endpoint | Before | After | Note |
|---|---|---|---|
| strict.ci | Warning (level:strict) | None (override, "Legacy tables, tracked in issue 42") |  |
```

The first paragraph is the justification of a one-item change, else the note of the change set, else `No justification given.` The sentence per item is one of `Sets <id> to <action> for levels <l>, stages <s> (adds an entry).`, `(replaces the entry that was <action>).`, `Updates the justification of the <id> entry for levels <l>, stages <s> (the action stays <action>).` and `Removes the override entry for <id> with levels <l>, stages <s> (it was <action>).`; notes follow as a list (unlisted ids, unchanged count). Above 60000 characters the tables are left out from the end with one italic line, then the body is cut at a line boundary.

The job summary (`ConvertTo-ChangeSummary`) has `## Rule change`, the message, the pull request or commit line, the same paragraph and tables, `## Validation errors` when there are any, and `## Effective diff`: the git-based diff of the pushed commit against the cloned head (`Compare-RulebookEndpoints`, the Validate rendering). That diff appears only in the summary, never in the body (WP09 interview, decision 14): the reviewer reads the in-memory table, and Validate on the pull request shows the effective diff again.

## 7. Branch, title and landing

| Thing | Value |
|---|---|
| Branch | `change-rule/<ruleId>/<yyMMddHHmmss>` (UTC, from `-Now`); a fresh branch per run, so two runs never collide and there is no duplicate guard |
| Title (commit and pull request) | `Change LC0015 to None (levels: strict, stages: ci)`, `Remove override for LC0015 (levels: strict, stages: ci)`; several items (WP15): `Rulebook change: <n> changes` |
| Labels | `commitOptions.pullRequestLabels` |
| Landing | `commitOptions.createPullRequest` true or absent: pull request; false: direct commit to the branch the workflow runs on (D47) |

`Publish-RulebookChange` refuses an invalid or no-op plan, clones the base branch with the write token, refuses a base branch that moved since the plan read the checkout (`The base branch moved since the change was planned (main 1a2b3c4 is now 5d6e7f8); nothing was pushed. Run the workflow again.`, stage `push`, reason `base-moved`), writes `Changes`, commits with the title and pushes the branch (`Publish-GitHubChange` without `-Force`), or the base branch with `-DirectCommit`. A refused direct push (branch protection) moves the commit to the new branch and opens the pull request (`Fallback`, the notice says "(the direct commit was refused)"). Then the effective diff against the cloned head and the pull request with the labels. A failure after the push names the pushed branch and its tree link.

## 8. Action reference

`actions/ChangeRule/action.yaml`, one `pwsh` step, inputs through `INPUT_*` environment variables only:

| Input | Default | Meaning |
|---|---|---|
| `ruleId` | required | The diagnostic id. |
| `action` | required | Error, Warning, Info, Hidden, None, or Remove. |
| `levels`, `stages` | `'*'` | A slug or `*`. |
| `justification` | `''` | Optional. |
| `token` | `''` | The `GHTOKENWORKFLOW` value; not needed for a validation error or a no-op. |
| `directCommit` | `'false'` | The workflow passes `-not createPullRequest`. |
| `baseBranch` | `${{ github.ref_name }}` | |
| `repositoryRoot` | `'.'` | |
| `actor` | `${{ github.actor }}` | The git author of the commit. |

| Output | Values |
|---|---|
| `result` | `pull-request`, `direct-commit`, `no-op`; empty on failure |
| `noop` | `true` or `false` |
| `changedEndpoints` | Comma-separated endpoints, for example `strict.ci` |
| `pullRequestUrl`, `branch` | The pull request and the pushed branch (the base branch for a direct commit) |
| `failure` | `validation`, `token`, `push`, `pull-request`, `error`; empty on success |

Order in `ChangeRule.ps1`: settings (secret name, labels), the plan, the validation annotations (`::error file=<path>,title=<rule>::...`, failure `validation`) or the no-op notice, then **the token guard** (an invalid `ghTokenWorkflowSecretName`, or `The GHTOKENWORKFLOW secret is needed to change a rule. Read <docs>`, failure `token`), the exchange and `::add-mask::` before anything else prints, then the publish. The guard runs after the local plan so a wrong rule id or a no-op answers without a secret; the token is still exchanged and masked before any request. Push and pull-request failures carry the token hint (`Make sure that the token in the secret ... may write contents and pull requests`); a moved base does not. The summary is capped at 900 KiB with `Limit-SummaryText`. The script never calls `exit`; `-RemoteUrl`, `-ApiUrl`, `-WorkPath`, `-SummaryLimit`, `-Now` and `-PublishCommand` are test seams.

## 9. The workflow and its choice lists

`template/.github/workflows/ChangeRule.yaml` (system file): `workflow_dispatch` with `ruleId` (string, required), `action` (choice), `levels` and `stages` (choice, default `'*'`, the shipped slugs), `justification` (string, optional); `permissions: contents: read` (the change is pushed with the secret's token, so the pull request runs Validate); `concurrency: change-rule-${{ github.ref }}` without cancelling; checkout without persisted credentials; a "Read the settings" step that resolves the secret name and `directCommit = -not commitOptions.createPullRequest` on every run (D47), with no `directCommit` input; then `ALCops/rulebook-engine/actions/ChangeRule@main` (pinned to `@v1` by the deploy, WP13).

The update rewrites the `levels` and `stages` options from the settings (D30, [update-mechanics.md](update-mechanics.md) section 5): `'*'` and the slugs in settings order. The shipped file is laid out so that rewrite with the shipped settings reproduces it byte for byte; an organization that adds a level `House` gets `house` in its form after the next update.

## 10. Tests and CI

- `tests/Rulebook.Edit.Tests.ps1`: the round trips, write-on-change and `-WhatIf`; set on an empty array, replace in place with order-insensitive selectors, the dropped justification, `unchanged`, append; remove with the rest of the file byte-identical (AC4) and the miss message; every `Test-RulebookChangeSet` message; `Invoke-RulebookChangeSet` for AC1 (one endpoint), AC2 (all 12), AC3 (unlisted), AC5 (nothing copied, repository untouched), AC6 (no-op), justification-only, partial, `*` order and remove; title, table, body (and its limit) and summary; `Publish-RulebookChange` against a bare repository (pull request with labels and body, direct commit, fallback with a push-refusing hook, base moved, the pull-request failure, refused plans).
- `tests/ChangeRule.Action.Tests.ps1`: `action.yaml`; the template workflow (inputs and option lists, permissions, concurrency, secret lookup, no interpolation in `run`, the settings step run in-process for `createPullRequest` false, true and absent); `ChangeRule.ps1` in-process (validation, remove miss, no-op without a token, token guard and mask, the publish seam with outputs and summary, failure mapping, work folders, and against a bare remote: direct commit, pushed branch, fallback).
- `tests/Rulebook.Update.Tests.ps1`: the shipped `ChangeRule.yaml` rewritten with the shipped settings is unchanged, with a level `House` it gains `house` in settings order.
- CI job `changerule-action` on a copy of `valid-minimal`, no token: `AA0001` `None` `*`/`*` fails with `token`, `AA0072` `Info` `*`/`*` with the justification `House style` is a no-op, `LC9999` fails with `validation`.

## 11. Live run

*To be recorded after the live run on `Arthurvdv/rulebook-e2e-changerule` (WP09 plan section 6.7): the run ids and pull request links of AC1 to AC6, the token failure, the remove miss, the direct commit with `createPullRequest: false` and the choice-list rewrite after adding a level.*

## 12. Hooks for WP15

- `Invoke-RulebookChangeSet` already takes a change set with several items, applies them all or nothing and regenerates once; `Get-RulebookChangeTitle` names a multi-item change `Rulebook change: <n> changes`; the body has one sentence and table per item.
- `release` is reserved in `Test-RulebookChangeSet`; WP15 implements it on the quarantine files (`Rulebook.Quarantine`).
- The change set schema `schemas/rulebook-changeset.schema.json` and the issue-form parsing are WP15.
- `Publish-RulebookChange -BranchPrefix` is `change-rule/<ruleId>` for the form and `rulebook-change/<issue>` for the issue path; the landing rule (D33, D47) is the same.
