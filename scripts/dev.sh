#!/usr/bin/env bash
# Boot dev servers across sub-repos in parallel; tee each one's output to logs/<name>.log.
# Each sub-repo has its own dev command — driven by REPO_CMDS from workspace.sh.
# Do NOT assume one package manager for all: each sub-repo's REPO_CMDS entry handles
# its own PM (npm/pnpm/yarn/bun/make/cargo/go) explicitly.
# usage:  <pm> run dev              # all sub-repos
#         <pm> run dev -- --only a,b   # subset
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOGS="$ROOT/logs"
mkdir -p "$LOGS"

# ── workspace config ──
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/workspace.sh"

# ── worktree env (no-op in main checkout) ──
# Inside a per-task worktree this exports WORKTREE_*_PORT + outbound URLs.
# These are the canonical port values for this slot; workspace.sh's wsp_repo_port
# gives the same numbers but worktree.env makes them available as named vars for
# any sub-repo dev command that interpolates them directly (e.g. PORT=... make run).
# shellcheck source=/dev/null
[ -f "$ROOT/worktree.env" ] && source "$ROOT/worktree.env"

# Resolve the worktree slot (0 = main checkout).
SLOT="${WORKTREE_SLOT:-0}"

# ── central port assignment ──
# We intentionally IGNORE each sub-repo's pinned port in its own package.json/Makefile
# (e.g. "next dev --port 3000" hard-coded in a sub-repo dev script) and override here,
# so all worktree slots coexist without collision. Port for repo at this slot =
# wsp_repo_port <repo> <slot>  (base + slot * SLOT_PORT_STEP).
#
# Per-repo dev commands in REPO_CMDS (workspace.sh) must accept a PORT env or explicit
# --port flag so this override reaches the process. See the workspace.sh REPO_CMDS
# comment block for the convention per project type (Next.js, Go, Rust, etc.).

SCOPE="$(wsp_repos_csv)"
while [ $# -gt 0 ]; do
  case "$1" in
    --only) SCOPE="$2"; shift 2 ;;
    -h|--help) echo "usage: $ROOT_PM run dev -- [--only $(wsp_repos_csv)]"; exit 0 ;;
    *) echo "unknown arg: $1"; exit 2 ;;
  esac
done

pids=()
cleanup() {
  echo ""
  echo "stopping dev servers..."
  for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done
  sleep 1
  for pid in "${pids[@]}"; do kill -9 "$pid" 2>/dev/null || true; done
  exit 0
}
trap cleanup INT TERM

run_one() {
  local name="$1"
  local cmd="$2"
  local dir="$ROOT/$name"
  local log="$LOGS/$name.log"
  : > "$log"

  if [ ! -d "$dir" ]; then
    echo "[$name] (directory missing, skipping)"
    return
  fi
  if [ -z "$cmd" ]; then
    echo "[$name] (no dev command configured, skipping)"
    return
  fi

  (
    cd "$dir" || exit 1
    bash -c "$cmd" 2>&1 | while IFS= read -r line; do
      printf '[%s] %s\n' "$name" "$line"
      printf '%s\n' "$line" >> "$log"
    done
  ) &
  pids+=("$!")
}

# Preflight: free each scoped service's port before binding, so a stale stack
# from a non-clean prior exit (or another terminal on the same port) doesn't
# cause a silent EADDRINUSE that serves stale code. macOS bash 3.2
# has no `xargs -r`, so guard the empty case.
free_port() {
  local port="$1" held_pids
  [ -n "$port" ] || return 0
  held_pids=$(lsof -ti tcp:"$port" 2>/dev/null) || true
  if [ -n "$held_pids" ]; then
    echo "[dev] port $port held by stale PID(s): $held_pids — killing before bind"
    kill -9 $held_pids 2>/dev/null || true
    sleep 0.3
  fi
}

for repo in "${REPOS[@]}"; do
  [[ ",$SCOPE," == *",$repo,"* ]] || continue
  cmd="$(wsp_repo_cmd "$repo")"
  port=$(wsp_repo_port "$repo" "$SLOT")
  free_port "$port"
  run_one "$repo" "$cmd"
done

echo ""
echo "logs → $LOGS/<repo>.log"
echo "(ctrl-c to stop)"
wait
