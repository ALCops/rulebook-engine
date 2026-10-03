# D9. Tooling: PowerShell 7 and Pester on ubuntu runners

- **Status:** Accepted
- **Date:** 2026-09-29

- **Decision:** actions are composite actions running PowerShell 7 scripts; tests are Pester 5; static analysis is PSScriptAnalyzer; every workflow runs on `ubuntu-latest`.
- **Rationale:** same language as AL-Go and BcContainerHelper, so the Business Central community can contribute and patterns can be reused. `pwsh` is preinstalled on GitHub's Ubuntu images.
- **Rejected:** TypeScript (faster startup, unfamiliar to the community); .NET tooling everywhere (heavier build); a split with a .NET extractor (possible later if WP01 spike b shows reflection from pwsh is unreliable).
- **Consequences:** no Windows-only dependency is accepted in any action.
- **Affects:** all WPs.
