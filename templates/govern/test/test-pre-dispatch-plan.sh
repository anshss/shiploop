#!/usr/bin/env bash
# pre-dispatch-check.sh PLAN mode: a batch
# is `12,14` (one worker), space-separates parallel batches. Every existing single-ticket gate
# still runs once per named member (covered by test-pre-dispatch-check.sh, unchanged by this file);
# this file covers the mechanical composition checks and the single-ticket/plan mode boundary.
#
#   1. a single bare <N> (no comma, one arg) is untouched: exactly the legacy one-line verdict.
#   2. a single comma-arg ("12,14") is PLAN mode even though $# == 1.
#   3. dependency inside a batch, either direction: the dependent is dropped, the blocker proceeds.
#   4. sub-repo mismatch: a later member whose measured path resolves to a DIFFERENT sub-repo than
#      the batch's anchor is dropped.
#   5. size: a batch over GOVERN_GROUP_MAX drops the trailing overflow.
#   6. an "unrelated" batch (no measured path shared by any pair) requires stated precision naming
#      1-2 files; a member that doesn't qualify is dropped, one that does proceeds.
#   7. the final `plan:` line names exactly what survived every check, per batch.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

PDC="$DIR/../pre-dispatch-check.sh"
[[ -f "$PDC" ]] || { echo "SKIP: pre-dispatch-check.sh not found"; exit 77; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T" "alpha"   # REPOS = (alpha web)
mkdir -p "$T/queue"
export GOVERN_QUEUE_DIR="$T/queue"
export GOVERN_MIN_FREE_GB=0   # this file's own disk-space gate is covered by test-pre-dispatch-check.sh
( cd "$T" && git init -q && git config user.email t@t && git config user.name t )

cat > "$T/queue/tickets.md" <<'TIX'
# Tickets

## #10 — a plain single ticket

**Severity:** Low

**Proposed solution:** do the thing.

Done when: done.

---

## #20 — depends on #21, same batch

**Severity:** Low

**Depends on:** #21

**Proposed solution:** do the thing.

Done when: done.

---

## #21 — the blocker #20 depends on

**Severity:** Low

**Proposed solution:** do the thing.

Done when: done.

---

## #30 — alpha: touches alpha only

**Severity:** Low

**Files:** alpha/a.go

**Proposed solution:** do the thing.

Done when: done.

---

## #31 — web: touches web only

**Severity:** Low

**Files:** web/b.ts

**Proposed solution:** do the thing.

Done when: done.

---

## #50 — shared file, member 1

**Severity:** Low

**Files:** alpha/shared.go

**Proposed solution:** do the thing.

Done when: done.

---

## #51 — shared file, member 2

**Severity:** Low

**Files:** alpha/shared.go

**Proposed solution:** do the thing.

Done when: done.

---

## #52 — shared file, member 3

**Severity:** Low

**Files:** alpha/shared.go

**Proposed solution:** do the thing.

Done when: done.

---

## #53 — shared file, member 4

**Severity:** Low

**Files:** alpha/shared.go

**Proposed solution:** do the thing.

Done when: done.

---

## #54 — shared file, member 5

**Severity:** Low

**Files:** alpha/shared.go

**Proposed solution:** do the thing.

Done when: done.

---

## #55 — shared file, member 6

**Severity:** Low

**Files:** alpha/shared.go

**Proposed solution:** do the thing.

Done when: done.

---

## #56 — shared file, member 7 (over the default cap)

**Severity:** Low

**Files:** alpha/shared.go

**Proposed solution:** do the thing.

Done when: done.

---

## #40 — unrelated tiny batch, stated + 1 file (qualifies)

**Severity:** Low

**Files:** alpha/a.go

**Proposed solution:** do the thing.

**Precision:** stated

Done when: done.

---

## #41 — unrelated tiny batch, open precision (does not qualify)

**Severity:** Low

**Files:** alpha/c.go

**Proposed solution:** do the thing.

**Precision:** open

Done when: done.
TIX
( cd "$T" && git add -A && git commit -qm init )

run_pdc() { ( cd "$T" && bash "$PDC" "$@" 2>/dev/null ); }

# ══════════════════════════════════════════════════════════════════════════════════════════════
# 1. a single bare <N> is untouched: exactly the legacy verdict, one line
# ══════════════════════════════════════════════════════════════════════════════════════════════
out1="$(run_pdc 10)"
assert_eq "$out1" "proceed" "1. a single bare <N> still verdicts exactly 'proceed'"
assert_eq "$(printf '%s\n' "$out1" | grep -c .)" "1" "1. ...and is exactly one line, no plan wrapper"

# ══════════════════════════════════════════════════════════════════════════════════════════════
# 2. a single comma-arg is PLAN mode even though $# == 1
# ══════════════════════════════════════════════════════════════════════════════════════════════
out2="$(run_pdc 20,21)"
assert_contains "$out2" "plan:" "2. a single arg WITH a comma engages plan mode"

# ══════════════════════════════════════════════════════════════════════════════════════════════
# 3. dependency inside a batch, either direction: the dependent never reaches the batch composition
# check at all here -- gate 4 (existing, unconditional) already skips a ticket whose declared
# dependency still has a live block in tickets.md, batched or not, so #20 is skipped BEFORE the
# composition check would even run. The end state the plan check wants (the dependent never
# proceeds alongside its blocker) holds either way; _pdc_check_deps is the defense-in-depth path
# for a dependency gate 4 does not already cover.
# ══════════════════════════════════════════════════════════════════════════════════════════════
out3="$(run_pdc 20,21)"
assert_contains "$out3" "#20: skip: depends on unresolved #21" "3. #20 is skipped by the existing depends-on gate (unmet, still in tickets.md)"
assert_contains "$out3" "#21: proceed" "3. #21's own gate verdicts proceed"
assert_contains "$out3" "plan: 21" "3. the final plan keeps only #21 -- the dependent never rides along"

# ══════════════════════════════════════════════════════════════════════════════════════════════
# 4. sub-repo mismatch: the later member (different repo than the anchor) is dropped
# ══════════════════════════════════════════════════════════════════════════════════════════════
out4="$(run_pdc 30,31)"
assert_contains "$out4" "#31: dropped from batch 1" "4. #31 (web) is dropped -- differs from the batch's anchor repo (alpha)"
assert_contains "$out4" "sub-repo" "4. ...and the reason names the sub-repo mismatch"
assert_contains "$out4" "plan: 30" "4. the final plan keeps only #30"

# ══════════════════════════════════════════════════════════════════════════════════════════════
# 5. size: a batch over GOVERN_GROUP_MAX drops the trailing overflow
# ══════════════════════════════════════════════════════════════════════════════════════════════
out5="$(run_pdc 50,51,52,53,54,55,56)"
assert_contains "$out5" "#56: dropped from batch 1" "5. the 7th member (over the default cap of 6) is dropped"
assert_contains "$out5" "GOVERN_GROUP_MAX" "5. ...and the reason names the size cap"
assert_contains "$out5" "plan: 50,51,52,53,54,55" "5. the final plan keeps exactly the first 6"

out5b="$(GOVERN_GROUP_MAX=3 run_pdc 50,51,52,53,54,55,56)"
assert_contains "$out5b" "plan: 50,51,52" "5b. GOVERN_GROUP_MAX is honored when overridden"

# ══════════════════════════════════════════════════════════════════════════════════════════════
# 6. an unrelated batch (no shared measured path) needs stated precision naming 1-2 files
# ══════════════════════════════════════════════════════════════════════════════════════════════
out6="$(run_pdc 40,41)"
assert_contains "$out6" "#41: dropped from batch 1" "6. #41 (open precision) does not qualify for the unrelated-batch rule"
assert_contains "$out6" "stated precision" "6. ...and the reason names the stated-precision requirement"
assert_contains "$out6" "plan: 40" "6. #40 (stated, 1 file) survives alone"

# A batch that DOES share a measured path is never subject to the stated-precision rule, even
# with an open-precision member: reuse #30 (alpha/a.go) alongside a second alpha/a.go ticket.
cat >> "$T/queue/tickets.md" <<'TIX2'

---

## #42 — shares #30's exact path, open precision

**Severity:** Low

**Files:** alpha/a.go

**Proposed solution:** do the thing.

**Precision:** open

Done when: done.
TIX2
( cd "$T" && git add -A && git commit -qm "add #42" )
out6b="$(run_pdc 30,42)"
assert_contains "$out6b" "plan: 30,42" "6b. a batch sharing a measured path is exempt from the unrelated-batch rule"

# ══════════════════════════════════════════════════════════════════════════════════════════════
# 7. parallel batches: the final plan line reflects each batch independently
# ══════════════════════════════════════════════════════════════════════════════════════════════
out7="$(run_pdc 10 20,21)"
assert_contains "$out7" "batch 1: proceed 10" "7. batch 1 (a lone ticket) proceeds"
assert_contains "$out7" "batch 2: proceed 21" "7. batch 2 keeps only its surviving member"
assert_contains "$out7" "plan: 10|21" "7. the final plan line is pipe-joined per batch, in order"

assert_done
