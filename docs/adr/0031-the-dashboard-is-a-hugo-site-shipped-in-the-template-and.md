# D31. The dashboard is a Hugo site shipped in the template and published next to the endpoints

- **Status:** Accepted
- **Date:** 2026-10-03

- **Decision:** an organization's rulebook repository ships a Hugo site under `site/` that renders the matrix of diagnostic ids by level and stage with provenance, one page per rule, filters and a cart. The Publish action builds it with a pinned Hugo and deploys it as the root of the same host that serves `rulesets/`. It is optional (`site.enabled`), replaces the WP05 `index.html` when enabled, and is meaningful for the `pages` and `azure-blob` targets only. The whole site lives in the template so an organization can adapt it (see D35 for how updates respect that).
- **Rationale:** the audience is the organization maintainer who owns the rulebook but does not want to edit JSON. Hugo renders 628 rows and 628 rule pages at build time, so the browser-side script stays small; the runner that publishes already exists, so installing Hugo costs the organization nothing. Pages is the default host already (D7), and a site next to the endpoints needs no second deployment.
- **Rejected:** a single-page application without a generator (works, but every row and page is built in the browser and there is no stable URL per rule); the site in the engine deployed by the action (fixes ship with `@v1`, but an organization cannot adapt layouts; the owner chose adaptability); a separate theme repository or Hugo module (a third repository and Go tooling); a site on alcops.dev for every organization (a central service that would need the organization's data).
- **Consequences:** `site/**` is a new file class in the update (D35). The Publish action gains a Hugo step and a data export (`site/data/rulebook.json`, gitignored). Spike WP01 (h) confirms Hugo content adapters for the per-rule pages. For `dist-repo` and `gist` the setting is ignored with a warning because raw URLs serve HTML as text.
- **Affects:** WP02, WP05, WP07, WP11, WP14.
