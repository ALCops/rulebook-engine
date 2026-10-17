# The dashboard

The Publish workflow can build a small website out of your rulebook and put it at the same address as your endpoints. Each stage gets a grid with one row per rule and one column per level, and each cell shows the action that endpoint gives the rule and which input decided it. There is a page for every stage, every level and every rule, and a setup page for AL projects. From a cell you can put a change in a cart, and the cart opens an issue in your rulebook repository with the change set already filled in. The site reads your rules but never changes them: a maintainer applies a submitted change set.

> **Status:** written 2026-10-17 with the dashboard site of the engine ([#16](https://github.com/ALCops/rulebook-engine/issues/16)). Everything below is stated by the files in `site/`, the Publish action and the issue form `.github/ISSUE_TEMPLATE/rulebook-change.yml`; the design, the data contract and the decisions are in the engine's [dashboard.md](https://github.com/ALCops/rulebook-engine/blob/main/docs/dashboard.md). Publishing in general is [hosting.md](hosting.md); the workflow that applies a rule change is [changing-a-rule.md](changing-a-rule.md).

## Contents

1. [What the site shows](#1-what-the-site-shows)
2. [Turning it on](#2-turning-it-on)
3. [Changing a rule from the site](#3-changing-a-rule-from-the-site)
4. [What is public](#4-what-is-public)
5. [Adapting `site/`](#5-adapting-site)
6. [The data files](#6-the-data-files)
7. [Troubleshooting](#7-troubleshooting)

## 1. What the site shows

| Page | Address | Content |
|---|---|---|
| Matrix | `<baseUrl>/` and `<baseUrl>/stages/<stage>/` | The grid of one stage: one row per rule, grouped by analyzer, in the id order of the endpoints; one column per level in settings order. `<baseUrl>/` shows the first stage of your settings (`default` in the shipped settings), and the stage links at the top switch between stages. A stage page also has the stage summary below the grid: the stage file, its entries with the levels where an entry has no effect, the counts per level and the ids the stage quarantines. |
| Level | `<baseUrl>/levels/<level>/` | The level file, the chain of levels it is built on, the counts per stage, and the entries of the level file grouped by analyzer, each with the action before it ("From"), the new action ("To") and its justification. Every level of your settings gets a page, your own levels included. |
| Rule | `<baseUrl>/rules/<id>/` (lowercase, for example `rules/lc0031/`) | The title, the analyzer, the default severity and whether the analyzer enables the rule by default, the documentation link, the justifications of the level and stage files that name the rule, and the cell of every level and stage. |
| Setup | `<baseUrl>/setup/` | **Set up an AL project**, the section the plain index page has: the two commands of the init script with your first level as the example, the `al.ruleSetPath` and AL-Go `rulesetFile` lines, the levels, and per stage a table with the endpoint URL, the number of ids it lists and the skeleton download for every level ([al-project.md](al-project.md)). The header and the legend link to it. |

A cell shows the action and a marker for the input that decided it:

| Marker | Decided by |
|---|---|
| no marker | a level file, or the analyzer default |
| dot | the stage file |
| ring | the twins rule of your settings ([pte-or-appsource.md](pte-or-appsource.md)) |
| badge `O` | an entry of `overrides.json` ([overrides.md](overrides.md)); point at the badge to see the entry's position in the file, counted from 0 |
| badge `Q` | the quarantine of the stage ([quarantine.md](quarantine.md)) |

The block **What the cells mean** below every grid repeats this legend and links to this page; so does the **Help** link in the header. Above the grid of a matrix page are four filters: analyzer, action, the deciding input (override, quarantine, stage file, twins rule, level file, analyzer default) and a text field for the id or the title, with a row counter. The filters are stored in the address after `#`, for example `#source=override&q=LC00`, so a link with them opens the same view, and the stage links keep them when you switch stages.

Without JavaScript the grids and pages are still complete; the filters, the popover and the cart are hidden then.

## 2. Turning it on

The shipped settings have the site on:

```json
"site": { "enabled": true, "includeJustifications": false, "updateMode": "skip" }
```

1. **Pages and `baseUrl`.** The site is published the same way as the endpoints: GitHub Pages with Source GitHub Actions and `baseUrl` set ([hosting.md](hosting.md) section 2). The site needs nothing else in the repository. You do not have to install Hugo: the Publish action installs the version it pins on the runner before it builds the site.
2. **Publish.** The first run happens when you merge the `baseUrl` change ([hosting.md](hosting.md) section 2, step 3); Publish waits for the deployment to serve (up to about 11 minutes, [hosting.md](hosting.md#how-fast-changes-arrive) section 2, How fast changes arrive). The Publish workflow builds the site on every run while `site.enabled` is `true`. It runs on a push to `main` that changes `rulesets/`, `skeletons/`, `site/`, `catalog/diagnostics.json`, the settings or the workflow itself. A change that touches none of these does not start it: for example an override that changes no endpoint (only its justification, or an entry a more specific one hides), a quarantine edit that changes no endpoint, or a new justification in a level file. Run Actions > **Publish** > Run workflow for such a change. Until then the site shows the old state.
3. **Check.** Open `<baseUrl>/`: it shows the grid of the first stage. Publish already checked after the deploy that the pages of the site, `rulebook.json` and `catalog/diagnostics.json` serve what it built (every stage and level page, the setup page and the first rule page are requested); a failed check fails the run, as for the endpoints ([hosting.md](hosting.md) section 3).

With the site on, `<baseUrl>/` is the matrix, and the setup content of the plain index page moves to `<baseUrl>/setup/`. The endpoints, the skeletons and `rulebook.json` stay at their addresses, so the init script and every AL project keep working. With `"enabled": false` Publish publishes the plain index page at `<baseUrl>/`, with the setup section, and builds no site; the data files of section 6 are still published.

## 3. Changing a rule from the site

1. **Click a cell**, or focus it with Tab and press Enter or Space. A popover offers the five actions `Error`, `Warning`, `Info`, `Hidden` and `None`; **Reset** only on a cell with the `O` badge (it removes the override that decides the cell); **Release** only on a cell with the `Q` badge (it releases the id from the quarantine of that stage). A stage page also has a Release button next to every id in its quarantine list. Escape closes the popover. Rule pages have the same popover.
2. **The cart** opens on the right with the change, and the **Cart** button in the header shows how many changes it holds. An action becomes a change for exactly that level and stage; Reset becomes a removal of the whole override entry, with that entry's levels and stages; Release becomes a release for that stage. Per change you can:
   - tick **all levels** or **all stages** to widen it to `*` (a removal names one entry and cannot be widened); untick to go back;
   - type a justification (actions only; it goes into the override entry);
   - remove it.

   One more field, **Note for the issue**, is optional and goes into the issue. A second change of the same kind for the same rule, levels and stages replaces the first. A change widened or narrowed onto the selection of another change replaces that one, and the status line says so.
3. **Before and after.** Every change lists the cells it touches, each with the action and deciding input before and after. An action shows the chosen action as an override on every matching cell. A removal or a release shows what the cell would have without the override or the quarantine, which the Publish action computed with the generator's own rules. A change that alters no cell says "No action changes: the change would be a no-op." One limit: a widened action shows the chosen action on every cell, but where a more specific override already decides a cell (an entry with exactly that level or stage), that entry still wins after the change. The pull request that applies the change shows the real result.
4. **The size.** The cart measures the issue link it will open against 7372 bytes: "`<n>` of 7372 bytes of the issue link". GitHub refuses a link of 8192 bytes or more. That fits about 28 changes with a 39-character justification each, or 46 without (a longer justification or a note fits fewer). Over the limit the text turns red and **Submit on GitHub** is disabled.
5. **Submit on GitHub** opens the issue form **Rulebook change** of your repository in a new tab, with the change set in the field **Changes** (JSON) and your note in **Note**. Read it and click **Submit new issue**; you need to be signed in to GitHub and allowed to open issues in the repository. Back on the site, the cart asks "Did GitHub open the filled form? Clear the cart?"; it is emptied only when you confirm.
6. **Too large for one link.** Over the limit the cart shows **Submit in parts**, which splits the cart into parts that fit, in the order of the changes, each with the note: every click opens the next part in a new tab ("Opened part 1 of 3."). A change that is too large for a link on its own is skipped. When every part has opened, the cart asks whether to clear it; when some were too large, the changes whose forms opened are removed from the cart and only the too-large ones stay, with the status "`N` part(s) opened and removed from the cart; `M` change(s) too large for a link stay: use Copy change set." **Copy change set** puts the whole change set on the clipboard, formatted; paste it into the **Changes** field of the empty form, which the cart links as "empty form".

The cart is kept in your browser (local storage), one cart per rulebook repository, and survives closing the tab; another browser or a private window has its own. **Clear** empties it after a confirmation.

**Before the first submission**, create the label `rulebook-change` once in the repository (Issues > Labels > New label, or `gh label create rulebook-change`). The form asks GitHub to apply it, and GitHub applies only labels that exist: without it the issue is opened without a label.

**What happens next.** The issue holds the change set; nothing is applied automatically yet. A maintainer applies it with the workflows that exist today (the form says by hand or with the Change Rule workflow) and closes the issue ([changing-a-rule.md](changing-a-rule.md) section 3). The site shows the new state only after the maintainer's pull request is merged and Publish has run; for an override that changes no endpoint, run Publish by hand (section 2).

| `op` in the change set | Applied with |
|---|---|
| `set` (an action) | **Change Rule** with the id, the action, the level and stage (`*` for `["*"]`) and the justification. |
| `remove` (Reset) | **Change Rule** with `Remove` and the same level and stage. A `remove` for an entry with two or more levels or stages is in the change set too, but Change Rule cannot apply it: delete the entry from `overrides.json` by hand ([overrides.md](overrides.md) section 6). |
| `release` | Delete the id from `quarantine.<stage>.json` by hand and regenerate the endpoints in the same pull request ([quarantine.md](quarantine.md) section 4). |

## 4. What is public

Anyone who can open the site sees the action of every rule on every endpoint, and which input decided it. On GitHub Free a Pages site is public, and so are the endpoints in every case: the AL compiler reads them without signing in. The site adds this:

| Data | On the site | Why |
|---|---|---|
| The action of every rule on every endpoint | yes | The endpoints and the analyzer defaults say the same. |
| The deciding input of every cell (override, quarantine, stage, level, twins, default) | yes | It shows that you deviate, not why. |
| The justifications of the level and stage files, the shipped ones and your own | yes, always | The shipped files are public in the engine; your own level and stage files are part of the rulebook the site describes. |
| The justification text of your overrides and quarantine entries | only with `"includeJustifications": true` | Free text your organization wrote; a quarantine justification names package versions and dates. |

If the repository itself is public, which GitHub Free requires for Pages, `overrides.json`, the quarantine files and their justifications are readable there anyway; `includeJustifications` only matters when the repository is private (paid plans).

With `includeJustifications` set to `true`, the override justifications are written into `rulebook.json` and the quarantine justifications also appear in the quarantine list of the stage pages. Any other value leaves both out. There is no other access control on the site. If none of this should be on a web page, set `"enabled": false`: Publish keeps the plain index page, and `rulebook.json` and `catalog/diagnostics.json` are still published, with the same rule for the justifications.

## 5. Adapting `site/`

`site/` holds the whole site: `hugo.yaml` (the title), `layouts/` (the HTML of every page), `assets/css/site.css` (the colours are variables at the top) and `assets/js/` (the filters, the popover and the cart). It uses no theme, no npm and no framework. You can change any of these files.

**Updates.** `site/` is a customizable file class, like `docs/` ([updating.md](updating.md) section 1). The update replaces a site file you have not changed. A file you changed is kept, and when the template changed it too, the update pull request lists it under "Skipped: local changes" with a link to the template diff, so you can take over what you need. A site file you deleted comes back while the template ships it, unless you list it in `unusedRulebookFiles`. With `site.updateMode` set to `"overwrite"` the template's files always replace yours.

A file you changed and the update kept keeps running against a newer `rulebook.json` and the template's newer scripts, so it can break after an update. The safest changes are the title in `hugo.yaml` and the colour variables at the top of `site.css`. If you change `layouts/` or `assets/js/`, check the "Skipped: local changes" list of every update pull request and build the site locally before you merge it.

**What the site needs.** Publish builds whatever `site/` holds. Keep these parts when you change a layout:

- the attribute `data-rulebook-matrix` on the grid of `<baseUrl>/` (the `section` in `layouts/partials/matrix.html`). Without it Publish warns that `site/layouts` may have dropped the matrix, and still publishes the site as built;
- the attributes `data-repository`, `data-issue-template` and `data-rulebook-json` on `<body>` (`layouts/baseof.html`), the `cart` and `popover` partials, and the cart button in the header: the cart needs them to work.

**Building it locally.** You need Hugo 0.156.0 or later, extended, and a data file in `site/data/rulebook.json`. The quickest data file is the published one: download `<baseUrl>/rulebook.json` into `site/data/`. To see changes you have not published yet, write the file from a clone of the engine ([ALCops/rulebook-engine](https://github.com/ALCops/rulebook-engine)) instead. Run it in the root of your rulebook repository: `Export-RulebookSiteData` reads `.github/Rulebook-Settings.json` and `catalog/diagnostics.json` there and throws without them. Pass `-Repository` with your repository as `owner/name`, or the cart cannot build the issue link:

```powershell
Import-Module <engine clone>/modules/Rulebook.Site.psd1
Export-RulebookSiteData -RepositoryRoot . -BaseUrl https://contoso.github.io/rulebook -Repository contoso/rulebook
hugo --source site --baseURL https://contoso.github.io/rulebook/ --destination <folder outside the repository> --noBuildLock
```

To click through the result, build with `--baseURL http://localhost:8000/` instead and serve the folder with any local web server on that port, for example `python -m http.server 8000` in the folder: the links of the pages start with the path of `--baseURL`. `site/data/` and the build output are in `site/.gitignore`; they are never committed, and the update never touches `site/data/`.

## 6. The data files

Publish writes two files for other tooling (scripts, an editor extension, a report) on every run, with or without the site:

| File | Content |
|---|---|
| `<baseUrl>/rulebook.json` | One document with everything the site shows. The keys in order: `generatedAt`, `repository`, `baseUrl`, `issueTemplate`, `docsUrl`, `initScriptUrl`, `engineRef` and `alProjectDocsUrl` (the links and the engine ref of the setup page), `levels` (settings order, with the facts, counts and entries of each level page), `stages` (the same for the stage pages), `rules` (every id with its default and one cell per level and stage: `action`, `source`, and on override and quarantine cells the `fallback` the cart uses), `overrides` (the entries of `overrides.json` in file order) and `quarantine` (one list per stage). The init script reads the `levels` and `stages` names and slugs. |
| `<baseUrl>/catalog/diagnostics.json` | Your `catalog/diagnostics.json`, byte for byte. |

`generatedAt` is UTC text such as `2026-10-17T08:30:00Z`. PowerShell's `ConvertFrom-Json` turns it into a date; read it with `ConvertFrom-Json -DateKind String` (PowerShell 7.5 and later) to keep the text. The complete key list with an example is section 5 of the engine's [dashboard.md](https://github.com/ALCops/rulebook-engine/blob/main/docs/dashboard.md).

## 7. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Publish fails with failure `site`: "Installing Hugo ... failed: ..." | The Hugo download, its download check (sha256) or the install failed, or the runner is not Linux and has no extended Hugo 0.156.0 or later (the message names `hugoPath`, an input of the Publish action). | Run Publish again on `ubuntu-latest` as shipped; elsewhere install Hugo 0.156.0 or later (extended) and pass its path as `hugoPath`. If it keeps failing, set `site.enabled` to `false` to publish the plain index page meanwhile. |
| Publish fails with failure `site`: "The site build failed: ..." | Hugo could not build `site/`, often after a change to a layout. The red error in the run summary carries the end of Hugo's output; the previous deployment stays live. | Fix the file Hugo names (build locally, section 5) or restore it from the template. |
| Publish fails with failure `site`: "site.enabled is true, but Hugo was not found ..." | `hugoPath` (an input of the Publish action) names a Hugo that is not there. | Correct `hugoPath`, or remove it so the action installs its Hugo. |
| Warning "site.enabled is true, but site/hugo.yaml is missing: this run publishes the plain index.html. ..." | The repository has no `site/` yet (created before the template shipped it), or the file was deleted. | Run **Update Rulebook System Files** to get `site/`, or set `site.enabled` to `false`. |
| Warning "The built index.html has no data-rulebook-matrix marker: ..." | A changed layout no longer carries the attribute (section 5). | Put `data-rulebook-matrix` back on the grid, or ignore the warning if you dropped the matrix on purpose. |
| GitHub shows an error page (500, 502 or 414) after Submit | You are not signed in: GitHub sends you to the sign-in page with the whole link appended, and that redirect fails from about 7 KB with 500 or 502. A signed-in browser gets 414 "URI Too Long" from 8192 bytes, which the cart's 7372-byte limit stays under. | Sign in to GitHub first and submit again; or use **Submit in parts** or **Copy change set** with the empty form. |
| The byte count is red and Submit on GitHub is disabled | The issue link would be more than 7372 bytes. | **Submit in parts**, or **Copy change set** and the empty form; shorter justifications and a shorter note also help. |
| The cart is empty after a submission | You confirmed "Did GitHub open the filled form? Clear the cart?". Or you opened the site in another browser or a private window, which keeps its own cart. | If the form did not open, add the changes again. Submitted issues keep the change set. |
| A filter is gone after a click | Only the stage links keep the filters; the level, rule and other links do not. | Go back in the browser, or open a link that carries the part after `#`. |
| A cell has no Reset | Reset removes an override, and only a cell with the `O` badge is decided by one. A cell with the ring is decided by the twins rule, which may follow an override on the other rule of the pair. | Choose an action for the cell instead, or reset the override on the cell that carries the badge. |
| The issue was opened without the label `rulebook-change` | The label does not exist in the repository. GitHub applies only labels that exist. | Create the label once (section 3) and add it to the issue. |
| The cart says "The data file names no repository as owner/name, so the site cannot open its issue form." | The site was built from a `rulebook.json` without `repository`, for example a local build without `-Repository`. | Publish writes it on GitHub; for a local build pass `-Repository` (section 5). |
| The cart says "rulebook.json could not be read, so the before and after are not shown." | The page could not load `<baseUrl>/rulebook.json`, for example while the deploy is running. | Reload the page; the next action tries again. |
| The site still shows the old state after a merge | The change touched no path the Publish workflow runs on (section 2), or the deploy is a few seconds old. | Run Publish by hand; GitHub Pages may serve a file from its cache for up to 10 minutes. |
