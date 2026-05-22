---
name: sqlite3-quality
description: Use when changing SQLite schema, SQLite queries, sqlite3 CLI usage, report database publishing, or browser SQLite rendering in this speedtest repository.
---

# SQLite Quality Workflow

## Scope

Use this skill for changes touching:

- `db/schema/*.sql`
- `db/defaults/*.sql`
- `db/seed.sql`
- `scripts/lib/sqlite.sh`
- scripts that call `sqlite_exec`, `sqlite_scalar`, `sqlite3`, `VACUUM INTO`, or `readfile()`
- report queries in `assets/report.js`
- `scripts/publish-report-db.sh`

## First Checks

1. Read the relevant schema module before editing queries.
2. Identify the database surface:
   - working DB: `logs/speedtest.sqlite`
   - browser snapshot: `data/report.sqlite`
   - raw private logs: `logs/<run_id>/`
3. Preserve the privacy boundary: generated DBs and logs stay ignored.
4. Check local SQLite capabilities when using version-sensitive features:

```bash
sqlite3 --version
```

## Schema Rules

- Keep schema split by responsibility under `db/schema/NNN_name.sql`.
- Keep seed/default rows under `db/defaults/*.sql`.
- Use explicit `PRIMARY KEY`, `UNIQUE`, `CHECK`, and `REFERENCES ... ON DELETE CASCADE` where they describe real invariants.
- Prefer `TEXT NOT NULL DEFAULT ''` only when empty string is a meaningful value. Use nullable columns for unknown measurements.
- Add indexes when queries repeatedly filter by `run_id`, `phase`, `target`, `tool_key`, or foreign-key columns over growing tables.
- Consider `STRICT` only for new tables when the target SQLite version supports it and portability is acceptable. Do not convert existing tables to `STRICT` casually.
- Do not store parsed metrics only in raw text if the report needs to compare, filter, or aggregate them later.

## Query Rules

- Use explicit column lists in report-facing queries. Avoid `SELECT *`.
- Always make report ordering deterministic with `ORDER BY`.
- Prefer table-valued PRAGMA functions for introspection queries that need filtering or joins.
- For non-trivial report queries, inspect the plan:

```bash
sqlite3 logs/speedtest.sqlite "EXPLAIN QUERY PLAN <query>;"
```

- Prefer one query per report section over ad hoc string parsing in JS or shell.
- In browser code, open the DB read-only with `PRAGMA query_only = ON`.

## CLI And Write Rules

- Use `scripts/lib/sqlite.sh` helpers for writes and reads from shell.
- Helpers must enable foreign keys per connection and use a 5000 ms timeout.
- Quote shell-interpolated SQL values with `sql_quote`; never paste raw user, SSID, path, or log values into SQL.
- Use `readfile()` for raw log content instead of manually escaping blobs.
- Wrap bulk inserts in a transaction when adding or rewriting high-volume ingestion.
- Prefer `.timeout 5000` in sqlite3 CLI commands instead of `PRAGMA busy_timeout = 5000` when output cleanliness matters.

## Working DB Vs Browser Snapshot

- Keep the working DB in WAL mode for local writes.
- Before publishing to the browser:
  1. checkpoint WAL,
  2. run `PRAGMA optimize`,
  3. create a compact copy with `VACUUM INTO`,
  4. switch the snapshot to rollback journal mode,
  5. keep the snapshot ignored and local.
- Do not point the browser at an active WAL database trio.

## Verification

Run the narrowest useful set:

```bash
bash -n scripts/*.sh scripts/lib/*.sh
scripts/init-db.sh logs/speedtest.sqlite
scripts/publish-report-db.sh logs/speedtest.sqlite data/report.sqlite
sqlite3 data/report.sqlite "PRAGMA quick_check; PRAGMA foreign_key_check; PRAGMA journal_mode;"
node --check assets/report.js
git status --short --ignored
```

Before publishing or committing, grep committed sources for machine-specific data:

```bash
grep -RInE "KNOWN_PRIVATE_SSID|KNOWN_PRIVATE_BSSID|KNOWN_PRIVATE_DOMAIN|10\\.|192\\.168\\.|172\\." . \
  --exclude-dir=.git --exclude-dir=logs --exclude-dir=reports --exclude='report.sqlite'
```

## References

- SQLite PRAGMAs: https://www.sqlite.org/pragma.html
- SQLite WAL: https://www.sqlite.org/wal.html
- SQLite CLI: https://www.sqlite.org/cli.html
- SQLite query planner: https://www.sqlite.org/queryplanner.html
- SQLite STRICT tables: https://www.sqlite.org/stricttables.html
