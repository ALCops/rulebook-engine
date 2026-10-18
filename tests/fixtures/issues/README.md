# Issue body fixtures

Bodies of `rulebook-change` issues for `ConvertFrom-RulebookIssueBody` and `Read-RulebookChangeSetText` (`modules/Rulebook.Edit.psm1`, [docs/reference/change-mechanics.md](../../../docs/reference/change-mechanics.md) section 12). GitHub documents that it renders an issue form as one `### <label>` section per field: the `render: json` textarea `Changes` as a fenced `json` block, the optional `Note` as plain text, an empty field as `_No response_`. That rendering is not yet observed here: the bodies below are written by hand in that shape until the WP15 live run captures a real one. The ids and slugs of the hand-made bodies are those of `tests/fixtures/repos/valid-minimal`.

| File | Shape | Proves |
|---|---|---|
| `rulebook-change-opened.md` | **Placeholder** (its first line, an HTML comment, says so): the body the dashboard cart submits, a minified change set with one `set` and one `release` in a `json` fence under `### Changes`, the same note under `### Note`. Replace it with the real body captured on the WP15 live run (`gh api repos/<owner>/<repo>/issues/<n> --jq .body`); the tests assert only its shape (a schema-valid change set and a non-empty note), so the capture needs no other change. | The body of a real submission parses into a schema-valid change set and its note. |
| `note-no-response.md` | A one-item set; the empty Note field arrives as `_No response_`. | An empty note is `''`, so the JSON `note` stands. |
| `prose-and-two-fences.md` | Prose above the first heading, a trailing blank after `### Changes`, prose before a `~~~ json` fence, a second fence in Changes, a note with two fences and a `####` heading. | Only the first fenced block of Changes counts; deeper headings do not split; the Note section comes back next to the JSON `note` (the issue path lets a non-empty Note win). |
| `no-fence.md` | The change set JSON straight under `### Changes`, no fence, no Note section. | The section text is the change set; an absent Note is `''`. |
| `no-changes-section.md` | A hand-written issue with `## Changes` (H2), no form sections. | The missing-section error. |

CRLF bodies, an empty body and a `$null` body are built in the tests from these files.
