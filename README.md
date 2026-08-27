# Agent Metrics

Apple-silicon macOS 14+ menu bar app for local Codex and Claude Code metrics. It normalizes local usage metadata into a compact Output Throughput summary without storing prompt, code, or tool-result bodies.

## Local build and test

Requires Apple silicon, macOS 14+, and Xcode 16+ / Swift 6.2.

```sh
swift test
swift build
scripts/build-app.sh
open ".build/release/Agent Metrics.app"
```

There is no GitHub Actions workflow. All automated checks run locally.

## Website

The maintainable GitHub Pages source lives in `website/` on `main`. Build it into an empty temporary directory and open the result locally:

```sh
site_output="$(mktemp -d "${TMPDIR:-/tmp}/agent-metrics-site.XXXXXX")"
scripts/build-site.sh "$site_output"
open "$site_output/index.html"
```

The build has no package install or external runtime dependency. It copies the static site, the real app screenshot, `.nojekyll`, and `updates/appcast.xml` into a deterministic Pages artifact. Site contracts run with the lifecycle tests:

```sh
swift test --filter PagesSiteContractTests
```

`website/updates/appcast.xml` is the canonical production feed. Its signed 0.1.1–0.2.0 history must remain intact; never add a synthetic enclosure to the published feed.

Deployment is deliberately local rather than CI-driven. It requires a clean local checkout of the legacy `patrick-fu/coding-agent-metrics` repository with a local `gh-pages` branch. First inspect both worktree diffs:

```sh
scripts/deploy-pages.sh --legacy-repo /path/to/coding-agent-metrics
```

After reviewing the primary site and legacy feed diff, publish both branches explicitly:

```sh
scripts/deploy-pages.sh --legacy-repo /path/to/coding-agent-metrics --publish
```

The script builds from committed `main`, verifies the public 0.2.0 artifact before publishing, then stages the primary site and the same frozen feed in separate temporary worktrees. It pushes the primary Pages branch first and the legacy updater feed last.

## Bundle identity

The public product is **Agent Metrics**, and the local app bundle is `Agent Metrics.app`.

`dev.codingagentmetrics.app` is the frozen reverse-DNS identifier. The legacy `CodingAgentMetrics` Swift module, executable, and bundled-resource names also remain technical identifiers. They preserve installed-app ownership, Application Support compatibility, and existing internal resource wiring while only the public-facing name changes.

Updates use `https://patrick-fu.github.io/coding-agent-metrics/updates/appcast.xml`, and the configured Sparkle trust key remains unchanged so existing signed clients keep accepting releases. The target public repository is `patrick-fu/agent-metrics-macos`; release assets use `AgentMetrics-<version>.dmg`.

The packaged app is an `LSUIElement` status-item/panel shell. The SwiftUI popover is 440 pt wide and reads only a `LightSnapshot` from `TelemetryRuntime`.
