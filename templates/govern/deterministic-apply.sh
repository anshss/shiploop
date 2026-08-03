#!/usr/bin/env bash
# deterministic-apply.sh — resolve a ticket with ZERO model turns.
#
# Why this exists: the largest arbitrage in the harness is not opus→sonnet (5×) or sonnet→haiku (4×),
# it is model→NO model, which is unbounded. A real share of any backlog is mechanical — flip a
# default, add a key, bump a version, delete a stale line, apply a known rename. The scout ALREADY
# runs and ALREADY greps real code, so the patch for those tickets is a FIELD ON AN EXISTING CALL
# (scout-ticket.sh's `deterministic` object), not a new one. This script consumes that cached field,
# applies it, verifies it, and opens the PR — spending zero model turns on the fix.
#
# THERE IS NO `claude` INVOCATION IN THIS FILE, AND THERE MUST NEVER BE ONE. Adding one deletes the
# entire reason the script exists; the diff is grepped for it.
#
# DOCTRINE — every doubt resolves to exit 10. This is a pure optimization sitting in FRONT of the
# normal worker: falling through costs exactly one ordinary worker, which is the status quo, while
# applying a wrong patch costs far more than a worker (a bad PR, a wasted CI cycle, and a human's
# attention). So the guards below are deliberately over-strict and each one exits 10 rather than
# trying to recover:
#   - kill switch off, or no cached scout survey, or `kind` empty, or `diff` empty
#   - the patch renames files, is binary, or touches > GOVERN_DETERMINISTIC_MAX_FILES files
#   - any patched path is OUTSIDE the scout's measured, verified `targetPaths`
#   - the patch spans more than one sub-repo, or a path that is not under a known sub-repo
#   - the target sub-repo is dirty, or is not on its default branch
#   - a worktree for this ticket already exists (a prior attempt is mid-flight — not our lane)
#   - `git apply --check` fails
#   - no verify command is configured, or the verify command fails
#
# Contract:
#   deterministic-apply.sh [--dry-run] <N>
#     exit 0  → resolved with zero model turns; a worker-shaped report JSON is on STDOUT.
#               It carries `"zeroModel": true` — the marker the loop counts.
#     exit 10 → not applicable / not confidently deterministic. Caller falls through to a worker.
#     other   → error. Caller falls through to a worker.
#   STDOUT carries the report and NOTHING else; all narration goes to stderr via govern::log.
#
# Env knobs:
#   GOVERN_DETERMINISTIC=0|1            0 (DEFAULT) = disabled; the script exits 10 immediately and
#                                       ships inert. Nothing on the dispatch path changes until an
#                                       operator opts in.
#   GOVERN_DETERMINISTIC_MAX_FILES=3    more files than this is not "mechanical" → exit 10.
#   GOVERN_DETERMINISTIC_VERIFY_CMD=""  the verification command, run inside the patched sub-repo.
#                                       Deliberately OPERATOR-SUPPLIED: the scout's `testCommand` is
#                                       UNTRUSTED MODEL OUTPUT, and executing it here would be
#                                       arbitrary code execution sourced from a model reply. This
#                                       script never runs a command a model wrote.
#   GOVERN_DETERMINISTIC_VERIFY_REQUIRED=1  1 (default) = no verify command configured ⇒ exit 10
#                                       (an unverified auto-patch is exactly the risk). 0 = allow the
#                                       unverified path; the report then says verified:false.
#   GOVERN_MODE=live|dry, --dry-run     do everything except push + open the PR.
#   GOVERN_WORKTREE_CMD                 test seam: takes a slug, prints a worktree path (as spawn-worker).
#   GOVERN_AUTONOMY                     observe → draft PR · pr-only/auto → normal PR (never merges here).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib/common.sh"
govern::require jq
govern::require git

DET_SKIP=10
DET_TMP=""
# Cleanup on EVERY exit path — normal, error, signal.
trap '[[ -n "$DET_TMP" ]] && rm -rf "$DET_TMP" 2>/dev/null; true' EXIT INT TERM HUP

# The one way out. Never returns.
det::skip() { # <reason>
  govern::log "deterministic #${N:-?}: NOT APPLICABLE — $1 (falling through to a normal worker)"
  exit "$DET_SKIP"
}

# ── argument parsing ────────────────────────────────────────────────────────────────────────────
# NB: every conditional here is a full `if`, never a bare `[[ … ]] && x`. At top level under `set -e`
# a false bare conditional is the script's exit status and aborts it silently.
DRY=0
if [[ "${GOVERN_MODE:-live}" == "dry" ]]; then DRY=1; fi
if [[ "${1:-}" == "--dry-run" ]]; then DRY=1; shift; fi
N="${1:?ticket number required}"
[[ "$N" =~ ^[0-9]+$ ]] || govern::die "ticket number must be numeric, got '$N'"

# ── kill switch (checked FIRST, before any work at all) ─────────────────────────────────────────
if [[ "${GOVERN_DETERMINISTIC:-0}" != "1" ]]; then
  govern::log "deterministic #$N: disabled (GOVERN_DETERMINISTIC=${GOVERN_DETERMINISTIC:-0}) — no-op"
  exit "$DET_SKIP"
fi

MAX_FILES="${GOVERN_DETERMINISTIC_MAX_FILES:-3}"
[[ "$MAX_FILES" =~ ^[0-9]+$ ]] || MAX_FILES=3

# ── helpers ─────────────────────────────────────────────────────────────────────────────────────
# Paths touched by a unified diff, deduped. Reads the `---`/`+++` headers only; /dev/null (add or
# delete) is dropped, and a leading a//b/ is stripped. Deliberately OVER-collects (a body line that
# happens to start with `+++ ` is counted too) — over-collecting can only push us toward exit 10,
# which is the safe direction.
det::diff_paths() { # <patchfile> -> paths, one per line
  awk '
    /^(---|\+\+\+) / {
      p = substr($0, index($0, " ") + 1)
      sub(/\t.*$/, "", p)
      if (p == "/dev/null" || p == "") next
      sub(/^[ab]\//, "", p)
      if (p != "") print p
    }' "$1" | sort -u
  return 0
}

# Is <path> covered by the scout's measured targetPaths? The scout's prompt calls them repo-relative
# while its findings block calls them workspace-relative, so accept EITHER reading: exact match, or
# one is a path-suffix of the other. Anything else is outside the measured surface → the caller skips.
det::path_allowed() { # <diff-path> <target-paths-newline-separated>
  local p="$1" targets="$2" t
  while IFS= read -r t; do
    t="${t#./}"; t="${t%/}"
    [[ -n "$t" ]] || continue
    if [[ "$p" == "$t" || "$p" == */"$t" || "$t" == */"$p" ]]; then return 0; fi
  done <<< "$targets"
  return 1
}

# The sub-repo owning a workspace-relative path = its first component, and only if that names a
# real sub-repo. "" (rc 1) otherwise — a root-level path (scripts/, queue/) is NOT a PR lane.
det::repo_for_path() { # <path> -> repo | rc 1
  local p="$1" head r
  head="${p%%/*}"
  [[ -n "$head" && "$head" != "$p" ]] || return 1
  for r in "${REPOS[@]}"; do
    if [[ "$head" == "$r" ]]; then printf '%s' "$r"; return 0; fi
  done
  return 1
}

# ── 1. the cached deterministic verdict (cache read only — no model call) ───────────────────────
DET_JSON=""
DET_JSON="$("$DIR/scout-ticket.sh" --deterministic "$N" 2>/dev/null || true)"
[[ -n "$DET_JSON" ]] || det::skip "the scout has no cached deterministic verdict for this ticket"

DET_KIND="$(printf '%s' "$DET_JSON" | jq -r '.kind // ""' 2>/dev/null || true)"
DET_WHY="$(printf '%s' "$DET_JSON" | jq -r '.rationale // ""' 2>/dev/null || true)"
[[ -n "$DET_KIND" ]] || det::skip "scout kind is empty (= not deterministic)"

DET_TMP="$(mktemp -d "${TMPDIR:-/tmp}/govern-deterministic.XXXXXX")"
PATCH="$DET_TMP/patch.diff"
# `jq -j` (join-output), NOT `jq -r` and NEVER `$(...)`: a command substitution strips the diff's
# trailing newline and `git apply` cares about it, while `jq -r` would ADD one on top of the diff's
# own. -j reproduces the cached bytes EXACTLY; the guard below only appends a newline when the diff
# genuinely lacks one, so a well-formed patch is byte-identical to what the scout cached.
printf '%s' "$DET_JSON" | jq -j '.diff // ""' > "$PATCH" 2>/dev/null || true
[[ -s "$PATCH" ]] || det::skip "scout diff is empty"
if [[ "$(tail -c 1 "$PATCH" | od -An -tx1 | tr -d ' \n')" != "0a" ]]; then
  printf '\n' >> "$PATCH"
  govern::log "deterministic #$N: cached diff had no trailing newline — appended one for git apply"
fi
# Test seam (underscore-prefixed = NOT a public knob): copy the extracted patch out so a test can
# assert BYTE-EXACTNESS against the cached diff, trailing newline included.
if [[ -n "${_GOVERN_DET_PATCH_COPY:-}" ]]; then cp "$PATCH" "$_GOVERN_DET_PATCH_COPY" 2>/dev/null || true; fi

# ── 2. shape guards on the patch itself ─────────────────────────────────────────────────────────
if grep -qE '^(rename from |rename to |GIT binary patch|Binary files )' "$PATCH"; then
  det::skip "patch is a rename or binary patch — not a mechanical text edit"
fi

# `while read`, not `mapfile`: macOS ships bash 3.2, which has no mapfile.
DIFF_PATHS=()
while IFS= read -r _p; do
  [[ -n "$_p" ]] || continue
  DIFF_PATHS+=("$_p")
done < <(det::diff_paths "$PATCH")
[[ "${#DIFF_PATHS[@]}" -gt 0 ]] || det::skip "no file paths could be parsed out of the patch"
if [[ "${#DIFF_PATHS[@]}" -gt "$MAX_FILES" ]]; then
  det::skip "patch touches ${#DIFF_PATHS[@]} files (> GOVERN_DETERMINISTIC_MAX_FILES=$MAX_FILES)"
fi

# ── 3. every path must sit inside the scout's MEASURED targetPaths ──────────────────────────────
TARGETS="$("$DIR/scout-ticket.sh" --paths "$N" 2>/dev/null || true)"
[[ -n "$TARGETS" ]] || det::skip "the scout measured no targetPaths — nothing to bound the patch against"
for p in "${DIFF_PATHS[@]}"; do
  det::path_allowed "$p" "$TARGETS" || det::skip "patched path '$p' is outside the scout's measured targetPaths"
done

# ── 4. exactly ONE known sub-repo ───────────────────────────────────────────────────────────────
REPO=""
for p in "${DIFF_PATHS[@]}"; do
  r="$(det::repo_for_path "$p" || true)"
  [[ -n "$r" ]] || det::skip "patched path '$p' is not under a known sub-repo (root-level work has no PR lane)"
  if [[ -z "$REPO" ]]; then REPO="$r"
  elif [[ "$REPO" != "$r" ]]; then det::skip "patch spans two sub-repos ($REPO, $r) — not a mechanical single-PR change"
  fi
done
[[ -n "$REPO" ]] || det::skip "could not resolve a sub-repo for the patch"

# ── 5. the source checkout must be clean and on its default branch ──────────────────────────────
SRC_DIR="$(govern::repo_localdir "$REPO")"
[[ -d "$SRC_DIR/.git" ]] || det::skip "sub-repo '$REPO' has no checkout at $SRC_DIR"
if [[ -n "$(git -C "$SRC_DIR" status --porcelain 2>/dev/null || printf 'dirty')" ]]; then
  det::skip "sub-repo '$REPO' is dirty — refusing to branch a mechanical patch off uncommitted work"
fi
DEFAULT_BRANCH="$(govern::subrepo_default_branch "$SRC_DIR")"
CUR_BRANCH="$(git -C "$SRC_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
[[ "$CUR_BRANCH" == "$DEFAULT_BRANCH" ]] || \
  det::skip "sub-repo '$REPO' is on '$CUR_BRANCH', not its default branch '$DEFAULT_BRANCH'"

# ── 6. the verify command (operator-supplied only — never a model-written command) ──────────────
VERIFY_CMD="${GOVERN_DETERMINISTIC_VERIFY_CMD:-}"
VERIFY_REQUIRED="${GOVERN_DETERMINISTIC_VERIFY_REQUIRED:-1}"
if [[ -z "$VERIFY_CMD" && "$VERIFY_REQUIRED" == "1" ]]; then
  det::skip "no GOVERN_DETERMINISTIC_VERIFY_CMD configured and verification is required"
fi

# gh is needed for the PR; check BEFORE doing any work so a missing gh costs nothing.
if [[ "$DRY" -eq 0 ]] && ! command -v gh >/dev/null 2>&1; then
  det::skip "gh is not installed — cannot open the PR"
fi

# ── 7. worktree (same mechanics as spawn-worker.sh) ─────────────────────────────────────────────
slug="ticket-$N"
wtpath="$WORKTREE_BASE/$slug"
wt_cmd="${GOVERN_WORKTREE_CMD:-}"
if [[ -n "$wt_cmd" ]]; then
  wtpath="$("$wt_cmd" "$slug")"
elif [[ -d "$wtpath" ]]; then
  # A preserved worktree means a prior attempt on this ticket is mid-flight (spawn-worker treats it
  # as a resume). A mechanical patch must never land on top of a half-finished human-shaped attempt.
  det::skip "a worktree already exists at $wtpath — a prior attempt owns this ticket"
else
  set +e
  wt_out="$( cd "$WS_ROOT" && WORKTREE_ASSUME_YES=1 bash "$WS_ROOT/scripts/worktree/new.sh" "$slug" 2>&1 )"
  wt_rc=$?
  set -e
  if [[ "$wt_rc" -ne 0 || ! -d "$wtpath" ]]; then
    govern::log "deterministic #$N: worktree:new failed (rc=$wt_rc): $(printf '%s' "$wt_out" | tail -2 | tr '\n' ' ')"
    det::skip "could not create a worktree"
  fi
fi
[[ -d "$wtpath" ]] || det::skip "worktree not created at $wtpath"
WT_REPO="$wtpath/$REPO"
[[ -d "$WT_REPO/.git" ]] || det::skip "worktree has no '$REPO' checkout at $WT_REPO"

# From here on the working tree may be MUTATED, so every failure path must first revert the patch.
DET_APPLIED=0
det::revert_and_skip() { # <reason>
  if [[ "$DET_APPLIED" -eq 1 ]]; then
    ( cd "$wtpath" && git apply -R "$PATCH" ) >/dev/null 2>&1 \
      || govern::log "deterministic #$N: WARNING — could not revert the applied patch in $wtpath"
    DET_APPLIED=0
  fi
  det::skip "$1"
}

# ── 8. apply ────────────────────────────────────────────────────────────────────────────────────
# cwd = the WORKTREE ROOT: the scout is told to emit a diff that applies at the workspace root, so
# its paths are `<repo>/<path>`.
if ! ( cd "$wtpath" && git apply --check "$PATCH" ) >/dev/null 2>&1; then
  det::skip "git apply --check failed — the patch does not apply cleanly"
fi
( cd "$wtpath" && git apply "$PATCH" ) || det::skip "git apply failed after --check passed"
DET_APPLIED=1
govern::log "deterministic #$N: applied a $DET_KIND patch to ${#DIFF_PATHS[@]} file(s) in $REPO — zero model turns so far"

# ── 9. verify ───────────────────────────────────────────────────────────────────────────────────
VERIFIED=false
if [[ -n "$VERIFY_CMD" ]]; then
  vf=()
  # verify-filter.sh collapses a PASSING run to one line and passes the exit code through. Degrade
  # gracefully when a workspace predates it.
  if [[ -x "$DIR/verify-filter.sh" ]]; then vf=("$DIR/verify-filter.sh" --); fi
  set +e
  # `${vf[@]+"${vf[@]}"}` — bash 3.2 errors on an empty array under `set -u`.
  ( cd "$WT_REPO" && ${vf[@]+"${vf[@]}"} bash -c "$VERIFY_CMD" ) >&2
  v_rc=$?
  set -e
  [[ "$v_rc" -eq 0 ]] || det::revert_and_skip "verification failed (rc=$v_rc): $VERIFY_CMD"
  VERIFIED=true
else
  govern::log "deterministic #$N: no verify command (GOVERN_DETERMINISTIC_VERIFY_REQUIRED=0) — reporting verified:false"
fi

# ── 10. commit inside the SUB-REPO (root-level `git add` never stages sub-repo files) ───────────
REL_PATHS=()
for p in "${DIFF_PATHS[@]}"; do REL_PATHS+=("${p#"$REPO"/}"); done
( cd "$WT_REPO" && git add -- "${REL_PATHS[@]}" ) || det::revert_and_skip "git add failed"
if [[ -z "$( cd "$WT_REPO" && git diff --cached --name-only )" ]]; then
  det::revert_and_skip "the patch staged no changes — nothing to commit"
fi
commit_msg="fix: apply deterministic $DET_KIND patch"
if [[ -n "$DET_WHY" ]]; then
  commit_msg="$commit_msg

$DET_WHY

Resolved with zero model turns by deterministic-apply.sh."
fi
( cd "$WT_REPO" && git commit -q -m "$commit_msg" ) || det::revert_and_skip "git commit failed"

# ── 11. push + PR ───────────────────────────────────────────────────────────────────────────────
branch="$(govern::ticket_branch "$N" "$REPO")"
slugref="$(govern::repo_slug "$REPO")"
# A PUBLIC repo must not leak an internal ticket id (same rule the neutral-branch scheme enforces).
pr_title="fix: deterministic $DET_KIND patch"
pr_body="Mechanical patch applied by the governor's deterministic lane — **zero model turns**.

- kind: \`$DET_KIND\`
- rationale: ${DET_WHY:-n/a}
- files: ${#DIFF_PATHS[@]}
- verification: ${VERIFY_CMD:-<none configured>} (${VERIFIED})"
if ! govern::repo_is_public "$REPO"; then
  pr_title="$pr_title (#$N)"
  pr_body="$pr_body

Ticket #$N."
fi

if [[ "$DRY" -eq 1 ]]; then
  govern::log "deterministic #$N: DRY RUN — committed in $WT_REPO on $(git -C "$WT_REPO" rev-parse --abbrev-ref HEAD), not pushing, no PR"
  jq -nc --arg kind "$DET_KIND" --arg why "$DET_WHY" --arg repo "$REPO" \
     --argjson files "${#DIFF_PATHS[@]}" --argjson verified "$VERIFIED" \
     '{status:"resolved", pr:null, prs:[], lessonPatch:null, newTickets:[], crossRefs:{},
       migration:null, validation:null, escalation:null,
       zeroModel:true,
       deterministic:{kind:$kind, rationale:$why, repo:$repo, files:$files, verified:$verified, dryRun:true}}'
  exit 0
fi

set +e
push_out="$( cd "$WT_REPO" && git push -u origin "HEAD:$branch" 2>&1 )"
push_rc=$?
set -e
[[ "$push_rc" -eq 0 ]] || { govern::log "deterministic #$N: push failed: $(printf '%s' "$push_out" | tail -2 | tr '\n' ' ')"; det::skip "git push failed"; }

draft_flag=()
if govern::pr_draft; then draft_flag=(--draft); fi
set +e
pr_out="$( cd "$WT_REPO" && gh pr create --repo "$slugref" --base "$DEFAULT_BRANCH" --head "$branch" \
            --title "$pr_title" --body "$pr_body" ${draft_flag[@]+"${draft_flag[@]}"} 2>&1 )"
pr_rc=$?
set -e
pr_url="$(printf '%s\n' "$pr_out" | grep -oE 'https://[^[:space:]]+/pull/[0-9]+' | tail -1 || true)"
if [[ "$pr_rc" -ne 0 || -z "$pr_url" ]]; then
  govern::log "deterministic #$N: gh pr create failed (rc=$pr_rc): $(printf '%s' "$pr_out" | tail -2 | tr '\n' ' ')"
  det::skip "could not open the PR"
fi
pr_num="${pr_url##*/}"
[[ "$pr_num" =~ ^[0-9]+$ ]] || det::skip "could not parse a PR number out of '$pr_url'"

govern::log "deterministic #$N: RESOLVED with ZERO model turns — $slugref#$pr_num ($DET_KIND)"
jq -nc --arg kind "$DET_KIND" --arg why "$DET_WHY" --arg repo "$REPO" \
   --arg url "$pr_url" --argjson num "$pr_num" \
   --argjson files "${#DIFF_PATHS[@]}" --argjson verified "$VERIFIED" \
   '{status:"resolved",
     pr:{repo:$repo, number:$num, url:$url},
     prs:[{repo:$repo, number:$num, url:$url}],
     lessonPatch:null, newTickets:[], crossRefs:{}, migration:null, validation:null, escalation:null,
     zeroModel:true,
     deterministic:{kind:$kind, rationale:$why, repo:$repo, files:$files, verified:$verified, dryRun:false}}'
exit 0
