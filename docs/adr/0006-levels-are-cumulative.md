# D6. Levels are cumulative

- **Status:** Superseded by D18, partly reinstated by D27 (2026-10-01)
- **Date:** 2026-09-29

- **Partly reinstated** by D27 (2026-10-01): a level is again the level it is based on plus a delta, in the source files; the include chain stays superseded by D18.
- **Decision:** `L<n>` includes `./L<n-1>.ruleset.json` and carries only its own delta in `rules`. A custom level is inserted by including the level below it.
- **Rationale:** adding a level is adding one file. Because a file's own rules override its includes, a level can raise and lower rules of the level below it.
- **Rejected:** independent full sets per level (every decision repeated six times, drift guaranteed without a generator); matrix source with generated flat outputs (conflicts with D13).
- **Consequences:** chain depth adds one HTTP fetch per level at compile time (see D13). Validation must resolve the chain.
- **Affects:** WP02, WP03, WP09, WP10.
