# Frequently asked questions

Short answers to the questions organizations ask most, each with a link to the page or the decision record that holds the detail.

> **Status:** written 2026-10-10 with WP11 of the engine ([#13](https://github.com/ALCops/rulebook-engine/issues/13)). The decisions are the engine's records under [docs/adr](https://github.com/ALCops/rulebook-engine/blob/main/docs/adr/README.md) (`D` numbers).

## Contents

1. [Why one flat endpoint per level and stage?](#1-why-one-flat-endpoint-per-level-and-stage)
2. [Why one file per stage in an AL project?](#2-why-one-file-per-stage-in-an-al-project)
3. [Why are levels and stages configurable?](#3-why-are-levels-and-stages-configurable)
4. [Why does suppressWarnings work for some ids and not for others?](#4-why-does-suppresswarnings-work-for-some-ids-and-not-for-others)
5. [Why does the endpoint not list every id?](#5-why-does-the-endpoint-not-list-every-id)
6. [Why are the level files copied into my repository?](#6-why-are-the-level-files-copied-into-my-repository)
7. [Why does Rulebook not know whether a project is a per-tenant extension or an AppSource app?](#7-why-does-rulebook-not-know-whether-a-project-is-a-per-tenant-extension-or-an-appsource-app)
8. [Do I get documentation updates?](#8-do-i-get-documentation-updates)
9. [Can I host the endpoints somewhere else?](#9-can-i-host-the-endpoints-somewhere-else)
10. [Troubleshooting](#10-troubleshooting)

## 1. Why one flat endpoint per level and stage?

Each endpoint is one ruleset file without includes, generated from the level's chain of files, the stage file, your twins setting, your overrides and quarantine ([D18](https://github.com/ALCops/rulebook-engine/blob/main/docs/adr/0018-every-endpoint-is-one-flat-ruleset-file-there-is-no-include.md); since [D22](https://github.com/ALCops/rulebook-engine/blob/main/docs/adr/0022-sparse-endpoints-an-id-at-its-analyzer-default-is-not-listed.md) it lists only the deviations, question 5). The compiler resolves includes in ways that are easy to get wrong (strictest-wins between siblings, a failing include drops the whole tree), and every include is one more HTTP request per compile. A flat file is fetched once and reads the same in every consumer. With the shipped four levels and three stages that makes twelve endpoints; your own levels and stages add theirs.

## 2. Why one file per stage in an AL project?

A project exception has to sit in the file the compiler is pointed at, because a file's own `rules` beat what it includes, and each stage points at another endpoint. So every stage gets its own small file in `.rulebook/`, and an exception that applies everywhere is repeated in each ([al-project.md](al-project.md) section 2).

## 3. Why are levels and stages configurable?

Organizations differ in how many steps their ladder needs and which builds they run. The levels and stages are entries in your settings, not names built into the engine: add a level between two shipped ones, publish one under another name, start from everything off, add a stage for nightly builds, or stop publishing one ([D26](https://github.com/ALCops/rulebook-engine/blob/main/docs/adr/0026-levels-and-stages-are-configuration.md), [levels.md](levels.md)).

## 4. Why does suppressWarnings work for some ids and not for others?

The compiler merges `suppressWarnings` from `app.json` after the ruleset, strictest wins, and switching off is never the strictest. So it works for every id your endpoint does not list (Errors included) and is silently ignored for an id the endpoint lists at any action. Use an exception in the stage file's `rules` for those ([al-project.md](al-project.md) section 6, observed in the engine's [spike (f)](https://github.com/ALCops/rulebook-engine/blob/main/docs/reference/spikes/f-suppresswarnings-sparse-endpoint.md)).

## 5. Why does the endpoint not list every id?

An endpoint lists only the ids whose action differs from the analyzer default ([D22](https://github.com/ALCops/rulebook-engine/blob/main/docs/adr/0022-sparse-endpoints-an-id-at-its-analyzer-default-is-not-listed.md)). The compiler applies the default to every id it does not find, so listing it would change nothing, make every file several hundred lines longer and take `suppressWarnings` away from projects (question 4). The full picture per level, listed or not, is on the level pages in the engine ([docs/levels](https://github.com/ALCops/rulebook-engine/blob/main/docs/levels/README.md)).

## 6. Why are the level files copied into my repository?

Your repository holds its own copy of the shipped level and stage files ([D3](https://github.com/ALCops/rulebook-engine/blob/main/docs/adr/0003-managed-levels-are-vendored-into-the-org-repo.md)). Your endpoints are generated from files you can see, review and pin, and nothing changes them behind your back: a new template version arrives as a pull request with the effective change per endpoint, and you merge it when you are ready ([updating.md](updating.md)).

## 7. Why does Rulebook not know whether a project is a per-tenant extension or an AppSource app?

There is one ladder of levels for both kinds. Both Microsoft cops run at their native severity, and a project opts out of the rules written for the other kind: by not running that cop, with `suppressWarnings`, or with exceptions in its own file ([D21](https://github.com/ALCops/rulebook-engine/blob/main/docs/adr/0021-no-target-dimension-one-ladder-per-rule-both-microsoft-cops.md)). A second dimension would double the endpoints and the decisions for every rule. The rules that contradict and the ready-made lists are in [pte-or-appsource.md](pte-or-appsource.md); an organization that builds only one kind sets `twins` ([section 7 there](pte-or-appsource.md#7-the-twins-setting)).

## 8. Do I get documentation updates?

Yes. The pages in `docs/` of your repository are kept current by **Update Rulebook System Files**: a page you never edited follows the template, a page you edited is kept, and listed in the update pull request when the template changed it too, so you can take over what you need ([D50](https://github.com/ALCops/rulebook-engine/blob/main/docs/adr/0050-docs-is-a-customizable-file-class-and-the-installed-commit-is-recovered.md), [updating.md](updating.md) section 1). Set `"docs": { "updateMode": "overwrite" }` to always take the template's pages. A page you delete comes back until you list it in `unusedRulebookFiles`. The current pages are always at https://github.com/ALCops/rulebook/tree/main/docs.

## 9. Can I host the endpoints somewhere else?

Version 1 publishes to GitHub Pages only. A separate public repository, Azure Blob Storage and a gist are planned ([hosting.md](hosting.md) section 4). The endpoints are self-contained files without includes, so a static host on a public address that answers without redirects should serve them too, but only `github.io` and `raw.githubusercontent.com` have been tested with the compiler; the Publish workflow and its checks are what is still missing for the other targets.

## 10. Troubleshooting

This page has no messages of its own. Where to look:

| Symptom | Cause | Fix |
|---|---|---|
| AL1033 or AL0767 in VS Code or a pipeline | The endpoint could not be loaded, or external rulesets are off. | [vscode.md](vscode.md) section 8, [al-go.md](al-go.md) section 9, [azure-devops.md](azure-devops.md) section 8. |
| Publish fails | Pages, `baseUrl` or out-of-date endpoints. | [hosting.md](hosting.md) section 3. |
| An update, scan or change fails on the token | The `GHTOKENWORKFLOW` secret is missing or cannot be used. | [ghtokenworkflow.md](ghtokenworkflow.md) section 6. |
| Validate reports a finding after you changed a level, stage or override | A file or a selector does not match the settings. | [levels.md](levels.md) section 10, [overrides.md](overrides.md) section 7. |
| The update pull request is not what you expected | Kept files, skipped pages, removed files. | [updating.md](updating.md) section 8. |
