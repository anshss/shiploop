#!/usr/bin/env bash
# bench/record.sh: turn a bench session's `"type":"result"` events into results.jsonl rows.
# Source, do not execute.
#
# Two row kinds land in the SAME results.jsonl:
#   kind:"session" is one per spawned claude session. The vanilla arm emits exactly one; the
#                    shiploop arm emits one per session the loop spawned (driver, scouts,
#                    workers, escalations), because section 2 says cost is everything the loop spends.
#   kind:"rollup"  is one per (backlog, arm, rep), folding that cell's session rows.
#
# Session field names are the ticket-history.jsonl names (spec section 5) so `govern-health.sh --bench`
# can fold either file: run, backlog, task, arm, rep, model, cli_version, status, resolved,
# turns, tokens{input,output,cacheRead,cacheCreation,total}, costUsd, usageSource, wallMs,
# verifyExit, startedAt. The rollup row adds sessions, ticketsCleared, costUsdTotal, tokensTotal.
#
# The `kind` key is an addition to the spec's field list: one file has to carry both shapes and
# discriminating on "does this row have a `sessions` key" is a trap the first null would spring.
# ticket-history rows simply have no `kind`, so nothing downstream breaks.
#
# Usage extraction is NOT reimplemented here. govern::stream_usage (templates/govern/lib/common.sh)
# is the authoritative parser for a result event: it reads the LAST `"type":"result"` line through
# the NUL-hole-safe grep, falls back to summing per-turn assistant usage when a session was hard
# killed before emitting a result, and never fabricates a cost. Reusing it is the point.
set -euo pipefail

BENCH_RECORD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH_HUB_ROOT="$(cd "$BENCH_RECORD_DIR/.." && pwd)"

# Defined here rather than in run.sh because arms.sh and the tests both source record.sh first.
bench::log() { printf '[bench] %s\n' "$*" >&2; return 0; }
bench::die() { printf '[bench] FATAL: %s\n' "$*" >&2; exit 1; }

# Load templates/govern/lib/common.sh for govern::stream_usage / govern::stream_grep.
#
# common.sh sources "$GOVERN_WS_ROOT/scripts/lib/workspace.sh" and derives GOVERNOR_DIR from it, so
# it cannot be sourced from a bare hub checkout. Seed a throwaway shim workspace (the same trick
# assert.sh's mk_ws_stub uses) under the bench state dir, point GOVERN_WS_ROOT at it, and source.
# The shim is never used for anything but satisfying that source: bench reads streams, it does not
# dispatch govern work.
bench::load_govern_lib() { # <state-dir>
  local state="$1"
  if [[ -n "${BENCH_GOVERN_LIB_LOADED:-}" ]]; then return 0; fi
  local shim="$state/.govern-shim"
  mkdir -p "$shim/scripts/lib"
  if [[ ! -f "$shim/scripts/lib/workspace.sh" ]]; then
    cat > "$shim/scripts/lib/workspace.sh" <<SHIM
#!/usr/bin/env bash
set -uo pipefail
META_ROOT="\${META_ROOT:-$shim}"
GITHUB_ORG="bench"
REPOS=(bench)
GOVERN_MERGE_REPOS=""
GOVERN_LOCAL_FIRST_REPOS=""
WORKTREE_BASE="$shim/wt"
wsp_is_merge_repo() { return 1; }
wsp_is_local_first_repo() { return 1; }
wsp_repo_slug() { printf '%s/%s' "\$GITHUB_ORG" "\$1"; }
wsp_repo_localdir() { printf '%s/%s' "\$META_ROOT" "\$1"; }
SHIM
  fi
  # common.sh runs `set -euo pipefail` and touches unset-ish globals; source it with GOVERN_WS_ROOT
  # pinned so nothing resolves against the caller's real workspace.
  GOVERN_WS_ROOT="$shim" GOVERN_EVENTS=0 source "$BENCH_HUB_ROOT/templates/govern/lib/common.sh"
  BENCH_GOVERN_LIB_LOADED=1
  return 0
}

# Emit ONE kind:"session" row for one session stream.
#
#   bench::session_row <jsonl> <run> <backlog> <task> <arm> <rep> <model> <cli_version> \
#                      <status> <resolved:true|false> <wallMs> <verifyExit> <startedAt>
#
# tokens/costUsd/usageSource come from govern::stream_usage; turns from the result event's
# num_turns. A stream with no result event yields costUsd null (never a fabricated 0) and, where
# the assistant events survived, recovered tokens with usageSource "assistant-partial".
bench::session_row() {
  local jsonl="$1" run="$2" backlog="$3" task="$4" arm="$5" rep="$6" model="$7" cli="$8"
  local status="$9" resolved="${10}" wallms="${11}" verifyexit="${12}" startedat="${13}"
  local usage turns
  usage="$(govern::stream_usage "$jsonl" 2>/dev/null || echo '{"tokens":null,"costUsd":null,"usageSource":"none"}')"
  [[ -n "$usage" ]] || usage='{"tokens":null,"costUsd":null,"usageSource":"none"}'
  turns="$(govern::stream_grep "$jsonl" '"type":"result"' 2>/dev/null | tail -1 \
    | jq -r '.num_turns // empty' 2>/dev/null || true)"
  [[ -n "$turns" ]] || turns=null
  jq -nc \
    --arg run "$run" --arg backlog "$backlog" --arg task "$task" --arg arm "$arm" \
    --argjson rep "$rep" --arg model "$model" --arg cli "$cli" --arg status "$status" \
    --argjson resolved "$resolved" --argjson turns "$turns" --argjson usage "$usage" \
    --argjson wallms "$wallms" --argjson verifyexit "$verifyexit" --argjson startedat "$startedat" \
    '{kind:"session", run:$run, backlog:$backlog, task:$task, arm:$arm, rep:$rep,
      model:$model, cli_version:$cli, status:$status, resolved:$resolved, turns:$turns,
      tokens:$usage.tokens, costUsd:$usage.costUsd, usageSource:$usage.usageSource,
      wallMs:$wallms, verifyExit:$verifyexit, startedAt:$startedat}'
  return 0
}

# Append every session row for one cell, reading each `*.jsonl` under <session-log-dir>.
# Streams are read in sorted filename order so a cell's rows are deterministic (fixtures and real
# runs alike name them 01-driver.jsonl, 02-worker-3.jsonl, ...).
#
#   bench::record_sessions <session-log-dir> <results.jsonl> <run> <backlog> <arm> <rep> \
#                          <model> <cli_version> <status> <verifyExit> <wallMs> <startedAt> \
#                          <resolvedCount> <ticketCount>
#
# `task` for the vanilla arm is the backlog name (one session covers the whole backlog); for the
# shiploop and vanilla-fresh arms it is the stream's basename minus its ordering prefix, which is
# the ticket id the loop was working. Both are recorded, never inferred later.
bench::record_sessions() {
  local logdir="$1" out="$2" run="$3" backlog="$4" arm="$5" rep="$6" model="$7" cli="$8"
  local status="$9" verifyexit="${10}" wallms="${11}" startedat="${12}"
  local resolved_json="false" f base task n=0
  if [[ "${13:-0}" -gt 0 && "${13:-0}" -eq "${14:-0}" ]]; then resolved_json="true"; fi
  shopt -s nullglob
  for f in "$logdir"/*.jsonl; do
    base="$(basename "$f" .jsonl)"
    case "$arm" in
      vanilla) task="$backlog" ;;
      *)       task="${base#*-}" ;;
    esac
    bench::session_row "$f" "$run" "$backlog" "$task" "$arm" "$rep" "$model" "$cli" \
      "$status" "$resolved_json" "$wallms" "$verifyexit" "$startedat" >> "$out"
    n=$((n+1))
  done
  shopt -u nullglob
  printf '%s\n' "$n"
  return 0
}

# Fold this cell's session rows into ONE kind:"rollup" row and append it.
#
#   bench::record_rollup <results.jsonl> <run> <backlog> <arm> <rep> <status> \
#                        <ticketsCleared> <ticketCount> <wallMs> <startedAt>
#
# Sums only over rows of THIS (run, backlog, arm, rep). costUsdTotal is null-safe: a session whose
# cost could not be read contributes nothing rather than poisoning the sum with a zero, and
# `costUsdSessions` records how many rows actually carried a cost so a partial fold is visible
# instead of silently understated.
bench::record_rollup() {
  local out="$1" run="$2" backlog="$3" arm="$4" rep="$5" status="$6"
  local cleared="$7" total="$8" wallms="$9" startedat="${10}"
  local row
  row="$(jq -sc \
    --arg run "$run" --arg backlog "$backlog" --arg arm "$arm" --argjson rep "$rep" \
    --arg status "$status" --argjson cleared "$cleared" --argjson total "$total" \
    --argjson wallms "$wallms" --argjson startedat "$startedat" \
    '[ .[] | select(.kind=="session" and .run==$run and .backlog==$backlog
                    and .arm==$arm and .rep==$rep) ] as $s
     | { kind:"rollup", run:$run, backlog:$backlog, task:$backlog, arm:$arm, rep:$rep,
         model:  ($s | map(.model)       | map(select(. != null and . != "")) | last // null),
         cli_version: ($s | map(.cli_version) | map(select(. != null and . != "")) | last // null),
         status:$status,
         resolved: ($cleared > 0 and $cleared == $total),
         turns: ($s | map(.turns // 0) | add // 0),
         tokens: ($s | map(.tokens) | map(select(. != null))
                  | reduce .[] as $t ({input:0,output:0,cacheRead:0,cacheCreation:0,total:0};
                      {input:(.input + ($t.input//0)), output:(.output + ($t.output//0)),
                       cacheRead:(.cacheRead + ($t.cacheRead//0)),
                       cacheCreation:(.cacheCreation + ($t.cacheCreation//0)),
                       total:(.total + ($t.total//0))})),
         costUsd: ($s | map(.costUsd) | map(select(. != null)) | if length==0 then null else add end),
         usageSource: "rollup",
         wallMs:$wallms, verifyExit:0, startedAt:$startedat,
         sessions: ($s | length),
         costUsdSessions: ($s | map(.costUsd) | map(select(. != null)) | length),
         ticketsCleared:$cleared, ticketsTotal:$total,
         costUsdTotal: ($s | map(.costUsd) | map(select(. != null)) | if length==0 then null else add end),
         tokensTotal: ($s | map(.tokens.total // 0) | add // 0) }' "$out" 2>/dev/null || true)"
  if [[ -z "$row" ]]; then return 1; fi
  printf '%s\n' "$row" >> "$out"
  return 0
}

# Did a session stream get cut off by its OWN per-session ceiling (--max-turns or
# --max-budget-usd), rather than finishing the work it was given? The claude CLI marks a
# limit-truncated session with a distinct `subtype` on its `"type":"result"` event
# (`error_max_turns` for the turn ceiling; the budget ceiling's own CLI-assigned subtype matches
# the same `error_max_*` shape). Detected by prefix, not an exact string, so either ceiling — or a
# future one with the same naming convention — is caught without a version compare.
#
# This matters because a truncated session clears fewer tickets for a reason that has nothing to
# do with the arm's competence: recording it as an ordinary "failed" cell would let a rail artifact
# read as a real result. bench::run_cell_capped is checked by run.sh BEFORE it derives cleared/total
# into a status, so a cell containing even one capped session is forced to "capped", never
# "resolved" or "failed".
bench::stream_hit_session_cap() { # <jsonl> -> rc 0 if this stream's session was cut off by its ceiling
  local jsonl="$1" subtype
  subtype="$(govern::stream_grep "$jsonl" '"type":"result"' 2>/dev/null | tail -1 \
    | jq -r '.subtype // empty' 2>/dev/null || true)"
  [[ "$subtype" == error_max_* ]]
}

# rc 0 if ANY *.jsonl stream under <session-log-dir> was cut off by its per-session ceiling.
bench::cell_hit_session_cap() { # <session-log-dir>
  local logdir="$1" f
  shopt -s nullglob
  for f in "$logdir"/*.jsonl; do
    if bench::stream_hit_session_cap "$f"; then
      shopt -u nullglob
      return 0
    fi
  done
  shopt -u nullglob
  return 1
}

# Total API-rate dollars recorded so far in <results.jsonl>, over kind:"session" rows only
# (folding rollups too would double count). Prints a decimal; "0" when nothing is readable.
# This is what BENCH_MAX_USD is compared against.
bench::spent_usd() { # <results.jsonl>
  local out="$1"
  if [[ ! -s "$out" ]]; then printf '0\n'; return 0; fi
  jq -s '[ .[] | select(.kind=="session") | .costUsd | select(. != null) ] | add // 0' "$out" \
    2>/dev/null || printf '0\n'
  return 0
}
