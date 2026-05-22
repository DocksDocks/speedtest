CREATE VIEW IF NOT EXISTS speed_comparison AS
SELECT
  b.run_id,
  b.ping_ms AS before_ping_ms,
  f.ping_ms AS final_ping_ms,
  b.download_mbps AS before_download_mbps,
  f.download_mbps AS final_download_mbps,
  b.upload_mbps AS before_upload_mbps,
  f.upload_mbps AS final_upload_mbps
FROM speed_tests b
JOIN speed_tests f
  ON f.run_id = b.run_id
WHERE b.phase = 'before'
  AND f.phase IN ('after-final', 'after');

CREATE VIEW IF NOT EXISTS raw_log_catalog AS
SELECT
  r.run_id,
  r.relative_path,
  r.kind,
  COALESCE(c.phase, r.phase) AS phase,
  c.section_key,
  s.title AS section_title,
  c.signal_type,
  c.source_tool,
  c.target,
  c.display_label,
  c.display_order,
  c.is_primary,
  r.size_bytes,
  r.sha256,
  r.captured_at
FROM raw_logs r
LEFT JOIN raw_log_classifications c
  ON c.raw_log_id = r.id
LEFT JOIN report_sections s
  ON s.section_key = c.section_key;
