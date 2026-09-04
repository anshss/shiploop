#!/usr/bin/env node
// Generates bench/fixtures/replay-fleet/, the synthetic fleet workspace the replay tests read.
//
// Nothing here is a measurement. The shapes are copied from the real corpus (result event with a
// full usage object, 1-hour cache writes only, per-assistant-event output_tokens that are truncated
// snapshots rather than a running total, modelUsage per model) and the magnitudes are chosen so the
// expected output is checkable by hand. The derivation is in fixtures/README.md.
//
// Regenerate with: node bench/fixtures/make-replay-fixture.mjs

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.join(HERE, 'replay-fleet');
const RUN = 'run-20260101-000000';

// Each ticket: turns whose CONTEXT (input + cacheRead + cacheCreation) is stated directly.
// Turn 1 primes the session: input 10000, cacheCreation 12000, the rest cache read.
// Every later turn: cacheCreation 5000, the rest cache read, no fresh input.
const PRIME_INPUT = 10_000;
const PRIME_WRITE = 12_000;
const STEP_WRITE = 5_000;

const TICKETS = [
  { id: '101', model: 'claude-opus-4-8', output: 40_000, ctx: [50_000, 100_000, 150_000, 200_000, 250_000, 300_000, 350_000, 400_000] },
  { id: '102', model: 'claude-opus-4-8', output: 30_000, ctx: [50_000, 100_000, 150_000, 200_000, 250_000, 300_000] },
  { id: '103', model: 'claude-opus-4-8', output: 20_000, ctx: [50_000, 100_000, 150_000, 200_000, 250_000] },
  { id: '104', model: 'claude-sonnet-5', output: 25_000, ctx: [300_000, 500_000, 700_000] },
];

const RATES = { opus: { i: 5, o: 25 }, sonnet: { i: 2, o: 10 }, haiku: { i: 1, o: 5 } };
const tier = (m) => (m.includes('opus') ? 'opus' : m.includes('sonnet') ? 'sonnet' : 'haiku');

function turnsFor(t) {
  return t.ctx.map((ctx, k) => {
    const cacheCreation = k === 0 ? PRIME_WRITE : STEP_WRITE;
    const input = k === 0 ? PRIME_INPUT : 0;
    return { ctx, input, cacheCreation, cacheRead: ctx - input - cacheCreation };
  });
}

function session(t) {
  const turns = turnsFor(t);
  const billed = turns.reduce(
    (a, x) => ({
      input: a.input + x.input,
      cacheRead: a.cacheRead + x.cacheRead,
      cacheCreation: a.cacheCreation + x.cacheCreation,
    }),
    { input: 0, cacheRead: 0, cacheCreation: 0 },
  );
  const r = RATES[tier(t.model)];
  // The reported cost is set to exactly what published rates give, so the fixture pins the
  // reconciliation ratio at 1.000 and a rate-table regression shows up as a ratio drift.
  const cost =
    (billed.input * r.i + t.output * r.o + billed.cacheRead * r.i * 0.1 + billed.cacheCreation * r.i * 2) / 1e6;
  return { turns, billed, cost };
}

function lines(t) {
  const { turns, billed, cost } = session(t);
  const out = [];
  out.push(
    JSON.stringify({
      type: 'system',
      subtype: 'init',
      session_id: `fixture-${t.id}`,
      model: t.model,
    }),
  );
  turns.forEach((turn, k) => {
    const usage = {
      input_tokens: turn.input,
      cache_creation_input_tokens: turn.cacheCreation,
      cache_read_input_tokens: turn.cacheRead,
      cache_creation: { ephemeral_5m_input_tokens: 0, ephemeral_1h_input_tokens: turn.cacheCreation },
      // Truncated snapshot, exactly as the real stream emits it. It does not accumulate across
      // content blocks and it is nowhere near the session's real output. Anything that sums this
      // undercounts output by more than an order of magnitude, which is why the tool never does.
      output_tokens: 4,
      service_tier: 'standard',
    };
    const id = `msg_fixture_${t.id}_${k}`;
    // Three content-block events per turn, same message id, same usage snapshot.
    for (let b = 0; b < 3; b++) {
      out.push(
        JSON.stringify({
          type: 'assistant',
          message: { id, model: t.model, role: 'assistant', type: 'message', usage },
          session_id: `fixture-${t.id}`,
        }),
      );
    }
    out.push(JSON.stringify({ type: 'user', session_id: `fixture-${t.id}` }));
  });
  const mu = {};
  mu[t.model] = {
    inputTokens: billed.input,
    outputTokens: t.output,
    cacheReadInputTokens: billed.cacheRead,
    cacheCreationInputTokens: billed.cacheCreation,
    webSearchRequests: 0,
    costUSD: cost,
  };
  out.push(
    JSON.stringify({
      type: 'result',
      subtype: 'success',
      is_error: false,
      num_turns: turns.length,
      session_id: `fixture-${t.id}`,
      total_cost_usd: cost,
      usage: {
        input_tokens: billed.input,
        cache_creation_input_tokens: billed.cacheCreation,
        cache_read_input_tokens: billed.cacheRead,
        output_tokens: t.output,
        cache_creation: { ephemeral_5m_input_tokens: 0, ephemeral_1h_input_tokens: billed.cacheCreation },
        service_tier: 'standard',
      },
      modelUsage: mu,
    }),
  );
  return out.join('\n') + '\n';
}

fs.rmSync(ROOT, { recursive: true, force: true });
for (const t of TICKETS) {
  const dir = path.join(ROOT, 'logs', 'govern', RUN, `ticket-${t.id}`);
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, 'worker.jsonl'), lines(t));
}

// A session killed before it emitted a result event. It must be excluded and counted as excluded,
// never silently priced at zero.
const killedDir = path.join(ROOT, 'logs', 'govern', RUN, 'ticket-105');
fs.mkdirSync(killedDir, { recursive: true });
fs.writeFileSync(
  path.join(killedDir, 'worker.jsonl'),
  [
    JSON.stringify({ type: 'system', subtype: 'init', session_id: 'fixture-105' }),
    JSON.stringify({
      type: 'assistant',
      message: {
        id: 'msg_fixture_105_0',
        model: 'claude-opus-4-8',
        usage: {
          input_tokens: 10_000,
          cache_creation_input_tokens: 12_000,
          cache_read_input_tokens: 28_000,
          output_tokens: 4,
        },
      },
      session_id: 'fixture-105',
    }),
  ].join('\n') + '\n',
);

// state.jsonl is governor bookkeeping, not a transcript. The scanner must skip it by name.
fs.writeFileSync(path.join(ROOT, 'logs', 'govern', RUN, 'state.jsonl'), '{"phase":"done"}\n');

fs.mkdirSync(path.join(ROOT, 'governor'), { recursive: true });
fs.writeFileSync(
  path.join(ROOT, 'governor', 'ticket-history.jsonl'),
  [
    { ticket: 101, run: RUN, status: 'resolved', ts: 1_800_000_001 },
    { ticket: 102, run: RUN, status: 'resolved', ts: 1_800_000_002 },
    { ticket: 103, run: RUN, status: 'failed', ts: 1_800_000_003 },
    { ticket: 104, run: RUN, status: 'resolved', ts: 1_800_000_004 },
    { ticket: 105, run: RUN, status: 'failed', ts: 1_800_000_005 },
  ]
    .map((r) => JSON.stringify(r))
    .join('\n') + '\n',
);

// The tickets must replay in the order they completed. Transcript mtime is the ordering key, so
// stamp them monotonically rather than relying on the order the generator happened to write them.
let t0 = 1_800_000_000_000;
for (const t of TICKETS) {
  const f = path.join(ROOT, 'logs', 'govern', RUN, `ticket-${t.id}`, 'worker.jsonl');
  const when = new Date((t0 += 60_000));
  fs.utimesSync(f, when, when);
}

// A second fleet with a logs/govern directory and nothing in it. Discovery must accept it and the
// report must say there is nothing to replay instead of dividing by zero.
const EMPTY = path.join(HERE, 'replay-empty-fleet');
fs.rmSync(EMPTY, { recursive: true, force: true });
fs.mkdirSync(path.join(EMPTY, 'logs', 'govern'), { recursive: true });
fs.writeFileSync(path.join(EMPTY, 'logs', 'govern', '.keep'), '');

console.log(`wrote ${ROOT} and ${EMPTY}`);

// ── golden-results.jsonl ─────────────────────────────────────────────────────
// The rollup's golden fixture, expressed from the SAME sessions. The shiploop rows are the
// fixture's four worker sessions verbatim. The vanilla row is not an invented measurement and not
// a measurement at all: it is what bench/replay.mjs's 1M-context model says the same four tickets
// would have cost in one accumulating session, so nothing in the test suite asserts a headline
// that was made up. It is labelled `modeled` in the row itself.
//
// There is no driver row. The real corpus logs worker sessions only, so the shiploop arm here
// understates itself by whatever the driver spent. That direction is stated in METHODOLOGY.md.
import { execFileSync } from 'node:child_process';

const replay = JSON.parse(
  execFileSync(process.execPath, [path.join(HERE, '..', 'replay.mjs'), '--fleet', ROOT, '--arm', '1m', '--json'], {
    encoding: 'utf8',
  }),
).arms['1m'];

const base = {
  run: 'golden',
  backlog: 'fixture-backlog',
  rep: 1,
  cli_version: 'fixture',
  status: 'resolved',
  resolved: true,
  usageSource: 'result',
  wallMs: 600000,
  verifyExit: 0,
  startedAt: 1780000000,
};
const tok = (b, total) => ({ ...b, total });
const rows = [];

const vanTotal = replay.vanillaTokens;
rows.push({
  kind: 'session',
  ...base,
  task: 'fixture-backlog',
  arm: 'vanilla',
  model: 'modeled',
  provenance: 'modeled',
  turns: 22,
  tokens: tok(replay.vanillaBreakdown, vanTotal),
  costUsd: replay.vanillaCostUsd,
});
rows.push({
  kind: 'rollup',
  ...base,
  task: 'fixture-backlog',
  arm: 'vanilla',
  model: 'modeled',
  provenance: 'modeled',
  turns: 22,
  tokens: tok(replay.vanillaBreakdown, vanTotal),
  costUsd: replay.vanillaCostUsd,
  usageSource: 'rollup',
  sessions: 1,
  costUsdSessions: 1,
  ticketsCleared: 4,
  ticketsTotal: 4,
  costUsdTotal: replay.vanillaCostUsd,
  tokensTotal: vanTotal,
});

let shipCost = 0;
let shipTurns = 0;
for (const t of TICKETS) {
  const { turns, billed, cost } = session(t);
  const total = billed.input + billed.cacheRead + billed.cacheCreation + t.output;
  shipCost += cost;
  shipTurns += turns.length;
  rows.push({
    kind: 'session',
    ...base,
    task: `worker-${t.id}`,
    arm: 'shiploop',
    model: t.model,
    provenance: 'measured',
    turns: turns.length,
    tokens: tok({ input: billed.input, output: t.output, cacheRead: billed.cacheRead, cacheCreation: billed.cacheCreation }, total),
    costUsd: cost,
  });
}
rows.push({
  kind: 'rollup',
  ...base,
  task: 'fixture-backlog',
  arm: 'shiploop',
  model: 'mixed',
  provenance: 'measured',
  turns: shipTurns,
  tokens: tok(replay.shiploopBreakdown, replay.shiploopTokens),
  costUsd: shipCost,
  usageSource: 'rollup',
  sessions: TICKETS.length,
  costUsdSessions: TICKETS.length,
  ticketsCleared: 4,
  ticketsTotal: 4,
  costUsdTotal: shipCost,
  tokensTotal: replay.shiploopTokens,
});

fs.writeFileSync(path.join(HERE, 'golden-results.jsonl'), rows.map((r) => JSON.stringify(r)).join('\n') + '\n');
console.log('wrote golden-results.jsonl');
