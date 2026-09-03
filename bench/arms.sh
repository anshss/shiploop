#!/usr/bin/env bash
# bench/arms.sh: the three arm shapes of the marketing benchmark (spec section 2). Source, do not execute.
#
#   vanilla        ONE `claude -p` session per backlog, headless default model, default tools, no
#                  hooks, no extra CLAUDE.md, in a fresh worktree of the pinned ref. The prompt is
#                  the backlog verbatim plus the one framing line. This is stock Claude Code used
#                  the way it is used out of the box: one session, one conversation, top to bottom.
#   vanilla-fresh  a fresh `claude -p` per ticket, sequential, same prompt shape. Private record
#                  only (section 2): if a teardown replays us with per-ticket sessions we already know the
#                  delta. Never published.
#   shiploop       the REAL governor loop (templates/govern/run-loop.sh) in a scaffolded throwaway
#                  workspace, over a queue/tickets.md seeded with the same backlog, defaults on.
#                  Every ticket is named in ONE dispatch, so the full loop runs: dependency gate,
#                  cross-driver re-verify, failure-streak breaker, escalation. A per-ticket
#                  fan-out would bypass all of them and measure something that is not the product
#                  (CLAUDE.md anti-pattern 15).
#
# Ticket text is byte-identical across arms. The treatment arm gets no hints: asymmetric input is
# the first thing a replay finds, and it voids even true numbers.
#
# Neither arm gets WebFetch or WebSearch, so nothing in a run can reach the upstream PRs the
# backlog was mined from (section 3). Both arms express that through the SAME already-gated `--tools`
# mechanism: the vanilla session passes the governor's default tool list minus the two web tools,
# and the shiploop arm sets GOVERN_WORKER_TOOLS to the same list so its workers inherit it.
set -euo pipefail

BENCH_ARMS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH_ARMS_HUB="$(cd "$BENCH_ARMS_DIR/.." && pwd)"

# Tool list shared by both arms: the governor's measured default minus WebFetch and WebSearch.
BENCH_TOOLS="Bash,Read,Edit,Write,Glob,Grep,NotebookEdit,TodoWrite,Agent,Task,ToolSearch,Monitor,ScheduleWakeup,SendMessage,TaskCreate,TaskGet,TaskList,TaskOutput,TaskStop,TaskUpdate"

# ── --max-turns capability probe ────────────────────────────────────────────
# CLAUDE.md anti-pattern 12: never put a new `claude` flag on a dispatch path unguarded. The fleet's
# CLI is not ours, and an unknown flag makes `claude -p` die at argument parsing, which the failure
# classifier reports as a generic `failed`. A marketing benchmark that silently fails is worse than
# an honest one.
#
# The probe itself is NOT reimplemented here. `govern::claude_supports_max_turns` lives in
# templates/govern/lib/common.sh beside the --tools and --exclude-dynamic-system-prompt-sections
# probes: a cached, bounded `--help` grep, never a version compare, with a
# `_GOVERN_MAXTURNS_SUPPORTED` pre-seed test seam. Both arms need the same answer, and the shiploop
# arm's workers reach it through spawn-worker.sh's GOVERN_WORKER_MAX_TURNS, so one probe is the only
# way the two arms can be guaranteed to agree.
#
#   BENCH_MAX_TURNS_FLAG=0        kill switch: never pass --max-turns
#   _GOVERN_MAXTURNS_SUPPORTED    pre-seed 1|0 to skip the probe entirely (test seam)
#
# Unsupported CLI is a HARD STOP, not a silent degrade: BENCH_MAX_TURNS is an always-on rail (spec
# section 5) and dropping it would spawn an uncapped, spend-bearing session.
# `BENCH_ALLOW_UNCAPPED_TURNS=1` is the deliberate operator override.
bench::claude_supports_max_turns() { # <claude_bin> -> rc 0 supported, 1 not
  govern::claude_supports_max_turns "$1"
}

# Sets the global `bench_max_turns_flag` (empty, or `--max-turns N`). Always returns 0; the caller
# decides what an empty flag means, because the two arms differ (a vanilla session refuses to run
# uncapped, a shiploop worker still has GOVERN_WORKER_TIMEOUT under it).
bench::resolve_max_turns_flag() { # <claude_bin> <turns>
  local bin="$1" turns="$2"
  bench_max_turns_flag=""
  if [[ "${BENCH_MAX_TURNS_FLAG:-1}" == "0" ]]; then
    bench::log "BENCH_MAX_TURNS_FLAG=0, omitting --max-turns (turn ceiling disabled by operator)"
    return 0
  fi
  if bench::claude_supports_max_turns "$bin"; then
    bench_max_turns_flag="--max-turns $turns"
  else
    bench::log "claude CLI ($bin) does not support --max-turns, so the BENCH_MAX_TURNS rail cannot be enforced"
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

# ── vanilla ─────────────────────────────────────────────────────────────────
# ONE session for the whole backlog. Writes exactly one stream: 01-<backlog>.jsonl.
bench::arm_vanilla() { # <workdir> <backlog.jsonl> <logdir> <backlog-name>
  local wd="$1" backlog="$2" logdir="$3" name="$4"
  local prompt jsonl
  jsonl="$logdir/01-$name.jsonl"
  prompt="$(bench::backlog_prompt "$backlog")"
  bench::resolve_max_turns_flag "$BENCH_CLAUDE_BIN" "$BENCH_TURNS_VANILLA"
  bench::require_turn_ceiling vanilla
  bench::spawn "$wd" "$prompt" "$jsonl" ${bench_max_turns_flag:-}
  return 0
}

# ── vanilla-fresh ───────────────────────────────────────────────────────────
# A fresh session per ticket, sequential, same worktree so later tickets see earlier commits.
# Streams are NN-<ticket-id>.jsonl in dispatch order.
bench::arm_vanilla_fresh() { # <workdir> <backlog.jsonl> <logdir> <backlog-name>
  local wd="$1" backlog="$2" logdir="$3"
  local i=0 id prompt jsonl
  bench::resolve_max_turns_flag "$BENCH_CLAUDE_BIN" "$BENCH_TURNS_WORKER"
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

# ── shiploop ────────────────────────────────────────────────────────────────
# Scaffold a throwaway workspace around the SAME checkout the vanilla arm gets, seed
# queue/tickets.md from the backlog, and hand every ticket number to the real run-loop.sh in one
# named dispatch. Nothing here reimplements the loop; the gates being measured are the product.
bench::arm_shiploop() { # <workdir> <backlog.jsonl> <logdir> <backlog-name>
  local wd="$1" backlog="$2" logdir="$3" name="$4"
  local ws nums slug
  slug="$(bench::repo_slug "$backlog")"
  ws="$(bench::scaffold_workspace "$wd" "$name" "$slug")"
  bench::seed_tickets "$backlog" "$ws/queue/tickets.md" "$slug"
  nums="$(jq -rs 'to_entries | map((.key + 1) | tostring) | join(" ")' "$backlog")"
  # Same rails as the vanilla arm, expressed through the governor's own knobs so the loop under
  # measurement is the shipped one:
  #   GOVERN_WORKER_TOOLS      the same web-free tool list, gated by the same --tools probe
  #   GOVERN_WORKER_MAX_TURNS  the per-worker turn ceiling; spawn-worker resolves the flag behind
  #                            govern::claude_supports_max_turns, the same probe checked here
  # The ceiling is checked HERE too, so an arm that cannot enforce it refuses to run rather than
  # spending uncapped and reporting a number nothing bounded.
  bench::resolve_max_turns_flag "$BENCH_CLAUDE_BIN" "$BENCH_TURNS_WORKER"
  bench::require_turn_ceiling shiploop
  (
    cd "$ws"
    GOVERN_WS_ROOT="$ws" \
    GOVERN_WORKER_TOOLS="$BENCH_TOOLS" \
    GOVERN_WORKER_MAX_TURNS="$BENCH_TURNS_WORKER" \
    GOVERN_MAX_TICKETS="$(jq -s 'length' "$backlog")" \
    bash "$ws/scripts/govern/run-loop.sh" --serial $nums
  ) >"$logdir/00-driver.log" 2>&1 || true
  bench::collect_govern_streams "$ws" "$logdir"
  return 0
}

# Copy every session stream the loop produced into the bench log dir, in dispatch order, named
# NN-<ticket>.jsonl so record.sh derives `task` from the filename. A run that spawned scouts and
# escalations copies those too: section 2 says cost is EVERYTHING the loop spends.
bench::collect_govern_streams() { # <workspace> <logdir>
  local ws="$1" logdir="$2" i=0 f rel tag
  # `find`, not a `**` glob: globstar is bash 4+ and macOS ships bash 3.2, where `**` would
  # silently match only one level and quietly drop every worker stream from the cost total.
  [[ -d "$ws/logs/govern" ]] || return 0
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    i=$((i+1))
    rel="${f#"$ws"/logs/govern/}"
    tag="$(printf '%s' "$rel" | tr '/' '-' | sed 's/\.jsonl$//')"
    cp "$f" "$(printf '%s/%02d-%s.jsonl' "$logdir" "$i" "$tag")"
  done < <(find "$ws/logs/govern" -name '*.jsonl' -type f | LC_ALL=C sort)
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
# numbers handed to run-loop.sh are stable and the body is byte-identical to the vanilla prompt's.
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
    --merge-allowlist "" \
    --worktree-base "$ws.wt" \
    --git-init \
    --yes >"$BENCH_STATE_DIR/scaffold-$name.log" 2>&1
  printf '%s\n' "$ws"
  return 0
}

# ── the one place a `claude -p` is launched ─────────────────────────────────
# Every arm goes through here so the flag set, the env scrub, and the stream destination are
# identical across arms. Extra args (the resolved --max-turns) are appended verbatim.
bench::spawn() { # <workdir> <prompt> <jsonl> [extra flags...]
  local wd="$1" prompt="$2" jsonl="$3"; shift 3
  local tools_flag=""
  if govern::claude_supports_tools_flag "$BENCH_CLAUDE_BIN"; then
    tools_flag="--tools $BENCH_TOOLS"
  else
    bench::die "claude CLI ($BENCH_CLAUDE_BIN) does not support --tools, so WebFetch/WebSearch cannot be excluded. Spec section 3 forbids running an arm that can reach the upstream PRs."
  fi
  mkdir -p "$(dirname "$jsonl")"
  ( cd "$wd" && exec env \
      -u CLAUDE_CODE_ENTRYPOINT -u CLAUDECODE -u CLAUDE_CODE_SSE_PORT \
      -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID -u CLAUDE_EFFORT \
      "$BENCH_CLAUDE_BIN" -p "$prompt" \
      --output-format stream-json --verbose \
      --setting-sources project,local \
      $tools_flag \
      --permission-mode acceptEdits \
      "$@" ) >"$jsonl" 2>&1 || true
  return 0
}
