#!/usr/bin/env bash
# ── Shared dev-stack preflight probes ── SOURCE this file; do NOT execute.
#
# Pure, non-mutating probes the read-only `doctor` and a `dev` launcher can both
# share. Each prints a result token and never changes anything, so each caller
# decides how to react (doctor warns; a launcher could auto-install).
#
# Currently ships the node_modules-vs-package.json drift probe: a dependency
# DECLARED in package.json but absent from node_modules (e.g. a dep added after
# the last install) makes `require()`/`import` throw "Cannot find module" at
# RUNTIME with no boot signal. Catching it as a preflight turns a cryptic crash
# into an actionable warning.
#
# NOTE: a project that runs a service stack (e.g. Redis/Postgres) can add its own
# probes here via the project hook seam (scripts/lib/doctor-extra.sh) — for
# example a Redis RDB-bgsave / persistence check. Those are deliberately left out
# of this generic lib because they presume a particular stack.

# List dependencies DECLARED in <pkgdir>/package.json (dependencies +
# devDependencies) that are absent from <pkgdir>/node_modules. Echoes the missing
# names space-separated (empty when all satisfied), or the sentinel
# `__NO_NODE_MODULES__` when node_modules itself is absent. Returns 2 (caller
# should skip) when it can't check — node missing or no package.json. A
# declared-but-uninstalled dep is exactly what makes `require()` throw
# "Cannot find module" at runtime.
preflight_missing_deps() {
  local pkgdir="$1"
  [ -f "$pkgdir/package.json" ] || return 2
  command -v node >/dev/null 2>&1 || return 2
  [ -d "$pkgdir/node_modules" ] || { echo "__NO_NODE_MODULES__"; return 0; }
  node -e '
    const fs = require("fs");
    const path = require("path");
    const dir = process.argv[1];
    let pkg;
    try {
      pkg = JSON.parse(fs.readFileSync(path.join(dir, "package.json"), "utf8"));
    } catch {
      process.exit(0);
    }
    const declared = { ...(pkg.dependencies || {}), ...(pkg.devDependencies || {}) };
    const missing = Object.keys(declared).filter(
      (d) => !fs.existsSync(path.join(dir, "node_modules", d, "package.json"))
    );
    if (missing.length) console.log(missing.join(" "));
  ' "$pkgdir" 2>/dev/null
  return 0
}
