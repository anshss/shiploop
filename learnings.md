# Workspace learnings — cross-repo

Transient / evolving discoveries that don't belong in `CLAUDE.md` (too volatile) and don't belong in
a ticket (not a work item). Read at session start (the SessionStart hook prints the top of this file);
append at session end when something is worth carrying forward but hasn't yet stabilized into a
permanent pattern.

> The SessionStart hook auto-prints **only this root `learnings.md`** — when working inside a sub-repo,
> open that sub-repo's own `learnings.md` yourself.

Format: short, date-stamped, grep-able. When a learning stabilizes (still true after ~2 weeks /
several sessions), promote it into the appropriate `CLAUDE.md` and delete the entry here. **A fixed
bug is NOT a learning** — promote its durable lesson to `CLAUDE.md` or delete it; **work items go to
`tickets.md`**, never here.

---

### 2026-07-26 — `PostToolUse` → `updatedToolOutput` is a NO-OP in `claude -p` mode (CLI 2.1.220)

Measured, not read from docs. In headless `-p --output-format stream-json`, a `PostToolUse` hook **does
fire** and **does receive** the real `tool_response` on stdin — but returning
`{"hookSpecificOutput":{"hookEventName":"PostToolUse","updatedToolOutput":"…"}}` (valid JSON, exit 0)
has **zero effect**: the tool_result, the assistant's text, and the final `result` all still carry the
ORIGINAL output. Reproduced twice; sentinel string appeared 0 times, original 6 times. `--debug hooks`
emitted nothing. Also note `PostToolUse` hook execution is not surfaced as `hook_started`/`hook_response`
events in `-p` stream-json, so you cannot confirm it ran from the transcript alone — log a side-effect.

**Consequence:** any "compress/truncate/dedup tool output via a hook" design is unbuildable on this path
today. Only tested in `-p` mode — may work interactively. Re-test on CLI upgrades before assuming it's
still broken; the delivery path below is proven and would work the moment this is fixed.

### 2026-07-26 — `--settings` + `--setting-sources user` = clean hook isolation for workers

Verified working shape for giving a headless worker EXACTLY the hooks you choose, with zero project-hook
leakage (our spawn passes `--setting-sources "${GOVERN_SETTING_SOURCES:-user}"` on purpose, so workers
don't inherit the project's Stop/SessionStart hooks):

```
claude -p '…' --setting-sources user --settings /path/to/settings.json
```
```json
{ "hooks": { "PostToolUse": [ { "matcher": "Bash",
  "hooks": [ { "type": "command", "command": "<cmd or script path>" } ] } ] } }
```

Confirmed under its exact trigger condition that the project's `PreToolUse` hook
(`router-posture-guard.sh`) never ran and no `PreToolUse`/`UserPromptSubmit` events appeared. File form
tested; inline-JSON-string form untested. `--permission-mode acceptEdits` was needed to keep the run
non-interactive.

### 2026-07-26 — `--bare` is the biggest prefix lever and we CANNOT use it

`--bare` = "skip hooks, LSP, plugin sync, attribution, auto-memory, background prefetches, keychain
reads, and CLAUDE.md auto-discovery", with explicit opt-in via `--system-prompt[-file]`,
`--append-system-prompt[-file]`, `--add-dir`, `--mcp-config`, `--settings`, `--agents`, `--plugin-dir`.

**Blocked for this fleet:** *"Anthropic auth is strictly `ANTHROPIC_API_KEY` or `apiKeyHelper` via
`--settings` (OAuth and keychain are never read)."* On a Max subscription that either fails to
authenticate or forces API billing, which inverts the subscription economics shiploop depends on. It
also skips hooks, so it is mutually exclusive with any hook-based mechanism.
`--exclude-dynamic-system-prompt-sections` is the auth-compatible subset and is what we ship.

### 2026-07-26 — `--max-turns` is NOT in the installed binary (2.1.220)

Documented in the CLI reference, absent from `claude --help`. Confirm against the actual binary before
designing anything around it. `--max-budget-usd` IS present (`--print` only).

### 2026-07-26 — an unknown CLI flag is INVISIBLE in govern's failure classification

`claude -p x --bogus-flag >"$jsonl" 2>&1` → exit 1, 53-byte file, single plain-text line
`error: unknown option '--bogus-flag'`. Not JSON, no `"type":"result"`, rc=1 so `worker_killed` is
false, and it matches neither `infra_error_signature` nor `interrupted_error_signature` — so it becomes
a generic synthesized `failed` report. A fleet-wide CLI-incompatibility outage would therefore look like
N ordinary ticket failures. Tracked as #56. **Corollary for hub templates: never ship a NEW `claude`
flag without a capability probe** — the fleet's CLI version is not yours.

