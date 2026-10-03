# D36. The public site omits the organization's free-text justifications by default

- **Status:** Accepted
- **Date:** 2026-10-03

- **Decision:** `site/data/rulebook.json` carries the effective action and provenance for every id and endpoint, the override entries and the quarantine ids, and the level and stage justifications from the engine. The justification text of override and quarantine entries is written only when `site.includeJustifications` is true.
- **Rationale:** outside Enterprise Cloud a Pages site is public. The endpoints are public already (the compiler fetches anonymously, D7), so the effective actions add nothing new; the organization's free text may name tickets, customers or dates. The engine's justifications are public in the engine repository.
- **Rejected:** everything public by default (one setting away from leaking a ticket reference); only what the endpoints reveal (loses the override and quarantine markers that make the matrix useful); a password-protected site (rejected in the interview).
- **Consequences:** the export has one switch; the user docs say what is public. There is no other access control; `site.enabled: false` is the off switch.
- **Affects:** WP11, WP14.
