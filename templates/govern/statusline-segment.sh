#!/usr/bin/env bash
# One statusline segment describing the running fleet, e.g.
#
#   ⚙ 4/6 · #94 opus 22m
#    │ │ │    └ oldest live worker: ticket, tier, elapsed
#    │ │ └──── tickets answered so far this run
#    │ └────── live workers right now
#
# Reads the statusline stdin JSON (documented fields: `cwd`, `workspace.current_dir`,
# `workspace.project_dir`) and walks UP from there for governor/events.jsonl — a session is
# normally inside a sub-repo or a worktree, several levels below the workspace root.
#
# SILENT when there is no fleet: no log, no run, or a finished run prints NOTHING and exits 0. That
# is the whole contract — a statusline segment that prints noise in every unrelated session is worse
# than no segment at all.
#
# STAT-ONLY AND FAST. Claude Code cancels an in-flight statusline script when a new update triggers,
# and there is no documented timeout, so this does one `stat`-class read and one awk pass: no jq, no
# git, no network, no process spawning beyond awk. It never sources common.sh either — the segment
# must work from ANY cwd, including sessions that have no workspace at all.
set -uo pipefail

IN="$(cat 2>/dev/null || true)"

# Pull a top-level or one-level-nested string field out of the statusline JSON without jq.
_field() { # <json> <path like cwd | workspace.project_dir>
  printf '%s' "$1" | awk -v want="$2" '
    BEGIN{ n=split(want,p,"."); leaf=p[n] }
    { s=$0 }
    END{
      # Statusline JSON is machine-generated and flat enough that locating "leaf":"…" is exact.
      pat = "\"" leaf "\":\""
      i = index(s, pat)
      if (i == 0) { print ""; exit }
      s = substr(s, i + length(pat))
      j = index(s, "\"")
      if (j == 0) { print ""; exit }
      print substr(s, 1, j-1)
    }'
  return 0
}

START=""
for _p in cwd workspace.current_dir workspace.project_dir; do
  _v="$(_field "$IN" "$_p")"
  if [[ -n "$_v" && -d "$_v" ]]; then START="$_v"; break; fi
done
[[ -n "$START" ]] || START="$PWD"

LOG="${GOVERN_EVENTS_FILE:-}"
if [[ -z "$LOG" || ! -f "$LOG" ]]; then
  LOG=""
  _d="$(cd "$START" 2>/dev/null && pwd || true)"
  _i=0
  while [[ -n "$_d" && "$_d" != "/" && "$_i" -lt 12 ]]; do
    if [[ -f "$_d/governor/events.jsonl" ]]; then LOG="$_d/governor/events.jsonl"; break; fi
    _d="$(dirname "$_d")"; _i=$((_i+1))
  done
fi
[[ -n "$LOG" && -s "$LOG" ]] || exit 0

# One awk pass, last-event-wins per (run_id, ticket) — the same fold status.sh uses, inlined here so
# the segment stays a single process. Only the NEWEST run counts (state is reset whenever run_id
# changes), and a finished run emits nothing at all.
#
# Output is TSV on stdout only — no awk `> "/dev/stderr"` (non-portable across BSD awk / mawk) and no
# temp file (a statusline runs on every keystroke-ish update; a temp file per invocation is litter
# and a race):
#   P <ticket> <pid> <since> <model>   one per worker the log claims is live
#   N <answered>                       tickets already answered this run
OUT="$(awk '
function jget(line, key,   pat, i, s, c, out, esc, n) {
  pat = "\"" key "\":"
  i = index(line, "{" pat)
  if (i > 0) { i = i + 1 } else { i = index(line, "," pat); if (i == 0) return ""; i = i + 1 }
  s = substr(line, i + length(pat))
  if (substr(s, 1, 1) == "\"") {
    s = substr(s, 2); out = ""; esc = 0; n = length(s)
    for (i = 1; i <= n; i++) {
      c = substr(s, i, 1)
      if (esc) { out = out c; esc = 0 }
      else if (c == "\\") { esc = 1 }
      else if (c == "\"") { break }
      else { out = out c }
    }
    return out
  }
  if (match(s, /^[^,}]*/)) return substr(s, 1, RLENGTH)
  return ""
}
{
  rid = jget($0, "run_id"); typ = jget($0, "type")
  if (rid == "" || typ == "") next
  if (rid != cur) { cur = rid; split("", st); split("", pid); split("", mod); split("", since); done = 0; answered = 0 }
  if (typ == "run_done") { done = 1 }
  else if (typ == "worker_spawned") {
    t = jget($0,"ticket"); st[t] = 1; pid[t] = jget($0,"pid"); mod[t] = jget($0,"model"); since[t] = jget($0,"ts")
  }
  else if (typ == "worker_escalated") { t = jget($0,"ticket"); if (t in mod) mod[t] = jget($0,"to") }
  else if (typ == "worker_done") { t = jget($0,"ticket"); st[t] = 0; answered++ }
}
END {
  if (done) exit 0
  for (t in st) if (st[t] == 1) printf "P\t%s\t%s\t%s\t%s\n", t, pid[t], since[t], mod[t]
  printf "N\t%d\n", answered
}
' "$LOG" 2>/dev/null)"

[[ -n "$OUT" ]] || exit 0

# Verify liveness. A spawn with no matching done is a CLAIM, not a fact — a killed driver leaves it
# in the log forever, and a statusline still reading "4 workers" an hour after the fleet died is
# worse than silence. `kill -0` is the arbiter, exactly as in status.sh.
LIVE=0; NDONE=0; BEST_T=""; BEST_M=""; BEST_S=0
while IFS=$'\t' read -r _k _a _b _c _d; do
  case "${_k:-}" in
    N) NDONE="${_a:-0}" ;;
    P)
      [[ "${_b:-0}" -gt 0 ]] 2>/dev/null || continue
      kill -0 "$_b" 2>/dev/null || continue
      LIVE=$((LIVE+1))
      if [[ "$BEST_S" -eq 0 || "${_c:-0}" -lt "$BEST_S" ]]; then BEST_S="${_c:-0}"; BEST_T="$_a"; BEST_M="${_d:-}"; fi
      ;;
  esac
done <<<"$OUT"

[[ "$LIVE" -gt 0 ]] || exit 0

_hms() {
  local s="${1:-0}"
  [[ "$s" =~ ^[0-9]+$ ]] || { printf '?'; return 0; }
  if   [[ "$s" -lt 60 ]]; then printf '%ds' "$s"
  elif [[ "$s" -lt 3600 ]]; then printf '%dm' "$((s/60))"
  else printf '%dh%02dm' "$((s/3600))" "$(((s%3600)/60))"; fi
  return 0
}

NOW="$(date +%s)"
TOTAL=$((LIVE + NDONE))
printf '%s %s/%s' "${GOVERN_STATUSLINE_ICON:-⚙}" "$LIVE" "$TOTAL"
if [[ -n "$BEST_T" ]]; then
  printf ' · #%s' "$BEST_T"
  [[ -n "$BEST_M" ]] && printf ' %s' "$BEST_M"
  [[ "${BEST_S:-0}" -gt 0 ]] && printf ' %s' "$(_hms "$(( NOW - BEST_S ))")"
fi
printf '\n'
exit 0
