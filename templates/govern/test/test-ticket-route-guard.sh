#!/usr/bin/env bash
# router-posture-guard.sh: the ticket-route guard (one of the file's BLOCKING paths).
#
# Vocabulary under test: a **worker** is the trim, single-ticket session dispatched as
# `Agent(subagent_type: "worker")`. Anything else the Agent tool spawns is a **subagent**.
# Ticket-shaped work belongs to a worker, so a ticket-shaped `Agent` call WITHOUT
# subagent_type "worker" is denied -- but ONLY once the referenced ticket number is confirmed to
# exist in queue/tickets.md. Sandboxed with mk_ws_stub plus a fixture tickets.md (#42, #50, #126,
# #200, #955, #1004) so that fact check has something real to confirm; a number NOT in the
# fixture proves the negative direction.
#
# Contract:
#   1. A ticket-shaped Agent prompt (`#42`, a REAL ticket) without subagent_type "worker" is
#      DENIED, and the deny reason carries the exact call to paste plus the govern alternative.
#   2. The word "ticket" alone (no `#N`) is ticket-shaped, but there is no number to confirm
#      against queue/tickets.md, so it is ADVISORY, never a block -- the guard cannot verify a
#      fact it was never given.
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
#   8. A write marker under a NEGATION ("do not open a PR", "not create a
#      worktree") does not count against the exemption, for EVERY write marker, not
#      just the "do not edit/commit" pair the first fix special-cased. A genuine,
#      non-negated write verb still defeats it (on a REAL ticket number: DENIED).
#   9. AUTHORING is its own two-signal exemption: an authoring verb
#      (draft/author) PLUS a content-artifact noun (prose, write-up, entries) reads
#      as producing text about a ticket, not dispatching it -- even though the
#      quoted/drafted text is full of ticket references and "Fix:"-shaped headers.
#      Either signal alone, or a real non-negated write verb anywhere, still denies
#      (on a REAL ticket number).
#  10. Item-shaped NAME/DESCRIPTION (`t1004`, `ticket-955`, `w973`) carries
#      ticket-shaped + dispatch intent on its own, even when the PROMPT body never
#      says "ticket" or a dispatch verb. A single-digit `t1`/`t2` is a step label,
#      not a ticket number, and stays untouched; an item-shaped name doing
#      genuinely read-only work is still exempt.
#  11. subagent_type "lookup"/"investigator" is exempt from the deny
#      even on a GENUINELY ticket-shaped, non-read-only-framed dispatch -- proven from
#      the type alone, the same as "worker" already was, never from prompt shape. The
#      identical prompt with no subagent_type (or a stock type) is still denied: the
#      type is what changed, not the words.
#  12. A bare `#NNN` marked in prose as a PULL REQUEST ("PR #166")
#      is not a ticket reference: it must not make an otherwise non-ticket prompt
#      ticket-shaped. A genuine ticket reference elsewhere in the same prompt still
#      denies, so the fix narrows the false positive without widening the exemption.
#  13. One negator governs a whole LIST in English -- "do not
#      edit, commit, or create anything" negates BOTH edit and commit -- but the
#      first negation fix only stripped ONE write verb per trigger, so a read-only
#      audit prompt (read-only, audit, explain, report back, do not edit) was denied
#      anyway because "commit" survived un-negated later in the same sentence.
#  14. the fan-out cap: nothing previously counted a genuine
#      subagent_type "worker" dispatch, so a session could spawn unbounded workers.
#      Past MAX_WORKERS_PER_SESSION, an advisory (never a deny) is attached; the
#      kill switch is GOVERN_WORKER_FANOUT_NUDGE=0.
#  15. The FACT gate: a ticket-shaped/item-shaped, non-exempt call whose number has no matching
#      `## #N` block in queue/tickets.md is ADVISORY, never DENIED -- covers both a bare "ticket"
#      mention (test 2) and a resolvable-but-nonexistent number (test 15). Regression case: the
#      original false positive (schema "ticket" ROWS plus "bug-fix COMMITS", no ticket number
#      anywhere in the prompt) passes clean.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 required by the hook under test"; exit 0; }

[ -n "${GOVERN_HOOKS_DIR:-}" ] && [ -f "$GOVERN_HOOKS_DIR/router-posture-guard.sh" ] || \
  { echo "SKIP: router-posture-guard.sh not resolvable in this layout"; exit 0; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"   # scripts/lib/workspace.sh -> META_ROOT="$T", so tickets_file resolves to $T/queue/tickets.md

# Sandbox: copy the real guard under a controlled SELF_ROOT (dirname(guard)/..) so the
# scripts/lib/workspace.sh + queue/tickets.md dual-layout resolve lands on THIS fixture, not
# whatever queue/tickets.md happens to exist in the ambient template tree.
mkdir -p "$T/hooks" "$T/queue"
cp "$GOVERN_HOOKS_DIR/router-posture-guard.sh" "$T/hooks/router-posture-guard.sh"
GUARD="$T/hooks/router-posture-guard.sh"

# Real ticket blocks for every number the DENY-expecting cases below reference. #999999 is
# DELIBERATELY absent, for test 15's negative direction.
cat > "$T/queue/tickets.md" <<'TIX'
# Tickets

## #42 - sample ticket

**Severity:** Low

Observed: x.
Done when: y.

---

## #50 - sample ticket

**Severity:** Low

Done when: y.

---

## #126 - sample ticket

Done when: y.

---

## #200 - sample ticket

Done when: y.

---

## #955 - sample ticket

Done when: y.

---

## #1004 - sample ticket

Done when: y.
TIX

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
clear_fanout() { rm -f "${TMPDIR:-/tmp}/metarepo-router-posture-worker-fanout-$1" 2>/dev/null || true; }

# ── 1. ticket-shaped, no subagent_type, a REAL ticket → DENY with a pasteable fix ───────────
sid="ticketroute-deny"; clear_counter "$sid"
payload "" "You are fixing ticket #42 in the backend repo. Open a PR when done." "$sid" "/tmp/fake-transcript.jsonl"
out="$(env -u GOVERN_RUN bash "$GUARD" < "$PL" 2>&1)"
assert_contains "$out" '"permissionDecision": "deny"' "1. ticket-shaped Agent call on a REAL ticket without subagent_type is DENIED"
assert_contains "$out" 'Agent(' "1b. deny reason contains the call to paste"
assert_contains "$out" 'subagent_type' "1c. deny reason names subagent_type"
assert_contains "$out" 'worker' "1d. deny reason names the worker agent type"
assert_contains "$out" 'npm run govern:pre-dispatch -- 42' "1e. deny reason carries the headless govern alternative with the real ticket number"
assert_contains "$out" 'GOVERN_TICKET_ROUTE_GUARD=0' "1f. deny reason names its own kill switch"
clear_counter "$sid"

# ── 2. the bare word "ticket", no #N at all → ADVISORY, never denied (no fact to check) ─────
sid="ticketroute-word"; clear_counter "$sid"
payload "general-purpose" "Work the ticket in the queue and open a PR." "$sid" "/tmp/fake-transcript.jsonl"
out="$(env -u GOVERN_RUN bash "$GUARD" < "$PL" 2>&1)"
assert_not_contains "$out" '"permissionDecision": "deny"' "2a. /ticket/i without a #N is ticket-shaped but unconfirmed: never denied"
assert_contains "$out" "ROUTER POSTURE" "2b. it still gets an advisory line"
clear_counter "$sid"

# ── 3. subagent_type "worker" is never denied ───────────────────────────────────────────────
# clear_fanout too: this is a genuine worker dispatch, so it counts against the SEPARATE
# fan-out counter (test 14's), and a leftover count from a prior local run would otherwise
# tip this single call past MAX_WORKERS_PER_SESSION and attach an unrelated advisory.
sid="ticketroute-isworker"; clear_counter "$sid"; clear_fanout "$sid"
payload "worker" "You are fixing ticket #42. Open a PR when done." "$sid" "/tmp/fake-transcript.jsonl"
out="$(env -u GOVERN_RUN bash "$GUARD" < "$PL" 2>&1)"
assert_eq "$out" "" "3. a call that is ALREADY subagent_type worker passes untouched"
clear_counter "$sid"; clear_fanout "$sid"

# ── 4. a non-ticket Agent call is never denied ──────────────────────────────────────────────
sid="ticketroute-nonticket"; clear_counter "$sid"
payload "investigator" "Find where the retry classifier reads its inputs and report back." "$sid" "/tmp/fake-transcript.jsonl"
out="$(env -u GOVERN_RUN bash "$GUARD" < "$PL" 2>&1)"
assert_eq "$out" "" "4. non-ticket investigation subagent passes untouched"
clear_counter "$sid"

# ── 4b. cited identifiers and read-only framings are NOT dispatch ───────────────────────────
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

# ── 5. kill switch ───────────────────────────────────────────────────────────────────────────
sid="ticketroute-killswitch"; clear_counter "$sid"
payload "" "You are fixing ticket #42." "$sid" "/tmp/fake-transcript.jsonl"
out="$(env -u GOVERN_RUN GOVERN_TICKET_ROUTE_GUARD=0 bash "$GUARD" < "$PL" 2>&1)"
assert_eq "$out" "" "5. GOVERN_TICKET_ROUTE_GUARD=0 silences the ticket-route guard"
clear_counter "$sid"

# ── 6. never fires inside a worker ──────────────────────────────────────────────────────────
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

# ── 7. a deny does not consume the shared per-session advisory warn cap ─────────────────────
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

# ── 8. negated write verbs beyond edit/commit don't count against the exemption ─────────────
# The first fix only special-cased "do not (edit|commit)"; a prohibition worded
# "do not open a PR" / "do not create a worktree" slipped straight past it.
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

# ── 9. authoring exemption: drafting queue-entry prose is not ticket dispatch ───────────────
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

# ── 10. named-child blind spot: an item-shaped name/description carries both signals ────────
# Item-named children measured since 2026-09-04 outnumbered subagent_type
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
assert_contains "$out" '"permissionDecision": "deny"' "10a. name t1004 (a REAL ticket) with dispatch language but no ticket vocab in the prompt is DENIED"
clear_counter "$sid"

sid="ticketroute-namedblind2"; clear_counter "$sid"
payload_named "" "ticket-955" "Handle the payment-retry regression end to end." "$sid"
out="$(env -u GOVERN_RUN bash "$GUARD" < "$PL" 2>&1)"
assert_contains "$out" '"permissionDecision": "deny"' "10b. description ticket-955 (a REAL ticket, no name field) is item-shaped too"
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

# ── 11. subagent_type lookup/investigator is a read-only data child, exempt by
#          TYPE ALONE, even on a prompt that would otherwise deny ──────────────────────────
# Same prompt, two directions: no subagent_type denies (this is genuine ticket
# dispatch, per test 1's shape), lookup/investigator does not, because the type
# itself is provably read-only (tools: Read, Grep, Glob, Bash -- no Write/Edit/Agent).
sid="ticketroute-d9-stock"; clear_counter "$sid"
payload "" "Resolve ticket #50 end to end and open a PR when done." "$sid" "/tmp/fake-transcript.jsonl"
out="$(env -u GOVERN_RUN bash "$GUARD" < "$PL" 2>&1)"
assert_contains "$out" '"permissionDecision": "deny"' "11a. the same ticket-shaped prompt (a REAL ticket) with no subagent_type is DENIED (baseline)"
clear_counter "$sid"

sid="ticketroute-d9-lookup"; clear_counter "$sid"
payload "lookup" "Resolve ticket #50 end to end and open a PR when done." "$sid" "/tmp/fake-transcript.jsonl"
out="$(env -u GOVERN_RUN bash "$GUARD" < "$PL" 2>&1)"
assert_eq "$out" "" "11b. subagent_type lookup passes untouched on the IDENTICAL prompt (type, not prompt shape, is what exempts it)"
clear_counter "$sid"

sid="ticketroute-d9-investigator"; clear_counter "$sid"
payload "investigator" "Resolve ticket #50 end to end and open a PR when done." "$sid" "/tmp/fake-transcript.jsonl"
out="$(env -u GOVERN_RUN bash "$GUARD" < "$PL" 2>&1)"
assert_eq "$out" "" "11c. subagent_type investigator passes untouched on the same genuinely-dispatch-shaped prompt"
clear_counter "$sid"

# ── 12. a "#NNN" that prose marks as a PULL REQUEST is not a ticket reference ────────────────
sid="ticketroute-prref-only"; clear_counter "$sid"
payload "" "Reference: PR #166. Finish the migration end to end." "$sid" "/tmp/fake-transcript.jsonl"
out="$(env -u GOVERN_RUN bash "$GUARD" < "$PL" 2>&1)"
assert_eq "$out" "" "12a. 'PR #166' with no other ticket signal is NOT ticket-shaped (the literal regression case)"
clear_counter "$sid"

sid="ticketroute-prref-lower"; clear_counter "$sid"
payload "" "the changelog says pr #166 shipped last week. now finish the migration end to end." "$sid" "/tmp/fake-transcript.jsonl"
out="$(env -u GOVERN_RUN bash "$GUARD" < "$PL" 2>&1)"
assert_eq "$out" "" "12b. lower-case 'pr #166' is exempted the same way"
clear_counter "$sid"

sid="ticketroute-prref-plus-real"; clear_counter "$sid"
payload "" "PR #166 introduced the bug. Please resolve ticket #200 end to end." "$sid" "/tmp/fake-transcript.jsonl"
out="$(env -u GOVERN_RUN bash "$GUARD" < "$PL" 2>&1)"
assert_contains "$out" '"permissionDecision": "deny"' "12c. a genuine ticket reference (a REAL ticket) alongside a PR reference is still DENIED"
assert_contains "$out" 'govern:pre-dispatch -- 200' "12d. the recovered ticket number is the real ticket (200), never the PR number (166)"
clear_counter "$sid"

# ── 13. one negator governs a whole LIST, not just the first write verb ─────────────────────
sid="ticketroute-neglist"; clear_counter "$sid"
payload "" "Audit ticket #126 read-only and fix the root-cause writeup: investigate why the guard denies audits, explain the finding, and report back. Do not edit, commit, or create anything." "$sid" "/tmp/fake-transcript.jsonl"
out="$(env -u GOVERN_RUN bash "$GUARD" < "$PL" 2>&1)"
assert_eq "$out" "" "13. a read-only framing with a NEGATED LIST of write verbs (edit, commit) is exempt"
clear_counter "$sid"

sid="ticketroute-neglist-mixed"; clear_counter "$sid"
payload "" "Audit ticket #126 read-only: investigate and fix the root cause, explain the finding, and report back. Do not edit or create anything, then commit the fix." "$sid" "/tmp/fake-transcript.jsonl"
out="$(env -u GOVERN_RUN bash "$GUARD" < "$PL" 2>&1)"
assert_contains "$out" '"permissionDecision": "deny"' "13b. a real (non-negated) write verb (on a REAL ticket) OUTSIDE the negated list is still DENIED"
clear_counter "$sid"

# ── 14. the fan-out cap on genuine WORKER dispatches, advisory only ─────────────────────────
# MAX_WORKERS_PER_SESSION=5 in the script under test. This is a SEPARATE counter
# file from the Read/Bash advisory one (contract item 7's cap must stay untouched).
sid="ticketroute-fanout"; clear_fanout "$sid"
nudged=0; denies=0
for i in 1 2 3 4 5 6; do
  payload "worker" "Resolve ticket #$((900 + i)) end to end and open a PR." "$sid" "/tmp/fake-transcript-fanout-$i.jsonl"
  out="$(env -u GOVERN_RUN bash "$GUARD" < "$PL" 2>&1)"
  case "$out" in *'"permissionDecision": "deny"'*) denies=$((denies + 1)) ;; esac
  [ -n "$out" ] && nudged=$((nudged + 1))
done
assert_eq "$denies" "0" "14a. a worker-typed dispatch is NEVER denied by the fan-out cap, however many fire"
assert_eq "$nudged" "1" "14b. exactly one advisory fires, on the 6th dispatch (past MAX_WORKERS_PER_SESSION=5)"
out_last="$out"
assert_contains "$out_last" "6" "14c. the advisory names the running dispatch count"
assert_contains "$out_last" "GOVERN_WORKER_FANOUT_NUDGE=0" "14d. the advisory names its own kill switch"
clear_fanout "$sid"

sid="ticketroute-fanout-killswitch"; clear_fanout "$sid"
for i in 1 2 3 4 5 6; do
  payload "worker" "Resolve ticket #$((900 + i)) end to end and open a PR." "$sid" "/tmp/fake-transcript-fk-$i.jsonl"
  out="$(env -u GOVERN_RUN GOVERN_WORKER_FANOUT_NUDGE=0 bash "$GUARD" < "$PL" 2>&1)"
  assert_eq "$out" "" "14e.$i GOVERN_WORKER_FANOUT_NUDGE=0 silences the fan-out advisory even past the cap"
done
clear_fanout "$sid"

# ── 14f. lookup/investigator dispatches never count against the worker fan-out cap ──────────
sid="ticketroute-fanout-datachild"; clear_fanout "$sid"
for i in 1 2 3 4 5 6 7; do
  payload "lookup" "Resolve ticket #$((950 + i)) end to end and open a PR." "$sid" "/tmp/fake-transcript-fd-$i.jsonl"
  out="$(env -u GOVERN_RUN bash "$GUARD" < "$PL" 2>&1)"
  assert_eq "$out" "" "14f.$i a lookup dispatch is silent regardless of count (data children are not capped)"
done
clear_fanout "$sid"

# ── 15. the FACT gate: ticket-shaped/item-shaped + non-exempt is not enough on its own ──────
# The number must actually exist in queue/tickets.md, or this is advisory, never a deny --
# guessing that a NUMBER is real from prose alone is exactly the judgment call moved off this
# guard. #999999 is deliberately absent from the fixture above.
sid="ticketroute-fact-missing"; clear_counter "$sid"
payload "" "Resolve ticket #999999 end to end and open a PR when done." "$sid" "/tmp/fake-transcript.jsonl"
out="$(env -u GOVERN_RUN bash "$GUARD" < "$PL" 2>&1)"
assert_not_contains "$out" '"permissionDecision": "deny"' "15a. a resolvable but NONEXISTENT ticket number is never denied"
assert_contains "$out" "999999" "15b. the advisory still names the unconfirmed number"
clear_counter "$sid"

# ── 15c. "ticket" ROWS and "bug-fix" COMMITS, zero ticket numbers anywhere ──────────────────
# The original false positive: a data-prep subagent building bench datasets used "ticket" only to
# name schema rows and "fix" only inside the compound noun "bug-fix commits" -- no #N anywhere.
sid="ticketroute-schema-regression"; clear_counter "$sid"
payload "general-purpose" "Build the benchmark dataset per bench/backlogs/SCHEMA.md: each row is a ticket with a title, a repo, and the upstream bug-fix commits that resolved it. Write the output to scratch/dataset.jsonl." "$sid" "/tmp/fake-transcript.jsonl"
out="$(env -u GOVERN_RUN bash "$GUARD" < "$PL" 2>&1)"
assert_not_contains "$out" '"permissionDecision": "deny"' "15c. the schema-rows / bug-fix-commits prompt (zero ticket numbers) is never denied"
clear_counter "$sid"

assert_done
