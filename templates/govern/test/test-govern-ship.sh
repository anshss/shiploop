#!/usr/bin/env bash
# ship.sh: the one command a worker runs to land its changes, from inside its own worktree.
#
#   1. a sub-repo change: staged, committed, pushed, PR opened; the report skeleton names it.
#   2. idempotency: a second run with no new changes reuses the same PR (no duplicate `gh pr create`).
#   3. unnamed-untracked refusal: an untracked file not named via --add aborts BEFORE anything is
#      staged or committed anywhere.
#   4. rootScope: a root-level change commits on the worktree's own HEAD, never pushed, never a PR,
#      and the commit sha is named in the report.
#   5. PR hygiene: a PUBLIC repo's branch is the neutral sl-<hex> scheme and the PR carries no
#      ticket id; a private repo's branch is ticket-<N> and the PR does.
#   6. .dispatch-packet.md is never staged, even when named explicitly via --add, and an untracked
#      packet left un-named never blocks the ship either.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e

SHIP="$DIR/../ship.sh"
[[ -f "$SHIP" ]] || { echo "SKIP: ship.sh not found"; exit 77; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; exit 77; }
command -v jq  >/dev/null 2>&1 || { echo "SKIP: jq unavailable"; exit 77; }

# ── a stateful `gh` stub: pr create/list/repo-view backed by one JSON log file ────────────────────
mk_gh_stub() { # <bindir> <logfile>
  local bindir="$1" log="$2"
  mkdir -p "$bindir"
  : > "$log"; echo '[]' > "$log"
  cat > "$bindir/gh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
LOG="$log"
[[ -s "\$LOG" ]] || echo '[]' > "\$LOG"
case "\$*" in
  *"repo view"*) echo private; exit 0 ;;
  *"pr list"*) cat "\$LOG"; exit 0 ;;
  *"pr create"*)
    title=""; body=""; head=""; repo=""
    args=("\$@")
    for ((i=0; i<\${#args[@]}; i++)); do
      case "\${args[i]}" in
        --title) title="\${args[i+1]}" ;;
        --body) body="\${args[i+1]}" ;;
        --head) head="\${args[i+1]}" ;;
        --repo) repo="\${args[i+1]}" ;;
      esac
    done
    num=\$(( \$(jq 'length' "\$LOG") + 100 ))
    url="https://github.com/\$repo/pull/\$num"
    jq --arg t "\$title" --arg b "\$body" --arg h "\$head" --arg u "\$url" --argjson n "\$num" \\
      '. + [{number:\$n, url:\$u, headRefName:\$h, title:\$t, body:\$b}]' "\$LOG" > "\$LOG.tmp" && mv "\$LOG.tmp" "\$LOG"
    echo "\$url"
    exit 0
    ;;
  *"api user"*) echo acme; exit 0 ;;
  *) echo '[]'; exit 0 ;;
esac
EOF
  chmod +x "$bindir/gh"
}

setup_case() { # -> sets CASE_T, CASE_LOG; alpha is a real repo with a real bare origin
  CASE_T="$(mktemp -d)"
  local t="$CASE_T"
  mk_ws_stub "$t" "alpha"
  export GOVERN_QUEUE_DIR="$t/queue"
  export GOVERN_VIS_CACHE="$t/.vis"
  mkdir -p "$t/queue" "$t/governor"
  CASE_LOG="$t/gh-prs.json"
  mk_gh_stub "$t/bin" "$CASE_LOG"
  export PATH="$t/bin:$PATH"

  cat > "$t/queue/tickets.md" <<'TIX'
# Tickets

## #7 — tighten the alpha retry ladder

**Severity:** Low

Done when: the ladder stops at three.
TIX

  # root (the worktree's own detached-at-main checkout). Sub-repo dirs, the gh stub and test
  # scaffolding are gitignored here the same way a real workspace's .gitignore keeps them out of
  # the meta repo's own status (worktree/new.sh's __SUBREPO_IGNORES__) -- otherwise ship's own
  # untracked-file refusal (case 3 below) would trip on the test's OWN fixtures, not the case
  # under test.
  printf '/alpha/\n/web/\n/origin-alpha.git/\n/origin-meta.git/\n/bin/\n/gh-prs.json\n/.vis\n/governor/\n' > "$t/.gitignore"
  git init -q --bare "$t/origin-meta.git"
  # Detached at main, exactly like worktree/new.sh's real `git worktree add --detach ... main` --
  # a root commit must advance ONLY HEAD, never the main ref itself, or ship's own
  # `origin/main..HEAD` ahead-count (how it finds root commits to report) reads zero forever.
  ( cd "$t" && git init -q && git checkout -q -b main \
      && git config user.email t@t && git config user.name t \
      && git add -A && git commit -qm init \
      && git remote add origin "$t/origin-meta.git" && git push -q origin main \
      && git checkout -q --detach HEAD )

  # alpha: a real bare origin + a real working clone, one tracked file to modify later.
  git init -q --bare "$t/origin-alpha.git"
  mkdir -p "$t/alpha"
  ( cd "$t/alpha" && git init -q && git config user.email t@t && git config user.name t \
      && git remote add origin "$t/origin-alpha.git" \
      && echo "retry = 5" > retry.conf && git add -A && git commit -qm base \
      && git branch -M main && git push -q origin main )
}
# Separate streams, deliberately: the report skeleton on stdout must stay pure JSON for jq, while
# a refusal's reason is govern::die text on stderr. Both capture files live OUTSIDE $CASE_T -- inside
# it, they'd show up as untracked files in the very repo ship.sh is inspecting. Sets $SHIP_OUT /
# $SHIP_ERR as side effects -- MUST be called un-subshelled (`run_ship 7; x="$SHIP_OUT"`, never
# `x="$(run_ship 7)"`): a command-substitution subshell would swallow both assignments silently,
# the same reasoning setup_case's own header comment gives for mk_ws_stub's exports.
run_ship() {
  local outfile errfile
  outfile="$(mktemp)"; errfile="$(mktemp)"
  ( cd "$CASE_T" && bash "$SHIP" "$@" ) >"$outfile" 2>"$errfile"
  SHIP_RC=$?
  SHIP_OUT="$(cat "$outfile" 2>/dev/null)"
  SHIP_ERR="$(cat "$errfile" 2>/dev/null)"
  rm -f "$outfile" "$errfile"
  return "$SHIP_RC"
}

# ══════════════════════════════════════════════════════════════════════════════════════════════
# 1. a sub-repo change ships: commit, push, PR opened, skeleton names it
# ══════════════════════════════════════════════════════════════════════════════════════════════
setup_case
sed -i.bak 's/5/3/' "$CASE_T/alpha/retry.conf" 2>/dev/null || sed -i '' 's/5/3/' "$CASE_T/alpha/retry.conf"
rm -f "$CASE_T/alpha/retry.conf.bak"
run_ship 7; rc1=$SHIP_RC; out1="$SHIP_OUT"
assert_eq "$rc1" "0" "1. ship exits 0 on a clean sub-repo change"
assert_eq "$(jq -r '.pr.repo' <<<"$out1" 2>/dev/null)" "alpha" "1. the report names the repo"
assert_eq "$(jq -r '.prs | length' <<<"$out1" 2>/dev/null)" "1" "1. exactly one PR in .prs"
assert_eq "$(git -C "$CASE_T/alpha" log -1 --format=%s)" "tighten the alpha retry ladder" "1. commit subject is the ticket's own heading"
pushed_branch1="$(jq -r '.[0].headRefName' "$CASE_LOG")"
assert_eq "$pushed_branch1" "ticket-7" "1. a PRIVATE repo pushes to the classic ticket-<N> branch"
assert_contains "$(jq -r '.[0].title' "$CASE_LOG")" "(#7)" "1. a PRIVATE repo's PR title carries the ticket ref"
rm -rf "$CASE_T"

# ══════════════════════════════════════════════════════════════════════════════════════════════
# 2. idempotency: a second run with nothing new reuses the SAME pr, no duplicate gh pr create
# ══════════════════════════════════════════════════════════════════════════════════════════════
setup_case
echo "retry = 3" > "$CASE_T/alpha/retry.conf"
run_ship 7; out2a="$SHIP_OUT"
n_after_first="$(jq 'length' "$CASE_LOG")"
run_ship 7; rc2b=$SHIP_RC; out2b="$SHIP_OUT"
n_after_second="$(jq 'length' "$CASE_LOG")"
assert_eq "$rc2b" "0" "2. a re-run with nothing new still exits 0"
assert_eq "$n_after_second" "$n_after_first" "2. no duplicate PR was opened"
assert_eq "$(jq -r '.pr.number' <<<"$out2a")" "$(jq -r '.pr.number' <<<"$out2b")" "2. the SAME pr number is reported both times"
rm -rf "$CASE_T"

# ══════════════════════════════════════════════════════════════════════════════════════════════
# 3. unnamed-untracked refusal: nothing staged or committed anywhere
# ══════════════════════════════════════════════════════════════════════════════════════════════
setup_case
echo "retry = 3" > "$CASE_T/alpha/retry.conf"
echo "stray" > "$CASE_T/alpha/unnamed-new-file.txt"
head_before="$(git -C "$CASE_T/alpha" rev-parse HEAD)"
run_ship 7; rc3=$SHIP_RC
assert_eq "$([ "$rc3" -ne 0 ] && echo nonzero || echo 0)" "nonzero" "3. an unnamed untracked file refuses (nonzero exit)"
assert_contains "$SHIP_ERR" "unnamed-new-file.txt" "3. the refusal names the offending file"
assert_eq "$(git -C "$CASE_T/alpha" rev-parse HEAD)" "$head_before" "3. no commit was made"
assert_eq "$(git -C "$CASE_T/alpha" diff --cached --name-only)" "" "3. nothing was staged either"
rm -rf "$CASE_T"

# an --add'ed untracked file is accepted, and does NOT trip the refusal
setup_case
echo "retry = 3" > "$CASE_T/alpha/retry.conf"
echo "new" > "$CASE_T/alpha/added.txt"
run_ship --add alpha/added.txt 7; rc3b=$SHIP_RC
assert_eq "$rc3b" "0" "3b. a file named via --add is accepted, not refused"
assert_contains "$(git -C "$CASE_T/alpha" show --stat HEAD)" "added.txt" "3b. the named file is part of the commit"
rm -rf "$CASE_T"

# ══════════════════════════════════════════════════════════════════════════════════════════════
# 4. rootScope: a root-level change commits on the worktree's own HEAD, never pushed, never a PR
# ══════════════════════════════════════════════════════════════════════════════════════════════
setup_case
mkdir -p "$CASE_T/scripts"
echo "root work" > "$CASE_T/scripts/rootwork.txt"
run_ship --add scripts/rootwork.txt 7; rc4=$SHIP_RC; out4="$SHIP_OUT"
assert_eq "$rc4" "0" "4. a root-only change ships cleanly"
assert_eq "$(jq -r '.pr' <<<"$out4")" "null" "4. no PR for a root-only change"
assert_eq "$(jq -r '.prs | length' <<<"$out4")" "0" "4. .prs is empty for a root-only change"
root_worktree_name="$(jq -r '.rootScope.worktree' <<<"$out4")"
assert_eq "$root_worktree_name" "$(basename "$CASE_T")" "4. rootScope.worktree names the worktree"
n_root_commits="$(jq -r '.rootScope.commits | length' <<<"$out4")"
assert_eq "$([ "${n_root_commits:-0}" -gt 0 ] && echo yes || echo no)" "yes" "4. rootScope.commits is non-empty"
sha4="$(jq -r '.rootScope.commits[0]' <<<"$out4")"
assert_eq "$(git -C "$CASE_T" cat-file -t "$sha4" 2>/dev/null)" "commit" "4. the named sha is a real commit on the worktree"
rm -rf "$CASE_T"

# ══════════════════════════════════════════════════════════════════════════════════════════════
# 5. PR hygiene: a PUBLIC repo's branch is the neutral sl-<hex> scheme, no ticket id on the PR
# ══════════════════════════════════════════════════════════════════════════════════════════════
setup_case
export GOVERN_PUBLIC_REPOS="alpha"
echo "retry = 3" > "$CASE_T/alpha/retry.conf"
run_ship 7; rc5=$SHIP_RC
assert_eq "$rc5" "0" "5. a public-repo ship still exits 0"
pushed_branch5="$(jq -r '.[0].headRefName' "$CASE_LOG")"
if [[ "$pushed_branch5" =~ ^sl-[0-9a-f]{12}$ ]]; then assert_eq ok ok "5. a PUBLIC repo pushes the neutral sl-<hex> branch"
else assert_eq "$pushed_branch5" "sl-<12hex>" "5. a PUBLIC repo pushes the neutral sl-<hex> branch"; fi
case "$pushed_branch5" in *ticket*|*-7*) assert_eq leak no-leak "5. the branch hides the ticket number";; *) assert_eq ok ok "5. the branch hides the ticket number";; esac
title5="$(jq -r '.[0].title' "$CASE_LOG")"
case "$title5" in *"#7"*) assert_eq leak no-leak "5. a PUBLIC repo's PR title carries no ticket id";; *) assert_eq ok ok "5. a PUBLIC repo's PR title carries no ticket id";; esac
unset GOVERN_PUBLIC_REPOS
rm -rf "$CASE_T"

# ══════════════════════════════════════════════════════════════════════════════════════════════
# 6. .dispatch-packet.md is never staged, even named explicitly via --add
# ══════════════════════════════════════════════════════════════════════════════════════════════
setup_case
echo "packet content" > "$CASE_T/.dispatch-packet.md"
mkdir -p "$CASE_T/scripts"
echo "root work" > "$CASE_T/scripts/rootwork2.txt"
run_ship --add .dispatch-packet.md 7; rc6=$SHIP_RC
assert_eq "$([ "$rc6" -ne 0 ] && echo refused || echo shipped)" "refused" "6. --add .dispatch-packet.md is refused outright"
assert_eq "$(git -C "$CASE_T" status --porcelain -- .dispatch-packet.md)" "?? .dispatch-packet.md" "6. it is left untracked, never staged"
rm -rf "$CASE_T"

setup_case
echo "packet content" > "$CASE_T/.dispatch-packet.md"
mkdir -p "$CASE_T/scripts"
echo "root work" > "$CASE_T/scripts/rootwork3.txt"
run_ship --add scripts/rootwork3.txt 7; rc6b=$SHIP_RC
assert_eq "$rc6b" "0" "6b. an un-named untracked packet does not block the ship"
assert_eq "$(git -C "$CASE_T" status --porcelain -- .dispatch-packet.md)" "?? .dispatch-packet.md" "6b. the packet is still untracked after the ship"
case "$(git -C "$CASE_T" show --stat --format= HEAD)" in
  *dispatch-packet*) assert_eq staged never-staged "6b. the packet is not in the commit" ;;
  *) assert_eq ok ok "6b. the packet is not in the commit" ;;
esac
rm -rf "$CASE_T"

assert_done
