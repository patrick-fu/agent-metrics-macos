# SQLite retention prototype

THROW AWAY prototype for [Measure SQLite growth and set retention](https://github.com/patrick-fu/coding-agent-metrics/issues/10).

This is not the production AppKit/SwiftUI app. It measures a synthetic-only SQLite WAL store of canonical Usage Facts and compares mutually exclusive retention strategies. The accepted 20k fact budget from issue 7 is the hot/query working set, not persistent retention.

## Run

Requires Node 22+ with `node:sqlite` (this run used Node 25.6.1). From this directory:


```bash
node harness.mjs
```

Optional:

```bash
node harness.mjs --scales=10k,100k,1m --runs=5
```

That writes `results/benchmark-results.md`, `results/benchmark-results.json`, and `results/hitl-snapshot.js`. Open `sqlite-retention.throwaway.html` by double-clicking it. Scratch databases live in `tmp/` and are named `*PROTOTYPE-wipe-me*`.

`PASS` is only for correctness. Timings and sizes are `MEASURED` local ranges, not fleet SLOs and not AppKit/Swift numbers.

## What it covers

- Single-writer WAL schema close to the accepted FactStore, with no prompt, code, tool I/O, path, account, or content columns
- Synthetic Codex / Claude Code Usage Facts over 400 days
- Mutually exclusive token parts; unavailable stays NULL, never 0
- Windowed Output Throughput, Token Burn, Calls, Agent+Model multi-select, and raw-sample Decode TPS p50/p95
- Checkpoint, delete, incremental_vacuum, VACUUM, backup, source-scoped rebuild, and a minimal migration
- Source logs that later disappear: historical facts stay unless Reset Data or an explicit delete policy runs
- Three mutually exclusive retention candidates in `CANDIDATES.md`

## Privacy

Synthetic fixtures only. No real Coding Agent logs, prompts, command output, local paths, accounts, or private URLs.
