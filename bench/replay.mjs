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
import crypto from 'node:crypto';

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
    else if (a === '--since') opts.since = argv[++i];
    else if (a === '--rows') opts.rows = true;
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
                            [--scope all|resolved] [--since YYYYMMDD[-HHMMSS]] [--json]

  --fleet   a shiploop workspace to read (repeatable). Defaults to auto-discovery of the
            current workspace and its siblings. Read only, never written to.
  --arm     which counterfactual session to model. Default all.
  --scope   all (every ticket the loop paid for) or resolved (only tickets that
            ticket-history.jsonl marks resolved). Default all. Scope selects what is
            COUNTED, never what happened: a failed ticket keeps contributing carry.
  --since   keep only runs whose run-dir timestamp (run-YYYYMMDD-HHMMSS-<pid>, local time) is
            >= this value. A transcript carries no shiploop package version, so this is the
            disclosable proxy for "sessions on version X or later": pass X's release commit
            timestamp. Prints the resulting date range and CLI/model versions next to the number.
  --json    machine-readable output instead of the report.
  --rows    print one anonymized JSONL row per (run, ticket position) instead of the aggregate
            report — the recomputable evidence behind a published percentage. fleet/run/ticket
            identifiers are replaced with an opaque hash; run id, position (depth), sessions,
            measured tokens/cost, and modeled tokens/cost survive. Combine with --arm to pick
            which counterfactual's rows to emit (default: every arm, one row set per arm).`;

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
  let initModel = null;
  let initVersion = null;
  const seen = new Set();

  // A session killed before it emitted a result event still has an exactly recoverable input side:
  // the deduplicated per-turn context sums to the result event's own input, cache-read and
  // cache-write totals to the token. Its OUTPUT is not recoverable at any accuracy, so a recovered
  // session is built with output 0 and flagged `partial`. Partials are EXCLUDED from the measured
  // arm by default; the report prints what including them would do, because dropping our own spend
  // is the one exclusion that flatters us.
  const recover = () => {
    if (!turns.length) return;
    excluded++;
    const billed = turns.reduce(
      (a, t) => ({
        input: a.input + t.input,
        cacheRead: a.cacheRead + t.cacheRead,
        cacheCreation: a.cacheCreation + t.cacheCreation,
      }),
      { input: 0, cacheRead: 0, cacheCreation: 0 },
    );
    if (billed.input + billed.cacheRead + billed.cacheCreation > 0) {
      sessions.push({
        file,
        sessionId: null,
        reportedCostUsd: null,
        numTurns: turns.length,
        partial: true,
        billed: { ...billed, output: 0 },
        write1h: billed.cacheCreation,
        write5m: 0,
        modelUsage: null,
        initModel,
        initVersion,
        turns,
      });
    }
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
    if (ev.type === 'system' && ev.subtype === 'init' && ev.model) {
      // The init event names the session's model even when the result event omits modelUsage and
      // every assistant message is a synthetic notice. It is the authoritative fallback. It also
      // carries the Claude Code CLI version the session actually ran under (claude_code_version) —
      // no event carries the shiploop PACKAGE version, so that is what --since's run-dir-timestamp
      // filter is for instead.
      initModel = ev.model;
      if (ev.claude_code_version) initVersion = ev.claude_code_version;
    } else if (ev.type === 'assistant' && ev.message) {
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
        input: u.input_tokens || 0,
        cacheRead: u.cache_read_input_tokens || 0,
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
        initModel,
        initVersion,
        partial: false,
        turns,
      });
      turns = [];
      seen.clear();
    }
  }
  recover();
  return { sessions, excluded };
}

// ── pricing ──────────────────────────────────────────────────────────────────
// Cost is recomputed from published rates for BOTH arms, so the comparison never mixes a
// reported dollar figure with a modeled one. The reported total_cost_usd is used only as the
// reconciliation check.
function sessionCost(sess, fb) {
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
    if (!tier && fb) fb.models.add(p.model);
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

// Older CLI versions omit modelUsage, and an aborted session's only assistant messages can all be
// synthetic notices carrying no model. Resolve in order: the first assistant turn naming a real
// tier, then the session's `system`/`init` event, which names the model the session was spawned
// with. Only a transcript with neither is unresolvable.
function fallbackModel(sess) {
  const t = sess.turns.find((x) => tierOf(x.model));
  if (t) return t.model;
  if (tierOf(sess.initModel)) return sess.initModel;
  return 'unresolved';
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

// run-YYYYMMDD-HHMMSS-<pid> -> "YYYYMMDD-HHMMSS" (lexically sortable, local time — see run-loop.sh's
// `date +%Y%m%d-%H%M%S`, no `-u`). null for a run name that doesn't match (e.g. "adhoc").
function runDateKey(run) {
  const m = /^run-(\d{8}-\d{6})/.exec(run || '');
  return m ? m[1] : null;
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
function replayRun(allTicketsInOrder, window, includePartial) {
  const ticketsInOrder = includePartial
    ? allTicketsInOrder
    : allTicketsInOrder.filter((t) => t.sessions.some((x) => !x.partial));
  let carry = 0;
  const rows = [];
  for (let k = 0; k < ticketsInOrder.length; k++) {
    const t = ticketsInOrder[k];
    const sessions = includePartial ? t.sessions : t.sessions.filter((x) => !x.partial);
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

    for (let s = 0; s < sessions.length; s++) {
      const sess = sessions[s];
      const b = sess.billed;
      shipTokens += b.input + b.output + b.cacheRead + b.cacheCreation;
      shipParts.input += b.input;
      shipParts.output += b.output;
      shipParts.cacheRead += b.cacheRead;
      shipParts.cacheCreation += b.cacheCreation;
      const c = sessionCost(sess, null);
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
      sessions: sessions.length,
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

  const allTickets = [];
  let excludedSessions = 0;
  const fleetNotes = [];

  for (const fleet of fleets) {
    const { tickets, excluded, files } = scanFleet(fleet);
    excludedSessions += excluded;
    allTickets.push(...tickets);
    fleetNotes.push({ fleet, tickets: tickets.length, transcripts: files });
  }

  // --since: the disclosable date-cutoff proxy for "sessions on shiploop version X or later" (no
  // transcript carries the shiploop package version — see the USAGE text). Runs whose run-dir
  // name doesn't parse as a timestamp (e.g. "adhoc") are dropped by a --since filter: an
  // unparseable run can never be shown to be on-or-after the cutoff.
  const runsSeenTotal = new Set(allTickets.map((t) => `${t.fleet}#${t.run}`)).size;
  const keptByDate = opts.since
    ? allTickets.filter((t) => {
        const k = runDateKey(t.run);
        return k != null && k >= opts.since;
      })
    : allTickets;
  const runsSeenKept = new Set(keptByDate.map((t) => `${t.fleet}#${t.run}`)).size;

  // Corpus metadata for the headline: CLI version(s) and model(s) actually seen, and the date span
  // of the run dirs that made the cut — printed next to the number, not left for stdout to bury.
  const cliVersions = new Set();
  const models = new Set();
  let minDate = null;
  let maxDate = null;
  for (const t of keptByDate) {
    const dk = runDateKey(t.run);
    if (dk) {
      if (minDate == null || dk < minDate) minDate = dk;
      if (maxDate == null || dk > maxDate) maxDate = dk;
    }
    for (const sess of t.sessions) {
      if (sess.initVersion) cliVersions.add(sess.initVersion);
      const m = (sess.modelUsage && Object.keys(sess.modelUsage)) || [fallbackModel(sess)];
      for (const mm of m) if (mm && mm !== 'unresolved') models.add(mm);
    }
  }
  const meta = {
    since: opts.since || null,
    runsSeenTotal,
    runsSeenKept,
    dateRange: minDate ? { from: minDate, to: maxDate } : null,
    cliVersions: [...cliVersions].sort(),
    models: [...models].sort(),
  };

  const allTicketsAfterSince = keptByDate;

  // Scope selects which tickets are COUNTED, never which ones happened. A ticket the loop failed
  // still consumed the loop's tokens and still would have grown a single session's context, so it
  // keeps contributing carry to the tickets after it under either scope. Dropping it from the run
  // outright would shorten the modeled session and mechanically flatter whichever arm.
  const kept = allTicketsAfterSince.filter((t) => t.sessions.length > 0);
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

  // --rows evidence, keyed by arm. Populated once per real (non-sensitivity) computeArm call.
  const rowsByArm = {};

  const computeArm = (arm, includePartial) => {
    const window = ARMS[arm].window;
    const all = [];
    for (const arr of runs.values()) all.push(...replayRun(arr, window, includePartial));
    const rows = all.filter((r) => r.counted);
    if (opts.rows && !includePartial) rowsByArm[arm] = all;

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

    return {
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
  };

  const armResults = {};
  for (const arm of armNames) {
    armResults[arm] = computeArm(arm, false);
    // Sensitivity, always computed and always printed. The measured arm drops every session that
    // never emitted a result event, and those are OUR spend, so dropping them is the exclusion
    // that flatters us. This is what the same arm reports when their exactly recoverable input
    // side is added back (output stays 0, because output is not recoverable).
    const withPartials = computeArm(arm, true);
    armResults[arm].sensitivityWithRecoveredPartials = {
      shiploopTokens: withPartials.shiploopTokens,
      vanillaTokens: withPartials.vanillaTokens,
      shiploopCostUsd: withPartials.shiploopCostUsd,
      vanillaCostUsd: withPartials.vanillaCostUsd,
      tokenReductionPct: withPartials.tokenReductionPct,
      costReductionPct: withPartials.costReductionPct,
      tokenReductionDeltaPts:
        withPartials.tokenReductionPct == null || armResults[arm].tokenReductionPct == null
          ? null
          : withPartials.tokenReductionPct - armResults[arm].tokenReductionPct,
      costReductionDeltaPts:
        withPartials.costReductionPct == null || armResults[arm].costReductionPct == null
          ? null
          : withPartials.costReductionPct - armResults[arm].costReductionPct,
    };
  }

  if (opts.rows) {
    // Anonymized, recomputable evidence: one line per (run, ticket position), fleet/run/ticket
    // replaced with a hash so a workspace name or internal ticket number never leaves the machine.
    // Same numbers the aggregate above was built from — sum shipTokens/shipCost per run and you
    // reproduce the corresponding arm's shiploopTokens/shiploopCostUsd exactly.
    for (const arm of armNames) {
      for (const r of rowsByArm[arm] || []) {
        const runHash = crypto.createHash('sha256').update(`${r.fleet}#${r.run}`).digest('hex').slice(0, 16);
        console.log(
          JSON.stringify({
            arm,
            run: runHash,
            position: r.position,
            counted: r.counted,
            sessions: r.sessions,
            shipTokens: r.shipTokens,
            shipCostUsd: r.shipCost,
            vanillaTokens: r.vanTokens,
            vanillaCostUsd: r.vanCost,
          }),
        );
      }
    }
    process.exit(0);
  }

  // Tier resolution audit, computed once over the session list rather than inside the arm loop.
  // A session is resolvable when modelUsage names a known tier, or any assistant turn does, or the
  // init event does. Anything left is priced at the Opus rate, which inflates BOTH arms.
  const tierFallback = { sessions: 0, tokens: 0, measuredSessions: 0, measuredTokens: 0 };
  for (const arr of runs.values()) {
    for (const t of arr) {
      for (const sess of t.sessions) {
        const named =
          (sess.modelUsage && Object.keys(sess.modelUsage).some(tierOf)) || tierOf(fallbackModel(sess));
        if (named) continue;
        const b = sess.billed;
        const tk = b.input + b.output + b.cacheRead + b.cacheCreation;
        tierFallback.sessions++;
        tierFallback.tokens += tk;
        if (!sess.partial) {
          tierFallback.measuredSessions++;
          tierFallback.measuredTokens += tk;
        }
      }
    }
  }

  const partialSessions = [];
  for (const arr of runs.values()) {
    for (const t of arr) for (const sess of t.sessions) if (sess.partial) partialSessions.push(sess);
  }
  const partialRecovery = {
    sessions: partialSessions.length,
    recoverableInputSideTokens: partialSessions.reduce(
      (a, x) => a + x.billed.input + x.billed.cacheRead + x.billed.cacheCreation,
      0,
    ),
    outputRecoverable: false,
  };

  // Reconciliation: computed cost over reported cost, per session, median. Uses the 1m arm's
  // rows because the shiploop side is identical across arms.
  const anyArm = armResults[armNames[0]];
  const ratios = [];
  for (const arr of runs.values()) {
    for (const t of arr) {
      for (const sess of t.sessions) {
        if (sess.reportedCostUsd == null || sess.reportedCostUsd <= 0) continue;
        ratios.push(sessionCost(sess, null).usd / sess.reportedCostUsd);
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
    meta,
    fleets: fleetNotes,
    sessionsExcludedNoResultEvent: excludedSessions,
    partialRecovery,
    tierFallback,
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
  // Version/model/date next to the headline, not buried in stdout (ticket #104): a transcript
  // carries no shiploop package version, so `since` (if given) + the CLI/model actually seen +
  // the covered date range are the disclosable stand-in, printed before a single number.
  const m = out.meta;
  L.push(
    `  corpus: CLI ${m.cliVersions.length ? m.cliVersions.join(', ') : 'unknown'}` +
      `   model ${m.models.length ? m.models.join(', ') : 'unknown'}` +
      `   dates ${m.dateRange ? `${m.dateRange.from} .. ${m.dateRange.to}` : 'n/a'}` +
      `   runs ${m.runsSeenKept}/${m.runsSeenTotal}${m.since ? ` (--since ${m.since})` : ''}`,
  );
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
    L.push(`    corpus    ${a.runs} runs, ${a.tickets} tickets, median run clears ${a.medianTicketsPerRun} ${a.medianTicketsPerRun === 1 ? 'ticket' : 'tickets'}, ${out.sessionsExcludedNoResultEvent} sessions excluded, ${out.partialRecovery.sessions} of them recoverable`);
    const curve = CURVE_POSITIONS.map((p) => {
      const c = a.positionCurve[p];
      return `#${p} ${c.n ? fmtPct(c.medianTokenReductionPct) : 'n/a'}`;
    }).join('  ');
    L.push(`    by ticket position (median token reduction): ${curve}`);
    L.push(`    ceiling    ${fmtPct(a.ceilingTokenReductionPct)} tokens / ${fmtPct(a.ceilingCostReductionPct)} cost, the most any architecture could save here`);
    const sv = a.sensitivityWithRecoveredPartials;
    if (out.partialRecovery.sessions) {
      L.push(
        `    if the ${out.partialRecovery.sessions} killed sessions' recoverable input side is added back to OUR arm: ` +
          `${fmtPct(sv.tokenReductionPct)} tokens / ${fmtPct(sv.costReductionPct)} cost`,
      );
    }
    L.push('');
  }

  const tokensAll = names.length ? out.arms[names[0]].shiploopTokens : 0;
  L.push(`  rates reconciliation: median computed/reported = ${out.reconciliation.medianComputedOverReported == null ? 'n/a' : out.reconciliation.medianComputedOverReported.toFixed(3)} over ${out.reconciliation.n} sessions`);
  if (out.reconciliation.within2pct != null) {
    L.push(`                        ${(out.reconciliation.within2pct * 100).toFixed(1)}% of sessions within 2% of reported`);
  }
  const tf = out.tierFallback;
  if (!tf.sessions) {
    L.push('  tier fallback: none. Every session named a real model in modelUsage, on a turn, or on its init event.');
  } else {
    const share = tokensAll ? (100 * tf.tokens) / tokensAll : 0;
    L.push(
      `  tier fallback: ${tf.measuredSessions} of the measured arm's sessions and ${tf.sessions - tf.measuredSessions} recovered partial(s)`,
    );
    L.push(
      `                 name no model anywhere, holding ${tf.tokens.toLocaleString('en-US')} tokens = ${share.toFixed(3)}% of the corpus.`,
    );
    L.push('                 Priced at the Opus rate, which inflates both arms and very nearly cancels.');
  }
  L.push('');
  L.push('  Ticket 1 saves 0% at the median: there is nothing carried yet. The saving is entirely');
  L.push('  the context that a single session accumulates and a fresh worker never loads. (A ticket');
  L.push('  needing a same-ticket retry is the one documented exception -- METHODOLOGY.md.)');
  L.push('  Method, assumptions, and which arm each one flatters: bench/METHODOLOGY.md');

  console.log(L.join('\n'));
}

main();
