<#
.SYNOPSIS
  一次跑完 HD5Skills 的全部測試（2026-11-28）。本機與 CI（.github/workflows/tests.yml）都用這一支。
  用哪一版 PowerShell 執行它，測試就用那一版跑：
    pwsh -File tests/run-all.ps1                 PowerShell 7：所有 *.tests.ps1＋Node 工具的 --selftest
    powershell -File tests/run-all.ps1           Windows PowerShell 5.1：所有 *.tests.ps1（install.tests.ps1 只支援 pwsh，略過）
  自動找測試：版控內的 *.tests.ps1、內含「--selftest」的 .mjs——新加的測試不用改這支。
  每支測試各開一個子程序跑；判定＝輸出有「ALL PASSED」、沒有「FAIL」行（不只看結束碼：有些測試的結束碼會被最後一個外部指令帶走）。
  全部通過 exit 0，有任何一支沒過 exit 1，並印出沒過那支的最後 40 行。
.PARAMETER Filter
  只跑路徑含這段文字的測試（例 -Filter grill），排錯用。
#>
param([string]$Filter = '')
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object Text.UTF8Encoding $false } catch { }
$kit = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$isDesktop = $PSVersionTable.PSEdition -eq 'Desktop'
$exe = (Get-Process -Id $PID).Path
$edition = if ($isDesktop) { "Windows PowerShell $($PSVersionTable.PSVersion)" } else { "PowerShell $($PSVersionTable.PSVersion)" }

$eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
$files = @(& git -C $kit -c core.quotepath=false ls-files 2>$null)
$ErrorActionPreference = $eap
if (-not $files.Count) { Write-Host 'FAILED: 找不到版控內的檔案（要在 HD5Skills 的 git repo 裡跑）' -ForegroundColor Red; exit 1 }

$jobs = @()
foreach ($f in @($files | Where-Object { $_ -match '\.tests\.ps1$' } | Sort-Object)) {
    if ($isDesktop -and $f -eq 'tests/install.tests.ps1') { continue }   # install.ps1 需要 PowerShell 7（README「需求」）
    $jobs += [pscustomobject]@{ Name = $f; Kind = 'ps1' }
}
$node = Get-Command node -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $isDesktop) {
    if (-not $node) { Write-Host 'FAILED: 找不到 node（Node 工具的 --selftest 要用）' -ForegroundColor Red; exit 1 }
    foreach ($f in @($files | Where-Object { $_ -match '\.mjs$' } | Sort-Object)) {
        if ([IO.File]::ReadAllText((Join-Path $kit $f)).Contains("'--selftest'")) { $jobs += [pscustomobject]@{ Name = $f; Kind = 'node' } }
    }
}
if ($Filter) { $jobs = @($jobs | Where-Object { $_.Name -like "*$Filter*" }) }

Write-Host "== HD5Skills 全部測試（$edition，$($jobs.Count) 支）"
$results = @()
foreach ($j in $jobs) {
    $path = Join-Path $kit $j.Name
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        if ($j.Kind -eq 'node') { $out = (& $node.Source $path --selftest 2>&1 | Out-String) }
        else { $out = (& $exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $path 2>&1 | Out-String) }
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $eap }
    $sw.Stop()
    $fails = @([regex]::Matches($out, '(?m)^\s*FAIL\b')).Count
    $ok = ($out -match '(?m)ALL PASSED\s*$') -and $fails -eq 0 -and ($j.Kind -ne 'node' -or $code -eq 0)
    $results += [pscustomobject]@{ Name = $j.Name; Ok = $ok; Fails = $fails; Sec = [math]::Round($sw.Elapsed.TotalSeconds); Out = $out }
    $mark = if ($ok) { 'ok  ' } else { 'FAIL' }
    Write-Host ("  {0} {1}（{2} 秒{3}）" -f $mark, $j.Name, [math]::Round($sw.Elapsed.TotalSeconds), $(if ($ok) { '' } else { "，FAIL $fails 項" })) -ForegroundColor $(if ($ok) { 'Gray' } else { 'Red' })
}

$bad = @($results | Where-Object { -not $_.Ok })
foreach ($b in $bad) {
    Write-Host ''
    Write-Host "---- $($b.Name) 的最後 40 行 ----" -ForegroundColor Red
    ($b.Out.TrimEnd() -split "`r?`n" | Select-Object -Last 40) | ForEach-Object { Write-Host "  | $_" }
}
Write-Host ''
if ($bad.Count) { Write-Host "FAILED: $($bad.Count)／$($results.Count) 支沒過（$edition）" -ForegroundColor Red; exit 1 }
Write-Host "ALL PASSED（$edition，$($results.Count) 支）" -ForegroundColor Green
exit 0
