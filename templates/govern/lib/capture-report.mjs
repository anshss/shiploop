#!/usr/bin/env node
// Turn a capture-proxy JSONL log into the committed component-split table.
//
// Reads size-only records (capture-proxy.mjs never logs content) and reports:
//   * the TURN-1 split — `tools` / `system` / `messages` / other, in bytes and % of the request,
//   * the per-tool schema breakdown, biggest first, since the tool block is one JSON array whose
//     members can be trimmed individually via `--tools`,
//   * an all-turns roll-up, because the prefix is RE-SENT on every turn: a component's true cost
//     share is Σ(component_i) / Σ(total_i), not its turn-1 share.
//
// Usage: node capture-report.mjs <capture.jsonl> [--top 20] [--json]

import fs from 'node:fs'

const [, , logPath, ...rest] = process.argv
if (!logPath) {
  process.stderr.write('capture-report: <capture.jsonl> is required\n')
  process.exit(2)
}

const flag = (name, fallback) => {
  const i = rest.indexOf(`--${name}`)
  return i >= 0 && rest[i + 1] !== undefined ? rest[i + 1] : fallback
}
const TOP_N = Number(flag('top', '20'))
const asJson = rest.includes('--json')

const records = fs
  .readFileSync(logPath, 'utf8')
  .split('\n')
  .filter(Boolean)
  .map((line) => {
    try {
      return JSON.parse(line)
    } catch {
      return null
    }
  })
  .filter((r) => r && r.parsed === true && r.path?.includes('/v1/messages'))

if (!records.length) {
  process.stderr.write(`capture-report: no parsed /v1/messages records in ${logPath}\n`)
  process.exit(1)
}

const pct = (part, whole) => (whole ? ((part / whole) * 100).toFixed(1) : '0.0')
const n = (v) => v.toLocaleString('en-US')

const turn1 = records[0]
const sum = (key) => records.reduce((acc, r) => acc + (r[key] || 0), 0)
const allTotal = sum('totalBytes')

const COMPONENTS = [
  ['tool schemas', 'toolBytes'],
  ['messages', 'messagesBytes'],
  ['system prompt', 'systemBytes'],
  ['other (model, metadata, …)', 'otherBytes'],
]

const summary = {
  logPath,
  requests: records.length,
  model: turn1.model,
  toolCount: turn1.toolCount,
  turn1: Object.fromEntries([
    ['totalBytes', turn1.totalBytes],
    ...COMPONENTS.map(([, key]) => [key, turn1[key] || 0]),
  ]),
  allTurns: Object.fromEntries([
    ['totalBytes', allTotal],
    ...COMPONENTS.map(([, key]) => [key, sum(key)]),
  ]),
  tools: [...(turn1.tools || [])].sort((a, b) => b.bytes - a.bytes),
}

if (asJson) {
  process.stdout.write(`${JSON.stringify(summary, null, 2)}\n`)
  process.exit(0)
}

const out = []
out.push(`**Capture:** \`${logPath}\` — ${summary.requests} \`/v1/messages\` request(s), model \`${summary.model}\`, ${summary.toolCount} tools.`)
out.push('')
out.push(`### Turn-1 request split — ${n(turn1.totalBytes)} bytes total`)
out.push('')
out.push('| Component | Bytes | % of request |')
out.push('|---|---:|---:|')
for (const [label, key] of COMPONENTS) {
  out.push(`| ${label} | ${n(turn1[key] || 0)} | ${pct(turn1[key] || 0, turn1.totalBytes)}% |`)
}
out.push('')
out.push(`### All ${summary.requests} turns — ${n(allTotal)} bytes sent`)
out.push('')
out.push('| Component | Bytes | % of all bytes sent |')
out.push('|---|---:|---:|')
for (const [label, key] of COMPONENTS) {
  out.push(`| ${label} | ${n(sum(key))} | ${pct(sum(key), allTotal)}% |`)
}
out.push('')
out.push(`### Tool schemas, biggest first (top ${TOP_N} of ${summary.tools.length})`)
out.push('')
out.push('| Tool | Bytes | % of tool block |')
out.push('|---|---:|---:|')
for (const tool of summary.tools.slice(0, TOP_N)) {
  out.push(`| \`${tool.name}\` | ${n(tool.bytes)} | ${pct(tool.bytes, turn1.toolBytes)}% |`)
}
process.stdout.write(`${out.join('\n')}\n`)
