# D7. Hosting is pluggable, GitHub Pages is the default

- **Status:** Accepted
- **Date:** 2026-09-29

- **Decision:** the publish action supports GitHub Pages (default), a public dist repository served through `raw.githubusercontent.com`, Azure Blob Storage and a Gist. Pages is the documented path.
- **Rationale:** the compiler fetches anonymously with a 15 second timeout, so the endpoint must be a plain public HTTPS URL. Pages works from a private repo (public site) on GitHub Pro, Team and Enterprise Cloud; on Free the repo must be public. Orgs on Free with a private repo need the dist-repo or blob recipe, which is why the target is pluggable. Spike WP01 (d) [confirmed](../reference/spikes/d-pages-private-repo.md) the Free-plan rule on a Free organization and found a second gate, the org member privilege "Pages creation".
- **Rejected:** Pages only (excludes private repos on Free); Gist as default (personal account, no custom domain, no CI on the gist).
- **Consequences:** the base URL is a setting and is rendered into skeletons. A post-publish reachability check of every endpoint is part of the action.
- **Affects:** WP05, WP06, WP11.
