# ============================================================
# 万象书屋: Windows -> Mac 一键迁移打包
# ============================================================
#
# 用途: 把 Windows 上的 万象书屋 项目所有相关资产, 打成 4 个 zip 放到桌面,
#       拷到 Mac 上解压即可继续开发.
#
# 输出:
#   ~/Desktop/wxsw-mac-migration/
#     |- README.md             (Mac 上开机指引)
#     |- code-snapshot.zip     (项目代码, 排除 build/缓存/二进制工具)
#     |- secrets.zip           (签名 key + .env, 单独加密提示)
#     |- cursor-history.zip    (Cursor 聊天历史)
#     |- SHA256SUMS.txt        (3 个 zip 的 sha256 校验和)
#
# 用法:
#   PowerShell 进项目根, 直接跑:
#     .\scripts\migrate-to-mac.ps1
#
#   PowerShell 执行策略问题, 用:
#     powershell -ExecutionPolicy Bypass -File .\scripts\migrate-to-mac.ps1
# ============================================================

[CmdletBinding()]
param(
    [string]$ProjectRoot = "",
    [string]$OutDir = "$env:USERPROFILE\Desktop\wxsw-mac-migration"
)

$ErrorActionPreference = 'Stop'

# 万象书屋: $PSScriptRoot 在中文路径 / -File 启动场景下偶尔为空, 多重兜底
if (-not $ProjectRoot) {
    $scriptDir = $PSScriptRoot
    if (-not $scriptDir -and $MyInvocation.MyCommand.Path) {
        $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    }
    if (-not $scriptDir) {
        $scriptDir = Get-Location
    }
    $ProjectRoot = Split-Path -Parent $scriptDir
}
$ProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).ProviderPath
$Host.UI.RawUI.WindowTitle = "万象书屋 -> Mac 迁移打包"

function Write-Step($msg) {
    Write-Host ""
    Write-Host "==> $msg" -ForegroundColor Cyan
}
function Write-Ok($msg) {
    Write-Host "    [OK] $msg" -ForegroundColor Green
}
function Write-Warn($msg) {
    Write-Host "    [!]  $msg" -ForegroundColor Yellow
}
function Format-Size($bytes) {
    if ($bytes -lt 1KB)        { return "$bytes B" }
    elseif ($bytes -lt 1MB)    { return ("{0:N1} KB" -f ($bytes / 1KB)) }
    elseif ($bytes -lt 1GB)    { return ("{0:N1} MB" -f ($bytes / 1MB)) }
    else                       { return ("{0:N2} GB" -f ($bytes / 1GB)) }
}

# ============================================================
# 0. 准备
# ============================================================
Write-Step "0. 准备输出目录"
Write-Host "    项目路径: $ProjectRoot"
Write-Host "    输出路径: $OutDir"

if (-not (Test-Path $ProjectRoot)) {
    Write-Error "项目路径不存在: $ProjectRoot"
    exit 1
}

if (Test-Path $OutDir) {
    Write-Warn "输出目录已存在, 将清空"
    Remove-Item $OutDir -Recurse -Force
}
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

# 临时目录 (打包前先 stage 到这里)
$stage = Join-Path $env:TEMP "wxsw-migrate-stage-$(Get-Random)"
New-Item -ItemType Directory -Path $stage -Force | Out-Null
$cleanupStage = { if (Test-Path $stage) { Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue } }

try {

    # ============================================================
    # 1. 项目代码 -> code-snapshot.zip
    # ============================================================
    Write-Step "1. 收集项目代码 (排除 build / 缓存 / Windows 二进制工具)"

    # robocopy 比 Compress-Archive 快很多, 而且支持 /XD 排除目录
    $codeStage = Join-Path $stage "WXSW"
    New-Item -ItemType Directory -Path $codeStage -Force | Out-Null

    # 要排除的目录: robocopy /XD 给"目录名"(不是绝对路径)时会匹配任意层级同名目录,
    # 这样 modules\book\build 这种子模块产物也会被一并排除.
    $excludeDirNames = @(
        # ---- Gradle / Android Studio 产物 ----
        "build",                                     # Gradle 所有模块的产物 (通用)
        ".gradle",                                   # Gradle 缓存
        ".idea",                                     # IntelliJ 配置
        ".cxx",                                      # NDK 缓存
        ".transforms",                               # Gradle transforms 缓存
        "intermediates",                             # AGP 中间产物
        ".kotlin",                                   # Kotlin 增量编译缓存
        # ---- Node ----
        "node_modules",                              # Node 依赖 (后端 + 任意 npm 子项)
        "node-v22.14.0-win-x64",                     # Windows 二进制 node, Mac 用 brew
        "node-v22.22.2-win-x64",                     # backend/.tools 下的同款
        # ---- 临时 / 缓存 / 测试产物 ----
        "tmp",
        ".tmp",
        "test_full",                                 # UI 测试 dump (132 MB)
        "test_screens",                              # UI 截图归档 (100 MB)
        "release-test",
        # ---- 第三方 SDK 官方 demo (参考资料, Mac 不需要) ----
        "csj_demo",                                  # 穿山甲 demo 工程 100 MB
        "ylh"                                        # 优量汇 demo 18 MB
    )
    # 也保留几个绝对路径的精确排除 (防误伤同名目录):
    $excludeDirAbs = @(
        "backend\data"                               # 本地 SQLite 数据 (服务器上有真实数据)
    )
    # 要排除的文件 (按名字, 任意层级匹配)
    $excludeFiles = @(
        # ---- 临时 / 日志 ----
        "*.log",
        "*.tmp",
        "local.properties",                          # Android SDK 本地路径, Mac 上要重新生成
        # ---- 本地 DB ----
        "*.db",
        "*.db-shm",
        "*.db-wal",
        # ---- 旧 APK / AAB (Mac 编译会重新出) ----
        "*.apk",
        "*.aab",
        # ---- Windows 二进制 (Mac 跑不了, brew 装替代) ----
        "*.exe",
        "*.dll",
        "*.msi",
        "node-win-x64.zip",                          # node 安装包
        # ---- macOS 系统垃圾 (拷过去会自动产生, 但提前清理) ----
        ".DS_Store",
        "Thumbs.db",
        "desktop.ini"
    )
    # 敏感文件单独打 (这里排除, 第 2 步处理)
    $secretFiles = @(
        "app\release.keystore",
        "app\debug.keystore",
        "backend\.env",
        ".env"
    )

    # 用 robocopy 复制, /MIR 镜像 + /XD 排除目录 + /XF 排除文件
    $rcArgs = @(
        $ProjectRoot,
        $codeStage,
        "/MIR",
        "/NFL", "/NDL", "/NJH", "/NJS", "/NC", "/NS", "/NP",  # 安静模式
        "/MT:8",
        "/R:1", "/W:1"
    )
    # 目录名 (任意层级匹配) — robocopy 文档: /XD 后给纯名字会匹配任意路径下的同名目录
    foreach ($d in $excludeDirNames) { $rcArgs += "/XD"; $rcArgs += $d }
    # 绝对路径精确排除
    foreach ($d in $excludeDirAbs)   { $rcArgs += "/XD"; $rcArgs += (Join-Path $ProjectRoot $d) }
    foreach ($f in $excludeFiles)    { $rcArgs += "/XF"; $rcArgs += $f }
    foreach ($f in $secretFiles)     { $rcArgs += "/XF"; $rcArgs += (Join-Path $ProjectRoot $f) }

    Write-Host "    robocopy 复制中..."
    & robocopy @rcArgs | Out-Null
    # robocopy 退出码 0/1/2 都是成功 (1=有文件复制, 2=额外文件被检测)
    $rc = $LASTEXITCODE
    if ($rc -ge 8) {
        throw "robocopy 失败, exit code = $rc"
    }

    $codeSize = (Get-ChildItem $codeStage -Recurse -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
    Write-Ok "stage 大小: $(Format-Size $codeSize)"

    # 压缩 — 用 tar.exe (Win10+ 内置 BSD libarchive), 比 Compress-Archive 快, 不受 MAX_PATH 限制,
    # Mac 端 tar xzf 直接解开, 也支持 unzip 解 .zip 但 .tar.gz 跨平台更稳.
    $codeZip = Join-Path $OutDir "code-snapshot.tar.gz"
    Write-Host "    压缩中 (tar.exe, 1-3 分钟)..."
    $stageParent = Split-Path -Parent $codeStage
    $stageLeaf   = Split-Path -Leaf   $codeStage
    Push-Location $stageParent
    try {
        & tar.exe -czf $codeZip $stageLeaf
        if ($LASTEXITCODE -ne 0) { throw "tar 失败, exit code = $LASTEXITCODE" }
    } finally { Pop-Location }
    $codeZipSize = (Get-Item $codeZip).Length
    Write-Ok "code-snapshot.tar.gz = $(Format-Size $codeZipSize)"

    # ============================================================
    # 2. 敏感文件 -> secrets.zip
    # ============================================================
    Write-Step "2. 收集敏感文件 (签名 key, .env)"

    $secStage = Join-Path $stage "secrets"
    New-Item -ItemType Directory -Path $secStage -Force | Out-Null

    $foundSecrets = @()
    foreach ($f in $secretFiles) {
        $src = Join-Path $ProjectRoot $f
        if (Test-Path $src) {
            $dest = Join-Path $secStage $f
            New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force | Out-Null
            Copy-Item $src $dest
            $foundSecrets += $f
            Write-Ok "$f"
        }
    }

    # 顺便把 gradle.properties 里的签名相关字段抠出来 (RELEASE_STORE_PASSWORD 等)
    $gpFile = Join-Path $ProjectRoot "gradle.properties"
    if (Test-Path $gpFile) {
        $gpContent = Get-Content $gpFile -Raw
        $gpSensitive = ($gpContent -split "`n") | Where-Object {
            $_ -match '(RELEASE_STORE_|RELEASE_KEY_|SIGNING_|_PASSWORD|_SECRET|_TOKEN|API_KEY)'
        }
        if ($gpSensitive) {
            $gpOut = Join-Path $secStage "gradle.properties.signing-fields.txt"
            "# 来自 gradle.properties 的签名/密钥相关字段 (在 Mac 上也要原样配回去):" | Out-File $gpOut -Encoding UTF8
            $gpSensitive | Out-File $gpOut -Append -Encoding UTF8
            Write-Ok "gradle.properties 签名字段已抠出"
            $foundSecrets += "gradle.properties.signing-fields.txt"
        }
    }

    # ssh key 提示 (不自动拷, 因为不一定在项目内)
    $sshKey = Join-Path $env:USERPROFILE ".ssh\id_rsa"
    if (Test-Path $sshKey) {
        Copy-Item $sshKey (Join-Path $secStage "id_rsa")
        Copy-Item "$sshKey.pub" (Join-Path $secStage "id_rsa.pub") -ErrorAction SilentlyContinue
        Write-Ok "id_rsa (SSH 密钥) 已收集"
        $foundSecrets += "id_rsa"
    }

    # 服务器密码 (硬编码警示放到 README, 不放 zip)

    if ($foundSecrets.Count -eq 0) {
        Write-Warn "没有找到任何敏感文件, secrets.zip 跳过"
        $secZip = $null
        $secZipSize = 0
    } else {
        # 写一份 secrets/README.md
        $secReadme = Join-Path $secStage "README.md"
        @"
# 敏感文件清单

请把这些文件**手动**放回 Mac 上对应位置:

| 文件 | Mac 路径 |
|---|---|
"@ | Out-File $secReadme -Encoding UTF8

        foreach ($f in $foundSecrets) {
            $macPath = switch -Wildcard ($f) {
                "app\release.keystore"     { '~/Desktop/wxsw/WXSW/app/release.keystore' }
                "app\debug.keystore"       { '~/Desktop/wxsw/WXSW/app/debug.keystore' }
                "backend\.env"             { '~/Desktop/wxsw/WXSW/backend/.env' }
                ".env"                     { '~/Desktop/wxsw/WXSW/.env' }
                "id_rsa"                   { '~/.ssh/id_rsa  (chmod 600 必做!)' }
                "*signing-fields*"         { '复制内容到 ~/Desktop/wxsw/WXSW/gradle.properties' }
                default                    { '相同相对路径' }
            }
            "| ``$f`` | $macPath |" | Out-File $secReadme -Append -Encoding UTF8
        }
        @"

---

## 服务器登录信息 (脚本不打包, 这里手抄)

- 主机: wxsw.app
- SSH 端口: 22
- 用户: root
- 密码: (从你 Windows 上的笔记里拿)

## Apple Developer 账号 (如果有)

- Apple ID:
- 团队 ID:
- App-Specific Password:

---
**这个文件夹本身就是机密, 不要传 GitHub, 用 U 盘 / 加密邮件传 Mac.**
"@ | Out-File $secReadme -Append -Encoding UTF8

        $secZip = Join-Path $OutDir "secrets.tar.gz"
        $secParent = Split-Path -Parent $secStage
        $secLeaf   = Split-Path -Leaf   $secStage
        Push-Location $secParent
        try {
            & tar.exe -czf $secZip $secLeaf
            if ($LASTEXITCODE -ne 0) { throw "tar (secrets) 失败" }
        } finally { Pop-Location }
        $secZipSize = (Get-Item $secZip).Length
        Write-Ok "secrets.tar.gz = $(Format-Size $secZipSize)  ($($foundSecrets.Count) 个文件)"
    }

    # ============================================================
    # 3. Cursor 聊天记录 -> cursor-history.zip
    # ============================================================
    Write-Step "3. 收集 Cursor 聊天历史"

    # 项目根目录的反推: 把绝对路径转成 Cursor 项目目录名
    # 例: C:\Users\柠檬茶\Desktop\wxsw\WXSW -> c-Users-柠檬茶-Desktop-wxsw-WXSW
    function Convert-PathToProjectName($path) {
        $p = $path -replace '^([A-Za-z]):\\', '$1-' -replace '\\', '-'
        return $p
    }
    $projectName = Convert-PathToProjectName $ProjectRoot
    $cursorRoots = @(
        "$env:USERPROFILE\.cursor\projects\$projectName",
        # 兼容老路径 (没有用户名前缀)
        "$env:USERPROFILE\.cursor\projects\c-Users-Desktop-wxsw-WXSW"
    )
    $cursorRoot = $cursorRoots | Where-Object { Test-Path $_ } | Select-Object -First 1

    if (-not $cursorRoot) {
        Write-Warn "没有找到 Cursor 项目目录, 试过:"
        $cursorRoots | ForEach-Object { Write-Host "      $_" }
        $curZip = $null
        $curZipSize = 0
    } else {
        Write-Host "    源: $cursorRoot"
        $curStage = Join-Path $stage "cursor-history"
        New-Item -ItemType Directory -Path $curStage -Force | Out-Null

        # 这里也用 robocopy: Cursor 的 assets 目录里图片名是 image-hash + workspaceStorage + uuid,
        # 拼起来动辄 250+ 字符, Copy-Item 在 PS 5.1 上崩, robocopy + UNC 长路径 OK.
        $curStageInner = Join-Path $curStage (Split-Path -Leaf $cursorRoot)
        New-Item -ItemType Directory -Path $curStageInner -Force | Out-Null
        $rcCurArgs = @(
            $cursorRoot, $curStageInner,
            "/MIR",
            "/NFL", "/NDL", "/NJH", "/NJS", "/NC", "/NS", "/NP",
            "/MT:8", "/R:1", "/W:1"
        )
        & robocopy @rcCurArgs | Out-Null
        $rcCur = $LASTEXITCODE
        if ($rcCur -ge 8) { throw "robocopy (cursor-history) 失败, exit code = $rcCur" }

        # 写一份 README
        $curReadme = Join-Path $curStage "README.md"
        @"
# Cursor 聊天历史

这是从 Windows 备份的 Cursor agent transcripts.

## 在 Mac 上查看

直接用 VS Code / Cursor 打开任意 .jsonl 文件, 一行 = 一条消息.
``find $(Split-Path -Leaf $cursorRoot)/agent-transcripts -name '*.jsonl' | xargs ls -lh``

## 在 Mac Cursor 里恢复成会话 (可选, 不一定成功)

1. 在 Mac 上打开项目: ``open -a Cursor ~/Desktop/wxsw/WXSW``
2. 跟 AI 随便聊一句, 让 Cursor 创建对应的 projects 目录
3. 关闭 Cursor
4. 找到 Mac 上的项目目录:
   ``ls ~/Library/Application\ Support/Cursor/projects/``
   找到名字包含 wxsw 的目录
5. 把这个备份里的 ``agent-transcripts/*.jsonl`` 拷进去
6. 重开 Cursor, 在历史会话里应该能看到

⚠️ Cursor 的索引是基于绝对路径生成的, 跨机器迁移**可能不会自动识别**.
如果只是想保留历史记录作参考, 解压后拿 jsonl 文件当档案翻就行.
"@ | Out-File $curReadme -Encoding UTF8

        $curZip = Join-Path $OutDir "cursor-history.tar.gz"
        $curParent = Split-Path -Parent $curStage
        $curLeaf   = Split-Path -Leaf   $curStage
        Push-Location $curParent
        try {
            & tar.exe -czf $curZip $curLeaf
            if ($LASTEXITCODE -ne 0) { throw "tar (cursor) 失败" }
        } finally { Pop-Location }
        $curZipSize = (Get-Item $curZip).Length
        Write-Ok "cursor-history.tar.gz = $(Format-Size $curZipSize)"
    }

    # ============================================================
    # 3.5 setup-mac.sh (Mac 端一键脚本)
    # ============================================================
    Write-Step "3.5 拷贝 Mac 端一键脚本 setup-mac.sh"
    $setupSh = Join-Path $ProjectRoot "scripts\setup-mac.sh"
    if (Test-Path $setupSh) {
        # 用 .NET 直接读, 强制 LF 行尾 (Windows 的 CRLF 在 bash 里会报错)
        $shContent = [System.IO.File]::ReadAllText($setupSh) -replace "`r`n", "`n"
        [System.IO.File]::WriteAllText((Join-Path $OutDir "setup-mac.sh"), $shContent, (New-Object System.Text.UTF8Encoding $false))
        Write-Ok "setup-mac.sh ($(Format-Size ((Get-Item $setupSh).Length)), 行尾已转 LF)"
    } else {
        Write-Warn "scripts\setup-mac.sh 不存在, 跳过 (Mac 上需手动操作)"
    }

    # ============================================================
    # 4. README.md (Mac 上的开机指引)
    # ============================================================
    Write-Step "4. 生成 Mac 开机指引 README.md"

    $readmePath = Join-Path $OutDir "README.md"
    $now = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $sourceMachine = $env:COMPUTERNAME

    $readme = @"
# 万象书屋 - Mac 迁移包

> 打包时间: $now
> 来源机器: $sourceMachine

## 包内容

| 文件 | 大小 | 用途 |
|---|---|---|
| ``code-snapshot.tar.gz`` | $(Format-Size $codeZipSize) | 项目代码 (已排除 build / 缓存 / Windows 二进制工具) |
"@
    if ($secZip)  { $readme += "`n| ``secrets.tar.gz`` | $(Format-Size $secZipSize) | 签名密钥 / .env / SSH key (机密!) |" }
    if ($curZip)  { $readme += "`n| ``cursor-history.tar.gz`` | $(Format-Size $curZipSize) | Cursor 聊天历史备份 |" }
    $readme += "`n| ``SHA256SUMS.txt`` | - | 上面 tar.gz 的校验和 |"

    $readme += @"


---

## ⚡ Mac 用户: 推荐用一键脚本 (5 分钟全自动)

把整个目录传到 Mac (建议 ``~/Downloads/wxsw-mac-migration/``), 然后:

``````bash
cd ~/Downloads/wxsw-mac-migration
bash setup-mac.sh
``````

每个步骤会问 [Y/n], 一路回车默认 yes. 自动完成:
- SHA256 校验包完整性
- 解压代码到 ``~/Desktop/wxsw/WXSW/``
- 解压 Cursor 历史到 ``~/Desktop/wxsw-cursor-history-backup/``
- 装 Homebrew + JDK 17 + Node 22 + Android Studio + Cursor
- 写 ``local.properties`` 指 Android SDK
- 跑一次 ``./gradlew assembleAppDebug`` 验证编译能过
- 跑 ``npm install`` + 启动后端 health check 验证

完事直接打开 Android Studio 就能继续干活.

全自动模式 (零交互):
``````bash
bash setup-mac.sh --yes
``````

下面是手工步骤 (脚本里其实已经做完了, 仅参考):

---

## 手工步骤 (脚本失败时备用)

### 1. 装环境 (一次性, 5-10 分钟)

``````bash
# 装 Homebrew (如果没有)
/bin/bash -c "`$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# 装 JDK 17 + Android Studio + Node 22 + Cursor
brew install --cask zulu@17 android-studio cursor
brew install node@22 git

# 装 Xcode 命令行工具 (iOS 开发用)
xcode-select --install
``````

### 2. 解压代码

``````bash
mkdir -p ~/Desktop/wxsw
cd ~/Desktop/wxsw
tar xzf /path/to/code-snapshot.tar.gz
# 解压后是 ~/Desktop/wxsw/WXSW/
``````

### 3. 配回敏感文件 (从 secrets.tar.gz)

``````bash
mkdir -p ~/Desktop/secrets-tmp
tar xzf /path/to/secrets.tar.gz -C ~/Desktop/secrets-tmp
cd ~/Desktop/secrets-tmp/secrets
# 看 README.md 里的对应表, 把每个文件放回 ~/Desktop/wxsw/WXSW/ 内对应路径

# SSH 密钥 (重要)
cp id_rsa ~/.ssh/
chmod 600 ~/.ssh/id_rsa

# 用完删掉, 别留在桌面
rm -rf ~/Desktop/secrets-tmp
``````

### 4. 验证 Android 端能编译

``````bash
cd ~/Desktop/wxsw/WXSW
./gradlew :app:assembleAppDebug
# 5-10 分钟后:
ls app/build/outputs/apk/app/debug/
``````

如果第一次报 ``SDK location not found``:
- 打开 Android Studio -> 让它自动装 Android SDK
- 或手动建 ``local.properties``: ``sdk.dir=/Users/你的用户名/Library/Android/sdk``

### 5. 验证后端能跑

``````bash
cd ~/Desktop/wxsw/WXSW/backend
npm install
PORT=3001 node server.js
# 另开终端: curl http://localhost:3001/api/health
``````

### 6. (可选) 恢复 Cursor 聊天历史

见 ``cursor-history.zip`` 里的 README.md.

### 7. 服务器仍在跑, 不用动

- 主机: ``http://wxsw.app/``
- 品牌页: 同上
- Admin: http://wxsw.app/admin
- 部署位置: ``/opt/wanxiang/``
- 服务: ``systemctl status wanxiang-backend.service``

Mac 上 SSH 上去和 Windows 一样:
``````bash
ssh root@wxsw.app
``````

---

## 校验包完整性

Mac 上比对 SHA256:

``````bash
shasum -a 256 *.tar.gz
diff <(shasum -a 256 *.tar.gz | awk '{print `$1, `$2}' | sort) \
     <(cat SHA256SUMS.txt | awk '{print `$1, `$2}' | sort)
# 没输出 = 一致
``````

---

## 已排除 / 不在包里的内容 (Mac 上无需关心)

- ``app/build/``       - Gradle 构建产物, ``./gradlew assembleAppDebug`` 重新出
- ``.gradle/``         - Gradle 本地缓存, 自动重建
- ``.idea/``           - IDEA 工程配置, Android Studio 打开自动重建
- ``backend/node_modules/`` - Node 依赖, ``npm install`` 重装
- ``backend/data/``    - 本地 SQLite 数据库, **服务器上有真实数据, 别覆盖**
- ``.tools/node-v22.14.0-win-x64/`` - Windows 二进制 Node, Mac 用 brew 装

---

## 目前状态快照

- Android Release APK: 3.26.050412 (含书城顶栏修复)
- 服务器: wxsw.app, Node.js + Nginx + SQLite, 运行中
- 后端服务: ``wanxiang-backend.service``, autostart on
- 公网入口: ``http://wxsw.app/``
- APK 下载: ``http://wxsw.app/dl/wanxiang-latest.apk``
- 后台管理: ``http://wxsw.app/admin``

下一步路线见上一段对话: 域名 + ICP 备案 + HTTPS, 然后启动 iOS 工程.

"@
    $readme | Out-File $readmePath -Encoding UTF8
    Write-Ok "README.md 生成"

    # ============================================================
    # 5. SHA256 校验和
    # ============================================================
    Write-Step "5. 计算 SHA256 校验和"

    $sumPath = Join-Path $OutDir "SHA256SUMS.txt"
    $zips = @($codeZip, $secZip, $curZip) | Where-Object { $_ -and (Test-Path $_) }
    $sums = foreach ($z in $zips) {
        $hash = (Get-FileHash $z -Algorithm SHA256).Hash.ToLower()
        $name = Split-Path -Leaf $z
        "$hash  $name"
    }
    $sums | Out-File $sumPath -Encoding ASCII
    Write-Ok "SHA256SUMS.txt"

    # ============================================================
    # 完成报告
    # ============================================================
    Write-Step "完成! 输出位置:"
    Write-Host "    $OutDir" -ForegroundColor Green
    Write-Host ""
    Write-Host "包内容:"
    Get-ChildItem $OutDir | ForEach-Object {
        $sz = if ($_.PSIsContainer) { '(dir)' } else { Format-Size $_.Length }
        Write-Host ("    {0,-30} {1,12}" -f $_.Name, $sz)
    }
    Write-Host ""
    $totalSize = (Get-ChildItem $OutDir -Recurse -File | Measure-Object Length -Sum).Sum
    Write-Host "总大小: $(Format-Size $totalSize)" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "下一步:" -ForegroundColor Yellow
    Write-Host "  1. 用 LocalSend / U盘 / 网盘把上面的 zip 传到 Mac"
    Write-Host "  2. Mac 上解压, 按 README.md 的步骤跑"
    Write-Host "  3. secrets.zip 用机密渠道传 (千万别上 GitHub!)"
    Write-Host ""

    # 自动在资源管理器打开
    explorer.exe $OutDir

} finally {
    & $cleanupStage
}
