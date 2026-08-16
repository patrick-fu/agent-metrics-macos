# Resource budget candidates

THROW AWAY decision aid for [Validate bounded runtime and rendering behavior](https://github.com/patrick-fu/coding-agent-metrics/issues/7).

Measured Node timings in `benchmark-results.md` are one local in-memory run. They are not AppKit, SQLite, or fleet facts. The numbers below are **candidate acceptance gates**, not observed production SLOs.

## A. Menu-bar conservative — recommended

Use this as the P0 default.

| Knob | Candidate gate |
| --- | --- |
| Status-item light snapshot | 1 Hz |
| Detail snapshot while popover visible | 4 Hz |
| Detail snapshot while popover hidden | 0 |
| Queue per source | 256 |
| Max events drained per source per tick | 128 |
| Fact store | 20,000 facts |
| Live series | 180 points |
| Inflight queries | 1 |
| Light build | candidate < 5 ms |
| Detail build | candidate < 16 ms |

Degrade: shed newest on the noisy source only; keep the last good light snapshot; mark coverage partial; never stall the other source; during a burst rebuild at most one light and one detail snapshot per interval.

Why recommend: a menu-bar app spends almost all of its life with the popover closed. The important budget is idle status-item cost plus failure isolation, not chart smoothness.

Local repeats on this machine, 20k in-memory facts, five runs:

- light rebuild: 1.5–4.8 ms (candidate A < 5 ms is tight but usually inside)
- detail rebuild: 18.6–25.1 ms (**misses** the 16 ms visible-frame candidate every run)
- 20k drain including per-tick snapshot rebuilds: 0.79–1.28 s
- heap used: about 33 MiB

That is a reason to keep A's cadence, coalesce burst rebuilds to at most one snapshot per interval, and require a windowed index or pre-aggregation so the UI thread does not scan the whole fact store. It is not a reason to raise idle refresh rates.

## B. Balanced live

| Knob | Candidate gate |
| --- | --- |
| Light snapshot | 2 Hz |
| Detail snapshot while visible | 10 Hz |
| Detail snapshot while hidden | 0 |
| Queue per source | 1,024 |
| Fact store | 80,000 facts |
| Live series | 600 points |

Degrade: after three minutes, coalesce series into 2-second bins. Still isolate source failure.

Tradeoff: smoother visible charts, higher idle memory and more SQLite writer pressure. Choose only if A makes the visible drill-downs feel stale on a developer Mac.

## C. Burst-tolerant

| Knob | Candidate gate |
| --- | --- |
| Light snapshot | 2 Hz |
| Detail snapshot while visible | 10 Hz |
| Queue per source | 4,096 |
| Fact store | 250,000 facts |
| Live series | 1,800 points |

Degrade: keep more history before eviction.

Tradeoff: better burst absorption, worse idle memory. Do not pick this until a later retention measurement shows 20,000 facts is too small.

## Unverified assumptions

- Real JSONL tail and optional OTLP ingest rates on an Apple-silicon developer Mac.
- SQLite single-writer WAL amplification versus this in-memory FactStore.
- AppKit status-item and SwiftUI popover render cost, including VoiceOver live-region chatter.
- Whether 256-per-source shedding drops useful live tokens during a legitimate high-output session.

## Suggested acceptance statement

If A is accepted:

> Accept candidate A as the P0 resource budget: 1 Hz light snapshots, 4 Hz detail snapshots only while the popover is visible, 256 events per source queue, 20k facts, 180 series points, one inflight query, newest-shed degradation, burst snapshot coalescing, source isolation, and a windowed or pre-aggregated detail path so the UI thread does not scan the full fact store. Treat the Node timings as local evidence, not a fleet SLO. System VoiceOver remains a manual check.
