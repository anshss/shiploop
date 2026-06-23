#!/usr/bin/env bash
# Tiny assertion helper for govern smoke tests.
set -euo pipefail
ASSERT_FAILS=0
assert_eq() { # actual expected message
  if [[ "$1" == "$2" ]]; then printf 'ok   - %s\n' "$3"
  else printf 'FAIL - %s\n       expected: [%s]\n       actual:   [%s]\n' "$3" "$2" "$1"; ASSERT_FAILS=$((ASSERT_FAILS+1)); fi
}
assert_contains() { # haystack needle message
  # Here-string (temp-file backed), NOT `printf … | grep`: under `set -o pipefail` a piped grep -qF
  # exits at the first match and closes the pipe, so printf takes SIGPIPE (141) on a haystack larger
  # than the OS pipe buffer (~16KB on macOS) → the pipeline returns 141 and a real match reads as a
  # spurious FAIL. A here-string has no pipe, so the check is deterministic regardless of size/load.
  if grep -qF "$2" <<<"$1"; then printf 'ok   - %s\n' "$3"
  else printf 'FAIL - %s\n       [%s] not found in output\n' "$3" "$2"; ASSERT_FAILS=$((ASSERT_FAILS+1)); fi
}
assert_done() { [[ "$ASSERT_FAILS" -eq 0 ]] || { printf '\n%d assertion(s) failed\n' "$ASSERT_FAILS"; exit 1; }; printf '\nall assertions passed\n'; }
