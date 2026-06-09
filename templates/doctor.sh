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
# That file can add project-specific checks (e.g. Akash chain health,
# Prisma migration drift, cloud CLI auth, database reachability) using
# the same ok/warn/fail/section helpers defined above.
# shellcheck source=/dev/null
if [ -f "$ROOT/scripts/lib/doctor-extra.sh" ]; then
  source "$ROOT/scripts/lib/doctor-extra.sh"
fi

# ── Summary ──
echo ""
echo "── summary ──"
echo "  ✓ pass: $PASS    ⚠ warn: $WARN    ✗ fail: $FAIL"
if [ $FAIL -gt 0 ]; then exit 1; fi
