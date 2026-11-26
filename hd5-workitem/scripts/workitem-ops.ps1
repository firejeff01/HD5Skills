<#
.SYNOPSIS
  Azure DevOps 工單維運：看工單、列狀態、留言、指派、改狀態、查人員；可一併套用到上層工單。
  改成「待驗收」類狀態前會先過工單閘。

.DESCRIPTION
  規範見 hd5-workitem skill（SKILL.md）。

  動作（-Action）：
    show       讀工單：標題、型別、狀態、指派、上層鏈、留言數、附件清單（預設動作）
    states     列出這張工單「型別」允許的狀態名稱（改狀態前先看這個，各型別狀態集不同）
    comments   列出留言（時間／人／純文字摘要）。-Id 只列指定的留言、-ExcludeId 排除指定的留言（都可給多個，逗號分隔）；
               篩選在印出之前做，被排除的留言連摘要都不印（例：要求「不要看某則留言」時用 -ExcludeId，不要先全部印出再過濾）
    whoami     顯示目前用哪個身分連 Azure DevOps
    find-user  用 -Query 查人員（顯示名、帳號或信箱），回 DisplayName／Account／Mail
    update     寫入：-Comment／-CommentFile（留言）、-AssignTo（指派）、-State（改狀態）三者任意組合；
               加 -IncludeParents 就沿 Hierarchy-Reverse 往上每一層都做同樣的事；
               加 -WhatIfOnly 只印預覽不寫入。

  專案網址（只給工單號碼時）：-ProjectUrl → 環境變數 AZURE_DEVOPS_PROJECT_URL → .claude/workflow.json 的 tracker.url。
  找到 .claude/workflow.json 但 tracker.type 不是 azure-devops ⇒ 拒絕執行。

  🔴 寫入前一律先跑一次 -WhatIfOnly 給使用者看目標工單標題、上層鏈、狀態、留言內容，使用者同意後才拿掉 -WhatIfOnly。
  🔴 改「待驗收」（或 tracker.acceptanceStates 列的狀態）要給 -CasePath，腳本在連網前檢查工單閘；
     沒有案子（例：緊急修正）且使用者同意略過時，改給 -SkipAcceptanceGate "<理由>"。
  🔴 本腳本不印 PAT，只印認證來源。

.EXAMPLE
  & "<hd5-tools>/workitem/workitem-ops.ps1" "https://dev.azure.com/<org>/<project>/_workitems/edit/123"

.EXAMPLE
  # 只給號碼：專案網址取自 workflow.json 的 tracker.url（或 -ProjectUrl／AZURE_DEVOPS_PROJECT_URL）
  & "<hd5-tools>/workitem/workitem-ops.ps1" 123 -Action states

.EXAMPLE
  # 留言＋指派＋改待驗收，連同上層工單，先預覽
  & "<hd5-tools>/workitem/workitem-ops.ps1" 123 -Action update -CommentFile ".\留言稿.html" -CommentHtml `
      -AssignTo "<帳號或信箱>" -State 待驗收 -CasePath "AI_Service/spec/<案名>" -IncludeParents -WhatIfOnly

.EXAMPLE
  # 只讀需求方回傳答覆的那兩則；或排除某則（例：前一輪的完成通知）
  & "<hd5-tools>/workitem/workitem-ops.ps1" 123 -Action comments -Id 4465,4467
  & "<hd5-tools>/workitem/workitem-ops.ps1" 123 -Action comments -ExcludeId 4471

.EXAMPLE
  & "<hd5-tools>/workitem/workitem-ops.ps1" 123 -Action find-user -Query "<姓名>"
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)][string]$WorkItem,
    [ValidateSet('show', 'states', 'comments', 'whoami', 'find-user', 'update')][string]$Action = 'show',
    [string]$ProjectUrl,
    [string]$Comment,
    [string]$CommentFile,
    [switch]$CommentHtml,
    # comments＝討論串留言（預設，有留言 id）；history＝寫進 System.History 欄位，跟指派／狀態同一次 PATCH（帶 /rev 檢查）
    [ValidateSet('comments', 'history')][string]$CommentVia = 'comments',
    [string]$AssignTo,
    [string]$State,
    [switch]$IncludeParents,
    [int]$MaxDepth = 10,
    [string]$Query,
    # -Action comments：只列這些留言 id／排除這些留言 id（可多個）
    [Alias('CommentId')][int[]]$Id,
    [Alias('ExcludeCommentId')][int[]]$ExcludeId,
    [string]$Pat,
    # PAT 檔（一行 PAT；不進版控）。沒給就找本資料夾的 pat.write.local.txt → pat.local.txt
    [string]$PatFile,
    [switch]$UseWindowsAuth,
    # 憑證：預設不驗（為了自架 Azure DevOps Server 的自簽憑證，同原版）；連雲端想驗證就加 -StrictCertificate。-SkipCertificateCheck 為相容舊參數（本來就預設略過）
    [switch]$SkipCertificateCheck,
    [switch]$StrictCertificate,
    [switch]$WhatIfOnly,
    [string]$CasePath,
    [string]$SkipAcceptanceGate,
    # 從哪裡往上找 .claude/workflow.json（預設：-CasePath → 目前資料夾 → 本腳本資料夾）
    [string]$ConfigStart,
    # HD5 工具資料夾（含 _verify-map-lib.ps1）；預設取 workflow.json 的 paths.tools
    [string]$ToolsDir,
    # 功能地圖資料夾；預設 <專案>/<paths.aiService>/verify
    [string]$VerifyRoot
)

$ErrorActionPreference = 'Stop'
$SkipCertificateCheck = -not $StrictCertificate   # 預設不驗憑證；-StrictCertificate 才驗
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
. (Join-Path $PSScriptRoot '_workitem-ops-lib.ps1')

$ctx = Get-HD5TrackerContext -ConfigStart $ConfigStart -CasePath $CasePath -ScriptRoot $PSScriptRoot
Assert-HD5AzureDevOpsTracker -Context $ctx

# 改「待驗收」前的工單閘：連網之前就判，沒過不碰工單（-WhatIfOnly 只警告，讓預覽照樣能看）
if ($Action -eq 'update' -and (Test-DevOpsStateNeedsAcceptanceGate -State $State -AcceptanceStates $ctx.AcceptanceStates)) {
    # 功能地圖檢查器要在腳本最上層 dot-source（它用 $script: 變數）；找不到時 Assert 會 fail closed
    $vlib = Resolve-HD5VerifyMapLib -ToolsDir $ToolsDir -Context $ctx -ScriptRoot $PSScriptRoot
    if ($vlib.Path -and [string]::IsNullOrWhiteSpace($SkipAcceptanceGate)) { . $vlib.Path }
    if ([string]::IsNullOrWhiteSpace($VerifyRoot) -and $ctx.ProjectDir) { $VerifyRoot = Join-Path $ctx.ProjectDir (Join-Path $ctx.AiService 'verify') }
    $null = Assert-HD5AcceptanceGate -CasePath $CasePath -SkipReason $SkipAcceptanceGate -Preview:$WhatIfOnly -ActionLabel "改成「$State」" `
        -VerifyRoot $VerifyRoot -VerifyLibPath $vlib.Path -VerifyLibSearched $vlib.Searched
}

# 退回紀錄閘（2026-11-25）：改待驗收＝歷程退回 k 次要記滿 k 輪；改驗收完成＝結案報告 5.1＋退回總帳要齊。
# 要讀工單歷程，所以在讀完工單後才判；改驗收完成缺 -CasePath 則在連網前就擋。
$reworkStage = $null
if ($Action -eq 'update') {
    if (Test-DevOpsStateNeedsAcceptanceGate -State $State -AcceptanceStates $ctx.AcceptanceStates) { $reworkStage = 'accept' }
    elseif (Test-HD5StateIsDone -State $State -DoneStates $ctx.DoneStates) {
        $reworkStage = 'done'
        if ([string]::IsNullOrWhiteSpace($CasePath)) { $null = Assert-HD5ReworkGate -CasePath $CasePath -SkipReason $SkipAcceptanceGate -Stage done -Preview:$WhatIfOnly -ActionLabel "改成「$State」" }
    }
}
$ledgerTool = Resolve-HD5ToolFile -Name 'check-rework-ledger.mjs' -ToolsDir $ToolsDir -Context $ctx -ScriptRoot $PSScriptRoot

# 目標解析在認證之前：缺專案網址時不會先去讀 PAT 檔
$target = Resolve-WorkItemTarget -WorkItem $WorkItem -ProjectUrl $ProjectUrl -Context $ctx
$auth = New-DevOpsAuthContext -Pat $Pat -PatFile $PatFile -ScriptRoot $PSScriptRoot -ForceWindows:$UseWindowsAuth -Write -TargetUrl "$($target.Origin)/$($target.Collection)"
Enable-HD5Tls12
$origPolicy = $null
if ($SkipCertificateCheck) { $origPolicy = Enable-DevOpsTrustAllCerts }
try {

$wi = Get-DevOpsWorkItem -Auth $auth -Target $target -SkipCertificateCheck:$SkipCertificateCheck
$target = Resolve-WorkItemProject -Target $target -WorkItem $wi
$loader = { param($id) Get-DevOpsWorkItem -Auth $auth -Target (New-WorkItemTargetObject -Id $id -Origin $target.Origin -Collection $target.Collection -Project $null) -SkipCertificateCheck:$SkipCertificateCheck }

if ($reworkStage -and [string]::IsNullOrWhiteSpace($SkipAcceptanceGate) -and -not [string]::IsNullOrWhiteSpace($CasePath)) {
    $updates = @(Get-DevOpsWorkItemUpdates -Auth $auth -Target $target -SkipCertificateCheck:$SkipCertificateCheck)
    $k = Get-HD5RejectionCount -Updates $updates -RejectedStates $ctx.RejectedStates
    $null = Assert-HD5ReworkGate -CasePath $CasePath -Stage $reworkStage -Rejections $k -WorkItemId ([string]$wi.id) `
        -LedgerTool $ledgerTool.Path -LedgerToolSearched $ledgerTool.Searched -Preview:$WhatIfOnly -ActionLabel "改成「$State」"
}

switch ($Action) {
    'show' {
        Write-Host "=== 工單 ===" -ForegroundColor Cyan
        Write-Host (Format-DevOpsWorkItemLine $wi)
        Write-Host "專案：$($wi.fields.'System.TeamProject')｜建立 $($wi.fields.'System.CreatedDate') by $($wi.fields.'System.CreatedBy'.displayName)｜異動 $($wi.fields.'System.ChangedDate')"
        Write-Host "連結：$($target.WebUrl)"
        Write-Host "認證：$($auth.Source)"
        $parents = @(Get-DevOpsAncestors -WorkItem $wi -Loader $loader -MaxDepth $MaxDepth)
        Write-Host "--- 上層鏈（$($parents.Count) 層）---"
        foreach ($p in $parents) { Write-Host "  ↑ $(Format-DevOpsWorkItemLine $p)" }
        $att = @($wi.relations | Where-Object { $_.rel -eq 'AttachedFile' })
        Write-Host "--- 附件（$($att.Count)）---"
        foreach ($a in $att) { Write-Host "  $($a.attributes.name)" }
        $cm = @(Get-DevOpsComments -Auth $auth -Target $target -SkipCertificateCheck:$SkipCertificateCheck)
        Write-Host "--- 留言（$($cm.Count)）--- 用 -Action comments 看內容"
    }
    'states' {
        $type = [string]$wi.fields.'System.WorkItemType'
        $st = Get-DevOpsWorkItemTypeStates -Auth $auth -Target $target -TypeName $type -SkipCertificateCheck:$SkipCertificateCheck
        Write-Host "型別「$type」允許的狀態（目前：$($wi.fields.'System.State')）：" -ForegroundColor Cyan
        foreach ($s in $st) { Write-Host "  $($s.Name)  [$($s.Category)]" }
    }
    'comments' {
        $all = @(Get-DevOpsComments -Auth $auth -Target $target -SkipCertificateCheck:$SkipCertificateCheck)
        $sel = Select-HD5Comments -Comments $all -Id $Id -ExcludeId $ExcludeId
        $cm = @($sel.Comments)
        $scope = @()
        if ($Id) { $scope += "只列 id $($Id -join '、')" }
        if ($sel.ExcludedIds.Count) { $scope += "已排除 id $($sel.ExcludedIds -join '、')（內容未印）" }
        Write-Host "留言 $($cm.Count) 則（新→舊；工單共 $($all.Count) 則$(if ($scope) { '；' + ($scope -join '；') })）：" -ForegroundColor Cyan
        if ($sel.MissingIds.Count) { Write-Warning "工單上沒有這些留言 id：$($sel.MissingIds -join '、')" }
        foreach ($c in $cm) { Write-Host (Format-HD5CommentLine $c) }
    }
    'whoami' {
        $me = Get-DevOpsCurrentUser -Auth $auth -Target $target -SkipCertificateCheck:$SkipCertificateCheck
        Write-Host "認證方式：$($auth.Source)"
        Write-Host "身分：$($me.DisplayName)（$($me.Account)）"
    }
    'find-user' {
        if ([string]::IsNullOrWhiteSpace($Query)) { throw 'find-user 需要 -Query' }
        $list = @(Find-DevOpsIdentity -Auth $auth -Target $target -Query $Query -SkipCertificateCheck:$SkipCertificateCheck)
        Write-Host "「$Query」找到 $($list.Count) 筆：" -ForegroundColor Cyan
        foreach ($u in $list) { Write-Host "  $($u.DisplayName)｜Account=$($u.Account)｜Mail=$($u.Mail)" }
        if ($list.Count -eq 0) { Write-Host '  （查無此人，試試帳號、信箱或部分姓名）' }
    }
    'update' {
        if ($CommentFile) {
            if (-not (Test-Path -LiteralPath $CommentFile)) { throw "找不到留言檔：$CommentFile" }
            $Comment = Get-Content -LiteralPath $CommentFile -Raw -Encoding UTF8
        }
        $hasComment = -not [string]::IsNullOrWhiteSpace($Comment)
        $html = $null
        if ($hasComment) { $html = ConvertTo-DevOpsCommentHtml -Text $Comment -Html:$CommentHtml }
        $historyHtml = $null
        if ($hasComment -and $CommentVia -eq 'history') { $historyHtml = $html }
        if (-not $hasComment -and -not (New-DevOpsPatchBody -AssignTo $AssignTo -State $State)) { throw 'update 至少要給 -Comment／-CommentFile、-AssignTo、-State 其中一個' }

        $targets = @([pscustomobject]@{ Target = $target; Item = $wi })
        if ($IncludeParents) {
            foreach ($p in @(Get-DevOpsAncestors -WorkItem $wi -Loader $loader -MaxDepth $MaxDepth)) {
                $pt = New-WorkItemTargetObject -Id ([int]$p.id) -Origin $target.Origin -Collection $target.Collection -Project ([string]$p.fields.'System.TeamProject')
                $targets += [pscustomobject]@{ Target = $pt; Item = $p }
            }
        }

        # 狀態名先對型別狀態集驗證（各型別狀態集不同）
        if ($State) {
            foreach ($t in $targets) {
                $type = [string]$t.Item.fields.'System.WorkItemType'
                $st = Get-DevOpsWorkItemTypeStates -Auth $auth -Target $t.Target -TypeName $type -SkipCertificateCheck:$SkipCertificateCheck
                if (-not (Test-DevOpsStateAllowed -State $State -States $st)) {
                    throw "工單 #$($t.Item.id) 型別「$type」沒有狀態「$State」。允許：$(($st | ForEach-Object { $_.Name }) -join '、')"
                }
            }
        }

        Write-Host "=== 即將套用（$($targets.Count) 張）===" -ForegroundColor Cyan
        Write-Host "認證：$($auth.Source)"
        foreach ($t in $targets) { Write-Host "  $(Format-DevOpsWorkItemLine $t.Item)" }
        if ($AssignTo) { Write-Host "指派 → $AssignTo" }
        if ($State) { Write-Host "狀態 → $State" }
        if ($hasComment) {
            $mode = if ($CommentHtml) { 'HTML 原樣送出' } else { '純文字（自動編碼、換行轉 <br/>）' }
            $via = if ($CommentVia -eq 'history') { '寫進 System.History（與指派／狀態同一次更新）' } else { '討論串留言（comments API）' }
            Write-Host "留言（$mode，$via，$($Comment.Length) 字）：" ; Write-Host $Comment
        }
        if ($WhatIfOnly) { Write-Host ''; Write-Host '（-WhatIfOnly：未寫入，工單沒有任何變動）' -ForegroundColor Yellow; return }

        foreach ($t in $targets) {
            $id = $t.Item.id
            if ($hasComment -and $CommentVia -eq 'comments') {
                $c = Add-DevOpsComment -Auth $auth -Target $t.Target -Html $html -SkipCertificateCheck:$SkipCertificateCheck
                Write-Host "✅ #$id 留言 id=$($c.id)" -ForegroundColor Green
            }
            $rev = 0
            if ($historyHtml -and $t.Item.rev) { $rev = [int]$t.Item.rev }
            $patch = New-DevOpsPatchBody -AssignTo $AssignTo -State $State -HistoryHtml $historyHtml -Rev $rev
            if ($patch) {
                $u = Update-DevOpsWorkItemFields -Auth $auth -Target $t.Target -PatchBody $patch -SkipCertificateCheck:$SkipCertificateCheck
                $hist = if ($historyHtml) { '｜留言已寫入歷程' } else { '' }
                Write-Host "✅ #$id 狀態=$($u.fields.'System.State')｜指派=$($u.fields.'System.AssignedTo'.displayName)$hist" -ForegroundColor Green
            }
            Write-Host "   $($t.Target.WebUrl)"
        }
    }
}

}
finally {
    if ($null -ne $origPolicy) { [System.Net.ServicePointManager]::CertificatePolicy = $origPolicy }
}
