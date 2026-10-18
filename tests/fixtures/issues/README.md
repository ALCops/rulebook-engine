# Issue body fixtures

Bodies of `rulebook-change` issues for `ConvertFrom-RulebookIssueBody` and `Read-RulebookChangeSetText` (`modules/Rulebook.Edit.psm1`, [docs/reference/change-mechanics.md](../../../docs/reference/change-mechanics.md) section 12). GitHub renders an issue form as one `### <label>` section per field: the `render: json` textarea `Changes` as a fenced `json` block, the optional `Note` as plain text, an empty field as `_No response_`, with LF line ends and no final line end (observed in the WP15 live run of 2026-10-18, [change-mechanics.md](../../../docs/reference/change-mechanics.md) section 16). `rulebook-change-opened.md` is a real body from that run; the other bodies are written by hand in that shape, with the ids and slugs of `tests/fixtures/repos/valid-minimal`.

| File | Shape | Proves |
|---|---|---|
| `rulebook-change-opened.md` | **Captured** on the live run of 2026-10-18: the body GitHub wrote for issue #1 of `Arthurvdv/rulebook-e2e-apply`, created from the form by the dashboard cart, byte for byte (no provenance line in the file, as the tests read it as the body; no final line end, as GitHub wrote it). A minified change set with two `set` and one `release` (`LC0031`, `AA0072`, `AW0008`, ids of that repository, not of `valid-minimal`) in a `json` fence under `### Changes`, `_No response_` under `### Note`. Not applied to a repository fixture. | The body of a real submission parses into a schema-valid change set, its empty Note into `''`. |
| `note-no-response.md` | A one-item set; the empty Note field arrives as `_No response_`. | An empty note is `''`, so the JSON `note` stands. |
| `prose-and-two-fences.md` | Prose above the first heading, a trailing blank after `### Changes`, prose before a `~~~ json` fence, a second fence in Changes, a note with two fences and a `####` heading. | Only the first fenced block of Changes counts; deeper headings do not split; the Note section comes back next to the JSON `note` (the issue path lets a non-empty Note win). |
| `no-fence.md` | The change set JSON straight under `### Changes`, no fence, no Note section. | The section text is the change set; an absent Note is `''`. |
| `no-changes-section.md` | A hand-written issue with `## Changes` (H2), no form sections. | The missing-section error. |

CRLF bodies, an empty body and a `$null` body are built in the tests from these files.
