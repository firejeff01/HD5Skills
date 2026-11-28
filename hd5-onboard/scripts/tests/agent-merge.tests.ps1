<#
.SYNOPSIS
  _agent-merge-lib.ps1（代理檔三方比對）離線測試。執行：pwsh -File hd5-onboard/scripts/tests/agent-merge.tests.ps1；最後一行要是 ALL PASSED。
#>
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
. (Resolve-Path (Join-Path $PSScriptRoot '..\_agent-merge-lib.ps1')).Path
$script:fail = 0
function Check($name, $cond) { if ($cond) { Write-Host "  ok   $name" } else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:fail++ } }
function Doc([string[]]$parts) { ($parts -join "`n`n") + "`n" }
function Keys($text) { @((Split-AgentSections $text) | ForEach-Object Key) -join '|' }

$pre = "---`nname: x`n---`n`n你是代理。"
$stack = "## 本專案技術架構重點`n`nPython 3.12"
$stackTpl = "## 本專案技術架構重點`n`n（範本預設字）"

Write-Host '--- 切節 ---'
$t = Doc @($pre, "## 做法`n`n- a`n`n``````md`n## 不是標題`n``````", "## 不做`n`n- b", "## 不做`n`n- c")
Check '程式碼區塊裡的 ## 不算標題；同名節加 #2' ((Keys $t) -eq '|做法|不做|不做#2')
Check 'CRLF 與 LF 切出相同的節' ((Keys $t.Replace("`n", "`r`n")) -eq (Keys $t))

Write-Host '--- 有基準 ---'
$base = Doc @($pre, "## 做法`n`n- 舊做法", "## 熔斷`n`n- 舊熔斷", "## 不做`n`n- 舊不做", "## 回報`n`n- 舊回報", "## 已淘汰`n`n- x", "## 淘汰但改過`n`n- y", $stackTpl)
$tpl = Doc @($pre, "## 做法`n`n- 舊做法", "## 新原則`n`n- 新的", "## 熔斷`n`n- 新熔斷", "## 不做`n`n- 舊不做", "## 回報`n`n- 新回報", $stackTpl)
$proj = Doc @($pre, "## 做法`n`n- 舊做法  ", "## 熔斷`n`n- 舊熔斷", "## 不做`n`n- 專案自訂不做", "## 回報`n`n- 專案回報", "## 已淘汰`n`n- x", "## 淘汰但改過`n`n- 專案改過", "## 專案自己的節`n`n- z", $stack)
$m = Merge-AgentSections -Project $proj -Template $tpl -Base $base
Check '範本新加的節插在範本裡前一節（做法）後面' ((Keys $m.Text) -eq '|做法|新原則|熔斷|不做|回報|淘汰但改過|專案自己的節|本專案技術架構重點' -and $m.Added -contains '## 新原則')
Check '專案沒改過、範本改了 ⇒ 換成範本' ($m.Text -match '- 新熔斷' -and $m.Text -notmatch '- 舊熔斷' -and $m.Updated -contains '## 熔斷')
Check '專案改過、範本沒變 ⇒ 保留專案的' ($m.Text -match '專案自訂不做')
Check '兩邊都改 ⇒ 衝突、專案不動' ($m.Text -match '專案回報' -and @($m.Conflicts | Where-Object Key -eq '回報').Count -eq 1 -and $m.Conflicts.Count -eq 1)
Check '範本刪掉、專案沒改 ⇒ 移除；專案改過 ⇒ 保留＋備註' ($m.Removed -contains '## 已淘汰' -and $m.Text -match '專案改過' -and ($m.Notes -join ' ') -match '淘汰但改過')
Check '受保護的「本專案技術架構重點」不動' ($m.Text -match 'Python 3\.12' -and $m.Text -notmatch '範本預設字')
Check '只差行尾空白不算改過（做法沒被當成衝突）' (@($m.Conflicts | Where-Object Key -eq '做法').Count -eq 0)
Check '新基準：衝突的節留舊基準、其他記範本' ($m.BaseText -match '- 舊回報' -and $m.BaseText -match '- 新熔斷' -and $m.BaseText -match '## 新原則' -and $m.BaseText -notmatch '已淘汰')
$m2 = Merge-AgentSections -Project $m.Text -Template $tpl -Base $m.BaseText
Check '用新基準再跑 ⇒ 不再改檔、衝突照樣列' (-not $m2.Changed -and $m2.Conflicts.Count -eq 1)
$m3 = Merge-AgentSections -Project $m.Text -Template $tpl -Base $m.BaseText -Accept
Check '-Accept ⇒ 專案不動、基準＝範本' (-not $m3.Changed -and $m3.Text -ceq $m.Text -and $m3.BaseText -ceq $tpl)
$m4 = Merge-AgentSections -Project $m.Text -Template $tpl -Base $m3.BaseText
Check '接受後再跑 ⇒ 沒有衝突（專案的回報當成自訂保留）' ($m4.Conflicts.Count -eq 0 -and -not $m4.Changed -and $m4.Text -match '專案回報')
$projDel = Doc @($pre, "## 做法`n`n- 舊做法", "## 不做`n`n- 舊不做", "## 回報`n`n- 舊回報", $stack)
$m5 = Merge-AgentSections -Project $projDel -Template $tpl -Base $base
Check '專案刪掉的節：範本沒改 ⇒ 不加回；範本改了 ⇒ 衝突' ($m5.Text -notmatch '已淘汰' -and @($m5.Conflicts | Where-Object Key -eq '熔斷').Count -eq 1 -and $m5.Text -notmatch '熔斷')
Check '專案＝範本的檔 ⇒ 不改、沒衝突' (-not (Merge-AgentSections -Project $tpl -Template $tpl -Base $base).Changed)

Write-Host '--- 沒有基準（舊專案第一次）---'
# 2026-11-28 IMOCore 導入實測：沒有基準時自動插入範本的節，跟專案裡標題不同的同義節重複（例 sa「小問題模式（…）」、qa「第五原則：假訊號」）
# ⇒ 沒有基準就不插入，改列衝突並點名專案裡標題相近的節；有衝突也不建基準，等 -AcceptAgents 才建（否則下次會把沒插入的節當範本新加的再插進去）
$projOld = Doc @("---`nname: api-expert`ndescription: 改過`n---`n`n你是代理。", "## 做法`n`n- 舊做法", "## 新的原則（舊寫法）`n`n- 專案自己寫的原則", "## 回顧`n`n- 只跟「回報」共一個字，不該被點名", "## 熔斷`n`n- 新熔斷", "## 不做`n`n- 專案自訂不做", $stack)
$m6 = Merge-AgentSections -Project $projOld -Template $tpl -Base $null
Check '🔴 沒有基準：範本有、專案沒有的節不插入（專案檔不動）' (-not $m6.Changed -and $m6.Added.Count -eq 0 -and $m6.Text -ceq $projOld)
Check '沒有基準：缺的節與內容不同的節都列衝突（照範本順序）；前言不比' ((@($m6.Conflicts | ForEach-Object Key) -join '|') -eq '新原則|不做|回報' -and $m6.Text -match 'name: api-expert')
Check '🔴 缺的節點名專案裡標題相近的節（可能是同義節）' (@($m6.Conflicts | Where-Object Key -eq '新原則')[0].Reason -match '專案沒有這一節' -and @($m6.Conflicts | Where-Object Key -eq '新原則')[0].Reason -match '新的原則（舊寫法）')
Check '缺的節找不到相近的就不亂點名（只共一個字的「回顧」不算）' (@($m6.Conflicts | Where-Object Key -eq '回報')[0].Reason -notmatch '相近|回顧')
# IMOCore 導入實際撞在一起的三組（範本標題 ← 專案標題），以及不該配對的
Check 'IMOCore 實例：小問題模式（spec_001…）← 小問題模式（…，2026-11-23）' ((Get-AgentSimilarHeadings '小問題模式（spec_001 路線＝小問題）' @('小問題模式（…，2026-11-23）', '不做')) -contains '小問題模式（…，2026-11-23）')
Check 'IMOCore 實例：這個環境會給你假訊號 ← 第五原則：假訊號' ((Get-AgentSimilarHeadings '🔴 這個環境會給你假訊號（守衛：無）' @('第五原則：假訊號', '驗島', '開工前')) -contains '第五原則：假訊號')
Check 'IMOCore 實例：回報（照這個格式）← 回報格式（強制）' ((Get-AgentSimilarHeadings '回報（照這個格式）' @('回報格式（強制）', '熔斷')) -contains '回報格式（強制）')
Check '不相干的不配：程式設計原則 ↛ 本專案技術架構重點／開工前／做法' (@(Get-AgentSimilarHeadings '程式設計原則' @('本專案技術架構重點', '開工前（每次都做）', '做法', '不做')).Count -eq 0)
Check '🔴 沒有基準又有衝突 ⇒ 不建基準（BaseText＝空）' ($null -eq $m6.BaseText)
$m7 = Merge-AgentSections -Project $m6.Text -Template $tpl -Base $m6.BaseText
Check '第二次跑（還是沒有基準）⇒ 照樣只列衝突、不會補插' (-not $m7.Changed -and $m7.Conflicts.Count -eq 3)
$m8a = Merge-AgentSections -Project $m6.Text -Template $tpl -Base $null -Accept
$m8b = Merge-AgentSections -Project $m6.Text -Template $tpl -Base $m8a.BaseText
Check '-Accept 建了基準之後：缺的節當成專案刪掉、不再列衝突也不插入' ($m8b.Conflicts.Count -eq 0 -and -not $m8b.Changed)
$mClean = Merge-AgentSections -Project ($tpl -replace '（範本預設字）', 'Python 3.12') -Template $tpl -Base $null
Check '沒有基準但沒有任何衝突 ⇒ 照常建基準' ($mClean.Conflicts.Count -eq 0 -and $mClean.BaseText -ceq $tpl)

Write-Host '--- 真範本：基準＝範本、專案只填了技術架構重點 ⇒ 不動 ---'
$real = [IO.File]::ReadAllText((Resolve-Path (Join-Path $PSScriptRoot '..\..\templates\agents\backend-expert.template.md')).Path)
$filled = [regex]::Replace($real, '（初始化腳本會在這裡放技術架構的重點規則[^）]*）', 'Go 1.22')
$m8 = Merge-AgentSections -Project $filled -Template $real -Base $real
Check '沒有任何改動與衝突' (-not $m8.Changed -and $m8.Conflicts.Count -eq 0)
$noRule = ((Split-AgentSections $filled) | Where-Object Key -ne '程式設計原則' | ForEach-Object Text) -join "`n`n"
$baseOld = ((Split-AgentSections $real) | Where-Object Key -ne '程式設計原則' | ForEach-Object Text) -join "`n`n"
$m9 = Merge-AgentSections -Project $noRule -Template $real -Base $baseOld
Check '舊版（沒有程式設計原則）⇒ 補在「做法」與「不做」之間，技術架構重點保留' ((Keys $m9.Text) -match '\|做法\|程式設計原則\|不做\|' -and $m9.Text -match 'Go 1\.22' -and $m9.Conflicts.Count -eq 0)

Write-Host ''
if ($script:fail) { Write-Host "FAILED: $($script:fail)" -ForegroundColor Red; exit 1 } else { Write-Host 'ALL PASSED' -ForegroundColor Green }
