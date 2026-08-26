# Agent Metrics

Apple-silicon macOS 14+ menu bar app. This repository currently contains the first production-shaped slice: a synthetic Codex-style fixture through SQLite into a compact Output Throughput summary.

## Local build and test

Requires Apple silicon, macOS 14+, and Xcode 16+ / Swift 6.2.

```sh
swift test
swift build
scripts/build-app.sh
open ".build/release/Agent Metrics.app"
```

There is no GitHub Actions workflow. All automated checks run locally.

## Bundle identity

The public product is **Agent Metrics**, and the local app bundle is `Agent Metrics.app`.

`dev.codingagentmetrics.app` is the frozen reverse-DNS identifier. The legacy `CodingAgentMetrics` Swift module, executable, and bundled-resource names also remain technical identifiers. They preserve installed-app ownership, Application Support compatibility, and existing internal resource wiring while only the public-facing name changes.

Updates use `https://patrick-fu.github.io/coding-agent-metrics/updates/appcast.xml`, and the configured Sparkle trust key remains unchanged so existing signed clients keep accepting releases. The target public repository is `patrick-fu/agent-metrics-macos`; release assets use `AgentMetrics-<version>.dmg`.

The packaged app is an `LSUIElement` status-item/panel shell. The SwiftUI popover is 440 pt wide and reads only a `LightSnapshot` from `TelemetryRuntime`.
