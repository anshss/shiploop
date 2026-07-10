#!/usr/bin/env bash
# Durable-validation JOB SUBSTRATE (harness durable-validation-runner design §2–§3). Sourced by
# BOTH run-validation.sh's detached supervisor AND a flow's validation script — DEFINITIONS ONLY;
# every function resolves its deps at call time so definition order and the sourcing context are
# irrelevant. No `set -e` side effects: sourcing this file must never abort the caller.
#
# The job dir (logs/govern/validations/<job>/) is the whole interface contract for the sibling
# tickets (delivery, stamping) and for ANY workspace's GOVERN_DEPLOY_SWEEP_CMD. The files it holds:
#   deploys.jsonl  — manifest: one {id,provider,ts} line appended BEFORE provisioning each box, so a
#                    box is trackable even if the job dies one line later.
#   heartbeat      — runner-owned liveness file, touched ~every GOVERN_VAL_HEARTBEAT_INTERVAL while
#                    the flow's process group is alive (liveness, NOT script cooperation).
#   status.jsonl   — {phase,deploys,verdict,evidence,ts} per phase boundary (§3 schema).
#   status         — terminal marker holding one of PASS|FAIL|ABORT|ERROR (the quick terminal probe).
#   tombstone      — written by the workspace sweep when it reaps a stale job; STICKY and DOMINATES
#                    the heartbeat. Present at a phase boundary → the job must ABORT and touch nothing.
#   pgid           — the flow process group id (runner-recorded, for group-kill on wall-cap timeout).
#
# Env contract (set by run-validation.sh, read here):
#   VAL_JOB_ID   the job id (val-<flowid>-<ts>); deploy names are <VAL_JOB_ID>-<label>.
#   VAL_JOB_DIR  the job dir (absolute).
# Tunables (all overridable, defaults chosen for a real fleet; tests shrink them):
#   GOVERN_VAL_HEARTBEAT_STALE  seconds a heartbeat may age before the job is deemed orphaned (~180).

# ── internals ────────────────────────────────────────────────────────────────
valjob::_log() {
  if command -v govern::log >/dev/null 2>&1; then govern::log "valjob: $*"
  else printf '[valjob] %s\n' "$*" >&2; fi
}
# JSON string escaper (backslash + double-quote only — ids/providers/evidence pointers are simple).
valjob::_esc() { local s="${1:-}"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; printf '%s' "$s"; }
# mtime in epoch seconds — GNU (`stat -c %Y`) first, BSD (`stat -f %m`) fallback: on GNU coreutils,
# `stat -f` means FILESYSTEM mode (succeeds and prints unrelated multi-line output), so BSD-first
# order would silently "succeed" with garbage on Linux instead of falling through.
valjob::_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }
# Resolve + ensure the job dir; rc 1 (never abort) when VAL_JOB_DIR is unset.
valjob::_require_dir() {
  if [[ -z "${VAL_JOB_DIR:-}" ]]; then valjob::_log "VAL_JOB_DIR unset"; return 1; fi
  mkdir -p "$VAL_JOB_DIR" 2>/dev/null || true
  printf '%s' "$VAL_JOB_DIR"
}

# ── deploy naming (§1) ───────────────────────────────────────────────────────
# The name every box the flow provisions MUST carry so the session-scoped reaper can attribute it:
# <VAL_JOB_ID>-<label>. VAL_JOB_ID already begins with `val-`, so the result matches the spec's
# `val-<jobid>-<label>` shape and the sweep's `<jobid>-*` prefix match without a doubled prefix.
valjob::deploy_name() { printf '%s-%s' "${VAL_JOB_ID:?VAL_JOB_ID unset}" "${1:?deploy label required}"; }

# ── manifest (§2) ────────────────────────────────────────────────────────────
# Append one deploy line BEFORE provisioning. A single short line is < PIPE_BUF so `>>` is atomic.
valjob::manifest_add() { # <deploy-id> <provider>
  local id="${1:?deploy id required}" prov="${2:-unknown}" dir
  dir="$(valjob::_require_dir)" || return 1
  printf '{"id":"%s","provider":"%s","ts":%s}\n' \
    "$(valjob::_esc "$id")" "$(valjob::_esc "$prov")" "$(date +%s)" >> "$dir/deploys.jsonl"
}
# The manifest deploys as `id provider` lines — the candidate set a sweep closes when the job orphans.
valjob::orphan_deploys() { # [jobdir]
  local dir="${1:-${VAL_JOB_DIR:-}}" f
  [[ -n "$dir" ]] || return 0
  f="$dir/deploys.jsonl"; [[ -s "$f" ]] || return 0
  sed -n 's/.*"id":"\([^"]*\)".*"provider":"\([^"]*\)".*/\1 \2/p' "$f"
}
# The deploys array (for a status line) built without jq: each manifest line is already a JSON object.
valjob::_deploys_array() {
  local f="${VAL_JOB_DIR:-}/deploys.jsonl"
  [[ -s "$f" ]] || { printf '[]'; return 0; }
  printf '[%s]' "$(awk 'BEGIN{sep=""} {printf "%s%s", sep, $0; sep=","}' "$f")"
}

# ── heartbeat (§2) ───────────────────────────────────────────────────────────
valjob::heartbeat_touch() { local dir; dir="$(valjob::_require_dir)" || return 1; touch "$dir/heartbeat" 2>/dev/null || true; return 0; }
# Age of the heartbeat in seconds (empty output when there is no heartbeat yet).
valjob::heartbeat_age() { # [jobdir]
  local dir="${1:-${VAL_JOB_DIR:-}}" hb m now
  [[ -n "$dir" ]] || return 0
  hb="$dir/heartbeat"; [[ -f "$hb" ]] || return 0
  m="$(valjob::_mtime "$hb")"; [[ -n "$m" ]] || return 0
  now="$(date +%s)"; printf '%s' "$(( now - m ))"
}

# ── status + terminal record (§3) ────────────────────────────────────────────
# Append a phase-boundary line. verdict/evidence stay empty until the terminal line.
valjob::phase() { # <phase> [verdict] [evidence]
  local phase="${1:?phase name required}" verdict="${2:-}" evidence="${3:-}" dir
  dir="$(valjob::_require_dir)" || return 1
  printf '{"phase":"%s","deploys":%s,"verdict":"%s","evidence":"%s","ts":%s}\n' \
    "$(valjob::_esc "$phase")" "$(valjob::_deploys_array)" \
    "$(valjob::_esc "$verdict")" "$(valjob::_esc "$evidence")" "$(date +%s)" >> "$dir/status.jsonl"
}
# Write the terminal record. First writer wins (idempotent) — a supervisor and a flow racing the same
# job must never double-stamp. The `status` marker file is the quick terminal probe orphan_verdict reads.
valjob::terminal() { # <PASS|FAIL|ABORT|ERROR> [evidence]
  local v="${1:?terminal verdict required}" evidence="${2:-}" dir
  case "$v" in PASS|FAIL|ABORT|ERROR) ;; *) valjob::_log "invalid terminal verdict: $v"; return 1 ;; esac
  dir="$(valjob::_require_dir)" || return 1
  if [[ -f "$dir/status" ]]; then valjob::_log "already terminal ($(cat "$dir/status" 2>/dev/null)); ignoring $v"; return 0; fi
  valjob::phase terminal "$v" "$evidence"
  printf '%s\n' "$v" > "$dir/status.tmp.$$" 2>/dev/null && mv -f "$dir/status.tmp.$$" "$dir/status" 2>/dev/null
  valjob::_log "terminal $v"
  return 0
}

# ── tombstone guard (§3) — the job side of orphan-safety ─────────────────────
# Called at EVERY phase boundary, before doing anything else. Tombstone present → the sweep already
# closed this job's boxes; emit terminal ABORT and EXIT without touching or re-provisioning anything.
# This exits the sourcing flow script by design (a resumed job must never continue against reaped boxes).
valjob::guard_tombstone() { # [phase-label]
  local dir; dir="$(valjob::_require_dir)" || return 1
  if [[ -e "$dir/tombstone" ]]; then
    valjob::_log "tombstone present — aborting at boundary '${1:-?}' (sweep already reaped this job)"
    valjob::terminal ABORT "tombstone present at boundary '${1:-?}' — sweep reaped this job's deploys; touching nothing"
    exit 0
  fi
  return 0
}

# ── orphan verdict (§2) — DATA for GOVERN_DEPLOY_SWEEP_CMD; the hub NEVER closes boxes itself ─────
# Deterministic rule: tombstone (sticky, dominates) → terminal record → stale heartbeat → else LIVE.
valjob::orphan_verdict() { # [jobdir] -> "LIVE …" | "ORPHAN <reason>"
  local dir="${1:-${VAL_JOB_DIR:-}}" age stale
  [[ -n "$dir" && -d "$dir" ]] || { printf 'UNKNOWN no-job-dir\n'; return 0; }
  if [[ -e "$dir/tombstone" ]]; then printf 'ORPHAN tombstone\n'; return 0; fi
  if [[ -f "$dir/status" ]]; then printf 'ORPHAN terminal:%s\n' "$(cat "$dir/status" 2>/dev/null)"; return 0; fi
  age="$(valjob::heartbeat_age "$dir")"
  [[ -n "$age" ]] || { printf 'ORPHAN no-heartbeat\n'; return 0; }
  stale="${GOVERN_VAL_HEARTBEAT_STALE:-180}"
  if (( age > stale )); then printf 'ORPHAN stale-heartbeat:%ss\n' "$age"; return 0; fi
  printf 'LIVE heartbeat:%ss\n' "$age"; return 0
}
valjob::is_orphan() { case "$(valjob::orphan_verdict "${1:-${VAL_JOB_DIR:-}}")" in ORPHAN*) return 0 ;; *) return 1 ;; esac; }

# ── retention pruning (§1) ───────────────────────────────────────────────────
# Prune TERMINAL job dirs only (those with a `status` marker) — keep the newest N regardless of age,
# then delete the rest older than the day window. Live (non-terminal) dirs are NEVER touched.
valjob::prune() { # <validations-dir>
  local base="${1:?validations dir required}" keep days cutoff
  [[ -d "$base" ]] || return 0
  keep="${GOVERN_VAL_RETAIN_KEEP:-20}"; days="${GOVERN_VAL_RETAIN_DAYS:-14}"
  cutoff="$(( $(date +%s) - days * 86400 ))"
  local d m
  for d in "$base"/*/; do
    [[ -d "$d" ]] || continue
    [[ -f "${d}status" ]] || continue
    m="$(valjob::_mtime "${d}status")"; [[ -n "$m" ]] || m=0
    printf '%s\t%s\n' "$m" "${d%/}"
  done | sort -rn | { local n=0 mm dd
    while IFS="$(printf '\t')" read -r mm dd; do
      n=$(( n + 1 ))
      [[ "$n" -le "$keep" ]] && continue
      [[ "$mm" -lt "$cutoff" ]] && rm -rf "$dd" 2>/dev/null || true
    done; }
  return 0
}
