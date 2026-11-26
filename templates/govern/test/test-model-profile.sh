#!/usr/bin/env bash
# Model profiles: one file per model family, roles everywhere else. With SHIPLOOP_MODEL_PROFILE set
# the dispatch path speaks ROLES and a concrete model is chosen at spawn by the model-router mod;
# with it unset nothing reads a profile and every path below is exactly what it was.
#
#   1. the reader (govern::model_profile_* in lib/common.sh): no profile answers "" everywhere; an
#      active profile answers its values; a name that is not a plain name, a missing file and an
#      unknown key each read as unset; GOVERN_MODEL_PROFILE_DIR overrides where profiles live.
#   2. the model ladder: with no profile the Claude ladder is unchanged; under a profile a model
#      ranks by its first position on TIER_ORDER, an alias falls through to the Claude ladder, the
#      session ceiling reads the same ladder, and a profile whose file is missing changes nothing.
#   3. dispatch-packet.sh: under a profile the packet carries `Role:` and never `Model:`, the role
#      comes from --role, then GOVERN_WORKER_ROLE, then worker, and --model is refused; with no
#      profile the packet is the `Model:` line it always was and --role is refused.
#   4. dispatch.sh: under a profile the printed Agent call names the role's type and carries no
#      model; with no profile the call is unchanged.
#   5. router-posture-guard.sh's dispatch preparer: under a profile the packet's Role line follows
#      the call's type, a `model` the call passed is ignored, a packet cut under the other mode has
#      its line converted, and the extra context names the role.
#   6. the steer guard records a worker-retry dispatch like a worker's.
#   7. worker-retry.md is worker.md under another name.
# The hook, the real dispatch scripts and the real common.sh run in stub roots; nothing touches the
# network or a model.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

COMMON="$DIR/../lib/common.sh"
DP="$DIR/../dispatch-packet.sh"
DS="$DIR/../dispatch.sh"
GUARD="${GOVERN_HOOKS_DIR:-}/router-posture-guard.sh"
STEER="${GOVERN_HOOKS_DIR:-}/advisor-steer-guard.sh"
[[ -f "$COMMON" && -f "$DP" && -f "$DS" && -f "$GUARD" && -f "$STEER" ]] \
  || { echo "SKIP: dispatch scripts, common.sh or hooks not found in this layout"; exit 77; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; exit 77; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 required by the hook under test"; exit 77; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq required"; exit 77; }
unset SHIPLOOP_MODEL_PROFILE GOVERN_MODEL_PROFILE_DIR GOVERN_WORKER_ROLE   # assert.sh sweeps these; restated for the reader

# A small family for the fixtures: three tiers, so the ladder has a top, a middle and a floor.
PROFILE_DIR="$(mktemp -d)"; trap 'rm -rf "$PROFILE_DIR"' EXIT
cat > "$PROFILE_DIR/testfam.conf" <<'CONF'
FAMILY=testfam
SESSION_MODEL="tf-top[1m]"
PICKER="tf-top[1m]|tf-mid|tf-floor[1m]"
ROLE_advisor="tf-top[1m]"
ROLE_worker="tf-floor[1m]"
ROLE_worker_retry="tf-top[1m]"
ROLE_investigator="tf-mid"
ROLE_lookup="tf-floor[1m]"
TIER_ORDER="advisor worker_retry investigator worker lookup"
CONF
mkdir -p "$PROFILE_DIR/ws"
mk_ws_stub "$PROFILE_DIR/ws"
# shellcheck source=/dev/null
. "$COMMON"
set +e   # common.sh re-arms set -e; a test asserts on failing commands
export GOVERN_MODEL_PROFILE_DIR="$PROFILE_DIR"

# ── 1. the reader ──────────────────────────────────────────────────────────────────────────────
assert_eq "$(govern::model_profile_name)|$(govern::model_profile_file)|$(govern::model_profile_get ROLE_worker)|$(govern::model_profile_role worker-retry)" "|||" \
  "1. no profile: name, file and every value answer empty"
SHIPLOOP_MODEL_PROFILE=testfam
assert_eq "$(govern::model_profile_name)" "testfam" "1. the profile's name"
assert_eq "$(govern::model_profile_file)" "$PROFILE_DIR/testfam.conf" "1. the profile's file"
assert_eq "$(govern::model_profile_get SESSION_MODEL)" "tf-top[1m]" "1. a quoted value comes back unquoted, [1m] intact"
assert_eq "$(govern::model_profile_get TIER_ORDER)" "advisor worker_retry investigator worker lookup" "1. TIER_ORDER comes back whole"
assert_eq "$(govern::model_profile_get ROLE_worker_retry)" "tf-top[1m]" "1. ROLE_worker_retry reads the retry role"
assert_eq "$(govern::model_profile_role worker)" "tf-floor[1m]" "1. model_profile_role worker reads ROLE_worker"
assert_eq "$(govern::model_profile_role worker-retry)" "tf-top[1m]" "1. model_profile_role worker-retry reads ROLE_worker_retry (dash taken as underscore)"
assert_eq "$(govern::model_profile_role lens)" "" "1. a role the profile does not hold answers empty"
assert_eq "$(govern::model_profile_get NO_SUCH_KEY)" "" "1. an unknown key answers empty"
assert_eq "$(govern::model_profile_get 'ROLE_x"; echo pwned')" "" "1. a key that is not an identifier answers empty and runs nothing"
printf 'ROLE_worker =  "tf-dir"\n# ROLE_lookup="commented"\n' > "$PROFILE_DIR/plain.conf"
SHIPLOOP_MODEL_PROFILE=plain
assert_eq "$(govern::model_profile_get ROLE_worker)" "tf-dir" "1. spaces around = are tolerated and the value unquoted"
assert_eq "$(govern::model_profile_get ROLE_lookup)" "" "1. a commented-out line is not a value"
for bad in "../etc/passwd" "a b" "" "tf/.."; do
  SHIPLOOP_MODEL_PROFILE="$bad"
  assert_eq "$(govern::model_profile_name)|$(govern::model_profile_file)|$(govern::model_profile_get ROLE_worker)" "||" "1. profile name [$bad] is no profile"
done
SHIPLOOP_MODEL_PROFILE=nosuchfile
assert_eq "$(govern::model_profile_file)|$(govern::model_profile_get ROLE_worker)" "|" "1. a profile whose file is missing answers empty"
# Without the override the profiles are looked up in the workspace and then beside the libs.
R="$(mktemp -d)"; mkdir -p "$R/scripts/lib/model-profiles" "$R/scripts/lib"
printf 'META_ROOT="${META_ROOT:-%s}"\nREPOS=(alpha)\nwsp_is_merge_repo() { return 1; }\n' "$R" > "$R/scripts/lib/workspace.sh"
printf 'ROLE_worker="tf-ws"\n' > "$R/scripts/lib/model-profiles/testfam.conf"
ws_dir="$(GOVERN_WS_ROOT="$R" GOVERN_MODEL_PROFILE_DIR= bash -c '. "$1" >/dev/null 2>&1; govern::model_profile_dir' _ "$COMMON")"
assert_eq "$ws_dir" "$R/scripts/lib/model-profiles" "1. with no override the workspace's scripts/lib/model-profiles is where profiles are read from"
rm -rf "$R"

# ── 2. the model ladder ────────────────────────────────────────────────────────────────────────
unset SHIPLOOP_MODEL_PROFILE
assert_eq "$(govern::model_rank opus)|$(govern::model_rank sonnet)|$(govern::model_rank claude-opus-5)|$(govern::model_rank 'tf-top[1m]')" "30000|20000|30500|0" \
  "2. no profile: the Claude ladder is unchanged and a profile model does not rank"
assert_eq "$(GOVERN_SESSION_MODEL= govern::model_ceiling)" "opus" "2. no profile: an undetectable session keeps the opus ceiling"
SHIPLOOP_MODEL_PROFILE=testfam
r_top="$(govern::model_rank 'tf-top[1m]')"; r_mid="$(govern::model_rank tf-mid)"; r_floor="$(govern::model_rank 'tf-floor[1m]')"
assert_eq "$([ "$r_top" -gt "$r_mid" ] && [ "$r_mid" -gt "$r_floor" ] && [ "$r_floor" -gt "$(govern::model_rank opus)" ] && echo ordered)" "ordered" \
  "2. under a profile: top > mid > floor, and every profile tier outranks any Claude name"
assert_eq "$(govern::model_rank TF-TOP)" "$r_top" "2. the comparison ignores case and the [1m] suffix"
assert_eq "$(govern::model_rank sonnet)" "20000" "2. a Claude alias still falls through to the Claude ladder"
assert_eq "$(govern::model_rank tf-unknown)" "0" "2. a model the profile does not place does not rank"
assert_eq "$(GOVERN_SESSION_MODEL= govern::model_ceiling)" "tf-top[1m]" "2. an undetectable session gets the ladder's top as its ceiling"
assert_eq "$(GOVERN_SESSION_MODEL=tf-mid govern::model_ceiling)" "tf-mid" "2. a session on the middle tier is its own ceiling"
assert_eq "$(GOVERN_SESSION_MODEL=tf-floor govern::model_clamp tf-top 2>/dev/null)" "tf-floor" "2. a request for the top under a floor session is clamped to the floor (the session's model, verbatim)"
assert_eq "$(GOVERN_SESSION_MODEL=tf-top govern::model_clamp tf-floor 2>/dev/null)" "tf-floor" "2. a request for the floor under a top session passes untouched"
SHIPLOOP_MODEL_PROFILE=nosuchfile
assert_eq "$(govern::model_rank 'tf-top[1m]')|$(GOVERN_SESSION_MODEL= govern::model_ceiling)" "0|opus" \
  "2. a profile whose file is missing leaves the Claude ladder and the opus ceiling in place"
unset SHIPLOOP_MODEL_PROFILE

# ── the real dispatch scripts, in a real meta root (as test-dispatch-packet.sh builds one) ─────
TICKETS_BODY='# Tickets

## #7: tighten the alpha retry ladder

**Severity:** Low

**Where:** `alpha/retry.conf`

**Proposed solution:** cap it at three.

**Precision:** stated

Done when: the ladder stops at three.
'
setup_case() { # sets CASE_T
  CASE_T="$(mktemp -d)"
  local t="$CASE_T"
  mkdir -p "$t/scripts/worktree/lib" "$t/scripts/lib" "$t/alpha" "$t/queue" "$t/governor"
  cp "$DIR/../../worktree/new.sh" "$t/scripts/worktree/new.sh"
  cp "$DIR/../../worktree/lib/registry.sh" "$t/scripts/worktree/lib/registry.sh"
  cp "$DIR/../../worktree/lib/base-ref.sh" "$t/scripts/worktree/lib/base-ref.sh"
  cat > "$t/scripts/lib/workspace.sh" <<EOF2
ROOT_PM=npm
GITHUB_ORG=acme
WORKTREE_BASE="$t/wt"
REPOS=(alpha)
REPO_PORTS=("")
SLOT_PORT_STEP=10
wsp_repos_csv() { echo alpha; }
wsp_repo_port() { :; }
wsp_repo_slug() { printf 'acme/%s' "\$1"; }
wsp_repo_localdir() { printf '%s/%s' "$t" "\$1"; }
wsp_is_merge_repo() { return 1; }
EOF2
  printf '%s' "$TICKETS_BODY" > "$t/queue/tickets.md"
  git -C "$t" init -q -b main
  git -C "$t" config user.email t@t; git -C "$t" config user.name t
  echo root > "$t/root.txt"; git -C "$t" add -A; git -C "$t" commit -qm init >/dev/null
  git -C "$t/alpha" init -q -b main
  git -C "$t/alpha" config user.email t@t; git -C "$t/alpha" config user.name t
  echo "retry = 5" > "$t/alpha/retry.conf"; git -C "$t/alpha" add -A; git -C "$t/alpha" commit -qm init >/dev/null
  export GOVERN_WS_ROOT="$t"
  export GOVERN_QUEUE_DIR="$t/queue"
  export WORKTREE_ASSUME_YES=1 WORKTREE_FREE_GB_OVERRIDE=10
}
run_in() { ( cd "$CASE_T" && env "$@" ) 2>/dev/null; }        # stdout only
run_err() { ( cd "$CASE_T" && env "$@" ) 2>&1; }               # a refusal's message is the subject

# ── 3. dispatch-packet.sh ─────────────────────────────────────────────────────────────────────
setup_case
out="$(run_in SHIPLOOP_MODEL_PROFILE=testfam bash "$DP" 7)"; rc=$?
packet="$(printf '%s\n' "$out" | sed -n '1p')"
assert_eq "$rc" "0" "3. under a profile the packet is cut"
assert_eq "$(sed -n -E 's/^(Role|Model): (.*)$/\1=\2/p' "$packet")" "Role=worker" "3. under a profile the packet carries Role: worker and no Model: line"
assert_not_contains "$(cat "$packet")" "Model: " "3. ...no Model: line anywhere in it"
out="$(run_in SHIPLOOP_MODEL_PROFILE=testfam bash "$DP" 7 --role worker-retry)"
assert_eq "$(sed -n -E 's/^(Role|Model): (.*)$/\1=\2/p' "$(printf '%s\n' "$out" | sed -n '1p')")" "Role=worker-retry" "3. --role worker-retry is recorded"
out="$(run_in SHIPLOOP_MODEL_PROFILE=testfam GOVERN_WORKER_ROLE=worker-retry bash "$DP" 7)"
assert_eq "$(sed -n -E 's/^(Role|Model): (.*)$/\1=\2/p' "$(printf '%s\n' "$out" | sed -n '1p')")" "Role=worker-retry" "3. GOVERN_WORKER_ROLE=worker-retry is recorded"
out="$(run_in SHIPLOOP_MODEL_PROFILE=testfam GOVERN_WORKER_ROLE=worker-retry bash "$DP" 7 --role worker)"
assert_eq "$(sed -n -E 's/^(Role|Model): (.*)$/\1=\2/p' "$(printf '%s\n' "$out" | sed -n '1p')")" "Role=worker" "3. --role wins over GOVERN_WORKER_ROLE"
err="$(run_err SHIPLOOP_MODEL_PROFILE=testfam bash "$DP" 7 --model opus 2>&1)"; rc=$?
assert_eq "$rc" "1" "3. under a profile --model is refused"
assert_contains "$err" "SHIPLOOP_MODEL_PROFILE=testfam is active" "3. the refusal names the active profile"
assert_contains "$err" "--role" "3. the refusal names the flag to use instead"
err="$(run_err SHIPLOOP_MODEL_PROFILE=testfam bash "$DP" 7 --role opus 2>&1)"; rc=$?
assert_eq "$rc" "1" "3. a role that is not worker or worker-retry is refused"
err="$(cd "$CASE_T" && env -u SHIPLOOP_MODEL_PROFILE bash "$DP" 7 --role worker 2>&1)"; rc=$?
assert_eq "$rc" "1" "3. with no profile --role is refused"
out="$(cd "$CASE_T" && env -u SHIPLOOP_MODEL_PROFILE bash "$DP" 7 2>/dev/null)"
assert_eq "$(sed -n -E 's/^(Role|Model): (.*)$/\1=\2/p' "$(printf '%s\n' "$out" | sed -n '1p')")" "Model=sonnet" "3. with no profile the packet carries Model: sonnet, as before"
out="$(cd "$CASE_T" && env -u SHIPLOOP_MODEL_PROFILE bash "$DP" 7 --model opus 2>/dev/null)"
assert_eq "$(sed -n -E 's/^(Role|Model): (.*)$/\1=\2/p' "$(printf '%s\n' "$out" | sed -n '1p')")" "Model=opus" "3. with no profile --model opus is recorded, as before"
rm -rf "$CASE_T"

# ── 4. dispatch.sh ────────────────────────────────────────────────────────────────────────────
setup_case
out="$(run_in SHIPLOOP_MODEL_PROFILE=testfam bash "$DS" 7)"; rc=$?
assert_eq "$rc" "0" "4. under a profile dispatch runs"
assert_contains "$out" 'subagent_type: "worker",' "4. the printed call names the worker type"
assert_not_contains "$out" 'model: "' "4. the printed call carries no model"
assert_contains "$(cat "$CASE_T/wt/t7/.dispatch-packet.md")" "Role: worker" "4. the packet carries Role: worker"
out="$(run_in SHIPLOOP_MODEL_PROFILE=testfam bash "$DS" 7 --role worker-retry)"
assert_contains "$out" 'subagent_type: "worker-retry",' "4. --role worker-retry prints a worker-retry call"
assert_not_contains "$out" 'model: "' "4. ...still with no model"
assert_contains "$(cat "$CASE_T/wt/t7/.dispatch-packet.md")" "Role: worker-retry" "4. ...and its packet says so"
err="$(run_err SHIPLOOP_MODEL_PROFILE=testfam bash "$DS" 7 --model opus 2>&1)"; rc=$?
assert_eq "$rc" "1" "4. under a profile dispatch.sh refuses --model"
assert_contains "$err" "--role" "4. ...and names --role"
rm -rf "$CASE_T"
setup_case
out="$(cd "$CASE_T" && env -u SHIPLOOP_MODEL_PROFILE bash "$DS" 7 2>/dev/null)"
assert_contains "$out" 'subagent_type: "worker",' "4. with no profile the call names the worker type, as before"
assert_not_contains "$out" 'model: "' "4. ...with no model for the default, as before"
assert_contains "$(cat "$CASE_T/wt/t7/.dispatch-packet.md")" "Model: sonnet" "4. ...and a Model: sonnet packet, as before"
out="$(cd "$CASE_T" && env -u SHIPLOOP_MODEL_PROFILE bash "$DS" 7 --model opus 2>/dev/null)"
assert_contains "$out" 'model: "opus",' "4. with no profile --model opus still prints model: opus, as before"
rm -rf "$CASE_T"

# ── 5. the guard's dispatch preparer ──────────────────────────────────────────────────────────
# The hook, the real dispatch.sh (for --print-blocks) and the real common.sh in a fake scaffolded
# root; pre-dispatch-check.sh and dispatch-packet.sh are stubs, as in test-dispatch-gate.sh.
G="$(mktemp -d)"
export TMPDIR="$G"
unset GOVERN_RUN GOVERN_TICKET_ROUTE_GUARD GOVERN_DISPATCH_FRESH_HOURS 2>/dev/null || true
export GOVERN_DISPATCH_GATE=1 GOVERN_PROPOSAL_GATE=0 GOVERN_WORKER_FANOUT_NUDGE=0
FAKE="$G/fakews"; mkdir -p "$G/wt"
mk_ws_stub "$FAKE"
mkdir -p "$FAKE/scripts/govern/lib" "$FAKE/queue"
cp "$GUARD" "$FAKE/scripts/router-posture-guard.sh"
cp "$STEER" "$FAKE/scripts/advisor-steer-guard.sh"
cp "$COMMON" "$FAKE/scripts/govern/lib/common.sh"
for lib in flows pregate landed valjob valpending plan; do [[ -f "$DIR/../lib/$lib.sh" ]] && cp "$DIR/../lib/$lib.sh" "$FAKE/scripts/govern/lib/"; done
cp "$DS" "$FAKE/scripts/govern/dispatch.sh"
cat > "$FAKE/queue/tickets.md" <<'TIX'
# Tickets

## #7 tighten the retry ladder

**Done when:** the ladder stops at three.

**Proposed solution:** cap it at three.

**Precision:** stated
TIX
cat > "$FAKE/scripts/govern/pre-dispatch-check.sh" <<'EOF2'
#!/usr/bin/env bash
echo proceed
EOF2
cat > "$FAKE/scripts/govern/dispatch-packet.sh" <<EOF2
#!/usr/bin/env bash
# \$1 tickets, \$2 --role|--model, \$3 the value: the stub records which and writes that line.
csv="\$1"; flag="\$2"; on="\$3"; primary="\${csv%%,*}"
mkdir -p "$G/wt/t\$primary"
p="$G/wt/t\$primary/.dispatch-packet.md"
case "\$flag" in --role) line="Role: \$on" ;; *) line="Model: \$on" ;; esac
{ printf '<!-- GOVERN:PACKET-CREATED %s -->\n# Dispatch packet for %s\n\nWorktree: x\n%s\n' "\$(date +%s)" "#\$primary" "\$line"; } > "\$p"
echo "\$flag \$on" >> "$FAKE/cuts.log"
echo "\$p"; echo "Resolve #\$primary. Read your packet at \$p first and follow it."
EOF2
chmod +x "$FAKE/scripts/govern/"*.sh
PK7="$G/wt/t7/.dispatch-packet.md"
NOW="$(date +%s)"
spawn() { # <subagent_type> [model] [caller agent_type] -> hook output
  python3 -c '
import json, sys
ti = {"subagent_type": sys.argv[1], "description": "dispatch", "prompt": sys.argv[4]}
if len(sys.argv) > 2 and sys.argv[2]:
    ti["model"] = sys.argv[2]
d = {"tool_name": "Agent", "session_id": "profile-gate", "transcript_path": "/tmp/driver.jsonl", "tool_input": ti}
if len(sys.argv) > 3 and sys.argv[3]:
    d["agent_type"] = sys.argv[3]
print(json.dumps(d))
' "$1" "${2:-}" "${3:-}" "$4" | { local envs=("${@:5}"); env "${envs[@]}" bash "$FAKE/scripts/router-posture-guard.sh"; } 2>/dev/null
}
decision() { jq -r '.hookSpecificOutput.permissionDecision // "allow"' <<<"$1" 2>/dev/null || echo "?"; }
ctx() { jq -r '.hookSpecificOutput.additionalContext // ""' <<<"$1" 2>/dev/null; }
cuts() { [[ -f "$FAKE/cuts.log" ]] && tr '\n' ';' < "$FAKE/cuts.log" || true; }
rm -f "$FAKE/cuts.log"

out="$(spawn worker "" "" "Resolve #7. Do the work." SHIPLOOP_MODEL_PROFILE=testfam)"
assert_eq "$(decision "$out")" "allow" "5. under a profile a worker spawn is allowed"
assert_eq "$(cuts)" "--role worker;" "5. the hook cuts the packet with --role worker"
assert_eq "$(sed -n -E 's/^(Role|Model): (.*)$/\1=\2/p' "$PK7")" "Role=worker" "5. the packet carries Role: worker"
assert_contains "$(ctx "$out")" "(Role: worker)" "5. the extra context names the role"
rm -f "$FAKE/cuts.log" "$PK7"
out="$(spawn worker-retry "" "" "Resolve #7. Do the work." SHIPLOOP_MODEL_PROFILE=testfam)"
assert_eq "$(decision "$out")" "allow" "5. a worker-retry spawn is allowed (it is a worker type)"
assert_eq "$(cuts)" "--role worker-retry;" "5. ...and cuts its packet with --role worker-retry"
assert_eq "$(sed -n -E 's/^(Role|Model): (.*)$/\1=\2/p' "$PK7")" "Role=worker-retry" "5. ...so the retry's packet says worker-retry"
assert_contains "$(ctx "$out")" "(Role: worker-retry)" "5. ...and its context names it"
rm -f "$FAKE/cuts.log" "$PK7"
out="$(spawn worker opus "" "Resolve #7. Do the work." SHIPLOOP_MODEL_PROFILE=testfam)"
assert_eq "$(decision "$out")" "allow" "5. a model the call passed under a profile is not a deny"
assert_eq "$(sed -n -E 's/^(Role|Model): (.*)$/\1=\2/p' "$PK7")" "Role=worker" "5. ...and is not recorded either: the role decides"
# a fresh packet is reused; its line follows the call's type and converts from the other mode
mk_packet() { mkdir -p "$(dirname "$1")"; printf '<!-- GOVERN:PACKET-CREATED %s -->\n# Dispatch packet for #7\n\nWorktree: x\n%s\n' "$3" "$2" > "$1"; }
mk_packet "$PK7" "Role: worker" "$NOW"; rm -f "$FAKE/cuts.log"
out="$(spawn worker-retry "" "" "Resolve #7. Read your packet at $PK7 first and follow it." SHIPLOOP_MODEL_PROFILE=testfam)"
assert_eq "$(cuts)" "" "5. a fresh packet is reused, not re-cut"
assert_eq "$(sed -n -E 's/^(Role|Model): (.*)$/\1=\2/p' "$PK7")" "Role=worker-retry" "5. a fresh packet's Role line follows the retry's type"
mk_packet "$PK7" "Model: sonnet" "$NOW"
spawn worker "" "" "Resolve #7. Read your packet at $PK7 first and follow it." SHIPLOOP_MODEL_PROFILE=testfam >/dev/null
assert_eq "$(sed -n -E 's/^(Role|Model): (.*)$/\1=\2/p' "$PK7")" "Role=worker" "5. a packet cut before the profile was set has its Model line converted to Role"
mk_packet "$PK7" "Role: worker" "$(( NOW - 7 * 3600 ))"
spawn worker "" "" "Resolve #7. Read your packet at $PK7 first and follow it." SHIPLOOP_MODEL_PROFILE=testfam >/dev/null
assert_eq "$(sed -n -E 's/^(Role|Model): (.*)$/\1=\2/p' "$PK7")" "Role=worker" "5. a stale packet is re-cut under the profile"
# with no profile: unchanged, and a packet left over from a profile session converts back
rm -f "$FAKE/cuts.log" "$PK7"
out="$(spawn worker opus "" "Resolve #7. Do the work." SHIPLOOP_MODEL_PROFILE=)"
assert_eq "$(cuts)" "--model opus;" "5. no profile: the hook cuts with --model, as before"
assert_eq "$(sed -n -E 's/^(Role|Model): (.*)$/\1=\2/p' "$PK7")" "Model=opus" "5. ...and the packet carries Model: opus, as before"
assert_contains "$(ctx "$out")" "(Model: opus)" "5. ...as does the context"
mk_packet "$PK7" "Role: worker" "$NOW"
spawn worker "" "" "Resolve #7. Read your packet at $PK7 first and follow it." SHIPLOOP_MODEL_PROFILE= >/dev/null
assert_eq "$(sed -n -E 's/^(Role|Model): (.*)$/\1=\2/p' "$PK7")" "Model=sonnet" "5. a leftover Role line is converted back to a Model line"
out="$(spawn worker "" worker "Resolve #7. Do the work." SHIPLOOP_MODEL_PROFILE=testfam)"
assert_eq "$(decision "$out")" "deny" "5. a worker spawning a worker is still denied under a profile"

# ── 6. the steer guard ────────────────────────────────────────────────────────────────────────
steer_registry=""
steer() { # <subagent_type> -> the session's worker-address registry, one entry per line
  rm -f "$TMPDIR/metarepo-advisor-steer-workers-steerprof"
  python3 -c '
import json, sys
print(json.dumps({"tool_name": "Agent", "session_id": "steerprof", "transcript_path": "/tmp/driver.jsonl",
                  "tool_input": {"subagent_type": sys.argv[1], "name": sys.argv[2], "prompt": "resolve it", "description": "dispatch"}}))
' "$1" "$2" | GOVERN_STEER_CAP=12 bash "$FAKE/scripts/advisor-steer-guard.sh" >/dev/null 2>&1
  cat "$TMPDIR/metarepo-advisor-steer-workers-steerprof" 2>/dev/null
}
assert_eq "$(steer worker-retry worker-7)" "worker-7" "6. a named worker-retry dispatch is recorded like a worker's"
assert_eq "$(steer worker-retry "")" "worker-retry
@unnamed" "6. an unnamed worker-retry is addressable by its type"
assert_eq "$(steer worker "")" "worker
@unnamed" "6. an unnamed worker is still addressable as worker, as before"
assert_eq "$(steer general-purpose "")" "" "6. a non-worker dispatch records nothing (negative control)"

# ── 7. worker-retry.md ────────────────────────────────────────────────────────────────────────
AGENTS=""; for c in "$DIR/../../.claude/agents" "$DIR/../../../.claude/agents"; do [ -f "$c/worker-retry.md" ] && { AGENTS="$c"; break; }; done
if [ -n "$AGENTS" ]; then
  assert_eq "$(diff "$AGENTS/worker.md" "$AGENTS/worker-retry.md" | grep -c '^[<>]')" "4" \
    "7. worker-retry.md differs from worker.md in exactly two lines"
  assert_eq "$(diff "$AGENTS/worker.md" "$AGENTS/worker-retry.md" | grep '^[<>]' | sed -E 's/^..//' | sort | tr '\n' ' ')" \
    "model: opus model: sonnet name: worker name: worker-retry " "7. those lines are the name and the model, nothing else"
  assert_eq "$(sed -n '2p' "$AGENTS/worker-retry.md")" "name: worker-retry" "7. it is named worker-retry"
  assert_eq "$(sed -n '4p' "$AGENTS/worker-retry.md")" "model: opus" "7. with no profile active it pins the retry at opus, the model a retry was dispatched with before profiles"
else
  echo "info - .claude/agents not present in this layout: worker-retry.md identity not checked here"
fi

assert_done
