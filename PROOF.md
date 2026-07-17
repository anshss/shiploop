# PROOF — evidence from a real production run

The README's Proof section makes claims about shiploop running against a real backlog. This
document is the sanitized, re-runnable audit behind those claims — the queries are included so
anyone can reproduce the methodology against their own workspace history. Source: one maintainer's
production multi-repo workspace (8 sub-repos: backend/API, orchestration, deploy driver, CLI, a
meta-tooling repo, plus a web console, marketing site, and admin panel), running the governor from
2026-05-28 through 2026-07-17 (50 days). This is a single case study, not a controlled experiment —
treat the numbers as one real deployment's track record, not a statistical guarantee for yours.

No customer data, repo names, or ticket contents are included below — only aggregate counts and the
commands used to produce them.

## 1. Tickets resolved

**Verified: 281 distinct tickets resolved or closed** (300 `resolve` bookkeeping events — some
tickets were reopened and re-resolved after a bad first attempt, per the governor's own
churn-tracking — plus 4 tickets closed via an alternate mitigation, 3 of which overlap with an
earlier resolve). This is out of 379 ticket numbers ever filed since the workspace's first commit.

This **corrects an earlier maintainer-attested figure of "400+ tickets auto-found and resolved"**
that had never been checked against the actual bookkeeping history. Re-running the query below
against the full commit history put the real number lower. We're publishing the corrected number
rather than the original estimate, because a number nobody re-derives isn't evidence.

Query (run from the workspace root, across the full history):

```bash
# distinct tickets resolved
git log --oneline | grep "docs(tickets): resolve" \
  | sed -E 's/^[a-f0-9]+ docs\(tickets\): resolve #([0-9]+).*/\1/' | sort -n -u | wc -l

# distinct tickets closed via an alternate path (not "resolve")
git log --oneline | grep "docs(tickets): close" \
  | sed -E 's/^[a-f0-9]+ docs\(tickets\): close #([0-9]+).*/\1/' | sort -n -u
```

## 2. Auto-merge vs. human-merge split

Across the 8 sub-repos, governor-authored PRs (branch name matching the governor's own
`ticket-<N>` / `sl-<hex>` naming — the same pattern the auto-merge guard itself checks before it
will ever land a PR) totaled **290 merged PRs**:

| Merge path | PRs | Share |
|---|---|---|
| Auto-merge-eligible repos (on the `GOVERN_MERGE_REPOS` allowlist — backend/infra, CI green-or-no-checks gated) | 234 | 81% |
| PR-only repos (frontend + anything off the allowlist — a human always clicks merge) | 56 | 19% |

This measures **merge-path eligibility**, not a confirmed "the bot clicked merge" event — the
governor's auto-merge lane and a human both merge under the same GitHub identity, so GitHub's
`mergedBy` field can't distinguish them after the fact. The branch-naming guard is the honest
signal available: only the governor opens `ticket-<N>`/`sl-<hex>` branches, so this counts what the
governor *could* auto-merge under doctrine, split from what always requires a human (frontend).

Query (per repo, requires `gh` auth against the org):

```bash
gh pr list --repo <org>/<repo> --state merged --limit 1000 \
  --json headRefName \
  | jq '[.[] | select(.headRefName | test("^(ticket-[0-9]+|sl-[0-9a-f]+)$"))] | length'
```
Run once per repo, sum the auto-merge-allowlisted repos separately from the rest.

## 3. Auto-merge revert / rollback rate

**0 confirmed reverts out of 290 governor-branch merges** (0%), found by matching every `git
revert`-style commit (`Revert "..."` subject + a `This reverts commit <sha>` trailer) against the
merge-commit SHA of every governor-branch PR, across all 8 repos.

One separate, self-referential revert was found and is worth naming precisely because it's *not*
a hit against this number: the governor's own tooling briefly auto-merged into a frontend repo
during a policy experiment, and that policy change — not any product code — was reverted the same
day once the guard proved unsafe (Vercel's check doesn't fire for the governor's commit author).
That's the harness catching its own bad config change, in the meta-tooling repo, not a shipped
product regression that had to be rolled back.

Caveat: this methodology only catches reverts made via `git revert` or GitHub's "Revert" button,
which stamps the `This reverts commit` trailer. A manual hand-edit that silently undoes a governor
merge without that trailer would not be caught. We don't have evidence that happened, but the
query can't rule it out either — flagging the gap rather than rounding it away.

Query (per repo, requires a local clone):

```bash
# collect merge-commit SHAs for governor-branch PRs (see query in section 2, add mergeCommit.oid)
gh pr list --repo <org>/<repo> --state merged --limit 1000 \
  --json headRefName,mergeCommit \
  | jq -r '.[] | select(.headRefName | test("^(ticket-[0-9]+|sl-[0-9a-f]+)$")) | .mergeCommit.oid' \
  | cut -c1-7 > gov-shas.txt

# for every git-revert-style commit, check whether it reverts one of those SHAs
git log --all --grep="^Revert" --format="%H" | while read -r sha; do
  reverted="$(git log -1 --format="%b" "$sha" \
    | grep -oE 'This reverts commit [0-9a-f]+' | grep -oE '[0-9a-f]{7,40}' | cut -c1-7)"
  [ -n "$reverted" ] && grep -q "^$reverted" gov-shas.txt && echo "MATCH: $sha reverts $reverted"
done
```

## 4. Cost per resolved ticket

Real per-ticket cost (Claude Code's own reported `total_cost_usd`, not an estimated token-times-rate
calculation) is only available for the tickets resolved since cost telemetry was wired into the
governor's history log (2026-07-02 onward). Over that window, **N = 32 resolved tickets**:

| Stat | Value |
|---|---|
| Mean | $4.49 / ticket |
| Median | $3.03 / ticket |
| Range | $1.34 – $12.00 / ticket |

**This supersedes the earlier "~623.9k output tokens (~$0.54) per resolved ticket" estimate**,
which predates real cost telemetry and does not reproduce against Claude Code's own cost
accounting. The measured sample also skews toward `opus`-tier, self-referential harness/meta-tooling
tickets (the harness improving itself), which run more expensive than typical right-sized
haiku/sonnet product tickets — so $4.49 is closer to an opus-heavy upper bound than a right-sized
average. We're not publishing a lower, nicer-looking number in its place; $4.49/median $3.03 is
what the 32-ticket sample with real telemetry actually shows, and the sample will grow as more runs
carry cost data.

Query (from a workspace with the governor's `ticket-history.jsonl`):

```bash
jq -c 'select(.status=="resolved" and .costUsd != null)' governor/ticket-history.jsonl \
  | jq -s 'group_by(.ticket) | map(max_by(.ts))' > resolved-cost.json

jq '[.[].costUsd] | add/length' resolved-cost.json          # mean
jq '[.[].costUsd] | sort' resolved-cost.json                # full distribution, for the median/range
```

## Limitations

- Single maintainer, single workspace. Not a multi-deployment study.
- The auto-merge split (section 2) measures eligibility by branch-naming convention, not a
  confirmed automated-click audit — see the caveat there.
- The revert-rate methodology (section 3) only catches `git revert`-style commits with the
  standard trailer.
- The cost sample (section 4) is 32 tickets from a 6-week telemetry window, not the full 281
  resolved-ticket history — earlier tickets ran before cost tracking existed and can't be
  reconstructed after the fact.

All queries above are plain `git`/`gh`/`jq` — no proprietary tooling. Run them against your own
`GOVERN_MERGE_REPOS` and `governor/ticket-history.jsonl` to audit your own deployment the same way.
