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
#   sync-templates.sh --paths     # same set, BARE paths, silent when empty (machine-readable)
#   sync-templates.sh --counterpart <live-path>
#                                 # print the template counterpart of one live path; exit 1 if unmirrored
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

# The marker is an untracked file that exists only in the main checkout. A worktree never has one,
# and running --mark there would start a fresh marker and discard the drift the main checkout has
# accumulated, so the message sends the operator back to the main checkout.
no_marker() {
  echo "sync-templates: no marker at $MARKER" >&2
  echo "  The marker lives only in the main checkout: run --check, --files and --mark from there," >&2
  echo "  never from a worktree (marking in a worktree discards the main checkout's accumulated drift)." >&2
  return 0
}

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

# Was this blob EVER a version the hub shipped for the template at $tpl? A converge
# commit writes an exact hub version that may be older than today's template, so
# "equals today's template" alone would count every old pull as local drift as soon
# as the hub changes the file again. Three sources, cheapest first: the shipped-hash
# manifests under $TEMPLATES_ROOT/lib (mechanism scripts and seeds), then the hub
# git history of the template path (main plus v* release tags, the same ref set
# tools/gen-mechanism-hashes.sh walks) for mirrored files neither manifest covers.
# Unreadable manifests or a templates root outside a git checkout just answer "no".
# Per-run cache of each template's history hashes. Created and removed by drift_commits (never
# inside a nested command substitution) so every lookup in one walk shares one directory.
HASH_CACHE_DIR=""
cleanup_hash_cache() {
  if [[ -n "$HASH_CACHE_DIR" ]]; then rm -rf "$HASH_CACHE_DIR"; fi
  return 0
}
trap cleanup_hash_cache EXIT   # covers an interrupted walk; drift_commits runs in a subshell, which resets traps

blob_sha256() { shasum -a 256 | cut -d' ' -f1; }

hub_history_hashes() { # <template-path> -> one sha256 per line, cached per template
  local tpl="$1" key top prefix rel mainref cand sha
  key="$HASH_CACHE_DIR/$(printf '%s' "$tpl" | tr '/ ' '__')"
  if [[ ! -f "$key" ]]; then
    : > "$key"
    top="$(git -C "$(dirname "$tpl")" rev-parse --show-toplevel 2>/dev/null)" || { return 0; }
    prefix="$(git -C "$(dirname "$tpl")" rev-parse --show-prefix 2>/dev/null)"
    rel="${prefix}$(basename "$tpl")"
    mainref=HEAD
    for cand in origin/main main; do
      if git -C "$top" rev-parse --verify --quiet "$cand^{commit}" >/dev/null; then mainref="$cand"; break; fi
    done
    {
      git -C "$top" log --format='%H' "$mainref" --tags='v[0-9]*' --follow -- "$rel" 2>/dev/null \
      | while IFS= read -r sha; do
          [[ -n "$sha" ]] || continue
          git -C "$top" show "$sha:$rel" 2>/dev/null | blob_sha256
        done
    } | sort -u > "$key"
  fi
  cat "$key"
  return 0
}

was_shipped_version() { # <blob-sha256> <template-path>
  local h="$1" tpl="$2" rel seedrel m
  rel="${tpl#"$TEMPLATES_ROOT"/}"
  seedrel="${rel#seed/}"
  m="$TEMPLATES_ROOT/lib/mechanism-hashes.txt"
  [[ -f "$m" ]] && grep -Fxq "$h  $rel" "$m" && return 0
  m="$TEMPLATES_ROOT/lib/seed-hashes.txt"
  [[ "$seedrel" != "$rel" && -f "$m" ]] && grep -Fxq "$h  $seedrel" "$m" && return 0
  grep -Fxq "$h" <<<"$(hub_history_hashes "$tpl")" && return 0
  return 1
}

drift_commits() { # <base>
  local sha f tpl h
  HASH_CACHE_DIR="$(mktemp -d)"
  while IFS= read -r sha; do
    [[ -z "$sha" ]] && continue
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      tpl="$(template_counterpart_path "$f")" || continue
      # Content-aware: a commit whose post-state for a mirrored file already
      # MATCHES the template, or any version the hub ever shipped, is a
      # hub→workspace convergence (a /shiploop:update pull), NOT a local
      # improvement to port back. Skip it so pulls don't masquerade as
      # harness→hub drift. A file that is no shipped version is genuine unported
      # local work → count the commit. A file the commit deleted has no post-state
      # and counts as before.
      if ! cmp -s <(git_g show "$sha:$f" 2>/dev/null) "$tpl"; then
        h="$(git_g show "$sha:$f" 2>/dev/null | blob_sha256)"
        if git_g cat-file -e "$sha:$f" 2>/dev/null && was_shipped_version "$h" "$tpl"; then
          continue
        fi
        git_g log -1 --format='%h %s' "$sha"
        break
      fi
    done < <(git_g diff-tree --no-commit-id --name-only -r "$sha" -- "${TRACKED[@]}" "${EXCLUDES[@]}")
  done < <(git_g log --no-merges --format='%H' "$1..$UPPER" -- "${TRACKED[@]}" "${EXCLUDES[@]}")
  cleanup_hash_cache
  return 0
}

MODE="${1:---check}"

case "$MODE" in
  --sha)
    read_marker || { no_marker; exit 2; }
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
    base="$(read_marker)" || { no_marker; exit 2; }
    files=()
    while IFS= read -r f; do [[ -n "$f" ]] && files+=("$f"); done < <(mirrored_files "$base")
    [[ ${#files[@]} -eq 0 ]] && { echo "(none — mirrored templates in sync through $base)"; exit 0; }
    git_g diff "$base..$UPPER" -- "${files[@]}"
    ;;

  --counterpart)
    # Machine-readable single-path lookup: repo-relative LIVE path -> its template
    # counterpart. Exit 0 + path on stdout when the file is mirrored; exit 1 and
    # silence when it is not. Needs no marker and touches no git history, so the
    # pre-dispatch drift gate (lib/pregate.sh) can call it on an arbitrary
    # `**Where:**` token without first proving the workspace is marker-initialized.
    [[ -n "${2:-}" ]] || { echo "sync-templates: --counterpart needs a repo-relative path" >&2; exit 2; }
    template_counterpart_path "$2" || exit 1
    ;;

  --paths)
    # Same set as --files, but BARE paths and a silent-empty contract (exit 0, no
    # output) so callers can consume it without stripping the human "[mirrored]"
    # column or the "(none — …)" sentence.
    #
    # The rc MUST be 0 for "no drift" and non-zero ONLY for "cannot answer" — the
    # drift gate keys its fail-open on exactly that distinction, and a bare
    # `mirrored_files` would leak its loop's last-iteration status (1 whenever the
    # final candidate happens to be unmirrored), turning a clean workspace into a
    # phantom "unknowable" and silently disarming the gate. Capture, then exit 0.
    base="$(read_marker)" || { no_marker; exit 2; }
    paths="$(mirrored_files "$base")"
    [[ -n "$paths" ]] && printf '%s\n' "$paths"
    exit 0
    ;;

  --files)
    base="$(read_marker)" || { no_marker; exit 2; }
    files="$(mirrored_files "$base")"
    [[ -z "$files" ]] && { echo "(none — mirrored templates in sync through $base)"; exit 0; }
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      printf '%-10s %s\n' "[mirrored]" "$f"
    done <<< "$files"
    ;;

  --check|"")
    base="$(read_marker)" || { no_marker; exit 2; }
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
    echo "sync-templates: unknown option '$MODE' (try --check|--files|--paths|--counterpart|--diff|--mark|--sha|--help)" >&2
    exit 2
    ;;
esac
