#!/usr/bin/env bash
# A converge commit that wrote an OLDER exact hub version must not count as drift once the hub
# has changed the file again. The drift walk used to compare each commit's post-state with
# TODAY's template only, so every old /shiploop:update pull turned into "unported" work as soon
# as the hub moved on, and the update flow's marker guard (advance only when --check was clean)
# then refused every later advance.
#
# Proves, against a hub whose template has moved past the version the workspace converged to:
#   A. manifest-covered file: converge to an older shipped version is NOT drift (exit 0)
#   B. a genuine local edit made after that converge IS drift (exit 3), and only that commit is listed
#   C. a mirrored file outside both manifests: converge to an older version found only in the
#      hub's git history is NOT drift (exit 0); a local edit to it IS
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e
TOOL="$(cd "$DIR/.." && pwd)/sync-templates.sh"

SANDBOX="$(mktemp -d)"; trap 'rm -rf "$SANDBOX"' EXIT
sha() { shasum -a 256 | cut -d' ' -f1; }

new_repo() { # <dir>
  mkdir -p "$1"
  git -C "$1" init -q; git -C "$1" config user.email t@t; git -C "$1" config user.name t
}

# ── A + B: manifest-covered mechanism script, templates root is not a git checkout ──
TPL_ROOT="$SANDBOX/a/templates"; TPL="$TPL_ROOT/govern"; mkdir -p "$TPL" "$TPL_ROOT/lib"
printf 'echo v1\n' > "$SANDBOX/v1"; printf 'echo v2\n' > "$SANDBOX/v2"
printf 'echo v3\n' > "$TPL/spawn-worker.sh"
{
  printf '%s  govern/spawn-worker.sh\n' "$(sha < "$SANDBOX/v1")"
  printf '%s  govern/spawn-worker.sh\n' "$(sha < "$SANDBOX/v2")"
  printf '%s  govern/spawn-worker.sh\n' "$(sha < "$TPL/spawn-worker.sh")"
} > "$TPL_ROOT/lib/mechanism-hashes.txt"

REPO="$SANDBOX/a/repo"; new_repo "$REPO"; mkdir -p "$REPO/scripts/govern"
echo 'echo base' > "$REPO/scripts/govern/spawn-worker.sh"
git -C "$REPO" add -A; git -C "$REPO" commit -qm init
BASE="$(git -C "$REPO" rev-parse HEAD)"

export GOVERN_DIR="$REPO/scripts/govern"
export GOVERN_SYNC_MARKER="$REPO/scripts/govern/.templates-synced-at"
export GOVERN_TEMPLATE_DIR="$TPL"
bash "$TOOL" --mark "$BASE" >/dev/null

cp "$SANDBOX/v1" "$REPO/scripts/govern/spawn-worker.sh"
git -C "$REPO" add -A; git -C "$REPO" commit -qm "chore(harness): converge to hub v1"
cp "$SANDBOX/v2" "$REPO/scripts/govern/spawn-worker.sh"
git -C "$REPO" add -A; git -C "$REPO" commit -qm "chore(harness): converge to hub v2"
rc=0; out="$(bash "$TOOL" --check)" || rc=$?
assert_eq "$rc" "0" "A: converges to older shipped versions (template now v3) are not drift"
assert_contains "$out" "in sync" "A: in-sync message"

printf 'echo v2\necho LOCAL_TWEAK\n' > "$REPO/scripts/govern/spawn-worker.sh"
git -C "$REPO" add -A; git -C "$REPO" commit -qm "feat(govern): real local edit"
rc=0; out="$(bash "$TOOL" --check)" || rc=$?
assert_eq "$rc" "3" "B: a genuine local edit after the converges is drift"
assert_contains "$out" "real local edit" "B: the local edit is listed"
assert_not_contains "$out" "converge to hub" "B: the converge commits are not listed"
assert_contains "$out" "1 unported" "B: exactly one commit counted"

# ── C: mirrored file in neither manifest, history lives only in the hub's git ───────
HUB="$SANDBOX/c/hub"; new_repo "$HUB"
TPL_ROOT="$HUB/templates"; TPL="$TPL_ROOT/govern"; mkdir -p "$TPL"
printf 'echo h1\n' > "$TPL/extra-tool.sh"
git -C "$HUB" add -A; git -C "$HUB" commit -qm h1; git -C "$HUB" tag v1.0.0
printf 'echo h2\n' > "$TPL/extra-tool.sh"
git -C "$HUB" add -A; git -C "$HUB" commit -qm h2; git -C "$HUB" tag v1.1.0
printf 'echo h3\n' > "$TPL/extra-tool.sh"
git -C "$HUB" add -A; git -C "$HUB" commit -qm h3

REPO="$SANDBOX/c/repo"; new_repo "$REPO"; mkdir -p "$REPO/scripts/govern"
echo 'echo base' > "$REPO/scripts/govern/extra-tool.sh"
git -C "$REPO" add -A; git -C "$REPO" commit -qm init
BASE="$(git -C "$REPO" rev-parse HEAD)"

export GOVERN_DIR="$REPO/scripts/govern"
export GOVERN_SYNC_MARKER="$REPO/scripts/govern/.templates-synced-at"
export GOVERN_TEMPLATE_DIR="$TPL"
bash "$TOOL" --mark "$BASE" >/dev/null

printf 'echo h1\n' > "$REPO/scripts/govern/extra-tool.sh"
git -C "$REPO" add -A; git -C "$REPO" commit -qm "chore(harness): converge to hub h1"
rc=0; out="$(bash "$TOOL" --check)" || rc=$?
assert_eq "$rc" "0" "C: converge to an old version found only in hub git history is not drift"

printf 'echo h1\necho LOCAL\n' > "$REPO/scripts/govern/extra-tool.sh"
git -C "$REPO" add -A; git -C "$REPO" commit -qm "feat(govern): local edit to unmanifested file"
rc=0; out="$(bash "$TOOL" --check)" || rc=$?
assert_eq "$rc" "3" "C: a local edit to an unmanifested mirrored file is drift"
assert_contains "$out" "local edit to unmanifested file" "C: the edit is listed"

assert_done
