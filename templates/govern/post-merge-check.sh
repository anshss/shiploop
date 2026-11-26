#!/usr/bin/env bash
# post-merge-check.sh: the merged-ref gate behind "landed".
#
# Worktree-green is not merged-green when PRs stack: each PR's CI ran on ITS OWN branch base, so a
# squash-merge can silently resolve a stacked conflict to the stale-base side and drop the other
# PR's lines (the stacked-PR clobber). CI on the branches says nothing about the tree a merge
# PRODUCES. This script runs a configurable check command against the POST-MERGE ref (freshly
# fetched origin/main, in a throwaway detached worktree) so the resolve path can refuse to bookkeep
# "landed" on a merged-but-broken main.
#
# Usage:  post-merge-check.sh <repo> <pr>          (the <pr> arg is only used in messages)
#
# Configuration:
#   GOVERN_POST_MERGE_GATE   1 (default) = gate on; 0 = always pass. Kill switch.
#   GOVERN_POST_MERGE_CMD    the check command, run with cwd = a fresh temp checkout of merged
#                            origin/main. Empty (default) = gate ARMED but INERT — there is nothing
#                            to run, so the gate passes with a note. Set it to turn the gate on
#                            (workspace.sh seeds the value; note a fresh temp checkout has no
#                            node_modules, so prefer a dependency-free command or have the command
#                            install/point at deps).
#   GOVERN_LABS_FILE         export-only: if eval/labs/select.js exists in the temp checkout, this
#                            script selects the lab set from the merged sha's FIRST-PARENT diff and
#                            hands the file to $CMD via this variable (empty/unset = run the full
#                            suite). The first-parent diff is used because the PR branch does not
#                            exist at gate time and first-parent survives squash and fast-forward
#                            merges; select.js owns every forced-full rule (gate machinery,
#                            fixtures, an explicit full request) and over-selects by design. A
#                            missing or failing selector falls back to the full suite: failing
#                            toward MORE labs is the safe direction. A $CMD that never reads the
#                            variable is unaffected.
#   GOVERN_POST_MERGE_LABS_SELECT  selector override: a shell command REPLACING the conventional
#                            eval/labs/select.js lookup, for repos that select labs without node.
#                            It runs in the temp checkout with cwd = checkout root, with
#                            `--changed <changed-files.txt>` APPENDED to the command string (so a
#                            bare `bash tools/resolve-labs-select.sh` works as-is), and its stdout
#                            (selected lab/test names, one per line) is what the CMD receives.
#                            Unset (default) = the node path above, byte-for-byte. A failing
#                            override falls back to the full suite (the safe direction), exactly
#                            like a failing node selector.
#   GOVERN_ECHO=1            print what would run, touch nothing, exit 0 (dry-run convention).
#   GOVERN_POST_MERGE_CACHE  1 (default) = reuse a recorded PASS verdict when repo, merged sha and
#                            the full check-command key (cmd + labs selector + env-strip config)
#                            all match and the record is younger than the TTL; a landing batch
#                            resolves several PRs against the SAME merged ref, and re-proving an
#                            unchanged ref is duplicated wall clock. 0 = always run the gate in
#                            full. PASSes only are ever recorded; any mismatch, expiry or corrupt
#                            record runs the gate exactly as before.
#   GOVERN_POST_MERGE_CACHE_TTL  seconds a recorded PASS stays reusable (default 1800, sized to one
#                            landing batch whose resolves land minutes apart).
#   GOVERN_GATE_ENV_STRIP    comma-separated extra VARIABLE PREFIXES (no spaces, e.g. AWS_,STRIPE_)
#                            stripped from the check command's environment on top of the fixed
#                            GOVERN_/WSP_ strip. A workspace whose own knobs live under another
#                            prefix lists that prefix here.
#
# Child-env sanitization: the check command must prove MERGED MAIN, not "merged main as seen
# through whatever env the session calling the resolve happened to carry". Every GOVERN_*/WSP_*
# variable (kill switches included) and any GOVERN_GATE_ENV_STRIP prefix is removed from the
# env the check command receives; this script's OWN knob reads (gate/cmd/echo/cache knobs) keep
# coming from the parent env untouched. GOVERN_LABS_FILE is the one deliberate handoff, exported to
# the child only when a selector actually produced labs (empty and unset both mean "full suite",
# the documented contract), so a no-selection gate child sees zero stripped-namespace vars at all.
#
# Exit codes:
#   0   passed (or gate off, or no command configured)
#   7   the check command FAILED on the merged ref — caller must NOT bookkeep "landed"
#   8   could not build a trustworthy merged checkout (fetch failure / missing ref / worktree
#       add failed) — FAIL-CLOSED: an unverifiable merged ref never counts as a pass
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib/common.sh"

REPO="${1:?repo required}"
PR="${2:-}"

if [[ "${GOVERN_POST_MERGE_GATE:-1}" != "1" ]]; then
  govern::log "post-merge-check: GOVERN_POST_MERGE_GATE=0 — gate off, passing"
  exit 0
fi
# Per-repo check command: workspace.sh may define wsp_post_merge_cmd() (a case on the repo name,
# e.g. the meta repo's bash -n sweep vs a sub-repo's lab gate); fall back to the global knob.
if declare -F wsp_post_merge_cmd >/dev/null 2>&1; then
  CMD="$(wsp_post_merge_cmd "$REPO")"
else
  CMD="${GOVERN_POST_MERGE_CMD:-}"
fi
if [[ -z "$CMD" ]]; then
  govern::log "post-merge-check: GOVERN_POST_MERGE_CMD empty — gate armed but inert (nothing to run), passing"
  exit 0
fi

localdir="$(govern::repo_localdir "$REPO")"
if ! { [[ -d "$localdir/.git" ]] || [[ -f "$localdir/.git" ]]; }; then
  echo "[govern ERROR] post-merge-check: no checkout of '$REPO' at $localdir to resolve the merged ref through" >&2
  exit 8
fi

if [[ "${GOVERN_ECHO:-0}" == "1" ]]; then
  printf 'WOULD RUN (post-merge check on %s merged main): %s\n' "$REPO" "$CMD"
  exit 0
fi

# Resolve the merged ref through a FRESH fetch — the whole point is to check what origin/main is
# NOW, post-merge, not what some checkout last saw. A fetch failure is exit 8 (fail-closed), never
# a silent pass.
if ! git -C "$localdir" fetch --quiet --prune origin main >/dev/null 2>&1; then
  echo "[govern ERROR] post-merge-check: fetch of origin main failed for $REPO — cannot verify the merged ref" >&2
  exit 8
fi
sha="$(git -C "$localdir" rev-parse --verify origin/main)" || {
  echo "[govern ERROR] post-merge-check: no origin/main ref on $REPO after fetch" >&2
  exit 8
}

# ── PASS reuse: a recorded PASS for THIS (repo, merged sha, check-command key) within the TTL is
# reused instead of re-proving an unchanged ref (a landing batch resolves several PRs against the
# same merged main; measured 2026-11-25: two full gates, ~15-20 min, against one merged sha). The
# command key hashes the resolved cmd plus the labs-selector and env-strip knobs, the two parent
# settings that change what the child actually runs or sees, so a changed knob can never reuse a
# verdict recorded under the old one. One record per repo in governor/.post-merge-cache/ (runtime
# state, gitignored). PASSes only are ever recorded, and a mismatched, expired or corrupt record
# is IGNORED, never trusted: the only thing a stale entry can do is fail to apply.
CACHE_ENABLED=1
[[ "${GOVERN_POST_MERGE_CACHE:-1}" == "0" ]] && CACHE_ENABLED=0
cmdhash="$(printf '%s\0%s\0%s' "$CMD" "${GOVERN_POST_MERGE_LABS_SELECT:-}" "${GOVERN_GATE_ENV_STRIP:-}" \
  | { shasum -a 256 2>/dev/null || sha256sum 2>/dev/null; } | awk '{print $1}')"
cachefile="$GOVERNOR_DIR/.post-merge-cache/$REPO"
if [[ "$CACHE_ENABLED" == "1" && -s "$cachefile" ]]; then
  cline="$(cat "$cachefile" 2>/dev/null || true)"
  read -r c_sha c_hash c_ts _crest <<<"$cline" || true
  now="$(date +%s)"
  ttl="${GOVERN_POST_MERGE_CACHE_TTL:-1800}"
  if [[ "$c_sha" == "$sha" && "$c_hash" == "$cmdhash" && "$c_ts" =~ ^[0-9]+$ ]] \
     && (( now - c_ts >= 0 && now - c_ts < ttl )); then
    cached_at="$(date -r "$c_ts" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -d "@$c_ts" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf '%ss' "$c_ts")"
    govern::log "post-merge-check: reuse PASS on $sha (cached at $cached_at)"
    exit 0
  fi
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/govern-post-merge-check.XXXXXX")"
cleanup() {
  git -C "$localdir" worktree remove --force "$tmp/check" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT

if ! git -C "$localdir" worktree add --detach "$tmp/check" "$sha" >/dev/null 2>&1; then
  echo "[govern ERROR] post-merge-check: could not materialize merged main ($sha) for $REPO at $tmp/check" >&2
  exit 8
fi

# Lab selection (see GOVERN_LABS_FILE above): select the lab set from the merged sha's
# FIRST-PARENT diff (the PR branch does not exist at gate time; first-parent survives squash and
# fast-forward merges). GOVERN_POST_MERGE_LABS_SELECT replaces the conventional node selector with
# any shell command; unset, the eval/labs/select.js lookup applies unchanged (a fleet with neither
# selector configured sees no selection at all). Selector missing or failing leaves the file empty
# = full suite: failing toward MORE labs is the safe direction.
labsfile=""
SEL="${GOVERN_POST_MERGE_LABS_SELECT:-}"
if [ -n "$SEL" ]; then
  git -C "$tmp/check" diff --name-only "${sha}^1" "$sha" > "$tmp/changed.txt" 2>/dev/null || true
  if ( cd "$tmp/check" && eval "$SEL" --changed "$tmp/changed.txt" \
       > "$tmp/labs.txt" 2> "$tmp/select.log" ); then
    labsfile="$tmp/labs.txt"
    govern::log "post-merge-check: lab selection: $(tr '\n' ' ' < "$tmp/labs.txt")"
  else
    govern::log "post-merge-check: selector failed; falling back to the full lab suite"
  fi
elif [ -f "$tmp/check/eval/labs/select.js" ]; then
  git -C "$tmp/check" diff --name-only "${sha}^1" "$sha" > "$tmp/changed.txt" 2>/dev/null || true
  if ( cd "$tmp/check" && node eval/labs/select.js --changed "$tmp/changed.txt" \
       > "$tmp/labs.txt" 2> "$tmp/select.log" ); then
    labsfile="$tmp/labs.txt"
    govern::log "post-merge-check: lab selection: $(tail -n 1 "$tmp/select.log")"
  else
    govern::log "post-merge-check: selector failed; falling back to the full lab suite"
  fi
fi

govern::log "post-merge-check: running GOVERN_POST_MERGE_CMD on merged $REPO main ($sha)${PR:+, PR #$PR}"
# Namespaces stripped from the CHILD env only (see "Child-env sanitization" in the header): this
# script's own knobs above were already read from the parent env; the check command must not see
# the calling session's.
strip_re='GOVERN_|WSP_'
if [[ -n "${GOVERN_GATE_ENV_STRIP:-}" ]]; then
  strip_re="${GOVERN_GATE_ENV_STRIP//,/|}|$strip_re"
fi
stripped_n="$(env | grep -cE "^(${strip_re})" || true)"
govern::log "post-merge-check: sanitized gate child env (stripped $stripped_n var(s) matching ${strip_re})"
if (
  cd "$tmp/check"
  sargs=()
  while IFS= read -r sv; do
    [[ "$sv" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    sargs+=(-u "$sv")
  done < <(env | grep -E "^(${strip_re})" | cut -d= -f1)
  if [[ -n "$labsfile" ]]; then
    env ${sargs[@]+"${sargs[@]}"} GOVERN_LABS_FILE="$labsfile" bash -c "$CMD"
  else
    env ${sargs[@]+"${sargs[@]}"} bash -c "$CMD"
  fi
); then
  govern::log "post-merge-check: PASS on merged ref ($sha)"
  if [[ "$CACHE_ENABLED" == "1" ]] && mkdir -p "$GOVERNOR_DIR/.post-merge-cache" 2>/dev/null; then
    cache_tmp="$(mktemp "$GOVERNOR_DIR/.post-merge-cache/${REPO}.XXXXXX" 2>/dev/null || true)"
    if [[ -n "$cache_tmp" ]] && printf '%s %s %s\n' "$sha" "$cmdhash" "$(date +%s)" >"$cache_tmp" 2>/dev/null; then
      mv -f "$cache_tmp" "$cachefile" 2>/dev/null || rm -f "$cache_tmp" 2>/dev/null || true
    fi
  fi
  exit 0
else
  rc=$?
  govern::log "post-merge-check: FAIL (rc=$rc) on merged $REPO main ($sha): $CMD"
  exit 7
fi
