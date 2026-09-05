
<p align="center">
  <img src="assets/shiploop-readme-header.png" width="880" alt="Shiploop">
</p>

<p align="center">
Shiploop is a harness for Claude Code. It changes how work in a session is runs, so the same work ships on fewer tokens.
</p>

## Get Started

Install the plugin once, globally. `/shiploop:setup`, `/shiploop:flows` and the rest then appear in every session:

```
/plugin marketplace add anshss/shiploop
/plugin install shiploop@shiploop
```
or 
```
git clone https://github.com/anshss/shiploop.git ~/.claude/skills/shiploop &&
bash ~/.claude/skills/shiploop/install.sh
```

Then set it up on a project, once per project:

```bash
cd ~/code/your-project && claude   # then run: /shiploop:setup
```

Setup adapts to the folder. A single existing repo is wrapped in place: moved into a subfolder while remaining a separate Git repo, with history verified byte-for-byte and your cd path unchanged. A folder of repos or an empty folder gets a new scaffold; existing workspaces are upgraded component by component without changing your config.

Add every repo related to your project to the folder. Shiploop detects sub-repos, ports, dev commands, and your package manager, asks all setup questions in one batch, then finishes setup. It never overwrites README.md, CLAUDE.md, config, or governor files without --yes, and creates .wrap-undo.sh before wrapping.

## Built to Spend Fewer Tokens

One goal: minimize tokens per shipped work. These are the levers that materially change that outcome.

- **Routine changes skip the model.** Shiploop detects mechanical work during its survey, applies it deterministically, and verifies it. Ambiguous, unsafe, or unverified work goes to a normal worker.

- **Workers run lean.** Each Shiploop worker gets only the tools it needs: no slash commands, personal settings, MCP servers, or unused definitions. Trimming the tool list alone cuts tool bytes by 66.7% and the whole request by **−34.5%** ([full methodology](PROOF.md)).

- **Successful output stays out of the transcript.** Green test output adds little value, so it is omitted; failures are trimmed to the useful excerpt. CI logs work the same way. The interactive driver exposes this through `npm run vf -- <cmd>` and can delegate lookup or multi-file diagnosis to lookup and investigator agents.

- **A watchdog stops sessions that loop, stall, or just keep erroring.** It kills workers that loop, stall, or repeatedly error, and enforces per-worker and per-run token budgets. The worktree is kept so work can resume rather than restart. Both controls are independently configurable.

- **Every worker shares a scripted codebase map.** Pre-dispatch scripts index files, symbols, and structure, so workers do not repeatedly rediscover the repository. Retries inherit prior findings, and manual audits read only what changed.

- **Model orchestration.** Start with the lowest-cost capable model and escalate only after a clear failure. Failed attempts are usually far cheaper than successful ones, so a cheap first pass reduces average cost without compromising difficult work.

- **Retries resume instead of restart.** Failed workers keep their worktree and findings, avoiding another clone and repeated exploration.

- **Memory improves within a fixed budget.** Resolved tickets add lessons to CLAUDE.md, which is re-sent on every turn. Entries are capped, the file has a budget, and overflow moves to an appendix.

- **Blocked work is caught early.** Shiploop checks dependencies, repository health, capacity, setup, and duplicate upstream fixes before dispatching a worker. Work that cannot succeed never consumes one.

- **Related work can share exploration.** A worker can handle tickets whose scout-measured file paths overlap, exploring an area once instead of once per ticket. A five-ticket batch is therefore far cheaper than five separate workers.

Tokens are the currency. Shiploop breaks work into tickets; you choose the priorities, and each dispatched ticket is completed with the least token spend. The coordination layer uses no model tokens. The zero-model lane is off by default. Parallelism improves throughput, not per-ticket efficiency.

## How Shiploop Runs

You pick the tickets. Naming them is the only way work starts: there is no backlog sweep, because a
sweep spends on queue-order priorities and you have your own. Two layers are created for you: one
**workspace** and a fresh **worker** for every ticket.

**The workspace.** `/shiploop:setup` wraps your existing repo without absorbing it. Your code moves into a subfolder but stays a separate Git repo with its full history, and your `cd` path stays unchanged. Everything around it is plain text you can read and edit:

```yaml
your-project/
  <your-repo>/              # your code, untouched, still its own git repo
  queue/tickets.md          # the queue you dispatch from, one `## #N` per ticket
  governor/                 # doctrine, escalations, improvements
  scripts/                  # bash: status / dev / doctor / worktrees / govern
  scripts/lib/workspace.sh  # the ONE config file; every knob lives here
  CLAUDE.md                 # git-tracked memory; every resolved ticket adds a lesson
```

**The scripts** are the deterministic Bash harness. `run-loop.sh` owns state and control flow without calling a model; `spawn-worker.sh` builds prompts and launches workers; config-check.sh validates the full config with zero tokens and no Claude auth. Deciding what to do costs no tokens. Only the work does.

**The worktree** makes parallel work safe. Each ticket gets a worktree from current main, with ticket-named branches in every in-scope sub-repo. Out-of-scope sub-repos are detached and read-only for inspection. Workers cannot collide or inherit bad state. Failed worktrees remain for retries, and are removed only after the work lands, never with unpushed commits.

**The worker** is a fresh, headless `claude -p` session in that worktree. It receives a fixed prompt skeleton, `governor/preferences.md`, the ticket, scout-verified paths, and the prior handoff on retries. It has no MCP servers, slash commands, personal settings, or unnecessary tools. This reduces cost and keeps a single-purpose worker free of scheduling and orchestration baggage, including schemas re-sent across roughly 218 turns. It completes the task, opens a PR, and writes a structured report for the Bash driver.

That headless session is the worker’s autonomous lane. The same worker and doctrine also run interactively as `Agent(subagent_type: "worker")` for a single ticket: the same Sonnet floor, trimmed tools, dedicated worktree, and stopping point of PR open plus report. Merge, CI waiting, and queue bookkeeping return to the governor. `npm run govern -- <N>` adopts an already-open PR instead of repeating the work, so the queue block remains until merge.

Autonomy is bounded by the trust ladder, not the scaffolding. Workers bypass permissions by design, but operate only in a disposable worktree and on the branch they push.

## Glossary

One noun, one meaning. Every page pairs a term with its definition on its first prose use, because none of these
words is exclusively ours: Factory's docs, for one, call their in-session delegated children "worker
agents". In shiploop they mean exactly this:

| Term | Definition |
|---|---|
| **governor** | The pure-bash driver, `scripts/govern/run-loop.sh <N…>`. It owns state and control flow deterministically, spawns workers, and never calls a model itself. |
| **driver** | The orchestrating session: the governor on the autonomous side, your interactive Claude Code session on the other. A driver dispatches and relays verdicts; it does not bulk-read product source. |
| **worker** | The trim, single-ticket session. One definition, **two lanes**: the *autonomous* lane is the headless `claude -p` session `spawn-worker.sh` launches, the *interactive* lane is `Agent(subagent_type: "worker")` in your own session. Both run the same doctrine at the same model floor in their own worktree, and both end at a PR plus a structured report. Never used for any other kind of child. |
| **scout** | The cheap pre-dispatch survey pass (haiku). It only surveys: verified file paths, whether tests cover the area, whether history holds a precedent commit. Cached per run, so a retry never re-scouts. |
| **supervisor** | The review pass over a run's state (`npm run govern:audit`, `GOVERN_SUPERVISOR_MODEL`). It can return a `halt` verdict; it never edits code. |
| **subagent** | The platform's own term for an Agent-tool child that is **not** `subagent_type: "worker"` (the shipped `lookup` and `investigator` agent types, or a stock `Agent` call). Sized per the delegation table for investigation, sweeps, and diagnosis. A subagent is never called a worker, and ticket-shaped work never goes to one. |

## How it works

The runner is a pure-Bash driver (`scripts/govern/run-loop.sh <N> ...`): you name the tickets, and it deterministically owns state and control flow while using near-zero Claude context. Model tokens are spent only by the fresh headless workers it starts. Multiple tickets are grouped by measured file overlap, so concurrent workers never share a file. Every dispatch runs every gate: claim lock, `Depends on:`, staleness, base CI, upstream drift, and failure streak.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/how-it-works-dark.svg">
    <img src="assets/how-it-works-light.svg" width="880" alt="The shiploop loop: you name tickets from queue/tickets.md, and each one dispatches to a fresh headless worker in its own git worktree (sonnet floor, opus on retry), which opens a PR and waits for CI. A merge guard (allowlist + three-factor) auto-merges green-CI PRs on opted-in repos, or leaves the PR for you on the default pr-only rung. Hard-stops park and escalate to governor/escalations.md; a manual audit can review a run and halt it on demand. Every resolved ticket writes a lesson into CLAUDE.md, so the next worker starts smarter.">
  </picture>
</p>

- **One ticket, one fresh headless session.** Each gets its own Git worktree, keeping context flat, avoiding collisions, and preventing bad state from carrying between runs.
  
- **Cheap floor, one escalation.** Tickets start at `GOVERN_WORKER_MODEL` (default `sonnet`)and, after a classified failure, escalate once to `GOVERN_WORKER_ESCALATION_MODEL` (default `opus`). Per-ticket prediction was tested and proved to be a rubber stamp. Both respect a session ceiling: nothing spawns above `max(opus, the spawning session's model)`. A cheap Haiku scout runs first, but only surveys verified paths, test coverage, and precedent commits. Workers use it as a warm start; batching uses it for locality; the zero-model lane uses it as patch input. Results are cached per run, so retries do not re-scout.
  
- **Manual audit on demand** `npm run govern:audit` starts another cheap, fresh session to review a run and can return halt. Hard stops go to `governor/escalations.md`. It spends no model tokens unless you invoke it.
  
- **Improvement accumulates under review.** Resolved tickets promote durable lessons to the appropriate `CLAUDE.md` before their entry is deleted, creating memory you can read, diff, and edit. Harness improvements go to g`overnor/improvements.md` through observe → propose → triage, and never auto-apply to safety rails. `/shiploop:update` and `/shiploop:push` move mechanism fixes between the workspace and template repo, always through a human-reviewed PR.

## Commands

| Command | What it does |
|---|---|
| `/shiploop:setup` | Scaffold or upgrade a workspace: wrap-in-place inside an existing repo, or from a parent folder of repos |
| *(say "work on \<tickets\>")* | Ship the tickets you name: natural language onto the bash-driven ticket loop (`scripts/govern/run-loop.sh <N> ...`), end to end |
| `/shiploop:flows` | Inventory (`extract`), inspect (`list`), and validate (`file`) your product's user-facing paths |
| `/shiploop:update` | Pull the latest hub templates into this workspace (`workspace.sh` is never overwritten) |
| `/shiploop:push` | Port local mechanism improvements back to the hub as a human-reviewed PR (never auto-merges) |
| `npm run govern:audit` | Manual audit: review a run's state on demand, zero model spend unless invoked |
| `npm run govern:budgets` | Enforce context budgets (lesson char cap, learnings TTL) and run the evidence-based CLAUDE.md trim, all outside a dispatch; `--dry` to preview |
| `npm run govern:trim` | Evidence-based CLAUDE.md trim on its own: auto-move provably dead or duplicate blocks to the appendix, propose the rest (`--apply <hash>`, `--still-true <hash>`, `--dry-run`) |
| `npm run govern:externalize` | File open low-severity tickets as public good-first-issues and drop them from the queue (opt-in, off until `GOVERN_EXTERNALIZE_REPO` is set) |

`bash scripts/doctor.sh` warns when your workspace lags the hub by N releases, and **fails** when root `CLAUDE.md` exceeds its context budget (`SHIPLOOP_CLAUDEMD_MAX_CHARS`, default 14000), since an over-budget file is a tax on every turn of every session. `npm run govern:budgets` then trims on evidence, never on size: blocks whose every cited path or knob is provably gone (and exact duplicates) auto-move to `CLAUDE-APPENDIX.md`, everything else becomes a ranked proposal in `governor/claudemd-trim-proposals.md` for you to `--apply` or stamp `--still-true`. Doctor also reports how many proposals are pending.

### Fleet visibility

Governor workers are detached `claude -p` processes. Their pid lives only in a bash array inside
`run-loop.sh` and structured state is written only at completion, so while a run is in flight
*nothing on disk says "running"*, which is why no surface could ever show them.

`GOVERN_EVENTS=1` fixes that with one append-only log, `governor/events.jsonl`, and three readers
fold it. The emitter can never abort a run: a failed append is swallowed silently, by construction.

```
$ npm run govern:status
fleet: 2 active · 3 resolved · 1 parked · 0 failed · 1 escalated
run:   gov-20260901T101500Z-4242 (running, mode=live, up 41m)
  #94    opus     22m    pid 44112  effort=high
  #97    sonnet   4m     pid 44530  effort=medium
drivers: 2 live: #94(pid 44098) #97(pid 44520)
```

## Configuration

Everything lives in one file: `scripts/lib/workspace.sh`. Advanced lanes ship **off** so a fresh install is inert until you opt in:

| Knob | Default | Turns on |
|---|---|---|
| `GOVERN_AUTONOMY` | `pr-only` | Trust-ladder rung (`observe` / `pr-only` / `auto`); absent = `auto` for pre-knob installs |
| `GOVERN_MERGE_REPOS` | empty | Per-repo auto-merge allowlist (requires `auto`) |
| `GOVERN_WORKER_MODEL` | `sonnet` | First-attempt **floor**: the tier every ticket dispatches at. A ticket's own `Model:`/`Effort:` fields no longer participate in dispatch |
| `GOVERN_WORKER_ESCALATION_MODEL` | `opus` | Escalate-once **ceiling**: the tier a classified judgment failure retries at. A ticket never escalates twice |
| `GOVERN_MODEL_CEILING` | `1` (on) | Session ceiling: every model the harness dispatches (worker, scout, supervisor, self-improve, self-apply, sync porter) is clamped to `max(opus, the model of the session that spawned it)`. A sonnet or haiku driver still buys opus on a retry; only a session above opus may spawn above opus, and never above itself. `0` disables the clamp |
| `GOVERN_DETERMINISTIC` | `0` (off) | Zero-model lane: let the scout's mechanical patch resolve a ticket with **no model turns** on the fix. Over-strict guards; every doubt falls through to a normal worker |
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
| `GOVERN_PUBLIC_REPOS` | auto-detect | Public repos get neutral `sl-<hex>` branches, no ticket ids on PRs |
| `GOVERN_PR_TICKET_REF` | `0` (ids suppressed) | `1` puts the internal ticket id back in PR titles/bodies/commit subjects. By default every worker is told to keep `#N` off the PR and the run-loop scrubs title+body as a backstop; branches stay `ticket-<N>` either way. The opt-out never applies to a **public** repo |
| `GOVERN_EXTERNALIZE_REPO` / `_SUBREPO` | empty | Stage low-severity OSS tickets as public "good first issue"s, filed only on your approval |
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

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Everything the scaffolder installs lives under `templates/`; the slash commands under `commands/`; hermetic governor tests under `templates/govern/test/` (hub-only; the suite is not installed into a workspace).

## License

[Apache License 2.0](LICENSE). Includes an express patent grant and a
trademark reservation; redistributions must carry the [NOTICE](NOTICE) file
and state any changes made. Releases up to and including v1.15.1 were
published under the MIT license and remain available under those terms.
