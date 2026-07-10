#!/usr/bin/env bash
# Durable-validation runner + job-substrate proof (design §1–§3). bash 3.2-safe, like its siblings.
# Part A unit-tests the pure valjob.sh helpers (manifest/heartbeat/orphan-verdict/terminal/prune).
# Part B drives the REAL run-validation.sh with a fake flow script to prove the five "Done when"
# behaviors: (1) the job survives the launcher process's exit; (2) the manifest line precedes the
# mock provision; (3) the heartbeat stops within ~60s of a pgid SIGKILL; (4) GOVERN_VAL_TIMEOUT kills
# the job and writes terminal ERROR; (5) a pre-placed tombstone at a boundary yields terminal ABORT
# with zero side effects. Fast: intervals/timeouts are shrunk to seconds via env.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"

T="$(mktemp -d)"
# Kill any lingering detached job process groups before removing the tree (no leaked test procs).
cleanup() {
  local p
  for p in "$T"/logs/validations/*/pgid; do
    [[ -f "$p" ]] && kill -KILL "-$(cat "$p" 2>/dev/null)" 2>/dev/null
  done
  rm -rf "$T"
}
trap cleanup EXIT
mk_ws_stub "$T"
export GOVERN_LOG_ROOT="$T/logs" GOVERN_NO_PUSH=1
RUNV="$DIR/../run-validation.sh"
VALJOB="$DIR/../lib/valjob.sh"
VALDIR="$T/logs/validations"
export VALJOB_LIB="$VALJOB"   # the fake flow scripts source this.

# Poll helper: run a status-file check for up to <secs>, echoing the terminal marker when it appears.
await_status() { # <secs> <jobdir>
  local secs="$1" jd="$2" i
  for ((i=0; i<secs*5; i++)); do
    if [[ -f "$jd/status" ]]; then cat "$jd/status"; return 0; fi
    sleep 0.2
  done
  return 0
}

# ─────────────────────────── Part A — valjob.sh helpers ──────────────────────
source "$VALJOB"

# deploy_name = <jobid>-<label> (jobid already carries the val- prefix; no doubling).
export VAL_JOB_ID="val-unit-1" VAL_JOB_DIR="$T/unitA"; mkdir -p "$VAL_JOB_DIR"
assert_eq "$(valjob::deploy_name gpu)" "val-unit-1-gpu" "deploy_name = <jobid>-<label>"

# invalid terminal verdict rejected (fresh dir, before any real terminal).
rc=0; valjob::terminal BOGUS 2>/dev/null || rc=$?
assert_eq "$rc" "1" "terminal rejects a verdict outside PASS|FAIL|ABORT|ERROR"

# manifest_add writes JSON lines; orphan_deploys parses id+provider back out.
valjob::manifest_add box-1 vastai
valjob::manifest_add box-2 runpod
assert_contains "$(cat "$VAL_JOB_DIR/deploys.jsonl")" '"id":"box-1"' "manifest line written before provisioning"
assert_eq "$(valjob::orphan_deploys | tr '\n' ';')" "box-1 vastai;box-2 runpod;" "orphan_deploys yields id+provider rows"

# fresh heartbeat → LIVE; aged heartbeat → ORPHAN (stale).
valjob::heartbeat_touch
assert_contains "$(valjob::orphan_verdict)" "LIVE" "fresh heartbeat → LIVE"
assert_contains "$(GOVERN_VAL_HEARTBEAT_STALE=-1 valjob::orphan_verdict)" "ORPHAN stale-heartbeat" "aged heartbeat → ORPHAN"

# tombstone is sticky and DOMINATES a fresh heartbeat.
touch "$VAL_JOB_DIR/tombstone"; valjob::heartbeat_touch
assert_contains "$(valjob::orphan_verdict)" "ORPHAN tombstone" "tombstone dominates a fresh heartbeat"
rm -f "$VAL_JOB_DIR/tombstone"

# terminal record writes the status marker, is idempotent (first writer wins), and → ORPHAN.
valjob::terminal PASS "validation/evidence/x.md"
assert_eq "$(cat "$VAL_JOB_DIR/status")" "PASS" "terminal writes the status marker"
valjob::terminal FAIL "second attempt"
assert_eq "$(cat "$VAL_JOB_DIR/status")" "PASS" "terminal is idempotent — first writer wins (no double-stamp)"
assert_contains "$(valjob::orphan_verdict)" "ORPHAN terminal:PASS" "terminal record → job's deploys are orphan-candidates"

# prune: removes an aged terminal dir, keeps a recent terminal dir, never touches a live (non-terminal) dir.
PB="$T/prunebase"; mkdir -p "$PB/old-term" "$PB/new-term" "$PB/live-job"
echo PASS > "$PB/old-term/status"; echo PASS > "$PB/new-term/status"   # live-job has NO status marker
touch -t 202001010000 "$PB/old-term/status" 2>/dev/null || touch -d 2020-01-01 "$PB/old-term/status"
GOVERN_VAL_RETAIN_KEEP=0 GOVERN_VAL_RETAIN_DAYS=14 valjob::prune "$PB"
assert_eq "$([[ -d "$PB/old-term" ]] && echo present || echo absent)" "absent"  "prune removes an aged terminal job dir"
assert_eq "$([[ -d "$PB/new-term" ]] && echo present || echo absent)" "present" "prune keeps a recent terminal job dir"
assert_eq "$([[ -d "$PB/live-job" ]] && echo present || echo absent)" "present" "prune never touches a live (non-terminal) job dir"

# ───────────────────── Part B — run-validation.sh integration ────────────────

# (1)+(2): a well-behaved flow. Launch it, let the launcher process exit, then confirm it ran to
# terminal PASS (survived parent exit) and that the manifest line was written before the mock provision.
cat > "$T/flow_ok.sh" <<'EOF'
#!/usr/bin/env bash
source "$VALJOB_LIB"
valjob::guard_tombstone start
valjob::phase start
valjob::manifest_add box-ok mockprov && printf 'manifest box-ok\n' >> "$VAL_JOB_DIR/journal"
printf 'provision box-ok\n' >> "$VAL_JOB_DIR/journal"          # mock provision — strictly AFTER manifest
printf 'provisioned\n'      >  "$VAL_JOB_DIR/provision.done"
valjob::phase provision
valjob::terminal PASS "validation/evidence/flow-ok.md"
EOF
job_ok="$(GOVERN_VAL_HEARTBEAT_INTERVAL=1 bash "$RUNV" "$T/flow_ok.sh")"
jd_ok="$VALDIR/$job_ok"
assert_eq "$(await_status 20 "$jd_ok")" "PASS" "job runs to terminal PASS after the launcher process exited (survives parent exit)"
assert_contains "$(cat "$jd_ok/deploys.jsonl")" '"id":"box-ok"' "manifest recorded the deploy"
assert_eq "$(head -1 "$jd_ok/journal")" "manifest box-ok" "manifest line precedes the mock provision"

# orphans subcommand exposes a terminal job's deploys as sweep candidates (the GOVERN_DEPLOY_SWEEP_CMD data surface).
assert_contains "$(bash "$RUNV" orphans)" "box-ok" "orphans report exposes terminal job's deploys as sweep candidates"

# (3): heartbeat stops within ~60s of a pgid SIGKILL.
cat > "$T/flow_sleep.sh" <<'EOF'
#!/usr/bin/env bash
source "$VALJOB_LIB"
valjob::phase start
sleep 120
valjob::terminal PASS
EOF
job_s="$(GOVERN_VAL_HEARTBEAT_INTERVAL=1 bash "$RUNV" "$T/flow_sleep.sh")"
jd_s="$VALDIR/$job_s"
pgid=""; for ((i=0; i<100; i++)); do if [[ -s "$jd_s/pgid" ]]; then pgid="$(cat "$jd_s/pgid")"; break; fi; sleep 0.2; done
assert_eq "$([[ -n "$pgid" ]] && echo yes)" "yes" "supervisor recorded the flow's pgid"
sleep 2; hb1="$(valjob::_mtime "$jd_s/heartbeat")"; sleep 2; hb2="$(valjob::_mtime "$jd_s/heartbeat")"
assert_eq "$([[ "$hb2" -gt "$hb1" ]] && echo yes)" "yes" "heartbeat advances while the pgid is alive"
kill -KILL "-$pgid" 2>/dev/null || kill -KILL "$pgid" 2>/dev/null || true
sleep 4; hbA="$(valjob::_mtime "$jd_s/heartbeat")"; sleep 6; hbB="$(valjob::_mtime "$jd_s/heartbeat")"
assert_eq "$hbA" "$hbB" "heartbeat stops within ~60s of a pgid SIGKILL (interval=1 → within seconds)"

# (4): GOVERN_VAL_TIMEOUT kills the job and writes terminal ERROR.
cat > "$T/flow_hang.sh" <<'EOF'
#!/usr/bin/env bash
source "$VALJOB_LIB"
valjob::phase start
sleep 300
valjob::terminal PASS
EOF
job_h="$(GOVERN_VAL_HEARTBEAT_INTERVAL=1 GOVERN_VAL_TIMEOUT=3 bash "$RUNV" "$T/flow_hang.sh")"
jd_h="$VALDIR/$job_h"
assert_eq "$(await_status 30 "$jd_h")" "ERROR" "GOVERN_VAL_TIMEOUT wall cap kills the job and writes terminal ERROR"
assert_contains "$(cat "$jd_h/status.jsonl")" "wall cap" "terminal ERROR record notes the wall cap"

# (5): a pre-placed tombstone at a boundary → terminal ABORT with zero side effects.
cat > "$T/flow_tomb.sh" <<'EOF'
#!/usr/bin/env bash
source "$VALJOB_LIB"
valjob::guard_tombstone start                       # MUST abort here, before any spend
valjob::manifest_add box-should-not-exist vastai    # side effects that must NOT happen
printf 'provisioned\n' > "$VAL_JOB_DIR/provision.done"
valjob::terminal PASS
EOF
jid_t="val-tomb-test"
mkdir -p "$VALDIR/$jid_t"; touch "$VALDIR/$jid_t/tombstone"     # tombstone present before the flow starts
job_t="$(GOVERN_VAL_JOB_ID="$jid_t" GOVERN_VAL_HEARTBEAT_INTERVAL=1 bash "$RUNV" "$T/flow_tomb.sh")"
assert_eq "$job_t" "$jid_t" "deterministic job-id (GOVERN_VAL_JOB_ID) honored"
jd_t="$VALDIR/$jid_t"
assert_eq "$(await_status 20 "$jd_t")" "ABORT" "pre-placed tombstone at a boundary → terminal ABORT"
assert_eq "$([[ -f "$jd_t/deploys.jsonl" ]] && echo present || echo absent)"  "absent" "tombstone ABORT touched nothing (no manifest written)"
assert_eq "$([[ -f "$jd_t/provision.done" ]] && echo present || echo absent)" "absent" "tombstone ABORT touched nothing (no mock provision)"

assert_done
