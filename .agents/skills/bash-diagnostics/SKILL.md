---
name: bash-diagnostics
description: Use when adding or changing Bash scripts that collect network diagnostics, mutate NetworkManager settings, ingest logs, publish reports, or call sqlite3 in this speedtest repository.
metadata:
  updated: 2026-06-11
---

# Bash Diagnostics Workflow

## Scope

Use this skill for:

- `scripts/*.sh`
- `scripts/lib/*.sh`
- collection scripts that call `nmcli`, `iw`, `iperf3`, `flent`, `netperf`, `speedtest-cli`, `ping`, `dig`, `mtr`, or `tracepath`
- scripts that write logs under `logs/<run_id>/`
- scripts that change DNS, BSSID, Wi-Fi power saving, Avahi, NetworkManager, or iwd

## Structure Rules

- Source shared helpers instead of duplicating path or SQLite logic:

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/path.sh"
```

- Use `scripts/lib/sqlite.sh` when the script writes or reads SQLite.
- Detect defaults through `speedtest_default_run_dir`, `speedtest_default_wifi_iface`, and `speedtest_default_connection_name`.
- Site-specific values must be env vars, not committed defaults:
  - `IFACE`
  - `CONNECTION_NAME`
  - `PREFERRED_BSSID`
  - `DNS_SEARCH`
  - `IPERF3_SERVER`
  - `FLENT_SERVER`

## Safety Rules

- Scripts that mutate network state must require typed confirmation or an explicit env gate.
- Root-only scripts must fail early with a clear message.
- For rollback-sensitive changes, write rollback instructions or a rollback script before changing state.
- Use arrays for commands with optional arguments; do not use `eval`.
- Quote variables unless deliberately using word splitting for documented lists.
- Use `trap` for cleanup and rollback when a script creates temporary files or changes network state.
- Daemons that own a Wi-Fi interface (iwd) can delete it on stop. Rollback or recovery flows must stop the daemon before restarting NetworkManager, then recover a missing interface by reloading the Wi-Fi driver module (`scripts/recover-wifi-interface.sh` is the standalone tool).
- Backend switches must account for package-shipped NetworkManager configs: the Ubuntu iwd package installs `/usr/lib/NetworkManager/conf.d/iwd.conf` (`wifi.backend=iwd`). Pin the intended backend in `/etc/NetworkManager/conf.d/` with a low-sort prefix (`10-wifi-backend.conf`) so test-specific `90-` files can still override it.

## Collection Rules

- Collection scripts should keep going when one measurement fails, log exit status, and store the raw output.
- Use a helper like `run_logged` for command output plus start/end status.
- Do not hide failures in parsed SQLite tables; record `failed`, `skipped`, or `blocked` statuses explicitly.
- Keep raw logs under the run directory and rely on `.gitignore` for privacy.
- Do not print secrets, passwords, tokens, or private config values into committed files.

## SQLite Rules

- Use `sqlite_exec`, `sqlite_scalar`, and `sqlite_table_html` from `scripts/lib/sqlite.sh`.
- Quote SQL values with `sql_quote`.
- Prefer idempotent inserts with `ON CONFLICT DO UPDATE` for rerunnable collectors.
- Store raw files in `raw_logs` and classification in `raw_log_classifications`; store parsed metrics in dedicated metric tables.

## Verification

For syntax-only changes:

```bash
bash -n scripts/*.sh scripts/lib/*.sh
```

For SQLite-writing script changes:

```bash
scripts/init-db.sh logs/speedtest.sqlite
sqlite3 logs/speedtest.sqlite "PRAGMA quick_check; PRAGMA foreign_key_check;"
```

For report-affecting changes:

```bash
scripts/publish-report-db.sh logs/speedtest.sqlite data/report.sqlite
node --check assets/report.js
```

Before committing:

```bash
git status --short --ignored
git diff --check
grep -RInE "KNOWN_PRIVATE_SSID|KNOWN_PRIVATE_BSSID|KNOWN_PRIVATE_DOMAIN|/home/|10\\." . \
  --exclude-dir=.git --exclude-dir=logs --exclude-dir=reports --exclude='report.sqlite'
```
