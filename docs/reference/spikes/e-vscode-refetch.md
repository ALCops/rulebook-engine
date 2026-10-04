# Spike (e): VS Code re-fetch

> **Status:** done 2026-10-04. Issue [#23](https://github.com/ALCops/rulebook-engine/issues/23), part of WP01 ([#3](https://github.com/ALCops/rulebook-engine/issues/3)). Blocks: WP11 ([#13](https://github.com/ALCops/rulebook-engine/issues/13)).

## Question

When does VS Code re-fetch a remote ruleset?

## Method

The scratch repository `Arthurvdv/rulebook-spike-endpoint` (public, from spike (a)) got one extra file, `e/ruleset.json`, served through raw and edited **in place**. It is the only file in that repository that a spike edited in place:

```json
{ "name": "Spike e", "rules": [ { "id": "AA0137", "action": "Error" } ] }
```

A flip script in the scratchpad rewrote `action` between `Error` and `None`, committed, pushed, and then polled the raw URL until the `etag` changed. Its core:

```bash
printf '{ "name": "Spike e", "rules": [ { "id": "AA0137", "action": "%s" } ] }\n' "$ACTION" > e/ruleset.json
git commit -qam "spike e: AA0137 -> $ACTION" && git push -q origin main
while [ "$(curl -sI "$URL" | awk -F': ' 'tolower($1)=="etag"{print $2}')" = "$OLD" ]; do sleep 10; done
```

Arthur opened a single-folder workspace in VS Code on Windows: the one-codeunit fixture of the common protocol (unused local variable `Unused` in `Probe`, so AA0137, CodeCop Warning by default), `.alpackages/System.app` 28.0.54265, and an `app.json` without `suppressWarnings`. Its `.vscode/settings.json`:

```json
{
  "al.enableCodeAnalysis": true,
  "al.codeAnalyzers": [ "${CodeCop}" ],
  "al.enableExternalRulesets": true,
  "al.ruleSetPath": "https://raw.githubusercontent.com/Arthurvdv/rulebook-spike-endpoint/main/e/ruleset.json",
  "al.packageCachePath": [ "./.alpackages" ]
}
```

Protocol: the executor flipped the remote file and waited for the new `etag`; only then did Arthur perform **one** trigger and report the Problems pane within about 30 s. A flip was made only once the editor matched the remote, so every trigger started from a known stale state: editor showing the old severity, remote serving the new one. A trigger that changed nothing left the editor stale, and the next trigger ran on the same state without a new flip. Five flips in all (one initial create plus four).

Baseline, before any flip: AA0137 at **Error**, "Variable 'Unused' is unused in 'Probe'." The `alc` cross-check of the fallback was skipped: `alc` aborts on AL1033 ([spike a](a-hosts-and-skeleton-include.md)), so it has no fallback to compare with.

## Environment and versions

| Item | Value |
|---|---|
| Date | 2026-10-04 |
| OS | Windows 11 Enterprise 10.0.26200 |
| VS Code | 1.140.0 |
| AL extension | `ms-dynamics-smb.al@18.0.2819426` (from `code --list-extensions --show-versions`) |
| Platform symbols | `microsoft.platform.symbols` 28.0.54265 (`System.app`) |
| Analyzers | CodeCop only |
| Endpoint | `raw.githubusercontent.com`, `Cache-Control: max-age=300`, `Arthurvdv/rulebook-spike-endpoint` `main` `e/ruleset.json` |
| Code read for the prediction | `nav-sdk-source`, `Microsoft.Dynamics.Nav.EditorServices.Protocol/net10.0` |

## Observed

### Prediction from the code

`VsCodeWorkspace.AddOrUpdateProjectFromPath` reads the ruleset on every call: `settings.GetRuleSetPath()` at line 362, then `CommonCompiler.TryReadRuleSetAndApplyToOptions` at line 399 (existing project) or line 412 (new project). The new options replace the project's options whenever they differ (`UpdateDependencies`, `WithProjectCompilationOptions`). There is no cache: `RuleSetLoader` fetches every time it is asked. The callers are:

| Caller | LSP message | Predicted re-read |
|---|---|---|
| `ProjectRequestHandler.TryAddOrUpdateProject`, via `DidChangeConfigurationRequestHandler` and `SetActiveWorkspaceRequestHandler` | `workspace/didChangeConfiguration`, `al/setActiveWorkspace` (project load) | yes, whenever the client sends the message |
| `DidSaveTextDocumentRequestHandler.ReloadProject`, only when the saved file is named `app.json` | `textDocument/didSave` | yes for `app.json`; no for `.al` files |
| `DidChangeAlWorkspaceFoldersRequestHandler`, `DebugAdapterStartRequestHandler` | workspace folder change, debug start | yes (not tested) |

The code does not show which configuration changes the extension forwards as `didChangeConfiguration`; only the experiment answers that.

### Triggers

| Trigger | Remote flip before it (pushed, etag changed, CDN delay) | Re-fetched (diagnostics changed) | Latency | Side effects |
|---|---|---|---|---|
| Baseline (folder opened) | create at `Error` (09:45:27, 09:46:22, 52 s after a 404) | yes: AA0137 Error | on load | none reported |
| (a) Edit and save the `.al` file | `Error` → `None` (09:56:00, 09:57:36, 94 s) | **no**: AA0137 stayed Error | n/a | none |
| (b) Edit `app.json` (`version` 1.0.0.0 → 1.0.0.1) and save | none (editor still stale after (a)) | **yes**: AA0137 gone (`None`) | instant on save | none reported |
| (c) Add `"editor.fontSize": 15` to `.vscode/settings.json` and save | `None` → `Error` (10:04:51, 10:08:31, 217 s) | **no**: AA0137 stayed gone | n/a | none |
| (d) `"al.enableCodeAnalysis": false`, save, then `true`, save | none (editor still stale after (c)) | **yes**: AA0137 back at Error after the **on**-save | on save | the off-save shows nothing either way, because AA0137 cannot appear while analysis is off |
| (e1) `al.ruleSetPath` → `.../e/does-not-exist.json` (404), save | none (editor in sync at Error after (d)) | **yes**: AA0137 at **Warning** (its default) plus **AL1033** | within 30 s | AL1033 shown on `app.json` (message text not captured); editing without saving does nothing |
| (e2) `al.ruleSetPath` back to `.../e/ruleset.json`, save | none | **yes**: AL1033 gone, AA0137 back at Error | under 1 s on save | none |
| (f) `AL: Download symbols` | `Error` → `None` (10:18:23, 10:22:45, 258 s) | **no**: AA0137 stayed Error | n/a | command outcome not captured |
| (g) `Developer: Reload Window` | none (editor still stale after (f)) | **yes**: AA0137 gone | after the reload completed | none reported |
| (h) File > Close Folder, reopen from Open Recent | `None` → `Error` (10:28:52, 10:33:04, 248 s) | **yes**: AA0137 back at Error | as soon as the AL extension finished loading | none |

No status-bar hint or notification asking for a reload appeared at any step, and the "AL Language" output channel showed no ruleset lines that Arthur reported.

### Extra check: `suppressWarnings` on `app.json` save

Spike (f) saw a `suppressWarnings` change take effect only after Developer: Reload Window. After (h), with the endpoint stable at `Error`, Arthur ran one extra check in the same folder:

| Step | Result |
|---|---|
| X1: add `procedure Caller() begin Probe; end;` to the codeunit and save | **AA0008** (Warning, its default, not listed by the endpoint) appears on `Probe;` |
| X2: add `"suppressWarnings": [ "AA0008", "AA0137" ]` to `app.json` and save, no reload | AA0008 **gone** at once; AA0137 **still Error** (listed by the endpoint, so `suppressWarnings` is a no-op for it, as in spike (f)) |

A `suppressWarnings` change in `app.json` therefore takes effect on save, with no reload, when the file is saved from the editor. The difference from spike (f) V2 is most likely in how the change was made. Saving in the editor sends `textDocument/didSave` for `app.json`, which runs `ReloadProject`. Replacing the file on disk (spike (f) copied a variant file into `app.json`) sends no `didSave`, so nothing is re-read. This explanation comes from the code and was not reproduced.

### CDN delays

Raw `Cache-Control: max-age=300`. The time from `git push` to the first changed `etag` on `curl -sI`, polled every 10 s:

| Flip | Delay |
|---|---|
| create `Error` (after a cached 404) | 52 s |
| `Error` → `None` | 94 s |
| `None` → `Error` | 217 s |
| `Error` → `None` | 258 s |
| `None` → `Error` | 248 s |

All five stayed under the 300 s cache window. Every `Error` version had the same `etag` (`"0ce5e008…9cf2"`) and every `None` version the same `"54b04175…1dbd"`, because the etag follows the content.

<details>
<summary>Endpoint headers at baseline</summary>

```text
HTTP/1.1 200 OK
Cache-Control: max-age=300
ETag: "0ce5e0080343a561ba35f9ca09ceac74b53b30ee8153b8aac1a6c35f781e9cf2"
Date: Sun, 04 Oct 2026 07:46:28 GMT
X-Cache: HIT
X-Cache-Hits: 1
```

</details>

### Prediction versus observation

| Prediction (code) | Observation |
|---|---|
| `.al` save does not re-read | confirmed (a) |
| `app.json` save re-reads (`ReloadProject`) | confirmed (b), and the `suppressWarnings` merge is reapplied too (X2) |
| `didChangeConfiguration` re-reads | confirmed for `al.*` settings (d), (e1), (e2); an unrelated setting (`editor.fontSize`) sends nothing that re-reads (c), so the extension forwards only the `al` section |
| Project load re-reads | confirmed (g), (h) |
| `AL: Download symbols` | does not re-read (f) |
| Fallback to `DefaultRuleSet` on a failing URL (language server only) | **observed** (e1): AL1033 on `app.json`, AA0137 at its default Warning |

## Answer

The AL extension (18.0.2819426) never re-fetches a remote ruleset by itself, and it shows no hint that the remote changed. It re-reads the ruleset, fetching the URL again, when one of these happens:
- `app.json` is saved from the editor;
- a change to an `al.*` setting is saved;
- the window is reloaded;
- the folder is reopened.

It does not re-read on an `.al` save, on a non-AL setting change, or on `AL: Download symbols`. When the URL fails, the editor does not stop: it shows AL1033 on `app.json` and falls back to the analyzers' default severities. The one-line instruction for the WP11 walkthrough:

> After the organization ruleset changes, run **Developer: Reload Window** (or save `app.json`) to pick up the new rules; allow up to 10 minutes after a publish for the endpoint's CDN cache (5 on raw).

## Consequences for blocked work packages

| WP | Consequence | Action taken |
|---|---|---|
| WP11 ([#13](https://github.com/ALCops/rulebook-engine/issues/13)) | The walkthrough gets the one-line instruction above. The troubleshooting rows: AL1033 on `app.json` with default severities means the endpoint failed (the editor falls back, `alc` aborts); a rule change not visible yet means CDN cache plus no reload. Spike (f)'s advice "reload the window after editing `suppressWarnings`" can become "save `app.json` in the editor"; Reload Window remains the safe fallback. | Comment posted on [#13](https://github.com/ALCops/rulebook-engine/issues/13#issuecomment-5978243689) |
| Docs | [compiler-ruleset-internals.md](../compiler-ruleset-internals.md) §7 said the language-server fallback came from the code, not observed; §9 said only reload or toggling the path setting pick up a change. [ARCHITECTURE.md](../../ARCHITECTURE.md) §2 and §10 said the same. | Updated in this pull request with links to this file |

## Not covered

- Pages as the host (`max-age=600`): only raw was used, as planned. The editor has no cache of its own, so only the CDN delay should differ.
- The full AL1033 message text in the editor and the AL Language output lines were not captured.
- Saving an unmodified `app.json` (Ctrl+S without a change), whether VS Code then sends `didSave`: not tried. The instruction therefore says "save `app.json`" in the sense of saving a change, and names Reload Window first.
- Replacing `app.json` on disk outside the editor, to confirm the explanation of the spike (f) difference: not reproduced.
- Other `al.*` settings, multi-root workspaces, `al/setActiveWorkspace` switching between folders, debug start, and the 15 s fetch timeout in the editor: not tested.
- The skeleton model (local `.rulebook/*.ruleset.json` including the URL): only the URL as `al.ruleSetPath` was tested. The code reads the skeleton and its includes through the same call, so the triggers are expected to be the same.
- Other AL extension versions.

## Artifacts

- Scratch repository `Arthurvdv/rulebook-spike-endpoint` (public, created 2026-10-04 by spike (a)). This spike's commits on `main`: `99a8fc1` (create, Error), `35d1a3d` (None), `5a48576` (Error), `679cab5` (None), `c3e5c7f` (Error). The repository is deleted by hand after WP01 (#3), with Arthur's confirmation; `e/does-not-exist.json` was never created.
- The flip script, the VS Code folder and the flip log stayed in the session scratchpad. No workflow was used. Nothing besides this file and the documentation updates is kept in the repository.
