# D3. Managed levels are vendored into the org repo

- **Status:** Accepted
- **Date:** 2026-09-29

- **Decision:** the level files ship inside the template and are updated in the org repo by the update workflow. Compilation never depends on an ALCops-hosted URL.
- **Rationale:** the compiler discards the whole ruleset when one include fails (AL1033). A live dependency on a third-party URL would put every org's pipeline behind ALCops' availability.
- **Rejected:** public ALCops endpoints included by URL (zero maintenance for the user, but a runtime dependency on ALCops for every build); both mechanisms (two code paths to test).
- **Consequences:** level files are system files in the update file classes. Adopting a new ALCops level version is a reviewable PR in the org repo.
- **Affects:** WP04, WP07, WP10.
