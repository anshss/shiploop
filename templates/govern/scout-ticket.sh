#!/usr/bin/env bash
# Scout-then-size: MEASURE a ticket's scope with a cheap pre-dispatch pass, then select the worker's
# (model, effort) DETERMINISTICALLY from that measurement.
#
# Why this exists: sizing used to be a PRIOR, not a measurement. The `Model:` field is decided before
# any evidence by whoever files the ticket, and a ticket with no field fell through to a blanket
# `GOVERN_WORKER_MODEL` (default `opus`). That is wrong in both directions — it overpays on easy
# tickets and cannot detect a hard one until an attempt has already failed at full price.
# Reconnaissance costs roughly 1/1000th of the work, so spending a cent to decide whether to spend $3
# or $34 is the highest-ROI decision in the harness.
#
# TWO halves, deliberately split so only the first is a model call:
#   1. MEASURE (a `claude -p` pass at the haiku tier, read-only) → a small JSON scope object.
#   2. SCORE  (pure bash, no LLM) → (model, effort, scopeClass). Auditable, tunable, unit-testable
#      in isolation — NOT a second judgement call handed to a model.
#
# Modes:
#   scout-ticket.sh <N>            run the scout for ticket N (or reuse this run's cached verdict),
#                                  write <worker-logdir>/scout.json, print "model<TAB>effort<TAB>class"
#   scout-ticket.sh --verdict <N>  cache-READ only — never calls a model. Exit 1 when there is no
#                                  usable cache. This is what spawn-worker.sh calls.
#   scout-ticket.sh --score <file> score a scope JSON (`-` = stdin). No model, no cache, no workspace
#                                  writes — the deterministic half, exercised directly by the tests.
#
# PRECEDENCE — the scout NEVER outranks a human. An explicit ticket `Model:`/`Effort:` field always
# wins (spawn-worker.sh's resolve_sizing claims those axes before consulting this script); the scout
# only decides the axes the brain left blank, replacing the blanket default rather than the operator.
#
# GUARD — scout output is UNTRUSTED model output feeding a dispatch decision:
#   - structurally invalid (not a JSON object, or a required key missing) → REJECTED, loudly. The
#     caller falls back to today's GOVERN_WORKER_MODEL / GOVERN_WORKER_EFFORT behavior.
#   - present but out-of-domain (unknown enum, non-integer, absurd count) → CLAMPED to the HARD end
#     of its domain, loudly. Clamping is one-directional by construction: a malformed field can only
#     ever push a ticket UP the ladder, never silently downgrade a hard ticket to haiku.
#
# Env knobs:
#   GOVERN_SCOUT=0            disable entirely (dispatch reverts to the pre-scout behavior)
#   GOVERN_SCOUT_MODEL        tier the scout pass itself runs at (default `haiku`)
#   GOVERN_SCOUT_TIMEOUT      wall-clock bound on the scout pass, seconds (default 180)
#   GOVERN_CLAUDE_BIN         the claude binary (shared with spawn-worker.sh)
#   GOVERN_SETTING_SOURCES    forwarded to `claude -p` (default `user`)
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib/common.sh"
govern::require jq

SCOUT_TIMEOUT_DEFAULT=180
SCOUT_MAX_FILES=999          # clamp ceiling; anything at/above this scores as hard by construction
SCOUT_MAX_REPOS=99
SCOUT_TRIVIAL_FILES=1        # "1 file, local, precedent + test exist"
SCOUT_SMALL_FILES=5          # "<=5 files, 1 repo, concrete fix direction"

# ── the deterministic half ──────────────────────────────────────────────────────────────────────
# Reads a scope JSON object on stdin. Prints "model<TAB>effort<TAB>scopeClass". Returns 2 when the
# input is structurally unusable (the caller then falls back, loudly).
#
#   | measured scope                                              | model  | effort |
#   | 1 file, local, precedent + test exist                       | haiku  | low    |
#   | <=5 files, 1 repo, concrete fix direction                   | sonnet | medium |
#   | cross-repo, or contract/schema change, or no test, or vague | opus   | high   |
#
# The HARD gate is evaluated FIRST so every disqualifier short-circuits before any cheap tier can be
# selected, and the trailing `else` is hard too — an unclassifiable shape costs money, never risk.
scout::score() {
  local raw files repos tests prec kind dir class
  raw="$(cat)"

  if ! printf '%s' "$raw" | jq -e 'type == "object"' >/dev/null 2>&1; then
    govern::log "scout: REJECTED — output is not a JSON object; falling back to GOVERN_WORKER_MODEL"
    return 2
  fi
  # Every key must be PRESENT. A missing key is a malformed scout, not a defaultable one: silently
  # defaulting would let a truncated response masquerade as a real measurement.
  if ! printf '%s' "$raw" | jq -e 'has("files") and has("repos") and has("testsCover")
        and has("precedent") and has("changeKind") and has("fixDirection")' >/dev/null 2>&1; then
    govern::log "scout: REJECTED — scope JSON is missing required keys (need files/repos/testsCover/precedent/changeKind/fixDirection); falling back to GOVERN_WORKER_MODEL"
    return 2
  fi

  files="$(printf '%s' "$raw" | jq -r '.files | tostring' 2>/dev/null || echo '')"
  repos="$(printf '%s' "$raw" | jq -r '.repos | tostring' 2>/dev/null || echo '')"
  tests="$(printf '%s' "$raw" | jq -r '.testsCover | tostring' 2>/dev/null || echo '')"
  prec="$(printf '%s' "$raw" | jq -r '.precedent | tostring' 2>/dev/null || echo '')"
  kind="$(printf '%s' "$raw" | jq -r '.changeKind | tostring' 2>/dev/null || echo '')"
  dir="$(printf '%s' "$raw" | jq -r '.fixDirection | tostring' 2>/dev/null || echo '')"

  files="$(scout::clamp_int files "$files" "$SCOUT_MAX_FILES")"
  repos="$(scout::clamp_int repos "$repos" "$SCOUT_MAX_REPOS")"
  tests="$(scout::clamp_bool testsCover "$tests")"
  prec="$(scout::clamp_bool precedent "$prec")"
  kind="$(scout::clamp_enum changeKind "$kind" structural local structural)"
  dir="$(scout::clamp_enum fixDirection "$dir" vague concrete vague)"

  # HARD first — any single disqualifier wins. `files < 1` lands here too: a scout that could not
  # name even one file did not measure anything.
  if [[ "$repos" -gt 1 || "$kind" == "structural" || "$tests" == "false" \
        || "$dir" == "vague" || "$files" -lt 1 ]]; then
    class="hard"
  elif [[ "$files" -le "$SCOUT_TRIVIAL_FILES" && "$prec" == "true" ]]; then
    # Reachable only past the hard gate, so `local` + `testsCover` are already established here.
    class="trivial"
  elif [[ "$files" -le "$SCOUT_SMALL_FILES" ]]; then
    class="small"
  else
    class="hard"
  fi

  case "$class" in
    trivial) printf 'haiku\tlow\t%s\n'     "$class" ;;
    small)   printf 'sonnet\tmedium\t%s\n' "$class" ;;
    *)       printf 'opus\thigh\t%s\n'     "$class" ;;
  esac
  return 0
}

# Non-integer or over-ceiling → clamped to the ceiling, which the HARD gate then reads as "too big".
scout::clamp_int() { # <field> <value> <max>
  local field="$1" v="$2" max="$3"
  if [[ ! "$v" =~ ^[0-9]+$ ]]; then
    govern::log "scout: CLAMPED — $field='$v' is not a non-negative integer; using $max (scores hard)"
    printf '%s' "$max"; return 0
  fi
  if [[ "$v" -gt "$max" ]]; then
    govern::log "scout: CLAMPED — $field=$v exceeds $max; using $max (scores hard)"
    printf '%s' "$max"; return 0
  fi
  printf '%s' "$v"
}

# Anything that is not literally `true` is treated as `false` — the hard-scoring side of the domain.
scout::clamp_bool() { # <field> <value>
  local field="$1" v="$2"
  case "$v" in
    true|false) printf '%s' "$v" ;;
    *) govern::log "scout: CLAMPED — $field='$v' is not a boolean; using false (scores hard)"
       printf 'false' ;;
  esac
}

scout::clamp_enum() { # <field> <value> <hard-fallback> <allowed...>
  local field="$1" v="$2" fallback="$3"; shift 3
  local a
  for a in "$@"; do [[ "$v" == "$a" ]] && { printf '%s' "$v"; return 0; }; done
  govern::log "scout: CLAMPED — $field='$v' is not one of [$*]; using '$fallback' (scores hard)"
  printf '%s' "$fallback"
}

# ── cache ───────────────────────────────────────────────────────────────────────────────────────
# Run-scoped (logs/govern/run-<ts>/ticket-N/scout.json via govern::worker_logdir), so a RETRY inside
# the same run reuses the verdict instead of re-scouting, and a fresh run re-measures against fresh
# code. The cached `scope` object is the source of truth: `--verdict` re-SCORES it rather than
# trusting the stored verdict, so a scoring-table change takes effect immediately and a hand-edited
# verdict field can never bypass the guard.
scout::cache_path() { # <N>
  printf '%s/scout.json' "$(govern::worker_logdir "$1")"
}

scout::verdict_from_cache() { # <N> -> "model<TAB>effort<TAB>class" | nonzero
  local n="$1" cache
  cache="$(scout::cache_path "$n")"
  [[ -s "$cache" ]] || return 1
  local scope
  scope="$(jq -c '.scope' "$cache" 2>/dev/null || true)"
  [[ -n "$scope" && "$scope" != "null" ]] || return 1
  printf '%s' "$scope" | scout::score
}

# ── the model half ──────────────────────────────────────────────────────────────────────────────
scout::prompt() { # <N> <block>
  local n="$1" block="$2"
  cat <<EOF
You are a SCOUT sizing a ticket before a worker is dispatched. You are NOT fixing anything — do not
edit a single file. Measure the ticket's SCOPE, cheaply and fast: a handful of targeted greps and at
most a skim of the files you find. Seed the search from the ticket's \`Where:\` line.

Workspace root: $WS_ROOT
Sub-repos: ${REPOS[*]:-<none>}

<ticket number="$n">
$block
</ticket>

Answer these six questions about the FIX this ticket asks for:
  files        how many files the fix plausibly touches (an integer; 0 if you could not locate any)
  repos        how many distinct sub-repos are involved (an integer)
  testsCover   true if tests already exercise the area the fix touches, else false
  precedent    true if git history contains an analogous prior commit for the same file/area
               (\`git log --oneline -- <path>\` on the target paths), else false
  changeKind   "local" for an edit contained inside function bodies; "structural" for anything that
               moves a signature, a schema, a serialized format, or an API contract
  fixDirection "concrete" if the ticket already names the change to make; "vague" if the approach
               still has to be designed

Output ONLY a single JSON object as the LAST line of your reply. No prose around it, no code fence:
{"files":0,"repos":0,"testsCover":false,"precedent":false,"changeKind":"local","fixDirection":"vague"}
EOF
}

# Bounded run of the scout pass. Read-only by construction: `--permission-mode plan` lets the pass
# search and read but never write, so a scout can't mutate the tree it is measuring.
scout::run_pass() { # <N> <block> -> raw stdout
  local n="$1" block="$2"
  local bin="${GOVERN_CLAUDE_BIN:-claude}"
  local secs="${GOVERN_SCOUT_TIMEOUT:-$SCOUT_TIMEOUT_DEFAULT}"
  local tier="${GOVERN_SCOUT_MODEL:-haiku}"
  local prompt; prompt="$(scout::prompt "$n" "$block")"
  ( cd "$WS_ROOT" && govern::run_bounded "$secs" "$bin" -p "$prompt" \
      --model "$tier" --permission-mode plan --strict-mcp-config \
      --setting-sources "${GOVERN_SETTING_SOURCES:-user}" 2>/dev/null )
}

# The model is asked for a bare object on the last line, but a chatty reply is the common failure —
# so take the LAST brace-delimited run rather than the whole transcript.
scout::extract_json() { # reads the scout's stdout on stdin
  grep -o '{[^{}]*}' | tail -1
}

# ── entrypoints ─────────────────────────────────────────────────────────────────────────────────
MODE_SCORE=0; MODE_VERDICT=0
case "${1:-}" in
  --score)   MODE_SCORE=1;   shift ;;
  --verdict) MODE_VERDICT=1; shift ;;
esac

if [[ "$MODE_SCORE" -eq 1 ]]; then
  # Explicit rc capture: under `set -e` a bare `scout::score` returning 2 would abort before the
  # `exit`, and the guard's REJECT code is exactly what a caller needs to see.
  src="${1:--}"; rc=0
  if [[ "$src" == "-" ]]; then scout::score || rc=$?; else scout::score < "$src" || rc=$?; fi
  exit "$rc"
fi

N="${1:?ticket number required}"
[[ "$N" =~ ^[0-9]+$ ]] || govern::die "ticket number must be numeric, got '$N'"

# Cache-read only. stderr is deliberately NOT suppressed: this is the path spawn-worker.sh calls, so
# a cache that fails the guard there surfaces the same loud govern::log line into the run log.
if [[ "$MODE_VERDICT" -eq 1 ]]; then
  scout::verdict_from_cache "$N" || exit 1
  exit 0
fi

if [[ "${GOVERN_SCOUT:-1}" == "0" ]]; then
  govern::log "scout #$N: disabled (GOVERN_SCOUT=0) — sizing falls through to the ticket fields / GOVERN_WORKER_MODEL"
  exit 1
fi

# Cache hit → this is a retry (or a second dispatch) inside the same run. Reuse, don't re-scout.
if cached="$(scout::verdict_from_cache "$N" 2>/dev/null)"; then
  govern::log "scout #$N: cache hit — $(printf '%s' "$cached" | tr '\t' ' ')"
  printf '%s\n' "$cached"
  exit 0
fi

block="$(govern::ticket_block "$N" "$TICKETS_FILE" 2>/dev/null || true)"
[[ -n "$block" ]] || { govern::log "scout #$N: ticket not found in $TICKETS_FILE — skipping the scout, sizing falls back"; exit 1; }

raw=""; rc=0
raw="$(scout::run_pass "$N" "$block")" || rc=$?
if [[ "$rc" -eq 124 ]]; then
  govern::log "scout #$N: TIMED OUT after ${GOVERN_SCOUT_TIMEOUT:-$SCOUT_TIMEOUT_DEFAULT}s — falling back to GOVERN_WORKER_MODEL (no scout verdict cached)"
  exit 1
fi
if [[ "$rc" -ne 0 ]]; then
  govern::log "scout #$N: scout pass exited $rc — falling back to GOVERN_WORKER_MODEL (no scout verdict cached)"
  exit 1
fi

scope="$(printf '%s' "$raw" | scout::extract_json || true)"
if [[ -z "$scope" ]]; then
  govern::log "scout #$N: no JSON object found in the scout reply — falling back to GOVERN_WORKER_MODEL"
  exit 1
fi

verdict=""
verdict="$(printf '%s' "$scope" | scout::score)" || {
  govern::log "scout #$N: scope JSON rejected by the guard — falling back to GOVERN_WORKER_MODEL"
  exit 1
}

IFS=$'\t' read -r sc_model sc_effort sc_class <<<"$verdict"

# Cache only a verdict that already PASSED the guard, so `--verdict` never re-litigates a rejection.
logdir="$(govern::worker_logdir "$N")"; mkdir -p "$logdir"
jq -nc --argjson n "$N" --argjson scope "$scope" \
   --arg m "$sc_model" --arg e "$sc_effort" --arg c "$sc_class" \
   --arg tier "${GOVERN_SCOUT_MODEL:-haiku}" --argjson ts "$(date +%s)" \
   '{ticket:$n, scope:$scope, verdict:{model:$m, effort:$e, scopeClass:$c},
     scoutModel:$tier, ts:$ts}' > "$(scout::cache_path "$N")" 2>/dev/null || true

govern::log "scout #$N: scope=$sc_class → model=$sc_model effort=$sc_effort (measured: $(printf '%s' "$scope" | jq -c '{files,repos,testsCover,precedent,changeKind,fixDirection}' 2>/dev/null || printf '%s' "$scope"))"
printf '%s\n' "$verdict"
