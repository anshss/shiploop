#!/usr/bin/env bash
# Regression for config-check.sh — the cheap no-auth smoke.
#
# Contract:
#   1. every required knob set → exit 0, prints resolved values, all helpers called
#   2. required knob missing (META_NAME empty) → exit 1, PROBLEM listed
#   3. --json → valid JSON with meta_root / repos / helpers / knobs / problems / warnings
#   4. optional lane misconfiguration → warning (not a problem)
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
set +e
TOOL="$(cd "$DIR/.." && pwd)/config-check.sh"

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
mk_ws_stub "$ROOT"
# mk_ws_stub omits knobs the config-check treats as required (META_NAME, ROOT_PM).
# Append them so case 1 exercises the full-pass path.
cat >> "$ROOT/scripts/lib/workspace.sh" <<'EOF'
META_NAME="testmeta"
ROOT_PM="npm"
EOF

# ── 1. every required knob set → exit 0 ────────────────────────────────────
out="$(bash "$TOOL" 2>&1)"; rc=$?
assert_eq "$rc" "0" "1. every knob set → exit 0"
assert_contains "$out" "config-check" "1. banner printed"
assert_contains "$out" "REPOS" "1. REPOS listed"
assert_contains "$out" "wsp_repo_slug" "1. helper wsp_repo_slug called"
assert_contains "$out" "wsp_repo_localdir" "1. helper wsp_repo_localdir called"
assert_contains "$out" "every required knob resolves" "1. clean-summary line"

# ── 2. required knob missing → exit 1 ──────────────────────────────────────
sed -i.bak 's/META_NAME=.*/META_NAME=""/' "$ROOT/scripts/lib/workspace.sh"
rm -f "$ROOT/scripts/lib/workspace.sh.bak"
out="$(bash "$TOOL" 2>&1)"; rc=$?
assert_eq "$rc" "1" "2. missing META_NAME → exit 1"
assert_contains "$out" "META_NAME" "2. calls out the missing knob"
assert_contains "$out" "PROBLEMS" "2. PROBLEMS section printed"

# ── 3. --json → valid JSON with expected keys ──────────────────────────────
# Restore META_NAME first.
sed -i.bak 's/META_NAME=""/META_NAME="testmeta"/' "$ROOT/scripts/lib/workspace.sh"
rm -f "$ROOT/scripts/lib/workspace.sh.bak"
out="$(bash "$TOOL" --json 2>&1)"; rc=$?
assert_eq "$rc" "0" "3. --json → exit 0"
# jq exit codes: 0 valid, non-0 malformed. This is the JSON-validity assertion.
printf '%s' "$out" | jq -e '.meta_name and .repos and .helpers and .knobs' >/dev/null 2>&1 && \
  printf 'ok   - 3. JSON has meta_name / repos / helpers / knobs\n' || \
  { printf 'FAIL - 3. JSON schema mismatch\n%s\n' "$out"; ASSERT_FAILS=$((ASSERT_FAILS+1)); }

# ── 4. GOVERN_EXTERNALIZE_LANE=1 with empty REPO/SUBREPO → warning (not problem)
cat >> "$ROOT/scripts/lib/workspace.sh" <<'EOF'
export GOVERN_EXTERNALIZE_LANE=1
export GOVERN_EXTERNALIZE_REPO=""
export GOVERN_EXTERNALIZE_SUBREPO=""
EOF
out="$(bash "$TOOL" 2>&1)"; rc=$?
assert_eq "$rc" "0" "4. partial lane → exit 0 (warning, not problem)"
assert_contains "$out" "notice" "4. notices section printed"
assert_contains "$out" "lane no-ops" "4. lane no-op notice"

# ── 5. root-remote status line (wrap-in-place "skip remote" surfaces first-class)
# Make the stub root a real git repo with a queue/ so govern::meta_root resolves to it.
( cd "$ROOT" && git init -q && git config user.email t@t && git config user.name t )
mkdir -p "$ROOT/queue" && : > "$ROOT/queue/tickets.md"
out="$(bash "$TOOL" 2>&1)"; rc=$?
assert_eq "$rc" "0" "5. no-remote root → still exit 0 (warning, not a problem)"
assert_contains "$out" "root remote" "5. root remote status line printed"
assert_contains "$out" "DISABLED" "5. no-remote surfaces the CAS/sync DISABLED warning"

# ── 6. once a remote exists, the line flips to show it ──────────────────────
( cd "$ROOT" && git remote add origin https://example.com/acme/meta.git )
out="$(bash "$TOOL" 2>&1)"; rc=$?
assert_eq "$rc" "0" "6. with remote → exit 0"
assert_contains "$out" "origin" "6. root remote line shows the remote"

# ── 7. --json carries root_remote ──────────────────────────────────────────
out="$(bash "$TOOL" --json 2>&1)"
printf '%s' "$out" | jq -e 'has("root_remote")' >/dev/null 2>&1 && \
  printf 'ok   - 7. JSON has root_remote key\n' || \
  { printf 'FAIL - 7. JSON missing root_remote\n%s\n' "$out"; ASSERT_FAILS=$((ASSERT_FAILS+1)); }

# ── 8. GOVERN_MIGRATE_CMD unset + a migration-shaped ticket → dedicated notice ──
# Today the actual gap-detection only happens reactively in resolve-ticket.sh, AFTER a worker already
# built + opened a PR for the migration ticket. This surfaces it proactively, pre-run.
printf '## #9 — needs an ALTER TABLE migration\n\n**Severity:** High\n\nbody\n\n---\n' >> "$ROOT/queue/tickets.md"
out="$(bash "$TOOL" 2>&1)"; rc=$?
assert_eq "$rc" "0" "8. migration-shaped ticket + no migrate cmd → still exit 0 (warning, not a problem)"
assert_contains "$out" "GOVERN_MIGRATE_CMD is unset but tickets.md has a migration-shaped entry" "8. dedicated migration notice printed"
assert_contains "$out" "ALTER TABLE" "8. notice names the actual flagged line, not a generic message"

# ── 9. same backlog, but GOVERN_MIGRATE_CMD IS set → no migration notice ────
out="$(GOVERN_MIGRATE_CMD='echo migrate' bash "$TOOL" 2>&1)"; rc=$?
assert_eq "$rc" "0" "9. migrate cmd configured → exit 0"
if printf '%s' "$out" | grep -q "migration-shaped entry"; then
  echo "FAIL - 9. migration notice wrongly fired with GOVERN_MIGRATE_CMD set"; ASSERT_FAILS=$((ASSERT_FAILS+1))
else
  echo "ok   - 9. no migration notice once GOVERN_MIGRATE_CMD is configured"
fi

# ── 10. the worker model is chosen per dispatch, so config-check asserts nothing about model knobs ──
out="$(GOVERN_WORKER_MODEL=opus GOVERN_WORKER_ESCALATION_MODEL=opus bash "$TOOL" 2>&1)"; rc=$?
assert_eq "$rc" "0" "10. colliding model knobs are not a problem (nothing escalates)"
assert_not_contains "$out" "PROBLEMS" "10. no PROBLEMS section for model knobs"
assert_not_contains "$out" "worker model floor" "10. no floor/ceiling section in the summary"
out="$(GOVERN_WORKER_MODEL=opus GOVERN_WORKER_ESCALATION_MODEL=sonnet bash "$TOOL" --json 2>&1)"; rc=$?
assert_eq "$rc" "0" "10b. floor above ceiling is not a problem either"
assert_eq "$(printf '%s' "$out" | jq -r 'has("model_tiers")')" "false" "10b. --json carries no model_tiers"

# ── 13. the next_ticket_number probe is READ-ONLY: .ticket-seq is byte-identical before/after ──
# Regression: govern::next_ticket_number unconditionally writes the high-water mark
# (`printf '%s\n' "$maxn" > "$seq_file"`), so a health check calling it for real dirtied
# governor/.ticket-seq in the operator's git tree on every run. config-check.sh now calls it with
# GOVERN_SEQ_PEEK=1, which computes and prints the same number WITHOUT the write.
mkdir -p "$ROOT/governor"
printf '50\n' > "$ROOT/governor/.ticket-seq"
seq_before="$(cat "$ROOT/governor/.ticket-seq")"
out="$(bash "$TOOL" 2>&1)"; rc=$?
seq_after="$(cat "$ROOT/governor/.ticket-seq")"
assert_eq "$rc" "0" "13. probe run → exit 0"
assert_eq "$seq_after" "$seq_before" "13. .ticket-seq is BYTE-IDENTICAL after the health-check probe (no silent write)"
assert_contains "$out" "next_ticket_number" "13. the probe still ran and reported a value"

# ── 14. same, via --json: the peek value is still correctly computed (hwm 50 + filemax #9 → 51) ──
out="$(bash "$TOOL" --json 2>&1)"
seq_after2="$(cat "$ROOT/governor/.ticket-seq")"
assert_eq "$seq_after2" "$seq_before" "14. --json probe likewise never writes .ticket-seq"
printf '%s' "$out" | jq -e '.helpers.next_ticket_number == "51"' >/dev/null 2>&1 && \
  printf 'ok   - 14. peeked value reflects max(hwm 50, tickets.md #9) + 1 = 51\n' || \
  { printf 'FAIL - 14. unexpected peeked next_ticket_number\n%s\n' "$out"; ASSERT_FAILS=$((ASSERT_FAILS+1)); }

# ── hub-default knob drift + named-but-missing scripts ─────
# A fake "hub" clone, pointed at via GOVERN_UPSTREAM_HARNESS_DIR — the same
# knob a real operator's local fork clone uses (commands/update.md). Every
# case below also pins CLAUDE_PLUGIN_ROOT="" and HOME="$ROOT" so an ambient
# plugin install / ~/.claude/skills/shiploop on the machine running the suite
# can never leak into the fixture (rule 13's inherited-env failure mode).
HUB="$(mktemp -d)"; trap '{ rm -rf "$ROOT" "$HUB"; }' EXIT
mkdir -p "$HUB/templates/lib"
cat > "$HUB/templates/lib/workspace.sh" <<'EOF'
GOVERN_WORKER_MODEL="${GOVERN_WORKER_MODEL:-sonnet}"
GOVERN_WORKER_ESCALATION_MODEL="${GOVERN_WORKER_ESCALATION_MODEL:-opus}"
EOF

# ── 15. a local knob set differently than the hub default → WARNING, not a problem ──
out="$(CLAUDE_PLUGIN_ROOT= HOME="$ROOT" GOVERN_UPSTREAM_HARNESS_DIR="$HUB" GOVERN_WORKER_MODEL=haiku bash "$TOOL" 2>&1)"; rc=$?
assert_eq "$rc" "0" "15. hub-default knob drift → exit 0 (warning, not a problem)"
assert_contains "$out" "knob 'GOVERN_WORKER_MODEL' diverges from hub default" "15. names the diverging knob"
assert_contains "$out" "local='haiku'" "15. reports the local value"
assert_contains "$out" "hub default='sonnet'" "15. reports the hub's value"

# ── 16. a declared override (GOVERN_CONFIG_DRIFT_ACK) silences the same drift ──
out="$(CLAUDE_PLUGIN_ROOT= HOME="$ROOT" GOVERN_UPSTREAM_HARNESS_DIR="$HUB" GOVERN_WORKER_MODEL=haiku GOVERN_CONFIG_DRIFT_ACK="GOVERN_WORKER_MODEL" bash "$TOOL" 2>&1)"; rc=$?
assert_eq "$rc" "0" "16. acknowledged override → exit 0"
if printf '%s' "$out" | grep -q "diverges from hub default"; then
  echo "FAIL - 16. GOVERN_CONFIG_DRIFT_ACK did not silence the declared knob"; ASSERT_FAILS=$((ASSERT_FAILS+1))
else
  echo "ok   - 16. declared override stops the warning"
fi

# ── 17. hub unresolvable (no plugin root, no upstream dir, no skills symlink) → one advisory line, exit 0 ──
out="$(CLAUDE_PLUGIN_ROOT= HOME="$ROOT" GOVERN_UPSTREAM_HARNESS_DIR=/no/such/hub-dir bash "$TOOL" 2>&1)"; rc=$?
assert_eq "$rc" "0" "17. hub unresolvable → exit 0 (soft, not an error)"
assert_contains "$out" "hub not resolvable" "17. names the gap instead of staying silent"

# ── 18. package.json script naming a script path absent on disk → HARD failure ──
# The pre-dispatch-check.sh live instance: the npm-script entry existed, the file didn't.
cat > "$ROOT/package.json" <<'EOF'
{"scripts": {"ghost": "bash scripts/govern/does-not-exist.sh"}}
EOF
out="$(bash "$TOOL" 2>&1)"; rc=$?
assert_eq "$rc" "1" "18. npm script names a missing file → exit 1"
assert_contains "$out" "package.json script 'ghost'" "18. names the offending script key"
assert_contains "$out" "scripts/govern/does-not-exist.sh" "18. names the missing path"
assert_contains "$out" "PROBLEMS" "18. surfaces as a hard PROBLEM, not a notice"

# ── 19. CLAUDE.md documents `npm run <key>` for a key package.json no longer has → HARD failure ──
# The "npm run govern" live instance: a rule outlived the npm script it named.
cat > "$ROOT/package.json" <<'EOF'
{"scripts": {"dev": "bash scripts/dev.sh"}}
EOF
mkdir -p "$ROOT/scripts" && : > "$ROOT/scripts/dev.sh"
printf 'Run `npm run dev` first, then `npm run retired-command`.\n' > "$ROOT/CLAUDE.md"
out="$(bash "$TOOL" 2>&1)"; rc=$?
assert_eq "$rc" "1" "19. CLAUDE.md names a removed npm script → exit 1"
assert_contains "$out" "CLAUDE.md references 'npm run retired-command'" "19. names the removed script"
if printf '%s' "$out" | grep -q "references 'npm run dev'"; then
  echo "FAIL - 19. a still-live npm script was wrongly flagged"; ASSERT_FAILS=$((ASSERT_FAILS+1))
else
  echo "ok   - 19. a still-live npm script (dev) is not flagged"
fi

# ── 20. the CLAUDE.md scan tolerates the three real shapes CLAUDE.md writes commands in:
# trailing args ("-- <N>"), a markdown table cell, and mid-sentence backticks + punctuation.
# All three name a REAL script (govern:resolve) so none of them should be flagged.
cat > "$ROOT/package.json" <<'EOF'
{"scripts": {"dev": "bash scripts/dev.sh", "govern:resolve": "bash scripts/govern/resolve-ticket.sh"}}
EOF
mkdir -p "$ROOT/scripts/govern" && : > "$ROOT/scripts/govern/resolve-ticket.sh"
cat > "$ROOT/CLAUDE.md" <<'EOF'
1. Run `npm run govern:resolve -- <N>` BEFORE landing.
2. | command | what it does |
   |---|---|
   | `npm run govern:resolve` | lands a ticket |
3. Then commit, via `npm run govern:resolve`, once CI is green.
EOF
out="$(bash "$TOOL" 2>&1)"; rc=$?
assert_eq "$rc" "0" "20. all three real-world CLAUDE.md shapes resolve to a live script → exit 0"
if printf '%s' "$out" | grep -q "references 'npm run govern:resolve'"; then
  echo "FAIL - 20. a live script mentioned with trailing args / in a table / mid-sentence was wrongly flagged"; ASSERT_FAILS=$((ASSERT_FAILS+1))
else
  echo "ok   - 20. trailing-args / table-cell / mid-sentence forms all parsed to the same live key"
fi

# ── 21. same removed-script case as 19, but declared via GOVERN_CLAUDE_SCRIPT_IGNORE → no longer a problem ──
# The escape hatch for "CLAUDE.md deliberately mentions a command this fleet does not install."
printf 'Run `npm run dev` first, then `npm run retired-command`.\n' > "$ROOT/CLAUDE.md"
cat > "$ROOT/package.json" <<'EOF'
{"scripts": {"dev": "bash scripts/dev.sh"}}
EOF
out="$(GOVERN_CLAUDE_SCRIPT_IGNORE="retired-command" bash "$TOOL" 2>&1)"; rc=$?
assert_eq "$rc" "0" "21. declared GOVERN_CLAUDE_SCRIPT_IGNORE → exit 0, no longer hard-fails"
if printf '%s' "$out" | grep -q "references 'npm run retired-command'"; then
  echo "FAIL - 21. GOVERN_CLAUDE_SCRIPT_IGNORE did not silence the declared key"; ASSERT_FAILS=$((ASSERT_FAILS+1))
else
  echo "ok   - 21. declared ignore-list entry silences the named-but-missing check"
fi

# ── 22. GOVERN_CLAUDE_SCRIPT_IGNORE is scoped to the CLAUDE.md prose check only — an actually-WIRED
# package.json script pointing at a missing file still hard-fails regardless (case (a) has no exemption:
# it is never "deliberately not installed", the entry exists and is broken).
cat > "$ROOT/package.json" <<'EOF'
{"scripts": {"dev": "bash scripts/dev.sh", "ghost": "bash scripts/govern/does-not-exist.sh"}}
EOF
printf 'nothing relevant here\n' > "$ROOT/CLAUDE.md"
out="$(GOVERN_CLAUDE_SCRIPT_IGNORE="ghost" bash "$TOOL" 2>&1)"; rc=$?
assert_eq "$rc" "1" "22. GOVERN_CLAUDE_SCRIPT_IGNORE does not exempt a wired-but-missing package.json script"
assert_contains "$out" "package.json script 'ghost'" "22. still hard-fails on the wired-but-missing script"

# ── 23. bare run (GOVERN_RUN_DIR unset) leaves nothing untracked under governor/ ────────────
# The runtime caches a govern script can write outside a governor run (repo-visibility and the
# claude --help capability probes, which fall back to governor/ without a run dir) are listed in
# the hub templates/gitignore governor block, so they never dirty git status for the NEXT
# update's Phase 1 dirty-tree precondition.
cat > "$ROOT/package.json" <<'PJEOF'
{"scripts": {"dev": "bash scripts/dev.sh"}}
PJEOF
git init -q "$ROOT"
# Use the gitignore a fresh workspace actually has: templates/gitignore sits two dirs up when the
# suite runs from the hub checkout, but CI (and the copy-in dev loop) runs it from a scaffolded
# workspace's scripts/govern/test, where the same template content landed in the workspace root.
if [ -f "$DIR/../../gitignore" ]; then
  cp "$DIR/../../gitignore" "$ROOT/.gitignore"
else
  cp "$DIR/../../../.gitignore" "$ROOT/.gitignore"
fi
mkdir -p "$ROOT/governor"
for f in .repo-visibility .claude-edp-support .claude-tools-support; do
  printf 'acme/web public\n' > "$ROOT/governor/$f"
done
# governor/.ticket-seq is the tracked ticket high-water mark (not a runtime cache): commit it the
# way a real workspace has it, so only genuinely untracked runtime files can dirty the status.
if [ -f "$ROOT/governor/.ticket-seq" ]; then
  git -C "$ROOT" add governor/.ticket-seq
  git -C "$ROOT" config user.email t@t
  git -C "$ROOT" config user.name t
  git -C "$ROOT" commit -qm "fixture: ticket-seq"
fi
out="$(env -u GOVERN_RUN_DIR -u GOVERN_VIS_CACHE -u GOVERN_TOOLS_PROBE_CACHE bash "$TOOL" 2>&1)"; rc=$?
assert_eq "$rc" "0" "23. bare run (no GOVERN_RUN_DIR) exits 0"
assert_eq "$(git -C "$ROOT" status --porcelain -- governor/ | wc -l | tr -d ' ')" "0" \
  "23. nothing untracked under governor/ after a bare run"

assert_done
