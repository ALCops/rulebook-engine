# D1. Topology: one rulebook repo per organization

- **Status:** Accepted
- **Date:** 2026-09-29

- **Decision:** an organization creates one rulebook repo from the template. It publishes endpoints (URLs). Each AL project repo only holds a small local ruleset file that includes one endpoint by URL plus project exceptions.
- **Rationale:** rules are decided once per organization. The AL project side stays a single file that every consumer (VS Code, AL-Go, ALOps) can point at.
- **Rejected:** rulebook files inside every AL repo (N copies to keep in sync, no single place to decide); both models at once (double documentation and testing for v1).
- **Consequences:** the update mechanism (D2, WP07) targets the org repo, not AL projects. AL projects need only the skeleton file (WP06).
- **Affects:** WP04, WP06, WP07, WP11.
