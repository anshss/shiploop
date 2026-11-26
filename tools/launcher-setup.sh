#!/usr/bin/env bash
# launcher-setup.sh: install the wiring that lets Claude Code run on a model family.
#
# Usage:  tools/launcher-setup.sh <family>
#         HOME=<dir> SHELL_RC=<file> GOVERN_MODEL_PROFILE_DIR=<dir> tools/launcher-setup.sh <family>
#
# A fresh machine gets the profiles but nothing that consumes them: the settings file and the
# shell function that make a family work in Claude Code had to be written by hand. This writes
# both from the profile, so the same family is wired the same way on any machine. It writes three
# things and nothing else:
#
#   ~/.claude/settings-<family>.json      regenerated on every run, byte for byte the same for
#                                          the same profile: a modelPicker row per PICKER id, and
#                                          an autoCompactWindow per bare id when WINDOW is set
#   ~/.shiploop/launchers/<family>.conf   created only when absent, mode 600: the two values only
#                                          this machine knows (BASE_URL, AUTH_TOKEN) as placeholders.
#                                          Never read here, never printed, never overwritten
#   $SHELL_RC (default ~/.zshrc)          one marked block defining <family>(), added or replaced
#                                          in place. Nothing outside the markers is read or written
#
# The endpoint and the token live in the conf because they are secrets; the launcher reads that
# file at launch and refuses to start while either value is still a placeholder.
#
# Before anything is written the whole run is validated: an unknown family, a malformed profile,
# or an rc whose marked block cannot be found unambiguously (exactly one opening and one closing
# marker, in that order) leaves every file untouched. Exit 0 installed, 1 refused, 2 usage.
#
# Reads from the hub checkout this script sits in: templates/lib/model-profiles/<family>.conf
# (or GOVERN_MODEL_PROFILE_DIR when set), and the checkout's own path, embedded in the block as
# the --plugin-dir the launcher passes. Re-run after moving the checkout.
set -euo pipefail

usage() {
  cat <<'USAGE'
usage: tools/launcher-setup.sh <family>

  <family>            a model profile name: templates/lib/model-profiles/<family>.conf

environment:
  HOME                   where ~/.claude and ~/.shiploop are written (default: the real home)
  SHELL_RC               the rc file that gets the launcher block (default: $HOME/.zshrc)
  GOVERN_MODEL_PROFILE_DIR
                         read profiles from this directory instead of the hub's
USAGE
}

fail() { echo "launcher-setup: $*" >&2; exit 1; }
say() { echo "launcher-setup: $*"; }

[ "$#" -eq 1 ] || { usage >&2; exit 2; }
case "$1" in -h|--help) usage; exit 0 ;; esac
family="$1"

# The family becomes a shell function name and a file name, so it is a plain lowercase word.
case "$family" in
  [a-z]*) ;;
  *) fail "family '$family' must start with a lowercase letter" ;;
esac
case "$family" in
  *[!a-z0-9_]*|"") fail "family '$family' may hold only lowercase letters, digits and underscores" ;;
esac

HUB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
[ -f "$HUB/.claude-plugin/plugin.json" ] || fail "$HUB is not a shiploop hub checkout (no .claude-plugin/plugin.json); run this from the hub's tools/ directory"

PROFILE_DIR="${GOVERN_MODEL_PROFILE_DIR:-$HUB/templates/lib/model-profiles}"
PROFILE="$PROFILE_DIR/$family.conf"
[ -f "$PROFILE" ] || fail "no profile for family '$family' at $PROFILE"

: "${HOME:?HOME is not set}"
[ -d "$HOME" ] || fail "HOME ($HOME) is not a directory"
SHELL_RC="${SHELL_RC:-$HOME/.zshrc}"

OPEN="# >>> shiploop launcher ($family) >>>"
CLOSE="# <<< shiploop launcher ($family) <<<"

# ── the profile ──────────────────────────────────────────────────────────────
# KEY=value lines, double quotes stripped, the same reading the govern scripts and the
# model-router mod apply. A key that is absent reads as the empty string.
profile_get() { # <KEY> -> value, "" when the key is absent
  awk -v k="$1" '
    $0 ~ "^[ \t]*" k "[ \t]*=" {
      v = $0; sub(/^[^=]*=[ \t]*/, "", v); sub(/[ \t]*$/, "", v)
      if (v ~ /^".*"$/) v = substr(v, 2, length(v) - 2)
      print v; exit
    }' "$PROFILE"
}

# An id is a model name with an optional [..] context suffix. Anything outside this shape would
# need JSON escaping, which the generated file deliberately does not do.
ID_RE='^[A-Za-z0-9]+(-[A-Za-z0-9.]+)*(\[[A-Za-z0-9]+\])?$'
check_id() { # <value> <what>
  [[ "$1" =~ $ID_RE ]] || fail "$2 in $PROFILE is not a plain model id: '$1'"
}

[ "$(profile_get FAMILY)" = "$family" ] || fail "the profile at $PROFILE is not the '$family' family (its FAMILY line says '$(profile_get FAMILY)')"

window="$(profile_get WINDOW)"
# No leading zeros: the number is written into the settings file and a shell export as it stands.
case "$window" in
  '') ;;
  0*|*[!0-9]*) fail "WINDOW in $PROFILE must be a whole number of tokens greater than zero: '$window'" ;;
esac

# The three slot aliases the launcher pins. A profile without these roles cannot drive a session.
slot_opus="$(profile_get ROLE_advisor)"
slot_sonnet="$(profile_get ROLE_investigator)"
slot_haiku="$(profile_get ROLE_worker)"
[ -n "$slot_opus" ] || fail "ROLE_advisor is missing from $PROFILE"
[ -n "$slot_sonnet" ] || fail "ROLE_investigator is missing from $PROFILE"
[ -n "$slot_haiku" ] || fail "ROLE_worker is missing from $PROFILE"
check_id "$slot_opus" "ROLE_advisor"
check_id "$slot_sonnet" "ROLE_investigator"
check_id "$slot_haiku" "ROLE_worker"

picker="$(profile_get PICKER)"
[ -n "$picker" ] || fail "PICKER is missing from $PROFILE"
n_picker=0
oldifs="$IFS"
IFS='|'
set -f
for id in $picker; do
  check_id "$id" "a PICKER entry"
  n_picker=$((n_picker + 1))
done
set +f
IFS="$oldifs"
[ "$n_picker" -gt 0 ] || fail "PICKER in $PROFILE holds no ids"

work="$(mktemp -d "${TMPDIR:-/tmp}/launcher-setup.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# ── the settings file ────────────────────────────────────────────────────────
# The /model lineup, one row per PICKER id, and the compaction window per bare id. The label is
# derived from the id: the bracketed suffix dropped, the first word uppercased, digit runs joined
# with dots, every later word title-cased (glm-5.3-flash[1m] is "GLM 5.3 Flash"). The description
# names the highest role on TIER_ORDER that runs the id ("Advisor tier"); an id no role runs says
# so. With WINDOW set the description ends in the window ("Advisor tier, 1M context") and every
# bare id gets an autoCompactWindow: the CLI matches a [1m] spelling of an id to its bare entry.
render_settings() { # <profile> -> JSON on stdout
  awk '
    function bareof(s) { sub(/\[[^]]*\]$/, "", s); return s }
    function titlecase(s) { return toupper(substr(s, 1, 1)) tolower(substr(s, 2)) }
    function label(id,    t, parts, n, i, tok, out, digits, sep) {
      t = bareof(id)
      n = split(t, parts, "-")
      out = ""; digits = ""; sep = ""
      for (i = 1; i <= n; i++) {
        tok = parts[i]
        if (tok ~ /^[0-9]+([.][0-9]+)*$/) { digits = digits (digits == "" ? "" : ".") tok; continue }
        if (digits != "") { out = out sep digits; sep = " "; digits = "" }
        out = out sep (out == "" ? toupper(tok) : titlecase(tok))
        sep = " "
      }
      if (digits != "") out = out sep digits
      return out
    }
    function roletitle(r,    parts, n, i, out) {
      n = split(r, parts, "_")
      out = ""
      for (i = 1; i <= n; i++) out = out (i > 1 ? " " : "") toupper(substr(parts[i], 1, 1)) substr(parts[i], 2)
      return out
    }
    function describe(id,    i, r, m) {
      for (i = 1; i <= ntiers; i++) {
        r = tier[i]; m = rolemodel[r]
        if (m != "" && bareof(m) == id) return roletitle(r) " tier"
      }
      return "No shiploop role"
    }
    function human(w) {
      if (w % 1000000 == 0) return (w / 1000000) "M"
      if (w % 1000 == 0) return (w / 1000) "K"
      return w
    }
    /^[ \t]*#/ { next }
    /^[ \t]*[A-Za-z_][A-Za-z0-9_]*[ \t]*=/ {
      line = $0
      key = line; sub(/^[ \t]*/, "", key); sub(/[ \t]*=.*$/, "", key)
      val = line; sub(/^[^=]*=[ \t]*/, "", val); sub(/[ \t]*$/, "", val)
      if (val ~ /^".*"$/) val = substr(val, 2, length(val) - 2)
      if (key == "PICKER") picker = val
      else if (key == "WINDOW") window = val
      else if (key == "TIER_ORDER") tierorder = val
      else if (key ~ /^ROLE_/) rolemodel[substr(key, 6)] = val
      next
    }
    END {
      n = split(picker, ids, "|")
      ntiers = split(tierorder, tier, " ")
      print "{"
      print "  \"modelPicker\": {"
      print "    \"replaceBuiltInOptions\": true,"
      print "    \"options\": ["
      for (i = 1; i <= n; i++) {
        desc = describe(bareof(ids[i]))
        if (window != "") desc = desc ", " human(window) " context"
        printf "      { \"model\": \"%s\", \"label\": \"%s\", \"description\": \"%s\" }%s\n", ids[i], label(ids[i]), desc, (i < n ? "," : "")
      }
      print "    ]"
      print (window != "" ? "  }," : "  }")
      if (window != "") {
        # One entry per bare id; a repeated bare id (with and without a suffix) is written once.
        last = 0
        for (i = 1; i <= n; i++) {
          b = bareof(ids[i])
          if (b in seen) continue
          seen[b] = 1
          last = i
        }
        print "  \"modelSettings\": {"
        for (i = 1; i <= n; i++) {
          b = bareof(ids[i])
          if (b in written) continue
          written[b] = 1
          printf "    \"%s\": { \"autoCompactWindow\": %s }%s\n", b, window, (i < last ? "," : "")
        }
        print "  }"
      }
      print "}"
    }' "$1"
}
render_settings "$PROFILE" > "$work/settings.json"

# ── the launcher block ───────────────────────────────────────────────────────
# A subshell, so the endpoint, the token and the aliases never reach the interactive shell.
# Without WINDOW the CLI meters its own model names and the two context exports are left out.
# A family called "claude" names the very binary the function calls, so that one goes through
# `command` to reach the binary instead of itself.
launch="claude"
[ "$family" = "claude" ] && launch="command claude"

{
  cat <<BLOCK
$OPEN
# Written by shiploop's tools/launcher-setup.sh; re-run it to regenerate this block.
# Starts Claude Code on the $family family. Edits here are lost on the next run.
$family() {
  (
    conf="\$HOME/.shiploop/launchers/$family.conf"
    if [ ! -r "\$conf" ]; then
      echo "shiploop launcher ($family): cannot read \$conf; run tools/launcher-setup.sh $family" >&2
      return 1
    fi
    . "\$conf"
    case "\$BASE_URL" in ''|REPLACE_WITH_*)
      echo "shiploop launcher ($family): BASE_URL in \$conf is still a placeholder; fill it in and retry" >&2
      return 1 ;;
    esac
    case "\$AUTH_TOKEN" in ''|REPLACE_WITH_*)
      echo "shiploop launcher ($family): AUTH_TOKEN in \$conf is still a placeholder; fill it in and retry" >&2
      return 1 ;;
    esac
    export ANTHROPIC_BASE_URL="\$BASE_URL"
    export ANTHROPIC_AUTH_TOKEN="\$AUTH_TOKEN"
    export API_TIMEOUT_MS="\${API_TIMEOUT_MS:-3000000}"
BLOCK
  if [ -n "$window" ]; then
    cat <<BLOCK
    # The CLI meters an id it does not know against 200k; these two pin the window the family serves.
    export CLAUDE_CODE_MAX_CONTEXT_TOKENS="$window"
    export CLAUDE_CODE_AUTO_COMPACT_WINDOW="$window"
BLOCK
  fi
  cat <<BLOCK
    # Slot aliases: opus is the advisor's model, sonnet the investigator's, haiku the worker's.
    export ANTHROPIC_DEFAULT_OPUS_MODEL="$slot_opus"
    export ANTHROPIC_DEFAULT_SONNET_MODEL="$slot_sonnet"
    export ANTHROPIC_DEFAULT_HAIKU_MODEL="$slot_haiku"
    # Lets the plugin's model-router mod map shiploop spawns to this family's models.
    export SHIPLOOP_MODEL_PROFILE="$family"
    $launch --settings "\$HOME/.claude/settings-$family.json" --plugin-dir "$HUB" "\$@"
  )
}
$CLOSE
BLOCK
} > "$work/block.sh"

# ── the rc file: locate the block and stage the new content ─────────────────
# Nothing is written until every check below has passed. The splice keeps every byte outside the
# markers, including a missing newline on the last line.
ends_nl=0
if [ ! -e "$SHELL_RC" ] && [ ! -L "$SHELL_RC" ]; then
  rc_state=create
  cp "$work/block.sh" "$work/rc.new"
else
  [ -f "$SHELL_RC" ] || fail "$SHELL_RC exists and is not a regular file; set SHELL_RC to the rc file to edit"
  [ -r "$SHELL_RC" ] || fail "$SHELL_RC is not readable"
  n_open="$(grep -cxF "$OPEN" "$SHELL_RC" || true)"
  n_close="$(grep -cxF "$CLOSE" "$SHELL_RC" || true)"
  if [ "$n_open" -eq 0 ] && [ "$n_close" -eq 0 ]; then
    rc_state=append
    cp "$SHELL_RC" "$work/rc.new"
    # A block must start on its own line; add the newline the file may be missing.
    if [ -s "$work/rc.new" ] && [ -n "$(tail -c1 "$work/rc.new")" ]; then printf '\n' >> "$work/rc.new"; fi
    cat "$work/block.sh" >> "$work/rc.new"
  elif [ "$n_open" -eq 1 ] && [ "$n_close" -eq 1 ]; then
    l_open="$(grep -nxF "$OPEN" "$SHELL_RC" | cut -d: -f1)"
    l_close="$(grep -nxF "$CLOSE" "$SHELL_RC" | cut -d: -f1)"
    [ "$l_open" -lt "$l_close" ] || fail "$SHELL_RC has the shiploop launcher ($family) markers in the wrong order (line $l_open opens, line $l_close closes); fix them by hand, nothing was written"
    rc_state=replace
    # The file is passed twice: the first pass is skipped (FNR == NR), the second emits every
    # record with the block in place of the old one, joined by the newlines the original carried.
    [ -z "$(tail -c1 "$SHELL_RC")" ] && ends_nl=1
    awk -v mopen="$OPEN" -v mclose="$CLOSE" -v blockfile="$work/block.sh" -v ends_nl="$ends_nl" '
      BEGIN {
        while ((getline l < blockfile) > 0) blk = blk l "\n"
        sub(/\n$/, "", blk)
        first = 1
      }
      FNR == NR { next }
      {
        if ($0 == mopen) { skipping = 1; chunk = blk }
        else if ($0 == mclose) { skipping = 0; next }
        else if (skipping) next
        else chunk = $0
        out = (first ? chunk : out "\n" chunk)
        first = 0
      }
      END { if (ends_nl) out = out "\n"; printf "%s", out }
    ' "$SHELL_RC" "$SHELL_RC" > "$work/rc.new"
  else
    fail "$SHELL_RC holds $n_open opening and $n_close closing markers for the $family launcher; exactly one of each is needed to update the block. Nothing was written"
  fi
fi

# Everything outside the block, for the stray-definition warning.
outside="$(
  [ -e "$SHELL_RC" ] || exit 0
  awk -v mopen="$OPEN" -v mclose="$CLOSE" '$0 == mopen { skipping = 1; next } $0 == mclose { skipping = 0; next } !skipping' "$SHELL_RC"
)"

# ── write ────────────────────────────────────────────────────────────────────
mkdir -p "$HOME/.claude"
# Written through the path: an existing file (or a symlink to one, a dotfiles checkout say) keeps
# its inode, and a new file gets the umask's mode like any hand-written settings file.
settings="$HOME/.claude/settings-$family.json"
cat "$work/settings.json" > "$settings"
say "settings: $settings"

conf="$HOME/.shiploop/launchers/$family.conf"
if [ -e "$conf" ] || [ -L "$conf" ]; then
  say "conf:    $conf kept as it is (not read, not printed)"
else
  mkdir -p "$HOME/.shiploop/launchers"
  (umask 077; cat > "$conf" <<CONF
# Values only this machine knows, for the shiploop $family launcher. The $family() function in your
# shell rc reads this file at launch. Never commit or paste it anywhere.
BASE_URL="REPLACE_WITH_ENDPOINT_URL"
AUTH_TOKEN="REPLACE_WITH_API_TOKEN"
API_TIMEOUT_MS="3000000"
CONF
  )
  chmod 600 "$conf"
  say "conf:    $conf created with mode 600. Fill in BASE_URL and AUTH_TOKEN; $family refuses to launch until then"
fi

# Written through the path, never by renaming onto it: a symlinked rc keeps its inode and mode.
cat "$work/rc.new" > "$SHELL_RC"
case "$rc_state" in
  create)  say "rc:      $SHELL_RC created with the $family launcher block" ;;
  append)  say "rc:      $family launcher block added to $SHELL_RC" ;;
  replace) say "rc:      $family launcher block updated in $SHELL_RC" ;;
esac

# A hand-written launcher of the same name would win or lose by order of definition. Say so once.
stray="$(printf '%s\n' "$outside" | grep -nE "^[[:space:]]*(function[[:space:]]+)?$family[[:space:]]*\(\)" | cut -d: -f1 | head -1 || true)"
if [ -n "$stray" ]; then
  echo "launcher-setup: warning: $SHELL_RC line $stray also defines $family(); remove that definition, it shadows the block or is shadowed by it" >&2
fi

say "done: open a new shell (or source $SHELL_RC) and run: $family"
