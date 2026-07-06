#!/usr/bin/env bash
# Report harness→template drift so ALL accumulated mirrored changes can be
# ported into the shiploop templates in ONE batched PR, instead of one
# ticket-per-change (a 1:1 amplification pattern that dominated governor
# throughput in one measured session with near-zero product value — the "port
# #N into templates" churn class).
#
# What "mirrored" means (robust rule — track by MIRROR PRESENCE, not by dir):
#   A live file is drift-relevant IFF it has a TEMPLATE COUNTERPART. The
#   template's presence marks the file "generic / mirrored"; a live file with
#   no template counterpart is workspace-specific and has no business being
#   ported (deploy-check.sh, workspace-scoped lib helpers, etc.). This lets us
#   widen the git pathspec to whole dirs (scripts/, governor/, .githooks/,
#   .claude/commands/, CLAUDE.md) that MIX generic + specific files, then
#   filter down to only the genuinely-mirrored ones.
#
# The live↔template mapping (scaffold inverse):
#   scripts/govern/*        ↔ templates/govern/*
#   governor/*              ↔ templates/governor/*
#   scripts/worktree/*      ↔ templates/worktree/*
#   scripts/lib/*           ↔ templates/lib/*
#   .githooks/*             ↔ templates/githooks/*
#   .claude/commands/*      ↔ templates/.claude/commands/*
#   scripts/<name>.sh       ↔ templates/hooks/<name>.sh  OR  templates/<name>.sh
#   CLAUDE.md               ↔ templates/seed/CLAUDE.md
#
# Deliberately NOT mirrored (excluded even though a same-named template file
# exists): the marker file itself, governor runtime artifacts the loop WRITES
# (improvements.md/escalations.md/decisions-log.md/.ticket-seq — templates
# carry only seed versions), scripts/lib/workspace.sh (the ONE per-workspace
# CONFIG sink, intentionally divergent from its placeholder template), and
# CLAUDE.md (the seed is a lean generic STARTER, not a mirror). Everything
# else with no template counterpart is filtered out by has_template_counterpart.
#
# Where the local templates live — TWO sources of truth in priority order:
#   1. GOVERN_UPSTREAM_HARNESS_DIR (workspace.sh knob) — an explicit local
#      clone of your fork / the canonical repo. Point this at wherever you
#      checked out shiploop for contribution.
#   2. GOVERN_TEMPLATE_DIR (env-only, tests) — direct path to templates/govern.
#   3. $HOME/.claude/skills/shiploop/templates/govern — legacy install path.
#
# Marker: scripts/govern/.templates-synced-at holds the harness commit SHA the
# templates are synced through. Drift = commits in (<marker>..HEAD) that touch
# ≥1 mirrored file.
#
# Usage:
#   sync-templates.sh [--check]   # default: report unported drift; exit 3 if any, 0 if clean
#   sync-templates.sh --files     # list distinct MIRRORED files changed since the marker
#   sync-templates.sh --diff      # emit the consolidated diff of the mirrored files to port
#   sync-templates.sh --mark [SHA]# advance the marker to SHA (default HEAD)
#   sync-templates.sh --sha       # print the current marker SHA
#
# Env overrides (tests): GOVERN_DIR (govern script dir), GOVERN_SYNC_MARKER
# (marker file), GOVERN_PROMPTS_DIR (governor prompts dir; skipped if missing),
# GOVERN_TEMPLATE_DIR / GOVERN_PROMPTS_TEMPLATE_DIR (local templates dirs;
# GOVERN_TEMPLATE_DIR's PARENT is the templates root), GOVERN_SYNC_UPPER_BOUND
# (enumeration upper bound for --check/--files/--diff; default HEAD — sync-port
# pins it to one HEAD capture to close a mid-run TOCTOU race).
set -uo pipefail

GOVERN_DIR="${GOVERN_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
MARKER="${GOVERN_SYNC_MARKER:-$GOVERN_DIR/.templates-synced-at}"

# N4: optional enumeration UPPER BOUND. Every drift walk below is "marker..UPPER";
# UPPER defaults to HEAD (unchanged behavior). sync-port pins it to a single
# HEAD capture (GOVERN_SYNC_UPPER_BOUND=<sha>) so a mirrored-file commit landing
# on live main mid-run can't be excluded from the port yet swept into the marker
# advance (silent drift loss via race).
UPPER="${GOVERN_SYNC_UPPER_BOUND:-HEAD}"

# Resolve the repo + the govern dir's path relative to the repo root.
REPO_ROOT="$(git -C "$GOVERN_DIR" rev-parse --show-toplevel 2>/dev/null)" || {
  echo "sync-templates: $GOVERN_DIR is not inside a git repo" >&2; exit 2; }
GOVERN_REL="$(cd "$GOVERN_DIR" && git rev-parse --show-prefix)"
GOVERN_REL="${GOVERN_REL%/}"
SCRIPTS_REL="${GOVERN_REL%/*}"
MARKER_REL="${GOVERN_REL}/$(basename "$MARKER")"

# Resolve the templates root — try workspace.sh's GOVERN_UPSTREAM_HARNESS_DIR
# first (an adopter with a local clone of their fork can point us there), then
# the direct GOVERN_TEMPLATE_DIR env override, then the legacy skill path.
_resolve_upstream_dir() {
  # Source workspace.sh in a subshell so we can read the knob without polluting
  # this script's env (workspace.sh may set -u traps that interact badly).
  ( set +u
    ws="$REPO_ROOT/scripts/lib/workspace.sh"
    [ -f "$ws" ] && . "$ws" 2>/dev/null || true
    printf '%s\n' "${GOVERN_UPSTREAM_HARNESS_DIR:-}"
  )
}
if [[ -n "${GOVERN_TEMPLATE_DIR:-}" ]]; then
  TEMPLATE_DIR="$GOVERN_TEMPLATE_DIR"
else
  _upstream_dir="$(_resolve_upstream_dir)"
  if [[ -n "$_upstream_dir" && -d "$_upstream_dir/templates/govern" ]]; then
    TEMPLATE_DIR="$_upstream_dir/templates/govern"
  else
    TEMPLATE_DIR="$HOME/.claude/skills/shiploop/templates/govern"
  fi
fi
TEMPLATES_ROOT="$(dirname "$TEMPLATE_DIR")"
PROMPTS_TEMPLATE_DIR="${GOVERN_PROMPTS_TEMPLATE_DIR:-$TEMPLATES_ROOT/governor}"

# Second tracked area: the governor/ prompt dir, mirrored into templates/governor/.
PROMPTS_DIR="${GOVERN_PROMPTS_DIR:-$REPO_ROOT/governor}"
PROMPTS_REL=""
if [[ -d "$PROMPTS_DIR" ]]; then
  PROMPTS_REL="$(cd "$PROMPTS_DIR" && git rev-parse --show-prefix 2>/dev/null)"
  PROMPTS_REL="${PROMPTS_REL%/}"
fi

# Widened git pathspec: the UNION of dirs that CONTAIN mirrored files.
TRACKED=("$SCRIPTS_REL" ".githooks" ".claude/commands" "CLAUDE.md")
[[ -n "$PROMPTS_REL" ]] && TRACKED+=("$PROMPTS_REL")

# Never-portable files (excluded at the git-pathspec level).
EXCLUDES=(":(exclude)$MARKER_REL" ":(exclude)$SCRIPTS_REL/lib/workspace.sh" ":(exclude)CLAUDE.md")
if [[ -n "$PROMPTS_REL" ]]; then
  for rt in improvements.md escalations.md decisions-log.md .ticket-seq; do
    EXCLUDES+=(":(exclude)$PROMPTS_REL/$rt")
  done
fi

git_g() { git -C "$REPO_ROOT" "$@"; }

read_marker() {
  [[ -f "$MARKER" ]] || return 1
  awk 'NF && $0 !~ /^#/ {print $1; exit}' "$MARKER"
}

# Map a repo-relative live path to its candidate template file path(s) under
# $TEMPLATES_ROOT. Echoes zero or more candidates; file is "mirrored" iff any exists.
template_candidates() { # <repo-relative-path>
  local p="$1" rest b
  case "$p" in
    "$GOVERN_REL"/*)
      rest="${p#"$GOVERN_REL"/}"; echo "$TEMPLATE_DIR/$rest" ;;
    "$SCRIPTS_REL"/worktree/*)
      rest="${p#"$SCRIPTS_REL"/worktree/}"; echo "$TEMPLATES_ROOT/worktree/$rest" ;;
    "$SCRIPTS_REL"/lib/*)
      rest="${p#"$SCRIPTS_REL"/lib/}"; echo "$TEMPLATES_ROOT/lib/$rest" ;;
    "$SCRIPTS_REL"/*/*)
      : ;;
    "$SCRIPTS_REL"/*)
      b="${p#"$SCRIPTS_REL"/}"
      echo "$TEMPLATES_ROOT/hooks/$b"
      echo "$TEMPLATES_ROOT/$b" ;;
    .githooks/*)
      echo "$TEMPLATES_ROOT/githooks/${p#.githooks/}" ;;
    .claude/commands/*)
      echo "$TEMPLATES_ROOT/.claude/commands/${p#.claude/commands/}" ;;
    CLAUDE.md)
      echo "$TEMPLATES_ROOT/seed/CLAUDE.md" ;;
    *)
      if [[ -n "$PROMPTS_REL" && "$p" == "$PROMPTS_REL"/* ]]; then
        echo "$PROMPTS_TEMPLATE_DIR/${p#"$PROMPTS_REL"/}"
      fi ;;
  esac
}

has_template_counterpart() { # <repo-relative-path>
  local c
  while IFS= read -r c; do
    [[ -n "$c" && -f "$c" ]] && return 0
  done < <(template_candidates "$1")
  return 1
}

# Echo the FIRST existing template counterpart path for a live file (or nothing).
template_counterpart_path() { # <repo-relative-path> -> template-path | ""
  local c
  while IFS= read -r c; do
    [[ -n "$c" && -f "$c" ]] && { printf '%s\n' "$c"; return 0; }
  done < <(template_candidates "$1")
  return 1
}

candidate_files() { git_g diff --name-only "$1..$UPPER" -- "${TRACKED[@]}" "${EXCLUDES[@]}"; }

mirrored_files() { # <base>
  local f
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    has_template_counterpart "$f" && printf '%s\n' "$f"
  done < <(candidate_files "$1")
}

drift_commits() { # <base>
  local sha f tpl
  while IFS= read -r sha; do
    [[ -z "$sha" ]] && continue
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      tpl="$(template_counterpart_path "$f")" || continue
      # K6 — content-aware: a commit whose post-state for a mirrored file already
      # MATCHES the template is a hub→workspace convergence (a /shiploop:update
      # pull), NOT a local improvement to port back. Skip it so pulls don't
      # masquerade as harness→hub drift. A file that DIFFERS from the template is
      # genuine unported local work → count the commit.
      if ! cmp -s <(git_g show "$sha:$f" 2>/dev/null) "$tpl"; then
        git_g log -1 --format='%h %s' "$sha"
        break
      fi
    done < <(git_g diff-tree --no-commit-id --name-only -r "$sha" -- "${TRACKED[@]}" "${EXCLUDES[@]}")
  done < <(git_g log --no-merges --format='%H' "$1..$UPPER" -- "${TRACKED[@]}" "${EXCLUDES[@]}")
}

MODE="${1:---check}"

case "$MODE" in
  --sha)
    read_marker || { echo "sync-templates: no marker at $MARKER" >&2; exit 2; }
    ;;

  --mark)
    sha="${2:-HEAD}"
    full="$(git_g rev-parse "$sha")" || { echo "sync-templates: bad ref '$sha'" >&2; exit 2; }
    {
      echo "# Harness commit the meta-repo templates are synced THROUGH."
      echo "# Advanced by scripts/govern/sync-templates.sh --mark when a batched template-sync PR lands."
      echo "$full"
    } > "$MARKER"
    echo "sync-templates: marker advanced to $full"
    ;;

  --diff)
    base="$(read_marker)" || { echo "sync-templates: no marker at $MARKER" >&2; exit 2; }
    files=()
    while IFS= read -r f; do [[ -n "$f" ]] && files+=("$f"); done < <(mirrored_files "$base")
    [[ ${#files[@]} -eq 0 ]] && { echo "(none — mirrored templates in sync through $base)"; exit 0; }
    git_g diff "$base..$UPPER" -- "${files[@]}"
    ;;

  --files)
    base="$(read_marker)" || { echo "sync-templates: no marker at $MARKER" >&2; exit 2; }
    files="$(mirrored_files "$base")"
    [[ -z "$files" ]] && { echo "(none — mirrored templates in sync through $base)"; exit 0; }
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      printf '%-10s %s\n' "[mirrored]" "$f"
    done <<< "$files"
    ;;

  --check|"")
    base="$(read_marker)" || {
      echo "sync-templates: no marker at $MARKER — run 'sync-templates.sh --mark' to initialize" >&2
      exit 2; }
    commits="$(drift_commits "$base")"
    if [[ -z "$commits" ]]; then
      echo "✓ templates in sync through ${base:0:9} — no unported harness commits touch a mirrored file"
      exit 0
    fi
    n="$(printf '%s\n' "$commits" | grep -c .)"
    nfiles="$(mirrored_files "$base" | grep -c .)"
    echo "⚠ $n unported harness commit(s) touching a MIRRORED template file since ${base:0:9} ($nfiles file(s)):"
    printf '%s\n' "$commits" | sed 's/^/   /'
    echo
    echo "→ Do NOT file a per-change 'port #N into templates' ticket. Batch these into ONE"
    echo "  'sync templates' PR on the meta-repo: inspect 'sync-templates.sh --diff', port additively"
    echo "  into $TEMPLATES_ROOT, then land the PR and run 'sync-templates.sh --mark'."
    exit 3
    ;;

  -h|--help)
    sed -n '2,/^set -uo/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; $d'
    ;;

  *)
    echo "sync-templates: unknown option '$MODE' (try --check|--files|--diff|--mark|--sha|--help)" >&2
    exit 2
    ;;
esac
