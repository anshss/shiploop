# Changelog

## Unreleased

Sub-repo, sync-channel, sync-port, update-channel correctness plus governor test-coverage + dead-code cleanup (remediation batches — N1–N12, K5, K6) plus the validation-flow registry substrate, verdict pipeline, and staleness sweep (Phases 1-3). VERSION bump at release.

### Added

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

### Fixed
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
