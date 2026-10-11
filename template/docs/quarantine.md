# New diagnostics and quarantine

The AL compiler, the Microsoft code cops and the ALCops analyzers gain new diagnostics with every release. Your rulebook decides what happens to them: the **Scan Diagnostics** workflow reads the newest packages every day, records every new diagnostic in your catalog and holds it back in the stages you choose (its *quarantine*) until you adopt it. It keeps one pull request with everything it found. With a policy that quarantines, a new rule does not reach your AL projects until you adopt it.

> **Status:** written 2026-10-08 with the scan work package of the engine ([WP08, #10](https://github.com/ALCops/rulebook-engine/issues/10)). Everything below was observed in a live run on a scratch repository or is stated by the engine's contributor reference, [scan-mechanics.md](https://github.com/ALCops/rulebook-engine/blob/main/docs/reference/scan-mechanics.md), which also holds the run table. The scan writes with the same secret as the update: [ghtokenworkflow.md](ghtokenworkflow.md).

## Contents

1. [What the scan does](#1-what-the-scan-does)
2. [Choosing the policy](#2-choosing-the-policy)
3. [Reading the pull request](#3-reading-the-pull-request)
4. [Adopting a quarantined rule](#4-adopting-a-quarantined-rule)
5. [Changed defaults](#5-changed-defaults)
6. [The catalog](#6-the-catalog)
7. [Running it by hand](#7-running-it-by-hand)
8. [Troubleshooting](#8-troubleshooting)

## 1. What the scan does

The scan reads two packages from nuget.org: **Microsoft.Dynamics.BusinessCentral.Development.Tools** (the compiler and the CodeCop, UICop, AppSourceCop and PerTenantExtensionCop analyzers, called `tools` in titles) and **ALCops.Analyzers** (the ALCops cops, called `alcops`). Of each it takes the newest stable version and the newest prerelease, the prerelease only when it is newer than the stable version: an ALCops prerelease such as 1.3.0-beta.1 that is older than the stable 1.3.1 is not scanned.

`catalog/scan-state.json` records which versions it has scanned. When neither package has a new version and no quarantined diagnostic has been adopted in a level file, the run ends in seconds with the notice "No new package version (...); nothing to do". When a package has a new version, the scan reads every diagnostic of that version, compares them with `catalog/diagnostics.json` and then:

- adds every new diagnostic to the catalog and to the quarantine files your policy names ([section 2](#2-choosing-the-policy));
- releases quarantined diagnostics that a level file has adopted in the meantime ([section 4](#4-adopting-a-quarantined-rule)); this also happens without a new package version;
- records changed default severities ([section 5](#5-changed-defaults));
- regenerates the endpoints in `rulesets/`, runs the full validation and puts the result into **one pull request** on the branch `scan-diagnostics/<branch>`, `scan-diagnostics/main` for a scan of `main`.

The workflow runs every day at 04:17 UTC (the `scan.schedule` setting, [section 7](#7-running-it-by-hand)) and whenever you start it under Actions > **Scan Diagnostics** > Run workflow. It needs the `GHTOKENWORKFLOW` secret ([ghtokenworkflow.md](ghtokenworkflow.md)).

## 2. Choosing the policy

There is no default policy: until you set both keys of `quarantine` in `.github/Rulebook-Settings.json`, every run stops before it reads anything, with

> Set quarantine.stages and quarantine.prereleaseStages in .github/Rulebook-Settings.json. Typical choice: quarantine default and ci, leave vnext out so it shows new rules at their default severity.

| Key | Receives |
|---|---|
| `quarantine.stages` | Diagnostics first seen in a **stable** package version; a prerelease diagnostic that is still in a quarantine file when a stable version carries it (promoted to stable); and a diagnostic the catalog had as defined but not reported (`advertised: false`, [section 6](#6-the-catalog)) that an analyzer of a stable version starts to report. |
| `quarantine.prereleaseStages` | Diagnostics first seen in a **prerelease**. |

Both are lists of stage names in lowercase, as they appear in your file names (`default`, `ci`, `vnext`, or a stage you added). Two typical policies:

```json
"quarantine": { "stages": ["default", "ci"], "prereleaseStages": ["default", "ci"] }
```

New rules stay off in the editor and in your pipelines until you decide, and `vnext` shows them at their default severity, so builds against the next platform warn you early.

```json
"quarantine": { "stages": [], "prereleaseStages": ["default", "ci"] }
```

A new rule of a stable release is active everywhere at once, at the severity its analyzer gives it; a rule that is off by default stays off. Only prerelease rules are held back. `[]` is valid for either key and quarantines nowhere: the new diagnostics are then only recorded in the catalog.

A quarantined diagnostic is `None` in the endpoints of that stage, for every level, until a level file mentions it. A diagnostic that is off by default is simply not listed in the endpoints, quarantined or not, and stays off (LC0054 in the live run). Each stage has its own file, `quarantine.<stage>.json`, `quarantine.default.json` included. A stage you add gets its file the first time the scan writes to it: in the live run, the stage `Nightly` in the settings and the slug `nightly` in `quarantine.stages` gave `quarantine.nightly.json` with the next new diagnostic. A file named after a stage your settings do not have is not read by anything; Validate warns about it (C16).

## 3. Reading the pull request

The pull request is titled with the counts first and then the package versions it scanned, for example

- `Scan diagnostics: 3 new ids quarantined (alcops 1.3.1, tools 18.0.43.1464, tools 30.0.42.60748-beta)`
- `Scan diagnostics: 1 quarantine entry released, no new package version`
- `Scan diagnostics: alcops 1.3.1 recorded, no new diagnostics`

The last one is a **record run**: a new package version that brought nothing new. It still opens a pull request, because the catalog and `catalog/scan-state.json` record the version; merge it so the next run does not scan that version again. The parts of a title, in this order: new diagnostics quarantined, new diagnostics recorded (no policy stage took them), diagnostics promoted to stable, defaults changed, quarantine entries released.

The body has these sections. Changes and Effective diff are always there ("No file changes.", "No effective change." when there is nothing); the others only when they have something to show:

| Section | Example from the live run |
|---|---|
| Scanned versions | `\| alcops.analyzers \| stable \| 1.3.1 \| none \| 127 \| 2 \| 0 \|`: package, channel, version, the version recorded before, the number of diagnostics, the new ones and the changed defaults. |
| New diagnostics | `\| LC0043 \| LinterCop \| Warning \| Use SecretText type to protect credentials ... \| docs \| alcops.analyzers 1.3.1 (stable) \| default, ci \|`: the default severity (`Warning (disabled)` for a rule that is off by default), the link to its documentation, where it was seen (`..., now advertised` for a diagnostic an analyzer reports for the first time), and where it is quarantined, or `nowhere (policy [])` when the policy key is empty, `nowhere (not advertised)` for a diagnostic no analyzer reports, `nowhere (a level file mentions it)` when a level file already sets it. |
| Promoted to stable | A prerelease diagnostic still in a quarantine file that a stable version now carries, added to `quarantine.stages`. |
| Changed defaults | See [section 5](#5-changed-defaults). |
| Prerelease default changes (not applied) | A prerelease that changes a default; nothing changes until a stable version carries it. |
| Released from quarantine | `\| default \| LC0043 \| base/essential.ruleset.json \|`: the stage, the diagnostic and the level file that now mentions it. |
| Catalog notes | For example "622 seeded ids got their package fields", "Refreshed from the stable descriptors: 1 title, 2 docs links", the diagnostics no analyzer advertises ([section 6](#6-the-catalog)). |
| Changes | Every file the pull request changes. |
| Effective diff | One table per endpoint: before, after, and what decided it, for example `\| LC0043 \| (unknown default) \| None \| quarantine, "New in alcops.analyzers 1.3.1 (stable), quarantined 2026-10-08. Review and adopt." \|`. A diagnostic the catalog did not know before shows `(unknown default)` on the left. |
| Validation warnings | Warnings of the validation of the result; an error stops the run instead. |

**One pull request, rebuilt every run.** The scan does not open a new pull request per run. Every run rebuilds the branch `scan-diagnostics/<branch>` from the current state of the scanned branch as one commit with the whole current result, and updates the title and body of the open pull request ("Pull request updated: ..."). That keeps it mergeable after other pull requests and makes the body describe exactly what the branch holds. **Do not push to that branch**: the next run replaces your commit. Merge the pull request. If you close it instead, the next run brings it back, because your branch still lacks the catalog and scan-state change; changing the policy or adopting the diagnostics does not stop that, only merging does. When the scanned branch already holds the result, or the result went in as a direct commit ([section 7](#7-running-it-by-hand)), the scan closes an open scan pull request and starts its body with a line that says why.

Every quarantine entry carries its reason, for example

```json
{ "id": "LC0043", "justification": "New in alcops.analyzers 1.3.1 (stable), quarantined 2026-10-08. Review and adopt." }
```

## 4. Adopting a quarantined rule

**Release it with a level file of your own.** Mention the diagnostic in a level file of a published level that you added yourself, for example `{ "id": "LC0043", "action": "Error" }` in your own `base/<level>.ruleset.json`. A level is published when it has an entry under `levels` in your settings and its file `base/<slug>.ruleset.json` exists; a file in `base/` that no `levels` entry names (directly or as `basedOn`) releases nothing. Do not edit the shipped level files (`base/essential.ruleset.json`, `recommended`, `strict`, `complete`): the next update replaces them with the template version ([updating.md](updating.md) section 1), and your adoption is gone. From then on the level decides for that diagnostic, on every level whose chain contains your file, and quarantine no longer applies to it there. Validate reports the quarantine entry that is left as a warning (C13), and the next scan removes it from every quarantine file, even without a new package version: in the live run that was the pull request `Scan diagnostics: 1 quarantine entry released, no new package version`, with only `quarantine.default.json` and `quarantine.ci.json` changed. Until that pull request is merged, levels whose chain does not contain your file still show the diagnostic at `None` in the quarantined stages; after it, they get its default severity. To keep a diagnostic off in every level, leave its quarantine entry in place; `None` in your own level file keeps it off only for the levels whose chain contains that file.

**Set it with an override.** An entry in `overrides.json` wins over quarantine in the endpoints for the levels and stages it selects; the Change Rule workflow writes one for you ([changing-a-rule.md](changing-a-rule.md)). It does not release the quarantine entry: the entry is no C13 warning and the scan never removes it, so it stays in the quarantine file until a level file mentions the diagnostic or you delete it by hand. Delete it in the same pull request when the override is your decision.

**Delete the entry by hand.** Removing an entry from a quarantine file also adopts the diagnostic, at its default severity (or at the action a level file or an override gives it).

**Regenerate the endpoints in the same pull request.** A level file, `overrides.json` or a quarantine file you change by hand leaves `rulesets/` out of date: Validate fails with C12 ("... would be modified; run Update-RulebookEndpoints and commit the result") and Publish refuses to deploy ([hosting.md](hosting.md)). For an override, the Change Rule workflow regenerates in its own pull request ([changing-a-rule.md](changing-a-rule.md)). For a hand edit there are two ways:

- **Locally.** Clone the `main` branch of [ALCops/rulebook-engine](https://github.com/ALCops/rulebook-engine) next to your repository (the branch your workflows use, so the local run and Validate write the same bytes) and run, in PowerShell 7.4 or newer from the root of your rulebook repository:

  ```powershell
  Import-Module ../rulebook-engine/modules/Rulebook.Generate.psd1
  Update-RulebookEndpoints -RepositoryRoot .
  ```

  Commit the changed `rulesets/` files with your change.
- **With the update workflow.** Merge your change, then run Update Rulebook System Files with "Resolve the latest commit" off ([updating.md](updating.md) section 2): it re-applies the installed template and regenerates `rulesets/` in its pull request.

A scan run that finds something (a new package version, or a quarantined diagnostic that a level file now mentions) also regenerates every endpoint on its candidate (code-derived; in the live run the endpoints were regenerated before the housekeeping run, which changed only the two quarantine files). An override or a deleted quarantine entry alone does not start such a run. Until the regenerated endpoints are merged, Validate fails on your branch and Publish keeps the endpoints it published last.

## 5. Changed defaults

Your endpoints list only the diagnostics whose action differs from the analyzer's default. When a stable version changes a default severity, or turns a rule on or off by default, the scan updates `defaultSeverity` or `enabledByDefault` in the catalog, records the change as a `defaultChanges` element of that entry, and lists it in the pull request with its effect, for example "now listed at Info in strict.ci; now unlisted in strict.default". A diagnostic whose level action now equals the new default drops out of that endpoint; one whose default moved away from the level action appears in it. For a diagnostic a level file, an override or the twins setting decides, the effective action in your AL projects stays what that decides. A diagnostic that is still quarantined stays `None` in the quarantined stages. A diagnostic that nothing mentions follows the new default.

To keep a diagnostic at a fixed severity whatever its analyzer does, give it that action in a level file of your own or in `overrides.json`. A prerelease never changes a default: such a change is listed under "Prerelease default changes (not applied)" and waits for the stable version.

The live run could not show a changed default (nuget.org cannot be steered); the engine's tests prove it with test packages.

## 6. The catalog

`catalog/diagnostics.json` lists every diagnostic your rulebook knows, one entry per line. The template ships it with 628 entries (`id`, `analyzer`, `defaultSeverity`, `enabledByDefault`, `title`, `docs`). These shipped diagnostics are known: the scan never quarantines them as new; it only adds their package fields, from the first scanned version that carries each of them. The scan writes:

| Field | Meaning |
|---|---|
| `package`, `firstSeenVersion`, `firstSeenChannel` | The package and the first scanned version that carried the diagnostic, `stable` or `prerelease`. |
| `firstStableVersion` | The first stable version that carried it. |
| `lastSeenVersion` | The newest version that carried it; it only moves forward. |
| `title`, `docs` | Refreshed from every stable version. |
| `advertised: false` | The package defines the diagnostic but no analyzer reports it (for example AS0141 and the ALCops `xx0000` exception diagnostics). It stays in the catalog and is not quarantined while no analyzer reports it. When an analyzer of a stable version starts reporting it, it is quarantined in `quarantine.stages` like a new diagnostic, shipped or not. |
| `deprecated: true` | The analyzer marks the diagnostic as deprecated. |
| `defaultChanges` | One element per changed default of a stable version, [section 5](#5-changed-defaults). |

A diagnostic that a newer package no longer carries keeps its entry, with its old `lastSeenVersion`. In the first live scan, 625 of the 628 shipped entries got package fields; AC0033, AC0034 and TA0002 are documented by ALCops but in no released package yet, so they keep none.

`catalog/scan-state.json` is created by the first scan; the template does not ship it. It holds the version scanned last per package and channel. Once it exists, every diagnostic named in a level file, a stage file, `base/twins.json`, `overrides.json` or a quarantine file must be in the catalog: a missing one is an error in Validate (C7), where it was a warning before the first scan.

## 7. Running it by hand

Actions > **Scan Diagnostics** > Run workflow:

| Input | Default | Use |
|---|---|---|
| Also scan the newest prerelease | on | Off scans only the stable versions; the prerelease entries of `catalog/scan-state.json` stay as they are. A scheduled run always scans prereleases. |
| Push to this branch instead of updating the scan pull request | off | A direct commit, see below. |

**Direct commit.** With the input on, the result is committed to the branch you run the workflow on (`main` by default), and the summary goes to the run's job summary only. When the push is refused, because a ruleset or branch protection requires pull requests, the scan opens the pull request instead and says "(the direct commit was refused)". A scheduled run makes a direct commit when `commitOptions.createPullRequest` is `false` in your settings.

**To confirm it works**, run the workflow by hand once after you set the policy: it ends with the scan pull request (or a direct commit), or with "No new package version (...); nothing to do", and `catalog/scan-state.json` on the branch records the versions it read.

**The schedule.** `scan.schedule` in your settings is the cron expression of the daily run (shipped `"17 4 * * *"`). The workflow file carries it: the Update Rulebook System Files workflow writes it into `ScanDiagnostics.yaml` ([updating.md](updating.md) section 6), so a changed `scan.schedule` takes effect only after an update run and the merge of its pull request. `null` removes the schedule, so the scan runs only by hand. A settings file without a `scan` key, such as one created before the scan existed, keeps the shipped daily schedule.

**Scanning a version again.** The scan skips a version that `catalog/scan-state.json` records. To scan a package channel again, set its entry to `null` and run the workflow. The entry is under `packages` > the package id > `stable` or `prerelease`, for example:

```json
"packages": {
  "microsoft.dynamics.businesscentral.development.tools": {
    "stable": null,
    "prerelease": { "version": "30.0.42.60748-beta", "scannedAt": "2026-10-08T09:15:13Z" }
  },
  "alcops.analyzers": {
    "stable": { "version": "1.3.1", "scannedAt": "2026-10-08T09:27:21Z" },
    "prerelease": null
  }
}
```

## 8. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| "Set quarantine.stages and quarantine.prereleaseStages in .github/Rulebook-Settings.json. ..." | The policy is not set. | See [section 2](#2-choosing-the-policy). |
| "The GHTOKENWORKFLOW secret is needed to scan diagnostics. Read ..." | The secret named by `ghTokenWorkflowSecretName` (default `GHTOKENWORKFLOW`) is missing or empty in this repository. | See [ghtokenworkflow.md](ghtokenworkflow.md). |
| "The scanned rulebook would not validate: LC0999: LC0999 is not in catalog/diagnostics.json (catalog/scan-state.json exists); add LC0999 to catalog/diagnostics.json or remove it from base/complete.ruleset.json; ..." | A file names a diagnostic the catalog does not know, a typo for example. After the first scan this is an error. Nothing was pushed. | Fix the name, or add the entry. |
| "The diagnostics could not be extracted: Extraction failed for ..." | A package version could not be read, for example an analyzer that fails to load in it. Nothing was pushed and your catalog stays as it was. Every run fails the same way while that version is the newest one. | Report it at [ALCops/rulebook-engine](https://github.com/ALCops/rulebook-engine/issues); the scan works again once the engine your workflow uses can read the package. |
| "The NuGet packages could not be read: ..." | nuget.org was not reachable or kept answering with an error (the scan retries three times). | Run the workflow again later. |
| "The base branch moved during the scan (main <sha> is now <sha>); nothing was pushed, the next run will pick it up." | Someone merged into the branch while the scan ran. | Run the workflow again, or wait for the next day. |
| "Failed to push the scan. Make sure that the token in the secret GHTOKENWORKFLOW is not expired and may write contents and pull requests of <repository>. Read ... (Error was: ...)" | The push was refused: an expired token or an app without Contents write, or "git push --force-with-lease ... failed" when someone pushed to `scan-diagnostics/<branch>` while the scan pushed. | Read the part after "Error was:". Renew the token or fix the app ([ghtokenworkflow.md](ghtokenworkflow.md) section 6); after a lease failure just run the workflow again. |
| "Failed to create or update the scan pull request. ... (Error was: ...)" | The branch was pushed but the pull request could not be opened or updated, usually because the token lacks Pull requests write. | Give the token Pull requests write ([ghtokenworkflow.md](ghtokenworkflow.md) section 6); the message names the pushed branch and a link to open the pull request by hand. |
| The pull request did not update | The run ended with "No new package version (...); nothing to do": no new package version and no adopted diagnostic, so there was nothing to rebuild. Or the run failed. | Nothing to do in the first case; otherwise see the rows above. |
| A diagnostic you removed from the catalog by hand does not come back | The scan only scans versions it has not recorded. | Wait for the next package version, or set the channel's entry in `catalog/scan-state.json` to `null` ([section 7](#7-running-it-by-hand)). |
