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

### 2026-07-26 — reading token usage out of `stream-json`: three traps that silently corrupt the numbers

Hit all three while measuring the fleet. Anything that analyses `logs/govern/**/worker*.jsonl` (the #45
benchmark especially) must handle them or it will report confidently wrong figures.

1. **Every real API turn is logged as 1–3 duplicate `"type":"assistant"` lines** — one per content block
   (thinking / tool_use / text) — each carrying the *identical, non-incremental* usage snapshot. Summing
   raw lines inflates context totals ~1.7x. **Dedupe by `message.id` first.**
2. **`usage.output_tokens` on `assistant` events is NOT a per-turn total.** Even after correct dedup it
   came out **38x low** (1,313 vs 49,908 authoritative) on a verified session — while the same dedup
   reproduced `input_tokens`/`cache_read`/`cache_creation` EXACTLY. Read output tokens and cost only from
   the terminal `{"type":"result",...}` event (`result.usage.output_tokens`, `result.total_cost_usd`).
   This one error made a first pass report median session output as 81 tokens; the truth is ~17,448.
3. **Fixture stubs are indistinguishable by shape alone.** Test fake-`claude` stubs emit round-number
   usage (`input:100, output:50, cache_*:0`) and pass a naive "has an assistant turn" filter. **Filter on
   a genuine `msg_...` `message.id`** — stubs have none. Of 262 files in the tree, only **35** are real
   sessions (see #57).

Also: a prefix's true cost share is `Σ(prefix_i × turns_i) / Σ(session_total_i)` — it is RE-READ every
turn. Measuring turn-1 `cache_creation` alone counts only the one-time cache write and understates it by
~100x (0.23% vs the real **23.4%**). Caveat: `prefix_i × turns_i` assumes every turn re-reads the full
prefix, which breaks on short/compacted sessions (one 6-turn session computes to a nonsensical 142.9%) —
trust the aggregate, not per-session ratios.

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

