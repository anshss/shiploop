#!/usr/bin/env bash
# bench/arms.sh: the arm shapes of the live A/B benchmark. Source, do not execute.
#
#   vanilla        without shiploop. ONE `claude -p` session per backlog, headless default model,
#                  the CLI's own DEFAULT toolset (no --tools flag at all), no hooks, no extra
#                  CLAUDE.md, in a fresh worktree of the pinned ref. The prompt is the backlog
#                  verbatim plus the one framing line. This is stock Claude Code used the way it is
#                  used out of the box: one session, one conversation, top to bottom.
#   vanilla-fresh  a fresh `claude -p` per ticket, sequential, same prompt shape, same no-flag
#                  toolset. Private record only: if a teardown replays us with per-ticket sessions
#                  we already know the delta. Never published.
#   shiploop       with shiploop. The SAME checkout, inside a workspace `scaffold.sh` actually
#                  built, handed the SAME whole-backlog prompt as vanilla. It follows whatever the
#                  installed doctrine tells it to: acts as advisor, spawns worker subagents through
#                  the native Agent tool (the scaffolded .claude/agents/worker.md that
#                  --setting-sources project,local already picks up with no --agents flag), and —
#                  if it chooses to — pipes a worker's report into its own resolve step. Nothing
#                  here scripts that sequence: the session under test decides it, the way a real
#                  operator's session does.
#
# Ticket text is byte-identical across arms. The treatment arm gets no hints: asymmetric input is
# the first thing a replay finds, and it voids even true numbers.
#
# Neither arm gets a curated --tools list any more: the ONLY difference between arms is which
# directory the session opens in. A trimmed tool schema was itself one of the ten levers under
# test, so handing it to the control arm (or holding it back from the advisor's own session) would
# lend one arm part of the product's own credit. `bench::assert_offline` (bench/run.sh) plus the
# git-remote strip plus the scrubbed GH_TOKEN/GITHUB_TOKEN/... env still close every leak this
# design can close without a network namespace — the open gap (a worker's own Bash could still
# reach the network) is unchanged and is disclosed in bench/KNOWN-LIMITS.md, not something either
# arm's tool list ever tried to plug.
set -euo pipefail

BENCH_ARMS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH_ARMS_HUB="$(cd "$BENCH_ARMS_DIR/.." && pwd)"

# ── --max-turns / --max-budget-usd capability probe ─────────────────────────
# CLAUDE.md anti-pattern 12: never put a new `claude` flag on a dispatch path unguarded. The fleet's
# CLI is not ours, and an unknown flag makes `claude -p` die at argument parsing, which the failure
# classifier reports as a generic `failed`. A marketing benchmark that silently fails is worse than
# an honest one.
#
# Neither probe is reimplemented here. `govern::claude_supports_max_turns` and
# `govern::claude_supports_max_budget_usd` live in templates/govern/lib/common.sh beside the
# --exclude-dynamic-system-prompt-sections probe: cached, bounded `--help` greps, never a version
# compare, each with its own `_GOVERN_..._SUPPORTED` pre-seed test seam. Both arms need the same
# answer, and the shiploop arm's own workers reach the same two probes through spawn-worker.sh's
# GOVERN_WORKER_MAX_TURNS / GOVERN_WORKER_MAX_BUDGET_USD IF the session chooses that path, so the
# probes are the only way the two arms can be guaranteed to agree.
#
# --max-turns is tried FIRST; --max-budget-usd is the fallback for a CLI release that dropped
# --max-turns entirely (observed: claude 2.1.246 has no --max-turns, only --max-budget-usd). A
# dollar ceiling is not turn-shaped, but it is the closest available substitute for capping a
# spend-bearing session, and the run-level BENCH_MAX_USD cap still bounds the whole run either way.
#
#   BENCH_MAX_TURNS_FLAG=0        kill switch: never pass --max-turns or --max-budget-usd
#   _GOVERN_MAXTURNS_SUPPORTED    pre-seed 1|0 to skip the --max-turns probe (test seam)
#   _GOVERN_MAXBUDGETUSD_SUPPORTED pre-seed 1|0 to skip the --max-budget-usd probe (test seam)
#
# Unsupported CLI (neither flag) is a HARD STOP, not a silent degrade: a per-session ceiling is an
# always-on rail and dropping it would spawn an uncapped, spend-bearing session.
# `BENCH_ALLOW_UNCAPPED_TURNS=1` is the deliberate operator override.
bench::claude_supports_max_turns() { # <claude_bin> -> rc 0 supported, 1 not
  govern::claude_supports_max_turns "$1"
}

bench::claude_supports_max_budget_usd() { # <claude_bin> -> rc 0 supported, 1 not
  govern::claude_supports_max_budget_usd "$1"
}

# Sets the global `bench_max_turns_flag` (empty, `--max-turns N`, or `--max-budget-usd D`). Always
# returns 0; the caller decides what an empty flag means, because the two arms differ (a vanilla
# session refuses to run uncapped, a shiploop worker still has GOVERN_WORKER_TIMEOUT under it).
bench::resolve_max_turns_flag() { # <claude_bin> <turns> <budget_usd>
  local bin="$1" turns="$2" budget="$3"
  bench_max_turns_flag=""
  if [[ "${BENCH_MAX_TURNS_FLAG:-1}" == "0" ]]; then
    bench::log "BENCH_MAX_TURNS_FLAG=0, omitting the per-session ceiling flag (disabled by operator)"
    return 0
  fi
  if bench::claude_supports_max_turns "$bin"; then
    bench_max_turns_flag="--max-turns $turns"
    return 0
  fi
  bench::log "claude CLI ($bin) does not support --max-turns, so the BENCH_MAX_TURNS rail cannot be enforced"
  if bench::claude_supports_max_budget_usd "$bin"; then
    bench_max_turns_flag="--max-budget-usd $budget"
    bench::log "falling back to --max-budget-usd $budget as the per-session ceiling"
  else
    bench::log "claude CLI ($bin) does not support --max-budget-usd either, so no per-session ceiling flag can be enforced"
  fi
  return 0
}

# Guard: a spend-bearing arm must never spawn without the turn ceiling.
bench::require_turn_ceiling() { # <arm>
  if [[ -n "${bench_max_turns_flag:-}" ]]; then return 0; fi
  if [[ "${BENCH_ALLOW_UNCAPPED_TURNS:-0}" == "1" ]]; then
    bench::log "arm $1: running UNCAPPED (BENCH_ALLOW_UNCAPPED_TURNS=1)"
    return 0
  fi
  bench::die "arm $1: --max-turns is unavailable and BENCH_ALLOW_UNCAPPED_TURNS is not set. Refusing to spawn an uncapped session; upgrade the claude CLI or set BENCH_ALLOW_UNCAPPED_TURNS=1 deliberately."
}

# ── --forward-subagent-text capability probe ────────────────────────────────
# Attribution inside the treatment arm (which model did the advisor's own reasoning, which did the
# worker's) reads forwarded subagent turns tagged `parent_tool_use_id`, each carrying its own
# `message.usage` / `message.model`. That forwarding is itself a `claude` CLI flag on a dispatch
# path, so CLAUDE.md anti-pattern 12 applies exactly as it does to --max-turns above: a cached,
# bounded --help grep, never a version compare, with its own pre-seed seam
# (`_GOVERN_FWDSUBAGENT_SUPPORTED`) and env kill switch (`BENCH_FORWARD_SUBAGENT_TEXT=0`).
#
# Unlike --max-turns, an unsupported CLI here is a HARD STOP for the shiploop arm rather than a
# fallback: there is no substitute flag, and running without it would silently degrade the
# treatment arm's own attribution to "unmeasured" while everything else looked like a normal run —
# the same failure mode section 6 closes for subagent_stats. `bench::require_turn_ceiling` is the
# shape this copies: a spend-bearing arm either gets the rail or the run refuses to start.
_GOVERN_FWDSUBAGENT_PROBE_CACHE="${GOVERN_FWDSUBAGENT_PROBE_CACHE:-${GOVERN_RUN_DIR:-$GOVERNOR_DIR}/.claude-fwd-subagent-support}"

bench::claude_supports_forward_subagent_text() { # <claude_bin> -> rc 0 supported, 1 not
  local bin="$1"
  local cached=""
  if [[ -n "${_GOVERN_FWDSUBAGENT_SUPPORTED:-}" ]]; then
    if [[ "$_GOVERN_FWDSUBAGENT_SUPPORTED" == "1" ]]; then return 0; else return 1; fi
  fi
  [[ -f "$_GOVERN_FWDSUBAGENT_PROBE_CACHE" ]] && cached="$(cat "$_GOVERN_FWDSUBAGENT_PROBE_CACHE" 2>/dev/null || true)"
  if [[ -z "$cached" ]]; then
    if govern::_bounded_help_grep "$bin" "$_GOVERN_EDP_PROBE_TIMEOUT_S" '--forward-subagent-text'; then
      cached="1"
    else
      cached="0"
    fi
    if [[ "${_GOVERN_EDP_TIMED_OUT:-0}" == "1" ]]; then
      bench::log "claude CLI ($bin) --help probe TIMED OUT after ${_GOVERN_EDP_PROBE_TIMEOUT_S}s (possible hanging wrapper/shim), treating as unsupported this run; omitting --forward-subagent-text"
    fi
    mkdir -p "$(dirname "$_GOVERN_FWDSUBAGENT_PROBE_CACHE")" 2>/dev/null || true
    printf '%s' "$cached" > "$_GOVERN_FWDSUBAGENT_PROBE_CACHE" 2>/dev/null || true
  fi
  if [[ "$cached" == "1" ]]; then return 0; else return 1; fi
}

# Sets the global `bench_fwd_subagent_flag` (empty or `--forward-subagent-text`). Hard-stops the
# whole run when unsupported and no override is set — see the header comment above for why this one
# has no degraded fallback the way --max-turns does.
bench::resolve_forward_subagent_flag() { # <claude_bin>
  local bin="$1"
  bench_fwd_subagent_flag=""
  if [[ "${BENCH_FORWARD_SUBAGENT_TEXT:-1}" == "0" ]]; then
    bench::log "BENCH_FORWARD_SUBAGENT_TEXT=0, omitting --forward-subagent-text (disabled by operator); the treatment arm's own advisor/worker attribution will be unmeasured this run"
    return 0
  fi
  if bench::claude_supports_forward_subagent_text "$bin"; then
    bench_fwd_subagent_flag="--forward-subagent-text"
    return 0
  fi
  bench::die "claude CLI ($bin) does not support --forward-subagent-text, so the treatment arm's advisor/worker attribution cannot be measured. Upgrade the claude CLI, or set BENCH_FORWARD_SUBAGENT_TEXT=0 to run without attribution deliberately (the headline cost/token numbers are unaffected either way — attribution is never the headline)."
}

# ── prompts ─────────────────────────────────────────────────────────────────
# Byte-identical ticket text across arms: both of these render from the same backlog.jsonl fields
# through the same jq program, so there is one place where the wording lives.
# A rendered ticket is TITLE and BODY, and nothing else.
#
# `verify_cmd` is deliberately NOT in the prompt. Under the golden-test-patch oracle the test does
# not exist at the pinned ref (the merged PR added it, and the patch is applied at verify time,
# after the session ends), so printing "Verify with: pytest tests/test_foo.py::test_bar" would hand
# the arm the exact file and case name the oracle is about to create. That is gold-test leakage: an
# arm that knows the target test name can satisfy the oracle without solving the problem, and the
# leak is symmetric across arms, so it would not even show up as an asymmetry. The arm gets the
# issue text and the repo's own test suite, which is what a real engineer starts with.
bench::backlog_prompt() { # <backlog.jsonl> -> the vanilla session prompt on stdout
  printf 'Work through these tickets in order; commit each when its tests pass.\n\n'
  bench::tickets_markdown "$1"
  return 0
}

bench::ticket_prompt() { # <backlog.jsonl> <ticket-id> -> one ticket's prompt on stdout
  printf 'Work this ticket; commit when its tests pass.\n\n'
  jq -r --arg id "$2" 'select(.id == $id) | "## " + .title + "\n\n" + .body + "\n"' "$1"
  return 0
}

bench::tickets_markdown() { # <backlog.jsonl> -> all tickets as markdown on stdout
  jq -r '"## " + .title + "\n\n" + .body + "\n"' "$1"
  return 0
}

# ── vanilla (without shiploop) ───────────────────────────────────────────────
# ONE session for the whole backlog. Writes exactly one stream: 01-<backlog>.jsonl.
bench::arm_vanilla() { # <workdir> <backlog.jsonl> <logdir> <backlog-name>
  local wd="$1" backlog="$2" logdir="$3" name="$4"
  local prompt jsonl
  jsonl="$logdir/01-$name.jsonl"
  prompt="$(bench::backlog_prompt "$backlog")"
  bench::resolve_max_turns_flag "$BENCH_CLAUDE_BIN" "$BENCH_TURNS" "$BENCH_SESSION_USD"
  bench::require_turn_ceiling vanilla
  bench::spawn "$wd" "$prompt" "$jsonl" ${bench_max_turns_flag:-}
  return 0
}

# ── vanilla-fresh ───────────────────────────────────────────────────────────
# A fresh session per ticket, sequential, same worktree so later tickets see earlier commits.
# Streams are NN-<ticket-id>.jsonl in dispatch order. Also without shiploop: same no-flag toolset.
bench::arm_vanilla_fresh() { # <workdir> <backlog.jsonl> <logdir> <backlog-name>
  local wd="$1" backlog="$2" logdir="$3"
  local i=0 id prompt jsonl
  bench::resolve_max_turns_flag "$BENCH_CLAUDE_BIN" "$BENCH_TURNS" "$BENCH_SESSION_USD"
  bench::require_turn_ceiling vanilla-fresh
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    i=$((i+1))
    jsonl="$(printf '%s/%02d-%s.jsonl' "$logdir" "$i" "$id")"
    prompt="$(bench::ticket_prompt "$backlog" "$id")"
    bench::spawn "$wd" "$prompt" "$jsonl" ${bench_max_turns_flag:-}
  done < <(jq -r '.id' "$backlog")
  return 0
}

# ── shiploop (with shiploop) ─────────────────────────────────────────────────
# Scaffold a throwaway workspace around the SAME checkout the vanilla arm gets, seed
# queue/tickets.md from the backlog, and hand the advisor session the SAME whole-backlog prompt
# vanilla gets. This is the whole point of the design: from here on the only difference between
# arms is which directory the session opened in. Nothing about the dispatch loop is reimplemented,
# simulated, or scripted on the session's behalf — it invokes whatever the scaffolded CLAUDE.md /
# SKILL.md tells it to, the way a real operator's session does.
bench::arm_shiploop() { # <workdir> <backlog.jsonl> <logdir> <backlog-name>
  local wd="$1" backlog="$2" logdir="$3" name="$4"
  local ws slug prompt jsonl ghbin
  slug="$(bench::repo_slug "$backlog")"
  ws="$(bench::scaffold_workspace "$wd" "$name" "$slug")"
  bench::assert_offline "$ws"
  bench::seed_tickets "$backlog" "$ws/queue/tickets.md" "$slug"
  ghbin="$(bench::install_local_gh "$ws" "$slug")"
  jsonl="$logdir/01-$name.jsonl"
  prompt="$(bench::backlog_prompt "$backlog")"
  bench::resolve_max_turns_flag "$BENCH_CLAUDE_BIN" "$BENCH_TURNS" "$BENCH_SESSION_USD"
  bench::require_turn_ceiling shiploop
  bench::resolve_forward_subagent_flag "$BENCH_CLAUDE_BIN"
  # The advisor session's own env. NOT GOVERN_WORKER_TOOLS / GOVERN_WORKER_MAX_TURNS /
  # GOVERN_WORKER_MAX_BUDGET_USD / GOVERN_WORKER_MODEL: every one of those is a lever under test
  # (rail 4 — "the treatment arm's model tiers come from the scaffold, not from bench"), and the
  # scaffolded .claude/agents/worker.md already carries its own model/tools/permissionMode in its
  # frontmatter with no flag needed. GOVERN_AUTONOMY=auto + the merge allowlist below are NOT a
  # lever: they are what makes a resolved ticket actually land in this offline, reviewer-less
  # workspace at all, exactly as bench::scaffold_workspace already documents for the old loop.
  local rundir="$ws/logs/govern/run-$(date +%Y%m%d-%H%M%S)-$$"
  mkdir -p "$rundir"
  (
    cd "$ws"
    export PATH="$ghbin:$PATH"
    export GOVERN_WS_ROOT="$ws"
    export GOVERN_RUN_DIR="$rundir"
    export GOVERN_AUTONOMY=auto
    export GOVERN_PR_TICKET_REF=1
    export _GOVERN_ASSUME_MERGE_ALLOWED=1
    unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GH_HOST GH_REPO
    bench::spawn "$ws" "$prompt" "$jsonl" ${bench_max_turns_flag:-} ${bench_fwd_subagent_flag:-}
  )
  # Two failure modes that produce a clean-looking zero (section 6): a subagent refused for zero
  # tools, or a stream headed by bench::spawn's merged-stderr non-JSON line, both still exit 0 with
  # is_error:false. A treatment arm that never spawned a worker is indistinguishable from one that
  # worked unless this is checked directly against subagent_stats, never the exit code. This is the
  # REAL spawn path only — bench::run_arm calls bench::dry_arm instead of this function under
  # --dry-run, so there is no canned-fixture case to special-case here.
  if ! bench::stream_had_subagent_activity "$jsonl"; then
    bench::die "arm shiploop ($name): the advisor session's own result event shows no completed subagent (subagent_stats.spawned>0 && completed>0 required) — this cell measured nothing, not a real with-shiploop run. See $jsonl."
  fi
  bench::report_attribution "$ws" "$jsonl" "$rundir" "$name"
  # Write-back: the dispatch above worked entirely inside "$ws/$slug", a COPY bench::scaffold_workspace
  # made of $wd (arms.sh cp -R). run.sh's main loop verifies "$wd" (the ORIGINAL), never the copy —
  # so without this, verify always sees the pristine pre-run checkout and the shiploop arm can never
  # register a cleared ticket, no matter how correct the session's fix was. The copy IS the fully
  # evolved tree (worker commits + local merges happened there), so replace $wd with it wholesale.
  if [[ -d "$ws/$slug/.git" ]]; then
    rm -rf "$wd"
    cp -R "$ws/$slug" "$wd"
  else
    bench::log "arm_shiploop: $ws/$slug has no .git — write-back skipped, $wd left as the pristine checkout (verify will show 0 cleared)"
  fi
  return 0
}

# Install the purely-local `gh` shim (bench/local-gh.sh) for one cell's shiploop run and prints its
# bin directory. Env it needs is exported here, not left for the caller, so "the shim's contract"
# lives in one place. See bench/local-gh.sh's header for exactly what it does and does not emulate.
bench::install_local_gh() { # <workspace> <repo-slug-short-name> -> bin dir on stdout
  local ws="$1" repo="$2" bindir
  bindir="$ws.gh-bin"
  rm -rf "$bindir"; mkdir -p "$bindir"
  cat > "$bindir/gh" <<EOF
#!/usr/bin/env bash
export BENCH_GH_REPO_DIR="$ws/$repo"
export BENCH_GH_DEFAULT_BRANCH="main"
export BENCH_GH_LEDGER="$ws.gh-ledger.jsonl"
exec "$BENCH_ARMS_DIR/local-gh.sh" "\$@"
EOF
  chmod +x "$bindir/gh"
  : > "$ws.gh-ledger.jsonl"
  # Pre-seed the repo-visibility cache (templates/govern/lib/common.sh: govern::repo_is_public) so
  # the governor never calls `gh repo view` at all: the shim doesn't implement it, and a benchmark
  # repo is never public. The visibility cache is keyed on $GOVERNOR_DIR, not the run dir, so it
  # resolves to "$ws/governor/.repo-visibility" whether or not GOVERN_RUN_DIR is set.
  mkdir -p "$ws/governor"
  printf '%s private\n' "$repo" > "$ws/governor/.repo-visibility"
  printf '%s\n' "$bindir"
  return 0
}

# The sub-repo NAME the scaffolded workspace will use: the last path segment of the backlog's
# repo, minus any .git suffix. It has to be a name, not the clone URL, because the governor's
# ticket selector matches a ticket's `Repo:` field against the workspace's repo list. Seeding the
# URL there would make every ticket unselectable and the whole shiploop arm would record a cost of
# zero, which the rollup would happily read as a 100% saving.
bench::repo_slug() { # <backlog.jsonl> -> repo name
  local repo
  repo="$(jq -rs '.[0].repo' "$1")"
  repo="${repo%/}"
  repo="${repo##*/}"
  repo="${repo%.git}"
  printf '%s\n' "$repo"
  return 0
}

# Seed queue/tickets.md from a backlog.jsonl. Ticket N is the Nth line of the backlog, so the
# numbers the shiploop arm dispatches are stable and the body is byte-identical to the vanilla prompt's.
# Same omission as the prompts above: no verify_cmd, because it names the test file the golden
# patch will add at verify time.
bench::seed_tickets() { # <backlog.jsonl> <tickets.md> <repo-slug>
  local backlog="$1" out="$2" slug="$3"
  mkdir -p "$(dirname "$out")"
  {
    printf '# Tickets\n\n'
    jq -rs --arg slug "$slug" 'to_entries[] | "## #\(.key + 1) \(.value.title)\n\nSeverity: Medium\nRepo: \($slug)\n\n\(.value.body)\n"' "$backlog"
  } > "$out"
  return 0
}

# Scaffold a throwaway workspace with <workdir> as its single sub-repo. Uses the hub's real
# scaffold.sh so the loop under test is the shipped one, per the scaffold discipline in
# CLAUDE.md anti-pattern 13. Prints the workspace path.
bench::scaffold_workspace() { # <repo-workdir> <name> <repo-slug> -> workspace path
  local wd="$1" name="$2" repo="$3" ws
  ws="$BENCH_STATE_DIR/ws-$name"
  rm -rf "$ws"; mkdir -p "$ws"
  cp -R "$wd" "$ws/$repo"
  bash "$BENCH_ARMS_HUB/scaffold.sh" \
    --workspace-dir "$ws" \
    --pm npm \
    --org bench \
    --repos "$repo:3999:echo dev" \
    --merge-allowlist "$repo" \
    --worktree-base "$ws.wt" \
    --git-init \
    --yes >"$BENCH_STATE_DIR/scaffold-$name.log" 2>&1
  # A throwaway benchmark workspace has no reviewer, so GOVERN_AUTONOMY's scaffold-seeded default
  # (pr-only — templates/lib/workspace.sh) would leave every worker's fix stranded on an unmerged
  # branch forever: the tree bench/run.sh verifies never receives the work. bench::arm_shiploop
  # exports GOVERN_AUTONOMY=auto into the lane's own env, which (because workspace.sh seeds it as
  # `${GOVERN_AUTONOMY:-pr-only}`) wins over the file's default without editing the scaffold.
  # --merge-allowlist above is the OTHER half: GOVERN_AUTONOMY=auto alone still refuses to merge a
  # repo that isn't in GOVERN_MERGE_REPOS (govern::is_merge_repo), which an empty allowlist always
  # fails.
  # A real offline install would say this too — it is genuine operator guidance, not a benchmark
  # trick — so it goes in the scaffolded workspace's OWN CLAUDE.md, never worker-prompt.md.
  if [[ -f "$ws/CLAUDE.md" ]]; then
    printf '\n## Offline workspace\n\nThis workspace has no git remotes. Do not `git push` — it has\nnowhere to push to and will only waste turns. `gh pr create` (and every other `gh pr` step) works\ndirectly against your local branch.\n' >> "$ws/CLAUDE.md"
  fi
  printf '%s\n' "$ws"
  return 0
}

# ── the one place a `claude -p` is launched ─────────────────────────────────
# Every arm goes through here so the flag set, the env scrub, and the stream destination are
# identical across arms. Extra args (the resolved --max-turns / --forward-subagent-text) are
# appended verbatim. No --tools flag: the CLI's own default toolset, MCP included, is what BOTH
# arms get now — see the file header for why.
bench::spawn() { # <workdir> <prompt> <jsonl> [extra flags...]
  local wd="$1" prompt="$2" jsonl="$3"; shift 3
  mkdir -p "$(dirname "$jsonl")"
  # -u GH_TOKEN/GITHUB_TOKEN/GH_ENTERPRISE_TOKEN/GH_HOST/GH_REPO: offline guard, part 2 (run.sh's
  # bench::assert_offline covers git remotes; this covers the OTHER way a gh credential reaches a
  # real repo — an ambient token in the operator's own shell, which a bare `gh` call honors with no
  # remote and no stored login required. Scrubbed from every spawned session, both arms, always.
  # </dev/null: bench::spawn merges stderr into the same stream (section 6), and with no stdin the
  # CLI printed a "no stdin data received in 3s, proceeding without it" warning line ahead of the
  # first real JSON line, once per cell — a non-JSON line a reader must otherwise learn to skip.
  # Piping from /dev/null removes both the line and the 3-second stall.
  ( cd "$wd" && exec env \
      -u CLAUDE_CODE_ENTRYPOINT -u CLAUDECODE -u CLAUDE_CODE_SSE_PORT \
      -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID -u CLAUDE_EFFORT \
      -u GH_TOKEN -u GITHUB_TOKEN -u GH_ENTERPRISE_TOKEN -u GH_HOST -u GH_REPO \
      "$BENCH_CLAUDE_BIN" -p "$prompt" \
      --output-format stream-json --verbose \
      --setting-sources project,local \
      --permission-mode acceptEdits \
      "$@" ) </dev/null >"$jsonl" 2>&1 || true
  return 0
}
