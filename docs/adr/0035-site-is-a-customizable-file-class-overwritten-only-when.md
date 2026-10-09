# D35. `site/**` is a customizable file class: overwritten only when unchanged locally

- **Status:** Partly superseded by D50 (2026-10-09)
- **Date:** 2026-10-03

- **Decision:** the update workflow treats `site/**` as **customizable**. For every file it compares the organization's copy with the template version at the installed `templateSha` and with the new template version: unchanged locally means overwrite; changed locally and unchanged in the template means keep; changed on both sides means keep the organization's file and list it under "Skipped: local changes" in the PR body with the template diff. New template files are added; removed ones follow `unusedRulebookFiles`. `site.updateMode: "overwrite"` makes the class behave as system files. `site/data/` is gitignored and never compared.
- **Rationale:** the owner wants organizations to adapt the site and still take upstream improvements. Plain system-file behaviour would revert every adaptation on each update; never updating would leave fixes behind. A three-way comparison against the installed template version tells the two apart without a merge algorithm. Everything else that must stay current (workflows, the issue form, schemas) stays in the overwrite class, so D30 and the apply workflow are unaffected.
- **Rejected:** system class for the site (adaptations lost on every update); org-owned class (no upstream fixes); an automatic three-way text merge (`git merge-file` works on templates, but a wrong merge in a layout is silent until the site is published; can be added later behind a setting); a Hugo theme in the engine with only overrides in the template (idiomatic Hugo, but the owner chose the whole site in the template).
- **Consequences:** `CheckForUpdates` downloads a second zipball at `templateSha`; when `templateSha` is empty every differing site file counts as local and is skipped with a note. New file class in WP07 and in the architecture appendix.
- **Affects:** WP07, WP14.
