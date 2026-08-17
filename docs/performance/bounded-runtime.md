# Bounded runtime performance report

This report measures the production Swift/SQLite snapshot path and the real AppKit/SwiftUI summary render path with synthetic data. It contains no user telemetry, local source locators, credentials, device identifiers, or private data.

## Method

- Hardware: Apple-silicon Mac; exact model, host name, serial number, and user identity intentionally omitted.
- Platform: macOS 14 or newer.
- Build: Swift release build.
- Commands: `swift run -c release CodingAgentMetricsBenchmark 100` and `swift run -c release CodingAgentMetricsApp --benchmark-render 100`.
- Workload: 20,000 synthetic canonical Usage Facts across two Coding Agents and six Model Identities, spread across the ten-minute live window. Token parts and stable Model Call identities are present.
- Measurement: five warm-ups, then 100 wall-clock samples per path. Percentiles use nearest-rank.
- Light path: indexed SQLite bounded-window read plus `LiveSampler`, authority selection, light KPI, filter-option, and empty performance-window construction.
- Detail path: indexed SQLite bounded-window read plus authority selection, pre-aggregation, Top 4 + Other, bounded series, and accessible-table construction.
- Candidate references are comparison points, not established SLOs. Outcome is determined from p95 and a miss stays a miss.

## Results

| Path | Samples | p50 | p95 | Max | Candidate reference | Outcome |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| Light snapshot | 100 | 154.954 ms | 163.819 ms | 175.587 ms | < 5 ms | **MISS** |
| Detail snapshot | 100 | 180.225 ms | 195.868 ms | 210.865 ms | < 16 ms | **MISS** |

Both candidate references were missed. The implementation therefore keeps the references as candidates and does not relabel or relax them.

The observed detail maximum of 210.865 ms stayed below one 250 ms scheduler interval. The runtime contract still guarantees **at most** 4 Hz, one detail query in flight, and no queued detail backlog; this finite local measurement is not a sustained 4 Hz guarantee.

Thirty additional profiling samples separated the applicable path into indexed SQLite decoding and in-memory builders:

| Stage | p50 | p95 |
| --- | ---: | ---: |
| SQLite 20,000-Fact bounded query | 49.646 ms | 50.911 ms |
| Light snapshot builder | 104.550 ms | 118.105 ms |
| Trend snapshot builder | 128.878 ms | 134.765 ms |

This profiling was used to remove repeated authority-cohort construction from the light path and per-bucket Fact scans from the trend path. The remaining misses are recorded rather than extending this ticket into a new storage/pre-aggregation design.

## AppKit/SwiftUI render result

The release App executable was run in its bounded benchmark mode for five warm-ups and 100 measured samples. Each sample instantiates the real `SummaryPopoverView` and `NSHostingView`, performs fitting and AppKit layout, and renders the view into an AppKit bitmap cache. The input is a synthetic Light Snapshot with 12 Usage Facts across two Coding Agents and three Model Identities.

| Path | Samples | p50 | p95 | Max |
| --- | ---: | ---: | ---: | ---: |
| Summary popover composition + layout + bitmap render | 100 | 78.114 ms | 87.294 ms | 95.008 ms |

No candidate SLO exists for this render measurement, so no MEET/MISS label is assigned. The measurement includes production SwiftUI view composition, `NSHostingView` layout, and AppKit bitmap rendering. It does not claim to measure WindowServer compositing, panel presentation animation, status-item interaction latency, or display refresh latency. Ordinary App launch remains unchanged; benchmark mode returns after printing aggregate timings and does not create the status item, run the event loop, scan local sources, or enable telemetry.

## Reproduction and interpretation

`CodingAgentMetricsBenchmark` creates its synthetic SQLite database under the system temporary directory, prints aggregate timing only, and removes the temporary directory afterward. `CodingAgentMetricsApp --benchmark-render` constructs only synthetic in-memory snapshot data and prints aggregate timing only. Results are local evidence, not fleet-wide guarantees. The runtime benchmark includes the maximum 20,000-Fact query working set, so it is intentionally a high-volume workload rather than a typical-session claim.
