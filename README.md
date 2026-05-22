# Speedtest Network Reports

SQLite-backed network diagnostics for comparing a machine's network state before and after tuning. It stores raw logs and parsed metrics locally, then renders a browser report from a generated SQLite snapshot.

## Install

Required on the machine being measured:

```bash
sudo apt update
sudo apt install -y sqlite3 speedtest-cli bind9-dnsutils iputils-ping iputils-tracepath mtr-tiny network-manager python3
```

Optional Wi-Fi diagnostics:

```bash
sudo apt install -y wavemon iperf3 flent netperf iw iwd
```

The collection scripts call `speedtest-cli --secure --simple`, so install the package that provides the `speedtest-cli` command. The browser report uses a pinned `sql.js` WebAssembly build at runtime unless you override `window.SPEEDTEST_REPORT_CONFIG.sqlJsBaseUrl` in `index.html`.

## Report Pattern

- `logs/speedtest.sqlite` is the working SQLite database and is ignored by git.
- `logs/<run_id>/` stores raw command output for a run and is ignored by git.
- `scripts/publish-report-db.sh` checkpoints and compacts the working DB into `data/report.sqlite`.
- `data/report.sqlite` is ignored by git because it contains local machine and network data.
- `index.html`, `assets/report.css`, and `assets/report.js` are stable committed assets.
- `assets/report.js` loads `data/report.sqlite` in the browser with SQLite WebAssembly and runs read-only report queries.

Serve the report locally because browsers usually block `fetch()` from `file://` pages:

```bash
scripts/publish-report-db.sh
scripts/serve-report.sh
```

Open `http://127.0.0.1:8765/`. To force a specific run, open `http://127.0.0.1:8765/?run=<run_id>`.

You can also open `index.html` directly from the filesystem and use the
`Load file` button to choose `data/report.sqlite`. Browsers do not allow a page
to auto-select a local file by path, so direct-open mode needs that click.

## Database Layout

- `db/schema/001_core.sql`: migrations, preferences, and run identity.
- `db/schema/002_raw_logs.sql`: raw evidence and classification tables.
- `db/schema/003_metrics.sql`: speed, latency, DNS, service, recommendation, and artifact tables.
- `db/schema/004_views.sql`: report-facing SQLite views.
- `db/schema/005_wifi_tooling.sql`: Wi-Fi tool results and stability samples.
- `db/defaults/*.sql`: report sections, preferences, and Wi-Fi next-step metadata.
- `db/seed.sql`: compatibility entry point for manual `sqlite3` seeding.

SQLite helpers in `scripts/lib/sqlite.sh` enable foreign keys per connection, use a busy timeout, initialize the database in WAL mode for local writes, and optimize planner stats after schema work.

## Agent Skills

Project-local agent skills live under `.agents/skills/`:

- `sqlite3-quality`: SQLite schema, query, sqlite3 CLI, and browser snapshot rules.
- `bash-diagnostics`: Bash collection, rollback, NetworkManager, and SQLite-writing script rules.

Use those before changing database or script behavior; they encode the privacy and report-generation patterns specific to this repo.

## Common Commands

Initialize or migrate the local DB:

```bash
scripts/init-db.sh
```

Collect a network test phase:

```bash
RUN_ID="$(date +%Y%m%d-%H%M%S)"
scripts/collect-network-tests.sh before "logs/$RUN_ID"
scripts/collect-network-tests.sh after-final "logs/$RUN_ID"
```

Parse collected metrics into SQLite:

```bash
scripts/summarize-network-run.sh before "logs/$RUN_ID"
scripts/summarize-network-run.sh after-final "logs/$RUN_ID"
```

Ingest raw logs into SQLite:

```bash
scripts/ingest-run-logs.sh "logs/$RUN_ID"
```

Collect Wi-Fi diagnostics:

```bash
scripts/collect-wifi-tool-tests.sh wifi-before "logs/$RUN_ID"
scripts/collect-wifi-tool-tests.sh wifi-current "logs/$RUN_ID"
```

Run Wi-Fi stability and BSSID A/B sampling:

```bash
PREFERRED_BSSID=<ap-bssid> scripts/run-wifi-stability-bssid-ab.sh "logs/$RUN_ID"
```

Run controlled LAN throughput or bufferbloat tests when you have a server:

```bash
IPERF3_SERVER=<host> scripts/collect-wifi-tool-tests.sh wifi-current "logs/$RUN_ID"
FLENT_SERVER=<host> scripts/collect-wifi-tool-tests.sh wifi-current "logs/$RUN_ID"
```

Apply or roll back local NetworkManager optimizations:

```bash
scripts/apply-approved-optimizations.sh
scripts/rollback-optimizations.sh
```

Both scripts require a typed confirmation before changing settings.

## iwd Backend Test

The iwd test temporarily switches NetworkManager's Wi-Fi backend, runs the same stability/BSSID sample, and rolls back automatically. It requires root and a preferred BSSID.

```bash
sudo apt install -y iwd
sudo CONFIRM_IWD_TEST=YES PREFERRED_BSSID=<ap-bssid> scripts/test-iwd-backend.sh "logs/$RUN_ID"
```

The script writes `logs/<run_id>/iwd-rollback.sh` before changing NetworkManager.

## Privacy

Do not commit generated databases, run logs, or report snapshots. They can include SSIDs, BSSIDs, local IP addresses, DNS domains, hostnames, and raw command output. The `.gitignore` keeps `logs/*`, `logs/*.sqlite*`, `data/*`, and `reports/*.html` out of git while preserving placeholder directories.
