#!/usr/bin/env bash
# Proof, re-targeted at resolve-ticket.sh (the loop purge moved this step here): on a
# LOCAL-FIRST repo an ADDITIVE migration ships as auto-applying code (no deployed prod DB), so the
# governor must NOT park it "apply migration to prod manually", it lands normally. A DESTRUCTIVE
# migration on the same repo STILL escalates. Hermetic, resolve-ticket.sh sandboxed next to stubs of
# merge-pr.sh / await-ci.sh / land-resolution.sh, no network, no gh, no real push.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

RT="$DIR/../resolve-ticket.sh"
[[ -f "$RT" ]] || { echo "SKIP: resolve-ticket.sh not found"; exit 77; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

mk_sandbox() { # <root> -> writes resolve-ticket.sh + stubs into <root>/bin, tickets.md into <root>/queue
  local root="$1"
  mk_ws_stub "$root" "" "web"            # web = PR-only AND local-first (always a REPOS member, unlike an unmentioned custom repo)
  export GOVERN_QUEUE_DIR="$root/queue"
  mkdir -p "$root/bin/lib" "$root/queue"
  ( cd "$root" && git init -q && git config user.email t@t && git config user.name t )
  cp "$RT" "$root/bin/resolve-ticket.sh"
  cp "$DIR/../lib/common.sh" "$root/bin/lib/common.sh"
  [[ -f "$DIR/../lib/flows.sh" ]] && cp "$DIR/../lib/flows.sh" "$root/bin/lib/"
  cat > "$root/bin/land-resolution.sh" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
printf 'landed %s\n' "${1:-}" >> "$LANDED_LOG"
exit 0
STUB
  cat > "$root/bin/await-ci.sh" <<'STUB'
#!/usr/bin/env bash
printf 'green\n'
exit 0
STUB
  cat > "$root/bin/merge-pr.sh" <<'STUB'
#!/usr/bin/env bash
# web is PR-only in this fixture (mk_ws_stub with an empty merge-csv), a real merge-pr.sh would
# refuse with rc=2. Model that exactly so resolve-ticket sees the same "left open" shape it would live.
exit 2
STUB
  chmod +x "$root/bin"/*.sh
  printf '# Tickets\n\n## #1, add a table for annotations\n\n**Severity:** Medium\n\nbody\n\n---\n' > "$root/queue/tickets.md"
  ( cd "$root" && git add -A && git commit -qm init )
}
landed_count() { local f="$1"; [[ -f "$f" ]] || { echo 0; return 0; }; tr -cd '\n' < "$f" | wc -c | tr -d ' '; }

# ── ADDITIVE migration on a local-first repo → NO manual-apply park; neutralised; lands normally ──
T1="$(mktemp -d)"; mk_sandbox "$T1"
L1="$T1/landed.log"; : > "$L1"
report1='{"status":"resolved","pr":{"repo":"web","number":101,"url":"http://pr/1"},"prs":[],"migration":{"needed":true,"destructive":false,"name":"20260610_add_x","note":"ADD TABLE"}}'
add_out="$( cd "$T1" && printf '%s' "$report1" | LANDED_LOG="$L1" bash "$T1/bin/resolve-ticket.sh" 1 2>&1 )"
add_rc=$?
assert_contains "$add_out" "ships as auto-applying code on local-first repo" "additive local-first migration is NOT parked"
assert_eq "$(printf '%s' "$add_out" | grep -c 'no GOVERN_MIGRATE_CMD is configured')" "0" "no spurious manual-apply escalation (GOVERN_MIGRATE_CMD gate never fires)"
assert_eq "$add_rc" "0" "additive local-first ticket resolves (exit 0)"
assert_eq "$(landed_count "$L1")" "1" "additive local-first ticket lands (normal PR)"
rm -rf "$T1"

# ── DESTRUCTIVE migration on the SAME local-first repo → STILL escalates (parked) ──────────────────
T2="$(mktemp -d)"; mk_sandbox "$T2"
L2="$T2/landed.log"; : > "$L2"
report2='{"status":"resolved","pr":{"repo":"web","number":101,"url":"http://pr/1"},"prs":[],"migration":{"needed":true,"destructive":true,"name":"20260610_drop_x","note":"DROP COLUMN"}}'
destr_out="$( cd "$T2" && printf '%s' "$report2" | LANDED_LOG="$L2" bash "$T2/bin/resolve-ticket.sh" 1 2>&1 )"
destr_rc=$?
assert_contains "$destr_out" "DESTRUCTIVE prod migration" "destructive migration still escalates on a local-first repo"
assert_eq "$destr_rc" "6" "destructive local-first ticket exits 6"
assert_eq "$(landed_count "$L2")" "0" "destructive local-first ticket is parked (never lands)"
rm -rf "$T2"

assert_done
