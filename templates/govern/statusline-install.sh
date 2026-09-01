#!/usr/bin/env bash
# Install / remove the shiploop fleet statusline segment. Explicit and opt-in — NOTHING in
# scaffold.sh, /shiploop:setup or /shiploop:update ever calls this. The operator runs
# `/shiploop:statusline` (or this script) or it does not happen.
#
#   statusline-install.sh install     wrap the existing statusLine (recording it verbatim first)
#   statusline-install.sh uninstall   restore the recorded statusLine, byte for byte
#   statusline-install.sh status      report what is currently wired up
#
# THE ONE UNACCEPTABLE OUTCOME is clobbering a user's ccusage / custom HUD. So install records the
# ENTIRE previous `statusLine` object (not just its command) into a sidecar state file BEFORE it
# writes settings.json, refuses to re-record over an existing recording (a second install would
# record shiploop's own wrapper as "the original" and make restore impossible), and uninstall writes
# the recorded object straight back — including deleting the key entirely when there was none.
#
# Env overrides (tests set all three):
#   GOVERN_STATUSLINE_SETTINGS   default ~/.claude/settings.json
#   GOVERN_STATUSLINE_STATE      default ~/.claude/shiploop-statusline.json
#   GOVERN_STATUSLINE_REFRESH    default 5   (seconds; the line does not refresh while idle without it)
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SETTINGS="${GOVERN_STATUSLINE_SETTINGS:-$HOME/.claude/settings.json}"
STATE="${GOVERN_STATUSLINE_STATE:-$HOME/.claude/shiploop-statusline.json}"
REFRESH="${GOVERN_STATUSLINE_REFRESH:-5}"
CHAIN="$DIR/statusline-chain.sh"
SEGMENT="$DIR/statusline-segment.sh"
ACTION="${1:-status}"

die() { printf 'statusline: %s\n' "$*" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || die "jq is required to edit $SETTINGS safely"
[[ -f "$CHAIN"   ]] || die "missing $CHAIN"
[[ -f "$SEGMENT" ]] || die "missing $SEGMENT"

OUR_CMD="bash $CHAIN"

read_settings() { # -> the settings JSON, or {} when absent/empty
  if [[ -s "$SETTINGS" ]]; then cat "$SETTINGS"; else printf '{}'; fi
}

write_settings() { # <json> — atomic replace, never a partial file
  local json="$1" tmp
  printf '%s' "$json" | jq empty >/dev/null 2>&1 || die "refusing to write malformed settings JSON"
  mkdir -p "$(dirname "$SETTINGS")" 2>/dev/null || true
  tmp="$SETTINGS.shiploop.$$"
  printf '%s\n' "$json" > "$tmp" || die "could not write $tmp"
  mv -f "$tmp" "$SETTINGS" || die "could not replace $SETTINGS"
  return 0
}

installed() { # 0 when settings.json currently points at our wrapper
  local cur
  cur="$(read_settings | jq -r '.statusLine.command // ""' 2>/dev/null || printf '')"
  [[ "$cur" == *"statusline-chain.sh"* ]]
}

case "$ACTION" in
  install)
    cur_json="$(read_settings)"
    printf '%s' "$cur_json" | jq empty >/dev/null 2>&1 || die "$SETTINGS is not valid JSON — fix it first; refusing to touch it"

    if installed; then
      printf 'statusline: already installed (%s)\n' "$SETTINGS"
      exit 0
    fi

    # Record FIRST. `originalStatusLine` is the whole previous object (null when the key was absent),
    # which is what uninstall restores; `originalCommand` is the string the chain wrapper actually
    # invokes. Recording both means a restore never has to reconstruct anything.
    if [[ -f "$STATE" ]] && jq -e 'has("originalStatusLine")' "$STATE" >/dev/null 2>&1; then
      die "a recording already exists at $STATE — run 'uninstall' first (overwriting it would record shiploop's own wrapper as your original and make restore impossible)"
    fi
    orig_obj="$(printf '%s' "$cur_json" | jq -c '.statusLine // null')"
    orig_cmd="$(printf '%s' "$cur_json" | jq -r '.statusLine.command // ""')"
    mkdir -p "$(dirname "$STATE")" 2>/dev/null || true
    # -c (compact): the chain wrapper reads this file with awk, not jq — it must stay dependency-free
    # and fast, since it runs on every statusline update.
    jq -nc --argjson o "$orig_obj" --arg c "$orig_cmd" --arg s "$SEGMENT" --arg ch "$CHAIN" \
       --argjson t "$(date +%s)" \
       '{originalStatusLine:$o, originalCommand:$c, segment:$s, chain:$ch, installedAt:$t}' \
       > "$STATE" || die "could not record the existing statusline to $STATE"

    # Now wrap. `refreshInterval` is preserved from the original when it had one — the user's number
    # beats ours; otherwise default to GOVERN_STATUSLINE_REFRESH (5s), without which the line does
    # not update while the session sits idle and the elapsed time visibly freezes.
    new_json="$(printf '%s' "$cur_json" | jq \
      --arg cmd "$OUR_CMD" --argjson refresh "$REFRESH" '
        .statusLine = ((.statusLine // {})
          | .type = "command"
          | .command = $cmd
          | .refreshInterval = (.refreshInterval // $refresh))
      ')" || die "jq failed to build the new settings"
    write_settings "$new_json"
    if [[ -n "$orig_cmd" ]]; then
      printf 'statusline: wrapped your existing command (recorded verbatim at %s)\n' "$STATE"
      printf '            original: %s\n' "$orig_cmd"
    else
      printf 'statusline: installed (there was no previous statusLine to preserve)\n'
    fi
    printf '            settings: %s   refreshInterval=%ss\n' "$SETTINGS" "$REFRESH"
    printf "            remove with: bash %s uninstall\n" "${BASH_SOURCE[0]}"
    ;;

  uninstall)
    cur_json="$(read_settings)"
    printf '%s' "$cur_json" | jq empty >/dev/null 2>&1 || die "$SETTINGS is not valid JSON — refusing to touch it"
    if [[ ! -f "$STATE" ]]; then
      if installed; then
        die "settings.json points at shiploop's wrapper but the recording at $STATE is gone — refusing to guess; edit statusLine by hand"
      fi
      printf 'statusline: not installed (no recording at %s)\n' "$STATE"
      exit 0
    fi
    orig_obj="$(jq -c '.originalStatusLine // null' "$STATE" 2>/dev/null || printf 'null')"
    if [[ "$orig_obj" == "null" ]]; then
      # There was no statusLine before us — remove the key entirely rather than leaving an empty
      # object behind. "Restore verbatim" includes restoring its ABSENCE.
      new_json="$(printf '%s' "$cur_json" | jq 'del(.statusLine)')" || die "jq failed"
    else
      new_json="$(printf '%s' "$cur_json" | jq --argjson o "$orig_obj" '.statusLine = $o')" || die "jq failed"
    fi
    write_settings "$new_json"
    rm -f "$STATE" 2>/dev/null || true
    printf 'statusline: removed — your original statusLine restored verbatim in %s\n' "$SETTINGS"
    ;;

  status)
    if installed; then
      printf 'statusline: INSTALLED\n'
      printf '  settings : %s\n' "$SETTINGS"
      printf '  command  : %s\n' "$(read_settings | jq -r '.statusLine.command // ""')"
      printf '  refresh  : %ss\n' "$(read_settings | jq -r '.statusLine.refreshInterval // "unset"')"
      printf '  wrapping : %s\n' "$(jq -r '.originalCommand // "(nothing — there was no previous statusLine)"' "$STATE" 2>/dev/null || printf '(recording missing!)')"
    else
      printf 'statusline: not installed\n'
      printf '  settings : %s\n' "$SETTINGS"
      printf '  current  : %s\n' "$(read_settings | jq -r '.statusLine.command // "(none)"')"
      printf '  install  : bash %s install\n' "${BASH_SOURCE[0]}"
    fi
    ;;

  *) die "unknown action '$ACTION' (install | uninstall | status)" ;;
esac
exit 0
