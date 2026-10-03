# D4. Level content starts empty, placeholder names L0 to L5

- **Status:** Superseded by D25, D26 and D28 (2026-10-01)
- **Date:** 2026-09-29

- **Superseded** by D25, D26 and D28 (2026-10-01): no `L0`, no `L<n>` ids; levels are an ordered configurable ladder identified by a single `name`. "Level names appear only in file names and settings, never in code" still holds.
- **Decision:** the template ships six levels named `L0` to `L5` with no rules except `L0`, which lists every known diagnostic at `None`. The ALCops maintainer crafts the rules afterwards. Names are configuration in `Rulebook-Settings.json` and can be changed.
- **Rationale:** the tooling and structure are independent of the per-rule decisions. Existing rulesets (company blob-hosted trees, StefanMaron/RulesetFiles) are input for the maintainer, not seed content.
- **Rejected:** seeding from an existing company ruleset tree (company-specific decisions in a public template); a migration script as part of v1 (moved to WP11 as a guide, script optional).
- **Consequences:** `L0` is generated from the catalog (WP08, WP10). Level names appear only in file names and settings, never in code.
- **Affects:** WP04, WP10.
