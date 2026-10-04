# Spike (a): hosts and the skeleton include

> **Status:** done 2026-10-04. Issue [#19](https://github.com/ALCops/rulebook-engine/issues/19), part of WP01 ([#3](https://github.com/ALCops/rulebook-engine/issues/3)). Blocks: WP02 ([#4](https://github.com/ALCops/rulebook-engine/issues/4)).

## Question

Does the compiler's anti-SSRF policy allow `*.github.io` and `raw.githubusercontent.com`, and does a local skeleton that includes one endpoint URL behave as documented (one fetch, own rules beat the include)? Added by spike (c): when the URL that fails is an *include* in a local skeleton rather than the root path, does `alc` abort or continue with its defaults?

## Method

A throwaway public repository, `Arthurvdv/rulebook-spike-endpoint` (personal Free account, created 2026-10-04), holds two files under `v1/rulesets/`:

```jsonc
// recommended.ci.ruleset.json
{
  "name": "Spike",
  "rules": [ { "id": "AA0137", "action": "Error" } ]
}
// broken.ruleset.json (invalid: Default is not a valid rule action)
{
  "name": "Spike broken",
  "rules": [ { "id": "AA0137", "action": "Default" } ]
}
```

GitHub Pages was enabled from `main` `/` with `gh api -X POST repos/Arthurvdv/rulebook-spike-endpoint/pages -f build_type=legacy -f 'source[branch]=main' -f 'source[path]=/'`, which returned `201 Created` (`"build_type":"legacy"`, `"public":true`, `"https_enforced":true`); the first build took 19 s and both hosts served 200 a minute after the push. The two endpoint URLs:

- Pages: `https://arthurvdv.github.io/rulebook-spike-endpoint/v1/rulesets/recommended.ci.ruleset.json`
- raw: `https://raw.githubusercontent.com/Arthurvdv/rulebook-spike-endpoint/main/v1/rulesets/recommended.ci.ruleset.json`

A throwaway workflow (`spike-a.yml`, `workflow_dispatch` plus push on `wp01/spike-a`, read-only token, removed before the pull request; last version at `eb6d640:.github/workflows/spike-a.yml`) ran on `ubuntu-latest` with the [spike (c) recipe](c-alc-on-ubuntu.md#recipe) unchanged: stable tool 18.0.43.1464, `AL_BIN` from `tools/net10.0/any` with the guard, `System.app` from MSSymbols with the prerelease-safe `jq` filter, the one-codeunit fixture (`runtime 17.0`, `platform 28.0.0.0`, unused local variable for AA0137, CodeCop Warning by default), CodeCop, UICop and PerTenantExtensionCop, compile output in `compile.log` with the AL1003 check.

Per host it ran, in order: the controls of the common protocol (URL without `/enableexternalrulesets`, a 404 URL with the flag; the no-ruleset control once), the endpoint URL as `/ruleset:` with the flag, then the skeleton `$GITHUB_WORKSPACE/fixture/.rulebook/ci.ruleset.json` written exactly as [ARCHITECTURE.md §6.3](../../ARCHITECTURE.md#63-skeletons-r3):

```json
{
  "name": "Rulebook Spike / CI",
  "description": "Includes the org endpoint. Add project exceptions to rules; they override the endpoint.",
  "includedRuleSets": [
    { "action": "Default", "path": "<endpoint URL>" }
  ],
  "rules": [ { "id": "AA0137", "action": "None" } ]
}
```

The skeleton ran with its include pointing at the endpoint (once with `"rules": []` as a control that the include is applied, once with the own `None` rule, once with the own rule but without the flag), at `broken.ruleset.json`, at a 404 path on the same host, and (once, host-independent) at `https://nonexistent.invalid/x.json`.

Every compile ran under `strace -f -e trace=connect` and a concurrent `sudo tcpdump -i any -nn -U` capture of outgoing SYNs to port 443 (filter from the protocol), with `set +e` semantics: the exit code of `al` is recorded as is, the `.app` path is deleted before each compile and checked after it.

Request counting, as implemented in the run:

```bash
sudo tcpdump -i any -nn -U -w cap.pcap 'tcp[tcpflags] & tcp-syn != 0 and tcp[tcpflags] & tcp-ack == 0 and dst port 443' &
sleep 2
strace -f -qq -e trace=connect -o strace.log al compile ... > compile.log 2>&1; rc=$?
sleep 2; sudo pkill -INT -x tcpdump; wait
grep -c 'htons(443)' strace.log                    # TCP connects to :443 by alc
grep -c 'htons(53)'  strace.log                    # DNS: connects to the resolver stub 127.0.0.53:53
# -i any records each SYN twice, on eth0 and on a second interface, with the same source port and sequence number; count distinct SYNs:
sudo tcpdump -nn -r cap.pcap 'dst net 185.199.108.0/22' | awk '{print $5, $7, $11}' | sort -u | wc -l
```

`185.199.108.0/22` covers every address `getent ahosts` returned for both hosts; SYNs to other addresses (140.82.112.0/20, 20.x) belong to the runner agent and never appear in `strace.log`.

## Environment and versions

| Item | Value |
|---|---|
| Date | 2026-10-04 |
| Runner image / OS | `ubuntu-latest` = ubuntu-24.04, image version 20260927.320.1 (Ubuntu 24.04.5 LTS) |
| Development.Tools (alc) | 18.0.43.1464 (`18.0.43.1464+ad5c66161d2e2ef7ba77e4a6c7681eb522cf752c`), `tools/net10.0/any` |
| Platform symbols | `microsoft.platform.symbols` 28.0.54265 |
| strace / tcpdump | strace 6.8 and tcpdump 4.99.4, both preinstalled on the image (no `apt-get` needed) |
| Name resolution on the runner | `arthurvdv.github.io`: 185.199.108-111.153 and 2606:50c0:8000-8003::153; `raw.githubusercontent.com`: 185.199.108-111.133 and 2606:50c0:8000-8003::154; `nonexistent.invalid`: no address. IPv6 is unreachable on the runner. |
| Scratch repository | `Arthurvdv/rulebook-spike-endpoint`, public, Pages `build_type: legacy` from `main` `/` |

## Observed

Final run: [actions/runs/37179557047](https://github.com/ALCops/rulebook-engine/actions/runs/37179557047) (commit `daa517b`, rebased onto main as `eb6d640` with an identical workflow file). The first run, [37179402446](https://github.com/ALCops/rulebook-engine/actions/runs/37179402446) (commit `3e809dd`, rebased as `af1527c`), gave the same exit codes, diagnostics and connect counts; it only counted every SYN twice (see the note on `-i any` above).

| host | scenario | exit code | AL1033 | AL0767 | AA0137 severity | .app written | connects :443 (strace) | SYNs (tcpdump, distinct) | DNS :53 (strace) | wall time |
|---|---|---|---|---|---|---|---|---|---|---|
| none | control: no ruleset | 0 | no | no | Warning | yes | 0 | 0 | 0 | 2.2 s |
| Pages | control: URL, no flag | 1 | no | yes | (no compile) | no | 0 | 0 | 0 | 0.3 s |
| Pages | control: 404 URL, flag | 1 | yes | no | (no compile) | no | 1 | 1 | 1 | 0.7 s |
| Pages | direct URL, flag | 1 | no | no | **Error** | no (AA0137 is an error) | 1 | 1 | 1 | 2.3 s |
| Pages | skeleton, include only (`rules: []`) | 1 | no | no | Error | no (AA0137 is an error) | 1 | 1 | 1 | 2.3 s |
| Pages | skeleton, own AA0137 `None` | **0** | no | no | **absent** | **yes** | **1** | **1** | 1 | 2.5 s |
| Pages | skeleton, own AA0137 `None`, no flag | 1 | yes | no | (no compile) | no | 0 | 0 | 0 | 0.4 s |
| Pages | skeleton, include `broken` | 1 | yes | no | (no compile) | no | 1 | 1 | 1 | 0.8 s |
| Pages | skeleton, include 404 | 1 | yes | no | (no compile) | no | 1 | 1 | 1 | 0.8 s |
| raw | control: URL, no flag | 1 | no | yes | (no compile) | no | 0 | 0 | 0 | 0.3 s |
| raw | control: 404 URL, flag | 1 | yes | no | (no compile) | no | 1 | 1 | 1 | 0.7 s |
| raw | direct URL, flag | 1 | no | no | **Error** | no (AA0137 is an error) | 1 | 1 | 1 | 2.3 s |
| raw | skeleton, include only (`rules: []`) | 1 | no | no | Error | no (AA0137 is an error) | 1 | 1 | 1 | 2.3 s |
| raw | skeleton, own AA0137 `None` | **0** | no | no | **absent** | **yes** | **1** | **1** | 1 | 2.4 s |
| raw | skeleton, own AA0137 `None`, no flag | 1 | yes | no | (no compile) | no | 0 | 0 | 0 | 0.5 s |
| raw | skeleton, include `broken` | 1 | yes | no | (no compile) | no | 1 | 1 | 1 | 1.0 s |
| raw | skeleton, include 404 | 1 | yes | no | (no compile) | no | 1 | 1 | 1 | 0.8 s |
| non-existent host | skeleton, include `https://nonexistent.invalid/x.json` | 1 | yes | no | (no compile) | no | 0 | 0 | 2 | 0.6 s |
| non-existent host | same, `rules: []` | 1 | yes | no | (no compile) | no | 0 | 0 | 2 | 0.5 s |

"(no compile)" means alc printed only the one diagnostic and never reached `Compilation started`. Wall times include the strace overhead.

Findings:

- **Both hosts pass the anti-SSRF policy.** The endpoint URL as root path and as the include of a local skeleton loads on Pages and on raw without AL1033, and AA0137 comes out at the endpoint's `Error`.
- **One fetch per compile.** Every compile that loads one URL, direct or through the skeleton, makes exactly one TCP connect to port 443 (strace) and one SYN to the GitHub CDN (tcpdump), plus one DNS query to the local resolver stub. The connect goes to an IPv4-mapped address on a dual-mode socket (`::ffff:185.199.x.y`), non-blocking (`EINPROGRESS`). The extra `connect` calls with port 0 in `strace.log` (four IPv4, four IPv6 with `ENETUNREACH`) send no packet: none of them has a matching SYN in tcpdump, which is consistent with glibc's address-sorting probes on a UDP socket during `getaddrinfo`. No redirect was observed on either host, so there was never a second connect.
- **The skeleton's own rule beats the include.** With the include alone the result is the endpoint's `Error`; with `{ "id": "AA0137", "action": "None" }` in the skeleton's own `rules` AA0137 is absent, the compile exits 0 and writes the `.app`. Same on both hosts.
- **A failing include aborts the compile, like a failing root.** A 404 include, an invalid include (`"action": "Default"` on a rule) and an include on a host that does not resolve all produce one `error AL1033` naming the skeleton file, no `Compilation started`, no `.app`, exit 1. alc does not fall back to its defaults. The non-resolving host fails in about 0.6 s (two DNS queries, no TCP connect), well inside the 15 s fetch timeout.
- **An include URL without `/enableexternalrulesets` is AL1033, not AL0767.** AL0767 appears only when the *root* path is a URL; a local skeleton whose include is a URL fails with AL1033 ("... because external rulesets are not allowed") before any network access. Same abort: exit 1, no `.app`.
- **The fetch happens during command-line parsing.** The SYN is sent about 0.3 s before alc prints `Compilation started`, which is consistent with the abort: a ruleset error is a command-line error and the compilation is never started.

<details>
<summary>Headers (curl -sI from the runner, final run)</summary>

```
=== https://arthurvdv.github.io/rulebook-spike-endpoint/v1/rulesets/recommended.ci.ruleset.json
HTTP/2 200
server: GitHub.com
content-type: application/json; charset=utf-8
etag: "6ac1e0a0-4c"
cache-control: max-age=600
via: 1.1 varnish
x-cache: HIT
=== https://raw.githubusercontent.com/Arthurvdv/rulebook-spike-endpoint/main/v1/rulesets/recommended.ci.ruleset.json
HTTP/2 200
cache-control: max-age=300
content-type: text/plain; charset=utf-8
etag: "4f820c9200751dea3459939ef4a882bbf05b9b9a14b4c7f064cde14b5fe02c0e"
via: 1.1 varnish
x-cache: HIT
=== https://arthurvdv.github.io/rulebook-spike-endpoint/v1/rulesets/does-not-exist.ruleset.json
HTTP/2 404
content-type: text/html; charset=utf-8
=== https://raw.githubusercontent.com/Arthurvdv/rulebook-spike-endpoint/main/v1/rulesets/does-not-exist.ruleset.json
HTTP/2 404
content-type: text/plain; charset=utf-8
=== curl -sL, redirects followed
200 redirects=0 http=2 ip=185.199.108.153 https://arthurvdv.github.io/rulebook-spike-endpoint/v1/rulesets/recommended.ci.ruleset.json
200 redirects=0 http=2 ip=185.199.110.133 https://raw.githubusercontent.com/Arthurvdv/rulebook-spike-endpoint/main/v1/rulesets/recommended.ci.ruleset.json
```

No `location` header on either host: no redirect observed. Pages serves the file as `application/json` with `max-age=600`, raw as `text/plain` with `max-age=300`; the compiler accepts both content types.

</details>

<details>
<summary>raw, skeleton with own AA0137 None (exit 0)</summary>

```
Compilation started for project 'Spike' containing '1' files at '05:20:52.537'.
fixture/src/Spike.Codeunit.al(1,16): info AA0247: Use namespaces to organize your code and isolate it from changes.
Compilation ended at '05:20:54.166'.

--- strace connects to ports 443 and 53
3303  connect(109, {sa_family=AF_INET, sin_port=htons(53), sin_addr=inet_addr("127.0.0.53")}, 16) = 0
3303  connect(114, {sa_family=AF_INET6, sin6_port=htons(443), sin6_flowinfo=htonl(0), inet_pton(AF_INET6, "::ffff:185.199.109.133", &sin6_addr), sin6_scope_id=0}, 28) = -1 EINPROGRESS (Operation now in progress)
--- other strace connects with an inet address
3303  connect(109, {sa_family=AF_INET, sin_port=htons(0), sin_addr=inet_addr("185.199.109.133")}, 16) = 0
3303  connect(109, {sa_family=AF_INET, sin_port=htons(0), sin_addr=inet_addr("185.199.111.133")}, 16) = 0
3303  connect(109, {sa_family=AF_INET, sin_port=htons(0), sin_addr=inet_addr("185.199.108.133")}, 16) = 0
3303  connect(109, {sa_family=AF_INET, sin_port=htons(0), sin_addr=inet_addr("185.199.110.133")}, 16) = 0
3303  connect(109, {sa_family=AF_INET6, sin6_port=htons(0), ... "2606:50c0:8000::154" ...}, 28) = -1 ENETUNREACH (Network is unreachable)
(three more IPv6 probes, ENETUNREACH)
--- tcpdump SYNs to :443
05:20:52.212425 eth0  Out IP 10.1.0.130.33500 > 185.199.109.133.443: Flags [S], seq 1725168263, ...
05:20:52.212429 enP60402s1 Out IP 10.1.0.130.33500 > 185.199.109.133.443: Flags [S], seq 1725168263, ...
```

The two tcpdump lines carry the same source port and sequence number on two interfaces, consistent with one SYN recorded twice (strace shows one connect).

</details>

<details>
<summary>Include failures (final run)</summary>

```
## skeleton, include broken (Pages)
error AL1033: An error occurred while loading the included rule set file /home/runner/work/rulebook-engine/rulebook-engine/fixture/.rulebook/ci.ruleset.json - The content of the rule set file 'https://arthurvdv.github.io/rulebook-spike-endpoint/v1/rulesets/broken.ruleset.json' cannot be recognized.'.

## skeleton, include 404 (raw)
error AL1033: An error occurred while loading the included rule set file /home/runner/work/rulebook-engine/rulebook-engine/fixture/.rulebook/ci.ruleset.json - Could not load the rule set file from 'https://raw.githubusercontent.com/Arthurvdv/rulebook-spike-endpoint/main/v1/rulesets/does-not-exist.ruleset.json'.

## skeleton, include non-existent host
error AL1033: An error occurred while loading the included rule set file /home/runner/work/rulebook-engine/rulebook-engine/fixture/.rulebook/ci.ruleset.json - Could not load the rule set file from 'https://nonexistent.invalid/x.json'.
--- strace connects to ports 443 and 53
3589  connect(109, {sa_family=AF_INET, sin_port=htons(53), sin_addr=inet_addr("127.0.0.53")}, 16) = 0
3589  connect(109, {sa_family=AF_INET, sin_port=htons(53), sin_addr=inet_addr("127.0.0.53")}, 16) = 0

## skeleton, own AA0137 None, no flag (raw)
error AL1033: An error occurred while loading the included rule set file /home/runner/work/rulebook-engine/rulebook-engine/fixture/.rulebook/ci.ruleset.json - It was not possible to load the ruleset with location 'https://raw.githubusercontent.com/Arthurvdv/rulebook-spike-endpoint/main/v1/rulesets/recommended.ci.ruleset.json' because external rulesets are not allowed.

## controls (Pages)
error AL0767: The URL 'https://arthurvdv.github.io/rulebook-spike-endpoint/v1/rulesets/recommended.ci.ruleset.json' cannot be used as the ruleset path for this project because its configuration does not permit external rulesets.
error AL1033: An error occurred while loading the included rule set file 'https://arthurvdv.github.io/rulebook-spike-endpoint/v1/rulesets/does-not-exist.ruleset.json' - Could not load the rule set file from 'https://arthurvdv.github.io/rulebook-spike-endpoint/v1/rulesets/does-not-exist.ruleset.json'.
```

Each of these is the complete compiler output after the banner: no `Compilation started`, no other diagnostic.

</details>

## Answer

Both `arthurvdv.github.io` (GitHub Pages) and `raw.githubusercontent.com` serve an endpoint the compiler accepts: with `/enableexternalrulesets` the anti-SSRF policy lets both through, AL1033 is absent and the endpoint's rule applies (AA0137 at Error). A compile against the endpoint, directly or through the one-include skeleton of ARCHITECTURE.md §6.3, makes exactly one request: one TCP connect to port 443 and one SYN per compile on both hosts, with no redirect. The skeleton's own rule beats the include: AA0137 at `None` in the skeleton's `rules` removes the endpoint's `Error`, the compile exits 0 and writes the `.app`. On the `alc` command line a failing include does **not** fall back to defaults: a 404, an invalid file, a host that does not resolve, or a URL include without `/enableexternalrulesets` each give one AL1033 and abort the compile with exit 1 and no `.app`, exactly like a failing root URL (spike (c)).

## Consequences for blocked work packages

| WP | Consequence | Action taken |
|---|---|---|
| WP02 ([#4](https://github.com/ALCops/rulebook-engine/issues/4)) | Single-include skeleton confirmed on both hosts: one fetch, own rules win. D7 (Pages default) and the dist-repo target (raw) both work for the compiler. Failure semantics differ from the docs: on `alc` an unreachable or broken endpoint stops the build (AL1033, exit 1) instead of building with defaults, so a CI build fails loudly by itself (on raw `alc`; AL-Go and BcContainerHelper not observed); the skeleton's `includedRuleSets` URL also needs the consumer's external-rulesets switch (AL1033 otherwise, not AL0767). | Comment posted on [#4](https://github.com/ALCops/rulebook-engine/issues/4#issuecomment-5976943740) |
| WP06 ([#8](https://github.com/ALCops/rulebook-engine/issues/8)) | None: the skeleton model and the `rules` route for exceptions behave as designed. | None |
| Docs | [compiler-ruleset-internals.md](../compiler-ruleset-internals.md) §6, §7, §11 and §13, [ARCHITECTURE.md](../../ARCHITECTURE.md) §2, §5, §9 and §10 and [rulebook/composition.md](../../rulebook/composition.md) said that alc continues with compiler defaults after AL1033 or AL0767. | Corrected in this pull request to the observed behaviour, citing this file and spike (c); the VS Code fallback (from the code, not observed) is kept as such. |
| Spikes (f), (e) | The endpoint repository, the `v1/` URLs and the request-counting steps above are reusable; spike (f) publishes under `v2/`, spike (e) edits `e/ruleset.json` in place. | None (facts passed to the next executors) |

## Not covered

- The VS Code language server path: whether the editor also refuses the ruleset or falls back to defaults on AL1033 (the code reading in compiler-ruleset-internals.md §7 says fallback). Answered by [spike (e)](e-vscode-refetch.md): the editor falls back to defaults and shows AL1033 on `app.json`.
- AL-Go for GitHub and BcContainerHelper run the same compiler but were not run here; the abort is expected there too, not observed.
- A host that accepts the connection but never answers (the 15 s timeout path). A non-resolving host fails in 0.6 s; a black-holed public address was not tried.
- Private, loopback and link-local targets (anti-SSRF denials): not needed for the hosts in scope.
- A custom domain on Pages (CNAME): not tried; the policy sees a different host name but the same CDN addresses.
- Windows `alc`: the stable tool is not installed locally; ubuntu only, as planned.

## Artifacts

- Final run: <https://github.com/ALCops/rulebook-engine/actions/runs/37179557047> (job summary holds the result table and the headers); first run: <https://github.com/ALCops/rulebook-engine/actions/runs/37179402446>.
- The throwaway workflow `.github/workflows/spike-a.yml` lived on `wp01/spike-a` and was removed before the pull request; the version the final run executed is `eb6d640:.github/workflows/spike-a.yml` (`git show eb6d640:.github/workflows/spike-a.yml`; the run itself ran the pre-rebase commit `daa517b` with the identical file).
- Scratch repository `Arthurvdv/rulebook-spike-endpoint` (public), created 2026-10-04, kept for spikes (f) and (e) and deleted after WP01 (#3). Content at the end of this spike: `README.md`, `.nojekyll`, `v1/rulesets/recommended.ci.ruleset.json`, `v1/rulesets/broken.ruleset.json` (commit `532f841`). The path `v1/rulesets/does-not-exist.ruleset.json` is the 404 control and must stay absent.
- Nothing besides this file and the documentation corrections is kept in the repository.
