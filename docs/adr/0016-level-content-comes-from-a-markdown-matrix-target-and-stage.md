# D16. Level content comes from a Markdown matrix; target and stage layers are generated ancestors

- **Status:** Accepted
- **Date:** 2026-09-29

- **Decision:** `docs/rulebook/` holds the source of truth for what every diagnostic does at every level, target and stage: a full inventory (`inventory/`), a matrix (`matrix/`), the placement algorithm and a composition spec. A generator in the engine produces `template/rulesets/` from it. The target and stage layers are ancestors in the include chain (`L<n>` <- `L<n>.<target>` <- `L<n>.<target>.<stage>.managed` <- endpoint root) instead of the sibling overlays `pte`, `appsource`, `dev`, `cicd`, `nextmajor` of ARCHITECTURE section 5.
- **Rationale:** the interview requires the `pte` target to show AppSourceCop rules at Info where `appsource` shows Error, and the `cicd` stage to lower AL0432 to Info. Siblings can only raise (strictest wins, `None` never wins), so a layer that must lower has to be an ancestor. Because the files are generated, restating a target's full delta per level costs nothing and keeps every include a plain `./name`.
- **Rejected:** keeping disjoint sibling overlays (PTE and AppSource could only differ by subtraction, so either PTE gets Errors or AppSource loses its submission floor at low levels); raise-only overlays (works for targets, cannot express stage downgrades); a matrix format read by the compiler (does not exist).
- **Consequences:** validation rule V5 (overlay disjointness) is replaced by "generated layers are system files regenerated from the matrix and never hand-edited". Fetch depth for `L4` is nine files. D13 still holds for an organization's repository: what is in `rulesets/` is what the compiler loads; the generation step runs in the engine when the template is built. Quarantine files keep their sibling role.
- **Affects:** WP02, WP03, WP04, WP09, WP10. See `docs/rulebook/composition.md` and `docs/rulebook/01-levels.md`.
