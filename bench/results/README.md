# bench/results

Empty on purpose.

`bench/results/*` is gitignored: raw benchmark results are runtime state, not artifacts. This file
is the only tracked thing here, and it exists so the directory survives in a fresh clone.

There is **no committed result table** at the moment. `bench/gen-proof-table.mjs` still works and
still generates one, but it needs a published rows file to generate from, and there is not one:
see `bench/published-rows/SCHEMA.md` for why, and for what has to happen before there is.

Regenerating one, once a corpus exists:

```bash
node bench/gen-proof-table.mjs bench/published-rows/<file>.jsonl > bench/results/proof-table.txt
```

Committing that output means committing a performance claim, so it is a deliberate act with the
same bar as publishing a number anywhere else in this repository.
