# Spike (b): analyzer DLLs and id extraction

> **Status:** done 2026-10-03. Issue [#20](https://github.com/ALCops/rulebook-engine/issues/20), part of WP01 ([#3](https://github.com/ALCops/rulebook-engine/issues/3)). Blocks: WP08 ([#10](https://github.com/ALCops/rulebook-engine/issues/10)).

## Question

Where are the analyzer DLLs inside the two NuGet packages, and which extraction method for diagnostic ids works on Linux, including prerelease packages?

## Method

A throwaway workflow (`spike-b.yml`, `workflow_dispatch` plus push on `wp01/spike-b`, read-only token, removed before the pull request; last version at `755dea0:.github/workflows/spike-b.yml`, with its scripts under `755dea0:.github/spike-b/`) ran on `ubuntu-latest`. It:

1. resolved the latest stable (last version without `-`) and the latest prerelease (last version with `-`) of `microsoft.dynamics.businesscentral.development.tools`, its `.linux` variant and `alcops.analyzers` from the nuget.org flat-container indexes, downloaded the six `.nupkg` files with `curl` and unzipped them;
2. listed every `*.dll` matching `Cop|Analyzer` plus `Microsoft.Dynamics.Nav.CodeAnalysis.dll` with path, size and SHA-256, compared the `.linux` DLLs with the neutral package by hash, and diffed the DLL lists of stable and prerelease;
3. ran three extraction methods on the stable and the prerelease packages and compared each id set, per prefix, with [`docs/rulebook/inventory/inventory.json`](../../rulebook/inventory/inventory.json) (628 ids, produced from sources by `tools/rulebook/Extract-Inventory.ps1`), including default severity and enablement;
4. probed alcops.dev and Microsoft Learn for anything machine-readable that carries title and docs URL.

The three methods:

- **Method 1, reflection in pwsh** (`m1-reflection.ps1`). `[Reflection.Assembly]::LoadFrom` on `Microsoft.Dynamics.Nav.CodeAnalysis.dll` from the tools folder, an `AppDomain.AssemblyResolve` handler that probes the ALCops folder and then the tools folder, `LoadFrom` on each `Microsoft.Dynamics.Nav.*Cop.dll` and `ALCops.*.dll`, then every non-abstract type assignable to `Microsoft.Dynamics.Nav.CodeAnalysis.Diagnostics.DiagnosticAnalyzer` with a parameterless constructor is instantiated and its `SupportedDiagnostics` read (`Id`, `DefaultSeverity`, `IsEnabledByDefault`, `Title`, `HelpLinkUri`, `Category`, `IsDeprecated`). The compiler's own configurable ids (prefix AL) are not analyzers: they come from the internal enum `Microsoft.Dynamics.Nav.CodeAnalysis.ErrorCode` (members numbered 100 and up whose name starts with `WRN_`, `INF_` or `HDN_`, the same rule `Extract-Inventory.ps1` applies to the source), with the message format from the `CompilerDiagnosticsResources` resource as title. A second pass reads every static field of type `DiagnosticDescriptor` in the cop assemblies, to find ids that are defined but returned by no analyzer.
- **Method 2, console app** (`m2/`, `TargetFrameworks` `net8.0;net10.0`, `RollForward` `LatestPatch`). A custom `AssemblyLoadContext` that resolves through an `AssemblyDependencyResolver` per `*.deps.json` in the tools folder, then probes the ALCops and tools folders, and leaves framework assemblies to the default context. Same enumeration through reflection, compiler ids without titles.
- **Method 3, regex scan** (`m3-scan.sh`). `strings -e l` (UTF-16, the .NET user-string heap) and `strings` on `Microsoft.Dynamics.Nav.CodeAnalysis.dll`, the four Microsoft cops and the seven ALCops DLLs of the `net10.0` folders; once for strings that are exactly an id (`^(AA|AW|AS|PTE|AL|LC|AC|DC|FC|PC|TA|TAC|CM)[0-9]{4}$`), once for ids embedded anywhere in a string (`\b...[0-9]{4}i?\b`).

The core of method 1, which WP08 can lift:

```powershell
$ca   = [Reflection.Assembly]::LoadFrom("$ToolsDir/Microsoft.Dynamics.Nav.CodeAnalysis.dll")
$base = $ca.GetType('Microsoft.Dynamics.Nav.CodeAnalysis.Diagnostics.DiagnosticAnalyzer', $true)
foreach ($dll in $copDlls) {
    $asm = [Reflection.Assembly]::LoadFrom($dll)
    try { $types = $asm.GetTypes() } catch [Reflection.ReflectionTypeLoadException] { $types = $_.Exception.Types | Where-Object { $_ } }
    foreach ($t in $types | Where-Object { $_.IsClass -and -not $_.IsAbstract -and $base.IsAssignableFrom($_) -and $_.GetConstructor([Type]::EmptyTypes) }) {
        foreach ($d in ([Activator]::CreateInstance($t)).SupportedDiagnostics) {
            # $d.Id, $d.DefaultSeverity, $d.IsEnabledByDefault, $d.Title.ToString(), $d.HelpLinkUri, $d.Category, $d.IsDeprecated
        }
    }
}
```

## Environment and versions

| Item | Value |
|---|---|
| Date | 2026-10-03 |
| Runner image / OS | `ubuntu-latest` = ubuntu-24.04, image version 20260927.320.1 (Ubuntu 24.04.5 LTS) |
| pwsh on the runner | 7.6.6 on .NET 10.0.12 (`/opt/microsoft/powershell/7`) |
| .NET on the runner | SDKs 8.0.131 to 10.0.401; runtimes Microsoft.NETCore.App 8.0.6/8.0.22/8.0.31, 9.0.6/9.0.20, 10.0.8/10.0.11/10.0.12 |
| Development.Tools | stable **18.0.43.1464**, prerelease **30.0.42.60748-beta** (index: 45 versions) |
| Development.Tools.Linux | stable **18.0.43.1464**, prerelease **30.0.42.60748-beta** (index: 44 versions) |
| ALCops.Analyzers | stable **1.3.1**, prerelease **1.3.0-beta.1** (index: 107 versions; the newest prerelease is older than the stable) |
| Other tools | GNU strings (binutils) 2.42, `jq`, `curl`, `unzip` from the image |
| Baseline | `inventory.json` on `main` at 3e03449 (628 ids; ALCops part read from the Analyzers repository `main`, 18 commits after `v1.3.1`) |

## Observed

Final run: [actions/runs/37144520914](https://github.com/ALCops/rulebook-engine/actions/runs/37144520914) (job 52 s, all steps green). Download of all six packages: 0.05 to 0.4 s each.

### DLL inventory

Stable packages. `TextCopy.dll` matches the `Cop` filter but is a clipboard library, not an analyzer.

| Package | Version | Path in nupkg | Size | sha256 (short) |
|---|---|---|---|---|
| Development.Tools | 18.0.43.1464 | `tools/net8.0/any/Microsoft.Dynamics.Nav.CodeAnalysis.dll` | 10,997,088 | c6d4f66c6fd9 |
| Development.Tools | 18.0.43.1464 | `tools/net8.0/any/Microsoft.Dynamics.Nav.CodeCop.dll` | 362,808 | 14425f3e9682 |
| Development.Tools | 18.0.43.1464 | `tools/net8.0/any/Microsoft.Dynamics.Nav.UICop.dll` | 83,256 | 8f6fb0bab121 |
| Development.Tools | 18.0.43.1464 | `tools/net8.0/any/Microsoft.Dynamics.Nav.AppSourceCop.dll` | 468,280 | 0e4725059542 |
| Development.Tools | 18.0.43.1464 | `tools/net8.0/any/Microsoft.Dynamics.Nav.PerTenantExtensionCop.dll` | 83,256 | 41e0fdf072c2 |
| Development.Tools | 18.0.43.1464 | `tools/net8.0/any/Microsoft.Dynamics.Nav.Analyzers.Common.dll` | 59,232 | c6ade6703c4f |
| Development.Tools | 18.0.43.1464 | `tools/net10.0/any/Microsoft.Dynamics.Nav.CodeAnalysis.dll` | 10,997,560 | fcdae1eb28f8 |
| Development.Tools | 18.0.43.1464 | `tools/net10.0/any/Microsoft.Dynamics.Nav.CodeCop.dll` | 362,808 | d029772acc06 |
| Development.Tools | 18.0.43.1464 | `tools/net10.0/any/Microsoft.Dynamics.Nav.UICop.dll` | 83,256 | f46fc3b3caf3 |
| Development.Tools | 18.0.43.1464 | `tools/net10.0/any/Microsoft.Dynamics.Nav.AppSourceCop.dll` | 468,280 | efb8cc7d5ded |
| Development.Tools | 18.0.43.1464 | `tools/net10.0/any/Microsoft.Dynamics.Nav.PerTenantExtensionCop.dll` | 83,256 | 6dba53cb9e26 |
| Development.Tools | 18.0.43.1464 | `tools/net10.0/any/Microsoft.Dynamics.Nav.Analyzers.Common.dll` | 59,192 | b4597084fd40 |
| Development.Tools.Linux | 18.0.43.1464 | `lib/net8.0/Microsoft.Dynamics.Nav.{CodeCop,UICop,AppSourceCop,PerTenantExtensionCop,Analyzers.Common}.dll` | as `tools/net8.0/any` | identical to `tools/net8.0/any` |
| Development.Tools.Linux | 18.0.43.1464 | `lib/net10.0/Microsoft.Dynamics.Nav.{CodeCop,UICop,AppSourceCop,PerTenantExtensionCop,Analyzers.Common}.dll` | as `tools/net10.0/any` | identical to `tools/net10.0/any` |
| ALCops.Analyzers | 1.3.1 | `lib/net8.0/ALCops.ApplicationCop.dll` | 168,960 | d406ebbd7415 |
| ALCops.Analyzers | 1.3.1 | `lib/net8.0/ALCops.Common.dll` | 182,784 | 135cb4b07d43 |
| ALCops.Analyzers | 1.3.1 | `lib/net8.0/ALCops.DocumentationCop.dll` | 34,304 | 66cc5bd40edd |
| ALCops.Analyzers | 1.3.1 | `lib/net8.0/ALCops.FormattingCop.dll` | 73,216 | b55d5d6d3c2b |
| ALCops.Analyzers | 1.3.1 | `lib/net8.0/ALCops.LinterCop.dll` | 195,584 | a0f3574ebcf0 |
| ALCops.Analyzers | 1.3.1 | `lib/net8.0/ALCops.PlatformCop.dll` | 308,224 | 9df6131ab1cf |
| ALCops.Analyzers | 1.3.1 | `lib/net8.0/ALCops.TestAutomationCop.dll` | 12,800 | 8d7aad9b99cd |
| ALCops.Analyzers | 1.3.1 | `lib/net10.0/ALCops.ApplicationCop.dll` | 168,960 | 51432b6cb7e7 |
| ALCops.Analyzers | 1.3.1 | `lib/net10.0/ALCops.Common.dll` | 183,808 | a2629f500c83 |
| ALCops.Analyzers | 1.3.1 | `lib/net10.0/ALCops.DocumentationCop.dll` | 34,304 | 3d9658d96cee |
| ALCops.Analyzers | 1.3.1 | `lib/net10.0/ALCops.FormattingCop.dll` | 73,216 | d86b34bd24b1 |
| ALCops.Analyzers | 1.3.1 | `lib/net10.0/ALCops.LinterCop.dll` | 195,584 | 47ec7cd87423 |
| ALCops.Analyzers | 1.3.1 | `lib/net10.0/ALCops.PlatformCop.dll` | 311,808 | 8597d5cfb278 |
| ALCops.Analyzers | 1.3.1 | `lib/net10.0/ALCops.TestAutomationCop.dll` | 12,800 | 8e14e3b13f69 |
| ALCops.Analyzers | 1.3.1 | `lib/netstandard2.1/ALCops.*.dll` (same seven names) | 13,824 to 299,008 | see details |

Findings on the packages:

- **The `.Linux` package is a subset with byte-identical analyzers.** It is a `Dependency` package ("intended to be referenced from other .NET projects", per its README) with only the five cop DLLs per TFM under `lib/net8.0` and `lib/net10.0`; all 20 DLLs (stable and prerelease, both TFMs) have the same SHA-256 as the neutral package's `tools/<tfm>/any` copies. It does **not** contain `Microsoft.Dynamics.Nav.CodeAnalysis.dll`, so it cannot be used on its own for extraction, and it adds nothing. `.win` and `.osx` variants exist on nuget.org too (prerelease `30.0.42.60748-beta` is the newest of each); they were not downloaded.
- **Prerelease ships no analyzer missing from stable.** The tools prerelease `30.0.42.60748-beta` adds only `Onigwrap.dll`, `TextMateSharp.dll` and three `runtimes/win-*/native/libonigwrap.dll` per TFM (a TextMate grammar engine, not an analyzer); the cop DLL names and folders are the same. `alcops.analyzers` 1.3.0-beta.1 and 1.3.1 have identical DLL lists.
- Both TFM folders of the tools package carry their own build of every cop (different hashes, same names); ALCops ships `netstandard2.1`, `net8.0` and `net10.0`.

<details>
<summary>Prerelease and netstandard2.1 rows</summary>

```
package                                               version             path                                                            size      sha256
microsoft.dynamics.businesscentral.development.tools  30.0.42.60748-beta  tools/net10.0/any/Microsoft.Dynamics.Nav.Analyzers.Common.dll    59232     ddff42cafa79
microsoft.dynamics.businesscentral.development.tools  30.0.42.60748-beta  tools/net10.0/any/Microsoft.Dynamics.Nav.AppSourceCop.dll       468320    eb9b9b077e73
microsoft.dynamics.businesscentral.development.tools  30.0.42.60748-beta  tools/net10.0/any/Microsoft.Dynamics.Nav.CodeAnalysis.dll      11024736  ef05d4413272
microsoft.dynamics.businesscentral.development.tools  30.0.42.60748-beta  tools/net10.0/any/Microsoft.Dynamics.Nav.CodeCop.dll            363360    4d9e40948101
microsoft.dynamics.businesscentral.development.tools  30.0.42.60748-beta  tools/net10.0/any/Microsoft.Dynamics.Nav.PerTenantExtensionCop.dll  83256  3a50dc73149d
microsoft.dynamics.businesscentral.development.tools  30.0.42.60748-beta  tools/net10.0/any/Microsoft.Dynamics.Nav.UICop.dll              83296     e39fe854493e
microsoft.dynamics.businesscentral.development.tools  30.0.42.60748-beta  tools/net8.0/any/Microsoft.Dynamics.Nav.Analyzers.Common.dll     59192     ea3af3977c0b
microsoft.dynamics.businesscentral.development.tools  30.0.42.60748-beta  tools/net8.0/any/Microsoft.Dynamics.Nav.AppSourceCop.dll        468280    41fd4e38429a
microsoft.dynamics.businesscentral.development.tools  30.0.42.60748-beta  tools/net8.0/any/Microsoft.Dynamics.Nav.CodeAnalysis.dll       11024696  2b991bea8d94
microsoft.dynamics.businesscentral.development.tools  30.0.42.60748-beta  tools/net8.0/any/Microsoft.Dynamics.Nav.CodeCop.dll             363360    86181a79ae6e
microsoft.dynamics.businesscentral.development.tools  30.0.42.60748-beta  tools/net8.0/any/Microsoft.Dynamics.Nav.PerTenantExtensionCop.dll  83256   eb73143f3a7e
microsoft.dynamics.businesscentral.development.tools  30.0.42.60748-beta  tools/net8.0/any/Microsoft.Dynamics.Nav.UICop.dll               83296     bb3495297d58
alcops.analyzers  1.3.1         lib/netstandard2.1/ALCops.ApplicationCop.dll      164864  d734fdb15bac
alcops.analyzers  1.3.1         lib/netstandard2.1/ALCops.Common.dll              179200  fd09ac9293c1
alcops.analyzers  1.3.1         lib/netstandard2.1/ALCops.DocumentationCop.dll     34816  128888a56279
alcops.analyzers  1.3.1         lib/netstandard2.1/ALCops.FormattingCop.dll        72704  6f524213a184
alcops.analyzers  1.3.1         lib/netstandard2.1/ALCops.LinterCop.dll           184320  9ddea959c814
alcops.analyzers  1.3.1         lib/netstandard2.1/ALCops.PlatformCop.dll         299008  ab82b9267932
alcops.analyzers  1.3.1         lib/netstandard2.1/ALCops.TestAutomationCop.dll    13824  f71fc494afdf
alcops.analyzers  1.3.0-beta.1  lib/net8.0/ALCops.{ApplicationCop,Common,DocumentationCop,FormattingCop,LinterCop,PlatformCop,TestAutomationCop}.dll  (same layout as 1.3.1)
alcops.analyzers  1.3.0-beta.1  lib/net10.0/...  lib/netstandard2.1/...                                                                          (same layout as 1.3.1)

== DLL list diff microsoft.dynamics.businesscentral.development.tools stable 18.0.43.1464 vs prerelease 30.0.42.60748-beta (all *.dll paths)
> tools/net10.0/any/Onigwrap.dll
> tools/net10.0/any/TextMateSharp.dll
> tools/net10.0/any/runtimes/win-arm64/native/libonigwrap.dll
> tools/net10.0/any/runtimes/win-x64/native/libonigwrap.dll
> tools/net10.0/any/runtimes/win-x86/native/libonigwrap.dll
> (the same five under tools/net8.0/any)
== DLL list diff alcops.analyzers stable 1.3.1 vs prerelease 1.3.0-beta.1 (all *.dll paths)
identical DLL lists
```

</details>

### Extraction methods

Id counts are against the 628 ids of `inventory.json`. "Not advertised" means the descriptor exists as a static field in the DLL but no analyzer returns it from `SupportedDiagnostics`.

| Method | Works net8 | Works net10 | Runtime | Deps on runner | Ids found / 628 | Missing | Extra | Fragility |
|---|---|---|---|---|---|---|---|---|
| 1 pwsh reflection | yes (`tools/net8.0/any` + `lib/net8.0`) | yes (`tools/net10.0/any` + `lib/net10.0`) | 0.9 to 1.2 s per package pair, pwsh start included | preinstalled pwsh 7.6.6 only | **618**; 625 with the static-field pass | 10: not advertised AC0000, DC0000, FC0000, LC0000, PC0000, TA0000, AS0141; not released AC0033, AC0034, TA0002 (the field pass recovers the seven, the three stay missing) | 0 | low: public Roslyn-style API of the cops; the AL part depends on the internal `ErrorCode` enum and its `WRN_`/`INF_`/`HDN_` naming. Severity, enablement, title (618/618) and help link (all 399 cop ids) come with it; 0 differences in default or enablement against the inventory |
| 2 console + `AssemblyLoadContext` | yes (net8.0 console on `tools/net8.0/any`) | yes (net10.0 console on `tools/net10.0/any`); a net8.0 console on the net10.0 folder crashes | `dotnet build` (restore + build) 13.1 s, run 0.1 to 2.7 s | preinstalled .NET SDK; a project to build and keep | **618** | same 10 as method 1 | 0 | low for loading, but more code to own (a project, a build step, two TFMs); same internal-enum dependency for AL; output identical to method 1 (0 differing id/severity/enabled lines) |
| 3 `strings` + regex | not TFM-bound | not TFM-bound | 0.13 s | binutils `strings` | **126** (exact match; 129 with embedded matches) | 502: every AA, AW, AS, PTE and AL id, plus LC0089i (exact only), AC0033, AC0034, TA0002 | exact: AL1022, AL1045, AL1153; embedded adds AL1023 (compiler Error codes that occur in strings) | high: finds nothing for the Microsoft cops, whose ids are built at run time (`AppSourceCopAnalyzers.AnalyzerPrefix + "0141"`), and nothing for the compiler (enum values are numbers); yields no severity, enablement, title or link; ALCops ids appear only because they are string literals |

Findings on the methods:

- **Reflection works on both TFM folders under the runner's pwsh.** pwsh 7.6.6 runs on .NET 10.0.12, so it loads `tools/net10.0/any` natively and `tools/net8.0/any` by forward compatibility; both give the same 618 ids with the same defaults. The reverse does not hold: a process on .NET 8 that loads the `net10.0` folder fails (`FileNotFoundException: Could not load file or assembly 'System.Runtime, Version=10.0.0.0'` in method 2), which is the same mechanism as the AL1003 mismatch in [spike (c)](c-alc-on-ubuntu.md). pwsh 7.4 (.NET 8) was not available on the runner to try.
- **ALCops `netstandard2.1` loses a rule.** With `lib/netstandard2.1` the LinterCop returns 32 instead of 33 descriptors: LC0091 is defined but not advertised in that build. `lib/net8.0` and `lib/net10.0` agree.
- **No instantiation failures, no binding failures on the runner** (235 analyzer types per run: 135 Microsoft, 100 ALCops; 0 exceptions). The `AssemblyResolve` handler is needed: ALCops.LinterCop's code-fix types reference `Microsoft.Dynamics.Nav.CodeAnalysis.Workspaces.dll`, which ships in the tools folder; in a local check on Windows without the handler, `GetTypes()` threw `ReflectionTypeLoadException` with 36 of 140 types unloaded.
- **62 ids are returned by more than one analyzer type** (mostly AppSourceCop, plus AC0032); in every case the duplicates agree on severity and enablement, so deduplication by id is safe. LC0003 appears once; `inventory.json` notes it as a descriptor pair from source.
- **Stable and prerelease give the same id set.** Method 1 on Development.Tools 30.0.42.60748-beta with ALCops 1.3.0-beta.1 returned the same 618 ids as on 18.0.43.1464 with 1.3.1, with no default or enablement change.
- **Why the inventory has 10 more ids.** `Extract-Inventory.ps1` reads source, not binaries. AS0141 is a descriptor no AppSourceCop analyzer returns (dead in both versions). The six `XX0000` ids are the ALCops "analyzer exception" descriptors; in 1.3.1 the rule analyzers derive from `DiagnosticAnalyzer` directly instead of the per-cop base class that appends the `XX0000` descriptor, so no analyzer advertises them. AC0033, AC0034 and TA0002 were added on the Analyzers `main` after `v1.3.1` (commits 0764aae and b9ed989) and are in no package yet.
- **ALCops TestAutomationCop's help link is wrong.** `HelpLinkUri` is `https://alcops.dev/docs/analyzers/testautomationCop/ta0001/` (capital `C`), which returns 404; the lowercase path returns 200. The same URL is in `inventory.json`, which copied it from the source.

<details>
<summary>Method 1 and 2 output, stable, net10.0 (runner)</summary>

```
pwsh 7.6.6 on .NET 10.0.12
loaded Microsoft.Dynamics.Nav.CodeAnalysis, Version=18.0.43.1464, Culture=neutral, PublicKeyToken=31bf3856ad364e35 from .../tools/net10.0/any/Microsoft.Dynamics.Nav.CodeAnalysis.dll
compiler: 219 configurable ids
Microsoft.Dynamics.Nav.AppSourceCop.dll: 44 analyzer types, 215 descriptors
Microsoft.Dynamics.Nav.CodeCop.dll: 61 analyzer types, 93 descriptors
Microsoft.Dynamics.Nav.PerTenantExtensionCop.dll: 13 analyzer types, 26 descriptors
Microsoft.Dynamics.Nav.UICop.dll: 17 analyzer types, 17 descriptors
ALCops.ApplicationCop.dll: 24 analyzer types, 33 descriptors
ALCops.Common.dll: 1 analyzer types, 1 descriptors
ALCops.DocumentationCop.dll: 6 analyzer types, 10 descriptors
ALCops.FormattingCop.dll: 8 analyzer types, 8 descriptors
ALCops.LinterCop.dll: 25 analyzer types, 33 descriptors
ALCops.PlatformCop.dll: 35 analyzer types, 37 descriptors
ALCops.TestAutomationCop.dll: 1 analyzer types, 1 descriptors
static descriptor fields: 406 ids; defined but not returned by any analyzer: 7
  field-only AC0000 Info/True ALCops.ApplicationCop.DiagnosticDescriptors.AnalyzerException
  field-only AS0141 Error/True Microsoft.Dynamics.Nav.AppSourceCop.DiagnosticDescriptors.Rule0141TableMovedWithoutMovedFromProperty
  field-only DC0000 Info/True ALCops.DocumentationCop.DiagnosticDescriptors.AnalyzerException
  field-only FC0000 Info/True ALCops.FormattingCop.DiagnosticDescriptors.AnalyzerException
  field-only LC0000 Info/True ALCops.LinterCop.DiagnosticDescriptors.AnalyzerException
  field-only PC0000 Info/True ALCops.PlatformCop.DiagnosticDescriptors.AnalyzerException
  field-only TA0000 Info/True ALCops.TestAutomationCop.DiagnosticDescriptors.AnalyzerException
unique ids: 618; instantiation failures: 0; elapsed 1.0 s
## m1-stable-net10 : 618 ids, inventory 628, common 618
AA   inventory   93 found   93 missing   0 [] extra   0 []
AC   inventory   35 found   32 missing   3 [AC0000 AC0033 AC0034] extra   0 []
AL   inventory  219 found  219 missing   0 [] extra   0 []
AS   inventory  143 found  142 missing   1 [AS0141] extra   0 []
AW   inventory   17 found   17 missing   0 [] extra   0 []
CM   inventory    1 found    1 missing   0 [] extra   0 []
DC   inventory   11 found   10 missing   1 [DC0000] extra   0 []
FC   inventory    8 found    7 missing   1 [FC0000] extra   0 []
LC   inventory   34 found   33 missing   1 [LC0000] extra   0 []
PC   inventory   38 found   37 missing   1 [PC0000] extra   0 []
PTE  inventory   26 found   26 missing   0 [] extra   0 []
TA   inventory    3 found    1 missing   2 [TA0000 TA0002] extra   0 []
default/enabled differences vs inventory: 0
ids without title: 0; without helpLinkUri: 219

== m2 stable-console8-folder10
runtime .NET 8.0.31
loaded Microsoft.Dynamics.Nav.CodeAnalysis, Version=18.0.43.1464, ...
Unhandled exception. System.IO.FileNotFoundException: Could not load file or assembly 'System.Runtime, Version=10.0.0.0, Culture=neutral, PublicKeyToken=b03f5f7f11d50a3a'. The system cannot find the file specified.
exit=134

== m1 stable-ns21-on-net8 (ALCops lib/netstandard2.1)
ALCops.LinterCop.dll: 25 analyzer types, 32 descriptors
  field-only LC0091 Warning/True ALCops.LinterCop.DiagnosticDescriptors.TranslatableTextShouldBeTranslated
unique ids: 617; instantiation failures: 0; elapsed 1.0 s

m1 net10: stable 618, prerelease 618
  only in prerelease:
  only in stable:
  default changes (id sev enabled, stable < > prerelease):
m1-stable-net10 vs m1-stable-net8: 0 differing lines
m1-stable-net10 vs m2-stable-net8: 0 differing lines
m1-stable-net10 vs m2-stable-net10: 0 differing lines
```

</details>

<details>
<summary>Method 3 output, stable</summary>

```
m3 m3-stable: exact 129 ids, embedded 133 ids, 0.13 s
AA exact=0 embedded=2; AW exact=0 embedded=0; AS exact=0 embedded=0; PTE exact=0 embedded=0; AL exact=3 embedded=4; LC exact=33 embedded=34; AC exact=33 embedded=33; DC exact=11 embedded=11; FC exact=8 embedded=8; PC exact=38 embedded=38; TA exact=2 embedded=2; CM exact=1 embedded=1;
## m3-stable-exact : 129 ids, inventory 628, common 126
m3-stable exact vs m1-stable-net10: only in m3: 9, only in m1: 498
  only in m3 (exact): AC0000 AL1022 AL1045 AL1153 DC0000 FC0000 LC0000 PC0000 TA0000
```

The two embedded AA hits are AA0131 and AA0137, found inside longer strings. The prerelease scan gave the same counts.

</details>

### Machine-readable title and docs URL

Not needed for the recommended method, which reads `Title` and `HelpLinkUri` from the descriptors. Probed anyway (runner and local, same results):

| URL | Status | What it carries |
|---|---|---|
| `https://alcops.dev/docs/analyzers/index.json` | 404 | - |
| `https://alcops.dev/index.json` | 404 | - |
| `https://alcops.dev/docs/analyzers/index.xml` | 200, RSS, 439 bytes | empty channel, no items |
| `https://alcops.dev/index.xml` | 200, RSS, 244,676 bytes | 137 items with title and link, 123 of them rule pages; the id is only in the URL path |
| `https://alcops.dev/sitemap.xml` | 200 | 152 URLs, 123 rule pages, no titles |
| `https://alcops.dev/offline-search-index.be3d677e694d6411853167da52919974.json` (name found in the `search-index-json-src` attribute of every page) | 200, JSON, 465,918 bytes | 152 entries `{ref, title, description, excerpt, body, categories, tags}`, 123 rule pages; no id field, no severity; the file name changes with every site build |
| `https://alcops.dev/docs/analyzers/lintercop/lc0001/` | 404 | rule page URLs use the cop folder and lowercase id (`.../applicationcop/ac0001/` is 200) |
| `https://learn.microsoft.com/en-us/dynamics365/business-central/dev-itpro/developer/analyzers/codecop-aa0137` | 200, HTML | no `application/ld+json`; `<meta name="description">` holds the rule title, `<title>` is "CodeCop Warning AA0137 - Business Central" |
| `https://learn.microsoft.com/en-us/dynamics365/business-central/dev-itpro/developer/toc.json` (the page's `toc_rel`) | 200, JSON, 358,294 bytes | id-to-path map only (`{"href":"analyzers/codecop-aa0137","toc_title":"AA0137"}`): 93 AA, 17 AW, 143 AS, 26 PTE and 917 AL entries (the AL entries include Error codes); no titles |

The 123 alcops.dev rule pages are the 121 ALCops 1.3.1 ids without `LC0089i` (no page of its own) plus AC0033, AC0034 and TA0002, which the site already documents ahead of the package.

## Answer

WP08 implements **method 1, reflection in pwsh**: load `Microsoft.Dynamics.Nav.CodeAnalysis.dll` and the four `Microsoft.Dynamics.Nav.*Cop.dll` from **`tools/<tfm>/any/`** of `Microsoft.Dynamics.BusinessCentral.Development.Tools`, the seven `ALCops.*.dll` from **`lib/<tfm>/`** of `ALCops.Analyzers` (same `<tfm>`, resolving `Microsoft.Dynamics.Nav.CodeAnalysis*` from the tools folder through an `AssemblyResolve` handler), instantiate every `DiagnosticAnalyzer` and read `SupportedDiagnostics`; read the compiler's AL ids from the `ErrorCode` enum in the same assembly. On `ubuntu-latest` today (pwsh 7.6.6 on .NET 10.0.12) `<tfm>` is **`net10.0`**: `tools/net10.0/any/` and `lib/net10.0/`. `net8.0` gave identical output; WP08 should choose the highest TFM folder that is not newer than the pwsh runtime (`[Environment]::Version.Major`) and never `netstandard2.1`. It works for stable and prerelease alike, needs nothing beyond pwsh, takes about a second, and yields everything the catalog needs (id, default severity, enablement, title, help link); it found 618 of the 628 inventory ids with zero default differences, and the 10 others are not advertised by any analyzer or not released yet. The `.Linux` package can be ignored: its analyzers are byte-identical to the neutral package and it lacks `Microsoft.Dynamics.Nav.CodeAnalysis.dll`.

## Consequences for blocked work packages

| WP | Consequence | Action taken |
|---|---|---|
| WP08 ([#10](https://github.com/ALCops/rulebook-engine/issues/10)) | Extractor = pwsh reflection over `tools/<tfm>/any/` and `lib/<tfm>/` (TFM rule above), no .NET project. Download only the neutral tools package and `alcops.analyzers`. `title` and `docsUrl` come from the descriptors (strip `?wt.mc_id=...` from Microsoft links); only AL ids need the docs pattern `.../diagnostics/diagnostic-al<n>`. Add the static-descriptor-field pass to report defined-but-unadvertised ids (AS0141, `XX0000`) separately instead of quarantining them, deduplicate by id (62 ids come from several analyzers), and treat the prerelease channel as current only when it sorts after stable (ALCops prerelease 1.3.0-beta.1 is older than stable 1.3.1). The `Rulebook.Extract.Tests.ps1` fixture can be a stub assembly with one `DiagnosticAnalyzer` subclass. | Comment posted on [#10](https://github.com/ALCops/rulebook-engine/issues/10); [ARCHITECTURE.md §7.4](../../ARCHITECTURE.md#74-scan-diagnostics-r9) names the method and links this file |
| WP10 and the inventory | `inventory.json` lists 3 ids that no package ships yet (AC0033, AC0034, TA0002: Analyzers `main` after `v1.3.1`) and carries the broken TestAutomationCop docs link. A refresh of `Extract-Inventory.ps1` should pin the Analyzers source to the released tag, as it already does for the Microsoft side with `StableTag`. | None in this PR (recorded here) |
| Analyzers repository (follow-up, not opened from here) | (1) `ALCops.TestAutomationCop` builds its help link with `testautomationCop` (capital C); alcops.dev serves only the lowercase path, so every TA link returns 404. (2) A machine-readable rule list is **not needed** for the rulebook: the DLLs already expose id, severity, enablement, title and link through reflection, and alcops.dev publishes titles and links (RSS and the offline search index) without id or severity. Not worth asking for. (3) The `XX0000` descriptors are not advertised by any shipped analyzer, and `lib/netstandard2.1` does not advertise LC0091; both are for the maintainers to judge. | None (no issue opened in other repositories) |
| WP01 open questions (#3 section 8) | Prerelease tools packages do not ship analyzers missing from the stable or the neutral package: same cop DLLs, same 618 ids, same defaults, and the `.Linux` variant is a byte-identical subset. A rule list in the Analyzers repository is unnecessary (see above). | Answered here |

## Not covered

- pwsh 7.4 or 7.5 (on .NET 8 or 9): only pwsh 7.6.6 is on the runner. The .NET 8 failure mode for the `net10.0` folder is shown by method 2.
- The `.win` and `.osx` variants of the tools package and the AL VS Code extension (VSIX) as an analyzer source (WP08 section 8): not downloaded.
- Older stable versions (for example 18.0.41.62505) and a version that actually changes a default: the two channels on 2026-10-03 have identical id sets, so default drift could not be observed.

## Artifacts

- Final run: <https://github.com/ALCops/rulebook-engine/actions/runs/37144520914> (job summary holds every table; the `spike-b-outputs` artifact with the JSON outputs is kept 14 days).
- Earlier iteration: [37144382694](https://github.com/ALCops/rulebook-engine/actions/runs/37144382694) (method 2's expected crash on the TFM mismatch stopped the job; the later steps did not run).
- The throwaway workflow `.github/workflows/spike-b.yml` and its scripts under `.github/spike-b/` lived on `wp01/spike-b` and were removed in the last commit before the pull request; the version the final run executed is `755dea0` (`git show 755dea0:.github/workflows/spike-b.yml`). No scratch repository was created. Nothing besides this file and the one-sentence link in ARCHITECTURE.md §7.4 is kept in the repository.
