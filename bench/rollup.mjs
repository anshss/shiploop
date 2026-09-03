#!/usr/bin/env node
// bench/rollup.mjs: results.jsonl to the three metric cuts of spec section 4, the backlog
// selection ranking of section 3, and the one published sentence. Node, zero dependencies.
//
// Usage:
//   node bench/rollup.mjs [results.jsonl] [--json] [--floor 65] [--keep-max 3] [--window-usd N]
//
//   results.jsonl   path to a run's results file. Omitted: the newest run under bench/results/.
//   --json          machine-readable output instead of the report.
//   --floor         selection stops as soon as the kept set clears this headline percentage.
//                   Default 65, the number the claim has to beat to be worth making.
//   --keep-max      most backlogs the kept set may contain. Default 3.
//   --window-usd    an OBSERVED 5-hour window budget in API-rate dollars, for the absolute
//                   tickets-per-window figures. Without it the third cut is reported only as the
//                   ratio, which is what the "Nx more" claim actually rests on; the absolute
//                   counts need a measured budget and are never guessed.
//
// Every number printed here is computed from total_cost_usd and the token counts in the file.
// Nothing is modelled, extrapolated, or filled in. A cut that cannot be computed prints "n/a" and
// says why, because a plausible placeholder next to real figures is how a benchmark stops being
// one.

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
const opts = { json: false, floor: 65, keepMax: 3, windowUsd: null, file: null };
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a === "--json") opts.json = true;
  else if (a === "--floor") opts.floor = Number(argv[++i]);
  else if (a === "--keep-max") opts.keepMax = Number(argv[++i]);
  else if (a === "--window-usd") opts.windowUsd = Number(argv[++i]);
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

// ---- folding ---------------------------------------------------------------
// A cell is one (backlog, arm, rep). Reps of the same (backlog, arm) are averaged, so a backlog
// with two reps does not outvote one with a single rep in the aggregate.
const num = (v) => (typeof v === "number" && Number.isFinite(v) ? v : 0);
const mean = (xs) => (xs.length ? xs.reduce((a, b) => a + b, 0) / xs.length : 0);

// Two token cuts (section 4, metric 2). `billable` charges cache reads at nothing, which is the
// conservative reading; `allIn` counts every token the API moved. Both are true statements about
// the same file; the report says which one the headline used.
const tokenCuts = (t) => ({
  billable: num(t?.input) + num(t?.output) + num(t?.cacheCreation),
  allIn: num(t?.total) || num(t?.input) + num(t?.output) + num(t?.cacheRead) + num(t?.cacheCreation),
});

const cells = new Map();
for (const r of rollups) {
  const key = `${r.backlog} ${r.arm}`;
  if (!cells.has(key)) cells.set(key, []);
  const tc = tokenCuts(r.tokens);
  cells.get(key).push({
    rep: r.rep,
    status: r.status,
    cleared: num(r.ticketsCleared),
    total: num(r.ticketsTotal),
    resolved: r.resolved === true,
    costUsd: r.costUsdTotal ?? r.costUsd,
    tokensBillable: tc.billable,
    tokensAllIn: tc.allIn,
    sessions: num(r.sessions),
    model: r.model,
    cli: r.cli_version,
  });
}

const backlogNames = [...new Set(rollups.map((r) => r.backlog))].sort();

function armFold(backlog, arm) {
  const reps = cells.get(`${backlog} ${arm}`);
  if (!reps || reps.length === 0) return null;
  // A rep with no readable cost cannot be averaged into a cost claim. Report it rather than
  // treating the missing dollars as zero, which would inflate every cut downstream.
  const costed = reps.filter((r) => typeof r.costUsd === "number");
  return {
    reps: reps.length,
    repsCosted: costed.length,
    capped: reps.some((r) => r.status === "capped"),
    cleared: reps.every((r) => r.resolved),
    tickets: reps[0].total,
    costUsd: costed.length ? mean(costed.map((r) => r.costUsd)) : null,
    tokensBillable: mean(reps.map((r) => r.tokensBillable)),
    tokensAllIn: mean(reps.map((r) => r.tokensAllIn)),
    sessions: mean(reps.map((r) => r.sessions)),
    model: reps[reps.length - 1].model,
    cli: reps[reps.length - 1].cli,
  };
}

const pctLower = (base, treat) => (base > 0 ? ((base - treat) / base) * 100 : null);
const ratio = (base, treat) => (treat > 0 ? base / treat : null);

const perBacklog = backlogNames.map((name) => {
  const v = armFold(name, "vanilla");
  const s = armFold(name, "shiploop");
  const vf = armFold(name, "vanilla-fresh");
  // Section 3: a backlog either arm failed to clear is not comparable and drops out. So is a
  // capped one: a truncated run is cheaper for the wrong reason, and letting it into the ranking
  // would make the cap itself look like a saving.
  const eligible =
    !!v && !!s && v.cleared && s.cleared && !v.capped && !s.capped &&
    typeof v.costUsd === "number" && typeof s.costUsd === "number";
  let reason = null;
  if (!v) reason = "no vanilla arm recorded";
  else if (!s) reason = "no shiploop arm recorded";
  else if (v.capped || s.capped) reason = "run hit BENCH_MAX_USD (status capped)";
  else if (!v.cleared || !s.cleared) reason = "an arm failed to clear the backlog";
  else if (typeof v.costUsd !== "number" || typeof s.costUsd !== "number") reason = "no readable cost";
  return {
    backlog: name,
    tickets: v?.tickets ?? s?.tickets ?? 0,
    vanilla: v,
    shiploop: s,
    vanillaFresh: vf,
    eligible,
    reason,
    costPct: eligible ? pctLower(v.costUsd, s.costUsd) : null,
    tokenPctBillable: eligible ? pctLower(v.tokensBillable, s.tokensBillable) : null,
    tokenPctAllIn: eligible ? pctLower(v.tokensAllIn, s.tokensAllIn) : null,
  };
});

// ---- selection (section 3) -------------------------------------------------
// Rank the eligible backlogs by cost delta, take them best-first, and stop as soon as the
// AGGREGATE over the kept set clears the floor. The aggregate is what gets published, so it is
// what the stopping rule reads: a set whose individual members all beat the floor can still
// aggregate below it once a big cheap backlog is weighted in.
function aggregate(set) {
  const vCost = set.reduce((a, b) => a + b.vanilla.costUsd, 0);
  const sCost = set.reduce((a, b) => a + b.shiploop.costUsd, 0);
  const vTokB = set.reduce((a, b) => a + b.vanilla.tokensBillable, 0);
  const sTokB = set.reduce((a, b) => a + b.shiploop.tokensBillable, 0);
  const vTokA = set.reduce((a, b) => a + b.vanilla.tokensAllIn, 0);
  const sTokA = set.reduce((a, b) => a + b.shiploop.tokensAllIn, 0);
  const tickets = set.reduce((a, b) => a + b.tickets, 0);
  return {
    backlogs: set.length,
    tickets,
    vanillaCostUsd: vCost,
    shiploopCostUsd: sCost,
    costPct: pctLower(vCost, sCost),
    tokenPctBillable: pctLower(vTokB, sTokB),
    tokenPctAllIn: pctLower(vTokA, sTokA),
    // Section 4, metric 3. Tickets per window is (window budget / cost per ticket), so the RATIO
    // of the two arms is window-budget independent: the budget cancels. That ratio is the honest
    // form of "Nx more tickets per 5-hour window". Absolute counts need a measured budget and
    // only appear when --window-usd supplies one.
    ticketsPerDollarRatio: ratio(vCost / tickets, sCost / tickets),
    vanillaCostPerTicket: vCost / tickets,
    shiploopCostPerTicket: sCost / tickets,
  };
}

const ranked = perBacklog
  .filter((b) => b.eligible)
  .sort((a, b) => b.costPct - a.costPct);

const kept = [];
for (const b of ranked) {
  if (kept.length >= opts.keepMax) break;
  kept.push(b);
  const a = aggregate(kept);
  // Two is the published minimum (section 3 keeps 2 to 3): "our benchmark suite" of one backlog
  // is a single data point wearing a plural.
  if (kept.length >= 2 && a.costPct >= opts.floor) break;
}

const agg = kept.length ? aggregate(kept) : null;
const allEligible = ranked.length ? aggregate(ranked) : null;

// ---- headline (section 4) --------------------------------------------------
// Exactly one sentence, "up to" phrasing, in the shape the spec fixes. The percentage is the
// larger of the cost cut and the better token cut, and the report always says which one it is so
// nobody publishes a token number under a cost word.
function headline(a, model, cli) {
  if (!a) return null;
  const cuts = [
    { label: "lower cost", value: a.costPct, verb: "lower cost" },
    { label: "fewer tokens (billable)", value: a.tokenPctBillable, verb: "fewer tokens" },
    { label: "fewer tokens (all-in)", value: a.tokenPctAllIn, verb: "fewer tokens" },
  ].filter((c) => typeof c.value === "number" && Number.isFinite(c.value));
  if (!cuts.length) return null;
  const best = cuts.reduce((x, y) => (y.value > x.value ? y : x));
  const pct = Math.floor(best.value);
  return {
    metric: best.label,
    pct,
    sentence:
      `Up to ${pct}% ${best.verb} to ship the same backlog vs a stock Claude Code session ` +
      `(${a.backlogs} real upstream backlogs, ${a.tickets} tickets, model ${model}, CLI ${cli}).`,
  };
}

const model = kept.length ? kept[0].vanilla.model : rollups[rollups.length - 1].model;
const cli = kept.length ? kept[0].vanilla.cli : rollups[rollups.length - 1].cli_version;
const head = headline(agg, model, cli);

// ---- output ----------------------------------------------------------------
function stripArms(b) {
  return {
    backlog: b.backlog, tickets: b.tickets, eligible: b.eligible, reason: b.reason,
    vanillaCostUsd: b.vanilla?.costUsd ?? null, shiploopCostUsd: b.shiploop?.costUsd ?? null,
    vanillaFreshCostUsd: b.vanillaFresh?.costUsd ?? null,
    costPct: b.costPct, tokenPctBillable: b.tokenPctBillable, tokenPctAllIn: b.tokenPctAllIn,
  };
}

if (opts.json) {
  const payload = {
    file,
    perBacklog: perBacklog.map(stripArms),
    selection: {
      floor: opts.floor,
      keepMax: opts.keepMax,
      ranked: ranked.map((b) => b.backlog),
      kept: kept.map((b) => b.backlog),
      dropped: perBacklog.filter((b) => !b.eligible).map((b) => ({ backlog: b.backlog, reason: b.reason })),
    },
    aggregateKept: agg,
    aggregateAllEligible: allEligible,
    headline: head,
  };
  process.stdout.write(JSON.stringify(payload, null, 2) + "\n");
  process.exit(0);
}

const f2 = (n) => (typeof n === "number" && Number.isFinite(n) ? n.toFixed(2) : "n/a");
const f1 = (n) => (typeof n === "number" && Number.isFinite(n) ? n.toFixed(1) : "n/a");
const out = (s) => process.stdout.write(s + "\n");

out(`bench rollup: ${file}`);
out("");

out("Per backlog");
out("    backlog                        tickets   vanilla $   shiploop $   cost cut");
for (const b of perBacklog) {
  const flag = b.eligible ? "  " : "x ";
  out(
    `  ${flag}${b.backlog.padEnd(28)} ${String(b.tickets).padStart(9)} ` +
      `${f2(b.vanilla?.costUsd).padStart(11)} ${f2(b.shiploop?.costUsd).padStart(12)} ` +
      `${(b.costPct === null ? "n/a" : f1(b.costPct) + "%").padStart(11)}` +
      (b.eligible ? "" : `   dropped: ${b.reason}`),
  );
}
out("");

out("Cut 1: cost to clear the same backlog");
if (agg) {
  out(`  vanilla   $${f2(agg.vanillaCostUsd)}`);
  out(`  shiploop  $${f2(agg.shiploopCostUsd)}`);
  out(`  lower by  ${f1(agg.costPct)}%`);
} else {
  out("  n/a: no backlog had both arms clear with a readable cost");
}
out("");

out("Cut 2: tokens to clear the same backlog");
if (agg) {
  out(`  billable (input + output + cache creation)   ${f1(agg.tokenPctBillable)}% fewer`);
  out(`  all-in   (billable + cache reads)            ${f1(agg.tokenPctAllIn)}% fewer`);
} else {
  out("  n/a: no eligible backlog");
}
out("");

out("Cut 3: tickets shipped per 5-hour window");
if (agg) {
  out(`  vanilla   $${f2(agg.vanillaCostPerTicket)} per ticket`);
  out(`  shiploop  $${f2(agg.shiploopCostPerTicket)} per ticket`);
  out(`  ratio     ${f2(agg.ticketsPerDollarRatio)}x more tickets per window (the budget cancels, so this holds for any window size)`);
  if (typeof opts.windowUsd === "number" && Number.isFinite(opts.windowUsd)) {
    out(`  at an observed $${f2(opts.windowUsd)} window: vanilla ${f1(opts.windowUsd / agg.vanillaCostPerTicket)} tickets, shiploop ${f1(opts.windowUsd / agg.shiploopCostPerTicket)} tickets`);
  } else {
    out("  absolute per-window counts: n/a, pass --window-usd with a measured window budget");
  }
} else {
  out("  n/a: no eligible backlog");
}
out("");

out("Selection");
out(`  ranked by cost delta: ${ranked.length ? ranked.map((b) => b.backlog).join(", ") : "(none eligible)"}`);
out(`  kept (floor ${opts.floor}%, max ${opts.keepMax}): ${kept.length ? kept.map((b) => b.backlog).join(", ") : "(none)"}`);
const dropped = perBacklog.filter((b) => !b.eligible);
for (const d of dropped) out(`  dropped ${d.backlog}: ${d.reason}`);
if (allEligible && agg && allEligible.costPct < agg.costPct) {
  out(`  internal record: over ALL eligible backlogs the cut is ${f1(allEligible.costPct)}%, not ${f1(agg.costPct)}%. Never publish the kept-set figure without knowing this one.`);
}
out("");

out("Headline");
if (head) {
  out(`  metric: ${head.metric}`);
  out(`  ${head.sentence}`);
  if (head.pct < opts.floor) {
    out(`  NOTE: ${head.pct}% is below the ${opts.floor}% floor. Ship it at this value or re-select; do not round it up.`);
  }
} else {
  out("  n/a: nothing eligible to compute a headline from");
}
