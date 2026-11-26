<#
.SYNOPSIS
  讀 Azure DevOps 工單（標題／描述／內嵌圖片／附件／引用工單），輸出成案子骨架 <AI_Service>/spec/<案名>/。

.DESCRIPTION
  規範見 hd5-workitem skill。會在 spec/<案名>/ 底下建立 case_spec_content、pm、sa、pg、qa 資料夾，
  並把工單描述轉成 case_spec_content/spec_001.md、圖片存成 image1..N.png。
  工單附件（relations 內的 AttachedFile，例如需求方上傳的需求文件／HTML）
  會下載到 case_spec_content/attachments/，並在 spec_001.md 末尾列出清單。
  加 -NoAttachments 可略過附件下載。

  留言（2026-11-24）：建案時一併把留言寫成 case_spec_content/comments.md（舊→新，每則標 id／時間／人；需求方常在留言回傳答覆檔、補充需求）。
    -ExcludeCommentId（別名 -ExcludeId，可多個）排除指定留言：被排除的連內容都不擷取，檔頭只記 id。-NoComments 不抓留言。
    comments.md 已存在且屬於別張工單時改存 comments-<工單號>.md；同一張工單重抓會覆蓋。
    -PeekOnly 只列留言 id／時間／人（不印內容），方便先決定要排除哪幾則。

  -PeekOnly：只印出標題／類型／狀態／附件清單／引用工單編號／描述摘要，不建立任何檔案。
    決定案名之前先看內容用（不必先用暫定名跑一次再重跑）。此模式不需要 -CaseName。

  -Replace：同一張工單重抓時，覆蓋既有的那份 spec_00N.md（依檔頭「來源工單」比對）而不是另存 spec_002.md，
    並清掉 attachments/ 重新下載。related/{工單號}/verify.md 不會被覆蓋。
    沒帶 -Replace 時另存遞增檔名（就地追加第二張工單時用）。

  引用工單（深度一層，加 -NoRelated 可略過）：
    工單 relations 內的正式連結（父／子／Related／前後置）、描述內帶完整網址的提及、
    描述內的純文字 #NNN，都會被展開到 case_spec_content/related/{工單號}/workitem.md
    （標題／狀態／描述／附件清單／它自己的正式連結），並在 spec_001.md 末尾列成「引用工單」表。
    引用工單若掛有固定檔名的結案報告 ai-case-report.md（多份取最新），會一併下載到同資料夾。
    其他附件只列清單不下載，需要時用 fetch-related-attachments.ps1 按需抓。
    ⚠️ 純文字 #NNN 未經驗證（可能是裁定編號或別專案同號工單）：腳本會在 related/{工單號}/verify.md
    產一份驗證骨架（已存在則不動），建案者比對標題與上下文後把結果填進去。

  工單怎麼給：完整網址（/_workitems/edit/NN、/_backlogs/…?workitem=NN、/_sprints/backlog/…?workitem=NN），
    或純號碼（專案網址依序取 -ProjectUrl → 環境變數 AZURE_DEVOPS_PROJECT_URL → .claude/workflow.json 的 tracker.url）。
  找到 .claude/workflow.json 但 tracker.type 不是 azure-devops ⇒ 拒絕執行。
  案子資料夾：-SpecRoot，預設 <專案>/<paths.aiService>/spec（由 .claude/workflow.json 推）。

  認證（與 workitem-ops 共用 _auth.ps1）：-Pat → 環境變數 AZURE_DEVOPS_PAT → -PatFile → 本資料夾 pat.local.txt →
    Windows 整合驗證（自架 Server；雲端或非 Windows 沒 PAT 就報錯）。PAT 要 Work Items - Read。
  本腳本只讀不寫工單。

.EXAMPLE
  # 先看內容再決定案名（不落檔）
  & "<hd5-tools>/workitem/fetch-workitem.ps1" -WorkItemUrl "https://dev.azure.com/<org>/<project>/_workitems/edit/123" -PeekOnly

.EXAMPLE
  & "<hd5-tools>/workitem/fetch-workitem.ps1" -WorkItemUrl 123 -CaseName my-case

.EXAMPLE
  # 改引用參數後重抓同一張，覆蓋 spec_001.md
  & "<hd5-tools>/workitem/fetch-workitem.ps1" -WorkItemUrl "<工單網址>" -CaseName my-case -NoRelated -Replace
#>
param(
    [Parameter(Mandatory = $true)][string]$WorkItemUrl,
    [string]$CaseName,
    [string]$SpecRoot,
    [string]$ProjectUrl,
    [string]$Pat,
    [string]$PatFile,
    [string]$ConfigStart,
    # 憑證：預設不驗（為了自架 Azure DevOps Server 的自簽憑證，同原版）；連雲端想驗證就加 -StrictCertificate。-SkipCertificateCheck 為相容舊參數（本來就預設略過）
    [switch]$SkipCertificateCheck,
    [switch]$StrictCertificate,
    [switch]$NoAttachments,
    [switch]$NoRelated,
    [int]$MaxRelated = 15,
    [switch]$PeekOnly,
    [switch]$Replace,
    # 留言：排除這些留言 id（不擷取內容）；-NoComments 完全不抓
    [Alias('ExcludeId')][int[]]$ExcludeCommentId,
    [switch]$NoComments
)

$ErrorActionPreference = 'Stop'
$SkipCertificateCheck = -not $StrictCertificate   # 預設不驗憑證；-StrictCertificate 才驗
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
. (Join-Path $PSScriptRoot '_devops-lib.ps1')

if (-not $PeekOnly -and [string]::IsNullOrWhiteSpace($CaseName)) {
    throw '請提供 -CaseName；還沒決定名字的話先用 -PeekOnly 看內容（不落檔）'
}
$ctx = Get-HD5TrackerContext -ConfigStart $ConfigStart -ScriptRoot $PSScriptRoot
Assert-HD5AzureDevOpsTracker -Context $ctx
if (-not $PeekOnly) {
    if ([string]::IsNullOrWhiteSpace($SpecRoot)) { $SpecRoot = Get-HD5DefaultSpecRoot -Context $ctx }
    if ([string]::IsNullOrWhiteSpace($SpecRoot)) { throw '找不到案子資料夾：請給 -SpecRoot <AI_Service/spec>，或在專案的 .claude/workflow.json 設 paths.aiService' }
    $SpecRoot = [IO.Path]::GetFullPath($SpecRoot)
}
$WorkItemUrl = Resolve-DevOpsWorkItemInput -WorkItem $WorkItemUrl -ProjectUrl $ProjectUrl -Context $ctx
$ref = Resolve-DevOpsWorkItemUrl -Url $WorkItemUrl

# 🔴 本檔【不得】內嵌任何 PAT，也不印 PAT。取用順序見 _auth.ps1 的 New-DevOpsAuthContext。
$auth = New-DevOpsAuthContext -Pat $Pat -PatFile $PatFile -ScriptRoot $PSScriptRoot -TargetUrl "$($ref.Origin)/$($ref.Collection)"
$headers = $auth   # 認證內容（PAT 標頭或 Windows 整合驗證），由 Get-DevOpsWebParams 套用
Enable-HD5Tls12
$origCertPolicy = $null
if ($SkipCertificateCheck) { $origCertPolicy = Enable-DevOpsTrustAllCerts }
$relScript = Join-Path $PSScriptRoot 'fetch-related-attachments.ps1'
try {

# --- 抓取工單 ---------------------------------------------------------------
if (-not $ref.Project) { throw "工單網址缺少專案段（需要 https://host/{collection}/{project}/_workitems/edit/NN）：$WorkItemUrl" }
$id = $ref.Id

Write-Host "抓取工單 #$id ($($ref.Collection)/$($ref.Project)) ..."
$wi = Get-DevOpsWorkItem -ApiRoot $ref.ProjectApi -Id $id -Headers $headers

$title = $wi.fields.'System.Title'
$type = $wi.fields.'System.WorkItemType'
$state = $wi.fields.'System.State'
$html = Get-DevOpsDescriptionHtml -WorkItem $wi
if ($html -eq '') { Write-Warning "工單 #$id 沒有描述內容" }
$htmlOriginal = $html   # 引用偵測用原始 HTML（圖片網址被改寫前）

# --- Peek：只看不寫 -----------------------------------------------------------
if ($PeekOnly) {
    $pAtts = @(Get-DevOpsAttachments -WorkItem $wi)
    $pRefs = @(Get-DevOpsWorkItemRefs -WorkItem $wi -Html $htmlOriginal -SelfId $id)
    $pMd = ConvertFrom-DevOpsHtml -Html $html
    $limit = 800
    Write-Host ""
    Write-Host "=== PEEK #$id（未建立任何檔案）==="
    Write-Host "標題：$title"
    Write-Host "類型／狀態：$type／$state　專案：$($wi.fields.'System.TeamProject')"
    Write-Host "附件（$($pAtts.Count)）："
    if ($pAtts.Count -eq 0) { Write-Host "  （無）" }
    foreach ($a in $pAtts) {
        $when = ''
        if ($a.Created) { try { $when = "　$(([datetime]$a.Created).ToString('yyyy-MM-dd'))" } catch { } }
        Write-Host "  - $($a.Name)$when"
    }
    Write-Host "引用工單（$($pRefs.Count)）："
    if ($pRefs.Count -eq 0) { Write-Host "  （無）" }
    # 每張多讀一次，把標題／狀態／有無結案報告／有無描述一起印，決定 -MaxRelated 要留哪幾張才有依據
    $k = 0
    foreach ($r in $pRefs) {
        $k++
        $info = ''
        if ($k -le $MaxRelated) {
            try {
                $rw = Get-DevOpsWorkItem -ApiRoot $ref.CollectionApi -Id $r.Id -Headers $headers
                $hasReport = (@(Get-DevOpsAttachments -WorkItem $rw | Where-Object { $_.Name -ieq 'ai-case-report.md' })).Count -gt 0
                $info = "　$($rw.fields.'System.Title')［$($rw.fields.'System.WorkItemType')／$($rw.fields.'System.State')］"
                if ($hasReport) { $info += '　結案報告✅' }
                if ((Get-DevOpsDescriptionHtml -WorkItem $rw) -eq '') { $info += '　（無描述）' }
                if ([string]$rw.fields.'System.TeamProject' -ne $ref.Project) { $info += '　⚠️跨專案' }
            }
            catch { $info = '　查無此工單／讀取失敗' }
        }
        else { $info = "　（超過 -MaxRelated $MaxRelated，未讀取）" }
        Write-Host "  - #$($r.Id)　$(ConvertTo-DevOpsRefTierLabel -Tier $r.Tier -Via $r.Via)$info"
    }
    if (-not $NoComments) {
        try {
            $pSel = Select-HD5Comments -Comments @(Get-DevOpsWorkItemComments -ApiRoot $ref.ProjectApi -Id $id -Headers $headers) -ExcludeId $ExcludeCommentId
            Write-Host "留言（$($pSel.Comments.Count)$(if ($pSel.ExcludedIds.Count) { "；已排除 id $($pSel.ExcludedIds -join '、')" })；只列 id，不印內容——要排除的用 -ExcludeCommentId）："
            if ($pSel.Comments.Count -eq 0) { Write-Host "  （無）" }
            foreach ($c in @($pSel.Comments | Sort-Object { [datetime]$_.createdDate })) { Write-Host "  - id $($c.id)　$($c.createdDate)　$($c.createdBy.displayName)" }
        }
        catch { Write-Warning "留言讀取失敗：$($_.Exception.Message)" }
    }
    Write-Host "描述摘要（前 $limit 字，共 $($pMd.Length) 字）："
    Write-Host "----------------------------------------"
    Write-Host ($pMd.Substring(0, [Math]::Min($limit, $pMd.Length)))
    if ($pMd.Length -gt $limit) { Write-Host "…" }
    Write-Host "----------------------------------------"
    Write-Host "決定 case-name 後：-CaseName <name> 正式抓取（不帶 -PeekOnly）"
    return
}

# --- 建立 case 骨架 ---------------------------------------------------------
$caseDir = Join-Path $SpecRoot $CaseName
foreach ($sub in 'case_spec_content', 'pm', 'sa', 'pg', 'qa') {
    New-Item -ItemType Directory -Force (Join-Path $caseDir $sub) | Out-Null
}
$contentDir = Join-Path $caseDir 'case_spec_content'

# 同一張工單是否已抓過（依檔頭「來源工單」比對）：決定 -Replace 要覆蓋哪一份
$existingSame = $null
foreach ($f in @(Get-ChildItem $contentDir -Filter 'spec_*.md' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
    $head = @(Get-Content $f.FullName -TotalCount 6 -Encoding UTF8)
    if (($head -join "`n") -match "來源工單：\[#$id\]") { $existingSame = $f.FullName; break }
}

# --- 下載內嵌圖片 -----------------------------------------------------------
$imgs = [regex]::Matches($html, '<img[^>]*src="([^"]+)"')
$n = 0
foreach ($m in $imgs) {
    $n++
    $src = $m.Groups[1].Value -replace '&amp;', '&'
    $dest = Join-Path $contentDir "image$n.png"
    try {
        $wp = Get-DevOpsWebParams @{ Uri = $src; Headers = $headers; OutFile = $dest; UseBasicParsing = $true }; Invoke-WebRequest @wp
        $html = $html.Replace($m.Groups[1].Value, "image$n.png")
        Write-Host "  圖片 $n -> image$n.png"
    }
    catch {
        Write-Warning "  圖片 $n 下載失敗，保留原始網址：$src"
    }
}

# --- 下載工單附件 -----------------------------------------------------------
# relations 內 rel = 'AttachedFile' 的項目（PM 端 create-workitem.ps1 -AttachFiles 上傳的
# 事件風暴／feature／HTML 就在這裡）。API 已帶 $expand=all，relations 一併回傳。
$attachOk = @()
$attachFail = @()
if (-not $NoAttachments) {
    $atts = @(Get-DevOpsAttachments -WorkItem $wi)   # 一定包 @()：只有一個附件時函式回傳會被拆成單一物件
    if ($atts.Count -gt 0) {
        $attachDir = Join-Path $contentDir 'attachments'
        if ($Replace -and $existingSame -and (Test-Path $attachDir)) {
            Remove-Item -Recurse -Force $attachDir
            Write-Host "  -Replace：已清空 attachments\ 重新下載"
        }
        New-Item -ItemType Directory -Force $attachDir | Out-Null
        $k = 0
        foreach ($a in $atts) {
            $k++
            $name = Get-DevOpsSafeFileName -Name $a.Name -Fallback "attachment$k"
            $path = Get-DevOpsUniquePath -Dir $attachDir -Name $name
            $name = [IO.Path]::GetFileName($path)
            try {
                Save-DevOpsAttachment -Url $a.Url -Dest $path -Headers $headers
                $attachOk += $name
                Write-Host "  附件 -> attachments\$name"
            }
            catch {
                $attachFail += [pscustomobject]@{ Name = $name; Url = $a.Url }
                Write-Warning "  附件下載失敗，保留原始網址：$name -> $($a.Url)"
            }
        }
    }
}

# --- 展開引用工單（深度一層） -----------------------------------------------
# 抓回來的內容是「背景參考」，一律隔離在 related/ 底下，不混進 spec_001.md 的需求本文。
$relatedRows = @()
if (-not $NoRelated) {
    $refs = @(Get-DevOpsWorkItemRefs -WorkItem $wi -Html $htmlOriginal -SelfId $id)
    if ($refs.Count -gt $MaxRelated) {
        Write-Warning "引用工單 $($refs.Count) 張超過上限 $MaxRelated，只展開前 $MaxRelated 張（正式連結優先）；其餘請人工判斷"
        $refs = $refs[0..($MaxRelated - 1)]
    }
    if ($refs.Count -gt 0) {
        Write-Host "展開引用工單 $($refs.Count) 張 ..."
        $relatedRoot = Join-Path $contentDir 'related'
        New-Item -ItemType Directory -Force $relatedRoot | Out-Null
        $fetchedAt = Get-Date -Format 'yyyy-MM-dd HH:mm'

        foreach ($rf in $refs) {
            $row = [ordered]@{
                Id = $rf.Id; Tier = $rf.Tier; Via = $rf.Via
                Title = ''; Type = ''; State = ''; Project = ''
                Report = '—'; Path = ''; Note = ''
            }
            try {
                $rw = Get-DevOpsWorkItem -ApiRoot $ref.CollectionApi -Id $rf.Id -Headers $headers
            }
            catch {
                $status = 0
                try { $status = [int]$_.Exception.Response.StatusCode } catch { }
                if ($status -eq 404) { $row.Note = '查無此工單（純文字編號多半是裁定編號，不是工單）' }
                else { $row.Note = "讀取失敗（HTTP $status）" }
                $relatedRows += [pscustomobject]$row
                Write-Warning "  引用 #$($rf.Id) [$($rf.Via)]：$($row.Note)"
                continue
            }

            $row.Title = [string]$rw.fields.'System.Title'
            $row.Type = [string]$rw.fields.'System.WorkItemType'
            $row.State = [string]$rw.fields.'System.State'
            $row.Project = [string]$rw.fields.'System.TeamProject'
            if ($row.Project -ne $ref.Project) { $row.Note = "⚠️ 跨專案（$($row.Project)），可能是撞號，請確認" }

            $rDir = Join-Path $relatedRoot "$($rf.Id)"
            New-Item -ItemType Directory -Force $rDir | Out-Null
            $rWebUrl = Get-DevOpsWorkItemWebUrl -Origin $ref.Origin -Collection $ref.Collection -Project $row.Project -Id $rf.Id
            $rHtml = Get-DevOpsDescriptionHtml -WorkItem $rw
            $rMd = ConvertFrom-DevOpsHtml -Html $rHtml
            if ($rMd -eq '') { $rMd = '（此工單沒有描述內容）' }
            $rAtts = @(Get-DevOpsAttachments -WorkItem $rw)
            $rLinks = @(Get-DevOpsWorkItemRefs -WorkItem $rw -Html $rHtml -SelfId $rf.Id | Where-Object { $_.Tier -eq 'relation' })

            # 固定檔名的結案報告：有就下載（多份取最新），其他附件只列清單
            $reports = @($rAtts | Where-Object { $_.Name -ieq 'ai-case-report.md' })
            if ($reports.Count -gt 0) {
                $pick = Select-DevOpsLatestAttachment -Attachments $reports
                try {
                    Save-DevOpsAttachment -Url $pick.Url -Dest (Join-Path $rDir 'ai-case-report.md') -Headers $headers
                    $row.Report = "✅ 已下載（共 $($reports.Count) 版，取最新）"
                }
                catch { $row.Report = "⚠️ 下載失敗：$($pick.Url)" }
            }
            else { $row.Report = '無' }

            # 純文字引用：產驗證骨架給 建案者填，重跑不覆蓋（驗證結果要能活過 -Replace）
            if ($rf.Tier -eq 'text' -or $row.Note -like '*跨專案*') {
                $verifyFile = Join-Path $rDir 'verify.md'
                if (-not (Test-Path $verifyFile)) {
                    $v = @(
                        "# 引用驗證：#$($rf.Id)",
                        '',
                        "- 引用來源：工單 #$id 描述中的 $($rf.Via)（腳本無法確認是不是真的工單引用）",
                        "- 抓回標題：$($row.Title)｜類型／狀態：$($row.Type)／$($row.State)｜專案：$($row.Project)",
                        "- 本工單描述的上下文摘錄：（建案者填：提到 #$($rf.Id) 的那句話）",
                        '',
                        '## 驗證結果（建案者擇一打勾並說明）',
                        '',
                        '- [ ] 真實引用——抓回標題與本工單上下文吻合',
                        '- [ ] 疑似非工單引用——對不上（裁定編號、別套編號），已寫進 spec 的 已知未確認',
                        '- [ ] 跨專案撞號——已列出問使用者',
                        '',
                        '說明：（建案者填）',
                        '',
                        "驗證者／時間：（建案者填，例：建案者 $(Get-Date -Format 'yyyy-MM-dd')）"
                    )
                    Set-Content -Path $verifyFile -Value ($v -join "`n") -Encoding utf8
                }
                $row.Note = (@($row.Note, "驗證結果：related/$($rf.Id)/verify.md") | Where-Object { $_ }) -join '；'
            }

            $lines = @(
                "# #$($rf.Id) $($row.Title)",
                '',
                "- 工單：[#$($rf.Id)]($rWebUrl)｜專案 $($row.Project)｜類型 $($row.Type)｜狀態 $($row.State)",
                "- 引用方式：$(ConvertTo-DevOpsRefTierLabel -Tier $rf.Tier -Via $rf.Via)（由工單 #$id 展開）",
                "- 抓取時間：$fetchedAt",
                "- 結案報告 ai-case-report.md：$($row.Report)"
            )
            if ($row.Note) { $lines += "- $($row.Note)" }
            $lines += @(
                '',
                '> ⚠️ 本檔是**背景參考**，不是本 case 的需求本文。內容反映該工單當時的狀態，',
                '> 驗收條件可能已被後續工單改動；與本 case 工單描述衝突時，寫進「已知未確認」問使用者。',
                '',
                '---',
                '',
                $rMd,
                '',
                '---',
                '',
                '## 附件清單（未下載，需要時按需抓）',
                ''
            )
            if ($rAtts.Count -eq 0) { $lines += '- （無附件）' }
            foreach ($a in $rAtts) {
                $when = ''
                if ($a.Created) { try { $when = "（$(([datetime]$a.Created).ToString('yyyy-MM-dd'))）" } catch { } }
                $lines += "- $($a.Name)$when"
            }
            $lines += @(
                '',
                "> 抓指定附件：``& ""$relScript"" -WorkItemUrl ""$rWebUrl"" -CaseName ""$CaseName"" -Name ""<檔名，可用萬用字元>""``（不帶 -Name 則全抓）",
                '',
                '## 此工單的正式連結（未展開；引用只做深度一層）',
                ''
            )
            if ($rLinks.Count -eq 0) { $lines += '- （無）' }
            foreach ($l in $rLinks) { $lines += "- #$($l.Id)（$($l.Via)）" }

            Set-Content -Path (Join-Path $rDir 'workitem.md') -Value ($lines -join "`n") -Encoding utf8
            $row.Path = "related/$($rf.Id)/workitem.md"
            $relatedRows += [pscustomobject]$row
            Write-Host "  引用 #$($rf.Id) [$($rf.Via)] $($row.Title) -> related\$($rf.Id)\　結案報告：$($row.Report)"
        }
    }
}

# --- HTML -> Markdown -------------------------------------------------------
$md = ConvertFrom-DevOpsHtml -Html $html

$header = @"
# $title

- 來源工單：[#$id]($WorkItemUrl)
- 類型：$type ｜ 狀態：$state
- 匯入時間：$(Get-Date -Format 'yyyy-MM-dd HH:mm')

---

"@

# 附件清單附在文末，讓 pm-expert / sa-expert 讀 spec 時就看得到有哪些上游產物
$attachSection = ''
if ($attachOk.Count -gt 0 -or $attachFail.Count -gt 0) {
    # 開頭兩個空字串＝正文與 --- 之間留一個空行；少了會讓 CommonMark 把正文最後一行當成 setext 標題
    $lines = @('', '', '---', '', '## 工單附件', '')
    foreach ($a in $attachOk) {
        $lines += "- [$a](attachments/$([Uri]::EscapeDataString($a)))"
    }
    foreach ($f in $attachFail) {
        $lines += "- ⚠️ $($f.Name) —— 下載失敗，原始網址：$($f.Url)"
    }
    $attachSection = ($lines -join "`n") + "`n"
}

# 引用工單表也附在文末；表格只是索引，內容在 related/{工單號}/workitem.md
$relatedSection = ''
if ($relatedRows.Count -gt 0) {
    $lines = @(
        '', '', '---', '',
        '## 引用工單（自動展開，深度 1）', '',
        '> 以下為**背景參考**，不是本工單的需求本文，PM 讀取時當脈絡用、不得當作驗收條件。',
        '> 「純文字 #編號」的驗證結果記在 `related/{工單號}/verify.md`（建案者填寫，重跑不覆蓋）；「查無此工單」多半是裁定編號而非工單。',
        '> 有 `ai-case-report.md` 的優先讀它（結案時的最終驗收條件／改動範圍／未盡事項／commit）。',
        '',
        '| 工單 | 引用方式 | 標題 | 類型／狀態 | 結案報告 | 本地檔 | 備註 |',
        '|---|---|---|---|---|---|---|'
    )
    foreach ($r in $relatedRows) {
        $t = ($r.Title -replace '\|', '｜')
        $ts = if ($r.Type -or $r.State) { "$($r.Type)／$($r.State)" } else { '' }
        $p = if ($r.Path) { "[$($r.Path)]($($r.Path))" } else { '' }
        $lines += "| #$($r.Id) | $(ConvertTo-DevOpsRefTierLabel -Tier $r.Tier -Via $r.Via) | $t | $ts | $($r.Report) | $p | $($r.Note) |"
    }
    $relatedSection = ($lines -join "`n") + "`n"
}

# --- 留言 → comments.md（脈絡，不混進需求本文）-------------------------------------
$commentsSection = ''; $commentsNote = '已略過（-NoComments）'
if (-not $NoComments) {
    $cErr = $null; $cSel = $null
    try { $cSel = Select-HD5Comments -Comments @(Get-DevOpsWorkItemComments -ApiRoot $ref.ProjectApi -Id $id -Headers $headers) -ExcludeId $ExcludeCommentId }
    catch { $cErr = $_.Exception.Message; Write-Warning "  留言讀取失敗：$cErr" }
    $cFile = Join-Path $contentDir 'comments.md'
    if (Test-Path -LiteralPath $cFile) {
        $cHead = @(Get-Content -LiteralPath $cFile -TotalCount 4 -Encoding UTF8) -join "`n"
        if ($cHead -notmatch "來源工單：\[#$id\]") { $cFile = Join-Path $contentDir "comments-$id.md" }
    }
    $cMd = Format-HD5CommentsMarkdown -Comments $(if ($cSel) { $cSel.Comments } else { @() }) -WorkItemId $id -WorkItemUrl $WorkItemUrl `
        -ExcludedIds $(if ($cSel) { $cSel.ExcludedIds } else { $ExcludeCommentId }) -FetchError $cErr
    [IO.File]::WriteAllText($cFile, $cMd, [Text.UTF8Encoding]::new($false))
    $cName = [IO.Path]::GetFileName($cFile)
    $commentsNote = if ($cErr) { "讀取失敗（$cName 有記錄）" } else { "$(@($cSel.Comments).Count) 則 -> case_spec_content\$cName$(if ($cSel.ExcludedIds.Count) { "（已排除 id $($cSel.ExcludedIds -join '、')）" })" }
    $commentsSection = "`n`n---`n`n## 留言`n`n> 留言另存 [$cName]($cName)（$(if ($cErr) { '讀取失敗' } else { "$(@($cSel.Comments).Count) 則" })）：是**脈絡**不是需求本文，跟本文衝突的寫進 6.1。`n"
}

# --- 決定輸出檔名：同一工單 + -Replace 覆蓋；否則遞增 ----------------------------
$outFile = Join-Path $contentDir 'spec_001.md'
if ($existingSame -and $Replace) {
    $outFile = $existingSame
    Write-Warning "同一工單 #$id 重抓：覆蓋 $([IO.Path]::GetFileName($outFile))（-Replace）。若已做過人工校對，內容需重做"
}
elseif (Test-Path $outFile) {
    $i = 2
    while (Test-Path (Join-Path $contentDir ("spec_{0:000}.md" -f $i))) { $i++ }
    $outFile = Join-Path $contentDir ("spec_{0:000}.md" -f $i)
    if ($existingSame) {
        Write-Warning "同一工單 #$id 已有 $([IO.Path]::GetFileName($existingSame))，本次另存為 $([IO.Path]::GetFileName($outFile))；要覆蓋重抓請加 -Replace"
    }
}
Set-Content -Path $outFile -Value ($header + $md + $attachSection + $commentsSection + $relatedSection) -Encoding utf8

Write-Host ""
Write-Host "完成：$outFile"
Write-Host "圖片：$n 張"
if ($NoAttachments) {
    Write-Host "附件：已略過（-NoAttachments）"
}
else {
    Write-Host "附件：$($attachOk.Count) 個成功、$($attachFail.Count) 個失敗 -> case_spec_content\attachments\"
}
Write-Host "留言：$commentsNote"
if ($NoRelated) {
    Write-Host "引用工單：已略過（-NoRelated）"
}
else {
    $ok = @($relatedRows | Where-Object { $_.Path }).Count
    $miss = @($relatedRows | Where-Object { -not $_.Path }).Count
    $rep = @($relatedRows | Where-Object { $_.Report -like '✅*' }).Count
    $txt = @($relatedRows | Where-Object { $_.Tier -eq 'text' }).Count
    Write-Host "引用工單：$ok 張已展開、$miss 張查無／失敗（純文字待驗證 $txt 張，驗證骨架在 related\{工單號}\verify.md）、結案報告 $rep 份 -> case_spec_content\related\"
}
Write-Host "Case 目錄：$caseDir"

}
finally {
    # 還原憑證驗證政策，不讓「信任全部憑證」外洩到這支腳本以外
    Restore-DevOpsCertPolicy $origCertPolicy
}
