<#
.SYNOPSIS
  按需下載「引用工單」的附件到案子的 case_spec_content/related/{工單號}/attachments/。

.DESCRIPTION
  fetch-workitem.ps1 展開引用工單時只列附件清單、不下載（結案報告 ai-case-report.md 除外），
  避免引用鏈把半個專案史抓回來。建案者判斷某份附件承重（例如上一案的測試報告、需求 HTML）時，用本腳本指定下載。
  不建立 spec_*.md、不動案子其他內容；目標資料夾不存在會自動建立。

  工單：完整網址或純號碼（專案網址取法同 fetch-workitem.ps1）。案子資料夾：-SpecRoot，預設由 .claude/workflow.json 推。
  認證：取法同 fetch-workitem.ps1（共用 _auth.ps1；沒 PAT 時自架 Server 用 Windows 整合驗證）。本腳本只讀不寫工單。

.EXAMPLE
  # 只抓一份
  & "<hd5-tools>/workitem/fetch-related-attachments.ps1" -WorkItemUrl "https://dev.azure.com/<org>/<project>/_workitems/edit/163" -CaseName my-case -Name "spec_163.html"

.EXAMPLE
  # 萬用字元、多個
  & "<hd5-tools>/workitem/fetch-related-attachments.ps1" -WorkItemUrl 163 -CaseName my-case -Name "*.feature","event-storming-*"

.EXAMPLE
  # 全抓
  & "<hd5-tools>/workitem/fetch-related-attachments.ps1" -WorkItemUrl "<工單網址>" -CaseName my-case
#>
param(
    [Parameter(Mandatory = $true)][string]$WorkItemUrl,
    [Parameter(Mandatory = $true)][string]$CaseName,
    [string[]]$Name,
    [string]$SpecRoot,
    [string]$ProjectUrl,
    [string]$Pat,
    [string]$PatFile,
    [string]$ConfigStart,
    # 憑證：預設不驗（為了自架 Azure DevOps Server 的自簽憑證，同原版）；連雲端想驗證就加 -StrictCertificate。-SkipCertificateCheck 為相容舊參數（本來就預設略過）
    [switch]$SkipCertificateCheck,
    [switch]$StrictCertificate
)

$ErrorActionPreference = 'Stop'
$SkipCertificateCheck = -not $StrictCertificate   # 預設不驗憑證；-StrictCertificate 才驗
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
. (Join-Path $PSScriptRoot '_devops-lib.ps1')

$ctx = Get-HD5TrackerContext -ConfigStart $ConfigStart -ScriptRoot $PSScriptRoot
Assert-HD5AzureDevOpsTracker -Context $ctx
if ([string]::IsNullOrWhiteSpace($SpecRoot)) { $SpecRoot = Get-HD5DefaultSpecRoot -Context $ctx }
if ([string]::IsNullOrWhiteSpace($SpecRoot)) { throw '找不到案子資料夾：請給 -SpecRoot <AI_Service/spec>，或在專案的 .claude/workflow.json 設 paths.aiService' }
$WorkItemUrl = Resolve-DevOpsWorkItemInput -WorkItem $WorkItemUrl -ProjectUrl $ProjectUrl -Context $ctx
$ref = Resolve-DevOpsWorkItemUrl -Url $WorkItemUrl

$auth = New-DevOpsAuthContext -Pat $Pat -PatFile $PatFile -ScriptRoot $PSScriptRoot -TargetUrl "$($ref.Origin)/$($ref.Collection)"
$headers = $auth   # 認證內容（PAT 標頭或 Windows 整合驗證），由 Get-DevOpsWebParams 套用
Enable-HD5Tls12
$origCertPolicy = $null
if ($SkipCertificateCheck) { $origCertPolicy = Enable-DevOpsTrustAllCerts }
try {

$id = $ref.Id
Write-Host "讀取引用工單 #$id 的附件清單 ..."
$wi = Get-DevOpsWorkItem -ApiRoot $ref.CollectionApi -Id $id -Headers $headers
Write-Host "  #$id $($wi.fields.'System.Title')  [$($wi.fields.'System.State')]"

$atts = @(Get-DevOpsAttachments -WorkItem $wi)
if ($atts.Count -eq 0) { Write-Host "  此工單沒有附件"; return }

if ($Name -and $Name.Count -gt 0) {
    $atts = @($atts | Where-Object { $a = $_; @($Name | Where-Object { $a.Name -like $_ }).Count -gt 0 })
    if ($atts.Count -eq 0) {
        Write-Warning "沒有附件符合 -Name（$($Name -join ', ')）。此工單的附件："
        (Get-DevOpsAttachments -WorkItem $wi) | ForEach-Object { Write-Host "    - $($_.Name)" }
        return
    }
}

$dest = Join-Path (Join-Path (Join-Path (Join-Path $SpecRoot $CaseName) 'case_spec_content') 'related') "$id"
$dest = Join-Path $dest 'attachments'
New-Item -ItemType Directory -Force $dest | Out-Null

$ok = 0
foreach ($a in $atts) {
    $fname = Get-DevOpsSafeFileName -Name $a.Name -Fallback 'attachment'
    $path = Get-DevOpsUniquePath -Dir $dest -Name $fname
    try {
        Save-DevOpsAttachment -Url $a.Url -Dest $path -Headers $headers
        $ok++
        Write-Host "  附件 -> related\$id\attachments\$([IO.Path]::GetFileName($path))"
    }
    catch {
        Write-Warning "  附件下載失敗：$fname -> $($a.Url)"
    }
}

Write-Host ""
Write-Host "完成：$ok / $($atts.Count) 個附件 -> $dest"
Write-Host "⚠️ 這些是引用工單的產物，屬背景參考；不要搬進 pm/ sa/ pg/ qa/，也不要當成本 case 的需求。"

}
finally {
    Restore-DevOpsCertPolicy $origCertPolicy
}
