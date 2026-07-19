#!/usr/bin/env bash
# #119 — cross-run wait-for-merge / dependency deferral. Proves:
#   (A) helper layer: ticket_deps parses `**Depends on:** #K`; waits_add/remove/refresh persist +
#       re-evaluate governor/pending-waits.json against PR state (gh stub) + dep presence.
#   (B) pre-spawn dependency gate: a ticket with `**Depends on:** #K` (K still open) is deferred
#       this run, no worker burned; K resolves, the ticket survives in tickets.md for next run.
#   (C) run-start wait re-exclusion: a seeded wait whose PR is OPEN re-excludes its ticket and the
#       entry persists; flip the PR to MERGED and the wait clears so the ticket is worked.
# Stubbed Claude (worker + supervisor) + gh; sandboxed, no network.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
REPO="$(cd "$DIR/../../.." && pwd)"
RL="$DIR/../run-loop.sh"

# ── (A) helper-layer unit tests ──────────────────────────────────────────────
HT="$(mktemp -d)"; trap 'rm -rf "$HT"' EXIT
mkdir -p "$HT/governor" "$HT/bin"
cat > "$HT/tickets.md" <<'EOF'
# Tickets
---
## #1 — needs a dep
**Severity:** High — x.
**Depends on:** #2
body
---
## #2 — the dep
**Severity:** High — y.
body
---
## #12 — digit-boundary decoy
**Severity:** Low — must not match #1's dep scan.
body
---
## #98 — blocked on a merge
**Severity:** Medium — waits on a PR.
body
EOF

# gh stub: PR 5 → state is whatever $HT/pr5_state says; PR 9 → MERGED.
cat > "$HT/bin/gh" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *"pr view 5 "*) cat "$HT/pr5_state" 2>/dev/null || echo OPEN;;
  *"pr view 9 "*) echo MERGED;;
  *) echo OPEN;;
esac
EOF
chmod +x "$HT/bin/gh"
echo OPEN > "$HT/pr5_state"

# GOVERN_WS_ROOT points at the scaffold (so common.sh finds scripts/lib/workspace.sh);
# the data files this helper-layer block exercises are overridden to the $HT sandbox.
export GOVERN_WS_ROOT="$REPO" GOVERN_TICKETS_FILE="$HT/tickets.md" \
       GOVERN_PENDING_WAITS_FILE="$HT/governor/pending-waits.json"
PATH="$HT/bin:$PATH"
source "$DIR/../lib/common.sh"

# ticket_deps: #1 declares dep #2; the #12 decoy is NOT picked up for #1.
deps="$(govern::ticket_deps 1 "$HT/tickets.md" | tr '\n' ',')"
assert_eq "$deps" "2," "ticket_deps parses '**Depends on:** #2' for #1 (no #12 bleed)"
assert_eq "$(govern::ticket_deps 2 "$HT/tickets.md" | tr '\n' ',')" "" "ticket #2 declares no deps"

# #309 — implicit deps from a blocker's `**Blocks:** #N, #M` line: a blocker declares the edge once,
# and each named dependent inherits it WITHOUT its own `**Depends on:**` marker.
BT="$(mktemp -d)"
cat > "$BT/tickets.md" <<'EOF'
# Tickets
---
## #6 — dependent, no marker of its own
**Severity:** Low — x.
body6
---
## #7 — also blocked by #8, no marker
**Severity:** Low — y.
body7
---
## #8 — the blocker, declares the edge for both
**Severity:** Low — z.
**Blocks:** #6, #7
body8
---
## #60 — digit-boundary decoy (must NOT match #6)
**Severity:** Low — b.
body60
---
## #9 — declares its own dep the classic way
**Severity:** Low — a.
**Depends on:** #8
body9
---
## #11 — prose 'blocks' decoy, NOT the bold marker
**Severity:** Low — this ticket blocks #6 in prose but carries no bold marker, so must NOT link.
body11
EOF
assert_eq "$(govern::ticket_deps 6 "$BT/tickets.md" | tr '\n' ',')" "8," "ticket_deps: #6 inherits #8 via '**Blocks:** #6, #7' (bold marker only, prose #11 ignored)"
assert_eq "$(govern::ticket_deps 7 "$BT/tickets.md" | tr '\n' ',')" "8," "ticket_deps: #7 inherits #8 via the same Blocks line"
assert_eq "$(govern::ticket_deps 8 "$BT/tickets.md" | tr '\n' ',')" "" "ticket_deps: blocker #8 has no deps of its own (its Blocks names dependents, not blockers)"
assert_eq "$(govern::ticket_deps 60 "$BT/tickets.md" | tr '\n' ',')" "" "ticket_deps: #60 does NOT match #8's '#6' (exact numeric compare, no digit-boundary bleed)"
assert_eq "$(govern::ticket_deps 9 "$BT/tickets.md" | tr '\n' ',')" "8," "ticket_deps: declared '**Depends on:** #8' still works alongside Blocks propagation"
rm -rf "$BT"

# csv_remove
assert_eq "$(govern::csv_remove "1,3,5" 3)" "1,5" "csv_remove drops the middle element"
assert_eq "$(govern::csv_remove "7" 7)" "" "csv_remove empties a singleton"

# waits_add / waits_remove (de-dupe by ticket, newest wins)
govern::waits_add '{"ticket":98,"pr":5,"repo":"harness"}'
govern::waits_add '{"ticket":98,"pr":5,"repo":"harness","note":"newer"}'
govern::waits_add '{"ticket":1,"dependsOn":2}'
cnt="$(jq '.waits | length' "$HT/governor/pending-waits.json")"
assert_eq "$cnt" "2" "waits_add de-dupes by ticket (98 stored once) + keeps #1"
assert_contains "$(cat "$HT/governor/pending-waits.json")" "newer" "waits_add newest-wins on re-add"
govern::waits_remove 1
assert_eq "$(jq '.waits | length' "$HT/governor/pending-waits.json")" "1" "waits_remove drops #1"

# waits_refresh: #98 PR 5 OPEN → still blocking (printed + kept); flip MERGED → cleared.
out="$(govern::waits_refresh)"
assert_contains "$out" "98	waiting on harness PR #5 (still open)" "refresh keeps #98 while PR 5 OPEN"
assert_eq "$(jq '.waits | length' "$HT/governor/pending-waits.json")" "1" "PR-open wait persists in file"
echo MERGED > "$HT/pr5_state"
out="$(govern::waits_refresh)"
assert_eq "$out" "" "refresh prints nothing once PR 5 MERGED"
assert_eq "$(jq '.waits | length' "$HT/governor/pending-waits.json")" "0" "merged wait dropped from file"

# waits_refresh dependsOn: blocks while dep ticket present, clears when gone.
govern::waits_add '{"ticket":1,"dependsOn":2}'
assert_contains "$(govern::waits_refresh)" "depends on #2 (still open)" "refresh blocks #1 while dep #2 in tickets.md"
# remove #2 from tickets.md → dep resolved → wait clears.
grep -v '## #2 ' "$HT/tickets.md" > "$HT/t2" && mv "$HT/t2" "$HT/tickets.md"
assert_eq "$(govern::waits_refresh)" "" "refresh clears #1 once dep #2 leaves tickets.md"

unset GOVERN_WS_ROOT GOVERN_TICKETS_FILE GOVERN_PENDING_WAITS_FILE

# ── shared loop fixtures (B + C) ─────────────────────────────────────────────
mk_loop_env() { # <tmpdir>
  local T="$1"
  mkdir -p "$T/bin" "$T/governor" "$T/logs" "$T/wt"
  ( cd "$T" && git init -q && git config user.email t@t && git config user.name t )
  printf '## Open\n\n## Resolved\n' > "$T/governor/escalations.md"
  cat > "$T/wt.sh" <<EOF
#!/usr/bin/env bash
mkdir -p "$T/wt/\$1"; echo "$T/wt/\$1"
EOF
  chmod +x "$T/wt.sh"
  # worker: resolves whatever ticket it's handed; supervisor: plain ok (no extra advice).
  cat > "$T/bin/claude" <<'EOF'
#!/usr/bin/env bash
prompt=""
while [[ $# -gt 0 ]]; do [[ "$1" == "-p" ]] && { prompt="$2"; shift 2; continue; }; shift; done
if printf '%s' "$prompt" | grep -q 'SUPERVISOR-REVIEW'; then
  printf '{"type":"result","result":%s}\n' "$(printf '{"verdict":"ok","concerns":[],"skipThisRun":[],"waitForMerge":[],"attemptNext":[],"haltReason":null}' | jq -Rs .)"
  exit 0
fi
n="$(printf '%s' "${GOVERN_REPORT_PATH:-}" | sed -E 's#.*/ticket-([0-9]+)/.*#\1#')"
report="{\"status\":\"resolved\",\"pr\":{\"repo\":\"alpha\",\"number\":${n}01,\"url\":\"http://pr/${n}\"},\"lessonPatch\":null,\"newTickets\":[],\"crossRefs\":{\"overlaps\":[],\"dependsOn\":[]},\"migration\":null,\"escalation\":null}"
[[ -n "${GOVERN_REPORT_PATH:-}" ]] && printf '%s' "$report" > "$GOVERN_REPORT_PATH"
printf '{"type":"result","result":%s}\n' "$(printf '%s' "$report" | jq -Rs .)"
EOF
  chmod +x "$T/bin/claude"
}

run_loop() { # <tmpdir>  → prints loop stdout+stderr; env vars after set on caller
  local T="$1"; shift
  PATH="$T/bin:$PATH" \
    GOVERN_TICKETS_FILE="$T/tickets.md" \
    GOVERN_ESCALATIONS_FILE="$T/governor/escalations.md" \
    GOVERN_PENDING_FILE="$T/governor/pending-escalations.json" \
    GOVERN_PENDING_WAITS_FILE="$T/governor/pending-waits.json" \
    GOVERN_WORKER_PROMPT_FILE="$REPO/governor/worker-prompt.md" \
    GOVERN_PREFERENCES_FILE="$REPO/governor/preferences.md" \
    GOVERN_SUPERVISOR_PROMPT_FILE="$REPO/governor/supervisor-prompt.md" \
    GOVERN_LOG_ROOT="$T/logs" \
    GOVERN_TICKET_SEQ_FILE="$T/.ticket-seq" \
    GOVERN_LOCK="$T/lock" \
    GOVERN_WORKTREE_CMD="$T/wt.sh" \
    GOVERN_CLAUDE_BIN="$T/bin/claude" \
    GOVERN_NO_PUSH=1 GOVERN_SUPERVISOR_EVERY=99 GOVERN_IMPROVE=0 \
    "$@" \
    bash "$RL" 2>&1
}

# ── (B) pre-spawn dependency gate ────────────────────────────────────────────
TB="$(mktemp -d)"; trap 'rm -rf "$HT" "$TB"' EXIT
mk_loop_env "$TB"
# gh: no open PRs (find_pr → empty); default → green CI rollup so await-ci/merge succeed.
cat > "$TB/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in *"pr list"*) echo '[]';; *) echo '[{"bucket":"pass"}]';; esac
EOF
chmod +x "$TB/bin/gh"
cat > "$TB/tickets.md" <<'EOF'
# Tickets
---
## #1 — builds on #2
**Severity:** High — x.
**Depends on:** #2
body1
---
## #2 — the dependency
**Severity:** High — y.
body2
EOF

outB="$(run_loop "$TB")"
assert_contains "$outB" "#1 depends on unresolved #2" "dep gate defers #1 while #2 open (#119)"
assert_contains "$outB" "resolved=1" "only the dependency #2 is worked this run"
# #1 deferred (excluded this run) → still in tickets.md; #2 resolved → removed.
assert_eq "$(grep -cE '^## #1 ' "$TB/tickets.md" || true)" "1" "deferred #1 remains in tickets.md"
assert_eq "$(grep -cE '^## #2 ' "$TB/tickets.md" || true)" "0" "dependency #2 resolved out of tickets.md"

# ── (C) run-start wait re-exclusion from a seeded pending-waits.json ──────────
TC="$(mktemp -d)"; trap 'rm -rf "$HT" "$TB" "$TC"' EXIT
mk_loop_env "$TC"
echo OPEN > "$TC/pr7_state"
cat > "$TC/bin/gh" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *"pr list"*)    echo '[]';;
  *"pr view 7 "*) cat "$TC/pr7_state" 2>/dev/null || echo OPEN;;
  *)              echo '[{"bucket":"pass"}]';;
esac
EOF
chmod +x "$TC/bin/gh"
cat > "$TC/tickets.md" <<'EOF'
# Tickets
---
## #5 — blocked on a PR
**Severity:** High — x.
body5
---
## #6 — free to go
**Severity:** High — y.
body6
EOF
# Seed a wait: #5 waits on harness PR #7.
printf '{"waits":[{"ticket":5,"pr":7,"repo":"harness"}]}\n' > "$TC/governor/pending-waits.json"

outC1="$(run_loop "$TC")"
assert_contains "$outC1" "#5 still blocked" "run-start re-excludes #5 while PR 7 OPEN (#119)"
assert_contains "$outC1" "waiting on harness PR #7" "deferral reason logged"
assert_eq "$(grep -cE '^## #5 ' "$TC/tickets.md" || true)" "1" "blocked #5 not worked — stays in tickets.md"
assert_eq "$(grep -cE '^## #6 ' "$TC/tickets.md" || true)" "0" "unblocked #6 resolved normally"
assert_eq "$(jq '.waits | length' "$TC/governor/pending-waits.json")" "1" "open-PR wait persists across the run"

# Now PR 7 merges → next run clears the wait and works #5.
echo MERGED > "$TC/pr7_state"
outC2="$(run_loop "$TC")"
assert_contains "$outC2" "harness PR #7 is MERGED; clearing wait" "merged PR clears the wait (#119)"
assert_eq "$(grep -cE '^## #5 ' "$TC/tickets.md" || true)" "0" "#5 worked once its blocker landed"
assert_eq "$(jq '.waits | length' "$TC/governor/pending-waits.json")" "0" "cleared wait removed from file"

assert_done
