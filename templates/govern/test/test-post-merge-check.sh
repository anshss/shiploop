#!/usr/bin/env bash
# post-merge-check.sh's GOVERN_LABS_FILE seam, driven against a real fixture repo:
#   a. no eval/labs/select.js in the merged checkout -> the CMD receives an EMPTY GOVERN_LABS_FILE
#      (full-suite fallback; a CMD that ignores the variable is unaffected).
#   b. a selector that exits non-zero -> empty GOVERN_LABS_FILE, with the fallback note on stderr.
#   c. a selector that succeeds -> the CMD receives the selector's own output file, and the file
#      list it was handed is the merged sha's FIRST-PARENT diff (only the tip commit's files, so
#      squash and fast-forward merges both select correctly).
#   d. a selector that succeeds but selects nothing -> GOVERN_LABS_FILE is set to an existing,
#      EMPTY file (the consuming harness's cheap sections skip).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

GATE="$DIR/../post-merge-check.sh"
[[ -f "$GATE" ]] || { echo "SKIP: post-merge-check.sh not found"; exit 77; }
command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"

# fixture: bare origin + the local checkout post-merge-check resolves the merged ref through
# (wsp_repo_localdir in the stub returns $T/<repo>), + a pusher clone that advances origin main.
git init -q --bare -b main "$T/origin.git"
git clone -q "$T/origin.git" "$T/pusher" 2>/dev/null
( cd "$T/pusher" && git config user.email t@t && git config user.name t \
  && echo base > base.txt && git add base.txt && git commit -qm base && git push -q origin main )
git clone -q "$T/origin.git" "$T/alpha" 2>/dev/null
( cd "$T/alpha" && git config user.email t@t && git config user.name t )

push_main() { # <path-in-repo> ...  (reads file contents already written to "$T/pusher/<path>")
  ( cd "$T/pusher" && git add -A && git commit -qm "witness $*" && git push -q origin main )
  git -C "$T/origin.git" rev-parse main
}

# the consuming CMD: records what it received. GOVERN_LABS_FILE is always SET (possibly empty),
# never unset, so ${VAR-} (not ${VAR:-}) keeps the two distinguishable.
LABLOG="$T/lablog.txt"; export LABLOG
LABSNIF="$T/labsnif.sh"; export LABSNIF
cat > "$LABSNIF" <<'SNIFF'
#!/usr/bin/env bash
{ printf 'labsfile=%s\n' "${GOVERN_LABS_FILE-<unset>}"
  # size at CMD time: the gate's EXIT trap deletes the temp dir, so the file is gone post-run.
  if [ -n "${GOVERN_LABS_FILE:-}" ]; then
    printf 'content=%s\n' "$(tr '\n' ' ' < "$GOVERN_LABS_FILE")"
    printf 'size=%s\n' "$(wc -c < "$GOVERN_LABS_FILE" | tr -d ' ')"
  fi
} >> "$LABLOG"
SNIFF
chmod +x "$LABSNIF"

rungate() { # -> sets GATE_RC and GATE_ERR (stderr+stdout of the gate)
  GATE_ERR="$(cd "$T" && env GOVERN_WS_ROOT="$T" GOVERN_POST_MERGE_CMD="$LABSNIF" \
    bash "$GATE" alpha pr 2>&1 >/dev/null)"; GATE_RC=$?
}

# ── a. no selector in the merged checkout: empty GOVERN_LABS_FILE ────────────────────────────────
rungate
assert_eq "$GATE_RC" "0" "a. no selector: the gate passes"
assert_contains "$GATE_ERR" "PASS on merged ref" "a. ...and reports the pass"
assert_contains "$(cat "$LABLOG")" "labsfile=" "a. ...and the CMD got an EMPTY GOVERN_LABS_FILE (full-suite fallback)"

# ── b. selector present but failing: fallback to the full suite ──────────────────────────────────
mkdir -p "$T/pusher/eval/labs"
printf 'process.exit(1);\n' > "$T/pusher/eval/labs/select.js"
push_main eval/labs/select.js
rungate
assert_eq "$GATE_RC" "0" "b. a failing selector: the gate still passes"
assert_contains "$GATE_ERR" "selector failed; falling back to the full lab suite" "b. ...with the fallback note"
assert_contains "$(cat "$LABLOG")" "labsfile=" "b. ...and the CMD got an EMPTY GOVERN_LABS_FILE"

# ── c. a working selector: its output is consumed, and the file list is the FIRST-PARENT diff ────
# Two commits pushed together: the merged sha's first-parent diff is ONLY src/b.js, so a selector
# fed the cumulative or full history would name src/a.js too.
cat > "$T/pusher/eval/labs/select.js" <<'SELECTOR'
const fs = require('fs');
const a = process.argv;
const changed = fs.readFileSync(a[a.indexOf('--changed') + 1], 'utf8')
  .split('\n').filter((s) => s && !s.startsWith('eval/'));
for (const f of changed) console.log('lab-' + f);
SELECTOR
( cd "$T/pusher" && mkdir -p src && echo A > src/a.js && git add -A && git commit -qm a \
  && echo B > src/b.js && git add -A && git commit -qm b && git push -q origin main )
rungate
assert_eq "$GATE_RC" "0" "c. a working selector: the gate passes"
assert_contains "$GATE_ERR" "lab selection:" "c. ...and logs the selection"
assert_contains "$(grep '^labsfile=' "$LABLOG" | tail -1)" "govern-post-merge-check." "c. ...and the CMD got the selector's output FILE"
assert_contains "$(cat "$LABLOG")" "content=lab-src/b.js" "c. ...whose content is the selector's pick for the TIP commit"
assert_not_contains "$(cat "$LABLOG")" "lab-src/a.js" "c. ...and NOT the parent commit's file (first-parent, not cumulative)"

# ── d. a selector that selects nothing: the CMD gets an existing EMPTY file ──────────────────────
# The tip commit touches only eval/ paths, which the selector ignores: zero labs.
printf '// updated selector, still ignores eval/\n' > "$T/pusher/eval/labs/select.js"
push_main eval/labs/select.js
rungate
assert_eq "$GATE_RC" "0" "d. a zero-selection merge: the gate passes"
labsline="$(grep '^labsfile=' "$LABLOG" | tail -1)"
assert_contains "$labsline" "govern-post-merge-check." "d. ...and GOVERN_LABS_FILE is SET to a file"
assert_contains "$(cat "$LABLOG")" "size=0" "d. ...and that file exists and is EMPTY (cheap sections skip)"

assert_done
