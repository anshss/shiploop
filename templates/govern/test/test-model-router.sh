#!/usr/bin/env bash
# The model-router mod (hooks/model-router.js): an agent.spawn hook that hands a shiploop spawn the
# active model profile's model for its role, and passes every other spawn through untouched.
#
# A Node stub loads the hooks module the way Claude Code does (it imports the file and calls the
# exported register), then fires agent.spawn with a stand-in mods API and asserts the model the
# hook handed on. It is a STAND-IN for the engine: the same routing is also proven against Claude
# Code's own test kit by hooks/model-router.test.ts (claude plugin test), which this test runs too
# when the claude CLI is on PATH.
#
#   1. under SHIPLOOP_MODEL_PROFILE=glm each shiploop role gets its profile model;
#   2. the profile model replaces a model the call passed;
#   3. a type the profile holds no role for passes through as the same object;
#   4. no profile, an unreadable profile, a profile name that is not a plain name, and a resumed
#      run each pass through;
#   5. the workspace's copy of the profile is read before the one the plugin ships;
#   6. the shipped profiles are well formed, and the mod and govern::model_profile_get (the govern
#      scripts' reader for the same file) agree on every value in them;
#   7. no Claude model name configures another family.
#
# This is a HUB-CONTEXT test: the mod and the profiles are hub files under hooks/ and
# templates/lib/, not a mechanism a scaffolded workspace installs, so it exits 77 outside a hub
# checkout and is listed in tools/hub-context-tests.txt.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

HUB="$(cd "$DIR/../../.." && pwd)"
MOD="$HUB/hooks/model-router.js"
PROFILES="$HUB/templates/lib/model-profiles"
[ -f "$MOD" ] && [ -d "$PROFILES" ] || { echo "SKIP: not running from a hub checkout ($HUB)"; exit 77; }
command -v node >/dev/null 2>&1 || { echo "SKIP: node required to load the hooks module"; exit 77; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq required"; exit 77; }

# ── 1 to 5: the stub ───────────────────────────────────────────────────────────────────────────
STUB="$(mktemp "$TMPDIR/model-router-stub.XXXXXX.mjs")"
trap 'rm -f "$STUB"' EXIT
cat > "$STUB" <<'EOF'
// argv: 2 = path to the hooks module. Prints one "name<TAB>value" line per case.
import { readFileSync } from 'node:fs'
const src = readFileSync(process.argv[2], 'utf8')
const mod = await import('data:text/javascript,' + encodeURIComponent(src))

const hook = (handlers) => handlers['agent.spawn']
const fire = async (h, env, event, files = {}, cwd = '/ws') => {
  const reads = []
  const next = async (e) => ({ model: e === event ? undefined : e.model, same: e === event })
  const $ = {
    env: { get: async (name) => env[name] },
    session: { cwd: async () => cwd },
    fs: { read: async (path) => { reads.push(path); if (!(path in files)) throw new Error('ENOENT ' + path); return files[path] } },
    plugin: { root: '/plugin' },
  }
  return { ...(await h($, event, next)), reads }
}
const register = () => { const handlers = {}; mod.register((name, m, fn) => { handlers[name] = typeof m === 'function' ? m : fn }); return handlers }

const GLM = ['ROLE_worker="glm-5.3-flash[1m]"', 'ROLE_worker_retry="glm-5.4[1m]"', 'ROLE_investigator="glm-5.3"',
  'ROLE_lookup="glm-5.3-flash[1m]"', 'TIER_ORDER="advisor worker_retry investigator worker lookup"'].join('\n')
const WS = '/ws/scripts/lib/model-profiles/glm.conf'
const PLUGIN = '/plugin/templates/lib/model-profiles/glm.conf'
const spawn = (type, extra = {}) => ({ tool_use_id: 't', prompt: 'Resolve #7.', description: 'd', subagentType: type,
  provider: { plugin: 'engine', tier: 'core' }, parentModel: 'glm-5.4[1m]', background: false, fork: false, ...extra })
const out = (name, v) => console.log(name + '\t' + v)
const model = (r) => (r.same ? 'passthrough' : String(r.model))

const handlers = register()
if (Object.keys(handlers).join(',') !== 'agent.spawn') { out('registered', Object.keys(handlers).join(',')); }
const h = hook(handlers)
out('role.worker', model(await fire(h, { SHIPLOOP_MODEL_PROFILE: 'glm' }, spawn('worker'), { [WS]: GLM })))
out('role.worker-retry', model(await fire(h, { SHIPLOOP_MODEL_PROFILE: 'glm' }, spawn('worker-retry'), { [WS]: GLM })))
out('role.investigator', model(await fire(h, { SHIPLOOP_MODEL_PROFILE: 'glm' }, spawn('investigator'), { [WS]: GLM })))
out('role.lookup', model(await fire(h, { SHIPLOOP_MODEL_PROFILE: 'glm' }, spawn('lookup'), { [WS]: GLM })))
out('call-model-replaced', model(await fire(h, { SHIPLOOP_MODEL_PROFILE: 'glm' }, spawn('worker', { model: 'opus' }), { [WS]: GLM })))
out('unknown.general-purpose', model(await fire(h, { SHIPLOOP_MODEL_PROFILE: 'glm' }, spawn('general-purpose'), { [WS]: GLM })))
out('unknown.Explorer', model(await fire(h, { SHIPLOOP_MODEL_PROFILE: 'glm' }, spawn('Explore'), { [WS]: GLM })))
out('unknown.teammate', model(await fire(h, { SHIPLOOP_MODEL_PROFILE: 'glm' }, spawn('teammate', { isTeammate: true }), { [WS]: GLM })))
out('noprofile.worker', model(await fire(h, {}, spawn('worker'), { [WS]: GLM })))
out('noprofile.empty', model(await fire(h, { SHIPLOOP_MODEL_PROFILE: '' }, spawn('worker'), { [WS]: GLM })))
out('unreadable.worker', model(await fire(h, { SHIPLOOP_MODEL_PROFILE: 'glm' }, spawn('worker'))))
out('unplainname.worker', model(await fire(h, { SHIPLOOP_MODEL_PROFILE: '../../etc/passwd' }, spawn('worker'), { [WS]: GLM })))
out('resumed.worker', model(await fire(h, { SHIPLOOP_MODEL_PROFILE: 'glm' }, spawn('worker', { resume: { agentId: 'a1' } }), { [WS]: GLM })))
out('emptyrole.worker', model(await fire(h, { SHIPLOOP_MODEL_PROFILE: 'glm' }, spawn('worker'), { [WS]: 'ROLE_worker=""' })))
const w = await fire(h, { SHIPLOOP_MODEL_PROFILE: 'glm' }, spawn('worker'), { [WS]: GLM, [PLUGIN]: 'ROLE_worker="from-plugin"' })
out('workspace-copy-first', model(w) + ' reads=' + w.reads.join(','))
const p = await fire(h, { SHIPLOOP_MODEL_PROFILE: 'glm' }, spawn('worker'), { [PLUGIN]: 'ROLE_worker="from-plugin"' })
out('plugin-copy-fallback', model(p) + ' reads=' + p.reads.join(','))
const bare = await fire(h, { SHIPLOOP_MODEL_PROFILE: 'glm' }, spawn('lookup'), { [WS]: '# c\n\nROLE_lookup=glm-5.3-flash[1m]\nROLE_lookup_x = "y"\nnot an assignment\n' })
out('unquoted-value', model(bare))

// 6. the JS reader, for the parity check: argv: 3 = profile path. Prints KEY<TAB>value per line.
const parse = (src.match(/function parseProfile\(text\) \{[\s\S]*?\n\}/) || [''])[0]
const parseProfile = new Function('return (' + parse + ')')()
const profile = parseProfile(readFileSync(process.argv[3], 'utf8'))
for (const [k, v] of Object.entries(profile)) console.log('value\t' + k + '\t' + v)
EOF

# The two locations the stub sees a profile in, mirroring the paths inside its stand-in API.
WS='/ws/scripts/lib/model-profiles/glm.conf'
run_stub() { node "$STUB" "$MOD" "${2:-$PROFILES/glm.conf}" 2>&1; }
got="$(run_stub)"
field() { printf '%s\n' "$got" | awk -F'\t' -v n="$1" '$1 == n { print $2; exit }'; }

assert_eq "$(field registered)" "" "0. the module registers exactly one hook, on agent.spawn"
assert_eq "$(field role.worker)" "glm-5.3-flash[1m]" "1. worker gets the profile's ROLE_worker"
assert_eq "$(field role.worker-retry)" "glm-5.4[1m]" "1. worker-retry gets ROLE_worker_retry (dash read as underscore)"
assert_eq "$(field role.investigator)" "glm-5.3" "1. investigator gets ROLE_investigator"
assert_eq "$(field role.lookup)" "glm-5.3-flash[1m]" "1. lookup gets ROLE_lookup, [1m] suffix intact"
assert_eq "$(field call-model-replaced)" "glm-5.3-flash[1m]" "2. the profile model replaces a model the call passed"
assert_eq "$(field unknown.general-purpose)" "passthrough" "3. general-purpose is not a role: the same event object goes on"
assert_eq "$(field unknown.Explorer)" "passthrough" "3. a built-in type is not a role: passes through"
assert_eq "$(field unknown.teammate)" "passthrough" "3. a teammate spawn is not a role: passes through"
assert_eq "$(field noprofile.worker)" "passthrough" "4. SHIPLOOP_MODEL_PROFILE unset: passes through"
assert_eq "$(field noprofile.empty)" "passthrough" "4. SHIPLOOP_MODEL_PROFILE empty: passes through"
assert_eq "$(field unreadable.worker)" "passthrough" "4. a profile no location holds: passes through"
assert_eq "$(field unplainname.worker)" "passthrough" "4. a profile name with a path separator: passes through"
assert_eq "$(field resumed.worker)" "passthrough" "4. a resumed run: passes through"
assert_eq "$(field emptyrole.worker)" "passthrough" "4. an empty role value: passes through"
assert_eq "$(field workspace-copy-first)" "glm-5.3-flash[1m] reads=$WS" \
  "5. the workspace copy is read and nothing else is"
assert_eq "$(field plugin-copy-fallback)" "from-plugin reads=$WS,/plugin/templates/lib/model-profiles/glm.conf" \
  "5. with no workspace copy the plugin's own templates/lib/model-profiles/ copy is read"
assert_eq "$(field unquoted-value)" "glm-5.3-flash[1m]" "5. an unquoted value parses; comments and non-assignments are skipped"

# ── 6. the shipped profiles ────────────────────────────────────────────────────────────────────
role_keys() { sed -n -E 's/^(ROLE_[A-Za-z0-9_]+)=.*/\1/p' "$1" | sort; }
for pf in "$PROFILES"/*.conf; do
  name="$(basename "$pf" .conf)"
  [ -f "$pf" ] || continue
  assert_contains "$(cat "$pf")" "FAMILY=$name" "6. $name.conf names its own family"
  for key in SESSION_MODEL PICKER TIER_ORDER; do
    assert_eq "$(grep -c "^${key}=" "$pf" | tr -d ' ')" "1" "6. $name.conf defines $key exactly once"
  done
  # Every role on the tier ladder has a model, and every model is ranked: the two lists name the
  # same roles, or a role could be spawned unranked and the "never above your own tier" ceiling
  # could not place it.
  ladder="$(sed -n -E 's/^TIER_ORDER="?([^"]*)"?$/\1/p' "$pf")"
  assert_eq "$(for r in $ladder; do echo "ROLE_$r"; done | sort | tr '\n' ' ')" "$(role_keys "$pf" | tr '\n' ' ')" \
    "6. $name.conf: TIER_ORDER and the ROLE_ keys name the same roles"
  for r in worker worker-retry investigator lookup; do
    assert_eq "$(role_keys "$pf" | grep -c "^ROLE_${r//-/_}\$")" "1" "6. $name.conf defines a model for the $r role"
  done
done
assert_eq "$(sed -n -E 's/^TIER_ORDER="?([^"]*)"?$/\1/p' "$PROFILES/glm.conf")" \
  "$(sed -n -E 's/^TIER_ORDER="?([^"]*)"?$/\1/p' "$PROFILES/claude.conf")" "6. both shipped families rank the same roles"
assert_eq "$(grep -ciE 'claude-(opus|sonnet|haiku|fable)|(^|[^a-z])(opus|sonnet|haiku|fable)([^a-z]|$)' "$PROFILES/glm.conf")" "0" \
  "7. no Claude model name or alias appears in the GLM profile"

# ── 6b. parity: the mod's reader and the govern scripts' reader agree on every value ───────────
# govern::model_profile_get is what dispatch-packet.sh, the model ceiling and the guard read the
# profile with; the mod reads the same file with its own parser. One value read two ways is one
# place the two sides of a dispatch could disagree about which model a role runs on.
mkdir -p "$TMPDIR/ws" && mk_ws_stub "$TMPDIR/ws"
. "$DIR/../lib/common.sh" 2>/dev/null
command -v govern::model_profile_get >/dev/null 2>&1 || { echo "FAIL - govern::model_profile_get is not defined in lib/common.sh"; assert_done; }
pf="$PROFILES/glm.conf"
SHIPLOOP_MODEL_PROFILE=glm GOVERN_MODEL_PROFILE_DIR="$PROFILES" got="$(run_stub x "$pf")"
pf_line="$(printf '%s\n' "$got" | awk -F'\t' '$1 == "value" { print $2 }')"
[ -n "$pf_line" ] || { echo "FAIL - the stub printed no parsed values for $pf"; assert_done; }
n_vals=0; n_bad=0
while IFS=$'\t' read -r _ key jsval; do
  [ -n "${key:-}" ] || continue
  n_vals=$((n_vals + 1))
  bval="$(SHIPLOOP_MODEL_PROFILE=glm GOVERN_MODEL_PROFILE_DIR="$PROFILES" govern::model_profile_get "$key" 2>/dev/null)"
  [ "$jsval" = "$bval" ] || { n_bad=$((n_bad + 1)); echo "       $key: mod=[$jsval] bash=[$bval]"; }
done <<< "$(printf '%s\n' "$got" | awk -F'\t' '$1 == "value"')"
pf="$PROFILES/claude.conf"
got="$(run_stub x "$pf")"
while IFS=$'\t' read -r _ key jsval; do
  [ -n "${key:-}" ] || continue
  n_vals=$((n_vals + 1))
  bval="$(SHIPLOOP_MODEL_PROFILE=claude GOVERN_MODEL_PROFILE_DIR="$PROFILES" govern::model_profile_get "$key" 2>/dev/null)"
  [ "$jsval" = "$bval" ] || { n_bad=$((n_bad + 1)); echo "       $key: mod=[$jsval] bash=[$bval]"; }
done <<< "$(printf '%s\n' "$got" | awk -F'\t' '$1 == "value"')"
assert_eq "$n_vals" "18" "6b. both shipped profiles were read (9 keys each)"
assert_eq "$n_bad" "0" "6b. the mod and govern::model_profile_get agree on every value in both profiles"

# ── the real engine, when the claude CLI is here ──────────────────────────────────────────────
# The kit loads the module through Claude Code's own loader and static analysis, which the stub
# above cannot: a call the loader would refuse (a computed env name, an event name that is not a
# literal) passes the stub and never runs in a session. Optional: CI has no claude CLI.
if command -v claude >/dev/null 2>&1; then
  vout="$(cd "$HUB" && claude plugin validate . 2>&1)"; vrc=$?
  assert_eq "$vrc" "0" "8. claude plugin validate accepts the plugin (CLI present)"
  assert_contains "$vout" "./model-router.js hooks: agent.spawn" "8. the validator sees the agent.spawn hook"
  assert_contains "$vout" "env reads: SHIPLOOP_MODEL_PROFILE" "8. the validator sees the one variable the mod reads"
  tout="$(cd "$HUB" && claude plugin test 2>&1)"; trc=$?
  assert_eq "$trc" "0" "8. claude plugin test passes against Claude Code's own engine"
  assert_contains "$tout" " 0 fail" "8. the kit reports no failing test"
else
  echo "info - claude CLI not on PATH: skipping claude plugin validate/test (hooks/model-router.test.ts)"
fi

assert_done
