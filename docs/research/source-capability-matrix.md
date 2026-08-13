# Source Capability Matrix

Research date: 2026-08-14.

Scope: Codex CLI/Desktop and Claude Code CLI as observed through official documentation and public upstream source. No local fixtures, logs, prompts, or private artifacts are referenced.

Notation: each claim is marked **[fact]** (cited from official docs or public source), **[inference]** (derived from combining facts), or **[unverified]** (plausible but not confirmed by a primary source).

---

## 1. Sources consulted

### Codex CLI

| Source | URL |
|--------|-----|
| Configuration Reference (`config.toml`) | <https://learn.chatgpt.com/codex/config-file/config-reference> |
| Changelog v0.143.0–v0.147.0 | <https://learn.chatgpt.com/docs/changelog> |
| App Server API overview | <https://learn.chatgpt.com/docs/app-server> |
| Responses API create method | <https://developers.openai.com/api/reference/resources/responses/methods/create> |
| Rollout persistence policy at the reviewed upstream revision | <https://github.com/openai/codex/blob/1c9f890c051dbd091f1827ecd0149d0f43001b5f/codex-rs/rollout/src/policy.rs> |
| Protocol types at the reviewed upstream revision | <https://github.com/openai/codex/blob/2edad72de3e4fb12a7519027d5eb3cbda45eea6c/codex-rs/protocol/src/protocol.rs> |

### Claude Code CLI

| Source | URL |
|--------|-----|
| Monitoring (OpenTelemetry) | <https://code.claude.com/docs/en/monitoring-usage> |
| Manage costs effectively | <https://code.claude.com/docs/en/costs> |

---

## 2. Local data channels

### 2.1 Codex CLI — rollout files

Codex persists each non-ephemeral thread as a JSONL "rollout" file. The App Server API describes thread/archive and thread/unarchive as moving rollout files between active and archived session directories. **[fact: App Server API overview]**

Each rollout line is a structured item. The current persistence policy stores turn lifecycle events, thread settings, accumulated `TokenCount` events, and selected response/content items. **[fact: rollout persistence policy]**

- **Turn items** persisted for paginated threads (PR #30188, v0.144.0 changelog). **[fact]**
- **Response items** include a `turn_id` on ResponseItem metadata (PR #28360, v0.143.0 changelog). **[fact]**
- **Exact per-response usage** is exposed in live raw app-server events (PR #32985, v0.145.0 changelog), but `RawResponseCompleted` is explicitly transient and is not persisted to rollout files. **[fact: protocol type + rollout persistence policy]**
- **Cache-write token usage** tracked and added to the raw response schema (PR #33454, PR #33500, v0.145.0 changelog). **[fact]**
- **Rollout budget units** captured from response usage (PR #36641, PR #36715, v0.147.0 changelog). **[fact]**
- **Turn start times** included in terminal turn events (PR #32263, v0.145.0 changelog). **[fact]**
- Thread and turn IDs are UUID7 (PR #27714, v0.143.0 changelog). **[fact]**

Persisted identity includes thread and turn UUID7 values plus the effective `model` in turn context/settings items. A durable model-call identifier is not publicly documented. **[fact + inference]**

This distinction is decisive: a live app-server subscriber can receive exact per-response usage, while a collector that only tails rollout files receives accumulated/replayed `TokenCount` observations and must not describe them as exact per-response records. **[fact + inference]**

### 2.2 Claude Code CLI — transcript files

Claude Code stores session transcripts as JSONL files under `~/.claude/projects/*/*.jsonl`. The costs doc references these files directly: *"session transcripts, the top-level `~/.claude/projects/*/*.jsonl` files"*. **[fact: costs doc]**

The `/usage` command documentation shows the aggregate usage parts available per model. The following is a synthetic rendering of that documented shape, not a captured usage log:

```text
claude-sonnet-4-6: 1.2k input, 5.3k output, 940.0k cache read, 50.0k cache write
```

This maps to the Anthropic Messages API usage object fields: `input_tokens`, `output_tokens`, `cache_creation_input_tokens` (cache write), `cache_read_input_tokens` (cache read). **[fact: costs doc + Anthropic API convention]**

The public documentation says the transcript entry format is internal to Claude Code and changes between versions. It documents `message.uuid` as a join key from OTel events, but it does not publish a stable per-entry schema for model identity, token fields, call boundaries, or timing. Those local fields therefore remain **unverified**, not P0 facts, until the sanitized-fixture prototype validates a versioned parser. **[fact + inference: monitoring doc]**

Transcripts are cleaned up after `cleanupPeriodDays` (default 30). **[fact: costs doc]**

---

## 3. OpenTelemetry channels

### 3.1 Codex CLI OTel

Configured via `config.toml`:

| Key | Values | Source |
|-----|--------|--------|
| `otel.trace_exporter` | `none` / `otlp-http` / `otlp-grpc` | config.toml docs **[fact]** |
| `otel.metrics_exporter` | `none` / `statsig` / `otlp-http` / `otlp-grpc` | config.toml docs **[fact]** |
| `otel.exporter` | `none` / `otlp-http` / `otlp-grpc` | config.toml docs **[fact]** |
| `otel.log_user_prompt` | boolean, default off | config.toml docs **[fact]** |
| `otel.environment` | string tag, default `dev` | config.toml docs **[fact]** |

Key telemetry signals emitted:

- **Per-request TTFT** (PR #30883, v0.143.0 changelog: *"emit per-request TTFT completion telemetry"*). **[fact]**
- **Service tier and reasoning effort** in OTel (PR #29155, v0.143.0 changelog). **[fact]**
- **Responses WebSocket timing telemetry** improvements (PR #32256, v0.145.0 changelog). **[fact]**

Default `metrics_exporter` is `statsig`, which sends to OpenAI's internal analytics, not a user-controllable OTLP endpoint. **[fact]**

### 3.2 Claude Code CLI OTel

Configured via environment variables:

| Variable | Values | Source |
|----------|--------|--------|
| `CLAUDE_CODE_ENABLE_TELEMETRY` | `1` (required to enable) | monitoring doc **[fact]** |
| `CLAUDE_CODE_ENHANCED_TELEMETRY_BETA` | `1` (also required for traces) | monitoring doc **[fact]** |
| `OTEL_METRICS_EXPORTER` | `otlp` / `prometheus` / `console` / `none` | monitoring doc **[fact]** |
| `OTEL_LOGS_EXPORTER` | `otlp` / `console` / `none` | monitoring doc **[fact]** |
| `OTEL_TRACES_EXPORTER` | beta; same OTLP options implied | monitoring doc **[fact]** |
| `OTEL_LOG_USER_PROMPTS` | `1` to enable prompt content (default off) | monitoring doc **[fact]** |
| `OTEL_LOG_ASSISTANT_RESPONSES` | `1` to enable response text (default off; requires v2.1.193+) | monitoring doc **[fact]** |
| `OTEL_LOG_TOOL_DETAILS` | `1` to enable tool params (default off) | monitoring doc **[fact]** |
| `OTEL_LOG_TOOL_CONTENT` | `1` to enable tool I/O in trace spans (default off) | monitoring doc **[fact]** |

Metrics emitted:

| Metric | Attributes | Source |
|--------|-----------|--------|
| `claude_code.token.usage` | `type` (input/output/cacheRead/cacheCreation), `model`, `session.id`, `skill.name`, `plugin.name`, `agent.name` | monitoring doc **[fact]** |
| `claude_code.cost.usage` | `model`, `session.id`, etc. | monitoring doc **[fact]** |
| `claude_code.session.count` | `session.id`, etc. | monitoring doc **[fact]** |
| `claude_code.lines_of_code.count` | `model` (from v2.1.172) | monitoring doc **[fact]** |

Events emitted: `user_prompt`, `assistant_response`, `tool_result`, `tool_decision`, `api_request`, `api_error`, `mcp_server_connection`, `auth`, `permission_mode_changed`. **[fact]**

Key dedup guarantee: *"Claude Code counts each streaming response toward the cost and token metrics exactly once, including when a gateway or proxy streams usage progressively across multiple frames."* (Fixed in v2.1.214.) **[fact]**

The `claude_code.llm_request` trace span (beta) documents request `duration_ms`, `ttft_ms`, all four token parts, model, request identifiers, and retry count. The `claude_code.api_request` event documents duration, all four token parts, model, and request identifiers, but not TTFT. **[fact]**

---

## 4. Capability matrix — P0 metrics

### P0 metrics (from CONTEXT.md)

- Output throughput (system output / window seconds)
- Decode TPS (per model call, excludes TTFT)
- Token burn/min (normalized disjoint token parts / window minutes)
- TTFT (time to first token)
- E2E latency (request wall-clock start to final output)
- Calls/min (deduplicated model call count / window minutes)

### Matrix

| Metric | Codex local rollout | Codex OTel | Claude local JSONL | Claude OTel metrics | Claude OTel event/trace |
|--------|--------------------|-----------|--------------------|-----------------------|--------------------------|
| **Output throughput** | derived from measured aggregate `output_tokens` | derived from measured per-response output | unverified pending versioned transcript fixture | derived from measured token counter | derived from measured request output |
| **Decode TPS** | unavailable per model call | unverified: public OTel fields do not establish a stable co-key for duration, TTFT, output, and response identity | unavailable | unavailable (no timing) | derived from measured co-keyed fields in the beta `llm_request` span; unavailable from events alone |
| **Token burn/min** | derived with partial coverage: cache-write disjointness is unverified | derived with partial coverage for the same reason | unverified pending versioned transcript fixture | derived from measured disjoint `type` values | derived from four measured disjoint request token fields |
| **TTFT** | measured at turn level where persisted `time_to_first_token_ms` is present; unavailable per model call | measured per request (`ttft_ms`) | unavailable | unavailable | measured per request (`ttft_ms`) |
| **E2E latency** | measured at turn level where persisted `duration_ms` is present | measured per request | unavailable | unavailable | measured per request (`duration_ms`); trace also exposes turn interaction duration |
| **Calls/min** | unavailable (exact raw completion events are not persisted) | unavailable from documented OTel alone; measured live app-server completions can support it | unverified pending versioned transcript fixture | unavailable from token metrics alone | derived by counting distinct request identities in events/traces |

Quality classification rationale:

- **Codex local**: persisted `TokenCount` observations can support aggregate output and token windows, but the exact per-response completion event is transient. Turn timing must not be relabelled as model-call timing. **[fact + inference]**
- **Codex OTel**: per-request TTFT telemetry exists, but the cited public event fields do not establish a stable join to duration, output count, and response identity. Do not claim Decode TPS or Calls/min from OTel until that correlation is verified. **[fact + inference]**
- **Claude local**: public docs intentionally treat the transcript schema as internal and version-specific. P0 field availability stays unverified until sanitized fixtures establish a version gate. **[fact]**
- **Claude OTel metrics**: token usage has disjoint `type` values, but metrics alone have no request timing. Calls/min requires an exporter representation that preserves request-sized points; an aggregated counter without request identities is insufficient for dedup. **[fact + inference]**
- **Claude OTel events/traces**: both document request duration, token parts, and identifiers; TTFT is documented only on the beta `llm_request` span. These are measured request observations when their respective channels are enabled. **[fact]**

---

## 5. Token counter and subset semantics

### 5.1 Codex (Responses API usage object)

Fields documented from the Responses API schema and Codex public source:

| Field | Meaning | Subset of? |
|-------|---------|-----------|
| `input_tokens` | Total input tokens processed | — |
| `cached_input_tokens` | Input tokens served from cache | subset of `input_tokens` |
| `output_tokens` | Total output tokens generated | — |
| `reasoning_output_tokens` | Output tokens consumed by reasoning | subset of `output_tokens` |
| `total_tokens` | input_tokens + output_tokens | sum of the two |
| `cache_write_input_tokens` | Input tokens written to cache (PR #33500) | relationship to `input_tokens` unverified |

Normalization for disjoint burn:

```text
input_uncached = input_tokens − cached_input_tokens
cache_read     = cached_input_tokens
cache_write    = unavailable as a disjoint part until its overlap is verified
output_visible = output_tokens − reasoning_output_tokens
reasoning      = reasoning_output_tokens
```

Critical caveat: `cached_input_tokens` and `reasoning_output_tokens` are subsets; adding either to its parent double-counts. `cache_write_input_tokens` was added in v0.145.0 and its relationship to `input_tokens` is not documented, so a disjoint total that includes it is unavailable until verified. **[fact + inference]**

### 5.2 Claude Code (Anthropic Messages API usage object)

Fields from the Claude OTel monitoring doc:

| Field | Meaning | Subset of? |
|-------|---------|-----------|
| `input_tokens` | Input tokens processed | — |
| `cache_creation_input_tokens` | Tokens written to cache | additive to `input_tokens` (billed separately) |
| `cache_read_input_tokens` | Tokens served from cache | replaces uncached input for those tokens |
| `output_tokens` | Output tokens generated (includes thinking) | — |

Normalization for disjoint burn:

```text
input_uncached = input_tokens                 [Anthropic API: input_tokens excludes cached]
cache_read     = cache_read_input_tokens
cache_write    = cache_creation_input_tokens
output_visible = unavailable as a separate part
reasoning      = unavailable as a separate part
```

Critical difference from OpenAI: Anthropic's `cache_creation_input_tokens` and `cache_read_input_tokens` are disjoint from `input_tokens`, not subsets. The `input_tokens` field counts only uncached input. Adding them directly is correct for total burn. **[fact: Anthropic billing model — cache tokens are billed and counted separately from uncached input]**

Thinking/reasoning tokens: Anthropic bills extended thinking as output tokens, and the standard usage object does not separate visible output from reasoning output. **[inference: costs doc says "Thinking tokens are billed as output tokens" but usage breakdown shows only a single output total]**

### 5.3 Streaming dedup

Claude Code guarantees single counting per streaming response (v2.1.214+). Before that version, multi-frame streams could inflate counts. **[fact]**

Codex rollout files persist accumulated `TokenCount` events rather than exact raw completions. A local parser therefore needs cumulative-delta and replay handling; it cannot count content items as model calls. **[fact + inference]**

---

## 6. Authority contract — one channel per capability

### Principle

For each fully qualified `(source, capability, granularity)` tuple, exactly one channel is authoritative. A higher-fidelity channel replaces a lower-fidelity observation only when identity and granularity match; otherwise the differently defined observations coexist and are never summed as equivalents.

### Codex authority table

| Capability | Authority (default) | Authority (enhanced) | Rule |
|-----------|--------------------|-----------------------|------|
| Token counts | Local rollout `TokenCount` (aggregate) | Live app-server raw completion (per response) | Select one whole observation granularity; never add response parts to the rollout aggregate |
| TTFT | Local rollout turn timing | OTel TTFT (per request) | Turn TTFT is not a fallback for request TTFT; both may coexist as differently defined capabilities |
| Decode TPS | unavailable | unavailable until OTel/live fields have a verified common request identity | Requires co-keyed response duration, TTFT, output count, and identity |
| Model identity | Rollout turn context/settings | OTel/live event attributes after correlation is verified | The authority must be selected with the same observation as usage/timing |
| Session/turn identity | Rollout UUID7 | — | Single source |

### Claude authority table

| Capability | Authority (default) | Authority (enhanced) | Rule |
|-----------|--------------------|-----------------------|------|
| Token counts | Local JSONL (only after versioned fixture validation) | OTel `api_request` event or `llm_request` span | Select exactly one complete four-part request observation; do not splice parts from local and OTel channels |
| TTFT | unavailable | OTel `llm_request.ttft_ms` span | Enhanced value is measured and request-scoped; `api_request` events do not include TTFT |
| Decode TPS | unavailable | OTel `llm_request` span (derived from measured fields) | Requires co-keyed duration, TTFT, output count, and request identity |
| Model identity | Local JSONL only after fixture validation | OTel `model` attribute | The authority follows the selected request observation |
| Session/request identity | Local JSONL only after fixture validation | OTel `session.id` + `client_request_id`/`request_id` | Use request identity for dedup; session identity alone is insufficient |

### Fallback-replaces-not-adds

When transitioning from local-only to OTel-enhanced:

1. Authority is selected for a complete `(source, capability, observation identity, time range)`; replacement requires the same capability and granularity.
2. A selected observation comes wholly from one channel. Never splice token parts across channels or sum local and enhanced observations for the same identity.
3. When a measured enhanced observation replaces an estimate for the same identity, quality changes to `measured`; the superseded record remains non-contributing.
4. If the enhanced channel stops, fallback applies only to new non-overlapping observations. It never retroactively re-adds local records already replaced.
5. Coverage is `partial` when a fallback lacks a required disjoint part or per-call boundary; missing fields are `unavailable`, never zero.

---

## 7. Timing precision and export latency

| Source | Channel | Timestamp precision | Export latency | Version gate |
|--------|---------|--------------------|----------------|-------------|
| Codex | Rollout JSONL | Turn `started_at`, `completed_at`, `duration_ms`, and turn TTFT when present | Append timing is implementation-dependent; completion fields arrive at turn end | v0.145.0+ for documented turn timing |
| Codex | OTel | Per-request TTFT (PR #30883) | Depends on exporter; OTLP gRPC/HTTP configurable | v0.143.0+ for TTFT telemetry |
| Claude | Local JSONL | Internal, version-specific transcript schema | Append timing not a stable public contract | Requires versioned fixture validation |
| Claude | OTel metrics | Aggregated per export interval (default 60s; configurable) | `OTEL_METRIC_EXPORT_INTERVAL` default 60000ms | All OTel-enabled versions |
| Claude | OTel events | Per-event timestamps | `OTEL_LOGS_EXPORT_INTERVAL` default 5000ms | All OTel-enabled versions |
| Claude | OTel traces | Span-level timestamps | Depends on exporter | Beta; version-gated |

The default 60-second metrics export interval for Claude OTel means that live throughput (3-minute window) has up to 60 seconds of delay before the most recent data arrives. **[inference]**

For Codex, persisted turn-completion timing does not expose model-call decode intervals. **[fact + inference]**

---

## 8. Version gating and privacy switches

### 8.1 Version gates

| Feature | Source | Minimum version | Evidence |
|---------|--------|----------------|----------|
| Codex cache-write tokens in response schema | Codex | v0.145.0 (PR #33500, #33454) | Changelog |
| Codex per-request TTFT telemetry | Codex | v0.143.0 (PR #30883) | Changelog |
| Codex turn start times in events | Codex | v0.145.0 (PR #32263) | Changelog |
| Codex service tier + reasoning effort in OTel | Codex | v0.143.0 (PR #29155) | Changelog |
| Claude streaming dedup for token/cost | Claude | v2.1.214 | Monitoring doc |
| Claude request identifiers and documented transcript join key | Claude | v2.1.214 | Monitoring doc |
| Claude `model` attribute on lines-of-code metric | Claude | v2.1.172 | Monitoring doc |
| Claude assistant response logging | Claude | v2.1.193 | Monitoring doc |

### 8.2 Privacy switches

| Source | Switch | Default | Effect |
|--------|--------|---------|--------|
| Codex | `otel.log_user_prompt` | off | Controls raw prompt export via OTel |
| Codex | `otel.trace_exporter` | `none` | Off by default; user must configure |
| Codex | `otel.metrics_exporter` | `statsig` | Default metrics destination is not a user-configured OTLP endpoint |
| Claude | `CLAUDE_CODE_ENABLE_TELEMETRY` | unset (off) | Required to enable any OTel |
| Claude | `OTEL_LOG_USER_PROMPTS` | off | Controls prompt content in events |
| Claude | `OTEL_LOG_ASSISTANT_RESPONSES` | off | Controls response text in events |
| Claude | `OTEL_LOG_TOOL_DETAILS` | off | Controls tool params in events |
| Claude | `OTEL_LOG_TOOL_CONTENT` | off | Controls tool I/O in trace spans |
| Claude | `OTEL_LOG_RAW_API_BODIES` | off | `1` exports truncated full request/response bodies; `file:<dir>` writes untruncated bodies. Both can contain the complete conversation and tool results |

The collector must field-allowlist metadata, usage, timing, and opaque identities. It must not ingest content-bearing response items, prompts, tool inputs/outputs, paths, account attributes, or raw API bodies. **[inference: follows from the documented channel contents and repository privacy contract]**

---

## 9. P0 unavailable boundary

Capabilities that cannot be provided without an enhanced (OTel) channel:

| Metric | Codex local only | Claude local only |
|--------|-----------------|-------------------|
| **TTFT** | measured only as turn TTFT, not model-call TTFT | unavailable |
| **Decode TPS** | unavailable | unavailable |
| **E2E latency** | measured at turn level where completion timing is present | unavailable |

Turn-level values and request-level values are distinct metric definitions. Without the required enhanced request channel, per-call TTFT, Decode TPS, and request E2E must remain `unavailable`; do not substitute turn timing. **[inference: follows from CONTEXT.md quality definitions]**

---

## 10. Identity model

### Codex

- **Agent identity**: implicit — Codex is the sole agent writing rollout files under its home directory. No explicit agent string in the rollout. **[inference]**
- **Model identity**: effective source-reported `model` in persisted turn context/settings. **[fact]**
- **Session identity**: thread UUID7 + rollout file path. **[fact]**
- **Turn identity**: turn UUID7 within a thread. **[fact]**
- **Model call identity**: unavailable in rollout-only collection; content response items are not model-call boundaries. Exact live completions carry a response ID but are not persisted. **[fact + inference]**

### Claude Code

- **Agent identity**: `service.name` = `claude-code` or `claude-code-desktop` in OTel. In local JSONL, implicit from the file location. **[fact: monitoring doc]**
- **Model identity**: documented on OTel metrics/events/spans; local transcript availability is version-specific and unverified here. **[fact]**
- **Session identity**: OTel carries `session.id`; the transcript join key `message.uuid` is documented for v2.1.214+. **[fact]**
- **Turn identity**: OTel `prompt.id` groups activity initiated by a prompt; local transcript turn reconstruction is version-specific. **[fact + inference]**
- **Model call identity**: OTel request identifiers provide the stable enhanced boundary. The public docs do not promise that one transcript assistant entry equals one API call. **[fact + inference]**

---

## 11. Recommendations for #4 (ingestion prototype) and #5 (metric contract)

### 11.1 Fixture inputs for #4

Synthetic fixtures should cover these scenarios, using only synthetic data (no real logs):

1. **Codex accumulated local usage**: successive synthetic `TokenCount` events. Verify cumulative deltas and replay replacement without inventing per-call identity.
2. **Codex live raw completion**: two synthetic `RawResponseCompleted` events in one turn. Verify response identity and prove they are a separate authority from rollout aggregates.
3. **Codex pre-v0.145 response**: response without `cache_write_input_tokens`. Verify graceful absence.
4. **Claude versioned local transcript**: synthetic entries matching each explicitly supported schema version. Verify only fields established by fixtures.
5. **Claude repeated or cumulative local usage**: verify single-counting without assuming one assistant entry equals one call.
6. **Claude pre-v2.1.214 stream**: simulated multi-frame usage. Verify dedup handles it.
7. **Truncated JSONL**: incomplete last line. Verify tail handling.
8. **Empty session**: no data. Verify zero/unavailable state.

### 11.2 Contract inputs for #5

The metric contract should encode:

- Per-metric `definition_version` (to handle `output_tokens − 1` vs `output_tokens` for Decode TPS numerator).
- Per-source and per-granularity `MeasurementQuality` defaults (Codex local turn timing is measured but per-call timing is unavailable; Claude local timing is unavailable).
- The authority replacement rule: replacement requires the same capability, identity, granularity, and time range; otherwise both observations may coexist but cannot be aggregated as equivalents.
- Token-part disjointness rules: Codex uses subset semantics (subtract cached from input); Claude uses additive semantics (cache tokens are separate from input).
- `scope`, `source`, and `coverage` metadata on every observation.

### 11.3 Open questions for #5

- Whether `cache_write_input_tokens` in Codex overlaps with `input_tokens` or is additive. Until resolved, the cache-write disjoint part and any total including it are unavailable/partial. **[unverified]**
- Which Claude local transcript versions and fields the sanitized-fixture prototype can support. Public docs describe the schema as internal and version-specific. **[unverified]**
- Whether the target Codex Desktop deployment exposes a user-consumable live app-server/OTel stream with stable request identity; rollout-only collection cannot recover exact call boundaries. **[unverified]**
- The exact formula version for Decode TPS: `output_tokens / (response_end − first_token)` vs `output_tokens / decode_duration`. **[needs contract decision]**

---

## 12. Risk register

| Risk | Impact | Mitigation |
|------|--------|-----------|
| Codex rollout schema changes across versions | Parser breaks on new fields | Version-gated parser; unknown-field tolerance; diagnostics |
| Claude JSONL usage repeats or changes shape across versions | Double counting or parser breakage | Version-gated sanitized fixtures; identity and cumulative-delta tests |
| Token-part subset semantics differ between providers | Incorrect burn totals | Source-specific normalization in CanonicalIngestor |
| OTel not enabled by default | Enhanced capabilities unavailable | Graceful degradation to estimated/unavailable |
| OTel export interval delays live throughput | Stale live window | Document latency and show partial/stale state; do not splice a second channel into the same observation |
| Local and OTel observations have different granularity | False replacement or cross-channel double count | Key authority by capability + identity + granularity + time range |

---

## Appendix A: Synthetic usage object examples

### Codex Responses API usage (synthetic)

```json
{
  "input_tokens": 5000,
  "cached_input_tokens": 3000,
  "cache_write_input_tokens": 800,
  "output_tokens": 1200,
  "reasoning_output_tokens": 400,
  "total_tokens": 6200,
  "service_tier": "default"
}
```

Normalized disjoint parts (Codex):

```text
input_uncached = 5000 − 3000 = 2000
cache_read     = 3000
cache_write    = unavailable  [overlap with input_tokens unverified]
output_visible = 1200 − 400 = 800
reasoning      = 400
```

### Claude Code usage (synthetic)

```json
{
  "input_tokens": 2000,
  "cache_creation_input_tokens": 800,
  "cache_read_input_tokens": 3000,
  "output_tokens": 1200
}
```

Normalized disjoint parts (Claude):

```text
input_uncached = 2000          [Anthropic: input_tokens excludes cached]
cache_read     = 3000
cache_write    = 800
output_visible = unavailable    [thinking not separately reported]
reasoning      = unavailable    [not separately reported]
```
