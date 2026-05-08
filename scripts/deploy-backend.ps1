<#
.SYNOPSIS
  万象书屋 · 后端一键部署脚本 (Windows → Linux VPS)

.DESCRIPTION
  把当前修改过的 backend 文件打包 tar.gz, scp 到服务器, ssh 解压 + 自动跑迁移 + 重启 systemd.

  需要的文件 (跟 git status 里 backend 的修改/新增一致):
    M  backend/db.js              · 加了 events / bookstore_mirror 相关 dao
    M  backend/server.js          · 加了 /api/events、/api/bookstore/mirror 等 endpoint
    M  backend/public/admin.html  · admin 面板新加 mirror / events 监控
    M  backend/test/api.test.js   · 测试用例
    +  backend/jobs/qidianMirror.js          · 起点 mirror 抓取定时任务
    +  backend/migrations/010_events.sql     · 埋点 events 表
    +  backend/migrations/011_book_sources_idx.sql · 书源索引
    +  backend/migrations/012_bookstore_mirror.sql · mirror cache 表

.EXAMPLE
  # 完整部署 (会问 SSH 密码, 然后自动: scp + ssh 部署 + 跑迁移 + 重启 + 验证)
  .\scripts\deploy-backend.ps1

  # 仅打包不部署 (排查用)
  .\scripts\deploy-backend.ps1 -PackageOnly

  # 干跑 (打印计划但不真上传)
  .\scripts\deploy-backend.ps1 -DryRun

.PARAMETER Server
  目标 VPS IP / 域名 (默认 104.224.156.240)

.PARAMETER User
  SSH 用户名 (默认 root)

.PARAMETER RemotePath
  服务端部署目录 (默认 /opt/wanxiang)

.PARAMETER ServiceName
  systemd 服务名 (默认 wanxiang)
#>

param(
    [string]$Server = '104.224.156.240',
    [string]$User = 'root',
    [string]$RemotePath = '/opt/wanxiang/backend',
    [string]$ServiceName = 'wanxiang-backend',
    [switch]$PackageOnly,
    [switch]$DryRun,
    [switch]$RunNpmInstall  # 如果 package.json 改了就开
)

$ErrorActionPreference = 'Stop'

# 万象书屋: 全部要部署的文件 (改动 + 新增)
$DeployFiles = @(
    'backend/db.js',
    'backend/server.js',
    'backend/public/admin.html',
    'backend/test/api.test.js',
    'backend/jobs/qidianMirror.js',
    'backend/migrations/010_events.sql',
    'backend/migrations/011_book_sources_idx.sql',
    'backend/migrations/012_bookstore_mirror.sql'
)

$RepoRoot = Split-Path -Parent $PSScriptRoot
$StageDir = Join-Path $env:TEMP "wanxiang-deploy-$(Get-Date -Format yyyyMMdd-HHmmss)"
$Tarball = Join-Path $env:TEMP "wanxiang-deploy.tar.gz"

Write-Host "==> 万象书屋后端部署脚本" -ForegroundColor Cyan
Write-Host "    目标: $User@$Server`:$RemotePath" -ForegroundColor Gray
Write-Host "    repo: $RepoRoot" -ForegroundColor Gray
Write-Host ""

# 1. 检查工具
foreach ($cmd in @('tar', 'ssh', 'scp')) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        Write-Host "✗ 缺少 $cmd 命令; Windows 10/11 自带 OpenSSH + tar, 请检查 PATH" -ForegroundColor Red
        exit 1
    }
}

# 2. 校验所有文件存在
$missing = @()
foreach ($f in $DeployFiles) {
    $full = Join-Path $RepoRoot $f
    if (-not (Test-Path $full)) {
        $missing += $f
    }
}
if ($missing.Count -gt 0) {
    Write-Host "✗ 以下文件不存在, 中止部署:" -ForegroundColor Red
    $missing | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
    exit 1
}

# 3. 暂存到临时目录, 保留相对路径
Write-Host "[1/5] 暂存文件到 $StageDir" -ForegroundColor Yellow
New-Item -ItemType Directory -Path $StageDir -Force | Out-Null
foreach ($f in $DeployFiles) {
    $src = Join-Path $RepoRoot $f
    # 只保留 backend/ 下的相对路径 (不带 backend 前缀, 因为远端 RemotePath 已经是 /opt/wanxiang)
    $rel = $f -replace '^backend/', ''
    $dst = Join-Path $StageDir $rel
    $dstDir = Split-Path -Parent $dst
    if (-not (Test-Path $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
    Copy-Item $src $dst -Force
    Write-Host "    + $rel" -ForegroundColor DarkGray
}

# 4. 打包 tar.gz (Windows 10+ 自带 BSD tar)
Write-Host "[2/5] 打包 -> $Tarball" -ForegroundColor Yellow
if (Test-Path $Tarball) { Remove-Item $Tarball -Force }
Push-Location $StageDir
try {
    & tar -czf $Tarball .
    if ($LASTEXITCODE -ne 0) { throw "tar 打包失败 (exit $LASTEXITCODE)" }
} finally {
    Pop-Location
}
$size = [math]::Round((Get-Item $Tarball).Length / 1KB, 1)
Write-Host "    包大小: $size KB" -ForegroundColor Gray

if ($PackageOnly) {
    Write-Host ""
    Write-Host "✓ 仅打包模式, 包路径: $Tarball" -ForegroundColor Green
    Write-Host "  你可以手动 scp 上去:" -ForegroundColor Gray
    Write-Host "    scp '$Tarball' $User@${Server}:/tmp/" -ForegroundColor Gray
    exit 0
}

if ($DryRun) {
    Write-Host ""
    Write-Host "[DRY RUN] 不会真的上传, 以下是计划:" -ForegroundColor Magenta
    Write-Host "  - scp $Tarball $User@${Server}:/tmp/wanxiang-deploy.tar.gz" -ForegroundColor Gray
    Write-Host "  - ssh + 解压到 $RemotePath" -ForegroundColor Gray
    Write-Host "  - chown -R wanxiang:wanxiang $RemotePath" -ForegroundColor Gray
    if ($RunNpmInstall) { Write-Host "  - cd $RemotePath && npm install --omit=dev" -ForegroundColor Gray }
    Write-Host "  - systemctl restart $ServiceName" -ForegroundColor Gray
    Write-Host "  - 自动跑迁移 (server.js 启动时由 db.js runMigrations 自动检测新 *.sql)" -ForegroundColor Gray
    Write-Host "  - curl localhost:3000/api/bookstore/mirror 验证" -ForegroundColor Gray
    exit 0
}

# 5. SCP 上传
Write-Host "[3/5] 上传到 ${User}@${Server}:/tmp/wanxiang-deploy.tar.gz" -ForegroundColor Yellow
Write-Host "    (会问 SSH 密码, 输一次)" -ForegroundColor DarkGray
& scp $Tarball "${User}@${Server}:/tmp/wanxiang-deploy.tar.gz"
if ($LASTEXITCODE -ne 0) {
    Write-Host "✗ scp 失败 (exit $LASTEXITCODE). 检查网络 / 密码 / 服务器 ssh 设置." -ForegroundColor Red
    exit 1
}

# 6. SSH 远程命令: 解压 + chown + (可选 npm install) + 重启 + 验证
Write-Host "[4/5] 远程部署: 解压 + 重启 systemd" -ForegroundColor Yellow

$npmStep = if ($RunNpmInstall) {
    "cd $RemotePath && npm install --omit=dev || { echo 'npm install 失败'; exit 1; }"
} else {
    "echo '(skip npm install — 没指定 -RunNpmInstall)'"
}

$RemoteScript = @"
set -e
echo '--- backup current 部署 ---'
BACKUP=/tmp/wanxiang-backup-`$(date +%Y%m%d-%H%M%S).tar.gz
tar -czf `$BACKUP -C $RemotePath db.js server.js public/admin.html migrations jobs 2>/dev/null || true
echo "    -> `$BACKUP"

echo '--- 解压新版本到 $RemotePath ---'
mkdir -p $RemotePath/jobs $RemotePath/migrations $RemotePath/test
tar -xzf /tmp/wanxiang-deploy.tar.gz -C $RemotePath
# 万象书屋: 实测服务器 owner 是 root:root, 没 wanxiang 用户. 跳过 chown.
chmod 666 $RemotePath/db.js $RemotePath/server.js $RemotePath/public/admin.html 2>/dev/null || true
ls -lah $RemotePath/migrations/01[012]*.sql

echo '--- npm install ---'
$npmStep

echo '--- 重启 systemd ---'
systemctl restart $ServiceName
sleep 3
systemctl is-active $ServiceName || { journalctl -u $ServiceName -n 30 --no-pager; exit 1; }

echo '--- 验证 endpoint ---'
echo '> /api/sources:'; curl -fsS http://127.0.0.1:3000/api/sources -H 'X-Platform: ios' | head -c 200; echo
echo '> /api/bookstore/mirror (期望 503 没 cache 或 200 已 cache):'; curl -fsS -o /dev/null -w 'HTTP %{http_code}\n' http://127.0.0.1:3000/api/bookstore/mirror -H 'X-Device-Id: deploy-probe' || true
echo '> 最近迁移记录:'
sqlite3 $RemotePath/data/wanxiang.db "SELECT name, applied_at FROM schema_migrations ORDER BY id DESC LIMIT 5;" 2>/dev/null || echo '(sqlite3 不可用或 schema_migrations 不存在 — 旧版 db.js 第一次启动会建)'
echo '--- 部署完成 ✓ ---'
rm -f /tmp/wanxiang-deploy.tar.gz
"@

# 通过 ssh 单条 bash -s 调用, 避免转义地狱
$RemoteScript | & ssh "${User}@${Server}" "bash -s"
if ($LASTEXITCODE -ne 0) {
    Write-Host "✗ 远程部署失败 (exit $LASTEXITCODE). 看上面的 journalctl 输出排查." -ForegroundColor Red
    Write-Host "  备份包仍在服务器 /tmp/wanxiang-backup-*.tar.gz" -ForegroundColor Yellow
    exit 1
}

# 7. 本机 curl 走外网验证 (可选)
Write-Host "[5/5] 外网验证" -ForegroundColor Yellow
try {
    $sourcesResp = Invoke-WebRequest -Uri "http://$Server/api/sources" -Headers @{ 'X-Platform' = 'ios' } -TimeoutSec 8 -UseBasicParsing
    Write-Host "    /api/sources -> HTTP $($sourcesResp.StatusCode), $([math]::Round($sourcesResp.Content.Length/1KB,1)) KB" -ForegroundColor Green
} catch {
    Write-Host "    /api/sources 外网访问失败: $($_.Exception.Message) (内网 OK 即可)" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "✓ 部署成功" -ForegroundColor Green
Write-Host "  - admin 面板: http://$Server/admin (默认密码已在 .env 改过)" -ForegroundColor Gray
Write-Host "  - mirror 抓取首次会在每天 0-7 点随机时段触发; 想立刻拉, admin 面板里点'手动刷新'" -ForegroundColor Gray
Write-Host "  - 出问题查日志: ssh $User@$Server 'journalctl -u $ServiceName -n 50 --no-pager'" -ForegroundColor Gray

# 清理本地暂存
Remove-Item $StageDir -Recurse -Force -ErrorAction SilentlyContinue
