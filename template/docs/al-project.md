# Rulebook in an AL project

How an AL project uses your rulebook: which files it keeps, how VS Code and the pipelines point at them, where project exceptions go, when `suppressWarnings` in `app.json` works, and what happens when the endpoint cannot be read.

> **Status:** written with WP06 of the engine ([#8](https://github.com/ALCops/rulebook-engine/issues/8)). This page states the facts, with their sources; it is not a walkthrough. The walkthroughs [vscode.md](vscode.md), [al-go.md](al-go.md) and [azure-devops.md](azure-devops.md) build on it (WP11). The design behind it is the engine's [ARCHITECTURE.md section 6.3](https://github.com/ALCops/rulebook-engine/blob/main/docs/ARCHITECTURE.md#63-skeletons-r3).

## Contents

1. [Layout](#1-layout)
2. [Why one file per stage](#2-why-one-file-per-stage)
3. [Getting the files](#3-getting-the-files)
4. [Settings per consumer](#4-settings-per-consumer)
5. [Exceptions](#5-exceptions)
6. [Exactly when suppressWarnings works](#6-exactly-when-suppresswarnings-works)
7. [When the endpoint fails (AL1033)](#7-when-the-endpoint-fails-al1033)
8. [Seeing changes in VS Code](#8-seeing-changes-in-vs-code)
9. [Troubleshooting](#9-troubleshooting)
10. [References](#10-references)

## 1. Layout

An AL project keeps one small ruleset file per stage of your rulebook in a folder `.rulebook/` next to `app.json`, named after the stage (the VS Code setting resolves the path against the workspace folder, section 4). For a project on the `strict` level with the shipped stages:

```
.rulebook/default.ruleset.json   includes <baseUrl>/rulesets/strict.ruleset.json
.rulebook/ci.ruleset.json        includes <baseUrl>/rulesets/strict.ci.ruleset.json
.rulebook/vnext.ruleset.json     includes <baseUrl>/rulesets/strict.vnext.ruleset.json
```

Each file is a published skeleton: one include of the endpoint of its level and stage, and the project's own exceptions in `rules`. An organization that adds or removes stages gets one file per stage it publishes. The folder name `.rulebook/` and the file names, `default` included, come from the engine's [naming.md](https://github.com/ALCops/rulebook-engine/blob/main/docs/reference/naming.md); one file per stage is decision [D28](https://github.com/ALCops/rulebook-engine/blob/main/docs/adr/0028-identity-is-one-name-the-slug-names-every-file-url-selector.md) (open question O6, closed by it).

A `.rulebook/ci.ruleset.json` with two exceptions:

```json
{
  "name": "Rulebook Strict / CI",
  "description": "Copy into your AL project and point al.ruleSetPath or the AL-Go rulesetFile at it. Add project exceptions to rules; they override the endpoint.",
  "includedRuleSets": [
    { "action": "Default", "path": "https://contoso.github.io/rulebook/rulesets/strict.ci.ruleset.json" }
  ],
  "rules": [
    { "id": "LC0015", "action": "None", "justification": "Legacy table pattern, tracked in issue 42" },
    { "id": "AS0084", "action": "None", "justification": "Per-tenant extension: id range 50000..99999 is intentional" }
  ]
}
```

## 2. Why one file per stage

- **Each stage points at a different endpoint.** VS Code uses the `default` stage, pull request builds `ci`, next-major builds `vnext`, so each consumer needs a root file that includes its own endpoint.
- **An exception has to sit in the file the compiler is pointed at.** A ruleset file's own `rules` beat the rules of the files it includes; an include cannot lower what its parent sets ([compiler-ruleset-internals.md section 4](https://github.com/ALCops/rulebook-engine/blob/main/docs/reference/compiler-ruleset-internals.md#4-merge-algorithm)). So the exception goes into the root, and every stage has its own root.
- **The exception list is repeated per stage.** An exception that applies everywhere is written in each of the files. That is deliberate.
- **Rejected: one file plus a pipeline step that rewrites its include per stage.** A rewrite that fails silently leaves the default stage's ruleset in place, and nothing would notice.
- **One HTTP request per compile.** The endpoint is flat and has no includes of its own, so the skeleton's include is the only fetch ([compiler-ruleset-internals.md section 6](https://github.com/ALCops/rulebook-engine/blob/main/docs/reference/compiler-ruleset-internals.md#6-paths-and-urls); measured in [spike (a)](https://github.com/ALCops/rulebook-engine/blob/main/docs/reference/spikes/a-hosts-and-skeleton-include.md)).

## 3. Getting the files

**The init script** downloads the published skeletons of one level into `.rulebook/`, one per stage. It needs PowerShell 7. Run it from the AL project root, the folder with `app.json`:

```powershell
Invoke-WebRequest https://raw.githubusercontent.com/ALCops/rulebook-engine/main/scripts/Get-RulebookSkeletons.ps1 -OutFile Get-RulebookSkeletons.ps1
./Get-RulebookSkeletons.ps1 -BaseUrl https://contoso.github.io/rulebook -Level strict
```

The script is a one-off helper: delete it afterwards, or download it to a temporary folder and pass the project folder with `-OutputPath`. Once the engine's `v1` branch exists (WP13), use the `v1` URL instead of `main`.

| Parameter | Meaning |
|---|---|
| `-BaseUrl` | The address of your published site, the `baseUrl` of your rulebook repository. https; http only for a site served on the local machine. |
| `-Level` | The level by its slug (`strict`) or its name (`Strict`). |
| `-OutputPath` | The folder for the files, default `.rulebook`. |
| `-Force` | Overwrite existing files. |

What it does and refuses:

- It reads `<baseUrl>/rulebook.json`, the list of levels and stages your site publishes, and stops with the published list when the level is not one of them, before it downloads a skeleton.
- It stops when one of the files exists already, unless you pass `-Force`. A downloaded skeleton has an empty `rules` array, so copy your exceptions first.
- It follows no redirect: `-BaseUrl` must be the final address of the site. The compiler fetches an include with one request ([compiler-ruleset-internals.md section 6](https://github.com/ALCops/rulebook-engine/blob/main/docs/reference/compiler-ruleset-internals.md#6-paths-and-urls)), and the engine treats a redirect as a failure for that reason (code-derived; a redirecting site was not tried with the compiler).
- It checks every skeleton (one include, the endpoint of its level and stage) and writes nothing until all downloads and checks have passed. The files are written exactly as the site serves them, so they are the same files a manual download gives.
- It prints the settings for VS Code and AL-Go and never changes a settings file.

The script lives in the engine and is served from its `main` branch until the `v1` release branch exists (then `.../rulebook-engine/v1/scripts/...`, [#15](https://github.com/ALCops/rulebook-engine/issues/15)). The index page of your site at `<baseUrl>/` shows the same two commands.

**By hand.** Download `<baseUrl>/skeletons/<level>.<stage>.ruleset.json` for each stage, linked from the index page, and save it as `.rulebook/<stage>.ruleset.json`. Take the files from the published site, never from the `skeletons/` folder of your rulebook repository: the repository copies keep the placeholder `{BASEURL}`, which the compiler cannot fetch.

**No local files.** Point the setting straight at the endpoint URL, for example `"al.ruleSetPath": "https://contoso.github.io/rulebook/rulesets/strict.ruleset.json"`. Nothing to maintain in the project, but project exceptions are then impossible: there is no file of your own to put them in.

## 4. Settings per consumer

| Consumer | Setting | Value |
|---|---|---|
| VS Code | `al.ruleSetPath` in `.vscode/settings.json` | `.rulebook/default.ruleset.json` (relative to the workspace folder) |
| VS Code | `al.enableExternalRulesets` | default `true`; leave it |
| AL-Go for GitHub | `rulesetFile` in `.AL-Go/settings.json` | the `ci` file, relative to the AL-Go project folder: `MyApp/.rulebook/ci.ruleset.json` (see the note below) |
| AL-Go for GitHub | `enableExternalRulesets` | `true` |
| AL-Go, next major | `rulesetFile` in `.github/Test Next Major.settings.json` | the `vnext` file, relative to the AL-Go project folder: `MyApp/.rulebook/vnext.ruleset.json` (see the note below) |
| `alc` | `/ruleset:<path>` and `/enableexternalrulesets` | the file of the stage; external rulesets are **off** by default on `alc` |

The VS Code row was observed in the WP06 live run: `.rulebook/default.ruleset.json` relative to the workspace folder. When the workspace folder is not the project folder (the repository root opened in VS Code, the app in `app/`), prefix the path with the project folder: `app/.rulebook/default.ruleset.json`. The init script prints paths relative to the folder it runs in. In AL-Go a relative `rulesetFile` is resolved against the AL-Go project folder (the folder with `.AL-Go/settings.json`, the repository root in a single-project repository), not the app folder, and the next-major workflow reads `.github/Test Next Major.settings.json` (from its workflow name); both are taken from the AL-Go source, see [al-go.md](al-go.md) sections 3 and 4.

Sources: [compiler-ruleset-internals.md section 9](https://github.com/ALCops/rulebook-engine/blob/main/docs/reference/compiler-ruleset-internals.md#9-consumer-flags), the [AL-Go settings](https://github.com/microsoft/AL-Go/blob/main/Scenarios/settings.md) and Microsoft Learn's [AL extension configuration](https://learn.microsoft.com/dynamics365/business-central/dev-itpro/developer/devenv-al-extension-configuration).

## 5. Exceptions

An exception is an entry in `rules` of the stage's file:

```json
{ "id": "LC0015", "action": "None", "justification": "Legacy table pattern, tracked in issue 42" }
```

- `id` is the diagnostic id, `action` one of `Error`, `Warning`, `Info`, `Hidden` or `None`, `justification` free text. The compiler ignores `justification`; write one anyway, so the next reader knows why.
- The file's own `rules` override the endpoint in both directions: lower a rule the endpoint sets to `Warning`, or raise one.
- Repeat the exception in the file of every stage it applies to (section 2).
- An invalid `action` in the file, `Default` in `rules` or a typo, makes the whole ruleset fail to load: AL1033, your exceptions included (code-derived, [compiler-ruleset-internals.md sections 2 and 7](https://github.com/ALCops/rulebook-engine/blob/main/docs/reference/compiler-ruleset-internals.md#2-schema-as-the-code-accepts-it)).
- A list that grows, or the same exception in many projects, is a signal for a change for the whole organization instead: an entry in `overrides.json` of your rulebook repository, written with the Change Rule workflow ([changing-a-rule.md](changing-a-rule.md)).

## 6. Exactly when suppressWarnings works

`suppressWarnings` in `app.json` is merged after the ruleset, with strictest-wins semantics ([compiler-ruleset-internals.md section 8](https://github.com/ALCops/rulebook-engine/blob/main/docs/reference/compiler-ruleset-internals.md#8-how-the-ruleset-combines-with-other-inputs)). Because `None` is never the strictest, it cannot change an id the ruleset already sets:

- **It works for every id the endpoint does not list.** Endpoints are sparse: they list only the ids whose action differs from the analyzer default ([D22](https://github.com/ALCops/rulebook-engine/blob/main/docs/adr/0022-sparse-endpoints-an-id-at-its-analyzer-default-is-not-listed.md)), so every analyzer diagnostic at its analyzer default can be suppressed this way, Errors included. Compiler errors (AL####) cannot be suppressed ([compiler-ruleset-internals.md section 8](https://github.com/ALCops/rulebook-engine/blob/main/docs/reference/compiler-ruleset-internals.md#8-how-the-ruleset-combines-with-other-inputs), [route B](pte-or-appsource.md#4-route-b-suppresswarnings-in-appjson)).
- **It is a silent no-op for an id the endpoint lists**, at any action, Info included. The same holds when your own `.rulebook` file lists the id. Use an exception in `rules` (section 5) for those.
- On the `alc` command line, `/nowarn:<id>` is the only switch that beats a listed id; in a ruleset, an exception in the stage file's own `rules` does (section 5).

Observed: [spike (f)](https://github.com/ALCops/rulebook-engine/blob/main/docs/reference/spikes/f-suppresswarnings-sparse-endpoint.md) removed the unlisted AppSourceCop Errors AS0084 and AS0013 with `suppressWarnings`; a listed id kept its ruleset action, at Error, Warning and Info on `alc`, and at Warning in VS Code after Reload Window (internals section 8 lists it per host). The same again in the WP06 live run ([rulebook-engine#60](https://github.com/ALCops/rulebook-engine/pull/60)): with `suppressWarnings: ["AA0247", "AA0137"]`, the unlisted AA0137 disappeared and AA0247, listed at Warning by `strict`, stayed. A change to `suppressWarnings` takes effect when `app.json` is saved in the editor, or after a window reload ([spike (e)](https://github.com/ALCops/rulebook-engine/blob/main/docs/reference/spikes/e-vscode-refetch.md)).

Which per-tenant or AppSource rules to suppress, and the ready-made lists: [pte-or-appsource.md](pte-or-appsource.md), [route B](pte-or-appsource.md#4-route-b-suppresswarnings-in-appjson), [route C](pte-or-appsource.md#5-route-c-a-project-ruleset-file) and [the lists](pte-or-appsource.md#6-ready-made-lists).

## 7. When the endpoint fails (AL1033)

When the compiler cannot use the endpoint (unreachable host, HTTP error, invalid JSON), it discards the **whole** ruleset, your exceptions included, and reports **AL1033** ([compiler-ruleset-internals.md section 7](https://github.com/ALCops/rulebook-engine/blob/main/docs/reference/compiler-ruleset-internals.md#7-failure-model)). Two more cases are code-derived and were not observed: a fetch that takes longer than the 15 second `HttpClient` timeout ([internals section 6](https://github.com/ALCops/rulebook-engine/blob/main/docs/reference/compiler-ruleset-internals.md#6-paths-and-urls)), and a redirect. The engine's reachability check treats a 3xx as a failure because the compiler's fetch is one request with no redirect (spike (a) saw no redirect on either host); a redirecting site was not tried, and the init script refuses a redirecting `baseUrl` for that reason.

- **`alc` stops**: no compilation, no `.app`, exit code 1, observed for a 404, an invalid file and a host that does not resolve ([spike (a)](https://github.com/ALCops/rulebook-engine/blob/main/docs/reference/spikes/a-hosts-and-skeleton-include.md), [spike (c)](https://github.com/ALCops/rulebook-engine/blob/main/docs/reference/spikes/c-alc-on-ubuntu.md)); for a timeout it was not observed.
- **VS Code goes on** with the analyzer defaults and shows AL1033 on `app.json` ([spike (e)](https://github.com/ALCops/rulebook-engine/blob/main/docs/reference/spikes/e-vscode-refetch.md)). Every `None` of your level, every lowered rule and every organization override is lost until the endpoint loads again. Observed in the WP06 live run: with a broken include, AL1033 appeared on `app.json` and AA0247 fell back from Warning to its default Information ([rulebook-engine#60](https://github.com/ALCops/rulebook-engine/pull/60)).
- **External rulesets off**: AL0767 when the setting is a URL, AL1033 when a local file includes one; `alc` stops in both cases. Set `al.enableExternalRulesets`, `enableExternalRulesets` or `/enableexternalrulesets` (section 4).

A pipeline should treat AL1033 as a failure, so a build never passes on the analyzer defaults by accident. The Publish workflow of your rulebook checks every published URL after each deploy, so a broken publish shows up there first ([ARCHITECTURE.md section 10](https://github.com/ALCops/rulebook-engine/blob/main/docs/ARCHITECTURE.md#10-failure-model-and-operational-risks)).

## 8. Seeing changes in VS Code

VS Code does not re-fetch a ruleset by itself and shows no hint that it changed. It reads the ruleset again after **Developer: Reload Window**, after a change to `app.json` saved in the editor, after a saved change to `al.ruleSetPath` or `al.enableCodeAnalysis`, or when the folder is reopened ([spike (e)](https://github.com/ALCops/rulebook-engine/blob/main/docs/reference/spikes/e-vscode-refetch.md)). After an edit to your own `.rulebook` file, use **Reload Window**: the live run reloaded after every edit, and whether a plain save of the local file is picked up was not tested (the extension does not watch ruleset files, [internals section 9](https://github.com/ALCops/rulebook-engine/blob/main/docs/reference/compiler-ruleset-internals.md#9-consumer-flags)). After a publish of your rulebook, allow up to 10 minutes for the GitHub Pages cache ([hosting.md](hosting.md#how-fast-changes-arrive)).

## 9. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| AL1033 on `app.json`, rules at their default severities | The endpoint could not be loaded: URL wrong, site down, external rulesets off, or a file that is not valid JSON. | Open the include URL in a browser; check `baseUrl` and the Publish run of your rulebook; check the external rulesets setting (section 4). |
| A rule is still reported after adding it to `suppressWarnings` | The endpoint lists the id (section 6). | Add an exception to `rules` of the stage's file. |
| An exception has no effect | It is in another stage's file, or VS Code has not re-read the file. | Put it in the file the consumer points at (section 4), then Reload Window. |
| `{BASEURL}` appears in the include path | The file came from the `skeletons/` folder of the repository, not from the published site. | Download it again from `<baseUrl>/skeletons/` or with the init script. |
| VS Code shows "Array has too few items. Expected 1 or more." on `"rules": []` | The AL extension's JSON schema for `*.ruleset.json` asks for at least one rule. Observed in the WP06 live run. | Harmless: the compiler accepts an empty `rules` array. Add your first exception, or ignore the warning. |
| The init script stops with "is not published" | The level is not in your rulebook, or it is spelled differently. | Use one of the levels the message lists. |
| The init script says `rulebook.json` is missing | The site was published before rulebook.json existed, or `-BaseUrl` is wrong. | Check `-BaseUrl`; run the Publish workflow of your rulebook once. |

## 10. References

- Engine design: [ARCHITECTURE.md section 6.3](https://github.com/ALCops/rulebook-engine/blob/main/docs/ARCHITECTURE.md#63-skeletons-r3) and [compiler-ruleset-internals.md](https://github.com/ALCops/rulebook-engine/blob/main/docs/reference/compiler-ruleset-internals.md).
- Spikes: [(a) hosts and the skeleton include](https://github.com/ALCops/rulebook-engine/blob/main/docs/reference/spikes/a-hosts-and-skeleton-include.md), [(e) VS Code re-fetch](https://github.com/ALCops/rulebook-engine/blob/main/docs/reference/spikes/e-vscode-refetch.md), [(f) suppressWarnings against a sparse endpoint](https://github.com/ALCops/rulebook-engine/blob/main/docs/reference/spikes/f-suppresswarnings-sparse-endpoint.md).
- The WP06 live run: [rulebook-engine#60](https://github.com/ALCops/rulebook-engine/pull/60) and [publish-targets.md section 7](https://github.com/ALCops/rulebook-engine/blob/main/docs/reference/publish-targets.md#7-live-run-of-wp06-skeletons).
- The init script: [scripts/Get-RulebookSkeletons.ps1](https://github.com/ALCops/rulebook-engine/blob/main/scripts/Get-RulebookSkeletons.ps1).
- Microsoft Learn, AL extension configuration: https://learn.microsoft.com/dynamics365/business-central/dev-itpro/developer/devenv-al-extension-configuration
- AL-Go settings (`rulesetFile`, `enableExternalRulesets`): https://github.com/microsoft/AL-Go/blob/main/Scenarios/settings.md
