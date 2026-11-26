<#
.SYNOPSIS
  validate-grill-gate.ps1 離線測試（暫存資料夾造 case 與一份「依地圖規則產生的合格功能地圖」；不依賴專案自己的 verify/，母版也能跑）。
  執行：pwsh -File tests/validate-grill-gate.tests.ps1（也會用 Windows PowerShell 5.1 跑一輪）；最後一行要是 ALL PASSED。
#>
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

$b = [IO.File]::ReadAllBytes($gate)
Check 'BOM（Windows PowerShell 5.1 讀中文訊息）' ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)

# 預設＝四角色路線，pm/、sa/ 都有拍板紀錄。$route 給空字串＝不寫路線。
function New-Case([string]$featureText, [string]$route = '四角色') {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('grillgate_' + [guid]::NewGuid().ToString('N'))
    $case = Join-Path $root 'AI_Service\spec\case-x'
    New-Item -ItemType Directory -Force (Join-Path $case 'pm'), (Join-Path $case 'sa'), (Join-Path $case 'case_spec_content') | Out-Null
    Set-Content (Join-Path $case 'pm\grill-x.md') '質詢輪結束：已拍板' -Encoding UTF8
    Set-Content (Join-Path $case 'sa\grill-x.md') '質詢輪結束：已拍板' -Encoding UTF8
    $spec = "## 5. 驗收條件`n- [ ] x"
    if ($route) { $spec += "`n`n路線：$route，高風險：否，理由：測試" }
    Set-Content (Join-Path $case 'case_spec_content\spec_001.md') $spec -Encoding UTF8
    if ($null -ne $featureText) { Set-Content (Join-Path $case 'sa\x.feature') $featureText -Encoding UTF8 }
    return [pscustomobject]@{ Root = $root; Case = $case }
}
# 小問題路線：沒有 pm/；SA 寫 sa/bug-analysis.md
function New-BugCase([string]$specExtra = '', [string]$analysis) {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('grillgate_' + [guid]::NewGuid().ToString('N'))
    $case = Join-Path $root 'AI_Service\spec\bug-y'
    New-Item -ItemType Directory -Force (Join-Path $case 'case_spec_content') | Out-Null
    Set-Content (Join-Path $case 'case_spec_content\spec_001.md') "## 5. 驗收條件`n- [ ] 匯入更新寫回$specExtra`n`n**路線**：小問題，**高風險**：否，理由：單一匯入方法" -Encoding UTF8
    if ($null -ne $analysis) {
        New-Item -ItemType Directory -Force (Join-Path $case 'sa') | Out-Null
        Set-Content (Join-Path $case 'sa\bug-analysis.md') $analysis -Encoding UTF8
    }
    return [pscustomobject]@{ Root = $root; Case = $case }
}
$fullAnalysis = "# bug 分析`n## 原因`nNoTracking`n## 影響範圍`n匯入`n## 同類位置`n2 處`n## 修法`nAsTracking`n## 待決事項`n待決事項：無"

$exes = @([Environment]::ProcessPath)
$ps5 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if ((Test-Path $ps5) -and ($exes[0] -notlike '*WindowsPowerShell*')) { $exes += $ps5 }
$cases = @()
foreach ($exe in $exes) {
    $tag = if ($exe -like '*WindowsPowerShell*') { '[PS5.1]' } else { '[pwsh]' }
    function Run([string[]]$a) { $o = & $exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $gate @a 2>&1 | Out-String; [pscustomobject]@{ Code = $LASTEXITCODE; Out = $o } }

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
    Set-Content $sp "## 5. 驗收條件`n- [ ] x`n`n路線：四角色，高風險：是，理由：動到權限" -Encoding UTF8
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
    Set-Content $sp "## 5. 驗收條件`n- [ ] x`n`n**路線**：四角色，**高風險**：是，理由：粗體也認" -Encoding UTF8
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

    $r = Run @('-Role', 'backend', '-CasePath', $c.Case)
    Check "$tag 不帶 -VerifyRoot：預設找 CasePath 往上兩層的 verify/（暫存 case 沒有 ⇒ exit 6）" ($r.Code -eq 6)
}
foreach ($x in $cases) { Remove-Item -LiteralPath $x.Root -Recurse -Force -ErrorAction SilentlyContinue }
Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
if ($script:fail) { Write-Host "FAILED: $($script:fail)" -ForegroundColor Red; exit 1 } else { Write-Host 'ALL PASSED' -ForegroundColor Green }
