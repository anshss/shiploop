# Workspace learnings — cross-repo

Transient / evolving operational knowledge — true right now, not yet stable enough for `CLAUDE.md`
("X provider is flaky this week"). **Not** a work item (→ `queue/tickets.md`) and **not** a fixed-bug
writeup (→ promote the durable lesson, or delete it).

> The SessionStart digest covers **only this root `learnings.md`** — when working inside a sub-repo,
> open that sub-repo's own `learnings.md` yourself. (Nothing above the `---` rule below is ever
> injected: this preamble uses no `##` headings precisely so the digest can't mistake it for an entry.)

**Write observations, not recommendations.** An old observation is a historical fact and stays
readable forever. An old recommendation is a landmine: it tells a future session what to *do* from a
picture of the world that may have expired. Record what you saw, with what makes it checkable —
**date, source, and n** (how many runs, which repo, which version). "Provider X timed out on 4 of 9
dispatches on 2026-08-01 (run-42 logs)" ages into a fact. "Avoid provider X" ages into a wrong
instruction nobody can audit.

**Supersede in place; never append beside.** Two failures look identical from outside and only one of
them is age: *stale* (was true, is no longer) and *wrong at birth* (never was true). No expiry window
catches the second. So when you re-measure something, rewrite the existing entry with the new number
and a new date rather than adding a second entry next to it — two entries disagreeing is worse than
either alone, because the reader cannot tell which is current.

**When an entry stops being transient, route it by the cheapest rung that works:** make it impossible
(a guard) > make it caught (a lint or a test) > make it retrievable (`CLAUDE-APPENDIX.md`, the default
sink — costs nothing until opened) > make it always-on (`CLAUDE.md`). The always-on slot is charged to
**every** session on **every** turn, so its bar is **frequency × severity**, never frequency alone:
something that fires rarely still earns it when missing it fails *silently* or *irreversibly*. Fixed,
superseded, or now covered by a guard/lint/test → **delete it** — the mechanism is the record. Moving a
dead entry to the appendix does not retire it, it only hides it.

Entry format — the digest finds entries by this heading shape and injects the newest few:

```
### YYYY-MM-DD — short grep-able title

What you OBSERVED, with source and n. One or two lines. If a future session should act on it,
say what would have to still be true for that to hold.
```

Order doesn't matter (entries are date-sorted on read). Keep each heading immediately followed by its
own body — the digest slices the file at headings, so appending a new entry *between* a heading and
its body silently injects a garbled fragment into every session from then on.

---

_(empty — append dated entries as you discover things)_
