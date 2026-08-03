#!/usr/bin/env bash
# Proves scout-ticket.sh's SURVEYOR half — the sanitize/clamp guard, the cache-read-only
# `--paths`/`--deterministic` contracts, and the tolerant JSON extraction — with a STUBBED `claude`
# binary standing in for the one real model call the script ever makes. No real model call anywhere
# in this file (assert.sh's global `GOVERN_SCOUT=0` is deliberately overridden per-case with a stub).
#
# Renamed from test-scout-sizing.sh: the scout no longer scores a ticket into (model, effort) — see
# scout-ticket.sh's header for why (the `--score`/`--verdict` modes, the scoring table, and the HARD
# gate disjunction are gone). This file now tests what the scout is FOR: a cheap survey that measures
# scope, locates real paths, and flags purely mechanical tickets — never a difficulty verdict.
#
# Covered:
#   - the sanitize/clamp guard on every measurement field, including the new `deterministic`
#     sub-object and its closed-set `kind` clamp (both "unknown kind" and "kind ok, diff oversized")
#   - structurally-unusable input is REJECTED (no cache, rc 1), not silently defaulted
#   - `--paths` / `--deterministic`: present + absent, rc AND stdout, plus the defensive re-filter/
#     re-clamp a cache-read applies to a hand-seeded or stale cache
#   - the tolerant JSON extraction (govern::_json_objects) picks the real survey object out of a
#     chatty reply that ALSO contains a decoy top-level object and the survey's own nested
#     `deterministic` object — the bug the old `grep -o '{[^{}]*}' | tail -1` would have hit, since
#     that pattern matches the INNER (braceless-body) `deterministic` object and returns THAT instead
#   - `GOVERN_SCOUT=0` performs no model pass at all (the stub is never invoked)
#   - the `<N>` run mode's stdout-is-always-empty contract, across success/reject/disabled/not-found/
#     timeout
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
SCOUT="$DIR/../scout-ticket.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 77; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"
mkdir -p "$T/bin" "$T/run"

# ── helper: run the FULL `<N>` mode against a stubbed claude reply ─────────────────────────────
# Writes <reply> verbatim as the stub's stdout, a single matching ticket into tickets.md, clears any
# prior cache for THIS ticket number, then runs scout-ticket.sh <n>. Leaves SC_RC/SC_STDOUT/SC_STDERR
# and SC_CACHE (the would-be cache path) for the caller to assert on.
CLAUDE_CALLS="$T/claude-calls"
run_scout() { # <n> <reply-text>
  local n="$1" reply="$2"
  printf '%s' "$reply" > "$T/reply.txt"
  : > "$CLAUDE_CALLS"
  cat > "$T/bin/claude" <<EOF
#!/usr/bin/env bash
printf 'x' >> "$CLAUDE_CALLS"
cat "$T/reply.txt"
EOF
  chmod +x "$T/bin/claude"
  cat > "$T/tickets.md" <<EOF
## #$n — scout survey test ticket
**Severity:** Medium
Where: somewhere in the tree
---
EOF
  rm -rf "$T/run/ticket-$n"
  SC_CACHE="$T/run/ticket-$n/scout.json"
  SC_RC=0
  SC_STDOUT="$(GOVERN_SCOUT=1 GOVERN_TICKETS_FILE="$T/tickets.md" GOVERN_RUN_DIR="$T/run" \
    GOVERN_CLAUDE_BIN="$T/bin/claude" "$SCOUT" "$n" 2>"$T/stderr.txt")" || SC_RC=$?
  SC_STDERR="$(cat "$T/stderr.txt")"
}

scope() { jq -c '.scope' "$SC_CACHE"; }          # cached scope, compact
sf() { jq -r ".scope$1" "$SC_CACHE"; }           # field out of the cached scope (arg starts with '.')

# ══════════════════════════════════════════════════════════════════════════════════════════════
# ── the sanitize/clamp guard — every field, in one kitchen-sink malformed reply ──
# ══════════════════════════════════════════════════════════════════════════════════════════════
LONGCOMMIT="$(printf 'c%.0s' $(seq 1 250))"     # 250 chars, > the 200-char cap
LONGTESTCMD="$(printf 't%.0s' $(seq 1 450))"    # 450 chars, > the 400-char cap
LONGPATH="$(printf 'p%.0s' $(seq 1 401))"       # 401 chars, > the <400 path filter
LONGRATIONALE="$(printf 'r%.0s' $(seq 1 600))"  # 600 chars, > the 500-char cap

kitchen_sink=$(jq -nc --arg lc "$LONGCOMMIT" --arg lt "$LONGTESTCMD" --arg lp "$LONGPATH" --arg lr "$LONGRATIONALE" '{
  files: "lots", repos: -5, testsCover: "yes", precedent: "maybe",
  changeKind: "telepathy", fixDirection: "vibes",
  targetPaths: ["a.sh","b.sh","c.sh","d.sh","e.sh","f.sh","g.sh","h.sh","i.sh","",123,$lp],
  precedentCommit: $lc, testCommand: $lt,
  deterministic: {kind: "time-travel", rationale: $lr, diff: "short diff, but kind is bogus so it must not survive"}
}')
run_scout 101 "some prose before the object
$kitchen_sink"
assert_eq "$SC_RC" "0" "kitchen-sink reply: still survey-ably usable (fields clamp, not reject)"
assert_eq "$SC_STDOUT" "" "kitchen-sink reply: <N> mode prints nothing on stdout"
assert_eq "$(sf .files)" "0" "non-integer files clamps to 0 (absence of evidence, not the ceiling)"
assert_eq "$(sf .repos)" "0" "a negative (non-matching-regex) repos clamps to 0"
assert_eq "$(sf .testsCover)" "false" "non-boolean testsCover clamps to false"
assert_eq "$(sf .precedent)" "false" "non-boolean precedent clamps to false"
assert_eq "$(sf .changeKind)" "local" "unknown changeKind clamps to local (was structural pre-demotion)"
assert_eq "$(sf .fixDirection)" "vague" "unknown fixDirection clamps to vague"
assert_eq "$(sf '.targetPaths | length')" "8" "targetPaths caps at 8 AFTER filtering the empty/non-string/oversized entries"
assert_eq "$(sf '.targetPaths[0]')" "a.sh" "the first 8 valid paths survive, in order"
assert_eq "$(sf '.targetPaths[-1]')" "h.sh" "the 9th valid path (i.sh) is dropped by the 8-cap, not the filter"
assert_eq "$(sf '.precedentCommit | length')" "200" "precedentCommit truncates to 200 chars"
assert_eq "$(sf '.testCommand | length')" "400" "testCommand truncates to 400 chars"
assert_eq "$(sf '.deterministic.kind')" "" "deterministic.kind outside the closed set clamps to \"\" (not deterministic)"
assert_eq "$(sf '.deterministic.rationale | length')" "500" "deterministic.rationale truncates to 500 chars regardless of kind"
assert_eq "$(sf '.deterministic.diff')" "" "an unrecognized kind drops the diff too — a patch with no kind is meaningless"

# ── deterministic: a VALID kind with an oversized diff keeps the kind, drops only the diff ──
bigdiff="$(printf 'd%.0s' $(seq 1 20001))"      # 20001 chars, > the 20000-char cap
det_valid_kind_big_diff=$(jq -nc --arg d "$bigdiff" '{
  files: 2, repos: 1, testsCover: true, precedent: false, changeKind: "local", fixDirection: "concrete",
  deterministic: {kind: "version-bump", rationale: "bump the pinned version", diff: $d}
}')
run_scout 102 "$det_valid_kind_big_diff"
assert_eq "$(sf '.deterministic.kind')" "version-bump" \
  "a VALID kind survives even when the diff is oversized — the two clamps are independent"
assert_eq "$(sf '.deterministic.diff')" "" "an oversized diff (>20000 chars) is dropped even under a valid kind"
assert_eq "$(sf '.deterministic.rationale')" "bump the pinned version" "the rationale is untouched when short"

# ── deterministic: a valid kind with a small diff is kept VERBATIM ──
det_small=$(jq -nc '{
  files: 1, repos: 1, testsCover: true, precedent: true, changeKind: "local", fixDirection: "concrete",
  deterministic: {kind: "config-default", rationale: "flip the default", diff: "--- a/x\n+++ b/x\n-old\n+new\n"}
}')
run_scout 103 "$det_small"
assert_eq "$(sf '.deterministic.kind')" "config-default" "a closed-set kind is kept as-is"
assert_eq "$(sf '.deterministic.diff')" "$(printf -- '--- a/x\n+++ b/x\n-old\n+new\n')" \
  "a small diff under a valid kind is kept VERBATIM (byte-exact, incl. newlines)"

# ══════════════════════════════════════════════════════════════════════════════════════════════
# ── structurally-unusable input is REJECTED, not silently defaulted ──
# ══════════════════════════════════════════════════════════════════════════════════════════════
run_scout 110 "not json at all, just prose the model wrote instead of the requested object"
assert_eq "$SC_RC" "1" "no JSON object anywhere in the reply -> rc 1"
assert_eq "$SC_STDOUT" "" "<N> mode prints nothing on stdout even on rejection"
[[ ! -e "$SC_CACHE" ]] && printf 'ok   - %s\n' "no JSON in the reply -> nothing is cached" \
  || { printf 'FAIL - %s\n' "no JSON in the reply -> nothing is cached"; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
assert_contains "$SC_STDERR" "no survey JSON object found" "the rejection reason is logged loudly on stderr"

missing_key='{"files":1,"repos":1,"testsCover":true,"precedent":true,"changeKind":"local"}'
run_scout 111 "$missing_key"
assert_eq "$SC_RC" "1" "a candidate object missing a required key (fixDirection) -> rc 1, not defaulted"
[[ ! -e "$SC_CACHE" ]] && printf 'ok   - %s\n' "a missing-key candidate is never cached" \
  || { printf 'FAIL - %s\n' "a missing-key candidate is never cached"; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
assert_contains "$SC_STDERR" "REJECTED" "the guard rejection is logged loudly, not swallowed"
assert_contains "$SC_STDERR" "missing required keys" "the rejection names WHY (missing keys), not just that it failed"

run_scout 112 "$(jq -nc '{"note":"just a decoy object, no files key at all"}')"
assert_eq "$SC_RC" "1" "an object with no 'files' key is never even a CANDIDATE (extraction, not sanitize)"
[[ ! -e "$SC_CACHE" ]] && printf 'ok   - %s\n' "a files-less object is never cached" \
  || { printf 'FAIL - %s\n' "a files-less object is never cached"; ASSERT_FAILS=$((ASSERT_FAILS+1)); }

# ── ticket not found -> rejected before any model call is even attempted ──
: > "$CLAUDE_CALLS"
cat > "$T/bin/claude" <<EOF
#!/usr/bin/env bash
printf 'x' >> "$CLAUDE_CALLS"
echo unused
EOF
chmod +x "$T/bin/claude"
printf '# empty tickets file, #999 does not exist\n' > "$T/tickets.md"
rm -rf "$T/run/ticket-999"
rc=0
out="$(GOVERN_SCOUT=1 GOVERN_TICKETS_FILE="$T/tickets.md" GOVERN_RUN_DIR="$T/run" \
  GOVERN_CLAUDE_BIN="$T/bin/claude" "$SCOUT" 999 2>"$T/stderr.txt")" || rc=$?
assert_eq "$rc" "1" "ticket not found in tickets.md -> rc 1"
assert_eq "$out" "" "<N> mode prints nothing on stdout when the ticket isn't found"
assert_eq "$(cat "$CLAUDE_CALLS")" "" "no ticket block -> the model is never even invoked"

# ── a claude pass that runs past GOVERN_SCOUT_TIMEOUT is rejected, not left to hang ──
cat > "$T/bin/claude-slow" <<'EOF'
#!/usr/bin/env bash
sleep 5
echo '{"files":1,"repos":1,"testsCover":true,"precedent":true,"changeKind":"local","fixDirection":"concrete"}'
EOF
chmod +x "$T/bin/claude-slow"
cat > "$T/tickets.md" <<'EOF'
## #113 — a ticket whose scout pass hangs
**Severity:** Medium
Where: somewhere
---
EOF
rm -rf "$T/run/ticket-113"
rc=0
out="$(GOVERN_SCOUT=1 GOVERN_SCOUT_TIMEOUT=1 GOVERN_TICKETS_FILE="$T/tickets.md" GOVERN_RUN_DIR="$T/run" \
  GOVERN_CLAUDE_BIN="$T/bin/claude-slow" "$SCOUT" 113 2>"$T/stderr.txt")" || rc=$?
assert_eq "$rc" "1" "a scout pass that outlives GOVERN_SCOUT_TIMEOUT -> rc 1, no survey cached"
assert_eq "$out" "" "<N> mode prints nothing on stdout on a timeout either"
[[ ! -e "$T/run/ticket-113/scout.json" ]] && printf 'ok   - %s\n' "a timed-out pass caches nothing" \
  || { printf 'FAIL - %s\n' "a timed-out pass caches nothing"; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
assert_contains "$(cat "$T/stderr.txt")" "TIMED OUT" "the timeout is logged loudly"

# ══════════════════════════════════════════════════════════════════════════════════════════════
# ── the tolerant JSON extraction: decoy object + nested `deterministic` object ──
# The OLD `grep -o '{[^{}]*}' | tail -1` cannot survive a nested `deterministic` object: it would
# match the LAST brace-balanced-with-no-inner-braces span, which is the INNER `deterministic`
# object, and hand that back as "the survey" — a survey with no `files` key. The real extractor
# (govern::_json_objects) only ever emits TOP-LEVEL objects, so the nested object is never even a
# candidate, and the decoy (a real top-level object, but lacking `files`) is skipped in favor of the
# real survey.
# ══════════════════════════════════════════════════════════════════════════════════════════════
chatty="Let me survey the ticket first.
I'll grep around and report back.
Decoy note (NOT the survey — no files key): {\"status\":\"thinking\",\"progress\":\"halfway\"}
Here is my measurement, as requested:
{\"files\":2,\"repos\":1,\"testsCover\":true,\"precedent\":false,\"changeKind\":\"local\",\"fixDirection\":\"concrete\",\"targetPaths\":[\"src/x.sh\"],\"precedentCommit\":\"\",\"testCommand\":\"\",\"deterministic\":{\"kind\":\"add-key\",\"rationale\":\"add the missing config key\",\"diff\":\"\"}}
Let me know if that looks right."
run_scout 120 "$chatty"
assert_eq "$SC_RC" "0" "a chatty reply with a decoy object + nested deterministic object still surveys successfully"
assert_eq "$(sf .files)" "2" "the REAL survey object (has files) is picked, not the decoy"
assert_eq "$(sf '.targetPaths[0]')" "src/x.sh" "targetPaths comes from the real object"
assert_eq "$(sf '.deterministic.kind')" "add-key" \
  "the nested deterministic object stays NESTED — the scanner never returns it as its own candidate"

# ══════════════════════════════════════════════════════════════════════════════════════════════
# ── GOVERN_SCOUT=0 performs NO model pass at all ──
# ══════════════════════════════════════════════════════════════════════════════════════════════
: > "$CLAUDE_CALLS"
cat > "$T/bin/claude" <<EOF
#!/usr/bin/env bash
printf 'x' >> "$CLAUDE_CALLS"
echo '{"files":1,"repos":1,"testsCover":true,"precedent":true,"changeKind":"local","fixDirection":"concrete"}'
EOF
chmod +x "$T/bin/claude"
cat > "$T/tickets.md" <<'EOF'
## #130 — a ticket the scout must never touch when disabled
**Severity:** Medium
Where: somewhere
---
EOF
rm -rf "$T/run/ticket-130"
rc=0
out="$(GOVERN_SCOUT=0 GOVERN_TICKETS_FILE="$T/tickets.md" GOVERN_RUN_DIR="$T/run" \
  GOVERN_CLAUDE_BIN="$T/bin/claude" "$SCOUT" 130 2>"$T/stderr.txt")" || rc=$?
assert_eq "$rc" "1" "GOVERN_SCOUT=0 exits 1"
assert_eq "$out" "" "GOVERN_SCOUT=0 -> <N> mode still prints nothing on stdout"
assert_eq "$(cat "$CLAUDE_CALLS")" "" "GOVERN_SCOUT=0 -> the claude stub is never invoked"
[[ ! -e "$T/run/ticket-130/scout.json" ]] && printf 'ok   - %s\n' "GOVERN_SCOUT=0 -> nothing is cached" \
  || { printf 'FAIL - %s\n' "GOVERN_SCOUT=0 -> nothing is cached"; ASSERT_FAILS=$((ASSERT_FAILS+1)); }
assert_contains "$(cat "$T/stderr.txt")" "disabled" "the disabled state is logged"

# ══════════════════════════════════════════════════════════════════════════════════════════════
# ── --paths: cache-READ only, no model call ──
# ══════════════════════════════════════════════════════════════════════════════════════════════
export GOVERN_RUN_DIR="$T/run2"
mkdir -p "$GOVERN_RUN_DIR/ticket-7"

with_paths=$(jq -nc '{files:2,repos:1,testsCover:true,precedent:false,changeKind:"local",fixDirection:"concrete",
  targetPaths:["a/one.sh","b/two.sh"],precedentCommit:"",testCommand:"",deterministic:{kind:"",rationale:"",diff:""}}')
jq -nc --argjson s "$with_paths" '{ticket:7,scope:$s,scoutModel:"haiku",ts:1}' > "$GOVERN_RUN_DIR/ticket-7/scout.json"
rc=0; out="$("$SCOUT" --paths 7)" || rc=$?
assert_eq "$rc" "0" "--paths with targetPaths present -> rc 0"
assert_eq "$out" "$(printf 'a/one.sh\nb/two.sh')" "--paths prints one verified path per line"

no_paths=$(jq -nc '{files:2,repos:1,testsCover:true,precedent:false,changeKind:"local",fixDirection:"concrete",
  targetPaths:[],precedentCommit:"",testCommand:"",deterministic:{kind:"",rationale:"",diff:""}}')
jq -nc --argjson s "$no_paths" '{ticket:7,scope:$s,scoutModel:"haiku",ts:1}' > "$GOVERN_RUN_DIR/ticket-7/scout.json"
rc=0; out="$("$SCOUT" --paths 7)" || rc=$?
assert_eq "$rc" "1" "--paths with an empty targetPaths -> rc 1"
assert_eq "$out" "" "--paths prints nothing when there are none"

rc=0; out="$("$SCOUT" --paths 8)" || rc=$?
assert_eq "$rc" "1" "--paths with NO cache at all -> rc 1"
assert_eq "$out" "" "--paths prints nothing when there is no cache"

# Defensive re-filter: a hand-seeded / stale cache carrying MORE than 8 paths is still capped on read.
manypaths=$(jq -nc '[range(0;12)|"path\(.)/f.sh"]')
hand_edited=$(jq -nc --argjson p "$manypaths" '{files:2,repos:1,testsCover:true,precedent:false,changeKind:"local",fixDirection:"concrete",
  targetPaths:$p,precedentCommit:"",testCommand:"",deterministic:{kind:"",rationale:"",diff:""}}')
jq -nc --argjson s "$hand_edited" '{ticket:7,scope:$s,scoutModel:"haiku",ts:1}' > "$GOVERN_RUN_DIR/ticket-7/scout.json"
rc=0; out="$("$SCOUT" --paths 7)" || rc=$?
assert_eq "$rc" "0" "a hand-edited cache with 12 paths still reads -> rc 0"
assert_eq "$(wc -l <<<"$out" | tr -d ' ')" "8" "--paths re-caps at 8 on READ, even for a hand-seeded cache"

# ══════════════════════════════════════════════════════════════════════════════════════════════
# ── --deterministic: cache-READ only, no model call ──
# ══════════════════════════════════════════════════════════════════════════════════════════════
with_det=$(jq -nc '{files:1,repos:1,testsCover:true,precedent:true,changeKind:"local",fixDirection:"concrete",
  targetPaths:[],precedentCommit:"",testCommand:"",
  deterministic:{kind:"known-rename",rationale:"rename per the ticket",diff:"--- a/f\n+++ b/f\n"}}')
jq -nc --argjson s "$with_det" '{ticket:7,scope:$s,scoutModel:"haiku",ts:1}' > "$GOVERN_RUN_DIR/ticket-7/scout.json"
rc=0; out="$("$SCOUT" --deterministic 7)" || rc=$?
assert_eq "$rc" "0" "--deterministic with a non-empty kind -> rc 0"
assert_eq "$(printf '%s' "$out" | jq -r '.kind')" "known-rename" "--deterministic prints the cached kind"
assert_eq "$(printf '%s' "$out" | jq -r '.rationale')" "rename per the ticket" "--deterministic prints the rationale"
assert_eq "$(printf '%s' "$out" | jq -r '.diff')" "$(printf -- '--- a/f\n+++ b/f\n')" "--deterministic prints the diff verbatim"
assert_eq "$(wc -l <<<"$out" | tr -d ' ')" "1" "--deterministic prints the object as ONE line"

no_det=$(jq -nc '{files:1,repos:1,testsCover:true,precedent:true,changeKind:"local",fixDirection:"concrete",
  targetPaths:[],precedentCommit:"",testCommand:"",deterministic:{kind:"",rationale:"",diff:""}}')
jq -nc --argjson s "$no_det" '{ticket:7,scope:$s,scoutModel:"haiku",ts:1}' > "$GOVERN_RUN_DIR/ticket-7/scout.json"
rc=0; out="$("$SCOUT" --deterministic 7)" || rc=$?
assert_eq "$rc" "1" "--deterministic with an empty kind -> rc 1 (not deterministic)"
assert_eq "$out" "" "--deterministic prints nothing when kind is empty"

rc=0; out="$("$SCOUT" --deterministic 9)" || rc=$?
assert_eq "$rc" "1" "--deterministic with NO cache at all -> rc 1"
assert_eq "$out" "" "--deterministic prints nothing when there is no cache"

# Re-clamp on read: a hand-edited cache carrying an unrecognized kind is rejected, not trusted.
bogus_kind=$(jq -nc '{files:1,repos:1,testsCover:true,precedent:true,changeKind:"local",fixDirection:"concrete",
  targetPaths:[],precedentCommit:"",testCommand:"",deterministic:{kind:"mind-reading",rationale:"nope",diff:""}}')
jq -nc --argjson s "$bogus_kind" '{ticket:7,scope:$s,scoutModel:"haiku",ts:1}' > "$GOVERN_RUN_DIR/ticket-7/scout.json"
rc=0; out="$("$SCOUT" --deterministic 7 2>"$T/stderr.txt")" || rc=$?
assert_eq "$rc" "1" "a hand-edited cache with an out-of-set kind is rejected on READ, not trusted"
assert_eq "$out" "" "--deterministic prints nothing for a re-clamped-to-empty kind"
assert_contains "$(cat "$T/stderr.txt")" "CLAMPED" "the read-time re-clamp is logged loudly"

# Re-drop on read: a hand-edited cache carrying a valid kind but an oversized diff drops the diff.
bigdiff2="$(printf 'e%.0s' $(seq 1 20001))"
big_diff_cache=$(jq -nc --arg d "$bigdiff2" '{files:1,repos:1,testsCover:true,precedent:true,changeKind:"local",fixDirection:"concrete",
  targetPaths:[],precedentCommit:"",testCommand:"",deterministic:{kind:"dead-line-delete",rationale:"drop the stale line",diff:$d}}')
jq -nc --argjson s "$big_diff_cache" '{ticket:7,scope:$s,scoutModel:"haiku",ts:1}' > "$GOVERN_RUN_DIR/ticket-7/scout.json"
rc=0; out="$("$SCOUT" --deterministic 7)" || rc=$?
assert_eq "$rc" "0" "a hand-edited cache with a valid kind but oversized diff still reads -> rc 0"
assert_eq "$(printf '%s' "$out" | jq -r '.kind')" "dead-line-delete" "the valid kind still comes through"
assert_eq "$(printf '%s' "$out" | jq -r '.diff')" "" "the oversized diff is dropped on READ too"

# ── cache hit: a second dispatch inside the same run REUSES the survey, no second model call ──
run_scout 140 '{"files":1,"repos":1,"testsCover":true,"precedent":true,"changeKind":"local","fixDirection":"concrete"}'
assert_eq "$SC_RC" "0" "first dispatch surveys and caches"
firstcalls="$(cat "$CLAUDE_CALLS")"
rc=0
out2="$(GOVERN_SCOUT=1 GOVERN_TICKETS_FILE="$T/tickets.md" GOVERN_RUN_DIR="$T/run" \
  GOVERN_CLAUDE_BIN="$T/bin/claude" "$SCOUT" 140 2>"$T/stderr.txt")" || rc=$?
assert_eq "$rc" "0" "a second dispatch of the same ticket, same run -> cache hit, rc 0"
assert_eq "$out2" "" "a cache-hit dispatch still prints nothing on stdout"
assert_eq "$(cat "$CLAUDE_CALLS")" "$firstcalls" "a cache hit issues NO additional model call"
assert_contains "$(cat "$T/stderr.txt")" "cache hit" "the cache hit is logged"

assert_done
