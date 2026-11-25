#!/usr/bin/env bash
# pre-dispatch-check.sh — the resolved-skip branch and the merged-PR mirror probe (ticket #234).
#
# The resolved-skip used to bare-skip ANY block gone from origin/main as "resolved+pushed by a
# concurrent session", and both misfire shapes burned real work: unimplemented tickets skipped
# while their blocks were still PRESENT on origin (hunt #125), and fresh tickets skipped because
# the queue existed only locally (2026-11-24 dispatch wave). The contract pinned here:
#
#   1. a block PRESENT on origin never emits a resolved-skip: it proceeds (or hits a later gate).
#   2. a block absent from origin with a Fix-Files-Contain fingerprint ON the trunk skips as
#      resolved (positive evidence — the only shape that may silently skip).
#   3. fingerprints accumulate across lines and repos (`<repo>:<string>`, `.` = the meta repo);
#      ANY hit resolves.
#   4. a block absent with fingerprints configured but NONE on the trunk prints an explicit
#      resolved-unverified line; it is never a bare drop.
#   5. a block absent with NO fingerprints at all (the local-only-queue shape) also prints
#      resolved-unverified.
#   6. the merged-PR mirror probe: an OPEN block whose PR is already MERGED on origin skips as
#      bookkeeping-only instead of re-implementing merged work; a GOVERN_MERGED_PR_PROBE=0 kill
#      switch restores proceed; an inconclusive gh probe fails OPEN to proceed.
#   7. the mirror probe trusts a discovered MERGED ref only past a generation guard: a merge that
#      PREDATES the block heading's first commit in the queue history is a stale-generation branch
#      match and never skips; an explicit PR reference in the block overrides the guard; a missing
#      merge stamp or an uncommitted queue is inconclusive and never skips.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

PDC="$DIR/../pre-dispatch-check.sh"
[[ -f "$PDC" ]] || { echo "SKIP: pre-dispatch-check.sh not found"; exit 77; }

W="$(mktemp -d)"; trap 'rm -rf "$W" "$S"' EXIT
S="$(mktemp -d)"   # stub dir for the fake gh used by the mirror-probe cases
mk_ws_stub "$W"
mkdir -p "$W/queue"
export GOVERN_QUEUE_DIR="$W/queue"
( cd "$W" && git init -q && git config user.email t@t && git config user.name t )

# ── fixture: a meta workspace whose origin/main carries the genuinely-open blocks (#70, #75) only,
#    plus a sub-repo `alpha` whose trunk carries the #71 fingerprint; #72 pairs a trunk MISS with a
#    meta-repo (`.`) trunk HIT. ──
git init -q --bare "$W/origin-ws.git"
mkdir -p "$W/alpha"
git init -q --bare "$W/origin-alpha.git"
( cd "$W/alpha" && git init -q && git config user.email t@t && git config user.name t
  mkdir -p src && printf 'RETRY_LADDER_MAX_STEP=4\n' > src/ladder.sh
  git add -A && git commit -qm sig >/dev/null
  git branch -M main >/dev/null 2>&1 || true
  git remote add origin "$W/origin-alpha.git"
  git push -q origin main ) >/dev/null 2>&1

cat > "$W/queue/tickets.md" <<'TIX'
# Tickets

## #70 — still open on origin

**Severity:** Low

Done when: done.

---

## #71 — resolved+pushed while this checkout was offline

**Severity:** Low

**Fix-Files-Contain:** alpha:RETRY_LADDER_MAX_STEP=4

Done when: done.

---

## #72 — resolved, fingerprint split across a miss and a meta-repo hit

**Severity:** Low

**Fix-Files-Contain:** alpha:SIG_THAT_WILL_NEVER_EXIST
**Fix-Files-Contain:** .:TRUNK_SIG_72

Done when: done.

---

## #73 — resolved-unverified: fingerprints configured, none on the trunk

**Severity:** Low

**Fix-Files-Contain:** alpha:NO_SUCH_SIG_73

Done when: done.

---

## #74 — unimplemented, queue only on this checkout (no fingerprints)

**Severity:** Low

Done when: done.

---

## #75 — PR merged on origin but the block was never booked

**Severity:** Low

Done when: done.
TIX
( cd "$W" && git add -A && git commit -qm local >/dev/null
  git remote add origin "$W/origin-ws.git"
  # origin/main carries #70 and #75 (both genuinely open); the never-implemented tail is absent.
  printf '# Tickets\n\n## #70 — still open on origin\n\n**Severity:** Low\n\nDone when: done.\n\n---\n\n## #75 — PR merged on origin but the block was never booked\n\n**Severity:** Low\n\nDone when: done.\n' > queue/tickets.md
  printf 'TRUNK_SIG_72\n' > meta-notes.txt
  git add -A && git commit -qm "published" >/dev/null
  git branch -M main >/dev/null 2>&1 || true
  git push -q origin main
  # Restore the FULL queue locally: local says open, origin says gone, for #71-#74.
  cat > queue/tickets.md <<'TIX2'
# Tickets

## #70 — still open on origin

**Severity:** Low

Done when: done.

---

## #71 — resolved+pushed while this checkout was offline

**Severity:** Low

**Fix-Files-Contain:** alpha:RETRY_LADDER_MAX_STEP=4

Done when: done.

---

## #72 — resolved, fingerprint split across a miss and a meta-repo hit

**Severity:** Low

**Fix-Files-Contain:** alpha:SIG_THAT_WILL_NEVER_EXIST
**Fix-Files-Contain:** .:TRUNK_SIG_72

Done when: done.

---

## #73 — resolved-unverified: fingerprints configured, none on the trunk

**Severity:** Low

**Fix-Files-Contain:** alpha:NO_SUCH_SIG_73

Done when: done.

---

## #74 — unimplemented, queue only on this checkout (no fingerprints)

**Severity:** Low

Done when: done.

---

## #75 — PR merged on origin but the block was never booked

**Severity:** Low

Done when: done.
TIX2
  git add -A && git commit -qm "restore locally" >/dev/null ) >/dev/null 2>&1

run_pdc() { ( cd "$W" && GOVERN_NO_PUSH=0 bash "$PDC" "$1" 2>/dev/null ); }

# ── 1. a block present on origin NEVER skips as resolved ─────────────────────────────────────────
out70="$(run_pdc 70)"
assert_contains "$out70" "proceed" "1. a block present on origin proceeds (never a resolved-skip)"
assert_eq "$(printf '%s\n' "$out70" | grep -c .)" "1" "1. the verdict is exactly one line"

# ── 2. absent block, fingerprint ON the trunk: resolved skip (positive evidence only) ────────────
out71="$(run_pdc 71)"
assert_contains "$out71" "skip" "2. a block absent from origin with a trunk signature skips"
assert_contains "$out71" "(resolved)" "2. ...and the verdict says resolved (not bare dropped)"

# ── 3. fingerprints accumulate across lines and repos; ANY hit resolves ──────────────────────────
out72="$(run_pdc 72)"
assert_contains "$out72" "(resolved)" "3. a miss on one repo does not mask a hit on another (meta-repo '.' sig resolves)"

# ── 4. absent block, fingerprints configured but none on the trunk: resolved-UNVERIFIED ──────────
out73="$(run_pdc 73)"
assert_contains "$out73" "skip" "4. a block absent with no trunk hit still skips (no worker burned on a guess)"
assert_contains "$out73" "resolved-unverified" "4. ...but the verdict says resolved-UNVERIFIED"
assert_contains "$out73" "confirm before skipping" "4. ...and tells the caller to confirm"

# ── 5. absent block, NO fingerprints at all (the local-only-queue misfire shape) ─────────────────
out74="$(run_pdc 74)"
assert_contains "$out74" "resolved-unverified" "5. a fingerprint-less absent block is resolved-unverified, never bare-skipped"
assert_contains "$out74" "origin/main" "5. ...and the verdict names origin/main"

# ── 6. the merged-PR mirror probe ────────────────────────────────────────────────────────────────
cat > "$S/gh" <<'STUB'
#!/usr/bin/env bash
# Emulates the helper's `--jq` post-processing: pr list -> "num\turl\tmergedAt" rows,
# pr view -> state. The merge timestamp is far in the future, so it always postdates the fixture
# queue's first commit: the healthy shape (the PR merged after its ticket was filed) that must
# still flag as bookkeeping-only.
case "$2" in
  list) printf '77\thttps://github.com/acme/alpha/pull/77\t2999-01-01T00:00:00Z\n' ;;
  view) echo 'MERGED' ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$S/gh"

out75="$( cd "$W" && PATH="$S:$PATH" GOVERN_NO_PUSH=0 GOVERN_MERGE_REPOS=alpha GOVERN_MERGED_PR_PROBE=1 bash "$PDC" 75 2>/dev/null )"
assert_contains "$out75" "skip" "6. an open block whose PR is MERGED on origin skips"
assert_contains "$out75" "already MERGED" "6. ...the verdict says the PR is already merged"
assert_contains "$out75" "alpha#77" "6. ...and names the merged PR ref"

out75b="$( cd "$W" && PATH="$S:$PATH" GOVERN_NO_PUSH=0 GOVERN_MERGE_REPOS=alpha GOVERN_MERGED_PR_PROBE=0 bash "$PDC" 75 2>/dev/null )"
assert_contains "$out75b" "proceed" "6. GOVERN_MERGED_PR_PROBE=0 is the kill switch back to proceed"

# ── 7. the generation guard: a branch name is reusable across a queue renumbering, so a merged
# PR whose merge PREDATES the block heading's first commit in the queue history cannot be this
# ticket's work. The probe stays silent and the dispatch proceeds: a fixture ticket with no
# explicit PR reference is never skipped on a stale-generation branch match.
mkdir -p "$S/stale"
cat > "$S/stale/gh" <<'STUB'
#!/usr/bin/env bash
case "$2" in
  list) printf '77\thttps://github.com/acme/alpha/pull/77\t2020-01-01T00:00:00Z\n' ;;
  view) echo 'MERGED' ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$S/stale/gh"
out75s="$( cd "$W" && PATH="$S/stale:$PATH" GOVERN_NO_PUSH=0 GOVERN_MERGE_REPOS=alpha GOVERN_MERGED_PR_PROBE=1 bash "$PDC" 75 2>/dev/null )"
assert_contains "$out75s" "proceed" "7. a merged PR predating the block's first queue commit is never trusted (stale-generation branch match)"
assert_eq "$(printf '%s\n' "$out75s" | grep -c .)" "1" "7. ...with still exactly one verdict line"

# ── 8. an explicit PR reference in the block overrides the recency guard: a block that names the
# merged PR itself (a Fix-PR: field, a PR field, a literal `PR #N` mention) vouches for the ref
# regardless of merge date.
( cd "$W" && printf '\n**Fix-PR:** alpha#77\n' >> queue/tickets.md )
out75e="$( cd "$W" && PATH="$S/stale:$PATH" GOVERN_NO_PUSH=0 GOVERN_MERGE_REPOS=alpha GOVERN_MERGED_PR_PROBE=1 bash "$PDC" 75 2>/dev/null )"
assert_contains "$out75e" "skip" "8. a block that explicitly names the merged PR still flags as bookkeeping-only"
assert_contains "$out75e" "already MERGED" "8. ...with the merged-PR verdict"

# Inconclusive probe (gh fails) fails OPEN: never blocks a dispatch on a lookup miss.
mkdir -p "$S/fail"
cat > "$S/fail/gh" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$S/fail/gh"
out75c="$( cd "$W" && PATH="$S/fail:$PATH" GOVERN_NO_PUSH=0 GOVERN_MERGE_REPOS=alpha GOVERN_MERGED_PR_PROBE=1 bash "$PDC" 75 2>/dev/null )"
assert_contains "$out75c" "proceed" "6. an inconclusive gh probe fails OPEN to proceed (never blocks on a lookup miss)"

# The probe never fires for a ticket the stub has no answer about — #70 with a HEALTHY gh that
# reports no merged PR (empty list) must still proceed.
mkdir -p "$S/none"
cat > "$S/none/gh" <<'STUB'
#!/usr/bin/env bash
if [[ "$2" == "list" ]]; then echo '[]'; else exit 0; fi
STUB
chmod +x "$S/none/gh"
out70b="$( cd "$W" && PATH="$S/none:$PATH" GOVERN_NO_PUSH=0 GOVERN_MERGE_REPOS=alpha GOVERN_MERGED_PR_PROBE=1 bash "$PDC" 70 2>/dev/null )"
assert_contains "$out70b" "proceed" "6. a block whose PR search comes back empty proceeds"
assert_eq "$(printf '%s\n' "$out70b" | grep -c .)" "1" "6. ...with still exactly one verdict line"

assert_done
