(function () {
  "use strict";

  const defaults = {
    dbUrl: "data/report.sqlite",
    sqlJsVersion: "1.13.0",
    sqlJsBaseUrl: "",
    sqlJsScriptUrl: "",
    runId: "",
    fileInputId: "sqlite-file",
    loadStatusId: "file-load-status",
  };

  const config = Object.assign({}, defaults, window.SPEEDTEST_REPORT_CONFIG || {});
  if (!config.sqlJsBaseUrl) {
    config.sqlJsBaseUrl = `https://cdn.jsdelivr.net/npm/sql.js@${config.sqlJsVersion}/dist/`;
  }
  if (!config.sqlJsScriptUrl) {
    config.sqlJsScriptUrl = `${config.sqlJsBaseUrl}sql-wasm.js`;
  }

  const tableTargets = {
    speedCompare: "speed-compare",
    latencyCompare: "latency-compare",
    dnsCompare: "dns-compare",
    wifiBuiltin: "wifi-builtin",
    wifiBackendTests: "wifi-backend-tests",
    wifiStability: "wifi-stability",
    wifiTools: "wifi-tools",
    serviceTests: "service-tests",
    evidenceCategories: "evidence-categories",
    primaryEvidence: "primary-evidence",
    nextSteps: "next-steps",
  };

  let sqlJsPromise;

  function byId(id) {
    return document.getElementById(id);
  }

  function text(value) {
    if (value === null || value === undefined || value === "") {
      return "n/a";
    }
    return String(value);
  }

  function clear(node) {
    while (node.firstChild) {
      node.removeChild(node.firstChild);
    }
  }

  function appendText(parent, value) {
    parent.appendChild(document.createTextNode(text(value)));
  }

  function selectedRunId() {
    const params = new URLSearchParams(window.location.search);
    return params.get("run") || config.runId || "";
  }

  function loadScript(src) {
    return new Promise((resolve, reject) => {
      const existing = document.querySelector(`script[src="${src}"]`);
      if (existing) {
        existing.addEventListener("load", resolve, { once: true });
        existing.addEventListener("error", reject, { once: true });
        return;
      }

      const script = document.createElement("script");
      script.src = src;
      script.async = true;
      script.onload = resolve;
      script.onerror = () => reject(new Error(`Could not load ${src}`));
      document.head.appendChild(script);
    });
  }

  async function loadSqlJs() {
    if (!sqlJsPromise) {
      sqlJsPromise = (async () => {
        if (!window.initSqlJs) {
          await loadScript(config.sqlJsScriptUrl);
        }

        return window.initSqlJs({
          locateFile: (file) => `${config.sqlJsBaseUrl}${file}`,
        });
      })();
    }

    return sqlJsPromise;
  }

  async function openDatabase(SQL) {
    const response = await fetch(config.dbUrl, { cache: "no-store" });
    if (!response.ok) {
      throw new Error(`Could not load ${config.dbUrl}: HTTP ${response.status}`);
    }

    return openDatabaseFromBuffer(SQL, await response.arrayBuffer());
  }

  function openDatabaseFromBuffer(SQL, buffer) {
    const db = new SQL.Database(new Uint8Array(buffer));
    db.run("PRAGMA query_only = ON;");
    return db;
  }

  function readFileAsArrayBuffer(file) {
    return new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = () => resolve(reader.result);
      reader.onerror = () => reject(reader.error || new Error(`Could not read ${file.name}`));
      reader.readAsArrayBuffer(file);
    });
  }

  function setLoadStatus(message) {
    const target = byId(config.loadStatusId);
    if (target) {
      target.textContent = message;
    }
  }

  async function loadSelectedFile(file) {
    setLoadStatus(`Loading ${file.name}`);
    const SQL = await loadSqlJs();
    const db = openDatabaseFromBuffer(SQL, await readFileAsArrayBuffer(file));

    try {
      render(buildReport(db));
      setLoadStatus(`Loaded ${file.name}`);
    } finally {
      db.close();
    }
  }

  function setupFileLoader() {
    const input = byId(config.fileInputId);
    if (!input) {
      return;
    }

    input.addEventListener("change", () => {
      const file = input.files && input.files[0];
      if (!file) {
        return;
      }

      loadSelectedFile(file).catch((error) => {
        setLoadStatus(`Could not load ${file.name}`);
        renderError(error);
      });
    });
  }

  function rows(db, sql, params) {
    const statement = db.prepare(sql);
    const output = [];

    try {
      if (params) {
        statement.bind(params);
      }

      while (statement.step()) {
        output.push(statement.getAsObject());
      }

      return output;
    } finally {
      statement.free();
    }
  }

  function firstRow(db, sql, params) {
    return rows(db, sql, params)[0] || {};
  }

  function scalar(db, sql, params) {
    const row = firstRow(db, sql, params);
    const values = Object.values(row);
    return values.length ? values[0] : "";
  }

  function tableExists(db, tableName) {
    return Number(scalar(
      db,
      "SELECT COUNT(*) FROM sqlite_schema WHERE type IN ('table', 'view') AND name = $name;",
      { $name: tableName },
    )) > 0;
  }

  function columnExists(db, tableName, columnName) {
    if (!/^[A-Za-z0-9_]+$/.test(tableName)) {
      return false;
    }

    return Number(scalar(
      db,
      `SELECT COUNT(*) FROM pragma_table_info('${tableName}') WHERE name = $name;`,
      { $name: columnName },
    )) > 0;
  }

  function latestRunId(db) {
    const explicit = selectedRunId();
    if (explicit) {
      return explicit;
    }

    return scalar(
      db,
      `
      SELECT COALESCE(
        (
          SELECT r.run_id
          FROM runs r
          WHERE EXISTS (
            SELECT 1
            FROM speed_tests st
            WHERE st.run_id = r.run_id
          )
          ORDER BY r.started_at DESC, r.run_id DESC
          LIMIT 1
        ),
        (
          SELECT run_id
          FROM runs
          ORDER BY started_at DESC, run_id DESC
          LIMIT 1
        )
      ) AS run_id;
      `,
    );
  }

  function currentPhase(db, runId) {
    return scalar(
      db,
      `
      SELECT phase
      FROM speed_tests
      WHERE run_id = $run_id
      ORDER BY CASE phase
        WHEN 'after-final' THEN 1
        WHEN 'after' THEN 2
        WHEN 'current' THEN 3
        WHEN 'before' THEN 4
        ELSE 5
      END
      LIMIT 1;
      `,
      { $run_id: runId },
    ) || "before";
  }

  function buildSummaryCards(db, runId, phase) {
    const speed = firstRow(
      db,
      `
      SELECT
        b.ping_ms AS before_ping,
        c.ping_ms AS current_ping,
        b.download_mbps AS before_download,
        c.download_mbps AS current_download,
        b.upload_mbps AS before_upload,
        c.upload_mbps AS current_upload
      FROM speed_tests b
      LEFT JOIN speed_tests c
        ON c.run_id = b.run_id
       AND c.phase = $phase
      WHERE b.run_id = $run_id
        AND b.phase = 'before'
      LIMIT 1;
      `,
      { $run_id: runId, $phase: phase },
    );

    if (!Object.keys(speed).length) {
      return [];
    }

    return [
      metricCard("Speedtest Ping", speed.before_ping, "ms", speed.current_ping, "ms", "lower"),
      metricCard("Download", speed.before_download, "Mbit/s", speed.current_download, "Mbit/s", "higher"),
      metricCard("Upload", speed.before_upload, "Mbit/s", speed.current_upload, "Mbit/s", "higher"),
    ];
  }

  function metricCard(label, before, beforeUnit, current, currentUnit, preferredDirection) {
    return {
      label,
      before: formatNumber(before, beforeUnit === "ms" ? 3 : 2),
      beforeUnit,
      current: formatNumber(current, currentUnit === "ms" ? 3 : 2),
      currentUnit,
      change: changeText(before, current, preferredDirection, currentUnit),
    };
  }

  function formatNumber(value, digits) {
    if (value === null || value === undefined || value === "") {
      return "n/a";
    }

    return Number(value).toFixed(digits);
  }

  function changeText(before, current, preferredDirection, unit) {
    if (before === null || before === undefined || current === null || current === undefined) {
      return "n/a";
    }

    const delta = Number(current) - Number(before);
    if (delta === 0) {
      return "no change";
    }

    const improved = preferredDirection === "higher" ? delta > 0 : delta < 0;
    const magnitude = Math.abs(delta).toFixed(unit === "ms" ? 3 : 2);
    return `${magnitude} ${unit} ${improved ? "better" : "worse"}`;
  }

  function buildReport(db) {
    const runId = latestRunId(db);
    if (!runId) {
      throw new Error("No runs found in the SQLite database.");
    }

    const phase = currentPhase(db, runId);
    const run = firstRow(
      db,
      `
      SELECT
        run_id AS id,
        'before -> current' AS comparison,
        $phase AS currentPhase,
        approval_status AS status,
        notes,
        (SELECT COUNT(*) FROM raw_logs WHERE run_id = runs.run_id) AS logCount,
        (
          SELECT COUNT(*)
          FROM raw_log_catalog
          WHERE run_id = runs.run_id
            AND is_primary = 1
        ) AS primaryLogCount
      FROM runs
      WHERE run_id = $run_id;
      `,
      { $run_id: runId, $phase: phase },
    );

    if (!Object.keys(run).length) {
      throw new Error(`Run not found in SQLite database: ${runId}`);
    }

    return {
      run,
      summaryCards: buildSummaryCards(db, runId, phase),
      tables: {
        speedCompare: speedCompareRows(db, runId, phase),
        latencyCompare: latencyCompareRows(db, runId, phase),
        dnsCompare: dnsCompareRows(db, runId, phase),
        wifiBuiltin: wifiBuiltinRows(db, runId),
        wifiBackendTests: wifiBackendRows(db, runId),
        wifiStability: wifiStabilityRows(db, runId),
        wifiTools: wifiToolRows(db, runId),
        serviceTests: serviceRows(db, runId, phase),
        evidenceCategories: evidenceCategoryRows(db, runId),
        primaryEvidence: primaryEvidenceRows(db, runId),
        nextSteps: nextStepRows(db),
      },
    };
  }

  function speedCompareRows(db, runId, phase) {
    return rows(
      db,
      `
      SELECT
        'Speedtest ping' AS Metric,
        printf('%.3f ms', b.ping_ms) AS Before,
        printf('%.3f ms', c.ping_ms) AS Current,
        CASE
          WHEN c.ping_ms < b.ping_ms THEN printf('%.3f ms lower', b.ping_ms - c.ping_ms)
          WHEN c.ping_ms > b.ping_ms THEN printf('%.3f ms higher', c.ping_ms - b.ping_ms)
          ELSE 'no change'
        END AS Change
      FROM speed_tests b
      JOIN speed_tests c ON c.run_id = b.run_id
      WHERE b.run_id = $run_id AND b.phase = 'before' AND c.phase = $phase
      UNION ALL
      SELECT
        'Download',
        printf('%.2f Mbit/s', b.download_mbps),
        printf('%.2f Mbit/s', c.download_mbps),
        CASE
          WHEN c.download_mbps > b.download_mbps THEN printf('%.2f Mbit/s higher', c.download_mbps - b.download_mbps)
          WHEN c.download_mbps < b.download_mbps THEN printf('%.2f Mbit/s lower', b.download_mbps - c.download_mbps)
          ELSE 'no change'
        END
      FROM speed_tests b
      JOIN speed_tests c ON c.run_id = b.run_id
      WHERE b.run_id = $run_id AND b.phase = 'before' AND c.phase = $phase
      UNION ALL
      SELECT
        'Upload',
        printf('%.2f Mbit/s', b.upload_mbps),
        printf('%.2f Mbit/s', c.upload_mbps),
        CASE
          WHEN c.upload_mbps > b.upload_mbps THEN printf('%.2f Mbit/s higher', c.upload_mbps - b.upload_mbps)
          WHEN c.upload_mbps < b.upload_mbps THEN printf('%.2f Mbit/s lower', b.upload_mbps - c.upload_mbps)
          ELSE 'no change'
        END
      FROM speed_tests b
      JOIN speed_tests c ON c.run_id = b.run_id
      WHERE b.run_id = $run_id AND b.phase = 'before' AND c.phase = $phase;
      `,
      { $run_id: runId, $phase: phase },
    );
  }

  function latencyCompareRows(db, runId, phase) {
    return rows(
      db,
      `
      SELECT
        b.target AS Target,
        printf('%.3f ms', b.avg_ms) AS "Before avg",
        printf('%.3f ms', c.avg_ms) AS "Current avg",
        CASE
          WHEN c.avg_ms < b.avg_ms THEN printf('%.3f ms lower', b.avg_ms - c.avg_ms)
          WHEN c.avg_ms > b.avg_ms THEN printf('%.3f ms higher', c.avg_ms - b.avg_ms)
          ELSE 'no change'
        END AS Change,
        printf('%.0f%% -> %.0f%%', b.packet_loss_percent, c.packet_loss_percent) AS "Packet loss"
      FROM latency_tests b
      JOIN latency_tests c
        ON c.run_id = b.run_id
       AND c.target = b.target
      WHERE b.run_id = $run_id
        AND b.phase = 'before'
        AND c.phase = $phase
      ORDER BY CASE
        WHEN b.target = 'gateway' OR b.target LIKE 'gateway %' THEN 1
        WHEN b.target = '1.1.1.1' THEN 2
        WHEN b.target = '8.8.8.8' THEN 3
        WHEN b.target = 'google.com' THEN 4
        ELSE 5
      END;
      `,
      { $run_id: runId, $phase: phase },
    );
  }

  function dnsCompareRows(db, runId, phase) {
    return rows(
      db,
      `
      SELECT
        b.resolver AS Resolver,
        printf('%.3f ms', b.avg_query_ms) AS Before,
        printf('%.3f ms', c.avg_query_ms) AS Current,
        CASE
          WHEN c.avg_query_ms < b.avg_query_ms THEN printf('%.3f ms lower', b.avg_query_ms - c.avg_query_ms)
          WHEN c.avg_query_ms > b.avg_query_ms THEN printf('%.3f ms higher', c.avg_query_ms - b.avg_query_ms)
          ELSE 'no change'
        END AS Change
      FROM dns_benchmarks b
      JOIN dns_benchmarks c
        ON c.run_id = b.run_id
       AND c.resolver = b.resolver
      WHERE b.run_id = $run_id
        AND b.phase = 'before'
        AND c.phase = $phase
      ORDER BY c.avg_query_ms;
      `,
      { $run_id: runId, $phase: phase },
    );
  }

  function wifiBuiltinRows(db, runId) {
    return rows(
      db,
      `
      WITH before_rows AS (
        SELECT tool_key, category, status, result
        FROM wifi_tool_tests
        WHERE run_id = $run_id AND phase = 'wifi-before'
      ),
      current_rows AS (
        SELECT tool_key, category, status, result
        FROM wifi_tool_tests
        WHERE run_id = $run_id AND phase = 'wifi-current'
      ),
      labels(tool_key, category, label, sort_order) AS (
        VALUES
          ('networkmanager', 'state', 'NetworkManager state', 10),
          ('networkmanager', 'wifi_scan', 'Active Wi-Fi AP', 20),
          ('iw', 'kernel_counters', 'Kernel wireless counters', 30)
      )
      SELECT
        l.label AS Signal,
        COALESCE(b.status, 'not tested') AS "Before status",
        COALESCE(b.result, 'n/a') AS Before,
        COALESCE(c.status, 'not tested') AS "Current status",
        COALESCE(c.result, 'n/a') AS Current
      FROM labels l
      LEFT JOIN before_rows b
        ON b.tool_key = l.tool_key
       AND b.category = l.category
      LEFT JOIN current_rows c
        ON c.tool_key = l.tool_key
       AND c.category = l.category
      ORDER BY l.sort_order;
      `,
      { $run_id: runId },
    );
  }

  function wifiBackendRows(db, runId) {
    if (!tableExists(db, "wifi_backend_tests")) {
      return [];
    }

    const hasBaseRun = columnExists(db, "wifi_backend_tests", "base_run_id");
    const whereClause = hasBaseRun
      ? "(run_id = $run_id OR base_run_id = $run_id)"
      : "run_id = $run_id";

    return rows(
      db,
      `
      SELECT
        run_id AS "Attempt run",
        backend AS Backend,
        phase AS Phase,
        status AS Status,
        connection_name AS Connection,
        interface_name AS Interface,
        COALESCE(original_bssid, 'n/a') AS "Original BSSID",
        COALESCE(preferred_bssid, 'n/a') AS "Preferred BSSID",
        started_at AS Started,
        COALESCE(finished_at, 'n/a') AS Finished,
        notes AS Notes
      FROM wifi_backend_tests
      WHERE ${whereClause}
      ORDER BY started_at DESC, backend;
      `,
      { $run_id: runId },
    );
  }

  function wifiStabilityRows(db, runId) {
    const iwdRunId = tableExists(db, "wifi_backend_tests") &&
      columnExists(db, "wifi_backend_tests", "base_run_id")
      ? scalar(
        db,
        `
        SELECT run_id
        FROM wifi_backend_tests
        WHERE run_id = $run_id
           OR base_run_id = $run_id
        ORDER BY started_at DESC, run_id DESC
        LIMIT 1;
        `,
        { $run_id: runId },
      ) || runId
      : runId;

    return rows(
      db,
      `
      WITH groups(phase, sample_group, backend, label, sort_order) AS (
        VALUES
          ('wifi-experiments', 'stability-current', 'NetworkManager/wpa_supplicant', '5-minute current stability', 10),
          ('wifi-experiments', 'bssid-auto', 'NetworkManager/wpa_supplicant', 'BSSID pin off', 20),
          ('wifi-experiments', 'bssid-pinned', 'NetworkManager/wpa_supplicant', 'BSSID pin on', 30),
          ('wifi-iwd-experiments', 'stability-current', 'NetworkManager/iwd', '5-minute current stability', 40),
          ('wifi-iwd-experiments', 'bssid-auto', 'NetworkManager/iwd', 'BSSID pin off', 50),
          ('wifi-iwd-experiments', 'bssid-pinned', 'NetworkManager/iwd', 'BSSID pin on', 60)
      )
      SELECT
        CASE WHEN g.phase = 'wifi-iwd-experiments' THEN $iwd_run_id ELSE $run_id END AS Run,
        g.backend AS Backend,
        g.label AS Test,
        COUNT(s.id) AS Samples,
        COALESCE(GROUP_CONCAT(DISTINCT s.connected_bssid), 'n/a') AS "Connected BSSID",
        CASE WHEN COUNT(s.id) > 0 THEN printf('%.1f dBm', AVG(s.iw_signal_dbm)) ELSE 'n/a' END AS "Avg signal",
        CASE WHEN COUNT(s.id) > 0 THEN printf('%.1f dBm', MIN(s.iw_signal_dbm)) ELSE 'n/a' END AS "Worst signal",
        CASE WHEN COUNT(s.id) > 0 THEN printf('%.1f dBm', MAX(s.iw_signal_dbm)) ELSE 'n/a' END AS "Best signal",
        CASE WHEN COUNT(s.id) > 0 THEN printf('%.1f Mbit/s', AVG(s.tx_bitrate_mbps)) ELSE 'n/a' END AS "Avg TX bitrate",
        CASE WHEN COUNT(s.id) > 0 THEN printf('%.1f Mbit/s', AVG(s.rx_bitrate_mbps)) ELSE 'n/a' END AS "Avg RX bitrate",
        CASE WHEN COUNT(s.id) > 0 THEN printf('%d', COALESCE(MAX(s.tx_retries) - MIN(s.tx_retries), 0)) ELSE 'n/a' END AS "TX retries delta",
        CASE WHEN COUNT(s.id) > 0 THEN printf('%d', COALESCE(MAX(s.tx_failed) - MIN(s.tx_failed), 0)) ELSE 'n/a' END AS "TX failed delta",
        CASE WHEN COUNT(s.id) > 0 THEN printf('%d', COALESCE(MAX(s.beacon_loss) - MIN(s.beacon_loss), 0)) ELSE 'n/a' END AS "Beacon loss delta"
      FROM groups g
      LEFT JOIN wifi_stability_samples s
        ON s.run_id = CASE
          WHEN g.phase = 'wifi-iwd-experiments' THEN $iwd_run_id
          ELSE $run_id
        END
       AND s.phase = g.phase
       AND s.sample_group = g.sample_group
      GROUP BY g.phase, g.sample_group, g.backend, g.label, g.sort_order
      ORDER BY g.sort_order;
      `,
      { $run_id: runId, $iwd_run_id: iwdRunId },
    );
  }

  function wifiToolRows(db, runId) {
    return rows(
      db,
      `
      WITH before_summary AS (
        SELECT
          tool_key,
          CASE
            WHEN SUM(CASE WHEN status = 'measured' THEN 1 ELSE 0 END) > 0 THEN 'measured'
            WHEN SUM(CASE WHEN status = 'skipped' THEN 1 ELSE 0 END) > 0 THEN 'skipped'
            WHEN SUM(CASE WHEN status = 'blocked' THEN 1 ELSE 0 END) > 0 THEN 'blocked'
            WHEN SUM(CASE WHEN status IN ('installed', 'available') THEN 1 ELSE 0 END) > 0 THEN 'available'
            ELSE MAX(status)
          END AS status,
          COALESCE(
            MAX(CASE WHEN status = 'measured' THEN result END),
            MAX(CASE WHEN status = 'skipped' THEN result END),
            MAX(CASE WHEN status = 'blocked' THEN result END),
            MAX(result)
          ) AS result
        FROM wifi_tool_tests
        WHERE run_id = $run_id
          AND phase = 'wifi-before'
          AND category = 'summary'
        GROUP BY tool_key
      ),
      current_summary AS (
        SELECT
          tool_key,
          CASE
            WHEN SUM(CASE WHEN status = 'measured' THEN 1 ELSE 0 END) > 0 THEN 'measured'
            WHEN SUM(CASE WHEN status = 'skipped' THEN 1 ELSE 0 END) > 0 THEN 'skipped'
            WHEN SUM(CASE WHEN status = 'blocked' THEN 1 ELSE 0 END) > 0 THEN 'blocked'
            WHEN SUM(CASE WHEN status IN ('installed', 'available') THEN 1 ELSE 0 END) > 0 THEN 'available'
            ELSE MAX(status)
          END AS status,
          COALESCE(
            MAX(CASE WHEN status = 'measured' THEN result END),
            MAX(CASE WHEN status = 'skipped' THEN result END),
            MAX(CASE WHEN status = 'blocked' THEN result END),
            MAX(result)
          ) AS result
        FROM wifi_tool_tests
        WHERE run_id = $run_id
          AND phase = 'wifi-current'
          AND category = 'summary'
        GROUP BY tool_key
      )
      SELECT
        n.display_name AS Tool,
        n.risk_level AS Level,
        COALESCE(b.status, 'not tested') AS Before,
        COALESCE(c.status, 'not tested') AS Current,
        COALESCE(c.result, b.result, n.why) AS "Current result",
        n.requires AS Requires
      FROM wifi_next_steps n
      LEFT JOIN before_summary b ON b.tool_key = n.tool_key
      LEFT JOIN current_summary c ON c.tool_key = n.tool_key
      ORDER BY n.sort_order;
      `,
      { $run_id: runId },
    );
  }

  function serviceRows(db, runId, phase) {
    return rows(
      db,
      `
      SELECT
        service AS Service,
        printf('%.3f ms', ping_avg_ms) AS "Current ping avg",
        printf('%.0f%%', ping_loss_percent) AS Loss,
        https_http_code AS "HTTP code",
        printf('%.1f ms', https_total_s * 1000.0) AS "HTTPS total"
      FROM service_tests
      WHERE run_id = $run_id
        AND phase = $phase
      ORDER BY service;
      `,
      { $run_id: runId, $phase: phase },
    );
  }

  function evidenceCategoryRows(db, runId) {
    return rows(
      db,
      `
      SELECT
        section_title AS Category,
        COUNT(*) AS Logs,
        SUM(CASE WHEN is_primary = 1 THEN 1 ELSE 0 END) AS "Primary logs",
        SUM(size_bytes) AS Bytes
      FROM raw_log_catalog
      WHERE run_id = $run_id
      GROUP BY section_key, section_title
      ORDER BY MIN(display_order), section_title;
      `,
      { $run_id: runId },
    );
  }

  function primaryEvidenceRows(db, runId) {
    return rows(
      db,
      `
      SELECT
        section_title AS Category,
        phase AS Phase,
        signal_type AS "Signal type",
        source_tool AS "Source tool",
        target AS Target,
        display_label AS Label,
        relative_path AS Path
      FROM raw_log_catalog
      WHERE run_id = $run_id
        AND is_primary = 1
      ORDER BY display_order, section_title, phase, relative_path;
      `,
      { $run_id: runId },
    );
  }

  function nextStepRows(db) {
    return rows(
      db,
      `
      SELECT
        risk_level AS Level,
        display_name AS Option,
        package_names AS Packages,
        auto_test AS "Auto test",
        why AS Why,
        requires AS Requires
      FROM wifi_next_steps
      ORDER BY sort_order;
      `,
    );
  }

  function renderMeta(run) {
    const meta = byId("run-meta");
    clear(meta);

    [
      ["Run", run.id || "no data"],
      ["Comparison", run.comparison || "before -> current"],
      ["Status", run.status || "unknown"],
    ].forEach(([label, value]) => {
      const row = document.createElement("span");
      const strong = document.createElement("strong");
      const valueNode = document.createElement("span");
      appendText(strong, label);
      appendText(valueNode, value);
      row.append(strong, valueNode);
      meta.appendChild(row);
    });
  }

  function renderCards(cards) {
    const container = byId("summary-cards");
    clear(container);

    if (!cards || cards.length === 0) {
      container.appendChild(emptyState("No summary metrics found in SQLite yet."));
      return;
    }

    cards.forEach((card) => {
      const article = document.createElement("article");
      article.className = "comparison-card";

      const label = document.createElement("span");
      label.className = "label";
      appendText(label, card.label);

      const comparison = document.createElement("div");
      comparison.className = "before-current";
      comparison.append(
        metricSide(card.before, `Before ${card.beforeUnit || ""}`.trim()),
        arrow(),
        metricSide(card.current, `Current ${card.currentUnit || ""}`.trim()),
      );

      const change = document.createElement("div");
      change.className = "change-note";
      appendText(change, card.change);

      article.append(label, comparison, change);
      container.appendChild(article);
    });
  }

  function metricSide(value, label) {
    const wrapper = document.createElement("div");
    const strong = document.createElement("strong");
    const span = document.createElement("span");
    appendText(strong, value);
    appendText(span, label);
    wrapper.append(strong, span);
    return wrapper;
  }

  function arrow() {
    const node = document.createElement("div");
    node.className = "arrow";
    node.textContent = "->";
    return node;
  }

  function emptyState(message) {
    const node = document.createElement("div");
    node.className = "empty-state";
    appendText(node, message);
    return node;
  }

  function renderTable(targetId, tableRows) {
    const target = byId(targetId);
    clear(target);

    if (!tableRows || tableRows.length === 0) {
      target.appendChild(emptyState("No rows found in SQLite for this section."));
      return;
    }

    const table = document.createElement("table");
    const thead = document.createElement("thead");
    const tbody = document.createElement("tbody");
    const headers = Object.keys(tableRows[0]);
    const headerRow = document.createElement("tr");

    headers.forEach((header) => {
      const th = document.createElement("th");
      appendText(th, header);
      headerRow.appendChild(th);
    });

    tableRows.forEach((row) => {
      const tr = document.createElement("tr");
      headers.forEach((header) => {
        const td = document.createElement("td");
        appendText(td, row[header]);
        tr.appendChild(td);
      });
      tbody.appendChild(tr);
    });

    thead.appendChild(headerRow);
    table.append(thead, tbody);
    target.appendChild(table);
  }

  function renderChangeSummary(data) {
    const target = byId("change-summary");
    const run = data.run || {};
    const wifiRows = (data.tables && data.tables.wifiBuiltin) || [];
    const state = wifiRows.find((row) => row.Signal === "NetworkManager state");
    const ap = wifiRows.find((row) => row.Signal === "Active Wi-Fi AP");

    if (!state && !ap) {
      target.textContent = "Publish a local SQLite report database to render this machine's settings and measurements.";
      return;
    }

    const parts = [];
    if (state && state.Current) {
      parts.push(state.Current);
    }
    if (ap && ap.Current) {
      parts.push(ap.Current);
    }

    target.textContent = parts.join(" ");
    if (run.notes) {
      target.appendChild(document.createElement("br"));
      appendText(target, run.notes);
    }
  }

  function renderEvidenceSummary(run) {
    const target = byId("evidence-summary");
    target.textContent = `${text(run.logCount)} raw files are stored in SQLite; ${text(run.primaryLogCount)} are marked as primary evidence. Raw logs and generated databases stay local by default.`;
  }

  function render(data) {
    const run = data.run || {};
    const tables = data.tables || {};

    renderMeta(run);
    renderCards(data.summaryCards || []);
    renderChangeSummary(data);
    renderEvidenceSummary(run);

    Object.entries(tableTargets).forEach(([key, id]) => {
      renderTable(id, tables[key] || []);
    });
  }

  function renderError(error) {
    renderMeta({ id: "no data", comparison: "before -> current", status: "publish needed" });
    renderCards([]);
    byId("change-summary").textContent =
      `No SQLite report database loaded. Serve the repo locally or open a SQLite snapshot with the file picker. Detail: ${error.message}`;
    byId("evidence-summary").textContent =
      "The committed viewer reads an ignored local SQLite file from data/report.sqlite.";

    Object.values(tableTargets).forEach((id) => {
      renderTable(id, []);
    });
  }

  async function main() {
    setupFileLoader();

    const SQL = await loadSqlJs();
    const db = await openDatabase(SQL);

    try {
      render(buildReport(db));
      setLoadStatus(`Loaded ${config.dbUrl}`);
    } finally {
      db.close();
    }
  }

  main().catch(renderError);
})();
