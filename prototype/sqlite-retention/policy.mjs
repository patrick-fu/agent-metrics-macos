// THROW AWAY — capacity ceiling and Reset Data policy for the SQLite retention prototype.
// Synthetic fixtures only. Not production AppKit/SQLite code.

import { DatabaseSync } from "node:sqlite";
import { readFileSync } from "node:fs";

export const DAY = 86_400_000;
export const PROTECTED_RAW_MS = 7 * DAY;
export const COMPACT_AFTER_MS = 90 * DAY;
export const WARN_BYTES = 750 * 1024 * 1024;
export const HARD_BYTES = 1024 * 1024 * 1024;
export const WARN_ROWS = 1_500_000;
export const HARD_ROWS = 2_000_000;

export const TELEMETRY_TABLES = Object.freeze([
  "usage_facts",
  "usage_observations",
  "fact_rollups",
  "cursors",
  "watermarks",
  "source_health",
  "diagnostics",
  "snapshots",
  "migration_backups",
  "export_copies",
  "retention_state",
]);

export const RESET_CONFIRMATION =
  "Reset Data deletes every App-owned telemetry store: Usage Facts, observations, rollups, cursors, watermarks, source state, opaque identities, diagnostics, snapshots, caches, migration backups, and App-managed export copies. Schema and non-telemetry preferences stay. Source Codex and Claude Code logs are not modified. Files you already saved outside the app cannot be deleted by the app.";

export function capacityTrigger({ bytes, rows }, limits = {}) {
  const warnBytes = limits.warnBytes ?? WARN_BYTES;
  const hardBytes = limits.hardBytes ?? HARD_BYTES;
  const warnRows = limits.warnRows ?? WARN_ROWS;
  const hardRows = limits.hardRows ?? HARD_ROWS;
  const hit = (overBytes, overRows) => {
    if (overBytes && overRows) return "bytes+rows";
    if (overBytes) return "bytes";
    if (overRows) return "rows";
    return null;
  };
  return {
    warn: bytes >= warnBytes || rows >= warnRows,
    hard: bytes >= hardBytes || rows >= hardRows,
    warnBy: hit(bytes >= warnBytes, rows >= warnRows),
    hardBy: hit(bytes >= hardBytes, rows >= hardRows),
  };
}

export function applySchema(db, schemaSql) {
  const parts = schemaSql
    .split(";")
    .map((part) => part.trim())
    .filter(Boolean);
  for (const part of parts) db.exec(`${part};`);
}

export function measureLogicalRows(db) {
  const raw = db.prepare("SELECT COUNT(*) AS n FROM usage_facts").get().n;
  const rollup = db.prepare("SELECT COALESCE(SUM(fact_count), 0) AS n FROM fact_rollups").get().n;
  return Number(raw) + Number(rollup);
}

function upsertRetentionState(db, patch) {
  const current = db.prepare("SELECT * FROM retention_state WHERE id = 1").get() || {
    id: 1,
    warn_hit: 0,
    hard_hit: 0,
    trigger: null,
    ingest_paused: 0,
    coverage: "complete",
    pruned_before: null,
    earliest_retained_at: null,
    diagnostic_code: null,
  };
  const next = { ...current, ...patch, id: 1 };
  db.prepare(
    `INSERT OR REPLACE INTO retention_state
      (id, warn_hit, hard_hit, trigger, ingest_paused, coverage, pruned_before, earliest_retained_at, diagnostic_code)
     VALUES (1,?,?,?,?,?,?,?,?)`,
  ).run(
    next.warn_hit,
    next.hard_hit,
    next.trigger,
    next.ingest_paused,
    next.coverage,
    next.pruned_before,
    next.earliest_retained_at,
    next.diagnostic_code,
  );
  return db.prepare("SELECT * FROM retention_state WHERE id = 1").get();
}

export function earliestRetainedAt(db) {
  const raw = db.prepare("SELECT MIN(observed_at) AS t FROM usage_facts").get().t;
  const rollup = db.prepare("SELECT MIN(window_start) AS t FROM fact_rollups").get().t;
  const times = [raw, rollup].filter((value) => value != null);
  return times.length ? Math.min(...times) : null;
}

function compactOlderThan(db, now, olderThanMs) {
  const cutoff = now - olderThanMs;
  db.exec("BEGIN");
  try {
    db.prepare("DELETE FROM fact_rollups WHERE window_end <= ?").run(cutoff);
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
    ).run(DAY, DAY, DAY, DAY, DAY, cutoff, DAY);
    db.prepare("DELETE FROM usage_facts WHERE observed_at < ?").run(cutoff);
    db.exec("COMMIT");
  } catch (error) {
    db.exec("ROLLBACK");
    throw error;
  }
}

export function enforceCapacity(db, now, limits = {}) {
  const protectedRawMs = limits.protectedRawMs ?? PROTECTED_RAW_MS;
  const compactAfterMs = limits.compactAfterMs ?? COMPACT_AFTER_MS;
  const measure = limits.measure || (() => ({
    bytes: limits.bytes ?? 0,
    rows: measureLogicalRows(db),
  }));
  const steps = [];
  const protectedFrom = now - protectedRawMs;

  const snap = () => {
    const measured = measure();
    return { ...measured, ...capacityTrigger(measured, limits) };
  };

  let status = snap();
  upsertRetentionState(db, {
    warn_hit: status.warn ? 1 : 0,
    hard_hit: status.hard ? 1 : 0,
    trigger: status.hardBy || status.warnBy,
    diagnostic_code: status.hard ? "CAPACITY_HARD" : status.warn ? "CAPACITY_WARN" : null,
    earliest_retained_at: earliestRetainedAt(db),
  });
  if (!status.hard) {
    return finalize(db, status, steps, false);
  }

  const superseded = db.prepare(
    "DELETE FROM usage_facts WHERE contributing = 0 OR superseded_by IS NOT NULL",
  ).run();
  steps.push({ action: "delete-superseded", changes: superseded.changes });
  status = snap();
  if (!status.hard) return finalize(db, status, steps, false);

  compactOlderThan(db, now, compactAfterMs);
  steps.push({ action: "compact-gt-90d" });
  status = snap();
  if (!status.hard) return finalize(db, status, steps, false);

  while (status.hard) {
    const oldest = db.prepare("SELECT MIN(window_start) AS t FROM fact_rollups").get().t;
    if (oldest == null) break;
    const deleted = db.prepare("DELETE FROM fact_rollups WHERE window_start = ?").run(oldest);
    steps.push({ action: "delete-oldest-rollup", windowStart: oldest, changes: deleted.changes });
    const state = db.prepare("SELECT pruned_before FROM retention_state WHERE id = 1").get();
    upsertRetentionState(db, {
      pruned_before: Math.max(state?.pruned_before || 0, oldest + DAY),
      coverage: "partial",
      diagnostic_code: "RETENTION_PRUNED",
    });
    status = snap();
  }
  if (!status.hard) return finalize(db, status, steps, false);

  while (status.hard) {
    const oldest = db.prepare(
      "SELECT MIN(observed_at) AS t FROM usage_facts WHERE observed_at < ?",
    ).get(protectedFrom).t;
    if (oldest == null) break;
    const dayStart = Math.floor(oldest / DAY) * DAY;
    const deleted = db.prepare(
      "DELETE FROM usage_facts WHERE observed_at >= ? AND observed_at < ? AND observed_at < ?",
    ).run(dayStart, dayStart + DAY, protectedFrom);
    steps.push({ action: "delete-oldest-7-90d-raw", dayStart, changes: deleted.changes });
    const state = db.prepare("SELECT pruned_before FROM retention_state WHERE id = 1").get();
    upsertRetentionState(db, {
      pruned_before: Math.max(state?.pruned_before || 0, Math.min(dayStart + DAY, protectedFrom)),
      coverage: "partial",
      diagnostic_code: "RETENTION_PRUNED",
    });
    status = snap();
  }

  if (status.hard) {
    upsertRetentionState(db, {
      ingest_paused: 1,
      coverage: "partial",
      diagnostic_code: "CAPACITY_PROTECTED_WINDOW",
    });
    steps.push({ action: "pause-ingest", protectedFrom });
    return finalize(db, status, steps, true);
  }
  return finalize(db, status, steps, false);
}

function finalize(db, status, steps, paused) {
  const state = upsertRetentionState(db, {
    warn_hit: status.warn ? 1 : 0,
    hard_hit: status.hard ? 1 : 0,
    trigger: status.hardBy || status.warnBy,
    ingest_paused: paused ? 1 : 0,
    earliest_retained_at: earliestRetainedAt(db),
    diagnostic_code: paused
      ? "CAPACITY_PROTECTED_WINDOW"
      : (db.prepare("SELECT coverage FROM retention_state WHERE id = 1").get()?.coverage === "partial")
        ? "RETENTION_PRUNED"
        : status.hard
          ? "CAPACITY_HARD"
          : status.warn
            ? "CAPACITY_WARN"
            : db.prepare("SELECT diagnostic_code FROM retention_state WHERE id = 1").get()?.diagnostic_code,
  });
  return {
    bytes: status.bytes,
    rows: status.rows,
    warn: status.warn,
    hard: status.hard,
    warnBy: status.warnBy,
    hardBy: status.hardBy,
    steps,
    ingestPaused: paused,
    coverage: state.coverage,
    prunedBefore: state.pruned_before,
    earliestRetainedAt: state.earliest_retained_at,
    diagnosticCode: state.diagnostic_code,
    rawRemaining: db.prepare("SELECT COUNT(*) AS n FROM usage_facts").get().n,
  };
}

export function resetData(db) {
  const logsBefore = db.prepare("SELECT source, present FROM source_log_standin ORDER BY source").all();
  const prefsBefore = db.prepare("SELECT key, value FROM preferences WHERE telemetry = 0 ORDER BY key").all();
  const schemaBefore = db.prepare("SELECT key, value FROM schema_meta ORDER BY key").all();
  db.exec("BEGIN");
  try {
    for (const table of TELEMETRY_TABLES) db.exec(`DELETE FROM ${table}`);
    db.exec("DELETE FROM preferences WHERE telemetry = 1");
    db.exec("COMMIT");
  } catch (error) {
    db.exec("ROLLBACK");
    throw error;
  }
  const logsAfter = db.prepare("SELECT source, present FROM source_log_standin ORDER BY source").all();
  const prefsAfter = db.prepare("SELECT key, value FROM preferences WHERE telemetry = 0 ORDER BY key").all();
  const schemaAfter = db.prepare("SELECT key, value FROM schema_meta ORDER BY key").all();
  const leftover = {};
  for (const table of TELEMETRY_TABLES) {
    leftover[table] = db.prepare(`SELECT COUNT(*) AS n FROM ${table}`).get().n;
  }
  leftover.telemetryPreferences = db.prepare("SELECT COUNT(*) AS n FROM preferences WHERE telemetry = 1").get().n;
  return {
    confirmation: RESET_CONFIRMATION,
    sourceLogsUnchanged: JSON.stringify(logsBefore) === JSON.stringify(logsAfter),
    preferencesKept: JSON.stringify(prefsBefore) === JSON.stringify(prefsAfter),
    schemaMetaKept: JSON.stringify(schemaBefore) === JSON.stringify(schemaAfter),
    telemetryEmpty: Object.values(leftover).every((n) => n === 0),
    leftover,
    externalExportNotGuaranteed: true,
  };
}

function insertFact(db, row) {
  db.prepare(
    `INSERT INTO usage_facts (
      source, agent, model_raw, model_display, session_id, turn_id, model_call_id,
      observed_at, quality, data_state, coverage, scope, definition_version, channel,
      authority_key, contributing, superseded_by, retry, schema_version, parser_version,
      tokens_output_total
    ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`,
  ).run(
    row.source,
    row.agent,
    "synthetic",
    "Orion 2",
    row.session,
    row.turn,
    row.call,
    row.observedAt,
    "measured",
    "present",
    "complete",
    "tokens/call",
    "decode-tps-v1",
    "local",
    `${row.source}|${row.session}|${row.turn}|${row.observedAt}`,
    row.contributing,
    row.supersededBy,
    0,
    1,
    "1.0.0",
    row.output,
  );
}

export function seedPolicyFixture(db, now) {
  db.exec("DELETE FROM usage_facts");
  db.exec("DELETE FROM fact_rollups");
  db.exec("DELETE FROM usage_observations");
  db.exec("DELETE FROM cursors");
  db.exec("DELETE FROM watermarks");
  db.exec("DELETE FROM source_health");
  db.exec("DELETE FROM diagnostics");
  db.exec("DELETE FROM snapshots");
  db.exec("DELETE FROM migration_backups");
  db.exec("DELETE FROM export_copies");
  db.exec("DELETE FROM preferences");
  db.exec("DELETE FROM schema_meta");
  db.exec("DELETE FROM retention_state");
  db.exec("DELETE FROM source_log_standin");

  const mk = (offsetMs, extra = {}) => ({
    source: extra.source || "src-codex",
    agent: extra.agent || "Codex",
    session: extra.session || "sess-01",
    turn: extra.turn || `turn-${offsetMs}`,
    call: extra.call || `call-${offsetMs}`,
    observedAt: now - offsetMs,
    contributing: extra.contributing ?? 1,
    supersededBy: extra.supersededBy ?? null,
    output: extra.output ?? 10,
  });

  for (let i = 0; i < 5; i += 1) insertFact(db, mk((120 + i) * DAY, { contributing: 0, supersededBy: 99, turn: `old-s-${i}` }));
  for (let i = 0; i < 5; i += 1) insertFact(db, mk((100 + i) * DAY, { turn: `old-c-${i}`, output: 20 }));
  for (let i = 0; i < 5; i += 1) insertFact(db, mk((20 + i) * DAY, { turn: `mid-${i}`, output: 30 }));
  for (let i = 0; i < 5; i += 1) insertFact(db, mk(i * DAY + 3_600_000, { turn: `hot-${i}`, output: 40 }));

  db.prepare("INSERT INTO usage_observations(source, observed_at) VALUES (?,?)").run("src-codex", now);
  db.prepare("INSERT INTO cursors(source, file_identity, generation, \"offset\") VALUES (?,?,?,?)").run("src-codex", "file-aa", 1, 10);
  db.prepare("INSERT INTO watermarks(source, counter, identity, value) VALUES (?,?,?,?)").run("src-codex", "session-total", "sess-01", 40);
  db.prepare("INSERT INTO source_health(source, log_present, last_observed_at, data_state, coverage, diagnostic_code) VALUES (?,?,?,?,?,?)").run("src-codex", 1, now, "present", "complete", null);
  db.prepare("INSERT INTO diagnostics(code, observed_at) VALUES (?,?)").run("SRC_OK", now);
  db.prepare("INSERT INTO snapshots(kind, captured_at) VALUES (?,?)").run("light", now);
  db.prepare("INSERT INTO migration_backups(created_at, opaque_name) VALUES (?,?)").run(now, "backup-aa");
  db.prepare("INSERT INTO export_copies(created_at, location) VALUES (?,?)").run(now, "app-managed");
  db.prepare("INSERT INTO export_copies(created_at, location) VALUES (?,?)").run(now, "user-external");
  db.prepare("INSERT INTO preferences(key, value, telemetry) VALUES (?,?,?)").run("launch-at-login", "1", 0);
  db.prepare("INSERT INTO preferences(key, value, telemetry) VALUES (?,?,?)").run("last-export-ordinal", "3", 1);
  db.prepare("INSERT INTO schema_meta(key, value) VALUES (?,?)").run("schema_version", "1");
  db.prepare("INSERT INTO source_log_standin(source, present) VALUES (?,?)").run("src-codex", 1);
  db.prepare("INSERT INTO source_log_standin(source, present) VALUES (?,?)").run("src-claude", 1);
}

export function runPolicyAssertions(assert, { schemaPath, now = Date.UTC(2026, 7, 17, 12, 0, 0) } = {}) {
  const triggerRows = capacityTrigger({ bytes: 100, rows: WARN_ROWS });
  const triggerBytes = capacityTrigger({ bytes: WARN_BYTES, rows: 100 });
  const hardRows = capacityTrigger({ bytes: 100, rows: HARD_ROWS });
  const hardBytes = capacityTrigger({ bytes: HARD_BYTES, rows: 100 });
  assert("warn trips on rows first", triggerRows.warn && triggerRows.warnBy === "rows", triggerRows, "rows");
  assert("warn trips on bytes first", triggerBytes.warn && triggerBytes.warnBy === "bytes", triggerBytes, "bytes");
  assert("hard trips on rows first", hardRows.hard && hardRows.hardBy === "rows", hardRows, "rows");
  assert("hard trips on bytes first", hardBytes.hard && hardBytes.hardBy === "bytes", hardBytes, "bytes");

  const db = new DatabaseSync(":memory:");
  applySchema(db, readFileSync(schemaPath, "utf8"));
  seedPolicyFixture(db, now);

  const warnOnly = enforceCapacity(db, now, {
    warnRows: 10,
    hardRows: 10_000,
    warnBytes: 10 ** 12,
    hardBytes: 10 ** 12,
    measure: () => ({ bytes: 1, rows: measureLogicalRows(db) }),
  });
  assert("warn does not prune", warnOnly.steps.length === 0 && warnOnly.diagnosticCode === "CAPACITY_WARN", warnOnly, "CAPACITY_WARN, no prune");

  const afterSuperseded = enforceCapacity(db, now, {
    warnRows: 1,
    hardRows: 16,
    warnBytes: 10 ** 12,
    hardBytes: 10 ** 12,
    measure: () => ({ bytes: 1, rows: measureLogicalRows(db) }),
  });
  const supersededLeft = db.prepare("SELECT COUNT(*) AS n FROM usage_facts WHERE contributing = 0").get().n;
  assert(
    "hard ceiling deletes superseded first",
    afterSuperseded.steps[0]?.action === "delete-superseded" && supersededLeft === 0,
    afterSuperseded.steps,
    "delete-superseded first",
  );

  seedPolicyFixture(db, now);
  const afterCompact = enforceCapacity(db, now, {
    warnRows: 1,
    hardRows: 12,
    warnBytes: 10 ** 12,
    hardBytes: 10 ** 12,
    measure: () => ({ bytes: 1, rows: measureLogicalRows(db) }),
  });
  const olderThan90 = db.prepare("SELECT COUNT(*) AS n FROM usage_facts WHERE observed_at < ?").get(now - COMPACT_AFTER_MS).n;
  assert(
    "hard ceiling then atomically compacts raw older than 90d",
    afterCompact.steps.some((step) => step.action === "compact-gt-90d") && olderThan90 === 0,
    afterCompact.steps.map((step) => step.action),
    "compact-gt-90d and no raw >90d",
  );

  seedPolicyFixture(db, now);
  const afterRollupPrune = enforceCapacity(db, now, {
    warnRows: 1,
    hardRows: 10,
    warnBytes: 10 ** 12,
    hardBytes: 10 ** 12,
    measure: () => ({ bytes: 1, rows: measureLogicalRows(db) }),
  });
  const stateAfterRollup = db.prepare("SELECT * FROM retention_state WHERE id = 1").get();
  assert(
    "oldest rollup prune marks partial coverage and pruned_before",
    afterRollupPrune.steps.some((step) => step.action === "delete-oldest-rollup")
      && stateAfterRollup.coverage === "partial"
      && stateAfterRollup.pruned_before != null
      && stateAfterRollup.earliest_retained_at != null,
    stateAfterRollup,
    "coverage=partial plus pruned_before and earliest_retained_at",
  );

  seedPolicyFixture(db, now);
  const afterMidRaw = enforceCapacity(db, now, {
    warnRows: 1,
    hardRows: 6,
    warnBytes: 10 ** 12,
    hardBytes: 10 ** 12,
    measure: () => ({ bytes: 1, rows: measureLogicalRows(db) }),
  });
  const midRaw = db.prepare(
    "SELECT COUNT(*) AS n FROM usage_facts WHERE observed_at < ? AND observed_at >= ?",
  ).get(now - PROTECTED_RAW_MS, now - COMPACT_AFTER_MS).n;
  const protectedRaw = db.prepare("SELECT COUNT(*) AS n FROM usage_facts WHERE observed_at >= ?").get(now - PROTECTED_RAW_MS).n;
  assert(
    "next prune deletes 7-90d raw but keeps the 7d protected window",
    afterMidRaw.steps.some((step) => step.action === "delete-oldest-7-90d-raw") && midRaw === 0 && protectedRaw === 5,
    { midRaw, protectedRaw, steps: afterMidRaw.steps.map((step) => step.action) },
    "no 7-90d raw, 5 protected 7d raw",
  );

  seedPolicyFixture(db, now);
  const pause = enforceCapacity(db, now, {
    warnRows: 1,
    hardRows: 2,
    warnBytes: 10 ** 12,
    hardBytes: 10 ** 12,
    measure: () => ({ bytes: 1, rows: measureLogicalRows(db) }),
  });
  const protectedAfterPause = db.prepare("SELECT COUNT(*) AS n FROM usage_facts WHERE observed_at >= ?").get(now - PROTECTED_RAW_MS).n;
  assert(
    "protected 7d window pauses ingest instead of silent delete",
    pause.ingestPaused
      && pause.diagnosticCode === "CAPACITY_PROTECTED_WINDOW"
      && protectedAfterPause === 5
      && pause.steps.at(-1)?.action === "pause-ingest",
    { ingestPaused: pause.ingestPaused, diagnosticCode: pause.diagnosticCode, protectedAfterPause },
    "CAPACITY_PROTECTED_WINDOW and 7d raw remains",
  );

  seedPolicyFixture(db, now);
  const reset = resetData(db);
  assert("Reset Data wipes App-owned telemetry stores", reset.telemetryEmpty, reset.leftover, "all telemetry tables empty");
  assert("Reset Data keeps schema metadata", reset.schemaMetaKept, true, true);
  assert("Reset Data keeps non-telemetry preferences", reset.preferencesKept, true, true);
  assert("Reset Data does not modify source logs", reset.sourceLogsUnchanged, true, true);
  assert(
    "Reset Data confirmation names unsaved-external export limit",
    reset.confirmation.includes("saved outside the app") && reset.externalExportNotGuaranteed,
    reset.confirmation,
    RESET_CONFIRMATION,
  );
  db.close();
}
