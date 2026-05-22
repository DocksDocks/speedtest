INSERT OR REPLACE INTO preferences (key, value, updated_at) VALUES
  ('preferred_primary_dns', '9.9.9.9', CURRENT_TIMESTAMP),
  ('preferred_secondary_dns', '1.1.1.1', CURRENT_TIMESTAMP),
  ('preserve_dns_search_domain', '', CURRENT_TIMESTAMP),
  ('preferred_wifi_interface', '', CURRENT_TIMESTAMP),
  ('preferred_bssid', '', CURRENT_TIMESTAMP),
  ('preferred_log_root', 'logs', CURRENT_TIMESTAMP),
  ('default_report_css', 'assets/report.css', CURRENT_TIMESTAMP),
  ('service_hosts', 'chatgpt.com claude.ai api.openai.com api.anthropic.com', CURRENT_TIMESTAMP);
