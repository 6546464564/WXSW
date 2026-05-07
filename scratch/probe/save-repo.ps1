# Wanxiang: git init + commit (requires Git for Windows installed)
# Run: powershell -ExecutionPolicy Bypass -File .\save-repo.ps1
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$env:Path = "$machinePath;$userPath"

$gitExe = $null
foreach ($p in @(
        "${env:ProgramFiles}\Git\cmd\git.exe",
        "${env:ProgramFiles}\Git\bin\git.exe",
        "${env:ProgramFiles(x86)}\Git\cmd\git.exe",
        "$env:LOCALAPPDATA\Programs\Git\cmd\git.exe"
    )) {
    if (Test-Path $p) { $gitExe = $p; break }
}
if (-not $gitExe) {
    $cmd = Get-Command git -ErrorAction SilentlyContinue
    if ($cmd) { $gitExe = $cmd.Source }
}

if (-not $gitExe) {
    Write-Host "Git not found. Install from https://git-scm.com/download/win then run this script again."
    exit 1
}

function Invoke-Git {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
    & $gitExe @Args
    if ($LASTEXITCODE -ne 0) { throw "git $($Args -join ' ') failed: $LASTEXITCODE" }
}

if (-not (Test-Path '.git')) {
    Invoke-Git init
    Invoke-Git branch -M main
}

Invoke-Git add -A
Invoke-Git status
$msg = "snapshot $(Get-Date -Format 'yyyy-MM-dd_HHmm')"
Invoke-Git commit -m $msg

Write-Host "OK."
