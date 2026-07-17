# Flow registry

The git-tracked inventory of **user-reachable flows** this product exposes — each keyed by a stable,
never-renamed id and pinned to the code SHAs it was last validated against. The governor stamps this
file deterministically on every validation ticket's resolve/gate-park; you seed and curate the flow
entries. It answers, at any HEAD: which paths are proven, which are stale, which failed, and which
measured ineffective (deletion candidates). See the design spec for the full model.

## Block grammar

Each flow is one `## <id>` block. `<id>` is lowercase dot-separated kebab, coarse→fine
(`deploy-gpu.vastai`, `comfyui.migration.datacrunch`, `api.deployments.close`). Ids are STABLE —
never rename a referenced id; evolve via supersession (`Supersedes:` / `SupersededBy:`).

Fields:
- **Kind** (required) — `correctness` (does it work? → PASS/FAIL) or `effectiveness` (worth keeping? → EFFECTIVE/INEFFECTIVE; requires a `Gate`).
- **Surface** (required) — human sketch of the path (`console UI → orchestrator → provider`).
- **Paths** (required) — space-separated git pathspec globs; **first segment = sub-repo folder name**; no spaces inside a glob. The staleness sweep degrades this flow when any mapped path changes past its validated SHA.
- **Status** (required) — `UNTESTED | PASS | FAIL | STALE | MEASURING | INEFFECTIVE | EFFECTIVE | BLOCKED | TOMBSTONED`.
- **Validated / Evidence / Env** (required once validated) — date · `repo@sha …` pins · PR URL; a pointer to `.claude/shiploop/validation/evidence/<id>.md` (or an https object-storage URL); `local` or `prod`.
- **Gate** (required when Kind=effectiveness) — the metric + threshold + measurement source (`… ≥10% reduction, N≥100 · source: posthog:experiment/opt-v2`).
- **Blocker** (required when Status=BLOCKED) — the named unworkable blocker (per anti-pattern #15).
- Optional: **Revalidate** (`on-change` | `every <N>d`), **Disposition**, **Supersedes**, **SupersededBy**, **Resource-group**, **Env-required**.

Unknown fields are preserved verbatim on rewrite. `<!-- HTML comments -->` are decoration (parsers
strip them); a legitimate PII mention is allowlisted with `<!-- lint:allow <pattern> -->` on the line.

Populate with `/shiploop:flows extract` (staged for your approval), then `/shiploop:flows file <ids>`
to queue validations. Example blocks (a `correctness` flow and a gated `effectiveness` flow) live in
the design spec — they are not embedded here because the block parser reads `## <id>` headings even
inside HTML comments and would lint placeholder globs as real flows.
