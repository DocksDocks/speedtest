CREATE TABLE IF NOT EXISTS wifi_next_steps (
  tool_key TEXT PRIMARY KEY,
  display_name TEXT NOT NULL,
  package_names TEXT NOT NULL,
  category TEXT NOT NULL,
  risk_level TEXT NOT NULL,
  auto_test TEXT NOT NULL,
  requires TEXT NOT NULL,
  why TEXT NOT NULL,
  sort_order INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS wifi_tool_tests (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  run_id TEXT NOT NULL REFERENCES runs(run_id) ON DELETE CASCADE,
  phase TEXT NOT NULL,
  tool_key TEXT NOT NULL,
  category TEXT NOT NULL,
  status TEXT NOT NULL,
  result TEXT NOT NULL,
  source_file TEXT NOT NULL,
  captured_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE (run_id, phase, tool_key, category, source_file)
);

CREATE TABLE IF NOT EXISTS wifi_stability_samples (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  run_id TEXT NOT NULL REFERENCES runs(run_id) ON DELETE CASCADE,
  phase TEXT NOT NULL,
  sample_group TEXT NOT NULL,
  sample_index INTEGER NOT NULL,
  sampled_at TEXT NOT NULL,
  mode TEXT NOT NULL,
  configured_bssid TEXT,
  connected_bssid TEXT,
  ssid TEXT,
  freq_mhz REAL,
  channel INTEGER,
  nm_signal INTEGER,
  proc_quality REAL,
  proc_level_dbm REAL,
  iw_signal_dbm REAL,
  iw_signal_avg_dbm REAL,
  rx_bitrate_mbps REAL,
  tx_bitrate_mbps REAL,
  tx_retries INTEGER,
  tx_failed INTEGER,
  beacon_loss INTEGER,
  rx_drop_misc INTEGER,
  source_file TEXT NOT NULL,
  UNIQUE (run_id, phase, sample_group, sample_index)
);

CREATE TABLE IF NOT EXISTS wifi_backend_tests (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  run_id TEXT NOT NULL REFERENCES runs(run_id) ON DELETE CASCADE,
  phase TEXT NOT NULL,
  backend TEXT NOT NULL,
  connection_name TEXT,
  interface_name TEXT,
  original_bssid TEXT,
  preferred_bssid TEXT,
  backend_config_path TEXT,
  backup_dir TEXT,
  rollback_script TEXT,
  status TEXT NOT NULL,
  started_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  finished_at TEXT,
  notes TEXT NOT NULL DEFAULT '',
  UNIQUE (run_id, phase, backend)
);
