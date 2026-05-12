// 万象书屋: 告警规则扫描器

const logger = require('../logger');

function startAlertScanner(db) {
  async function evaluateAlertRule(rule) {
    const since = Date.now() - rule.window_min * 60_000;
    switch (rule.kind) {
      case 'crash_burst': {
        const c = db.__db.prepare('SELECT COUNT(*) AS c FROM crashes WHERE ts >= ?').get(since).c;
        return c >= rule.threshold ? { metric: 'crashes', value: c } : null;
      }
      case 'ad_error_rate': {
        const r = db.__db.prepare(
          `SELECT
              SUM(CASE WHEN type='error' THEN 1 ELSE 0 END) AS errs,
              SUM(CASE WHEN type IN ('load','error') THEN 1 ELSE 0 END) AS total
           FROM ad_events WHERE ts >= ?`
        ).get(since);
        if ((r.total || 0) < 20) return null;
        const rate = r.errs / r.total;
        return rate >= rule.threshold ? { metric: 'errorRate', value: rate, errs: r.errs, total: r.total } : null;
      }
      case 'heartbeat_drop': {
        const cur = db.__db.prepare('SELECT COUNT(*) AS c FROM heartbeats WHERE ts >= ?').get(since).c;
        const prevSince = since - rule.window_min * 60_000;
        const prev = db.__db.prepare('SELECT COUNT(*) AS c FROM heartbeats WHERE ts >= ? AND ts < ?').get(prevSince, since).c;
        if (prev < 50) return null;
        const drop = (prev - cur) / prev;
        return drop >= rule.threshold ? { metric: 'heartbeatDrop', value: drop, prev, cur } : null;
      }
      default:
        return null;
    }
  }

  async function sendAlert(rule, info) {
    const msg = `🚨 [万象书屋] ${rule.name}\n` +
      `规则: ${rule.kind} · 阈值 ${rule.threshold} · ${rule.window_min}min 窗口\n` +
      `命中: ${JSON.stringify(info)}\n` +
      `时间: ${new Date().toISOString()}`;
    let body;
    if (rule.webhook_kind === 'wecom') {
      body = JSON.stringify({ msgtype: 'text', text: { content: msg } });
    } else if (rule.webhook_kind === 'dingtalk') {
      body = JSON.stringify({ msgtype: 'text', text: { content: msg } });
    } else {
      body = JSON.stringify({ name: rule.name, kind: rule.kind, info, msg });
    }
    try {
      const ctrl = new AbortController();
      const timer = setTimeout(() => ctrl.abort(), 5000);
      const resp = await fetch(rule.webhook_url, {
        method: 'POST', headers: { 'Content-Type': 'application/json' }, body, signal: ctrl.signal,
      });
      clearTimeout(timer);
      logger.info('alert fired', { id: rule.id, name: rule.name, status: resp.status });
    } catch (e) {
      logger.warn('alert send failed', { id: rule.id, msg: e.message });
    }
  }

  async function scan() {
    let rules = [];
    try { rules = db.listAlertRules(); } catch { return; }
    const now = Date.now();
    for (const r of rules) {
      if (!r.enabled) continue;
      if (r.last_fired_at && now - r.last_fired_at < r.cooldown_min * 60_000) continue;
      try {
        const triggered = await evaluateAlertRule(r);
        if (triggered) {
          await sendAlert(r, triggered);
          db.markAlertFired(r.id);
        }
      } catch (e) {
        logger.warn('alert scan failed', { id: r.id, msg: e.message });
      }
    }
  }

  setInterval(scan, 5 * 60_000).unref?.();
  setTimeout(scan, 30_000).unref?.();
}

module.exports = { startAlertScanner };
