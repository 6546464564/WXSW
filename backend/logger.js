// 万象书屋: 轻量结构化日志器 (不引 pino 依赖, 省安装步骤)
// 输出单行 JSON 到 stdout/stderr, 运维层可用 logrotate / journalctl / docker logs 聚合.
// 将来想换 pino / winston 很容易, 接口形似.

const LEVELS = { debug: 10, info: 20, warn: 30, error: 40 };
const LEVEL = (process.env.LOG_LEVEL || 'info').toLowerCase();
const MIN = LEVELS[LEVEL] || LEVELS.info;

// 万象书屋: 防止 meta 字段 (用户传的) 覆盖核心 t/l/m 字段, 这会破坏日志解析.
// 同名 key 时把 meta 的值搬到 _key 命名空间.
const RESERVED_KEYS = new Set(['t', 'l', 'm']);

function emit(level, msg, meta) {
  if (LEVELS[level] < MIN) return;
  const line = {
    t: new Date().toISOString(),
    l: level,
    m: typeof msg === 'string' ? msg : JSON.stringify(msg),
  };
  if (meta && typeof meta === 'object') {
    for (const k of Object.keys(meta)) {
      if (RESERVED_KEYS.has(k)) {
        line['_' + k] = meta[k];  // 例如 logger.info('x', { m: 'y' }) → { t, l, m: 'x', _m: 'y' }
      } else {
        line[k] = meta[k];
      }
    }
  }
  const stream = level === 'error' ? process.stderr : process.stdout;
  try {
    stream.write(JSON.stringify(line) + '\n');
  } catch {
    // 序列化失败 (循环引用等), 降级
    stream.write(`{"t":"${line.t}","l":"${level}","m":"log-serialize-fail"}\n`);
  }
}

module.exports = {
  debug: (m, meta) => emit('debug', m, meta),
  info:  (m, meta) => emit('info', m, meta),
  warn:  (m, meta) => emit('warn', m, meta),
  error: (m, meta) => emit('error', m, meta),
  /**
   * Express 访问日志中间件. 在响应结束时输出一行, 包含 method/url/status/ms/ip/ua.
   * 避免给心跳 / 健康检查 这种高频 + 无用的信息刷屏.
   */
  httpAccess() {
    const skipPaths = new Set(['/api/health']);
    return (req, res, next) => {
      const start = Date.now();
      res.on('finish', () => {
        if (skipPaths.has(req.path)) return;
        emit('info', 'http', {
          method: req.method,
          path: req.path,
          status: res.statusCode,
          ms: Date.now() - start,
          ip: req.ip,
          ua: (req.get('User-Agent') || '').slice(0, 120),
        });
      });
      next();
    };
  },
};
