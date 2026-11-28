<#
.SYNOPSIS
  grill-gate.ps1（Claude 派發子代理的 PreToolUse hook）離線測試：用暫存資料夾造 IMOCore 結構，餵派發 JSON 看 exit code。
  執行：pwsh -File IMOCore/.claude/hooks/tests/grill-gate.tests.ps1；最後一行要是 ALL PASSED。
#>
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
$hook = (Resolve-Path (Join-Path $PSScriptRoot '..\grill-gate.ps1')).Path
# HD5Skills：hooks/tests → tools；IMOCore 舊位置：.claude/hooks/tests → AI_Service/…
$first = { param($c) $c | Where-Object { Test-Path $_ } | Select-Object -First 1 }
$realGate = (Resolve-Path (& $first @((Join-Path $PSScriptRoot '..\..\validate-grill-gate.ps1'), (Join-Path $PSScriptRoot '..\..\..\AI_Service\.agents\skills\imocore-vue3-workflow\scripts\validate-grill-gate.ps1')))).Path
$realLib = (Resolve-Path (& $first @((Join-Path $PSScriptRoot '..\..\_verify-map-lib.ps1'), (Join-Path $PSScriptRoot '..\..\..\AI_Service\agent\scripts\_verify-map-lib.ps1')))).Path
$script:fail = 0
function Check($name, $cond) { if ($cond) { Write-Host "  ok   $name" } else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:fail++ } }

# 暫存的 IMOCore 根：AI_Service/（真的 validate-grill-gate 與 verify lib）＋功能地圖＋兩個案子
$root = Join-Path ([IO.Path]::GetTempPath()) ('grillhook_' + [guid]::NewGuid().ToString('N'))
$ai = Join-Path $root 'AI_Service'
$gateDir = Join-Path $ai '.agents\skills\imocore-vue3-workflow\scripts'
New-Item -ItemType Directory -Force $gateDir, (Join-Path $ai 'agent\scripts'), (Join-Path $ai 'verify\features') | Out-Null
Copy-Item $realGate $gateDir; Copy-Item $realLib (Join-Path $ai 'agent\scripts')
. $realLib
$doc = @('# 驗證文件', '') + @($script:VerifyDocSections | ForEach-Object { "## $($_.Label)"; '內容。'; '' })
Set-Content (Join-Path $ai 'verify\verify-t.md') $doc -Encoding UTF8
Set-Content (Join-Path $ai 'verify\features\README.md') '# 共同前提' -Encoding UTF8
foreach ($id in 'f-a', 'f-b', 'f-c') {
    $body = @("# $id", '功能。', '') + @($script:FeatureSections | ForEach-Object { "## $($_.Label)"; if ($_.Key -eq 'Driving it') { '前提：帳號。'; '1. 開頁 → 看到' } else { '- 內容' }; '' })
    Set-Content (Join-Path $ai "verify\features\$id.md") $body -Encoding UTF8
}
function New-Case([string]$name, [string]$route, [switch]$WithBugAnalysis, [switch]$WithGrill) {
    $c = Join-Path $ai "spec\$name"
    New-Item -ItemType Directory -Force (Join-Path $c 'case_spec_content') | Out-Null
    $spec = "## 5. 驗收條件`n- [ ] x（@功能:f-a）"; if ($route) { $spec += "`n`n路線：$route，高風險：否，外部系統：無，理由：測試" }
    Set-Content (Join-Path $c 'case_spec_content\spec_001.md') $spec -Encoding UTF8
    if ($WithGrill) { New-Item -ItemType Directory -Force (Join-Path $c 'pm'), (Join-Path $c 'sa') | Out-Null; Set-Content (Join-Path $c 'pm\grill-x.md') '已拍板' -Encoding UTF8; Set-Content (Join-Path $c 'sa\grill-x.md') "已拍板`n`n## 設計形狀`n資料形狀：已拍板" -Encoding UTF8 }
    if ($WithBugAnalysis) { New-Item -ItemType Directory -Force (Join-Path $c 'sa') | Out-Null; Set-Content (Join-Path $c 'sa\bug-analysis.md') "## 原因`na`n## 影響範圍`nb`n## 同類位置`nc`n## 修法`nd`n## 待決事項`n待決事項：無" -Encoding UTF8 }
}
New-Case 'full-ok' '四角色' -WithGrill
New-Case 'bug-nosa' '小問題'
New-Case 'bug-ok' '小問題' -WithBugAnalysis
New-Case 'noroute' '' -WithGrill

function Invoke-Hook([string]$agent, [string]$prompt) {
    $json = @{ tool_name = 'Agent'; cwd = $root; tool_input = @{ subagent_type = $agent; prompt = $prompt } } | ConvertTo-Json -Compress
    $psi = [Diagnostics.ProcessStartInfo]::new([Environment]::ProcessPath, "-NoProfile -NonInteractive -ExecutionPolicy Bypass -Command `"`$global:LASTEXITCODE = 0; & '$($hook.Replace("'", "''"))'; if (`$?) { exit 0 } elseif (`$LASTEXITCODE) { exit `$LASTEXITCODE } else { exit 1 }`"")
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardError = $true; $psi.RedirectStandardOutput = $true; $psi.UseShellExecute = $false
    $psi.WorkingDirectory = $root
    $psi.StandardInputEncoding = [Text.UTF8Encoding]::new($false); $psi.StandardErrorEncoding = [Text.Encoding]::UTF8; $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $p = [Diagnostics.Process]::Start($psi); $p.StandardInput.Write($json); $p.StandardInput.Close()
    $so = $p.StandardOutput.ReadToEndAsync(); $err = $p.StandardError.ReadToEnd(); $p.WaitForExit()
    $ctx = $null; try { $ctx = ($so.Result.Trim() | ConvertFrom-Json).hookSpecificOutput } catch { }
    [pscustomobject]@{ Code = $p.ExitCode; Err = $err; Out = $so.Result; Ctx = $(if ($ctx) { [string]$ctx.additionalContext } else { '' }); Event = $(if ($ctx) { [string]$ctx.hookEventName } else { '' }) }
}
# 2026-11-24：放行不再靜默——stdout 要是一行 PreToolUse 的 additionalContext，含路徑、代理、案子、閘 exit 碼
function Test-PassLine($r, [string]$agent, [string]$case, [string]$gate) {
    $r.Code -eq 0 -and $r.Event -eq 'PreToolUse' -and $r.Ctx -match '^grill-gate 放行：' -and $r.Ctx -match "代理=$([regex]::Escape($agent))" -and
        $r.Ctx -match "案子=$([regex]::Escape($case))" -and $r.Ctx -match "閘 exit=$([regex]::Escape($gate))"
}

Write-Host '--- 指到案子：改用 validate-grill-gate 檢查那個案子 ---'
$r = Invoke-Hook 'backend-expert' '任務：修 AI_Service/spec/full-ok 的匯入'
Check '四角色、紀錄齊 ⇒ 放行' ($r.Code -eq 0)
Check '放行時回一行 additionalContext（validate 通過、代理、案子、exit 0、帶 GRILL_GATE=pass 摘要）' ((Test-PassLine $r 'backend-expert' 'full-ok' '0') -and $r.Ctx -match 'GRILL_GATE=pass role=backend')
Check '沒有警告時放行訊息不帶警告' ($r.Ctx -notmatch 'grill-gate 警告')
# 2026-11-25：閘的「grill-gate 警告：…」（外部系統宣告／樣本表／驗收回合，不擋）要跟著放行訊息交給主對話
New-Case 'noext' '四角色' -WithGrill
Set-Content (Join-Path $ai 'spec\noext\case_spec_content\spec_001.md') "## 5. 驗收條件`n- [ ] x（@功能:f-a）`n`n路線：四角色，高風險：否，理由：沒寫外部系統" -Encoding UTF8
$r = Invoke-Hook 'backend-expert' '任務：修 AI_Service/spec/noext 的匯入'
Check '閘有警告 ⇒ 照樣放行（exit 0），放行訊息帶出「grill-gate 警告：[1/1] 外部系統…」' ((Test-PassLine $r 'backend-expert' 'noext' '0') -and $r.Ctx -match 'grill-gate 警告：\[1/1\] 外部系統')
Check '警告摘要排在各項前面（共 1 項、列出類別）' ($r.Ctx -match 'grill-gate 警告摘要：共 1 項（外部系統）' -and $r.Ctx.IndexOf('警告摘要') -lt $r.Ctx.IndexOf('[1/1]'))
$r = Invoke-Hook 'backend-expert' '任務：修 AI_Service/spec/bug-nosa 的匯入'
Check '🔴 小問題沒有 SA 分析就派實作代理 ⇒ 攔（exit 2，帶 validate 的原因）' ($r.Code -eq 2 -and $r.Err -match 'bug-analysis')
Check '攔下時 stdout 不印放行訊息' ($r.Out -notmatch '放行')
# 舊名別名（IMOCore 過渡期 csharp-expert）：只在本專案 workflow.json 有設這個別名時才測
$wfAliases = @(); try { $loc = @((Join-Path $PSScriptRoot '..\..\_hd5-locate.ps1'), (Join-Path $PSScriptRoot '..\..\..\AI_Service\agent\scripts\_hd5-locate.ps1')) | Where-Object { Test-Path $_ } | Select-Object -First 1
  $wfj = if ($loc) { . $loc; (Get-HD5Project -Start (Split-Path $hook -Parent)).Workflow } else { Get-Content -Raw (Join-Path $PSScriptRoot '..\..\workflow.json') -Encoding UTF8 | ConvertFrom-Json }
  $wfAliases = @($wfj.implementers | ForEach-Object { $_.aliases }) } catch { }
if ($wfAliases -contains 'csharp-expert') {
    $r = Invoke-Hook 'csharp-expert' '任務：修 AI_Service/spec/bug-nosa 的匯入'
    Check '🔴 舊名 csharp-expert（workflow.json 別名）一樣攔' ($r.Code -eq 2 -and $r.Err -match 'bug-analysis')
} else { Write-Host '  ok   （本專案 workflow.json 沒有舊名別名，略過別名測試）' }
$r = Invoke-Hook 'frontend-expert' '任務：AI_Service\spec\bug-ok 依 sa/bug-analysis.md 修畫面'
Check '新名 frontend-expert、SA 分析齊 ⇒ 放行' ($r.Code -eq 0)
$r = Invoke-Hook 'sa-expert' '任務：盤查 AI_Service/spec/bug-nosa'
Check '小問題派 SA 不需要 pm/ ⇒ 放行' ($r.Code -eq 0)
$r = Invoke-Hook 'frontend-expert' '任務：AI_Service\spec\bug-ok 依 sa/bug-analysis.md 修'
Check '小問題 SA 分析齊、反斜線路徑也認得 ⇒ 放行' ($r.Code -eq 0)
$r = Invoke-Hook 'backend-expert' "任務：AI_Service/spec/bug-ok`nGRILL_GATE=skip"
Check '🔴 有路線又帶 GRILL_GATE=skip ⇒ 攔（不准跳步）' ($r.Code -eq 2 -and $r.Err -match 'exit 9')
$r = Invoke-Hook 'qa-expert' '任務：AI_Service/spec/noroute 補測試'
Check '🔴 沒寫路線 ⇒ 攔（exit 8）' ($r.Code -eq 2 -and $r.Err -match 'exit 8')
$r = Invoke-Hook 'qa-expert' "任務：AI_Service/spec/noroute 補測試`nSKIP_ROUTE=11-23 前已進 QA"
Check '舊案 SKIP_ROUTE=理由 ⇒ 放行' ($r.Code -eq 0)
# 11-24 改用 -Command 呼叫質詢閘：理由裡的單引號、分號不能變成指令（注入就會跑出 exit 0 以外的東西或多執行一段）
$marker = Join-Path ([IO.Path]::GetTempPath()) ('gg_inject_' + [guid]::NewGuid().ToString('N').Substring(0, 6))
$r = Invoke-Hook 'qa-expert' "任務：AI_Service/spec/noroute 補測試`nSKIP_ROUTE=it's 舊案'; New-Item -ItemType File '$marker'; '"
Check "SKIP_ROUTE 含單引號＋分號 ⇒ 當成理由文字放行、不執行（$($r.Code)）" ($r.Code -eq 0 -and -not (Test-Path -LiteralPath $marker))
Remove-Item -LiteralPath $marker -ErrorAction SilentlyContinue

Write-Host '--- 沒指到案子：維持舊邏輯 ---'
$r = Invoke-Hook 'backend-expert' '幫我看一下這段程式'
Check '有任一案 sa/grill 已拍板 ⇒ 放行（舊邏輯）' ($r.Code -eq 0)
Check '舊邏輯放行也有訊息：寫明沒指到案子、閘未呼叫' ((Test-PassLine $r 'backend-expert' '（未指到）' '未呼叫') -and $r.Ctx -match '舊邏輯（prompt 沒指到案子）')
$r = Invoke-Hook 'pm-expert' '任務：AI_Service/spec/bug-nosa'
Check 'pm-expert 不攔' ($r.Code -eq 0)
Check 'pm-expert 放行也有訊息（不是角色閘名單）' ((Test-PassLine $r 'pm-expert' '（未指到）' '未呼叫') -and $r.Ctx -match '不是要過質詢閘')
$r = Invoke-Hook 'general-purpose' '任務：AI_Service/spec/bug-nosa'
Check '非角色代理不攔' ($r.Code -eq 0)
$r = Invoke-Hook 'backend-expert' '任務：AI_Service/spec/not-exist-case'
Check '指到不存在的案子 ⇒ 走舊邏輯（放行）' ($r.Code -eq 0)
Check '指到不存在的案子：訊息寫明找不到案子資料夾' ($r.Ctx -match 'not-exist-case 但找不到該案子資料夾')

# 2026-11-28 king_wu 回報：工作分支用 worktree（.claude/worktrees/<名>），案子資料夾只在 worktree 裡；session 在 repo 根開
# ⇒ hook 只看 cwd 找不到案子，掉進舊邏輯（幾乎不擋）。要也找 git worktree 的各個路徑，以及 prompt 裡寫的絕對路徑。
Write-Host '--- 案子只在 worktree 裡、session 在主 checkout 開（2026-11-28）---'
$gw = { param([string[]]$a) $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'; try { (& git -C $root @a 2>$null) } finally { $ErrorActionPreference = $eap } }
$null = & $gw @('init', '-q'); $null = & $gw @('config', 'user.email', 't@t'); $null = & $gw @('config', 'user.name', 't'); $null = & $gw @('config', 'core.autocrlf', 'false')
$null = & $gw @('add', '-A'); $null = & $gw @('commit', '-q', '-m', 'base')
$wt = Join-Path $root '.claude\worktrees\wt1'
$null = & $gw @('worktree', 'add', '-q', '-b', 'wt1', $wt)
$wtCase = Join-Path $wt 'AI_Service\spec\wt-case'
New-Item -ItemType Directory -Force (Join-Path $wtCase 'case_spec_content'), (Join-Path $wtCase 'sa'), (Join-Path $wtCase 'pm') | Out-Null
Set-Content (Join-Path $wtCase 'case_spec_content\spec_001.md') "## 5. 驗收條件`n- [ ] x（@功能:f-a）`n`n路線：四角色，高風險：否，外部系統：無，理由：測試" -Encoding UTF8
Set-Content (Join-Path $wtCase 'pm\grill-x.md') '已拍板' -Encoding UTF8
Set-Content (Join-Path $wtCase 'sa\grill-x.md') "已拍板`n`n## 設計形狀`n資料形狀：已拍板" -Encoding UTF8
Check '（前提）主 checkout 沒有這個案子資料夾' (-not (Test-Path (Join-Path $ai 'spec\wt-case')) -and (Test-Path $wtCase))
$r = Invoke-Hook 'backend-expert' '任務：修 AI_Service/spec/wt-case 的匯入'
Check '🔴 案子只在 worktree：hook 照樣找到並呼叫 validate-grill-gate（不掉進舊邏輯）' ((Test-PassLine $r 'backend-expert' 'wt-case' '0') -and $r.Ctx -match 'validate-grill-gate 通過')
Set-Content (Join-Path $wtCase 'sa\grill-x.md') '還在討論' -Encoding UTF8
$r = Invoke-Hook 'backend-expert' '任務：修 AI_Service/spec/wt-case 的匯入'
Check '🔴 worktree 裡的案子沒過質詢閘 ⇒ 攔（exit 2）' ($r.Code -eq 2 -and $r.Err -match 'wt-case')
# prompt 寫了不在任何專案根／worktree 底下的絕對路徑 ⇒ 直接採用
$other = Join-Path ([IO.Path]::GetTempPath()) ('grillhook_abs_' + [guid]::NewGuid().ToString('N'))
Copy-Item -Recurse (Join-Path $ai 'verify') (Join-Path $other 'AI_Service\verify')
$absCase = Join-Path $other 'AI_Service\spec\abs-case'
New-Item -ItemType Directory -Force (Join-Path $absCase 'case_spec_content'), (Join-Path $absCase 'sa'), (Join-Path $absCase 'pm') | Out-Null
Set-Content (Join-Path $absCase 'case_spec_content\spec_001.md') "## 5. 驗收條件`n- [ ] x（@功能:f-a）`n`n路線：四角色，高風險：否，外部系統：無，理由：測試" -Encoding UTF8
Set-Content (Join-Path $absCase 'pm\grill-x.md') '已拍板' -Encoding UTF8
Set-Content (Join-Path $absCase 'sa\grill-x.md') "已拍板`n`n## 設計形狀`n資料形狀：已拍板" -Encoding UTF8
$r = Invoke-Hook 'backend-expert' "任務：案子在 $absCase ，照 SA 文件實作"
Check 'prompt 寫案子的絕對路徑 ⇒ 直接採用、呼叫 validate-grill-gate' ((Test-PassLine $r 'backend-expert' 'abs-case' '0') -and $r.Ctx -match 'validate-grill-gate 通過')
Remove-Item -LiteralPath $other -Recurse -Force -ErrorAction SilentlyContinue

Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
if ($script:fail) { Write-Host "FAILED: $($script:fail)" -ForegroundColor Red; exit 1 } else { Write-Host 'ALL PASSED' -ForegroundColor Green }
