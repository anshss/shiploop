#!/usr/bin/env node
// bench/gen-proof-table.mjs: regenerate bench/results/proof-table.txt from the committed rows.
//
// Deterministic and fully offline: reads ONLY bench/published-rows/replay-*.jsonl (1,821 rows
// committed to this repo), does no network, no `claude` process, no fleet transcripts. Same
// inputs always produce the same bytes, which is the whole point: a drift test
// (templates/govern/test/test-bench-proof-table.sh) runs this and diffs it against the committed
// bench/results/proof-table.txt so the published table and the published data can never silently
// diverge, the failure mode headroom (index_proof_table.txt) is built to prevent and caveman/RTK
// do not (bench/README.md, "Ship proof, because the category does").
//
// Two things this file prints CANNOT come from the rows themselves, by design: the rows are
// privacy-stripped (bench/replay.mjs `--rows`, run/fleet identifiers hashed, no CLI version, no
// model, no workspace name, no wall-clock date survive the strip). Those four facts (workspace
// count, CLI version span, model span, calendar date span) are carried here as constants sourced
// from the same 2026-09-05 measurement documented in bench/README.md ("The best-case number, on
// the author's corpus"). If the corpus is ever refreshed, update PROVENANCE below in the same
// commit as the new published-rows file, or this table will (correctly) go stale-but-consistent
// rather than silently wrong.
//
// Usage: node bench/gen-proof-table.mjs [path/to/replay-YYYY-MM-DD.jsonl]
// Prints the table to stdout. `bench/results/proof-table.txt` is that output, committed verbatim.

import fs from 'node:fs';
import path from 'node:path';
import url from 'node:url';

const HERE = path.dirname(url.fileURLToPath(import.meta.url));
const DEFAULT_ROWS = path.join(HERE, 'published-rows', 'replay-2026-09-05.jsonl');
const rowsPath = process.argv[2] || DEFAULT_ROWS;

// Not recomputable from the anonymized rows (see header note): sourced from bench/README.md's
// "The best-case number, on the author's corpus" section, same measurement date as DEFAULT_ROWS.
const PROVENANCE = {
  workspaces: 7,
  cliVersionSpan: '2.1.126-2.1.246',
  modelSpan: 'haiku-4.5, opus-4.7, opus-4.8, opus-5, sonnet-5',
  dateSpan: '2026-06-12 to 2026-09-04',
};

const ARMS = ['200k', '1m', 'uncapped'];
const MIN_POSITION_N = 10; // below this a median is one or two rows wide; not reported.

function fail(msg) {
  process.stderr.write(`gen-proof-table: ${msg}\n`);
  process.exit(1);
}

function readRows(p) {
  let text;
  try {
    text = fs.readFileSync(p, 'utf8');
  } catch (e) {
    fail(`cannot read ${p}: ${e.message}`);
  }
  return text
    .trim()
    .split('\n')
    .filter(Boolean)
    .map((line, i) => {
      try {
        return JSON.parse(line);
      } catch (e) {
        fail(`${p}:${i + 1}: invalid JSON row (${e.message})`);
      }
    });
}

function sourceDate(p) {
  const m = path.basename(p).match(/replay-(\d{4}-\d{2}-\d{2})\.jsonl$/);
  return m ? m[1] : '(unknown: file does not match replay-YYYY-MM-DD.jsonl)';
}

function median(nums) {
  if (nums.length === 0) return null;
  const s = [...nums].sort((a, b) => a - b);
  const mid = Math.floor(s.length / 2);
  return s.length % 2 ? s[mid] : (s[mid - 1] + s[mid]) / 2;
}

function commas(n) {
  const neg = n < 0;
  const s = Math.trunc(Math.abs(n)).toString();
  const grouped = s.replace(/\B(?=(\d{3})+(?!\d))/g, ',');
  return neg ? `-${grouped}` : grouped;
}

function usd(n) {
  const neg = n < 0;
  const abs = Math.abs(n);
  const fixed = abs.toFixed(2);
  const [whole, frac] = fixed.split('.');
  const grouped = whole.replace(/\B(?=(\d{3})+(?!\d))/g, ',');
  return `${neg ? '-' : ''}$${grouped}.${frac}`;
}

function pct1(n) {
  return `${n.toFixed(1)}%`;
}

function pad(s, w) {
  s = String(s);
  return s + ' '.repeat(Math.max(0, w - s.length));
}
function padLeft(s, w) {
  s = String(s);
  return ' '.repeat(Math.max(0, w - s.length)) + s;
}

function main() {
  const rows = readRows(rowsPath);
  for (const arm of ARMS) {
    if (!rows.some((r) => r.arm === arm)) fail(`no rows for arm ${arm} in ${rowsPath}`);
  }

  const byArm = {};
  for (const arm of ARMS) {
    const rs = rows.filter((r) => r.arm === arm);
    const shipTokens = rs.reduce((a, r) => a + r.shipTokens, 0);
    const vanillaTokens = rs.reduce((a, r) => a + r.vanillaTokens, 0);
    const shipCostUsd = rs.reduce((a, r) => a + r.shipCostUsd, 0);
    const vanillaCostUsd = rs.reduce((a, r) => a + r.vanillaCostUsd, 0);
    byArm[arm] = {
      ticketRows: rs.length,
      shipTokens,
      vanillaTokens,
      tokenReductionPct: ((vanillaTokens - shipTokens) / vanillaTokens) * 100,
      shipCostUsd,
      vanillaCostUsd,
      costReductionPct: ((vanillaCostUsd - shipCostUsd) / vanillaCostUsd) * 100,
    };
  }

  const runCount = new Set(rows.filter((r) => r.arm === ARMS[0]).map((r) => r.run)).size;
  const ticketCount = byArm[ARMS[0]].ticketRows;

  // Per-ticket-position curve: 1m arm, pooled across the corpus, counted rows only, median token
  // reduction %. Depth-dependence is the whole point: position 1 is a fresh session against a
  // fresh session, so it saves ~0% BY CONSTRUCTION, not by any failure of the harness.
  const arm1m = rows.filter((r) => r.arm === '1m' && r.counted);
  const byPos = {};
  for (const r of arm1m) (byPos[r.position] = byPos[r.position] || []).push(r);
  const positions = Object.keys(byPos)
    .map(Number)
    .sort((a, b) => a - b)
    .filter((p) => byPos[p].length >= MIN_POSITION_N);

  const lines = [];
  const gen = sourceDate(rowsPath);
  // Print the path relative to this script's own directory (bench/), never process.cwd(); the
  // drift test invokes this from an arbitrary working directory and the output must be byte-
  // identical regardless of where it was run from.
  lines.push(
    `shiploop proof table, generated ${gen}, source: bench/published-rows/${path.basename(rowsPath)}`,
  );
  lines.push(
    `corpus: ${runCount} runs, ${ticketCount} tickets, ${PROVENANCE.workspaces} workspaces (workspace count is provenance metadata, not derivable from the anonymized rows below)`,
  );
  lines.push(
    `cli ${PROVENANCE.cliVersionSpan} | models ${PROVENANCE.modelSpan} | dates ${PROVENANCE.dateSpan}`,
  );
  lines.push('');
  lines.push(
    'shiploop side = MEASURED billed usage (real transcripts). vanilla side = MODELED counterfactual',
  );
  lines.push(
    '(no vanilla session was run for this table). See bench/METHODOLOGY.md for the model and every',
  );
  lines.push('assumption; bench/KNOWN-LIMITS.md for where this does not hold.');
  lines.push('');
  lines.push(
    'ALL THREE arms, always together (the unflattering one is never shown without the others):',
  );
  lines.push('');

  const armLabel = { '200k': '200k (CLI default, compaction)', '1m': '1m (1M context)', uncapped: 'uncapped (unphysical ceiling)' };
  const headers = ['arm', 'ship tokens [MEASURED]', 'vanilla tokens [MODELED]', 'tokens saved', 'ship cost [MEASURED]', 'vanilla cost [MODELED]', 'cost saved'];
  const rowsOut = ARMS.map((arm) => {
    const a = byArm[arm];
    return [
      armLabel[arm],
      commas(a.shipTokens),
      commas(a.vanillaTokens),
      pct1(a.tokenReductionPct),
      usd(a.shipCostUsd),
      usd(a.vanillaCostUsd),
      pct1(a.costReductionPct),
    ];
  });
  const widths = headers.map((h, i) => Math.max(h.length, ...rowsOut.map((r) => r[i].length)));
  const sep = widths.map((w) => '-'.repeat(w)).join(' | ');
  lines.push(headers.map((h, i) => pad(h, widths[i])).join(' | '));
  lines.push(sep);
  for (const r of rowsOut) {
    lines.push(r.map((c, i) => (i === 0 ? pad(c, widths[i]) : padLeft(c, widths[i]))).join(' | '));
  }
  lines.push('');
  lines.push(
    `per-ticket-position token reduction, 1m arm, pooled, counted rows only, MEASURED ship / MODELED vanilla (median %):`,
  );
  lines.push(`(positions with fewer than ${MIN_POSITION_N} rows omitted: a median of 1-9 rows is not a curve)`);
  for (const p of positions) {
    const rs = byPos[p];
    const pcts = rs.filter((r) => r.vanillaTokens > 0).map((r) => (100 * (r.vanillaTokens - r.shipTokens)) / r.vanillaTokens);
    const m = median(pcts);
    const note = p === 1 ? '  -- by construction: a fresh session vs a fresh session is the same session' : '';
    lines.push(`  position ${padLeft(p, 2)} (n=${padLeft(rs.length, 3)}): ${padLeft(pct1(m), 6)}${note}`);
  }
  lines.push('');
  lines.push(`TOTAL rows in source file: ${rows.length} (${ticketCount} tickets x ${ARMS.length} arms)`);
  lines.push('');
  lines.push('Recompute this table yourself: node bench/gen-proof-table.mjs');
  lines.push(
    'Recompute the three headline percentages with only jq: see the command in bench/README.md ("The best-case number").',
  );

  process.stdout.write(lines.join('\n') + '\n');
}

main();
