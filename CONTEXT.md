# Coding Agent Metrics

This context describes how the product observes and compares the performance and token activity of local coding agents without treating unlike measurements as equivalent.

## Language

**Coding Agent**:
A local agent runtime whose sessions and model calls are observed, initially Codex or Claude Code.
_Avoid_: Provider, model

**Model Identity**:
The source-reported identity of a model, retaining both its raw identity and a user-facing display identity.
_Avoid_: Model family when the exact identity is known

**Session**:
A continuous coding-agent interaction containing turns.
_Avoid_: Request, model call

**Turn**:
One unit of agent work initiated by the user or agent runtime; it may contain multiple model calls and tool waits.
_Avoid_: Request, model call

**Model Call**:
One invocation of a model endpoint, distinct from the surrounding turn.
_Avoid_: Turn, request when its boundary is unknown

**Usage Observation**:
A source-native report of token usage whose counter and subset semantics have not yet been normalized.
_Avoid_: Usage fact

**Usage Fact**:
A deduplicated, source-normalized token record with mutually exclusive token parts.
_Avoid_: Raw usage, token event

**Output Throughput**:
The selected agents' and models' observed output tokens divided by a common sliding-window duration.
_Avoid_: TPS

**Decode TPS**:
A per-model-call decode rate that excludes time to first token and states its exact formula version.
_Avoid_: TPS, output throughput

**Token Burn**:
The rate at which normalized, mutually exclusive input and output token parts are consumed over a sliding window.
_Avoid_: TPM, rate-limit usage

**Measurement Quality**:
How a value was obtained: measured, derived, estimated, or unavailable.
_Avoid_: Data state

**Data State**:
Whether an observation is zero, stale, absent, or unavailable.
_Avoid_: Measurement quality

**Coverage**:
Whether all observations required by a metric were available: complete or partial.
_Avoid_: Measurement quality, data state
