#!/usr/bin/env bash
# Regression: registry-UNKNOWN worktree dirs on disk must be visible and reclaimable.
#
# The registry loop in rm.sh --sweep, worktree:status and govern:resolve all iterate the
# REGISTRY only. A directory under WORKTREE_BASE absent from registry.json is invisible to
# every teardown path (worktree:rm's named path exits 1 on unknown names) and rots on disk
# forever. Covers:
#   · worktree:status lists such dirs with an (UNREGISTERED) marker, and does NOT flag
#     registered ones
#   · rm.sh --sweep removes a registry-unknown dir that is packetless, expired (dir mtime
#     older than GOVERN_AGENT_WALLCLOCK), clean, and has no live session
#   · --sweep KEEPS the same dir when it has a live session, uncommitted changes, a
#     .dispatch-packet.md, or a fresh mtime
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FAILS=0
assert_eq() { # <got> <want> <label>
  if [[ "$1" == "$2" ]]; then printf '  ok   %s\n' "$3"
  else printf '  FAIL %s\n       got:  %s\n       want: %s\n' "$3" "$1" "$2"; FAILS=$((FAILS + 1)); fi
}
assert_contains() { # <haystack> <needle> <label>
  if [[ "$1" == *"$2"* ]]; then printf '  ok   %s\n' "$3"
  else printf '  FAIL %s\n       missing from output: %s\n' "$3" "$2"; FAILS=$((FAILS + 1)); fi
}
assert_rc() { # <want-rc> <got-rc> <label>
  if [[ "$2" == "$1" ]]; then printf '  ok   %s\n' "$3"
  else printf '  FAIL %s (rc %s, want %s)\n' "$3" "$2" "$1"; FAILS=$((FAILS + 1)); fi
}
assert_no_dir() { # <path> <label>
  if [[ ! -e "$1" ]]; then printf '  ok   %s\n' "$2"
  else printf '  FAIL %s (dir exists: %s)\n' "$2" "$1"; FAILS=$((FAILS + 1)); fi
}
assert_dir() {
  if [[ -e "$1" ]]; then printf '  ok   %s\n' "$2"
  else printf '  FAIL %s (dir MISSING: %s)\n' "$2" "$1"; FAILS=$((FAILS + 1)); fi
}

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# ── Sandbox: real meta-repo root with the worktree scripts committed, like the guard test. ──
mkdir -p "$T/scripts/worktree/lib" "$T/scripts/lib"
cp "$DIR/../../worktree/status.sh" "$T/scripts/worktree/status.sh"
cp "$DIR/../../worktree/rm.sh" "$T/scripts/worktree/rm.sh"
cp "$DIR/../../worktree/lib/registry.sh" "$T/scripts/worktree/lib/registry.sh"
cat > "$T/scripts/lib/workspace.sh" <<EOF
ROOT_PM=npm
WORKTREE_BASE="$T/.wt"
REPOS=()
REPO_PORTS=()
SLOT_PORT_STEP=10
wsp_repos_csv() { :; }
wsp_repo_port() { :; }
EOF
git -C "$T" init -q -b main
git -C "$T" config user.email t@t && git -C "$T" config user.name t
echo root > "$T/root.txt"
git -C "$T" add -A && git -C "$T" commit -qm init

REG="$T/.worktrees/registry.json"

# Default-create the registry (slot 0 → main checkout).
mkdir -p "$T/.worktrees"
git -C "$T" worktree add -q --detach "$T/.wt/t33" 2>/dev/null
printf '%s\n' "$(jq -n --arg root "$T" '{slots: {"0": {name: "__main__", path: $root}, "1": {name: "t33", path: ($root + "/.wt/t33")}}, nextSlot: 2}')" > "$REG"

OLD="-t 200001010000"   # ancient mtime → older than any GOVERN_AGENT_WALLCLOCK cap

# The five unregistered dirs. Content first, mtime touch LAST (content writes refresh mtime).
git -C "$T" worktree add -q --detach "$T/.wt/t88"                       # the removable one
git -C "$T" worktree add -q --detach "$T/.wt/t_live"                    # live session below
git -C "$T" worktree add -q --detach "$T/.wt/t_dirty"                   # dirty below
git -C "$T" worktree add -q --detach "$T/.wt/t_packet"                  # packet below
git -C "$T" worktree add -q --detach "$T/.wt/t_young"                   # stays fresh
echo junk > "$T/.wt/t_dirty/untracked.txt"
echo x > "$T/.wt/t_packet/.dispatch-packet.md"
touch $OLD "$T/.wt/t88" "$T/.wt/t_live" "$T/.wt/t_dirty" "$T/.wt/t_packet"

# ── 1. status.sh lists all five unregistered dirs and does NOT flag the registered one. ─────
st_out="$(cd "$T" && bash scripts/worktree/status.sh 2>&1)"
assert_eq "$(grep -c 'UNREGISTERED' <<<"$st_out")" "5" "status flags exactly the 5 unregistered dirs"
assert_contains "$st_out" "$T/.wt/t88" "the removable dir appears in the status table"
if grep -q 't33.*UNREGISTERED' <<<"$st_out"; then
  printf '  FAIL registered t33 is flagged UNREGISTERED\n'; FAILS=$((FAILS + 1))
else
  printf '  ok   registered t33 is not flagged\n'
fi

# ── 2. Live session: a process with its cwd inside t_live must block its sweep. ──────────────
SPID=""
( cd "$T/.wt/t_live" && sleep 60 ) & SPID=$!
# Deterministic: wait (bounded) until lsof actually sees the sleeper's cwd inside t_live,
# so the sweep below can't race ahead of the probe. Capture to a variable first — under
# pipefail, `lsof | grep -q` dies on SIGPIPE the moment grep matches and the pipeline
# reports 141, so a direct pipe never registers the match.
live_seen=""
for _ in $(seq 1 100); do
  lsof_out="$(lsof -a +D "$T/.wt/t_live" -d cwd 2>/dev/null)"
  case "$lsof_out" in *"$SPID"*) live_seen=1; break ;; esac
done
if [[ -z "$live_seen" ]]; then
  printf '  FAIL lsof never saw the live session in t_live — test env problem, not a code bug\n'
  FAILS=$((FAILS + 1))
fi

# ── 3. --sweep removes t88 and keeps the four gated ones; registry untouched. ────────────────
before_reg="$(cat "$REG")"
sweep_out="$(cd "$T" && bash scripts/worktree/rm.sh --sweep 2>&1)"; sweep_rc=$?
kill "$SPID" 2>/dev/null
assert_rc 0 "$sweep_rc" "sweep exits 0"
assert_contains "$sweep_out" "unregistered: 1 removed, 4 kept" "sweep summary counts both directions"
assert_no_dir "$T/.wt/t88" "clean + packetless + expired unregistered dir is removed"
assert_dir "$T/.wt/t_live" "dir with a live session is kept"
assert_contains "$sweep_out" "live-session(pids:" "the live-session blocker is named"
assert_dir "$T/.wt/t_dirty" "dirty dir is kept"
assert_contains "$sweep_out" "uncommitted changes" "the dirty blocker is named"
assert_dir "$T/.wt/t_packet" "packet-bearing dir is kept (preserved-worker scope)"
assert_contains "$sweep_out" ".dispatch-packet.md" "the packet blocker is named"
assert_dir "$T/.wt/t_young" "fresh (too-young) dir is kept"
assert_contains "$sweep_out" "cap 3600s" "the age blocker is named"
assert_eq "$(cat "$REG")" "$before_reg" "the registry is untouched by the unregistered sweep"
assert_eq "$(git -C "$T" worktree list --porcelain | grep -c "^worktree $T/.wt/t88$")" "0" \
  "git worktree metadata no longer lists the swept dir"

if [[ "$FAILS" -gt 0 ]]; then
  printf '\n%s check(s) FAILED\n' "$FAILS"
  exit 1
fi
printf '\nall checks passed\n'
