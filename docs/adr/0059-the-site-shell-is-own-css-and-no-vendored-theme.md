# D59. The site shell is own CSS, not a vendored theme

- **Status:** Accepted
- **Date:** 2026-10-28

- **Decision:** the shell of the dashboard site is plain CSS and a small script that `site/` writes itself, with no vendored Hugo theme. The shell is the header, the dark mode, the mobile menu, the footer and the design tokens. This confirms the "no theme, no modules" sentence of D31 and keeps the vendored theme as a rejected alternative of D35.
- **Rationale:** decided in the WP16 execution interview of 2026-10-28; the owner chose on [#137](https://github.com/ALCops/rulebook-engine/issues/137) after the spike built the landing page and `stages/default/` twice, once on own CSS and once on a vendored Hextra 0.13.0 subset. The [spike record](../reference/spikes/wp16-shell/README.md) has the criteria table and the screenshots. Hextra met every hard constraint of [#136](https://github.com/ALCops/rulebook-engine/issues/136) after trimming, but bought little:
  - **Little of its shell survives.** Its navbar builds its links from the site configuration, not from `rulebook.json`. Its menu script throws without a sidebar container. Its footer is built around the theme credit. Its head and script partials fingerprint the asset paths. So the header, the menu, the footer, `baseof`, the head and the scripts were ours in both variants. What Hextra contributed was its compiled CSS and a theme toggle.
  - **The compiled CSS has a class gap.** It ships precompiled and holds only the utility classes Hextra itself uses. 14 of the classes our first layouts wrote did not exist and failed without an error. Every later layout (drawer, setup buttons, help) would be limited to that vocabulary or to `site.css`.
  - **Its dark mode needs JavaScript.** Hextra switches through a class that a script sets, so without JavaScript the site stays light even on a dark system. Own CSS follows the system setting through `prefers-color-scheme` with no script.
  - **Volume.** The subset is 12 files and 163,141 bytes under `site/themes/hextra/`; the compiled CSS alone is 144,984 bytes. Every organization repository would carry those files, and the three-way compare of every update (D35) would cover them. Own CSS adds no file under `themes/`; its `site.css` is 15,881 bytes.
  - **Maintenance per release.** A Hextra release means copying the 12 files again and repeating three trims, then checking that every `hx:` class of our layouts (155 in the spike) still exists in the new CSS, because a dropped class fails silently. The three trims:
    - the remote-icon branch of `utils/icon.html` (a `resources.GetRemote` to unpkg and jsdelivr);
    - `icons.yaml`, cut to the five icons of the toggle;
    - `theme.toml`, left out.

    Copied as is, `theme.toml` (`blob/main/` in its licence link) and an `icons.yaml` comment ("heroicons v1") break the Deploy test that forbids branch literals under `site/`.
  - **Look.** Own CSS gives the dense developer-tool look of #136 (14 px base, monospace ids and chips, labelled segmented Stage and Level controls) from one file of tokens an organization can change. Hextra reads as a documentation or marketing site.
- **Rejected:**
  - **Vendored Hextra 0.13.0:** see Rationale. It was built and screenshotted on the scratch branch `wp16/spike-hextra`.
  - **Hugo Book:** not built. It was the fallback only if Hextra failed a hard constraint, and none failed.
  - **Relearn:** kept out for its look in the WP16 planning interview.
  - **Docsy:** Hugo modules and npm, excluded by D31 and by #136.
- **Consequences:**
  - **Design tokens.** The shell PR ([#138](https://github.com/ALCops/rulebook-engine/issues/138)) builds on the scratch branch `wp16/spike-own-css`. The tokens sit in `site/assets/css/site.css` under `:root`, under `[data-theme="dark"]`, and again in a `@media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) }` block. The two dark blocks are equal, so the system setting applies without JavaScript.
  - **Theme toggle and mobile menu.** An inline script first in `<head>` applies `localStorage['rulebook-theme']` before the first paint. A new `site/assets/js/shell.js` (published as `js/shell.js`) binds the toggle and the menu below 768 px.
  - **Logo.** The ALCops logo is an inline partial, `partials/logo.html`, with `fill="currentColor"`.
  - **Chip markup.** Each matrix cell wraps its action in `<span class="chip">` and keeps every `data-*` attribute. The cell pattern of the site tests changes with it.
  - **Asset paths.** No file under `site/themes/`; the assets keep their fixed paths under `css/` and `js/`.
  - **Scratch branches.** `wp16/spike-hextra` is deleted once this record merges; `wp16/spike-own-css` is deleted once the shell PR has taken what it needs.
  - **Numbering.** #136 reserved D58 for this decision. It is D59 because the documentation strategy (D58) merged first.
- **Affects:** [#137](https://github.com/ALCops/rulebook-engine/issues/137), WP16 ([#136](https://github.com/ALCops/rulebook-engine/issues/136) and its children [#138](https://github.com/ALCops/rulebook-engine/issues/138), [#139](https://github.com/ALCops/rulebook-engine/issues/139), [#140](https://github.com/ALCops/rulebook-engine/issues/140), [#141](https://github.com/ALCops/rulebook-engine/issues/141), [#143](https://github.com/ALCops/rulebook-engine/issues/143)), D31, D35, D54.
