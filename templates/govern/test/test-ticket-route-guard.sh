#!/usr/bin/env bash
# router-posture-guard.sh: the ticket-route guard (the file's one BLOCKING path).
#
# Vocabulary under test: a **worker** is the trim, single-ticket session, two lanes
# (interactive `Agent(subagent_type: "worker")`, autonomous spawn-worker.sh). Anything
# else the Agent tool spawns is a **subagent**. Ticket-shaped work belongs to a worker,
# so a ticket-shaped `Agent` call WITHOUT subagent_type "worker" is denied.
#
# Contract:
#   1. A ticket-shaped Agent prompt (`#42`) without subagent_type "worker" is DENIED,
#      and the deny reason carries the exact call to paste plus the govern alternative.
#   2. The word "ticket" alone (no `#N`) is ticket-shaped too.
#   3. subagent_type "worker" is never denied, however ticket-shaped it is.
#   4. A non-ticket Agent call (investigation, sweep) is never denied.
#   4b. Two signals, not one keyword: a prompt that merely CITES a ticket artifact
#      (`queue/tickets.md`, `ticket-<N>`, `GOVERN_MAX_TICKETS`) is not dispatch, and a
#      read-only framing over ticket vocabulary with no write marker is exempt.
#   5. GOVERN_TICKET_ROUTE_GUARD=0 is the kill switch: silent even on a ticket-shaped call.
#   6. Never fires inside a worker: autonomous lane (GOVERN_RUN set) and interactive lane
#      (transcript under .../subagents/) are both silent. Workers hold the Agent tool for
#      their own sub-delegation, so nagging them is wrong AND would break sub-delegation.
#   7. The deny never consumes the shared per-session warn cap (a deny is not an advisory).
#   8. (#115) A write marker under a NEGATION ("do not open a PR", "not create a
#      worktree") does not count against the exemption, for EVERY write marker, not
#      just the "do not edit/commit" pair the first fix special-cased. A genuine,
#      non-negated write verb still defeats it.
#   9. (#115) AUTHORING is its own two-signal exemption: an authoring verb
#      (draft/author) PLUS a content-artifact noun (prose, write-up, entries) reads
#      as producing text about a ticket, not dispatching it -- even though the
#      quoted/drafted text is full of ticket references and "Fix:"-shaped headers.
#      Either signal alone, or a real non-negated write verb anywhere, still denies.
#  10. (#115) Item-shaped NAME/DESCRIPTION (`t1004`, `ticket-955`, `w973`) carries
#      ticket-shaped + dispatch intent on its own, even when the PROMPT body never
#      says "ticket" or a dispatch verb. A single-digit `t1`/`t2` is a step label,
#      not a ticket number, and stays untouched; an item-shaped name doing
#      genuinely read-only work is still exempt.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 required by the hook under test"; exit 0; }

[ -n "${GOVERN_HOOKS_DIR:-}" ] && [ -f "$GOVERN_HOOKS_DIR/router-posture-guard.sh" ] || \
  { echo "SKIP: router-posture-guard.sh not resolvable in this layout"; exit 0; }
GUARD="$GOVERN_HOOKS_DIR/router-posture-guard.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PL="$T/payload.json"

# Write the payload to a REAL FILE and feed the guard by `<` redirection, never a pipe:
# the GOVERN_RUN=1 case exits before it ever reads stdin, and a pipe writer whose reader
# closed early takes SIGPIPE (the failure mode test-router-posture-guard.sh documents).
payload() { # <subagent_type> <prompt> <session_id> <transcript_path>
  python3 -c '
import json, sys
subagent_type, prompt, session_id, transcript_path = sys.argv[1:5]
ti = {"prompt": prompt, "description": "delegated task"}
if subagent_type:
    ti["subagent_type"] = subagent_type
print(json.dumps({
    "tool_name": "Agent",
    "transcript_path": transcript_path,
    "session_id": session_id,
    "tool_input": ti,
}))
' "$1" "$2" "$3" "$4" > "$PL"
}

clear_counter() { rm -f "${TMPDIR:-/tmp}/metarepo-router-posture-guard-$1" 2>/dev/null || true; }

# ── 1. ticket-shaped, no subagent_type → DENY with a pasteable fix ──────────
sid="ticketroute-deny"; clear_counter "$sid"
payload "" "You are fixing ticket #42 in the backend repo. Open a PR when done." "$sid" "/tmp/fake-transcript.jsonl"
out="$(env -u GOVERN_RUN bash "$GUARD" < "$PL" 2>&1)"
assert_contains "$out" '"permissionDecision": "deny"' "1. ticket-shaped Agent call without subagent_type is DENIED"
assert_contains "$out" 'Agent(' "1b. deny reason contains the call to paste"
assert_contains "$out" 'subagent_type' "1c. deny reason names subagent_type"
assert_contains "$out" 'worker' "1d. deny reason names the worker agent type"
assert_contains "$out" 'npm run govern:pre-dispatch -- 42' "1e. deny reason carries the headless govern alternative with the real ticket number"
assert_contains "$out" 'GOVERN_TICKET_ROUTE_GUARD=0' "1f. deny reason names its own kill switch"
clear_counter "$sid"

# ── 2. the bare word "ticket" is ticket-shaped too ──────────────────────────
sid="ticketroute-word"; clear_counter "$sid"
payload "general-purpose" "Work the ticket in the queue and open a PR." "$sid" "/tmp/fake-transcript.jsonl"
out="$(env -u GOVERN_RUN bash "$GUARD" < "$PL" 2>&1)"
assert_contains "$out" '"permissionDecision": "deny"' "2. /ticket/i without a #N is ticket-shaped and denied"
clear_counter "$sid"

# ── 3. subagent_type "worker" is never denied ───────────────────────────────
sid="ticketroute-isworker"; clear_counter "$sid"
payload "worker" "You are fixing ticket #42. Open a PR when done." "$sid" "/tmp/fake-transcript.jsonl"
out="$(env -u GOVERN_RUN bash "$GUARD" < "$PL" 2>&1)"
assert_eq "$out" "" "3. a call that is ALREADY subagent_type worker passes untouched"
clear_counter "$sid"

# ── 4. a non-ticket Agent call is never denied ──────────────────────────────
sid="ticketroute-nonticket"; clear_counter "$sid"
payload "investigator" "Find where the retry classifier reads its inputs and report back." "$sid" "/tmp/fake-transcript.jsonl"
out="$(env -u GOVERN_RUN bash "$GUARD" < "$PL" 2>&1)"
assert_eq "$out" "" "4. non-ticket investigation subagent passes untouched"
clear_counter "$sid"

# ── 4b. cited identifiers and read-only framings are NOT dispatch ───────────
# Regression: the guard used to be a blind `/ticket/i` + `/#[0-9]+/` scan, so it denied
# a prompt that quoted the real filename `queue/tickets.md` and a prompt whose whole job
# was auditing ticket TERMINOLOGY. Both are read-only work naming an identifier.
not_denied() { # <label> <sid> <prompt>
  clear_counter "$2"
  payload "" "$3" "$2" "/tmp/fake-transcript.jsonl"
  local o; o="$(env -u GOVERN_RUN bash "$GUARD" < "$PL" 2>&1)"
  assert_eq "$o" "" "$1"
  clear_counter "$2"
}
not_denied "4b-i. citing the filename queue/tickets.md is not ticket dispatch" \
  "ticketroute-filename" \
  "The real fix was queue/tickets.md, not the fictional queue.md I was correcting. Update the diagram."
not_denied "4b-ii. auditing ticket terminology is read-only, not ticket dispatch" \
  "ticketroute-audit" \
  "Audit the README ticket terminology rules and report back. Do not edit anything."
not_denied "4b-iii. the identifier GOVERN_MAX_TICKETS is not a ticket reference" \
  "ticketroute-envvar" \
  "Check whether GOVERN_MAX_TICKET_FAILS is respected in pre-dispatch-check.sh and fix the off-by-one."
not_denied "4b-iv. the branch prefix ticket-<N> is not a ticket reference" \
  "ticketroute-branchprefix" \
  "Rename the ticket-<N> branch prefix docs in CONTRIBUTING.md"

# ── 5. kill switch ─────────────────────────────────────────────────────────
sid="ticketroute-killswitch"; clear_counter "$sid"
payload "" "You are fixing ticket #42." "$sid" "/tmp/fake-transcript.jsonl"
out="$(env -u GOVERN_RUN GOVERN_TICKET_ROUTE_GUARD=0 bash "$GUARD" < "$PL" 2>&1)"
assert_eq "$out" "" "5. GOVERN_TICKET_ROUTE_GUARD=0 silences the ticket-route guard"
clear_counter "$sid"

# ── 6. never fires inside a worker (either lane) ────────────────────────────
sid="ticketroute-autonomous"; clear_counter "$sid"
payload "" "You are fixing ticket #42." "$sid" "/tmp/fake-transcript.jsonl"
out="$(GOVERN_RUN=1 bash "$GUARD" < "$PL" 2>&1)"
assert_eq "$out" "" "6a. autonomous lane (GOVERN_RUN set): a worker sub-delegating is never denied"
clear_counter "$sid"

sid="ticketroute-interactive"; clear_counter "$sid"
payload "" "You are fixing ticket #42." "$sid" "/tmp/.claude/subagents/abc/transcript.jsonl"
out="$(env -u GOVERN_RUN bash "$GUARD" < "$PL" 2>&1)"
assert_eq "$out" "" "6b. interactive lane (.../subagents/ transcript): a worker sub-delegating is never denied"
clear_counter "$sid"

# ── 7. a deny does not consume the shared per-session advisory warn cap ─────
# MAX_WARNS_PER_SESSION=3 in the script under test. Five denies in one session must
# all still deny: the cap governs advisories, and a deny is a decision, not a nudge.
sid="ticketroute-cap"; clear_counter "$sid"
denies=0
for i in 1 2 3 4 5; do
  payload "" "You are fixing ticket #42." "$sid" "/tmp/fake-transcript-$i.jsonl"
  out="$(env -u GOVERN_RUN bash "$GUARD" < "$PL" 2>&1)"
  case "$out" in *'"permissionDecision": "deny"'*) denies=$((denies + 1)) ;; esac
done
assert_eq "$denies" "5" "7. all 5 ticket-shaped calls in one session are denied (the warn cap never gates a deny)"
clear_counter "$sid"

# ── 8. negated write verbs beyond edit/commit don't count against the exemption ─────
# The first fix only special-cased "do not (edit|commit)"; a prohibition worded
# "do not open a PR" / "do not create a worktree" slipped straight past it (#115).
sid="ticketroute-negwrite"; clear_counter "$sid"
payload "" "Audit ticket #42, fix it. Do not open a PR, do not create a worktree, and do not merge." "$sid" "/tmp/fake-transcript.jsonl"
out="$(env -u GOVERN_RUN bash "$GUARD" < "$PL" 2>&1)"
assert_eq "$out" "" "8. negated write verbs beyond edit/commit (open a PR, worktree, merge) don't defeat a read-only exemption"
clear_counter "$sid"

sid="ticketroute-negwrite-mixed"; clear_counter "$sid"
payload "" "Audit ticket #42, fix it, and open a PR when done." "$sid" "/tmp/fake-transcript.jsonl"
out="$(env -u GOVERN_RUN bash "$GUARD" < "$PL" 2>&1)"
assert_contains "$out" '"permissionDecision": "deny"' "8b. a real (non-negated) write verb after a read-only framing is still DENIED"
clear_counter "$sid"

# ── 9. authoring exemption: drafting queue-entry prose is not ticket dispatch ───────
# Fresh evidence, 2026-09-10: a general-purpose subagent asked to DRAFT prose for two
# new queue entries (quoting "## #N" and a "Fix:" template header) into a scratchpad
# file was denied twice, even though it explicitly disclaimed opening a PR, creating a
# worktree, or touching product code.
sid="ticketroute-authoring"; clear_counter "$sid"
payload "" "Draft prose for two new queue entries as plain text, referencing ## #117 and ticket #118, in this format: **Where:** ... **Fix:** ... **Done when:** ... Write the result to /private/tmp/scratch/queue-draft.md. This is an AUTHORING task, not work-item resolution: do not open a PR, do not create a worktree, and do not change any product code." "$sid" "/tmp/fake-transcript.jsonl"
out="$(env -u GOVERN_RUN bash "$GUARD" < "$PL" 2>&1)"
assert_eq "$out" "" "9. drafting queue-entry prose into a scratchpad, with only negated write verbs, is not ticket dispatch"
clear_counter "$sid"

sid="ticketroute-authoring-bare"; clear_counter "$sid"
payload "" "Draft a fix for ticket #42 and land it." "$sid" "/tmp/fake-transcript.jsonl"
out="$(env -u GOVERN_RUN bash "$GUARD" < "$PL" 2>&1)"
assert_contains "$out" '"permissionDecision": "deny"' "9b. 'draft a fix' (authoring verb, no content-artifact noun) is still genuine dispatch, still DENIED"
clear_counter "$sid"

sid="ticketroute-authoring-mixed"; clear_counter "$sid"
payload "" "Draft prose for queue entries: ## #42 **Fix:** patch the retry path. Then commit the change yourself." "$sid" "/tmp/fake-transcript.jsonl"
out="$(env -u GOVERN_RUN bash "$GUARD" < "$PL" 2>&1)"
assert_contains "$out" '"permissionDecision": "deny"' "9c. authoring framing with a real (non-negated) commit is still DENIED"
clear_counter "$sid"

# ── 10. named-child blind spot: an item-shaped name/description carries both signals ─
# #115: item-named children measured since 2026-09-04 outnumbered subagent_type
# "worker" ones roughly 4 to 1, and the prompt-only scan saw none of them because the
# PROMPT never says "ticket" or a dispatch verb -- only the NAME/description does.
payload_named() { # <name> <description> <prompt> <session_id>
  python3 -c '
import json, sys
name, desc, prompt, session_id = sys.argv[1:5]
ti = {"prompt": prompt, "description": desc}
if name:
    ti["name"] = name
print(json.dumps({
    "tool_name": "Agent",
    "transcript_path": "/tmp/fake-transcript.jsonl",
    "session_id": session_id,
    "tool_input": ti,
}))
' "$1" "$2" "$3" "$4" > "$PL"
}

sid="ticketroute-namedblind"; clear_counter "$sid"
payload_named "t1004" "delegated task" "Go handle the backend refactor we discussed and land it." "$sid"
out="$(env -u GOVERN_RUN bash "$GUARD" < "$PL" 2>&1)"
assert_contains "$out" '"permissionDecision": "deny"' "10a. name t1004 with dispatch language but no ticket vocab in the prompt is DENIED"
clear_counter "$sid"

sid="ticketroute-namedblind2"; clear_counter "$sid"
payload_named "" "ticket-955" "Handle the payment-retry regression end to end." "$sid"
out="$(env -u GOVERN_RUN bash "$GUARD" < "$PL" 2>&1)"
assert_contains "$out" '"permissionDecision": "deny"' "10b. description ticket-955 (no name field) is item-shaped too"
assert_contains "$out" 'govern:pre-dispatch -- 955' "10c. the ticket number is recovered from the item-shaped field when the prompt has no #N"
clear_counter "$sid"

sid="ticketroute-namedfloor"; clear_counter "$sid"
payload_named "t1" "delegated task" "Summarize step 1 of the plan." "$sid"
out="$(env -u GOVERN_RUN bash "$GUARD" < "$PL" 2>&1)"
assert_eq "$out" "" "10d. single-digit t1 is a step label, not a ticket number, and passes untouched"
clear_counter "$sid"

sid="ticketroute-namedreadonly"; clear_counter "$sid"
payload_named "w973-audit" "delegated task" "Investigate why the retry classifier misfires and report back. Read-only." "$sid"
out="$(env -u GOVERN_RUN bash "$GUARD" < "$PL" 2>&1)"
assert_eq "$out" "" "10e. an item-shaped name doing genuinely read-only work is still exempt"
clear_counter "$sid"

assert_done
