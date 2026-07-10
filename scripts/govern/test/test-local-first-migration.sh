#!/usr/bin/env bash
# Proof for #72: on a LOCAL-FIRST repo an ADDITIVE migration ships as auto-applying code (no deployed
# prod DB), so the governor must NOT park it "apply migration to prod manually" — it opens as a normal
# PR and resolves. A DESTRUCTIVE migration on the same repo STILL escalates. Stubbed claude + gh.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
RL="$DIR/../run-loop.sh"

run_case() { # <migration-json> -> run-loop output for a single ticket #1 on local-first repo 'alpha'
  local mig="$1" T; T="$(mktemp -d)"
  mk_ws_stub "$T" "" "alpha"          # alpha = PR-only AND local-first; web = neither
  mkdir -p "$T/bin" "$T/governor" "$T/logs" "$T/wt"
  ( cd "$T" && git init -q && git config user.email t@t && git config user.name t )
  printf '# Tickets\n---\n## #1 — add a table for annotations\n**Severity:** Medium\nbody\n---\n' > "$T/tickets.md"
  printf '## Open\n\n## Resolved\n' > "$T/governor/escalations.md"
  printf '#!/usr/bin/env bash\nmkdir -p "%s/wt/$1"; echo "%s/wt/$1"\n' "$T" "$T" > "$T/wt.sh"; chmod +x "$T/wt.sh"
  printf '#!/usr/bin/env bash\ncase "$*" in *"pr list"*) echo "[]";; *) echo "{}";; esac\n' > "$T/bin/gh"; chmod +x "$T/bin/gh"
  cat > "$T/bin/claude" <<EOF
#!/usr/bin/env bash
prompt=""
while [[ \$# -gt 0 ]]; do [[ "\$1" == "-p" ]] && { prompt="\$2"; shift 2; continue; }; shift; done
printf '%s' "\$prompt" | grep -q 'SUPERVISOR-REVIEW' && { printf '{"type":"result","result":%s}\n' "\$(printf '{"verdict":"ok","concerns":[],"haltReason":null}' | jq -Rs .)"; exit 0; }
report='{"status":"resolved","pr":{"repo":"alpha","number":101,"url":"http://pr/1"},"lessonPatch":null,"newTickets":[],"crossRefs":{"overlaps":[],"dependsOn":[]},"migration":${mig},"validation":null,"escalation":null}'
[[ -n "\${GOVERN_REPORT_PATH:-}" ]] && printf '%s' "\$report" > "\$GOVERN_REPORT_PATH"
printf '{"type":"result","result":%s}\n' "\$(printf '%s' "\$report" | jq -Rs .)"
EOF
  chmod +x "$T/bin/claude"
  PATH="$T/bin:$PATH" GOVERN_TICKETS_FILE="$T/tickets.md" GOVERN_ESCALATIONS_FILE="$T/governor/escalations.md" \
    GOVERN_WORKER_PROMPT_FILE="$GOVERN_PROMPTS_DIR/worker-prompt.md" GOVERN_PREFERENCES_FILE="$GOVERN_PROMPTS_DIR/preferences.md" \
    GOVERN_SUPERVISOR_PROMPT_FILE="$GOVERN_PROMPTS_DIR/supervisor-prompt.md" GOVERN_LOG_ROOT="$T/logs" \
    GOVERN_TICKET_SEQ_FILE="$T/.ticket-seq" GOVERN_LOCK="$T/lock" GOVERN_WORKTREE_CMD="$T/wt.sh" \
    GOVERN_CLAUDE_BIN="$T/bin/claude" GOVERN_ECHO=1 GOVERN_SKIP_CI=1 GOVERN_SUPERVISOR_EVERY=99 GOVERN_IMPROVE=0 \
    bash "$RL" 2>&1
  rm -rf "$T"
}

# ADDITIVE migration on a local-first repo → NO manual-apply park; ships as code; resolves.
add_out="$(run_case '{"needed":true,"destructive":false,"name":"20260610_add_x","note":"ADD TABLE"}')"
assert_contains "$add_out" "ships as auto-applying code on local-first repo" "#72: additive local-first migration is NOT parked"
assert_eq "$(printf '%s' "$add_out" | grep -c 'apply the additive migration to prod manually')" "0" "#72: no spurious 'apply to prod manually' escalation"
assert_contains "$add_out" "resolved=1" "#72: additive local-first ticket resolves (normal PR)"

# DESTRUCTIVE migration on the SAME local-first repo → STILL escalates (parked).
destr_out="$(run_case '{"needed":true,"destructive":true,"name":"20260610_drop_x","note":"DROP COLUMN"}')"
assert_contains "$destr_out" "DESTRUCTIVE prod migration" "#72: destructive migration still escalates on a local-first repo"
assert_contains "$destr_out" "parked=1" "#72: destructive local-first ticket is parked"

assert_done
