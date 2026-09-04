#!/usr/bin/env bash
# Drift guard for the interactive worker lane (`.claude/agents/worker.md`).
#
# There is ONE worker doctrine and TWO lanes that run it: the headless lane
# (spawn-worker.sh, which sends governor/worker-prompt.md) and the interactive lane
# (Agent(subagent_type: "worker"), which loads .claude/agents/worker.md). The whole point
# of the agent definition is that it does NOT carry a second copy of the doctrine:
# worker-prompt.md stays canonical and worker.md INCLUDES IT BY REFERENCE, telling the
# spawned worker to read that file first. A hand-forked copy would silently re-create the
# drift this design exists to kill, so the assertions below fail on any sign of one.
#
# Also pins the frontmatter to the headless lane's own defaults: model to
# GOVERN_WORKER_MODEL's floor and tools to GOVERN_WORKER_TOOLS_DEFAULT, both read out of
# spawn-worker.sh rather than restated here, so bumping one lane without the other is red.
#
# Runs in BOTH layouts (hub template tree and a scaffolded workspace), same probe order as
# assert.sh's resolver.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

# Agents dir: templates/.claude/agents (hub) | <root>/.claude/agents (workspace).
AGENTS_DIR=""
for _c in "$DIR/../../.claude/agents" "$DIR/../../../.claude/agents"; do
  if [ -f "$_c/worker.md" ]; then AGENTS_DIR="$(cd "$_c" && pwd)"; break; fi
done
[ -n "$AGENTS_DIR" ] || { echo "SKIP: no .claude/agents/worker.md in either layout" >&2; exit 77; }

WORKER_MD="$AGENTS_DIR/worker.md"
PROMPT_MD="$GOVERN_PROMPTS_DIR/worker-prompt.md"
SPAWN="$(cd "$DIR/.." && pwd)/spawn-worker.sh"
[ -f "$PROMPT_MD" ] || { echo "SKIP: canonical worker-prompt.md not found" >&2; exit 77; }
[ -f "$SPAWN" ] || { echo "SKIP: spawn-worker.sh not found at $SPAWN" >&2; exit 77; }

body="$(cat "$WORKER_MD")"
# Frontmatter = everything between the first two `---` lines.
fm="$(awk 'NR==1 && $0=="---"{inb=1;next} inb && $0=="---"{exit} inb{print}' "$WORKER_MD")"

# ── 1. Frontmatter identity ────────────────────────────────────────────────
assert_eq "$(sed -n 's/^name: *//p' <<<"$fm")" "worker" \
  "1. agent name is exactly 'worker' (the literal subagent_type in the routing rule)"
assert_eq "$([ -n "$(sed -n 's/^description: *//p' <<<"$fm")" ] && echo yes || echo no)" "yes" \
  "1b. description present"

# ── 2. Model floor matches the headless lane ───────────────────────────────
# spawn-worker.sh:  base_model="${GOVERN_WORKER_MODEL:-sonnet}"
headless_model="$(sed -n 's/.*GOVERN_WORKER_MODEL:-\([a-z0-9.-]*\)}.*/\1/p' "$SPAWN" | head -1)"
assert_eq "$([ -n "$headless_model" ] && echo yes || echo no)" "yes" \
  "2. read the headless model floor out of spawn-worker.sh"
assert_eq "$(sed -n 's/^model: *//p' <<<"$fm")" "$headless_model" \
  "2b. worker.md model matches the GOVERN_WORKER_MODEL floor ($headless_model)"

# ── 3. Tools mirror GOVERN_WORKER_TOOLS_DEFAULT ────────────────────────────
# Compare as normalized comma lists so `a, b` and `a,b` are the same list.
norm_tools() { tr -d ' ' <<<"$1" | tr ',' '\n' | sed '/^$/d' | paste -sd, - ; }
headless_tools="$(sed -n 's/^GOVERN_WORKER_TOOLS_DEFAULT="\(.*\)"$/\1/p' "$SPAWN" | head -1)"
agent_tools="$(sed -n 's/^tools: *//p' <<<"$fm")"
assert_eq "$([ -n "$headless_tools" ] && echo yes || echo no)" "yes" \
  "3. read GOVERN_WORKER_TOOLS_DEFAULT out of spawn-worker.sh"
assert_eq "$(norm_tools "$agent_tools")" "$(norm_tools "$headless_tools")" \
  "3b. worker.md tools mirror GOVERN_WORKER_TOOLS_DEFAULT exactly"

# ── 4. Single-source: the doctrine is INCLUDED, never copied ───────────────
assert_contains "$body" "governor/worker-prompt.md" \
  "4. worker.md points at the canonical doctrine by path"
assert_contains "$body" "Read" \
  "4b. worker.md instructs an actual read of it"

# A hand-fork announces itself: these are worker-prompt.md's own structural landmarks and
# output-contract keys. None of them may appear in the agent definition.
for marker in \
  "## 1. Scope and flow" \
  "## 2. Context economy" \
  "## 3. Scratchpad" \
  "## 4. Capability posture" \
  "## 5. Output contract" \
  '"lessonPatch"' \
  '"crossRefs"' \
  '"newTickets"' \
  "GOVERN:HANDOFF"
do
  assert_not_contains "$body" "$marker" \
    "4c. no forked doctrine in worker.md: [$marker] lives only in worker-prompt.md"
done

# Every landmark above must actually still be IN the canonical file, or the check above is
# vacuously green after a rename.
canon="$(cat "$PROMPT_MD")"
for marker in "## 1. Scope and flow" "## 5. Output contract" '"lessonPatch"' "GOVERN:HANDOFF"; do
  assert_contains "$canon" "$marker" \
    "4d. landmark [$marker] still present in worker-prompt.md (drift check is not vacuous)"
done

# Size bound: a reference plus lane deltas, not a doctrine. If worker.md ever grows past a
# third of the canonical prompt, someone is re-stating doctrine in it.
w_bytes="$(wc -c < "$WORKER_MD" | tr -d ' ')"
p_bytes="$(wc -c < "$PROMPT_MD" | tr -d ' ')"
assert_eq "$([ "$w_bytes" -lt "$((p_bytes / 3))" ] && echo under || echo over)" "under" \
  "4e. worker.md ($w_bytes B) stays under a third of worker-prompt.md ($p_bytes B)"

# ── 5. Interactive-lane deltas are stated ──────────────────────────────────
assert_contains "$body" "npm run worktree:new" \
  "5. self-service worktree instruction present"
assert_contains "$body" 'isolation: "worktree"' \
  "5b. the Agent tool's worktree isolation is called out"
assert_contains "$body" "NEVER" \
  "5c. that call-out is a prohibition, not a suggestion"
assert_contains "$body" "npm run govern --" \
  "5d. the lane bridge names govern's PR-adoption path"
assert_contains "$body" "queue/tickets.md" \
  "5e. the queue-bookkeeping boundary is stated"

assert_done
