#!/usr/bin/env bash
# resolve-ticket.sh's report source: stdin when it carries a report (always wins), else the file
# governor/reports/<N>.json. A refusal names that file and the expected shape.
#
#   1. no stdin + a report file: lands (the queue block is deleted).
#   2. no stdin + no file: refuses, naming the file path and the shape, queue untouched
#      (negative control for 1).
#   3. stdin wins: a file reporting `failed` is ignored when stdin reports `resolved`.
#   4. the file alone, reporting `failed`, is honoured as written (nothing to land, exit 2).
#   5. a file that is not JSON is refused naming the file.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

RT="$DIR/../resolve-ticket.sh"
LR="$DIR/../land-resolution.sh"
[[ -f "$RT" && -f "$LR" ]] || { echo "SKIP: resolve-ticket.sh or land-resolution.sh not found"; exit 77; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; exit 77; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq unavailable"; exit 77; }

TICKET_BODY='# Tickets

## #9 — a ticket with no PR

**Severity:** Medium

Done when: it lands.
'

setup_case() { # sets CASE_T (call un-subshelled: mk_ws_stub exports must reach this shell)
  CASE_T="$(mktemp -d)"
  local t="$CASE_T"
  mk_ws_stub "$t"
  export GOVERN_QUEUE_DIR="$t/queue"
  export GOVERN_ALLOW_EMPTY_RESOLVE=1
  mkdir -p "$t/bin/lib" "$t/queue" "$t/governor/reports"
  git -C "$t" init -q -b main
  git -C "$t" config user.email t@t; git -C "$t" config user.name t
  printf '%s' "$TICKET_BODY" > "$t/queue/tickets.md"
  printf 'governor/\n' > "$t/.gitignore"
  cp "$RT" "$t/bin/resolve-ticket.sh"
  cp "$LR" "$t/bin/land-resolution.sh"
  cp "$DIR/../lib/common.sh" "$t/bin/lib/common.sh"
  [[ -f "$DIR/../lib/flows.sh" ]] && cp "$DIR/../lib/flows.sh" "$t/bin/lib/"
  chmod +x "$t/bin"/*.sh
  git -C "$t" add -A; git -C "$t" commit -qm init
}
run_rt() { # <root> <stdin-text|-> -> combined output; "-" means an empty stdin
  local t="$1" in="$2"
  if [[ "$in" == "-" ]]; then
    ( cd "$t" && GOVERN_INDEX=0 bash "$t/bin/resolve-ticket.sh" 9 </dev/null 2>&1 )
  else
    ( cd "$t" && printf '%s' "$in" | GOVERN_INDEX=0 bash "$t/bin/resolve-ticket.sh" 9 2>&1 )
  fi
}
block_present() { grep -qE '^##[[:space:]]+#9([^0-9]|$)' "$1/queue/tickets.md"; }

setup_case; T1="$CASE_T"
printf '{"status":"resolved"}' > "$T1/governor/reports/9.json"
out="$(run_rt "$T1" -)"; rc=$?
assert_eq "$rc" "0" "1. no stdin, report file present: resolve exits 0"
if block_present "$T1"; then assert_eq present absent "1. the queue block is deleted from the file's report"
else assert_eq absent absent "1. the queue block is deleted from the file's report"; fi
rm -rf "$T1"

setup_case; T2="$CASE_T"
out="$(run_rt "$T2" -)"; rc=$?
assert_eq "$([ "$rc" -ne 0 ] && echo y || echo n)" "y" "2. no stdin and no file: refused"
assert_contains "$out" "$T2/governor/reports/9.json" "2. the refusal names the report file"
assert_contains "$out" "{ status, pr: { repo, number, url } | number, validation, newTickets[] }" "2. the refusal names the expected shape"
if block_present "$T2"; then assert_eq present present "2. the queue block is untouched"
else assert_eq absent present "2. the queue block is untouched"; fi
rm -rf "$T2"

setup_case; T3="$CASE_T"
printf '{"status":"failed"}' > "$T3/governor/reports/9.json"
out="$(run_rt "$T3" '{"status":"resolved"}')"; rc=$?
assert_eq "$rc" "0" "3. stdin resolved beats a file reporting failed: exit 0"
if block_present "$T3"; then assert_eq present absent "3. the stdin report landed"
else assert_eq absent absent "3. the stdin report landed"; fi
rm -rf "$T3"

setup_case; T4="$CASE_T"
printf '{"status":"failed"}' > "$T4/governor/reports/9.json"
out="$(run_rt "$T4" -)"; rc=$?
assert_eq "$rc" "2" "4. the file's own failed status is honoured: nothing to land (exit 2)"
if block_present "$T4"; then assert_eq present present "4. the queue block survives"
else assert_eq absent present "4. the queue block survives"; fi
rm -rf "$T4"

setup_case; T5="$CASE_T"
printf 'worker prose, not json' > "$T5/governor/reports/9.json"
out="$(run_rt "$T5" -)"; rc=$?
assert_eq "$([ "$rc" -ne 0 ] && echo y || echo n)" "y" "5. a non-JSON report file is refused"
assert_contains "$out" "$T5/governor/reports/9.json" "5. the refusal names the file"
rm -rf "$T5"

assert_done
