#!/usr/bin/env bash
# govern::event — the fleet event log emitter (lib/events.sh).
#
# Contract:
#   1. OFF by default. GOVERN_EVENTS unset/0 writes nothing at all (rule 12).
#   2. GOVERN_EVENTS=1 appends one valid JSON object per line, with ts/run_id/type always present.
#   3. Integers and JSON literals are emitted bare; everything else is a quoted string.
#   4. Values containing quotes/backslashes/newlines stay valid JSON.
#   5. THE LOAD-BEARING ONE: a failing emitter can NEVER abort a caller running `set -euo pipefail`.
#      An unwritable log, a read-only parent, a garbage key — the caller keeps going.
#   6. The shared awk field extractor reads back exactly what was written, and cannot be fooled by a
#      key name appearing INSIDE a string value.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

T="$(mktemp -d)"; trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
mk_ws_stub "$T"
mkdir -p "$T/governor"

EV="$T/governor/events.jsonl"

# ── 1. off by default ───────────────────────────────────────────────────────────────────────────
env -u GOVERN_EVENTS GOVERN_WS_ROOT="$T" GOVERN_EVENTS_FILE="$EV" bash -c '
  set -euo pipefail
  source "'"$DIR"'/../lib/common.sh"
  govern::event worker_spawned ticket=1
' </dev/null >"$T/off.log" 2>&1
assert_eq "$?" "0" "emitter: sourcing + calling with GOVERN_EVENTS unset exits clean"
assert_eq "$([[ -f "$EV" ]] && echo yes || echo no)" "no" "emitter: writes NOTHING when GOVERN_EVENTS is unset"

GOVERN_EVENTS=0 GOVERN_WS_ROOT="$T" GOVERN_EVENTS_FILE="$EV" bash -c '
  set -euo pipefail
  source "'"$DIR"'/../lib/common.sh"
  govern::event worker_spawned ticket=1
' </dev/null >/dev/null 2>&1
assert_eq "$([[ -f "$EV" ]] && echo yes || echo no)" "no" "emitter: writes NOTHING when GOVERN_EVENTS=0"

# ── 2/3/4. enabled: shape, typing, escaping ─────────────────────────────────────────────────────
GOVERN_EVENTS=1 GOVERN_WS_ROOT="$T" GOVERN_EVENTS_FILE="$EV" GOVERN_EVENT_RUN_ID="run-xyz" bash -c '
  set -euo pipefail
  source "'"$DIR"'/../lib/common.sh"
  govern::event worker_spawned ticket=94 model=opus effort=high pid=4242 timeout=3600
  govern::event worker_done ticket=94 status=resolved tokens=null ok=true elapsed=-5
  govern::event ticket_parked ticket=94 "note=he said \"no\" — path C:\\tmp
second line"
' </dev/null >"$T/on.log" 2>&1
assert_eq "$?" "0" "emitter: enabled emit under set -euo pipefail exits clean"

lines="$(wc -l < "$EV" | tr -d ' ')"
assert_eq "$lines" "3" "emitter: three calls append exactly three lines"

if command -v jq >/dev/null 2>&1; then
  jq -e . "$EV" >/dev/null 2>&1
  assert_eq "$?" "0" "emitter: every line is valid JSON (jq)"
  assert_eq "$(jq -r 'select(.type=="worker_spawned") | "\(.run_id)|\(.pid)|\(.model)"' "$EV")" \
    "run-xyz|4242|opus" "emitter: run_id/pid/model round-trip"
  assert_eq "$(jq -r 'select(.type=="worker_spawned") | .pid | type' "$EV")" "number" \
    "emitter: an integer value is a JSON number, not a string"
  assert_eq "$(jq -r 'select(.type=="worker_done") | .ok | type' "$EV")" "boolean" \
    "emitter: true/false emit as JSON booleans"
  assert_eq "$(jq -r 'select(.type=="worker_done") | .tokens | type' "$EV")" "null" \
    "emitter: the literal null emits as JSON null"
  assert_eq "$(jq -r 'select(.type=="worker_done") | .elapsed' "$EV")" "-5" \
    "emitter: a negative integer stays a bare number"
  assert_eq "$(jq -r 'select(.type=="worker_done") | .status | type' "$EV")" "string" \
    "emitter: a non-numeric value is a JSON string"
  assert_contains "$(jq -r 'select(.type=="ticket_parked") | .note' "$EV")" 'he said "no"' \
    "emitter: an embedded double quote survives the round trip"
  assert_contains "$(jq -r 'select(.type=="ticket_parked") | .note' "$EV")" 'C:\tmp' \
    "emitter: an embedded backslash survives the round trip"
  assert_eq "$(jq -r 'select(.type=="ticket_parked") | .note' "$EV" | wc -l | tr -d ' ')" "2" \
    "emitter: an embedded newline is escaped, not a torn log line"
  assert_eq "$(jq -rs 'map(.ts | type) | unique | join(",")' "$EV")" "number" \
    "emitter: ts is a number on every line"
fi

# ── 5. an emitter failure can never abort the caller ────────────────────────────────────────────
# Unwritable log directory: the append fails on every call. The caller must still reach its final
# marker under `set -euo pipefail` — this is the whole reason govern::event exists as a guarded
# group with an explicit `return 0` (root CLAUDE.md rule 11).
RO="$T/readonly"; mkdir -p "$RO"; chmod 500 "$RO"
out="$(GOVERN_EVENTS=1 GOVERN_WS_ROOT="$T" GOVERN_EVENTS_FILE="$RO/events.jsonl" bash -c '
  set -euo pipefail
  source "'"$DIR"'/../lib/common.sh"
  govern::event worker_spawned ticket=1
  govern::event worker_done ticket=1 status=resolved
  echo REACHED_THE_END
' </dev/null 2>&1)"
rc=$?
chmod 700 "$RO"
assert_eq "$rc" "0" "never-abort: an unwritable event log leaves the caller's exit status at 0"
assert_contains "$out" "REACHED_THE_END" "never-abort: the caller runs to completion with a broken emitter"

# A malformed argument (no `=`) is skipped, not fatal; a bare `k=` is an empty string, not a syntax error.
out="$(GOVERN_EVENTS=1 GOVERN_WS_ROOT="$T" GOVERN_EVENTS_FILE="$T/governor/garbage.jsonl" bash -c '
  set -euo pipefail
  source "'"$DIR"'/../lib/common.sh"
  govern::event worker_spawned notakvpair ticket=7 empty=
  echo REACHED_THE_END
' </dev/null 2>&1)"
assert_eq "$?" "0" "never-abort: a malformed k=v argument does not abort the caller"
assert_contains "$out" "REACHED_THE_END" "never-abort: malformed argument path runs to completion"
if command -v jq >/dev/null 2>&1; then
  jq -e . "$T/governor/garbage.jsonl" >/dev/null 2>&1
  assert_eq "$?" "0" "never-abort: the line written despite a malformed argument is still valid JSON"
  assert_eq "$(jq -r '.notakvpair // "absent"' "$T/governor/garbage.jsonl")" "absent" \
    "never-abort: the malformed argument is dropped, not emitted as a key"
fi

# Emitting with NO type argument at all must not abort either.
out="$(GOVERN_EVENTS=1 GOVERN_WS_ROOT="$T" GOVERN_EVENTS_FILE="$T/governor/notype.jsonl" bash -c '
  set -euo pipefail
  source "'"$DIR"'/../lib/common.sh"
  govern::event
  echo REACHED_THE_END
' </dev/null 2>&1)"
assert_contains "$out" "REACHED_THE_END" "never-abort: govern::event with no arguments does not abort the caller"

# ── 6. the shared awk extractor ─────────────────────────────────────────────────────────────────
# The false-match trap: a string VALUE that contains the text `"ticket":`. Because every quote inside
# a value is backslash-escaped, the extractor's `{"key":` / `,"key":` anchor must skip it.
GOVERN_EVENTS=1 GOVERN_WS_ROOT="$T" GOVERN_EVENTS_FILE="$T/governor/tricky.jsonl" GOVERN_EVENT_RUN_ID=r1 bash -c '
  set -euo pipefail
  source "'"$DIR"'/../lib/common.sh"
  govern::event worker_done note="a body containing \"ticket\":999 verbatim" ticket=42 status=resolved
' </dev/null >/dev/null 2>&1

# Build the extractor program in a file: the shared lib plus one action line. (Assembling it in a
# nested command substitution inside a single-quoted string is a quoting maze — a temp file is the
# readable version and matches how status.sh composes the same two pieces.)
GOVERN_WS_ROOT="$T" bash -c 'source "'"$DIR"'/../lib/common.sh"; govern::event_awk_lib' > "$T/lib.awk" 2>/dev/null
printf '%s\n' '{ print jget($0,"ticket") "|" jget($0,"type") "|" jget($0,"run_id") "|" jget($0,"status") }' >> "$T/lib.awk"
got="$(awk -f "$T/lib.awk" "$T/governor/tricky.jsonl")"
assert_eq "$got" "42|worker_done|r1|resolved" \
  "awk lib: extracts the real fields and is NOT fooled by a key name inside a string value"

assert_done
