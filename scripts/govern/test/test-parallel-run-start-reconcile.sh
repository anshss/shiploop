#!/usr/bin/env bash
# The run-start reconcile must happen exactly ONCE per run, no matter how wide the fan-out.
#
# The bug: the run-start block (escalations-apply-answers → escalations-emit-pending →
# preflight-main → externalize-low-tickets, plus the NA-skip streak bookkeeping) is WHOLE-RUN state
# reconciliation against the ONE shared meta checkout — preflight-main in particular does
# fetch / pull --rebase / push on it. When parallel became the default, the orchestrator ran that
# block itself and then spawned N full backlog drivers that EACH re-ran it against the SAME
# checkout, concurrently. Nothing serialized them (the bookkeep lock only covers tickets.md edits);
# GOVERN_PARALLEL_STAGGER_S merely narrowed the collision window.
#
# The fix: the orchestrator already reconciles once, under the single-run lock, before it spawns
# anything — so children are handed the internal `--orchestrated` flag and skip the block entirely.
#
# What this locks:
#  1. A 2-driver backlog fan-out against a REAL origin-backed meta checkout runs preflight-main
#     exactly once, logs one "run-start reconcile: skipped" per child, still resolves the whole
#     backlog, and leaves origin/main correctly reconciled (ground truth, not just a log line).
#  2. A SERIAL run still reconciles (exactly once, and never logs a skip) — the fix must not turn
#     the reconcile off for the mode that has no orchestrator to do it.
#  3. Under a preflight stub that records its own entry/exit, a 3-driver fan-out yields exactly ONE
#     invocation and zero OVERLAP markers — i.e. no two drivers are ever inside the git work at the
#     same time. Pre-fix every driver ran it (orchestrator + one per spawned child) and overlapped.
#  4. Dry-run parallel: the "[dry] would preflight-reconcile" intent is announced once, not per child.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
RL="$DIR/../run-loop.sh"

# Every worker call resolves its ticket; every supervisor call returns a clean verdict (same minimal
# stubs as test-supervisor-cadence-parallel.sh).
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

# A meta checkout that is REALLY origin-backed and REALLY ahead of origin/main, so preflight-main
# takes its push path (git fetch + git push) instead of the "no origin remote — skipping" no-op.
# That is the git work the parallel drivers were duplicating.
mk_fixture() { # <dir>
  local d="$1"
  mkdir -p "$d/bin" "$d/governor" "$d/logs" "$d/wt"
  git init -q --bare "$d/origin.git"
  ( cd "$d" && git init -q && git config user.email t@t && git config user.name t \
      && git symbolic-ref HEAD refs/heads/main \
      && git remote add origin "$d/origin.git" \
      && mkdir -p governor && printf '## Open\n\n## Resolved\n' > governor/escalations.md \
      && printf '# seed\n' > README.md && git add -A && git commit -qm seed && git push -q -u origin main \
      && printf '# seed + one unpushed meta commit\n' > README.md && git commit -qam "local meta commit" )
  mk_ws_stub "$d"
  { echo "# Tickets"; local n
    for n in 501 502; do printf -- '---\n## #%s — one\n**Severity:** High — x.\n' "$n"; done; echo "---"; } > "$d/tickets.md"
  cat > "$d/wt.sh" <<EOF
#!/usr/bin/env bash
mkdir -p "$d/wt/\$1"; echo "$d/wt/\$1"
EOF
  chmod +x "$d/wt.sh"
  mk_gh_stub "$d/bin"; mk_claude_stub "$d/bin"
}

# The orchestrator and every child log through govern::log → stderr, and a child's stdout is
# redirected onto the parent's stderr, so 2>&1 captures EVERY driver's lines in one string.
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
  bash "${RL_UNDER_TEST:-$RL}" "$@" 2>&1
}
count() { grep -cF "$2" <<<"$1" || true; }

# ── 1. A 2-driver backlog fan-out reconciles ONCE ────────────────────────────────────────────────
TP="$(mktemp -d)"; trap 'rm -rf "$TP"' EXIT
mk_fixture "$TP"
par_out="$(run_govern "$TP" --parallel=2)"
assert_contains "$par_out" "parallel mode: backlog pull across 2 concurrent full driver(s)" \
  "the fan-out under test is 2 FULL backlog drivers — the shape that re-ran the preflight N times"
assert_eq "$(count "$par_out" "preflight: published")" "1" \
  "preflight-main did its git work (fetch + push of the unpushed meta commit) EXACTLY once across the whole run — pre-fix each of the 2 children repeated it against the same checkout"
assert_eq "$(count "$par_out" "run-start reconcile: skipped")" "2" \
  "each of the 2 children announces that it skipped the run-start reconcile — one line per child, so the skip is auditable, never silent"
assert_eq "$(count "$par_out" "could NOT reconcile")" "0" \
  "no driver hit a reconcile failure — the interleaved-git hazard is gone, not merely narrowed"
assert_contains "$par_out" "parallel run done: 2 driver(s) processed 2 ticket(s) → resolved 2" \
  "skipping the child reconcile does not cost the run any tickets — the whole backlog still resolves"
# Ground truth, independent of any log line: the one reconcile actually happened on disk.
assert_eq "$(git -C "$TP/origin.git" rev-parse main)" "$(git -C "$TP" rev-parse main)" \
  "origin/main == local main afterwards — the single reconcile really published the unpushed meta commit"

# ── 2. A SERIAL run still reconciles (there is no orchestrator to have done it) ───────────────────
TS="$(mktemp -d)"; trap 'rm -rf "$TP" "$TS"' EXIT
mk_fixture "$TS"
seq_out="$(run_govern "$TS" --serial)"
assert_eq "$(count "$seq_out" "preflight: published")" "1" \
  "the sequential driver still runs the run-start preflight itself — the fix must not disarm the mode with no orchestrator"
assert_eq "$(count "$seq_out" "run-start reconcile: skipped")" "0" \
  "a top-level driver never skips the reconcile — only an orchestrator-spawned child does"
assert_contains "$seq_out" "resolved=2 parked=0 failed=0" "sequential baseline resolved both tickets"

# ── 3. No two drivers are ever INSIDE the reconcile at once ──────────────────────────────────────
# Run against a COPY of the govern dir whose preflight-main.sh is a stub that records enter/exit and
# holds the section open for a moment: any second entrant while one is inside writes an OVERLAP
# marker. This is the interleaving assertion the log counts alone can't make.
TO="$(mktemp -d)"; trap 'rm -rf "$TP" "$TS" "$TO"' EXIT
mk_fixture "$TO"
cp -R "$DIR/.." "$TO/govern"
cat > "$TO/govern/preflight-main.sh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
echo "ENTER \$\$" >> "$TO/preflight.trace"
[[ -e "$TO/preflight.inside" ]] && echo "OVERLAP \$\$" >> "$TO/preflight.trace"
: > "$TO/preflight.inside"
sleep 1
rm -f "$TO/preflight.inside"
echo "EXIT \$\$" >> "$TO/preflight.trace"
exit 0
EOF
chmod +x "$TO/govern/preflight-main.sh"
: > "$TO/preflight.trace"
RL_UNDER_TEST="$TO/govern/run-loop.sh" run_govern "$TO" --parallel=3 >/dev/null
assert_eq "$(grep -c '^ENTER' "$TO/preflight.trace" || true)" "1" \
  "exactly ONE process entered preflight-main across a 3-wide fan-out — pre-fix every driver ran it: 1 orchestrator + one per spawned child"
assert_eq "$(grep -c '^OVERLAP' "$TO/preflight.trace" || true)" "0" \
  "no driver entered the reconcile while another was inside it — the git work against the shared meta checkout is never interleaved"

# ── 4. Dry-run announces the reconcile intent once, not per child ─────────────────────────────────
TD="$(mktemp -d)"; trap 'rm -rf "$TP" "$TS" "$TO" "$TD"' EXIT
mk_fixture "$TD"
dry_out="$(run_govern "$TD" --parallel=2 --dry-run)"
assert_eq "$(count "$dry_out" "[dry] would preflight-reconcile")" "1" \
  "dry-run announces the reconcile intent once for the run — a per-child repeat would misreport what a live run would do"

assert_done
