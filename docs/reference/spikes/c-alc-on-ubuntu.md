# Spike (c): alc on ubuntu

> **Status:** done 2026-10-03. Issue [#21](https://github.com/ALCops/rulebook-engine/issues/21), part of WP01 ([#3](https://github.com/ALCops/rulebook-engine/issues/3)). Blocks: WP12 ([#14](https://github.com/ALCops/rulebook-engine/issues/14)); the compile recipe feeds spikes (a) and (f).

## Question

Does `alc` from the NuGet tool run on `ubuntu-latest`?

## Method

A throwaway workflow (`spike-c.yml`, `workflow_dispatch` plus push on `wp01/spike-c`, read-only token, removed before the pull request; last version at `568bd7e:.github/workflows/spike-c.yml`) ran on `ubuntu-latest`. It:

1. recorded the runner image and the installed .NET SDKs and runtimes;
2. installed the latest **stable** `Microsoft.Dynamics.BusinessCentral.Development.Tools` as a global dotnet tool, pinned to `18.0.43.1464` (re-checked against the nuget.org flat-container index: still the latest stable on 2026-10-03), with no `actions/setup-dotnet`;
3. resolved which TFM folder the `al` shim loads (`COREHOST_TRACE=1`);
4. downloaded the platform symbols (`System.app`) from the public MSSymbols feed with `curl`;
5. compiled a one-codeunit fixture (below) with CodeCop, UICop and PerTenantExtensionCop: without a ruleset, with a local ruleset setting AA0137 to `Error`, through `al compile` and through the bare `dotnet alc.dll`, plus the two URL controls of the common protocol, the missing-symbols negative case, one compile with AppSourceCop added, and one deliberate TFM mismatch.

Fixture (final values; `runtime` and `platform` needed no change):

```json
{
  "id": "6f1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d",
  "name": "Spike",
  "publisher": "Rulebook Spike",
  "version": "1.0.0.0",
  "platform": "28.0.0.0",
  "runtime": "17.0",
  "idRanges": [ { "from": 50000, "to": 50099 } ],
  "target": "Cloud"
}
```

```al
codeunit 50000 "Spike"
{
    procedure Probe()
    var
        Unused: Integer;
    begin
    end;
}
```

Local ruleset `aa0137-error.ruleset.json`:

```json
{
  "name": "spike-c",
  "rules": [ { "id": "AA0137", "action": "Error", "justification": "spike (c)" } ]
}
```

## Environment and versions

| Item | Value |
|---|---|
| Date | 2026-10-03 |
| Runner image / OS | `ubuntu-latest` = ubuntu-24.04, image version 20260927.320.1 (Ubuntu 24.04.5 LTS) |
| .NET on the runner | SDKs 8.0.131 to 10.0.401 (default `dotnet --version` 10.0.401); runtimes Microsoft.NETCore.App 8.0.6/8.0.22/8.0.31, 9.0.6/9.0.20, 10.0.8/10.0.11/10.0.12. No `setup-dotnet` needed. |
| Development.Tools (alc) | 18.0.43.1464 (`al --version`: `18.0.43.1464+ad5c66161d2e2ef7ba77e4a6c7681eb522cf752c`). The tool store holds both `tools/net8.0/any` and `tools/net10.0/any`; the `al` shim loads **`tools/net10.0/any`** on Microsoft.NETCore.App 10.0.12. |
| Platform symbols | `microsoft.platform.symbols` 28.0.54265 from MSSymbols, nupkg 64,887 bytes, one file `System.app` (64,485 bytes) |
| AL runtime | `al GetLatestSupportedRuntimeVersion 28.0` prints `17.1`; the fixture uses `17.0` and compiles. |

## Observed

Final run: [actions/runs/37143256030](https://github.com/ALCops/rulebook-engine/actions/runs/37143256030) (job 23 s). `$AL_BIN` is `~/.dotnet/tools/.store/microsoft.dynamics.businesscentral.development.tools/18.0.43.1464/microsoft.dynamics.businesscentral.development.tools/18.0.43.1464/tools/net10.0/any`; `$COPS` is `/analyzer:` for CodeCop, UICop and PerTenantExtensionCop from that folder.

| Step | Command | Exit code | Wall time | Key output line |
|---|---|---|---|---|
| Install | `dotnet tool install --global Microsoft.Dynamics.BusinessCentral.Development.Tools --version 18.0.43.1464` | 0 | 2.7 to 5.9 s (three runs) | `Tool '...development.tools' (version '18.0.43.1464') was successfully installed.` |
| Version | `al --version` | 0 | 0.1 s | `18.0.43.1464+ad5c661...` |
| Runtime | `al GetLatestSupportedRuntimeVersion 28.0` | 0 | 0.1 s | `17.1` (the four-part `28.0.0.0`, `27.0.0.0` and `26.0.0.0` give `Unknown platform version`, exit 1) |
| Symbols | `curl -sSL -o platform.nupkg $FEED/microsoft.platform.symbols/28.0.54265/...nupkg` + `unzip -o -j platform.nupkg '*.app' -d fixture/.alpackages` | 0 | 0.3 s | exactly one file: `System.app` |
| 1 no ruleset | `al compile /project:fixture /packagecachepath:fixture/.alpackages /out:fixture/out1.app $COPS` | 0 | 1.6 s | `warning AA0137: Variable 'Unused' is unused in 'Probe'.`; `out1.app` 2,434 bytes |
| 2 local ruleset | same + `/ruleset:aa0137-error.ruleset.json` | 1 | 1.4 s | `error AA0137: Variable 'Unused' is unused in 'Probe'.` |
| 3 bare invocation | `dotnet $AL_BIN/alc.dll` + same switches as 2 | 1 | 1.4 s | `error AA0137: ...` (identical output: the `al` wrapper adds nothing) |
| 4 control | `al compile ... /ruleset:<url>` without `/enableexternalrulesets` | 1 | 0.2 s | `error AL0767: The URL '...' cannot be used as the ruleset path ...`; no compilation |
| 5 control | `al compile ... /ruleset:<404 url> /enableexternalrulesets` | 1 | 0.4 s | `error AL1033: An error occurred while loading the included rule set file '...'`; no compilation |
| 6 negative | step 2 with an empty `.alpackages` | 1 | 0.6 s | `error AL1022: A package with publisher 'Microsoft', name 'System', and a version compatible with '28.0.0.0' could not be found in the package cache folders: ...` |
| 7 AppSourceCop | step 1 + `/analyzer:$AL_BIN/Microsoft.Dynamics.Nav.AppSourceCop.dll` | 1 | 1.4 s | AppSourceCop loads and runs: AS0051 (7x), AS0084, AS0015, AS0052, AS0100, AS0054 as errors on this per-tenant fixture |
| 8 TFM mismatch | `dotnet tools/net8.0/any/alc.dll` with analyzers from `tools/net10.0/any` | **0** | 4.3 s | 91x `warning AL1003: An instance of analyzer ... cannot be created ...`; **no AA0137**; `out8.app` written |
| 9 other TFM, matched | `dotnet tools/net8.0/any/alc.dll` with analyzers from `tools/net8.0/any` + local ruleset | 1 | 1.4 s | `error AA0137: ...` (the net8.0 build works too when its analyzers come from the same folder) |

Findings beyond the yes/no:

- **Controls 4 and 5 abort the compile.** On the `alc` command line a root ruleset URL that is blocked (AL0767) or cannot be loaded (AL1033) is a command-line error: alc prints the one diagnostic, never reaches `Compilation started`, writes no `.app`, and exits 1. This differs from [compiler-ruleset-internals.md §7](../compiler-ruleset-internals.md#7-failure-model) and [ARCHITECTURE.md §10](../../ARCHITECTURE.md#10-failure-model-and-operational-risks), which say the compiler continues with its defaults. Whether the same holds when the failing URL is an *include* inside a local skeleton is left to spike (a).
- **Analyzer DLLs must come from the TFM folder of the `alc.dll` that runs.** Mixing folders (step 8) does not fail the build: every rule is dropped with AL1003, the exit code is 0 and no analyzer diagnostic appears. A CI job must derive `$AL_BIN` from the folder the shim loads (or call `dotnet <folder>/alc.dll` with analyzers from the same folder) and should treat AL1003 as a failure by grepping the compile log (see the Recipe).
- **The MSSymbols index is sorted newest first.** `jq -r '.versions[-1]'` returns `17.0.17020.31164`, the oldest entry; `.versions[0]` returned `28.0.54265`. The robust form is to filter on the major and sort numerically (command below).
- **The tool package ships no `.app` files**, so a project without dependencies still needs the `System.app` download (step 6 is the error a job sees without it).
- **AppSourceCop on a per-tenant fixture produces errors.** A fixture meant to be analyzer-quiet must leave AppSourceCop out (or be a full AppSource manifest); spikes that probe AS ids (f) expect these errors.
- The run carried the annotation "The ubuntu-latest label will migrate to Ubuntu 26 beginning October 19, 2026" ([actions/runner-images#14748](https://github.com/actions/runner-images/issues/14748)). Nothing in the recipe depends on Ubuntu 24.04, but the image changes under WP12 before it starts.

<details>
<summary>Tool layout and shim resolution (final run)</summary>

```
dotnet --version: 10.0.401
al shim loads: /home/runner/.dotnet/tools/.store/microsoft.dynamics.businesscentral.development.tools/18.0.43.1464/microsoft.dynamics.businesscentral.development.tools/18.0.43.1464/tools/net10.0/any/altool.dll
--- ls $(dirname $AL_BIN)
any
--- cops
Microsoft.CodeAnalysis.dll
Microsoft.Dynamics.Nav.AppSourceCop.dll
Microsoft.Dynamics.Nav.CodeAnalysis.dll
Microsoft.Dynamics.Nav.CodeCop.dll
Microsoft.Dynamics.Nav.PerTenantExtensionCop.dll
Microsoft.Dynamics.Nav.UICop.dll
alc.dll
alc.runtimeconfig.json          "tfm": "net10.0", Microsoft.NETCore.App "10.0.0"
altool.dll
altool.runtimeconfig.json       "tfm": "net10.0"
--- DotnetToolSettings.xml (net10.0/any)
<Command Name="al" EntryPoint="altool.dll" Runner="dotnet" />
--- .app files in tool
(none)
```

`find ~/.dotnet/tools/.store -name alc.dll` lists both `tools/net8.0/any/alc.dll` and `tools/net10.0/any/alc.dll`, in that order, so `find ... | head -1` picks **net8.0**, not the folder the shim runs.

</details>

<details>
<summary>Symbols</summary>

```
versions[0]=28.0.54265  versions[-1]=17.0.17020.31164
chosen=28.0.54265
curl exit 0 in 0.3s, size 64887 bytes
Archive:  platform.nupkg
  Length      Date    Time    Name
---------  ---------- -----   ----
      469  2026-09-07 17:47   manifest.nuspec
    64485  2026-09-07 17:47   System.app
---------                     -------
    64954                     2 files
  inflating: fixture/.alpackages/System.app
```

</details>

<details>
<summary>Compile output, steps 1, 2, 4, 5 and 6</summary>

```
## 1 no ruleset (al compile)
Microsoft (R) AL Compiler version 18.0.43.1464
Compilation started for project 'Spike' containing '1' files at '18:11:27.495'.
fixture/src/Spike.Codeunit.al(1,16): info AA0247: Use namespaces to organize your code and isolate it from changes.
fixture/src/Spike.Codeunit.al(5,9): warning AA0137: Variable 'Unused' is unused in 'Probe'.
Compilation ended at '18:11:28.895'.

## 2 local ruleset AA0137=Error (al compile)
Compilation started for project 'Spike' containing '1' files at '18:11:29.180'.
fixture/src/Spike.Codeunit.al(1,16): info AA0247: Use namespaces to organize your code and isolate it from changes.
fixture/src/Spike.Codeunit.al(5,9): error AA0137: Variable 'Unused' is unused in 'Probe'.
Compilation ended at '18:11:30.305'.

## 4 control: URL without /enableexternalrulesets
Microsoft (R) AL Compiler version 18.0.43.1464
error AL0767: The URL 'https://raw.githubusercontent.com/ALCops/rulebook-engine/main/does-not-exist.ruleset.json' cannot be used as the ruleset path for this project because its configuration does not permit external rulesets.

## 5 control: 404 URL with /enableexternalrulesets
Microsoft (R) AL Compiler version 18.0.43.1464
error AL1033: An error occurred while loading the included rule set file 'https://raw.githubusercontent.com/ALCops/rulebook-engine/main/does-not-exist.ruleset.json' - Could not load the rule set file from 'https://raw.githubusercontent.com/ALCops/rulebook-engine/main/does-not-exist.ruleset.json'.

## 6 negative: empty .alpackages
Compilation started for project 'Spike' containing '1' files at '18:11:32.666'.
error AL1022: A package with publisher 'Microsoft', name 'System', and a version compatible with '28.0.0.0' could not be found in the package cache folders: /home/runner/work/rulebook-engine/rulebook-engine/empty/.alpackages
Compilation ended at '18:11:33.012'.
```

</details>

<details>
<summary>Step 8, TFM mismatch (first of 91 identical warnings)</summary>

```
warning AL1003: An instance of analyzer Microsoft.Dynamics.Nav.CodeCop.Readability.Rule001BinaryOperatorSpacing cannot be created from .../tools/net10.0/any/Microsoft.Dynamics.Nav.CodeCop.dll : Could not load file or assembly 'System.Collections.Immutable, Version=10.0.0.0, Culture=neutral, PublicKeyToken=b03f5f7f11d50a3a'. The system cannot find the file specified.
```

</details>

### Recipe

Install and PATH (no `setup-dotnet`; the runner's .NET 10 runtime is used):

```bash
dotnet tool install --global Microsoft.Dynamics.BusinessCentral.Development.Tools --version 18.0.43.1464
echo "$HOME/.dotnet/tools" >> "$GITHUB_PATH"          # al is on PATH from the next step on
# analyzer folder = the TFM folder the al shim loads (net10.0 on ubuntu-24.04 today)
AL_BIN=$(dirname "$(find ~/.dotnet/tools/.store/microsoft.dynamics.businesscentral.development.tools -path '*/tools/net10.0/any/alc.dll' | head -1)")
if [ ! -f "$AL_BIN/alc.dll" ]; then echo "::error::alc.dll not found in '$AL_BIN'"; exit 1; fi
```

`net10.0` is today's value on ubuntu-24.04; WP12 must resolve the folder at run time from the shim (the `altool.dll` path printed by `COREHOST_TRACE=1 al --version`) or from the `DotnetToolSettings.xml` it uses, rather than hard-code it. The guard matters because `dirname ""` is `.`, which would turn every `/analyzer:` path into a missing file.

Symbols (anonymous, no container):

```bash
FEED=https://pkgs.dev.azure.com/dynamicssmb2/DynamicsBCPublicFeeds/_packaging/MSSymbols/nuget/v3/flat2
V=$(curl -fsS "$FEED/microsoft.platform.symbols/index.json" \
  | jq -r '[.versions[] | select(startswith("28.") and (contains("-") | not))]
           | sort_by(split(".") | map(tonumber)) | last // empty')
if [ -z "$V" ]; then echo "::error::no stable 28.x platform symbols on the feed"; exit 1; fi
curl -fsSL -o platform.nupkg "$FEED/microsoft.platform.symbols/$V/microsoft.platform.symbols.$V.nupkg"
mkdir -p fixture/.alpackages && unzip -o -j platform.nupkg '*.app' -d fixture/.alpackages   # -> System.app
```

Compile:

```bash
al compile /project:fixture /packagecachepath:fixture/.alpackages /out:fixture/out.app \
  /analyzer:$AL_BIN/Microsoft.Dynamics.Nav.CodeCop.dll \
  /analyzer:$AL_BIN/Microsoft.Dynamics.Nav.UICop.dll \
  /analyzer:$AL_BIN/Microsoft.Dynamics.Nav.PerTenantExtensionCop.dll \
  /ruleset:<path-or-url> [/enableexternalrulesets] 2>&1 | tee compile.log
rc=${PIPESTATUS[0]}
if grep -q 'AL1003' compile.log; then echo "::error::analyzers failed to load (AL1003)"; exit 1; fi
exit "$rc"
```

The AL1003 check is needed because a run whose analyzers fail to load still exits 0 (step 8).

`dotnet $AL_BIN/alc.dll <same switches>` is equivalent. Add `/analyzer:$AL_BIN/Microsoft.Dynamics.Nav.AppSourceCop.dll` only when AppSourceCop findings are wanted.

## Answer

Yes. The stable `Microsoft.Dynamics.BusinessCentral.Development.Tools` 18.0.43.1464 installs as a global dotnet tool on `ubuntu-latest` in about 3 to 6 seconds without `setup-dotnet`, runs from `tools/net10.0/any`, and compiles a one-codeunit project in about 1.5 seconds with CodeCop, UICop and PerTenantExtensionCop and a local ruleset (AA0137 moved from Warning to Error as configured); AppSourceCop also loads and runs, but reports errors on the per-tenant fixture. A project without dependencies still needs a symbol download: the tool ships no `.app`, and the `System.app` from the public MSSymbols feed (`microsoft.platform.symbols` 28.0.54265, one `curl`) is enough; without it alc stops with AL1022. WP12's end-to-end compile can run on a plain `ubuntu-latest` runner without a container, provided the job takes the analyzers from the same TFM folder as `alc.dll` and fails on AL1003.

## Consequences for blocked work packages

| WP | Consequence | Action taken |
|---|---|---|
| WP12 ([#14](https://github.com/ALCops/rulebook-engine/issues/14)) | End-to-end compile option is **go** on `ubuntu-latest` without a container. The reusable job: install pinned stable tool, `$GITHUB_PATH`, `$AL_BIN` from the shim's TFM folder, `System.app` from MSSymbols, compile; fail on AL1003 (grep on the compile log) and AL1022 (AL1033 and AL0767 abort the compile with exit 1 on their own). Note the Ubuntu 26 migration of `ubuntu-latest` from 2026-10-19. | Comment posted on [#14](https://github.com/ALCops/rulebook-engine/issues/14#issuecomment-5972051669) |
| WP02 ([#4](https://github.com/ALCops/rulebook-engine/issues/4)) via spike (a) | A failing **root** ruleset URL aborts `alc` (exit 1, no compilation) instead of falling back to defaults; [compiler-ruleset-internals.md §7](../compiler-ruleset-internals.md#7-failure-model) and [ARCHITECTURE.md §10](../../ARCHITECTURE.md#10-failure-model-and-operational-risks) state a fallback. Spike (a) checks the include case and corrects those lines if confirmed. | A one-sentence "Contested" note added under §7 and §13 of compiler-ruleset-internals.md and §10 of ARCHITECTURE.md (original text kept); passed to spike (a); removed again by spike (a) |
| Spikes (a), (f) | Use the recipe above; `runtime: "17.0"` and `platform: "28.0.0.0"` work. Spike (f) adds AppSourceCop and should expect AS0051, AS0015, AS0052, AS0100 and AS0054 on a minimal manifest next to AS0084. | None (facts passed to the next executors) |

## Not covered

- The `.Linux` variant of the tools package: the platform-neutral package worked, so it was not tried (per the protocol).
- `ubuntu-26.04`: not available as `ubuntu-latest` yet; WP12 re-checks after the 2026-10-19 migration.
- Prerelease tools (30.x): out of scope by decision (stable only); spike (b) downloads them for DLL inventory only.
- Application symbols (`microsoft.application.symbols`): the fixture has no Base Application dependency.
- AL1033 and AL0767 when the URL is an include in a local skeleton rather than the root path: spike (a).

## Artifacts

- Final run: <https://github.com/ALCops/rulebook-engine/actions/runs/37143256030> (all steps; job summary holds the result table).
- Earlier iterations: [37143072312](https://github.com/ALCops/rulebook-engine/actions/runs/37143072312) (workflow file error: `runner` context not allowed in `defaults.run.working-directory`), [37143096407](https://github.com/ALCops/rulebook-engine/actions/runs/37143096407) (all four cops, AppSourceCop errors on the per-tenant fixture), [37143193714](https://github.com/ALCops/rulebook-engine/actions/runs/37143193714) (TFM mismatch first observed).
- The throwaway workflow `.github/workflows/spike-c.yml` lived on `wp01/spike-c` and was removed in the last commit before the pull request; its last version, the file the final run executed, is `568bd7e:.github/workflows/spike-c.yml` (`git show 568bd7e:.github/workflows/spike-c.yml`). No scratch repository was created. Nothing besides this file and the spikes index is kept in the repository.
