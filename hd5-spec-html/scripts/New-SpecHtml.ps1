<#
.SYNOPSIS
  由題目 JSON 產生「需求摘要＋Open Questions 互動表單」單檔 HTML（可離線開啟、按儲存下載 answer 版）。

.DESCRIPTION
  格式與行為依 hd5-spec-html/SKILL.md 第四、五節；本腳本只是把 PM 手寫 HTML 改成「寫 JSON、跑腳本」。
  JSON 結構見 _spec-html-lib.ps1 開頭註解（specId／title／source／summary／flow／rules／bodyHtmlFile／questions）。
  圖片：bodyHtmlFile 內的 <img src="相對路徑"> 會自動 base64 內嵌；找不到的圖會變成警示區塊並自動追加一題 Open Question。

.EXAMPLE
  & ".../New-SpecHtml.ps1" -QuestionsFile "spec/case-x/pm/spec_1432.questions.json" -OutFile "spec/case-x/pm/spec_1432.html"

.EXAMPLE
  # 不給 -OutFile 時輸出到 JSON 同目錄的 {specId}.html
  & ".../New-SpecHtml.ps1" -QuestionsFile ".\spec_1432.questions.json"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$QuestionsFile,
    [string]$OutFile,
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
. (Join-Path $PSScriptRoot '_spec-html-lib.ps1')

if (-not (Test-Path -LiteralPath $QuestionsFile)) { throw "找不到題目檔：$QuestionsFile" }
$QuestionsFile = (Resolve-Path -LiteralPath $QuestionsFile).Path
$json = [IO.File]::ReadAllText($QuestionsFile, [Text.Encoding]::UTF8)
try { $spec = $json | ConvertFrom-Json } catch { throw "題目檔不是合法 JSON：$($_.Exception.Message)" }
$baseDir = [IO.Path]::GetDirectoryName($QuestionsFile)
if (-not $OutFile) { $OutFile = Join-Path $baseDir ("$($spec.specId).html") }
if ((Test-Path -LiteralPath $OutFile) -and -not $Force) { throw "輸出檔已存在：$OutFile（要覆蓋加 -Force）" }

$r = New-SpecHtmlDocument -Spec $spec -BaseDir $baseDir
if (-not [IO.Path]::IsPathRooted($OutFile)) { $OutFile = Join-Path (Get-Location).Path $OutFile }
$dir = [IO.Path]::GetDirectoryName($OutFile)
if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
[IO.File]::WriteAllText($OutFile, $r.Html, (New-Object Text.UTF8Encoding($false)))
$size = (Get-Item -LiteralPath $OutFile).Length

Write-Host "✅ 已產生 $OutFile" -ForegroundColor Green
Write-Host "   題數 $($r.QuestionCount)｜大小 $([Math]::Round($size / 1KB, 1)) KB｜圖片全部 base64 內嵌"
if ($r.Missing.Count) { Write-Host "⚠ 缺圖 $($r.Missing.Count) 張（已標示並追加為 Open Question）：$($r.Missing -join '、')" -ForegroundColor Yellow }
if ($size -gt 10MB) { Write-Host '⚠ 檔案超過 10 MB，請在 PM 報告中提醒使用者（圖片過多）' -ForegroundColor Yellow }
Write-Host '下一步：用瀏覽器開啟確認 → 傳給填答者（人工傳送，或選配的 Publish-SpecHtml.ps1 上傳工單附件／Send-TeamsFile.ps1 用 Teams 傳）'
