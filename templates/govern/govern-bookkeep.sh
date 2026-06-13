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

# Serialize the whole tickets.md read-modify-write + commit. Two concurrent govern drivers
# (parallel sessions on disjoint tickets, #41) would otherwise race the mktemp→mv (lost
# block-delete) and the git index. mkdir-mutex; reclaim if a crashed holder left it >5min.
BK_LOCK="${GOVERN_BOOKKEEP_LOCK:-$GOVERNOR_DIR/.bookkeep.lock}"
govern::lock_acquire "$BK_LOCK" 60 300 || govern::log "bookkeep lock busy >60s — proceeding (degraded)"
trap 'govern::lock_release "$BK_LOCK"' EXIT

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
      # Insert the (possibly multi-line) lesson AFTER the anchor line. Pass the text via a
      # FILE read with getline — NEVER `awk -v t="$text"`: awk's -v cannot hold literal
      # newlines, so multi-line lesson text dies with "awk: newline in string" and the patch
      # silently fails (the resolve then aborts before its commit under set -e).
      tmpf="$(mktemp)"; tf="$(mktemp)"; printf '%s\n' "$text" > "$tf"
      awk -v a="$anchor" -v tf="$tf" '
        index($0,a) && !done { print; print ""; while ((getline line < tf) > 0) print line; close(tf); done=1; next }
        { print }
      ' "$target" > "$tmpf"
      mv "$tmpf" "$target"; rm -f "$tf"
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
