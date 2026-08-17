# SQLite retention prototype

THROW AWAY prototype for [Measure SQLite growth and set retention](https://github.com/patrick-fu/coding-agent-metrics/issues/10).

This is not the production AppKit/SwiftUI app. It measures a synthetic-only SQLite WAL store of canonical Usage Facts. [Measure SQLite growth and set retention](https://github.com/patrick-fu/coding-agent-metrics/issues/10) accepted candidate A: keep all raw Usage Facts until a bytes-or-rows ceiling. The accepted 20k fact budget from issue 7 is the hot/query working set, not persistent retention.

## Run

Requires Node 22+ with `node:sqlite` (this run used Node 25.6.1). From this directory:


```bash
node harness.mjs
```

Optional:

```bash
node harness.mjs --scales=10k,100k,1m --runs=5
node harness.mjs --logic-only
```

The first command writes `results/benchmark-results.md`, `results/benchmark-results.json`, and `results/hitl-snapshot.js`. The second command writes `results/p0-policy-assertions.md` and does **not** rewrite the 10k/100k/1m timings. Open `sqlite-retention.throwaway.html` by double-clicking it. Scratch databases live in `tmp/` and are named `*PROTOTYPE-wipe-me*`.

`PASS` is only for correctness. Timings and sizes are `MEASURED` local ranges, not fleet SLOs and not AppKit/Swift numbers.

## What it covers

- Single-writer WAL schema close to the accepted FactStore, with no prompt, code, tool I/O, path, account, or content columns
- Synthetic Codex / Claude Code Usage Facts over 400 days
- Mutually exclusive token parts; unavailable stays NULL, never 0
- Windowed Output Throughput, Token Burn, Calls, Agent+Model multi-select, and raw-sample Decode TPS p50/p95
- Checkpoint, delete, incremental_vacuum, VACUUM, backup, source-scoped rebuild, and a minimal migration
- Source logs that later disappear: historical facts stay unless Reset Data or an explicit delete policy runs
- Capacity ceiling: bytes or rows, superseded then 90d compact, then oldest rollup, then 7-90d raw, then pause rather than delete the 7d window
- 90d compaction is repeat-safe: upsert/merge only buckets with new raw, never wipe existing rollups
- Reset Data wipes all App-owned telemetry and never touches source logs or user-saved external exports
- Accepted candidate A is recorded in `CANDIDATES.md`; B and C remain rejected alternatives

## Privacy

Synthetic fixtures only. No real Coding Agent logs, prompts, command output, local paths, accounts, or private URLs.
