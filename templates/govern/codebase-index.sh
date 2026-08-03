#!/usr/bin/env bash
# codebase-index.sh — a persistent, DETERMINISTIC codebase index shared by every worker.
#
# Why: exploration is the dominant cost of a resolved ticket, and every worker pays it cold. Measured
# on a worker session, `Read` is 7.7% of tool CALLS but 31% of returned BYTES, at ~6,145 B/call. An
# index converts per-ticket O(explore) into O(read index) amortized across the whole backlog: twenty
# tickets against one repo currently pay twenty identical rediscoveries of the same layout.
#
# Why NEVER model-generated: a model-written digest is a RECURRING bill AND it rots the moment the
# tree moves — the worst combination. Everything here comes from `git`, `grep`, and `ctags` (ctags is
# used only when present; absent, the grep extractors carry it). Zero `claude` invocations, by design.
#
# Contract:
#   codebase-index.sh build [repo|path ...]   (re)build. No args = every sub-repo in $REPOS.
#   codebase-index.sh query <path-or-symbol>  print matching rows (substring, case-insensitive).
#   codebase-index.sh path <file>             print everything known about one file.
#   codebase-index.sh summary                 print the human-readable summary path + contents.
#
# Artifacts, under ${GOVERN_INDEX_DIR:-$GOVERNOR_DIR/index}:
#   <repo>.tsv    the index. TAB-separated, three columns, one row per fact:
#                   sym <file>      <symbol>     — file defines/exports <symbol>
#                   cov <testfile>  <file>       — <testfile> is believed to cover <file> (HEURISTIC)
#                   dep <module>    <dependent>  — <dependent> imports <module> (reverse import graph)
#   <repo>.ref    the commit the .tsv reflects (drives the incremental path)
#   SUMMARY.md    small human-readable digest a worker prompt can point at
#
# Env:
#   GOVERN_INDEX=1|0            0 makes `build` a SILENT no-op exiting 0 (query/path still read a
#                               previously built index). Default 1.
#   GOVERN_INDEX_DIR            artifact dir override.
#   GOVERN_INDEX_MAX_FILES      per-repo file cap, default 5000 — keeps a full rebuild bounded.
#   GOVERN_INDEX_FULL=1         force a full rebuild, skipping the incremental path.
#
# Never fails the caller: best-effort partial success exits 0; all diagnostics go to stderr. It is
# invoked post-merge by the loop, so a hard failure here must never take the run down.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$DIR/lib/common.sh"

INDEX_DIR="${GOVERN_INDEX_DIR:-$GOVERNOR_DIR/index}"
MAX_FILES="${GOVERN_INDEX_MAX_FILES:-5000}"
[[ "$MAX_FILES" =~ ^[0-9]+$ ]] || MAX_FILES=5000

# ctags is a bonus, never a requirement — it parses properly where the greps only pattern-match.
# `GOVERN_INDEX_CTAGS=0` forces the grep extractors (used by the tests so their expectations are
# identical on a machine with and without ctags installed).
#
# The probe is a CAPABILITY check, not a presence check: macOS ships a BSD `ctags` at /usr/bin/ctags
# that rejects every long option and prints a usage error instead of tags. Only Universal/Exuberant
# ctags understands the `-x` cross-reference format this reads, so match the banner.
IDX_HAVE_CTAGS=0
if [[ "${GOVERN_INDEX_CTAGS:-1}" == "1" ]] && command -v ctags >/dev/null 2>&1; then
  if ctags --version 2>/dev/null | grep -qE 'Universal Ctags|Exuberant Ctags'; then IDX_HAVE_CTAGS=1; fi
fi

# ── file classification ─────────────────────────────────────────────────────────────────────────

# Is $1 a source file we know how to extract from? Keeps the index dense instead of listing assets.
idx::is_source() { # <path>
  case "$1" in
    *.js|*.jsx|*.mjs|*.cjs|*.ts|*.tsx|*.py|*.go|*.rb|*.sh|*.bash|*.rs|*.java|*.kt|*.php) return 0 ;;
    *) return 1 ;;
  esac
}

# Is $1 a test file? Path-shape OR basename-shape — both conventions are in wide use and a repo
# usually picks one. Deliberately broad: a false positive only adds `cov` rows, never removes facts.
idx::is_test() { # <path>
  case "$1" in
    */test/*|*/tests/*|*/__tests__/*|*/spec/*|test/*|tests/*|spec/*|__tests__/*) return 0 ;;
  esac
  local base="${1##*/}"
  case "$base" in
    *.test.*|*.spec.*|test_*.py|*_test.py|*_test.go|test-*.sh|test_*.sh|*_spec.rb|*Test.java|*Tests.kt) return 0 ;;
  esac
  return 1
}

# ── symbol extraction ───────────────────────────────────────────────────────────────────────────

# Emit `sym\t<path>\t<symbol>` rows for one file. ctags first when available (it actually parses);
# otherwise per-language greps that target DEFINITION sites only, so the index stays small enough to
# be worth reading. Best-effort: an unparseable file simply contributes no rows.
idx::symbols() { # <repo-root> <rel-path>
  local root="$1" rel="$2"
  local abs="$root/$rel"
  [[ -r "$abs" ]] || return 0

  if [[ "${IDX_HAVE_CTAGS:-0}" -eq 1 ]]; then
    local out
    # `ctags -x` prints: <name> <kind> <line> <file> <source line>. Column 1 is all we need.
    out="$(ctags -x "$abs" 2>/dev/null \
      | awk -v p="$rel" 'NF>=4 && $1 ~ /^[A-Za-z_][A-Za-z0-9_]*$/ { print "sym\t" p "\t" $1 }' \
      | LC_ALL=C sort -u | head -n 200)" || out=""
    # A ctags build that doesn't know this language emits nothing — fall THROUGH to the greps rather
    # than silently dropping the file's symbols.
    if [[ -n "$out" ]]; then printf '%s\n' "$out"; return 0; fi
  fi

  case "$rel" in
    *.js|*.jsx|*.mjs|*.cjs|*.ts|*.tsx)
      grep -Eho '^[[:space:]]*(export[[:space:]]+)?(default[[:space:]]+)?(async[[:space:]]+)?(function|class|const|let|var|interface|type|enum)[[:space:]]+[A-Za-z_$][A-Za-z0-9_$]*' "$abs" 2>/dev/null \
        | awk '{ print $NF }'
      ;;
    *.py)
      grep -Eho '^[[:space:]]*(async[[:space:]]+)?(def|class)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' "$abs" 2>/dev/null \
        | awk '{ print $NF }'
      ;;
    *.go)
      grep -Eho '^(func|type)[[:space:]]+(\([^)]*\)[[:space:]]*)?[A-Za-z_][A-Za-z0-9_]*' "$abs" 2>/dev/null \
        | awk '{ print $NF }'
      ;;
    *.rb)
      grep -Eho '^[[:space:]]*(def|class|module)[[:space:]]+[A-Za-z_][A-Za-z0-9_:.]*' "$abs" 2>/dev/null \
        | awk '{ print $NF }'
      ;;
    *.sh|*.bash)
      # Both `name() {` and the govern:: namespaced form; `function name {` too.
      grep -Eho '^[[:space:]]*(function[[:space:]]+)?[A-Za-z_][A-Za-z0-9_:]*[[:space:]]*\(\)' "$abs" 2>/dev/null \
        | sed -E 's/[[:space:]]*\(\)[[:space:]]*$//; s/^[[:space:]]*(function[[:space:]]+)?//'
      ;;
    *.rs)
      grep -Eho '^[[:space:]]*(pub[[:space:]]+)?(fn|struct|enum|trait|mod)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' "$abs" 2>/dev/null \
        | awk '{ print $NF }'
      ;;
    *.java|*.kt)
      grep -Eho '^[[:space:]]*(public|private|protected|internal)?[[:space:]]*(final[[:space:]]+)?(abstract[[:space:]]+)?(class|interface|enum|object|fun)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' "$abs" 2>/dev/null \
        | awk '{ print $NF }'
      ;;
    *.php)
      grep -Eho '^[[:space:]]*(abstract[[:space:]]+|final[[:space:]]+)?(function|class|trait|interface)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' "$abs" 2>/dev/null \
        | awk '{ print $NF }'
      ;;
    *) return 0 ;;
  esac | grep -Ev '^(if|for|while|return|else|end|do|then|fi|case|esac|in|of|new|this|self)$' \
       | sort -u | head -n 200 | awk -v p="$rel" 'NF { print "sym\t" p "\t" $0 }'
  return 0
}

# ── import extraction + resolution (reverse dependency graph) ───────────────────────────────────

# Raw import specifiers a file names, one per line. Language-specific, definition-free — we only
# care about the STRING, resolution happens next.
idx::raw_imports() { # <repo-root> <rel-path>
  local abs="$1/$2"
  [[ -r "$abs" ]] || return 0
  case "$2" in
    *.js|*.jsx|*.mjs|*.cjs|*.ts|*.tsx)
      { grep -Eho "from[[:space:]]+['\"][^'\"]+['\"]" "$abs" 2>/dev/null || true
        grep -Eho "require\([[:space:]]*['\"][^'\"]+['\"]" "$abs" 2>/dev/null || true
        grep -Eho "import[[:space:]]+['\"][^'\"]+['\"]" "$abs" 2>/dev/null || true
      } | sed -E "s/.*['\"]([^'\"]+)['\"].*/\1/"
      ;;
    *.py)
      { grep -Eho '^[[:space:]]*from[[:space:]]+[A-Za-z0-9_.]+' "$abs" 2>/dev/null || true
        grep -Eho '^[[:space:]]*import[[:space:]]+[A-Za-z0-9_.]+' "$abs" 2>/dev/null || true
      } | awk '{ print $NF }'
      ;;
    *.go)
      grep -Eho '"[a-zA-Z0-9_./-]+"' "$abs" 2>/dev/null | tr -d '"' | grep '/' || true
      ;;
    *.rb)
      grep -Eho "require(_relative)?[[:space:]]+['\"][^'\"]+['\"]" "$abs" 2>/dev/null \
        | sed -E "s/.*['\"]([^'\"]+)['\"].*/\1/"
      ;;
    *.sh|*.bash)
      # `source x/y.sh` and `. x/y.sh` — the govern harness's own dependency mechanism. The idiomatic
      # form is `source "$DIR/lib/common.sh"` where $DIR is the script's OWN directory, so strip the
      # quotes and a leading `$VAR/` / `${VAR}/` and re-anchor the remainder as `./…`. That is
      # correct for the overwhelmingly common self-dir case and simply fails to resolve otherwise.
      grep -Eho '^[[:space:]]*(source|\.)[[:space:]]+[^[:space:];]+' "$abs" 2>/dev/null \
        | awk '{ print $NF }' \
        | tr -d '"'"'" \
        | sed -E 's#^\$\{?[A-Za-z_][A-Za-z0-9_]*\}?/#./#' \
        | grep -E '\.(sh|bash)$' || true
      ;;
    *) return 0 ;;
  esac
  return 0
}

# Resolve one import specifier to a repo-relative path, or emit nothing. Handles the relative forms
# (`./x`, `../x`) with the usual extension/index probing; a bare package name (`react`, `os`) has no
# in-repo path and is correctly dropped. Python dotted paths are probed as a/b/c.py.
idx::resolve_import() { # <repo-root> <importing-rel-path> <spec>
  local root="$1" from="$2" spec="$3"
  local base cand
  case "$spec" in
    ./*|../*)
      base="$(cd "$root/$(dirname "$from")" 2>/dev/null && pwd -P)" || return 0
      base="$base/$spec"
      ;;
    /*) return 0 ;;
    *)
      # Non-relative: try it as a repo-root-relative path (works for go module subpaths, python
      # dotted modules, and monorepo aliases that mirror the tree). Anything else drops out.
      base="$root/${spec//.//}"
      ;;
  esac
  local ext
  for ext in "" .ts .tsx .js .jsx .mjs .cjs .py .go .rb .sh /index.ts /index.js /index.tsx /index.jsx /__init__.py; do
    cand="${base}${ext}"
    if [[ -f "$cand" ]]; then
      # Normalize to repo-relative. realpath is not portable enough to rely on; do it textually.
      cand="$(cd "$(dirname "$cand")" 2>/dev/null && pwd -P)/$(basename "$cand")" || return 0
      case "$cand" in "$root"/*) printf '%s\n' "${cand#"$root"/}"; return 0 ;; esac
      return 0
    fi
  done
  return 0
}

# ── test → covered-file heuristic ───────────────────────────────────────────────────────────────

# HEURISTIC, and labelled as such everywhere it surfaces: there is no deterministic way to know what
# a test "covers" without running it under coverage. Two signals, both cheap and both wrong sometimes:
#   1. the test file's own resolved in-repo imports (strong signal, drives most rows)
#   2. name stripping — `foo.test.ts` → `foo.ts` beside it, `test_foo.py` → `foo.py`, `test-x.sh` →
#      `x.sh` — probed in the same dir, the parent dir, and the sibling src/ dir.
# A worker must treat `cov` rows as "start here", never as proof.
idx::cov_by_name() { # <repo-root> <test-rel-path>
  local root="$1" rel="$2"
  local dir base stem
  dir="$(dirname "$rel")"
  base="${rel##*/}"
  stem="$base"
  stem="${stem/.test./.}"
  stem="${stem/.spec./.}"
  stem="${stem#test_}"
  stem="${stem#test-}"
  # Each `<x>_test.<ext>` rule MUST be case-guarded: an unguarded `${stem%_test.py}.py` appends `.py`
  # to every non-Python name (`select-ticket.sh` → `select-ticket.sh.py`) and the probe never hits.
  case "$base" in
    *_test.py)  stem="${base%_test.py}.py" ;;
    *_test.go)  stem="${base%_test.go}.go" ;;
    *_spec.rb)  stem="${base%_spec.rb}.rb" ;;
    *_test.sh)  stem="${base%_test.sh}.sh" ;;
  esac
  [[ "$stem" != "$base" ]] || return 0
  local d cand
  for d in "$dir" "$dir/.." "$dir/../src" "src" "lib" "."; do
    cand="$(printf '%s/%s' "$d" "$stem" | sed -E 's#/\./#/#g; s#^\./##')"
    # Collapse a single `a/../` segment textually — `cd`-based resolution would escape the repo.
    cand="$(printf '%s' "$cand" | sed -E 's#[^/]+/\.\./##g')"
    if [[ -f "$root/$cand" ]]; then printf '%s\n' "$cand"; return 0; fi
  done
  return 0
}

# ── build ───────────────────────────────────────────────────────────────────────────────────────

# Index one file: symbols, plus its resolved imports as reverse-graph rows, plus cov rows if it is a
# test. Emits TSV rows on stdout; never fails.
idx::index_file() { # <repo-root> <rel-path>
  local root="$1" rel="$2" spec target
  idx::symbols "$root" "$rel" || true
  while IFS= read -r spec; do
    [[ -n "$spec" ]] || continue
    target="$(idx::resolve_import "$root" "$rel" "$spec" || true)"
    [[ -n "$target" && "$target" != "$rel" ]] || continue
    printf 'dep\t%s\t%s\n' "$target" "$rel"
    # A test importing ANOTHER test file (the shared `assert.sh` helper, a fixture module) is not
    # coverage — without this filter every test in the suite claims to "cover" the helper and the
    # cov rows drown in one useless star.
    if idx::is_test "$rel" && ! idx::is_test "$target"; then printf 'cov\t%s\t%s\n' "$rel" "$target"; fi
  done < <(idx::raw_imports "$root" "$rel" | sort -u)
  if idx::is_test "$rel"; then
    target="$(idx::cov_by_name "$root" "$rel" || true)"
    [[ -n "$target" ]] && printf 'cov\t%s\t%s\n' "$rel" "$target"
  fi
  return 0
}

# Rebuild (or incrementally refresh) one repo's .tsv + .ref.
idx::build_repo() { # <name> <root>
  local name="$1" root="$2"
  local tsv="$INDEX_DIR/$name.tsv"
  local ref_file="$INDEX_DIR/$name.ref"
  if [[ ! -d "$root" ]]; then
    govern::log "index: skipping '$name' — no such directory: $root"
    return 0
  fi
  if ! git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
    govern::log "index: skipping '$name' — not a git repo: $root"
    return 0
  fi

  local head old_ref="" mode="full"
  head="$(git -C "$root" rev-parse HEAD 2>/dev/null || printf 'unknown')"
  [[ -f "$ref_file" ]] && old_ref="$(cat "$ref_file" 2>/dev/null || printf '')"

  local files=() changed=()
  if [[ "${GOVERN_INDEX_FULL:-0}" != "1" && -s "$tsv" && -n "$old_ref" && "$old_ref" != "unknown" ]] \
     && git -C "$root" cat-file -e "$old_ref^{commit}" 2>/dev/null; then
    # Incremental: only files that moved since the indexed ref, plus anything currently dirty.
    mode="incremental"
    while IFS= read -r f; do [[ -n "$f" ]] && changed+=("$f"); done < <(
      { git -C "$root" diff --name-only "$old_ref" HEAD 2>/dev/null || true
        git -C "$root" diff --name-only HEAD 2>/dev/null || true
      } | sort -u)
    if [[ "${#changed[@]}" -eq 0 ]]; then
      printf '%s\n' "$head" > "$ref_file"
      govern::log "index: $name unchanged since ${old_ref:0:8} — no work"
      return 0
    fi
    files=("${changed[@]}")
  fi

  if [[ "$mode" == "full" ]]; then
    while IFS= read -r f; do [[ -n "$f" ]] && files+=("$f"); done < <(
      git -C "$root" ls-files 2>/dev/null | head -n "$MAX_FILES")
  fi

  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/govern-index.XXXXXX")"
  # Incremental: carry forward every row that does NOT concern a changed file. `dep` rows are keyed
  # by the DEPENDENT (col 3) — a changed importer invalidates its dep rows; `sym`/`cov` rows are
  # keyed by the file itself (col 2).
  if [[ "$mode" == "incremental" && -s "$tsv" ]]; then
    local drop
    drop="$(mktemp "${TMPDIR:-/tmp}/govern-index-drop.XXXXXX")"
    printf '%s\n' "${changed[@]}" > "$drop"
    awk -F'\t' -v dropfile="$drop" '
      BEGIN { while ((getline l < dropfile) > 0) d[l]=1 }
      $1 == "dep" { if (!($3 in d)) print; next }
      { if (!($2 in d)) print }
    ' "$tsv" > "$tmp" 2>/dev/null || true
    rm -f "$drop" 2>/dev/null || true
  fi

  # `${files[@]+"${files[@]}"}` — bash 3.2 (macOS) errors on an empty array under `set -u`.
  local f n=0
  for f in ${files[@]+"${files[@]}"}; do
    idx::is_source "$f" || continue
    [[ -f "$root/$f" ]] || continue   # deleted in an incremental pass → rows already dropped
    idx::index_file "$root" "$f" >> "$tmp" 2>/dev/null || true
    n=$((n + 1))
  done

  mkdir -p "$INDEX_DIR"
  LC_ALL=C sort -u "$tmp" > "$tsv" 2>/dev/null || cp "$tmp" "$tsv" 2>/dev/null || true
  rm -f "$tmp" 2>/dev/null || true
  printf '%s\n' "$head" > "$ref_file"
  govern::log "index: $name — $mode, $n file(s) indexed, $(awk 'END{print NR+0}' "$tsv") row(s) → $tsv"
  return 0
}

# One small human-readable digest across all indexed repos. This is the artifact a worker prompt
# points at; the .tsv files are for `query`/`path`.
idx::write_summary() {
  local out="$INDEX_DIR/SUMMARY.md"
  mkdir -p "$INDEX_DIR"
  {
    printf '# Codebase index\n\n'
    printf 'Generated deterministically by `scripts/govern/codebase-index.sh` from `git` + `grep`'
    printf '%s. No model wrote any of this.\n\n' "$([[ "${IDX_HAVE_CTAGS:-0}" -eq 1 ]] && printf ' + `ctags`')"
    printf 'Query it instead of exploring:\n\n'
    printf '```\nscripts/govern/codebase-index.sh query <symbol-or-path>\nscripts/govern/codebase-index.sh path <file>\n```\n\n'
    printf 'Row kinds in `<repo>.tsv` (TAB-separated):\n\n'
    printf -- '- `sym <file> <symbol>` — file defines/exports symbol\n'
    printf -- '- `dep <module> <dependent>` — dependent imports module (reverse import graph)\n'
    printf -- '- `cov <testfile> <file>` — testfile is BELIEVED to cover file. **Heuristic**'
    printf ' (resolved imports + filename stripping) — a starting point, never proof.\n\n'
    local tsv name
    for tsv in "$INDEX_DIR"/*.tsv; do
      [[ -f "$tsv" ]] || continue
      name="$(basename "$tsv" .tsv)"
      printf '## %s\n\n' "$name"
      printf -- '- ref: `%s`\n' "$(cat "$INDEX_DIR/$name.ref" 2>/dev/null || printf 'unknown')"
      printf -- '- files with symbols: %s\n' "$(awk -F'\t' '$1=="sym"{print $2}' "$tsv" | sort -u | wc -l | tr -d ' ')"
      printf -- '- symbols: %s\n' "$(awk -F'\t' '$1=="sym"' "$tsv" | wc -l | tr -d ' ')"
      printf -- '- import edges: %s\n' "$(awk -F'\t' '$1=="dep"' "$tsv" | wc -l | tr -d ' ')"
      printf -- '- test→file links: %s\n' "$(awk -F'\t' '$1=="cov"' "$tsv" | wc -l | tr -d ' ')"
      printf '\n  Most-depended-on modules:\n\n'
      awk -F'\t' '$1=="dep"{c[$2]++} END{for(k in c) printf "%d\t%s\n", c[k], k}' "$tsv" \
        | sort -rn | head -n 10 | awk -F'\t' '{ printf "  - `%s` — %s dependent(s)\n", $2, $1 }'
      printf '\n'
    done
  } > "$out"
  govern::log "index: summary → $out"
  return 0
}

idx::cmd_build() { # [repo|path ...]
  if [[ "${GOVERN_INDEX:-1}" != "1" ]]; then exit 0; fi   # kill switch: silent no-op
  mkdir -p "$INDEX_DIR"
  local t name root
  local targets=()
  targets=(${@+"$@"})
  if [[ "${#targets[@]}" -eq 0 ]]; then targets=(${REPOS[@]+"${REPOS[@]}"}); fi
  if [[ "${#targets[@]}" -eq 0 ]]; then
    govern::log "index: no repos to index (REPOS is empty and no argument given)"
    return 0
  fi
  for t in "${targets[@]}"; do
    [[ -n "$t" ]] || continue
    if [[ -d "$t" ]]; then
      root="$(cd "$t" && pwd -P)"
      name="$(basename "$root")"
    else
      name="$t"
      root="$(wsp_repo_localdir "$t" 2>/dev/null || printf '%s/%s' "$WS_ROOT" "$t")"
    fi
    idx::build_repo "$name" "$root" || true
  done
  idx::write_summary || true
  return 0
}

idx::cmd_query() { # <term>
  local term="$1" tsv
  local found=0
  for tsv in "$INDEX_DIR"/*.tsv; do
    [[ -f "$tsv" ]] || continue
    while IFS= read -r row; do
      printf '%s\t%s\n' "$(basename "$tsv" .tsv)" "$row"
      found=1
    done < <(grep -iF -- "$term" "$tsv" 2>/dev/null | head -n 200 || true)
  done
  [[ "$found" -eq 1 ]] || govern::log "index: no rows match '$term' (is the index built?)"
  return 0
}

idx::cmd_path() { # <file>
  local file="$1" tsv name
  for tsv in "$INDEX_DIR"/*.tsv; do
    [[ -f "$tsv" ]] || continue
    name="$(basename "$tsv" .tsv)"
    awk -F'\t' -v f="$file" -v repo="$name" '
      $1=="sym" && index($2,f) { s[$3]=1; sf=1 }
      $1=="dep" && index($2,f) { deps[$3]=1; df=1 }
      $1=="dep" && index($3,f) { imports[$2]=1; imf=1 }
      $1=="cov" && index($3,f) { tests[$2]=1; tf=1 }
      $1=="cov" && index($2,f) { covers[$3]=1; cf=1 }
      END {
        if (!(sf||df||imf||tf||cf)) exit 0
        printf "[%s] %s\n", repo, f
        if (sf) { printf "  defines: "; for (k in s) printf "%s ", k; printf "\n" }
        if (imf) { printf "  imports: "; for (k in imports) printf "%s ", k; printf "\n" }
        if (df) { printf "  imported by: "; for (k in deps) printf "%s ", k; printf "\n" }
        if (tf) { printf "  covered by (heuristic): "; for (k in tests) printf "%s ", k; printf "\n" }
        if (cf) { printf "  covers (heuristic): "; for (k in covers) printf "%s ", k; printf "\n" }
      }
    ' "$tsv" 2>/dev/null || true
  done
  return 0
}

CMD="${1:-}"
[[ $# -gt 0 ]] && shift || true
case "$CMD" in
  build)   idx::cmd_build "$@" ;;
  query)   [[ -n "${1:-}" ]] || { echo "usage: codebase-index.sh query <path-or-symbol>" >&2; exit 2; }
           idx::cmd_query "$1" ;;
  path)    [[ -n "${1:-}" ]] || { echo "usage: codebase-index.sh path <file>" >&2; exit 2; }
           idx::cmd_path "$1" ;;
  summary) printf '%s\n' "$INDEX_DIR/SUMMARY.md"; cat "$INDEX_DIR/SUMMARY.md" 2>/dev/null || true ;;
  *) echo "usage: codebase-index.sh build [repo|path ...] | query <term> | path <file> | summary" >&2; exit 2 ;;
esac
exit 0
