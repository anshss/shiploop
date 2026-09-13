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

# ── Worker model floor/ceiling: a HARD assertion, not informational ──
# GOVERN_WORKER_MODEL (floor, every attempt) and GOVERN_WORKER_ESCALATION_MODEL (the CAP on what an
# explicit request may ask for) are deliberately two knobs (see workspace.sh). The assertion SURVIVED
# the removal of automatic escalation, with a new meaning: a cap at or below the floor means every
# dispatch already runs at or above the highest tier anyone is allowed to request, so the cap knob
# controls nothing and reads as configured when it is inert. `${VAR:-default}` lets a downstream
# fleet's environment collapse them to the same tier SILENTLY, with no signal that it happened.
# Assert it here as a hard PROBLEM (drives exit 1 below), not a warn_only print.
#
# Reuse the repo's own tier ordering (govern::model_rank, defined in lib/common.sh and already
# used on the spawn-worker.sh sizing path) instead of hard-coding a
# second list of model names here. govern::model_max itself is NOT enough for this check: on a
# tie it returns the second argument (the ceiling) unchanged ("b wins ties"), so
# `model_max(floor, ceiling) == ceiling` is true both when floor < ceiling (fine) AND when
# floor == ceiling (the exact no-op this assertion exists to catch): it cannot express a STRICT
# less-than. govern::model_rank, the primitive model_max is built on, can.
resolved_floor="${GOVERN_WORKER_MODEL:-sonnet}"
resolved_ceiling="${GOVERN_WORKER_ESCALATION_MODEL:-opus}"
floor_rank="$(govern::model_rank "$resolved_floor")"
ceiling_rank="$(govern::model_rank "$resolved_ceiling")"
if [[ "$floor_rank" -ge "$ceiling_rank" ]]; then
  problems+=("GOVERN_WORKER_MODEL='$resolved_floor' (floor, rank $floor_rank) is not strictly cheaper than GOVERN_WORKER_ESCALATION_MODEL='$resolved_ceiling' (the explicit-request cap, rank $ceiling_rank): a cap at or below the floor is inert, since every dispatch already runs at or above the highest tier a ticket Model: field may ask for")
fi

# ── Named-but-missing scripts — a HARD problem ──
# Nothing checked whether a rule or an npm script naming an installed script
# still points at a real file. Two live instances the same session: (a)
# package.json's OWN "govern:pre-dispatch" entry named
# scripts/govern/pre-dispatch-check.sh while this workspace's scripts/govern/
# had drifted far enough behind the hub that the file was simply absent; (b)
# CLAUDE.md documented `npm run govern` after a release deleted that npm-script
# key outright. Unlike a diverging knob value below, nothing legitimate
# explains either case, so both are hard problems, not warnings.
pkg_json="$WS_ROOT/package.json"
if [[ -f "$pkg_json" ]] && command -v jq >/dev/null 2>&1; then
  # (a) every npm script that literally invokes `bash|sh|node <path>`: the path
  # must exist. Scripts that shell out to something else (a binary, another npm
  # script) are out of scope — there is no local FILE to check.
  while IFS=$'\t' read -r skey scmd spath; do
    [[ -n "$spath" ]] || continue
    [[ -f "$WS_ROOT/$spath" ]] || problems+=("package.json script '$skey' runs '$scmd' but '$spath' does not exist on disk")
  done < <(jq -r '.scripts // {} | to_entries[] | [.key, .value, (.value | capture("^(?:bash|sh|node)\\s+(?<p>\\S+)").p // "")] | @tsv' "$pkg_json" 2>/dev/null)

  # (b) every `npm run <key>` / `pnpm run <key>` / `yarn run <key>` mentioned in
  # the root CLAUDE.md must still be a real package.json script key — the
  # "npm run govern" instance, where the rule outlived the script it named.
  # The `[A-Za-z0-9:_-]+` capture stops at the first space, so it already
  # tolerates the forms CLAUDE.md actually uses: trailing args
  # ("npm run govern:pre-dispatch -- <N>"), inside backticks, and inside a
  # markdown table cell — all verified by 20/21/22 below.
  #
  # A prose mention is a weaker signal than a package.json script that is
  # actually WIRED to a missing file (case (a) above): CLAUDE.md may
  # legitimately document a command for an optional module this fleet hasn't
  # installed. GOVERN_CLAUDE_SCRIPT_IGNORE (space-separated script-key list
  # in workspace.sh) is the declared-exemption escape, same shape as
  # GOVERN_CONFIG_DRIFT_ACK above, so a real gap still hard-fails by default
  # but an operator can name the deliberate exception instead of the check
  # either over-trusting prose or never catching the "npm run govern" case.
  claude_md="$WS_ROOT/CLAUDE.md"
  if [[ -f "$claude_md" ]]; then
    claude_ignore=" ${GOVERN_CLAUDE_SCRIPT_IGNORE:-} "
    while IFS= read -r rkey; do
      [[ -n "$rkey" ]] || continue
      case "$claude_ignore" in *" $rkey "*) continue ;; esac
      jq -e --arg k "$rkey" '.scripts // {} | has($k)' "$pkg_json" >/dev/null 2>&1 || \
        problems+=("CLAUDE.md references 'npm run $rkey' but package.json has no such script (declare it in GOVERN_CLAUDE_SCRIPT_IGNORE in workspace.sh if deliberate)")
    done < <(grep -ohE '(npm|pnpm|yarn) run [A-Za-z0-9:_-]+' "$claude_md" | awk '{print $3}' | sort -u)
  fi
fi

# ── Hub-default knob drift — a WARNING, never a hard problem ──
# A local knob running a different value than the hub ships is not itself a
# bug: a fleet may deliberately pin a floor/ceiling the hub no longer
# defaults to. The bug is drift NOBODY NOTICED — scripts/lib/workspace.sh is
# copied once at scaffold time and then deliberately never overwritten by an
# update (it is the one file holding per-workspace customization), so when the
# hub bumps a shipped default, an already-scaffolded workspace keeps the OLD
# one silently, forever, with no surface ever naming the gap.
#
# Compare against the hub template's CURRENT literal default instead of
# hardcoding a knob list: any `KNOB="${KNOB:-default}"` line in
# templates/lib/workspace.sh whose default is neither empty nor an unfilled
# `__PLACEHOLDER__` is a shared POLICY default (as opposed to per-workspace
# identity like META_NAME/REPOS, which use `__PLACEHOLDER__` substitution and
# so never match this pattern). Today that is exactly GOVERN_WORKER_MODEL and
# GOVERN_WORKER_ESCALATION_MODEL; the check stays correct if the hub adds
# another self-referential policy default later with no code change here.
#
# Hub resolution order matches /shiploop:update (commands/update.md): the
# installed plugin, then an operator's local fork clone, then the legacy
# skill path, then a plugin-cache glob. Soft-fails to one advisory line when
# none resolve (offline / a bare git clone with no plugin install) — the same
# "graceful when unresolvable" contract render_update_channel already holds
# to in govern-health.sh.
hub_ws_file=""
for _cand in "${CLAUDE_PLUGIN_ROOT:-}" "${GOVERN_UPSTREAM_HARNESS_DIR:-}" \
             "$HOME/.claude/skills/shiploop" \
             "$HOME/.claude/plugins/cache/claude-plugins-official/shiploop"; do
  [[ -n "$_cand" && -f "$_cand/templates/lib/workspace.sh" ]] && { hub_ws_file="$_cand/templates/lib/workspace.sh"; break; }
done
if [[ -z "$hub_ws_file" ]]; then
  for _cand in "$HOME"/.claude/plugins/*/shiploop/templates/lib/workspace.sh \
               "$HOME"/.claude/plugins/*/*/shiploop/templates/lib/workspace.sh; do
    [[ -f "$_cand" ]] && { hub_ws_file="$_cand"; break; }
  done
fi
if [[ -n "$hub_ws_file" ]]; then
  ack_list=" ${GOVERN_CONFIG_DRIFT_ACK:-} "
  while IFS=$'\t' read -r kname kdefault; do
    [[ -n "$kname" ]] || continue
    case "$kdefault" in __*__) continue ;; esac   # per-workspace identity placeholder, not a shared default
    case "$ack_list" in *" $kname "*) continue ;; esac   # declared override — stop warning
    cur="${!kname:-$kdefault}"
    if [[ "$cur" != "$kdefault" ]]; then
      warn_only+=("knob '$kname' diverges from hub default: local='$cur' hub default='$kdefault' — if deliberate, add it to GOVERN_CONFIG_DRIFT_ACK in workspace.sh to stop this warning")
    fi
  done < <(sed -nE 's/^([A-Za-z_][A-Za-z0-9_]*)="\$\{[A-Za-z_][A-Za-z0-9_]*:-([^}]+)\}".*/\1\t\2/p' "$hub_ws_file")
else
  warn_only+=("hub not resolvable (no CLAUDE_PLUGIN_ROOT / GOVERN_UPSTREAM_HARNESS_DIR / ~/.claude/skills/shiploop) — skipped hub-default knob-drift check")
fi

# ── Optional knobs (informational) ──
opt_seen=()
for k in GOVERN_MERGE_REPOS GOVERN_LOCAL_FIRST_REPOS \
         GOVERN_MODEL_CEILING GOVERN_SESSION_MODEL \
         GOVERN_SCOUT GOVERN_SCOUT_MODEL GOVERN_SCOUT_TIMEOUT \
         GOVERN_EXTERNALIZE_LANE GOVERN_EXTERNALIZE_REPO GOVERN_EXTERNALIZE_SUBREPO \
         GOVERN_EXTERNALIZE_LABELS WSP_LINT_FIX_CMD GOVERN_MIGRATE_CMD GOVERN_VERIFY_CMD \
         GOVERN_UPSTREAM_HARNESS_REPO GOVERN_UPSTREAM_HARNESS_DIR \
         GOVERN_BATCH_MAX \
         GOVERN_STALENESS_GATE GOVERN_STALENESS_RUN_TESTS GOVERN_STALENESS_TEST_TIMEOUT \
         GOVERN_INDEX GOVERN_INDEX_DIR GOVERN_INDEX_MAX_FILES GOVERN_INDEX_CTAGS \
         GOVERN_VERIFY_FILTER GOVERN_VERIFY_FILTER_MAX_LINES \
         GOVERN_EARLY_ABORT GOVERN_EARLY_ABORT_TURNS GOVERN_EARLY_ABORT_REPEATS \
         GOVERN_RUN_MAX_TOKENS \
         GOVERN_CI_LOG_MAX_LINES \
         GOVERN_LESSON_SINK GOVERN_LESSON_LADDER GOVERN_LESSON_EVICT \
         GOVERN_LESSON_MAX_CHARS GOVERN_LESSON_BUDGET_CHARS \
         SHIPLOOP_LEARNINGS_TTL SHIPLOOP_LEARNINGS_TTL_DAYS SHIPLOOP_LEARNINGS_LINT; do
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

# next_ticket_number is a real allocator call, so this health probe uses GOVERN_SEQ_PEEK=1 to read
# it WITHOUT bumping governor/.ticket-seq (a health check must never mutate the operator's git tree).
# We call it with the workspace's tickets file (harmless read); on any error capture and continue.
if [[ -f "${TICKETS_FILE:-}" ]]; then
  h_next_ticket="$(GOVERN_SEQ_PEEK=1 govern::next_ticket_number 2>&1)" || problems+=("next_ticket_number errored: $h_next_ticket")
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

# With no GOVERN_MIGRATE_CMD configured, a migration-shaped ticket sitting in the backlog is a
# silent gap today: the only existing detection is REACTIVE, resolve-ticket.sh's
# mneeded/GOVERN_MIGRATE_CMD check, which fires AFTER a worker has already built and opened a PR
# for it (confirmed via
# preflight-main.sh/govern-health.sh: neither checks this pre-run). Surface it proactively here as a
# dedicated notice — NOT buried among the ~9 neutral optional-knob lines below — so the operator sees
# it before a worker is ever burned on it.
if [[ -z "${GOVERN_MIGRATE_CMD:-}" && -f "${TICKETS_FILE:-}" ]]; then
  h_migrate_hit="$(grep -inE 'migration|schema change|alter table' "$TICKETS_FILE" 2>/dev/null | sed -n '1p' || true)"
  if [[ -n "$h_migrate_hit" ]]; then
    warn_only+=("GOVERN_MIGRATE_CMD is unset but tickets.md has a migration-shaped entry — it will escalate for a manual apply if/when picked up: $h_migrate_hit")
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
    --arg resolved_floor   "$resolved_floor" \
    --arg resolved_ceiling "$resolved_ceiling" \
    --argjson floor_rank   "$floor_rank" \
    --argjson ceiling_rank "$ceiling_rank" \
    --argjson opt_seen   "$(printf '%s\n' "${opt_seen[@]}" | jq -R . | jq -s .)" \
    --argjson problems   "$( { [ "${#problems[@]}"  -gt 0 ] && printf '%s\n' "${problems[@]}"; } | jq -R . | jq -s '. | map(select(. != ""))')" \
    --argjson warn_only  "$( { [ "${#warn_only[@]}" -gt 0 ] && printf '%s\n' "${warn_only[@]}"; } | jq -R . | jq -s '. | map(select(. != ""))')" \
    '{meta_root:$meta_root, root_remote:$root_remote, meta_name:$meta_name, github_org:$github_org,
      root_pm:$root_pm, worktree_base:$worktree_base, repos:$repos,
      helpers: {repo_slug:$h_slug, repo_localdir:$h_localdir, repo_port:$h_port,
               repo_cmd:$h_cmd, is_merge_repo:$h_ismerge, is_local_first:$h_islocal,
               next_ticket_number:$h_next_ticket},
      model_tiers: {floor:$resolved_floor, floor_rank:$floor_rank,
                    ceiling:$resolved_ceiling, ceiling_rank:$ceiling_rank},
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
  echo "── worker model floor/ceiling ──"
  echo "  GOVERN_WORKER_MODEL            (floor)   : $resolved_floor (rank $floor_rank)"
  echo "  GOVERN_WORKER_ESCALATION_MODEL (ceiling) : $resolved_ceiling (rank $ceiling_rank)"
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
