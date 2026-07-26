#!/usr/bin/env bash
# Locks the load-bearing security properties of the request-capture proxy (`lib/capture-proxy.mjs`).
#
# The proxy sits in front of a worker on `ANTHROPIC_BASE_URL` and therefore handles LIVE credentials.
# Three properties are the whole reason it is safe to run, and each is asserted here against a real
# proxied request rather than left to a comment:
#   1. It never writes a header VALUE to its log — an `Authorization` / `x-api-key` sentinel must not
#      appear anywhere in the capture file.
#   2. It never writes request or response BODY content to its log — a body sentinel and a response
#      sentinel must both be absent.
#   3. It forwards headers VERBATIM to the upstream — the upstream must SEE the credential it was
#      given, unmodified, or subscription/OAuth auth would break behind the proxy.
# Plus the functional contract it exists for: the componentised byte split is recorded.
#
# Runs entirely against a local http stub upstream — no network, no auth, no cost.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
PROXY="$DIR/../lib/capture-proxy.mjs"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not installed"; exit 77; }
command -v jq   >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 77; }
[[ -f "$PROXY" ]] || { echo "SKIP: capture-proxy.mjs not present in this layout"; exit 77; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"; kill ${up_pid:-} ${proxy_pid:-} 2>/dev/null || true' EXIT

SECRET="sk-ant-SENTINEL-CREDENTIAL-8f2a"
BODY_SENTINEL="BODY-SENTINEL-QQ7"
RESP_SENTINEL="RESPONSE-SENTINEL-ZZ9"

# --- Stub upstream: records the Authorization header it received, replies with a sentinel body. ---
cat > "$TMP/upstream.mjs" <<EOF
import http from 'node:http'
import fs from 'node:fs'
const server = http.createServer((req, res) => {
  req.on('data', () => {})
  req.on('end', () => {
    fs.writeFileSync('$TMP/seen-auth.txt', String(req.headers['authorization'] ?? ''))
    res.writeHead(200, { 'content-type': 'application/json' })
    res.end(JSON.stringify({ ok: true, marker: '$RESP_SENTINEL' }))
  })
})
server.listen(0, '127.0.0.1', () => process.stderr.write('listening ' + server.address().port + '\n'))
EOF

node "$TMP/upstream.mjs" 2>"$TMP/upstream.err" & up_pid=$!
up_port=""
for _ in $(seq 1 100); do
  up_port="$(awk '/^listening /{print $2; exit}' "$TMP/upstream.err" 2>/dev/null || true)"
  [[ -n "$up_port" ]] && break
  kill -0 "$up_pid" 2>/dev/null || { echo "FAIL - stub upstream died"; exit 1; }
  sleep 0.1
done
[[ -n "$up_port" ]] || { echo "FAIL - stub upstream never reported a port"; exit 1; }

# --- Proxy in front of it. ---
node "$PROXY" --port 0 --log "$TMP/capture.jsonl" --upstream "http://127.0.0.1:$up_port" \
  2>"$TMP/proxy.err" & proxy_pid=$!
port=""
for _ in $(seq 1 100); do
  port="$(awk '/^listening /{print $2; exit}' "$TMP/proxy.err" 2>/dev/null || true)"
  [[ -n "$port" ]] && break
  kill -0 "$proxy_pid" 2>/dev/null || { echo "FAIL - proxy died: $(cat "$TMP/proxy.err")"; exit 1; }
  sleep 0.1
done
[[ -n "$port" ]] || { echo "FAIL - proxy never reported a port"; exit 1; }

# --- One request shaped like a real /v1/messages call, carrying a credential and a body sentinel. ---
jq -nc --arg s "$BODY_SENTINEL" '{
  model:"claude-test", stream:false,
  system:[{type:"text",text:$s}],
  messages:[{role:"user",content:$s}],
  tools:[{name:"Bash",description:$s},{name:"Read",description:"x"}]
}' > "$TMP/req.json"

curl -sS -o "$TMP/resp.json" -X POST "http://127.0.0.1:$port/v1/messages" \
  -H "content-type: application/json" \
  -H "authorization: Bearer $SECRET" \
  --data-binary "@$TMP/req.json" >/dev/null

kill "$proxy_pid" 2>/dev/null || true
for _ in $(seq 1 30); do [[ -s "$TMP/capture.jsonl" ]] && break; sleep 0.1; done

# 1. The request actually round-tripped (otherwise every "absent" assertion below is vacuous).
if grep -qF "$RESP_SENTINEL" "$TMP/resp.json" 2>/dev/null; then
  printf 'ok   - %s\n' "the request round-tripped through the proxy to the upstream"
else
  printf 'FAIL - %s\n       response was: %s\n' "the request round-tripped through the proxy" \
    "$(cat "$TMP/resp.json" 2>/dev/null)"
  ASSERT_FAILS=$((ASSERT_FAILS+1))
fi

# 2. Headers forwarded VERBATIM — the upstream saw the exact credential.
assert_eq "$(cat "$TMP/seen-auth.txt" 2>/dev/null)" "Bearer $SECRET" \
  "the upstream receives the Authorization header verbatim (auth survives the proxy)"

# 3. No credential, no request body, no response body anywhere in the log.
for sentinel_desc in \
  "$SECRET|header VALUEs (the credential)" \
  "$BODY_SENTINEL|request BODY content" \
  "$RESP_SENTINEL|response BODY content"; do
  sentinel="${sentinel_desc%%|*}"; desc="${sentinel_desc##*|}"
  if grep -qF "$sentinel" "$TMP/capture.jsonl" 2>/dev/null; then
    printf 'FAIL - %s\n' "the capture log MUST NOT contain $desc"
    ASSERT_FAILS=$((ASSERT_FAILS+1))
  else
    printf 'ok   - %s\n' "the capture log contains no $desc"
  fi
done

# 4. …and it still records the thing it exists to record: the componentised byte split.
rec="$(head -1 "$TMP/capture.jsonl")"
assert_eq "$(printf '%s' "$rec" | jq -r '.parsed')" "true" "the /v1/messages body was componentised"
assert_eq "$(printf '%s' "$rec" | jq -r '.toolCount')" "2" "the tool count is recorded"
assert_eq "$(printf '%s' "$rec" | jq -r '.tools[0].name')" "Bash" "tool NAMES are recorded (names are not content)"
for field in totalBytes toolBytes systemBytes messagesBytes; do
  v="$(printf '%s' "$rec" | jq -r ".$field")"
  if [[ "$v" =~ ^[0-9]+$ ]] && [[ "$v" -gt 0 ]]; then
    printf 'ok   - %s\n' "$field is recorded as a positive byte count ($v)"
  else
    printf 'FAIL - %s\n       got: %s\n' "$field is recorded as a positive byte count" "$v"
    ASSERT_FAILS=$((ASSERT_FAILS+1))
  fi
done

# 5. Source-level lock: the proxy must bind to loopback only. A future edit that widens the bind
# address would expose a credential-forwarding proxy to the network.
if grep -qF "const LISTEN_HOST = '127.0.0.1'" "$PROXY"; then
  printf 'ok   - %s\n' "the proxy binds to 127.0.0.1 only"
else
  printf 'FAIL - %s\n' "the proxy MUST bind to 127.0.0.1 only"
  ASSERT_FAILS=$((ASSERT_FAILS+1))
fi

assert_done
