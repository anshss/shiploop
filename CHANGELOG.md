# Changelog

## 1.17.1 — 2026-08-03

### Fixed

- **v1.17.0's new knobs never reached any workspace.** They were registered in `config-check.sh` —
  which only *reports* what is set — but not in `templates/lib/workspace.sh`, which is the file
  `/shiploop:update` actually distributes. `workspace-sh-merge` appends knobs the hub template
  declares; the hub declared none of them, so it had nothing to append. Every fleet that updated to
  v1.17.0 got the five new scripts and **no way to discover a single lever they expose**.

  The sharp edge was `GOVERN_WORKER_ESCALATION_MODEL`. Undeclared, it fell back to the script default
  `opus` — while `templates/lib/workspace.sh` still pinned `GOVERN_WORKER_MODEL=opus` from before the
  split. Floor and ceiling both resolved to opus, which **re-collapses the two knobs v1.17.0 exists to
  separate and makes escalation a same-tier re-bet.** That is precisely the failure the split was
  built to prevent, shipped by the release that built it. It hit new scaffolds too, not just
  upgrades, because the template carried the pin.

  Now declared with their rationale: the floor (`sonnet`) and ceiling (`opus`) as an explicitly-paired
  comment block that says keeping them different is the point, plus `GOVERN_DETERMINISTIC`,
  `GOVERN_STALENESS_GATE`, `GOVERN_STALENESS_RUN_TESTS`, `GOVERN_EARLY_ABORT`, `GOVERN_INDEX`,
  `GOVERN_VERIFY_FILTER`, `GOVERN_RUN_MAX_TOKENS`, `GOVERN_SELFREF_MAX_PER_RUN` and
  `GOVERN_PRODUCT_FIRST`. Every default is unchanged, so this alters no behaviour on its own.

  **Existing fleets need one manual edit.** `workspace-sh-merge` is append-only by design
  (`scaffold.sh:727` skips any variable already present), so an upgrading workspace that already pins
  `GOVERN_WORKER_MODEL` keeps its own value — `/shiploop:update` will append the new ceiling but
  cannot lower your floor. If yours reads `opus`, change it to `sonnet` yourself or you are still
  running floor == ceiling. Fresh scaffolds get the correct pair with no action.

## 1.17.0 — 2026-08-03

The cost of a run is `Σ(bytes × turns_remaining) × tier_price`. Only the tier is a number you can set;
the rest is growth rate. This release reprices the tier, removes work that never needed a model, and
puts a ceiling on the one file that was allowed to grow forever.

All measurements below are first-party, taken 2026-08-03 from `governor/ticket-history.jsonl`, the five
cached `scout.json` verdicts, and 12 real `worker.jsonl` transcripts (2,617 assistant turns).

### Removed

- **The `/govern` and `/shiploop:govern` commands are gone. The loop is not.** Dispatch is now plain
  language onto the same substrate — `"work on 42 51 63"`, `"work on all the tickets on queue"`,
  `"work through the queue while I'm out"`. These differ only in selection and count, so a later
  session still reaps workers an earlier one launched. Detached workers, claim locks, verdict files,
  resumable worktrees and reaping — the only things that survive a closed laptop — are untouched. The
  command's doctrine moved into `SKILL.md`; the retired workspace-local twin is listed in
  `templates/lib/purge.txt`, so `/shiploop:update` removes it from existing fleets.

  Lowering trigger friction *raises* the need for a ceiling: a slash command was a deliberate act, a
  sentence is not. See `GOVERN_RUN_MAX_TOKENS` below.

- **The scout no longer decides a tier.** `scout::score()`, the HARD gate, the scoring table, and the
  `--verdict` / `--score` modes are deleted. Its gate was a disjunction, so one disqualifier won
  outright and `testsCover==false` alone forced opus — a rubber stamp, not arbitrage. **4 of the 5
  verdicts it ever cached were `opus/high`.** Three tickets it sized `opus` were run at sonnet and
  resolved on attempt 1 for $1.34–$2.95; the one actually dispatched at opus cost **$20.18**.

  The scout stays, as a **surveyor**: it still greps real code and now emits verified `targetPaths`
  (`--paths`) plus a `deterministic` patch field (`--deterministic`). Net less code.

### Changed

- **Tier floor split from escalation ceiling — sonnet-first.** `GOVERN_WORKER_MODEL` is now `sonnet`
  (the first-attempt floor) and the new `GOVERN_WORKER_ESCALATION_MODEL` is `opus` (the retry
  ceiling). These were one variable, so lowering it alone would have silently made a failed sonnet
  attempt "escalate" to sonnet — disabling the rail that makes sonnet-first safe.

  Measured cost per ticket: opus **$8.94** · sonnet **$2.22** · haiku **$0.59**. Failures are also
  cheap relative to successes (2.28M tokens vs 11.25M) because a worker out of its depth dies early —
  so a wrong cheap bet costs far less than a right expensive one. Absence of evidence now routes
  **down**; escalation is the only way up. `GOVERN_SYNC_PORTER_MODEL` is pinned to `opus` rather than
  inheriting the worker floor.

- **Escalation now provably fires at most once per ticket.** It previously held only by accident: the
  cap was on consecutive *runs*, not on escalations, and nothing recorded "already escalated".
  `GOVERN_RESOLVE_CONFLICT` could buy the ceiling tier a second time inside one run under a single
  failure count. It is now pinned to class `ci` (tier unchanged, as `GOVERN_FIX_CI` already was), and
  a `.governor-escalated` stamp lives in the preserved worktree — the same artifact whose existence is
  the retry signal, so the two cannot rot apart. Kill switch `GOVERN_ESCALATE_ONCE=0`.

- **Batching re-keyed onto measured file overlap.** `govern::ticket_locality` is replaced by
  `govern::ticket_paths` + `govern::paths_overlap`. The old key parsed the `Where:` **prose** line for
  a leaf directory name — prose written before anything was measured, the same failure that retired
  the `Model:`/`Effort:` fields — and leaf names collapse a backlog into a couple of buckets, making
  grouping arbitrary. Arbitrary grouping is the losing side of the trade: no discovery shared, full
  accumulation paid, and accumulation is superlinear. Now a candidate joins a group only if it shares
  an **exact file path** with the group's seed, and **no measurement means no batch**. Only with that
  fixed did `GOVERN_BATCH_MAX` rise from `1` to `2`; raising the cap first would have made it worse.

- **The worker prompt is 34.3% smaller — 22,819 → 14,988 bytes.** It is injected on every turn of a
  218-turn session, so a byte here is paid ~218 times. It had never been compressed because three
  tests pinned its exact prose; those now assert structure and machine contract (marker counts, JSON
  keys their consumers actually read) instead, so the lever stays unlocked rather than re-breaking on
  the next pass. The rendered per-turn prompt for an ordinary ticket falls 14,779 → 11,042 bytes.

### Added

- **Zero-model resolution (`deterministic-apply.sh`).** The largest arbitrage is not opus→sonnet (~5×)
  but **model → no model**, which is unbounded. When the scout can name a fully mechanical change —
  flip a default, add a key, bump a version, delete a stale line, apply a known rename — the patch
  applies, the suite runs, the PR opens, and no worker is spawned. It rides on the scout's existing
  call and adds no model call of its own. Aggressively conservative: any ambiguity falls through to a
  normal worker. Reports carry `"zeroModel": true`. `GOVERN_DETERMINISTIC=1` to enable.

- **A persistent, deterministic codebase index (`codebase-index.sh`).** file→symbols, test→files
  covered, module→dependents, built from git/grep/ctags and rebuilt after each resolved ticket.
  Exploration is the dominant cost of a resolved ticket and every worker paid it cold: `Read` is 7.7%
  of a worker's tool calls but **31% of returned bytes, at 6,145 B/call**. Never model-generated — that
  would be a recurring bill *and* would rot.

- **A staleness gate (`staleness-gate.sh`).** The queue is partly machine-generated, so it accumulates
  duplicates and already-fixed entries; discovering that cost a **full worker**. Bash only, fail-open —
  only positive evidence (every named path gone, or the named failing test now passing) skips a ticket.
  `GOVERN_STALENESS_GATE=1`. Executing a test command read out of the queue is a **separate** opt-in
  (`GOVERN_STALENESS_RUN_TESTS=1`), because the queue is machine-written and a stat() is not a `bash -c`.

- **Early abort + warm escalation.** A doomed worker burned nearly its whole budget before failing. A
  third watchdog reads the live JSONL for deterministic pathologies — no file edits in N turns, the
  same command repeated M times, a rising tool-error rate — and kills at ~turn 30 instead of 218.
  Because retries are **cold** (no `--resume`; a retry is a fresh `-p` in the preserved worktree), the
  dying worker now writes a structured *ruled out / stopped at / would try next* handoff block that the
  escalated attempt starts from. `GOVERN_EARLY_ABORT=1`.

- **Verification output filtered to failures (`verify-filter.sh`).** `Bash` returns 64.6% of a worker's
  tool bytes and a worker is an edit→test→edit loop; a passing run's output carries near-zero
  information and is re-read every later turn. A green suite becomes one line; failures print in full;
  the exit code passes through. This *prevents* bytes entering rather than truncating them after —
  capping tool results was explicitly rejected, since the size distribution has no upper tail (a 100 KB
  cap saves 0.0%).

- **The failing CI log is handed to the CI-fix retry (`ci-log.sh`).** Workers verify on macOS while CI
  runs Linux. `GOVERN_FIX_CI` was read in exactly one place — to pin the retry class — so the
  redispatched worker got a byte-identical prompt and rediscovered the failure at full price with the
  answer sitting in a log file. `gh` only, fail-open, bounded excerpt.

- **Allocation gates.** `GOVERN_SELFREF_MAX_PER_RUN` caps how many harness-about-harness tickets one
  run may dispatch, and `GOVERN_PRODUCT_FIRST=1` sorts product work ahead of it. The loop files
  tickets about itself, pays full worker price, and files more; `CLAUDE.md` stated the principle —
  *gate dispatch cost, never discovery* — but nothing enforced it. Discovery, filing and triage are
  untouched; only dispatch is capped.

- **A run-level spend ceiling.** `GOVERN_RUN_MAX_TOKENS` stops a run cleanly before dispatching another
  ticket. The governor had per-attempt telemetry and per-attempt bounds but no brake on the run.

- **The context ratchet has a ceiling (§6).** Promotion into always-on context was automatic; removal
  required a human noticing. There was no admission test, no eviction, and no expiry. Now:
  `CLAUDE-APPENDIX.md` is the **default** sink and the always-on slot is opt-in
  (`GOVERN_LESSON_SINK=appendix`); claiming it requires an explicit frequency **and** reversibility
  argument, because the bar is frequency × severity, never frequency alone; at budget a promotion must
  **name the entry it displaces** (`GOVERN_LESSON_EVICT=1`), which turns *"is this useful?"* (always
  yes → ratchet) into *"is this more useful than the weakest incumbent?"* (a comparison → steady
  state); and a ladder check prefers make-it-impossible > make-it-caught > make-it-retrievable >
  make-it-always-on.

  In `learnings-digest.sh`, entries past `SHIPLOOP_LEARNINGS_TTL_DAYS` (14) degrade to a **title-only**
  line rather than being deleted — deleting a still-true measurement just makes a future session
  re-derive it. A structure lint (`SHIPLOOP_LEARNINGS_LINT=1`) reports a heading with no body or a body
  with no heading, and is silent when healthy: a real orphaned heading had been injected at every
  SessionStart, unnoticed, since it was created.

### Notes

- Every new mechanism is **deterministic** — the whole release adds no new `claude` invocation to any
  path. `deterministic-apply.sh` rides on a field added to the scout's existing call.
- Every new knob defaults to today's behaviour, so upgrading changes nothing until each is enabled
  deliberately. The two exceptions are stated above and are the point of the release: the worker tier
  floor (`opus` → `sonnet`, with the escalation rail behind it) and `GOVERN_BATCH_MAX` (`1` → `2`,
  gated by measured overlap).
- This release also carries **v1.16.0's relicense from MIT to Apache 2.0**, which was committed but
  never tagged or published. See the 1.16.0 entry below for its terms; releases up to and including
  v1.15.1 remain under MIT.

## 1.16.0 — 2026-08-03

### Changed

- **Relicensed from MIT to the Apache License 2.0.** The project is still permissively licensed and
  commercial use is still permitted — Apache 2.0 grants the same freedoms MIT did. What it adds is an
  express patent grant (§3, with reciprocal termination if a user sues a contributor for patent
  infringement over the work), a trademark reservation (§6, so a fork cannot keep calling itself
  shiploop), a requirement that modified files carry a change notice (§4b), and NOTICE-file
  propagation into derivatives (§4d). A `NOTICE` file now ships alongside `LICENSE`.

  MIT left the patent question unanswered — an implied license is arguable but untested — and its only
  condition was retaining the copyright line. For a plugin distributed through a marketplace, where
  fork-and-rebrand is the realistic failure mode, the attribution and trademark terms are the practical
  gain; the patent grant is the legal one. The one real cost is GPLv2 incompatibility: Apache's patent
  and indemnity terms count as additional restrictions under GPLv2, so shiploop can no longer be
  combined into a GPLv2-only project. Nothing here links against GPLv2 code.

  **Releases up to and including v1.15.1 remain under MIT** and stay available under those terms —
  relicensing binds future releases only. Sole authorship meant no contributor consent was required.

## 1.15.1 — 2026-08-03

### Fixed

- **`/shiploop:update` now converges an existing workspace's CONFIG, not just its mechanism scripts.**
  The bump loop only ever touched the six byte-comparable components, so anything the hub shipped
  outside them reached brand-new installs only. Measured across five installed workspaces (stamped
  1.2.1 → 1.14.0 against hub 1.15.0): every one was missing at least one npm entrypoint, and a full
  successful `/update` left them missing — `govern:validations` had been unreachable since it shipped.

  New merge-tier components, all additive and idempotent (a second run is a byte-level no-op):
  `package-json-merge` adds absent harness scripts without overwriting, removing, or reordering the
  operator's; `workspace-sh-merge` appends `GOVERN_*` knobs added since the workspace was scaffolded,
  each with its doc comment, never touching an existing value (this is what made `GOVERN_PARALLEL_DEFAULT`
  unreachable, so upgrading fleets silently kept running serial); `settings-merge` now also **repairs**
  a harness hook whose command or timeout drifted from canonical, where before marker-presence alone
  counted as "installed" and a stale invocation ran forever. `readme` and `gitignore` joined the loop,
  and both now read the real PM + sub-repo list out of `workspace.sh` instead of rendering defaults.
  `--component config-merge` runs the set; `--diff-only` reports config drift without counting it as
  drift (a customized file is a permanent, correct difference and must not gate the version stamp).

- **Seed improvements reach workspaces that never edited the seed.** `component_seeds` was
  fill-if-absent, so the 1.14.0 `CLAUDE.md` trim benefited new installs only. It now upgrades a seed
  whose sha256 appears in the new `templates/lib/seed-hashes.txt` — proof the file was never touched,
  which is the only condition under which replacing it is lossless. Anything else is left untouched and
  silent: byte-identity is the entire safety argument, with no diff, merge, or heuristic. One live
  workspace's `CLAUDE.md` had grown to 47 KB of promoted lessons; overwriting that to save bytes would
  be catastrophic, and the guard is what prevents it.

- **`doctor.sh` names the command that fixes staleness.** The BEHIND warning pointed at
  `bash $HUB/scaffold.sh --workspace-dir . --component <name>` — an unresolved variable and a literal
  `<name>` to guess. It now says `/shiploop:update`.

### Added

- `tools/check-manifests.sh` + CI job `check-manifests` — fails a PR that deletes a template without
  registering its installed path in `purge.txt` (the channel that makes deletions propagate), or that
  changes a seed without regenerating `seed-hashes.txt`.
- `tools/gen-seed-hashes.sh` — regenerates the seed hash manifest from git history.
- CI job `hub-context-tests`. Five update-channel tests resolve the hub as `$DIR/../../..` and exit 77
  when that is not a hub checkout — which is exactly what `scaffold-and-test` gives them, so all five
  had been skipping in CI and the machinery behind `/update` was ungated while appearing gated. They
  now run from the checkout, and a skip there is a hard failure.
- `templates/govern/test/test-update-config-converge.sh` — 30 assertions over the merge tier, including
  the critical safety case that a seed with one byte of local content is never modified.

## 1.15.0 — 2026-08-03

### Removed

- **The install footprint drops 62% of its files (234 → 88) and 46% of its bytes, and an old install
  now sheds the difference instead of carrying it forever.** Four groups came out, each traced from
  1,372 real sessions (277 in one fleet, 174 in another) and then confirmed by a dependency trace
  against every file that stays — usage data found the candidates, the trace is what justified the
  cut.

  **The cross-repo git wrappers** — `status.sh`, `branch.sh`, `switch.sh`, `pull-all.sh`,
  `push-prs.sh`, `health.sh`, `investigate.sh` — and their `npm run` aliases. Across 54,690 parsed
  bash sub-statements, not one shiploop wrapper reached the top 25. Agents ran the underlying command
  instead: `git status` ×419, `git push` ×285, `git pull --ff-only` ×59, `git checkout` ×43,
  `git switch -c` ×30, `curl localhost` ×60. A wrapper that has to be remembered loses to a command
  that doesn't.

  **`/investigate` and `/resolve`** (both the hub commands and their project-local copies) — 0
  invocations across both fleets, by typed tag or Skill tool. The work `/resolve` describes still
  happens constantly (67 direct `tickets.md` edits, 81 `govern-bookkeep.sh` calls), so the close-out
  discipline moved into `SKILL.md` and the seed `tickets.md` as prose. Cutting the command does not
  cut the capability, and it removes two always-on description lines from every session.

  **The govern test suite is hub-only now** (134 files, ~869 KB — the single biggest item). Nothing in
  a fleet workspace ever ran it: no npm script, no hook, no command, no govern script. `sync-port.sh`
  already builds its own scratch copy straight from the hub tree, and hub CI now copies the suite into
  the throwaway workspace it scaffolds. Two of the tests (`test-wrap-in-place`, `test-detect-inputs`)
  `exit 77` on any fleet by design. `scaffold.sh --run-tests` went with it — there is nothing left to
  run — as did `/setup`'s B3 test-suite step and `/update`'s mirror of it.

  **The three `.example` project hooks.** `doctor.sh`, `worktree/new.sh` and `workspace.sh` all look
  for `worktree-bootstrap.sh` / `session-cleanup.sh` / `doctor-extra.sh` *without* the suffix, so a
  file left at the `.example` path was inert by construction. `/setup` now tells you to write the real
  filename.

### Added

- **`templates/lib/purge.txt` — the removal channel installs never had.** scaffold's components only
  copy IN; they have never removed anything. So every file the hub retires lives on forever in every
  workspace that once installed it, and a deletion here would only have helped brand-new installs.
  The manifest lists paths shiploop used to ship, and every writer run — fresh scaffold, single
  `--component` refresh, `/shiploop:update` — deletes them, so an existing fleet converges on the
  current footprint no matter which component is bumped. Standalone `--verify` only warns, because
  it must never write. Absolute and `..`-bearing manifest lines are refused, so a malformed entry
  can't reach outside the workspace. Seeded with everything removed above; when you delete a template
  from now on, add its installed path here (moves still go to `relocations.txt`). Locked in by
  `test-purge-removed.sh` (17 assertions).

- **A sub-repo-scoped lesson now lands in that sub-repo's own `CLAUDE.md` instead of bloating root's.**
  Root `CLAUDE.md` is re-sent every turn of every session, and `lessonPatch` had no placement check —
  a worker's mis-scoped "root-worthy" lesson just accretes forever. Measured: one fleet's root file
  went 7,319 → 47,075 bytes monotonically; another reached 99,261 B, needed a manual trim to 20,903 B,
  then re-grew to 62,911 B and needed a second trim. `worker-prompt.md` already told workers to route
  sub-repo facts into their own PR instead of `lessonPatch`, but that's a text instruction a worker can
  get wrong — and it did.

  `govern-bookkeep.sh` now re-derives placement itself (`govern::lesson_placement`) instead of
  trusting the worker's claim, redirecting the insert to `<sub-repo>/CLAUDE.md` only when exactly one
  `REPOS` entry is named as a path, no second sub-repo appears anywhere in the text, and no
  cross-cutting signal word (governor/workspace.sh/meta-repo/…) is present — every less clear-cut case
  stays at root, logged either way. Three guards keep the redirect safe: it requires the sub-repo tree
  clean (`git status --porcelain` empty) before writing anything into it; it requires the sub-repo be
  checked out on its own resolved default branch — no hardcoded `main`, it falls back through the
  cached `origin/HEAD` symref, then `origin/main`/`origin/master`, then `main` as a last resort; and
  the commit+push is one transactional unit — any failure, including a push failure and not just a
  commit failure, rolls the sub-repo back to its pre-attempt HEAD and falls through to the original
  root insert, so a lesson never lands nowhere and a sub-repo working tree is never left dirty.

### Changed

- **The always-on cost of installing shiploop is cut 46%, and the half nothing was measuring is now
  measured.** Two surfaces load into every session of a workspace that has the plugin installed and are
  re-sent every turn. The seed `CLAUDE.md` was the known one, and the SessionStart digest has warned
  when it exceeded 14,000 chars since it landed. The other was invisible: the plugin's own manifest
  metadata — the `description:` frontmatter of `SKILL.md` and of every `commands/*.md` — which had
  grown to ~4.4 KB, nearly as much as `CLAUDE.md` itself, with nothing watching it. `/setup`'s
  description alone was 737 bytes of feature tour. A description's only job is to let the model decide
  whether to invoke the command; the prose belongs in the body, which loads on invocation. Trimmed to
  ~1.1 KB, preserving the routing signal that actually distinguishes siblings — `/push` and `/update`
  now name each other as opposite directions of the same sync channel, and `/setup` points at both.

  The seed `CLAUDE.md` was re-audited by **frequency of need**, not topic. A rule earns a place in a
  file re-sent every turn if it fires often, **or** if violating it fails silently and unrecoverably —
  nobody consults an appendix before `reset --hard`. Rules that are both rare *and* mechanically
  backstopped moved to `CLAUDE-APPENDIX.md`: MCP-servers-at-root, one-root-package-manager (the root
  `.gitignore` already blocks a second lockfile), and main-checkout-on-main (`check-main-on-main.sh`
  re-checks it every session start). Rare-but-silent rules stayed — including never committing `.env`,
  which is the sole control there, since `githooks/pre-commit` has no `.env` guard. The delegation rule
  shrank because `router-posture-reminder.sh` already injects the full posture once per session, so the
  core was paying twice for one instruction. The appendix now records the audit *test*, not just its
  outcome. Net: seed `CLAUDE.md` 5,895 → 4,417 bytes, manifest 4,412 → 1,155, total 10,307 → 5,572.

  So the manifest can't silently regrow, the free `wc -c` size-trigger in `learnings-digest.sh` now
  covers it too, via `SHIPLOOP_MANIFEST_MAX_CHARS` (default 1400, measured against the summed
  `description:` values). It resolves the plugin directory through the same candidate order as
  `doctor.sh` and degrades completely silently when none resolves — a workspace without the plugin
  installed pays nothing and sees nothing. Still no model invocation: the alarm costs zero when healthy.

- **The internal ticket id is kept off PRs by default, in every workspace — not just public ones.**
  `#N` is a local queue id: it means nothing to anyone reading the repo, and it advertises a private
  tracker. Two controls existed, and both were narrower than the problem. The run-loop's
  `govern::scrub_pr_ticket_ref` backstop ran on every PR but can only reach the **title and body** —
  a **commit subject** is unreachable, because rewriting pushed history is a force-push and a hard
  stop. The only control that ever covered commit subjects was the "PUBLIC-REPO PR HYGIENE" prompt
  block, and that was injected only when some repo in the workspace was detected public. A
  private-only fleet therefore shipped `#N` into commit subjects with nothing to stop it, and got its
  titles fixed only after the worker had already written them.

  Every worker prompt now carries a three-line default rule: no ticket id in the PR title, the PR
  body, or any commit subject — describe the change on its own merits. The **branch is unchanged**
  and still `ticket-<N>`; the governor links PRs to queue entries by branch, and the rule says so
  explicitly so it cannot be read as contradicting `worker-prompt.md`. The public-repo block is
  trimmed to what is now unique to it — the neutral `sl-<hex>` branch and the matching resource
  naming — so no workspace pays for the same instruction twice.

  `GOVERN_PR_TICKET_REF=1` restores the old behavior: the prompt block is dropped and the run-loop
  scrub is skipped. It cannot weaken the existing public-repo guarantee — on a repo
  `govern::repo_is_public` reports public, the scrub runs anyway and the prompt restates the rule.

- **Every prompt surface the harness sends is compressed in place** — meaning preserved, every parse
  contract byte-exact. Per dispatched ticket (multiplies by backlog size): `worker-prompt.md`
  26,342 → 22,018 bytes, `preferences.md` 4,598 → 3,457, the `scout-ticket.sh` prompt 2,145 → 1,422 —
  ~6.2 KB (~1,557 tokens) saved per ticket. Per turn, forever: installed command/skill `description:`
  frontmatter 2,217 → 1,067 bytes — the manifest trim above only reached the hub-facing descriptions,
  not the `templates/` copies `scaffold.sh` actually installs, so a fresh workspace was paying more
  than the hub itself; this closes that gap. Per session: hook payloads cut 45-59%
  (`router-posture-reminder.sh` 1,109 → 458). Per research run: `deep-research.js` prompts −31%, and
  VERIFY fires up to 75×, so up to ~35.8 KB per run.

  The recurring win was de-duplication, not prose trimming — `SKILL.md`, `router-posture-reminder.sh`
  and `check-main-on-main.sh` each re-sent text the auto-loaded seed `CLAUDE.md` already carries at
  zero marginal cost. Seed `CLAUDE.md` and the seed files are unchanged, already measured at their
  floor. Verified: `GOVERN:SECTION` fences, `{{VAR}}` template vars, the report-schema keys and all six
  scout keys intact byte-exact.

- **The validation/Flow output-field rule is fenced too, closing a gap in 1.14.0's prompt
  segmentation.** The `required`/`ranLiveTest`/`evidence` plus
  `gatePassed`/`measured`/`validatedShas`/`environment`/`flowIds` field rules sat *after* the first
  `GOVERN:END validation` marker, so they were unfenced and always-on — every worker paid for
  output-contract rules only a validation/spike ticket could ever populate. Wrapped in a second
  `GOVERN:SECTION validation` … `GOVERN:END validation` pair; `prompt_apply_sections()` already
  keeps/drops a fenced block by name per-occurrence, so the existing `govern::is_validation_ticket`
  classifier governs both spans identically with no `spawn-worker.sh` change. Measured: an ordinary
  ticket's rendered prompt drops 16,010 → 14,484 bytes (−1,526 B, matching the span exactly); a
  validation ticket's prompt is byte-identical with segmentation on or off.

### Fixed

- **5 govern tests asserted on exact prompt/hook wording that the compression pass above reworded,
  and broke.** `govern-supervise.sh`'s "nothing new since last pass" marker lost its "no ticket has"
  phrasing (`test-supervise-incremental`); `spawn-worker.sh`'s default PR-hygiene block dropped its
  bolded **PR title**/**PR body**/**commit subject** markers and reworded "BRANCH is still"
  (`test-pr-ticket-ref-default`); its retry-notes framing dropped "not instructions and not
  established fact" (`test-retry-notes-injection`); and `learnings-digest.sh`'s size-budget reminders
  dropped the "budget N" phrasing two override tests grep for (`test-claudemd-size-trigger`,
  `test-manifest-size-trigger`). Restored the pre-compression wording for exactly these five strings;
  the rest of the compression is untouched, and no test was changed.

- **Two stale assumptions in scaffold / session-start housekeeping.** `scaffold.sh`'s
  `component_govern()` still logged "installed govern scripts + tests + governor prompts", but the
  govern test suite is deliberately hub-only now and is no longer installed into a fleet workspace —
  dropped the false "+ tests" claim. `check-main-on-main.sh` assumed every sub-repo's default branch
  is named "main", so a repo whose default is "master" (or anything else) reported constant false
  drift; it now resolves each repo's actual default branch from the cached `origin/HEAD` symref,
  falling back to whichever of `origin/main`/`origin/master` exists, then "main" as a last resort — no
  network calls, so the SessionStart hook stays fast.

## 1.14.0 — 2026-08-03

The lighter release. The measured cost identity for a worker run is
`sessions × turns/session × context/turn × price/token`, and the accumulating term dominates: one
resolved ticket ran 22.9M tokens of which 22.55M (98.4%) was cache-read of context the worker grew
itself, against a ~7k starting prompt. So this release is weighted toward **deleting per-turn context
and decoupling machinery that acted unconditionally** — not toward adding capability. Two of the
spec's components were gated and correctly ship as *not built*; see "Deliberately not built" below.

### Changed

- **The tool-schema trim is ON by default** (`GOVERN_WORKER_TOOLS`). It shipped opt-in in 1.13.x while
  the allow-list was still a theory. Before flipping it, the list was **re-derived over all 125 worker
  transcripts** under `logs/govern/` (the earlier derivation covered 39): every tool the fleet has
  ever invoked — Bash 2194, Read 267, Edit 240, Write 64, Agent 35, TaskUpdate 24, Monitor 14,
  ToolSearch 13, TaskCreate 13, ScheduleWakeup 9, SendMessage 3 — is already in the list, so the
  measured invocation set is a strict **subset** and default-on removes nothing in live use. The
  reproducing histogram is committed in `spawn-worker.sh`'s header; re-run it before any future edit
  to the list. Measured: turn-1 request 164,795 → 107,985 bytes (−34.5%); the tool block alone
  85,260 → 28,417 (−66.7%). `GOVERN_WORKER_TOOLS=0` (or `off`) restores the pre-trim spawn.

- **Headless passes no longer inherit the operator's personal config layer.**
  `GOVERN_SETTING_SOURCES` now defaults to `project,local` instead of `user`, at all seven
  `claude -p` call sites (`spawn-worker`, `scout-ticket`, `govern-supervise`, `govern-improve`,
  `govern-self-apply`, `sync-port`, `measure-prefix`). None of them can act on extended-thinking
  shortcuts, TodoWrite practice or PR-review workflow, yet all of it was re-sent on every turn of
  every worker session (~5,000 tokens on the authoring machine). `project`/`local` are kept because
  the workspace's own `settings.json` is what wires the govern hooks. Set
  `GOVERN_SETTING_SOURCES=user` to restore the prior behavior.

- **The worker prompt is conditionally assembled instead of one static blob.**
  `templates/governor/worker-prompt.md` is sent to every worker and re-read on every turn, so a block
  that only ever applies to one ticket class is pure per-turn tax on every other ticket. The
  validation/spike section — 6,207 of 24,216 template bytes, 25.6% — is now fenced
  `<!-- GOVERN:SECTION validation -->` and appended only for a validation ticket, classified by the
  existing fail-closed `govern::is_validation_ticket`. Maintainer HTML comments are stripped from the
  assembled prompt too. Measured through the real `GOVERN_SPAWN_PRINT_PROMPT=1` seam, including
  doctrine and ticket block: **an ordinary ticket's prompt is 25,680 → 19,379 bytes (−24.5%,
  ≈ −1,575 tokens per turn)**; a validation ticket's is byte-identical.
  `GOVERN_PROMPT_SEGMENTED=0` restores the monolith exactly.

  Segmentation uses in-place markers rather than a second template file, so this adds no file and no
  scaffold wiring. The rules for adding a section are in the template's own header: only a block with
  an existing, reliable, **fail-closed** classifier — a worker that needed a section it did not
  receive fails its ticket, and a failed attempt is ~100% waste whose retry costs more than the
  original. The asymmetry runs one way; when uncertain, include.

- **Worker sizing is a measurement, not a filing-time guess.** `resolve_sizing`'s precedence is
  inverted: the scout's measured verdict now decides both axes. Previously a hand-written ticket
  `Model:`/`Effort:` field — written before any evidence existed, by whoever happened to notice the
  bug — **outranked** the pass that actually greps the code, and the scout only filled axes the
  ticket left blank. `GOVERN_MEASURED_SIZING=0` restores the old ticket-field-wins precedence.

  The tier set stays deliberately coarse and must stay so: the prompt cache is per-model and an
  effort change invalidates the tools+system prefix, so spreading N tickets across N distinct
  `(model, effort)` combinations fragments the cross-worker shared prefix that measurements show
  currently works.

- **The scout stops throwing away what it found.** It had to locate the target files, the analogous
  prior commit and the test command in order to answer its six scope questions — then reported only
  the six integers, so the worker paid full exploration price to rediscover what a haiku pass had just
  found. Those pointers now reach the worker (new `scout-ticket.sh --findings`), explicitly labelled
  **unverified hints, not instructions**, with an instruction to ignore any pointer that does not
  match the code. The six-scalar deterministic bash scorer is unchanged.

- **Self-improvement fires once per run, not once per driver.** The pass now runs in the orchestrator
  over the aggregated state after reaping — beside the whole-run supervisor flush, which exists for
  exactly this reason — and a child driver (`--orchestrated`) skips its own. A child only ever sees
  its own slice of a run, so a per-driver "review of the run" is structurally a review of a fragment;
  an N-way parallel run filed N near-identical tickets, two of them from the same wall-clock run.
  Triage now also **appends to a standing ticket** rather than minting a new `## #N` each time, since
  the same friction recurs and produces the same proposal. `GOVERN_IMPROVE_PER_RUN=0` restores
  per-driver filing.

- **Worker prompt: task boundaries, and verify a delegated claim before acting on it.** The brief
  shape a subagent needs is objective, output format, tool/source guidance **and clear task
  boundaries**; the template had the first two. Boundaries are what stop a worker wandering — the fix
  is contained in X, adjacent improvements go to `newTickets`, not into the diff. And workers delegate
  too (34 `Agent` calls across 39 transcripts): a child's factual claim is now framed as a lead, not
  a result, to be confirmed with one `grep` before it is acted on.

### Added

- **Dispatch is no longer unconditional — a ticket can resolve with no worker, or with an
  execute-only worker.** Every ticket used to get a fresh headless worker that re-derived the codebase
  from scratch regardless of what the parent session already knew. The criterion for spawning at all
  is that the work would flood the parent with output it will never reference again; when the parent
  already **holds** the context, the spawn buys nothing and pays a cold start.

  The split is by **token weight, not by task** — the parent DECIDES (states the change it already
  knows), the worker EXECUTES (the edits, the test runs, the build errors, the retry loop, the PR: the
  verbose part, which stays in a throwaway context). "Let the parent do the work" would destroy the
  flat-parent property the governor exists for.

      GOVERN_WARM="<ticket-number>|<what you read, and the change you believe is needed>"

  The signal is **explicit and narrow, never inferred**: it names exactly one ticket, it is
  per-invocation so it cannot rot in the queue the way a ticket field does, and a malformed value is
  ignored with a log line rather than guessed at. With a stated change the worker runs **execute-only**
  at the cheapest *existing* tier (never a newly minted `(model, effort)` pair — that would
  re-fragment the shared cache prefix). With an empty change **no worker is spawned** and the ticket
  is parked with the assertion recorded — never auto-resolved, because "the parent thinks nothing is
  needed" is a claim for a human to confirm and a silently dropped ticket is the one outcome this must
  not produce.

  **The risk, stated plainly:** a warm parent's knowledge can be stale or simply wrong, and an
  execute-only worker will faithfully implement a wrong instruction where a cold worker would have
  re-derived the truth. So the brief is **falsifiable, not a command**: it states what the parent
  *believes* and instructs the worker to STOP and report rather than proceed if the code does not
  match. `GOVERN_EXECUTE_ONLY=0` hard-disables the branch fleet-wide.

### Removed

- **The ticket `Model:` / `Effort:` contract.** Gone from the parser's dispatch path, from
  `file-ticket.sh`, and from all four documentation sites (`templates/seed/tickets.md`,
  `templates/seed/CLAUDE.md`, `templates/governor/README.md`, `commands/setup.md`). Sizing is measured
  now; a guess made at filing time no longer participates.

  **Upgrade note — this degrades cleanly and needs no action.** Existing queue entries still carrying
  the fields are **inert**: ignored, never an error. `file-ticket.sh --model` / `--effort` are still
  *accepted* and ignored with one log line, so an older caller — or a `/setup` doc a fleet already
  copied — does not have its tier value consumed as the ticket title. `GOVERN_MEASURED_SIZING=0`
  restores the old precedence for a fleet that wants it.

### Fixed

- **One hardened `govern::mtime`** replaces three open-coded copies of the portable
  `stat -c %Y || stat -f %m` idiom. On GNU coreutils `stat -f` means `--file-system` and prints
  multi-line noise on stdout while exiting non-zero, so both guards matter: strip non-digits, and
  default to `0` rather than returning empty (an empty value makes a caller's `$(( now - m ))` a
  syntax error that aborts it under `set -e`). Only `valjob::_mtime` actually lacked them —
  `valpending.sh` has had them all along, contrary to an earlier audit note. `valjob.sh` delegates
  when `common.sh` is loaded and keeps a local copy otherwise, preserving its deliberate standalone
  property.

- **The `--tools` capability probe is now wired into every spawning test.** Flipping the trim on by
  default made the probe invoke `$claude_bin --help`, which consumed counter-driven fake CLIs and
  shifted assertions in three tests. The `_GOVERN_TOOLS_SUPPORTED` pre-seed seam already existed but
  was not used by those tests; it now sits alongside `_GOVERN_EDP_SUPPORTED`. This is the documented
  "new `claude` invocation in the dispatch path perturbs the suite" anti-pattern, and it predicted the
  failures exactly.

### Deliberately not built

Two components of the design spec were gated and the gates correctly refused them. Recorded here so
they are not re-attempted from scratch.

- **Decoupling ticket bookkeeping from PR merge.** The proposal was to delete a ticket's queue entry
  as soon as its PR is open. The gate's letter passes — escalations and `state.jsonl` could carry
  unmerged-PR tracking — but the change reintroduces `#42` (`test-merge-fail-park.sh` is its
  regression test) and, worse, kills an *automatic* recovery path: run-loop's resume adopts an
  existing open PR only when a ticket is re-**selected**, which requires its block to still be in
  `tickets.md`. A red-CI ticket would stop being auto-retried and depend on a human answering an
  escalation — a net loss of autonomy for a harness whose purpose is autonomous grinding. The part of
  the complaint that survives is **latency, not ordering** (the driver still blocks on CI before
  claiming the next ticket) and is tracked separately.

- **A model-authored dispatch plan.** The diagnosis is sound — the harness mail-merges a template
  rather than orchestrating — but the gate required the seam to be **net-negative**: it could only be
  built if landing it let us delete the scout's scoring table, the `Model:`/`Effort:` parser and
  `resolve_sizing`'s precedence ladder. All three are deliberately retained (the parser is what the
  kill switch restores, the bash scorer is deterministic and auditable rather than a second judgement
  handed to a model, and the ladder is retry escalation). So the seam would be purely additive — a
  model in front of every worker that can author a wrong brief confidently, at scale, where today a
  cold worker at least discovers the truth for itself.

### Upgrade notes

- Nothing to do. Every behavior change above is behind an env kill switch whose `=0` (or documented
  value) restores the previous behavior exactly: `GOVERN_WORKER_TOOLS=0`,
  `GOVERN_SETTING_SOURCES=user`, `GOVERN_PROMPT_SEGMENTED=0`, `GOVERN_MEASURED_SIZING=0`,
  `GOVERN_IMPROVE_PER_RUN=0`, `GOVERN_EXECUTE_ONLY=0`.
- Existing workspaces pick this up via `/shiploop:update`. Queue entries carrying `Model:`/`Effort:`
  need no edit — they are inert.
- Verified with the full scaffolded suite (CI's `scaffold-and-test` recipe in a throwaway workspace):
  128 passed, 0 failed, 5 skipped, 133 total, against a 126/0/5/131 baseline.

## 1.13.3 — 2026-07-26

### Added

- **The worker's request payload is now measurable — and the biggest component turned out to be tool
  JSON.** Every prefix decision so far was made against a number nobody could see directly.
  `count_tokens` cannot observe what Claude Code assembles, and turn-1 `cache_creation_input_tokens`
  collapses the whole prefix into a single figure, so attributing it meant one throwaway re-spawn per
  component and N sources of noise. At the API boundary the assembled body is already componentised,
  so `templates/govern/measure-prefix.sh` reads the split directly: it starts a local pass-through
  proxy on `ANTHROPIC_BASE_URL`, spawns a REAL worker through it — the prompt from `spawn-worker.sh`'s
  own assembly (new `GOVERN_SPAWN_PRINT_PROMPT=1` seam) and the flags from its own resolver
  (`GOVERN_SPAWN_DRY_RUN=1`), so the measurement can never drift from the spawn the fleet runs — and
  emits a component table plus a per-tool schema breakdown.

  The proxy (`templates/govern/lib/capture-proxy.mjs`) sits in front of a worker and handles live
  credentials, so three properties are load-bearing and asserted in its header: every header is
  forwarded **verbatim** and no header **value** is ever read, stored or logged; no request or
  response **body** content is ever written to the log, only sizes and names; and it binds to
  `127.0.0.1` only. Subscription/OAuth auth survives it unchanged — this is *not* the `--bare`
  blocker, which forces `ANTHROPIC_API_KEY`. All three are asserted against a real proxied request in
  `templates/govern/test/test-capture-proxy-no-leak.sh` (local http stub upstream, no network): a
  credential sentinel, a request-body sentinel and a response-body sentinel must all be absent from
  the capture log, while the stub upstream must still receive the credential verbatim.

  First measurement (CLI 2.1.220, `--model opus`, a real spawn): of 164,795 turn-1 request bytes,
  **tool schemas are 85,260 — 51.7%**, ahead of `messages` (43.7%) and the system prompt (4.3%). A
  single tool a headless worker structurally cannot call (`Workflow`, 21,525 B) is 13.1% of the whole
  request, re-sent every turn. Full table and method in `PROOF.md` section 5.

- **`GOVERN_WORKER_TOOLS` — opt-in tool-schema trim, -34.5% request bytes measured.** Set it to
  `default` to pass `--tools <recommended list>` to every worker, or give your own space/comma-
  separated list. On the same spawn as above this took the request from 164,795 to 107,985 bytes,
  with the tool block down 66.7%, and the worker still completed normally. The recommended list keeps
  file + shell + search, `Agent` (the router posture mandates delegation), the docs-research web tools
  and the background-task controls; it drops the interactive/long-lived surface a `-p` worker has no
  user for. It also *adds* `Glob` and `Grep`, which the CLI's default `-p` set omits — dedicated
  search tools return less into context than the bash pipelines that replace them.

  Why this lever and not tool-output compression: cache reads bill ~0.1x and writes ~1.25x, so
  rewriting anything already in the conversation invalidates from that point forward and converts
  cheap reads into expensive writes — a raw-byte reduction does not survive the conversion. The tool
  block is **static and deterministic** and sits at the front of the prefix, so trimming it moves the
  cache key exactly once and every later worker shares the smaller prefix. (The same rule is why any
  future output compressor may only touch the **tail** — a fresh `tool_result` with nothing
  downstream of it — and must be deterministic.) `--allowedTools` is not a substitute: measured
  no-change, because it gates permission rather than what gets loaded.

  **Off by default** per the additive-union rule — losing a tool a worker genuinely needed costs a
  failed ticket, which dwarfs the prefix saved, so the opt-in is deliberate. Capability-probed via
  `--help` (`govern::claude_supports_tools_flag`), so a fleet on an older CLI silently skips the flag
  instead of failing every worker at argument parsing. **Keep/purge gate:** purge if a worker fails or
  parks for a missing tool, or if re-measuring shows the tool block below ~15% of the request; keep
  while the cut holds and the suite plus a real end-to-end ticket stay green. Covered by
  `templates/govern/test/test-spawn-tools-trim.sh`.

- `assert_not_contains` in the govern test harness — asserting that something is **absent** is the
  natural shape for a context-cost test, and there was no helper for it.
- `test-learnings-digest.sh` (19 assertions), which runs in both the hub and scaffolded-workspace
  layouts. Includes a guard that the shipped seed `learnings.md` injects zero bytes, so re-introducing
  a heading into the seed can't silently re-tax every fleet.

### Changed

- **The seed `CLAUDE.md` is 47% smaller, and the displaced material has a home.** `CLAUDE.md` is
  re-sent to the model on *every turn*, so it is the most expensive storage in the workspace — and the
  seed was using it for reference tables and rationale. The full `npm run` command table (discoverable
  via `npm run`), the *why* behind the delegation rule, and the multi-paragraph justification for
  checkpoint filing were all being re-billed every turn, forever, on every fleet.

  The seed now ships a **`CLAUDE-APPENDIX.md`** alongside it: same durable knowledge, loaded on demand
  instead of every turn. `CLAUDE.md` keeps the hard rules a session must never miss; the appendix
  carries the depth. 1682 → 892 words in the always-on file, and that is *after* promoting an
  additional load-bearing anti-pattern into it. Two near-duplicate rules (the delegation posture
  appeared as both operating rule #3 and anti-pattern #10) collapsed into one.

  The appendix is seeded on existing fleets too, not just new ones — an absent appendix is precisely
  what makes operators keep growing the always-on file.

- **The SessionStart learnings hook injects entries, not lines.** The slot ran an inline
  `head -30 learnings.md`, which was a net token *loss* three ways. It paid for the file's ~16-line
  instructional preamble ("what belongs here", "promote when stable") before reaching anything the
  file had to *say*. On a fresh fleet it injected 18 lines whose entire payload was
  `_(empty — append dated entries…)_` — a per-session tax, forever, for zero information. And `head`
  reads the *top* of a file the seed tells operators to *append* to, so any fleet that followed the
  instruction was shown its **oldest** learnings with the newest truncated away.

  Replaced by `scripts/learnings-digest.sh`: skips the preamble, date-ranks entries (correct whether
  a fleet prepends or appends), emits the newest few, and emits **nothing at all** when there are no
  entries. Fenced code blocks are not treated as entry boundaries, so a shell snippet containing
  `## comment` no longer slices the file at the wrong place. Tuned by
  `SHIPLOOP_LEARNINGS_MAX_ENTRIES` (default 3) and `SHIPLOOP_LEARNINGS_MAX_LINES` (default 40).

  A fresh fleet goes from ~1.9 KB of session-start boilerplate to **zero bytes**. `settings-merge`
  rewrites the legacy inline command **in place** on existing fleets rather than appending beside it
  (which would double the injection), and the rewrite is idempotent.

### Fixed

- **`GOVERN_WORKER_TOOLS_DEFAULT` was missing three tools workers actually invoke.** A scan of 39
  confirmed-real worker transcripts found `Monitor` (11x), `ScheduleWakeup` (6x) and `SendMessage`
  (3x) all in live use despite being cut from the recommended `--tools` list on the theory that a
  headless `-p` worker has no use for them. Flipping the trim on as-shipped would have removed tools
  mid-flight for any worker that reached for one — a failed ticket costs far more than the prefix
  saved, so measurement wins over theory here. All three are back in the recommended list; the
  never-invoked `Task*` tail and `NotebookEdit` are left in place pending a dedicated re-measure
  (dropping them needs its own evidence, not opportunistic cleanup). The default remains **off** —
  turning it on fleet-wide still needs a real A/B on cost-per-successful-ticket, not bytes, which
  hasn't run yet.

- **The flow-registry grammar was described but not enforced.** `govern::flow_validate` encoded the
  whole flow-block grammar and had no production caller — the gate that actually runs
  (`lint-validation-refs.sh` and the Stop hook, both via `govern::flows_lint`) never invoked it, so a
  flow missing `Kind`/`Surface`/`Paths` passed the real gate. `GOVERN_FLOW_ID_RE` and
  `GOVERN_FLOW_STATUSES` were likewise declared and never read. Consequence: a typo'd `Status: PSAS`
  linted clean and then matched none of the downstream `case` arms (staleability, status summary,
  revalidation, the validated-subset field requirement) — the flow did not error, it silently ceased
  to exist for the registry. `flows_lint` now runs `flow_validate` per flow as a FAIL row, and
  `flow_validate` rejects an out-of-charset id and an unknown `Status`. Covered in
  `test-flows-parser.sh` and `test-flows-lint.sh`, including a negative case so a legal `Status`
  cannot trip the check.

- **The validation gate recognized fewer tickets than the worker prompt does — and degraded OPEN.**
  `worker-prompt.md` gives the worker four tells for "this is a validation ticket, empirical evidence
  required", but the #67/#73 safety net in `run-loop.sh` matched only the first two plus half of the
  third. A ticket whose `Done when` asks for a PASS/FAIL table from a real run was validation-required
  *by the worker's own prompt* and invisible to the gate, so a worker reporting `resolved` off static
  analysis walked straight through the mechanism built to stop exactly that. Every other malformed key
  in the report contract degrades closed; this one accepted an unproven "resolved". The recognizer is
  now `govern::is_validation_ticket` in `lib/common.sh`, beside `govern::validation_gate_action`, so
  the prompt's tells and the enforcement have one place to drift from instead of two; tells 3b
  ("actually work") and 4 ("PASS/FAIL") are added, and it is deliberately fail-closed — a false
  positive parks and asks a human, a false negative is the bug.
  `test-validation-ticket-recognizer.sh` locks all four tells *and* the negative direction, so routine
  bugfix/docs tickets are not swept into the gate.

- **The deep-research verifier is asked to judge recency but was never given the date.**
  `EXTRACT_SCHEMA` declares `publishDate` and the fetch stage writes it, but nothing read it — absent
  from all four `sources:` projections and from synthesis — while `VERIFY_PROMPT` item 4 tells every
  verifier to check whether a claim is outdated. That checklist item was answered from guesswork. The
  date now rides on each claim and renders in the verifier prompt, with an explicit "unknown — treat
  recency as unverified" when the source had none. Two further declared-and-unread fields are also
  surfaced: `counterSource` (the source that disputes a claim — every killed claim previously discarded
  its own evidence) now appears in `refuted[]` and the synthesis prompt, and `scope.summary` is logged
  so the angle choice is auditable when a run comes back thin. Additive only; the output shape stays
  at parity with Claude Code's built-in deep-research.

### Removed

- **Three dead artifacts, each verified by repo-wide `git grep` returning only its own definition.**
  `measurements/ticket-76-tail-compression-ceiling.md` (zero inbound references anywhere — a one-off
  analysis artifact that read as current documentation while being unreachable, citing tickets no
  longer live), `scaffold.sh write_if_changed()` (defined, never invoked, no `eval`/`trap`/`export -f`
  dispatch), and `templates/lib/wrap.sh fs_is_case_insensitive()` (an APFS/HFS+ probe never invoked —
  removing it drops no capability, since `wrap.sh`'s real case-collision check uses `find -iname`,
  which works on any filesystem without knowing the FS first). The scan covered 257 tracked files and
  406 shell functions across 201 files; these were the only inert artifacts on the shell/file axis.

### Docs

- **Four documented claims that contradicted the implementation, all re-verified against the code.**
  `templates/.claude/commands/govern.md` — the copy that scaffolds into every workspace as `/govern`,
  and the one `commands/govern.md` explicitly declares authoritative — was many revisions behind its
  hub counterpart: the more authoritative file was the more stale one. It was missing the
  `GOVERN_AUTONOMY` trust ladder and `GOVERN_BATCH_MAX` locality batching, and told operators to
  hand-edit `governor/escalations.md` entries when `record-escalation-answer.sh` is the real
  mechanism, while omitting the `mitigated` disposition entirely. Regenerated from the hub copy via the
  same transform the other three pairs already use. Also: `GOVERN_MAX_RUNTIME` was documented as "~4h"
  when `run-loop.sh` defaults it to `0` (no cap) — a wall-clock bound that does not exist is the worse
  direction of wrong; `CONTRIBUTING.md` said "the four slash commands" when there are seven; and
  `commands/push.md` gave the sync-port lock path as `scripts/govern/.locks/` when it resolves under
  `governor/.locks/`.

- **~25 user-tunable governor knobs were source-only.** A sweep of all 182 `GOVERN_*`/`SHIPLOOP_*`
  identifiers found no documented-but-unread knob — the docs were accurate as far as they went — but
  that many genuinely tunable knobs in no README table, no `.env.example` and no prose, discoverable
  only by reading the governor source. The one that matters most is `GOVERN_PERMISSION_MODE`: it
  defaults to `bypassPermissions` and is on the `GOVERN_PROTECTED_PATTERNS` self-apply guard list —
  considered important enough to shield from agent self-edit, yet invisible to the operator, so the
  permissive default was effectively non-negotiable in practice.

## 1.13.2 — 2026-07-26

The cost release. Three levers, all aimed at the same target: the tokens a ticket spends on
*exploration* rather than on the fix. Sizing stops being a guess, a failed attempt stops being a
total loss, and a fix that already exists upstream stops being rediscovered from scratch.

### Added

- **Scout-then-size — a ticket's tier is now MEASURED, not guessed.** Sizing was a prior, not a
  measurement: the `Model:` field is decided before any evidence by whoever files the ticket, and a
  ticket carrying no field fell through to a blanket `GOVERN_WORKER_MODEL` (default `opus`). That is
  wrong in both directions — it overpays on easy tickets, and it cannot detect a hard one until an
  attempt has already failed at full price. Reconnaissance costs roughly a thousandth of the work, so
  spending a fraction of a cent to decide whether to spend three dollars or thirty is the best trade
  available.

  A new `scout-ticket.sh` runs **before** the worker is spawned, from the single `spawn_worker_tracked`
  chokepoint in `run-loop.sh`. It has two deliberately separate halves. The first is one cheap
  read-only `claude -p` pass at the **haiku** tier (`--permission-mode plan`, so it can grep and read
  but never write) that greps the real code seeded from the ticket's `Where:` line and emits a small
  scope object: files plausibly touched, repos involved, whether tests already cover the area, whether
  git history holds a precedent commit, local edit vs structural (signature / schema / API contract)
  change, and concrete vs vague fix direction. The second half is **pure bash** — a deterministic,
  auditable, tunable scoring table, not a second model judgement call:

  | measured scope                                              | model  | effort |
  |-------------------------------------------------------------|--------|--------|
  | 1 file, local, precedent + test exist                       | haiku  | low    |
  | ≤5 files, 1 repo, concrete fix direction                    | sonnet | medium |
  | cross-repo, or contract/schema change, or no test, or vague | opus   | high   |

  **The scout never outranks a human.** An explicit ticket `Model:`/`Effort:` always wins, per axis —
  the scout only decides what the brain left blank, replacing the blanket default rather than the
  operator. The verdict is cached on the run dir, so a retry reuses it instead of re-scouting, and the
  chosen tier and scope class are logged and recorded in the per-attempt ledger (`scopeClass`) so a
  later analysis can join scope class to outcome.

  Scout output is untrusted model output feeding a dispatch decision, so it is guarded on the way in:
  structurally invalid output (not a JSON object, or a missing key) is **rejected** and sizing falls
  back to `GOVERN_WORKER_MODEL`, loudly; an out-of-domain field (unknown enum, non-integer, absurd
  count) is **clamped to the hard end** of its domain. Clamping is one-directional by construction, so
  a malformed scout can only ever push a ticket up the ladder — never silently downgrade a hard ticket
  to haiku. A timeout, a non-zero exit, or a reply with no JSON in it all cache nothing and fall back
  the same way. `GOVERN_SCOUT=0` reverts dispatch to the pre-scout behavior exactly; `GOVERN_SCOUT_MODEL`
  and `GOVERN_SCOUT_TIMEOUT` tune the pass. The scoring half is unit-tested in isolation via
  `scout-ticket.sh --score` (no model call), alongside end-to-end precedence tests through the existing
  dry-run seam.

- **Retry memory — a worker's findings survive into its next attempt.** A failed or timed-out worker
  left its worktree preserved but its knowledge nowhere: the retry started from the same cold prompt
  and re-derived the whole exploration, which is the dominant cost term. Every worker now appends to
  a `.governor-notes.md` scratchpad at its worktree root as it goes (relevant files, ones ruled out,
  root cause, what was tried and why it failed, the repro commands), and `spawn-worker.sh` injects
  that file back into the prompt **on a retry only**.

  The injected block is framed as **untrusted prior-attempt evidence** — the attempt that wrote it
  did not finish, so its conclusions are things to evaluate, never instructions and never established
  fact. Content is delimited as data and byte-capped by `GOVERN_RETRY_NOTES_MAX_BYTES` (default
  `16000`), with the full file left on disk. First attempts are unchanged apart from the standing
  instruction to keep notes; a retry with no notes file injects nothing. The scratchpad is
  git-ignored, so it never lands in a PR.

- **Upstream-drift pre-gate — the harness stops paying to re-derive a fix the hub already has.** A
  workspace that dogfoods shiploop as its own sub-repo has, for every mechanism script under
  `scripts/govern/` (and `scripts/worktree/`, `scripts/lib/`, `governor/`), a template counterpart in
  the hub — and another fleet may have already ported the identical fix upward. Root `CLAUDE.md`'s
  "workspace ↔ hub drift" anti-pattern told a *human* to diff the two before authoring a fresh fix,
  but nothing enforced it, so a worker could burn a full session (~$10) rediscovering a fix that was
  one `/shiploop:update` away.

  Before dispatch, the gate reads the ticket's `Where:`/`Files:` line and, for each live path it
  names, asks whether the hub is ahead on that exact file. **The direction test is the whole trick:**
  `live != tpl` proves the two sides disagree but says nothing about who moved. `sync-templates.sh`
  already answers that — its marker records the harness commit the templates are synced through, and
  `--paths` lists the mirrored files this workspace changed since then, i.e. unported *local* work.
  So differs-and-in-`--paths` means the workspace is ahead (spawn normally), while
  differs-and-not-in-`--paths` means the hub is ahead (surface it instead). Reusing
  `sync-templates.sh` rather than re-deriving the live↔template mapping also inherits every exclusion
  it already encodes, for free.

  Four load-bearing safety properties, each asserted by tests: it is **deterministic** (pure file and
  git reads — no LLM call, no network, no writes); it **can never mark a ticket resolved**, its only
  outcome being park-and-escalate, which is strictly weaker than what a worker could have done; it
  **fails open**, so anything unclear dispatches a worker exactly as before; and it is scoped to
  tickets naming mirrored mechanism paths, leaving an ordinary product backlog untouched.

  The codemod-detection half of the original proposal was **explicitly declined** rather than shipped
  half-safe: a false positive that "resolves" a ticket without fixing it is far worse than a missed
  optimization.

## 1.13.1 — 2026-07-26

The ticket-cadence release. Auto-filing stays — it is the mechanism that keeps a backlog grinding
without you. What changes is **when** it fires and **how coarse** it is.

The measurement that drove it, from one real 14-hour session: **23 tickets filed, zero requested by
the operator.** Eight were minted mechanically by `/resolve`'s post-PR sweep, two per worker report
(`resolve #341 (PR 598 opened); file #344/#345 from worker report`). The other fifteen were
volunteered mid-answer, inside replies to the operator's *discussion questions* — the operator asked
what a component did today and got an answer plus a new numbered ticket. When they pushed back —
*"it should all be in single 328, you can merge and rewrite"* — the correction was applied to that
one ticket and the next unprompted filing landed four minutes later.

Three defects, none of which require weakening auto-filing.

### Changed

- **Filing moved from the discussion turn to the bookkeeping checkpoint.** A discussion turn now ends
  with the finding, not with a new `## #N`. Filing happens where the harness already has a checkpoint
  — the Stop-hook sweep, `/resolve`, or an explicit "file this" — by which point the discussion has
  decided what the item actually IS.

  Filing mid-discussion pre-empts that decision twice over: it hijacks a thread the operator opened
  in order to *think*, and it hands a half-formed gap to a future governor run as authorized work.
  That second half is the real cost — in this harness, filing and authorizing are the same act, so
  every reflexive ticket silently widens what runs unsupervised later.

- **Consolidation is the default; a new number is the exception.** Before minting `## #N`, fold the
  finding into the nearest OPEN ticket — rewriting that ticket's body is expected, not a compromise.
  A new number is earned only when the work is independently dispatchable: a different repo/area, or
  something a worker could ship without touching the other ticket. The rule of thumb that ships in
  the seed context: **two tickets one worker would fix in one PR should have been one ticket**, and
  several findings out of one discussion are usually one ticket.

  This binds `/resolve`'s worker-report sweep hardest — one consolidated entry per report, not two
  thin ones. Fragmentation there is not cosmetic: each thin ticket is a separate future governor
  dispatch, so a split queue costs real worker spawns to ship the same change.

- **A filing correction is session-durable.** When the operator rejects a filing decision ("that
  should all be one ticket", "don't file that, let's discuss it"), that is now a standing constraint
  on every later filing in the session, recorded where compaction cannot drop it — not a one-off edit
  to the ticket in hand. The Stop-hook sweep restates it at the checkpoint.

Touches `templates/seed/CLAUDE.md` (rule 4), `templates/hooks/ticket-sweep-reminder.sh` (the
blocking sweep text), and the `/resolve` + `/investigate` commands in both the plugin and the
scaffolded-workspace copies. Behavior-only: no script logic changed, and the govern suite is
unaffected.

## 1.13.0 — 2026-07-26

The context-hygiene release. Where 1.12.0 attacked how many workers you run and what they collide
with, this one attacks what a single worker carries on every turn.

The measurement that drove it, over 35 real worker sessions: the system-prompt prefix is **re-read on
every turn**, and totals **~23% of a session's tokens**. Measuring only the one-time cache *write*
puts it near 0.2% — that is the wrong number, and it is the easy mistake to make. Median session
output was ~17.4k tokens against a mean session total of ~7.2M, so output discipline compounds:
anything a worker doesn't write is also something it never re-reads on a later turn.

A note on units, unchanged from 1.12.0: on a subscription plan the binding constraint is quota and
wall-clock, not dollars.

### Added

- **`--exclude-dynamic-system-prompt-sections` on the worker spawn.** Per-machine sections (cwd, env
  info, memory paths, git status) move out of the system prompt and into the first user message, so
  concurrent workers in different worktrees can share one cached prefix instead of each building a
  private one. `GOVERN_EXCLUDE_DYNAMIC_PROMPT=0` opts out.

  **The size of this win is not yet measured.** Turn-1 cache reads recur identically across unrelated
  tickets, which means a deterministic block already caches across workers today — so the marginal
  gain is only over the genuinely dynamic sections, and may be small. It ships on by default because
  it is free and safe, not because a number justifies it.

- **A bounded capability probe** (`GOVERN_EDP_PROBE_TIMEOUT_S`, default 5s). The flag above is passed
  only if the installed `claude` advertises it in `--help`, probed once per run and cached. On an
  older CLI the flag is omitted with a warning and the run continues.

  This guard matters more than the flag it guards. An unrecognized flag makes `claude -p` exit at
  argument parsing with a plain-text error, which the run loop cannot distinguish from an ordinary
  ticket failure — so shipping a new flag unguarded would kill every worker on a fleet running an
  older CLI and present as N indistinguishable failures. The probe treats a timeout as unsupported,
  so a `claude` wrapper that hangs on `--help` cannot hang the spawn.

- **`--forward-subagent-text` is locked out** by a source-scan assertion. It forwards sub-agent text
  and thinking into the parent — the opposite of the bounded-return contract below — so the suite now
  fails if it is ever introduced.

### Changed

- **Worker prompt: output discipline.** A conciseness directive scoped to prose, summaries, and PR
  bodies — explicitly *not* to doing less work, since a worker that under-delivers to save words is a
  failed ticket and costs far more than it saves. A delegation **floor** opposite the existing ceiling
  ("don't delegate what you could finish in a few tool calls," because each sub-agent re-establishes
  context from scratch). And a return contract for sub-agents that cuts filler but forbids
  compressing code, commands, file paths, error text, or exact numbers.

### Upgrade notes

Nothing to do. Both new behaviours are on by default and degrade safely: `GOVERN_EXCLUDE_DYNAMIC_PROMPT=0`
disables the flag, and an older `claude` simply never receives it.

If you maintain your own copies of `templates/govern/test/*`, note that any test driving a fake
`claude` stub now needs `_GOVERN_EDP_SUPPORTED=1` in its env. A probe that invokes `$claude_bin`
otherwise consumes an invocation from stubs that don't implement `--help` — which is exactly how this
release's first CI run went red.

### Still not here

Automatic model/effort right-sizing remains unbuilt. A ticket's `Model:`/`Effort:` fields are still
the only thing that sizes a worker, and a ticket naming neither runs at `GOVERN_WORKER_MODEL`
(`opus`). This remains the largest unclaimed saving in the harness.

Hook-based output shaping was investigated and ruled out. A `PostToolUse` hook does fire and does
receive the real tool response in `claude -p` mode, but returning `updatedToolOutput` has no effect
on what the model sees (measured on CLI 2.1.220, reproduced twice). Bash-output capping and read
dedup are unbuildable on that path until that changes. The delivery path is proven and waiting:
`--settings <file>` plus `--setting-sources user` gives a worker exactly the hooks you choose with no
project-hook leakage.

## 1.12.0 — 2026-07-25

The cost-and-throughput release. v1.11.x shipped the *mechanism* for parallel execution; this one
ships the things that make a parallel run actually cheaper and safer — non-colliding workers,
bounded context growth, and a refusal to waste a whole fan-out on a broken baseline.

Everything here was sized against measured telemetry rather than argument. The two numbers that
drove the priorities:

- **Cache *writes* are ~32% of cost on ~4.8% of tokens** — writes price roughly 12.5x reads. Anything
  that keeps junk out of context is therefore paid for twice: once at write price immediately, and
  again on every subsequent turn at read price.
- **~16,500 new tokens are cached per turn**, against an average re-read context of ~130k tokens per
  turn. Context growth, not prompt size, is what a long worker session actually spends.

A note on units: on a subscription plan the binding constraint is **quota and wall-clock**, not
dollars. Improvements below are described in tokens and turns for that reason.

### Added

- **Locality batching** (#92), **opt-in**. When enabled, eligible tickets are partitioned into
  disjoint groups by the files they touch and one worker handles a whole group, so `--parallel=N`
  means N *groups* rather than N tickets. Two effects: concurrent workers stop colliding on the same
  file, and a group pays discovery — repo layout, conventions, the ~15k-token session-start cache
  write — **once** instead of once per ticket.

  **It is OFF by default.** `GOVERN_BATCH_MAX` defaults to `1`, which is exactly the previous
  one-ticket-per-worker behavior; set it above 1 in `scripts/lib/workspace.sh` to enable grouping.
  The conservative default is deliberate: grouping keys off a locality heuristic that has not yet
  been exercised on a real backlog, and a bad key would put unrelated work in one worker. Raise it
  once you have watched it group a run you can inspect.
- **Base-branch CI guard** (#95). The run-start preflight refuses to dispatch workers onto an
  unambiguously CI-red base branch. Measured motivation: two tickets in one wave each burned a full
  worker session producing correct code that could never go green, because the base was red at
  dispatch — under parallel-by-default a red baseline wastes the *entire* fan-out, not one ticket.
  Fail-**open** by design: absent CI, no auth, in-progress runs, and API errors all proceed exactly
  as before, so a fleet with no checks is unaffected. `GOVERN_SKIP_BASE_CHECK=1` opts out — for
  example when the ticket being worked *is* the CI fix.
- **Sizing decision recorded beside the cost** (#93). `ticket-history.jsonl` rows now carry `model`,
  `effort`, and `attempt` alongside the tokens and cost already logged, and usage is no longer lost
  on killed attempts. Previously you could see what a ticket cost but not which tier produced it,
  which made the data unlearnable — failures, the rows most worth studying, were also the ones
  most often missing usage.

### Changed

- **Worker context discipline** (#91). Three additions to the worker prompt, all targeting context
  growth: verbose commands are redirected and inspected in bounded slices rather than dumping full
  build/test output into context; every delegated subagent must be given an explicit **return
  contract** (an unbounded child reply defeats the delegation it was supposed to pay for); and local
  validation is scaled to the diff, so a docs-only change no longer triggers a full suite run whose
  output floods the session. The read path was already covered in v1.11.0 — the *run* path, which is
  the common case, was not.
- **Evidence-based retry escalation** (#94). A failed attempt is classified by failure signature
  instead of unconditionally re-betting at `GOVERN_WORKER_MODEL`. A CI failure caused by
  environment/portability retries at the **same** tier with the failing log injected; running out of
  token budget while still exploring means scope was underestimated and escalates; infrastructure
  errors retry identically without escalating at all. An unrecognized signature falls back to the
  previous escalate-always behavior.
- **Workers no longer load the slash-command surface** (#96). Measured: a worker's baseline context
  was ~33,000 tokens before its ticket prompt or any file read; `--disable-slash-commands` brings
  that to ~30,400 — roughly 2,600 tokens off *every turn*. Honest sizing: this is a ~2% lever, worth
  taking because it is a one-flag change with an opt-out (`GOVERN_WORKER_SLASH_COMMANDS=1`), not
  because it is transformative.

  Recorded so nobody retries them: `--allowedTools` does **not** shrink the prefix (it gates
  permission, not loading), and `--bare` fails without explicitly re-provided context and also skips
  hooks and LSP, so it is not a drop-in.

### Upgrade notes

Parallel execution remains the default from v1.11.1 (`GOVERN_PARALLEL_DEFAULT`, fallback 4), and
`--serial` still opts out per run. With locality batching, that default now fans out over disjoint
groups, so concurrent workers are substantially less likely to conflict than in v1.11.1.

### Still not here

Automatic model/effort right-sizing remains unbuilt — an unpinned ticket still runs at
`GOVERN_WORKER_MODEL` (default `opus`), and `GOVERN_WORKER_EFFORT` is inert unless set. A scout pass
that measures ticket scope and selects both knobs is tracked but deliberately not in this release:
tier selection mostly shifts list-price cost between models, and on a subscription plan its effect
on the binding constraint — quota — is far smaller than the raw price spread suggests.

## 1.11.1 — 2026-07-25

**Behavior change on upgrade — read this before updating.** Parallel backlog execution is now
genuinely the default. A workspace that has never set `GOVERN_PARALLEL_DEFAULT` goes from **one**
worker to **four concurrent** workers on its next plain `run-loop.sh` / `/govern` run. That
multiplies how much is in flight at once — it does not make any single ticket cheaper. If you are
rate-limited, or want a smaller blast radius, set `GOVERN_PARALLEL_DEFAULT=1` in
`scripts/lib/workspace.sh`, or pass `--serial` for a single run.

### Fixed

- **`GOVERN_PARALLEL_DEFAULT` was never actually wired, so 1.11.0 shipped serial.** The 1.11.0 notes
  stated twice that parallel execution was the default. That was wrong: `run-loop.sh` fell back to
  `1`, the seed template set `1`, and `--parallel=1` is documented as identical to `--serial`. Every
  1.11.0 install — new or upgraded — still worked one ticket at a time unless the operator passed
  `--parallel` by hand. The headline behavior of that release was inert. This release makes the
  claim true.

  The fallback in `run-loop.sh` (not just the seed template) is the load-bearing part:
  `/shiploop:update` deliberately **preserves** a workspace's `scripts/lib/workspace.sh`, so an
  already-installed fleet can never pick up a new default from a template bump. The fallback is the
  only path that reaches them.

### Precedence (unchanged)

An explicit `GOVERN_PARALLEL_DEFAULT` always wins over the fallback — including `=1`, which remains
the way to say "sequential, permanently". `--serial` opts out of any single run, and `--parallel=N`
still beats the env knob. Naming exactly one ticket stays sequential; there is nothing to fan out.

### Note on a reversed invariant

`test-run-loop-multi-target.sh` previously asserted that an unset knob stayed sequential, on the
principle that *"a template bump must never change an existing workspace's run shape."* That
assertion has been deliberately rewritten rather than removed, and the reasoning recorded inline.
The trade is explicit: silent-upgrade safety was given up so that already-installed fleets actually
receive parallel execution. Per-run and per-workspace opt-outs are preserved.

### Still not in this release

Parallel workers do **not** yet avoid collisions — two tickets touching the same file can be worked
concurrently and produce conflicting branches. Nor is model/effort right-sizing automatic: an
unpinned ticket still runs at `GOVERN_WORKER_MODEL` (default `opus`), and `GOVERN_WORKER_EFFORT` is
inert unless set by hand. Both are tracked and land in 1.12.0.

## 1.11.0 — 2026-07-25

The token-efficiency release: the harness now applies its own orchestration doctrine to the
**worker** session — where ~98% of a run's tokens are actually spent — instead of only to the
operator session. Adds two independent sizing knobs (model tier and reasoning effort), a
per-attempt token ceiling, and makes parallel backlog execution the default.

Motivating measurement: a resolved ticket was a ~22M-token worker session that was **98% cache
reads** — i.e. ~200+ turns of a context that grew all session, inside one monolithic agent that
explored, edited, built, tested and PR'd without delegating anything. The starting prompt was only
~7k tokens, so cost was turn count × accumulated context, not prompt size or model tier alone.

### Added

- **ROUTER POSTURE in the worker prompt** (#82). The per-ticket worker now delegates reconnaissance
  — multi-file investigation, sweeps, log reading — to cheap subagents and keeps only the verdict,
  with explicit child model-sizing guidance (haiku = mechanical/extract/lookup, sonnet =
  search/investigation, inherit only for judgment). Hard rule: **delegate reconnaissance, never
  delegate the commit, the PR, or the report write** — reconciled with the pre-existing constraint
  that a subagent runs under a restrictive policy and cannot persist the evidence report.
- **Per-attempt token budget** (`GOVERN_WORKER_MAX_TOKENS`, #84). Previously the only ceiling on a
  worker was a 3600s wall clock, so a wandering attempt could burn tens of millions of tokens before
  anything stopped it. Exceeding the budget hard-kills the process tree and records a **distinct
  `budget-exceeded` outcome** — deliberately not `timeout`, because "ran out of room while still
  exploring" is the signal an escalation policy needs. Default `0` (unlimited) preserves existing
  behavior.
- **Reasoning effort as an independent sizing knob** (`GOVERN_WORKER_EFFORT`, ticket `Effort:` field,
  `file-ticket.sh --effort`, #86). Model tier and reasoning effort are separate controls; the harness
  previously set only the tier, leaving no rung between "sonnet" and "opus at several times the price
  on the dominant cache-read line". Raising effort is far cheaper than raising tier, so it is the
  correct first rung on an escalation ladder. Unset means no flag is passed at all — no invented
  default.
- **Full-driver parallel backlog mode** (`--parallel[=N]`, `--serial`, `GOVERN_PARALLEL_DEFAULT`,
  #87). Children run the **whole backlog loop** rather than a single explicit ticket, which is what
  keeps the governor's gates alive: a child handed one explicit ticket is indistinguishable from an
  operator typing `run-loop.sh <N>` and silently inherits every explicit-target bypass — the
  dependency gate, the cross-driver re-verify, and the failure-streak circuit breaker — and can never
  reach the periodic supervisor.

### Changed

- **Supervisor reviews run history incrementally** (#83). Each pass previously re-sent the entire
  `state.jsonl` plus up to 500 lines of open ticket blocks; at the default cadence a 20-ticket run
  paid that four times over steadily growing input. Now each pass reads only what was appended since
  its own previous pass, carrying its prior verdict forward as the compressed summary of everything
  before — lossless, without the re-send.
- **Supervisor tail flush + one whole-run review under parallel** (#89). With N concurrent drivers
  each tracking its own review counter, the periodic supervisor's effective global cadence loosened
  by roughly the fan-out factor — a 12-ticket run split across 4 drivers could fire it zero times
  where a sequential run fired it twice — and no supervisor ever saw the run as a whole.
- **Worker prompt hygiene** (#85). The ticket block moved to the end of the prompt so the stable
  boilerplate forms a cacheable prefix; the redundant instruction to re-`Read` the already-auto-loaded
  root `CLAUDE.md` was dropped; duplicated validate-locally and branch-naming rules collapsed to one
  authoritative mention each.

### Fixed

- **Dependency scan anchored to the declared marker line** (#88). `govern::ticket_deps` harvested
  `#N` references out of ordinary prose, so a ticket that merely *mentioned* other tickets could
  become hard-gated on them by the pre-spawn dependency gate. Now only the line that actually starts
  with the `**Depends on:**` marker is read.
- **Run-start reconcile runs once per run, not once per driver** (#90). With parallel execution on
  by default, every child driver independently re-ran the whole run-start preflight — including a
  `git fetch`/rebase/push against the same meta checkout, serialized by nothing (the bookkeep lock
  covers only `tickets.md` edits). The exposure predates this release — the hand-launched
  multi-terminal recipe had the identical property — but parallel-by-default moved it from
  occasional to routine.

### Upgrade notes

- **Parallel execution is now the default.** `GOVERN_PARALLEL_DEFAULT` in `scripts/lib/workspace.sh`
  sets per-workspace concurrency; `--serial` opts any single run back out. Runs that depend on a
  strict sequential pick ORDER should pass `--serial` explicitly.
- `GOVERN_WORKER_MAX_TOKENS` and `GOVERN_WORKER_EFFORT` both default to preserving existing
  behavior (unlimited / no effort flag), so upgrading changes nothing until you set them.

## 1.10.0 — 2026-07-19

The validation-sink relocation release: the governor-owned validation sink moved out of the
co-tenant `.claude/context/` namespace to a dedicated `.claude/shiploop/validation/`, plus a
hand-port of the live-forward governor mechanisms from the reference instance.

### Added

- **Live-forward governor mechanisms ported from the reference instance** (#387 hand-port). The
  automated porter escalated because the drift is bidirectional — the templates are ahead on some
  files while the reference instance carries forward-improvements interwoven in the same files — so
  this is a surgical per-mechanism port: additive, genericized, and scoped to the listed mechanisms
  only (the template-only `harness_repo_slugs`/`is_harness_repo`/`harness_pr_verify` are preserved).
  - **Single `GOVERN_PROTECTED_PATTERNS` SSOT** in `common.sh` — self-apply and improve-triage now
    source it instead of each carrying its own list. Adds `_ndjson_validate`, and the escalations
    parser now requires the `— ` title separator and jq-validates every emitted object, so a `### #N`
    body reference no longer starts a spurious entry.
  - **`govern::sync_port_collision_tickets`** — excludes tickets touching a file that has an OPEN
    sync-port escalation; wired into `select-ticket.sh`.
  - **Implicit ticket dependencies** — `ticket_deps` now honors a blocker's `**Blocks:** #N` line,
    plus `govern::prose_dep_warnings`; wired into `lint-tickets.sh`.
  - **`govern::pull_rebase_autostash`** — recovers the rc-0-but-unmerged overlapping autostash-pop
    wedge; call sites switched in `commit_meta_to_main` and `govern-bookkeep.sh` (pre-edit sync +
    push-CAS retry).
  - **Co-tenant-safe commits** — `preflight-main.sh` and `escalations-apply-answers.sh` commit ONLY
    governor paths via pathspec, never a bare `git commit` that could sweep co-tenant staged WIP.
  - **`scaffold.sh` settings-merge is now per-hook** — each hook is checked and appended
    individually per event, so a newly-introduced hook (e.g. `validations-pending-hook.sh`) lands on
    an existing install even when a sibling hook is already wired (previously the whole event was
    skipped). Still idempotent.
  - `spawn-worker.sh` PR footer prefix → "🤖 shipped by".
  - Coupled tests ported alongside: `test-escalation-body-ref`, `test-lint-prose-deps`,
    `test-bookkeep-overlap-autostash-pop`, `test-select-ticket`, `test-pending-waits`,
    `test-update-channel`.

### Changed

- **A parallel run performs the run-start reconcile exactly once, not once per driver.** The run-start
  block — `escalations-apply-answers.sh` → `escalations-emit-pending.sh` → `preflight-main.sh` →
  `externalize-low-tickets.sh`, plus the NA-skip streak bookkeeping — is whole-run state
  reconciliation against the **one** shared meta checkout, and `preflight-main.sh` does
  `git fetch` / `pull --rebase` / `push` on it. Since parallel became the default, the orchestrator ran
  that block and then spawned N full backlog drivers that each re-ran all of it against the same
  checkout, concurrently: nothing serialized them (the bookkeep lock only covers `tickets.md` edits),
  and `GOVERN_PARALLEL_STAGGER_S` only narrowed the collision window. The orchestrator already
  reconciles once while holding the single-run lock, so each child is now spawned with a new
  **internal `--orchestrated` flag** and skips the block, logging one auditable
  `run-start reconcile: skipped` line. One reconcile per run is both correct and cheaper; a
  `--serial` / top-level driver is unaffected (it still reconciles itself), and the stagger stays for
  what remains genuinely concurrent (selector + claim locks + worktree creation). Never pass
  `--orchestrated` by hand — a driver run with it reconciles nothing. New test
  `templates/govern/test/test-parallel-run-start-reconcile.sh` locks it against a **real**
  origin-backed checkout: one `preflight: published` line + one skip line per child + `origin/main`
  actually reconciled on a 2-driver fan-out, the serial baseline still reconciling, and — under an
  enter/exit-recording preflight stub — exactly one entry and **zero overlaps** across a 3-wide
  fan-out (pre-fix: one entry per driver, with a recorded overlap).

- **The supervisor no longer skips a driver's tail, and a parallel run now gets one whole-run review.**
  `GOVERN_SUPERVISOR_EVERY` counts resolved tickets *per driver* (`since_review` is a shell variable in
  each driver process), so a driver that ends holding 1..`SUP_EVERY`-1 unreviewed resolves never
  reviewed them. Sequentially that tail is a rounding error; under `--parallel` it was the whole run —
  a 12-ticket backlog split 3-per-driver across 4 drivers reached the periodic pass **zero** times,
  where the same 12 worked sequentially fired it twice, and no supervisor ever saw the run as a whole
  (each child reviews only its own run dir). Two out-of-loop passes close both gaps:
  - a **run-tail flush** — one pass per driver at end-of-loop when `since_review > 0` (skipped on an
    infra/auth halt);
  - a **whole-run pool review** — one pass in the `--parallel` orchestrator over the *aggregated*
    `state.jsonl`, after every child is reaped.

  Both are **on by default** — this is a defect fix to an always-on mechanism, not a new lane, so a
  bump does change the review rhythm (and adds roughly one supervisor call per driver plus one per
  parallel run). **`GOVERN_SUPERVISOR_FLUSH=0` restores the previous periodic-only behaviour.** The
  per-driver cadence itself is deliberately unchanged: N drivers each firing every `SUP_EVERY` of their
  own resolves already totals ≈ K/`SUP_EVERY` passes over K tickets, so scaling the cadence down by the
  fan-out would over-fire by ~N× on a long run. Neither out-of-loop pass needs the in-loop verdict
  handling lifted out — at run-end only `concerns` are still actionable, since `skipThisRun` /
  `attemptNext` / `waitForMerge` / `halt` all steer a selection loop that has already finished. New
  test `templates/govern/test/test-supervisor-cadence-parallel.sh` pins the counts (sequential 6 @
  `SUP_EVERY=5` → 2 passes; the same 6 across a 2-driver fan-out → 3, split-independently) and the
  `GOVERN_SUPERVISOR_FLUSH=0` opt-out. Rationale documented in `commands/govern.md`.

- **`--parallel` backlog mode now fans out into N FULL backlog drivers, plus a `--serial` flag and a
  `GOVERN_PARALLEL_DEFAULT` workspace knob.** Previously a `--parallel` backlog pull picked the top-N
  eligible tickets, ran one single-ticket child per ticket, and exited — so it worked at most N
  tickets per run, and each child (being handed one explicit ticket) took the same bypasses
  `run-loop.sh <N>` deliberately takes: the dependency gate (#119), the cross-driver re-verify, the
  #60 failure-streak auto-escalation, the periodic supervisor cadence and its `attemptNext` priority
  queue were all skipped or never reached. A backlog pull now spawns N children that each run the
  ordinary sequential loop over the whole queue, contending on the per-ticket claim lock — the
  "launch N terminals" recipe, automated — so every one of those mechanisms keeps working, and the
  run grinds the WHOLE backlog N at a time instead of stopping after N tickets. An explicit ticket
  SET still fans out one single-ticket child per named ticket (unchanged).
  - `--serial` (alias `--no-parallel`) forces one-at-a-time. A resolved cap of 1 from ANY source
    (`--parallel=1`, `GOVERN_PARALLEL=1`, the knob) now collapses to the sequential driver instead of
    an orchestrator-of-one, which in backlog mode would have pulled a single ticket and quit.
  - `GOVERN_PARALLEL_DEFAULT` (new, `scripts/lib/workspace.sh`, **default `1` = sequential**) sets
    the concurrency of a plain `run-loop.sh` with no flags. Existing workspaces are unaffected until
    they set it; `N > 1` costs N× the spend, so it is a deliberate opt-in. Precedence is `--serial` ›
    `--parallel=N` › bare `--parallel` › `GOVERN_PARALLEL=N` › `GOVERN_PARALLEL_DEFAULT`.
  - **Fork-bomb fix:** children are now spawned with `--serial` and a cleared `GOVERN_PARALLEL`.
    Under `GOVERN_PARALLEL=4 run-loop.sh` a child inherited the env, resolved to parallel mode for
    its own ticket, became an orchestrator and spawned a grandchild — unbounded, and reachable on the
    shipped code.
  - The orchestrator now folds every child's `state.jsonl` rows into its OWN run dir and emits the
    same canonical `DONE — resolved=… parked=…` line the sequential path ends on, so a run dir stays
    the single place to read what a run did regardless of fan-out shape.
  - Backlog fan-out is sized to the eligible ticket count (never 4 drivers for a 1-ticket queue) and
    launches are staggered by `GOVERN_PARALLEL_STAGGER_S` (default 2s) so N drivers don't run the
    run-start git preflight against the same meta checkout in the same instant.
  - Coverage: `test-run-loop-multi-target.sh` gains the full precedence matrix, the "5 tickets at cap
    2 → all 5 processed" whole-backlog proof, and the full-driver fan-out assertion.
  - Note the hard bounds (`GOVERN_MAX_TICKETS`, `GOVERN_MAX_BAD_STREAK`, `GOVERN_MAX_RUNTIME`) are
    PER DRIVER, so a parallel backlog run's ceiling is N × `GOVERN_MAX_TICKETS`. It still always ends.

- **Validation sink relocated to `.claude/shiploop/validation/`.** The flow registry
  (`flows.md`), its evidence tree (`evidence/`), and the #252 promoted validation summaries now all
  live under `.claude/shiploop/validation/` instead of the root-level `validation/` + the co-tenant
  `.claude/context/validation/`. This keeps the governor-owned, git-tracked sink outside the
  `.claude/context/` namespace a co-tenant tool (e.g. vibelab) may sweep, so a governor commit no
  longer needs a per-path exclusion to avoid clobbering co-tenant WIP.
  - Every citing mechanism was repointed: `govern/lib/flows.sh` (`FLOWS_FILE`/`FLOWS_EVIDENCE_DIR`
    defaults), `govern-bookkeep.sh` (summary promotion path), `spawn-worker.sh`, `flows-*.sh`,
    `doctor.sh`, the worker prompt, the Stop-hook sweep reminder, and `commands/flows.md`.
  - `lint-validation-refs.sh` now scans BOTH `.claude/context` and `.claude/shiploop` as citation
    sources and flags any surviving `.claude/context/validation/*.md` reference as dangling, so a
    stale ref after the move fails the Stop-hook lint rather than passing silently.
  - `scaffold.sh` seeds the registry at `.claude/shiploop/validation/flows.md` (seed source moved to
    `templates/seed/.claude/shiploop/validation/flows.md`).
  - **Migration:** an existing workspace converging past this version must `git mv` its sink once —
    see the one-time step in `/shiploop:update` (Phase 3).

## 1.9.0 — 2026-07-11

The durable-validation-runner release: the harness's first durable-job primitive (jobs that survive
session caps and structurally cannot orphan a billable resource), plus native parallel ticket
execution in run-loop, plus the one-pause setup interview.

### Added

- **Durable validation runner — core launcher + job substrate.** Long, billable validation flows
  (deploy → provision → verify classes, 45-60 min) can now run as durable jobs:
  - `templates/govern/run-validation.sh` — `setsid`-detached launcher: returns a job-id
    (`val-<flowid>-<ts>`) immediately, exports `VAL_JOB_ID` so every deploy the flow creates is
    name-tagged, enforces a `GOVERN_VAL_TIMEOUT` wall cap (kills the job's process group and writes
    terminal `ERROR` — durable ≠ immortal), and prunes terminal job dirs on a retention window.
  - `templates/govern/lib/valjob.sh` — the substrate the runner and future fleet supervision share:
    a `deploys.jsonl` manifest written *before* provisioning (a box is trackable even if the job
    dies one line later), a runner-owned heartbeat (~30s, process liveness — not script
    cooperation), a sticky reap-tombstone check at every phase boundary (tombstoned job → terminal
    `ABORT`, touches nothing), and a deterministic orphan verdict exposed as data for the
    workspace-wired `GOVERN_DEPLOY_SWEEP_CMD` — the hub never closes resources itself. (#76)
- **Pending-results delivery + live-jobs surface.** A job's terminal record appends an atomically
  written pending-result entry consumed exactly-once (bookkeep mutex) by any of three readers — the
  governor supervisor, the SessionStart hook, or `flows status` on demand — so result delivery never
  depends on a governor happening to be live when the job finishes. The live surface lists job-id,
  phase, deploy-ids, and heartbeat age. (#78)
- **`govern::flows_stamp` terminal-verdict entry point.** The runner deterministically stamps
  `validation/flows.md` (Status / Validated repo@sha pins / Evidence pointer / Env) through
  `cas_edit` under the bookkeep mutex — safe against a concurrent governor run writing the same
  registry. (#75)
- **run-loop ticket sets + `--parallel[=N]`.** `run-loop.sh 152 153 154 155` now works — multiple
  numeric args previously kept only the LAST one silently — and `--parallel` fans the target set
  out over N concurrent single-ticket drivers on the existing per-ticket claim-lock + bookkeep-mutex
  machinery (`GOVERN_PARALLEL` is the env equivalent; the flag wins). (#73)
- **Workspace README generated on setup** — new workspaces get a landing page describing the
  harness layout.
- **`worktree:new --base <branch>`** + tolerance for a forwarded `--` from PM arg-passing. (#71)

### Fixed

- **Flow-block parser, lint, and Stop hook are comment-aware.** `govern::flow_ids` no longer parses
  `## <id>` headings inside multi-line `<!-- -->` HTML comments — the scaffolded example flows were
  linted as real flows, their placeholder globs tripped the zero-match FAIL, `flow_set_field`
  mutated `Status:` *inside* the comment blocks, and the Stop hook blocked every session end with a
  misattributed missing-evidence message. Regression tests cover the parser, the lint, and the Stop
  hook path. (#74, #77)
- **Harness PR adoption under `set -e`** — `collect_ticket_prs`' harness re-scan no longer aborts
  callers; duplicate-ticket flagging hardened. (#74)
- **Worker PR footer** now reads "PR shipped by shiploop".

### Changed

- **Driver-context hygiene is a documented anti-pattern.** The driver session never reads product
  source — it dispatches fixes to workers and relays verdicts (seed `CLAUDE.md` + `SKILL.md`). (#72)

- **Setup interview: ONE pause instead of six.** A live wrap-in-place onboarding paused six separate
  times over ~8 minutes (proceed? → config batch → more config → mid-wrap `NEEDS-CONFIRM` → remote?
  → install?), forcing the operator to babysit the run. `/shiploop:setup` now follows an explicit
  interview doctrine: detect EVERYTHING first (repos, ports, dev commands, org, root PM, worktree
  base, repo visibility), surface every wrap confirm-item up front via the new read-only
  `wrap.sh --preflight` mode, then ask everything in a SINGLE batched `AskUserQuestion` call — and
  run to completion without pausing. The root-remote choice, `install + doctor`, the starter ticket,
  and auto-externalization are all collected in that one batch; wrap.sh exit-5 mid-run is now a
  "should not happen" fallback rather than a guaranteed stop. Phase Z gains a `Decisions:` recap line.

- **Setup machine time: one-shot detection + sonnet.** Excluding user-wait, the same onboarding
  spent ~7 min on model round-trips vs ~30 s in actual tool execution — a bash probe per detected
  value (port, lockfile, org, visibility…) each costing a full opus turn. Detection is now ONE
  deterministic call (`templates/lib/detect-inputs.sh`, below) and setup.md's frontmatter drops
  from `model: opus` to `model: sonnet` — justified because every judgment-heavy step is delegated
  to guarded scripts (detect-inputs.sh, `wrap.sh --preflight`/`--yes`, scaffold.sh) with explicit
  exit codes, leaving the command pure orchestration.

### Added

- **`govern::flows_stamp` (durable validation runner, spec §5).** A runner-facing entry point over
  the existing `govern::flows_stamp_from_report`: takes a flow id, a settled terminal verdict
  (`PASS`/`FAIL`), and a `{pr, prs, validation}` record — translates `PASS`→resolve / `FAIL`→gate-park
  and reuses every existing guard (never-overwrite-fresher, ancestor-verify + squash-merge
  substitution, PII-park, evidence promotion under `validation/evidence/`, `cas_edit` under the
  bookkeep mutex) verbatim. `ABORT`/`ERROR` refuse to stamp (rc 1) — they carry no settled verdict
  and route to the pending-results escalation path instead. Lets the durable validation runner
  (once its job substrate lands) stamp the registry directly from a job's terminal record with no
  report.json/ticket-resolve context required. Covered by the new
  `test-flows-stamp-terminal.sh` (PASS/FAIL mapping, ABORT/ERROR refusal, exact-block isolation in a
  multi-flow registry, and a stamp racing a concurrent registry edit through the real CAS-retry path).
- **`detect-inputs.sh` (one-shot interview defaults).** Emits every setup default in a single
  call — `root_pm`, `worktree_base`, `org`, one `repo=<name>|<port>|<cmd>|<visibility>` line per
  sub-repo (ports de-collided to stable distinct values, dev command from lockfile/Makefile/
  Cargo.toml/go.mod signals, visibility `unknown` when `gh` is absent), plus a ready-to-pass
  `repos_spec=`. Setup-time tool like wrap.sh (templates/lib/, not installed into workspaces).
  Covered by the new `test-detect-inputs.sh` (19 assertions: collisions, lockfile signals,
  origin-vs-folder naming, arg errors).
- **`wrap.sh --preflight` (read-only).** Runs only the preflight checks — same exit codes (0/3/4/5)
  and the same `NEEDS-CONFIRM[--confirm-x]` lines, nothing moved or written; only `--name` required.
  This is the seam that lets setup fold every confirm-item into its single upfront interview.
  Covered by a new section 7 in `test-wrap-in-place.sh` (exit 5 list / exit 0 untouched-layout /
  hard-refusal and collision surfacing).

## 1.8.0 — 2026-07-08

The public-surfaces release: what outsiders see of a shiploop-run repo is now deliberately curated. Neutral `sl-<12hex>` branch names and zero internal ticket-ids on public-repo PRs (guards fully intact for private repos), and the externalization lane no longer publishes on your behalf — eligible tickets stage into a review queue behind ONE approve-all / decide-later / move-back questionnaire, with `Externalize: never` as a permanent per-ticket veto. Plus the five README staleness fixes.

### Added

- **Public-repo PR hygiene (no internal ticket-ids on public PRs).** On a repo that is public, a
  worker now names its branch with a neutral, deterministic `sl-<12hex>` token (`govern::neutral_branch`)
  instead of `ticket-<N>`, and is instructed to keep the internal ticket id out of the PR title, body,
  and commit subjects — an outsider can no longer infer a private tracker from the branch name. The
  neutral name is a stateless function of the ticket number, so the governor still discovers, tracks,
  and merges the PR (`find_pr`/`find_all_prs` match it alongside `ticket-<N>`). Repo visibility is set
  explicitly by the new **`GOVERN_PUBLIC_REPOS`** knob (space-separated short names; wins over
  detection) or auto-detected via `gh repo view` (cached once per run); a lookup failure is treated as
  **private** so an API hiccup never changes a private repo's branch mechanics. The three-factor
  auto-merge guard accepts the neutral branch **only** for public repos — the private-repo branch
  pattern is unchanged, so the guard is never weakened — and the `.githooks/pre-push` sanctioned-branch
  check accepts `sl-<12hex>` under `GOVERN_RUN`. The existing PR title/body scrub remains the
  unconditional backstop for both cases.
- **Externalization review gate (staged, operator-approved).** The externalization lane no longer
  auto-files public issues. Each run now **stages** eligible Low tickets out of `tickets.md` into
  `queue/tickets-externalize-review.md` and files ONE escalation questionnaire (Kind:
  `externalize-review`, deduped so exactly one is ever open) with three dispositions: **approve-all**
  files every staged ticket as a public issue and de-stages it; **decide-later** leaves them staged and
  re-nudges next run; **move-back:&lt;ids&gt;** returns the listed tickets to `tickets.md` stamped
  `**Externalize:** never` (honored by `govern::externalize_candidates`, so they never re-stage) while
  the rest stay staged. Dispositions are wired through `escalations-apply-answers.sh` (mirroring the
  flows `kill` path): the tokens are added to `govern::norm_disposition` **last and kind-gated**, so the
  generic do-the-work/defer/mitigated lifecycle cannot regress, and the queue edits are published by
  apply-answers' single atomic commit. Idempotence + partial-failure heal (the `externalized.md` ledger)
  and dry-mode inertness are preserved. `externalize-low-tickets.sh` gains `--approve` / `--move-back`
  modes; `file_open_escalation` gains optional Kind + disposition-hint args; `record-escalation-answer.sh`
  accepts the new tokens.

### Fixed

- **README/SKILL staleness.** Documented `/shiploop:flows` in the Commands table and corrected the
  slash-command count (six → seven); added `GOVERN_AUTONOMY` and `WSP_PR_FOOTER` to the opt-in knobs
  list; rewrote the "Trust and cost" ladder to match `GOVERN_AUTONOMY`'s real mechanics (`observe` runs
  real workers that open **draft** PRs — distinct from the separate `--dry-run` flag — and `auto`
  requires both `GOVERN_AUTONOMY=auto` *and* `GOVERN_MERGE_REPOS` membership); corrected the Act 1
  `/shiploop:flows file` gate description (dry-by-default + `--yes`, `--max-deploys N`, and the
  `GOVERN_DEPLOY_SWEEP_CMD` precondition on batch modes — not a generic "spend cap"); fixed the seed
  Components row (`CLAUDE.md`/`learnings.md` install at the workspace root, `tickets*.md` under
  `queue/`, `flows.md` under `validation/` — not all under `queue/`). Mirrored the `GOVERN_AUTONOMY`
  fix into `SKILL.md`'s governor section.

## 1.7.0 — 2026-07-07

The onboarding release: run setup inside your existing repo and shiploop wraps it in place — no empty-parent ritual. The transform is a single trap-guarded script with fail-closed preflights (linked worktrees, absolute git configs, escaping symlinks, cloud-sync roots), a manifest-based undo written before anything moves, and byte-identical post-move verification.

### Added

- **Wrap-in-place setup.** `/shiploop:setup` run *inside* an existing git repo now offers to wrap it
  in place instead of demanding the empty-parent ritual: the repo's contents move into a subfolder
  (`<name>/`) of the same path and the shiploop workspace scaffolds where the repo used to be, so the
  path you `cd` into stays stable (shell history, IDE recents, and Claude Code's path-keyed session
  identity all survive). Quickstart is now literally `cd your-project && /shiploop:setup`; the
  fresh-folder flow is demoted to the multi-repo / clean-start variant.
  - The transform is ONE trap-guarded script (`templates/lib/wrap.sh`) invoked in a single call —
    never a model-driven sequence of moves. Preflight is entirely fail-closed (clean tracked tree; no
    in-progress merge/rebase/cherry-pick/bisect; `.git` must be a directory; no linked worktrees; no
    stranding absolute-path git config — `core.worktree`/absolute `core.hooksPath`/`includeIf gitdir:/abs`,
    incl. submodule configs, read RAW so a poisoning `core.worktree` can't hide; escaping root symlinks;
    single-filesystem + cloud-sync guard; nested-repo guard; pre-existing wrap-artifact guard;
    case-insensitive name-collision; live-writer + `git maintenance` warnings). The move is rename-only
    (never copy), enumerated explicitly (never `mv * .*`), and verified **byte-identical** afterwards
    (HEAD, branch, `git status --porcelain` snapshot, and submodule SHAs). A `trap` rolls the layout
    back on any failure or `SIGINT`, and a manifest-based `.wrap-undo.sh` (written first, removed only
    after the full end-to-end verify) reverses even a completed scaffold without clobbering the user's
    same-named files.
  - Setup entry now dispatches on `wrap.sh --detect` (six-row table: fresh / upgrade / wrap /
    refuse-gitfile / refuse-below-root / refuse-bare). New shared interview additions in both modes:
    the autonomy rung (`GOVERN_AUTONOMY`: observe / pr-only / auto), "what else belongs to this
    product?" extra-repo cloning, and opt-in auto-externalization when a registered repo is public.
- **`doctor` + `config-check`: "root has no remote" is now a first-class status line** — a
  wrap-in-place scaffold that skips creating a root remote silently disables the governor's CAS ticket
  pushes and cross-driver ticket sync, so both surfaces call it out (config-check also exposes
  `root_remote` in `--json`) instead of burying it.

## 1.6.0 — 2026-07-07

The self-maintenance release: a full-harness adversarial audit fixed 23 findings across the sync, update, and governor mechanisms (remediation batches — N1–N17, K1–K6), a new **validation-flow registry** landed end-to-end (`validation/flows.md` + verdict pipeline + staleness sweep + `/shiploop:flows` extract/list/file + long-horizon effectiveness gates and the kill loop, Phases 1–5), the contribution channel gained the **auto-fork funnel** (#45) and the queue-isolation rule (#46), and onboarding was rebuilt around time-to-first-magic: extract-first quickstart, the **trust ladder** (`GOVERN_AUTONOMY`: observe → pr-only → auto, new workspaces start pr-only), a starter ticket at setup, per-run cost transparency, and the opt-out PR footer. Nearly every change in this release was implemented, validated, and merged by the harness's own agent pattern.

### Added

- **push v2 — the auto-fork contribution funnel (#45).** `/shiploop:push` (via `sync-port.sh`) no longer
  dead-ends adopters without push access, and no longer strands the PR inside the operator's fork. The
  push + PR step now derives the access posture from **git + GitHub** (not workspace config): it reads the
  templates clone's `origin`, resolves the **canonical hub** as that repo's `parent` (falling back to
  `origin` when there is no parent), and checks push permission — so the PR **always** targets the real
  hub. Three postures: **direct-access** (push to origin, same-repo PR — historical, unchanged),
  **fork** (origin is the operator's fork → push there, open a **cross-repo** PR `<you>:<branch>` against
  the hub), and **plain-clone** (no push access → `gh repo fork --clone=false` creates the fork, the
  branch is pushed there, and a cross-repo PR opens against the hub — no manual fork step). GitHub
  un-resolvable (offline / non-GitHub remote) **degrades safely** to the historical direct-to-origin push;
  the fork funnel is taken ONLY on an affirmative no-push signal, never an unknown one. The real `git push`
  honors `GOVERN_NO_PUSH`. `commands/push.md` documents the three postures and drops the manual-fork
  precondition. New hermetic regression `templates/govern/test/test-sync-port-fork-funnel.sh` covers all
  four paths (direct / fork / plain-clone / unknown-perm) with gh+git stubs.
- **Flow-registry long-horizon + kill loop + capability adapters + passive evidence (validations feature,
  Phase 5 — the final phase).** Closes the effectiveness/deletion half of the design:
  - **Kill loop (INEFFECTIVE → TOMBSTONED).** `common.sh` `govern::norm_disposition` learns a `kill`
    disposition; `run-loop.sh` adds `kill` to a gate-failed FLOW ticket's escalation options so it is
    discoverable end-to-end; `escalations-apply-answers.sh` acts on `kill` — marks the flow kill-pending
    (`govern::flows_mark_kill_pending`, so `list`/health show it in flight and the Phase-3 sweep can
    auto-withdraw it if the flow goes STALE first) and files a normal removal ticket via `file-ticket.sh`
    `--flow <id> --flow-op remove`; `govern-bookkeep.sh` pre-captures `Flow-op:` (`govern::ticket_flow_op`)
    and on the removal ticket's resolve TOMBSTONES the flow (`govern::flows_tombstone` — Status→TOMBSTONED,
    history preserved, `SupersededBy` reserved for supersession not a plain kill) instead of stamping a verdict.
  - **Capability adapters (generic — knob NAMES in the template, VALUES only in `workspace.sh`).**
    `govern::flow_cap_knob` / `flow_missing_caps` / `flow_missing_cap_blocker` map a flow's `Requires:`
    capabilities (`browser`→`WSP_BROWSER_CMD`, `analytics`→`WSP_ANALYTICS_QUERY_CMD`,
    `test-account`→`TEST_USER_EMAIL`, `deploy`→`GOVERN_DEPLOY_SWEEP_CMD`) to their env knobs; `flows-file.sh`
    degrades a flow requiring an UNSET knob to BLOCKED with the named blocker (anti-pattern #15) instead of
    queuing a runnable-then-billable ticket.
  - **Passive evidence + due advisories (surfaced, NEVER auto-filed — billable safety).** `flows.sh`
    `govern::flow_analytics_query` (generic `$WSP_ANALYTICS_QUERY_CMD <source>` read, rc 2 unwired),
    `govern::flows_passive_evidence` (a wired analytics adapter + a flow's `Usage-source:` → "0 usage"
    INEFFECTIVE-leaning advisory; `--attach` records a `Passive-note:`, never a Status/Disposition stamp),
    `govern::flows_due_advisories` (MEASURING `Sample-window:` elapsed + `Revalidate: every Nd` past-due).
    `run-loop.sh` surfaces all three as advisory lines in the periodic supervisor pass (logged + appended
    to the run review) — the arm→collect split's collect nudge, filing stays a human act.
  - Tests: `test-flows-kill-loop.sh` (norm_disposition kill, `--flow-op remove` field, `ticket_flow_op`
    parse, `flows_tombstone`, `flows_mark_kill_pending` + sweep auto-withdrawal, apply-answers kill →
    removal-ticket + validation-ticket-closed, bookkeep Flow-op:remove → tombstone),
    `test-flows-capabilities.sh` (cap→knob map, missing-cap detection/blocker, flows-file BLOCKED gate,
    unknown-key ignored), `test-flows-passive-advisories.sh` (analytics rc 2 unwired, passive 0-usage
    advisory + never-stamps + `--attach` note, MEASURING-window + Revalidate-due lines, no-registry no-op).
- **`/shiploop:flows` command UX (validations feature, Phase 4).** The operator surface over the flow
  registry — the model orchestrates + inventories, but every registry write goes through a script (bash
  owns bookkeeping under the governor lock):
  - **`commands/flows.md`** (hub global, defer-to-local preamble) + **`templates/.claude/commands/flows.md`**
    (workspace-local copy); frontmatter `allowed-tools: Bash, Read, Agent`.
  - **`flows-extract-merge.sh`** — merges a STAGED extraction diff (an Agent fan-out inventory) into the
    registry: ADDs new flows + REFRESHes Paths/Surface on existing ones, but never touches verdict state
    (Status/Validated/Disposition) and FLAGS a Kind/Gate change on an existing id for a manual decision,
    never auto-applying it. DRY without `--approve` — a hallucinated flow can't silently become a
    fileable, later-billable row.
  - **`flows-list.sh`** — the registry grouped by status (BLOCKED shows its blocker, MEASURING its
    window); read-only by default with a dry "would go STALE" annotation, `--sweep` to record the degrades.
  - **`flows-file.sh`** — the spend gate: DRY by default (files nothing without `--yes`), Resource-group
    batching (N flows → one ticket, one deploy), BLOCKED exclusion + in-flight-ticket guard, `--all-*`
    refusal without `GOVERN_DEPLOY_SWEEP_CMD`, cheapest/fastest-first ordering + `--max-deploys N`,
    slow-provision flagging near `GOVERN_WORKER_TIMEOUT`.
  - Tests: `test-flows-command.sh` (extract ADD/REFRESH/FLAG incl. Kind-change-not-applied + verdict
    state untouched, list grouping/blocker/window, file precondition-refusal/grouping/in-flight-guard/
    BLOCKED-exclusion/dry-vs-yes/max-deploys).
- **Flow-registry staleness sweep (validations feature, Phase 3).** Makes "validated" mean "validated
  at the current code state" — a flow degrades to STALE the moment any mapped path moves past the SHA it
  was validated at:
  - **`flows.sh`** — `govern::flows_sweep_file` (per-sub-repo `git log <pinned-sha>..origin/main -- <globs>`
    degrade of the staleable statuses PASS/FAIL/EFFECTIVE/INEFFECTIVE; MONOTONIC missing-repo semantics —
    a change in any present mapped repo stales even if another is missing, only "no present change + a
    missing/unpinned repo" leaves the status untouched with a warning, never silently fresh; negatives
    stale too; a pending `kill` Disposition on a freshly-stale flow is auto-withdrawn — a stale negative
    must not be acted on), `govern::flows_sweep` (persisting sweep via `cas_edit`), `govern::flows_sweep_scan`
    (report-only dry scan), `govern::flows_status_summary` (the doctor/health count line),
    `govern::flows_matching_paths` + `govern::flow_glob_prefix` (path→flow overlap ranked most-specific-first).
  - **`spawn-worker.sh`** — a NON-validation ticket touching paths mapped by a validated flow now gets a
    context-flat ONE-LINE "flows your change may STALE" heads-up (never full blocks; silent when nothing
    overlaps), complementing the Phase-2 full-block injection for validation tickets.
  - **`hooks/ticket-sweep-reminder.sh`** — a soft, never-blocking session-end advisory ("this session
    staled N flows"), folded into the reconcile reason; a cheap report-only dry scan (no writes, no network).
  - **`doctor.sh` / `govern-health.sh`** — a flow-registry status-count line
    (`flows: N total · … PASS-fresh · … STALE · … pending-disposition`).
  - Tests: `test-flows-sweep.sh` (degrade, no-false-STALE, negatives, non-staleable exclusion, missing-repo
    monotonicity, kill-withdrawal, dry scan, status summary, path-match ranking), `test-flows-spawn-stale-note.sh`
    (one-line heads-up on overlap, silence on no overlap, full-block path for a validation ticket).
- **Flow-registry verdict pipeline (validations feature, Phase 2).** Wires validation outcomes into
  the Phase-1 registry — a validation ticket tagged with a `Flow:` field now stamps `validation/flows.md`
  deterministically on resolve/gate-park:
  - **`governor/worker-prompt.md`** report schema: the `validation` object gains `gatePassed`,
    `measured`, `validatedShas` (map sub-repo folder → validated-at SHA), `environment`, `flowIds`.
  - **`file-ticket.sh`** — a `--flow <id[,id…]>` flag (parallel to `--model`, any order) emitting a
    `Flow:` ticket field.
  - **`spawn-worker.sh`** — latches the ticket's `Flow:` field (same anchored parse as the Model latch)
    and injects the full registry block(s) for a flow-validation ticket, reminding the worker to fill
    the new report fields. (The one-line "your change stales flows X, Y" summary for non-validation
    tickets is Phase 3.)
  - **`govern-bookkeep.sh`** — pre-captures the `Flow:` field before deleting the ticket block, then
    stamps the registry on resolve (Status per Kind: correctness→PASS, effectiveness→EFFECTIVE/MEASURING).
  - **`run-loop.sh`** — the `park-gate-failed` branch stamps a measured NEGATIVE (correctness→FAIL,
    effectiveness→INEFFECTIVE) from the original report before the PR is nulled for the park.
  - **`flows.sh`** — `govern::flows_stamp_from_report` (SHA ancestor-verify against origin/main,
    squash-merge merge-commit substitution, never-overwrite-fresher guard, PR-URL linkage, grouped
    multi-flow stamping, evidence-summary promotion committed atomically with the stamp; a PII hit in
    the summary returns 2 → the caller PARKs rather than aborting mid-resolve), plus
    `govern::flow_reachable_sha`, `govern::flow_recorded_sha`, `govern::ticket_flow_ids`; `cas_edit`
    gained an optional extra-path arg so the evidence summary lands in the registry-stamp commit.
  - Tests: `test-flows-stamp.sh` (every Status transition, ancestor-verify + substitution,
    never-overwrite-fresher, grouped multi-stamp, PII-park), `test-flow-pipeline.sh` (file-ticket →
    ticket_flow_ids → spawn-worker injection → bookkeep stamp on resolve).
- **Flow-registry substrate (validations feature, Phase 1).** A net-new `validation/flows.md` registry
  keyed by stable dot-kebab flow ids pinned to code SHAs — the durable inventory of which user-facing
  paths are proven at HEAD, stale, failed, or measured-ineffective. Ships as pure mechanism (no LLM):
  - **`templates/govern/lib/flows.sh`** — a net-new block parser (flow blocks anchor on `^## <id>`,
    disjoint from the ticket parser's `^## #<digits>`): `govern::flow_ids/flow_block/flow_field`
    (inline-HTML-comment stripping), `govern::flow_set_field` (field upsert that preserves unknown
    fields + comments verbatim), `govern::flow_validate` (grammar conformance), `govern::cas_edit`
    (a compare-and-swap registry write — sync → edit-fn → commit → CAS-push with rebase-retry, factored
    from bookkeep's step-0 sync + step-4/5 push, serialized under the bookkeep lock), glob-resolution
    helpers, and `govern::flows_lint` (the lint matrix). Sourced by `common.sh` (guarded on existence).
  - **`templates/govern/lint-validation-refs.sh`** extended additively with the flow-registry lint
    matrix: a `logs/` evidence reference fails; a dangling `Evidence:` ref fails; a `Paths:` glob that
    resolves to 0 tracked files fails **and auto-degrades the flow to `STALE`** (an empty git-log must
    never read as "no changes"); oversized assets warn (>300 KB/file, >2 MB/dir); a PII/secret shape in
    tracked evidence fails, suppressible with a `<!-- lint:allow <pattern> -->` marker.
  - **`templates/seed/validation/flows.md`** — a seed registry documenting the block grammar; scaffold
    installs it (+ `validation/evidence/assets/`) via `component_seeds` (never overwritten).
  - Tests: `test-flows-parser.sh` (parser round-trip + unknown-field preservation + grammar validation),
    `test-flows-cas-edit.sh` (CAS retry under an injected concurrent push), `test-flows-lint.sh` (every
    lint row). Scaffold now copies all of `govern/lib/*.sh` (not just `common.sh`).

- **`templates/govern/test/test-spawn-worker-sweep.sh`** (N11) — regression test for the #239 orphan-resource sweep: asserts `spawn-worker.sh` fires `GOVERN_DEPLOY_SWEEP_CMD` on BOTH the clean-resolve and the hard-KILLED (timeout, exit >128, no report) exit paths — the #3001 leak class where a killed worker never runs its own cleanup — and that the sweep is handed the worker's start epoch + ticket number. Fails if the trap wiring is removed.
- **`templates/govern/test/test-pr-hygiene-api.sh`** (N12) — stub-`gh` coverage for the two PR-hygiene wrappers that talk to the GitHub API (previously only their pure sub-helper `_strip_ticket_ref` was tested): `govern::scrub_pr_ticket_ref` (asserts the `-X PATCH repos/<slug>/pulls/<pr>` endpoint + scrubbed `.title`/`.body`, the idempotent no-op, and the non-object defensive no-op) and `govern::pr_spec_files` (asserts the `pulls/<pr>/files --jq '.[].filename'` leak grep). Red on endpoint/jq-path regressions.

- **Onboarding mechanisms — trust ladder, viral PR footer, cost transparency.** Four adopter-facing
  mechanisms so a new fleet starts safe and cheap and grows autonomy on the operator's schedule:
  - **Trust ladder (`GOVERN_AUTONOMY` in `workspace.sh`): `observe` → `pr-only` → `auto`.** `observe`
    = workers open **draft** PRs, governor never merges (visible but inert); `pr-only` = normal PRs,
    governor never merges (a human clicks merge); `auto` = today's full auto-merge. `merge-pr.sh` gates
    at the outermost layer (fail-closed, distinct exit 6) and `run-loop.sh`'s merge loop leaves every PR
    open under the lower rungs. **Backward compatible:** an absent/empty knob (any workspace.sh predating
    the ladder) resolves to `auto`, so existing installs are unchanged; the scaffold **template** seeds
    `pr-only` for new adopters. `spawn-worker.sh` instructs workers to open draft PRs in `observe`.
    Documented in `commands/govern.md` + `templates/governor/README.md`.
  - **Viral PR footer (`WSP_PR_FOOTER`, on by default).** Governor-worker PR bodies end with one
    attribution line — `🤖 shipped by [shiploop](https://github.com/anshss/shiploop)` — injected via the
    worker prompt (`spawn-worker.sh`), replacing the old generated-with line. Opt out with `WSP_PR_FOOTER=off`.
  - **Starter ticket at setup** (`commands/setup.md`, fresh path, doc-only). After verification the setup
    flow offers to file ticket #1 — a small, guaranteed-tractable item detected during scaffold (a doctor
    warning, a missing `.env.example` key, a README TODO) via `file-ticket.sh` with a cheap model — so the
    adopter's first `/shiploop:govern` run is short and ends in a visible green PR.
  - **Cost transparency.** The governor run summary gains a **Spend** line — tokens and, when the worker
    JSONL carried it, dollar cost, per ticket and summed — derived from the stream-json `usage` /
    `total_cost_usd` that `history_enrich` already records. Token-only fallback when cost is absent; never
    invents a pricing table.

### Fixed
- **Ticket-queue isolation half-propagated to the hub (#46).** The queue-isolation fix reached `templates/govern/lib/common.sh` (`govern::out_of_scope_tickets`) but nothing wired it and the seed template lacked the behavioral rule, so a scaffolded workspace never flagged an external tool's ticket. Now (a) `templates/seed/CLAUDE.md`'s tickets-row carries the two-scopes rule (the queue admits only the current project's sub-repos and the harness itself; an external tool's follow-ups belong in its own tracker) so every new scaffold inherits it, and (b) the Stop-hook sweep (`templates/hooks/ticket-sweep-reminder.sh`) folds a **soft, never-blocking** advisory into its reconcile reason for any ticket whose `**Where:**` targets neither a sub-repo nor the harness — allowlist-based, so a Where-less ticket is never flagged and deletion stays the operator's call. New hermetic regression `templates/govern/test/test-queue-isolation-advisory.sh` (out-of-scope flagged / in-scope + no-Where not flagged / no advisory when all in-scope).
- **N3 — sync-port forbidden-identity gate no longer treats dictionary words as identity strings.** `templates/govern/sync-port.sh` derived its forbidden-token list from raw `$GITHUB_ORG` + `$META_NAME` + `${REPOS[@]}` with no filter, so a reference workspace with repos named `docs`, `console`, `website` (or a 2-letter `aq`) would block a correctly-genericized ported line like "see the docs" as a fake leak. The repo-derived tokens are now filtered (minimum length, default 4, via `GOVERN_FORBIDDEN_MIN_LEN`, plus an embedded common-word stop list); `$GITHUB_ORG` and `$META_NAME` remain **always** forbidden and unfiltered (real org/name leaks still caught even when short). Added a curated `GOVERN_FORBIDDEN_TOKENS` override that **replaces** the derived org/meta/repo list; `GOVERN_FORBIDDEN_EXTRA` keeps its extend semantics. New regression `templates/govern/test/test-forbidden-tokens.sh` proves: "see the docs" passes with a repo named `docs`, org/meta names still fail, a distinctive repo name (`mjolnir`) still fails, and the override replaces the derived list.
- **N1 — escalation boilerplate pinned the SHA, not `HEAD`.** `sync-port.sh`'s generic escalation body and the merge-failure message told the human to run `sync-templates.sh --mark HEAD`; a human resolving it days later would advance the marker over never-examined commits (silent drift-tracking loss). Both sites now interpolate the captured `$MARK_TO`, matching the other messages. No literal `--mark HEAD` remains.
- **N2 — `/shiploop:push` now advances the marker after a human merges the PR.** The `NO_MERGE` review path exited before the marker advance, so after a merge the next run re-cut the same branch and re-spawned a full porter against an already-ported tree (fails the "committed nothing" gate → escalates forever). `sync-port.sh` now checks for a MERGED PR on the drift branch BEFORE spawning the porter; if found it advances the marker (`--mark $MARK_TO` + CAS-commit) and exits 0. Regression test with a `gh` stub (`test-sync-port-merged-marker.sh`).
- **N4 — TOCTOU on the enumeration upper bound.** `sync-port.sh` resolved `HEAD` three independent times (`--check`, `--files`, `rev-parse`), so a mirrored-file commit landing on live main mid-run could be excluded from the port yet swept into the marker advance. `MARK_TO` is now captured ONCE, first, and threaded as a new `GOVERN_SYNC_UPPER_BOUND` env into `sync-templates.sh` (bounds `--check`/`--files`/`--diff` to `base..$MARK_TO` instead of `base..HEAD`; defaults to `HEAD`, unchanged behavior). Regression test (`test-sync-templates-upper-bound.sh`).
- **K6 — hub→workspace pulls no longer conflate with local improvements.** `sync-templates.sh` `drift_commits()` was purely commit-based, so a `/shiploop:update` converge counted as harness→hub drift (verified live: 3 of 5 "unported" commits were pulls). `drift_commits()` is now content-aware — a commit whose post-state for a mirrored file already matches the template is a convergence and is skipped. Complemented by a converge-time marker-advance instruction (Phase 3.5) in `commands/update.md`, guarded to only auto-advance when there was no pre-existing local drift. Regression test (`test-sync-templates-converge.sh`).
- **N5 — `workflows` orphaned from the update channel (permanent "behind" loop).** `scaffold.sh --diff-only` tracks `core-scripts worktrees govern githooks commands workflows`, but the bump loops in `commands/update.md` (Phase 3) and `commands/setup.md` (B1/B2) iterated only the first five — a pre-v1.5.0 workspace reported `workflows` drift forever. Added `workflows` to both loops (and a `workflows` row to setup.md's B1 inventory). Documented `.gitignore`'s deliberate exclusion from the drift set (it is placeholder-filled + merge-only, never overwritten, so not byte-comparable).
- **N7 — `.harness-version` stamp conflated "any scaffold run" with "fully in sync".** `scaffold.sh` wrote the hub VERSION stamp unconditionally at the end of ANY invocation, incl single `--component` runs — so a partial run left doctor/govern-health false-reporting "up to date" while another component was behind. `component_stamp` now stamps ONLY when the workspace is fully converged against the templates (new `workspace_converged` gate, sharing one `probe_files` + `MECH_COMPONENTS` source of truth with `--diff-only`). Fresh `--component all` runs and the converging final bump of an `/update` loop still stamp; partial/non-converged runs do not.
- **N8 — `commands/update.md` documented the wrong governor lock path.** The Phase 1 guard referenced `governor/.govern.lock/` (or `scripts/govern/.locks/*`); corrected to the real paths — single-run lock `governor/.govern.lock`, per-ticket claim locks `governor/.locks/ticket-<N>` (both under `governor/`, never `scripts/govern/`).
- **N9 — `scaffold.sh --verify` skipped `.githooks/pre-commit`.** The `bash -n` find-sweep covered `*.sh`, `pre-push`, `prepare-commit-msg` but not `pre-commit` (a bash hook activated via `core.hooksPath`); a syntax-broken `pre-commit` would ship green. Added `-o -name 'pre-commit'`.
- **K5 — `/shiploop:update` trusted a stale device clone.** Added a Phase-0.5 best-effort hub-freshness probe: when `$HUB` is a git clone, `git fetch -q origin` + `git rev-list --count HEAD..origin/main` warns with the behind-count and offers to `pull --ff-only` before any bump; degrades gracefully offline / non-git.

- **husky (and any framework that regenerates its hooks dir on `npm install`) silently wiping
  sub-repo attribution/pre-commit hooks — now audited AND re-asserted.** Each sub-repo is an
  independent git repo that does not inherit the harness root's `core.hooksPath`; the harness
  installs `prepare-commit-msg` (attribution) + `pre-commit` (optional lint-fix) into each
  sub-repo's *resolved* hooks dir (husky's `.husky/_/` when applicable). Previously that install
  happened only at fresh setup and at worktree creation — and in `worktree/new.sh` it ran BEFORE
  the bootstrap step, so a bootstrap `npm install` triggering husky's `prepare` regenerated
  `.husky/_/*` and wiped the hook. `doctor.sh` audited only the root's `core.hooksPath`, so a
  stubbed sub-repo was invisible. Empirically confirmed with a real `npm install`: husky
  regenerates `.husky/_/prepare-commit-msg`, replacing the attribution hook with its stub.
  - **`templates/doctor.sh`** gains a "sub-repo commit hooks" section that diffs each sub-repo's
    resolved `prepare-commit-msg`/`pre-commit` against `.githooks/` and flags a stubbed/stale/absent
    hook (warn, never fail), pointing at the re-install path.
  - **`templates/worktree/new.sh`** re-asserts both hook installers AFTER the bootstrap step, so a
    bootstrap `npm install`/husky reinstall can no longer leave the worktree's sub-repos stubbed.
  - **`commands/update.md` (Phase 3b)** and **`commands/setup.md` (Phase B2b)** now re-run the hook
    installers across every sub-repo on update/bump — not fresh-setup-only — restoring a wiped hook
    on each converge.
  - **`templates/lib/githooks.sh`** extracts the shared `resolve_subrepo_hooksdir` resolver (both
    installers now share it, byte-consistent) and adds the read-only `audit_subrepo_hooks` seam the
    doctor check uses.
  - Regression: **`templates/govern/test/test-subrepo-hook-resilience.sh`** proves the audit flags a
    husky-stubbed sub-repo and that a re-assert after a simulated husky regeneration restores the
    hook byte-identical to `.githooks/`.

- **`templates/govern/spawn-worker.sh`** (N11) — the post-worker orphan sweep's test seam was dead: the genericization refactor moved the explicit `GOVERN_DEPLOY_SWEEP_CMD` fire BELOW a `-z "${GOVERN_WORKTREE_CMD:-}"` guard, so the sweep could never fire under a test worktree override (i.e. in any test). Dropped that clause from the guard (kept the DRY-mode skip); a live governor run never sets `GOVERN_WORKTREE_CMD`, so real behavior is unchanged while the #239 trap is now regression-testable.

- **Docs/commands truth (Batch G — K4, N13, N14, N15, N17).**
  - **K4** — `commands/govern.md`, `commands/investigate.md`, `commands/resolve.md` now open with a
    defer-to-local preamble: if `.claude/commands/<name>.md` exists in the workspace, follow that
    live, locally-improved copy instead; the global copy is the fallback for un-scaffolded workspaces.
  - **N13** — `commands/govern.md` no longer claims a `GOVERN_MAX_RUNTIME (~4h)` default; corrected to
    match `run-loop.sh` and `templates/governor/README.md` (`0` = no cap by default).
  - **N14** — `jq` promoted from "handful of tests use it" to an explicit hard prerequisite in
    `README.md` (`run-loop.sh` fails closed at startup without it, and it's pervasive across the
    governor); `templates/doctor.sh`'s warning text corrected to match.
  - **N15** — `commands/govern.md`'s escalation-answer step now shells out to a new
    **`templates/govern/record-escalation-answer.sh <N> --answer "…" --disposition <token> [--rule
    "…"]`** instead of hand-editing `governor/escalations.md` — the command's `allowed-tools` stays
    `Bash, Read` (no Edit-tool ask). Rewrites only an OPEN `### #N` entry's Answer/Disposition/Make-a-
    rule fields, idempotent, commits via the shared CAS-safe escalations path. New regression
    `templates/govern/test/test-record-escalation-answer.sh`.
  - **N17** — `SKILL.md`'s Hooks section now lists all five wired hooks (was 3 of 5), adding
    `UserPromptSubmit → router-posture-reminder.sh` and `PreToolUse → router-posture-guard.sh` to
    match `README.md`'s table.

### Removed
- **`govern::retarget_pr_base`** (N10) — a fully-implemented REST-PATCH workaround for the `gh pr edit --base` GraphQL-deprecation bug (#116) with ZERO callers anywhere (hub + live workspace verified). Deleted as dead code; the #116 workaround knowledge is preserved as a concise NOTE comment in `templates/govern/lib/common.sh` where a future base-retargeting caller (select-ticket dependency-reorder / preflight-main base reconciliation) would look.

### Tests
- `templates/govern/test/test-update-channel.sh`: rewrote assertion 2 (partial run on a non-converged workspace writes no stamp), added the convergence-stamp assertion to 3, and added assertion 9 — N7's done-when end-to-end (a partial `--component` run does not flip doctor to "up to date" while a component is behind; the converging bump then advances the stamp).

### Docs
- **Extract-first onboarding (README restructure).** The README now leads with time-to-first-magic: Install moved up, and a two-act Quickstart is the first hands-on section. **Act 1 — "10 minutes: see your product's risk map"** (`/shiploop:setup` on a repo you already have → `/shiploop:flows extract` → `list`); the truthful minimal path is documented as setup → extract, because `extract` needs the scaffolded `scripts/govern/flows-*.sh` helpers + `validation/flows.md` (it is not runnable cold), and it deploys/merges nothing. **Act 2 — "file one ticket, watch it ship"** (starter ticket → `config-check.sh` → `/shiploop:govern`, pr-only). Requirements pulled up and made prominent (git/gh/jq; Act 1 needs only Claude Code + git + jq).
- **Explicit trust ladder** (README `Trust and cost` + SKILL.md governor section): **observe → pr-only → auto**. New workspaces start pr-only; you graduate one repo at a time by adding it to `GOVERN_MERGE_REPOS` once you've watched its PRs behave. The three-factor merge guard, green-or-no-checks CI, and hard-stop doctrine are framed as why graduation is safe.
- **N=1 is a first-class adopter.** README, SKILL.md, and the `commands/setup.md` interview now state that one repo is a fine meta-repo — the queue, governor, worktrees, and lesson-accretion all pay off at N=1; add sub-repos later. No assumption of microservices.
- **Coherent wedge line.** README, SKILL.md, and `commands/flows.md` all describe `extract` as inventorying "every user-facing path that might break" so the risk-map framing reads identically everywhere.

## 1.5.1 — 2026-07-05

Positioning reframe — job-first, self-improving multi-agent harness (every resolved ticket writes a lesson into your git-tracked CLAUDE.md). No mechanism changes.

### Changed
- **README** reframed around the operator's job split: humans do specs and systems engineering, shiploop ships the code. New tagline block; new section order (how it ships without burning your quota → how it ships without shipping slop → why it gets better and cheaper over time → proof → contrast, demoted). Every operational fact preserved (install commands, requirements, opt-in knobs including the v1.5.0 `Model:` field, component table, ~$0.54 cost figure with methodology, three-factor guard, hooks). The v1.4.1 Devin/Cursor/Copilot contrast paragraph survives, demoted to a "How it compares" section.
- **`.claude-plugin/plugin.json`** description + keywords aligned to the job-first frame; added `self-improving`, `multi-agent`, `orchestration`, `model-routing`, `backlog` keywords.
- **`.claude-plugin/marketplace.json`** outer + inner descriptions and tags aligned.
- **`SKILL.md`** frontmatter description + "What it is" opening reframed; trigger phrases and mechanism prose intact.
- **`commands/{govern,setup,update,push,resolve,investigate}.md`** frontmatter descriptions aligned to the frame (`govern` = "ships your backlog"; `update` / `push` = "the self-improvement channel, pull/push direction"; `resolve` = the lesson-promotion step where the harness gets smarter). Trigger semantics preserved verbatim.

Claims discipline: every "self-improving" carries its mechanism clause in the same breath (lesson → git-tracked CLAUDE.md). Every number is checkable (~$0.54 methodology in Trust and cost; the 400+ tickets figure is attested by the maintainer, with a public evidence artifact tracked as follow-up work).

## 1.5.0 — 2026-07-05

Brain-decided model routing — the interactive session (the "brain") decides which cheap tier
handles each delegated worker, and the harness executes the decision. Three components:

### Added

- **Per-ticket `Model:` field, honored by the governor.** `templates/govern/spawn-worker.sh`
  now reads an optional `**Model:** haiku|sonnet|opus` line inside the ticket block and passes
  it to `claude -p --model <tier>` — but **only on the ticket's first attempt**. Any retry
  (preserved worktree at `$WORKTREE_BASE/ticket-N/` OR a prior `worker.jsonl` at
  `$LOG_ROOT/ticket-N/`) escalates to `GOVERN_WORKER_MODEL` unconditionally, because a
  cheap-tier bet that didn't land the first time shouldn't be re-bet on retry. Unknown /
  absent values are dropped fail-safe → the entire existing backlog behaves exactly as
  before. `scripts/govern/file-ticket.sh` gains a `--model <tier>` flag that prepends the
  field to the ticket body.
- **`templates/workflows/deep-research.js`** — model-tiered override of the built-in
  `deep-research` workflow (adapted from Claude Code's session-persisted script). Ships
  `.claude/workflows/deep-research.js` into scaffolded workspaces, registered under the
  distinct `meta.name: 'deep-research-tiered'` so it never collides with the built-in by
  name (an in-session probe on 2026-07-05 confirmed a same-named workspace copy did NOT
  shadow the built-in — the distinct name is robust regardless of fresh-session precedence).
  The 5 `agent()` sites now accept a brain-decided plan via `args.models = {scope, search,
  verify, synthesize}` with a clear null-semantics contract: absent OR explicit `null` →
  the tiered default (`scope=sonnet`, `search=sonnet`, `fetch=haiku effort:low`,
  `verify=sonnet`, `synthesize=inherit`); the literal string `"inherit"` → no model pinned
  (session model); any other string pins that stage. `args.models` non-object → ignored,
  defaults used. A brainless invocation never repeats the all-inherit token burn. New
  `component_workflows` in `scaffold.sh` also installs a paired
  `.claude/skills/deep-research-tiered/SKILL.md` whose description carries the built-in
  deep-research trigger language plus a preference note, so `deep-research`-shaped
  requests in a scaffolded workspace route to the tiered workflow. Both are covered by
  `--diff-only`.
- **Router-posture hooks gain the model rule.** `templates/hooks/router-posture-reminder.sh`,
  `router-posture-guard.sh`, and `templates/seed/CLAUDE.md`'s delegation section each carry
  the same 3-4 line guide: haiku = mechanical/extract/lookup · sonnet =
  search/investigation/standard edits · inherit only for judgment-heavy synthesis. So the
  posture the driver adopts on turn 1 already includes sizing children, not just delegating.

### Test suite

- Grew 70 → 71 hermetic tests (`test-spawn-model-routing.sh`) — first-attempt honor,
  retry-escalation, no-`Model:` unchanged, unknown-tier fail-safe, PLUS a fenced-`Model:`-in-
  body case that locks in the leading-field-block anchor (a `Model:` line in prose or a code
  fence later in the body cannot spoof the routing field). Auth-free; drives a new
  `GOVERN_SPAWN_DRY_RUN=1` observation seam in `spawn-worker.sh` (no worker cost, no auth).

### Compatibility

- Fully additive. Backlogs with no `Model:` line keep running under `GOVERN_WORKER_MODEL`
  unchanged (same route path). Workspaces scaffolded pre-v1.5.0 pick up the tiered workflow
  file on the next `/shiploop:update`.

## 1.4.2 — 2026-07-05

Fix cold-install doc bugs — correct ticket path (`queue/tickets.md`), honest `--dry-run` cost framing + `config-check.sh` as the free smoke, standalone `scaffold.sh --verify`, test-count consistency.

### Fixed
- **Quickstart pointed at the wrong ticket path.** README + SKILL.md + `commands/govern.md` + `commands/resolve.md` said tickets live in a root-level `tickets.md`, but the scaffolder installs them at `queue/tickets.md` (and every runtime script — `select-ticket.sh`, `file-ticket.sh`, `dry-run.sh` — reads that path). Every reference to the queue location is now `queue/tickets.md`. Only the setup-md legacy-migration line (`git mv tickets.md queue/`) is left as-is, since it deliberately references the pre-scaffold path.
- **`--dry-run` was framed as free but spawns a real billable worker.** README Quickstart §5 read as "prove the loop, ship nothing" — technically true (nothing lands in git) but misleading (the plan-mode worker is still a live `claude -p --model opus` process consuming tokens). Quickstart now leads with `bash scripts/govern/config-check.sh` as the genuinely-free ($0, no auth, no worker) smoke, and reframes `--dry-run` as an end-to-end rehearsal that spends worker tokens. The "Trust and cost" section carries the same distinction so the two sections agree.
- **`scaffold.sh --verify` failed standalone.** Running `scaffold.sh --verify` (or `--diff-only`) alone died with `ERROR: --org is required for workspace.sh` because the default `COMPONENT=all` re-ran the `workspace.sh` writer even though the caller was only asking for a read-only check. `scaffold.sh` now detects verify-only invocations (any of `--verify` / `--diff-only`, with no `--org`, `--repos`, or explicit `--component`) and skips the entire writer phase — running just `verify_scripts` + `verify_relocations` against the existing install. `--workspace-dir` defaults to the current directory in that mode, so `scaffold.sh --verify` works from inside the workspace. Explicit `--component X --verify` still runs its normal writer path. Locked in by `test-scaffold-verify-standalone.sh`.
- **CI header comment claimed a 65-test suite.** The real count is 70 after this release. The CI comment now references "the full govern test suite" without a brittle count; the README follows suit ("the hermetic test suite") so the number doesn't rot every time a new regression lands.

### Test suite
- Grew from 69 → 70 hermetic tests (`test-scaffold-verify-standalone.sh`). Full suite green locally + CI.

## 1.4.1 — 2026-07-05

README rewrite — reposition as autonomous backlog governor; no code changes.

## 1.4.0 — 2026-07-05

Renamed `meta-repo-harness` → `shiploop` (product / plugin / command namespace / repo slug). No mechanism changes; every prior release's behavior is preserved. Historical CHANGELOG entries below still reference the old name — that is intentional (they record what the release was called at the time).

### Changed
- Plugin manifest `name` + `displayName` → `shiploop`; homepage / repository URLs → `github.com/anshss/shiploop`.
- Marketplace manifest name + inner plugin `name` → `shiploop`.
- Slash-command namespace: `/meta-repo-harness:{setup,update,push,govern,resolve,investigate}` → `/shiploop:{…}`.
- Install commands in README + `install.sh`: `/plugin marketplace add anshss/shiploop`, `/plugin install shiploop@shiploop`; clone path `~/.claude/skills/shiploop/`.
- SKILL.md frontmatter `name: shiploop`; description references the new command namespace.
- Docs, prompts, and error messages that referenced the old product name updated to `shiploop`.
- Test fixtures that mocked the harness repo as `meta-repo-harness` now mock it as `shiploop`.

### Unchanged (deliberately)
- Env var NAMES: `GOVERN_UPSTREAM_HARNESS_REPO`, `GOVERN_UPSTREAM_HARNESS_DIR`, and every other `GOVERN_*` name. Their default *values* (empty) also unchanged; example values in comments updated to `shiploop`.
- Workspace stamp filename `scripts/lib/.harness-version`.
- Generic-noun prose: "meta-repo workspace", "the meta-repo pattern", "multi-subrepo / meta-repo" — shiploop is still a tool *for meta-repos*.

### Compatibility
- Existing installs pick up the new name on plugin update. The install command changes to `/plugin install shiploop@shiploop`; the old marketplace add now needs `anshss/shiploop`. GitHub redirects the old repo URL, so links continue to resolve until you re-`marketplace add`.

## 1.3.0 — 2026-07-05

Reconcile-commands release. The two-way update channel that shipped in v1.2.0 gains its user-facing surface: fleet reconciliation is now a one-command action in each direction, matching the `git pull` / `git push` mental model.

### Added
- **`/meta-repo-harness:update`** — pull the latest hub templates into THIS workspace. Wraps `scaffold.sh --diff-only` (detect what's behind) → component-by-component bump (mechanism scripts only, PRESERVES `scripts/lib/workspace.sh`) → `config-check.sh` + `bash -n` verify + stale-relocations sweep → concise per-component `in-sync | bumped | skipped` report. Idempotent (up-to-date workspace prints "up to date" and exits). Fail-closed on dirty tree / live governor. Resolves the hub in priority order: `CLAUDE_PLUGIN_ROOT` → `GOVERN_UPSTREAM_HARNESS_DIR` (workspace.sh knob) → `~/.claude/skills/meta-repo-harness/` → plugin-cache glob. Regression-locked by `test-reconcile-update.sh` (12 assertions).
- **`/meta-repo-harness:push`** — push local mechanism-script improvements back to the hub. Requires `GOVERN_UPSTREAM_HARNESS_REPO` set. Reuses the existing v1.2.0 `sync-templates.sh --check` + `sync-port.sh` pipeline verbatim — same fail-closed gates (bash -n + forbidden-identity-strings on ADDED lines + scaffold-suite baseline diff), same single-owner lock, same EXIT-trap restore, same fingerprint-deduped escalations. Invokes `sync-port.sh` with `--no-merge` unconditionally: this is an INTERACTIVE command, so the PR opens for HUMAN review, never auto-merges. Workspace-specific files (workspace.sh, package.json, repo lists, operator-owned governor files) intentionally NEVER pushed — `sync-templates.sh` filters them at the pathspec level. Dry-run by default; `--run` or `--yes` in `$ARGUMENTS` skips the confirmation. Regression-locked by `test-reconcile-push.sh` (17 assertions).

### Scaffold-reachability decisions
- **`/update`** needs `scaffold.sh`. It lives at the hub root and is NOT copied into scaffolded workspaces; `/update` resolves it from the plugin/hub root (same resolution as `/setup`).
- **`/push`** needs `sync-port.sh` + `sync-templates.sh`. Both were already scaffolded into `scripts/govern/` via `component_govern` starting v1.2.0 (no install change needed). Workspaces scaffolded pre-v1.2.0 must run `/update` first to install the sync channel.

### Docs
- README "Updating" section rewritten to lead with the two commands (the pull/push mental model); deeper scaffold detail moved below.
- `commands/setup.md` cross-references `/update` (ongoing maintenance) and `/push` (contribute back) so operators know when to reach for which.
- The Components table gains the two new command files.

### Test suite
- Grew from 65 → 67 hermetic tests. Full suite green locally + CI.

### Compatibility
- Fully additive. Existing installs pick up the new commands on plugin update or `/meta-repo-harness:update`. Both commands are opt-in — nothing runs at scaffold time.
- Pairs with issue #35 (retire the reference instance's bespoke sync-port wrapper) and closes the loop on fleet drift being a monitored problem.

## 1.2.1 — 2026-07-05

Adopter-friction patch surfaced by the reference-instance convergence to v1.2.0.

### Fixed
- **`assert.sh` back-compat seam.** v1.2.0 moved `_GOVERN_ASSUME_MERGE_ALLOWED=1` from top-level into `mk_ws_stub()`. Any adopter test that sources `assert.sh` WITHOUT calling `mk_ws_stub` lost the merge-allowed seam → `merge-pr.sh` exited 5 with `external-author` → ~14 red tests on the reference instance. v1.2.1 emits the seam at BOTH sites — top-level for adopters, re-set inside `mk_ws_stub` for callers that unset it earlier. Locked in by `test-assert-merge-seam-top-level.sh`.
- **Exit-77 SKIP handling for naive runners.** `test-update-channel.sh` and `test-sync-port.sh` exit 77 (SKIP) when the enclosing hub / porter-prompt isn't present. A naive `for t in test-*.sh` loop read that as a hard failure. v1.2.1: (a) `commands/setup.md` documents the copy-pasteable idiom with an rc==77 branch that prints `skip`; (b) `templates/govern/govern-self-apply.sh` and `templates/govern/sync-port.sh` — the two suite-runners shipped in templates — now treat rc==77 as skip. (The CI workflow already tallied 77 correctly.)

## 1.2.0 — 2026-07-05

Update-channel release. Ships the two-way channel that lets an adopter know a bump is due AND lets them contribute back — plus a batch of upgrade-friction fixes distilled from three real convergence runs (claude-keepalive, splito, tokenjam).

### Added — the update channel core
- **`VERSION` file at hub root.** Records the hub's current version (`1.2.0`); readable by `scaffold.sh --version`. Existed nowhere before this release — convergence reports depended on a floating string in setup.md.
- **Workspace stamp.** `scaffold.sh` writes `scripts/lib/.harness-version` on every run and every component bump. The stamp is the version this workspace was last synced against.
- **Staleness warning in `doctor.sh` + `govern-health.sh`.** Both compare the stamp against the installed hub's `VERSION` (resolved via `CLAUDE_PLUGIN_ROOT` → `~/.claude/skills/…` → the plugin cache). If behind: "harness N releases behind — run the setup upgrade". Graceful when the hub is unresolvable (offline / cache-only install): degrades to a soft "cannot compare" notice, never an error.

### Added — generalized sync channel
- **`templates/govern/sync-templates.sh`.** Ports the drift reporter into the templates. Detects which live files have drifted from the templates repo (by MIRROR PRESENCE — files with a template counterpart are drift-relevant, workspace-specific files are filtered out). Read the file — it documents the mapping (govern, worktree, lib, .githooks, .claude/commands, hook scripts, CLAUDE.md seed) + the exclusions (workspace.sh config sink, runtime artifacts). Regression-locked by `test-sync-templates.sh` (25 assertions).
- **`templates/govern/sync-port.sh`.** Auto porter that opens + validates + merges a template-sync PR. Fail-closed at every step: bash -n on changed shell files, forbidden-identity-strings gate on ADDED diff lines (org + repo names + `$META_NAME` + `$GOVERN_FORBIDDEN_EXTRA`, all lowercased/deduped), scaffold suite baseline-diff, empty-diff / strand / uncommitted-work guards, EXIT-trap restore of the templates repo to `main`, escalation dedup by branch fingerprint. `--no-merge` mode for safe first rollout. Regression-locked by `test-sync-port.sh` (44 assertions).
- **Genericized via workspace.sh knobs.** `GOVERN_UPSTREAM_HARNESS_REPO` (short repo name) and `GOVERN_UPSTREAM_HARNESS_DIR` (local working dir of the fork clone). BOTH empty (default) → the whole mechanism is inert (sync-port exits 0 with "feature off"). Adopters who don't contribute back pay zero cost. Adopters who do point them at their fork.
- **`run-loop.sh` auto-trigger.** At the end of every governor run, if `GOVERN_UPSTREAM_HARNESS_REPO` is set AND `sync-port.sh` is present in the workspace, sync-port fires. Best-effort; never overrides the run's exit code. `GOVERN_SYNC_PORT_ON_END=0` disables.
- **`templates/governor/sync-porter-prompt.md`.** Genericized porter prompt (worker instructions).

### Added — upgrade-friction fixes
- **`scripts/govern/lock-release.sh`** (from tokenjam friction #1). Inspects the run lock, verifies holder pid liveness, reclaims iff dead — the scripted path that was missing when a prior worker crashed. `--status` (holder info), `--force` (bypass — prints holder for the record). Setup.md B-pre calls it out.
- **Knob-type migration guard** (tokenjam friction #2). `scaffold.sh --component workspace-sh` detects the legacy `GOVERN_MERGE_REPOS=(...)` / `GOVERN_LOCAL_FIRST_REPOS=(...)` array shape and warns with the exact mechanical migration to the v1.1.0+ space-separated string form. Setup.md B2 documents it too.
- **`--component settings-merge`** (tokenjam friction #3). Idempotent jq-driven insertion of the harness hook stanzas (SessionStart / UserPromptSubmit / PreToolUse / Stop / SessionEnd) into an EXISTING `.claude/settings.json` — one script call replaces the "merge missing hook entries yourself" hand-edit. Re-run is a no-op (each event is skipped if a harness marker script is already referenced there).
- **`templates/lib/relocations.txt`** (tokenjam friction #4). Machine-readable manifest of file relocations. Seeded with the v1.1.0 test relocation (`scripts/worktree/test/test-base-ref.sh` → `scripts/govern/test/test-base-ref.sh`). `scaffold.sh --verify` reads it and warns about stale copies still living at the old path. When you move a template file, add a line here.
- **`scripts/govern/config-check.sh`** (tokenjam friction #5). Cheap no-auth smoke — sources workspace.sh + common.sh, resolves every knob, calls every helper (`wsp_repo_slug`, `wsp_repo_localdir`, `wsp_repo_port`, `wsp_is_merge_repo`, `wsp_is_local_first_repo`, `govern::next_ticket_number`, `govern::meta_root`), prints values, exits nonzero on any missing required. `--json` mode. Setup.md B3 points here first; dry-run.sh (which spawns a live worker) is the second step.
- **`scaffold.sh --diff-only`** (tokenjam friction #7). Per-component sync report without writing — `in-sync` (all installed files match template) or `behind (N file(s) drift)` per component. Also prints the hub VERSION + workspace stamp. Exit 0 if in sync, exit 3 if any component is behind.
- **Pipe-stall test idiom in setup.md** (tokenjam friction #6). Documents the `timeout … bash test.sh </dev/null > file.log 2>&1 & wait` idiom for headless environments where the piped `... | tail` form stalls.
- **BUMP-mode caveats in setup.md** (splito frictions #4, #6, #8, #9). Adds: test-suite step (was omitted in the doctrine), `--run-tests` escape hatch mention, dry-run auth caveat in B3 (was only mentioned in fresh mode), `--component all` warn-and-continue behavior for `workspace.sh` / `package.json` / `.claude/settings.json`, structured commit-message body template.

### Changed
- `scaffold.sh` gains `--version` and `--diff-only` flags.
- `component_govern` also copies `governor/sync-porter-prompt.md` when present (v1.2.0+).
- `templates/lib/workspace.sh` gains two new opt-in knobs: `GOVERN_UPSTREAM_HARNESS_REPO`, `GOVERN_UPSTREAM_HARNESS_DIR`.
- `templates/govern/run-loop.sh` calls `sync-port.sh` at run-end (guarded by knob + script presence).

### Compatibility
- Existing installs pick up the update channel by re-running `scaffold.sh --component <name>` — the stamp gets written; doctor.sh + govern-health.sh start comparing vs the hub VERSION.
- The sync channel is OFF by default (both `GOVERN_UPSTREAM_HARNESS_REPO` and `GOVERN_UPSTREAM_HARNESS_DIR` empty). Zero-cost for pure-consumer instances.
- Adopters carrying the legacy bash-array `GOVERN_MERGE_REPOS=(...)` / `GOVERN_LOCAL_FIRST_REPOS=(...)` are warned at `--component workspace-sh` with the exact rewrite. Multi-element arrays SILENTLY BROKE in v1.1.0; this release makes the migration visible.

### Test suite
- Grew from 60 → 62 hermetic tests (added `test-sync-templates.sh` + `test-sync-port.sh`).

## 1.1.0 — 2026-07-04

Fleet-harvest release. Two production instances (a tokenjam-shaped workspace and the splito workspace) fed a batch of hardening fixes and small-but-load-bearing features back into the templates. Every added mechanism is OFF by default; existing installs upgrade cleanly with `scaffold.sh --component <name>`.

### Added (from tokenjam harvest, PR #30)
- **Validation-gate action ladder.** Worker's `## Validation` block now carries an explicit action (`retry` / `escalate` / `park`) that the governor honors, replacing string-heuristic disposition. Locked by `test-validation-gate-action.sh`.
- **Opt-in externalization lane.** Every governor run can file each OPEN Low-severity ticket whose Where targets `GOVERN_EXTERNALIZE_SUBREPO` as a public GitHub Issue on `GOVERN_EXTERNALIZE_REPO`. Sibling-repo name containment is excluded. Auto-label mode when `GOVERN_EXTERNALIZE_LABELS` is empty. 42-assertion `test-externalize.sh`.
- **Local-first migration classification.** `GOVERN_LOCAL_FIRST_REPOS` marks sub-repos that ship schema changes as self-applying code, so additive migrations merge normally instead of parking for a manual prod apply. Destructive migrations still escalate. Regression: `test-local-first-migration.sh`.
- **PR-hygiene scrubbing.** Worker PR bodies are scrubbed of the harness-internal disposition/validation blocks before opening. `test-pr-hygiene.sh`.
- **Worktree base-ref fix.** `worktree/new.sh` now resolves the sub-repo's actual default branch instead of assuming `main`, so worktrees created against `master`/`develop`/etc. no longer fail to pick a base. `test-base-ref.sh`.
- **`govern-improve` lib discovery fix.** The self-improve triage no longer walks past the meta root looking for its lib.

### Added (from splito harvest, this PR)
- **Workspace pre-commit lint-fix hook.** `templates/githooks/pre-commit` runs `WSP_LINT_FIX_CMD` (any idempotent formatter/linter fixer) in each sub-repo before commit, then `git add -u`'s the touched tracked files. Failures are soft (commit proceeds). Chain-safe: sub-repos that already have a pre-commit hook (husky, lefthook, hand-rolled) are left untouched. Empty CMD (default) = the hook is a no-op. `install_subrepo_pre_commit_hook()` in `templates/lib/githooks.sh` propagates it into sub-repos alongside the attribution hook. 12-assertion `test-pre-commit-hook.sh`.
- **Cross-repo file-conflict warning in `push-prs.sh`.** Before opening PRs, warn when two sub-repos have touched the same relative path — the operator can review before both PRs go out. Uses `grep -F` for bracket-safe filenames and a trap-cleaned tmpfile. (Feature already ported into templates; this changelog records its provenance.)
- **`merge-pr.sh` local-branch cleanup guard.** When deleting the post-merge local ticket-`<N>` branch, skip silently if the branch is checked out in any worktree, instead of leaving noise on every merge. Worktree teardown handles that case. Locked by `test-merge-pr-branch-cleanup.sh`. (Feature already ported into templates; this changelog records its provenance.)

### Changed
- Test suite grew from 54 → 60 hermetic tests.
- CI scaffold-and-test job now exercises all 60 tests against a freshly-scaffolded workspace on every PR.

### Compatibility
- Every new mechanism is OFF-by-default. Existing installs pick up the new hook by re-running `scaffold.sh --component githooks` plus `install_subrepo_pre_commit_hook` in the sub-repo loop from `commands/setup.md` Phase 3.
- No migrations required; `workspace.sh` gains one new opt-in variable (`WSP_LINT_FIX_CMD`).

## 1.0.0 — 2026-07-04

First Claude Code **plugin** release. Prior to this, the repo installed as a skill via a symlink installer. That path still works; the plugin path is now the recommended install method.

### Added
- **Plugin packaging.** `.claude-plugin/plugin.json` manifest + `.claude-plugin/marketplace.json` marketplace catalog. Users install via `/plugin marketplace add anshss/meta-repo-harness` + `/plugin install meta-repo-harness@meta-repo-harness`. Slash commands appear as `/meta-repo-harness:*` under the plugin namespace.
- **Deterministic `scaffold.sh`.** All mechanical file operations (template copies, placeholder fills, chmod, git init, initial commit, verification) extracted from `commands/setup.md` into a top-level bash script. Idempotent, non-interactive (`--yes`), component-scoped (`--component <name>` refreshes one part), verifiable (`--verify` runs `bash -n` + sources `workspace.sh`). `setup.md` now interviews the operator, invokes `scaffold.sh`, and does only judgment work (detection, disambiguation, migration decisions).
- **Real CI.** New `scaffold-and-test` job runs `scaffold.sh` against 2 fake sub-repos and executes all 54 govern tests in the throwaway workspace on every PR. A `validate-manifests` job asserts the plugin + marketplace JSON parse and carry required fields. Existing `bash -n` and conflict-marker gates preserved.
- **`CHANGELOG.md`** + this version tag.

### Ported from the reference deployment (2026-06 → 2026-07 hardening batch)
The templates absorbed a run of production-driven fixes ahead of this release:
- Fail-closed CI lane + escalation lifecycle + ticket-block parser + claim-lock heartbeat + worktree rm-guard + port SSOT (batch of 2026-07-03).
- Round-2 drift: supervisor / self-improve input fidelity (#122), duplicate-heading hook (#73), wakeup-guard (#308), +6 new govern tests bringing the suite to 54.
- Round-1 drift: ROI telemetry (#272), interrupted-retry (#34b), worktree-leak fix.
- Git-hooks enforcement, router-posture guard, `/investigate` command, CLAUDE.md core/appendix split.

### Fixed
- `templates/govern/test/test-validation-promote.sh` — hardcoded template-layout path replaced with the existing `GOVERN_HOOKS_DIR` resolver so the test passes in both template and scaffolded-workspace layouts. Without this fix the scaffold-and-test CI job would be red on 1 test.

### Compatibility
- Legacy `install.sh` (clone → symlink into `~/.claude/commands`) continues to work.
- `scaffold.sh` resolves the templates directory from `${CLAUDE_PLUGIN_ROOT}` first, then from its own script directory, so the same command runs correctly in both install modes.
- `commands/setup.md` no longer hardcodes `~/.claude/skills/meta-repo-harness/templates/` — it resolves `PLUGIN_ROOT` at runtime.
