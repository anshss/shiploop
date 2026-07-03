#!/usr/bin/env bash
# Proves preflight-main.sh self-heals uncommitted governor RUNTIME artifacts (governor/.ticket-seq,
# governor/escalations.md, governor/pending-escalations.json) so a crash between "write the
# artifact" and "commit it" doesn't self-block the next run. Previously the allowlist covered only
# governor/improvements.md, so a dirty .ticket-seq at run-start made preflight exit 2 → the loop
# refused to start.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
PF="$DIR/../preflight-main.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"
REMOTE="$T/remote.git"
LOCAL="$T/local"
git init --bare -q "$REMOTE"

git init -q "$LOCAL"
( cd "$LOCAL"
  git config user.email t@t; git config user.name t
  git remote add origin "$REMOTE"
  mkdir -p governor
  printf 'seed\n' > README.md
  printf '## Open\n\n## Resolved\n' > governor/escalations.md
  printf '10\n' > governor/.ticket-seq
  git add -A && git commit -q -m init
  git push -q origin HEAD:main
  git branch --set-upstream-to=origin/main main >/dev/null 2>&1 || true )

# Second clone to advance origin/main so local goes "behind" (the reconcile branch requires
# behind != 0 to reach the self-heal path).
git clone -q "$REMOTE" "$T/clone"
( cd "$T/clone"
  git config user.email t@t; git config user.name t
  printf 'advance\n' >> README.md
  git add -A && git commit -q -m advance
  git push -q origin HEAD:main )

# Now dirty .ticket-seq + escalations.md in $LOCAL (simulating a crashed run that wrote them
# but never committed). These are exactly the artifacts a crash between bump-and-commit or
# write-and-commit leaves behind. WITHOUT the fix, preflight halts on "UNCOMMITTED changes".
( cd "$LOCAL"
  printf '99\n' > governor/.ticket-seq
  printf '\n### #1 — later escalation\n- **Reason:** x\n' >> governor/escalations.md
  printf '{"pending":[]}\n' > governor/pending-escalations.json )

# Run preflight — should self-heal + reconcile, exit 0.
out="$(bash "$PF" "$LOCAL" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" "0" "preflight exits 0 after self-healing dirty runtime artifacts"
assert_contains "$out" "committed uncommitted governor runtime artifacts" "self-heal message logged"

# Working tree is now clean.
dirty="$(git -C "$LOCAL" status --porcelain | wc -l | tr -d ' ')"
assert_eq "$dirty" "0" "working tree clean after preflight self-heal"

# Local main should equal origin/main after the reconcile.
lh="$(git -C "$LOCAL" rev-parse HEAD)"
rh="$(git -C "$LOCAL" rev-parse origin/main)"
assert_eq "$lh" "$rh" "local main == origin/main after preflight reconcile"

# ── Regression guard: a dirty file OUTSIDE the allowlist must still halt (exit 2).
( cd "$LOCAL"
  printf 'stranger\n' > unexpected.txt )
# roll origin forward again so we're behind and hit the same code path
( cd "$T/clone"
  git pull -q --rebase origin main
  printf 'more\n' >> README.md
  git add -A && git commit -q -m more
  git push -q origin HEAD:main )
out2="$(bash "$PF" "$LOCAL" 2>&1)" && rc2=0 || rc2=$?
assert_eq "$rc2" "2" "preflight STILL halts on a dirty file OUTSIDE the runtime-artifact allowlist"
assert_contains "$out2" "UNCOMMITTED changes" "halt cause named clearly"

assert_done
