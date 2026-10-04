# Spike (f): suppressWarnings against a sparse endpoint

> **Status:** done 2026-10-04. Issue [#24](https://github.com/ALCops/rulebook-engine/issues/24), part of WP01 ([#3](https://github.com/ALCops/rulebook-engine/issues/3)). Blocks: WP06 ([#8](https://github.com/ALCops/rulebook-engine/issues/8)), WP11 ([#13](https://github.com/ALCops/rulebook-engine/issues/13)).

## Question

Does `suppressWarnings` in `app.json` remove an analyzer Error rule (AS0084, AS0013) that a sparse endpoint does not list, and does it stop working once the endpoint lists the id ([D22](../../adr/0022-sparse-endpoints-an-id-at-its-analyzer-default-is-not-listed.md))?

## Method

Three endpoint files were added under `v2/rulesets/` of the scratch repository `Arthurvdv/rulebook-spike-endpoint` from [spike (a)](a-hosts-and-skeleton-include.md) (commit `d5503ff`; the `v1/` files were not touched), served from GitHub Pages and from raw:

```jsonc
// recommended.ci.ruleset.json: sparse, AS0084 and AS0013 unlisted
{ "name": "Spike f sparse", "rules": [ { "id": "AA0137", "action": "Error" } ] }
// listed-warning.ruleset.json
{ "name": "Spike f listed warning", "rules": [ { "id": "AA0137", "action": "Error" }, { "id": "AS0013", "action": "Warning" } ] }
// listed-info.ruleset.json
{ "name": "Spike f listed info", "rules": [ { "id": "AA0137", "action": "Error" }, { "id": "AS0013", "action": "Info" } ] }
```

AA0137 (CodeCop, Warning by default) at `Error` in every endpoint proves that the endpoint was loaded: each compile that shows `error AA0137` applied the ruleset.

Fixture: the [spike (c)](c-alc-on-ubuntu.md) project (`runtime 17.0`, `platform 28.0.0.0`, `idRanges [50000..50099]`, `target: "Cloud"`, no `application`, the AA0137 codeunit) plus, as derived from the decompiled `RuleIdRangeMustBeRespected` and `RuleAppManifestConfigurationMustBeProvided`:

```al
table 50000 "Spike Base"
{
    DataClassification = CustomerContent;
    fields { field(1; "No."; Code[20]) { DataClassification = CustomerContent; } }
    keys { key(PK; "No.") { Clustered = true; } }
}

tableextension 50001 "Spike Ext" extends "Spike Base"
{
    fields { field(60000; "Spike Extra"; Integer) { DataClassification = CustomerContent; } }
}
```

The `suppressWarnings` variant of `app.json` adds `"suppressWarnings": ["AS0084", "AS0013"]`; runs 7a and 7b use a longer list (below).

A throwaway workflow (`spike-f.yml`, `workflow_dispatch` plus push on `wp01/spike-f`, read-only token, removed before the pull request; last version at `51191f8:.github/workflows/spike-f.yml`) ran on `ubuntu-latest` with the [spike (c) recipe](c-alc-on-ubuntu.md#recipe) unchanged (pinned stable tool, `AL_BIN` from `tools/net10.0/any` with the guard, `System.app` from MSSymbols with the prerelease-safe `jq` filter, output in `compile.log`, AL1003 check) and **all four** Microsoft cops:

```bash
al compile /project:fixture /packagecachepath:fixture/.alpackages /out:$d/out.app \
  /analyzer:$AL_BIN/Microsoft.Dynamics.Nav.CodeCop.dll \
  /analyzer:$AL_BIN/Microsoft.Dynamics.Nav.UICop.dll \
  /analyzer:$AL_BIN/Microsoft.Dynamics.Nav.PerTenantExtensionCop.dll \
  /analyzer:$AL_BIN/Microsoft.Dynamics.Nav.AppSourceCop.dll \
  /ruleset:<endpoint URL or skeleton> /enableexternalrulesets [/nowarn:AS0013] > $d/compile.log 2>&1
rc=$?   # under set +e; the .app path is deleted before each compile and checked after it
```

The workflow polled each endpoint URL for `200` before compiling (all six answered on the first attempt) and flagged any AL1003, AL1033 or AL0767 in a compile log as a setup error ([spike (a)](a-hosts-and-skeleton-include.md#answer): a ruleset that does not load aborts `alc`); none appeared. Runs 6p, 6w and 6o used the [ARCHITECTURE.md §6.3](../../ARCHITECTURE.md#63-skeletons-r3) skeleton as a local file (`fixture/.rulebook/ci.ruleset.json`, one `includedRuleSets` entry with `"action": "Default"`, own `rules`), exactly as in [spike (a)](a-hosts-and-skeleton-include.md#method).

The editor path was run by Arthur in VS Code on Windows with the same fixture (see [VS Code](#vs-code)); rows V1 to V4 of the table.

## Environment and versions

| Item | Value |
|---|---|
| Date | 2026-10-04 |
| Runner image / OS | `ubuntu-latest` = ubuntu-24.04, image version 20260927.320.1; VS Code path on Windows 11 Enterprise 10.0.26200 |
| Development.Tools (alc) | 18.0.43.1464 (`18.0.43.1464+ad5c66161d2e2ef7ba77e4a6c7681eb522cf752c`), `tools/net10.0/any` |
| Platform symbols | `microsoft.platform.symbols` 28.0.54265 |
| AL extension (VS Code) | `ms-dynamics-smb.al@18.0.2819426` (from `code --list-extensions --show-versions`) |
| Endpoints | `https://arthurvdv.github.io/rulebook-spike-endpoint/v2/rulesets/<file>` (Pages) and `https://raw.githubusercontent.com/Arthurvdv/rulebook-spike-endpoint/main/v2/rulesets/<file>` (raw) |

## Observed

Final run: [actions/runs/37180612371](https://github.com/ALCops/rulebook-engine/actions/runs/37180612371) (commit `51191f8`). The first run, [37180549341](https://github.com/ALCops/rulebook-engine/actions/runs/37180549341) (commit `557d304`, runs c0 to 6o only), gave identical results for every run they share.

**Other AS ids.** Every compile of this fixture without them in `suppressWarnings` also reports, unchanged by any endpoint: AS0051 (Error, 7x: `brief`, `description`, `privacyStatement`, `EULA`, `help`, `logo`, `contextSensitiveHelpUrl`), AS0015 (Error), AS0052 (Error), AS0054 (Error), AS0100 (Error, `application` missing), AS0092 (Warning), AS0103 (Warning), plus PTE0004 (Error, PerTenantExtensionCop: no permission set for the table) and AA0247 (Info). These are abbreviated as *the rest* in the table. Because they are errors, **the exit code of runs c0 to 6o is 1 regardless of AS0084 and AS0013**, and AA0137 at the endpoint's `Error` also fails every endpoint compile; the table is therefore read by the presence and severity of AS0084, AS0013 and AA0137 in `compile.log`. Runs 7a and 7b make the exit code unambiguous.

| run | host | endpoint lists AS0013 | suppressWarnings | AS0084 | AS0013 | AA0137 | other AS ids | exit code | .app |
|---|---|---|---|---|---|---|---|---|---|
| c0 | alc, no ruleset | (no ruleset) | none | Error | Error | Warning | the rest | 1 | no |
| c0s | alc, no ruleset | (no ruleset) | AS0084, AS0013 | absent | absent | Warning | the rest | 1 | no |
| 1p | alc, Pages sparse | no | none | **Error** | **Error** | Error | the rest | 1 | no |
| 1r | alc, raw sparse | no | none | **Error** | **Error** | Error | the rest | 1 | no |
| 2p | alc, Pages sparse | no | AS0084, AS0013 | **absent** | **absent** | Error | the rest | 1 | no |
| 2r | alc, raw sparse | no | AS0084, AS0013 | **absent** | **absent** | Error | the rest | 1 | no |
| 3p | alc, Pages listed-warning | Warning | AS0084, AS0013 | absent | **Warning** | Error | the rest | 1 | no |
| 3n | alc, Pages listed-warning | Warning | none | Error | Warning | Error | the rest | 1 | no |
| 4p | alc, Pages listed-info | Info | AS0084, AS0013 | absent | **Info** | Error | the rest | 1 | no |
| 5p | alc, Pages listed-warning + `/nowarn:AS0013` | Warning | none | Error | **absent** | Error | the rest | 1 | no |
| 6p | alc, skeleton including Pages sparse | no | AS0084, AS0013 | **absent** | **absent** | Error | the rest | 1 | no |
| 6w | alc, skeleton including Pages listed-warning | Warning (include) | AS0084, AS0013 | absent | **Warning** | Error | the rest | 1 | no |
| 6o | alc, skeleton including Pages sparse, own `rules` AS0013 Warning | Warning (skeleton's own rule) | AS0084, AS0013 | absent | **Warning** | Error | the rest | 1 | no |
| 7a | alc, no ruleset | (no ruleset) | all ids seen in c0, AA0137 included | absent | absent | absent | none | **0** | **yes** |
| 7b | alc, Pages sparse (lists AA0137) | no | all ids seen in c0, AA0137 included | absent | absent | **Error** | none | **1** | no |
| 8a | alc, no ruleset, field **50050** | (no ruleset) | none | Error | **absent** | Warning | the rest | 1 | no |
| 8b | alc, no ruleset, field **99000** | (no ruleset) | none | Error | **Error** | Warning | the rest | 1 | no |
| 8c | alc, no ruleset, field **1000000** | (no ruleset) | none | Error | **Error** | Warning | the rest, plus PTE0002 Error | 1 | no |
| V1 | VS Code, Pages listed-warning | Warning | none | Error | **Warning** | Error | none shown (see below) | n/a | n/a |
| V2 | VS Code, Pages listed-warning (after Reload Window) | Warning | AS0084, AS0013 | **absent** | **Warning** | Error | not reported | n/a | n/a |
| V3 | VS Code, Pages sparse | no | AS0084, AS0013 | **absent** | **absent** | Error | not reported | n/a | n/a |
| V4 | VS Code, Pages sparse | no | none | **Error** | **Error** | Error | not reported | n/a | n/a |

Runs 7a and 7b use `"suppressWarnings": ["AS0084", "AS0013", "AS0015", "AS0051", "AS0052", "AS0054", "AS0100", "AS0092", "AS0103", "PTE0004", "AA0137"]`. Runs 8a to 8c change only the field id of the table extension. Every alc compile took 1.2 to 1.7 s (wall time, including the fetch).

Findings:

- **`suppressWarnings` removes analyzer errors the endpoint does not list.** AS0084 and AS0013 are Errors without a ruleset and with the sparse endpoint (c0, 1p, 1r) and disappear with `suppressWarnings` on both hosts (2p, 2r) and through the skeleton include (6p), while AA0137 stays at the endpoint's `Error`, so the endpoint was loaded. 7a shows the same mechanism clears the whole build: with every reported id in `suppressWarnings` and no ruleset, exit 0 and an `.app`.
- **It stops working once the ruleset lists the id, whatever the action.** AS0013 listed at `Warning` stays a Warning (3p), listed at `Info` stays Info (4p), and AA0137 listed at `Error` stays an Error (7b: the only diagnostic left, exit 1, no `.app`). The same holds when the listing comes from the include of a skeleton (6w) or from the skeleton's own `rules` (6o). Meanwhile AS0084, which no endpoint lists, is suppressed in every one of these runs.
- **`/nowarn` on the command line beats the ruleset.** With the listed-warning endpoint and no `suppressWarnings`, `/nowarn:AS0013` removes AS0013 (5p versus 3n), as [compiler-ruleset-internals.md §8](../compiler-ruleset-internals.md#8-how-the-ruleset-combines-with-other-inputs) states.
- **AS0013 fires on table extension fields outside the app's `idRanges`; the 50000..99999 range plays no part.** Field 50050 (inside `idRanges [50000..50099]` and inside 50000..99999) gives no AS0013 (8a); 99000 (outside `idRanges`, inside 50000..99999) and 1000000 (outside both) give AS0013 (8b, 8c). The diagnostic text reads "must be within the range '[50000..50099]' ... and outside the range '[50000..99999]', which is allocated to per-tenant customizations", but the second half is only a message argument: the decompiled `RuleIdRangeMustBeRespected` checks the field id against `idRanges` (and, when the extended table is in the same app or has the same publisher, also accepts 1..49999). Fields of a plain `table` get AS0099 (Info) instead, from the code (not exercised: field 1 of the fixture table is valid). AS0084 is the rule that looks at 50000..99999: it fires when an `idRanges` entry intersects 50000..99999 or is not inside the AppSource range 1000000..75999999.

<details>
<summary>Compile output, c0 (no ruleset, no suppressWarnings; first run, identical in the final run)</summary>

```
Compilation started for project 'Spike' containing '3' files at '05:40:17.260'.
fixture/src/Spike.Codeunit.al(1,16): info AA0247: Use namespaces to organize your code and isolate it from changes.
fixture/src/SpikeBase.Table.al(1,13): info AA0247: Use namespaces to organize your code and isolate it from changes.
fixture/src/SpikeExt.TableExt.al(1,22): info AA0247: Use namespaces to organize your code and isolate it from changes.
fixture/app.json(1,1): warning AS0092: The app.json file must specify an Azure Application Insights resource with the property 'applicationInsightsConnectionString' ...
fixture/src/SpikeBase.Table.al(1,13): warning AS0103: Table 50000 'Spike Base' is missing a matching permission set.
fixture/src/Spike.Codeunit.al(5,9): warning AA0137: Variable 'Unused' is unused in 'Probe'.
fixture/app.json(1,1): error AS0051: The manifest property 'brief' must be specified and contain a meaningful value.
(six more AS0051: description, privacyStatement, EULA, help, logo, contextSensitiveHelpUrl)
fixture/app.json(8,3): error AS0084: The ID range '[50000..50099]' is not valid. It must be within the range allocated to the partner for AppSource, within the range '[1000000..75999999]' allocated to AppSource applications, and outside the range '[50000..99999]' allocated to per-tenant customizations.
fixture/app.json(1,1): error AS0015: The "TranslationFile" flag must be added to the "features" array in the app.json file.
fixture/app.json(1,1): error AS0052: The property 'url' must be set to a valid URL.
fixture/app.json(1,1): error AS0100: The 'application' property in the app.json file must be specified on apps targeting the AppSource marketplace.
fixture/src/SpikeExt.TableExt.al(5,15): error AS0013: The field identifier '60000' is not valid. It must be within the range '[50000..50099]', which is allocated to the application, and outside the range '[50000..99999]', which is allocated to per-tenant customizations.
fixture/src/SpikeBase.Table.al(1,13): error PTE0004: Table 50000 'Spike Base' is missing a matching permission set.
error AS0054: The AppSourceCop configuration must specify one of the following properties: 'mandatorySuffix', 'mandatoryPrefix', or 'mandatoryAffixes'
Compilation ended at '05:40:18.310'.
```

</details>

<details>
<summary>AS0084, AS0013 and AA0137 lines per run (2p to 6o from the first run, 7b to 8c from the final run; identical where both ran)</summary>

```
## 2p Pages sparse, suppressWarnings
fixture/src/Spike.Codeunit.al(5,9): error AA0137: Variable 'Unused' is unused in 'Probe'.
## 3p Pages listed-warning, suppressWarnings
fixture/src/SpikeExt.TableExt.al(5,15): warning AS0013: The field identifier '60000' is not valid. ...
fixture/src/Spike.Codeunit.al(5,9): error AA0137: Variable 'Unused' is unused in 'Probe'.
## 4p Pages listed-info, suppressWarnings
fixture/src/SpikeExt.TableExt.al(5,15): info AS0013: The field identifier '60000' is not valid. ...
fixture/src/Spike.Codeunit.al(5,9): error AA0137: Variable 'Unused' is unused in 'Probe'.
## 5p Pages listed-warning, no suppressWarnings, /nowarn:AS0013
fixture/app.json(8,3): error AS0084: The ID range '[50000..50099]' is not valid. ...
fixture/src/Spike.Codeunit.al(5,9): error AA0137: Variable 'Unused' is unused in 'Probe'.
## 6o skeleton incl. Pages sparse, own AS0013 Warning, suppressWarnings
fixture/src/SpikeExt.TableExt.al(5,15): warning AS0013: The field identifier '60000' is not valid. ...
fixture/src/Spike.Codeunit.al(5,9): error AA0137: Variable 'Unused' is unused in 'Probe'.
## 7b Pages sparse, suppressWarnings = all seen ids incl. AA0137 (complete output after the banner)
Compilation started for project 'Spike' containing '3' files at '05:42:01.028'.
fixture/src/Spike.Codeunit.al(1,16): info AA0247: Use namespaces to organize your code and isolate it from changes.
(two more AA0247)
fixture/src/Spike.Codeunit.al(5,9): error AA0137: Variable 'Unused' is unused in 'Probe'.
Compilation ended at '05:42:02.212'.
## 8a field 50050
fixture/app.json(8,3): error AS0084: The ID range '[50000..50099]' is not valid. ...
(no AS0013)
## 8c field 1000000
fixture/src/SpikeExt.TableExt.al(5,15): error PTE0002: Field 'Spike Extra' has an ID of [1000000]. It must be within the range '[50000..99999]'.
fixture/src/SpikeExt.TableExt.al(5,15): error AS0013: The field identifier '1000000' is not valid. It must be within the range '[50000..50099]', which is allocated to the application, and outside the range '[50000..99999]', which is allocated to per-tenant customizations.
```

</details>

### VS Code

Arthur opened the `vscode` folder of the scratchpad (same fixture, `.alpackages` with `System.app` 28.0.54265) in VS Code with AL `18.0.2819426`, opened `app.json` and the three `.al` files and read the Problems pane. `.vscode/settings.json`:

```json
{
  "al.enableCodeAnalysis": true,
  "al.codeAnalyzers": [ "${CodeCop}", "${UICop}", "${PerTenantExtensionCop}", "${AppSourceCop}" ],
  "al.enableExternalRulesets": true,
  "al.ruleSetPath": "https://arthurvdv.github.io/rulebook-spike-endpoint/v2/rulesets/listed-warning.ruleset.json",
  "al.packageCachePath": ["./.alpackages"]
}
```

For V3 and V4 `al.ruleSetPath` pointed at `.../v2/rulesets/recommended.ci.ruleset.json`; `app.json` was swapped by copying the variant with or without `"suppressWarnings": ["AS0084", "AS0013"]` over it.

- **V1** (listed-warning, no `suppressWarnings`), Problems pane export, verbatim (the learn.microsoft.com target column shortened):

  ```
  file|error code|severity|error message|start line|start char|end line|end char|target
  app.json|AS0084|Error|The ID range '[50000..50099]' is not valid. It must be within the range allocated to the partner for AppSource, within the range '[1000000..75999999]' allocated to AppSource applications, and outside the range '[50000..99999]' allocated to per-tenant customizations.|7|2|7|12|.../appsourcecop-as0084
  src\SpikeExt.TableExt.al|AS0013|Warning|The field identifier '60000' is not valid. It must be within the range '[50000..50099]', which is allocated to the application, and outside the range '[50000..99999]', which is allocated to per-tenant customizations.|4|14|4|19|.../appsourcecop-as0013
  src\Spike.Codeunit.al|AA0137|Error|Variable 'Unused' is unused in 'Probe'.|4|8|4|14|.../codecop-aa0137
  ```

  No AL1033 or ruleset message. The export shows only these three; the other AS ids `alc` reports for the same fixture (AS0051, AS0015, AS0052, AS0054, AS0100, AS0092, AS0103) and PTE0004 did not appear in it, with the three files open.
- **V2** (listed-warning, `suppressWarnings` copied into `app.json`): Arthur: "I've needed to do reload window". The Problems pane did not update on its own after the `app.json` change; Developer: Reload Window was required. After the reload the pane showed the expected state: AS0084 absent, AS0013 Warning, AA0137 Error.
- **V3** (sparse, `suppressWarnings`, after Reload Window): matched the expected result: AS0084 and AS0013 absent, AA0137 Error.
- **V4** (sparse, no `suppressWarnings`): matched the expected result: AS0084 Error, AS0013 Error, AA0137 Error.

V1 shows the endpoint loaded in the editor (AA0137 at `Error`, AS0013 at the listed `Warning`); V2 shows the listed AS0013 keeping its `Warning` despite `suppressWarnings` while the unlisted AS0084 disappears; V3 versus V4 shows the editor applies `suppressWarnings` to the unlisted ids the same way `alc` does.

## Answer

Yes: against a sparse endpoint that does not list them, `"suppressWarnings": ["AS0084", "AS0013"]` in `app.json` removes both AppSourceCop Errors, on Pages and raw and through the one-include skeleton, while the endpoint's own rules still apply. It stops working as soon as the effective ruleset lists the id, at any action: a listed AS0013 stays a Warning or an Info, a listed AA0137 stays an Error, whether the listing comes from the endpoint, from the skeleton's include or from the skeleton's own `rules`; only `/nowarn` on the `alc` command line overrides a listed id. AS0013's real trigger is a field added by a `tableextension` whose id lies outside the app's `idRanges` (1..49999 also accepted when the extended table is the app's own or its publisher's); the range 50000..99999 is not checked by AS0013 despite its message text, it is AS0084's subject. VS Code with AL 18.0.2819426 behaves the same for the unlisted case (AS0084 and AS0013 present without and absent with `suppressWarnings` against the sparse endpoint) and keeps the listed AS0013 at `Warning` despite `suppressWarnings`. In the editor a change to `suppressWarnings` in `app.json` took effect only after Developer: Reload Window.

## Consequences for blocked work packages

Claims of the template page [`ALCops/rulebook` `docs/pte-or-appsource.md`](https://github.com/ALCops/rulebook/blob/main/docs/pte-or-appsource.md), checked against the observations:

| Line(s) | Claim | Verdict |
|---|---|---|
| 38 | An endpoint lists only rules whose severity differs from the analyzer default; the contradicting blockers are not in the file. | Design (D22), not tested here; the sparse endpoint of this spike is built that way. |
| 39 | `suppressWarnings` is merged strictest-wins after the ruleset, switches off exactly the unlisted rules, has no effect on listed ones. | **Confirmed** on `alc` (2p, 2r, 6p versus 3p, 4p, 6w, 7b) and in VS Code (V2, V3). |
| 61 | AS0013 "Requires field ids inside `idRanges` and outside 50000..99999." | **Corrected**: AS0013 checks only `idRanges` (8a: field 50050 passes). Proposed text: "Requires every field a table extension adds to lie inside `idRanges`. The message also names 50000..99999, but only AS0084 checks that range." |
| 62 | AS0084 requires `idRanges` inside the AppSource range and outside 50000..99999. | **Confirmed** (c0 message and code). |
| 97 | `suppressWarnings` suppresses diagnostics of any severity, Error included; only compiler errors cannot be suppressed. | **Confirmed** for analyzer Errors (AS0084, AS0013, AS0051, AS0015, AS0052, AS0054, AS0100, PTE0004 and AA0137 removed, 7a exit 0). The compiler-error half was not tested. |
| 130 | Route B works only when the id is not listed; a listed id keeps the endpoint's action. | **Confirmed** (3p: Warning kept; 4p: Info kept; 7b: Error kept). |
| 132 | If the endpoint lists the id, `suppressWarnings` silently does nothing. | **Confirmed** (3p, 4p, 6w, V2; no diagnostic tells the user). |
| 133 | If the project ruleset's own `rules` list the id, the same. | **Confirmed** (6o). |
| 135 | Open the endpoint URL to see what it lists. | Not tested (no claim about the compiler). |
| 174 | Per-tenant list `AS0013, AS0084, AS0054, AS0051, AS0052, AS0092, AS0015`. | **Confirmed** as far as observed: on a minimal per-tenant manifest these are exactly the AS ids that fire besides AS0100 (fires only because the fixture has no `application`, which a real project has) and AS0103 (a both-cops permission set check the page keeps on purpose, line 76). |
| 194 | AppSource list of PTE ids. | Not tested (no AppSource fixture). |
| 237 | AS0084 still reported after adding it to `suppressWarnings` means the endpoint lists it. | **Confirmed** as a mechanism (observed with AS0013 and AA0137; the merge in `CommandLineParser.cs` does not depend on the id). |

| WP | Consequence | Action taken |
|---|---|---|
| WP06 ([#8](https://github.com/ALCops/rulebook-engine/issues/8)) | D22 confirmed on `alc` and in VS Code: sparse endpoints keep route B (`suppressWarnings`) available for every unlisted id, and any listed id (even at Info) makes route B a silent no-op, so an organization override of an AS id moves projects to route C. No design change. | Comment posted on [#8](https://github.com/ALCops/rulebook-engine/issues/8#issuecomment-5977220845) |
| WP11 ([#13](https://github.com/ALCops/rulebook-engine/issues/13)) | Route B, route C and the troubleshooting row confirmed; the AS0013 row of `pte-or-appsource.md` (line 61) needs the correction above. Editor side observation (AL 18.0.2819426): after a `suppressWarnings` change in `app.json` the Problems pane did not refresh until Developer: Reload Window, so the walkthrough should say "reload the window after editing `suppressWarnings`"; spike (e) ([#23](https://github.com/ALCops/rulebook-engine/issues/23)) measures the re-fetch triggers in detail. | Comment posted on [#13](https://github.com/ALCops/rulebook-engine/issues/13#issuecomment-5977221085), with the proposed text for line 61; the template repository is not edited here |
| Docs | [compiler-ruleset-internals.md §8](../compiler-ruleset-internals.md#8-how-the-ruleset-combines-with-other-inputs) (suppressWarnings strictest-wins, `/nowarn` after the ruleset) confirmed; [ADR 0022](../../adr/0022-sparse-endpoints-an-id-at-its-analyzer-default-is-not-listed.md) rationale confirmed. | One-sentence link added under §8; no ADR edit. |

## Not covered

- A table extension of a table in another app from another publisher (the usual per-tenant case, extending Base Application): it needs the application symbols; from the code the check there is `idRanges` only, without the 1..49999 exception.
- AS0084 listed in an endpoint (observed with AS0013 and AA0137; same code path).
- Compiler errors (`NotConfigurable`) in `suppressWarnings`: not tried.
- AL-Go and BcContainerHelper: same compiler, not run.
- VS Code: why AS0051, AS0015, AS0052, AS0054, AS0100, AS0092, AS0103 and PTE0004 did not show in the Problems pane export while `alc` reports them (manifest-level and compilation-level diagnostics in the editor) was not investigated.

## Artifacts

- Final run: <https://github.com/ALCops/rulebook-engine/actions/runs/37180612371> (job summary holds the result table); first run: <https://github.com/ALCops/rulebook-engine/actions/runs/37180549341>.
- The throwaway workflow `.github/workflows/spike-f.yml` lived on `wp01/spike-f` and was removed before the pull request; the version the final run executed is `51191f8:.github/workflows/spike-f.yml` (`git show 51191f8:.github/workflows/spike-f.yml`).
- Scratch repository `Arthurvdv/rulebook-spike-endpoint` (from [spike (a)](a-hosts-and-skeleton-include.md)): `v2/rulesets/recommended.ci.ruleset.json`, `listed-warning.ruleset.json` and `listed-info.ruleset.json` added in commit `d5503ff` on 2026-10-04; kept for spike (e), deleted after WP01 (#3).
- Nothing besides this file and the one-sentence link in compiler-ruleset-internals.md is kept in the repository.
