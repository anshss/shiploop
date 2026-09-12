#!/usr/bin/env node
// Generates bench/fixtures/replay-attribution-fleet/, the fixture for the two catch-up readers
// added after bench was last updated at 09ab731:
//
//   tierAttribution  -- the per-attempt sizing fields record_attempt() has always written into
//                       attempts.jsonl and replay.mjs used to load and throw away (it read only
//                       retryClass). Precision grade DRIVES tier selection, so without these the
//                       report can say which tier ran a ticket and never why.
//   advisorSpend     -- advisor-consult.sh's FLAT per-ticket ledger ($LOG_ROOT/ticket-N/
//                       advisor.jsonl, deliberately not run-scoped). Real tokens on a worker's
//                       dispatch, in no transcript bench walks.
//
// Shaped so both halves of every contract are real, not just the happy path:
//   run-20260401-000000
//     ticket-801  fully attributed ledger row (grade + source + effort + respec requested), and a
//                 two-row advisor ledger (claim + record) for a ticket that appears in EXACTLY ONE
//                 run -> attributable spend.
//     ticket-802  OLD-SHAPE ledger row: no precisionGrade/precisionSource/respecRequested keys at
//                 all, the way every row written before those fields existed looks. Must bucket as
//                 `unrecorded`, never as a zero and never as `none`. Also appears in a SECOND run
//                 below, so its advisor ledger is unattributable and must say so.
//     ticket-803  ledger row carrying the keys with NULL values -- the harness recording "there was
//                 no grade here". Must bucket as `none`, distinct from ticket-802's `unrecorded`.
//     ticket-804  no attempts.jsonl at all -> unattributed, reason `no-ledger`.
//   run-20260401-000001
//     ticket-802  the second appearance that makes its advisor spend unattributable.
//   ticket-999    an advisor ledger for a ticket with NO transcript anywhere in the corpus ->
//                 unattributed, reason `ticket-not-in-corpus`. Real spend, charged to no arm.
//   logs/govern/lever-events.jsonl  two RUN-LESS interactive-lane rows (the shape
//                 templates/hooks/agent-watchdog-guard.sh emits, which has no GOVERN_RUN_DIR):
//                 counted by the reader, credited nowhere.
//
// Regenerate with: node bench/fixtures/make-attribution-fixture.mjs

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.join(HERE, 'replay-attribution-fleet');
const RUN = 'run-20260401-000000';
const RUN2 = 'run-20260401-000001';

const RATES = { opus: { i: 5, o: 25 }, sonnet: { i: 2, o: 10 }, haiku: { i: 1, o: 5 } };
const tier = (m) => (m.includes('opus') ? 'opus' : m.includes('sonnet') ? 'sonnet' : 'haiku');

// One turn, one result event: the simplest transcript that still carries a real usage object. Only
// the sibling LEDGERS are under test here, never the transcript parser.
function transcript(sessionId, model, input, cacheRead, cacheCreation, output) {
  const r = RATES[tier(model)];
  const cost = (input * r.i + output * r.o + cacheRead * r.i * 0.1 + cacheCreation * r.i * 2) / 1e6;
  return (
    [
      JSON.stringify({ type: 'system', subtype: 'init', session_id: sessionId, model }),
      JSON.stringify({
        type: 'assistant',
        message: {
          id: `${sessionId}-msg-0`,
          model,
          usage: {
            input_tokens: input,
            cache_creation_input_tokens: cacheCreation,
            cache_read_input_tokens: cacheRead,
            output_tokens: 3,
          },
        },
        session_id: sessionId,
      }),
      JSON.stringify({
        type: 'result',
        subtype: 'success',
        is_error: false,
        num_turns: 1,
        session_id: sessionId,
        total_cost_usd: cost,
        usage: {
          input_tokens: input,
          cache_creation_input_tokens: cacheCreation,
          cache_read_input_tokens: cacheRead,
          output_tokens: output,
          cache_creation: { ephemeral_5m_input_tokens: 0, ephemeral_1h_input_tokens: cacheCreation },
        },
      }),
    ].join('\n') + '\n'
  );
}

fs.rmSync(ROOT, { recursive: true, force: true });

function ticketDir(run, n) {
  const dir = path.join(ROOT, 'logs', 'govern', run, `ticket-${n}`);
  fs.mkdirSync(dir, { recursive: true });
  return dir;
}

// ── ticket-801: every sizing field recorded. The row a CURRENT spawn-worker.sh writes. ──────────
{
  const dir = ticketDir(RUN, 801);
  fs.writeFileSync(path.join(dir, 'worker.jsonl'), transcript('fx-801', 'claude-sonnet-5', 5_000, 20_000, 8_000, 3_000));
  fs.writeFileSync(
    path.join(dir, 'attempts.jsonl'),
    JSON.stringify({
      attempt: 1,
      model: 'claude-sonnet-5',
      modelSource: 'precision-grade',
      effort: 'high',
      effortSource: 'precision-grade',
      ticketModel: null,
      isRetry: false,
      retryClass: 'first-attempt',
      retryReason: 'first attempt -- no prior failure to classify',
      respecRequested: true,
      respecClass: 'underspecified',
      precisionGrade: 'stated',
      precisionSource: 'ticket-field',
      advisorBudget: 1,
      mode: 'brief',
      status: 'resolved',
      ts: 1_806_000_001,
    }) + '\n',
  );
}

// ── ticket-802: the PRE-FIELD row shape. No precision*, no respecRequested keys at all. ─────────
{
  const dir = ticketDir(RUN, 802);
  fs.writeFileSync(path.join(dir, 'worker.jsonl'), transcript('fx-802', 'claude-opus-4-8', 6_000, 12_000, 9_000, 2_000));
  fs.writeFileSync(
    path.join(dir, 'attempts.jsonl'),
    JSON.stringify({
      attempt: 1,
      model: 'claude-opus-4-8',
      modelSource: 'GOVERN_WORKER_MODEL',
      effort: null,
      effortSource: 'none (unset)',
      retryClass: 'first-attempt',
      mode: 'brief',
      status: 'resolved',
      ts: 1_806_000_002,
    }) + '\n',
  );
}

// ── ticket-803: the keys ARE there, carrying null. "No grade", not "no field". ──────────────────
{
  const dir = ticketDir(RUN, 803);
  fs.writeFileSync(path.join(dir, 'worker.jsonl'), transcript('fx-803', 'claude-haiku-4-5-20251001', 4_000, 10_000, 6_000, 1_000));
  fs.writeFileSync(
    path.join(dir, 'attempts.jsonl'),
    JSON.stringify({
      attempt: 1,
      model: 'claude-haiku-4-5-20251001',
      modelSource: 'GOVERN_WORKER_MODEL',
      effort: null,
      effortSource: 'none (unset)',
      retryClass: 'first-attempt',
      respecRequested: false,
      respecClass: null,
      precisionGrade: null,
      precisionSource: null,
      advisorBudget: 2,
      mode: 'brief',
      status: 'resolved',
      ts: 1_806_000_003,
    }) + '\n',
  );
}

// ── ticket-804: no ledger at all. Unattributed with a named reason, never folded into a bucket. ──
{
  const dir = ticketDir(RUN, 804);
  fs.writeFileSync(path.join(dir, 'worker.jsonl'), transcript('fx-804', 'claude-sonnet-5', 3_000, 9_000, 5_000, 1_000));
}

// ── run 2: ticket-802 again. Two runs for one ticket is what makes its flat advisor ledger
// unattributable -- the ledger names a ticket and nothing else.
{
  const dir = ticketDir(RUN2, 802);
  fs.writeFileSync(path.join(dir, 'worker.jsonl'), transcript('fx-802b', 'claude-sonnet-5', 4_000, 11_000, 5_000, 2_000));
  fs.writeFileSync(
    path.join(dir, 'attempts.jsonl'),
    JSON.stringify({
      attempt: 1,
      model: 'claude-sonnet-5',
      modelSource: 'GOVERN_WORKER_MODEL',
      effort: 'medium',
      effortSource: 'GOVERN_WORKER_EFFORT',
      retryClass: 'first-attempt',
      respecRequested: false,
      precisionGrade: 'scoped',
      precisionSource: 'inferred',
      mode: 'brief',
      status: 'resolved',
      ts: 1_806_000_004,
    }) + '\n',
  );
}

// ── advisor ledgers: FLAT, at logs/govern/ticket-N/advisor.jsonl, never under a run. Exactly the
// path govern::advisor_ledger_path builds, and exactly the two row kinds it writes.
function advisorLedger(n, rows) {
  const dir = path.join(ROOT, 'logs', 'govern', `ticket-${n}`);
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, 'advisor.jsonl'), rows.map((r) => JSON.stringify(r)).join('\n') + '\n');
}

// 801: one consult, attributable (the ticket appears in exactly one run). 4000 opus tokens.
advisorLedger(801, [
  { ts: 1_806_000_010, event: 'claim', consultId: 1, sessionId: 'sess-a', question: 'which seam?', turn: '12' },
  {
    ts: 1_806_000_011,
    event: 'record',
    consultId: 1,
    model: 'claude-opus-4-8',
    tokens: 4000,
    answer: 'the wire shape, not the helper',
    workerRemaining: 0,
    sessionRemaining: 5,
  },
]);

// 802: spend that CANNOT be attributed -- the ticket ran in two runs and the row names neither.
advisorLedger(802, [
  { ts: 1_806_000_020, event: 'claim', consultId: 1, sessionId: 'sess-a', question: null, turn: null },
  {
    ts: 1_806_000_021,
    event: 'record',
    consultId: 1,
    model: 'claude-opus-4-8',
    tokens: 1000,
    answer: 'ambiguous',
    workerRemaining: 1,
    sessionRemaining: 4,
  },
]);

// 999: a ticket with no transcript in this corpus at all. Real spend, no run, no arm.
advisorLedger(999, [
  {
    ts: 1_806_000_030,
    event: 'record',
    consultId: 1,
    model: 'claude-sonnet-5',
    tokens: 500,
    answer: 'orphan',
    workerRemaining: 1,
    sessionRemaining: 3,
  },
]);

// ── run-less lever events: the interactive lane's own emission path. Counted, credited nowhere. ──
fs.writeFileSync(
  path.join(ROOT, 'logs', 'govern', 'lever-events.jsonl'),
  [
    {
      event: 'watchdog-kill',
      ts: 1_806_000_040,
      ticket: null,
      session: 'worker',
      tier: null,
      ctxTokens: 120000,
      turns: 44,
      reason: 'wall-clock-timeout',
      lane: 'interactive',
    },
    {
      event: 'watchdog-kill',
      ts: 1_806_000_041,
      ticket: null,
      session: 'worker',
      tier: null,
      ctxTokens: 200000,
      turns: 91,
      reason: 'wall-clock-timeout',
      lane: 'interactive',
    },
  ]
    .map((r) => JSON.stringify(r))
    .join('\n') + '\n',
);

fs.mkdirSync(path.join(ROOT, 'governor'), { recursive: true });
fs.writeFileSync(
  path.join(ROOT, 'governor', 'ticket-history.jsonl'),
  [
    { ticket: 801, run: RUN, status: 'resolved', ts: 1_806_000_001 },
    { ticket: 802, run: RUN, status: 'resolved', ts: 1_806_000_002 },
    { ticket: 803, run: RUN, status: 'resolved', ts: 1_806_000_003 },
    { ticket: 804, run: RUN, status: 'resolved', ts: 1_806_000_004 },
    { ticket: 802, run: RUN2, status: 'resolved', ts: 1_806_000_005 },
  ]
    .map((r) => JSON.stringify(r))
    .join('\n') + '\n',
);

console.log(`wrote ${ROOT}`);
