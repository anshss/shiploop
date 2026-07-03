#!/usr/bin/env bash
# Proves govern-supervise.sh recovers a supervisor verdict wrapped in ```json fences or
# followed by trailing prose (a common LLM formatting drift), instead of silently downgrading
# a genuine `halt` (the systemic-failure brake) to `ok`. Truly-unparseable output still fails
# open to ok BUT emits a loud log line + tags the emitted verdict with `unparseable:true`, so
# a lost halt is visible in the run log rather than invisible.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"

SUP="$DIR/../govern-supervise.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"
mkdir -p "$T/bin" "$T/rundir" "$T/governor"
# supervisor-prompt.md must exist even if we mock claude — the script cats it.
printf 'SUPERVISOR-REVIEW\n' > "$T/governor/supervisor-prompt.md"
printf '## Open\n\n## Resolved\n' > "$T/governor/escalations.md"
printf '# tickets\n---\n' > "$T/tickets.md"
printf '{"ticket":1,"status":"resolved"}\n' > "$T/rundir/state.jsonl"

# Fake claude: emit whatever text $FAKE_SUPERVISOR_OUTPUT tells it to emit as the .result field
# of a stream-json result event.
cat > "$T/bin/claude" <<'EOF'
#!/usr/bin/env bash
# Read $FAKE_SUPERVISOR_OUTPUT file, escape into a JSON string via jq -Rs, emit as a result event.
raw="$(cat "$FAKE_SUPERVISOR_OUTPUT")"
printf '{"type":"result","result":%s}\n' "$(printf '%s' "$raw" | jq -Rs .)"
EOF
chmod +x "$T/bin/claude"

run_sup() { # <fixture-file>
  FAKE_SUPERVISOR_OUTPUT="$1" \
  GOVERN_WS_ROOT="$T" \
  GOVERN_TICKETS_FILE="$T/tickets.md" \
  GOVERN_ESCALATIONS_FILE="$T/governor/escalations.md" \
  GOVERN_SUPERVISOR_PROMPT_FILE="$T/governor/supervisor-prompt.md" \
  GOVERN_CLAUDE_BIN="$T/bin/claude" \
  PATH="$T/bin:$PATH" \
  bash "$SUP" "$T/rundir" 2>&1
}

# 1. Bare JSON — the happy path (baseline).
printf '{"verdict":"halt","haltReason":"the deploy pipeline is systemic-broken"}' > "$T/fx-bare.json"
out="$(run_sup "$T/fx-bare.json")"
verdict="$(printf '%s' "$out" | tail -1 | jq -r '.verdict')"
assert_eq "$verdict" "halt" "bare JSON verdict passes through unchanged"

# 2. ```json fence-wrapped JSON — the exact drift the fix targets. A genuine halt must survive.
{
  printf '```json\n'
  printf '{"verdict":"halt","haltReason":"systemic-broken"}\n'
  printf '```\n'
} > "$T/fx-fence.json"
out="$(run_sup "$T/fx-fence.json")"
verdict="$(printf '%s' "$out" | tail -1 | jq -r '.verdict')"
assert_eq "$verdict" "halt" 'triple-backtick fence-wrapped verdict recovered as halt (not defaulted to ok)'

# 3. JSON + trailing prose — the LLM appended explanatory prose after its JSON. Verdict must survive.
{
  printf '{"verdict":"halt","haltReason":"systemic-broken"}\n\n'
  printf 'I halted the run because every ticket in the batch failed the same way.\n'
} > "$T/fx-prose.json"
out="$(run_sup "$T/fx-prose.json")"
verdict="$(printf '%s' "$out" | tail -1 | jq -r '.verdict')"
assert_eq "$verdict" "halt" "JSON + trailing prose recovered as halt"

# 4. Prose + JSON at the end — the JSON should still be extracted from the tail.
{
  printf 'Reviewing the run... I saw many parked tickets. My verdict:\n\n'
  printf '{"verdict":"halt","haltReason":"systemic-broken"}\n'
} > "$T/fx-preamble.json"
out="$(run_sup "$T/fx-preamble.json")"
verdict="$(printf '%s' "$out" | tail -1 | jq -r '.verdict')"
assert_eq "$verdict" "halt" "leading prose + trailing JSON recovered as halt"

# 5. Truly-unparseable garbage — fail-open to ok BUT emit the loud log line + tag unparseable:true.
printf 'this is just prose with no JSON at all — some verdict-shaped noise\n' > "$T/fx-garbage.json"
out="$(run_sup "$T/fx-garbage.json")"
verdict="$(printf '%s' "$out" | tail -1 | jq -r '.verdict')"
unpar="$(printf '%s' "$out" | tail -1 | jq -r '.unparseable // false')"
assert_eq "$verdict" "ok" "unparseable garbage fails open to ok (deliberate fallback)"
assert_eq "$unpar" "true" "unparseable=true tag surfaces the lost halt to callers"
assert_contains "$out" "supervisor verdict UNPARSEABLE" "unparseable path emits a loud log line"

assert_done
