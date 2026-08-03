#!/usr/bin/env bash
# Deterministic PRE-DISPATCH gate — upstream-drift detection. Source, don't execute.
#
# WHY. Every ticket currently costs a full agent session, even when the fix it asks for
# ALREADY EXISTS upstream. This workspace dogfoods the harness as its own sub-repo, so a
# mechanism script under scripts/govern/ (or scripts/worktree/, scripts/lib/, governor/)
# has a template counterpart in the hub, and ANOTHER fleet may have already ported the
# identical fix up. Root CLAUDE.md's "workspace ↔ hub drift" anti-pattern tells a human to
# diff the two before authoring a fresh fix — but nothing ENFORCED it, so a worker could
# burn a whole session re-deriving a fix that was one `/shiploop:update` away.
#
# WHAT THIS DOES. Before spawning, read #N's `**Where:**` / `**Files:**` line, and for each
# named live path ask: is the HUB ahead of us on this exact file? If so, surface it to the
# operator ("port the hub diff down") instead of dispatching a fresh-fix worker.
#
# THE DIRECTION TEST (this is the whole trick — a bare `cmp` is NOT enough). live != tpl
# means the two sides disagree, but says nothing about WHO moved. sync-templates.sh already
# answers that: its marker records the harness commit the templates are synced THROUGH, and
# `--paths` lists exactly the mirrored files this workspace changed since the marker whose
# content still differs from the hub — i.e. unported LOCAL work. So:
#     differs  AND     in --paths  →  WORKSPACE ahead (local work not yet pushed up) → spawn
#     differs  AND NOT in --paths  →  HUB ahead (someone else pushed a fix up)       → surface
# Reusing sync-templates.sh rather than re-deriving the live↔template mapping also means the
# gate inherits every exclusion it already encodes (workspace.sh, runtime artifacts, the
# marker itself), for free.
#
# SAFETY CONTRACT (all four are load-bearing; the tests assert each):
#   1. Deterministic — pure file/git reads. No LLM call, no network, no writes.
#   2. It can never mark a ticket RESOLVED. Its only outcome is "park + escalate to the
#      operator", which is strictly weaker than what a worker could have done.
#   3. FAIL-OPEN everywhere. Missing tool, missing marker, unparseable Where:, unmirrored
#      path, ambiguity of ANY kind → emit nothing → the loop spawns the worker exactly as
#      it does today. A false negative costs one session; a false positive would silently
#      stall a real ticket, so every unknown resolves toward spawning.
#   4. Killable — GOVERN_PREGATE_DRIFT=0 disables it outright.
#
# Scope note: this file implements the upstream-drift half of the pre-gate ONLY. Codemod
# auto-detection is deliberately NOT implemented — see the PR description for the rationale.

# Resolve deps lazily (like lib/valjob.sh) so sourcing order never matters and sourcing this
# file can't abort the caller.
GOVERN_PREGATE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Master kill switch: 0 → the gate is inert (spawn every ticket, pre-gate behavior).
GOVERN_PREGATE_DRIFT="${GOVERN_PREGATE_DRIFT:-1}"

# Live-root prefixes we will even CONSIDER. Narrow by construction: these are the mirrored
# harness areas from sync-templates.sh's scaffold-inverse map. A `**Where:**` naming anything
# else (a product sub-repo, queue/, a doc) is ignored outright, so the gate cannot fire on a
# ticket that has nothing to do with the harness.
GOVERN_PREGATE_PREFIXES="${GOVERN_PREGATE_PREFIXES:-scripts/ governor/ .githooks/ .claude/commands/}"

govern::pregate_sync_tool() { # -> abs path of sync-templates.sh ("" if unavailable)
  local t="${GOVERN_PREGATE_SYNC_TOOL:-$GOVERN_PREGATE_LIB_DIR/../sync-templates.sh}"
  [[ -x "$t" || -f "$t" ]] || return 1
  printf '%s\n' "$t"
}

govern::pregate_live_root() { # -> abs path of the workspace root ("" if undeterminable)
  local r="${GOVERN_PREGATE_LIVE_ROOT:-${WS_ROOT:-}}"
  [[ -n "$r" && -d "$r" ]] || return 1
  printf '%s\n' "$r"
}

# Extract candidate live FILE paths from #N's Where:/Files: line. Unlike
# govern::ticket_paths (which yields MEASURED file paths for batching) this keeps
# the full path — the drift question is per-file. Conservative on purpose: a token must be a
# literal, glob-free, prefix-allowed path, and every filter below drops rather than guesses.
govern::pregate_where_paths() { # N [tickets-file] -> repo-relative paths, one per line
  local n="$1"
  local f="${2:-${TICKETS_FILE:-}}"
  local block line root p
  [[ -n "$f" && -f "$f" ]] || return 0
  root="$(govern::pregate_live_root)" || return 0
  block="$(govern::ticket_block "$n" "$f" 2>/dev/null | tail -n +2)" || return 0
  [[ -n "$block" ]] || return 0
  # Both markers contribute (a ticket may name the mechanism in Where: and the exact file in
  # Files:); dedup happens below.
  line="$(printf '%s\n' "$block" \
    | sed -n -E 's/^[[:space:]]*(-[[:space:]]+)?\*{0,2}([Ww]here|[Ff]iles)(:\*{0,2}|\*{0,2}:)[[:space:]]*//p')"
  [[ -n "$line" ]] || return 0

  printf '%s\n' "$line" | _GV_PREFIXES="$GOVERN_PREGATE_PREFIXES" awk '
    BEGIN{ np=split(ENVIRON["_GV_PREFIXES"], P, /[ ]+/) }
    {
      gsub(/\$[A-Za-z_][A-Za-z0-9_]*/, " ")   # shell interpolations name no real path
      gsub(/[`(),;"]/, " ")
      n=split($0, tok, /[[:space:]]+/)
      for (i=1; i<=n; i++) {
        p=tok[i]
        sub(/^\.\//, "", p); sub(/[.,;:]+$/, "", p); sub(/\/+$/, "", p)
        if (p == "" || p ~ /\*/ || p ~ /\?/ || p ~ /\[/) continue   # literals only — never a glob
        if (p ~ /\.\./) continue                                     # no traversal
        ok=0
        for (j=1; j<=np; j++) if (P[j] != "" && index(p, P[j]) == 1) { ok=1; break }
        if (!ok) continue
        if (!(p in seen)) { seen[p]=1; print p }
      }
    }' \
  | while IFS= read -r p; do
      # Must name a real, regular file in THIS workspace. A path that does not exist locally
      # (renamed, aspirational, a directory) is not something we can diff — drop it.
      [[ -f "$root/$p" ]] && printf '%s\n' "$p"
    done
}

# The set of mirrored files this workspace has changed since the sync marker and that still
# differ from the hub — i.e. unported LOCAL drift. Prints one repo-relative path per line.
# Returns 1 (and prints nothing) whenever the answer is unknowable, which the caller treats
# as "cannot establish direction → fail open".
govern::pregate_unported_paths() { # -> repo-relative paths, one per line
  local tool out
  local rc=0
  tool="$(govern::pregate_sync_tool)" || return 1
  out="$(bash "$tool" --paths 2>/dev/null)" || rc=$?
  [[ "$rc" -eq 0 ]] || return 1
  printf '%s\n' "$out"
}

# THE GATE. Emits one "live<TAB>template" line per Where:-named file the HUB is ahead on.
# rc 0 with output = drift found; rc 1 with no output = nothing to surface (spawn as usual).
govern::pregate_hub_ahead() { # N [tickets-file] -> "live\ttpl" lines
  [[ "${GOVERN_PREGATE_DRIFT:-1}" != "0" ]] || return 1
  local n="$1"
  local f="${2:-${TICKETS_FILE:-}}"
  local tool root unported paths p tpl found=""
  tool="$(govern::pregate_sync_tool)" || return 1
  root="$(govern::pregate_live_root)" || return 1
  paths="$(govern::pregate_where_paths "$n" "$f")"
  [[ -n "$paths" ]] || return 1
  # Direction is established ONCE per ticket. If it cannot be established at all (no marker,
  # no templates root, sync-templates errored) we fail open rather than guess who moved.
  unported="$(govern::pregate_unported_paths)" || return 1

  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    # Unported LOCAL change on this exact file → the workspace is the one that moved. Spawn.
    printf '%s\n' "$unported" | grep -qxF "$p" && continue
    tpl="$(bash "$tool" --counterpart "$p" 2>/dev/null)" || tpl=""
    [[ -n "$tpl" && -f "$tpl" ]] || continue     # not mirrored → nothing upstream to port
    cmp -s "$root/$p" "$tpl" && continue          # identical → in sync
    found+="$p"$'\t'"$tpl"$'\n'
  done <<< "$paths"

  [[ -n "$found" ]] || return 1
  printf '%s' "$found"
}
