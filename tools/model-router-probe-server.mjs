// Loopback stand-in for a model endpoint, for tools/model-router-probe.sh.
//
// Listens on 127.0.0.1 only and never contacts anything. Every /v1/messages request is appended
// to the log file (argv: 3) as one JSON line with the model it carried and whether it came from the
// spawned subagent (its system prompt holds the marker given as argv: 4). The main agent's first
// request is answered with one Agent tool call; everything else gets a short text answer.
//
// argv: 2 = port (0 for any free port), 3 = log file, 4 = subagent marker
import http from 'node:http'
import { appendFileSync } from 'node:fs'

const port = Number(process.argv[2]) || 0
const log = process.argv[3]
const marker = process.argv[4] || ''

let n = 0          // message ids
let seen = 0        // requests logged
const sse = (res, events) => {
  res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache' })
  for (const [event, data] of events) res.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`)
  res.end()
}
const start = (model) => ['message_start', { type: 'message_start', message: { id: `msg_${++n}`, type: 'message', role: 'assistant', model, content: [], stop_reason: null, stop_sequence: null, usage: { input_tokens: 10, output_tokens: 1, cache_creation_input_tokens: 0, cache_read_input_tokens: 0 } } }]
const toolCall = (model, type) => [
  start(model),
  ['content_block_start', { type: 'content_block_start', index: 0, content_block: { type: 'tool_use', id: `toolu_${n}`, name: 'Agent', input: {} } }],
  ['content_block_delta', { type: 'content_block_delta', index: 0, delta: { type: 'input_json_delta', partial_json: JSON.stringify({ description: 'probe', prompt: 'What is the value of X? Answer in one line.', subagent_type: type }) } }],
  ['content_block_stop', { type: 'content_block_stop', index: 0 }],
  ['message_delta', { type: 'message_delta', delta: { stop_reason: 'tool_use', stop_sequence: null }, usage: { output_tokens: 20 } }],
  ['message_stop', { type: 'message_stop' }],
]
const text = (model) => [
  start(model),
  ['content_block_start', { type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } }],
  ['content_block_delta', { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: 'probe answer' } }],
  ['content_block_stop', { type: 'content_block_stop', index: 0 }],
  ['message_delta', { type: 'message_delta', delta: { stop_reason: 'end_turn', stop_sequence: null }, usage: { output_tokens: 5 } }],
  ['message_stop', { type: 'message_stop' }],
]

const server = http.createServer((req, res) => {
  let body = ''
  req.on('data', (chunk) => { body += chunk })
  req.on('end', () => {
    if (req.method !== 'POST' || !req.url.startsWith('/v1/messages')) {
      res.writeHead(404, { 'content-type': 'application/json' })
      res.end('{}')
      return
    }
    let parsed = {}
    try { parsed = JSON.parse(body) } catch { /* an unreadable body still gets an answer, so the session ends */ }
    const system = JSON.stringify(parsed.system ?? '')
    const subagent = marker !== '' && system.includes(marker)
    const toolResult = JSON.stringify(parsed.messages ?? []).includes('"tool_result"')
    seen += 1
    appendFileSync(log, JSON.stringify({ n: seen, model: parsed.model, subagent }) + '\n')
    if (subagent || toolResult) sse(res, text(parsed.model))
    else sse(res, toolCall(parsed.model, process.env.PROBE_SPAWN_TYPE || 'lookup'))
  })
})
server.listen(port, '127.0.0.1', () => console.log(server.address().port))
