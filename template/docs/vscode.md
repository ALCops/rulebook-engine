# VS Code

How the AL Language extension in VS Code uses your rulebook: the workspace settings, workspaces whose folder is not the app, when the editor reads the ruleset again, and how `suppressWarnings` fits in.

> **Status:** written 2026-10-10 with WP11 of the engine ([#13](https://github.com/ALCops/rulebook-engine/issues/13)). The re-read triggers were observed in the engine's [spike (e)](https://github.com/ALCops/rulebook-engine/blob/main/docs/reference/spikes/e-vscode-refetch.md) (AL extension 18.0.2819426, VS Code 1.140.0) and the settings in the WP06 live run ([rulebook-engine#60](https://github.com/ALCops/rulebook-engine/pull/60)); the setting names are Microsoft Learn's [AL Language extension configuration](https://learn.microsoft.com/dynamics365/business-central/dev-itpro/developer/devenv-al-extension-configuration). The project-side facts are in [al-project.md](al-project.md).

## Contents

1. [What you need](#1-what-you-need)
2. [Workspace settings](#2-workspace-settings)
3. [When the workspace folder is not the app](#3-when-the-workspace-folder-is-not-the-app)
4. [When VS Code reads the ruleset again](#4-when-vs-code-reads-the-ruleset-again)
5. [Seeing the effective rules](#5-seeing-the-effective-rules)
6. [suppressWarnings](#6-suppresswarnings)
7. [Check that it works](#7-check-that-it-works)
8. [Troubleshooting](#8-troubleshooting)

## 1. What you need

- Your published rulebook: `<baseUrl>/` opens the index page ([getting-started.md](getting-started.md)).
- The skeletons next to `app.json`, downloaded with the init script: `.rulebook/default.ruleset.json` is the one VS Code uses ([al-project.md](al-project.md) section 3).

## 2. Workspace settings

In `.vscode/settings.json` of the workspace folder:

```json
{
  "al.ruleSetPath": ".rulebook/default.ruleset.json",
  "al.enableCodeAnalysis": true,
  "al.codeAnalyzers": ["${CodeCop}", "${UICop}", "${PerTenantExtensionCop}"],
  "al.enableExternalRulesets": true
}
```

| Setting | Value | Microsoft Learn |
|---|---|---|
| `al.ruleSetPath` | The `default` skeleton, relative to the workspace folder. Pointing it straight at the endpoint URL works too, but then the project has no file for its own exceptions ([al-project.md](al-project.md) section 3). | [Rule Set Path](https://learn.microsoft.com/dynamics365/business-central/dev-itpro/developer/devenv-al-extension-configuration), [ruleset syntax](https://learn.microsoft.com/dynamics365/business-central/dev-itpro/developer/devenv-rule-set-syntax-for-code-analysis-tools) |
| `al.enableCodeAnalysis` | `true`. The default is `false`: without it no analyzer runs and the ruleset changes nothing. | [Enable Code Analysis](https://learn.microsoft.com/dynamics365/business-central/dev-itpro/developer/devenv-al-extension-configuration) |
| `al.codeAnalyzers` | The analyzers to run: `${CodeCop}`, `${UICop}`, `${PerTenantExtensionCop}` or `${AppSourceCop}`, and the paths of other analyzer DLLs such as ALCops. A rule of an analyzer that does not run never fires. Which of the two Microsoft cops to run: [pte-or-appsource.md](pte-or-appsource.md). | [Code Analyzers](https://learn.microsoft.com/dynamics365/business-central/dev-itpro/developer/devenv-al-extension-configuration) |
| `al.enableExternalRulesets` | `true`; keep it. Learn states no default; the extension's source defaults it to `true`. Set to `false`, the URL include of the skeleton fails with AL1033 and the editor falls back to the analyzer defaults (section 8). | [Enable External Rulesets](https://learn.microsoft.com/dynamics365/business-central/dev-itpro/developer/devenv-al-extension-configuration) |

## 3. When the workspace folder is not the app

`al.ruleSetPath` is resolved against the **workspace folder**, which is not always the folder with `app.json`. When you open the repository root and the app is in `MyApp/`, prefix the path with the app folder:

```json
{ "al.ruleSetPath": "MyApp/.rulebook/default.ruleset.json" }
```

In a multi-root workspace (a `.code-workspace` file with one folder per app), each app folder is a workspace folder, so the plain `.rulebook/default.ruleset.json` in each app folder's own `.vscode/settings.json` should resolve per app; this layout was not tested. The init script prints paths relative to the folder it ran in ([al-project.md](al-project.md) section 4).

## 4. When VS Code reads the ruleset again

VS Code does not notice by itself that your rulebook changed, and shows no hint that it did; Microsoft Learn says the same and advises reloading the window ([using the code analysis tool with a ruleset](https://learn.microsoft.com/dynamics365/business-central/dev-itpro/developer/devenv-using-code-analysis-tool-with-rule-set)). It reads the ruleset again on:

| Trigger | Reads again |
|---|---|
| **Developer: Reload Window** | yes |
| A change to `app.json`, saved in the editor | yes, at once |
| A saved change to `al.ruleSetPath` or `al.enableCodeAnalysis` (other `al.*` settings not tested) | yes |
| Closing and reopening the folder | yes |
| Saving an `.al` file | no |
| A change to a setting outside `al.*` | no |
| **AL: Download symbols** | no |

**The rule:** after your rulebook changes, run **Developer: Reload Window** (or save a change to `app.json`). Allow up to 10 minutes after a publish for the cache of GitHub Pages (5 minutes on `raw.githubusercontent.com`) before you reload ([hosting.md](hosting.md) section 2). After an edit to your own `.rulebook` file, reload too: whether a plain save of the local file is picked up was not tested ([al-project.md](al-project.md) section 8).

## 5. Seeing the effective rules

There is no command that prints the ruleset VS Code applies. Two ways to tell:

- **A known id.** Write code that breaks a rule your endpoint lists at another action than the analyzer default and look at the Problems pane (section 7).
- **AL1033 on `app.json`.** When the Problems pane shows AL1033 on `app.json` and every rule is at its analyzer default, the endpoint did not load: VS Code goes on with the defaults, so every `None` of your level, every lowered rule and every organization override is lost until it loads again ([al-project.md](al-project.md) section 7).

## 6. suppressWarnings

`suppressWarnings` in `app.json` switches off only the ids your endpoint does not list, Errors included; an id the endpoint lists keeps its action, without any message. For a listed id, use an exception in the `rules` of `.rulebook/default.ruleset.json` and the other stage files ([al-project.md](al-project.md) sections 5 and 6).

After you edit `suppressWarnings`, save `app.json` in the editor; if the Problems pane does not change, run **Developer: Reload Window** (a file replaced on disk by another tool sends no save to the extension).

## 7. Check that it works

1. Pick a probe from `<baseUrl>/rulesets/<level>.ruleset.json` (the `default` stage). On Strict and Complete, `AA0247` ("Use namespaces", CodeCop, default Info) is listed at `Warning`; on Essential, `AA0137` (an unused variable, default Warning) is listed at `None`. On Recommended, or a level of your own, neither may be listed: add a temporary exception `{ "id": "AA0137", "action": "None" }` to the `rules` of `.rulebook/default.ruleset.json` instead, which proves that the file is applied (and no AL1033 on `app.json` proves that its include loaded).
2. Add code that breaks it: for `AA0247` a codeunit without a `namespace` line (AA0247 needs only `System.app` among the symbols); for `AA0137` a local variable that is never used.
3. Run **Developer: Reload Window**. Expect the Problems pane to show `AA0247` as a **Warning** (without the ruleset it is Information), or no `AA0137` (without the ruleset it is a Warning).

Remove the probe afterwards. Observed in the WP06 live run with `strict`: AA0247 went from Information to Warning after the reload ([rulebook-engine#60](https://github.com/ALCops/rulebook-engine/pull/60)).

## 8. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| AL1033 on `app.json`, and the rules at their default severities | The endpoint could not be loaded: the URL in the skeleton is wrong, the site is down, `al.enableExternalRulesets` is `false`, or the file is not valid JSON. | Open the include URL of `.rulebook/default.ruleset.json` in a browser; set `al.enableExternalRulesets` to `true`; check the Publish run of your rulebook. |
| A change to the rulebook does not show | The cache of the site still serves the old endpoint, or VS Code has not read the ruleset again. | Wait up to 10 minutes after the publish, then **Developer: Reload Window** (section 4). |
| An edit to `suppressWarnings` has no effect | The id is listed by the endpoint, or `app.json` was changed outside the editor. | Use an exception in `rules` for a listed id; save `app.json` in the editor or reload (section 6). |
| No analyzer diagnostics at all | `al.enableCodeAnalysis` is `false` (the default), or `al.codeAnalyzers` is empty. | Set both (section 2). |
| The ruleset seems ignored when the repository root is open | `al.ruleSetPath` is resolved against the workspace folder, not the app. | Prefix the app folder (section 3). |
| "Array has too few items. Expected 1 or more." on `"rules": []` | The extension's JSON schema for ruleset files wants at least one rule. | Harmless: the compiler accepts an empty `rules` array ([al-project.md](al-project.md) section 9). |
