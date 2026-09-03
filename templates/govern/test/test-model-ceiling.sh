#!/usr/bin/env bash
# Locks in the model ceiling: a session may never spawn a process at a tier ABOVE
# max(opus, its own model).
#
# Opus is the FLOOR of that ceiling, not the ceiling itself, which is what keeps the existing
# cheap-floor/escalate-once rail intact: a sonnet (or haiku, or undetectable) session still buys opus
# for a retry, exactly as before. What the rail forbids is a session buying a tier it does not itself
# run at, so only a session ABOVE opus can dispatch above opus.
#
# Three layers are covered here:
#   1. govern::model_rank: the ladder now has to order a bare alias against a full model id, incl.
#      versions within a family and the dated `claude-haiku-4-5-20251001` shape.
#   2. govern::model_ceiling / govern::model_clamp: the policy itself, plus the kill switch.
#   3. spawn-worker.sh: the integration check that the clamp actually reaches the assembled
#      `--model`, via the GOVERN_SPAWN_DRY_RUN observation seam (no auth, no claude binary).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
SPAWN="$DIR/../spawn-worker.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 77; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mk_ws_stub "$TMP"
mkdir -p "$TMP/governor" "$TMP/wt"

# common.sh is sourced ONCE here and the session-model memo is reset per case below. Every case that
# changes the session model must clear the latch, or it would read the previous case's answer.
source "$DIR/../lib/common.sh"
sess() { # <session-model>: repoint the ceiling and drop the memo
  export GOVERN_SESSION_MODEL="$1"
  _GOVERN_SESSION_MODEL=""; _GOVERN_SESSION_MODEL_RESOLVED=0
}

# ── 1. the ladder ───────────────────────────────────────────────────────────
rank() { govern::model_rank "$1"; }
lt() { # a b msg: assert rank(a) < rank(b)
  if [[ "$(rank "$1")" -lt "$(rank "$2")" ]]; then printf 'ok   - %s\n' "$3"
  else printf 'FAIL - %s\n       rank(%s)=%s is NOT < rank(%s)=%s\n' "$3" "$1" "$(rank "$1")" "$2" "$(rank "$2")"
       ASSERT_FAILS=$((ASSERT_FAILS+1)); fi
}
lt haiku sonnet          "1. haiku < sonnet"
lt sonnet opus           "1. sonnet < opus"
lt opus fable            "1. opus < fable (a family above opus exists and outranks it)"
lt claude-opus-4 claude-opus-5          "1. opus-4 < opus-5 (version orders within a family)"
lt claude-fable-5 claude-fable-5-1      "1. fable-5 < fable-5-1 (minor orders within a version)"
lt opus claude-opus-5    "1. the bare alias ranks BELOW any versioned member of its family"
lt claude-sonnet-5 opus  "1. family dominates version: sonnet-5 still ranks below bare opus"
assert_eq "$(rank 'claude-opus-5[1m]')" "$(rank claude-opus-5)" \
  "1. a [1m] context-window suffix does not change the rank"
assert_eq "$(rank claude-haiku-4-5-20251001)" "$(rank claude-haiku-4-5)" \
  "1. the trailing build date in claude-haiku-4-5-20251001 is not read as version digits"
lt claude-haiku-4-5-20251001 sonnet \
  "1. a dated haiku id cannot climb out of its family (the date is not a version)"
lt claude-opus-4-20250514 claude-opus-5 \
  "1. a date sitting where a minor would be cannot outrank a real point release"
assert_eq "$(rank gpt-nano)" "0" "1. an unknown model ranks 0"
assert_eq "$(rank '')" "0" "1. an empty model ranks 0"

# ── 2. the ceiling ──────────────────────────────────────────────────────────
for s in haiku sonnet opus claude-opus-5; do
  sess "$s"
  assert_eq "$(govern::model_ceiling)" "opus" \
    "2. session=$s → ceiling is opus (a cheap session may still buy opus, as before)"
done
# The opus-5 case above is the one worth stating twice: `claude-opus-5` OUTRANKS the bare `opus`
# alias on the ladder, but it is still the opus FAMILY, and the ceiling is expressed as the canonical
# alias for anything at or below opus so the value handed to --model stays a plain tier name.

# Genuinely undetectable: every resolution source empty at once. `env -u` rather than `unset`, so
# the ambient session driving this suite (which really does have a transcript on disk) cannot leak
# into the answer and make this case pass for the wrong reason.
assert_eq "$(env -u GOVERN_SESSION_MODEL -u ANTHROPIC_MODEL -u CLAUDE_CODE_SESSION_ID \
              bash -c 'source "$1"/../lib/common.sh; govern::model_ceiling' _ "$DIR")" "opus" \
  "2. UNDETECTABLE session → ceiling is opus (fail-safe direction, never permissive)"

sess claude-fable-5
assert_eq "$(govern::model_ceiling)" "claude-fable-5" \
  "2. a session above opus raises its own ceiling to itself, verbatim"

# ── 3. the clamp ────────────────────────────────────────────────────────────
sess sonnet
assert_eq "$(govern::model_clamp claude-fable-5 2>/dev/null)" "opus" \
  "3. a sonnet session asking for fable-5 is clamped to opus"
assert_eq "$(govern::model_clamp opus 2>/dev/null)" "opus" \
  "3. clamp is a no-op at the ceiling"
assert_eq "$(govern::model_clamp haiku 2>/dev/null)" "haiku" \
  "3. clamp is a no-op below the ceiling"
assert_eq "$(govern::model_clamp '' 2>/dev/null)" "" \
  "3. an empty tier passes through (the clamp never invents a model the caller did not ask for)"
assert_eq "$(govern::model_clamp gpt-nano 2>/dev/null)" "gpt-nano" \
  "3. an unrankable tier passes through untouched"
assert_contains "$(govern::model_clamp claude-fable-5 2>&1 >/dev/null)" "model ceiling:" \
  "3. a clamp that LOWERS the tier is logged, never silent"

sess claude-opus-5
assert_eq "$(govern::model_clamp 'claude-opus-5[1m]' 2>/dev/null)" "claude-opus-5[1m]" \
  "3. an opus-family ceiling admits the whole opus family: a versioned/[1m] opus is NOT rewritten"
assert_eq "$(govern::model_clamp claude-fable-5 2>/dev/null)" "opus" \
  "3. that same opus-5 session still cannot reach a family above opus"

sess claude-fable-5
assert_eq "$(govern::model_clamp claude-fable-5-1 2>/dev/null)" "claude-fable-5" \
  "3. a fable-5 session clamps a fable-5-1 request down to its own model"
assert_eq "$(govern::model_clamp claude-fable-5 2>/dev/null)" "claude-fable-5" \
  "3. that same session may run AT its own model"
assert_eq "$(govern::model_clamp opus 2>/dev/null)" "opus" \
  "3. and may still dispatch below it"

sess sonnet
assert_eq "$(GOVERN_MODEL_CEILING=0 govern::model_clamp claude-fable-5 2>/dev/null)" "claude-fable-5" \
  "3. GOVERN_MODEL_CEILING=0 disables the rail entirely (pass-through)"

# ── 4. integration: the clamp reaches spawn-worker's assembled --model ──────
cat > "$TMP/tickets.md" <<'EOF'
## #201 - a ticket to size
**Severity:** Medium
Observed: standard ticket.
Done when: PR opens.

---
EOF
printf 'DOCTRINE\n' > "$TMP/governor/preferences.md"
printf 'PROMPT {{TICKET_BLOCK}} REPORT={{REPORT_PATH}}\n' > "$TMP/governor/worker-prompt.md"

dry() { # <session-model> <GOVERN_WORKER_MODEL> [extra env assignments...]
  local smodel="$1" wmodel="$2"; shift 2
  env GOVERN_TICKETS_FILE="$TMP/tickets.md" \
      GOVERN_PREFERENCES_FILE="$TMP/governor/preferences.md" \
      GOVERN_WORKER_PROMPT_FILE="$TMP/governor/worker-prompt.md" \
      GOVERN_LOG_ROOT="$TMP/logs-dry" \
      GOVERN_SESSION_MODEL="$smodel" \
      GOVERN_WORKER_MODEL="$wmodel" \
      GOVERN_SPAWN_DRY_RUN=1 \
      "$@" "$SPAWN" 201 2>/dev/null
}

# An operator raising the floor above what the session runs at is the exact hole this closes: without
# the clamp the dispatch below would spawn a fable worker from a sonnet driver.
out="$(dry sonnet claude-fable-5)"
assert_eq "$(printf '%s' "$out" | jq -r '.model')" "opus" \
  "4. spawn-worker clamps a fable floor down to opus for a sonnet session"
assert_contains "$(printf '%s' "$out" | jq -r '.model_source')" "clamped to opus" \
  "4. the clamp is recorded in model_source, so the dispatch record explains the lower tier"

out="$(dry claude-fable-5 claude-fable-5)"
assert_eq "$(printf '%s' "$out" | jq -r '.model')" "claude-fable-5" \
  "4. a fable-5 session may spawn a fable-5 worker (the ceiling is its own model)"
assert_not_contains "$(printf '%s' "$out" | jq -r '.model_source')" "clamped" \
  "4. no clamp marker when nothing was clamped"

out="$(dry sonnet sonnet)"
assert_eq "$(printf '%s' "$out" | jq -r '.model')" "sonnet" \
  "4. the ordinary sonnet-floor dispatch is untouched by the rail"

# The RETRY rail is the other path that picks a tier, and it picks the highest one the harness ever
# chooses on its own, so it is clamped at the same choke point, not at the branch.
out="$(dry sonnet sonnet GOVERN_WORKER_ESCALATION_MODEL=claude-fable-5 GOVERN_SPAWN_FORCE_RETRY=1)"
assert_eq "$(printf '%s' "$out" | jq -r '.model')" "opus" \
  "4. the retry escalation ceiling is clamped too (escalation to fable-5 lands on opus)"
assert_eq "$(printf '%s' "$out" | jq -r '.is_retry')" "1" \
  "4. that case really did take the retry path"

out="$(dry sonnet claude-fable-5 GOVERN_MODEL_CEILING=0)"
assert_eq "$(printf '%s' "$out" | jq -r '.model')" "claude-fable-5" \
  "4. GOVERN_MODEL_CEILING=0 restores the unclamped dispatch end to end"

assert_done
