#!/usr/bin/env bash
# Proves scout-ticket.sh's SIZING half is deterministic, auditable and fail-safe — with no model call
# anywhere in this file. The scout's model pass only ever produces a scope JSON; `--score` turns that
# JSON into (model, effort, scopeClass) in pure bash, which is exactly the seam under test here.
#
# Covered:
#   - the three rows of the scoring table
#   - every HARD disqualifier in isolation (cross-repo / structural / no test / vague)
#   - the fail-safe guard: structurally invalid input is REJECTED (rc 2, caller falls back), while an
#     out-of-domain FIELD is CLAMPED to the hard end — clamping is one-directional, so a malformed
#     scout can never silently downgrade a hard ticket to haiku
#   - `--verdict` re-scores the cached scope (rather than trusting a stored verdict), and reports
#     "no usable cache" as rc 1 so spawn-worker falls back instead of guessing
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
SCOUT="$DIR/../scout-ticket.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 77; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"

# score <json> -> "model effort class" on success; "rc=<n>" on a guard rejection.
score() {
  local out rc=0
  out="$(printf '%s' "$1" | "$SCOUT" --score - 2>/dev/null)" || rc=$?
  if [[ "$rc" -ne 0 ]]; then printf 'rc=%s' "$rc"; else printf '%s' "$out" | tr '\t' ' '; fi
}

# A ticket that is easy on EVERY axis. Each case below flips exactly one field, so a failure names
# the disqualifier that broke rather than "some combination".
easy='{"files":1,"repos":1,"testsCover":true,"precedent":true,"changeKind":"local","fixDirection":"concrete"}'

# ── the scoring table ──
assert_eq "$(score "$easy")" "haiku low trivial" \
  "1 file, local, precedent + test exist -> haiku/low"

assert_eq "$(score '{"files":4,"repos":1,"testsCover":true,"precedent":false,"changeKind":"local","fixDirection":"concrete"}')" \
  "sonnet medium small" "<=5 files, 1 repo, concrete, but NO precedent -> sonnet/medium"

assert_eq "$(score '{"files":1,"repos":1,"testsCover":true,"precedent":false,"changeKind":"local","fixDirection":"concrete"}')" \
  "sonnet medium small" "1 file but no precedent is NOT trivial — precedent is what makes it haiku"

assert_eq "$(score '{"files":6,"repos":1,"testsCover":true,"precedent":true,"changeKind":"local","fixDirection":"concrete"}')" \
  "opus high hard" "6 files exceeds the small band -> falls through to opus/high"

# ── each HARD disqualifier, in isolation ──
assert_eq "$(score '{"files":1,"repos":2,"testsCover":true,"precedent":true,"changeKind":"local","fixDirection":"concrete"}')" \
  "opus high hard" "cross-repo alone forces opus/high"

assert_eq "$(score '{"files":1,"repos":1,"testsCover":true,"precedent":true,"changeKind":"structural","fixDirection":"concrete"}')" \
  "opus high hard" "a structural (contract/schema) change alone forces opus/high"

assert_eq "$(score '{"files":1,"repos":1,"testsCover":false,"precedent":true,"changeKind":"local","fixDirection":"concrete"}')" \
  "opus high hard" "no test coverage on the touched area alone forces opus/high"

assert_eq "$(score '{"files":1,"repos":1,"testsCover":true,"precedent":true,"changeKind":"local","fixDirection":"vague"}')" \
  "opus high hard" "a vague fix direction alone forces opus/high"

assert_eq "$(score '{"files":0,"repos":1,"testsCover":true,"precedent":true,"changeKind":"local","fixDirection":"concrete"}')" \
  "opus high hard" "files=0 means the scout located nothing — that is not a measurement, so opus/high"

# ── the guard: REJECT structurally invalid input (caller falls back to GOVERN_WORKER_MODEL) ──
assert_eq "$(score 'not json at all')"  "rc=2" "non-JSON scout output is rejected, not scored"
assert_eq "$(score '[1,2,3]')"          "rc=2" "a JSON array (not an object) is rejected"
assert_eq "$(score '{}')"               "rc=2" "an empty object is rejected — every key must be present"
assert_eq "$(score '{"files":1,"repos":1,"testsCover":true,"precedent":true,"changeKind":"local"}')" \
  "rc=2" "a MISSING key is rejected rather than silently defaulted"

# ── the guard: CLAMP an out-of-domain field to the HARD end (never downward) ──
assert_eq "$(score '{"files":1,"repos":1,"testsCover":true,"precedent":true,"changeKind":"telepathy","fixDirection":"concrete"}')" \
  "opus high hard" "an unknown changeKind enum clamps to structural -> opus/high"

assert_eq "$(score '{"files":1,"repos":1,"testsCover":true,"precedent":true,"changeKind":"local","fixDirection":"vibes"}')" \
  "opus high hard" "an unknown fixDirection enum clamps to vague -> opus/high"

assert_eq "$(score '{"files":1,"repos":1,"testsCover":"yes","precedent":true,"changeKind":"local","fixDirection":"concrete"}')" \
  "opus high hard" "a non-boolean testsCover clamps to false -> opus/high"

assert_eq "$(score '{"files":1,"repos":1,"testsCover":true,"precedent":"maybe","changeKind":"local","fixDirection":"concrete"}')" \
  "sonnet medium small" "a non-boolean precedent clamps to false — drops trivial to small, never below"

assert_eq "$(score '{"files":"lots","repos":1,"testsCover":true,"precedent":true,"changeKind":"local","fixDirection":"concrete"}')" \
  "opus high hard" "a non-integer files clamps to the ceiling -> opus/high"

assert_eq "$(score '{"files":100000,"repos":1,"testsCover":true,"precedent":true,"changeKind":"local","fixDirection":"concrete"}')" \
  "opus high hard" "an absurd files count clamps to the ceiling -> opus/high"

assert_eq "$(score '{"files":1,"repos":-3,"testsCover":true,"precedent":true,"changeKind":"local","fixDirection":"concrete"}')" \
  "opus high hard" "a negative repos count clamps to the ceiling -> opus/high"

# ── --verdict reads the run-scoped cache and RE-SCORES it (no model call, no stored-verdict trust) ──
export GOVERN_RUN_DIR="$T/run"
mkdir -p "$GOVERN_RUN_DIR/ticket-7"

vrc=0; "$SCOUT" --verdict 7 >/dev/null 2>&1 || vrc=$?
assert_eq "$vrc" "1" "--verdict with NO cache exits 1 so spawn-worker falls back instead of guessing"

# The stored verdict deliberately DISAGREES with the scope: the scope is the source of truth, so a
# hand-edited (or stale-table) verdict field cannot smuggle a cheaper tier past the guard.
cat > "$GOVERN_RUN_DIR/ticket-7/scout.json" <<EOF
{"ticket":7,"scope":$easy,"verdict":{"model":"opus","effort":"max","scopeClass":"hard"},"scoutModel":"haiku","ts":1}
EOF
assert_eq "$("$SCOUT" --verdict 7 2>/dev/null | tr '\t' ' ')" "haiku low trivial" \
  "--verdict re-scores the cached SCOPE, ignoring the stored verdict field"

# A cache whose scope fails the guard must produce NO verdict (so the caller falls back) AND say so
# on stderr — "safely and loudly" is one requirement, not two. spawn-worker deliberately leaves this
# stderr unsuppressed, so the reason lands in the run log.
cat > "$GOVERN_RUN_DIR/ticket-7/scout.json" <<'EOF'
{"ticket":7,"scope":{"files":1},"verdict":{"model":"haiku","effort":"low","scopeClass":"trivial"},"ts":1}
EOF
vrc=0; verr="$("$SCOUT" --verdict 7 2>&1 >/dev/null)" || vrc=$?
assert_eq "$vrc" "1" "a cache whose scope fails the guard yields no verdict — no silent downgrade to haiku"
assert_contains "$verr" "REJECTED" "the guard rejection is logged loudly rather than swallowed"

cat > "$GOVERN_RUN_DIR/ticket-7/scout.json" <<'EOF'
{"ticket":7,"verdict":{"model":"haiku","effort":"low","scopeClass":"trivial"},"ts":1}
EOF
vrc=0; "$SCOUT" --verdict 7 >/dev/null 2>&1 || vrc=$?
assert_eq "$vrc" "1" "a cache with NO scope object is treated as no cache at all"

# ── GOVERN_SCOUT=0 disables the model pass entirely (dispatch reverts to pre-scout behavior) ──
drc=0; GOVERN_SCOUT=0 "$SCOUT" 7 >/dev/null 2>&1 || drc=$?
assert_eq "$drc" "1" "GOVERN_SCOUT=0 exits 1 without running any scout pass"

# ── PRECEDENCE, end to end through spawn-worker's dry-run seam ──────────────────────────────────
# The scout must replace the blanket GOVERN_WORKER_MODEL default WITHOUT ever outranking the brain.
# GOVERN_SPAWN_DRY_RUN=1 resolves sizing exactly as the live spawn would and prints it as JSON —
# and because the cache is pre-seeded here, `--verdict` reads it and no model is ever invoked.
SPAWN="$DIR/../spawn-worker.sh"
mkdir -p "$T/governor" "$T/wt"
cat > "$T/tickets.md" <<'EOF'
## #201 — unsized ticket: the scout decides both axes
**Severity:** Medium
Observed: no Model / no Effort field — this is the case that used to default to opus.

---

## #202 — the brain stamped BOTH axes
**Severity:** Medium
**Model:** opus
**Effort:** max
Observed: an explicit operator decision that the scout must not touch.

---

## #203 — the brain stamped only Model
**Severity:** Medium
**Model:** opus
Observed: Model is claimed; Effort is still the scout's to decide.
EOF
: > "$T/escalations.md"

# One shared "trivial" measurement, so any difference below comes from precedence alone.
for tn in 201 202 203; do
  mkdir -p "$GOVERN_RUN_DIR/ticket-$tn"
  cat > "$GOVERN_RUN_DIR/ticket-$tn/scout.json" <<EOF
{"ticket":$tn,"scope":$easy,"verdict":{"model":"haiku","effort":"low","scopeClass":"trivial"},"ts":1}
EOF
done

dry() { # <ticket> <jq-filter>
  GOVERN_SCOUT=1 GOVERN_SPAWN_DRY_RUN=1 GOVERN_WORKER_MODEL=opus \
  GOVERN_TICKETS_FILE="$T/tickets.md" GOVERN_ESCALATIONS_FILE="$T/escalations.md" \
    "$SPAWN" "$1" 2>/dev/null | jq -r "$2"
}

assert_eq "$(dry 201 '.model + " " + .effort + " " + .scope_class')" "haiku low trivial" \
  "an UNSIZED ticket takes the scout's measured tier instead of the blanket opus default"
assert_contains "$(dry 201 '.model_source')" "scout" "the log/ledger names the scout as the source"
assert_contains "$(dry 201 '.model_source')" "trivial" "and records the measured scope class"

assert_eq "$(dry 202 '.model + " " + .effort')" "opus max" \
  "an explicit ticket Model: AND Effort: both WIN over the scout"
assert_eq "$(dry 202 '.model_source')" "ticket-Model-field" \
  "the brain stays the recorded source for the axis it claimed"
assert_eq "$(dry 202 '.scope_class')" "trivial" \
  "the measured scope is still recorded even when the brain overrode it"

assert_eq "$(dry 203 '.model + " " + .effort')" "opus low" \
  "a ticket that stamps only Model: keeps opus, and the scout decides the unclaimed Effort axis"

# With the scout off, #201 must resolve EXACTLY as it did before this feature existed.
assert_eq "$(GOVERN_SCOUT=0 GOVERN_SPAWN_DRY_RUN=1 GOVERN_WORKER_MODEL=opus \
  GOVERN_TICKETS_FILE="$T/tickets.md" GOVERN_ESCALATIONS_FILE="$T/escalations.md" \
  "$SPAWN" 201 2>/dev/null | jq -r '.model + " " + .model_source')" "opus GOVERN_WORKER_MODEL" \
  "GOVERN_SCOUT=0 restores the pre-scout dispatch behavior byte for byte"

assert_done
