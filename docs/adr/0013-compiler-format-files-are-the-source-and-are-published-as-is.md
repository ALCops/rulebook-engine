# D13. Compiler-format files are the source and are published as-is

- **Status:** Superseded by D18 (2026-09-29)
- **Date:** 2026-09-29

- **Superseded** by D18 (2026-09-29): every endpoint is one flat file generated from the level chain, the stage deltas and the organization's inputs; there is a generation step and the generated files are committed. The index listed this record as Accepted until 2026-10-06 (WP05).
- **Decision:** the files in `rulesets/` are ordinary ruleset files in the compiler's schema (plus a `justification` property the compiler ignores). There is no build or flattening step; the include chain is what the compiler fetches.
- **Rationale:** what you see in the repo is what the compiler loads. No generated artifacts to review, no generator to maintain. AL developers already know the format.
- **Rejected:** layered source flattened on publish (one fetch per compile and no merge pitfalls, but a build step and generated files); a Rulebook-specific matrix format (most powerful, least familiar).
- **Consequences:** every include in a chain is a separate HTTP fetch with a 15 second timeout and no cache, so chain depth is bounded by the validation rules. Only an ancestor can lower a rule, so overlays that sit as siblings of the level chain must be disjoint from every level file, and this is enforced by the validate action. Org overrides live in the endpoint root's own `rules` (see O1).
- **Affects:** WP02, WP03, WP05, WP09.
