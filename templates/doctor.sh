#!/usr/bin/env bash
# Verify the meta-repo workspace is healthy. Pass/warn/fail per check.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ── customize: list your sub-repo folder names and dev ports here ──
REPOS=("app" "backend" "website")
PORTS=(3001 4000 3000)   # one per REPO, same order

PASS=0; WARN=0; FAIL=0

ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
warn() { echo "  ⚠ $1"; WARN=$((WARN+1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

section() { echo ""; echo "── $1 ──"; }

# ── Tooling ──
section "tooling"
command -v node >/dev/null   && ok "node $(node -v)"        || fail "node missing"
command -v pnpm >/dev/null   && ok "pnpm $(pnpm -v)"        || fail "pnpm missing"
command -v git  >/dev/null   && ok "git $(git --version | awk '{print $3}')" || fail "git missing"
if command -v gh >/dev/null; then
  if gh auth status >/dev/null 2>&1; then ok "gh authenticated"; else warn "gh installed but not authenticated (run 'gh auth login')"; fi
else fail "gh missing (brew install gh)"; fi
command -v curl >/dev/null && ok "curl" || fail "curl missing"

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
  local sub="$1"
  if [ -f "$ROOT/$sub/.env" ] || [ -f "$ROOT/$sub/.env.local" ]; then
    ok "$sub/ has .env or .env.local"
  elif [ -f "$ROOT/$sub/.env.example" ]; then
    warn "$sub/.env missing (copy $sub/.env.example)"
  else
    warn "$sub/.env missing and no .env.example"
  fi
}
for sub in "${REPOS[@]}"; do
  check_env "$sub"
done

# ── Ports ──
section "ports (free or in-use by dev server)"
for port in "${PORTS[@]}"; do
  if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
    pid=$(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t | head -1)
    cmd=$(ps -p "$pid" -o comm= 2>/dev/null | xargs basename 2>/dev/null || echo "?")
    ok "port $port in use by $cmd (pid $pid)"
  else
    ok "port $port free"
  fi
done

# ── Workspace deps ──
section "workspace"
if [ -f "$ROOT/pnpm-workspace.yaml" ] || [ -f "$ROOT/pnpm-workspace.yml" ]; then
  ok "pnpm-workspace config present"
else
  warn "no pnpm-workspace.yaml at root"
fi
[ -d "$ROOT/node_modules" ] && ok "root node_modules installed" || warn "root node_modules missing — run 'pnpm install'"
for sub in "${REPOS[@]}"; do
  [ -d "$ROOT/$sub/node_modules" ] && ok "$sub/node_modules installed" || warn "$sub/node_modules missing"
done

# ── Summary ──
echo ""
echo "── summary ──"
echo "  ✓ pass: $PASS    ⚠ warn: $WARN    ✗ fail: $FAIL"
if [ $FAIL -gt 0 ]; then
  exit 1
elif [ $WARN -gt 0 ]; then
  exit 0  # warnings non-fatal
fi
