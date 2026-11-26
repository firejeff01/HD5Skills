<#
.SYNOPSIS
  讀回填者存下來的 spec_{號碼}_answer*.html，輸出成 Markdown 回覆表（給 PM／SA／PG 讀，不必開瀏覽器）。

.DESCRIPTION
  優先讀 Save 寫進去的 data-answer／data-note 屬性；手寫範本產生的 answer 版沒有這些屬性時退回解析畫面文字。
  -OutFile 省略時只印到畫面；給了就寫成 .md（建議放 case_spec_content/spec_{號碼}_answer.md，讓下游角色直接讀）。

.EXAMPLE
  & ".../Read-SpecAnswer.ps1" -AnswerFile "case_spec_content/spec_1432_answer.html" -OutFile "case_spec_content/spec_1432_answer.md"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$AnswerFile,
    [string]$OutFile,
    [switch]$Json
)
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
. (Join-Path $PSScriptRoot '_spec-html-lib.ps1')

if (-not (Test-Path -LiteralPath $AnswerFile)) { throw "找不到 answer 檔：$AnswerFile" }
$html = [IO.File]::ReadAllText($AnswerFile, [Text.Encoding]::UTF8)
$p = Read-SpecAnswerHtml -Html $html
if (@($p.Answers).Count -eq 0) { throw '檔案裡沒有任何 .open-question 區塊——確認這是 spec HTML 的 answer 版，不是別的檔' }
if (-not $p.AnsweredAt) { Write-Host '⚠ 沒有填寫完成的紀錄（可能是尚未按「儲存答覆」的原始檔）' -ForegroundColor Yellow }

if ($Json) { $p | ConvertTo-Json -Depth 5; return }
$md = ConvertTo-SpecAnswerMarkdown -Parsed $p
if ($OutFile) {
    [IO.File]::WriteAllText($OutFile, $md, (New-Object Text.UTF8Encoding($false)))
    Write-Host "✅ 已寫入 $OutFile（$(@($p.Answers | Where-Object { $_.Answered }).Count) / $(@($p.Answers).Count) 題已作答）" -ForegroundColor Green
}
else { $md }
