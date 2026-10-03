# Spike (h): Hugo content adapter at 628 pages

> **Status:** done 2026-10-03. Issue [#26](https://github.com/ALCops/rulebook-engine/issues/26), part of WP01 ([#3](https://github.com/ALCops/rulebook-engine/issues/3)). Blocks: WP14 ([#16](https://github.com/ALCops/rulebook-engine/issues/16)).

## Question

Does a Hugo content adapter (`content/_content.gotmpl`) create one page per entry of a 628-entry JSON data file within a few seconds on `ubuntu-latest`, and which Hugo version to pin?

## Method

1. **Data file.** A throwaway pwsh script joined `docs/rulebook/inventory/inventory.json` (`id`, `analyzer`, `title`, `docs` as `docsUrl`, `default`, `enabled` as `enabledByDefault`) with the 12 `<level>.<stage>` cells per id of `docs/rulebook/matrix/resolved.json`, and with `levels.json` and `stages.json`, into one `rulebook.json` shaped per [dashboard.md §5](../../dashboard.md#5-data-contract): top-level `generatedAt`, `repository`, `baseUrl`, `issueTemplate`, `levels[]`, `stages[]`, `rules[]`, `overrides[]` (empty), `quarantine{}` (empty); each rule has `justifications{}` (empty) and `cells."<level>.<stage>": {action, source}`. `source` is an approximation (`stage:<slug>` when the cell differs from the level's `default` stage, else `default` when the action equals the analyzer default, else `level:<slug>`); WP14 takes it from the generator. Result: **628 rules, 1,002,175 bytes** (LF, pretty-printed by `ConvertTo-Json`; 4 levels × 3 stages).
2. **Site.** A minimal theme-less site, built locally first with Hugo 0.165.0 extended on Windows, then committed temporarily under `.github/spike-h/site/`:
   - `hugo.yaml`: `baseURL`, `title`, `disableKinds: [taxonomy, term, rss, sitemap]`;
   - `layouts/index.html`: prints `len .Site.Data.rulebook.rules`, the number of pages in section `rules` and a link list;
   - `layouts/rules/single.html`: title, analyzer, default, docs link and a table over `.Params.cells`;
   - the same file in `data/rulebook.json` and `assets/rulebook.json`, and four content directories that differ only in the adapter's first line, selected with `--contentDir`:

   | Variant | First line of `_content.gotmpl` |
   |---|---|
   | `data` | `{{ $data := .Site.Data.rulebook }}` |
   | `readfile` (variant B) | `{{ $data := os.ReadFile "data/rulebook.json" \| transform.Unmarshal }}` |
   | `resources` | `{{ $data := resources.Get "rulebook.json" \| transform.Unmarshal }}` (file under `assets/`) |
   | `hugodata` | `{{ $data := hugo.Data.rulebook }}` (added after the local build printed the `.Site.Data` deprecation) |

   The rest of the adapter is shared and uses only `dict`, `printf`, `range` and `with`, so it parses on 0.126:

   ```
   {{ with $data }}{{ warnf "spike-h probe variant=data rules=%v" (len .rules) }}{{ else }}{{ warnf "spike-h probe variant=data data=nil" }}{{ end }}
   {{ range $data.rules }}
     {{ $content := dict "mediaType" "text/markdown" "value" (printf "Rule %s" .id) }}
     {{ $params := dict "ruleId" .id "analyzer" .analyzer "default" .default "cells" .cells "docsUrl" .docsUrl }}
     {{ $page := dict "path" (printf "rules/%s" .id) "title" .title "kind" "page" "content" $content "params" $params }}
     {{ $.AddPage $page }}
   {{ end }}
   ```

   The `warnf` probe answers "is the data available inside the adapter" in the build log: `rules=628` means yes, `data=nil` would mean no.
3. **Workflow.** A throwaway `spike-h.yml` (`workflow_dispatch` plus push on `wp01/spike-h`, `permissions: contents: read`, `ubuntu-latest`, 30 minute timeout, removed before the pull request; last version at `6dbe799:.github/workflows/spike-h.yml`) ran a matrix over Hugo **0.167.0** (latest stable, released 2026-09-28), **0.165.0** (the local version) and **0.126.0** (the documented content-adapter floor). Per version:

   ```bash
   curl -sSfLO "$base/hugo_extended_${HUGO_VERSION}_linux-amd64.deb"
   curl -sSfLO "$base/hugo_${HUGO_VERSION}_checksums.txt"
   grep " ${deb}\$" "hugo_${HUGO_VERSION}_checksums.txt" | sha256sum -c -
   sudo dpkg -i "$deb"
   # per variant: three timed builds (median of the wall time), then one with metrics
   hugo --source "$SITE" --contentDir "content-$v" --printPathWarnings
   hugo --source "$SITE" --contentDir "content-$v" --printPathWarnings --templateMetrics --templateMetricsHints
   du -sh "$SITE/public"; find "$SITE/public" -name index.html | wc -l
   ```

   Each build started from a clean `public/` and `resources/`. Wall time is `date +%s.%N` around the process; Hugo's own `Total in` line is reported next to it.

## Environment and versions

| Item | Value |
|---|---|
| Date | 2026-10-03 |
| Runner image / OS | `ubuntu-latest` = ubuntu-24.04, image version 20260927.320.1; local Windows 11 Enterprise |
| Hugo (runner) | `hugo v0.167.0-3fff6fb5c267dacb26280c78dbe8c344054249c8+extended linux/amd64 BuildDate=2026-09-28T14:50:38Z`; `hugo v0.165.0-76a5e1880ab46688155b02e99bab9be2a6134492+extended linux/amd64 BuildDate=2026-08-12T14:26:28Z`; `hugo v0.126.0-32c967551be308fbd14e5f0dfba0ff50a60e7f5e+extended linux/amd64 BuildDate=2024-05-14T13:24:11Z` |
| Hugo (local) | `hugo v0.165.0-76a5e1880ab46688155b02e99bab9be2a6134492+extended windows/amd64` |
| Install | `hugo_extended_<v>_linux-amd64.deb` from the GitHub release, `sha256sum -c` against `hugo_<v>_checksums.txt` printed `OK` for all three; download plus `dpkg -i` took 2.1 s (0.167.0), 3.0 s (0.165.0) and 2.9 s (0.126.0) |
| Data file | `rulebook.json`, 628 rules, 1,002,175 bytes |

## Observed

Final run: [actions/runs/37145597032](https://github.com/ALCops/rulebook-engine/actions/runs/37145597032), all three jobs green.

| Hugo | Variant | Data in adapter | Exit | Pages | `index.html` files | `du -sh public` | Wall time, 3 runs (s) | Median (s) | Hugo `Total in` (ms) |
|---|---|---|---|---|---|---|---|---|---|
| 0.167.0 | `data` (`.Site.Data`) | yes, 628 | 0 | 629 | 629 | 5.1M | 0.171, 0.216, 0.171 | 0.171 | 134, 170, 134 |
| 0.167.0 | `readfile` | yes, 628 | 0 | 629 | 629 | 5.1M | 0.196, 0.226, 0.202 | 0.202 | 158, 175, 164 |
| 0.167.0 | `resources` | yes, 628 | 0 | 629 | 629 | 5.1M | 0.180, 0.175, 0.177 | 0.177 | 142, 137, 139 |
| 0.167.0 | `hugodata` (`hugo.Data`) | yes, 628 | 0 | 629 | 629 | 5.1M | 0.174, 0.172, 0.170 | 0.172 | 137, 135, 132 |
| 0.165.0 | `data` | yes, 628 | 0 | 629 | 629 | 5.1M | 0.136, 0.132, 0.150 | 0.136 | 107, 104, 120 |
| 0.165.0 | `readfile` | yes, 628 | 0 | 629 | 629 | 5.1M | 0.129, 0.182, 0.136 | 0.136 | 101, 143, 107 |
| 0.165.0 | `resources` | yes, 628 | 0 | 629 | 629 | 5.1M | 0.133, 0.133, 0.132 | 0.133 | 104, 105, 104 |
| 0.165.0 | `hugodata` | yes, 628 | 0 | 629 | 629 | 5.1M | 0.128, 0.132, 0.129 | 0.129 | 99, 102, 101 |
| 0.126.0 | `data` | yes, 628 | 0 | 629 | 629 | 5.1M | 0.173, 0.170, 0.158 | 0.170 | 141, 137, 127 |
| 0.126.0 | `readfile` | yes, 628 | 0 | 629 | 629 | 5.1M | 0.164, 0.199, 0.184 | 0.184 | 134, 165, 142 |
| 0.126.0 | `resources` | yes, 628 | 0 | 629 | 629 | 5.1M | 0.163, 0.176, 0.165 | 0.165 | 132, 144, 134 |
| 0.126.0 | `hugodata` | n/a | 1 | none | none | none | 0.037, 0.037, 0.035 | fails | 5, 4, 4 |

- **Pages 629** = 628 rule pages plus the home page; `public/` holds 629 `index.html` files (`public/index.html` and `public/rules/<id-lowercase>/index.html`). The `rules` section page is not rendered because the site has no `rules/list.html` (third warning below).
- **Output size:** 5.1M is `du -sh` on the runner (disk blocks, 4 KiB per small file). The HTML itself is about 0.85 MB: locally `du -sb public` gives 874,326 bytes (home page 83,744 bytes with 628 links, a rule page about 1.2 KB).
- **Local Windows** (0.165.0, one build per variant): the same 629 pages and the same probe output; `Total in` 164 to 210 ms.
- **`--templateMetrics`** (0.167.0, variant `data`): `rules/single.html` 628 calls, 100.84 ms cumulative; `/_content.gotmpl` 1 call, 35.70 ms; `index.html` 14.56 ms. The adapter itself is a fraction of the build; no cache hints were reported.
- **Map order:** `range $k, $c := .Params.cells` walks the map in key order (`complete.ci`, `complete.default`, ... `strict.vnext`), not in level and stage order. The matrix and rule templates must iterate `levels` and `stages` and look up `cells` by key.

<details><summary>Build output, Hugo 0.167.0, variant <code>data</code> (identical on 0.165.0 apart from the version line and timing)</summary>

```
Start building sites …
hugo v0.167.0-3fff6fb5c267dacb26280c78dbe8c344054249c8+extended linux/amd64 BuildDate=2026-09-28T14:50:38Z VendorInfo=gohugoio

WARN  deprecated: .Site.Data was deprecated in Hugo v0.156.0 and will be removed in a future release. Use hugo.Data instead.
WARN  spike-h probe variant=data rules=628
WARN  found no layout file for "html" for kind "section": You should create a template file which matches Hugo Layouts Lookup Rules for this combination.

                  │ EN
──────────────────┼─────
 Pages            │ 629
 Paginator pages  │   0
 Non-page files   │   0
 Static files     │   0
 Processed images │   0
 Aliases          │   0
 Cleaned          │   0

Total in 134 ms
```

The `readfile`, `resources` and `hugodata` variants print the same three warnings (the deprecation then comes from `layouts/index.html`, which still uses `.Site.Data`). `--printPathWarnings` printed nothing in any build.

</details>

<details><summary>Build output, Hugo 0.126.0, variants <code>data</code> and <code>hugodata</code></summary>

```
WARN  spike-h probe variant=data rules=628
WARN  found no layout file for "html" for kind "section": You should create a template file which matches Hugo Layouts Lookup Rules for this combination.
                   | EN
-------------------+------
  Pages            | 629
...
Total in 127 ms
```

```
Total in 4 ms
Error: error building site: process: readAndProcessContent: ".../content-hugodata/_content.gotmpl:1:12": template: .../content-hugodata/_content.gotmpl:1:12: executing ".../content-hugodata/_content.gotmpl" at <hugo>: can't evaluate field Data in type interface {}
```

No deprecation warning on 0.126.0. `hugo.Data` arrived in 0.156.0 together with the deprecation of `.Site.Data` (release note: "hugolib: Move site.Data to hugo.Data", gohugoio/hugo#14521).

</details>

## Answer

Yes: one content adapter builds all 628 rule pages from one 1 MB `rulebook.json` in **about 0.13 to 0.2 s** of build time on `ubuntu-latest` (median 0.171 s on 0.167.0, 0.136 s on 0.165.0), plus 2 to 3 s to download and install Hugo; the output is 629 HTML pages, about 0.85 MB of HTML (5.1M on disk). The Publish action pins **`HUGO_VERSION: 0.167.0`** (latest stable on 2026-10-03, extended `.deb` with checksum). The data **is** available inside the adapter: `.Site.Data`, `hugo.Data`, `os.ReadFile | transform.Unmarshal` and `resources.Get | transform.Unmarshal` all saw 628 rules. The file's home stays **`site/data/rulebook.json`**, read as **`hugo.Data.rulebook`** because `.Site.Data` is deprecated since 0.156.0; that makes the **version floor 0.156.0** for the shipped templates (0.126.0 builds the same site only through `.Site.Data`, `os.ReadFile` or `resources.Get`). `assets/` brings nothing here: the site does not process the file as a resource.

## Consequences for blocked work packages

| WP | Consequence | Action taken |
|---|---|---|
| WP14 ([#16](https://github.com/ALCops/rulebook-engine/issues/16)) | Pin `HUGO_VERSION: 0.167.0` (extended `.deb`, checksum from `hugo_<v>_checksums.txt`); templates read `hugo.Data.rulebook` instead of `.Site.Data.rulebook`, so the floor is 0.156.0, not 0.126; keep the file in `site/data/`; add `layouts/rules/list.html` (or `section` in `disableKinds`) to silence the section warning; iterate `levels` × `stages` and look up `cells` by key, because ranging over `cells` sorts the keys. | [dashboard.md](../../dashboard.md#11-open-questions) Q4 and [ADR 0031](../../adr/0031-the-dashboard-is-a-hugo-site-shipped-in-the-template-and.md) link this file; comment posted on [#16](https://github.com/ALCops/rulebook-engine/issues/16#issuecomment-5972389368) |
| WP05 (Publish action) | The Hugo step costs about 3 s of install and well under 1 s of build at 628 rules; no vendoring or caching is needed (dashboard.md Q4). | None (recorded here) |

## Not covered

- Partials, `matrix.js`, `cart.js` and the full 628 × 12 grid on the home page: the spike renders a link list, not the matrix, so the production build will be slower (expected still well under a second, not measured).
- Hugo versions between 0.126.0 and 0.165.0: the 0.156.0 floor for `hugo.Data` comes from the release note, not from a build.
- `--minify`, `--baseURL` with a sub-path, and multiple languages.
- The real `source` per cell: the spike approximated it; the generator records which input won.

## Artifacts

- Final run: <https://github.com/ALCops/rulebook-engine/actions/runs/37145597032> (the job summary per Hugo version holds the table above and the build output per variant).
- Earlier iteration: [37145548193](https://github.com/ALCops/rulebook-engine/actions/runs/37145548193) (same results for 0.167.0 and 0.165.0; the 0.126.0 job stopped at the expected `hugo.Data` failure because the step ran under `bash -e`).
- The throwaway workflow `.github/workflows/spike-h.yml` and the site under `.github/spike-h/site/` lived on `wp01/spike-h` and were removed in the last commit before the pull request; the version the final run executed is `6dbe799` (`git show 6dbe799:.github/workflows/spike-h.yml`, site at `6dbe799:.github/spike-h/site/`). No scratch repository was created. Nothing besides this file, the Q4 pointer in dashboard.md and the link in ADR 0031 is kept in the repository.
