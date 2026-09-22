#!/usr/bin/env node
// bench/rollup.mjs: results.jsonl to the paired-comparison report. Node, zero dependencies.
//
// Usage:
//   node bench/rollup.mjs [results.jsonl] [--json]
//
//   results.jsonl   path to a run's results file. Omitted: the newest run under bench/results/.
//   --json          machine-readable output instead of the report.
//
// The pairing unit is (backlog, rep): a pair exists when both arms recorded a completed cell for
// that backlog and rep. EVERY backlog is analysed — nothing is ranked, nothing is dropped for
// looking bad. A pair is excluded only when the comparison itself would be dishonest: a cell hit
// BENCH_MAX_USD (capped), a cost could not be read (error), or the shiploop cell never actually
// activated a worker (void-no-activation). Exclusion is symmetric — the whole pair drops, never one
// arm — and every excluded pair is listed with its reason.
//
// The STATISTICAL unit is the backlog, not the pair: each backlog folds its own included reps into
// one mean per arm before the relative delta is taken, so a backlog run many times cannot out-vote
// one run only once. Median, CI, Wilcoxon and the dose-response tables all run over these per-backlog
// deltas; n is the count of backlogs that produced one. The pooled-ratio line stays pair-level (a
// straight sum over every included pair), reported as a secondary total, never the headline.
//
// Every number here is computed from total_cost_usd and the token counts in the file. Nothing is
// modeled, extrapolated, or filled in. A metric that cannot be computed prints "n/a" and says why.
import { readFileSync, readdirSync, statSync, existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const BENCH_DIR = dirname(fileURLToPath(import.meta.url));

function die(msg) {
  process.stderr.write(`[rollup] FATAL: ${msg}\n`);
  process.exit(1);
}

// ---- args ------------------------------------------------------------------
const argv = process.argv.slice(2);
const opts = { json: false, file: null };
for (const a of argv) {
  if (a === "--json") opts.json = true;
  else if (a.startsWith("--")) die(`unknown argument: ${a}`);
  else opts.file = a;
}

function newestRunFile() {
  const root = join(BENCH_DIR, "results");
  if (!existsSync(root)) return null;
  const runs = readdirSync(root)
    .map((n) => ({ n, p: join(root, n) }))
    .filter((r) => existsSync(join(r.p, "results.jsonl")))
    .sort((a, b) => statSync(b.p).mtimeMs - statSync(a.p).mtimeMs);
  return runs.length ? join(runs[0].p, "results.jsonl") : null;
}

const file = opts.file ?? newestRunFile();
if (!file) die("no results.jsonl given and none found under bench/results/");
if (!existsSync(file)) die(`no such file: ${file}`);

const rows = readFileSync(file, "utf8")
  .split("\n")
  .filter((l) => l.trim() !== "")
  .map((l, i) => {
    try {
      return JSON.parse(l);
    } catch {
      return die(`${file}:${i + 1} is not valid JSON`);
    }
  });

const rollups = rows.filter((r) => r.kind === "rollup");
if (rollups.length === 0) die(`${file} contains no kind:"rollup" rows`);

// ---- statistics primitives ---------------------------------------------------
// Fixed seed, deterministic mulberry32 PRNG: the same input file always produces the same CI, on
// any machine, forever. Nothing here is a source of nondeterminism that a re-run could disagree on.
const BOOTSTRAP_SEED = 0x9e3779b9;
const BOOTSTRAP_RESAMPLES = 10000;

function mulberry32(seed) {
  let a = seed >>> 0;
  return function () {
    a |= 0;
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function median(xs) {
  const s = [...xs].sort((a, b) => a - b);
  const n = s.length;
  if (n === 0) return null;
  const mid = n >> 1;
  return n % 2 ? s[mid] : (s[mid - 1] + s[mid]) / 2;
}

function mean(xs) {
  return xs.reduce((a, b) => a + b, 0) / xs.length;
}

// 95% bootstrap CI of the median, fixed seed, BOOTSTRAP_RESAMPLES resamples, deterministic output.
// Undefined below n=2 (a single point cannot support a confidence interval); the caller reports n/a.
function bootstrapMedianCI(values) {
  const n = values.length;
  if (n < 2) return null;
  const rng = mulberry32(BOOTSTRAP_SEED);
  const meds = new Array(BOOTSTRAP_RESAMPLES);
  for (let r = 0; r < BOOTSTRAP_RESAMPLES; r++) {
    const sample = new Array(n);
    for (let i = 0; i < n; i++) sample[i] = values[Math.floor(rng() * n)];
    meds[r] = median(sample);
  }
  meds.sort((a, b) => a - b);
  const lo = meds[Math.floor(0.025 * (BOOTSTRAP_RESAMPLES - 1))];
  const hi = meds[Math.floor(0.975 * (BOOTSTRAP_RESAMPLES - 1))];
  return [lo, hi];
}

// Lanczos approximation to ln(Gamma(x)), used for exact binomial coefficients in log-space so the
// sign test never overflows on a large ticket count.
function lgamma(x) {
  const g = 7;
  const c = [
    0.99999999999980993, 676.5203681218851, -1259.1392167224028,
    771.32342877765313, -176.61502916214059, 12.507343278686905,
    -0.13857109526572012, 9.9843695780195716e-6, 1.5056327351493116e-7,
  ];
  if (x < 0.5) return Math.log(Math.PI / Math.sin(Math.PI * x)) - lgamma(1 - x);
  x -= 1;
  let a = c[0];
  const t = x + g + 0.5;
  for (let i = 1; i < g + 2; i++) a += c[i] / (x + i);
  return 0.5 * Math.log(2 * Math.PI) + (x + 0.5) * Math.log(t) - t + Math.log(a);
}

function logChoose(n, k) {
  return lgamma(n + 1) - lgamma(k + 1) - lgamma(n - k + 1);
}

// Exact two-sided sign test: X ~ Binomial(n, 0.5), p = 2 * P(X <= min(better,worse)), capped at 1.
function signTestP(better, worse) {
  const n = better + worse;
  if (n === 0) return null;
  const k = Math.min(better, worse);
  let p = 0;
  for (let i = 0; i <= k; i++) p += Math.exp(logChoose(n, i) - n * Math.log(2));
  return Math.min(1, 2 * p);
}

function erf(x) {
  // Abramowitz & Stegun 7.1.26, max error ~1.5e-7 — plenty for a two-sided p-value at this n.
  const sign = x < 0 ? -1 : 1;
  x = Math.abs(x);
  const a1 = 0.254829592, a2 = -0.284496736, a3 = 1.421413741, a4 = -1.453152027, a5 = 1.061405429, p = 0.3275911;
  const t = 1 / (1 + p * x);
  const y = 1 - (((((a5 * t + a4) * t) + a3) * t + a2) * t + a1) * t * Math.exp(-x * x);
  return sign * y;
}
const normalCdf = (x) => 0.5 * (1 + erf(x / Math.SQRT2));

// Two-sided Wilcoxon signed-rank test over paired differences. Zero differences are dropped first
// (the standard procedure); ties in the remaining absolute values get the average rank. n <= 25
// (post-drop) is exact, via a subset-sum distribution over the (doubled, to stay integer) ranks —
// every one of the 2^n sign assignments is enumerated by convolution, not simulated. Above that,
// a normal approximation with the standard tie-correction term.
function wilcoxonSignedRank(diffs) {
  const nz = diffs.filter((d) => d !== 0);
  const n = nz.length;
  if (n === 0) return null;
  const abs = nz.map(Math.abs);
  const order = abs.map((_, i) => i).sort((a, b) => abs[a] - abs[b]);
  const ranks = new Array(n);
  const tieGroupSizes = [];
  let i = 0;
  while (i < n) {
    let j = i;
    while (j + 1 < n && abs[order[j + 1]] === abs[order[i]]) j++;
    const avgRank = (i + 1 + (j + 1)) / 2; // 1-based
    for (let k = i; k <= j; k++) ranks[order[k]] = avgRank;
    tieGroupSizes.push(j - i + 1);
    i = j + 1;
  }
  let wPlus = 0;
  for (let k = 0; k < n; k++) if (nz[k] > 0) wPlus += ranks[k];

  if (n <= 25) {
    const doubled = ranks.map((r) => Math.round(r * 2));
    let counts = new Map([[0, 1]]);
    for (const r of doubled) {
      const next = new Map();
      for (const [s, c] of counts) {
        next.set(s, (next.get(s) || 0) + c);
        next.set(s + r, (next.get(s + r) || 0) + c);
      }
      counts = next;
    }
    const total = 2 ** n;
    const obs = Math.round(wPlus * 2);
    let le = 0, ge = 0;
    for (const [s, c] of counts) {
      if (s <= obs) le += c;
      if (s >= obs) ge += c;
    }
    const p = Math.min(1, 2 * Math.min(le / total, ge / total));
    return { p, method: "exact", n, wPlus };
  }
  const mean = (n * (n + 1)) / 4;
  const tieCorrection = tieGroupSizes.reduce((a, t) => a + (t ** 3 - t), 0);
  const variance = (n * (n + 1) * (2 * n + 1)) / 24 - tieCorrection / 48;
  const sd = Math.sqrt(variance);
  const cc = wPlus > mean ? -0.5 : wPlus < mean ? 0.5 : 0;
  const z = sd > 0 ? (wPlus - mean + cc) / sd : 0;
  const p = Math.min(1, 2 * (1 - normalCdf(Math.abs(z))));
  return { p, method: "normal-approx", n, wPlus, z };
}

// ---- cells: one rollup row IS one (backlog, arm, rep) cell -----------------
const num = (v) => (typeof v === "number" && Number.isFinite(v) ? v : null);

function cellView(row) {
  if (!row) return null;
  const t = row.tokens || {};
  const billable = (t.input ?? 0) + (t.output ?? 0) + (t.cacheCreation ?? 0);
  const allIn = typeof t.total === "number" ? t.total : billable + (t.cacheRead ?? 0);
  return {
    status: row.status,
    costUsd: num(row.costUsdTotal ?? row.costUsd),
    tokensAllIn: allIn,
    tokensBillable: billable,
    tokensOutput: t.output ?? 0,
    tokensCacheRead: t.cacheRead ?? 0,
    freshInput: (t.input ?? 0) + (t.cacheCreation ?? 0),
    turns: num(row.turns) ?? 0,
    workerSpawns: num(row.workerSpawns) ?? 0,
    models: Array.isArray(row.models) ? row.models : row.model ? [row.model] : [],
    perTicket: Array.isArray(row.perTicket) ? row.perTicket : [],
    ticketsTotal: num(row.ticketsTotal) ?? 0,
    hubSha: row.hubSha ?? null,
  };
}

const cells = new Map();
for (const r of rollups) cells.set(`${r.backlog}|${r.arm}|${r.rep}`, r);
const backlogNames = [...new Set(rollups.map((r) => r.backlog))].sort();
const repNumbers = [...new Set(rollups.map((r) => r.rep))].sort((a, b) => a - b);

// ---- pairing ----------------------------------------------------------------
const pairs = [];
const excluded = [];
for (const backlog of backlogNames) {
  for (const rep of repNumbers) {
    const vRow = cells.get(`${backlog}|vanilla|${rep}`);
    const sRow = cells.get(`${backlog}|shiploop|${rep}`);
    if (!vRow && !sRow) continue; // this (backlog, rep) cell was never dispatched
    if (!vRow || !sRow) {
      excluded.push({ backlog, rep, reason: `error: no ${vRow ? "shiploop" : "vanilla"} cell recorded` });
      continue;
    }
    const v = cellView(vRow), s = cellView(sRow);
    if (v.status === "capped" || s.status === "capped") {
      excluded.push({ backlog, rep, reason: "capped" });
      continue;
    }
    if (s.status === "void-no-activation") {
      excluded.push({ backlog, rep, reason: "void-no-activation" });
      continue;
    }
    if (v.status === "no-tickets" || s.status === "no-tickets") {
      excluded.push({ backlog, rep, reason: "error: zero-ticket backlog" });
      continue;
    }
    if (typeof v.costUsd !== "number" || typeof s.costUsd !== "number") {
      excluded.push({ backlog, rep, reason: "error: no readable cost" });
      continue;
    }
    pairs.push({ backlog, rep, vanilla: v, shiploop: s, tickets: v.ticketsTotal || s.ticketsTotal });
  }
}

// ---- backlog grouping: the statistical unit is the backlog, not the (backlog, rep) pair --------
// Each backlog contributes ONE observation per metric: the mean of that metric's values over the
// backlog's own included reps. A backlog with a single included rep still counts (its mean is that
// one value, unchanged from a per-pair reading); a backlog with more reps is not allowed to out-vote
// one run only once just because it ran more times.
const backlogGroups = new Map(); // backlog -> its included pairs
for (const p of pairs) {
  if (!backlogGroups.has(p.backlog)) backlogGroups.set(p.backlog, []);
  backlogGroups.get(p.backlog).push(p);
}

function repsPerBacklogLabel() {
  const counts = [...backlogGroups.values()].map((ps) => ps.length);
  if (!counts.length) return "0";
  const lo = Math.min(...counts), hi = Math.max(...counts);
  return lo === hi ? String(lo) : `${lo}-${hi}`;
}

// ---- metrics ------------------------------------------------------------------
const METRICS = [
  { key: "cost", label: "cost (USD)", primary: true, unit: "$", get: (c) => c.costUsd },
  { key: "tokensAllIn", label: "all-in tokens", get: (c) => c.tokensAllIn },
  { key: "tokensBillable", label: "billable tokens", get: (c) => c.tokensBillable },
  { key: "tokensOutput", label: "output tokens", get: (c) => c.tokensOutput },
  { key: "tokensCacheRead", label: "cache-read tokens", get: (c) => c.tokensCacheRead },
  { key: "freshInput", label: "fresh input (input + cache creation)", get: (c) => c.freshInput },
  { key: "turns", label: "turns", get: (c) => c.turns },
];

// Per-backlog relative delta is (mean_shiploop - mean_vanilla) / mean_vanilla, the mean taken over
// that backlog's own included reps. A positive delta means shiploop cost MORE, printed as such —
// never dressed up as a saving. A backlog whose mean vanilla value is exactly zero cannot form a
// ratio and is skipped for THAT metric only. n is the count of backlogs that produced a delta;
// median/CI/Wilcoxon run over these BACKLOG-level deltas. The pooled ratio and totals stay a
// secondary line computed over every included PAIR (not backlog-averaged), same as before.
function metricStats(metric) {
  const deltas = [];
  let vTotal = 0, sTotal = 0, totalsN = 0;
  for (const [, ps] of backlogGroups) {
    const vVals = [], sVals = [];
    for (const p of ps) {
      const v = metric.get(p.vanilla), s = metric.get(p.shiploop);
      if (typeof v !== "number" || typeof s !== "number") continue;
      vVals.push(v); sVals.push(s);
      vTotal += v; sTotal += s; totalsN++;
    }
    if (vVals.length === 0) continue;
    const meanV = mean(vVals), meanS = mean(sVals);
    if (meanV === 0) continue;
    deltas.push((meanS - meanV) / meanV);
  }
  const n = deltas.length;
  const med = n ? median(deltas) : null;
  const ci = n ? bootstrapMedianCI(deltas) : null;
  const wil = n ? wilcoxonSignedRank(deltas) : null;
  return {
    metric: metric.key,
    n,
    medianDeltaPct: med === null ? null : med * 100,
    ci95Pct: ci === null ? null : [ci[0] * 100, ci[1] * 100],
    wilcoxonP: wil ? wil.p : null,
    wilcoxonMethod: wil ? wil.method : null,
    pooledRatio: totalsN && vTotal !== 0 ? sTotal / vTotal : null,
    vanillaTotal: totalsN ? vTotal : null,
    shiploopTotal: totalsN ? sTotal : null,
    totalsN,
  };
}

const metricResults = METRICS.map((m) => ({ ...m, stats: metricStats(m) }));
const costResult = metricResults.find((m) => m.key === "cost");

// ---- quality: per-ticket cleared comparison, majority vote within each backlog's reps ----------
// Per ticket, PER BACKLOG: an arm cleared it only if it cleared in a STRICT majority of that
// backlog's included reps (cleared count > half the reps) — a tie (e.g. 1 of 2) is NOT cleared.
// This collapses each (backlog, ticket) to one verdict per arm before comparing, so a backlog run
// many times cannot out-vote one run only once.
function qualityStats() {
  let better = 0, worse = 0, same = 0, ticketsCompared = 0, vCleared = 0, sCleared = 0;
  const bump = (map, id, cleared) => {
    const c = map.get(id) || { cleared: 0, total: 0 };
    c.total++;
    if (cleared) c.cleared++;
    map.set(id, c);
  };
  for (const [, ps] of backlogGroups) {
    const vCounts = new Map(), sCounts = new Map();
    for (const p of ps) {
      for (const t of p.vanilla.perTicket) bump(vCounts, t.id ?? t.ticket, !!t.cleared);
      for (const t of p.shiploop.perTicket) bump(sCounts, t.id ?? t.ticket, !!t.cleared);
    }
    const ids = new Set([...vCounts.keys(), ...sCounts.keys()]);
    for (const id of ids) {
      if (!vCounts.has(id) || !sCounts.has(id)) continue; // can't compare a ticket missing from either ledger
      const v = vCounts.get(id), s = sCounts.get(id);
      const vC = v.cleared > v.total / 2, sC = s.cleared > s.total / 2;
      ticketsCompared++;
      if (vC) vCleared++;
      if (sC) sCleared++;
      if (sC && !vC) better++;
      else if (vC && !sC) worse++;
      else same++;
    }
  }
  return {
    ticketsCompared,
    vanillaClearRatePct: ticketsCompared ? (100 * vCleared) / ticketsCompared : null,
    shiploopClearRatePct: ticketsCompared ? (100 * sCleared) / ticketsCompared : null,
    better, worse, same,
    signTestP: ticketsCompared ? signTestP(better, worse) : null,
  };
}
const quality = qualityStats();

// ---- dose response: cost delta bucketed by spawn count / ticket count, descriptive only -----
// One observation per BACKLOG (its own cost delta, mean-of-included-reps, same as metricStats),
// bucketed by round(mean shiploop worker-spawn count over that backlog's reps) or by the backlog's
// own ticket count.
function doseTable(keyFn) {
  const buckets = new Map();
  for (const [, ps] of backlogGroups) {
    const vVals = ps.map((p) => p.vanilla.costUsd).filter((v) => typeof v === "number");
    const sVals = ps.map((p) => p.shiploop.costUsd).filter((v) => typeof v === "number");
    if (vVals.length === 0 || sVals.length === 0) continue;
    const meanV = mean(vVals), meanS = mean(sVals);
    if (meanV === 0) continue;
    const spawnsMean = mean(ps.map((p) => p.shiploop.workerSpawns));
    const k = keyFn({ spawnsMean, tickets: ps[0].tickets });
    if (!buckets.has(k)) buckets.set(k, []);
    buckets.get(k).push((meanS - meanV) / meanV);
  }
  return [...buckets.entries()]
    .sort((a, b) => a[0] - b[0])
    .map(([bucket, deltas]) => ({ bucket, n: deltas.length, medianDeltaPct: median(deltas) * 100 }));
}
const doseBySpawns = doseTable(({ spawnsMean }) => Math.round(spawnsMean));
const doseByTickets = doseTable(({ tickets }) => tickets);

// ---- headline: exactly one sentence, always cost, direction-neutral ----------
function modelsFor(arm) {
  const s = new Set();
  for (const r of rollups) if (r.arm === arm) for (const m of Array.isArray(r.models) ? r.models : r.model ? [r.model] : []) s.add(m);
  return [...s].sort();
}

function headline() {
  const c = costResult.stats;
  if (c.n === 0 || c.medianDeltaPct === null) return null;
  const f1 = (n) => (n >= 0 ? "+" : "") + n.toFixed(1);
  const ciStr = c.ci95Pct ? `${f1(c.ci95Pct[0])}%..${f1(c.ci95Pct[1])}%` : "n/a (n<2)";
  const pStr = c.wilcoxonP === null ? "n/a" : c.wilcoxonP < 0.001 ? "<0.001" : c.wilcoxonP.toFixed(3);
  const vanillaModels = modelsFor("vanilla").join("+") || "unknown";
  const shiploopModels = modelsFor("shiploop").join("+") || "unknown";
  return (
    `Median paired cost change: ${f1(c.medianDeltaPct)}% (95% CI ${ciStr}, Wilcoxon p=${pStr}, ` +
    `n=${c.n} backlogs, reps per backlog ${repsPerBacklogLabel()}; ` +
    `vanilla models ${vanillaModels}, shiploop models ${shiploopModels}).`
  );
}
const head = headline();

// ---- output ------------------------------------------------------------------
if (opts.json) {
  const payload = {
    file,
    pairs: pairs.map((p) => ({ backlog: p.backlog, rep: p.rep, tickets: p.tickets })),
    excluded,
    metrics: metricResults.map((m) => ({ key: m.key, label: m.label, primary: !!m.primary, ...m.stats })),
    quality,
    doseResponse: { byWorkerSpawns: doseBySpawns, byTicketCount: doseByTickets },
    headline: head,
  };
  process.stdout.write(JSON.stringify(payload, null, 2) + "\n");
  process.exit(0);
}

const f1 = (n) => (typeof n === "number" && Number.isFinite(n) ? (n >= 0 ? "+" : "") + n.toFixed(1) : "n/a");
const f2 = (n) => (typeof n === "number" && Number.isFinite(n) ? n.toFixed(2) : "n/a");
// Plain: no leading "+" — for rates, never for a delta. A delta keeps its sign (f1); a rate is
// never "negative", so a "+" in front of it would read as a delta it is not.
const fPlain = (n) => (typeof n === "number" && Number.isFinite(n) ? n.toFixed(1) : "n/a");
const out = (s) => process.stdout.write(s + "\n");

out(`bench rollup: ${file}`);
out("");

out("Pairs");
out(`  ${pairs.length} included, over ${new Set(pairs.map((p) => p.backlog)).size} backlog(s) x ${repNumbers.length} rep(s)`);
for (const e of excluded) out(`  excluded ${e.backlog} rep ${e.rep}: ${e.reason}`);
if (!excluded.length) out("  no exclusions");
out("");

out("Metrics (per-pair relative delta, (shiploop - vanilla) / vanilla)");
for (const m of metricResults) {
  const s = m.stats;
  out(`  ${m.label}${m.primary ? " [PRIMARY]" : ""}`);
  if (s.n === 0) {
    out(`    n/a: no pair had both arms' values readable for this metric`);
    out("");
    continue;
  }
  out(`    n=${s.n} backlogs`);
  out(`    median delta   ${f1(s.medianDeltaPct)}%`);
  out(`    95% CI         ${s.ci95Pct ? `${f1(s.ci95Pct[0])}% .. ${f1(s.ci95Pct[1])}%` : "n/a (n<2)"}`);
  const wilcoxonPStr = s.wilcoxonP === null ? "n/a (every pair tied at zero delta)" : s.wilcoxonP < 0.001 ? "<0.001" : s.wilcoxonP.toFixed(3);
  out(`    Wilcoxon p     ${wilcoxonPStr}${s.wilcoxonMethod ? ` (${s.wilcoxonMethod})` : ""}`);
  out(`    pooled totals  ${m.unit === "$" ? `$${f2(s.vanillaTotal)} -> $${f2(s.shiploopTotal)}` : `${s.vanillaTotal} -> ${s.shiploopTotal}`}, ratio ${s.pooledRatio === null ? "n/a" : s.pooledRatio.toFixed(3) + "x"}`);
  out("");
}

out("Quality (per-ticket, within included pairs only)");
if (quality.ticketsCompared === 0) {
  out("  n/a: no ticket was comparable across both arms' ledgers");
} else {
  out(`  tickets compared   ${quality.ticketsCompared}`);
  out(`  vanilla clear rate  ${fPlain(quality.vanillaClearRatePct)}%`);
  out(`  shiploop clear rate ${fPlain(quality.shiploopClearRatePct)}%`);
  out(`  better ${quality.better}  worse ${quality.worse}  same ${quality.same}`);
  out(`  sign test p        ${quality.signTestP === null ? "n/a" : quality.signTestP < 0.001 ? "<0.001" : quality.signTestP.toFixed(3)}`);
}
out("");

out("Activation");
const voidPairs = excluded.filter((e) => e.reason === "void-no-activation");
out(voidPairs.length
  ? `  ${voidPairs.length} pair(s) excluded for void-no-activation: ${voidPairs.map((e) => `${e.backlog} rep ${e.rep}`).join(", ")}`
  : "  no shiploop cell was excluded for zero worker-spawn activation");
out("");

out("Dose response (descriptive only, no test)");
out("  by shiploop worker-spawn count");
if (doseBySpawns.length) {
  for (const b of doseBySpawns) out(`    spawns=${b.bucket}  n=${b.n}  median cost delta ${f1(b.medianDeltaPct)}%`);
} else {
  out("    n/a: no pair had a readable cost");
}
out("  by backlog ticket count");
if (doseByTickets.length) {
  for (const b of doseByTickets) out(`    tickets=${b.bucket}  n=${b.n}  median cost delta ${f1(b.medianDeltaPct)}%`);
} else {
  out("    n/a: no pair had a readable cost");
}
out("");

out("Headline");
out(head ? `  ${head}` : "  n/a: no cost pair to compute a headline from");
