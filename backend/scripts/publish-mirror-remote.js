#!/usr/bin/env node
// 万象书屋: 本地抓 mirror (含 ranksFemale) → POST 到线上 admin publish 接口.
// 用法: BACKEND_URL=https://wxsw.app ADMIN_PASSWORD=xxx node scripts/publish-mirror-remote.js

const qidianMirror = require('../jobs/qidianMirror');

const BASE = process.env.BACKEND_URL || 'https://wxsw.app';
const PASSWORD = process.env.ADMIN_PASSWORD || process.env.ADMIN_PWD;

async function main() {
  if (!PASSWORD) {
    console.error('需要环境变量 ADMIN_PASSWORD');
    process.exit(1);
  }

  console.log('>>> 本地抓取 mirror (含女频)...');
  const payload = await qidianMirror.fetchMirrorPayload();
  const male = Object.values(payload.ranks || {}).reduce((s, a) => s + a.length, 0);
  const female = payload.ranksFemale
    ? Object.values(payload.ranksFemale).reduce((s, a) => s + a.length, 0)
    : 0;
  console.log(`    男生 ${male} 本, 女生 ${female} 本, 月票50 ${payload.yuepiaoTop50?.length}, 女月票50 ${payload.yuepiaoTop50Female?.length}`);
  const publish = payload.ranksPublish
    ? Object.values(payload.ranksPublish).reduce((s, a) => s + a.length, 0)
    : 0;
  console.log(`    出版 ${publish} 本 (四榜), 出版月票50 ${payload.yuepiaoTop50Publish?.length ?? 0}`);

  const validation = qidianMirror.validateMirrorPayload(payload);
  if (!validation.ok) {
    console.error('>>> mirror 校验失败, 拒绝上传:');
    validation.errors.forEach((e) => console.error(`    - ${e}`));
    process.exit(1);
  }

  console.log(`>>> 登录 ${BASE}...`);
  const loginRes = await fetch(`${BASE}/api/admin/login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ password: PASSWORD }),
  });
  const loginBody = await loginRes.json();
  if (!loginRes.ok || !loginBody.ok) {
    throw new Error(`login failed: ${JSON.stringify(loginBody)}`);
  }
  const cookie = loginRes.headers.getSetCookie?.()?.join('; ') || '';
  if (!cookie) throw new Error('login ok but no Set-Cookie');

  console.log('>>> 上传 mirror payload...');
  const pubRes = await fetch(`${BASE}/api/admin/bookstore-mirror/publish`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Cookie: cookie },
    body: JSON.stringify(payload),
  });
  const pubBody = await pubRes.json().catch(() => ({}));
  if (!pubRes.ok) {
    throw new Error(`publish failed (${pubRes.status}): ${JSON.stringify(pubBody)}`);
  }
  console.log('>>> 完成:', pubBody);
}

main().catch((e) => {
  console.error('ERR:', e.message);
  process.exit(1);
});
