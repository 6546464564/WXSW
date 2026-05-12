// 万象书屋: iOS IAP 票据

let db;
let stmtUpsertIapReceipt;

function init(database) {
  db = database;
  stmtUpsertIapReceipt = db.prepare(
    `INSERT INTO iap_receipts(
       device_id, product_id, transaction_id, original_tx_id,
       receipt_data, expires_at, verified_at, sandbox, status, raw_response
     ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT(transaction_id) DO UPDATE SET
       receipt_data = excluded.receipt_data,
       expires_at   = excluded.expires_at,
       verified_at  = excluded.verified_at,
       status       = excluded.status,
       raw_response = excluded.raw_response`
  );
}

function saveIapReceipt({
  deviceId, productId, transactionId, originalTxId,
  receiptData, expiresAt, sandbox, status, rawResponse,
}) {
  if (!deviceId || !productId || !transactionId || !receiptData) {
    throw new Error('deviceId / productId / transactionId / receiptData required');
  }
  stmtUpsertIapReceipt.run(
    String(deviceId).slice(0, 128),
    String(productId).slice(0, 100),
    String(transactionId).slice(0, 100),
    originalTxId ? String(originalTxId).slice(0, 100) : null,
    String(receiptData).slice(0, 50000),
    expiresAt != null ? Number(expiresAt) : null,
    Date.now(),
    sandbox ? 1 : 0,
    status || 'active',
    rawResponse ? String(rawResponse).slice(0, 50000) : null,
  );
}

function listActiveIapForDevice(deviceId) {
  if (!deviceId) return [];
  const now = Date.now();
  return db.prepare(`
    SELECT product_id, transaction_id, expires_at, verified_at, status, sandbox
    FROM iap_receipts
    WHERE device_id = ?
      AND status = 'active'
      AND (expires_at IS NULL OR expires_at > ?)
  `).all(String(deviceId), now);
}

function setIapStatus(transactionId, status) {
  const allowed = new Set(['active', 'expired', 'refunded', 'revoked']);
  if (!allowed.has(status)) throw new Error('invalid iap status');
  db.prepare('UPDATE iap_receipts SET status = ? WHERE transaction_id = ?')
    .run(status, String(transactionId));
}

module.exports = { init, saveIapReceipt, listActiveIapForDevice, setIapStatus };
