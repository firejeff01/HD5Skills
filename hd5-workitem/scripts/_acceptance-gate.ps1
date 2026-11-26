<#
.SYNOPSIS
  hd5-workitem 的工單閘（唯一一份）：改「待驗收」與上傳結案報告前共用。

.DESCRIPTION
  由 _workitem-ops-lib.ps1 與 _devops-lib.ps1 以 dot-source 載入，不可直接執行。
  判定（hd5-onsite-gate 第七節的機器版）：
    qa/{Codex|Claude}驗收結果_[中綴_]R{n}[b].md 合併取最新一輪、qa/onsite-gate_[中綴_]R{n}[b].md 取最新一輪，
    兩者檔內最後一個「總結：」行都要通過；功能地圖合格；站上關卡 A 表每條對到功能、Pass 有證據。
  功能地圖檢查器 _verify-map-lib.ps1 由呼叫端（入口腳本的最上層）找到後 dot-source——它用 $script: 變數，
  不能在函式裡 dot-source；找不到就 fail closed。
  相容 Windows PowerShell 5.1 與 PowerShell 7；必須存成 UTF-8 with BOM。
#>

function Get-DevOpsLatestRoundFile {
    param([string]$Dir, [string]$Pattern)
    if (-not (Test-Path -LiteralPath $Dir)) { return $null }
    # 受阻後補齊證據重送同一輪＝R{n}b：排序 R1 < R1b < R1c < R2
    $best = $null; $bestN = -1; $bestB = ''; $bestKey = -1
    foreach ($f in @(Get-ChildItem -LiteralPath $Dir -File)) {
        $m = [regex]::Match($f.Name, $Pattern)
        if ($m.Success) {
            $n = [int]$m.Groups['n'].Value
            $b = if ($m.Groups['b'].Success) { $m.Groups['b'].Value } else { '' }
            $key = $n * 100 + $(if ($b) { [int][char]$b - 96 } else { 0 })
            if ($key -gt $bestKey) { $bestKey = $key; $bestN = $n; $bestB = $b; $best = $f }
        }
    }
    if ($null -eq $best) { return $null }
    return [pscustomobject]@{ File = $best; Round = $bestN; Tag = "$bestN$bestB" }
}

function Get-DevOpsSummaryLine {
    # 取檔內「最後一個」總結行。不用最後一行：結果檔在總結前後常有「新發現：N 筆」。
    param([string]$Path)
    $hits = @(Get-Content -LiteralPath $Path -Encoding UTF8 | ForEach-Object { ([string]$_).Replace('*', '').Trim() } | Where-Object { $_ -match '^總結[:：]' })
    if ($hits.Count -eq 0) { return '' }
    return $hits[-1]
}

function Test-DevOpsSummaryPassed {
    # 通過：「總結：通過」可接（附註）。不通過但 P0、P1 都是 0 也放行——只修 P1 政策，P2 列已知限制（hd5-review）。
    param([string]$Line)
    $s = $Line -replace '^總結[:：]\s*', ''
    if ($s -match '^通過\s*([（(].*)?$') { return $true }
    if ($s -match '^不通過') {
        $p0 = [regex]::Match($s, 'P0\s*[×xX]?\s*(\d+)'); $p1 = [regex]::Match($s, 'P1\s*[×xX]?\s*(\d+)')
        return ($p0.Success -and $p1.Success -and [int]$p0.Groups[1].Value -eq 0 -and [int]$p1.Groups[1].Value -eq 0)
    }
    return $false
}

function Test-DevOpsAcceptanceGate {
    # -VerifyRoot 預設＝CasePath 往上兩層（<AI_Service>/spec/<案名> → <AI_Service>）的 verify/
    # -VerifyLibPath：功能地圖檢查器 _verify-map-lib.ps1 的路徑，呼叫端已 dot-source。空的或檔案不存在 ⇒ fail closed。
    param([string]$CasePath, [string]$VerifyRoot, [string]$VerifyLibPath, [string[]]$VerifyLibSearched)
    $reasons = @(); $details = @(); $onsiteLatest = $null
    $qa = [IO.Path]::Combine([string]$CasePath, 'qa')   # Join-Path 遇到不存在的磁碟機會直接拋錯
    if ([string]::IsNullOrWhiteSpace($CasePath) -or -not (Test-Path -LiteralPath $qa)) {
        return [pscustomobject]@{ Passed = $false; Reasons = @("找不到 $qa（-CasePath 要指到 <AI_Service>/spec/<案名>）"); Details = @() }
    }
    $checks = @(
        # 檔名是契約：只認 qa/ 根目錄，允許 _{案號或任意}_ 中綴；.raw.md、子目錄不認（hd5-review 第五節）
        @{ Name = '獨立驗收'; Pattern = '^(Codex|Claude)驗收結果_(?:[^\\/]+_)?R(?<n>\d+)(?<b>[a-z])?\.md$'; Hint = 'hd5-review' },
        @{ Name = '站上關卡'; Pattern = '^onsite-gate_(?:[^\\/]+_)?R(?<n>\d+)(?<b>[a-z])?\.md$'; Hint = 'hd5-onsite-gate' }
    )
    foreach ($c in $checks) {
        $latest = Get-DevOpsLatestRoundFile -Dir $qa -Pattern $c.Pattern
        if ($null -eq $latest) {
            $qaFull = (Get-Item -LiteralPath $qa).FullName
            $nested = @(Get-ChildItem -LiteralPath $qa -File -Recurse | Where-Object { $_.DirectoryName -ne $qaFull -and $_.Name -match $c.Pattern } |
                ForEach-Object { $_.FullName.Substring($qaFull.Length + 1) })
            $hint = if ($nested.Count) { "；子目錄有 $($nested -join '、')，請把結果檔放到 qa/ 根目錄" } else { '' }
            $reasons += "缺$($c.Name)結果檔（qa/ 根目錄找不到，見 $($c.Hint) skill$hint）"; continue
        }
        $last = Get-DevOpsSummaryLine -Path $latest.File.FullName
        $shown = if ($last) { $last } else { '（找不到總結行）' }
        $details += "$($c.Name)：$($latest.File.Name)「$shown」"
        if (-not (Test-DevOpsSummaryPassed $last)) {
            $next = if ($last -match '^總結[:：]\s*受阻') { "；受阻＝補齊缺的東西後重送同一輪（R$($latest.Round)b…），不算一次不通過" } else { '' }
            $reasons += "$($c.Name)最新一輪 R$($latest.Tag)（$($latest.File.Name)）未通過：「$shown」$next"
        }
        if ($c.Name -eq '站上關卡') { $onsiteLatest = $latest }
    }

    # 功能地圖：檢查器找不到就 fail closed（不放行），不要因為工具沒裝而默默略過
    $libOk = (-not [string]::IsNullOrWhiteSpace($VerifyLibPath)) -and (Test-Path -LiteralPath $VerifyLibPath -PathType Leaf) -and
             [bool](Get-Command Test-VerifyMap -ErrorAction SilentlyContinue) -and [bool](Get-Command Test-OnsiteGateEvidence -ErrorAction SilentlyContinue)
    if (-not $libOk) {
        $where = if (@($VerifyLibSearched).Count) { "（找過：$(@($VerifyLibSearched) -join '、')）" } else { '' }
        $reasons += "功能地圖：找不到功能地圖檢查工具 _verify-map-lib.ps1$where，工單閘不放行（fail closed）。用 -ToolsDir 指到 HD5 工具資料夾，或確認 .claude/workflow.json 的 paths.tools"
        return [pscustomobject]@{ Passed = $false; Reasons = $reasons; Details = $details }
    }
    if ([string]::IsNullOrWhiteSpace($VerifyRoot)) {
        $VerifyRoot = [IO.Path]::GetFullPath([IO.Path]::Combine([string]$CasePath, '..', '..', 'verify'))
    }
    $map = Test-VerifyMap -VerifyRoot $VerifyRoot
    if (-not $map.Passed) { $reasons += @($map.Reasons | ForEach-Object { "功能地圖：$_" }) }
    else { $details += "功能地圖：$($map.FeatureIds.Count) 個功能（$($map.FeatureIds -join '、')）" }
    if ($onsiteLatest -and $map.Passed) {
        $ev = Test-OnsiteGateEvidence -Path $onsiteLatest.File.FullName -FeatureIds $map.FeatureIds -Round $onsiteLatest.Round -RoundTag $onsiteLatest.Tag
        if ($ev.Legacy) { $details += "站上關卡證據：$($onsiteLatest.File.Name) 日期早於新格式生效日，未檢查功能編號與證據檔" }
        elseif (-not $ev.Passed) { $reasons += @($ev.Reasons | ForEach-Object { "站上關卡證據：$_" }) }
        else { $details += '站上關卡證據：每條都對到功能地圖、Pass 都有證據' }
    }
    return [pscustomobject]@{ Passed = ($reasons.Count -eq 0); Reasons = $reasons; Details = $details }
}

# 入口腳本共用的「過閘」流程：印結果、決定擋不擋。兩支入口（workitem-ops.ps1 改待驗收、upload-case-report.ps1 上傳）都呼叫這支。
#   -SkipReason 非空白 ⇒ 略過並明講理由；空白（含全是空格）不算理由。
#   -Preview ⇒ 預覽模式：閘沒過只印紅字「正式執行會被擋」，不拋錯。
#   -PreviewToleratesMissingCase ⇒ 預覽時缺 -CasePath 也只警告（上傳預覽用）；沒給這個開關時缺 -CasePath 一律擋。
#   -ActionLabel ⇒ 訊息裡的動作名，例「改成「待驗收」」「上傳結案報告」。
# 回傳 $true＝通過或略過、$false＝預覽中未通過；正式執行未通過直接 throw。
function Assert-HD5AcceptanceGate {
    param(
        [string]$CasePath,
        [string]$SkipReason,
        [switch]$Preview,
        [switch]$PreviewToleratesMissingCase,
        [string]$ActionLabel = '改狀態',
        [string]$VerifyRoot,
        [string]$VerifyLibPath,
        [string[]]$VerifyLibSearched
    )
    if (-not [string]::IsNullOrWhiteSpace($SkipReason)) {
        Write-Host "⚠ 已略過工單閘（$ActionLabel）：理由「$($SkipReason.Trim())」" -ForegroundColor Yellow
        return $true
    }
    if ([string]::IsNullOrWhiteSpace($CasePath)) {
        $m = "$ActionLabel 前要過工單閘：請給 -CasePath <AI_Service/spec/<案名>>，腳本會檢查獨立驗收與站上關卡最新一輪都是「總結：通過」、功能地圖合格、Pass 有證據。" +
             "沒有案子（例：緊急修正）且使用者同意略過時，改用 -SkipAcceptanceGate '<理由>'（理由不可空白）。"
        if ($Preview -and $PreviewToleratesMissingCase) { Write-Host "❌ 工單閘（正式執行會被擋）：$m" -ForegroundColor Red; return $false }
        throw $m
    }
    $gate = Test-DevOpsAcceptanceGate -CasePath $CasePath -VerifyRoot $VerifyRoot -VerifyLibPath $VerifyLibPath -VerifyLibSearched $VerifyLibSearched
    foreach ($d in $gate.Details) { Write-Host "  工單閘｜$d" }
    if (-not $gate.Passed) {
        $why = $gate.Reasons -join '；'
        if ($Preview) { Write-Host "❌ 工單閘未通過（正式執行會被擋）：$why" -ForegroundColor Red; return $false }
        throw "工單閘未通過，不$($ActionLabel)：$why"
    }
    Write-Host '  工單閘｜通過（另請人工核對：站上關卡報告的部署 commit 跟現在站上一致、留言稿列出全部「未驗證」項目）' -ForegroundColor Green
    return $true
}
