# `backlog.jsonl` schema

One backlog is a directory under `bench/backlogs/` (published) or `bench/pilot-backlogs/`
(candidate pool, gitignored, never pushed) containing a single `backlog.jsonl`: one JSON object per
line, 2 lines, applied in file order.

| Field | Type | Meaning |
|---|---|---|
| `id` | string | Ticket id, unique within the backlog. Used as the session `task` and in stream filenames, so keep it filename-safe. |
| `repo` | string | Clone URL or path of the repo. Every ticket in one backlog names the same repo. |
| `ref` | string | Pinned ref (commit sha preferred) that both arms are checked out at. Same for every ticket in the backlog. The backlog's own tests already exist in the tree at this ref, already failing. |
| `title` | string | Ticket title. Rendered byte-identically into both arms' prompts. |
| `body` | string | Task text. Never mentions the fix or shiploop. |
| `verify_cmd` | string | Run from the checkout root after the arm finishes; exit 0 means the ticket cleared. This is the whole oracle: nothing here is judged by a model, and nothing is patched onto the arm's tree first. |
| `kind` | string | Free-form category (`bug`, `feature`, `refactor`, `test`) for the private record. |

Rules that the runner enforces:

- Every ticket needs every field non-empty. `bench/run.sh` hard-stops on a malformed backlog rather
  than skipping the line, because a silently dropped ticket makes both arms cheaper and the ratio
  meaningless.
- All tickets in one backlog come from the same repo at the same `ref`, ordered so no two tickets
  touch the same files. Sequential vanilla work then cannot legitimately conflict.
- `verify_cmd` must be deterministic and offline. Neither arm has WebFetch or WebSearch. It is
  never in either arm's prompt: that would hand over the exact command that clears the ticket.

`bench/backlogs/fixture-backlog/` is a synthetic backlog used only by the test suite. It is not a
benchmark backlog and never appears in a published count.
