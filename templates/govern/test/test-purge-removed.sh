#!/usr/bin/env bash
# Regression for scaffold.sh's purge pass (templates/lib/purge.txt).
#
# scaffold's components only copy IN — they never remove. So when the hub RETIRES a
# template, every workspace that ever installed it keeps the dead file forever. The
# purge manifest is the removal channel: any writer run (fresh scaffold, single-component
# refresh, /shiploop:update) deletes every path listed in it.
#
# Contract:
#   1. A writer run removes a retired FILE listed in purge.txt.
#   2. A trailing-slash entry removes a whole DIRECTORY, recursively.
#   3. Standalone --verify (read-only mode) WARNS and deletes nothing — it must never
#      write, and a purge is a write.
#   4. Unsafe manifest paths (absolute, or containing ..) are refused, so a malformed
#      manifest line can never rm outside the workspace.
#   5. Purge is idempotent + silent when there is nothing to remove.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

# Requires a hub checkout — scaffold.sh + templates/ at ../../../..
HUB="$(cd "$DIR/../../.." && pwd)"
[ -f "$HUB/scaffold.sh" ] && [ -d "$HUB/templates" ] || \
  { echo "SKIP: not running from a hub checkout ($HUB)" >&2; exit 77; }
SCAFFOLD="$HUB/scaffold.sh"

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
W="$ROOT/ws"; mkdir -p "$W"

# Private templates copy so the unsafe-path case can extend the manifest without
# touching the hub's real one.
TEMPLATES="$ROOT/templates"
cp -R "$HUB/templates" "$TEMPLATES"

scaffold_fresh() {
  bash "$SCAFFOLD" --workspace-dir "$W" --templates "$TEMPLATES" \
    --pm npm --org purge-test-org \
    --repos "alpha:3000:echo alpha,web:3001:echo web" \
    --merge-allowlist "alpha" --worktree-base "$W.wt" --yes >"$ROOT/scaffold.log" 2>&1
}

scaffold_fresh
assert_eq "$?" "0" "0. fresh scaffold succeeds"

exists() { [ -e "$1" ] && echo present || echo absent; }

# Purge deletes only bytes that are a version the hub shipped (sha256 in mechanism-hashes.txt,
# keyed by installed path). `shipped <installed-path>` records the fixture's current bytes there,
# in the private templates copy, standing in for "an older shiploop installed exactly this".
shipped() { # <installed-path-relative-to-workspace>
  printf '%s  %s\n' "$(shasum -a 256 "$W/$1" | cut -d' ' -f1)" "$1" >> "$TEMPLATES/lib/mechanism-hashes.txt"
}

# ── 1 + 2. A writer run removes a retired file and a retired directory ─────
# Simulate an OLD install: re-create paths a previous shiploop shipped and the
# current purge.txt lists.
printf '#!/usr/bin/env bash\necho legacy\n' > "$W/scripts/status.sh"
mkdir -p "$W/.claude/commands" && printf '# legacy\n' > "$W/.claude/commands/resolve.md"
mkdir -p "$W/scripts/govern/test" && printf '# legacy\n' > "$W/scripts/govern/test/test-legacy.sh"
shipped scripts/status.sh; shipped .claude/commands/resolve.md; shipped scripts/govern/test/test-legacy.sh

bash "$SCAFFOLD" --workspace-dir "$W" --templates "$TEMPLATES" --component core-scripts --yes \
  >"$ROOT/purge.log" 2>&1
assert_eq "$?" "0" "1a. component refresh succeeds"
purge_log="$(cat "$ROOT/purge.log")"
assert_eq "$(exists "$W/scripts/status.sh")" "absent" "1b. retired file purged"
assert_eq "$(exists "$W/.claude/commands/resolve.md")" "absent" "1c. retired command purged"
assert_eq "$(exists "$W/scripts/govern/test")" "absent" "2. retired directory purged recursively"
assert_contains "$purge_log" "removed scripts/status.sh" "1d. purge reports each removal"

# The purge must not take live files with it.
assert_eq "$(exists "$W/scripts/doctor.sh")" "present" "1e. still-shipped script survives the purge"
assert_eq "$(exists "$W/scripts/lib/workspace.sh")" "present" "1f. operator config survives the purge"

# ── 3. Standalone --verify warns, never deletes ────────────────────────────
printf '#!/usr/bin/env bash\necho legacy\n' > "$W/scripts/status.sh"
( cd "$W" && bash "$SCAFFOLD" --verify >"$ROOT/verify.log" 2>&1 )
assert_eq "$?" "0" "3a. standalone --verify succeeds"
verify_log="$(cat "$ROOT/verify.log")"
assert_eq "$(exists "$W/scripts/status.sh")" "present" "3b. read-only --verify did NOT delete"
assert_contains "$verify_log" "retired-but-present: scripts/status.sh" "3c. --verify warns instead"
rm -f "$W/scripts/status.sh"

# ── 4. Unsafe manifest paths are refused ───────────────────────────────────
OUTSIDE="$ROOT/outside-the-workspace"
printf 'do not touch\n' > "$OUTSIDE"
printf 'do not touch\n' > "$ROOT/parent-escape"
{
  printf '%s\n' "$OUTSIDE"
  printf '%s\n' "../parent-escape"
} >> "$TEMPLATES/lib/purge.txt"

bash "$SCAFFOLD" --workspace-dir "$W" --templates "$TEMPLATES" --component core-scripts --yes \
  >"$ROOT/unsafe.log" 2>&1
assert_eq "$?" "0" "4a. writer run with an unsafe manifest still succeeds"
unsafe_log="$(cat "$ROOT/unsafe.log")"
assert_eq "$(exists "$OUTSIDE")" "present" "4b. absolute manifest path refused"
assert_eq "$(exists "$ROOT/parent-escape")" "present" "4c. parent-escaping manifest path refused"
assert_contains "$unsafe_log" "ignoring unsafe manifest path" "4d. unsafe paths are reported"

# ── 5. Nothing to purge → silent + idempotent ──────────────────────────────
bash "$SCAFFOLD" --workspace-dir "$W" --templates "$TEMPLATES" --component core-scripts --yes \
  >"$ROOT/clean.log" 2>&1
assert_eq "$?" "0" "5a. second refresh succeeds"
clean_log="$(cat "$ROOT/clean.log")"
assert_not_contains "$clean_log" "purge: removing files retired by the hub" \
  "5b. purge stays silent when there is nothing to remove"

# ── 6. a retired file carrying LOCAL EDITS is kept, not deleted ────────────
# The retired file may still be wired into the workspace (a package.json script), so purge only
# removes bytes that are provably a shipped version.
printf '#!/usr/bin/env bash\necho legacy\n' > "$W/scripts/status.sh"      # recorded above: pristine
printf '#!/usr/bin/env bash\necho local fix\n' > "$W/scripts/branch.sh"    # purge.txt path, unrecorded bytes
mkdir -p "$W/scripts/govern/test"
printf '# legacy\n' > "$W/scripts/govern/test/test-legacy.sh"                # recorded: pristine
printf '# my own test\n' > "$W/scripts/govern/test/test-mine.sh"             # workspace's own file
bash "$SCAFFOLD" --workspace-dir "$W" --templates "$TEMPLATES" --component core-scripts --yes \
  >"$ROOT/keep.log" 2>&1
keep_log="$(cat "$ROOT/keep.log")"
assert_eq "$(exists "$W/scripts/status.sh")" "absent" "6a. pristine retired file is deleted"
assert_eq "$(exists "$W/scripts/branch.sh")" "present" "6b. locally edited retired file is KEPT"
assert_contains "$(cat "$W/scripts/branch.sh")" "local fix" "6b. and its content is untouched"
assert_contains "$keep_log" "retired by the hub, kept because it carries local edits: scripts/branch.sh" \
  "6c. named in the KEPT summary"
assert_contains "$keep_log" "/shiploop:push" "6c. summary says how to resolve it"
assert_eq "$(exists "$W/scripts/govern/test/test-mine.sh")" "present" "6d. workspace-owned file inside a retired dir is kept"
assert_eq "$(exists "$W/scripts/govern/test/test-legacy.sh")" "absent" "6d. pristine file inside it is deleted"
stamp="$(awk 'NF && $0 !~ /^#/ {print $1; exit}' "$W/scripts/lib/.harness-version" 2>/dev/null)"
printf '0.0.1\n' > "$W/scripts/lib/.harness-version"
bash "$SCAFFOLD" --workspace-dir "$W" --templates "$TEMPLATES" --component core-scripts --yes >/dev/null 2>&1
assert_eq "$(awk 'NF && $0 !~ /^#/ {print $1; exit}' "$W/scripts/lib/.harness-version")" "0.0.1" \
  "6e. stamp not advanced while a retired file is kept"
bash "$SCAFFOLD" --workspace-dir "$W" --templates "$TEMPLATES" --component core-scripts --yes --overwrite-local-edits \
  >"$ROOT/ow.log" 2>&1
assert_eq "$(exists "$W/scripts/branch.sh")" "absent" "6f. --overwrite-local-edits deletes the edited retired file"
assert_eq "$(exists "$W/scripts/govern/test")" "absent" "6f. and the whole retired directory"

assert_done
