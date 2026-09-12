#!/usr/bin/env bash
# Fail-closed CI verification, re-targeted at resolve-ticket.sh (the loop
# purge moved this step here): when a resolved ticket's PR is on a merge-repo but its CI state cannot
# be VERIFIED (merge-pr.sh returns rc=4, its "CI state unverifiable" exit), resolve-ticket.sh must
# refuse to land, keep the tickets.md block untouched, exit non-zero, never merge blind. This is the
# regression guard for the pre-fix fail-OPEN where a broken gh looked identical to a checkless repo
# and auto-merged an un-verified PR. Hermetic, resolve-ticket.sh sandboxed next to stubs of
# merge-pr.sh / await-ci.sh / land-resolution.sh, no network, no gh, no real push.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

RT="$DIR/../resolve-ticket.sh"
[[ -f "$RT" ]] || { echo "SKIP: resolve-ticket.sh not found"; exit 77; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"
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
# rc=4, merge-pr.sh's own "CI state UNVERIFIABLE" exit (gh network/auth/rate-limit/5xx).
cat > "$T/bin/merge-pr.sh" <<'STUB'
#!/usr/bin/env bash
exit 4
STUB
chmod +x "$T/bin"/*.sh
export LANDED_LOG="$LANDED"
landed_count() { [[ -f "$LANDED" ]] || { echo 0; return 0; }; tr -cd '\n' < "$LANDED" | wc -c | tr -d ' '; }

cat > "$T/queue/tickets.md" <<'TIX'
# Tickets

## #1 — high one

**Severity:** High

Done when: x.

---
TIX
( cd "$T" && git add -A && git commit -qm init )

report='{"status":"resolved","pr":{"repo":"alpha","number":101,"url":"http://pr/1"},"prs":[]}'
: > "$LANDED"
out="$( cd "$T" && printf '%s' "$report" | bash "$T/bin/resolve-ticket.sh" 1 2>&1 )"
rc=$?

assert_eq "$rc" "5" "unverifiable CI (merge-pr rc=4) is a refusal, resolve-ticket exits 5"
assert_eq "$(landed_count)" "0" "unverifiable CI does not land, land-resolution.sh was never reached"
assert_contains "$out" "CI state could not be verified" "resolve-ticket's own unverifiable-CI wording is surfaced"
remaining="$(grep -c '^## #' "$T/queue/tickets.md" || true)"
assert_eq "$remaining" "1" "ticket #1 block SURVIVES unverifiable CI (fail-closed: never merge blind, never delete the block for a PR whose CI was never verified)"

assert_done
