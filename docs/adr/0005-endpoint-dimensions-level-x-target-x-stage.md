# D5. Endpoint dimensions: level x target x stage

- **Status:** Partly superseded by D21 and D28 (2026-10-01)
- **Date:** 2026-09-29

- **Partly superseded** by D21 and D28 (2026-10-01): the target dimension is removed, an endpoint is `<level>.<stage>.ruleset.json`. The stage dimension and its rationale stand.
- **Decision:** an endpoint is one file `<level>.<target>.<stage>.ruleset.json`. Targets are `pte`, `appsource` and `all`; stages are `dev`, `cicd` and `nextmajor`. With six levels that is 54 endpoints. `all` includes no target overlay, so both AppSourceCop and PerTenantExtensionCop run at the level's severities, for teams that do not distinguish per-tenant from AppSource development. The name of the third target (`all`, `any`, `both`) is fixed in WP02.
- **Rationale:** stage is where the quarantine granularity of the daily scan lives (D14). Target is where the AppSource-only rules are subtracted. Both are needed per level.
- **Rejected:** level x target with stages left to the org (moves the hardest part to every user); level only (same, worse).
- **Consequences:** many small root files, all generated once by WP04 and maintained by the update workflow. The change-rule action must be able to write to all matching roots (WP09).
- **Affects:** WP02, WP04, WP05, WP06, WP09.
