#!/usr/bin/env bash
# wrap.sh — wrap-in-place transform for /shiploop:setup.
#
# Turns the CURRENT git repo into a shiploop workspace WITHOUT the empty-parent
# ritual: it moves the repo's contents into a subfolder of the same path, then
# scaffolds the workspace root where the repo used to be. The outer path stays
# stable (~/code/myproject remains what you cd into; the repo now lives at
# ~/code/myproject/<name>/).
#
# ── Architecture (load-bearing) ──────────────────────────────────────────────
# The ENTIRE preflight → move → verify → scaffold → verify → rollback sequence
# is ONE script invoked in a single call. The rollback trap is armed from before
# the first move to after the final verify, so a Ctrl-C or crash at ANY point
# leaves the repo either fully wrapped or fully restored — NEVER half-disassembled.
# commands/setup.md invokes this; it never orchestrates the moves itself.
#
# This is NOT a workspace mechanism script — it is a one-time setup-time transform
# run from the plugin/hub. It is intentionally not installed into scaffolded
# workspaces (it lives in templates/lib/, which scaffold does not auto-copy).
#
# ── Exit codes (setup.md branches on these) ─────────────────────────────────
#   0  wrapped + scaffolded OK
#   1  transform failed mid-flight — trap rolled the layout back; .wrap-undo.sh kept
#   2  usage / argument error (nothing touched)
#   3  hard preflight refusal, no override (nothing touched)
#   4  subfolder-name collision (setup.md re-prompts for a name)
#   5  warn+confirm preflight not yet confirmed (setup.md asks, re-invokes with --confirm-*)
#
# ── Test seams (env, undocumented for users) ────────────────────────────────
#   WRAP_TEST_FAIL_AT=<moving|pre-rename|renamed|scaffolding>  force failure at a phase
#   WRAP_TEST_HANG_BEFORE_RENAME=1                             sleep before the rename (for SIGINT injection)
#
set -uo pipefail

# ── Constants ────────────────────────────────────────────────────────────────
UNDO_FILE=".wrap-undo.sh"
MANIFEST_FILE=".wrap-manifest"
STAGING_GLOB=".wrap-staging.*"

# Top-level paths scaffold.sh creates (its --git-init `git add` set + component
# dirs + seeds). Baked into the undo manifest BEFORE scaffold runs so the manifest
# exists for the whole scaffolding window (a hard SIGKILL mid-scaffold still leaves
# a usable .wrap-undo.sh). Post-scaffold reconciliation appends anything extra.
SCAFFOLD_TOPLEVEL=".git scripts governor .githooks queue .claude .worktrees validation package.json .gitignore CLAUDE.md learnings.md"

# ── Logging ──────────────────────────────────────────────────────────────────
log()  { printf '── %s\n' "$*" >&2; }
info() { printf '   %s\n' "$*" >&2; }
warn() { printf '!! %s\n' "$*" >&2; }
refuse() { printf 'REFUSE: %s\n' "$*" >&2; exit 3; }

# ── Args ─────────────────────────────────────────────────────────────────────
WORKSPACE_DIR=""
NAME=""
PM="npm"
ORG=""
REPOS_SPEC=""
MERGE_ALLOWLIST=""
WORKTREE_BASE=""
SCAFFOLD=""
TEMPLATES_DIR=""
KEEP_UNDO=0
DETECT=0
YES=0
# Confirm flags for the warn+confirm preflights.
CONFIRM_CLOUD=0
CONFIRM_NESTED=0
CONFIRM_SYMLINKS=0
CONFIRM_LIVE_WRITER=0
CONFIRM_MAINTENANCE=0

usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --workspace-dir)     WORKSPACE_DIR="$2"; shift 2 ;;
    --name)              NAME="$2"; shift 2 ;;
    --pm)                PM="$2"; shift 2 ;;
    --org)               ORG="$2"; shift 2 ;;
    --repos)             REPOS_SPEC="$2"; shift 2 ;;
    --merge-allowlist)   MERGE_ALLOWLIST="$2"; shift 2 ;;
    --worktree-base)     WORKTREE_BASE="$2"; shift 2 ;;
    --scaffold)          SCAFFOLD="$2"; shift 2 ;;
    --templates)         TEMPLATES_DIR="$2"; shift 2 ;;
    --keep-undo)         KEEP_UNDO=1; shift ;;
    --detect)            DETECT=1; shift ;;
    --yes|-y)            YES=1; shift ;;
    --confirm-cloud-sync)   CONFIRM_CLOUD=1; shift ;;
    --confirm-nested)       CONFIRM_NESTED=1; shift ;;
    --confirm-symlinks)     CONFIRM_SYMLINKS=1; shift ;;
    --confirm-live-writer)  CONFIRM_LIVE_WRITER=1; shift ;;
    --confirm-maintenance)  CONFIRM_MAINTENANCE=1; shift ;;
    -h|--help)           usage ;;
    *) printf 'wrap.sh: unknown arg: %s\n' "$1" >&2; exit 2 ;;
  esac
done

# Resolve workspace dir (the repo root to wrap). pwd -P (physical path) so it matches
# git's `rev-parse --show-toplevel`, which resolves symlinks (e.g. macOS /var ->
# /private/var). A logical-path mismatch would false-trip the "not at repo root" refusal.
[ -n "$WORKSPACE_DIR" ] || WORKSPACE_DIR="$(pwd)"
WORKSPACE_DIR="$(cd "$WORKSPACE_DIR" 2>/dev/null && pwd -P)" || { printf 'wrap.sh: bad --workspace-dir\n' >&2; exit 2; }
cd "$WORKSPACE_DIR" || { printf 'wrap.sh: cannot cd into workspace dir\n' >&2; exit 2; }

# ── Mode detection (the setup-entry six-row table) ───────────────────────────
# Single tested source of truth for what /shiploop:setup should do in this folder.
# Prints exactly one token; setup.md branches on it.
#   upgrade           already a shiploop workspace (scripts/lib/workspace.sh present)
#   wrap              at the ROOT of a git repo whose .git is a DIRECTORY  → offer wrap-in-place
#   fresh             not inside any git repo                              → existing fresh scaffold
#   refuse:gitfile    .git is a FILE (linked worktree / submodule)         → refuse
#   refuse:bare       bare repository                                       → refuse
#   refuse:below-root inside a git repo but below its root                 → refuse (cd to root)
detect_mode() {
  if [ -f scripts/lib/workspace.sh ]; then echo upgrade; return; fi
  if [ -f .git ]; then echo refuse:gitfile; return; fi
  # Bare repo first: it has no working tree, so `--show-toplevel` is empty and would
  # otherwise look like "not a repo" (fresh).
  if [ "$(git rev-parse --is-bare-repository 2>/dev/null || true)" = "true" ]; then echo refuse:bare; return; fi
  local toplevel; toplevel="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -z "$toplevel" ]; then echo fresh; return; fi
  if [ -d .git ] && [ "$toplevel" = "$WORKSPACE_DIR" ]; then echo wrap; return; fi
  echo refuse:below-root
}

if [ "$DETECT" -eq 1 ]; then
  detect_mode
  exit 0
fi

[ -n "$NAME" ] || { printf 'wrap.sh: --name <subfolder> is required\n' >&2; exit 2; }
[ -n "$ORG" ] || { printf 'wrap.sh: --org is required (forwarded to scaffold)\n' >&2; exit 2; }
[ -n "$REPOS_SPEC" ] || { printf 'wrap.sh: --repos is required (forwarded to scaffold)\n' >&2; exit 2; }

# Resolve scaffold.sh + templates (defaults relative to this script: templates/lib/wrap.sh).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -n "$SCAFFOLD" ] || SCAFFOLD="$SCRIPT_DIR/../../scaffold.sh"
[ -f "$SCAFFOLD" ] || { printf 'wrap.sh: scaffold.sh not found (pass --scaffold): %s\n' "$SCAFFOLD" >&2; exit 2; }
[ -z "$TEMPLATES_DIR" ] && [ -d "$SCRIPT_DIR/.." ] && TEMPLATES_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Transform state (read by the rollback trap) ─────────────────────────────
PHASE="preflight"
STAGING=""
FAIL_REASON=""

# ── Rollback machinery ───────────────────────────────────────────────────────
# Move every top-level entry of $1 back into the workspace root (cwd). NUL-safe,
# handles dotfiles and names with spaces. No subshell (process substitution) so a
# failing mv is visible to the caller.
_restore_from_dir() {
  local src="$1" e
  local -a es=()
  [ -d "$src" ] || return 0
  while IFS= read -r -d '' e; do es+=("$e"); done < <(find "$src" -maxdepth 1 -mindepth 1 -print0)
  for e in "${es[@]:-}"; do
    [ -n "$e" ] || continue
    mv -- "$e" ./ 2>/dev/null || warn "rollback: could not move $e back"
  done
}

# Delete scaffold outputs left at root (everything EXCEPT the wrapped subfolder and
# the wrap artifacts). Used by the scaffolding-phase rollback, where the manifest
# may not be finalized yet — so it works purely from the invariant "after a good
# move, the only legit non-scaffold root entry is <name>".
_delete_scaffold_outputs() {
  local e b
  local -a es=()
  while IFS= read -r -d '' e; do es+=("$e"); done < <(find . -maxdepth 1 -mindepth 1 -print0)
  for e in "${es[@]:-}"; do
    [ -n "$e" ] || continue
    b="$(basename "$e")"
    case "$b" in
      "$NAME"|"$UNDO_FILE"|"$MANIFEST_FILE"|.wrap-staging.*) continue ;;
    esac
    rm -rf -- "$e" 2>/dev/null || warn "rollback: could not remove $e"
  done
}

rollback_and_exit() {
  local ec="${1:-1}"
  trap - INT TERM ERR EXIT   # disarm — never recurse
  case "$PHASE" in
    preflight|done)
      : ;;   # nothing moved (preflight) or already succeeded+cleaned (done)
    moving|pre-rename)
      # entries are (partly) in staging; move them back, drop staging
      _restore_from_dir "$STAGING"
      rmdir "$STAGING" 2>/dev/null || true
      ;;
    renamed)
      # staging was renamed to <name>; move its entries back, drop <name>
      _restore_from_dir "$NAME"
      rmdir "$NAME" 2>/dev/null || true
      ;;
    scaffolding)
      # scaffold (partly) ran; delete its outputs, then move <name> back
      _delete_scaffold_outputs
      _restore_from_dir "$NAME"
      rmdir "$NAME" 2>/dev/null || true
      ;;
  esac
  # Drop the (now-stale) manifest: post-rollback the paths it lists (.git,
  # package.json, CLAUDE.md, …) name the RESTORED ORIGINAL repo, not scaffold
  # output — so a subsequent run of the retained .wrap-undo.sh must NOT act on
  # them. With the manifest gone the retained undo script is a safe no-op, while
  # still satisfying the contract that .wrap-undo.sh stays on failure.
  rm -f "$MANIFEST_FILE" 2>/dev/null || true
  warn "wrap FAILED (phase=$PHASE): ${FAIL_REASON:-unknown} — original layout restored."
  [ -f "$UNDO_FILE" ] && warn "manual undo still available (safe no-op after this rollback): $WORKSPACE_DIR/$UNDO_FILE"
  exit "$ec"
}

abort()     { FAIL_REASON="$1"; rollback_and_exit 1; }
on_signal() { FAIL_REASON="interrupted by signal"; rollback_and_exit 1; }

# ── Preflight helpers ────────────────────────────────────────────────────────
# Warn+confirm findings accumulate here; if any remain unconfirmed we exit 5 with
# all of them listed so setup.md can ask once and re-invoke with the flags.
NEEDS_CONFIRM=()

# Detect a case-insensitive filesystem at the workspace root (APFS/HFS+ default).
fs_is_case_insensitive() {
  local probe=".wrap_case_probe.$$"
  rm -f "$probe" "$(printf '%s' "$probe" | tr 'a-z' 'A-Z')" 2>/dev/null
  : > "$probe" 2>/dev/null || { return 1; }
  local hit=1
  # If creating lowercase makes the UPPERCASE name resolve, the FS is case-insensitive.
  [ -e "$(printf '%s' "$probe" | tr 'a-z' 'A-Z')" ] && hit=0
  rm -f "$probe" 2>/dev/null
  return "$hit"
}

# Read a [core] key from a RAW git config file without invoking git on the repo.
# Critical: an absolute core.worktree that points at a missing path makes EVERY
# `git ...` invocation from inside the repo fail ("fatal: Invalid path") — even
# `git config --file` (git still does repository discovery first). So the only way
# to see a poisoning core.worktree is to parse the ini ourselves. Section-aware:
# `[core]`, `[remote "x"]`, etc. Prints the value (empty if unset).
raw_core_key() { # <config-file> <key>
  [ -f "$1" ] || return 0
  awk -v key="$(printf '%s' "$2" | tr 'A-Z' 'a-z')" '
    function trim(s){ sub(/^[ \t]+/,"",s); sub(/[ \t]+$/,"",s); return s }
    /^[ \t]*\[/ { s=$0; sub(/^[ \t]*\[[ \t]*/,"",s); sub(/[ \t"\]].*$/,"",s); section=tolower(s); next }
    {
      if (section=="core") {
        low=tolower($0)
        if (low ~ "^[ \t]*" key "[ \t]*=") { v=$0; sub(/^[ \t]*[^=]*=[ \t]*/,"",v); print trim(v); exit }
      }
    }
  ' "$1"
}

# Resolve a symlink target to an absolute path (best-effort, portable). Prints the
# resolved absolute path of the target's directory + basename, or empty on failure.
resolve_symlink_abs() {
  local link="$1" tgt dir base
  tgt="$(readlink "$link" 2>/dev/null)" || return 1
  case "$tgt" in
    /*) printf '%s' "$tgt"; return 0 ;;
  esac
  dir="$(dirname "$link")"
  base="$(basename "$tgt")"
  local tdir="$dir/$(dirname "$tgt")"
  local resolved
  resolved="$(cd "$tdir" 2>/dev/null && pwd)" || return 1
  printf '%s/%s' "$resolved" "$base"
}

preflight() {
  log "wrap preflight (all fail-closed) — $WORKSPACE_DIR"

  # 3 (early) — .git must be a DIRECTORY. A .git FILE is a linked worktree /
  # submodule checkout; wrapping it corrupts the main repo's back-pointers.
  if [ -f .git ]; then
    local mainrepo
    mainrepo="$(sed -n 's/^gitdir: //p' .git 2>/dev/null | head -1)"
    refuse ".git is a FILE (linked worktree or submodule checkout) — wrapping it would corrupt the main repo. Main repo gitdir: ${mainrepo:-<unreadable>}. Out of scope for v1."
  fi
  [ -d .git ] || refuse "no .git directory here — not at the root of a git repo. cd to the repo root and re-run."

  # 5 (moved EARLY — must run before any git command) — absolute-path git config
  # that a relocation would strand. Read RAW: a bad core.worktree poisons every
  # `git ...` from inside the repo, so a git-based read would silently miss it.
  local cw ch
  cw="$(raw_core_key .git/config worktree)"
  if [ -n "$cw" ]; then
    refuse "local git config sets core.worktree ($cw) — relocating would strand it. Remove it (git config --local --unset core.worktree) or wrap manually. v1 does not auto-repair."
  fi
  ch="$(raw_core_key .git/config hooksPath)"
  case "$ch" in
    /*) refuse "local git config sets an ABSOLUTE core.hooksPath ($ch) — relocating would strand it. Make it relative or unset it first." ;;
  esac
  # includeIf gitdir with an absolute path in local config
  if [ -f .git/config ] && grep -Eiq '^[[:space:]]*\[includeif "gitdir:/' .git/config 2>/dev/null; then
    refuse "local git config has an [includeIf \"gitdir:/abs...\"] section — an absolute gitdir condition breaks on relocation. Remove/relativize it first."
  fi
  # submodule configs — absolute worktree/hooksPath only (a submodule ALWAYS has a
  # RELATIVE core.worktree pointing back at its checkout; that is normal and moves fine).
  if [ -d .git/modules ]; then
    local smc smw smh
    while IFS= read -r smc; do
      [ -n "$smc" ] || continue
      smw="$(raw_core_key "$smc" worktree)"
      case "$smw" in /*) refuse "submodule config $smc sets an ABSOLUTE core.worktree ($smw) — relocation would strand it. v1 refuses; resolve it first." ;; esac
      smh="$(raw_core_key "$smc" hooksPath)"
      case "$smh" in /*) refuse "submodule config $smc sets an absolute core.hooksPath ($smh) — resolve it first." ;; esac
    done < <(find .git/modules -name config -type f 2>/dev/null)
  fi

  # bare repo — nothing to wrap
  if [ "$(git rev-parse --is-bare-repository 2>/dev/null)" = "true" ]; then
    refuse "this is a bare repository — nothing to wrap."
  fi

  # must be AT the repo root (not below it)
  local toplevel
  toplevel="$(git rev-parse --show-toplevel 2>/dev/null)"
  if [ -n "$toplevel" ] && [ "$toplevel" != "$WORKSPACE_DIR" ]; then
    refuse "not at the repo root — cd to the repo root ($toplevel) and re-run."
  fi

  # 1 — clean tracked state (untracked files are allowed; they move with the folder)
  local dirty_tracked
  dirty_tracked="$(git status --porcelain 2>/dev/null | grep -v '^??' || true)"
  if [ -n "$dirty_tracked" ]; then
    refuse "working tree has uncommitted tracked changes (or an unmerged path). Commit or stash first:"$'\n'"$dirty_tracked"
  fi

  # 2 — no in-progress git operation
  local gd; gd="$(git rev-parse --git-dir 2>/dev/null)"; gd="${gd:-.git}"
  if [ -e "$gd/MERGE_HEAD" ] || [ -d "$gd/rebase-merge" ] || [ -d "$gd/rebase-apply" ] \
     || [ -e "$gd/CHERRY_PICK_HEAD" ] || [ -e "$gd/REVERT_HEAD" ] || [ -e "$gd/BISECT_LOG" ]; then
    refuse "a git operation is in progress (merge/rebase/cherry-pick/revert/bisect) — finish or abort it first."
  fi

  # 4 — no linked worktrees
  local wt_count
  wt_count="$(git worktree list 2>/dev/null | wc -l | tr -d ' ')"
  if [ "${wt_count:-1}" -gt 1 ]; then
    refuse "this repo has linked worktrees ($wt_count total). Remove them (git worktree remove ...) before wrapping — v1 does not auto-repair worktree gitdir pointers."
  fi

  # git maintenance register (global config carries the absolute path) — warn hard
  if git config --global --get-regexp '^maintenance\.repo$' 2>/dev/null | grep -Fq "$WORKSPACE_DIR"; then
    if [ "$CONFIRM_MAINTENANCE" -eq 0 ]; then
      NEEDS_CONFIRM+=("--confirm-maintenance|git maintenance is registered for this repo (global config holds the OLD absolute path $WORKSPACE_DIR). After wrapping, re-register: git maintenance unregister (old) then git -C $WORKSPACE_DIR/$NAME maintenance register.")
    fi
  fi

  # 6 — escaping relative symlinks at root
  local esc="" l abs
  local -a links=()
  while IFS= read -r -d '' l; do links+=("$l"); done < <(find . -maxdepth 1 -mindepth 1 -type l -print0 2>/dev/null)
  for l in "${links[@]:-}"; do
    [ -n "$l" ] || continue
    abs="$(resolve_symlink_abs "$l")" || continue
    case "$abs/" in
      "$WORKSPACE_DIR"/*) : ;;                 # target stays inside the folder — fine
      *) esc="$esc  $l -> $(readlink "$l")"$'\n' ;;
    esac
  done
  if [ -n "$esc" ]; then
    if [ "$CONFIRM_SYMLINKS" -eq 0 ]; then
      NEEDS_CONFIRM+=("--confirm-symlinks|root symlinks point OUTSIDE the folder; their relative targets will silently retarget one level deeper after wrapping:"$'\n'"$esc")
    fi
  fi

  # 7 — single filesystem (cross-device child turns rename into copy+delete)
  local root_dev e edev
  root_dev="$(stat -f '%d' . 2>/dev/null || stat -c '%d' . 2>/dev/null || echo '')"
  if [ -n "$root_dev" ]; then
    local -a entries=()
    while IFS= read -r -d '' e; do entries+=("$e"); done < <(find . -maxdepth 1 -mindepth 1 -print0)
    for e in "${entries[@]:-}"; do
      [ -n "$e" ] || continue
      case "$(basename "$e")" in "$UNDO_FILE"|"$MANIFEST_FILE"|.wrap-staging.*) continue ;; esac
      edev="$(stat -f '%d' "$e" 2>/dev/null || stat -c '%d' "$e" 2>/dev/null || echo "$root_dev")"
      if [ "$edev" != "$root_dev" ]; then
        refuse "$e is on a DIFFERENT filesystem than the workspace root — the move would become a copy+delete (slow, non-atomic, and risks a partial .git). Resolve the cross-device mount before wrapping."
      fi
    done
  fi
  # cloud-sync path match — warn hard + confirm
  case "$WORKSPACE_DIR" in
    *"/Mobile Documents/"*|*"/Dropbox/"*|*"/Google Drive"*|*"/OneDrive"*|*"/Library/CloudStorage/"*)
      if [ "$CONFIRM_CLOUD" -eq 0 ]; then
        NEEDS_CONFIRM+=("--confirm-cloud-sync|this folder looks like a cloud-synced location ($WORKSPACE_DIR). A sync daemon can race the move and corrupt .git. Pause syncing first, then confirm.")
      fi ;;
  esac

  # 8 — nested inside another git working tree
  local anc="$WORKSPACE_DIR"
  while [ "$anc" != "/" ]; do
    anc="$(dirname "$anc")"
    if [ -e "$anc/.git" ]; then
      if [ "$CONFIRM_NESTED" -eq 0 ]; then
        NEEDS_CONFIRM+=("--confirm-nested|this repo is nested inside another git working tree at $anc — wrapping here creates a workspace inside that outer repo. Usually you want to wrap the OUTER repo instead. Confirm to proceed anyway.")
      fi
      break
    fi
  done

  # 10 — no pre-existing wrap artifacts (would be skipped by the move / clobbered by the undo write)
  if [ -e "$UNDO_FILE" ]; then refuse "$UNDO_FILE already exists — remove it first (a stale one would be clobbered)."; fi
  if [ -e "$MANIFEST_FILE" ]; then refuse "$MANIFEST_FILE already exists — remove it first."; fi
  if ls -d $STAGING_GLOB >/dev/null 2>&1; then refuse "a $STAGING_GLOB staging dir already exists — remove it first."; fi

  # 9 — subfolder name collision, case-insensitively
  local existing
  existing="$(find . -maxdepth 1 -mindepth 1 -iname "$NAME" 2>/dev/null | head -1)"
  if [ -n "$existing" ]; then
    local got; got="$(basename "$existing")"
    if [ "$got" != "$NAME" ]; then
      printf 'COLLISION: an entry named "%s" already exists — clashes with "%s" case-insensitively on this filesystem. Choose a different subfolder name.\n' "$got" "$NAME" >&2
    else
      printf 'COLLISION: an entry named "%s" already exists here — choose a different subfolder name.\n' "$NAME" >&2
    fi
    exit 4
  fi

  # 11 — live-writer warning (dev servers / IDE indexers recreate caches at the OLD root)
  if [ "$CONFIRM_LIVE_WRITER" -eq 0 ]; then
    NEEDS_CONFIRM+=("--confirm-live-writer|stop dev servers and heavy IDE indexers before wrapping — a live writer can recreate .next/-style caches at the OLD root and orphan files outside $NAME/.")
  fi

  # If any warn+confirm findings remain, list them and exit 5.
  if [ "${#NEEDS_CONFIRM[@]}" -gt 0 ]; then
    log "wrap needs confirmation before proceeding:"
    local nc
    for nc in "${NEEDS_CONFIRM[@]}"; do
      printf 'NEEDS-CONFIRM[%s]: %s\n' "${nc%%|*}" "${nc#*|}" >&2
    done
    exit 5
  fi

  # 12 — record verification baselines
  PRE_HEAD="$(git rev-parse HEAD 2>/dev/null || echo '')"
  PRE_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"
  PRE_STATUS="$(git status --porcelain 2>/dev/null || true)"
  PRE_SUBMODULES=""
  if [ -f .gitmodules ]; then
    PRE_SUBMODULES="$(git submodule status 2>/dev/null || true)"
  fi
  info "preflight OK — HEAD=${PRE_HEAD:-<none>} branch=${PRE_BRANCH:-<detached>}"
}

# ── The move ─────────────────────────────────────────────────────────────────
write_undo_script() {
  # Written BEFORE any move so a hard crash still leaves a usable undo. It reads
  # .wrap-manifest at RUN time (guarded — absent is fine) to delete scaffold
  # outputs, then moves <name>/ (or a leftover staging dir) contents back to root.
  cat > "$UNDO_FILE" <<UNDO
#!/usr/bin/env bash
# .wrap-undo.sh — reverse a shiploop wrap-in-place. Safe to run from the workspace
# root. Deletes ONLY the scaffold-created paths listed in .wrap-manifest (so files
# you added at the root after wrapping are spared), then moves your repo back to
# where it was and removes itself.
set -uo pipefail
cd "\$(dirname "\$0")" || exit 1
SUBDIR="$NAME"

restore_dir() {
  local d="\$1" e
  local -a es=()
  [ -d "\$d" ] || return 0
  while IFS= read -r -d '' e; do es+=("\$e"); done < <(find "\$d" -maxdepth 1 -mindepth 1 -print0)
  for e in "\${es[@]:-}"; do
    [ -n "\$e" ] || continue
    mv -- "\$e" ./ || echo "undo: could not move \$e back" >&2
  done
  rmdir "\$d" 2>/dev/null || true
}

# 1. delete scaffold-created paths (explicit manifest — never a blind wipe)
if [ -f .wrap-manifest ]; then
  while IFS= read -r p; do
    [ -n "\$p" ] || continue
    case "\$p" in "\$SUBDIR"|.wrap-undo.sh|.wrap-manifest) continue ;; esac
    rm -rf -- "\$p" 2>/dev/null || echo "undo: could not remove \$p" >&2
  done < .wrap-manifest
fi

# 2. move the wrapped repo (or a crashed-mid-move staging dir) back to root
restore_dir "\$SUBDIR"
for s in .wrap-staging.*; do [ -d "\$s" ] && restore_dir "\$s"; done

# 3. remove manifest + self
rm -f .wrap-manifest
rm -f -- "\$0"
echo "unwrapped: original layout restored."
UNDO
  chmod +x "$UNDO_FILE"
  log "wrote undo script: $WORKSPACE_DIR/$UNDO_FILE (run it to reverse the wrap before completion)"
}

do_move() {
  STAGING=".wrap-staging.$$"
  mkdir "$STAGING" || abort "could not create staging dir $STAGING"

  write_undo_script

  PHASE="moving"
  # Enumerate explicitly — never `mv * .*` (globs . and ..). Exclude our own artifacts.
  local -a entries=()
  local e
  while IFS= read -r -d '' e; do entries+=("$e"); done < <(
    find . -maxdepth 1 -mindepth 1 \
      ! -name "$STAGING" ! -name "$UNDO_FILE" ! -name "$MANIFEST_FILE" -print0
  )
  local moved=0
  for e in "${entries[@]:-}"; do
    [ -n "$e" ] || continue
    mv -- "$e" "$STAGING/" || abort "move failed for $e"
    moved=$((moved+1))
    if [ "${WRAP_TEST_FAIL_AT:-}" = "moving" ] && [ "$moved" -ge 1 ]; then
      abort "test-injected failure during moving"
    fi
  done
  info "moved $moved entr$([ "$moved" = 1 ] && echo y || echo ies) into staging"

  PHASE="pre-rename"
  [ "${WRAP_TEST_FAIL_AT:-}" = "pre-rename" ] && abort "test-injected failure before rename"
  if [ "${WRAP_TEST_HANG_BEFORE_RENAME:-0}" = "1" ]; then
    info "TEST: hanging before rename (awaiting signal)"
    sleep 10
  fi

  mv -- "$STAGING" "$NAME" || abort "could not rename staging to $NAME"
  PHASE="renamed"
  [ "${WRAP_TEST_FAIL_AT:-}" = "renamed" ] && abort "test-injected failure after rename"
}

verify_move() {
  log "verify move (HEAD / branch / status snapshot / submodules must be byte-identical)"
  local now_head now_branch now_status now_subm
  now_head="$(git -C "$NAME" rev-parse HEAD 2>/dev/null || echo '')"
  [ "$now_head" = "$PRE_HEAD" ] || abort "HEAD changed after move ($PRE_HEAD -> ${now_head:-<none>})"
  now_branch="$(git -C "$NAME" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"
  [ "$now_branch" = "$PRE_BRANCH" ] || abort "branch changed after move ($PRE_BRANCH -> ${now_branch:-<none>})"
  now_status="$(git -C "$NAME" status --porcelain 2>/dev/null || true)"
  [ "$now_status" = "$PRE_STATUS" ] || abort "git status not byte-identical after move (a stale worktree path or lost untracked file) — refusing."
  if [ -f "$NAME/.gitmodules" ]; then
    now_subm="$(git -C "$NAME" submodule status 2>/dev/null || true)"
    [ "$now_subm" = "$PRE_SUBMODULES" ] || abort "submodule status/SHAs changed after move — refusing."
  fi
  info "move verified — repo intact at $NAME/"
}

# ── Scaffold + manifest ──────────────────────────────────────────────────────
run_scaffold() {
  # Seed the manifest with the KNOWN scaffold top-level paths BEFORE scaffold runs,
  # so the undo script is usable even if scaffold is SIGKILLed mid-run.
  : > "$MANIFEST_FILE"
  local p
  for p in $SCAFFOLD_TOPLEVEL; do printf '%s\n' "$p" >> "$MANIFEST_FILE"; done

  PHASE="scaffolding"
  [ "${WRAP_TEST_FAIL_AT:-}" = "scaffolding" ] && abort "test-injected scaffold failure"

  log "scaffolding workspace root (wrapped repo pre-registered as $NAME)"
  local -a sc_args=(
    --workspace-dir "$WORKSPACE_DIR"
    --pm "$PM" --org "$ORG" --repos "$REPOS_SPEC"
    --merge-allowlist "$MERGE_ALLOWLIST"
    --git-init --verify --yes
  )
  [ -n "$WORKTREE_BASE" ] && sc_args+=(--worktree-base "$WORKTREE_BASE")
  [ -n "$TEMPLATES_DIR" ] && sc_args+=(--templates "$TEMPLATES_DIR")
  bash "$SCAFFOLD" "${sc_args[@]}" || abort "scaffold.sh failed — rolling back"

  # Reconcile: append any top-level scaffold output not already predicted.
  local e b
  local -a es=()
  while IFS= read -r -d '' e; do es+=("$e"); done < <(find . -maxdepth 1 -mindepth 1 -print0)
  for e in "${es[@]:-}"; do
    [ -n "$e" ] || continue
    b="$(basename "$e")"
    case "$b" in "$NAME"|"$UNDO_FILE"|"$MANIFEST_FILE"|.wrap-staging.*) continue ;; esac
    grep -Fxq "$b" "$MANIFEST_FILE" 2>/dev/null || printf '%s\n' "$b" >> "$MANIFEST_FILE"
  done

  # Seam: fail AFTER scaffold has created real files, to exercise the trap's
  # scaffold-output cleanup (_delete_scaffold_outputs) against actual output.
  [ "${WRAP_TEST_FAIL_AT:-}" = "post-scaffold" ] && abort "test-injected post-scaffold failure"
}

verify_final() {
  log "final end-to-end verify"
  # Wrapped repo still intact at its new home.
  local now_head
  now_head="$(git -C "$NAME" rev-parse HEAD 2>/dev/null || echo '')"
  [ "$now_head" = "$PRE_HEAD" ] || abort "wrapped repo HEAD drifted after scaffold"
  # Workspace root scaffolded: config + git init present.
  [ -f scripts/lib/workspace.sh ] || abort "scaffold did not produce scripts/lib/workspace.sh"
  [ -d .git ] || abort "scaffold did not initialize the workspace root git repo"
  # The wrapped subfolder must be gitignored at the root (not swept into the root commit).
  if ! git check-ignore -q "$NAME" 2>/dev/null; then
    abort "wrapped subfolder $NAME/ is NOT gitignored at the root — refusing (it would be committed into the workspace repo)."
  fi
  info "final verify OK — workspace root scaffolded, $NAME/ intact and gitignored"
}

# ── Main ─────────────────────────────────────────────────────────────────────
trap on_signal INT TERM

preflight

log "wrapping $WORKSPACE_DIR — repo will move into $NAME/"
do_move
verify_move
run_scaffold
verify_final

# Success: retire the undo lifeline (unless asked to keep it).
PHASE="done"
trap - INT TERM ERR EXIT
if [ "$KEEP_UNDO" -eq 1 ]; then
  info "wrap verified — keeping undo script at $WORKSPACE_DIR/$UNDO_FILE (--keep-undo)"
else
  log "wrap verified — removing undo script"
  rm -f "$UNDO_FILE" "$MANIFEST_FILE"
fi

log "wrap-in-place complete: $WORKSPACE_DIR/  (repo now at $NAME/)"
exit 0
