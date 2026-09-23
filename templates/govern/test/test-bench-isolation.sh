#!/usr/bin/env bash
# bench: arm isolation (#163 item 11) — workdir root, cache isolation, --strict-mcp-config.
#
# Contract:
#   1. a cell's actual working directory (bench::prepare_workdir) lives under BENCH_WORKDIR_ROOT,
#      never under BENCH_STATE_DIR/OUT_ROOT — so a workspace's own root CLAUDE.md is never an
#      ancestor of an arm's cwd
#   2. the shiploop arm's scaffolded workspace (bench::scaffold_workspace) resolves under the SAME
#      BENCH_WORKDIR_ROOT when it is set, and falls back to BENCH_STATE_DIR for a standalone caller
#      that never set it (a unit test, same as before this ticket)
#   3. bench::isolation_env_args returns GOMODCACHE/GOPROXY/GOFLAGS/CARGO_HOME always, PATH only
#      when an isolated venv's python3 actually exists, and nothing at all when BENCH_ISOLATE=0
#   4. bench::resolve_strict_mcp_flag: --strict-mcp-config when the CLI supports it, empty (logged)
#      when it does not, and empty (logged, "disabled by operator") when BENCH_STRICT_MCP_CONFIG=0
#      regardless of support — optional isolation, never a hard stop
#   5. bench::verify_backlog runs verify_cmd with the SAME cache isolation an arm's own session gets
#   6. the run's own kind:"meta" row records which isolation was active
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

HUB="$(cd "$DIR/../../.." && pwd)"
[ -f "$HUB/bench/run.sh" ] && [ -f "$HUB/bench/arms.sh" ] || \
  { echo "SKIP: not running from a hub checkout ($HUB)" >&2; exit 77; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# ── 1. bench::prepare_workdir lives under BENCH_WORKDIR_ROOT, not OUT_ROOT ──────
out="$(BENCH_OUT_ROOT="$T/out" BENCH_WORKDIR_ROOT="$T/wdroot" bash "$HUB/bench/run.sh" --dry-run \
        --run-id iso --backlogs "$HUB/bench/backlogs" --backlog fixture-backlog 2>&1)"
assert_eq "$?" "0" "1. a dry run with an explicit BENCH_WORKDIR_ROOT still exits 0"
assert_eq "$(find "$T/wdroot/iso-dry" -maxdepth 1 -name 'wd-fixture-backlog-*' 2>/dev/null | wc -l | tr -d ' ')" \
  "2" "1. both cells' workdirs land under BENCH_WORKDIR_ROOT/<run-id>, one per (backlog, arm)"
assert_eq "$(find "$T/out" -name 'wd-fixture-backlog-*' 2>/dev/null | wc -l | tr -d ' ')" "0" \
  "1. and NONE land under OUT_ROOT (BENCH_STATE_DIR) any more"

# ── 2. bench::scaffold_workspace: same root when set, old fallback when not ─────
ws1="$(BENCH_STATE_DIR="$T/state" BENCH_WORKDIR_ROOT="$T/wdroot2" RUN_ID="probe" bash -c '
  source "'"$HUB"'/bench/record.sh"
  bench::load_govern_lib "'"$T"'/state"
  source "'"$HUB"'/bench/arms.sh"
  mkdir -p "'"$T"'/repo-src"
  bench::scaffold_workspace "'"$T"'/repo-src" probe bench
' 2>/dev/null | tail -1)"
assert_contains "$ws1" "$T/wdroot2/probe/ws-probe" \
  "2. with BENCH_WORKDIR_ROOT set, the scaffolded workspace resolves under it (+ RUN_ID)"

ws2="$(BENCH_STATE_DIR="$T/state2" bash -c '
  source "'"$HUB"'/bench/record.sh"
  bench::load_govern_lib "'"$T"'/state2"
  source "'"$HUB"'/bench/arms.sh"
  mkdir -p "'"$T"'/repo-src2"
  bench::scaffold_workspace "'"$T"'/repo-src2" probe2 bench
' 2>/dev/null | tail -1)"
assert_contains "$ws2" "$T/state2/ws-probe2" \
  "2. with NO BENCH_WORKDIR_ROOT set, a standalone caller keeps the old BENCH_STATE_DIR fallback"

# ── 3. bench::isolation_env_args ────────────────────────────────────────────────
args="$(BENCH_ISOLATE=1 BENCH_GOMODCACHE="$T/gomod" BENCH_CARGO_HOME="$T/cargo" \
        BENCH_VENV_DIR="$T/no-such-venv" bash -c '
  source "'"$HUB"'/bench/record.sh"
  bench::isolation_env_args
')"
assert_contains "$args" "GOMODCACHE=$T/gomod" "3. GOMODCACHE is set to the isolated cache dir"
assert_contains "$args" "GOPROXY=off" "3. GOPROXY=off, so a fetch fails rather than silently reaching the network"
assert_contains "$args" "GOFLAGS=-mod=mod" "3. GOFLAGS=-mod=mod"
assert_contains "$args" "CARGO_HOME=$T/cargo" "3. CARGO_HOME is set to the isolated cache dir"
assert_not_contains "$args" "PATH=" "3. no PATH override when the venv's python3 does not exist"

mkdir -p "$T/venv/bin"; printf '#!/bin/sh\n' > "$T/venv/bin/python3"; chmod +x "$T/venv/bin/python3"
args2="$(BENCH_ISOLATE=1 BENCH_GOMODCACHE="$T/gomod" BENCH_CARGO_HOME="$T/cargo" \
         BENCH_VENV_DIR="$T/venv" bash -c '
  source "'"$HUB"'/bench/record.sh"
  bench::isolation_env_args
')"
assert_contains "$args2" "PATH=$T/venv/bin:" "3. once the isolated venv exists, PATH is prepended with it"

args3="$(BENCH_ISOLATE=0 bash -c 'source "'"$HUB"'/bench/record.sh"; bench::isolation_env_args')"
assert_eq "$args3" "" "3. BENCH_ISOLATE=0 turns every isolation env var off, cleanly"

# ── 4. bench::resolve_strict_mcp_flag ───────────────────────────────────────────
flag="$(_GOVERN_STRICTMCP_SUPPORTED=1 bash -c '
  source "'"$HUB"'/bench/record.sh"
  bench::load_govern_lib "'"$T"'/state3"
  source "'"$HUB"'/bench/arms.sh"
  bench::resolve_strict_mcp_flag claude
  printf "[%s]" "$bench_strict_mcp_flag"
' 2>/dev/null)"
assert_eq "$flag" "[--strict-mcp-config]" "4. --strict-mcp-config is applied when the CLI supports it"

flag2="$(_GOVERN_STRICTMCP_SUPPORTED=0 bash -c '
  source "'"$HUB"'/bench/record.sh"
  bench::load_govern_lib "'"$T"'/state4"
  source "'"$HUB"'/bench/arms.sh"
  bench::resolve_strict_mcp_flag claude
  printf "[%s]" "$bench_strict_mcp_flag"
' 2>&1)"
assert_contains "$flag2" "[]" "4. an unsupported CLI degrades to no flag, never a hard stop"
assert_contains "$flag2" "does not support --strict-mcp-config" "4. and says so"

flag3="$(_GOVERN_STRICTMCP_SUPPORTED=1 BENCH_STRICT_MCP_CONFIG=0 bash -c '
  source "'"$HUB"'/bench/record.sh"
  bench::load_govern_lib "'"$T"'/state5"
  source "'"$HUB"'/bench/arms.sh"
  bench::resolve_strict_mcp_flag claude
  printf "[%s]" "$bench_strict_mcp_flag"
' 2>&1)"
assert_contains "$flag3" "[]" "4. BENCH_STRICT_MCP_CONFIG=0 omits the flag even on a supporting CLI"
assert_contains "$flag3" "disabled by operator" "4. and says it was the operator's own override"

# ── 5. verify_cmd runs under the SAME cache isolation an arm's own session gets ──
# Driven through a REAL `run.sh --dry-run` (bench::verify_backlog is defined inside run.sh itself,
# which unconditionally executes its whole pipeline when sourced — so a custom backlog whose own
# verify_cmd checks the env is the only way to observe this without duplicating the function).
mkdir -p "$T/isobacklogs/isobl" "$T/isovenv/bin"
printf '#!/bin/sh\n' > "$T/isovenv/bin/python3"; chmod +x "$T/isovenv/bin/python3"
jq -nc --arg cmd 'test "$GOMODCACHE" = "'"$T"'/gomod5" && test "$GOPROXY" = off && test "$GOFLAGS" = -mod=mod && test "$CARGO_HOME" = "'"$T"'/cargo5" && case ":$PATH:" in *":'"$T"'/isovenv/bin:"*) true;; *) false;; esac' \
  '{id:"iso1", repo:"fixture://iso", ref:"0000000000000000000000000000000000000000", title:"t", body:"b", verify_cmd:$cmd, kind:"bug"}' \
  > "$T/isobacklogs/isobl/backlog.jsonl"
out5="$(BENCH_OUT_ROOT="$T/out5" BENCH_GOMODCACHE="$T/gomod5" BENCH_CARGO_HOME="$T/cargo5" \
        BENCH_VENV_DIR="$T/isovenv" bash "$HUB/bench/run.sh" --dry-run --run-id iso5 \
        --backlogs "$T/isobacklogs" --backlog isobl 2>&1)"
assert_eq "$?" "0" "5. the dry run with the env-checking verify_cmd exits 0"
R5="$T/out5/iso5-dry/verify/isobl-vanilla-1.jsonl"
assert_eq "$(jq -r '.cleared' "$R5")" "true" \
  "5. verify_cmd saw the exact GOMODCACHE/GOPROXY/GOFLAGS/CARGO_HOME/PATH bench::verify_backlog sets"

# ── 6. the run's own kind:"meta" row records which isolation was active ────────
R="$T/out/iso-dry/results.jsonl"
meta="$(jq -c 'select(.kind=="meta")' "$R")"
assert_contains "$meta" '"active":true' "6. isolation.active is true by default"
assert_contains "$meta" '"settingSources":"project,local"' "6. and names the setting-sources value"
assert_contains "$meta" '"strictMcpConfig":"n/a (dry run)"' "6. a dry run never resolves the strict-mcp-config probe (nothing is spawned)"
assert_contains "$meta" "\"workdirRoot\":\"$T/wdroot\"" "6. and records the workdir root actually used"

out0="$(BENCH_OUT_ROOT="$T/out0" BENCH_ISOLATE=0 bash "$HUB/bench/run.sh" --dry-run --run-id iso0 \
        --backlogs "$HUB/bench/backlogs" --backlog fixture-backlog 2>&1)"
assert_eq "$?" "0" "6. BENCH_ISOLATE=0 still runs cleanly"
meta0="$(jq -c 'select(.kind=="meta")' "$T/out0/iso0-dry/results.jsonl")"
assert_contains "$meta0" '"active":false' "6. and the meta row records isolation as OFF, not silently on"

assert_done
