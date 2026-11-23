#!/usr/bin/env bash
# Run the govern test suite with the same semantics CI's shard job uses.
#
# One definition of the run order: tests listed in tools/slow-tests-first.txt
# that still exist (slowest first, a scheduling hint only), then every remaining
# test-*.sh alphabetically. A stale hint entry is skipped, an unlisted test lands
# in the tail, so the built order is always the complete suite; it is asserted
# to cover every test file exactly once so a shard split cannot silently drop
# coverage.
#
# Usage:
#   tools/run-suite.sh [--suite-dir DIR] [--hint FILE] [--shard i/n]
#                      [--jobs N] [--log-dir DIR] [--hub-context FILE]
#
#   --suite-dir DIR    Directory holding test-*.sh (default ./scripts/govern/test).
#   --hint FILE        Scheduling hint; default: slow-tests-first.txt beside this script.
#   --shard i/n        Run only the round-robin i-th partition of n over the order.
#   --jobs N           Run N tests concurrently (default 1 = sequential, CI's order).
#   --log-dir DIR      Where per-test logs go (default: a mktemp dir, kept on failure).
#   --hub-context FILE Skip-accounting list (tools/hub-context-tests.txt). A test that
#     exits 77 (skip) here runs nowhere unless that list covers it, so with this flag
#     given every uncovered skip is a hard failure. Local runs omit the flag.
#
# Exit 0 = every selected test passed or skipped; exit 1 = one or more failures
# (each named, with its log path) or a broken order/skip-accounting.
#
# Tests may source this file to call build_order / assert_coverage / select_shard
# against fixtures: sourcing defines the functions and runs nothing (the main
# entry only fires when executed directly).

set -uo pipefail

usage() { grep '^#   --' "$0" | sed 's/^# //'; }

build_order() { # <suite_dir> <hint_file> <out_file>
  local suite_dir="$1" hint="$2" out="$3" n
  : > "$out"
  if [ -f "$hint" ]; then
    while IFS= read -r n; do
      case "$n" in ''|\#*) continue ;; esac
      # NOT `[ -f x ] && printf`: under `set -e` a stale hint entry would make
      # this statement return 1 and abort the caller.
      if [ -f "$suite_dir/$n.sh" ]; then
        printf '%s\n' "$n" >> "$out"
      fi
    done < "$hint"
  fi
  # Tail: every test file the hint did not already name, alphabetically.
  local t
  for t in "$suite_dir"/test-*.sh; do
    [ -f "$t" ] || continue
    n="$(basename "$t" .sh)"
    grep -qxF "$n" "$out" || printf '%s\n' "$n" >> "$out"
  done
  return 0
}

assert_coverage() { # <suite_dir> <order_file>
  local suite_dir="$1" order="$2" n_files n_order n_lines
  n_files="$(ls "$suite_dir"/test-*.sh 2>/dev/null | wc -l | tr -d ' ')"
  n_order="$(sort -u "$order" | wc -l | tr -d ' ')"
  n_lines="$(wc -l < "$order" | tr -d ' ')"
  if [ "$n_order" != "$n_files" ] || [ "$n_lines" != "$n_files" ]; then
    echo "::error::shard order covers $n_order unique / $n_lines lines but there are $n_files test files" >&2
    return 1
  fi
  echo "ok - order covers all $n_files tests"
  return 0
}

select_shard() { # <order_file> <i> <n> <out_file>
  local order="$1" shard="$2" shards="$3" out="$4" idx=0
  : > "$out"
  while IFS= read -r name; do
    idx=$((idx + 1))
    [ "$(( (idx - 1) % shards + 1 ))" -eq "$shard" ] || continue
    printf '%s\n' "$name" >> "$out"
  done < "$order"
  return 0
}

# ── main ─────────────────────────────────────────────────────────────────────
main() {
  local suite_dir="scripts/govern/test"
  local hint
  hint="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/slow-tests-first.txt"
  local shard="" shards="" jobs=1 log_dir="" hub_context=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --suite-dir)   suite_dir="$2"; shift 2 ;;
      --hint)        hint="$2"; shift 2 ;;
      --shard)       shard="${2%%/*}"; shards="${2##*/}"; shift 2 ;;
      --jobs)        jobs="$2"; shift 2 ;;
      --log-dir)     log_dir="$2"; shift 2 ;;
      --hub-context) hub_context="$2"; shift 2 ;;
      -h|--help)     usage; return 0 ;;
      *) echo "unknown flag: $1" >&2; usage >&2; return 2 ;;
    esac
  done

  [ -d "$suite_dir" ] || { echo "::error::suite dir not found: $suite_dir" >&2; return 2; }

  local tmp order selected
  tmp="$(mktemp -d)"
  order="$tmp/order.txt"
  selected="$tmp/selected.txt"

  build_order "$suite_dir" "$hint" "$order" || return 1
  assert_coverage "$suite_dir" "$order" || return 1

  if [ -n "$shard" ]; then
    case "$shard" in ''|*[!0-9]*) echo "::error::bad shard index: $shard" >&2; return 2 ;; esac
    case "$shards" in ''|*[!0-9]*) echo "::error::bad shard count: $shards" >&2; return 2 ;; esac
    [ "$shard" -ge 1 ] && [ "$shard" -le "$shards" ] || { echo "::error::shard $shard out of range 1..$shards" >&2; return 2; }
    select_shard "$order" "$shard" "$shards" "$selected"
    echo "shard $shard/$shards: $(wc -l < "$selected" | tr -d ' ') test(s)"
  else
    cp "$order" "$selected"
  fi

  if [ -z "$log_dir" ]; then
    log_dir="$tmp/logs"
  fi
  mkdir -p "$log_dir"

  # status files: one per test, <name>.rc
  local passed=0 failed=0 skipped=0 total=0
  local fails=() skips=()

  run_one() { # <name>
    local name="$1" rc=0
    bash "$suite_dir/$name.sh" > "$log_dir/$name.log" 2>&1 || rc=$?
    printf '%s\n' "$rc" > "$log_dir/$name.rc"
    return 0
  }

  if [ "$jobs" -gt 1 ]; then
    # Portable slot control (no `wait -n`, which macOS's stock bash 3.2 lacks):
    # hold at most $jobs background PIDs, poll with kill -0, reap by dropping the
    # dead ones; the final `wait` drains the rest. Each test's real status lands
    # in its .rc file, so exit codes are never read off the `wait`s.
    local name pids=() p alive newpids=()
    while IFS= read -r name; do
      total=$((total + 1))
      run_one "$name" &
      pids+=("$!")
      while [ "${#pids[@]}" -ge "$jobs" ]; do
        alive=0
        newpids=()
        for p in ${pids[@]+"${pids[@]}"}; do
          if kill -0 "$p" 2>/dev/null; then
            alive=$((alive + 1))
            newpids+=("$p")
          fi
        done
        # Not `pids=("${newpids[@]}")`: with newpids empty, unquoted expansion
        # of a possibly-empty array is what stays unbound-safe on bash 3.2.
        pids=(${newpids[@]+"${newpids[@]}"})
        if [ "$alive" -ge "$jobs" ]; then
          sleep 0.2
        fi
      done
    done < "$selected"
    wait
  else
    local name rc
    while IFS= read -r name; do
      total=$((total + 1))
      run_one "$name"
    done < "$selected"
  fi

  # Summary: one line per test, in order (logs hold the full output either way).
  while IFS= read -r name; do
    rc="$(cat "$log_dir/$name.rc")"
    if [ "$rc" -eq 0 ]; then
      passed=$((passed + 1))
      echo "ok   - $name"
    elif [ "$rc" -eq 77 ]; then
      skipped=$((skipped + 1))
      skips+=("$name")
      echo "skip - $name (env not applicable)"
    else
      failed=$((failed + 1))
      fails+=("$name")
      echo "FAIL - $name"
    fi
  done < "$selected"

  echo ""
  echo "passed=$passed  failed=$failed  skipped=$skipped  total=$total  (logs: $log_dir)"

  if [ "$failed" -gt 0 ]; then
    local f
    for f in ${fails[@]+"${fails[@]}"}; do
      echo "::error::govern test failed: $f"
      echo "--- $f log (last 40 lines) ---"
      tail -40 "$log_dir/$f.log"
    done
  fi

  # A test that skips HERE runs nowhere unless the hub-context job picks it up.
  if [ -n "$hub_context" ]; then
    local unaccounted=0 s
    for s in ${skips[@]+"${skips[@]}"}; do
      # `!name` (quarantined) still counts as listed; strip the marker before matching.
      if ! sed 's/^!//' "$hub_context" | grep -qxF "$s"; then
        echo "::error::$s skipped here and is NOT in $hub_context: it runs in NO job. Add it there (and confirm it passes from a hub checkout)." >&2
        unaccounted=1
      fi
    done
    [ "$unaccounted" -eq 0 ] || return 1
    echo "ok - all $skipped skip(s) are covered by the hub-context list"
  fi

  [ "$failed" -eq 0 ] || return 1
  return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
  exit $?
fi
