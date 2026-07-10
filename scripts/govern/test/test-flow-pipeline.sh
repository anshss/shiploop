#!/usr/bin/env bash
# Flow verdict pipeline end-to-end (validations Phase 2): file-ticket --flow emits the Flow: field →
# ticket_flow_ids reads it → spawn-worker injects the flow block(s) → govern-bookkeep pre-captures the
# Flow field and stamps the registry on resolve.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
command -v git >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || { echo "git/jq absent — skip"; exit 77; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"
mkdir -p "$T/governor" "$T/validation"
export GOVERN_NO_PUSH=1
source "$DIR/../lib/common.sh"

# ── file-ticket --flow: the Flow: field lands in the ticket's leading field block (git-less path).
export GOVERN_TICKETS_FILE="$T/tickets.md" GOVERN_TICKET_SEQ_FILE="$T/.ticket-seq"
: > "$GOVERN_TICKETS_FILE"
n1="$(printf 'Where: x\nDone when: y\n' | "$DIR/../file-ticket.sh" --flow "deploy.correctness" "Validate deploy path" Low)"
assert_contains "$(cat "$T/tickets.md")" "**Flow:** deploy.correctness" "file-ticket --flow emits the Flow: field"
# --model + --flow together, in either order, both land.
n2="$(printf 'body\n' | "$DIR/../file-ticket.sh" --flow "a.b,c.d" --model haiku "Two flows" Low)"
tblk="$(govern::ticket_block "$n2" "$T/tickets.md")"
assert_contains "$tblk" "**Model:** haiku" "file-ticket: --model still lands alongside --flow"
assert_contains "$tblk" "**Flow:** a.b,c.d" "file-ticket: --flow comma-list lands"

# ── ticket_flow_ids: parses the Flow field (comma → space), anchored to the leading block.
assert_eq "$(govern::ticket_flow_ids "$n1" "$T/tickets.md")" "deploy.correctness" "ticket_flow_ids: single id"
assert_eq "$(govern::ticket_flow_ids "$n2" "$T/tickets.md")" "a.b c.d" "ticket_flow_ids: comma-list → space-list"

# ── spawn-worker: injects the FULL flow block + the flowIds reminder for a Flow ticket.
cat > "$T/validation/flows.md" <<'EOF'
## deploy.correctness
- **Kind:** correctness
- **Surface:** console UI → backend
- **Paths:** backend/**
- **Status:** UNTESTED
EOF
cat > "$T/tickets2.md" <<'EOF'
## #5 — VALIDATION: deploy path
**Severity:** Medium
**Flow:** deploy.correctness

Drive the real deploy.
---
EOF
printf 'DOCTRINE\n' > "$T/governor/preferences.md"
printf 'HEADER {{TICKET_BLOCK}} REPORT={{REPORT_PATH}}\n' > "$T/governor/worker-prompt.md"
cat > "$T/fake-wt.sh" <<EOF
#!/usr/bin/env bash
mkdir -p "$T/wt/\$1"; echo "$T/wt/\$1"
EOF
chmod +x "$T/fake-wt.sh"
cat > "$T/fake-claude.sh" <<EOF
#!/usr/bin/env bash
prompt=""; while [[ \$# -gt 0 ]]; do [[ "\$1" == "-p" ]] && { prompt="\$2"; shift 2; continue; }; shift; done
printf '%s' "\$prompt" > "$T/seen.txt"
printf '{"type":"result","result":"{\\"status\\":\\"resolved\\"}"}\n'
EOF
chmod +x "$T/fake-claude.sh"
GOVERN_TICKETS_FILE="$T/tickets2.md" GOVERN_PREFERENCES_FILE="$T/governor/preferences.md" \
  GOVERN_WORKER_PROMPT_FILE="$T/governor/worker-prompt.md" GOVERN_LOG_ROOT="$T/logs" \
  GOVERN_WORKTREE_CMD="$T/fake-wt.sh" GOVERN_CLAUDE_BIN="$T/fake-claude.sh" \
  "$DIR/../spawn-worker.sh" 5 >/dev/null 2>&1
seen="$(cat "$T/seen.txt")"
assert_contains "$seen" "Flow(s) this ticket validates" "spawn-worker: injects the flow-validation section"
assert_contains "$seen" "## deploy.correctness" "spawn-worker: injects the full flow block"
assert_contains "$seen" "(echo: deploy.correctness)" "spawn-worker: reminds the worker to echo flowIds"

# ── govern-bookkeep: pre-captures Flow + stamps the registry PASS on resolve, and deletes the ticket.
M="$T/m"; mkdir -p "$M/queue" "$M/validation" "$M/backend"
git init -q "$M"; git -C "$M" config user.email ci@test; git -C "$M" config user.name ci
git init -q "$M/backend"; git -C "$M/backend" config user.email ci@test; git -C "$M/backend" config user.name ci
printf 'app\n' > "$M/backend/a.txt"; git -C "$M/backend" add -A; git -C "$M/backend" commit -q -m c1
BSHA="$(git -C "$M/backend" rev-parse HEAD)"
cat > "$M/validation/flows.md" <<'EOF'
## deploy.correctness
- **Kind:** correctness
- **Surface:** UI → backend
- **Paths:** backend/**
- **Status:** UNTESTED
EOF
cat > "$M/queue/tickets.md" <<'EOF'
## #12 — VALIDATION: deploy path
**Severity:** Medium
**Flow:** deploy.correctness

Drive the real deploy.
---
EOF
git -C "$M" add -A; git -C "$M" commit -q -m seed
rep="$(jq -nc --arg s "$BSHA" '{status:"resolved",pr:{repo:"backend",number:3,url:"https://github.com/acme/backend/pull/3"},newTickets:[],validation:{ranLiveTest:true,evidence:"drove real deploy; PASS",environment:"prod",validatedShas:{backend:$s}}}')"
printf '%s' "$rep" | GOVERN_TICKETS_FILE="$M/queue/tickets.md" GOVERN_GOVERNOR_DIR="$M/governor" \
  GOVERNOR_DIR="$M/governor" "$DIR/../govern-bookkeep.sh" 12 >/dev/null 2>&1
assert_eq "$(govern::flow_field deploy.correctness Status "$M/validation/flows.md")" "PASS" "bookkeep: stamped the flow PASS on resolve"
assert_contains "$(govern::flow_field deploy.correctness Validated "$M/validation/flows.md")" "backend@${BSHA:0:7}" "bookkeep: pinned the validated SHA"
if grep -q "^## #12" "$M/queue/tickets.md"; then del=1; else del=0; fi
assert_eq "$del" "0" "bookkeep: deleted the resolved ticket block"

assert_done
