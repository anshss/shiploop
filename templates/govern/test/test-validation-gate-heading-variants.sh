#!/usr/bin/env bash
# Proves the #67 VALIDATION-EVIDENCE gate — resolve-ticket.sh's step 2, since the loop purge moved
# this check here — fires under HEADING WHITESPACE / PUNCTUATION variance. Previously the gate awk
# required exactly `## #N ` (single space), so a ticket whose heading was `##  #N` (double-space) or
# `## #N—Title` (em-dash with no space between `#N` and title) yielded an empty tblock — the
# VALIDATION|SPIKE grep then missed, and a validation ticket auto-resolved on static code analysis
# with no live-test evidence, defeating the gate. The fix routes the gate through the shared tolerant
# parser (govern::ticket_block), which resolve-ticket.sh still uses unchanged.
#
# Hermetic — resolve-ticket.sh sandboxed next to stubs of merge-pr.sh / await-ci.sh /
# land-resolution.sh, no network, no gh, no real push. Every assertion is on resolve-ticket.sh's own
# exit code + stderr wording and on the synthetic tickets.md fixture this test writes itself.
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
cat > "$T/bin/merge-pr.sh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$T/bin"/*.sh
export LANDED_LOG="$LANDED"
landed_count() { [[ -f "$LANDED" ]] || { echo 0; return 0; }; tr -cd '\n' < "$LANDED" | wc -c | tr -d ' '; }

# #1: heading has DOUBLE-SPACE after `##` (`##  #1`) — a common markdown-formatter drift.
# #2: heading has EM-DASH glued to the number (`## #2—…`) — no space between `#2` and `—`.
# Both are validation tickets; each report below is resolved WITHOUT live-test evidence. If the gate
# parses each block, both must be refused. If the strict old regex is used, both empty-block through
# the gate and would land.
cat > "$T/queue/tickets.md" <<'TIX'
# Tickets
---
##  #1 — VALIDATION/SPIKE: double-space heading trap
**Severity:** High — gates the pillar.
body1
---
## #2—VALIDATION/SPIKE: em-dash glued to number
**Severity:** High — gates the pillar.
body2
---
TIX
( cd "$T" && git add -A && git commit -qm init )

rpt() { printf '{"status":"resolved","pr":{"repo":"alpha","number":%s01,"url":"u"},"prs":[],"validation":null}' "$1"; }

: > "$LANDED"
out1="$( cd "$T" && printf '%s' "$(rpt 1)" | bash "$T/bin/resolve-ticket.sh" 1 2>&1 )"
rc1=$?
out2="$( cd "$T" && printf '%s' "$(rpt 2)" | bash "$T/bin/resolve-ticket.sh" 2 2>&1 )"
rc2=$?

assert_eq "$rc1" "3" "double-space heading #1 still trips the gate (exit 3)"
assert_contains "$out1" "no live-test evidence" "double-space heading #1: gate refuses on the no-evidence wording"
assert_eq "$rc2" "3" "em-dash-glued heading #2 still trips the gate (exit 3)"
assert_contains "$out2" "no live-test evidence" "em-dash-glued heading #2: gate refuses on the no-evidence wording"
assert_eq "$(landed_count)" "0" "no resolve landed — no validation ticket slipped past the gate"

# Both blocks must SURVIVE in tickets.md (the gate refuses before resolve-ticket ever touches the file).
h1="$(grep -cE '^##  +#1 ' "$T/queue/tickets.md" || true)"
h2="$(grep -cE '^## #2—' "$T/queue/tickets.md" || true)"
assert_eq "$h1" "1" "double-space heading #1 remains in tickets.md (gate did NOT skip it)"
assert_eq "$h2" "1" "em-dash-glued heading #2 remains in tickets.md (gate did NOT skip it)"

assert_done
