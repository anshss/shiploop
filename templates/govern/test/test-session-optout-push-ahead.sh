#!/usr/bin/env bash
# The two workspace extension switches, both off by default:
#   GOVERN_SESSION_OPTOUT_DIR: router-posture-reminder.sh and ticket-sweep-reminder.sh exit silently
#     for a session whose marker $DIR/<session_id> is younger than GOVERN_SESSION_OPTOUT_HOURS, and a
#     skipped session does not spend the once-per-session marker. Stale, absent or unset: they run.
#   GOVERN_SYNC_PUSH_AHEAD=1: sync.sh pushes a sub-repo's local main that is ahead of origin and not
#     behind; ahead AND behind prints both counts and the log command and pushes nothing. Off: no push.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e
REMIND="$GOVERN_HOOKS_DIR/router-posture-reminder.sh"
SWEEP="$GOVERN_HOOKS_DIR/ticket-sweep-reminder.sh"
SNAP="$GOVERN_HOOKS_DIR/session-snapshot.sh"
SYNC="$DIR/../../sync.sh"
[ -f "$SYNC" ] || SYNC="$DIR/../../sync.sh.missing"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T/wsstub"
export TMPDIR="$T/tmp"; mkdir -p "$TMPDIR"
OPT="$T/optout"; mkdir -p "$OPT"
old_stamp() { touch -t "$(date -r "$(( $(date +%s) - 8*3600 ))" +%Y%m%d%H%M 2>/dev/null || date -d "@$(( $(date +%s) - 8*3600 ))" +%Y%m%d%H%M)" "$1"; }

remind() { printf '{"session_id":"%s","prompt":"hello"}' "$1" | env "${@:2}" bash "$REMIND" 2>/dev/null; }

# ── router-posture-reminder ──────────────────────────────────────────────────────────────────
touch "$OPT/r-fresh"
assert_eq "$(remind r-fresh GOVERN_SESSION_OPTOUT_DIR="$OPT")" "" "reminder: a fresh marker skips the banner"
assert_contains "$(remind r-fresh)" "[ROUTER POSTURE]" \
  "reminder: the skip did not spend the once-per-session marker (same session, switch unset, still primes)"
touch "$OPT/r-stale"; old_stamp "$OPT/r-stale"
assert_contains "$(remind r-stale GOVERN_SESSION_OPTOUT_DIR="$OPT")" "[ROUTER POSTURE]" "reminder: a stale marker runs"
assert_contains "$(remind r-absent GOVERN_SESSION_OPTOUT_DIR="$OPT")" "[ROUTER POSTURE]" "reminder: no marker runs"
touch "$OPT/r-unset"
assert_contains "$(remind r-unset)" "[ROUTER POSTURE]" "reminder: switch unset runs, marker or not"
touch "$OPT/r-hours"; old_stamp "$OPT/r-hours"
assert_eq "$(remind r-hours GOVERN_SESSION_OPTOUT_DIR="$OPT" GOVERN_SESSION_OPTOUT_HOURS=12)" "" \
  "reminder: GOVERN_SESSION_OPTOUT_HOURS widens the window"

# ── ticket-sweep-reminder (needs a session that did code work so it would fire) ──────────────
# The sweep iterates the REPOS of the workspace.sh it sources itself (beside the hook), so the
# sandbox sub-repo takes that list's first name, the same way test-ticket-sweep.sh does.
REPO="$(source "$DIR/../../lib/workspace.sh" >/dev/null 2>&1; printf '%s' "${REPOS[0]:-alpha}")"
mk_sandbox() {
  local S="$1"
  mkdir -p "$S/main/queue" "$S/wt"
  ( cd "$S/main" && git init -q && git config user.email t@t && git config user.name t \
      && printf '## #99 - placeholder\n' > queue/tickets.md && git add -A && git commit -q -m init )
  printf 'export WORKTREE_NAME=test\n' > "$S/wt/worktree.env"
  ( cd "$S/wt" && mkdir "$REPO" && cd "$REPO" && git init -q && git config user.email t@t \
      && git config user.name t && printf 'v1\n' > app.txt && git add -A && git commit -q -m init )
}
sweep_case() { # <session> [env...] -> the sweep's stdout after real work this session
  local S="$T/sb-$1"; mk_sandbox "$S"
  printf '{"session_id":"%s","cwd":"%s/wt"}' "$1" "$S" | META_ROOT="$S/main" bash "$SNAP" >/dev/null 2>&1
  printf 'changed\n' >> "$S/wt/$REPO/app.txt"
  printf '{"session_id":"%s","cwd":"%s/wt","stop_hook_active":false}' "$1" "$S" \
    | env META_ROOT="$S/main" "${@:2}" bash "$SWEEP" 2>/dev/null
}
touch "$OPT/s-fresh"
assert_eq "$(sweep_case s-fresh GOVERN_SESSION_OPTOUT_DIR="$OPT")" "" "sweep: a fresh marker exits silently"
touch "$OPT/s-stale"; old_stamp "$OPT/s-stale"
assert_contains "$(sweep_case s-stale GOVERN_SESSION_OPTOUT_DIR="$OPT")" '"decision":"block"' "sweep: a stale marker runs"
assert_contains "$(sweep_case s-absent GOVERN_SESSION_OPTOUT_DIR="$OPT")" '"decision":"block"' "sweep: no marker runs"
touch "$OPT/s-unset"
assert_contains "$(sweep_case s-unset)" '"decision":"block"' "sweep: switch unset runs"
out="$(sweep_case s-wording)"
assert_contains "$out" "govern:resolve" "sweep: a resolved ticket is landed through govern:resolve"
case "$out" in *"delete it from tickets.md now"*) echo "FAIL - sweep: still tells the session to hand-delete the block"; ASSERT_FAILS=$((ASSERT_FAILS+1)) ;;
  *) echo "ok   - sweep: no longer tells the session to hand-delete the block" ;; esac

# ── sync.sh push-ahead ───────────────────────────────────────────────────────────────────────
if [ -f "$SYNC" ]; then
  W="$T/sync"; mkdir -p "$W/scripts/lib"
  cp "$SYNC" "$W/scripts/sync.sh"
  printf '#!/usr/bin/env bash\nMETA_ROOT="${META_ROOT:-%s}"\nROOT_PM="npm"\nREPOS=(alpha)\n' "$W" > "$W/scripts/lib/workspace.sh"
  git init -q --bare -b main "$W/origin.git"
  git clone -q "$W/origin.git" "$W/alpha" 2>/dev/null
  ( cd "$W/alpha" && git config user.email t@t && git config user.name t && git checkout -q -b main 2>/dev/null
    echo a > a.txt && git add a.txt && git commit -qm a && git push -q -u origin main 2>/dev/null )
  git clone -q "$W/origin.git" "$W/other" 2>/dev/null
  ( cd "$W/other" && git config user.email t@t && git config user.name t )
  run_sync() { ( cd "$W" && env "$@" bash "$W/scripts/sync.sh" 2>&1 ); }
  # Ahead only: a local commit origin lacks. The sub-repo must be clean for sync to touch it.
  ( cd "$W/alpha" && echo b > b.txt && git add b.txt && git commit -qm b )
  local_head="$(git -C "$W/alpha" rev-parse main)"
  run_sync >/dev/null
  assert_eq "$(git -C "$W/origin.git" rev-parse main)" "$(git -C "$W/alpha" rev-parse main~1)" \
    "push-ahead off (default): an ahead main is not pushed"
  out="$(run_sync GOVERN_SYNC_PUSH_AHEAD=1)"
  assert_eq "$(git -C "$W/origin.git" rev-parse main)" "$local_head" "push-ahead on: an ahead-only main is pushed"
  assert_contains "$out" "pushed 1 local main commit(s) to origin" "push-ahead on: and says so"
  # Diverged: origin gains a commit, local gains another.
  ( cd "$W/other" && git pull -q origin main 2>/dev/null; echo c > c.txt && git add c.txt && git commit -qm c && git push -q origin main 2>/dev/null )
  ( cd "$W/alpha" && echo d > d.txt && git add d.txt && git commit -qm d )
  origin_before="$(git -C "$W/origin.git" rev-parse main)"
  out="$(run_sync GOVERN_SYNC_PUSH_AHEAD=1)"
  assert_eq "$(git -C "$W/origin.git" rev-parse main)" "$origin_before" "push-ahead on, diverged: nothing is pushed"
  assert_contains "$out" "ahead by 1 and behind by 1" "push-ahead on, diverged: both counts are printed"
  assert_contains "$out" "log --oneline --left-right main...origin/main" "push-ahead on, diverged: the log command is printed"
else
  echo "ok   - sync.sh not in this layout; push-ahead cases skipped"
fi

assert_done
