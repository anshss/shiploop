#!/usr/bin/env bash
# bench/run.sh: the marketing benchmark driver.
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
#                 vanilla-fresh is the private variant and is opt-in only.
#   --reps        repetitions per (backlog, arm) cell. Default 1.
#
# Rails, always on, never options:
#   BENCH_MAX_USD    (60) hard cap on API-rate total_cost_usd across the whole run. The driver
#                    stops dispatching past it and records the remaining cells as status "capped".
#                    Identical behavior on a subscription (caps quota burn) and on an API key
#                    (caps real spend), because total_cost_usd is API-list-rate denominated either
#                    way, which is also why the published number is a percentage.
#   BENCH_MAX_TURNS  per-session turn ceiling, when the running claude CLI supports --max-turns.
#                    Default 200, EQUAL on both arms (fairness rail 1 — section 5 of the design):
#                    each arm is now exactly one whole-backlog session, so there is no shape-specific
#                    reason left for one arm's ceiling to bind tighter than the other's. Non-binding
#                    by construction; a cell that hits it is forced to "capped", never counted as an
#                    ordinary loss.
#   BENCH_MAX_SESSION_USD  the per-session dollar ceiling used INSTEAD of BENCH_TURNS when the CLI
#                    has no --max-turns (observed on claude 2.1.246, which ships --max-budget-usd
#                    in its place; see bench/METHODOLOGY.md). Default equal to BENCH_MAX_USD (the
#                    whole run budget): since each arm is one whole-backlog session, its own cap is
#                    the run cap, the same way it always was for the vanilla arm. A session that
#                    hits its cap records status "capped" for the whole cell, never "resolved" or
#                    "failed": a budget-truncated run is not a completed comparison.
#   Smoke gate       a LIVE (non-dry) run bigger than one (backlog x rep) cell refuses to start
#                    unless BENCH_SMOKE_RUN=<run-id> names a prior results dir, recorded at this
#                    SAME hub git sha, whose every cell completed (status resolved or failed —
#                    never capped or another status) and whose shiploop cell(s) genuinely
#                    activated a worker. A run of exactly one backlog and one rep IS a smoke run
#                    and needs no gate. BENCH_SKIP_SMOKE_GATE=1 is the deliberate override,
#                    recorded into results.jsonl's own kind:"meta" row when used.
#   Infra-class error  a session whose final result event carries `is_error:true` for a reason other
#                    than its own turn/budget ceiling (a usage/session limit, a generic API error, an
#                    auth outage) records status "error", never "failed" or "void-no-activation" — an
#                    outage is not a measurement of either arm. The driver stops dispatching NEW
#                    cells after the first one (the outage will not have cleared a turn later) and
#                    records every remaining cell "error" too, the same zero-session/null-cost shape
#                    bench::record_capped_cell already uses for a cell skipped past BENCH_MAX_USD.
#
# Every function ends `return 0` and dependent locals are split across statements: a function whose
# LAST statement is a bare `[[ c ]] && cmd` returns the test's status and aborts the caller under
# `set -euo pipefail`, and `local a=x b="$a"` leaves b unbound.
set -euo pipefail

BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The hub's own git sha, stamped onto every rollup row: the smoke gate compares a prior smoke run's
# stamp against THIS one, so a pipeline fix never lets a smoke run from before the fix vouch for a
# live run after it. "unknown" (never a fabricated sha) when the hub itself is not a git checkout.
HUB_SHA="$(git -C "$BENCH_DIR/.." rev-parse HEAD 2>/dev/null || echo unknown)"

DRY_RUN=0
BACKLOG_DIR="$BENCH_DIR/backlogs"
OUT_ROOT="${BENCH_OUT_ROOT:-$BENCH_DIR/results}"
RUN_ID=""
REPS=1
SEL_BACKLOGS=()
SEL_ARMS=()

BENCH_MAX_USD="${BENCH_MAX_USD:-60}"
BENCH_TURNS="${BENCH_MAX_TURNS:-200}"
BENCH_CLAUDE_BIN="${BENCH_CLAUDE_BIN:-claude}"
# Per-session dollar ceiling, the --max-budget-usd fallback for a CLI with no --max-turns. Equal on
# both arms (see the usage header above): each arm is one session doing the whole backlog now, so
# the per-session cap is the run cap by default, same as the run-level BENCH_MAX_USD.
BENCH_SESSION_USD="${BENCH_MAX_SESSION_USD:-$BENCH_MAX_USD}"
export BENCH_TURNS BENCH_CLAUDE_BIN BENCH_SESSION_USD

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
# bench::arm_shiploop's subshell does `cd "$ws"` before re-reading the backlog file; a relative
# --backlogs there silently resolves against $ws instead of the caller's cwd, jq fails to open it,
# the ticket-number list comes out EMPTY, and the arm dispatches ZERO tickets and exits clean,
# which reads exactly like a working run that happened to clear nothing.
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

# ── isolation ────────────────────────────────────────────────────────────────
# A cell's actual working directory used to live under $BENCH_STATE_DIR, which by default sits
# inside THIS hub checkout inside the workspace worktree tree — so a workspace's own root CLAUDE.md
# was a genuine ANCESTOR of every cell's cwd (the "project" memory walk-up finds it there, same as it
# would for a real project file), and a shiploop-arm session walked up and ran `npm run
# worktree:new` in the OUTER workspace, touching the real sub-repos' git. BENCH_WORKDIR_ROOT decouples
# the actual arm working directory from $OUT_ROOT/$BENCH_STATE_DIR entirely: default is outside any
# repo, so there is no ancestor CLAUDE.md, no ancestor .git, nothing to walk up into.
_bench_tmp_root="${TMPDIR:-/tmp}"
_bench_tmp_root="${_bench_tmp_root%/}"
BENCH_WORKDIR_ROOT="${BENCH_WORKDIR_ROOT:-$_bench_tmp_root/shiploop-bench}"
mkdir -p "$BENCH_WORKDIR_ROOT"
export BENCH_WORKDIR_ROOT
# Cache isolation, both arms AND every verify_cmd run (BENCH_ISOLATE=0 is the deliberate override):
# an empty GOMODCACHE/CARGO_HOME so neither arm sees a module the OPERATOR's own machine already
# fetched (observed live: a fixed upstream dependency version in the machine's Go module cache let
# an arm diff against it), GOPROXY=off + GOFLAGS=-mod=mod so a `go` invocation fails rather than
# silently reaching the network, and a harness-built venv (no system site-packages) so `python3`
# never resolves to whatever the operator happens to have `pip install`ed globally (observed live:
# system Python had `pygments` installed). Built ONCE, outside any arm — see
# bench::ensure_isolated_venv, called below, never from bench::spawn or an arm's own session.
BENCH_ISOLATE="${BENCH_ISOLATE:-1}"
BENCH_CACHE_ROOT="${BENCH_CACHE_ROOT:-$BENCH_WORKDIR_ROOT/.caches}"
BENCH_GOMODCACHE="${BENCH_GOMODCACHE:-$BENCH_CACHE_ROOT/gomod}"
BENCH_CARGO_HOME="${BENCH_CARGO_HOME:-$BENCH_CACHE_ROOT/cargo}"
BENCH_VENV_DIR="${BENCH_VENV_DIR:-$BENCH_CACHE_ROOT/venv}"
export BENCH_ISOLATE BENCH_CACHE_ROOT BENCH_GOMODCACHE BENCH_CARGO_HOME BENCH_VENV_DIR

# bench::isolation_env_args lives in record.sh, not here: arms.sh's bench::spawn calls it directly
# (the one place every arm's session is launched), and record.sh is the shared library both run.sh
# and arms.sh already depend on — a function only run.sh defined would break arms.sh the moment it
# is sourced on its own (as a test or a probe does), rather than always via run.sh's own process.

# Builds the isolated venv ONCE, in the driver's own process — never from bench::spawn or an arm's
# own session, so an arm never gets credit (or blame) for provisioning its own test tooling. Memoized
# on the venv's own python3 binary existing, so a second run on the same machine is a no-op. Network
# use here is a one-time local `pip install`, not a benchmarked arm's own spend. Best-effort: a
# failure here logs and continues without python isolation rather than aborting the whole run — the
# no-install doctrine (bench/KNOWN-LIMITS.md) means most backlogs need no python at all.
bench::ensure_isolated_venv() {
  [[ "$BENCH_ISOLATE" != "0" ]] || return 0
  [[ -x "$BENCH_VENV_DIR/bin/python3" ]] && return 0
  command -v python3 >/dev/null 2>&1 || {
    bench::log "isolation: no python3 on PATH — a verify_cmd that needs it will fail; no venv to build"
    return 0
  }
  bench::log "isolation: building the isolated venv at $BENCH_VENV_DIR (one-time; may use the network for 'pip install pytest')"
  if ! python3 -m venv "$BENCH_VENV_DIR" >/dev/null 2>&1; then
    bench::log "isolation: failed to create a venv at $BENCH_VENV_DIR; continuing without python isolation"
    rm -rf "$BENCH_VENV_DIR"
    return 0
  fi
  if ! "$BENCH_VENV_DIR/bin/pip" install --quiet --disable-pip-version-check pytest >/dev/null 2>&1; then
    bench::log "isolation: failed to install pytest into the isolated venv; continuing without it"
  fi
  return 0
}

# record.sh also defines bench::log / bench::die, so it must be sourced before anything speaks.
# shellcheck source=./record.sh
source "$BENCH_DIR/record.sh"
bench::load_govern_lib "$BENCH_STATE_DIR"
# shellcheck source=./arms.sh
source "$BENCH_DIR/arms.sh"

command -v jq >/dev/null 2>&1 || bench::die "jq is required"

if [[ "$BENCH_ISOLATE" != "0" ]]; then
  mkdir -p "$BENCH_GOMODCACHE" "$BENCH_CARGO_HOME"
  bench::ensure_isolated_venv
fi

# CLI version is recorded on every row so the published sentence can name it. A dry run has no
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
#   {id, repo, ref, title, body, verify_cmd, kind}
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
  local f="$1" bad count
  bad="$(jq -r 'select((.id//"")=="" or (.repo//"")=="" or (.ref//"")=="" or (.title//"")==""
                       or (.body//"")=="" or (.verify_cmd//"")=="") | .id // "<no id>"' "$f" 2>&1 || true)"
  [[ -z "$bad" ]] || bench::die "backlog $f has ticket(s) missing required fields: $bad"
  # A zero-ticket backlog is not rejected outright (a smoke-test backlog is a legitimate, if
  # unpublishable, thing to run) but every cell it produces gets its OWN status rather than the
  # misleading "resolved" a bare `cleared -eq total` comparison gives 0 == 0 (see the main loop
  # below and spec section 7 item 1). Logged here, once, rather than once per arm/rep.
  count="$(jq -s 'length' "$f" 2>/dev/null || echo 0)"
  [[ "${count:-0}" -gt 0 ]] || bench::log "backlog $f has ZERO tickets — every cell will record status no-tickets, never resolved"
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
# Non-negotiable: the shiploop arm runs the REAL governor loop, which opens PRs
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
#
# Deliberately under $BENCH_WORKDIR_ROOT, NEVER $BENCH_STATE_DIR: the state dir lives inside this
# hub checkout, itself typically inside a workspace worktree, so a cell's cwd would otherwise have
# the workspace's OWN root CLAUDE.md (and its `.git`) as an ancestor. $BENCH_WORKDIR_ROOT defaults
# outside any repo (see the isolation block above), so this cell's tree is the only ancestor CLAUDE.md
# / .git either arm's session can find by walking up from its cwd.
bench::prepare_workdir() { # <backlog.jsonl> <cell-id> -> path on stdout
  local backlog="$1" cell="$2" wd repo ref
  wd="$BENCH_WORKDIR_ROOT/$RUN_ID/wd-$cell"
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
# Mechanical oracle, no LLM judging. A backlog ships with its own tests already present in the tree
# at `ref`, already failing: an arm's job is to make `verify_cmd` pass, nothing is mined from an
# upstream PR and nothing is patched onto the arm's tree at verify time. The arm receives `title`
# and `body` verbatim and nothing else; `verify_cmd` itself stays out of the prompt so it never
# hands either arm the exact command that clears the ticket.
#
# Prints "<cleared> <total> <worstExit>" and writes one JSON line per ticket to <verify-ledger>,
# the private per-ticket verification record.
bench::verify_backlog() { # <backlog.jsonl> <workdir> <verify-ledger>
  local backlog="$1" wd="$2" ledger="$3"
  local cleared=0 total=0 worst=0 line id cmd rc
  : > "$ledger"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    total=$((total+1))
    id="$(printf '%s' "$line" | jq -r '.id')"
    cmd="$(printf '%s' "$line" | jq -r '.verify_cmd')"
    rc=0
    # Same cache isolation an arm's own session gets (bench::isolation_env_args, above): a
    # verify_cmd is real code execution against the arm's tree, so it gets the identical empty
    # GOMODCACHE/GOPROXY=off/GOFLAGS/CARGO_HOME and isolated-venv python3, or an arm could pass
    # verify_cmd only because the DRIVER's own machine happened to have a dependency cached or a
    # system python package installed that the arm itself never fetched.
    ( cd "$wd"
      if [[ "$BENCH_ISOLATE" != "0" ]]; then
        export GOMODCACHE="$BENCH_GOMODCACHE" GOPROXY=off GOFLAGS=-mod=mod CARGO_HOME="$BENCH_CARGO_HOME"
        if [[ -x "$BENCH_VENV_DIR/bin/python3" ]]; then export PATH="$BENCH_VENV_DIR/bin:$PATH"; fi
      fi
      eval "$cmd"
    ) >/dev/null 2>&1 || rc=$?
    if [[ "$rc" -eq 0 ]]; then cleared=$((cleared+1)); else worst="$rc"; fi
    jq -nc --arg id "$id" --argjson exit "$rc" \
      '{ticket:$id, verifyExit:$exit, cleared:($exit == 0)}' >> "$ledger"
  done < <(jq -c '.' "$backlog")
  printf '%s %s %s\n' "$cleared" "$total" "$worst"
  return 0
}

# ── dry-run arm stand-ins ───────────────────────────────────────────────────
# Canned `"type":"result"` events. Every arm is ONE whole-backlog session now (vanilla-fresh is the
# one exception, one session per ticket), so every case here writes exactly the same shape
# bench::arm_vanilla / bench::arm_shiploop write for real: a single 01-<name>.jsonl stream.
#
# BENCH_DRY_ERROR_REP=<N>: test seam only, unset by default. When set, the arm named by
# BENCH_DRY_ERROR_ARM (default "shiploop") gets `fixtures/error-session.jsonl` instead of its usual
# fixture for rep N alone, so the test suite can drive an infra-class error through the REAL run.sh
# dispatch loop (status derivation, the halt-on-error flag, the next cell's skip) without a live
# spawn. No effect on a real run: nothing sets this outside the test suite.
bench::dry_arm() { # <arm> <backlog.jsonl> <logdir> <backlog-name> <rep>
  local arm="$1" backlog="$2" logdir="$3" name="$4" rep="$5"
  local fx="$BENCH_DIR/fixtures"
  local i=0 id
  if [[ -n "${BENCH_DRY_ERROR_REP:-}" && "$rep" == "$BENCH_DRY_ERROR_REP" \
        && "$arm" == "${BENCH_DRY_ERROR_ARM:-shiploop}" ]]; then
    cp "$fx/error-session.jsonl" "$logdir/01-$name.jsonl"
    return 0
  fi
  case "$arm" in
    vanilla)
      cp "$fx/vanilla-session.jsonl" "$logdir/01-$name.jsonl"
      ;;
    vanilla-fresh)
      while IFS= read -r id; do
        i=$((i+1))
        cp "$fx/vanilla-fresh-session.jsonl" "$(printf '%s/%02d-%s.jsonl' "$logdir" "$i" "$id")"
      done < <(jq -r '.id' "$backlog")
      ;;
    shiploop)
      cp "$fx/shiploop-session.jsonl" "$logdir/01-$name.jsonl"
      ;;
    *) bench::die "unknown arm: $arm" ;;
  esac
  return 0
}

bench::run_arm() { # <arm> <workdir> <backlog.jsonl> <logdir> <backlog-name> <rep>
  local arm="$1" wd="$2" backlog="$3" logdir="$4" name="$5" rep="$6"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    bench::dry_arm "$arm" "$backlog" "$logdir" "$name" "$rep"
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
    "$(date +%s)" 0 "" "$HUB_SHA"
  return 0
}

# ── halt on infra-class error ────────────────────────────────────────────────
# A cell whose session ended on an infra-class error (bench::cell_hit_error, record.sh) is not a
# measurement, and neither is anything dispatched after it while the SAME outage is still live: a
# subscription/session limit does not clear itself mid-run, so every remaining cell would just burn
# a few more seconds recording the same non-measurement. The first error-class cell still runs (the
# halt is checked before the NEXT dispatch, the same "cannot un-spend a session already started"
# rule bench::over_cap follows) and every cell after it records status "error" with zero sessions and
# a null cost, same shape as bench::record_capped_cell, without ever spawning.
bench::record_error_cell() { # <backlog> <arm> <rep> <ticketCount>
  local backlog="$1" arm="$2" rep="$3" total="$4"
  bench::record_rollup "$RESULTS" "$RUN_ID" "$backlog" "$arm" "$rep" "error" 0 "$total" 0 \
    "$(date +%s)" 0 "" "$HUB_SHA"
  return 0
}

# ── smoke gate ──────────────────────────────────────────────────────────────
# See the usage header ("Smoke gate") for what this enforces and why. Only ever consulted for a
# LIVE run bigger than one cell; a dry run and a single-cell run never call this.
bench::smoke_gate_check() { # <smoke-run-id>
  local smoke_id="$1" smoke_file bad
  smoke_file="$OUT_ROOT/$smoke_id/results.jsonl"
  [[ -f "$smoke_file" ]] || bench::die "smoke gate: BENCH_SMOKE_RUN=$smoke_id names no results file at $smoke_file"
  bad="$(jq -sr --arg sha "$HUB_SHA" \
    '[ .[] | select(.kind=="rollup" and .hubSha != $sha) ] | length' "$smoke_file" 2>/dev/null || echo 1)"
  [[ "$bad" == "0" ]] || bench::die "smoke gate: $smoke_file was not recorded at the current hub sha ($HUB_SHA) — re-run the smoke at this sha first"
  bad="$(jq -sr \
    '[ .[] | select(.kind=="rollup" and (.status != "resolved" and .status != "failed")) ] | length' \
    "$smoke_file" 2>/dev/null || echo 1)"
  [[ "$bad" == "0" ]] || bench::die "smoke gate: $smoke_file has a cell that did not complete (resolved/failed) — capped or another status means the pipeline is not proven clean at this sha"
  bad="$(jq -sr \
    '[ .[] | select(.kind=="rollup" and .arm=="shiploop" and ((.workerSpawns // 0) == 0)) ] | length' \
    "$smoke_file" 2>/dev/null || echo 1)"
  [[ "$bad" == "0" ]] || bench::die "smoke gate: $smoke_file has a shiploop cell with zero worker-spawn activation — dispatch itself is not proven at this sha"
  return 0
}

# ── main loop ───────────────────────────────────────────────────────────────
backlogs=()
while IFS= read -r n; do backlogs+=("$n"); done < <(bench::discover_backlogs)
[[ "${#backlogs[@]}" -gt 0 ]] || bench::die "no backlogs found under $BACKLOG_DIR"

bench::log "run $RUN_ID: ${#backlogs[@]} backlog(s) x ${#SEL_ARMS[@]} arm(s) x $REPS rep(s), cap \$$BENCH_MAX_USD"

smoke_gate_skipped=0
total_cells=$(( ${#backlogs[@]} * REPS ))
if [[ "$DRY_RUN" -ne 1 && "$total_cells" -gt 1 ]]; then
  if [[ "${BENCH_SKIP_SMOKE_GATE:-0}" == "1" ]]; then
    bench::log "smoke gate: BENCH_SKIP_SMOKE_GATE=1 — running $total_cells cells with NO smoke-run proof at hub sha $HUB_SHA"
    smoke_gate_skipped=1
  elif [[ -n "${BENCH_SMOKE_RUN:-}" ]]; then
    bench::smoke_gate_check "$BENCH_SMOKE_RUN"
    bench::log "smoke gate: satisfied by BENCH_SMOKE_RUN=$BENCH_SMOKE_RUN at hub sha $HUB_SHA"
  else
    bench::die "smoke gate: this run has $total_cells (backlog x rep) cells, more than a smoke run's one. Run a 1-backlog 1-rep smoke first and pass BENCH_SMOKE_RUN=<its run id>, or set BENCH_SKIP_SMOKE_GATE=1 to run without proof (recorded in the results)."
  fi
fi
# Which isolation was actually active, recorded once per run rather than re-derived from logs
# later. strict-mcp-config's own support is resolved eagerly here (never during a dry run, which
# spawns nothing) so the meta row reflects what the CLI on THIS machine can actually do, not just
# what was requested.
strict_mcp_supported="n/a (dry run)"
if [[ "$DRY_RUN" -ne 1 ]]; then
  if [[ "${BENCH_STRICT_MCP_CONFIG:-1}" == "0" ]]; then
    strict_mcp_supported="disabled (BENCH_STRICT_MCP_CONFIG=0)"
  elif bench::claude_supports_strict_mcp_config "$BENCH_CLAUDE_BIN"; then
    strict_mcp_supported="true"
  else
    strict_mcp_supported="false (unsupported CLI)"
  fi
fi
python_venv_path="null"
[[ -x "$BENCH_VENV_DIR/bin/python3" ]] && python_venv_path="$BENCH_VENV_DIR"
jq -nc --arg run "$RUN_ID" --arg sha "$HUB_SHA" --arg smokerun "${BENCH_SMOKE_RUN:-}" \
  --argjson dry "$([[ "$DRY_RUN" -eq 1 ]] && printf true || printf false)" \
  --argjson skipped "$([[ "$smoke_gate_skipped" -eq 1 ]] && printf true || printf false)" \
  --argjson isolate "$([[ "$BENCH_ISOLATE" != "0" ]] && printf true || printf false)" \
  --arg workdirroot "$BENCH_WORKDIR_ROOT" --arg strictmcp "$strict_mcp_supported" \
  --arg venv "$python_venv_path" \
  '{kind:"meta", run:$run, hubSha:$sha, dryRun:$dry, smokeGateSkipped:$skipped,
    smokeRun:($smokerun | if .=="" then null else . end),
    isolation:{active:$isolate, settingSources:"project,local", strictMcpConfig:$strictmcp,
      workdirRoot:$workdirroot, goModCacheIsolated:$isolate, cargoHomeIsolated:$isolate,
      pythonVenv:($venv | if .=="null" then null else . end)}}' >> "$RESULTS"

capped=0
halted_on_error=0
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
      if [[ "$halted_on_error" -eq 1 ]]; then
        bench::log "cell $cell: SKIPPED, an earlier cell hit an infra-class error this run"
        bench::record_error_cell "$name" "$arm" "$rep" "$ticket_count"
        continue
      fi
      logdir="$RUN_DIR/sessions/$cell"
      mkdir -p "$logdir"
      started="$(date +%s)"
      workdir="$(bench::prepare_workdir "$backlog_file" "$cell")"
      bench::run_arm "$arm" "$workdir" "$backlog_file" "$logdir" "$name" "$rep"
      # NOT inside $logdir: record_sessions globs every *.jsonl there as a claude session stream,
      # so a ledger written beside the streams would be recorded as an extra zero-cost session.
      mkdir -p "$RUN_DIR/verify"
      read -r cleared total worst < <(bench::verify_backlog "$backlog_file" "$workdir" "$RUN_DIR/verify/$cell.jsonl")
      wall_ms=$(( ( $(date +%s) - started ) * 1000 ))
      # A zero-ticket backlog makes `cleared -eq total` compare 0 -eq 0, which reads exactly like a
      # cell that dispatched nothing as one that cleared everything (spec section 7 item 1). Checked
      # BEFORE the ordinary comparison so a real empty backlog never silently reports "resolved".
      if [[ "$total" -eq 0 ]]; then
        status="no-tickets"
      elif [[ "$cleared" -eq "$total" ]]; then
        status="resolved"
      else
        status="failed"
      fi
      # A session cut off by its OWN per-session ceiling (--max-turns / --max-budget-usd) never
      # gets to be a completed comparison, even if it happened to clear every ticket anyway: the
      # cap decided how far it got, not the arm. Overrides resolved/failed to "capped" so the
      # rollup drops it from the published set the same way a run-level BENCH_MAX_USD cap does.
      if bench::cell_hit_session_cap "$logdir"; then
        status="capped"
        bench::log "cell $cell: a session hit its per-session ceiling mid-run; forcing status=capped"
      elif bench::cell_hit_error "$logdir"; then
        # A usage/session limit, a generic API error, or an auth outage — never the arm's own
        # competence. This cell already dispatched (it cannot be un-spent, same as bench::over_cap),
        # but the outage is unlikely to have cleared a turn later, so every cell dispatched AFTER
        # this one this run is skipped and recorded the same way (see the halted_on_error check
        # above), rather than burning the rest of the run on doomed attempts.
        status="error"
        halted_on_error=1
        bench::log "cell $cell: a session's final result event was an infra-class error (session/usage limit, API error, auth); forcing status=error and halting further dispatch this run"
      fi
      # Direct evidence of delegation: how many Agent/Task tool_use invocations the stream itself
      # shows, never the result event's self-reported subagent_stats alone. A shiploop cell with
      # zero forces status void-no-activation (capped still wins — a session cut off before it
      # could even delegate is a rail artifact, not evidence about whether it would have).
      worker_spawns="$(bench::cell_worker_spawns "$logdir")"
      status="$(bench::activation_status "$status" "$arm" "$worker_spawns")"
      if [[ "$status" == "void-no-activation" ]]; then
        bench::log "cell $cell: shiploop arm shows zero Agent/Task tool_use invocations; forcing status=void-no-activation"
      fi
      sessions="$(bench::record_sessions "$logdir" "$RESULTS" "$RUN_ID" "$name" "$arm" "$rep" \
        "$MODEL_NAME" "$CLI_VERSION" "$status" "$worst" "$wall_ms" "$started" "$cleared" "$total")"
      bench::record_rollup "$RESULTS" "$RUN_ID" "$name" "$arm" "$rep" "$status" \
        "$cleared" "$total" "$wall_ms" "$started" "$worker_spawns" "$RUN_DIR/verify/$cell.jsonl" "$HUB_SHA"
      bench::log "cell $cell: $status, $cleared/$total cleared, $sessions session(s), cumulative spent \$$(bench::spent_usd "$RESULTS")"
    done
  done
done

bench::log "results: $RESULTS"
bench::log "total recorded cost: \$$(bench::spent_usd "$RESULTS")"
