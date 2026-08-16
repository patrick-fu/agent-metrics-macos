// THROW AWAY — Validate bounded runtime and rendering behavior.
// Synthetic fixtures only. Not production AppKit/SQLite code.

export const WINDOWS = Object.freeze({
  outputThroughputSec: 180,
  tokenBurnSec: 600,
  callsSec: 600,
  performanceSec: Object.freeze({
    "15m": 900,
    "1h": 3600,
    "24h": 86400,
    "7d": 604800,
  }),
  defaultPerformance: "1h",
  staleAfterSec: 30,
});

export const DEFAULT_LIMITS = Object.freeze({
  queueCapacityPerSource: 256,
  maxFacts: 20000,
  maxSeriesPoints: 180,
  maxInflightQueries: 1,
  maxEventsPerTick: 128,
  lightSnapshotIntervalMs: 1000,
  detailSnapshotIntervalMs: 250,
});

export const AGENTS = Object.freeze(["Codex", "Claude Code"]);
export const MODELS = Object.freeze([
  "Orion 2",
  "Nova Large",
  "Sage Mini",
  "Atlas Code",
  "Ember",
  "Quartz",
]);

const QUALITY_RANK = Object.freeze({
  measured: 0,
  derived: 1,
  estimated: 2,
  unavailable: 3,
});

function clone(value) {
  return JSON.parse(JSON.stringify(value));
}

function median(values) {
  if (!values.length) return null;
  const sorted = [...values].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
}

function percentile(values, p) {
  if (!values.length) return null;
  const sorted = [...values].sort((a, b) => a - b);
  const index = Math.min(sorted.length - 1, Math.max(0, Math.ceil((p / 100) * sorted.length) - 1));
  return sorted[index];
}

export function emptyTokenParts() {
  return {
    inputUncached: 0,
    cacheRead: 0,
    cacheWrite: 0,
    outputVisible: 0,
    reasoning: 0,
  };
}

export function normalizeTokenParts(observation) {
  const source = observation.source;
  const raw = observation.rawTokens || {};
  if (observation.tokenParts) return { ...emptyTokenParts(), ...observation.tokenParts };

  if (source === "codex") {
    const input = raw.inputTokens ?? 0;
    const cached = raw.cachedInputTokens ?? 0;
    const output = raw.outputTokens ?? 0;
    const reasoning = raw.reasoningOutputTokens ?? 0;
    return {
      inputUncached: Math.max(0, input - cached),
      cacheRead: cached,
      cacheWrite: null,
      outputVisible: Math.max(0, output - reasoning),
      reasoning,
    };
  }

  return {
    inputUncached: raw.inputTokens ?? 0,
    cacheRead: raw.cacheReadInputTokens ?? 0,
    cacheWrite: raw.cacheCreationInputTokens ?? 0,
    outputVisible: null,
    reasoning: null,
  };
}

export function disjointBurnTokens(parts) {
  let total = 0;
  let missing = false;
  for (const key of ["inputUncached", "cacheRead", "cacheWrite", "outputVisible", "reasoning"]) {
    const value = parts[key];
    if (value == null) missing = true;
    else total += value;
  }
  return { total, missing };
}

export function decodeTps(observation) {
  const n = observation.outputTokens ?? 0;
  const durationMs = observation.durationMs;
  const ttftMs = observation.ttftMs;
  if (observation.retry) return { value: null, quality: "unavailable", reason: "retry-excluded" };
  if (!observation.modelCallId) return { value: null, quality: "unavailable", reason: "no-model-call-identity" };
  if (n < 2 || durationMs == null || ttftMs == null) {
    return { value: null, quality: "unavailable", reason: "insufficient-timing" };
  }
  const denom = (durationMs - ttftMs) / 1000;
  if (!(denom > 0)) return { value: null, quality: "unavailable", reason: "non-positive-decode-window" };
  return { value: (n - 1) / denom, quality: "derived", definitionVersion: "decode-tps-v1" };
}

export function matchesFilter(fact, filters) {
  const agents = filters.agents || ["全部"];
  const models = filters.models || ["全部"];
  const agentOk = agents.includes("全部") || agents.includes(fact.agent);
  const modelOk = models.includes("全部") || models.includes(fact.modelDisplay);
  return agentOk && modelOk;
}

export function topNWithOther(rows, n = 4) {
  const sorted = [...rows].sort((a, b) => {
    if (b.value !== a.value) return b.value - a.value;
    return a.label.localeCompare(b.label);
  });
  const head = sorted.slice(0, n);
  const tail = sorted.slice(n);
  if (!tail.length) return { ranked: head, other: null };
  return {
    ranked: head,
    other: {
      label: `其他 · ${tail.length}`,
      value: tail.reduce((sum, row) => sum + row.value, 0),
      count: tail.length,
      members: tail.map((row) => row.label),
    },
  };
}

function makeFact(observation, now) {
  const tokenParts = normalizeTokenParts(observation);
  const outputTokens = observation.outputTokens ?? observation.rawTokens?.outputTokens ?? 0;
  const schemaUnknown = Boolean(observation.schemaUnknown || observation.schemaVersion === "unknown");
  const identityMissing = !observation.modelCallId && observation.requiresCallIdentity;
  return {
    factId: observation.factId || `${observation.source}:${observation.identity || observation.seq || now}`,
    source: observation.source,
    agent: observation.agent,
    modelDisplay: observation.modelDisplay,
    modelCallId: observation.modelCallId || null,
    sessionId: observation.sessionId || null,
    turnId: observation.turnId || null,
    observedAt: observation.observedAt ?? now,
    outputTokens,
    tokenParts,
    quality: observation.quality || "derived",
    coverage: schemaUnknown || observation.truncated || identityMissing ? "partial" : observation.coverage || "complete",
    dataState: observation.dataState || "fresh",
    ttftMs: observation.ttftMs ?? null,
    durationMs: observation.durationMs ?? null,
    retry: Boolean(observation.retry),
    superseded: false,
    schemaUnknown,
    truncated: Boolean(observation.truncated),
    channel: observation.channel || "local",
  };
}

export function createRuntime(options = {}) {
  const limits = { ...DEFAULT_LIMITS, ...options.limits };
  let now = options.now ?? 0;
  let seq = 0;
  const sources = new Map();
  const facts = [];
  const factIds = new Set();
  const series = [];
  const diagnostics = [];
  const filters = { agents: ["全部"], models: ["全部"] };
  let performanceRange = WINDOWS.defaultPerformance;
  let popoverVisible = false;
  let reducedMotion = false;
  let inflightQueries = 0;
  let lastLightAt = -Infinity;
  let lastDetailAt = -Infinity;
  let lastSeriesAt = -Infinity;
  let lightSnapshot = null;
  let detailSnapshot = null;
  const counters = {
    ingested: 0,
    accepted: 0,
    dropped: 0,
    evictedFacts: 0,
    evictedSeries: 0,
    ticks: 0,
    lightBuilds: 0,
    detailBuilds: 0,
    popoverRenders: 0,
    statusRenders: 0,
    rejectedQueries: 0,
    failedSourceEvents: 0,
    schemaPartials: 0,
  };

  function ensureSource(sourceId) {
    if (!sources.has(sourceId)) {
      sources.set(sourceId, {
        id: sourceId,
        queue: [],
        healthy: true,
        schemaVersion: "v1",
        dropped: 0,
        accepted: 0,
        failed: 0,
      });
    }
    return sources.get(sourceId);
  }

  function note(kind, message, extra) {
    diagnostics.push({ at: now, kind, message, ...(extra || {}) });
    if (diagnostics.length > 200) diagnostics.shift();
  }

  function evictFacts() {
    while (facts.length > limits.maxFacts) {
      const evicted = facts.shift();
      factIds.delete(evicted.factId);
      counters.evictedFacts += 1;
    }
  }

  function acceptFact(fact) {
    if (factIds.has(fact.factId)) return false;
    if (fact.modelCallId) {
      const existing = facts.find((row) => row.modelCallId === fact.modelCallId && !row.superseded);
      if (existing && fact.channel === "enhanced" && existing.channel !== "enhanced") {
        existing.superseded = true;
      } else if (existing && existing.channel === "enhanced") {
        fact.superseded = true;
      }
    }
    facts.push(fact);
    factIds.add(fact.factId);
    evictFacts();
    return !fact.superseded;
  }

  function visibleFacts(windowSec, extraPred) {
    const start = now - windowSec * 1000;
    return facts.filter((fact) => {
      if (fact.superseded) return false;
      if (fact.observedAt <= start || fact.observedAt > now) return false;
      if (!matchesFilter(fact, filters)) return false;
      return extraPred ? extraPred(fact) : true;
    });
  }

  function chooseCohort(rows) {
    if (!rows.length) return { cohort: "unavailable", rows: [] };
    const present = new Set(rows.map((row) => row.quality));
    const chosen = ["measured", "derived", "estimated"].find((quality) => present.has(quality));
    if (!chosen) return { cohort: "unavailable", rows: [] };
    return { cohort: chosen, rows: rows.filter((row) => row.quality === chosen) };
  }

  function windowMeta(rows, chosen) {
    if (!rows.length) {
      return { quality: "unavailable", coverage: "partial", dataState: "absent", lowN: true, n: 0 };
    }
    const latest = Math.max(...rows.map((row) => row.observedAt));
    const stale = now - latest > WINDOWS.staleAfterSec * 1000;
    const anyPartial = rows.some((row) => row.coverage === "partial" || row.schemaUnknown || row.truncated);
    const anyMissing = rows.some((row) => row.dataState === "unavailable");
    return {
      quality: chosen,
      coverage: anyPartial ? "partial" : "complete",
      dataState: anyMissing ? "unavailable" : stale ? "stale" : "fresh",
      lowN: rows.length < 5,
      n: rows.length,
    };
  }

  function throughput() {
    const inWindow = visibleFacts(WINDOWS.outputThroughputSec, (fact) => fact.outputTokens != null);
    const { cohort, rows } = chooseCohort(inWindow);
    const meta = windowMeta(rows, cohort);
    if (!rows.length) return { value: null, unit: "tokens/s", definitionVersion: "output-throughput-v1", ...meta };
    const tokens = rows.reduce((sum, fact) => sum + fact.outputTokens, 0);
    return {
      value: tokens / WINDOWS.outputThroughputSec,
      tokens,
      unit: "tokens/s",
      definitionVersion: "output-throughput-v1",
      ...meta,
    };
  }

  function tokenBurn() {
    const inWindow = visibleFacts(WINDOWS.tokenBurnSec);
    const { cohort, rows } = chooseCohort(inWindow);
    const meta = windowMeta(rows, cohort);
    if (!rows.length) return { value: null, unit: "tokens/s", definitionVersion: "token-burn-v1", ...meta };
    let tokens = 0;
    let missingPart = false;
    for (const fact of rows) {
      const burn = disjointBurnTokens(fact.tokenParts);
      tokens += burn.total;
      missingPart = missingPart || burn.missing;
    }
    return {
      value: tokens / WINDOWS.tokenBurnSec,
      tokens,
      unit: "tokens/s",
      definitionVersion: "token-burn-v1",
      ...meta,
      coverage: missingPart || meta.coverage === "partial" ? "partial" : "complete",
    };
  }

  function calls() {
    const inWindow = visibleFacts(WINDOWS.callsSec, (fact) => Boolean(fact.modelCallId));
    const identityLess = visibleFacts(WINDOWS.callsSec, (fact) => !fact.modelCallId);
    const { cohort, rows } = chooseCohort(inWindow);
    const meta = windowMeta(rows, cohort);
    const ids = new Set(rows.map((fact) => fact.modelCallId));
    if (!rows.length) {
      return {
        value: null,
        unit: "calls/s",
        definitionVersion: "calls-v1",
        ...meta,
        coverage: identityLess.length ? "partial" : meta.coverage,
      };
    }
    return {
      value: ids.size / WINDOWS.callsSec,
      count: ids.size,
      unit: "calls/s",
      definitionVersion: "calls-v1",
      ...meta,
      coverage: identityLess.length || meta.coverage === "partial" ? "partial" : "complete",
    };
  }

  function performance() {
    const windowSec = WINDOWS.performanceSec[performanceRange];
    const inWindow = visibleFacts(windowSec, (fact) => Boolean(fact.modelCallId) && !fact.retry);
    const decoded = [];
    for (const fact of inWindow) {
      const result = decodeTps(fact);
      if (result.value != null) decoded.push({ fact, tps: result.value, ttftMs: fact.ttftMs });
    }
    const values = decoded.map((row) => row.tps);
    const lowN = values.length < 5;
    return {
      range: performanceRange,
      definitionVersion: "decode-tps-v1",
      n: values.length,
      lowN,
      quality: values.length ? "derived" : "unavailable",
      coverage: inWindow.length && values.length < inWindow.length ? "partial" : values.length ? "complete" : "partial",
      dataState: values.length ? "fresh" : "unavailable",
      overall: lowN
        ? { samples: values, p25: null, p50: null, p75: null }
        : { samples: values, p25: percentile(values, 25), p50: median(values), p75: percentile(values, 75) },
      byModel: MODELS.map((model) => {
        const modelValues = decoded.filter((row) => row.fact.modelDisplay === model).map((row) => row.tps);
        return {
          label: model,
          n: modelValues.length,
          lowN: modelValues.length < 5,
          p50: modelValues.length < 5 ? null : median(modelValues),
          samples: modelValues.length < 5 ? modelValues : undefined,
        };
      }).filter((row) => row.n > 0),
    };
  }

  function ranking(metric = "throughput") {
    const groups = new Map();
    const source =
      metric === "burn" ? tokenBurn : metric === "calls" ? calls : throughput;
    const windowSec =
      metric === "burn" ? WINDOWS.tokenBurnSec : metric === "calls" ? WINDOWS.callsSec : WINDOWS.outputThroughputSec;
    const inWindow = visibleFacts(windowSec);
    const { rows } = chooseCohort(inWindow);
    for (const fact of rows) {
      const current = groups.get(fact.modelDisplay) || { label: fact.modelDisplay, value: 0 };
      if (metric === "burn") current.value += disjointBurnTokens(fact.tokenParts).total;
      else if (metric === "calls") current.value += fact.modelCallId ? 1 : 0;
      else current.value += fact.outputTokens;
      groups.set(fact.modelDisplay, current);
    }
    const raw = [...groups.values()].map((row) => {
      if (metric === "burn") return { ...row, value: row.value / WINDOWS.tokenBurnSec };
      if (metric === "calls") return { ...row, value: row.value / WINDOWS.callsSec };
      return { ...row, value: row.value / WINDOWS.outputThroughputSec };
    });
    return topNWithOther(raw, 4);
  }

  function seriesPoint() {
    const snap = throughput();
    series.push({
      at: now,
      throughput: snap.value,
      coverage: snap.coverage,
      quality: snap.quality,
    });
    while (series.length > limits.maxSeriesPoints) {
      series.shift();
      counters.evictedSeries += 1;
    }
  }

  function buildLight() {
    const live = throughput();
    counters.lightBuilds += 1;
    lastLightAt = now;
    lightSnapshot = {
      kind: "light",
      builtAt: now,
      bytesHint: 180,
      outputThroughput: live.value,
      quality: live.quality,
      dataState: live.dataState,
      coverage: live.coverage,
      filters: clone(filters),
      popoverVisible,
    };
    counters.statusRenders += 1;
    return lightSnapshot;
  }

  function buildDetail() {
    counters.detailBuilds += 1;
    lastDetailAt = now;
    const live = throughput();
    const burn = tokenBurn();
    const callRate = calls();
    detailSnapshot = {
      kind: "detail",
      builtAt: now,
      bytesHint: 4200,
      filters: clone(filters),
      performanceRange,
      reducedMotion,
      live,
      burn,
      calls: callRate,
      performance: performance(),
      ranking: {
        throughput: ranking("throughput"),
        burn: ranking("burn"),
        calls: ranking("calls"),
      },
      series: series.slice(-36),
      sources: [...sources.values()].map((source) => ({
        id: source.id,
        healthy: source.healthy,
        queue: source.queue.length,
        dropped: source.dropped,
        schemaVersion: source.schemaVersion,
      })),
    };
    return detailSnapshot;
  }

  function drainSource(source) {
    if (!source.healthy) {
      const skipped = source.queue.length;
      source.failed += skipped;
      counters.failedSourceEvents += skipped;
      source.queue.length = 0;
      note("source-failure", `${source.id} dropped queued observations`, { skipped });
      return;
    }
    let taken = 0;
    while (source.queue.length && taken < limits.maxEventsPerTick) {
      const observation = source.queue.shift();
      taken += 1;
      if (source.schemaVersion === "unknown" || observation.schemaUnknown) {
        observation.schemaUnknown = true;
        counters.schemaPartials += 1;
      }
      const fact = makeFact(observation, now);
      if (acceptFact(fact)) {
        source.accepted += 1;
        counters.accepted += 1;
      }
    }
  }

  function ingest(observation) {
    const source = ensureSource(observation.source);
    counters.ingested += 1;
    const next = {
      ...observation,
      seq: observation.seq ?? ++seq,
      observedAt: observation.observedAt ?? now,
    };
    if (source.queue.length >= limits.queueCapacityPerSource) {
      source.dropped += 1;
      counters.dropped += 1;
      note("queue-shed", `${source.id} shed newest observation`, {
        capacity: limits.queueCapacityPerSource,
      });
      return { accepted: false, reason: "queue-full" };
    }
    source.queue.push(next);
    return { accepted: true };
  }

  function query(kind) {
    if (inflightQueries >= limits.maxInflightQueries) {
      counters.rejectedQueries += 1;
      return { ok: false, reason: "query-bound" };
    }
    inflightQueries += 1;
    try {
      if (kind === "light") return { ok: true, snapshot: lightSnapshot || buildLight() };
      if (!popoverVisible) return { ok: false, reason: "popover-hidden" };
      return { ok: true, snapshot: detailSnapshot || buildDetail() };
    } finally {
      inflightQueries -= 1;
    }
  }

  function maybeBuildSnapshots(force = false) {
    if (now - lastSeriesAt >= 1000) {
      seriesPoint();
      lastSeriesAt = now;
    }
    if (force || now - lastLightAt >= limits.lightSnapshotIntervalMs) buildLight();
    if (popoverVisible && (force || now - lastDetailAt >= limits.detailSnapshotIntervalMs)) {
      buildDetail();
      counters.popoverRenders += 1;
    }
  }

  function tick(nextNow) {
    if (nextNow != null) now = nextNow;
    counters.ticks += 1;
    const acceptedBefore = counters.accepted;
    const failedBefore = counters.failedSourceEvents;
    for (const source of sources.values()) drainSource(source);
    const factsChanged = counters.accepted !== acceptedBefore || counters.failedSourceEvents !== failedBefore;
    maybeBuildSnapshots(factsChanged);
    return getState();
  }

  function getState() {
    return {
      now,
      limits,
      filters: clone(filters),
      performanceRange,
      popoverVisible,
      reducedMotion,
      factCount: facts.length,
      seriesCount: series.length,
      sources: [...sources.values()].map((source) => ({
        id: source.id,
        healthy: source.healthy,
        queue: source.queue.length,
        dropped: source.dropped,
        accepted: source.accepted,
        failed: source.failed,
        schemaVersion: source.schemaVersion,
      })),
      counters: { ...counters },
      lightSnapshot,
      detailSnapshot,
      diagnostics: diagnostics.slice(-20),
    };
  }

  return {
    WINDOWS,
    limits,
    ingest,
    ingestMany(observations) {
      return observations.map(ingest);
    },
    failSource(sourceId, reason = "synthetic-failure") {
      const source = ensureSource(sourceId);
      source.healthy = false;
      note("source-failure", `${sourceId} marked unhealthy`, { reason });
    },
    recoverSource(sourceId) {
      const source = ensureSource(sourceId);
      source.healthy = true;
      note("source-recover", `${sourceId} recovered`);
    },
    setSchema(sourceId, schemaVersion) {
      const source = ensureSource(sourceId);
      source.schemaVersion = schemaVersion;
      note("schema-change", `${sourceId} schema -> ${schemaVersion}`);
    },
    setFilters(next) {
      if (next.agents) filters.agents = next.agents.length ? next.agents : ["全部"];
      if (next.models) filters.models = next.models.length ? next.models : ["全部"];
      if (popoverVisible) buildDetail();
      buildLight();
    },
    setPerformanceRange(range) {
      if (!WINDOWS.performanceSec[range]) return;
      performanceRange = range;
      if (popoverVisible) buildDetail();
    },
    setPopoverVisible(visible) {
      popoverVisible = Boolean(visible);
      if (popoverVisible) {
        buildDetail();
        counters.popoverRenders += 1;
      }
    },
    setReducedMotion(value) {
      reducedMotion = Boolean(value);
    },
    flushSnapshots(kind = "both") {
      if (kind === "light" || kind === "both") buildLight();
      if ((kind === "detail" || kind === "both") && popoverVisible) buildDetail();
      return { lightSnapshot, detailSnapshot };
    },
    tick,
    advance(ms, step = 250) {
      const start = now;
      const end = start + ms;
      while (now < end) tick(Math.min(end, now + step));
      return getState();
    },
    query,
    getState,
    getLightSnapshot: () => lightSnapshot,
    getDetailSnapshot: () => detailSnapshot,
    getFacts: () => facts.filter((fact) => !fact.superseded),
    now: () => now,
    setNow(value) {
      now = value;
    },
  };
}

export function syntheticObservation(overrides = {}) {
  const source = overrides.source || "codex";
  const agent = overrides.agent || (source === "claude" ? "Claude Code" : "Codex");
  const modelDisplay = overrides.modelDisplay || "Orion 2";
  return {
    source,
    agent,
    modelDisplay,
    channel: overrides.channel || "local",
    modelCallId: overrides.modelCallId ?? `call-${source}-${overrides.seq ?? 1}`,
    sessionId: overrides.sessionId ?? `sess-${source}`,
    turnId: overrides.turnId ?? `turn-${overrides.seq ?? 1}`,
    observedAt: overrides.observedAt ?? 0,
    outputTokens: overrides.outputTokens ?? 120,
    rawTokens: overrides.rawTokens || {
      inputTokens: source === "codex" ? 500 : 200,
      cachedInputTokens: source === "codex" ? 300 : undefined,
      cacheReadInputTokens: source === "claude" ? 300 : undefined,
      cacheCreationInputTokens: source === "claude" ? 80 : undefined,
      outputTokens: overrides.outputTokens ?? 120,
      reasoningOutputTokens: source === "codex" ? 40 : undefined,
    },
    quality: overrides.quality || "derived",
    coverage: overrides.coverage || "complete",
    dataState: overrides.dataState || "fresh",
    ttftMs: overrides.ttftMs ?? 180,
    durationMs: overrides.durationMs ?? 1800,
    retry: Boolean(overrides.retry),
    truncated: Boolean(overrides.truncated),
    schemaUnknown: Boolean(overrides.schemaUnknown),
    schemaVersion: overrides.schemaVersion,
    factId: overrides.factId,
    requiresCallIdentity: Boolean(overrides.requiresCallIdentity),
    ...overrides,
  };
}

export function generateVolume(spec = {}) {
  const {
    count = 1000,
    now = 180_000,
    windowMs = 180_000,
    sources = ["codex", "claude"],
    models = MODELS,
    prefix = "vol",
  } = spec;
  const out = [];
  for (let i = 0; i < count; i += 1) {
    const source = sources[i % sources.length];
    const modelDisplay = models[i % models.length];
    out.push(
      syntheticObservation({
        source,
        agent: source === "claude" ? "Claude Code" : "Codex",
        modelDisplay,
        seq: i + 1,
        factId: `${prefix}:${source}:${i}`,
        modelCallId: `${prefix}-call-${i}`,
        observedAt: now - (windowMs - Math.floor((i / Math.max(1, count - 1)) * windowMs)),
        outputTokens: 40 + (i % 9) * 10,
        quality: i % 17 === 0 ? "estimated" : "derived",
        coverage: i % 23 === 0 ? "partial" : "complete",
      }),
    );
  }
  return out;
}
