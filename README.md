# Coding Agent Metrics

Apple-silicon macOS 14+ menu bar app. This repository currently contains the first production-shaped slice: a synthetic Codex-style fixture through SQLite into a compact Output Throughput summary.

## Local build and test

Requires Apple silicon, macOS 14+, and Xcode 16+ / Swift 6.2.

```sh
swift test
swift build
scripts/build-app.sh
open .build/release/CodingAgentMetrics.app
```

There is no GitHub Actions workflow. All automated checks run locally.

## Bundle identity

`dev.codingagentmetrics.app` is the frozen reverse-DNS identifier. A later product-name change must not change it.

The packaged app is an `LSUIElement` status-item/panel shell. The SwiftUI popover is 440 pt wide and reads only a `LightSnapshot` from `TelemetryRuntime`.
