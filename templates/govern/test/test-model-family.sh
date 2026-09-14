#!/usr/bin/env bash
# govern::model_family: normalises a model alias OR a full model id down to its bare family name
# (haiku/sonnet/opus/fable). Same lowercase-and-strip-the-[…]-suffix pass govern::model_rank runs,
# kept as its own function because a caller needing a family name (not a comparable rank) should
# not have to unpack one out of model_rank's encoding.
# Covered: bare alias, full id, a [1m] context-window suffix, a dated build id, an unknown model,
# and empty input.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
COMMON="$DIR/../lib/common.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"

fam() { ( source "$COMMON"; govern::model_family "$1" ); }
assert_eq "$(fam opus)"                              "opus"   "bare alias 'opus'"
assert_eq "$(fam claude-sonnet-5)"                    "sonnet" "full id 'claude-sonnet-5'"
assert_eq "$(fam 'claude-opus-5[1m]')"                 "opus"   "a [1m] context-window suffix does not change the family"
assert_eq "$(fam claude-haiku-4-5-20251001)"          "haiku"  "a dated build id still resolves to its family"
assert_eq "$(fam gpt-nano)"                           ""       "an unknown model → empty (no family)"
assert_eq "$(fam '')"                                 ""       "empty input → empty"

assert_done
