#!/usr/bin/env bash
# Unit test for govern::extract_report / govern::_json_objects (#66): a worker that did the work
# but emitted "JSON + trailing prose" must be parsed as its real status, not synthesized failed.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
mk_ws_stub "$(mktemp -d)"  # hermetic workspace stub (independent of the live workspace.sh) — seed before common.sh is sourced
# shellcheck source=../lib/common.sh
source "$DIR/../lib/common.sh"

# 1. Pure single object — the strict happy path — round-trips verbatim.
got="$(printf '%s' '{"status":"resolved","pr":null}' | govern::extract_report)"
assert_eq "$got" '{"status":"resolved","pr":null}' "pure JSON object passes through"

# 2. The exact #66 regression: valid JSON followed by trailing prose.
got="$(printf '%s' '{"status":"resolved","pr":{"repo":"alpha","number":116}}

Ticket #12 resolved. PR #116 is open and ready for review.' | govern::extract_report)"
assert_eq "$(printf '%s' "$got" | jq -r '.status')" "resolved" "JSON + trailing prose → real status"
assert_eq "$(printf '%s' "$got" | jq -r '.pr.number')" "116" "JSON + trailing prose → PR preserved"

# 3. Leading prose before the JSON object.
got="$(printf '%s' 'Here is my report:
{"status":"parked","pr":null}' | govern::extract_report)"
assert_eq "$(printf '%s' "$got" | jq -r '.status')" "parked" "leading prose + JSON → real status"

# 4. Prose containing non-JSON braces around the real object — only the status object is chosen.
got="$(printf '%s' 'I inspected {the config} first.
{"status":"resolved"}
All done {ok}.' | govern::extract_report)"
assert_eq "$(printf '%s' "$got" | jq -r '.status')" "resolved" "non-JSON braces ignored, status object chosen"

# 5. Pretty-printed multi-line JSON is one object.
got="$(printf '%s' '{
  "status": "resolved",
  "pr": { "repo": "beta", "number": 5 }
}' | govern::extract_report)"
assert_eq "$(printf '%s' "$got" | jq -r '.pr.repo')" "beta" "multi-line pretty JSON extracted whole"

# 6. Braces inside a string value must not confuse the scanner.
got="$(printf '%s' '{"status":"resolved","note":"has } and { inside"}' | govern::extract_report)"
assert_eq "$(printf '%s' "$got" | jq -r '.note')" "has } and { inside" "string-embedded braces handled"

# 7. Pure prose with no JSON → nothing extracted, non-zero return.
if printf '%s' 'Ticket resolved. PR is open.' | govern::extract_report >/dev/null 2>&1; then
  assert_eq "extracted" "nothing" "pure prose must yield no report"
else
  assert_eq "rc!=0" "rc!=0" "pure prose yields no report (non-zero return)"
fi

# 8. A brace object WITHOUT a status field is not a valid report.
if printf '%s' '{"pr":{"number":1}}' | govern::extract_report >/dev/null 2>&1; then
  assert_eq "extracted" "nothing" "object without status must be rejected"
else
  assert_eq "rc!=0" "rc!=0" "object without a status field is rejected"
fi

# 9. Two status objects → the LAST one wins.
got="$(printf '%s' '{"status":"failed"}
{"status":"resolved"}' | govern::extract_report)"
assert_eq "$(printf '%s' "$got" | jq -r '.status')" "resolved" "last status-bearing object wins"

assert_done
