# 万象书屋后端 — Windows 本地一键启动（需已安装 Node.js LTS，含 npm）
# 若提示禁止脚本：powershell -ExecutionPolicy Bypass -File .\run-local.ps1
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

function Find-NpmCmd {
    $cmd = Get-Command npm.cmd -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($p in @(
            "$env:ProgramFiles\nodejs\npm.cmd",
            "${env:ProgramFiles(x86)}\nodejs\npm.cmd",
            "$env:LOCALAPPDATA\Programs\node\npm.cmd"
        )) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

function Find-NodeExe {
    $cmd = Get-Command node.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($p in @(
            "$env:ProgramFiles\nodejs\node.exe",
            "${env:ProgramFiles(x86)}\nodejs\node.exe",
            "$env:LOCALAPPDATA\Programs\node\node.exe"
        )) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

$npm = Find-NpmCmd
$node = Find-NodeExe
if (-not $npm -or -not $node) {
    Write-Host "未找到 Node.js / npm。请先安装：https://nodejs.org/ （选 LTS），安装完成后关闭并重开终端。"
    exit 1
}

Write-Host "node: $node"
Write-Host "npm:  $npm"

if (-not (Test-Path "node_modules")) {
    Write-Host "首次运行：npm install ..."
    & $npm install
}

Write-Host ""
Write-Host "后台已启动："
Write-Host "  API    http://127.0.0.1:3000/api/sources"
Write-Host "  管理页 http://127.0.0.1:3000/admin  （默认密码见 README / wanxiang.service）"
Write-Host "按 Ctrl+C 停止"
Write-Host ""

& $node server.js
