$urls = Get-Content -Raw ".\sources_to_probe.txt" -Encoding UTF8 |
    ForEach-Object { $_ -split "`n" } |
    Where-Object { $_ -match '\|' } |
    ForEach-Object {
        $parts = $_ -split '\|', 2
        [PSCustomObject]@{ Url = $parts[0].Trim(); Name = $parts[1].Trim() }
    }

$ua = "Mozilla/5.0 (Linux; Android 12; Pixel 5) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.0.0 Mobile Safari/537.36"

# 把 legado 内联 syntax (,{...} 或 ////## 后缀等) 剥离掉,保留干净的 https://host/path
function Get-CleanUrl([string]$u) {
    $clean = $u -replace ',\{.*$', ''
    $clean = $clean -replace '/+##.*$', ''
    $clean = $clean -replace '/+@.*$', ''
    $clean = $clean.TrimEnd('/')
    if (-not $clean) { return $null }
    if ($clean -notmatch '^https?://') { return $null }
    return $clean
}

$results = New-Object System.Collections.ArrayList
$batchSize = 10
$idx = 0
$total = $urls.Count

while ($idx -lt $total) {
    $batch = @($urls[$idx..[Math]::Min($idx + $batchSize - 1, $total - 1)])
    $jobs = @()
    foreach ($s in $batch) {
        $cu = Get-CleanUrl $s.Url
        if (-not $cu) {
            $null = $results.Add([PSCustomObject]@{ Url = $s.Url; Name = $s.Name; CleanUrl = ""; Code = 0; Size = 0; Class = "BAD_URL" })
            continue
        }
        $jobs += Start-Job -ArgumentList $cu, $s.Url, $s.Name, $ua -ScriptBlock {
            param($cu, $orig, $name, $ua)
            $tmp = [System.IO.Path]::GetTempFileName()
            try {
                $out = & curl.exe -sL -A $ua -H "Accept-Language: zh-CN,zh;q=0.9" --max-time 6 --retry 0 $cu -o $tmp -w "%{http_code}|%{size_download}" 2>$null
                $parts = $out -split '\|'
                $code = [int]($parts[0])
                $size = [int]($parts[1])
                $body = ""
                if ((Test-Path $tmp) -and ($size -gt 0)) {
                    try { $body = [System.IO.File]::ReadAllText($tmp, [System.Text.Encoding]::UTF8) } catch {}
                }
                $cls = "OK"
                if ($code -eq 0) { $cls = "TIMEOUT_OR_DNS" }
                elseif ($code -eq 202 -and $size -lt 2000) { $cls = "BOT_CHALLENGE" }
                elseif ($code -ge 400) { $cls = "ERR_$code" }
                elseif ($body -match 'Just a moment|cf-browser-verification|cf_chl_|Attention Required|Checking your browser|Cloudflare|cloudflare') { $cls = "CLOUDFLARE" }
                elseif ($body -match '正在进行安全验证|请稍候\.{3}|安全验证防护|验证码|滑块验证|geetest|captcha') { $cls = "CAPTCHA" }
                elseif ($size -lt 1000) { $cls = "TINY_BODY" }
                [PSCustomObject]@{ Url = $orig; Name = $name; CleanUrl = $cu; Code = $code; Size = $size; Class = $cls }
            } finally {
                Remove-Item $tmp -Force -ErrorAction SilentlyContinue
            }
        }
    }
    Wait-Job -Job $jobs -Timeout 30 | Out-Null
    foreach ($j in $jobs) {
        $r = Receive-Job -Job $j -ErrorAction SilentlyContinue
        if ($r) { $null = $results.Add($r) }
        Remove-Job -Job $j -Force -ErrorAction SilentlyContinue
    }
    $idx += $batchSize
    Write-Host -NoNewline "."
}
Write-Host ""
Write-Host ("=== Summary ===")
$results | Group-Object Class | Sort-Object Count -Descending | ForEach-Object {
    Write-Host ("{0,-20} {1}" -f $_.Name, $_.Count)
}
$results | ConvertTo-Json -Depth 3 | Out-File ".\probe_results.json" -Encoding UTF8
Write-Host "Saved probe_results.json"
