# Bounded runtime and rendering validation

THROW AWAY prototype for [Validate bounded runtime and rendering behavior](https://github.com/patrick-fu/coding-agent-metrics/issues/7).

This is not the production AppKit/SwiftUI app. It is an in-memory stand-in of the accepted P0 pipeline:

`SourceAdapter → CanonicalIngestor → FactStore → LiveSampler → SnapshotBuilder`

## Run

From this directory:

```bash
node harness.mjs
```

That writes `benchmark-results.md` and `benchmark-results.json`. `PASS` is only for correctness. Candidate gates are `MEET` or `MISS` (`ok: false` / `candidate-miss` when over the gate). Ungated timings are `MEASURED`.

To open the accepted D summary-drill-down shell:

```bash
python3 -m http.server 8765
```

Then visit `http://127.0.0.1:8765/bounded-runtime.throwaway.html`.

Do not open the HTML as a `file:` URL. It loads `runtime.mjs` as an ES module.

## What it covers

- Orthogonal Agent / Model multi-select
- Fixed live windows from the metric contract: 3-minute output throughput, 10-minute token burn, 10-minute calls
- Independent performance range: 15m / 1h / 24h / 7d
- Top 4 + Other, alphabetical tie-break
- Stale / partial / unavailable, never fabricated as zero
- Schema-unknown and source-failure isolation
- Status-item light snapshot vs popover detail snapshot
- Hidden popover stops high-frequency detail rendering
- Bounded queues, facts, series, and inflight queries
- Keyboard, non-color cues, reduced motion, expandable data table

## VoiceOver

System VoiceOver is a manual acceptance item. This prototype exposes accessible names and a real data table, but it cannot certify macOS VoiceOver speech.

## Privacy

Synthetic fixtures only. No real Codex/Claude logs, prompts, tool results, local paths, accounts, or private URLs.
