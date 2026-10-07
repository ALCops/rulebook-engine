# Stub analyzer packages

C# stubs of the Business Central compiler and its cops, compiled at test time into fixture nupkgs so the Extract, Scan
and ScanDiagnostics action suites run offline (WP08, [docs/reference/scan-mechanics.md](../../../docs/reference/scan-mechanics.md)
section 10). The real packages are read only by the CI job `scan-action` and the live end-to-end run.

| File | Stub of |
|---|---|
| `CodeAnalysis.cs` | `Microsoft.Dynamics.Nav.CodeAnalysis.dll`: `DiagnosticSeverity`, the internal `ErrorCode` enum (below 100, `WRN_` 200, `ERR_` 1003, `INF_` 1027, `HDN_` 1030), `DiagnosticDescriptor`, the abstract `DiagnosticAnalyzer` with `ImmutableArray<DiagnosticDescriptor> SupportedDiagnostics`. No embedded resources, so the AL titles are empty. |
| `CodeCop.cs` | AA0001 advertised by two analyzers, AA0002 field-only, AA0003 deprecated, an abstract analyzer and one without a parameterless constructor, a link with `?wt.mc_id=`, a static descriptor property whose getter throws (reported in `fieldErrors`). |
| `LinterCop.cs` | LC0015 Info in 1.3.1 and Warning from 1.4.0-beta.1, LC0100 new in 1.4.0-beta.1, LC0000 field-only, LC0089 and LC0089i, ZZ0001 with an unknown prefix. |
| `TestAutomationCop.cs` | TA0001 with the link as shipped (`testautomationCop`). |
| `Common.cs` | CM0001 at Info, disabled by default. |
| `BrokenCop.cs`, `MissingDependency.cs` | `-Fault MissingDependency`: a cop deriving from a class in `Stub.Missing.dll`, which the package does not ship (`ReflectionTypeLoadException`). |
| `ThrowingCop.cs` | `-Fault ThrowingConstructor`: an analyzer whose constructor throws. |
| `OneIdCop.cs` | One advertised id; `Build-StubPackage.ps1` fills it for UICop, AppSourceCop, PerTenantExtensionCop, ApplicationCop, DocumentationCop, FormattingCop and PlatformCop. |

`Build-StubPackage.ps1 -Variant <tools-stable | tools-prerelease | alcops-v1 | alcops-v2 | alcops-v3> -OutputPath <folder>`
compiles the stubs with the Roslyn compiler that ships with pwsh (the one `Add-Type` uses; `Add-Type -OutputAssembly`
names the assembly randomly, and the cops must reference the compiler stub as `Microsoft.Dynamics.Nav.CodeAnalysis`),
prepends `#define STUB_<VARIANT>` to every source, lays the DLLs out like the real packages (`tools/<tfm>/any/`,
`lib/<tfm>/`) and writes a NuGet flat container (`<id>/index.json`, `<id>/<version>/<id>.<version>.nupkg`) that
`Get-NuGetVersionIndex -Source` reads as a folder. Run it in its own pwsh process so the stub types never load into the
test session; `tests/Helpers/StubFeed.ps1` does that once per source hash and caches the result in the temp folder.
