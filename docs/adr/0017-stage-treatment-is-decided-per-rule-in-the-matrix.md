# D17. Stage treatment is decided per rule in the matrix

- **Status:** Partly superseded by D26 and D27 (2026-10-01)
- **Date:** 2026-09-29

- **Partly superseded** by D26 and D27 (2026-10-01): the stage columns remain the engine source; in an organization repository a stage is one delta file and the default stage has no file; the stage set is configuration.
- **Decision:** every diagnostic carries a `Dev`, `CICD` and `vNext` column. `dev` always equals the level and target action; `cicd` may lower a rule to Info; `nextmajor` raises compiler future errors to Error and obsolete-pending to Warning.
- **Rationale:** the interview asked that each rule decides how it applies in development, pipelines and vNext, while developers see the same diagnostics the pipeline will enforce. A per-rule column with `=` as the default keeps the dev and pipeline views identical except for the few documented relaxations.
- **Rejected:** no stage dimension (loses the AL0432 case and the vNext preview of future errors); a full per-rule-per-level stage matrix (36 cells per rule to decide by hand; the factorized columns cover the same space).
- **Consequences:** the stage layer of D16 exists for every level and target; the `dev` managed file is always empty. Closes O2 for v1: levels are not stage-aware, the managed stage layer is.
- **Affects:** WP02, WP08, WP10.
