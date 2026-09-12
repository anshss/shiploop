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
spawn_body="$(cat "$SPAWN")"
# #117: GOVERN_WORKER_TOOLS_DEFAULT is now DERIVED from worker.md at runtime (see
# govern::worker_agent_field) — the quoted literal below is only the fallback for a fleet that
# hasn't synced .claude/agents/worker.md yet, so `tail -1` grabs that fallback rather than the
# `$(...)` derive expression (which also textually matches `="…"` and would sort first).
headless_tools="$(sed -n 's/.*GOVERN_WORKER_TOOLS_DEFAULT="\([^"]*\)".*/\1/p' "$SPAWN" | tail -1)"
agent_tools="$(sed -n 's/^tools: *//p' <<<"$fm")"
assert_eq "$([ -n "$headless_tools" ] && echo yes || echo no)" "yes" \
  "3. read GOVERN_WORKER_TOOLS_DEFAULT's fallback out of spawn-worker.sh"
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
assert_contains "$body" "npm run govern:resolve --" \
  "5d. the lane bridge names govern's resolve path"
assert_contains "$body" "queue/tickets.md" \
  "5e. the queue-bookkeeping boundary is stated"

# ── 6. Capability posture ported from spawn-worker.sh (#117) ──────────────
# Genuine delegation, not a second hardcoded copy that happens to match: the failure mode #117
# closes is two independently-maintained tool lists kept in sync only by test 3 above. Pin that
# spawn-worker.sh actually CALLS the reader rather than restating the list.
assert_contains "$spawn_body" "govern::worker_agent_field tools" \
  "6. spawn-worker.sh derives its tool default from worker.md instead of duplicating it"

# permissionMode: worker.md declares the same default spawn-worker.sh hardcodes
# (permflag="${GOVERN_PERMISSION_MODE:-bypassPermissions}"). The interactive lane has no
# per-run CLI invocation of its own to attach a flag to, so this has to live in the frontmatter.
headless_permission="$(sed -n 's/.*GOVERN_PERMISSION_MODE:-\([a-zA-Z]*\)}.*/\1/p' "$SPAWN" | head -1)"
assert_eq "$([ -n "$headless_permission" ] && echo yes || echo no)" "yes" \
  "6b. read the headless permission-mode default out of spawn-worker.sh"
assert_eq "$(sed -n 's/^permissionMode: *//p' <<<"$fm")" "$headless_permission" \
  "6c. worker.md permissionMode matches the headless default ($headless_permission)"

# mcpServers: zero MCP tools on both lanes, by two different mechanisms. Headless gets there at
# the CONNECTION level (--strict-mcp-config, no --mcp-config passed). The interactive lane has no
# flag to attach that to, so it gets there at the TOOL level instead: a `tools:` allow-list with no
# `mcp__` entry already means no MCP tool is invocable regardless of what connects, and
# disallowedTools makes that explicit and keeps it true even if `tools:` is ever loosened. See the
# mcpServers finding in CLAUDE-APPENDIX.md (merge-vs-replace, sourced against the installed CLI)
# that this pins.
assert_contains "$spawn_body" "strict-mcp-config" \
  "6d. headless lane still defaults to zero MCP servers (strict-mcp-config)"
assert_contains "$fm" "disallowedTools:" \
  "6e. worker.md declares a disallowedTools line"
assert_contains "$(sed -n 's/^disallowedTools: *//p' <<<"$fm")" "mcp__" \
  "6f. that disallowedTools line denies the mcp__ tool namespace"
assert_not_contains "$fm" "mcpServers:" \
  "6g. worker.md does not declare mcpServers -- omitted IS the zero-MCP state here, not a list to merge/replace"

# isolation: 5b above already prohibits the Agent-tool CALLER from passing isolation: "worktree"
# to this agent type, because a meta-repo's nested sub-repo .git directories don't come along into
# a bare git worktree. A frontmatter isolation: worktree DEFAULT would trigger the exact same
# breakage from the other side -- every future interactive spawn, whether or not the caller asked
# for it -- so it must never be declared here either.
assert_not_contains "$fm" "isolation:" \
  "6h. worker.md does not declare isolation -- worktree would break this meta-repo's nested .git dirs"

# hooks: a SubagentStop hook (agent-progress-guard.sh) already supervises every subagent at the
# settings.json level (scaffold.sh writes it project-wide; both lanes load project settings). A
# hooks: entry here would be a second registration of the same supervision for the same children.
assert_not_contains "$fm" "hooks:" \
  "6i. worker.md does not declare hooks -- SubagentStop supervision is owned once, at settings.json"

# ── 7. Hazard handoff reaches this lane too (rail 9 / #125) ────────────────
# spawn-worker.sh gets its "Recorded gotchas" section injected FOR it (#118/#174); this lane has no
# launcher to do that, so worker.md must tell it to run the SAME lookup itself, on the paths it is
# about to touch, as an explicit step -- not leave it as a passive "go read the file" pointer.
assert_contains "$body" "gotchas-for-paths.sh" \
  "7. worker.md instructs running the shared hazard-lookup script itself"
GOTCHA_SCRIPT="$(cd "$DIR/.." && pwd)/gotchas-for-paths.sh"
assert_eq "$([ -f "$GOTCHA_SCRIPT" ] && echo yes || echo no)" "yes" \
  "7b. the script worker.md points at actually exists beside spawn-worker.sh"

# ── 8. the consult goes UP to the advisor, and no lane ever spawns one ────
# Nothing ever spawns an advisor. The headless lane has no advisor session at all and reports an
# honest escalation on a fork it cannot resolve; the interactive lane asks the session that wrote
# its proposal. Cases 8e-8g are REGRESSION tests on the ABSENCE of the old spawn-a-fresh-child
# instruction: re-introducing it in either lane's doctrine file turns this red.
assert_contains "$body" "advisor-consult.sh claim" \
  "8b. the interactive lane still uses the same script-owned budget/ledger"
assert_contains "$body" "SendMessage" \
  "8c. worker.md instructs messaging the advisor that dispatched it"
assert_contains "$body" "STOP and wait" \
  "8d. the consult BLOCKS -- explicit instruction to stop rather than proceed on a guess"
assert_not_contains "$body" "spawn exactly ONE" \
  "8e. worker.md carries no spawn-a-fresh-child instruction"
PROMPT_BODY="$(cat "$PROMPT_MD")"
assert_not_contains "$PROMPT_BODY" "spawn exactly ONE" \
  "8f. the headless lane's doctrine carries no spawn-a-fresh-child instruction either"
assert_not_contains "$PROMPT_BODY" "advisorModel" \
  "8g. and names no model for one to be spawned at"
assert_contains "$PROMPT_BODY" "escalation" \
  "8h. the headless lane's answer to an unresolvable fork is an honest escalation"

# ── 9. D2: the ticket's proposal is implemented, in worker-prompt.md (lane-neutral, both lanes) ──
assert_contains "$PROMPT_BODY" "Implement the ticket's" \
  "9. worker-prompt.md states the implement-the-proposal doctrine (reached by both lanes: worker.md includes this file by reference)"

assert_done
