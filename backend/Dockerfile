# 万象书屋后端 Docker 镜像
# 构建: docker build -t wanxiang-backend:latest .
# 运行: docker run -d -p 3000:3000 -v $(pwd)/data:/app/data wanxiang-backend:latest

FROM node:22-alpine

# 安装 build deps (better-sqlite3 需要 native build)
RUN apk add --no-cache python3 make g++ tini && \
    ln -sf python3 /usr/bin/python

WORKDIR /app

# 先 copy package*.json 利用 docker layer 缓存
COPY package*.json ./
RUN npm ci --omit=dev --no-audit --no-fund

# 拷贝源码
COPY . .

# 数据目录 (容器内固定路径, 通过 volume 挂载持久化)
RUN mkdir -p /app/data && chown -R node:node /app

# 不用 root 跑 (node 镜像自带 node 用户, uid=1000)
USER node

ENV NODE_ENV=production \
    PORT=3000 \
    DB_PATH=/app/data/wanxiang.db \
    LOG_LEVEL=info

EXPOSE 3000

# tini 作为 PID 1 转发信号, 让 SIGTERM 能正常 graceful shutdown
ENTRYPOINT ["/sbin/tini", "--"]

# 健康检查 (每 30s 一次, 失败 3 次视为不健康)
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget -qO- http://localhost:3000/api/health || exit 1

CMD ["node", "server.js"]
