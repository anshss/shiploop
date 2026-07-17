#!/usr/bin/env bash
# Merge a STAGED flow-extraction diff into .claude/shiploop/validation/flows.md (validations Phase 4, `/shiploop:flows
# extract`). Extraction fans out over the codebase via Agent workers and writes a proposed registry
# fragment (a flows.md-format file of `## <id>` blocks); this script is the deterministic, operator-
# gated MERGE — the model never writes the registry directly.
#
# The vet gate (design High): hallucinated flows must not silently become fileable — and later
# BILLABLE — rows. So WITHOUT --approve this prints the staged diff and writes NOTHING. WITH --approve
# it applies only the SAFE parts:
#   • NEW id            → appended verbatim (a brand-new flow the extractor found).
#   • existing id       → Paths/Surface REFRESHED (the mapped-file set legitimately drifts).
# and NEVER:
#   • Status / Validated / Disposition / Env / Evidence — verdict state is owned by the governor's
#     bookkeep stamp, never by re-extraction.
#   • a Kind or Gate CHANGE on an existing id — flagged for an explicit operator decision, never
#     auto-applied (a silent correctness→effectiveness flip would rewire the whole verdict vocabulary).
#
# Usage:
#   scripts/govern/flows-extract-merge.sh <staged-file> [--approve]
# Prints the diff summary either way; exit 0 normally, exit 3 when --approve was given but every
# change was a flagged Kind/Gate conflict (nothing safe to apply — surfaced so the caller notices).
# All registry writes go through govern::cas_edit (bookkeep-lock serialized, CAS-pushed). Honors
# GOVERN_NO_PUSH / GOVERN_FLOWS_FILE overrides like the rest of the flow tooling.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$DIR/lib/common.sh"
command -v govern::flow_ids >/dev/null 2>&1 || govern::die "flow parser (flows.sh) unavailable — upgrade the harness"

staged="${1:?usage: flows-extract-merge.sh <staged-file> [--approve]}"
approve=0; [[ "${2:-}" == "--approve" ]] && approve=1
[[ -f "$staged" ]] || govern::die "staged file not found: $staged"

META="$(govern::meta_root 2>/dev/null || echo "$WS_ROOT")"
FLOWS="${GOVERN_FLOWS_FILE:-$META/.claude/shiploop/validation/flows.md}"
mkdir -p "$(dirname "$FLOWS")"
[[ -f "$FLOWS" ]] || : > "$FLOWS"   # first extraction into a fresh registry

# Classify every staged id. Arrays stay index-parallel (bash 3.2 — no associative arrays).
adds=(); refreshes=(); flags=()
while IFS= read -r id; do
  [[ -n "$id" ]] || continue
  if ! govern::flow_exists "$id" "$FLOWS"; then
    adds+=("$id"); continue
  fi
  # Existing id — a Kind or Gate change is a FLAG (never auto-applied); otherwise a Paths/Surface refresh.
  local_kind_cur="$(govern::flow_field "$id" Kind "$FLOWS")"
  local_kind_new="$(govern::flow_field "$id" Kind "$staged")"
  local_gate_cur="$(govern::flow_field "$id" Gate "$FLOWS")"
  local_gate_new="$(govern::flow_field "$id" Gate "$staged")"
  if { [[ -n "$local_kind_new" && "$local_kind_new" != "$local_kind_cur" ]]; } \
     || { [[ -n "$local_gate_new" && "$local_gate_new" != "$local_gate_cur" ]]; }; then
    flags+=("$id")
  else
    refreshes+=("$id")
  fi
done < <(govern::flow_ids "$staged")

# ── Diff summary (always printed) ───────────────────────────────────────────
printf '── /shiploop:flows extract — staged merge for %s ──\n' "${FLOWS#"$META/"}"
printf 'staged: %s   (%d flow block(s))\n\n' "$staged" "$(govern::flow_ids "$staged" | grep -c . || true)"

if [[ ${#adds[@]} -gt 0 ]]; then
  printf 'ADD (%d new flow(s)):\n' "${#adds[@]}"
  for id in "${adds[@]}"; do printf '  + %-32s %s\n' "$id" "$(govern::flow_field "$id" Kind "$staged")"; done
  printf '\n'
fi
if [[ ${#refreshes[@]} -gt 0 ]]; then
  printf 'REFRESH (%d existing — Paths/Surface only):\n' "${#refreshes[@]}"
  for id in "${refreshes[@]}"; do printf '  ~ %s\n' "$id"; done
  printf '\n'
fi
if [[ ${#flags[@]} -gt 0 ]]; then
  printf 'FLAGGED — Kind/Gate change on an existing id (NEVER auto-applied; decide by hand):\n'
  for id in "${flags[@]}"; do
    printf '  ! %s\n' "$id"
    printf '      Kind:  %s  →  %s\n' "$(govern::flow_field "$id" Kind "$FLOWS")" "$(govern::flow_field "$id" Kind "$staged")"
    printf '      Gate:  %s  →  %s\n' "$(govern::flow_field "$id" Gate "$FLOWS")" "$(govern::flow_field "$id" Gate "$staged")"
  done
  printf '\n'
fi
[[ ${#adds[@]} -eq 0 && ${#refreshes[@]} -eq 0 && ${#flags[@]} -eq 0 ]] && { printf '(no flows in the staged file)\n'; exit 0; }

if [[ "$approve" -eq 0 ]]; then
  printf 'DRY RUN — nothing written. Re-run with --approve to apply the ADD + REFRESH rows (flagged rows are still skipped).\n'
  exit 0
fi

if [[ ${#adds[@]} -eq 0 && ${#refreshes[@]} -eq 0 ]]; then
  printf 'Nothing safe to apply — every staged change is a flagged Kind/Gate conflict. Resolve those by hand.\n'
  exit 3
fi

# ── Apply (ADD + REFRESH) through cas_edit ──────────────────────────────────
# The edit-fn runs in THIS shell (cas_edit calls it directly), so it reads the classification arrays
# and the staged file straight from scope. Appends new blocks; refreshes only Paths + Surface on
# existing ids — Status/Validated/Disposition/Env/Evidence are never touched.
_extract_merge_edit() { # <flows-file>
  local f="$1" id blk pval sval
  for id in ${adds[@]+"${adds[@]}"}; do
    blk="$(govern::flow_block "$id" "$staged")"
    [[ -n "$blk" ]] || continue
    # Ensure a blank-line separator before appending (only if the file is non-empty and lacks one).
    [[ -s "$f" ]] && [[ -n "$(tail -c1 "$f" 2>/dev/null)" || -n "$(tail -n1 "$f" 2>/dev/null)" ]] && printf '\n' >> "$f"
    printf '%s\n' "$blk" >> "$f"
  done
  for id in ${refreshes[@]+"${refreshes[@]}"}; do
    pval="$(govern::flow_field "$id" Paths "$staged")"
    sval="$(govern::flow_field "$id" Surface "$staged")"
    [[ -n "$pval" ]] && govern::flow_set_field "$id" Paths   "$pval" "$f" || true
    [[ -n "$sval" ]] && govern::flow_set_field "$id" Surface "$sval" "$f" || true
  done
}
govern::cas_edit "$FLOWS" _extract_merge_edit "docs(flows): extract-merge — +${#adds[@]} new, ~${#refreshes[@]} refreshed"
unset -f _extract_merge_edit

printf 'APPLIED: %d added, %d refreshed' "${#adds[@]}" "${#refreshes[@]}"
[[ ${#flags[@]} -gt 0 ]] && printf ' (%d flagged Kind/Gate change(s) skipped)' "${#flags[@]}"
printf '.\n'
exit 0
