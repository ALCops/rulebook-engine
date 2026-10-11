# Azure DevOps and other pipelines

How a pipeline outside AL-Go for GitHub compiles against your rulebook: the ALOps compile task, BcContainerHelper, and a plain `alc` call. All three take the same two things: the path of the stage's skeleton file and the switch that allows its URL include.

> **Status:** written 2026-10-10 with WP11 of the engine ([#13](https://github.com/ALCops/rulebook-engine/issues/13)). The ALOps inputs are taken from the ALOps documentation of `ALOpsAppCompiler@3` (as of its revision of 2026-03-03); the sample was not run. The BcContainerHelper parameters are taken from the BcContainerHelper source (`Run-AlPipeline`, `Compile-AppInBcContainer`, `Compile-AppWithBcCompilerFolder`). The `alc` command line was observed in the engine's [spike (c)](https://github.com/ALCops/rulebook-engine/blob/main/docs/reference/spikes/c-alc-on-ubuntu.md). The project-side facts are in [al-project.md](al-project.md).

## Contents

1. [What you need](#1-what-you-need)
2. [One stage per pipeline](#2-one-stage-per-pipeline)
3. [ALOps](#3-alops)
4. [BcContainerHelper](#4-bccontainerhelper)
5. [Plain alc](#5-plain-alc)
6. [When the endpoint fails](#6-when-the-endpoint-fails)
7. [Check that it works](#7-check-that-it-works)
8. [Troubleshooting](#8-troubleshooting)

## 1. What you need

- Your published rulebook: `<baseUrl>/` opens the index page ([getting-started.md](getting-started.md)).
- The skeletons in each app: `.rulebook/default.ruleset.json`, `.rulebook/ci.ruleset.json` and `.rulebook/vnext.ruleset.json` next to `app.json`, downloaded with the init script and committed ([al-project.md](al-project.md) section 3).

The [ALCops extension for Azure DevOps](https://marketplace.visualstudio.com/items?itemName=Arthurvdv.alcops-ado) (`ALCopsDownloadAnalyzers@1`) downloads the ALCops analyzers; it has no ruleset input, so the ruleset goes into the compile step below.

## 2. One stage per pipeline

| Pipeline | Stage | File |
|---|---|---|
| Pull request and release builds | `ci` | `.rulebook/ci.ruleset.json` |
| Builds against the next major version | `vnext` | `.rulebook/vnext.ruleset.json` |
| Developers in VS Code | `default` | `.rulebook/default.ruleset.json` ([vscode.md](vscode.md)) |

Each pipeline names its file explicitly. A stage you added to your rulebook gets its own skeleton ([levels.md](levels.md) section 7).

## 3. ALOps

The ALOps compile task, `ALOpsAppCompiler@3` (inputs from the [ALOps documentation](https://github.com/HodorNV/ALOps/blob/master/mkdocs/docs/ALOpsSteps/v3/ALOpsAppCompiler_v3.md)), takes the ruleset and the external-rulesets switch as inputs. Add them to your existing compile step:

```yaml
- task: ALOpsAppCompiler@3
  displayName: 'ALOps App Compiler'
  inputs:
    compilation_mode: Serial
    alsourcepath: $(System.DefaultWorkingDirectory)/MyApp
    alcodeanalyzer: CodeCop,UICop,PTECop
    ruleset: ./.rulebook/ci.ruleset.json
    enable_external_rulesets: true
```

| Input | Value |
|---|---|
| `ruleset` | The stage's skeleton. A path that starts with `.` is resolved against `alsourcepath` (in serial mode per app, per the documentation); with several apps keep one `.rulebook/` per app and one task per app, or point `ruleset` at one shared file (not run). An `https` URL is downloaded by the task. **Set it explicitly**: when it is empty, the task takes `al.ruleSetPath` from `.vscode/settings.json`, which is the `default` stage, not `ci`. `NONE` turns rulesets off. |
| `enable_external_rulesets` | `true`: passes `/enableexternalrulesets` to the compiler, so the URL include of the skeleton loads. Default `false`. Serial mode only: in parallel mode (`compilation_mode: Parallel`) the documentation says it is silently ignored, so the include fails with AL1033 (section 6). |
| `alcodeanalyzer` | The analyzers to run in serial mode (`CodeCop`, `UICop`, `AppSourceCop`, `PTECop`, or DLL paths for others such as ALCops); a rule of an analyzer that does not run never fires. In parallel mode the input is `analyzers`. |
| `failonwarnings` | `true` fails the task on any warning, so the rules your endpoint lists at Warning fail the build too. Default `false`. |
| `suppresswarnings` | Default `KEEP` leaves `suppressWarnings` of `app.json` as it is ([al-project.md](al-project.md) section 6). |

Older versions of the task (`ALOpsAppCompiler@2`) have the same `ruleset` and `enable_external_rulesets` inputs, with `ruleset` relative to `alsourcepath` ([v2 documentation](https://github.com/HodorNV/ALOps/blob/master/mkdocs/docs/ALOpsSteps/v2/ALOpsAppCompiler_v2.md)).

## 4. BcContainerHelper

The BcContainerHelper functions take `-rulesetFile` and the switch `-enableExternalRulesets` ([BcContainerHelper](https://github.com/microsoft/navcontainerhelper)):

Only the ruleset and analyzer parameters are shown; your call keeps its other parameters (`-artifact`, credentials and so on):

```powershell
Run-AlPipeline `
    -pipelineName 'ci' `
    -baseFolder $env:BUILD_SOURCESDIRECTORY `
    -appFolders 'MyApp' `
    -enableCodeCop -enableUICop -enablePerTenantExtensionCop `
    -rulesetFile 'MyApp/.rulebook/ci.ruleset.json' `
    -enableExternalRulesets
```

| Function | `-rulesetFile` |
|---|---|
| `Run-AlPipeline` | A relative path is resolved against `-baseFolder`; an `https://` value is passed on as it is. Keep the local skeleton, so project exceptions work. |
| `Compile-AppInBcContainer` | The file must be in a folder shared with the container (it throws "The rulesetFile (...) is not shared with the container" otherwise); it is passed to the compiler as `/ruleset:`. |
| `Compile-AppWithBcCompilerFolder` | Passed to the compiler as `/ruleset:`. |

In all three, `-enableExternalRulesets` adds `/enableexternalrulesets`. The cops are separate switches (`-enableCodeCop`, `-enableUICop`, `-enableAppSourceCop`, `-enablePerTenantExtensionCop`, and `-customCodeCops` for ALCops).

## 5. Plain alc

**External rulesets are off by default on the command line, the opposite of VS Code.** Pass both switches. `$AL_BIN` is the folder of the `alc.dll` that runs; spike (c) shows how to find it ([recipe](https://github.com/ALCops/rulebook-engine/blob/main/docs/reference/spikes/c-alc-on-ubuntu.md#recipe)). The two switches belong to the compiler (`al compile` passes its arguments on to `alc`). Microsoft Learn does not list them, but documents the failure they guard against ([AL1033](https://learn.microsoft.com/dynamics365/business-central/dev-itpro/developer/diagnostics/diagnostic-al1033)); both were observed in spike (c):

```bash
al compile /project:MyApp /packagecachepath:MyApp/.alpackages /out:MyApp/out.app \
  /analyzer:$AL_BIN/Microsoft.Dynamics.Nav.CodeCop.dll \
  /analyzer:$AL_BIN/Microsoft.Dynamics.Nav.UICop.dll \
  /analyzer:$AL_BIN/Microsoft.Dynamics.Nav.PerTenantExtensionCop.dll \
  /ruleset:MyApp/.rulebook/ci.ruleset.json \
  /enableexternalrulesets
```

- `/ruleset:<path>` takes the stage's skeleton; a relative path is resolved against the current folder.
- `/enableexternalrulesets` allows the URL include. Without it a local skeleton fails with AL1033, and a URL as the `/ruleset:` value fails with AL0767.
- `al` is the `Microsoft.Dynamics.BusinessCentral.Development.Tools` dotnet tool; `dotnet <folder>/alc.dll` with the same switches gives the same result.
- `$AL_BIN` must be the folder of the `alc.dll` that runs. Analyzer DLLs from another target-framework folder load with **AL1003** ("An instance of analyzer ... cannot be created") for every rule, the compile still exits 0 and no analyzer diagnostic appears. Fail the build when the log contains `AL1003` (spike (c)).
- `/warnaserror` and `/nowarn:<id>` apply after the ruleset; `/nowarn:<id>` is the only switch that beats an id the endpoint lists ([al-project.md](al-project.md) section 6).

## 6. When the endpoint fails

When the compiler cannot load the endpoint (wrong URL, site down, external rulesets off, invalid JSON), it reports **AL1033** ("An error occurred while loading the included rule set file ...") and drops the whole ruleset. On the command line it does not go on with the analyzer defaults: `alc` prints the one error, writes no `.app` and exits 1, also when the failing URL is the include of a local skeleton (observed in [spike (a)](https://github.com/ALCops/rulebook-engine/blob/main/docs/reference/spikes/a-hosts-and-skeleton-include.md) and [spike (c)](https://github.com/ALCops/rulebook-engine/blob/main/docs/reference/spikes/c-alc-on-ubuntu.md)). So a pipeline that fails on a compiler error fails on AL1033 by itself; ALOps and BcContainerHelper run the same compiler (not observed with them).

## 7. Check that it works

An endpoint lists only the rules whose action differs from the analyzer default, so a listed rule shows whether the ruleset reached the compiler.

1. Pick a probe. On Strict and Complete, `AA0247` ("Use namespaces", CodeCop, default Info) is listed at `Warning` in `<baseUrl>/rulesets/<level>.ci.ruleset.json`; on Essential, `AA0137` (an unused variable, default Warning) is listed at `None`. On Recommended, or a level of your own, neither may be listed: add a temporary exception `{ "id": "AA0137", "action": "None" }` to the `rules` of `.rulebook/ci.ruleset.json` instead, which proves that the file is applied (and no AL1033 proves that its include loaded).
2. On a branch, add code that breaks it: for `AA0247` a codeunit without a `namespace` line; for `AA0137` a local variable that is never used. Run the pull request build.
3. Expect the compile log to report `AA0247` as a warning for that codeunit (without the ruleset it stays at Info), or no `AA0137` at all (without the ruleset it is a warning).

Remove the probe afterwards.

## 8. Troubleshooting

| Message | Cause | Fix |
|---|---|---|
| `error AL1033: An error occurred while loading the included rule set file ...` | The endpoint could not be loaded: the URL in the skeleton is wrong, the site is down, external rulesets are off (`enable_external_rulesets`, `-enableExternalRulesets`, `/enableexternalrulesets`), or the file is not valid JSON. | Open the include URL in a browser; turn external rulesets on (sections 3 to 5); check the Publish run of your rulebook. |
| `error AL0767: The URL '...' cannot be used as the ruleset path ...` | The ruleset is a URL and external rulesets are off. | Point at the local skeleton and turn external rulesets on. |
| ALOps: AL1033 although `enable_external_rulesets` is `true` | The task runs in parallel mode, where the input is ignored. | Use `compilation_mode: Serial` (section 3). |
| ALOps: the rules of the editor apply in the pipeline | `ruleset` is empty, so the task took `al.ruleSetPath` from `.vscode/settings.json` (the `default` stage). | Set `ruleset` to the `ci` file (section 3). |
| "The rulesetFile (...) is not shared with the container." | `Compile-AppInBcContainer` got a file outside the folders shared with the container. | Keep the app, and with it `.rulebook/`, in a shared folder. |
| `warning AL1003: An instance of analyzer ... cannot be created ...` and no analyzer diagnostics | Analyzer DLLs from another target-framework folder than the `alc.dll` that runs. | Take the analyzers from the folder of that `alc.dll`; fail the build on AL1003 (section 5). |
| A rule shows at its analyzer default, not at the action the endpoint lists | The pipeline does not pass the ruleset, the analyzer does not run, or the skeleton has a project exception. | Check the compile command for `/ruleset:` and `/analyzer:`; look at the `rules` of the skeleton. |
