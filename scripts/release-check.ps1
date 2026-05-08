# Wanxiang release self-check
# Run: powershell -ExecutionPolicy Bypass -File scripts\release-check.ps1

$ErrorActionPreference = 'Continue'
$root = Resolve-Path "$PSScriptRoot\.."
Set-Location $root

$blockers = @()
$warnings = @()
$infos = @()

function Add-Blocker([string]$msg) { $script:blockers += $msg; Write-Host "[BLOCK] $msg" -ForegroundColor Red }
function Add-Warning([string]$msg) { $script:warnings += $msg; Write-Host "[WARN ] $msg" -ForegroundColor Yellow }
function Add-Info([string]$msg)    { $script:infos    += $msg; Write-Host "[ OK  ] $msg" -ForegroundColor Green }

Write-Host "=== Wanxiang Release Self-Check ===" -ForegroundColor Cyan
Write-Host "root: $root`n"

# 1. applicationId
$gradle = Get-Content "android\app\build.gradle" -Raw
if ($gradle -match 'applicationId\s+"io\.legado\.app"') {
    Add-Blocker "applicationId is still io.legado.app — must rename for store"
} elseif ($gradle -match 'applicationId\s+"([^"]+)"') {
    Add-Info "applicationId = $($matches[1])"
}

# 2. minSdk
if ($gradle -match 'minSdk\s+(\d+)') {
    $min = [int]$matches[1]
    if ($min -lt 24) { Add-Warning "minSdk = $min, recommended >=24 for CN stores" }
    else { Add-Info "minSdk = $min" }
}

# 3. release flavor hardening
if ($gradle -match 'minifyEnabled\s+true') { Add-Info "release minifyEnabled true" }
else { Add-Warning "release missing minifyEnabled" }
if ($gradle -match 'shrinkResources\s*=?\s*true') { Add-Info "release shrinkResources true" }
else { Add-Warning "release missing shrinkResources" }
if ($gradle -match 'debuggable\s+false') { Add-Info "release debuggable=false declared" }

# 4. AndroidManifest hot spots
$manifest = Get-Content "android\app\src\main\AndroidManifest.xml" -Raw
if ($manifest -match 'android:allowBackup="true"') {
    Add-Blocker "allowBackup=true detected — privacy risk, set to false"
}
if ($manifest -notmatch 'networkSecurityConfig') {
    Add-Blocker "missing networkSecurityConfig"
}
if ($manifest -match 'android:debuggable="true"') {
    Add-Blocker "manifest hardcodes debuggable=true"
}
$dangerousPerms = @(
    'READ_PHONE_STATE', 'READ_CONTACTS', 'WRITE_CONTACTS',
    'READ_SMS', 'SEND_SMS', 'CALL_PHONE',
    'CAMERA', 'RECORD_AUDIO', 'ACCESS_FINE_LOCATION', 'ACCESS_COARSE_LOCATION',
    'GET_ACCOUNTS', 'READ_CALL_LOG', 'WRITE_CALL_LOG'
)
foreach ($p in $dangerousPerms) {
    if ($manifest -match "android.permission\.$p") {
        Add-Warning "dangerous permission $p declared, ensure privacy policy covers it"
    }
}

# 5. bundled book sources
$bookSources = "android\app\src\main\assets\defaultData\bookSources.json"
if (Test-Path $bookSources) {
    $size = (Get-Item $bookSources).Length
    if ($size -gt 50) {
        Add-Blocker "bookSources.json bundled $size bytes — recommend empty + dynamic backend distribution"
    } else {
        $sz = $size
        Add-Info "bookSources.json is empty ($sz bytes)"
    }
}

# 6. legado brand text in strings
$brandHits = Select-String -Path "android\app\src\main\res\values*\strings.xml" -Pattern "legado\.app|gedoor\.com" -ErrorAction SilentlyContinue
if ($brandHits) {
    Add-Warning "strings.xml still contains legado/gedoor brand text in $($brandHits.Count) places"
}

# 7. legal docs
$legalFiles = @(
    "android\app\src\main\assets\legal\privacyPolicy.md",
    "android\app\src\main\assets\legal\userAgreement.md",
    "android\app\src\main\assets\legal\collectList.md",
    "android\app\src\main\assets\legal\sdkList.md",
    "android\app\src\main\assets\legal\license.md"
)
foreach ($f in $legalFiles) {
    if (-not (Test-Path $f)) {
        Add-Blocker "missing legal doc: $f"
    } else {
        $content = Get-Content $f -Raw
        # check for placeholder markers (ascii only to keep PS5 happy)
        $placeholderHex = [byte[]]@(0x5B,0xE8,0xAF,0xB7,0xE5,0xA1,0xAB,0xE5,0x85,0xA5)  # "[请填入" UTF-8
        $placeholderStr = [System.Text.Encoding]::UTF8.GetString($placeholderHex)
        if ($content -match 'PLACEHOLDER' -or $content.Contains($placeholderStr)) {
            Add-Warning "$([System.IO.Path]::GetFileName($f)) still has placeholder, fill it before release"
        }
        if ($content.Length -lt 500) {
            Add-Warning "$f is short ($($content.Length) chars)"
        }
    }
}

# 8. LICENSE / NOTICE
if (-not (Test-Path "LICENSE")) { Add-Blocker "missing LICENSE (GPL-3.0)" }
elseif ((Get-Item "LICENSE").Length -lt 30000) { Add-Warning "LICENSE is small, may not be full GPL-3.0 text" }
else { Add-Info "LICENSE present" }
$noticePath = "docs\NOTICE.md"
if (-not (Test-Path $noticePath)) { Add-Warning "missing $noticePath" }

# 9. NOTICE repo placeholder
if (Test-Path $noticePath) {
    $notice = Get-Content $noticePath -Raw
    if ($notice -match 'REPO_URL_PLACEHOLDER') {
        Add-Blocker "$noticePath has REPO_URL_PLACEHOLDER not replaced with public Git repo"
    }
}

# 10. backend URL via gradle.properties
if ($gradle -match 'wanxiangBackendEscaped') {
    $props = if (Test-Path "android\gradle.properties") { Get-Content "android\gradle.properties" -Raw } else { "" }
    if ($props -notmatch 'WANXIANG_BACKEND_URL=https://') {
        Add-Warning "android/gradle.properties WANXIANG_BACKEND_URL not HTTPS, store requires HTTPS in production"
    }
}

# 11. TODO/FIXME
$debugTags = @('TODO', 'FIXME', 'XXX')
$debugCount = 0
foreach ($t in $debugTags) {
    $hits = Select-String -Path "android\app\src\main\java\io\legado\app\**\*.kt" -Pattern $t -ErrorAction SilentlyContinue
    if ($hits) { $debugCount += $hits.Count }
}
if ($debugCount -gt 0) {
    Add-Info "$debugCount TODO/FIXME tags in code (not blocking)"
}

# 12. internal tools shouldn't bloat git
if (Test-Path ".tools\node-v22.14.0-win-x64") {
    Add-Warning ".tools/node-v22.14.0-win-x64 should be added to .gitignore"
}

# 13. icon
$icLauncher = Get-ChildItem "android\app\src\main\res\mipmap-*" -Filter "ic_launcher*" -ErrorAction SilentlyContinue
$count = $icLauncher.Count
if ($count -ge 5) { Add-Info "ic_launcher exists in $count mipmap dirs" }
else { Add-Warning "ic_launcher only in $count mipmap dirs, recommend full set (mdpi-xxxhdpi)" }

# Summary
Write-Host "`n=== Self-Check Report ===" -ForegroundColor Cyan
Write-Host "Pass: $($infos.Count)"   -ForegroundColor Green
Write-Host "Warn: $($warnings.Count)" -ForegroundColor Yellow
Write-Host "Block: $($blockers.Count)" -ForegroundColor Red

if ($blockers.Count -gt 0) {
    Write-Host "`nBlockers (must fix before release):" -ForegroundColor Red
    $blockers | ForEach-Object { Write-Host " - $_" -ForegroundColor Red }
    exit 1
}
if ($warnings.Count -gt 0) {
    Write-Host "`nWarnings (recommended fix):" -ForegroundColor Yellow
    $warnings | ForEach-Object { Write-Host " - $_" -ForegroundColor Yellow }
}
Write-Host "`nSelf-check OK" -ForegroundColor Green
exit 0
