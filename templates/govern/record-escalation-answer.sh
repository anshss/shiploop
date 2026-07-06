#!/usr/bin/env bash
# #N15 — write the operator's escalation answer back into governor/escalations.md WITHOUT the
# calling command needing Edit-tool access. commands/govern.md's escalation round-trip declares
# `allowed-tools: Bash, Read` only (bash-owns-everything, matching run-loop/spawn-worker's own
# posture); before this script existed that command's Phase-2 procedure asked the relay to hand-edit
# escalations.md, which either stalled on a permission ask or improvised fragile inline sed/awk.
#
# Rewrites the `- **Answer:**` and `- **Disposition:**` lines (and, if given, `- **Make this a
# rule?:**`) of the named `### #N` entry — but ONLY while it still sits under "## Open"; a
# `## Resolved` entry (or ticket number that plain doesn't exist) is refused so a stale/typo'd N
# can't silently rewrite history. Same field structure govern::file_open_escalation writes, so
# escalations-apply-answers.sh reads the result at the next run-start with no format drift.
#
# Usage:
#   record-escalation-answer.sh <N> --answer "<text>" --disposition <token> [--rule "<text>"]
#     <token> one of: do-the-work | defer | mitigated | keep-open (canonical tokens
#     escalations-apply-answers.sh's govern::norm_disposition acts on).
#
# Idempotent: re-running for the same N overwrites the same three fields, so a typo'd answer can be
# corrected by calling it again before the next governor run applies it. Commits (and, unless
# GOVERN_NO_PUSH=1, CAS-pushes) escalations.md via the same govern::_commit_escalations path every
# other escalations.md writer uses.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$DIR/lib/common.sh"

N="${1:-}"
[[ "$N" =~ ^[0-9]+$ ]] || govern::die "usage: record-escalation-answer.sh <N> --answer \"...\" --disposition <token> [--rule \"...\"]"
shift

answer="" disposition="" rule=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --answer)       [[ -n "${2:-}" ]] || govern::die "--answer requires a value"; answer="$2"; shift 2 ;;
    --disposition)  disposition="${2:-}"; shift 2 ;;
    --rule)         rule="${2:-}"; shift 2 ;;
    *) govern::die "unknown argument: $1" ;;
  esac
done

[[ -n "$answer" ]] || govern::die "--answer is required"
case "$disposition" in
  do-the-work|defer|mitigated|keep-open) ;;
  *) govern::die "--disposition must be one of do-the-work|defer|mitigated|keep-open (got: '$disposition')" ;;
esac

[[ -f "$ESCALATIONS_FILE" ]] || govern::die "no escalations file at $ESCALATIONS_FILE"

# Refuse a ticket # that isn't an OPEN entry (already resolved, or never escalated) — same section
# scan test-escalations.sh uses to read the Open block.
open_section="$(awk '/^## Open/{f=1;next} /^## Resolved/{f=0} f' "$ESCALATIONS_FILE")"
printf '%s\n' "$open_section" | grep -qE "^### +#$N([^0-9]|\$)" \
  || govern::die "no OPEN ### #$N entry in $ESCALATIONS_FILE (already resolved, or never escalated)"

tmp="$(mktemp)"
awk -v n="$N" -v ans="$answer" -v disp="$disposition" -v rule="$rule" '
  BEGIN { section=""; in_block=0 }
  /^## Open/     { section="open"; print; next }
  /^## Resolved/ { section="resolved"; in_block=0; print; next }
  /^### +#/ {
    m=$0; sub(/^### +#/,"",m); sub(/[^0-9].*/,"",m)
    in_block = (section=="open" && m==n) ? 1 : 0
    print; next
  }
  in_block && /^- \*\*Answer:\*\*/       { print "- **Answer:** " ans; next }
  in_block && /^- \*\*Disposition:\*\*/  { print "- **Disposition:** " disp; next }
  in_block && rule != "" && /^- \*\*Make this a rule\?:\*\*/ { print "- **Make this a rule?:** " rule; next }
  { print }
' "$ESCALATIONS_FILE" > "$tmp" && mv "$tmp" "$ESCALATIONS_FILE"

govern::_commit_escalations "record answer for #$N ($disposition)"
echo "recorded #$N: disposition=$disposition"
