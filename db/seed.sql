-- Compatibility entry point for sqlite3 when invoked from the project root:
--
--   sqlite3 logs/speedtest.sqlite < db/seed.sql
--
-- The production initializer, scripts/init-db.sh, applies these modules with
-- absolute paths so it is safe to run from any working directory.

.read db/schema/001_core.sql
.read db/schema/002_raw_logs.sql
.read db/schema/003_metrics.sql
.read db/schema/004_views.sql
.read db/schema/005_wifi_tooling.sql
.read db/defaults/001_report_sections.sql
.read db/defaults/002_preferences.sql
.read db/defaults/003_wifi_next_steps.sql
