// shiploop's model router.
//
// shiploop names the subagents it spawns by ROLE (worker, worker-retry, investigator, lookup) and
// never passes `model` on the spawn, because the Agent tool's model parameter takes only Claude's
// slot aliases and cannot carry another family's id. This hook sits after that point: it reads the
// active model profile (SHIPLOOP_MODEL_PROFILE names the family) and hands the spawn the model the
// profile assigns to that role.
//
// Passthrough is the contract. With the variable unset, with a profile file that cannot be read,
// or for an agent type the profile holds no role for, the event goes on exactly as it arrived and
// the subagent resolves its model by Claude Code's own rule: the call's model, then the
// definition's, then the parent's. A failure inside this hook can therefore never cost a spawn
// more than its routing, which is why every read is caught and falls through.

// A profile file is KEY=value lines. A value may sit in double quotes (a model id can hold
// characters a shell would otherwise read, such as the [1m] context suffix), # starts a comment,
// and a line that is not an assignment is skipped. The govern scripts parse the same file with
// the same three rules, so the two readers can never disagree about a value.
function parseProfile(text) {
  const profile = {}
  for (const line of String(text).split('\n')) {
    const match = /^[ \t]*([A-Za-z_][A-Za-z0-9_]*)[ \t]*=[ \t]*(.*)$/.exec(line)
    if (!match) continue
    const value = match[2].trim()
    profile[match[1]] = value.startsWith('"') && value.endsWith('"') && value.length >= 2
      ? value.slice(1, -1)
      : value
  }
  return profile
}

// The role a spawn's agent type names, or "" when it names none.
//
// A workspace installs shiploop's agent definitions at .claude/agents/, and the type arrives bare
// (`worker`, `worker-retry`). An agent a PLUGIN provides arrives namespaced, `<plugin>:<type>`, and
// when this plugin is the one providing it the type behind the prefix is still the role. A type
// namespaced by any other plugin is some other plugin's agent, whatever it is called, and is not a
// shiploop role.
function roleName(subagentType, ownPlugin) {
  const type = String(subagentType)
  const colon = type.indexOf(':')
  if (colon < 0) return type
  return type.slice(0, colon) === ownPlugin ? type.slice(colon + 1) : ''
}

// The profile key that holds a role's model: the role with every non-identifier character taken
// as an underscore, so `worker-retry` reads ROLE_worker_retry.
function roleKey(role) {
  return 'ROLE_' + role.replace(/[^A-Za-z0-9_]/g, '_')
}

// The active profile as a plain object, or null when none applies.
//
// The file is looked up first in the session's workspace (scripts/lib/model-profiles/, where
// /shiploop:update installs it beside the govern scripts that read the same file) and then among
// the profiles this plugin itself ships. A name with a path separator or a space in it is not a
// profile name and reads as none.
async function activeProfile($) {
  const name = await $.env.get('SHIPLOOP_MODEL_PROFILE')
  if (!name || !/^[A-Za-z0-9_.-]+$/.test(name)) return null
  const file = '/model-profiles/' + name + '.conf'
  const candidates = [
    (await $.session.cwd()) + '/scripts/lib' + file,
    $.plugin.root + '/templates/lib' + file,
  ]
  for (const path of candidates) {
    try {
      return parseProfile(await $.fs.read(path))
    } catch {
      // Unreadable here: the next location may hold it, and none holding it means passthrough.
    }
  }
  return null
}

// Claude Code calls this once when the mod loads.
export function register(on) {
  // Runs when a subagent or a teammate is about to start
  on('agent.spawn', async ($, e, next) => {
    let profile
    try {
      profile = await activeProfile($)
    } catch {
      return next(e)
    }
    if (!profile) return next(e)
    // A resumed run keeps the model it started on; a change here would be ignored anyway, and a
    // retry is meant to be a fresh worker-retry spawn, never a resumed worker.
    if (e.resume) return next(e)
    if (e.fork) return next(e)
    const model = profile[roleKey(roleName(e.subagentType, $.plugin.name))]
    // An empty or missing role means the type is not a shiploop role: leave the spawn alone.
    if (!model) return next(e)
    return next({ ...e, model })
  })
}
