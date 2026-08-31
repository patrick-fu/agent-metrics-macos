# Agent Metrics

Agent Metrics is a native macOS menu bar app for inspecting local coding-agent activity without pretending that different measurements are interchangeable.

[简体中文](README.zh-CN.md) · [Website](https://patrick-fu.github.io/agent-metrics-macos/) · [GitHub Releases](https://github.com/patrick-fu/agent-metrics-macos/releases)

![Agent Metrics menu bar summary showing output throughput, token burn, active sessions, and data quality](website/assets/summary-popover-2x.png)

## What it is—and is not

Agent Metrics reads supported local coding-agent data, normalizes what can be compared, and keeps source boundaries visible. It is a menu bar observer, not a coding-agent runtime, a billing meter, a rate-limit meter, or a single cross-provider score.

The product currently targets local Codex and Claude Code activity. A value can be unavailable, stale, or partial; that is a result to interpret, not a zero to fill in.

## Metrics

| Metric | Definition | Important boundary |
| --- | --- | --- |
| **Output Throughput** | Observed output tokens for the selected agents and models divided by one shared sliding-window duration. Settings offers 3, 5, and 10 minute windows. | It is aggregate output throughput, not per-model-call TPS. |
| **Token Burn** | Normalized, mutually exclusive input and output token parts consumed over a fixed 600-second window. | It is not TPM or rate-limit usage; overlapping counters are not added together. |
| **Calls** | Distinct stable Model Call IDs in a sliding window, expressed per minute. | If stable IDs are unavailable, Calls remains unavailable rather than inferred from turns or content. |
| **Decode TPS** | Per-model-call decode rate excluding time to first token. | It needs usable request-level timing, output, and identity fields from Enhanced Telemetry. Without that correlation it remains unavailable. |

Quality, state, coverage, freshness, source authority, and definition version provide the context for a value. Compare only values with compatible definitions and coverage.

## Sources and boundaries

| Coding Agent | Default local channel | Enhanced channel boundary |
| --- | --- | --- |
| **Codex** | Persisted rollout usage observations can support aggregate output and token windows. They do not recover durable per-model-call completion boundaries. | Request-level observations are used only when their fields and identity can be verified. |
| **Claude Code** | Local transcript support is version-gated because its durable schema is not a public stable contract. | Supported request observations may be available through the local receiver; token metrics alone do not establish request timing or stable calls. |

Agent Metrics does not splice a partial observation from one channel with another channel's fields, or add a fallback observation after an enhanced observation has replaced it for the same identity and range.

## App surfaces

- **Summary** shows filtered output throughput, activity, performance availability, and source health.
- **Trends** shows Output Throughput plus Token Burn or Calls over time, with exact-value tables and visible metric metadata.
- **Settings** controls Launch at Login, the output window, menu bar cadence, Enhanced Telemetry, update checks, and entry points to the two detail surfaces.
- **Data & Diagnostics** can preview allowlisted diagnostics in memory, request one-time confirmation before copy/save, and prepare text for manual public-issue review. It does not submit an issue for you.
- **About & Updates** shows version, minimum macOS version, metric definitions, privacy/update boundaries, and a user-confirmed update check.

## Accessibility

The interface supports keyboard focus, Escape-based return paths, and non-color cues in Trends. The manual checklist covers keyboard and VoiceOver navigation through filters, trends tables, settings, diagnostics, reset confirmation, and reduced motion. It is a manual verification checklist, not a claim of final VoiceOver certification; see [`docs/accessibility-manual-checklist.md`](docs/accessibility-manual-checklist.md).

## Requirements and installation

Agent Metrics requires an Apple silicon Mac running macOS 14 or later.

**Public Beta** describes the product's maturity; it is not a GitHub or updater channel. When a release is available, download its `AgentMetrics-<version>.dmg` from GitHub Releases, open it, move `Agent Metrics.app` to Applications, and launch it. A release must complete the project's signing, notarization, stapling, and public-download checks before it is represented as such; this working tree does not itself establish that a future version has been released.

## Local data, privacy, and reset

Agent Metrics stores normalized usage facts in an app-owned local SQLite store. The app's stated network boundary is update checks against its configured update feed; diagnostics require your review before any external sharing.

The retention policy protects the most recent seven days. At warning or hard capacity thresholds, older data can be pruned and coverage can become partial. If the store remains at its hard limit, ingestion can pause; the app reports that condition rather than silently treating the range as complete.

Diagnostics use an allowlist. Reset Data removes app-owned telemetry and managed copies, including migration backups, observations, facts, rollups, cursors, watermarks, source state, opaque identities, diagnostics, runtime snapshots, and app-managed export copies. It preserves settings, Codex and Claude Code source logs, and external user-saved files. Cleanup and space reclamation can remain pending and retry later; uninstalling the app alone does not erase the telemetry store.

## Enhanced Telemetry

Enhanced Telemetry is off by default. When enabled, it starts this app's unauthenticated loopback receiver. Enable it only if you trust other local processes on the Mac. The receiver is app-owned: enabling it does not reconfigure your shell or environment variables, and it does not itself configure Claude Code. It is not a Claude-Code-only feature.

## Development and verification

Building from source requires Xcode 16+ and Swift 6.2 in addition to the app requirements above.

```sh
swift test
swift build
scripts/build-app.sh
open ".build/release/Agent Metrics.app"
```

Build the Pages artifact into an empty temporary directory:

```sh
site_output="$(mktemp -d "${TMPDIR:-/tmp}/agent-metrics-site.XXXXXX")"
scripts/build-site.sh "$site_output"
open "$site_output/index.html"
swift test --filter PagesSiteContractTests
```

The Pages build has no package-install step or external runtime. `website/site-manifest.txt` is its allowlist; the build derives displayed version, build, and download URL from the newest `website/updates/appcast.xml` item.

## Releases, Pages, and identity

The appcast is the production updater feed and preserves signed historical items. Public Beta does not create a separate updater channel: every appcast item must correspond to a published, non-prerelease GitHub Release. The legacy feed at `https://patrick-fu.github.io/coding-agent-metrics/updates/appcast.xml` remains for installed clients; Pages deployment stages the primary site and legacy feed separately. See [`docs/release/pages-deployment.md`](docs/release/pages-deployment.md) and [`docs/release/public-beta-runbook.md`](docs/release/public-beta-runbook.md).

The public app name is **Agent Metrics** and the bundle is `Agent Metrics.app`. `dev.codingagentmetrics.app`, legacy `CodingAgentMetrics` module/resource identifiers, and the Sparkle trust configuration are compatibility identifiers for installed-data ownership and updater continuity.

## Troubleshooting and known limits

- **Partial, stale, or unavailable values:** inspect the shown quality, state, coverage, freshness, source authority, and recommended action before comparing values.
- **Missing Decode TPS or Calls:** the required request timing or stable Model Call IDs may not be available. Do not treat a turn-level value as a per-call substitute; review the Enhanced Telemetry trust boundary before enabling it.
- **Capacity warning or paused ingestion:** inspect Data & Diagnostics. Reset Data is the recovery action when the store cannot resume ingestion at the hard limit.
- **No local observations:** wait for a supported source to produce data, or reduce a filter that excludes available observations.
- **Site or download mismatch:** build the Pages artifact locally and verify the newest appcast item's version, build, and enclosure before deployment.
- **Older app after a data migration:** this project does not promise database downgrade compatibility; prefer a higher-build roll-forward when compatibility is unknown.

This repository has no `LICENSE` file. Do not infer a license or describe the project as open source.
