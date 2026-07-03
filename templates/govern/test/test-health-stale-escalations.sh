#!/usr/bin/env bash
# #312 — govern-health.sh flags STALE open escalations: any `## Open` entry still blank on BOTH
# Answer and Disposition whose stamped `Opened` date is older than GOVERN_ESCALATION_STALE_DAYS
# (default 3). Legacy entries with no `Opened` field (they predate #312) are flagged with an unknown
# age. Answered entries and freshly-opened ones are NOT flagged. Pure sandbox: no auth, no network.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
HEALTH="$DIR/../govern-health.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"

# Portable "N days ago" as YYYY-MM-DD (BSD date first, then GNU).
days_ago() { date -v-"$1"d +%F 2>/dev/null || date -d "$1 days ago" +%F; }
OLD="$(days_ago 30)"     # well past the 3-day threshold
TODAY="$(date +%F)"      # opened today → not yet stale

cat > "$T/escalations.md" <<EOF
# Escalations

## Open

### #101 — old and unanswered (SHOULD flag)
- **Opened:** $OLD (run run-old)
- **Reason:** stuck a long time
- **Question:** what to do
- **Options:** A / B
- **Answer:** _(operator fills this in)_
- **Disposition:** _(operator: do-the-work | defer | mitigated | keep-open)_
- **Make this a rule?:** _(operator)_

### #102 — opened today, unanswered (should NOT flag — too young)
- **Opened:** $TODAY (run run-fresh)
- **Reason:** just parked
- **Question:** q
- **Options:** A
- **Answer:** _(operator fills this in)_
- **Disposition:** _(operator: do-the-work | defer | mitigated | keep-open)_
- **Make this a rule?:** _(operator)_

### #103 — old but ANSWERED (should NOT flag)
- **Opened:** $OLD (run run-old)
- **Reason:** r
- **Question:** q
- **Options:** A
- **Answer:** yes, go ahead
- **Disposition:** do-the-work
- **Make this a rule?:** _(operator)_

### #104 — legacy entry, no Opened field, unanswered (SHOULD flag, unknown age)
- **Reason:** predates the #312 Opened field
- **Question:** q
- **Options:** A
- **Answer:** _(operator fills this in)_
- **Disposition:** _(operator: do-the-work | defer | mitigated | keep-open)_
- **Make this a rule?:** _(operator)_

## Resolved
EOF

env_common=(
  GOVERN_ESCALATIONS_FILE="$T/escalations.md"
  GOVERN_HISTORY_FILE="$T/no-history.jsonl"   # absent → exercises the empty-history path too
  GOVERN_ESCALATION_STALE_DAYS=3
)

# ── JSON path ────────────────────────────────────────────────────────────────────────────
json="$(env "${env_common[@]}" bash "$HEALTH" --json)"
flagged="$(jq -r '.staleEscalations | map(.ticket|tostring) | join(",")' <<<"$json")"
assert_eq "$flagged" "101,104" "stale = old-unanswered #101 + legacy-no-Opened #104 (ordered oldest-first)"
assert_eq "$(jq -r '.staleEscalationDays' <<<"$json")" "3" "threshold surfaced in JSON"
assert_eq "$(jq -r '.staleEscalations[] | select(.ticket==101) | .ageDays' <<<"$json")" "30" "#101 age computed from Opened date"
assert_eq "$(jq -r '.staleEscalations[] | select(.ticket==104) | .ageDays' <<<"$json")" "null" "#104 (no Opened) reported with null age"
assert_eq "$(jq -r '.staleEscalations | map(.ticket) | index(102) // "none"' <<<"$json")" "none" "#102 (opened today) NOT flagged"
assert_eq "$(jq -r '.staleEscalations | map(.ticket) | index(103) // "none"' <<<"$json")" "none" "#103 (answered) NOT flagged"

# ── human render path ────────────────────────────────────────────────────────────────────
human="$(env "${env_common[@]}" bash "$HEALTH")"
assert_contains "$human" "stale escalations — needs operator attention" "human render shows the stale section header"
assert_contains "$human" "#101 (30d open)" "human render shows #101 with its age"
assert_contains "$human" "#104 (opened date unknown)" "human render shows #104 as unknown-age"

# ── nothing stale → no section, empty array ──────────────────────────────────────────────
cat > "$T/clean.md" <<EOF
# Escalations

## Open

### #200 — answered, nothing stale
- **Opened:** $OLD (run run-old)
- **Reason:** r
- **Question:** q
- **Options:** A
- **Answer:** done
- **Disposition:** mitigated
- **Make this a rule?:** _(operator)_

## Resolved
EOF
cleanjson="$(env GOVERN_ESCALATIONS_FILE="$T/clean.md" GOVERN_HISTORY_FILE="$T/no-history.jsonl" GOVERN_ESCALATION_STALE_DAYS=3 bash "$HEALTH" --json)"
assert_eq "$(jq -r '.staleEscalations | length' <<<"$cleanjson")" "0" "no stale entries when the only open one is answered"
cleanhuman="$(env GOVERN_ESCALATIONS_FILE="$T/clean.md" GOVERN_HISTORY_FILE="$T/no-history.jsonl" GOVERN_ESCALATION_STALE_DAYS=3 bash "$HEALTH")"
assert_eq "$(grep -c 'stale escalations' <<<"$cleanhuman" || true)" "0" "no stale section rendered when nothing is stale"

assert_done
