-- THROW AWAY / prototype schema. Not the production FactStore.
-- Persistent Usage Facts only. No prompt, code, tool I/O, path, account, or content columns.
-- 20k is the hot/query working set, not this table's retention.

PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;
PRAGMA foreign_keys = ON;
PRAGMA auto_vacuum = INCREMENTAL;
PRAGMA temp_store = MEMORY;

CREATE TABLE IF NOT EXISTS usage_facts (
  fact_id INTEGER PRIMARY KEY,
  source TEXT NOT NULL,
  agent TEXT NOT NULL,
  model_raw TEXT NOT NULL,
  model_display TEXT NOT NULL,
  session_id TEXT NOT NULL,
  turn_id TEXT NOT NULL,
  model_call_id TEXT,
  observed_at INTEGER NOT NULL,
  started_at INTEGER,
  ended_at INTEGER,
  ttft_ms INTEGER,
  duration_ms INTEGER,
  tokens_input_uncached INTEGER,
  tokens_cache_read INTEGER,
  tokens_cache_write INTEGER,
  tokens_output_visible INTEGER,
  tokens_reasoning INTEGER,
  tokens_output_total INTEGER,
  quality TEXT NOT NULL CHECK (quality IN ('measured', 'derived', 'estimated', 'unavailable')),
  data_state TEXT NOT NULL CHECK (data_state IN ('present', 'zero', 'stale', 'absent', 'unavailable')),
  coverage TEXT NOT NULL CHECK (coverage IN ('complete', 'partial')),
  scope TEXT NOT NULL,
  definition_version TEXT NOT NULL,
  channel TEXT NOT NULL CHECK (channel IN ('local', 'enhanced')),
  authority_key TEXT NOT NULL,
  contributing INTEGER NOT NULL CHECK (contributing IN (0, 1)),
  superseded_by INTEGER,
  retry INTEGER NOT NULL CHECK (retry IN (0, 1)),
  schema_version INTEGER NOT NULL,
  parser_version TEXT NOT NULL,
  generation INTEGER,
  "offset" INTEGER,
  file_identity TEXT, -- opaque synthetic id only, never a filesystem path
  diagnostic_code TEXT
);

CREATE TABLE IF NOT EXISTS cursors (
  source TEXT NOT NULL,
  file_identity TEXT NOT NULL,
  generation INTEGER NOT NULL,
  "offset" INTEGER NOT NULL,
  PRIMARY KEY (source, file_identity)
);

CREATE TABLE IF NOT EXISTS source_health (
  source TEXT PRIMARY KEY,
  log_present INTEGER NOT NULL CHECK (log_present IN (0, 1)),
  last_observed_at INTEGER,
  data_state TEXT NOT NULL CHECK (data_state IN ('present', 'zero', 'stale', 'absent', 'unavailable')),
  coverage TEXT NOT NULL CHECK (coverage IN ('complete', 'partial')),
  diagnostic_code TEXT
);

CREATE TABLE IF NOT EXISTS fact_rollups (
  rollup_id INTEGER PRIMARY KEY,
  source TEXT NOT NULL,
  agent TEXT NOT NULL,
  model_display TEXT NOT NULL,
  window_start INTEGER NOT NULL,
  window_end INTEGER NOT NULL,
  granularity TEXT NOT NULL,
  tokens_input_uncached INTEGER,
  tokens_cache_read INTEGER,
  tokens_cache_write INTEGER,
  tokens_output_visible INTEGER,
  tokens_reasoning INTEGER,
  tokens_output_total INTEGER,
  call_count INTEGER,
  fact_count INTEGER,
  coverage TEXT NOT NULL CHECK (coverage IN ('complete', 'partial')),
  quality TEXT NOT NULL,
  contributing INTEGER NOT NULL CHECK (contributing IN (0, 1))
);

CREATE INDEX IF NOT EXISTS idx_facts_observed
  ON usage_facts (observed_at);
CREATE INDEX IF NOT EXISTS idx_facts_source_observed
  ON usage_facts (source, observed_at);
CREATE INDEX IF NOT EXISTS idx_facts_agent_model_observed
  ON usage_facts (agent, model_display, observed_at);
CREATE INDEX IF NOT EXISTS idx_facts_contributing_observed
  ON usage_facts (contributing, observed_at);
CREATE INDEX IF NOT EXISTS idx_facts_call
  ON usage_facts (model_call_id);
CREATE INDEX IF NOT EXISTS idx_facts_authority
  ON usage_facts (authority_key);
CREATE INDEX IF NOT EXISTS idx_rollups_window
  ON fact_rollups (window_start, window_end, agent, model_display);
CREATE UNIQUE INDEX IF NOT EXISTS idx_rollups_bucket
  ON fact_rollups (source, agent, model_display, window_start, granularity);

CREATE TABLE IF NOT EXISTS usage_observations (
  observation_id INTEGER PRIMARY KEY,
  source TEXT NOT NULL,
  observed_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS watermarks (
  source TEXT NOT NULL,
  counter TEXT NOT NULL,
  identity TEXT NOT NULL,
  value INTEGER NOT NULL,
  PRIMARY KEY (source, counter, identity)
);

CREATE TABLE IF NOT EXISTS diagnostics (
  diagnostic_id INTEGER PRIMARY KEY,
  code TEXT NOT NULL,
  observed_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS snapshots (
  snapshot_id INTEGER PRIMARY KEY,
  kind TEXT NOT NULL,
  captured_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS migration_backups (
  backup_id INTEGER PRIMARY KEY,
  created_at INTEGER NOT NULL,
  opaque_name TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS export_copies (
  export_id INTEGER PRIMARY KEY,
  created_at INTEGER NOT NULL,
  location TEXT NOT NULL CHECK (location IN ('app-managed', 'user-external'))
);

CREATE TABLE IF NOT EXISTS preferences (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  telemetry INTEGER NOT NULL CHECK (telemetry IN (0, 1))
);

CREATE TABLE IF NOT EXISTS schema_meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS retention_state (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  warn_hit INTEGER NOT NULL DEFAULT 0,
  hard_hit INTEGER NOT NULL DEFAULT 0,
  trigger TEXT,
  ingest_paused INTEGER NOT NULL DEFAULT 0,
  coverage TEXT NOT NULL DEFAULT 'complete',
  pruned_before INTEGER,
  earliest_retained_at INTEGER,
  diagnostic_code TEXT
);

CREATE TABLE IF NOT EXISTS source_log_standin (
  source TEXT PRIMARY KEY,
  present INTEGER NOT NULL CHECK (present IN (0, 1))
);
