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

**SCOPE — corrected 2026-07-26 (read this before the entry below).** This result is about EXACTLY ONE
API: `PostToolUse` → `updatedToolOutput`. It was then over-generalised to "compression is unbuildable,"
which is FALSE. The "Consequence" paragraph below is superseded by this note. Two other delivery layers
were never tested at the time; both were then measured on CLI 2.1.220 under subscription/OAuth auth,
and **both work**:

1. **`PreToolUse` → `updatedInput` WORKS.** Bash: a hook rewrote `echo ORIGINAL_MARKER` →
   `echo REWRITTEN_MARKER_XYZ`; the `tool_use` event still logged the model's original command, but the
   executed command and the `tool_result` were the rewritten one. Read: a hook injected
   `offset:1, limit:5` into a Read of a 500-line file; the model asked for the whole file, received 5
   lines, and reported receiving 5. This is `rtk`'s actual mechanism — shape the output BEFORE it exists
   by rewriting the command — and it sidesteps the broken `PostToolUse` path entirely. **Caveat
   measured:** the model NOTICED the Bash substitution and commented on it unprompted, so a silent
   rewrite costs turns on the model investigating its own tooling; any rewrite needs a visible note.
2. **A pass-through proxy on `ANTHROPIC_BASE_URL` WORKS, and subscription auth survives it.** Not the
   `--bare` blocker (which forces `ANTHROPIC_API_KEY`): a local forwarder passes OAuth/keychain
   credentials through unchanged. The full assembled request is both visible and mutable.

**So the binding constraint is cache economics, not feasibility.** Cache reads bill ~0.1x, writes ~1.25x,
read:creation measured 33.3:1 — rewriting the prefix or any prior message invalidates from that point
forward and turns cheap reads into expensive writes, so raw-text reduction claims (`headroom`'s "~50%")
do not survive the conversion. **Design rule: compress only the TAIL** — a fresh `tool_result` on its
first transmission, with nothing downstream of it yet. That recovers exactly the broken `PostToolUse`
capability with no invalidation. Never rewrite history, and any compressor must be DETERMINISTIC or it
changes the prefix between turns and busts the cache every turn.

**Also corrected: "Claude Code never exposes the assembled prompt" is false at the proxy layer.** The
componentised split is a direct read — shipped as `scripts/govern/measure-prefix.sh`. Measured against a
REAL govern worker spawn (opus, CLI 2.1.220): of 164,795 turn-1 bytes, **tool schemas 85,260 (51.7%)**,
messages 71,981 (43.7%), system prompt 7,093 (4.3%). An earlier Haiku probe's 65.4%/17.1% figures did NOT
reproduce — do not quote them. Trimming the tool block via `--tools` (`GOVERN_WORKER_TOOLS`, opt-in) is
cache-safe because that block is static and deterministic: measured 164,795 → 107,985 bytes (−34.5%).

Measured, not read from docs. In headless `-p --output-format stream-json`, a `PostToolUse` hook **does
fire** and **does receive** the real `tool_response` on stdin — but returning
`{"hookSpecificOutput":{"hookEventName":"PostToolUse","updatedToolOutput":"…"}}` (valid JSON, exit 0)
has **zero effect**: the tool_result, the assistant's text, and the final `result` all still carry the
ORIGINAL output. Reproduced twice; sentinel string appeared 0 times, original 6 times. `--debug hooks`
emitted nothing. Also note `PostToolUse` hook execution is not surfaced as `hook_started`/`hook_response`
events in `-p` stream-json, so you cannot confirm it ran from the transcript alone — log a side-effect.

**Consequence — scoped narrowly on purpose (corrected 2026-07-26):** exactly ONE API is broken,
`PostToolUse` + `updatedToolOutput`, in `-p` mode. This entry previously ended "any compress/truncate/dedup
tool output via a hook design is unbuildable," which got read as *compression is impossible* and parked
three separate levers. It isn't, and two alternative layers were measured WORKING the same day (same
binary, same subscription/OAuth auth) — see #68:

- **`PreToolUse` → `updatedInput` WORKS in `-p`.** Bash: a hook rewrote `echo ORIGINAL_MARKER` →
  `echo REWRITTEN_MARKER_XYZ`; the `tool_use` event still logs the model's ORIGINAL command, but the
  executed command and the `tool_result` were the rewritten one. Read: injecting `offset:1, limit:5` into
  a Read of a 500-line file returned 5 lines and the model reported receiving 5. So output can be shaped
  BEFORE it exists by rewriting the call — no dependency on the broken API. Watch out: the model NOTICED
  the substitution and spent its reply commenting on it, so a rewrite must carry a visible marker or it
  buys confusion turns.
- **An API-layer proxy on `ANTHROPIC_BASE_URL` WORKS, and subscription auth survives it.** This is NOT the
  `--bare` blocker (which forces `ANTHROPIC_API_KEY`): a local pass-through forwards OAuth/keychain creds
  unchanged, verified `rc=0` end-to-end. The full assembled request is visible AND mutable — a tail
  injection moved the body 161,602 → 164,023 bytes and changed the model's reply. Corollary: the claim
  "Claude Code never exposes the assembled prompt" (v1.13.0 plan line 84) is FALSE at this layer, and the
  differential-ablation procedure built on it is unnecessary — read the componentised breakdown directly.

**Still genuinely untested: interactive mode** — and that is the layer that matters most, because the real
topology is an INTERACTIVE session in a shiploop repo spawning the headless workers. The interactive
orchestrator is the long-lived leg: it accumulates across a whole govern run and it is the only one that
ever compacts. Every measurement in this entry is `-p` only, so "unbuildable" was never established for
the layer where subagent returns actually pile up. Test `updatedToolOutput` interactively before parking
anything else on this entry. Re-test on CLI upgrades either way; the `--settings` + `--setting-sources user`
delivery path below is proven and works the moment the API is fixed.

**Do not re-split context-window pressure from token spend.** They are one resource. A window that fills
slower is less spend for the same work — compression that delays a compaction is a cost lever, not a UX
nicety, and compaction is worse than linear (you pay to summarise, then re-read the summary every turn
after).

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

