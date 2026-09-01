#!/usr/bin/env bash
# shiploop fleet monitor — the in-session channel for governor workers.
#
# Registered as a plugin Monitor (monitors/monitors.json). Claude Code runs it as a persistent
# background process for the session's lifetime and turns EVERY LINE IT PRINTS ON STDOUT into a
# notification in the driver's context.
#
# That last sentence is the entire design constraint. shiploop's whole thesis is that the driver's
# context is the scarce resource; a monitor that tailed the event log would spend it faster than the
# work it reports saves. So:
#
#   • TRANSITIONS ONLY. A worker starting, finishing, escalating, parking; a run starting/finishing.
#     Never a raw tail, never a periodic "still running" heartbeat.
#   • DEDUPED. An identical message inside GOVERN_MONITOR_DEDUPE_S is dropped.
#   • RATE LIMITED. At most GOVERN_MONITOR_MAX_PER_MIN lines per 60s window; the overflow is
#     collapsed into ONE "N more suppressed" line per window, so a 12-way fan-out cannot flood.
#   • SILENT WITH NO FLEET. No event log (i.e. almost every session ever) prints absolutely nothing
#     and costs one stat() every GOVERN_MONITOR_POLL_S seconds. It does not exit, so a fleet started
#     later in the same session is still picked up.
#   • NEVER REPLAYS HISTORY. It attaches at the END of the log; events from before the session
#     started are not the driver's business.
#
# Self-contained on purpose: it must run in ANY session, including one with no shiploop workspace,
# so it never sources scripts/govern/lib/common.sh (which requires a workspace config file).
set -uo pipefail

POLL_S="${GOVERN_MONITOR_POLL_S:-15}"
DEDUPE_S="${GOVERN_MONITOR_DEDUPE_S:-120}"
MAX_PER_MIN="${GOVERN_MONITOR_MAX_PER_MIN:-6}"
# Kill switch: a session that wants nothing from this sets GOVERN_MONITOR=0 and the process idles
# out immediately rather than being half-alive.
[[ "${GOVERN_MONITOR:-1}" == "0" ]] && exit 0

find_log() { # walk up from the session cwd (and CLAUDE_PROJECT_DIR) for governor/events.jsonl
  local d i
  if [[ -n "${GOVERN_EVENTS_FILE:-}" && -f "${GOVERN_EVENTS_FILE:-}" ]]; then
    printf '%s' "$GOVERN_EVENTS_FILE"; return 0
  fi
  for d in "${CLAUDE_PROJECT_DIR:-}" "$PWD"; do
    [[ -n "$d" && -d "$d" ]] || continue
    d="$(cd "$d" 2>/dev/null && pwd)" || continue
    i=0
    while [[ -n "$d" && "$d" != "/" && "$i" -lt 12 ]]; do
      if [[ -f "$d/governor/events.jsonl" ]]; then printf '%s' "$d/governor/events.jsonl"; return 0; fi
      d="$(dirname "$d")"; i=$((i+1))
    done
  done
  return 1
}

# Field extractor for ONE of our own event lines. sed, not jq: the monitor must not require jq, and
# the lines are flat one-level JSON this repo emits itself. Anchored on `,"key":` / `{"key":` so a
# key name inside a (backslash-escaped) string value cannot false-match.
jget() { # <line> <key>
  local line="$1" key="$2" v
  v="$(printf '%s' "$line" | sed -n "s/.*[{,]\"$key\":\"\\([^\"]*\\)\".*/\\1/p" | head -1)"
  if [[ -z "$v" ]]; then
    v="$(printf '%s' "$line" | sed -n "s/.*[{,]\"$key\":\\([^,}\"]*\\).*/\\1/p" | head -1)"
  fi
  printf '%s' "$v"
  return 0
}

# ── rate limit + dedupe state ───────────────────────────────────────────────────────────────────
WINDOW_START=0; WINDOW_N=0; WINDOW_SUPPRESSED=0
LAST_KEYS=""   # newline-separated "<epoch> <key>" entries, pruned by age

emit() { # <dedupe-key> <message>
  local key="$1" msg="$2" now line ts k kept=""
  now="$(date +%s)"

  # Dedupe: identical key seen inside DEDUPE_S → drop. Prune while scanning so the list stays small.
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    ts="${line%% *}"; k="${line#* }"
    [[ $(( now - ts )) -lt "$DEDUPE_S" ]] || continue
    [[ "$k" == "$key" ]] && return 0
    kept+="$line"$'\n'
  done <<<"$LAST_KEYS"
  LAST_KEYS="$kept$now $key"$'\n'

  # Rate limit, per 60s window.
  if [[ $(( now - WINDOW_START )) -ge 60 ]]; then
    if [[ "$WINDOW_SUPPRESSED" -gt 0 ]]; then
      printf 'shiploop fleet: %s more event(s) suppressed by the monitor rate limit (%s/min)\n' \
        "$WINDOW_SUPPRESSED" "$MAX_PER_MIN"
    fi
    WINDOW_START="$now"; WINDOW_N=0; WINDOW_SUPPRESSED=0
  fi
  if [[ "$WINDOW_N" -ge "$MAX_PER_MIN" ]]; then
    WINDOW_SUPPRESSED=$((WINDOW_SUPPRESSED+1))
    return 0
  fi
  WINDOW_N=$((WINDOW_N+1))
  printf '%s\n' "$msg"
  return 0
}

handle() { # <event line>
  local line="$1" typ t st model to frm lbl
  typ="$(jget "$line" type)"
  case "$typ" in
    run_started)
      emit "run-start" "shiploop fleet: governor run started (mode=$(jget "$line" mode), target=$(jget "$line" target), up to $(jget "$line" parallel) driver(s))" ;;
    worker_spawned)
      t="$(jget "$line" ticket)"; model="$(jget "$line" model)"
      emit "spawn-$t" "shiploop fleet: worker started on #$t (${model:-?})" ;;
    worker_escalated)
      t="$(jget "$line" ticket)"; frm="$(jget "$line" from)"; to="$(jget "$line" to)"
      emit "esc-$t-$to" "shiploop fleet: #$t escalated ${frm:-?} -> ${to:-?} ($(jget "$line" reason))" ;;
    worker_done)
      t="$(jget "$line" ticket)"; st="$(jget "$line" status)"
      # `stale` is a bookkeeping reap written by status.sh, not something that happened to a worker.
      [[ "$st" == "stale" ]] && return 0
      emit "done-$t-$st" "shiploop fleet: #$t $st ($(jget "$line" model), $(jget "$line" elapsed)s)" ;;
    ticket_parked)
      t="$(jget "$line" ticket)"
      emit "park-$t" "shiploop fleet: #$t PARKED — needs a human decision" ;;
    run_done)
      emit "run-done" "shiploop fleet: run finished — resolved=$(jget "$line" resolved) parked=$(jget "$line" parked) failed=$(jget "$line" failed)" ;;
    # driver_spawned / driver_reaped are deliberately NOT surfaced: they are fan-out plumbing, one
    # per driver on top of the per-ticket events that already say what is happening.
    *) return 0 ;;
  esac
  return 0
}

# ── main loop ───────────────────────────────────────────────────────────────────────────────────
# Outer loop re-resolves the log, so a fleet that starts (or a workspace that is created) mid-session
# is picked up without the monitor ever having printed anything in the meantime.
while :; do
  LOG="$(find_log || true)"
  if [[ -z "$LOG" ]]; then sleep "$POLL_S"; continue; fi

  # Attach at the END. `tail -n0 -F` also survives the log being rotated or recreated, which is what
  # happens when a workspace is re-scaffolded mid-session.
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    handle "$line"
  done < <(tail -n 0 -F "$LOG" 2>/dev/null)

  # tail exited (log vanished, or the process was signalled) — fall back to polling for it.
  sleep "$POLL_S"
done
