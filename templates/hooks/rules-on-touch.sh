#!/usr/bin/env bash
# PreToolUse(Write|Edit|Bash) hook: deliver a CLAUDE.md rule at the MOMENT the
# surface it governs is touched, instead of resident in the always-on prompt.
#
# PORTED from a live fleet's scripts/rules-on-touch.sh, where it took that
# workspace's CLAUDE.md from 26,511 to 18,830 chars (-29%) WITHOUT DELETING A
# SINGLE RULE. A wording-only pass over the same file bought 759 chars (2.9%):
# the file was already at its hand-compressed floor, so prose was never the
# lever. DELIVERY was. Every guard below carries the incident that produced it;
# do not simplify one away without re-reading its comment.
#
# Why this exists
#   CLAUDE.md is re-sent in full on EVERY turn of EVERY session, so a rule that
#   only matters when you are editing a shell script is charged to every session
#   that never opens one. The rules moved here all share one property: their
#   trigger is MECHANICALLY DETECTABLE from the tool call itself. A rule whose
#   trigger is a judgment call ("is this a proxy or an outcome?") can NOT move
#   here and stays resident in CLAUDE.md.
#
#   DETECTABILITY IS THE SORT KEY, NEVER FREQUENCY. A rule that fires rarely but
#   prevents a destroyed box is high value precisely because nobody recalls it,
#   which argues FOR just-in-time delivery, not against it.
#
#   Just-in-time beats the appendix for these. CLAUDE-APPENDIX.md only helps a
#   session that remembers to go read it; this fires whether anyone remembered.
#
# Deliberately NOT driver-only (unlike router-posture-guard.sh)
#   A subagent or governor worker editing a sub-repo does NOT load the root
#   CLAUDE.md at all: that is the standing delegation gotcha ("hand over every
#   rule a CI guard enforces, or N children each break it N times"). These packs
#   are therefore worth MORE inside a worker than in the driver, so this hook
#   fires for every caller. That is the point, not an oversight.
#
# Cost shape
#   Silent unless a trigger matches, and each pack fires at most ONCE per
#   session (per-pack stamp, not one shared counter, because a shared counter would let
#   an early pack starve every later one). Never blocks: advisory
#   additionalContext only, and the script always exits 0.
#
# Kill switches
#   GOVERN_RULES_ON_TOUCH=0        disable the whole hook
#   GOVERN_RULES_ON_TOUCH_PACKS=   comma-list to restrict to named packs (debug/test)
#   GOVERN_RULES_MAX_PACKS=        per-call cap (default 2)
#   GOVERN_RULES_STATE_DIR=        override the per-session stamp dir (tests)
#   GOVERN_RULES_LOCAL=            path to this workspace's own pack extension
#                                  (default scripts/rules-on-touch.local.sh beside this file)
#
# Adding a workspace's OWN packs without editing this template
#   Drop a file at scripts/rules-on-touch.local.sh defining either or both of:
#     rules_local_triggers   # called with $tool_name, $probe, $search_only and
#                            # $search_is_action (set for `grep -r`) in scope;
#                            # call `add_pack <name>` for each pack that matches
#     rules_local_pack_text  # called with a pack name; print that pack's text
#   It is sourced only if present, is never overwritten by /shiploop:update
#   (nothing in the hub ships that path), and its packs share the same cap,
#   stamping and kill switches as the built-ins.
#
# Contract with CLAUDE.md
#   Core CLAUDE.md keeps a one-line index naming every pack here, so a session
#   knows the rule EXISTS even on a turn where nothing fired. If you add a pack,
#   add it to that line. If you delete a pack, put its rule back in core.
set -u

[ "${GOVERN_RULES_ON_TOUCH:-1}" = "0" ] && exit 0

payload="$(cat 2>/dev/null || true)"
[ -n "$payload" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

# One python3 pass, one field per line (macOS bash 3.2: no mapfile).
{
  IFS= read -r tool_name
  IFS= read -r session_id
  IFS= read -r file_path
  IFS= read -r command
} < <(printf '%s' "$payload" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
ti = d.get("tool_input") or {}
def g(k):
    v = ti.get(k)
    return "" if v is None else str(v)
for f in (d.get("tool_name") or "", d.get("session_id") or "", g("file_path"), g("command")):
    print(f.replace("\t", " ").replace("\n", " "))
' 2>/dev/null)
tool_name="${tool_name:-}"; session_id="${session_id:-}"
file_path="${file_path:-}"; command="${command:-}"
[ -n "$tool_name" ] || exit 0

# The text a pack matches against: a file path for Write/Edit, the command for Bash.
case "$tool_name" in
  Write|Edit|NotebookEdit) probe="$file_path" ;;
  Bash)                    probe="$command"   ;;
  *) exit 0 ;;
esac
[ -n "$probe" ] || exit 0

matched=""
add_pack() { matched="${matched}${matched:+|}$1"; }

# Optional workspace-local pack extension (see the header). Sourced before the
# triggers so its functions are in scope; a broken local file must never take
# the built-in packs down with it.
LOCAL_PACKS="${GOVERN_RULES_LOCAL:-$(dirname "${BASH_SOURCE[0]}")/rules-on-touch.local.sh}"
# shellcheck disable=SC1090
[ -f "$LOCAL_PACKS" ] && { . "$LOCAL_PACKS" 2>/dev/null || true; }

# NOTE: every match below is `grep ... <<< "$var"`, never `printf ... | grep`. An
# early-exiting consumer (grep -q) SIGPIPEs a live producer, which under
# `pipefail` kills the script silently at exit 141. A herestring has no producer
# process to kill.
# ── pack triggers ───────────────────────────────────────────────────────────
# Each is high-precision on purpose: a false negative costs one un-delivered
# rule, a false positive costs trust in the whole hook.

search_only=0
search_is_action=0
if [ "$tool_name" != "Bash" ]; then
  case "$probe" in
    *queue/tickets.md) add_pack worklist ;;
  esac
  case "$probe" in
    *.sh|*.bash) add_pack shell ;;
  esac
  case "$probe" in
    */scripts/govern/*|scripts/govern/*|*/templates/govern/*|templates/govern/*) add_pack govern ;;
  esac
  # Writing the VERSION file through the Write/Edit tool. The Bash side cannot
  # catch this one: `echo 1.2.0 > VERSION` and `printf ... > VERSION` both lead
  # with a searcher, so the search-only exemption (correctly) suppresses them.
  case "$probe" in
    */VERSION|VERSION) add_pack release ;;
  esac
else
  # A pure SEARCH/READ command never PERFORMS a governed action, it only mentions
  # it. Without this, `grep -n P1001 notes.md` fires an action pack and a doc
  # audit fires five packs at once. Found by running this hook against its own
  # coverage audit, which mentioned every trigger token in one command line.
  # `grep -r` is the one search that IS a governed action (on a meta-repo it
  # behaves differently from a normal read), so packs that key on searching are
  # evaluated for search commands too (see the search-exempt block below).
  # A heredoc BODY is data, not command text: `python3 - <<'EOF' ... git push`
  # was firing a pack off a doc string. Cut the probe at the first `<<`;
  # everything before it is what actually runs. (Found live - this hook misfired
  # on the very edit that removed the prose it was replacing.)
  probe="${probe%%<<*}"
  [ -n "$probe" ] || exit 0

  _stripped="$(sed -E 's/^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*//' <<< "$probe")"
  first="${_stripped%%[[:space:]]*}"
  # Space-delimited membership test rather than a `case a|b|c)` list: a pattern
  # list reads as a pipeline to a shape guard scanning for pipe characters.
  # Same behaviour, no false positive to allowlist away.
  _searchers=" grep rg egrep fgrep echo printf cat sed awk wc head tail ls find comm diff sort uniq jq command "
  case "$_searchers" in
    *" $(basename "${first:-}") "*) search_only=1 ;;
  esac
  # `grep -r` is exempt from the exemption: a recursive sweep IS the governed
  # action, not a read of one named file. It does NOT clear search_only (that
  # would let a sweep whose PATTERN is `gh pr` fire the pr pack, the exact false
  # positive the exemption exists to prevent); it sets a separate flag that only
  # packs keyed on searching read.
  search_is_action=0
  # shellcheck disable=SC2034  # read by rules_local_triggers in the sourced local extension
  grep -Eq '(^|[[:space:];&|])grep[[:space:]]+(-[[:alnum:]]*[rR])' <<< "$probe" && search_is_action=1

  if [ "$search_only" = "0" ]; then
    grep -Eq '(^|[[:space:];&|])cat[[:space:]]+>[^|]*\.sh' <<< "$probe" && add_pack shell
    # `git ...`, optionally behind the `cd <sub-repo> &&` prefix this very pack
    # is about.
    grep -Eq '^[[:space:]]*(cd[[:space:]][^&;|]*([&][&]|;)[[:space:]]*)*git([[:space:]]|$)' <<< "$probe" && add_pack git
    grep -Eq '(^|[^[:alnum:]_-])gh[[:space:]]+pr([[:space:]]|$)' <<< "$probe" && add_pack pr
    grep -Eq '(^|[^[:alnum:]_/.-])VERSION([^[:alnum:]_-]|$)|(^|[^[:alnum:]_-])(npm|pnpm|yarn|bun)[[:space:]]+version([[:space:]]|$)|(^|[^[:alnum:]_-])git[[:space:]]+tag([[:space:]]|$)' <<< "$probe" && add_pack release
  fi
fi

# Workspace-local triggers. Evaluated for search commands too, with both
# $search_only and $search_is_action in scope: that is the slot the `grep -r`
# exemption above exists for. The hub ships no built-in pack keyed on searching,
# because what a recursive grep does wrong is workspace-specific (a shimmed grep,
# a root .gitignore that hides sub-repos).
if command -v rules_local_triggers >/dev/null 2>&1; then
  rules_local_triggers 2>/dev/null || true
fi

[ -n "$matched" ] || exit 0

# ── restrict to named packs (tests/debug) ───────────────────────────────────
if [ -n "${GOVERN_RULES_ON_TOUCH_PACKS:-}" ]; then
  keep=""
  for p in $(printf '%s' "$matched" | tr '|' ' '); do
    case ",${GOVERN_RULES_ON_TOUCH_PACKS}," in *",$p,"*) keep="${keep}${keep:+|}$p" ;; esac
  done
  matched="$keep"
  [ -n "$matched" ] || exit 0
fi

# ── per-pack once-per-session gate ──────────────────────────────────────────
session_id="$(printf '%s' "$session_id" | tr -c 'A-Za-z0-9._-' '_')"
[ -n "$session_id" ] || session_id="nosession"
state_dir="${GOVERN_RULES_STATE_DIR:-${TMPDIR:-/tmp}}"
mkdir -p "$state_dir" 2>/dev/null || true

# Per-call cap. A single tool call that trips several triggers must not dump the
# whole rulebook into context - that is the noise that gets a hook switched off,
# and a switched-off hook is every moved rule silently deleted. Untripped packs
# are NOT stamped, so they still fire on the next call that touches their surface.
MAX_PACKS_PER_CALL="${GOVERN_RULES_MAX_PACKS:-2}"
fire=""; n_fired=0
for p in $(printf '%s' "$matched" | tr '|' ' '); do
  [ "$n_fired" -ge "$MAX_PACKS_PER_CALL" ] 2>/dev/null && break
  stamp="${state_dir}/shiploop-rules-on-touch-${session_id}-${p}"
  [ -f "$stamp" ] && continue
  : > "$stamp" 2>/dev/null || true
  fire="${fire}${fire:+ }$p"; n_fired=$((n_fired+1))
done
[ -n "$fire" ] || exit 0

# ── rule packs ──────────────────────────────────────────────────────────────
# Text is the CLAUDE.md rule, MOVED not paraphrased. Long form stays in
# CLAUDE-APPENDIX.md; these are the imperatives.
pack_text() {
  case "$1" in
    shell) cat <<'EOF'
[RULES/shell] Writing shell in this workspace:
- Under `set -euo pipefail`, a function whose LAST statement is a bare `[[ cond ]] && cmd` returns the TEST's status, so a false condition aborts the CALLER, not just the branch. End such a function with an explicit `return 0`.
- `local a=x b="$a"` is UNBOUND: `local` evaluates its assignments left to right in ONE pass, so `$a` is not set yet. Split dependent locals onto separate `local` lines.
- Under `pipefail`, a CONSUMER that stops early (`grep -q`) kills the script SILENTLY at exit 141. Feed consumers from a FILE or a herestring, never a live `printf "$var" |`.
EOF
;;
    worklist) cat <<'EOF'
[RULES/worklist] Editing queue/tickets.md:
- Work items only, one `## #N` each. Scope: this workspace's sub-repos and the harness, nothing external.
- **Consolidate by default:** two tickets one worker would fix in one PR should have been one ticket.
- Editing ONE ticket: bound its region by the `## #N` heading FIRST. Anchors like `**Done when:**` repeat across tickets, so a bare index-of can slice backwards and a scripted replace then rewrites the whole file. Verify the line count after any scripted edit, BEFORE committing.
EOF
;;
    git) cat <<'EOF'
[RULES/git] Running git in a meta-repo:
- **`cd` into the sub-repo before committing.** `git add` from root won't stage sub-repo files, and `git status` at the root proves nothing about sub-repo state.
- **Never assume sub-repos share a branch.** They drift: check each sub-repo's `git status` first.
- **Verify which sub-repo you're in before destructive git** (`reset --hard`, `clean -fd`, `branch -D`).
- **Never `git stash` to A/B a baseline** - the edits usually live in a nested sub-repo, so a root-level stash silently no-ops and the "baseline" run is worthless. Use a throwaway `git archive HEAD | tar -x -C "$(mktemp -d)"` export.
EOF
;;
    pr) cat <<'EOF'
[RULES/pr] Touching a pull request:
- **Never mutate an OPEN PR with `gh pr edit`.** Its GraphQL query pulls `projectCards`, which hard-fails where that field is unavailable, and `--base` is worse: it reports success while changing nothing.
- Use the REST API instead: `gh api -X PATCH repos/<org>/<repo>/pulls/<N> -F body=@body.md` (add `-F base=<branch>` for the base). No projectCards query, and it fails loudly.
EOF
;;
    release) cat <<'EOF'
[RULES/release] Touching a version or a tag:
- Cut a PATCH release yourself.
- **ASK the operator before a MINOR or a MAJOR.** Never publish an x.0.0 release without them: the version number is the public promise, and only the operator makes it.
EOF
;;
    govern) cat <<'EOF'
[RULES/govern] Editing a governor script:
- **Never add a new `claude` flag to the dispatch path unguarded.** Gate it on a CACHED `--help` probe, never on a version compare (a version reports what shipped, not what this binary supports), give it an env kill switch, and expose a `_GOVERN_<X>_SUPPORTED` pre-seed seam so tests can skip the probe. An unbounded probe on the dispatch path is also a hang risk: bound it.
- **Diff the workspace copy against the hub template before fixing a govern-script defect** (`bash scripts/govern/sync-templates.sh --check`). The bug is often already fixed upstream, and a local-only fix silently forks the fleet.
EOF
;;
    *)
      # Workspace-local packs (see the header).
      command -v rules_local_pack_text >/dev/null 2>&1 && rules_local_pack_text "$1"
      ;;
  esac
}

out=""
for p in $fire; do
  t="$(pack_text "$p")"
  [ -n "$t" ] || continue
  out="${out}${out:+

}${t}"
done
[ -n "$out" ] || exit 0

python3 -c '
import json, sys
print(json.dumps({
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "additionalContext": sys.argv[1],
  }
}))
' "$out" 2>/dev/null || true
exit 0
