# The GHTOKENWORKFLOW secret

The update workflow writes to your rulebook repository: it changes files under `.github/workflows/`, pushes a branch and opens a pull request. It does that with a token from the secret `GHTOKENWORKFLOW`, the same secret and value format AL-Go for GitHub uses. An organization that runs AL-Go can reuse its secret and GitHub App. The Scan Diagnostics workflow ([quarantine.md](quarantine.md)) uses the same secret, found the same way through `ghTokenWorkflowSecretName`, and exchanges a GitHub App value for a token the same way; it pushes the branch `scan-diagnostics/<branch>` and opens or updates its pull request with the same app permissions as the update, and its push failures name the secret too. The Change Rule workflow ([changing-a-rule.md](changing-a-rule.md)) uses the same secret in the same way to push `change-rule/<id>/<timestamp>` (or a direct commit) and open its pull request; it needs the secret only for a change it actually writes.

> **Status:** written 2026-10-07 with the update work package of the engine ([WP07, #9](https://github.com/ALCops/rulebook-engine/issues/9)); the decision is [D44](https://github.com/ALCops/rulebook-engine/blob/main/docs/adr/0044-the-write-token-secret-is-ghtokenworkflow-in-al-go-format.md). How the update uses the token: [updating.md](updating.md) and the engine's [update-mechanics.md](https://github.com/ALCops/rulebook-engine/blob/main/docs/reference/update-mechanics.md) section 6.

## Contents

1. [Why the workflow token is not enough](#1-why-the-workflow-token-is-not-enough)
2. [A GitHub App (recommended)](#2-a-github-app-recommended)
3. [A personal access token](#3-a-personal-access-token)
4. [Where to put the secret](#4-where-to-put-the-secret)
5. [A private template](#5-a-private-template)
6. [Troubleshooting](#6-troubleshooting)

## 1. Why the workflow token is not enough

- The `GITHUB_TOKEN` of a run can never get the Workflows permission, so a push that changes `.github/workflows/` is refused. The update rewrites workflow files.
- A pull request opened with `GITHUB_TOKEN` starts no workflow, so Validate would not run on the update.
- Organizations can forbid GitHub Actions to create pull requests at all.

The update workflow therefore keeps `GITHUB_TOKEN` read-only (`contents: read`, `actions: read`) and writes only with the token from the secret.

## 2. A GitHub App (recommended)

A GitHub App gives the update a short-lived token for one repository at a time. The pull request shows the App as its author, tagged **bot**; the commit itself is authored by the account that started the run, as `<account>@users.noreply.github.com` (both observed for a run started by hand; for a scheduled run, code-derived, it is the account GitHub names as the run's actor, normally the one that last changed the schedule). The private key never leaves the runner.

1. **Register the App.** For an organization: `https://github.com/organizations/<org>/settings/apps/new`. For a personal account: <https://github.com/settings/apps/new>.
   - Name: anything unique, for example `contoso-rulebook`. Homepage URL: any URL, for example your rulebook repository.
   - Leave the callback URL and the setup URL empty. Under **Webhook**, untick **Active**.
   - **Repository permissions:** Contents **Read and write**, Pull requests **Read and write**, Workflows **Read and write**, Actions **Read-only**. Metadata becomes Read-only by itself. No organization or account permissions.
   - Where it can be installed: only on this account.
   - Create the App and note its **Client ID** (it starts with `Iv`).
2. **Generate a private key**: on the App's page, "Private keys" > "Generate a private key". A `.pem` file downloads.
3. **Install the App**: "Install App" > your organization or account > "Only select repositories" > your rulebook repository (and the template repository if it is private, [section 5](#5-a-private-template)).
4. **Build the secret value.** The value is compressed JSON (one line) with the Client ID and the key. In PowerShell 7:

   ```powershell
   $githubAppClientId = 'Iv23li...'
   $privateKeyFile = 'C:\Users\you\Downloads\contoso-rulebook.2026-10-07.private-key.pem'
   @{ "GitHubAppClientId" = $githubAppClientId; "PrivateKey" = ([string]::Join('', [System.IO.File]::ReadAllLines($privateKeyFile))) } | ConvertTo-Json -Compress -Depth 99 | Set-Clipboard
   ```

   Paste the clipboard as the secret value ([section 4](#4-where-to-put-the-secret)). Or pipe the JSON straight into the GitHub CLI instead of `Set-Clipboard`: `... | gh secret set GHTOKENWORKFLOW -R <owner>/<repository>`.

   The value must be one line. GitHub masks each line of a multi-line secret separately, which would print parts of the JSON in the logs.

On every run the update exchanges the App JSON for an installation token. The token is valid for one hour, limited to the rulebook repository, and has exactly the permissions above. It is masked in the log before anything else runs.

**To confirm it works**, run Actions > **Update Rulebook System Files** once: the log shows "Write token: app" (`pat` for a personal access token) and the run ends with a pull request or "No updates available", not with one of the messages of section 6.

## 3. A personal access token

A personal access token is used as it is, without an exchange. The pull request shows the token's owner as its author, and the commit is authored by the account that started the run, as with an App (code-derived: the live test used an App).

- **Fine-grained token** (better): resource owner your organization, only the rulebook repository, repository permissions Contents, Pull requests and Workflows **Read and write**, Actions **Read-only** (Metadata comes by itself). If the template repository is private, the update reads it with the same token, so add the template repository to the token's repositories too (the permissions apply to both; the update only reads the template). A fine-grained token has one resource owner, so that works only when the template lives under the same owner; otherwise use a GitHub App installed on both, or a classic token ([section 5](#5-a-private-template)).
- **Classic token**: both the `repo` and the `workflow` scopes. It reaches every repository its owner can reach.

Give it a short expiration date and renew it before it runs out: an expired token fails the update (section 6). Store the token itself as the secret value.

## 4. Where to put the secret

- **Repository secret**: in the rulebook repository, Settings > Secrets and variables > Actions > New repository secret, name `GHTOKENWORKFLOW`. Or `gh secret set GHTOKENWORKFLOW -R <owner>/<repository>`.
- **Organization secret**: Organization settings > Secrets and variables > Actions, named `GHTOKENWORKFLOW`, with the rulebook repository in its repository access. An organization that already has the AL-Go secret only adds the rulebook repository to it, and installs the App on the repository.

A secret that is visible to the repository does not by itself give access: the App must also be installed on the repository, or the token must be allowed to reach it.

**Another name.** The workflow reads the secret name from the settings. To use a different secret, for example one kept apart from AL-Go:

```json
"ghTokenWorkflowSecretName": "RULEBOOK_TOKEN"
```

The name follows GitHub's rules for secret names: letters, digits and underscores, not starting with a digit, and not starting with `GITHUB_` (in any case). An invalid name is a C5 finding of the settings check in Validate, the update workflow's "Read the settings" step fails with "ghTokenWorkflowSecretName '`<name>`' is not a valid secret name", and the update never falls back to `GHTOKENWORKFLOW`.

## 5. A private template

The update downloads the template with the workflow token first. A public template, such as `ALCops/rulebook`, needs nothing more. When the template is private (an internal copy of the template, for example), the download is refused, and the update retries with the token from the secret:

- **GitHub App**: install the App on the template repository too. The update asks for a read-only token on it.
- **Personal access token**: the token must be able to read the template repository.

The Validate check reads with the workflow token only, so for a private template it reports "update check skipped". Updating still works.

## 6. Troubleshooting

The token rows below apply to the update and to the Scan Diagnostics workflow alike (the scan's message says "to scan diagnostics" where the update's says "to update system files"); the scan's own messages are in [quarantine.md](quarantine.md) section 8.

| Message | Cause | Fix |
|---|---|---|
| "The GHTOKENWORKFLOW secret is needed to update system files. Read https://github.com/ALCops/rulebook/blob/main/docs/ghtokenworkflow.md" (the message carries the configured name when `ghTokenWorkflowSecretName` is set) | No secret of that name is visible to the repository. | Create it (section 4). With another name, set `ghTokenWorkflowSecretName`. |
| "The GHTOKENWORKFLOW secret could not be used: The GitHub App `<client id>` has no installation on `<repository>` (HTTP `<status>`: ...)" | The installation lookup did not answer 200. That is the App not installed on the rulebook repository, but a wrong client id or private key gives the same text (code-derived: any answer other than 200, typically HTTP 401 for a bad JWT). | Check the installation (section 2, step 3) and the client id and key in the secret; rebuild the secret if the key was regenerated. |
| "... The GitHub App JSON in the token secret needs GitHubAppClientId and PrivateKey" or "... is not a PEM key" | The secret value is not the JSON of step 4. | Build it again with the one-liner. |
| "... could not get an installation token for `<repository>` (HTTP `<status>`: `<message>`)" | GitHub refused the token request; the status and message come from the API. Likely causes (code-derived, not observed): a permission of step 1 is missing, or the App is not installed on the repository; a wrong client id or private key fails one step earlier, at the installation lookup (the row above). | Compare the App's permissions with step 1 and its installation with step 3; rebuild the secret if the key was regenerated. |
| "Failed to update the Rulebook system files. Make sure that the token in the secret GHTOKENWORKFLOW is not expired and may write contents, pull requests and workflows ..." | Pushing failed: an expired personal access token, or no Workflows permission. | Renew the token or add the permission. |
| "Failed to create the pull request for the Rulebook system files. ... (Error was: ...)" | Look inside the "Error was:" part: if it begins with "Branch `<name>` was pushed.", the branch is pushed, the link to open the pull request by hand is there, and only the pull request was refused. Otherwise nothing was pushed: the token could not read the branch or the open pull requests before cloning. | Open it from the link when there is one; give the token Pull requests write and read access to the repository. |
| "update check skipped: Could not get the latest commit of ..." in Validate | A private template, which the workflow token cannot read. | Expected; the update itself uses the secret (section 5). |
