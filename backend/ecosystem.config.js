// 万象书屋: pm2 配置 (Docker 不可用时的备选方案)
//
// 用法:
//   npm install -g pm2
//   pm2 start ecosystem.config.js
//   pm2 save                          # 保存进程列表
//   pm2 startup                       # 生成开机自启脚本 (按提示 sudo 执行)
//   pm2 reload wanxiang-backend       # 零停机重启 (升级代码后)
//   pm2 logs wanxiang-backend         # 看日志

module.exports = {
  apps: [
    {
      name: 'wanxiang-backend',
      script: './server.js',
      node_args: '--experimental-require-module',
      instances: 1,                  // SQLite 单 writer, 不能多实例
      exec_mode: 'fork',
      autorestart: true,
      watch: false,
      max_memory_restart: '500M',    // 内存超 500M 自动重启 (防泄露)
      kill_timeout: 5000,            // SIGTERM 后 5s 还没退就 SIGKILL
      env: {
        NODE_ENV: 'production',
        PORT: 3000,
        LOG_LEVEL: 'info'
      },
      error_file: './logs/err.log',
      out_file: './logs/out.log',
      log_date_format: 'YYYY-MM-DD HH:mm:ss',
      merge_logs: true,
      // 健康检查 (pm2 plus 收费功能, 自建用 cron 调 /api/health)
      exp_backoff_restart_delay: 100, // 频繁崩溃时退避重启
      max_restarts: 10                // 1 分钟内最多重启 10 次, 否则 stop
    }
  ]
};
