# D12. Testing scope for v1 is Pester unit tests

- **Status:** Accepted
- **Date:** 2026-09-29

- **Decision:** every module and action has Pester unit tests with fixtures, run on `ubuntu-latest` on every PR. End-to-end compile tests with the real compiler, effective-ruleset snapshot tests and a template smoke test are documented as later options.
- **Rationale:** unit tests give the fastest feedback for the merge logic, file generation and diffing, which is where the risk is. The other layers need infrastructure that v1 does not have.
- **Consequences:** the merge module must be testable without network access (fixtures with local include trees).
- **Affects:** WP03, WP12.
