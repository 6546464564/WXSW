const TIPS: Record<number, {title: string; body: string; plants: string[]}> = {
  1: {title: '一月 · 静观冬态', body: '落叶树看枝形与芽点，常绿看叶色与耐寒表现。', plants: ['山茶', '孝顺竹']},
  2: {title: '二月 · 早花留意', body: '留意早花与新芽，记录花苞膨大过程。', plants: ['山茶', '紫藤']},
  3: {title: '三月 · 萌芽季', body: '新叶展开速度快，适合连续记录同一株的变化。', plants: ['银杏', '三叶草']},
  4: {title: '四月 · 春叶正盛', body: '嫩叶颜色最鲜明，可对比不同生境的同种植物。', plants: ['蒲公英', '绿萝']},
  5: {title: '五月 · 野外好时节', body: '野外与公园草本增多，注意记录生境与群落。', plants: ['三叶草', '肾蕨']},
  6: {title: '六月 · 阳台观察', body: '夏季适合记录阳台盆栽的浇水与叶色变化。', plants: ['薄荷', '芦荟']},
  7: {title: '七月 · 观叶为主', body: '多数植物进入旺盛生长期，记录叶形与株型即可。', plants: ['景天科多肉', '绿萝']},
  8: {title: '八月 · 耐暑记录', body: '留意高温下叶缘焦枯、颜色转深等应激表现。', plants: ['孝顺竹', '薄荷']},
  9: {title: '九月 · 转色前夕', body: '部分树种开始转色，可建立秋季观察基线。', plants: ['银杏', '桂花']},
  10: {title: '十月 · 赏桂时节', body: '桂花盛开，记录香气强弱与花量变化。', plants: ['桂花', '银杏']},
  11: {title: '十一月 · 秋色正浓', body: '落叶变色高峰期，同种不同地点颜色可能差异很大。', plants: ['银杏', '三叶草']},
  12: {title: '十二月 · 年终回顾', body: '整理全年记录，看看哪些植物观察次数最多。', plants: ['山茶', '景天科多肉']},
};

export function getSeasonTip() {
  const month = new Date().getMonth() + 1;
  return TIPS[month];
}
