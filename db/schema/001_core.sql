PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;

CREATE TABLE IF NOT EXISTS schema_migrations (
  version INTEGER PRIMARY KEY,
  name TEXT NOT NULL,
  applied_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

INSERT OR IGNORE INTO schema_migrations (version, name)
VALUES
  (1, 'initial_speedtest_schema'),
  (2, 'raw_log_taxonomy'),
  (3, 'modular_schema_layout'),
  (4, 'wifi_next_steps'),
  (5, 'wifi_stability_samples');

CREATE TABLE IF NOT EXISTS preferences (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS runs (
  run_id TEXT PRIMARY KEY,
  started_at TEXT NOT NULL,
  run_dir TEXT NOT NULL,
  report_path TEXT,
  connection_name TEXT,
  interface_name TEXT,
  gateway TEXT,
  mtu INTEGER,
  approval_status TEXT NOT NULL DEFAULT 'not applied',
  notes TEXT NOT NULL DEFAULT ''
);
