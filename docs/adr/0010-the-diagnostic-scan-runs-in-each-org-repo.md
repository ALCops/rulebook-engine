# D10. The diagnostic scan runs in each org repo

- **Status:** Accepted
- **Date:** 2026-09-29

- **Decision:** the daily `ScanDiagnostics` workflow in the org repo downloads the latest stable and prerelease versions of `Microsoft.Dynamics.BusinessCentral.Development.Tools` and `ALCops.Analyzers` from NuGet, extracts every diagnostic id and updates the org's catalog and quarantine files.
- **Rationale:** no dependency on an ALCops-hosted catalog; every org sees new rules the day they are published.
- **Rejected:** a central catalog published by ALCops (single point of failure, and the org's scan would still need to run to update its files); both with a fallback (two code paths).
- **Consequences:** one NuGet download per org per day. The extraction method must work on Linux (WP01 spike b).
- **Affects:** WP01, WP08, WP10.
