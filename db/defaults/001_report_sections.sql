INSERT OR REPLACE INTO report_sections (section_key, title, description, display_order) VALUES
  ('overview', 'Overview And Summaries', 'Human-readable findings, generated reports, SQL updates, and run summaries.', 10),
  ('speed', 'Speed Tests', 'Throughput and speedtest-cli results.', 20),
  ('latency', 'Latency And Packet Loss', 'Ping, mtr, and route samples used to evaluate loss and jitter.', 30),
  ('dns', 'DNS And Resolver', 'DNS resolver configuration and lookup benchmarks.', 40),
  ('wifi', 'Wi-Fi Signal And Access Points', 'Wi-Fi scans, BSSID pinning, signal quality, and radio state.', 50),
  ('mtu', 'MTU And Path', 'MTU, DF ping, and tracepath evidence.', 60),
  ('mdns', 'mDNS And Local Discovery', 'Avahi and mDNS state.', 70),
  ('service', 'ChatGPT Claude Codex Service Tests', 'Service-specific DNS, ping, and HTTPS timing checks.', 80),
  ('system', 'System And Network State', 'Interface, route, tool availability, NetworkManager, and OS state.', 90),
  ('actions', 'Applied Actions And Rollback', 'Optimization, rollback, and command execution logs.', 100),
  ('uncategorized', 'Uncategorized Evidence', 'Logs that do not yet match a specific taxonomy rule.', 999);
