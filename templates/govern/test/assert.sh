#!/usr/bin/env bash
# Tiny assertion helper for govern smoke tests.
set -euo pipefail
ASSERT_FAILS=0

# Seed a hermetic workspace stub so a test never depends on the LIVE scripts/lib/workspace.sh (its repo
# list / auto-merge allowlist) — common.sh sources "$GOVERN_WS_ROOT/scripts/lib/workspace.sh", so without
# this a test only "passes" when run from inside a real workspace whose config happens to match. Call it
# right after `mktemp -d`. Pass the auto-merge repos as a comma list (default "alpha"); REPOS = those plus
# a frontend "web" repo (PR-only). Exports GOVERN_WS_ROOT (+ GOVERN_EXTERNALIZE_LANE=0, harmless where the
# externalize lane doesn't exist, required where it does so run-loop's lane doesn't fire under the stub).
#   mk_ws_stub "$T"                 # alpha auto-mergeable, web PR-only
#   mk_ws_stub "$T" "alpha,api"     # alpha + api auto-mergeable
mk_ws_stub() { # <root> [merge-csv]
  local root="$1" merge="${2:-alpha}"
  export GOVERN_WS_ROOT="$root"
  export GOVERN_EXTERNALIZE_LANE=0
  mkdir -p "$root/scripts/lib"
  cat > "$root/scripts/lib/workspace.sh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
META_ROOT="\${META_ROOT:-$root}"
GITHUB_ORG="acme"
REPOS=(${merge//,/ } web)
GOVERN_MERGE_REPOS=(${merge//,/ })
WORKTREE_BASE="$root/wt"
wsp_is_merge_repo() { case ",$merge," in *",\$1,"*) return 0;; *) return 1;; esac; }
wsp_repo_slug() { printf '%s/%s' "\$GITHUB_ORG" "\$1"; }
wsp_repo_localdir() { printf '%s/%s' "\$META_ROOT" "\$1"; }
EOF
}
assert_eq() { # actual expected message
  if [[ "$1" == "$2" ]]; then printf 'ok   - %s\n' "$3"
  else printf 'FAIL - %s\n       expected: [%s]\n       actual:   [%s]\n' "$3" "$2" "$1"; ASSERT_FAILS=$((ASSERT_FAILS+1)); fi
}
assert_contains() { # haystack needle message
  if printf '%s' "$1" | grep -qF "$2"; then printf 'ok   - %s\n' "$3"
  else printf 'FAIL - %s\n       [%s] not found in output\n' "$3" "$2"; ASSERT_FAILS=$((ASSERT_FAILS+1)); fi
}
assert_done() { [[ "$ASSERT_FAILS" -eq 0 ]] || { printf '\n%d assertion(s) failed\n' "$ASSERT_FAILS"; exit 1; }; printf '\nall assertions passed\n'; }
