/**
 * 万象书屋 RN · 书籍信息格式化工具
 * 对齐 iOS: BookDetailView.cleanedIntro / formatWordCount
 */

/**
 * 字数格式化: "5769700" → "576.97万字"
 */
export function formatWordCount(raw?: string): string | undefined {
  if (!raw) return undefined;
  if (raw.includes('万') || raw.includes('字')) return raw;
  const num = parseFloat(raw.trim());
  if (isNaN(num) || num <= 0) return raw;
  if (num >= 10000) {
    return (num / 10000).toFixed(2) + '万字';
  }
  return Math.floor(num) + '字';
}

const UPDATE_EMOJIS = ['🔔', '🧑', '🕐', '⏰'];
const UPDATE_PREFIXES = UPDATE_EMOJIS.flatMap(e => [
  `${e} 更新：`, `${e}更新：`, `${e} 更新:`, `${e}更新:`,
  `${e} 更新: `, `${e}更新: `,
]);
const INTRO_PREFIXES = [
  '📜 简介：', '📜简介：', '📖 简介：', '📖简介：',
  '📜 简介:', '📖 简介:',
  '📝 简介：', '📝简介：', '📝 简介:', '📝简介:',
];
const CUT_EMOJIS = ['📌', '🔧', '⚙', '💫', '🔮', '❤️'];

interface CleanedIntro {
  text: string;
  updateTime?: string;
}

/**
 * 清理简介: 去掉 emoji 前缀、元数据、尾部路由信息，提取嵌入的更新时间
 */
export function cleanIntro(raw?: string): CleanedIntro {
  if (!raw) return {text: ''};
  let lines = raw.split('\n');
  let extractedTime: string | undefined;

  // 提取嵌入的更新时间行
  const updateIdx = lines.findIndex(line => {
    const t = line.trim();
    return UPDATE_EMOJIS.some(e => t.startsWith(e)) && t.includes('更新');
  });
  if (updateIdx >= 0) {
    const line = lines[updateIdx].trim();
    for (const prefix of UPDATE_PREFIXES) {
      if (line.startsWith(prefix)) {
        extractedTime = line.slice(prefix.length).trim();
        break;
      }
    }
    lines.splice(updateIdx, 1);
  }

  // 去掉零宽字符行
  lines = lines.filter(l => {
    const t = l.trim();
    return t !== '\u200B' && t !== '\uFEFF';
  });

  // 截断尾部路由/元数据 (📌 开头及以后全部去掉)
  const cutIdx = lines.findIndex(l =>
    CUT_EMOJIS.some(e => l.trim().startsWith(e)),
  );
  if (cutIdx >= 0) {
    lines = lines.slice(0, cutIdx);
  }

  // 去掉简介前缀 emoji
  lines = lines.map(line => {
    let s = line;
    for (const prefix of INTRO_PREFIXES) {
      if (s.startsWith(prefix)) {
        s = s.slice(prefix.length);
        break;
      }
    }
    return s;
  });

  const text = lines
    .join('\n')
    .replace(/<br\s*\/?>/gi, '')
    .replace(/<[^>]+>/g, '')
    .trim();

  return {text, updateTime: extractedTime};
}
