#!/usr/bin/env node
// Generates bench/fixtures/replay-outcome-fleet/, the fixture for the attempt-outcome breakdown
// ("no attempt-outcome dimension"). Exercises the per-attempt LEDGER read
// (spawn-worker.sh's `attempts.jsonl`, sibling of the transcript) that replay.mjs's
// outcomeBreakdown() reads to say WHY an attempt happened, not just how many tokens it cost.
//
// Three tickets, chosen so both sides of the "present class, absent class" contract are real:
//   ticket-701  two attempts, ledger present: attempt 1 (first-attempt, failed) is superseded by
//               attempt 2 (judgment, resolved) -- the ordinary retry shape, exercising the
//               worker.attempt1.jsonl / worker.jsonl rotation the classifier keys off.
//   ticket-702  one attempt, ledger present, retryClass "infra" -- a class other than
//               first-attempt/judgment actually gets read, not just whichever one happens first.
//   ticket-703  one attempt, NO ledger at all -- an uninstrumented/pre-ledger dispatch, which must
//               land in `unclassified` (reason `no-ledger`), never silently folded into `unknown`.
//
// Regenerate with: node bench/fixtures/make-outcome-fixture.mjs

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.join(HERE, 'replay-outcome-fleet');
const RUN = 'run-20260301-000000';

const RATES = { opus: { i: 5, o: 25 }, sonnet: { i: 2, o: 10 }, haiku: { i: 1, o: 5 } };
const tier = (m) => (m.includes('opus') ? 'opus' : m.includes('sonnet') ? 'sonnet' : 'haiku');

// One turn, one result event -- the simplest transcript shape that still carries a real usage
// object, since only the ledger's own classification is under test here.
function transcript(sessionId, model, input, cacheRead, cacheCreation, output) {
  const r = RATES[tier(model)];
  const cost = (input * r.i + output * r.o + cacheRead * r.i * 0.1 + cacheCreation * r.i * 2) / 1e6;
  return {
    text:
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
      ].join('\n') + '\n',
    cost,
  };
}

function ledgerRow(attempt, model, retryClass, status, tok, costUsd) {
  return (
    JSON.stringify({
      attempt,
      model,
      modelSource: 'GOVERN_WORKER_MODEL',
      effort: null,
      effortSource: 'none (unset)',
      ticketModel: null,
      isRetry: attempt > 1,
      retryClass,
      retryReason: retryClass === 'first-attempt' ? 'first attempt -- no prior failure to classify' : 'fixture',
      respecRequested: false,
      respecClass: null,
      precisionGrade: null,
      precisionSource: null,
      mode: 'brief',
      status,
      ts: 1_803_000_000 + attempt,
      tokens: tok,
      costUsd,
      usageSource: 'result',
    }) + '\n'
  );
}

fs.rmSync(ROOT, { recursive: true, force: true });

// ── ticket-701: two attempts, ledger present. Attempt 1 fails (a coherent PR that did not land,
// classified `judgment` by the classifier ONCE attempt 2 is dispatched); attempt 2 resolves.
{
  const dir = path.join(ROOT, 'logs', 'govern', RUN, 'ticket-701');
  fs.mkdirSync(dir, { recursive: true });
  const a1 = transcript('fixture-701-1', 'claude-sonnet-5', 5_000, 20_000, 8_000, 3_000);
  const a2 = transcript('fixture-701-2', 'claude-sonnet-5', 5_000, 30_000, 8_000, 4_000);
  fs.writeFileSync(path.join(dir, 'worker.attempt1.jsonl'), a1.text);
  fs.writeFileSync(path.join(dir, 'worker.jsonl'), a2.text);
  const tok1 = { input: 5_000, output: 3_000, cacheRead: 20_000, cacheCreation: 8_000, total: 36_000 };
  const tok2 = { input: 5_000, output: 4_000, cacheRead: 30_000, cacheCreation: 8_000, total: 47_000 };
  fs.writeFileSync(
    path.join(dir, 'attempts.jsonl'),
    ledgerRow(1, 'claude-sonnet-5', 'first-attempt', 'failed', tok1, a1.cost) +
      ledgerRow(2, 'claude-sonnet-5', 'judgment', 'resolved', tok2, a2.cost),
  );
}

// ── ticket-702: one attempt, ledger present, retryClass "infra" -- proves a class OTHER than
// first-attempt/judgment is actually read off the ledger, not just whichever sorts first.
{
  const dir = path.join(ROOT, 'logs', 'govern', RUN, 'ticket-702');
  fs.mkdirSync(dir, { recursive: true });
  const a2 = transcript('fixture-702-2', 'claude-opus-4-8', 6_000, 12_000, 9_000, 2_000);
  fs.writeFileSync(path.join(dir, 'worker.jsonl'), a2.text);
  const tok2 = { input: 6_000, output: 2_000, cacheRead: 12_000, cacheCreation: 9_000, total: 29_000 };
  // Only attempt 2's row is present (attempt 1's own ledger write is not part of this fixture --
  // the classifier only ever needs the CURRENT transcript's own attempt number resolved).
  fs.writeFileSync(path.join(dir, 'attempts.jsonl'), ledgerRow(2, 'claude-opus-4-8', 'infra', 'resolved', tok2, a2.cost));
}

// ── ticket-703: one attempt, NO ledger at all -- an uninstrumented, pre-ledger dispatch. Must land
// in `unclassified` (reason `no-ledger`), never silently folded into the classifier's own
// `unknown` verdict.
{
  const dir = path.join(ROOT, 'logs', 'govern', RUN, 'ticket-703');
  fs.mkdirSync(dir, { recursive: true });
  const a1 = transcript('fixture-703-1', 'claude-haiku-4-5-20251001', 4_000, 10_000, 6_000, 1_000);
  fs.writeFileSync(path.join(dir, 'worker.jsonl'), a1.text);
}

fs.mkdirSync(path.join(ROOT, 'governor'), { recursive: true });
fs.writeFileSync(
  path.join(ROOT, 'governor', 'ticket-history.jsonl'),
  [
    { ticket: 701, run: RUN, status: 'resolved', ts: 1_803_000_002 },
    { ticket: 702, run: RUN, status: 'resolved', ts: 1_803_000_003 },
    { ticket: 703, run: RUN, status: 'resolved', ts: 1_803_000_004 },
  ]
    .map((r) => JSON.stringify(r))
    .join('\n') + '\n',
);

console.log(`wrote ${ROOT}`);
