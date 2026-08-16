# Bounded runtime local results

THROW AWAY. Synthetic fixtures only.

Measured numbers are from one local Node process and an in-memory stand-in. They are not AppKit, SQLite, or fleet facts. Suggested gates are candidate acceptance thresholds for Patrick to accept or revise.

| Check | Measured | Suggested / expected | Result |
| --- | --- | --- | --- |
| decode TPS v1 formula | 60 | (output_total - 1) / (duration - TTFT) = 60 | PASS |
| decode TPS unavailable without call identity | unavailable | unavailable | PASS |
| decode TPS excludes retries | unavailable | unavailable | PASS |
| Top4 + Other tie-breaks alphabetically | ["Nova Large","Orion 2","Sage Mini","Atlas Code","其他 · 2"] | ["Nova Large","Orion 2","Sage Mini","Atlas Code","其他 · 2"] | PASS |
| fixed 3-minute output throughput window | 10 | 10 | PASS |
| detail query hidden by default | popover-hidden | popover-hidden | PASS |
| quality cohorts are not pooled | {"quality":"derived","value":5} | {"quality":"derived","value":5} | PASS |
| orthogonal Agent AND Model filters | 2 | 2 | PASS |
| stale window older than 30s | stale | stale | PASS |
| absent window stays unavailable, not zero | absent | absent / unavailable | PASS |
| failed source does not contribute facts | 6 | 6 | PASS |
| schema change marks partial coverage | {"coverage":"partial","schemaPartials":6} | {"coverage":"partial","schemaPartials":6} | PASS |
| hidden popover stops detail snapshot builds | 1 | 1 | PASS |
| status-item light snapshots continue while hidden | 6 | > 1 | PASS |
| opening popover builds a detail snapshot | {"light":1,"detail":1} | {"light":">=1","detail":">=1"} | PASS |
| per-source queue never exceeds capacity | ["codex:0","claude:0"] | <= 32 | PASS |
| fact store is bounded | 64 | <= 200 | PASS |
| series buffer is bounded | 20 | <= 20 | PASS |
| queue shedding is counted | 336 | > 0 | PASS |
| bounded ingest of 400 events (ms) | 0.4015 | local measurement only | PASS |
| single query is accepted | true | true | PASS |
| serial query after release is accepted | true | true | PASS |
| query bound rejects overflow | query-bound | query-bound | PASS |
| high-volume facts stay within maxFacts | 20000 | <= 20000 | PASS |
| Top4 + Other reconstructs selected throughput | {"rankedSum":8365.111111111111,"liveValue":8365.111111111111} | equal within 1e-6 | PASS |
| 20k ingest wall time (ms) | 3.8785 | local measurement only — do not treat as a universal SLO | PASS |
| 20k drain wall time (ms) | 833.1277 | local measurement only — do not treat as a universal SLO | PASS |
| light snapshot rebuild (ms) | 4.8251 | local measurement; candidate A gate is < 5 ms | PASS |
| detail snapshot rebuild (ms) | 20.7158 | local measurement; candidate A gate is < 16 ms | PASS |
| heap used after 20k facts (MiB) | 33.2837 | local measurement only | PASS |
| public artifact privacy scan | [] | [] | PASS |

## Candidate budgets

### A. Menu-bar conservative (recommended)

- light: 1 Hz
- detail visible: 4 Hz
- detail hidden: 0 Hz
- queue/source: 256
- max facts: 20000
- max series points: 180
- degrade: Shed newest per source, keep last good light snapshot, mark coverage partial.

### B. Balanced live

- light: 2 Hz
- detail visible: 10 Hz
- detail hidden: 0 Hz
- queue/source: 1024
- max facts: 80000
- max series points: 600
- degrade: Coalesce live series to 2s bins after 3 minutes; still isolate source failure.

### C. Burst-tolerant

- light: 2 Hz
- detail visible: 10 Hz
- detail hidden: 0 Hz
- queue/source: 4096
- max facts: 250000
- max series points: 1800
- degrade: Keep more history; only if later retention evidence says 20k facts is too small.

## Unverified assumptions

- Real JSONL tail and OTLP ingest rates on a developer Mac.
- SQLite single-writer amplification versus this in-memory store.
- AppKit status-item and SwiftUI popover render cost.
- System VoiceOver announcement quality for live number changes.
