# WP01 spikes

Results of the time-boxed experiments of WP01 ([#3](https://github.com/ALCops/rulebook-engine/issues/3)). Each spike answers one technical question whose outcome changes the design of a later work package. A result file records the question, the method, the versions used, what was observed, the answer and its consequences; the scripts and workflows behind it were throwaway and only excerpts are kept.

| Spike | Question | File | Status |
|---|---|---|---|
| (a) [#19](https://github.com/ALCops/rulebook-engine/issues/19) | Do `*.github.io` and `raw.githubusercontent.com` pass the compiler's anti-SSRF policy, and does a one-include skeleton make one fetch and win with its own rules? | [a-hosts-and-skeleton-include.md](a-hosts-and-skeleton-include.md) | done |
| (b) [#20](https://github.com/ALCops/rulebook-engine/issues/20) | Where are the analyzer DLLs in the two NuGet packages, and which id-extraction method works on Linux? | [b-analyzer-dll-extraction.md](b-analyzer-dll-extraction.md) | done |
| (c) [#21](https://github.com/ALCops/rulebook-engine/issues/21) | Does `alc` from the NuGet tool run on `ubuntu-latest`? | [c-alc-on-ubuntu.md](c-alc-on-ubuntu.md) | done |
| (d) [#22](https://github.com/ALCops/rulebook-engine/issues/22) | How does GitHub Pages behave for a private organization repository on the Free plan? | [d-pages-private-repo.md](d-pages-private-repo.md) | done |
| (e) [#23](https://github.com/ALCops/rulebook-engine/issues/23) | When does VS Code re-fetch a remote ruleset? | [e-vscode-refetch.md](e-vscode-refetch.md) | done |
| (f) [#24](https://github.com/ALCops/rulebook-engine/issues/24) | Does `suppressWarnings` remove AS0084 and AS0013 against a sparse endpoint, and stop once the endpoint lists the id? | [f-suppresswarnings-sparse-endpoint.md](f-suppresswarnings-sparse-endpoint.md) | done |
| (g) [#25](https://github.com/ALCops/rulebook-engine/issues/25) | How long may a prefilled `issues/new` URL be, and does a `render: json` textarea survive intact? | [g-prefilled-issue-url-limit.md](g-prefilled-issue-url-limit.md) | done |
| (h) [#26](https://github.com/ALCops/rulebook-engine/issues/26) | Does a Hugo content adapter build 628 pages from one JSON file in a few seconds, and which Hugo version to pin? | [h-hugo-content-adapter.md](h-hugo-content-adapter.md) | done |
