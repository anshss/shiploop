---
description: Triage a bug across all sub-repos before it becomes a ticket the governor ships. Seeds a notes file, pulls logs, forms a hypothesis, proposes a fix.
allowed-tools: Bash, Read, Edit, Grep, Glob
---

# /investigate

> **Workspace-local override:** if `.claude/commands/investigate.md` exists in this workspace, follow
> THAT file instead — it is the live, locally-improved copy; this global copy is the fallback for
> un-scaffolded workspaces.

Investigate a bug described in natural language: `/investigate <description>`

This is a GENERIC harness command. The mechanism (seed a notes file → collect evidence →
hypothesis → evidence → fix) is portable; the evidence-collection guts (log queries, live DB
state) are workspace-specific and live behind the `# workspace-specific` markers in
`scripts/investigate.sh`. Wire your own log/DB tools there once, then this command uses them.

## Playbook (follow in order)

1. **Seed the notes file.** Run:
   ```bash
   bash scripts/investigate.sh "$ARGUMENTS"
   ```
   Capture the path it prints. That is the working notes file for this investigation. It already
   contains the description and (if this workspace wired a log tool) the last 1h of errors.

2. **Read the notes file.** Review the auto-collected evidence.

3. **Identify likely affected sub-repo(s) and code paths.** From the description + evidence, decide
   which sub-repo(s) (see `scripts/lib/workspace.sh` `REPOS`) most likely contain the bug, and which
   user actions or background jobs are relevant.

4. **Pull targeted logs / state.** If this workspace has a log tool (e.g. `scripts/logs.sh`) or a DB
   probe, widen the search window or filter by service/user/id. Append findings to the notes file as
   you go — do NOT dump every query into the conversation context.
   ```bash
   # workspace-specific — examples only; adapt to your wired tools:
   # bash scripts/logs.sh --grep "<pattern>" --since <duration>
   ```

5. **Read source where the log trail points.** Use Read / Grep / Glob on the relevant sub-repo(s).

6. **Check live external/provider state if relevant** (API keys typically live in a sub-repo `.env`).

7. **Form a hypothesis.** Edit the notes file: replace `(filled in during investigation)` under
   `## Hypothesis` with a specific theory referencing exact files and line numbers.

8. **Gather evidence for and against.** Under `## Evidence`, list bullets — For / Against.

9. **Decide:**
   - **Confident:** propose the exact diff (file path + before/after). Don't apply without
     confirmation unless pre-authorized.
   - **Not confident:** report what's still unclear and what would resolve it.

10. **After the fix lands** (a later turn), append a `## Resolution` block: what changed, which
    sub-repo(s), and any follow-ups. File any newly-discovered gap as a ticket in `queue/tickets.md`.

## Anti-patterns

- Do NOT skip the notes file — it's the audit trail.
- Do NOT propose a fix without evidence written down for it.
- Do NOT batch every log query into the conversation context; write findings to the notes file.
- Do NOT make destructive changes (rm, git reset, drop table) without explicit confirmation.
