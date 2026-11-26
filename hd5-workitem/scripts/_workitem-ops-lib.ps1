<#
.SYNOPSIS
  hd5-workitem 工單維運的共用函式：目標解析、認證（PAT 或 Windows 整合驗證）、API 呼叫、
  工單／上層／狀態清單／留言／指派／人員查詢、改待驗收前的工單閘。

.DESCRIPTION
  由 workitem-ops.ps1 以 dot-source 載入：

      . (Join-Path $PSScriptRoot '_workitem-ops-lib.ps1')

  本檔不可直接執行。🔴 本檔【不得】內嵌任何 PAT、帳密，也不得把 PAT 印出來。
  工單閘要用的功能地圖檢查器（_verify-map-lib.ps1，在 HD5 工具資料夾）由呼叫端找到後 dot-source；
  找不到就 fail closed（Test-DevOpsAcceptanceGate 回不通過）。
  相容 Windows PowerShell 5.1 與 PowerShell 7（不用 ??、三元運算子、-SkipCertificateCheck 只在 7 才帶）。
  必須存成 UTF-8 with BOM（5.1 對無 BOM 的 UTF-8 會用系統字碼頁解析，中文會變亂碼而語法錯誤）。
#>

. (Join-Path $PSScriptRoot '_tracker-config.ps1')
. (Join-Path $PSScriptRoot '_auth.ps1')
. (Join-Path $PSScriptRoot '_acceptance-gate.ps1')
. (Join-Path $PSScriptRoot '_comments.ps1')

# --- 目標解析 ---------------------------------------------------------------
# 接受：
#   1. 完整工單網址：https://host/{org}/{project}/_workitems/edit/123
#                    https://host/{org}/{project}/_sprints/backlog/...?workitem=123
#                    https://host/{org}/_apis/wit/workItems/123（relations 內的網址，沒有 project）
#   2. 純號碼：專案網址依序取 -ProjectUrl → 環境變數 AZURE_DEVOPS_PROJECT_URL → .claude/workflow.json 的 tracker.url
# 沒有 project 時仍可讀工單（工單號在 organization／collection 內唯一），呼叫端要用 Resolve-WorkItemProject 補上。
function Resolve-WorkItemTarget {
    param(
        [Parameter(Mandatory = $true)][string]$WorkItem,
        [string]$ProjectUrl,
        $Context
    )
    $WorkItem = $WorkItem.Trim()
    $id = 0; $origin = $null; $collection = $null; $project = $null

    if ($WorkItem -match '^\d+$') {
        $id = [int]$WorkItem
        $ProjectUrl = Resolve-HD5ProjectUrl -ProjectUrl $ProjectUrl -Context $Context
        if ([string]::IsNullOrWhiteSpace($ProjectUrl)) { throw (Get-HD5MissingProjectUrlMessage) }
        $u = [Uri]$ProjectUrl.Trim().TrimEnd('/')
        $seg = $u.AbsolutePath.Trim('/').Split('/')
        if ($seg.Count -lt 2 -or [string]::IsNullOrWhiteSpace($seg[1])) { throw "專案網址必須含 organization（或 collection）與 project 兩段：$ProjectUrl" }
        $origin = "$($u.Scheme)://$($u.Authority)"
        $collection = $seg[0]
        $project = [Uri]::UnescapeDataString($seg[1])
    }
    else {
        if ($WorkItem -match '_workitems/edit/(\d+)') { $id = [int]$Matches[1] }
        elseif ($WorkItem -match '[?&]workitem=(\d+)') { $id = [int]$Matches[1] }
        elseif ($WorkItem -match '(?i)_apis/wit/workItems/(\d+)') { $id = [int]$Matches[1] }
        else { throw "無法從輸入解析工單編號：$WorkItem" }
        $u = [Uri]$WorkItem
        $seg = $u.AbsolutePath.Trim('/').Split('/')
        $origin = "$($u.Scheme)://$($u.Authority)"
        $collection = $seg[0]
        if ($seg.Count -gt 1 -and $seg[1] -ne '_apis') { $project = [Uri]::UnescapeDataString($seg[1]) }
    }

    return New-WorkItemTargetObject -Id $id -Origin $origin -Collection $collection -Project $project
}

function New-WorkItemTargetObject {
    param([int]$Id, [string]$Origin, [string]$Collection, [string]$Project)
    # [string] 參數會把 $null 變成空字串；統一還原成 $null，呼叫端才能用 -eq $null 判斷「沒有 project」
    $proj = $Project
    if ([string]::IsNullOrWhiteSpace($proj)) { $proj = $null }
    $projectApi = $null; $webUrl = $null
    if ($proj) {
        $projectApi = "$Origin/$Collection/$([Uri]::EscapeDataString($proj))/_apis"
        $webUrl = "$Origin/$Collection/$([Uri]::EscapeDataString($proj))/_workitems/edit/$Id"
    }
    return [pscustomobject]@{
        Id            = $Id
        Origin        = $Origin
        Collection    = $Collection
        Project       = $proj
        CollectionApi = "$Origin/$Collection/_apis"
        ProjectApi    = $projectApi
        WebUrl        = $webUrl
    }
}

# 5.1 沒有 -SkipCertificateCheck，用 ServicePointManager 的 policy 代替；回傳原 policy 供 finally 還原。
function Enable-DevOpsTrustAllCerts {
    if ($PSVersionTable.PSVersion.Major -ge 6) { return $null }
    if (-not ('TrustAllCertsPolicy' -as [type])) {
        Add-Type @"
using System.Net;using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
  public bool CheckValidationResult(ServicePoint s, X509Certificate c, WebRequest r, int p) { return true; }
}
"@
    }
    $orig = [System.Net.ServicePointManager]::CertificatePolicy
    [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
    return $orig
}

# --- API 呼叫 ---------------------------------------------------------------
# 所有 HTTP 都走這裡：套認證、UTF-8 body、把 401/403/404 翻成看得懂的訊息。
function Invoke-DevOpsApi {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Auth,
        [Parameter(Mandatory = $true)][string]$Uri,
        [string]$Method = 'Get',
        [string]$Body,
        [string]$ContentType = 'application/json',
        [switch]$SkipCertificateCheck
    )
    $p = @{ Uri = $Uri; Method = $Method; ErrorAction = 'Stop' }
    if ($Auth.Mode -eq 'Windows') { $p.UseDefaultCredentials = $true } else { $p.Headers = $Auth.Headers }
    if (-not [string]::IsNullOrEmpty($Body)) {
        $p.Body = [Text.Encoding]::UTF8.GetBytes($Body)
        $p.ContentType = "$ContentType; charset=utf-8"
    }
    if ($SkipCertificateCheck -and $PSVersionTable.PSVersion.Major -ge 6) { $p.SkipCertificateCheck = $true }
    try {
        return Invoke-RestMethod @p
    }
    catch {
        $status = 0
        try { $status = [int]$_.Exception.Response.StatusCode } catch { }
        $hint = switch ($status) {
            401 { "401 未授權：$($Auth.Source) 對這個 Azure DevOps 沒有權限（Windows 驗證＝目前登入帳號沒有專案權限；PAT＝過期或缺 Work Items Read & Write）" }
            403 { "403 禁止：帳號有登入但沒有這個動作的權限（改狀態／指派需要專案 Contributor）" }
            404 { "404 找不到：工單編號、organization／collection 或 project 有誤，或 API 路徑漏帶 project（留言 API 一定要帶 project）" }
            default { "HTTP $status：$($_.Exception.Message)" }
        }
        throw "$hint`n  URI：$Uri"
    }
}

# --- 讀取 -------------------------------------------------------------------
function Get-DevOpsWorkItem {
    param([hashtable]$Auth, [pscustomobject]$Target, [switch]$SkipCertificateCheck)
    $api = if ($Target.ProjectApi) { $Target.ProjectApi } else { $Target.CollectionApi }
    return Invoke-DevOpsApi -Auth $Auth -Uri "$api/wit/workitems/$($Target.Id)?`$expand=relations&api-version=6.0" -SkipCertificateCheck:$SkipCertificateCheck
}

# 輸入沒有 project（_apis 形式的網址）時，用工單本身的 System.TeamProject 補上。
function Resolve-WorkItemProject {
    param([pscustomobject]$Target, $WorkItem)
    if ($Target.Project) { return $Target }
    $proj = [string]$WorkItem.fields.'System.TeamProject'
    if ([string]::IsNullOrWhiteSpace($proj)) { throw "工單 #$($Target.Id) 讀不到 System.TeamProject，無法組留言 API 路徑" }
    return New-WorkItemTargetObject -Id $Target.Id -Origin $Target.Origin -Collection $Target.Collection -Project $proj
}

function Get-DevOpsParentId {
    param($WorkItem)
    foreach ($r in @($WorkItem.relations)) {
        if ($null -ne $r -and $r.rel -eq 'System.LinkTypes.Hierarchy-Reverse' -and ([string]$r.url) -match '(?i)_apis/wit/workItems/(\d+)$') { return [int]$Matches[1] }
    }
    return 0
}

# 往上走 Hierarchy-Reverse 直到沒有父工單或到 MaxDepth。Loader 是 { param($id) 回傳工單物件 }，
# 拆成參數是為了離線測試能用假資料驗證「走到頂」「防循環」「MaxDepth 截斷」。
function Get-DevOpsAncestors {
    param(
        [Parameter(Mandatory = $true)]$WorkItem,
        [Parameter(Mandatory = $true)][scriptblock]$Loader,
        [int]$MaxDepth = 10
    )
    $chain = @()
    $seen = New-Object 'System.Collections.Generic.HashSet[int]'
    [void]$seen.Add([int]$WorkItem.id)
    $cur = $WorkItem
    for ($i = 0; $i -lt $MaxDepth; $i++) {
        $parentId = Get-DevOpsParentId -WorkItem $cur
        if ($parentId -le 0) { break }
        if (-not $seen.Add($parentId)) { break }
        $cur = & $Loader $parentId
        if ($null -eq $cur) { break }
        $chain += $cur
    }
    return $chain
}

function Get-DevOpsWorkItemTypeStates {
    param([hashtable]$Auth, [pscustomobject]$Target, [string]$TypeName, [switch]$SkipCertificateCheck)
    if (-not $Target.ProjectApi) { throw '查工單型別狀態需要 project' }
    $r = Invoke-DevOpsApi -Auth $Auth -Uri "$($Target.ProjectApi)/wit/workitemtypes/$([Uri]::EscapeDataString($TypeName))/states?api-version=6.0" -SkipCertificateCheck:$SkipCertificateCheck
    return @($r.value | ForEach-Object { [pscustomobject]@{ Name = $_.name; Category = $_.category } })
}

function Test-DevOpsStateAllowed {
    param([string]$State, [object[]]$States)
    foreach ($s in @($States)) { if ($s.Name -eq $State) { return $true } }
    return $false
}

# ── 工單閘：判定函式在 _acceptance-gate.ps1（與上傳結案報告共用）；這裡只決定哪些狀態要過閘 ──
# 判定：qa/{Codex|Claude}驗收結果_[中綴_]R{n}[b].md 合併取最新一輪、qa/onsite-gate_[中綴_]R{n}[b].md 取最新一輪，
#       兩者檔內最後一個「總結：」行都要通過（Test-DevOpsSummaryPassed）；功能地圖合格；A 表每條對到功能、Pass 有證據。
function Test-DevOpsStateNeedsAcceptanceGate {
    param([string]$State, [string[]]$AcceptanceStates)
    return (Test-HD5StateNeedsAcceptanceGate -State $State -AcceptanceStates $AcceptanceStates)
}

function Get-DevOpsComments {
    param([hashtable]$Auth, [pscustomobject]$Target, [switch]$SkipCertificateCheck)
    if (-not $Target.ProjectApi) { throw '留言 API 一定要帶 project' }
    $r = Invoke-DevOpsApi -Auth $Auth -Uri "$($Target.ProjectApi)/wit/workItems/$($Target.Id)/comments?api-version=6.0-preview.3" -SkipCertificateCheck:$SkipCertificateCheck
    return @($r.comments)
}

# --- 寫入 -------------------------------------------------------------------
# 純文字 → HTML：先編碼（< > & 不會被當標籤），再把換行轉 <br/>。內容本身已是 HTML 就用 -Html 原樣送。
function ConvertTo-DevOpsCommentHtml {
    param([string]$Text, [switch]$Html)
    if ($null -eq $Text) { return '' }
    if ($Html) { return $Text }
    $escaped = [System.Net.WebUtility]::HtmlEncode($Text)
    return (($escaped -replace "`r`n", "`n") -replace "`n", "<br/>`n")
}

# 留言走 comments API（顯示在討論串，有留言 id）。
function Add-DevOpsComment {
    param([hashtable]$Auth, [pscustomobject]$Target, [string]$Html, [switch]$SkipCertificateCheck)
    if (-not $Target.ProjectApi) { throw '留言 API 一定要帶 project' }
    $body = @{ text = $Html } | ConvertTo-Json -Compress -Depth 3
    return Invoke-DevOpsApi -Auth $Auth -Uri "$($Target.ProjectApi)/wit/workItems/$($Target.Id)/comments?api-version=6.0-preview.3" -Method Post -Body $body -SkipCertificateCheck:$SkipCertificateCheck
}

# JSON Patch body。ConvertTo-Json 遇到單元素陣列會拆成物件，JSON Patch 端點只吃陣列，所以手動包 [ ]。
# -HistoryHtml：留言改走 System.History 欄位（-CommentVia history），跟指派／狀態在同一次 PATCH 寫入；
#   舊版 comments API 不能用（例：較舊的 Azure DevOps Server）或想讓留言跟狀態變更出現在同一筆歷程時用。
# -Rev：加 test /rev，工單在預覽後被別人改過就整筆失敗，不會蓋掉別人的變更。
function New-DevOpsPatchBody {
    param([string]$AssignTo, [string]$State, [string]$HistoryHtml, [int]$Rev = 0)
    $ops = @()
    if (-not [string]::IsNullOrWhiteSpace($AssignTo)) { $ops += @{ op = 'add'; path = '/fields/System.AssignedTo'; value = $AssignTo } }
    if (-not [string]::IsNullOrWhiteSpace($State)) { $ops += @{ op = 'add'; path = '/fields/System.State'; value = $State } }
    if (-not [string]::IsNullOrWhiteSpace($HistoryHtml)) { $ops += @{ op = 'add'; path = '/fields/System.History'; value = $HistoryHtml } }
    if ($ops.Count -eq 0) { return $null }
    if ($Rev -gt 0) { $ops = @(@{ op = 'test'; path = '/rev'; value = $Rev }) + $ops }
    return '[' + (($ops | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 3 }) -join ',') + ']'
}

function Update-DevOpsWorkItemFields {
    param([hashtable]$Auth, [pscustomobject]$Target, [string]$PatchBody, [switch]$SkipCertificateCheck)
    $api = if ($Target.ProjectApi) { $Target.ProjectApi } else { $Target.CollectionApi }
    return Invoke-DevOpsApi -Auth $Auth -Uri "$api/wit/workitems/$($Target.Id)?api-version=6.0" -Method Patch -Body $PatchBody -ContentType 'application/json-patch+json' -SkipCertificateCheck:$SkipCertificateCheck
}

# --- 人員 -------------------------------------------------------------------
# 用顯示名或帳號查 identity；回傳 DisplayName／Account／Mail。指派欄位給 Account（或信箱）最穩，同名時顯示名會錯人。
function Find-DevOpsIdentity {
    param([hashtable]$Auth, [pscustomobject]$Target, [string]$Query, [switch]$SkipCertificateCheck)
    $r = Invoke-DevOpsApi -Auth $Auth -Uri "$($Target.Origin)/$($Target.Collection)/_apis/identities?searchFilter=General&filterValue=$([Uri]::EscapeDataString($Query))&api-version=6.0" -SkipCertificateCheck:$SkipCertificateCheck
    $list = @()
    foreach ($v in @($r.value)) {
        $acct = $null; $mail = $null; $domain = $null
        if ($v.properties) {
            if ($v.properties.Account) { $acct = [string]$v.properties.Account.'$value' }
            if ($v.properties.Mail) { $mail = [string]$v.properties.Mail.'$value' }
            if ($v.properties.Domain) { $domain = [string]$v.properties.Domain.'$value' }
        }
        $login = $acct
        if ($acct -and $domain -and $acct -notmatch '\\' -and $acct -notmatch '@') { $login = "$domain\$acct" }
        $list += [pscustomobject]@{ DisplayName = [string]$v.providerDisplayName; Account = $login; Mail = $mail; Descriptor = [string]$v.descriptor }
    }
    return $list
}

function Get-DevOpsCurrentUser {
    param([hashtable]$Auth, [pscustomobject]$Target, [switch]$SkipCertificateCheck)
    $r = Invoke-DevOpsApi -Auth $Auth -Uri "$($Target.Origin)/$($Target.Collection)/_apis/connectionData?api-version=6.0-preview" -SkipCertificateCheck:$SkipCertificateCheck
    $u = $r.authenticatedUser
    $acct = $null
    if ($u.properties -and $u.properties.Account) { $acct = [string]$u.properties.Account.'$value' }
    return [pscustomobject]@{ DisplayName = [string]$u.providerDisplayName; Account = $acct; Id = [string]$u.id }
}

# --- 顯示 -------------------------------------------------------------------
function Format-DevOpsWorkItemLine {
    param($WorkItem)
    $f = $WorkItem.fields
    $who = ''
    if ($f.'System.AssignedTo') { $who = [string]$f.'System.AssignedTo'.displayName }
    if ([string]::IsNullOrWhiteSpace($who)) { $who = '（未指派）' }
    return "#$($WorkItem.id) [$($f.'System.WorkItemType')] $($f.'System.Title')｜狀態 $($f.'System.State')｜指派 $who"
}
