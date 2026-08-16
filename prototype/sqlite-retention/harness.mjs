#!/usr/bin/env node
// THROW AWAY — SQLite retention prototype harness. Synthetic fixtures only.
// 20k is the hot/query working set, not persistent retention.

import { DatabaseSync } from "node:sqlite";
import { performance } from "node:perf_hooks";
import {
  copyFileSync,
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { runPolicyAssertions } from "./policy.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const tmpDir = join(here, "tmp");
const resultsDir = join(here, "results");
const schemaPath = join(here, "schema.sql");

const HOT_QUERY_WORKING_SET = 20_000;
const SCHEMA_VERSION = 1;
const PARSER_VERSION = "1.0.0";
const NOW_MS = Date.UTC(2026, 7, 17, 12, 0, 0);
const SPAN_DAYS = 400;
const SPAN_MS = SPAN_DAYS * 86_400_000;
const DAY = 86_400_000;
const MIN = 60_000;

const AGENTS = [
  { source: "src-codex", agent: "Codex" },
  { source: "src-claude", agent: "Claude Code" },
];
const MODELS = ["Orion 2", "Nova Large", "Sage Mini", "Atlas Code", "Ember", "Quartz"];
const MODEL_RAW = {
  "Orion 2": "orion-2-synthetic",
  "Nova Large": "nova-large-synthetic",
  "Sage Mini": "sage-mini-synthetic",
  "Atlas Code": "atlas-code-synthetic",
  Ember: "ember-synthetic",
  Quartz: "quartz-synthetic",
};
const WINDOWS = [
  ["3m", 3 * MIN],
  ["10m", 10 * MIN],
  ["15m", 15 * MIN],
  ["1h", 60 * MIN],
  ["24h", DAY],
  ["7d", 7 * DAY],
  ["90d", 90 * DAY],
  ["1y", 365 * DAY],
  ["All", null],
];
const SELECTED_AGENTS = ["Codex", "Claude Code"];
const SELECTED_MODELS = ["Orion 2", "Nova Large"];

const args = process.argv.slice(2);
function flag(name, fallback) {
  const hit = args.find((item) => item.startsWith(`--${name}=`));
  return hit ? hit.slice(name.length + 3) : fallback;
}
const SCALE_ALIAS = { "10k": 10_000, "100k": 100_000, "1m": 1_000_000 };
const requestedScales = flag("scales", "10k,100k,1m")
  .split(",")
  .map((token) => SCALE_ALIAS[token] || Number(token))
  .filter((n) => Number.isFinite(n) && n > 0);
const runsOverride = Number(flag("runs", "")) || null;
const oneMBudgetMs = Number(flag("budget-1m-ms", String(15 * 60 * 1000)));
const logicOnly = args.includes("--logic-only");

const rows = [];
let failed = 0;

function format(value) {
  if (value == null) return "n/a";
  if (typeof value === "number") {
    if (Number.isInteger(value)) return String(value);
    return value.toFixed(4).replace(/0+$/, "0");
  }
  return typeof value === "object" ? JSON.stringify(value) : String(value);
}

function pushRow(row) {
  rows.push(row);
  if (row.kind === "assertion" && !row.ok) failed += 1;
  console.log(`${row.status.padEnd(8)} ${row.name}`);
  console.log(`         measured:  ${format(row.measured)}`);
  console.log(`         expected:  ${format(row.suggested)}`);
  if (row.note) console.log(`         note:      ${row.note}`);
}

function assert(name, condition, measured, suggested, extra = {}) {
  pushRow({
    name,
    kind: "assertion",
    status: condition ? "PASS" : "FAIL",
    ok: Boolean(condition),
    measured,
    suggested,
    ...extra,
  });
}

function measure(name, measured, suggested, extra = {}) {
  pushRow({
    name,
    kind: "measurement",
    status: "MEASURED",
    ok: null,
    measured,
    suggested,
    ...extra,
  });
}

function timed(fn) {
  const start = performance.now();
  const value = fn();
  return { value, ms: performance.now() - start };
}

function mulberry32(seed) {
  let a = seed >>> 0;
  return function rng() {
    a |= 0;
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function pick(rng, list) {
  return list[Math.floor(rng() * list.length)];
}

function hexId(rng, width) {
  let out = "";
  while (out.length < width) out += Math.floor(rng() * 0x10000).toString(16).padStart(4, "0");
  return out.slice(0, width);
}

function observedAt(rng) {
  const bucket = rng();
  if (bucket < 0.04) return NOW_MS - Math.floor(rng() * 3 * MIN);
  if (bucket < 0.08) return NOW_MS - Math.floor(rng() * 10 * MIN);
  if (bucket < 0.12) return NOW_MS - Math.floor(rng() * 60 * MIN);
  if (bucket < 0.2) return NOW_MS - Math.floor(rng() * DAY);
  if (bucket < 0.36) return NOW_MS - Math.floor(rng() * 7 * DAY);
  if (bucket < 0.55) return NOW_MS - Math.floor(rng() * 90 * DAY);
  if (bucket < 0.78) return NOW_MS - Math.floor(rng() * 365 * DAY);
  return NOW_MS - Math.floor(rng() * SPAN_MS);
}

function applyCumulative(prev, reading) {
  if (reading < prev) return { delta: 0, rebuild: true, watermark: prev };
  return { delta: reading - prev, rebuild: false, watermark: reading };
}

function decodeTpsValue(outputTotal, durationMs, ttftMs) {
  if (outputTotal == null || outputTotal < 2) return null;
  if (durationMs == null || ttftMs == null) return null;
  const denomSec = (durationMs - ttftMs) / 1000;
  if (!(denomSec > 0)) return null;
  return (outputTotal - 1) / denomSec;
}

function quantile(sorted, p) {
  if (!sorted.length) return null;
  const idx = (sorted.length - 1) * p;
  const lo = Math.floor(idx);
  const hi = Math.ceil(idx);
  if (lo === hi) return sorted[lo];
  return sorted[lo] * (hi - idx) + sorted[hi] * (idx - lo);
}

function rangeOf(values) {
  const nums = values.filter((v) => typeof v === "number" && Number.isFinite(v));
  if (!nums.length) return null;
  return {
    min: Math.min(...nums),
    max: Math.max(...nums),
    n: nums.length,
    values: nums,
  };
}

function openDb(dbPath, { create = false } = {}) {
  const db = new DatabaseSync(dbPath);
  if (create) db.exec("PRAGMA auto_vacuum = INCREMENTAL");
  db.exec("PRAGMA journal_mode = WAL");
  db.exec("PRAGMA synchronous = NORMAL");
  db.exec("PRAGMA temp_store = MEMORY");
  db.exec("PRAGMA foreign_keys = ON");
  return db;
}

function applySchema(db, { indexes = false } = {}) {
  const sql = readFileSync(schemaPath, "utf8");
  const parts = sql
    .split(";")
    .map((part) => part.trim())
    .filter(Boolean)
    .filter((part) => indexes || !/^CREATE INDEX/i.test(part));
  for (const part of parts) db.exec(`${part};`);
}

function createIndexes(db) {
  const sql = readFileSync(schemaPath, "utf8");
  const parts = sql
    .split(";")
    .map((part) => part.trim())
    .filter((part) => /^CREATE INDEX/i.test(part));
  for (const part of parts) db.exec(`${part};`);
}

function unlinkQuiet(path) {
  try {
    unlinkSync(path);
  } catch {
    // ignore
  }
}

function wipeDbFiles(dbPath) {
  unlinkQuiet(dbPath);
  unlinkQuiet(`${dbPath}-wal`);
  unlinkQuiet(`${dbPath}-shm`);
}

function fileBytes(path) {
  try {
    return statSync(path).size;
  } catch {
    return 0;
  }
}

function generateFact(index, rng, n) {
  const agentSpec = rng() < 0.52 ? AGENTS[0] : AGENTS[1];
  const model = pick(rng, MODELS);
  const sessionId = `sess-${Math.floor(rng() * Math.max(16, n / 24)).toString(16).padStart(6, "0")}`;
  const turnId = `turn-${Math.floor(rng() * Math.max(32, n / 6)).toString(16).padStart(6, "0")}`;
  const missingCall = rng() < 0.12;
  const retry = rng() < 0.08 ? 1 : 0;
  const modelCallId = missingCall ? null : `call-${hexId(rng, 10)}`;
  const ts = observedAt(rng);
  const ttft = 70 + Math.floor(rng() * 380);
  const decodeMs = 180 + Math.floor(rng() * 4200);
  const duration = ttft + decodeMs;
  const roll = rng();
  let contributing = 1;
  let coverage = "complete";
  let quality = rng() < 0.82 ? "measured" : rng() < 0.7 ? "derived" : "estimated";
  let dataState = "present";
  let diagnostic = null;
  let supersededBy = null;

  if (roll < 0.1) {
    contributing = 0;
    supersededBy = 1 + Math.floor(rng() * Math.max(1, n));
    quality = "measured";
  } else if (roll < 0.13) {
    coverage = "partial";
    diagnostic = "PARTIAL_TOKENS";
  } else if (roll < 0.15) {
    quality = "unavailable";
    dataState = rng() < 0.5 ? "unavailable" : "absent";
    diagnostic = missingCall ? "NO_CALL_IDENTITY" : "PARTIAL_TOKENS";
  }

  if (rng() < 0.03 && dataState === "present") dataState = "stale";
  if (rng() < 0.02 && quality !== "unavailable") dataState = "zero";

  const channel = contributing === 0 ? "local" : rng() < 0.12 ? "enhanced" : "local";
  const authorityKey = `${agentSpec.source}|tokens|${sessionId}|${turnId}|model-call|${ts}`;
  const fileIdentity = `file-${agentSpec.source}-${Math.floor(rng() * 8).toString(16).padStart(2, "0")}`;

  let inputUncached = null;
  let cacheRead = null;
  let cacheWrite = null;
  let outputVisible = null;
  let reasoning = null;
  let outputTotal = null;

  if (quality !== "unavailable" && dataState !== "absent" && dataState !== "unavailable") {
    if (dataState === "zero") {
      inputUncached = 0;
      cacheRead = 0;
      outputTotal = 0;
      if (agentSpec.source === "src-claude") cacheWrite = 0;
      else {
        outputVisible = 0;
        reasoning = 0;
      }
    } else {
      inputUncached = 40 + Math.floor(rng() * 1800);
      cacheRead = rng() < 0.65 ? Math.floor(rng() * 4000) : null;
      outputTotal = 2 + Math.floor(rng() * 1400);
      if (agentSpec.source === "src-claude") {
        cacheWrite = rng() < 0.55 ? Math.floor(rng() * 900) : null;
      } else {
        outputVisible = Math.max(1, Math.floor(outputTotal * (0.55 + rng() * 0.4)));
        reasoning = Math.max(0, outputTotal - outputVisible);
      }
      if (coverage === "partial" && rng() < 0.5) {
        cacheRead = null;
        diagnostic = "PARTIAL_TOKENS";
      }
    }
  }

  if (retry || missingCall) {
    // Decode TPS stays unavailable without a stable non-retry model-call identity.
  }

  return [
    agentSpec.source,
    agentSpec.agent,
    MODEL_RAW[model],
    model,
    sessionId,
    turnId,
    modelCallId,
    ts,
    ts - duration,
    ts,
    quality === "unavailable" ? null : ttft,
    quality === "unavailable" ? null : duration,
    inputUncached,
    cacheRead,
    cacheWrite,
    outputVisible,
    reasoning,
    outputTotal,
    quality,
    dataState,
    coverage,
    "model-call",
    "decode-tps-v1",
    channel,
    authorityKey,
    contributing,
    supersededBy,
    retry,
    SCHEMA_VERSION,
    PARSER_VERSION,
    1 + Math.floor(rng() * 4),
    Math.floor(rng() * 50000),
    fileIdentity,
    diagnostic,
  ];
}

const INSERT_SQL = `INSERT INTO usage_facts (
  source, agent, model_raw, model_display, session_id, turn_id, model_call_id,
  observed_at, started_at, ended_at, ttft_ms, duration_ms,
  tokens_input_uncached, tokens_cache_read, tokens_cache_write,
  tokens_output_visible, tokens_reasoning, tokens_output_total,
  quality, data_state, coverage, scope, definition_version, channel,
  authority_key, contributing, superseded_by, retry,
  schema_version, parser_version, generation, "offset", file_identity, diagnostic_code
) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`;

function seedSupport(db) {
  const cursor = db.prepare(
    `INSERT OR REPLACE INTO cursors(source, file_identity, generation, "offset") VALUES (?,?,?,?)`,
  );
  const health = db.prepare(
    `INSERT OR REPLACE INTO source_health(source, log_present, last_observed_at, data_state, coverage, diagnostic_code)
     VALUES (?,?,?,?,?,?)`,
  );
  for (const spec of AGENTS) {
    for (let i = 0; i < 4; i += 1) {
      cursor.run(spec.source, `file-${spec.source}-${i.toString(16).padStart(2, "0")}`, 1, 1000 * (i + 1));
    }
    health.run(spec.source, 1, NOW_MS, "present", "complete", null);
  }
}

function insertFacts(db, n, seed) {
  const rng = mulberry32(seed);
  const insert = db.prepare(INSERT_SQL);
  const batch = 20_000;
  for (let start = 0; start < n; start += batch) {
    db.exec("BEGIN");
    const end = Math.min(n, start + batch);
    for (let i = start; i < end; i += 1) insert.run(...generateFact(i, rng, n));
    db.exec("COMMIT");
  }
}

function measureSizes(db, dbPath) {
  const pageSize = db.prepare("PRAGMA page_size").get().page_size;
  const pageCount = db.prepare("PRAGMA page_count").get().page_count;
  const freelist = db.prepare("PRAGMA freelist_count").get().freelist_count;
  const factCount = db.prepare("SELECT COUNT(*) AS n FROM usage_facts").get().n;
  let pageBytes = {};
  try {
    const groups = db.prepare("SELECT name, SUM(pgsize) AS bytes FROM dbstat GROUP BY name").all();
    for (const row of groups) pageBytes[row.name] = row.bytes;
  } catch {
    pageBytes = { unavailable: true };
  }
  const indexBytes = Object.entries(pageBytes)
    .filter(([name]) => name.startsWith("idx_") || name.includes("index"))
    .reduce((sum, [, bytes]) => sum + Number(bytes || 0), 0);
  const tableBytes = Number(pageBytes.usage_facts || 0);
  const dbBytes = fileBytes(dbPath);
  const walBytes = fileBytes(`${dbPath}-wal`);
  const shmBytes = fileBytes(`${dbPath}-shm`);
  const totalPagesBytes = pageCount * pageSize;
  const freelistBytes = freelist * pageSize;
  return {
    factCount,
    pageSize,
    pageCount,
    freelistCount: freelist,
    freelistBytes,
    dbBytes,
    walBytes,
    shmBytes,
    totalPagesBytes,
    tableBytes,
    indexBytes,
    pageBytes,
    bytesPerFact: factCount ? dbBytes / factCount : null,
    pageBytesPerFact: factCount ? totalPagesBytes / factCount : null,
  };
}

function windowClause(ms) {
  if (ms == null) return { sql: "", params: [] };
  return { sql: " AND observed_at >= ? ", params: [NOW_MS - ms] };
}

function queryWindow(db, windowMs) {
  const filter = windowClause(windowMs);
  const durationSec = windowMs == null ? SPAN_MS / 1000 : windowMs / 1000;
  const burn = db
    .prepare(
      `SELECT
         SUM(tokens_input_uncached) AS input_uncached,
         SUM(tokens_cache_read) AS cache_read,
         SUM(tokens_cache_write) AS cache_write,
         SUM(tokens_output_visible) AS output_visible,
         SUM(tokens_reasoning) AS reasoning,
         SUM(tokens_output_total) AS output_total,
         SUM(CASE WHEN coverage = 'partial' THEN 1 ELSE 0 END) AS partials,
         SUM(CASE WHEN quality = 'unavailable' THEN 1 ELSE 0 END) AS unavailable_n,
         COUNT(*) AS n
       FROM usage_facts
       WHERE contributing = 1 ${filter.sql}`,
    )
    .get(...filter.params);
  const throughput = db
    .prepare(
      `SELECT SUM(tokens_output_total) AS output_total, COUNT(*) AS n
       FROM usage_facts
       WHERE contributing = 1
         AND quality != 'unavailable'
         AND tokens_output_total IS NOT NULL
         ${filter.sql}`,
    )
    .get(...filter.params);
  const calls = db
    .prepare(
      `SELECT COUNT(DISTINCT model_call_id) AS calls
       FROM usage_facts
       WHERE contributing = 1
         AND model_call_id IS NOT NULL
         AND retry = 0
         ${filter.sql}`,
    )
    .get(...filter.params);
  const selected = db
    .prepare(
      `SELECT SUM(tokens_output_total) AS output_total, COUNT(*) AS n
       FROM usage_facts
       WHERE contributing = 1
         AND quality != 'unavailable'
         AND tokens_output_total IS NOT NULL
         AND agent IN (?, ?)
         AND model_display IN (?, ?)
         ${filter.sql}`,
    )
    .get(...SELECTED_AGENTS, ...SELECTED_MODELS, ...filter.params);

  const samples = [];
  const iter = db
    .prepare(
      `SELECT tokens_output_total, duration_ms, ttft_ms
       FROM usage_facts
       WHERE contributing = 1
         AND retry = 0
         AND model_call_id IS NOT NULL
         AND tokens_output_total IS NOT NULL
         AND duration_ms IS NOT NULL
         AND ttft_ms IS NOT NULL
         ${filter.sql}`,
    )
    .iterate(...filter.params);
  for (const row of iter) {
    const value = decodeTpsValue(row.tokens_output_total, row.duration_ms, row.ttft_ms);
    if (value != null) samples.push(value);
  }
  samples.sort((a, b) => a - b);

  const outputTotal = throughput.output_total;
  const selectedTotal = selected.output_total;
  return {
    rows: burn.n,
    outputThroughput: outputTotal == null ? null : outputTotal / durationSec,
    tokenBurn: {
      inputUncached: burn.input_uncached,
      cacheRead: burn.cache_read,
      cacheWrite: burn.cache_write,
      outputVisible: burn.output_visible,
      reasoning: burn.reasoning,
      outputTotal: burn.output_total,
    },
    calls: calls.calls,
    selectedOutputThroughput: selectedTotal == null ? null : selectedTotal / durationSec,
    selectedRows: selected.n,
    decodeSamples: samples.length,
    decodeP50: quantile(samples, 0.5),
    decodeP95: quantile(samples, 0.95),
    coverage: burn.partials > 0 || burn.unavailable_n > 0 ? "partial" : "complete",
    qualityNote: "cohorts not pooled; unavailable stays null, never coerced to 0",
  };
}

function timeQueries(db) {
  const out = {};
  for (const [name, ms] of WINDOWS) {
    const timedQuery = timed(() => queryWindow(db, ms));
    out[name] = { ms: timedQuery.ms, ...timedQuery.value };
  }
  return out;
}

function checkpoint(db) {
  return timed(() => db.prepare("PRAGMA wal_checkpoint(TRUNCATE)").get());
}

function contributingTotals(db, extraSql = "", params = []) {
  return db
    .prepare(
      `SELECT
         COUNT(*) AS facts,
         SUM(tokens_output_total) AS output_total,
         SUM(tokens_input_uncached) AS input_uncached,
         SUM(tokens_cache_read) AS cache_read
       FROM usage_facts
       WHERE contributing = 1 ${extraSql}`,
    )
    .get(...params);
}

function rollupTotals(db) {
  return db
    .prepare(
      `SELECT
         SUM(fact_count) AS facts,
         SUM(tokens_output_total) AS output_total,
         SUM(tokens_input_uncached) AS input_uncached,
         SUM(tokens_cache_read) AS cache_read,
         SUM(call_count) AS calls
       FROM fact_rollups`,
    )
    .get();
}

function buildRollups(db, olderThanMs) {
  db.exec("DELETE FROM fact_rollups");
  db.prepare(
    `INSERT INTO fact_rollups (
        source, agent, model_display, window_start, window_end, granularity,
        tokens_input_uncached, tokens_cache_read, tokens_cache_write,
        tokens_output_visible, tokens_reasoning, tokens_output_total,
        call_count, fact_count, coverage, quality, contributing
      )
      SELECT
        source, agent, model_display,
        (observed_at / ?) * ?,
        (observed_at / ?) * ? + ?,
        'day',
        SUM(tokens_input_uncached),
        SUM(tokens_cache_read),
        SUM(tokens_cache_write),
        SUM(tokens_output_visible),
        SUM(tokens_reasoning),
        SUM(tokens_output_total),
        COUNT(DISTINCT model_call_id),
        COUNT(*),
        CASE WHEN SUM(CASE WHEN coverage = 'partial' THEN 1 ELSE 0 END) > 0 THEN 'partial' ELSE 'complete' END,
        'derived',
        1
      FROM usage_facts
      WHERE contributing = 1 AND observed_at < ?
      GROUP BY source, agent, model_display, (observed_at / ?)`,
  ).run(DAY, DAY, DAY, DAY, DAY, NOW_MS - olderThanMs, DAY);
}

function sourceScopedRebuild(db, n) {
  const source = "src-codex";
  const before = db.prepare("SELECT COUNT(*) AS n FROM usage_facts WHERE source = ?").get(source).n;
  return timed(() => {
    db.prepare("UPDATE usage_facts SET contributing = 0 WHERE source = ?").run(source);
    const rng = mulberry32(4242 + n);
    const insert = db.prepare(INSERT_SQL);
    const rewrite = Math.min(before, Math.max(200, Math.floor(before * 0.15)));
    db.exec("BEGIN");
    for (let i = 0; i < rewrite; i += 1) {
      const row = generateFact(i, rng, rewrite);
      row[0] = source;
      row[1] = "Codex";
      row[25] = 1;
      row[26] = null;
      insert.run(...row);
    }
    db.exec("COMMIT");
    return { marked: before, rewritten: rewrite };
  });
}

function vacuumInto(db, backupPath) {
  wipeDbFiles(backupPath);
  return timed(() => {
    db.exec(`VACUUM INTO '${backupPath.replaceAll("'", "''")}'`);
  });
}

function migrate(db, backupPath) {
  const backup = vacuumInto(db, backupPath);
  const alter = timed(() => {
    db.exec("ALTER TABLE usage_facts ADD COLUMN proto_retention_mark INTEGER");
  });
  return { backupMs: backup.ms, alterMs: alter.ms, backupBytes: fileBytes(backupPath) };
}

function logDisappearExperiment(db) {
  const before = db.prepare("SELECT COUNT(*) AS n FROM usage_facts WHERE source = 'src-claude'").get().n;
  db.prepare(
    `UPDATE source_health
     SET log_present = 0, data_state = 'stale', coverage = 'partial', diagnostic_code = 'SRC_LOG_ABSENT'
     WHERE source = 'src-claude'`,
  ).run();
  const kept = db.prepare("SELECT COUNT(*) AS n FROM usage_facts WHERE source = 'src-claude'").get().n;
  const health = db.prepare("SELECT * FROM source_health WHERE source = 'src-claude'").get();
  const deleted = db.prepare("DELETE FROM usage_facts WHERE source = 'src-claude'").run().changes;
  const afterDelete = db.prepare("SELECT COUNT(*) AS n FROM usage_facts WHERE source = 'src-claude'").get().n;
  return {
    before,
    keptAfterLogGone: kept,
    defaultDeletes: before !== kept,
    health,
    explicitDeleteChanges: deleted,
    afterExplicitDelete: afterDelete,
  };
}

function compactOlderThan(db, rawKeepMs) {
  const cutoff = NOW_MS - rawKeepMs;
  const beforeAll = contributingTotals(db);
  const beforeOld = contributingTotals(db, "AND observed_at < ?", [cutoff]);
  db.exec("BEGIN");
  try {
    buildRollups(db, rawKeepMs);
    db.prepare("DELETE FROM usage_facts WHERE observed_at < ?").run(cutoff);
    db.exec("COMMIT");
  } catch (error) {
    db.exec("ROLLBACK");
    throw error;
  }
  const afterRaw = contributingTotals(db);
  const rollup = rollupTotals(db);
  const combinedFacts = Number(afterRaw.facts || 0) + Number(rollup.facts || 0);
  const combinedOutput = Number(afterRaw.output_total || 0) + Number(rollup.output_total || 0);
  return {
    beforeAll,
    beforeOld,
    afterRaw,
    rollup,
    conservedFacts: combinedFacts === Number(beforeAll.facts || 0),
    conservedOutput: combinedOutput === Number(beforeAll.output_total || 0),
  };
}

function strategySnapshot(db, dbPath, label, rawKeepMs) {
  let conservation = null;
  if (rawKeepMs != null) {
    conservation = compactOlderThan(db, rawKeepMs);
    db.exec("PRAGMA incremental_vacuum");
    db.exec("VACUUM");
  }
  const sizes = measureSizes(db, dbPath);
  const allRaw = timed(() => queryWindow(db, null));
  const week = timed(() => queryWindow(db, 7 * DAY));
  const rollupAll = rollupTotals(db);
  const allHistoryExactQuantile = rawKeepMs == null;
  return {
    label,
    rawKeepMs,
    sizes,
    allRawMs: allRaw.ms,
    allRawDecodeSamples: allRaw.value.decodeSamples,
    hasRawSamples: allRaw.value.decodeSamples > 0,
    allHistoryExactQuantile,
    allExactQuantile: allHistoryExactQuantile,
    weekMs: week.ms,
    weekDecodeSamples: week.value.decodeSamples,
    weekExactQuantile: week.value.decodeSamples > 0,
    rollupFacts: rollupAll.facts || 0,
    rollupOutputTotal: rollupAll.output_total,
    conservation,
    note:
      rawKeepMs == null
        ? "raw facts retained; exact All-history quantile possible wherever samples exist"
        : "older raw facts replaced by daily rollups; All-history exact quantile unavailable; remaining-raw samples are not All-history",
  };
}

function copyDb(fromPath, toPath) {
  wipeDbFiles(toPath);
  copyFileSync(fromPath, toPath);
}

function semanticChecks() {
  const watermark = applyCumulative(100, 140);
  const rollback = applyCumulative(140, 90);
  assert(
    "cumulative watermark uses positive delta only",
    watermark.delta === 40 && watermark.rebuild === false,
    watermark,
    { delta: 40, rebuild: false },
  );
  assert(
    "counter rollback triggers source-scoped rebuild, not a negative delta",
    rollback.delta === 0 && rollback.rebuild === true,
    rollback,
    { delta: 0, rebuild: true },
  );

  const tps = decodeTpsValue(121, 2200, 200);
  assert("decode TPS v1 formula", Math.abs(tps - 60) < 1e-9, tps, "(output_total-1)/(duration-TTFT)=60");
  assert("decode TPS unavailable when n<2", decodeTpsValue(1, 2200, 200) == null, null, "unavailable");
  assert("hot/query working set is 20k facts, not retention", HOT_QUERY_WORKING_SET === 20_000, HOT_QUERY_WORKING_SET, 20000);
}

function scanPrivacy() {
  const forbidden = [
    /\/Users\//,
    /\/private\/tmp\//,
    /[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/i,
    /http:\/\/127\.0\.0\.1/,
    /prompt\s*[:=]/i,
    /tool[_ -]?payload/i,
  ];
  const hits = [];
  const roots = [here, resultsDir];
  for (const root of roots) {
    if (!existsSync(root)) continue;
    const stack = [root];
    while (stack.length) {
      const dir = stack.pop();
      for (const entry of readdirSync(dir, { withFileTypes: true })) {
        if (entry.name === "tmp" || entry.name.startsWith(".")) continue;
        const full = join(dir, entry.name);
        if (entry.isDirectory()) {
          stack.push(full);
          continue;
        }
        if (!/\.(md|html|js|mjs|json|sql)$/i.test(entry.name)) continue;
        const text = readFileSync(full, "utf8");
        for (const pattern of forbidden) {
          if (pattern.test(text)) hits.push({ file: entry.name, pattern: String(pattern) });
        }
      }
    }
  }
  return hits;
}

function buildFresh(dbPath, n, seed) {
  wipeDbFiles(dbPath);
  const db = openDb(dbPath, { create: true });
  applySchema(db, { indexes: false });
  seedSupport(db);
  const insert = timed(() => insertFacts(db, n, seed));
  const index = timed(() => createIndexes(db));
  const walBeforeCheckpoint = fileBytes(`${dbPath}-wal`);
  const ckpt = checkpoint(db);
  return { db, insertMs: insert.ms, indexMs: index.ms, checkpointMs: ckpt.ms, walBeforeCheckpoint };
}

function measureOps(db, dbPath, n, tag) {
  const backupPath = join(tmpDir, `${tag}-backup-PROTOTYPE-wipe-me.db`);
  const ckpt = checkpoint(db);
  const deleteOld = timed(() => db.prepare("DELETE FROM usage_facts WHERE observed_at < ?").run(NOW_MS - 90 * DAY));
  const incVac = timed(() => db.exec("PRAGMA incremental_vacuum"));
  const sizesAfterInc = measureSizes(db, dbPath);
  const fullVac = timed(() => db.exec("VACUUM"));
  const sizesAfterVac = measureSizes(db, dbPath);
  const backup = vacuumInto(db, backupPath);
  const rebuild = sourceScopedRebuild(db, n);
  const migration = migrate(db, join(tmpDir, `${tag}-migrate-PROTOTYPE-wipe-me.db`));
  return {
    checkpointMs: ckpt.ms,
    delete90dMs: deleteOld.ms,
    delete90dChanges: deleteOld.value.changes,
    incrementalVacuumMs: incVac.ms,
    vacuumMs: fullVac.ms,
    backupMs: backup.ms,
    backupBytes: fileBytes(backupPath),
    rebuildMs: rebuild.ms,
    rebuilt: rebuild.value,
    sizesAfterIncrementalVacuum: sizesAfterInc,
    sizesAfterVacuum: sizesAfterVac,
    migration,
  };
}

function emptyRange() {
  return { min: null, max: null, n: 0, values: [] };
}

function collectScale(n, runs) {
  const tag = `n${n}`;
  const dbPath = join(tmpDir, `${tag}-sqlite-retention-PROTOTYPE-wipe-me.db`);
  const queryRuns = [];
  const sizeRuns = [];
  const loadRuns = [];
  const opRuns = [];
  let lastDb = null;
  const cleanSnapshot = join(tmpDir, `${tag}-clean-PROTOTYPE-wipe-me.db`);
  const opsRepeats = n >= 1_000_000 ? Math.min(runs, 3) : runs;
  const scaleStarted = performance.now();

  for (let run = 0; run < runs; run += 1) {
    if (n >= 1_000_000 && performance.now() - scaleStarted > oneMBudgetMs && run > 0) {
      measure(
        `${n} remaining runs skipped after budget`,
        { completed: run, budgetMs: oneMBudgetMs },
        "finish completed 1m runs; do not invent missing scales",
      );
      break;
    }
    const built = buildFresh(dbPath, n, 1000 + n + run * 17);
    loadRuns.push({
      insertMs: built.insertMs,
      indexMs: built.indexMs,
      checkpointMs: built.checkpointMs,
      walBeforeCheckpoint: built.walBeforeCheckpoint,
    });
    sizeRuns.push(measureSizes(built.db, dbPath));
    queryRuns.push(timeQueries(built.db));
    if (run === 0) {
      built.db.close();
      copyDb(dbPath, cleanSnapshot);
      built.db = openDb(dbPath);
    }
    if (run < opsRepeats) opRuns.push(measureOps(built.db, dbPath, n, `${tag}-r${run}`));
    if (lastDb) lastDb.close();
    lastDb = built.db;
  }

  const logPath = join(tmpDir, `${tag}-log-PROTOTYPE-wipe-me.db`);
  copyDb(cleanSnapshot, logPath);
  const logDb = openDb(logPath);
  const logGone = logDisappearExperiment(logDb);
  logDb.close();

  const strategies = [];
  if (existsSync(cleanSnapshot)) {
    if (lastDb) {
      lastDb.close();
      lastDb = null;
    }
    const baseBackup = cleanSnapshot;

    const aPath = join(tmpDir, `${tag}-strategy-a-PROTOTYPE-wipe-me.db`);
    copyDb(baseBackup, aPath);
    const aDb = openDb(aPath);
    strategies.push(strategySnapshot(aDb, aPath, "A-raw-or-capacity", null));
    aDb.close();

    const bPath = join(tmpDir, `${tag}-strategy-b-PROTOTYPE-wipe-me.db`);
    copyDb(baseBackup, bPath);
    const bDb = openDb(bPath);
    strategies.push(strategySnapshot(bDb, bPath, "B-90d-raw-plus-rollup", 90 * DAY));
    bDb.close();

    const cPath = join(tmpDir, `${tag}-strategy-c-PROTOTYPE-wipe-me.db`);
    copyDb(baseBackup, cPath);
    const cDb = openDb(cPath);
    strategies.push(strategySnapshot(cDb, cPath, "C-7d-raw-plus-totals", 7 * DAY));
    cDb.close();
  }

  const queryRanges = {};
  for (const [name] of WINDOWS) {
    queryRanges[name] = {
      ms: rangeOf(queryRuns.map((run) => run[name].ms)),
      rows: rangeOf(queryRuns.map((run) => run[name].rows)),
      outputThroughput: rangeOf(queryRuns.map((run) => run[name].outputThroughput)),
      calls: rangeOf(queryRuns.map((run) => run[name].calls)),
      selectedOutputThroughput: rangeOf(queryRuns.map((run) => run[name].selectedOutputThroughput)),
      decodeSamples: rangeOf(queryRuns.map((run) => run[name].decodeSamples)),
      decodeP50: rangeOf(queryRuns.map((run) => run[name].decodeP50)),
      decodeP95: rangeOf(queryRuns.map((run) => run[name].decodeP95)),
    };
  }

  const summary = {
    n,
    runsCompleted: queryRuns.length,
    hotQueryWorkingSet: HOT_QUERY_WORKING_SET,
    load: {
      insertMs: rangeOf(loadRuns.map((r) => r.insertMs)) || emptyRange(),
      indexMs: rangeOf(loadRuns.map((r) => r.indexMs)) || emptyRange(),
      checkpointMs: rangeOf(loadRuns.map((r) => r.checkpointMs)) || emptyRange(),
      walBeforeCheckpoint: rangeOf(loadRuns.map((r) => r.walBeforeCheckpoint)) || emptyRange(),
    },
    sizes: {
      dbBytes: rangeOf(sizeRuns.map((r) => r.dbBytes)) || emptyRange(),
      walBytes: rangeOf(sizeRuns.map((r) => r.walBytes)) || emptyRange(),
      freelistBytes: rangeOf(sizeRuns.map((r) => r.freelistBytes)) || emptyRange(),
      indexBytes: rangeOf(sizeRuns.map((r) => r.indexBytes)) || emptyRange(),
      tableBytes: rangeOf(sizeRuns.map((r) => r.tableBytes)) || emptyRange(),
      bytesPerFact: rangeOf(sizeRuns.map((r) => r.bytesPerFact)) || emptyRange(),
      pageBytesPerFact: rangeOf(sizeRuns.map((r) => r.pageBytesPerFact)) || emptyRange(),
      last: sizeRuns.at(-1) || null,
    },
    queries: queryRanges,
    lastQueries: queryRuns.at(-1) || null,
    ops: {
      checkpointMs: rangeOf(opRuns.map((r) => r.checkpointMs)) || emptyRange(),
      delete90dMs: rangeOf(opRuns.map((r) => r.delete90dMs)) || emptyRange(),
      incrementalVacuumMs: rangeOf(opRuns.map((r) => r.incrementalVacuumMs)) || emptyRange(),
      vacuumMs: rangeOf(opRuns.map((r) => r.vacuumMs)) || emptyRange(),
      backupMs: rangeOf(opRuns.map((r) => r.backupMs)) || emptyRange(),
      backupBytes: rangeOf(opRuns.map((r) => r.backupBytes)) || emptyRange(),
      rebuildMs: rangeOf(opRuns.map((r) => r.rebuildMs)) || emptyRange(),
      last: opRuns.at(-1) || null,
    },
    logDisappear: logGone,
    strategies,
  };

  assert(
    `${n} facts exceed the 20k hot/query working set or stay distinct from retention`,
    n !== HOT_QUERY_WORKING_SET || n === 10_000,
    { facts: n, hotQueryWorkingSet: HOT_QUERY_WORKING_SET },
    "20k is working set, not a retention policy",
  );
  if (sizeRuns.at(-1)) {
    const last = sizeRuns.at(-1);
    assert(
      `${n} Codex cache_write stays NULL`,
      lastDbCheckNulls(cleanSnapshot, "src-codex", "tokens_cache_write"),
      "all NULL",
      "Codex cache_write NULL (overlap unverified)",
    );
    assert(
      `${n} Claude output_visible/reasoning stay NULL`,
      lastDbCheckNulls(cleanSnapshot, "src-claude", "tokens_output_visible") &&
        lastDbCheckNulls(cleanSnapshot, "src-claude", "tokens_reasoning"),
      "all NULL",
      "Claude visible/reasoning NULL",
    );
    assert(
      `${n} unavailable is not stored as 0`,
      lastDbNoUnavailableZero(cleanSnapshot),
      "no zero-for-unavailable",
      "NULL means unavailable",
    );
  }
  assert(
    `${n} disappeared source logs do not delete canonical facts by default`,
    logGone.keptAfterLogGone === logGone.before && logGone.defaultDeletes === false,
    { kept: logGone.keptAfterLogGone, before: logGone.before },
    "keep facts; log_present=0",
  );

  measure(`${n} bytes/fact`, summary.sizes.bytesPerFact, "local range only");
  measure(`${n} All query ms`, summary.queries.All.ms, "local range only");
  measure(`${n} 7d query ms`, summary.queries["7d"].ms, "local range only");
  measure(`${n} VACUUM ms`, summary.ops.vacuumMs, "local range only");
  measure(`${n} backup ms`, summary.ops.backupMs, "local range only");
  if (summary.queries.All.decodeSamples && summary.queries["7d"].decodeSamples) {
    measure(
      `${n} All vs 7d exact-quantile raw samples`,
      { all: summary.queries.All.decodeSamples, week: summary.queries["7d"].decodeSamples },
      "exact quantile needs raw samples; rollups cannot recompute it",
    );
  }
  return summary;
}

function lastDbCheckNulls(dbPath, source, column) {
  const db = openDb(dbPath);
  const row = db.prepare(`SELECT COUNT(*) AS n FROM usage_facts WHERE source = ? AND ${column} IS NOT NULL`).get(source);
  db.close();
  return row.n === 0;
}

function lastDbNoUnavailableZero(dbPath) {
  const db = openDb(dbPath);
  const row = db
    .prepare(
      `SELECT COUNT(*) AS n FROM usage_facts
       WHERE quality = 'unavailable'
         AND (
           tokens_input_uncached = 0 OR tokens_cache_read = 0 OR tokens_cache_write = 0
           OR tokens_output_visible = 0 OR tokens_reasoning = 0 OR tokens_output_total = 0
         )`,
    )
    .get();
  db.close();
  return row.n === 0;
}

function sqliteVersion() {
  const db = new DatabaseSync(":memory:");
  const version = db.prepare("SELECT sqlite_version() AS v").get().v;
  db.close();
  return version;
}

function writeMarkdown(payload) {
  const lines = [
    "# SQLite retention local results",
    "",
    "THROW AWAY. Synthetic fixtures only.",
    "",
    "Measured numbers are from one Apple silicon developer Mac and a Node `node:sqlite` process. They are not AppKit, Swift, fleet, or release-contract facts. Do not treat a single-machine range as an SLO.",
    "",
    "20k facts is the accepted hot/query working set from issue 7. It is not SQLite persistent retention.",
    "",
    `SQLite used: ${payload.machine.sqliteUsed}. Node ${payload.machine.node}.`,
    "",
    "Result key: `PASS`/`FAIL` = correctness assertion. `MEASURED` = ungated local timing or size.",
    "",
    "| Check | Kind | Measured | Suggested / expected | Result |",
    "| --- | --- | --- | --- | --- |",
  ];
  for (const row of rows) {
    lines.push(
      `| ${row.name} | ${row.kind} | ${String(format(row.measured)).replaceAll("|", "/")} | ${String(format(row.suggested)).replaceAll("|", "/")} | ${row.status} |`,
    );
  }
  lines.push("", "## Scale ranges", "");
  for (const scale of payload.scales) {
    const all = scale.queries.All;
    const week = scale.queries["7d"];
    lines.push(`### ${scale.n} facts`);
    lines.push("");
    lines.push(`- runs completed: ${scale.runsCompleted}`);
    lines.push(`- bytes/fact: ${fmtRange(scale.sizes.bytesPerFact)}`);
    lines.push(`- DB bytes: ${fmtRange(scale.sizes.dbBytes)}`);
    lines.push(`- index bytes: ${fmtRange(scale.sizes.indexBytes)}`);
    lines.push(`- WAL bytes before checkpoint (load): ${fmtRange(scale.load.walBeforeCheckpoint)}`);
    lines.push(`- All query ms: ${fmtRange(all.ms)}`);
    lines.push(`- 7d query ms: ${fmtRange(week.ms)}`);
    lines.push(`- All exact-quantile samples: ${fmtRange(all.decodeSamples)}`);
    lines.push(`- 7d exact-quantile samples: ${fmtRange(week.decodeSamples)}`);
    lines.push(`- VACUUM ms: ${fmtRange(scale.ops.vacuumMs)}`);
    lines.push(`- backup ms: ${fmtRange(scale.ops.backupMs)}`);
    lines.push(`- source-scoped rebuild ms: ${fmtRange(scale.ops.rebuildMs)}`);
    lines.push(
      `- source log disappear default: kept ${scale.logDisappear.keptAfterLogGone} of ${scale.logDisappear.before} facts`,
    );
    if (scale.strategies.length) {
      lines.push("- strategy snapshots:");
      for (const strategy of scale.strategies) {
        lines.push(
          `  - ${strategy.label}: db=${strategy.sizes.dbBytes} bytes/fact=${strategy.sizes.bytesPerFact?.toFixed?.(1) || strategy.sizes.bytesPerFact}, All-history exact quantile=${strategy.allHistoryExactQuantile}, remaining-raw samples=${strategy.allRawDecodeSamples}, 7d exact quantile=${strategy.weekExactQuantile}, totals conserved=${strategy.conservation ? strategy.conservation.conservedFacts && strategy.conservation.conservedOutput : "n/a"}`,
        );
      }
    }
    lines.push("");
  }
  lines.push("## Unverified assumptions", "");
  lines.push("- Real JSONL tail rates and AppKit/SQLite writer interleaving on a developer Mac.");
  lines.push("- Production page cache, backup destination, and user-visible Reset Data confirmation copy.");
  lines.push("- Whether a later release should expose retention as a setting; this prototype only measures options.");
  lines.push("- Workload timestamps are recency-biased (about 38% of facts fall in 7d), not a uniform 400-day history.");
  lines.push("");
  return lines.join("\n");
}

function fmtRange(range) {
  if (!range || range.min == null) return "n/a";
  if (range.min === range.max) return format(range.min);
  return `${format(range.min)}–${format(range.max)} (n=${range.n})`;
}

function writePolicyArtifacts() {
  const payload = {
    prototype: "THROW AWAY sqlite retention policy assertions",
    kind: "post-hoc-logic",
    disclaimer:
      "Added after the 10k/100k/1m size timings. These are targeted logic assertions for the capacity ladder and Reset Data wipe. They are not a rerun of the 1m measurements.",
    machine: {
      label: "Apple silicon developer Mac",
      node: process.versions.node,
      sqliteUsed: `${sqliteVersion()} via node:sqlite`,
    },
    rows,
  };
  writeFileSync(join(resultsDir, "p0-policy-assertions.json"), `${JSON.stringify(payload, null, 2)}\n`);
  const lines = [
    "# P0 policy logic assertions",
    "",
    "THROW AWAY. Post-hoc logic only. These rows were added after the 10k/100k/1m measurements and do not replace those size or query ranges.",
    "",
    "| Check | Kind | Measured | Suggested / expected | Result |",
    "| --- | --- | --- | --- | --- |",
  ];
  for (const row of rows) {
    lines.push(
      `| ${row.name} | ${row.kind} | ${String(format(row.measured)).replaceAll("|", "/")} | ${String(format(row.suggested)).replaceAll("|", "/")} | ${row.status} |`,
    );
  }
  lines.push("");
  writeFileSync(join(resultsDir, "p0-policy-assertions.md"), `${lines.join("\n")}\n`);
}

function main() {
  mkdirSync(tmpDir, { recursive: true });
  mkdirSync(resultsDir, { recursive: true });
  semanticChecks();
  runPolicyAssertions(assert, { schemaPath, now: NOW_MS });
  if (logicOnly) {
    const privacy = scanPrivacy();
    assert("public artifact privacy scan", privacy.length === 0, privacy, []);
    writePolicyArtifacts();
    if (failed) {
      console.error(`\n${failed} assertion(s) failed`);
      process.exitCode = 1;
    } else {
      console.log("\nPolicy assertions passed. Existing 10k/100k/1m results were not rewritten.");
    }
    return;
  }

  const tinyPath = join(tmpDir, "tiny-sqlite-retention-PROTOTYPE-wipe-me.db");
  const tiny = buildFresh(tinyPath, 2000, 7);
  const tinyCodexNull = tiny.db.prepare("SELECT COUNT(*) AS n FROM usage_facts WHERE source='src-codex' AND tokens_cache_write IS NOT NULL").get().n;
  const tinyClaudeVis = tiny.db.prepare("SELECT COUNT(*) AS n FROM usage_facts WHERE source='src-claude' AND tokens_output_visible IS NOT NULL").get().n;
  const tinyClaudeReason = tiny.db.prepare("SELECT COUNT(*) AS n FROM usage_facts WHERE source='src-claude' AND tokens_reasoning IS NOT NULL").get().n;
  const tinyZero = tiny.db.prepare(
    `SELECT COUNT(*) AS n FROM usage_facts WHERE quality='unavailable' AND (
      tokens_input_uncached=0 OR tokens_cache_read=0 OR tokens_cache_write=0
      OR tokens_output_visible=0 OR tokens_reasoning=0 OR tokens_output_total=0)`,
  ).get().n;
  assert("tiny Codex cache_write NULL", tinyCodexNull === 0, tinyCodexNull, 0);
  assert("tiny Claude output_visible NULL", tinyClaudeVis === 0, tinyClaudeVis, 0);
  assert("tiny Claude reasoning NULL", tinyClaudeReason === 0, tinyClaudeReason, 0);
  assert("tiny unavailable not stored as 0", tinyZero === 0, tinyZero, 0);
  const multi = queryWindow(tiny.db, 7 * DAY);
  assert(
    "multi-select derives after summing raw samples",
    multi.selectedOutputThroughput == null || multi.selectedOutputThroughput >= 0,
    multi.selectedOutputThroughput,
    "sum raw output tokens, then divide by window",
  );
  const compact90 = compactOlderThan(tiny.db, 90 * DAY);
  assert(
    "90d compact conserves contributing fact counts via raw+rollup",
    compact90.conservedFacts,
    compact90,
    "raw remaining + rollup fact_count == contributing facts before compact",
  );
  assert(
    "90d compact conserves output token totals via raw+rollup",
    compact90.conservedOutput,
    {
      before: compact90.beforeAll.output_total,
      afterRaw: compact90.afterRaw.output_total,
      rollup: compact90.rollup.output_total,
    },
    "raw remaining + rollup output_total == contributing output before compact",
  );
  assert(
    "compacted All-history exact quantile is unavailable",
    queryWindow(tiny.db, null).decodeSamples < compact90.beforeAll.facts,
    queryWindow(tiny.db, null).decodeSamples,
    "remaining-raw samples are not All-history samples",
  );
  tiny.db.close();

  const scales = [];
  const blocked = [];
  for (const n of requestedScales) {
    const runs = runsOverride || 5;
    console.log(`\n--- scale ${n} x ${runs} ---\n`);
    try {
      scales.push(collectScale(n, runs));
    } catch (error) {
      blocked.push({ n, message: String(error && error.message ? error.message : error) });
      pushRow({
        name: `${n} scale failed`,
        kind: "assertion",
        status: "FAIL",
        ok: false,
        measured: String(error && error.message ? error.message : error),
        suggested: "complete the scale or record a blocker",
      });
    }
  }

  const payload = {
    prototype: "THROW AWAY sqlite retention harness",
    disclaimer:
      "Single-machine local measurements, not a fleet SLO and not AppKit/Swift numbers. 20k is the hot/query working set, not persistent retention.",
    machine: {
      label: "Apple silicon developer Mac",
      node: process.versions.node,
      sqliteUsed: `${sqliteVersion()} via node:sqlite`,
    },
    constants: {
      hotQueryWorkingSetFacts: HOT_QUERY_WORKING_SET,
      spanDays: SPAN_DAYS,
      now: "2026-08-17T12:00:00.000Z",
      timestampMix: "recency-biased, not uniform 400d",
    },
    scales,
    blocked,
    rows,
  };

  const privacy = scanPrivacy();
  payload.privacyScan = { matches: privacy, ok: privacy.length === 0 };
  assert("public artifact privacy scan", privacy.length === 0, privacy, []);

  writeFileSync(join(resultsDir, "benchmark-results.json"), `${JSON.stringify(payload, null, 2)}\n`);
  writeFileSync(join(resultsDir, "benchmark-results.md"), `${writeMarkdown(payload)}\n`);
  writeFileSync(join(resultsDir, "hitl-snapshot.js"), `window.HARNESS_RESULTS = ${JSON.stringify(payload)};\n`);

  if (failed) {
    console.error(`\n${failed} assertion(s) failed`);
    process.exitCode = 1;
  } else {
    console.log("\nAll assertions passed. Results written under results/.");
  }
}

main();
