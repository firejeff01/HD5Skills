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

Write-Host "--- $tag 站上關卡：退回後的新打通、待使用者動作連兩輪（2026-11-25，#2164；使用者拍板：只警告、不擋）---"
$case = Join-Path $root 'AI_Service\spec\case-r'
$qa = Join-Path $case 'qa'
New-Item -ItemType Directory -Force (Join-Path $qa 'onsite-gate_R2'), (Join-Path $qa 'onsite-gate_R1'), (Join-Path $case 'sa') | Out-Null
[IO.File]::WriteAllText((Join-Path $qa 'onsite-gate_R2\ac1.png'), 'x')
function Save-Case([string]$rel, [string[]]$lines) { [IO.File]::WriteAllLines((Join-Path $case $rel), $lines, [Text.UTF8Encoding]::new($false)) }
$aHead = @('## A. 驗收項目', '| 項目 | 功能 | 結果 | 證據 | 備註 |', '|---|---|---|---|---|')
function New-Gate([string]$name, [string]$date, [string[]]$rows, [string[]]$extra = @()) {
    Save-Case "qa\$name" (@("# 測試 站上關卡", '', "- 日期：$date 10:00", '') + $aHead + $rows + @('') + $extra + @('', '新發現：0 筆', '總結：通過'))
}
$okRow = '| AC-1 抓取 | feat-a | Pass | `ac1.png` | |'
$rlHead = @('# 退回紀錄', '| 輪次 | 退回原因 | 處理類別 | 根因類別 | 為什麼沒先抓到 | 修正 |', '|---|---|---|---|---|---|')
$gp = Join-Path $qa 'onsite-gate_R2.md'
function Gate { Test-OnsiteGateEvidence -Path $gp -FeatureIds @('feat-a', 'feat-b', 'feat-c') }
function Warn($x) { (@($x.Warnings) -join ' ') -replace '\s+', '' }
# 只警告：Passed 一律照舊（true），提醒放在 Warnings
function Warned($x, [string]$pat) { $x.Passed -and (Warn $x) -match $pat }
function Quiet($x) { $x.Passed -and @($x.Warnings).Count -eq 0 }

New-Gate 'onsite-gate_R2.md' '2026-11-25' @($okRow)
$r = Gate; Check '沒有退回紀錄 ⇒ 合格、沒有警告（原本行為不變）' (Quiet $r)
Save-Case 'qa\rework-log.md' ($rlHead + '| R1（11/25） | 某電號抓不到 | 程式錯誤 | 樣本不足 | 只測一個 | abc |')
$r = Gate; Check '退回 R1（11/25）之後的關卡沒有（新打通）也沒寫「新打通：無（理由）」⇒ 合格但警告，註明過渡條件' ((Warned $r '新打通') -and (Warn $r) -match '過渡：專案有自動化端到端回歸測試涵蓋該流程時可移除')
New-Gate 'onsite-gate_R2.md' '2026-11-25' @($okRow, '| AC-2 自動建立（新打通） | feat-a | Pass | `ac1.png` | 用當初失敗的電號 |')
$r = Gate; Check 'A 表有一列標（新打通）⇒ 沒有警告' (Quiet $r)
New-Gate 'onsite-gate_R2.md' '2026-11-25' @($okRow) @('新打通：無（本輪只改文案，沒有被擋住的後段流程）')
$r = Gate; Check '「新打通：無（理由）」⇒ 沒有警告' (Quiet $r)
New-Gate 'onsite-gate_R2.md' '2026-11-25' @($okRow) @('新打通：無')
$r = Gate; Check '「新打通：無」沒寫理由 ⇒ 警告' (Warned $r '新打通')
Save-Case 'qa\rework-log.md' ($rlHead + '| R1（12/01） | 某電號抓不到 | 程式錯誤 | 樣本不足 | 只測一個 | abc |')
New-Gate 'onsite-gate_R2.md' '2026-11-25' @($okRow)
$r = Gate; Check '最新退回日期晚於這份關卡 ⇒ 不提醒新打通' (Quiet $r)
Save-Case 'qa\rework-log.md' ($rlHead + '| R1（11/23） | a | 程式錯誤 | 修後沒重跑 | b | c |' + '| R2 | d | 新規則 | 規則定義晚 | e | f |')
$r = Gate; Check '最新一輪（R2）沒寫日期 ⇒ 保守視為在關卡之前 ⇒ 警告' (Warned $r '新打通')
New-Gate 'onsite-gate_R2.md' '2026-11-24' @($okRow)
$r = Gate; Check '關卡日期早於 2026-11-25 ⇒ 不回溯（沒有警告）' (Quiet $r)
Remove-Item -LiteralPath (Join-Path $qa 'rework-log.md')

Save-Case 'sa\external-samples.md' @('# 樣本', '| 變化 | 真實樣本 | 誰提供 | 開發階段實跑結果 |', '|---|---|---|---|', '| 帳期跨月 | 待提供（PM） | PM | — |')
New-Gate 'onsite-gate_R2.md' '2026-11-25' @($okRow)
$r = Gate; Check '外部樣本逐種列 A 項已拿掉（改由產品程式層的樣本契約測試）：A 表沒列樣本變化 ⇒ 合格、沒有警告' (Quiet $r)
Remove-Item -LiteralPath (Join-Path $case 'sa\external-samples.md')

$waitRow = '| AC-9 開機自動啟動 | feat-a | 未驗證（待使用者動作：設定開機自啟） | — | |'
New-Gate 'onsite-gate_R1.md' '2026-11-25' @($okRow, $waitRow)
New-Gate 'onsite-gate_R2.md' '2026-11-25' @($okRow, '| AC-9 開機自啟 | feat-a | 未驗證（待使用者動作：還沒設定） | — | |')
$r = Gate; Check '上一輪同一項（AC-9）也是「待使用者動作」⇒ 合格但警告' (Warned $r 'AC-9')
New-Gate 'onsite-gate_R2.md' '2026-11-25' @($okRow, '| AC-9 開機自啟 | feat-a | 未驗證（待使用者動作：還沒設定） | — | |') @('使用者放行：AC-9 開機自啟留到正式上線再驗（11-25）')
$r = Gate; Check '「使用者放行：AC-9 …（MM-DD）」⇒ 消除警告' (Quiet $r)
New-Gate 'onsite-gate_R2.md' '2026-11-25' @($okRow, '| AC-9 開機自啟 | feat-a | 未驗證（待使用者動作：還沒設定） | — | |') @('使用者放行：AC-7 另一項（11-25）')
$r = Gate; Check '放行寫的是別的項目 ⇒ AC-9 仍警告' (Warned $r 'AC-9')
New-Gate 'onsite-gate_R1.md' '2026-11-25' @($okRow, '| AC-9 開機自動啟動 | feat-a | 未驗證（缺資料） | — | |')
New-Gate 'onsite-gate_R2.md' '2026-11-25' @($okRow, '| AC-9 開機自啟 | feat-a | 未驗證（待使用者動作：還沒設定） | — | |')
$r = Gate; Check '上一輪是別的原因（缺資料）⇒ 沒有警告' (Quiet $r)
New-Gate 'onsite-gate_R1.md' '2026-11-25' @($okRow, $waitRow)
New-Gate 'onsite-gate_R1b.md' '2026-11-25' @($okRow, '| AC-9 開機自啟 | feat-a | Pass | `ac1.png` | |')
$r = Gate; Check '上一輪有 R1b ⇒ 以 R1b 為上一輪（已 Pass）⇒ 沒有警告' (Quiet $r)
Remove-Item -LiteralPath (Join-Path $qa 'onsite-gate_R1b.md')
Remove-Item -LiteralPath (Join-Path $qa 'onsite-gate_R1.md')

# verify-map-check.ps1 -Onsite 入口跟 lib 同一套判定：警告照印、exit 照舊
Save-Case 'qa\rework-log.md' ($rlHead + '| R1（11/25） | a | 程式錯誤 | 修後沒重跑 | b | c |')
New-Gate 'onsite-gate_R2.md' '2026-11-25' @($okRow)
$vmc = (Resolve-Path (Join-Path $PSScriptRoot '..\verify-map-check.ps1')).Path
$exe = (Get-Process -Id $PID).Path
$o = & $exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $vmc -VerifyRoot $vr -Onsite $gp 2>&1 | Out-String
Check 'verify-map-check.ps1 -Onsite 缺新打通 ⇒ exit 0、印警告' ($LASTEXITCODE -eq 0 -and ($o -replace '\s+', '') -match '警告.*新打通')
New-Gate 'onsite-gate_R2.md' '2026-11-25' @($okRow) @('新打通：無（只改文案）')
$o = & $exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $vmc -VerifyRoot $vr -Onsite $gp 2>&1 | Out-String
Check 'verify-map-check.ps1 -Onsite 補上新打通 ⇒ exit 0、沒有警告' ($LASTEXITCODE -eq 0 -and $o -notmatch '警告')

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
