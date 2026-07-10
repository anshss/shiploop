#!/usr/bin/env bash
# Verdict stamping (validations Phase 2): govern::flows_stamp_from_report. Covers Status-per-Kind on
# resolve AND gate-park, SHA ancestor-verify + squash-merge substitution, the never-overwrite-fresher
# guard, grouped multi-flow stamping, and the PII-park-not-abort path.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
command -v git >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || { echo "git/jq absent — skip"; exit 77; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"          # wsp_repo_slug backend -> acme/backend (used only for the gh merge-commit sub)
mkdir -p "$T/governor"
export GOVERN_NO_PUSH=1
source "$DIR/../lib/common.sh"

# Meta repo M with a sub-repo `backend` that carries two commits (sha1 ancestor of sha2).
M="$T/meta"; mkdir -p "$M/validation"
git init -q "$M"; git -C "$M" config user.email ci@test; git -C "$M" config user.name ci
mkdir -p "$M/backend"; git init -q "$M/backend"; git -C "$M/backend" config user.email ci@test; git -C "$M/backend" config user.name ci
printf 'v1\n' > "$M/backend/app.txt"; git -C "$M/backend" add -A; git -C "$M/backend" commit -q -m c1
SHA1="$(git -C "$M/backend" rev-parse HEAD)"
printf 'v2\n' >> "$M/backend/app.txt"; git -C "$M/backend" add -A; git -C "$M/backend" commit -q -m c2
SHA2="$(git -C "$M/backend" rev-parse HEAD)"
FLOWS="$M/validation/flows.md"

seed_flows() {
  cat > "$FLOWS" <<EOF
## deploy.correctness
- **Kind:** correctness
- **Surface:** UI → backend
- **Paths:** backend/**
- **Status:** UNTESTED

## opt.effectiveness
- **Kind:** effectiveness
- **Surface:** optimizer A/B
- **Gate:** reduction >=10% · source: analytics:exp/1
- **Paths:** backend/**
- **Status:** UNTESTED
EOF
  git -C "$M" add -A; git -C "$M" commit -q -m "seed flows" >/dev/null 2>&1 || true
}
status_of() { govern::flow_field "$1" Status "$FLOWS"; }

# ── resolve + correctness → PASS, with a reachable SHA pin + PR-URL linkage + promoted summary.
seed_flows
rep_pass="$(jq -nc --arg s "$SHA2" '{status:"resolved",pr:{repo:"backend",number:7,url:"https://github.com/acme/backend/pull/7"},validation:{ranLiveTest:true,evidence:"drove the real UI; PASS table in PR",environment:"prod",validatedShas:{backend:$s}}}')"
govern::flows_stamp_from_report "$rep_pass" resolve "deploy.correctness" "$M"
assert_eq "$(status_of deploy.correctness)" "PASS" "resolve+correctness → PASS"
assert_contains "$(govern::flow_field deploy.correctness Validated "$FLOWS")" "backend@${SHA2:0:7}" "PASS: reachable SHA pinned"
assert_contains "$(govern::flow_field deploy.correctness Validated "$FLOWS")" "PR https://github.com/acme/backend/pull/7" "PASS: PR-URL linkage"
assert_eq "$(govern::flow_field deploy.correctness Env "$FLOWS")" "prod" "PASS: Env recorded"
assert_eq "$([[ -f "$M/validation/evidence/deploy.correctness.md" ]] && echo yes)" "yes" "PASS: evidence summary promoted"

# ── resolve + effectiveness, gatePassed=true → EFFECTIVE with measured; gate absent → MEASURING.
rep_eff="$(jq -nc --arg s "$SHA2" '{status:"resolved",pr:{repo:"backend",number:8,url:"u8"},validation:{ranLiveTest:true,evidence:"A/B ran",environment:"prod",gatePassed:true,measured:"+12%, n=200",validatedShas:{backend:$s}}}')"
govern::flows_stamp_from_report "$rep_eff" resolve "opt.effectiveness" "$M"
assert_eq "$(status_of opt.effectiveness)" "EFFECTIVE" "resolve+effectiveness+gatePassed=true → EFFECTIVE"
assert_contains "$(govern::flow_field opt.effectiveness Validated "$FLOWS")" "measured: +12%, n=200" "EFFECTIVE: measured value recorded"

seed_flows
rep_arm="$(jq -nc --arg s "$SHA2" '{status:"resolved",pr:null,validation:{ranLiveTest:true,evidence:"experiment armed + running",environment:"prod",validatedShas:{backend:$s}}}')"
govern::flows_stamp_from_report "$rep_arm" resolve "opt.effectiveness" "$M"
assert_eq "$(status_of opt.effectiveness)" "MEASURING" "resolve+effectiveness+no-gate → MEASURING (arm)"

# ── gate-park → FAIL (correctness) / INEFFECTIVE (effectiveness).
seed_flows
rep_park="$(jq -nc --arg s "$SHA2" '{status:"parked",pr:{repo:"backend",number:9,url:"u9"},validation:{ranLiveTest:true,evidence:"measured negative",environment:"prod",gatePassed:false,validatedShas:{backend:$s}}}')"
govern::flows_stamp_from_report "$rep_park" gate-park "deploy.correctness" "$M"
assert_eq "$(status_of deploy.correctness)" "FAIL" "gate-park+correctness → FAIL"
govern::flows_stamp_from_report "$rep_park" gate-park "opt.effectiveness" "$M"
assert_eq "$(status_of opt.effectiveness)" "INEFFECTIVE" "gate-park+effectiveness → INEFFECTIVE"

# ── grouped multi-flow: one report stamps N flows in the id-list.
seed_flows
govern::flows_stamp_from_report "$rep_pass" resolve "deploy.correctness opt.effectiveness" "$M"
assert_eq "$(status_of deploy.correctness)" "PASS" "grouped: first flow stamped"
assert_eq "$(status_of opt.effectiveness)" "MEASURING" "grouped: second flow stamped (effectiveness, no gate → MEASURING)"

# ── SHA ancestor-verify + squash-merge substitution: an ORPHAN pin (not an ancestor) is replaced by
# the PR merge-commit (via a gh stub returning SHA2, a real ancestor).
seed_flows
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<EOF
#!/usr/bin/env bash
case "\$*" in *"pulls/"*) printf '%s' "$SHA2";; *) exit 1;; esac
EOF
chmod +x "$T/bin/gh"
ORPHAN="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
rep_orphan="$(jq -nc --arg s "$ORPHAN" '{status:"resolved",pr:{repo:"backend",number:10,url:"u10"},validation:{ranLiveTest:true,evidence:"squash-merged branch",environment:"prod",validatedShas:{backend:$s}}}')"
PATH="$T/bin:$PATH" govern::flows_stamp_from_report "$rep_orphan" resolve "deploy.correctness" "$M"
assert_eq "$(status_of deploy.correctness)" "PASS" "orphan pin: still stamps PASS via substitution"
assert_contains "$(govern::flow_field deploy.correctness Validated "$FLOWS")" "backend@${SHA2:0:7}" "orphan pin substituted with the PR merge-commit"

# ── never-overwrite-fresher: incoming pin is an ANCESTOR of the recorded one → stamp is REJECTED.
seed_flows
govern::flow_set_field deploy.correctness Status PASS "$FLOWS"
govern::flow_set_field deploy.correctness Validated "2026-07-06 · backend@${SHA2:0:7} · PR u" "$FLOWS"
rep_stale="$(jq -nc --arg s "$SHA1" '{status:"resolved",pr:{repo:"backend",number:11,url:"u11"},validation:{ranLiveTest:true,evidence:"older run",environment:"prod",validatedShas:{backend:$s}}}')"
govern::flows_stamp_from_report "$rep_stale" resolve "deploy.correctness" "$M"
assert_contains "$(govern::flow_field deploy.correctness Validated "$FLOWS")" "backend@${SHA2:0:7}" "never-overwrite-fresher: recorded (newer) SHA retained"

# ── PII in the promoted summary → PARK (return 2), flow NOT stamped, no orphaned summary.
seed_flows
rep_pii="$(jq -nc --arg s "$SHA2" '{status:"resolved",pr:null,validation:{ranLiveTest:true,evidence:"leaked user someone@example.com in the run",environment:"prod",validatedShas:{backend:$s}}}')"
if govern::flows_stamp_from_report "$rep_pii" resolve "deploy.correctness" "$M"; then rc=0; else rc=$?; fi
assert_eq "$rc" "2" "PII in summary → return 2 (PARK signal)"
assert_eq "$(status_of deploy.correctness)" "UNTESTED" "PII: flow NOT stamped"
assert_eq "$([[ -f "$M/validation/evidence/deploy.correctness.md" ]] && echo yes || echo no)" "no" "PII: no orphaned summary left"

assert_done
