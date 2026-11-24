#!/usr/bin/env bash
# Regression: /shiploop:update must not overwrite a locally edited githook, project command or
# agent definition, and must not re-add a template .gitignore line the workspace removed.
#
# Contract (mechanism_install_component + component_gitignore in scaffold.sh):
#   a. an edited .githooks/pre-commit, .claude/agents/worker.md and .claude/commands/flows.md
#      survive an update, each with the hub version beside it as .shiploop-new, a KEPT block, and
#      the .harness-version stamp held
#   b. an unedited older shipped version of each is upgraded, silently
#   c. a worker.md whose only difference is the operator's maxTurns is not a local edit
#   d. a template ignore line the workspace removed stays removed across repeated updates, with
#      or without a record from an earlier update, while a genuinely new template line is appended
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

HUB="$(cd "$DIR/../../.." && pwd)"
[ -f "$HUB/scaffold.sh" ] && [ -f "$HUB/VERSION" ] && [ -d "$HUB/templates" ] || \
  { echo "SKIP: not running from a hub checkout ($HUB)" >&2; exit 77; }
SCAFFOLD="$HUB/scaffold.sh"
TEMPLATES="$HUB/templates"

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
LOG="$ROOT/out.log"

run_scaffold() { # <workspace> <templates> [extra scaffold args...]
  local ws="$1" tpl="$2"; shift 2
  bash "$SCAFFOLD" --workspace-dir "$ws" --templates "$tpl" "$@" --yes </dev/null >"$LOG" 2>&1 &
  bg_reap "$!"
  wait $!
}

W="$ROOT/ws"; mkdir -p "$W"
run_scaffold "$W" "$TEMPLATES" --pm npm --org testorg --repos "alpha::echo alpha" \
  --merge-allowlist "" --worktree-base "$W.wt" --component workspace-sh
for c in core-scripts worktrees govern githooks commands agents workflows; do
  run_scaffold "$W" "$TEMPLATES" --component "$c"
done
run_scaffold "$W" "$TEMPLATES" --component config-merge
stamp() { awk 'NF && $0 !~ /^#/ {print $1; exit}' "$1/scripts/lib/.harness-version" 2>/dev/null; }
v="$(awk 'NF && $0 !~ /^#/ {print $1; exit}' "$HUB/VERSION")"
assert_eq "$(stamp "$W")" "$v" "0. fresh converged workspace is stamped with the hub VERSION"

# ── a. local edits survive, hub copy lands beside each, stamp holds ─────────────────────────
Wa="$ROOT/wsa"; cp -R "$W" "$Wa"
printf '\n# LOCAL HOOK\n' >> "$Wa/.githooks/pre-commit"
printf '\n# LOCAL AGENT\n' >> "$Wa/.claude/agents/worker.md"
printf '\n# LOCAL COMMAND\n' >> "$Wa/.claude/commands/flows.md"
printf '0.0.1\n' > "$Wa/scripts/lib/.harness-version"
outa=""
for c in githooks agents commands; do
  run_scaffold "$Wa" "$TEMPLATES" --component "$c"
  outa+="$(cat "$LOG")"$'\n'
done
assert_contains "$(tail -c 100 "$Wa/.githooks/pre-commit")" "LOCAL HOOK" "a. edited githook is kept"
assert_contains "$(tail -c 100 "$Wa/.claude/agents/worker.md")" "LOCAL AGENT" "a. edited agent is kept"
assert_contains "$(tail -c 100 "$Wa/.claude/commands/flows.md")" "LOCAL COMMAND" "a. edited project command is kept"
cmp -s "$Wa/.githooks/pre-commit.shiploop-new" "$TEMPLATES/githooks/pre-commit" && r=hub || r=other
assert_eq "$r" "hub" "a. hub githook written beside the kept one"
cmp -s "$Wa/.claude/agents/worker.md.shiploop-new" "$TEMPLATES/.claude/agents/worker.md" && r=hub || r=other
assert_eq "$r" "hub" "a. hub agent written beside the kept one"
cmp -s "$Wa/.claude/commands/flows.md.shiploop-new" "$TEMPLATES/.claude/commands/flows.md" && r=hub || r=other
assert_eq "$r" "hub" "a. hub command written beside the kept one"
[ -x "$Wa/.githooks/pre-commit" ] && r=exec || r=noexec
assert_eq "$r" "exec" "a. kept githook is still executable"
assert_contains "$outa" "KEPT" "a. loud kept summary printed"
assert_eq "$(stamp "$Wa")" "0.0.1" "a. stamp NOT advanced while files are kept"

# ── b. an unedited older shipped version is upgraded ────────────────────────────────────────
T2="$ROOT/tpl2"; cp -R "$TEMPLATES" "$T2"
printf '\n# newer hub hook\n' >> "$T2/githooks/pre-commit"
printf '\n# newer hub agent\n' >> "$T2/.claude/agents/worker.md"
printf '\n# newer hub command\n' >> "$T2/.claude/commands/flows.md"
Wb="$ROOT/wsb"; cp -R "$W" "$Wb"
outb=""
for c in githooks agents commands; do
  run_scaffold "$Wb" "$T2" --component "$c"
  outb+="$(cat "$LOG")"$'\n'
done
cmp -s "$Wb/.githooks/pre-commit" "$T2/githooks/pre-commit" && r=upgraded || r=stale
assert_eq "$r" "upgraded" "b. unedited older githook is upgraded"
cmp -s "$Wb/.claude/agents/worker.md" "$T2/.claude/agents/worker.md" && r=upgraded || r=stale
assert_eq "$r" "upgraded" "b. unedited older agent is upgraded"
cmp -s "$Wb/.claude/commands/flows.md" "$T2/.claude/commands/flows.md" && r=upgraded || r=stale
assert_eq "$r" "upgraded" "b. unedited older command is upgraded"
assert_not_contains "$outb" "KEPT" "b. no kept summary on a clean upgrade"
[ -x "$Wb/.githooks/pre-commit" ] && r=exec || r=noexec
assert_eq "$r" "exec" "b. upgraded githook is executable"

# ── c. an operator-chosen maxTurns alone is not a local edit ────────────────────────────────
Wc="$ROOT/wsc"; cp -R "$W" "$Wc"
run_scaffold "$Wc" "$TEMPLATES" --component agents --worker-max-turns 40 --overwrite-local-edits
assert_contains "$(grep '^maxTurns:' "$Wc/.claude/agents/worker.md")" "40" "c. fixture: maxTurns rewritten"
run_scaffold "$Wc" "$TEMPLATES" --component agents
assert_not_contains "$(cat "$LOG")" "KEPT" "c. a maxTurns-only difference is not kept"
assert_contains "$(grep '^maxTurns:' "$Wc/.claude/agents/worker.md")" "40" "c. the operator's maxTurns survives a re-run"

# ── d. a removed template ignore line stays removed ─────────────────────────────────────────
Wd="$ROOT/wsd"; cp -R "$W" "$Wd"
grep -vxF '.specs/' "$Wd/.gitignore" > "$ROOT/gi" && cp "$ROOT/gi" "$Wd/.gitignore"
rm -f "$Wd/scripts/lib/.gitignore-applied"      # a workspace last updated before the record existed
run_scaffold "$Wd" "$TEMPLATES" --component gitignore
grep -qxF '.specs/' "$Wd/.gitignore" && r=readded || r=removed
assert_eq "$r" "removed" "d. first update with no record does not resurrect the removed line"
assert_contains "$(cat "$LOG")" ".specs/" "d. the skipped removal is reported"
T4="$ROOT/tpl4"; cp -R "$TEMPLATES" "$T4"
printf '\n# a newer template ignore\n.brand-new-dir/\n' >> "$T4/gitignore"
run_scaffold "$Wd" "$T4" --component gitignore
run_scaffold "$Wd" "$T4" --component gitignore
grep -qxF '.specs/' "$Wd/.gitignore" && r=readded || r=removed
assert_eq "$r" "removed" "d. the removed line stays removed across repeated updates"
assert_eq "$(grep -cxF '.brand-new-dir/' "$Wd/.gitignore")" "1" "d. a genuinely new template line is appended exactly once"
# First run with no record also appends a static line the baseline never listed.
We="$ROOT/wse"; cp -R "$W" "$We"
grep -vxF '.specs/' "$We/.gitignore" > "$ROOT/gi" && cp "$ROOT/gi" "$We/.gitignore"
rm -f "$We/scripts/lib/.gitignore-applied"
run_scaffold "$We" "$T4" --component gitignore
assert_eq "$(grep -cxF '.brand-new-dir/' "$We/.gitignore")" "1" "d. first run appends a pattern new in this release"
grep -qxF '.specs/' "$We/.gitignore" && r=readded || r=removed
assert_eq "$r" "removed" "d. and still leaves the removed line out"

assert_done
