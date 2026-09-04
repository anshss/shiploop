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

// ── replay-init-model-fleet ──────────────────────────────────────────────────
// One session whose result event omits modelUsage and whose only assistant message is a synthetic
// notice carrying no model. The model name exists in exactly one place: the `system`/`init` event.
// A tool that does not read it prices this session at the most expensive tier by default. It lives
// in its own fleet so the main golden numbers stay untouched.
const INIT_FLEET = path.join(HERE, 'replay-init-model-fleet');
const INIT_MODEL = 'claude-haiku-4-5-20251001';
{
  fs.rmSync(INIT_FLEET, { recursive: true, force: true });
  const dir = path.join(INIT_FLEET, 'logs', 'govern', RUN, 'ticket-201');
  fs.mkdirSync(dir, { recursive: true });
  const billed = { input: 5_000, cacheCreation: 5_000, cacheRead: 40_000 };
  const output = 2_000;
  const r = RATES.haiku;
  const cost =
    (billed.input * r.i + output * r.o + billed.cacheRead * r.i * 0.1 + billed.cacheCreation * r.i * 2) / 1e6;
  fs.writeFileSync(
    path.join(dir, 'worker.jsonl'),
    [
      JSON.stringify({ type: 'system', subtype: 'init', session_id: 'fixture-201', model: INIT_MODEL }),
      JSON.stringify({
        type: 'assistant',
        message: {
          id: 'msg_fixture_201_0',
          model: '<synthetic>',
          usage: { input_tokens: 0, cache_creation_input_tokens: 0, cache_read_input_tokens: 0, output_tokens: 0 },
        },
        session_id: 'fixture-201',
      }),
      JSON.stringify({
        type: 'result',
        subtype: 'success',
        is_error: false,
        num_turns: 1,
        session_id: 'fixture-201',
        total_cost_usd: cost,
        usage: {
          input_tokens: billed.input,
          cache_creation_input_tokens: billed.cacheCreation,
          cache_read_input_tokens: billed.cacheRead,
          output_tokens: output,
          cache_creation: { ephemeral_5m_input_tokens: 0, ephemeral_1h_input_tokens: billed.cacheCreation },
        },
      }),
    ].join('\n') + '\n',
  );
  fs.mkdirSync(path.join(INIT_FLEET, 'governor'), { recursive: true });
  fs.writeFileSync(
    path.join(INIT_FLEET, 'governor', 'ticket-history.jsonl'),
    JSON.stringify({ ticket: 201, run: RUN, status: 'resolved', ts: 1_800_000_001 }) + '\n',
  );
}

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

// ── the live-A/B fixtures ────────────────────────────────────────────────────
// These feed bench/run.sh --dry-run and the selection test. They used to carry invented round
// dollars ($24.00 vanilla against $3.70 shiploop, an 84.6% saving nobody had measured or modeled;
// $40.00 against $2.00 in the selection file, 95%). Both read as results.
//
// They are now built from the token MIX the real corpus actually has, and every dollar figure is
// computed from the published rate table rather than chosen. The one thing still chosen is each
// backlog's carry multiplier, because a spread of deltas is what the selection ranking exists to
// sort. The multipliers span 1.3x to 3.4x, which lands the deltas inside the 4% to 77% range the
// replay model produces across real fleets, so no percentage in these files reads as a headline.

// Real corpus mix, 1M-context arm, from `node bench/replay.mjs --arm 1m`.
const CORPUS = {
  shiploop: { input: 6_260_208, output: 20_207_850, cacheRead: 3_362_466_006, cacheCreation: 75_188_684 },
  vanilla: { input: 6_260_208, output: 20_207_850, cacheRead: 11_565_453_790, cacheCreation: 67_063_435 },
};
const CORPUS_TOTAL = Object.values(CORPUS.shiploop).reduce((a, b) => a + b, 0);

// Scale the corpus mix to a target token total. Cache reads absorb the remainder so the parts
// always sum to the total exactly, with no rounding drift.
function mix(base, total) {
  const f = total / CORPUS_TOTAL;
  const input = Math.round(base.input * f);
  const output = Math.round(base.output * f);
  const cacheCreation = Math.round(base.cacheCreation * f);
  return { input, output, cacheRead: total - input - output - cacheCreation, cacheCreation };
}
// Opus list rates. Every fixture cost below is this function's output, never a chosen number.
function priceOpus(t) {
  return (t.input * 5 + t.output * 25 + t.cacheRead * 0.5 + t.cacheCreation * 10) / 1e6;
}
const round2 = (x) => Math.round(x * 100) / 100;

// The four canned streams. A worker session is a real one's order of magnitude (~250k cache read,
// ~3.5k output); the vanilla session is one long session over a whole backlog.
function stream(sessionId, model, total, turnCount) {
  const t = mix(CORPUS.shiploop, total);
  const cost = priceOpus(t);
  const out = [JSON.stringify({ type: 'system', subtype: 'init', session_id: sessionId, model })];
  // Two truncated per-turn snapshots, the shape the real stream emits. Nothing sums them.
  for (let i = 0; i < 2; i++) {
    out.push(
      JSON.stringify({
        type: 'assistant',
        message: {
          id: `${sessionId}-msg-${i}`,
          model,
          usage: {
            input_tokens: Math.round(t.input / 2),
            output_tokens: 3,
            cache_read_input_tokens: Math.round((t.cacheRead / 2) * (i + 0.5)),
            cache_creation_input_tokens: Math.round(t.cacheCreation / 2),
            cache_creation: {
              ephemeral_5m_input_tokens: 0,
              ephemeral_1h_input_tokens: Math.round(t.cacheCreation / 2),
            },
          },
        },
      }),
    );
  }
  out.push(
    JSON.stringify({
      type: 'result',
      subtype: 'success',
      is_error: false,
      num_turns: turnCount,
      session_id: sessionId,
      total_cost_usd: cost,
      usage: {
        input_tokens: t.input,
        output_tokens: t.output,
        cache_read_input_tokens: t.cacheRead,
        cache_creation_input_tokens: t.cacheCreation,
        cache_creation: { ephemeral_5m_input_tokens: 0, ephemeral_1h_input_tokens: t.cacheCreation },
      },
    }),
  );
  return out.join('\n') + '\n';
}

// Sizes come from the real per-session distribution: 522 corpus sessions have a median of
// 3,061,307 tokens ($3.14) and a 25th percentile of 1,859,253 ($1.87). The worker is set at that
// 25th percentile so a six-ticket dry run stays comfortably under the default BENCH_MAX_USD of 60
// while still being a real session's order of magnitude, not a toy.
fs.writeFileSync(path.join(HERE, 'vanilla-session.jsonl'), stream('fixture-vanilla', 'claude-opus-4-8', 12_000_000, 96));
fs.writeFileSync(path.join(HERE, 'shiploop-worker.jsonl'), stream('fixture-worker', 'claude-opus-4-8', 1_900_000, 18));
fs.writeFileSync(path.join(HERE, 'shiploop-driver.jsonl'), stream('fixture-driver', 'claude-opus-4-8', 600_000, 3));
// Killed before a result event: two turns, no result. Recovery of its input side is exact; its
// output is gone for good.
{
  const t = mix(CORPUS.shiploop, 400_000);
  const half = {
    input_tokens: Math.round(t.input / 2),
    output_tokens: 3,
    cache_read_input_tokens: Math.round(t.cacheRead / 2),
    cache_creation_input_tokens: Math.round(t.cacheCreation / 2),
  };
  fs.writeFileSync(
    path.join(HERE, 'partial-no-result.jsonl'),
    [
      JSON.stringify({ type: 'system', subtype: 'init', session_id: 'fixture-partial', model: 'claude-opus-4-8' }),
      JSON.stringify({ type: 'assistant', message: { id: 'fixture-partial-0', model: 'claude-opus-4-8', usage: half } }),
      JSON.stringify({ type: 'assistant', message: { id: 'fixture-partial-1', model: 'claude-opus-4-8', usage: half } }),
    ].join('\n') + '\n',
  );
}

// ── selection-results.jsonl ──────────────────────────────────────────────────
// Five backlogs whose only job is to exercise the ranking, the floor, and the two drop rules.
// shiploopTokens is the corpus mix at a chosen scale; the vanilla arm is that same run with a
// carry multiplier applied to its cache reads, which is the one thing that actually varies between
// real runs (a run that clears more tickets carries more). Every cost is priced, not chosen.
const BACKLOGS = [
  { id: 'bl-a', tickets: 8, shipTokens: 24_000_000, carry: 3.4, cleared: 8, vanillaCleared: true, status: 'resolved' },
  { id: 'bl-b', tickets: 7, shipTokens: 21_000_000, carry: 2.3, cleared: 7, vanillaCleared: true, status: 'resolved' },
  { id: 'bl-c', tickets: 6, shipTokens: 18_000_000, carry: 1.3, cleared: 6, vanillaCleared: true, status: 'resolved' },
  // The delta looks good and the backlog still drops: the vanilla arm cleared 5 of 8.
  { id: 'bl-d', tickets: 8, shipTokens: 20_000_000, carry: 2.8, cleared: 5, vanillaCleared: false, status: 'resolved' },
  { id: 'bl-e', tickets: 6, shipTokens: 18_000_000, carry: 2.0, cleared: 6, vanillaCleared: true, status: 'capped' },
];
const selRows = [];
for (const b of BACKLOGS) {
  const ship = mix(CORPUS.shiploop, b.shipTokens);
  // One long session re-primes once, not once per ticket, so its cache WRITES are lower even as
  // its cache reads climb. 0.8919 is the ratio the real corpus shows (67,063,435 / 75,188,684).
  const van = {
    ...ship,
    cacheRead: Math.round(ship.cacheRead * b.carry),
    cacheCreation: Math.round(ship.cacheCreation * 0.8919),
  };
  const mk = (arm, t, cleared, status, resolved) => {
    const total = t.input + t.output + t.cacheRead + t.cacheCreation;
    const cost = round2(priceOpus(t));
    return {
      kind: 'rollup',
      run: 'selection',
      backlog: b.id,
      task: b.id,
      arm,
      rep: 1,
      model: 'claude-opus-4-8',
      cli_version: 'fixture',
      status,
      resolved,
      provenance: arm === 'vanilla' ? 'modeled' : 'measured',
      turns: 10,
      tokens: { ...t, cacheRead: t.cacheRead, total },
      costUsd: cost,
      usageSource: 'rollup',
      wallMs: 600000,
      verifyExit: 0,
      startedAt: 1780000000,
      sessions: arm === 'vanilla' ? 1 : b.tickets + 1,
      costUsdSessions: arm === 'vanilla' ? 1 : b.tickets + 1,
      ticketsCleared: cleared,
      ticketsTotal: b.tickets,
      costUsdTotal: cost,
      tokensTotal: total,
    };
  };
  if (b.status === 'capped') {
    selRows.push(mk('vanilla', van, b.tickets, 'resolved'));
    // The run hit BENCH_MAX_USD before the shiploop arm was dispatched, so its cost is recorded
    // as zero. A zero must never be readable as a saving, which is what rule 3 exists to enforce.
    const capped = mk('shiploop', { input: 0, output: 0, cacheRead: 0, cacheCreation: 0 }, 0, 'capped', false);
    capped.costUsd = 0;
    capped.costUsdTotal = 0;
    selRows.push(capped);
  } else {
    selRows.push(mk('vanilla', van, b.cleared, b.vanillaCleared ? 'resolved' : 'failed', b.vanillaCleared));
    selRows.push(mk('shiploop', ship, b.tickets, 'resolved', true));
  }
}
fs.writeFileSync(path.join(HERE, 'selection-results.jsonl'), selRows.map((r) => JSON.stringify(r)).join('\n') + '\n');
console.log('wrote the live-A/B stream fixtures and selection-results.jsonl');
for (const b of BACKLOGS) {
  const ship = mix(CORPUS.shiploop, b.shipTokens);
  const van = {
    ...ship,
    cacheRead: Math.round(ship.cacheRead * b.carry),
    cacheCreation: Math.round(ship.cacheCreation * 0.8919),
  };
  const sc = round2(priceOpus(ship));
  const vc = round2(priceOpus(van));
  console.log(`  ${b.id}: shiploop $${sc.toFixed(2)}  vanilla $${vc.toFixed(2)}  cut ${(100 * (vc - sc) / vc).toFixed(2)}%`);
}
