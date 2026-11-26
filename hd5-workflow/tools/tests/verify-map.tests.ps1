<#
.SYNOPSIS
  _verify-map-lib.ps1（功能地圖檢查器）離線測試：暫存資料夾造最小合格地圖，再逐項放入合法內容／佔位符看判定。
  執行：pwsh -File tests/verify-map.tests.ps1（也會用 Windows PowerShell 5.1 跑一輪）；最後一行要是 ALL PASSED。
#>
param([switch]$Inner)
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
$lib = (Resolve-Path (Join-Path $PSScriptRoot '..\_verify-map-lib.ps1')).Path
. $lib
$script:fail = 0
$tag = if ($PSVersionTable.PSEdition -eq 'Desktop') { '[PS5.1]' } else { '[pwsh]' }
function Check($name, $cond) { if ($cond) { Write-Host "  ok   $tag $name" } else { Write-Host "  FAIL $tag $name" -ForegroundColor Red; $script:fail++ } }

$root = Join-Path ([IO.Path]::GetTempPath()) ('verifymap_' + [guid]::NewGuid().ToString('N'))
$vr = Join-Path $root 'verify'
New-Item -ItemType Directory -Force (Join-Path $vr 'features') | Out-Null
function Save([string]$rel, [string[]]$lines) { [IO.File]::WriteAllLines((Join-Path $vr $rel), $lines, [Text.UTF8Encoding]::new($false)) }
function New-Doc([string[]]$extraLaunch = @()) {
    $l = @('# 驗證文件（測試用）', '')
    foreach ($s in $script:VerifyDocSections) { $l += "## $($s.Label)"; $l += '測試用內容。'; if ($s.Key -eq 'Launch') { $l += $extraLaunch }; $l += '' }
    Save 'verify-test.md' $l
}
function New-Feature([string]$id, [string[]]$extraDrive = @()) {
    $l = @("# $id", '測試用功能。', '')
    foreach ($s in $script:FeatureSections) {
        $l += "## $($s.Label)"
        if ($s.Key -eq 'Driving it') { $l += '前提：測試帳號。'; $l += '1. 開頁 → 看到清單'; $l += $extraDrive } else { $l += '- 測試用內容' }
        $l += ''
    }
    Save "features\$id.md" $l
}
Save 'features\README.md' @('# 功能地圖共同前提（測試用）')
New-Doc; foreach ($id in 'feat-a', 'feat-b', 'feat-c') { New-Feature $id }
$r = Test-VerifyMap -VerifyRoot $vr
Check '最小地圖 ⇒ 合格（測試本身的底）' $r.Passed
if (-not $r.Passed) { Write-Host "    $($r.Reasons -join '；')" }

Write-Host "--- $tag {{…}} 在程式碼裡不算佔位符（11-23 導入實測：docker --format 被擋）---"
New-Feature 'feat-a' @('2. 看容器：`docker compose ps --format "{{.Name}}"` → 列出服務名')
$r = Test-VerifyMap -VerifyRoot $vr; Check '行內碼裡的 {{.Name}} ⇒ 合格' $r.Passed
New-Feature 'feat-a' @('2. 執行：', '```', 'docker compose ps --format "{{.Name}} {{.Status}}"', '{{#each items}}{{name}}{{/each}}', '```', '3. 看到全部 Up')
$r = Test-VerifyMap -VerifyRoot $vr; Check '``` 程式碼區塊裡的 Go template／Handlebars ⇒ 合格' $r.Passed
New-Feature 'feat-a' @('2. 執行：', '~~~bash', 'kubectl get pods -o go-template="{{range .items}}{{.metadata.name}}{{end}}"', '~~~')
$r = Test-VerifyMap -VerifyRoot $vr; Check '~~~ 程式碼區塊裡的 {{…}} ⇒ 合格' $r.Passed
New-Doc @('啟動後看 `{{.State}}` 是 running。')
$r = Test-VerifyMap -VerifyRoot $vr; Check '驗證文件裡行內碼的 {{…}} ⇒ 合格' $r.Passed
New-Doc

Write-Host "--- $tag 程式碼外的 {{…}} 與其他佔位符照擋 ---"
New-Feature 'feat-a' @('2. 開 {{功能網址}} → 看到清單')
$r = Test-VerifyMap -VerifyRoot $vr; Check '🔴 程式碼外的 {{功能網址}} ⇒ 擋' (-not $r.Passed -and ($r.Reasons -join ' ') -match 'feat-a\.md 還有佔位符')
New-Feature 'feat-a' @('2. 執行 `docker ps` 之後開 {{網址}}')
$r = Test-VerifyMap -VerifyRoot $vr; Check '🔴 同一行有行內碼、{{…}} 在行內碼外 ⇒ 擋' (-not $r.Passed)
New-Feature 'feat-a' @('```', '# TODO 補指令', '```')
$r = Test-VerifyMap -VerifyRoot $vr; Check '🔴 程式碼區塊裡的 TODO 仍算佔位符 ⇒ 擋' (-not $r.Passed)
New-Feature 'feat-a' @('```', 'echo ok', '```', '2. 開 {{網址}}')
$r = Test-VerifyMap -VerifyRoot $vr; Check '🔴 程式碼區塊結束後的 {{…}} ⇒ 擋' (-not $r.Passed -and ($r.Reasons -join ' ') -match '第 \d+ 行')
New-Doc @('啟動網址 {{網址}}')
$r = Test-VerifyMap -VerifyRoot $vr; Check '🔴 驗證文件程式碼外的 {{…}} ⇒ 擋' (-not $r.Passed -and ($r.Reasons -join ' ') -match 'verify-test\.md 還有佔位符')
New-Doc

Write-Host "--- $tag 登入帳密寫法（AI 不讀密碼檔、不代打密碼）不算佔位符 ---"
New-Feature 'feat-a' @('2. 登入：帳號、密碼由使用者輸入（AI 不代打）', '3. 或由腳本讀環境變數 `APP_TEST_PASSWORD`（只寫名稱不寫值）')
$r = Test-VerifyMap -VerifyRoot $vr; Check '「由使用者輸入」「讀環境變數 X」⇒ 合格' $r.Passed
New-Feature 'feat-a'

Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue

if (-not $Inner) {
    $ps5 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if ($env:SystemRoot -and (Test-Path $ps5) -and $PSVersionTable.PSEdition -ne 'Desktop') {
        & $ps5 -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $PSCommandPath -Inner
        if ($LASTEXITCODE -ne 0) { $script:fail++ }
    }
    Write-Host ''
    if ($script:fail) { Write-Host "FAILED: $($script:fail)" -ForegroundColor Red; exit 1 } else { Write-Host 'ALL PASSED' -ForegroundColor Green }
} elseif ($script:fail) { exit 1 }
