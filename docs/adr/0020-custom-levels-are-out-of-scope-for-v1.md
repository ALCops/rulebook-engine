# D20. Custom levels are out of scope for v1

- **Status:** Superseded by D26, D27 and D29 (2026-10-01)
- **Date:** 2026-09-29

- **Superseded** by D26, D27 and D29 (2026-10-01): levels are configurable and `basedOn` exists.
- **Decision:** the template ships `L0` and the four content levels only. There is no `AddLevel` action and no `basedOn` in the settings. Requirement R8 ("multiple levels, extensible, custom levels possible") is met by the four levels plus `overrides.json`; a custom level is revisited when someone asks for one.
- **Rationale:** in the flat model a custom level would be a named override set on top of a base level, which is the same mechanism as organization overrides with a different scope. Building the tooling before there is demand adds nine endpoints, nine skeletons and a settings shape for nothing.
- **Rejected:** custom level as override set with its own endpoints (possible later without breaking anything); hand-maintained flat files per custom level (no tooling, no update path).
- **Consequences:** `settings.levels` is fixed to five entries whose `name` and `description` remain editable. WP09 loses `AddLevel`, WP10 loses forking and inserting levels, WP04 generates 37 roots and skeletons.
- **Affects:** WP02, WP04, WP09, WP10.
