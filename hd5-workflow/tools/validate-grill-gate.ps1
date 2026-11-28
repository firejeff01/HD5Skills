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
  0'. 外部系統宣告（2026-11-25，-Role sa 與下游；-SkipRoute 時略過）：spec_*.md 該寫「外部系統：有｜無」，
     路線那一行（建議：路線：…，高風險：…，外部系統：無，理由：…）或另起一行都可以；沒寫 ⇒ 警告（不擋）。
  1c. 外部系統樣本（外部系統：有，-Role 實作角色|qa）：sa/external-samples.md 要有樣本表（表頭含「變化」「真實樣本」）、
     至少一列、每列「真實樣本」有值或寫「待提供（誰）」⇒ 否則警告（不擋）。依據：#2164 R1 只用一個真實電號測。
  1d. 驗收回合（-Role 實作角色|qa；-Skip 時一起跳過）：qa/rework-log.md 有處理類別＝新規則的輪次 R{k} ⇒
     pm/ 或 sa/ 的 grill-*.md 要有標題含「驗收回合」與 R{k} 的小節，內有已拍板／已查證／已轉單且沒有待拍板行（同 exit 12 判定）
     ⇒ 否則警告（不擋）。依據：#2164 R3／R4 新規則照自己理解做，又退一輪。
  1e. 設計形狀（2026-11-28，路線＝四角色／PM 端已完成，-Role 實作角色|qa；-Skip 時一起跳過）：sa/grill-*.md 要有標題含「設計形狀」的小節，
     內有已拍板／已查證／已轉單或 N/A ⇒ 否則警告（不擋）。依據：hd5-grill 第三節第十分支只寫在 skill，子代理很少讀 skills。
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
           警告（不改 exit 碼，stdout 印「grill-gate 警告：…」）：沒寫外部系統｜外部系統＝有但樣本表缺或不齊｜新規則退回缺驗收回合質詢｜SA 缺設計形狀小節
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
    # 只用 Workflow，不需要 git 前綴（-NoGit；舊版 _hd5-locate 沒有這個參數就照舊呼叫）
    $noGit = @{}; if ((Get-Command Get-HD5Project).Parameters.ContainsKey('NoGit')) { $noGit['NoGit'] = $true }
    $proj = Get-HD5Project -Start $resolvedCase.Path @noGit
    if (-not $proj.Workflow) { $proj = Get-HD5Project -Start $PSScriptRoot @noGit }
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

# 共用解析（樣本對照表、退回紀錄、功能地圖）：_verify-map-lib.ps1
$vlib = Join-Path $PSScriptRoot '_verify-map-lib.ps1'   # HD5Skills：同一個 tools 資料夾
if (-not (Test-Path -LiteralPath $vlib)) { $vlib = Join-Path $PSScriptRoot '..\..\..\..\agent\scripts\_verify-map-lib.ps1' }   # IMOCore 舊位置
if (Test-Path -LiteralPath $vlib) { . $vlib }
function Assert-VerifyLib([string]$what) {
    if (-not (Get-Command Get-ReworkLog -ErrorAction SilentlyContinue)) {
        Write-Error "GRILL_GATE=fail role=$Role lib: $what 要用 _verify-map-lib.ps1，但找不到（$vlib）或版本太舊。請重新安裝 HD5 工具（不放行）"
        exit 1
    }
}

# 警告（2026-11-25 使用者拍板）：外部系統宣告、樣本表、驗收回合是需求溝通與人工步驟，程式碰不到，擋了容易被敷衍或繞過；
# 照樣判斷，但只印「grill-gate 警告：…」（hook 放行訊息會帶出），exit 碼照舊。真正的防線在產品程式層的測試。
$gateWarnings = @()

# 待拍板行（exit 12 與驗收回合警告共用）：有「待拍板」或「[待確認]」，沒標已轉單、不是總結行、同一行後面也沒接已拍板／已查證
function Test-PendingLine([string]$line) {
    $pm = [regex]::Matches($line, '待拍板|[\[［]\s*待確認\s*[\]］]')
    if ($pm.Count -eq 0) { return $false }
    if ($line -match '已轉單') { return $false }                                       # 轉給非工程角色＝合法終止狀態
    if ($line -match '待拍板\S{0,2}\s*[:：]?\s*(無|0\s*題|0\s*$)') { return $false }      # 「待拍板：無」「待拍板題 0 題」之類的總結行
    $last = $pm[$pm.Count - 1]
    if ($line.Substring($last.Index + $last.Length) -match '已拍板|已查證') { return $false }   # 同一行後面已收斂（例：建議 A [待確認] → 已拍板 A）
    return $true
}

# ── 0. 路線閘 ───────────────────────────────────────────────────────────
$route = ''
$routeLine = ''
$risk = ''
$external = ''
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
    # 外部系統（2026-11-25，#2164 R1 樣本不足）：建案時就要判斷「有沒有串外部系統」，寫在路線那一行（建議）或另起一行「外部系統：有｜無」
    $extM = [regex]::Match($routeLine, '外部系統\**\s*[:：]\s*\**\s*(有|無)')
    if (-not $extM.Success) {
        foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $resolvedCase 'case_spec_content') -Filter 'spec_*.md' -File -ErrorAction SilentlyContinue)) {
            $extM = [regex]::Match((Get-Content -Raw -LiteralPath $f.FullName -Encoding UTF8), '(?m)^[\s>*-]*\**外部系統\**\s*[:：]\s*\**\s*(有|無)')
            if ($extM.Success) { break }
        }
    }
    if (-not $extM.Success) {
        $gateWarnings += "外部系統：spec_001.md 沒寫「外部系統：有｜無」（抓網頁、呼叫對方 API、讀對方產的檔案＝有；有 ⇒ SA 列 sa/external-samples.md 樣本對照表，hd5-grill 第三節第九分支）。建議寫在路線那一行：路線：…，高風險：…，外部系統：無，理由：…"
        $routeNote += ' external=unknown'
    } else {
        $external = $extM.Groups[1].Value
        $routeNote += " external=$(if ($external -eq '有') { 'yes' } else { 'no' })"
    }
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
                if (-not (Test-PendingLine $line)) { continue }
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

# ── 1c. 外部系統樣本閘（外部系統：有，派實作／QA 前；2026-11-25）────────────────────
# #2164 R1：開發只用一個真實電號測，另外兩種電號型態到驗收才炸。sa/external-samples.md 的樣本對照表至少一列，
# 每列「真實樣本」要有值，或寫「待提供（誰）」（測試資料由需求方準備，開發不造）。
if ($external -eq '有' -and $isDownstream) {
    Assert-VerifyLib '外部系統樣本閘'
    $smpPath = Join-Path $resolvedCase 'sa\external-samples.md'
    $why = ''
    if (-not (Test-Path -LiteralPath $smpPath)) { $why = '缺 sa/external-samples.md' }
    else {
        $smp = Get-ExternalSamples -Path $smpPath
        if (-not $smp.Found) { $why = 'sa/external-samples.md 沒有樣本對照表（表頭要有「變化」與「真實樣本」欄）' }
        elseif (@($smp.Rows).Count -eq 0) { $why = 'sa/external-samples.md 的樣本對照表一列都沒有' }
        else {
            $bad = @($smp.Rows | Where-Object { $_.Problem } | ForEach-Object { "「$($_.Name)」$($_.Problem)" })
            if ($bad.Count) { $why = 'sa/external-samples.md 樣本不齊：' + ($bad -join '；') }
        }
    }
    if ($why) {
        $gateWarnings += "外部系統樣本：$why。SA 要列出對方會有幾種變化（類型、版型、期間、欄位有無、錯誤頁），每種寫真實樣本，沒有的寫「待提供（誰）」並轉題給需求方（hd5-grill 第三節第九分支）"
    } else {
        $grillNote += " samples=$(@($smp.Rows).Count)"
    }
}

# ── 1d. 驗收回合閘（qa/rework-log.md 有「新規則」退回，派實作／QA 前；-Skip 時一起跳過；2026-11-25）───────
# #2164 R3、R4：需求方在退回裡給了新規則，開發照自己的理解做、邊界寫在送驗留言 ⇒ 又退一輪。
# 每個處理類別＝新規則的輪次 R{k}，pm/ 或 sa/ 的 grill-*.md 要有標題含「驗收回合」與 R{k} 的小節，
# 小節內至少一個已拍板／已查證／已轉單，而且沒有待拍板行（判定同 exit 12）。
if ($isDownstream -and -not $Skip) {
    $rwPath = Join-Path $resolvedCase 'qa\rework-log.md'
    if (Test-Path -LiteralPath $rwPath) {
        Assert-VerifyLib '驗收回合閘'
        $rw = Get-ReworkLog -Path $rwPath
        $ruleRounds = @($rw.Rows | Where-Object { $_.Category -match '新規則' } | ForEach-Object { $_.Round } | Sort-Object -Unique)
        if ($ruleRounds.Count) {
            $okRounds = @{}; $badSec = @()
            foreach ($dir in 'pm', 'sa') {
                foreach ($g in @(Get-ChildItem -LiteralPath (Join-Path $resolvedCase $dir) -Filter 'grill-*.md' -File -ErrorAction SilentlyContinue)) {
                    $gl = @(Get-Content -LiteralPath $g.FullName -Encoding UTF8)
                    for ($i = 0; $i -lt $gl.Count; $i++) {
                        $hm = [regex]::Match($gl[$i], '^(#{1,6})\s+.*驗收回合')
                        if (-not $hm.Success) { continue }
                        $lvl = $hm.Groups[1].Value.Length
                        $rounds = @([regex]::Matches($gl[$i], 'R\s*(\d+)') | ForEach-Object { [int]$_.Groups[1].Value })
                        $body = @()
                        for ($j = $i + 1; $j -lt $gl.Count; $j++) {
                            $h2 = [regex]::Match($gl[$j], '^(#{1,6})\s'); if ($h2.Success -and $h2.Groups[1].Value.Length -le $lvl) { break }
                            $body += $gl[$j]
                        }
                        $hasMarker = (($body -join "`n") -match $markerPattern)
                        $pend = @($body | Where-Object { Test-PendingLine $_ })
                        if ($hasMarker -and $pend.Count -eq 0) { foreach ($k in $rounds) { $okRounds[$k] = "$dir/$($g.Name)" } }
                        else { $badSec += "$dir/$($g.Name):$($i + 1)（$(if (-not $hasMarker) { '沒有已拍板／已查證／已轉單' } else { "還有 $($pend.Count) 題待拍板" })）" }
                    }
                }
            }
            $missRounds = @($ruleRounds | Where-Object { -not $okRounds.ContainsKey($_) })
            if ($missRounds.Count) {
                $gateWarnings += ("驗收回合：qa/rework-log.md 的 " + (($missRounds | ForEach-Object { "R$_" }) -join '、') + " 退回是「新規則」，" +
                    "但 pm/ 或 sa/ 的 grill-*.md 沒有收斂完的「驗收回合 R{k}」小節" + $(if ($badSec.Count) { "（不合格的小節：$($badSec -join '；')）" } else { '' }) +
                    "。先查判斷依據的欄位何時被寫入、用選擇題請需求方逐項勾，答案寫進「## 驗收回合 R{k}」小節再派實作（hd5-grill 第二節第 6 條）")
            }
            $grillNote += " rework-rules=$(($ruleRounds | ForEach-Object { "R$_" }) -join ',')"
        }
    }
}

# ── 1e. 設計形狀（四角色／PM 端已完成，派實作／QA 前；-Skip 時一起跳過；2026-11-28）───────
# SA 設計質詢的第十分支（hd5-grill 第三節第 1 條）：sa/grill-*.md 要有標題含「設計形狀」的小節，
# 小節內至少一個已拍板／已查證／已轉單或「N/A」。只警告不擋：寫得好不好是內容判斷，擋了只會換來一個空殼小節。
if ($isDownstream -and -not $Skip -and $route -in @('四角色', 'PM端已完成')) {
    $shapeOk = $false; $shapeBad = @()
    foreach ($g in @(Get-ChildItem -LiteralPath (Join-Path $resolvedCase 'sa') -Filter 'grill-*.md' -File -ErrorAction SilentlyContinue)) {
        $gl = @(Get-Content -LiteralPath $g.FullName -Encoding UTF8)
        for ($i = 0; $i -lt $gl.Count; $i++) {
            $hm = [regex]::Match($gl[$i], '^(#{1,6})\s+.*設計形狀')
            if (-not $hm.Success) { continue }
            $lvl = $hm.Groups[1].Value.Length; $body = @()
            for ($j = $i + 1; $j -lt $gl.Count; $j++) {
                $h2 = [regex]::Match($gl[$j], '^(#{1,6})\s'); if ($h2.Success -and $h2.Groups[1].Value.Length -le $lvl) { break }
                $body += $gl[$j]
            }
            if ((($body -join "`n") -match $markerPattern) -or (($body -join "`n") -cmatch 'N/A')) { $shapeOk = $true } else { $shapeBad += "sa/$($g.Name):$($i + 1)" }
        }
    }
    if ($shapeOk) { $grillNote += ' design-shape=ok' }
    else {
        $gateWarnings += ("設計形狀：sa/grill-*.md 沒有收斂的「設計形狀」小節" + $(if ($shapeBad.Count) { "（小節裡沒有已拍板／已查證／已轉單或 N/A：$($shapeBad -join '、')）" } else { '' }) +
            "。SA 設計質詢要回答第十分支：資料形狀、領域規則放哪、邊界、冪等、共用狀態、重新設計還是硬接、2～3 個備選方案；無關的項寫「N/A－理由」（hd5-grill 第三節第 1 條）")
    }
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
        if (-not (Get-Command Test-VerifyMap -ErrorAction SilentlyContinue)) { . $vlib }
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

foreach ($w in $gateWarnings) { Write-Output "grill-gate 警告：$w" }
Write-Output "GRILL_GATE=pass role=$Role $routeNote $grillNote$riskNote$featureNote"
exit 0
