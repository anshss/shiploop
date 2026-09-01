#!/usr/bin/env bash
# govern:status — what is the fleet doing RIGHT NOW.
#
# One-shot reader over the append-only event log (governor/events.jsonl, written by
# scripts/govern/lib/events.sh when GOVERN_EVENTS=1). Folds the log into live state, verifies every
# claimed-live worker with `kill -0`, reaps the ones whose process is gone, and prints it. Text by
# default, `--json` for machines. No model call, no network, no lock — safe to run from inside a
# Claude session, from CI, or over SSH while a run is mid-flight.
#
# Usage:
#   scripts/govern/status.sh              # text
#   scripts/govern/status.sh --json       # one JSON object on stdout
#   scripts/govern/status.sh --no-reap    # do not append stale markers to the log
#   scripts/govern/status.sh --all-runs   # every run in the log, not just the newest
#
# Exit codes: 0 always when the log is readable (an idle fleet is not an error); 0 with an
# "events log not enabled" note when the log is absent, so a wrapper can call this unconditionally.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib/common.sh"

JSON=0; REAP=1; ALL_RUNS=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)     JSON=1 ;;
    --no-reap)  REAP=0 ;;
    --all-runs) ALL_RUNS=1 ;;
    -h|--help)  sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'unknown argument: %s (try --help)\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

LOG="${GOVERN_EVENTS_FILE:-$GOVERNOR_DIR/events.jsonl}"
NOW="$(date +%s)"

if [[ ! -s "$LOG" ]]; then
  if [[ "$JSON" -eq 1 ]]; then
    printf '{"enabled":false,"log":"%s","runId":null,"active":[],"stale":[],"counts":{},"drivers":[]}\n' "$LOG"
  else
    printf 'fleet: no event log at %s\n' "$LOG"
    printf '       (the log is written only when GOVERN_EVENTS=1 — export it before `%s run govern`)\n' "${ROOT_PM:-npm}"
  fi
  exit 0
fi

# ── the fold ────────────────────────────────────────────────────────────────────────────────────
# ONE awk pass, LAST-EVENT-WINS per (run_id, ticket). That keying is what makes retries correct: a
# ticket spawned → done → spawned again is ACTIVE, and a naive spawned-minus-done count would call
# it idle. Drivers fold the same way on (run_id, label).
#
# Output is TSV so bash can consume it without a second jq pass:
#   RUN <run_id> <started_ts> <done:0|1> <mode> <target>
#   W   <ticket> <pid> <model> <effort> <since_ts>          (last event was worker_spawned)
#   D   <label>  <pid> <since_ts>                            (driver still running)
#   C   <counter> <n>                                        (resolved/parked/failed/… tallies)
FOLD_PROG="$( govern::event_awk_lib; cat <<'AWKMAIN'
{
  line = $0
  rid = jget(line, "run_id"); typ = jget(line, "type"); ts = jget(line, "ts")
  if (rid == "" || typ == "") next
  if (!(rid in seen)) { seen[rid] = 1; order[++nruns] = rid; rstart[rid] = ts }
  rlast[rid] = ts
  if (typ == "run_started") { rmode[rid] = jget(line,"mode"); rtarget[rid] = jget(line,"target"); rstart[rid] = ts }
  else if (typ == "run_done") { rdone[rid] = 1
    cnt[rid,"resolved"] = jget(line,"resolved"); cnt[rid,"parked"] = jget(line,"parked")
    cnt[rid,"failed"]   = jget(line,"failed");   cnt[rid,"timeout"] = jget(line,"timeout")
  }
  else if (typ == "worker_spawned") {
    t = jget(line,"ticket"); k = rid SUBSEP t
    wstate[k] = "live"; wpid[k] = jget(line,"pid"); wmodel[k] = jget(line,"model")
    weffort[k] = jget(line,"effort"); wsince[k] = ts
    if (!(k in wseen)) { wseen[k] = 1; worder[++nw] = k; wrid[k] = rid; wtick[k] = t }
  }
  else if (typ == "worker_escalated") {
    t = jget(line,"ticket"); k = rid SUBSEP t
    if (k in wseen) { wmodel[k] = jget(line,"to"); wesc[k] = 1 }
    tally[rid,"escalated"]++
  }
  else if (typ == "worker_done") {
    t = jget(line,"ticket"); k = rid SUBSEP t
    wstate[k] = "done"; wstatus[k] = jget(line,"status")
    tally[rid, jget(line,"status")]++
  }
  else if (typ == "ticket_parked") { tally[rid,"parked_event"]++ }
  else if (typ == "driver_spawned") {
    l = jget(line,"label"); k = rid SUBSEP l
    dstate[k] = "live"; dpid[k] = jget(line,"pid"); dsince[k] = ts
    if (!(k in dseen)) { dseen[k] = 1; dorder[++nd] = k; drid[k] = rid; dlbl[k] = l }
  }
  else if (typ == "driver_reaped") { l = jget(line,"label"); dstate[rid SUBSEP l] = "done" }
}
END {
  for (i = 1; i <= nruns; i++) {
    r = order[i]
    printf "RUN\t%s\t%s\t%s\t%s\t%s\n", r, (rstart[r]==""?0:rstart[r]), (rdone[r]?1:0), rmode[r], rtarget[r]
  }
  for (i = 1; i <= nw; i++) {
    k = worder[i]
    if (wstate[k] != "live") continue
    printf "W\t%s\t%s\t%s\t%s\t%s\t%s\n", wrid[k], wtick[k], (wpid[k]==""?0:wpid[k]), wmodel[k], weffort[k], (wsince[k]==""?0:wsince[k])
  }
  for (i = 1; i <= nd; i++) {
    k = dorder[i]
    if (dstate[k] != "live") continue
    printf "D\t%s\t%s\t%s\t%s\n", drid[k], dlbl[k], (dpid[k]==""?0:dpid[k]), (dsince[k]==""?0:dsince[k])
  }
  for (kk in tally) {
    split(kk, p, SUBSEP)
    printf "C\t%s\t%s\t%s\n", p[1], p[2], tally[kk]
  }
}
AWKMAIN
)"
# The program is passed as an ARGUMENT, never `awk -f /dev/stdin`: BSD awk on macOS and mawk on a
# Debian CI image disagree about reading a program from a pipe, and the failure mode is an empty
# fold that looks exactly like an idle fleet.
FOLD="$(awk "$FOLD_PROG" "$LOG" 2>/dev/null)"

# Newest run = the last RUN row the fold emitted (rows are in first-appearance order).
LATEST_RUN="$(printf '%s\n' "$FOLD" | awk -F'\t' '$1=="RUN"{r=$2} END{print r}')"
RUN_DONE="$(printf '%s\n' "$FOLD" | awk -F'\t' -v r="$LATEST_RUN" '$1=="RUN" && $2==r {print $4}')"
RUN_MODE="$(printf '%s\n' "$FOLD" | awk -F'\t' -v r="$LATEST_RUN" '$1=="RUN" && $2==r {print $5}')"
RUN_START="$(printf '%s\n' "$FOLD" | awk -F'\t' -v r="$LATEST_RUN" '$1=="RUN" && $2==r {print $3}')"

run_filter() { # reads FOLD on stdin, keeps rows for the run(s) in scope
  if [[ "$ALL_RUNS" -eq 1 ]]; then cat; else awk -F'\t' -v r="$LATEST_RUN" '$2==r'; fi
}

# ── liveness + stale reap ───────────────────────────────────────────────────────────────────────
# The log says a worker was spawned and never finished. That is a CLAIM, not a fact: a killed
# driver, a `pkill claude`, or an OOM leaves the spawn event with no done event forever. `kill -0`
# is the arbiter. A claimed-live worker whose pid is gone is STALE — reported separately, and (by
# default) a synthetic `worker_done status=stale` is appended so the next fold is clean and the
# log self-heals instead of accumulating phantom workers.
ACTIVE=(); STALE=()
while IFS=$'\t' read -r _k rid tick pid model effort since; do
  [[ "$_k" == "W" ]] || continue
  if [[ "$pid" -gt 0 ]] 2>/dev/null && kill -0 "$pid" 2>/dev/null; then
    ACTIVE+=("$rid"$'\t'"$tick"$'\t'"$pid"$'\t'"$model"$'\t'"$effort"$'\t'"$since")
  else
    STALE+=("$rid"$'\t'"$tick"$'\t'"$pid"$'\t'"$model"$'\t'"$effort"$'\t'"$since")
  fi
done < <(printf '%s\n' "$FOLD" | awk -F'\t' '$1=="W"' | run_filter)

DRIVERS=()
while IFS=$'\t' read -r _k rid lbl pid since; do
  [[ "$_k" == "D" ]] || continue
  if [[ "$pid" -gt 0 ]] 2>/dev/null && kill -0 "$pid" 2>/dev/null; then
    DRIVERS+=("$rid"$'\t'"$lbl"$'\t'"$pid"$'\t'"$since")
  fi
done < <(printf '%s\n' "$FOLD" | awk -F'\t' '$1=="D"' | run_filter)

if [[ "$REAP" -eq 1 && "${#STALE[@]}" -gt 0 && -w "$LOG" ]]; then
  # Append directly rather than via govern::event: the reap must work even though GOVERN_EVENTS is
  # 0 in the reader's own environment (the log's existence is the only permission needed, and the
  # write is what stops the phantom from being re-reported on every later read).
  for _s in "${STALE[@]}"; do
    IFS=$'\t' read -r _r _t _p _m _e _si <<<"$_s"
    printf '{"ts":%s,"run_id":"%s","type":"worker_done","ticket":%s,"status":"stale","pid":%s,"reapedBy":"status.sh"}\n' \
      "$NOW" "$_r" "$_t" "${_p:-0}" >> "$LOG" 2>/dev/null || true
  done
fi

# ── counters ────────────────────────────────────────────────────────────────────────────────────
counter() { # <name> -> count for the run(s) in scope
  printf '%s\n' "$FOLD" | awk -F'\t' '$1=="C"' | run_filter \
    | awk -F'\t' -v n="$1" '$3==n {s+=$4} END{print s+0}'
}
N_RES="$(counter resolved)"; N_PARK="$(counter parked)"; N_FAIL="$(counter failed)"
N_TIME="$(counter timeout)"; N_BUDGET="$(counter budget-exceeded)"; N_ABORT="$(counter early-abort)"
N_INTR="$(counter interrupted)"; N_ESC="$(counter escalated)"; N_STALEC="$(counter stale)"

hms() { # seconds -> compact human duration
  local s="${1:-0}"
  [[ "$s" =~ ^[0-9]+$ ]] || { printf '?'; return 0; }
  if   [[ "$s" -lt 60 ]]; then printf '%ds' "$s"
  elif [[ "$s" -lt 3600 ]]; then printf '%dm' "$((s/60))"
  else printf '%dh%02dm' "$((s/3600))" "$(((s%3600)/60))"; fi
  return 0
}

if [[ "$JSON" -eq 1 ]]; then
  # Hand-assembled so status.sh has no jq dependency — it must stay runnable in a bare CI container.
  {
    printf '{"enabled":true,"log":"%s","now":%s,"runId":"%s","runMode":"%s","runStarted":%s,"runDone":%s' \
      "$LOG" "$NOW" "$LATEST_RUN" "$RUN_MODE" "${RUN_START:-0}" "$([[ "${RUN_DONE:-0}" == "1" ]] && printf true || printf false)"
    printf ',"active":['
    _first=1
    for _a in ${ACTIVE[@]+"${ACTIVE[@]}"}; do
      IFS=$'\t' read -r _r _t _p _m _e _si <<<"$_a"
      [[ "$_first" -eq 1 ]] || printf ','; _first=0
      printf '{"ticket":%s,"pid":%s,"model":"%s","effort":"%s","since":%s,"elapsed":%s}' \
        "$_t" "$_p" "$_m" "$_e" "${_si:-0}" "$(( NOW - ${_si:-NOW} ))"
    done
    printf '],"stale":['
    _first=1
    for _a in ${STALE[@]+"${STALE[@]}"}; do
      IFS=$'\t' read -r _r _t _p _m _e _si <<<"$_a"
      [[ "$_first" -eq 1 ]] || printf ','; _first=0
      printf '{"ticket":%s,"pid":%s}' "$_t" "$_p"
    done
    printf '],"drivers":['
    _first=1
    for _a in ${DRIVERS[@]+"${DRIVERS[@]}"}; do
      IFS=$'\t' read -r _r _l _p _si <<<"$_a"
      [[ "$_first" -eq 1 ]] || printf ','; _first=0
      printf '{"label":"%s","pid":%s,"elapsed":%s}' "$_l" "$_p" "$(( NOW - ${_si:-NOW} ))"
    done
    printf '],"counts":{"resolved":%s,"parked":%s,"failed":%s,"timeout":%s,"budgetExceeded":%s,"earlyAborted":%s,"interrupted":%s,"escalated":%s,"stale":%s}}\n' \
      "$N_RES" "$N_PARK" "$N_FAIL" "$N_TIME" "$N_BUDGET" "$N_ABORT" "$N_INTR" "$N_ESC" "$N_STALEC"
  }
  exit 0
fi

# ── text ────────────────────────────────────────────────────────────────────────────────────────
_state="running"; [[ "${RUN_DONE:-0}" == "1" ]] && _state="finished"
printf 'fleet: %s active · %s resolved · %s parked · %s failed'  "${#ACTIVE[@]}" "$N_RES" "$N_PARK" "$N_FAIL"
[[ "$N_TIME"   -gt 0 ]] && printf ' · %s timed-out' "$N_TIME"
[[ "$N_ESC"    -gt 0 ]] && printf ' · %s escalated' "$N_ESC"
printf '\n'
printf 'run:   %s (%s, mode=%s, up %s)\n' "${LATEST_RUN:-none}" "$_state" "${RUN_MODE:-?}" "$(hms "$(( NOW - ${RUN_START:-NOW} ))")"

if [[ "${#ACTIVE[@]}" -gt 0 ]]; then
  for _a in "${ACTIVE[@]}"; do
    IFS=$'\t' read -r _r _t _p _m _e _si <<<"$_a"
    printf '  #%-5s %-8s %-6s pid %-7s%s\n' "$_t" "${_m:-?}" "$(hms "$(( NOW - ${_si:-NOW} ))")" "$_p" \
      "${_e:+effort=$_e}"
  done
else
  printf '  (no live workers)\n'
fi

if [[ "${#DRIVERS[@]}" -gt 0 ]]; then
  printf 'drivers: %s live —' "${#DRIVERS[@]}"
  for _a in "${DRIVERS[@]}"; do
    IFS=$'\t' read -r _r _l _p _si <<<"$_a"
    printf ' %s(pid %s)' "$_l" "$_p"
  done
  printf '\n'
fi

if [[ "${#STALE[@]}" -gt 0 ]]; then
  printf 'stale: %s worker(s) claimed live with a dead pid%s —' "${#STALE[@]}" \
    "$([[ "$REAP" -eq 1 ]] && printf ', reaped' || printf '')"
  for _a in "${STALE[@]}"; do
    IFS=$'\t' read -r _r _t _p _rest <<<"$_a"
    printf ' #%s' "$_t"
  done
  printf '\n'
fi
exit 0
