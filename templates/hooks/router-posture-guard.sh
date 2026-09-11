#!/usr/bin/env bash
# PreToolUse(Read|Bash|Agent) hook: catch a ROUTER-POSTURE violation at the
# MOMENT it happens: the driver session itself about to do a large inline Read
# or a verbose build / `npm run dev` instead of delegating it, or about to spend
# a full-fat subagent on work that belongs to a worker.
#
# Why this exists (companion to router-posture-reminder.sh):
#   router-posture-reminder.sh primes the delegate-heavy-work posture ONCE per
#   session (UserPromptSubmit) and then stays quiet, so an *in-turn* violation
#   isn't caught when it occurs. Per-turn cost is proportional to THIS session's
#   context size, which is re-sent in full every turn — so a driver that reads a
#   1000+ line file inline or runs a verbose build bloats the window and re-pays
#   for it on every later turn. This hook fires a pointed, low-noise warn at the
#   exact tool call so the driver can redirect the work to a sub-agent.
#
# Design constraints (from the ticket + the once-per-session reminder it extends):
#   • The Read/Bash advisories NEVER block; they only advise via
#     additionalContext. The ticket-route guard (below) is the one deliberate
#     exception: it returns permissionDecision "deny" on Agent calls. Either
#     way the script itself always exits 0.
#   • Low-noise / no per-turn token cost — a small per-session warn CAP (not a
#     per-turn re-inject). After the cap is hit the hook goes silent.
#   • DRIVER only — skip when the call originates from a sub-agent (its
#     transcript_path lives under a .../subagents/ dir) or a governor worker
#     (GOVERN_RUN set): those throwaway sub-sessions are the delegation *target*,
#     so nudging them to "delegate" is noise.
#
# Second advisory (same file, same cap, same driver-only guard): a test/build
# runner (npm test, npm run build/test/check, pytest, go test, cargo test,
# vitest, jest, tsc) invoked WITHOUT verify-filter.sh / `npm run vf` wrapping it
# loses the context savings verify-filter exists for (see templates/govern/
# verify-filter.sh): a passing run's output still lands in the transcript and
# is re-sent every later turn. Kill switch: GOVERN_VF_NUDGE=0.
#
# THIRD behavior, and the only BLOCKING one in this file: the ticket-route guard.
# Vocabulary (one noun, one meaning): a **worker** is the trim, single-ticket
# session. It has two lanes and one doctrine: the interactive lane is
# `Agent(subagent_type: "worker")`, the autonomous lane is govern's headless
# spawn-worker.sh. Any Agent-tool child that is NOT subagent_type "worker" is a
# **subagent** (the platform's own term). "Ticket-shaped" needs TWO signals, not
# one keyword: a real ticket REFERENCE (the word "ticket" on its own, or a bare
# `#<N>`) AND DISPATCH intent (a verb meaning "go make this ticket done") --
# OR an item-shaped `name`/`description` (`t1004`, `ticket-955`, `w973`,
# `t920-fix`), which carries both signals on its own even when the prompt body
# never says "ticket" or a dispatch verb (#115: measured across 95 sessions,
# item-named children outnumbered `worker`-typed ones roughly 4 to 1, and the
# prompt-only scan saw none of them).
#
# A write marker under a NEGATION ("do not open a PR", "never commit",
# "without editing") is the prompt FORBIDDING that action, not evidence it
# will happen. The first cut of this fix only special-cased "do not
# (edit|commit)"; #115 hit the identical defect again on "do not open a PR" /
# "not create a worktree", proving enumerate-the-pairs doesn't scale. The
# negation check is generic instead: ANY write marker preceded (within a
# short filler window) by a negator -- do/does/did not, will not, won't,
# cannot, can't, never, without -- is stripped before the write check ever
# sees it.
#
# A prompt that only QUOTES or DESCRIBES ticket text (drafting queue-entry
# prose for a *different* ticket, reviewing a draft ticket body) is not a
# prompt that DISPATCHES one, even though the quoted text is full of ticket
# references and section headers ("Fix:") that read as dispatch verbs out of
# context (#115, 2026-09-10). Authoring gets its own two-signal exemption,
# same shape as ticket-shaped itself: an authoring verb (draft/author) PLUS a
# content-artifact noun (prose, write-up, queue entr(y|ies), scratchpad) --
# either alone is too weak ("draft" also reads "draft a fix", which IS
# dispatch) but the pair together isn't real dispatch language.
#
# A read-only OR authoring framing with no SURVIVING (non-negated) write
# marker overrides both ticket-shaped signals. A blind `/ticket/i` scan
# denied prompts that merely NAMED a ticket artifact (`queue/tickets.md`,
# `ticket-<N>`, `GOVERN_MAX_TICKETS`) or audited ticket vocabulary. An
# `Agent` call that IS ticket-shaped WITHOUT subagent_type "worker" is a
# full-fat subagent doing a worker's job: it inherits the driver's posture,
# skips the worker doctrine, and costs multiples of a worker for the same
# ticket. That call is DENIED with the correct call written out to paste,
# plus the govern alternative. Kill switch: GOVERN_TICKET_ROUTE_GUARD=0
# (default ON, same polarity as GOVERN_VF_NUDGE above). It never fires
# inside a worker (the GOVERN_RUN and .../subagents/ exemptions below
# already cover both lanes, and workers hold the Agent tool for their own
# sub-delegation) and never on a call that already carries subagent_type
# "worker".
#
# FOURTH behavior, D9 (2026-09-11 spec): a `lookup` or `investigator` Agent call is a
# read-only DATA-COLLECTION child, never routed here even when the prompt is
# ticket-shaped. It exits clean exactly where subagent_type "worker" already does,
# because it is provable rather than heuristic: both types ship with tools: Read,
# Grep, Glob, Bash and nothing that writes, so an advisor gathering what it needs to
# WRITE a proposal (D2) cannot be mistaken for a subagent doing the ticket's actual
# work. Without this exemption, D2's proposal gate and this guard's deny path would
# deadlock the advisor investigating its own ticket -- #126's read-only false
# positive by a second route. D9 also settles the corollary: these children do NOT
# count against the fan-out cap below (that cap targets unbounded WORKER spawning,
# not the advisor's own thinking).
#
# FIFTH behavior, D4's fan-out cap (queue #126 / #115): nothing previously counted a
# genuine `subagent_type: "worker"` dispatch, so a session could spawn an unbounded
# number of them in one turn with zero friction (G4's "way too many workers"
# symptom). Reuses the exact per-session-counter-file MECHANISM the Read/Bash
# advisories below already use, keyed the same way (sanitised session_id), but with
# its OWN file and its OWN kill switch -- a worker dispatch is a materially
# different event from an inline-Read/verbose-build advisory and the two must not
# share a budget or a cap. Advisory only, exactly like those: it never blocks a
# dispatch, only flags one past MAX_WORKERS_PER_SESSION for the driver to notice.
# The deny path above stays the only blocking mechanism in this file. Kill switch:
# GOVERN_WORKER_FANOUT_NUDGE=0.
#
# Output contract: a PreToolUse hook that prints
#   {"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"..."}}
# on stdout (exit 0) injects that text into the model's context WITHOUT blocking
# the tool (no permissionDecision => normal permission flow is untouched).
set -uo pipefail

# --- tuning knobs -----------------------------------------------------------
READ_LINE_THRESHOLD=1000   # a Read spanning >= this many lines counts as "large"
MAX_WARNS_PER_SESSION=3    # after this many warns in a session, stay quiet
# D4's fan-out cap (queue #126 / spec D4): a starting point, not a derived constant.
# Chosen high enough that a legitimate multi-ticket sweep ("several tickets, one at a
# time" per the operator doctrine) doesn't nag on every dispatch, low enough that the
# "way too many workers" symptom G4 measured (every ticket-shaped signal steered
# independently, with zero session-wide count) gets flagged before it compounds.
MAX_WORKERS_PER_SESSION=5

# --- never nag the delegation target (sub-agent / governor worker) ----------
[ -n "${GOVERN_RUN:-}" ] && exit 0

# --- read the PreToolUse stdin payload --------------------------------------
payload="$(cat 2>/dev/null || true)"
[ -n "$payload" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0   # parser needed; degrade silently

# Parse the fields we need with one python3 pass (robust vs. nested tool_input).
# Emits ONE FIELD PER LINE (newlines within values flattened to spaces) so empty
# fields survive and we can read them portably (macOS system bash is 3.2 — no
# `mapfile`; a tab-delimited `read` would also collapse the empty middle fields).
{
  IFS= read -r tool_name
  IFS= read -r transcript_path
  IFS= read -r session_id
  IFS= read -r file_path
  IFS= read -r limit
  IFS= read -r command
  IFS= read -r subagent_type
  IFS= read -r agent_prompt
  IFS= read -r agent_desc
  IFS= read -r agent_name
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
fields = [
    d.get("tool_name") or "",
    d.get("transcript_path") or "",
    d.get("session_id") or "",
    g("file_path"),
    g("limit"),
    g("command"),
    g("subagent_type"),
    g("prompt"),
    g("description"),
    g("name"),
]
for f in fields:
    print(f.replace("\t", " ").replace("\n", " "))
' 2>/dev/null)
tool_name="${tool_name:-}"; transcript_path="${transcript_path:-}"
session_id="${session_id:-}"; file_path="${file_path:-}"
limit="${limit:-}"; command="${command:-}"
subagent_type="${subagent_type:-}"; agent_prompt="${agent_prompt:-}"
agent_desc="${agent_desc:-}"
agent_name="${agent_name:-}"
[ -n "$tool_name" ] || exit 0

# --- skip sub-agent calls (their transcript lives under .../subagents/) ------
case "$transcript_path" in
  */subagents/*) exit 0 ;;
esac

# --- ticket-route guard: ticket-shaped Agent work belongs to a worker --------
# The one BLOCKING path in this file (see the header). Both worker lanes are
# already exempt above: the autonomous lane exports GOVERN_RUN, the interactive
# lane's transcript lives under .../subagents/, so a worker sub-delegating with
# the Agent tool is never touched by this.
if [ "$tool_name" = "Agent" ]; then
  [ "${GOVERN_TICKET_ROUTE_GUARD:-1}" = "0" ] && exit 0
  # Already the worker agent type, or a read-only data-collection child (D9): nothing
  # to route. `lookup`/`investigator` are read-only BY THEIR OWN `tools:` line (Read,
  # Grep, Glob, Bash -- no Write/Edit/Agent), so this is provable from the type alone,
  # never a prompt-shape heuristic, and neither counts against the fan-out cap below.
  case "$subagent_type" in
    lookup|investigator) exit 0 ;;
  esac
  if [ "$subagent_type" = "worker" ]; then
    # D4's fan-out cap (see header FIFTH behavior): count this dispatch, and once a
    # session crosses MAX_WORKERS_PER_SESSION, emit ONE advisory per subsequent
    # dispatch -- never a deny; the deny path above is reserved for ticket-shaped
    # work skipping the worker doctrine entirely, not for "too many of them".
    if [ "${GOVERN_WORKER_FANOUT_NUDGE:-1}" != "0" ]; then
      fanout_sid="$(printf '%s' "$session_id" | tr -c 'A-Za-z0-9._-' '_')"
      [ -n "$fanout_sid" ] || fanout_sid="nosession"
      fanout_counter="${TMPDIR:-/tmp}/metarepo-router-posture-worker-fanout-${fanout_sid}"
      fanout_count=0
      [ -f "$fanout_counter" ] && fanout_count="$(cat "$fanout_counter" 2>/dev/null || echo 0)"
      case "$fanout_count" in (*[!0-9]*) fanout_count=0 ;; esac
      fanout_count=$((fanout_count + 1))
      printf '%s' "$fanout_count" > "$fanout_counter" 2>/dev/null || true
      if [ "$fanout_count" -gt "$MAX_WORKERS_PER_SESSION" ] 2>/dev/null; then
        python3 -c '
import json, sys
print(json.dumps({
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "additionalContext": sys.argv[1],
  }
}))
' "[ROUTER POSTURE] This session has now dispatched ${fanout_count} workers. Each is a separate PR needing its own review and merge -- if this is one investigation spawning parallel units rather than ${fanout_count} genuinely independent tickets, prefer an investigator/sweep instead, or dispatch the remaining tickets one at a time as each prior one lands. Set GOVERN_WORKER_FANOUT_NUDGE=0 to silence this for the session." 2>/dev/null || true
      fi
    fi
    exit 0
  fi
  probe="$agent_prompt $agent_desc"
  # Two signals, never one keyword (see the header). Word boundaries here exclude
  # `/` `.` `-` `_` on purpose: `queue/tickets.md`, `tickets.md`, `ticket-<N>` and
  # `GOVERN_MAX_TICKETS` are IDENTIFIERS being cited, not tickets being dispatched.
  #
  # A bare `#NNN` marked in prose as a PULL REQUEST ("PR #166", "pull request #166")
  # is a PR reference, not a ticket reference (queue #126: a changelog-style sentence
  # read as ticket-shaped dispatch). Anchored the way govern::ticket_deps anchors its
  # own harvest -- it only counts a `#N` that appears on the declared MARKER line, never
  # from surrounding prose -- applied here as an exclusion rather than an inclusion,
  # because free text has no marker line to anchor TO: strip the "pr #N" / "pull
  # request #N" shape from a lowercased copy before the number half of the
  # ticket-reference check ever sees it. The "tickets?" word check is untouched (a PR
  # description that also says "ticket" is still ticket-shaped on that signal alone).
  ticket_word_re='(^|[^[:alnum:]_/.#-])tickets?([^[:alnum:]_/.-]|$)'
  ticket_num_re='(^|[^[:alnum:]])#[0-9]+'
  pr_ref_re='(^|[^[:alnum:]])(pr|pull[[:space:]]+request)[[:space:]]*#[0-9]+'
  dispatch_re='(^|[^[:alnum:]])(resolv(e|es|ing)|fix(es|ing)?|implement(s|ing)?|clos(e|es|ing)|land|ship|complet(e|es|ing)|handl(e|es|ing)|solv(e|es|ing)|address(es)?|work (on|the)|working on|works on|pick up|take on|do the|end[- ]to[- ]end)([^[:alnum:]]|$)'
  # Lowercased once, reused below both for the PR-ref strip here and for the
  # negated-write-verb strip further down -- one lowering, not two.
  probe_lc="$(tr '[:upper:]' '[:lower:]' <<< "$probe")"
  probe_lc_noPR="$(sed -E "s/$pr_ref_re/ /g" <<< "$probe_lc")"

  # Item-shaped NAME/DESCRIPTION: a short slug that carries its own ticket reference +
  # dispatch intent, so a custom-named child that skips ticket vocabulary in its PROMPT
  # (t1004, ticket-955, w973, t920-fix) is still routed (#115). Anchored to the WHOLE
  # field, never a substring, so a prose description ("Fix ticket 930 ready_at") is
  # untouched here -- it already matches the ticket-reference + dispatch_re checks below. `{2,}`
  # floors t/w names at two digits: a single-digit `t1`/`t2` used as an ad-hoc step
  # label ("task 1", "task 2") is not a ticket number.
  item_shape_re='^(t[0-9]{2,}|w[0-9]{2,}|ticket-?[0-9]+)(-[a-zA-Z0-9-]+)?$'

  # NOTE ON PIPE STYLE BELOW: every check here feeds a possibly-large $probe (the
  # full agent prompt) into a consumer via a herestring (`<<<`), never a live
  # `printf '%s' "$var" | grep -q ...` pipe -- a `-q`/`head`-style consumer that
  # stops reading early closes its end while the producer is still writing, and a
  # producer that gets SIGPIPE on a long-enough probe is a silent, hard-to-repro
  # failure. A herestring hands the shell a real fd (backed by a temp file), so
  # there is no live writer to kill.
  ticket_shaped=0
  if { grep -Eq "$ticket_word_re" <<< "$probe_lc" || grep -Eq "$ticket_num_re" <<< "$probe_lc_noPR"; } \
     && grep -Eqi "$dispatch_re" <<< "$probe"; then
    ticket_shaped=1
  fi
  item_shaped=0
  if grep -Eqi "$item_shape_re" <<< "$agent_name" || grep -Eqi "$item_shape_re" <<< "$agent_desc"; then
    item_shaped=1
  fi

  if [ "$ticket_shaped" = 1 ] || [ "$item_shaped" = 1 ]; then
    readonly_re='(^|[^[:alnum:]])(audit(s|ing)?|review(s|ing)?|investigat(e|es|ing|ion)|analy[sz]|diagnos|read[- ]only|report back|explain|survey|inventor(y|ies)|summari[sz]|terminology|wording)'
    write_verbs_re='(open (a|the) pr|commit|worktree|branch|patch|edit|rewrite|apply the fix|merge)'
    write_re="(^|[^[:alnum:]])$write_verbs_re"

    # AUTHORING is its own two-signal exemption, same shape as ticket-shaped itself:
    # drafting queue-entry PROSE quotes ticket vocabulary and "Fix:"-shaped section
    # headers without dispatching anything (#115, 2026-09-10). Neither signal alone is
    # safe on its own -- "draft" also reads "draft a fix" (real dispatch), and
    # "prose"/"entries" show up in unrelated writing -- so both must be present.
    authoring_verb_re='(^|[^[:alnum:]])(draft(s|ing)?|author(s|ing)?)([^[:alnum:]]|$)'
    authoring_noun_re='(prose|scratchpad|write[- ]?up|entr(y|ies))'
    authoring=0
    if grep -Eqi "$authoring_verb_re" <<< "$probe" && grep -Eqi "$authoring_noun_re" <<< "$probe"; then
      authoring=1
    fi

    # A write marker under a NEGATION is the prompt FORBIDDING that action, not
    # evidence it will happen -- generic over every write_re marker rather than a
    # hand-picked "do not edit/commit" pair (#115 hit the same defect twice: a
    # prohibition worded "do not open a PR" / "not create a worktree" slipped past a
    # fix scoped only to edit/commit). Strip a write_re marker preceded, within a
    # short filler window, by a negator: do/does/did not, will not, won't, cannot,
    # can't, never, without. Lowercase first (BSD sed has no case-insensitive flag);
    # this is boolean-only scratch text, never shown to the user. (probe_lc was
    # already lowered above, for the PR-ref strip -- reused here, not recomputed.)
    #
    # #126 (2026-09-11): one negator governs a whole LIST in English -- "do not edit,
    # commit, or create anything" negates BOTH edit and commit -- but the first cut of
    # this pattern only consumed ONE write verb per trigger, so "commit" survived
    # un-negated and re-triggered write_re just past the very prohibition disclaiming
    # it (reproduced twice in-session, including auditing this guard itself). The
    # repeated group below consumes an arbitrary-length comma/word-separated RUN of
    # write verbs after a single negator, not just the first one.
    neg_trigger_re='(do|does|did)[[:space:]]+not|will[[:space:]]+not|won.?t|cannot|can.?t|never|without'
    neg_filler_re='([a-z]+[[:space:]]+){0,3}'
    neg_write_re="(^|[^[:alnum:]])($neg_trigger_re)([[:space:]]+${neg_filler_re}${write_verbs_re})([,]?[[:space:]]+${neg_filler_re}${write_verbs_re})*"
    probe_write_lc="$(sed -E "s/$neg_write_re/ /g" <<< "$probe_lc")"

    exempt=0
    if { grep -Eqi "$readonly_re" <<< "$probe" || [ "$authoring" = 1 ]; } \
       && ! grep -Eq "$write_re" <<< "$probe_write_lc"; then
      exempt=1
    fi
  else
    exempt=1  # neither signal fired; nothing to exempt FROM
  fi

  if { [ "$ticket_shaped" = 1 ] || [ "$item_shaped" = 1 ]; } && [ "$exempt" != 1 ]; then
    # Same PR-ref strip as the signal check above: a genuine ticket number should
    # never be reported as "PR #166" when a real ticket reference is also present.
    tnum="$(grep -oE '#[0-9]+' <<< "$probe_lc_noPR" 2>/dev/null | head -1 | tr -d '#' || true)"
    if [ -z "$tnum" ]; then
      tnum="$(grep -oEi '^(t|w|ticket-?)[0-9]+' <<< "$agent_name"$'\n'"$agent_desc" 2>/dev/null | grep -oE '[0-9]+' | head -1 || true)"
    fi
    [ -n "$tnum" ] || tnum="N"
    deny="$(cat <<EOF
[ROUTER POSTURE] Denied: this is ticket-shaped work, and ticket-shaped work goes to a WORKER, never to a stock subagent. A worker is the trim, single-ticket session: sonnet floor, trimmed tools, its own workspace worktree, ending at PR-open plus a structured report. A stock subagent doing the same ticket carries the driver's posture and none of the worker doctrine, and costs multiples of a worker for the same result.

Interactive lane. Paste this instead:

  Agent(
    subagent_type: "worker",
    description: "ticket #${tnum}",
    prompt: "<the ticket text plus anything the worker needs to start>"
  )

Headless lane, for no open session, one ticket at a time:

  npm run govern:pre-dispatch -- ${tnum}       # verdict: proceed / skip / refuse
  bash scripts/govern/spawn-worker.sh ${tnum}  # opens the PR, prints a JSON report

The interactive lane STOPS at PR-open plus the report too. Landing it either way is the same last step: pipe that report into \`npm run govern:resolve -- ${tnum}\`, which awaits CI, merges, and edits the queue file. Never delete the queue block before merge. If the worker fails once, retry it once with \`model: opus\`, then stop and report.

Not ticket work after all (an investigation, a sweep, a diagnosis feeding an answer, or drafting/authoring prose about a ticket rather than resolving one)? Say so in the prompt -- a read-only framing ("audit", "investigate", "explain", "report back") or an authoring framing ("draft"/"author" plus what you're producing: "prose", "write-up", "entries") with no SURVIVING write marker is already exempt; a write verb inside a prohibition ("do not open a PR", "never commit") does not count against you. Otherwise drop the dispatch verb, the ticket reference, and any item-shaped name/description (t<N>, ticket-<N>, w<N>), and size the subagent per the haiku/sonnet table, or set GOVERN_TICKET_ROUTE_GUARD=0 to turn this guard off for the session.
EOF
)"
    python3 -c '
import json, sys
print(json.dumps({
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": sys.argv[1],
  }
}))
' "$deny" 2>/dev/null || true
  fi
  exit 0
fi

# --- decide whether THIS call is heavy inline work --------------------------
reason=""
case "$tool_name" in
  Read)
    # Large inline Read: unbounded (or wide-limit) read of a big file.
    if [ -n "$file_path" ] && [ -f "$file_path" ]; then
      total_lines="$(wc -l < "$file_path" 2>/dev/null | tr -d ' ')"
      [ -n "$total_lines" ] || total_lines=0
      # effective span = limit if the driver set one, else the whole file
      span="$total_lines"
      if [ -n "$limit" ]; then
        case "$limit" in (*[!0-9]*) ;; (*) span="$limit" ;; esac
      fi
      if [ "$span" -ge "$READ_LINE_THRESHOLD" ] 2>/dev/null; then
        reason="a ${span}-line inline Read of $(basename "$file_path")"
      fi
    fi
    ;;
  Bash)
    # Verbose build / dev-server / install run.
    if printf '%s' "$command" | grep -Eq \
      '(^|[[:space:];&|])((npm|pnpm|yarn|bun)[[:space:]]+(run[[:space:]]+)?(dev|build|start)|(npm|pnpm|bun)[[:space:]]+(ci|install|i)([[:space:]]|$)|yarn[[:space:]]+install|next[[:space:]]+(dev|build)|vite[[:space:]]+build|turbo[[:space:]]+run[[:space:]]+(dev|build)|(cargo|go|docker)[[:space:]]+build|webpack([[:space:]]|$)|tsc([[:space:]]|$))'; then
      reason="a verbose build/dev/install run"
    fi
    ;;
esac

# --- separate advisory: unwrapped test/build runner should use verify-filter
vf_reason=""
if [ "$tool_name" = "Bash" ] && [ "${GOVERN_VF_NUDGE:-1}" != "0" ]; then
  if printf '%s' "$command" | grep -Eq \
      '(^|[[:space:];&|])(npm[[:space:]]+(run[[:space:]]+)?(test|build|check)([[:space:]]|$)|pytest([[:space:]]|$)|go[[:space:]]+test([[:space:]]|$)|cargo[[:space:]]+test([[:space:]]|$)|vitest([[:space:]]|$)|jest([[:space:]]|$)|tsc([[:space:]]|$))' \
    && ! printf '%s' "$command" | grep -Eq \
      '(verify-filter\.sh|npm[[:space:]]+run[[:space:]]+vf([[:space:]]|$))'; then
    vf_reason="a test/build run not wrapped in verify-filter"
  fi
fi

[ -n "$reason" ] || [ -n "$vf_reason" ] || exit 0

# --- rate-limit: cap warns per session --------------------------------------
# sanitize session_id for use in a filename (it's a UUID in practice, but never
# trust it — keep only filename-safe chars so it can't path-traverse).
session_id="$(printf '%s' "$session_id" | tr -c 'A-Za-z0-9._-' '_')"
[ -n "$session_id" ] || session_id="nosession"
counter="${TMPDIR:-/tmp}/metarepo-router-posture-guard-${session_id}"
count=0
[ -f "$counter" ] && count="$(cat "$counter" 2>/dev/null || echo 0)"
case "$count" in (*[!0-9]*) count=0 ;; esac
[ "$count" -ge "$MAX_WARNS_PER_SESSION" ] 2>/dev/null && exit 0
printf '%s' "$((count + 1))" > "$counter" 2>/dev/null || true

# --- emit the non-blocking warn ---------------------------------------------
warn=""
if [ -n "$reason" ]; then
  warn="[ROUTER POSTURE] About to do ${reason} inline. Delegate it to a subagent (run_in_background if long); relay only its verdict. Size the subagent per CLAUDE.md's delegation table (haiku=mechanical, sonnet=search/edits, inherit=judgment-heavy), reaching for the shipped \`lookup\` or \`investigator\` agent types when they fit. If this is ticket-shaped work it belongs to a worker instead: \`Agent(subagent_type: \"worker\")\` for one ticket in-session, or the headless lane (\`npm run govern:pre-dispatch -- <N>\` then \`spawn-worker.sh <N>\`) with no session open. Proceed inline only for a quick one-off check."
fi
if [ -n "$vf_reason" ]; then
  vf_warn="[ROUTER POSTURE] ${vf_reason}: wrap it as \`npm run vf -- <cmd>\` (or \`bash scripts/govern/verify-filter.sh -- <cmd>\`) so a passing run emits nothing into context and a failing run still shows its bounded tail."
  if [ -n "$warn" ]; then warn="$warn $vf_warn"; else warn="$vf_warn"; fi
fi

python3 -c '
import json, sys
print(json.dumps({
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "additionalContext": sys.argv[1],
  }
}))
' "$warn" 2>/dev/null || true
exit 0
