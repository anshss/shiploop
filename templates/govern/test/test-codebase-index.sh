#!/usr/bin/env bash
# codebase-index.sh: the index is built from git+grep alone (no model), carries the three row kinds
# (sym / dep / cov), answers `query` and `path`, refreshes incrementally against a stored ref, and
# no-ops silently under its kill switch.
#
# GOVERN_INDEX_CTAGS=0 throughout: ctags is an optional accelerator, so pinning the grep extractors
# keeps the expected row set identical on a machine with and without Universal Ctags installed.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
IDX="$DIR/../codebase-index.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mk_ws_stub "$TMP"                      # REPOS=(alpha web); WS_ROOT=$TMP
gitcfg() { git -C "$1" config user.email t@t; git -C "$1" config user.name t; }

export GOVERN_INDEX_DIR="$TMP/index"
export GOVERN_INDEX_CTAGS=0
# assert.sh force-exports GOVERN_INDEX=0 for the whole suite (the post-resolve rebuild in run-loop.sh
# is pure wall-clock across hundreds of synthetic tickets). This is the one test that must actually
# build, so it opts back in explicitly — the same per-feature pattern every other gated mechanism uses.
export GOVERN_INDEX=1

# A small polyglot repo: a JS module, a JS consumer of it, a co-located JS test, a Python module and
# a bash script that sources a lib — one instance of every extractor path that matters.
REPO="$TMP/alpha"
mkdir -p "$REPO/src" "$REPO/lib"
cat > "$REPO/src/math.js" <<'EOF'
export function addNumbers(a, b) { return a + b; }
export const MATH_VERSION = 2;
export class Calculator {}
EOF
cat > "$REPO/src/app.js" <<'EOF'
import { addNumbers } from './math.js';
export function runApp() { return addNumbers(1, 2); }
EOF
cat > "$REPO/src/math.test.js" <<'EOF'
import { addNumbers } from './math.js';
test('adds', () => { addNumbers(1, 2); });
EOF
cat > "$REPO/src/util.py" <<'EOF'
def slugify(text):
    return text
class Slugger:
    pass
EOF
cat > "$REPO/lib/shared.sh" <<'EOF'
#!/usr/bin/env bash
shared::hello() { echo hi; }
EOF
cat > "$REPO/run.sh" <<'EOF'
#!/usr/bin/env bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib/shared.sh"
run::main() { shared::hello; }
EOF
git init -q "$REPO"; gitcfg "$REPO"
( cd "$REPO" && git add -A && git commit -q -m init ) >/dev/null 2>&1

build_out="$("$IDX" build "$REPO" 2>&1)"
TSV="$GOVERN_INDEX_DIR/alpha.tsv"
assert_contains "$build_out" "full," "first build takes the FULL path (no stored ref yet)"
assert_eq "$([[ -f "$TSV" ]] && echo yes || echo no)" "yes" "writes <repo>.tsv"
assert_eq "$([[ -f "$GOVERN_INDEX_DIR/alpha.ref" ]] && echo yes || echo no)" "yes" "writes <repo>.ref"
assert_eq "$([[ -f "$GOVERN_INDEX_DIR/SUMMARY.md" ]] && echo yes || echo no)" "yes" "writes SUMMARY.md"
assert_eq "$(cat "$GOVERN_INDEX_DIR/alpha.ref")" "$(git -C "$REPO" rev-parse HEAD)" \
  "the stored ref is the indexed commit"

tsv="$(cat "$TSV")"
# ── file → symbols ──────────────────────────────────────────────────────────────────────────────
assert_contains "$tsv" "$(printf 'sym\tsrc/math.js\taddNumbers')" "js: exported function"
assert_contains "$tsv" "$(printf 'sym\tsrc/math.js\tMATH_VERSION')" "js: exported const"
assert_contains "$tsv" "$(printf 'sym\tsrc/math.js\tCalculator')" "js: exported class"
assert_contains "$tsv" "$(printf 'sym\tsrc/util.py\tslugify')" "py: def"
assert_contains "$tsv" "$(printf 'sym\tsrc/util.py\tSlugger')" "py: class"
assert_contains "$tsv" "$(printf 'sym\trun.sh\trun::main')" "sh: namespaced function"
assert_contains "$tsv" "$(printf 'sym\tlib/shared.sh\tshared::hello')" "sh: sourced lib function"

# ── module → dependents (reverse import graph) ──────────────────────────────────────────────────
assert_contains "$tsv" "$(printf 'dep\tsrc/math.js\tsrc/app.js')" "js relative import → reverse edge"
assert_contains "$tsv" "$(printf 'dep\tlib/shared.sh\trun.sh')" 'sh `source "$DIR/lib/x.sh"` → reverse edge'

# ── test file → files it covers (HEURISTIC) ─────────────────────────────────────────────────────
assert_contains "$tsv" "$(printf 'cov\tsrc/math.test.js\tsrc/math.js')" "test → covered file"
assert_not_contains "$tsv" "$(printf 'cov\tsrc/app.js')" "a non-test file never emits cov rows"

# Rows are the documented 3-column TAB shape and nothing else.
assert_eq "$(awk -F'\t' 'NF!=3 || $1!~/^(sym|dep|cov)$/' "$TSV" | wc -l | tr -d ' ')" "0" \
  "every row is exactly 3 TAB-separated fields with a known kind"

# ── query / path ────────────────────────────────────────────────────────────────────────────────
q="$("$IDX" query addNumbers 2>/dev/null)"
assert_contains "$q" "src/math.js" "query <symbol> finds the defining file"
assert_contains "$q" "alpha" "query rows are prefixed with the repo name"

p="$("$IDX" path src/math.js 2>/dev/null)"
assert_contains "$p" "defines:" "path <file> lists what the file defines"
assert_contains "$p" "addNumbers" "path <file> names the symbol"
assert_contains "$p" "imported by:" "path <file> lists dependents (reverse graph)"
assert_contains "$p" "src/app.js" "path <file> names the dependent"
assert_contains "$p" "covered by (heuristic)" "path <file> labels coverage as a HEURISTIC"
assert_contains "$p" "src/math.test.js" "path <file> names the covering test"

# ── incremental refresh ─────────────────────────────────────────────────────────────────────────
noop="$("$IDX" build "$REPO" 2>&1)"
assert_contains "$noop" "unchanged since" "a re-run on an unchanged tree does no work"
assert_eq "$(cat "$TSV")" "$tsv" "an unchanged re-run leaves the index byte-identical"

printf 'export function brandNewSymbol() {}\n' >> "$REPO/src/math.js"
( cd "$REPO" && git commit -q -am "add symbol" ) >/dev/null 2>&1
inc="$("$IDX" build "$REPO" 2>&1)"
assert_contains "$inc" "incremental, 1 file(s)" "only the changed file is re-indexed"
tsv2="$(cat "$TSV")"
assert_contains "$tsv2" "$(printf 'sym\tsrc/math.js\tbrandNewSymbol')" "the new symbol is picked up"
assert_contains "$tsv2" "$(printf 'sym\tsrc/util.py\tslugify')" "untouched files' rows are carried forward"
assert_contains "$tsv2" "$(printf 'dep\tsrc/math.js\tsrc/app.js')" "untouched dep edges survive"

# A DELETED file's rows are dropped, and so are the dep edges it owned as the dependent.
git -C "$REPO" rm -q "src/app.js"
( cd "$REPO" && git commit -q -m "drop app" ) >/dev/null 2>&1
"$IDX" build "$REPO" >/dev/null 2>&1
tsv3="$(cat "$TSV")"
assert_not_contains "$tsv3" "$(printf 'sym\tsrc/app.js')" "a deleted file's sym rows are dropped"
assert_not_contains "$tsv3" "$(printf 'dep\tsrc/math.js\tsrc/app.js')" "its dep edges are dropped too"
assert_contains "$tsv3" "$(printf 'sym\tsrc/math.js\taddNumbers')" "surviving files are untouched"

# GOVERN_INDEX_FULL=1 bypasses the incremental path entirely.
full="$(GOVERN_INDEX_FULL=1 "$IDX" build "$REPO" 2>&1)"
assert_contains "$full" "full," "GOVERN_INDEX_FULL=1 forces a full rebuild"

# ── kill switch: build is a SILENT no-op exiting 0 ───────────────────────────────────────────────
rm -rf "$TMP/index2"
set +e
off_out="$(GOVERN_INDEX=0 GOVERN_INDEX_DIR="$TMP/index2" "$IDX" build "$REPO" 2>&1)"; off_rc=$?
set -e
assert_eq "$off_rc" "0" "GOVERN_INDEX=0 exits 0"
assert_eq "$off_out" "" "GOVERN_INDEX=0 is SILENT"
assert_eq "$([[ -e "$TMP/index2" ]] && echo yes || echo no)" "no" "GOVERN_INDEX=0 writes nothing"

# ── safe in any repo state: a non-git dir and a missing dir are logged, never fatal ──────────────
mkdir -p "$TMP/notgit"
set +e
"$IDX" build "$TMP/notgit" >/dev/null 2>&1; ng_rc=$?
"$IDX" build "$TMP/does-not-exist-at-all" >/dev/null 2>&1; miss_rc=$?
set -e
assert_eq "$ng_rc" "0" "a non-git directory never fails the caller"
assert_eq "$miss_rc" "0" "a missing repo never fails the caller"

# ── deterministic by design: zero model invocations ─────────────────────────────────────────────
assert_eq "$(grep -vE '^[[:space:]]*#' "$IDX" | grep -cE '(^|[^a-zA-Z_-])claude([^a-zA-Z_.-]|$)' || true)" "0" \
  "codebase-index.sh invokes claude ZERO times"

assert_done
