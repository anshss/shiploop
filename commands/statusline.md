---
description: Show the governor fleet in your Claude Code statusline. Explicit, opt-in, and chains — it never replaces an existing statusline.
allowed-tools: Bash, Read
---

# /shiploop:statusline

Adds a fleet segment to your Claude Code statusline:

```
⚙ 4/6 · #94 opus 22m
```

live workers · tickets answered this run · the oldest live worker (ticket, tier, elapsed). **Silent
when no fleet is running** — in a session with no governor run it prints nothing at all.

`$ARGUMENTS` selects the action: `install` (default) · `uninstall` · `status`.

## The one rule

**Never clobber an existing `statusLine.command`.** Plenty of people run ccusage, a git/model HUD, or
a hand-rolled script there. `statusLine.command` is a single string, so anything that just writes its
own value destroys theirs. The installer therefore *records the entire previous `statusLine` object
verbatim* into `~/.claude/shiploop-statusline.json` and *wraps* it: the wrapper reads stdin once,
replays it to the recorded original, and appends our segment after it. Uninstall writes the recorded
object back byte for byte (including removing the key entirely when there was none before).

You do not implement any of that. `scripts/govern/statusline-install.sh` owns every settings edit.

## Prerequisite

The segment reads `governor/events.jsonl`, which the governor only writes when **`GOVERN_EVENTS=1`**
(off by default). Say so if the operator has not set it — the statusline will otherwise be
permanently, correctly silent.

## What to do

1. **Locate the script.** From the workspace root: `scripts/govern/statusline-install.sh`. Prefer the
   workspace copy over any hub path — one installed copy serves every workspace, because the segment
   walks up from the session's `cwd` to find that workspace's event log.

2. **Run the action.**
   ```bash
   bash scripts/govern/statusline-install.sh status        # what is wired up right now
   bash scripts/govern/statusline-install.sh install       # record + wrap
   bash scripts/govern/statusline-install.sh uninstall     # restore verbatim
   ```
   Run `status` first on an install and **show the operator what is currently in
   `statusLine.command`** before wrapping it. If they already have something there, name it and
   confirm they want it wrapped rather than assuming.

3. **Report the outcome** — what was recorded, where, and the exact uninstall command. Mention that
   `refreshInterval` is set to 5s (their own value is preserved if they had one); without it the
   elapsed time visibly freezes while the session is idle.

## Refusals

- The installer refuses to re-record over an existing recording. That is correct: a second install
  would record shiploop's own wrapper as "the original" and make restore impossible. If it refuses,
  run `uninstall` first.
- It refuses to touch a `settings.json` that is not valid JSON. Do not "fix" their settings file to
  get past this — tell them.
- Never edit `settings.json` yourself, with `jq`, an editor, or otherwise. Every write goes through
  the script so the recording and the settings can never disagree.
