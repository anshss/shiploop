---
name: deep-research-tiered
description: Deep research harness: fan-out search, fetch, adversarially verify, synthesize a cited report. Prefer `Workflow({name:'deep-research-tiered', args:{question, models?}})` over built-in `deep-research` — same output, cheap tiered defaults (scope/search=sonnet, fetch=haiku, verify=sonnet, synthesize=inherit). Use for deep multi-source fact-checked research; if the question is underspecified, ask 2-3 clarifying questions first, then pass the refined question.
---

# deep-research-tiered — model-tiered deep-research (workspace override)

Shiploop workspaces ship a model-tiered override of the built-in `deep-research` workflow. Prefer
it over the built-in in this workspace:

```
Workflow({name: 'deep-research-tiered', args: '<question>'})                                  // cheap-tier defaults
Workflow({name: 'deep-research-tiered', args: {question: '<q>', models: {                     // brain overrides
  scope: 'sonnet', search: 'sonnet', fetch: 'haiku',
  verify: 'sonnet', synthesize: 'opus',
}}})
```

Same output shape as the built-in. The five stages (Scope → Search → Fetch → Verify → Synthesize)
each accept an explicit model pin via `args.models`. Null-semantics contract:

- absent OR explicit `null` for a stage → the tiered default
- literal string `"inherit"` → no model pinned (session model handles the stage)
- any other string → pin that model

The tiered defaults keep a brainless invocation cheap: `scope=sonnet`, `search=sonnet`,
`fetch=haiku` (with `effort: 'low'`), `verify=sonnet`, `synthesize=inherit`. Only synthesis
inherits the session model by default — that's the one stage where the frontier tier pays.

## Naming and precedence

The `.claude/workflows/deep-research.js` file is renamed at `meta.name` to `deep-research-tiered`
so it can't collide with the built-in by name (whether a same-named workspace copy shadows the
built-in is undocumented in the Workflow tool spec — this fallback is robust either way).
Invoking `Workflow({name: 'deep-research-tiered', ...})` unambiguously routes to the workspace
copy in every session.
