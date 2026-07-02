#!/usr/bin/env bash
# Lint for DANGLING `.claude/context/validation/*.md` references (#252). The committed validation
# sink is cited as proof by founder-os context (`features.md` / `direction.md` / `product.md`) and
# the root `CLAUDE.md`. A founder-os layout migration that DELETES a summary while live refs still
# point at it → dangling proof. This is the cheap backstop: scan the pillar-claim files for any
# `.claude/context/validation/<name>.md` reference and FAIL if the referenced file is missing, so a
# migration can't silently orphan the evidence a claim rests on.
#
# Prints each "<source>:<line> → <missing target>" to stderr and exits 1 if any ref dangles; silent
# + exit 0 when every ref resolves. Wire into the Stop hook beside the other lint passes.
#
# Usage: scripts/govern/lint-validation-refs.sh [meta-root]   (defaults to the governor meta-root)
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$DIR/lib/common.sh"

root="${1:-$(govern::meta_root)}"
vdir="$root/.claude/context/validation"

# Files that may cite a validation summary: the founder-os context tree + the root CLAUDE.md and its
# optional on-demand appendix (some workspaces tier the CLAUDE.md forensics — which carry the
# citations — into a CLAUDE-APPENDIX.md; scan both, guarded on existence, so moving a citation there
# keeps it linted).
sources=()
[[ -f "$root/CLAUDE.md" ]] && sources+=("$root/CLAUDE.md")
[[ -f "$root/CLAUDE-APPENDIX.md" ]] && sources+=("$root/CLAUDE-APPENDIX.md")
if [[ -d "$root/.claude/context" ]]; then
  while IFS= read -r f; do sources+=("$f"); done \
    < <(find "$root/.claude/context" -type f -name '*.md' 2>/dev/null)
fi
[[ ${#sources[@]} -eq 0 ]] && exit 0

# A reference is the literal path `.claude/context/validation/<name>.md`. The charset deliberately
# EXCLUDES `<`, `*`, `(`, `)` so doc placeholders/globs (`ticket-<N>-*.md`, `.../*.md`) never match.
ref_re='\.claude/context/validation/[A-Za-z0-9._-]+\.md'
dangling=""
while IFS= read -r hit; do
  [[ -n "$hit" ]] || continue
  src="${hit%%:*}"; rest="${hit#*:}"; lineno="${rest%%:*}"
  # Extract every matching ref on the line (a line may cite more than one summary).
  while IFS= read -r ref; do
    [[ -n "$ref" ]] || continue
    base="${ref#.claude/context/validation/}"
    [[ -e "$vdir/$base" ]] && continue
    dangling="${dangling}${src#$root/}:$lineno → $ref (missing)"$'\n'
  done < <(printf '%s\n' "$rest" | grep -oE "$ref_re" || true)
done < <(grep -nE "$ref_re" "${sources[@]}" 2>/dev/null || true)

if [[ -z "$dangling" ]]; then exit 0; fi
printf 'DANGLING .claude/context/validation/*.md reference(s) — a cited evidence summary is missing (#252):\n' >&2
printf '%s' "$dangling" >&2
printf 'A migration likely deleted the summary while a live ref still points at it. Restore the file\n' >&2
printf '(e.g. from the pre-migration commit, `git show <migration>^:<path>`) or fix the reference.\n' >&2
exit 1
