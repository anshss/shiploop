#!/usr/bin/env bash
# Verify the godmode setup is healthy. Pass/warn/fail per check.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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
for sub in app backend website; do
  if [ -d "$ROOT/$sub/.git" ]; then
    ok "$sub/ present (git repo)"
  elif [ -d "$ROOT/$sub" ]; then
    warn "$sub/ exists but not a git repo"
  else
    fail "$sub/ missing — clone github.com/Splitoio/$sub"
  fi
done

# ── Env files ──
section "env files"
check_env() {
  local sub="$1" file="$2"
  if [ -f "$ROOT/$sub/$file" ]; then
    ok "$sub/$file present"
  elif [ -f "$ROOT/$sub/.env.example" ]; then
    warn "$sub/$file missing (copy $sub/.env.example)"
  else
    warn "$sub/$file missing and no .env.example"
  fi
}
check_env "app"     ".env"
check_env "backend" ".env"
check_env "website" ".env.local"

# ── Ports ──
section "ports (free or in-use by dev server)"
for port in 3000 3001 4000; do
  if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
    pid=$(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t | head -1)
    cmd=$(ps -p "$pid" -o comm= 2>/dev/null | xargs basename 2>/dev/null || echo "?")
    ok "port $port in use by $cmd (pid $pid)"
  else
    ok "port $port free"
  fi
done

# ── Port↔CLAUDE.md drift ──
section "port mapping consistency"
claude_md="$ROOT/CLAUDE.md"
health="$ROOT/health.sh"
if [ -f "$claude_md" ] && [ -f "$health" ]; then
  drift=0
  # Extract port mentions from CLAUDE.md table rows and from health.sh check lines.
  grep -E '^\| `(app|backend|website)/`' "$claude_md" 2>/dev/null | while read -r line; do
    name=$(echo "$line" | grep -oE '`(app|backend|website)/`' | tr -d '`/')
    port=$(echo "$line" | grep -oE '[0-9]{4}' | head -1)
    [ -z "$name" ] || [ -z "$port" ] && continue
    health_port=$(grep -E "check[[:space:]]+\"$name\"" "$health" | grep -oE '[0-9]{4}' | head -1)
    if [ -n "$health_port" ] && [ "$port" != "$health_port" ]; then
      echo "  ⚠ drift: CLAUDE.md says $name=$port, health.sh says $name=$health_port"
    fi
  done
  ok "checked CLAUDE.md ↔ health.sh"
else
  warn "could not compare CLAUDE.md and health.sh"
fi

# ── Workspace deps ──
section "workspace"
if [ -f "$ROOT/pnpm-workspace.yaml" ] || [ -f "$ROOT/pnpm-workspace.yml" ]; then
  ok "pnpm-workspace config present"
else
  warn "no pnpm-workspace.yaml at root"
fi
[ -d "$ROOT/node_modules" ] && ok "root node_modules installed" || warn "root node_modules missing — run 'pnpm install'"
[ -d "$ROOT/app/node_modules" ]     && ok "app/node_modules installed"     || warn "app/node_modules missing"
[ -d "$ROOT/backend/node_modules" ] && ok "backend/node_modules installed" || warn "backend/node_modules missing"
[ -d "$ROOT/website/node_modules" ] && ok "website/node_modules installed" || warn "website/node_modules missing"

# ── Prisma ──
section "prisma"
if [ -f "$ROOT/backend/prisma/schema.prisma" ]; then
  ok "backend/prisma/schema.prisma present"
  if [ -d "$ROOT/backend/node_modules/.prisma" ] || [ -d "$ROOT/backend/node_modules/@prisma/client" ]; then
    ok "prisma client generated"
  else
    warn "prisma client not generated — run 'cd backend && pnpm prisma:generate'"
  fi
else
  warn "no prisma schema found"
fi

# ── Summary ──
echo ""
echo "── summary ──"
echo "  ✓ pass: $PASS    ⚠ warn: $WARN    ✗ fail: $FAIL"
if [ $FAIL -gt 0 ]; then
  exit 1
elif [ $WARN -gt 0 ]; then
  exit 0  # warnings non-fatal
fi
