# AL-Go template mechanics

Reference description of the mechanisms in [AL-Go for GitHub](https://github.com/microsoft/AL-Go) that Rulebook borrows: the **template repository** behind the "Use this template" button, the **Update AL-Go System Files** mechanism that keeps repositories created from a template up to date, the rules that decide which files survive an update, and the **GhTokenWorkflow** secret that lets a workflow write files and open pull requests. It closes with the mapping of each mechanism to Rulebook's two repositories, settings file, update workflow and file classes.

> **Status:** reference for Rulebook contributors, not a design. Observed on 2026-09-29 against the `main` branch of microsoft/AL-Go, latest release **v9.2** (2026-08-25). All links point at `main` and may drift; the tag `v9.2` on microsoft/AL-Go (`https://github.com/microsoft/AL-Go/tree/v9.2/<path>`) gives a frozen view of the same files. Facts marked *(not verified)* could not be confirmed against a raw source.

---

## Contents

1. [Purpose and scope](#1-purpose-and-scope)
2. [AL-Go at a glance](#2-al-go-at-a-glance)
3. [Template repositories](#3-template-repositories)
4. [Release and deploy model](#4-release-and-deploy-model)
5. [The update mechanism](#5-the-update-mechanism)
6. [Customization preservation](#6-customization-preservation)
7. [Custom (indirect) templates](#7-custom-indirect-templates)
8. [GhTokenWorkflow](#8-ghtokenworkflow)
9. [Mapping to Rulebook](#9-mapping-to-rulebook)
10. [References](#10-references)
11. [Appendix: quick reference](#11-appendix-quick-reference)

---

## 1. Purpose and scope

Rulebook has three needs that AL-Go already solves for its own system files:

1. **Distribute files at creation.** An org rulebook repo must start with the level and stage files, the generated endpoints, skeletons, settings and workflows. GitHub's template repository feature does this.
2. **Update the files later.** When Rulebook ships new level content or a new workflow, every org rulebook repo must be able to pull the new version as a reviewable pull request without losing its own overrides. AL-Go's "Update AL-Go System Files" workflow and its `CheckForUpdates` action do this.
3. **Write to the repository from a workflow.** Pushing a branch and opening a pull request from GitHub Actions needs a token with more rights than the default `GITHUB_TOKEN`, in particular when workflow files are among the updated files. AL-Go's `GhTokenWorkflow` secret does this.

This document explains how AL-Go implements each of the three, at the level of files, functions, inputs and settings, with a link for every claim, so that a Rulebook contributor can port the mechanism without re-reading AL-Go from scratch.

---

## 2. AL-Go at a glance

AL-Go is spread over four GitHub repositories with distinct roles.

| Repository | Role | Template? |
|---|---|---|
| [microsoft/AL-Go](https://github.com/microsoft/AL-Go) | Source of everything: the actions, the two templates, the deploy script, the documentation. Nobody creates a repository from it. | No |
| [microsoft/AL-Go-Actions](https://github.com/microsoft/AL-Go-Actions) | Published copy of the `Actions/` folder, one branch per release (`v9.2`, ...). Workflows in consumer repositories reference `microsoft/AL-Go-Actions/<Action>@v9.2`. | No (`is_template: false`) |
| [microsoft/AL-Go-PTE](https://github.com/microsoft/AL-Go-PTE) | Published copy of `Templates/Per Tenant Extension`. Has the "Use this template" button. | Yes (`is_template: true`) |
| [microsoft/AL-Go-AppSource](https://github.com/microsoft/AL-Go-AppSource) | Published copy of `Templates/AppSource App`. Has the "Use this template" button. | Yes (`is_template: true`) |

The folders in microsoft/AL-Go that matter for this document:

| Folder or file | Content |
|---|---|
| [Actions/](https://github.com/microsoft/AL-Go/tree/main/Actions) | About 42 composite GitHub Actions, one folder each (`CheckForUpdates`, `ReadSettings`, `ReadSecrets`, `GetWorkflowMultiRunBranches`, ...), plus shared PowerShell: [AL-Go-Helper.ps1](https://github.com/microsoft/AL-Go/blob/main/Actions/AL-Go-Helper.ps1) (git helpers, settings), [Github-Helper.psm1](https://github.com/microsoft/AL-Go/blob/main/Actions/Github-Helper.psm1) (API, tokens, GitHub App), [.Modules/ReadSettings.psm1](https://github.com/microsoft/AL-Go/blob/main/Actions/.Modules/ReadSettings.psm1) (settings hierarchy, defaults, file name constants) and [.Modules/settings.schema.json](https://github.com/microsoft/AL-Go/blob/main/Actions/.Modules/settings.schema.json). |
| [Templates/Per Tenant Extension/](https://github.com/microsoft/AL-Go/tree/main/Templates/Per%20Tenant%20Extension) | The PTE template as it is authored: `.github/workflows/*.yaml`, `.github/AL-Go-Settings.json`, `.AL-Go/settings.json`, `.AL-Go/localDevEnv.ps1`, `.AL-Go/cloudDevEnv.ps1`, `al.code-workspace`, `README.md`, `CODEOWNERS`, `SECURITY.md`, `SUPPORT.md`, `.gitignore`. |
| [Internal/Deploy.ps1](https://github.com/microsoft/AL-Go/blob/main/Internal/Deploy.ps1) and [.github/workflows/Deploy.yaml](https://github.com/microsoft/AL-Go/blob/main/.github/workflows/Deploy.yaml) | The release pipeline that copies templates and actions to the three published repositories (section 4). |
| [Scenarios/](https://github.com/microsoft/AL-Go/tree/main/Scenarios) | User documentation. Relevant here: [GetStarted.md](https://github.com/microsoft/AL-Go/blob/main/Scenarios/GetStarted.md), [UpdateAlGoSystemFiles.md](https://github.com/microsoft/AL-Go/blob/main/Scenarios/UpdateAlGoSystemFiles.md), [GhTokenWorkflow.md](https://github.com/microsoft/AL-Go/blob/main/Scenarios/GhTokenWorkflow.md), [CustomizingALGoForGitHub.md](https://github.com/microsoft/AL-Go/blob/main/Scenarios/CustomizingALGoForGitHub.md), [settings.md](https://github.com/microsoft/AL-Go/blob/main/Scenarios/settings.md), [secrets.md](https://github.com/microsoft/AL-Go/blob/main/Scenarios/secrets.md). |
| [RELEASENOTES.md](https://github.com/microsoft/AL-Go/blob/main/RELEASENOTES.md) | Per-version notes. Copied into every template as `.github/RELEASENOTES.copy.md` and used as the pull request body of an update (section 5.5). |

The life cycle, from source to a consumer repository and back:

```mermaid
flowchart LR
    src[microsoft/AL-Go<br/>Actions/ + Templates/] -->|Deploy.yaml + Deploy.ps1<br/>rewrite action refs to @vX.Y| act[microsoft/AL-Go-Actions<br/>branch vX.Y]
    src -->|Deploy.ps1<br/>rewrite templateUrl, $schema| pte[microsoft/AL-Go-PTE<br/>branches main, preview, vX.Y<br/>is_template = true]
    pte -->|Use this template<br/>copies default branch, one commit| repo[consumer repository<br/>.github/AL-Go-Settings.json: templateUrl]
    repo -->|CI/CD job CheckForUpdates<br/>update = N: warn only| repo
    repo -->|Update AL-Go System Files<br/>update = Y: PR or direct commit| repo
    repo -.->|download zipball of templateUrl@branch<br/>compare with local files| pte
    repo -.->|uses: microsoft/AL-Go-Actions/...@vX.Y| act
```

---

## 3. Template repositories

### 3.1 The GitHub feature

Source: [Creating a template repository](https://docs.github.com/en/repositories/creating-and-managing-repositories/creating-a-template-repository) and [Creating a repository from a template](https://docs.github.com/en/repositories/creating-and-managing-repositories/creating-a-repository-from-a-template).

| Aspect | Behaviour |
|---|---|
| Enabling | Repository **Settings**, tick **Template repository**. Anyone with admin permission on the repository can do this. The button "Use this template" then appears on the repository page. |
| Who can use it | Anyone with read access to the template repository. For a public template that is everyone. |
| What is copied | "The same directory structure, branches, and files." By default only the **default branch**; with **Include all branches** the file tree of every branch. |
| History | The new repository "starts with a single commit". Branches created from a template "have unrelated histories, so you cannot create pull requests or merge between the branches" (template and copy). This is the difference with a fork. |
| Limitation | "Your template repository cannot include files stored using Git LFS." |
| Not copied *(GitHub behaviour in practice, not verified on the two pages above)* | Secrets, variables, environments, branch protection rules, repository settings, Actions run history, issues and pull requests. Every consumer repository has to be given its secrets separately, which is why AL-Go documents the `GhTokenWorkflow` secret as an organization secret (section 8.2). |
| Command line | `gh repo create <owner>/<name> --template <owner>/<template> [--include-all-branches]` ([gh manual](https://cli.github.com/manual/gh_repo_create)). |
| REST | `POST /repos/{template_owner}/{template_repo}/generate` with `name`, optional `owner`, `description`, `private`, `include_all_branches` ([REST reference](https://docs.github.com/en/rest/repos/repos#create-a-repository-using-a-template)). The template must have `is_template: true`. |
| Workflows in the copy | Workflow files under `.github/workflows` are copied as ordinary files and become active immediately; nothing has to be enabled. Workflows with `workflow_dispatch` appear under Actions and can be run by hand. Workflows with `push` triggers run on the first push. |

### 3.2 What the AL-Go templates contain

Contents of `microsoft/AL-Go-PTE`, branch `main` (GitHub contents API, 2026-09-29):

| Path | Files | Purpose |
|---|---|---|
| `/` | `.gitignore`, `CODEOWNERS`, `README.md`, `SECURITY.md`, `SUPPORT.md`, `al.code-workspace` | Ordinary repository files. AL-Go never updates them after creation. |
| `.AL-Go/` | `settings.json`, `localDevEnv.ps1`, `cloudDevEnv.ps1` | Project settings and the two developer scripts. Updated by AL-Go. |
| `.github/` | `AL-Go-Settings.json`, `RELEASENOTES.copy.md`, `Test Current.settings.json`, `Test Next Major.settings.json`, `Test Next Minor.settings.json`, `.agents/` | Repository settings, release notes copy, workflow-specific settings. Updated by AL-Go. |
| `.github/workflows/` | 20 `.yaml` files (`CICD`, `NextMajor`, `PullRequestHandler`, `UpdateGitHubGoSystemFiles`, `_BuildALGoProject`, ...) | The workflows. Updated by AL-Go. |

`.github/AL-Go-Settings.json` is the file that ties a repository to its template. On `main` it contains exactly:

```json
{
  "$schema": "https://raw.githubusercontent.com/microsoft/AL-Go-Actions/v9.2/.Modules/settings.schema.json",
  "type": "PTE",
  "templateUrl": "https://github.com/microsoft/AL-Go-PTE@main"
}
```

Note what is **not** in it: `templateSha`. The template does not know which commit it is; the consumer's first update run records that (section 5.8).

### 3.3 Versions are branches

The template repositories have no git tags. Every release is a **branch**: `v0.1` ... `v9.2`, plus `main`, `preview` and `PPPreview`. The three flavours of `AL-Go-Settings.json`:

| Branch | `templateUrl` | `$schema` | Action references in workflows |
|---|---|---|---|
| `main` | `https://github.com/microsoft/AL-Go-PTE@main` | `.../AL-Go-Actions/v9.2/...` | `microsoft/AL-Go-Actions/<Action>@v9.2` |
| `v9.2` | `https://github.com/microsoft/AL-Go-PTE@v9.2` | `.../AL-Go-Actions/v9.2/...` | `microsoft/AL-Go-Actions/<Action>@v9.2` |
| `preview` | `https://github.com/microsoft/AL-Go-PTE@preview` | `.../microsoft/AL-Go/<commit sha>/Actions/...` | `microsoft/AL-Go/Actions/<Action>@<commit sha>` |

So `main` and `v9.2` hold the same files except for the `templateUrl`. A repository created from `main` follows every future release; a repository that switches its `templateUrl` to `@v9.2` is pinned. The `templateUrl@branch` notation is what the update mechanism parses (section 5.2, step 1).

### 3.4 State of a freshly created repository

Right after "Use this template" on `AL-Go-PTE@main`:

- Files: everything from section 3.2, in one commit, history unrelated to the template.
- `templateUrl` = `https://github.com/microsoft/AL-Go-PTE@main`, no `templateSha`.
- No secrets. The CI/CD workflow's check for updates still works, because it only reads the public template (section 5.6). The Update workflow fails until `GhTokenWorkflow` exists (section 8).
- Workflows run with `uses: microsoft/AL-Go-Actions/...@v9.2`, so a consumer repository never executes code from the template repository itself, only from the pinned actions branch.

### 3.5 Checklist for a template of our own

Derived from 3.1 to 3.4:

1. A repository whose default branch holds exactly the files a new org rulebook repo should start with. Files that must never be overwritten later (README, .gitignore) and files that will be managed by the update mechanism can live side by side; the update mechanism decides by file list, not by folder (section 5.3).
2. Tick **Template repository** in the repository settings. No LFS files.
3. A settings file in the template that records the template URL (and later, in the consumer, the template commit).
4. A decision on versioning: `main` only, or `main` plus one branch per version like AL-Go. Branches, not tags, because the update mechanism resolves `@<branch>` through the branches API (section 5.2, step 4). "Include all branches" is off by default, so consumers get the default branch only.
5. An update workflow and an organization secret that consumers can use, since secrets are not copied.

---

## 4. Release and deploy model

AL-Go needs a deploy step ([Deploy.yaml](https://github.com/microsoft/AL-Go/blob/main/.github/workflows/Deploy.yaml), [Internal/Deploy.ps1](https://github.com/microsoft/AL-Go/blob/main/Internal/Deploy.ps1)) because its templates reference actions in another repository. The source templates always reference `@main`; the deploy step copies `Templates/*` to `AL-Go-PTE@<branch>` and `Actions/` to `AL-Go-Actions@<branch>`, rewriting every line that mentions the repository name and the word `main` to the target branch (regex `^(.*)<owner/repo>(.*)main(.*)$`). A release deploy with `copyToMain` also refreshes `main` and `preview`, which is why `AL-Go-PTE@main` always equals the latest release. Rulebook has the same split (template in one repo, actions in another), so a smaller version of this rewrite is needed when pinning the engine reference in the template workflows (section 9). Rulebook keeps the rewrite but not the frozen branches, `preview` or `copyToMain`: one floating `v1`, a bleeding-edge `main` refreshed from the engine's `template/`, and the version from `RELEASENOTES.md` ([D52](../adr/0052-releases-are-a-floating-major-branch-cut-from-hand-written-release-notes.md)).

---

## 5. The update mechanism

### 5.1 Workflow anatomy

File: [Templates/Per Tenant Extension/.github/workflows/UpdateGitHubGoSystemFiles.yaml](https://github.com/microsoft/AL-Go/blob/main/Templates/Per%20Tenant%20Extension/.github/workflows/UpdateGitHubGoSystemFiles.yaml). Name: `' Update AL-Go System Files'` (note the leading space).

**Triggers.** `workflow_dispatch` and `workflow_call`; no `schedule` in the template (section 5.7).

| Input | Type | Default | Meaning |
|---|---|---|---|
| `templateUrl` | string | `''` | "Template Repository URL (current is {TEMPLATEURL})". Empty means: use the `templateUrl` setting. `{TEMPLATEURL}` is a placeholder that `CheckForUpdates` replaces with the actual URL when it writes the workflow, so the dispatch form shows the current template. |
| `downloadLatest` | boolean | `true` | Resolve the latest commit of the template branch. `false` reuses the stored `templateSha`. |
| `directCommit` | boolean | `false` | Push to the branch instead of opening a pull request. |
| `includeBranches` | string | `''` | Comma-separated branch patterns with wildcards; every matching branch is updated in its own matrix job. |
| `caller` (workflow_call only) | string | required | Name of the calling workflow. |

**Permissions** for `GITHUB_TOKEN`: `actions: read`, `contents: read`, `id-token: write`. Nothing writable, because the write path uses the `GhTokenWorkflow` token, not `GITHUB_TOKEN`.

**Job `Initialize`** (windows-latest in AL-Go; Rulebook runs on ubuntu-latest):

1. `actions/checkout`.
2. `ReadSettings` with `get: templateUrl`, which exports the setting as an environment variable.
3. `GetWorkflowMultiRunBranches` ([script](https://github.com/microsoft/AL-Go/blob/main/Actions/GetWorkflowMultiRunBranches/GetWorkflowMultiRunBranches.ps1)) takes the patterns from the input on dispatch or call, from `settings.workflowSchedule.includeBranches` on a schedule, and falls back to the current branch. It matches them against `git for-each-ref refs/remotes/origin` and outputs `{ "branches": [...] }`.
4. "Determine Template URL": the input wins over the setting when it is not empty.

**Job `UpdateALGoSystemFiles`** (`needs: Initialize`, matrix over the branches, `fail-fast: false`):

1. checkout of `matrix.branch`.
2. `ReadSettings` with `get: commitOptions`.
3. `ReadSecrets` with `gitHubSecrets: ${{ toJson(secrets) }}` and `getSecrets: 'ghTokenWorkflow'` (section 8.4).
4. "Calculate Commit Options": on dispatch or call, `directCommit` and `downloadLatest` come from the inputs; on any other event (a schedule) `directCommit = -not commitOptions.createPullRequest` and `downloadLatest = true`.
5. `CheckForUpdates` with `token: ${{ fromJson(steps.ReadSecrets.outputs.Secrets).ghTokenWorkflow }}`, `downloadLatest`, `update: 'Y'`, `templateUrl` from the `Initialize` job, `directCommit`, `updateBranch: ${{ matrix.branch }}`, and `GITHUB_TOKEN: ${{ github.token }}` in the environment.

The action's own inputs ([Actions/CheckForUpdates/action.yaml](https://github.com/microsoft/AL-Go/blob/main/Actions/CheckForUpdates/action.yaml)) are `shell`, `actor` (default `github.actor`), `token` ("Base64 encoded GhTokenWorkflow secret"), `templateUrl`, `downloadLatest` (required), `update` (default `N`), `updateBranch` (default `github.ref_name`) and `directCommit` (default `false`). The composite action maps them to environment variables and runs `CheckForUpdates.ps1`. It has no outputs.

### 5.2 CheckForUpdates step by step

Script: [Actions/CheckForUpdates/CheckForUpdates.ps1](https://github.com/microsoft/AL-Go/blob/main/Actions/CheckForUpdates/CheckForUpdates.ps1), helpers in [CheckForUpdates.HelperFunctions.ps1](https://github.com/microsoft/AL-Go/blob/main/Actions/CheckForUpdates/CheckForUpdates.HelperFunctions.ps1) and [yamlclass.ps1](https://github.com/microsoft/AL-Go/blob/main/Actions/CheckForUpdates/yamlclass.ps1).

1. **Normalise `templateUrl`.** Append `@main` if there is no `@`; prepend `https://github.com/` if it does not start with `https://`; strip `www.`. After this the URL is always `https://github.com/<owner>/<repo>@<branch>`.
2. **Token guard.** If `update` is `Y` and no token was passed, throw `"The GhTokenWorkflow secret is needed. Read https://github.com/microsoft/AL-Go/blob/main/Scenarios/GhTokenWorkflow.md for more information."` If a token was passed, base64-decode it (the `ReadSecrets` action encodes every secret, section 8.4).
3. **Read the repository settings** and take `templateSha` from them. If the stored `templateUrl` differs from the requested one, or `templateSha` is empty, force `downloadLatest = true`.
4. **Download the template.** `DownloadTemplateRepository`:
   - First tries a `HEAD` request on the template repository URL with `GITHUB_TOKEN`. If that fails or is not 200, the template is private or internal, and the `GhTokenWorkflow` token is used instead (a GitHub App must then be installed on the template repository too).
   - With `downloadLatest`, `GetLatestTemplateSha` calls `GET .../branches/<branch>` and takes `commit.sha`. Failure: `"Failed to update AL-Go System Files. Could not get the latest SHA from template (<url>)"`.
   - Downloads `.../zipball/<sha>` to a temporary folder and unpacks it.
5. **Locate the template root.** `GetSrcFolder` resolves `*/.github/workflows` inside the unpacked zip and takes the grandparent.
6. **Detect a custom template** (section 7); not needed for Rulebook.
7. **Enumerate projects** and compute build-job duplication; not needed for Rulebook.
8. **Resolve the file lists** with `GetFilesToUpdate` (section 5.3): an include list and an exclude list of `{ sourceFullPath, originalSourceFullPath, destinationFullPath, type }`.
9. **Generate the content for every included file** (section 5.4) and compare it with the file in the repository using a case-sensitive string comparison (`-cne`) on LF-normalised content. Differences and missing files go into `$updateFiles`.
10. **Mark excluded files that exist** in the repository for removal (`$removeFiles`).
11. **Check mode** (`update` is not `Y`): print the lists and emit either the warning `"There are updates for your AL-Go system, run 'Update AL-Go System Files' workflow to download the latest version of AL-Go."` or the notice `"No updates available for AL-Go for GitHub."` Nothing is written.
12. **Update mode** (`update` is `Y`), inside one `try`:
    1. Commit message: `[<updateBranch>@<branch sha, 7 chars>] Update AL-Go System Files from <owner>/<repo> - <templateSha, 7 chars>`.
    2. `GetAccessToken -token $token -permissions @{ actions = read; contents = write; pull_requests = write; workflows = write }` gives `$repoWriteToken` (a PAT is returned as is; a GitHub App specification is exchanged for an installation token, section 8.3). It is also placed in `GH_TOKEN` for the `gh` CLI.
    3. **Existing pull request guard**: `gh api --paginate /repos/<repo>/pulls?base=<updateBranch>`; if a PR whose title equals the commit message exists, warn `"Pull request already exists for ..."` and exit.
    4. `CloneIntoNewFolder` (section 5.5) clones the repository into a temporary folder with the write token and creates the update branch unless `directCommit`.
    5. Write every file in `$updateFiles` (creating folders as needed) and delete every file in `$removeFiles`. While writing `.github/RELEASENOTES.copy.md`, compute the pull request body: the new release notes cut off at the first `## vX.Y` heading of the currently installed copy, so the body lists only what is new. Fallback body: `"No release notes available!"`.
    6. `UpdateSettingsFile` writes `templateUrl` and `templateSha` into the settings file (adds the properties if missing, only rewrites the file if something changed).
    7. `CommitFromNewFolder` (section 5.5) commits, pushes and opens the pull request. If it returns false (no changes after all), print `"No updates available for AL-Go for GitHub."`
    8. On any exception, rethrow with a hint: `"Failed to update AL-Go System Files. Make sure that the personal access token, defined in the secret called GhTokenWorkflow, is not expired and it has permission to update workflows. ..."` (direct commit) or `"Failed to create a pull-request to AL-Go System Files. Make sure that ..."` (pull request).

```mermaid
sequenceDiagram
    participant WF as Update workflow
    participant RS as ReadSecrets action
    participant CFU as CheckForUpdates.ps1
    participant API as GitHub API
    participant GIT as git / gh CLI
    WF->>RS: getSecrets: ghTokenWorkflow
    RS-->>WF: Secrets = { ghTokenWorkflow: base64 }
    WF->>CFU: token, templateUrl, downloadLatest, update=Y, directCommit, updateBranch
    CFU->>CFU: normalise templateUrl, decode token, read settings
    CFU->>API: HEAD template repo (GITHUB_TOKEN, else ghTokenWorkflow)
    CFU->>API: GET /repos/o/r/branches/b  (latest sha)
    CFU->>API: GET /repos/o/r/zipball/sha
    CFU->>CFU: resolve file lists, generate content, compare (-cne)
    alt update = N
        CFU-->>WF: warning or notice only
    else update = Y
        CFU->>API: GetAccessToken (App: JWT -> installation token)
        CFU->>API: GET /repos/o/r/pulls?base=branch (duplicate PR guard)
        CFU->>GIT: clone with user:token@host, checkout branch, new branch
        CFU->>GIT: write files, remove files, update settings file
        CFU->>GIT: commit, push, gh pr create (or direct push)
    end
```

### 5.3 Which files are "system files"

`GetFilesToUpdate` = `GetDefaultFilesToInclude` + `settings.customALGoFiles.filesToInclude`, minus `GetDefaultFilesToExclude` + `settings.customALGoFiles.filesToExclude`, minus `settings.unusedALGoSystemFiles`, all resolved by `ResolveFilePaths`.

Default include list (`GetDefaultFilesToInclude`):

| Source folder in the template | Filter | Type | Per project | Destination |
|---|---|---|---|---|
| `.github/workflows` | `*.yaml`, `*.yml` | `workflow` | no | same path |
| `.github` | `*.copy.md` | plain | no | same path |
| `.github` | `*.ps1` | plain | no | same path |
| `.github` | `AL-Go-Settings.json` | `settings` | no | same path |
| `.github` | `*.settings.json` | `settings` | no | same path |
| `.github/.agents` | `*.agent.md` | plain | no | same path |
| `.AL-Go` | `*.ps1` | plain | **yes** | `<project>/.AL-Go/` for every project |
| `.AL-Go` | `settings.json` | `settings` | **yes** | `<project>/.AL-Go/settings.json` |

Default exclude list (`GetDefaultFilesToExclude`): the three Power Platform workflows unless `type` is `PTE` and `powerPlatformSolutionFolder` is set.

Rules implemented in `GetFilesToUpdate`:

- An exclude entry only counts if the same source file is also in the include list ("excluding file ... as it is not in the include list"). Excluding therefore means "stop managing and delete", never "delete an arbitrary file".
- `unusedALGoSystemFiles` (an array of file names) moves matching included files to the exclude list, with a deprecation warning. The setting is announced for removal after 2026-10-01 ([RELEASENOTES.md, v8.1](https://github.com/microsoft/AL-Go/blob/main/RELEASENOTES.md)); `customALGoFiles.filesToExclude` replaces it.
- `customALGoFiles` entries have `sourceFolder`, `filter` (wildcards `*` and `?`), `destinationFolder` (default: same as source) and `perProject` ([settings.md](https://github.com/microsoft/AL-Go/blob/main/Scenarios/settings.md#customALGoFiles), [CustomizingALGoForGitHub.md, "Using custom template files"](https://github.com/microsoft/AL-Go/blob/main/Scenarios/CustomizingALGoForGitHub.md#using-custom-template-files)). The docs give a four-row truth table: matched by include only = created or updated; matched by include and exclude = removed; matched by exclude only = left alone; absent and matched by exclude = not created.
- Files that are in the repository but not in the template and not in any list are never touched. This is how a consumer's own workflows survive (section 6.1).

### 5.4 How the content of a file is generated

The comparison in step 9 is not "template file versus repository file". For each type the candidate content is built first:

| Type | Function | What happens |
|---|---|---|
| `workflow` | `GetWorkflowContentWithChangesFromSettings` | The template yaml is loaded into the line-based `Yaml` class and rewritten from settings (below). Then `{TEMPLATEURL}` is replaced by the template URL. |
| `settings` | `GetModifiedSettingsContent` | If the repository has no such file, the template file is used. Otherwise the **repository's** content is kept and only `$schema` is taken from the template and moved to the first position. Settings files are therefore never overwritten, only re-pointed to the schema of the new version. |
| anything else | `Get-ContentLF` | Copied as is, with LF line endings. |

Settings that `GetWorkflowContentWithChangesFromSettings` applies to a workflow (all documented in [settings.md](https://github.com/microsoft/AL-Go/blob/main/Scenarios/settings.md)):

| Setting | Effect on the generated yaml | Helper |
|---|---|---|
| `workflowSchedule` (`{ cron, includeBranches? }`) | Adds or replaces `schedule:` under `on:`. Only allowed in a workflow-specific settings file (`.github/<workflow>.settings.json`) or in conditional settings; in the global repository settings it throws. | inline |
| `workflowConcurrency` | Adds or replaces a top-level `concurrency:` block. Same placement rule. | inline |
| `runs-on`, `shell`, `githubRunner`, `githubRunnerShell` | Runner and shell of jobs. For the two "critical" workflows `UpdateGitHubGoSystemFiles` and `Troubleshooting` the change is skipped unless the runner is `windows-latest` or `ubuntu-latest`, so an update can always run. | `ModifyRunsOnAndShell` |
| `UpdateALGoSystemFilesEnvironment` | Inserts `environment: <name>` into the `UpdateALGoSystemFiles` job, so the secret can live in a protected environment with approvals. | `ModifyUpdateALGoSystemFiles` |
| `workflowDefaultInputs` | Overwrites `default:` of `workflow_dispatch` and matching `workflow_call` inputs, with type and choice validation. | `ApplyWorkflowDefaultInputs` |

The `Yaml` class ([yamlclass.ps1](https://github.com/microsoft/AL-Go/blob/main/Actions/CheckForUpdates/yamlclass.ps1)) is a deliberately small, line-based editor addressing nodes by path (`on:/push:`, `jobs:/UpdateALGoSystemFiles:/`) with `Find`, `Get`, `Replace`, `ReplaceAll`, `ReplaceOrAdd`, `Insert`, `Remove`, `Add`. No yaml parser, so formatting of the template survives.

### 5.5 Direct commit versus pull request

Git work is in [AL-Go-Helper.ps1](https://github.com/microsoft/AL-Go/blob/main/Actions/AL-Go-Helper.ps1).

`CloneIntoNewFolder -actor -token -updateBranch -directCommit -newBranchPrefix 'update-al-go-system-files'`:

- Creates a temporary folder, sets `GITHUB_USER` = actor and `GITHUB_TOKEN` = `GetAccessToken(token, actions/metadata read, contents/pull_requests write)`. Because `CheckForUpdates.ps1` already passes the exchanged `$repoWriteToken` (a plain token string, not a JSON App specification), `GetAccessToken` returns it unchanged, so the `workflows: write` permission from step 12.2 is preserved.
- Clone URL: `https://<actor>:<token>@github.com/<owner>/<repo>`. The token travels in the URL, not in an `http.extraheader`.
- Git identity: `user.name = <actor>`, `user.email = <actor>@users.noreply.github.com`; `core.autocrlf false`.
- Checks out `updateBranch`. Unless `directCommit`, creates `update-al-go-system-files/<updateBranch>/<yyMMddHHmmss UTC>`. The timestamp makes the branch name unique; duplicate PRs are prevented by the title check in step 12.3, not by the branch name.

`CommitFromNewFolder -serverUrl -commitMessage -branch -body -headBranch`:

- `git add *`, then `git status --porcelain=v1`. Nothing staged means "No changes detected in files" and `return $false`.
- Appends `commitOptions.messageSuffix` to message and body; truncates message and title to 250 characters; `git commit --allow-empty`.
- If the checked-out branch is not the new branch (direct commit): `git push <serverUrl>`; on failure it warns "Direct Commit wasn't allowed, trying to create a Pull Request instead", does `git reset --soft HEAD~`, creates the branch and re-commits. Branch protection therefore degrades gracefully into a PR.
- `git push -u <serverUrl> <branch>`, then `gh pr create --fill --head <branch> --repo <repo> --base <headBranch> --body "<body>"`, with `--label` when `commitOptions.pullRequestLabels` is set. Failure prints `"GitHub actions are not allowed to create Pull Requests (see GitHub Organization or Repository Actions Settings). You can create the PR manually by navigating to .../tree/<branch>"`.
- With `commitOptions.pullRequestAutoMerge`: `gh pr merge --auto --merge --delete-branch` or `--squash` according to `pullRequestMergeMethod` (default `squash`).

`commitOptions` defaults ([ReadSettings.psm1](https://github.com/microsoft/AL-Go/blob/main/Actions/.Modules/ReadSettings.psm1)): `messageSuffix ""`, `createPullRequest true`, `pullRequestAutoMerge false`, `pullRequestMergeMethod "squash"`, `pullRequestLabels []`. It can be set per workflow through workflow-specific settings files.

### 5.6 Check mode in CI/CD

The PTE `CICD.yaml` ([template](https://github.com/microsoft/AL-Go/blob/main/Templates/Per%20Tenant%20Extension/.github/workflows/CICD.yaml)) has a job `CheckForUpdates` with four steps: checkout, `ReadSettings` (`get: templateUrl`), `ReadSecrets` (`getSecrets: 'ghTokenWorkflow'`) and `CheckForUpdates` with `templateUrl`, `token` and `downloadLatest: true`, leaving `update` at its default `N`. So every CI/CD run performs steps 1 to 11 of section 5.2, downloads the template, and only annotates the run with the warning or notice. When the secret is missing the token is empty; that is fine in check mode because the guard in step 2 only fires for `update = Y`, and a public template is downloaded with `GITHUB_TOKEN`.

The user-facing description is in [UpdateAlGoSystemFiles.md](https://github.com/microsoft/AL-Go/blob/main/Scenarios/UpdateAlGoSystemFiles.md): every CI/CD run reports whether system files are outdated, including when someone edited a system file by hand, and the update PR reverts such edits.

### 5.7 Scheduling

The template ships without a schedule. A schedule is added by putting `workflowSchedule` in `.github/UpdateGitHubGoSystemFiles.settings.json` (or conditional settings) and running the update once, which rewrites the workflow with a `schedule:` trigger (section 5.4). On a scheduled run there are no inputs, so the workflow takes `downloadLatest = true` and `directCommit = -not commitOptions.createPullRequest` (default: a pull request). `workflowSchedule.includeBranches` lets one scheduled run update several branches ([RELEASENOTES.md, v6.4](https://github.com/microsoft/AL-Go/blob/main/RELEASENOTES.md)).

### 5.8 Life cycle of templateUrl and templateSha

| Moment | `templateUrl` | `templateSha` | What the next run does |
|---|---|---|---|
| Repository created from `AL-Go-PTE@main` | `...AL-Go-PTE@main` (from the template) | absent | `templateSha` empty forces `downloadLatest`; the first update writes both. |
| After an update | unchanged | commit of the template branch that was applied | With `downloadLatest = true` (default on dispatch, always on schedule) the branch head is resolved again. With `false` the stored commit is re-downloaded, which regenerates files from the same template version (useful after a settings change). |
| User dispatches with another `templateUrl` (for example `@v9.2`) | the new URL | reset by force-download | Both are written by the run. Later runs follow the new URL. |
| CI/CD check mode | read only | read only | Never writes settings. |

`templateSha` is not in the settings schema documentation; it is written by `UpdateSettingsFile` in `CheckForUpdates.ps1` and read back at the start of every run.

---

## 6. Customization preservation

Source: [CustomizingALGoForGitHub.md](https://github.com/microsoft/AL-Go/blob/main/Scenarios/CustomizingALGoForGitHub.md). The general rule: "If you make modifications to the AL-Go System Files (scripts and workflows) in your repository, in other ways than described in this document, these changes will be removed with the next AL-Go update." The supported ways are listed below.

| Mechanism | Survives an update? | How |
|---|---|---|
| **Own workflows** in `.github/workflows` that do not exist in the template | Yes | They are not in any file list (section 5.3). The docs recommend a prefix (`my`, `our`, the organization name) so a future template workflow cannot collide with them. |
| **Own scripts** in `.github` or `.AL-Go` with names that do not exist in the template | Yes | `.github/*.ps1` and `.AL-Go/*.ps1` are in the include list by *filter*, but the filter is evaluated on the template side, so a script that does not exist in the template is never a source file and is left alone. Only same-named scripts are overwritten. |
| **Custom jobs** `CustomJob<name>` in a template workflow | Yes | Extracted from the repository's copy of the workflow and re-inserted at the end of the regenerated yaml, with `needs:` relationships in both directions restored (section 6.2). Introduced in v7.3. |
| **Settings files** (`AL-Go-Settings.json`, `.AL-Go/settings.json`, `*.settings.json`) | Yes | `GetModifiedSettingsContent` keeps the repository's content and only updates `$schema` (section 5.4). |
| **Removed workflows** | Stay removed | `customALGoFiles.filesToExclude` (or the deprecated `unusedALGoSystemFiles`) both deletes the file and keeps it out of future updates. |
| Edits to the yaml of a template workflow outside a custom job, edits to `localDevEnv.ps1`, `cloudDevEnv.ps1`, `RELEASENOTES.copy.md` | No | Regenerated from the template; the PR shows the revert. |
| `README.md`, `.gitignore`, `CODEOWNERS`, `al.code-workspace`, AL code | Untouched | Not system files. |

### 6.1 Why unknown files survive

The include list is built from the **template** side (`Get-ChildItem` on the template's folders with the filters of section 5.3). A file that exists only in the consumer repository never appears as a source file, so it is neither compared nor removed. The only way a consumer file disappears is through the exclude list, which requires the file to exist in the template too.

### 6.2 Custom jobs in detail

In [yamlclass.ps1](https://github.com/microsoft/AL-Go/blob/main/Actions/CheckForUpdates/yamlclass.ps1):

- `GetCustomJobsFromYaml('CustomJob*')` scans the repository's current copy of the workflow. Jobs whose name matches and that are preceded by the comment line `# DO NOT EDIT. The following job was added through a custom template.` have origin `TemplateRepository`; other matching jobs have origin `FinalRepository`. For each custom job it records the content and the list of native jobs whose `needs:` mention it.
- `AddCustomJobsToYaml` appends each job to the regenerated yaml and patches `needs: [...]` of the dependent native jobs. A job that already exists is skipped.

The docs warn that custom jobs break when AL-Go renames the jobs they depend on, and that a custom job can carry its own `permissions:` block.

---

## 7. Custom (indirect) templates

Introduced in v7.3 ([CustomizingALGoForGitHub.md, "Using custom template repositories"](https://github.com/microsoft/AL-Go/blob/main/Scenarios/CustomizingALGoForGitHub.md#using-custom-template-repositories)): a custom template is an AL-Go repository that updates itself from `AL-Go-PTE`, while consumer repositories update from the custom template. `CheckForUpdates` downloads both, regenerates workflows from the original and re-applies the custom template's `CustomJob*` jobs, and writes two `*.doNotEdit.json` settings copies into the consumer. Rulebook is the top of its own chain, so this two-tier mechanism is not needed. It becomes relevant only if an organization wants to layer a company template on top of the Rulebook template; that is a possible later feature, not part of v1.

---

## 8. GhTokenWorkflow

### 8.1 Why GITHUB_TOKEN is not enough

Three limitations, each with the GitHub source and the place where AL-Go runs into it:

| Limitation | GitHub source | Where AL-Go hits it |
|---|---|---|
| **Workflow files cannot be written.** Pushing a change under `.github/workflows` needs the `workflow` scope (classic PAT), or the `Workflows` repository permission (fine-grained PAT, GitHub App). The `permissions:` keys available to `GITHUB_TOKEN` ([workflow syntax](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#permissions)) contain no `workflows` entry, so `GITHUB_TOKEN` can never get it. The push is rejected with a message of the form "refusing to allow a GitHub App to create or update workflow `.github/workflows/x.yaml` without `workflows` permission" *(wording from practice, not from a docs page)*. | The update writes `.github/workflows/*.yaml`; `CheckForUpdates.ps1` requests `workflows = write` explicitly (section 5.2, step 12.2). |
| **Events created with GITHUB_TOKEN do not start workflows.** [Triggering a workflow from a workflow](https://docs.github.com/en/actions/writing-workflows/choosing-when-your-workflow-runs/triggering-a-workflow#triggering-a-workflow-from-a-workflow): "if a workflow run pushes code using the repository's `GITHUB_TOKEN`, a new workflow will not run even when the repository contains a workflow configured to run when `push` events occur". | A pull request opened with `GITHUB_TOKEN` gets no CI run, so the PR cannot be validated before merge. |
| **Pull request creation can be disabled for Actions.** Organization and repository setting under Workflow permissions ([Disabling or limiting GitHub Actions for your organization](https://docs.github.com/en/organizations/managing-organization-settings/disabling-or-limiting-github-actions-for-your-organization)). | `CommitFromNewFolder` reports "GitHub actions are not allowed to create Pull Requests (see GitHub Organization or Repository Actions Settings)" when `gh pr create` fails. With a PAT or App token the setting does not apply. |

The `Update AL-Go System Files` workflow therefore keeps `GITHUB_TOKEN` at `contents: read` and does all writing with the token from the secret.

### 8.2 Personal access tokens

From [GhTokenWorkflow.md](https://github.com/microsoft/AL-Go/blob/main/Scenarios/GhTokenWorkflow.md):

| Flavour | Permissions | Scope of damage if leaked | AL-Go's verdict |
|---|---|---|---|
| Classic PAT | Scope `workflow` (which implies `repo`). | Every repository and organization the creator can reach. | Least secure. |
| Fine-grained PAT | Resource owner = the organization; selected repositories; **Read and write**: Contents, Pull requests, Workflows; **Read-only**: Actions (Metadata is implicit). | The selected repositories, impersonating the creator. | Better. |

Common to both: commits and PRs show as authored by the token's creator; "give them a short expiration date and recycle them frequently". The secret is created as a repository or organization secret named `GHTOKENWORKFLOW` (secret names are case-insensitive; the code reads `ghTokenWorkflow`). The name can be changed with the `ghTokenWorkflowSecretName` setting ([settings.md](https://github.com/microsoft/AL-Go/blob/main/Scenarios/settings.md#ghTokenWorkflowSecretName)). With `updateALGoSystemFilesEnvironment` the secret can live in a GitHub environment with reviewers.

One warning from the docs that matters for organization secrets: the secret being *available* to a repository is not the same as the PAT or App *having permissions* on that repository. Both must be true.

### 8.3 GitHub App (recommended by AL-Go)

Setup (same document):

1. Register an app at `https://github.com/organizations/<org>/settings/apps/new` (or the user-level URL). No callback, webhook or post-install URL.
2. Repository permissions: **Read and write** on Contents, Pull requests, Workflows; **Read-only** on Actions. No organization, account or enterprise permissions.
3. Generate a private key (downloaded as a `.pem`), and install the app on the organization for the repositories that need it.
4. Build the secret value with the documented one-liner:

```powershell
$githubAppClientId = '<GitHub App Client ID for your app>'
$privateKeyFile = '<full path of the downloaded private key file>'
@{"GitHubAppClientId"=$githubAppClientId; "PrivateKey" = ([string]::Join('',[System.IO.File]::ReadAllLines($privateKeyFile))) } | ConvertTo-Json -Compress -Depth 99 | Set-Clipboard
```

The result is compressed JSON `{"GitHubAppClientId":"...","PrivateKey":"-----BEGIN RSA PRIVATE KEY-----..."}` stored in the same `GHTOKENWORKFLOW` secret. Compressed matters: GitHub masks each line of a multi-line secret separately, which would turn every `{` and `}` in the logs into `***` ([secrets.md, "Use compressed JSON"](https://github.com/microsoft/AL-Go/blob/main/Scenarios/secrets.md)). Commits and PRs then appear as made by the app, tagged **bot**. Tokens are short-lived (one hour) and the private key never leaves the runner.

The code path, all in [Github-Helper.psm1](https://github.com/microsoft/AL-Go/blob/main/Actions/Github-Helper.psm1):

- `GetAccessToken -token -repository -repositories -permissions`: empty token returns empty; a token that does not start with `{` is returned as is (PAT); otherwise the JSON is parsed and `GetGitHubAppAuthToken` is called.
- `GetGitHubAppAuthToken`: builds a JWT, calls `GET <api>/repos/<repository>/installation` with `Authorization: Bearer <jwt>` to find the installation, then `POST <installation.access_tokens_url>` with a body limiting `repositories` and `permissions` to what the caller asked for. Returns `token`.
- `GenerateJwtForTokenRequest`: header `{alg: RS256, typ: JWT}`, payload `{iat: now-60s, exp: now+10min, iss: <client id>}`, signed with the PEM key (`RSA.ImportFromPem`, SHA256, PKCS1), base64url. Runs natively in PowerShell 7, which is what Rulebook uses.

### 8.4 How the token flows through a run

```mermaid
sequenceDiagram
    participant S as GitHub secret GHTOKENWORKFLOW
    participant RS as ReadSecrets action
    participant CFU as CheckForUpdates.ps1
    participant GH as Github-Helper.psm1
    participant API as GitHub API
    participant GIT as git / gh
    RS->>S: read via toJson(secrets), name ghTokenWorkflow
    RS->>RS: mask, base64-encode, output Secrets JSON
    RS-->>CFU: token input = base64(secret)
    CFU->>CFU: decode base64
    CFU->>GH: GetAccessToken(token, permissions: actions r, contents w, pull_requests w, workflows w)
    alt PAT
        GH-->>CFU: same string
    else GitHub App JSON
        GH->>API: GET /repos/o/r/installation (JWT)
        GH->>API: POST access_tokens_url (repositories, permissions)
        API-->>GH: installation token (1 h)
        GH-->>CFU: installation token
    end
    CFU->>GIT: clone https://actor:token@github.com/o/r
    CFU->>GIT: push branch; gh pr create (GH_TOKEN = token)
```

Details of the `ReadSecrets` action ([action.yaml](https://github.com/microsoft/AL-Go/blob/main/Actions/ReadSecrets/action.yaml), [ReadSecrets.ps1](https://github.com/microsoft/AL-Go/blob/main/Actions/ReadSecrets/ReadSecrets.ps1)): inputs `gitHubSecrets` (the whole `toJson(secrets)`) and `getSecrets` (comma-separated names). Each requested secret is looked up, JSON property values are masked individually, and the value is base64-encoded. Output `Secrets` is a compressed JSON object written to `GITHUB_OUTPUT`; the workflow reads it with `fromJson(steps.ReadSecrets.outputs.Secrets).ghTokenWorkflow`.

### 8.5 Permissions blocks and organization settings

- `UpdateGitHubGoSystemFiles.yaml`: `actions: read`, `contents: read`, `id-token: write`.
- For the `GITHUB_TOKEN` path, the organization or repository setting "Allow GitHub Actions to create and approve pull requests" must be on. For the secret path it is irrelevant.

### 8.6 Failure modes

| Symptom | Cause | Message |
|---|---|---|
| Update run fails immediately | Secret missing or not visible to the repository (environment, organization scope) | "The GhTokenWorkflow secret is needed. Read .../GhTokenWorkflow.md ..." |
| Push or PR fails | Expired PAT, missing `workflow` scope or Workflows permission, App not installed on the repository | "Failed to update AL-Go System Files / Failed to create a pull-request ... Make sure that the personal access token, defined in the secret called GhTokenWorkflow, is not expired and it has permission to update workflows." |
| Template download fails for a private template | `GITHUB_TOKEN` cannot read it and the App is not installed on the template repository | "Could not get the latest SHA from template" |
| PR creation fails with `GITHUB_TOKEN` | Organization setting | "GitHub actions are not allowed to create Pull Requests ..." |
| Logs show `***` instead of `{` | Multi-line JSON secret | Troubleshooting workflow warns "JSON formatted secrets ... should be compressed JSON (i.e. NOT contain any line breaks)" |

---

## 9. Mapping to Rulebook

Rulebook facts used below: two repositories, **`ALCops/rulebook`** (the template, `is_template: true`, holds the content an org rulebook repo starts with and the user-facing docs) and **`ALCops/rulebook-engine`** (the actions, referenced from template workflows as `ALCops/rulebook-engine/actions/<name>@v1`, plus modules, tests and contributor docs). The settings file is `.github/Rulebook-Settings.json` with `templateUrl` and `templateSha`. The update workflow is `.github/workflows/UpdateRulebookSystemFiles.yaml`. All actions run on `ubuntu-latest` with PowerShell 7.

### 9.1 Mechanism map

| Need of Rulebook | AL-Go mechanism | Read | Rulebook decision |
|---|---|---|---|
| Ship the 4 level files, the 2 stage files, 12 generated endpoints, 12 skeleton templates, settings and workflows into every new org rulebook repo | GitHub template repository (section 3) | 3.1, 3.5 | `ALCops/rulebook` default branch, `is_template` on. No secrets or settings travel with the copy. |
| Know which template and which version an org rulebook repo was created from | `templateUrl` in a settings file, `templateSha` written by the first update (sections 3.2, 5.8) | `UpdateSettingsFile`, `CheckForUpdates.ps1` steps 3 and 12.6 | `.github/Rulebook-Settings.json` carries `templateUrl: https://github.com/ALCops/rulebook@main`; `templateSha` is added by the first update. `@<branch>` selects the version. |
| Decide which files are managed and which belong to the org | Include and exclude lists built from the **template** side by folder and filter (section 5.3) | `GetDefaultFilesToInclude`, `GetFilesToUpdate`, `ResolveFilePaths` | Three file classes, see 9.2. Unknown org files are never touched. |
| Preserve the org's overrides across an update | AL-Go's `settings` file type: keep the repository content, refresh only `$schema` (section 5.4) | `GetModifiedSettingsContent` | Org decisions live only in `overrides.json`, which is org-owned and never touched; the shipped files in `base/` and `stages/` are overwritten and `rulesets/` regenerated. Settings files keep their content, only `$schema` is refreshed. |
| Regenerate a managed file with a placeholder | `{TEMPLATEURL}` replacement and the line-based `Yaml` class (section 5.4) | `GetWorkflowContentWithChangesFromSettings`, `yamlclass.ps1` | Template workflows carry `{TEMPLATEURL}`; skeleton templates carry `{BASEURL}`, rendered by the Publish action from `Rulebook-Settings.json`. |
| Tell an org rulebook repo that an update exists, without writing | Check mode (`update = N`) as a job in a CI workflow (section 5.6) | `CICD.yaml` job `CheckForUpdates`, step 11 | Check mode runs inside `Validate.yaml` on every pull request. Works without the secret because the template is public. |
| Apply the update as a reviewable change | Update mode: timestamped branch, PR titled with the template commit, duplicate-PR guard, optional direct commit, optional auto-merge, release notes as PR body (sections 5.2, 5.5) | `CloneIntoNewFolder`, `CommitFromNewFolder`, `commitOptions` | Port as `actions/CheckForUpdates` in rulebook-engine. Branch prefix `update-rulebook-system-files/`. Release notes from `.github/RELEASENOTES.copy.md`. |
| Update several branches or run unattended | `includeBranches` matrix and `workflowSchedule` (sections 5.1, 5.7) | `GetWorkflowMultiRunBranches.ps1` | `includeBranches` is left out of v1; a schedule comes from `update.schedule` in `Rulebook-Settings.json` (WP07, [update-mechanics.md](update-mechanics.md) section 5). |
| Write to the repository from the workflow | `GhTokenWorkflow` secret, GitHub App preferred over PAT, organization secret, exchanged per run for a least-privilege installation token (section 8) | `GetAccessToken`, `GetGitHubAppAuthToken`, `ReadSecrets.ps1` | **Reuse the secret name `GHTOKENWORKFLOW`** so an organization that already runs AL-Go needs no second secret and no second GitHub App (decided: D44, with the `ghTokenWorkflowSecretName` setting). The update touches `.github/workflows`, so `workflows: write` is required. |
| Version the template | Branch per version plus `main` = latest (sections 3.3, 4) | `Deploy.ps1` | Engine actions are referenced by version (`@v1`); the template source references `@main` and a small deploy step pins the reference on release (D52). |
| Guard the update with approvals | `UpdateALGoSystemFilesEnvironment` (section 5.4) | `ModifyUpdateALGoSystemFiles` | Optional setting, same behaviour. |
| Let orgs add their own jobs to a managed workflow | `CustomJob*` preservation (section 6.2) | `yamlclass.ps1` | Not in v1. Orgs add their own workflows with a prefix instead. |
| Two-tier templates | Custom (indirect) templates (section 7) | `CheckForUpdates.ps1` step 6 | Not in v1. |

### 9.2 File classes in an org rulebook repo

| Class | Files | Update behaviour |
|---|---|---|
| **Overwrite** (system files) | `.github/workflows/*.yaml` from the template, the shipped level files `base/<level>.ruleset.json` (4), the shipped stage files `stages/<stage>.json` (2), `base/twins.json`, skeleton templates, `.github/RELEASENOTES.copy.md` | Replaced by the template version on every update. Hand edits are reverted; the PR shows the revert. |
| **Settings-type** (merged) | `.github/Rulebook-Settings.json` and `.github/*.settings.json`: content kept, `$schema` refreshed, `templateSha` written. | Never lose org content. |
| **Generated** | The `levels x stages` sparse endpoints `rulesets/*.ruleset.json` (12 in the shipped set) | Regenerated by the update from the new level and stage files, the org's `twins` setting, `overrides.json`, quarantine files and catalog defaults; the PR shows the effective change. |
| **Org-owned** (never touched) | `overrides.json`, `quarantine.<stage>.json` (written by the org's own scan workflow), `catalog/diagnostics.json`, level and stage files the org added (`base/<custom>.ruleset.json`, `stages/<custom>.json`), the org's own workflows and scripts, `README.md`, `.gitignore`, `CODEOWNERS` | Not in any include list, so never compared or removed (section 6.1). |

Excluding a managed file follows AL-Go's rule: an exclude entry (`unusedRulebookFiles` in the settings) deletes the file and stops managing it, and only counts for files that exist in the template. An org that does not want the `vNext` stage removes it from `settings.stages` and lists `stages/vnext.json` there; the same applies to a shipped level the org no longer publishes.

### 9.3 AL-Go behaviours left out

The separate actions repository deploy rewrite beyond one pinned reference, project enumeration and build-job duplication (section 5.2 step 7), Power Platform file exclusion, Key Vault-backed secrets, telemetry (`WorkflowInitialize`, `WorkflowPostProcess`), custom jobs and custom templates.

Two AL-Go constraints to keep in mind: a template that consumers create with "Use this template" copies the template's own `templateUrl`, so the value in `ALCops/rulebook` must already be the URL an org rulebook repo should follow; and every org rulebook repo needs the secret, which in practice means an organization secret or an organization-owned GitHub App installed on the org rulebook repo (section 8.2).

---

## 10. References

**AL-Go documentation (Scenarios)**

- Get started: https://github.com/microsoft/AL-Go/blob/main/Scenarios/GetStarted.md
- Update AL-Go system files: https://github.com/microsoft/AL-Go/blob/main/Scenarios/UpdateAlGoSystemFiles.md
- Creating a GhTokenWorkflow secret (PAT and GitHub App): https://github.com/microsoft/AL-Go/blob/main/Scenarios/GhTokenWorkflow.md
- Customizing AL-Go (custom workflows, scripts, hooks, jobs, custom templates, custom template files): https://github.com/microsoft/AL-Go/blob/main/Scenarios/CustomizingALGoForGitHub.md
- Settings (hierarchy, `templateUrl`, `commitOptions`, `workflowSchedule`, `customALGoFiles`, `unusedALGoSystemFiles`, `ghTokenWorkflowSecretName`, `updateALGoSystemFilesEnvironment`): https://github.com/microsoft/AL-Go/blob/main/Scenarios/settings.md
- Secrets (compressed JSON, GhTokenWorkflow): https://github.com/microsoft/AL-Go/blob/main/Scenarios/secrets.md
- Release notes: https://github.com/microsoft/AL-Go/blob/main/RELEASENOTES.md (v5.0 `templateSha`; v6.4 GitHub App support and `workflowSchedule.includeBranches`; v7.3 custom jobs and custom template repositories; v8.1 `customALGoFiles` and the deprecation of `unusedALGoSystemFiles`)

**AL-Go code**

- Update workflow: https://github.com/microsoft/AL-Go/blob/main/Templates/Per%20Tenant%20Extension/.github/workflows/UpdateGitHubGoSystemFiles.yaml
- CI/CD workflow (check job): https://github.com/microsoft/AL-Go/blob/main/Templates/Per%20Tenant%20Extension/.github/workflows/CICD.yaml
- Template settings file: https://github.com/microsoft/AL-Go/blob/main/Templates/Per%20Tenant%20Extension/.github/AL-Go-Settings.json
- CheckForUpdates action: https://github.com/microsoft/AL-Go/tree/main/Actions/CheckForUpdates (`action.yaml`, `CheckForUpdates.ps1`, `CheckForUpdates.HelperFunctions.ps1`, `yamlclass.ps1`)
- ReadSecrets action: https://github.com/microsoft/AL-Go/tree/main/Actions/ReadSecrets
- GetWorkflowMultiRunBranches action: https://github.com/microsoft/AL-Go/tree/main/Actions/GetWorkflowMultiRunBranches
- Git helpers `CloneIntoNewFolder`, `CommitFromNewFolder`: https://github.com/microsoft/AL-Go/blob/main/Actions/AL-Go-Helper.ps1
- Token helpers `GetAccessToken`, `GetGitHubAppAuthToken`, `GenerateJwtForTokenRequest`: https://github.com/microsoft/AL-Go/blob/main/Actions/Github-Helper.psm1
- Settings defaults and file name constants: https://github.com/microsoft/AL-Go/blob/main/Actions/.Modules/ReadSettings.psm1
- Settings schema: https://github.com/microsoft/AL-Go/blob/main/Actions/.Modules/settings.schema.json
- Troubleshooting of secrets: https://github.com/microsoft/AL-Go/blob/main/Actions/Troubleshooting/Troubleshoot.Secrets.ps1
- Deploy workflow and script: https://github.com/microsoft/AL-Go/blob/main/.github/workflows/Deploy.yaml, https://github.com/microsoft/AL-Go/blob/main/Internal/Deploy.ps1
- Frozen view of all of the above at the observed release: https://github.com/microsoft/AL-Go/tree/v9.2

**Published repositories**

- https://github.com/microsoft/AL-Go-PTE (template, branches `main`, `preview`, `v0.1` ... `v9.2`)
- https://github.com/microsoft/AL-Go-AppSource (template)
- https://github.com/microsoft/AL-Go-Actions (actions, not a template)

**GitHub documentation**

- Creating a template repository: https://docs.github.com/en/repositories/creating-and-managing-repositories/creating-a-template-repository
- Creating a repository from a template: https://docs.github.com/en/repositories/creating-and-managing-repositories/creating-a-repository-from-a-template
- REST, create a repository using a template: https://docs.github.com/en/rest/repos/repos#create-a-repository-using-a-template
- `gh repo create --template`: https://cli.github.com/manual/gh_repo_create
- Automatic token authentication (`GITHUB_TOKEN`): https://docs.github.com/en/actions/security-for-github-actions/security-guides/automatic-token-authentication
- `permissions` keys for `GITHUB_TOKEN`: https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#permissions
- Triggering a workflow from a workflow: https://docs.github.com/en/actions/writing-workflows/choosing-when-your-workflow-runs/triggering-a-workflow#triggering-a-workflow-from-a-workflow
- OAuth and classic PAT scopes (`workflow`): https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/scopes-for-oauth-apps
- Managing personal access tokens: https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens
- Permissions required for GitHub Apps: https://docs.github.com/en/rest/authentication/permissions-required-for-github-apps
- Disabling or limiting GitHub Actions for your organization (PR creation setting): https://docs.github.com/en/organizations/managing-organization-settings/disabling-or-limiting-github-actions-for-your-organization

---

## 11. Appendix: quick reference

### Inputs of the update workflow and the action

| Workflow input (`UpdateGitHubGoSystemFiles.yaml`) | Action input (`CheckForUpdates`) | Note |
|---|---|---|
| `templateUrl` (default empty = setting) | `templateUrl` | `owner/repo`, `owner/repo@branch` or full URL; `@main` and `https://github.com/` are added when missing. |
| `downloadLatest` (default true) | `downloadLatest` (required) | `false` re-uses `templateSha`. Forced to `true` when the URL changed or no sha is stored. |
| `directCommit` (default false) | `directCommit` | Direct push, falls back to a PR on failure. |
| `includeBranches` (default empty) | `updateBranch` (one per matrix job) | Wildcards allowed. |
| (none) | `update` (`Y` in the update workflow, `N` in check mode) | Check versus update mode. |
| secret `ghTokenWorkflow` via `ReadSecrets` | `token` (base64) | Required only for `update = Y` and for private templates. |

### Settings that influence the update

| Setting | Where | Effect |
|---|---|---|
| `templateUrl` | settings file | Template and branch to check against. |
| `templateSha` | same, written by the update | Template commit currently applied. |
| `customALGoFiles` | repository settings | Extra include and exclude rules. |
| `commitOptions` | repository or workflow-specific settings | PR vs direct commit on schedule, message suffix, labels, auto-merge, merge method. |
| `workflowSchedule`, `workflowConcurrency` | workflow-specific settings only | Written into the yaml on update. |
| `updateALGoSystemFilesEnvironment` | repository settings | Environment of the update job. |
| `ghTokenWorkflowSecretName` | repository settings | Alternative secret name. |

### Secret formats

| Kind | Value of `GHTOKENWORKFLOW` |
|---|---|
| Classic PAT | `ghp_...` with scope `workflow` |
| Fine-grained PAT | `github_pat_...` with Contents, Pull requests, Workflows read/write and Actions read |
| GitHub App | `{"GitHubAppClientId":"<client id>","PrivateKey":"<PEM on one line>"}` (compressed JSON) |

### Naming produced by an AL-Go update

| Item | Format |
|---|---|
| Branch | `update-al-go-system-files/<updateBranch>/<yyMMddHHmmss UTC>` |
| Commit and PR title | `[<updateBranch>@<sha7>] Update AL-Go System Files from <owner>/<repo> - <templateSha7>` (+ ` / <messageSuffix>`) |
| PR body | New release notes since the installed version, from `.github/RELEASENOTES.copy.md`, or `No release notes available!` |

### Messages

| Message | Meaning |
|---|---|
| `There are updates for your AL-Go system, run 'Update AL-Go System Files' workflow to download the latest version of AL-Go.` | Check mode found differences. |
| `No updates available for AL-Go for GitHub.` | Check mode found none, or update mode had nothing to commit. |
| `Pull request already exists for ...` | Duplicate-PR guard. |
| `The GhTokenWorkflow secret is needed. ...` | Update mode without a token. |
| `Failed to update AL-Go System Files ... not expired and it has permission to update workflows.` | Push or PR failed. |
| `GitHub actions are not allowed to create Pull Requests ...` | `gh pr create` failed, typically the organization setting with `GITHUB_TOKEN`. |
