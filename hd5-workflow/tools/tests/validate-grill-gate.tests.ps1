<#
.SYNOPSIS
  validate-grill-gate.ps1 離線測試（暫存資料夾造 case 與一份「依地圖規則產生的合格功能地圖」；不依賴專案自己的 verify/，母版也能跑）。
  執行：pwsh -File tests/validate-grill-gate.tests.ps1（也會用 Windows PowerShell 5.1 跑一輪）；最後一行要是 ALL PASSED。
  2026-11-25：閘改在本程序內呼叫（& 腳本；腳本的 exit 只結束它自己），5.1 那一輪整支用 -Inner 在 5.1 裡再跑一次。
  原本每個情境都開一個 PowerShell 程序（約 1.3 秒／次），情境加到 80 多個後超過 install.ps1 跑測試的 180 秒上限。
  開程序（-File）的 exit 碼語意另留幾個情境驗（見「-File 開程序」段）。
#>
param([switch]$Inner)
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
$gate = (Resolve-Path (Join-Path $PSScriptRoot '..\validate-grill-gate.ps1')).Path
$libCand = @((Join-Path $PSScriptRoot '..\_verify-map-lib.ps1'), (Join-Path $PSScriptRoot '..\..\..\..\..\agent\scripts\_verify-map-lib.ps1'))   # HD5Skills tools／IMOCore 舊位置
$lib = (Resolve-Path ($libCand | Where-Object { Test-Path $_ } | Select-Object -First 1)).Path
. $lib
# 依 _verify-map-lib.ps1 的節名規格產生最小合格地圖（規格改了這裡跟著變，不寫死節名）
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('grillgate_map_' + [guid]::NewGuid().ToString('N'))
$realVerify = Join-Path $fixtureRoot 'verify'
New-Item -ItemType Directory -Force (Join-Path $realVerify 'features') | Out-Null
$doc = @('# 驗證文件（測試用）', '') + @($script:VerifyDocSections | ForEach-Object { "## $($_.Label)"; '測試用內容。'; '' })
Set-Content -LiteralPath (Join-Path $realVerify 'verify-test.md') $doc -Encoding UTF8
Set-Content -LiteralPath (Join-Path $realVerify 'features\README.md') '# 功能地圖共同前提（測試用）' -Encoding UTF8
foreach ($id in 'feat-alpha', 'feat-beta', 'feat-gamma') {
    $body = @("# $id", '測試用功能。', '') + @($script:FeatureSections | ForEach-Object {
        "## $($_.Label)"; if ($_.Key -eq 'Driving it') { '前提：測試帳號。'; '1. 開頁 → 看到清單' } else { '- 測試用內容' }; '' })
    Set-Content -LiteralPath (Join-Path $realVerify "features\$id.md") $body -Encoding UTF8
}
$fixtureCheck = Test-VerifyMap -VerifyRoot $realVerify
if (-not $fixtureCheck.Passed) { Write-Host "測試用地圖不合格（測試本身壞了）：$($fixtureCheck.Reasons -join '；')" -ForegroundColor Red; exit 1 }
$existing = 'feat-alpha'
$script:hasLegacyAlias = $false
# 讀質詢閘會讀的那份 workflow.json：用同一支 _hd5-locate.ps1 從閘的位置往上找
try { $loc = @((Join-Path $PSScriptRoot '..\_hd5-locate.ps1'), (Join-Path $PSScriptRoot '..\..\..\..\..\agent\scripts\_hd5-locate.ps1')) | Where-Object { Test-Path $_ } | Select-Object -First 1
      if ($loc) { . $loc; $wfj = (Get-HD5Project -Start (Split-Path $gate -Parent)).Workflow } else { $wfj = Get-Content -Raw (Join-Path $PSScriptRoot '..\..\..\..\..\..\.claude\workflow.json') -Encoding UTF8 | ConvertFrom-Json }
      $script:hasLegacyAlias = @($wfj.implementers | ForEach-Object { $_.gateAliases }) -contains 'csharp' } catch { }
$script:fail = 0
function Check($name, $cond) { if ($cond) { Write-Host "  ok   $name" } else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:fail++ } }
# 2026-11-25 使用者拍板：exit 14～16 改成警告——照樣判斷，exit 碼照舊（不擋派發），stdout 印「grill-gate 警告：…」
function Warned($r, [string]$pat) { $r.Code -eq 0 -and (($r.Out -replace '\s+', '') -match ('grill-gate警告：.*' + [regex]::Escape(($pat -replace '\s+', '')))) }

$b = [IO.File]::ReadAllBytes($gate)
Check 'BOM（Windows PowerShell 5.1 讀中文訊息）' ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)

# 預設＝四角色路線，pm/、sa/ 都有拍板紀錄。$route 給空字串＝不寫路線。
function New-Case([string]$featureText, [string]$route = '四角色') {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('grillgate_' + [guid]::NewGuid().ToString('N'))
    $case = Join-Path $root 'AI_Service\spec\case-x'
    New-Item -ItemType Directory -Force (Join-Path $case 'pm'), (Join-Path $case 'sa'), (Join-Path $case 'case_spec_content') | Out-Null
    Set-Content (Join-Path $case 'pm\grill-x.md') '質詢輪結束：已拍板' -Encoding UTF8
    Set-Content (Join-Path $case 'sa\grill-x.md') "質詢輪結束：已拍板`n`n## 設計形狀`n資料形狀：狀態用列舉（已拍板）" -Encoding UTF8
    $spec = "## 5. 驗收條件`n- [ ] x"
    if ($route) { $spec += "`n`n路線：$route，高風險：否，外部系統：無，理由：測試" }
    Set-Content (Join-Path $case 'case_spec_content\spec_001.md') $spec -Encoding UTF8
    if ($null -ne $featureText) { Set-Content (Join-Path $case 'sa\x.feature') $featureText -Encoding UTF8 }
    return [pscustomobject]@{ Root = $root; Case = $case }
}
# 小問題路線：沒有 pm/；SA 寫 sa/bug-analysis.md
function New-BugCase([string]$specExtra = '', [string]$analysis) {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('grillgate_' + [guid]::NewGuid().ToString('N'))
    $case = Join-Path $root 'AI_Service\spec\bug-y'
    New-Item -ItemType Directory -Force (Join-Path $case 'case_spec_content') | Out-Null
    Set-Content (Join-Path $case 'case_spec_content\spec_001.md') "## 5. 驗收條件`n- [ ] 匯入更新寫回$specExtra`n`n**路線**：小問題，**高風險**：否，**外部系統**：無，理由：單一匯入方法" -Encoding UTF8
    if ($null -ne $analysis) {
        New-Item -ItemType Directory -Force (Join-Path $case 'sa') | Out-Null
        Set-Content (Join-Path $case 'sa\bug-analysis.md') $analysis -Encoding UTF8
    }
    return [pscustomobject]@{ Root = $root; Case = $case }
}
$fullAnalysis = "# bug 分析`n## 原因`nNoTracking`n## 影響範圍`n匯入`n## 同類位置`n2 處`n## 修法`nAsTracking`n## 待決事項`n待決事項：無"

$selfExe = (Get-Process -Id $PID).Path   # 5.1 沒有 [Environment]::ProcessPath
$ps5 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$cases = @()
foreach ($exe in @($selfExe)) {
    $tag = if ($PSVersionTable.PSEdition -eq 'Desktop') { '[PS5.1]' } else { '[pwsh]' }
    # 本程序內呼叫：閘用 Write-Error＋exit N；這裡把 ErrorActionPreference 放寬成 Continue 才不會被 Stop 轉成例外，exit N 會留在 $LASTEXITCODE
    function Run([string[]]$a) {
        # 字串陣列展開給腳本時「-Role」會被當成位置參數 ⇒ 轉成雜湊表（沒有值的是 switch，例 -Skip）
        $h = @{}
        for ($i = 0; $i -lt $a.Count; $i++) {
            $k = $a[$i].TrimStart('-')
            if ($i + 1 -lt $a.Count -and -not $a[$i + 1].StartsWith('-')) { $h[$k] = $a[$i + 1]; $i++ } else { $h[$k] = [switch]$true }
        }
        $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'; $global:LASTEXITCODE = 0
        try { $o = & $gate @h 2>&1 | Out-String -Width 400; $code = $LASTEXITCODE } catch { $o = "例外：$($_.Exception.Message)"; $code = -1 } finally { $ErrorActionPreference = $eap }
        [pscustomobject]@{ Code = $code; Out = $o }
    }
    # 開程序跑（-File）：只留幾個情境驗 exit 碼語意（hook 與 Codex 都是開程序呼叫）
    # （5.1：原生程序的 stderr 在 ErrorActionPreference=Stop 下會變成例外，這裡同樣放寬成 Continue）
    function RunFile([string[]]$a) {
        $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try { $o = & $exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $gate @a 2>&1 | Out-String; $code = $LASTEXITCODE } finally { $ErrorActionPreference = $eap }
        [pscustomobject]@{ Code = $code; Out = $o }
    }

    Write-Host "--- $tag -File 開程序：exit 碼照腳本的 exit N ---"
    $fc = New-Case "@功能:$existing"; $cases += $fc
    $r = RunFile @('-Role', 'backend', '-CasePath', $fc.Case, '-VerifyRoot', $realVerify); Check "$tag -File 合格案 ⇒ exit 0" ($r.Code -eq 0 -and $r.Out -match 'GRILL_GATE=pass')
    Set-Content (Join-Path $fc.Case 'case_spec_content\spec_001.md') "路線：四角色，高風險：否，理由：沒寫外部系統" -Encoding UTF8
    $r = RunFile @('-Role', 'sa', '-CasePath', $fc.Case); Check "$tag -File 沒寫外部系統 ⇒ 警告（exit 0）" ((Warned $r '外部系統'))
    Set-Content (Join-Path $fc.Case 'case_spec_content\spec_001.md') "## 5" -Encoding UTF8
    $r = RunFile @('-Role', 'sa', '-CasePath', $fc.Case); Check "$tag -File 沒寫路線 ⇒ exit 8" ($r.Code -eq 8)

    Write-Host "--- $tag 原本的質詢閘行為不變（四角色路線）---"
    $c = New-Case "@功能:$existing`nFeature: x"; $cases += $c
    $r = Run @('-Role', 'sa', '-CasePath', $c.Case); Check "$tag -Role sa 不檢查功能地圖 ⇒ pass" ($r.Code -eq 0 -and $r.Out -match 'GRILL_GATE=pass role=sa' -and $r.Out -match 'route=四角色')
    $r = Run @('-Role', 'pm', '-CasePath', $c.Case); Check "$tag -Role pm ⇒ pass" ($r.Code -eq 0)

    Write-Host "--- $tag 角色通用化（2026-11-23：實作角色讀 .claude/workflow.json，舊名當別名）---"
    $r = Run @('-Role', 'backend', '-CasePath', $c.Case, '-VerifyRoot', $realVerify); Check "$tag -Role backend ⇒ pass" ($r.Code -eq 0 -and $r.Out -match 'role=backend')
    $r = Run @('-Role', 'frontend', '-CasePath', $c.Case, '-VerifyRoot', $realVerify); Check "$tag -Role frontend ⇒ pass" ($r.Code -eq 0 -and $r.Out -match 'role=frontend')
    # 舊名別名（IMOCore 過渡期 csharp／vue3）：只在本專案 .claude/workflow.json 有設時才測（新專案的 generic 設定沒有）
    if ($script:hasLegacyAlias) {
        $r = Run @('-Role', 'csharp', '-CasePath', $c.Case, '-VerifyRoot', $realVerify); Check "$tag 舊名 csharp 當別名 ⇒ 換成 backend" ($r.Code -eq 0 -and $r.Out -match 'role=backend')
        $r = Run @('-Role', 'vue3', '-CasePath', $c.Case, '-VerifyRoot', $realVerify); Check "$tag 舊名 vue3 當別名 ⇒ 換成 frontend" ($r.Code -eq 0 -and $r.Out -match 'role=frontend')
    } else { Write-Host "  ok   $tag （本專案 workflow.json 沒有舊名別名，略過別名測試）" }
    $r = Run @('-Role', 'python', '-CasePath', $c.Case); Check "$tag 設定檔沒有的角色 ⇒ exit 1 並列出可用角色" ($r.Code -eq 1 -and ($r.Out -replace '\s+', '') -match 'backend')

    Write-Host "--- $tag 功能地圖閘 ---"
    $r = Run @('-Role', 'backend', '-CasePath', $c.Case, '-VerifyRoot', $realVerify)
    Check "$tag 標了存在的功能 ⇒ pass 並列出編號" ($r.Code -eq 0 -and $r.Out -match "features=$existing")

    $c2 = New-Case $null; $cases += $c2
    $r = Run @('-Role', 'backend', '-CasePath', $c2.Case, '-VerifyRoot', $realVerify)
    Check "$tag sa 沒有 *.feature ⇒ exit 5" ($r.Code -eq 5)

    $c3 = New-Case "Feature: 沒標功能"; $cases += $c3
    $r = Run @('-Role', 'frontend', '-CasePath', $c3.Case, '-VerifyRoot', $realVerify)
    Check "$tag 沒標 @功能 ⇒ exit 5（vue3 也檢查）" ($r.Code -eq 5)
    $r = Run @('-Role', 'qa', '-CasePath', $c3.Case, '-VerifyRoot', $realVerify)
    Check "$tag 沒標 @功能 ⇒ exit 5（qa 也檢查）" ($r.Code -eq 5)

    $c4 = New-Case "@功能:$existing @功能:zz-not-in-map`nFeature: x"; $cases += $c4
    $r = Run @('-Role', 'backend', '-CasePath', $c4.Case, '-VerifyRoot', $realVerify)
    # PS 5.1 的 Write-Error 會依主控台寬度折行（實測把 zz- 與 not-in-map 拆到兩行）⇒ 先去掉空白換行再比對
    Check "$tag 標了地圖沒有的功能 ⇒ exit 7 並點名檔案" ($r.Code -eq 7 -and ($r.Out -replace '\s+', '') -match 'zz-not-in-map\.md')
    $c5 = New-Case "@功能:$existing @功能:Bad_Id`nFeature: x"; $cases += $c5
    $r = Run @('-Role', 'backend', '-CasePath', $c5.Case, '-VerifyRoot', $realVerify)
    Check "$tag 功能編號有大寫或底線 ⇒ exit 7 並點名（不靜默當成沒標）" ($r.Code -eq 7 -and ($r.Out -replace '\s+', '') -match 'Bad_Id')

    $c5 = New-Case "@功能：$existing`nFeature: 全形冒號"; $cases += $c5
    $r = Run @('-Role', 'backend', '-CasePath', $c5.Case, '-VerifyRoot', $realVerify)
    Check "$tag 全形冒號 @功能： 也認得" ($r.Code -eq 0 -and $r.Out -match "features=$existing")

    $emptyVerify = Join-Path $c.Root 'emptyverify'; New-Item -ItemType Directory -Force $emptyVerify | Out-Null
    $r = Run @('-Role', 'backend', '-CasePath', $c.Case, '-VerifyRoot', $emptyVerify)
    Check "$tag 功能地圖不合格 ⇒ exit 6" ($r.Code -eq 6)

    $r = Run @('-Role', 'backend', '-CasePath', $c3.Case, '-SkipFeatureMap', '本規則生效前已進 PG')
    Check "$tag -SkipFeatureMap 理由 ⇒ pass 並印出理由" ($r.Code -eq 0 -and $r.Out -match 'feature-map=skip')

    Write-Host "--- $tag 路線閘（2026-11-23）---"
    $c6 = New-Case "@功能:$existing" ''; $cases += $c6
    $r = Run @('-Role', 'backend', '-CasePath', $c6.Case, '-VerifyRoot', $realVerify)
    Check "$tag 🔴 spec_001 沒寫路線 ⇒ exit 8" ($r.Code -eq 8)
    $r = Run @('-Role', 'sa', '-CasePath', $c6.Case)
    Check "$tag 沒寫路線，派 SA 也擋（exit 8）" ($r.Code -eq 8)
    $r = Run @('-Role', 'backend', '-CasePath', $c.Case, '-Skip', '-VerifyRoot', $realVerify)
    Check "$tag 🔴 四角色路線帶 -Skip ⇒ exit 9" ($r.Code -eq 9)
    $r = Run @('-Role', 'backend', '-CasePath', $c6.Case, '-SkipRoute', '11-23 前已進 PG', '-Skip', '-VerifyRoot', $realVerify)
    Check "$tag 舊案 -SkipRoute 理由＋-Skip ⇒ pass（route=skip、grill=skip）" ($r.Code -eq 0 -and $r.Out -match 'route=skip' -and $r.Out -match 'grill=skip')
    $c7 = New-Case "@功能:$existing" 'PM 端已完成'; $cases += $c7
    $r = Run @('-Role', 'sa', '-CasePath', $c7.Case)
    Check "$tag 「PM 端已完成」（中間有空白）認得，派 SA 檢查 pm/ 拍板" ($r.Code -eq 0 -and $r.Out -match 'route=PM端已完成' -and $r.Out -match 'upstream=pm')
    Remove-Item -LiteralPath (Join-Path $c7.Case 'pm') -Recurse -Force
    $r = Run @('-Role', 'sa', '-CasePath', $c7.Case)
    Check "$tag PM 端已完成但 pm/ 沒放進來 ⇒ exit 2" ($r.Code -eq 2)

    Write-Host "--- $tag 高風險與對抗輪（2026-11-23）---"
    $rc = New-Case "@功能:$existing"; $cases += $rc
    $sp = Join-Path $rc.Case 'case_spec_content\spec_001.md'
    Set-Content $sp "## 5. 驗收條件`n- [ ] x`n`n路線：四角色，理由：沒寫高風險" -Encoding UTF8
    $r = Run @('-Role', 'backend', '-CasePath', $rc.Case, '-VerifyRoot', $realVerify)
    Check "$tag 🔴 路線沒寫高風險 ⇒ exit 11" ($r.Code -eq 11)
    Set-Content $sp "## 5. 驗收條件`n- [ ] x`n`n路線：四角色，高風險：是，外部系統：無，理由：動到權限" -Encoding UTF8
    $r = Run @('-Role', 'sa', '-CasePath', $rc.Case)
    Check "$tag 高風險派 SA 還不需要對抗輪 ⇒ pass" ($r.Code -eq 0 -and $r.Out -match 'risk=high')
    $r = Run @('-Role', 'backend', '-CasePath', $rc.Case, '-VerifyRoot', $realVerify)
    Check "$tag 🔴 高風險沒有對抗輪就派 PG ⇒ exit 11" ($r.Code -eq 11)
    Set-Content (Join-Path $rc.Case 'sa\adversarial-review.md') "# 對抗輪`nA1 SQL 聚合錯誤：待修`n對抗結論：" -Encoding UTF8
    $r = Run @('-Role', 'qa', '-CasePath', $rc.Case, '-VerifyRoot', $realVerify)
    Check "$tag 對抗輪問題還沒處理完 ⇒ exit 11" ($r.Code -eq 11)
    Set-Content (Join-Path $rc.Case 'sa\adversarial-review.md') "# 對抗輪`nA1 SQL 聚合錯誤：已修正（改 CTE）`n對抗結論：SA 已修正後可進 PG" -Encoding UTF8
    $r = Run @('-Role', 'backend', '-CasePath', $rc.Case, '-VerifyRoot', $realVerify)
    Check "$tag 對抗輪處理完 ⇒ pass 並列出檔名" ($r.Code -eq 0 -and $r.Out -match 'adversarial=sa/adversarial-review\.md')
    Set-Content $sp "## 5. 驗收條件`n- [ ] x`n`n**路線**：四角色，**高風險**：是，外部系統：無，理由：粗體也認" -Encoding UTF8
    $r = Run @('-Role', 'backend', '-CasePath', $rc.Case, '-VerifyRoot', $realVerify)
    Check "$tag 粗體「**高風險**：是」也認得" ($r.Code -eq 0 -and $r.Out -match 'risk=high')

    Write-Host "--- $tag 小問題路線：先派 SA 盤查，SA 文件寫完才派 PG ---"
    $bc = New-BugCase "（@功能:$existing）" $null; $cases += $bc
    $r = Run @('-Role', 'sa', '-CasePath', $bc.Case)
    Check "$tag 小問題派 SA 不需要 pm/ ⇒ pass" ($r.Code -eq 0 -and $r.Out -match 'route=小問題')
    $r = Run @('-Role', 'backend', '-CasePath', $bc.Case, '-VerifyRoot', $realVerify)
    Check "$tag 🔴 小問題沒有 sa/bug-analysis.md ⇒ exit 10（緊急也不例外）" ($r.Code -eq 10)
    $r = Run @('-Role', 'backend', '-CasePath', $bc.Case, '-Skip', '-VerifyRoot', $realVerify)
    Check "$tag 小問題帶 -Skip ⇒ exit 9" ($r.Code -eq 9)
    $bc2 = New-BugCase "（@功能:$existing）" $fullAnalysis; $cases += $bc2
    $r = Run @('-Role', 'backend', '-CasePath', $bc2.Case, '-VerifyRoot', $realVerify)
    Check "$tag 四節＋「待決事項：無」⇒ pass" ($r.Code -eq 0 -and $r.Out -match 'upstream=sa/bug-analysis\.md' -and $r.Out -match "features=$existing")
    $bc3 = New-BugCase "（@功能:$existing）" ($fullAnalysis -replace '## 同類位置', '## 其他'); $cases += $bc3
    $r = Run @('-Role', 'qa', '-CasePath', $bc3.Case, '-VerifyRoot', $realVerify)
    Check "$tag 缺「同類位置」小節 ⇒ exit 10 並點名" ($r.Code -eq 10 -and ($r.Out -replace '\s+', '') -match '同類位置')
    $bc4 = New-BugCase "（@功能:$existing）" ($fullAnalysis -replace '待決事項：無', 'Q1 要不要退回？'); $cases += $bc4
    $r = Run @('-Role', 'backend', '-CasePath', $bc4.Case, '-VerifyRoot', $realVerify)
    Check "$tag 有待決題沒拍板 ⇒ exit 10" ($r.Code -eq 10)
    $bc5 = New-BugCase "（@功能:$existing）" ($fullAnalysis -replace '待決事項：無', 'Q1 要退回：已拍板'); $cases += $bc5
    $r = Run @('-Role', 'backend', '-CasePath', $bc5.Case, '-VerifyRoot', $realVerify)
    Check "$tag 待決題已拍板 ⇒ pass" ($r.Code -eq 0)
    $bc6 = New-BugCase '' ($fullAnalysis + "`n@功能:$existing"); $cases += $bc6
    $r = Run @('-Role', 'backend', '-CasePath', $bc6.Case, '-VerifyRoot', $realVerify)
    Check "$tag SA 在 bug-analysis.md 標 @功能 也認得" ($r.Code -eq 0 -and $r.Out -match "features=$existing")
    $bc7 = New-BugCase '' $fullAnalysis; $cases += $bc7
    $r = Run @('-Role', 'backend', '-CasePath', $bc7.Case, '-VerifyRoot', $realVerify)
    Check "$tag 🔴 小問題也要標功能：都沒標 ⇒ exit 5" ($r.Code -eq 5)
    Set-Content (Join-Path $bc7.Case 'case_spec_content\..\pg\fix-plan.md') "影響功能：@功能:$existing" -Encoding UTF8 -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force (Join-Path $bc7.Case 'pg') | Out-Null
    Set-Content (Join-Path $bc7.Case 'pg\fix-plan.md') "影響功能：@功能:$existing" -Encoding UTF8
    $r = Run @('-Role', 'backend', '-CasePath', $bc7.Case, '-VerifyRoot', $realVerify)
    Check "$tag pg/*.md 標功能也認得" ($r.Code -eq 0 -and $r.Out -match "features=$existing")

    Write-Host "--- $tag 待拍板閘（2026-11-24，exit 12）---"
    $pc = New-Case "@功能:$existing"; $cases += $pc
    $sg = Join-Path $pc.Case 'sa\grill-x.md'
    Set-Content $sg "# SA 質詢`nQ-01 用哪張表：已拍板（使用者 11-24）`nQ-02 要不要分頁？建議 A [待確認]" -Encoding UTF8
    $r = Run @('-Role', 'backend', '-CasePath', $pc.Case, '-VerifyRoot', $realVerify)
    Check "$tag 🔴 sa/grill 有 [待確認] 沒拍板 ⇒ exit 12 並點名檔:行" ($r.Code -eq 12 -and ($r.Out -replace '\s+', '') -match 'sa/grill-x\.md:3')
    $r = Run @('-Role', 'sa', '-CasePath', $pc.Case)
    Check "$tag 派 SA 不檢查待拍板（只擋實作／QA）" ($r.Code -eq 0)
    Set-Content $sg "Q-01：已拍板`nQ-02 要不要分頁？待拍板 → 已轉單（需求問卷 r2）" -Encoding UTF8
    $r = Run @('-Role', 'qa', '-CasePath', $pc.Case, '-VerifyRoot', $realVerify)
    Check "$tag 同一行標已轉單 ⇒ pass（pending=0）" ($r.Code -eq 0 -and $r.Out -match 'pending=0')
    Set-Content $sg "Q-01：已拍板`nQ-02 要不要分頁？建議 A [待確認] → 已拍板 A（使用者 11-24）`n待拍板：無`n待拍板 0 題" -Encoding UTF8
    $r = Run @('-Role', 'backend', '-CasePath', $pc.Case, '-VerifyRoot', $realVerify)
    Check "$tag 同一行後面已拍板、「待拍板：無／0 題」總結行 ⇒ pass" ($r.Code -eq 0)
    Set-Content (Join-Path $pc.Case 'pm\grill-x.md') "Q-P1 範圍：已拍板`nQ-P2 日期格式：待拍板" -Encoding UTF8
    $r = Run @('-Role', 'frontend', '-CasePath', $pc.Case, '-VerifyRoot', $realVerify)
    Check "$tag 🔴 pm/grill 有待拍板 ⇒ 派實作也擋（exit 12）" ($r.Code -eq 12 -and ($r.Out -replace '\s+', '') -match 'pm/grill-x\.md:2')
    $sp2 = Join-Path $pc.Case 'case_spec_content\spec_001.md'
    Set-Content $sp2 "## 5. 驗收條件`n- [ ] x" -Encoding UTF8
    $r = Run @('-Role', 'backend', '-CasePath', $pc.Case, '-SkipRoute', '舊案', '-Skip', '-VerifyRoot', $realVerify)
    Check "$tag 舊案 -SkipRoute＋-Skip ⇒ 待拍板閘一起跳過" ($r.Code -eq 0 -and $r.Out -match 'grill=skip')

    Write-Host "--- $tag PM 問卷回收閘（2026-11-24，exit 13）---"
    $qc = New-Case "@功能:$existing" 'PM 端已完成'; $cases += $qc
    Set-Content (Join-Path $qc.Case 'pm\spec_9_r1.html') '<html>問卷</html>' -Encoding UTF8
    $r = Run @('-Role', 'sa', '-CasePath', $qc.Case)
    Check "$tag 🔴 PM 端已完成、pm/spec_9_r1.html 沒有 answer ⇒ exit 13 並點名" ($r.Code -eq 13 -and ($r.Out -replace '\s+', '') -match 'spec_9_r1\.html')
    Set-Content (Join-Path $qc.Case 'case_spec_content\spec_9_r1_answer_王.html') '<html>答覆</html>' -Encoding UTF8
    $r = Run @('-Role', 'sa', '-CasePath', $qc.Case)
    Check "$tag case_spec_content/ 有 spec_9_r1_answer_*.html ⇒ pass" ($r.Code -eq 0 -and $r.Out -match 'answers=1')
    New-Item -ItemType Directory -Force (Join-Path $qc.Case 'case_spec_content\attachments') | Out-Null
    Set-Content (Join-Path $qc.Case 'case_spec_content\attachments\spec_9_r2.html') '<html>第二輪</html>' -Encoding UTF8
    $r = Run @('-Role', 'backend', '-CasePath', $qc.Case, '-VerifyRoot', $realVerify)
    Check "$tag attachments/ 的第二輪問卷沒答覆 ⇒ 派實作也擋（exit 13）" ($r.Code -eq 13 -and ($r.Out -replace '\s+', '') -match 'spec_9_r2\.html' -and ($r.Out -replace '\s+', '') -notmatch 'spec_9_r1\.html')
    Set-Content (Join-Path $qc.Case 'pm\spec_9_r2_answer.html') '<html>答覆</html>' -Encoding UTF8
    $r = Run @('-Role', 'backend', '-CasePath', $qc.Case, '-VerifyRoot', $realVerify)
    Check "$tag 兩輪都有答覆 ⇒ pass" ($r.Code -eq 0 -and $r.Out -match 'answers=2')
    Set-Content (Join-Path $c.Case 'pm\spec_9_r1.html') '<html>問卷</html>' -Encoding UTF8
    $r = Run @('-Role', 'sa', '-CasePath', $c.Case)
    Check "$tag 四角色路線不檢查問卷回收（PM 自己在流程內收）" ($r.Code -eq 0)
    Remove-Item -LiteralPath (Join-Path $c.Case 'pm\spec_9_r1.html')

    Write-Host "--- $tag 外部系統宣告與樣本對照表（2026-11-25，exit 14／15；#2164 R1 樣本不足）---"
    $ec = New-Case "@功能:$existing"; $cases += $ec
    $esp = Join-Path $ec.Case 'case_spec_content\spec_001.md'
    Set-Content $esp "## 5. 驗收條件`n- [ ] x`n`n路線：四角色，高風險：否，理由：沒寫外部系統" -Encoding UTF8
    $r = Run @('-Role', 'sa', '-CasePath', $ec.Case)
    Check "$tag 🔴 spec_001 沒寫「外部系統：有｜無」⇒ 派 SA 印警告、不擋（exit 0）" ((Warned $r '外部系統') -and ($r.Out -replace '\s+', '') -match '外部系統')
    $r = Run @('-Role', 'backend', '-CasePath', $ec.Case, '-VerifyRoot', $realVerify)
    Check "$tag 沒寫外部系統 ⇒ 派實作也印警告、不擋（exit 0）" ((Warned $r '外部系統'))
    $r = Run @('-Role', 'backend', '-CasePath', $ec.Case, '-SkipRoute', '11-25 前已進 PG', '-Skip', '-VerifyRoot', $realVerify)
    Check "$tag 舊案 -SkipRoute＋-Skip ⇒ 外部系統宣告一起略過" ($r.Code -eq 0 -and $r.Out -match 'route=skip')
    Set-Content $esp "## 5. 驗收條件`n- [ ] x`n`n路線：四角色，高風險：否，理由：另一行寫`n**外部系統**：無" -Encoding UTF8
    $r = Run @('-Role', 'backend', '-CasePath', $ec.Case, '-VerifyRoot', $realVerify)
    Check "$tag 「外部系統：無」寫在另一行（粗體）也認得 ⇒ pass（external=no）" ($r.Code -eq 0 -and $r.Out -match 'external=no' -and $r.Out -notmatch 'grill-gate 警告')
    Set-Content $esp "## 5. 驗收條件`n- [ ] x`n`n路線：四角色，高風險：否，外部系統：有，理由：抓台電網頁" -Encoding UTF8
    $r = Run @('-Role', 'sa', '-CasePath', $ec.Case)
    Check "$tag 外部系統：有、派 SA 還不需要樣本表（SA 負責寫）⇒ pass" ($r.Code -eq 0 -and $r.Out -match 'external=yes')
    $r = Run @('-Role', 'backend', '-CasePath', $ec.Case, '-VerifyRoot', $realVerify)
    Check "$tag 🔴 外部系統：有但沒有 sa/external-samples.md ⇒ 派實作印警告、不擋（exit 0）" ((Warned $r 'external-samples') -and ($r.Out -replace '\s+', '') -match 'external-samples\.md')
    $smp = Join-Path $ec.Case 'sa\external-samples.md'
    Set-Content $smp "# 外部系統樣本`n（還沒整理）" -Encoding UTF8
    $r = Run @('-Role', 'qa', '-CasePath', $ec.Case, '-VerifyRoot', $realVerify)
    Check "$tag 樣本檔沒有樣本表 ⇒ 警告（exit 0）" ((Warned $r 'external-samples'))
    Set-Content $smp "# 外部系統樣本`n| 變化 | 真實樣本 | 誰提供 | 開發階段實跑結果 |`n|---|---|---|---|" -Encoding UTF8
    $r = Run @('-Role', 'qa', '-CasePath', $ec.Case, '-VerifyRoot', $realVerify)
    Check "$tag 樣本表一列都沒有 ⇒ 警告（exit 0）" ((Warned $r 'external-samples'))
    Set-Content $smp "# 外部系統樣本`n| 變化 | 真實樣本 | 誰提供 | 開發階段實跑結果 |`n|---|---|---|---|`n| 高壓電力 | 電號 16776680211 | 開發 | 通過 |`n| 表燈營業用 |  | PM | — |" -Encoding UTF8
    $r = Run @('-Role', 'backend', '-CasePath', $ec.Case, '-VerifyRoot', $realVerify)
    Check "$tag 🔴 有一列「真實樣本」空白 ⇒ 警告（exit 0） 並點名那種變化" ((Warned $r 'external-samples') -and ($r.Out -replace '\s+', '') -match '表燈營業用')
    Set-Content $smp "# 外部系統樣本`n| 變化 | 真實樣本 | 誰提供 | 開發階段實跑結果 |`n|---|---|---|---|`n| 高壓電力 | 電號 16776680211 | 開發 | 通過 |`n| 表燈營業用 | 待提供 | PM | — |" -Encoding UTF8
    $r = Run @('-Role', 'backend', '-CasePath', $ec.Case, '-VerifyRoot', $realVerify)
    Check "$tag 「待提供」沒寫誰 ⇒ 警告（exit 0）" ((Warned $r 'external-samples') -and ($r.Out -replace '\s+', '') -match '表燈營業用')
    Set-Content $smp "# 外部系統樣本`n| 變化 | 真實樣本 | 誰提供 | 開發階段實跑結果 |`n|---|---|---|---|`n| 高壓電力 | 電號 16776680211 | 開發 | 通過 |`n| 表燈營業用 | 待提供（PM 黃） | PM | — |" -Encoding UTF8
    $r = Run @('-Role', 'backend', '-CasePath', $ec.Case, '-VerifyRoot', $realVerify)
    Check "$tag 每列有樣本或「待提供（誰）」⇒ pass（samples=2）" ($r.Code -eq 0 -and $r.Out -match 'samples=2' -and $r.Out -notmatch 'grill-gate 警告')

    Write-Host "--- $tag 驗收退回的新規則要先補質詢（2026-11-25，exit 16；#2164 R3／R4 規則定義晚）---"
    $wc = New-Case "@功能:$existing"; $cases += $wc
    New-Item -ItemType Directory -Force (Join-Path $wc.Case 'qa') | Out-Null
    $rl = Join-Path $wc.Case 'qa\rework-log.md'
    $rlHead = "# 退回紀錄`n| 輪次 | 退回原因 | 處理類別 | 根因類別 | 為什麼沒先抓到 | 修正 |`n|---|---|---|---|---|---|"
    Set-Content $rl "$rlHead`n| R1（11/23） | 某電號抓不到 | 程式錯誤 | 樣本不足 | 只測一個電號 | abc123 |" -Encoding UTF8
    $r = Run @('-Role', 'backend', '-CasePath', $wc.Case, '-VerifyRoot', $realVerify)
    Check "$tag 退回紀錄只有程式錯誤 ⇒ 不要求驗收回合 ⇒ pass、沒警告" ($r.Code -eq 0 -and $r.Out -notmatch 'grill-gate 警告')
    Set-Content $rl "$rlHead`n| R1（11/23） | 某電號抓不到 | 程式錯誤 | 樣本不足 | 只測一個電號 | abc123 |`n| R3（11/24） | 只按確定也算修改 | 新規則 | 規則定義晚 | 拿修改人代替值有沒有變 | — |" -Encoding UTF8
    $r = Run @('-Role', 'backend', '-CasePath', $wc.Case, '-VerifyRoot', $realVerify)
    Check "$tag 🔴 有「新規則」退回、grill 沒有「驗收回合」小節 ⇒ 派實作印警告、不擋（exit 0）並點名輪次" ((Warned $r '驗收回合') -and ($r.Out -replace '\s+', '') -match 'R3')
    $r = Run @('-Role', 'sa', '-CasePath', $wc.Case)
    Check "$tag 派 SA 不檢查驗收回合（只看實作／QA）、沒警告" ($r.Code -eq 0 -and $r.Out -notmatch 'grill-gate 警告')
    Set-Content (Join-Path $wc.Case 'pm\grill-x.md') "質詢輪結束：已拍板`n`n## 驗收回合 R2（11-23）`nQ-20 期間推定：已拍板（PM 11-23）" -Encoding UTF8
    $r = Run @('-Role', 'qa', '-CasePath', $wc.Case, '-VerifyRoot', $realVerify)
    Check "$tag 只有別輪（R2）的驗收回合 ⇒ R3 仍印警告、不擋（exit 0）" ((Warned $r '驗收回合'))
    Set-Content (Join-Path $wc.Case 'pm\grill-x.md') "質詢輪結束：已拍板`n`n## 驗收回合 R3（11-24）`nQ-21 只按確定算不算修改？建議不算 [待確認]" -Encoding UTF8
    $r = Run @('-Role', 'backend', '-CasePath', $wc.Case, '-VerifyRoot', $realVerify)
    Check "$tag 驗收回合小節還有 [待確認] ⇒ 擋（待拍板閘 exit 12 先擋）" ($r.Code -eq 12)
    Set-Content (Join-Path $wc.Case 'pm\grill-x.md') "質詢輪結束：已拍板`n`n## 驗收回合 R3（11-24）`n" -Encoding UTF8
    $r = Run @('-Role', 'backend', '-CasePath', $wc.Case, '-VerifyRoot', $realVerify)
    Check "$tag 驗收回合小節是空的（沒有已拍板／已查證／已轉單）⇒ 警告（exit 0）" ((Warned $r '驗收回合'))
    Set-Content (Join-Path $wc.Case 'pm\grill-x.md') "質詢輪結束：已拍板`n`n### 驗收回合 R3（11-24）`nQ-21 只按確定算不算修改＝不算（PM 11-24 已拍板）`nQ-22 只暫存＝不算（已拍板）" -Encoding UTF8
    $r = Run @('-Role', 'backend', '-CasePath', $wc.Case, '-VerifyRoot', $realVerify)
    Check "$tag sa/ 或 pm/ 的 grill 有「驗收回合 R3」且已拍板 ⇒ pass（rework-rules=R3）" ($r.Code -eq 0 -and $r.Out -match 'rework-rules=R3' -and $r.Out -notmatch 'grill-gate 警告')
    Set-Content (Join-Path $wc.Case 'pm\grill-x.md') '質詢輪結束：已拍板' -Encoding UTF8
    $r = Run @('-Role', 'backend', '-CasePath', $wc.Case, '-SkipRoute', '舊案', '-Skip', '-VerifyRoot', $realVerify)
    Check "$tag 舊案 -SkipRoute＋-Skip ⇒ 驗收回合閘一起跳過（同 exit 12）" ($r.Code -eq 0)

    Write-Host "--- $tag SA 的設計形狀小節（2026-11-28，只警告）---"
    $dc = New-Case "@功能:$existing"; $cases += $dc
    $r = Run @('-Role', 'backend', '-CasePath', $dc.Case, '-VerifyRoot', $realVerify)
    Check "$tag sa/grill 有收斂的「設計形狀」小節 ⇒ pass、沒警告（design-shape=ok）" ($r.Code -eq 0 -and $r.Out -match 'design-shape=ok' -and $r.Out -notmatch 'grill-gate 警告')
    Set-Content (Join-Path $dc.Case 'sa\grill-x.md') '質詢輪結束：已拍板' -Encoding UTF8
    $r = Run @('-Role', 'qa', '-CasePath', $dc.Case, '-VerifyRoot', $realVerify)
    Check "$tag 🔴 sa/grill 沒有「設計形狀」小節 ⇒ 派實作／QA 印警告、不擋（exit 0）" ((Warned $r '設計形狀') -and $r.Out -match 'GRILL_GATE=pass')
    Set-Content (Join-Path $dc.Case 'sa\grill-x.md') "質詢輪結束：已拍板`n`n## 設計形狀`n（還沒寫）`n`n## 其他`n已拍板" -Encoding UTF8
    $r = Run @('-Role', 'backend', '-CasePath', $dc.Case, '-VerifyRoot', $realVerify)
    Check "$tag 設計形狀小節沒有終止標記（標記在別節不算）⇒ 警告並點名檔:行" ((Warned $r '設計形狀') -and ($r.Out -replace '\s+', '') -match 'sa/grill-x\.md:3')
    Set-Content (Join-Path $dc.Case 'sa\grill-x.md') "質詢輪結束：已拍板`n`n### 第十分支：設計形狀`n- 冪等：N/A－唯讀查詢`n- 共用狀態：N/A－單一請求" -Encoding UTF8
    $r = Run @('-Role', 'backend', '-CasePath', $dc.Case, '-VerifyRoot', $realVerify)
    Check "$tag 設計形狀小節全寫 N/A－理由 ⇒ 算收斂、沒警告" ($r.Code -eq 0 -and $r.Out -notmatch 'grill-gate 警告')
    Set-Content (Join-Path $dc.Case 'sa\grill-x.md') '質詢輪結束：已拍板' -Encoding UTF8
    $r = Run @('-Role', 'sa', '-CasePath', $dc.Case)
    Check "$tag 派 SA 不看設計形狀（那是 SA 自己要寫的）" ($r.Code -eq 0 -and $r.Out -notmatch '設計形狀')
    $r = Run @('-Role', 'backend', '-CasePath', $dc.Case, '-SkipRoute', '舊案', '-Skip', '-VerifyRoot', $realVerify)
    Check "$tag 舊案 -SkipRoute＋-Skip ⇒ 不看設計形狀" ($r.Code -eq 0 -and $r.Out -notmatch '設計形狀')
    $bc = New-BugCase '' $fullAnalysis; $cases += $bc
    Add-Content (Join-Path $bc.Case 'sa\bug-analysis.md') "`n@功能:$existing" -Encoding UTF8
    $r = Run @('-Role', 'backend', '-CasePath', $bc.Case, '-VerifyRoot', $realVerify)
    Check "$tag 小問題路線不要求設計形狀" ($r.Code -eq 0 -and $r.Out -notmatch '設計形狀')

    Write-Host "--- $tag 警告摘要與編號（2026-11-28）---"
    $wsc = New-Case "@功能:$existing"; $cases += $wsc
    Set-Content (Join-Path $wsc.Case 'case_spec_content\spec_001.md') "路線：四角色，高風險：否，理由：沒寫外部系統" -Encoding UTF8
    Set-Content (Join-Path $wsc.Case 'sa\grill-x.md') '質詢輪結束：已拍板' -Encoding UTF8
    $r = Run @('-Role', 'backend', '-CasePath', $wsc.Case, '-VerifyRoot', $realVerify)
    $wl = @($r.Out -split "`r?`n" | Where-Object { $_ -match 'grill-gate 警告' })
    Check "$tag 兩項警告 ⇒ 第一行是摘要（共 2 項、列出類別），各項編號 [1/2]、[2/2]、exit 0" ($r.Code -eq 0 -and $wl.Count -eq 3 -and $wl[0] -match '警告摘要：共 2 項（外部系統、設計形狀）' -and $wl[1] -match '\[1/2\] 外部系統' -and $wl[2] -match '\[2/2\] 設計形狀')
    $nwc = New-Case "@功能:$existing"; $cases += $nwc
    $r = Run @('-Role', 'backend', '-CasePath', $nwc.Case, '-VerifyRoot', $realVerify)
    Check "$tag 沒有警告 ⇒ 不印摘要" ($r.Out -notmatch '警告摘要')

    Write-Host "--- $tag 同一根因連兩輪退回 ⇒ 前提檢查（2026-11-28，只警告）---"
    $pc = New-Case "@功能:$existing"; $cases += $pc
    New-Item -ItemType Directory -Force (Join-Path $pc.Case 'qa') | Out-Null
    $pl = Join-Path $pc.Case 'qa\rework-log.md'
    $plHead = "# 退回紀錄`n| 輪次 | 退回原因 | 處理類別 | 根因類別 | 錯誤寫法 | 為什麼沒先抓到 | 修正 |`n|---|---|---|---|---|---|---|"
    Set-Content $pl "$plHead`n| R1（11/23） | 某電號抓不到 | 程式錯誤 | 樣本不足 | 只測一種電號 | 樣本少 | a1 |`n| R2（11/24） | 某帳期抓不到 | 程式錯誤 | 動作順序 | 先存後算 | 沒測順序 | a2 |" -Encoding UTF8
    $r = Run @('-Role', 'backend', '-CasePath', $pc.Case, '-VerifyRoot', $realVerify)
    Check "$tag 根因各不相同 ⇒ 不要求前提檢查" ($r.Code -eq 0 -and $r.Out -notmatch '前提檢查')
    Set-Content $pl "$plHead`n| R1（11/23） | 某電號抓不到 | 程式錯誤 | 樣本不足 | 只測一種電號 | 樣本少 | a1 |`n| R2（11/24） | 另一種電號也抓不到 | 程式錯誤 | 樣本不足 | 只補了一種 | 樣本少 | a2 |" -Encoding UTF8
    $r = Run @('-Role', 'qa', '-CasePath', $pc.Case, '-VerifyRoot', $realVerify)
    Check "$tag 🔴 同一根因（樣本不足）在 R1、R2 都出現、沒寫前提檢查 ⇒ 警告點名根因與 R2、不擋" ((Warned $r '前提檢查') -and ($r.Out -replace '\s+', '') -match '樣本不足.*R1、R2' -and $r.Out -match 'repeat-cause=樣本不足')
    Add-Content $pl "`n前提檢查 R1：前提是電號只有一種格式；（舊的，不算）" -Encoding UTF8
    $r = Run @('-Role', 'backend', '-CasePath', $pc.Case, '-VerifyRoot', $realVerify)
    Check "$tag 只寫了別輪（R1）的前提檢查 ⇒ 仍警告" ((Warned $r '前提檢查'))
    Add-Content $pl "前提檢查 R2：前提是「需求方給的樣本涵蓋所有電號格式」；唯讀查詢正式資料的電號長度分布 ⇒ 有 3 種，前提被推翻" -Encoding UTF8
    $r = Run @('-Role', 'backend', '-CasePath', $pc.Case, '-VerifyRoot', $realVerify)
    Check "$tag 寫了「前提檢查 R2：…」⇒ 不警告" ($r.Code -eq 0 -and $r.Out -notmatch '前提檢查：')
    Set-Content $pl "$plHead`n| R1 | 要加匯出 | 新規則 | 新需求 | 不是程式寫法（x） | 新需求 | — |`n| R2 | 又要加欄位 | 新規則 | 新需求 | 不是程式寫法（y） | 新需求 | — |" -Encoding UTF8
    $r = Run @('-Role', 'backend', '-CasePath', $pc.Case, '-VerifyRoot', $realVerify)
    Check "$tag 根因＝新需求連兩輪 ⇒ 豁免" ($r.Out -notmatch '前提檢查')

    Write-Host "--- $tag 小問題的逃逸標記（2026-11-28，只警告）---"
    $r = Run @('-Role', 'backend', '-CasePath', $bc.Case, '-VerifyRoot', $realVerify)
    Check "$tag 🔴 bug-analysis 沒寫「逃逸：」⇒ 派實作印警告、不擋（exit 0）" ((Warned $r '逃逸') -and $r.Out -match 'GRILL_GATE=pass')
    $ba = Join-Path $bc.Case 'sa\bug-analysis.md'; $baText = [IO.File]::ReadAllText($ba)
    [IO.File]::WriteAllText($ba, $baText + "`n**逃逸**：是（正式環境回報）`n", [Text.UTF8Encoding]::new($false))
    $r = Run @('-Role', 'qa', '-CasePath', $bc.Case, '-VerifyRoot', $realVerify)
    Check "$tag 「逃逸：是」沒寫來源案號 ⇒ 警告" ((Warned $r '逃逸') -and ($r.Out -replace '\s+', '') -match '沒寫來源案號')
    [IO.File]::WriteAllText($ba, $baText + "`n逃逸：是，來源 #2164（站上關卡沒測跨年期別）`n", [Text.UTF8Encoding]::new($false))
    $r = Run @('-Role', 'backend', '-CasePath', $bc.Case, '-VerifyRoot', $realVerify)
    Check "$tag 「逃逸：是，來源 #NNN」⇒ 沒警告（escape=yes）" ($r.Code -eq 0 -and $r.Out -match 'escape=yes' -and $r.Out -notmatch 'grill-gate 警告')
    [IO.File]::WriteAllText($ba, $baText + "`n逃逸：否（還沒上線的新功能）`n", [Text.UTF8Encoding]::new($false))
    $r = Run @('-Role', 'backend', '-CasePath', $bc.Case, '-VerifyRoot', $realVerify)
    Check "$tag 「逃逸：否（理由）」⇒ 沒警告（escape=no）" ($r.Code -eq 0 -and $r.Out -match 'escape=no' -and $r.Out -notmatch 'grill-gate 警告')
    $r = Run @('-Role', 'sa', '-CasePath', $bc.Case)
    Check "$tag 派 SA 不看逃逸（那是 SA 自己要寫的）" ($r.Code -eq 0 -and $r.Out -notmatch '逃逸')

    $r = Run @('-Role', 'backend', '-CasePath', $c.Case)
    Check "$tag 不帶 -VerifyRoot：預設找 CasePath 往上兩層的 verify/（暫存 case 沒有 ⇒ exit 6）" ($r.Code -eq 6)
}
foreach ($x in $cases) { Remove-Item -LiteralPath $x.Root -Recurse -Force -ErrorAction SilentlyContinue }
Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
if ($Inner) { if ($script:fail) { exit 1 } else { exit 0 } }
# 再用 Windows PowerShell 5.1 整支跑一輪（-Inner：只回 exit 碼，結果行照印）
if ($env:SystemRoot -and (Test-Path $ps5) -and $PSVersionTable.PSEdition -ne 'Desktop') {
    & $ps5 -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $PSCommandPath -Inner
    if ($LASTEXITCODE -ne 0) { $script:fail++ }
}
Write-Host ''
if ($script:fail) { Write-Host "FAILED: $($script:fail)" -ForegroundColor Red; exit 1 } else { Write-Host 'ALL PASSED' -ForegroundColor Green; exit 0 }
