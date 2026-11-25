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
#                      [--order-check 0|1]
#
#   --suite-dir DIR    Directory holding test-*.sh (default ./scripts/govern/test).
#   --hint FILE        Scheduling hint; default: slow-tests-first.txt beside this script.
#   --shard i/n        Run only the round-robin i-th partition of n over the order.
#   --jobs N           Run N tests concurrently (default 1 = sequential, CI's order).
#   --log-dir DIR      Where per-test logs go (default: a mktemp dir, kept on failure).
#                      With the order check on, the reversed pass logs to
#                      "<log-dir>-reversed" beside it.
#   --hub-context FILE Skip-accounting list (tools/hub-context-tests.txt). A test that
#     exits 77 (skip) here runs nowhere unless that list covers it, so with this flag
#     given every uncovered skip is a hard failure. Local runs omit the flag.
#   --order-check 0|1  After the canonical pass, run the SAME selection in REVERSED
#     order and fail when any test's verdict differs between the two passes: that
#     converts cross-test order dependence from "a worker notices on their machine"
#     into a guarded invariant. Doubles the run's wall clock. Default ON for a full
#     run (no --shard), OFF for a shard run (CI's shard job, where each partition
#     runs in its own job and the doubling would bill every PR).
#
# GOVERN_LABS_FILE (env, set by post-merge-check.sh): when it names an existing
# file, the run covers ONLY the listed test files (one name per line, no .sh
# suffix; over-selection is the caller's contract). A literal FULL line forces
# the whole set. Unknown names are skipped with a note; a file naming nothing
# that exists, or an empty file, falls back to the full suite (failing toward
# MORE validation). Unset/empty behaves as before. The coverage assertion is a
# full-run invariant and is skipped for a subset; the shard split, the order
# check and the no-orphans guard apply to a subset unchanged.
#
# Exit 0 = every selected test passed or skipped; exit 1 = one or more failures
# (each named, with its log path), a leaked background fixture (see the
# no-orphans guard below), a broken order/skip-accounting, or (order check on)
# a test whose verdict depends on run order.
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
  local shard="" shards="" jobs=1 log_dir="" hub_context="" order_check="" rev_log=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --suite-dir)   suite_dir="$2"; shift 2 ;;
      --hint)        hint="$2"; shift 2 ;;
      --shard)       shard="${2%%/*}"; shards="${2##*/}"; shift 2 ;;
      --jobs)        jobs="$2"; shift 2 ;;
      --log-dir)     log_dir="$2"; shift 2 ;;
      --hub-context) hub_context="$2"; shift 2 ;;
      --order-check) order_check="$2"; shift 2 ;;
      -h|--help)     usage; return 0 ;;
      *) echo "unknown flag: $1" >&2; usage >&2; return 2 ;;
    esac
  done

  [ -d "$suite_dir" ] || { echo "::error::suite dir not found: $suite_dir" >&2; return 2; }

  # The runner owns the environment tests inherit. META_ROOT is the one
  # non-GOVERN export a parent govern script leaks into a run (lib/common.sh
  # pins it for its own children at source time): inherited past that, a fixture
  # workspace's `META_ROOT="${META_ROOT:-$T}"` default loses and probe lookups
  # and pending-sync markers resolve against the OUTER workspace. assert.sh
  # sweeps the same knob per test; this covers the run before any test starts.
  unset META_ROOT

  # Default: ON for a full run, OFF for a shard run; an explicit value always wins.
  if [ -z "$order_check" ]; then
    if [ -n "$shard" ]; then order_check=0; else order_check=1; fi
  fi
  case "$order_check" in
    0|1) ;;
    *) echo "::error::--order-check takes 0 or 1, got: $order_check" >&2; return 2 ;;
  esac

  local tmp order selected
  tmp="$(mktemp -d)"
  order="$tmp/order.txt"
  selected="$tmp/selected.txt"

  # GOVERN_LABS_FILE subset mode (see the header): narrow the run to the listed
  # test files. The result is written into the same $order file every downstream
  # step (shard split, order check, summary) already consumes.
  local labs_file="${GOVERN_LABS_FILE:-}" subset=0 lab
  if [ -n "$labs_file" ] && [ -f "$labs_file" ]; then
    if grep -qx 'FULL' "$labs_file"; then
      echo "labs file: FULL line, running the whole suite"
    else
      grep -v '^[[:space:]]*$' "$labs_file" > "$tmp/labs-raw.txt"
      [ -s "$tmp/labs-raw.txt" ] && subset=1
    fi
  fi
  if [ "$subset" -eq 1 ]; then
    : > "$order"
    while IFS= read -r lab; do
      if [ -f "$suite_dir/$lab.sh" ]; then
        printf '%s\n' "$lab" >> "$order"
      else
        echo "labs file: no test named $lab in $suite_dir, skipped" >&2
      fi
    done < "$tmp/labs-raw.txt"
    if [ -s "$order" ]; then
      echo "labs subset: $(wc -l < "$order" | tr -d ' ') test(s) from GOVERN_LABS_FILE"
    else
      echo "labs file named no test in $suite_dir, falling back to the full suite"
      subset=0
    fi
  fi
  if [ "$subset" -eq 0 ]; then
    build_order "$suite_dir" "$hint" "$order" || return 1
    assert_coverage "$suite_dir" "$order" || return 1
  fi

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

  run_one() { # <name> <log_dir>
    local name="$1" ld="$2" rc=0
    bash "$suite_dir/$name.sh" > "$ld/$name.log" 2>&1 || rc=$?
    printf '%s\n' "$rc" > "$ld/$name.rc"
    sweep_orphans "$name" "$ld"
    return 0
  }

  # ── no-orphans guard ────────────────────────────────────────────────────────
  # A test that leaks a background fixture (a fleet-monitor, a long-sleep stub)
  # holds its stdout pipe open: a runner that captures test output via command
  # substitution then blocks on the orphan, not the test, so the suite hangs.
  # After each test file, sweep for fixture processes whose parent is gone
  # (re-parented to init), kill them, and fail the run on any survivor the suite
  # itself created. Only pids NEW since this invocation started are counted, so a
  # stray that predates the run never blames a test. A leak is recorded as
  # <name>.orphans beside the rc file: run_one runs in a subshell when --jobs > 1,
  # so records cannot travel through shell variables. GOVERN_SUITE_NO_ORPHANS=0
  # disables the guard (escape hatch, never needed on a clean host).
  orphans_now() { # -> newline-separated sorted pids of orphaned fixture processes
    local p ppid
    for p in $(pgrep -f "$orphans_pat" 2>/dev/null); do
      ppid="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
      [ "$ppid" = "1" ] || continue
      printf '%s\n' "$p"
    done | sort -u
    return 0
  }
  sweep_orphans() { # <name> <log_dir>
    local name="$1" ld="$2" now new p
    [ "${GOVERN_SUITE_NO_ORPHANS:-1}" = "1" ] || return 0
    now="$(orphans_now)"
    new="$(comm -13 <(printf '%s' "$base_orphans") <(printf '%s' "$now"))"
    [ -n "$new" ] || return 0
    # Plain TERM is enough: a fleet-monitor kills its own tail child on TERM, and
    # a sleep stub dies directly. No lib/common.sh here on purpose: it sources the
    # workspace config at source time, which a fixture suite dir cannot provide.
    for p in $new; do kill "$p" 2>/dev/null || true; done
    printf '%s\n' "$new" > "$ld/$name.orphans"
    printf 'leaked background fixture process(es), killed by the no-orphans guard:\n%s\n' "$new" >> "$ld/$name.log"
    return 0
  }
  local base_orphans orphans_pat
  # The monitor half of the pattern is anchored on THIS suite's hub root: several
  # suites (parallel workers on one host) can run at once, and an unanchored
  # 'fleet-monitor.sh' match would blame this run for a sibling's leak. Long-sleep
  # stubs carry no path, so they stay matched unanchored.
  orphans_pat='sleep [0-9]{3,}'
  case "$suite_dir" in
    */scripts/govern/test)  orphans_pat="${suite_dir%/scripts/govern/test}/tools/fleet-monitor\.sh|$orphans_pat" ;;
    */templates/govern/test) orphans_pat="${suite_dir%/templates/govern/test}/tools/fleet-monitor\.sh|$orphans_pat" ;;
  esac
  base_orphans="$(orphans_now)"

  run_pass() { # <selected_file> <log_dir> <count:1 canonical, 0 reversed>
    local sel="$1" ld="$2" inc="$3" name p alive
    if [ "$jobs" -gt 1 ]; then
      # Portable slot control (no `wait -n`, which macOS's stock bash 3.2 lacks):
      # hold at most $jobs background PIDs, poll with kill -0, reap by dropping the
      # dead ones; the final `wait` drains the rest. Each test's real status lands
      # in its .rc file, so exit codes are never read off the `wait`s.
      local pids=() newpids=()
      while IFS= read -r name; do
        [ "$inc" = "1" ] && total=$((total + 1))
        run_one "$name" "$ld" &
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
      done < "$sel"
      wait
    else
      while IFS= read -r name; do
        [ "$inc" = "1" ] && total=$((total + 1))
        run_one "$name" "$ld"
      done < "$sel"
    fi
    return 0
  }

  run_pass "$selected" "$log_dir" 1

  # ── order-independence check ────────────────────────────────────────────────
  # A test green in canonical order and red (or skipped, or vice versa) in
  # reversed order is reading state another test left behind. Running the SAME
  # selection in REVERSED order and comparing verdicts turns that from a
  # once-noticed machine-local flake into a guarded invariant of every full run.
  if [ "$order_check" = "1" ]; then
    local rev_log="${log_dir}-reversed"
    mkdir -p "$rev_log"
    awk '{ a[NR] = $0 } END { for (i = NR; i >= 1; i--) print a[i] }' "$selected" > "$tmp/selected-rev.txt"
    echo "order-check: running the same selection in reversed order (logs: $rev_log)"
    run_pass "$tmp/selected-rev.txt" "$rev_log" 0
    local rev_passed=0 rev_failed=0 rev_skipped=0 rname rrc mismatch=0 rc1 rc2
    while IFS= read -r rname; do
      rrc="$(cat "$rev_log/$rname.rc")"
      if [ "$rrc" -eq 0 ]; then rev_passed=$((rev_passed + 1))
      elif [ "$rrc" -eq 77 ]; then rev_skipped=$((rev_skipped + 1))
      else rev_failed=$((rev_failed + 1)); fi
      rc1="$(cat "$log_dir/$rname.rc")"
      if [ "$rc1" != "$rrc" ]; then
        echo "::error::order-dependent test: $rname verdict differs canonical=$rc1 reversed=$rrc (logs: $log_dir/$rname.log, $rev_log/$rname.log)"
        mismatch=$((mismatch + 1))
      fi
    done < "$selected"
    echo "order-check reversed pass: passed=$rev_passed  failed=$rev_failed  skipped=$rev_skipped"
    [ "$mismatch" -eq 0 ] || return 1
    echo "ok - order check: every verdict identical in both orders"
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

  # Orphan attribution: any <name>.orphans file is a fixture leak the guard caught
  # and killed; it fails the run, named, no matter what the test's own rc said.
  local orphaned=0 of
  for of in "$log_dir"/*.orphans ${rev_log:+"$rev_log"/*.orphans}; do
    [ -f "$of" ] || continue
    orphaned=$((orphaned + 1))
    echo "::error::$(basename "$of" .orphans) leaked background fixture process(es) (killed by the no-orphans guard): $(tr '\n' ' ' < "$of")"
  done

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
  [ "$orphaned" -eq 0 ] || return 1
  return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
  exit $?
fi
