# 万象书屋 1 小时 CSJ-only 广告测试 (开屏 + 激励交替)
# 每 cycle:
#   1. force-stop + 冷启 → SplashAdActivity (触发开屏)
#   2. 等隐私对话框 (首次), 自动点同意
#   3. 等 70s 让 splash 完整播放
#   4. 找右上角 X 关闭 splash
#   5. 进 MainActivity → 切我的 tab
#   6. 点"看 1 次广告 +30 分钟" → 触发激励视频
#   7. 等 70s 让激励视频完整播放
#   8. 找右上角 X 关闭激励
#   9. 回 MainActivity
# 跨 60 分钟, 每 5 cycle 拉一次 ad-funnel.

$ErrorActionPreference = 'SilentlyContinue'
$env:Path = "C:\Users\柠檬茶\Desktop\wxsw\WXSW\.tools\platform-tools;" + $env:Path

$startTime = Get-Date
$endTime = $startTime.AddMinutes(60)
$logFile = "$env:TEMP\wx-csj-1h.log"
$reportFile = "$env:TEMP\wx-csj-1h-report.log"
"=== CSJ-only 1h test started at $startTime ===" | Out-File $logFile

$session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
Invoke-WebRequest -Uri "http://localhost:3000/api/admin/login" -Method POST -Body '{"password":"wanxiang123"}' -ContentType "application/json" -WebSession $session -UseBasicParsing | Out-Null

# === Helper: 找 UI 元素 bounds ===
function Get-UiBounds($keyword) {
    adb -s emulator-5554 shell uiautomator dump /sdcard/d.xml 2>&1 | Out-Null
    adb -s emulator-5554 pull /sdcard/d.xml "$env:TEMP\d.xml" 2>&1 | Out-Null
    $xml = [System.IO.File]::ReadAllText("$env:TEMP\d.xml")
    if ($xml -match "$keyword[^>]*?bounds=`"\[(\d+),(\d+)\]\[(\d+),(\d+)\]`"") {
        return @(([int]$matches[1] + [int]$matches[3])/2, ([int]$matches[2] + [int]$matches[4])/2)
    }
    return $null
}

function Find-CloseButton {
    # 找右上角 ImageView (close 按钮通常在那里)
    adb -s emulator-5554 shell uiautomator dump /sdcard/d.xml 2>&1 | Out-Null
    adb -s emulator-5554 pull /sdcard/d.xml "$env:TEMP\d.xml" 2>&1 | Out-Null
    $xml = [System.IO.File]::ReadAllText("$env:TEMP\d.xml")
    $matches = [regex]::Matches($xml, 'class="android.widget.ImageView"[^>]*?bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"')
    foreach ($m in $matches) {
        $cx = ([int]$m.Groups[1].Value + [int]$m.Groups[3].Value)/2
        $cy = ([int]$m.Groups[2].Value + [int]$m.Groups[4].Value)/2
        # 右上角: x>1100 (1440 屏), y<350
        if ($cx -gt 1100 -and $cy -lt 350 -and ($cx - $cy) -gt 800) {
            return @($cx, $cy)
        }
    }
    return $null
}

$cycle = 0
while ((Get-Date) -lt $endTime) {
    $cycle++
    $now = Get-Date -Format "HH:mm:ss"
    "[cycle $cycle / $now] start" | Out-File $logFile -Append
    Write-Host "[cycle $cycle / $now]"

    # === 1. force-stop + 冷启 ===
    adb -s emulator-5554 shell am force-stop com.wanxiang.reader.debug 2>&1 | Out-Null
    Start-Sleep -Seconds 1
    adb -s emulator-5554 shell monkey -p com.wanxiang.reader.debug -c android.intent.category.LAUNCHER 1 2>&1 | Out-Null
    Start-Sleep -Seconds 6

    # === 2. 隐私同意对话框处理 (每个 cycle 都检测, 因为 force-stop 后 SP 可能还没写)
    # 检测策略 1: uiautomator dump + 找 button1
    # 策略 2: 找 ImageView in dialog area
    # 兜底: 直接 tap 屏幕中央偏右下 (1164, 1889) 这个位置在 dialog 显示时是同意按钮, 不显示时无害
    Start-Sleep -Seconds 2
    $consentTapped = $false
    for ($try = 1; $try -le 3; $try++) {
        adb -s emulator-5554 shell uiautomator dump /sdcard/d.xml 2>&1 | Out-Null
        adb -s emulator-5554 pull /sdcard/d.xml "$env:TEMP\d.xml" 2>&1 | Out-Null
        $xml = [System.IO.File]::ReadAllText("$env:TEMP\d.xml")
        if ($xml -match 'resource-id="android:id/button1"[^>]*?bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"') {
            $cx = ([int]$matches[1] + [int]$matches[3])/2
            $cy = ([int]$matches[2] + [int]$matches[4])/2
            adb -s emulator-5554 shell input tap $cx $cy 2>&1 | Out-Null
            "[cycle $cycle] consent dialog at ($cx,$cy), try=$try" | Out-File $logFile -Append
            $consentTapped = $true
            Start-Sleep -Seconds 3
            break
        }
        Start-Sleep -Seconds 1
    }
    if (-not $consentTapped) {
        "[cycle $cycle] no consent dialog detected (already accepted)" | Out-File $logFile -Append
    }

    # === 3. 等 splash 完整播放 (60s, ylh 短/csj 长 都覆盖) ===
    Start-Sleep -Seconds 60

    # === 4. 不依赖识别 close 按钮 (容易误识别书架页搜索图标),
    #        直接 force-stop 强制结束 splash 流程, 然后 am start 进 MainActivity ===
    adb -s emulator-5554 shell am force-stop com.wanxiang.reader.debug 2>&1 | Out-Null
    Start-Sleep -Seconds 2
    adb -s emulator-5554 shell am start -n com.wanxiang.reader.debug/io.legado.app.ui.main.MainActivity 2>&1 | Out-Null
    Start-Sleep -Seconds 5
    "[cycle $cycle] entered MainActivity directly (skip splash close)" | Out-File $logFile -Append

    # === 5. 切到我的 tab. 用 uiautomator 找"我的"实际坐标, 比硬编码可靠 ===
    $myTabTapped = $false
    for ($try = 1; $try -le 3; $try++) {
        adb -s emulator-5554 shell uiautomator dump /sdcard/d.xml 2>&1 | Out-Null
        adb -s emulator-5554 pull /sdcard/d.xml "$env:TEMP\d.xml" 2>&1 | Out-Null
        $xml = [System.IO.File]::ReadAllText("$env:TEMP\d.xml")
        # 找含"我的"的 LinearLayout/View, 中心点 tap
        if ($xml -match '(?:resource-id="[^"]*navigation_my[^"]*"|content-desc="我的"|text="我的")[^>]*?bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"') {
            $cx = ([int]$matches[1] + [int]$matches[3])/2
            $cy = ([int]$matches[2] + [int]$matches[4])/2
            adb -s emulator-5554 shell input tap $cx $cy 2>&1 | Out-Null
            "[cycle $cycle] my-tab tap at ($cx,$cy)" | Out-File $logFile -Append
            $myTabTapped = $true
            break
        }
        Start-Sleep -Seconds 1
    }
    if (-not $myTabTapped) {
        # 兜底硬编码
        adb -s emulator-5554 shell input tap 1200 2460
        "[cycle $cycle] my-tab tap fallback (1200,2460)" | Out-File $logFile -Append
    }
    Start-Sleep -Seconds 4

    # === 6. 点 "看 1 次广告 +30 分钟" 按钮.
    #        用 uiautomator 找"看 1 次广告"文本 ===
    adb -s emulator-5554 shell uiautomator dump /sdcard/d.xml 2>&1 | Out-Null
    adb -s emulator-5554 pull /sdcard/d.xml "$env:TEMP\d.xml" 2>&1 | Out-Null
    $xml = [System.IO.File]::ReadAllText("$env:TEMP\d.xml")
    if ($xml -match 'text="(?:看 1 次广告|看广告|\u770b\s*1\s*\u6b21\u5e7f\u544a)[^"]*"[^>]*?bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"') {
        $cx = ([int]$matches[1] + [int]$matches[3])/2
        $cy = ([int]$matches[2] + [int]$matches[4])/2
        adb -s emulator-5554 shell input tap $cx $cy 2>&1 | Out-Null
        "[cycle $cycle] watch-ad button at ($cx,$cy)" | Out-File $logFile -Append
    } else {
        # 兜底
        adb -s emulator-5554 shell input tap 1080 530
        "[cycle $cycle] watch-ad fallback (1080,530)" | Out-File $logFile -Append
    }
    Start-Sleep -Seconds 5

    # === 7. 等激励视频播放 (60s) ===
    Start-Sleep -Seconds 60

    # === 8. 跟 splash 一样不识别 close, 直接 force-stop 准备下一轮 ===
    "[cycle $cycle] cycle done, will force-stop next" | Out-File $logFile -Append

    # === 10. 每 5 cycle 拉报告 ===
    if (($cycle % 5) -eq 0) {
        try {
            $f = (Invoke-WebRequest -Uri "http://localhost:3000/api/admin/ad-funnel?hours=2" -WebSession $session -UseBasicParsing -TimeoutSec 5).Content | ConvertFrom-Json
            $line = "[$now] cycle=$cycle | "
            foreach ($r in $f.funnel) {
                $line += "$($r.placement.Substring(0,3))/$($r.provider): L$($r.load)/S$($r.show)/R$($r.reward)/C$($r.close)/E$($r.error)  "
            }
            $line | Out-File $reportFile -Append
            Write-Host $line
        } catch {}
    }
}

"=== Test ended at $(Get-Date) ===" | Out-File $logFile -Append
"=== Final ad-funnel ===" | Out-File $reportFile -Append
$f = (Invoke-WebRequest -Uri "http://localhost:3000/api/admin/ad-funnel?hours=2" -WebSession $session -UseBasicParsing).Content | ConvertFrom-Json
$f.funnel | ConvertTo-Json | Out-File $reportFile -Append
