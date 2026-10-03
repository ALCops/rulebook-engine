# D39. Test framework is Pester 6

- **Status:** Accepted
- **Date:** 2026-10-03

- **Decision:** the engine's tests use Pester 6 (PowerShell 7.4 or later, `Should-*` assertions) from the first test on.
- **Rationale:** no test exists yet, so there is nothing to migrate. Pester 6 is the current major version, runs on the same PowerShell 7 runtime that D9 already requires, and its `Should-*` assertions are the form new documentation and examples use.
- **Rejected:** pinning Pester 5.x (the first suites would be written in a syntax that is already the previous major version, and moved later).
- **Consequences:** D9 and D12 are partly superseded where they say "Pester 5"; the rest of both records stands. CI installs a pinned Pester 6 and imports it with `-MinimumVersion 6.0`, because the runner image may ship Pester 5. Contributors need PowerShell 7.4 or later. Tests use `Should-BeTrue`, `Should-Be` and the other `Should-*` commands, not `Should -Be`.
- **Affects:** WP00, WP12, every work package that adds a module or action.
