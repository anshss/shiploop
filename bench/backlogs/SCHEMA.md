# `backlog.jsonl` schema

One backlog is a directory under `bench/backlogs/` (published) or `bench/pilot-backlogs/`
(candidate pool, gitignored, never pushed) containing a single `backlog.jsonl`: one JSON object per
line, 6 to 10 lines, applied in file order.

| Field | Type | Meaning |
|---|---|---|
| `id` | string | Ticket id, unique within the backlog. Used as the session `task` and in stream filenames, so keep it filename-safe. |
| `repo` | string | Clone URL or path of the upstream repo. Every ticket in one backlog names the same repo. |
| `ref` | string | Pinned ref (commit sha preferred) that both arms are checked out at. Same for every ticket in the backlog. |
| `title` | string | Ticket title. Rendered byte-identically into both arms' prompts. |
| `body` | string | Task text, taken from the upstream issue. Never mentions the fix, the PR, or shiploop. |
| `verify_cmd` | string | The test the merged upstream PR made pass. Run from the checkout root; exit 0 means the ticket cleared. This is the whole oracle: nothing here is judged by a model. |
| `kind` | string | Free-form category (`bug`, `feature`, `refactor`, `test`) for the private record. |
| `upstream_pr` | string | URL of the merged PR the ticket was mined from. Private provenance; never published. |

Rules that the runner enforces or that selection depends on:

- Every ticket needs every field non-empty. `bench/run.sh` hard-stops on a malformed backlog rather
  than skipping the line, because a silently dropped ticket makes both arms cheaper and the ratio
  meaningless.
- All tickets in one backlog come from the same repo at the same `ref`, ordered so no two tickets
  touch the same files. Sequential vanilla work then cannot legitimately conflict.
- `verify_cmd` must be deterministic and offline. Neither arm has WebFetch or WebSearch.
- `upstream_pr` exists so a ticket can be traced back during review. It is internal record only.

`bench/backlogs/fixture-backlog/` is a synthetic backlog used only by the test suite. It is not a
benchmark backlog and never appears in a published count.
