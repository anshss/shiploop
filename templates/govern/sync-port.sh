#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# sync-port.sh — AUTO harness→template porter (fail-closed).
#
# When the live harness drifts from the skill templates (sync-templates.sh
# reports drift), this driver automatically ports the drift into the templates
# via a HEADLESS worker, VALIDATES the result, and ONLY THEN opens + merges the
# skill PR + advances the sync marker. On ANY failure or ambiguity it
# ESCALATES (files a note under governor/escalations.md ## Open) and exits
# non-zero — it NEVER ships an unvalidated or identity-leaking template change.
# This automates the manual detect → port → validate → PR → merge → mark loop
# that replaced the 1:1 "port #N into templates" ticket amplification pattern.
#
# It reuses (does NOT reinvent): sync-templates.sh (drift), merge-pr.sh
# (green-or-no-checks merge), lib/common.sh (locks, logging, workspace
# identity, marker CAS-commit), workspace.sh (REPOS, cross-repo overrides).
#
# CONFIGURATION (workspace.sh knobs — EMPTY = whole mechanism no-ops):
#   GOVERN_UPSTREAM_HARNESS_REPO — short repo name of your fork or the
#     canonical shiploop (e.g. "shiploop"). This name must
#     resolve via wsp_repo_slug + wsp_repo_localdir to (owner/repo, local
#     working dir); the workspace.sh helpers already carry per-repo overrides.
#   GOVERN_UPSTREAM_HARNESS_DIR — local working dir override for the templates
#     repo when it lives outside $META_ROOT (usually needed; workspace.sh's
#     default wsp_repo_localdir places every repo at $META_ROOT/<repo>).
#
# Both empty → sync-port + sync-templates are inert; adopters who don't want to
# contribute back to the templates repo pay zero cost.
#
# Usage:
#   sync-port.sh --dry-run   # detect + print the plan (drifted files, forbidden
#                            # strings, what it WOULD do). No branch / porter /
#                            # PR / merge / marker write.
#   sync-port.sh             # full run: branch → porter → VALIDATE → push → PR
#                            # → merge → mark.
#
# Fail-closed decision points (each → escalate + exit non-zero; NEVER merge):
#   • porter did not report status:"ported" (escalated / unparseable / timed
#     out / no commit)
#   • bash -n fails on any changed template shell file
#   • the porter's ADDED diff lines contain a FORBIDDEN IDENTITY STRING
#   • the scaffold test (throwaway workspace from templates/ → template
#     govern/test/test-*.sh) fails
#   • push / PR-create / merge fails (marker is NOT advanced)
# A clean pass advances the marker via a CAS/rebase-safe commit to harness main
# (safe beside a concurrent governor push).
#
# Test seams (env): GOVERN_CLAUDE_BIN (porter binary), GOVERN_SYNC_PORTER_MODEL,
#   GOVERN_MERGE_CMD, GOVERN_GH_BIN, GOVERN_SCAFFOLD_TEST_CMD (replaces the
#   real scaffold+test step), GOVERN_TEMPLATE_REPO_DIR (templates repo working
#   dir), GOVERN_SYNC_PORT_LOCK, GOVERN_SYNC_PORTER_TIMEOUT,
#   GOVERN_FORBIDDEN_EXTRA (extra distinctive identity tokens), GOVERN_NO_PUSH
#   (marker commit stays local) — plus every sync-templates.sh override
#   (GOVERN_DIR / GOVERN_TEMPLATE_DIR / GOVERN_SYNC_MARKER / GOVERN_PROMPTS_DIR
#   / …) passes through.
# NOT set -e: this script BRANCHES on failures to stay fail-closed; a bare -e
# would abort before the escalation could be filed.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$DIR/lib/common.sh"    # govern:: helpers + workspace identity (GITHUB_ORG, META_NAME, REPOS)
# common.sh enables `set -e`; we deliberately branch on failures ourselves to
# stay fail-closed (file the escalation before exiting), so a failing command
# must NOT abort the script. Re-disable -e.
set +e
govern::require jq
govern::require git

SYNC_TEMPLATES="$DIR/sync-templates.sh"
MERGE_CMD="${GOVERN_MERGE_CMD:-$DIR/merge-pr.sh}"
GH_BIN="${GOVERN_GH_BIN:-gh}"
CLAUDE_BIN="${GOVERN_CLAUDE_BIN:-claude}"
PORTER_MODEL="${GOVERN_SYNC_PORTER_MODEL:-${GOVERN_WORKER_MODEL:-opus}}"
PORTER_PROMPT_FILE="${GOVERN_SYNC_PORTER_PROMPT:-$GOVERNOR_DIR/sync-porter-prompt.md}"
PORTER_TIMEOUT="${GOVERN_SYNC_PORTER_TIMEOUT:-1800}"
LOCK="${GOVERN_SYNC_PORT_LOCK:-$GOVERNOR_DIR/.locks/sync-port}"
LOG_DIR="${GOVERN_SYNC_PORT_LOGDIR:-$LOG_ROOT/sync-port}"

# ── Guard: the whole mechanism is opt-in. If GOVERN_UPSTREAM_HARNESS_REPO
# isn't set (default), we can't know which repo to open a PR against — so
# there's nothing to do. Print a friendly line and exit 0.
UPSTREAM_REPO="${GOVERN_UPSTREAM_HARNESS_REPO:-}"
if [[ -z "$UPSTREAM_REPO" ]]; then
  govern::log "sync-port: GOVERN_UPSTREAM_HARNESS_REPO not set in workspace.sh — nothing to do (feature off)"
  exit 0
fi

LIVE_ROOT="$(govern::meta_root)"                       # the harness repo root
# Local working dir for the templates repo. Priority:
#   1. GOVERN_TEMPLATE_REPO_DIR (test seam)
#   2. GOVERN_UPSTREAM_HARNESS_DIR (workspace.sh knob for a checkout outside $META_ROOT)
#   3. wsp_repo_localdir "$UPSTREAM_REPO" (workspace.sh case-arm override; falls
#      back to $META_ROOT/<repo> which almost never matches for the templates repo)
TEMPLATE_REPO_DIR="${GOVERN_TEMPLATE_REPO_DIR:-${GOVERN_UPSTREAM_HARNESS_DIR:-$(govern::repo_localdir "$UPSTREAM_REPO")}}"
# The templates ROOT (where templates/ live) — keep consistent with sync-templates.sh's
# derivation (dirname of GOVERN_TEMPLATE_DIR) so both look at the same tree.
if [[ -n "${GOVERN_TEMPLATE_DIR:-}" ]]; then TEMPLATES_ROOT="$(dirname "$GOVERN_TEMPLATE_DIR")"
else TEMPLATES_ROOT="$TEMPLATE_REPO_DIR/templates"; fi
META_SLUG="$(govern::repo_slug "$UPSTREAM_REPO")"

DRY_RUN=0
# --no-merge (or GOVERN_SYNC_PORT_NO_MERGE=1): port + validate + open the PR,
# then STOP before merging — the safe-rollout mode for the first live runs, so
# a human reviews the porter's actual genericization before it lands on the
# global skill. Flip off (default) for full hands-off auto.
NO_MERGE="${GOVERN_SYNC_PORT_NO_MERGE:-0}"
case "${1:-}" in
  --dry-run) DRY_RUN=1 ;;
  --no-merge) NO_MERGE=1 ;;
  ""|--run) : ;;
  -h|--help) sed -n '2,/^set -uo/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; $d'; exit 0 ;;
  *) govern::die "unknown arg '$1' (use --dry-run, --no-merge, or no arg)" ;;
esac

# ── forbidden identity strings ──────────────────────────────────────────────
# The gate is generic across workspaces because the list is DERIVED from
# config, not hardcoded: $GITHUB_ORG + the ${REPOS[@]} names + a base
# product-token list ($META_NAME + optional $GOVERN_FORBIDDEN_EXTRA).
# Lowercased + deduped. A genericized template must contain NONE of these on
# the lines the porter ADDED.
forbidden_tokens() { # -> one lowercased token per line, deduped
  { printf '%s\n' "$GITHUB_ORG" "$META_NAME"
    printf '%s\n' "${REPOS[@]}"
    for t in ${GOVERN_FORBIDDEN_EXTRA:-}; do printf '%s\n' "$t"; done
  } | tr 'A-Z' 'a-z' | awk 'NF' | sort -u
}
forbidden_regex() {
  local re="" t esc
  while IFS= read -r t; do
    esc="$(printf '%s' "$t" | sed 's/[^a-zA-Z0-9]/\\&/g')"
    re+="${re:+|}$esc"
  done < <(forbidden_tokens)
  printf '(%s)' "$re"
}

# ── escalation (fail-closed sink) ───────────────────────────────────────────
find_open_sync_escalation_n() { # branch -> N | ""
  local br="$1"
  [[ -f "$ESCALATIONS_FILE" && -n "$br" ]] || { echo ""; return 0; }
  awk -v br="$br" '
    /^## Open/     { in_open=1; next }
    /^## Resolved/ { exit }
    /^## /         { in_open=0; next }
    in_open && /^### +#[0-9]+/ {
      cur=$0; sub(/^### +#/,"",cur); sub(/[^0-9].*/,"",cur)
      cur_is_sync=($0 ~ /sync-port:/)
      next
    }
    in_open && cur_is_sync && $0 ~ ("^- \\*\\*Branch:\\*\\* " br "( |$)") { print cur; exit }
  ' "$ESCALATIONS_FILE" 2>/dev/null
}

bump_last_seen() { # N ts
  local N="$1" ts="$2" tmp
  [[ -f "$ESCALATIONS_FILE" ]] || return 0
  tmp="$(mktemp)"
  awk -v n="$N" -v ts="$ts" '
    BEGIN{ inblk=0; wrote=0 }
    /^### +#[0-9]+/ {
      if(inblk && !wrote){ print "- **Last-seen:** " ts; wrote=1 }
      cur=$0; sub(/^### +#/,"",cur); sub(/[^0-9].*/,"",cur)
      inblk = (cur == n); wrote=0
      print; next
    }
    /^## / {
      if(inblk && !wrote){ print "- **Last-seen:** " ts; wrote=1 }
      inblk=0; print; next
    }
    inblk && $0 ~ /^- \*\*Last-seen:\*\*/ { print "- **Last-seen:** " ts; wrote=1; next }
    inblk && /^$/ && !wrote { print "- **Last-seen:** " ts; wrote=1; print; next }
    { print }
    END{ if(inblk && !wrote) print "- **Last-seen:** " ts }
  ' "$ESCALATIONS_FILE" > "$tmp" && mv "$tmp" "$ESCALATIONS_FILE"
}

file_sync_escalation() { # reason  branch  files-multiline
  local reason="$1" branch="$2" files="$3" blk tmp ts nfiles N existing
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  nfiles="$(printf '%s' "$files" | grep -c . || echo 0)"

  existing="$(find_open_sync_escalation_n "$branch" || true)"
  if [[ -n "$existing" ]]; then
    bump_last_seen "$existing" "$ts (repeat: $reason)"
    govern::log "sync-port ESCALATION DEDUP: matches open #$existing for branch $branch — bumped Last-seen (no new entry)"
    govern::_commit_escalations "sync-port #$existing (bump Last-seen)"
    return 0
  fi

  N="$(govern::next_ticket_number)"

  blk="$(mktemp)"
  {
    printf '\n### #%s — sync-port: %s file(s) need manual porting\n' "$N" "$nfiles"
    printf -- '- **Opened:** %s%s\n' "$(date +%F)" "${TJ_RUN_ID:+ (run $TJ_RUN_ID)}"
    printf -- '- **Reason:** %s (%s)\n' "$reason" "$ts"
    printf -- '- **Branch:** %s (in %s — inspect, finish the port by hand)\n' "${branch:-<none cut>}" "$TEMPLATE_REPO_DIR"
    printf -- '- **Files:**'
    if [[ -n "$files" ]]; then printf ' %s' "$(printf '%s' "$files" | tr '\n' ' ')"; fi
    printf '\n'
    printf -- '- **Question:** Port these into the templates by hand (additive + genericized), merge the branch, then run `sync-templates.sh --mark %s`.\n' "$MARK_TO"
    printf -- '- **Options:** \n'
    printf -- '- **Answer:** _(operator)_\n'
    printf -- '- **Disposition:** _(operator: do-the-work | defer | mitigated | keep-open)_\n'
    printf -- '- **Make this a rule?:** _(operator)_\n'
  } > "$blk"
  if grep -q '^## Open' "$ESCALATIONS_FILE" 2>/dev/null; then
    tmp="$(mktemp)"
    awk -v bf="$blk" '{print} /^## Open/ && !done {while ((getline l < bf) > 0) print l; close(bf); done=1}' \
      "$ESCALATIONS_FILE" > "$tmp" && mv "$tmp" "$ESCALATIONS_FILE"
  else
    mkdir -p "$(dirname "$ESCALATIONS_FILE")" 2>/dev/null || true
    { printf '## Open\n'; cat "$blk"; } >> "$ESCALATIONS_FILE"
  fi
  rm -f "$blk"
  govern::log "sync-port ESCALATED as #$N → $ESCALATIONS_FILE: $reason"
  govern::_commit_escalations "sync-port escalation #$N"
}

sync_port_restore_templates_main() {
  [[ -d "$TEMPLATE_REPO_DIR/.git" ]] || return 0
  git -C "$TEMPLATE_REPO_DIR" reset --hard HEAD >/dev/null 2>&1 || true
  git -C "$TEMPLATE_REPO_DIR" clean -fd >/dev/null 2>&1 || true
  git -C "$TEMPLATE_REPO_DIR" checkout -q main 2>/dev/null || true
}

export GOVERN_SUPPRESS_EMIT_PENDING=1

# ── 0. single-owner lock ────────────────────────────────────────────────────
if ! govern::lock_try "$LOCK"; then
  govern::log "sync-port: lock $LOCK held by another run — nothing to do."
  exit 0
fi
trap '_syncp_rc=$?; [[ "$_syncp_rc" -ne 0 ]] && sync_port_restore_templates_main; govern::lock_release "$LOCK"' EXIT

# ── 1. drift? ───────────────────────────────────────────────────────────────
# N4: pin the enumeration UPPER BOUND once, first — a single HEAD capture that
# --check, --files, and the eventual marker advance all key off. Without it,
# --check / --files / rev-parse each resolve HEAD independently, so a concurrent
# governor merge landing a mirrored-file commit on live main between enumeration
# and the marker write is EXCLUDED from the port yet INCLUDED in the marker
# advance (silent drift loss via race). Passing GOVERN_SYNC_UPPER_BOUND bounds
# sync-templates' internal "base..HEAD" walks to "base..$MARK_TO".
MARK_TO="$(git -C "$LIVE_ROOT" rev-parse HEAD 2>/dev/null || echo HEAD)"

drift_out="$(GOVERN_SYNC_UPPER_BOUND="$MARK_TO" "$SYNC_TEMPLATES" --check 2>&1)"; drift_rc=$?
if [[ "$drift_rc" -eq 0 ]]; then
  govern::log "sync-port: templates in sync — nothing to port."
  exit 0
elif [[ "$drift_rc" -ne 3 ]]; then
  govern::die "sync-port: sync-templates --check errored (rc=$drift_rc): $(printf '%s' "$drift_out" | head -2)"
fi

DRIFT_FILES=()
while IFS= read -r _f; do [[ -n "$_f" ]] && DRIFT_FILES+=("$_f"); done \
  < <(GOVERN_SYNC_UPPER_BOUND="$MARK_TO" "$SYNC_TEMPLATES" --files 2>/dev/null | awk '/\[mirrored\]/{print $2}')
if [[ "${#DRIFT_FILES[@]}" -eq 0 ]]; then
  govern::die "sync-port: --check said drift but --files listed none — refusing to act (fail-closed)."
fi
NFILES="${#DRIFT_FILES[@]}"
FREGEX="$(forbidden_regex)"
MARKER_SHA="$("$SYNC_TEMPLATES" --sha 2>/dev/null || echo unknown)"
BRANCH="sync-auto-${MARKER_SHA:0:9}-${NFILES}f"
drift_files_ml="$(printf '%s\n' "${DRIFT_FILES[@]}")"

# N2: advance-the-marker-after-a-human-merge. `/shiploop:push` runs sync-port
# with NO_MERGE=1 and opens a PR for HUMAN review — but the NO_MERGE path exits
# BEFORE the marker advance (step 5), so after the human merges nothing moves the
# marker: the next run sees identical marker+drift, re-cuts the SAME branch, and
# re-spawns a full porter against a tree that already carries the change (fails
# the "committed nothing" gate → escalates, forever). Detect it here — a MERGED
# PR for THIS drift branch → advance the marker + CAS-commit it (mirroring step
# 5) and exit 0, no porter respawn. Fail-open on any gh error (offline /
# rate-limit) — never block sync-port on a signal we can't fetch.
if command -v "$GH_BIN" >/dev/null 2>&1 && [[ "$DRY_RUN" -ne 1 ]]; then
  _merged_pr="$("$GH_BIN" pr list --repo "$META_SLUG" --head "$BRANCH" --state merged --json number --jq '.[0].number' 2>/dev/null || true)"
  if [[ -n "$_merged_pr" ]]; then
    govern::log "sync-port: MERGED PR #$_merged_pr on $META_SLUG for branch $BRANCH — advancing marker to ${MARK_TO:0:9} (no porter respawn)"
    if ! "$SYNC_TEMPLATES" --mark "$MARK_TO" >/dev/null 2>&1; then
      file_sync_escalation "merged PR #$_merged_pr found for $BRANCH but advancing the sync marker failed — run 'sync-templates.sh --mark $MARK_TO' by hand." "$BRANCH" "$drift_files_ml"
      exit 1
    fi
    marker_rel="$(cd "$LIVE_ROOT" && git ls-files --full-name -- '*/.templates-synced-at' 2>/dev/null | head -1)"
    [[ -n "$marker_rel" ]] || marker_rel="scripts/govern/.templates-synced-at"
    govern::commit_meta_to_main "$LIVE_ROOT" "$marker_rel" "chore(govern): advance template-sync marker to ${MARK_TO:0:9} (sync-port merged PR #$_merged_pr)"
    govern::log "sync-port: marker advanced to ${MARK_TO:0:9} after merged PR #$_merged_pr."
    echo "sync-port: merged PR #$_merged_pr already landed — marker advanced to ${MARK_TO:0:9} (no porter respawn)"
    exit 0
  fi
fi

# skip-if-open-PR: if a prior sync-port left an OPEN PR for THIS drift branch,
# re-spawning the porter would just fight the existing PR. Skip — the operator
# merges/closes the open PR, then the next run's drift check sees a fresh
# marker. Fail-open on a gh error (no network / rate-limit) — never block
# sync-port on a signal we can't fetch.
if command -v "$GH_BIN" >/dev/null 2>&1 && [[ "$DRY_RUN" -ne 1 ]]; then
  _open_pr="$("$GH_BIN" pr list --repo "$META_SLUG" --head "$BRANCH" --state open --json number --jq '.[0].number' 2>/dev/null || true)"
  if [[ -n "$_open_pr" ]]; then
    govern::log "sync-port: OPEN PR #$_open_pr already exists on $META_SLUG for branch $BRANCH — skipping porter respawn (merge/close the PR, then re-run)"
    exit 0
  fi
fi

# ── --dry-run: print the plan, touch nothing ────────────────────────────────
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "sync-port plan (DRY RUN — no branch/porter/PR/merge):"
  echo "  templates repo : $TEMPLATE_REPO_DIR ($META_SLUG)"
  echo "  templates root : $TEMPLATES_ROOT"
  echo "  marker synced-through: ${MARKER_SHA:0:9}   →  would advance to ${MARK_TO:0:9}"
  echo "  branch it WOULD cut  : $BRANCH  (off origin/main)"
  echo "  drifted mirrored files ($NFILES):"
  printf '    %s\n' "${DRIFT_FILES[@]}"
  echo "  FORBIDDEN identity strings (added lines grepped -iwE):"
  printf '    %s\n' "$(forbidden_tokens | tr '\n' ' ')"
  echo "  → would spawn the headless porter, VALIDATE (bash -n + forbidden grep + scaffold test),"
  echo "    then would open a PR on $META_SLUG and merge it green-or-no-checks, then advance the marker."
  exit 0
fi

# ── FULL RUN ────────────────────────────────────────────────────────────────
mkdir -p "$LOG_DIR"
command -v "$GH_BIN" >/dev/null 2>&1 || govern::die "sync-port: '$GH_BIN' not found — cannot open the PR."

[[ -d "$TEMPLATE_REPO_DIR/.git" ]] || govern::die "sync-port: $TEMPLATE_REPO_DIR is not a git repo."
if [[ -n "$(git -C "$TEMPLATE_REPO_DIR" status --porcelain 2>/dev/null)" ]]; then
  file_sync_escalation "templates repo working tree is DIRTY — cannot safely cut a clean branch. Commit/stash it first." "" "$(printf '%s\n' "${DRIFT_FILES[@]}")"
  exit 1
fi

if ! git -C "$TEMPLATE_REPO_DIR" fetch -q origin 2>/dev/null; then
  file_sync_escalation "could not 'git fetch origin' in the templates repo (offline / no origin)." "" "$(printf '%s\n' "${DRIFT_FILES[@]}")"
  exit 1
fi
if ! git -C "$TEMPLATE_REPO_DIR" checkout -q -B "$BRANCH" origin/main 2>/dev/null; then
  file_sync_escalation "could not cut branch $BRANCH off origin/main in the templates repo." "$BRANCH" "$(printf '%s\n' "${DRIFT_FILES[@]}")"
  exit 1
fi
BRANCH_BASE="$(git -C "$TEMPLATE_REPO_DIR" rev-parse HEAD)"

[[ -f "$PORTER_PROMPT_FILE" ]] || govern::die "sync-port: porter prompt missing at $PORTER_PROMPT_FILE"
pairs=""
for f in "${DRIFT_FILES[@]}"; do
  pairs+="  - $f"$'\n'
done
prompt="$(cat "$PORTER_PROMPT_FILE")

## CONTEXT (filled by the driver)
- **Live harness root:** $LIVE_ROOT
- **Templates root (edit files UNDER here):** $TEMPLATES_ROOT
- **You are already on branch:** $BRANCH  (do NOT switch/create branches; do NOT push)
- **Drifted mirrored files (live path → template counterpart):**
$pairs
- **FORBIDDEN IDENTITY STRINGS (your ADDED lines must contain NONE of these):**
  $(forbidden_tokens | tr '\n' ' ')
"
report_path="$LOG_DIR/report.json"; rm -f "$report_path"
jsonl="$LOG_DIR/porter.jsonl"

report=""; status=""; escalation=""; porter_rc=0
for porter_attempt in 1 2; do
  govern::log "sync-port: spawning porter (attempt $porter_attempt/2, model=$PORTER_MODEL, timeout=${PORTER_TIMEOUT}s) on $NFILES file(s) → branch $BRANCH"
  rm -f "$report_path"
  set -m
  ( cd "$TEMPLATE_REPO_DIR" && exec env \
      -u CLAUDE_CODE_ENTRYPOINT -u CLAUDECODE -u CLAUDE_CODE_SSE_PORT \
      -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID -u CLAUDE_EFFORT \
      GOVERN_RUN=1 GOVERN_REPORT_PATH="$report_path" "$CLAUDE_BIN" -p "$prompt" \
      --output-format stream-json --verbose \
      --setting-sources "${GOVERN_SETTING_SOURCES:-user}" \
      --permission-mode "${GOVERN_PERMISSION_MODE:-bypassPermissions}" \
      --model "$PORTER_MODEL" ) >"$jsonl" 2>&1 &
  cpid=$!
  set +m
  wd=""
  if [[ "$PORTER_TIMEOUT" -gt 0 ]]; then
    ( sleep "$PORTER_TIMEOUT"
      kill -0 "$cpid" 2>/dev/null && { govern::log "sync-port: porter exceeded ${PORTER_TIMEOUT}s — killing"; govern::kill_tree "$cpid" 10; } ) >>"$LOG_DIR/watchdog.log" 2>&1 & wd=$!
  fi
  wait "$cpid"; porter_rc=$?
  [[ -n "$wd" ]] && { kill "$wd" 2>/dev/null || true; govern::_kill_tree_walk "$wd" TERM; }

  report=""
  [[ -s "$report_path" ]] && report="$(govern::extract_report < "$report_path" || true)"
  if [[ -z "$report" ]]; then
    rmsg="$(grep '"type":"result"' "$jsonl" 2>/dev/null | tail -1 | jq -r '.result // empty' 2>/dev/null || true)"
    [[ -n "$rmsg" ]] && report="$(printf '%s' "$rmsg" | govern::extract_report || true)"
  fi
  status=""; escalation=""
  if [[ -n "$report" ]] && printf '%s' "$report" | jq empty >/dev/null 2>&1; then
    status="$(printf '%s' "$report" | jq -r '.status // ""')"
    escalation="$(printf '%s' "$report" | jq -r '.escalation // ""')"
  fi

  if [[ "$status" != "ported" && "$porter_attempt" -eq 1 ]]; then
    intr="$(govern::interrupted_error_signature "$jsonl" 2>/dev/null || true)"
    if [[ -n "$intr" ]]; then
      govern::log "sync-port: porter hit a transient connection drop ($intr) — retrying once from a clean base"
      git -C "$TEMPLATE_REPO_DIR" reset --hard "$BRANCH_BASE" >/dev/null 2>&1 || true
      continue
    fi
  fi
  break
done

drift_files_ml="$(printf '%s\n' "${DRIFT_FILES[@]}")"

if [[ "$status" != "ported" ]]; then
  local_reason="porter did not port cleanly (status='${status:-unparseable}', rc=$porter_rc)"
  [[ -n "$escalation" ]] && local_reason+=": $escalation"
  [[ "$status" == "" ]] && local_reason+=" — no parseable {status:...} report from the porter (inspect $jsonl)"
  file_sync_escalation "$local_reason" "$BRANCH" "$drift_files_ml"
  exit 1
fi

HEAD_NOW="$(git -C "$TEMPLATE_REPO_DIR" rev-parse HEAD)"
if [[ "$HEAD_NOW" == "$BRANCH_BASE" ]]; then
  file_sync_escalation "porter reported 'ported' but committed NOTHING (HEAD unchanged on $BRANCH)." "$BRANCH" "$drift_files_ml"
  exit 1
fi

_dirty="$(git -C "$TEMPLATE_REPO_DIR" status --porcelain 2>/dev/null)"
if [[ -n "$_dirty" ]]; then
  file_sync_escalation "porter reported 'ported' but left UNCOMMITTED changes in the templates worktree (strand — porter incomplete): $(printf '%s' "$_dirty" | head -5 | tr '\n' ' ')" "$BRANCH" "$drift_files_ml"
  exit 1
fi

_ncommits="$(git -C "$TEMPLATE_REPO_DIR" rev-list --count "origin/main..HEAD" 2>/dev/null || echo 0)"
if [[ "${_ncommits:-0}" -eq 0 ]]; then
  file_sync_escalation "porter produced NO commits vs origin/main on $BRANCH (empty diff — nothing to PR). Refusing to push/PR an empty branch." "$BRANCH" "$drift_files_ml"
  exit 1
fi

# ── 3. VALIDATION GATE ─────────────────────────────────────────────────────
CHANGED=()
while IFS= read -r _c; do [[ -n "$_c" ]] && CHANGED+=("$_c"); done \
  < <(git -C "$TEMPLATE_REPO_DIR" diff --name-only "origin/main...$BRANCH")
if [[ "${#CHANGED[@]}" -eq 0 ]]; then
  file_sync_escalation "porter committed but the diff vs origin/main is empty." "$BRANCH" "$drift_files_ml"
  exit 1
fi

synfail=""
for f in "${CHANGED[@]}"; do
  case "$f" in *.sh)
    if ! bash -n "$TEMPLATE_REPO_DIR/$f" 2>>"$LOG_DIR/bash-n.log"; then synfail+="$f "; fi ;;
  esac
done
if [[ -n "$synfail" ]]; then
  file_sync_escalation "GATE FAIL — 'bash -n' syntax error in ported template shell file(s): $synfail (see $LOG_DIR/bash-n.log)" "$BRANCH" "$drift_files_ml"
  exit 1
fi

added="$(git -C "$TEMPLATE_REPO_DIR" diff "origin/main...$BRANCH" -- "${CHANGED[@]}" \
          | grep -E '^\+' | grep -Ev '^\+\+\+' || true)"
leaks="$(printf '%s\n' "$added" | grep -iwE "$FREGEX" || true)"
if [[ -n "$leaks" ]]; then
  file_sync_escalation "GATE FAIL — ported template ADDED lines contain FORBIDDEN identity string(s). Sample: $(printf '%s' "$leaks" | head -3 | tr '\n' ' ' | cut -c1-200)" "$BRANCH" "$drift_files_ml"
  exit 1
fi

run_scaffold_suite() {  # templates_tree label -> prints failing test names
  local troot="$1" label="$2" ws t name fails=""
  ws="$(mktemp -d)"
  mkdir -p "$ws/scripts" "$ws/governor" "$ws/queue"
  cp -R "$troot/govern"  "$ws/scripts/govern"  2>/dev/null || { rm -rf "$ws"; echo "__BUILD_FAIL__"; return; }
  cp -R "$troot/lib"     "$ws/scripts/lib"     2>/dev/null || true
  [[ -d "$troot/worktree" ]] && cp -R "$troot/worktree" "$ws/scripts/worktree"
  [[ -d "$troot/githooks" ]] && cp -R "$troot/githooks" "$ws/.githooks"
  [[ -d "$troot/governor" ]] && cp -R "$troot/governor/." "$ws/governor/"
  [[ -d "$troot/hooks" ]] && cp "$troot/hooks/"*.sh "$ws/scripts/" 2>/dev/null || true
  if [[ -f "$troot/lib/workspace.sh" ]]; then
    sed -e 's/__META_NAME__/scaffoldws/g' -e 's/__GITHUB_ORG__/scaffoldorg/g' \
        -e 's/__REPOS__/alpha web/g' -e 's/__REPO_CMDS__/"echo alpha" "echo web"/g' \
        -e 's/__REPO_PORTS__/3000 3001/g' -e 's/__GOVERN_MERGE_REPOS__/alpha/g' \
        -e "s#__WORKTREE_BASE__#$ws/wt#g" \
        "$troot/lib/workspace.sh" > "$ws/scripts/lib/workspace.sh"
  fi
  [[ -d "$ws/scripts/govern/test" ]] || { rm -rf "$ws"; echo "__BUILD_FAIL__"; return; }
  for t in "$ws/scripts/govern/test/"test-*.sh; do
    [[ -f "$t" ]] || continue
    name="$(basename "$t")"
    bash "$t" >"$LOG_DIR/scaffold-$label-$name.log" 2>&1; rc=$?
    # rc=77 is a well-known SKIP (test-update-channel from a non-hub checkout, test-sync-port
    # when the porter prompt isn't present) — treat as skip, not fail.
    [[ "$rc" -eq 0 || "$rc" -eq 77 ]] || fails+="$name "
  done
  rm -rf "$ws"
  echo "$fails"
}
scaffold_cmd="${GOVERN_SCAFFOLD_TEST_CMD:-}"
if [[ -n "$scaffold_cmd" ]]; then
  "$scaffold_cmd" "$TEMPLATES_ROOT"; scaffold_rc=$?
  if [[ "$scaffold_rc" -ne 0 ]]; then
    file_sync_escalation "GATE FAIL — scaffold test failed (rc=$scaffold_rc; see $LOG_DIR/scaffold-*.log)." "$BRANCH" "$drift_files_ml"
    exit 1
  fi
else
  base_tmp="$(mktemp -d)"
  if git -C "$TEMPLATE_REPO_DIR" archive origin/main templates 2>/dev/null | tar -x -C "$base_tmp" 2>/dev/null && [[ -d "$base_tmp/templates/govern" ]]; then
    baseline_fails="$(run_scaffold_suite "$base_tmp/templates" base)"
  else
    baseline_fails=""; govern::log "sync-port: could not build baseline scaffold (git archive origin/main) — treating baseline as clean"
  fi
  rm -rf "$base_tmp"
  ported_fails="$(run_scaffold_suite "$TEMPLATES_ROOT" ported)"
  if [[ "$ported_fails" == *"__BUILD_FAIL__"* ]]; then
    file_sync_escalation "GATE FAIL — could not build a scaffold workspace from the ported templates." "$BRANCH" "$drift_files_ml"
    exit 1
  fi
  newfails=""
  for f in $ported_fails; do
    case " $baseline_fails " in *" $f "*) : ;; *) newfails+="$f " ;; esac
  done
  if [[ -n "$newfails" ]]; then
    file_sync_escalation "GATE FAIL — the port NEWLY broke scaffold test(s): $newfails (see $LOG_DIR/scaffold-ported-*.log)." "$BRANCH" "$drift_files_ml"
    exit 1
  fi
  [[ -n "$ported_fails" ]] && govern::log "sync-port: scaffold layout-sensitive pre-existing failures IGNORED (also fail on the pre-port baseline): $ported_fails"
fi

# ── 4. gate PASSED → push, PR, merge ────────────────────────────────────────
if ! git -C "$TEMPLATE_REPO_DIR" push -q -u origin "$BRANCH" 2>>"$LOG_DIR/git.log"; then
  file_sync_escalation "gate PASSED but 'git push' of $BRANCH failed (see $LOG_DIR/git.log)." "$BRANCH" "$drift_files_ml"
  exit 1
fi
pr_title="sync: port harness drift into templates ($NFILES file(s), through ${MARK_TO:0:9})"
pr_body="Automated harness→template sync (sync-port.sh). Ports drift through ${MARK_TO:0:9}.

Drifted files:
$(printf -- '- %s\n' "${DRIFT_FILES[@]}")

Validated: bash -n, forbidden-identity-strings gate (added lines), scaffold govern test suite.
🤖 Generated with sync-port.sh"
pr_url="$("$GH_BIN" pr create --repo "$META_SLUG" --base main --head "$BRANCH" \
           --title "$pr_title" --body "$pr_body" 2>>"$LOG_DIR/gh.log")"
gh_rc=$?
if [[ "$gh_rc" -ne 0 || -z "$pr_url" ]]; then
  file_sync_escalation "gate PASSED, branch pushed, but 'gh pr create' failed (rc=$gh_rc; see $LOG_DIR/gh.log)." "$BRANCH" "$drift_files_ml"
  exit 1
fi
pr_num="$(printf '%s' "$pr_url" | grep -oE '[0-9]+$' || true)"
govern::log "sync-port: opened $META_SLUG PR #$pr_num — $pr_url"

if [[ "$NO_MERGE" -eq 1 ]]; then
  govern::log "sync-port: --no-merge — validated PR #$pr_num opened for review; NOT merging, marker held at ${MARKER_SHA:0:9}."
  echo "sync-port: [no-merge] ported $NFILES file(s) → $META_SLUG PR #$pr_num ($pr_url) — review + merge, then: sync-templates.sh --mark $MARK_TO"
  exit 0
fi

if ! "$MERGE_CMD" "$UPSTREAM_REPO" "$pr_num" 2>>"$LOG_DIR/merge.log"; then
  file_sync_escalation "gate PASSED + PR #$pr_num opened but the auto-merge failed (CI not green / conflict; see $LOG_DIR/merge.log). Merge it by hand, then run sync-templates.sh --mark $MARK_TO." "$BRANCH" "$drift_files_ml"
  exit 1
fi
govern::log "sync-port: merged $META_SLUG PR #$pr_num"

# ── 5. advance the marker ──────────────────────────────────────────────────
if ! "$SYNC_TEMPLATES" --mark "$MARK_TO" >/dev/null 2>&1; then
  file_sync_escalation "PR #$pr_num MERGED but advancing the sync marker failed — run 'sync-templates.sh --mark $MARK_TO' by hand." "$BRANCH" "$drift_files_ml"
  exit 1
fi
marker_rel="$(cd "$LIVE_ROOT" && git ls-files --full-name -- '*/.templates-synced-at' 2>/dev/null | head -1)"
[[ -n "$marker_rel" ]] || marker_rel="scripts/govern/.templates-synced-at"
govern::commit_meta_to_main "$LIVE_ROOT" "$marker_rel" "chore(govern): advance template-sync marker to ${MARK_TO:0:9} (sync-port PR #$pr_num)"

govern::log "sync-port: DONE — merged PR #$pr_num, marker advanced to ${MARK_TO:0:9}."
echo "sync-port: ported $NFILES file(s), merged $META_SLUG PR #$pr_num, marker → ${MARK_TO:0:9}"
exit 0
