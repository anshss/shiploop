#!/usr/bin/env bash
# check-main-on-main.sh reports pending-sync markers (governor/.pending-sync/<repo>): one non-blocking
# line per marker, and a marker whose recorded sha the checkout's HEAD already contains is deleted
# silently. Local git only. Self-contained: no assert.sh, no scaffolded workspace. Exit 77 = SKIP.
# Run: bash templates/hooks/test-pending-sync-hook.sh
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/check-main-on-main.sh"
[ -f "$HOOK" ] || { echo "SKIP: check-main-on-main.sh not found beside this test"; exit 77; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git required"; exit 77; }

pass=0; fail=0
check() { # <description> <expected> <actual>
  if [ "$2" = "$3" ]; then pass=$((pass+1)); printf 'ok   - %s\n' "$1"
  else fail=$((fail+1)); printf 'FAIL - %s\n       expected: [%s]\n       actual:   [%s]\n' "$1" "$2" "$3"; fi
}

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
mkdir -p "$W/scripts/lib" "$W/governor"
cp "$HOOK" "$W/scripts/check-main-on-main.sh"
cat > "$W/scripts/lib/workspace.sh" <<'EOF'
ROOT_PM="npm"
REPOS=(alpha)
EOF
git init -q -b main "$W" && git -C "$W" config user.email t@t && git -C "$W" config user.name t
git init -q -b main "$W/alpha" && git -C "$W/alpha" config user.email t@t && git -C "$W/alpha" config user.name t
( cd "$W/alpha" && echo a > a.txt && git add a.txt && git commit -qm a )
HAVE="$(git -C "$W/alpha" rev-parse HEAD)"
M="$W/governor/.pending-sync/alpha"
run_hook() { ( cd "$W" && bash "$W/scripts/check-main-on-main.sh" 2>&1; echo "rc=$?" ); }

# ── no markers: nothing printed ──────────────────────────────────────────────────────────────────
check "no marker directory: silent, exit 0" "rc=0" "$(run_hook)"

# ── a marker whose sha the checkout does not contain prints one line and stays ───────────────────
mkdir -p "$W/governor/.pending-sync"
printf '%s 2026-11-23T10:00:00Z live-run\n' "0123456789abcdef0123456789abcdef01234567" > "$M"
out="$(run_hook)"
check "a pending marker prints one line" "alpha: local main is behind origin (live-run since 2026-11-23T10:00:00Z); run npm run sync once no run is live
rc=0" "$out"
check "...and the marker is kept" "yes" "$([ -f "$M" ] && echo yes || echo no)"

# ── ff-failed reason is reported as recorded ─────────────────────────────────────────────────────
printf '%s 2026-11-23T11:30:00Z ff-failed\n' "0123456789abcdef0123456789abcdef01234567" > "$M"
check "the recorded reason and time appear in the line" "alpha: local main is behind origin (ff-failed since 2026-11-23T11:30:00Z); run npm run sync once no run is live
rc=0" "$(run_hook)"

# ── a marker whose sha HEAD already contains is deleted silently ─────────────────────────────────
printf '%s 2026-11-23T10:00:00Z live-run\n' "$HAVE" > "$M"
check "a marker whose sha the checkout already contains prints nothing" "rc=0" "$(run_hook)"
check "...and is deleted" "no" "$([ -f "$M" ] && echo yes || echo no)"

# ── a marker with no readable sha is kept and reported ───────────────────────────────────────────
printf -- '- 2026-11-23T10:00:00Z live-run\n' > "$M"
check "a marker with no sha (-) still reports" "alpha: local main is behind origin (live-run since 2026-11-23T10:00:00Z); run npm run sync once no run is live
rc=0" "$(run_hook)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
