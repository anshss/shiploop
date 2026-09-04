#!/usr/bin/env node
// bench/replay.mjs — the replay benchmark.
//
// Reads real governor transcripts out of one or more fleet workspaces and computes what the same
// backlog would have cost inside ONE accumulating Claude Code session. The shiploop arm is
// measured (billed usage, straight off each session's result event). The vanilla arm is MODELED.
// No vanilla session was ever run, and this tool says so in its own output.
//
// Zero dependencies, read only. It never writes into a fleet workspace and never spawns anything.
//
// Full model, assumptions, and bias directions: bench/METHODOLOGY.md.

import fs from 'node:fs';
import path from 'node:path';

// ── published Anthropic rates, USD per million tokens ────────────────────────
// Cache read is 0.1x input. Cache write is 2x input at the 1-hour TTL, 1.25x at 5 minutes.
// These are list rates, not fitted. The reconciliation ratio in the report is the check.
const RATES = {
  opus: { input: 5, output: 25 },
  sonnet: { input: 2, output: 10 },
  haiku: { input: 1, output: 5 },
};
const CACHE_READ_MULT = 0.1;
const CACHE_WRITE_1H_MULT = 2.0;
const CACHE_WRITE_5M_MULT = 1.25;

const ARMS = {
  '200k': { window: 200_000, label: 'a 200k-context session with compaction' },
  '1m': { window: 1_000_000, label: 'a 1M-context session' },
  uncapped: { window: Infinity, label: 'an uncapped-context session (unphysical)' },
};
const CURVE_POSITIONS = [1, 2, 3, 5, 8];

function tierOf(model) {
  const m = String(model || '').toLowerCase();
  if (m.includes('opus')) return 'opus';
  if (m.includes('sonnet')) return 'sonnet';
  if (m.includes('haiku')) return 'haiku';
  return null;
}

// ── CLI ──────────────────────────────────────────────────────────────────────
function parseArgs(argv) {
  const opts = { arm: 'all', json: false, scope: 'all', fleets: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--arm') opts.arm = argv[++i];
    else if (a === '--json') opts.json = true;
    else if (a === '--scope') opts.scope = argv[++i];
    else if (a === '--fleet') opts.fleets.push(path.resolve(argv[++i]));
    else if (a === '-h' || a === '--help') opts.help = true;
    else return { error: `unknown argument: ${a}` };
  }
  if (opts.arm !== 'all' && !ARMS[opts.arm]) {
    return { error: `unknown arm: ${opts.arm} (expected 200k, 1m, uncapped, or all)` };
  }
  if (opts.scope !== 'all' && opts.scope !== 'resolved') {
    return { error: `unknown scope: ${opts.scope} (expected all or resolved)` };
  }
  return opts;
}

const USAGE = `usage: node bench/replay.mjs [--fleet <path>]... [--arm 200k|1m|uncapped|all]
                            [--scope all|resolved] [--json]

  --fleet   a shiploop workspace to read (repeatable). Defaults to auto-discovery of the
            current workspace and its siblings. Read only, never written to.
  --arm     which counterfactual session to model. Default all.
  --scope   all (every ticket the loop paid for) or resolved (only tickets that
            ticket-history.jsonl marks resolved). Default all. Scope selects what is
            COUNTED, never what happened: a failed ticket keeps contributing carry.
  --json    machine-readable output instead of the report.`;

// ── fleet discovery ──────────────────────────────────────────────────────────
function isFleet(dir) {
  try {
    if (fs.existsSync(path.join(dir, 'logs', 'govern'))) return true;
    if (fs.existsSync(path.join(dir, 'governor', 'ticket-history.jsonl'))) return true;
  } catch {
    return false;
  }
  return false;
}

function childFleets(dir) {
  let entries = [];
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch {
    return [];
  }
  return entries
    .filter((e) => e.isDirectory() && !e.name.startsWith('.'))
    .map((e) => path.join(dir, e.name))
    .filter(isFleet);
}

// Walk up from the working directory. The first level that either IS a fleet or CONTAINS fleets
// wins, and every fleet at that level is scanned. That is what makes "replay every fleet on this
// machine" a single default invocation from inside any one of them, or from a hub checkout that
// sits beside them.
function discoverFleets(startDir) {
  let cur = path.resolve(startDir);
  for (let i = 0; i < 8; i++) {
    if (isFleet(cur)) {
      return [...new Set([cur, ...childFleets(path.dirname(cur))])].sort();
    }
    const kids = childFleets(cur);
    if (kids.length) return kids.sort();
    const up = path.dirname(cur);
    if (up === cur) break;
    cur = up;
  }
  return [];
}

// ── transcript parsing ───────────────────────────────────────────────────────
function walkJsonl(dir, out) {
  let entries;
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch {
    return out;
  }
  for (const e of entries) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walkJsonl(p, out);
    else if (e.isFile() && e.name.endsWith('.jsonl') && e.name !== 'state.jsonl') out.push(p);
  }
  return out;
}

// A transcript file holds one or more sessions. A session ends at its result event; a trailing
// segment with no result event is an excluded session (killed, crashed, or still running).
//
// The per-assistant-event usage.output_tokens is a truncated running snapshot that does NOT
// accumulate across content blocks: summing it undercounts real output by more than an order of
// magnitude. Billed usage therefore comes ONLY from the result event. The assistant events are
// used for one thing they are exact at: the per-turn CONTEXT (input + cache_read + cache_creation),
// which is known before generation and reproduces the result event's totals to the token.
function parseTranscript(file) {
  let raw;
  try {
    raw = fs.readFileSync(file, 'utf8');
  } catch {
    return { sessions: [], excluded: 0 };
  }
  const sessions = [];
  let excluded = 0;
  let turns = [];
  const seen = new Set();

  const flushExcluded = () => {
    if (turns.length) excluded++;
    turns = [];
    seen.clear();
  };

  for (const line of raw.split('\n')) {
    if (!line || line[0] !== '{') continue;
    let ev;
    try {
      ev = JSON.parse(line);
    } catch {
      continue;
    }
    if (ev.type === 'assistant' && ev.message) {
      const id = ev.message.id;
      const u = ev.message.usage || {};
      const ctx =
        (u.input_tokens || 0) + (u.cache_read_input_tokens || 0) + (u.cache_creation_input_tokens || 0);
      if (id && seen.has(id)) continue; // same turn, later content block, identical context snapshot
      if (id) seen.add(id);
      // The CLI emits synthetic assistant messages (model "<synthetic>") for interrupts and
      // API-error notices. They carry no usage and are not turns anyone was billed for.
      if (ctx === 0) continue;
      turns.push({
        ctx,
        model: ev.message.model || null,
        cacheCreation: u.cache_creation_input_tokens || 0,
      });
    } else if (ev.type === 'result') {
      if (!ev.usage || typeof ev.usage !== 'object') {
        // A result event that carries no usage object bills nothing we can read. Treated the
        // same as a session that never emitted one: excluded, and counted as excluded.
        excluded++;
        turns = [];
        seen.clear();
        continue;
      }
      const u = ev.usage;
      const cc = u.cache_creation || {};
      const write1h = cc.ephemeral_1h_input_tokens || 0;
      const write5m = cc.ephemeral_5m_input_tokens || 0;
      sessions.push({
        file,
        sessionId: ev.session_id || null,
        reportedCostUsd: typeof ev.total_cost_usd === 'number' ? ev.total_cost_usd : null,
        numTurns: ev.num_turns || turns.length,
        billed: {
          input: u.input_tokens || 0,
          output: u.output_tokens || 0,
          cacheRead: u.cache_read_input_tokens || 0,
          cacheCreation: u.cache_creation_input_tokens || 0,
        },
        write1h,
        write5m,
        modelUsage: ev.modelUsage || null,
        turns,
      });
      turns = [];
      seen.clear();
    }
  }
  flushExcluded();
  return { sessions, excluded };
}

// ── pricing ──────────────────────────────────────────────────────────────────
// Cost is recomputed from published rates for BOTH arms, so the comparison never mixes a
// reported dollar figure with a modeled one. The reported total_cost_usd is used only as the
// reconciliation check.
function sessionCost(sess, unknownModels) {
  const totalWrite = sess.write1h + sess.write5m;
  const frac1h = totalWrite > 0 ? sess.write1h / totalWrite : 1;
  const writeMult = frac1h * CACHE_WRITE_1H_MULT + (1 - frac1h) * CACHE_WRITE_5M_MULT;

  const parts = [];
  if (sess.modelUsage && Object.keys(sess.modelUsage).length) {
    for (const [model, mu] of Object.entries(sess.modelUsage)) {
      parts.push({
        model,
        input: mu.inputTokens || 0,
        output: mu.outputTokens || 0,
        cacheRead: mu.cacheReadInputTokens || 0,
        cacheCreation: mu.cacheCreationInputTokens || 0,
      });
    }
  } else {
    parts.push({ model: fallbackModel(sess), ...sess.billed });
  }

  let usd = 0;
  let outputUsd = 0;
  for (const p of parts) {
    const tier = tierOf(p.model);
    if (!tier) unknownModels.add(p.model);
    const r = RATES[tier || 'opus'];
    outputUsd += (p.output * r.output) / 1e6;
    usd +=
      (p.input * r.input +
        p.output * r.output +
        p.cacheRead * r.input * CACHE_READ_MULT +
        p.cacheCreation * r.input * writeMult) /
      1e6;
  }
  return { usd, outputUsd };
}

// Older CLI versions omit modelUsage. Fall back to the first assistant turn whose model name is
// a recognizable tier, never to a synthetic or absent one.
function fallbackModel(sess) {
  const t = sess.turns.find((x) => tierOf(x.model));
  return t ? t.model : 'unknown';
}

function dominantTier(sess) {
  if (sess.modelUsage) {
    let best = null;
    let bestTok = -1;
    for (const [model, mu] of Object.entries(sess.modelUsage)) {
      const tok = (mu.inputTokens || 0) + (mu.cacheReadInputTokens || 0) + (mu.outputTokens || 0);
      if (tok > bestTok) {
        bestTok = tok;
        best = model;
      }
    }
    const t = tierOf(best);
    if (t) return t;
  }
  return tierOf(fallbackModel(sess)) || 'opus';
}

// ── fleet scan ───────────────────────────────────────────────────────────────
// Last-writer-wins status and completion timestamp per ticket. The timestamp is the primary
// ordering key: a git checkout does not preserve file mtimes, so mtime alone would let the modeled
// ticket order change between machines.
function ticketStatuses(fleetDir) {
  const f = path.join(fleetDir, 'governor', 'ticket-history.jsonl');
  const byKey = new Map();
  let raw;
  try {
    raw = fs.readFileSync(f, 'utf8');
  } catch {
    return byKey;
  }
  for (const line of raw.split('\n')) {
    if (!line || line[0] !== '{') continue;
    let ev;
    try {
      ev = JSON.parse(line);
    } catch {
      continue;
    }
    if (ev.ticket == null || !ev.status) continue;
    // Later rows win: a ticket that was parked and later resolved counts as resolved.
    const rec = { status: ev.status, ts: typeof ev.ts === 'number' ? ev.ts : null };
    byKey.set(`${ev.run || 'adhoc'}#${ev.ticket}`, rec);
    byKey.set(`*#${ev.ticket}`, rec);
  }
  return byKey;
}

function locate(file, fleetDir) {
  const rel = path.relative(path.join(fleetDir, 'logs', 'govern'), file);
  const parts = rel.split(path.sep);
  let run = 'adhoc';
  let ticket = null;
  for (const p of parts) {
    if (/^run-/.test(p)) run = p;
    else if (/^ticket-/.test(p)) ticket = p.replace(/^ticket-/, '');
  }
  if (!ticket) ticket = path.basename(path.dirname(file));
  return { run, ticket };
}

function scanFleet(fleetDir) {
  const logs = path.join(fleetDir, 'logs', 'govern');
  const files = walkJsonl(logs, []);
  const statuses = ticketStatuses(fleetDir);
  const tickets = new Map(); // key "run#ticket" -> ticket record
  let excluded = 0;

  for (const f of files) {
    const { sessions, excluded: ex } = parseTranscript(f);
    excluded += ex;
    if (!sessions.length) continue;
    const { run, ticket } = locate(f, fleetDir);
    const key = `${run}#${ticket}`;
    let rec = tickets.get(key);
    if (!rec) {
      const h = statuses.get(key) || statuses.get(`*#${ticket}`) || null;
      rec = {
        fleet: fleetDir,
        run,
        ticket,
        status: h ? h.status : 'unknown',
        historyTs: h && h.ts != null ? h.ts : null,
        sessions: [],
        mtime: 0,
      };
      tickets.set(key, rec);
    }
    let st = 0;
    try {
      st = fs.statSync(f).mtimeMs;
    } catch {
      st = 0;
    }
    rec.mtime = Math.max(rec.mtime, st);
    rec.sessions.push(...sessions);
  }
  return { tickets: [...tickets.values()], excluded, files: files.length };
}

// ── the model ────────────────────────────────────────────────────────────────
// Per ticket k of a run, the vanilla session is the same work plus one thing: every turn of
// ticket k additionally re-reads the context carried out of tickets 1..k-1, at the cache-read
// rate. Carry is measured, never reconstructed: a session's residue is the growth of its own
// observed per-turn context from first turn to last.
//
// Output is identical in both arms. It is the same work and the same code written, so it is a
// shared fixed cost and it appears in both arms in full. That is also why the reduction has a
// hard ceiling well under 100%.
function replayRun(ticketsInOrder, window, unknownModels) {
  let carry = 0;
  const rows = [];
  for (let k = 0; k < ticketsInOrder.length; k++) {
    const t = ticketsInOrder[k];
    let shipTokens = 0;
    const shipParts = { input: 0, output: 0, cacheRead: 0, cacheCreation: 0 };
    let shipCost = 0;
    let outputCost = 0;
    let overheadTokens = 0;
    let overheadCost = 0;
    let creditTokens = 0;
    let creditCost = 0;
    let ownCarry = 0;
    let reportedCost = 0;
    let reconcilable = 0;

    for (let s = 0; s < t.sessions.length; s++) {
      const sess = t.sessions[s];
      const b = sess.billed;
      shipTokens += b.input + b.output + b.cacheRead + b.cacheCreation;
      shipParts.input += b.input;
      shipParts.output += b.output;
      shipParts.cacheRead += b.cacheRead;
      shipParts.cacheCreation += b.cacheCreation;
      const c = sessionCost(sess, unknownModels);
      shipCost += c.usd;
      outputCost += c.outputUsd;
      if (sess.reportedCostUsd != null) {
        reportedCost += sess.reportedCostUsd;
        reconcilable++;
      }

      const tier = dominantTier(sess);
      const readRate = (RATES[tier].input * CACHE_READ_MULT) / 1e6;
      const writeRate = (RATES[tier].input * CACHE_WRITE_1H_MULT) / 1e6;

      // What one accumulating session pays that N fresh ones do not: the carry, re-read
      // every turn, bounded by the context window.
      for (const turn of sess.turns) {
        const headroom = window === Infinity ? Infinity : Math.max(0, window - turn.ctx);
        const eff = Math.min(carry, headroom);
        overheadTokens += eff;
        overheadCost += eff * readRate;
      }

      // What N fresh sessions pay that one accumulating session does not: re-priming the base
      // context (system prompt, CLAUDE.md, ticket text) at the start of every session after the
      // first. Credited to vanilla at the cache-write rate.
      if (!(k === 0 && s === 0) && sess.turns.length) {
        const prime = sess.turns[0].cacheCreation;
        creditTokens += prime;
        creditCost += prime * writeRate;
      }

      if (sess.turns.length) {
        const first = sess.turns[0].ctx;
        const last = sess.turns[sess.turns.length - 1].ctx;
        ownCarry += Math.max(0, last - first);
      }
    }

    const vanTokens = Math.max(0, shipTokens + overheadTokens - creditTokens);
    const vanCost = Math.max(0, shipCost + overheadCost - creditCost);
    rows.push({
      position: k + 1,
      fleet: t.fleet,
      run: t.run,
      ticket: t.ticket,
      status: t.status,
      counted: t.counted !== false,
      sessions: t.sessions.length,
      shipTokens,
      shipParts,
      outputCost,
      overheadTokens,
      creditTokens,
      shipCost,
      vanTokens,
      vanCost,
      reportedCost,
      reconcilable,
      carryIn: carry,
    });
    carry += ownCarry;
  }
  return rows;
}

function median(xs) {
  if (!xs.length) return null;
  const s = [...xs].sort((a, b) => a - b);
  const m = s.length >> 1;
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
}

function pct(a, b) {
  if (!b) return null;
  return ((b - a) / b) * 100;
}

// ── main ─────────────────────────────────────────────────────────────────────
function main() {
  const opts = parseArgs(process.argv.slice(2));
  if (opts.error) {
    console.error(opts.error);
    console.error(USAGE);
    process.exit(2);
  }
  if (opts.help) {
    console.log(USAGE);
    process.exit(0);
  }

  const fleets = opts.fleets.length ? opts.fleets : discoverFleets(process.cwd());
  const armNames = opts.arm === 'all' ? Object.keys(ARMS) : [opts.arm];

  const unknownModels = new Set();
  const allTickets = [];
  let excludedSessions = 0;
  const fleetNotes = [];

  for (const fleet of fleets) {
    const { tickets, excluded, files } = scanFleet(fleet);
    excludedSessions += excluded;
    allTickets.push(...tickets);
    fleetNotes.push({ fleet, tickets: tickets.length, transcripts: files });
  }

  // Scope selects which tickets are COUNTED, never which ones happened. A ticket the loop failed
  // still consumed the loop's tokens and still would have grown a single session's context, so it
  // keeps contributing carry to the tickets after it under either scope. Dropping it from the run
  // outright would shorten the modeled session and mechanically flatter whichever arm.
  const kept = allTickets.filter((t) => t.sessions.length > 0);
  for (const t of kept) t.counted = opts.scope === 'all' ? true : t.status === 'resolved';

  // Group into runs and order tickets within a run by completion time. That ordering is what a
  // single session would have worked them in.
  const runs = new Map();
  for (const t of kept) {
    const key = `${t.fleet}#${t.run}`;
    if (!runs.has(key)) runs.set(key, []);
    runs.get(key).push(t);
  }
  const orderKey = (t) => (t.historyTs != null ? t.historyTs * 1000 : t.mtime);
  for (const arr of runs.values()) {
    arr.sort((a, b) => orderKey(a) - orderKey(b) || String(a.ticket).localeCompare(String(b.ticket)));
  }

  const armResults = {};
  for (const arm of armNames) {
    const window = ARMS[arm].window;
    const all = [];
    for (const arr of runs.values()) all.push(...replayRun(arr, window, unknownModels));
    const rows = all.filter((r) => r.counted);

    const shipTokens = rows.reduce((s, r) => s + r.shipTokens, 0);
    const vanTokens = rows.reduce((s, r) => s + r.vanTokens, 0);
    const shipCost = rows.reduce((s, r) => s + r.shipCost, 0);
    const outputCost = rows.reduce((s, r) => s + r.outputCost, 0);
    const part = (k) => rows.reduce((s, r) => s + r.shipParts[k], 0);
    const shipBreakdown = {
      input: part('input'),
      output: part('output'),
      cacheRead: part('cacheRead'),
      cacheCreation: part('cacheCreation'),
    };
    // The vanilla arm is the same work with two edits: the carry is re-read every turn (cache
    // read), and the per-session re-prime that only fresh sessions pay is refunded (cache write).
    const vanBreakdown = {
      input: shipBreakdown.input,
      output: shipBreakdown.output,
      cacheRead: shipBreakdown.cacheRead + rows.reduce((s, r) => s + r.overheadTokens, 0),
      cacheCreation: shipBreakdown.cacheCreation - rows.reduce((s, r) => s + r.creditTokens, 0),
    };
    const vanCost = rows.reduce((s, r) => s + r.vanCost, 0);

    const curve = {};
    for (const p of CURVE_POSITIONS) {
      const at = rows.filter((r) => r.position === p && r.vanTokens > 0).map((r) => pct(r.shipTokens, r.vanTokens));
      curve[p] = { n: at.length, medianTokenReductionPct: median(at) };
    }

    armResults[arm] = {
      arm,
      contextWindow: window === Infinity ? null : window,
      label: ARMS[arm].label,
      runs: new Set(rows.map((r) => `${r.fleet}#${r.run}`)).size,
      tickets: rows.length,
      ticketsInModeledRuns: all.length,
      // The single most explanatory number in the report. The saving is carry, carry accumulates
      // across a run, so a fleet that dispatches one ticket per run saves nothing by this model
      // no matter how good the harness is.
      medianTicketsPerRun: median(
        [...new Set(all.map((r) => `${r.fleet}#${r.run}`))].map(
          (k) => all.filter((r) => `${r.fleet}#${r.run}` === k).length,
        ),
      ),
      shiploopTokens: shipTokens,
      shiploopBreakdown: shipBreakdown,
      vanillaTokens: vanTokens,
      vanillaBreakdown: vanBreakdown,
      shiploopCostUsd: shipCost,
      vanillaCostUsd: vanCost,
      tokenReductionPct: pct(shipTokens, vanTokens),
      costReductionPct: pct(shipCost, vanCost),
      // The ceiling. Output is the same in both arms and no architecture removes it: the work
      // still has to be written. An arm that spent NOTHING but output would land here, so any
      // reduction above this line is arithmetically impossible, not merely unachieved.
      sharedOutputCostUsd: outputCost,
      ceilingTokenReductionPct: pct(shipBreakdown.output, vanTokens),
      ceilingCostReductionPct: pct(outputCost, vanCost),
      positionCurve: curve,
    };
  }

  // Reconciliation: computed cost over reported cost, per session, median. Uses the 1m arm's
  // rows because the shiploop side is identical across arms.
  const anyArm = armResults[armNames[0]];
  const ratios = [];
  for (const arr of runs.values()) {
    for (const t of arr) {
      for (const sess of t.sessions) {
        if (sess.reportedCostUsd == null || sess.reportedCostUsd <= 0) continue;
        ratios.push(sessionCost(sess, unknownModels).usd / sess.reportedCostUsd);
      }
    }
  }
  const recon = {
    n: ratios.length,
    medianComputedOverReported: median(ratios),
    within2pct: ratios.length ? ratios.filter((r) => Math.abs(r - 1) <= 0.02).length / ratios.length : null,
  };

  const out = {
    kind: 'replay',
    provenance:
      'MODELED COUNTERFACTUAL. The shiploop arm is measured billed usage from result events. ' +
      'The vanilla arm is a model of one accumulating session over the same tickets. No vanilla session was run.',
    scope: opts.scope,
    fleets: fleetNotes,
    sessionsExcludedNoResultEvent: excludedSessions,
    unknownModels: [...unknownModels],
    reconciliation: recon,
    arms: armResults,
  };

  if (opts.json) {
    console.log(JSON.stringify(out, null, 2));
    process.exit(anyArm && anyArm.tickets ? 0 : 1);
  }

  render(out);
  process.exit(anyArm && anyArm.tickets ? 0 : 1);
}

function fmtPct(x) {
  return x == null ? 'n/a' : `${x.toFixed(1)}%`;
}
function fmtTok(x) {
  const m = x / 1e6;
  return `${m.toFixed(m < 100 ? 2 : 1)}M`;
}
function fmtUsd(x) {
  return `$${x.toFixed(2)}`;
}

function render(out) {
  const L = [];
  L.push('shiploop bench: replay');
  L.push('');
  L.push(`  MODELED COUNTERFACTUAL: shiploop arm measured from result events, vanilla arm modeled as`);
  const names = Object.keys(out.arms);
  L.push(`  ${names.map((n) => ARMS[n].label).join(' / ')}. No vanilla session was ever run.`);
  L.push('');
  L.push(`  scope: ${out.scope}   fleets: ${out.fleets.length}`);
  for (const f of out.fleets) {
    L.push(`    ${f.fleet}  (${f.transcripts} transcripts, ${f.tickets} tickets)`);
  }
  L.push('');

  const totalTickets = names.length ? out.arms[names[0]].tickets : 0;
  if (!totalTickets) {
    L.push('  No sessions with a result event were found in the fleets given.');
    L.push('  Nothing to replay. Pass --fleet <path> to a workspace with logs/govern transcripts.');
    console.log(L.join('\n'));
    return;
  }

  for (const name of names) {
    const a = out.arms[name];
    L.push(`  arm ${name}  (vs ${a.label})`);
    L.push(`    tokens    shiploop ${fmtTok(a.shiploopTokens)}  vanilla ${fmtTok(a.vanillaTokens)}   reduction ${fmtPct(a.tokenReductionPct)}`);
    L.push(`    cost      shiploop ${fmtUsd(a.shiploopCostUsd)}  vanilla ${fmtUsd(a.vanillaCostUsd)}   reduction ${fmtPct(a.costReductionPct)}`);
    L.push(`    corpus    ${a.runs} runs, ${a.tickets} tickets, median run clears ${a.medianTicketsPerRun} ${a.medianTicketsPerRun === 1 ? 'ticket' : 'tickets'}, ${out.sessionsExcludedNoResultEvent} sessions excluded (no result event)`);
    const curve = CURVE_POSITIONS.map((p) => {
      const c = a.positionCurve[p];
      return `#${p} ${c.n ? fmtPct(c.medianTokenReductionPct) : 'n/a'}`;
    }).join('  ');
    L.push(`    by ticket position (median token reduction): ${curve}`);
    L.push(`    ceiling    ${fmtPct(a.ceilingTokenReductionPct)} tokens / ${fmtPct(a.ceilingCostReductionPct)} cost, the most any architecture could save here`);
    L.push('');
  }

  L.push(`  rates reconciliation: median computed/reported = ${out.reconciliation.medianComputedOverReported == null ? 'n/a' : out.reconciliation.medianComputedOverReported.toFixed(3)} over ${out.reconciliation.n} sessions`);
  if (out.reconciliation.within2pct != null) {
    L.push(`                        ${(out.reconciliation.within2pct * 100).toFixed(1)}% of sessions within 2% of reported`);
  }
  if (out.unknownModels.length) {
    L.push(`  models priced as opus because their tier is unrecognized: ${out.unknownModels.join(', ')}`);
  }
  L.push('');
  L.push('  Ticket 1 saves exactly 0%: there is nothing carried yet. The saving is entirely the');
  L.push('  context that a single session accumulates and a fresh worker never loads.');
  L.push('  Method, assumptions, and which arm each one flatters: bench/METHODOLOGY.md');

  console.log(L.join('\n'));
}

main();
