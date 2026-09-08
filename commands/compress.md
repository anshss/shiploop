---
description: Compress this workspace's CLAUDE.md by moving mechanically-triggered rules into just-in-time rule packs. Operator-triggered, never automatic.
allowed-tools: Bash, Read, Edit, Write, Agent
---

# /shiploop:compress

> **The ONLY thing that compresses `CLAUDE.md`.** Nothing automatic ever edits that file. The run-end
> pass detects and reports only (`trim: CLAUDE.md <size>/<budget> chars, <N> compression candidate(s)
> - run /shiploop:compress`), and `scripts/govern/claudemd-trim.sh --apply <hash>` moves one
> pre-approved block. Everything else happens here, with an operator watching.

`CLAUDE.md` is re-sent to the model in full on every turn, so a rule that only matters while editing a
shell script is charged to every session that never opens one. This command reduces that per-turn tax
**without deleting a single rule**.

**The lever is delivery, not prose.** On the workspace this method came from, a wording-only pass over
the whole file bought 759 chars (2.9%) because the file was already at its hand-compressed floor. The
same file then dropped 26,511 -> 18,830 chars (-29%) with no rule removed, purely by moving
mechanically-triggered rules into `scripts/rules-on-touch.sh`. Do not open this command by rewriting
sentences.

**Sort by DETECTABILITY, never by frequency.** Frequency was tested as a sort key and rejected: a rule
that fires rarely but prevents a destroyed box is high value *precisely because* nobody recalls it,
which argues for just-in-time delivery, not against it. The only question that decides a block is
whether its trigger is mechanically detectable from a tool call.

---

## Step 1 - Measure composition per section

Do not skip this. It is what proves where the mass actually is, and it usually contradicts the guess.

```bash
awk '/^## /{if(h)printf "%6d  %s\n",n,h; h=$0; n=0} {n+=length($0)+1} END{if(h)printf "%6d  %s\n",n,h}' CLAUDE.md | sort -rn
wc -c CLAUDE.md
```

Report the table to the operator before touching anything.

## Step 2 - Read the candidates the automatic pass already found

`governor/claudemd-trim-proposals.md`. Each proposal carries a `Class:` field:

| Class | Meaning |
|---|---|
| `dead-citation` | every path or knob it cites is provably gone |
| `duplicate` | an exact duplicate of another block |
| `jit-candidate` | mechanically detectable trigger: it can become a rule pack |
| `judgment` | judgment-call trigger: **never a candidate**, it stays resident |

A `judgment`-class block is never a candidate. Do not re-litigate that classification here.

## Step 3 - Classify EVERY block into exactly one bucket

Not just the proposed ones: every block in the file.

1. **Automatic already** - a hook or a guard already enforces it and the resident prose merely
   restates it. This is the strongest cut: the rule is not moving, it is already mechanical.
2. **Mechanically detectable trigger** - can become a pack in `scripts/rules-on-touch.sh`, keyed off
   something readable from the tool call itself (a `*.sh` path, a `git` command, `gh pr`, a `VERSION`
   write, a path under `scripts/govern/`).
3. **Pure judgment, no trigger** - **STAYS RESIDENT.** Name every one of these explicitly in your
   report so the operator sees what was deliberately kept, not what was overlooked. A judgment rule
   left in `CLAUDE.md` is a decision, not an omission.

## Step 4 - Safety-net audit, BEFORE cutting anything

For each candidate, grep the hook text AND `CLAUDE-APPENDIX.md` and confirm the full text exists
somewhere recoverable:

```bash
grep -n "<distinctive token>" scripts/rules-on-touch.sh CLAUDE-APPENDIX.md
```

If a rule has no long form anywhere, **write the long form first, in its own commit, then cut.**
Never cut a rule whose only copy is the one being cut.

## Step 5 - Move the text VERBATIM

Copy the imperative into the pack unchanged. Never paraphrase on the way out: a paraphrase is an
uncontrolled edit to a rule, made by whoever happened to run the compression, and it will not be
reviewed as one. The long form belongs in `CLAUDE-APPENDIX.md`; the pack carries the imperative.

Each new pack needs both directions tested in `templates/hooks/test-rules-on-touch.sh`: it fires on
its trigger, AND it stays silent on a near-miss. An over-broad suppression turns a false positive into
a silently missing rule, which is worse than the noise.

A rule that is specific to THIS workspace does not belong in the template. Put it in
`scripts/rules-on-touch.local.sh` (`rules_local_triggers` + `rules_local_pack_text`), which the hook
sources if present and `/shiploop:update` never overwrites.

## Step 6 - Leave the one-line pack index in `CLAUDE.md`

Load-bearing. Without it, a session on a turn where no pack fires does not know the rules exist:

> **N rule packs are delivered JUST-IN-TIME by `scripts/rules-on-touch.sh` (PreToolUse), not resident
> here**: `shell` · `worklist` · ... They fire when you touch that surface, in workers too (a delegate
> never loads this file). Assume they exist; read the script if you need one early.

The pack test asserts this line names every pack, so a pack added without an index entry fails CI.

"in workers too" is the part that matters: a subagent editing a sub-repo never loads the root
`CLAUDE.md`, so just-in-time delivery is worth MORE in a delegate than in the driver.

## Step 7 - Coverage audit, and do not commit without it

For each removed rule, pick a distinctive token and grep the hook, the appendix, and the remaining
core. Print `OK` or `LOST` per rule and require a final `ALL COVERED` line:

```bash
lost=0
while IFS= read -r tok; do
  if grep -qF "$tok" scripts/rules-on-touch.sh CLAUDE-APPENDIX.md CLAUDE.md 2>/dev/null; then
    printf 'OK   - %s\n' "$tok"
  else
    printf 'LOST - %s\n' "$tok"; lost=1
  fi
done < /tmp/removed-tokens.txt
[ "$lost" -eq 0 ] && echo "ALL COVERED"
```

No `ALL COVERED` line means no commit.

## Step 8 - Run the hook against real recent traffic

Replay actual recent tool calls through `scripts/rules-on-touch.sh` before shipping. All three known
false-positive defenses were found this way and only this way:

- Five packs fired on one call and buried the one that mattered -> a per-call cap of 2, and a pack the
  cap skips is NOT stamped as delivered, so it still fires later.
- `grep -n P1001 notes.md` false-fired an action pack -> a leading search or read command (`grep`,
  `rg`, `cat`, `sed`, `awk`, `head`, `tail`, `ls`, `find`, `jq` and friends, after leading `VAR=x`
  assignments are stripped) never triggers an action pack. `grep -r` is exempt from that exemption,
  because a recursive sweep IS a governed action, but it feeds only packs keyed on searching: a sweep
  whose PATTERN is `gh pr` must not fire the pr pack.
- A heredoc body mentioning a command false-fired its pack -> truncate the command probe at the first
  `<<`, because a heredoc body is data, not command text.

Then run the pack test suite in the FOREGROUND and report real counts. The suite is hub-only (it is
not installed into a workspace), so run it from your hub checkout:

```bash
bash "$HUB/templates/hooks/test-rules-on-touch.sh" 2>&1 | tail -20
```

## Step 9 - Show the diff, get an explicit go/no-go

Print the diff and the before/after char counts, and **wait for the operator to say go.** State both
counts in the commit message.

## Step 10 - State the floor honestly

Some mass is irreducible: commands, paths, routing facts, the sub-repo table. And judgment rules stay
resident **by design, not by omission**. Report the floor as a number, and do not promise a second
pass will find another 29% when the remaining mass is the floor.
