# Governor preferences — the doctrine every worker reads

This is the operator's standing policy. Workers MUST follow it to auto-resolve decisions the
way the operator would, so they never block waiting for a human. It grows **slowly**: new rules
land here only when the operator marks an escalation answer "make this a rule" or the same
decision recurs ~2–3 times (see `escalations.md`).

> **Customize this file for your project.** The rules below are sensible defaults for a meta-repo
> with backend repos whose CI runs post-merge and frontend repos behind a billed preview. Edit the
> specifics (which repos auto-merge, what "the real test" means, what counts as a billable action)
> to match your stack. The auto-merge allowlist itself lives in `scripts/lib/workspace.sh`
> (`GOVERN_MERGE_REPOS`); this file is the *judgment* the worker applies.

## Completion & testing
- Prefer the option that **fully completes** a ticket over one that defers or splits it.
- **Validate locally before opening a PR.** Compile-clean + unit tests are NOT sufficient; run the
  real local loop end-to-end (`<pm> run dev -- --only ...`, drive the UI where the change is
  user-visible, watch logs) before claiming the fix works.
- If your project has a "real" environment to test against (e.g. a prod-like database), prefer it
  over a throwaway local one — but only if doing so is safe and non-destructive.
- If a test action costs money or creates real external resources, keep it **minimal** (one small
  action per ticket) and **always clean up afterward** (use the project's cleanup command / hook).

## Merging
- **Auto-merge** only the repos in `GOVERN_MERGE_REPOS` (workspace.sh), and only once CI is
  **green or has no PR-level checks** (a repo whose CI runs post-merge shows "no checks" → that is
  mergeable; red/pending block).
- **Never merge** the other (frontend / PR-only) repos — open the PR and stop; a human (or a
  different account) merges those. This also honors **merge-backend-first**: the consumer waits
  anyway.
- "Resolved" = **PR opened** (not merged). The governor — not the worker — performs the
  `tickets.md` / `CLAUDE.md` bookkeeping, in the main checkout.
- **Additive prod migration chain** (only if the project configures `GOVERN_MIGRATE_CMD`): merge →
  apply migration → verify → bookkeep. Order is safe because old running code ignores a new
  nullable/default column; the new code arrives after. Destructive migration → do NOT merge,
  escalate.

## Git & branching
- **Worktree-first** for any code change; the main checkout stays on `main` across every repo.
- Each sub-repo commits independently (`cd` into it first). The branch is `ticket-<N>` (the
  governor's worktree allocator names it).

## Hard-stops — ALWAYS escalate, never do autonomously
- **Destructive git:** force-push, history rewrite, `branch -D` on shared branches, hard resets
  that discard others' work.
- **Prod data / DESTRUCTIVE schema / secrets:** deleting or bulk-mutating prod rows; rotating or
  editing live secrets / `.env`; **destructive** migrations (DROP / rename / type-change /
  NOT-NULL-without-default / data-backfill). **Additive** migrations (ADD nullable-or-default
  column, ADD table/index) are NOT a hard-stop — classify them via the report's `migration` field
  and the governor handles them.

## Default rule
- **Anything this doctrine does not clearly cover → park the ticket and escalate.** Do not guess on
  a consequential or ambiguous choice. Fixing your *own* red CI (≤2 attempts) is NOT an escalation
  — that is part of completing the ticket.
