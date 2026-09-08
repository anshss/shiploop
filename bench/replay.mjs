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

// ── baselines (spec section 1) ───────────────────────────────────────────────
// The context arm says how much a single session could CARRY. The baseline says what MODEL that
// single session ran on. They compose into a matrix: 3 arms x 2 baselines.
const BASELINES = {
  'same-mix': {
    label: 'the same sessions at the same model tiers, glued into one session',
    short: 'same model mix',
  },
  'driver-tier': {
    label: "one session running entirely on the dispatching session's own tier",
    short: "driver's tier",
  },
};
const DEFAULT_BASELINE = 'driver-tier';

// Quota weight = the tier's input rate relative to the cheapest tier's. It is the
// subscription-plan framing of the routing credit: a plan meters capacity, not dollars, and an
// opus token eats five haiku tokens' worth of it. Printed in the report header, never mixed with
// raw token counts.
const QUOTA_WEIGHTS = { opus: 5, sonnet: 2, haiku: 1 };
const TIER_RANK = { haiku: 1, sonnet: 2, opus: 3 };

// Per-class estimate of the model work a `scripted-action` event replaced, in tokens. The keys are
// the scout's `DET_KIND` values, which is what `deterministic-apply.sh` puts on the wire, and the
// scout CLAMPS that field to exactly this set (`SCOUT_DET_KINDS` in scout-ticket.sh). An
// unrecognised class is counted, credited zero, and named in the report.
//
// The figure is a FLOOR, not an estimate of the work: a deterministic apply resolves the ticket
// with zero model turns, so what it avoided is a whole worker session, and this credits only the
// context that session would have paid to reach its FIRST turn.
//
// It is a calibration PARAMETER, not a result, and it is PROVISIONAL. It was set from the low end
// of observed worker first-turn contexts, rounded down. The corpus that observation came off is not
// instrumented well enough to publish anything from (bench/published-rows/SCHEMA.md), so the
// statistic behind it is deliberately not quoted here, and this constant must be re-derived from an
// instrumented corpus before any figure that depends on it is published.
//
// The classes are not differentiated from each other because nothing measured supports
// differentiating them. Inventing a spread per class would be precision this bench has not earned;
// one honest floor applied uniformly is the conservative choice, and it is stated as such.
const SCRIPTED_ACTION_FLOOR = 45_000;
// Bytes-to-tokens for the output-suppression lever. The emitter records BYTES (it is counting a
// file it is about to delete, not a tokenised stream), so the reader converts. 4 is the same
// rough constant the governor uses for its own sizing, and it is an ESTIMATE: it is stated
// wherever this lever is printed rather than presented as a measured token count.
const SUPPRESSION_BYTES_PER_TOKEN = 4;
const SCRIPTED_ACTION_ESTIMATES = {
  'config-default': SCRIPTED_ACTION_FLOOR,
  'version-bump': SCRIPTED_ACTION_FLOOR,
  'dead-line-delete': SCRIPTED_ACTION_FLOOR,
  'known-rename': SCRIPTED_ACTION_FLOOR,
  'add-key': SCRIPTED_ACTION_FLOOR,
};

// A transcript that is orchestration rather than ticket work: the governor's own model calls, the
// scout, a re-verification pass. Spec section 4a charges these into the SHIPLOOP arm, which lowers
// the shiploop number. Matched by basename (with any `.attemptN` / `.prior` infix) or by sitting
// outside a `ticket-*` directory.
const ORCHESTRATION_BASENAMES =
  /^(governor|driver|scout|supervise|supervisor|improve|review|reverify|re-verify|reverification|porter|bookkeep)(\..*)?\.jsonl$/;

// Levers this bench does NOT put a number on, each with the counterfactual that is missing. They
// are printed in every report: a lever table that lists only what it can measure reads as a
// complete accounting of the product, and it is not one.
const UNMEASURED_LEVERS = [
  {
    lever: 'shared-exploration',
    why: 'needs a counterfactual for what a second worker would have re-read had the first not written its findings down, which no transcript records.',
  },
  {
    lever: 'memory-budget',
    why: 'needs the size of the memory a session would have grown without a fixed budget, which is unobservable once the budget is enforced.',
  },
  {
    lever: 'blocked-work-early-catch',
    why: 'needs the cost of the run that a blocked ticket would have consumed had it not been caught, which by definition never ran.',
  },
];

// Levers whose saving is already baked INTO the transcripts the vanilla arm is built from, so both
// arms get them and neither is credited. The direction of the error is known (the model understates
// shiploop), which is why these are `absorbed`, not `unmeasured`.
const ABSORBED_LEVERS = [
  {
    lever: 'lean-worker-session',
    why: 'trimmed tool lists and stripped worker context are already in the measured transcripts, so the modeled vanilla session inherits them. A true vanilla session would be fatter.',
  },
  {
    lever: 'scripted-codebase-map',
    why: 'the map replaced exploratory reads before the transcript existed, so the reads it avoided are absent from BOTH arms.',
  },
];

function tierOf(model) {
  const m = String(model || '').toLowerCase();
  if (m.includes('opus')) return 'opus';
  if (m.includes('sonnet')) return 'sonnet';
  if (m.includes('haiku')) return 'haiku';
  return null;
}

// ── CLI ──────────────────────────────────────────────────────────────────────
function parseArgs(argv) {
  const opts = {
    arm: 'all',
    baseline: DEFAULT_BASELINE,
    partials: 'price',
    json: false,
    scope: 'all',
    fleets: [],
    all: false,
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--arm') opts.arm = argv[++i];
    else if (a === '--baseline') opts.baseline = argv[++i];
    else if (a === '--partials') opts.partials = argv[++i];
    else if (a === '--json') opts.json = true;
    else if (a === '--scope') opts.scope = argv[++i];
    else if (a === '--fleet') opts.fleets.push(path.resolve(argv[++i]));
    else if (a === '--since') opts.since = argv[++i];
    else if (a === '--all') opts.all = true;
    else if (a === '--rows') opts.rows = true;
    else if (a === '--rows-file') opts.rowsFile = argv[++i];
    else if (a === '-h' || a === '--help') opts.help = true;
    else return { error: `unknown argument: ${a}` };
  }
  if (opts.arm !== 'all' && !ARMS[opts.arm]) {
    return { error: `unknown arm: ${opts.arm} (expected 200k, 1m, uncapped, or all)` };
  }
  if (opts.baseline !== 'all' && !BASELINES[opts.baseline]) {
    return { error: `unknown baseline: ${opts.baseline} (expected same-mix, driver-tier, or all)` };
  }
  if (opts.partials !== 'price' && opts.partials !== 'drop') {
    return { error: `unknown partials mode: ${opts.partials} (expected price or drop)` };
  }
  if (opts.scope !== 'all' && opts.scope !== 'resolved') {
    return { error: `unknown scope: ${opts.scope} (expected all or resolved)` };
  }
  return opts;
}

const USAGE = `usage: node bench/replay.mjs [--fleet <path>]... [--arm 200k|1m|uncapped|all]
                            [--baseline same-mix|driver-tier|all] [--partials price|drop]
                            [--scope all|resolved] [--since YYYYMMDD[-HHMMSS]] [--all] [--json]
                            [--rows] [--rows-file <published-rows.jsonl>]

  --fleet   a shiploop workspace to read (repeatable). Defaults to auto-discovery of the
            current workspace and its siblings. Read only, never written to.
  --arm     which counterfactual session to model. Default all.
  --baseline which MODEL the counterfactual session runs on. Composes with --arm as a matrix.
            same-mix   = the same sessions at the same tiers, glued together (the pre-#108 model).
            driver-tier = one session entirely on the dispatching session's tier, which is the
                          real alternative to the harness. Default driver-tier.
  --partials price (default) counts a session killed before its result event from the usage it
            DID record, flagged partial. drop is the pre-#108 behavior, kept to reproduce
            historical numbers. Both totals are printed either way.
  --rows-file aggregate a published rows file (bench/published-rows/*.jsonl) instead of reading
            transcripts, and print the reduction each arm's rows imply. This is the frozen
            regression corpus: no fleet workspace is touched.
  --scope   all (every ticket the loop paid for) or resolved (only tickets that
            ticket-history.jsonl marks resolved). Default all. Scope selects what is
            COUNTED, never what happened: a failed ticket keeps contributing carry.
  --since   keep only runs whose run-dir timestamp (run-YYYYMMDD-HHMMSS-<pid>, local time) is
            >= this value. Composes with the version scope below (both must pass).
  --all     use every stamped-or-not run in the corpus, spanning every shiploop version this
            workspace has ever run. Without it, the default is the run's OWN shiploop version
            (run-.../shiploop-version, written by run-loop.sh at dispatch): only runs stamped
            with the NEWEST version present are kept, so an old workspace's numbers are not
            diluted by every prior harness version it has run under. A run from before the stamp
            shipped, or a workspace whose scaffold never wrote one, has no file and is reported
            separately as unstamped-legacy. If NO run anywhere is stamped, this falls back to
            --all automatically and says so, rather than reporting zero.
  --json    machine-readable output instead of the report.
  --rows    print one anonymized JSONL row per (run, ticket position) instead of the aggregate
            report — the recomputable evidence behind a published percentage. fleet/run/ticket
            identifiers are replaced with an opaque hash; run id, position (depth), sessions,
            measured tokens/cost, modeled tokens/cost, and the run's shiploop version and
            timestamp survive. Combine with --arm to pick which counterfactual's rows to emit
            (default: every arm, one row set per arm).`;

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
      // no event carries the shiploop PACKAGE version. That version instead comes from a sibling
      // file next to the transcript (run-.../shiploop-version, see runVersion below), written by
      // run-loop.sh at dispatch time; --since's run-dir-timestamp filter is the older, coarser
      // proxy, kept for corpora with no stamp at all.
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
function costParts(sess) {
  if (sess.modelUsage && Object.keys(sess.modelUsage).length) {
    return Object.entries(sess.modelUsage).map(([model, mu]) => ({
      model,
      input: mu.inputTokens || 0,
      output: mu.outputTokens || 0,
      cacheRead: mu.cacheReadInputTokens || 0,
      cacheCreation: mu.cacheCreationInputTokens || 0,
    }));
  }
  return [{ model: fallbackModel(sess), ...sess.billed }];
}

function writeMultOf(sess) {
  const totalWrite = sess.write1h + sess.write5m;
  const frac1h = totalWrite > 0 ? sess.write1h / totalWrite : 1;
  return frac1h * CACHE_WRITE_1H_MULT + (1 - frac1h) * CACHE_WRITE_5M_MULT;
}

// `forceTier` prices every part of the session at one tier, which is what the `driver-tier`
// baseline does to the vanilla arm: the same tokens, on the model the driver was already running.
// Passing null keeps each model's own rate, which is what the measured arm always uses.
function sessionCost(sess, fb, forceTier) {
  const writeMult = writeMultOf(sess);
  let usd = 0;
  let outputUsd = 0;
  for (const p of costParts(sess)) {
    const tier = forceTier || tierOf(p.model);
    if (!forceTier && !tierOf(p.model) && fb) fb.models.add(p.model);
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

// Quota-weighted tokens: the session's own tokens, each weighted by the tier that actually ran
// them (or by `forceTier` for the repriced arm). Never presented as, or added to, raw tokens.
function sessionQuota(sess, forceTier) {
  let q = 0;
  for (const p of costParts(sess)) {
    const tier = forceTier || tierOf(p.model) || 'opus';
    q += (p.input + p.output + p.cacheRead + p.cacheCreation) * QUOTA_WEIGHTS[tier];
  }
  return q;
}

function sessionTokens(sess) {
  const b = sess.billed;
  return b.input + b.output + b.cacheRead + b.cacheCreation;
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

// Per-session input rate for the MODELED side (carry re-reads and the re-prime refund).
//
// This replaces the old `dominantTier()`, which resolved one tier for a whole session (the model
// with the largest token volume) and priced all of that session's modeled overhead at it. On a
// session that escalated tiers mid-run, the later heavier-context turns pulled that choice toward
// the pricier tier and the whole session's overhead was billed there, inflating the modeled
// vanilla cost in shiploop's favour. The rate is now the session's own input-side token mix
// blended across the tiers that actually ran it, so a session that spent 90% of its input side on
// sonnet is priced ~90% at sonnet. For a single-model session the two are identical, which is why
// the legacy fixtures reproduce to the cent.
function sessionInputRate(sess) {
  let weighted = 0;
  let tokens = 0;
  for (const p of costParts(sess)) {
    const t = tierOf(p.model);
    const n = p.input + p.cacheRead + p.cacheCreation;
    if (!t || n <= 0) continue;
    weighted += n * RATES[t].input;
    tokens += n;
  }
  if (tokens > 0) return weighted / tokens;
  return RATES[tierOf(fallbackModel(sess)) || 'opus'].input;
}

// The tier a session's tokens weigh against a subscription quota, blended the same way.
function sessionQuotaRate(sess) {
  let weighted = 0;
  let tokens = 0;
  for (const p of costParts(sess)) {
    const t = tierOf(p.model);
    const n = p.input + p.cacheRead + p.cacheCreation;
    if (!t || n <= 0) continue;
    weighted += n * QUOTA_WEIGHTS[t];
    tokens += n;
  }
  if (tokens > 0) return weighted / tokens;
  return QUOTA_WEIGHTS[tierOf(fallbackModel(sess)) || 'opus'];
}

// The highest tier any session in the run touched: the fallback driver tier when nothing recorded
// which model dispatched the run. Conservative in the honest direction (it maximises the modeled
// vanilla cost), so the report counts how often it fired rather than hiding it.
function highestTier(sessions) {
  let best = null;
  for (const sess of sessions) {
    for (const p of costParts(sess)) {
      const t = tierOf(p.model);
      if (t && (best == null || TIER_RANK[t] > TIER_RANK[best])) best = t;
    }
    const ft = tierOf(sess.initModel);
    if (ft && (best == null || TIER_RANK[ft] > TIER_RANK[best])) best = ft;
  }
  return best;
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

// ── version scope (#107) ──────────────────────────────────────────────────────
// run-loop.sh stamps a run directory with the workspace's synced shiploop version at dispatch
// (best-effort: `govern::stamp_run_version`, never blocks a dispatch). One file per run, not per
// transcript, since a run is one dispatch of one harness version. Memoized: a fleet with many
// tickets in the same run would otherwise re-stat the same file once per ticket.
const versionCache = new Map();
function runVersion(fleetDir, run) {
  const key = `${fleetDir} ${run}`;
  if (versionCache.has(key)) return versionCache.get(key);
  let v = null;
  try {
    v = fs.readFileSync(path.join(fleetDir, 'logs', 'govern', run, 'shiploop-version'), 'utf8').trim() || null;
  } catch {
    v = null;
  }
  versionCache.set(key, v);
  return v;
}

// Numeric compare on dotted version strings (1.9.0 < 1.10.0). Falls back to a plain string
// compare for anything that doesn't parse as N.N.N, so a stray non-semver stamp never throws.
function compareVersions(a, b) {
  const pa = a.split('.').map(Number);
  const pb = b.split('.').map(Number);
  if (pa.some(Number.isNaN) || pb.some(Number.isNaN)) return a < b ? -1 : a > b ? 1 : 0;
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const d = (pa[i] || 0) - (pb[i] || 0);
    if (d) return d;
  }
  return 0;
}

// Default = keep only the runs stamped with the NEWEST version present in the corpus (right after
// an upgrade, that is the latest version that actually has data). `all` restores today's full
// sweep. A run with no stamp file is "unstamped-legacy" and is never conflated with "an older
// STAMPED version" — the two exclusion reasons are counted separately so the report can say which
// one is eating the corpus. If nothing anywhere is stamped (a pure pre-#107 workspace), there is
// no "newest" to select, so this falls back to the full sweep and says so.
function applyVersionScope(tickets, all) {
  const runVersionOf = new Map(); // "fleet#run" -> version|null, one lookup per run
  for (const t of tickets) {
    const key = `${t.fleet}#${t.run}`;
    if (!runVersionOf.has(key)) runVersionOf.set(key, runVersion(t.fleet, t.run));
  }
  const sessionsTotal = tickets.reduce((s, t) => s + t.sessions.length, 0);
  const base = { runsTotal: runVersionOf.size, sessionsTotal };

  if (all) {
    return { ...base, mode: 'all', selected: null, fellBack: false,
      runsKept: runVersionOf.size, runsExcludedOlder: 0, runsExcludedUnstamped: 0,
      sessionsKept: sessionsTotal, sessionsExcludedOlder: 0, sessionsExcludedUnstamped: 0,
      kept: tickets };
  }

  let newest = null;
  for (const v of runVersionOf.values()) {
    if (v && (newest == null || compareVersions(v, newest) > 0)) newest = v;
  }
  if (newest == null) {
    return { ...base, mode: 'all', selected: null, fellBack: true,
      runsKept: runVersionOf.size, runsExcludedOlder: 0, runsExcludedUnstamped: runVersionOf.size,
      sessionsKept: sessionsTotal, sessionsExcludedOlder: 0, sessionsExcludedUnstamped: sessionsTotal,
      kept: tickets };
  }

  let runsKept = 0, runsExcludedOlder = 0, runsExcludedUnstamped = 0;
  for (const v of runVersionOf.values()) {
    if (v === newest) runsKept++;
    else if (v) runsExcludedOlder++;
    else runsExcludedUnstamped++;
  }
  const kept = [];
  let sessionsKept = 0, sessionsExcludedOlder = 0, sessionsExcludedUnstamped = 0;
  for (const t of tickets) {
    const v = runVersionOf.get(`${t.fleet}#${t.run}`);
    if (v === newest) {
      kept.push(t);
      sessionsKept += t.sessions.length;
    } else if (v) {
      sessionsExcludedOlder += t.sessions.length;
    } else {
      sessionsExcludedUnstamped += t.sessions.length;
    }
  }
  return { ...base, mode: 'latest', selected: newest, fellBack: false,
    runsKept, runsExcludedOlder, runsExcludedUnstamped,
    sessionsKept, sessionsExcludedOlder, sessionsExcludedUnstamped,
    kept };
}

// ── orchestration, aborts and lever events (spec sections 4, 4a, 4b) ─────────
// Which side of the ledger a transcript belongs to. Ticket work is the measured arm's subject;
// orchestration is the harness's own overhead, charged into the shiploop arm by section 4a.
function roleOf(file, fleetDir) {
  if (ORCHESTRATION_BASENAMES.test(path.basename(file))) return 'orchestration';
  const rel = path.relative(path.join(fleetDir, 'logs', 'govern'), file);
  if (!rel.split(path.sep).some((p) => /^ticket-/.test(p))) return 'orchestration';
  return 'worker';
}

// A run whose state.jsonl is 0 bytes never dispatched anything: it aborted pre-flight. It is not a
// bench input (there is no work to price), but it IS a dispatch-health signal, so it is counted
// and printed rather than silently absent. See queue ticket #109.
function preflightAborts(fleetDir) {
  const logs = path.join(fleetDir, 'logs', 'govern');
  let entries = [];
  try {
    entries = fs.readdirSync(logs, { withFileTypes: true });
  } catch {
    return 0;
  }
  let n = 0;
  for (const e of entries) {
    if (!e.isDirectory() || !/^run-/.test(e.name)) continue;
    try {
      if (fs.statSync(path.join(logs, e.name, 'state.jsonl')).size === 0) n++;
    } catch {
      // no state.jsonl at all is not an abort we can prove; leave it uncounted.
    }
  }
  return n;
}

// The five instrumentation events, read from the run's sibling `lever-events.jsonl`. Contract:
// bench/LEVER-EVENTS.md. A file that does not exist means UNINSTRUMENTED, which is not the same
// as zero saving and is never reported as one. A line that will not parse is counted and skipped.
function readLeverEvents(fleetDir, run) {
  const f = path.join(fleetDir, 'logs', 'govern', run, 'lever-events.jsonl');
  let raw;
  try {
    raw = fs.readFileSync(f, 'utf8');
  } catch {
    return { present: false, events: [], malformed: 0, unknownEvents: 0 };
  }
  const events = [];
  let malformed = 0;
  let unknownEvents = 0;
  const KNOWN = new Set(['watchdog-kill', 'resume', 'scripted-action', 'escalation', 'output-suppression']);
  for (const line of raw.split('\n')) {
    if (!line.trim()) continue;
    let ev;
    try {
      ev = JSON.parse(line);
    } catch {
      malformed++;
      continue;
    }
    if (!ev || typeof ev !== 'object' || typeof ev.event !== 'string') {
      malformed++;
      continue;
    }
    if (!KNOWN.has(ev.event)) {
      unknownEvents++;
      continue;
    }
    events.push(ev);
  }
  return { present: true, events, malformed, unknownEvents };
}

// The tier the counterfactual session runs on under --baseline driver-tier. Resolution order:
// an explicit `driver-model` stamp beside the run, then the run's own orchestration transcript,
// then the highest tier any session in the run touched. The last is the FALLBACK and the report
// counts how often it fired, per spec section 1.
function resolveDriverTier(fleetDir, run, workerSessions, orchSessions) {
  let stamp = null;
  try {
    stamp = fs.readFileSync(path.join(fleetDir, 'logs', 'govern', run, 'driver-model'), 'utf8').trim();
  } catch {
    stamp = null;
  }
  if (tierOf(stamp)) return { tier: tierOf(stamp), source: 'stamp' };
  const fromOrch = highestTier(orchSessions);
  if (fromOrch) return { tier: fromOrch, source: 'orchestration-transcript' };
  return { tier: highestTier(workerSessions) || 'opus', source: 'fallback-highest-tier' };
}

function scanFleet(fleetDir) {
  const logs = path.join(fleetDir, 'logs', 'govern');
  const files = walkJsonl(logs, []);
  const statuses = ticketStatuses(fleetDir);
  const tickets = new Map(); // key "run#ticket" -> ticket record
  const orchestration = new Map(); // run -> sessions[]
  let excluded = 0;

  for (const f of files) {
    const { sessions, excluded: ex } = parseTranscript(f);
    excluded += ex;
    if (!sessions.length) continue;
    const { run, ticket } = locate(f, fleetDir);
    if (roleOf(f, fleetDir) === 'orchestration') {
      if (!orchestration.has(run)) orchestration.set(run, []);
      orchestration.get(run).push(...sessions);
      continue;
    }
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

  // Work the loop recorded as done that left no transcript here at all (a direct-to-main
  // completion, or a resolve written by hand). Out of the bench's scope by design, but the
  // denominator gap has to be visible, so it is counted from files rather than left unsaid.
  const withTranscript = new Set([...tickets.values()].map((t) => String(t.ticket)));
  const resolvedNoTranscript = new Set();
  for (const [k, v] of statuses) {
    if (!k.startsWith('*#') || v.status !== 'resolved') continue;
    const id = k.slice(2);
    if (!withTranscript.has(id)) resolvedNoTranscript.add(id);
  }

  return {
    tickets: [...tickets.values()],
    orchestration,
    excluded,
    files: files.length,
    abortedRuns: preflightAborts(fleetDir),
    resolvedWithoutTranscript: resolvedNoTranscript.size,
  };
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
// Every component is emitted twice, once priced at the sessions' own tiers (`same-mix`) and once
// at the run's driver tier (`driver-tier`). The two baselines are then a selection, not a second
// pass, which is what keeps the legacy arithmetic byte-for-byte reproducible.
function replayRun(allTicketsInOrder, window, includePartial, driverTier) {
  const ticketsInOrder = includePartial
    ? allTicketsInOrder
    : allTicketsInOrder.filter((t) => t.sessions.some((x) => !x.partial));
  const driverRead = (RATES[driverTier].input * CACHE_READ_MULT) / 1e6;
  const driverWrite = (RATES[driverTier].input * CACHE_WRITE_1H_MULT) / 1e6;
  let carry = 0;
  const rows = [];
  for (let k = 0; k < ticketsInOrder.length; k++) {
    const t = ticketsInOrder[k];
    const sessions = includePartial ? t.sessions : t.sessions.filter((x) => !x.partial);
    let shipTokens = 0;
    const shipParts = { input: 0, output: 0, cacheRead: 0, cacheCreation: 0 };
    const own = { shipCost: 0, overheadCost: 0, creditCost: 0, prefixCost: 0, shipQuota: 0, overheadQuota: 0, creditQuota: 0 };
    const drv = { shipCost: 0, overheadCost: 0, creditCost: 0, prefixCost: 0, shipQuota: 0, overheadQuota: 0, creditQuota: 0 };
    let outputCost = 0;
    let overheadTokens = 0;
    let creditTokens = 0;
    let prefixTokens = 0;
    let ownCarry = 0;
    let reportedCost = 0;
    let reconcilable = 0;
    let partials = 0;

    for (let s = 0; s < sessions.length; s++) {
      const sess = sessions[s];
      const b = sess.billed;
      shipTokens += b.input + b.output + b.cacheRead + b.cacheCreation;
      shipParts.input += b.input;
      shipParts.output += b.output;
      shipParts.cacheRead += b.cacheRead;
      shipParts.cacheCreation += b.cacheCreation;
      if (sess.partial) partials++;
      const c = sessionCost(sess, null);
      own.shipCost += c.usd;
      drv.shipCost += sessionCost(sess, null, driverTier).usd;
      own.shipQuota += sessionQuota(sess, null);
      drv.shipQuota += sessionQuota(sess, driverTier);
      outputCost += c.outputUsd;
      if (sess.reportedCostUsd != null) {
        reportedCost += sess.reportedCostUsd;
        reconcilable++;
      }

      const rate = sessionInputRate(sess);
      const readRate = (rate * CACHE_READ_MULT) / 1e6;
      const writeRate = (rate * CACHE_WRITE_1H_MULT) / 1e6;
      const qRate = sessionQuotaRate(sess);

      // What one accumulating session pays that N fresh ones do not: the carry, re-read
      // every turn, bounded by the context window.
      for (const turn of sess.turns) {
        const headroom = window === Infinity ? Infinity : Math.max(0, window - turn.ctx);
        const eff = Math.min(carry, headroom);
        overheadTokens += eff;
        own.overheadCost += eff * readRate;
        drv.overheadCost += eff * driverRead;
        own.overheadQuota += eff * qRate;
        drv.overheadQuota += eff * QUOTA_WEIGHTS[driverTier];
      }

      // What N fresh sessions pay that one accumulating session does not: re-priming the base
      // context (system prompt, CLAUDE.md, ticket text) at the start of every session after the
      // first. Credited to vanilla at the cache-write rate.
      if (!(k === 0 && s === 0) && sess.turns.length) {
        const prime = sess.turns[0].cacheCreation;
        creditTokens += prime;
        own.creditCost += prime * writeRate;
        drv.creditCost += prime * driverWrite;
        own.creditQuota += prime * qRate;
        drv.creditQuota += prime * QUOTA_WEIGHTS[driverTier];
      }

      // Lever 11b, cross-worker cache-prefix preservation. Measured from data every transcript
      // already carries: a spawn whose prefix survived byte-identical pays turn-1 cache READS
      // where a spawn without it would have paid cache WRITES. Credit is the read/write spread on
      // exactly those tokens. Token COUNT is unchanged by it, which is why this lever contributes
      // nothing to the token metric. Only sessions after the run's very first one can reuse
      // anything, so the first is excluded.
      if (!(k === 0 && s === 0) && sess.turns.length) {
        const reused = sess.turns[0].cacheRead;
        prefixTokens += reused;
        own.prefixCost += reused * (writeRate - readRate);
        drv.prefixCost += reused * (driverWrite - driverRead);
      }

      if (sess.turns.length) {
        const first = sess.turns[0].ctx;
        const last = sess.turns[sess.turns.length - 1].ctx;
        ownCarry += Math.max(0, last - first);
      }
    }

    // The legacy pair, kept exactly as it was before the multi-lever build: same-mix pricing,
    // carry only, no harness overhead, no event-derived levers. It is the regression anchor.
    const vanTokens = Math.max(0, shipTokens + overheadTokens - creditTokens);
    const vanCost = Math.max(0, own.shipCost + own.overheadCost - own.creditCost);
    rows.push({
      position: k + 1,
      fleet: t.fleet,
      run: t.run,
      ticket: t.ticket,
      status: t.status,
      counted: t.counted !== false,
      sessions: sessions.length,
      partials,
      shipTokens,
      shipParts,
      outputCost,
      overheadTokens,
      creditTokens,
      prefixTokens,
      own,
      drv,
      shipCost: own.shipCost,
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

// ── event-derived levers (spec section 4b, contract bench/LEVER-EVENTS.md) ───
// Credit is earned only by runs that actually carry `lever-events.jsonl`. A run without one is
// UNINSTRUMENTED and is reported as such; it never contributes a zero that would drag an average
// down and read as "this lever saves nothing".
function leversFromEvents(events, window, driverTier) {
  const zero = () => ({ tokens: 0, cost: 0, quota: 0, n: 0 });
  const out = {
    watchdog: zero(),
    resume: zero(),
    'skip-the-model': zero(),
    'escalation-correction': zero(),
    'output-suppression': zero(),
  };
  const unknownClasses = new Map();
  const readRate = (tier) => (RATES[tier].input * CACHE_READ_MULT) / 1e6;

  for (const ev of events) {
    const tier = tierOf(ev.tier) || driverTier;
    if (ev.event === 'watchdog-kill') {
      // The floor, not the true counterfactual: at minimum the un-killed session would have taken
      // one more turn re-reading the context it had reached, bounded by the arm's window. A
      // session the watchdog stopped could have run away much further; this credits one turn.
      const tk = Math.min(Number(ev.ctxTokens) || 0, window);
      out.watchdog.tokens += tk;
      out.watchdog.cost += tk * readRate(tier);
      out.watchdog.quota += tk * QUOTA_WEIGHTS[tier];
      out.watchdog.n++;
    } else if (ev.event === 'resume') {
      // `freshStartTokens` is the failed attempt's CONTEXT-RECONSTRUCTION spend only (input plus
      // cache creation, output excluded), per the wire contract. A retry redoes the actual work
      // either way; the only thing resuming avoids is reading its way back into context. Crediting
      // the failed attempt's total spend would hand this lever attempt 1's output tokens, which
      // would be a lever biased toward shiploop. This number is under-counted by construction and
      // the report says so where it prints it.
      const tk = Math.max(0, (Number(ev.freshStartTokens) || 0) - (Number(ev.checkpointTokens) || 0));
      out.resume.tokens += tk;
      out.resume.cost += tk * readRate(tier);
      out.resume.quota += tk * QUOTA_WEIGHTS[tier];
      out.resume.n++;
    } else if (ev.event === 'output-suppression') {
      // verify-filter.sh withheld a passing command's output from the transcript. Bytes to tokens
      // at SUPPRESSION_BYTES_PER_TOKEN, then credited ONCE.
      //
      // Crediting once is a hard floor, and a deliberately loose one: the real saving is that these
      // bytes would have been re-sent on EVERY later turn of the session, which is the whole reason
      // the wrapper exists. Charging one turn is what can be defended without knowing how many
      // turns remained, and the report says so rather than implying the lever is small.
      //
      // Coverage limit, disclosed wherever this is printed: wrapping a command is OPT-IN and the
      // router hook only nudges. This measures suppression that HAPPENED, never suppression that
      // could have happened, so an uncredited session is not evidence that nothing was withheld.
      const tk = Math.max(0, Math.floor((Number(ev.withheldBytes) || 0) / SUPPRESSION_BYTES_PER_TOKEN));
      out['output-suppression'].tokens += tk;
      out['output-suppression'].cost += tk * readRate(tier);
      out['output-suppression'].quota += tk * QUOTA_WEIGHTS[tier];
      out['output-suppression'].n++;
    } else if (ev.event === 'scripted-action') {
      const est = SCRIPTED_ACTION_ESTIMATES[ev.class];
      out['skip-the-model'].n++;
      if (est == null) {
        unknownClasses.set(String(ev.class), (unknownClasses.get(String(ev.class)) || 0) + 1);
        continue;
      }
      out['skip-the-model'].tokens += est;
      out['skip-the-model'].cost += est * readRate(tier);
      out['skip-the-model'].quota += est * QUOTA_WEIGHTS[tier];
    } else if (ev.event === 'escalation') {
      // An escalation means a cheap-tier attempt was wasted. The routing credit claimed for those
      // tokens is not real, so it is taken back. Negative by construction; zero when the failed
      // attempt already ran at or above the driver's tier, and zero under same-mix (see below,
      // where the whole term is dropped when there is no routing credit to correct).
      //
      // Not every retry carries one of these. The emitter fires it only for the retry classes that
      // actually change tier (budget / judgment / unknown) and deliberately not for infra or CI
      // retries, which re-run at the same tier and buy no escalation. So this correction is a
      // partial one by design: a retry with no event is not evidence that no tokens were wasted,
      // only that no TIER CHANGE was bought. Nothing here assumes one event per retry.
      const ft = tierOf(ev.failedTier) || driverTier;
      const tk = Number(ev.failedTokens) || 0;
      const spread = RATES[driverTier].input - RATES[ft].input;
      const qSpread = QUOTA_WEIGHTS[driverTier] - QUOTA_WEIGHTS[ft];
      out['escalation-correction'].cost -= (tk * Math.max(0, spread)) / 1e6;
      out['escalation-correction'].quota -= tk * Math.max(0, qSpread);
      out['escalation-correction'].n++;
    }
  }
  return { levers: out, unknownClasses };
}

// ── the frozen regression corpus (--rows-file) ───────────────────────────────
// Published rows are the recomputable evidence behind a published percentage, and re-deriving the
// percentage from them is the one regression check that does not depend on private transcripts.
// The arithmetic here is deliberately the same three lines the METHODOLOGY jq recipe runs, so a
// reader can check the tool against their own jq rather than against another run of the tool.
function aggregateRowsFile(file, asJson) {
  let raw;
  try {
    raw = fs.readFileSync(file, 'utf8');
  } catch (e) {
    console.error(`cannot read rows file: ${file}`);
    process.exit(2);
  }
  const byArm = new Map();
  let rows = 0;
  let malformed = 0;
  let unknownVersion = 0;
  const versions = new Set();
  for (const line of raw.split('\n')) {
    if (!line.trim()) continue;
    let r;
    try {
      r = JSON.parse(line);
    } catch {
      malformed++;
      continue;
    }
    rows++;
    // Absent and the literal string `unknown` are the same state: a row whose run carried no
    // version stamp. `--rows` writes the string, older rows have no field at all, and neither is
    // a version anyone can scope by, so both are counted here and neither is listed as a version.
    if (r.version && r.version !== 'unknown') versions.add(r.version);
    else unknownVersion++;
    const k = r.arm || 'unknown';
    if (!byArm.has(k)) byArm.set(k, { arm: k, rows: 0, shipTokens: 0, vanillaTokens: 0, shipCostUsd: 0, vanillaCostUsd: 0 });
    const a = byArm.get(k);
    a.rows++;
    a.shipTokens += r.shipTokens || 0;
    a.vanillaTokens += r.vanillaTokens || 0;
    a.shipCostUsd += r.shipCostUsd || 0;
    a.vanillaCostUsd += r.vanillaCostUsd || 0;
  }
  const arms = {};
  for (const a of byArm.values()) {
    arms[a.arm] = {
      ...a,
      tokenReductionPct: pct(a.shipTokens, a.vanillaTokens),
      costReductionPct: pct(a.shipCostUsd, a.vanillaCostUsd),
    };
  }
  const out = {
    kind: 'replay-rows',
    file,
    rows,
    malformedRows: malformed,
    rowsWithoutVersion: unknownVersion,
    versions: [...versions].sort(),
    arms,
  };
  if (asJson) {
    console.log(JSON.stringify(out, null, 2));
  } else {
    const L = [`shiploop bench: published rows`, `  file: ${file}`,
      `  rows: ${rows}   malformed: ${malformed}   without a version stamp: ${unknownVersion} (treated as unknown)`,
      `  versions: ${out.versions.length ? out.versions.join(', ') : 'none stamped'}`, ''];
    for (const a of Object.values(arms)) {
      L.push(`  arm ${a.arm}   ${a.rows} rows   tokens ${fmtPct(a.tokenReductionPct)}   cost ${fmtPct(a.costReductionPct)}`);
    }
    console.log(L.join('\n'));
  }
  process.exit(rows ? 0 : 1);
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

  if (opts.rowsFile) {
    aggregateRowsFile(opts.rowsFile, opts.json);
    return;
  }

  const fleets = opts.fleets.length ? opts.fleets : discoverFleets(process.cwd());
  const armNames = opts.arm === 'all' ? Object.keys(ARMS) : [opts.arm];
  const baselineNames = opts.baseline === 'all' ? Object.keys(BASELINES) : [opts.baseline];
  const primaryBaseline = baselineNames[0];

  const allTickets = [];
  let excludedSessions = 0;
  let abortedRuns = 0;
  let resolvedWithoutTranscript = 0;
  const fleetNotes = [];
  const orchByRun = new Map(); // "fleet#run" -> orchestration sessions

  for (const fleet of fleets) {
    const scan = scanFleet(fleet);
    excludedSessions += scan.excluded;
    abortedRuns += scan.abortedRuns;
    resolvedWithoutTranscript += scan.resolvedWithoutTranscript;
    allTickets.push(...scan.tickets);
    for (const [run, sessions] of scan.orchestration) orchByRun.set(`${fleet}#${run}`, sessions);
    fleetNotes.push({ fleet, tickets: scan.tickets.length, transcripts: scan.files });
  }

  // --since: the older, coarser date-cutoff proxy for "sessions on shiploop version X or later"
  // (pass X's release commit timestamp). Runs whose run-dir name doesn't parse as a timestamp
  // (e.g. "adhoc") are dropped by a --since filter: an unparseable run can never be shown to be
  // on-or-after the cutoff. Composes with the version scope below: since narrows first, then the
  // version filter narrows what is left.
  const runsSeenTotal = new Set(allTickets.map((t) => `${t.fleet}#${t.run}`)).size;
  const keptByDate = opts.since
    ? allTickets.filter((t) => {
        const k = runDateKey(t.run);
        return k != null && k >= opts.since;
      })
    : allTickets;
  const runsSeenKept = new Set(keptByDate.map((t) => `${t.fleet}#${t.run}`)).size;

  // Version scope (#107): default to the run's OWN shiploop-version stamp, keeping only the
  // newest version present. `--all` (or a corpus with no stamp anywhere) restores the full sweep.
  const versionScope = applyVersionScope(keptByDate, opts.all);
  const allTicketsAfterVersion = versionScope.kept;

  // Corpus metadata for the headline: CLI version(s) and model(s) actually seen, and the date span
  // of the run dirs that made the cut — printed next to the number, not left for stdout to bury.
  // Computed over the FINAL corpus (after --since and the version scope), so it describes exactly
  // what fed the numbers below rather than a wider set that was then quietly narrowed further.
  const cliVersions = new Set();
  const models = new Set();
  let minDate = null;
  let maxDate = null;
  for (const t of allTicketsAfterVersion) {
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
    versionScope: {
      mode: versionScope.mode,
      selected: versionScope.selected,
      fellBack: versionScope.fellBack,
      runsTotal: versionScope.runsTotal,
      runsKept: versionScope.runsKept,
      runsExcludedOlder: versionScope.runsExcludedOlder,
      runsExcludedUnstamped: versionScope.runsExcludedUnstamped,
      sessionsTotal: versionScope.sessionsTotal,
      sessionsKept: versionScope.sessionsKept,
      sessionsExcludedOlder: versionScope.sessionsExcludedOlder,
      sessionsExcludedUnstamped: versionScope.sessionsExcludedUnstamped,
    },
  };

  // Scope selects which tickets are COUNTED, never which ones happened. A ticket the loop failed
  // still consumed the loop's tokens and still would have grown a single session's context, so it
  // keeps contributing carry to the tickets after it under either scope. Dropping it from the run
  // outright would shorten the modeled session and mechanically flatter whichever arm.
  const kept = allTicketsAfterVersion.filter((t) => t.sessions.length > 0);
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

  // Per-run context the model needs beyond the transcripts themselves: which tier the run's
  // orchestrator was on (the `driver-tier` counterfactual), and whether the run carries the
  // instrumentation events at all.
  const runCtx = new Map();
  for (const [key, arr] of runs) {
    const [fleet, run] = [arr[0].fleet, arr[0].run];
    const workerSessions = arr.flatMap((t) => t.sessions);
    const orch = orchByRun.get(key) || [];
    const driver = resolveDriverTier(fleet, run, workerSessions, orch);
    const lev = readLeverEvents(fleet, run);
    runCtx.set(key, {
      fleet,
      run,
      driverTier: driver.tier,
      driverTierSource: driver.source,
      orch,
      levers: lev,
      version: runVersion(fleet, run),
      dateKey: runDateKey(run),
    });
  }

  const driverTierAudit = {
    runs: runCtx.size,
    fromStamp: [...runCtx.values()].filter((c) => c.driverTierSource === 'stamp').length,
    fromOrchestrationTranscript: [...runCtx.values()].filter((c) => c.driverTierSource === 'orchestration-transcript')
      .length,
    fromFallbackHighestTier: [...runCtx.values()].filter((c) => c.driverTierSource === 'fallback-highest-tier').length,
    tiers: [...new Set([...runCtx.values()].map((c) => c.driverTier))].sort(),
  };

  // Section 4a: the harness's own overhead, charged into the SHIPLOOP arm. A run with no
  // orchestration transcript is `overhead-uncovered`: its governor/scout spend happened and is
  // simply not in the corpus, so it is counted rather than assumed to be zero.
  const overhead = { runs: runCtx.size, covered: 0, uncovered: 0, tokens: 0, costUsd: 0, quota: 0, sessions: 0 };
  for (const c of runCtx.values()) {
    if (!c.orch.length) {
      overhead.uncovered++;
      continue;
    }
    overhead.covered++;
    for (const sess of c.orch) {
      overhead.sessions++;
      overhead.tokens += sessionTokens(sess);
      overhead.costUsd += sessionCost(sess, null).usd;
      overhead.quota += sessionQuota(sess, null);
    }
  }

  const instrumented = { runs: runCtx.size, withEvents: 0, malformedLines: 0, unknownEvents: 0 };
  for (const c of runCtx.values()) {
    if (c.levers.present) instrumented.withEvents++;
    instrumented.malformedLines += c.levers.malformed;
    instrumented.unknownEvents += c.levers.unknownEvents;
  }

  // --rows evidence, keyed by arm. Populated once per real (non-sensitivity) computeArm call.
  const rowsByArm = {};

  const computeArm = (arm, baseline, includePartial, keepRows) => {
    const window = ARMS[arm].window;
    const all = [];
    const perRun = new Map();
    for (const [key, arr] of runs) {
      const rr = replayRun(arr, window, includePartial, runCtx.get(key).driverTier);
      perRun.set(key, rr);
      all.push(...rr);
    }
    const rows = all.filter((r) => r.counted);
    if (keepRows) rowsByArm[arm] = all;
    const pick = (r) => (baseline === 'driver-tier' ? r.drv : r.own);
    const routing = baseline === 'driver-tier';

    // One aggregation, used for the arm total AND for each fleet's row in the spread table, so a
    // per-fleet figure can never be computed by a different model than the headline it sits under.
    const aggregate = (rs) => {
      const sum = (f) => rs.reduce((s, r) => s + f(r), 0);
      const runKeys = new Set(rs.map((r) => `${r.fleet}#${r.run}`));

      // Section 4a: the harness's own overhead, charged into the SHIPLOOP arm. A run with no
      // orchestration transcript is `overhead-uncovered`: its governor and scout spend happened
      // and is simply not in the corpus, so it is counted rather than assumed to be zero.
      const ov = { runs: runKeys.size, covered: 0, uncovered: 0, sessions: 0, tokens: 0, costUsd: 0, quota: 0 };
      const orchParts = { input: 0, output: 0, cacheRead: 0, cacheCreation: 0 };
      for (const key of runKeys) {
        const c = runCtx.get(key);
        if (!c || !c.orch.length) {
          ov.uncovered++;
          continue;
        }
        ov.covered++;
        for (const sess of c.orch) {
          ov.sessions++;
          ov.tokens += sessionTokens(sess);
          ov.costUsd += sessionCost(sess, null).usd;
          ov.quota += sessionQuota(sess, null);
          orchParts.input += sess.billed.input;
          orchParts.output += sess.billed.output;
          orchParts.cacheRead += sess.billed.cacheRead;
          orchParts.cacheCreation += sess.billed.cacheCreation;
        }
      }

      // The measured side is never repriced: it is what was actually billed. The harness's own
      // orchestration spend is added on top, which LOWERS this arm's reduction on purpose.
      const shipTokens = sum((r) => r.shipTokens) + ov.tokens;
      const shipCost = sum((r) => r.own.shipCost) + ov.costUsd;
      const shipQuota = sum((r) => r.own.shipQuota) + ov.quota;
      const outputCost = sum((r) => r.outputCost);

      // Event-derived levers, credited only in runs that carry lever-events.jsonl.
      const evLevers = {
        watchdog: { tokens: 0, cost: 0, quota: 0, n: 0 },
        resume: { tokens: 0, cost: 0, quota: 0, n: 0 },
        'skip-the-model': { tokens: 0, cost: 0, quota: 0, n: 0 },
        'escalation-correction': { tokens: 0, cost: 0, quota: 0, n: 0 },
        'output-suppression': { tokens: 0, cost: 0, quota: 0, n: 0 },
      };
      const coverage = {
        watchdog: 0, resume: 0, 'skip-the-model': 0, 'escalation-correction': 0,
        'output-suppression': 0,
      };
      const unknownClassCounts = new Map();
      let instrumentedRuns = 0;
      for (const key of runKeys) {
        const c = runCtx.get(key);
        if (!c || !c.levers.present) continue;
        instrumentedRuns++;
        const { levers: L, unknownClasses } = leversFromEvents(c.levers.events, window, c.driverTier);
        for (const [name, v] of Object.entries(L)) {
          if (name === 'escalation-correction' && !routing) continue; // no routing credit to correct
          const key2 = name;
          evLevers[key2].tokens += v.tokens;
          evLevers[key2].cost += v.cost;
          evLevers[key2].quota += v.quota;
          evLevers[key2].n += v.n;
          if (v.n) coverage[key2]++;
        }
        for (const [k, n] of unknownClasses) unknownClassCounts.set(k, (unknownClassCounts.get(k) || 0) + n);
      }
      const evStatus = instrumentedRuns ? 'measured' : 'uninstrumented';

      const levers = {
        carry: {
          tokens: sum((r) => r.overheadTokens - r.creditTokens),
          cost: sum((r) => pick(r).overheadCost - pick(r).creditCost),
          quota: sum((r) => pick(r).overheadQuota - pick(r).creditQuota),
          n: rs.length,
          status: 'measured',
          coverage: { credited: runKeys.size, of: runKeys.size },
        },
        routing: {
          tokens: 0,
          cost: routing ? sum((r) => r.drv.shipCost - r.own.shipCost) : 0,
          quota: routing ? sum((r) => r.drv.shipQuota - r.own.shipQuota) : 0,
          n: rs.length,
          status: routing ? 'measured' : 'not-in-this-baseline',
          coverage: { credited: routing ? runKeys.size : 0, of: runKeys.size },
        },
        'cache-prefix': {
          tokens: 0,
          cost: sum((r) => pick(r).prefixCost),
          quota: 0,
          n: sum((r) => (r.prefixTokens > 0 ? 1 : 0)),
          status: 'measured',
          coverage: { credited: runKeys.size, of: runKeys.size },
        },
        watchdog: { ...evLevers.watchdog, status: evStatus, coverage: { credited: coverage.watchdog, of: runKeys.size } },
        'resume-not-restart': { ...evLevers.resume, status: evStatus, coverage: { credited: coverage.resume, of: runKeys.size } },
        'skip-the-model': { ...evLevers['skip-the-model'], status: evStatus, coverage: { credited: coverage['skip-the-model'], of: runKeys.size } },
        'escalation-correction': {
          ...evLevers['escalation-correction'],
          status: !routing ? 'not-in-this-baseline' : evStatus,
          coverage: { credited: coverage['escalation-correction'], of: runKeys.size },
        },
        // Event-derived like the five above, from verify-filter.sh's `output-suppression`.
        // Uncredited runs are UNINSTRUMENTED, never a measured zero: the withheld bytes are absent
        // from every transcript, so a run with no event proves nothing about what it withheld.
        'output-suppression': {
          ...evLevers['output-suppression'],
          status: evStatus,
          coverage: { credited: coverage['output-suppression'], of: runKeys.size },
        },
        'harness-overhead': {
          tokens: -ov.tokens,
          cost: -ov.costUsd,
          quota: -ov.quota,
          n: ov.sessions,
          status: 'measured',
          coverage: { credited: ov.covered, of: ov.runs },
        },
      };

      const leverTotal = (metric) => Object.values(levers).reduce((s, l) => s + (l[metric] || 0), 0);
      const vanTokens = shipTokens + leverTotal('tokens');
      const vanCost = shipCost + leverTotal('cost');
      const vanQuota = shipQuota + leverTotal('quota');

      // The additivity the spec requires: the components must BE the saving, not merely accompany
      // it. A mismatch is a modelling bug and is reported as one rather than rounded away.
      const check = (a, b) => Math.abs(a - b) <= Math.max(1e-6, Math.abs(b) * 1e-9);
      const leverSumCheck = {
        tokens: check(leverTotal('tokens'), vanTokens - shipTokens),
        cost: check(leverTotal('cost'), vanCost - shipCost),
        quotaWeighted: check(leverTotal('quota'), vanQuota - shipQuota),
      };

      const part = (k) => sum((r) => r.shipParts[k]);
      const shipBreakdown = {
        input: part('input') + orchParts.input,
        output: part('output') + orchParts.output,
        cacheRead: part('cacheRead') + orchParts.cacheRead,
        cacheCreation: part('cacheCreation') + orchParts.cacheCreation,
      };
      // The vanilla arm is the same work with three edits: the carry is re-read every turn (cache
      // read), the per-session re-prime that only fresh sessions pay is refunded (cache write), and
      // the token-bearing instrumented levers add the context a session without them would have
      // re-read. The harness's own overhead sits on the shiploop side only, so it comes back out.
      const leverReadTokens = evLevers.watchdog.tokens + evLevers.resume.tokens + evLevers['skip-the-model'].tokens;
      const vanBreakdown = {
        input: part('input'),
        output: part('output'),
        cacheRead: part('cacheRead') + sum((r) => r.overheadTokens) + leverReadTokens,
        cacheCreation: part('cacheCreation') - sum((r) => r.creditTokens),
      };

      return {
        shipTokens, shipCost, shipQuota, vanTokens, vanCost, vanQuota,
        outputCost, levers, leverSumCheck, shipBreakdown, vanBreakdown,
        overhead: ov, instrumentedRuns,
        unknownClassCounts: Object.fromEntries(unknownClassCounts),
      };
    };

    const A = aggregate(rows);
    const {
      shipTokens, shipCost, shipQuota, vanTokens, vanCost, vanQuota,
      outputCost, levers, leverSumCheck, shipBreakdown, vanBreakdown,
    } = A;
    const unknownClassCounts = A.unknownClassCounts;
    // The legacy pair: same-mix, carry only, partials dropped, no harness overhead. Frozen on
    // purpose, so a refactor that silently moves the pre-#108 model is caught as a defect rather
    // than absorbed into a new default. Locked on the synthetic fixture by test-bench-regression.sh.
    const coreRows = (
      baseline === 'same-mix' && !includePartial
        ? all
        : [].concat(...[...runs.entries()].map(([key, arr]) => replayRun(arr, window, false, runCtx.get(key).driverTier)))
    ).filter((r) => r.counted);
    const coreShipTokens = coreRows.reduce((s, r) => s + r.shipTokens, 0);
    const coreShipCost = coreRows.reduce((s, r) => s + r.own.shipCost, 0);
    const coreVanTokens = coreRows.reduce((s, r) => s + r.vanTokens, 0);
    const coreVanCost = coreRows.reduce((s, r) => s + r.vanCost, 0);

    const curve = {};
    for (const p of CURVE_POSITIONS) {
      const at = rows.filter((r) => r.position === p && r.vanTokens > 0).map((r) => pct(r.shipTokens, r.vanTokens));
      curve[p] = { n: at.length, medianTokenReductionPct: median(at) };
    }

    // Per-fleet spread, auto-printed: any pooled figure is an average over this, and the spread
    // is wider than the figure (METHODOLOGY.md).
    const fleetSpread = [];
    for (const f of new Set(rows.map((r) => r.fleet))) {
      const fr = rows.filter((r) => r.fleet === f);
      const a = aggregate(fr);
      fleetSpread.push({
        fleet: f,
        tickets: fr.length,
        runs: new Set(fr.map((r) => r.run)).size,
        tokenReductionPct: pct(a.shipTokens, a.vanTokens),
        costReductionPct: pct(a.shipCost, a.vanCost),
        quotaReductionPct: pct(a.shipQuota, a.vanQuota),
      });
    }
    fleetSpread.sort((a, b) => (b.tokenReductionPct || 0) - (a.tokenReductionPct || 0));

    return {
      arm,
      baseline,
      partials: includePartial ? 'price' : 'drop',
      contextWindow: window === Infinity ? null : window,
      label: ARMS[arm].label,
      baselineLabel: BASELINES[baseline].label,
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
      shiploopQuotaWeighted: shipQuota,
      vanillaQuotaWeighted: vanQuota,
      tokenReductionPct: pct(shipTokens, vanTokens),
      costReductionPct: pct(shipCost, vanCost),
      quotaReductionPct: pct(shipQuota, vanQuota),
      levers,
      leverSumCheck,
      overhead: A.overhead,
      unknownScriptedActionClasses: unknownClassCounts,
      coreModel: {
        shiploopTokens: coreShipTokens,
        vanillaTokens: coreVanTokens,
        shiploopCostUsd: coreShipCost,
        vanillaCostUsd: coreVanCost,
        tokenReductionPct: pct(coreShipTokens, coreVanTokens),
        costReductionPct: pct(coreShipCost, coreVanCost),
      },
      // The ceiling. Output is the same in both arms and no architecture removes it: the work
      // still has to be written. An arm that spent NOTHING but output would land here, so any
      // reduction above this line is arithmetically impossible, not merely unachieved.
      sharedOutputCostUsd: outputCost,
      ceilingTokenReductionPct: pct(vanBreakdown.output, vanTokens),
      ceilingCostReductionPct: pct(outputCost, vanCost),
      positionCurve: curve,
      fleetSpread,
    };
  };

  const baselineResults = {};
  for (const baseline of baselineNames) {
    const armResults = {};
    for (const arm of armNames) {
      const primary = computeArm(arm, baseline, opts.partials === 'price', opts.rows && baseline === primaryBaseline);
      // Both partials totals, always. Which one is the headline is a flag; which one exists is
      // not. `sensitivityWithRecoveredPartials` is always the PRICED variant, so a consumer
      // reading that key gets the same thing it always got.
      const priced = opts.partials === 'price' ? primary : computeArm(arm, baseline, true, false);
      const dropped = opts.partials === 'drop' ? primary : computeArm(arm, baseline, false, false);
      primary.sensitivityWithRecoveredPartials = {
        shiploopTokens: priced.shiploopTokens,
        vanillaTokens: priced.vanillaTokens,
        shiploopCostUsd: priced.shiploopCostUsd,
        vanillaCostUsd: priced.vanillaCostUsd,
        tokenReductionPct: priced.tokenReductionPct,
        costReductionPct: priced.costReductionPct,
        tokenReductionDeltaPts:
          priced.tokenReductionPct == null || dropped.tokenReductionPct == null
            ? null
            : priced.tokenReductionPct - dropped.tokenReductionPct,
        costReductionDeltaPts:
          priced.costReductionPct == null || dropped.costReductionPct == null
            ? null
            : priced.costReductionPct - dropped.costReductionPct,
      };
      primary.partialsTotals = {
        price: { tokenReductionPct: priced.tokenReductionPct, costReductionPct: priced.costReductionPct },
        drop: { tokenReductionPct: dropped.tokenReductionPct, costReductionPct: dropped.costReductionPct },
      };
      armResults[arm] = primary;
    }
    baselineResults[baseline] = armResults;
  }
  const armResults = baselineResults[primaryBaseline];

  if (opts.rows) {
    // Anonymized, recomputable evidence: one line per (run, ticket position), fleet/run/ticket
    // replaced with a hash so a workspace name or internal ticket number never leaves the machine.
    // Same numbers the aggregate above was built from — sum shipTokens/shipCost per run and you
    // reproduce the corresponding arm's shiploopTokens/shiploopCostUsd exactly.
    // Section 5: every row also carries the shiploop version the run was dispatched under and the
    // run's timestamp, so a version-scoped corpus is a filter over published rows rather than
    // date archaeology against raw logs. Rows published before the stamp existed carry no
    // version; a reader treats a missing one as "unknown" and the report counts them.
    for (const arm of armNames) {
      for (const r of rowsByArm[arm] || []) {
        const runHash = crypto.createHash('sha256').update(`${r.fleet}#${r.run}`).digest('hex').slice(0, 16);
        const c = runCtx.get(`${r.fleet}#${r.run}`);
        console.log(
          JSON.stringify({
            arm,
            baseline: primaryBaseline,
            run: runHash,
            version: (c && c.version) || 'unknown',
            ts: (c && c.dateKey) || null,
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
    baseline: primaryBaseline,
    partials: opts.partials,
    quotaWeights: QUOTA_WEIGHTS,
    scriptedActionEstimates: SCRIPTED_ACTION_ESTIMATES,
    meta,
    fleets: fleetNotes,
    sessionsExcludedNoResultEvent: excludedSessions,
    abortedRuns,
    resolvedWithoutTranscript,
    driverTierAudit,
    harnessOverhead: overhead,
    instrumentation: instrumented,
    unmeasuredLevers: UNMEASURED_LEVERS,
    absorbedLevers: ABSORBED_LEVERS,
    partialRecovery,
    tierFallback,
    reconciliation: recon,
    arms: armResults,
    baselines: baselineResults,
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
  // Version scope (#107): which shiploop version the default corpus was narrowed to, and how much
  // that narrowing excluded, split into older-stamped vs unstamped-legacy so a reader can tell the
  // two apart. `--all` restores the pre-#107 full sweep.
  const vs = m.versionScope;
  if (vs.mode === 'all' && vs.fellBack) {
    L.push(
      `  shiploop version: no run in this corpus is stamped (pre-#107 workspace) — falling back ` +
        `to the full sweep, ${vs.runsTotal} runs / ${vs.sessionsTotal} sessions.`,
    );
  } else if (vs.mode === 'all') {
    L.push(`  shiploop version: --all — ${vs.runsTotal} runs / ${vs.sessionsTotal} sessions, every version.`);
  } else {
    L.push(
      `  shiploop version: ${vs.selected} (newest stamped) — kept ${vs.runsKept}/${vs.runsTotal} runs, ` +
        `${vs.sessionsKept}/${vs.sessionsTotal} sessions; excluded ${vs.runsExcludedOlder} older-stamped, ` +
        `${vs.runsExcludedUnstamped} unstamped-legacy run(s). Pass --all for the full history.`,
    );
  }
  L.push('');
  L.push(`  MODELED COUNTERFACTUAL: shiploop arm measured from result events, vanilla arm modeled as`);
  const names = Object.keys(out.arms);
  L.push(`  ${names.map((n) => ARMS[n].label).join(' / ')}. No vanilla session was ever run.`);
  L.push('');
  L.push(
    `  baseline: ${out.baseline} (${BASELINES[out.baseline].label}).` +
      `   partials: ${out.partials}.   scope: ${out.scope}   fleets: ${out.fleets.length}`,
  );
  L.push(
    `  quota weights (input-rate ratios, never added to raw tokens): ` +
      Object.entries(out.quotaWeights)
        .map(([t, w]) => `${t} ${w}x`)
        .join(', '),
  );
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

  // 1. The headline: the arm a real user reproduces. Ceilings are never the headline.
  const headName = names.includes('200k') ? '200k' : names[0];
  const head = out.arms[headName];
  L.push(`  HEADLINE  baseline ${out.baseline} x arm ${headName}  (vs ${head.label})`);
  L.push(`    tokens          shiploop ${fmtTok(head.shiploopTokens)}  vanilla ${fmtTok(head.vanillaTokens)}   reduction ${fmtPct(head.tokenReductionPct)}`);
  L.push(`    cost            shiploop ${fmtUsd(head.shiploopCostUsd)}  vanilla ${fmtUsd(head.vanillaCostUsd)}   reduction ${fmtPct(head.costReductionPct)}`);
  L.push(`    quota-weighted  shiploop ${fmtTok(head.shiploopQuotaWeighted)}  vanilla ${fmtTok(head.vanillaQuotaWeighted)}   reduction ${fmtPct(head.quotaReductionPct)}`);
  L.push('    Tokens are model-independent: routing work to a cheaper tier cannot change that column.');
  L.push('');

  // 2. The per-lever table for the headline arm. Every lever, including the ones worth nothing
  // here, including the one that is negative.
  L.push(`  levers (arm ${headName}, baseline ${out.baseline}) -- components sum to the arm's saving`);
  L.push('    lever                    tokens         cost   quota-weighted   coverage');
  for (const [name, v] of Object.entries(head.levers)) {
    const blank = v.status === 'uninstrumented';
    const cov =
      v.status === 'uninstrumented'
        ? `uninstrumented (${v.coverage.of - v.coverage.credited} of ${v.coverage.of} runs carry no lever-events.jsonl)`
        : v.status === 'not-in-this-baseline'
          ? 'n/a for this baseline'
          : `credited in ${v.coverage.credited} of ${v.coverage.of} runs`;
    const tok = blank ? '   uninstr.' : fmtTok(v.tokens).padStart(9);
    const usd = blank ? '   uninstr.' : fmtUsd(v.cost).padStart(11);
    const q = blank ? '   uninstr.' : fmtTok(v.quota).padStart(14);
    L.push(`    ${name.padEnd(22)}${tok}  ${usd}   ${q}   ${cov}`);
  }
  L.push(
    `    sum check: tokens ${head.leverSumCheck.tokens ? 'ok' : 'MISMATCH'}, ` +
      `cost ${head.leverSumCheck.cost ? 'ok' : 'MISMATCH'}, ` +
      `quota-weighted ${head.leverSumCheck.quotaWeighted ? 'ok' : 'MISMATCH'}`,
  );
  L.push(
    `    skip-the-model per-class floor (tokens), keyed on the scout's deterministic kinds: ` +
      Object.entries(out.scriptedActionEstimates)
        .map(([k, v]) => `${k} ${v.toLocaleString('en-US')}`)
        .join(', '),
  );
  L.push(
    `    Three levers are UNDER-counted on purpose. skip-the-model credits only the context a worker`,
  );
  L.push(
    `    would have paid to reach its first turn, not the whole session the deterministic apply`,
  );
  L.push(
    `    replaced. resume credits only context reconstruction (input + cache creation, output`,
  );
  L.push(
    `    excluded): a retry redoes the work either way, so only the re-reading is avoided.`,
  );
  L.push(
    `    output-suppression credits the withheld bytes ONCE, though they would have been re-sent on`,
  );
  L.push(
    `    every later turn. Its coverage is also structurally partial: wrapping a command in the`,
  );
  L.push(
    `    verify filter is OPT-IN and only nudged, so a zero here can mean nothing was withheld OR`,
  );
  L.push(
    `    that nobody wrapped anything. It is never evidence that the lever does not work.`,
  );
  if (head.levers['escalation-correction'].status === 'measured') {
    L.push(
      `    The escalation correction is partial by design: it fires only where a retry actually`,
    );
    L.push(
      `    changed tier, not on infra or CI retries that re-run at the same tier.`,
    );
  }
  if (Object.keys(head.unknownScriptedActionClasses || {}).length) {
    L.push(
      `    scripted-action classes with no estimate (counted, credited zero): ` +
        Object.entries(head.unknownScriptedActionClasses)
          .map(([k, n]) => `${k} x${n}`)
          .join(', '),
    );
  }
  L.push('');

  // 3. The per-fleet spread. Any pooled figure is an average over this, and the spread is wider
  // than the figure.
  L.push(`  per-fleet spread (arm ${headName}, token / cost reduction)`);
  for (const f of head.fleetSpread) {
    L.push(
      `    ${path.basename(f.fleet).padEnd(24)} ${String(f.tickets).padStart(4)} tickets, ` +
        `${String(f.runs).padStart(3)} runs   ${fmtPct(f.tokenReductionPct)} / ${fmtPct(f.costReductionPct)}`,
    );
  }
  L.push('');

  for (const name of names) {
    const a = out.arms[name];
    L.push(`  arm ${name}  (vs ${a.label})`);
    L.push(`    tokens    shiploop ${fmtTok(a.shiploopTokens)}  vanilla ${fmtTok(a.vanillaTokens)}   reduction ${fmtPct(a.tokenReductionPct)}`);
    L.push(`    cost      shiploop ${fmtUsd(a.shiploopCostUsd)}  vanilla ${fmtUsd(a.vanillaCostUsd)}   reduction ${fmtPct(a.costReductionPct)}`);
    L.push(`    quota     shiploop ${fmtTok(a.shiploopQuotaWeighted)}  vanilla ${fmtTok(a.vanillaQuotaWeighted)}   reduction ${fmtPct(a.quotaReductionPct)}`);
    L.push(`    corpus    ${a.runs} runs, ${a.tickets} tickets, median run clears ${a.medianTicketsPerRun} ${a.medianTicketsPerRun === 1 ? 'ticket' : 'tickets'}, ${out.sessionsExcludedNoResultEvent} sessions excluded, ${out.partialRecovery.sessions} of them recoverable`);
    const curve = CURVE_POSITIONS.map((p) => {
      const c = a.positionCurve[p];
      return `#${p} ${c.n ? fmtPct(c.medianTokenReductionPct) : 'n/a'}`;
    }).join('  ');
    L.push(`    by ticket position (median token reduction): ${curve}`);
    L.push(`    ceiling    ${fmtPct(a.ceilingTokenReductionPct)} tokens / ${fmtPct(a.ceilingCostReductionPct)} cost, the most any architecture could save here (a CEILING, never a headline)`);
    L.push(
      `    carry-only legacy model (same-mix, partials dropped, no harness overhead): ` +
        `${fmtPct(a.coreModel.tokenReductionPct)} tokens / ${fmtPct(a.coreModel.costReductionPct)} cost`,
    );
    const sv = a.sensitivityWithRecoveredPartials;
    L.push(
      `    partials: priced ${fmtPct(a.partialsTotals.price.tokenReductionPct)} tokens / ` +
        `${fmtPct(a.partialsTotals.price.costReductionPct)} cost   vs dropped ` +
        `${fmtPct(a.partialsTotals.drop.tokenReductionPct)} tokens / ${fmtPct(a.partialsTotals.drop.costReductionPct)} cost`,
    );
    if (out.partialRecovery.sessions) {
      L.push(
        `    if the ${out.partialRecovery.sessions} killed sessions' recoverable input side is added back to OUR arm: ` +
          `${fmtPct(sv.tokenReductionPct)} tokens / ${fmtPct(sv.costReductionPct)} cost`,
      );
    }
    L.push('');
  }

  // 5/6. Exclusions and coverage: everything the corpus did not contain, counted.
  const ov = out.harnessOverhead;
  L.push(
    `  harness overhead (charged INTO the shiploop arm): ${ov.sessions} orchestration session(s), ` +
      `${fmtTok(ov.tokens)} tokens, ${fmtUsd(ov.costUsd)}; covered in ${ov.covered} of ${ov.runs} runs, ` +
      `${ov.uncovered} overhead-uncovered.`,
  );
  if (ov.uncovered) {
    L.push(
      `                   An overhead-uncovered run spent governor/scout tokens that are not in the corpus, ` +
        `so this arm's cost is a LOWER bound on what the harness really cost.`,
    );
  }
  L.push(
    `  driver tier: ${out.driverTierAudit.tiers.join(', ') || 'none'} over ${out.driverTierAudit.runs} runs ` +
      `(${out.driverTierAudit.fromStamp} from a driver-model stamp, ` +
      `${out.driverTierAudit.fromOrchestrationTranscript} from an orchestration transcript, ` +
      `${out.driverTierAudit.fromFallbackHighestTier} from the highest-tier FALLBACK).`,
  );
  L.push(
    `  instrumentation: ${out.instrumentation.withEvents} of ${out.instrumentation.runs} runs carry ` +
      `lever-events.jsonl (${out.instrumentation.malformedLines} malformed line(s), ` +
      `${out.instrumentation.unknownEvents} unrecognised event(s) skipped).`,
  );
  if (out.instrumentation.withEvents < out.instrumentation.runs) {
    L.push(
      `                   The emitter ships DEFAULT OFF (GOVERN_LEVER_EVENTS=0), so an uninstrumented`,
    );
    L.push(
      `                   corpus is the expected state, not a fault. The five event-derived levers`,
    );
    L.push(
      `                   above are therefore UNCREDITED here, which understates the harness. They are`,
    );
    L.push(
      `                   not measured zeros and must never be quoted as "this lever saves nothing".`,
    );
  }
  L.push(`  ${out.abortedRuns} run(s) aborted before dispatch (0-byte state.jsonl): excluded from the bench, counted here.`);
  L.push(
    `  ${out.resolvedWithoutTranscript} ticket(s) recorded resolved with no transcript in this corpus ` +
      `(direct-to-main or hand-resolved work the bench cannot see).`,
  );
  L.push('');
  L.push('  levers this bench does NOT measure, and what each would need:');
  for (const u of out.unmeasuredLevers) L.push(`    ${u.lever}: ${u.why}`);
  L.push('  levers absorbed (uncredited, conservative) because both arms already have them:');
  for (const u of out.absorbedLevers) L.push(`    ${u.lever}: ${u.why}`);
  L.push('');

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
