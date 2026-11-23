#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/lib/run-probe.sh, the live-run probe and pending-sync marker helpers.
#
# A mechanism lib, installed to <root>/scripts/lib/run-probe.sh and refreshed by
# /shiploop:update through the same keep machinery as every other mechanism
# script: a workspace that carries local edits to it is never overwritten. It is
# deliberately NOT part of scripts/lib/workspace.sh, the one file updates never
# regenerate: helpers defined there reach only fresh installs, while every
# workspace scaffolded before they shipped would keep treating a declared
# GOVERN_RUN_PROBE as live forever.
#
# Callers (scripts/sync.sh, scripts/govern/lib/common.sh) source this file after
# workspace.sh and degrade to the documented fail-safe (a declared probe counts
# as LIVE, marker writes no-op) when it is somehow absent. Expects the sourcing
# script to have already sourced workspace.sh: META_ROOT and GOVERN_RUN_PROBE
# come from there.
#
# Source, don't execute:  source "<root>/scripts/lib/run-probe.sh"
# ─────────────────────────────────────────────────────────────────────────────

# wsp_run_live <repo> <dir>: 0 when GOVERN_RUN_PROBE reports a live product run in <dir>, 1 when it
# reports none or no probe is declared. A declared probe that is missing, not executable or over the
# 5s bound is treated as live, with a warning on stderr: never move code under a run because the
# probe itself broke. Bounded with a background pid and kill, so no `timeout` binary is needed.
wsp_run_live() {
  local probe="${GOVERN_RUN_PROBE:-}" path pid tenths=0 rc=0
  [ -n "$probe" ] || return 1
  case "$probe" in /*) path="$probe" ;; *) path="$META_ROOT/$probe" ;; esac
  if [ ! -f "$path" ] || [ ! -x "$path" ]; then
    echo "wsp_run_live: GOVERN_RUN_PROBE '$probe' is missing or not executable; treating $1 as LIVE" >&2
    return 0
  fi
  "$path" "${1:-}" "${2:-}" >/dev/null 2>&1 &
  pid=$!
  while [ "$tenths" -lt 50 ] && kill -0 "$pid" 2>/dev/null; do
    sleep 0.1
    tenths=$((tenths + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    sleep 0.1
    kill -9 "$pid" 2>/dev/null || true
    { wait "$pid"; } 2>/dev/null || true
    echo "wsp_run_live: GOVERN_RUN_PROBE '$probe' did not answer within 5s; treating $1 as LIVE" >&2
    return 0
  fi
  { wait "$pid"; } 2>/dev/null && rc=0 || rc=$?
  [ "$rc" -eq 0 ]
}

# wsp_pending_sync_mark <repo> <dir> <branch> <reason>: record that <repo>'s local <branch> is behind
# origin and was deliberately not fast-forwarded (reason: live-run | ff-failed), as one line
# `<origin sha> <ISO time> <reason>` in governor/.pending-sync/<repo>. The sha is the freshly fetched
# origin tip ("-" when it cannot be read). A later successful fast-forward clears it
# (wsp_pending_sync_clear), and the SessionStart hook reports whatever is still pending.
wsp_pending_sync_mark() {
  local repo="$1" dir="$2" branch="$3" reason="$4" sha pdir
  pdir="$META_ROOT/governor/.pending-sync"
  git -C "$dir" fetch -q origin "+refs/heads/$branch:refs/remotes/origin/$branch" >/dev/null 2>&1 || true
  sha="$(git -C "$dir" rev-parse -q --verify "refs/remotes/origin/$branch" 2>/dev/null || true)"
  mkdir -p "$pdir" 2>/dev/null || return 0
  printf '%s %s %s\n' "${sha:--}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$reason" > "$pdir/$repo" 2>/dev/null || true
  return 0
}

wsp_pending_sync_clear() { # <repo>
  rm -f "$META_ROOT/governor/.pending-sync/$1" 2>/dev/null || true
  return 0
}

return 0 2>/dev/null || true
