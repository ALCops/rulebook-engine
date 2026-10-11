# Getting started

From "Use this template" to published endpoints your AL projects can use: create the repository, fill in the settings, turn on GitHub Pages, add the write token, publish once and check the result. Then pick the walkthrough for your consumer.

> **Status:** written 2026-10-10 with WP11 of the engine ([#13](https://github.com/ALCops/rulebook-engine/issues/13)). Every step links the page that holds the details. The steps follow the template's own README and the pages written with the earlier work packages; this page adds no behaviour of its own.

## Contents

1. [What you need](#1-what-you-need)
2. [Create the repository](#2-create-the-repository)
3. [Turn on GitHub Pages](#3-turn-on-github-pages)
4. [Fill in the settings](#4-fill-in-the-settings)
5. [Add the write token](#5-add-the-write-token)
6. [Publish](#6-publish)
7. [Check the result](#7-check-the-result)
8. [What you got](#8-what-you-got)
9. [Next steps](#9-next-steps)
10. [Troubleshooting](#10-troubleshooting)

## 1. What you need

- **A GitHub plan that serves Pages for the repository.** On GitHub Free the rulebook repository must be public; a private repository needs GitHub Pro, Team or Enterprise Cloud. The endpoints are public either way, because the AL compiler fetches them without signing in ([hosting.md](hosting.md) section 2).
- **Pages creation allowed** in your organization: an owner turns on *Pages creation > Public* under Organization settings > Member privileges.
- **Admin rights on the new repository**, to turn on Pages and to add secrets.
- **A GitHub App or a personal access token** for the workflows that write to the repository ([ghtokenworkflow.md](ghtokenworkflow.md)). An organization that runs AL-Go for GitHub can reuse its `GHTOKENWORKFLOW` secret and App.
- **PowerShell 7** on the machine where you set up AL projects later, for the init script that downloads the skeletons ([al-project.md](al-project.md) section 3).

## 2. Create the repository

On https://github.com/ALCops/rulebook press **Use this template > Create a new repository**, pick the owner (your organization), a name such as `rulebook`, and the visibility from section 1. One repository per organization holds the rules of every AL project.

If Publish runs on the first commit of the new repository, it fails with "baseUrl is empty" because you have not set it yet. That is expected; step 6 runs it again.

## 3. Turn on GitHub Pages

In the repository, open Settings > Pages and set Build and deployment > Source to **GitHub Actions**. Someone with admin rights does this once; the Publish workflow never creates the site itself ([hosting.md](hosting.md) section 2, step 1). Do it before the settings change of step 4 is merged, because that merge starts Publish.

## 4. Fill in the settings

Everything you set lives in `.github/Rulebook-Settings.json`. Change it in a pull request, so Validate checks it before the merge.

1. **`baseUrl`**: the address the site will have, `https://`, all lowercase, no trailing slash: `https://<owner>.github.io/<repository>`, for example `https://contoso.github.io/rulebook`, or your custom domain ([hosting.md](hosting.md) section 2).

   ```json
   "baseUrl": "https://contoso.github.io/rulebook"
   ```

2. **`publish.target`** stays `pages`. The other targets are planned ([hosting.md](hosting.md) section 4).
3. **`quarantine`**: which stages hold back diagnostics that a new compiler or ALCops version adds. There is no default: the daily scan stops until both keys are set. The typical choice holds them back in the editor and in pull request builds and lets builds against the next platform show them ([quarantine.md](quarantine.md) section 2):

   ```json
   "quarantine": { "stages": ["default", "ci"], "prereleaseStages": ["default", "ci"] }
   ```

4. **`twins`**, optional: `both` (shipped) keeps the per-tenant and the AppSource rule of the 17 pairs that check the same thing; `pte` or `appsource` keeps only one side when every project you build is of that kind ([pte-or-appsource.md](pte-or-appsource.md) section 7).
5. **`levels` and `stages`**: leave them as shipped for now. Adding, renaming or removing levels and stages is in [levels.md](levels.md).

Merge the pull request. The merge changes the settings on `main`, so Publish runs by itself (step 6).

## 5. Add the write token

The Update Rulebook System Files, Scan Diagnostics and Change Rule workflows push branches and open pull requests, which the workflow token cannot do for workflow files. They read the token from the secret `GHTOKENWORKFLOW`: a GitHub App (recommended) or a personal access token. Set it up as described in [ghtokenworkflow.md](ghtokenworkflow.md) sections 2 to 4. Validate and Publish do not need it.

## 6. Publish

Run Actions > **Publish** > Run workflow on `main` (it also runs by itself on every push to `main` that changes `rulesets/`, `skeletons/`, the settings or the workflow). It validates the rulebook, publishes the endpoints, the skeletons with your `baseUrl` filled in, `rulebook.json` and an index page, and waits until every URL serves the committed file ([hosting.md](hosting.md) section 1).

## 7. Check the result

Open these three addresses in a browser, with your `baseUrl`:

1. `<baseUrl>/`: the index page, one table per stage, one row per level, with the endpoint URL and a skeleton download link.
2. `<baseUrl>/rulebook.json`: the levels and stages of your rulebook.
3. `<baseUrl>/rulesets/strict.ruleset.json`: an endpoint, a JSON file with a `rules` array.

When all three open, your rulebook is live. Optionally, run Actions > **Update Rulebook System Files** once: it records the template version in `templateSha` and shows that the write token works ([updating.md](updating.md) section 2).

## 8. What you got

| Path | What it is | On update from the template |
|---|---|---|
| `.github/Rulebook-Settings.json` | Your settings. | Kept; only `templateUrl`, `templateSha` and `$schema` change. |
| `.github/workflows/` | Validate, Publish, Update Rulebook System Files, Scan Diagnostics and Change Rule. | The workflows the template ships are replaced by the template version; workflows of your own are never touched. |
| `base/`, `stages/`, `base/twins.json` | The shipped levels and stages. | Replaced; change rules in `overrides.json` instead. |
| `overrides.json`, `quarantine.*.json`, `catalog/` | Your own rule decisions, the held-back diagnostics, the known diagnostics. | Never touched. |
| `rulesets/`, `skeletons/` | The generated endpoints and skeletons. | Regenerated from the files above. |
| `docs/` | This documentation, as a copy in your repository. | Kept current: a page you never edited follows the template, a page you edited is kept and listed in the update pull request; `"docs": { "updateMode": "overwrite" }` always takes the template's pages ([updating.md](updating.md) section 1). |
| `README.md` | Your repository's front page. | Never touched. |

## 9. Next steps

- Point your AL projects at the endpoints: [VS Code](vscode.md), [AL-Go for GitHub](al-go.md) or [Azure DevOps and other pipelines](azure-devops.md). The project side (the `.rulebook/` folder, exceptions, `suppressWarnings`) is [al-project.md](al-project.md).
- Projects that build per-tenant extensions or AppSource apps opt out of the other kind's rules: [pte-or-appsource.md](pte-or-appsource.md).
- Moving from an existing ruleset tree: [migration.md](migration.md).
- From here the workflows run by themselves: the daily scan keeps one pull request with new diagnostics ([quarantine.md](quarantine.md)), Validate tells you when a template update is available ([updating.md](updating.md)), and the Change Rule form changes a rule for your organization ([changing-a-rule.md](changing-a-rule.md)).

## 10. Troubleshooting

| Message | Cause | Fix |
|---|---|---|
| Publish: "baseUrl is empty" | `baseUrl` is not set; expected on the first commit of a new repository. | Step 4; the message proposes the value for your repository. |
| Publish: "GitHub Pages is not enabled for this repository" | Step 3 was skipped, or the plan or the organization does not allow Pages for this repository. | Step 3, then run Publish again; on GitHub Free check that the repository is public and that Pages creation is allowed ([hosting.md](hosting.md) section 3). |
| Publish: "The plan of this account does not support GitHub Pages for a private repository" | A private repository on GitHub Free. | Make the repository public or upgrade the plan. |
| The index page or an endpoint answers 404 or redirects | Publish did not end green, `baseUrl` is not the site's final address, or a cache still serves the old state. | Check the Publish run and its messages ([hosting.md](hosting.md) section 3); check `baseUrl`; wait up to 10 minutes and reload. |
| Every AL project fails with AL1033 a few minutes after the repository was made private | GitHub Free removes the Pages site of a private repository. | Make it public again, turn Pages on again (step 3) and run Publish ([hosting.md](hosting.md) section 2). |
| Scan Diagnostics: "Set quarantine.stages and quarantine.prereleaseStages in .github/Rulebook-Settings.json. ..." | The quarantine policy of step 4 is not set. | Set both keys ([quarantine.md](quarantine.md) section 2). |
| Update, Scan or Change Rule: "The GHTOKENWORKFLOW secret is needed ..." | The secret of step 5 is missing. | Create it ([ghtokenworkflow.md](ghtokenworkflow.md) section 4). |
