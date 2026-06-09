#!/usr/bin/env bash
# Deterministically apply a resolved worker's report (read from stdin) for ticket N:
#   delete the ## #N block, append newTickets (per-queue numbering = this file's max+1),
#   apply a ROOT-level lessonPatch (sub-repo CLAUDE.md lessons ride in the worker's own PR),
#   commit. No Claude context involved. Usage:  printf '%s' "$report" | govern-bookkeep.sh <N>
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$DIR/lib/common.sh"
govern::require jq
N="${1:?ticket number required}"
report="$(cat)"
commit_dir="$(cd "$(dirname "$TICKETS_FILE")" && pwd)"
patched=""

# 1. Delete the ## #N block (heading through its trailing ---).
tmp="$(mktemp)"
awk -v n="$N" '
  $0 ~ "^##[[:space:]]+#" n "([^0-9]|$)" { grab=1 }
  grab && /^---[[:space:]]*$/ { grab=0; next }
  grab { next }
  { print }
' "$TICKETS_FILE" > "$tmp"
mv "$tmp" "$TICKETS_FILE"

# 2. Append newTickets (this file's own highest ## #N + 1, incrementing per item).
maxn="$(grep -oE '^## #[0-9]+' "$TICKETS_FILE" | grep -oE '[0-9]+' | sort -n | tail -1 || true)"; maxn="${maxn:-0}"
count="$(printf '%s' "$report" | jq '.newTickets | length' 2>/dev/null || echo 0)"
i=0
while [[ "$i" -lt "$count" ]]; do
  maxn=$((maxn+1))
  title="$(printf '%s' "$report" | jq -r ".newTickets[$i].title")"
  sev="$(printf '%s' "$report" | jq -r ".newTickets[$i].severity // \"Medium\"")"
  body="$(printf '%s' "$report" | jq -r ".newTickets[$i].body")"
  printf '\n## #%s — %s\n\n**Severity:** %s\n\n%s\n\n---\n' "$maxn" "$title" "$sev" "$body" >> "$TICKETS_FILE"
  i=$((i+1))
done

# 3. Root-level lessonPatch (only files inside commit_dir; never a sub-repo's own git tree).
lp_file="$(printf '%s' "$report" | jq -r '.lessonPatch.file // empty' 2>/dev/null || true)"
if [[ -n "$lp_file" && "$lp_file" != */* ]]; then   # root-level file only (no slash)
  target="$commit_dir/$lp_file"
  if [[ -f "$target" ]]; then
    anchor="$(printf '%s' "$report" | jq -r '.lessonPatch.anchor // empty')"
    text="$(printf '%s' "$report" | jq -r '.lessonPatch.text')"
    if [[ -n "$anchor" ]] && grep -qF "$anchor" "$target"; then
      tmpf="$(mktemp)"
      awk -v a="$anchor" -v t="$text" 'index($0,a) && !done {print; print ""; print t; done=1; next} {print}' "$target" > "$tmpf"
      mv "$tmpf" "$target"
    else
      printf '\n%s\n' "$text" >> "$target"
    fi
    patched="$lp_file"
  fi
fi

# 4. Commit (in the dir holding tickets.md — the main checkout in real use).
pr="$(printf '%s' "$report" | jq -r '(.pr.repo // "?") + "#" + ((.pr.number // 0)|tostring)')"
( cd "$commit_dir"
  git add "$(basename "$TICKETS_FILE")" ${patched:+"$patched"}
  git commit -q -m "docs(tickets): resolve #$N ($pr)" || true
)
echo "bookkept #$N: block deleted; +$count ticket(s); lesson=${patched:-none}; pr=$pr"
