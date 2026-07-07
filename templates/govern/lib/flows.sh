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

# ── Phase 3: staleness sweep ────────────────────────────────────────────────
# "Validated" is only meaningful relative to code state: a flow is STALE the moment any mapped path
# moves past the SHA it was validated at. Only these SETTLED, SHA-pinned verdicts can go stale — a
# positive (PASS/EFFECTIVE) or a negative (FAIL/INEFFECTIVE); a negative must ALSO stale so a kill
# disposition never acts on a stale negative (design). UNTESTED/BLOCKED/MEASURING/STALE/TOMBSTONED are
# excluded: they carry no settled at-a-SHA claim to invalidate.
GOVERN_FLOW_STALEABLE_STATUSES='PASS FAIL INEFFECTIVE EFFECTIVE'

# The prefix of a `Paths:` glob up to its first wildcard, with any trailing slash trimmed — the
# directory a git pathspec would match. `mjolnir/providers/vastai/**` → `mjolnir/providers/vastai`;
# `backend/**` → `backend`; `console/app/x.ts` → `console/app/x.ts`. Shared by the sweep + the
# spawn-worker path-match heads-up.
govern::flow_glob_prefix() { # glob -> dir-prefix
  local g="$1"; g="${g%%\**}"; printf '%s' "${g%/}"
}

# Sweep the registry IN PLACE against origin/main: degrade every staleable flow whose mapped paths
# changed past its validated SHA to STALE, and auto-withdraw a pending kill Disposition on a flow that
# newly went STALE (a stale negative must not be acted on). PURE local mutation + git-log reads — NO
# commit, NO push, NO network unless GOVERN_FLOWS_SWEEP_FETCH=1 (then each mapped repo is fetched first;
# default off so a per-session Stop-hook sweep stays cheap and rides the refs the session already has).
# GOVERN_FLOWS_SWEEP_DRY=1 → compute only, mutate NOTHING (the report-only path). Appends each newly-
# stale id to the global GOVERN_FLOWS_SWEEP_STALED (space-separated) so a cas_edit wrapper — whose
# edit-fn runs in the caller's shell — can report them after the write. Freshness is MONOTONIC: a
# change in ANY present mapped repo stales the flow even if another mapped repo is missing; only when NO
# present repo shows a change AND some repo is missing/unpinned is the verdict "cannot compute → left
# as-is + warning" (never silently fresh). meta = GOVERN_FLOWS_SWEEP_META or two dirs above the file.
govern::flows_sweep_file() { # <flows-file>
  local flows="$1"
  [[ -f "$flows" ]] || return 0
  local meta="${GOVERN_FLOWS_SWEEP_META:-}"
  if [[ -z "$meta" ]]; then meta="$(cd "$(dirname "$flows")/.." 2>/dev/null && pwd || true)"; fi
  local dry="${GOVERN_FLOWS_SWEEP_DRY:-0}" fetch="${GOVERN_FLOWS_SWEEP_FETCH:-0}"
  local id status disp
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    status="$(govern::flow_field "$id" Status "$flows")"
    case " $GOVERN_FLOW_STALEABLE_STATUSES " in *" $status "*) ;; *) continue;; esac

    local -a _globs; read -r -a _globs <<< "$(govern::flow_field "$id" Paths "$flows")"
    local staled=0 uncomputable=0 glob pair repodir pathspec repokey sha target changed
    for glob in ${_globs[@]+"${_globs[@]}"}; do
      pair="$(govern::flow_glob_resolve "$glob" "$meta")"
      if [[ -z "$pair" ]]; then
        govern::log "flows_sweep: $id glob $glob — sub-repo not present/cloned; cannot compute freshness for it"
        uncomputable=1; continue
      fi
      repodir="${pair%%$'\t'*}"; pathspec="${pair#*$'\t'}"
      [[ -n "$pathspec" ]] || pathspec="."   # `repo/**` → empty prefix → whole repo
      repokey="$(basename "$repodir")"
      sha="$(govern::flow_recorded_sha "$id" "$repokey" "$flows")"
      if [[ -z "$sha" ]]; then uncomputable=1; continue; fi   # no pin for this repo → can't compute its slice
      [[ "$fetch" == "1" ]] && git -C "$repodir" fetch --quiet origin main >/dev/null 2>&1 || true
      target="origin/main"; git -C "$repodir" rev-parse --verify -q "$target" >/dev/null 2>&1 || target="HEAD"
      if ! git -C "$repodir" rev-parse --verify -q "${sha}^{commit}" >/dev/null 2>&1; then
        govern::log "flows_sweep: $id — recorded $repokey@$sha not resolvable in $repodir; cannot compute"
        uncomputable=1; continue
      fi
      changed="$(git -C "$repodir" log --oneline "${sha}..${target}" -- "$pathspec" 2>/dev/null | head -1 || true)"
      [[ -n "$changed" ]] && { staled=1; break; }
    done

    if [[ "$staled" == "1" ]]; then
      GOVERN_FLOWS_SWEEP_STALED="${GOVERN_FLOWS_SWEEP_STALED:+$GOVERN_FLOWS_SWEEP_STALED }$id"
      [[ "$dry" == "1" ]] && continue
      govern::flow_set_field "$id" Status STALE "$flows" || true
      # Auto-withdraw a pending kill disposition on a freshly-stale flow (stale-negative rule).
      disp="$(govern::flow_field "$id" Disposition "$flows")"
      case "$disp" in
        *[Kk]ill*)
          case "$disp" in
            *[Ww]ithdrawn*) : ;;   # already withdrawn — leave it
            *) govern::flow_set_field "$id" Disposition \
                 "withdrawn — flow went STALE before removal (stale negative; re-validate before re-deciding)" "$flows" || true ;;
          esac ;;
      esac
    elif [[ "$uncomputable" == "1" ]]; then
      govern::log "flows_sweep: $id — cannot compute freshness (missing/unpinned mapped repo, no present repo changed) — left as $status"
    fi
  done < <(govern::flow_ids "$flows")
  return 0
}

# Persisting sweep: run govern::flows_sweep_file under cas_edit (bookkeep-lock serialized, pre-sync to
# origin/main, commit + CAS-push ONLY the registry) and print each newly-stale id to stdout. cas_edit's
# edit-fn runs in THIS shell, so the global the sweep appends survives the call. No-op (rc 0) with no
# registry. For the governor / an operator `/shiploop:flows` refresh — NOT the Stop hook (that scans
# dry). Honors GOVERN_NO_PUSH / GOVERN_BOOKKEEP_LOCK_HELD like every other cas_edit write.
govern::flows_sweep() { # [meta-root]
  local meta="${1:-$(govern::meta_root 2>/dev/null || echo "$WS_ROOT")}"
  local flows="$meta/validation/flows.md"
  [[ -f "$flows" ]] || return 0
  GOVERN_FLOWS_SWEEP_STALED=""
  GOVERN_FLOWS_SWEEP_META="$meta" govern::cas_edit "$flows" govern::flows_sweep_file \
    "docs(flows): staleness sweep — degrade flows past their validated SHA"
  local staled="$GOVERN_FLOWS_SWEEP_STALED"; unset GOVERN_FLOWS_SWEEP_STALED
  [[ -n "$staled" ]] && printf '%s\n' $staled
  return 0
}

# Report-only sweep: which staleable flows WOULD go STALE right now, no mutation. One id per line.
# The Stop hook's cheap advisory path.
govern::flows_sweep_scan() { # [meta-root]
  local meta="${1:-$(govern::meta_root 2>/dev/null || echo "$WS_ROOT")}"
  local flows="$meta/validation/flows.md"
  [[ -f "$flows" ]] || return 0
  GOVERN_FLOWS_SWEEP_STALED=""
  GOVERN_FLOWS_SWEEP_META="$meta" GOVERN_FLOWS_SWEEP_DRY=1 govern::flows_sweep_file "$flows"
  local staled="$GOVERN_FLOWS_SWEEP_STALED"; unset GOVERN_FLOWS_SWEEP_STALED
  [[ -n "$staled" ]] && printf '%s\n' $staled
  return 0
}

# ── Status-count summary (doctor / govern-health) ───────────────────────────
# One compact line — "flows: <total> total · 34 PASS-fresh · 6 STALE · … · 1 pending-disposition" —
# listing only the non-zero status buckets plus a pending-disposition count (flows carrying a non-empty
# Disposition, i.e. an operator ship/kill call in flight). PASS renders as "PASS-fresh" (post-sweep, a
# PASS is fresh by definition). Empty (rc 0, no output) when there is no registry.
govern::flows_status_summary() { # [meta-root] -> one line | empty
  local meta="${1:-$(govern::meta_root 2>/dev/null || echo "$WS_ROOT")}"
  local flows="$meta/validation/flows.md"
  [[ -f "$flows" ]] || return 0
  local id status disp total=0 pend=0 st
  local counts_UNTESTED=0 counts_PASS=0 counts_FAIL=0 counts_STALE=0 counts_MEASURING=0
  local counts_INEFFECTIVE=0 counts_EFFECTIVE=0 counts_BLOCKED=0 counts_TOMBSTONED=0 counts_OTHER=0
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    total=$((total+1))
    status="$(govern::flow_field "$id" Status "$flows")"
    case "$status" in
      UNTESTED) counts_UNTESTED=$((counts_UNTESTED+1)) ;;
      PASS) counts_PASS=$((counts_PASS+1)) ;;
      FAIL) counts_FAIL=$((counts_FAIL+1)) ;;
      STALE) counts_STALE=$((counts_STALE+1)) ;;
      MEASURING) counts_MEASURING=$((counts_MEASURING+1)) ;;
      INEFFECTIVE) counts_INEFFECTIVE=$((counts_INEFFECTIVE+1)) ;;
      EFFECTIVE) counts_EFFECTIVE=$((counts_EFFECTIVE+1)) ;;
      BLOCKED) counts_BLOCKED=$((counts_BLOCKED+1)) ;;
      TOMBSTONED) counts_TOMBSTONED=$((counts_TOMBSTONED+1)) ;;
      *) counts_OTHER=$((counts_OTHER+1)) ;;
    esac
    disp="$(govern::flow_field "$id" Disposition "$flows")"
    [[ -n "$disp" ]] && pend=$((pend+1))
  done < <(govern::flow_ids "$flows")

  local out=""
  _add() { [[ "$2" -gt 0 ]] && out="${out:+$out · }$2 $1"; }   # label count
  _add "PASS-fresh"   "$counts_PASS"
  _add "STALE"        "$counts_STALE"
  _add "UNTESTED"     "$counts_UNTESTED"
  _add "MEASURING"    "$counts_MEASURING"
  _add "FAIL"         "$counts_FAIL"
  _add "EFFECTIVE"    "$counts_EFFECTIVE"
  _add "INEFFECTIVE"  "$counts_INEFFECTIVE"
  _add "BLOCKED"      "$counts_BLOCKED"
  _add "TOMBSTONED"   "$counts_TOMBSTONED"
  _add "other"        "$counts_OTHER"
  _add "pending-disposition" "$pend"
  unset -f _add
  printf 'flows: %s total%s' "$total" "${out:+ · $out}"
}

# ── Path-match heads-up (spawn-worker, NON-validation tickets) ──────────────
# Given one or more changed/target paths, print the ids of currently-VALIDATED flows (a settled PASS/
# FAIL/EFFECTIVE/INEFFECTIVE/MEASURING — not UNTESTED/BLOCKED/TOMBSTONED/already-STALE) whose mapped
# globs overlap those paths, MOST-SPECIFIC first (longer matching glob prefix ranks higher), capped at
# <max>. This is the context-flat heads-up injected as a ONE-LINE summary for a non-flow ticket — never
# full blocks. Match is dir-boundary prefix in EITHER direction (the change is under the glob, or the
# glob is under the change), so a coarse ticket path still flags the finer flow.
govern::flows_matching_paths() { # <meta-root> <max> <path> [path…] -> ranked flow ids
  local meta="$1" max="$2"; shift 2
  local -a paths=("$@")
  local flows="$meta/validation/flows.md"
  [[ -f "$flows" && ${#paths[@]} -gt 0 ]] || return 0
  local id status
  { while IFS= read -r id; do
      [[ -n "$id" ]] || continue
      status="$(govern::flow_field "$id" Status "$flows")"
      case "$status" in PASS|FAIL|EFFECTIVE|INEFFECTIVE|MEASURING) ;; *) continue;; esac
      local -a _globs; read -r -a _globs <<< "$(govern::flow_field "$id" Paths "$flows")"
      local best=-1 matched=0 glob gp cand
      for glob in ${_globs[@]+"${_globs[@]}"}; do
        gp="$(govern::flow_glob_prefix "$glob")"
        [[ -n "$gp" ]] || continue
        for cand in "${paths[@]}"; do
          cand="${cand%/}"
          if [[ "$cand" == "$gp" || "$cand" == "$gp/"* || "$gp" == "$cand/"* ]]; then
            matched=1; [[ "${#gp}" -gt "$best" ]] && best="${#gp}"
          fi
        done
      done
      [[ "$matched" == "1" ]] && printf '%s\t%s\n' "$best" "$id"
    done < <(govern::flow_ids "$flows"); } | sort -rn -k1,1 | head -n "$max" | cut -f2-
  return 0
}

# ── Phase 5: capability adapters (generic — knob NAMES here, VALUES in workspace.sh) ─────────────────
# A flow may declare `Requires: <cap> [<cap>…]` (space/comma list) naming the workspace capabilities its
# validation needs. The generic layer maps each capability KEY to the env-var KNOB the workspace wires;
# the knob's VALUE (a gstack command, a PostHog query wrapper, …) lives ONLY in scripts/lib/workspace.sh.
# An absent knob means the flow cannot be validated headlessly → it files as BLOCKED with a named blocker
# (anti-pattern #15), never silently as a runnable-then-billable row.
govern::flow_cap_knob() { # <capability-key> -> env-var name | "" (unknown key we don't manage)
  case "$1" in
    browser)      printf 'WSP_BROWSER_CMD' ;;
    analytics)    printf 'WSP_ANALYTICS_QUERY_CMD' ;;
    test-account) printf 'TEST_USER_EMAIL' ;;
    deploy)       printf 'GOVERN_DEPLOY_SWEEP_CMD' ;;
    *)            printf '' ;;
  esac
}

# The capability keys a flow `Requires:` whose knob is EMPTY (unset/blank) — one per line. An unknown
# key (typo / a capability the generic layer doesn't manage) is IGNORED, never reported missing, so the
# mechanism never blocks a flow on a capability it can't reason about. Empty output (rc 0) when the flow
# declares no `Requires:` or every required knob is wired.
govern::flow_missing_caps() { # id [file] -> missing capability keys, one per line
  local id="$1" f="${2:-$FLOWS_FILE}" req cap knob val
  req="$(govern::flow_field "$id" Requires "$f")"
  [[ -n "$req" ]] || return 0
  req="${req//,/ }"
  for cap in $req; do
    knob="$(govern::flow_cap_knob "$cap")"
    [[ -n "$knob" ]] || continue         # unknown key — not one we manage
    val="${!knob:-}"                      # indirect expansion (bash 3.2 supports ${!var})
    [[ -n "$val" ]] || printf '%s\n' "$cap"
  done
  return 0
}

# A human-readable named-blocker string for a flow's missing capabilities, or "" when nothing is
# missing. Feeds the BLOCKED `Blocker:` field at file/extract time.
govern::flow_missing_cap_blocker() { # id [file] -> "no <cap> capability (<KNOB> unset); …" | ""
  local id="$1" f="${2:-$FLOWS_FILE}" caps cap knob msg=""
  caps="$(govern::flow_missing_caps "$id" "$f")"
  [[ -n "$caps" ]] || return 0
  for cap in $caps; do
    knob="$(govern::flow_cap_knob "$cap")"
    msg="${msg:+$msg; }no $cap capability ($knob unset)"
  done
  printf '%s' "$msg"
}

# ── Phase 5: analytics adapter (effectiveness read + passive-evidence source) ────────────────────────
# The GENERIC interface to the workspace's analytics: run `$WSP_ANALYTICS_QUERY_CMD <source>` and echo
# its stdout. `<source>` is the flow's declared measurement source (the `source:` clause on a Gate, or a
# `Usage-source:` field) — an opaque string the workspace's adapter understands (a PostHog experiment id,
# a HogQL query, an experiment handle). rc 2 (no output) when the knob is unwired — the caller degrades
# to "no passive evidence / effectiveness BLOCKED". Never interprets the payload here; that is the
# caller's job (passive evidence reads a leading integer; the worker reads the gate verdict).
govern::flow_analytics_query() { # <source> -> adapter stdout; rc 2 if WSP_ANALYTICS_QUERY_CMD unset
  local src="$1" knob="${WSP_ANALYTICS_QUERY_CMD:-}"
  [[ -n "$knob" ]] || return 2
  # The knob is a command line; the source is appended as the final arg. Intentional word-split so a
  # multi-word command ("node analytics.js query") is honored.
  # shellcheck disable=SC2086
  $knob "$src" 2>/dev/null || true
}

# ── Phase 5: passive evidence (advisory; NEVER auto-stamps a verdict) ────────────────────────────────
# Where the workspace wires an analytics adapter, a flow declaring a `Usage-source:` gets a passive
# read: "0 real usage" is INEFFECTIVE-LEANING evidence the operator judges — it is NEVER a verdict the
# harness stamps. Report-only by default (prints one advisory line per 0-usage flow, mutates nothing);
# `--attach` additionally records a durable `Passive-note:` field via cas_edit (still never touching
# Status/Disposition — a note, not a stamp). No-op (rc 0) when the analytics knob is unwired.
govern::flows_passive_evidence() { # [meta-root] [--attach] -> advisory lines
  local meta="" attach=0 a
  for a in "$@"; do case "$a" in --attach) attach=1 ;; *) meta="$a" ;; esac; done
  meta="${meta:-$(govern::meta_root 2>/dev/null || echo "$WS_ROOT")}"
  local flows="$meta/validation/flows.md"
  [[ -f "$flows" ]] || return 0
  if [[ -z "${WSP_ANALYTICS_QUERY_CMD:-}" ]]; then
    govern::log "flows_passive_evidence: WSP_ANALYTICS_QUERY_CMD not wired — passive evidence off"; return 0
  fi
  local id status src usage attach_ids=""
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    src="$(govern::flow_field "$id" Usage-source "$flows")"
    [[ -n "$src" ]] || continue
    status="$(govern::flow_field "$id" Status "$flows")"
    # Only a flow that is SUPPOSED to be in use (a positive verdict, or measuring) can be "0 usage".
    case "$status" in PASS|EFFECTIVE|MEASURING) ;; *) continue ;; esac
    usage="$(govern::flow_analytics_query "$src" | head -1 | grep -oE '^-?[0-9]+' | head -1 || true)"
    [[ -n "$usage" ]] || continue         # non-numeric / query failed → can't judge, skip
    if [[ "$usage" -eq 0 ]]; then
      printf 'PASSIVE %s: 0 usage from analytics (source: %s) — INEFFECTIVE-leaning; operator decides (never auto-stamped).\n' "$id" "$src"
      attach_ids="${attach_ids:+$attach_ids }$id"
    fi
  done < <(govern::flow_ids "$flows")
  if [[ "$attach" == "1" && -n "$attach_ids" ]]; then
    local _pn_ids="$attach_ids"
    _flows_passive_attach_edit() { # <flows-file>
      local f="$1" _i
      for _i in $_pn_ids; do
        govern::flow_set_field "$_i" Passive-note "0 usage in analytics ($(date +%F)) — INEFFECTIVE-leaning; operator decides" "$f" || true
      done
    }
    govern::cas_edit "$flows" _flows_passive_attach_edit "docs(flows): passive-evidence advisory (0 usage)"
    unset -f _flows_passive_attach_edit
  fi
  return 0
}

# ── Phase 5: due-advisories (MEASURING sample-window elapsed · Revalidate past due) ──────────────────
# Extract a day-count N from a policy string like "every 14d", "7d", "14 days" → prints N (or "").
govern::_flows_days_of() { # str -> N | ""
  local s="$1" n
  n="$(printf '%s' "$s" | grep -oE '[0-9]+[[:space:]]*d([[:space:]]|$)' | head -1 | grep -oE '[0-9]+' | head -1 || true)"
  [[ -n "$n" ]] || n="$(printf '%s' "$s" | grep -oE '[0-9]+[[:space:]]*day' | head -1 | grep -oE '[0-9]+' | head -1 || true)"
  printf '%s' "$n"
}

# Pure READ — one advisory line per flow that is (a) MEASURING with a declared `Sample-window: <N>d`
# whose window has plausibly elapsed since it was armed (Validated date), or (b) a settled verdict whose
# `Revalidate: every <N>d` policy is past due. NEVER files, NEVER mutates — the periodic supervisor pass
# surfaces these for the operator (billable safety: filing a validation is always a human act). Empty
# (rc 0) when nothing is due or there is no registry.
govern::flows_due_advisories() { # [meta-root] -> advisory lines
  local meta="${1:-$(govern::meta_root 2>/dev/null || echo "$WS_ROOT")}"
  local flows="$meta/validation/flows.md"
  [[ -f "$flows" ]] || return 0
  local now_epoch id status val vdate vepoch days win reval
  now_epoch="$(date +%s)"
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    status="$(govern::flow_field "$id" Status "$flows")"
    val="$(govern::flow_field "$id" Validated "$flows")"
    vdate="${val%%[[:space:]]*}"
    vepoch="$(govern::date_to_epoch "$vdate" 2>/dev/null || true)"
    [[ -n "$vepoch" ]] || continue
    days=$(( (now_epoch - vepoch) / 86400 ))
    if [[ "$status" == "MEASURING" ]]; then
      win="$(govern::_flows_days_of "$(govern::flow_field "$id" Sample-window "$flows")")"
      if [[ -n "$win" && "$days" -ge "$win" ]]; then
        printf 'MEASURING %s: sample window (%sd) elapsed — %sd since armed (%s). File a collect validation to read the gate + stamp EFFECTIVE/INEFFECTIVE.\n' "$id" "$win" "$days" "$vdate"
      fi
    fi
    case " $GOVERN_FLOW_STALEABLE_STATUSES " in
      *" $status "*)
        reval="$(govern::_flows_days_of "$(govern::flow_field "$id" Revalidate "$flows")")"
        if [[ -n "$reval" && "$days" -ge "$reval" ]]; then
          printf 'REVALIDATE %s: due (every %sd; last validated %s, %sd ago). Re-file this flow to refresh its verdict.\n' "$id" "$reval" "$vdate" "$days"
        fi ;;
    esac
  done < <(govern::flow_ids "$flows")
  return 0
}

# ── Phase 5: kill loop — Flow-op parse, removal-ticket filing, tombstone-on-resolve ─────────────────
# A ticket's `Flow-op:` field (leading-field-block, anchored like ticket_flow_ids) declares what a
# resolve does to the flow registry: default "validate" (stamp a verdict), or "remove" (a KILL removal
# ticket — its PR deletes the feature, and on resolve bookkeep TOMBSTONES the flow rather than stamping
# a verdict). Empty/absent → validate.
govern::ticket_flow_op() { # N [tickets-file] -> validate|remove
  local n="$1" f="${2:-$TICKETS_FILE}" raw
  raw="$(govern::ticket_block "$n" "$f" \
    | awk 'NR==1{next} !started && NF==0 {next} NF==0 {exit} {started=1; print}' \
    | sed -n -E 's/^[[:space:]]*\*{0,2}[Ff]low-op:\*{0,2}[[:space:]]*//p' | head -1)"
  raw="$(printf '%s' "$raw" | tr 'A-Z' 'a-z' | tr -d '[:space:]')"
  case "$raw" in remove|removal|kill|tombstone) printf 'remove' ;; *) printf 'validate' ;; esac
}

# Mark an INEFFECTIVE flow as kill-pending (operator disposition): set Disposition so `list`/health show
# the kill in flight AND the staleness sweep's kill-withdrawal rule (Phase 3) can auto-withdraw it if the
# flow goes STALE before the removal lands. Writes through cas_edit; honors GOVERN_BOOKKEEP_LOCK_HELD.
govern::flows_mark_kill_pending() { # <id> [meta-root]
  local id="$1" meta="${2:-$(govern::meta_root 2>/dev/null || echo "$WS_ROOT")}"
  local flows="$meta/validation/flows.md"
  [[ -f "$flows" ]] || return 0
  govern::flow_exists "$id" "$flows" || { govern::log "flows_mark_kill_pending: '$id' not in registry — skipping"; return 0; }
  local _kid="$id"
  _flows_kill_pending_edit() { govern::flow_set_field "$_kid" Disposition "kill → removal ticket pending" "$1"; }
  govern::cas_edit "$flows" _flows_kill_pending_edit "docs(flows): $id kill disposition — removal ticket pending"
  unset -f _flows_kill_pending_edit
  return 0
}

# Tombstone one or more flows (space/comma id list) on a KILL removal ticket's resolve: Status→TOMBSTONED,
# Disposition annotated, ALL other fields (Validated/Evidence/history) preserved (a revived feature starts
# from its record; re-extraction cannot resurrect it as new). SupersededBy is left UNSET — that field is
# reserved for supersession (a rename/split), not a plain kill. Writes through cas_edit under the bookkeep
# lock (honors GOVERN_BOOKKEEP_LOCK_HELD). No-op for an id not in the registry.
govern::flows_tombstone() { # <idlist> [meta-root]
  local idlist="$1" meta="${2:-$(govern::meta_root 2>/dev/null || echo "$WS_ROOT")}"
  local flows="$meta/validation/flows.md" id
  [[ -f "$flows" ]] || { govern::log "flows_tombstone: no registry at $flows — nothing to tombstone"; return 0; }
  idlist="${idlist//,/ }"
  for id in $idlist; do
    [[ -n "$id" ]] || continue
    if ! govern::flow_exists "$id" "$flows"; then
      govern::log "flows_tombstone: flow '$id' not in registry — skipping"; continue
    fi
    local _tid="$id"
    _flows_tombstone_edit() { # <flows-file>
      govern::flow_set_field "$_tid" Status TOMBSTONED "$1"
      govern::flow_set_field "$_tid" Disposition "killed — removal PR opened; history preserved" "$1"
    }
    govern::cas_edit "$flows" _flows_tombstone_edit "docs(flows): tombstone $id (removal PR opened)"
    unset -f _flows_tombstone_edit
    govern::log "flows_tombstone: $id → TOMBSTONED (kill loop complete)"
  done
  return 0
}
