#!/usr/bin/env bash
# Public-repo PR hygiene: on a PUBLIC target repo no internal ticket id may be visible on the PR —
# the branch is the neutral, deterministic `sl-<12hex>` scheme (govern::neutral_branch) instead of
# `ticket-<N>`. This test covers the new common.sh primitives directly, PLUS the guard's per-repo
# branch-pattern acceptance driven through merge-pr.sh (the real auto-merge entrypoint):
#   1. neutral_branch — deterministic, `^sl-[0-9a-f]{12}$`, distinct per N.
#   2. repo_is_public — GOVERN_PUBLIC_REPOS knob wins; gh auto-detect; unknown ⇒ PRIVATE (fail-safe).
#   3. ticket_branch — neutral on public, ticket-<N> on private.
#   4. find_pr — matches the neutral head.
#   5. GUARD (pr_automerge_allowed via merge-pr.sh): a neutral branch is ALLOWED on a configured-PUBLIC
#      repo, but BLOCKED (bad-branch) on a private repo — proving the private guard is NOT weakened.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
COMMON="$DIR/../lib/common.sh"
MERGE="$DIR/../merge-pr.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not installed (neutral_branch needs git hash-object)"; exit 0; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"          # alpha auto-mergeable, org acme
export GOVERN_TICKETS_FILE=/dev/null
export GOVERN_VIS_CACHE="$T/.vis"   # isolate the visibility cache to this test
source "$COMMON"

# ── 1. neutral_branch ────────────────────────────────────────────────────────
b7="$(govern::neutral_branch 7)"
b7b="$(govern::neutral_branch 7)"
b8="$(govern::neutral_branch 8)"
assert_eq "$b7" "$b7b" "neutral_branch is deterministic (same N ⇒ same branch)"
if [[ "$b7" =~ ^sl-[0-9a-f]{12}$ ]]; then assert_eq ok ok "neutral_branch matches ^sl-[0-9a-f]{12}\$"
else assert_eq "$b7" "sl-<12hex>" "neutral_branch matches ^sl-[0-9a-f]{12}\$"; fi
if [[ "$b7" != "$b8" ]]; then assert_eq ok ok "neutral_branch is distinct across tickets"
else assert_eq "$b7" "!= $b8" "neutral_branch is distinct across tickets"; fi
if grep -qE 'ticket|[0-9]{1,}$' <<<"${b7#sl-}"; then :; fi   # the token carries no visible ticket id
case "$b7" in *ticket*|*"-7"*) assert_eq "leak" "no-leak" "neutral_branch hides the ticket number";; *) assert_eq ok ok "neutral_branch hides the ticket number";; esac

# ── 2. repo_is_public ────────────────────────────────────────────────────────
# (a) knob wins — no gh needed.
rm -f "$T/.vis"
if GOVERN_PUBLIC_REPOS="alpha web" govern::repo_is_public alpha; then assert_eq ok ok "repo_is_public: GOVERN_PUBLIC_REPOS knob marks a repo public (no gh call)"
else assert_eq public private "repo_is_public: GOVERN_PUBLIC_REPOS knob marks a repo public"; fi
if GOVERN_PUBLIC_REPOS="alpha" govern::repo_is_public web; then assert_eq public private "repo_is_public: a repo NOT in the knob is private"
else assert_eq ok ok "repo_is_public: a repo NOT in the knob is private (knob is an allowlist)"; fi

# (b) gh auto-detect: public/private/failure via a stub gh on PATH.
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
if [[ "\$*" == *"repo view"* ]]; then cat "$T/gh-vis" 2>/dev/null || exit 1; exit 0; fi
echo '[]'
EOF
chmod +x "$T/bin/gh"

rm -f "$T/.vis"; printf 'public\n' > "$T/gh-vis"
if PATH="$T/bin:$PATH" govern::repo_is_public alpha; then assert_eq ok ok "repo_is_public: gh visibility=public ⇒ public"
else assert_eq public private "repo_is_public: gh visibility=public ⇒ public"; fi

rm -f "$T/.vis"; printf 'private\n' > "$T/gh-vis"
if PATH="$T/bin:$PATH" govern::repo_is_public alpha; then assert_eq private public "repo_is_public: gh visibility=private ⇒ private"
else assert_eq ok ok "repo_is_public: gh visibility=private ⇒ private"; fi

# (c) FAIL-SAFE: a gh failure (empty output) ⇒ PRIVATE (current behavior), never a blind flip to public.
rm -f "$T/.vis"; : > "$T/gh-vis"
if PATH="$T/bin:$PATH" govern::repo_is_public alpha 2>/dev/null; then assert_eq public-on-error private-on-error "repo_is_public: gh failure ⇒ PRIVATE (fail-safe)"
else assert_eq ok ok "repo_is_public: gh failure ⇒ PRIVATE (fail-safe, current behavior preserved)"; fi

# (d) cache: a second call for the same repo must NOT re-hit gh (once per run per repo).
rm -f "$T/.vis"; printf 'public\n' > "$T/gh-vis"
PATH="$T/bin:$PATH" govern::repo_is_public alpha >/dev/null 2>&1 || true
printf 'private\n' > "$T/gh-vis"   # flip the source; a cached read must still say public
if PATH="$T/bin:$PATH" govern::repo_is_public alpha; then assert_eq ok ok "repo_is_public: result is cached per run (second call ignores flipped gh)"
else assert_eq cached-public re-queried "repo_is_public: result is cached per run"; fi

# ── 3. ticket_branch ─────────────────────────────────────────────────────────
rm -f "$T/.vis"
tb_pub="$(GOVERN_PUBLIC_REPOS="alpha" govern::ticket_branch 42 alpha)"
tb_priv="$(GOVERN_PUBLIC_REPOS="alpha" govern::ticket_branch 42 web)"
assert_eq "$tb_pub" "$(govern::neutral_branch 42)" "ticket_branch: neutral on a public repo"
assert_eq "$tb_priv" "ticket-42" "ticket_branch: classic ticket-<N> on a private repo"

# ── 4. find_pr matches the neutral head ──────────────────────────────────────
nb99="$(govern::neutral_branch 99)"
cat > "$T/bin/gh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
if [[ "\$*" == *"pr list"* ]]; then
  jq -nc --arg nb "$nb99" '[{number:512,url:"http://o/512",headRefName:\$nb}]'
  exit 0
fi
echo '[]'
EOF
chmod +x "$T/bin/gh"
found="$(PATH="$T/bin:$PATH" govern::find_pr 99 || true)"
assert_contains "$found" "512" "find_pr locates a PR whose head is the neutral sl-<hex> branch"

# ── 5. GUARD via merge-pr.sh: neutral allowed on public, blocked on private ───
# Reuse the automerge-guard harness shape: a data-driven gh stub + explicit guard (unset the bypass).
unset _GOVERN_ASSUME_MERGE_ALLOWED
cat > "$T/bin/gh" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *"api user"*) printf 'acme\n'; exit 0;;
  *"api repos/"*"pulls/"*) cat "$T/gh-pr.json"; exit 0;;
  *"repo view"*) cat "$T/gh-vis2" 2>/dev/null || exit 1; exit 0;;
  *"pr merge"*) echo "\$*" >> "$T/merge.log"; echo merged; exit 0;;
  *"pr view"*"headRefName"*) jq -r '.head.ref // ""' "$T/gh-pr.json" 2>/dev/null; exit 0;;
  *) echo '[]'; exit 0;;
esac
EOF
chmod +x "$T/bin/gh"
nbranch="$(govern::neutral_branch 42)"
# PR object: own author (acme), neutral head, own repo (not a fork).
jq -n --arg h "$nbranch" '{user:{login:"acme"},head:{ref:$h,repo:{owner:{login:"acme"}}},base:{repo:{owner:{login:"acme"}}}}' > "$T/gh-pr.json"

run_guard() { # sets rc,out ; env passed as leading VAR=val args
  : > "$T/merge.log"
  set +e
  out="$(unset _GOVERN_OWN_LOGIN; env "$@" PATH="$T/bin:$PATH" GOVERN_WS_ROOT="$T" GOVERN_VIS_CACHE="$T/.vg" GOVERN_SKIP_CI=1 "$MERGE" alpha 42 2>&1)"; rc=$?
  set -e
  rm -f "$T/.vg"
}

# PUBLIC repo (knob) → neutral branch ALLOWED.
run_guard GOVERN_PUBLIC_REPOS=alpha
assert_eq "$rc" "0" "GUARD: neutral sl-<hex> branch is ALLOWED on a configured-PUBLIC repo"
assert_eq "$(wc -l < "$T/merge.log" | tr -d ' ')" "1" "GUARD: the merge WAS invoked for the public-repo neutral PR"

# PRIVATE repo (gh says private, knob unset) → neutral branch BLOCKED (bad-branch). Proves the
# private-repo guard is NOT weakened by the public variant.
printf 'private\n' > "$T/gh-vis2"
run_guard GOVERN_PUBLIC_REPOS=
assert_eq "$rc" "5" "GUARD: neutral branch is BLOCKED on a PRIVATE repo (private guard NOT weakened)"
assert_contains "$out" "bad-branch" "GUARD: private-repo neutral branch reason is bad-branch"
assert_eq "$(wc -l < "$T/merge.log" | tr -d ' ')" "0" "GUARD: no merge attempted for the blocked private-repo neutral PR"

# PUBLIC repo + classic ticket-<N> head still ALLOWED (in-flight PR opened before repo went public).
jq -n '{user:{login:"acme"},head:{ref:"ticket-42",repo:{owner:{login:"acme"}}},base:{repo:{owner:{login:"acme"}}}}' > "$T/gh-pr.json"
run_guard GOVERN_PUBLIC_REPOS=alpha
assert_eq "$rc" "0" "GUARD: classic ticket-<N> head is still ALLOWED on a public repo (transition-safe)"

assert_done
