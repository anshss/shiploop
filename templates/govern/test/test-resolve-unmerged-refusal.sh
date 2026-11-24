#!/usr/bin/env bash
# A report that NAMES a PR but produces no merge row is a two-consumers-of-one-field contradiction,
# not a PR-less resolve. The old "no PR found" branch LANDED anyway: it deleted the queue block
# against a PR that never merged and printed success. It now REFUSES with exit 13 — NOT 12, which
# the queue foreign-changes guard owns — leaving tickets.md byte-identical and nothing merged.
# Proven at the script level with stubbed collaborators, both directions:
#   refuse:  a named harness PR that gh cannot confirm open (the row never reaches the merge set).
#   control: the SAME report shape when gh CAN confirm the PR open — it merges and lands.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

RT="$DIR/../resolve-ticket.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T" "alpha"
export GOVERN_QUEUE_DIR="$T/queue"
mkdir -p "$T/bin/lib" "$T/queue" "$T/bin"
( cd "$T" && git init -q && git config user.email t@t && git config user.name t )
git -C "$T" remote add origin https://github.com/acme/harness.git

cp "$RT" "$T/bin/resolve-ticket.sh"
cp "$DIR/../lib/common.sh" "$T/bin/lib/common.sh"
[[ -f "$DIR/../lib/flows.sh" ]] && cp "$DIR/../lib/flows.sh" "$T/bin/lib/"
[[ -f "$DIR/../post-merge-check.sh" ]] && cp "$DIR/../post-merge-check.sh" "$T/bin/"

LANDED="$T/landed.log"; MERGED="$T/merged.log"
cat > "$T/bin/land-resolution.sh" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
printf 'landed %s\n' "${1:-}" >> "$LANDED_LOG"
exit 0
STUB
cat > "$T/bin/await-ci.sh" <<'STUB'
#!/usr/bin/env bash
printf 'green\n'; exit 0
STUB
cat > "$T/bin/merge-pr.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s#%s\n' "$1" "$2" >> "$MERGED_LOG"
exit 0
STUB
chmod +x "$T/bin"/*.sh
export LANDED_LOG="$LANDED" MERGED_LOG="$MERGED"

# gh stub: `pr view 77` reports OPEN; every other lookup finds nothing.
cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
num=""
prev=""
q=""
for a in "$@"; do
  [[ "$prev" == "view" && "$a" =~ ^[0-9]+$ ]] && num="$a"
  [[ "$prev" == "-q" ]] && q="$a"
  prev="$a"
done
if [[ "$num" == "77" ]]; then
  case "$q" in
    *.state) printf 'OPEN\n' ;;
    *.url)   printf 'https://github.com/acme/harness/pull/77\n' ;;
    *)       printf '{"state":"OPEN","url":"https://github.com/acme/harness/pull/77"}\n' ;;
  esac
  exit 0
fi
exit 1
STUB
chmod +x "$T/bin/gh"

cat > "$T/queue/tickets.md" <<'TIX'
# Tickets

## #50 — some ticket

**Severity:** Medium

Done when: it is done.

---
TIX
( cd "$T" && git add -A && git commit -qm init )
SNAPSHOT="$(cat "$T/queue/tickets.md")"

run_rt() { # <ticket> <report-json> -> sets RC and OUT
  OUT="$( cd "$T" && printf '%s' "$2" | PATH="$T/bin:$PATH" bash "$T/bin/resolve-ticket.sh" "$1" 2>&1 )"
  RC=$?
}

# 1. Refuse: the report names a PR but nothing reaches the merge set.
run_rt 50 '{"status":"resolved","pr":{"repo":"harness","number":9,"url":"https://github.com/acme/harness/pull/9"}}'
assert_eq "$RC" "13" "a named PR that never reaches the merge set refuses with exit 13 (not the queue guard's 12)"
assert_contains "$OUT" "the two consumers of the same field disagree" "the refusal explains the contradiction"
assert_contains "$OUT" "NOT landing" "the refusal says nothing was landed"
assert_eq "$(cat "$T/queue/tickets.md")" "$SNAPSHOT" "the queue block is untouched by the refusal"
assert_not_contains "$(cat "$LANDED" 2>/dev/null || true)" "landed 50" "nothing was bookkept as landed"
assert_not_contains "$(cat "$MERGED" 2>/dev/null || true)" "harness#9" "nothing was merged"

# 2. Control: the SAME report shape with a gh-confirmed OPEN PR merges and lands.
run_rt 50 '{"status":"resolved","pr":{"repo":"harness","number":77,"url":"https://github.com/acme/harness/pull/77"}}'
assert_eq "$RC" "0" "a gh-confirmed open named PR merges and lands (control)"
assert_contains "$(cat "$MERGED" 2>/dev/null || true)" "harness#77" "the confirmed PR reached the merge path"
assert_contains "$(cat "$LANDED" 2>/dev/null || true)" "landed 50" "the resolution landed (control)"

assert_done
