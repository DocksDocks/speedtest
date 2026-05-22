CREATE TABLE IF NOT EXISTS raw_logs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  run_id TEXT NOT NULL REFERENCES runs(run_id) ON DELETE CASCADE,
  relative_path TEXT NOT NULL,
  kind TEXT NOT NULL,
  phase TEXT,
  content BLOB NOT NULL,
  size_bytes INTEGER NOT NULL,
  sha256 TEXT,
  captured_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE (run_id, relative_path)
);

CREATE TABLE IF NOT EXISTS report_sections (
  section_key TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  description TEXT NOT NULL,
  display_order INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS raw_log_classifications (
  raw_log_id INTEGER PRIMARY KEY REFERENCES raw_logs(id) ON DELETE CASCADE,
  section_key TEXT NOT NULL REFERENCES report_sections(section_key),
  signal_type TEXT NOT NULL,
  source_tool TEXT NOT NULL,
  target TEXT,
  phase TEXT,
  display_label TEXT NOT NULL,
  display_order INTEGER NOT NULL,
  is_primary INTEGER NOT NULL DEFAULT 0 CHECK (is_primary IN (0, 1)),
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
