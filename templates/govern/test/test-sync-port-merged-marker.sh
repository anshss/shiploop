#!/usr/bin/env bash
# N2 — after a human MERGES the NO_MERGE review PR, sync-port must advance the
# sync marker WITHOUT re-spawning a porter. Before this fix the NO_MERGE path
# exited before the marker advance, so the next run saw identical marker+drift,
# re-cut the same branch, and re-spawned a full porter against a tree that
# already carried the change (fails the "committed nothing" gate → escalates
# forever). Now: a MERGED PR for the drift branch → --mark + CAS-commit, exit 0.
#
# Proves (with a `gh` stub in PATH reporting a merged PR):
#   1. exit 0, marker advanced to live HEAD.
#   2. the porter binary is NEVER invoked (no respawn).
#   3. output states the merged PR was detected.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e
TOOL="$(cd "$DIR/.." && pwd)/sync-port.sh"
STPL="$(cd "$DIR/.." && pwd)/sync-templates.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 77; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

# ── Build a sandbox: harness repo (fake identity + a mirrored file + marker + drift) + templates repo ──
H="$ROOT/harness"; T="$ROOT/templates"
mkdir -p "$H/scripts/govern" "$H/scripts/lib" "$H/governor" "$H/queue"
mkdir -p "$T/templates/govern/test" "$T/templates/lib"
cat > "$H/scripts/lib/workspace.sh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
META_ROOT="\${META_ROOT:-$H}"
META_NAME="acmeproduct"
ROOT_PM="npm"
GITHUB_ORG="AcmeOrg"
REPOS=(alpha web)
GOVERN_MERGE_REPOS="alpha shiploop"
GOVERN_UPSTREAM_HARNESS_REPO="shiploop"
GOVERN_UPSTREAM_HARNESS_DIR="$T"
GOVERN_META_REPO_SLUG="acme/shiploop"
wsp_repo_slug() { case "\$1" in shiploop) printf '%s' "\$GOVERN_META_REPO_SLUG";; *) printf '%s/%s' "\$GITHUB_ORG" "\$1";; esac; }
wsp_repo_localdir() { case "\$1" in shiploop) printf '%s' "$T";; *) printf '%s/%s' "\$META_ROOT" "\$1";; esac; }
wsp_is_merge_repo() { local r="\$1" a; for a in \$GOVERN_MERGE_REPOS; do [ "\$r" = "\$a" ] && return 0; done; return 1; }
EOF
printf 'echo run\n' > "$H/scripts/govern/run-loop.sh"
printf '# marker placeholder\n' > "$H/scripts/govern/.templates-synced-at"
printf '# Escalations\n\n## Open\n' > "$H/governor/escalations.md"
printf '# tickets\n' > "$H/queue/tickets.md"
git -C "$H" init -q; git -C "$H" config user.email t@t; git -C "$H" config user.name t
git -C "$H" add -A; git -C "$H" commit -qm init >/dev/null
BASE="$(git -C "$H" rev-parse HEAD)"

# templates repo: the counterpart (so drift is "mirrored")
printf 'echo run\n' > "$T/templates/govern/run-loop.sh"
git -C "$T" init -q; git -C "$T" config user.email t@t; git -C "$T" config user.name t
git -C "$T" add -A; git -C "$T" commit -qm "init templates" >/dev/null

# mark BASE, then create drift (a local improvement to the mirrored file)
GOVERN_DIR="$H/scripts/govern" GOVERN_SYNC_MARKER="$H/scripts/govern/.templates-synced-at" \
  GOVERN_TEMPLATE_DIR="$T/templates/govern" bash "$STPL" --mark "$BASE" >/dev/null
git -C "$H" add -A; git -C "$H" commit -qm "mark base" >/dev/null
printf 'echo run v2\n' >> "$H/scripts/govern/run-loop.sh"
git -C "$H" add -A; git -C "$H" commit -qm "feat: improve run-loop mechanism" >/dev/null
MARK_TO="$(git -C "$H" rev-parse HEAD)"

# ── stubs ──
# gh: reports a MERGED PR for any `pr list --state merged`, empty for open.
gh="$ROOT/gh"; cat > "$gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"--state merged"*) echo "99";;
  *"pr list"*)        echo "";;
  *)                  exit 0;;
esac
EOF
chmod +x "$gh"
# porter: touches a sentinel so we can prove it is NEVER invoked.
porter="$ROOT/porter"; sentinel="$ROOT/porter-was-called"
printf '#!/usr/bin/env bash\ntouch "%s"\n' "$sentinel" > "$porter"; chmod +x "$porter"

out="$(
  export GOVERN_WS_ROOT="$H"
  export GOVERN_TICKETS_FILE="$H/queue/tickets.md"
  export GOVERN_ESCALATIONS_FILE="$H/governor/escalations.md"
  export GOVERN_DIR="$H/scripts/govern"
  export GOVERN_SYNC_MARKER="$H/scripts/govern/.templates-synced-at"
  export GOVERN_TEMPLATE_DIR="$T/templates/govern"
  export GOVERN_TEMPLATE_REPO_DIR="$T"
  export GOVERN_NO_PUSH=1
  export GOVERN_GH_BIN="$gh"
  export GOVERN_CLAUDE_BIN="$porter"
  bash "$TOOL" 2>&1
)"; rc=$?

assert_eq "$rc" "0" "merged PR → exit 0 (no respawn, no escalation)"
assert_contains "$out" "merged PR #99" "output states the merged PR was detected"
assert_eq "$( [ -e "$sentinel" ] && echo yes || echo no )" "no" "porter NEVER invoked (no respawn)"
assert_contains "$(cat "$H/scripts/govern/.templates-synced-at" 2>/dev/null)" "$MARK_TO" "marker advanced to live HEAD"
# the advance is a real commit, not a dirty tree
dirty="$(git -C "$H" status --porcelain -- scripts/govern/.templates-synced-at 2>/dev/null)"
assert_eq "$dirty" "" "marker advance committed same-step (no dirty tree)"

assert_done
