#!/usr/bin/env bash
# TokenJam cross-session run tagging: every worker spawn-worker.sh launches must carry the run's
# tokenjam.run_id (so TokenJam groups them under one "Run"), a distinct service.instance.id, and
# must NOT clobber any OTEL_RESOURCE_ATTRIBUTES the parent (onboarding/wrapper) already set.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
SPAWN="$DIR/../spawn-worker.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/governor" "$TMP/wt"
# Seed a hermetic workspace.sh + GOVERN_WS_ROOT so spawn-worker's common.sh can source it in
# the template layout (cases 1-3 don't set GOVERN_WS_ROOT; cases 4-5 override it inline). (#255)
mk_ws_stub "$TMP"

cat > "$TMP/tickets.md" <<'EOF'
## #7 — sample ticket A
**Severity:** Medium — test.
Observed: thing A is broken.
---
## #8 — sample ticket B
**Severity:** Medium — test.
Observed: thing B is broken.
---
EOF
printf 'DOCTRINE\n' > "$TMP/governor/preferences.md"
printf 'PROMPT {{TICKET_BLOCK}} {{REPORT_PATH}}\n' > "$TMP/governor/worker-prompt.md"

cat > "$TMP/fake-worktree.sh" <<EOF
#!/usr/bin/env bash
mkdir -p "$TMP/wt/ticket-\$1"; echo "$TMP/wt/ticket-\$1"
EOF
chmod +x "$TMP/fake-worktree.sh"

# Fake claude: record the OTEL_RESOURCE_ATTRIBUTES it was launched with (one line per spawn) to
# $OTEL_SINK, then emit a valid resolved report so spawn-worker returns cleanly.
cat > "$TMP/fake-claude.sh" <<'EOF'
#!/usr/bin/env bash
[[ -n "${OTEL_SINK:-}" ]] && printf '%s\n' "${OTEL_RESOURCE_ATTRIBUTES:-<unset>}" >> "$OTEL_SINK"
report='{"status":"resolved","pr":{"repo":"alpha","number":99,"url":"u"},"newTickets":[],"escalation":null}'
[[ -n "${GOVERN_REPORT_PATH:-}" ]] && printf '%s' "$report" > "$GOVERN_REPORT_PATH"
printf '{"type":"result","result":%s}\n' "$(printf '%s' "$report" | jq -Rs .)"
EOF
chmod +x "$TMP/fake-claude.sh"

run_worker() { # ticket  [extra env assignments...]
  local n="$1"; shift
  GOVERN_TICKETS_FILE="$TMP/tickets.md" \
  GOVERN_PREFERENCES_FILE="$TMP/governor/preferences.md" \
  GOVERN_WORKER_PROMPT_FILE="$TMP/governor/worker-prompt.md" \
  GOVERN_LOG_ROOT="$TMP/logs-$n-$RANDOM" \
  GOVERN_WORKTREE_CMD="$TMP/fake-worktree.sh" \
  GOVERN_CLAUDE_BIN="$TMP/fake-claude.sh" \
  OTEL_SINK="$SINK" \
  "$@" "$SPAWN" "$n" >/dev/null
}

# --- Case 1: two workers of ONE run share the run id + preserve an inherited attr + get distinct labels ---
SINK="$TMP/sink1"; : > "$SINK"
RUNID="gov-20260618T000000Z-12345"
# inherited attrs the per-terminal wrapper may already have set
run_worker 7 env TJ_RUN_ID="$RUNID" OTEL_RESOURCE_ATTRIBUTES="service.name=claude-code,service.namespace=gov"
run_worker 8 env TJ_RUN_ID="$RUNID" OTEL_RESOURCE_ATTRIBUTES="service.name=claude-code,service.namespace=gov"

line7="$(sed -n 1p "$SINK")"; line8="$(sed -n 2p "$SINK")"
assert_contains "$line7" "service.name=claude-code"        "worker7 preserves inherited service.name (append, not clobber)"
assert_contains "$line7" "service.namespace=gov"           "worker7 preserves inherited service.namespace"
assert_contains "$line7" "tokenjam.run_id=$RUNID"          "worker7 carries the run's tokenjam.run_id"
assert_contains "$line7" "service.instance.id=ticket-7"    "worker7 labelled with its ticket slug"
assert_contains "$line8" "tokenjam.run_id=$RUNID"          "worker8 carries the SAME tokenjam.run_id"
assert_contains "$line8" "service.instance.id=ticket-8"    "worker8 labelled with its own ticket slug"
r7="$(printf '%s' "$line7" | grep -oE 'tokenjam\.run_id=[^,]+')"
r8="$(printf '%s' "$line8" | grep -oE 'tokenjam\.run_id=[^,]+')"
assert_eq "$r7" "$r8" "both workers of one run share one tokenjam.run_id"

# --- Case 2: a pre-existing service.instance.id is NOT overridden by the ticket slug ---
SINK="$TMP/sink2"; : > "$SINK"
run_worker 7 env TJ_RUN_ID="$RUNID" OTEL_RESOURCE_ATTRIBUTES="service.instance.id=preset-label"
l="$(sed -n 1p "$SINK")"
assert_contains "$l" "service.instance.id=preset-label" "existing service.instance.id is kept"
assert_contains "$l" "tokenjam.run_id=$RUNID"           "run id still appended alongside preset label"
slugcount="$(printf '%s' "$l" | grep -c 'service.instance.id=ticket-7' || true)"
assert_eq "$slugcount" "0" "ticket slug does NOT override an existing service.instance.id"

# --- Case 3: no TJ_RUN_ID in env → fall back to the persisted run-id file ---
SINK="$TMP/sink3"; : > "$SINK"
printf 'gov-FROMFILE-999\n' > "$TMP/run-id"
run_worker 8 env -u TJ_RUN_ID GOVERN_RUN_ID_FILE="$TMP/run-id"
l3="$(sed -n 1p "$SINK")"
assert_contains "$l3" "tokenjam.run_id=gov-FROMFILE-999" "standalone worker reads run id from the persisted file"
assert_contains "$l3" "service.instance.id=ticket-8"     "standalone worker still gets a ticket-slug label"

# --- Case 4 & 5: run-loop ADOPTS a fresh run-id file but IGNORES a stale one (#3 freshness guard) ---
# Drive the real run-loop in dry mode against an EMPTY backlog → it sets up (reads/generates the run
# id), finds no eligible tickets, and exits cleanly. We assert on the "TokenJam run id:" log line.
RL="$DIR/../run-loop.sh"
mkdir -p "$TMP/gov2/scripts/lib"
printf '# Tickets\n' > "$TMP/empty-tickets.md"
printf '## Open\n' > "$TMP/gov2/escalations.md"
: > "$TMP/gov2/preferences.md"
# A self-contained mini-workspace: the live common.sh ignores scripts/lib/workspace.sh, the template
# common.sh sources it — so providing it keeps cases 4 & 5 portable across both baselines.
printf '#!/usr/bin/env bash\nREPOS=(backend)\nGITHUB_ORG="ExampleOrg"\nWORKTREE_BASE="%s/gov2.wt"\nwsp_is_merge_repo() { [[ "$1" == "backend" ]]; }\n' "$TMP" > "$TMP/gov2/scripts/lib/workspace.sh"
RIDF="$TMP/gov2/.run-id"
run_loop_dry() {
  GOVERN_WS_ROOT="$TMP/gov2" \
  GOVERN_TICKETS_FILE="$TMP/empty-tickets.md" \
  GOVERN_ESCALATIONS_FILE="$TMP/gov2/escalations.md" \
  GOVERN_PREFERENCES_FILE="$TMP/gov2/preferences.md" \
  GOVERN_LOG_ROOT="$TMP/gov2/logs" \
  GOVERN_RUN_ID_FILE="$RIDF" \
  GOVERN_LOCK="$TMP/gov2/.lock" \
  bash "$RL" --dry-run 2>&1
}

# FRESH: a just-written file (current mtime) is reused verbatim — the resume keeps the id.
printf 'gov-FRESH-1\n' > "$RIDF"
log4="$(run_loop_dry)"
assert_contains "$log4" "TokenJam run id: gov-FRESH-1" "fresh run-id file is reused (resume keeps the id)"

# STALE: a long-old file (mtime backdated past the window) is ignored → a NEW id is generated.
printf 'gov-STALE-1\n' > "$RIDF"
touch -t 202001010000 "$RIDF"
log5="$(run_loop_dry)"
assert_eq "$(printf '%s' "$log5" | grep -c 'TokenJam run id: gov-STALE-1' || true)" "0" "stale run-id file is NOT reused"
assert_contains "$log5" "ignoring stale run-id file" "stale run-id file is explicitly ignored"

assert_done
