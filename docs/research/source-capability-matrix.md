# Source Capability Matrix

Research date: 2026-08-14.

Scope: Codex CLI/Desktop and Claude Code CLI as observed through official documentation and public upstream source. No local fixtures, logs, prompts, or private artifacts are referenced.

Notation: each claim is marked **[fact]** (cited from official docs or public source), **[inference]** (derived from combining facts), or **[unverified]** (plausible but not confirmed by a primary source).

---

## 1. Sources consulted

### Codex CLI

| Source | URL |
|--------|-----|
| Configuration Reference (config.toml) | <https://learn.chatgpt.com/docs/config> |
| Changelog v0.143.0–v0.147.0 | <https://learn.chatgpt.com/docs/changelog> |
| App Server API overview | <https://learn.chatgpt.com/docs/app-server> |
| Responses API create method | <https://developers.openai.com/api/reference/resources/responses/methods/create> |

### Claude Code CLI

| Source | URL |
|--------|-----|
| Monitoring (OpenTelemetry) | <https://code.claude.com/docs/en/monitoring-usage> |
| Manage costs effectively | <https://code.claude.com/docs/en/costs> |

---

## 2. Local data channels

### 2.1 Codex CLI — rollout files

Codex persists each session as a JSONL "rollout" file under its sessions directory. The App Server API describes thread/archive and thread/unarchive as moving rollout files between active and archived session directories, confirming that one rollout file corresponds to one thread/session. **[fact: App Server API overview]**

Each rollout line is a structured item. Rollout items carry turn-level and response-level data:

- **Turn items** persisted for paginated threads (PR #30188, v0.144.0 changelog). **[fact]**
- **Response items** include a `turn_id` on ResponseItem metadata (PR #28360, v0.143.0 changelog). **[fact]**
- **Per-response usage** exposed in raw app-server events (PR #32985, v0.145.0 changelog). **[fact]**
- **Cache-write token usage** tracked and added to the raw response schema (PR #33454, PR #33500, v0.145.0 changelog). **[fact]**
- **Rollout budget units** captured from response usage (PR #36641, PR #36715, v0.147.0 changelog). **[fact]**
- **Turn start times** included in terminal turn events (PR #32263, v0.145.0 changelog). **[fact]**
- Thread and turn IDs are UUID7 (PR #27714, v0.143.0 changelog). **[fact]**

Identity fields available in rollout response items: `model` (source-reported model string), `turn_id` (UUID7), `thread_id` (UUID7). **[fact]**

### 2.2 Claude Code CLI — transcript files

Claude Code stores session transcripts as JSONL files under `~/.claude/projects/*/*.jsonl`. The costs doc references these files directly: *"session transcripts, the top-level `~/.claude/projects/*/*.jsonl` files"*. **[fact: costs doc]**

Each JSONL line is a message object. The `/usage` command output format reveals the usage parts available per model:

```text
claude-sonnet-4-6: 1.2k input, 5.3k output, 940.0k cache read, 50.0k cache write
```

This maps to the Anthropic Messages API usage object fields: `input_tokens`, `output_tokens`, `cache_creation_input_tokens` (cache write), `cache_read_input_tokens` (cache read). **[fact: costs doc + Anthropic API convention]**

Each assistant message carries the model string that served the request, and a session ID. **[fact: monitoring doc — standard attributes include `session.id` and `model`]**

Claude Code does not record first-token timing, inter-token timing, or per-model-call wall-clock boundaries in its transcript JSONL files. **[inference: the transcript format contains message content and cumulative usage, with no documented timing fields beyond message timestamps]**

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
| `claude_code.token.usage` | `type` (input/output), `model`, `session.id`, `skill.name`, `plugin.name`, `agent.name` | monitoring doc **[fact]** |
| `claude_code.cost.usage` | `model`, `session.id`, etc. | monitoring doc **[fact]** |
| `claude_code.session.count` | `session.id`, etc. | monitoring doc **[fact]** |
| `claude_code.lines_of_code.count` | `model` (from v2.1.172) | monitoring doc **[fact]** |

Events emitted: `user_prompt`, `assistant_response`, `tool_result`, `tool_decision`, `api_request`, `api_error`, `mcp_server_connection`, `auth`, `permission_mode_changed`. **[fact]**

Key dedup guarantee: *"Claude Code counts each streaming response toward the cost and token metrics exactly once, including when a gateway or proxy streams usage progressively across multiple frames."* (Fixed in v2.1.214.) **[fact]**

Traces (beta) provide distributed spans. The monitoring doc states traces are a "separate data path" from metrics and events. **[fact]**

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

| Metric | Codex local rollout | Codex OTel | Claude local JSONL | Claude OTel (metrics) | Claude OTel (traces, beta) |
|--------|--------------------|-----------|--------------------|-----------------------|---------------------------|
| **Output throughput** | measured (per-response `output_tokens`) | measured | measured (per-message `output_tokens`) | measured | measured |
| **Decode TPS** | estimated (output_tokens / (turn_end − turn_start), includes tool-wait time) | measured (if per-chunk timing available via trace) | unavailable (no per-call timing) | estimated (output_tokens / request duration if `api_request` events carry timestamps) | measured (span durations) |
| **Token burn/min** | measured (input + cached + cache_write + output + reasoning) | measured | measured (input + output + cache_read + cache_write) | measured | measured |
| **TTFT** | estimated (turn start to first output item timestamp, if item timestamps exist) | measured (PR #30883: per-request TTFT telemetry) | unavailable | unavailable (no TTFT metric documented) | unverified (trace spans may carry timestamps; not confirmed) |
| **E2E latency** | estimated (turn start to turn completion timestamps) | measured (request completion telemetry) | unavailable (no per-call wall-clock in JSONL) | estimated (if `api_request` event timestamps available) | measured (span start to end) |
| **Calls/min** | measured (count distinct response items or turn items) | measured | measured (count assistant messages) | measured | measured |

Quality classification rationale:

- **Codex local**: usage parts are exact per-response. Timing is limited to turn-level boundaries, not per-API-call decode intervals. A turn may contain multiple model calls and tool waits, so dividing output tokens by turn duration overestimates TTFT and underestimates true decode rate. **[inference]**
- **Codex OTel**: PR #30883 explicitly adds per-request TTFT telemetry, making TTFT measured. Decode TPS requires subtracting TTFT from total duration and dividing by output count; the formula version must be stated. **[inference]**
- **Claude local**: usage parts are exact per-message. No timing beyond message-level timestamps. Token burn is measured; throughput is measured; anything requiring TTFT or decode-interval timing is unavailable or estimated. **[inference]**
- **Claude OTel metrics**: `claude_code.token.usage` carries `type` (input/output) and `model`, but the monitoring doc does not document a TTFT metric. `api_request` events exist but their timestamp precision for TTFT is unverified. **[fact + inference]**
- **Claude OTel traces**: traces provide spans with durations. Whether spans distinguish first-token from completion is not documented. **[unverified]**

---

## 5. Token counter and subset semantics

### 5.1 Codex (Responses API usage object)

Fields documented from the Bedrock cookbook example and changelog PRs:

| Field | Meaning | Subset of? |
|-------|---------|-----------|
| `input_tokens` | Total input tokens processed | — |
| `cached_input_tokens` | Input tokens served from cache | subset of `input_tokens` |
| `output_tokens` | Total output tokens generated | — |
| `reasoning_output_tokens` | Output tokens consumed by reasoning | subset of `output_tokens` |
| `total_tokens` | input_tokens + output_tokens | sum of the two |
| `cache_write_tokens` | Input tokens written to cache (PR #33500) | relationship to `input_tokens` unverified |

Normalization for disjoint burn:

```text
input_uncached = input_tokens − cached_input_tokens
cache_read     = cached_input_tokens
cache_write    = cache_write_tokens          [unverified: may overlap with input_tokens]
output_visible = output_tokens − reasoning_output_tokens
reasoning      = reasoning_output_tokens
```

Critical caveat: `cached_input_tokens` is a subset of `input_tokens`, not additive. Adding them would double-count. `cache_write_tokens` was added in v0.144+ and its subset relationship to `input_tokens` is not documented. **[inference: cached tokens are standard subsets in the Responses API]**

### 5.2 Claude Code (Anthropic Messages API usage object)

Fields from the `/usage` output and monitoring doc:

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
output_visible = output_tokens − thinking_tokens   [thinking_tokens not separately reported in usage]
reasoning      = thinking_tokens (billed as output but not separately broken out in standard usage)
```

Critical difference from OpenAI: Anthropic's `cache_creation_input_tokens` and `cache_read_input_tokens` are disjoint from `input_tokens`, not subsets. The `input_tokens` field counts only uncached input. Adding them directly is correct for total burn. **[fact: Anthropic billing model — cache tokens are billed and counted separately from uncached input]**

Thinking/reasoning tokens: Anthropic bills extended thinking as output tokens, and the standard usage object does not separate visible output from reasoning output. **[inference: costs doc says "Thinking tokens are billed as output tokens" but usage breakdown shows only a single output total]**

### 5.3 Streaming dedup

Claude Code guarantees single counting per streaming response (v2.1.214+). Before that version, multi-frame streams could inflate counts. **[fact]**

Codex rollout files are append-only JSONL; each response item appears once. The risk is repeated cumulative usage across multi-line API responses. **[inference: same pattern as Kaboo's observed Claude JSONL dedup challenge]**

---

## 6. Authority contract — one channel per capability

### Principle

For each (source, capability) pair, exactly one channel is authoritative. If a higher-fidelity channel becomes available, it replaces the lower-fidelity channel's values — it does not add to them.

### Codex authority table

| Capability | Authority (default) | Authority (enhanced) | Rule |
|-----------|--------------------|-----------------------|------|
| Token counts | Local rollout | — | Rollout is the only channel; usage is per-response exact |
| TTFT | Local rollout (estimated) | OTel trace/metrics (measured, PR #30883) | If OTel TTFT present, replaces rollout estimate |
| Decode TPS | Rollout (estimated) | OTel (measured) | If OTel timing present, replaces rollout estimate |
| Model identity | Rollout response `model` | — | Single source |
| Session/turn identity | Rollout UUID7 | — | Single source |

### Claude authority table

| Capability | Authority (default) | Authority (enhanced) | Rule |
|-----------|--------------------|-----------------------|------|
| Token counts | Local JSONL | OTel metrics | OTel `claude_code.token.usage` replaces JSONL if both present (OTel has dedup guarantee) |
| TTFT | unavailable | OTel traces (unverified) | If trace span provides TTFT, it replaces the unavailable status |
| Decode TPS | unavailable | OTel traces (unverified) | Same as TTFT |
| Model identity | JSONL message `model` | OTel `model` attribute | Both carry the same value; JSONL is local authority |
| Session identity | JSONL session path / ID | OTel `session.id` | JSONL file identity is primary; OTel session.id joins to it |

### Fallback-replaces-not-adds

When transitioning from local-only to OTel-enhanced:

1. The enhanced channel's measured values replace the estimated values for the same time period.
2. The two channels must never be summed for the same observation.
3. The `MeasurementQuality` tag must change from `estimated` to `measured` for the replaced period.
4. If the enhanced channel goes offline or stops producing data, the system falls back to the local channel and reverts quality to `estimated`.

---

## 7. Timing precision and export latency

| Source | Channel | Timestamp precision | Export latency | Version gate |
|--------|---------|--------------------|----------------|-------------|
| Codex | Rollout JSONL | Turn-level start times (PR #32263); response item timestamps | Written at turn completion; near-real-time for append polling | v0.145.0+ for turn start times |
| Codex | OTel | Per-request TTFT (PR #30883) | Depends on exporter; OTLP gRPC/HTTP configurable | v0.143.0+ for TTFT telemetry |
| Claude | Local JSONL | Message-level timestamps (wall-clock write time) | Real-time append | All versions |
| Claude | OTel metrics | Aggregated per export interval (default 60s; configurable) | `OTEL_METRIC_EXPORT_INTERVAL` default 60000ms | All OTel-enabled versions |
| Claude | OTel events | Per-event timestamps | `OTEL_LOGS_EXPORT_INTERVAL` default 5000ms | All OTel-enabled versions |
| Claude | OTel traces | Span-level timestamps | Depends on exporter | Beta; version-gated |

The default 60-second metrics export interval for Claude OTel means that live throughput (3-minute window) has up to 60 seconds of delay before the most recent data arrives. **[inference]**

For Codex, rollout files are appended at turn boundaries, so within-turn decode activity is not visible until the turn completes. **[inference]**

---

## 8. Version gating and privacy switches

### 8.1 Version gates

| Feature | Source | Minimum version | Evidence |
|---------|--------|----------------|----------|
| Codex cache-write tokens in response schema | Codex | v0.144.0 (PR #33500, #33454) | Changelog |
| Codex per-request TTFT telemetry | Codex | v0.143.0 (PR #30883) | Changelog |
| Codex turn start times in events | Codex | v0.145.0 (PR #32263) | Changelog |
| Codex service tier + reasoning effort in OTel | Codex | v0.143.0 (PR #29155) | Changelog |
| Claude streaming dedup for token/cost | Claude | v2.1.214 | Monitoring doc |
| Claude `model` attribute on lines-of-code metric | Claude | v2.1.172 | Monitoring doc |
| Claude assistant response logging | Claude | v2.1.193 | Monitoring doc |

### 8.2 Privacy switches

| Source | Switch | Default | Effect |
|--------|--------|---------|--------|
| Codex | `otel.log_user_prompt` | off | Controls raw prompt export via OTel |
| Codex | `otel.trace_exporter` | `none` | Off by default; user must configure |
| Codex | `otel.metrics_exporter` | `statsig` | On by default but sends to OpenAI internal, not user OTLP |
| Claude | `CLAUDE_CODE_ENABLE_TELEMETRY` | unset (off) | Required to enable any OTel |
| Claude | `OTEL_LOG_USER_PROMPTS` | off | Controls prompt content in events |
| Claude | `OTEL_LOG_ASSISTANT_RESPONSES` | off | Controls response text in events |
| Claude | `OTEL_LOG_TOOL_DETAILS` | off | Controls tool params in events |
| Claude | `OTEL_LOG_TOOL_CONTENT` | off | Controls tool I/O in trace spans |

Neither source's local files (rollout/JSONL) contain a privacy switch — they are written unconditionally. Privacy is enforced by the collector reading only metadata, usage, timing, and identity fields. **[inference]**

---

## 9. P0 unavailable boundary

Capabilities that cannot be provided without an enhanced (OTel) channel:

| Metric | Codex local only | Claude local only |
|--------|-----------------|-------------------|
| **TTFT** | estimated (turn-level approximation) | unavailable |
| **Decode TPS** | estimated (turn duration includes tool waits) | unavailable |
| **E2E latency** | estimated (turn start to completion) | unavailable |

These must never be presented as `measured` without the enhanced channel. The UI must label them `estimated` or `unavailable` per the `MeasurementQuality` contract. **[inference: follows from CONTEXT.md quality definitions]**

---

## 10. Identity model

### Codex

- **Agent identity**: implicit — Codex is the sole agent writing rollout files under its home directory. No explicit agent string in the rollout. **[inference]**
- **Model identity**: `model` field in each response item (source-reported string, e.g. `gpt-5.6-terra`). **[fact]**
- **Session identity**: thread UUID7 + rollout file path. **[fact]**
- **Turn identity**: turn UUID7 within a thread. **[fact]**
- **Model call identity**: inferred from response items within a turn; each response item is one API call. **[inference]**

### Claude Code

- **Agent identity**: `service.name` = `claude-code` or `claude-code-desktop` in OTel. In local JSONL, implicit from the file location. **[fact: monitoring doc]**
- **Model identity**: `model` field per assistant message and `model` attribute on OTel metrics. **[fact]**
- **Session identity**: JSONL file path encodes project and session; OTel carries `session.id`. **[fact]**
- **Turn identity**: not explicitly modeled in JSONL; a "turn" is a user message followed by assistant messages until the next user message. **[inference]**
- **Model call identity**: each assistant message is one API call; but multiple API calls may happen within one assistant response if Claude Code retries or chains. **[inference]**

---

## 11. Recommendations for #4 (ingestion prototype) and #5 (metric contract)

### 11.1 Fixture inputs for #4

Synthetic fixtures should cover these scenarios, using only synthetic data (no real logs):

1. **Codex single-response turn**: one turn with one response item containing all token parts. Verify disjoint normalization.
2. **Codex multi-response turn**: one turn with two response items (e.g. tool call + continuation). Verify per-call identity.
3. **Codex pre-v0.144 response**: response without `cache_write_tokens`. Verify graceful absence.
4. **Claude single-message**: one assistant message with input/output/cache_read/cache_write.
5. **Claude multi-message cumulative**: multiple assistant messages where usage may repeat or accumulate. Verify single-counting.
6. **Claude pre-v2.1.214 stream**: simulated multi-frame usage. Verify dedup handles it.
7. **Truncated JSONL**: incomplete last line. Verify tail handling.
8. **Empty session**: no data. Verify zero/unavailable state.

### 11.2 Contract inputs for #5

The metric contract should encode:

- Per-metric `definition_version` (to handle `output_tokens − 1` vs `output_tokens` for Decode TPS numerator).
- Per-source `MeasurementQuality` default (Codex local = estimated for timing; Claude local = unavailable for timing).
- The authority replacement rule: OTel measured values replace local estimated values for the same observation period.
- Token-part disjointness rules: Codex uses subset semantics (subtract cached from input); Claude uses additive semantics (cache tokens are separate from input).
- `scope`, `source`, and `coverage` metadata on every observation.

### 11.3 Open questions for #5

- Whether `cache_write_tokens` in Codex overlaps with `input_tokens` or is additive. **[unverified]**
- Whether Claude OTel trace spans provide first-token timestamps for TTFT. **[unverified]**
- Whether Claude `api_request` events carry timestamps precise enough for estimated E2E latency. **[unverified]**
- The exact formula version for Decode TPS: `output_tokens / (response_end − first_token)` vs `output_tokens / decode_duration`. **[needs contract decision]**

---

## 12. Risk register

| Risk | Impact | Mitigation |
|------|--------|-----------|
| Codex rollout schema changes across versions | Parser breaks on new fields | Version-gated parser; unknown-field tolerance; diagnostics |
| Claude JSONL usage repeats across messages | Double counting | Identity-based dedup (message ID + cumulative delta detection) |
| Token-part subset semantics differ between providers | Incorrect burn totals | Source-specific normalization in CanonicalIngestor |
| OTel not enabled by default | Enhanced capabilities unavailable | Graceful degradation to estimated/unavailable |
| OTel export interval delays live throughput | Stale live window | Document latency; use local channel for live when OTel is delayed |
| Claude trace spans unverified for TTFT | Cannot claim measured Decode TPS | Verify with real OTel setup before marking measured |

---

## Appendix A: Synthetic usage object examples

### Codex Responses API usage (synthetic)

```json
{
  "input_tokens": 5000,
  "cached_input_tokens": 3000,
  "cache_write_tokens": 800,
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
cache_write    = 800          [unverified overlap]
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
output_visible = 1200           [thinking not separately reported]
reasoning      = 0              [not available in standard usage object]
```
