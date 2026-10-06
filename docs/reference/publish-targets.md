# Publish targets

How the Publish action gets an organization's endpoints to a URL the AL compiler can fetch, how to set up each target, what the action checks before and after the deploy, and what the live run showed. The design is in [ARCHITECTURE.md](../ARCHITECTURE.md) sections 7.2 and 9; the decision that Publish never commits is [D42](../adr/0042-publish-is-a-gate-and-never-commits.md).

> **Status:** written by WP05 ([#7](https://github.com/ALCops/rulebook-engine/issues/7)). v1 implements the `pages` target only. `dist-repo`, `azure-blob` and `gist` are backlog: [#55](https://github.com/ALCops/rulebook-engine/issues/55), [#56](https://github.com/ALCops/rulebook-engine/issues/56) and [#57](https://github.com/ALCops/rulebook-engine/issues/57).

---

## Contents

1. [Targets](#1-targets)
2. [GitHub Pages, step by step](#2-github-pages-step-by-step)
3. [Preflight messages](#3-preflight-messages)
4. [The reachability check](#4-the-reachability-check)
5. [Action reference](#5-action-reference)
6. [Live run of 2026-10-06](#6-live-run-of-2026-10-06)
7. [Backlog targets](#7-backlog-targets)

---

## 1. Targets

| `publish.target` | Endpoint URL | Status |
|---|---|---|
| `pages` (default) | `https://<owner>.github.io/<repo>/rulesets/...`, or a custom domain | Implemented |
| `dist-repo` | `https://raw.githubusercontent.com/<owner>/<dist>/<branch>/rulesets/...` | Backlog, [#55](https://github.com/ALCops/rulebook-engine/issues/55) |
| `azure-blob` | `https://<account>.blob.core.windows.net/<container>/rulesets/...` or the static website endpoint | Backlog, [#56](https://github.com/ALCops/rulebook-engine/issues/56) |
| `gist` | `https://gist.githubusercontent.com/<user>/<id>/raw/<file>` | Backlog, [#57](https://github.com/ALCops/rulebook-engine/issues/57) |

The settings schema accepts all four, so an organization's settings stay valid while a target is in the backlog. Publish fails a target that is not implemented with `Publish target '<target>' is not implemented yet; see <issue>`.

Every target publishes the same files ([naming.md](naming.md) section 4): `index.html`, the levels x stages endpoints of `rulesets/` as committed, and the skeletons with `{BASEURL}` rendered. A file that is no longer staged (a removed stage or level, a stray file in `rulesets/`) is not published; on Pages a deploy replaces the whole site, so it disappears with the next run.

## 2. GitHub Pages, step by step

### Prerequisites

- **Visibility and plan.** On GitHub Free the rulebook repository must be **public**. A private repository can serve a public Pages site on GitHub Pro, Team or Enterprise Cloud (per GitHub's docs, not observed); a private site needs Enterprise Cloud ([spike (d)](spikes/d-pages-private-repo.md)).
- **Organization policy.** An organization owner must allow *Pages creation > Public* under Organization settings > Member privileges. With it off, nobody (owners included) can create a site; an existing site keeps serving.

### One-time setup

1. **Enable Pages once**, by someone with admin rights on the repository: Settings > Pages > Build and deployment > Source **GitHub Actions**. The same from the command line: `gh api -X POST repos/<owner>/<repo>/pages -f build_type=workflow` (answers `201 Created`). Publish never creates the site itself; its workflow token has no admin rights, and `actions/configure-pages` with `enablement: true` fails with "Resource not accessible by integration" for the same reason (spike (d)).
2. **Set `baseUrl`** in `.github/Rulebook-Settings.json` to the site address without a trailing slash: `https://<owner>.github.io/<repo>`, all lowercase, or `https://<owner>.github.io` for a repository named `<owner>.github.io`. With `baseUrl` empty, Publish fails and proposes this value. Commit the change in a pull request.
3. **Run Publish**: the merge to `main` triggers it, or run it by hand (Actions > Publish > Run workflow). The first run creates the `github-pages` environment if it does not exist yet; this also happens on a run that fails the preflight.

After the run, `<baseUrl>/` lists every endpoint and skeleton. Copy a skeleton from there into the AL project; the repository copies under `skeletons/` keep `{BASEURL}`.

### The workflow

`template/.github/workflows/Publish.yaml`: on push to `main` and `workflow_dispatch`; `permissions: contents: read, pages: write, id-token: write`; `concurrency: publish-pages` without cancelling a running deploy; one job in the `github-pages` environment that checks out with full history, runs the Validate action and then the Publish action. The workflow holds no write token: Publish refuses stale endpoints instead of committing them (D42). The fix for a failing run is a pull request.

### Custom domain

An Actions-built Pages site takes its custom domain from Settings > Pages > Custom domain (with the DNS records GitHub lists there); a `CNAME` file in the published folder is ignored, so Publish does not write one. After the domain is set, change `baseUrl` to `https://<custom domain>` in a pull request. Until then the preflight warns that the site is served at another address than `baseUrl`, and the skeletons keep pointing at the `github.io` address, which GitHub then redirects to the custom domain. Neither a redirect nor a custom domain has been tested with the compiler's fetch and anti-SSRF policy ([naming.md](naming.md) section 4), so set `baseUrl` to the domain the site is really served from and compile once against it.

### Cache

Pages answers with `Cache-Control: max-age=600`. In the live run (section 6) the CDN served a changed endpoint and dropped a removed one within about 10 s of the deploy, so a client that does not cache sees the change right away; a client or proxy that honours `max-age` may keep the old file for up to 10 minutes. The reachability check waits up to 660 s for that reason. VS Code re-reads the ruleset on Developer: Reload Window or a change to `app.json` ([spike (e)](spikes/e-vscode-refetch.md)).

### When the repository goes private later

On GitHub Free a public repository made private loses its Pages site: the endpoints answered `404` about 9.5 minutes after the change (spike (d)), and every consumer then compiles with AL1033. Making the repository public again does **not** restore the site; enable Pages again (step 1) and run Publish.

## 3. Preflight messages

Before the deploy, Publish calls `GET /repos/{owner}/{repo}/pages` with the workflow token and maps the answer (`Get-PagesPreflightResult`). Every row but the first fails the run before anything is uploaded.

| Answer | Message (shortened) | What to do |
|---|---|---|
| `200`, `build_type: workflow` | GitHub Pages is enabled with Source GitHub Actions. | Nothing. When `html_url` differs from `baseUrl` (a custom domain), a **warning**: set `baseUrl` to the address the site is served at. |
| `200`, `build_type: legacy` | The site builds from a branch. | Settings > Pages > Source **GitHub Actions**. |
| `404` | GitHub Pages is not enabled for this repository. Enable it once (Source GitHub Actions); on a Free organization the repository must be public and an owner must allow Pages creation. Publish never creates the site itself. | Section 2, step 1. |
| "Your current plan does not support GitHub Pages for this repository." | The plan does not support Pages for a private repository. | Make the repository public, upgrade, or wait for `dist-repo` ([#55](https://github.com/ALCops/rulebook-engine/issues/55)). |
| "GitHub organization administrators disabled Pages creation." | An organization administrator has disabled Pages creation. | An owner allows Member privileges > Pages creation (Public). |
| `403` or "Resource not accessible by integration" | The workflow token cannot read the Pages site. | Give the job `pages: write` and `id-token: write`; make sure Pages is enabled. |
| Anything else | Reading the GitHub Pages site failed with HTTP `<status>`. | Rerun; check [githubstatus.com](https://www.githubstatus.com). |

The two `422` messages come from the create call (`POST /pages`) in spike (d); a `GET` answers `404` in both situations. They are mapped anyway, for a caller that passes a create response.

## 4. The reachability check

After `deploy-pages` reports success, `Test-RulebookEndpoints` requests every endpoint and skeleton URL (24 in the shipped set; `index.html` is not checked) with a 15 s timeout per request, as the compiler does. A URL passes on HTTP 200 with a body equal to the staged file (UTF-8, compared ordinally, line ends included). Pending URLs are retried every 30 s until `checkWindowSeconds` (default 660) is used up. A URL still `missing` (404), `different`, `timeout` or `error` then fails the job with one annotation:

```
::error title=Publish::https://contoso.github.io/rulebook/rulesets/strict.ci.ruleset.json is missing (HTTP 404) after 23 attempt(s) in 660.4 s. Consumers of this URL compile with AL1033 (alc aborts; VS Code falls back to the analyzer defaults).
```

The job summary lists every URL with its result, HTTP status, attempts and seconds. `skipCheck: 'true'` skips the check.

## 5. Action reference

`ALCops/rulebook-engine/actions/Publish` (composite; `@main` in `template/`, pinned to `@v1` by the deploy step of WP13).

| Input | Default | Meaning |
|---|---|---|
| `repositoryRoot` | `.` | The rulebook repository, relative to the workspace. |
| `baseUrl` | empty | Overrides `baseUrl` of the settings (https, no trailing slash). |
| `target` | empty | Overrides `publish.target`. Only `pages` is implemented. |
| `deploy` | `'true'` | `'false'` stages only: no preflight, no deploy, no check. The engine's `publish-action` CI job runs this way. |
| `skipCheck` | `'false'` | `'true'` skips the reachability check. |
| `checkWindowSeconds` | `'660'` | How long the check waits for every URL. |
| `token` | `github.token` | Token for the Pages preflight. |

| Output | Meaning |
|---|---|
| `stagingPath` | The staging folder (`$RUNNER_TEMP/rulebook-publish`). |
| `pageUrl` | The site URL from `deploy-pages`, or `<baseUrl>/` when nothing was deployed. |

Steps: `Publish.ps1 -Phase Stage` (settings, target, base URL, site notice, preflight, `New-RulebookPublishStage`, the manifest `$RUNNER_TEMP/rulebook-publish.manifest.json` next to the staging folder, the URL list in the job summary), `actions/upload-pages-artifact@v5`, `actions/deploy-pages@v5`, `Publish.ps1 -Phase Check`. The module is `modules/Rulebook.Publish`; its tests are `tests/Rulebook.Publish.Tests.ps1` and `tests/Publish.Action.Tests.ps1`.

## 6. Live run of 2026-10-06

A public scratch repository under a personal account, `Arthurvdv/rulebook-e2e-publish`, seeded from the engine's `template/` on branch `wp05/publish` with both workflows pointing at `@wp05/publish` and `baseUrl` set to `https://arthurvdv.github.io/rulebook-e2e-publish`. The ALCops organization has Pages creation off, so the run could not use an organization repository. Times are UTC.

| Step | Run | Result |
|---|---|---|
| Push of the seed, Pages not enabled | [37451961423](https://github.com/Arthurvdv/rulebook-e2e-publish/actions/runs/37451961423) | Failed in the preflight after 26 s: `Pages preflight: HTTP 404. GitHub Pages is not enabled for this repository. Enable it once: https://github.com/Arthurvdv/rulebook-e2e-publish/settings/pages, Source 'GitHub Actions'. ...`. Validate passed first; the site notice was printed; the `github-pages` environment was created by this run. |
| `gh api -X POST .../pages -f build_type=workflow` at 10:46:56 | | `201 Created`, `build_type: workflow`, `html_url` `https://arthurvdv.github.io/rulebook-e2e-publish/` |
| `workflow_dispatch` at 10:47:00 | [37452048589](https://github.com/Arthurvdv/rulebook-e2e-publish/actions/runs/37452048589) | Success in 35 s. Preflight `HTTP 200`; staged 12 endpoints, 12 skeletons and `index.html`; `deploy-pages` "Reported success!" at 10:47:28; check: 24 of 24 URLs on the first attempt, the last after 2.4 s. |
| `curl` from a workstation | | All 12 endpoints and 12 skeletons `200`, `application/json; charset=utf-8`, bodies byte-equal to the repository files (skeletons after replacing `{BASEURL}`); the repository skeletons still contain `{BASEURL}`; `<baseUrl>/` `200 text/html` with 12 endpoint links; headers `Cache-Control: max-age=600`, `X-Cache: HIT`. |
| Push removing the `vNext` stage (settings, `stages/vnext.json`, `quarantine.vnext.json`, the 4 `*.vnext` skeletons, endpoints regenerated with `Update-RulebookEndpoints`) and an override `AA0137` `Error` on `strict` / `ci`, at 10:49:41 | [37452356134](https://github.com/Arthurvdv/rulebook-e2e-publish/actions/runs/37452356134) | Success in 32 s. Staged 8 endpoints and 8 skeletons; `deploy-pages` success at 10:50:11; check: 16 of 16 on the first attempt after 1.4 s, the changed `strict.ci` endpoint included. |
| Poll from a workstation every 10 s from the push | | `rulesets/strict.vnext.ruleset.json` and `skeletons/strict.vnext.ruleset.json` `404`, and the new `strict.ci` body, all at 10:50:18: the first poll after the deploy, at most 7 s after it. The index page no longer mentions `vnext`. |

**AL compile** (Windows, `al` 30.0.42.11883-beta, `Microsoft_System_28.0.54476.0.app`, one codeunit with an unused local variable, CodeCop, `/enableexternalrulesets`, `/ruleset:` the downloaded published skeleton):

- `strict.ci` skeleton: exit 0 with the `.app`, no AL1033; `AA0137` at Warning (its analyzer default: `strict.ci` does not list it).
- `essential.default` skeleton: exit 0, no diagnostics (`essential` sets `AA0137`, `AA0215` and `AA0247` to `None`).
- `strict.ci` skeleton after the override was published: `error AA0137`, exit 1, no `.app`. The organization's override reached the compiler through Pages.

The number of fetches per compile was not measured here (no `strace` on Windows); [spike (a)](spikes/a-hosts-and-skeleton-include.md) measured one request per compile on `github.io`. The failure path of the check (a missing or different URL) is covered by the Pester tests, not by the live run.

## 7. Backlog targets

| Target | Open points | Issue |
|---|---|---|
| `dist-repo` | Write token for the second repository (`GHTOKENWORKFLOW`, O4), one commit that replaces the content so removed files disappear, the 300 s raw cache, `index.html` served as `text/plain`. | [#55](https://github.com/ALCops/rulebook-engine/issues/55) |
| `azure-blob` | OIDC login, static website (`$web`) or a container with anonymous read, deleting stale blobs (`upload-batch` does not), content types, the anti-SSRF policy against Azure hosts. | [#56](https://github.com/ALCops/rulebook-engine/issues/56) |
| `gist` | No folders: `rulesets/strict.ci.ruleset.json` and `skeletons/strict.ci.ruleset.json` collide, so the URL scheme needs a decision before any code. | [#57](https://github.com/ALCops/rulebook-engine/issues/57) |

Each issue carries the acceptance criterion moved from #7: a documented, tested manual run, and removal of a file from the published location.
