#!/usr/bin/env bash
# bench/run.sh: the marketing benchmark driver (spec section 5).
#
# For every (backlog x arm x rep) cell: cut a fresh worktree of the backlog's pinned ref, run the
# arm, run each ticket's verify_cmd, and record one results.jsonl row per spawned session plus one
# rollup row for the cell.
#
# Usage:
#   bench/run.sh [--dry-run] [--backlogs DIR] [--backlog NAME]... [--arm NAME]... [--reps N]
#                [--run-id ID] [--out DIR]
#
#   --dry-run     zero network, zero spend. Canned result-event fixtures stand in for both arm
#                 shapes; everything downstream (verify, record, rollup, the cap) is the real path.
#   --backlogs    dir of <name>/backlog.jsonl (default bench/backlogs; bench/pilot-backlogs for
#                 the private candidate pool, which is gitignored and never pushed)
#   --backlog     restrict to this backlog; repeatable. Default: all of them.
#   --arm         restrict to this arm; repeatable. Default: vanilla shiploop.
#                 vanilla-fresh is the private variant of section 2 and is opt-in only.
#   --reps        repetitions per (backlog, arm) cell. Default 1.
#
# Rails, always on, never options (spec section 5):
#   BENCH_MAX_USD    (60) hard cap on API-rate total_cost_usd across the whole run. The driver
#                    stops dispatching past it and records the remaining cells as status "capped".
#                    Identical behavior on a subscription (caps quota burn) and on an API key
#                    (caps real spend), because total_cost_usd is API-list-rate denominated either
#                    way, which is also why the published number is a percentage (section 4).
#   BENCH_MAX_TURNS  per-session turn ceiling, when the running claude CLI supports --max-turns.
#                    Defaults are shape-specific: 200 for a vanilla backlog session, 80 per
#                    shiploop worker. Setting BENCH_MAX_TURNS overrides both. A run that hits the
#                    ceiling clears fewer tickets, so it records as failed-to-clear and the
#                    backlog drops out of the published set (section 3).
#   BENCH_MAX_SESSION_USD  the per-session dollar ceiling used INSTEAD of BENCH_MAX_TURNS when the
#                    CLI has no --max-turns (observed on claude 2.1.246, which ships
#                    --max-budget-usd in its place; see bench/METHODOLOGY.md). Applies to the
#                    shiploop arm's workers; default $5, sized for one ticket's worth of work,
#                    the dollar analogue of the 80-turn worker default. The vanilla arm's
#                    per-session cap is NOT this value: vanilla is one session doing the WHOLE
#                    backlog, so its cap is BENCH_MAX_USD (the run budget) directly — capping it
#                    at a flat per-ticket number would bind it far tighter than the shiploop arm
#                    and make a loss look real when it is only the rail. A vanilla session that
#                    hits its cap records status "capped" for the whole cell, never "resolved" or
#                    "failed": a budget-truncated run is not a completed comparison.
#
# Every function ends `return 0` and dependent locals are split across statements: a function whose
# LAST statement is a bare `[[ c ]] && cmd` returns the test's status and aborts the caller under
# `set -euo pipefail`, and `local a=x b="$a"` leaves b unbound.
set -euo pipefail

BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DRY_RUN=0
BACKLOG_DIR="$BENCH_DIR/backlogs"
OUT_ROOT="${BENCH_OUT_ROOT:-$BENCH_DIR/results}"
RUN_ID=""
REPS=1
SEL_BACKLOGS=()
SEL_ARMS=()

BENCH_MAX_USD="${BENCH_MAX_USD:-60}"
BENCH_TURNS_VANILLA="${BENCH_MAX_TURNS:-200}"
BENCH_TURNS_WORKER="${BENCH_MAX_TURNS:-80}"
BENCH_CLAUDE_BIN="${BENCH_CLAUDE_BIN:-claude}"
# Per-session dollar ceiling, the --max-budget-usd fallback for a CLI with no --max-turns.
# Asymmetric by design (see the usage header above): vanilla's cap is the WHOLE run budget because
# it is one session doing the whole backlog; the worker default is a flat, documented dollar figure.
BENCH_SESSION_USD_WORKER="${BENCH_MAX_SESSION_USD:-5}"
BENCH_SESSION_USD_VANILLA="$BENCH_MAX_USD"
export BENCH_TURNS_VANILLA BENCH_TURNS_WORKER BENCH_CLAUDE_BIN BENCH_SESSION_USD_WORKER BENCH_SESSION_USD_VANILLA

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)  DRY_RUN=1 ;;
    --backlogs) BACKLOG_DIR="$2"; shift ;;
    --backlog)  SEL_BACKLOGS+=("$2"); shift ;;
    --arm)      SEL_ARMS+=("$2"); shift ;;
    --reps)     REPS="$2"; shift ;;
    --run-id)   RUN_ID="$2"; shift ;;
    --out)      OUT_ROOT="$2"; shift ;;
    -h|--help)  sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)          bench::die "unknown argument: $1" ;;
  esac
  shift
done

[[ "${#SEL_ARMS[@]}" -gt 0 ]] || SEL_ARMS=(vanilla shiploop)
[[ -n "$RUN_ID" ]] || RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"

# Absolutize --backlogs / --out NOW, before anything below can `cd` out from under a relative one.
# bench::arm_shiploop's subshell does `cd "$ws"` before re-reading the backlog file (to compute
# GOVERN_MAX_TICKETS); a relative --backlogs there silently resolves against $ws instead of the
# caller's cwd, jq fails to open it, the command substitution yields an empty string, and
# GOVERN_MAX_TICKETS collapses to run-loop.sh's own `${VAR:-0}` default — the loop dispatches ZERO
# tickets and exits clean, which reads exactly like a working run that happened to clear nothing.
BACKLOG_DIR="$(cd "$BACKLOG_DIR" && pwd)" || bench::die "--backlogs dir does not exist: $BACKLOG_DIR"
mkdir -p "$OUT_ROOT"
OUT_ROOT="$(cd "$OUT_ROOT" && pwd)"
# A bare `[[ c ]] && cmd` at statement position returns the TEST's status, and under
# `set -euo pipefail` a false test aborts the script. Every such pair in this file is an `if`.
if [[ "$DRY_RUN" -eq 1 ]]; then RUN_ID="${RUN_ID}-dry"; fi

RUN_DIR="$OUT_ROOT/$RUN_ID"
RESULTS="$RUN_DIR/results.jsonl"
BENCH_STATE_DIR="$RUN_DIR/state"
export BENCH_STATE_DIR
mkdir -p "$RUN_DIR" "$BENCH_STATE_DIR"
: > "$RESULTS"

# record.sh also defines bench::log / bench::die, so it must be sourced before anything speaks.
# shellcheck source=./record.sh
source "$BENCH_DIR/record.sh"
bench::load_govern_lib "$BENCH_STATE_DIR"
# shellcheck source=./arms.sh
source "$BENCH_DIR/arms.sh"

command -v jq >/dev/null 2>&1 || bench::die "jq is required"

# CLI version is recorded on every row so the published sentence can name it (section 4). A dry run has no
# CLI to ask, and inventing one would put a false version next to real-looking numbers.
if [[ "$DRY_RUN" -eq 1 ]]; then
  CLI_VERSION="dry-run"
  MODEL_NAME="dry-run"
else
  CLI_VERSION="$("$BENCH_CLAUDE_BIN" --version 2>/dev/null | head -1 || true)"
  [[ -n "$CLI_VERSION" ]] || CLI_VERSION="unknown"
  MODEL_NAME="${BENCH_MODEL_LABEL:-default}"
fi

# ── backlog discovery ───────────────────────────────────────────────────────
# A backlog is <dir>/<name>/backlog.jsonl, one JSON object per line:
#   {id, repo, ref, title, body, verify_cmd, kind, upstream_pr}
# See bench/backlogs/SCHEMA.md. Malformed lines are a hard stop, not a skip: a silently dropped
# ticket makes both arms cheaper and the ratio meaningless.
bench::discover_backlogs() { # -> names on stdout, one per line
  local d n
  for d in "$BACKLOG_DIR"/*/; do
    [[ -f "$d/backlog.jsonl" ]] || continue
    n="$(basename "$d")"
    if [[ "${#SEL_BACKLOGS[@]}" -gt 0 ]]; then
      local want found=0
      for want in "${SEL_BACKLOGS[@]}"; do if [[ "$want" == "$n" ]]; then found=1; fi; done
      [[ "$found" -eq 1 ]] || continue
    fi
    printf '%s\n' "$n"
  done
  return 0
}

bench::validate_backlog() { # <backlog.jsonl>
  local f="$1" bad
  bad="$(jq -r 'select((.id//"")=="" or (.repo//"")=="" or (.ref//"")=="" or (.title//"")==""
                       or (.body//"")=="" or (.verify_cmd//"")==""
                       or (.test_patch//"")=="" or (.merge_sha//"")=="") | .id // "<no id>"' "$f" 2>&1 || true)"
  [[ -z "$bad" ]] || bench::die "backlog $f has ticket(s) missing required fields: $bad"
  # backlogs/fixture-backlog exists for the test suite and names a fixture:// repo that no clone can
  # reach. Catching it here turns a confusing git failure mid-run into one sentence up front, and
  # makes sure a fixture can never be counted toward a published backlog total.
  if [[ "$DRY_RUN" -ne 1 ]]; then
    local fixture
    fixture="$(jq -r 'select((.repo//"") | startswith("fixture://")) | .id' "$f" | head -1)"
    [[ -z "$fixture" ]] || bench::die "backlog $f is a TEST FIXTURE (repo fixture://). It only runs under --dry-run and is never part of the published set."
  fi
  return 0
}

# ── offline guard ───────────────────────────────────────────────────────────
# Non-negotiable (ticket #104): the shiploop arm runs the REAL governor loop, which opens PRs
# against whatever remote it can reach. Every clone this driver makes has its remote(s) stripped
# immediately, and nothing is allowed to spawn while any remote survives anywhere under the cell's
# workdir. BENCH_ALLOW_REMOTES=1 is the deliberate, documented escape hatch — no benchmark needs it.
bench::strip_remotes() { # <git-dir>
  local d="$1" r
  [[ -d "$d/.git" || -f "$d/.git" ]] || return 0
  while IFS= read -r r; do
    [[ -n "$r" ]] || continue
    git -C "$d" remote remove "$r" >/dev/null 2>&1 || true
  done < <(git -C "$d" remote 2>/dev/null)
  return 0
}

# Fail-closed in the style of bench::require_turn_ceiling (arms.sh): walk every `.git` under <root>
# (bounded depth — a scaffolded workspace nests a sub-repo a few levels down, never deep) and abort
# the whole run the instant one still carries a remote. Called before EITHER arm is allowed to
# spawn, per cell, so a stray remote can never slip in between checkout and dispatch.
bench::assert_offline() { # <root-dir>
  if [[ "${BENCH_ALLOW_REMOTES:-0}" == "1" ]]; then
    bench::log "offline guard: BENCH_ALLOW_REMOTES=1 — remotes NOT stripped/asserted. No published benchmark number may use this."
    return 0
  fi
  local gitdir d leftover
  while IFS= read -r gitdir; do
    d="${gitdir%/.git}"
    leftover="$(git -C "$d" remote 2>/dev/null || true)"
    [[ -z "$leftover" ]] || bench::die "offline guard: $d still has git remote(s): $leftover — refusing to spawn any arm. Set BENCH_ALLOW_REMOTES=1 to override (documented: no benchmark needs this)."
  done < <(find "$1" -maxdepth 6 -name .git 2>/dev/null)
  # A `gh` credential is host-scoped, not workspace-scoped: an authenticated `gh` on PATH can reach
  # a real repo via an explicit --repo regardless of this workspace's git state, so "zero remotes"
  # cannot by itself close that door. The shiploop arm never lets the real `gh` run at all (arms.sh
  # shadows it on PATH with a purely-local shim — see bench::install_local_gh); GH_TOKEN /
  # GITHUB_TOKEN / GH_ENTERPRISE_TOKEN / GH_HOST / GH_REPO are additionally scrubbed from every
  # spawned session's environment (bench::spawn) so an ambient credential in the operator's shell
  # cannot flow through either arm. What is NOT closed, and is recorded as such in
  # bench/KNOWN-LIMITS.md: nothing here sandboxes raw network syscalls from a worker's Bash tool.
  return 0
}

# ── checkout ────────────────────────────────────────────────────────────────
# One fresh checkout of the pinned ref per cell, so no arm ever inherits another's commits. In a
# dry run there is no upstream to clone, so a git repo is synthesized locally: the arms never touch
# it (the fixtures stand in for their streams), but the verify step still runs for real inside it.
bench::prepare_workdir() { # <backlog.jsonl> <cell-id> -> path on stdout
  local backlog="$1" cell="$2" wd repo ref
  wd="$BENCH_STATE_DIR/wd-$cell"
  rm -rf "$wd"; mkdir -p "$wd"
  repo="$(jq -rs '.[0].repo' "$backlog")"
  ref="$(jq -rs '.[0].ref' "$backlog")"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    (
      cd "$wd"
      git init -q
      printf 'bench dry-run checkout of %s@%s\n' "$repo" "$ref" > README.md
      git -c user.email=bench@local -c user.name=bench add -A
      git -c user.email=bench@local -c user.name=bench commit -qm "bench fixture checkout"
    )
  else
    git clone -q "$repo" "$wd"
    bench::strip_remotes "$wd"
    # -B, not a bare checkout: the governor's worktree base-ref fallback (no origin ⇒ branch off
    # local `main`, templates/worktree/lib/base-ref.sh) must resolve to the BACKLOG'S PINNED ref,
    # not whatever `main` the clone happened to carry. Forcing the local `main` branch onto $ref
    # (whether $ref names a branch, tag, or bare SHA) makes that fallback correct instead of merely
    # not-crashing.
    ( cd "$wd" && git checkout -q -B main "$ref" )
    # A `git clone` of a LOCAL path (the common case: mining a backlog from a repo already on this
    # machine) brings every OTHER ref along too — branches, remote-tracking refs, AND TAGS — fully
    # reachable with `git log --all` / `git branch -a` / `git tag`, including, if the backlog's
    # source repo is still under active development, commits made AFTER the merge this ticket was
    # mined from (a release tag cut after the fix is exactly such a ref). That is a direct leak of
    # the answer: an arm never needs to solve the bug if it can `git show` the real fix. Deleting
    # EVERY ref except `refs/heads/main` and expiring the reflog closes the practical leak — an arm
    # would need to already know the future commit's exact SHA to reach it as a dangling object, not
    # merely list it. `git gc` then removes the now-unreachable objects outright.
    (
      cd "$wd"
      while IFS= read -r _r; do
        [[ -n "$_r" && "$_r" != "refs/heads/main" ]] || continue
        git update-ref -d "$_r" >/dev/null 2>&1 || true
      done < <(git for-each-ref --format='%(refname)')
      git reflog expire --expire=now --all >/dev/null 2>&1 || true
      git gc --prune=now --quiet >/dev/null 2>&1 || true
    )
    bench::assert_offline "$wd"
  fi
  printf '%s\n' "$wd"
  return 0
}

# ── verify ──────────────────────────────────────────────────────────────────
# Mechanical oracle, no LLM judging (section 3), SWE-bench style.
#
# THE ORDERING IS THE CONTRACT. `verify_cmd` is the test the merged upstream PR made pass, which
# means at the pinned `ref` that test DOES NOT EXIST: the PR added it. The arm is told only the
# problem, never the test file and never the case name, so it can never reproduce that name on its
# own. Verifying against the ref's tree would therefore fail every ticket in BOTH arms and drop
# every backlog. So the golden `test_patch` (test-file changes only, no source) is applied HERE, on
# the tree the arm produced, and only then does `verify_cmd` run.
#
# The arm session never sees test_patch, merge_sha, or upstream_pr. It receives title and body
# verbatim and nothing else, which is what keeps the ticket text byte-identical across arms and
# leaves the treatment arm no hint.
#
# If `git apply` fails, the arm edited a test file the patch touches. That records the sentinel
# below and the ticket is unresolved. No 3-way merge, no fuzzy apply, no --reject: silently
# repairing the oracle is worse than failing it, because a repaired oracle produces a number that
# looks measured and is not.
BENCH_VERIFY_PATCH_FAILED=90

# Prints "<cleared> <total> <worstExit>" and writes one JSON line per ticket to <verify-ledger>,
# the private per-ticket record section 3 asks for.
bench::verify_backlog() { # <backlog.jsonl> <workdir> <verify-ledger>
  local backlog="$1" wd="$2" ledger="$3"
  local cleared=0 total=0 worst=0 line id cmd patch rc applied
  : > "$ledger"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    total=$((total+1))
    id="$(printf '%s' "$line" | jq -r '.id')"
    cmd="$(printf '%s' "$line" | jq -r '.verify_cmd')"
    patch="$(printf '%s' "$line" | jq -r '.test_patch')"
    applied=false
    rc=0
    # Exact apply only. `git apply` does not fuzz by default, and nothing here adds -3 or --reject.
    # `printf '%s\n'`, not '%s': command substitution strips the trailing newline off $patch, and a
    # diff without its final newline is "corrupt patch at line N" to git apply. That failure is
    # indistinguishable from a genuine conflict, so it would silently sentinel every ticket in both
    # arms and drop every backlog for a reason that has nothing to do with the arms.
    if printf '%s\n' "$patch" | ( cd "$wd" && git apply - ) >/dev/null 2>&1; then
      applied=true
      ( cd "$wd" && eval "$cmd" ) >/dev/null 2>&1 || rc=$?
    else
      rc="$BENCH_VERIFY_PATCH_FAILED"
      bench::log "verify $id: the golden test_patch did NOT apply to the arm's tree (sentinel $rc); ticket recorded unresolved"
    fi
    if [[ "$rc" -eq 0 ]]; then cleared=$((cleared+1)); else worst="$rc"; fi
    jq -nc --arg id "$id" --argjson applied "$applied" --argjson exit "$rc" \
      '{ticket:$id, patchApplied:$applied, verifyExit:$exit, cleared:($exit == 0)}' >> "$ledger"
  done < <(jq -c '.' "$backlog")
  printf '%s %s %s\n' "$cleared" "$total" "$worst"
  return 0
}

# ── dry-run arm stand-ins ───────────────────────────────────────────────────
# Canned `"type":"result"` events for both arm shapes. The vanilla shape is ONE stream; the
# shiploop shape is a driver stream plus one worker stream per ticket, which is what makes the
# multi-session fold in record.sh a real code path in a dry run rather than a special case.
bench::dry_arm() { # <arm> <backlog.jsonl> <logdir> <backlog-name>
  local arm="$1" backlog="$2" logdir="$3" name="$4"
  local fx="$BENCH_DIR/fixtures"
  local i=0 id
  case "$arm" in
    vanilla)
      cp "$fx/vanilla-session.jsonl" "$logdir/01-$name.jsonl"
      ;;
    vanilla-fresh)
      while IFS= read -r id; do
        i=$((i+1))
        cp "$fx/shiploop-worker.jsonl" "$(printf '%s/%02d-%s.jsonl' "$logdir" "$i" "$id")"
      done < <(jq -r '.id' "$backlog")
      ;;
    shiploop)
      cp "$fx/shiploop-driver.jsonl" "$logdir/01-driver.jsonl"
      while IFS= read -r id; do
        i=$((i+1))
        cp "$fx/shiploop-worker.jsonl" "$(printf '%s/%02d-worker-%s.jsonl' "$logdir" "$((i+1))" "$id")"
      done < <(jq -r '.id' "$backlog")
      ;;
    *) bench::die "unknown arm: $arm" ;;
  esac
  return 0
}

bench::run_arm() { # <arm> <workdir> <backlog.jsonl> <logdir> <backlog-name>
  local arm="$1" wd="$2" backlog="$3" logdir="$4" name="$5"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    bench::dry_arm "$arm" "$backlog" "$logdir" "$name"
    return 0
  fi
  case "$arm" in
    vanilla)       bench::arm_vanilla       "$wd" "$backlog" "$logdir" "$name" ;;
    vanilla-fresh) bench::arm_vanilla_fresh "$wd" "$backlog" "$logdir" "$name" ;;
    shiploop)      bench::arm_shiploop      "$wd" "$backlog" "$logdir" "$name" ;;
    *) bench::die "unknown arm: $arm" ;;
  esac
  return 0
}

# ── the cap ─────────────────────────────────────────────────────────────────
# Compared BEFORE dispatching a cell, never mid-session: a session cannot be un-spent, and the
# honest thing to cap is what has not been started yet.
bench::over_cap() { # -> rc 0 when the run has already spent its budget
  local spent
  local rc=0
  spent="$(bench::spent_usd "$RESULTS")"
  awk -v s="$spent" -v c="$BENCH_MAX_USD" 'BEGIN { exit !(s >= c) }' || rc=$?
  return "$rc"
}

# A capped cell still gets rows, so results.jsonl is a complete record of the run: one rollup with
# status "capped", zero sessions, null cost. Nothing about it can be mistaken for a measurement.
bench::record_capped_cell() { # <backlog> <arm> <rep> <ticketCount>
  local backlog="$1" arm="$2" rep="$3" total="$4"
  bench::record_rollup "$RESULTS" "$RUN_ID" "$backlog" "$arm" "$rep" "capped" 0 "$total" 0 \
    "$(date +%s)"
  return 0
}

# ── main loop ───────────────────────────────────────────────────────────────
backlogs=()
while IFS= read -r n; do backlogs+=("$n"); done < <(bench::discover_backlogs)
[[ "${#backlogs[@]}" -gt 0 ]] || bench::die "no backlogs found under $BACKLOG_DIR"

bench::log "run $RUN_ID: ${#backlogs[@]} backlog(s) x ${#SEL_ARMS[@]} arm(s) x $REPS rep(s), cap \$$BENCH_MAX_USD"

capped=0
for name in "${backlogs[@]}"; do
  backlog_file="$BACKLOG_DIR/$name/backlog.jsonl"
  bench::validate_backlog "$backlog_file"
  ticket_count="$(jq -s 'length' "$backlog_file")"
  for arm in "${SEL_ARMS[@]}"; do
    for (( rep=1; rep<=REPS; rep++ )); do
      cell="$name-$arm-$rep"
      if [[ "$capped" -eq 1 ]] || bench::over_cap; then
        capped=1
        bench::log "cell $cell: SKIPPED, BENCH_MAX_USD=\$$BENCH_MAX_USD reached"
        bench::record_capped_cell "$name" "$arm" "$rep" "$ticket_count"
        continue
      fi
      logdir="$RUN_DIR/sessions/$cell"
      mkdir -p "$logdir"
      started="$(date +%s)"
      workdir="$(bench::prepare_workdir "$backlog_file" "$cell")"
      bench::run_arm "$arm" "$workdir" "$backlog_file" "$logdir" "$name"
      # NOT inside $logdir: record_sessions globs every *.jsonl there as a claude session stream,
      # so a ledger written beside the streams would be recorded as an extra zero-cost session.
      mkdir -p "$RUN_DIR/verify"
      read -r cleared total worst < <(bench::verify_backlog "$backlog_file" "$workdir" "$RUN_DIR/verify/$cell.jsonl")
      wall_ms=$(( ( $(date +%s) - started ) * 1000 ))
      if [[ "$cleared" -eq "$total" ]]; then status="resolved"; else status="failed"; fi
      # A session cut off by its OWN per-session ceiling (--max-turns / --max-budget-usd) never
      # gets to be a completed comparison, even if it happened to clear every ticket anyway: the
      # cap decided how far it got, not the arm. Overrides resolved/failed to "capped" so the
      # rollup drops it from the published set the same way a run-level BENCH_MAX_USD cap does.
      if bench::cell_hit_session_cap "$logdir"; then
        status="capped"
        bench::log "cell $cell: a session hit its per-session ceiling mid-run; forcing status=capped"
      fi
      sessions="$(bench::record_sessions "$logdir" "$RESULTS" "$RUN_ID" "$name" "$arm" "$rep" \
        "$MODEL_NAME" "$CLI_VERSION" "$status" "$worst" "$wall_ms" "$started" "$cleared" "$total")"
      bench::record_rollup "$RESULTS" "$RUN_ID" "$name" "$arm" "$rep" "$status" \
        "$cleared" "$total" "$wall_ms" "$started"
      bench::log "cell $cell: $status, $cleared/$total cleared, $sessions session(s), spent \$$(bench::spent_usd "$RESULTS")"
    done
  done
done

bench::log "results: $RESULTS"
bench::log "total recorded cost: \$$(bench::spent_usd "$RESULTS")"
