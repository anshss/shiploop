#!/usr/bin/env bash
# bench/LEVER-EVENTS.md instrumentation (spec 4b): the governor-side emitter half.
#
# bench/replay.mjs (built against the SAME contract file, in parallel) attributes four levers from
# a run's logs/govern/<run>/lever-events.jsonl: watchdog-kill, resume, scripted-action, escalation.
# This proves the EMITTER side: govern::emit_lever_event's own contract (off by default, well-formed
# JSON, never aborts the caller even on a write failure), then each of the four real call sites,
# present when the lever genuinely fires, absent when it does not.
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
#   B. the real call sites, through spawn-worker.sh and deterministic-apply.sh
#     8.  watchdog-kill PRESENT: a hard wall-clock kill
#     8b. the same real call site with GOVERN_LEVER_EVENTS genuinely unset: the runtime default
#         reaches production dispatch, not just the isolated emitter in case 1b
#     9.  watchdog-kill ABSENT: same ticket, resolved normally (no kill, no stray event)
#     10. resume PRESENT / escalation ABSENT: automatic tier escalation was removed, so the
#         `escalation` lever has no emitter left; `resume` is unaffected
#     11. escalation ABSENT on an infra retry too (the same tier is re-bet, as it always was)
#     12. scripted-action PRESENT: deterministic-apply.sh resolves with zero model turns
#     13. scripted-action ABSENT: the kill switch is off, the ticket falls through untouched
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
SPAWN="$DIR/../spawn-worker.sh"
APPLY="$DIR/../deterministic-apply.sh"
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
# nothing about the actual runtime default. Same idiom test-model-ceiling.sh and
# test-driver-model-stamp.sh already use for "genuinely undetectable".
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

# ══════════════════════════════════════════════════════════════════════════════════════════════
# B. the real call sites
# ══════════════════════════════════════════════════════════════════════════════════════════════
# Re-stub the workspace at $T: section A's mk_ws_stub "$U" left GOVERN_WS_ROOT (and so
# $WORKTREE_BASE, which the MODEL_IS_RETRY pre-check in spawn-worker.sh reads) pointed at $U. Without
# this, every "$T/wt/ticket-N already exists" retry setup below would go undetected.
mk_ws_stub "$T"
mkdir -p "$T/governor" "$T/wt"
cat > "$T/tickets.md" <<'EOF'
## #7: sample ticket
**Severity:** Medium: test.
Observed: thing is broken.
---
EOF
printf 'DOC\n' > "$T/governor/preferences.md"
printf 'PROMPT {{TICKET_BLOCK}} REPORT={{REPORT_PATH}}\n' > "$T/governor/worker-prompt.md"

cat > "$T/fake-worktree.sh" <<EOF
#!/usr/bin/env bash
mkdir -p "$T/wt/\$1"; echo "$T/wt/\$1"
EOF
chmod +x "$T/fake-worktree.sh"

run_spawn() { # <logroot> <claude-bin> [extra env assignments...]
  local logroot="$1" bin="$2"; shift 2
  env \
    GOVERN_LEVER_EVENTS=1 \
    GOVERN_TICKETS_FILE="$T/tickets.md" \
    GOVERN_PREFERENCES_FILE="$T/governor/preferences.md" \
    GOVERN_WORKER_PROMPT_FILE="$T/governor/worker-prompt.md" \
    GOVERN_LOG_ROOT="$logroot" \
    GOVERN_WORKTREE_CMD="$T/fake-worktree.sh" \
    GOVERN_CLAUDE_BIN="$bin" \
    "$@" \
    "$SPAWN" 7 </dev/null
}

# Same as run_spawn, but GOVERN_LEVER_EVENTS genuinely UNSET (env -u) rather than pinned to 1: the
# real call site, not just the emitter, must fire on the bare runtime default.
run_spawn_default() { # <logroot> <claude-bin> [extra env assignments...]
  local logroot="$1" bin="$2"; shift 2
  env -u GOVERN_LEVER_EVENTS \
    GOVERN_TICKETS_FILE="$T/tickets.md" \
    GOVERN_PREFERENCES_FILE="$T/governor/preferences.md" \
    GOVERN_WORKER_PROMPT_FILE="$T/governor/worker-prompt.md" \
    GOVERN_LOG_ROOT="$logroot" \
    GOVERN_WORKTREE_CMD="$T/fake-worktree.sh" \
    GOVERN_CLAUDE_BIN="$bin" \
    "$@" \
    "$SPAWN" 7 </dev/null
}

# ── 8. watchdog-kill PRESENT: wall-clock timeout ────────────────────────────────────────────────
cat > "$T/fake-claude-hang.sh" <<'EOF'
#!/usr/bin/env bash
printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/a"}}],"usage":{"input_tokens":50,"output_tokens":10}}}\n'
sleep 60
EOF
chmod +x "$T/fake-claude-hang.sh"
out8="$(run_spawn "$T/logs8" "$T/fake-claude-hang.sh" GOVERN_WORKER_TIMEOUT=2)"
assert_eq "$(jq -r '.status' <<<"$out8")" "timeout" "sanity: the wall-clock watchdog actually killed this attempt"
LE8="$T/logs8/lever-events.jsonl"
[[ -f "$LE8" ]] && present8=yes || present8=no
assert_eq "$present8" "yes" "watchdog-kill: a lever-events.jsonl is written for a killed attempt"
wd8="$(jq -c 'select(.event=="watchdog-kill")' "$LE8" 2>/dev/null || true)"
assert_contains "$wd8" '"reason":"wall-clock-timeout"' "watchdog-kill PRESENT with the wall-clock reason"
assert_eq "$(jq -r '.ticket' <<<"$wd8")" "7" "watchdog-kill: ticket=7"
assert_eq "$(jq -r '.session' <<<"$wd8")" "worker" "watchdog-kill: session=worker"
assert_eq "$([[ "$(jq -r '.ctxTokens' <<<"$wd8")" -ge 0 ]] && echo ok || echo bad)" "ok" "watchdog-kill: ctxTokens is a real number"

# ── 8b. same real call site, GOVERN_LEVER_EVENTS genuinely UNSET: the default fires it too ──────
out8b="$(run_spawn_default "$T/logs8b" "$T/fake-claude-hang.sh" GOVERN_WORKER_TIMEOUT=2)"
assert_eq "$(jq -r '.status' <<<"$out8b")" "timeout" "sanity: this attempt was killed too"
LE8b="$T/logs8b/lever-events.jsonl"
[[ -f "$LE8b" ]] && present8b=yes || present8b=no
assert_eq "$present8b" "yes" \
  "watchdog-kill: with NOTHING set (not even the test's own GOVERN_LEVER_EVENTS=1), the real spawn-worker.sh call site still writes the event: the runtime default reaches production dispatch, not just the isolated emitter"

# ── 9. watchdog-kill ABSENT: the SAME ticket resolved normally ─────────────────────────────────
cat > "$T/fake-claude-ok.sh" <<'EOF'
#!/usr/bin/env bash
printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/a"}}],"usage":{"input_tokens":50,"output_tokens":10}}}\n'
report='{"status":"resolved","pr":{"repo":"alpha","number":9,"url":"http://pr/9"},"lessonPatch":null,"newTickets":[],"crossRefs":{},"escalation":null}'
[[ -n "${GOVERN_REPORT_PATH:-}" ]] && printf '%s' "$report" > "$GOVERN_REPORT_PATH"
printf '{"type":"result","result":%s}\n' "$(printf '%s' "$report" | jq -Rs .)"
EOF
chmod +x "$T/fake-claude-ok.sh"
# case 8 PRESERVED $T/wt/ticket-7 (a genuine kill leaves the worktree behind for a retry to resume
# from): clear it so this is a truly clean FIRST attempt, not an accidental retry.
rm -rf "$T/wt/ticket-7"
out9="$(run_spawn "$T/logs9" "$T/fake-claude-ok.sh" GOVERN_WORKER_TIMEOUT=60)"
assert_eq "$(jq -r '.status' <<<"$out9")" "resolved" "sanity: this attempt was NOT killed"
LE9="$T/logs9/lever-events.jsonl"
if [[ -f "$LE9" ]]; then
  n9="$(jq -sc '[ .[] | select(.event=="watchdog-kill" or .event=="resume" or .event=="escalation") ] | length' "$LE9")"
else
  n9=0
fi
assert_eq "$n9" "0" "watchdog-kill/resume/escalation ABSENT: a clean first-attempt resolve fires none of them"

# ── 10. resume PRESENT, escalation ABSENT: a retry with real notes + a real prior attempt ──────
# This case used to assert an `escalation` lever event beside `resume`. Automatic tier escalation is
# REMOVED (no failure class buys a model), so the emitter is gone and the event can never fire. What
# is asserted now is both halves of that: `resume` still fires exactly as before, and `escalation`
# is absent even on the signature that used to be its canonical trigger (an unrecognized class on a
# real prior attempt). The `escalation` schema stays documented in bench/LEVER-EVENTS.md because
# historical logs still carry those rows; nothing emits new ones.
# rm -rf first: a stale worktree from an earlier case must not leak into this one.
rm -rf "$T/wt/ticket-7"; mkdir -p "$T/wt/ticket-7" "$T/logs10/ticket-7"
cat > "$T/wt/ticket-7/.governor-notes.md" <<'EOF'
Freeform scratchpad from attempt one.

<!-- GOVERN:HANDOFF -->
### Handoff: attempt 1 (failed)
**Ruled out:** the retry lock is not in db/pool.ts
**Stopped at:** src/queue/claim.ts:88
**Would try next:** check the error path
<!-- /GOVERN:HANDOFF -->
EOF
# The prior attempt's own stream: must still be at $logdir/worker.jsonl, UNTOUCHED, so
# freshStartTokens reads a real number before spawn-worker rotates it aside. Every usage bucket is
# a DISTINCT, deliberately large value so a leak of output_tokens or cache_read_input_tokens into
# the sum (the exact regression bench/LEVER-EVENTS.md warns against) fails loudly rather than
# quietly landing on a coincidentally-plausible number.
printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/a"}}],"usage":{"input_tokens":800,"output_tokens":200,"cache_read_input_tokens":5000,"cache_creation_input_tokens":50}}}\n' \
  > "$T/logs10/ticket-7/worker.jsonl"
printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/b"}}],"usage":{"input_tokens":300,"output_tokens":100,"cache_read_input_tokens":3000,"cache_creation_input_tokens":25}}}\n' \
  >> "$T/logs10/ticket-7/worker.jsonl"
# The prior attempt's ledger row. It used to be what escalation's failedTokens read; it is kept
# because it is ALSO what makes MODEL_IS_RETRY true, which is what this case needs.
printf '{"attempt":1,"model":"sonnet","tokens":{"input":1000,"output":500,"cacheRead":0,"cacheCreation":0,"total":1500},"status":"failed"}\n' \
  > "$T/logs10/ticket-7/attempts.jsonl"

out10="$(run_spawn "$T/logs10" "$T/fake-claude-ok.sh" GOVERN_WORKER_TIMEOUT=60)"
assert_eq "$(jq -r '.status' <<<"$out10")" "resolved" "sanity: the retry itself resolved"
LE10="$T/logs10/lever-events.jsonl"
[[ -f "$LE10" ]] && present10=yes || present10=no
assert_eq "$present10" "yes" "resume: lever-events.jsonl written for the retry"

resume10="$(jq -c 'select(.event=="resume")' "$LE10" 2>/dev/null || true)"
assert_eq "$([[ -n "$resume10" ]] && echo yes || echo no)" "yes" "resume PRESENT: the retry carried real notes + a real handoff block"
assert_eq "$(jq -r '.ticket' <<<"$resume10")" "7" "resume: ticket=7"
assert_eq "$(jq -r '.session' <<<"$resume10")" "worker" "resume: session=worker"
assert_eq "$(jq -r '.freshStartTokens' <<<"$resume10")" "1175" \
  "resume: freshStartTokens = input+cache_creation ONLY ((800+50)+(300+25)=1175), read before rotation: output_tokens (200+100) and cache_read_input_tokens (5000+3000) must NOT leak in"
assert_eq "$([[ "$(jq -r '.checkpointTokens' <<<"$resume10")" -gt 0 ]] && echo ok || echo bad)" "ok" "resume: checkpointTokens > 0 (the injected notes + handoff are non-empty)"

esc10="$(jq -c 'select(.event=="escalation")' "$LE10" 2>/dev/null || true)"
assert_eq "$([[ -z "$esc10" ]] && echo absent || echo present)" "absent" \
  "escalation ABSENT even on an unrecognized class: the lever it measured no longer exists"
assert_not_contains "$(cat "$DIR/../spawn-worker.sh")" "emit_lever_event escalation" \
  "and the emitter itself is deleted, not just unreachable"

# ── 11. escalation ABSENT on a driver-declared infra retry, which re-bets the SAME tier ────────
# MODEL_IS_RETRY now comes from a RECORDED attempt (attempts.jsonl), not from the worktree
# directory alone (see spawn-worker.sh): seed a real ledger row for the infra-killed attempt 1 so
# this dispatch is genuinely detected as a retry, same as case 10 above.
rm -rf "$T/wt/ticket-7"; mkdir -p "$T/wt/ticket-7" "$T/logs11/ticket-7"
printf '{"attempt":1,"model":"sonnet","tokens":{"input":100,"output":50,"cacheRead":0,"cacheCreation":0,"total":150},"status":"infra"}\n' \
  > "$T/logs11/ticket-7/attempts.jsonl"
cat > "$T/wt/ticket-7/.governor-notes.md" <<'EOF'
<!-- GOVERN:HANDOFF -->
### Handoff: attempt 1 (infra)
**Ruled out:** nothing: a transport outage, not a ticket problem
**Stopped at:** mid-request
**Would try next:** re-run identically
<!-- /GOVERN:HANDOFF -->
EOF
out11="$(run_spawn "$T/logs11" "$T/fake-claude-ok.sh" GOVERN_WORKER_TIMEOUT=60 GOVERN_RETRY_CLASS=infra)"
assert_eq "$(jq -r '.status' <<<"$out11")" "resolved" "sanity: this retry also resolved"
LE11="$T/logs11/lever-events.jsonl"
if [[ -f "$LE11" ]]; then
  esc11="$(jq -c 'select(.event=="escalation")' "$LE11" 2>/dev/null || true)"
else
  esc11=""
fi
assert_eq "$([[ -z "$esc11" ]] && echo absent || echo present)" "absent" \
  "escalation ABSENT: GOVERN_RETRY_CLASS=infra re-bets the same tier (and nothing escalates at all now)"
# resume still fires (real notes were injected): the two levers are independent.
resume11="$(jq -c 'select(.event=="resume")' "$LE11" 2>/dev/null || true)"
assert_eq "$([[ -n "$resume11" ]] && echo yes || echo no)" "yes" "resume still PRESENT on the infra retry (notes were real) even though escalation is absent"

# ══════════════════════════════════════════════════════════════════════════════════════════════
# scripted-action: deterministic-apply.sh (zero-model resolution lane)
# ══════════════════════════════════════════════════════════════════════════════════════════════
mkdir -p "$T/alpha"
cat > "$T/alpha/config.js" <<'EOF'
module.exports = {
  retries: 1,
  timeout: 30,
};
EOF
git -C "$T/alpha" init -q
git -C "$T/alpha" checkout -q -b main 2>/dev/null || true
git -C "$T/alpha" config user.email t@t.t
git -C "$T/alpha" config user.name t
git -C "$T/alpha" add -A
git -C "$T/alpha" commit -qm init

cat > "$T/fake-worktree-det.sh" <<EOF
#!/usr/bin/env bash
set -e
wt="$T/wt-det/\$1"
rm -rf "\$wt"; mkdir -p "\$wt"
cp -R "$T/alpha" "\$wt/alpha"
git -C "\$wt/alpha" checkout -q -b "\$1"
echo "\$wt"
EOF
chmod +x "$T/fake-worktree-det.sh"

GOOD_DIFF="$T/good.diff"
cat > "$GOOD_DIFF" <<'EOF'
--- a/alpha/config.js
+++ b/alpha/config.js
@@ -1,4 +1,4 @@
 module.exports = {
-  retries: 1,
+  retries: 3,
   timeout: 30,
 };
EOF

seed_case() { # <ticket> <diff-file> <logroot>
  local n="$1" diff="$2" logroot="$3"
  local d="$logroot/ticket-$n"   # split: a later `local` can't read an earlier one in the SAME statement
  mkdir -p "$d"
  jq -n --argjson n "$n" --argjson paths '["alpha/config.js"]' --rawfile diff "$diff" \
    '{ticket:$n, scoutModel:"haiku", ts:0,
      scope:{files:1, repos:1, testsCover:true, precedent:true, changeKind:"local",
             fixDirection:"concrete", targetPaths:$paths, precedentCommit:"", testCommand:"",
             deterministic:{kind:"config-default", rationale:"flip a default", diff:$diff}}}' \
    > "$d/scout.json"
}

run_apply() { # <ticket> <logroot> [env assignments...]
  local n="$1" logroot="$2"; shift 2
  set +e
  DET_OUT="$(env GOVERN_WS_ROOT="$T" GOVERN_LOG_ROOT="$logroot" \
      GOVERN_WORKTREE_CMD="$T/fake-worktree-det.sh" \
      GOVERN_CLAUDE_BIN="/usr/bin/false" \
      "$@" "$APPLY" --dry-run "$n" 2>/dev/null)"
  DET_RC=$?
  set -e
}

# ── 12. scripted-action PRESENT: the happy path, zero model turns ──────────────────────────────
seed_case 12 "$GOOD_DIFF" "$T/logs12"
run_apply 12 "$T/logs12" GOVERN_LEVER_EVENTS=1 GOVERN_DETERMINISTIC=1 GOVERN_DETERMINISTIC_VERIFY_CMD="true"
assert_eq "$DET_RC" "0" "sanity: the deterministic patch actually applied"
LE12="$T/logs12/lever-events.jsonl"
[[ -f "$LE12" ]] && present12=yes || present12=no
assert_eq "$present12" "yes" "scripted-action: lever-events.jsonl written for a zero-model resolution"
sa12="$(jq -c 'select(.event=="scripted-action")' "$LE12" 2>/dev/null || true)"
assert_eq "$([[ -n "$sa12" ]] && echo yes || echo no)" "yes" "scripted-action PRESENT"
assert_eq "$(jq -r '.ticket' <<<"$sa12")" "12" "scripted-action: ticket"
assert_eq "$(jq -r '.session' <<<"$sa12")" "driver" "scripted-action: session=driver"
assert_eq "$(jq -r '.tier' <<<"$sa12")" "null" "scripted-action: tier=null (no model call anywhere in this file)"
assert_eq "$(jq -r '.class' <<<"$sa12")" "config-default" "scripted-action: class = the scout's cached kind"

# ── 13. scripted-action ABSENT: kill switch off, the ticket falls through untouched ────────────
seed_case 13 "$GOOD_DIFF" "$T/logs13"
run_apply 13 "$T/logs13" GOVERN_LEVER_EVENTS=1
assert_eq "$DET_RC" "10" "sanity: kill switch off (default) → falls through to a normal worker"
LE13="$T/logs13/lever-events.jsonl"
[[ -f "$LE13" ]] && present13=yes || present13=no
assert_eq "$present13" "no" "scripted-action ABSENT: nothing was resolved, so nothing is credited"

assert_done
