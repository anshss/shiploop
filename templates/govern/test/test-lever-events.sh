#!/usr/bin/env bash
# bench/LEVER-EVENTS.md instrumentation (spec 4b): the governor-side emitter half.
#
# A reader built against the SAME contract file attributes levers from a run's
# logs/govern/<run>/lever-events.jsonl: watchdog-kill, resume, scripted-action, escalation.
# This proves the EMITTER side: govern::emit_lever_event's own contract (off by default, well-formed
# JSON, never aborts the caller even on a write failure). A prior "B" section drove the emitter
# through a real call site (watchdog-kill/resume via spawn-worker.sh, scripted-action via
# deterministic-apply.sh); both scripts were purged in the same merge, so no real call site is
# exercised from this file any more. watchdog-kill still fires in production, from the
# templates/hooks/agent-watchdog-guard.sh PreToolUse hook (covered by test-agent-watchdog-guard.sh,
# not here), while resume and scripted-action have no emitter left anywhere in the tree. watchdog-
# kill's and resume's schemas stay documented in bench/LEVER-EVENTS.md because historical logs
# still carry those rows; scripted-action's and escalation's entries were dropped from that doc
# outright when their last emitter went, so this file only tests the emitter in isolation now.
#
# Covered:
#   A. the emitter in isolation
#     1. GOVERN_LEVER_EVENTS=0 (explicit) → no-op, no file created (the kill switch)
#     1b. GOVERN_LEVER_EVENTS genuinely UNSET (env -u, not a test override) → an event IS written:
#         the runtime default is ON. test/assert.sh keeps the whole SUITE pinned to 0 regardless
#         (fixtures must not accumulate event files), which is what case 1 above actually exercises.
#     2/3/4/5. each of the four event shapes, called directly → well-formed JSON, correct field
#        types (ticket int|null, ts int, session string, tier string|null, event-specific extras)
#     6. string escaping (a reason containing a quote/backslash) round-trips through jq intact
#     7. a write failure (unwritable target dir) never aborts the caller (`set -e` survives)
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
COMMON="$DIR/../lib/common.sh"

command -v jq  >/dev/null 2>&1 || { echo "SKIP: jq not installed";  exit 77; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not installed"; exit 77; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# ══════════════════════════════════════════════════════════════════════════════════════════════
# A. the emitter in isolation: source common.sh directly, no spawn overhead
# ══════════════════════════════════════════════════════════════════════════════════════════════
U="$T/unit"; mkdir -p "$U"
mk_ws_stub "$U"

# emit <lever-events-file> <GOVERN_LEVER_EVENTS value> <emit_lever_event args...> -> stdout+stderr
emit() {
  local f="$1" on="$2"; shift 2
  ( GOVERN_WS_ROOT="$U" GOVERN_LOG_ROOT="$U/logs" GOVERN_LEVER_EVENTS="$on" GOVERN_LEVER_EVENTS_FILE="$f" \
    bash -c 'source "$1"; shift; govern::emit_lever_event "$@"; echo EMITTER-RETURNED-0' \
    _ "$COMMON" "$@" )
}

# emit_default <lever-events-file> <emit_lever_event args...> -> stdout+stderr, with
# GOVERN_LEVER_EVENTS genuinely UNSET (env -u, not merely un-passed): assert.sh exports it as 0 for
# the whole suite, so without the explicit -u this subshell would inherit that pin and prove
# nothing about the actual runtime default. Same idiom test-model-ceiling.sh already uses for
# "genuinely undetectable".
emit_default() {
  local f="$1"; shift
  ( env -u GOVERN_LEVER_EVENTS GOVERN_WS_ROOT="$U" GOVERN_LOG_ROOT="$U/logs" GOVERN_LEVER_EVENTS_FILE="$f" \
    bash -c 'source "$1"; shift; govern::emit_lever_event "$@"; echo EMITTER-RETURNED-0' \
    _ "$COMMON" "$@" )
}

# ── 1. explicit kill switch: GOVERN_LEVER_EVENTS=0 → no-op, no file ─────────────────────────────
F1="$U/off.jsonl"
out1="$(emit "$F1" 0 watchdog-kill 7 worker sonnet ctxTokens=100 turns=5 reason=x)"
assert_contains "$out1" "EMITTER-RETURNED-0" "GOVERN_LEVER_EVENTS=0 → the emitter returns 0 (never aborts the caller)"
[[ -f "$F1" ]] && created=yes || created=no
assert_eq "$created" "no" "GOVERN_LEVER_EVENTS=0 (explicit) → no lever-events file is even created"

# ── 1b. the RUNTIME default is ON: genuinely unset → an event IS written ────────────────────────
F1b="$U/default-on.jsonl"
out1b="$(emit_default "$F1b" watchdog-kill 7 worker sonnet ctxTokens=100 turns=5 reason=x)"
assert_contains "$out1b" "EMITTER-RETURNED-0" "GOVERN_LEVER_EVENTS genuinely unset → the emitter still returns 0"
[[ -f "$F1b" ]] && created1b=yes || created1b=no
assert_eq "$created1b" "yes" "GOVERN_LEVER_EVENTS genuinely unset → the runtime default is ON, a file IS created"
assert_eq "$(jq -r '.event' "$F1b" 2>/dev/null)" "watchdog-kill" \
  "GOVERN_LEVER_EVENTS genuinely unset → the written line is a real, well-formed event"

# ── 2. watchdog-kill: shape + types ─────────────────────────────────────────────────────────────
F2="$U/wd.jsonl"
emit "$F2" 1 watchdog-kill 7 worker sonnet ctxTokens=184320 turns=97 "reason=context-cap" >/dev/null
line2="$(cat "$F2")"
assert_eq "$(jq -e . >/dev/null 2>&1 <<<"$line2" && echo valid || echo invalid)" "valid" "watchdog-kill line is well-formed JSON"
assert_eq "$(jq -r '.event' <<<"$line2")" "watchdog-kill" "event name"
assert_eq "$(jq -r '.ticket' <<<"$line2")" "7" "ticket is a bare int"
assert_eq "$(jq -r '(.ticket|type)' <<<"$line2")" "number" "ticket type is number, not string"
assert_eq "$(jq -r '.session' <<<"$line2")" "worker" "session"
assert_eq "$(jq -r '.tier' <<<"$line2")" "sonnet" "tier"
assert_eq "$(jq -r '.ctxTokens' <<<"$line2")" "184320" "ctxTokens"
assert_eq "$(jq -r '(.ctxTokens|type)' <<<"$line2")" "number" "ctxTokens type is number"
assert_eq "$(jq -r '.turns' <<<"$line2")" "97" "turns"
assert_eq "$(jq -r '.reason' <<<"$line2")" "context-cap" "reason"
assert_eq "$(jq -r '(.ts|type)' <<<"$line2")" "number" "ts is a number (unix seconds)"

# ── 3. resume: null ticket path + checkpoint/freshStart shape ──────────────────────────────────
F3="$U/resume.jsonl"
emit "$F3" 1 resume - worker opus checkpointTokens=12400 freshStartTokens=86100 >/dev/null
line3="$(cat "$F3")"
assert_eq "$(jq -r '.event' <<<"$line3")" "resume" "event name"
assert_eq "$(jq -r '.ticket' <<<"$line3")" "null" "\"-\" ticket → JSON null, not the string \"-\""
assert_eq "$(jq -r '.checkpointTokens' <<<"$line3")" "12400" "checkpointTokens"
assert_eq "$(jq -r '.freshStartTokens' <<<"$line3")" "86100" "freshStartTokens"

# ── 4. scripted-action: null tier + orchestration session ──────────────────────────────────────
F4="$U/scripted.jsonl"
emit "$F4" 1 scripted-action 108 driver - class=version-bump >/dev/null
line4="$(cat "$F4")"
assert_eq "$(jq -r '.session' <<<"$line4")" "driver" "session=driver for a code-only resolution"
assert_eq "$(jq -r '.tier' <<<"$line4")" "null" "\"-\" tier → JSON null"
assert_eq "$(jq -r '.class' <<<"$line4")" "version-bump" "class"

# ── 5. escalation: carries failedTier instead of tier ───────────────────────────────────────────
F5="$U/escalation.jsonl"
emit "$F5" 1 escalation 108 worker - failedTier=sonnet failedTokens=240500 >/dev/null
line5="$(cat "$F5")"
assert_eq "$(jq -r '.tier' <<<"$line5")" "null" "escalation carries tier:null …"
assert_eq "$(jq -r '.failedTier' <<<"$line5")" "sonnet" "… and failedTier instead"
assert_eq "$(jq -r '.failedTokens' <<<"$line5")" "240500" "failedTokens"
assert_eq "$(jq -r '(.failedTokens|type)' <<<"$line5")" "number" "failedTokens type is number"

# ── 6. string escaping round-trips ──────────────────────────────────────────────────────────────
F6="$U/escape.jsonl"
emit "$F6" 1 watchdog-kill 7 worker sonnet ctxTokens=1 turns=1 'reason=STALL: a "quoted" signature \and a backslash' >/dev/null
line6="$(cat "$F6")"
assert_eq "$(jq -e . >/dev/null 2>&1 <<<"$line6" && echo valid || echo invalid)" "valid" "an embedded quote/backslash in a free-text field still produces valid JSON"
assert_eq "$(jq -r '.reason' <<<"$line6")" 'STALL: a "quoted" signature \and a backslash' "the escaped value round-trips byte-for-byte through jq"

# ── 7. a write failure never aborts the caller ──────────────────────────────────────────────────
RO="$U/readonly"; mkdir -p "$RO"; chmod 0555 "$RO"
if ( : > "$RO/sub/probe" ) 2>/dev/null; then
  echo "SKIP: sandbox permits writes under a chmod 0555 dir (likely running as root): case 7 not exercisable" >&2
else
  out7="$(emit "$RO/sub/lever-events.jsonl" 1 watchdog-kill 7 worker sonnet ctxTokens=1 turns=1 reason=x)"
  assert_contains "$out7" "EMITTER-RETURNED-0" "an unwritable target dir (mkdir -p fails, append fails) still returns 0: the caller survives under set -e"
fi
chmod 0755 "$RO"

assert_done
