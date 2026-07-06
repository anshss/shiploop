#!/usr/bin/env bash
# N12 — stub-gh coverage for the two PR-hygiene wrappers that talk to the GitHub API. test-pr-hygiene.sh
# deliberately covers only the PURE sub-helper (govern::_strip_ticket_ref); a regression in the gh-API
# CALL CONSTRUCTION of these wrappers would silently disable a leak-prevention control with green CI.
# We put a fake `gh` on PATH (pattern from test-na-permanent-nudge.sh) that records the PATCH it is
# handed and honors `--jq` on the /files endpoint, so the assertions go RED on endpoint/jq-path drift:
#   govern::scrub_pr_ticket_ref — strips a leaked internal ticket-id from a PUBLIC PR title/body via
#                                 `gh api -X PATCH repos/<slug>/pulls/<pr>` (common.sh).
#   govern::pr_spec_files       — lists leaked .specs/ / .plans/ / dated-design files in a PR diff via
#                                 `gh api repos/<slug>/pulls/<pr>/files --jq '.[].filename'`.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
COMMON="$DIR/../lib/common.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mk_ws_stub "$T"
mkdir -p "$T/bin"

# Source common.sh in this shell so we can call the wrappers directly.
export GOVERN_TICKETS_FILE=/dev/null
source "$COMMON"

# ── fake gh on PATH ──────────────────────────────────────────────────────────
# GET repos/<slug>/pulls/<pr>        → the PR object in $T/pr.json
# GET repos/<slug>/pulls/<pr>/files  → $T/files.json, filtered through the wrapper's own --jq
# any -X PATCH …                     → record endpoint + -f title=/body= fields, succeed
cat > "$T/bin/gh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "\$*" >> "$T/gh.calls"
_ispatch=0; for a in "\$@"; do [[ "\$a" == PATCH ]] && _ispatch=1; done
if [[ "\$_ispatch" == 1 ]]; then
  ep=""; ti=""; bo=""
  while [[ \$# -gt 0 ]]; do
    case "\$1" in
      repos/*) ep="\$1" ;;
      -f) shift; case "\${1:-}" in title=*) ti="\${1#title=}" ;; body=*) bo="\${1#body=}" ;; esac ;;
    esac
    shift
  done
  printf '%s' "\$ep" > "$T/patch.endpoint"
  printf '%s' "\$ti" > "$T/patch.title"
  printf '%s' "\$bo" > "$T/patch.body"
  exit 0
fi
case "\$*" in
  *"/files"*)
    jqf="."
    while [[ \$# -gt 0 ]]; do [[ "\$1" == "--jq" ]] && jqf="\${2:-.}"; shift; done
    jq -r "\$jqf" < "$T/files.json"
    exit 0 ;;
esac
cat "$T/pr.json"
EOF
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH"

# ── govern::scrub_pr_ticket_ref ──────────────────────────────────────────────
# A PR whose title + body leak the internal id #45 → the wrapper must PATCH the exact PR endpoint with
# the scrubbed strings.
cat > "$T/pr.json" <<'EOF'
{"title":"fix #45: harden the widget","body":"Implements the widget. Closes #45 in the runbook."}
EOF
rm -f "$T/patch.endpoint" "$T/patch.title" "$T/patch.body"

govern::scrub_pr_ticket_ref "acme/alpha" 99 45

assert_eq "$([[ -f "$T/patch.endpoint" ]] && echo yes || echo no)" "yes" \
  "scrub issues a PATCH when the PR leaks the internal ticket-id"
assert_eq "$(cat "$T/patch.endpoint" 2>/dev/null)" "repos/acme/alpha/pulls/99" \
  "PATCH targets the exact repos/<slug>/pulls/<pr> endpoint (red on endpoint regression)"
assert_eq "$(cat "$T/patch.title" 2>/dev/null)" "harden the widget" \
  "PATCH title has the leaked #45 stripped (red on .title jq-path regression)"
assert_eq "$(cat "$T/patch.body" 2>/dev/null)" "Implements the widget. Closes in the runbook." \
  "PATCH body has the leaked #45 stripped (red on .body jq-path regression)"

# Idempotent guard: a clean PR (no leaked ref) must NOT trigger a PATCH at all.
cat > "$T/pr.json" <<'EOF'
{"title":"harden the widget","body":"Implements the widget cleanly."}
EOF
rm -f "$T/patch.endpoint"
govern::scrub_pr_ticket_ref "acme/alpha" 99 45
assert_eq "$([[ -f "$T/patch.endpoint" ]] && echo yes || echo no)" "no" \
  "no PATCH when nothing leaked (idempotent no-op)"

# Non-object gh response (error/rate-limit/odd stub) must no-op, never spill a jq error.
printf '[]' > "$T/pr.json"; rm -f "$T/patch.endpoint"
out="$(govern::scrub_pr_ticket_ref "acme/alpha" 99 45 2>&1 || true)"
assert_eq "$([[ -f "$T/patch.endpoint" ]] && echo yes || echo no)" "no" \
  "non-object gh response → no PATCH (defensive jq)"
assert_eq "$(printf '%s' "$out" | grep -c 'cannot index' || true)" "0" \
  "non-object response does not spill a jq indexing error"

# ── govern::pr_spec_files ────────────────────────────────────────────────────
# The PR diff includes leaked spec/plan artifacts alongside legit code — only the leaked ones surface.
cat > "$T/files.json" <<'EOF'
[
  {"filename":".specs/2026-07-06-topic-design.md"},
  {"filename":"src/.plans/rollout.md"},
  {"filename":"2026-07-06-feature-spec.md"},
  {"filename":"src/main.ts"},
  {"filename":"console/pages/index.tsx"}
]
EOF

spec_out="$(govern::pr_spec_files "acme/alpha" 99)"
assert_contains "$spec_out" ".specs/2026-07-06-topic-design.md" "flags a leaked .specs/ file"
assert_contains "$spec_out" "src/.plans/rollout.md" "flags a leaked nested .plans/ file"
assert_contains "$spec_out" "2026-07-06-feature-spec.md" "flags a leaked dated design/spec/plan md"
assert_eq "$(printf '%s\n' "$spec_out" | grep -c 'src/main.ts' || true)" "0" \
  "does NOT flag a normal source file"
assert_eq "$(printf '%s\n' "$spec_out" | grep -c 'index.tsx' || true)" "0" \
  "does NOT flag a normal frontend file"
# Prove the /files call actually went through the wrapper's own --jq (jq-path exercised, not bypassed).
assert_eq "$(grep -c 'pulls/99/files' "$T/gh.calls" || true)" "1" \
  "pr_spec_files queried the exact pulls/<pr>/files endpoint once"

# A clean diff → empty result.
cat > "$T/files.json" <<'EOF'
[{"filename":"src/main.ts"},{"filename":"README.md"}]
EOF
clean_out="$(govern::pr_spec_files "acme/alpha" 99)"
assert_eq "$(printf '%s' "$clean_out" | tr -d '[:space:]')" "" "clean diff → no leaked-file report"

assert_done
