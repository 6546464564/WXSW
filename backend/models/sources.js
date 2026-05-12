// 万象书屋: 书源 CRUD + 内存缓存

const _ALLOWED_SOURCE_PLATFORMS = new Set(['android', 'ios', 'web']);

let db; // 由 init() 注入
let stmtListEnabledJson, stmtListEnabledJsonByPlatform,
    stmtListEnabledJsonByPlatformHealthy, stmtListAll,
    stmtGetSource, stmtUpsertSource, stmtCheckSourceExists,
    stmtDeleteSource, stmtSetEnabled, stmtSetPlatforms;

const HEALTH_HIDE_MIN_FAIL_COUNT = 5;

const cachedEnabledByPlatform = new Map();
const cachedEnabledEtagByPlatform = new Map();

function invalidateSourcesCache() {
  cachedEnabledByPlatform.clear();
  cachedEnabledEtagByPlatform.clear();
}

function init(database) {
  db = database;
  stmtListEnabledJson = db.prepare('SELECT json FROM book_sources WHERE enabled = 1');
  stmtListEnabledJsonByPlatform = db.prepare(
    `SELECT json FROM book_sources
     WHERE enabled = 1
       AND (',' || platforms || ',') LIKE ('%,' || ? || ',%')`
  );
  stmtListEnabledJsonByPlatformHealthy = db.prepare(
    `SELECT bs.json
     FROM book_sources bs
     WHERE bs.enabled = 1
       AND (',' || bs.platforms || ',') LIKE ('%,' || ? || ',%')
       AND NOT EXISTS (
         SELECT 1 FROM source_health sh
         WHERE sh.source_url = bs.url
           AND sh.platform = ?
           AND sh.stage = 'search'
           AND sh.status IN ('error', 'timeout')
           AND sh.fail_count >= ${HEALTH_HIDE_MIN_FAIL_COUNT}
           AND sh.success_count = 0
       )`
  );
  stmtListAll = db.prepare(
    `SELECT url, name, enabled, updated_at, platforms,
            json_extract(json, '$.bookSourceGroup') AS groupRaw
     FROM book_sources ORDER BY updated_at DESC`
  );
  stmtGetSource = db.prepare('SELECT * FROM book_sources WHERE url = ?');
  stmtUpsertSource = db.prepare(
    `INSERT INTO book_sources(url, name, json, enabled, created_at, updated_at)
     VALUES (?, ?, ?, 1, ?, ?)
     ON CONFLICT(url) DO UPDATE SET name=excluded.name, json=excluded.json, updated_at=excluded.updated_at`
  );
  stmtCheckSourceExists = db.prepare('SELECT 1 FROM book_sources WHERE url = ? LIMIT 1');
  stmtDeleteSource = db.prepare('DELETE FROM book_sources WHERE url = ?');
  stmtSetEnabled = db.prepare('UPDATE book_sources SET enabled=?, updated_at=? WHERE url=?');
  stmtSetPlatforms = db.prepare('UPDATE book_sources SET platforms=?, updated_at=? WHERE url=?');
}

function listEnabledSourcesJson(platform = null, opts = {}) {
  const key = platform == null ? '__all__'
    : (_ALLOWED_SOURCE_PLATFORMS.has(platform) ? platform : 'android');
  const healthyOnly = !!opts.healthyOnly && key !== '__all__';

  if (healthyOnly) {
    const rows = stmtListEnabledJsonByPlatformHealthy.all(key, key);
    return rows.map(r => JSON.parse(r.json));
  }

  const cached = cachedEnabledByPlatform.get(key);
  if (cached) return cached;
  const rows = key === '__all__'
    ? stmtListEnabledJson.all()
    : stmtListEnabledJsonByPlatform.all(key);
  const list = rows.map(r => JSON.parse(r.json));
  cachedEnabledByPlatform.set(key, list);
  return list;
}

function getEnabledSourcesEtag(platform = null, opts = {}) {
  const key = platform == null ? '__all__'
    : (_ALLOWED_SOURCE_PLATFORMS.has(platform) ? platform : 'android');
  const healthyOnly = !!opts.healthyOnly && key !== '__all__';

  if (healthyOnly) {
    const list = listEnabledSourcesJson(platform, opts);
    const hash = require('crypto')
      .createHash('md5')
      .update(JSON.stringify(list))
      .digest('hex')
      .slice(0, 12);
    return `"sources-${key}-healthy-${hash}"`;
  }

  const cached = cachedEnabledEtagByPlatform.get(key);
  if (cached) return cached;
  const list = listEnabledSourcesJson(platform, opts);
  const hash = require('crypto')
    .createHash('md5')
    .update(JSON.stringify(list))
    .digest('hex')
    .slice(0, 12);
  const etag = key === '__all__' ? `"sources-${hash}"` : `"sources-${key}-${hash}"`;
  cachedEnabledEtagByPlatform.set(key, etag);
  return etag;
}

function listAllSources() { return stmtListAll.all(); }

function getSource(url) { return stmtGetSource.get(url); }

function checkSourceExists(url) { return !!stmtCheckSourceExists.get(url); }

function upsertSource(srcJson) {
  const url = srcJson.bookSourceUrl;
  if (!url) throw new Error('bookSourceUrl required');
  if (typeof url !== 'string' || url.length > 2048) {
    throw new Error('bookSourceUrl invalid');
  }
  if (!/^https?:\/\//i.test(url)) {
    throw new Error('bookSourceUrl must start with http:// or https://');
  }
  try { new URL(url); } catch {
    throw new Error('bookSourceUrl is not a valid URL');
  }
  const name = srcJson.bookSourceName || url;
  const now = Date.now();
  const existed = !!stmtCheckSourceExists.get(url);
  stmtUpsertSource.run(url, name, JSON.stringify(srcJson), now, now);
  invalidateSourcesCache();
  return { url, action: existed ? 'updated' : 'created' };
}

function bulkUpsert(arr) {
  const tx = db.transaction((items) => {
    let created = 0, updated = 0;
    for (const it of items) {
      const r = upsertSource(it);
      if (r.action === 'created') created++; else updated++;
    }
    return { created, updated };
  });
  return tx(arr);
}

function deleteSource(url) {
  const info = stmtDeleteSource.run(url);
  invalidateSourcesCache();
  return info.changes;
}

function setEnabled(url, enabled) {
  const info = stmtSetEnabled.run(enabled ? 1 : 0, Date.now(), url);
  invalidateSourcesCache();
  return info.changes;
}

function setSourcePlatforms(url, platforms) {
  if (!Array.isArray(platforms)) throw new Error('platforms must be an array');
  const cleaned = Array.from(new Set(
    platforms
      .map(p => String(p || '').toLowerCase().trim())
      .filter(p => _ALLOWED_SOURCE_PLATFORMS.has(p))
  )).sort();
  const csv = cleaned.join(',');
  const info = stmtSetPlatforms.run(csv, Date.now(), url);
  invalidateSourcesCache();
  return info.changes;
}

function _invalidateSourcesCacheForTest() { invalidateSourcesCache(); }

module.exports = {
  init, listEnabledSourcesJson, getEnabledSourcesEtag, listAllSources,
  getSource, checkSourceExists, upsertSource, bulkUpsert, deleteSource,
  setEnabled, setSourcePlatforms, invalidateSourcesCache,
  _invalidateSourcesCacheForTest,
};
