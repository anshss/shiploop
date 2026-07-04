#!/usr/bin/env bash
# Tiny assertion helper for govern smoke tests.
set -euo pipefail
ASSERT_FAILS=0

# ── Layout resolver (#255) ──────────────────────────────────────────────────
# These tests run in TWO layouts: a live workspace (govern at scripts/govern/, prompt
# files at <root>/governor/, hooks at <root>/scripts/) and the template repo itself
# (govern at templates/govern/, prompts at templates/governor/, hooks at templates/hooks/).
# Probe both so the suite is green out-of-the-box in either — with NO scaffolded workspace
# present. assert.sh sits in <…>/govern/test/, so resolve relative to its own location.
ASSERT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Governor prompt dir: templates/governor (template) | <root>/governor (workspace).
for _cand in "$ASSERT_DIR/../../governor" "$ASSERT_DIR/../../../governor"; do
  if [[ -f "$_cand/worker-prompt.md" ]]; then GOVERN_PROMPTS_DIR="$(cd "$_cand" && pwd)"; break; fi
done
# Hooks dir (session-snapshot.sh + ticket-sweep-reminder.sh): templates/hooks (template) |
# <root>/scripts (workspace, where the hooks install beside govern/).
for _cand in "$ASSERT_DIR/../../hooks" "$ASSERT_DIR/../.."; do
  if [[ -f "$_cand/session-snapshot.sh" ]]; then GOVERN_HOOKS_DIR="$(cd "$_cand" && pwd)"; break; fi
done
export GOVERN_PROMPTS_DIR="${GOVERN_PROMPTS_DIR:-}" GOVERN_HOOKS_DIR="${GOVERN_HOOKS_DIR:-}"

# Seed a hermetic workspace stub so a test never depends on the LIVE scripts/lib/workspace.sh (its repo
# list / auto-merge allowlist) — common.sh sources "$GOVERN_WS_ROOT/scripts/lib/workspace.sh", so without
# this a test only "passes" when run from inside a real workspace whose config happens to match. Call it
# right after `mktemp -d`. Pass the auto-merge repos as a comma list (default "alpha"); REPOS = those plus
# a frontend "web" repo (PR-only). Exports GOVERN_WS_ROOT (+ GOVERN_EXTERNALIZE_LANE=0, harmless where the
# externalize lane doesn't exist, required where it does so run-loop's lane doesn't fire under the stub).
#   mk_ws_stub "$T"                     # alpha auto-mergeable, web PR-only
#   mk_ws_stub "$T" "alpha,api"         # alpha + api auto-mergeable
#   mk_ws_stub "$T" "" "alpha"          # alpha PR-only AND local-first (#72)
mk_ws_stub() { # <root> [merge-csv] [local-first-csv]
  local root="$1" merge="${2:-alpha}" localfirst="${3:-}"
  export GOVERN_WS_ROOT="$root"
  export GOVERN_EXTERNALIZE_LANE=0
  mkdir -p "$root/scripts/lib"
  cat > "$root/scripts/lib/workspace.sh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
META_ROOT="\${META_ROOT:-$root}"
GITHUB_ORG="acme"
REPOS=(${merge//,/ } web)
GOVERN_MERGE_REPOS="${merge//,/ }"
GOVERN_LOCAL_FIRST_REPOS="${localfirst//,/ }"
WORKTREE_BASE="$root/wt"
wsp_is_merge_repo() { case ",$merge," in *",\$1,"*) return 0;; *) return 1;; esac; }
wsp_is_local_first_repo() { case ",$localfirst," in *",\$1,"*) return 0;; *) return 1;; esac; }
wsp_repo_slug() { printf '%s/%s' "\$GITHUB_ORG" "\$1"; }
wsp_repo_localdir() { printf '%s/%s' "\$META_ROOT" "\$1"; }
EOF
}
assert_eq() { # actual expected message
  if [[ "$1" == "$2" ]]; then printf 'ok   - %s\n' "$3"
  else printf 'FAIL - %s\n       expected: [%s]\n       actual:   [%s]\n' "$3" "$2" "$1"; ASSERT_FAILS=$((ASSERT_FAILS+1)); fi
}
assert_contains() { # haystack needle message
  # `grep <<<"$1"` (here-string), NOT `printf "$1" | grep -q`: a -q grep exits on first match and
  # SIGPIPEs the printf, which `set -o pipefail` then reports as a pipeline failure once the haystack
  # exceeds the 64KB pipe buffer (e.g. cat of a large script) — a false "not found" (#183).
  if grep -qF "$2" <<<"$1"; then printf 'ok   - %s\n' "$3"
  else printf 'FAIL - %s\n       [%s] not found in output\n' "$3" "$2"; ASSERT_FAILS=$((ASSERT_FAILS+1)); fi
}
assert_done() { [[ "$ASSERT_FAILS" -eq 0 ]] || { printf '\n%d assertion(s) failed\n' "$ASSERT_FAILS"; exit 1; }; printf '\nall assertions passed\n'; }
