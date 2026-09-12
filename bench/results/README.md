# bench/results

Empty on purpose.

`bench/results/*` is gitignored: raw benchmark results are runtime state, not artifacts. This file
is the only tracked thing here, and it exists so the directory survives in a fresh clone.

There is **no committed result** at the moment. `bench/run.sh` writes a fresh
`results.jsonl` here on every real run, and `node bench/rollup.mjs` turns the newest one into the
three metric cuts and the headline sentence — but no backlog meeting the design's own 6-ticket
usability bar has been curated yet (`bench/KNOWN-LIMITS.md`), so there is nothing to run this
against that this repository would stand behind publishing.

Committing a run's output here (or citing a number from one) means committing a performance claim,
so it is a deliberate act with the same bar as publishing a number anywhere else in this
repository: a curated backlog, both arms measured for real, neither capped, and the arm/backlog/tier
named alongside the figure.
