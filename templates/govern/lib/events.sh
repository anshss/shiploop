#!/usr/bin/env bash
# Append-only fleet event log. Source, don't execute — common.sh sources this.
#
# WHY THIS EXISTS
# Governor workers are detached `claude -p` processes. Their pid lives only in a bash array
# inside run-loop.sh, and structured state is written only at COMPLETION — so while a fleet is
# running, nothing on disk says "running", and no surface (status command, statusline, plugin
# monitor) has anything to render. This file is the one source of truth those surfaces fold.
#
# HARD CONTRACT — the emitter can NEVER abort a governor run.
# Every govern:: caller runs under `set -euo pipefail`. A broken emitter (unwritable governor/,
# full disk, a malformed key) that returned non-zero would kill the RUN, which is a catastrophic
# trade for a telemetry line. So the whole body runs inside a `{ … } || true` group (bash
# suspends errexit for every command in a compound whose status is tested) and the function ends
# with an explicit `return 0` (root CLAUDE.md rule 11 — a function whose last statement is a bare
# `[[ c ]] && cmd` returns the TEST's status and aborts the caller).
#
# OFF BY DEFAULT (rule 12). GOVERN_EVENTS=1 opts in. Nothing about a run changes at 0 beyond a
# handful of no-op function calls.

# Opt-in switch and the log location. GOVERNOR_DIR comes from common.sh; the fallback keeps this
# file sourceable standalone (the tests do exactly that).
GOVERN_EVENTS="${GOVERN_EVENTS:-0}"
GOVERN_EVENTS_FILE="${GOVERN_EVENTS_FILE:-${GOVERNOR_DIR:-.}/events.jsonl}"

# Minimal JSON string escaper. Pure bash parameter expansion — no subprocess, so emitting an event
# costs nothing measurable and cannot fail on a fork limit. Covers backslash, quote, and the three
# whitespace control characters that actually appear in governor values (a ticket title, a park
# reason, a retry-class sentence). Other C0 controls are deliberately NOT handled: nothing the
# governor emits contains them, and a bracket-range strip is locale-collation dependent — a
# portability trap worse than the case it would guard.
govern::_event_jesc() { # <string> -> escaped, WITHOUT surrounding quotes
  local s="${1-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
  return 0
}

# The run identifier stamped on every line. Precedence:
#   GOVERN_EVENT_RUN_ID  — explicit override (tests)
#   TJ_RUN_ID            — the TokenJam run id run-loop.sh exports; the same id every worker of a
#                          run is tagged with, so events join cleanly against OTel data
#   GOVERN_RUN_DIR       — basename of the run dir (a spawn-worker inherits this even standalone)
#   adhoc-$$             — a manual invocation outside any run
govern::_event_run_id() {
  local rid="${GOVERN_EVENT_RUN_ID:-${TJ_RUN_ID:-}}"
  if [[ -z "$rid" && -n "${GOVERN_RUN_DIR:-}" ]]; then rid="${GOVERN_RUN_DIR##*/}"; fi
  if [[ -z "$rid" ]]; then rid="adhoc-$$"; fi
  printf '%s' "$rid"
  return 0
}

# govern::event <type> [key=value ...]
#
# Appends ONE JSON object per line to $GOVERN_EVENTS_FILE. Always-on fields, always in this order:
#   {"ts":<epoch>,"run_id":"<id>","type":"<type>", …extras}
# `ts` first and every later key preceded by a comma is load-bearing: the readers locate a field by
# searching for `,"key":` (or `{"key":`), which an ESCAPED quote inside a string value can never
# false-match. Values that look like an integer or a JSON literal are emitted bare (so `pid` and
# `elapsed` are numbers a consumer can compare); everything else is a quoted string.
#
# The append is a single `printf >>`. On every platform the governor runs on, an O_APPEND write
# below PIPE_BUF (4096 on macOS/Linux) is atomic, so two concurrent drivers can append to the same
# log without interleaving a line. Event lines are far below that; a pathological long value is
# truncated (see GOVERN_EVENT_MAX_LINE) rather than risking a torn line.
govern::event() { # <type> [k=v ...]
  {
    [[ "${GOVERN_EVENTS:-0}" == "1" ]] || return 0
    local file type line kv k v maxlen
    file="${GOVERN_EVENTS_FILE:-${GOVERNOR_DIR:-.}/events.jsonl}"
    type="${1:-unknown}"
    shift 2>/dev/null || true
    line="{\"ts\":$(date +%s),\"run_id\":\"$(govern::_event_jesc "$(govern::_event_run_id)")\",\"type\":\"$(govern::_event_jesc "$type")\""
    for kv in "$@"; do
      [[ "$kv" == *=* ]] || continue
      k="${kv%%=*}"; v="${kv#*=}"
      [[ -n "$k" ]] || continue
      # Bare JSON scalar iff it is an integer or one of the three literals — everything else is a
      # quoted string. An `=~` regex, not a `case` glob: the glob forms that approximate `^-?[0-9]+$`
      # all admit something like `1-2`, which would emit a bare token and produce invalid JSON.
      if [[ "$v" == "true" || "$v" == "false" || "$v" == "null" || "$v" =~ ^-?[0-9]+$ ]]; then
        line+=",\"$(govern::_event_jesc "$k")\":$v"
      else
        line+=",\"$(govern::_event_jesc "$k")\":\"$(govern::_event_jesc "$v")\""
      fi
    done
    line+="}"
    maxlen="${GOVERN_EVENT_MAX_LINE:-3500}"
    if [[ "${#line}" -gt "$maxlen" ]]; then line="${line:0:$((maxlen-2))}\"}"; fi
    mkdir -p "$(dirname "$file")" 2>/dev/null || true
    printf '%s\n' "$line" >> "$file" 2>/dev/null || true
  } 2>/dev/null || true
  return 0
}

# The awk field extractor every reader shares (status.sh, statusline-segment.sh, the plugin
# monitor). Emitted as a text blob so each consumer can prepend it to its own awk program — bash
# has no way to share an awk function otherwise, and three divergent copies of a JSON scanner is
# exactly the drift this avoids.
#
# jget(line, key) returns the scalar value of `key`, or "" when absent. It anchors on `{"key":` /
# `,"key":`, so a key name appearing INSIDE a string value (where every quote is backslash-escaped)
# cannot false-match. Only valid on lines this emitter wrote: flat, one level deep, no nesting.
govern::event_awk_lib() {
  cat <<'AWKLIB'
function jget(line, key,   pat, i, s, c, out, esc, n) {
  pat = "\"" key "\":"
  i = index(line, "{" pat)
  if (i > 0) { i = i + 1 } else {
    i = index(line, "," pat)
    if (i == 0) return ""
    i = i + 1
  }
  s = substr(line, i + length(pat))
  if (substr(s, 1, 1) == "\"") {
    s = substr(s, 2); out = ""; esc = 0; n = length(s)
    for (i = 1; i <= n; i++) {
      c = substr(s, i, 1)
      if (esc) {
        if (c == "n") out = out "\n"
        else if (c == "t") out = out "\t"
        else if (c == "r") out = out "\r"
        else out = out c
        esc = 0
      } else if (c == "\\") { esc = 1 }
      else if (c == "\"") { break }
      else { out = out c }
    }
    return out
  }
  if (match(s, /^[^,}]*/)) return substr(s, 1, RLENGTH)
  return ""
}
AWKLIB
  return 0
}

# Resolve the workspace event log by walking UP from a directory. Used by every surface that is
# handed a cwd rather than a workspace root (the statusline segment, the plugin monitor): a session
# is usually inside a sub-repo or a worktree, several levels below governor/.
# Prints the path and returns 0 when found; prints nothing and returns 1 otherwise.
govern::event_find_log() { # [start-dir]
  local d="${1:-$PWD}" i=0
  if [[ -n "${GOVERN_EVENTS_FILE:-}" && -f "${GOVERN_EVENTS_FILE:-}" ]]; then
    printf '%s' "$GOVERN_EVENTS_FILE"; return 0
  fi
  d="$(cd "$d" 2>/dev/null && pwd)" || return 1
  while [[ -n "$d" && "$d" != "/" && "$i" -lt 12 ]]; do
    if [[ -f "$d/governor/events.jsonl" ]]; then printf '%s' "$d/governor/events.jsonl"; return 0; fi
    d="$(dirname "$d")"; i=$((i+1))
  done
  return 1
}
