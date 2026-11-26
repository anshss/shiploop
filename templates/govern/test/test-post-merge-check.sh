#!/usr/bin/env bash
# post-merge-check.sh's GOVERN_LABS_FILE seam, driven against a real fixture repo:
#   a. no eval/labs/select.js in the merged checkout -> the CMD receives NO GOVERN_LABS_FILE
#      (unset; full-suite fallback; a CMD that ignores the variable is unaffected).
#   b. a selector that exits non-zero -> empty GOVERN_LABS_FILE, with the fallback note on stderr.
#   c. a selector that succeeds -> the CMD receives the selector's own output file, and the file
#      list it was handed is the merged sha's FIRST-PARENT diff (only the tip commit's files, so
#      squash and fast-forward merges both select correctly).
#   d. a selector that succeeds but selects nothing -> GOVERN_LABS_FILE is set to an existing,
#      EMPTY file (the consuming harness's cheap sections skip).
#   e. GOVERN_POST_MERGE_LABS_SELECT set -> it REPLACES the node selector (which is present but
#      must not be consulted), runs in the merged checkout with --changed <file> appended to the
#      command string, and its stdout is what the CMD receives.
#   f. a failing override selector -> empty GOVERN_LABS_FILE, with the fallback note on stderr.
#   g. a wsp_post_merge_cmd() defined in workspace.sh REPLACES GOVERN_POST_MERGE_CMD.
#   h. the CMD's env carries no GOVERN_*/WSP_* variable and nothing under a GOVERN_GATE_ENV_STRIP
#      prefix; an unrelated variable survives; GOVERN_LABS_FILE is still handed over.
#   i. the PASS cache: a recorded PASS for (repo, merged sha, command key) within the TTL is
#      reused without re-running the CMD; cache off, a changed key, an expired or corrupt record all
#      run the gate in full; a FAIL is never recorded.
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
assert_contains "$(cat "$LABLOG")" "labsfile=<unset>" "a. ...and the CMD got NO GOVERN_LABS_FILE (full-suite fallback; unset, not set-empty)"

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

# ── e. the override selector replaces the node selector ──────────────────────────────────────────
# GOVERN_POST_MERGE_LABS_SELECT set with eval/labs/select.js ALSO present: the override wins, runs
# in the merged checkout with the changed-file path as $2 after --changed, and its stdout is what
# the CMD receives. The override emits the changed list's own entries EXCEPT tools/ (the node
# selector's output would not be consulted at all).
cat > "$T/pusher/eval/labs/select.js" <<'SELECTOR'
const fs = require('fs');
console.log('node-selector-was-NOT-consulted');
SELECTOR
SELLOG="$T/sellog.txt"; export SELLOG
# A bare script path is the common override shape: the gate APPENDS --changed <file> to the
# command string, so the selector is invoked as `bash <script> --changed <path>` in the checkout.
cat > "$T/selwrap.sh" <<'WRAP'
#!/usr/bin/env bash
{ printf 'args=%s\n' "$*"; printf 'cwd=%s/markers/override.txt\n' "$PWD"; } >> "$SELLOG"
[ "${1:-}" = "--changed" ] || exit 3
cat "$2"
WRAP
export GOVERN_POST_MERGE_LABS_SELECT="bash $T/selwrap.sh"
mkdir -p "$T/pusher/markers"
printf x > "$T/pusher/markers/override.txt"
( cd "$T/pusher" && mkdir -p src tools && echo C > src/c.js && echo T > tools/t.txt \
  && git add -A && git commit -qm mixed && git push -q origin main )
rungate
assert_eq "$GATE_RC" "0" "e. the override selector: the gate passes"
assert_contains "$GATE_ERR" "lab selection:" "e. ...and logs the override's selection"
assert_contains "$GATE_ERR" "src/c.js" "e. ...naming the changed files the override picked"
econtent="$(grep '^content=' "$LABLOG" | tail -1)"
assert_contains "$econtent" "src/c.js" "e. ...and the CMD got the OVERRIDE's output"
assert_not_contains "$(cat "$LABLOG")" "node-selector-was-NOT-consulted" "e. ...and NOT the node selector's (override wins)"
assert_contains "$(cat "$SELLOG")" "args=--changed" "e. ...and the override got the --changed argv contract"
assert_contains "$(cat "$SELLOG")" "govern-post-merge-check." "e. ...pointing at the gate's changed-file list"
assert_contains "$(cat "$SELLOG")" "check/markers/override.txt" "e. ...and ran with the temp checkout as cwd"

# ── f. a failing override selector: fallback to the full suite ───────────────────────────────────
export GOVERN_POST_MERGE_LABS_SELECT='exit 4'
: > "$LABLOG"
rungate
assert_eq "$GATE_RC" "0" "f. a failing override: the gate still passes"
assert_contains "$GATE_ERR" "selector failed; falling back to the full lab suite" "f. ...with the fallback note"
assert_contains "$(cat "$LABLOG")" "labsfile=" "f. ...and the CMD got an EMPTY GOVERN_LABS_FILE"
unset GOVERN_POST_MERGE_LABS_SELECT SELLOG

# rungate_as "<cmd>" [VAR=VAL ...]: the gate with an explicit check command and extra parent env.
rungate_as() { # -> sets GATE_RC and GATE_ERR
  local cmd="$1"; shift
  GATE_ERR="$(cd "$T" && env GOVERN_WS_ROOT="$T" GOVERN_POST_MERGE_CMD="$cmd" "$@" \
    bash "$GATE" alpha pr 2>&1 >/dev/null)"; GATE_RC=$?
}
CACHE="$T/governor/.post-merge-cache"

# ── g. wsp_post_merge_cmd() REPLACES the global knob ──────────────────────────────────────────────
# When workspace.sh defines the function, its output for the repo IS the command and
# GOVERN_POST_MERGE_CMD is never consulted. The cache is off for every g/h run so each one proves
# the child really ran.
cp "$T/scripts/lib/workspace.sh" "$T/workspace.sh.bak"
cat >> "$T/scripts/lib/workspace.sh" <<'PER'
wsp_post_merge_cmd() { printf 'echo "perrepo repo=%s" >> "%s"' "$1" "$LABLOG"; }
PER
: > "$LABLOG"
rungate_as "echo global-knob-ran >> $LABLOG" GOVERN_POST_MERGE_CACHE=0
assert_eq "$GATE_RC" "0" "g. a wsp_post_merge_cmd workspace: the gate passes"
assert_contains "$(cat "$LABLOG")" "perrepo repo=alpha" "g. ...and the CMD was the function's output for the repo"
assert_not_contains "$(cat "$LABLOG")" "global-knob-ran" "g. ...NOT the GOVERN_POST_MERGE_CMD global knob"
cp "$T/workspace.sh.bak" "$T/scripts/lib/workspace.sh"

# ── h. child-env sanitization ──────────────────────────────────────────────────────────────────────
# The gate's own knobs were read from the parent env first; the CMD must see none of the session's.
SNIFFH="$T/sniffh.sh"
cat > "$SNIFFH" <<'HSNIFF'
#!/usr/bin/env bash
{ printf 'govern=%s\n' "${GOVERN_SOME_SESSION_KNOB-<unset>}"
  printf 'wsp=%s\n' "${WSP_SOME_SESSION_KNOB-<unset>}"
  printf 'aws=%s\n' "${AWS_SESSION_TOKEN-<unset>}"
  printf 'plain=%s\n' "${PLAIN_SESSION_VAR-<unset>}"
  printf 'labs=%s\n' "${GOVERN_LABS_FILE-<unset>}"
} >> "$LABLOG"
HSNIFF
chmod +x "$SNIFFH"
: > "$LABLOG"
rungate_as "$SNIFFH" GOVERN_POST_MERGE_CACHE=0 GOVERN_SOME_SESSION_KNOB=leak WSP_SOME_SESSION_KNOB=leak \
  AWS_SESSION_TOKEN=leak PLAIN_SESSION_VAR=keep GOVERN_GATE_ENV_STRIP=AWS_
assert_eq "$GATE_RC" "0" "h. a sanitized run: the gate passes"
assert_contains "$GATE_ERR" "sanitized gate child env" "h. ...and logs the sanitization"
assert_contains "$GATE_ERR" "AWS_|GOVERN_|WSP_" "h. ...naming the strip pattern with the extra prefix folded in"
assert_contains "$(cat "$LABLOG")" "govern=<unset>" "h. ...the child sees no GOVERN_ variable"
assert_contains "$(cat "$LABLOG")" "wsp=<unset>" "h. ...no WSP_ variable"
assert_contains "$(cat "$LABLOG")" "aws=<unset>" "h. ...and nothing under a GOVERN_GATE_ENV_STRIP prefix"
assert_contains "$(cat "$LABLOG")" "plain=keep" "h. ...while an unrelated variable survives"
assert_contains "$(cat "$LABLOG")" "labs=/" "h. ...while GOVERN_LABS_FILE (the selector ran in e) is still handed over"

# ── i. PASS cache ──────────────────────────────────────────────────────────────────────────────────
# A landing batch resolves several PRs against the SAME merged ref; re-proving an unchanged ref is
# duplicated wall clock. PASSes only are recorded; any mismatch, expiry or corruption runs in full.
rm -rf "$CACHE"
: > "$LABLOG"
rungate
assert_eq "$GATE_RC" "0" "i. first run on a fresh record: the gate passes"
assert_contains "$GATE_ERR" "PASS on merged ref" "i. ...by running the CMD"
assert_eq "$(grep -c '^labsfile=' "$LABLOG")" "1" "i. ...and the CMD ran exactly once"
if [ -s "$CACHE/alpha" ]; then
  echo "ok   - i. ...and the PASS was recorded for the repo"
else
  echo "FAIL - i. a PASS was not recorded in governor/.post-merge-cache/<repo>"; ASSERT_FAILS=$((ASSERT_FAILS+1))
fi
rungate
assert_eq "$GATE_RC" "0" "i. second run on the same sha: the gate passes"
assert_contains "$GATE_ERR" "reuse PASS" "i. ...by REUSING the recorded PASS"
assert_eq "$(grep -c '^labsfile=' "$LABLOG")" "1" "i. ...and the CMD did NOT run again"
rungate_as "$LABSNIF" GOVERN_POST_MERGE_CACHE=0
assert_contains "$GATE_ERR" "running GOVERN_POST_MERGE_CMD" "i. GOVERN_POST_MERGE_CACHE=0 runs the gate in full"
assert_eq "$(grep -c '^labsfile=' "$LABLOG")" "2" "i. ...and the CMD ran again"
DECOY="echo decoy-ran >> $LABLOG"
rungate_as "$DECOY"
assert_eq "$(grep -c decoy-ran "$LABLOG")" "1" "i. a changed check command runs the gate (the key hashes the command)"
rungate_as "$DECOY"
assert_eq "$(grep -c decoy-ran "$LABLOG")" "1" "i. ...and its PASS is recorded under ITS key (the next run reuses)"
read -r c_sha c_hash c_ts _ < "$CACHE/alpha"
printf '%s %s %s\n' "$c_sha" "$c_hash" "$(( c_ts - 9999 ))" > "$CACHE/alpha"
rungate_as "$DECOY"
assert_contains "$GATE_ERR" "running GOVERN_POST_MERGE_CMD" "i. an expired record runs the gate in full"
assert_eq "$(grep -c decoy-ran "$LABLOG")" "2" "i. ...and the CMD ran"
printf 'garbage\n' > "$CACHE/alpha"
rungate_as "$DECOY"
assert_contains "$GATE_ERR" "running GOVERN_POST_MERGE_CMD" "i. a corrupt record runs the gate in full"
rm -rf "$CACHE"
rungate_as "exit 3"
assert_eq "$GATE_RC" "7" "i. a failing CMD fails the gate"
if [ -e "$CACHE/alpha" ]; then
  echo "FAIL - i. a FAIL was recorded in the PASS cache"; ASSERT_FAILS=$((ASSERT_FAILS+1))
else
  echo "ok   - i. a FAIL is never recorded"
fi

assert_done
