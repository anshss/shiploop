#!/usr/bin/env bash
# Phase 3 spawn-worker heads-up: a NON-validation ticket (no Flow: field) that touches paths mapped by
# a currently-validated flow gets a ONE-LINE "flows your change may STALE" note injected — never a full
# flow block. A ticket touching unrelated paths gets nothing (zero context cost). Reverting the branch
# (a validation ticket WITH a Flow: field) takes the full-block path instead, not the heads-up.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
command -v git >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || { echo "git/jq absent — skip"; exit 77; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T" "alpha"   # REPOS = (alpha web)
mkdir -p "$T/governor" "$T/.claude/shiploop/validation"
export GOVERN_NO_PUSH=1

# Registry: a PASS flow mapped under alpha/src/pay/**.
cat > "$T/.claude/shiploop/validation/flows.md" <<'EOF'
## checkout.pay
- **Kind:** correctness
- **Surface:** UI → alpha
- **Paths:** alpha/src/pay/**
- **Status:** PASS
- **Validated:** 2026-07-01 · alpha@abc1234 · PR https://x/1
- **Env:** prod
- **Evidence:** .claude/shiploop/validation/evidence/checkout.pay.md
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

run_spawn() { # <tickets-file> <N>
  GOVERN_TICKETS_FILE="$1" GOVERN_PREFERENCES_FILE="$T/governor/preferences.md" \
    GOVERN_WORKER_PROMPT_FILE="$T/governor/worker-prompt.md" GOVERN_LOG_ROOT="$T/logs" \
    GOVERN_WS_ROOT="$T" GOVERN_WORKTREE_CMD="$T/fake-wt.sh" GOVERN_CLAUDE_BIN="$T/fake-claude.sh" \
    "$DIR/../spawn-worker.sh" "$2" >/dev/null 2>&1
}

# ── NON-validation ticket touching alpha/src/pay/ → one-line heads-up, NOT a full block.
cat > "$T/t-overlap.md" <<'EOF'
## #7 — refactor the pay module
**Severity:** Medium
**Where:** alpha/src/pay/charge.ts

Refactor charge handling.
---
EOF
run_spawn "$T/t-overlap.md" 7
seen="$(cat "$T/seen.txt")"
assert_contains "$seen" "Heads-up — flows your change may STALE" "overlap: heads-up injected"
assert_contains "$seen" "checkout.pay" "overlap: names the affected flow"
assert_eq "$(grep -c '## checkout.pay' <<<"$seen" || true)" "0" "overlap: NOT the full flow block (context-flat one-liner)"

# ── NON-validation ticket touching an unrelated path → NO note at all.
cat > "$T/t-unrelated.md" <<'EOF'
## #8 — tweak the docs site
**Severity:** Low
**Where:** web/pages/about.tsx

Wording change.
---
EOF
run_spawn "$T/t-unrelated.md" 8
seen="$(cat "$T/seen.txt")"
assert_eq "$(grep -c 'may STALE' <<<"$seen" || true)" "0" "unrelated path: no heads-up injected (zero context cost)"

# ── Spot-check the OTHER path: a VALIDATION ticket (Flow: field) still gets the FULL block, not the note.
cat > "$T/t-validate.md" <<'EOF'
## #9 — VALIDATION: pay path
**Severity:** Medium
**Flow:** checkout.pay

Drive the real pay flow.
---
EOF
run_spawn "$T/t-validate.md" 9
seen="$(cat "$T/seen.txt")"
assert_contains "$seen" "## checkout.pay" "validation ticket: full flow block injected"
assert_eq "$(grep -c 'may STALE' <<<"$seen" || true)" "0" "validation ticket: heads-up path NOT taken (full-block branch instead)"

assert_done
