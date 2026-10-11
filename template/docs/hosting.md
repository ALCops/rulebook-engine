# Hosting your endpoints

Your AL projects fetch their rules from URLs. This page explains where those URLs come from: the Publish workflow puts your endpoints, the skeletons, `rulebook.json` and an index page on GitHub Pages and then checks that every URL serves what you committed.

> **Status:** written 2026-10-06 with the Publish work package of the engine ([WP05, #7](https://github.com/ALCops/rulebook-engine/issues/7)). GitHub Pages is the only host available in version 1. The contributor reference, with the preflight messages and the live test run, is the engine's [publish-targets.md](https://github.com/ALCops/rulebook-engine/blob/main/docs/reference/publish-targets.md).

## Contents

1. [What gets published](#1-what-gets-published)
2. [GitHub Pages](#2-github-pages)
3. [Troubleshooting](#3-troubleshooting)
4. [Other hosts](#4-other-hosts)

## 1. What gets published

| URL | Content |
|---|---|
| `<baseUrl>/` | An index page: how to set up an AL project with the init script, then one table per stage, one row per level, with the endpoint URL, the number of rules it lists and a download link for the skeleton. |
| `<baseUrl>/rulebook.json` | The levels and stages of your rulebook, machine-readable; the init script reads it ([al-project.md](al-project.md)). |
| `<baseUrl>/rulesets/<level>.ruleset.json` and `<baseUrl>/rulesets/<level>.<stage>.ruleset.json` | The endpoints, exactly as committed in `rulesets/`. The `default` stage has no suffix. |
| `<baseUrl>/skeletons/<level>.<stage>.ruleset.json` | The skeletons, with your `baseUrl` filled in. The copies in your repository keep the placeholder `{BASEURL}`. |

Nothing else is published: not your level and stage files, not `overrides.json`, the quarantine files, the catalog or the settings. A level or stage you remove from the settings disappears from the site on the next run.

Publish never changes your repository. It publishes what is committed, and it stops when `rulesets/` is out of date instead of regenerating it. Endpoints only change through a pull request, where the Validate workflow shows the effective change per endpoint.

## 2. GitHub Pages

### Before you start

- **Public repository on GitHub Free.** On the Free plan GitHub Pages works for public repositories only. A private repository can serve a public site on GitHub Pro, Team or Enterprise Cloud. Your endpoints are public either way: the AL compiler fetches them without signing in.
- **Pages creation allowed.** In an organization, an owner must allow *Pages creation > Public* under Organization settings > Member privileges. While it is off, nobody can create a site, owners included.

### One-time setup

1. **Turn on Pages.** In your rulebook repository, open Settings > Pages and set Build and deployment > Source to **GitHub Actions**. Someone with admin rights on the repository does this once. The Publish workflow never creates the site itself.
2. **Set `baseUrl`** in `.github/Rulebook-Settings.json` to the address of the site, all lowercase, without a trailing slash:
   - `https://<owner>.github.io/<repository>`, for example `https://contoso.github.io/rulebook`;
   - `https://<owner>.github.io` if the repository is named `<owner>.github.io`;
   - your custom domain, if you set one (below).
3. **Merge the change into `main`.** The Publish workflow runs on every push to `main` that changes `rulesets/`, `skeletons/`, the settings or the workflow itself, and you can run it by hand under Actions > Publish. After the first run, `baseUrl` opens the index page. To confirm the site works, open `<baseUrl>/`, `<baseUrl>/rulebook.json` and one endpoint such as `<baseUrl>/rulesets/strict.ruleset.json`: all three must open without a redirect.

Then set up your AL projects: the index page shows the two commands of the init script, which downloads the skeletons of a level into `.rulebook/`, one file per stage. See [al-project.md](al-project.md).

### Custom domain

Set the domain under Settings > Pages > Custom domain and add the DNS records GitHub shows there. Then change `baseUrl` to `https://<your domain>` in a pull request. Until you do, Publish warns that the site is served at another address than `baseUrl`, and the check after the deploy fails right away with a message that the URL answers with a redirect: the old `github.io` address now redirects to your domain, and the AL compiler does not follow redirects. Compile one project against the new address before you roll it out; custom domains have not been tested with the compiler's network checks yet.

Renaming the repository or the owner changes the `github.io` address the same way: update `baseUrl` and publish again.

### How fast changes arrive

Publish waits until every URL serves the new file, for up to 11 minutes. In practice GitHub Pages served a changed or removed endpoint within seconds of the deploy. Pages tells clients they may cache a file for 10 minutes, so a proxy or tool that caches can show the old rules for up to that long. VS Code reads the ruleset again after **Developer: Reload Window** or a change to `app.json`.

### If the repository goes private

On GitHub Free a public repository that is made private loses its Pages site after about ten minutes. From then on every AL project that uses your endpoints fails to compile (AL1033). Making the repository public again does not bring the site back: turn on Pages again (step 1) and run Publish.

## 3. Troubleshooting

Publish checks before it deploys and after it deploys. Its message says what to change; the first column is the start of the message.

| Message | Cause | Fix |
|---|---|---|
| `baseUrl is empty` | `baseUrl` is not set; expected on the first commit of a new repository. | Set `baseUrl` as in step 2; the message proposes the value for your repository. |
| `GitHub Pages is not enabled for this repository` | Step 1 was not done, or the plan or the organization does not allow Pages here, or the workflow lost `pages: write`. | Step 1. On GitHub Free, also check that the repository is public and that Pages creation is allowed. If Pages is already on, check that the Publish workflow still grants `pages: write`. |
| `The GitHub Pages site of this repository builds from a branch` | The Pages source is a branch, not GitHub Actions. | Settings > Pages > Source: **GitHub Actions**. |
| `The plan of this account does not support GitHub Pages for a private repository` | A private repository on GitHub Free. | Make the repository public or upgrade the plan. |
| `An organization administrator has disabled Pages creation` | The organization policy forbids new Pages sites. | Ask an organization owner to allow Pages creation (Public). |
| `The committed endpoints do not match their inputs` | `rulesets/` is out of date. | Open a pull request that regenerates it; the Validate workflow names the files. |
| `Publish target '...' is not implemented yet` | `publish.target` names a planned target. | Set `publish.target` to `pages` (section 4). |
| `... is missing`, `... serves a different body`, `... answers with a redirect` | After the deploy, a URL did not serve the committed file. | Check `baseUrl` (a redirect means it is not the final address), then run Publish again. |

## 4. Other hosts

The settings already accept three more `publish.target` values. They are planned, not available: Publish fails with a link to the issue when one is selected.

| Target | Endpoints served from | Status |
|---|---|---|
| `dist-repo` | A separate public repository, through `raw.githubusercontent.com`. Intended to let the rulebook repository stay private on any plan. | Planned, [rulebook-engine#55](https://github.com/ALCops/rulebook-engine/issues/55) |
| `azure-blob` | Azure Blob Storage, after an OIDC login from the workflow. | Planned, [rulebook-engine#56](https://github.com/ALCops/rulebook-engine/issues/56) |
| `gist` | A GitHub gist. Needs a decision on the URL scheme first, because a gist has no folders. | Planned, [rulebook-engine#57](https://github.com/ALCops/rulebook-engine/issues/57) |
