#!/usr/bin/env bash
# scaffold.sh — deterministic scaffolder for meta-repo-harness.
#
# Extracted from commands/setup.md so the agent no longer performs mechanical
# file copies. The command still owns the interview + detection; this script
# owns the byte-level file operations that must be idempotent and reproducible.
#
# Usage (fresh scaffold):
#   scaffold.sh \
#     --workspace-dir /path/to/workspace \
#     --pm npm \
#     --org my-github-org \
#     --repos "backend:3080:npm run dev,console:3000:pnpm dev,site::" \
#     --merge-allowlist "backend" \
#     --worktree-base '$HOME/code/workspace.wt' \
#     --git-init \
#     --verify \
#     --yes
#
# Usage (refresh one component in place):
#   scaffold.sh --workspace-dir . --component govern
#
# Components: core-scripts, worktrees, govern, hooks, githooks, seeds,
#             gitignore, package-json, settings, all
#
# The script is IDEMPOTENT: re-running it refreshes mechanism scripts from the
# bundled templates without clobbering scripts/lib/workspace.sh (the ONE file
# holding per-workspace customization). Seed files (queue/, CLAUDE.md,
# governor/preferences.md) are never overwritten if present.

set -euo pipefail

# ── Resolve templates directory (dual-mode: plugin OR legacy clone) ──────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES_DIR=""

# ── Hub version (VERSION file at hub root — the update-channel anchor) ──────
# Read it lazily; not every code path needs it. --version + the stamp file both
# use hub_version(). If the file is missing (very old hub clone), fall back to
# "unknown" so the script still runs.
hub_version() {
  if [ -f "$SCRIPT_DIR/VERSION" ]; then
    awk 'NF && $0 !~ /^#/ {print $1; exit}' "$SCRIPT_DIR/VERSION"
  else
    echo unknown
  fi
}

# ── Defaults ────────────────────────────────────────────────────────────────
WORKSPACE_DIR=""
PM="npm"
ORG=""
REPOS_SPEC=""
MERGE_ALLOWLIST=""
WORKTREE_BASE=""
COMPONENT="all"
DO_GIT_INIT=0
DO_VERIFY=0
RUN_TESTS=0
YES=0
VERBOSE=0
DIFF_ONLY=0

usage() {
  sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

log()   { printf '── %s\n' "$*" >&2; }
info()  { printf '   %s\n' "$*" >&2; }
warn()  { printf '!! %s\n' "$*" >&2; }
die()   { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ── Parse flags ─────────────────────────────────────────────────────────────
while [ "$#" -gt 0 ]; do
  case "$1" in
    --workspace-dir)     WORKSPACE_DIR="$2"; shift 2 ;;
    --pm)                PM="$2"; shift 2 ;;
    --org)               ORG="$2"; shift 2 ;;
    --repos)             REPOS_SPEC="$2"; shift 2 ;;
    --merge-allowlist)   MERGE_ALLOWLIST="$2"; shift 2 ;;
    --worktree-base)     WORKTREE_BASE="$2"; shift 2 ;;
    --templates)         TEMPLATES_DIR="$2"; shift 2 ;;
    --component)         COMPONENT="$2"; shift 2 ;;
    --git-init)          DO_GIT_INIT=1; shift ;;
    --verify)            DO_VERIFY=1; shift ;;
    --run-tests)         RUN_TESTS=1; shift ;;
    --yes|-y)            YES=1; shift ;;
    --verbose|-v)        VERBOSE=1; shift ;;
    --diff-only)         DIFF_ONLY=1; shift ;;
    --version)           hub_version; exit 0 ;;
    -h|--help)           usage ;;
    *)                   die "unknown flag: $1 (see --help)" ;;
  esac
done

# ── Resolve templates ───────────────────────────────────────────────────────
if [ -z "$TEMPLATES_DIR" ]; then
  if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -d "$CLAUDE_PLUGIN_ROOT/templates" ]; then
    TEMPLATES_DIR="$CLAUDE_PLUGIN_ROOT/templates"
  elif [ -d "$SCRIPT_DIR/templates" ]; then
    TEMPLATES_DIR="$SCRIPT_DIR/templates"
  else
    die "cannot locate templates/ — pass --templates or set CLAUDE_PLUGIN_ROOT"
  fi
fi
[ -d "$TEMPLATES_DIR" ] || die "templates dir does not exist: $TEMPLATES_DIR"
T="$TEMPLATES_DIR"

# ── Validate workspace ──────────────────────────────────────────────────────
[ -n "$WORKSPACE_DIR" ] || die "--workspace-dir is required"
mkdir -p "$WORKSPACE_DIR"
WORKSPACE_DIR="$(cd "$WORKSPACE_DIR" && pwd)"
cd "$WORKSPACE_DIR"

case "$PM" in npm|pnpm|yarn|bun) ;; *) die "--pm must be npm|pnpm|yarn|bun (got: $PM)" ;; esac

# ── Parse repos spec: "name:port:cmd,name:port:cmd" ─────────────────────────
declare -a REPO_NAMES=()
declare -a REPO_PORTS=()
declare -a REPO_CMDS=()

if [ -n "$REPOS_SPEC" ]; then
  # Split by comma, then by first two colons (cmd may contain colons).
  IFS=',' read -r -a _entries <<<"$REPOS_SPEC"
  for entry in "${_entries[@]}"; do
    [ -n "$entry" ] || continue
    _name="${entry%%:*}"; _rest="${entry#*:}"
    if [ "$_rest" = "$entry" ]; then
      # no colon → just a name
      REPO_NAMES+=("$_name"); REPO_PORTS+=(""); REPO_CMDS+=("")
      continue
    fi
    _port="${_rest%%:*}"; _cmd="${_rest#*:}"
    if [ "$_cmd" = "$_rest" ]; then _cmd=""; fi
    REPO_NAMES+=("$_name")
    REPO_PORTS+=("$_port")
    REPO_CMDS+=("$_cmd")
  done
fi

# ── Utility: write only if changed (returns 0 if wrote, 1 if unchanged) ─────
write_if_changed() {
  local target="$1"; local content="$2"
  if [ -f "$target" ] && [ "$(cat "$target")" = "$content" ]; then
    [ "$VERBOSE" -eq 1 ] && info "unchanged: $target"
    return 1
  fi
  printf '%s' "$content" > "$target"
  [ "$VERBOSE" -eq 1 ] && info "wrote:     $target"
  return 0
}

# ── Component implementations ───────────────────────────────────────────────

component_dirs() {
  mkdir -p scripts/lib scripts/worktree/lib scripts/govern/lib scripts/govern/test
  mkdir -p governor .worktrees .claude/commands .githooks queue
  touch .worktrees/.gitkeep
}

component_workspace_sh() {
  log "component: workspace.sh (config file)"

  # ── Knob-type migration guard (v1.1.0 → v1.2.0): the string knobs
  # GOVERN_MERGE_REPOS and GOVERN_LOCAL_FIRST_REPOS used to be bash arrays
  # (VAR=(...)). A stale workspace.sh with the old array shape *coincidentally*
  # keeps working for the single-element case (`$VAR` yields the first token)
  # so silent migration is a real footgun. On any legacy shape here, WARN
  # loudly with the exact mechanical translation and refuse to touch the file
  # (unless --yes overrides). No --yes = no regen either way, but the guard
  # runs first so the operator sees the migration before deciding.
  if [ -f scripts/lib/workspace.sh ]; then
    local legacy_hit=""
    if grep -Eq '^[[:space:]]*GOVERN_MERGE_REPOS=\(' scripts/lib/workspace.sh; then
      legacy_hit+="GOVERN_MERGE_REPOS "
    fi
    if grep -Eq '^[[:space:]]*GOVERN_LOCAL_FIRST_REPOS=\(' scripts/lib/workspace.sh; then
      legacy_hit+="GOVERN_LOCAL_FIRST_REPOS "
    fi
    if [ -n "$legacy_hit" ]; then
      warn "workspace.sh uses LEGACY bash-array form for: $legacy_hit"
      warn "  v1.1.0 changed these knobs from array to space-separated STRING."
      warn "  Mechanical migration (single-element arrays keep working by accident, multi-element BREAK):"
      warn '    GOVERN_MERGE_REPOS=(foo bar)         → GOVERN_MERGE_REPOS="foo bar"'
      warn '    GOVERN_LOCAL_FIRST_REPOS=(baz)       → GOVERN_LOCAL_FIRST_REPOS="baz"'
      warn "  Do the rewrite by hand OR re-run with --component workspace-sh --yes to regenerate."
    fi
  fi

  [ -n "$ORG" ] || die "--org is required for workspace.sh"
  [ "${#REPO_NAMES[@]}" -gt 0 ] || die "--repos required (at least one)"

  local wt_base="${WORKTREE_BASE:-\$HOME/code/$(basename "$WORKSPACE_DIR").wt}"
  local meta_name; meta_name="$(basename "$WORKSPACE_DIR")"

  # Build quoted arrays for placeholders.
  local repos_join=""; local cmds_join=""; local ports_join=""
  local i
  for i in "${!REPO_NAMES[@]}"; do
    repos_join+="${REPO_NAMES[$i]} "
    cmds_join+="\"${REPO_CMDS[$i]}\" "
    if [ -z "${REPO_PORTS[$i]}" ]; then
      ports_join+='"" '
    else
      ports_join+="${REPO_PORTS[$i]} "
    fi
  done
  repos_join="${repos_join% }"
  cmds_join="${cmds_join% }"
  ports_join="${ports_join% }"

  if [ -f scripts/lib/workspace.sh ] && [ "$YES" -eq 0 ]; then
    warn "scripts/lib/workspace.sh already exists — refusing to overwrite (pass --yes to force)"
    return 0
  fi

  # Substitute placeholders.
  local content; content="$(cat "$T/lib/workspace.sh")"
  content="${content//__META_NAME__/$meta_name}"
  content="${content//__GITHUB_ORG__/$ORG}"
  content="${content//__REPOS__/$repos_join}"
  content="${content//__REPO_CMDS__/$cmds_join}"
  content="${content//__REPO_PORTS__/$ports_join}"
  content="${content//__WORKTREE_BASE__/$wt_base}"
  content="${content//__GOVERN_MERGE_REPOS__/$MERGE_ALLOWLIST}"
  # Set ROOT_PM (line: ROOT_PM="npm").
  content="$(printf '%s\n' "$content" | sed -E "s|^ROOT_PM=\".*\"|ROOT_PM=\"$PM\"|")"

  printf '%s\n' "$content" > scripts/lib/workspace.sh
  chmod 644 scripts/lib/workspace.sh
  info "wrote scripts/lib/workspace.sh"

  # Example project hooks (safe: only .example files, user renames to enable).
  cp "$T/lib/worktree-bootstrap.sh.example" scripts/lib/ 2>/dev/null || true
  cp "$T/lib/session-cleanup.sh.example" scripts/lib/ 2>/dev/null || true
  cp "$T/lib/doctor-extra.sh.example" scripts/lib/ 2>/dev/null || true
}

component_core_scripts() {
  log "component: core scripts"
  local s
  for s in status doctor branch switch dev pull-all push-prs health sync tail investigate; do
    cp "$T/$s.sh" "scripts/$s.sh"
    chmod +x "scripts/$s.sh"
  done
  # hooks that live in scripts/
  cp "$T/hooks/check-main-on-main.sh" scripts/
  cp "$T/hooks/ticket-sweep-reminder.sh" scripts/
  cp "$T/hooks/session-snapshot.sh" scripts/
  cp "$T/hooks/router-posture-reminder.sh" scripts/
  cp "$T/hooks/router-posture-guard.sh" scripts/
  chmod +x scripts/*.sh
  # sourced libs (no +x needed but harmless)
  cp "$T/lib/session-state.sh" scripts/lib/
  cp "$T/lib/preflight.sh" scripts/lib/
  cp "$T/lib/githooks.sh" scripts/lib/
  info "installed core scripts + hooks + libs"
}

component_worktrees() {
  log "component: worktrees"
  cp "$T/worktree/new.sh" "$T/worktree/rm.sh" "$T/worktree/status.sh" \
     "$T/worktree/exec.sh" "$T/worktree/main.sh" "$T/worktree/session-end-cleanup.sh" \
     scripts/worktree/
  cp "$T/worktree/lib/registry.sh" "$T/worktree/lib/base-ref.sh" scripts/worktree/lib/
  chmod +x scripts/worktree/*.sh
  info "installed worktree scripts"
}

component_govern() {
  log "component: govern"
  cp "$T"/govern/*.sh scripts/govern/
  cp "$T"/govern/lib/common.sh scripts/govern/lib/
  cp "$T"/govern/test/*.sh scripts/govern/test/
  chmod +x scripts/govern/*.sh scripts/govern/test/*.sh
  # governor/*.md — refresh prompt templates only; preserve operator data.
  local mf
  for mf in worker-prompt.md supervisor-prompt.md README.md sync-porter-prompt.md; do
    [ -f "$T/governor/$mf" ] && cp "$T/governor/$mf" "governor/$mf"
  done
  # Never clobber the operator's data.
  local pref
  for pref in preferences.md decisions-log.md escalations.md improvements.md; do
    if [ ! -f "governor/$pref" ]; then
      cp "$T/governor/$pref" "governor/$pref"
    fi
  done
  info "installed govern scripts + tests + governor prompts"
}

component_githooks() {
  log "component: git-hooks enforcement"
  cp "$T/githooks/pre-push" "$T/githooks/prepare-commit-msg" "$T/githooks/pre-commit" .githooks/
  chmod +x .githooks/pre-push .githooks/prepare-commit-msg .githooks/pre-commit
  # Activate hooks in the harness root (idempotent).
  if [ -d .git ]; then
    git config core.hooksPath .githooks
    info "activated core.hooksPath = .githooks"
  else
    info "no .git yet — core.hooksPath activation deferred to first git init"
  fi
}

component_project_commands() {
  log "component: project-local /govern + /resolve + /investigate"
  cp "$T"/.claude/commands/*.md .claude/commands/ 2>/dev/null || true
  info "installed .claude/commands/"
}

component_seeds() {
  log "component: seeds (never overwrite)"
  [ -f queue/tickets.md ]        || cp "$T/seed/tickets.md" queue/
  [ -f queue/tickets-parked.md ] || cp "$T/seed/tickets-parked.md" queue/
  [ -f learnings.md ]            || cp "$T/seed/learnings.md" .
  [ -f CLAUDE.md ]               || cp "$T/seed/CLAUDE.md" .
  info "seeds present"
}

component_gitignore() {
  log "component: .gitignore"
  local subrepo_lines=""
  local i
  for i in "${!REPO_NAMES[@]}"; do
    subrepo_lines+="/${REPO_NAMES[$i]}/"$'\n'
  done
  subrepo_lines="${subrepo_lines%$'\n'}"

  local lockfile_lines=""
  case "$PM" in
    npm)  lockfile_lines=$'/pnpm-lock.yaml\n/yarn.lock\n/bun.lockb' ;;
    pnpm) lockfile_lines=$'/pnpm-lock.yaml\n/package-lock.json\n/yarn.lock\n/bun.lockb' ;;
    yarn) lockfile_lines=$'/package-lock.json\n/pnpm-lock.yaml\n/bun.lockb' ;;
    bun)  lockfile_lines=$'/package-lock.json\n/pnpm-lock.yaml\n/yarn.lock' ;;
  esac

  # Substitute multiline placeholders line-by-line (portable, pure bash).
  local content=""
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      __SUBREPO_IGNORES__)      content+="$subrepo_lines"$'\n' ;;
      __ROOT_LOCKFILE_IGNORES__) content+="$lockfile_lines"$'\n' ;;
      *)                         content+="$line"$'\n' ;;
    esac
  done < "$T/gitignore"

  if [ -f .gitignore ]; then
    # Merge: append any missing lines from the generated content.
    local tmp; tmp="$(mktemp)"
    {
      cat .gitignore
      printf '\n# — meta-repo-harness scaffolded additions —\n'
      # Append only lines not already present in existing .gitignore.
      while IFS= read -r line; do
        if ! grep -Fxq "$line" .gitignore 2>/dev/null; then
          printf '%s\n' "$line"
        fi
      done <<<"$content"
    } > "$tmp"
    mv "$tmp" .gitignore
    info "merged into existing .gitignore"
  else
    printf '%s\n' "$content" > .gitignore
    info "wrote .gitignore"
  fi
}

component_package_json() {
  log "component: package.json"
  local repo
  local dev_lines=""
  for repo in "${REPO_NAMES[@]}"; do
    dev_lines+="    \"dev:$repo\": \"bash scripts/dev.sh --only $repo\",\n"
  done
  local content
  content=$(cat <<EOF
{
  "name": "$(basename "$WORKSPACE_DIR")-meta-repo",
  "version": "0.1.0",
  "private": true,
  "scripts": {
    "dev": "bash scripts/dev.sh",
$(printf "$dev_lines" | sed '/^$/d')
    "status": "bash scripts/status.sh",
    "doctor": "bash scripts/doctor.sh",
    "branch": "bash scripts/branch.sh",
    "switch": "bash scripts/switch.sh",
    "pull": "bash scripts/pull-all.sh",
    "push": "bash scripts/push-prs.sh",
    "sync": "bash scripts/sync.sh",
    "tail": "bash scripts/tail.sh",
    "health": "bash scripts/health.sh",
    "worktree": "bash scripts/worktree/main.sh",
    "worktree:new": "bash scripts/worktree/new.sh",
    "worktree:rm": "bash scripts/worktree/rm.sh",
    "worktree:status": "bash scripts/worktree/status.sh",
    "worktree:exec": "bash scripts/worktree/exec.sh",
    "govern": "bash scripts/govern/run-loop.sh",
    "govern:health": "bash scripts/govern/govern-health.sh",
    "govern:dry-run": "bash scripts/govern/dry-run.sh"
  }
}
EOF
)
  if [ -f package.json ] && [ "$YES" -eq 0 ]; then
    warn "package.json exists — leaving as-is (pass --yes to overwrite)"
  else
    printf '%s\n' "$content" > package.json
    info "wrote package.json"
  fi
}

component_settings() {
  log "component: .claude/settings.json"
  local root="$WORKSPACE_DIR"
  local content
  content=$(cat <<EOF
{
  "hooks": {
    "SessionStart": [{ "matcher": "*", "hooks": [
      { "type": "command", "command": "bash $root/scripts/session-snapshot.sh 2>/dev/null || true", "timeout": 15 },
      { "type": "command", "command": "if [ -f $root/learnings.md ]; then echo '── workspace learnings ──'; head -30 $root/learnings.md; echo '...'; fi", "timeout": 5 },
      { "type": "command", "command": "bash $root/scripts/check-main-on-main.sh 2>/dev/null || true", "timeout": 10 }
    ]}],
    "UserPromptSubmit": [{ "matcher": "*", "hooks": [
      { "type": "command", "command": "bash $root/scripts/router-posture-reminder.sh 2>/dev/null || true", "timeout": 10 }
    ]}],
    "PreToolUse": [{ "matcher": "Read|Bash", "hooks": [
      { "type": "command", "command": "bash $root/scripts/router-posture-guard.sh 2>/dev/null || true", "timeout": 10 }
    ]}],
    "Stop": [{ "matcher": "*", "hooks": [
      { "type": "command", "command": "bash $root/scripts/ticket-sweep-reminder.sh", "timeout": 15 }
    ]}],
    "SessionEnd": [{ "matcher": "*", "hooks": [
      { "type": "command", "command": "bash $root/scripts/worktree/session-end-cleanup.sh 2>/dev/null || true", "timeout": 90 }
    ]}]
  }
}
EOF
)
  if [ -f .claude/settings.json ] && [ "$YES" -eq 0 ]; then
    warn ".claude/settings.json exists — leaving as-is (pass --yes to overwrite, or use --component settings-merge to add just the harness hooks)"
  else
    printf '%s\n' "$content" > .claude/settings.json
    info "wrote .claude/settings.json"
  fi
}

# component_settings_merge — idempotently insert the harness hook stanzas into
# an EXISTING .claude/settings.json using jq, without touching anything else in
# that file. Solves the "merge missing hook entries yourself" hand-edit from
# setup.md's B2 (adopter-friction #3 from the tokenjam convergence).
#
# Insertion rule per event (SessionStart/UserPromptSubmit/PreToolUse/Stop/
# SessionEnd): if a matcher entry exists that references any of the harness
# scripts, leave it alone (idempotent — re-run is a no-op). Otherwise APPEND a
# new matcher block carrying just the harness's own hooks. Never delete or
# re-order existing entries.
component_settings_merge() {
  log "component: settings-merge (idempotent hook stanzas into existing .claude/settings.json)"
  command -v jq >/dev/null 2>&1 || die "settings-merge needs jq (brew install jq)"
  mkdir -p .claude
  local target=".claude/settings.json"
  if [ ! -f "$target" ]; then
    warn "$target absent — nothing to merge into; run --component settings to create it fresh"
    return 0
  fi
  local root="$WORKSPACE_DIR"
  # Reference stanzas — same commands as component_settings. jq --argjson pulls
  # each in as a value; the pipeline walks .hooks.<event> and appends the
  # harness stanza IFF no existing matcher entry mentions a harness-script name.
  local session_start user_prompt pre_tool stop session_end
  session_start=$(cat <<EOF
{ "matcher": "*", "hooks": [
  { "type": "command", "command": "bash $root/scripts/session-snapshot.sh 2>/dev/null || true", "timeout": 15 },
  { "type": "command", "command": "if [ -f $root/learnings.md ]; then echo '── workspace learnings ──'; head -30 $root/learnings.md; echo '...'; fi", "timeout": 5 },
  { "type": "command", "command": "bash $root/scripts/check-main-on-main.sh 2>/dev/null || true", "timeout": 10 }
] }
EOF
)
  user_prompt=$(cat <<EOF
{ "matcher": "*", "hooks": [
  { "type": "command", "command": "bash $root/scripts/router-posture-reminder.sh 2>/dev/null || true", "timeout": 10 }
] }
EOF
)
  pre_tool=$(cat <<EOF
{ "matcher": "Read|Bash", "hooks": [
  { "type": "command", "command": "bash $root/scripts/router-posture-guard.sh 2>/dev/null || true", "timeout": 10 }
] }
EOF
)
  stop=$(cat <<EOF
{ "matcher": "*", "hooks": [
  { "type": "command", "command": "bash $root/scripts/ticket-sweep-reminder.sh", "timeout": 15 }
] }
EOF
)
  session_end=$(cat <<EOF
{ "matcher": "*", "hooks": [
  { "type": "command", "command": "bash $root/scripts/worktree/session-end-cleanup.sh 2>/dev/null || true", "timeout": 90 }
] }
EOF
)
  # Marker substrings — if ANY of these appear in an existing event's hooks[].command,
  # we treat that event as already-wired for the harness and leave it alone.
  # (One marker per event; a single match is enough to skip.)
  local jq_prog
  jq_prog=$(cat <<'JQ'
def wire(event; markers; stanza):
  .hooks[event] as $existing
  | if ($existing // []) | tostring | test(markers) then . else
      .hooks[event] = (($existing // []) + [stanza])
    end;
.
| (if .hooks == null then .hooks = {} else . end)
| wire("SessionStart";     "session-snapshot\\.sh|check-main-on-main\\.sh"; $ss)
| wire("UserPromptSubmit"; "router-posture-reminder\\.sh";                   $up)
| wire("PreToolUse";       "router-posture-guard\\.sh";                      $pt)
| wire("Stop";             "ticket-sweep-reminder\\.sh";                     $sp)
| wire("SessionEnd";       "session-end-cleanup\\.sh";                       $se)
JQ
)
  local tmp; tmp="$(mktemp)"
  if jq --argjson ss "$session_start" \
        --argjson up "$user_prompt" \
        --argjson pt "$pre_tool" \
        --argjson sp "$stop" \
        --argjson se "$session_end" \
        "$jq_prog" "$target" > "$tmp"; then
    if ! diff -q "$target" "$tmp" >/dev/null 2>&1; then
      mv "$tmp" "$target"
      info "merged harness hook stanzas into $target"
    else
      rm -f "$tmp"
      info "$target already carries harness hooks — no changes needed (idempotent)"
    fi
  else
    rm -f "$tmp"
    die "jq failed to merge into $target (invalid JSON?)"
  fi
}

# component_stamp — write scripts/lib/.harness-version so doctor/govern-health
# can compare it against the installed hub's VERSION for the update-channel
# staleness warning. Called at the end of every scaffold run (fresh + bump).
component_stamp() {
  local v; v="$(hub_version)"
  mkdir -p scripts/lib
  {
    printf '%s\n' "$v"
    printf '# Written by scaffold.sh — the hub VERSION this workspace was last synced against.\n'
    printf '# Compare with $(hub-VERSION) via doctor.sh or govern-health.sh to see if a bump is due.\n'
  } > scripts/lib/.harness-version
  [ "$VERBOSE" -eq 1 ] && info "stamped scripts/lib/.harness-version = $v"
  return 0
}

# ── Verification ────────────────────────────────────────────────────────────

# verify_relocations — warn about files the hub moved (from-path → to-path) but
# the workspace still carries at the old path. Reads templates/lib/relocations.txt
# (from<space>to per non-comment line); each entry that still exists at the OLD
# path in the installed workspace becomes a warning. Non-fatal: relocated files
# rarely BREAK anything (govern's test loop only picks up test-*.sh files under
# the current path), but the old copy is a maintainability hazard.
verify_relocations() {
  local manifest="$T/lib/relocations.txt"
  [ -f "$manifest" ] || return 0
  log "verify: file relocations (workspace still carries files moved by the hub)"
  local from to count=0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"; line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
    [ -z "$line" ] && continue
    from="${line%% *}"; to="${line##* }"
    [ -n "$from" ] && [ -n "$to" ] || continue
    if [ -e "$from" ]; then
      warn "stale-relocated: $from → $to (delete $from; the hub moved it)"
      count=$((count+1))
    fi
  done < "$manifest"
  [ "$count" -eq 0 ] && info "no stale relocated files"
}

verify_scripts() {
  log "verify: bash -n over installed scripts"
  local fail=0 f
  while IFS= read -r f; do
    if ! bash -n "$f" 2>/tmp/scaffold_bashn.err; then
      warn "syntax error: $f"
      sed 's/^/         /' /tmp/scaffold_bashn.err >&2
      fail=1
    fi
  done < <(find scripts .githooks -name '*.sh' -o -name 'pre-push' -o -name 'prepare-commit-msg' 2>/dev/null)
  if [ "$fail" -ne 0 ]; then die "verification failed (see errors above)"; fi
  info "all scripts parse OK"

  log "verify: source scripts/lib/workspace.sh"
  if bash -c "source scripts/lib/workspace.sh && echo REPOS=\${REPOS[*]}" >/dev/null 2>&1; then
    info "workspace.sh sources cleanly"
  else
    die "workspace.sh failed to source"
  fi
}

verify_run_tests() {
  log "verify: govern test suite"
  local passed=0 failed=0 skipped=0 t name status
  local -a fails=()
  local total; total="$(find scripts/govern/test -name 'test-*.sh' -maxdepth 1 | wc -l | tr -d ' ')"
  info "running $total tests…"
  for t in scripts/govern/test/test-*.sh; do
    [ -x "$t" ] || chmod +x "$t"
    name="$(basename "$t" .sh)"
    if bash "$t" >/tmp/test-out.log 2>&1; then
      passed=$((passed+1))
    else
      status=$?
      if [ "$status" -eq 77 ] || grep -q 'SKIP' /tmp/test-out.log; then
        skipped=$((skipped+1))
      else
        failed=$((failed+1))
        fails+=("$name")
        [ "$VERBOSE" -eq 1 ] && { warn "FAIL $name"; sed 's/^/         /' /tmp/test-out.log >&2; }
      fi
    fi
  done
  info "tests: passed=$passed failed=$failed skipped=$skipped total=$total"
  if [ "$failed" -gt 0 ]; then
    for name in "${fails[@]}"; do warn "failed: $name"; done
    return 1
  fi
  return 0
}

# ── --diff-only mode ────────────────────────────────────────────────────────
# Report per-component whether the installed files match the current templates,
# without writing anything. Useful for a mid-bump adopter to see which
# components are already in sync (skip re-running them) and which are behind.
# Output: per component, prints "in-sync" (all installed files == template) or
# "behind (N file(s) drift)" with a short per-file list. Exit 0 if nothing is
# behind, exit 3 (drift) if anything is.
diff_only() {
  local behind=0
  probe_files() { # component -> lines "installed-path\ttemplate-path"
    case "$1" in
      core-scripts)
        for s in status doctor branch switch dev pull-all push-prs health sync tail investigate; do
          printf 'scripts/%s.sh\t%s/%s.sh\n' "$s" "$T" "$s"
        done
        for s in check-main-on-main ticket-sweep-reminder session-snapshot router-posture-reminder router-posture-guard; do
          printf 'scripts/%s.sh\t%s/hooks/%s.sh\n' "$s" "$T" "$s"
        done
        for s in session-state preflight githooks; do
          printf 'scripts/lib/%s.sh\t%s/lib/%s.sh\n' "$s" "$T" "$s"
        done ;;
      worktrees)
        for s in new rm status exec main session-end-cleanup; do
          printf 'scripts/worktree/%s.sh\t%s/worktree/%s.sh\n' "$s" "$T" "$s"
        done
        for s in registry base-ref; do
          printf 'scripts/worktree/lib/%s.sh\t%s/worktree/lib/%s.sh\n' "$s" "$T" "$s"
        done ;;
      govern)
        local f
        for f in "$T"/govern/*.sh; do
          [ -f "$f" ] || continue
          printf 'scripts/govern/%s\t%s\n' "$(basename "$f")" "$f"
        done
        printf 'scripts/govern/lib/common.sh\t%s/govern/lib/common.sh\n' "$T"
        for f in "$T"/govern/test/*.sh; do
          [ -f "$f" ] || continue
          printf 'scripts/govern/test/%s\t%s\n' "$(basename "$f")" "$f"
        done ;;
      githooks)
        for h in pre-push prepare-commit-msg pre-commit; do
          printf '.githooks/%s\t%s/githooks/%s\n' "$h" "$T" "$h"
        done ;;
      commands)
        local f
        for f in "$T"/.claude/commands/*.md; do
          [ -f "$f" ] || continue
          printf '.claude/commands/%s\t%s\n' "$(basename "$f")" "$f"
        done ;;
      *) : ;;
    esac
  }
  for c in core-scripts worktrees govern githooks commands; do
    local drift=0 details=""
    while IFS=$'\t' read -r installed template; do
      [ -n "$installed" ] || continue
      if [ ! -f "$installed" ] || ! diff -q "$installed" "$template" >/dev/null 2>&1; then
        drift=$((drift+1))
        details+="$installed "
      fi
    done < <(probe_files "$c")
    if [ "$drift" -eq 0 ]; then
      log "$c: in-sync"
    else
      log "$c: behind ($drift file(s) drift)"
      [ "$VERBOSE" -eq 1 ] && info "  $details"
      behind=1
    fi
  done
  local stamp="scripts/lib/.harness-version" workspace_v="unknown"
  if [ -f "$stamp" ]; then workspace_v="$(awk 'NF && $0 !~ /^#/ {print $1; exit}' "$stamp")"; fi
  local hub_v; hub_v="$(hub_version)"
  log "hub VERSION=$hub_v  workspace stamp=$workspace_v"
  if [ "$behind" -eq 1 ]; then exit 3; fi
  exit 0
}

if [ "$DIFF_ONLY" -eq 1 ]; then
  diff_only
fi

# ── Main dispatch ───────────────────────────────────────────────────────────

component_dirs

case "$COMPONENT" in
  all)
    component_workspace_sh
    component_core_scripts
    component_worktrees
    component_govern
    component_githooks
    component_project_commands
    component_seeds
    component_gitignore
    component_package_json
    component_settings
    ;;
  workspace-sh)   component_workspace_sh ;;
  core-scripts)   component_core_scripts ;;
  worktrees)      component_worktrees ;;
  govern)         component_govern ;;
  githooks)       component_githooks ;;
  commands)       component_project_commands ;;
  seeds)          component_seeds ;;
  gitignore)      component_gitignore ;;
  package-json)   component_package_json ;;
  settings)       component_settings ;;
  settings-merge) component_settings_merge ;;
  stamp)          : ;;    # component_stamp runs below unconditionally
  hooks)          # convenience: hooks-related bundle
    component_core_scripts
    component_settings
    ;;
  *) die "unknown component: $COMPONENT" ;;
esac

# Update-channel stamp — written on every scaffold invocation so doctor / govern-
# health can compare against the hub VERSION.
component_stamp

# ── Optional git init + initial commit ──────────────────────────────────────
if [ "$DO_GIT_INIT" -eq 1 ]; then
  if [ ! -d .git ]; then
    log "git init"
    git init -q
    git config core.hooksPath .githooks
    git add scripts .githooks governor package.json .gitignore .worktrees/.gitkeep \
            queue learnings.md CLAUDE.md .claude/settings.json .claude/commands 2>/dev/null || true
    git -c user.email=scaffold@meta-repo-harness -c user.name=scaffold \
        commit -q -m "chore: scaffold meta-repo workspace tooling (governor, worktrees, tickets, hooks)" || true
    info "initial commit created"
  else
    info "git already initialized — skipping init"
  fi
fi

# ── Verify (bash -n + optional test suite) ──────────────────────────────────
if [ "$DO_VERIFY" -eq 1 ]; then
  verify_scripts
  verify_relocations
  if [ "$RUN_TESTS" -eq 1 ]; then
    verify_run_tests || die "govern tests failed"
  fi
fi

log "scaffold: done (component=$COMPONENT workspace=$WORKSPACE_DIR)"
