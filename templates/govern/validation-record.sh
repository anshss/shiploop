#!/usr/bin/env bash
# Standalone validation-evidence sink writer (#252, generalized). From govern-bookkeep.sh:14:
# "Budgets are a property of the FILES, not of the run." Generalized: recording a validated
# ticket's evidence is a property of the WORKSPACE, not of a governor resolve. This block used to be
# INLINED in govern-bookkeep.sh, reachable only from the governor resolve path: a plain interactive
# session that live-tests a ticket by hand recorded nothing durable. Extracted here so
# govern-bookkeep.sh (the governor resolve path) and /validated (an interactive session) are
# two callers of ONE writer instead of one caller owning the only door.
#
# Usage:
#   validation-record.sh --ticket <N> --title <str> (--evidence <str> | --evidence-file <path>) \
#     [--pr <repo#num> ...] [--source <label>] [--print-path-only]
#
#   --ticket           the ticket number N (digits only)
#   --title            the ticket title, used for the heading AND the slug
#   --evidence         the empirical PASS/FAIL evidence text (ids, output, verdict, never a
#                       code-reading verdict); mutually exclusive with --evidence-file
#   --evidence-file    read the evidence text from a file instead of an argv string
#   --pr               a "repo#number" pair naming a PR this validation rode in on; repeatable
#   --source           who is calling this, e.g. "governor resolve (run 2026-09-09T...)" or
#                       "interactive session": names the CALLER in the file's provenance line
#                       instead of always claiming "the governor"
#   --print-path-only  compute and print the target path without writing anything (dry preview)
#
# Resolves the meta root the same way govern-bookkeep.sh does (govern::meta_root) and writes
# <meta-root>/.claude/shiploop/validation/ticket-<N>-<slug>.md. The slug rule is an EXACT match to
# govern-bookkeep.sh's pre-existing #252 promotion: lowercase, non-alphanumerics -> '-', collapse +
# trim, cut to 60 chars, fall back to "validation" when that leaves nothing, so a ticket promoted by
# either caller lands at the identical path.
#
# NEVER clobbers an existing file (a hand-authored summary is richer than anything generated here):
# when the target already exists, this is a silent success: log that it was kept, print the
# repo-relative path, exit 0. On a fresh write, prints that same repo-relative path. Either way,
# stdout carries ONLY the path (nothing else), so a caller can capture it directly.
#
# Kill switch: GOVERN_VALIDATION_RECORD=0 makes this a silent no-op (exit 0, nothing printed, nothing
# written, nothing logged) for a workspace that wants the old governor-only behavior back.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$DIR/lib/common.sh"

if [[ "${GOVERN_VALIDATION_RECORD:-1}" == "0" ]]; then
  exit 0
fi

vr_ticket="" vr_title="" vr_evidence="" vr_evidence_file="" vr_source="" vr_print_only=0
declare -a vr_prs=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ticket)          vr_ticket="${2:?--ticket requires a value}"; shift 2 ;;
    --title)           vr_title="${2:?--title requires a value}"; shift 2 ;;
    --evidence)        vr_evidence="${2:?--evidence requires a value}"; shift 2 ;;
    --evidence-file)   vr_evidence_file="${2:?--evidence-file requires a value}"; shift 2 ;;
    --pr)              vr_prs+=("${2:?--pr requires a value}"); shift 2 ;;
    --source)          vr_source="${2:?--source requires a value}"; shift 2 ;;
    --print-path-only) vr_print_only=1; shift ;;
    -h|--help) sed -n '2,29p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) govern::die "validation-record.sh: unknown argument: $1 (try --help)" ;;
  esac
done

[[ -n "$vr_ticket" ]] || govern::die "validation-record.sh: --ticket <N> is required"
[[ "$vr_ticket" =~ ^[0-9]+$ ]] || govern::die "validation-record.sh: --ticket must be a number, got '$vr_ticket'"
[[ -n "$vr_title" ]] || govern::die "validation-record.sh: --title <str> is required"
if [[ -n "$vr_evidence" && -n "$vr_evidence_file" ]]; then
  govern::die "validation-record.sh: pass --evidence OR --evidence-file, not both"
fi
if [[ -n "$vr_evidence_file" ]]; then
  [[ -f "$vr_evidence_file" ]] || govern::die "validation-record.sh: --evidence-file not found: $vr_evidence_file"
  vr_evidence="$(cat "$vr_evidence_file")"
fi
[[ -n "$vr_evidence" ]] || govern::die "validation-record.sh: --evidence (or --evidence-file, non-empty) is required: reading source is not evidence"

vr_meta_root="$(govern::meta_root)"
vr_dir="$vr_meta_root/.claude/shiploop/validation"

# slugify the title: lowercase, non-alphanumerics -> '-', collapse + trim, cap to 60 chars. EXACT
# match to govern-bookkeep.sh's pre-existing #252 slug rule (do not drift the two apart).
vr_slug="$(printf '%s' "$vr_title" \
  | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed -E 's/^-+//; s/-+$//' | cut -c1-60)"
[[ -n "$vr_slug" ]] || vr_slug="validation"

vr_rel=".claude/shiploop/validation/ticket-$vr_ticket-$vr_slug.md"
vr_file="$vr_dir/ticket-$vr_ticket-$vr_slug.md"

if [[ -e "$vr_file" ]]; then
  govern::log "validation-record #$vr_ticket: $vr_rel already exists, keeping it (not overwriting a hand-authored record)"
  printf '%s\n' "$vr_rel"
  exit 0
fi

if [[ "$vr_print_only" -eq 1 ]]; then
  printf '%s\n' "$vr_rel"
  exit 0
fi

mkdir -p "$vr_dir"

vr_pr_lines=""
for vr_pr in ${vr_prs[@]+"${vr_prs[@]}"}; do
  [[ -n "$vr_pr" ]] || continue
  vr_pr_lines+="- $vr_pr"$'\n'
done
[[ -n "$vr_pr_lines" ]] || vr_pr_lines="- (none recorded)"$'\n'

vr_src_label="${vr_source:-an unspecified caller}"

{
  printf '# Ticket #%s - %s - VALIDATION RESULT\n\n' "$vr_ticket" "$vr_title"
  printf '**Promoted by %s.** This is the durable, git-tracked evidence summary for a validated\n' "$vr_src_label"
  printf 'ticket, the committed sink that founder-os context (`features.md` / `direction.md` /\n'
  printf '`product.md`) may cite as proof. When this ran through the governor, the raw artifacts\n'
  printf '(screenshots, ground-truth, `report.json`, `worker.jsonl`) live in the **gitignored**\n'
  printf 'machine-local investigations sink on the machine that ran the test; this file is the\n'
  printf 'durable record that survives that machine-local sink.\n\n'
  printf '## PR(s)\n%s\n' "$vr_pr_lines"
  printf '## Verdict / evidence\n\n%s\n\n' "$vr_evidence"
  printf -- '---\n> Auto-generated by `validation-record.sh` (#252) so the committed\n'
  printf '> `.claude/shiploop/validation/` sink is never empty for a passing validation. A human may\n'
  printf '> expand this with the full PASS/FAIL table from the raw investigations sink; a pointer in\n'
  printf '> the ticket-history file (governor callers only) keeps the evidence path greppable after\n'
  printf '> the ticket block is deleted.\n'
} > "$vr_file"

govern::log "validation-record #$vr_ticket: wrote $vr_rel (source: $vr_src_label)"
printf '%s\n' "$vr_rel"
exit 0
