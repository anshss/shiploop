#!/usr/bin/env bash
# bench/validate-backlog.sh: the offline gate that decides which backlogs are eligible for the
# pilot at all. No `claude` spawns, no model calls, no LLM judging. Pure git and the repo's own
# test command.
#
# Usage:
#   bench/validate-backlog.sh <backlog.jsonl>...        validate specific backlogs
#   bench/validate-backlog.sh --backlogs <dir>          validate every <dir>/*/backlog.jsonl
#   [--json]                                            machine-readable, for the selection step
#   [--min-tickets N]                                   survivors needed to stay usable (default 6)
#
# It turns `verify_cmd` from an unverified claim into a mechanically sourced one. Every ticket has
# to prove the fail-to-pass property, in this order, against a real clone:
#
#   1. checkout `ref`, apply `test_patch` exactly. It must apply, or the ticket is DROPPED. A patch
#      that needs fuzz is not a golden patch.
#   2. run `verify_cmd` there. It must FAIL. This is the fail-to-pass precondition: a test that
#      already passes at the pinned ref proves nothing about the work, and a backlog of those would
#      hand both arms free tickets and make the whole comparison meaningless.
#   3. checkout `merge_sha` clean, confirm the test content is already present, run `verify_cmd`.
#      It must PASS. This is what proves the test is really the one the merged PR made pass, rather
#      than a test that nothing can satisfy.
#
# Presence in step 3 is checked with `git apply --reverse --check`: if the golden patch can be
# reversed out of the merge commit's tree, that content is in it. That is a mechanical check, not a
# guess about file names.
#
# A backlog with fewer than --min-tickets survivors is marked unusable. Its drop list is internal
# record (spec section 6) and is never published.
#
# Govern conventions: `set -euo pipefail`, every function ends `return 0`, dependent locals split
# across statements.
set -euo pipefail

VALIDATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

JSON=0
MIN_TICKETS="${BENCH_MIN_TICKETS:-6}"
BACKLOG_FILES=()
CLONE_ROOT="${BENCH_VALIDATE_CLONE_ROOT:-}"

bench::log() { printf '[validate] %s\n' "$*" >&2; return 0; }
bench::die() { printf '[validate] FATAL: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)         JSON=1 ;;
    --min-tickets)  MIN_TICKETS="$2"; shift ;;
    --backlogs)
      shift
      for d in "$1"/*/; do
        [[ -f "$d/backlog.jsonl" ]] && BACKLOG_FILES+=("$d/backlog.jsonl")
      done
      ;;
    -h|--help)      sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --*)            bench::die "unknown argument: $1" ;;
    *)              BACKLOG_FILES+=("$1") ;;
  esac
  shift
done

[[ "${#BACKLOG_FILES[@]}" -gt 0 ]] || bench::die "no backlogs given (pass files, or --backlogs <dir>)"
command -v jq  >/dev/null 2>&1 || bench::die "jq is required"
command -v git >/dev/null 2>&1 || bench::die "git is required"

if [[ -z "$CLONE_ROOT" ]]; then
  CLONE_ROOT="$(mktemp -d)"
  trap 'rm -rf "$CLONE_ROOT"' EXIT
fi
mkdir -p "$CLONE_ROOT"

# One clone per repo, reused across every ticket and backlog that names it. Cloning once per ticket
# would be minutes of wall clock for nothing; the checkouts below are what isolate the states.
bench::clone() { # <repo> -> path on stdout
  local repo="$1" key path
  key="$(printf '%s' "$repo" | tr -c 'A-Za-z0-9._-' '_')"
  path="$CLONE_ROOT/$key"
  if [[ ! -d "$path/.git" ]]; then
    git clone -q "$repo" "$path" >/dev/null 2>&1 || return 1
  fi
  printf '%s\n' "$path"
  return 0
}

# Hard reset to a ref, discarding anything a previous step applied. Every step below starts from a
# known tree, so a patch left behind by step 1 can never leak into step 3 and make a broken ticket
# look valid.
#
# The reset and clean come BEFORE the checkout, not after. Step 1 applies the golden patch, which
# leaves the new test file UNTRACKED in the worktree; `git checkout` then refuses to move because
# it would clobber an untracked file, and step 3 fails with "merge_sha does not resolve" for a
# reason that has nothing to do with merge_sha. Every valid ticket would be dropped.
bench::checkout_clean() { # <clonedir> <ref>
  ( cd "$1" \
      && git reset -q --hard >/dev/null 2>&1 \
      && git clean -qfdx >/dev/null 2>&1 \
      && git checkout -q --detach "$2" >/dev/null 2>&1 \
      && git reset -q --hard "$2" >/dev/null 2>&1 )
  return $?
}

# Run one ticket's three checks. Prints one JSON verdict object.
bench::validate_ticket() { # <ticket-json> -> verdict JSON
  local t="$1"
  local id repo ref sha cmd patch clone
  id="$(printf '%s' "$t" | jq -r '.id // ""')"
  repo="$(printf '%s' "$t" | jq -r '.repo // ""')"
  ref="$(printf '%s' "$t" | jq -r '.ref // ""')"
  sha="$(printf '%s' "$t" | jq -r '.merge_sha // ""')"
  cmd="$(printf '%s' "$t" | jq -r '.verify_cmd // ""')"
  patch="$(printf '%s' "$t" | jq -r '.test_patch // ""')"

  local verdict="keep" reason="" applies=false fails_at_ref=false present=false passes_at_merge=false
  local rc=0

  if [[ -z "$id" || -z "$repo" || -z "$ref" || -z "$sha" || -z "$cmd" || -z "$patch" ]]; then
    bench::verdict "$id" drop "missing a required field" false false false false
    return 0
  fi

  clone="$(bench::clone "$repo" || true)"
  if [[ -z "$clone" ]]; then
    bench::verdict "$id" drop "repo could not be cloned" false false false false
    return 0
  fi

  # ── 1. the golden patch applies exactly at the pinned ref ─────────────────
  if ! bench::checkout_clean "$clone" "$ref"; then
    bench::verdict "$id" drop "ref does not resolve in the clone" false false false false
    return 0
  fi
  # printf '%s\n', never '%s': command substitution ate $patch's trailing newline, and git apply
  # calls a diff without one "corrupt patch". That would drop every ticket for a reason that has
  # nothing to do with the ticket.
  if printf '%s\n' "$patch" | ( cd "$clone" && git apply - ) >/dev/null 2>&1; then
    applies=true
  else
    bench::verdict "$id" drop "test_patch does not apply cleanly at ref" false false false false
    return 0
  fi

  # ── 2. fail-to-pass precondition: it must FAIL there ──────────────────────
  rc=0
  ( cd "$clone" && eval "$cmd" ) >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    fails_at_ref=true
  else
    bench::verdict "$id" drop "verify_cmd already passes at ref (not fail-to-pass)" \
      "$applies" false false false
    return 0
  fi

  # ── 3. the merge commit has the test content, and passes ──────────────────
  if ! bench::checkout_clean "$clone" "$sha"; then
    bench::verdict "$id" drop "merge_sha does not resolve in the clone" "$applies" "$fails_at_ref" false false
    return 0
  fi
  # Reversible means present: if the golden patch can be taken back OUT of this tree, the tree
  # already contains it.
  if printf '%s\n' "$patch" | ( cd "$clone" && git apply --reverse --check - ) >/dev/null 2>&1; then
    present=true
  else
    bench::verdict "$id" drop "test content is not present at merge_sha" "$applies" "$fails_at_ref" false false
    return 0
  fi
  rc=0
  ( cd "$clone" && eval "$cmd" ) >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    passes_at_merge=true
  else
    bench::verdict "$id" drop "verify_cmd does not pass at merge_sha" \
      "$applies" "$fails_at_ref" "$present" false
    return 0
  fi

  bench::verdict "$id" keep "" "$applies" "$fails_at_ref" "$present" "$passes_at_merge"
  return 0
}

bench::verdict() { # <id> <keep|drop> <reason> <applies> <failsAtRef> <present> <passesAtMerge>
  jq -nc --arg id "$1" --arg v "$2" --arg r "$3" \
    --argjson a "$4" --argjson f "$5" --argjson p "$6" --argjson m "$7" \
    '{ticket:$id, verdict:$v, reason:$r,
      patchApplies:$a, failsAtRef:$f, testPresentAtMerge:$p, passesAtMerge:$m}'
  return 0
}

# ── main ────────────────────────────────────────────────────────────────────
results="$(mktemp)"
trap 'rm -f "$results"' RETURN 2>/dev/null || true
: > "$results"

for bl in "${BACKLOG_FILES[@]}"; do
  name="$(basename "$(dirname "$bl")")"
  [[ "$JSON" -eq 1 ]] || printf '\n== %s ==\n' "$name"
  tickets=0
  kept=0
  verdicts="$(mktemp)"
  : > "$verdicts"
  while IFS= read -r t; do
    [[ -n "$t" ]] || continue
    tickets=$((tickets+1))
    v="$(bench::validate_ticket "$t")"
    printf '%s\n' "$v" >> "$verdicts"
    if [[ "$(printf '%s' "$v" | jq -r '.verdict')" == "keep" ]]; then
      kept=$((kept+1))
      [[ "$JSON" -eq 1 ]] || printf '  keep - %s\n' "$(printf '%s' "$v" | jq -r '.ticket')"
    else
      [[ "$JSON" -eq 1 ]] || printf '  DROP - %s: %s\n' \
        "$(printf '%s' "$v" | jq -r '.ticket')" "$(printf '%s' "$v" | jq -r '.reason')"
    fi
  done < <(jq -c '.' "$bl")

  usable="true"
  [[ "$kept" -ge "$MIN_TICKETS" ]] || usable="false"
  jq -sc --arg name "$name" --arg file "$bl" --argjson tickets "$tickets" \
    --argjson kept "$kept" --argjson min "$MIN_TICKETS" --argjson usable "$usable" \
    '{backlog:$name, file:$file, tickets:$tickets, kept:$kept, minTickets:$min,
      usable:$usable, verdicts:.}' "$verdicts" >> "$results"
  rm -f "$verdicts"
  if [[ "$JSON" -ne 1 ]]; then
    printf '  %s: %d/%d tickets survive (min %d) verdict=%s\n' \
      "$name" "$kept" "$tickets" "$MIN_TICKETS" \
      "$([[ "$usable" == "true" ]] && echo USABLE || echo UNUSABLE)"
  fi
done

if [[ "$JSON" -eq 1 ]]; then
  jq -sc '{backlogs: ., usable: [ .[] | select(.usable) | .backlog ],
           unusable: [ .[] | select(.usable | not) | .backlog ]}' "$results"
else
  printf '\nusable backlogs: %s\n' "$(jq -sr '[ .[] | select(.usable) | .backlog ] | join(", ") // ""' "$results")"
fi

# Exit 1 when nothing is usable, so a pilot script cannot proceed on an empty eligible set.
any="$(jq -sr '[ .[] | select(.usable) ] | length' "$results")"
rm -f "$results"
[[ "${any:-0}" -gt 0 ]] || exit 1
exit 0
