<#
.SYNOPSIS
  讀工單建案腳本群（fetch-workitem／fetch-related-attachments／upload-case-report）的共用函式：
  憑證、工單網址解析、工單讀取、HTML -> Markdown、附件清單／下載、引用工單偵測。

.DESCRIPTION
  由 fetch-workitem.ps1 / fetch-related-attachments.ps1 / upload-case-report.ps1 以 dot-source 載入：

      . (Join-Path $PSScriptRoot '_devops-lib.ps1')

  本檔不可直接執行。🔴 本檔【不得】內嵌任何 PAT，也不得把 PAT 印出來（只印來源）。
  相容 Windows PowerShell 5.1 與 PowerShell 7；必須存成 UTF-8 with BOM。
#>

. (Join-Path $PSScriptRoot '_tracker-config.ps1')
. (Join-Path $PSScriptRoot '_auth.ps1')
. (Join-Path $PSScriptRoot '_acceptance-gate.ps1')
. (Join-Path $PSScriptRoot '_comments.ps1')

# 自架站台憑證不是公開 CA 且本機沒信任時才用（各腳本的 -SkipCertificateCheck）。
# Windows PowerShell 5.1：改 ServicePointManager 的 policy，回傳原 policy，呼叫端在 finally 還原。
# PowerShell 7：policy 對 Invoke-RestMethod 無效，改由 Get-DevOpsWebParams 帶 -SkipCertificateCheck。
$script:DevOpsSkipCert = $false
function Enable-DevOpsTrustAllCerts {
    $script:DevOpsSkipCert = $true
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

function Restore-DevOpsCertPolicy {
    param($Original)
    $script:DevOpsSkipCert = $false
    if ($null -ne $Original) { [System.Net.ServicePointManager]::CertificatePolicy = $Original }
}

# 組 Invoke-RestMethod／Invoke-WebRequest 參數：套憑證設定，並把 Headers 欄的「認證內容」（New-DevOpsAuthContext 回傳）
# 換成 PAT 標頭或 UseDefaultCredentials（Windows 整合驗證）。
function Get-DevOpsWebParams {
    param([hashtable]$Params)
    $a = $Params.Headers
    if ($a -is [hashtable] -and $a.ContainsKey('Mode')) {
        $Params.Remove('Headers')
        if ($a.Mode -eq 'Windows') { $Params.UseDefaultCredentials = $true } else { $Params.Headers = $a.Headers }
    }
    if ($script:DevOpsSkipCert -and $PSVersionTable.PSVersion.Major -ge 6) { $Params.SkipCertificateCheck = $true }
    return $Params
}

# 只給工單號碼時，用專案網址（-ProjectUrl → AZURE_DEVOPS_PROJECT_URL → workflow.json 的 tracker.url）組成工單網址。
function Resolve-DevOpsWorkItemInput {
    param([Parameter(Mandatory = $true)][string]$WorkItem, [string]$ProjectUrl, $Context)
    $WorkItem = $WorkItem.Trim()
    if ($WorkItem -notmatch '^\d+$') { return $WorkItem }
    $pu = Resolve-HD5ProjectUrl -ProjectUrl $ProjectUrl -Context $Context
    if ([string]::IsNullOrWhiteSpace($pu)) { throw (Get-HD5MissingProjectUrlMessage) }
    $u = [Uri]$pu.TrimEnd('/')
    $seg = $u.AbsolutePath.Trim('/').Split('/')
    if ($seg.Count -lt 2 -or [string]::IsNullOrWhiteSpace($seg[1])) { throw "專案網址必須含 organization（或 collection）與 project 兩段：$pu" }
    return "$($pu.TrimEnd('/'))/_workitems/edit/$WorkItem"
}

# --- 網址解析 ---------------------------------------------------------------
# 支援三種格式：
#   https://host/{collection}/{project}/_workitems/edit/163
#   https://host/{collection}/{project}/_backlogs/...?workitem=163
#   https://host/{collection}/_apis/wit/workItems/163            （relations 內的 url，沒有 project）
function Resolve-DevOpsWorkItemUrl {
    param([Parameter(Mandatory = $true)][string]$Url)
    $uri = [Uri]$Url
    if ($Url -match '_workitems/edit/(\d+)') { $id = [int]$Matches[1] }
    elseif ($Url -match '[?&]workitem=(\d+)') { $id = [int]$Matches[1] }
    elseif ($Url -match '(?i)_apis/wit/workItems/(\d+)') { $id = [int]$Matches[1] }
    else { throw "無法從網址解析工單編號：$Url" }

    $seg = $uri.AbsolutePath.Trim('/').Split('/')
    $collection = $seg[0]
    $project = $null
    if ($seg.Count -gt 1 -and $seg[1] -ne '_apis') { $project = [Uri]::UnescapeDataString($seg[1]) }
    $origin = "$($uri.Scheme)://$($uri.Authority)"

    $projectApi = $null
    if ($project) { $projectApi = "$origin/$collection/$([Uri]::EscapeDataString($project))/_apis" }
    return [pscustomobject]@{
        Id            = $id
        Collection    = $collection
        Project       = $project
        Origin        = $origin
        CollectionApi = "$origin/$collection/_apis"
        ProjectApi    = $projectApi
    }
}

function Get-DevOpsWorkItemWebUrl {
    param([string]$Origin, [string]$Collection, [string]$Project, [int]$Id)
    return "$Origin/$Collection/$([Uri]::EscapeDataString($Project))/_workitems/edit/$Id"
}

# --- 讀取工單 ---------------------------------------------------------------
# $expand=all：fields + relations 一次回來（附件、工單連結、commit 連結都在 relations）。
# ApiRoot 給 CollectionApi 時可跨專案讀取（工單編號是 collection 內唯一，不是 project 內唯一）。
function Get-DevOpsWorkItem {
    param(
        [Parameter(Mandatory = $true)][string]$ApiRoot,
        [Parameter(Mandatory = $true)][int]$Id,
        [Parameter(Mandatory = $true)][hashtable]$Headers
    )
    $p = Get-DevOpsWebParams @{ Uri = "$ApiRoot/wit/workitems/$Id`?`$expand=all&api-version=5.0"; Headers = $Headers }
    return Invoke-RestMethod @p
}

# 工單歷程（updates API，分頁讀完）：上傳結案報告時判斷需求方是否已驗收完成、數退回次數
function Get-DevOpsWorkItemUpdates {
    param(
        [Parameter(Mandatory = $true)][string]$ApiRoot,
        [Parameter(Mandatory = $true)][int]$Id,
        [Parameter(Mandatory = $true)][hashtable]$Headers
    )
    return @(Get-HD5AllUpdates -Fetcher { param($top, $skip) $p = Get-DevOpsWebParams @{ Uri = "$ApiRoot/wit/workItems/$Id/updates?`$top=$top&`$skip=$skip&api-version=5.0"; Headers = $Headers }; Invoke-RestMethod @p })
}

# 留言（comments API，需要 project 段）；回傳原始留言物件陣列（id／text／createdBy／createdDate）
function Get-DevOpsWorkItemComments {
    param(
        [Parameter(Mandatory = $true)][string]$ApiRoot,
        [Parameter(Mandatory = $true)][int]$Id,
        [Parameter(Mandatory = $true)][hashtable]$Headers
    )
    $p = Get-DevOpsWebParams @{ Uri = "$ApiRoot/wit/workItems/$Id/comments?api-version=6.0-preview.3"; Headers = $Headers }
    $r = Invoke-RestMethod @p
    return @($r.comments)
}

# 描述 HTML；Bug 型別的內容在 Microsoft.VSTS.TCM.ReproSteps。永遠回傳字串（可能是空字串）。
function Get-DevOpsDescriptionHtml {
    param([Parameter(Mandatory = $true)]$WorkItem)
    $html = $WorkItem.fields.'System.Description'
    if ([string]::IsNullOrWhiteSpace($html)) { $html = $WorkItem.fields.'Microsoft.VSTS.TCM.ReproSteps' }
    if ($null -eq $html) { $html = '' }
    return [string]$html
}

# --- HTML -> Markdown（輕量轉換，足以應付 DevOps 編輯器產出的 div/span/br） ---
# 超連結會轉成 [文字](網址) 保留——描述裡用 # 選單插入的工單提及就是靠這行留下完整網址。
function ConvertFrom-DevOpsHtml {
    param([string]$Html)
    if ($null -eq $Html) { return '' }
    $md = $Html
    $md = [regex]::Replace($md, '(?i)<br\s*/?>', "`n")
    # <div>/<p> 各是一個區塊 → 段落（兩個換行）；否則相鄰兩個 div 在 Markdown 會被軟換行黏成一行。
    # <li>/<tr> 只換一行，條列項目之間的多餘空行由下方後處理收攏。
    $md = [regex]::Replace($md, '(?i)</(div|p)>', "`n`n")
    $md = [regex]::Replace($md, '(?i)</(li|tr)>', "`n")
    $md = [regex]::Replace($md, '(?i)<li[^>]*>', '- ')
    $md = [regex]::Replace($md, '(?i)<img[^>]*src="([^"]+)"[^>]*>', '![]($1)')
    $md = [regex]::Replace($md, '(?i)<a[^>]*href="([^"]+)"[^>]*>(.*?)</a>', '[$2]($1)')
    $md = [regex]::Replace($md, '(?i)<(b|strong)>(.*?)</\1>', '**$2**')
    $md = [regex]::Replace($md, '<[^>]+>', '')
    $md = $md -replace '&nbsp;', ' ' -replace '&lt;', '<' -replace '&gt;', '>' -replace '&amp;', '&' -replace '&quot;', '"'

    # 後處理（實測回饋）：DevOps 編輯器產出的固定病灶，省掉大部分人工校對
    #   (a) 「**1. 來源：**」這種粗體偽標題 → 「## 1. 來源」；同一行接在後面的內容（「**1. 來源：**#256 發現」）
    #       另起一行成為段落，「**分級：**小修」這種沒有編號的粗體不動
    #   (b) </div> 換行造成的行尾空白 → 清掉（Markdown 裡是潛在 hard-break）
    #   (c) 條列項目之間夾的空行（<li><div>…</div></li>）→ 收攏
    #   (d) PM 開單模板的「☑ 條件」「☐ 條件」→ 「- [ ] 條件」checkbox
    #   (e) 「  - 項目」這種 1~3 格縮排的條列 → 拉到最左（DevOps 標籤間的空白造成，與巢狀無關）
    $listStart = '^\s*(- |[☑☐□✓✔])'
    $lines = @($md -split "`n" | ForEach-Object { $_.TrimEnd() })
    $out = New-Object 'System.Collections.Generic.List[string]'
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line -match '^\s*(?:-\s*)?[☑☐□✓✔]\s*(.+)$') { $line = "- [ ] $($Matches[1])" }
        elseif ($line -match '^ {1,3}(- .*)$') { $line = $Matches[1] }
        if ($line -match '^\s*\*\*\s*(\d+)[\.、]\s*([^*]+?)\s*[：:]?\s*\*\*\s*(.*)$') {
            $rest = $Matches[3].Trim()
            if ($out.Count -gt 0 -and $out[$out.Count - 1] -ne '') { $out.Add('') }
            $out.Add("## $($Matches[1]). $($Matches[2])")
            if ($rest -ne '') { $out.Add(''); $out.Add($rest) }
            continue
        }
        if ($line -eq '' -and $out.Count -gt 0 -and $out[$out.Count - 1] -match '^- ') {
            $j = $i + 1
            while ($j -lt $lines.Count -and $lines[$j] -eq '') { $j++ }
            if ($j -lt $lines.Count -and $lines[$j] -match $listStart) { continue }
        }
        $out.Add($line)
    }
    $md = $out -join "`n"
    $md = [regex]::Replace($md, '\n{3,}', "`n`n")
    return $md.Trim()
}

# --- 附件 -------------------------------------------------------------------
function Get-DevOpsAttachments {
    param([Parameter(Mandatory = $true)]$WorkItem)
    $list = @()
    foreach ($r in @($WorkItem.relations)) {
        if ($null -eq $r -or $r.rel -ne 'AttachedFile') { continue }
        $created = $null
        if ($r.attributes -and $r.attributes.resourceCreatedDate) { $created = $r.attributes.resourceCreatedDate }
        elseif ($r.attributes -and $r.attributes.authorizedDate) { $created = $r.attributes.authorizedDate }
        $list += [pscustomobject]@{
            Name    = [string]$r.attributes.name
            Url     = [string]$r.url
            Created = $created
            Comment = [string]$r.attributes.comment
        }
    }
    # ⚠️ 呼叫端一律用 @(Get-DevOpsAttachments …) 接：只有一個附件時 PowerShell 會把單元素陣列拆成
    # 單一物件，.Count 變空值、整個下載區塊被跳過（實測只有一個附件的工單被漏抓）。
    # 這裡【不要】改成 return ,$list——@(指令) 收到單一陣列物件會再包一層變巢狀，兩張引用會黏成一個。
    return $list
}

function Get-DevOpsSafeFileName {
    param([string]$Name, [string]$Fallback = 'attachment')
    if ([string]::IsNullOrWhiteSpace($Name)) { $Name = $Fallback }
    foreach ($c in [IO.Path]::GetInvalidFileNameChars()) { $Name = $Name.Replace($c, '_') }
    return $Name
}

# 同名不覆蓋，改 name(2).ext
function Get-DevOpsUniquePath {
    param([string]$Dir, [string]$Name)
    if (-not (Test-Path (Join-Path $Dir $Name))) { return (Join-Path $Dir $Name) }
    $base = [IO.Path]::GetFileNameWithoutExtension($Name)
    $ext = [IO.Path]::GetExtension($Name)
    $i = 2
    while (Test-Path (Join-Path $Dir "$base($i)$ext")) { $i++ }
    return (Join-Path $Dir "$base($i)$ext")
}

function Save-DevOpsAttachment {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Dest,
        [Parameter(Mandatory = $true)][hashtable]$Headers
    )
    $u = $Url
    if ($u -notmatch '\?') { $u = $u + '?api-version=5.0' }
    $p = Get-DevOpsWebParams @{ Uri = $u; Headers = $Headers; OutFile = $Dest; UseBasicParsing = $true }
    Invoke-WebRequest @p
}

# 多份同名附件（例如結案報告重傳）取上傳時間最新的一份；沒有時間資訊就取清單最後一個。
function Select-DevOpsLatestAttachment {
    param([object[]]$Attachments)
    if ($null -eq $Attachments -or $Attachments.Count -eq 0) { return $null }
    $dated = @($Attachments | Where-Object { $_.Created })
    if ($dated.Count -eq $Attachments.Count) {
        return ($Attachments | Sort-Object { [datetime]$_.Created } -Descending | Select-Object -First 1)
    }
    return $Attachments[-1]
}

# --- 引用工單偵測 -----------------------------------------------------------
function ConvertTo-DevOpsLinkTypeName {
    param([string]$Rel)
    switch ($Rel) {
        'System.LinkTypes.Hierarchy-Reverse'  { return '父工單' }
        'System.LinkTypes.Hierarchy-Forward'  { return '子工單' }
        'System.LinkTypes.Related'            { return '關聯 Related' }
        'System.LinkTypes.Dependency-Forward' { return '後續 Successor' }
        'System.LinkTypes.Dependency-Reverse' { return '前置 Predecessor' }
        'System.LinkTypes.Duplicate-Forward'  { return '重複 Duplicate' }
        'System.LinkTypes.Duplicate-Reverse'  { return '被重複 Duplicate Of' }
        default                               { return $Rel }
    }
}

# 從工單 relations 與描述 HTML 找出「引用到的其他工單」，只做深度一層。回傳依可信度排序、去重、排除自身：
#   Tier relation：relations 內的正式工單連結（父／子／Related／前後置）——編號與專案都明確
#   Tier link    ：描述內帶完整網址的提及（# 選單插入的 <a href>，或直接貼的工單網址）——編號明確
#   Tier text    ：描述內純文字 #NNN——⚠️ 未驗證，可能是裁定編號、別專案的同號工單，建案者必須比對標題與上下文
function Get-DevOpsWorkItemRefs {
    param(
        [Parameter(Mandatory = $true)]$WorkItem,
        [string]$Html,
        [Parameter(Mandatory = $true)][int]$SelfId
    )
    if ($null -eq $Html) { $Html = '' }
    $seen = New-Object 'System.Collections.Generic.HashSet[int]'
    [void]$seen.Add($SelfId)
    $refs = @()

    foreach ($r in @($WorkItem.relations)) {
        if ($null -eq $r) { continue }
        if ($r.rel -in @('AttachedFile', 'ArtifactLink', 'Hyperlink')) { continue }
        if ([string]$r.url -match '(?i)_apis/wit/workItems/(\d+)$') {
            $rid = [int]$Matches[1]
            if ($seen.Add($rid)) { $refs += [pscustomobject]@{ Id = $rid; Tier = 'relation'; Via = (ConvertTo-DevOpsLinkTypeName $r.rel) } }
        }
    }

    foreach ($m in [regex]::Matches($Html, '(?i)_workitems/edit/(\d+)|[?&]workitem=(\d+)')) {
        $rid = if ($m.Groups[1].Success) { [int]$m.Groups[1].Value } else { [int]$m.Groups[2].Value }
        if ($seen.Add($rid)) { $refs += [pscustomobject]@{ Id = $rid; Tier = 'link'; Via = '描述超連結' } }
    }

    # 純文字：先把 <a>…</a> 整段拿掉（超連結已在上一層處理），再剝標籤，才掃 #NNN。
    # 前置排除 \w / & ——避免 &#123; 這種 HTML 實體與網址片段誤中。
    $text = [regex]::Replace($Html, '(?is)<a\b[^>]*>.*?</a>', ' ')
    $text = [regex]::Replace($text, '<[^>]+>', ' ')
    foreach ($m in [regex]::Matches($text, '(?<![\w/&#])#(\d{1,6})(?!\d)')) {
        $rid = [int]$m.Groups[1].Value
        if ($seen.Add($rid)) { $refs += [pscustomobject]@{ Id = $rid; Tier = 'text'; Via = '純文字 #編號' } }
    }

    # 呼叫端一律 @(Get-DevOpsWorkItemRefs …) 接；同 Get-DevOpsAttachments 的說明，不要 return ,$refs
    return $refs
}

function ConvertTo-DevOpsRefTierLabel {
    param([string]$Tier, [string]$Via)
    switch ($Tier) {
        'relation' { return "關聯連結（$Via）" }
        'link'     { return '描述超連結' }
        'text'     { return '⚠️ 純文字 #編號（待驗證）' }
        default    { return $Tier }
    }
}
