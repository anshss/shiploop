#!/usr/bin/env bash
# Supervisor cadence must not silently loosen under --parallel.
#
# The bug: GOVERN_SUPERVISOR_EVERY is a PER-DRIVER counter (`since_review`, a shell variable in each
# driver process). Under a fan-out, each driver accumulates its own — so a backlog split N ways lost
# every driver's TAIL of 1..SUP_EVERY-1 unreviewed resolves. With SUP_EVERY=5, a 6-ticket backlog
# across 2 drivers (≈3 each) reached the periodic pass ZERO times, where the same 6 run sequentially
# fired it once. Nothing was broken — the anomaly trigger still worked — but the review rhythm
# quietly loosened by roughly the fan-out factor, and no supervisor ever saw the run as a WHOLE.
#
# The fix (documented in commands/govern.md): keep the per-driver cadence exactly as-is — dividing it
# by N would OVER-fire ~N× on a long run, since N drivers each firing every SUP_EVERY of their own
# resolves already totals ≈K/SUP_EVERY passes over K tickets — and instead add two out-of-loop passes:
#   · a run-tail flush, once per driver, when its loop ends holding unreviewed resolves;
#   · one whole-run pool review in the orchestrator over the AGGREGATED state.jsonl.
#
# What this locks:
#  1. Sequential 6 tickets @ SUP_EVERY=5 → exactly 2 passes (1 periodic + 1 tail flush).
#  2. The SAME 6 tickets across a 2-driver fan-out → exactly 3 passes — comparable, not zero. This is
#     split-INDEPENDENT: per driver the passes are ceil(k_i/SUP_EVERY), which sums to 2 for every way
#     6 tickets can land across 2 drivers ((3,3) (4,2) (5,1) (6,0)), plus the 1 pool review.
#  3. Exactly ONE whole-run pool review per parallel run — the review that sees the run as a whole.
#  4. GOVERN_SUPERVISOR_FLUSH=0 restores the old periodic-only behaviour (neither out-of-loop pass).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
RL="$DIR/../run-loop.sh"

# Same minimal stubs as test-run-loop-multi-target.sh: every worker call resolves its ticket, every
# supervisor call returns a clean verdict. Keeping the supervisor verdict EMPTY of concerns/halt is
# deliberate — this test counts PASSES, so a verdict that changed selection would muddy the count.
mk_claude_stub() { # <bindir>
  cat > "$1/claude" <<'EOF'
#!/usr/bin/env bash
prompt=""
while [[ $# -gt 0 ]]; do [[ "$1" == "-p" ]] && { prompt="$2"; shift 2; continue; }; shift; done
if printf '%s' "$prompt" | grep -q 'SUPERVISOR-REVIEW'; then
  printf '{"type":"result","result":%s}\n' "$(printf '{"verdict":"ok","concerns":[],"haltReason":null}' | jq -Rs .)"
  exit 0
fi
n="$(printf '%s' "${GOVERN_REPORT_PATH:-}" | sed -E 's#.*/ticket-([0-9]+)/.*#\1#')"
report="{\"status\":\"resolved\",\"pr\":{\"repo\":\"alpha\",\"number\":${n}01,\"url\":\"http://pr/${n}\"},\"lessonPatch\":null,\"newTickets\":[],\"crossRefs\":{\"overlaps\":[],\"dependsOn\":[]},\"migration\":null,\"escalation\":null}"
[[ -n "${GOVERN_REPORT_PATH:-}" ]] && printf '%s' "$report" > "$GOVERN_REPORT_PATH"
printf '{"type":"result","result":%s}\n' "$(printf '%s' "$report" | jq -Rs .)"
EOF
  chmod +x "$1/claude"
}
mk_gh_stub() { # <bindir>
  cat > "$1/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"pr list"*)  echo '[]';;
  *)            echo '[{"bucket":"pass"}]';;
esac
EOF
  chmod +x "$1/gh"
}

# Six tickets — one more than SUP_EVERY, so a sequential run fires the periodic pass exactly once and
# still ends holding a tail of one unreviewed resolve.
mk_fixture() { # <dir>
  local d="$1"
  mkdir -p "$d/bin" "$d/governor" "$d/logs" "$d/wt"
  ( cd "$d" && git init -q && git config user.email t@t && git config user.name t )
  mk_ws_stub "$d"
  { echo "# Tickets"; local n
    for n in 401 402 403 404 405 406; do
      printf -- '---\n## #%s — one\n**Severity:** High — x.\n' "$n"; done; echo "---"; } > "$d/tickets.md"
  printf '## Open\n\n## Resolved\n' > "$d/governor/escalations.md"
  cat > "$d/wt.sh" <<EOF
#!/usr/bin/env bash
mkdir -p "$d/wt/\$1"; echo "$d/wt/\$1"
EOF
  chmod +x "$d/wt.sh"
  mk_gh_stub "$d/bin"; mk_claude_stub "$d/bin"
}

# Both the orchestrator and every child log through govern::log → stderr, and a child's stdout is
# redirected onto the parent's stderr, so `2>&1` here captures EVERY driver's passes in one string.
run_govern() { # <dir> <args...> → combined stdout+stderr
  local d="$1"; shift
  PATH="$d/bin:$PATH" \
  GOVERN_TICKETS_FILE="$d/tickets.md" \
  GOVERN_ESCALATIONS_FILE="$d/governor/escalations.md" \
  GOVERN_WORKER_PROMPT_FILE="$GOVERN_PROMPTS_DIR/worker-prompt.md" \
  GOVERN_PREFERENCES_FILE="$GOVERN_PROMPTS_DIR/preferences.md" \
  GOVERN_SUPERVISOR_PROMPT_FILE="$GOVERN_PROMPTS_DIR/supervisor-prompt.md" \
  GOVERN_LOG_ROOT="$d/logs" \
  GOVERN_TICKET_SEQ_FILE="$d/.ticket-seq" \
  GOVERN_LOCK="$d/lock" \
  GOVERN_WORKTREE_CMD="$d/wt.sh" \
  GOVERN_CLAUDE_BIN="$d/bin/claude" \
  GOVERN_ECHO=1 GOVERN_SKIP_CI=1 GOVERN_IMPROVE=0 GOVERN_PARALLEL_STAGGER_S=0 \
  GOVERN_SUPERVISOR_EVERY="${SUP_EVERY_UNDER_TEST:-5}" \
  bash "$RL" "$@" 2>&1
}
count() { grep -cF "$2" <<<"$1" || true; }   # -F + here-string: same SIGPIPE-safe shape as assert_contains

# ── 1. Baseline: the SEQUENTIAL rhythm over 6 tickets ────────────────────────────────────────────
TS="$(mktemp -d)"; trap 'rm -rf "$TS"' EXIT
mk_fixture "$TS"
seq_out="$(run_govern "$TS" --serial)"
seq_n="$(count "$seq_out" "supervisor review")"
assert_contains "$seq_out" "resolved=6 parked=0 failed=0" "sequential baseline resolved all 6 tickets"
assert_eq "$(count "$seq_out" "supervisor review (run-tail flush, since_review=1)")" "1" \
  "sequential run flushes its 1-ticket tail — without this the 6th resolve is never reviewed by anyone"
assert_eq "$seq_n" "2" "sequential 6 tickets @ SUP_EVERY=5 → 2 passes (1 periodic + 1 tail flush)"

# ── 2. The SAME 6 tickets across a 2-driver fan-out fire a comparable number of passes ───────────
TP="$(mktemp -d)"; trap 'rm -rf "$TS" "$TP"' EXIT
mk_fixture "$TP"
par_out="$(run_govern "$TP" --parallel=2)"
par_n="$(count "$par_out" "supervisor review")"
assert_contains "$par_out" "parallel mode: backlog pull across 2 concurrent full driver(s)" \
  "the fan-out under test is 2 FULL backlog drivers (the shape that owns the per-driver cadence)"
assert_contains "$par_out" "parallel run done: 2 driver(s) processed 6 ticket(s) → resolved 6" \
  "the 2-driver run worked the same 6 tickets as the sequential baseline"
assert_eq "$par_n" "3" \
  "2-driver fan-out → 3 passes vs the sequential run's 2 — comparable. Pre-fix this was 0 for the common (3,3) split, because neither driver's since_review ever reached SUP_EVERY"
assert_eq "$(count "$par_out" "supervisor review (whole-run pool:")" "1" \
  "exactly ONE whole-run pool review — the pass that reads the AGGREGATED state.jsonl and so sees the run as a whole, which no per-driver pass ever does"

# ── 3. GOVERN_SUPERVISOR_FLUSH=0 restores the old periodic-only behaviour ────────────────────────
# The escape hatch matters because both new passes cost a real supervisor call; a fleet that wants the
# pre-fix rhythm (or is metering supervisor spend) must be able to opt out without patching the script.
TF="$(mktemp -d)"; trap 'rm -rf "$TS" "$TP" "$TF"' EXIT
mk_fixture "$TF"
off_out="$(GOVERN_SUPERVISOR_FLUSH=0 run_govern "$TF" --parallel=2)"
assert_contains "$off_out" "parallel run done: 2 driver(s) processed 6 ticket(s) → resolved 6" \
  "opting out of the flush changes only the review rhythm — the run itself still grinds the whole backlog"
assert_eq "$(count "$off_out" "run-tail flush")" "0" "GOVERN_SUPERVISOR_FLUSH=0 suppresses every per-driver tail flush"
assert_eq "$(count "$off_out" "whole-run pool")" "0" "GOVERN_SUPERVISOR_FLUSH=0 suppresses the whole-run pool review too"

assert_done
