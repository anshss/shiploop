#!/usr/bin/env bash
# Regression: the worktree:rm session-cleanup hook seam and its contract.
#
# A workspace that attaches deployable or billable resources to its worktrees installs
# scripts/lib/session-cleanup.sh; worktree:rm runs it before teardown and honors its
# exit. Covers the contract's shapes:
#   (a) no hook: teardown behaves exactly as the pre-seam script (no hook output);
#   (b) hook exits 0 SILENTLY (nothing to clean: no local stack, no orchestrator
#       reachable): teardown is quiet, never a warning;
#   (c) hook exits 0 with output (it actually cleaned something): the output is shown;
#   (d) hook FAILS with the strict gate off (default best-effort): the failure is
#       printed and the teardown CONTINUES;
#   (e) hook FAILS with GOVERN_RM_CLEANUP_GATE=1: teardown REFUSED (dir left in place,
#       registry intact), waivable per-run with --force-unclean (a flag separate from
#       --force-clean-fail, which waives the live-process gate instead).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

T="$(mktemp -d)"
T="$(cd "$T" && pwd -P)"
trap 'rm -rf "$T"' EXIT

mkdir -p "$T/scripts/worktree/lib" "$T/scripts/lib" "$T/alpha"
cp "$DIR/../../worktree/new.sh" "$T/scripts/worktree/new.sh"
cp "$DIR/../../worktree/rm.sh" "$T/scripts/worktree/rm.sh"
cp "$DIR/../../worktree/lib/registry.sh" "$T/scripts/worktree/lib/registry.sh"
cp "$DIR/../../worktree/lib/base-ref.sh" "$T/scripts/worktree/lib/base-ref.sh"
cat > "$T/scripts/lib/workspace.sh" <<EOF
ROOT_PM=npm
WORKTREE_BASE="$T/wt"
REPOS=(alpha)
REPO_PORTS=("")
SLOT_PORT_STEP=10
wsp_repos_csv() { echo alpha; }
wsp_repo_port() { :; }
EOF

git -C "$T" init -q -b main
git -C "$T" config user.email t@t; git -C "$T" config user.name t
printf '.dispatch-packet.md\nworktree.env\n.env\n/alpha/\n' > "$T/.gitignore"
echo root > "$T/root.txt"; git -C "$T" add -A; git -C "$T" commit -qm init
git -C "$T/alpha" init -q -b main
git -C "$T/alpha" config user.email t@t; git -C "$T/alpha" config user.name t
echo x > "$T/alpha/file.txt"; git -C "$T/alpha" add -A; git -C "$T/alpha" commit -qm init

export WORKTREE_ASSUME_YES=1 WORKTREE_FREE_GB_OVERRIDE=10

# ══ (a) no hook: pre-seam behavior, no hook output at all ═════════════════════════════
(cd "$T" && bash "$T/scripts/worktree/new.sh" ta --skip-bootstrap >/dev/null 2>&1)
assert_eq "$([ -e "$T/wt/ta/alpha/.git" ] && echo y || echo n)" "y" "setup: worktree ta exists"
out_a="$(cd "$T" && bash "$T/scripts/worktree/rm.sh" ta 2>&1)"; rc_a=$?
assert_eq "$rc_a" "0" "no hook: teardown succeeds"
assert_eq "$([ -e "$T/wt/ta" ] && echo y || echo n)" "n" "no hook: the worktree is removed"
assert_contains "$out_a" "removed" "no hook: teardown reports success"

# ══ (b) hook exits 0 SILENTLY (nothing to clean): teardown is QUIET ═══════════════════
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/scripts/lib/session-cleanup.sh"
chmod +x "$T/scripts/lib/session-cleanup.sh"
(cd "$T" && bash "$T/scripts/worktree/new.sh" tb --skip-bootstrap >/dev/null 2>&1)
out_b="$(cd "$T" && bash "$T/scripts/worktree/rm.sh" tb 2>&1)"; rc_b=$?
assert_eq "$rc_b" "0" "nothing to clean: teardown succeeds"
assert_eq "$([ -e "$T/wt/tb" ] && echo y || echo n)" "n" "nothing to clean: the worktree is removed"
case "$out_b" in *session-cleanup*)
  printf 'FAIL - nothing to clean: teardown was NOT quiet (%s)\n' "$out_b"; ASSERT_FAILS=$((ASSERT_FAILS + 1)) ;;
  *) printf 'ok   - nothing to clean: teardown is fully quiet\n' ;;
esac

# ══ (c) hook exits 0 WITH output (it cleaned something): the output is shown ══════════
printf '#!/usr/bin/env bash\necho "closed 1 deploy"\nexit 0\n' > "$T/scripts/lib/session-cleanup.sh"
(cd "$T" && bash "$T/scripts/worktree/new.sh" tc --skip-bootstrap >/dev/null 2>&1)
out_c="$(cd "$T" && bash "$T/scripts/worktree/rm.sh" tc 2>&1)"; rc_c=$?
assert_eq "$rc_c" "0" "cleaned something: teardown succeeds"
assert_contains "$out_c" "closed 1 deploy" "cleaned something: the hook's output is shown"

# ══ (d) hook FAILS, gate off (default best-effort): printed, teardown CONTINUES ═══════
printf '#!/usr/bin/env bash\necho "clean: cannot reach orchestrator" >&2\nexit 1\n' > "$T/scripts/lib/session-cleanup.sh"
(cd "$T" && bash "$T/scripts/worktree/new.sh" td --skip-bootstrap >/dev/null 2>&1)
out_d="$(cd "$T" && bash "$T/scripts/worktree/rm.sh" td 2>&1)"; rc_d=$?
assert_eq "$rc_d" "0" "failure, gate off: teardown continues (best-effort default)"
assert_eq "$([ -e "$T/wt/td" ] && echo y || echo n)" "n" "failure, gate off: the worktree is removed"
assert_contains "$out_d" "cannot reach orchestrator" "failure, gate off: the hook's own output is shown"
assert_contains "$out_d" "session-cleanup failed" "failure, gate off: the failure is named"

# ══ (e) hook FAILS, GOVERN_RM_CLEANUP_GATE=1: REFUSED, --force-unclean waives ═════════
(cd "$T" && bash "$T/scripts/worktree/new.sh" te --skip-bootstrap >/dev/null 2>&1)
out_e="$(cd "$T" && GOVERN_RM_CLEANUP_GATE=1 bash "$T/scripts/worktree/rm.sh" te 2>&1)"; rc_e=$?
assert_eq "$rc_e" "1" "strict gate: removal REFUSED while the cleanup hook fails"
assert_contains "$out_e" "refusing to tear down" "strict gate: the refusal is named"
assert_contains "$out_e" "--force-unclean" "strict gate: names its own waiver flag"
case "$out_e" in *force-clean-fail*)
  printf 'FAIL - strict gate: cleanup refusal names the LIVE-PROCESS waiver flag\n'; ASSERT_FAILS=$((ASSERT_FAILS + 1)) ;;
  *) printf 'ok   - strict gate: refusal never names the live-process waiver\n' ;;
esac
assert_eq "$([ -e "$T/wt/te" ] && echo y || echo n)" "y" \
  "strict gate: the worktree dir is left in place"
assert_contains "$(cd "$T" && bash "$T/scripts/worktree/rm.sh" te-nonexistent 2>&1)" "unknown worktree" \
  "strict gate: registry slot intact for a retry"
# The OTHER waiver flag must not open this gate: --force alone still refuses.
out_ef="$(cd "$T" && GOVERN_RM_CLEANUP_GATE=1 bash "$T/scripts/worktree/rm.sh" te --force 2>&1)"; rc_ef=$?
assert_eq "$rc_ef" "1" "strict gate: plain --force does NOT waive the cleanup refusal"
assert_eq "$([ -e "$T/wt/te" ] && echo y || echo n)" "y" "strict gate: --force alone leaves the dir in place"
# The dedicated flag waives it per-run.
out_eg="$(cd "$T" && GOVERN_RM_CLEANUP_GATE=1 bash "$T/scripts/worktree/rm.sh" te --force-unclean 2>&1)"; rc_eg=$?
assert_eq "$rc_eg" "0" "strict gate: --force-unclean tears down anyway"
assert_contains "$out_eg" "continuing per --force-unclean" "strict gate: the waiver is announced"
assert_eq "$([ -e "$T/wt/te" ] && echo y || echo n)" "n" "strict gate: the worktree is removed"

assert_done
