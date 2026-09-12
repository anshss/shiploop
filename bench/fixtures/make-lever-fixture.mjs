#!/usr/bin/env node
// Generates bench/fixtures/replay-lever-fleet/, the synthetic fleet the multi-lever tests read.
//
// Nothing here is a measurement. It is a three-session run whose every figure is checkable by
// hand, chosen to exercise exactly the things the earlier fixture cannot:
//
//   - three tiers in one run (opus driver, sonnet worker, haiku worker), so `--baseline
//     driver-tier` has something to reprice and the routing credit is not zero by construction
//   - an orchestration transcript (governor.jsonl), so there is overhead to charge
//   - a `driver-model` stamp, so the driver tier is resolved rather than guessed
//   - a session killed before its result event, so `--partials price|drop` differ
//   - a lever-events.jsonl carrying all four instrumentation events, plus one unrecognised
//     event, one unrecognised scripted-action class, and one unparseable line
//
// The derivation table is in fixtures/README.md. Regenerate with:
//   node bench/fixtures/make-lever-fixture.mjs

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.join(HERE, 'replay-lever-fleet');
const RUN = 'run-20260201-000000';
const DRIVER_MODEL = 'claude-opus-4-8';

const RATES = { opus: { i: 5, o: 25 }, sonnet: { i: 2, o: 10 }, haiku: { i: 1, o: 5 } };
const tier = (m) => (m.includes('opus') ? 'opus' : m.includes('sonnet') ? 'sonnet' : 'haiku');

// Every turn states its own context split directly, so `input + cacheRead + cacheCreation` is the
// turn's context and nothing has to be inferred.
const TICKETS = [
  {
    id: '201',
    model: 'claude-sonnet-5',
    output: 10_000,
    turns: [
      { input: 10_000, cacheCreation: 20_000, cacheRead: 70_000 },
      { input: 0, cacheCreation: 0, cacheRead: 200_000 },
    ],
  },
  {
    id: '202',
    model: 'claude-haiku-4-5',
    output: 10_000,
    turns: [
      { input: 10_000, cacheCreation: 0, cacheRead: 90_000 },
      { input: 0, cacheCreation: 0, cacheRead: 100_000 },
    ],
  },
  {
    // Killed before it emitted a result event. Its input side is exactly recoverable, its output
    // is not, so `--partials price` counts 50,000 tokens here and `--partials drop` counts none.
    id: '203',
    model: 'claude-sonnet-5',
    output: 0,
    partial: true,
    turns: [{ input: 10_000, cacheCreation: 10_000, cacheRead: 30_000 }],
  },
];

const ORCHESTRATION = {
  file: 'governor.jsonl',
  model: DRIVER_MODEL,
  output: 5_000,
  turns: [{ input: 20_000, cacheCreation: 0, cacheRead: 0 }],
};

function billedOf(t) {
  return t.turns.reduce(
    (a, x) => ({
      input: a.input + x.input,
      cacheRead: a.cacheRead + x.cacheRead,
      cacheCreation: a.cacheCreation + x.cacheCreation,
    }),
    { input: 0, cacheRead: 0, cacheCreation: 0 },
  );
}

function costOf(t) {
  const b = billedOf(t);
  const r = RATES[tier(t.model)];
  return (b.input * r.i + t.output * r.o + b.cacheRead * r.i * 0.1 + b.cacheCreation * r.i * 2) / 1e6;
}

function lines(t) {
  const out = [];
  out.push(
    JSON.stringify({
      type: 'system',
      subtype: 'init',
      model: t.model,
      claude_code_version: '2.1.246',
      session_id: `sess-${t.id || 'orch'}`,
    }),
  );
  t.turns.forEach((turn, k) => {
    out.push(
      JSON.stringify({
        type: 'assistant',
        message: {
          id: `msg_${t.id || 'orch'}_${k}`,
          model: t.model,
          usage: {
            input_tokens: turn.input,
            cache_read_input_tokens: turn.cacheRead,
            cache_creation_input_tokens: turn.cacheCreation,
            output_tokens: 4,
          },
        },
      }),
    );
  });
  if (t.partial) return out; // no result event: the session was killed
  const b = billedOf(t);
  out.push(
    JSON.stringify({
      type: 'result',
      subtype: 'success',
      session_id: `sess-${t.id || 'orch'}`,
      num_turns: t.turns.length,
      total_cost_usd: costOf(t),
      usage: {
        input_tokens: b.input,
        output_tokens: t.output,
        cache_read_input_tokens: b.cacheRead,
        cache_creation_input_tokens: b.cacheCreation,
        cache_creation: { ephemeral_1h_input_tokens: b.cacheCreation, ephemeral_5m_input_tokens: 0 },
      },
      modelUsage: {
        [t.model]: {
          inputTokens: b.input,
          outputTokens: t.output,
          cacheReadInputTokens: b.cacheRead,
          cacheCreationInputTokens: b.cacheCreation,
        },
      },
    }),
  );
  return out;
}

// The four instrumentation events, exactly as bench/LEVER-EVENTS.md defines them, plus the three
// things a reader must survive: an event it does not know, a scripted-action class it has no
// estimate for, and a line that is not JSON at all.
const LEVER_EVENTS = [
  '{"event":"watchdog-kill","ts":1801000000,"ticket":201,"session":"worker","tier":"sonnet","ctxTokens":300000,"turns":40,"reason":"context-cap"}',
  '{"event":"resume","ts":1801000001,"ticket":202,"session":"worker","tier":"haiku","checkpointTokens":10000,"freshStartTokens":60000}',
  '{"event":"scripted-action","ts":1801000002,"ticket":null,"session":"driver","tier":null,"class":"version-bump"}',
  '{"event":"scripted-action","ts":1801000003,"ticket":null,"session":"driver","tier":null,"class":"not-a-known-class"}',
  '{"event":"escalation","ts":1801000004,"ticket":201,"session":"worker","failedTier":"haiku","failedTokens":50000}',
  '{"event":"a-future-event-this-reader-does-not-know","ts":1801000005}',
  'this line is not json at all',
];

function write(p, body) {
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.writeFileSync(p, body.endsWith('\n') ? body : `${body}\n`);
}

fs.rmSync(ROOT, { recursive: true, force: true });
const runDir = path.join(ROOT, 'logs', 'govern', RUN);

for (const t of TICKETS) write(path.join(runDir, `ticket-${t.id}`, 'worker.jsonl'), lines(t).join('\n'));
write(path.join(runDir, ORCHESTRATION.file), lines(ORCHESTRATION).join('\n'));
write(path.join(runDir, 'lever-events.jsonl'), LEVER_EVENTS.join('\n'));
write(path.join(runDir, 'driver-model'), DRIVER_MODEL);
write(path.join(runDir, 'shiploop-version'), '1.19.0');
write(
  path.join(runDir, 'state.jsonl'),
  TICKETS.map((t) => JSON.stringify({ ticket: Number(t.id), status: 'resolved', note: 'fixture' })).join('\n'),
);
write(
  path.join(ROOT, 'governor', 'ticket-history.jsonl'),
  TICKETS.map((t, k) => JSON.stringify({ run: RUN, ticket: Number(t.id), status: 'resolved', ts: 1801000000 + k })).join(
    '\n',
  ),
);

// A second run that aborted before dispatch: 0-byte state.jsonl, no transcripts. It is not a bench
// input and it must not become one, but it IS counted and printed.
const abortDir = path.join(ROOT, 'logs', 'govern', 'run-20260202-000000');
fs.mkdirSync(abortDir, { recursive: true });
fs.writeFileSync(path.join(abortDir, 'state.jsonl'), '');

console.log(`wrote ${ROOT}`);
for (const t of TICKETS) {
  const b = billedOf(t);
  console.log(
    `  ticket ${t.id} ${tier(t.model).padEnd(6)} tokens ${b.input + b.cacheRead + b.cacheCreation + t.output} ` +
      `cost ${t.partial ? '(partial, recovered)' : `$${costOf(t).toFixed(6)}`}`,
  );
}
console.log(`  orchestration ${tier(ORCHESTRATION.model)} cost $${costOf(ORCHESTRATION).toFixed(6)}`);
