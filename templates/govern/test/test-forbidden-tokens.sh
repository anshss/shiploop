#!/usr/bin/env bash
# Regression for the forbidden-identity gate's token composition + filter (N3).
#
# The gate derives its forbidden-identity list from workspace config
# ($GITHUB_ORG + $META_NAME + ${REPOS[@]}) and greps -iwE the porter's ADDED
# lines for any of them. Before N3 the derived list included bare dictionary
# words that are legitimately present in genericized templates (`docs`,
# `console`, `website`, 2-letter `aq`), so a clean port saying "see the docs"
# tripped the gate as a FAKE leak. N3 filters the REPO-derived tokens (min
# length + stop-word list) while keeping $GITHUB_ORG/$META_NAME unfiltered, and
# adds a curated GOVERN_FORBIDDEN_TOKENS override that REPLACES the derived set.
#
# This test extracts the fenced gate region from sync-port.sh (the same code the
# tool runs) and exercises BOTH the token composition AND the real
# `grep -iwE "$(forbidden_regex)"` gate the tool applies to added lines.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

TOOL="$(cd "$DIR/.." && pwd)/sync-port.sh"
[ -f "$TOOL" ] || { echo "SKIP: sync-port.sh missing at $TOOL" >&2; exit 77; }

# Pull the fenced gate region out of the tool so we test the SHIPPED code, not a copy.
GATE_SRC="$(sed -n '/# >>> forbidden-token-gate/,/# <<< forbidden-token-gate/p' "$TOOL")"
[ -n "$GATE_SRC" ] || { echo "SKIP: forbidden-token-gate fence not found in $TOOL" >&2; exit 77; }

# gate_check "<added line>" -> prints PASS (no forbidden token) | LEAK (blocked),
# using the exact grep the tool runs at the leak gate. Reads identity from the
# GITHUB_ORG/META_NAME/REPOS + GOVERN_FORBIDDEN_* env already exported by caller.
gate_check() {
  local line="$1"
  ( eval "$GATE_SRC"
    local fregex added leaks
    fregex="$(forbidden_regex)"
    added="+$line"                                   # mimic a diff-added line
    leaks="$(printf '%s\n' "$added" | grep -iwE "$fregex" || true)"
    [ -n "$leaks" ] && printf 'LEAK' || printf 'PASS'
  )
}
tokens_of() { ( eval "$GATE_SRC"; forbidden_tokens | tr '\n' ' ' ); }

# ── Reference-shaped identity: repos include the colliding dictionary words ──
# `docs`/`console`/`website` = dictionary words; `mjolnir` = a genuinely
# identifying repo name; `aq` = 2-letter short token.
export GITHUB_ORG="AcmeOrg" META_NAME="acmeproduct"
export REPOS=(docs console website mjolnir aq)
unset GOVERN_FORBIDDEN_EXTRA GOVERN_FORBIDDEN_TOKENS GOVERN_FORBIDDEN_MIN_LEN

toks="$(tokens_of)"

# Composition: dictionary-word + short repo tokens filtered OUT …
assert_eq "$(grep -qw docs    <<<"$toks" && echo in || echo out)" "out" "docs (dictionary repo) filtered out of forbidden list"
assert_eq "$(grep -qw console <<<"$toks" && echo in || echo out)" "out" "console (dictionary repo) filtered out"
assert_eq "$(grep -qw website <<<"$toks" && echo in || echo out)" "out" "website (dictionary repo) filtered out"
assert_eq "$(grep -qw aq      <<<"$toks" && echo in || echo out)" "out" "aq (2-letter repo) filtered out (below min length)"
# … while high-signal identity + distinctive repo names stay IN.
assert_eq "$(grep -qw acmeorg     <<<"$toks" && echo in || echo out)" "in" "org name always forbidden"
assert_eq "$(grep -qw acmeproduct <<<"$toks" && echo in || echo out)" "in" "meta name always forbidden"
assert_eq "$(grep -qw mjolnir     <<<"$toks" && echo in || echo out)" "in" "distinctive repo name still forbidden"

# ── Case 1: "see the docs" PASSES with a repo named `docs` ──
assert_eq "$(gate_check 'see the docs for details')" "PASS" "1. clean 'see the docs' line PASSES (docs no longer a leak)"
assert_eq "$(gate_check 'print status to the console')" "PASS" "1b. 'to the console' PASSES (console no longer a leak)"

# ── Case 2: a line containing the ORG name still FAILS ──
assert_eq "$(gate_check 'deploy to AcmeOrg cluster')" "LEAK" "2. org name in an added line still BLOCKS"
assert_eq "$(gate_check 'the acmeproduct backend')" "LEAK" "2b. meta name in an added line still BLOCKS"

# ── Case 3: a genuinely-identifying repo name (mjolnir) still FAILS ──
assert_eq "$(gate_check 'restart the mjolnir provider')" "LEAK" "3. distinctive repo name still BLOCKS"

# ── Short high-signal org is NOT over-filtered (org/meta exempt from length) ──
( export GITHUB_ORG="aq" META_NAME="aq" REPOS=(docs)
  unset GOVERN_FORBIDDEN_TOKENS GOVERN_FORBIDDEN_EXTRA
  assert_eq "$(gate_check 'push image to aq registry')" "LEAK" "3b. short ORG name (2-letter) still forbidden — exempt from length filter" )

# ── Case 4: GOVERN_FORBIDDEN_TOKENS REPLACES the derived list ──
( export GOVERN_FORBIDDEN_TOKENS="widgetco zephyr"
  unset GOVERN_FORBIDDEN_EXTRA
  ov="$(tokens_of)"
  assert_eq "$(grep -qw widgetco <<<"$ov" && echo in || echo out)" "in" "4. override token widgetco present"
  assert_eq "$(grep -qw zephyr   <<<"$ov" && echo in || echo out)" "in" "4. override token zephyr present"
  assert_eq "$(grep -qw acmeorg  <<<"$ov" && echo in || echo out)" "out" "4. override REPLACES derived org token"
  assert_eq "$(grep -qw mjolnir  <<<"$ov" && echo in || echo out)" "out" "4. override REPLACES derived repo tokens"
  assert_eq "$(gate_check 'the AcmeOrg org')"     "PASS" "4b. derived org no longer blocks once overridden"
  assert_eq "$(gate_check 'ship it via widgetco')" "LEAK" "4b. override token blocks" )

# ── EXTRA still EXTENDS (with and without the override) ──
( export GOVERN_FORBIDDEN_EXTRA="specialsauce"
  unset GOVERN_FORBIDDEN_TOKENS
  assert_eq "$(gate_check 'add specialsauce here')" "LEAK" "5. GOVERN_FORBIDDEN_EXTRA still extends (derived path)"
  assert_eq "$(gate_check 'deploy to AcmeOrg')"     "LEAK" "5b. derived org still blocks alongside EXTRA" )
( export GOVERN_FORBIDDEN_TOKENS="widgetco" GOVERN_FORBIDDEN_EXTRA="specialsauce"
  assert_eq "$(gate_check 'add specialsauce here')" "LEAK" "5c. EXTRA extends even under the override" )

assert_done
