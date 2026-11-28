<#
.SYNOPSIS
  HD5Skills install.ps1＋整條導入鏈的測試：暫存 git repo 實際安裝 → 檔案、hook、重跑不重複 → 裝好的 main-edit-guard 會擋非 .NET 程式
  → 模擬 hd5-onboard 產物後 check-onboard 合格。執行：pwsh -File HD5Skills/tests/install.tests.ps1（或在既有 pwsh 裡 & 它）；最後一行要是 ALL PASSED。
  install.ps1 在本程序內執行（不開子程序：本機 COMODO 會隔離子程序寫的檔）。
#>
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
# install.ps1 需要 PowerShell 7（README「需求」；用到 [Environment]::ProcessPath、ProcessStartInfo.ArgumentList），本測試同樣只在 pwsh 跑
if ($PSVersionTable.PSEdition -eq 'Desktop') {
    Write-Host 'FAILED: install.ps1 與本測試需要 PowerShell 7（pwsh），Windows PowerShell 5.1 不支援。請改用：pwsh -File tests/install.tests.ps1' -ForegroundColor Red
    exit 1
}
$kit = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$exe = [Environment]::ProcessPath
$script:fail = 0
function Check($name, $cond) { if ($cond) { Write-Host "  ok   $name" } else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:fail++ } }
function New-Repo { $r = Join-Path ([IO.Path]::GetTempPath()) ('hd5inst_' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $r | Out-Null
    foreach ($a in @(@('init', '-q', '-b', 'dev'), @('config', 'user.email', 't@t'), @('config', 'user.name', 't'), @('config', 'core.autocrlf', 'false'))) { & git -C $r @a 2>&1 | Out-Null }
    [IO.File]::WriteAllText((Join-Path $r 'README.md'), 'x'); & git -C $r add -A 2>&1 | Out-Null; & git -C $r commit -q -m base 2>&1 | Out-Null; return $r }
# 同程序執行 install.ps1（11-23 使用者拍板）：本機 COMODO 會隔離子程序 pwsh 寫的檔，父程序看不到 ⇒ 子程序版整段假失敗。
# install 的 exit 只結束它自己的腳本範圍（不會帶走測試程序）；throw 由 catch 接住；$ErrorActionPreference／目前目錄用 finally 還原
function Run([string]$file, [string[]]$a) {
    $h = @{}
    for ($i = 0; $i -lt $a.Count; $i++) {
        $k = $a[$i].TrimStart('-')
        if ($i + 1 -lt $a.Count -and -not $a[$i + 1].StartsWith('-')) { $h[$k] = $a[$i + 1]; $i++ } else { $h[$k] = [switch]$true }
    }
    $eap = $ErrorActionPreference; $loc = Get-Location; $code = 0; $o = ''
    try {
        $global:LASTEXITCODE = 0
        $o = & $file @h *>&1 | Out-String
        $code = if ($global:LASTEXITCODE) { $global:LASTEXITCODE } else { 0 }   # install 用 exit 1 結束時會設 LASTEXITCODE
    } catch { $o = "$o`n例外：$($_.Exception.Message)"; $code = 1 }
    finally { $ErrorActionPreference = $eap; Set-Location -LiteralPath $loc.Path }
    [pscustomobject]@{ Code = $code; Out = [string]$o }
}
function J($p) { Get-Content -Raw -LiteralPath $p -Encoding UTF8 | ConvertFrom-Json }

Write-Host '--- 安裝到子資料夾 ---'
$r = New-Repo; $p = Join-Path $r 'app'
$x = Run (Join-Path $kit 'install.ps1') @('-RepoRoot', $r, '-ProjectDir', 'app')
Check '安裝成功（含裝完的 hook／質詢閘測試）' ($x.Code -eq 0 -and $x.Out -match '安裝完成')
if (-not ($x.Code -eq 0 -and $x.Out -match '安裝完成')) { Write-Host "    （安裝輸出最後 15 行，exit=$($x.Code)）"; ($x.Out.Trim() -split "`n" | Select-Object -Last 15) | ForEach-Object { Write-Host "    | $_" } }
Check 'skills：Claude 與 Codex 各一份 hd5-workflow、hd5-onboard' (@('.claude/skills/hd5-workflow/SKILL.md', '.agents/skills/hd5-workflow/SKILL.md', '.claude/skills/hd5-onboard/scripts/scan-repo.mjs', '.agents/skills/hd5-onboard/SKILL.md' | Where-Object { Test-Path (Join-Path $p $_) }).Count -eq 4)
Check '工具只有一份在 AI_Service/hd5-tools（skills 裡的 hd5-workflow 不帶 tools）' ((Test-Path (Join-Path $p 'AI_Service/hd5-tools/validate-grill-gate.ps1')) -and -not (Test-Path (Join-Path $p '.claude/skills/hd5-workflow/tools')))
$s = J (Join-Path $p '.claude/settings.json')
Check 'settings.json 兩支 hook，指到 AI_Service/hd5-tools/hooks' (@($s.hooks.PreToolUse).Count -eq 2 -and (($s.hooks.PreToolUse.hooks.command) -join ' ') -match 'AI_Service/hd5-tools/hooks/main-edit-guard\.ps1')
Check 'workflow.json 有 paths.tools' ((J (Join-Path $p '.claude/workflow.json')).paths.tools -eq 'AI_Service/hd5-tools')
Check '沒有產生 AGENTS.md／CLAUDE.md（那是 hd5-onboard 的工作）' (-not (Test-Path (Join-Path $p 'AGENTS.md')) -and -not (Test-Path (Join-Path $p 'CLAUDE.md')))
Check '預設（沒選工單系統）不裝工單工具' (-not (Test-Path (Join-Path $p 'AI_Service/hd5-tools/workitem')) -and -not (Test-Path (Join-Path $p '.claude/skills/hd5-workitem')))

Write-Host '--- 重跑 ---'
$x = Run (Join-Path $kit 'install.ps1') @('-RepoRoot', $r, '-ProjectDir', 'app', '-SkipTests')
Check '重跑：hook 不重複、已存在的檔跳過' ($x.Code -eq 0 -and @((J (Join-Path $p '.claude/settings.json')).hooks.PreToolUse).Count -eq 2 -and $x.Out -match '跳過')

Write-Host '--- 既有 settings.json／workflow.json：沒變動不重寫、加 tracker 只動那段（11-23 導入 IMOCore）---'
$r4 = New-Repo; New-Item -ItemType Directory -Force (Join-Path $r4 '.claude') | Out-Null
# settings.json：已有兩個同 matcher 的 hook，但格式是單行（跟 ConvertTo-Json 的輸出不同）＋專案自己的設定
$hkObj = (Get-Content -Raw (Join-Path $kit 'hd5-onboard/templates/settings.hooks.json') -Encoding UTF8).Replace('{{PREFIX}}', '') | ConvertFrom-Json
$hkObj | Add-Member -NotePropertyName permissions -NotePropertyValue ([pscustomobject]@{ allow = @('Bash(git status)') })
$stP = Join-Path $r4 '.claude/settings.json'; [IO.File]::WriteAllText($stP, ($hkObj | ConvertTo-Json -Depth 20 -Compress) + "`r`n", [Text.UTF8Encoding]::new($false))
$stBefore = [IO.File]::ReadAllBytes($stP)
# workflow.json：單行陣列、CRLF、沒有 tracker
$wfP = Join-Path $r4 '.claude/workflow.json'
$wfText = "{`r`n  `"stack`": `"dotnet`",`r`n  `"paths`": { `"aiService`": `"AI_Service`", `"tools`": `"AI_Service/hd5-tools`" },`r`n  `"branches`": { `"develop`": `"dev`", `"workBranchPrefix`": `"project_`" },`r`n  `"implementers`": [ { `"agent`": `"backend-expert`", `"gateRole`": `"backend`", `"extensions`": [`".cs`", `".cshtml`"] } ],`r`n  `"productCode`": { `"extensions`": [`".cs`", `".cshtml`"] }`r`n}`r`n"
[IO.File]::WriteAllText($wfP, $wfText, [Text.UTF8Encoding]::new($false))
$x = Run (Join-Path $kit 'install.ps1') @('-RepoRoot', $r4, '-SkipTests')
Check '已有同 matcher 的 hook ⇒ settings.json 位元組不變（不重寫）' ($x.Code -eq 0 -and [Convert]::ToBase64String([IO.File]::ReadAllBytes($stP)) -eq [Convert]::ToBase64String($stBefore) -and $x.Out -match '新增 hook 0 筆')
Check '沒選工單系統 ⇒ workflow.json 位元組不變' ([IO.File]::ReadAllText($wfP) -ceq $wfText)
$x = Run (Join-Path $kit 'install.ps1') @('-RepoRoot', $r4, '-Tracker', 'azure-devops', '-SkipTests')
$wfAfter = [IO.File]::ReadAllText($wfP); $oldL = $wfText -split "`r`n"; $newL = $wfAfter -split "`r`n"
$extra = @($newL | Where-Object { $oldL -notcontains $_ })
Check '-Tracker azure-devops ⇒ workflow.json 只多 tracker 一行（單行陣列不展開、CRLF 保留）' ($x.Code -eq 0 -and $newL.Count -eq $oldL.Count + 1 -and (J $wfP).tracker.type -eq 'azure-devops' -and $wfAfter.Contains('"extensions": [".cs", ".cshtml"] }') -and $extra.Count -eq 2 -and @($extra | Where-Object { $_ -match '"tracker"' }).Count -eq 1 -and $wfAfter -notmatch '(?<!\r)\n')
Check '-Tracker azure-devops ⇒ settings.json 仍位元組不變' ([Convert]::ToBase64String([IO.File]::ReadAllBytes($stP)) -eq [Convert]::ToBase64String($stBefore))
$wf2 = [IO.File]::ReadAllText($wfP)
$x = Run (Join-Path $kit 'install.ps1') @('-RepoRoot', $r4, '-Tracker', 'azure-devops', '-SkipTests')
Check 'tracker.type 已是 azure-devops 再跑 ⇒ workflow.json 位元組不變' ($x.Code -eq 0 -and [IO.File]::ReadAllText($wfP) -ceq $wf2)
# 已有 tracker 物件（type none、有 url）⇒ 只換 type 的值
$wfText2 = $wfText.Replace("  `"stack`": `"dotnet`",", "  `"stack`": `"dotnet`",`r`n  `"tracker`": { `"type`": `"none`", `"url`": `"https://dev.example/o/p`" },")
[IO.File]::WriteAllText($wfP, $wfText2, [Text.UTF8Encoding]::new($false))
$x = Run (Join-Path $kit 'install.ps1') @('-RepoRoot', $r4, '-Tracker', 'azure-devops', '-SkipTests')
Check '已有 tracker 物件 ⇒ 只換 type 的值（url 與其他位元組不變）' ($x.Code -eq 0 -and [IO.File]::ReadAllText($wfP) -ceq $wfText2.Replace('"type": "none"', '"type": "azure-devops"'))
Remove-Item -LiteralPath $r4 -Recurse -Force -ErrorAction SilentlyContinue

Write-Host '--- 裝好的 main-edit-guard 在新專案會擋（.py）---'
& git -C $r checkout -q -b project_x 2>&1 | Out-Null
New-Item -ItemType Directory -Force (Join-Path $p 'AI_Service/spec/bug-1/case_spec_content'), (Join-Path $p 'src') | Out-Null
[IO.File]::WriteAllText((Join-Path $p 'AI_Service/spec/bug-1/case_spec_content/spec_001.md'), '路線：小問題，高風險：否，理由：測試', [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $p 'src/app.py'), 'x = 1')
function Guard([string]$file, [string]$agentId) {
    $pl = @{ tool_name = 'Edit'; cwd = $p; tool_input = @{ file_path = $file } }; if ($agentId) { $pl.agent_id = $agentId }
    $psi = [Diagnostics.ProcessStartInfo]::new($exe); foreach ($y in @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $p 'AI_Service/hd5-tools/hooks/main-edit-guard.ps1'))) { $psi.ArgumentList.Add($y) }
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false; $psi.StandardInputEncoding = [Text.UTF8Encoding]::new($false); $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    $pr = [Diagnostics.Process]::Start($psi); $pr.StandardInput.Write(($pl | ConvertTo-Json -Compress)); $pr.StandardInput.Close(); $e = $pr.StandardError.ReadToEnd(); $pr.WaitForExit()
    [pscustomobject]@{ Code = $pr.ExitCode; Err = $e }
}
$g = Guard (Join-Path $p 'src/app.py'); Check '主對話改 app/src/app.py ⇒ 擋（建議 backend-expert）' ($g.Code -eq 2 -and $g.Err -match 'backend-expert')
$g = Guard (Join-Path $p 'src/app.py') 'a1'; Check '子代理 ⇒ 放行' ($g.Code -eq 0)
$g = Guard (Join-Path $p 'AI_Service/spec/bug-1/sa/bug-analysis.md'); Check '文件 ⇒ 放行' ($g.Code -eq 0)

Write-Host '--- 模擬 hd5-onboard 產物 → check-onboard ---'
$chk = Join-Path $kit 'hd5-onboard/scripts/check-onboard.mjs'
$o = & node $chk --project $p 2>&1 | Out-String
Check '還沒 onboard ⇒ check-onboard 擋（缺 AGENTS.md）' ($LASTEXITCODE -ne 0 -and $o -match 'AGENTS\.md')
$tplA = Get-Content -Raw (Join-Path $kit 'hd5-onboard/templates/AGENTS.md.tpl') -Encoding UTF8
$filled = [regex]::Replace($tplA, '\{\{[^}]+\}\}', '（測試內容）')
[IO.File]::WriteAllText((Join-Path $p 'AGENTS.md'), $filled, [Text.UTF8Encoding]::new($false))
$tplC = (Get-Content -Raw (Join-Path $kit 'hd5-onboard/templates/CLAUDE.md.tpl') -Encoding UTF8) -replace '\{\{[^}]+\}\}', '（測試）'
[IO.File]::WriteAllText((Join-Path $p 'CLAUDE.md'), $tplC, [Text.UTF8Encoding]::new($false))
foreach ($n in 'backend-expert', 'frontend-expert') {
    $f = Join-Path $p ".claude/agents/$n.md"; $t = Get-Content -Raw $f -Encoding UTF8
    $t = [regex]::Replace($t, '（初始化腳本會在這裡放技術架構的重點規則[^）]*）', 'Python 3.12＋FastAPI；測試用 pytest；資料存取用 SQLAlchemy。')
    [IO.File]::WriteAllText($f, $t, [Text.UTF8Encoding]::new($false))
}
$o = & node $chk --project $p 2>&1 | Out-String
Check '分支命名還沒問（範本 workBranchPrefix 空）⇒ check-onboard 擋' ($LASTEXITCODE -ne 0 -and $o -match 'branches\.workBranchPrefix')
# 模擬導入一開始問的分支命名（開發分支 main、工作分支 feature/）
$wfP = Join-Path $p '.claude/workflow.json'; $wfo = [IO.File]::ReadAllText($wfP) | ConvertFrom-Json
$wfo.branches.develop = 'main'; $wfo.branches.workBranchPrefix = 'feature/'
[IO.File]::WriteAllText($wfP, ($wfo | ConvertTo-Json -Depth 20) + "`n", [Text.UTF8Encoding]::new($false))
$o = & node $chk --project $p 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) { Write-Host $o }
Check '產物齊 ⇒ check-onboard 合格' ($LASTEXITCODE -eq 0 -and $o -match '合格')

Write-Host '--- -Update：已導入的專案只更新套件的檔（11-23 使用者拍板）---'
function SameBytes($a, $b) { (Test-Path -LiteralPath $a) -and (Test-Path -LiteralPath $b) -and [Linq.Enumerable]::SequenceEqual([byte[]][IO.File]::ReadAllBytes($a), [byte[]][IO.File]::ReadAllBytes($b)) }
$keep = @('AGENTS.md', 'CLAUDE.md', '.claude/agents/backend-expert.md', '.claude/agents/pm-expert.md', '.claude/workflow.json', '.claude/settings.json')
$snap = @{}; foreach ($k in $keep) { $snap[$k] = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $p $k))) }
# 專案端被改過的套件檔、PAT 檔、套件已不含的檔
$mod = @{ '.claude/skills/hd5-onboard/scripts/scan-repo.mjs' = 'hd5-onboard/scripts/scan-repo.mjs'; '.agents/skills/hd5-grill/SKILL.md' = 'hd5-grill/SKILL.md'; 'AI_Service/hd5-tools/validate-grill-gate.ps1' = 'hd5-workflow/tools/validate-grill-gate.ps1'; '.claude/skills/hd5-workflow/SKILL.md' = 'hd5-workflow/SKILL.md' }
foreach ($k in $mod.Keys) { [IO.File]::AppendAllText((Join-Path $p $k), "`n// 專案端被改過`n") }
[IO.File]::WriteAllText((Join-Path $p 'AI_Service/hd5-tools/pat.local.txt'), 'secret-pat')
[IO.File]::WriteAllText((Join-Path $p 'AI_Service/hd5-tools/old-tool.ps1'), '# 舊版套件留下的')
New-Item -ItemType Directory -Force (Join-Path $p '.claude/skills/hd5-obsolete') | Out-Null; [IO.File]::WriteAllText((Join-Path $p '.claude/skills/hd5-obsolete/SKILL.md'), 'x')
$x = Run (Join-Path $kit 'install.ps1') @('-RepoRoot', $r, '-ProjectDir', 'app', '-Update', '-SkipTests')
if ($x.Code -ne 0) { Write-Host "    （-Update 輸出最後 15 行，exit=$($x.Code)）"; ($x.Out.Trim() -split "`n" | Select-Object -Last 15) | ForEach-Object { Write-Host "    | $_" } }
Check '-Update 成功、被改過的 hd5 skill／工具檔覆蓋回套件版本（摘要：更新 4 個檔）' ($x.Code -eq 0 -and $x.Out -match '更新完成' -and $x.Out -match '更新 4 個檔' -and @($mod.Keys | Where-Object { SameBytes (Join-Path $p $_) (Join-Path $kit $mod[$_]) }).Count -eq 4)
Check '-Update 不動 workflow.json、settings.json、AGENTS.md、CLAUDE.md；代理只填了技術架構重點 ⇒ 也不動（位元組不變）' (@($keep | Where-Object { [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $p $_))) -eq $snap[$_] }).Count -eq $keep.Count)
Check '-Update 保留 PAT 檔、不列它' ([IO.File]::ReadAllText((Join-Path $p 'AI_Service/hd5-tools/pat.local.txt')) -eq 'secret-pat' -and $x.Out -notmatch 'pat\.local\.txt')
Check '-Update 列出套件已不含的檔與 skill、不刪' ($x.Out -match '套件已不含' -and $x.Out -match 'AI_Service/hd5-tools/old-tool\.ps1' -and $x.Out -match '\.claude/skills/hd5-obsolete/' -and (Test-Path (Join-Path $p 'AI_Service/hd5-tools/old-tool.ps1')) -and (Test-Path (Join-Path $p '.claude/skills/hd5-obsolete/SKILL.md')))
Check 'tracker 不是 azure-devops ⇒ -Update 不裝工單工具' (-not (Test-Path (Join-Path $p 'AI_Service/hd5-tools/workitem')) -and -not (Test-Path (Join-Path $p '.claude/skills/hd5-workitem')))
$x = Run (Join-Path $kit 'install.ps1') @('-RepoRoot', $r, '-ProjectDir', 'app', '-Update', '-SkipTests')
Check '再跑 -Update ⇒ 更新 0 個檔' ($x.Code -eq 0 -and $x.Out -match '更新 0 個檔')
# 11-24：git autocrlf 把 checkout 的檔轉成 CRLF ⇒ 只差行尾不算更新、也不覆蓋（IMOCore 實測 53 支只有 3 支真的有變）
$crlfFile = Join-Path $p '.claude/skills/hd5-workflow/SKILL.md'
$crlfText = [IO.File]::ReadAllText($crlfFile).Replace("`r`n", "`n").Replace("`n", "`r`n")
[IO.File]::WriteAllText($crlfFile, $crlfText, [Text.UTF8Encoding]::new($false))
$x = Run (Join-Path $kit 'install.ps1') @('-RepoRoot', $r, '-ProjectDir', 'app', '-Update', '-SkipTests')
Check '檔案只差行尾（CRLF）⇒ -Update 更新 0 個檔、保留 CRLF' ($x.Code -eq 0 -and $x.Out -match '更新 0 個檔' -and [IO.File]::ReadAllText($crlfFile).Contains("`r`n"))
# 11-24：hook 改用 pwsh -Command；新裝的 settings.json 不能再有 -File，舊專案 -Update 要提醒（不改設定）
$stFile = Join-Path $p '.claude/settings.json'; $stNow = [IO.File]::ReadAllText($stFile)
Check '新裝的 settings.json hook 用 -Command、不用 -File' ($stNow -match '-Command' -and $stNow -notmatch '\s-File\s')
$stOld = [regex]::Replace($stNow, '-Command \\"[^"]*?& ''\./\$p''[^"]*?\\"', '-File \"$p\"')
[IO.File]::WriteAllText($stFile, $stOld, [Text.UTF8Encoding]::new($false))
$x = Run (Join-Path $kit 'install.ps1') @('-RepoRoot', $r, '-ProjectDir', 'app', '-Update', '-SkipTests')
Check '舊專案 settings.json 還是 -File ⇒ -Update 警告兩支 hook、不改 settings.json' ($stOld -ne $stNow -and $x.Code -eq 0 -and ([regex]::Matches($x.Out, '舊寫法 pwsh -File')).Count -ge 2 -and [IO.File]::ReadAllText($stFile) -eq $stOld)
# 11-24：找不到 hook 腳本時要 stderr 警告（不再靜默 exit 0）；舊專案 -Update 要提醒（不改設定）
Check '新裝的 settings.json：找不到腳本時 stderr 警告＋additionalContext' (([regex]::Matches($stNow, '>&2')).Count -ge 2 -and $stNow -match 'additionalContext')
$stSilent = [regex]::Replace($stNow, ' echo \\"⚠ HD5 hook[^>]*>&2; echo ''[^'']*''; exit 0', ' exit 0')
[IO.File]::WriteAllText($stFile, $stSilent, [Text.UTF8Encoding]::new($false))
$x = Run (Join-Path $kit 'install.ps1') @('-RepoRoot', $r, '-ProjectDir', 'app', '-Update', '-SkipTests')
Check '舊專案 settings.json 找不到腳本會靜默放行 ⇒ -Update 警告兩支 hook、不改 settings.json' ($stSilent -ne $stNow -and $x.Code -eq 0 -and ([regex]::Matches($x.Out, '靜默放行')).Count -ge 2 -and [IO.File]::ReadAllText($stFile) -eq $stSilent)
[IO.File]::WriteAllText($stFile, $stNow, [Text.UTF8Encoding]::new($false))
$x = Run (Join-Path $kit 'install.ps1') @('-RepoRoot', $r, '-ProjectDir', 'app', '-Update', '-SkipTests')
Check '新寫法 settings.json ⇒ -Update 不出 hook 寫法警告' ($x.Code -eq 0 -and $x.Out -notmatch '靜默放行' -and $x.Out -notmatch '舊寫法 pwsh -File')
$x = Run (Join-Path $kit 'install.ps1') @('-RepoRoot', $r, '-ProjectDir', 'app', '-Update', '-Force', '-SkipTests')
Check '-Update＋-Force ⇒ 報錯' ($x.Code -ne 0 -and $x.Out -match '-Update 與 -Force 不能同時用')
$r5 = New-Repo
$x = Run (Join-Path $kit 'install.ps1') @('-RepoRoot', $r5, '-Update', '-SkipTests')
Check '沒導入過 ⇒ -Update 報錯、請改用一般安裝' ($x.Code -ne 0 -and $x.Out -match '還沒導入 HD5Skills' -and -not (Test-Path (Join-Path $r5 '.claude')))
Remove-Item -LiteralPath $r5 -Recurse -Force -ErrorAction SilentlyContinue

Write-Host '--- -Update：代理檔三方比對（11-28 使用者拍板）---'
$ab = Join-Path $p 'AI_Service/onboard/agent-base'
Check '一般安裝把新建代理用的範本存成基準' (SameBytes (Join-Path $ab 'templates/backend-expert.template.md') (Join-Path $kit 'hd5-onboard/templates/agents/backend-expert.template.md') -and (Test-Path (Join-Path $ab 'templates/sa-expert.md')))
. (Join-Path $kit 'hd5-onboard/scripts/_agent-merge-lib.ps1')
function Set-Sec([string]$text, [string]$key, $newText) {   # $newText＝$null ⇒ 拿掉這一節
    $out = foreach ($s in (Split-AgentSections $text)) { if ($s.Key -ne $key) { $s.Text } elseif ($null -ne $newText) { $newText } }
    (@($out | Where-Object { $_ }) -join "`n`n") + "`n" }
function Get-Sec([string]$text, [string]$key) { @((Split-AgentSections $text) | Where-Object Key -eq $key)[0].Text }
# 模擬「用舊版套件導入」的 backend-expert：舊版範本沒有「程式設計原則」、熔斷是舊寫法；專案自己改過「回報」，新版範本也改了「回報」
$beF = Join-Path $p '.claude/agents/backend-expert.md'; $beTplF = Join-Path $kit 'hd5-onboard/templates/agents/backend-expert.template.md'
$oldTpl = [IO.File]::ReadAllText($beTplF); $oldTpl = Set-Sec $oldTpl '程式設計原則' $null; $oldTpl = Set-Sec $oldTpl '熔斷' "## 熔斷`n`n舊的熔斷寫法。"; $oldTpl = Set-Sec $oldTpl '回報（照這個格式）' "## 回報（照這個格式）`n`n舊的回報格式。"
Remove-Item -LiteralPath (Join-Path $ab 'agents/backend-expert.md') -ErrorAction SilentlyContinue
[IO.File]::WriteAllText((Join-Path $ab 'templates/backend-expert.template.md'), $oldTpl, [Text.UTF8Encoding]::new($false))
$cur = [IO.File]::ReadAllText($beF); $cur = Set-Sec $cur '程式設計原則' $null; $cur = Set-Sec $cur '熔斷' "## 熔斷`n`n舊的熔斷寫法。"; $cur = Set-Sec $cur '回報（照這個格式）' "## 回報（照這個格式）`n`n專案自己的回報格式。"
[IO.File]::WriteAllText($beF, $cur, [Text.UTF8Encoding]::new($false))
$x = Run (Join-Path $kit 'install.ps1') @('-RepoRoot', $r, '-ProjectDir', 'app', '-Update', '-SkipTests')
$be = [IO.File]::ReadAllText($beF); $rep = Join-Path $p 'AI_Service/onboard/agent-update.md'
if ($x.Code -ne 0) { Write-Host "    （輸出最後 15 行）"; ($x.Out.Trim() -split "`n" | Select-Object -Last 15) | ForEach-Object { Write-Host "    | $_" } }
Check '新範本多的節自動補上（接在「做法」後面）' ($x.Code -eq 0 -and ((@((Split-AgentSections $be) | ForEach-Object Key)) -join '|') -match '\|做法\|程式設計原則\|不做\|' -and $x.Out -match '新增 ## 程式設計原則')
Check '專案沒改過、範本改了 ⇒ 自動換成新版' ((Get-AgentNorm (Get-Sec $be '熔斷')) -ceq (Get-AgentNorm (Get-Sec ([IO.File]::ReadAllText($beTplF)) '熔斷')) -and $be -notmatch '舊的熔斷寫法')
Check '兩邊都改 ⇒ 不動專案、列進 agent-update.md（附 -AcceptAgents 指令）' ($be -match '專案自己的回報格式' -and $x.Out -match '待合併衝突 1 節' -and (Test-Path $rep) -and [IO.File]::ReadAllText($rep) -match '## 回報（照這個格式）：專案與範本都改過' -and [IO.File]::ReadAllText($rep) -match '-AcceptAgents')
Check '「本專案技術架構重點」不動' ($be -match 'Python 3\.12＋FastAPI')
Check '代理的新基準寫在 agent-base/agents/' ((Test-Path (Join-Path $ab 'agents/backend-expert.md')) -and [IO.File]::ReadAllText((Join-Path $ab 'agents/backend-expert.md')) -match '舊的回報格式')
$beBytes = [IO.File]::ReadAllBytes($beF)
$x = Run (Join-Path $kit 'install.ps1') @('-RepoRoot', $r, '-ProjectDir', 'app', '-Update', '-SkipTests')
Check '再跑 -Update ⇒ 代理檔不變、衝突照樣列' ($x.Code -eq 0 -and [Linq.Enumerable]::SequenceEqual([byte[]]$beBytes, [byte[]][IO.File]::ReadAllBytes($beF)) -and $x.Out -match '待合併衝突 1 節')
$x = Run (Join-Path $kit 'install.ps1') @('-RepoRoot', $r, '-ProjectDir', 'app', '-Update', '-AcceptAgents', 'backend-expert', '-SkipTests')
Check '-AcceptAgents ⇒ 代理檔不動、衝突清空、報告改成沒有衝突' ($x.Code -eq 0 -and [Linq.Enumerable]::SequenceEqual([byte[]]$beBytes, [byte[]][IO.File]::ReadAllBytes($beF)) -and $x.Out -match '待合併衝突 0 節' -and [IO.File]::ReadAllText($rep) -match '沒有待合併的衝突')
$x = Run (Join-Path $kit 'install.ps1') @('-RepoRoot', $r, '-ProjectDir', 'app', '-Update', '-SkipTests')
Check '接受後再跑 ⇒ 沒有衝突、專案的回報保留' ($x.Code -eq 0 -and $x.Out -match '待合併衝突 0 節' -and [IO.File]::ReadAllText($beF) -match '專案自己的回報格式')
# 沒有基準的舊專案（本功能上線前導入）：frontend-expert 刪掉基準、少一節、改過一節、CRLF
$feF = Join-Path $p '.claude/agents/frontend-expert.md'
Remove-Item -LiteralPath (Join-Path $ab 'agents/frontend-expert.md'), (Join-Path $ab 'templates/frontend-expert.template.md') -ErrorAction SilentlyContinue
$cur = [IO.File]::ReadAllText($feF); $cur = Set-Sec $cur '程式設計原則' $null; $cur = Set-Sec $cur '不做' "## 不做`n`n- 專案自己的不做清單"
[IO.File]::WriteAllText($feF, $cur.Replace("`n", "`r`n"), [Text.UTF8Encoding]::new($false))
$x = Run (Join-Path $kit 'install.ps1') @('-RepoRoot', $r, '-ProjectDir', 'app', '-Update', '-SkipTests')
$fe = [IO.File]::ReadAllText($feF)
Check '🔴 沒有基準：缺的節不插入、和內容不同的節一起列衝突，專案檔不動（保留 CRLF）' ($x.Code -eq 0 -and $fe -notmatch '## 程式設計原則' -and $fe -match '專案自己的不做清單' -and $fe -notmatch '(?<!\r)\n' -and $x.Out -match '待合併衝突 2 節' -and [IO.File]::ReadAllText($rep) -match 'frontend-expert' -and [IO.File]::ReadAllText($rep) -match '專案沒有這一節')
Check '🔴 沒有基準又有衝突 ⇒ 不建基準、提醒合併完跑 -AcceptAgents' (-not (Test-Path (Join-Path $ab 'agents/frontend-expert.md')) -and $x.Out -match '先不建基準')
$x = Run (Join-Path $kit 'install.ps1') @('-RepoRoot', $r, '-ProjectDir', 'app', '-Update', '-SkipTests')
Check '再跑一次（還是沒有基準）⇒ 照樣不插入、衝突照列' ($x.Code -eq 0 -and [IO.File]::ReadAllText($feF) -notmatch '## 程式設計原則' -and $x.Out -match '待合併衝突 2 節')
$x = Run (Join-Path $kit 'install.ps1') @('-RepoRoot', $r, '-ProjectDir', 'app', '-Update', '-AcceptAgents', 'frontend-expert', '-SkipTests')
Check '-AcceptAgents 之後才建基準、衝突清空' ($x.Code -eq 0 -and (Test-Path (Join-Path $ab 'agents/frontend-expert.md')) -and $x.Out -match '待合併衝突 0 節')
$x = Run (Join-Path $kit 'install.ps1') @('-RepoRoot', $r, '-ProjectDir', 'app', '-AcceptAgents', 'all', '-SkipTests')
Check '-AcceptAgents 沒帶 -Update ⇒ 報錯' ($x.Code -ne 0 -and $x.Out -match '只能跟 -Update 一起用')

Write-Host '--- 選配：pre-commit 密鑰掃描（-InstallPreCommit，2026-11-28）---'
$hookF = Join-Path $r '.git\hooks\pre-commit'
Check '沒帶 -InstallPreCommit ⇒ 不裝 hook' (-not (Test-Path $hookF))
$x = Run (Join-Path $kit 'install.ps1') @('-RepoRoot', $r, '-ProjectDir', 'app', '-Update', '-InstallPreCommit', '-SkipTests')
Check '-Update -InstallPreCommit ⇒ 裝好 hook，工具路徑含專案資料夾前綴' ($x.Code -eq 0 -and $x.Out -match 'pre-commit 密鑰掃描：已安裝' -and [IO.File]::ReadAllText($hookF) -match 'TOOL="app/AI_Service/hd5-tools/check-secrets\.mjs"' -and [IO.File]::ReadAllText($hookF) -notmatch "`r")
$gitc = { param([string[]]$a) $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'; try { $o = (& git -C $r @a 2>&1 | Out-String); [pscustomobject]@{ Code = $LASTEXITCODE; Out = $o } } finally { $ErrorActionPreference = $eap } }
[IO.File]::WriteAllText((Join-Path $r 'secret.cfg'), ("conn=Server=db;" + 'Pass' + "word=RealOne42;`n"), [Text.UTF8Encoding]::new($false))
$null = & $gitc @('add', 'secret.cfg'); $c = & $gitc @('commit', '-m', 'add secret')
Check '🔴 hook 擋下含密鑰的 commit（不印原文）' ($c.Code -ne 0 -and $c.Out -match '疑似密鑰' -and $c.Out -notmatch 'RealOne42' -and ((& $gitc @('log', '--oneline', '-1')).Out -notmatch 'add secret'))
$null = & $gitc @('reset', '-q', 'secret.cfg'); Remove-Item -LiteralPath (Join-Path $r 'secret.cfg')
[IO.File]::WriteAllText((Join-Path $r 'ok.txt'), "hello`n", [Text.UTF8Encoding]::new($false))
$null = & $gitc @('add', 'ok.txt'); $c = & $gitc @('commit', '-q', '-m', 'clean commit')
Check '乾淨的 commit 照常通過' ($c.Code -eq 0 -and ((& $gitc @('log', '--oneline', '-1')).Out -match 'clean commit'))
$x = Run (Join-Path $kit 'install.ps1') @('-RepoRoot', $r, '-ProjectDir', 'app', '-Update', '-InstallPreCommit', '-SkipTests')
Check '重跑：本套件裝的 hook 會更新' ($x.Code -eq 0 -and $x.Out -match 'pre-commit 密鑰掃描：已更新')
[IO.File]::WriteAllText($hookF, "#!/bin/sh`necho team-hook`n", [Text.UTF8Encoding]::new($false))
$x = Run (Join-Path $kit 'install.ps1') @('-RepoRoot', $r, '-ProjectDir', 'app', '-Update', '-InstallPreCommit', '-SkipTests')
Check '已經有別人的 pre-commit ⇒ 不覆蓋、印出怎麼接上' ($x.Code -eq 0 -and [IO.File]::ReadAllText($hookF) -match 'team-hook' -and $x.Out -match '沒有覆蓋' -and $x.Out -match 'check-secrets\.mjs" --staged')
Remove-Item -LiteralPath $hookF

Write-Host '--- 安裝到 repo 根 ---'
$r2 = New-Repo
$x = Run (Join-Path $kit 'install.ps1') @('-RepoRoot', $r2, '-SkipTests')
Check '安裝成功、hook 路徑沒有前綴' ($x.Code -eq 0 -and (((J (Join-Path $r2 '.claude/settings.json')).hooks.PreToolUse.hooks.command) -join ' ') -match '"AI_Service/hd5-tools/hooks/grill-gate\.ps1"')
$x = Run (Join-Path $kit 'install.ps1') @('-RepoRoot', (Join-Path ([IO.Path]::GetTempPath()) ('nogit_' + [guid]::NewGuid().ToString('N'))), '-SkipTests')
Check '不是 git repo ⇒ 失敗' ($x.Code -ne 0)

Write-Host '--- -Tracker azure-devops ---'
$r3 = New-Repo
$x = Run (Join-Path $kit 'install.ps1') @('-RepoRoot', $r3, '-Tracker', 'azure-devops')
Check '安裝成功（含裝好位置跑工單工具測試）' ($x.Code -eq 0 -and $x.Out -match 'workitem-ops.tests.ps1：ALL PASSED' -and $x.Out -match 'devops-lib.tests.ps1：ALL PASSED')
Check '工單工具裝在 hd5-tools/workitem、skill 只帶 SKILL.md' ((Test-Path (Join-Path $r3 'AI_Service/hd5-tools/workitem/workitem-ops.ps1')) -and (Test-Path (Join-Path $r3 '.claude/skills/hd5-workitem/SKILL.md')) -and (Test-Path (Join-Path $r3 '.agents/skills/hd5-workitem/SKILL.md')) -and -not (Test-Path (Join-Path $r3 '.claude/skills/hd5-workitem/scripts')))
$gi = [IO.File]::ReadAllText((Join-Path $r3 '.gitignore'))
Check 'workflow.json 的 tracker.type 寫成 azure-devops' ((J (Join-Path $r3 '.claude/workflow.json')).tracker.type -eq 'azure-devops')
Check 'repo 根 .gitignore 排除 PAT 檔' ($gi -match '(?m)^pat.local.txt' -and $gi -match '(?m)^pat.write.local.txt')
$x = Run (Join-Path $kit 'install.ps1') @('-RepoRoot', $r3, '-Tracker', 'azure-devops', '-SkipTests')
Check '重跑不重複加 .gitignore' (([regex]::Matches([IO.File]::ReadAllText((Join-Path $r3 '.gitignore')), '(?m)^pat.local.txt')).Count -eq 1)
# -Update：workflow.json 的 tracker＝azure-devops（沒帶 -Tracker）⇒ 工單工具也更新；工單工具資料夾的 PAT 檔保留
[IO.File]::AppendAllText((Join-Path $r3 'AI_Service/hd5-tools/workitem/workitem-ops.ps1'), "`n# 專案端被改過`n")
[IO.File]::WriteAllText((Join-Path $r3 'AI_Service/hd5-tools/workitem/pat.local.txt'), 'secret-pat')
$x = Run (Join-Path $kit 'install.ps1') @('-RepoRoot', $r3, '-Update', '-SkipTests')
Check '-Update：tracker＝azure-devops ⇒ 工單工具覆蓋回套件版本、PAT 檔保留' ($x.Code -eq 0 -and (SameBytes (Join-Path $r3 'AI_Service/hd5-tools/workitem/workitem-ops.ps1') (Join-Path $kit 'hd5-workitem/scripts/workitem-ops.ps1')) -and [IO.File]::ReadAllText((Join-Path $r3 'AI_Service/hd5-tools/workitem/pat.local.txt')) -eq 'secret-pat')
Remove-Item -LiteralPath $r3 -Recurse -Force -ErrorAction SilentlyContinue

foreach ($d in $r, $r2) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host ''
if ($script:fail) { Write-Host "FAILED: $($script:fail)" -ForegroundColor Red; exit 1 } else { Write-Host 'ALL PASSED' -ForegroundColor Green }
