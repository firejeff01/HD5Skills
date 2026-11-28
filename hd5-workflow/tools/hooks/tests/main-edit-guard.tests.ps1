<#
.SYNOPSIS
  main-edit-guard.ps1（主對話不准直接改產品程式的 PreToolUse hook）離線測試：暫存 git repo＋假 origin/dev，餵 Edit／Write payload 看 exit code。
  執行：pwsh -File IMOCore/.claude/hooks/tests/main-edit-guard.tests.ps1；最後一行要是 ALL PASSED。
#>
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
$hook = (Resolve-Path (Join-Path $PSScriptRoot '..\main-edit-guard.ps1')).Path
$script:fail = 0
# hook 在專案裡一律由 pwsh（PowerShell 7）執行（settings.hooks.json）⇒ 測試也用 pwsh 跑 hook；本測試本身 7 與 5.1 都能跑
$script:selfExe = $($c = Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1; if ($c) { $c.Source } else { (Get-Process -Id $PID).Path })
function Check($name, $cond) { if ($cond) { Write-Host "  ok   $name" } else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:fail++ } }
function G { & git -C $script:repo @args 2>&1 | Out-Null; if ($LASTEXITCODE) { throw "git $args 失敗" } }
# 測試裡的路徑寫 IMOCore/，跑之前換成本專案資料夾（新專案起手包複製過去也能跑）
# 跟 hook 用同一套規則算專案前綴（_hd5-locate.ps1）；找不到 locate 時退回 IMOCore 舊規則
$loc = @((Join-Path $PSScriptRoot '..\..\_hd5-locate.ps1'), (Join-Path $PSScriptRoot '..\..\..\AI_Service\agent\scripts\_hd5-locate.ps1')) | Where-Object { Test-Path $_ } | Select-Object -First 1
if ($loc) { . $loc; $script:P = (Get-HD5Project -Start (Split-Path $hook -Parent)).Prefix }
if ($null -eq $script:P) { $script:P = (& git -C $PSScriptRoot rev-parse --show-prefix 2>$null); $script:P = ([string]$script:P -replace '\\', '/') -replace '\.claude/hooks/tests/?$', '' }
function Fix([string]$rel) { return ($rel -replace '^IMOCore/', $script:P) }
function W($rel, $text) { $rel = Fix $rel; $p = Join-Path $script:repo $rel; New-Item -ItemType Directory -Force (Split-Path $p -Parent) | Out-Null; [IO.File]::WriteAllText($p, $text, [Text.UTF8Encoding]::new($false)) }

$script:repo = Join-Path ([IO.Path]::GetTempPath()) ('mainedit_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $script:repo | Out-Null
G init -q -b dev; G config user.email t@t; G config user.name t; G config core.autocrlf false
W 'IMOCore/DIMP/Controllers/A.cs' 'class A {}'
W 'IMOCore/DIMP/ClientApp/src/B.vue' '<template/>'
W 'IMOCore/DIMP/ClientApp/scripts/run.mjs' '//'
W 'IMOCore/IMO.Tests/ATests.cs' 'class ATests {}'
W 'IMOCore/AI_Service/agent/scripts/x.ps1' '#'
W 'IMOCore/AI_Service/spec/old-case/case_spec_content/spec_001.md' "## 5`n路線：四角色，高風險：否，理由：舊案（已在 origin/dev）"
G add -A; G commit -q -m base
G update-ref refs/remotes/origin/dev HEAD
G checkout -q -b project_x

function Invoke-Hook([string]$tool, [string]$file, [string]$agentId) {
    $file = Fix $file
    $p = @{ tool_name = $tool; cwd = $script:repo; tool_input = @{ file_path = (Join-Path $script:repo $file) } }
    if ($agentId) { $p.agent_id = $agentId; $p.agent_type = 'csharp-expert' }
    $json = $p | ConvertTo-Json -Compress
    $psi = [Diagnostics.ProcessStartInfo]::new($script:selfExe, "-NoProfile -NonInteractive -ExecutionPolicy Bypass -Command `"`$global:LASTEXITCODE = 0; & '$($hook.Replace("'", "''"))'; if (`$?) { exit 0 } elseif (`$LASTEXITCODE) { exit `$LASTEXITCODE } else { exit 1 }`"")
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardError = $true; $psi.RedirectStandardOutput = $true; $psi.UseShellExecute = $false
    $psi.WorkingDirectory = $script:repo; $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    $pr = [Diagnostics.Process]::Start($psi); $pr.StandardInput.BaseStream.Write(($jb = [Text.UTF8Encoding]::new($false).GetBytes($json)), 0, $jb.Length); $pr.StandardInput.Close()
    $err = $pr.StandardError.ReadToEnd(); $null = $pr.StandardOutput.ReadToEnd(); $pr.WaitForExit()
    [pscustomobject]@{ Code = $pr.ExitCode; Err = $err }
}

Write-Host '--- 沒有進行中的案子 ---'
$r = Invoke-Hook 'Edit' 'IMOCore/DIMP/Controllers/A.cs'
Check '只有 origin/dev 上的舊案（本分支沒改）⇒ 放行' ($r.Code -eq 0)

Write-Host '--- 本分支新案（路線＝小問題，未 commit）---'
W 'IMOCore/AI_Service/spec/bug-1/case_spec_content/spec_001.md' "## 5`n路線：小問題，高風險：否，理由：單一方法"
$r = Invoke-Hook 'Edit' 'IMOCore/DIMP/Controllers/A.cs'
Check '🔴 主對話改 .cs ⇒ 攔（exit 2，點名案子與要派誰）' ($r.Code -eq 2 -and $r.Err -match 'bug-1' -and $r.Err -match 'backend-expert')
$r = Invoke-Hook 'Edit' 'IMOCore/DIMP/ClientApp/src/B.vue'
Check '🔴 主對話改 .vue ⇒ 攔，建議 frontend-expert' ($r.Code -eq 2 -and $r.Err -match 'frontend-expert')
$r = Invoke-Hook 'Write' 'IMOCore/DIMP/Controllers/New/C.cs'
Check '🔴 主對話 Write 新檔（目錄還不存在）⇒ 攔' ($r.Code -eq 2)
$r = Invoke-Hook 'Edit' 'IMOCore/IMO.Tests/ATests.cs'
Check '🔴 主對話改測試 .cs ⇒ 攔（測試也由 PG／QA 寫）' ($r.Code -eq 2)
$r = Invoke-Hook 'Edit' 'IMOCore/DIMP/Controllers/A.cs' 'agent-123'
Check '子代理（帶 agent_id）改 .cs ⇒ 放行' ($r.Code -eq 0)
$r = Invoke-Hook 'Edit' 'IMOCore/AI_Service/agent/scripts/x.ps1'
Check 'AI_Service 底下（工具／文件）⇒ 放行' ($r.Code -eq 0)
$r = Invoke-Hook 'Edit' 'IMOCore/DIMP/ClientApp/scripts/run.mjs'
Check 'ClientApp/scripts（守衛工具）⇒ 放行' ($r.Code -eq 0)
$r = Invoke-Hook 'Write' 'IMOCore/AI_Service/spec/bug-1/sa/bug-analysis.md'
Check '.md 文件 ⇒ 放行' ($r.Code -eq 0)
$r = Invoke-Hook 'Read' 'IMOCore/DIMP/Controllers/A.cs'
Check 'Read 不在攔截範圍 ⇒ 放行' ($r.Code -eq 0)

Write-Host '--- 例外與分支 ---'
W 'IMOCore/AI_Service/spec/bug-1/case_spec_content/spec_001.md' "## 5`n路線：小問題，高風險：否，理由：單一方法`n主對話直接改：只改一行常數（使用者 11-23 同意）"
$r = Invoke-Hook 'Edit' 'IMOCore/DIMP/Controllers/A.cs'
Check 'spec_001 有「主對話直接改：理由」⇒ 放行' ($r.Code -eq 0)
W 'IMOCore/AI_Service/spec/bug-1/case_spec_content/spec_001.md' "## 5`n**路線**：四角色，高風險：是，理由：權限"
G add -A; G commit -q -m case
$r = Invoke-Hook 'Edit' 'IMOCore/DIMP/Controllers/A.cs'
Check '🔴 案子已 commit（與 origin/dev 不同）仍算進行中 ⇒ 攔' ($r.Code -eq 2 -and $r.Err -match '四角色')
G checkout -q dev
W 'IMOCore/AI_Service/spec/merging/case_spec_content/spec_001.md' "## 5`n路線：小問題，高風險：否，理由：合併時帶進來的案子"
$r = Invoke-Hook 'Edit' 'IMOCore/DIMP/Controllers/A.cs'
Check 'dev 分支（合併／解衝突，工作目錄有帶路線的案子）⇒ 放行' ($r.Code -eq 0)
Remove-Item -LiteralPath (Join-Path $script:repo (Fix 'IMOCore/AI_Service/spec/merging')) -Recurse -Force
G checkout -q project_x

Write-Host '--- 壞輸入一律放行 ---'
$psi = [Diagnostics.ProcessStartInfo]::new($script:selfExe, "-NoProfile -NonInteractive -ExecutionPolicy Bypass -Command `"`$global:LASTEXITCODE = 0; & '$($hook.Replace("'", "''"))'; if (`$?) { exit 0 } elseif (`$LASTEXITCODE) { exit `$LASTEXITCODE } else { exit 1 }`"")
$psi.RedirectStandardInput = $true; $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false
$pr = [Diagnostics.Process]::Start($psi); $pr.StandardInput.Write('不是 JSON'); $pr.StandardInput.Close(); $null = $pr.StandardError.ReadToEnd(); $pr.WaitForExit()
Check '解析失敗 ⇒ 放行' ($pr.ExitCode -eq 0)
$r = Invoke-Hook 'Edit' '..\outside-repo.cs'
Check '不在 git repo 裡的檔 ⇒ 放行' ($r.Code -eq 0)

Remove-Item -LiteralPath $script:repo -Recurse -Force -ErrorAction SilentlyContinue

Write-Host '--- 分支規則讀 workflow.json（develop＝main、工作分支 feature/、沒有遠端）---'
# hook 從自己的位置找 workflow.json ⇒ 把 hook 與 _hd5-locate.ps1 複製進暫存 repo（跟安裝後的位置一樣），測試不受本機專案設定影響
$locSrc = @((Join-Path $PSScriptRoot '..\..\_hd5-locate.ps1'), (Join-Path (Split-Path $hook -Parent) '_hd5-locate.ps1')) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $locSrc) { Check '找得到 _hd5-locate.ps1（分支規則測試需要）' $false } else {
    $script:repo = Join-Path ([IO.Path]::GetTempPath()) ('mainedit2_' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force $script:repo | Out-Null
    G init -q -b main; G config user.email t@t; G config user.name t; G config core.autocrlf false
    $hd = Join-Path $script:repo 'AI_Service/hd5-tools/hooks'; New-Item -ItemType Directory -Force $hd | Out-Null
    Copy-Item -LiteralPath $hook -Destination $hd; Copy-Item -LiteralPath $locSrc -Destination (Join-Path $script:repo 'AI_Service/hd5-tools/_hd5-locate.ps1')
    $savedHook = $hook; $hook = Join-Path $hd 'main-edit-guard.ps1'; $savedP = $script:P; $script:P = ''
    $wfJson = @{ paths = @{ aiService = 'AI_Service'; tools = 'AI_Service/hd5-tools' }; branches = @{ develop = 'main'; workBranchPrefix = 'feature/' }
        productCode = @{ extensions = @('.cs', '.vue', '.ts'); excludeDirs = @('AI_Service/', '.claude/', 'scripts/', '**/generated/') }
        roleHints = @(@{ agent = 'qa-expert'; pathHints = @('tests/', 'test/') })
        implementers = @(@{ agent = 'backend-expert'; extensions = @('.cs'); pathHints = @('src/') }, @{ agent = 'frontend-expert'; extensions = @('.vue', '.ts'); pathHints = @('frontend/') }) } | ConvertTo-Json -Depth 6
    W '.claude/workflow.json' $wfJson
    W 'src/Api/A.cs' 'class A {}'
    W 'AI_Service/spec/old/case_spec_content/spec_001.md' "路線：小問題，高風險：否，理由：舊案（已在 main）"
    G add -A; G commit -q -m base
    G checkout -q -b feature/id-01
    $r = Invoke-Hook 'Edit' 'src/Api/A.cs'
    Check 'feature/ 分支、只有 main 上的舊案 ⇒ 放行' ($r.Code -eq 0)
    W 'AI_Service/spec/id-01/case_spec_content/spec_001.md' "路線：四角色，高風險：否，理由：新功能"
    $r = Invoke-Hook 'Edit' 'src/Api/A.cs'
    Check '🔴 feature/ 分支有新案（未 commit）⇒ 攔，建議 backend-expert' ($r.Code -eq 2 -and $r.Err -match 'id-01' -and $r.Err -match 'backend-expert')
    G add -A; G commit -q -m case
    $r = Invoke-Hook 'Edit' 'src/Api/A.cs'
    Check '🔴 案子已 commit、沒有遠端 ⇒ 跟本地 main 比，仍算進行中 ⇒ 攔' ($r.Code -eq 2)

    Write-Host '--- excludeDirs 只比前綴、**/ 才比任意層（11-23 實測：scripts/ 誤排除 frontend/scripts/）---'
    $r = Invoke-Hook 'Edit' 'scripts/tool.ts'
    Check 'excludeDirs「scripts/」⇒ 專案資料夾根的 scripts/ 放行' ($r.Code -eq 0)
    $r = Invoke-Hook 'Edit' 'frontend/scripts/build.ts'
    Check '🔴 excludeDirs「scripts/」不排除 frontend/scripts/ ⇒ 攔，建議 frontend-expert' ($r.Code -eq 2 -and $r.Err -match '請派 frontend-expert')
    $r = Invoke-Hook 'Edit' 'frontend/src/generated/api.ts'
    Check 'excludeDirs「**/generated/」⇒ 任意層放行' ($r.Code -eq 0)

    Write-Host '--- roleHints：tests/ 歸 qa-expert（建議派誰最先比）---'
    $r = Invoke-Hook 'Edit' 'tests/Api/ApiTests.cs'
    Check '🔴 tests/ 底下的 .cs ⇒ 攔，建議 qa-expert（不是 backend-expert）' ($r.Code -eq 2 -and $r.Err -match '請派 qa-expert')
    $r = Invoke-Hook 'Edit' 'frontend/test/b.spec.ts'
    Check '🔴 任意層的 test/ ⇒ 建議 qa-expert' ($r.Code -eq 2 -and $r.Err -match '請派 qa-expert')
    $r = Invoke-Hook 'Edit' 'src/latest/L.cs'
    Check 'roleHints 比對從目錄邊界開始（src/latest/ 不算 test/）⇒ 建議 backend-expert' ($r.Code -eq 2 -and $r.Err -match '請派 backend-expert')
    G checkout -q -b project_y
    $r = Invoke-Hook 'Edit' 'src/Api/A.cs'
    Check 'workBranchPrefix＝feature/ 時 project_* 不是工作分支 ⇒ 放行' ($r.Code -eq 0)
    G checkout -q main
    W 'AI_Service/spec/m/case_spec_content/spec_001.md' "路線：小問題，高風險：否，理由：合併帶進來"
    $r = Invoke-Hook 'Edit' 'src/Api/A.cs'
    Check 'develop（main）分支 ⇒ 放行' ($r.Code -eq 0)
    $hook = $savedHook; $script:P = $savedP
    Remove-Item -LiteralPath $script:repo -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host ''
if ($script:fail) { Write-Host "FAILED: $($script:fail)" -ForegroundColor Red; exit 1 } else { Write-Host 'ALL PASSED' -ForegroundColor Green }
