#!/usr/bin/env bash
# Guard for templates/hooks/rules-on-touch.sh, the hook that delivers CLAUDE.md
# rules just-in-time instead of resident in the always-on prompt.
#
# PORTED alongside the hook from the live fleet that proved it (its copy lives at
# scripts/tests/test-rules-on-touch.sh there), with the workspace-specific packs
# swapped for the hub's six and the kill switches renamed to the GOVERN_* names.
#
# Why this test is load-bearing: moving a rule out of CLAUDE.md and into a hook
# trades "always present" for "present when the trigger matches". A pack whose
# trigger silently stops matching is a rule that has been DELETED without anyone
# noticing, strictly worse than the prose it replaced. So every pack must prove
# BOTH directions here: it fires on its trigger, and it stays quiet otherwise.
#
# Self-contained: no assert.sh, no scaffolded workspace. Exit 77 = SKIP.
# Run: bash templates/hooks/test-rules-on-touch.sh
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/rules-on-touch.sh"
[ -f "$HOOK" ] || { echo "SKIP: rules-on-touch.sh not found beside this test"; exit 77; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 required by the hook under test"; exit 77; }

pass=0; fail=0
STATE="$(mktemp -d)"
trap 'rm -rf "$STATE"' EXIT
# Point the hook's default local-extension path at the scratch dir, so a real
# workspace file next to the hook can never leak into these assertions.
export GOVERN_RULES_LOCAL="$STATE/no-local-packs.sh"

# run <session> <tool> <file_path> <command> -> prints additionalContext (or "")
# The payload is built with json.dumps, not printf interpolation: half these
# fixtures contain quotes and heredocs.
run() {
  python3 -c '
import json, sys
sid, tool, fp, cmd = sys.argv[1:5]
print(json.dumps({"tool_name": tool, "session_id": sid,
                  "tool_input": {"file_path": fp, "command": cmd}}))
' "$1" "$2" "$3" "$4" \
  | GOVERN_RULES_STATE_DIR="$STATE" bash "$HOOK" 2>/dev/null \
  | python3 -c 'import sys,json
try: d=json.load(sys.stdin)
except Exception: print(""); raise SystemExit
print(d.get("hookSpecificOutput",{}).get("additionalContext",""))' 2>/dev/null
}

ok()  { pass=$((pass+1)); printf '  PASS  %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

expect_tag() { # <desc> <tag> <session> <tool> <path> <cmd>
  local out; out="$(run "$3" "$4" "$5" "$6")"
  case "$out" in *"$2"*) ok "$1" ;; *) bad "$1 (expected $2, got: ${out:0:60})" ;; esac
}
expect_silent() { # <desc> <session> <tool> <path> <cmd>
  local out; out="$(run "$2" "$3" "$4" "$5")"
  [ -z "$out" ] && ok "$1" || bad "$1 (expected silence, got: ${out:0:60})"
}
expect_text() { # <desc> <substring> <session> <tool> <path> <cmd>
  expect_tag "$@"
}

echo "positive: every pack fires on its trigger"
expect_tag "shell pack on a .sh write"          "[RULES/shell]"    p1 Write "/ws/scripts/deploy.sh" ""
# `cat > x.sh` only reaches the trigger when it is not the FIRST word (a leading
# `cat` is a searcher, so the search-only exemption shadows it). That is the
# shape a real script-writing command takes anyway.
expect_tag "shell pack on a scripted .sh write"  "[RULES/shell]"    p2 Bash  "" "mkdir -p scripts && cat > scripts/setup.sh"
expect_tag "worklist pack on tickets.md edit"   "[RULES/worklist]" p3 Edit  "/ws/queue/tickets.md" ""
expect_tag "git pack on a git command"          "[RULES/git]"      p4 Bash  "" "git commit -m 'x'"
expect_tag "git pack behind a cd prefix"        "[RULES/git]"      p5 Bash  "" "cd backend && git status"
expect_tag "pr pack on gh pr"                   "[RULES/pr]"       p6 Bash  "" "gh pr create --fill"
expect_tag "release pack on a VERSION write"    "[RULES/release]"  p7 Write "/ws/VERSION" ""
expect_tag "release pack on npm version"        "[RULES/release]"  p8 Bash  "" "npm version minor"
expect_tag "release pack on git tag"            "[RULES/release]"  p9 Bash  "" "git tag -a v1.2.0 -m rel"
expect_tag "govern pack on scripts/govern edit" "[RULES/govern]"   p10 Edit "/ws/scripts/govern/spawn-worker.sh" ""
expect_tag "govern pack on templates/govern"    "[RULES/govern]"   p11 Edit "/hub/templates/govern/spawn-worker.sh" ""

echo "each pack carries its actual rule text, not just its tag"
expect_text "shell pack: the return-status trap"   "return 0"           t1 Write "/x.sh" ""
expect_text "shell pack: dependent locals"         "UNBOUND"            t2 Write "/y.sh" ""
expect_text "worklist pack: work-item shape"       'one `## #N` each'   t3 Edit  "/ws/queue/tickets.md" ""
expect_text "worklist pack: consolidate"           "Consolidate by default" t4 Edit "/ws/queue/tickets.md" ""
expect_text "git pack: cd before committing"       "before committing"  t5 Bash "" "git add -A"
expect_text "git pack: sub-repos drift"            "share a branch"     t6 Bash "" "git add -A"
expect_text "git pack: destructive git"            "destructive git"    t7 Bash "" "git add -A"
expect_text "git pack: never stash to A/B"         "git stash"          t8 Bash "" "git add -A"
expect_text "pr pack: never gh pr edit"            "gh pr edit"         t9 Bash "" "gh pr view 1"
expect_text "pr pack: the projectCards hard-fail"  "projectCards"       t10 Bash "" "gh pr view 1"
expect_text "pr pack: the gh api replacement"      "gh api -X PATCH"    t11 Bash "" "gh pr view 1"
expect_text "release pack: ask before minor/major" "ASK the operator"   t12 Bash "" "npm version minor"
expect_text "release pack: never x.0.0 alone"      "x.0.0"              t13 Bash "" "npm version minor"
expect_text "govern pack: cached --help probe"     'CACHED `--help` probe' t14 Edit "/ws/scripts/govern/x.sh" ""
expect_text "govern pack: diff against the hub"    "sync-templates.sh --check" t15 Edit "/ws/scripts/govern/x.sh" ""

echo "negative: no pack fires on unrelated work"
expect_silent "plain ts edit"                n1 Edit  "/ws/backend/src/index.ts" ""
expect_silent "plain ls"                     n2 Bash  "" "ls -la"
expect_silent "unrelated md write"           n3 Write "/ws/README.md" ""
expect_silent "unknown tool"                 n4 Grep  "" "foo"
expect_silent "a .md merely named shell"     n5 Write "/ws/docs/shell-scripting.md" ""
expect_silent "running a .sh is not editing" n6 Bash  "" "bash deploy.sh"
expect_silent "tickets-parked.md is not the work list" n7 Edit "/ws/queue/tickets-parked.md" ""
expect_silent "a tickets.md outside queue/"  n8 Edit  "/ws/docs/tickets.md" ""
expect_silent "gh issue is not gh pr"        n9 Bash  "" "gh issue list"
expect_silent "'npm run versions' is not 'npm version'" n10 Bash "" "npm run versions"
# scripts/lib/*.sh legitimately fires the SHELL pack; what must not fire is govern.
lib_out="$(run n11 Edit "/ws/scripts/lib/workspace.sh" "")"
case "$lib_out" in *"[RULES/govern]"*) bad "scripts/lib wrongly fired the govern pack" ;;
  *) ok "scripts/lib is not scripts/govern" ;; esac
expect_silent "running govern is not editing it"  n12 Bash "" "npm run govern:resolve -- 42"

echo "once-per-session: a pack fires once, then goes quiet"
expect_tag    "first .sh write fires"   "[RULES/shell]" rep Write "/a.sh" ""
expect_silent "second .sh write quiet"                  rep Write "/b.sh" ""
expect_tag    "different session fires" "[RULES/shell]" rep2 Write "/c.sh" ""

echo "search-only commands never fire an action pack (regression: the coverage audit misfire)"
expect_silent "grep -n for a git string"        so1 Bash "" "grep -n 'git commit' notes.md"
expect_silent "echo mentioning git push"        so2 Bash "" "echo git push"
expect_silent "cat of a file named gh-pr"       so3 Bash "" "cat gh-pr-notes.md"
expect_silent "cat VERSION"                     so4 Bash "" "cat VERSION"
expect_silent "grep -n VERSION"                 so5 Bash "" "grep -n VERSION scaffold.sh"
expect_silent "a leading env assignment does not hide the searcher" so6 Bash "" "FOO=1 grep -n VERSION x"
expect_silent "an absolute path to a searcher is still a searcher"  so7 Bash "" "/bin/cat VERSION"
expect_tag    "a real git call still fires"     "[RULES/git]"     so8 Bash "" "git commit -m x"
expect_tag    "a real npm version still fires"  "[RULES/release]" so9 Bash "" "npm version patch"
# `grep -r` is exempt from the search-only exemption, but that exemption feeds
# only packs keyed on searching (the workspace-local slot below). It must NOT
# resurrect an action pack off the sweep's PATTERN.
expect_silent "grep -r whose pattern is 'gh pr' does not fire the pr pack" so10 Bash "" "grep -r 'gh pr' ."

echo "heredoc bodies are data, not command text (regression: the live misfire)"
expect_silent "heredoc mentioning git push"  hd1 Bash "" "python3 - <<PY  s.replace('git push')  PY"
expect_silent "heredoc mentioning gh pr"     hd2 Bash "" "cat > x <<EOF  gh pr edit --base main  EOF"
expect_silent "heredoc mentioning VERSION"   hd3 Bash "" "cat > x <<EOF  bump VERSION  EOF"
expect_tag    "a real git call still fires"  "[RULES/git]" hd4 Bash "" "git push origin HEAD"

echo "per-call cap: one command cannot dump the whole rulebook"
multi="$(run cap Bash "" "git tag -a v1.2.0 && gh pr create --fill && cat >> VERSION")"
npacks="$(printf '%s' "$multi" | grep -c '\[RULES/' || true)"
{ [ "$npacks" -le 2 ] && [ "$npacks" -ge 1 ]; } && ok "capped at $npacks pack(s) for a 3-trigger command" \
  || bad "expected <=2 packs, got $npacks"
uncapped="$(run cap Bash "" "npm version patch")"
case "$uncapped" in *"[RULES/release]"*) ok "a pack skipped by the cap is not stamped, fires later" ;;
  *) bad "capped pack was wrongly stamped as fired" ;; esac
capped_one="$(GOVERN_RULES_MAX_PACKS=1 run cap3 Bash "" "git tag -a v1 && gh pr create")"
n1p="$(printf '%s' "$capped_one" | grep -c '\[RULES/' || true)"
[ "$n1p" = "1" ] && ok "GOVERN_RULES_MAX_PACKS=1 tightens the cap" || bad "MAX_PACKS override ignored (got $n1p)"

echo "pack restriction (debug/test seam)"
# shellcheck disable=SC2209  # `VAR=x run ...` is a function call with an env prefix
restricted="$(GOVERN_RULES_ON_TOUCH_PACKS=pr run res Bash "" "git tag -a v1 && gh pr create")"
case "$restricted" in
  *"[RULES/pr]"*) case "$restricted" in *"[RULES/git]"*) bad "PACKS restriction let a non-listed pack through" ;;
    *) ok "GOVERN_RULES_ON_TOUCH_PACKS restricts to the named pack" ;; esac ;;
  *) bad "GOVERN_RULES_ON_TOUCH_PACKS dropped the pack it was told to keep" ;;
esac

echo "workspace-local packs extend the template without editing it"
cat > "$STATE/local.sh" <<'LOCAL'
rules_local_triggers() {
  [ "$search_is_action" = "1" ] && add_pack sweep
  case "$probe" in *docker-compose.yml) add_pack compose ;; esac
  return 0
}
rules_local_pack_text() {
  case "$1" in
    sweep)   printf '%s\n' "[RULES/sweep] local sweep rule" ;;
    compose) printf '%s\n' "[RULES/compose] local compose rule" ;;
  esac
}
LOCAL
loc="$(GOVERN_RULES_LOCAL="$STATE/local.sh" run loc1 Bash "" "grep -r foo .")"
case "$loc" in *"[RULES/sweep]"*) ok "a local pack keyed on grep -r fires (the search-is-action slot)" ;;
  *) bad "local grep -r pack did not fire (got: ${loc:0:60})" ;; esac
loc2="$(GOVERN_RULES_LOCAL="$STATE/local.sh" run loc2 Edit "/ws/docker-compose.yml" "")"
case "$loc2" in *"[RULES/compose]"*) ok "a local pack keyed on a file path fires" ;;
  *) bad "local path pack did not fire (got: ${loc2:0:60})" ;; esac
loc3="$(GOVERN_RULES_LOCAL="$STATE/nonexistent.sh" run loc3 Bash "" "git commit -m x")"
case "$loc3" in *"[RULES/git]"*) ok "a missing local file is not an error: built-ins still fire" ;;
  *) bad "missing local extension broke the built-in packs" ;; esac
printf 'this is not valid shell ((((\n' > "$STATE/broken.sh"
loc4="$(GOVERN_RULES_LOCAL="$STATE/broken.sh" run loc4 Bash "" "git commit -m x")"
case "$loc4" in *"[RULES/git]"*) ok "a BROKEN local file cannot take the built-in packs down" ;;
  *) bad "broken local extension broke the built-in packs" ;; esac

echo "kill switch"
out="$(printf '{"tool_name":"Write","session_id":"k","tool_input":{"file_path":"/x.sh"}}' \
  | GOVERN_RULES_ON_TOUCH=0 GOVERN_RULES_STATE_DIR="$STATE" bash "$HOOK" 2>/dev/null)"
[ -z "$out" ] && ok "GOVERN_RULES_ON_TOUCH=0 disables the hook" || bad "kill switch ignored"

echo "never blocks: no pack may emit a permissionDecision, and it always exits 0"
blocked=0
for c in "git commit -m x" "gh pr create" "npm version patch"; do
  printf '{"tool_name":"Bash","session_id":"nb","tool_input":{"command":"%s"}}' "$c" \
    | GOVERN_RULES_STATE_DIR="$STATE" bash "$HOOK" > "$STATE/nb.out" 2>/dev/null
  grep -q permissionDecision "$STATE/nb.out" && blocked=1
done
[ "$blocked" = "0" ] && ok "advisory only, never denies" || bad "a pack emitted permissionDecision"
printf '{"tool_name":"Bash","session_id":"e1","tool_input":{"command":"git commit"}}' \
  | GOVERN_RULES_STATE_DIR="$STATE" bash "$HOOK" >/dev/null 2>&1
[ "$?" = "0" ] && ok "exit 0 on a firing call" || bad "non-zero exit on a firing call"
printf '{"tool_name":"Write","session_id":"e2","tool_input":{"file_path":"/README.md"}}' \
  | GOVERN_RULES_STATE_DIR="$STATE" bash "$HOOK" >/dev/null 2>&1
[ "$?" = "0" ] && ok "exit 0 on a non-firing call" || bad "non-zero exit on a non-firing call"
printf 'not json at all' | GOVERN_RULES_STATE_DIR="$STATE" bash "$HOOK" >/dev/null 2>&1
[ "$?" = "0" ] && ok "fails open on a malformed payload" || bad "non-zero exit on a malformed payload"

echo "output is well-formed PreToolUse JSON"
printf '{"tool_name":"Bash","session_id":"j1","tool_input":{"command":"git commit"}}' \
  | GOVERN_RULES_STATE_DIR="$STATE" bash "$HOOK" 2>/dev/null \
  | python3 -c 'import sys,json
d=json.load(sys.stdin); h=d["hookSpecificOutput"]
assert h["hookEventName"]=="PreToolUse", h
assert h["additionalContext"].strip(), h
assert "permissionDecision" not in h, h' 2>/dev/null \
  && ok "emits valid additionalContext JSON with no permissionDecision" \
  || bad "malformed hook output"

echo "core CLAUDE.md keeps an index naming every pack"
SEED=""
for c in "$DIR/../seed/CLAUDE.md" "$DIR/../../templates/seed/CLAUDE.md" "$DIR/../CLAUDE.md"; do
  [ -f "$c" ] && { SEED="$c"; break; }
done
if [ -z "$SEED" ]; then
  ok "SKIP: no seed CLAUDE.md resolvable in this layout"
else
  grep -q "rules-on-touch" "$SEED" \
    && ok "CLAUDE.md points at the hook" \
    || bad "CLAUDE.md has no rules-on-touch index line (a session cannot know these rules exist)"
  missing=""
  for p in shell worklist git pr release govern; do
    grep -q "\`$p\`" "$SEED" || missing="$missing $p"
  done
  [ -z "$missing" ] && ok "the index names every pack" || bad "index is missing pack(s):$missing"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" = "0" ]
