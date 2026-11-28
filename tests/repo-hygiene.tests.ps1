<#
.SYNOPSIS
  套件本身的檔案衛生檢查（2026-11-28）：PowerShell 7 與 Windows PowerShell 5.1 都能跑；最後一行要是 ALL PASSED。
  1. 所有版控內的 *.ps1 都要有 UTF-8 BOM——5.1 沒有 BOM 會用系統字碼頁（Big5）讀檔，中文變亂碼：
     測試檔直接解析失敗、lib 裡的中文比對字串（例「本專案技術架構重點」）靜默失效。（king_wu 導入實測）
  2. 文字檔不能有控制字元（Tab、換行、歸位以外）——用腳本改檔時 \v、\b 這類跳脫很容易被寫成真的控制字元。
  執行：pwsh -File tests/repo-hygiene.tests.ps1（或 powershell.exe -File …）
#>
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object Text.UTF8Encoding $false } catch { }
$kit = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$script:fail = 0
function Check($name, $cond, [string[]]$detail = @()) {
    if ($cond) { Write-Host "  ok   $name" } else { Write-Host "  FAIL $name" -ForegroundColor Red; foreach ($d in $detail) { Write-Host "       $d" }; $script:fail++ }
}

$eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
$files = @(& git -C $kit -c core.quotepath=false ls-files 2>$null)
$ErrorActionPreference = $eap
Check '找得到版控內的檔案（要在 git repo 裡跑）' ($files.Count -gt 0)

Write-Host '--- *.ps1 都要有 UTF-8 BOM（Windows PowerShell 5.1）---'
$ps1 = @($files | Where-Object { $_ -match '\.ps1$' })
$noBom = @($ps1 | Where-Object {
        $b = [IO.File]::ReadAllBytes((Join-Path $kit $_))
        -not ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
    })
Check "$($ps1.Count) 支 .ps1 都有 BOM" ($noBom.Count -eq 0) ($noBom | ForEach-Object { "缺 BOM：$_（修法：內容不變，改存成 UTF-8 with BOM）" })

Write-Host '--- 文字檔沒有誤寫的控制字元 ---'
$text = @($files | Where-Object { $_ -match '\.(ps1|mjs|js|cjs|md|html|tpl|json|sh|txt)$' })
$utf8 = New-Object Text.UTF8Encoding $false
$bad = @()
foreach ($f in $text) {
    $s = [IO.File]::ReadAllText((Join-Path $kit $f), $utf8)
    $m = [regex]::Match($s, '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]')
    if ($m.Success) {
        $line = ([regex]::Matches($s.Substring(0, $m.Index), "`n")).Count + 1
        $bad += "$($f):$line 有控制字元 0x$('{0:X2}' -f [int][char]$m.Value)"
    }
}
Check "$($text.Count) 個文字檔沒有控制字元" ($bad.Count -eq 0) $bad

Write-Host ''
if ($script:fail) { Write-Host "FAILED: $($script:fail)" -ForegroundColor Red; exit 1 } else { Write-Host 'ALL PASSED' -ForegroundColor Green; exit 0 }
