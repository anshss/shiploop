#!/usr/bin/env node
// Measurement instrument: a local pass-through proxy for ANTHROPIC_BASE_URL that makes the FULL
// assembled request observable, so the prefix can be attributed to its components directly instead
// of inferred from differential cache-token ablation.
//
// Why this exists: `count_tokens` cannot see what Claude Code assembles, and turn-1
// `cache_creation_input_tokens` only gives you ONE number for the whole prefix. At the API boundary
// the request body is fully componentised (`tools`, `system`, `messages`), so the split is a direct
// read. Subscription/OAuth auth survives a local pass-through (this is NOT the `--bare` blocker,
// which forces ANTHROPIC_API_KEY) because every header is forwarded verbatim.
//
// LOAD-BEARING SECURITY PROPERTY — this process sits in front of a worker and handles live
// credentials. It therefore:
//   * forwards every request header verbatim and NEVER reads, stores, or logs a header VALUE
//     (only lowercase header NAMES, and only when SL_CAPTURE_HEADER_NAMES=1),
//   * NEVER writes request or response BODY content to the log — only sizes, counts and names,
//   * binds to 127.0.0.1 only.
// Any change that weakens one of these is a security regression, not a feature.
//
// Usage:
//   node capture-proxy.mjs --port 8787 --log /tmp/capture.jsonl [--upstream https://api.anthropic.com]
// then run the client with ANTHROPIC_BASE_URL=http://127.0.0.1:8787
//
// Emits one JSON line per proxied request to the log file. Prints "listening <port>" on stderr once
// ready, so a shell harness can block on it.

import http from 'node:http'
import https from 'node:https'
import fs from 'node:fs'
import { URL } from 'node:url'

const DEFAULT_UPSTREAM = 'https://api.anthropic.com'
const LISTEN_HOST = '127.0.0.1'
// Bodies are large (100k+) but bounded; refuse anything absurd rather than buffer without limit.
const MAX_BUFFERED_BODY_BYTES = 64 * 1024 * 1024

const argv = process.argv.slice(2)
const arg = (name, fallback) => {
  const i = argv.indexOf(`--${name}`)
  return i >= 0 && argv[i + 1] !== undefined ? argv[i + 1] : fallback
}

const port = Number(arg('port', '0'))
const logPath = arg('log', '')
const upstream = new URL(arg('upstream', process.env.SL_CAPTURE_UPSTREAM || DEFAULT_UPSTREAM))
const captureHeaderNames = process.env.SL_CAPTURE_HEADER_NAMES === '1'

if (!logPath) {
  process.stderr.write('capture-proxy: --log <path> is required\n')
  process.exit(2)
}

const logStream = fs.createWriteStream(logPath, { flags: 'a' })
const writeRecord = (record) => logStream.write(`${JSON.stringify(record)}\n`)

/** Byte length of a value once serialized as JSON — the unit the request is actually billed in. */
const jsonBytes = (value) =>
  value === undefined ? 0 : Buffer.byteLength(JSON.stringify(value), 'utf8')

/**
 * Componentise an /v1/messages request body by JSON byte size. Returns SIZES AND NAMES ONLY —
 * never content. `tools` is the per-tool schema breakdown; `system` and `messages` are the other
 * two top-level payload halves; `other` is everything else (model, max_tokens, metadata, …).
 */
const componentise = (body) => {
  const total = Buffer.byteLength(body, 'utf8')
  let parsed
  try {
    parsed = JSON.parse(body)
  } catch {
    return { totalBytes: total, parsed: false }
  }

  const toolBytes = jsonBytes(parsed.tools)
  const systemBytes = jsonBytes(parsed.system)
  const messagesBytes = jsonBytes(parsed.messages)
  const tools = Array.isArray(parsed.tools)
    ? parsed.tools.map((t) => ({ name: t?.name ?? '<unnamed>', bytes: jsonBytes(t) }))
    : []

  return {
    totalBytes: total,
    parsed: true,
    model: typeof parsed.model === 'string' ? parsed.model : null,
    stream: parsed.stream === true,
    toolBytes,
    toolCount: tools.length,
    systemBytes,
    systemBlocks: Array.isArray(parsed.system) ? parsed.system.length : parsed.system ? 1 : 0,
    messagesBytes,
    messageCount: Array.isArray(parsed.messages) ? parsed.messages.length : 0,
    otherBytes: Math.max(0, total - toolBytes - systemBytes - messagesBytes),
    tools,
  }
}

const server = http.createServer((req, res) => {
  const chunks = []
  let bufferedBytes = 0
  let overflowed = false

  req.on('data', (chunk) => {
    bufferedBytes += chunk.length
    if (bufferedBytes > MAX_BUFFERED_BODY_BYTES) {
      overflowed = true
      return
    }
    chunks.push(chunk)
  })

  req.on('error', () => {
    // Client hung up mid-upload — nothing to forward, nothing to record.
    res.destroy()
  })

  req.on('end', () => {
    if (overflowed) {
      res.writeHead(413).end()
      return
    }
    const body = Buffer.concat(chunks)
    const headers = { ...req.headers, host: upstream.host }
    const startedAt = process.hrtime.bigint()

    const isMessages = (req.url || '').includes('/v1/messages')
    const record = {
      method: req.method,
      path: (req.url || '').split('?')[0],
      requestBytes: body.length,
      ...(isMessages && body.length ? componentise(body.toString('utf8')) : {}),
      ...(captureHeaderNames ? { headerNames: Object.keys(headers).sort() } : {}),
    }

    const upstreamReq = https.request(
      {
        protocol: upstream.protocol,
        hostname: upstream.hostname,
        port: upstream.port || 443,
        path: req.url,
        method: req.method,
        headers,
      },
      (upstreamRes) => {
        let responseBytes = 0
        res.writeHead(upstreamRes.statusCode || 502, upstreamRes.headers)
        upstreamRes.on('data', (chunk) => {
          responseBytes += chunk.length
        })
        upstreamRes.pipe(res)
        upstreamRes.on('end', () => {
          writeRecord({
            ...record,
            status: upstreamRes.statusCode,
            responseBytes,
            elapsedMs: Number(process.hrtime.bigint() - startedAt) / 1e6,
          })
        })
      },
    )

    upstreamReq.on('error', (err) => {
      // Never swallow: the worker in front of this proxy must see the failure, and the log must
      // show why the capture has a hole. `err.message` is transport-level, never credential text.
      writeRecord({ ...record, status: null, error: err.message })
      if (!res.headersSent) res.writeHead(502)
      res.end()
    })

    upstreamReq.end(body)
  })
})

server.on('error', (err) => {
  process.stderr.write(`capture-proxy: ${err.message}\n`)
  process.exit(1)
})

server.listen(port, LISTEN_HOST, () => {
  process.stderr.write(`listening ${server.address().port}\n`)
})

const shutdown = () => {
  server.close(() => {
    logStream.end(() => process.exit(0))
  })
  // Don't hang forever on a half-open keep-alive socket.
  setTimeout(() => process.exit(0), 2000).unref()
}
process.on('SIGTERM', shutdown)
process.on('SIGINT', shutdown)
