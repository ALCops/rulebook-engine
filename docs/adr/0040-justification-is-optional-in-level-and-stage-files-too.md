# D40. Justification is optional in level and stage files too

- **Status:** Accepted
- **Date:** 2026-10-04

- **Decision:** a `justification` on a rule in a level file (`base/`) or a stage file (`stages/`) is optional, as it already is in overrides and change sets (D37); a generated endpoint carries only `id` and `action`, and its schema forbids `justification`.
- **Rationale:** one rule shape for every source file (`deltaRule` in `schemas/ruleset.schema.json`), shared by level, stage and skeleton files. An organization that writes its own level or stage by hand should not have to write prose per id to pass validation, any more than it has to for an override (D37). The shipped files still carry a justification on every entry because Build-Matrix copies the matrix `Justification` column into them; that is a matrix convention ([rulebook/00-conventions.md](../rulebook/00-conventions.md) section 5), not a schema rule.
- **Rejected:** required in level and stage files only (two rule shapes, and C1 would require what C10 does not, for the same kind of entry); required in shipped files only (the schema cannot tell a shipped file from an org-owned one, and the matrix check already guarantees it for the shipped set).
- **Consequences:** C1 and C10 in [ARCHITECTURE.md](../ARCHITECTURE.md) section 5.3 say the justification is optional; WP03 never fails a file for a missing justification; the endpoint profile rejects one, so a generator that leaks a justification into `rulesets/` fails validation. Extends D37, which stays in force unchanged.
- **Affects:** WP02, WP03, WP04, WP10, WP12.
