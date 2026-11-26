<#
.SYNOPSIS
  （選配工具：需要 Azure DevOps；沒有工單系統就人工傳送）
  把 spec HTML（或回填後的 answer HTML）上傳成 Azure DevOps 工單附件，並可順帶留一則說明留言。

.DESCRIPTION
  認證預設 Windows 整合驗證（目前登入帳號），不需 PAT；有 PAT 的人照舊（-Pat／AZURE_DEVOPS_PAT_WRITE／pat.write.local.txt）。
  只新增附件與留言，不改工單任何欄位（改狀態／指派用專案自己的工單工具）。
  只給工單號碼時，專案網址依序取：-ProjectUrl → 環境變數 AZURE_DEVOPS_PROJECT_URL → 從目前資料夾往上找 .claude/workflow.json 的 tracker.url。
  DevOps 附件只能新增不能刪除：重傳會多一份同名附件，引用端取最新；不要為了覆蓋改檔名。
  🔴 先跑 -WhatIfOnly 看目標工單標題對不對；必須用 & 在目前 session 執行並關閉沙箱。

.EXAMPLE
  & ".../Publish-SpecHtml.ps1" -WorkItem "https://devops.example.com/MyCollection/MyProject/_workitems/edit/1432" -File "spec/case-x/pm/spec_1432.html" -WhatIfOnly

.EXAMPLE
  & ".../Publish-SpecHtml.ps1" -WorkItem 1432 -ProjectUrl "<專案網址>" -File ".\spec_1432.html" -Comment "需求摘要與待確認問題已附上，請下載開啟填寫後回傳。"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$WorkItem,
    [Parameter(Mandatory = $true)][string]$File,
    [string]$ProjectUrl,
    [string]$Comment,
    [string]$AttachmentNote,
    [string]$Pat,
    [switch]$WhatIfOnly
)
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
. (Join-Path $PSScriptRoot '_spec-html-lib.ps1')

if (-not (Test-Path -LiteralPath $File)) { throw "找不到檔案：$File" }
$File = (Resolve-Path -LiteralPath $File).Path
$name = [IO.Path]::GetFileName($File)
if ($name -notmatch '\.html?$') { throw "只上傳 spec／answer HTML（.html），目前是：$name" }
$html = [IO.File]::ReadAllText($File, [Text.Encoding]::UTF8)
$problems = @()
if ($html -notmatch 'data-spec-id=') { $problems += '不是 spec HTML（缺 data-spec-id）' }
if ($html -match '<(script|link)[^>]+(src|href)="https?://') { $problems += '含外部資源（違反單檔規則）' }
if ($html -match '<img[^>]+src="(?!data:)') { $problems += '有圖片不是 base64 內嵌' }
$isAnswer = ($html -match 'data-answered-at="' -or $html -match '<div class="answered-banner"')
if ($problems.Count) { throw ("檔案檢查未通過，未上傳：`n  - " + ($problems -join "`n  - ")) }

$auth = New-SpecAuth -Pat $Pat -ScriptRoot $PSScriptRoot
$t = Resolve-SpecWorkItem -WorkItem $WorkItem -ProjectUrl $ProjectUrl -ConfigStart (Get-Location).Path
$wi = Get-SpecWorkItem -Auth $auth -Target $t
$same = @($wi.relations | Where-Object { $_.rel -eq 'AttachedFile' -and $_.attributes.name -ieq $name })
if (-not $AttachmentNote) { $AttachmentNote = "$(if ($isAnswer) { 'Open Questions 回覆' } else { '需求摘要＋Open Questions' }) v$($same.Count + 1)（$(Get-Date -Format 'yyyy-MM-dd HH:mm')）" }

Write-Host "=== 上傳 $(if ($isAnswer) { 'answer' } else { 'spec' }) HTML 到工單附件 ===" -ForegroundColor Cyan
Write-Host "目標工單：#$($t.Id)　$($wi.fields.'System.Title')｜狀態 $($wi.fields.'System.State')｜專案 $($wi.fields.'System.TeamProject')"
Write-Host "檔案：$File（$([Math]::Round((Get-Item -LiteralPath $File).Length / 1KB, 1)) KB）；既有同名附件 $($same.Count) 份 → 本次為第 $($same.Count + 1) 版"
Write-Host "附件註記：$AttachmentNote"
if ($Comment) { Write-Host "留言：$Comment" }
Write-Host "認證：$($auth.Source)"
if ($WhatIfOnly) { Write-Host ''; Write-Host '（-WhatIfOnly：未上傳、未留言，工單沒有任何變動）' -ForegroundColor Yellow; return }

$url = Add-SpecAttachment -Auth $auth -Target $t -Path $File -Comment $AttachmentNote
Write-Host "✅ 附件已掛上：$name" -ForegroundColor Green
if ($Comment) {
    $c = Add-SpecComment -Auth $auth -Target $t -Html ("<div>" + [System.Net.WebUtility]::HtmlEncode($Comment) + "</div><div>附件：" + [System.Net.WebUtility]::HtmlEncode($name) + "</div>")
    Write-Host "✅ 留言 id=$($c.id)" -ForegroundColor Green
}
Write-Host "連結：$($t.WebUrl)"
