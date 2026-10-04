# Spike (g): prefilled issue URL limit

> **Status:** done 2026-10-04. Issue [#25](https://github.com/ALCops/rulebook-engine/issues/25), part of WP01 ([#3](https://github.com/ALCops/rulebook-engine/issues/3)). Blocks: WP14 ([#16](https://github.com/ALCops/rulebook-engine/issues/16)), WP15 ([#17](https://github.com/ALCops/rulebook-engine/issues/17)).

## Question

How long may a prefilled `issues/new?template=...&changes=...` URL be before github.com rejects it or drops the field, and do issue-form query parameters prefill a `render: json` textarea intact (quotes, brackets, newlines)?

## Method

A throwaway public repository, `Arthurvdv/rulebook-spike-issue-form` (personal Free account, created 2026-10-04, commit `d7c59a9`), holds on `main`:

- `.github/ISSUE_TEMPLATE/rulebook-change.yml`, copied verbatim from [dashboard.md §7](../../dashboard.md#7-issue-form). That means: the name "Rulebook change", the title, the labels `[rulebook-change]`, the markdown intro, a required `textarea` with id `changes` and `render: json`, and an optional `textarea` with id `note`.
- `.github/ISSUE_TEMPLATE/config.yml` with `blank_issues_enabled: true`.
- The label `rulebook-change`, created with `gh label create`.

The generator (`spike-g.mjs`, Node, throwaway) builds a change set per [dashboard.md §6](../../dashboard.md#6-change-set) with N `set` items. Each item takes an id from `inventory.json`, rotates through the five actions, and has `levels: ["strict"]`, `stages: ["ci"]` and a 39-character justification. The justification holds a `+`, escaped quotes and brackets on purpose. N runs over 10, 20, 40, 80 and 160, and each set comes in two variants: pretty-printed (`JSON.stringify(cs, null, 2)`, so it has newlines) and minified. Every URL also carries `title` and a 60-character `note` that has `+`, `&`, quotes, brackets and braces in it. Key lines:

```js
const NOTE = 'Spike g: legacy + new "tables" & [brackets] {braces} 2026-10'; // 60 chars
justification: `Tracked in DEV-${String(1000 + i).padStart(4, '0')} + "legacy" [tables]`,
const u = `${BASE}&title=${encodeURIComponent(TITLE)}&changes=${encodeURIComponent(raw)}&note=${encodeURIComponent(NOTE)}`;
// BASE = https://github.com/Arthurvdv/rulebook-spike-issue-form/issues/new?template=rulebook-change.yml
// bytes = Buffer.byteLength(u)  (the URL is ASCII after encodeURIComponent, so bytes = characters)
```

For the bisection, `urlForTarget(bytes, pretty)` builds a URL of an exact byte length. It adds as many full items as fit, then pads the last item's justification with `x`. The N column in the tables below is the item count of that URL.

Runner (`run.mjs`, Playwright, throwaway). The key lines:

```js
const ctx = await chromium.launchPersistentContext(userDataDir, { channel: 'msedge', headless: false });
const resp = await page.goto(c.url, { waitUntil: 'domcontentloaded', timeout: 60000 });
r.status = resp.status();
await page.waitForLoadState('networkidle', { timeout: 20000 }).catch(() => {});
const changes = await page.getByLabel(/^Changes/).inputValue();       // accessible name is "Changes *"
r.jsonIdentical = changes === c.raw;
r.jsonIdenticalNorm = changes.replace(/\r\n/g, '\n') === c.raw;
const note  = await page.getByLabel(/^Note/).inputValue();
const title = await page.getByRole('textbox', { name: /title/i }).first().inputValue();  // "Add a title"
// The page is never submitted: the runner has no click at all.
```

The run went in five steps:

1. **Series:** N = 10, 20, 40, 80 and 160, pretty and minified.
2. **Bisection:** for each variant, between the last pass and the first fail, down to 256 bytes or less.
3. **Explicit checks:** 8100, 8209, 8210 and 8300 bytes. These test the boundary that curl had shown.
4. **Rerun:** a targeted rerun in a fresh order, plus a one-byte bisection between 8100 and 8193 for both variants.
5. **Repeat:** one rerun of the 83 KB case, to explain the connection resets seen in step 2.

A pass means all four of these: status 200, the form is shown, the `changes` value is identical to the generated JSON, and `note` and `title` are filled.

**Browser profiles.** The plan was to reuse Arthur's real Edge and Chrome profiles. That did not work, because both browsers refuse automation on their default user-data directory:

- Chrome 154 with `--profile-directory=Default` on `%LOCALAPPDATA%\Google\Chrome\User Data` printed `DevTools remote debugging requires a non-default data directory. Specify this using --user-data-dir.`
- Edge 154 with `--profile-directory=Profile 6` on `%LOCALAPPDATA%\Microsoft\Edge\User Data` printed the same line.
- In both cases Playwright then timed out at launch.

Edge therefore ran on a fresh persistent profile under the session scratchpad. Arthur signed in to github.com there once while the runner was stopped in `page.pause()`; after that the series ran unattended. The real profiles were never opened by Playwright and never modified, and the scratch profile was deleted after the measurements.

Chrome and Firefox were not tested. Chrome is "not tested: Chrome 136+ blocks automation on the default user-data dir, assumed equivalent to Edge (same engine)". Firefox was out of scope by decision.

**Server-side control.** curl ran without a session (`curl.exe --http1.1`, padded URLs `...&changes=xxxx`), to see GitHub's limit without a browser in between.

## Environment and versions

| Item | Value |
|---|---|
| Date | 2026-10-04 |
| OS | Windows 11 Enterprise 10.0.26200 |
| Node | v26.10.0 (Playwright's `engines` field is `node >=20`; no warning, no workaround) |
| Playwright | 1.63.0 (`npm i -D playwright`, no browser download; `channel: 'msedge'`) |
| Browser tested | Microsoft Edge 154.0.4258.53, fresh scratch profile, signed in to github.com; navigation protocol `h2` (`performance.getEntriesByType('navigation')[0].nextHopProtocol`) |
| Not tested | Chrome 154.0.8037.98 (refuses automation on its default user-data dir; assumed equivalent to Edge, same engine); Firefox (out of scope) |
| curl (server-side control) | curl 8.21.0 (Windows, Schannel), HTTP/1.1, anonymous |
| gh | 2.50.0 |
| Scratch repository | `Arthurvdv/rulebook-spike-issue-form`, public, `main` at `d7c59a9` |
| GitHub new-issue UI | The current React issue creation page: title box "Add a title", a "Create" button (not "Submit new issue"), and a Write/Preview markdown editor for the `note` textarea |

## Observed

URL sizes from the generator. Pretty-printing roughly doubles the URL, because `encodeURIComponent` turns every indent space into `%20` and every newline into `%0A`:

| N items | pretty JSON bytes | pretty URL bytes | minified JSON bytes | minified URL bytes |
|---|---|---|---|---|
| 10 | 2339 | 5500 | 1427 | 2764 |
| 20 | 4641 | 10682 | 2829 | 5246 |
| 40 | 9245 | 21046 | 5633 | 10210 |
| 80 | 18457 | 41778 | 11245 | 20142 |
| 160 | 36878 | 83239 | 22466 | 40003 |

The fixed part of the URL is 237 bytes: base, template, title, note and the empty `changes=`. On top of that, one item costs about 248 bytes minified and about 518 bytes pretty-printed.

### Edge: series and first bisection (run 1)

| browser + version | N items | pretty/minified | URL bytes | status | final URL kind | changes filled | JSON byte-identical | identical after newline normalisation | note filled | title filled |
|---|---|---|---|---|---|---|---|---|---|---|
| Edge 154.0.4258.53 | 10 | pretty | 5500 | 200 | form | yes | yes | yes | yes | yes |
| Edge 154.0.4258.53 | 20 | pretty | 10682 | 414 | error page (414) | no | no | no | no | no |
| Edge 154.0.4258.53 | 40 | pretty | 21046 | 414 | error page (414) | no | no | no | no | no |
| Edge 154.0.4258.53 | 80 | pretty | 41778 | 414 | error page (414) | no | no | no | no | no |
| Edge 154.0.4258.53 | 160 | pretty | 83239 | none (`ERR_CONNECTION_CLOSED`) | browser error page | no | no | no | no | no |
| Edge 154.0.4258.53 | 15 | pretty | 8091 | none (follow-on of the reset) | browser error page | no | no | no | no | no |
| Edge 154.0.4258.53 | 12 | pretty | 6795 | none (follow-on of the reset) | browser error page | no | no | no | no | no |
| Edge 154.0.4258.53 | 11 | pretty | 6147 | none (follow-on of the reset) | browser error page | no | no | no | no | no |
| Edge 154.0.4258.53 | 10 | pretty | 5823 | 200 | form | yes | yes | yes | yes | yes |
| Edge 154.0.4258.53 | 11 | pretty | 5985 | 200 | form | yes | yes | yes | yes | yes |
| Edge 154.0.4258.53 | 10 | minified | 2764 | 200 | form | yes | yes | yes | yes | yes |
| Edge 154.0.4258.53 | 20 | minified | 5246 | 200 | form | yes | yes | yes | yes | yes |
| Edge 154.0.4258.53 | 40 | minified | 10210 | 414 | error page (414) | no | no | no | no | no |
| Edge 154.0.4258.53 | 80 | minified | 20142 | 414 | error page (414) | no | no | no | no | no |
| Edge 154.0.4258.53 | 160 | minified | 40003 | 414 | error page (414) | no | no | no | no | no |
| Edge 154.0.4258.53 | 30 | minified | 7728 | 200 | form | yes | yes | yes | yes | yes |
| Edge 154.0.4258.53 | 35 | minified | 8969 | 414 | error page (414) | no | no | no | no | no |
| Edge 154.0.4258.53 | 32 | minified | 8348 | 414 | error page (414) | no | no | no | no | no |
| Edge 154.0.4258.53 | 31 | minified | 8038 | 200 | form | yes | yes | yes | yes | yes |
| Edge 154.0.4258.53 | 32 | minified | 8193 | 414 | error page (414) | no | no | no | no | no |
| Edge 154.0.4258.53 | 31 | minified | 8100 | 200 | form | yes | yes | yes | yes | yes |
| Edge 154.0.4258.53 | 32 | minified | 8209 | 414 | error page (414) | no | no | no | no | no |
| Edge 154.0.4258.53 | 32 | minified | 8210 | 414 | error page (414) | no | no | no | no | no |
| Edge 154.0.4258.53 | 32 | minified | 8300 | 414 | error page (414) | no | no | no | no | no |

The pretty-printed bisection in run 1 was disturbed by the 83 KB request that came just before it:

- GitHub closed the HTTP/2 connection on that request (`net::ERR_CONNECTION_CLOSED`).
- Chromium's error page then reloads itself, and those reloads interrupted the next `page.goto` calls (`Navigation ... is interrupted by another navigation to "chrome-error://chromewebdata/"`, and in the rerun also a 60 s timeout).
- So run 1 bisected to a wrong 5985/6147 boundary for pretty JSON.
- Rerun 3 showed the same sequence again: 83239 closed the connection, three 6147-byte navigations right after it failed, and later navigations passed again.

This is an effect of the test harness reusing one tab. A cart URL of 8 KB or less never gets near it.

### Edge: rerun in a fresh order and one-byte bisection (run 2)

| browser + version | N items | pretty/minified | URL bytes | status | final URL kind | changes filled | JSON byte-identical | identical after newline normalisation | note filled | title filled |
|---|---|---|---|---|---|---|---|---|---|---|
| Edge 154.0.4258.53 | 11 | pretty | 6147 | 200 | form | yes | yes | yes | yes | yes |
| Edge 154.0.4258.53 | 12 | pretty | 6500 | 200 | form | yes | yes | yes | yes | yes |
| Edge 154.0.4258.53 | 13 | pretty | 7000 | 200 | form | yes | yes | yes | yes | yes |
| Edge 154.0.4258.53 | 13 | pretty | 7500 | 200 | form | yes | yes | yes | yes | yes |
| Edge 154.0.4258.53 | 14 | pretty | 8000 | 200 | form | yes | yes | yes | yes | yes |
| Edge 154.0.4258.53 | 15 | pretty | 8100 | 200 | form | yes | yes | yes | yes | yes |
| Edge 154.0.4258.53 | 15 | pretty | 8150 | 200 | form | yes | yes | yes | yes | yes |
| Edge 154.0.4258.53 | 23 | minified | 6147 | 200 | form | yes | yes | yes | yes | yes |
| Edge 154.0.4258.53 | 27 | minified | 7000 | 200 | form | yes | yes | yes | yes | yes |
| Edge 154.0.4258.53 | 31 | minified | 8150 | 200 | form | yes | yes | yes | yes | yes |
| Edge 154.0.4258.53 | 15 | pretty | 8193 | 414 | error page (414) | no | no | no | no | no |
| Edge 154.0.4258.53 | 32 | minified | 8193 | 414 | error page (414) | no | no | no | no | no |
| Edge 154.0.4258.53 | 20 | pretty | 10682 | 414 | error page (414) | no | no | no | no | no |
| Edge 154.0.4258.53 | 32 | minified | 8190 | 200 | form | yes | yes | yes | yes | yes |
| Edge 154.0.4258.53 | 32 | minified | 8191 | 200 | form | yes | yes | yes | yes | yes |
| Edge 154.0.4258.53 | 32 | minified | 8192 | 414 | error page (414) | no | no | no | no | no |
| Edge 154.0.4258.53 | 15 | pretty | 8190 | 200 | form | yes | yes | yes | yes | yes |
| Edge 154.0.4258.53 | 15 | pretty | 8191 | 200 | form | yes | yes | yes | yes | yes |
| Edge 154.0.4258.53 | 15 | pretty | 8192 | 414 | error page (414) | no | no | no | no | no |

The one-byte bisection also passed at 8146, 8169, 8181 and 8187 for both variants; those rows are left out above.

Across all three runs there were 33 responses with status 200. In every one of them the `changes` value was byte-identical to the generated JSON with no normalisation needed, `note` was identical, and `title` was `Rulebook change spike`. There were 18 responses with status 414. The largest URL that passed was 8191 bytes; the smallest that got 414 was 8192 bytes.

| Per browser | Edge 154.0.4258.53 |
|---|---|
| First URL length with a non-200 | **8192 bytes**: `414`, GitHub's "Whoa there! Your request URL is too long." page. Pretty and minified break at the same byte count. |
| First length with an empty field and a 200 (silent drop) | none observed: every 200 had all three fields filled |
| `title` and `note` next to a large `changes` | survive up to 8191 bytes; above that the whole page is the 414, so no field is filled at all |
| Above about 80 KB | GitHub closes the connection without a status (`ERR_CONNECTION_CLOSED` at 83239 bytes; 41778 bytes still got a clean 414) |

<details>
<summary>Server-side control with curl (anonymous, HTTP/1.1)</summary>

The URL is `BASE&changes=xxxx...` padded to the given length. Without a session GitHub redirects `/issues/new` to `/login` with the whole URL in `return_to`. That makes the codes below 8210 depend on the login redirect, not on the issue form.

```text
URL bytes   status
5246-7000   302 (to /login?return_to=...)
~7050-8011  500 (boundary moved between runs)
8012-8209   502
8210        414
```

Over HTTP/1.1 the 414 starts when the request target (path and query) reaches 8192 bytes: 8210 − 18 for `https://github.com`. Edge over HTTP/2 hits 414 when the **full URL** reaches 8192 bytes, which is 18 bytes earlier. The browser number is the one the cart has to use.

</details>

Screenshots, kept in the scratchpad and not committed:

- **Baseline, N = 10 pretty, 5500 bytes:** the form "Create new issue" under "Rulebook change". The title box holds `Rulebook change spike`. The *Changes* box shows the pretty-printed JSON with its indentation. The *Note* markdown editor shows the note with `+`, quotes, `&`, brackets and braces intact. The `rulebook-change` label is preselected in the sidebar, and the button is "Create".
- **First failure, 10682 bytes:** GitHub's plain error page, "Whoa there! Your request URL is too long.", with links to Contact Support and GitHub Status.

## Answer

GitHub rejects a prefilled issue URL with **`414 URI Too Long` once the full URL reaches 8192 bytes**. The last length that worked in Edge 154 was 8191 bytes. The limit is on GitHub's side, not in the browser: Chromium navigated to 41 KB URLs and got GitHub's 414 page back, and anonymous curl gets the same 414 at the same order of size. Below the limit no field was ever silently dropped.

The cart should measure the whole URL it opens, including owner, repository and template name, because the limit counts the full URL. It should allow at most **7372 bytes** (90 % of 8192). That leaves room for longer owner and repository names and for a future change in GitHub's limit.

A `render: json` textarea is prefilled **byte-identical**: quotes, brackets, braces, newlines and `+` (sent as `%2B`) all survive without any normalisation. `title` and `note` survive next to a `changes` value that fills the URL up to the limit.

Measured in Edge only. Chrome was not tested: Chrome 136+ blocks automation on its default user-data dir; it is assumed equivalent to Edge (same engine). Firefox was not tested.

**dashboard.md Q1** asks whether a compact encoding is worth a second parser. It is not. At the 7372-byte budget, minified JSON holds about 28 changes with a 40-character justification each, or 46 without one. That is enough for one review sitting, and the split and copy routes cover larger carts. A compact form such as `LC0015=None@strict/ci` would hold about 228. But it drops justifications, the user cannot read it as the schema, and WP15 would need a second parser for it.

The cart should send **minified** JSON. Pretty-printing costs twice the bytes (about 13 items with a justification fit).

## Consequences for blocked work packages

| WP | Consequence | Action taken |
|---|---|---|
| WP14 ([#16](https://github.com/ALCops/rulebook-engine/issues/16)) | The cart measures the full prefilled URL and shows it against **7372 bytes**, which is 90 % of GitHub's measured 8192-byte rejection threshold. Above that budget it offers split or copy. The change set is serialized minified: about 28 changes with justifications fit, about 46 without. No compact encoding. An over-limit URL gives GitHub's 414 page, not a silently emptied form, but the cart must never open one. | [dashboard.md](../../dashboard.md) §7 (URL limit) and Q1 updated in this pull request; comment posted on #16 |
| WP15 ([#17](https://github.com/ALCops/rulebook-engine/issues/17)) | The parser can assume that the `changes` textarea holds exactly the JSON the dashboard generated, byte for byte (no CRLF conversion, `+` and quotes intact), in minified form. There is no compact-encoding parser. The new-issue page labels its button "Create" (dashboard.md §7 says "Submit new issue"). The issue body produced on submit was not observed, because nothing was submitted. | Comment posted on #17 |
| D32 ([ADR 0032](../../adr/0032-dashboard-writes-go-through-a-prefilled-github-issue-form.md)) | The URL limit it calls unknown is now measured. | One sentence with a link added in this pull request |

## Not covered

- **Chrome and Firefox.** Chrome 154 refused the default profile; by decision Edge only, with Chrome assumed equivalent. Firefox was out of scope.
- **The submitted issue body.** Nothing was submitted, so the body of an issue created from this form was not observed. That covers the ```` ```json ```` fence that `render: json` adds and how `note` appears in the body. WP15 tests that against its own fixture.
- **Non-ASCII content.** A justification or note with non-ASCII characters takes 6 to 12 URL bytes per character after `encodeURIComponent`. The cart counts bytes of the encoded URL, so this is covered by measuring, but it was not exercised.
- **Logged-out users.** A user without a session is redirected to `/login?return_to=<the whole URL>`. curl saw 500 and 502 errors for that redirect from about 7 KB upward. Whether a logged-out user who signs in comes back to a filled form near the limit was not tested.
- **The exact connection-close threshold** between 41778 bytes (414) and 83239 bytes (connection closed). It is irrelevant for a cart capped at about 7 KB.

## Artifacts

- Scratch repository `Arthurvdv/rulebook-spike-issue-form` (public), created 2026-10-04, at commit `d7c59a9`: `README.md`, `.github/ISSUE_TEMPLATE/rulebook-change.yml`, `.github/ISSUE_TEMPLATE/config.yml`, and the label `rulebook-change`. No issue was ever created in it. It is to be deleted after this spike, once Arthur confirms.
- Generator, runner, result JSON and screenshots stayed in the session scratchpad. The scratch Edge profile was deleted after the measurements.
- Nothing besides this file and the link edits in `docs/dashboard.md` and ADR 0032 is kept in the repository.
