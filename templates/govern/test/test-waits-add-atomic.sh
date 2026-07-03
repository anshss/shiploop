#!/usr/bin/env bash
# Proves govern::waits_add is ATOMIC: a jq failure (corrupt pre-existing pending-waits.json,
# malformed entry) never empties the file. The old code did `printf '%s' "$cur" | jq -c … > $f`
# which truncates $f BEFORE jq runs — a jq exit non-zero left $f as an EMPTY file, evaporating
# every #119 deferral. The fix is tmp+mv (matches na_skip_bump / waits_remove).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"
mkdir -p "$T/governor"

export GOVERN_TICKETS_FILE="$T/tickets.md" \
       GOVERN_PENDING_WAITS_FILE="$T/governor/pending-waits.json"
source "$DIR/../lib/common.sh"

# ── Seed a CORRUPT existing pending-waits.json — non-JSON garbage.
printf 'this is not JSON — a partial write from a killed prior driver\n' > "$T/governor/pending-waits.json"
before_bytes="$(wc -c < "$T/governor/pending-waits.json" | tr -d ' ')"

# Attempt to add a well-formed entry. The jq pipeline chokes on the corrupt current content
# and returns non-zero. With the OLD code, the file would already have been truncated to 0
# bytes by the redirect BEFORE jq ran → every persisted wait would evaporate. With the fix
# (tmp+mv), the target file is untouched until jq succeeds.
govern::waits_add '{"ticket":98,"pr":5,"repo":"harness"}' || true

after_bytes="$(wc -c < "$T/governor/pending-waits.json" | tr -d ' ')"
assert_eq "$after_bytes" "$before_bytes" "corrupt pending-waits.json is NOT truncated by a failing waits_add"

# ── Now reset to a well-formed file with an existing wait, add a second, verify both survive.
printf '{"waits":[{"ticket":50,"pr":100,"repo":"harness"}]}\n' > "$T/governor/pending-waits.json"
govern::waits_add '{"ticket":98,"pr":5,"repo":"harness"}'
cnt="$(jq '.waits | length' "$T/governor/pending-waits.json" 2>/dev/null || echo 0)"
assert_eq "$cnt" "2" "waits_add appends alongside existing entries when the file is valid"

# ── An invalid entry (missing ticket) is a no-op — file must be unchanged, not truncated.
before2="$(cat "$T/governor/pending-waits.json")"
govern::waits_add '{"pr":1,"repo":"harness"}' || true
after2="$(cat "$T/governor/pending-waits.json")"
assert_eq "$after2" "$before2" "waits_add with no ticket field is a no-op (file preserved)"

assert_done
