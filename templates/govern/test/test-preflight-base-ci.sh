#!/usr/bin/env bash
# #49: preflight-base-ci.sh must refuse to dispatch on an UNAMBIGUOUS base-branch CI red, and must
# fail OPEN on everything else (no checks configured, an in-progress run, a gh API error, gh
# missing) — a red baseline fails every worker in a --parallel wave, but this check must never
# block a fleet whose CI is simply absent.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
PF="$DIR/../preflight-base-ci.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mk_ws_stub "$TMP"   # REPOS=(alpha web), GOVERN_MERGE_REPOS=alpha (so GOVERN_FRONTEND_REPOS=web)

# Fake gh: branches on `run list --repo <slug>`, returning $FAKE_ALPHA / $FAKE_WEB per repo so a
# test can red-flag one repo without touching the other.
cat > "$TMP/gh" <<'EOF'
#!/usr/bin/env bash
args="$*"
if [[ "$args" == *"run list"* ]]; then
  case "$args" in
    *"--repo acme/alpha"*) printf '%s' "${FAKE_ALPHA-[]}";;
    *"--repo acme/web"*)   printf '%s' "${FAKE_WEB-[]}";;
    *) printf '[]';;
  esac
  exit 0
fi
exit 0
EOF
chmod +x "$TMP/gh"

run() { PATH="$TMP:$PATH" bash "$PF" 2>&1; }

# ── unambiguous red → blocks (exit 2), names the failing run URL ────────────
out="$(FAKE_ALPHA='[{"conclusion":"failure","status":"completed","url":"https://github.com/acme/alpha/actions/runs/1"}]' run)" && rc=0 || rc=$?
assert_eq "$rc" "2" "completed+failure conclusion on base branch → refuses to dispatch (exit 2)"
assert_contains "$out" "CI-RED" "red-baseline message logged"
assert_contains "$out" "https://github.com/acme/alpha/actions/runs/1" "failing run URL surfaced"

# ── no checks configured (empty run list) → proceeds (fail-open) ───────────
out="$(FAKE_ALPHA='[]' FAKE_WEB='[]' run)" && rc=0 || rc=$?
assert_eq "$rc" "0" "no runs found on either repo → proceeds unchanged"
assert_contains "$out" "no runs found" "no-runs case logged as fail-open"

# ── in-progress run (conclusion null) → proceeds (fail-open, not a red) ────
out="$(FAKE_ALPHA='[{"conclusion":null,"status":"in_progress","url":"https://x"}]' FAKE_WEB='[]' run)" && rc=0 || rc=$?
assert_eq "$rc" "0" "in-progress run (null conclusion) → proceeds unchanged"

# ── gh returns unparseable output (API error) → proceeds (fail-open) ───────
out="$(FAKE_ALPHA='not-json' FAKE_WEB='[]' run)" && rc=0 || rc=$?
assert_eq "$rc" "0" "gh API error (unparseable JSON) → proceeds unchanged, never blocks"
assert_contains "$out" "gh error" "api-error case logged as fail-open"

# ── a red repo is still fail-open when GOVERN_SKIP_BASE_CHECK=1 ────────────
out="$(FAKE_ALPHA='[{"conclusion":"failure","status":"completed","url":"https://x"}]' \
  PATH="$TMP:$PATH" GOVERN_SKIP_BASE_CHECK=1 bash "$PF" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" "0" "GOVERN_SKIP_BASE_CHECK=1 opts out even on a genuinely red base branch"

# ── gh not installed → proceeds (fail-open) ────────────────────────────────
out="$(PATH="/usr/bin:/bin" bash "$PF" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" "0" "gh not on PATH → proceeds unchanged"
assert_contains "$out" "gh not found" "gh-missing case logged as fail-open"

assert_done
