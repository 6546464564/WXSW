// 万象书屋: 书城 mirror cache

let db;
let stmtMirrorInsert, stmtMirrorLatestOk, stmtMirrorRecent,
    stmtMirrorCleanup, stmtMirrorSetOverrides;

function init(database) {
  db = database;

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

function insertBookstoreMirror({ version, payload, etag, fetched_at, source, ok, err_msg }) {
  stmtMirrorInsert.run(version, payload, etag, fetched_at, source, ok ? 1 : 0, err_msg || null);
}

function getLatestBookstoreMirror() {
  return stmtMirrorLatestOk.get() || null;
}

function listRecentBookstoreMirror(limit = 3) {
  return stmtMirrorRecent.all(limit);
}

function cleanupOldBookstoreMirror(keepCount = 3) {
  stmtMirrorCleanup.run(keepCount);
}

function setBookstoreMirrorOverrides(id, overridesJson) {
  stmtMirrorSetOverrides.run(overridesJson, id);
}

module.exports = {
  init,
  insertBookstoreMirror, getLatestBookstoreMirror, listRecentBookstoreMirror,
  cleanupOldBookstoreMirror, setBookstoreMirrorOverrides,
};
