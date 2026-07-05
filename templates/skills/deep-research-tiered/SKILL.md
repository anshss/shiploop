---
name: deep-research-tiered
description: Deep research harness — fan-out web searches, fetch sources, adversarially verify claims, synthesize a cited report. In this workspace, prefer `Workflow({name: 'deep-research-tiered', args: {question, models?}})` over the built-in `deep-research` — same output shape, brain-decided model plan, cheap defaults (scope=sonnet · search=sonnet · fetch=haiku · verify=sonnet · synthesize=inherit) so a brainless invocation never repeats the all-inherit token burn. Use when the user wants a deep, multi-source, fact-checked research report on any topic. BEFORE invoking, check if the question is specific enough to research directly — if underspecified (e.g. "what car to buy" without budget/use-case/region), ask 2-3 clarifying questions to narrow scope. Then pass the refined question as `args.question`, weaving the answers in.
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
