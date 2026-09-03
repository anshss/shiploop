# bench/fixtures

Canned `claude -p --output-format stream-json` streams. They exist so `bench/run.sh --dry-run` and
the whole `templates/govern/test/test-bench-*.sh` suite exercise the real recording, capping, and rollup code paths
with zero spawns and zero spend.

| File | Stands in for |
|---|---|
| `vanilla-session.jsonl` | the one long session the `vanilla` arm runs over a whole backlog |
| `shiploop-driver.jsonl` | the governor driver session the `shiploop` arm spawns |
| `shiploop-worker.jsonl` | one fresh-context worker session inside the `shiploop` arm |
| `partial-no-result.jsonl` | a session hard-killed before it emitted a `result` event |
| `golden-results.jsonl` | a complete `results.jsonl` the rollup test asserts against |
| `selection-results.jsonl` | five backlogs: three comparable with different deltas, one whose vanilla arm failed to clear, one capped |

The numbers in these files are synthetic. They are chosen to be arithmetically convenient for the
tests and carry no claim about real runs. Nothing published may be computed from them.
