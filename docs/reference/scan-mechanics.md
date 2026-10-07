# Scan mechanics

How the diagnostic scan of an organization rulebook repository works: which packages and versions it reads, how it extracts the diagnostic ids, what it writes into the catalog and the quarantine files, how housekeeping releases adopted ids, and how the one living pull request is built and kept. The design is in [ARCHITECTURE.md](../ARCHITECTURE.md) section 7.4, the extraction method in [spike (b)](spikes/b-analyzer-dll-extraction.md), the decisions in [D10](../adr/0010-the-diagnostic-scan-runs-in-each-org-repo.md), [D14](../adr/0014-the-quarantine-policy-is-configured-per-org-with-no-default.md), [D24](../adr/0024-the-catalog-records-analyzer-defaults-and-the-scan-reports.md), [D45](../adr/0045-the-scan-keeps-one-living-pull-request-and-records-every-package-version.md) and [D46](../adr/0046-seeded-catalog-ids-are-known-unadvertised-deprecated-and-vanished-ids-are-catalog-flags.md).

> **Status:** written by WP08 ([#10](https://github.com/ALCops/rulebook-engine/issues/10)). Code: `modules/Rulebook.NuGet.psm1`, `Rulebook.Extract.psm1`, `Rulebook.Catalog.psm1`, `Rulebook.Quarantine.psm1`, `Rulebook.Scan.psm1`, `actions/ScanDiagnostics/`, `template/.github/workflows/ScanDiagnostics.yaml`. Everything below is derived from that code and its tests unless it says *observed*; the live run is section 11.

---

## Contents

1. [Packages and channels](#1-packages-and-channels)
2. [Extraction](#2-extraction)
3. [Catalog and scan state](#3-catalog-and-scan-state)
4. [Policy and quarantine files](#4-policy-and-quarantine-files)
5. [Housekeeping](#5-housekeeping)
6. [The run step by step](#6-the-run-step-by-step)
7. [The living pull request](#7-the-living-pull-request)
8. [Pull request body and job summary](#8-pull-request-body-and-job-summary)
9. [Action reference](#9-action-reference)
10. [Engine proof](#10-engine-proof)
11. [Live run](#11-live-run)

---

## 1. Packages and channels

Two packages from `https://api.nuget.org/v3-flatcontainer`: `microsoft.dynamics.businesscentral.development.tools` (label `tools`: the compiler and the four Microsoft cops) and `alcops.analyzers` (label `alcops`: the seven ALCops cops). The `.Linux`, `.win` and `.osx` variants of the tools package are never read: their analyzers are byte-identical and they lack the compiler ([spike (b)](spikes/b-analyzer-dll-extraction.md)).

| Function | Rule |
|---|---|
| `Get-NuGetVersionIndex -PackageId [-Source]` | `GET <Source>/<id>/index.json`, the id lowercased. A `-Source` that is an existing folder is read from disk (the stub feeds of the suites). A non-200 answer or a missing index throws `Could not read the NuGet index of <id> (HTTP <status>)`, stage `nuget`. Every web request (`Invoke-NuGetRequest`) is retried three times with a short backoff on a 5xx or 429 answer and on a request without an answer; a 404 is not retried. |
| `Compare-NuGetVersion -Reference -Difference` | NuGet semantic versioning: up to four numeric parts (missing parts are 0, so `1.0` equals `1.0.0.0`); a version without a release label sorts after the same numbers with one; labels compare identifier by identifier (numeric by value, numeric before alphanumeric, else ordinal ignoring case, a shorter prefix first); build metadata is ignored. `1.4.0-beta.2` sorts before `1.4.0-beta.10`. |
| `Select-NuGetChannelVersion -Versions [-IncludePrerelease]` | Every entry goes through the version parser first; an entry that is not a version (an empty string, `../x`) is skipped, listed in `Invalid` and noted in the pull request, so a sole entry is validated too. Stable is the highest version without a label. Prerelease is the highest version with one, only with `-IncludePrerelease` and only when it sorts after Stable: ALCops `1.3.0-beta.1` after `1.3.1` is no prerelease channel. The index order is never trusted. |
| `Save-NuGetPackage -PackageId -Version -Path [-Source]` | Downloads `<id>/<version>/<id>.<version>.nupkg` (lowercase) and extracts it into `<Path>/<id>.<version>/` (deleted first). A version that is not a NuGet version, a nupkg or extract path outside `-Path`, or a zip entry that would land outside the extract folder throws before anything is written outside. |

`catalog/scan-state.json` records the version scanned last per package and channel. A channel whose version sorts after the recorded one is new (`Get-NewPackageVersion`), ordered tools before alcops and stable before prerelease; an index that names an equal or older version than the state (a package unlisted on nuget.org) is skipped and noted, so the scan never goes back. A prerelease that is not newer than the stable version is skipped; `includePrerelease: false` leaves the prerelease entries of the state untouched.

## 2. Extraction

Reflection in pwsh (spike (b), method 1), one child process per package version and channel, so two versions of `Microsoft.Dynamics.Nav.CodeAnalysis` never meet in one process.

- **Folder.** `Resolve-AnalyzerFolder` picks, among the subfolders `net<N>.0` of `tools/` (with `any/` below) or `lib/`, the highest `N` not newer than the running .NET (`net10.0` with pwsh 7.6.6 on .NET 10.0.12, observed in spike (b) on runner image 20260927.320.1); `netstandard2.1` is never chosen (its LinterCop build drops LC0091). No folder for the runtime throws and names the folders found.
- **Host.** A tools version is extracted from its own folder. An ALCops version needs the compiler: it is hosted by the tools version of the same channel from the index (the prerelease tools for an ALCops prerelease, downloaded if this run has not yet), else by the stable tools version.
- **Child process.** `Invoke-DescriptorExtraction` starts the pwsh of `$PSHOME` (`Get-Command pwsh` as the fallback; under a .NET global tool install the process path is `dotnet`) with `-NoProfile -NonInteractive -OutputFormat Text -EncodedCommand`. The child imports `Rulebook.Extract` and runs `Get-AnalyzerDescriptor`, which writes its result to `<work>/descriptors-<guid>.json`. The child gets no token: every `INPUT_*` variable, `GITHUB_TOKEN`, `GH_TOKEN`, `ACTIONS_RUNTIME_TOKEN`, `ACTIONS_ID_TOKEN_REQUEST_TOKEN` and any variable whose name ends in `TOKEN` is removed from its environment, because it loads the downloaded DLLs and runs their analyzer constructors. A non-zero exit, no result after 300 s (the child is killed) or no result file throws `Extraction failed for <ToolsDir>: <the last 20 output lines>`, stage `extract`.
- **Loading.** `LoadFrom` on `Microsoft.Dynamics.Nav.CodeAnalysis.dll`, then every `Microsoft.Dynamics.Nav.*Cop.dll` of the tools folder and every `ALCops.*.dll` of the ALCops folder, with an `AssemblyResolve` handler that probes the ALCops folder, then the tools folder (ALCops.LinterCop references `Microsoft.Dynamics.Nav.CodeAnalysis.Workspaces`). The handler reads its folders from a module variable and makes .NET calls only: a handler built with `GetNewClosure()` that called `Join-Path` and `Test-Path` overflowed the stack of the child (observed while building the stub fixture).
- **Compiler ids.** The internal enum `Microsoft.Dynamics.Nav.CodeAnalysis.ErrorCode`: members of 100 and up named `WRN_` (Warning), `INF_` (Info) or `HDN_` (Hidden), id `AL<n:0000>`, enabled; titles from the resource `CompilerDiagnosticsResources` (a missing resource leaves the titles empty and notes it).
- **Cop ids.** Every non-abstract `DiagnosticAnalyzer` with a parameterless constructor is instantiated and its `SupportedDiagnostics` enumerated (an `ImmutableArray` or an array). A second pass reads the static fields and properties of type `DiagnosticDescriptor`; an id found only there is *field-only* (`advertised: false`). A static member whose getter throws does not fail the run; it is listed (`fieldErrors`) and noted in the pull request and the job summary.
- **Loud failure.** An assembly that does not load, a `ReflectionTypeLoadException`, an analyzer that cannot be instantiated or a missing expected assembly (the five tools assemblies, plus the seven ALCops ones for an ALCops version; further cop DLLs are scanned by the pattern) fails the extraction. The spike accepted a partial load silently; the scan never does.

`ConvertTo-DiagnosticRecord -Result -PackageId` turns the rows into one record per id of that package (`ALCops.*` assemblies for `alcops.analyzers`, `Microsoft.Dynamics.Nav.*` for the tools): analyzer `Compiler`, or `<X>` of `Microsoft.Dynamics.Nav.<X>` and `ALCops.<X>` (the seed's names); white space in a title folded to one space; duplicates merged (62 ids come from several analyzers), disagreeing duplicates listed as a conflict note with the first one kept; ids with a prefix the engine does not know kept and noted.

The docs URL (`Get-CatalogDocsUrl`): a compiler id gets `https://learn.microsoft.com/dynamics365/business-central/dev-itpro/developer/diagnostics/diagnostic-al<n>` (no leading zeros); any other id its help link without the query string (the Microsoft links carry `?wt.mc_id=d365bc_inproduct_alextension`), with the path lowercased on `alcops.dev` (the TestAutomationCop links say `testautomationCop`, a 404).

## 3. Catalog and scan state

`catalog/diagnostics.json`, one entry per line, keys in this order (a seed entry has the first six):

```json
{ "id": "LC0099", "analyzer": "LinterCop", "defaultSeverity": "Warning", "enabledByDefault": true, "title": "...", "docs": "https://alcops.dev/docs/analyzers/lintercop/lc0099/", "package": "alcops.analyzers", "firstSeenVersion": "1.4.0-beta.1", "firstSeenChannel": "prerelease", "firstStableVersion": "1.4.0", "lastSeenVersion": "1.4.0", "advertised": false, "deprecated": true, "defaultChanges": [ { "version": "1.5.0", "field": "defaultSeverity", "from": "Info", "to": "Warning" } ] }
```

`Update-CatalogFromScan` applies one scanned version and is pure (it returns a new catalog and the lists below):

| Case | Rule | Listed as |
|---|---|---|
| New id | A full entry: analyzer, defaults, title, docs, `package`, `firstSeenVersion` and `firstSeenChannel` of this version, `firstStableVersion` when stable, `lastSeenVersion`, `advertised: false` when field-only. | `NewIds` (field-only ones also `Unadvertised`) |
| Seeded id (no `package` yet) | The package fields are filled from the first scanned version that carries it; never quarantined (D46). | `Recorded` |
| Promotion | A stable version sets `firstStableVersion` once. An id first seen in a prerelease and still in a quarantine file is promoted. | `Promoted` |
| Newly advertised | A stable version whose analyzers return an id the catalog has as `advertised: false` (seeded or not): the id goes live at its default, so it is quarantined like a new id. | `NewlyAdvertised` |
| Default change, stable | The default is overwritten and one `defaultChanges` element per field and version is appended once (D24). | `ChangedDefaults` |
| Default change, prerelease | Nothing changes. | `PrereleaseDefaultChanges` |
| Text | `title` and `docs` follow the stable descriptor (normalised); a prerelease never changes text. | `Refreshed` |
| Flags | Stable: `advertised` recomputed (written only as `false`), `deprecated` from the descriptor (written only as `true`). | `Unadvertised`, `Deprecated` |
| Vanished | A catalog id of this package that a stable version does not carry keeps its entry and its old `lastSeenVersion`. | `Vanished` |
| `lastSeenVersion` | The highest version carrying the id, any channel; it only moves forward. | |

`Write-CatalogFile` sorts by `Get-DiagnosticSortKey` and the id (the order of the seed) and writes only when the bytes differ; unknown keys of an entry are kept and written last. `ConvertTo-CatalogJson` is the one catalog writer: `Build-RulebookCatalog` writes the seed with it, so the seed round trips byte for byte.

`catalog/scan-state.json` (schema `rulebook-scan-state.schema.json`, closed), created by the first scan and never shipped by the template:

```json
{
  "$schema": "https://raw.githubusercontent.com/ALCops/rulebook-engine/v1/schemas/rulebook-scan-state.schema.json",
  "version": 1,
  "packages": {
    "microsoft.dynamics.businesscentral.development.tools": {
      "stable": { "version": "18.0.43.1464", "scannedAt": "2026-10-08T04:17:31Z" },
      "prerelease": { "version": "30.0.42.60748-beta", "scannedAt": "2026-10-08T04:17:31Z" }
    },
    "alcops.analyzers": {
      "stable": { "version": "1.3.1", "scannedAt": "2026-10-08T04:17:31Z" },
      "prerelease": null
    }
  }
}
```

Its presence turns C7 into an error: after the first scan every id in a level file, a stage file, the twins file, the overrides and the quarantine files must be in the catalog, and a scan whose candidate breaks that fails. Validate checks the file when it exists (C14, not blocking).

## 4. Policy and quarantine files

`Get-QuarantinePolicy` reads `quarantine.stages` and `quarantine.prereleaseStages` of the settings. There is no default (D14): `quarantine` absent, or either key absent or `null` (as the template ships), stops the run before any request with

> Set quarantine.stages and quarantine.prereleaseStages in .github/Rulebook-Settings.json. Typical choice: quarantine default and ci, leave vnext out so it shows new rules at their default severity.

`[]` is valid and quarantines nowhere (the new ids are then only recorded). A slug that is not a stage of the settings fails like C5.

`Update-QuarantineFromScan` reads `quarantine.<slug>.json` for every stage of the settings and adds:

- the new ids of a stable version to every stage of `quarantine.stages`;
- the new ids of a prerelease to every stage of `quarantine.prereleaseStages` (an id new in both channels of one run lands in `stages`, because the stable version is applied first);
- the promoted ids to every stage of `quarantine.stages`, next to their prerelease entries, which keep their text;
- the newly advertised ids (an id an analyzer returns for the first time) to every stage of `quarantine.stages`. The rule that seeded ids are never quarantined covers the first scan only: a seeded field-only id that an analyzer starts to return later is quarantined like any new id.

Never quarantined: an id no analyzer advertises, and an id a level file already mentions. Each addition carries `New in <package> <version> (<channel>), quarantined <yyyy-MM-dd>. Review and adopt.` (UTC). Only files whose rules changed are written, in the template layout (`$schema`, one `{ "id", "justification" }` per line, `"rules": []` when empty); a policy stage without a file gets one. A slug that is not a stage of the settings never gets a file (#48, C16).

## 5. Housekeeping

`Invoke-QuarantineHousekeeping` removes every quarantined id that a file on the chain of a published level mentions (the rule of C13): the level decides from then on, and quarantine would no longer apply anyway (D41). The pull request lists the stage, the id and the level files that mention it. A run without a new package version still runs when such an id exists (mode `housekeeping`: the scan state is untouched), so an adoption does not wait for the next package release.

## 6. The run step by step

`ScanDiagnostics.ps1` with `Get-RulebookScanPlan`:

| Step | What | Failure |
|---|---|---|
| 1 | Settings; the secret name from `ghTokenWorkflowSecretName`. | `error` |
| 2 | The policy (section 4), before any request. | `policy` |
| 3 | Unless `dryRun`: the token guard (`The <secret> secret is needed to scan diagnostics. Read <docs>`), the exchange (a GitHub App JSON becomes an installation token), the mask. | `token` |
| 4 | Both indexes, the channel versions, the new versions against the scan state. | `nuget` |
| 5 | No new version and no adopted id: `nothing-new`, exit 0. No new version but an adopted id: housekeeping only. | |
| 6 | The candidate `<work>/plan/candidate`, a copy of the repository without `.git`, `site/data` and `node_modules`. | |
| 7 | Per new version: download, extraction (section 2), `Update-CatalogFromScan`. | `nuget`, `extract` |
| 8 | Quarantine and housekeeping (sections 4 and 5). | |
| 9 | `Write-CatalogFile`, `Write-ScanState` (`scannedAt` = the run time; not in housekeeping mode), `Update-RulebookEndpoints`. | |
| 10 | `Test-Rulebook` on the candidate; any error: one annotation per finding, nothing pushed. A C7 finding names the remedy: add the id to `catalog/diagnostics.json` or remove it from the file; the scan writes `catalog/scan-state.json`, which turns the C7 warning into an error. | `validation` |
| 11 | The candidate compared with the repository (text with LF, bytes for binaries): the change list. | |
| 12 | `dryRun`: summary and outputs, the candidate kept (`candidatePath`). Else `Publish-RulebookScan` (section 7). | `push`, `pull-request` |

*Observed* (2026-10-07, a dry run on Windows, pwsh 7.6.6 on .NET 10.0.12, against nuget.org): the three new versions downloaded and extracted in 31 s in all, 0.4 to 0.8 s of it in the child processes. A second run on the result reads two indexes and the inputs and stops.

## 7. The living pull request

One pull request per base branch, on the fixed branch `scan-diagnostics/<base>` (D45). `Publish-RulebookScan`:

1. Clones the base branch (`New-GitHubClone`, the token in the git environment only). The plan recorded the head of its checkout (`git rev-parse HEAD`, `HeadSha`); when the clone's head differs, the base moved during the scan and the run fails (`push`, both shas named) without pushing: the next run picks it up. Then the change list is written.
2. `Publish-GitHubChange -Force`: reads the remote head of `scan-diagnostics/<base>` with `git ls-remote`, creates the branch from the base head with `checkout -B`, commits once with the title, and pushes with `--force-with-lease=refs/heads/<branch>:<head>` (an absent branch must stay absent). The lease covers only the window between `ls-remote` and the push: a push someone made in that window is rejected and the run fails (`push`); a push made earlier is replaced, which is why the body says not to push to the branch. A base that moved while the scan was planning is caught by step 1.
3. The effective diff of the commit against the base head (`Compare-RulebookEndpoints`).
4. `GET /repos/{r}/pulls?state=open&head=<owner>:scan-diagnostics/<base>&base=<base>`: an open pull request gets its title and body replaced (`PATCH /repos/{r}/pulls/{n}`, result `pull-request-updated`), else one is opened with `commitOptions.pullRequestLabels` (`pull-request`). A failure after the push names the pushed branch and its tree link (`pull-request`).

**A stale pull request is closed.** When the base already holds the result (`no-changes`) or the result went in as a direct commit, an open pull request from `scan-diagnostics/<base>` is closed (`PATCH` with `state: closed`) and its body starts with `Closed by the scan of <date>: the base branch <base> already contains its result.` or `... its result is on <base> already (direct commit <sha7>).`; the run annotates `Pull request closed: <url>` and sets the `pullRequestUrl` output to it.

There is no title guard: the branch, not the title, identifies the pull request. A new package version with no new id and no default change still produces it (a record run), because `lastSeenVersion` and the scan state move.

**Direct commit.** With `directCommit` (or on a schedule with `commitOptions.createPullRequest: false`) the commit goes to the base branch; a refused push (branch protection) falls back to the scan branch and the pull request. The summary goes to the job summary only.

**Title.** `Scan diagnostics: <parts> (<label> <version>, ...)`, the parts in this order and only when not zero: `3 new ids quarantined` (`1 new id quarantined`), `2 new ids recorded` (new ids no policy stage took), `2 ids promoted to stable`, `1 default changed`, `1 quarantine entry released`; the newly scanned versions follow with the labels `alcops` and `tools`, ALCops first. A run with no part: `Scan diagnostics: alcops 1.3.2 recorded, no new diagnostics` (`alcops 1.3.2 and tools 30.0.42.60748-beta recorded, ...`). Housekeeping: `Scan diagnostics: 1 quarantine entry released, no new package version`. Prerelease default changes and unadvertised ids do not count.

## 8. Pull request body and job summary

`ConvertTo-ScanPullRequestBody`, sections in order, each only with content (Changes and Effective diff always):

1. The intro: date, base and its sha, the scanned versions, and that the branch is rebuilt on every run.
2. `## Scanned versions`: `| Package | Channel | Version | Previously recorded | Ids | New | Changed defaults |`.
3. `## New diagnostics`: `| Id | Analyzer | Default | Title | Docs | Seen in | Quarantined in |` (a newly advertised id says `now advertised` in `Seen in`; a title is written with a zero-width space after every `@` so it mentions nobody, and the docs link as `[docs](<url>)`); `Quarantined in` is the stages, or `nowhere (not advertised)`, `nowhere (policy [])`, `nowhere (a level file mentions it)`.
4. `## Promoted to stable`.
5. `## Changed defaults`: `| Id | Field | From | To | Version | Effect |`, the effect from the effective diff (`now listed at Info in strict.ci; now unlisted in strict.default`): endpoints list only deviations (D22), so a moved default can add or remove an id from an endpoint.
6. `## Prerelease default changes (not applied)`.
7. `## Released from quarantine`: `| Stage | Id | Mentioned by |`.
8. `## Catalog notes`: unadvertised ids (new and known), deprecated ids, vanished ids, the number of seeded ids that got package fields, the refreshed titles and docs links, descriptor conflicts, unknown prefixes, static descriptor members that could not be read, skipped index entries and versions, ids no package carries.
9. `## Changes`: `| File | Change |`.
10. `## Effective diff`: one table per endpoint (`Get-EffectiveDiffBlock` of `Rulebook.Update`).
11. `## Validation warnings`.

Above 60000 characters (GitHub allows 65536) the effective diff tables go first, from the end, then the New diagnostics rows beyond 200, each with an italic line; only then is the body cut at a line boundary. The job summary `## Diagnostic scan` has the same sections without a limit, the newest NuGet versions, the result line and the validation errors, capped at 900 KiB.

## 9. Action reference

`actions/ScanDiagnostics/action.yaml`, a composite action; inputs reach the script through `INPUT_*` environment variables only.

| Input | Default | Meaning |
|---|---|---|
| `token` | `''` | The GHTOKENWORKFLOW value; needed unless `dryRun`. |
| `includePrerelease` | `'true'` | Scan the prerelease channel when it is newer than the stable one. |
| `directCommit` | `'false'` | Push to the base branch instead of the pull request. |
| `dryRun` | `'false'` | Build and validate without a token, push nothing, keep the candidate. |
| `baseBranch` | `${{ github.ref_name }}` | The branch the scan starts from. |
| `repositoryRoot` | `'.'` | The rulebook folder. |
| `actor` | `${{ github.actor }}` | The commit author name. |
| `packageSource` | `''` | A flat container (URL or folder) instead of nuget.org. |

| Output | Values |
|---|---|
| `result` | `pull-request`, `pull-request-updated`, `direct-commit`, `no-changes`, `nothing-new`, `dry-run`; empty on failure |
| `newIds`, `quarantined`, `changedDefaults`, `released` | counts |
| `scannedVersions` | `<package>@<version>:<channel>`, comma separated |
| `pullRequestUrl` | the new or updated pull request, or the one closed as stale |
| `candidatePath`, `elapsedSeconds` | |
| `failure` | `policy`, `token`, `nuget`, `extract`, `validation`, `push`, `pull-request`, `error` |

The template workflow `ScanDiagnostics.yaml`: dispatch inputs `includePrerelease` (default true) and `directCommit` (default false), `schedule:` as the last key under `on:` (written by the update from `scan.schedule`), permissions `contents: read` and `actions: read` (the writes use the secret's token, so the pull request runs Validate), concurrency `scan-diagnostics-${{ github.ref }}` without cancel, the settings step of the update workflow, and `uses: ALCops/rulebook-engine/actions/ScanDiagnostics@main`.

## 10. Engine proof

- **Stub packages.** `tests/fixtures/stub-analyzers/` holds C# stubs of the compiler (the `ErrorCode` enum, `DiagnosticDescriptor`, `DiagnosticAnalyzer` with `ImmutableArray<DiagnosticDescriptor> SupportedDiagnostics`) and of the twelve cop assemblies, in the variants tools 18.0.43.1464 and 30.0.42.60748-beta and ALCops 1.3.1 (LC0015 Info), 1.4.0-beta.1 and 1.4.0 (LC0015 Warning, LC0100 new). `Build-StubPackage.ps1` compiles them at test time with the Roslyn compiler that ships with pwsh (the one `Add-Type` uses, called directly because `Add-Type -OutputAssembly` gives the assembly a random name and the cops must reference the compiler stub by its real name), lays them out like the real packages and zips them into a flat container; `tests/Helpers/StubFeed.ps1` caches the builds per source hash. *Observed* on Windows (pwsh 7.6.6, .NET 10.0.12) and Ubuntu under WSL (pwsh 7.6.3, .NET 10.0.10).
- **Suites.** `Rulebook.NuGet`, `Rulebook.Extract`, `Rulebook.Catalog`, `Rulebook.Quarantine`, `Rulebook.Scan` (the plan against the stub feeds on `valid-minimal`: first run, nothing-new, promotion and the LC0015 default change of AC8, housekeeping, `-IncludePrerelease $false`, extraction and NuGet failures, C7 escalation; `Publish-RulebookScan` against a bare repository), `Rulebook.GitHub` (PATCH, the head lookup, the lease push and its rejection by a real concurrent push from a `pre-push` hook) and `ScanDiagnostics.Action`.
- **CI job `scan-action`** (`ubuntu-latest`, real nuget.org, dry runs only): the template without a policy fails with `failure=policy`; the template with a policy scans both stable versions, gives at least 600 catalog entries a package, a valid scan state and a candidate without errors, and prints the new ids, the refreshed texts and the ids without a package; `tests/fixtures/repos/scan-org` (30 catalog ids) quarantines at least 500 new ids in `default` and `ci` and leaves `vnext` alone; a second run on the template result is `nothing-new` in under a minute.

## 11. Live run

The live end-to-end run on a scratch repository created from `template/` records its run ids and pull request links here (policy failure, first scan with three removed seed ids, PATCH of the same pull request, nothing-new after the merge, housekeeping after an adoption, a new stage, direct commit, `includePrerelease: false`, token failure). AC3 (a prerelease id promoted to stable) and AC8 (a changed default) cannot be steered on nuget.org; the stub variants prove them (section 10).
