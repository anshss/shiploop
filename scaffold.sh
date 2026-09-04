#!/usr/bin/env bash
# scaffold.sh — deterministic scaffolder for shiploop.
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
#             gitignore, package-json, settings, commands, agents, workflows, all
#   merge-tier (additive, idempotent, safe on an existing workspace — what /update runs):
#             settings-merge, package-json-merge, workspace-sh-merge, config-merge
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
PM_EXPLICIT=0          # --pm given? if not, hydrate_from_workspace_sh may override the default
ORG=""
REPOS_SPEC=""
MERGE_ALLOWLIST=""
WORKTREE_BASE=""
COMPONENT="all"
COMPONENT_EXPLICIT=0
DO_GIT_INIT=0
DO_VERIFY=0
YES=0
VERBOSE=0
DIFF_ONLY=0
SKIP_SUBREPO_HOOKS=0   # wrap.sh sets this: it must not mutate the moved sub-repo's
                       # .git/hooks before its byte-identical rollback point retires.

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
    --pm)                PM="$2"; PM_EXPLICIT=1; shift 2 ;;
    --org)               ORG="$2"; shift 2 ;;
    --repos)             REPOS_SPEC="$2"; shift 2 ;;
    --merge-allowlist)   MERGE_ALLOWLIST="$2"; shift 2 ;;
    --worktree-base)     WORKTREE_BASE="$2"; shift 2 ;;
    --templates)         TEMPLATES_DIR="$2"; shift 2 ;;
    --component)         COMPONENT="$2"; COMPONENT_EXPLICIT=1; shift 2 ;;
    --git-init)          DO_GIT_INIT=1; shift ;;
    --verify)            DO_VERIFY=1; shift ;;
    --yes|-y)            YES=1; shift ;;
    --verbose|-v)        VERBOSE=1; shift ;;
    --diff-only)         DIFF_ONLY=1; shift ;;
    --skip-subrepo-hooks) SKIP_SUBREPO_HOOKS=1; shift ;;
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

# ── Read-only mode detection ────────────────────────────────────────────────
# --verify or --diff-only, standalone (no fresh-scaffold flags), against an
# already-scaffolded workspace: skip the writer phase entirely and only run
# the verification checks. Fresh-scaffold flags = --org, --repos, or an
# explicit --component (any of these means "you're writing something").
VERIFY_ONLY=0
if { [ "$DO_VERIFY" -eq 1 ] || [ "$DIFF_ONLY" -eq 1 ]; } \
   && [ -z "$ORG" ] && [ -z "$REPOS_SPEC" ] && [ "$COMPONENT_EXPLICIT" -eq 0 ]; then
  VERIFY_ONLY=1
fi

# ── Validate workspace ──────────────────────────────────────────────────────
# In read-only mode, default WORKSPACE_DIR to the current dir so an operator
# can just run `scaffold.sh --verify` from inside their scaffolded workspace.
if [ -z "$WORKSPACE_DIR" ]; then
  if [ "$VERIFY_ONLY" -eq 1 ]; then
    WORKSPACE_DIR="$(pwd)"
  else
    die "--workspace-dir is required"
  fi
fi
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

# ── Hydrate repo/PM facts from an existing workspace.sh ─────────────────────
# The config components (readme, gitignore, package-json-merge) need REPO_NAMES +
# PM to render accurate content. A fresh scaffold passes --repos/--pm; /shiploop:update
# passes NEITHER, because the operator's answers already live in scripts/lib/workspace.sh.
# Without this, an update-driven README/gitignore would render the default PM ("npm") and
# a generic repo list — the exact defect ticket #4 records. Read the real values instead.
#
# Sourced in a SUBSHELL so workspace.sh's exports (GOVERN_*, set -u interactions) can
# never leak into the scaffolder's own environment; only the printed fields come back.
hydrate_from_workspace_sh() {
  [ "${#REPO_NAMES[@]}" -eq 0 ] || return 0        # explicit --repos always wins
  [ -f scripts/lib/workspace.sh ] || return 0
  local hydrated
  hydrated="$(
    # shellcheck disable=SC1091
    . scripts/lib/workspace.sh >/dev/null 2>&1 || exit 0
    printf 'PM\t%s\n' "${ROOT_PM:-}"
    # `${REPOS[@]+...}` keeps this safe under `set -u` when workspace.sh is a stub
    # that never defines the array (a half-scaffolded or hand-trimmed workspace).
    for j in ${REPOS[@]+"${!REPOS[@]}"}; do
      printf 'REPO\t%s\t%s\t%s\n' "${REPOS[$j]}" "${REPO_PORTS[$j]:-}" "${REPO_CMDS[$j]:-}"
    done
  )" || return 0
  local kind a b c
  while IFS=$'\t' read -r kind a b c; do
    case "$kind" in
      # Reject un-substituted placeholders. A workspace.sh copied straight from the
      # template (a half-finished scaffold, or someone restoring the raw template) still
      # reads REPOS=(__REPOS__), and taking that literally minted a bogus `dev:__REPOS__`
      # npm script. Treat any __X__ value as "no answer recorded" and skip it.
      PM)   case "$a" in ''|*__*__*) ;; *) [ "$PM_EXPLICIT" -eq 0 ] && PM="$a" ;; esac ;;
      REPO) case "$a" in ''|*__*__*) ;; *) REPO_NAMES+=("$a"); REPO_PORTS+=("$b"); REPO_CMDS+=("$c") ;; esac ;;
    esac
  done <<<"$hydrated"
  [ "${#REPO_NAMES[@]}" -gt 0 ] && [ "$VERBOSE" -eq 1 ] && \
    info "hydrated ${#REPO_NAMES[@]} repo(s) + pm=$PM from scripts/lib/workspace.sh"
  return 0
}

# ── Component implementations ───────────────────────────────────────────────

component_dirs() {
  mkdir -p scripts/lib scripts/worktree/lib scripts/govern/lib
  mkdir -p governor .worktrees .claude/commands .claude/workflows .claude/skills .claude/agents .githooks queue
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

}

component_core_scripts() {
  log "component: core scripts"
  local s
  for s in doctor dev sync tail; do
    cp "$T/$s.sh" "scripts/$s.sh"
    chmod +x "scripts/$s.sh"
  done
  # hooks that live in scripts/
  cp "$T/hooks/check-main-on-main.sh" scripts/
  cp "$T/hooks/ticket-sweep-reminder.sh" scripts/
  cp "$T/hooks/session-snapshot.sh" scripts/
  cp "$T/hooks/router-posture-reminder.sh" scripts/
  cp "$T/hooks/router-posture-guard.sh" scripts/
  cp "$T/hooks/validations-pending-hook.sh" scripts/
  cp "$T/hooks/learnings-digest.sh" scripts/
  chmod +x scripts/*.sh
  # sourced libs (no +x needed but harmless)
  cp "$T/lib/session-state.sh" scripts/lib/
  cp "$T/lib/preflight.sh" scripts/lib/
  cp "$T/lib/githooks.sh" scripts/lib/
  cp "$T/lib/install-semaphore.sh" scripts/lib/
  info "installed core scripts + hooks + libs"
}

component_worktrees() {
  log "component: worktrees"
  cp "$T/worktree/new.sh" "$T/worktree/rm.sh" "$T/worktree/reap.sh" "$T/worktree/status.sh" \
     "$T/worktree/exec.sh" "$T/worktree/main.sh" "$T/worktree/session-end-cleanup.sh" \
     scripts/worktree/
  cp "$T/worktree/lib/registry.sh" "$T/worktree/lib/base-ref.sh" scripts/worktree/lib/
  chmod +x scripts/worktree/*.sh
  info "installed worktree scripts"
}

component_govern() {
  log "component: govern"
  cp "$T"/govern/*.sh scripts/govern/           # incl. run-validation.sh (durable validation runner)
  cp "$T"/govern/lib/*.sh scripts/govern/lib/   # common.sh + flows.sh + valjob.sh (job substrate)
  # Node helpers under govern/lib (the request-capture proxy + its reporter). Guarded: the glob is
  # only copied when it actually matches, so an older template tree without them still scaffolds.
  if compgen -G "$T/govern/lib/*.mjs" >/dev/null 2>&1; then
    cp "$T"/govern/lib/*.mjs scripts/govern/lib/
  fi
  # NOTE: govern/test/ is deliberately NOT installed. The suite is hub-only — nothing in a
  # fleet workspace executes it (sync-port.sh builds its own scratch copy from the hub tree,
  # and hub CI scaffolds a throwaway workspace and copies the suite in itself).
  chmod +x scripts/govern/*.sh
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
  info "installed govern scripts + governor prompts"
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
  log "component: project-local slash commands"
  cp "$T"/.claude/commands/*.md .claude/commands/ 2>/dev/null || true
  info "installed .claude/commands/"
}

# component_agents — shipped subagent definitions (lookup, investigator). These give the
# interactive driver lane cheap-tier targets for the delegation posture (router-posture
# hooks + CLAUDE.md) that already tells it to delegate: without them "delegate to an
# Agent" had no pre-sized, cheap-model destination, so haiku delegation stayed near zero
# in practice. Mirrors component_project_commands: copy-only, no substitution.
component_agents() {
  log "component: shipped subagent definitions (.claude/agents/)"
  mkdir -p .claude/agents
  cp "$T"/.claude/agents/*.md .claude/agents/ 2>/dev/null || true
  info "installed .claude/agents/"
}

# Workspace-shadowing workflows + skill. The tiered `deep-research.js` file ships with
# `meta.name: 'deep-research-tiered'` so it does NOT collide with the built-in `deep-research`
# by name (an in-session probe on 2026-07-05 confirmed a workspace copy with the same name did
# NOT shadow the built-in — the fallback is the safe route regardless of fresh-session
# precedence). The paired `.claude/skills/deep-research-tiered/SKILL.md` carries the built-in
# deep-research skill's trigger language plus a preference note so the router picks the
# workspace override in this workspace.
component_workflows() {
  log "component: workflows + skill (model-tiered .claude/workflows/ + .claude/skills/deep-research-tiered/)"
  if [ -d "$T/workflows" ]; then
    cp "$T"/workflows/*.js .claude/workflows/ 2>/dev/null || true
    info "installed .claude/workflows/"
  else
    info "no workflow templates present — skipping"
  fi
  if [ -d "$T/skills" ]; then
    local skdir
    for skdir in "$T"/skills/*/; do
      [ -d "$skdir" ] || continue
      local skname; skname="$(basename "$skdir")"
      mkdir -p ".claude/skills/$skname"
      cp "$skdir"/SKILL.md ".claude/skills/$skname/SKILL.md" 2>/dev/null || true
    done
    info "installed .claude/skills/"
  fi
}

# seed_pristine — is $1 (an installed seed file) byte-identical to SOME version of
# seed $2 that shiploop has shipped? Consults templates/lib/seed-hashes.txt.
#
# A hit proves the operator never edited the file, which is the ONLY condition under
# which replacing it with the current seed is lossless. A miss (including "no manifest
# available") means "assume customized" and is always safe — worst case the workspace
# keeps a seed one version behind, which is exactly today's behavior.
seed_pristine() {
  local file="$1" name="$2"
  local manifest="$T/lib/seed-hashes.txt"
  [ -f "$file" ] || return 1
  [ -f "$manifest" ] || return 1
  local h
  h="$(shasum -a 256 "$file" 2>/dev/null | cut -d' ' -f1)" || return 1
  [ -n "$h" ] || return 1
  grep -Fq "$h  $name" "$manifest"
}

# seed_install — fill if absent; losslessly upgrade if provably unedited; else leave alone.
seed_install() {
  local template="$1" dest="$2" name="$3"
  [ -f "$template" ] || return 0
  if [ ! -f "$dest" ]; then
    cp "$template" "$dest"
    return 0
  fi
  diff -q "$dest" "$template" >/dev/null 2>&1 && return 0     # already current
  if seed_pristine "$dest" "$name"; then
    cp "$template" "$dest"
    info "upgraded $dest (was an unedited shipped seed — no local content to lose)"
  else
    [ "$VERBOSE" -eq 1 ] && info "$dest differs from the current seed but carries local edits — left untouched"
  fi
  return 0
}

component_seeds() {
  log "component: seeds (fill if absent; upgrade only when provably unedited)"
  seed_install "$T/seed/tickets.md"        queue/tickets.md        tickets.md
  seed_install "$T/seed/tickets-parked.md" queue/tickets-parked.md tickets-parked.md
  seed_install "$T/seed/learnings.md"      learnings.md            learnings.md
  seed_install "$T/seed/CLAUDE.md"         CLAUDE.md               CLAUDE.md
  # The on-demand half of the CLAUDE.md split. CLAUDE.md is re-sent every turn; this is not, so it is
  # where reference tables and rule rationale live. Seeded even on an existing fleet whose CLAUDE.md
  # predates the split — an absent appendix is what makes operators keep growing the always-on file.
  seed_install "$T/seed/CLAUDE-APPENDIX.md" CLAUDE-APPENDIX.md     CLAUDE-APPENDIX.md
  # Flow registry (validations feature): .claude/shiploop/validation/flows.md + the evidence sink dir. Never overwrite.
  if [ ! -f .claude/shiploop/validation/flows.md ] && [ -f "$T/seed/.claude/shiploop/validation/flows.md" ]; then
    mkdir -p .claude/shiploop/validation/evidence/assets
    cp "$T/seed/.claude/shiploop/validation/flows.md" .claude/shiploop/validation/flows.md
  fi
  info "seeds present"
}

component_readme() {
  log "component: README.md (workspace landing page)"

  # /shiploop:update passes neither --pm nor --repos, so without this the README would
  # render the default PM and "the repos under this workspace" instead of the real list
  # (ticket #4, defect (1)). Read the operator's actual answers out of workspace.sh.
  hydrate_from_workspace_sh

  # Never clobber an existing README — the workspace root's README is operator-owned
  # documentation once written. On a fresh scaffold the root has none (a wrapped repo's
  # own README moved into its subfolder), so this only ever writes on first setup.
  if [ -f README.md ]; then
    info "README.md already present — leaving as-is"
    return 0
  fi

  local meta_name; meta_name="$(basename "$WORKSPACE_DIR")"

  # Human-readable sub-repo list for the landing page (falls back gracefully if
  # invoked as a standalone --component readme with no --repos).
  local repos_list=""
  if [ "${#REPO_NAMES[@]}" -gt 0 ]; then
    local i
    for i in "${!REPO_NAMES[@]}"; do
      repos_list+="\`${REPO_NAMES[$i]}\`, "
    done
    repos_list="${repos_list%, }"
  else
    repos_list="the repos under this workspace"
  fi

  local content
  content=$(cat <<EOF
# $meta_name on Shiploop

**$meta_name** ships on [Shiploop](https://github.com/anshss/shiploop) — a self-improving
multi-agent harness that dispatches the tickets you name across every repo in this workspace
($repos_list). A fresh headless agent takes each ticket at a cheap model floor, opens a PR, auto-merges
on green CI where you've allowed it, and writes a durable lesson back into \`CLAUDE.md\` so the
next run is smarter and cheaper.

## Ship the tickets you name

\`\`\`text
Just say what you want worked, in plain language:

  "work on 42"                         one ticket, sequential and unbatched
  "work on 42 51 63"                   that exact set, grouped by file locality
  "work on 42 51 63 while I'm out"     the same set, unattended and fanned out
\`\`\`

That maps onto \`scripts/govern/run-loop.sh\` — the loop, worktrees, claim locks and reaping are
unchanged, so a later session can reap workers an earlier one launched.

Everyday commands:

\`\`\`bash
$PM run doctor            # health-check the workspace
$PM run dev               # boot every sub-repo's dev server
/shiploop:flows           # inventory + validate your product's user-facing paths
\`\`\`

Backlog lives in \`queue/tickets.md\`; per-workspace config in \`scripts/lib/workspace.sh\`.
Full docs: the \`shiploop\` skill and <https://github.com/anshss/shiploop>.
EOF
)
  printf '%s\n' "$content" > README.md
  info "wrote README.md"
}

component_gitignore() {
  log "component: .gitignore"
  # Same reason as component_readme: an update-driven run knows the repos + PM only
  # through workspace.sh. Without hydration the merge would append the wrong lockfile
  # ignores and no sub-repo lines at all.
  hydrate_from_workspace_sh
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
    # Collect the genuinely-missing lines FIRST. The previous version appended a
    # "scaffolded additions" banner on every run whether or not anything followed it,
    # so each /shiploop:update grew the file by one dead header and reported a change —
    # which made the whole component read as non-idempotent.
    local missing=""
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      case "$line" in \#*) continue ;; esac        # never re-append template comments
      grep -Fxq "$line" .gitignore 2>/dev/null || missing+="$line"$'\n'
    done <<<"$content"

    if [ -z "$missing" ]; then
      info ".gitignore already covers every scaffolded pattern — no changes (idempotent)"
    else
      local tmp; tmp="$(mktemp)"
      {
        cat .gitignore
        printf '\n# — shiploop scaffolded additions (v%s) —\n' "$(hub_version)"
        printf '%s' "$missing"
      } > "$tmp"
      mv "$tmp" .gitignore
      info "appended $(printf '%s' "$missing" | grep -c '') missing .gitignore line(s)"
    fi
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
    "doctor": "bash scripts/doctor.sh",
    "sync": "bash scripts/sync.sh",
    "tail": "bash scripts/tail.sh",
    "worktree": "bash scripts/worktree/main.sh",
    "worktree:new": "bash scripts/worktree/new.sh",
    "worktree:rm": "bash scripts/worktree/rm.sh",
    "worktree:reap": "bash scripts/worktree/reap.sh",
    "worktree:status": "bash scripts/worktree/status.sh",
    "worktree:exec": "bash scripts/worktree/exec.sh",
    "govern": "bash scripts/govern/run-loop.sh",
    "govern:health": "bash scripts/govern/govern-health.sh",
    "govern:dry-run": "bash scripts/govern/dry-run.sh",
    "govern:status": "bash scripts/govern/status.sh",
    "govern:audit": "bash scripts/govern/govern-supervise.sh",
    "govern:budgets": "bash scripts/govern/govern-bookkeep.sh --enforce-budgets",
    "govern:trim": "bash scripts/govern/claudemd-trim.sh",
    "govern:externalize": "bash scripts/govern/externalize-low-tickets.sh",
    "govern:validations": "bash scripts/govern/govern-validations.sh",
    "vf": "bash scripts/govern/verify-filter.sh"
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

# component_package_json_merge — add the harness's npm-script entrypoints that are
# MISSING from an existing package.json, touching nothing else.
#
# component_package_json is all-or-nothing (rewrites the file, refuses without --yes),
# so /shiploop:update has always skipped it — and a hub release that adds a new script
# (govern:validations in v1.9, govern:dry-run, govern:health) could never reach an
# already-installed fleet. Measured on 5 local workspaces: every one was missing at
# least one, and a full successful /update left them missing.
#
# Rules: never overwrite a key the operator already defines (theirs may point at a
# wrapper), never remove keys, never reorder. Only absent keys are added.
component_package_json_merge() {
  log "component: package-json-merge (add missing harness scripts to existing package.json)"
  command -v jq >/dev/null 2>&1 || { warn "package-json-merge needs jq — skipping"; return 0; }
  if [ ! -f package.json ]; then
    warn "package.json absent — nothing to merge into; run --component package-json to create it"
    return 0
  fi
  hydrate_from_workspace_sh

  # Desired script set — must stay in step with component_package_json above.
  local desired
  desired=$(jq -n '{
    "dev":                "bash scripts/dev.sh",
    "doctor":             "bash scripts/doctor.sh",
    "sync":               "bash scripts/sync.sh",
    "tail":               "bash scripts/tail.sh",
    "worktree":           "bash scripts/worktree/main.sh",
    "worktree:new":       "bash scripts/worktree/new.sh",
    "worktree:rm":        "bash scripts/worktree/rm.sh",
    "worktree:reap":      "bash scripts/worktree/reap.sh",
    "worktree:status":    "bash scripts/worktree/status.sh",
    "worktree:exec":      "bash scripts/worktree/exec.sh",
    "govern":             "bash scripts/govern/run-loop.sh",
    "govern:health":      "bash scripts/govern/govern-health.sh",
    "govern:dry-run":     "bash scripts/govern/dry-run.sh",
    "govern:status":      "bash scripts/govern/status.sh",
    "govern:audit":       "bash scripts/govern/govern-supervise.sh",
    "govern:budgets":     "bash scripts/govern/govern-bookkeep.sh --enforce-budgets",
    "govern:trim":        "bash scripts/govern/claudemd-trim.sh",
    "govern:externalize": "bash scripts/govern/externalize-low-tickets.sh",
    "govern:validations": "bash scripts/govern/govern-validations.sh",
    "vf":                 "bash scripts/govern/verify-filter.sh"
  }') || { warn "package-json-merge: jq failed to build the script set"; return 0; }

  # Per-repo dev:<name> entries, from --repos or hydrated workspace.sh.
  local r
  for r in ${REPO_NAMES[@]+"${REPO_NAMES[@]}"}; do
    [ -n "$r" ] || continue
    desired=$(printf '%s' "$desired" | jq --arg k "dev:$r" --arg v "bash scripts/dev.sh --only $r" '. + {($k): $v}')
  done

  # Which harness keys are absent? Computed against the CURRENT file, before any write.
  # `|| true` is load-bearing: a jq failure here must not abort the component under
  # `set -e` (an assignment takes the command substitution's exit status).
  local added
  added="$(jq -r --argjson want "$desired" \
    '(.scripts // {}) as $have
     | [$want | keys[]] | map(. as $k | select($have | has($k) | not)) | join(", ")' \
    package.json 2>/dev/null)" || true

  local tmp; tmp="$(mktemp)"
  # Append ONLY the absent keys, after the operator's existing ones. Preserving their
  # order is what makes this idempotent — `$want + $have` would rewrite the file on
  # every run just to reshuffle keys, and each run would look like a real change.
  if jq --argjson want "$desired" '
        (.scripts // {}) as $have
        | .scripts = ($have + ($want | with_entries(. as $e | select($have | has($e.key) | not))))
      ' package.json > "$tmp" 2>/dev/null; then
    if diff -q package.json "$tmp" >/dev/null 2>&1; then
      rm -f "$tmp"
      info "package.json already carries every harness script — no changes (idempotent)"
    else
      mv "$tmp" package.json
      info "added missing script(s): ${added:-<none named>}"
    fi
  else
    rm -f "$tmp"
    warn "package.json is not valid JSON — skipping merge (fix it, then re-run /shiploop:update)"
  fi
  return 0
}

# component_workspace_sh_merge — append knobs the hub has ADDED since this workspace
# was scaffolded, without touching a single existing line.
#
# workspace.sh is the one file /update must never regenerate (it holds the operator's
# answers). But that also meant a new GOVERN_* knob shipped in the hub seed reached
# only NEW fleets — ticket #44's finding: GOVERN_PARALLEL_DEFAULT landed in v1.11.0 and
# every upgrading workspace silently kept running serial. Appending only absent knob
# names is safe: the operator's values, ordering, and comments are all preserved.
component_workspace_sh_merge() {
  log "component: workspace-sh-merge (append knobs new since this workspace was scaffolded)"
  local target="scripts/lib/workspace.sh"
  if [ ! -f "$target" ]; then
    warn "$target absent — not a scaffolded workspace; skipping"
    return 0
  fi
  # Identity fields are per-workspace and are NEVER appended — they are answers, not knobs.
  local identity=" META_NAME ROOT_PM GITHUB_ORG REPOS REPO_CMDS REPO_PORTS WORKTREE_BASE SLOT_PORT_STEP "
  local added="" line var
  local pending=""            # comment lines immediately above a knob travel with it
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      \#*)  pending+="$line"$'\n'; continue ;;
      "")   pending=""; continue ;;
    esac
    var="$(printf '%s' "$line" | sed -nE 's/^(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=.*/\2/p')"
    if [ -z "$var" ]; then pending=""; continue; fi
    # Skip identity fields and any line still carrying an install-time placeholder.
    case "$identity" in *" $var "*) pending=""; continue ;; esac
    case "$line" in *__*__*) pending=""; continue ;; esac
    if grep -qE "^[[:space:]]*(export[[:space:]]+)?$var=" "$target"; then
      pending=""; continue
    fi
    if [ -z "$added" ]; then
      printf '\n# ── knobs added by shiploop v%s (appended by /shiploop:update; edit freely) ──\n' \
        "$(hub_version)" >> "$target"
    fi
    [ -n "$pending" ] && printf '%s' "$pending" >> "$target"
    printf '%s\n' "$line" >> "$target"
    added+="$var "
    pending=""
  done < "$T/lib/workspace.sh"

  if [ -n "$added" ]; then
    info "appended new knob(s): $added"
    info "  defaults are conservative — review and tune in $target"
  else
    info "$target already carries every hub knob — no changes (idempotent)"
  fi
  return 0
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
      { "type": "command", "command": "bash $root/scripts/learnings-digest.sh 2>/dev/null || true", "timeout": 10 },
      { "type": "command", "command": "bash $root/scripts/check-main-on-main.sh 2>/dev/null || true", "timeout": 10 },
      { "type": "command", "command": "bash $root/scripts/validations-pending-hook.sh 2>/dev/null || true", "timeout": 15 }
    ]}],
    "UserPromptSubmit": [{ "matcher": "*", "hooks": [
      { "type": "command", "command": "bash $root/scripts/router-posture-reminder.sh 2>/dev/null || true", "timeout": 10 }
    ]}],
    "PreToolUse": [{ "matcher": "Read|Bash|Agent", "hooks": [
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
  # Individual harness hook commands — same commands as component_settings, but each carries its OWN
  # script marker and is checked + appended INDIVIDUALLY per event. The old design tested ONE marker
  # alternation for the whole event and skipped the ENTIRE event if ANY marker matched — so a NEWLY
  # introduced hook (e.g. validations-pending-hook.sh added after an install already had
  # session-snapshot.sh) never got appended to an existing settings.json. Per-hook checking fixes that:
  # a hook lands iff its own marker is absent, and re-running is idempotent (all markers then present).
  local ss_snap ss_learn ss_main ss_val up_reminder pt_guard stop_hook se_cleanup
  ss_snap=$(cat <<EOF
{ "type": "command", "command": "bash $root/scripts/session-snapshot.sh 2>/dev/null || true", "timeout": 15 }
EOF
)
  ss_learn=$(cat <<EOF
{ "type": "command", "command": "bash $root/scripts/learnings-digest.sh 2>/dev/null || true", "timeout": 10 }
EOF
)
  ss_main=$(cat <<EOF
{ "type": "command", "command": "bash $root/scripts/check-main-on-main.sh 2>/dev/null || true", "timeout": 10 }
EOF
)
  ss_val=$(cat <<EOF
{ "type": "command", "command": "bash $root/scripts/validations-pending-hook.sh 2>/dev/null || true", "timeout": 15 }
EOF
)
  up_reminder=$(cat <<EOF
{ "type": "command", "command": "bash $root/scripts/router-posture-reminder.sh 2>/dev/null || true", "timeout": 10 }
EOF
)
  pt_guard=$(cat <<EOF
{ "type": "command", "command": "bash $root/scripts/router-posture-guard.sh 2>/dev/null || true", "timeout": 10 }
EOF
)
  stop_hook=$(cat <<EOF
{ "type": "command", "command": "bash $root/scripts/ticket-sweep-reminder.sh", "timeout": 15 }
EOF
)
  se_cleanup=$(cat <<EOF
{ "type": "command", "command": "bash $root/scripts/worktree/session-end-cleanup.sh 2>/dev/null || true", "timeout": 90 }
EOF
)
  # Spec: per event, the matcher + the desired hooks each keyed by its own script marker. wire appends
  # ONLY the hooks whose marker is absent from that event's existing commands (grouped under the
  # matcher), so a fresh install gets one full stanza per event while an existing install gains only
  # the newly-missing hooks.
  local spec
  spec=$(jq -n \
    --argjson ss_snap "$ss_snap" --argjson ss_learn "$ss_learn" \
    --argjson ss_main "$ss_main" --argjson ss_val "$ss_val" \
    --argjson up "$up_reminder" --argjson pt "$pt_guard" \
    --argjson sp "$stop_hook" --argjson se "$se_cleanup" \
    '[
      {event:"SessionStart", matcher:"*", items:[
        {marker:"session-snapshot\\.sh",         hook:$ss_snap},
        {marker:"learnings-digest\\.sh",         hook:$ss_learn},
        {marker:"check-main-on-main\\.sh",       hook:$ss_main},
        {marker:"validations-pending-hook\\.sh", hook:$ss_val}
      ]},
      {event:"UserPromptSubmit", matcher:"*",         items:[{marker:"router-posture-reminder\\.sh", hook:$up}]},
      {event:"PreToolUse",       matcher:"Read|Bash|Agent", items:[{marker:"router-posture-guard\\.sh",    hook:$pt}]},
      {event:"Stop",             matcher:"*",         items:[{marker:"ticket-sweep-reminder\\.sh",   hook:$sp}]},
      {event:"SessionEnd",       matcher:"*",         items:[{marker:"session-end-cleanup\\.sh",     hook:$se}]}
    ]') || die "settings-merge: failed to build hook spec (jq error)"
  local jq_prog
  jq_prog=$(cat <<'JQ'
def event_cmds($ev): [ (.hooks[$ev] // [])[]?.hooks[]?.command ] | join("\n");
# MIGRATION (in place, not append): the SessionStart learnings slot used to be an inline
# `head -30 learnings.md`, which injected the file's format preamble instead of its entries and
# emitted 18 lines of "this file is empty" on a fresh fleet. Rewrite it to the digest script rather
# than appending alongside it — appending would double the output, and the marker check below would
# never fire on an existing fleet because the legacy command carries no `learnings-digest.sh`.
( if .hooks.SessionStart then
    .hooks.SessionStart |= map(
      if .hooks then
        .hooks |= map(
          if ((.command? // "") | test("head +-n? *[0-9]+ +[^ ]*learnings\\.md"))
          then (.command = $newlearn | .timeout = 10)
          else . end)
      else . end)
  else . end )
# MIGRATION (in place, not append): the PreToolUse matcher gained `Agent` when the
# router-posture guard grew its ticket-route deny. Marker-presence alone would call the
# existing stanza "already installed" and leave it matching only Read|Bash forever, so the
# guard would never see an Agent call on any workspace scaffolded before that. Widen the
# matcher on the entry that actually carries our guard; leave every other entry alone.
| ( if .hooks.PreToolUse then
      .hooks.PreToolUse |= map(
        if ((.matcher? // "") == "Read|Bash")
           and ([ (.hooks // [])[]?.command ] | join("\n") | test("router-posture-guard\\.sh"))
        then .matcher = "Read|Bash|Agent"
        else . end)
    else . end )
# REPAIR (in place): a hook already wired under this event but whose command string no
# longer matches what the hub ships — the workspace path moved, a redirect/flag changed,
# or the timeout was retuned. Marker-presence alone would call that "already installed"
# and leave the stale invocation running forever, so match on the marker and rewrite the
# command + timeout to the canonical pair. Only harness-owned hooks (ones whose command
# references OUR script path under the workspace root) are ever touched.
| reduce $spec[] as $e (
  .;
  reduce $e.items[] as $it (
    .;
    if (.hooks[$e.event] // null) == null then .
    else .hooks[$e.event] |= map(
      if .hooks then
        .hooks |= map(
          if (((.command? // "") | test($it.marker))
              and ((.command? // "") != ($it.hook.command))
              and ((.command? // "") | contains($root)))
          then (.command = $it.hook.command | .timeout = $it.hook.timeout)
          else . end)
      else . end)
    end
  )
)
| reduce $spec[] as $e (
  (if .hooks == null then .hooks = {} else . end);
  event_cmds($e.event) as $have
  | ($e.items | map(. as $it | select(($have | test($it.marker)) | not) | $it.hook)) as $missing
  | if ($missing | length) == 0 then .
    else .hooks[$e.event] = ((.hooks[$e.event] // []) + [ {matcher: $e.matcher, hooks: $missing} ])
    end
)
JQ
)
  local tmp; tmp="$(mktemp)"
  local newlearn; newlearn="$(printf '%s' "$ss_learn" | jq -r '.command')"
  if jq --argjson spec "$spec" --arg newlearn "$newlearn" --arg root "$root/scripts/" \
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

# The mechanism components whose installed files are byte-comparable against
# templates. Shared by --diff-only AND the stamp gate so the two can never drift
# apart (N5: a component tracked by one but not the other loops "behind" forever).
MECH_COMPONENTS="core-scripts worktrees govern githooks commands agents workflows"

# probe_files — component -> lines "installed-path<TAB>template-path".
# Top-level so both diff_only and workspace_converged share one source of truth.
probe_files() {
  case "$1" in
    core-scripts)
      for s in doctor dev sync tail; do
        printf 'scripts/%s.sh\t%s/%s.sh\n' "$s" "$T" "$s"
      done
      for s in check-main-on-main ticket-sweep-reminder session-snapshot router-posture-reminder router-posture-guard validations-pending-hook learnings-digest; do
        printf 'scripts/%s.sh\t%s/hooks/%s.sh\n' "$s" "$T" "$s"
      done
      for s in session-state preflight githooks install-semaphore; do
        printf 'scripts/lib/%s.sh\t%s/lib/%s.sh\n' "$s" "$T" "$s"
      done ;;
    worktrees)
      for s in new rm reap status exec main session-end-cleanup; do
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
      for f in "$T"/govern/lib/*.sh; do
        [ -f "$f" ] || continue
        printf 'scripts/govern/lib/%s\t%s\n' "$(basename "$f")" "$f"
      done
      ;;
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
    agents)
      local f
      for f in "$T"/.claude/agents/*.md; do
        [ -f "$f" ] || continue
        printf '.claude/agents/%s\t%s\n' "$(basename "$f")" "$f"
      done ;;
    workflows)
      local f skdir
      for f in "$T"/workflows/*.js; do
        [ -f "$f" ] || continue
        printf '.claude/workflows/%s\t%s\n' "$(basename "$f")" "$f"
      done
      for skdir in "$T"/skills/*/; do
        [ -d "$skdir" ] || continue
        local skname; skname="$(basename "$skdir")"
        [ -f "$skdir/SKILL.md" ] && \
          printf '.claude/skills/%s/SKILL.md\t%s/SKILL.md\n' "$skname" "$skdir"
      done ;;
    *) : ;;
  esac
}

# workspace_converged — return 0 iff every mechanism component's installed files
# match the current templates byte-for-byte (i.e. --diff-only would exit 0).
# Read-only; no logging. Used to gate the version stamp.
workspace_converged() {
  local c installed template
  for c in $MECH_COMPONENTS; do
    while IFS=$'\t' read -r installed template; do
      [ -n "$installed" ] || continue
      if [ ! -f "$installed" ] || ! diff -q "$installed" "$template" >/dev/null 2>&1; then
        return 1
      fi
    done < <(probe_files "$c")
  done
  return 0
}

# component_stamp — write scripts/lib/.harness-version so doctor/govern-health
# can compare it against the installed hub's VERSION for the update-channel
# staleness warning. Called at the end of every scaffold run (fresh + bump).
#
# N7: only stamp when the workspace is FULLY converged against the templates. A
# partial --component run that leaves another mechanism component behind must NOT
# advance the stamp — otherwise doctor/govern-health (which compare stamp==VERSION)
# false-report "up to date" while a component is still stale. A full --component all
# run, a fresh scaffold, or the converging final bump of an /update loop all leave
# zero drift and DO stamp.
component_stamp() {
  if ! workspace_converged; then
    [ "$VERBOSE" -eq 1 ] && info "not stamping .harness-version — mechanism drift remains (partial/non-converged run)"
    return 0
  fi
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

# ── Purge (retired files an older shiploop installed) ───────────────────────

# purge_removed — delete paths the hub used to ship and no longer does. Reads
# templates/lib/purge.txt (one workspace-relative path per non-comment line; a
# trailing `/` means "directory, remove recursively"). This is what lets an
# ALREADY-installed fleet shed a retired file: scaffold's components only copy
# IN, they never remove, so without this a purged template lives forever in
# every workspace that ever installed it.
#
# Two modes: "apply" (writer runs) removes; "warn" (standalone --verify, which
# must not write) only reports. Paths are relative to the workspace root, and
# every one is guarded against absolute/parent-escaping forms so a malformed
# manifest line can never reach outside the workspace.
purge_removed() {
  local mode="${1:-apply}"
  local manifest="$T/lib/purge.txt"
  [ -f "$manifest" ] || return 0
  local line count=0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"; line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
    [ -z "$line" ] && continue
    case "$line" in /*|*..*) warn "purge: ignoring unsafe manifest path: $line"; continue ;; esac
    [ -e "$line" ] || continue
    if [ "$count" -eq 0 ]; then log "purge: removing files retired by the hub"; fi
    count=$((count+1))
    if [ "$mode" = "warn" ]; then
      warn "retired-but-present: $line (a writer run — scaffold/update — removes it)"
    else
      rm -rf -- "$line"
      info "removed $line"
    fi
  done < "$manifest"
  if [ "$count" -gt 0 ] && [ "$mode" != "warn" ]; then
    info "purged $count retired path(s)"
  fi
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
  done < <(find scripts .githooks -name '*.sh' -o -name 'pre-push' -o -name 'prepare-commit-msg' -o -name 'pre-commit' 2>/dev/null)
  if [ "$fail" -ne 0 ]; then die "verification failed (see errors above)"; fi
  info "all scripts parse OK"

  log "verify: source scripts/lib/workspace.sh"
  if bash -c "source scripts/lib/workspace.sh && echo REPOS=\${REPOS[*]}" >/dev/null 2>&1; then
    info "workspace.sh sources cleanly"
  else
    die "workspace.sh failed to source"
  fi
}

# ── --diff-only mode ────────────────────────────────────────────────────────
# Report per-component whether the installed files match the current templates,
# without writing anything. Useful for a mid-bump adopter to see which
# components are already in sync (skip re-running them) and which are behind.
# Output: per component, prints "in-sync" (all installed files == template) or
# "behind (N file(s) drift)" with a short per-file list. Exit 0 if nothing is
# behind, exit 3 (drift) if anything is.
# config_drift_report — read-only report on the components that are NOT byte-comparable
# (config + seeds). Deliberately does NOT set the exit-3 drift flag and does NOT gate the
# version stamp: a customized CLAUDE.md or an operator-added npm script is a permanent,
# CORRECT difference, and folding it into the converge signal would leave every real
# workspace reporting "behind" forever. This exists so the drift is VISIBLE — the old
# behavior was silence, which is how a fleet stayed 3 releases behind on config without
# any surface ever saying so.
config_drift_report() {
  local notes=""

  if [ -f package.json ] && command -v jq >/dev/null 2>&1; then
    local missing_scripts
    missing_scripts="$(jq -r '
      (.scripts // {}) as $have
      | ["dev","doctor","sync","tail","worktree","worktree:new","worktree:rm","worktree:reap","worktree:status",
         "worktree:exec","govern","govern:health","govern:dry-run","govern:status","govern:audit",
         "govern:budgets","govern:trim","govern:externalize","govern:validations","vf"]
      | map(. as $k | select($have | has($k) | not)) | join(", ")
    ' package.json 2>/dev/null)"
    [ -n "$missing_scripts" ] && notes+="  package.json    missing script(s): $missing_scripts"$'\n'
  fi

  if [ -f scripts/lib/workspace.sh ]; then
    local knobs="" kline kvar
    while IFS= read -r kline || [ -n "$kline" ]; do
      case "$kline" in \#*|"") continue ;; *__*__*) continue ;; esac
      kvar="$(printf '%s' "$kline" | sed -nE 's/^(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=.*/\2/p')"
      [ -n "$kvar" ] || continue
      case " META_NAME ROOT_PM GITHUB_ORG REPOS REPO_CMDS REPO_PORTS WORKTREE_BASE SLOT_PORT_STEP " in
        *" $kvar "*) continue ;;
      esac
      grep -qE "^[[:space:]]*(export[[:space:]]+)?$kvar=" scripts/lib/workspace.sh || knobs+="$kvar "
    done < "$T/lib/workspace.sh"
    [ -n "$knobs" ] && notes+="  workspace.sh    knob(s) added since scaffold: $knobs"$'\n'
  fi

  [ -f README.md ] || notes+="  README.md       absent (a bump would create one)"$'\n'

  local sname sdest
  for sname in CLAUDE.md CLAUDE-APPENDIX.md learnings.md tickets.md tickets-parked.md; do
    case "$sname" in tickets.md|tickets-parked.md) sdest="queue/$sname" ;; *) sdest="$sname" ;; esac
    [ -f "$T/seed/$sname" ] || continue
    if [ ! -f "$sdest" ]; then
      notes+="  $sdest — absent (a bump would seed it)"$'\n'
    elif ! diff -q "$sdest" "$T/seed/$sname" >/dev/null 2>&1; then
      if seed_pristine "$sdest" "$sname"; then
        notes+="  $sdest — unedited older seed (a bump upgrades it losslessly)"$'\n'
      fi
      # Customized seeds are intentionally silent: that difference is the operator's work.
    fi
  done

  if [ -n "$notes" ]; then
    log "config + seeds (not byte-comparable; reported, not counted as drift):"
    printf '%s' "$notes" >&2
  else
    log "config + seeds: nothing outstanding"
  fi
  return 0
}

diff_only() {
  local behind=0
  # probe_files + the mechanism-component list are defined at top level so this
  # report and the stamp gate (workspace_converged) share one source of truth.
  for c in $MECH_COMPONENTS; do
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
  config_drift_report
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

# ── Standalone --verify (read-only against an already-scaffolded workspace) ─
# When VERIFY_ONLY was resolved above, run the verification checks without
# touching a byte on disk (no component_dirs, no writer). Nothing here needs
# --org or --repos — it's a health probe on the existing install.
if [ "$VERIFY_ONLY" -eq 1 ]; then
  log "verify-only mode (no writes) — probing existing scaffold at $WORKSPACE_DIR"
  verify_scripts
  verify_relocations
  purge_removed warn
  log "verify: standalone check complete"
  exit 0
fi

# ── Main dispatch ───────────────────────────────────────────────────────────

component_dirs
# Shed anything the hub used to install and has since retired. Runs on EVERY writer
# invocation (fresh scaffold, single-component refresh, /shiploop:update) so an old
# install converges on the current footprint no matter which component is bumped.
purge_removed apply

case "$COMPONENT" in
  all)
    component_workspace_sh
    component_core_scripts
    component_worktrees
    component_govern
    component_githooks
    component_project_commands
    component_agents
    component_workflows
    component_seeds
    component_readme
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
  agents)         component_agents ;;
  workflows)      component_workflows ;;
  seeds)          component_seeds ;;
  readme)         component_readme ;;
  gitignore)      component_gitignore ;;
  package-json)   component_package_json ;;
  settings)       component_settings ;;
  settings-merge) component_settings_merge ;;
  # The merge-tier trio: additive, idempotent, never clobber operator content. These are
  # what /shiploop:update runs so an EXISTING workspace converges on config too, not just
  # on the byte-comparable mechanism scripts.
  package-json-merge) component_package_json_merge ;;
  workspace-sh-merge) component_workspace_sh_merge ;;
  config-merge)   # convenience bundle: everything /update needs beyond MECH_COMPONENTS
    component_seeds
    component_readme
    component_gitignore
    component_package_json_merge
    component_workspace_sh_merge
    component_settings_merge
    ;;
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
    # `git add` is ATOMIC over its pathspec: one missing path aborts the whole call and stages
    # NOTHING. `validation` is not produced by any component, so this list always contained a
    # non-existent path — and with `2>/dev/null || true` swallowing the error, `--git-init` has been
    # silently producing an EMPTY initial commit. Filter to paths that exist before staging.
    git_add_paths=""
    for p in scripts .githooks governor package.json .gitignore .worktrees/.gitkeep \
             queue learnings.md CLAUDE.md CLAUDE-APPENDIX.md README.md \
             .claude/settings.json .claude/commands .claude/agents .claude/skills .claude/workflows validation; do
      [ -e "$p" ] && git_add_paths="$git_add_paths $p"
    done
    # shellcheck disable=SC2086 — deliberate word splitting into a pathspec list.
    if [ -n "$git_add_paths" ] && git add $git_add_paths; then
      git -c user.email=scaffold@shiploop -c user.name=scaffold \
          commit -q -m "chore: scaffold meta-repo workspace tooling (governor, worktrees, tickets, hooks)" || true
      info "initial commit created ($(git ls-files | wc -l | tr -d ' ') files)"
    else
      warn "nothing staged — skipping the initial commit"
    fi
  else
    info "git already initialized — skipping init"
  fi
fi

# ── Propagate sub-repo commit hooks (attribution + optional lint-fix) ────────
# Moves setup's Phase-3 hook loop into the scaffolder, so a fresh setup no longer
# spends a model turn driving it by hand. Only for a full scaffold (COMPONENT=all —
# fresh or a whole-refresh bump); standalone component runs skip it. wrap.sh passes
# --skip-subrepo-hooks: it MUST NOT mutate the moved sub-repo's .git/hooks while its
# byte-identical rollback is still armed (that would leave hook residue if the wrap
# rolled back or the undo script ran) — wrap-mode setup installs them in W4, after
# the rollback point retires. Isolated in a subshell (source + set changes never
# leak) and best-effort. worktree/new.sh re-runs the same installers per worktree.
if [ "$SKIP_SUBREPO_HOOKS" -eq 0 ] && [ "$COMPONENT" = "all" ] \
   && [ -f scripts/lib/workspace.sh ] && [ -f scripts/lib/githooks.sh ]; then
  log "propagating sub-repo commit hooks"
  (
    set +e
    # shellcheck disable=SC1091
    . scripts/lib/workspace.sh
    # shellcheck disable=SC1091
    . scripts/lib/githooks.sh
    for _r in "${REPOS[@]}"; do
      [ -d "$META_ROOT/$_r/.git" ] || [ -f "$META_ROOT/$_r/.git" ] || continue
      if install_subrepo_attribution_hook "$META_ROOT" "$META_ROOT/$_r" >/dev/null 2>&1; then
        info "  ✓ $_r: attribution hook"
      else
        info "  – $_r: attribution hook skipped"
      fi
      if install_subrepo_pre_commit_hook "$META_ROOT" "$META_ROOT/$_r" >/dev/null 2>&1; then
        info "  ✓ $_r: pre-commit hook"
      else
        info "  – $_r: pre-commit hook skipped"
      fi
    done
  ) || true
fi

# ── Verify (bash -n over the installed tree) ────────────────────────────────
if [ "$DO_VERIFY" -eq 1 ]; then
  verify_scripts
  verify_relocations
fi

log "scaffold: done (component=$COMPONENT workspace=$WORKSPACE_DIR)"
