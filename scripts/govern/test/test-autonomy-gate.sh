#!/usr/bin/env bash
# Onboarding mechanisms: the GOVERN_AUTONOMY trust ladder (observe | pr-only | auto). Exercises BOTH
# gate seams the feature touches:
#   A. merge-pr.sh — auto (and an ABSENT/EMPTY knob, for backward compat) merges; observe/pr-only
#      refuse with the distinct exit 6 (refused-by-autonomy) and a clear log line.
#   B. run-loop.sh — a resolved-with-PR ticket auto-merges under `auto` but is LEFT OPEN (still
#      bookkept resolved) under `pr-only`.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
MERGE="$DIR/../merge-pr.sh"
RL="$DIR/../run-loop.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"   # alpha auto-mergeable, web frontend; sets NO GOVERN_AUTONOMY (the backward-compat case)

# ── A. merge-pr.sh gate ──────────────────────────────────────────────────────
# Backward compat: knob ABSENT → treated as auto → merges (echo mode prints the merge, exit 0).
set +e
out="$(GOVERN_ECHO=1 GOVERN_SKIP_CI=1 "$MERGE" alpha 42 2>&1)"; code=$?
set -e
assert_eq "$code" "0" "GOVERN_AUTONOMY absent → auto (backward compat): alpha merges (exit 0)"
assert_contains "$out" "gh pr merge 42" "absent-knob echo mode still prints the merge command"

# Explicit auto → same.
set +e
out_a="$(GOVERN_AUTONOMY=auto GOVERN_ECHO=1 GOVERN_SKIP_CI=1 "$MERGE" alpha 42 2>&1)"; code_a=$?
set -e
assert_eq "$code_a" "0" "GOVERN_AUTONOMY=auto: alpha merges (exit 0)"

# pr-only → refused with exit 6 + a clear autonomy log line, NOT the merge command.
set +e
out_p="$(GOVERN_AUTONOMY=pr-only GOVERN_ECHO=1 GOVERN_SKIP_CI=1 "$MERGE" alpha 42 2>&1)"; code_p=$?
set -e
assert_eq "$code_p" "6" "GOVERN_AUTONOMY=pr-only: merge refused with distinct exit 6"
assert_contains "$out_p" "GOVERN_AUTONOMY=pr-only" "pr-only refusal names the autonomy mode"
if grep -qF "gh pr merge" <<<"$out_p"; then
  printf 'FAIL - %s\n' "pr-only does NOT run the merge command"; ASSERT_FAILS=$((ASSERT_FAILS+1))
else printf 'ok   - %s\n' "pr-only does NOT run the merge command"; fi

# observe → also refused with exit 6.
set +e
out_o="$(GOVERN_AUTONOMY=observe GOVERN_ECHO=1 GOVERN_SKIP_CI=1 "$MERGE" alpha 42 2>&1)"; code_o=$?
set -e
assert_eq "$code_o" "6" "GOVERN_AUTONOMY=observe: merge refused with distinct exit 6"

# An unrecognized value fails SAFE to auto (never silently disables a configured install on a typo).
set +e
out_x="$(GOVERN_AUTONOMY=bogus GOVERN_ECHO=1 GOVERN_SKIP_CI=1 "$MERGE" alpha 42 2>&1)"; code_x=$?
set -e
assert_eq "$code_x" "0" "unrecognized GOVERN_AUTONOMY degrades to auto (fail-safe): merges"

# ── B. run-loop.sh gate (full loop, hermetic — mirrors test-aborted-summary.sh) ──────────────────
mkdir -p "$T/bin" "$T/governor" "$T/logs-auto" "$T/logs-pr" "$T/wt"
( cd "$T" && git init -q && git config user.email t@t && git config user.name t )

cat > "$T/tickets.md" <<'EOF'
# Tickets
---
## #1 — simple resolved ticket with a PR on the auto-merge repo
**Severity:** Medium — x.
body1
---
EOF
printf '## Open\n\n## Resolved\n' > "$T/governor/escalations.md"
printf 'DOC\n' > "$T/governor/preferences.md"
printf 'P {{TICKET_BLOCK}} {{REPORT_PATH}}\n' > "$T/governor/worker-prompt.md"
printf 'SUPERVISOR-REVIEW\n' > "$T/governor/supervisor-prompt.md"

cat > "$T/wt.sh" <<EOF
#!/usr/bin/env bash
mkdir -p "$T/wt/\$1"; echo "$T/wt/\$1"
EOF
chmod +x "$T/wt.sh"

cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"pr list"*)    echo '[]';;
  *"pr checks"*)  echo '[{"bucket":"pass"}]';;
  *"pr merge"*)   echo 'merged';  exit 0;;
  *"pr view"*)    echo 'ticket-1'; exit 0;;
  *)              echo '[{"bucket":"pass"}]';;
esac
EOF
chmod +x "$T/bin/gh"

# Worker: supervisor verdict on the marker; else resolve #N with a PR on alpha (auto-merge repo), no migration.
cat > "$T/bin/claude" <<'EOF'
#!/usr/bin/env bash
prompt=""
while [[ $# -gt 0 ]]; do [[ "$1" == "-p" ]] && { prompt="$2"; shift 2; continue; }; shift; done
if printf '%s' "$prompt" | grep -q 'SUPERVISOR-REVIEW'; then
  printf '{"type":"result","result":%s}\n' "$(printf '{"verdict":"ok","concerns":[],"haltReason":null}' | jq -Rs .)"
  exit 0
fi
n="$(printf '%s' "${GOVERN_REPORT_PATH:-}" | sed -E 's#.*/ticket-([0-9]+)/.*#\1#')"
report="{\"status\":\"resolved\",\"pr\":{\"repo\":\"alpha\",\"number\":${n}01,\"url\":\"http://pr/${n}\"},\"lessonPatch\":null,\"newTickets\":[],\"escalation\":null}"
[[ -n "${GOVERN_REPORT_PATH:-}" ]] && printf '%s' "$report" > "$GOVERN_REPORT_PATH"
printf '{"type":"result","result":%s}\n' "$(printf '%s' "$report" | jq -Rs .)"
EOF
chmod +x "$T/bin/claude"

run_loop() { # <autonomy-value-or-empty> <logdir>
  local mode="$1" logdir="$2"
  # reset tickets.md each run (a resolved ticket gets bookkept/deleted)
  cat > "$T/tickets.md" <<'EOF'
# Tickets
---
## #1 — simple resolved ticket with a PR on the auto-merge repo
**Severity:** Medium — x.
body1
---
EOF
  rm -rf "$T/wt"/*
  set +e
  local envassign=()
  [[ -n "$mode" ]] && envassign=(GOVERN_AUTONOMY="$mode")
  PATH="$T/bin:$PATH" env "${envassign[@]}" \
    GOVERN_WS_ROOT="$T" \
    GOVERN_TICKETS_FILE="$T/tickets.md" \
    GOVERN_ESCALATIONS_FILE="$T/governor/escalations.md" \
    GOVERN_WORKER_PROMPT_FILE="$T/governor/worker-prompt.md" \
    GOVERN_PREFERENCES_FILE="$T/governor/preferences.md" \
    GOVERN_SUPERVISOR_PROMPT_FILE="$T/governor/supervisor-prompt.md" \
    GOVERN_LOG_ROOT="$logdir" \
    GOVERN_HISTORY_FILE="$logdir/history.jsonl" \
    GOVERN_LOCK="$logdir/lock" \
    GOVERN_WORKTREE_CMD="$T/wt.sh" \
    GOVERN_CLAUDE_BIN="$T/bin/claude" \
    GOVERN_SKIP_CI=1 GOVERN_SUPERVISOR_EVERY=99 GOVERN_IMPROVE=0 \
    bash "$RL" 1 </dev/null 2>&1
  set -e
}

# auto → the PR merges.
out_auto="$(run_loop auto "$T/logs-auto")"
assert_contains "$out_auto" "merged alpha#101" "auto: the auto-merge-repo PR is MERGED by the governor"

# pr-only → the PR is LEFT OPEN (never merged), surfaced as pr-only-left-open; ticket still resolved.
out_pr="$(run_loop pr-only "$T/logs-pr")"
if grep -qF "merged alpha#101" <<<"$out_pr"; then
  printf 'FAIL - %s\n' "pr-only does NOT merge the PR"; ASSERT_FAILS=$((ASSERT_FAILS+1))
else printf 'ok   - %s\n' "pr-only does NOT merge the PR"; fi
assert_contains "$out_pr" "left open — GOVERN_AUTONOMY=pr-only" "pr-only: PR surfaced as left-open with the autonomy reason"
assert_contains "$out_pr" "[autonomy]" "pr-only: left-open logged with the [autonomy] tag"
remaining="$(grep -c '^## #' "$T/tickets.md" || true)"
assert_eq "$remaining" "0" "pr-only: ticket still bookkept resolved (block deleted) with its PR left open"

assert_done
