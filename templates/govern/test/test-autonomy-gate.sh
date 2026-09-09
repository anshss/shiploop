#!/usr/bin/env bash
# Onboarding mechanisms: the GOVERN_AUTONOMY trust ladder (observe | pr-only | auto). Exercises BOTH
# gate seams the feature touches:
#   A. merge-pr.sh — auto (and an ABSENT/EMPTY knob, for backward compat) merges; observe/pr-only
#      refuse with the distinct exit 6 (refused-by-autonomy) and a clear log line. UNCHANGED.
#   B. resolve-ticket.sh, when merge-pr.sh (stubbed) returns 6, resolve-ticket LANDS the ticket
#      anyway: rc 6 is "left open by design" (that PR is deliberately not this governor's to merge),
#      not a refusal. Refusing to land there would strand every pr-only workspace permanently
#      un-bookkept. Its stderr names the autonomy mode and carries the `[autonomy]` tag.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
MERGE="$DIR/../merge-pr.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"   # alpha auto-mergeable, web frontend; sets NO GOVERN_AUTONOMY (the backward-compat case)

# ── A. merge-pr.sh gate (unchanged) ─────────────────────────────────────────────────────────────
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

# ── B. resolve-ticket.sh gate: merge-pr.sh rc=6 (autonomy-left-open) still LANDS ──────────────────
RT="$DIR/../resolve-ticket.sh"
[[ -f "$RT" ]] || { echo "SKIP: resolve-ticket.sh not found"; exit 77; }

export GOVERN_QUEUE_DIR="$T/queue"
mkdir -p "$T/bin/lib" "$T/queue"
( cd "$T" && git init -q && git config user.email t@t && git config user.name t )

cp "$RT" "$T/bin/resolve-ticket.sh"
cp "$DIR/../lib/common.sh" "$T/bin/lib/common.sh"
[[ -f "$DIR/../lib/flows.sh" ]] && cp "$DIR/../lib/flows.sh" "$T/bin/lib/"

LANDED="$T/landed.log"
cat > "$T/bin/land-resolution.sh" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
printf 'landed %s\n' "${1:-}" >> "$LANDED_LOG"
exit 0
STUB
cat > "$T/bin/await-ci.sh" <<'STUB'
#!/usr/bin/env bash
printf 'green\n'
exit 0
STUB
cat > "$T/bin/merge-pr.sh" <<'STUB'
#!/usr/bin/env bash
exit "${STUB_MERGE_RC:-0}"
STUB
chmod +x "$T/bin"/*.sh
export LANDED_LOG="$LANDED"
landed_count() { [[ -f "$LANDED" ]] || { echo 0; return 0; }; tr -cd '\n' < "$LANDED" | wc -c | tr -d ' '; }

cat > "$T/queue/tickets.md" <<'TIX'
# Tickets

## #1 — simple resolved ticket with a PR on the auto-merge repo

**Severity:** Medium

Done when: x.

---
TIX
( cd "$T" && git add -A && git commit -qm init )

report='{"status":"resolved","pr":{"repo":"alpha","number":101,"url":"http://pr/1"},"prs":[]}'

: > "$LANDED"
out_b="$( cd "$T" && printf '%s' "$report" \
  | STUB_MERGE_RC=6 GOVERN_AUTONOMY=pr-only bash "$T/bin/resolve-ticket.sh" 1 2>&1 )"
rc_b=$?

assert_eq "$rc_b" "0" "resolve-ticket: merge-pr.sh rc=6 (autonomy-left-open) is NOT a refusal, the script still exits 0"
assert_eq "$(landed_count)" "1" "resolve-ticket: the ticket LANDS anyway, that PR is deliberately not this governor's to merge"
assert_contains "$out_b" "left open" "resolve-ticket: stderr says the PR is left open"
assert_contains "$out_b" "GOVERN_AUTONOMY=pr-only" "resolve-ticket: stderr names the autonomy mode"
assert_contains "$out_b" "[autonomy]" "resolve-ticket: left-open logged with the [autonomy] tag"

assert_done
