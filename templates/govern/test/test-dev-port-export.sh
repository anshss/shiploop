#!/usr/bin/env bash
# dev.sh port export: the per-repo port was computed and freed but NEVER exported, so a dev command
# interpolating its own port var (e.g. `${MYREPO_PORT} --port`) evaluated an ALWAYS-EMPTY variable
# and silently bound a fallback port instead of the slot's advertised one. Now dev.sh exports
# wsp_repo_portvar's variable (repo name uppercased, `_PORT`) before running the command, and
# REFUSES a non-numeric port loudly instead of exporting garbage.
# Negative controls: a repo with no port var configured boots untouched, and the refusal skips the
# repo rather than booting it on a wrong port.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/scripts/lib" "$T/alpha" "$T/web" "$T/logs"
cp "$DIR/../../dev.sh" "$T/scripts/dev.sh"

cat > "$T/scripts/lib/workspace.sh" <<'EOF'
META_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ROOT_PM="npm"
REPOS=(alpha web)
REPO_CMDS=('echo "PORT=$ALPHA_PORT"' 'echo "WEB-PORT=${WEB_PORT:-empty}"')
REPO_PORTS=(4321 "")
SLOT_PORT_STEP=10
wsp_repos_csv() { printf 'alpha,web'; }
wsp_repo_index() {
  local r="$1" i
  for i in "${!REPOS[@]}"; do [ "${REPOS[$i]}" = "$r" ] && { echo "$i"; return 0; }; done
  return 1
}
wsp_repo_port() {
  local i base
  i=$(wsp_repo_index "$1") || return 0
  base="${REPO_PORTS[$i]:-}"
  [ -n "$base" ] || return 0
  echo $(( base + ${2:-0} * SLOT_PORT_STEP ))
}
wsp_repo_portvar() {
  local i name
  i=$(wsp_repo_index "$1") || return 0
  name="${REPOS[$i]}"
  [ -n "$name" ] || return 0
  printf '%s_PORT\n' "$(printf '%s' "$name" | tr '[:lower:]-' '[:upper:]_')"
}
wsp_repo_cmd() {
  local i
  i=$(wsp_repo_index "$1") || return 0
  echo "${REPO_CMDS[$i]:-}"
}
EOF

# 1. The port var is exported under the repo's own name before its command runs.
bash "$T/scripts/dev.sh" > /dev/null 2>"$T/err.txt"
assert_contains "$(cat "$T/logs/alpha.log" 2>/dev/null)" "PORT=4321" "alpha's dev command sees \$ALPHA_PORT=4321 (was always empty before)"

# 2. Negative control: a repo with NO base port still boots (its portvar exports nothing numeric —
#    wsp_repo_port returns empty, the refusal fires, and the command does NOT run with a fake port).
assert_contains "$(cat "$T/err.txt" 2>/dev/null)" "refusing to boot web" "a non-resolvable port refuses loudly instead of exporting garbage"
assert_not_contains "$(cat "$T/logs/web.log" 2>/dev/null)" "WEB-PORT=" "the refused repo's command never ran"

# 3. portvar naming: dash maps to underscore, uppercase.
. "$T/scripts/lib/workspace.sh"
assert_eq "$(wsp_repo_portvar alpha)" "ALPHA_PORT" "portvar is <REPO>_PORT uppercased"

assert_done
