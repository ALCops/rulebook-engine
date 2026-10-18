# Change mechanics

How a rule change reaches an organization rulebook repository: the change set the Change Rule workflow builds or a `rulebook-change` issue carries, how an entry of `overrides.json` is set, replaced or removed and a quarantined id released, what is validated and in which order, when a change is a no-op, how the candidate is planned without touching the repository, how the table and the pull request body are written, and how the change lands. The design is in [ARCHITECTURE.md](../ARCHITECTURE.md) sections 7.5 and 7.6, the decisions in [D11](../adr/0011-rule-changes-go-through-a-workflow-dispatch-form.md), [D19](../adr/0019-organization-overrides-and-quarantine-are-generator-inputs.md), [D30](../adr/0030-changerule-dropdowns-are-rewritten-from-the-settings-by-the.md), [D32](../adr/0032-dashboard-writes-go-through-a-prefilled-github-issue-form.md), [D33](../adr/0033-one-submission-is-a-change-set-many-changes-one-issue-one.md), [D37](../adr/0037-justification-is-optional-in-every-change-path.md), [D47](../adr/0047-changerule-follows-commitoptions-and-has-no-directcommit-input.md) and [D48](../adr/0048-no-op-changes-are-reported-and-never-written.md).

> **Status:** written by WP09 ([#11](https://github.com/ALCops/rulebook-engine/issues/11)); WP15 ([#17](https://github.com/ALCops/rulebook-engine/issues/17)) adds the change set version, the `release` operation and the module functions of the issue path (section 12). Code: `modules/Rulebook.Edit.psm1`, `modules/Rulebook.GitHub.psm1`, `actions/ChangeRule/`, `template/.github/workflows/ChangeRule.yaml`. Everything below is derived from that code and its tests unless it says *observed*; the live run of the Change Rule workflow is section 11.

---

## Contents

1. [The change set](#1-the-change-set)
2. [Setting, replacing and removing an entry, releasing an id](#2-setting-replacing-and-removing-an-entry-releasing-an-id)
3. [Validation](#3-validation)
4. [No-op and partial changes](#4-no-op-and-partial-changes)
5. [Plan and candidate](#5-plan-and-candidate)
6. [Table, pull request body and job summary](#6-table-pull-request-body-and-job-summary)
7. [Branch, title and landing](#7-branch-title-and-landing)
8. [Action reference](#8-action-reference)
9. [The workflow and its choice lists](#9-the-workflow-and-its-choice-lists)
10. [Tests and CI](#10-tests-and-ci)
11. [Live run](#11-live-run)
12. [The issue path: module functions](#12-the-issue-path-module-functions)

---

## 1. The change set

A change set is a dictionary `{ version, note?, changes[] }` (D32), the shape of `schemas/rulebook-changeset.schema.json` ([dashboard.md](../dashboard.md) section 6). `version` is the number 1; a change set read from an issue must carry it (the schema requires it), an in-memory one may leave it out. Each change is `{ op, id, action?, levels?, stages, justification? }`:

| `op` | Meaning |
|---|---|
| `set` | Write the override entry of `id` for the `levels` and `stages` selection with `action` (Error, Warning, Info, Hidden, None) and an optional `justification` (D37). |
| `remove` | Delete the entry of `id` with exactly these `levels` and `stages`. No `action`. |
| `release` | Remove `id` from `quarantine.<stage>.json` of every stage in `stages`. No `levels` (a quarantine file holds whole stages) and no `action` (the released id falls back to whatever decides it without the quarantine; [dashboard.md](../dashboard.md) Q2). |

`levels` and `stages` are `["*"]` or a list of slugs of the settings, the selector format of `overrides.json` (D19). A change set is applied all or nothing and regenerated once.

The Change Rule form is a one-item client: `ConvertTo-RulebookChangeSet -RuleId -Action -Levels -Stages [-Justification] [-Note]` builds `{ version = 1, note?, changes = @({ op = 'set', id, action, levels, stages, justification? }) }`, and `Action Remove` (any case) becomes `op remove` without an action. A known action is written in its canonical case (`none` becomes `None`), surrounding blanks are trimmed, empty selector values are dropped and a repeated slug is kept once (ordinal, order kept), an empty justification is left out. The action input `levels` and `stages` take one slug or `*`; a comma-separated list also works for a hand-run of the action.

## 2. Setting, replacing and removing an entry, releasing an id

`overrides.json` is read with `Read-OverridesFile` (strings stay strings, so a justification that looks like a date is not turned into a date) and written with `ConvertTo-OverridesJson` in the template layout: `$schema`, then one entry per line in the key order `id`, `action`, `levels`, `stages`, `justification` (left out when empty), two-space indent, LF, one trailing LF, `"rules": []` when empty. `template/overrides.json` and the fixture `valid-minimal/overrides.json` round-trip byte for byte. A file that was formatted differently by hand is rewritten in this layout the first time a change writes it. The reader accepts `//` and `/* */` comments and trailing commas, as `ConvertFrom-Json` in `Rulebook.Generate` does; the writer drops them.

| Function | Rule |
|---|---|
| `Set-RulebookOverride` | An entry with the same id and the **same level set and stage set** (ordinal, order and duplicates ignored: `["strict", "complete"]` equals `["complete", "strict"]`) is replaced in place: new action, and a new justification only when one is given; an empty justification keeps the entry's text (an entry without one stays without one; clearing a justification is a hand edit or a later dashboard change set). Its position and its own selector order are kept. Change `replaced`, or `unchanged` when the action is the same and the justification is empty or the same. Any other selection appends a new entry (`added`), so the file never collects two entries with the same selectors. Should a hand edit have left several entries with the same selectors, they collapse into the last of them, the effective entry (on equal specificity the later entry wins), at its position, so the precedence against other entries stays: it is reported as the previous entry and its justification survives when none is given (the earlier duplicates' text is dropped). When the requested action and justification equal that effective entry, the change is `deduplicated`: written (the file loses the duplicates), every row noted `duplicate entries removed`, the sentence `Removes the duplicate entries of <id> for ... (the action stays <action>).` |
| `Remove-RulebookOverride` | Removes the entry (every entry, should a hand edit have left duplicates) with the same id and selector sets. Everything else in the file stays byte-identical (AC4). |

An entry with a different selection is a separate entry: a later `strict`/`ci` entry next to an existing `*`/`ci` entry wins on `strict.ci` by specificity, as [composition.md](../rulebook/composition.md) defines.

A `release` works on the quarantine files, read and written by `Rulebook.Quarantine` (`Read-QuarantineFile`, `Write-QuarantineFile`; [scan-mechanics.md](scan-mechanics.md) section 4). `Remove-RulebookQuarantine -Files -Id -Stages` takes the files of every stage of the settings, in settings order, and expands `*` to all of them: a stage whose file lists the id loses the entry (`Removed`, with the justification it had), a stage whose file does not list it goes to `Unlisted` and is no error. Only the files that lost an entry are written, in the template layout (`$schema`, then one `{ "id", "justification" }` per line), so a quarantine file that was formatted differently by hand is normalised the first time a release writes it; the other entries keep their text. A release never creates a file, never touches `overrides.json` and never adds an override: the released id gets whatever decides it once the quarantine no longer does (a level file, a stage file, an override or a twin, else the analyzer default).

## 3. Validation

In this order; the first stage that finds something stops the run before anything is copied or written (AC5):

1. The repository: `Read-RulebookInputs` must read it (settings present, chain resolvable, every quarantine file readable). A failure is one finding "The rulebook cannot be read: ...".
2. `Test-RulebookChangeSet` against the settings and the catalog, findings `{ Rule 'change', Severity 'error', File 'overrides.json', Id, Message }`:

| Check | Message |
|---|---|
| `version`, when present, is the number 1 (the string `"1"` is refused, as by the schema's `const`); any other value stops the check with this one finding | `version '<v>' is not supported; this engine applies change sets of version 1` |
| `changes` is empty | `The change set has no changes.` |
| `op` | `change <n>: op '<op>' is not supported; use set, remove or release` |
| a `release` with `levels` or an `action` | `change <n>: op 'release' takes no levels; it releases the id from the quarantine of the listed stages` (or `takes no action`) |
| id pattern `^[A-Z]{2,3}\d{4}i?$` | `'<id>' is not a diagnostic id: two or three capital letters, four digits and an optional i, for example LC0015` |
| id in `catalog/diagnostics.json` | `<id> is not in catalog/diagnostics.json` |
| action of a `set` | `action '<action>': use Error, Warning, Info, Hidden or None` (the C4 wording) |
| selectors | `change <n> has no levels; ...`, `change <n> mixes '*' with other values in levels; ...`, `change <n> names unknown level '<slug>'; use a slug from the settings or ["*"]` (the C10 wording); a `release` has `stages` only |
| duplicates | `change <n> repeats an earlier change (same op, id, levels and stages)`; a `release` compares its id and its stage set |

3. The operations in memory. When the set has a `release`, the quarantine file of every stage of the settings is read first (a file that cannot be read is a finding on `quarantine.<stage>.json`; `Read-RulebookInputs` reads the same files in step 1 and stops there first). A `remove` without a matching entry is a finding: `overrides.json has no entry for LC0015 with levels [strict] and stages [ci]; existing entries for LC0015: None (levels: *, stages: ci), Info (levels: strict, stages: *)`, or `overrides.json has no entry for LC0015` when the id has none (D48).
4. After the regeneration, `Test-Rulebook` on the candidate (checks C1 to C16). An error there fails the run with every finding, each prefixed "The changed rulebook would not validate:", and nothing is pushed.

The form's dropdowns can be stale between a settings change and the next update (D30); the slug check keeps such a value from being written.

## 4. No-op and partial changes

D48, per change set:

| Situation | Result |
|---|---|
| No matching endpoint changes, and the entry is unchanged (same action; the justification empty, so the entry keeps its text, or the same) or would be new (a dead entry: the base, the stage, an existing broader entry or the twins setting already give that action everywhere the selection matches) | **No-op**: notice `No change: LC0015 is already None on every matching endpoint (strict.ci); overrides.json was not written`, or, when a more specific entry or input keeps another action on some endpoints, `No change: LC0015 keeps its effective action on every matching endpoint (2 at Warning; 1 decided by a more specific entry or input: strict.ci None (override)); overrides.json was not written`; a justification given for a dead entry shows as `Justification given but not stored (no entry was written): <text>`; the table in the job summary with every row `unchanged`, outputs `result=no-op` and `noop=true`, exit code 0, nothing written, no token needed. |
| A new entry, a removed entry, or a changed action that alters at least one endpoint | Written. The table lists every matching endpoint; rows that stay the same say `unchanged`, and the body adds `<k> of <n> matching endpoints are unchanged.` |
| Same action, a new non-empty justification | Written: the file changes, no endpoint does. Every row `unchanged` with the note `justification updated`, no file in `rulesets/` changes. |
| An id set to its analyzer default where the base deviates | Written (AC3): the id is no longer listed in that endpoint, the row note is `now unlisted in <endpoint>: <action> equals the analyzer default` and the body repeats it as a sentence. |
| A changed action that alters no endpoint (a more specific entry or input masks every matching endpoint) | Written (the entry is `replaced`); every row `unchanged`, the table shows why nothing changes (the deciding source on the after side). |
| Duplicates of the effective entry removed (`deduplicated`) | Written, every row `duplicate entries removed`. |
| `remove` | Never a no-op: the file always changes. |
| `release` of an id that no quarantine file of the selected stages lists | **No-op** (`Released` empty): the sentence `Leaves <id> as it is for stages <sel> (no quarantine file of these stages lists it; nothing is written).`, every row noted `not quarantined in <stage>`. |
| `release` that frees the id in at least one stage | Written, also when no endpoint changes (an override, a level or a twin decides every matching endpoint): the quarantine file changes, as a `replaced` or `deduplicated` entry is written. The rows cover every level of the selected stages; a row of a stage whose file did not list the id has the note `not quarantined in <stage>`, and the item the note `<id> is not quarantined in <stage>; nothing to release there.` |
| Several items | A dead new entry is dropped before `overrides.json` is written, also when another item changes something, and the other items are recomputed without it (when no other item changes `overrides.json`, the file stays as the repository has it, not rewritten in the template layout); the set is a no-op only when every item is. |
| `remove` without a matching entry | Validation error (section 3). |

The endpoint comparison uses the effective action and the listed status (`Get-EffectiveAction` on the working tree and on the candidate), the two things an endpoint file depends on.

## 5. Plan and candidate

`Invoke-RulebookChangeSet -RepositoryRoot -ChangeSet [-WorkPath] [-Now]` returns a `Rulebook.ChangePlan` and **never writes into the repository**:

1. The head of the checkout (`HeadSha`, for the base-moved guard of section 7) and the inputs of the working tree.
2. Validation (section 3, steps 1 to 3). A finding returns `Valid $false`, `Failure validation`, no candidate. When `git rev-parse HEAD` fails (no git, or not a checkout), `HeadSha` stays empty and the base-moved guard of section 7 is off; the action then writes the warning `base-move guard inactive: the checkout HEAD could not be read`.
3. The repository is copied to `<WorkPath>/candidate` (`Copy-UpdateTree`, without `.git`), and `overrides.json` is written there unless every override entry is unchanged (`OverridesChange`); the quarantine file of every stage a `release` freed the id in is written there too (`QuarantineChanges`).
4. One row per item and matching endpoint (`*` expanded in settings order): `{ Endpoint, File, Id, Before, After, BeforeSource, AfterSource, BeforeDetail, AfterDetail, ListedBefore, ListedAfter, Changed, Note }`, from the inputs of the working tree and of the candidate, both in memory. Rows are not taken from `Compare-RulebookEndpoints`, which lists changed rows only and needs a git ref.
5. `NoOp` (section 4): every item is a `set` that changes no endpoint and whose entry is `unchanged` or would be `added`, or a `release` that frees the id nowhere. A no-op returns here: `Valid $true`, `Changes` empty, no regeneration (the candidate copy may hold the unwritten entry; it is never pushed).
6. `Update-RulebookEndpoints` on the candidate (a failure is the finding "The changed rulebook cannot be regenerated: ..."), then `Test-Rulebook`: `Findings`, `Valid`.
7. `Changes`: every file that differs between the repository and the candidate, `{ File, Change (created, modified, deleted), Bytes }`, the list `Publish-RulebookChange` writes into its clone.

The plan carries `Root`, `CandidatePath`, `HeadSha`, `Now`, `ChangeSet`, `Items[]` (`Op`, `Id`, `Action`, `Levels`, `Stages`, `Justification`, `Entry { Change, Previous }`, `Released`, `Unlisted`, `Rows[]`, `ChangedEndpoints`, `NoOp`, `Notes[]`), `OverridesChange`, `QuarantineChanges[]`, `Changes[]`, `Findings[]`, `Valid`, `Failure`, `NoOp` and `Title`. A `release` item has `Levels` `["*"]` (its rows cover every level of the selected stages), no `Action` and no `Justification`, `Entry.Change` `released` or `unchanged` (with `Entry.Removed`, the entries it took out), and `Released` and `Unlisted`, the selected stages whose file did and did not list the id.

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

The opening paragraphs are the note of the change set (on one line), then `Justification: <text>` for a one-item `set` whose entry has a justification after the change (the given text or the kept one); without either, nothing for a change set of removes and releases only, else `No justification given.` The sentence per item is one of `Sets <id> to <action> for levels <l>, stages <s> (adds an entry).`, `(replaces the entry that was <action>).`, `Updates the justification of the <id> entry for levels <l>, stages <s> (the action stays <action>).`, `Removes the override entry for <id> with levels <l>, stages <s> (it was <action>).`, `Releases <id> from the quarantine of stages <s> (removes the entry from quarantine.<stage>.json).` and the no-op sentences of section 4; notes follow as a list (stages a release did not find the id in, unlisted ids, unchanged count). `ConvertTo-ChangeItemList` writes the sentences alone, one `- <sentence>` line per item. Above 60000 characters the tables are left out from the end with one italic line, then the body is cut at a line boundary.

The job summary (`ConvertTo-ChangeSummary`) has `## Rule change` (`-Heading` names another title), the message, the pull request or commit line, the same paragraph and tables, `## Validation errors` when there are any, and `## Effective diff`: the git-based diff of the pushed commit against the cloned head (`Compare-RulebookEndpoints`, the Validate rendering). That diff appears only in the summary, never in the body (WP09 interview, decision 14): the reviewer reads the in-memory table, and Validate on the pull request shows the effective diff again.

## 7. Branch, title and landing

| Thing | Value |
|---|---|
| Branch | `change-rule/<ruleId>/<yyMMddHHmmss>` (UTC, from `-Now`); a fresh branch per run, so two runs never collide and there is no duplicate guard |
| Title (commit and pull request) | `Change LC0015 to None (levels: strict, stages: ci)`, `Remove override for LC0015 (levels: strict, stages: ci)`, `Release LC0099 from quarantine (stages: ci)`; several items: `Rulebook change: <n> changes`. `-Title` replaces it (section 12). |
| Labels | `commitOptions.pullRequestLabels` |
| Landing | `commitOptions.createPullRequest` true or absent: pull request; false: direct commit to the branch the workflow runs on (D47) |

`Publish-RulebookChange` refuses an invalid or no-op plan, clones the base branch with the write token, refuses a base branch that moved since the plan read the checkout (`The base branch moved since the change was planned (main 1a2b3c4 is now 5d6e7f8); nothing was pushed. Run the workflow again.`, stage `push`, reason `base-moved`), writes `Changes`, commits with the title and pushes the branch (`Publish-GitHubChange` without `-Force`), or the base branch with `-DirectCommit`. A refused direct push (branch protection) moves the commit to the new branch and opens the pull request (`Fallback`, the notice says "(the direct commit was refused)"; `FallbackReason` holds the git output of the refused push). The refusal is one warning annotation before the notice, `The direct push to <branch> was refused; a pull request was created instead. (<git output on one line>)` ([#77](https://github.com/ALCops/rulebook-engine/issues/77)); when the pull request then fails, it ends `the branch was pushed instead.`, and when the fallback branch cannot be pushed either, `the fallback branch could not be pushed.`, with the same git output. Then the effective diff against the cloned head and the pull request with the labels. A failure after the push names the pushed branch and its tree link.

## 8. Action reference

`actions/ChangeRule/action.yaml`, one `pwsh` step, inputs through `INPUT_*` environment variables only; the step gets no `GITHUB_TOKEN` (the action reads nothing from GitHub with the workflow token, it writes with the secret's token):

| Input | Default | Meaning |
|---|---|---|
| `ruleId` | required | The diagnostic id. |
| `action` | required | Error, Warning, Info, Hidden, None, or Remove. |
| `levels`, `stages` | `'*'` | A slug or `*`. |
| `justification` | `''` | Optional; empty keeps the existing justification of the entry; ignored for Remove. |
| `token` | `''` | The `GHTOKENWORKFLOW` value; not needed for a validation error or a no-op. |
| `directCommit` | `'false'` | The workflow passes `-not createPullRequest`. |
| `baseBranch` | `${{ github.ref_name }}` | |
| `repositoryRoot` | `'.'` | |
| `actor` | `${{ github.actor }}` | The git author of the commit. |

| Output | Values |
|---|---|
| `result` | `pull-request`, `direct-commit`, `no-op`; empty on failure. Should the clone of the base branch hold the change already (pushed between plan and publish), there is nothing to commit and the result is `no-op` too, with the notice `No change: <branch> already holds this change; nothing was pushed`. |
| `noop` | `true` or `false` |
| `changedEndpoints` | Comma-separated endpoints, for example `strict.ci`; empty for a no-op |
| `pullRequestUrl`, `branch` | The pull request and the pushed branch (the base branch for a direct commit) |
| `failure` | `validation`, `token`, `push`, `pull-request`, `error`; empty on success |

Order in `ChangeRule.ps1`: settings (secret name, labels), the plan, the validation annotations (`::error file=<path>,title=<rule>::...`, failure `validation`) or the no-op notice, then **the token guard** (an invalid `ghTokenWorkflowSecretName`, or `The GHTOKENWORKFLOW secret is needed to change a rule. Read <docs>`, failure `token`), the exchange and `::add-mask::` before anything else prints, then the publish. The guard runs after the local plan so a wrong rule id or a no-op answers without a secret; the token is still exchanged and masked before any request. Push and pull-request failures carry the token hint (`Make sure that the token in the secret ... may write contents and pull requests`); a moved base does not. The summary is capped at 900 KiB with `Limit-SummaryText`. The script never calls `exit`; `-RemoteUrl`, `-ApiUrl`, `-WorkPath`, `-SummaryLimit`, `-Now` and `-PublishCommand` are test seams.

## 9. The workflow and its choice lists

`template/.github/workflows/ChangeRule.yaml` (system file): `workflow_dispatch` with `ruleId` (string, required), `action` (choice), `levels` and `stages` (choice, default `'*'`, the shipped slugs), `justification` (string, optional); `permissions: contents: read` (the change is pushed with the secret's token, so the pull request runs Validate); `concurrency: change-rule-${{ github.ref }}` without cancelling (GitHub keeps one running and one pending run per group: a third dispatch while one runs and one waits replaces the waiting one, which is then cancelled, so run the form again for it); checkout without persisted credentials; a "Read the settings" step that resolves the secret name and `directCommit = -not commitOptions.createPullRequest` on every run (D47), with no `directCommit` input; then `ALCops/rulebook-engine/actions/ChangeRule@main` (pinned to `@v1` by the deploy, WP13).

The update rewrites the `levels` and `stages` options from the settings (D30, [update-mechanics.md](update-mechanics.md) section 5): `'*'` and the slugs in settings order. The shipped file is laid out so that rewrite with the shipped settings reproduces it byte for byte; an organization that adds a level `House` gets `house` in its form after the next update.

## 10. Tests and CI

- `tests/Rulebook.Edit.Tests.ps1`: the round trips, write-on-change and `-WhatIf`; the change set version and `release` in `Test-RulebookChangeSet`; `Remove-RulebookQuarantine`; `release` in `Invoke-RulebookChangeSet` on `LC0099` of `valid-minimal` (`ci`: four endpoints, `*`: eight with `vnext` unlisted, `vnext`: a no-op, next to a set, masked by an override, a hand-edited file normalised); the note-first paragraph, `-Heading`, `ConvertTo-ChangeItemList`, the body prefix and suffix; the issue body parser on `tests/fixtures/issues/` and `Read-RulebookChangeSetText`; set on an empty array, replace in place with order-insensitive selectors, the kept justification, `unchanged`, append; remove with the rest of the file byte-identical (AC4) and the miss message; every `Test-RulebookChangeSet` message; `Invoke-RulebookChangeSet` for AC1 (one endpoint), AC2 (all 12), AC3 (unlisted), AC5 (nothing copied, repository untouched), AC6 (no-op), justification-only, partial, `*` order and remove; title, table, body (and its limit) and summary; `Publish-RulebookChange` against a bare repository (pull request with labels and body, direct commit, fallback with a push-refusing hook, base moved, the pull-request failure, refused plans, `-Title` and `-BodySuffix` on the commit and the pull request).
- `tests/Rulebook.GitHub.Tests.ps1`: the issue helpers of section 12 at the `Invoke-WebRequest` mock.
- `tests/ChangeRule.Action.Tests.ps1`: `action.yaml`; the template workflow (inputs and option lists, permissions, concurrency, secret lookup, no interpolation in `run`, the settings step run in-process for `createPullRequest` false, true and absent); `ChangeRule.ps1` in-process (validation, remove miss, no-op without a token, token guard and mask, the publish seam with outputs and summary, failure mapping, work folders, and against a bare remote: direct commit, pushed branch, fallback).
- `tests/Rulebook.Update.Tests.ps1`: the shipped `ChangeRule.yaml` rewritten with the shipped settings is unchanged, with a level `House` it gains `house` in settings order.
- CI job `changerule-action` on a copy of `valid-minimal`, no token: `AA0001` `None` `*`/`*` fails with `token`, `AA0072` `Info` `*`/`*` without a justification is a no-op (the entry keeps `House style`), `LC9999` fails with `validation`.

## 11. Live run

*Observed* on 2026-10-08 and 2026-10-09 in the scratch repository [Arthurvdv/rulebook-e2e-changerule](https://github.com/Arthurvdv/rulebook-e2e-changerule), seeded from `template/` of this branch with every action pinned to `@wp09/change-rule` and the shipped settings (`createPullRequest: true`, `baseUrl` empty, so every Publish run on `main` failed on the empty base URL, as expected; no Pages site was needed). The write token was a GitHub App (`Write token: app`), added as `GHTOKENWORKFLOW` after step 2. The template catalog has no LC0015, so the role of the issue's example id went to LC0031 (default Info, raised to Warning by Strict). Each step was one run of Actions > Change Rule > Run workflow on `main`; every pull request was merged before the next step unless noted, and Validate passed on every pull request.

| # | Checks | Inputs (ruleId / action / levels / stages / justification) | Run | Observed |
|---|---|---|---|---|
| 1 | AC5 | LC9999 / Warning / * / * / empty | [37889625164](https://github.com/Arthurvdv/rulebook-e2e-changerule/actions/runs/37889625164) | Failed with the one error `LC9999 is not in catalog/diagnostics.json`; no branch, no pull request. |
| 2 | token guard | LC0031 / None / strict / ci / empty, before the secret existed | [37889691838](https://github.com/Arthurvdv/rulebook-e2e-changerule/actions/runs/37889691838) | Failed with `The GHTOKENWORKFLOW secret is needed to change a rule. Read https://github.com/ALCops/rulebook/blob/main/docs/ghtokenworkflow.md` after the local plan had passed; nothing pushed. |
| 3 | AC1 | LC0031 / None / strict / ci / empty | [37895923298](https://github.com/Arthurvdv/rulebook-e2e-changerule/actions/runs/37895923298), [#1](https://github.com/Arthurvdv/rulebook-e2e-changerule/pull/1) | Branch `change-rule/LC0031/261009065616`, title `Change LC0031 to None (levels: strict, stages: ci)`, label `rulebook`. Two files: `overrides.json` (the entry line) and `rulesets/strict.ci.ruleset.json` only. Body `No justification given.`, `Sets LC0031 to None for levels strict, stages ci (adds an entry).`, row `strict.ci \| Warning (level:strict, "Advisory at Recommended, blocks CI from Strict; D-13") \| None (override)`. |
| 4 | AC6 | LC0031 / None / strict / ci / empty, after #1 | [37902765227](https://github.com/Arthurvdv/rulebook-e2e-changerule/actions/runs/37902765227) | Succeeded with `No change: LC0031 is already None on every matching endpoint (strict.ci); overrides.json was not written`; no token exchanged, no branch, no pull request. |
| 5 | justification only | LC0031 / None / strict / ci / `Legacy tables` | [37904969108](https://github.com/Arthurvdv/rulebook-e2e-changerule/actions/runs/37904969108), [#2](https://github.com/Arthurvdv/rulebook-e2e-changerule/pull/2) | Only `overrides.json` (+1 −1, the entry gains the justification), nothing in `rulesets/`. Body `Justification: Legacy tables`, `Updates the justification of the LC0031 entry for levels strict, stages ci (the action stays None).`, row note `justification updated`. |
| 6 | AC2 | AA0001 / None / * / * / empty | [37905478471](https://github.com/Arthurvdv/rulebook-e2e-changerule/actions/runs/37905478471), [#3](https://github.com/Arthurvdv/rulebook-e2e-changerule/pull/3) | Ten files: `overrides.json` and the nine recommended, strict and complete endpoints; the three essential endpoints untouched and their rows `unchanged`; note `3 of 12 matching endpoints are unchanged.`; validation passed. |
| 7 | AC3 | AL0432 / Warning / * / * / empty | [37905970490](https://github.com/Arthurvdv/rulebook-e2e-changerule/actions/runs/37905970490), [#4](https://github.com/Arthurvdv/rulebook-e2e-changerule/pull/4) | Warning is the analyzer default: seven endpoints (essential default, ci and vnext, recommended.default, recommended.ci, strict.ci, complete.ci) each lost their AL0432 line, each row and a note say `now unlisted in <endpoint>: Warning equals the analyzer default`; five rows `unchanged`. |
| 8 | AC4 | LC0031 / Remove / strict / ci / empty | [37908123685](https://github.com/Arthurvdv/rulebook-e2e-changerule/actions/runs/37908123685), [#5](https://github.com/Arthurvdv/rulebook-e2e-changerule/pull/5) | Title `Remove override for LC0031 (levels: strict, stages: ci)`. The raw `overrides.json` diff removes only the LC0031 line (no whitespace or end-of-file change); `strict.ci` back to Warning. Body opens with the sentence (no justification paragraph for a remove). |
| 9 | remove miss (D48) | AA0001 / Remove / strict / ci / empty | [37908425845](https://github.com/Arthurvdv/rulebook-e2e-changerule/actions/runs/37908425845) | Failed with `overrides.json has no entry for AA0001 with levels [strict] and stages [ci]; existing entries for AA0001: None (levels: *, stages: *)`; no token exchanged, nothing pushed. |
| 10 | D47 direct commit | AA0072 / Info / * / * / empty, with `createPullRequest: false` | [37911349110](https://github.com/Arthurvdv/rulebook-e2e-changerule/actions/runs/37911349110), commit [f12a4e6](https://github.com/Arthurvdv/rulebook-e2e-changerule/commit/f12a4e6a829961e868835d54c2c36fa968546986) | Settings step `direct commit: True`; notice `Rule change committed to main (f12a4e6)`; ten files on `main` (`overrides.json` and nine endpoints), no branch, no pull request; Validate on the push passed. |
| 10b | D47 fallback | AA0072 / None / complete / * / empty, with a ruleset requiring pull requests on `main` | [37911655683](https://github.com/Arthurvdv/rulebook-e2e-changerule/actions/runs/37911655683), [#6](https://github.com/Arthurvdv/rulebook-e2e-changerule/pull/6) | The push was refused (`GH013: Repository rule violations found for refs/heads/main`); notice `Pull request: ... (the direct commit was refused)`, `main` unchanged. Four files: `overrides.json` and the three complete endpoints, whose rows say `now unlisted in complete.<stage>: None equals the analyzer default`. The refusal shows in the log as a PowerShell warning from `Publish-GitHubChange`, not as a workflow annotation, so only the notice suffix names it on the run page. |
| 11 | D30 | Level House (basedOn Recommended) added after Recommended in the settings with its level file, endpoints and skeletons, `templateUrl` pointed at the scratch template repository; then Update Rulebook System Files with its defaults | [37912189607](https://github.com/Arthurvdv/rulebook-e2e-changerule/actions/runs/37912189607), [#7](https://github.com/Arthurvdv/rulebook-e2e-changerule/pull/7) | Exactly three files: `ChangeRule.yaml` gains the one line `- house` after `- recommended` (settings order, not at the end), `UpdateRulebookSystemFiles.yaml` gets the template URL in place of `{TEMPLATEURL}`, the settings get `templateSha` with House kept. |

## 12. The issue path: module functions

The dashboard writes through a `rulebook-change` issue (D32, D33): the cart prefills the issue form with the change set as minified JSON in the `Changes` field and an optional `Note`. These functions are what the issue path calls; the `ApplyChangeSet` action and the Apply Rulebook Change workflow that call them follow in the next pull request of WP15 ([#17](https://github.com/ALCops/rulebook-engine/issues/17)).

| Function | Module | What it does |
|---|---|---|
| `ConvertFrom-RulebookIssueBody -Body` | Edit | The body as GitHub renders the form, one `### <label>` section per field: CRLF becomes LF, the body splits at `### <label>` lines (other heading levels do not split, text above the first is ignored). `ChangesText` is the first fenced block (```` ``` ```` or `~~~`, info string optional, an unclosed fence runs to the end of the section) of the first section headed exactly `Changes`, or the section text when it has no fence, trimmed. `Note` is the first `Note` section, trimmed; `_No response_` and an absent section are `''`. `Errors`: `The issue body has no "### Changes" section; submit the Rulebook change form from the dashboard, or add the section with the change set in a json code block.` or `The Changes field is empty.` Returns data, never throws. |
| `Read-RulebookChangeSetText -Text [-SchemaPath]` | Edit | Strict JSON (`System.Text.Json`: no comments, no trailing commas): `The change set is not valid JSON (line <l>, position <p>): <reason>`. Then `Test-Json` against `schemas/rulebook-changeset.schema.json`: one line `The change set does not match the schema: <error>` per error (a line `Test-Json` repeats is kept once; the wording of `Test-Json` differs between PowerShell versions, and when it names no error at all, one line says what a set, a remove and a release need). Only a valid text gets a `ChangeSet`: ordered dictionaries with ordinal keys, strings kept as strings. The catalog, the slugs and repeated changes are checked by `Test-RulebookChangeSet` in the plan. Returns data, never throws. |
| `Remove-RulebookQuarantine -Files -Id -Stages` | Edit | Section 2. |
| `ConvertTo-ChangeItemList -Plan` | Edit | One `- <sentence>` line per item, for the comment on a no-op. |
| `Publish-RulebookChange -Title -BodyPrefix -BodySuffix` | Edit | `-Title` is the commit subject and the pull request title (the commit message is the title alone, so a direct commit never carries a closing keyword); the issue path passes the engine title with ` (#<n>)`. `-BodySuffix` (the `Closes #<n>` line) ends the pull request body and `-BodyPrefix` opens it, each after a blank line; the 60000-character limit is applied to the generated part between them, so the suffix is never cut. `Result.Title` and `Result.Body` are what was sent. `-BranchPrefix` is `rulebook-change/<issue>` there; the landing rule (D33, D47) is the one of section 7. |
| `ConvertTo-ChangeSummary -Heading` | Edit | The summary under another heading, `Rulebook change (#<n>)` on the issue path. |
| `Get-GitHubIssue -Number` | GitHub | `GET issues/{n}`: `{ Number, Title, Body ('' without one), State, StateReason, Author, AuthorType, AuthorAssociation, Labels, Url, IsPullRequest }`. |
| `Get-GitHubUserPermission -User` | GitHub | `GET collaborators/{user}/permission`: `{ Permission (admin, write, read, none), RoleName }`; a 404 (no collaborator) is `none`. |
| `Add-GitHubIssueComment -Number -Body` | GitHub | `POST issues/{n}/comments`: `{ Id, Url }`. |
| `Close-GitHubIssue -Number -StateReason completed\|not_planned` | GitHub | `PATCH issues/{n}` with `state closed` and the reason: `{ Number, Url }`. |
| `Confirm-GitHubLabel -Name [-Color] [-Description] [-IssueNumber]` | GitHub | `GET labels/{name}`; a 404 creates it (color `1D76DB`, description `A change set submitted from the Rulebook dashboard`; a 422 `already_exists` from a run that created it in between is accepted); with `-IssueNumber` the label is added to that issue: `{ Created, Added }`. |
| `Find-GitHubPullRequestByHeadPrefix -Base -HeadPrefix` | GitHub | Every open pull request into the base, paginated, matched on the head branch by an ordinal prefix (`rulebook-change/12/` never matches `rulebook-change/123/`): `{ Number, Url, Title, Head }` or `$null`. The duplicate guard of D33. |

The GitHub helpers take `-Repository -Token -ApiUrl`, go through `Invoke-GitHubApi` (methods GET, POST, PATCH, HEAD) and throw with the HTTP status in `Data['StatusCode']` on an unexpected answer, as `Get-GitHubBranchSha` does. The issue helpers need `issues: write` (comment, label, close) and `pull-requests: read` (the guard) of the workflow token; the push and the pull request use the `GHTOKENWORKFLOW` token as for Change Rule.
