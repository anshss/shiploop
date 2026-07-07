#!/usr/bin/env bash
# config-check.sh — cheap, no-auth smoke that sources the workspace's config +
# common.sh, calls every helper with fake args, and prints resolved values.
#
# Motivated by the tokenjam convergence friction #5: dry-run.sh is the only
# smoke path setup.md points at, but it invokes a live authenticated Claude
# worker. A headless upgrade verifier with no OAuth can't complete it and can't
# tell whether workspace.sh, common.sh, and the helpers are wired sanely. This
# script fills that gap:
#
#   - sources scripts/lib/workspace.sh (fails hard if it can't parse)
#   - sources scripts/govern/lib/common.sh (fails hard on missing helpers)
#   - resolves & prints every knob + helper output the governor reads
#   - REQUIRES the set that governor cannot run without; exits nonzero if any
#     is missing (empty). Everything else is informational.
#
# Usage: scripts/govern/config-check.sh          # human summary
#        scripts/govern/config-check.sh --json   # machine-readable
#
# Exit codes:
#   0  every required knob resolves + every helper returns something
#   1  a required knob is empty / a helper errored
#   2  arg error
set -uo pipefail

MODE=human
case "${1:-}" in
  --json) MODE=json ;;
  ""|--human) : ;;
  -h|--help) sed -n '2,/^set -uo/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; $d'; exit 0 ;;
  *) echo "config-check: unknown arg '$1' (use --json or no arg)" >&2; exit 2 ;;
esac

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$DIR/lib/common.sh"     # sources workspace.sh + defines govern:: helpers
# common.sh enables `set -e`; we need to KEEP running past a failing helper so we
# can list every problem in one pass. Disable -e (leave -u -o pipefail on).
set +e
govern::require jq

problems=()
warn_only=()

# ── Required knobs (empty = fail) ──
req() { # <name> <value>
  if [[ -z "${2:-}" ]]; then problems+=("required knob '$1' is empty"); fi
}
req META_NAME    "${META_NAME:-}"
req GITHUB_ORG   "${GITHUB_ORG:-}"
req ROOT_PM      "${ROOT_PM:-}"
req WORKTREE_BASE "${WORKTREE_BASE:-}"
if [[ "${#REPOS[@]}" -eq 0 ]]; then problems+=("REPOS is empty (no sub-repos configured)"); fi

# ── Optional knobs (informational) ──
opt_seen=()
for k in GOVERN_MERGE_REPOS GOVERN_LOCAL_FIRST_REPOS GOVERN_WORKER_MODEL \
         GOVERN_EXTERNALIZE_LANE GOVERN_EXTERNALIZE_REPO GOVERN_EXTERNALIZE_SUBREPO \
         GOVERN_EXTERNALIZE_LABELS WSP_LINT_FIX_CMD GOVERN_MIGRATE_CMD GOVERN_VERIFY_CMD \
         GOVERN_UPSTREAM_HARNESS_REPO GOVERN_UPSTREAM_HARNESS_DIR; do
  eval "v=\${$k:-}"
  opt_seen+=("$k=$v")
done

# ── Helpers (call with fake args; capture output for the report) ──
h_slug=""; h_localdir=""; h_port=""; h_cmd=""; h_ismerge=""; h_islocal=""
h_next_ticket=""
if [[ "${#REPOS[@]}" -gt 0 ]]; then
  probe="${REPOS[0]}"
  h_slug="$(wsp_repo_slug "$probe" 2>&1)" || problems+=("wsp_repo_slug '$probe' errored: $h_slug")
  h_localdir="$(wsp_repo_localdir "$probe" 2>&1)" || problems+=("wsp_repo_localdir '$probe' errored: $h_localdir")
  # wsp_repo_port / wsp_repo_cmd are OPTIONAL helpers (older workspaces predate them).
  if type wsp_repo_port >/dev/null 2>&1;  then h_port="$(wsp_repo_port "$probe" 0 2>&1)" || :; else h_port="<not-defined>"; fi
  if type wsp_repo_cmd  >/dev/null 2>&1;  then h_cmd="$(wsp_repo_cmd "$probe" 2>&1)"     || :; else h_cmd="<not-defined>"; fi
  if wsp_is_merge_repo "$probe" 2>/dev/null; then h_ismerge=yes; else h_ismerge=no; fi
  if wsp_is_local_first_repo "$probe" 2>/dev/null; then h_islocal=yes; else h_islocal=no; fi
fi

# next_ticket_number is a real bookkeep call — it reads tickets.md if present.
# We call it with the workspace's tickets file (harmless read); on any error
# capture and continue.
if [[ -f "${TICKETS_FILE:-}" ]]; then
  h_next_ticket="$(govern::next_ticket_number 2>&1)" || problems+=("next_ticket_number errored: $h_next_ticket")
else
  warn_only+=("tickets file missing at ${TICKETS_FILE:-<unset>} — skipped next_ticket_number probe")
fi

# meta_root — govern::meta_root cd's into $QUEUE_DIR (the queue folder) as part of
# resolving the meta repo. If the queue dir doesn't exist yet (a very fresh scaffold or
# a hermetic test stub), meta_root errors — treat that as a WARNING, not a hard problem,
# because the rest of the config check has already validated the knobs it can.
h_meta_root="$(govern::meta_root 2>&1)"; _mr_rc=$?
if [[ "$_mr_rc" -ne 0 ]]; then
  warn_only+=("govern::meta_root errored (queue dir absent?): $h_meta_root")
  h_meta_root="<unresolved>"
fi

# Root remote — a first-class status line. The governor pushes meta-repo runtime
# artifacts (tickets.md CAS, harness commits) to the root's origin, and
# cross-driver ticket sync depends on it. A wrap-in-place scaffold can leave the
# root remote-less ("skip for now"), silently DISABLING those paths.
h_root_remote=""
if [[ "$h_meta_root" != "<unresolved>" ]] && git -C "$h_meta_root" rev-parse --git-dir >/dev/null 2>&1; then
  h_root_remote="$(git -C "$h_meta_root" remote 2>/dev/null | tr '\n' ' ')"
  h_root_remote="${h_root_remote% }"
fi
if [[ -z "$h_root_remote" ]]; then
  warn_only+=("root has no git remote: governor CAS pushes + cross-driver ticket sync are DISABLED (gh repo create / git remote add origin <url>)")
fi

# Optional feature-flag combinatorics: if EXTERNALIZE_LANE is 1 but REPO+SUBREPO are empty,
# the lane no-ops (documented). Not a failure; but adopters mixing partial values want a note.
if [[ "${GOVERN_EXTERNALIZE_LANE:-0}" == "1" ]]; then
  if [[ -z "${GOVERN_EXTERNALIZE_REPO:-}" || -z "${GOVERN_EXTERNALIZE_SUBREPO:-}" ]]; then
    warn_only+=("GOVERN_EXTERNALIZE_LANE=1 but REPO/SUBREPO empty — lane no-ops (expected for pure-consumer instances)")
  fi
fi

# ── Emit report ──
if [[ "$MODE" == json ]]; then
  jq -n \
    --arg meta_root      "$h_meta_root" \
    --arg root_remote    "$h_root_remote" \
    --arg meta_name      "${META_NAME:-}" \
    --arg github_org     "${GITHUB_ORG:-}" \
    --arg root_pm        "${ROOT_PM:-}" \
    --arg worktree_base  "${WORKTREE_BASE:-}" \
    --argjson repos      "$(printf '%s\n' "${REPOS[@]}" | jq -R . | jq -s .)" \
    --arg h_slug         "$h_slug" \
    --arg h_localdir     "$h_localdir" \
    --arg h_port         "$h_port" \
    --arg h_cmd          "$h_cmd" \
    --arg h_ismerge      "$h_ismerge" \
    --arg h_islocal      "$h_islocal" \
    --arg h_next_ticket  "$h_next_ticket" \
    --argjson opt_seen   "$(printf '%s\n' "${opt_seen[@]}" | jq -R . | jq -s .)" \
    --argjson problems   "$( { [ "${#problems[@]}"  -gt 0 ] && printf '%s\n' "${problems[@]}"; } | jq -R . | jq -s '. | map(select(. != ""))')" \
    --argjson warn_only  "$( { [ "${#warn_only[@]}" -gt 0 ] && printf '%s\n' "${warn_only[@]}"; } | jq -R . | jq -s '. | map(select(. != ""))')" \
    '{meta_root:$meta_root, root_remote:$root_remote, meta_name:$meta_name, github_org:$github_org,
      root_pm:$root_pm, worktree_base:$worktree_base, repos:$repos,
      helpers: {repo_slug:$h_slug, repo_localdir:$h_localdir, repo_port:$h_port,
               repo_cmd:$h_cmd, is_merge_repo:$h_ismerge, is_local_first:$h_islocal,
               next_ticket_number:$h_next_ticket},
      knobs:$opt_seen, problems:$problems, warnings:$warn_only}'
else
  echo "════════ config-check (no-auth smoke) ════════"
  echo "meta_root       : $h_meta_root"
  echo "root remote     : ${h_root_remote:-<none — governor CAS/ticket-sync DISABLED>}"
  echo "META_NAME       : ${META_NAME:-<empty>}"
  echo "GITHUB_ORG      : ${GITHUB_ORG:-<empty>}"
  echo "ROOT_PM         : ${ROOT_PM:-<empty>}"
  echo "WORKTREE_BASE   : ${WORKTREE_BASE:-<empty>}"
  echo "REPOS (${#REPOS[@]})         : ${REPOS[*]}"
  echo ""
  echo "── helper probes (with '${REPOS[0]:-<no-repo>}') ──"
  echo "  wsp_repo_slug        : $h_slug"
  echo "  wsp_repo_localdir    : $h_localdir"
  echo "  wsp_repo_port slot 0 : $h_port"
  echo "  wsp_repo_cmd         : $h_cmd"
  echo "  wsp_is_merge_repo    : $h_ismerge"
  echo "  wsp_is_local_first   : $h_islocal"
  echo "  next_ticket_number   : ${h_next_ticket:-<skipped>}"
  echo ""
  echo "── optional knobs ──"
  for e in "${opt_seen[@]}"; do echo "  $e"; done
  if [[ "${#warn_only[@]}" -gt 0 ]]; then
    echo ""
    echo "── notices ──"
    for w in "${warn_only[@]}"; do echo "  · $w"; done
  fi
  if [[ "${#problems[@]}" -gt 0 ]]; then
    echo ""
    echo "── PROBLEMS ──"
    for p in "${problems[@]}"; do echo "  ✗ $p"; done
    exit 1
  fi
  echo ""
  echo "✓ every required knob resolves; every helper returned"
fi
exit 0
