<#
.SYNOPSIS
  檢查這個專案的功能地圖（AI_Service/verify/）是否存在且格式合格。不合格 exit 1。

.DESCRIPTION
  規範：hd5-verify skill。呼叫點（🔴 都是硬擋）：
    - 開工：接新案、開始 PG 前先跑；失敗就先建立功能地圖
    - PG 開發中自驗、站上關卡（hd5-onsite-gate）開始驗之前；失敗就標「受阻」不開始驗
    - 工單閘（有工單系統時，改待驗收前）會自動呼叫同一套檢查
  -Onsite 給站上關卡報告路徑時，一併檢查 A 表每條是否對到功能編號、Pass 是否有證據檔；
  2026-11-25 起（報告日期 ≥ 2026-11-25 或沒寫日期）另印**警告**（不影響 exit 碼；hd5-onsite-gate 第四節、第七節第 4 項）：
    - qa/rework-log.md 最新一輪退回不晚於本報告，A 表卻沒有（新打通）列、也沒有「新打通：無（理由）」
    - 上一輪同一項也是「未驗證（待使用者動作…）」，又沒有「使用者放行：<項目>…（MM-DD）」
  判定在 _verify-map-lib.ps1 的 Test-OnsiteGateEvidence，工單閘呼叫同一支函式。

.EXAMPLE
  & "AI_Service/hd5-tools/verify-map-check.ps1"
  & "AI_Service/hd5-tools/verify-map-check.ps1" -Onsite ".../spec/{case}/qa/onsite-gate_R1.md"
#>
[CmdletBinding()]
param(
    # 預設＝<專案>/<AI_Service>/verify（由 _hd5-locate.ps1 找專案）；找不到專案設定時退回本檔往上兩層的 verify（IMOCore 舊位置）
    [string]$VerifyRoot,
    [string]$Onsite
)
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
. (Join-Path $PSScriptRoot '_verify-map-lib.ps1')
if ([string]::IsNullOrWhiteSpace($VerifyRoot)) {
    $VerifyRoot = Join-Path $PSScriptRoot '..\..\verify'
    $loc = Join-Path $PSScriptRoot '_hd5-locate.ps1'
    if (Test-Path -LiteralPath $loc) { . $loc; $hp = Get-HD5Project -Start $PSScriptRoot; if ($hp.ConfigPath -and $hp.ProjectDir) { $VerifyRoot = Join-Path $hp.ProjectDir "$($hp.AiService)\verify" } }
}

$root = [IO.Path]::GetFullPath($VerifyRoot)
$map = Test-VerifyMap -VerifyRoot $root
$fail = 0
if ($map.Passed) {
    Write-Host "✅ 功能地圖合格：$root"
    Write-Host "   驗證文件：$($map.VerifyDoc.Name)｜功能 $($map.FeatureIds.Count) 個：$($map.FeatureIds -join '、')"
} else {
    $fail++
    Write-Host "❌ 功能地圖不合格：$root" -ForegroundColor Red
    foreach ($r in $map.Reasons) { Write-Host "   - $r" -ForegroundColor Red }
}
if ($Onsite) {
    if (-not $map.Passed) { Write-Host '   （功能地圖不合格，略過站上關卡證據檢查）' }
    else {
        $ev = Test-OnsiteGateEvidence -Path $Onsite -FeatureIds $map.FeatureIds
        if ($ev.Legacy) { Write-Host "ℹ $Onsite 為舊格式（日期早於生效日），不檢查證據" }
        elseif ($ev.Passed) { Write-Host "✅ 站上關卡證據合格：$Onsite" }
        else { $fail++; Write-Host "❌ 站上關卡證據不合格：$Onsite" -ForegroundColor Red; foreach ($r in $ev.Reasons) { Write-Host "   - $r" -ForegroundColor Red } }
        # 只提醒、不影響 exit 碼（2026-11-25 使用者拍板）
        foreach ($w in @($ev.Warnings | Where-Object { $_ })) { Write-Host "⚠ 站上關卡警告（不擋）：$w" -ForegroundColor Yellow }
    }
}
if ($fail) { exit 1 }
exit 0
