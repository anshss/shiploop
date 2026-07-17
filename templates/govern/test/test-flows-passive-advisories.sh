#!/usr/bin/env bash
# Passive evidence + due-advisories (validations Phase 5). The analytics adapter is generic (knob NAME
# here, VALUE in workspace.sh); passive "0 usage" evidence and MEASURING/Revalidate due-nudges are
# ADVISORY ONLY — surfaced for the operator, NEVER auto-stamping a verdict or auto-filing (billable
# safety). Covers: flow_analytics_query rc 2 when unwired / passthrough when wired; flows_passive_evidence
# 0-usage advisory + never-stamps + --attach note; non-zero usage → silent; flows_due_advisories
# MEASURING-window-elapsed + Revalidate-past-due + not-yet-due silence; no-registry no-op.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
command -v git >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || { echo "git/jq absent — skip"; exit 77; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"
export GOVERN_NO_PUSH=1

M="$T/meta"; mkdir -p "$M/.claude/shiploop/validation" "$M/governor"
git init -q "$M"; git -C "$M" config user.email ci@test; git -C "$M" config user.name ci
export GOVERN_FLOWS_FILE="$M/.claude/shiploop/validation/flows.md"
source "$DIR/../lib/common.sh"
FLOWS="$GOVERN_FLOWS_FILE"
fld() { govern::flow_field "$1" "$2" "$FLOWS"; }

# Analytics stub: echoes "0" for a source naming "dead", else "42". flow_analytics_query appends the
# source as the final arg, so word-splitting a multi-word command line is exercised too.
mkdir -p "$T/bin"
cat > "$T/bin/analytics-stub" <<'EOF'
#!/usr/bin/env bash
case "$*" in *dead*) echo 0;; *) echo 42;; esac
EOF
chmod +x "$T/bin/analytics-stub"
STUB="$T/bin/analytics-stub"

# ── flow_analytics_query: rc 2 when the knob is unwired; passthrough when wired. ─────────────────────
if ( unset WSP_ANALYTICS_QUERY_CMD; govern::flow_analytics_query "any:src" >/dev/null ); then rc=0; else rc=$?; fi
assert_eq "$rc" "2" "analytics query: rc 2 when WSP_ANALYTICS_QUERY_CMD unset"
q="$( WSP_ANALYTICS_QUERY_CMD="$STUB query" govern::flow_analytics_query "posthog:exp/live" )"
assert_eq "$q" "42" "analytics query: passthrough echoes the adapter's stdout (wired multi-word cmd)"

# ── Registry seed: a PASS flow with 0 usage, a PASS flow with real usage, a PASS flow with NO source. ─
cat > "$FLOWS" <<'EOF'
## feature.dead
- **Kind:** correctness
- **Surface:** UI
- **Paths:** validation/**
- **Status:** PASS
- **Validated:** 2026-06-01 · repo@abc1234 · PR https://x/1
- **Env:** prod
- **Usage-source:** posthog:event/dead-feature

## feature.live
- **Kind:** correctness
- **Surface:** UI
- **Paths:** validation/**
- **Status:** PASS
- **Validated:** 2026-06-01 · repo@abc1234 · PR https://x/2
- **Env:** prod
- **Usage-source:** posthog:event/live-feature

## feature.nosrc
- **Kind:** correctness
- **Surface:** UI
- **Paths:** validation/**
- **Status:** PASS
- **Validated:** 2026-06-01 · repo@abc1234 · PR https://x/3
- **Env:** prod
EOF
git -C "$M" add -A; git -C "$M" commit -q -m seed

# ── flows_passive_evidence report-only: 0-usage flow → advisory; live flow silent; no Status touched. ─
adv="$( WSP_ANALYTICS_QUERY_CMD="$STUB" govern::flows_passive_evidence "$M" )"
assert_contains "$adv" "PASSIVE feature.dead" "passive: 0-usage flow surfaces an advisory"
assert_contains "$adv" "0 usage"              "passive: advisory names the 0-usage finding"
assert_eq "$(printf '%s' "$adv" | grep -c 'feature.live' || true)"  "0" "passive: a flow with real usage does NOT surface"
assert_eq "$(printf '%s' "$adv" | grep -c 'feature.nosrc' || true)" "0" "passive: a flow with no Usage-source is skipped"
assert_eq "$(fld feature.dead Status)"      "PASS" "passive: report-only NEVER stamps a verdict (Status unchanged)"
assert_eq "$(fld feature.dead Disposition)" ""     "passive: report-only writes no Disposition"

# ── passive off when the knob is unwired (no output, no error). ──────────────────────────────────────
adv_off="$( unset WSP_ANALYTICS_QUERY_CMD; govern::flows_passive_evidence "$M" 2>/dev/null )"
assert_eq "$adv_off" "" "passive: unwired analytics → no advisory (off)"

# ── --attach records a durable Passive-note (still never a Status/Disposition stamp). ────────────────
WSP_ANALYTICS_QUERY_CMD="$STUB" govern::flows_passive_evidence "$M" --attach >/dev/null 2>&1
assert_contains "$(fld feature.dead Passive-note)" "0 usage" "passive --attach: records a Passive-note field"
assert_eq "$(fld feature.dead Status)"      "PASS" "passive --attach: Status STILL untouched (a note, not a stamp)"
assert_eq "$(printf '%s' "$(fld feature.live Passive-note)")" "" "passive --attach: live flow gets no note"

# ── flows_due_advisories: MEASURING-window elapsed + Revalidate past-due + not-yet-due silence. ──────
TODAY="$(date +%F)"
cat > "$FLOWS" <<EOF
## measuring.elapsed
- **Kind:** effectiveness
- **Gate:** reduction >= 10% · source: analytics:e/1
- **Surface:** A/B
- **Paths:** validation/**
- **Status:** MEASURING
- **Validated:** 2026-01-01 · repo@abc1234 · PR https://x/9
- **Env:** prod
- **Sample-window:** 7d

## measuring.fresh
- **Kind:** effectiveness
- **Gate:** reduction >= 10% · source: analytics:e/2
- **Surface:** A/B
- **Paths:** validation/**
- **Status:** MEASURING
- **Validated:** $TODAY · repo@abc1234 · PR https://x/10
- **Env:** prod
- **Sample-window:** 14d

## reval.due
- **Kind:** correctness
- **Surface:** UI
- **Paths:** validation/**
- **Status:** PASS
- **Validated:** 2026-01-01 · repo@abc1234 · PR https://x/11
- **Env:** prod
- **Revalidate:** every 30d

## reval.fresh
- **Kind:** correctness
- **Surface:** UI
- **Paths:** validation/**
- **Status:** PASS
- **Validated:** $TODAY · repo@abc1234 · PR https://x/12
- **Env:** prod
- **Revalidate:** every 365d
EOF
due="$( govern::flows_due_advisories "$M" )"
assert_contains "$due" "MEASURING measuring.elapsed" "due: MEASURING flow past its sample window is surfaced"
assert_eq "$(printf '%s' "$due" | grep -c 'measuring.fresh' || true)" "0" "due: a MEASURING flow inside its window is NOT surfaced"
assert_contains "$due" "REVALIDATE reval.due" "due: a Revalidate policy past due is surfaced"
assert_eq "$(printf '%s' "$due" | grep -c 'reval.fresh' || true)" "0" "due: a not-yet-due Revalidate flow is NOT surfaced"

# ── no registry → clean no-op for both. ──────────────────────────────────────────────────────────────
EMPTY="$T/empty"; mkdir -p "$EMPTY"
assert_eq "$( govern::flows_due_advisories "$EMPTY" )" "" "due: no registry → no-op"
assert_eq "$( WSP_ANALYTICS_QUERY_CMD="$STUB" govern::flows_passive_evidence "$EMPTY" )" "" "passive: no registry → no-op"

assert_done
