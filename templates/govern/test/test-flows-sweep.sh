#!/usr/bin/env bash
# Staleness sweep (validations Phase 3): govern::flows_sweep_file / _sweep_scan. Covers the core
# per-sub-repo git-log degrade, the monotonic missing-repo semantics ("cannot compute → left as-is,
# never silently fresh"), negative-verdict staling, kill-disposition auto-withdrawal on a freshly-stale
# flow, the non-staleable-status exclusion, dry-run (report-only, no mutation), and the status-count
# summary line. Each mechanism is spot-checked to go the OTHER way when its precondition flips.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
command -v git >/dev/null 2>&1 || { echo "git absent — skip"; exit 77; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"
mkdir -p "$T/governor"
export GOVERN_NO_PUSH=1
source "$DIR/../lib/common.sh"

# Meta repo M with a sub-repo `backend`: c1 (SHA1) then c2 (SHA2) touching backend/src/app.txt.
M="$T/meta"; mkdir -p "$M/validation"
git init -q "$M"; git -C "$M" config user.email ci@test; git -C "$M" config user.name ci
mkdir -p "$M/backend/src"; git init -q "$M/backend"; git -C "$M/backend" config user.email ci@test; git -C "$M/backend" config user.name ci
printf 'v1\n' > "$M/backend/src/app.txt"; git -C "$M/backend" add -A; git -C "$M/backend" commit -q -m c1
SHA1="$(git -C "$M/backend" rev-parse HEAD)"
printf 'v2\n' >> "$M/backend/src/app.txt"; git -C "$M/backend" add -A; git -C "$M/backend" commit -q -m c2
SHA2="$(git -C "$M/backend" rev-parse HEAD)"
# The sweep targets refs/remotes/origin/main; set it directly to HEAD (==SHA2) without a real remote,
# so a pin at SHA1 reads a backend/src/ change since-validated (STALE) and a pin at SHA2 reads clean.
git -C "$M/backend" update-ref refs/remotes/origin/main "$SHA2"
FLOWS="$M/validation/flows.md"
status_of() { govern::flow_field "$1" Status "$FLOWS"; }

seed() { # <status> [validated-sha] [extra-lines...]
  local st="$1" sha="${2:-$SHA1}"; shift 2 || shift $#
  cat > "$FLOWS" <<EOF
## deploy.correctness
- **Kind:** correctness
- **Surface:** UI → backend
- **Paths:** backend/src/**
- **Status:** $st
- **Validated:** 2026-07-01 · backend@${sha:0:7} · PR https://x/1
- **Env:** prod
- **Evidence:** validation/evidence/deploy.correctness.md
EOF
  for extra in "$@"; do printf -- '%s\n' "$extra" >> "$FLOWS"; done
}

# ── PASS pinned at SHA1, origin/main == SHA2 (a backend/src/ change landed since) → STALE.
seed PASS "$SHA1"
GOVERN_FLOWS_SWEEP_STALED=""
GOVERN_FLOWS_SWEEP_META="$M" govern::flows_sweep_file "$FLOWS"
assert_eq "$(status_of deploy.correctness)" "STALE" "PASS pinned behind origin/main (paths moved) → STALE"
assert_contains "$GOVERN_FLOWS_SWEEP_STALED" "deploy.correctness" "sweep records the newly-stale id"

# ── PASS pinned at SHA2 (== origin/main, nothing moved) → stays PASS.
seed PASS "$SHA2"
GOVERN_FLOWS_SWEEP_STALED=""
GOVERN_FLOWS_SWEEP_META="$M" govern::flows_sweep_file "$FLOWS"
assert_eq "$(status_of deploy.correctness)" "PASS" "PASS pinned at origin/main HEAD → stays PASS (spot-check: no false STALE)"
assert_eq "${GOVERN_FLOWS_SWEEP_STALED:-EMPTY}" "EMPTY" "fresh flow not reported staled"

# ── Negatives stale too: an INEFFECTIVE pinned behind → STALE (a stale negative must not be acted on).
seed INEFFECTIVE "$SHA1"
GOVERN_FLOWS_SWEEP_META="$M" GOVERN_FLOWS_SWEEP_STALED="" govern::flows_sweep_file "$FLOWS"
assert_eq "$(status_of deploy.correctness)" "STALE" "INEFFECTIVE pinned behind → STALE (negatives stale too)"

# ── Non-staleable status (UNTESTED) is never touched even though paths moved.
seed UNTESTED "$SHA1"
GOVERN_FLOWS_SWEEP_META="$M" GOVERN_FLOWS_SWEEP_STALED="" govern::flows_sweep_file "$FLOWS"
assert_eq "$(status_of deploy.correctness)" "UNTESTED" "UNTESTED excluded from sweep (no settled claim to invalidate)"

# ── Kill-disposition auto-withdrawal: INEFFECTIVE + a pending kill that goes STALE → disposition withdrawn.
seed INEFFECTIVE "$SHA1" "- **Disposition:** kill → removal PR pending"
GOVERN_FLOWS_SWEEP_META="$M" GOVERN_FLOWS_SWEEP_STALED="" govern::flows_sweep_file "$FLOWS"
assert_eq "$(status_of deploy.correctness)" "STALE" "kill+STALE: flow degraded"
assert_contains "$(govern::flow_field deploy.correctness Disposition "$FLOWS")" "withdrawn" "pending kill auto-withdrawn on stale negative"

# ── A non-kill disposition is NOT rewritten when the flow goes stale (spot-check: only kill withdraws).
seed PASS "$SHA1" "- **Disposition:** ship-default-off"
GOVERN_FLOWS_SWEEP_META="$M" GOVERN_FLOWS_SWEEP_STALED="" govern::flows_sweep_file "$FLOWS"
assert_eq "$(govern::flow_field deploy.correctness Disposition "$FLOWS")" "ship-default-off" "non-kill disposition left intact"

# ── Missing sub-repo → cannot compute → status UNCHANGED (never silently fresh).
cat > "$FLOWS" <<EOF
## api.ghost
- **Kind:** correctness
- **Surface:** UI → ghost
- **Paths:** ghostrepo/src/**
- **Status:** PASS
- **Validated:** 2026-07-01 · ghostrepo@deadbee · PR https://x/2
- **Env:** prod
- **Evidence:** validation/evidence/api.ghost.md
EOF
GOVERN_FLOWS_SWEEP_META="$M" GOVERN_FLOWS_SWEEP_STALED="" govern::flows_sweep_file "$FLOWS" 2>/dev/null
assert_eq "$(status_of api.ghost)" "PASS" "missing/un-cloned repo → cannot compute → status unchanged (not falsely fresh, not falsely stale)"

# ── Monotonic: a flow mapping a PRESENT changed repo AND a missing repo still STALEs on the present change.
cat > "$FLOWS" <<EOF
## multi.repo
- **Kind:** correctness
- **Surface:** UI → backend + ghost
- **Paths:** backend/src/** ghostrepo/src/**
- **Status:** PASS
- **Validated:** 2026-07-01 · backend@${SHA1:0:7} ghostrepo@deadbee · PR https://x/3
- **Env:** prod
- **Evidence:** validation/evidence/multi.repo.md
EOF
GOVERN_FLOWS_SWEEP_META="$M" GOVERN_FLOWS_SWEEP_STALED="" govern::flows_sweep_file "$FLOWS" 2>/dev/null
assert_eq "$(status_of multi.repo)" "STALE" "present-repo change stales even when another mapped repo is missing (monotonic)"

# ── Dry scan mutates nothing but reports the would-stale ids.
seed PASS "$SHA1"
before="$(cat "$FLOWS")"
scanned="$(GOVERN_FLOWS_SWEEP_META="$M" GOVERN_FLOWS_SWEEP_DRY=1 bash -c '
  source '"$DIR"'/../lib/common.sh; GOVERN_FLOWS_SWEEP_STALED=""; GOVERN_FLOWS_SWEEP_DRY=1 GOVERN_FLOWS_SWEEP_META='"$M"' govern::flows_sweep_file '"$FLOWS"'; printf "%s" "$GOVERN_FLOWS_SWEEP_STALED"' 2>/dev/null)"
assert_eq "$(cat "$FLOWS")" "$before" "dry scan does not mutate the registry"
assert_contains "$scanned" "deploy.correctness" "dry scan still reports the would-stale id"

# ── status-count summary line.
cat > "$FLOWS" <<EOF
## a.one
- **Kind:** correctness
- **Surface:** s
- **Paths:** backend/src/**
- **Status:** PASS
- **Validated:** d · backend@${SHA2:0:7} · PR p
- **Env:** prod
- **Evidence:** validation/evidence/a.one.md

## a.two
- **Kind:** correctness
- **Surface:** s
- **Paths:** backend/src/**
- **Status:** STALE
- **Validated:** d · backend@${SHA1:0:7} · PR p
- **Env:** prod
- **Evidence:** validation/evidence/a.two.md

## a.three
- **Kind:** correctness
- **Surface:** s
- **Paths:** backend/src/**
- **Status:** UNTESTED

## a.four
- **Kind:** effectiveness
- **Gate:** x >= 1 · source: analytics:e/1
- **Surface:** s
- **Paths:** backend/src/**
- **Status:** INEFFECTIVE
- **Validated:** d · backend@${SHA1:0:7} · PR p
- **Env:** prod
- **Evidence:** validation/evidence/a.four.md
- **Disposition:** kill → removal PR pending
EOF
sum="$(govern::flows_status_summary "$M")"
assert_contains "$sum" "4 total" "summary: total count"
assert_contains "$sum" "1 PASS-fresh" "summary: PASS-fresh bucket"
assert_contains "$sum" "1 STALE" "summary: STALE bucket"
assert_contains "$sum" "1 UNTESTED" "summary: UNTESTED bucket"
assert_contains "$sum" "1 INEFFECTIVE" "summary: INEFFECTIVE bucket"
assert_contains "$sum" "1 pending-disposition" "summary: pending-disposition count"

# ── path-match heads-up: a change under a mapped glob surfaces the flow; an unrelated path does not.
cat > "$FLOWS" <<EOF
## deploy.vastai
- **Kind:** correctness
- **Surface:** s
- **Paths:** backend/src/providers/vastai/**
- **Status:** PASS
- **Validated:** d · backend@${SHA2:0:7} · PR p
- **Env:** prod
- **Evidence:** validation/evidence/deploy.vastai.md

## deploy.broad
- **Kind:** correctness
- **Surface:** s
- **Paths:** backend/src/**
- **Status:** PASS
- **Validated:** d · backend@${SHA2:0:7} · PR p
- **Env:** prod
- **Evidence:** validation/evidence/deploy.broad.md

## unrelated.untested
- **Kind:** correctness
- **Surface:** s
- **Paths:** backend/src/providers/vastai/**
- **Status:** UNTESTED
EOF
matched="$(govern::flows_matching_paths "$M" 5 "backend/src/providers/vastai/client.go" | tr '\n' ' ')"
assert_contains "$matched" "deploy.vastai" "path-match: specific flow surfaced"
assert_contains "$matched" "deploy.broad" "path-match: coarser mapped flow also surfaced"
assert_eq "$(printf '%s' "$matched" | grep -c 'unrelated.untested' || true)" "0" "path-match: UNTESTED flow excluded (nothing validated to stale)"
# most-specific first: deploy.vastai (longer prefix) ranks before deploy.broad.
assert_eq "$(govern::flows_matching_paths "$M" 5 "backend/src/providers/vastai/client.go" | head -1)" "deploy.vastai" "path-match: most-specific ranked first"
# an unrelated path matches nothing.
assert_eq "$(govern::flows_matching_paths "$M" 5 "console/app/page.tsx" | wc -l | tr -d ' ')" "0" "path-match: unrelated path surfaces nothing"

assert_done
