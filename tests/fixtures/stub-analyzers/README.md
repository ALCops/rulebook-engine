# Stub analyzer packages

C# stubs of the Business Central compiler and its cops, compiled at test time into fixture nupkgs so the Extract and
Scan suites run offline (WP08, plan 5.7). `Build-StubPackage.ps1 -Variant <name> -OutputPath <folder>` compiles them
with `Add-Type -OutputAssembly`, lays them out like the real packages (`tools/<tfm>/any/`, `lib/<tfm>/`) and writes a
NuGet flat container (`<id>/index.json`, `<id>/<version>/<id>.<version>.nupkg`) that `Get-NuGetVersionIndex -Source`
reads as a folder. Run it in its own pwsh process so the stub types never load into the test session.

The real packages are scanned only by the CI job `scan-action` and the live end-to-end run.
