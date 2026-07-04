#!/usr/bin/env bash
# Verify the meta-repo workspace is healthy. Pass/warn/fail per check.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ── workspace config ──
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/workspace.sh"

# ── worktree env (no-op in main checkout) ──
# shellcheck source=/dev/null
[ -f "$ROOT/worktree.env" ] && source "$ROOT/worktree.env"

SLOT="${WORKTREE_SLOT:-0}"

PASS=0; WARN=0; FAIL=0
ok()      { echo "  ✓ $1"; PASS=$((PASS+1)); }
warn()    { echo "  ⚠ $1"; WARN=$((WARN+1)); }
fail()    { echo "  ✗ $1"; FAIL=$((FAIL+1)); }
section() { echo ""; echo "── $1 ──"; }

# ── Tooling ──
section "tooling"
command -v node >/dev/null   && ok "node $(node -v)"        || warn "node missing"
command -v git  >/dev/null   && ok "git $(git --version | awk '{print $3}')" || fail "git missing"
if command -v gh >/dev/null; then
  if gh auth status >/dev/null 2>&1; then ok "gh authenticated"; else warn "gh installed but not authenticated (run 'gh auth login')"; fi
else fail "gh missing (brew install gh / https://cli.github.com)"; fi
command -v curl >/dev/null && ok "curl" || fail "curl missing"
command -v jq   >/dev/null && ok "jq"   || warn "jq missing (needed for worktree registry)"

# Root package manager
case "$ROOT_PM" in
  npm)  command -v npm  >/dev/null && ok "npm $(npm -v)"   || warn "npm missing" ;;
  pnpm) command -v pnpm >/dev/null && ok "pnpm"            || warn "pnpm missing" ;;
  yarn) command -v yarn >/dev/null && ok "yarn"            || warn "yarn missing" ;;
  bun)  command -v bun  >/dev/null && ok "bun"             || warn "bun missing" ;;
  *)    warn "unknown ROOT_PM '$ROOT_PM'" ;;
esac

# ── Sub-repos ──
section "sub-repos"
for sub in "${REPOS[@]}"; do
  if [ -d "$ROOT/$sub/.git" ]; then
    ok "$sub/ present (git repo)"
  elif [ -d "$ROOT/$sub" ]; then
    warn "$sub/ exists but not a git repo"
  else
    fail "$sub/ missing — clone the sub-repo into this folder"
  fi
done

# ── Env files ──
section "env files"
check_env() {
  local sub="$1" env_dir="$2"
  if [ -f "$ROOT/$env_dir/.env" ] || [ -f "$ROOT/$env_dir/.env.local" ]; then
    ok "$sub/ has .env or .env.local"
  elif [ -f "$ROOT/$env_dir/.env.example" ]; then
    warn "$sub/.env missing (copy $env_dir/.env.example)"
  else
    warn "$sub/.env missing and no .env.example"
  fi
}
# Check each sub-repo's root for an env file (convention: .env at sub-repo root).
for sub in "${REPOS[@]}"; do
  check_env "$sub" "$sub"
done

# ── Ports ──
section "ports (free or in-use by dev server)"
for repo in "${REPOS[@]}"; do
  port=$(wsp_repo_port "$repo" "$SLOT")
  [ -n "$port" ] || continue
  if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
    pid=$(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t | head -1)
    cmd=$(ps -p "$pid" -o comm= 2>/dev/null | xargs basename 2>/dev/null || echo "?")
    ok "$repo port $port in use by $cmd (pid $pid)"
  else
    ok "$repo port $port free"
  fi
done

# ── Workspace config ──
section "workspace"
[ -f "$ROOT/package.json" ] && ok "root package.json present" || warn "root package.json missing"
[ -f "$ROOT/scripts/lib/workspace.sh" ] && ok "scripts/lib/workspace.sh present" || fail "scripts/lib/workspace.sh missing — run meta-repo setup"

# Git-hooks enforcement: the harness activates .githooks/ via core.hooksPath (pre-push guard +
# commit-attribution). If it's unset (e.g. a fresh clone that never ran setup's git config step),
# the enforcement is silently inert — warn with the one-liner to activate it.
hooks_path="$(git -C "$ROOT" config --get core.hooksPath 2>/dev/null || true)"
if [ "$hooks_path" = ".githooks" ]; then
  ok "core.hooksPath = .githooks (push guard + attribution active)"
elif [ -z "$hooks_path" ]; then
  warn "core.hooksPath unset — run 'git config core.hooksPath .githooks' in the harness root to activate .githooks/"
else
  warn "core.hooksPath = '$hooks_path' (expected .githooks) — harness push guard/attribution may be inactive"
fi

# Git drift across the checkout (root + every sub-repo): off-main branch, dirty
# tree, and ahead/behind vs the tracked upstream. Pure read.
git_drift() {
  local label="$1" dir="$2"
  [ -d "$dir/.git" ] || [ -f "$dir/.git" ] || { warn "$label: not a git repo"; return; }
  local br dirty ahead behind upstream
  br=$(git -C "$dir" branch --show-current 2>/dev/null)
  [ -n "$br" ] || br="(detached)"
  dirty=$(git -C "$dir" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  ahead=0; behind=0
  if upstream=$(git -C "$dir" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null); then
    ahead=$(git -C "$dir" rev-list --count "$upstream..HEAD" 2>/dev/null || echo 0)
    behind=$(git -C "$dir" rev-list --count "HEAD..$upstream" 2>/dev/null || echo 0)
  fi
  local msg="$label on $br"
  [ "$dirty" != "0" ] && msg="$msg, $dirty dirty"
  [ "${ahead:-0}" -gt 0 ] 2>/dev/null && msg="$msg, +$ahead ahead"
  [ "${behind:-0}" -gt 0 ] 2>/dev/null && msg="$msg, -$behind behind"
  if [ "$dirty" = "0" ] && [ "${ahead:-0}" -eq 0 ] && [ "${behind:-0}" -eq 0 ]; then
    ok "$msg (clean)"
  else
    warn "$msg"
  fi
}
git_drift "root" "$ROOT"
for sub in "${REPOS[@]}"; do git_drift "$sub" "$ROOT/$sub"; done

# Dependency drift (node_modules vs package.json) — a declared-but-uninstalled
# dep crashes the dev server with "Cannot find module" at runtime. Pure probe
# from scripts/lib/preflight.sh.
# shellcheck source=/dev/null
if [ -f "$ROOT/scripts/lib/preflight.sh" ]; then
  source "$ROOT/scripts/lib/preflight.sh"
  for sub in "${REPOS[@]}"; do
    [ -f "$ROOT/$sub/package.json" ] || continue
    missing=$(preflight_missing_deps "$ROOT/$sub") || continue   # return 2 → skip (no node / no pkg)
    if [ "$missing" = "__NO_NODE_MODULES__" ]; then
      warn "$sub: node_modules absent — run install in $sub/"
    elif [ -n "$missing" ]; then
      warn "$sub: declared deps not installed: $missing (run install in $sub/)"
    else
      ok "$sub: node_modules satisfies package.json"
    fi
  done
fi

# ── Worktrees ──
section "worktrees"
if [ -f "$ROOT/.worktrees/registry.json" ] && command -v jq >/dev/null 2>&1; then
  count=$(jq '[.slots | to_entries[] | select(.key != "0")] | length' "$ROOT/.worktrees/registry.json")
  if [ "$count" -eq 0 ]; then
    ok "no worktrees registered (slot 0 only)"
  else
    ok "$count worktree(s) registered"
    while IFS=$'\t' read -r slot name path; do
      if [ -d "$path" ]; then
        ok "slot $slot: $name → $path"
      else
        warn "slot $slot: $name → $path (orphaned, run $ROOT_PM run worktree:status -- --gc)"
      fi
    done < <(jq -r '.slots | to_entries[] | select(.key != "0") | [.key, .value.name, .value.path] | @tsv' "$ROOT/.worktrees/registry.json")
  fi
else
  warn "registry missing or jq unavailable — worktree state unknown"
fi

# ── Project-specific doctor hook ──
# If the project provides scripts/lib/doctor-extra.sh, source it here.
# That file can add project-specific checks (e.g. blockchain/RPC health,
# ORM migration drift, cloud CLI auth, database reachability) using
# the same ok/warn/fail/section helpers defined above.
# shellcheck source=/dev/null
if [ -f "$ROOT/scripts/lib/doctor-extra.sh" ]; then
  source "$ROOT/scripts/lib/doctor-extra.sh"
fi

# ── Update channel — is the harness behind the installed hub? ──
# scaffold.sh writes scripts/lib/.harness-version (the hub VERSION this workspace
# was last synced against). If the installed hub is locally resolvable and its
# VERSION file names a newer version, warn that a bump is due. When the hub
# can't be resolved (adopter installed via plugin cache / offline / repo
# elsewhere), degrade to a soft "cannot compare" notice — never an error.
section "update channel"
stamp="$ROOT/scripts/lib/.harness-version"
if [ -f "$stamp" ]; then
  stamp_v="$(awk 'NF && $0 !~ /^#/ {print $1; exit}' "$stamp")"
  hub_v=""
  # Resolve the hub in priority order (mirrors setup.md's Locate-the-plugin block).
  for _cand in "${CLAUDE_PLUGIN_ROOT:-}" \
               "$HOME/.claude/skills/shiploop" \
               "$HOME/.claude/plugins/cache/claude-plugins-official/shiploop"; do
    [ -n "$_cand" ] && [ -f "$_cand/VERSION" ] && { hub_v="$(awk 'NF && $0 !~ /^#/ {print $1; exit}' "$_cand/VERSION")"; break; }
  done
  if [ -z "$hub_v" ]; then
    # Fallback: any /Users/*/plugins/**/shiploop/VERSION we can glob.
    for _cand in "$HOME"/.claude/plugins/*/shiploop/VERSION \
                 "$HOME"/.claude/plugins/*/*/shiploop/VERSION; do
      [ -f "$_cand" ] && { hub_v="$(awk 'NF && $0 !~ /^#/ {print $1; exit}' "$_cand")"; break; }
    done
  fi
  if [ -z "$hub_v" ]; then
    warn "workspace stamped at $stamp_v — cannot locate the installed hub to compare (soft: not an error)"
  elif [ "$stamp_v" = "$hub_v" ]; then
    ok "harness stamp = hub VERSION = $hub_v (up to date)"
  else
    # Best-effort ordering: if the two are lexicographically or numerically ordered, count releases behind.
    behind=""
    if command -v sort >/dev/null 2>&1; then
      _newer="$(printf '%s\n%s\n' "$stamp_v" "$hub_v" | sort -V | tail -1)"
      if [ "$_newer" = "$hub_v" ]; then behind="behind"; else behind="ahead"; fi
    fi
    if [ "$behind" = "behind" ]; then
      warn "harness $stamp_v BEHIND hub $hub_v — run the setup upgrade: bash \$HUB/scaffold.sh --workspace-dir . --component <name>"
    elif [ "$behind" = "ahead" ]; then
      warn "harness $stamp_v AHEAD of installed hub $hub_v (dev checkout?)"
    else
      warn "harness stamp $stamp_v ≠ hub $hub_v — versions differ"
    fi
  fi
else
  warn "no scripts/lib/.harness-version stamp — re-run scaffold.sh once to write one (harmless if the hub is unresolvable)"
fi

# ── Summary ──
echo ""
echo "── summary ──"
echo "  ✓ pass: $PASS    ⚠ warn: $WARN    ✗ fail: $FAIL"
if [ $FAIL -gt 0 ]; then exit 1; fi
