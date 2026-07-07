---
description: Inventory, inspect, and validate the user-facing flows your product exposes. `extract` fans out over the codebase to build the combinatorial list of paths a user might take that could break (staged for your approval, never auto-applied); `list` shows the registry grouped by proven / stale / untested / blocked; `file` queues governor validation tickets with a spend gate (resource-group batching, cheapest-first, --max-deploys, refuses billable batch runs without an orphan-sweep). The durable registry (validation/flows.md) always knows which paths are proven at HEAD, which went stale, which failed, and which measured ineffective.
allowed-tools: Bash, Read, Agent
---

# /shiploop:flows

> **Defer to the workspace-local copy.** If the current workspace has installed its own
> `.claude/commands/flows.md` (every scaffolded shiploop workspace does), follow THAT copy — it is
> pinned to the workspace's harness version and its `scripts/govern/flows-*.sh` helpers. This global
> copy is the fallback for a workspace that predates the flows feature; the playbook below is identical
> in shape, but always run the workspace's own `scripts/govern/flows-*.sh`, never a hub path.

Manage the **flow registry** (`validation/flows.md`) — the git-tracked inventory of user-reachable
paths through the product, each keyed by a stable id and pinned to the code SHAs it was last validated
at. `$ARGUMENTS` selects the subcommand: `extract` · `list` · `file <ids…|--all-stale|--all-untested>`.

**Load-bearing division of labor:** the model (you) orchestrates and *inventories*; **all registry
writes go through the `scripts/govern/flows-*.sh` scripts** (deterministic bash owns bookkeeping, under
the same lock as the governor). You never hand-edit `validation/flows.md`.

Run from the workspace root (main checkout or a worktree). First learn the layout:
`source scripts/lib/workspace.sh` (for `$REPOS`, `$GITHUB_ORG`).

---

## `extract` — inventory the flows (staged, operator-gated)

Build the combinatorial list of "paths a user might take that might break." **Fan out with `Agent`** —
one worker per surface, so no single context has to hold the whole codebase:

1. **Enumerate the surfaces to inventory.** Typically: every UI route/page, every API endpoint, every
   provider/integration matrix (a dimension that's *enumerable* — e.g. N providers × {deploy, feature-X,
   migration} — expands combinatorially into one flow id per cell), plus any snapshot/migration/backup
   paths. Use `$REPOS` to scope.
2. **Dispatch `Agent` workers** (general-purpose), one per surface, each returning a list of proposed
   flow blocks in the registry grammar (`## <id>` + `Kind` / `Surface` / `Paths` / `Status: UNTESTED`;
   `Gate` for an effectiveness flow). Ids are lowercase dot-kebab, coarse→fine (`deploy-gpu.vastai`).
   Derive `Paths:` from the real imports/dependencies, not just the obvious feature dir — first segment
   of every glob MUST be a sub-repo folder name.
3. **Collect the workers' blocks into ONE staged file**, e.g. `logs/investigations/flows-extract/staged.md`
   (gitignored scratch — not the registry).
4. **Vet gate — merge is staged and operator-approved.** Show the diff, then apply only on an explicit yes:
   ```bash
   scripts/govern/flows-extract-merge.sh logs/investigations/flows-extract/staged.md          # DRY: ADD / REFRESH / FLAGGED
   # …review the classification with the operator…
   scripts/govern/flows-extract-merge.sh logs/investigations/flows-extract/staged.md --approve # apply ADD + REFRESH
   ```
   The merge **only** adds new flows and refreshes `Paths`/`Surface` on existing ones. It **never**
   touches verdict state (`Status`/`Validated`/`Disposition`), and a `Kind` or `Gate` change on an
   existing id is **FLAGGED, never auto-applied** — a hallucinated or silently-reclassified flow must
   not become a fileable, later-billable row. Relay the flagged rows for a manual decision.

## `list` — the registry, grouped by status

```bash
scripts/govern/flows-list.sh            # read-only; annotates flows whose paths moved ("would go STALE")
scripts/govern/flows-list.sh --sweep    # first RECORD the STALE degrades (persisting sweep), then list
```
Grouped proven → measuring → untested → stale → failed → blocked → tombstoned. BLOCKED flows show their
named blocker; MEASURING flows show their gate/sample window. Use `--sweep` when you want the staleness
actually written to the registry (it commits + pushes via the same CAS path as bookkeep).

## `file` — queue validations (the spend gate)

Filing a flow queues a **real, often billable, deploy**, so this is deliberately conservative — it is
**DRY by default** and files nothing until you pass `--yes`.

```bash
scripts/govern/flows-file.sh deploy-gpu.vastai comfyui.vastai        # plan (dry) — resource-group batched
scripts/govern/flows-file.sh --all-untested --max-deploys 5          # plan the untested backlog, capped
scripts/govern/flows-file.sh deploy-gpu.vastai comfyui.vastai --yes  # actually file
```
- **Resource-group batching:** flows sharing a `Resource-group:` are filed as ONE ticket (comma-list
  `Flow:` field) — one worker, one deploy, N flows validated.
- **BLOCKED excluded; in-flight guard** skips a flow that already has an open `Flow:` ticket.
- **Capability gate:** a flow that `Requires:` a workspace capability whose knob is unset (`browser` →
  `WSP_BROWSER_CMD`, `analytics` → `WSP_ANALYTICS_QUERY_CMD`, `test-account` → `TEST_USER_EMAIL`,
  `deploy` → `GOVERN_DEPLOY_SWEEP_CMD`) can't be validated headlessly — `file` degrades it to BLOCKED
  with the named blocker and excludes it, rather than queuing a runnable-then-billable ticket.
- **`--all-*` preconditions:** batch filing refuses unless `GOVERN_DEPLOY_SWEEP_CMD` is wired (the
  post-worker orphan sweep is the safety net on the highest-spend path). Cheapest/fastest-provision
  flows are ordered first (so a truncated governor run maximizes coverage); slow-provision flows near
  `GOVERN_WORKER_TIMEOUT` are flagged.
- **Never auto-file on staleness** — staleness is advisory, filing is a human act (the `--yes`).

Review the dry plan with the operator, confirm, then re-run with `--yes`. The governor grinds the filed
tickets on its next pass and stamps each flow's verdict back into the registry.

## Kill path (an INEFFECTIVE flow the operator wants gone)

An INEFFECTIVE flow (measured worthless) is a **deletion candidate, not a fix candidate**. When a gated
validation parks gate-failed, the governor raises a disposition escalation whose options include
**`kill`**. Answer it `kill` (via `/resolve` / the escalation answer flow) and at the next run-start
`escalations-apply-answers.sh` marks the flow kill-pending and files a normal removal ticket; when that
ticket's PR opens, bookkeep **tombstones** the flow (history survives — a revived feature starts from its
record, re-extraction can't resurrect it as new). A pending kill whose flow goes STALE first is
auto-withdrawn by the sweep — a stale negative must not be acted on.

## Long-horizon, passive evidence & due advisories (surfaced, never auto-filed)

Effectiveness gates accrue over days; a worker lives minutes. The split is **arm → collect**: an *arm*
ticket verifies the experiment is running (flow → `MEASURING`); a later *collect* ticket reads the
accrued gate and stamps `EFFECTIVE`/`INEFFECTIVE`. The periodic governor supervisor surfaces, as
**advisory lines only** (never auto-filing — billable safety):

- a `MEASURING` flow whose `Sample-window: <N>d` has plausibly elapsed → file a collect run;
- a settled flow whose `Revalidate: every <N>d` policy is past due → re-file to refresh;
- where an analytics adapter (`WSP_ANALYTICS_QUERY_CMD`) is wired, a flow declaring `Usage-source:` with
  **0 real usage** → INEFFECTIVE-leaning passive evidence for the operator's kill decision.
