<#
.SYNOPSIS
  派發 SA／實作（backend、frontend 等，見 .claude/workflow.json）／QA 前的唯讀檢查（hd5-grill skill；功能地圖 hd5-verify；路線 AGENTS.md「案件路線」）。

.DESCRIPTION
  0. 路線閘（2026-11-23 新增，-Role sa 與下游）：
     建案時主對話在 case_spec_content/spec_001.md 寫「路線：<四角色｜PM 端已完成｜小問題>，理由：…」。
       四角色        pm → sa → qa（計畫＋Red）→ 實作代理（workflow.json 的 implementers）→ qa（驗證與報告）全派
       PM 端已完成   工單附 PM 端 pm agent 產物；主對話檢查後從 sa-expert 開始派
       小問題        沒有 PM 文件的小問題／緊急 bug：先派 sa-expert 盤查，產出 sa/bug-analysis.md，再派 PG
     沒寫路線 ⇒ exit 8；寫了路線又帶 -Skip ⇒ exit 9（三條路線都不准跳步）。
     同一行要寫「高風險：是｜否」（資料模型／權限／跨模組／正式站資料修正＝是），沒寫 ⇒ exit 11。
  1b. 對抗輪閘（高風險：是，-Role 實作角色|qa）：要有 sa/adversarial-review*.md，含「對抗結論：」且問題都處理完
     （已拍板／已查證／已轉單／已修正，或「無問題」）⇒ 否則 exit 11。依據：#884 的 SA 寫錯 SQL 到執行時才撞到。
     為什麼：使用者原本理解「下達任務後由主對話判斷派哪個 agent」，量測（9 月起角色代理只派 6 次）顯示判斷沒有被執行。
  1. 質詢閘：
     四角色／PM 端已完成：上一階段（SA 看 pm/、其他看 sa/）要有 grill-*.md，且至少一份含終止標記（已拍板／已查證／已轉單）。
     小問題：-Role sa 不需要 pm/；-Role 實作角色|qa 要有 sa/bug-analysis*.md，含「原因／影響範圍／同類位置／修法」四節
             與終止標記（已拍板／已查證／已轉單，或「待決事項：無」）——緊急也不例外（exit 10）。
  1a. 待拍板閘（2026-11-24，僅 -Role 實作角色|qa；-Skip 時一起跳過）：
     pm/grill-*.md、sa/grill-*.md 裡還有一行寫「待拍板」或「[待確認]」，而且同一行沒有標「已轉單」、後面也沒接「已拍板／已查證」⇒ exit 12。
     依據：試跑時 SA 的 grill 檔還有待拍板題，舊閘只看「有終止標記」照樣放行（hd5-grill 第六節：未拍板題不得當定案）。
     「待拍板：無」「待拍板 0 題」這類總結行不算。
  1b'. PM 問卷回收閘（2026-11-24，路線＝PM 端已完成，-Role sa 與下游）：
     pm/ 或 case_spec_content/attachments/ 有 spec_*_r*.html（需求問卷）⇒ pm/ 或 case_spec_content/（含子資料夾）要有對應的
     <同名>_answer*.html，缺 ⇒ exit 13。依據：試跑時 pm.zip 的 grill 檔一複製進來閘就過，問卷有沒有回收完全沒驗。
  2. 功能地圖閘（2026-11-22，僅 -Role 實作角色|qa）：
     - 本案動到的功能要標成 `@功能:<編號>`，可寫在：sa/*.feature、sa/*.md（小問題路線的 bug-analysis）、
       case_spec_content/spec_*.md、pg/*.md。
     - 每個編號都要在 AI_Service/verify/features/<編號>.md 存在，且整份地圖合格（verify-map-check 同一套規則）。
  跳過：
     -SkipRoute "理由"        不檢查路線（本規則生效前已進行中的舊案、純工具案）；此時 -Skip 照舊可用
     -Skip                    只跳過質詢閘，且只在 -SkipRoute 時允許；🔴 功能地圖閘照跑
     -SkipFeatureMap "理由"   只跳過功能地圖閘（純工具／無使用者功能）

.EXAMPLE
  & ./validate-grill-gate.ps1 -Role backend -CasePath AI_Service/spec/<案名>
  & ./validate-grill-gate.ps1 -Role backend -CasePath AI_Service/spec/<舊案> -SkipRoute "11-23 前已進 PG" -Skip
  exit 碼：0 通過｜1 角色不認得｜2～4 質詢紀錄｜5～7 功能地圖｜8 沒寫路線｜9 有路線又 -Skip｜10 小問題缺 SA 分析｜
           11 沒標高風險或高風險缺對抗輪｜12 grill 紀錄還有待拍板題｜13 PM 問卷沒有回收答覆
#>
[CmdletBinding()]
param(
    # pm｜sa｜qa｜實作角色（workflow.json 的 implementers[].gateRole，IMOCore＝backend｜frontend；
    # 舊名 csharp｜vue3 過渡期當別名，2026-11-23 改名）
    [Parameter(Mandatory = $true)]
    [string]$Role,

    [Parameter(Mandatory = $true)]
    [string]$CasePath,

    [switch]$Skip,

    [string]$SkipFeatureMap,

    [string]$SkipRoute,

    # 測試用：指定功能地圖根目錄（預設＝CasePath 往上兩層的 verify/，即 AI_Service/verify）
    [string]$VerifyRoot
)

$resolvedCase = Resolve-Path -LiteralPath $CasePath -ErrorAction Stop

# ── 角色（通用化 2026-11-23）：實作角色由專案 .claude/workflow.json 決定，不寫死 csharp／vue3 ──
# 設定檔：從案子往上找 .claude/workflow.json（案子在哪個專案就用哪個專案的設定），找不到再從本檔位置找（_hd5-locate.ps1）
$locate = Join-Path $PSScriptRoot '_hd5-locate.ps1'
if (-not (Test-Path -LiteralPath $locate)) { $locate = Join-Path $PSScriptRoot '..\..\..\..\agent\scripts\_hd5-locate.ps1' }
$wf = $null
if (Test-Path -LiteralPath $locate) {
    . $locate
    $proj = Get-HD5Project -Start $resolvedCase.Path
    if (-not $proj.Workflow) { $proj = Get-HD5Project -Start $PSScriptRoot }
    $wf = $proj.Workflow
}
$implRoles = @{}   # 名稱（含別名）→ 正式 gateRole
if ($wf -and $wf.implementers) {
    foreach ($i in @($wf.implementers)) {
        $implRoles[[string]$i.gateRole] = [string]$i.gateRole
        foreach ($a in @($i.gateAliases)) { if ($a) { $implRoles[[string]$a] = [string]$i.gateRole } }
    }
} else {
    $implRoles = @{ backend = 'backend'; frontend = 'frontend'; csharp = 'backend'; vue3 = 'frontend' }
}
if ($Role -notin @('pm', 'sa', 'qa') -and -not $implRoles.ContainsKey($Role)) {
    Write-Error "GRILL_GATE=fail role=$Role：不認得的角色。可用 pm｜sa｜qa｜$(@($implRoles.Keys | Sort-Object) -join '｜')（實作角色見 .claude/workflow.json）"
    exit 1
}
if ($implRoles.ContainsKey($Role)) { $Role = $implRoles[$Role] }
$isDownstream = $Role -notin @('pm', 'sa')   # 實作角色或 qa：要過對抗輪閘與功能地圖閘

if ($Role -eq 'pm') {
    Write-Output "GRILL_GATE=pass role=pm reason=first-stage"
    exit 0
}

# ── 0. 路線閘 ───────────────────────────────────────────────────────────
$route = ''
$routeLine = ''
$risk = ''
$routeNote = ''
if (-not [string]::IsNullOrWhiteSpace($SkipRoute)) {
    $routeNote = "route=skip reason=$SkipRoute"
} else {
    foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $resolvedCase 'case_spec_content') -Filter 'spec_*.md' -File -ErrorAction SilentlyContinue)) {
        $m = [regex]::Match((Get-Content -Raw -LiteralPath $f.FullName -Encoding UTF8), '(?m)^[\s>*-]*\**路線\**\s*[:：]\s*\**\s*(四角色|PM\s*端已完成|小問題)[^\r\n]*')
        if ($m.Success) { $route = ($m.Groups[1].Value -replace '\s', ''); $routeLine = $m.Value; break }
    }
    if (-not $route) {
        Write-Error ("GRILL_GATE=fail role=$Role route: case_spec_content/spec_001.md 沒有寫路線。建案時主對話要寫一行「路線：四角色｜PM 端已完成｜小問題，理由：…」" +
            "（判斷規則見 AGENTS.md「案件路線」）。本規則生效前已進行中的舊案才用 -SkipRoute ""理由""")
        exit 8
    }
    if ($Skip) {
        Write-Error "GRILL_GATE=fail role=$Role route=$($route)：有寫路線就不准 -Skip（三條路線都不跳步）。小問題請走「小問題」路線（先派 sa-expert 盤查）；確定是舊案才用 -SkipRoute ""理由"""
        exit 9
    }
    # 高風險（2026-11-23 使用者拍板：只在高風險案做對抗輪）：同一行要寫「高風險：是｜否」，判斷結果要留下來
    $riskM = [regex]::Match($routeLine, '高風險\**\s*[:：]\s*\**\s*(是|否)')
    if (-not $riskM.Success) {
        Write-Error ("GRILL_GATE=fail role=$Role risk: 路線那一行沒寫「高風險：是｜否」。資料模型／權限／跨模組／正式站資料修正＝是" +
            "（是 ⇒ SA 之後、派 PG 前要跑對抗輪，見 AGENTS.md「案件路線」）")
        exit 11
    }
    $risk = $riskM.Groups[1].Value
    $routeNote = "route=$route risk=$(if ($risk -eq '是') { 'high' } else { 'low' })"
}

# ── 1. 質詢閘 ───────────────────────────────────────────────────────────
$markerPattern = '已拍板|已查證|已轉單'
$grillNote = ''
if ($Skip) {
    $grillNote = 'grill=skip'
} elseif ($route -eq '小問題' -and $Role -eq 'sa') {
    $grillNote = 'upstream=none（小問題路線不需要 pm/）'
} elseif ($route -eq '小問題') {
    $saDir = Join-Path $resolvedCase 'sa'
    $docs = @(Get-ChildItem -LiteralPath $saDir -Filter 'bug-analysis*.md' -File -ErrorAction SilentlyContinue)
    if ($docs.Count -eq 0) {
        Write-Error "GRILL_GATE=fail role=$Role route=小問題: 缺 $saDir\bug-analysis.md。小問題／緊急 bug 也要先派 sa-expert 盤查，SA 文件寫完才派 PG（sa-expert.md「小問題模式」）"
        exit 10
    }
    $ok = $null; $why = @()
    foreach ($d in $docs) {
        $t = Get-Content -Raw -LiteralPath $d.FullName -Encoding UTF8
        $miss = @('原因', '影響範圍', '同類位置', '修法' | Where-Object { $t -notmatch "(?m)^#{2,3}\s*(\d+[.、]\s*)?$_" })
        $done = ($t -match $markerPattern) -or ($t -match '待決事項\s*[:：]\s*(無|0\s*題)')
        if ($miss.Count -eq 0 -and $done) { $ok = $d; break }
        if ($miss.Count) { $why += "$($d.Name) 缺小節：$($miss -join '、')" }
        if (-not $done) { $why += "$($d.Name) 沒有終止標記（已拍板／已查證／已轉單，或「待決事項：無」）" }
    }
    if ($null -eq $ok) {
        Write-Error ("GRILL_GATE=fail role=$Role route=小問題: SA 分析文件不完整：" + ($why -join '；'))
        exit 10
    }
    $grillNote = "upstream=sa/$($ok.Name)"
} else {
    $upstream = if ($Role -eq 'sa') { 'pm' } else { 'sa' }
    $upstreamPath = Join-Path $resolvedCase $upstream
    if (-not (Test-Path -LiteralPath $upstreamPath -PathType Container)) {
        Write-Error "GRILL_GATE=fail role=$Role missing-directory=$upstreamPath"
        exit 2
    }
    $records = @(Get-ChildItem -LiteralPath $upstreamPath -Filter 'grill-*.md' -File -ErrorAction SilentlyContinue)
    if ($records.Count -eq 0) {
        Write-Error "GRILL_GATE=fail role=$Role missing=$upstreamPath\grill-*.md"
        exit 3
    }
    $validRecords = @($records | Where-Object { (Get-Content -Raw -LiteralPath $_.FullName -Encoding UTF8) -match $markerPattern })
    if ($validRecords.Count -eq 0) {
        Write-Error "GRILL_GATE=fail role=$Role records-have-no-terminal-marker"
        exit 4
    }
    $grillNote = "upstream=$upstream records=$($validRecords.Count)"
}

# ── 1a. 待拍板閘（派實作／QA 前；2026-11-24）────────────────────────────────
# grill 紀錄「有終止標記」不代表每題都收斂：還有「待拍板」或「[待確認]」而且沒轉單的行就擋（hd5-grill 第六節第 1 條）。
if ($isDownstream -and -not $Skip) {
    $pendingHits = @()
    foreach ($dir in 'pm', 'sa') {
        foreach ($g in @(Get-ChildItem -LiteralPath (Join-Path $resolvedCase $dir) -Filter 'grill-*.md' -File -ErrorAction SilentlyContinue)) {
            $n = 0
            foreach ($line in @(Get-Content -LiteralPath $g.FullName -Encoding UTF8)) {
                $n++
                $pm = [regex]::Matches($line, '待拍板|[\[［]\s*待確認\s*[\]］]')
                if ($pm.Count -eq 0) { continue }
                if ($line -match '已轉單') { continue }                                       # 轉給非工程角色＝合法終止狀態
                if ($line -match '待拍板\S{0,2}\s*[:：]?\s*(無|0\s*題|0\s*$)') { continue }      # 「待拍板：無」「待拍板題 0 題」之類的總結行
                $last = $pm[$pm.Count - 1]
                if ($line.Substring($last.Index + $last.Length) -match '已拍板|已查證') { continue }   # 同一行後面已收斂（例：建議 A [待確認] → 已拍板 A）
                $snip = $line.Trim(); if ($snip.Length -gt 60) { $snip = $snip.Substring(0, 60) + '…' }
                $pendingHits += "$dir/$($g.Name):$n「$snip」"
            }
        }
    }
    if ($pendingHits.Count) {
        Write-Error ("GRILL_GATE=fail role=$Role pending: 質詢紀錄還有 $($pendingHits.Count) 處待拍板／[待確認]（沒標已轉單）：" + (($pendingHits | Select-Object -First 8) -join '；') +
            $(if ($pendingHits.Count -gt 8) { "；…另 $($pendingHits.Count - 8) 處" } else { '' }) +
            "。先一題一題問使用者拍板（或轉單給需求方並標「已轉單」），回填紀錄後再派（hd5-grill 第六節）")
        exit 12
    }
    $grillNote += ' pending=0'
}

# ── 1b'. PM 問卷回收閘（路線＝PM 端已完成；2026-11-24）─────────────────────────
# 需求方的問卷 spec_*_r*.html 要有對應的 *_answer*.html，才算「Open Questions 都有答案」（hd5-workflow「案件路線」）。
if ($route -eq 'PM端已完成') {
    $qDirs = @((Join-Path $resolvedCase 'pm'), (Join-Path $resolvedCase 'case_spec_content\attachments'))
    $questionnaires = @(foreach ($d in $qDirs) { Get-ChildItem -LiteralPath $d -Filter 'spec_*.html' -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.BaseName -match '^spec_.+_r\d+' -and $_.BaseName -notmatch '_answer' } })
    $answers = @(foreach ($d in @((Join-Path $resolvedCase 'pm'), (Join-Path $resolvedCase 'case_spec_content'))) { Get-ChildItem -LiteralPath $d -Filter '*_answer*.html' -File -Recurse -ErrorAction SilentlyContinue })
    $noAnswer = @($questionnaires | Where-Object { $b = $_.BaseName; -not @($answers | Where-Object { $_.Name.StartsWith("$($b)_answer", [StringComparison]::OrdinalIgnoreCase) }).Count } |
        ForEach-Object { $_.Name } | Sort-Object -Unique)
    if ($noAnswer.Count) {
        Write-Error ("GRILL_GATE=fail role=$Role route=PM端已完成 answer: 需求問卷還沒有回收答覆：" + ($noAnswer -join '、') +
            "（要有同名的 <問卷>_answer*.html，放 pm/ 或 case_spec_content/）。沒答的題先問需求方，答覆檔放進來再派（hd5-spec-html）")
        exit 13
    }
    if ($questionnaires.Count) { $grillNote += " answers=$($questionnaires.Count)" }
}

# ── 1b. 對抗輪閘（高風險：是，派 PG／QA 前；2026-11-23）────────────────────────
# 依據：#884 的 SA 寫錯 SQL，到執行時才撞到。高風險案 SA 產出後另派全新子代理（不可 fork）專門推翻 SA 結論，
# 結果寫 sa/adversarial-review*.md，要有「對抗結論：」一行，且每條問題都處理完（已拍板／已查證／已轉單／已修正，或寫「無問題」）。
$riskNote = ''
if ($risk -eq '是' -and $isDownstream) {
    $adv = @(Get-ChildItem -LiteralPath (Join-Path $resolvedCase 'sa') -Filter 'adversarial-review*.md' -File -ErrorAction SilentlyContinue)
    $okAdv = $adv | Where-Object { $t = Get-Content -Raw -LiteralPath $_.FullName -Encoding UTF8; ($t -match '(?m)對抗結論\s*[:：]') -and ($t -match '已拍板|已查證|已轉單|已修正|無問題') } | Select-Object -First 1
    if (-not $okAdv) {
        $why = if ($adv.Count) { "$($adv[0].Name) 沒有「對抗結論：」或問題還沒處理完（已拍板／已查證／已轉單／已修正／無問題）" } else { "缺 sa/adversarial-review.md" }
        Write-Error "GRILL_GATE=fail role=$Role risk=high: $why。高風險案在 SA 之後、派 PG 前要派全新子代理（不可 fork）挑 SA 的錯（AGENTS.md「案件路線」）"
        exit 11
    }
    $riskNote = " adversarial=sa/$($okAdv.Name)"
}

# ── 2. 功能地圖閘（PG／QA 開工前；-Skip 不跳過這一段）───────────────────────
$featureNote = ''
if ($isDownstream) {
    if (-not [string]::IsNullOrWhiteSpace($SkipFeatureMap)) {
        $featureNote = " feature-map=skip reason=$SkipFeatureMap"
    } else {
        $sources = @()
        $sources += @(Get-ChildItem -LiteralPath (Join-Path $resolvedCase 'sa') -Include '*.feature', '*.md' -File -Recurse -ErrorAction SilentlyContinue)
        $sources += @(Get-ChildItem -LiteralPath (Join-Path $resolvedCase 'case_spec_content') -Filter 'spec_*.md' -File -ErrorAction SilentlyContinue)
        $sources += @(Get-ChildItem -LiteralPath (Join-Path $resolvedCase 'pg') -Filter '*.md' -File -ErrorAction SilentlyContinue)
        $ids = @()
        foreach ($f in $sources) {
            foreach ($m in [regex]::Matches((Get-Content -Raw -LiteralPath $f.FullName -Encoding UTF8), '@功能[:：]([A-Za-z0-9][A-Za-z0-9._-]*)')) { $ids += $m.Groups[1].Value }
        }
        $ids = @($ids | Sort-Object -Unique)
        # 功能編號＝功能檔名，地圖檢查只收小寫英數＋連字號；這裡收得寬是為了把寫錯的指出來，不要靜默當成沒標
        $badIds = @($ids | Where-Object { $_ -cnotmatch '^[a-z0-9][a-z0-9-]*$' })
        if ($badIds.Count -gt 0) {
            Write-Error ("GRILL_GATE=fail role=$Role feature-map: 功能編號格式不對（只能小寫英數與連字號，要跟 verify/features/ 的檔名一樣）：" + ($badIds -join '、'))
            exit 7
        }
        if ($ids.Count -eq 0) {
            Write-Error ("GRILL_GATE=fail role=$Role feature-map: 本案沒有標任何 @功能:<編號>。四角色由 SA 標在 sa/*.feature；小問題由 SA 標在 sa/bug-analysis.md；" +
                "也可由主對話標在 case_spec_content/spec_001.md 的驗收條件旁；功能編號＝AI_Service/verify/features/ 的檔名，" +
                "地圖沒有就先建骨架（hd5-verify skill）。純工具、無使用者功能才用 -SkipFeatureMap ""理由""")
            exit 5
        }
        if ([string]::IsNullOrWhiteSpace($VerifyRoot)) { $VerifyRoot = Join-Path (Split-Path (Split-Path $resolvedCase -Parent) -Parent) 'verify' }
        $vlib = Join-Path $PSScriptRoot '_verify-map-lib.ps1'   # HD5Skills：同一個 tools 資料夾
        if (-not (Test-Path -LiteralPath $vlib)) { $vlib = Join-Path $PSScriptRoot '..\..\..\..\agent\scripts\_verify-map-lib.ps1' }   # IMOCore 舊位置
        . $vlib
        $map = Test-VerifyMap -VerifyRoot $VerifyRoot
        if (-not $map.Passed) {
            Write-Error ("GRILL_GATE=fail role=$Role feature-map: 功能地圖不合格（$VerifyRoot）：" + ($map.Reasons -join '；'))
            exit 6
        }
        $missing = @($ids | Where-Object { $map.FeatureIds -notcontains $_ })
        if ($missing.Count) {
            Write-Error ("GRILL_GATE=fail role=$Role feature-map: 本案標的功能不在地圖：" + (($missing | ForEach-Object { "verify/features/$_.md" }) -join '、') + "（先建骨架檔，格式見 hd5-verify skill）")
            exit 7
        }
        $featureNote = " features=$($ids -join ',')"
    }
}

Write-Output "GRILL_GATE=pass role=$Role $routeNote $grillNote$riskNote$featureNote"
exit 0
