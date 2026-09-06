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
| `verify_cmd` | string | The test the merged upstream PR made pass. Run from the checkout root **after `test_patch` is applied**; exit 0 means the ticket cleared. This is the whole oracle: nothing here is judged by a model. |
| `kind` | string | Free-form category (`bug`, `feature`, `refactor`, `test`) for the private record. |
| `upstream_pr` | string | URL of the merged PR the ticket was mined from. Private provenance; never published. |
| `test_patch` | string | Unified diff carrying **only** the test-file changes from the merged PR, no source changes. Must apply exactly to the tree at `ref`. |
| `merge_sha` | string | The PR's merge commit SHA. Used only by `bench/validate-backlog.sh`; the arms never see it. |

## Why `test_patch` exists

`verify_cmd` is the test the merged PR made pass, which means **at the pinned `ref` that test does
not exist**: the PR added it. The arm is told only the problem, never the test file and never the
case name, so it can never reproduce that name on its own. Verifying against the ref's tree would
fail every ticket in both arms and drop every backlog.

So the oracle is SWE-bench shaped. `test_patch` is applied at **verify time only**, on the tree the
arm produced, and `verify_cmd` runs after that. The ordering is the contract:

1. Worktree at `ref`. The arm session receives `title` and `body` verbatim and nothing else. It
   never sees `test_patch`, `merge_sha`, `upstream_pr`, or even `verify_cmd`: that command names
   the gold test file, and handing it over would let an arm satisfy the oracle without solving the
   problem.
2. The arm finishes and commits.
3. `git apply` the `test_patch` onto the arm's tree, then run `verify_cmd`. Record `verifyExit`.
4. If the apply fails (the arm edited a test file the patch touches), record the distinct sentinel
   `90` and treat the ticket as unresolved. No 3-way merge, no fuzzy apply, no `--reject`:
   silently repairing the oracle is worse than failing it, because a repaired oracle produces a
   number that looks measured and is not.

Same path for both arms, no exceptions.

## Validation

`bench/validate-backlog.sh` is the offline gate that decides which backlogs are even eligible for
the pilot. Per ticket, against a real clone, with no model calls: the patch must apply at `ref`,
`verify_cmd` must FAIL there (the fail-to-pass precondition), and at `merge_sha` the test content
must be present and `verify_cmd` must PASS. A backlog with fewer than 6 survivors is unusable.
`--json` feeds the selection step.

Rules that the runner enforces or that selection depends on:

- Every ticket needs every field non-empty. `bench/run.sh` hard-stops on a malformed backlog rather
  than skipping the line, because a silently dropped ticket makes both arms cheaper and the ratio
  meaningless.
- All tickets in one backlog come from the same repo at the same `ref`, ordered so no two tickets
  touch the same files. Sequential vanilla work then cannot legitimately conflict.
- `verify_cmd` must be deterministic and offline. Neither arm has WebFetch or WebSearch.
- `test_patch` must touch test files only. A source change smuggled into it would hand both arms the
  fix and make every ticket clear for free.
- `upstream_pr` exists so a ticket can be traced back during review. It is internal record only.

`bench/backlogs/fixture-backlog/` is a synthetic backlog used only by the test suite. It is not a
benchmark backlog and never appears in a published count.
