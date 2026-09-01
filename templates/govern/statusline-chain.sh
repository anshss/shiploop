#!/usr/bin/env bash
# The statusline command shiploop installs. It CHAINS — it does not replace.
#
# statusLine.command is a single string, so anything that "installs a statusline" by writing its own
# value destroys whatever the user already had (ccusage, a custom HUD, a git/model line). That is the
# one unacceptable outcome here, so:
#
#   1. statusline-install.sh records the user's ENTIRE previous `statusLine` object, verbatim, into a
#      sidecar state file before touching settings.json.
#   2. This wrapper reads stdin ONCE (it is a pipe — the child and the segment cannot each `cat` it),
#      feeds the identical payload to the recorded original command, and appends shiploop's segment.
#   3. Uninstall writes the recorded object straight back, byte for byte.
#
# The original's output always comes FIRST and is passed through unchanged, so a user who forgets
# this is installed sees their own statusline plus a fleet segment — never a replacement.
#
# Never fails: a broken original, a missing segment, a bad state file all degrade to printing
# whatever else worked. A statusline script that exits non-zero or hangs is a visible defect in
# every prompt of every session.
set -uo pipefail

STATE="${GOVERN_STATUSLINE_STATE:-$HOME/.claude/shiploop-statusline.json}"
IN="$(cat 2>/dev/null || true)"

_state_field() { # <key> -> raw string value, "" when absent
  [[ -f "$STATE" ]] || { printf ''; return 0; }
  awk -v key="$1" '
    { s = s $0 }
    END {
      # Tolerate whitespace after the colon: jq pretty-prints by default, and a state file an
      # operator has opened and re-saved will not be compact either. Anchoring on `"key":"` alone
      # silently found nothing and the wrapper degraded to printing only our own segment — i.e. it
      # LOOKED like a clobber, which is the one outcome this whole file exists to prevent.
      pat = "\"" key "\":"
      i = index(s, pat)
      if (i == 0) { print ""; exit }
      s = substr(s, i + length(pat))
      while (substr(s, 1, 1) == " " || substr(s, 1, 1) == "\t") s = substr(s, 2)
      if (substr(s, 1, 1) != "\"") { print ""; exit }
      s = substr(s, 2); out = ""; esc = 0
      for (j = 1; j <= length(s); j++) {
        c = substr(s, j, 1)
        if (esc) { if (c == "n") out = out "\n"; else if (c == "t") out = out "\t"; else out = out c; esc = 0 }
        else if (c == "\\") { esc = 1 }
        else if (c == "\"") { break }
        else { out = out c }
      }
      print out
    }' "$STATE" 2>/dev/null
  return 0
}

ORIG_CMD="$(_state_field originalCommand)"
SEGMENT="$(_state_field segment)"

OUT=""
if [[ -n "$ORIG_CMD" ]]; then
  # `bash -c`, not `eval`: the recorded value is a shell command line the user already trusted enough
  # to put in settings.json, and running it in a child keeps a `cd`/`exit`/`set` in it from affecting
  # this wrapper. stdin is the captured payload, replayed identically.
  OUT="$(printf '%s' "$IN" | bash -c "$ORIG_CMD" 2>/dev/null || true)"
fi

SEG=""
if [[ -n "$SEGMENT" && -f "$SEGMENT" ]]; then
  SEG="$(printf '%s' "$IN" | bash "$SEGMENT" 2>/dev/null || true)"
fi

# Trim trailing newlines from both halves so the join never emits a blank second line.
OUT="${OUT%$'\n'}"; SEG="${SEG%$'\n'}"

if [[ -n "$OUT" && -n "$SEG" ]]; then printf '%s %s %s\n' "$OUT" "${GOVERN_STATUSLINE_SEP:-·}" "$SEG"
elif [[ -n "$SEG" ]];             then printf '%s\n' "$SEG"
elif [[ -n "$OUT" ]];             then printf '%s\n' "$OUT"
fi
exit 0
