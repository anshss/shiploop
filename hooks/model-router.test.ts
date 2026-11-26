// The model router's spawn routing, fired through Claude Code's own test kit (claude plugin test):
// each test fires agent.spawn the way a real session does and reads back the model the spawn was
// handed. No session, sign-in or network is involved.
import { expect, mock, test } from 'claude-code/testing'

const PROFILE = [
  'FAMILY=glm',
  '# a comment line is skipped',
  'ROLE_advisor="glm-5.4[1m]"',
  'ROLE_worker="glm-5.3-flash[1m]"',
  'ROLE_worker_retry="glm-5.4[1m]"',
  'ROLE_investigator="glm-5.3"',
  'ROLE_lookup="glm-5.3-flash[1m]"',
  'TIER_ORDER="advisor worker_retry investigator worker lookup"',
].join('\n')

// What the engine stub reports for a spawn the router left alone: the event still carries no
// model, so Claude Code's own resolution (the definition's, then the parent's) would decide.
const INHERITED = 'inherited'

// Stands in for Claude Code at the end of the chain and reports the model the spawn arrived with.
function engineAnswers(on: (name: string, handler: unknown) => void) {
  on('session.cwd', () => ({ value: '/work' }))
  on('agent.spawn', (_$: unknown, e: { model?: string }) => ({ model: e.model ?? INHERITED }))
}

function spawn($: { agent: { spawn: (e: object) => Promise<{ model?: string }> } }, subagentType: string, extra: object = {}) {
  return $.agent.spawn({
    tool_use_id: 'toolu_1',
    prompt: 'Resolve #7.',
    description: 'dispatch',
    subagentType,
    provider: { plugin: 'engine', tier: 'core' },
    parentModel: 'glm-5.4[1m]',
    background: false,
    fork: false,
    ...extra,
  })
}

test('a shiploop role gets the profile model for that role', async ($, on) => {
  mock.env(on, { SHIPLOOP_MODEL_PROFILE: 'glm' })
  on('fs.read', (_$: unknown, e: { path: string }) => ({
    value: e.path.endsWith('/scripts/lib/model-profiles/glm.conf') ? PROFILE : '',
  }))
  engineAnswers(on)

  expect((await spawn($, 'worker')).model).toBe('glm-5.3-flash[1m]')
  expect((await spawn($, 'worker-retry')).model).toBe('glm-5.4[1m]')
  expect((await spawn($, 'investigator')).model).toBe('glm-5.3')
  expect((await spawn($, 'lookup')).model).toBe('glm-5.3-flash[1m]')
})

test('the profile model replaces whatever model the call passed', async ($, on) => {
  mock.env(on, { SHIPLOOP_MODEL_PROFILE: 'glm' })
  on('fs.read', () => ({ value: PROFILE }))
  engineAnswers(on)

  expect((await spawn($, 'worker', { model: 'opus' })).model).toBe('glm-5.3-flash[1m]')
})

test('an agent type the profile holds no role for inherits the session model', async ($, on) => {
  mock.env(on, { SHIPLOOP_MODEL_PROFILE: 'glm' })
  on('fs.read', () => ({ value: PROFILE }))
  engineAnswers(on)

  expect((await spawn($, 'general-purpose')).model).toBe(INHERITED)
  expect((await spawn($, 'Explore')).model).toBe(INHERITED)
})

test('with no profile active every spawn passes through unchanged', async ($, on) => {
  mock.env(on, {})
  on('fs.read', () => ({ value: PROFILE }))
  engineAnswers(on)

  expect((await spawn($, 'worker')).model).toBe(INHERITED)
  expect((await spawn($, 'lookup')).model).toBe(INHERITED)
  expect((await spawn($, 'worker-retry', { model: 'opus' })).model).toBe('opus')
})

test('a profile that cannot be read passes every spawn through', async ($, on) => {
  mock.env(on, { SHIPLOOP_MODEL_PROFILE: 'glm' })
  on('fs.read', () => ({ deny: 'no such file' }))
  engineAnswers(on)

  expect((await spawn($, 'worker')).model).toBe(INHERITED)
})

test('a profile name that is not a plain name passes through without reading any file', async ($, on) => {
  mock.env(on, { SHIPLOOP_MODEL_PROFILE: '../../etc/passwd' })
  on('fs.read', () => ({ value: PROFILE }))
  engineAnswers(on)

  expect((await spawn($, 'worker')).model).toBe(INHERITED)
})

test('a resumed run is left alone', async ($, on) => {
  mock.env(on, { SHIPLOOP_MODEL_PROFILE: 'glm' })
  on('fs.read', () => ({ value: PROFILE }))
  engineAnswers(on)

  expect((await spawn($, 'worker', { resume: { agentId: 'a1' } })).model).toBe(INHERITED)
})
