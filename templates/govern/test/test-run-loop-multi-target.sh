#!/usr/bin/env bash
# Ticket-SET fix + native --parallel mode + parallel-by-default. Locks four invariants:
#  1. `run-loop.sh <N> <N> <N> ...` works EVERY listed ticket (severity-ordered, deduped) — not just
#     the LAST arg. Before the fix, each numeric arg OVERWROTE a single $TARGET, so
#     `run-loop.sh 104 101 101 103 102` silently worked only #102 while reporting a normal DONE line.
#  2. A named set whose members are all ineligible is called out loudly instead of silently doing
#     nothing.
#  3. Concurrency precedence: parallel is the DEFAULT (cap 4), `--serial`/`--parallel=1`/
#     `GOVERN_PARALLEL=1` force sequential, `--parallel=N` beats `GOVERN_PARALLEL=N`, and naming
#     exactly ONE ticket stays sequential.
#  4. A named set larger than the concurrency cap still finishes EVERY ticket: the orchestrator
#     reaps and refills up to the cap rather than stopping after its first wave.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
RL="$DIR/../run-loop.sh"

# stub claude: resolves whatever ticket GOVERN_REPORT_PATH names, no migrations — kept deliberately
# simple (unlike test-run-loop.sh's fixture) so failures here point at ticket-SET/--parallel logic,
# not migration handling already covered elsewhere.
mk_claude_stub() { # <bindir>
  cat > "$1/claude" <<'EOF'
#!/usr/bin/env bash
prompt=""
while [[ $# -gt 0 ]]; do [[ "$1" == "-p" ]] && { prompt="$2"; shift 2; continue; }; shift; done
if printf '%s' "$prompt" | grep -q 'SUPERVISOR-REVIEW'; then
  printf '{"type":"result","result":%s}\n' "$(printf '{"verdict":"ok","concerns":[],"haltReason":null}' | jq -Rs .)"
  exit 0
fi
n="$(printf '%s' "${GOVERN_REPORT_PATH:-}" | sed -E 's#.*/ticket-([0-9]+)/.*#\1#')"
report="{\"status\":\"resolved\",\"pr\":{\"repo\":\"alpha\",\"number\":${n}01,\"url\":\"http://pr/${n}\"},\"lessonPatch\":null,\"newTickets\":[],\"crossRefs\":{\"overlaps\":[],\"dependsOn\":[]},\"migration\":null,\"escalation\":null}"
[[ -n "${GOVERN_REPORT_PATH:-}" ]] && printf '%s' "$report" > "$GOVERN_REPORT_PATH"
printf '{"type":"result","result":%s}\n' "$(printf '%s' "$report" | jq -Rs .)"
EOF
  chmod +x "$1/claude"
}
mk_gh_stub() { # <bindir>
  cat > "$1/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"pr list"*)  echo '[]';;
  *)            echo '[{"bucket":"pass"}]';;
esac
EOF
  chmod +x "$1/gh"
}

# ── 1. Ticket SET fix (sequential): every listed target resolves, severity order, dedup ──────────
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/governor" "$T/logs" "$T/wt"
( cd "$T" && git init -q && git config user.email t@t && git config user.name t )
mk_ws_stub "$T"
cat > "$T/tickets.md" <<'EOF'
# Tickets
---
## #101 — high one
**Severity:** High — a.
---
## #102 — high two
**Severity:** High — b.
---
## #103 — medium one
**Severity:** Medium — c.
---
## #104 — low one
**Severity:** Low — d.
---
EOF
printf '## Open\n\n## Resolved\n' > "$T/governor/escalations.md"
cat > "$T/wt.sh" <<EOF
#!/usr/bin/env bash
mkdir -p "$T/wt/\$1"; echo "$T/wt/\$1"
EOF
chmod +x "$T/wt.sh"
mk_gh_stub "$T/bin"; mk_claude_stub "$T/bin"

# Args deliberately out of severity order AND with a duplicate (101 twice) — proves both severity
# ordering within the set and dedup, on top of the core "every arg is kept" fix.
# `--serial` is explicit because a multi-ticket set now fans out BY DEFAULT (section 4 covers that);
# this section is specifically the SEQUENTIAL set path, so it pins the sequential summary line.
out="$(PATH="$T/bin:$PATH" \
  GOVERN_TICKETS_FILE="$T/tickets.md" \
  GOVERN_ESCALATIONS_FILE="$T/governor/escalations.md" \
  GOVERN_WORKER_PROMPT_FILE="$GOVERN_PROMPTS_DIR/worker-prompt.md" \
  GOVERN_PREFERENCES_FILE="$GOVERN_PROMPTS_DIR/preferences.md" \
  GOVERN_SUPERVISOR_PROMPT_FILE="$GOVERN_PROMPTS_DIR/supervisor-prompt.md" \
  GOVERN_LOG_ROOT="$T/logs" \
  GOVERN_TICKET_SEQ_FILE="$T/.ticket-seq" \
  GOVERN_LOCK="$T/lock" \
  GOVERN_WORKTREE_CMD="$T/wt.sh" \
  GOVERN_CLAUDE_BIN="$T/bin/claude" \
  GOVERN_ECHO=1 GOVERN_SKIP_CI=1 GOVERN_IMPROVE=0 GOVERN_PARALLEL_STAGGER_S=0 \
  bash "$RL" --serial 104 101 101 103 102 2>&1)"

assert_contains "$out" "targets: (target set: #104 #101 #103 #102 · 4)" "run-start log names the full parsed set — duplicate folded, arg order preserved"
assert_contains "$out" "resolved=4 parked=0 failed=0" "all FOUR distinct targets resolved — none silently dropped (the original bug kept only the last)"
remaining="$(grep -c '^## #' "$T/tickets.md" || true)"
assert_eq "$remaining" "0" "all four ticket blocks removed from tickets.md"
commits="$(cd "$T" && git log --oneline | grep -c 'resolve #' || true)"
assert_eq "$commits" "4" "4 distinct resolve commits — #101 #102 #103 #104, not just #102 (the old last-arg-wins bug)"

# ── 2. a named set with nothing eligible is called out LOUDLY, never silent ─────────────────────
T2="$(mktemp -d)"; trap 'rm -rf "$T" "$T2"' EXIT
mkdir -p "$T2/governor" "$T2/logs"
( cd "$T2" && git init -q && git config user.email t@t && git config user.name t )
mk_ws_stub "$T2"
printf '# Tickets\n' > "$T2/tickets.md"   # no tickets at all
printf '## Open\n\n## Resolved\n' > "$T2/governor/escalations.md"
rc2=0
out2="$(GOVERN_TICKETS_FILE="$T2/tickets.md" \
  GOVERN_ESCALATIONS_FILE="$T2/governor/escalations.md" \
  GOVERN_WORKER_PROMPT_FILE="$GOVERN_PROMPTS_DIR/worker-prompt.md" \
  GOVERN_PREFERENCES_FILE="$GOVERN_PROMPTS_DIR/preferences.md" \
  GOVERN_LOG_ROOT="$T2/logs" \
  GOVERN_LOCK="$T2/lock" \
  bash "$RL" --dry-run --parallel=2 901 902 2>&1)" || rc2=$?
assert_contains "$out2" "target #901 not found in tickets.md" "a named ticket that does not exist is named, never silently dropped"
assert_contains "$out2" "no named ticket is eligible — nothing dispatched" "a wholly-ineligible set is called out explicitly"
assert_eq "$rc2" "0" "a wholly-ineligible named set is a clean no-op, not an error"

# ── 3. --parallel actually runs a target set concurrently and aggregates one combined tally ──────
T3="$(mktemp -d)"; trap 'rm -rf "$T" "$T2" "$T3"' EXIT
mkdir -p "$T3/bin" "$T3/governor" "$T3/logs" "$T3/wt"
( cd "$T3" && git init -q && git config user.email t@t && git config user.name t )
mk_ws_stub "$T3"
cat > "$T3/tickets.md" <<'EOF'
# Tickets
---
## #201 — high one
**Severity:** High — a.
---
## #202 — medium one
**Severity:** Medium — b.
---
EOF
printf '## Open\n\n## Resolved\n' > "$T3/governor/escalations.md"
cat > "$T3/wt.sh" <<EOF
#!/usr/bin/env bash
mkdir -p "$T3/wt/\$1"; echo "$T3/wt/\$1"
EOF
chmod +x "$T3/wt.sh"
mk_gh_stub "$T3/bin"; mk_claude_stub "$T3/bin"

out3="$(PATH="$T3/bin:$PATH" \
  GOVERN_TICKETS_FILE="$T3/tickets.md" \
  GOVERN_ESCALATIONS_FILE="$T3/governor/escalations.md" \
  GOVERN_WORKER_PROMPT_FILE="$GOVERN_PROMPTS_DIR/worker-prompt.md" \
  GOVERN_PREFERENCES_FILE="$GOVERN_PROMPTS_DIR/preferences.md" \
  GOVERN_SUPERVISOR_PROMPT_FILE="$GOVERN_PROMPTS_DIR/supervisor-prompt.md" \
  GOVERN_LOG_ROOT="$T3/logs" \
  GOVERN_TICKET_SEQ_FILE="$T3/.ticket-seq" \
  GOVERN_LOCK="$T3/lock" \
  GOVERN_WORKTREE_CMD="$T3/wt.sh" \
  GOVERN_CLAUDE_BIN="$T3/bin/claude" \
  GOVERN_ECHO=1 GOVERN_SKIP_CI=1 GOVERN_IMPROVE=0 GOVERN_PARALLEL_STAGGER_S=0 \
  bash "$RL" --parallel=2 201 202 2>&1)"; rc3=$?

assert_contains "$out3" "parallel mode: 2 locality group(s)" "orchestrator announces the plan before spawning"
assert_contains "$out3" "parallel run done: 2 driver(s) processed 2 ticket(s) → resolved 2 · parked 0 · failed 0" "aggregate tally covers BOTH children in one line"
assert_eq "$rc3" "0" "a fully-resolved parallel run exits 0"
remaining3="$(grep -c '^## #' "$T3/tickets.md" || true)"
assert_eq "$remaining3" "0" "both concurrently-processed tickets removed from tickets.md — no lost update"
commits3="$(cd "$T3" && git log --oneline | grep -c 'resolve #' || true)"
assert_eq "$commits3" "2" "2 distinct resolve commits from 2 concurrent children — bookkeep lock kept it exactly-once"

# ── 4. Concurrency PRECEDENCE — parallel is the default; --serial/--parallel=1 opt back out ──────
# Asserted off the run-start "concurrency:" line, which the driver logs unconditionally before any
# selection happens — so these cases need no tickets, no worker, and no worktree at all. An empty
# backlog keeps each invocation to a few hundred milliseconds.
T4="$(mktemp -d)"; trap 'rm -rf "$T" "$T2" "$T3" "$T4"' EXIT
mkdir -p "$T4/governor" "$T4/logs"
( cd "$T4" && git init -q && git config user.email t@t && git config user.name t )
mk_ws_stub "$T4"
printf '# Tickets\n' > "$T4/tickets.md"
printf '## Open\n\n## Resolved\n' > "$T4/governor/escalations.md"
mode_run() { # <args...> → the run's stdout+stderr. Always names tickets: a bare run exits 2.
  GOVERN_TICKETS_FILE="$T4/tickets.md" \
  GOVERN_ESCALATIONS_FILE="$T4/governor/escalations.md" \
  GOVERN_WORKER_PROMPT_FILE="$GOVERN_PROMPTS_DIR/worker-prompt.md" \
  GOVERN_PREFERENCES_FILE="$GOVERN_PROMPTS_DIR/preferences.md" \
  GOVERN_LOG_ROOT="$T4/logs" \
  GOVERN_LOCK="$T4/lock" \
  bash "$RL" --dry-run "$@" 2>&1
}
SET3="101 102 103"
# GOVERN_PARALLEL_DEFAULT is the per-workspace default concurrency. The fallback is 4, not 1, and
# that is load-bearing: `/shiploop:update` PRESERVES a workspace's scripts/lib/workspace.sh, so an
# existing fleet can NEVER pick up a new default from the template. The run-loop fallback is the only
# path that reaches them. An explicit knob (including =1) always wins, and `--serial` opts out of any
# single run.
assert_contains "$(mode_run $SET3)" "concurrency: parallel — up to 4 group(s) at once" \
  "a named SET + GOVERN_PARALLEL_DEFAULT unset → PARALLEL at the fallback cap of 4 (clamped to the real group count once the set is partitioned)"
assert_contains "$(GOVERN_PARALLEL_DEFAULT=4 mode_run $SET3)" "concurrency: parallel — up to 4 group(s) at once" \
  "GOVERN_PARALLEL_DEFAULT=4 sets the provisional cap for a named set"
assert_contains "$(GOVERN_PARALLEL_DEFAULT=1 mode_run $SET3)" "concurrency: serial — one group at a time" \
  "GOVERN_PARALLEL_DEFAULT=1 is the explicit way to say sequential"
assert_contains "$(GOVERN_PARALLEL_DEFAULT=4 mode_run --serial $SET3)" "concurrency: serial — one group at a time" \
  "--serial opts back out of a workspace's parallel default for one run"
assert_contains "$(GOVERN_PARALLEL_DEFAULT=4 mode_run 101)" "concurrency: serial — one group at a time" \
  "one named ticket ignores the workspace default — nothing to fan out"
assert_contains "$(mode_run --parallel $SET3)" "concurrency: parallel — up to 4 group(s) at once" \
  "a bare --parallel on a workspace that never set the knob still fans out, never collapses to serial"
assert_contains "$(mode_run --parallel=1 $SET3)" "concurrency: serial — one group at a time" \
  "--parallel=1 means the same as --serial"
assert_contains "$(GOVERN_PARALLEL=1 mode_run $SET3)" "concurrency: serial — one group at a time" \
  "GOVERN_PARALLEL=1 also collapses to the sequential driver"
assert_contains "$(GOVERN_PARALLEL=7 mode_run $SET3)" "concurrency: parallel — up to 7 group(s) at once" \
  "GOVERN_PARALLEL=N alone (no flag) sets parallel mode AND the cap"
assert_contains "$(GOVERN_PARALLEL=7 mode_run --parallel=2 $SET3)" "concurrency: parallel — up to 2 group(s) at once" \
  "--parallel=N BEATS GOVERN_PARALLEL=N (flag > env, per the documented precedence)"
assert_contains "$(GOVERN_PARALLEL=7 mode_run --serial $SET3)" "concurrency: serial — one group at a time" \
  "--serial wins over everything, including GOVERN_PARALLEL"
assert_contains "$(mode_run 101)" "concurrency: serial — one group at a time" \
  "naming EXACTLY ONE ticket stays sequential — nothing to fan out, no orchestrator process in the way"
# A bare invocation is a usage error, not an empty run.
rc0=0; out0="$(mode_run)" || rc0=$?
assert_eq "$rc0" "2" "a run with no ticket named exits 2 (usage), never 0"
assert_contains "$out0" "usage: run-loop.sh" "…and prints usage"

# ── 5. A named set LARGER than the cap still finishes every ticket ──────────────────────────────
# The regression this guards: an orchestrator that spawns PARALLEL_N children and exits would
# silently truncate a 5-ticket dispatch to 2. Reap-and-refill must cover the whole named set.
T5="$(mktemp -d)"; trap 'rm -rf "$T" "$T2" "$T3" "$T4" "$T5"' EXIT
mkdir -p "$T5/bin" "$T5/governor" "$T5/logs" "$T5/wt"
( cd "$T5" && git init -q && git config user.email t@t && git config user.name t )
mk_ws_stub "$T5"
{ echo "# Tickets"; for n in 301 302 303 304 305; do
    printf -- '---\n## #%s — one\n**Severity:** High — x.\n' "$n"; done; echo "---"; } > "$T5/tickets.md"
printf '## Open\n\n## Resolved\n' > "$T5/governor/escalations.md"
cat > "$T5/wt.sh" <<EOF
#!/usr/bin/env bash
mkdir -p "$T5/wt/\$1"; echo "$T5/wt/\$1"
EOF
chmod +x "$T5/wt.sh"
mk_gh_stub "$T5/bin"; mk_claude_stub "$T5/bin"

rc5=0
out5="$(PATH="$T5/bin:$PATH" \
  GOVERN_TICKETS_FILE="$T5/tickets.md" \
  GOVERN_ESCALATIONS_FILE="$T5/governor/escalations.md" \
  GOVERN_WORKER_PROMPT_FILE="$GOVERN_PROMPTS_DIR/worker-prompt.md" \
  GOVERN_PREFERENCES_FILE="$GOVERN_PROMPTS_DIR/preferences.md" \
  GOVERN_LOG_ROOT="$T5/logs" \
  GOVERN_TICKET_SEQ_FILE="$T5/.ticket-seq" \
  GOVERN_LOCK="$T5/lock" \
  GOVERN_WORKTREE_CMD="$T5/wt.sh" \
  GOVERN_CLAUDE_BIN="$T5/bin/claude" \
  GOVERN_ECHO=1 GOVERN_SKIP_CI=1 GOVERN_IMPROVE=0 GOVERN_PARALLEL_STAGGER_S=0 \
  bash "$RL" --parallel=2 301 302 303 304 305 2>&1)" || rc5=$?

assert_contains "$out5" "dispatching 5 locality group(s) from 5 named ticket(s)" \
  "the whole named set is partitioned before anything is dispatched"
assert_contains "$out5" "parallel run done: 5 driver(s) processed 5 ticket(s) → resolved 5" \
  "all FIVE named tickets processed at a cap of 2 — the orchestrator reaped and refilled"
assert_eq "$rc5" "0" "a fully-resolved refilling dispatch exits 0"
remaining5="$(grep -c '^## #' "$T5/tickets.md" || true)"
assert_eq "$remaining5" "0" "no named ticket left behind"

assert_done
