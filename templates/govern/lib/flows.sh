#!/usr/bin/env bash
# Flow-registry substrate (validations feature — Phase 1). Sourced by common.sh; DEFINITIONS ONLY —
# every function resolves its govern:: deps at call time, so definition order relative to common.sh
# is irrelevant. See .specs/2026-07-06-shiploop-validations-design.md.
#
# The registry (validation/flows.md) is a git-tracked inventory of user-reachable *flows*, each keyed
# by a STABLE dot-kebab id and pinned to code SHAs, so the system always knows which paths are proven
# at HEAD, which are stale, which failed, and which measured ineffective. This module is the pure
# mechanism: a net-new block parser (flow blocks anchor on `^## <id>`, DISJOINT from the ticket parser
# which anchors `^## #<digits>`), a field read/upsert primitive that preserves unknown fields + HTML
# comments verbatim, a `govern::cas_edit` sync+retry-push helper for standalone registry writes, and
# the lint matrix (glob-resolution, evidence-ref, size, PII scrub). No LLM, no verdict pipeline (that
# is Phase 2), no staleness sweep (Phase 3).

# ── Paths (overridable for tests) ───────────────────────────────────────────
FLOWS_FILE="${GOVERN_FLOWS_FILE:-$WS_ROOT/validation/flows.md}"
FLOWS_EVIDENCE_DIR="${GOVERN_FLOWS_EVIDENCE_DIR:-$WS_ROOT/validation/evidence}"

# A flow id is lowercase, dot-separated kebab segments: coarse→fine (deploy-gpu.vastai). The heading
# anchor is `## <id>`; the ticket parser's `## #<digits>` can never collide (a `#` is not in the id
# charset). Status vocabulary + the "validated" subset (statuses that REQUIRE Validated/Evidence/Env).
GOVERN_FLOW_ID_RE='^[a-z0-9][a-z0-9.-]*$'
GOVERN_FLOW_STATUSES='UNTESTED PASS FAIL STALE MEASURING INEFFECTIVE EFFECTIVE BLOCKED TOMBSTONED'
GOVERN_FLOW_VALIDATED_STATUSES='PASS FAIL STALE MEASURING INEFFECTIVE EFFECTIVE'

# ── Parser ──────────────────────────────────────────────────────────────────
# All flow ids in declaration order. A `## <id>` heading whose remainder is not a valid id (e.g. a
# stray `## #12` ticket-style heading, or a `## Some Prose Header`) is skipped, so the registry file
# may carry a human preamble under normal `##` headings without tripping the parser.
govern::flow_ids() { # [file] -> one id per line
  local f="${1:-$FLOWS_FILE}"
  [[ -f "$f" ]] || return 0
  awk '
    /^## / {
      rest=$0; sub(/^## /,"",rest)
      if (rest ~ /^[a-z0-9][a-z0-9.-]*$/) print rest
    }
  ' "$f"
}

# Print the whole block for flow <id>: its `## <id>` heading through the line before the next `## `
# heading (or EOF). Empty output if the id isn't present.
govern::flow_block() { # id [file]
  local id="$1" f="${2:-$FLOWS_FILE}"
  [[ -f "$f" ]] || return 0
  awk -v id="$id" '
    /^## / {
      cur=$0; sub(/^## /,"",cur)
      if (cur==id) { grab=1; print; next }
      if (grab) { grab=0; exit }
    }
    grab { print }
  ' "$f"
}

# Does the registry carry flow <id>?  rc 0 present, 1 absent.
govern::flow_exists() { # id [file]
  local id="$1" f="${2:-$FLOWS_FILE}"
  govern::flow_ids "$f" | grep -qxF "$id"
}

# Read a single field's value from flow <id>. Tolerant of leading `- `, optional `**bold**`, and any
# leading whitespace. Strips inline HTML comments (`<!-- decoration -->`) and trailing whitespace from
# the value — comments are decoration per the grammar. Empty output if the field is absent.
govern::flow_field() { # id field [file] -> value
  local id="$1" field="$2" f="${3:-$FLOWS_FILE}" line val
  line="$(govern::flow_block "$id" "$f" \
    | grep -m1 -E "^[[:space:]]*-?[[:space:]]*\*{0,2}${field}:\*{0,2}" 2>/dev/null || true)"
  [[ -n "$line" ]] || return 0
  val="$(printf '%s' "$line" | sed -E "s/^[[:space:]]*-?[[:space:]]*\*{0,2}${field}:\*{0,2}[[:space:]]*//")"
  # Strip inline HTML comments (incl. lint:allow markers — they are not part of the value) + trailing ws.
  val="$(printf '%s' "$val" | sed -E 's/<!--[^>]*-->//g; s/[[:space:]]+$//')"
  printf '%s' "$val"
}

# Upsert flow <id>'s <field> to <value>: replace the field line in place if present, else insert a
# canonical `- **field:** value` line right after the block's LAST non-blank line. Every OTHER line —
# unknown fields, HTML comments, ordering, the heading — is preserved verbatim (forward-compat). No-op
# rc 1 if the id isn't present or the file is missing. Rewrites <file> atomically (tmp+mv).
govern::flow_set_field() { # id field value [file]
  local id="$1" field="$2" value="$3" f="${4:-$FLOWS_FILE}" tmp
  [[ -f "$f" ]] || return 1
  govern::flow_exists "$id" "$f" || return 1
  tmp="$(mktemp)"
  awk -v id="$id" -v field="$field" -v value="$value" '
    function emit_block(   i, replaced, lastnb) {
      replaced=0; lastnb=0
      for (i=1;i<=bn;i++) if (buf[i] ~ /[^[:space:]]/) lastnb=i
      for (i=1;i<=bn;i++) {
        if (!replaced && buf[i] ~ ("^[[:space:]]*-?[[:space:]]*\\*{0,2}" field ":")) {
          print "- **" field ":** " value; replaced=1
        } else {
          print buf[i]
          if (i==lastnb && !replaced) { print "- **" field ":** " value; replaced=1 }
        }
      }
      bn=0
    }
    /^## / {
      h=$0; sub(/^## /,"",h)
      if (inblk) { emit_block(); inblk=0 }
      if (h==id) { inblk=1; print; next }
      print; next
    }
    inblk { buf[++bn]=$0; next }
    { print }
    END { if (inblk) emit_block() }
  ' "$f" > "$tmp" && mv "$tmp" "$f" || { rm -f "$tmp" 2>/dev/null; return 1; }
}

# ── Field validation (grammar conformance) ──────────────────────────────────
# Print one "<id>: <problem>" per grammar violation for flow <id>; rc 1 if any, else 0 silent.
# Required always: Kind, Surface, Paths, Status. Gate required when Kind=effectiveness. Blocker
# required when Status=BLOCKED. Validated/Evidence/Env required once the status is a "validated" one.
govern::flow_validate() { # id [file] -> problems on stdout, rc 1 if any
  local id="$1" f="${2:-$FLOWS_FILE}" bad=0 kind status fld
  for fld in Kind Surface Paths Status; do
    [[ -n "$(govern::flow_field "$id" "$fld" "$f")" ]] || { printf '%s: missing required field %s\n' "$id" "$fld"; bad=1; }
  done
  kind="$(govern::flow_field "$id" Kind "$f")"
  status="$(govern::flow_field "$id" Status "$f")"
  if [[ "$kind" == "effectiveness" && -z "$(govern::flow_field "$id" Gate "$f")" ]]; then
    printf '%s: Kind=effectiveness requires a Gate field\n' "$id"; bad=1
  fi
  if [[ "$status" == "BLOCKED" && -z "$(govern::flow_field "$id" Blocker "$f")" ]]; then
    printf '%s: Status=BLOCKED requires a Blocker field\n' "$id"; bad=1
  fi
  case " $GOVERN_FLOW_VALIDATED_STATUSES " in
    *" $status "*)
      for fld in Validated Evidence Env; do
        [[ -n "$(govern::flow_field "$id" "$fld" "$f")" ]] || { printf '%s: Status=%s requires a %s field\n' "$id" "$status" "$fld"; bad=1; }
      done ;;
  esac
  return "$bad"
}

# ── govern::cas_edit — compare-and-swap registry write ──────────────────────
# Factored from govern-bookkeep.sh's step-0 sync + step-4/5 CAS-with-retry push (bookkeep's own
# commit_meta_to_main has NO pre-edit sync). Serializes standalone registry writes with bookkeep by
# taking the SAME bookkeep lock (skipped when the caller already holds it — GOVERN_BOOKKEEP_LOCK_HELD=1
# — since the mkdir mutex is not reentrant), syncs the checkout's main to origin/main, applies the
# caller's <edit-fn> (a shell function name taking the file path; it mutates the file in place), then
# commits ONLY that file and CAS-pushes with rebase-retry so a concurrent driver sharing origin/main
# can't clobber the edit. Guarded + non-fatal: no push outside a git repo / without origin / under
# GOVERN_NO_PUSH=1 (the edit is still applied + committed locally where a repo exists).
govern::cas_edit() { # <file> <edit-fn> [commit-msg] [extra-repo-relpath ...]
  local file="$1" editfn="$2" msg="${3:-chore: update $(basename "$file")}"
  shift 2; [[ $# -ge 1 ]] && shift    # drop the (now-consumed) commit-msg arg if it was supplied
  local extra=("$@")                  # additional repo-relative paths to stage in the SAME commit
  local dir root rel held=0
  local BK_LOCK="${GOVERN_BOOKKEEP_LOCK:-$GOVERNOR_DIR/.bookkeep.lock}"
  command -v "$editfn" >/dev/null 2>&1 || { govern::log "cas_edit: edit-fn '$editfn' not found"; return 1; }
  mkdir -p "$(dirname "$file")" 2>/dev/null || true
  # Serialize with bookkeep unless the caller already holds the lock.
  if [[ "${GOVERN_BOOKKEEP_LOCK_HELD:-0}" != "1" ]]; then
    govern::lock_acquire "$BK_LOCK" 60 300 || govern::log "cas_edit: bookkeep lock busy >60s — proceeding (degraded)"
    held=1
  fi
  dir="$(cd "$(dirname "$file")" 2>/dev/null && pwd || true)"
  root="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || true)"
  # Pre-edit sync onto the freshest origin/main so the edit + CAS-push replay cleanly.
  if [[ -n "$root" && "${GOVERN_NO_PUSH:-0}" != "1" ]] && git -C "$dir" remote get-url origin >/dev/null 2>&1; then
    git -C "$dir" pull --ff-only origin main >/dev/null 2>&1 \
      || git -C "$dir" pull --rebase origin main >/dev/null 2>&1 \
      || { git -C "$dir" rebase --abort >/dev/null 2>&1 || true
           govern::log "cas_edit: pre-edit ff-pull AND rebase-pull failed for $(basename "$file") — reconcile origin/main manually"; }
  fi
  # Apply the caller's mutation.
  "$editfn" "$file" || { [[ "$held" == "1" ]] && govern::lock_release "$BK_LOCK"; return 1; }
  # Commit + CAS-push, pathspec-scoped to this file (+ any extra paths the caller named, e.g. a
  # promoted evidence summary that must land in the same commit as the registry stamp).
  if [[ -n "$root" ]]; then
    rel="${file#"$root/"}"
    ( cd "$root"
      # ${extra[@]+…} guards an EMPTY array under set -u (macOS bash 3.2 errors on a bare "${extra[@]}").
      git add -- "$rel" ${extra[@]+"${extra[@]}"} >/dev/null 2>&1 || true
      if ! git diff --cached --quiet -- "$rel" ${extra[@]+"${extra[@]}"} 2>/dev/null; then
        git commit -q -m "$msg" -- "$rel" ${extra[@]+"${extra[@]}"} >/dev/null 2>&1 || true
        if [[ "${GOVERN_NO_PUSH:-0}" != "1" ]] && git remote get-url origin >/dev/null 2>&1; then
          for _a in 1 2 3 4 5; do
            git push origin HEAD:main >/dev/null 2>&1 && break
            git pull --rebase origin main >/dev/null 2>&1 || { git rebase --abort >/dev/null 2>&1 || true; break; }
          done
        fi
      fi )
  fi
  [[ "$held" == "1" ]] && govern::lock_release "$BK_LOCK"
  return 0
}

# ── Glob resolution (shared by lint + Phase-3 sweep) ────────────────────────
# Resolve a `Paths:` glob to its (repo-dir, in-repo-pathspec) pair, honoring the "first segment = sub-
# repo folder name" rule but degrading gracefully for a single-repo workspace where the glob is meta-
# root-relative. Prints "<repo-dir>\t<pathspec>" or nothing if no git work-tree resolves. The pathspec
# is the literal prefix up to the first wildcard (git pathspec matches a directory prefix), so a
# trailing `/**` or `*` never has to be understood by git ls-files.
govern::flow_glob_resolve() { # glob meta-root -> "repodir\tpathspec"  (empty if no repo resolves)
  local glob="$1" meta="$2" first rest repodir pathspec
  first="${glob%%/*}"
  if [[ "$glob" == */* ]] && git -C "$meta/$first" rev-parse --show-toplevel >/dev/null 2>&1; then
    repodir="$meta/$first"; rest="${glob#*/}"
  elif git -C "$meta" rev-parse --show-toplevel >/dev/null 2>&1; then
    repodir="$meta"; rest="$glob"
  else
    return 0   # neither a sub-repo nor the meta-root is a git work-tree → cannot resolve
  fi
  pathspec="${rest%%\**}"   # everything before the first '*' (git matches a dir prefix)
  printf '%s\t%s' "$repodir" "$pathspec"
}

# Count tracked files a `Paths:` glob resolves to. Prints an integer; prints -1 (cannot compute) when
# no repo resolves (missing/un-cloned sub-repo) so the caller can warn-not-fresh rather than read an
# empty match as "0 → zero-glob".
govern::flow_glob_match_count() { # glob meta-root -> count | -1
  local glob="$1" meta="$2" pair repodir pathspec
  pair="$(govern::flow_glob_resolve "$glob" "$meta")"
  [[ -n "$pair" ]] || { printf '%s' "-1"; return 0; }
  repodir="${pair%%$'\t'*}"; pathspec="${pair#*$'\t'}"
  # wc -l (never exits nonzero, unlike grep -c) so a zero count can't trip set -e in a caller.
  git -C "$repodir" ls-files -- "$pathspec" 2>/dev/null | wc -l | tr -d ' '
}

# ── PII / secret scrub scan ─────────────────────────────────────────────────
# Emit "<file>:<line>: <token>" for each PII/secret-shaped hit NOT covered by a `<!-- lint:allow … -->`
# marker on the SAME line (a flow validating auth legitimately mentions emails). rc 1 if any un-allowed
# hit, else 0. Shared: the Stop-hook lint FAILS on a hit; the Phase-2 promotion path PARKS on the same
# scan (never aborts the governor mid-resolve).
GOVERN_FLOW_PII_RE='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}|sk-[A-Za-z0-9]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{12,}|xox[baprs]-[A-Za-z0-9-]{10,}|-----BEGIN[[:space:]][A-Z ]*PRIVATE KEY-----'
govern::flows_pii_scan() { # file [file...] -> "file:line: token" per un-allowed hit; rc 1 if any
  local hit=0 f m lineno text tok
  for f in "$@"; do
    [[ -f "$f" ]] || continue
    # grep -n on a single file yields "<lineno>:<text>".
    while IFS= read -r m; do
      [[ -n "$m" ]] || continue
      lineno="${m%%:*}"; text="${m#*:}"
      case "$text" in *"lint:allow"*) continue;; esac
      tok="$(printf '%s' "$text" | grep -oE "$GOVERN_FLOW_PII_RE" | head -1)"
      printf '%s:%s: %s\n' "$f" "$lineno" "$tok"
      hit=1
    done < <(grep -nE "$GOVERN_FLOW_PII_RE" "$f" 2>/dev/null || true)
  done
  return "$hit"
}

# ── Lint matrix (called additively from lint-validation-refs.sh) ────────────
# Runs every registry/evidence check from the design's lint matrix against <meta-root>. FAIL rows
# (logs/-ref, dangling evidence ref, zero-match glob) print to stderr and set rc 1; the zero-match-glob
# row ALSO auto-degrades the offending flow's Status to STALE in place (an empty git-log must never read
# as "no changes"). WARN rows (asset size, PII) print to stderr but do NOT fail on their own EXCEPT the
# PII row, which fails (the Stop-hook gate; the promotion path parks instead). Missing registry ⇒ rc 0.
govern::flows_lint() { # [meta-root] -> rc 1 if any FAIL row tripped
  local meta="${1:-$(govern::meta_root 2>/dev/null || echo "$WS_ROOT")}"
  local flows="$meta/validation/flows.md"
  local evdir="$meta/validation/evidence"
  local rc=0 id status glob cnt ev
  [[ -f "$flows" ]] || return 0

  # Row: registry/summary references a logs/ path (single-machine evidence) → FAIL.
  local logs_hits
  logs_hits="$(grep -rInE '(^|[^A-Za-z0-9._/-])logs/[A-Za-z0-9]' "$flows" "$evdir" 2>/dev/null || true)"
  if [[ -n "$logs_hits" ]]; then
    printf 'FLOWS LINT FAIL — validation evidence must not reference a machine-local logs/ path (it is gitignored, invisible to teammates):\n%s\n' "$logs_hits" >&2
    rc=1
  fi

  # Per-flow rows.
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    status="$(govern::flow_field "$id" Status "$flows")"

    # Row: Evidence ref dangles (no file, dead URL shape) → FAIL. Skip statuses that predate validation.
    ev="$(govern::flow_field "$id" Evidence "$flows")"
    if [[ -n "$ev" ]]; then
      if [[ "$ev" == https://* ]]; then
        : # a URL shape is accepted (object-storage opt-in); deep liveness is out of scope for a cheap lint
      elif [[ ! -e "$meta/$ev" ]]; then
        printf 'FLOWS LINT FAIL — flow %s Evidence ref dangles: %s (no such file under %s, and not an https URL)\n' "$id" "$ev" "$meta" >&2
        rc=1
      fi
    fi

    # Row: any Paths glob resolves to 0 tracked files → FAIL + auto-degrade this flow to STALE.
    # read -a splits on whitespace WITHOUT pathname-expanding the globs (a bare `for g in $(...)`
    # would let the shell expand `src/**` against the CWD).
    local -a _globs; read -r -a _globs <<< "$(govern::flow_field "$id" Paths "$flows")"
    for glob in ${_globs[@]+"${_globs[@]}"}; do   # ${…+…} guards an empty array under set -u (bash 3.2)
      cnt="$(govern::flow_glob_match_count "$glob" "$meta")"
      if [[ "$cnt" == "-1" ]]; then
        printf 'FLOWS LINT WARN — flow %s glob %s: sub-repo not present/cloned — cannot compute freshness (left as-is, not treated fresh)\n' "$id" "$glob" >&2
      elif [[ "$cnt" == "0" ]]; then
        printf 'FLOWS LINT FAIL — flow %s glob %s resolves to 0 tracked files — auto-degrading Status→STALE (an empty git-log must never read as "no changes")\n' "$id" "$glob" >&2
        govern::flow_set_field "$id" Status STALE "$flows" || true
        status="STALE"
        rc=1
      fi
    done
  done < <(govern::flow_ids "$flows")

  # Row: asset size warnings (per-file > 300 KB, per-flow asset dir > 2 MB).
  if [[ -d "$evdir/assets" ]]; then
    local d fsz dsz af
    while IFS= read -r af; do
      [[ -f "$af" ]] || continue
      fsz="$(wc -c < "$af" 2>/dev/null | tr -d ' ')"
      [[ "${fsz:-0}" -gt 307200 ]] && printf 'FLOWS LINT WARN — asset %s is %s bytes (>300 KB) — trim into the tier-2 summary or link object storage\n' "${af#"$meta/"}" "$fsz" >&2
    done < <(find "$evdir/assets" -type f 2>/dev/null)
    for d in "$evdir"/assets/*/; do
      [[ -d "$d" ]] || continue
      dsz="$(find "$d" -type f -exec wc -c {} + 2>/dev/null | awk 'END{print s} {s+=$1}')"
      [[ "${dsz:-0}" -gt 2097152 ]] && printf 'FLOWS LINT WARN — asset dir %s is %s bytes (>2 MB) — curate down to the money-shot(s)\n' "${d#"$meta/"}" "$dsz" >&2
    done
  fi

  # Row: PII/secret scrub — FAIL on an un-allowed hit in the registry or any tier-2/3 evidence file.
  local pii
  pii="$(govern::flows_pii_scan "$flows" $([[ -d "$evdir" ]] && find "$evdir" -type f -name '*.md' 2>/dev/null) 2>/dev/null || true)"
  if [[ -n "$pii" ]]; then
    printf 'FLOWS LINT FAIL — PII/secret shape in tracked validation evidence (add `<!-- lint:allow <pattern> -->` on the line if legitimate):\n%s\n' "$pii" >&2
    rc=1
  fi

  return "$rc"
}

# ── Phase 2: verdict stamping ───────────────────────────────────────────────
# Resolve a validated-at SHA to one REACHABLE from origin/main: the pin itself if it is already an
# ancestor; else the PR's merge-commit (a squash-merge orphans the branch sha — same tree, durable on
# main); else empty (unreachable — the caller drops the pin with a warning; never stamp an unreachable
# SHA, or `git log <sha>..` errors / false-STALEs everything). Ancestor target is origin/main when it
# resolves, else HEAD (hermetic/local checkouts with no remote).
govern::flow_reachable_sha() { # repodir sha [slug] [pr] -> reachable sha | ""
  local repodir="$1" sha="$2" slug="${3:-}" pr="${4:-}" target mc
  [[ -n "$sha" && -d "$repodir" ]] || return 0
  target="origin/main"; git -C "$repodir" rev-parse --verify -q "$target" >/dev/null 2>&1 || target="HEAD"
  if git -C "$repodir" merge-base --is-ancestor "$sha" "$target" 2>/dev/null; then printf '%s' "$sha"; return 0; fi
  if [[ -n "$slug" && -n "$pr" ]] && command -v gh >/dev/null 2>&1; then
    mc="$(gh api "repos/$slug/pulls/$pr" --jq '.merge_commit_sha // empty' 2>/dev/null || true)"
    if [[ -n "$mc" ]] && git -C "$repodir" merge-base --is-ancestor "$mc" "$target" 2>/dev/null; then printf '%s' "$mc"; return 0; fi
  fi
  return 0
}

# Extract the recorded sha for <repo> from a flow's existing Validated field (format:
# `<date> · repoA@shaA repoB@shaB · PR …`). Empty if none. Feeds the never-overwrite-fresher guard.
govern::flow_recorded_sha() { # id repo [file] -> sha | ""
  local id="$1" repo="$2" f="${3:-$FLOWS_FILE}" v
  v="$(govern::flow_field "$id" Validated "$f")"
  # `|| true` — no recorded pin (UNTESTED flow / grep no-match) is normal, not an error to abort a
  # set -e caller (bookkeep/run-loop) on.
  printf '%s' "$v" | grep -oE "(^|[^A-Za-z0-9._-])${repo}@[0-9a-f]+" 2>/dev/null | head -1 | sed -E "s/.*${repo}@//" || true
}

# Stamp the registry from a worker report. Deterministic — the model ran the validation; bash records
# it. Args: <report-json> <outcome: resolve|gate-park> <flow-ids space/comma list> [meta-root].
# Per flow id: Status per Kind × outcome (correctness resolve→PASS, park→FAIL; effectiveness
# resolve→EFFECTIVE if gatePassed==true else MEASURING, park→INEFFECTIVE); Validated = date · reachable
# repo@sha pins · PR url (+ measured for effectiveness); Env; Evidence → validation/evidence/<id>.md.
# Guards: never-overwrite-fresher (skip a stamp whose incoming pin is an ANCESTOR of the recorded one);
# ancestor-verify + squash-merge substitution on every pin. Writes through cas_edit under the bookkeep
# lock (honors GOVERN_BOOKKEEP_LOCK_HELD=1), committing the promoted evidence summary in the SAME commit.
# Returns 0; a PII hit in a promoted summary returns 2 (the caller PARKs, per "never abort mid-resolve").
govern::flows_stamp_from_report() { # report outcome flowids [meta-root]
  local report="$1" outcome="$2" idlist="$3" meta="${4:-$(govern::meta_root 2>/dev/null || echo "$WS_ROOT")}"
  local flows="$meta/validation/flows.md" evdir="$meta/validation/evidence"
  local id kind newstatus env measured pr_url pii_park=0
  [[ -f "$flows" ]] || { govern::log "flows_stamp: no registry at $flows — nothing to stamp"; return 0; }
  idlist="${idlist//,/ }"
  env="$(printf '%s' "$report" | jq -r '.validation.environment // .validation.env // "local"' 2>/dev/null || echo local)"
  measured="$(printf '%s' "$report" | jq -r '.validation.measured // ""' 2>/dev/null || true)"
  pr_url="$(printf '%s' "$report" | jq -r '([ .pr ] + (.prs // [])) | map(select(.!=null and ((.url//"")!=""))) | (.[0].url // "")' 2>/dev/null || true)"

  for id in $idlist; do
    [[ -n "$id" ]] || continue
    if ! govern::flow_exists "$id" "$flows"; then
      govern::log "flows_stamp: flow '$id' not in registry — skipping (re-extract to register it)"; continue
    fi
    kind="$(govern::flow_field "$id" Kind "$flows")"
    local gatepass; gatepass="$(printf '%s' "$report" | jq -r 'if .validation.gatePassed==true then "true" elif .validation.gatePassed==false then "false" else "unknown" end' 2>/dev/null || echo unknown)"
    case "$outcome:$kind" in
      resolve:effectiveness)   [[ "$gatepass" == "true" ]] && newstatus="EFFECTIVE" || newstatus="MEASURING" ;;
      resolve:*)               newstatus="PASS" ;;
      gate-park:effectiveness) newstatus="INEFFECTIVE" ;;
      gate-park:*)             newstatus="FAIL" ;;
      *) govern::log "flows_stamp: unknown outcome '$outcome' for $id — skipping"; continue ;;
    esac

    # Reachable SHA-pin list (never-overwrite-fresher guard + squash-merge substitution).
    local pins="" stale_reject=0 repo sha reach slug pr recorded
    while IFS=$'\t' read -r repo sha; do
      [[ -n "$repo" && -n "$sha" ]] || continue
      slug="$(govern::repo_slug "$repo" 2>/dev/null || true)"
      pr="$(printf '%s' "$report" | jq -r --arg r "$repo" '([ .pr ] + (.prs // [])) | map(select((.repo//"")==$r)) | (.[0].number // empty | tostring)' 2>/dev/null || true)"
      recorded="$(govern::flow_recorded_sha "$id" "$repo" "$flows")"
      if [[ -n "$recorded" && "$recorded" != "$sha" ]] && git -C "$meta/$repo" merge-base --is-ancestor "$sha" "$recorded" 2>/dev/null; then
        govern::log "flows_stamp: refusing to stamp $id — incoming $repo@$sha is an ANCESTOR of recorded $repo@$recorded (never overwrite fresher with staler)"
        stale_reject=1; break
      fi
      reach="$(govern::flow_reachable_sha "$meta/$repo" "$sha" "$slug" "$pr")"
      if [[ -z "$reach" ]]; then
        govern::log "flows_stamp: $id — $repo@$sha not reachable from origin/main (orphaned, no substitute) — dropping this pin (never stamp an unreachable SHA)"
        continue
      fi
      pins="${pins:+$pins }${repo}@${reach:0:7}"
    done < <(printf '%s' "$report" | jq -r '(.validation.validatedShas // {}) | to_entries[] | "\(.key)\t\(.value)"' 2>/dev/null || true)
    [[ "$stale_reject" == "1" ]] && continue

    # Promote a durable evidence summary (supersede-in-place). PII → PARK signal, do not stamp this id.
    mkdir -p "$evdir"
    local summary="$evdir/$id.md" evidence
    evidence="$(printf '%s' "$report" | jq -r '.validation.evidence // ""' 2>/dev/null || true)"
    {
      printf '# Flow %s — %s\n\n' "$id" "$newstatus"
      printf -- '- **Status:** %s\n- **Env:** %s\n' "$newstatus" "$env"
      [[ -n "$pins" ]]    && printf -- '- **Validated SHAs:** %s\n' "$pins"
      [[ -n "$measured" ]] && printf -- '- **Measured:** %s\n' "$measured"
      [[ -n "$pr_url" ]]  && printf -- '- **PR:** %s\n' "$pr_url"
      printf '\n> Auto-promoted by the governor on %s. Supersede-in-place; git history keeps priors.\n\n' "$outcome"
      printf '## Verdict / evidence\n\n%s\n' "${evidence:-(no evidence string in report)}"
    } > "$summary"
    if ! govern::flows_pii_scan "$summary" >/dev/null 2>&1; then
      govern::log "flows_stamp: PII/secret shape in promoted summary for $id — PARKING (add a <!-- lint:allow --> marker or scrub); registry NOT stamped for $id"
      rm -f "$summary" 2>/dev/null || true
      pii_park=1; continue
    fi

    # Upsert Status/Validated/Env/Evidence via cas_edit (registry + summary in ONE commit).
    local validated_val
    validated_val="$(date +%F)${pins:+ · $pins}${pr_url:+ · PR $pr_url}"
    [[ "$kind" == "effectiveness" && -n "$measured" ]] && validated_val="$validated_val (measured: $measured)"
    local _sid="$id" _sstatus="$newstatus" _senv="$env" _sval="$validated_val"
    _flows_stamp_edit() { # <flows-file>
      govern::flow_set_field "$_sid" Status    "$_sstatus"                      "$1"
      govern::flow_set_field "$_sid" Validated "$_sval"                         "$1"
      govern::flow_set_field "$_sid" Env       "$_senv"                         "$1"
      govern::flow_set_field "$_sid" Evidence  "validation/evidence/$_sid.md"   "$1"
    }
    govern::cas_edit "$flows" _flows_stamp_edit "docs(flows): stamp $id → $newstatus" "validation/evidence/$id.md"
    unset -f _flows_stamp_edit
    govern::log "flows_stamp: $id → $newstatus (env=$env${pins:+, $pins})"
  done
  [[ "$pii_park" == "1" ]] && return 2
  return 0
}

# Read a ticket's `Flow:` field (space/comma-separated flow ids) from its leading field block —
# ANCHORED like spawn-worker's Model latch (contiguous field lines between the `## #N` heading and the
# first blank line), so a `Flow:` mention later in prose can't be parsed as the field. Empty if none.
govern::ticket_flow_ids() { # N [tickets-file] -> "id id …"
  local n="$1" f="${2:-$TICKETS_FILE}" raw
  raw="$(govern::ticket_block "$n" "$f" \
    | awk 'NR==1{next} !started && NF==0 {next} NF==0 {exit} {started=1; print}' \
    | sed -n -E 's/^[[:space:]]*\*{0,2}[Ff]low:\*{0,2}[[:space:]]*//p' | head -1)"
  printf '%s' "${raw//,/ }"
}
