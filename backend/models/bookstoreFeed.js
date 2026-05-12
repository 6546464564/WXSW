// 万象书屋: 书城 feed + mirror cache

let db;
let stmtFeedListByChannel, stmtFeedListAll, stmtFeedInsert,
    stmtFeedUpdate, stmtFeedSetEnabled, stmtFeedDelete;
let stmtMirrorInsert, stmtMirrorLatestOk, stmtMirrorRecent,
    stmtMirrorCleanup, stmtMirrorSetOverrides;

let feedCachedByChannel = new Map();
let feedEtagByChannel = new Map();

function invalidateFeedCache() {
  feedCachedByChannel.clear();
  feedEtagByChannel.clear();
}

function init(database) {
  db = database;

  stmtFeedListByChannel = db.prepare(
    `SELECT id, channel, section, name, author, cover_url, intro, kind,
            target_url, source_origin, priority, enabled, updated_at
     FROM bookstore_feed
     WHERE enabled = 1 AND channel = ?
     ORDER BY priority ASC, id ASC`
  );
  stmtFeedListAll = db.prepare(
    `SELECT id, channel, section, name, author, cover_url, intro, kind,
            target_url, source_origin, priority, enabled, updated_at
     FROM bookstore_feed
     ORDER BY channel ASC, priority ASC, id ASC`
  );
  stmtFeedInsert = db.prepare(
    `INSERT INTO bookstore_feed
       (channel, section, name, author, cover_url, intro, kind,
        target_url, source_origin, priority, enabled, updated_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
  );
  stmtFeedUpdate = db.prepare(
    `UPDATE bookstore_feed SET
       channel=?, section=?, name=?, author=?, cover_url=?, intro=?, kind=?,
       target_url=?, source_origin=?, priority=?, enabled=?, updated_at=?
     WHERE id=?`
  );
  stmtFeedSetEnabled = db.prepare(
    `UPDATE bookstore_feed SET enabled = ?, updated_at = ? WHERE id = ?`
  );
  stmtFeedDelete = db.prepare(`DELETE FROM bookstore_feed WHERE id = ?`);

  // mirror statements
  stmtMirrorInsert = db.prepare(
    `INSERT INTO bookstore_mirror (version, payload, etag, fetched_at, source, ok, err_msg)
     VALUES (?, ?, ?, ?, ?, ?, ?)`
  );
  stmtMirrorLatestOk = db.prepare(
    `SELECT id, version, payload, etag, fetched_at, source, overrides_json
     FROM bookstore_mirror WHERE ok = 1 ORDER BY id DESC LIMIT 1`
  );
  stmtMirrorRecent = db.prepare(
    `SELECT id, version, etag, fetched_at, source, ok, err_msg, length(payload) AS payload_size
     FROM bookstore_mirror ORDER BY id DESC LIMIT ?`
  );
  stmtMirrorCleanup = db.prepare(
    `DELETE FROM bookstore_mirror WHERE id NOT IN
       (SELECT id FROM bookstore_mirror ORDER BY id DESC LIMIT ?)`
  );
  stmtMirrorSetOverrides = db.prepare(
    `UPDATE bookstore_mirror SET overrides_json = ? WHERE id = ?`
  );
}

function listBookstoreFeed(channel) {
  if (!channel) return [];
  const cached = feedCachedByChannel.get(channel);
  if (cached) return cached;
  const rows = stmtFeedListByChannel.all(channel);
  const list = rows.map(r => ({
    id: r.id,
    channel: r.channel,
    section: r.section,
    name: r.name,
    author: r.author,
    coverUrl: r.cover_url,
    intro: r.intro,
    kind: r.kind,
    bookUrl: r.target_url,
    origin: r.source_origin || '',
    originName: '书城推荐',
    priority: r.priority,
  }));
  feedCachedByChannel.set(channel, list);
  return list;
}

function getBookstoreFeedEtag(channel) {
  const cached = feedEtagByChannel.get(channel);
  if (cached) return cached;
  const list = listBookstoreFeed(channel);
  const hash = require('crypto')
    .createHash('md5')
    .update(JSON.stringify(list))
    .digest('hex')
    .slice(0, 12);
  const etag = `"feed-${channel}-${hash}"`;
  feedEtagByChannel.set(channel, etag);
  return etag;
}

function listAllBookstoreFeed() { return stmtFeedListAll.all(); }

function upsertBookstoreFeed(item) {
  const now = Date.now();
  if (item.id) {
    stmtFeedUpdate.run(
      item.channel, item.section || 'recommend', item.name,
      item.author || '', item.cover_url || null, item.intro || null,
      item.kind || null, item.target_url, item.source_origin || null,
      Number.isFinite(item.priority) ? item.priority : 0,
      item.enabled === false ? 0 : 1, now, item.id
    );
  } else {
    const r = stmtFeedInsert.run(
      item.channel, item.section || 'recommend', item.name,
      item.author || '', item.cover_url || null, item.intro || null,
      item.kind || null, item.target_url, item.source_origin || null,
      Number.isFinite(item.priority) ? item.priority : 0,
      item.enabled === false ? 0 : 1, now
    );
    item.id = r.lastInsertRowid;
  }
  invalidateFeedCache();
  return item;
}

function setBookstoreFeedEnabled(id, enabled) {
  stmtFeedSetEnabled.run(enabled ? 1 : 0, Date.now(), id);
  invalidateFeedCache();
}

function deleteBookstoreFeed(id) {
  const info = stmtFeedDelete.run(id);
  invalidateFeedCache();
  return info.changes;
}

// --- Mirror ---

function insertBookstoreMirror({ version, payload, etag, fetched_at, source, ok, err_msg }) {
  stmtMirrorInsert.run(version, payload, etag, fetched_at, source, ok ? 1 : 0, err_msg || null);
}

function getLatestBookstoreMirror() {
  return stmtMirrorLatestOk.get() || null;
}

function listRecentBookstoreMirror(limit = 24) {
  return stmtMirrorRecent.all(limit);
}

function cleanupOldBookstoreMirror(keepCount = 24) {
  stmtMirrorCleanup.run(keepCount);
}

function setBookstoreMirrorOverrides(id, overridesJson) {
  stmtMirrorSetOverrides.run(overridesJson, id);
}

module.exports = {
  init, invalidateFeedCache,
  listBookstoreFeed, getBookstoreFeedEtag, listAllBookstoreFeed,
  upsertBookstoreFeed, setBookstoreFeedEnabled, deleteBookstoreFeed,
  insertBookstoreMirror, getLatestBookstoreMirror, listRecentBookstoreMirror,
  cleanupOldBookstoreMirror, setBookstoreMirrorOverrides,
};
