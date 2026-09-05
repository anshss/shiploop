# Governor preferences — the doctrine every worker reads

Operator's standing policy — auto-resolve decisions the way the operator would; never block waiting
for a human. Grows only via an escalation answer marked "make this a rule" or a ~2-3x recurring
decision (`escalations.md`).

> Defaults assume backend repos with post-merge CI, frontend repos behind a billed preview — edit to
> match your stack. Auto-merge allowlist: `scripts/lib/workspace.sh` (`GOVERN_MERGE_REPOS`); this file
> is the judgment applied around it.

## Completion & testing
- Fully complete a ticket over deferring/splitting it.
- Validate locally before opening a PR — compile-clean + unit tests are NOT sufficient. Run the real
  local loop end-to-end (`<pm> run dev -- --only ...`, drive the UI, watch logs).
- Prefer a "real" test env (e.g. prod-like DB) over throwaway local, only if safe/non-destructive.
- Billable/real-resource test action → minimal (one small action per ticket), always clean up after
  (project's cleanup command/hook).

## Merging
- Auto-merge only repos in `GOVERN_MERGE_REPOS`, only once CI is green or has no PR-level checks
  (post-merge-CI repo shows "no checks" = mergeable; red/pending block).
- Never merge other (frontend/PR-only) repos — open PR and stop; a human/different account merges.
  Honors merge-backend-first (the consumer waits anyway).
- "Resolved" = PR opened, not merged. Governor (not worker) does `tickets.md`/`CLAUDE.md` bookkeeping
  in the main checkout.
- Additive prod migration chain (only if `GOVERN_MIGRATE_CMD` set): merge → apply → verify → bookkeep.
  Safe because old code ignores a new nullable/default column. Destructive migration → do NOT merge,
  escalate.

## Git & branching
- Worktree-first for any code change; main checkout stays on `main` across every repo.
- Each sub-repo commits independently (`cd` in first). Branch = `ticket-<N>` (worktree allocator names it).

## Hard-stops — ALWAYS escalate, never act autonomously
- Destructive git: force-push, history rewrite, `branch -D` on shared branches, hard resets that
  discard others' work.
- Prod data / destructive schema / secrets: deleting/bulk-mutating prod rows; rotating/editing live
  secrets/`.env`; destructive migrations (DROP / rename / type-change / NOT-NULL-without-default /
  data-backfill). Additive migrations (ADD nullable-or-default column, ADD table/index) are NOT a
  hard-stop — classify via the report's `migration` field; governor handles them.

## Closing & escalation judgment
- Closeable umbrella → CLOSE, don't park. If the core deliverable is merged + verified and every
  residual is already its own child ticket, close it (note "resolved — core shipped + verified;
  residuals tracked as #a/#b/…") rather than park-and-escalate. See `decisions-log.md` for the
  operator decisions this generalizes.
- Respect an embedded operator deferral: a dated DECISION in the ticket body deferring remaining work
  (with the reactive mitigation already shipped) stays parked/closed-as-mitigated per that deferral.
  Don't autonomously re-attempt before its stated condition is met, even if technically feasible —
  especially when the only remaining path is a hard-stop (live prod infra/secrets).
- Meta-repo file fixes are a delivery, not a park. When the deliverable is meta-repo/coordination
  files (root `scripts/*`, root `*.md` beyond an append-only `lessonPatch`, `package.json`,
  `.claude/*`, `governor/*`, `.githooks/*`) rather than a sub-repo, commit on the meta checkout with
  a pathspec-scoped `git commit -- <paths>`, never a bare `git commit` (it sweeps a co-tenant's
  staged index). If the meta-repo has no `origin` (or `GOVERN_NO_PUSH=1`) there is no PR channel:
  the local `main` commit IS the delivery, so report `status:"resolved"` with `pr: null` and
  `repo:"harness"`. With a remote, the governor's `ticket-<N>` PR lane applies instead
  (`.githooks/pre-push`). Park a meta-repo ticket only for a real hard-stop, never merely because it
  touches `scripts/`.

## Default rule
Anything not clearly covered → park and escalate. Don't guess on a consequential/ambiguous choice.
Fixing your OWN red CI (≤2 attempts) is completing the ticket, not an escalation.
