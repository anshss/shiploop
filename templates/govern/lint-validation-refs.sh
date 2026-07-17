#!/usr/bin/env bash
# Lint for DANGLING `.claude/shiploop/validation/*.md` references (#252). The committed validation
# sink is cited as proof by founder-os context (`features.md` / `direction.md` / `product.md`) and
# the root `CLAUDE.md`. A founder-os layout migration that DELETES a summary while live refs still
# point at it → dangling proof. This is the cheap backstop: scan the pillar-claim files for any
# `.claude/shiploop/validation/<name>.md` reference and FAIL if the referenced file is missing, so a
# migration can't silently orphan the evidence a claim rests on.
#
# Prints each "<source>:<line> → <missing target>" to stderr and exits 1 if any ref dangles; silent
# + exit 0 when every ref resolves. Wire into the Stop hook beside the other lint passes.
#
# Usage: scripts/govern/lint-validation-refs.sh [meta-root]   (defaults to the governor meta-root)
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$DIR/lib/common.sh"

root="${1:-$(govern::meta_root)}"
vdir="$root/.claude/shiploop/validation"

# Files that may cite a validation summary: the founder-os context tree + the root CLAUDE.md and its
# optional on-demand appendix (some workspaces tier the CLAUDE.md forensics — which carry the
# citations — into a CLAUDE-APPENDIX.md; scan both, guarded on existence, so moving a citation there
# keeps it linted).
sources=()
[[ -f "$root/CLAUDE.md" ]] && sources+=("$root/CLAUDE.md")
[[ -f "$root/CLAUDE-APPENDIX.md" ]] && sources+=("$root/CLAUDE-APPENDIX.md")
for ctx_dir in "$root/.claude/context" "$root/.claude/shiploop"; do
  [[ -d "$ctx_dir" ]] || continue
  while IFS= read -r f; do sources+=("$f"); done \
    < <(find "$ctx_dir" -type f -name '*.md' 2>/dev/null)
done
# No founder-os context sources to scan — still run the flow-registry lint matrix (below) and exit
# on its verdict. The two lints are independent: this legacy pass guards `.claude/shiploop/validation`
# refs; govern::flows_lint guards the `validation/` flow registry + evidence sinks.
[[ ${#sources[@]} -eq 0 ]] && { govern::flows_lint "$root"; exit $?; }

# A reference is the literal path `.claude/shiploop/validation/<name>.md`. The charset deliberately
# EXCLUDES `<`, `*`, `(`, `)` so doc placeholders/globs (`ticket-<N>-*.md`, `.../*.md`) never match.
# The legacy `.claude/context/validation/` prefix is matched too so a ref that survived the sink
# migration (post-#252 layout move to `.claude/shiploop/`) is flagged as dangling, not skipped.
ref_re='\.claude/(context|shiploop)/validation/[A-Za-z0-9._-]+\.md'
dangling=""
while IFS= read -r hit; do
  [[ -n "$hit" ]] || continue
  src="${hit%%:*}"; rest="${hit#*:}"; lineno="${rest%%:*}"
  # Extract every matching ref on the line (a line may cite more than one summary).
  while IFS= read -r ref; do
    [[ -n "$ref" ]] || continue
    [[ -e "$root/$ref" ]] && continue
    dangling="${dangling}${src#$root/}:$lineno → $ref (missing)"$'\n'
  done < <(printf '%s\n' "$rest" | grep -oE "$ref_re" || true)
done < <(grep -nE "$ref_re" "${sources[@]}" 2>/dev/null || true)

context_rc=0
if [[ -n "$dangling" ]]; then
  printf 'DANGLING .claude/shiploop/validation/*.md reference(s) — a cited evidence summary is missing (#252):\n' >&2
  printf '%s' "$dangling" >&2
  printf 'A migration likely deleted the summary while a live ref still points at it. Restore the file\n' >&2
  printf '(e.g. from the pre-migration commit, `git show <migration>^:<path>`) or fix the reference.\n' >&2
  context_rc=1
fi

# Flow-registry lint matrix (validations feature): logs/-ref, dangling Evidence ref, zero-match glob
# (fail + auto-degrade STALE), asset-size warns, PII scrub. Additive + independent of the context scan
# above; a missing .claude/shiploop/validation/flows.md is a silent no-op. Fail if EITHER lint tripped.
govern::flows_lint "$root"; flows_rc=$?
[[ "$context_rc" -eq 0 && "$flows_rc" -eq 0 ]] && exit 0
exit 1
