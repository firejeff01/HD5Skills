<#
.SYNOPSIS
  把案子的結案報告 ai-case-report.md 掛到 Azure DevOps 工單附件。🔴 預設只預覽；使用者同意後加 -Upload 才真的上傳。

.DESCRIPTION
  規範見 hd5-case-report skill（報告內容）與 hd5-workitem skill（工具）。結案報告是跨工單交接記憶：
  之後任何工單引用到這張單時，fetch-workitem.ps1 會自動找這個固定檔名的附件下載。

  規則：
    - 檔名固定 ai-case-report.md，不接受其他檔名（引用端靠檔名找）
    - Azure DevOps 附件只能新增不能刪除：重傳會多一份同名附件，引用端取上傳時間最新的一份。
      「更新報告」就是再上傳一次；不要為了覆蓋去改檔名
    - 上傳前檢查：內容長度、沒有殘留範本佔位符 {{…}}、有第 1／2／3／5／6 節、有 commit 列；不合格就停（-Force 可略過）
    - 不帶 -Upload：印出目標工單標題、狀態、既有報告版數後就停（預覽），工單沒有任何變動
    - 帶 -Upload：先過工單閘（與改「待驗收」同一套：獨立驗收、站上關卡、功能地圖、Pass 有證據；需要 -CasePath（有 -CaseName 且 <SpecRoot>/<CaseName> 存在時自動推得），
      檢查器找不到就 fail closed；沒有案子且使用者同意時用 -SkipAcceptanceGate '<理由>'，理由不可空白、略過會印出來），
      過了才上傳附件並掛到工單（只新增附件，不改工單其他欄位）。預覽不擋，但會印出工單閘結果
    - （相容舊參數）-WhatIfOnly 與預設相同，只預覽；同時給 -Upload 與 -WhatIfOnly 時以預覽為準

  工單：完整網址或純號碼（專案網址依序取 -ProjectUrl → AZURE_DEVOPS_PROJECT_URL → .claude/workflow.json 的 tracker.url）。
  找到 .claude/workflow.json 但 tracker.type 不是 azure-devops ⇒ 拒絕執行。
  報告位置：-ReportPath，或 -CaseName（＋ -SpecRoot，預設由 .claude/workflow.json 推 <專案>/<paths.aiService>/spec）。

  認證（與 workitem-ops 共用 _auth.ps1）：-Pat → 環境變數 AZURE_DEVOPS_PAT_WRITE → AZURE_DEVOPS_PAT → -PatFile →
  本資料夾 pat.write.local.txt → pat.local.txt → Windows 整合驗證（自架 Server；雲端或非 Windows 沒 PAT 就報錯）。PAT 要 Work Items (Read & Write)。本腳本不印 PAT，只印來源。

.EXAMPLE
  # 預覽（預設）
  & "<hd5-tools>/workitem/upload-case-report.ps1" -WorkItemUrl 281 -CaseName my-case

.EXAMPLE
  # 使用者看過預覽、同意後才正式上傳
  & "<hd5-tools>/workitem/upload-case-report.ps1" -WorkItemUrl 281 -CaseName my-case -Upload   # -CasePath 由 -CaseName 推得

.EXAMPLE
  # 報告不在預設位置
  & "<hd5-tools>/workitem/upload-case-report.ps1" -WorkItemUrl "<工單網址>" -ReportPath "D:\path\to\ai-case-report.md"
#>
param(
    [Parameter(Mandatory = $true)][string]$WorkItemUrl,
    [string]$CaseName,
    [string]$ReportPath,
    [string]$SpecRoot,
    [string]$ProjectUrl,
    [string]$Pat,
    [string]$PatFile,
    [string]$ConfigStart,
    # 憑證：預設不驗（為了自架 Azure DevOps Server 的自簽憑證，同原版）；連雲端想驗證就加 -StrictCertificate。-SkipCertificateCheck 為相容舊參數（本來就預設略過）
    [switch]$SkipCertificateCheck,
    [switch]$StrictCertificate,
    [switch]$Upload,
    # 工單閘：案子資料夾 <AI_Service>/spec/<案名>（-Upload 時必填）；沒有案子且使用者同意時用 -SkipAcceptanceGate '<理由>'
    [string]$CasePath,
    [string]$SkipAcceptanceGate,
    [string]$ToolsDir,
    [string]$VerifyRoot,
    [switch]$WhatIfOnly,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$SkipCertificateCheck = -not $StrictCertificate   # 預設不驗憑證；-StrictCertificate 才驗
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
. (Join-Path $PSScriptRoot '_devops-lib.ps1')

$FixedName = 'ai-case-report.md'
$ctx = Get-HD5TrackerContext -ConfigStart $ConfigStart -CasePath $CasePath -ScriptRoot $PSScriptRoot
Assert-HD5AzureDevOpsTracker -Context $ctx

# --- 找報告檔、檢查內容 -----------------------------------------------------
if (-not $ReportPath) {
    if (-not $CaseName) { throw '請提供 -CaseName（報告預設在 <AI_Service>/spec/<案名>/ai-case-report.md）或 -ReportPath' }
    if ([string]::IsNullOrWhiteSpace($SpecRoot)) { $SpecRoot = Get-HD5DefaultSpecRoot -Context $ctx }
    if ([string]::IsNullOrWhiteSpace($SpecRoot)) { throw '找不到案子資料夾：請給 -SpecRoot <AI_Service/spec> 或 -ReportPath' }
    $ReportPath = Join-Path (Join-Path $SpecRoot $CaseName) $FixedName
}
if (-not (Test-Path -LiteralPath $ReportPath)) { throw "找不到報告：$ReportPath（先依 hd5-case-report skill 產出）" }
$ReportPath = (Resolve-Path -LiteralPath $ReportPath).Path
if ([IO.Path]::GetFileName($ReportPath) -ne $FixedName) {
    throw "檔名必須是 $FixedName（引用端靠固定檔名找），目前是：$([IO.Path]::GetFileName($ReportPath))"
}

$content = Get-Content -LiteralPath $ReportPath -Raw -Encoding UTF8
$problems = @()
if ([string]::IsNullOrWhiteSpace($content) -or $content.Length -lt 200) { $problems += '內容過短（< 200 字元），看起來不是完整報告' }
$holders = @([regex]::Matches([string]$content, '\{\{[^}]*\}\}') | ForEach-Object { $_.Value } | Select-Object -Unique)
if ($holders.Count -gt 0) { $problems += "殘留範本佔位符：$($holders -join '、')" }
foreach ($h in '## 1.', '## 2.', '## 3.', '## 5.', '## 6.') {
    if ([string]$content -notmatch [regex]::Escape($h)) { $problems += "缺少章節「$h」" }
}
if ([string]$content -notmatch '(?m)^\s*-\s*\**commit') { $problems += '找不到 commit 資訊列（報告必須帶 commit hash，引用端靠它驗證時效）' }

if ($problems.Count -gt 0) {
    Write-Host "⚠ 報告檢查未通過：" -ForegroundColor Yellow
    $problems | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
    if (-not $Force) { throw '已停止，沒有上傳。修正後重跑；確定要照傳請加 -Force。' }
    Write-Host "  （-Force：略過檢查照傳）" -ForegroundColor DarkGray
}

# --- 工單閘（與改「待驗收」同一套，見 _acceptance-gate.ps1）：連網之前判 -------
# 正式上傳（-Upload 且沒有 -WhatIfOnly）沒過就擋；預覽不擋，但先印出閘的結果讓使用者知道正式上傳會不會被擋。
$isPreview = (-not $Upload) -or $WhatIfOnly
# 有 -CaseName、沒 -CasePath：推 <SpecRoot>/<CaseName>；資料夾存在才用，不存在就照樣當「沒給 -CasePath」擋
if ([string]::IsNullOrWhiteSpace($CasePath) -and -not [string]::IsNullOrWhiteSpace($CaseName)) {
    $sr = $SpecRoot
    if ([string]::IsNullOrWhiteSpace($sr)) { $sr = Get-HD5DefaultSpecRoot -Context $ctx }
    if (-not [string]::IsNullOrWhiteSpace($sr)) {
        $cand = Join-Path $sr $CaseName
        if (Test-Path -LiteralPath $cand -PathType Container) { $CasePath = $cand; Write-Host "  工單閘｜-CasePath 由 -CaseName 推得：$CasePath" }
    }
}$vlib = Resolve-HD5VerifyMapLib -ToolsDir $ToolsDir -Context $ctx -ScriptRoot $PSScriptRoot
if ($vlib.Path -and [string]::IsNullOrWhiteSpace($SkipAcceptanceGate)) { . $vlib.Path }
if ([string]::IsNullOrWhiteSpace($VerifyRoot) -and $ctx.ProjectDir) { $VerifyRoot = Join-Path $ctx.ProjectDir (Join-Path $ctx.AiService 'verify') }
$gateOk = Assert-HD5AcceptanceGate -CasePath $CasePath -SkipReason $SkipAcceptanceGate -Preview:$isPreview -PreviewToleratesMissingCase `
    -ActionLabel '上傳結案報告' -VerifyRoot $VerifyRoot -VerifyLibPath $vlib.Path -VerifyLibSearched $vlib.Searched

# --- 解析工單、認證、讀目標工單 ---------------------------------------------
$WorkItemUrl = Resolve-DevOpsWorkItemInput -WorkItem $WorkItemUrl -ProjectUrl $ProjectUrl -Context $ctx
$ref = Resolve-DevOpsWorkItemUrl -Url $WorkItemUrl
if (-not $ref.Project) { throw "工單網址缺少專案段（需要 https://host/{organization}/{project}/_workitems/edit/NN）：$WorkItemUrl" }
$id = $ref.Id

$auth = New-DevOpsAuthContext -Pat $Pat -PatFile $PatFile -ScriptRoot $PSScriptRoot -Write -TargetUrl "$($ref.Origin)/$($ref.Collection)"
$headers = $auth   # 認證內容（PAT 標頭或 Windows 整合驗證），由 Get-DevOpsWebParams 套用
Enable-HD5Tls12
$origCertPolicy = $null
if ($SkipCertificateCheck) { $origCertPolicy = Enable-DevOpsTrustAllCerts }
try {

$wi = Get-DevOpsWorkItem -ApiRoot $ref.ProjectApi -Id $id -Headers $headers
$existing = @((Get-DevOpsAttachments -WorkItem $wi) | Where-Object { $_.Name -ieq $FixedName })
$version = $existing.Count + 1

Write-Host "=== 上傳結案報告（只新增附件，不改動工單任何欄位）===" -ForegroundColor Cyan
Write-Host "目標工單：#$id　$($wi.fields.'System.Title')"
Write-Host "目前狀態：$($wi.fields.'System.State')　專案：$($wi.fields.'System.TeamProject')"
Write-Host "報告檔案：$ReportPath（$([Math]::Round((Get-Item -LiteralPath $ReportPath).Length / 1KB, 1)) KB）"
Write-Host "既有同名報告：$($existing.Count) 份 → 本次上傳為第 $version 版（引用端取最新）"
Write-Host "認證：$($auth.Source)"

# 退回檢討（2026-11-25）：需求方已驗收完成（目前狀態，或歷程進過 tracker.doneStates）⇒ 報告 5.1、退回總帳要齊（check-rework-ledger.mjs）
$updates = @(Get-DevOpsWorkItemUpdates -ApiRoot $ref.ProjectApi -Id $id -Headers $headers)
$accepted = (Test-HD5StateIsDone -State ([string]$wi.fields.'System.State') -DoneStates $ctx.DoneStates) -or (Test-HD5HistoryReachedDone -Updates $updates -DoneStates $ctx.DoneStates)
if ($accepted) {
    Write-Host "  工單閘｜需求方已驗收完成：檢查結案報告 5.1 退回檢討與退回總帳"
    $ledgerTool = Resolve-HD5ToolFile -Name 'check-rework-ledger.mjs' -ToolsDir $ToolsDir -Context $ctx -ScriptRoot $PSScriptRoot
    $k = Get-HD5RejectionCount -Updates $updates -RejectedStates $ctx.RejectedStates
    $reworkOk = Assert-HD5ReworkGate -CasePath $CasePath -SkipReason $SkipAcceptanceGate -Stage done -Rejections $k -WorkItemId ([string]$id) `
        -LedgerTool $ledgerTool.Path -LedgerToolSearched $ledgerTool.Searched -Preview:$isPreview -ActionLabel '上傳結案報告'
    if (-not $reworkOk) { $gateOk = $false }
}

if (-not $Upload -or $WhatIfOnly) {
    Write-Host ""
    if (-not $gateOk) { Write-Host "（工單閘目前未通過：照現況加 -Upload 會被擋）" -ForegroundColor Red }
    Write-Host "（預覽：未上傳，工單 #$id 沒有任何變動。確認目標工單、內容無機密，且使用者同意後，加 -Upload 正式上傳）" -ForegroundColor Yellow
    return
}

# --- 上傳：POST 附件 → PATCH relations 掛到工單 -----------------------------
$bytes = [IO.File]::ReadAllBytes($ReportPath)
$uploadUrl = "$($ref.ProjectApi)/wit/attachments?fileName=$([Uri]::EscapeDataString($FixedName))&api-version=5.0"
try {
    $wp = Get-DevOpsWebParams @{ Uri = $uploadUrl; Headers = $headers; Method = 'Post'; Body = $bytes; ContentType = 'application/octet-stream' }
    $up = Invoke-RestMethod @wp
}
catch {
    $status = 0
    try { $status = [int]$_.Exception.Response.StatusCode } catch { }
    if ($status -in 401, 403) { throw "HTTP $status：沒有寫入權限。PAT 要有 Work Items (Read & Write)；Windows 整合驗證要有專案 Contributor。設定方式見 hd5-workitem skill。目前認證來源：$($auth.Source)" }
    throw
}

$patch = @(
    @{
        op    = 'add'
        path  = '/relations/-'
        value = @{
            rel        = 'AttachedFile'
            url        = $up.url
            attributes = @{ comment = "結案報告 v$version（$(Get-Date -Format 'yyyy-MM-dd HH:mm')）" }
        }
    }
)
# ConvertTo-Json 遇到單元素陣列會吐成物件，JSON Patch 端點只吃陣列，補上包裝
$json = $patch | ConvertTo-Json -Depth 5
if (@($patch).Count -eq 1) { $json = "[$json]" }
$body = [Text.Encoding]::UTF8.GetBytes($json)
$patchUrl = "$($ref.ProjectApi)/wit/workitems/$id`?api-version=5.0"
$wp = Get-DevOpsWebParams @{ Uri = $patchUrl; Headers = $headers; Method = 'Patch'; Body = $body; ContentType = 'application/json-patch+json; charset=utf-8' }
Invoke-RestMethod @wp | Out-Null

Write-Host ""
Write-Host "✅ 已把 $FixedName（第 $version 版）掛到工單 #$id" -ForegroundColor Green
Write-Host "連結：$(Get-DevOpsWorkItemWebUrl -Origin $ref.Origin -Collection $ref.Collection -Project $ref.Project -Id $id)"

}
finally {
    Restore-DevOpsCertPolicy $origCertPolicy
}
