#!/usr/bin/env bash
# Cross-process cap on concurrent dependency installs.
#
# WHY THIS EXISTS
# ---------------
# `worktree:new` hands off to the project's own scripts/lib/worktree-bootstrap.sh
# hook, and a bootstrap for a multi-repo workspace almost always installs deps for
# several sub-repos at once — backgrounding each one, because installing five repos
# sequentially is slow. That is the right instinct and this file does not change it.
#
# The problem is that the obvious throttle — `wait` at the end of the bootstrap — is
# per-worktree. It cannot see another worktree's installs, so it bounds nothing that
# matters once the governor is running the backlog in parallel:
#
#     GOVERN_PARALLEL_DEFAULT tickets in flight
#       x N sub-repos installing concurrently inside each bootstrap
#       x ~1 GB peak per install
#
# A JS install peaks around 1 GB and holds it: the resolver builds the whole
# dependency tree in memory, extraction runs many concurrent sockets, and the runtime's
# heap does not return to the OS mid-run. That is fine once and ruinous twenty times.
# Measured on a 24 GB laptop: 13 concurrent installs, ~14 GB resident, 3.7 GB swap,
# machine unusable for minutes. Neither layer was individually wrong — the governor's
# concurrency knob reasons about API spend and rate limits, the bootstrap's `&` reasons
# about one worktree, and nothing anywhere was denominated in machine memory.
#
# So the cap has to be CROSS-PROCESS. This is that cap.
#
# NOTE FOR ANYONE MEASURING THIS: `ps` RSS does not show the spike. It reported a
# 364 MB maximum while the OS process monitor showed 1.18 GB for the same processes,
# because RSS excludes compressed and swapped pages. Measure phys_footprint (macOS) or
# PSS/swap-inclusive counters (Linux), or the problem reads as absent.
#
# USAGE (from your scripts/lib/worktree-bootstrap.sh)
# --------------------------------------------------
#   source "$ROOT/scripts/lib/install-semaphore.sh"
#   ( trap sem_release EXIT
#     sem_acquire "$repo_name"
#     <your install command>
#   ) &
#
# Hold it across the WHOLE install, including any fallback command and post-install
# codegen — those are part of the same memory peak. Requires the sourcing script to
# define log() and ROOT.
#
# Package-manager agnostic: it caps whatever command you wrap, so npm/pnpm/yarn/bun/
# cargo/go/uv all work the same way.

# How many installs may run at once across EVERY worktree and session on this machine.
INSTALL_PARALLEL="${WORKTREE_INSTALL_PARALLEL:-4}"
INSTALL_SEM_DIR="${WORKTREE_INSTALL_SEM_DIR:-$ROOT/logs/.install-slots}"
# Waiting forever would turn one wedged install into a hung bootstrap for every other
# session on the machine, so a slot wait degrades to running UNCAPPED (loudly) rather
# than blocking. Slow is recoverable; deadlocked across sessions is not.
INSTALL_SEM_TIMEOUT="${WORKTREE_INSTALL_WAIT_TIMEOUT:-600}"
mkdir -p "$INSTALL_SEM_DIR"

# Acquire one of INSTALL_PARALLEL slots. `mkdir` is the atomic primitive — bash 3.2 (the
# system bash on macOS) has no flock, and this must work on a stock machine. Each slot
# records its holder pid so a slot orphaned by a killed install is reclaimable; reclaim
# is itself serialized behind .reclaim so two waiters cannot both tear down the same
# slot while a third is legitimately taking it.
INSTALL_SEM_HELD=""
sem_acquire() {
  local label="$1" waited=0 i h holder
  while :; do
    for i in $(seq 1 "$INSTALL_PARALLEL"); do
      if mkdir "$INSTALL_SEM_DIR/$i" 2>/dev/null; then
        echo "$$" > "$INSTALL_SEM_DIR/$i/holder"
        INSTALL_SEM_HELD="$INSTALL_SEM_DIR/$i"
        [ "$waited" -gt 0 ] && log "[$label] install slot $i acquired after ${waited}s wait"
        return 0
      fi
    done
    if mkdir "$INSTALL_SEM_DIR/.reclaim" 2>/dev/null; then
      for i in $(seq 1 "$INSTALL_PARALLEL"); do
        h="$INSTALL_SEM_DIR/$i/holder"; holder=""
        [ -f "$h" ] && holder="$(cat "$h" 2>/dev/null || true)"
        if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
          log "reclaiming install slot $i — holder pid $holder is gone"
          rm -rf "${INSTALL_SEM_DIR:?}/${i:?}"
        fi
      done
      rmdir "$INSTALL_SEM_DIR/.reclaim" 2>/dev/null || true
    fi
    if [ "$waited" -eq 0 ]; then
      log "[$label] all $INSTALL_PARALLEL install slots busy — queued (this is the RAM cap, not a hang)"
    fi
    sleep 2; waited=$((waited + 2))
    if [ "$waited" -ge "$INSTALL_SEM_TIMEOUT" ]; then
      log "[$label] WARNING: no install slot after ${waited}s — proceeding UNCAPPED rather than blocking the bootstrap"
      INSTALL_SEM_HELD=""
      return 0
    fi
  done
}

sem_release() {
  [ -n "$INSTALL_SEM_HELD" ] && rm -rf "${INSTALL_SEM_HELD:?}" 2>/dev/null
  INSTALL_SEM_HELD=""
}
