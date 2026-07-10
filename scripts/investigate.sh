#!/usr/bin/env bash
# Seed an investigation notes file for a free-text bug description, and (optionally)
# auto-collect recent errors via this workspace's log tool if one is wired up.
#
# GENERIC harness stub: the notes-seeding + hypothesis→evidence structure is portable.
# The evidence-collection guts (log queries, live DB state) are WORKSPACE-SPECIFIC — this
# stub calls an optional `scripts/logs.sh` if present and otherwise leaves clearly-marked
# placeholders for you to wire in your own log/DB probes.
#
# Usage:  scripts/investigate.sh "<bug description>"
# Prints: the path of the notes file.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/workspace.sh
source "$ROOT/scripts/lib/workspace.sh" 2>/dev/null || true

if [ $# -lt 1 ]; then
  echo "usage: scripts/investigate.sh \"<bug description>\"" >&2
  exit 2
fi

DESC="$*"
NOW=$(date +"%Y-%m-%d-%H%M")
NOW_HUMAN=$(date +"%Y-%m-%d %H:%M %Z")

slug_body=$(printf '%s' "$DESC" \
  | tr '[:upper:]' '[:lower:]' \
  | tr -c '[:alnum:]' '-' \
  | sed -E 's/-+/-/g; s/^-//; s/-$//' \
  | cut -c1-40 \
  | sed -E 's/-$//')
SLUG="${NOW}-${slug_body}"

OUT_DIR="$ROOT/logs/investigations"
mkdir -p "$OUT_DIR"
OUT="$OUT_DIR/$SLUG.md"

# ── Optional workspace-specific evidence collection ─────────────────────────
# If this workspace ships a log-query tool at scripts/logs.sh, pull the last hour of
# errors to seed the notes. Absent → leave a marked placeholder. Wire your own log/DB
# probes here (e.g. `scripts/logs.sh --error --since 1h`, a `psql` live-state query).
if [ -x "$ROOT/scripts/logs.sh" ]; then
  err_logs=$(bash "$ROOT/scripts/logs.sh" --error --since 1h --limit 100 2>&1 || echo "(logs.sh failed)")
else
  err_logs="(no scripts/logs.sh in this workspace — wire your log tool here, then re-run.
# workspace-specific: replace this branch with your log query, e.g. a cloud-logs CLI
# filtered to the last hour of errors across your services.)"
fi

cat > "$OUT" <<EOF
# Investigation: $DESC

**Reported:** $NOW_HUMAN
**Status:** open

## Reported symptoms

$DESC

## Initial evidence (auto-collected)

### Recent errors across services (last 1h)
\`\`\`
$err_logs
\`\`\`

<!-- workspace-specific: add live DB state / provider state / slow-query probes here -->

## Hypothesis

(filled in during investigation)

## Evidence

(for / against — filled in during investigation)

## Resolution

(written after fix lands)
EOF

echo "$OUT"
