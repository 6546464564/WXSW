/**
 * 一次性脚本: 把真实广告位 ID 写入数据库 ad_config 表.
 * 用法: cd backend && node scripts/seed-ad-config.js
 */
const db = require('../db');
const { saveAdConfig } = require('../models/adConfig');

const config = {
  disabled: false,
  primary: 'csj',
  sdk: {
    csj: { appId: '', androidAppId: '5822340', iosAppId: '5825810' },
    ylh: { appId: '', androidAppId: '1217143733', iosAppId: '1217620900' }
  },
  placements: {
    splash: {
      enabled: true,
      timeoutMs: 3000,
      soloProvider: '',
      providers: [
        { name: 'csj', weight: 80, posId: '', androidPosId: '980622522', iosPosId: '981264244' },
        { name: 'ylh', weight: 20, posId: '', androidPosId: '7300219291644321', iosPosId: '4300170851839651' }
      ]
    },
    rewardedReadingUnlock: {
      enabled: true,
      unlockMinutes: 30,
      cooldownMinutes: 30,
      cooldownSec: 180,
      maxAccumulatedMinutes: 1440,
      showCountdownBar: true,
      soloProvider: '',
      providers: [
        { name: 'csj', weight: 80, posId: '', androidPosId: '980622521', iosPosId: '981263226' },
        { name: 'ylh', weight: 20, posId: '', androidPosId: '5330818271549483', iosPosId: '3310279811340675' }
      ]
    }
  },
  pollIntervalSec: 21600,
  chapterUnlock: {
    enabled: false,
    freeChapters: 3,
    unlockMinutes: 30,
    blockOnSkip: true
  }
};

try {
  const result = saveAdConfig(config);
  console.log('✅ ad-config saved:', result);
  console.log('   CSJ appId: 5825810');
  console.log('   YLH appId: 1217620900');
  console.log('   splash.csj: 981264244 (新插屏当开屏)');
  console.log('   rewarded.csj: 981263226');
  console.log('   splash.ylh: 4300170851839651');
  console.log('   rewarded.ylh: 3310279811340675');
} catch (e) {
  console.error('❌ failed:', e.message);
  process.exit(1);
}
