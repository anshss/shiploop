#!/usr/bin/env bash
# staleness-gate.sh — kill already-dead tickets BEFORE they cost a worker.
#
# Why: the queue is partly machine-generated, so it accumulates duplicates and entries whose subject
# was already fixed by some other ticket's PR. Discovering that today costs a FULL worker spawn —
# 100% waste, not a factor, and it multiplies against every other saving in the loop.
#
# Why bash-only, no model fallback: a probabilistic "is this still relevant?" judgement that is wrong
# in the STALE direction silently deletes real work, and the loop would never learn it happened. So
# this gate is deterministic and hard fail-OPEN: it reports stale ONLY on POSITIVE evidence, and every
# inconclusive case — no paths named, a path it cannot resolve, no test command, a timeout, a missing
# helper — dispatches. Zero `claude` invocations, by design.
#
# Positive evidence, either of:
#   (a) every path the ticket names is GONE from disk, and git history proves at least one of them
#       once existed (so a typo'd path can never masquerade as a deleted one), or
#   (b) the ticket names a failing test command and that command now PASSES.
#
# Usage:  staleness-gate.sh <N>
# Exit:   0  → dispatch (this includes EVERY inconclusive case)
#         10 → confidently stale, skip
#         2  → usage error (callers must treat any non-10 exit as dispatch)
# Stdout: exactly one line — the verdict and the evidence for it.
#
# Env:
#   GOVERN_STALENESS_GATE=0|1        0 (DEFAULT) = disabled, always prints "dispatch" and exits 0.
#                                    The gate ships inert; enabling it is a deliberate act.
#   GOVERN_STALENESS_RUN_TESTS=0|1   0 (DEFAULT) = never execute a test command read out of the queue
#                                    file. Separate from the gate switch on purpose: the path check
#                                    only stat()s, this executes. tickets.md is partly machine-written.
#   GOVERN_STALENESS_TEST_TIMEOUT=90 seconds bound on the test-command probe.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$DIR/lib/common.sh"

N="${1:-}"
[[ "$N" =~ ^[0-9]+$ ]] || { echo "usage: staleness-gate.sh <ticket-number>" >&2; exit 2; }

TEST_TIMEOUT="${GOVERN_STALENESS_TEST_TIMEOUT:-90}"
[[ "$TEST_TIMEOUT" =~ ^[0-9]+$ ]] || TEST_TIMEOUT=90

# Kill switch. Default OFF: the gate ships inert so adopting it is opt-in per fleet.
if [[ "${GOVERN_STALENESS_GATE:-0}" != "1" ]]; then
  printf 'dispatch #%s: staleness gate disabled (GOVERN_STALENESS_GATE=0)\n' "$N"
  exit 0
fi

# govern::ticket_block is the SINGLE canonical parser — block boundary is the next
# `^##[[:space:]]+#[0-9]+` heading, NOT a bare `---` (a `---` inside a body is content).
BLOCK="$(govern::ticket_block "$N" 2>/dev/null || printf '')"
if [[ -z "$BLOCK" ]]; then
  printf 'dispatch #%s: inconclusive — ticket block not found in %s\n' "$N" "$TICKETS_FILE"
  exit 0
fi

# ── candidate paths ─────────────────────────────────────────────────────────────────────────────

# Pull path-shaped tokens out of a line. A token qualifies only if it contains a `/` AND either has a
# file extension or ends in `/` — this is what stops prose ("the worker prompt") from being read as a
# path and manufacturing fake evidence. Backticks/quotes/commas/parens are stripped.
sg::paths_from_line() { # <line>
  # tr -c: everything that is NOT a path character becomes a separator. Complement form avoids
  # hand-listing quotes/backticks/parens and the quoting gymnastics that comes with them.
  printf '%s\n' "$1" \
    | tr -c 'A-Za-z0-9_./@+-' '\n' \
    | sed -E 's/[.,;:-]+$//' \
    | grep -E '^[A-Za-z0-9_.@-]+(/[A-Za-z0-9_.@+-]+)+(/)?$' \
    | grep -E '(\.[A-Za-z0-9]+$|/$)' \
    | sort -u || true
  return 0
}

CANDIDATES="$(mktemp "${TMPDIR:-/tmp}/govern-staleness.XXXXXX")"
SG_TEST_OUT="$(mktemp "${TMPDIR:-/tmp}/govern-staleness-test.XXXXXX")"
trap 'rm -f "$CANDIDATES" "$CANDIDATES.tmp" "$SG_TEST_OUT" 2>/dev/null || true' EXIT INT TERM HUP

# 1. The scout's MEASURED targetPaths, when a scout cache exists. This is the highest-quality source
#    (it verified the paths against the real tree). `--paths` is cache-READ only — no model call —
#    and returns rc 1 when it has nothing. Tolerate the script being absent or failing entirely.
scout_paths=""
if [[ -x "$DIR/scout-ticket.sh" ]]; then
  scout_paths="$("$DIR/scout-ticket.sh" --paths "$N" 2>/dev/null || printf '')"
fi
[[ -n "$scout_paths" ]] && printf '%s\n' "$scout_paths" >> "$CANDIDATES"

# 2. The ticket's own **Files:** / **Where:** lines (bold or plain, list-marker tolerant — the queue
#    contains both `**Where:** …` and bare `Where: …`).
while IFS= read -r line; do
  case "$line" in
    *[Ff]iles:*|*[Ww]here:*) sg::paths_from_line "$line" >> "$CANDIDATES" ;;
  esac
done <<< "$BLOCK"

# Dedup, drop blanks. (grep + mv, not `sed -i` — the in-place flag's suffix handling differs between
# BSD and GNU sed and CI is Linux while dev machines are macOS.)
{ grep -v '^[[:space:]]*$' "$CANDIDATES" 2>/dev/null | sort -u > "$CANDIDATES.tmp" || true; }
mv "$CANDIDATES.tmp" "$CANDIDATES" 2>/dev/null || true

# ── resolution ──────────────────────────────────────────────────────────────────────────────────

# A ticket path may be workspace-relative (`shiploop/templates/govern/x.sh`) or repo-relative
# (`templates/govern/x.sh`). Probe the workspace root and every sub-repo root. Echo the resolved
# absolute path on success.
sg::resolve() { # <rel-path> -> abs | nonzero
  local p="$1"
  local r root stripped
  p="${p%/}"
  if [[ -e "$WS_ROOT/$p" ]]; then printf '%s\n' "$WS_ROOT/$p"; return 0; fi
  stripped="${p#*/}"
  for r in ${REPOS[@]+"${REPOS[@]}"}; do
    root="$(wsp_repo_localdir "$r" 2>/dev/null || printf '%s/%s' "$WS_ROOT" "$r")"
    if [[ -e "$root/$p" ]]; then printf '%s\n' "$root/$p"; return 0; fi
    # `<repo>/a/b.ts` written workspace-relative but the repo checkout lives elsewhere → retry with
    # the leading component stripped.
    if [[ "$p" == "$r/"* && -e "$root/$stripped" ]]; then printf '%s\n' "$root/$stripped"; return 0; fi
  done
  return 1
}

# Did git ever know this path? A `git log -- <path>` hit proves the path was REAL and is now gone —
# without it, a missing path is just as likely a typo, which must stay inconclusive.
sg::git_knew() { # <rel-path>
  local p="$1"
  local r root stripped roots=("$WS_ROOT")
  p="${p%/}"
  stripped="${p#*/}"
  for r in ${REPOS[@]+"${REPOS[@]}"}; do
    roots+=("$(wsp_repo_localdir "$r" 2>/dev/null || printf '%s/%s' "$WS_ROOT" "$r")")
  done
  for root in "${roots[@]}"; do
    [[ -d "$root" ]] || continue
    git -C "$root" rev-parse --git-dir >/dev/null 2>&1 || continue
    if [[ -n "$(git -C "$root" log --oneline -1 -- "$p" 2>/dev/null || printf '')" ]]; then return 0; fi
    if [[ "$stripped" != "$p" \
       && -n "$(git -C "$root" log --oneline -1 -- "$stripped" 2>/dev/null || printf '')" ]]; then return 0; fi
  done
  return 1
}

total=0; missing=0; alive_example=""; gone_known=0; gone_example=""
while IFS= read -r p; do
  [[ -n "$p" ]] || continue
  total=$((total + 1))
  if sg::resolve "$p" >/dev/null 2>&1; then
    [[ -z "$alive_example" ]] && alive_example="$p"
  else
    missing=$((missing + 1))
    if sg::git_knew "$p"; then gone_known=1; [[ -z "$gone_example" ]] && gone_example="$p"; fi
  fi
done < "$CANDIDATES"

if [[ "$total" -gt 0 && "$missing" -eq "$total" && "$gone_known" -eq 1 ]]; then
  printf 'STALE #%s: all %s named path(s) are gone from disk and git history shows `%s` once existed (deleted) — skipping\n' \
    "$N" "$total" "$gone_example"
  exit 10
fi

# ── test-command probe ──────────────────────────────────────────────────────────────────────────

# Only a line that explicitly labels itself a test/repro command is eligible — we never scrape an
# arbitrary backticked string and execute it.
TEST_CMD=""
while IFS= read -r line; do
  case "$line" in
    *[Tt]est\ command:*|*[Tt]est:*|*[Rr]epro:*|*[Ff]ailing\ test:*) ;;
    *) continue ;;
  esac
  # The command must be backticked; a prose sentence is not runnable.
  cand="$(printf '%s\n' "$line" | sed -nE 's/.*`([^`]+)`.*/\1/p' | head -n1)"
  if [[ -n "$cand" ]]; then TEST_CMD="$cand"; break; fi
done <<< "$BLOCK"

# SEPARATE opt-in from GOVERN_STALENESS_GATE, deliberately. The path-existence half of this gate only
# ever stat()s files; this half executes a command string lifted out of `tickets.md`. The queue is
# partly MACHINE-generated (workers file their own `newTickets[]`, and govern-improve-triage.sh files
# harness proposals), so "enable the cheap staleness check" must not silently also mean "execute
# whatever ended up backticked in a queue entry". Two knobs, two decisions.
if [[ -n "$TEST_CMD" && "${GOVERN_STALENESS_RUN_TESTS:-0}" != "1" ]]; then
  printf 'dispatch #%s: inconclusive — %s path(s) still present; test probe skipped (GOVERN_STALENESS_RUN_TESTS=0, will not execute `%s` from the queue)\n' \
    "$N" "$((total - missing))" "$TEST_CMD"
  exit 0
fi

if [[ -n "$TEST_CMD" ]]; then
  TIMEOUT_BIN=""
  for c in timeout gtimeout; do
    if command -v "$c" >/dev/null 2>&1; then TIMEOUT_BIN="$c"; break; fi
  done
  if [[ -z "$TIMEOUT_BIN" ]]; then
    printf 'dispatch #%s: inconclusive — %s path(s) still present; test probe skipped (no timeout(1) to bound `%s`)\n' \
      "$N" "$((total - missing))" "$TEST_CMD"
    exit 0
  fi
  set +e
  ( cd "$WS_ROOT" && "$TIMEOUT_BIN" "$TEST_TIMEOUT" bash -c "$TEST_CMD" ) >"$SG_TEST_OUT" 2>&1
  trc=$?
  set -e
  # 124 = timed out (GNU + coreutils convention), 126/127 = not executable / not found. All three are
  # ambiguity, not evidence.
  if [[ "$trc" -eq 0 ]]; then
    printf 'STALE #%s: the ticket'"'"'s named failing test `%s` now PASSES (exit 0) — skipping\n' "$N" "$TEST_CMD"
    exit 10
  fi
  printf 'dispatch #%s: test `%s` still exits %s; %s/%s named path(s) present — not stale\n' \
    "$N" "$TEST_CMD" "$trc" "$((total - missing))" "$total"
  exit 0
fi

if [[ "$total" -eq 0 ]]; then
  printf 'dispatch #%s: inconclusive — ticket names no resolvable path and no test command\n' "$N"
  exit 0
fi

printf 'dispatch #%s: %s/%s named path(s) still present (e.g. `%s`) — not stale\n' \
  "$N" "$((total - missing))" "$total" "${alive_example:-$gone_example}"
exit 0
