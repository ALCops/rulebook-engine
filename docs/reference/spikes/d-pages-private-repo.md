# Spike (d): Pages from a private repository

> **Status:** done 2026-10-04. Issue [#22](https://github.com/ALCops/rulebook-engine/issues/22), part of WP01 ([#3](https://github.com/ALCops/rulebook-engine/issues/3)). Blocks: WP05 ([#7](https://github.com/ALCops/rulebook-engine/issues/7)).

## Question

How does GitHub Pages behave for a private organization repository on the Free plan?

## Method

All calls ran from local Windows with `gh` logged in as an **owner** of the ALCops organization (plan `free`). The workflows ran on `ubuntu-latest` in the scratch repositories.

1. **Scratch repositories.** Two repositories were created in the ALCops org on 2026-10-03 18:58Z: `ALCops/rulebook-spike-pages-private` (private) and `ALCops/rulebook-spike-pages-public` (public, the same-plan control). Each holds a README, `index.html` and `rulesets/essential.ruleset.json`:

   ```json
   {
     "name": "Spike",
     "rules": [
       { "id": "AA0137", "action": "Error" }
     ]
   }
   ```

2. **API path** (owner token), on each repository:

   ```bash
   gh api -i -X POST repos/ALCops/<repo>/pages -f build_type=legacy -f 'source[branch]=main' -f 'source[path]=/'
   gh api -i -X POST repos/ALCops/<repo>/pages -f build_type=workflow
   gh api -i repos/ALCops/<repo>/pages
   gh api orgs/ALCops --jq '{plan: .plan.name, members_can_create_pages, members_can_create_public_pages, members_can_create_private_pages}'
   ```

3. **Actions path** (what the Publish action will use): `.github/workflows/pages.yml` in each repository, triggered on push and by `workflow_dispatch`:

   ```yaml
   permissions:
     contents: read
     pages: write
     id-token: write
   jobs:
     deploy:
       runs-on: ubuntu-latest
       environment:
         name: github-pages
         url: ${{ steps.deployment.outputs.page_url }}
       steps:
         - uses: actions/checkout@v4
         - id: configure
           uses: actions/configure-pages@v5
           with:
             enablement: true
         - run: mkdir -p _site && cp -r rulesets index.html _site/
         - uses: actions/upload-pages-artifact@v3
           with:
             path: _site
         - id: deployment
           uses: actions/deploy-pages@v4
   ```

4. **Settings page.** Arthur opened Settings > Pages of both repositories and pasted the wording, before and after the org change in step 5.
5. **Org policy change.** The first round showed that the org's member privilege *Pages creation* was off, and that it blocks owners too. Arthur turned on *Pages creation > Public* (Org Settings > Member privileges) late on 2026-10-03 local time. Steps 2 and 3 were then repeated: the first successful call was at **2026-10-04 04:39:21Z**. Private Pages creation stayed off (it needs Enterprise Cloud).
6. **Serving.** Steps after the public site existed:
   - Anonymous `curl -sI https://alcops.github.io/rulebook-spike-pages-public/rulesets/essential.ruleset.json`, polled every 15 s from the deploy dispatch.
   - Headers recorded.
   - `gh api repos/.../pages` fields recorded.
7. **Repository goes private later.** `gh api -X PATCH repos/ALCops/rulebook-spike-pages-public -f visibility=private` was run, followed by 10 minutes of polling every 15 s:
   - the endpoint with a cache-busting query string;
   - the endpoint without one;
   - the Pages API.

   The repository was then set back to public and polled for 2 more minutes. Finally the Actions workflow ran once more on the public repository, which had no Pages site at that point. This tested whether `configure-pages` with `enablement: true` can create the site on its own.

   gh 2.50.0 does not know `gh repo edit --accept-visibility-change-consequences` (`unknown flag`), hence the REST call.

## Environment and versions

| Item | Value |
|---|---|
| Date | 2026-10-03 (first round, 18:58Z to 19:00Z) and 2026-10-04 (after the org change, 04:39Z to 05:05Z) |
| Organization | ALCops, `plan.name` = `free` |
| `gh` | `gh version 2.50.0 (2024-05-29)`, user Arthurvdv (org owner) |
| Runner image | `ubuntu-latest` = ubuntu-24.04, image version 20260927.320.1, runner 2.337.0 |
| Actions | `actions/checkout@v4` (11d5960), `actions/configure-pages@v5` (983d773), `actions/upload-pages-artifact@v3` (56afc60), `actions/deploy-pages@v4` (d6db901) |
| `GITHUB_TOKEN` permissions printed by the job | `Contents: read`, `Metadata: read`, `Pages: write` |

## Observed

Two independent gates refuse a Pages site before anything is built:

- **The org member privilege "Pages creation"**: off on this org until Arthur changed it, and it applies to owners as well.
- **The plan gate** for private repositories on Free.

The Actions path shows neither message: `configure-pages` reports the same `Resource not accessible by integration` in every case.

| Repo visibility | API create status + message | Settings page wording | Actions deploy result | Anonymous GET status | content-type | Time to live |
|---|---|---|---|---|---|---|
| private, org "Pages creation" off | `422` "Your current plan does not support GitHub Pages for this repository." (legacy and workflow) | "Pages on this repository are disabled. Please contact your organization administrators" | fails in `configure-pages`: "Create Pages site failed. Error: Resource not accessible by integration" | no site | n/a | n/a |
| public, org "Pages creation" off | `422` "GitHub organization administrators disabled Pages creation." (legacy and workflow) | "Pages on this repository are disabled. Please contact your organization administrators" | fails in `configure-pages`: same message | no site | n/a | n/a |
| private, org "Pages creation: Public" on | `422` "Your current plan does not support GitHub Pages for this repository." (legacy and workflow) | "Upgrade or make this repository public to enable Pages" | fails in `configure-pages`: same message | no site | n/a | n/a |
| public, org "Pages creation: Public" on | `201 Created` (workflow); a second POST (legacy) `409` "GitHub Pages is already enabled." | before the site existed: "GitHub Pages is currently disabled. Select a source below to enable GitHub Pages for this repository." | **success** once the site existed; `deploy-pages` "Reported success!" | `404` before the deploy, `200` on the first poll after it | `application/json; charset=utf-8` | first `200` 7 s after `deploy-pages` reported success (first poll, so an upper bound); 43 s after the site was created; 27 s after the dispatch |
| public, org on, **no site yet**, Actions only | (not called) | (as above) | fails in `configure-pages`: "Create Pages site failed. Error: Resource not accessible by integration" | no site | n/a | n/a |
| public → **private** (site live) | Pages API `404` from +17 s | (not read) | (not run) | `200` until +555 s, `404` from +572 s, with and without cache-busting query | `text/html` on the 404 | site unpublished about 9.5 min after the change |
| private → public again | Pages API still `404`, `has_pages: false` for the 2 min polled | (not read) | (not run) | `404` | n/a | the site does not come back by itself; it must be enabled again |

`gh api repos/ALCops/rulebook-spike-pages-public/pages` once the site was deployed:

```json
{"build_type":"workflow","html_url":"https://alcops.github.io/rulebook-spike-pages-public/","public":true,"status":null}
```

The org setting as read through the API: before the change `members_can_create_pages`, `members_can_create_public_pages` and `members_can_create_private_pages` were all `false`. After the change they were `true`, `true` and `false`. `gh api orgs/ALCops/actions/permissions` answers 403 for this token: it needs the `admin:org` scope.

The existing site of `ALCops/alcops.dev` (`build_type: workflow`, `cname: alcops.dev`, `public: true`) was enabled before this spike. It is the org's only Pages site and kept serving while "Pages creation" was off. So the member privilege only blocks **creating** a site.

<details>
<summary>API responses, first round (2026-10-03 18:58Z, org "Pages creation" off)</summary>

Private repository, both POSTs (legacy and workflow):

```text
HTTP/2.0 422 Unprocessable Entity
Content-Type: application/json; charset=utf-8

{"message":"Your current plan does not support GitHub Pages for this repository.","documentation_url":"https://docs.github.com/rest/pages/pages#create-a-apiname-pages-site","status":"422"}
```

Public repository, both POSTs (legacy and workflow):

```text
HTTP/2.0 422 Unprocessable Entity
Content-Type: application/json; charset=utf-8

{"message":"GitHub organization administrators disabled Pages creation.","documentation_url":"https://docs.github.com/rest/pages/pages#create-a-apiname-pages-site","status":"422"}
```

`GET repos/ALCops/<repo>/pages`, both repositories:

```text
HTTP/2.0 404 Not Found

{"message":"Not Found","documentation_url":"https://docs.github.com/rest/pages/pages#get-a-apiname-pages-site","status":"404"}
```

</details>

<details>
<summary>API responses, second round (2026-10-04 04:39Z, org "Pages creation: Public" on)</summary>

Private repository, 04:39:20Z, both POSTs: unchanged, `422` "Your current plan does not support GitHub Pages for this repository."

Public repository, `POST ... -f build_type=workflow`, 04:39:21Z:

```text
HTTP/2.0 201 Created
Location: https://api.github.com/repos/ALCops/rulebook-spike-pages-public/pages

{"url":"https://api.github.com/repos/ALCops/rulebook-spike-pages-public/pages","status":null,"cname":null,"custom_404":false,"html_url":"https://alcops.github.io/rulebook-spike-pages-public/","build_type":"workflow","source":{"branch":"main","path":"/"},"public":true,"protected_domain_state":null,"pending_domain_unverified_at":null,"https_enforced":true}
```

Public repository, `POST ... -f build_type=legacy`, 04:39:22Z:

```text
HTTP/2.0 409 Conflict

{"message":"GitHub Pages is already enabled.","documentation_url":"https://docs.github.com/rest/pages/pages#create-a-apiname-pages-site","status":"409"}
```

</details>

<details>
<summary>Actions log lines (configure-pages, every failing run)</summary>

```text
##[warning]Get Pages site failed. Error: Not Found - https://docs.github.com/rest/pages/pages#get-a-apiname-pages-site
##[error]Create Pages site failed. Error: Resource not accessible by integration - https://docs.github.com/rest/pages/pages#create-a-apiname-pages-site
##[error]HttpError: Resource not accessible by integration - https://docs.github.com/rest/pages/pages#create-a-apiname-pages-site
```

Successful run on the public repository (site created through the API first):

```text
04:39:51Z Creating Pages deployment with payload:
04:39:52Z Created deployment for f206ff0aee4fd3d9f5c69e9cb8c1f04d98162dfe, ID: f206ff0aee4fd3d9f5c69e9cb8c1f04d98162dfe
04:39:57Z Getting Pages deployment status...
04:39:57Z Reported success!
base_url=https://alcops.github.io/rulebook-spike-pages-public
page_url=https://alcops.github.io/rulebook-spike-pages-public/
```

</details>

<details>
<summary>Anonymous GET of the endpoint (2026-10-04 04:40:11Z)</summary>

```text
HTTP/1.1 200 OK
Content-Length: 82
Server: GitHub.com
Content-Type: application/json; charset=utf-8
Last-Modified: Sun, 04 Oct 2026 04:39:53 GMT
Access-Control-Allow-Origin: *
ETag: "6ac1d899-52"
Cache-Control: max-age=600
x-github-edge-region: fra
Via: 1.1 varnish
X-Cache: HIT
```

</details>

<details>
<summary>Poll after the change to private (flip 2026-10-04 04:50:46Z)</summary>

```text
04:50:48Z +1s   GETbust=200 GETplain=200 API=null public=true https://alcops.github.io/rulebook-spike-pages-public/
04:51:04Z +17s  GETbust=200 GETplain=200 API={"message":"Not Found",...}
... (200 with Pages API 404 on every poll in between)
05:00:02Z +555s GETbust=200 GETplain=200 API={"message":"Not Found",...}
05:00:19Z +572s GETbust=404 GETplain=404 API={"message":"Not Found",...}
... (404 until the end of the poll at +653s)
```

Back to public at 05:02:05Z: `visibility: public`, `has_pages: false`; endpoint `404` and Pages API `404` on every poll up to +136 s.

</details>

<details>
<summary>Settings > Pages wording (pasted by Arthur, verbatim)</summary>

Before the org change, identical on both repositories:

```text
GitHub Pages
GitHub Pages is designed to host your personal, organization, or project pages from a GitHub repository.

Pages on this repository are disabled. Please contact your organization administrators

Visibility
GitHub Enterprise
With a GitHub Enterprise account, you can restrict access to your GitHub Pages site by publishing it privately. You can use privately published sites to share your internal documentation or knowledge base with members of your enterprise. You can try GitHub Enterprise risk-free for 30 days. Learn more about the visibility of your GitHub Pages site.
```

("Learn more" links to <https://docs.github.com/en/enterprise-cloud@latest/pages/getting-started-with-github-pages/changing-the-visibility-of-your-github-pages-site>.)

After the org change, private repository:

```text
GitHub Pages
GitHub Pages is designed to host your personal, organization, or project pages from a GitHub repository.

GitHub Pages
Upgrade or make this repository public to enable Pages
Learn more about GitHub Pages
Visibility
GitHub Enterprise
With a GitHub Enterprise account, you can restrict access to your GitHub Pages site by publishing it privately. [same Enterprise paragraph as above]
```

After the org change, public repository:

```text
GitHub Pages
GitHub Pages is designed to host your personal, organization, or project pages from a GitHub repository.

Build and deployment
Source
Branch
GitHub Pages is currently disabled. Select a source below to enable GitHub Pages for this repository. Learn more about configuring the publishing source for your site.

Visibility
GitHub Enterprise
[same Enterprise paragraph as above]
```

</details>

## Answer

On **GitHub Free**, Pages serves the endpoint anonymously only from a **public** repository. A private repository is refused by the plan, through the API with `422` "Your current plan does not support GitHub Pages for this repository." and in the UI with "Upgrade or make this repository public to enable Pages". This confirms D7: "Pages works from a private repo (public site) on GitHub Pro, Team and Enterprise Cloud; on Free the repo must be public". GitHub's documentation says the same: "If the account that owns the repository uses GitHub Free or GitHub Free for organizations, the repository must be public." The Pro, Team and Enterprise Cloud rows were not run; they rest on the documentation. Private site visibility needs Enterprise Cloud (UI notice and docs).

The served endpoint is `https://alcops.github.io/<repo>/rulesets/essential.ruleset.json`, shape `https://<owner>.github.io/<repo>/rulesets/...`. It answers `200` with `content-type: application/json; charset=utf-8`, `access-control-allow-origin: *` and `cache-control: max-age=600`, within seconds of `deploy-pages` reporting success.

D7 misses a second gate. The organization member privilege **"Pages creation"** blocks creating a site in **any** repository, public included, and blocks owners as well: `422` "GitHub organization administrators disabled Pages creation.", UI "Pages on this repository are disabled. Please contact your organization administrators". It was off on ALCops.

Neither gate is visible from the Actions path. `actions/configure-pages@v5` with `enablement: true` and `GITHUB_TOKEN` fails with "Create Pages site failed. Error: Resource not accessible by integration" in every case, even on a public repository where an owner could create the site. A site must therefore exist before the first Publish run. An admin creates it once:
- through Settings > Pages > Source "GitHub Actions";
- or through `POST /repos/{o}/{r}/pages` with `build_type=workflow`.

When a public repository is later made private on Free:
- the Pages API answers `404` within about 17 s;
- the site keeps serving for about 9.5 min, then answers `404`;
- making the repository public again does not restore it.

## Consequences for blocked work packages

| WP | Consequence | Action taken |
|---|---|---|
| WP05 ([#7](https://github.com/ALCops/rulebook-engine/issues/7)) | `pages` target: the docs state that the repository must be public on Free (private on Pro, Team, Enterprise Cloud), that an org admin must enable the member privilege "Pages creation > Public", and that the site is created once, by an admin, before the first Publish run (`configure-pages` with `GITHUB_TOKEN` cannot create it). The Publish action's preflight calls `GET /repos/{o}/{r}/pages`; on `404` it may try `POST ... build_type=workflow` with the user's token. It maps the messages "Your current plan does not support GitHub Pages for this repository." (make the repo public, upgrade, or use `dist-repo`/`azure-blob`), "GitHub organization administrators disabled Pages creation." (ask an org admin to enable Pages creation) and "Resource not accessible by integration" (enable Pages once in Settings > Pages, Source "GitHub Actions"). The `baseUrl` example is `https://<owner>.github.io/<repo>`. The post-publish reachability check can expect `application/json` and should allow for the 600 s CDN cache. The docs add that making the repository private later unpublishes the endpoints after about 10 minutes (every consumer then gets AL1033) and that the site must be enabled again after it becomes public. | Comment posted on [#7](https://github.com/ALCops/rulebook-engine/issues/7#issuecomment-5976802064); [ARCHITECTURE.md §9](../../ARCHITECTURE.md#9-hosting-targets) and [ADR 0007](../../adr/0007-hosting-is-pluggable-github-pages-is-the-default.md) link this file |

## Not covered

- Pro, Team and Enterprise Cloud: not run (the org is on Free). Those rows rest on GitHub's documentation, not on observation.
- The Settings > Pages wording after the change to private and back was not read; the API (`404`, `has_pages: false`) was used instead.
- `configure-pages` with a token that has repository administration rights (a PAT or a GitHub App token passed as `token:`) was not tried. The owner's `gh` token could create the site, so such a token probably can, but this was not verified. WP05 decides whether the action supports passing one.
- A custom domain (CNAME) on a project site.
- Whether the org's *Pages creation* default is "off" for every new Free organization: observed off on ALCops only.

## Artifacts

The scratch repositories `ALCops/rulebook-spike-pages-private` and `ALCops/rulebook-spike-pages-public` were created 2026-10-03 and are deleted after this spike (with Arthur's confirmation). The run URLs below disappear with them, so the key lines are quoted above.

- Private, first round: <https://github.com/ALCops/rulebook-spike-pages-private/actions/runs/37146279238> (failure in `configure-pages`)
- Public, first round: <https://github.com/ALCops/rulebook-spike-pages-public/actions/runs/37146281888> (failure in `configure-pages`)
- Public, deploy: <https://github.com/ALCops/rulebook-spike-pages-public/actions/runs/37177639903> (success)
- Private, second round: <https://github.com/ALCops/rulebook-spike-pages-private/actions/runs/37178213295> (failure in `configure-pages`)
- Public, Actions only without a site: <https://github.com/ALCops/rulebook-spike-pages-public/actions/runs/37178831776> (failure in `configure-pages`)

Nothing besides this file and the one-sentence links in ARCHITECTURE.md §9 and ADR 0007 is kept in the engine repository.

## References

- GitHub Docs, [Creating a GitHub Pages site](https://docs.github.com/en/pages/getting-started-with-github-pages/creating-a-github-pages-site): "If the account that owns the repository uses GitHub Free or GitHub Free for organizations, the repository must be public." Arthur's reading of the availability note: "GitHub Pages is available in public repositories with GitHub Free and GitHub Free for organizations, and in public and private repositories with GitHub Pro, GitHub Team, GitHub Enterprise Cloud, and GitHub Enterprise Server." This matches what was observed on Free.
- GitHub Docs, [GitHub's plans](https://docs.github.com/en/get-started/learning-about-github/githubs-plans): GitHub Pages is listed for private repositories under GitHub Team, with "To publish a GitHub Pages site privately, you need to have an organization account. Additionally, your organization must use GitHub Enterprise Cloud."
- GitHub Docs, [Managing the publication of GitHub Pages sites for your organization](https://docs.github.com/en/organizations/managing-organization-settings/managing-the-publication-of-github-pages-sites-for-your-organization): Settings > Member privileges > "Pages creation" > "Public". The page speaks of members only; this spike observed that it blocks owners too.
