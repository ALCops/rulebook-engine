# D8. Endpoint URLs are unversioned in v1

- **Status:** Accepted
- **Date:** 2026-09-29

- **Decision:** endpoints always reflect the default branch of the org repo. No `/v1/` prefix.
- **Rationale:** the org repo is the version; pinning is done with git. Fewer files, simpler publish.
- **Rejected:** versioned folders plus latest (more publish logic, no demand yet).
- **Consequences:** validation before publish is the safety net; a broken publish affects every build immediately. The URL scheme keeps `rulesets/` as a segment so a version prefix can be inserted later.
- **Affects:** WP03, WP05.
