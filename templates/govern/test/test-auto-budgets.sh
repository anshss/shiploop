#!/usr/bin/env bash
# #95 - run-loop.sh flushes `govern-bookkeep.sh --enforce-budgets` at run-end, after every worker
# is reaped, instead of never (it used to run only by hand: `npm run govern:budgets`, or a human
# heeding doctor.sh's failing check). Gated by GOVERN_AUTO_BUDGETS (default on; assert.sh forces it
# off for the whole suite the same way it forces GOVERN_OVERLAP_NUDGE off, so a test that wants the
# real default must opt back in explicitly). Proves:
#   1. GOVERN_AUTO_BUDGETS=1, two tickets dispatched: --enforce-budgets runs EXACTLY ONCE for the
#      whole run, never per-ticket (a per-driver cadence divided across a fan-out would overfire).
#   2. GOVERN_AUTO_BUDGETS=0: --enforce-budgets never runs at all.
#   3. A deliberate exit-3 alarm from --enforce-budgets (CLAUDE.md over budget, no appendix to
#      demote into) is logged but does NOT change the run's own exit status.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
RL="$DIR/../run-loop.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 77; }

# Every ticket resolves cleanly (no lessonPatch, so nothing exercises the #87 admission gates:
# those are test-lesson-admission.sh's job). Two tickets, so "exactly once" is a real claim.
setup_ws() { # <root> <n-tickets>
  local T="$1" n="$2" i body=""
  mkdir -p "$T/bin" "$T/governor" "$T/logs" "$T/wt"
  ( cd "$T" && git init -q && git config user.email t@t && git config user.name t )
  { printf '# Tickets\n---\n'
    for ((i = 1; i <= n; i++)); do
      printf '## #%d - ticket %d\n**Severity:** High - x.\nbody%d\n---\n' "$i" "$i" "$i"
    done
  } > "$T/tickets.md"
  printf '## Open\n\n## Resolved\n' > "$T/governor/escalations.md"
  cat > "$T/wt.sh" <<EOF
#!/usr/bin/env bash
mkdir -p "$T/wt/\$1"; echo "$T/wt/\$1"
EOF
  chmod +x "$T/wt.sh"
  cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"pr list"*) echo '[]';;
  *)           echo '[{"bucket":"pass"}]';;
esac
EOF
  chmod +x "$T/bin/gh"
  cat > "$T/bin/claude" <<'EOF'
#!/usr/bin/env bash
prompt=""
while [[ $# -gt 0 ]]; do [[ "$1" == "-p" ]] && { prompt="$2"; shift 2; continue; }; shift; done
n="$(printf '%s' "${GOVERN_REPORT_PATH:-}" | sed -E 's#.*/ticket-([0-9]+)/.*#\1#')"
report="{\"status\":\"resolved\",\"pr\":{\"repo\":\"alpha\",\"number\":${n}01,\"url\":\"http://pr/${n}\"},\"lessonPatch\":null,\"newTickets\":[],\"crossRefs\":{\"overlaps\":[],\"dependsOn\":[]},\"migration\":null,\"escalation\":null}"
[[ -n "${GOVERN_REPORT_PATH:-}" ]] && printf '%s' "$report" > "$GOVERN_REPORT_PATH"
printf '{"type":"result","result":%s}\n' "$(printf '%s' "$report" | jq -Rs .)"
EOF
  chmod +x "$T/bin/claude"
}

run_governor() { # <root> <ticket-args...> -- <extra-env-assignments...>
  local T="$1"; shift
  local -a targets=() extra=() dashseen=0
  for a in "$@"; do
    if [[ "$dashseen" -eq 0 && "$a" == "--" ]]; then dashseen=1; continue; fi
    if [[ "$dashseen" -eq 0 ]]; then targets+=("$a"); else extra+=("$a"); fi
  done
  # NOTE: a dynamically-built "NAME=value" string is not parsed as an assignment prefix by bash
  # (that only applies to a literal token at parse time), it would be treated as the command name
  # instead ("command not found"). Route the caller-supplied extra assignments through `env`.
  PATH="$T/bin:$PATH" \
  GOVERN_WS_ROOT="$T" \
  GOVERN_TICKETS_FILE="$T/tickets.md" \
  GOVERN_ESCALATIONS_FILE="$T/governor/escalations.md" \
  GOVERN_WORKER_PROMPT_FILE="$GOVERN_PROMPTS_DIR/worker-prompt.md" \
  GOVERN_PREFERENCES_FILE="$GOVERN_PROMPTS_DIR/preferences.md" \
  GOVERN_SUPERVISOR_PROMPT_FILE="$GOVERN_PROMPTS_DIR/supervisor-prompt.md" \
  GOVERN_LOG_ROOT="$T/logs" \
  GOVERN_TICKET_SEQ_FILE="$T/.ticket-seq" \
  GOVERN_LOCK="$T/lock" \
  GOVERN_WORKTREE_CMD="$T/wt.sh" \
  GOVERN_CLAUDE_BIN="$T/bin/claude" \
  GOVERN_ECHO=1 GOVERN_SKIP_CI=1 GOVERN_IMPROVE=0 \
  GOVERN_MIGRATE_CMD="true" GOVERN_VERIFY_CMD="true" \
  env ${extra[@]+"${extra[@]}"} \
  bash "$RL" --serial ${targets[@]+"${targets[@]}"} 2>&1
}

MARK="budgets: auto-enforced at run-end"

# ── 1. GOVERN_AUTO_BUDGETS=1, two tickets: exactly ONE enforcement pass for the whole run ────────
T1="$(mktemp -d)"; trap 'rm -rf "$T1"' EXIT
setup_ws "$T1" 2
mk_ws_stub "$T1"
out1="$(run_governor "$T1" 1 2 -- GOVERN_AUTO_BUDGETS=1)"
assert_contains "$out1" "DONE" "on: the run completed"
hits1="$(grep -c "$MARK" <<<"$out1" || true)"
assert_eq "$hits1" "1" "on: --enforce-budgets ran EXACTLY ONCE across a 2-ticket dispatch, not per-ticket"
assert_contains "$out1" "nothing to enforce" \
  "on: the real govern-bookkeep.sh --enforce-budgets ran (no CLAUDE.md yet -> its own no-op message)"

# ── 2. GOVERN_AUTO_BUDGETS=0: never invoked ───────────────────────────────────────────────────────
T2="$(mktemp -d)"; trap 'rm -rf "$T1" "$T2"' EXIT
setup_ws "$T2" 1
mk_ws_stub "$T2"
out2="$(run_governor "$T2" 1 -- GOVERN_AUTO_BUDGETS=0)"
assert_contains "$out2" "DONE" "off: the run completed"
if grep -qF "$MARK" <<<"$out2"; then f=1; else f=0; fi
assert_eq "$f" "0" "off: GOVERN_AUTO_BUDGETS=0 means --enforce-budgets never runs"

# ── 3. A deliberate exit-3 alarm never changes the run's own exit status ─────────────────────────
T3="$(mktemp -d)"; trap 'rm -rf "$T1" "$T2" "$T3"' EXIT
setup_ws "$T3" 1
mk_ws_stub "$T3"
# CLAUDE.md over budget, CLAUDE-APPENDIX.md absent -> --enforce-budgets has nowhere to demote to
# and exits 3 immediately (govern-bookkeep.sh's own documented alarm path).
printf '# over budget\n%s\n' "$(head -c 200 /dev/zero | tr '\0' x)" > "$T3/CLAUDE.md"
out3="$(run_governor "$T3" 1 -- GOVERN_AUTO_BUDGETS=1 GOVERN_LESSON_BUDGET_CHARS=10)" && rc3=0 || rc3=$?
assert_eq "$rc3" "0" "alarm: exit-3 from --enforce-budgets does not change the DRIVER's own exit status"
assert_contains "$out3" "DONE" "alarm: the run still completes normally"
assert_contains "$out3" "ALARM" "alarm: the exit-3 outcome is logged"
assert_contains "$out3" "does not affect this run's exit status" "alarm: the log line says so explicitly"

assert_done
