// 万象书屋: 书源健康度 / 解析器质量追踪

const _ALLOWED_SOURCE_PLATFORMS = new Set(['android', 'ios', 'web']);
const _SOURCE_STAGES = new Set(['search', 'info', 'toc', 'content', 'static']);
const _SOURCE_STATUSES = new Set(['ok', 'zero', 'error', 'timeout', 'skip']);

let db;
let sourcesModel; // 引用 sources model 做 cache invalidate + exists check
let stmtHealthUpsert, stmtErrorEventInsert, stmtHealthList, stmtHealthSummary;

function init(database, _sourcesModel) {
  db = database;
  sourcesModel = _sourcesModel;

  stmtHealthUpsert = db.prepare(
    `INSERT INTO source_health
       (source_url, platform, stage, sample_keyword, status, error_message,
        success_count, fail_count, last_checked_at, last_ok_at, last_error_at, app_ver)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT(source_url, platform, stage, sample_keyword)
     DO UPDATE SET
       status=excluded.status,
       error_message=excluded.error_message,
       success_count=source_health.success_count + excluded.success_count,
       fail_count=source_health.fail_count + excluded.fail_count,
       last_checked_at=excluded.last_checked_at,
       last_ok_at=COALESCE(excluded.last_ok_at, source_health.last_ok_at),
       last_error_at=COALESCE(excluded.last_error_at, source_health.last_error_at),
       app_ver=COALESCE(excluded.app_ver, source_health.app_ver)`
  );

  stmtErrorEventInsert = db.prepare(
    `INSERT INTO source_error_events
       (ts, source_url, source_name, platform, stage, status, error_message,
        sample_keyword, sample_url, app_ver, device_id, ip)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
  );

  stmtHealthList = db.prepare(
    `SELECT h.*, bs.name AS source_name
     FROM source_health h
     LEFT JOIN book_sources bs ON bs.url = h.source_url
     WHERE (? IS NULL OR h.platform = ?)
       AND (? IS NULL OR h.stage = ?)
       AND (? IS NULL OR h.status = ?)
       AND (? IS NULL OR h.source_url = ?)
     ORDER BY h.last_checked_at DESC
     LIMIT ?`
  );

  stmtHealthSummary = db.prepare(
    `SELECT platform, stage, status, COUNT(*) AS count,
            SUM(success_count) AS success_count,
            SUM(fail_count) AS fail_count
     FROM source_health
     WHERE (? IS NULL OR platform = ?)
     GROUP BY platform, stage, status
     ORDER BY platform, stage, status`
  );
}

function _cleanPlatform(platform) {
  const p = String(platform || 'ios').toLowerCase().trim();
  return _ALLOWED_SOURCE_PLATFORMS.has(p) ? p : 'ios';
}

function _cleanStage(stage) {
  const s = String(stage || 'search').toLowerCase().trim();
  return _SOURCE_STAGES.has(s) ? s : 'search';
}

function _cleanStatus(status) {
  const s = String(status || 'error').toLowerCase().trim();
  return _SOURCE_STATUSES.has(s) ? s : 'error';
}

function recordSourceHealth(input, opts = {}) {
  const now = Date.now();
  const sourceUrl = String(input.sourceUrl || input.source_url || '').trim();
  if (!sourceUrl) throw new Error('sourceUrl required');
  const platform = _cleanPlatform(input.platform);
  const stage = _cleanStage(input.stage);
  const status = _cleanStatus(input.status);
  const sampleKeyword = String(input.sampleKeyword || input.sample_keyword || '').slice(0, 128);
  const errorMessage = input.errorMessage || input.error_message
    ? String(input.errorMessage || input.error_message).slice(0, 1000)
    : null;
  const ok = status === 'ok';
  stmtHealthUpsert.run(
    sourceUrl, platform, stage, sampleKeyword, status, errorMessage,
    ok ? 1 : 0,
    ok || status === 'skip' ? 0 : 1,
    now,
    ok ? now : null,
    ok || status === 'skip' ? null : now,
    input.appVer || input.app_ver || null
  );
  if (!opts.skipCacheInvalidate) sourcesModel.invalidateSourcesCache();
  return { ok: true, sourceUrl, platform, stage, status };
}

function recordSourceErrorEvent(input, ip) {
  const now = Date.now();
  const sourceUrl = String(input.sourceUrl || input.source_url || '').trim();
  if (!sourceUrl) throw new Error('sourceUrl required');
  if (!sourcesModel.checkSourceExists(sourceUrl)) {
    throw new Error('unknown sourceUrl');
  }
  const platform = _cleanPlatform(input.platform);
  const stage = _cleanStage(input.stage);
  const status = _cleanStatus(input.status || 'error');
  const event = {
    ts: now,
    source_url: sourceUrl,
    source_name: input.sourceName || input.source_name || null,
    platform,
    stage,
    status,
    error_message: input.errorMessage || input.error_message ? String(input.errorMessage || input.error_message).slice(0, 1000) : null,
    sample_keyword: input.sampleKeyword || input.sample_keyword ? String(input.sampleKeyword || input.sample_keyword).slice(0, 128) : null,
    sample_url: input.sampleUrl || input.sample_url ? String(input.sampleUrl || input.sample_url).slice(0, 1000) : null,
    app_ver: input.appVer || input.app_ver || null,
    device_id: input.deviceId || input.device_id || null,
    ip: ip || null
  };
  stmtErrorEventInsert.run(
    event.ts, event.source_url, event.source_name, event.platform, event.stage,
    event.status, event.error_message, event.sample_keyword, event.sample_url,
    event.app_ver, event.device_id, event.ip
  );
  recordSourceHealth({
    sourceUrl,
    platform,
    stage,
    status,
    errorMessage: event.error_message,
    sampleKeyword: event.sample_keyword || '',
    appVer: event.app_ver
  }, { skipCacheInvalidate: true });
  return { ok: true };
}

function listSourceHealth(filters = {}) {
  const platform = filters.platform ? _cleanPlatform(filters.platform) : null;
  const stage = filters.stage ? _cleanStage(filters.stage) : null;
  const status = filters.status ? _cleanStatus(filters.status) : null;
  const sourceUrl = filters.sourceUrl || filters.source_url || null;
  const limit = Math.min(Math.max(parseInt(filters.limit, 10) || 200, 1), 1000);
  return stmtHealthList.all(platform, platform, stage, stage, status, status, sourceUrl, sourceUrl, limit);
}

function sourceHealthSummary(platform = null) {
  const p = platform ? _cleanPlatform(platform) : null;
  return stmtHealthSummary.all(p, p);
}

function _recordStaticCheck(src, platform, sampleKeyword) {
  const url = src.bookSourceUrl;
  const checks = [];
  const rs = src.ruleSearch || {};
  checks.push(['search', src.searchUrl && rs.bookList && rs.name && rs.bookUrl]);
  const ri = src.ruleBookInfo || {};
  checks.push(['info', !!(ri.name || ri.author || ri.tocUrl || ri.coverUrl || ri.intro)]);
  const rt = src.ruleToc || {};
  checks.push(['toc', !!(rt.chapterList && (rt.chapterName || rt.chapterUrl))]);
  const rc = src.ruleContent || {};
  checks.push(['content', !!rc.content]);
  let okCount = 0, errorCount = 0;
  for (const [stage, pass] of checks) {
    if (pass) okCount++;
    else errorCount++;
    recordSourceHealth({
      sourceUrl: url,
      platform,
      stage,
      status: pass ? 'ok' : 'error',
      errorMessage: pass ? null : `missing ${stage} required rules`,
      sampleKeyword
    }, { skipCacheInvalidate: true });
  }
  return { url, name: src.bookSourceName || url, okCount, errorCount };
}

function runSourceStaticCheck({ platform = 'ios', sampleKeyword = '斗破苍穹', url = null } = {}) {
  const p = _cleanPlatform(platform);
  const list = url
    ? (() => {
        const row = sourcesModel.getSource(url);
        return row ? [JSON.parse(row.json)] : [];
      })()
    : sourcesModel.listEnabledSourcesJson(p);
  const results = db.transaction(() => list.map(src => _recordStaticCheck(src, p, sampleKeyword)))();
  sourcesModel.invalidateSourcesCache();
  return {
    platform: p,
    checked: results.length,
    ok: results.filter(r => r.errorCount === 0).length,
    error: results.filter(r => r.errorCount > 0).length,
    results
  };
}

module.exports = {
  init, recordSourceHealth, recordSourceErrorEvent,
  listSourceHealth, sourceHealthSummary, runSourceStaticCheck,
};
