#!/usr/bin/env bash
# A worker report carrying a bare integer `.pr` (e.g. `"pr": 169`) used to silently fall
# through resolve-ticket.sh's "no PR found" branch — and that branch LANDS. It deleted a queue
# block while the real PR sat open, green and mergeable, and the exit status was SUCCESS. The same
# fall-through fires for ANY present-but-unparseable `.pr` (a malformed object, a non-numeric
# string, ...), not just an integer.
#
# Required behavior, all proven at BOTH layers (the unit primitives in common.sh, and the full
# resolve-ticket.sh script against stubbed collaborators):
#   1. `.pr` a bare integer either resolves to a repo and MERGES, or REFUSES non-zero — it must
#      never land with nothing merged.
#   2. `.pr` present but malformed/unresolvable is a hard REFUSAL, before any bookkeeping,
#      tickets.md left byte-identical.
#   3. `.pr` absent (and `.prs[]` empty) still lands exactly as it does today — the legitimate
#      no-PR case must not regress.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

RT="$DIR/../resolve-ticket.sh"
[[ -f "$RT" ]] || { echo "SKIP: resolve-ticket.sh not found"; exit 77; }

# ══════════════════════════════════════════════════════════════════════════════════════════════
# PART A — UNIT: govern::normalize_pr_field / govern::resolve_pr_repo, sourced directly.
# ══════════════════════════════════════════════════════════════════════════════════════════════
TU="$(mktemp -d)"; trap 'rm -rf "$TU" "${T2:-}" "${T3:-}" "${T4:-}"' EXIT
mk_ws_stub "$TU" "alpha,api"   # 2 merge repos + web (frontend) => 3 candidates total, forces the
                               # gh-lookup path in resolve_pr_repo (never the single-repo shortcut)
source "$DIR/../lib/common.sh"
set +e   # common.sh's own `set -euo pipefail` re-armed -e on sourcing above — a bare failing call
         # below (rc 1 = refusal, the very thing under test) would otherwise abort this whole file.

# A1. absent .pr passes through untouched.
out="$(govern::normalize_pr_field '{"status":"resolved"}')"; rc=$?
assert_eq "$rc" "0" "A1. absent .pr: normalize succeeds"
assert_eq "$out" '{"status":"resolved"}' "A1. absent .pr: report passed through byte-identical"

# A2. a well-formed object passes through untouched.
wf='{"pr":{"repo":"alpha","number":9,"url":"u"}}'
out="$(govern::normalize_pr_field "$wf")"; rc=$?
assert_eq "$rc" "0" "A2. well-formed object .pr: normalize succeeds"
assert_eq "$out" "$wf" "A2. well-formed object .pr: passed through byte-identical"

# A3. object missing .number is a refusal (this is the OTHER present-but-unparseable shape the
# same defect class hides — not just the bare integer).
govern::normalize_pr_field '{"pr":{"repo":"alpha"}}' >/dev/null 2>&1
assert_eq "$?" "1" "A3. object .pr missing .number: refuses (rc 1)"

# A4. object missing .repo is a refusal.
govern::normalize_pr_field '{"pr":{"number":9}}' >/dev/null 2>&1
assert_eq "$?" "1" "A4. object .pr missing .repo: refuses (rc 1)"

# A5. a non-numeric string is a refusal.
govern::normalize_pr_field '{"pr":"nope"}' >/dev/null 2>&1
assert_eq "$?" "1" "A5. non-numeric-string .pr: refuses (rc 1)"

# A6. a bool is a refusal.
govern::normalize_pr_field '{"pr":true}' >/dev/null 2>&1
assert_eq "$?" "1" "A6. boolean .pr: refuses (rc 1)"

# A7. a bare integer, resolvable via gh (stubbed), rewrites .pr into the canonical object.
mkdir -p "$TU/bin"
cat > "$TU/bin/gh" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "pr" && "$2" == "view" ]]; then
  num="$3"; repo=""
  shift 3
  while [[ $# -gt 0 ]]; do case "$1" in --repo) repo="$2"; shift 2 ;; *) shift ;; esac; done
  if [[ "$repo" == "acme/alpha" && "$num" == "169" ]]; then
    printf '{"state":"OPEN","url":"https://github.com/acme/alpha/pull/169"}\n'; exit 0
  fi
  exit 1
fi
echo '[]'
STUB
chmod +x "$TU/bin/gh"
out="$(PATH="$TU/bin:$PATH" govern::normalize_pr_field '{"pr":169}')"; rc=$?
assert_eq "$rc" "0" "A7. bare integer .pr, gh resolves it: normalize succeeds"
assert_eq "$(jq -c '.pr' <<<"$out" 2>/dev/null)" '{"repo":"alpha","number":169,"url":"https://github.com/acme/alpha/pull/169"}' \
  "A7. bare integer .pr: rewritten to {repo,number,url}"

# A8. a bare integer no configured repo has open (gh finds nothing anywhere): refuses.
cat > "$TU/bin/gh" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == "pr" && "$2" == "view" ]] && exit 1
echo '[]'
STUB
chmod +x "$TU/bin/gh"
PATH="$TU/bin:$PATH" govern::normalize_pr_field '{"pr":169}' >/dev/null 2>&1
assert_eq "$?" "1" "A8. bare integer .pr, unresolvable everywhere: refuses (rc 1), never silently 'no PR'"

# A9. a bare integer with NO gh on PATH at all, in a single-repo workspace: resolves from
# workspace config alone (the shortcut — no gh call needed, matches this ticket's own workspace).
T2="$(mktemp -d)"
( mkdir -p "$T2/scripts/lib"
  cat > "$T2/scripts/lib/workspace.sh" <<'EOF'
GITHUB_ORG="acme"
REPOS=(shiploop)
GOVERN_MERGE_REPOS="shiploop"
GOVERN_LOCAL_FIRST_REPOS=""
wsp_is_merge_repo() { [[ "$1" == "shiploop" ]]; }
wsp_is_local_first_repo() { return 1; }
wsp_repo_slug() { printf '%s/%s' "$GITHUB_ORG" "$1"; }
wsp_repo_localdir() { printf '%s/%s' "$T2" "$1"; }
EOF
)
# A fresh subshell that re-sources common.sh against T2's single-repo config — the parent shell
# already sourced common.sh against TU's (alpha,api,web) config above, and REPOS/GOVERN_MERGE_REPOS
# are fixed at SOURCE time, not re-read per call, so GOVERN_WS_ROOT must be set before an ISOLATED
# re-source, not passed as a prefix to the already-sourced function.
out="$(export GOVERN_WS_ROOT="$T2" PATH="/usr/bin:/bin"; source "$DIR/../lib/common.sh"; govern::normalize_pr_field '{"pr":169}')"; rc=$?
assert_eq "$rc" "0" "A9. bare integer .pr, single-repo workspace: resolves with no gh needed"
assert_eq "$(jq -c '.pr.repo,.pr.number' <<<"$out" 2>/dev/null | tr '\n' ' ')" '"shiploop" 169 ' \
  "A9. bare integer .pr, single-repo workspace: resolved to the one configured repo"

# ══════════════════════════════════════════════════════════════════════════════════════════════
# PART B — SCRIPT: resolve-ticket.sh end to end, stubbed merge-pr.sh/await-ci.sh/land-resolution.sh
# (same hermetic harness as test-resolve-ticket.sh), proving the three Done-when cases at the
# level that actually matters: does a real run land or not.
# ══════════════════════════════════════════════════════════════════════════════════════════════
T3="$(mktemp -d)"
mk_ws_stub "$T3" "alpha,api"
export GOVERN_QUEUE_DIR="$T3/queue"
mkdir -p "$T3/bin/lib" "$T3/queue"
( cd "$T3" && git init -q && git config user.email t@t && git config user.name t )

cp "$RT" "$T3/bin/resolve-ticket.sh"
cp "$DIR/../lib/common.sh" "$T3/bin/lib/common.sh"
[[ -f "$DIR/../lib/flows.sh" ]] && cp "$DIR/../lib/flows.sh" "$T3/bin/lib/"

LANDED="$T3/landed.log"
cat > "$T3/bin/land-resolution.sh" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
printf 'landed %s\n' "${1:-}" >> "$LANDED_LOG"
exit 0
STUB
cat > "$T3/bin/await-ci.sh" <<'STUB'
#!/usr/bin/env bash
printf 'green\n'; exit 0
STUB
MERGE_ORDER="$T3/merge-order.log"
cat > "$T3/bin/merge-pr.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s#%s\n' "$1" "$2" >> "$MERGE_ORDER_LOG"
exit 0
STUB
chmod +x "$T3/bin"/*.sh
export LANDED_LOG="$LANDED" MERGE_ORDER_LOG="$MERGE_ORDER"

cat > "$T3/queue/tickets.md" <<'TIX'
# Tickets

## #50 — some ticket

**Severity:** Medium

Done when: it is done.

---
TIX
( cd "$T3" && git add -A && git commit -qm init )
TICKETS_SNAPSHOT="$(cat "$T3/queue/tickets.md")"

landed_count() { [[ -f "$LANDED" ]] || { echo 0; return 0; }; tr -cd '\n' < "$LANDED" | wc -c | tr -d ' '; }
tickets_unchanged() { [[ "$(cat "$T3/queue/tickets.md")" == "$TICKETS_SNAPSHOT" ]]; }
run_rt() { # <ticket> <report-json> [path-prefix] ; prints combined stdout+stderr, rc = its own
  ( cd "$T3" && printf '%s' "$2" | PATH="${3:+$3:}$PATH" bash "$T3/bin/resolve-ticket.sh" "$1" 2>&1 )
}

# ── B1. bare integer, gh resolves it to alpha#169 (OPEN) — MERGES, lands exactly once ───────────
: > "$LANDED"; : > "$MERGE_ORDER"
cat > "$T3/bin/gh" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "pr" && "$2" == "view" ]]; then
  num="$3"; repo=""
  shift 3
  while [[ $# -gt 0 ]]; do case "$1" in --repo) repo="$2"; shift 2 ;; *) shift ;; esac; done
  if [[ "$repo" == "acme/alpha" && "$num" == "169" ]]; then
    printf '{"state":"OPEN","url":"https://github.com/acme/alpha/pull/169"}\n'; exit 0
  fi
  exit 1
fi
echo '[]'
STUB
chmod +x "$T3/bin/gh"
out="$(run_rt 50 '{"status":"resolved","pr":169}' "$T3/bin")"; rc=$?
assert_eq "$rc" "0" 'B1. "pr":169 resolved via gh: resolve-ticket exits 0'
assert_contains "$(cat "$MERGE_ORDER")" "alpha#169" 'B1. "pr":169 resolved via gh: merge-pr.sh called with the resolved repo#number'
assert_eq "$(landed_count)" "1" 'B1. "pr":169 resolved via gh: lands exactly once'

# ── B2. bare integer, UNRESOLVABLE (no configured repo has it open) — REFUSES, never lands ──────
: > "$LANDED"; : > "$MERGE_ORDER"
cat > "$T3/bin/gh" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == "pr" && "$2" == "view" ]] && exit 1
echo '[]'
STUB
chmod +x "$T3/bin/gh"
out="$(run_rt 50 '{"status":"resolved","pr":169}' "$T3/bin")"; rc=$?
assert_not_contains "$rc" "0" 'B2. "pr":169 unresolvable: resolve-ticket exits non-zero'
assert_eq "$(landed_count)" "0" 'B2. "pr":169 unresolvable: does NOT land (nothing merged)'
if tickets_unchanged; then assert_eq ok ok "B2. tickets.md left byte-identical"
else assert_eq changed unchanged "B2. tickets.md left byte-identical"; fi

# ── B3. malformed .pr (object missing .number) — REFUSES before any bookkeeping ─────────────────
: > "$LANDED"; : > "$MERGE_ORDER"
out="$(run_rt 50 '{"status":"resolved","pr":{"repo":"alpha"}}')"; rc=$?
assert_not_contains "$rc" "0" "B3. malformed .pr (no .number): resolve-ticket exits non-zero"
assert_eq "$(landed_count)" "0" "B3. malformed .pr (no .number): does NOT land"
if tickets_unchanged; then assert_eq ok ok "B3. malformed .pr: tickets.md left byte-identical"
else assert_eq changed unchanged "B3. malformed .pr: tickets.md left byte-identical"; fi
assert_eq "$(cat "$MERGE_ORDER" 2>/dev/null)" "" "B3. malformed .pr: merge-pr.sh never even reached"

# ── B4. .pr absent, .prs[] empty — the legitimate no-PR case still lands exactly as today ───────
: > "$LANDED"; : > "$MERGE_ORDER"
cat > "$T3/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo '[]'
STUB
chmod +x "$T3/bin/gh"
out="$(run_rt 50 '{"status":"resolved"}' "$T3/bin")"; rc=$?
assert_eq "$rc" "0" "B4. no .pr at all: resolve-ticket exits 0 (unchanged legitimate case)"
assert_eq "$(landed_count)" "1" "B4. no .pr at all: still lands exactly once (no regression)"
assert_contains "$out" "no PR found on the report" "B4. no .pr at all: the (accurate) no-PR message still fires"

assert_done
