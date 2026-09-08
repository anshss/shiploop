# Configuration

Every knob shiploop reads lives in one file: `templates/lib/workspace.sh` in this hub repo, seeded
into each workspace as `scripts/lib/workspace.sh` by `/shiploop:setup` and refreshed (never
clobbered) by `/shiploop:update`. Advanced lanes ship **off** so a fresh install is inert until you
opt in.

| Knob | Default | Turns on |
|---|---|---|
| `GOVERN_AUTONOMY` | `pr-only` | Trust-ladder rung (`observe` / `pr-only` / `auto`); absent = `auto` for pre-knob installs |
| `GOVERN_MERGE_REPOS` | empty | Per-repo auto-merge allowlist (requires `auto`) |
| `GOVERN_WORKER_MODEL` | `sonnet` | First-attempt **floor**: the tier every ticket dispatches at. A ticket's own `Model:`/`Effort:` fields no longer participate in dispatch |
| `GOVERN_WORKER_ESCALATION_MODEL` | `opus` | Escalate-once **ceiling**: the tier a classified judgment failure retries at. A ticket never escalates twice |
| `GOVERN_MODEL_CEILING` | `1` (on) | Session ceiling: every model the harness dispatches (worker, scout, supervisor, self-improve, self-apply, sync porter) is clamped to `max(opus, the model of the session that spawned it)`. A sonnet or haiku driver still buys opus on a retry; only a session above opus may spawn above opus, and never above itself. `0` disables the clamp |
| `GOVERN_DETERMINISTIC` | `0` (off) | Zero-model lane: let the scout's mechanical patch resolve a ticket with **no model turns** on the fix. Over-strict guards; every doubt falls through to a normal worker |
| `GOVERN_STALENESS_GATE` | `0` (off) | Skip a ticket before dispatch if its named paths are gone from the tree. Fail-open: it only acts on positive evidence, never on absence of evidence |
| `GOVERN_STALENESS_RUN_TESTS` | `0` (off) | On top of the staleness check, also execute a test command read out of `tickets.md`. A separate opt-in on purpose: the queue is partly machine-written, and a stat() is not a `bash -c` |
| `GOVERN_EARLY_ABORT` | `0` (off) | Kill a worker showing no progress around turn 30 instead of letting it run to the usual ~218; it leaves a handoff the retry resumes from |
| `GOVERN_INDEX` | `1` (on) | Rebuild the deterministic codebase index after each resolved ticket. `0` stops the rebuild |
| `GOVERN_VERIFY_FILTER` | `1` (on) | Collapse a passing build/test run to one line. `0` restores the verbatim output |
| `GOVERN_RUN_MAX_TOKENS` | `0` (no cap) | Stop the run cleanly once this many tokens are spent across the whole run, not just one worker. `0` means no run-level brake |
| `GOVERN_SCOUT` | on | Pre-dispatch survey (verified file paths, coverage, precedent commit) used as a worker warm start, the batching key, and the zero-model patch source. It does **not** pick the tier |
| `GOVERN_SCOUT_MODEL` | `haiku` | Tier the scout pass itself runs at; recon should cost a rounding error |
| `GOVERN_SCOUT_TIMEOUT` | `180` | Seconds the scout pass may run before it is abandoned; dispatch proceeds without a survey |
| `GOVERN_PARALLEL_DEFAULT` | `4` | Locality groups a named `run-loop.sh <N> ...` dispatch works at once: `N > 1` runs N concurrent full-driver children, one per group (N× the spend); per-run `--parallel[=N]` / `--serial` override it. Naming exactly one ticket, or resolving to a single group, always collapses to sequential |
| `GOVERN_RETRY_NOTES_MAX_BYTES` | `16000` | Byte cap on the findings scratchpad (`.governor-notes.md`) a retry inherits from the previous attempt; the full file stays on disk in the preserved worktree |
| `GOVERN_LESSON_MAX_CHARS` | `600` | Char cap on a single lesson promoted into `CLAUDE.md`; overflow keeps the lead rule inline and parks the full text in `CLAUDE-APPENDIX.md` |
| `GOVERN_LESSON_EVICT` | `1` (on) | Forced eviction at budget: once root `CLAUDE.md` is at/over `GOVERN_LESSON_BUDGET_CHARS`, a new always-on lesson must name the existing entry it displaces (`lessonPatch.evicts`, matching exactly one heading/rule line) or it is routed to `CLAUDE-APPENDIX.md` instead of growing the always-on file. `0` restores the old always-insert-into-`CLAUDE.md` behaviour |
| `SHIPLOOP_CLAUDEMD_MAX_CHARS` | `14000` | Total budget for root `CLAUDE.md` (alias `GOVERN_LESSON_BUDGET_CHARS`); enforced by `npm run govern:budgets` and checked by `doctor`. Past the ceiling the evidence-based trim proposes candidates, it never blind-evicts |
| `GOVERN_TRIM_DEAD` | `1` (on) | Lane 1 of the CLAUDE.md trim: auto-move blocks whose every cited path/knob is provably absent from the workspace, plus exact duplicates, into `CLAUDE-APPENDIX.md`. `0` disables auto-moves, leaving proposals only |
| `SHIPLOOP_LEARNINGS_TTL` | `0` (off) | Age out `learnings.md` entries older than `SHIPLOOP_LEARNINGS_TTL_DAYS` (default `14`) when `npm run govern:budgets` runs |
| `GOVERN_WORKER_TOOLS` | `default` (on) | Tool-schema trim: passes `--tools <recommended list>` to every worker, cutting the measured 51.7% of the request that tool JSON occupies down to 26.3% (−34.5% request bytes; see `PROOF.md` §5). Or give your own space/comma-separated list. Capability-probed, so an older CLI just skips it |
| `WSP_LINT_FIX_CMD` | empty | Pre-commit lint/format fix across sub-repos |
| `GOVERN_LOCAL_FIRST_REPOS` | empty | Repos with no prod DB: additive migrations merge instead of parking |
| `GOVERN_MIGRATE_CMD` / `GOVERN_VERIFY_CMD` | empty | If a resolved ticket carries an additive prod migration, the governor runs MIGRATE then VERIFY after merge. Leave unset and a ticket like that escalates instead, asking you to apply the migration manually |
| `GOVERN_PUBLIC_REPOS` | auto-detect | Public repos get neutral `sl-<hex>` branches, no ticket ids on PRs |
| `GOVERN_PR_TICKET_REF` | `0` (ids suppressed) | `1` puts the internal ticket id back in PR titles/bodies/commit subjects. By default every worker is told to keep `#N` off the PR and the run-loop scrubs title+body as a backstop; branches stay `ticket-<N>` either way. The opt-out never applies to a **public** repo |
| `GOVERN_EXTERNALIZE_LANE` | `1` (on) | Master switch for the externalization lane itself; `0` disables it outright even if the vars below are set. Still a no-op until `GOVERN_EXTERNALIZE_REPO`/`_SUBREPO` are also configured |
| `GOVERN_EXTERNALIZE_REPO` / `_SUBREPO` | empty | Stage low-severity OSS tickets as public "good first issue"s, filed only on your approval |
| `GOVERN_EXTERNALIZE_LABELS` | empty | Manual label override applied verbatim to filed issues. Empty means auto-decide: the lane fetches the target repo's existing labels and picks from them per issue |
| `GOVERN_UPSTREAM_HARNESS_REPO` / `_DIR` | empty | The `/shiploop:push` sync channel to your hub fork |
| `WSP_PR_FOOTER` | on | "shipped by shiploop" attribution line on worker PRs (`off` to suppress) |
| `GOVERN_EVENTS` | `0` (off) | Fleet event log: append one JSON line per worker spawn/finish/escalation/park to `governor/events.jsonl`. Nothing reads it until you turn it on, and nothing about a run changes when you do. This is what `npm run govern:status`, the statusline segment, and the plugin monitor all fold; see **Fleet visibility** below |
| `GOVERN_EVENTS_FILE` | `governor/events.jsonl` | Where that log lives |
| `GOVERN_VF_NUDGE` | `1` (on) | Driver-session advisory: an unwrapped test/build command (`npm test`, `pytest`, `go test`, `cargo test`, `vitest`, `jest`, `tsc`, ...) gets a one-line nudge toward `npm run vf -- <cmd>`. Advisory only, capped per session, silent for workers and sub-agents; `0` disables it |

| Surface | What it is | How to get it |
|---|---|---|
| `npm run govern:status` | One-shot reader. Text, or `--json` for machines. Verifies every claimed-live worker with `kill -0` and reaps the phantoms a killed driver leaves behind. No model call, no lock, so it is safe from inside a session, from CI, or over SSH | Ships with the harness |
| Statusline segment | `⚙ 4/6 · #94 opus 22m` in your Claude Code statusline. Silent when no fleet is running | `/shiploop:statusline`; explicit, opt-in, and it **chains**: your existing `statusLine.command` is recorded verbatim and wrapped, never replaced. `uninstall` restores it byte for byte |
| Plugin monitor | The in-session channel. Prints one line per state *transition* (never a raw tail), which Claude Code turns into a notification in your session | Automatic with the plugin; silent in any session with no event log. `GOVERN_MONITOR=0` to disable |

The monitor is deliberately stingy: every line it prints costs context in the very session shiploop
exists to keep cheap. It dedupes repeated states, caps itself at 6 lines/minute
(`GOVERN_MONITOR_MAX_PER_MIN`), attaches at the *end* of the log so history is never replayed, and
prints nothing at all when there is no fleet.

### Permissions

| Knob | Default | Turns on |
|---|---|---|
| `GOVERN_PERMISSION_MODE` | `bypassPermissions` | The `--permission-mode` every headless worker runs under. The default lets a worker act without prompting, which is what makes an unattended run possible, and also the single widest grant in the harness. Tighten it if you want workers to stop at the permission boundary; note that a mode which prompts will stall a headless run rather than fail it |
| `GOVERN_WORKER_MCP` | `0` (off) | Give workers the workspace's MCP servers. Off by default: MCP tool schemas are re-sent on every turn, so this is a standing per-turn cost |

### Hard bounds: how a run is guaranteed to end

| Knob | Default | Turns on |
|---|---|---|
| `GOVERN_MAX_TICKETS` | `20` | Tickets one driver will work before stopping. **Per driver**, so a `--parallel` dispatch's real ceiling is N × this |
| `GOVERN_MAX_BAD_STREAK` | `4` | Consecutive parked/failed tickets before the run halts itself |
| `GOVERN_MAX_RUNTIME` | `0` (no cap) | Wall-clock seconds. There is **no** time bound unless you set one |
| `GOVERN_WORKER_TIMEOUT` | `3600` (1h) | Seconds one worker may run before it is killed rather than left stalled |
| `GOVERN_WORKER_MAX_TOKENS` | `0` (unlimited) | Token ceiling per worker; crossing it kills the worker with a distinct `budget-exceeded` outcome |
| `GOVERN_MIN_FREE_GB` | `5` | Free-disk floor checked before spawning; below it the run stops rather than filling the volume |

### CI, retries, and cadence

| Knob | Default | Turns on |
|---|---|---|
| `GOVERN_CI_INTERVAL` | `30` | Seconds between CI polls while awaiting checks |
| `GOVERN_CI_MAX_TRIES` | `60` | Polls before CI is treated as never-settling (≈30 min at the default interval) |
| `GOVERN_CI_FIX_TRIES` | `1` | Attempts a worker gets at fixing its own red CI before the ticket parks |
| `GOVERN_CONFLICT_FIX_TRIES` | `1` | Attempts at resolving a merge conflict before parking |
| `GOVERN_INFRA_RETRY` | `1` | Retries for an infrastructure-class failure (API/transport). Retried at the **same** model tier, not escalated |
| `GOVERN_INTERRUPT_RETRY` | `1` | Retries for a worker killed mid-flight |
| `GOVERN_SUPERVISOR_MODEL` | `sonnet` | Tier the manual audit (`govern:audit`) runs at |
| `GOVERN_BATCH_MAX` | `2` | Tickets with overlapping scout-measured file paths that one worker may take as a group, exploring once and opening one PR. Kept low because no production A/B measurement of batching exists yet; `1` disables it |
| `GOVERN_OVERLAP_NUDGE` | `1` (on) | Dispatch-time hint, zero model calls: before a named dispatch proceeds, print up to 5 `[overlap]`/`[overlap-dir]` lines naming any OTHER open ticket that shares a file (or, weaker, a directory) with what you named, so you can re-run with both on `npm run govern --`. Log line only, never blocks and never touches the queue; `0` silences it |
| `GOVERN_AUTO_BUDGETS` | `1` (on) | Run `govern-bookkeep.sh --enforce-budgets` once at the end of every dispatch, after every worker is reaped (never per-ticket, so an N-way `--parallel` fan-out doesn't overfire it). A "still over budget" alarm from that pass (exit 3) is logged but never changes the dispatch's own exit status. `0` disables the auto-run; `npm run govern:budgets` still works manually either way |

### Script-level overrides (not seeded in workspace.sh)

A handful of toggles are read straight out of the environment by the one script that uses them,
via `${VAR:-default}`, and are never written into `scripts/lib/workspace.sh`. Set them as plain
environment variables if you need to change one.

| Knob | Default | Turns on |
|---|---|---|
| `GOVERN_MONITOR` | `1` (on) | The in-session plugin monitor (`tools/fleet-monitor.sh`). `0` is the kill switch: a session that wants nothing from the fleet log idles out immediately instead of staying half-alive |
| `GOVERN_SKIP_CI` | `0` (off) | Skips the CI wait before merging a PR (`templates/govern/merge-pr.sh`). `1` merges without polling `await-ci.sh` at all |
| `GOVERN_TICKET_ROUTE_GUARD` | `1` (on) | The blocking hook (`templates/hooks/router-posture-guard.sh`) that denies an `Agent` call for ticket-shaped work unless it targets `subagent_type: "worker"`. `0` turns the guard off |
| `GOVERN_SELF_APPLY` | `0` (off) | Lets the self-improvement lane (`templates/govern/govern-self-apply.sh`) apply its own proposed harness diffs to an allow-listed set of mechanism scripts. `1` enables it |
| `WSP_ANALYTICS_QUERY_CMD` | empty | Command a flow's passive-evidence check (`templates/govern/lib/flows.sh`) shells out to for analytics data; unset means the check degrades to "no passive evidence" |

