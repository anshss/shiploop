#!/usr/bin/env bash
# One statusline segment describing the running fleet, e.g.
#
#   ⚙ 4/6 · agent_001 opus 22m
#    │ │ │    └ oldest live worker: agent id, tier, elapsed
#    │ │ └──── workers answered so far this run
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

# One awk pass, last-event-wins per (run_id, agent_id): the same fold status.sh uses, inlined here
# so the segment stays a single process. Only the NEWEST run counts (state is reset whenever run_id
# changes), and a finished run emits nothing at all.
#
# Output is TSV on stdout only — no awk `> "/dev/stderr"` (non-portable across BSD awk / mawk) and no
# temp file (a statusline runs on every keystroke-ish update; a temp file per invocation is litter
# and a race):
#   P <agent_id> <agent_type> <since> <model>   one per worker the log claims is live
#   N <answered>                                workers already answered this run
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
  if (rid != cur) { cur = rid; split("", st); split("", atyp); split("", mod); split("", since); split("", doneModel); done = 0; answered = 0 }
  if (typ == "run_done") { done = 1 }
  else if (typ == "worker_spawned") {
    aid = jget($0,"agent_id"); if (aid == "") next
    st[aid] = 1; atyp[aid] = jget($0,"agent_type"); mod[aid] = jget($0,"model"); since[aid] = jget($0,"ts")
  }
  else if (typ == "worker_escalated") { aid = jget($0,"agent_id"); if (aid in mod) mod[aid] = jget($0,"to") }
  else if (typ == "worker_done") {
    aid = jget($0,"agent_id"); if (aid == "") next
    st[aid] = 0; answered++
    # Tier mix (the terse counterpart of `status.sh`s full "by source": this stays a raw
    # MODEL tally, not the full model_source string, on purpose: one more awk pass is affordable,
    # but the segment must stay a single glance, and model_source prose is not.
    dm = jget($0,"model"); if (dm != "") doneModel[dm]++
  }
}
END {
  if (done) exit 0
  for (aid in st) if (st[aid] == 1) printf "P\t%s\t%s\t%s\t%s\n", aid, atyp[aid], since[aid], mod[aid]
  printf "N\t%d\n", answered
  for (m in doneModel) printf "M\t%s\t%s\n", m, doneModel[m]
}
' "$LOG" 2>/dev/null)"

[[ -n "$OUT" ]] || exit 0

# Verify liveness. A spawn with no matching done is a CLAIM, not a fact: a worker that went quiet
# without reaching SubagentStop (a killed session, an OOM) leaves it in the log forever, and a
# statusline still reading "4 workers" an hour after the fleet died is worse than silence. A worker
# is an in-session subagent with no pid of its own, so age is the arbiter instead of `kill -0`: a
# claim older than GOVERN_WORKER_STALE_S is treated as dead. Same knob status.sh uses for its own
# reap, so the two surfaces can't disagree. Kill switch: GOVERN_STATUSLINE_STALE_CHECK=0.
NOW="$(date +%s)"
_STALE_WORKER_S="${GOVERN_WORKER_STALE_S:-7200}"
_STALE_CHECK="${GOVERN_STATUSLINE_STALE_CHECK:-1}"
LIVE=0; NDONE=0; BEST_A=""; BEST_M=""; BEST_S=0; MIX=""; N_MIX=0
while IFS=$'\t' read -r _k _a _b _c _d; do
  case "${_k:-}" in
    N) NDONE="${_a:-0}" ;;
    M)
      # Tier mix among ALREADY-ANSWERED workers this run: the raw model, not the full
      # model_source (see the fold above). Only ever printed alongside a live worker below (the
      # segment's own silence contract), so this never fires on an idle fleet.
      N_MIX=$((N_MIX+1))
      MIX="${MIX:+$MIX }${_a}${_b:+×$_b}"
      ;;
    P)
      # _a=agent_id _b=agent_type _c=since (spawn ts) _d=model
      [[ "${_c:-0}" -gt 0 ]] 2>/dev/null || continue
      if [[ "$_STALE_CHECK" != "0" ]]; then
        [[ $(( NOW - _c )) -ge "$_STALE_WORKER_S" ]] && continue
      fi
      LIVE=$((LIVE+1))
      if [[ "$BEST_S" -eq 0 || "${_c:-0}" -lt "$BEST_S" ]]; then BEST_S="${_c:-0}"; BEST_A="$_a"; BEST_M="${_d:-}"; fi
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

# A statusline is one line in a narrow terminal, so a long platform-issued agent_id is truncated
# rather than pushing the rest of the segment off-screen.
_trunc() { local s="${1:-}"; if [[ "${#s}" -gt 12 ]]; then printf '%s…' "${s:0:12}"; else printf '%s' "$s"; fi; return 0; }

TOTAL=$((LIVE + NDONE))
printf '%s %s/%s' "${GOVERN_STATUSLINE_ICON:-⚙}" "$LIVE" "$TOTAL"
if [[ -n "$BEST_A" ]]; then
  printf ' · %s' "$(_trunc "$BEST_A")"
  [[ -n "$BEST_M" ]] && printf ' %s' "$BEST_M"
  [[ "${BEST_S:-0}" -gt 0 ]] && printf ' %s' "$(_hms "$(( NOW - BEST_S ))")"
fi
# Only worth a glance once more than one tier answered something THIS run — a single-tier run says
# nothing `$BEST_M` above didn't already. The full breakdown, grouped by model_source with cost, is
# `status.sh`'s "by source" section; this is the one-line hint that it exists.
[[ "$N_MIX" -gt 1 ]] && printf ' · %s' "$MIX"
printf '\n'
exit 0
