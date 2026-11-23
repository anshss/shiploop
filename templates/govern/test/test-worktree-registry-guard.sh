#!/usr/bin/env bash
# Regression: the worktree slot registry is MAIN-CHECKOUT-ONLY.
#
# Every dispatch worktree carries its own full copy of scripts/, and registry.sh resolves
# WT_ROOT from its own location — so any registry-touching script invoked with cwd inside a
# worktree (its own package.json, or a relative path) used to resolve WT_ROOT to the
# WORKTREE and operate on <worktree>/.worktrees/registry.json. The first read there
# default-created a registry whose __main__ slot pointed at the worktree itself with
# nextSlot reset to 1, and dispatches registered against that scoped file never reached the
# real registry (the worktree sat on disk, unknown to worktree:rm and govern:resolve).
#
# Covers: sourcing registry.sh from inside a worktree refuses loudly and creates no scoped
# file; the read and re-dispatch paths from inside a worktree create no scoped file; the
# main-checkout flows (default-create, dispatch, removal) are unchanged; wt_registry_write
# refuses any JSON whose slot 0 is not exactly __main__ -> WT_ROOT, and still accepts every
# legitimate writer's output.
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
assert_no_file() { # <path> <label>
  if [[ ! -e "$1" ]]; then printf '  ok   %s\n' "$2"
  else printf '  FAIL %s (file exists: %s)\n' "$2" "$1"; FAILS=$((FAILS + 1)); fi
}

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# ── Sandbox: a real meta-repo root (git, branch main) whose committed tree carries the
# worktree scripts, so the linked worktree new.sh creates holds its own scripts/ copy —
# the exact shape that makes a from-inside-the-worktree invocation resolve WT_ROOT to the
# worktree. ──────────────────────────────────────────────────────────────────────────────────
mkdir -p "$T/scripts/worktree/lib" "$T/scripts/lib"
cp "$DIR/../../worktree/new.sh" "$T/scripts/worktree/new.sh"
cp "$DIR/../../worktree/status.sh" "$T/scripts/worktree/status.sh"
cp "$DIR/../../worktree/rm.sh" "$T/scripts/worktree/rm.sh"
cp "$DIR/../../doctor.sh" "$T/scripts/doctor.sh"
cp "$DIR/../../worktree/lib/registry.sh" "$T/scripts/worktree/lib/registry.sh"
cp "$DIR/../../worktree/lib/base-ref.sh" "$T/scripts/worktree/lib/base-ref.sh"
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

NEW="$T/scripts/worktree/new.sh"
export WORKTREE_ASSUME_YES=1 WORKTREE_FREE_GB_OVERRIDE=10

REG="$T/.worktrees/registry.json"
WT33="$T/.wt/t33"

# ── 1. Healthy dispatch from the main checkout: default-create is correct, slot 1 taken. ────
out1="$(cd "$T" && bash "$NEW" t33 --skip-bootstrap 2>&1)"; rc1=$?
assert_rc 0 "$rc1" "dispatch from the main checkout succeeds"
assert_eq "$(jq -r '.slots["0"].path' "$REG")" "$T" "default-create anchors slot 0 at the main checkout"
assert_eq "$(jq -r '.slots["0"].name' "$REG")" "__main__" "default-create names slot 0 __main__"
assert_eq "$(jq -r '.slots["1"].name' "$REG")" "t33" "dispatch registers the worktree in the real registry"

# ── 2. Sourcing the worktree's own copy from inside the worktree refuses, and writes no
#       scoped registry: the whole library is main-checkout-only. ────────────────────────────
src_err="$(cd "$WT33" && bash -c 'source scripts/worktree/lib/registry.sh' 2>&1 >/dev/null)"; src_rc=$?
assert_rc 1 "$src_rc" "registry.sh sourced from inside a worktree fails"
assert_contains "$src_err" "linked git worktree" "refusal names the worktree-scoped WT_ROOT"
assert_no_file "$WT33/.worktrees/registry.json" "the refused source created no scoped registry"

# ── 3. The reader path from inside the worktree (the write that used to poison slot 0):
#       refused loudly, no scoped file, real registry untouched, and status exits NONZERO —
#       it used to swallow the guard's return (no set -e), render an empty table, and exit 0. ─
before3="$(cat "$REG")"
st_err="$(cd "$WT33" && bash scripts/worktree/status.sh 2>&1 >/dev/null)"; st_rc=$?
assert_rc 1 "$st_rc" "status.sh from inside a worktree exits 1 (not an empty table + rc 0)"
assert_no_file "$WT33/.worktrees/registry.json" "status.sh from inside a worktree creates no scoped registry"
assert_contains "$st_err" "linked git worktree" "status.sh from inside a worktree prints the refusal"
assert_eq "$(cat "$REG")" "$before3" "the real registry is untouched by the worktree-scoped read"

# ── 4. A re-dispatch (the --adopt retry path) run through the worktree's OWN scripts copy —
#       the poison path: refused, no scoped registry, so a dispatch can never register into
#       the wrong file. ────────────────────────────────────────────────────────────────────────
adopt_out="$(cd "$WT33" && bash scripts/worktree/new.sh t33 --skip-bootstrap --adopt 2>&1)"; adopt_rc=$?
assert_rc 1 "$adopt_rc" "re-dispatch through the worktree's scripts copy fails"
assert_contains "$adopt_out" "linked git worktree" "re-dispatch refusal names the scoped context"
assert_no_file "$WT33/.worktrees/registry.json" "the refused re-dispatch created no scoped registry"

# ── 4b. rm.sh --sweep from inside the worktree: the registry read would silently yield
#        nothing there, and the unregistered second pass would then judge every dir on
#        disk as unknown — sweep real worktrees of the main checkout. Must refuse rc 1. ────
sw_err="$(cd "$WT33" && bash scripts/worktree/rm.sh --sweep 2>&1)"; sw_rc=$?
assert_rc 1 "$sw_rc" "rm.sh --sweep from inside a worktree refuses rc 1"
assert_contains "$sw_err" "linked git worktree" "sweep refusal names the worktree-scoped context"

# ── 5. wt_registry_write refuses every slot-0 violation and accepts a legitimate write. ─────
root_src="$T/scripts/worktree/lib/registry.sh"
wr() { # <json> -> prints the rc of the real wt_registry_write against the sandbox registry
  printf '%s' "$1" | ROOT_SRC="$root_src" bash -c 'source "$ROOT_SRC"; wt_registry_write "$(cat)"' >/dev/null 2>&1
  echo $?
}
echo 'sentinel' > "$REG"
wr_rc_foreign=$(wr '{"slots":{"0":{"name":"__main__","path":"/elsewhere"},"1":{"name":"t9","path":"'$T'/.wt/t9"}},"nextSlot":2}')
assert_rc 1 "$wr_rc_foreign" "write with a foreign slot-0 path is refused"
assert_eq "$(cat "$REG")" "sentinel" "the refused foreign write left the registry untouched"
wr_rc_name=$(wr '{"slots":{"0":{"name":"other","path":"'$T'"}},"nextSlot":1}')
assert_rc 1 "$wr_rc_name" "write with a non-__main__ slot-0 name is refused"
wr_rc_missing=$(wr '{"slots":{"1":{"name":"t9","path":"'$T'/.wt/t9"}},"nextSlot":2}')
assert_rc 1 "$wr_rc_missing" "write with slot 0 absent is refused"
wr_rc_junk=$(wr 'not json')
assert_rc 1 "$wr_rc_junk" "unparseable JSON is refused"
wr_rc_ok=$(wr '{"slots":{"0":{"name":"__main__","path":"'$T'"},"1":{"name":"t9","path":"'$T'/.wt/t9","createdAt":"x"}},"nextSlot":2}')
assert_rc 0 "$wr_rc_ok" "a write carrying the correct slot 0 passes"
assert_eq "$(jq -r '.slots["1"].name' "$REG")" "t9" "the accepted write persisted its entry"

# ── 6. Removal round-trip from the main checkout: slot freed, slot 0 still anchored,
#       nextSlot recomputed — the guard never blocks a legitimate writer. ────────────────────
(cd "$T" && bash "$NEW" t34 --skip-bootstrap >/dev/null 2>&1)
rm_out="$(cd "$T" && bash "$T/scripts/worktree/rm.sh" t34 --force --keep-branch 2>&1)"; rm_rc=$?
assert_rc 0 "$rm_rc" "worktree:rm from the main checkout succeeds"
assert_contains "$rm_out" "slot 2 freed" "removal frees the worktree's slot"
assert_eq "$(jq -r '.slots["0"].path' "$REG")" "$T" "slot 0 is still the main checkout after removal"
assert_eq "$(jq -r '.nextSlot' "$REG")" "2" "nextSlot recomputed without slot 0 moving"

# ── 7. doctor reads the registry through the library: refused (rc 1) from inside a
#       worktree, and the guard must fire BEFORE its registry-file-existence test, else
#       the worktree case would warn "registry missing" and exit 0. From the main
#       checkout it reports real state as today. ─────────────────────────────────────────
doc_err="$(cd "$WT33" && bash scripts/doctor.sh 2>&1 >/dev/null)"; doc_rc=$?
assert_rc 1 "$doc_rc" "doctor.sh from inside a worktree aborts rc 1"
assert_contains "$doc_err" "linked git worktree" "doctor refusal names the worktree-scoped context"
doc_out="$(cd "$T" && GOVERN_DOCTOR_WORKTREE_TRUST=0 bash scripts/doctor.sh 2>&1)"; doc_main_rc=$?
assert_rc 0 "$doc_main_rc" "doctor.sh from the main checkout still succeeds"
assert_contains "$doc_out" "1 worktree(s) registered" "doctor from the main checkout reports real registry state"

# ── 8. An inherited WT_ROOT env var is IGNORED: it must not redirect WT_REGISTRY/WT_LOCK
#       away from the main checkout (the guard only catches the linked-worktree case). ─────
env_out="$(cd "$T" && WT_ROOT=/nonexistent bash -c \
  'source scripts/worktree/lib/registry.sh; printf "%s\t%s" "$WT_ROOT" "$WT_REGISTRY"' 2>&1)"; env_rc=$?
assert_rc 0 "$env_rc" "registry.sh sources cleanly from the main checkout despite an inherited WT_ROOT"
assert_eq "$env_out" "$T	$T/.worktrees/registry.json" "inherited WT_ROOT env var does not redirect WT_REGISTRY"

if [[ "$FAILS" -gt 0 ]]; then
  printf '\n%s check(s) FAILED\n' "$FAILS"
  exit 1
fi
printf '\nall checks passed\n'
