#!/usr/bin/env bash
# detect-inputs.sh — one-shot interview-defaults detection for /shiploop:setup.
#
# Everything the setup interview needs, emitted as key=value lines in ONE call,
# so the setup command spends one tool round-trip on detection instead of a
# model turn per probe (port, lockfile, org, visibility, ... each used to be a
# separate think-act cycle — the dominant cost of a live onboarding run).
#
#   detect-inputs.sh --workspace-dir DIR --mode wrap|fresh
#
# Output (stdout), stable and grep-able:
#   root_pm=<npm|pnpm|yarn|bun>
#   worktree_base=</abs/path.wt>
#   org=<github-org or empty>
#   repo=<name>|<port>|<dev-cmd>|<visibility PUBLIC|PRIVATE|unknown>   (one per repo)
#   repos_spec=<name:port:cmd,...>                                     (scaffold --repos arg)
#
# wrap mode: DIR itself is the (single) repo being wrapped — its `repo=` line
# carries the wrap subfolder NAME (from origin, else folder name).
# fresh mode: every DIR/*/  with its own .git is a repo.
#
# Like wrap.sh, this is a setup-time tool that lives only in the hub/template
# checkout (templates/lib/); it is NOT installed into scaffolded workspaces.
set -uo pipefail

WORKSPACE_DIR=""
MODE=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --workspace-dir) WORKSPACE_DIR="$2"; shift 2 ;;
    --mode)          MODE="$2"; shift 2 ;;
    -h|--help)       sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
    *) printf 'detect-inputs.sh: unknown arg: %s\n' "$1" >&2; exit 2 ;;
  esac
done

[ -n "$WORKSPACE_DIR" ] || WORKSPACE_DIR="$(pwd)"
WORKSPACE_DIR="$(cd "$WORKSPACE_DIR" 2>/dev/null && pwd -P)" || { printf 'detect-inputs.sh: bad --workspace-dir\n' >&2; exit 2; }
case "$MODE" in wrap|fresh) : ;; *) printf 'detect-inputs.sh: --mode wrap|fresh is required\n' >&2; exit 2 ;; esac

# ── Per-repo probes ──────────────────────────────────────────────────────────

# org/name from a git remote url (git@host:org/repo.git or https://host/org/repo[.git]).
origin_org()  { sed -E 's#^git@[^:]+:##; s#^[a-z]+://[^/]+/##; s#\.git$##' <<<"$1" | cut -d/ -f1; }
origin_name() { sed -E 's#^git@[^:]+:##; s#^[a-z]+://[^/]+/##; s#\.git$##' <<<"$1" | cut -d/ -f2; }

# Dev command by lockfile signal, falling back to Makefile/Cargo.toml/go.mod.
# npm-family commands only when package.json actually has a dev script.
detect_cmd() { # <repo-dir>
  local d="$1" has_dev=0
  if [ -f "$d/package.json" ] && grep -q '"dev"[[:space:]]*:' "$d/package.json" 2>/dev/null; then has_dev=1; fi
  if [ "$has_dev" -eq 1 ]; then
    if   [ -f "$d/pnpm-lock.yaml" ]; then echo "pnpm dev"
    elif [ -f "$d/yarn.lock" ];      then echo "yarn dev"
    elif [ -f "$d/bun.lockb" ] || [ -f "$d/bun.lock" ]; then echo "bun run dev"
    else echo "npm run dev"; fi
    return
  fi
  if [ -f "$d/Makefile" ] && grep -qE '^run[[:space:]]*:' "$d/Makefile" 2>/dev/null; then echo "make run"; return; fi
  [ -f "$d/Cargo.toml" ] && { echo "cargo run"; return; }
  [ -f "$d/go.mod" ]     && { echo "go run ./..."; return; }
  echo ""
}

# Port from the package.json dev script: `-p NNNN` / `--port NNNN` (Next.js) or PORT=NNNN (Express).
detect_port() { # <repo-dir>
  local d="$1" script
  [ -f "$d/package.json" ] || { echo ""; return; }
  script="$(grep -o '"dev"[[:space:]]*:[[:space:]]*"[^"]*"' "$d/package.json" 2>/dev/null | head -1)"
  [ -n "$script" ] || { echo ""; return; }
  sed -nE 's/.*(-p |--port[ =]|PORT=)([0-9]{2,5}).*/\2/p' <<<"$script" | head -1
}

detect_visibility() { # <org> <name>
  local org="$1" name="$2" vis
  [ -n "$org" ] || { echo "unknown"; return; }
  command -v gh >/dev/null 2>&1 || { echo "unknown"; return; }
  vis="$(gh repo view "$org/$name" --json visibility -q .visibility 2>/dev/null)"
  echo "${vis:-unknown}"
}

# ── Collect repos ────────────────────────────────────────────────────────────
REPO_DIRS=()
if [ "$MODE" = "wrap" ]; then
  REPO_DIRS+=("$WORKSPACE_DIR")
else
  for d in "$WORKSPACE_DIR"/*/; do
    [ -e "$d/.git" ] && REPO_DIRS+=("${d%/}")
  done
fi

ORG=""
NAMES=() PORTS=() CMDS=() VIS=()
for d in "${REPO_DIRS[@]:-}"; do
  [ -n "$d" ] || continue
  url="$(git -C "$d" remote get-url origin 2>/dev/null || true)"
  name=""
  [ -n "$url" ] && name="$(origin_name "$url")"
  [ -n "$name" ] || name="$(basename "$d")"
  [ -n "$ORG" ] || { [ -n "$url" ] && ORG="$(origin_org "$url")"; }
  NAMES+=("$name"); PORTS+=("$(detect_port "$d")"); CMDS+=("$(detect_cmd "$d")")
done

# Resolve port collisions: keep the first claimant, bump later duplicates to the
# next port not already taken (3000, 3000 → 3000, 3001).
n="${#NAMES[@]}"
for ((i=0; i<n; i++)); do
  p="${PORTS[$i]}"; [ -n "$p" ] || continue
  taken=0
  for ((j=0; j<i; j++)); do [ "${PORTS[$j]}" = "$p" ] && taken=1; done
  while [ "$taken" -eq 1 ]; do
    p=$((p+1)); taken=0
    for ((j=0; j<i; j++)); do [ "${PORTS[$j]}" = "$p" ] && taken=1; done
  done
  PORTS[$i]="$p"
done

for ((i=0; i<n; i++)); do VIS+=("$(detect_visibility "$ORG" "${NAMES[$i]}")"); done

# ── Workspace-level probes ───────────────────────────────────────────────────
ROOT_PM="npm"
if   [ -f "$WORKSPACE_DIR/pnpm-lock.yaml" ]; then ROOT_PM="pnpm"
elif [ -f "$WORKSPACE_DIR/yarn.lock" ];      then ROOT_PM="yarn"
elif [ -f "$WORKSPACE_DIR/bun.lockb" ] || [ -f "$WORKSPACE_DIR/bun.lock" ]; then ROOT_PM="bun"
fi

# ── Emit ─────────────────────────────────────────────────────────────────────
printf 'root_pm=%s\n' "$ROOT_PM"
printf 'worktree_base=%s\n' "$(dirname "$WORKSPACE_DIR")/$(basename "$WORKSPACE_DIR").wt"
printf 'org=%s\n' "$ORG"
SPEC=""
for ((i=0; i<n; i++)); do
  printf 'repo=%s|%s|%s|%s\n' "${NAMES[$i]}" "${PORTS[$i]}" "${CMDS[$i]}" "${VIS[$i]}"
  SPEC="${SPEC:+$SPEC,}${NAMES[$i]}:${PORTS[$i]}:${CMDS[$i]}"
done
printf 'repos_spec=%s\n' "$SPEC"
