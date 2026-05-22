INSERT OR REPLACE INTO wifi_next_steps (
  tool_key,
  display_name,
  package_names,
  category,
  risk_level,
  auto_test,
  requires,
  why,
  sort_order
) VALUES
  (
    'wavemon',
    'wavemon',
    'wavemon',
    'Live Wi-Fi monitor',
    'Safe',
    'Install check plus non-interactive dump when supported.',
    'Local Wi-Fi interface only.',
    'Shows signal, noise, bitrate, and retry behavior while you test desk placement.',
    10
  ),
  (
    'iw',
    'iw',
    'iw',
    'Kernel Wi-Fi telemetry',
    'Safe',
    'Capture link, station, and survey data.',
    'Local Wi-Fi interface only.',
    'Gives scriptable signal, bitrate, channel, and radio counters that are easier to compare than a live UI.',
    20
  ),
  (
    'iperf3',
    'iperf3',
    'iperf3',
    'Controlled throughput',
    'Moderate',
    'Run client test when IPERF3_SERVER is set.',
    'A LAN or controlled iperf3 server.',
    'Separates local Wi-Fi performance from internet/provider limits when the server is on a known-good path.',
    30
  ),
  (
    'flent_netperf',
    'flent + netperf',
    'flent netperf',
    'Bufferbloat under load',
    'Moderate',
    'Run flent when FLENT_SERVER is set and netperf is available.',
    'A LAN or controlled netperf server.',
    'Shows latency under load, which is the practical pain point for coding assistants and video calls.',
    40
  ),
  (
    'iwd',
    'iwd',
    'iwd',
    'NetworkManager Wi-Fi backend',
    'Moderate',
    'Check availability and active backend; no automatic backend switch.',
    'Planned rollback window before changing NetworkManager backend.',
    'Worth testing only if scanning, roaming, or reconnect behavior remains unstable.',
    50
  );
