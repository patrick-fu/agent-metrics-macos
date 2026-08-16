# Bounded runtime local results

THROW AWAY. Synthetic fixtures only.

Measured numbers are from one local Node process and an in-memory stand-in. They are not AppKit, SQLite, or fleet facts. Suggested gates are candidate acceptance thresholds for Patrick to accept or revise. PASS is only for correctness assertions. Candidate gates are MEET or MISS. Ungated timings are MEASURED.

Result key: `PASS`/`FAIL` = correctness assertion. `MEET`/`MISS` = candidate gate. `MEASURED` = ungated local timing.

| Check | Kind | Measured | Suggested / expected | Result |
| --- | --- | --- | --- | --- |
| decode TPS v1 formula | assertion | 60 | (output_total - 1) / (duration - TTFT) = 60 | PASS |
| decode TPS unavailable without call identity | assertion | unavailable | unavailable | PASS |
| decode TPS excludes retries | assertion | unavailable | unavailable | PASS |
| Top4 + Other tie-breaks alphabetically | assertion | ["Nova Large","Orion 2","Sage Mini","Atlas Code","其他 · 2"] | ["Nova Large","Orion 2","Sage Mini","Atlas Code","其他 · 2"] | PASS |
| fixed 3-minute output throughput window | assertion | 10 | 10 | PASS |
| detail query hidden by default | assertion | popover-hidden | popover-hidden | PASS |
| quality cohorts are not pooled | assertion | {"quality":"derived","value":5} | {"quality":"derived","value":5} | PASS |
| orthogonal Agent AND Model filters | assertion | 2 | 2 | PASS |
| stale window older than 30s | assertion | stale | stale | PASS |
| absent window stays unavailable, not zero | assertion | absent | absent / unavailable | PASS |
| failed source does not contribute facts | assertion | 6 | 6 | PASS |
| schema change marks partial coverage | assertion | {"coverage":"partial","schemaPartials":6} | {"coverage":"partial","schemaPartials":6} | PASS |
| hidden popover stops detail snapshot builds | assertion | 1 | 1 | PASS |
| status-item light snapshots continue while hidden | assertion | 6 | > 1 | PASS |
| opening popover builds a detail snapshot | assertion | {"light":1,"detail":1} | {"light":">=1","detail":">=1"} | PASS |
| per-source queue never exceeds capacity | assertion | ["codex:0","claude:0"] | <= 32 | PASS |
| fact store is bounded | assertion | 64 | <= 200 | PASS |
| series buffer is bounded | assertion | 20 | <= 20 | PASS |
| queue shedding is counted | assertion | 336 | > 0 | PASS |
| bounded ingest of 400 events (ms) | measurement | 0.1026 | local measurement only | MEASURED |
| single query is accepted | assertion | true | true | PASS |
| serial query after release is accepted | assertion | true | true | PASS |
| query bound rejects overflow | assertion | query-bound | query-bound | PASS |
| high-volume facts stay within maxFacts | assertion | 20000 | <= 20000 | PASS |
| Top4 + Other reconstructs selected throughput | assertion | {"rankedSum":8365.111111111111,"liveValue":8365.111111111111} | equal within 1e-6 | PASS |
| 20k ingest wall time (ms) | measurement | 3.9688 | local measurement only — do not treat as a universal SLO | MEASURED |
| 20k drain wall time (ms) | measurement | 870.0040 | local measurement only — do not treat as a universal SLO | MEASURED |
| light snapshot rebuild (ms) | candidate-gate | 2.1569 | candidate A gate < 5 ms | MEET |
| detail snapshot rebuild (ms) | candidate-gate | 19.1425 | candidate A gate < 16 ms | MISS |
| heap used after 20k facts (MiB) | measurement | 32.3557 | local measurement only | MEASURED |
| candidate-miss classifier rejects pass | assertion | {"kind":"candidate-gate","status":"MISS","ok":false,"outcome":"candidate-miss","gateMs":16} | {"status":"MISS","ok":false,"outcome":"candidate-miss"} | PASS |
| candidate-met classifier | assertion | {"kind":"candidate-gate","status":"MEET","ok":true,"outcome":"candidate-met","gateMs":5} | {"status":"MEET","ok":true,"outcome":"candidate-met"} | PASS |
| measurement classifier is not pass | assertion | {"kind":"measurement","status":"MEASURED","ok":null,"outcome":"measured-only"} | {"status":"MEASURED","ok":null} | PASS |
| labeling: bounded ingest of 400 events (ms) | assertion | {"status":"MEASURED","ok":null} | MEASURED and not ok:true | PASS |
| labeling: 20k ingest wall time (ms) | assertion | {"status":"MEASURED","ok":null} | MEASURED and not ok:true | PASS |
| labeling: 20k drain wall time (ms) | assertion | {"status":"MEASURED","ok":null} | MEASURED and not ok:true | PASS |
| labeling: light snapshot rebuild (ms) | assertion | {"status":"MEET","ok":true,"outcome":"candidate-met"} | {"kind":"candidate-gate","status":"MEET","ok":true,"outcome":"candidate-met","gateMs":5} | PASS |
| labeling: detail snapshot rebuild (ms) | assertion | {"status":"MISS","ok":false,"outcome":"candidate-miss"} | {"kind":"candidate-gate","status":"MISS","ok":false,"outcome":"candidate-miss","gateMs":16} | PASS |
| labeling: heap used after 20k facts (MiB) | assertion | {"status":"MEASURED","ok":null} | MEASURED and not ok:true | PASS |
| public artifact privacy scan | assertion | [] | [] | PASS |

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
