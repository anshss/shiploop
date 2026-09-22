# `backlog.jsonl` schema

One backlog is a directory under `bench/backlogs/` (published) or `bench/pilot-backlogs/`
(candidate pool, gitignored, never pushed) containing a single `backlog.jsonl`: one JSON object per
line, 2 or more lines, applied in file order. Nothing in `bench/run.sh` enforces exactly 2 — a
backlog may carry as many tickets as it has real, independent fixes for.

| Field | Type | Meaning |
|---|---|---|
| `id` | string | Ticket id, unique within the backlog. Used as the session `task` and in stream filenames, so keep it filename-safe. |
| `repo` | string | Clone URL or path of the repo. Every ticket in one backlog names the same repo. |
| `ref` | string | Pinned ref (commit sha preferred) that both arms are checked out at. Same for every ticket in the backlog. The backlog's own tests already exist in the tree at this ref, already failing. |
| `title` | string | Ticket title. Rendered byte-identically into both arms' prompts. |
| `body` | string | Task text. Never mentions the fix or shiploop. |
| `verify_cmd` | string | Run from the checkout root after the arm finishes; exit 0 means the ticket cleared. This is the whole oracle: nothing here is judged by a model, and nothing is patched onto the arm's tree first. Should restore its own test files from the pinned `ref` before running (`git checkout <ref> -- <test paths> && <runner>`), so an arm that edits the tests it is graded against cannot pass itself. |
| `kind` | string | Free-form category (`bug`, `feature`, `refactor`, `test`) for the private record. |

Rules that the runner enforces:

- Every ticket needs every field non-empty. `bench/run.sh` hard-stops on a malformed backlog rather
  than skipping the line, because a silently dropped ticket makes both arms cheaper and the ratio
  meaningless.
- All tickets in one backlog come from the same repo at the same `ref`, ordered so no two tickets
  touch the same files. Sequential vanilla work then cannot legitimately conflict.
- `verify_cmd` must be deterministic and offline. Neither arm has WebFetch or WebSearch. It is
  never in either arm's prompt: that would hand over the exact command that clears the ticket.
- A backlog's own test suite must run from a bare checkout with nothing fetched: no step in
  `verify_cmd` may install a dependency, because that would need network inside the offline guard
  (`bench::assert_offline`, `bench/run.sh`) — see "The no-install constraint" in
  `bench/KNOWN-LIMITS.md`. A backlog's tests must be stdlib-only, vendored, or already committed to
  the repo at the pinned `ref`. Do NOT add an install step to close this; there is no offline way to.

`bench/backlogs/fixture-backlog/` is a synthetic backlog used only by the test suite. It is not a
benchmark backlog and never appears in a published count.
