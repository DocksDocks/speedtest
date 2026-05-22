CREATE TABLE IF NOT EXISTS speed_tests (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  run_id TEXT NOT NULL REFERENCES runs(run_id) ON DELETE CASCADE,
  phase TEXT NOT NULL,
  ping_ms REAL,
  download_mbps REAL,
  upload_mbps REAL,
  source_file TEXT NOT NULL,
  UNIQUE (run_id, phase, source_file)
);

CREATE TABLE IF NOT EXISTS latency_tests (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  run_id TEXT NOT NULL REFERENCES runs(run_id) ON DELETE CASCADE,
  phase TEXT NOT NULL,
  target TEXT NOT NULL,
  packet_loss_percent REAL,
  avg_ms REAL,
  max_ms REAL,
  source_file TEXT NOT NULL,
  UNIQUE (run_id, phase, target, source_file)
);

CREATE TABLE IF NOT EXISTS dns_benchmarks (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  run_id TEXT NOT NULL REFERENCES runs(run_id) ON DELETE CASCADE,
  phase TEXT NOT NULL,
  resolver TEXT NOT NULL,
  avg_query_ms REAL NOT NULL,
  source_file TEXT NOT NULL,
  UNIQUE (run_id, phase, resolver, source_file)
);

CREATE TABLE IF NOT EXISTS service_tests (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  run_id TEXT NOT NULL REFERENCES runs(run_id) ON DELETE CASCADE,
  phase TEXT NOT NULL,
  service TEXT NOT NULL,
  ping_loss_percent REAL,
  ping_avg_ms REAL,
  ping_max_ms REAL,
  https_http_code INTEGER,
  https_remote_ip TEXT,
  https_dns_s REAL,
  https_connect_s REAL,
  https_tls_s REAL,
  https_ttfb_s REAL,
  https_total_s REAL,
  source_ping_file TEXT NOT NULL,
  source_https_file TEXT NOT NULL,
  UNIQUE (run_id, phase, service)
);

CREATE TABLE IF NOT EXISTS recommendations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  run_id TEXT NOT NULL REFERENCES runs(run_id) ON DELETE CASCADE,
  category TEXT NOT NULL,
  recommendation TEXT NOT NULL,
  status TEXT NOT NULL,
  UNIQUE (run_id, category)
);

CREATE TABLE IF NOT EXISTS artifacts (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  run_id TEXT NOT NULL REFERENCES runs(run_id) ON DELETE CASCADE,
  kind TEXT NOT NULL,
  path TEXT NOT NULL,
  description TEXT NOT NULL,
  UNIQUE (run_id, path)
);
