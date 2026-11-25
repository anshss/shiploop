#!/usr/bin/env bash
# Unit test of the zero-spend parse probe, govern::claude_flag_parses (lib/common.sh), and the
# two capability probes built on it (govern::claude_supports_tools_flag, govern::claude_bin_is_real).
#
# The probe runs `<bin> -p <flag> <value> </dev/null>` and classifies by output: a known flag
# exits at the missing-input validation with "Input must be provided either through stdin or as
# a prompt argument"; an unknown flag fails parsing with "error: unknown option". The fixture
# here reproduces exactly those two behaviors.
#
# Covered:
#   1. a flag the fixture CLI knows -> probe reports supported (rc 0) and writes the run-scoped cache
#   2. a flag the fixture CLI does not know -> probe reports unsupported (rc 1)
#   3. the cache prevents re-probing (fixture swapped for an all-unknown parser; the cached
#      verdict wins and the binary is not invoked a second time)
#   4. a hidden-but-supported flag: `--max-turns` parses yet is absent from the fixture's `--help`
#      output, so the realness check accepts a real-CLI-shaped binary without reading help at all
#   5. the pre-seed seams (_GOVERN_TOOLS_SUPPORTED / _GOVERN_REAL_CLAUDE_BIN) skip the probe
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"

T="$(mktemp -d)"; mk_ws_stub "$T"
# The cache-path env overrides and the probe bound are baked into module state at source time, so
# set them BEFORE sourcing lib/common.sh. The bound override keeps the fixture spawn immune to
# wall-clock contention on a loaded runner (the suite runs up to 8 tests in parallel); the probe
# still exercises the normal run_bounded path, only with a wider margin.
export GOVERN_EDP_PROBE_TIMEOUT_S=60
export GOVERN_TOOLS_PROBE_CACHE="$T/cache/tools-support"
export GOVERN_REAL_BIN_PROBE_CACHE="$T/cache/real-bin"
source "$DIR/../lib/common.sh"

make_claude_fixture() { # <path> <known-flags-csv> <help-listed-csv>
  # Arg-parser-shaped stub of the claude CLI. Its --help lists only <help-listed-csv>, but its
  # parser accepts every flag in <known-flags-csv> exactly like the real CLI does: known flag
  # exits at the missing-input validation (stderr, rc 1, zero work), unknown flag exits with the
  # parse error. Every invocation appends a line to <path>.invocations so tests can count probes.
  local path="$1" known="$2" listed="$3" f
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<FIXEOF
#!/usr/bin/env bash
printf 'run\n' >> "$path.invocations"
if [[ "\${1:-}" == "--help" ]]; then
  printf 'Usage: claude [options]\n'
FIXEOF
  for f in ${listed//,/ }; do
    printf '  printf %s\n' "'  $f <value>\n'" >> "$path"
  done
  cat >> "$path" <<FIXEOF
  exit 0
fi
case ",$known," in *",\${2:-},"*)
  echo "Error: Input must be provided either through stdin or as a prompt argument when using --print" >&2
  exit 1 ;;
esac
echo "error: unknown option '\${2:-}'" >&2
exit 1
FIXEOF
  chmod +x "$path"
}

invocations() { # <path> -> count of fixture invocations
  [[ -f "$1.invocations" ]] && wc -l < "$1.invocations" | tr -d ' ' || printf '0'
}

# ── 1. known flag -> supported, cache written ────────────────────────────────
BIN="$T/bin/claude-tools"
make_claude_fixture "$BIN" '--tools' '--tools'
export GOVERN_TOOLS_PROBE_CACHE="$T/cache/tools-support"
rc=0; govern::claude_supports_tools_flag "$BIN" || rc=$?
assert_eq "$rc" "0" "1. a flag the CLI parses reports supported"
assert_eq "$(cat "$GOVERN_TOOLS_PROBE_CACHE")" "1" "1. the run-scoped cache records the verdict"
assert_eq "$(invocations "$BIN")" "1" "1. the fixture binary was invoked exactly once"

# ── 2. unknown flag -> unsupported ───────────────────────────────────────────
UNK="$T/bin/claude-unknown"
make_claude_fixture "$UNK" '' ''
rc=0; govern::claude_flag_parses "$UNK" '--definitely-not-a-flag' 'x' || rc=$?
assert_eq "$rc" "1" "2. a flag the CLI rejects reports unsupported"

# ── 3. cache prevents re-probing ─────────────────────────────────────────────
make_claude_fixture "$BIN" '' ''   # swap in a parser that knows nothing
rc=0; govern::claude_supports_tools_flag "$BIN" || rc=$?
assert_eq "$rc" "0" "3. the cached verdict wins over a now-failing probe"
assert_eq "$(invocations "$BIN")" "1" "3. no second invocation: the probe never re-ran"

# ── 4. hidden-but-supported flag ─────────────────────────────────────────────
HIDDEN="$T/bin/claude-hidden"
make_claude_fixture "$HIDDEN" '--max-turns' ''
export GOVERN_REAL_BIN_PROBE_CACHE="$T/cache/real-bin"
rc=0; govern::claude_bin_is_real "$HIDDEN" || rc=$?
assert_eq "$rc" "0" "4. a flag hidden from --help yet parses passes the realness check"
HIDDEN_OFF="$T/bin/claude-stub"
make_claude_fixture "$HIDDEN_OFF" '' ''
rm -f "$GOVERN_REAL_BIN_PROBE_CACHE"   # 4a's verdict is cached; 4b must probe fresh
rc=0; govern::claude_bin_is_real "$HIDDEN_OFF" || rc=$?
assert_eq "$rc" "1" "4. a binary that parses nothing fails the realness check"

# ── 5. pre-seed seams skip the probe ─────────────────────────────────────────
rc=0; _GOVERN_TOOLS_SUPPORTED=0 govern::claude_supports_tools_flag "$BIN" || rc=$?
assert_eq "$rc" "1" "5. _GOVERN_TOOLS_SUPPORTED=0 forces unsupported without probing"
assert_eq "$(invocations "$BIN")" "1" "5. the seam skipped the probe (no new invocation)"
rc=0; _GOVERN_REAL_CLAUDE_BIN=1 govern::claude_bin_is_real "$HIDDEN_OFF" || rc=$?
assert_eq "$rc" "0" "5. _GOVERN_REAL_CLAUDE_BIN=1 forces real without probing"

rm -rf "$T"
assert_done
