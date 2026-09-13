#!/usr/bin/env bash
# Scout: a cheap pre-dispatch SURVEY of a ticket. It measures scope and locates pointers — it does
# NOT decide the worker's tier any more.
#
# Why the demotion: the scout used to also SCORE its measurement into (model, effort). Measured on
# the real backlog, 4 of the 5 cached verdicts it ever produced were `opus/high`, and 3 tickets it
# sized `opus` then succeeded at `sonnet` on attempt 1. It was a rubber stamp, not arbitrage. Tier is
# now decided WITHOUT the scout: a cheap floor (`GOVERN_WORKER_MODEL`) plus escalate-once-on-failure
# (`GOVERN_WORKER_ESCALATION_MODEL`). So the difficulty verdict is gone — the survey stays.
#
# What the survey is FOR now:
#   - `targetPaths` — real, verified, repo-relative paths. The load-bearing field: the batching layer
#     keys on it, and the worker gets it as a warm start instead of rediscovering it at full price.
#   - the six former scoring fields — kept as pure MEASUREMENTS (codebase index, batch key, warm
#     start). Nothing scores them.
#
# Modes (stdout contract is explicit — callers must not parse anything else):
#   scout-ticket.sh <N>                run-or-reuse-cache; writes <worker-logdir>/scout.json.
#                                      STDOUT IS EMPTY on every path. The measured summary goes to
#                                      STDERR via govern::log. rc 0 on a usable survey, 1 otherwise
#                                      (disabled, no ticket, timeout, unparseable, guard reject).
#   scout-ticket.sh --findings <N>     cache-READ only, no model. Prints the
#                                      "## Scout findings — UNVERIFIED pointers" markdown block.
#                                      rc 1 + no output when nothing was located.
#   scout-ticket.sh --paths <N>        cache-READ only, no model. Prints targetPaths, ONE PER LINE.
#                                      rc 1 + no output when there are none. Batch-key source.
#
# GUARD — scout output is UNTRUSTED model output:
#   - not a JSON object, or a required measurement key missing → REJECTED, loudly, nothing cached.
#   - present but out-of-domain (unknown enum, non-integer, absurd count, oversized string) → CLAMPED,
#     loudly. Clamping no longer biases "toward hard" (nothing is being scored); it just sanitizes.
#
# Env knobs:
#   GOVERN_SCOUT=0            disable the model pass entirely (exit 1, nothing cached)
#   GOVERN_SCOUT_MODEL        tier the scout pass itself runs at (default `haiku`)
#   GOVERN_SCOUT_TIMEOUT      wall-clock bound on the scout pass, seconds (default 180)
#   GOVERN_CLAUDE_BIN         the claude binary (shared with spawn-worker.sh)
#   GOVERN_SETTING_SOURCES    forwarded to `claude -p` (default `project,local`)
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib/common.sh"
govern::require jq

SCOUT_TIMEOUT_DEFAULT=180
SCOUT_MAX_FILES=999
SCOUT_MAX_REPOS=99
SCOUT_MAX_PATHS=8

# ── sanitize (pure bash + jq, no LLM) ───────────────────────────────────────────────────────────
# Reads the raw scope object on stdin, prints a NORMALIZED compact object on stdout. Returns 2 when
# the input is structurally unusable — the caller then skips caching, loudly.
scout::sanitize_scope() {
  local raw files repos tests prec kind dir
  raw="$(cat)"

  if ! printf '%s' "$raw" | jq -e 'type == "object"' >/dev/null 2>&1; then
    govern::log "scout: REJECTED — output is not a JSON object"
    return 2
  fi
  # Every measurement key must be PRESENT. A missing key is a malformed scout, not a defaultable one:
  # silently defaulting would let a truncated response masquerade as a real measurement.
  if ! printf '%s' "$raw" | jq -e 'has("files") and has("repos") and has("testsCover")
        and has("precedent") and has("changeKind") and has("fixDirection")' >/dev/null 2>&1; then
    govern::log "scout: REJECTED — scope JSON is missing required keys (need files/repos/testsCover/precedent/changeKind/fixDirection)"
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
  kind="$(scout::clamp_enum changeKind "$kind" local local structural)"
  dir="$(scout::clamp_enum fixDirection "$dir" vague concrete vague)"

  printf '%s' "$raw" | jq -c \
    --argjson files "$files" --argjson repos "$repos" \
    --argjson tests "$tests" --argjson prec "$prec" \
    --arg kind "$kind" --arg dir "$dir" \
    --argjson maxp "$SCOUT_MAX_PATHS" \
    '{files:$files, repos:$repos, testsCover:$tests, precedent:$prec,
      changeKind:$kind, fixDirection:$dir,
      targetPaths: ((.targetPaths? // []) | if type=="array" then . else [] end
        | map(select(type=="string" and length>0 and length<400)) | .[0:$maxp]),
      precedentCommit: (.precedentCommit? // "" | if type=="string" then .[0:200] else "" end),
      testCommand: (.testCommand? // "" | if type=="string" then .[0:400] else "" end)}'
  return 0
}

# Non-integer → 0 (no measurement); over-ceiling → the ceiling. Neither biases a decision any more.
scout::clamp_int() { # <field> <value> <max>
  local field="$1" v="$2" max="$3"
  if [[ ! "$v" =~ ^[0-9]+$ ]]; then
    govern::log "scout: CLAMPED — $field='$v' is not a non-negative integer; using 0"
    printf '0'; return 0
  fi
  if [[ "$v" -gt "$max" ]]; then
    govern::log "scout: CLAMPED — $field=$v exceeds $max; using $max"
    printf '%s' "$max"; return 0
  fi
  printf '%s' "$v"
  return 0
}

scout::clamp_bool() { # <field> <value>
  local field="$1" v="$2"
  case "$v" in
    true|false) printf '%s' "$v" ;;
    *) govern::log "scout: CLAMPED — $field='$v' is not a boolean; using false"
       printf 'false' ;;
  esac
  return 0
}

scout::clamp_enum() { # <field> <value> <fallback> <allowed...>
  local field="$1" v="$2" fallback="$3"; shift 3
  local a
  for a in "$@"; do
    if [[ "$v" == "$a" ]]; then printf '%s' "$v"; return 0; fi
  done
  govern::log "scout: CLAMPED — $field='$v' is not one of [$*]; using '$fallback'"
  printf '%s' "$fallback"
  return 0
}

# ── cache ───────────────────────────────────────────────────────────────────────────────────────
# Run-scoped (logs/govern/run-<ts>/ticket-N/scout.json via govern::worker_logdir), so a RETRY inside
# the same run reuses the survey instead of re-scouting, and a fresh run re-measures against fresh
# code. Schema: {ticket, scope:{...sanitized survey...}, scoutModel, ts} — no `verdict` key.
scout::cache_path() { # <N>
  printf '%s/scout.json' "$(govern::worker_logdir "$1")"
}

scout::scope_from_cache() { # <N> -> compact scope JSON | nonzero
  local n="$1" cache scope
  cache="$(scout::cache_path "$n")"
  [[ -s "$cache" ]] || return 1
  scope="$(jq -c '.scope' "$cache" 2>/dev/null || true)"
  [[ -n "$scope" && "$scope" != "null" ]] || return 1
  printf '%s' "$scope"
  return 0
}

# targetPaths, one per line. Defensive re-filter: a hand-seeded or older cache may hold anything.
scout::paths_from_cache() { # <N> -> paths | nonzero
  local n="$1" scope paths
  scope="$(scout::scope_from_cache "$n")" || return 1
  paths="$(printf '%s' "$scope" | jq -r "
      (.targetPaths? // []) | if type==\"array\" then . else [] end
      | map(select(type==\"string\" and length>0 and length<400)) | .[0:$SCOUT_MAX_PATHS] | .[]" \
      2>/dev/null || true)"
  [[ -n "$paths" ]] || return 1
  printf '%s\n' "$paths"
  return 0
}

# ── the findings block ──────────────────────────────────────────────────────────────────────────
# The scout had to LOCATE the target files, the analogous prior commit, and the test command in order
# to answer its questions. This prints those pointers as a markdown block for spawn-worker.sh to
# append to the worker prompt. Silent no-op (rc 1, no output) when there is no cache or the scout
# located nothing.
#
# They are HINTS, not instructions, and the block below says so: the scout is a cheap haiku pass and
# a confidently wrong pointer that the worker follows costs more than no pointer at all.
scout::findings_from_cache() { # <N> -> markdown block | nonzero
  local n="$1" scope paths prec test out
  scope="$(scout::scope_from_cache "$n")" || return 1
  paths="$(scout::paths_from_cache "$n" || true)"
  prec="$(printf '%s' "$scope" | jq -r '
      .precedentCommit? // "" | if type=="string" then . else "" end' 2>/dev/null || true)"
  test="$(printf '%s' "$scope" | jq -r '
      .testCommand? // "" | if type=="string" then . else "" end' 2>/dev/null || true)"
  [[ "${#prec}" -le 200 ]] || prec=""
  [[ "${#test}" -le 400 ]] || test=""

  [[ -n "$paths" || -n "$prec" || -n "$test" ]] || return 1

  out="## Scout findings — UNVERIFIED pointers, not instructions
A cheap read-only pass located these before you were dispatched. They exist to save you the
rediscovery, NOT to constrain the fix. The scout ran at a low tier and may simply be wrong: cheaply
confirm anything you are about to depend on, and if a pointer does not match the code, IGNORE IT and
explore normally — do not bend the fix to fit it."
  if [[ -n "$paths" ]]; then
    out="$out

**Files it counted as in-scope** (workspace-relative):
$(printf '%s\n' "$paths" | sed 's/^/- `/; s/$/`/')"
  fi
  [[ -n "$prec" ]] && out="$out

**Analogous prior commit:** \`$prec\` — \`git show $prec\` for the shape of the precedent."
  [[ -n "$test" ]] && out="$out

**Test command covering this area:** \`$test\` (redirect + tail it, per the output discipline above)."
  printf '%s\n' "$out"
  return 0
}

# ── the model half (exactly ONE claude invocation, here) ────────────────────────────────────────
scout::prompt() { # <N> <block>
  local n="$1" block="$2"
  cat <<EOF
SCOUT survey for ticket #$n. Do NOT edit anything. Survey only: a few targeted greps, at most skim the files you find. Seed from the ticket's \`Where:\` line.

Workspace root: $WS_ROOT
Sub-repos: ${REPOS[*]:-<none>}

<ticket number="$n">
$block
</ticket>

Locate what the fix needs, then report these MEASUREMENTS (they are recorded, not scored — do not shade them):
  files        files the fix plausibly touches (int; 0 if none located)
  repos        distinct sub-repos involved (int)
  testsCover   true if tests already exercise this area, else false
  precedent    true if \`git log --oneline -- <path>\` shows an analogous prior commit, else false
  changeKind   "local" (edit inside function bodies) or "structural" (signature/schema/API-contract change)
  fixDirection "concrete" (ticket names the change) or "vague" (approach still needs designing)

  targetPaths     THE MOST IMPORTANT FIELD. Repo-relative paths of the files the fix touches, most
                  relevant first, max 8. Every path must be one you ACTUALLY VERIFIED EXISTS (you
                  read it, grepped it, or listed it) — never a plausible-looking guess. Downstream
                  code keys on these, so a hallucinated path is worse than a short list: emit FEWER
                  rather than invent. [] if you verified none.
  precedentCommit short SHA of the analogous commit if precedent=true, else ""
  testCommand     the real command that runs the covering tests if testsCover=true (copy it from the
                  repo's config/README — do not invent one), else ""

Output ONLY a single JSON object as the LAST line. No prose, no code fence:
{"files":0,"repos":0,"testsCover":false,"precedent":false,"changeKind":"local","fixDirection":"vague","targetPaths":[],"precedentCommit":"","testCommand":""}
EOF
}

# Bounded run of the scout pass. Read-only by construction: `--permission-mode plan` lets the pass
# search and read but never write, so a scout can't mutate the tree it is measuring.
scout::run_pass() { # <N> <block> -> raw stdout
  local n="$1" block="$2"
  local bin="${GOVERN_CLAUDE_BIN:-claude}"
  local secs="${GOVERN_SCOUT_TIMEOUT:-$SCOUT_TIMEOUT_DEFAULT}"
  local tier="${GOVERN_SCOUT_MODEL:-haiku}"
  # Session ceiling: the scout is a haiku recon pass by default, so this is normally a no-op. It is
  # applied anyway because GOVERN_SCOUT_MODEL is an operator knob and the rail has to hold for every
  # `--model` the harness assembles, not only the expensive ones.
  tier="$(govern::model_clamp "$tier")"
  local prompt; prompt="$(scout::prompt "$n" "$block")"
  ( cd "$WS_ROOT" && govern::run_bounded "$secs" "$bin" -p "$prompt" \
      --model "$tier" --permission-mode plan --strict-mcp-config \
      --setting-sources "${GOVERN_SETTING_SOURCES:-project,local}" 2>/dev/null )
}

# The model is asked for a bare object on the last line, but a chatty reply is the common failure.
# A naive `grep -o '{[^{}]*}' | tail -1` cannot survive a chatty reply that embeds another brace
# pair before the survey. So reuse the string/escape-aware balanced-brace scanner from common.sh
# (govern::_json_objects, the same one govern::extract_report is built on) and keep the LAST
# top-level object that carries a `files` key, which is what identifies a survey.
scout::extract_json() { # reads the scout's stdout on stdin
  local raw cand best=""
  raw="$(cat)"
  [[ -n "$raw" ]] || return 0
  # Happy path: the whole reply is exactly one object → emit verbatim.
  if printf '%s' "$raw" | jq -e -s 'length==1 and (.[0]|type=="object") and (.[0]|has("files"))' >/dev/null 2>&1; then
    printf '%s' "$raw"; return 0
  fi
  while IFS= read -r -d $'\x1e' cand; do
    [[ -n "$cand" ]] || continue
    if printf '%s' "$cand" | jq -e 'type=="object" and has("files")' >/dev/null 2>&1; then best="$cand"; fi
  done < <(printf '%s' "$raw" | govern::_json_objects)
  printf '%s' "$best"
  return 0
}

# ── entrypoints ─────────────────────────────────────────────────────────────────────────────────
MODE_FINDINGS=0; MODE_PATHS=0
case "${1:-}" in
  --findings)      MODE_FINDINGS=1; shift ;;
  --paths)         MODE_PATHS=1;    shift ;;
esac

N="${1:?ticket number required}"
[[ "$N" =~ ^[0-9]+$ ]] || govern::die "ticket number must be numeric, got '$N'"

# Cache-READ modes. No model call on any of these paths. stderr is deliberately NOT suppressed so a
# cache that fails the guard surfaces the same loud govern::log line into the run log.
if [[ "$MODE_FINDINGS" -eq 1 ]]; then scout::findings_from_cache "$N" || exit 1; exit 0; fi
if [[ "$MODE_PATHS"    -eq 1 ]]; then scout::paths_from_cache    "$N" || exit 1; exit 0; fi

if [[ "${GOVERN_SCOUT:-1}" == "0" ]]; then
  govern::log "scout #$N: disabled (GOVERN_SCOUT=0) — no survey, no cache"
  exit 1
fi

# Cache hit → this is a retry (or a second dispatch) inside the same run. Reuse, don't re-scout.
if cached="$(scout::scope_from_cache "$N" 2>/dev/null)"; then
  govern::log "scout #$N: cache hit — $(printf '%s' "$cached" | jq -c '{files,repos,targetPaths}' 2>/dev/null || printf '%s' "$cached")"
  exit 0
fi

block="$(govern::ticket_block "$N" "$TICKETS_FILE" 2>/dev/null || true)"
[[ -n "$block" ]] || { govern::log "scout #$N: ticket not found in $TICKETS_FILE — no survey"; exit 1; }

raw=""; rc=0
raw="$(scout::run_pass "$N" "$block")" || rc=$?
if [[ "$rc" -eq 124 ]]; then
  govern::log "scout #$N: TIMED OUT after ${GOVERN_SCOUT_TIMEOUT:-$SCOUT_TIMEOUT_DEFAULT}s — no survey cached"
  exit 1
fi
if [[ "$rc" -ne 0 ]]; then
  govern::log "scout #$N: scout pass exited $rc — no survey cached"
  exit 1
fi

scope_raw="$(printf '%s' "$raw" | scout::extract_json || true)"
if [[ -z "$scope_raw" ]]; then
  govern::log "scout #$N: no survey JSON object found in the scout reply — no survey cached"
  exit 1
fi

# Explicit rc capture: under `set -e` a bare call returning 2 would abort before the log line.
scope=""; srce=0
scope="$(printf '%s' "$scope_raw" | scout::sanitize_scope)" || srce=$?
if [[ "$srce" -ne 0 || -z "$scope" ]]; then
  govern::log "scout #$N: scope JSON rejected by the guard — no survey cached"
  exit 1
fi

# Cache only a survey that already PASSED the guard, in its SANITIZED form.
logdir="$(govern::worker_logdir "$N")"; mkdir -p "$logdir"
jq -nc --argjson n "$N" --argjson scope "$scope" \
   --arg tier "${GOVERN_SCOUT_MODEL:-haiku}" --argjson ts "$(date +%s)" \
   '{ticket:$n, scope:$scope, scoutModel:$tier, ts:$ts}' > "$(scout::cache_path "$N")" 2>/dev/null || true

govern::log "scout #$N: surveyed — $(printf '%s' "$scope" | jq -c '{files,repos,testsCover,precedent,changeKind,fixDirection,paths:(.targetPaths|length)}' 2>/dev/null || printf '%s' "$scope")"
exit 0
