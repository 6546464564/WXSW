// 万象书屋: OpenAPI 3.0 文档.
// 不用 swagger-jsdoc 在每个路由加 @swagger 注释 — 太冗余, 用集中定义.
// 启动后访问 http://localhost:3000/api/docs 看交互式文档.
'use strict';

const swaggerSpec = {
  openapi: '3.0.0',
  info: {
    title: '万象书屋后端 API',
    version: '2.0.0',
    description: '阅读 App 后端: 书源管理 + 广告控制 + 用户运营 + 监控',
    license: { name: 'GPL-3.0' }
  },
  servers: [
    { url: 'http://localhost:3000', description: '本地开发' },
    { url: 'https://your-domain.com', description: '生产环境 (改成你的)' }
  ],
  tags: [
    { name: 'health', description: '健康检查与监控' },
    { name: 'public', description: 'App 客户端公开接口 (匿名)' },
    { name: 'device', description: '设备注册与 token' },
    { name: 'admin-auth', description: '管理员登录' },
    { name: 'admin-sources', description: '书源管理' },
    { name: 'admin-ad', description: '广告配置 (含灰度发布)' },
    { name: 'admin-ops', description: '运维: 备份/熔断/告警' },
    { name: 'pipl', description: 'PIPL 合规接口' }
  ],
  components: {
    securitySchemes: {
      cookieAuth: { type: 'apiKey', in: 'cookie', name: 'adm' },
      deviceAuth: {
        type: 'apiKey', in: 'header', name: 'X-Device-Token',
        description: 'HMAC token from POST /api/device/register'
      }
    },
    schemas: {
      Health: {
        type: 'object',
        properties: {
          ok: { type: 'boolean' },
          checks: {
            type: 'object',
            properties: {
              db: { type: 'object', properties: { ok: { type: 'boolean' }, latency_ms: { type: 'number' } } },
              mem: { type: 'object' },
              disk: { type: 'object' },
              uptime_s: { type: 'integer' }
            }
          }
        }
      },
      AdConfig: {
        type: 'object',
        properties: {
          version: { type: 'integer' },
          etag: { type: 'string' },
          config: {
            type: 'object',
            properties: {
              disabled: { type: 'boolean' },
              placements: { type: 'object' },
              chapterUnlock: { type: 'object' }
            }
          }
        }
      }
    }
  },
  paths: {
    '/api/health': {
      get: {
        tags: ['health'], summary: '分级健康检查',
        description: '返回 200 表示完全健康, 503 表示某依赖异常 (但仍可对外服务)',
        responses: {
          '200': { description: 'OK', content: { 'application/json': { schema: { $ref: '#/components/schemas/Health' } } } },
          '503': { description: 'Degraded' }
        }
      }
    },
    '/metrics': {
      get: {
        tags: ['health'], summary: 'Prometheus 文本格式指标',
        responses: { '200': { description: 'plaintext metrics' } }
      }
    },
    '/api/sources': {
      get: {
        tags: ['public'], summary: '获取启用书源列表',
        parameters: [
          { name: 'X-Device-Id', in: 'header', schema: { type: 'string' } },
          { name: 'X-Device-Token', in: 'header', schema: { type: 'string' } }
        ],
        responses: {
          '200': { description: 'JSON array' },
          '304': { description: 'Not Modified (etag match)' },
          '401': { description: 'device token invalid' }
        }
      }
    },
    '/api/announcement': {
      get: {
        tags: ['public'], summary: '获取生效公告',
        parameters: [{ name: 'versionCode', in: 'query', schema: { type: 'integer' } }],
        responses: { '200': { description: 'list' } }
      }
    },
    '/api/ad-config': {
      get: {
        tags: ['public'], summary: '获取广告配置 (含灰度选版本)',
        parameters: [
          { name: 'X-Device-Id', in: 'header', schema: { type: 'string' },
            description: 'device_id 决定灰度命中, 不传则总返回主版本' }
        ],
        responses: {
          '200': { description: 'config envelope', content: { 'application/json': { schema: { $ref: '#/components/schemas/AdConfig' } } } },
          '304': { description: 'Not Modified' }
        }
      }
    },
    '/api/ping': {
      post: {
        tags: ['public'], summary: 'App 心跳上报',
        security: [{ deviceAuth: [] }],
        requestBody: {
          required: true,
          content: { 'application/json': { schema: { type: 'object', properties: { device_id: { type: 'string' } } } } }
        },
        responses: { '200': { description: 'ok' } }
      }
    },
    '/api/device/register': {
      post: {
        tags: ['device'], summary: '设备首次注册, 获得 HMAC token',
        requestBody: {
          required: true,
          content: { 'application/json': { schema: { type: 'object', required: ['device_id'], properties: { device_id: { type: 'string' } } } } }
        },
        responses: {
          '200': { description: 'token issued', content: { 'application/json': { schema: { type: 'object', properties: { ok: { type: 'boolean' }, token: { type: 'string' }, install_ts: { type: 'integer' } } } } } },
          '409': { description: 'already registered' }
        }
      }
    },
    '/api/me/wipe-data': {
      delete: {
        tags: ['pipl'], summary: 'PIPL 用户数据清空 (账号注销时调)',
        security: [{ deviceAuth: [] }],
        responses: {
          '200': { description: 'wiped', content: { 'application/json': { schema: { type: 'object', properties: { ok: { type: 'boolean' }, deleted: { type: 'object' } } } } } },
          '401': { description: 'token invalid' }
        }
      }
    },
    '/api/admin/login': {
      post: {
        tags: ['admin-auth'], summary: '管理员登录 (5 分钟 5 次失败锁 30 分钟)',
        requestBody: { required: true, content: { 'application/json': { schema: { type: 'object', properties: { username: { type: 'string' }, password: { type: 'string' }, totp: { type: 'string' } } } } } },
        responses: {
          '200': { description: 'success, sets adm cookie' },
          '401': { description: 'wrong credentials' },
          '423': { description: 'account locked' },
          '429': { description: 'rate limited' }
        }
      }
    },
    '/api/admin/ad-config/staging': {
      put: {
        tags: ['admin-ad'], summary: '设置灰度版本',
        security: [{ cookieAuth: [] }],
        requestBody: { required: true, content: { 'application/json': { schema: { type: 'object', properties: { config: { type: 'object' }, rolloutPct: { type: 'integer' } } } } } },
        responses: { '200': { description: 'staged' } }
      }
    },
    '/api/admin/ad-config/staging/commit': {
      post: {
        tags: ['admin-ad'], summary: '灰度晋升: staging → 主版本',
        security: [{ cookieAuth: [] }],
        responses: { '200': { description: 'ok' } }
      }
    },
    '/api/admin/backup/now': {
      post: {
        tags: ['admin-ops'], summary: '立即触发一次备份',
        security: [{ cookieAuth: [] }],
        responses: { '200': { description: 'backup triggered' } }
      }
    },
    '/api/admin/breaker/reset': {
      post: {
        tags: ['admin-ops'], summary: '清空广告熔断状态 + suppress N 分钟',
        security: [{ cookieAuth: [] }],
        parameters: [{ name: 'minutes', in: 'query', schema: { type: 'integer' } }],
        responses: { '200': { description: 'reset' } }
      }
    }
  }
};

module.exports = swaggerSpec;
