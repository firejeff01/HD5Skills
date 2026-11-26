<#
.SYNOPSIS
  hd5-spec-html 工具鏈的離線測試（不連網、不開 Teams、不需 PAT）。

.DESCRIPTION
  執行：& ".../tests/spec-html.tests.ps1"
  涵蓋：四支腳本＋函式庫語法解析與 BOM、題目 JSON 檢查、HTML 產生（結構／編碼／缺圖處理／0 題定稿／複選）、
  answer 版解析（本產生器的 data-* 屬性版＋手寫範本的畫面文字版）、工單目標解析、Publish 的前置檢查、
  Send-TeamsFile 的參數檢查（不會碰 Teams）。
  改過任何一支之後必跑；最後一行要是 ALL PASSED。
#>
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
$scripts = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$script:fail = 0
function Check($name, $cond) { if ($cond) { Write-Host "  ok   $name" } else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:fail++ } }

Write-Host '--- parse / BOM check ---'
foreach ($f in '_spec-html-lib.ps1', 'New-SpecHtml.ps1', 'Read-SpecAnswer.ps1', 'Publish-SpecHtml.ps1', 'Send-TeamsFile.ps1') {
    $tokens = $null; $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $scripts $f), [ref]$tokens, [ref]$errors) | Out-Null
    Check "parse $f" ($errors.Count -eq 0)
    $b = [IO.File]::ReadAllBytes((Join-Path $scripts $f))
    Check "bom   $f" ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
}
. (Join-Path $scripts '_spec-html-lib.ps1')

Write-Host '--- Test-SpecQuestions ---'
$sample = [IO.File]::ReadAllText((Join-Path $scripts 'sample.questions.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
Check 'sample valid' ((Test-SpecQuestions -Spec $sample).Count -eq 0)
$bad = [pscustomobject]@{ specId = ''; title = 'x'; questions = @([pscustomobject]@{ id = 'q1'; title = 't'; options = @('only one') }, [pscustomobject]@{ id = 'q1'; title = ''; options = @('a', 'b') }) }
$e = Test-SpecQuestions -Spec $bad
Check 'missing specId' ($e -contains '缺 specId')
Check 'too few options' (($e | Where-Object { $_ -like '*選項少於 2*' }).Count -eq 1)
Check 'duplicate id' (($e | Where-Object { $_ -like '題號重複*' }).Count -eq 1)

Write-Host '--- New-SpecHtmlDocument ---'
$tmp = Join-Path $env:TEMP ("spechtml-" + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $tmp | Out-Null
$r = New-SpecHtmlDocument -Spec $sample -BaseDir $tmp -GeneratedAt '2026-09-04T10:00:00+08:00'
$h = $r.Html
Check 'doctype' ($h.StartsWith('<!DOCTYPE html>'))
Check 'data-spec-id' ($h.Contains('data-spec-id="spec_sample"'))
Check 'title encoded' ($h.Contains('<title>需求摘要：範例：銷售報表統計幣別（spec_sample）</title>'))
Check 'two questions' (([regex]::Matches($h, 'class="open-question"')).Count -eq 2)
Check 'q1 radio + other' ($h.Contains('<input type="radio" name="q1" value="A" />') -and $h.Contains('name="q1" value="OTHER"'))
Check 'q2 checkbox no other' ($h.Contains('<input type="checkbox" name="q2" value="C" />') -and -not $h.Contains('name="q2" value="OTHER"'))
Check 'summary paragraphs' (([regex]::Matches($h, '<p>')).Count -ge 2)
Check 'flow list' ($h.Contains('<li>使用者建立報表並選擇統計幣別</li>'))
Check 'rules table' ($h.Contains('<td>StatCurrencyId</td>'))
Check 'save js present' ($h.Contains('function saveAnswers()') -and $h.Contains("specId + '_answer'"))
Check 'no external resources' (-not ($h -match '<(script|link)[^>]+(src|href)="https?://'))
Check 'answeredBy input' ($h.Contains('id="answeredBy"'))

# 缺圖：bodyHtmlFile 引用不存在的圖 → 警示區塊＋自動追加一題
Set-Content (Join-Path $tmp 'body.html') '<p>圖：</p><img src="nope.png" alt="x"><img src="ok.png" alt="y">' -Encoding UTF8
[IO.File]::WriteAllBytes((Join-Path $tmp 'ok.png'), [byte[]](0x89, 0x50, 0x4E, 0x47, 0, 0, 0, 0))
$spec2 = [IO.File]::ReadAllText((Join-Path $scripts 'sample.questions.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
$spec2 | Add-Member -NotePropertyName bodyHtmlFile -NotePropertyValue 'body.html'
$r2 = New-SpecHtmlDocument -Spec $spec2 -BaseDir $tmp
Check 'missing image flagged' ($r2.Missing.Count -eq 1 -and $r2.Html.Contains('缺少圖檔：nope.png'))
Check 'existing image embedded' ($r2.Html.Contains('src="data:image/png;base64,iVBORw'))
Check 'missing image adds question' (([regex]::Matches($r2.Html, 'class="open-question"')).Count -eq 3)
Check 'no relative img left' (-not ($r2.Html -match '<img[^>]+src="(?!data:)'))

# 0 題＝定稿
$spec3 = [pscustomobject]@{ specId = 's3'; title = 't'; source = 'x'; questions = @() }
$r3 = New-SpecHtmlDocument -Spec $spec3 -BaseDir $tmp
Check 'zero questions -> final wording, no save bar' ($r3.Html.Contains('本份需求視為定稿') -and -not $r3.Html.Contains('class="save-bar"'))

Write-Host '--- Read-SpecAnswerHtml（本產生器 answer 版）---'
$ans = $h
$ans = $ans.Replace('<body data-spec-id="spec_sample"', '<body data-answered-at="2026-09-04T02:00:00.000Z" data-answered-by="王小明" data-spec-id="spec_sample"')
$ans = $ans -replace '<div class="open-question" data-qid="q1">', '<div class="open-question answered" data-qid="q1" data-answer="B" data-note="要能改">'
$ans = $ans -replace '(?s)(data-qid="q1" data-answer="B" data-note="要能改">.*?)<div class="options">.*?</div>\s*<textarea[^>]*></textarea>', '$1<div class="options"><p class="selected-option">✔ 選擇：B. 使用者在報表上自選一筆</p></div><p class="answer-note"><strong>補充：</strong>要能改</p>'
$ans = $ans -replace '<div class="open-question" data-qid="q2" data-multi="1">', '<div class="open-question unanswered" data-qid="q2" data-multi="1">'
$ans = $ans.Replace('<div class="answer-meta">', '<div class="answered-banner">✅ 王小明 已於 2026-09-04T02:00:00.000Z 填寫完成（共 1 / 2 題，1 題未作答）</div><div class="answer-meta">')
$p = Read-SpecAnswerHtml -Html $ans
Check 'specId' ($p.SpecId -eq 'spec_sample')
Check 'answeredBy/At' ($p.AnsweredBy -eq '王小明' -and $p.AnsweredAt -eq '2026-09-04T02:00:00.000Z')
Check 'two answers parsed' (@($p.Answers).Count -eq 2)
Check 'q1 answered B + note' ($p.Answers[0].Id -eq 'q1' -and $p.Answers[0].Answered -and $p.Answers[0].Answer -eq 'B' -and $p.Answers[0].Note -eq '要能改' -and $p.Answers[0].AnswerText -like 'B. 使用者*')
Check 'q2 unanswered' ($p.Answers[1].Id -eq 'q2' -and -not $p.Answers[1].Answered)
$md = ConvertTo-SpecAnswerMarkdown -Parsed $p
Check 'markdown table' ($md.Contains('| q1 |') -and $md.Contains('（未作答）') -and $md.Contains('作答：1 / 2 題'))

Write-Host '--- Read-SpecAnswerHtml（手寫範本 answer 版，無 data-* 屬性）---'
$legacy = @'
<body data-spec-id="spec_783"><section class="open-questions"><div class="answered-banner">✅ 已於 2026-08-01T01:02:03.000Z 填寫完成（共 1 / 1 題）</div>
<div class="open-question answered" data-qid="q1"><div class="q-title">Q1. 要不要匯出？</div><div class="options"><p class="selected-option">✔ 選擇：A. 要</p></div><p><strong>補充：</strong>下季<br/>再說</p></div>
</section></body>
'@
$lp = Read-SpecAnswerHtml -Html $legacy
Check 'legacy answeredAt from banner' ($lp.AnsweredAt -eq '2026-08-01T01:02:03.000Z')
Check 'legacy answer letter from label' ($lp.Answers[0].Answer -eq 'A' -and $lp.Answers[0].Note -eq "下季`n再說")

Write-Host '--- Resolve-SpecWorkItem ---'
$t = Resolve-SpecWorkItem -WorkItem 'https://devops.example.com/MyCollection/MyProject/_workitems/edit/1432'
Check 'url' ($t.Id -eq 1432 -and $t.ProjectApi -eq 'https://devops.example.com/MyCollection/MyProject/_apis')
$t2 = Resolve-SpecWorkItem -WorkItem '5' -ProjectUrl 'https://h/c/p/'
Check 'id + ProjectUrl' ($t2.Id -eq 5 -and $t2.Project -eq 'p')
$threw = $false; try { Resolve-SpecWorkItem -WorkItem 'https://h/c/_apis/wit/workItems/5' | Out-Null } catch { $threw = $true }
Check 'api url without project throws' $threw

Write-Host '--- tracker.url（.claude/workflow.json）---'
$pu = [Environment]::GetEnvironmentVariable('AZURE_DEVOPS_PROJECT_URL'); [Environment]::SetEnvironmentVariable('AZURE_DEVOPS_PROJECT_URL', $null)
$proj = Join-Path $tmp 'proj'; New-Item -ItemType Directory -Force (Join-Path $proj '.claude'), (Join-Path $proj 'sub\deeper') | Out-Null
Set-Content (Join-Path $proj '.claude\workflow.json') '{ "tracker": { "type": "azure-devops", "url": "https://devops.example.com/Coll/Proj" } }' -Encoding UTF8
Check 'tracker.url found from subfolder' ((Get-SpecTrackerUrl -Start (Join-Path $proj 'sub\deeper')) -eq 'https://devops.example.com/Coll/Proj')
$t3 = Resolve-SpecWorkItem -WorkItem '7' -ConfigStart (Join-Path $proj 'sub')
Check 'id + tracker.url' ($t3.Id -eq 7 -and $t3.Collection -eq 'Coll' -and $t3.Project -eq 'Proj')
$noTracker = Join-Path $tmp 'proj2'; New-Item -ItemType Directory -Force (Join-Path $noTracker '.claude') | Out-Null
Set-Content (Join-Path $noTracker '.claude\workflow.json') '{ "tracker": { "type": "none", "url": "" } }' -Encoding UTF8
Check 'empty tracker.url -> null' ($null -eq (Get-SpecTrackerUrl -Start $noTracker))
$threw = $false; $msg = ''; try { Resolve-SpecWorkItem -WorkItem '7' -ConfigStart $noTracker | Out-Null } catch { $threw = $true; $msg = $_.Exception.Message }
Check 'id without any url throws (mentions tracker.url)' ($threw -and $msg -match 'tracker\.url')

Write-Host '--- New-SpecAuth ---'
$sp = [Environment]::GetEnvironmentVariable('AZURE_DEVOPS_PAT'); $sw = [Environment]::GetEnvironmentVariable('AZURE_DEVOPS_PAT_WRITE')
[Environment]::SetEnvironmentVariable('AZURE_DEVOPS_PAT', $null); [Environment]::SetEnvironmentVariable('AZURE_DEVOPS_PAT_WRITE', $null)
Check 'default Windows' ((New-SpecAuth -ScriptRoot $tmp).Mode -eq 'Windows')
Check '-Pat wins' ((New-SpecAuth -Pat 'x' -ScriptRoot $tmp).Mode -eq 'PAT')
[Environment]::SetEnvironmentVariable('AZURE_DEVOPS_PAT', $sp); [Environment]::SetEnvironmentVariable('AZURE_DEVOPS_PAT_WRITE', $sw)

Write-Host '--- 腳本前置檢查（不連網）---'
$out = Join-Path $tmp 'gen.html'
& (Join-Path $scripts 'New-SpecHtml.ps1') -QuestionsFile (Join-Path $scripts 'sample.questions.json') -OutFile $out | Out-Null
Check 'New-SpecHtml writes file' ((Test-Path $out) -and ((Get-Item $out).Length -gt 5000))
$threw = $false; try { & (Join-Path $scripts 'New-SpecHtml.ps1') -QuestionsFile (Join-Path $scripts 'sample.questions.json') -OutFile $out | Out-Null } catch { $threw = $true }
Check 'New-SpecHtml refuses overwrite without -Force' $threw
Set-Content (Join-Path $tmp 'ans.html') $ans -Encoding UTF8
$mdOut = Join-Path $tmp 'ans.md'
& (Join-Path $scripts 'Read-SpecAnswer.ps1') -AnswerFile (Join-Path $tmp 'ans.html') -OutFile $mdOut | Out-Null
Check 'Read-SpecAnswer writes md' ((Test-Path $mdOut) -and ((Get-Content $mdOut -Raw) -match '\| q1 \|'))
Set-Content (Join-Path $tmp 'ext.html') '<body data-spec-id="x"><link href="https://cdn/x.css"><div class="open-question"></div></body>' -Encoding UTF8
$threw = $false; $msg = ''; try { & (Join-Path $scripts 'Publish-SpecHtml.ps1') -WorkItem 'https://devops.example.com/MyCollection/MyProject/_workitems/edit/1' -File (Join-Path $tmp 'ext.html') -WhatIfOnly } catch { $threw = $true; $msg = $_.Exception.Message }
Check 'Publish rejects external resources before network' ($threw -and $msg -match '外部資源')
Push-Location $noTracker   # 目前資料夾往上沒有 tracker.url，才能驗「只給號碼就停」
$threw = $false; $msg = ''; try { & (Join-Path $scripts 'Publish-SpecHtml.ps1') -WorkItem '1' -File $out -WhatIfOnly } catch { $threw = $true; $msg = $_.Exception.Message }
Pop-Location
Check 'Publish id without ProjectUrl stops' ($threw -and $msg -match 'ProjectUrl')
[Environment]::SetEnvironmentVariable('AZURE_DEVOPS_PROJECT_URL', $pu)
if ($env:OS -eq 'Windows_NT') {
    $threw = $false; $msg = ''; try { & (Join-Path $scripts 'Send-TeamsFile.ps1') -To 'a@b' -Peer 'x' -Action Send } catch { $threw = $true; $msg = $_.Exception.Message }
    Check 'Send-TeamsFile requires message' ($threw -and $msg -match 'Message')
    $threw = $false; $msg = ''; try { & (Join-Path $scripts 'Send-TeamsFile.ps1') -To 'a@b' -Peer 'x' -Message 'hi' -File (Join-Path $tmp 'no-such.html') } catch { $threw = $true; $msg = $_.Exception.Message }
    Check 'Send-TeamsFile checks attachment exists' ($threw -and $msg -match '找不到附件')
}
else {
    $threw = $false; $msg = ''; try { & (Join-Path $scripts 'Send-TeamsFile.ps1') -To 'a@b' -Peer 'x' -Message 'hi' } catch { $threw = $true; $msg = $_.Exception.Message }
    Check 'Send-TeamsFile refuses non-Windows' ($threw -and $msg -match 'Windows')
    Write-Host '  skip Send-TeamsFile 參數檢查（非 Windows，選配工具不可用）' -ForegroundColor Yellow
}
Remove-Item -Recurse -Force $tmp

Write-Host ''
if ($script:fail) { Write-Host "FAILED: $($script:fail)" -ForegroundColor Red; exit 1 } else { Write-Host 'ALL PASSED' -ForegroundColor Green }
