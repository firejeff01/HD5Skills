# 功能地圖（verify 文件）檢查器——由工單閘、站上關卡、開工檢查共用。規範：hd5-verify skill
#
#   Test-VerifyMap -VerifyRoot <AI_Service/verify>
#     → { Passed; Reasons[]; FeatureIds[]; VerifyDoc }
#   Test-OnsiteGateEvidence -Path <qa/onsite-gate_R{n}.md> -FeatureIds <ids> [-Round n]
#     → { Passed; Reasons[]; Legacy; Warnings[]（只提醒、不影響 Passed） }
#
# 方法出自 Lauren Tan（poteto）的 create-verification-skill：專案要有一份「下一個代理冷啟動就能照做」的
# 驗證文件（6 節）＋功能地圖（每個使用者可見功能一檔、固定 4 節）。本檔只檢查「形狀」，內容對不對由實跑證明。

$script:VerifyDocSections = @(
    @{ Key = 'Launch';   Label = '啟動（Launch）' },
    @{ Key = 'Doctor';   Label = '體檢（Doctor）' },
    @{ Key = 'Drive';    Label = '操作（Drive）' },
    @{ Key = 'Evidence'; Label = '證據（Evidence）' },
    @{ Key = 'Cleanup';  Label = '清理（Cleanup）' },
    @{ Key = 'Helpers';  Label = '工具腳本（Helpers）' }
)
$script:FeatureSections = @(
    @{ Key = 'Sub-features';     Label = '子功能（Sub-features）' },
    @{ Key = 'How to get to it'; Label = '使用者怎麼到達（How to get to it）' },
    @{ Key = 'Driving it';       Label = '怎麼操作（Driving it）' },
    @{ Key = 'Gotchas';          Label = '地雷（Gotchas）' }
)
$script:VerifyMinFeatures = 3
# 佔位符：留著就代表沒寫完（create-verification-skill：不可留 placeholder）
$script:VerifyPlaceholder = '(?i)\bTODO\b|\bTBD\b|待補|待填|<填[^>]*>|\{\{[^}]+\}\}'
# {{…}} 在反引號行內碼與 ``` ／ ~~~ 程式碼區塊內是合法內容（docker --format "{{.Name}}"、Go template、Handlebars），不算佔位符；
# 區塊外仍算。其他佔位符（TODO／待補…）不論在不在程式碼裡都算（11-23 導入實測）
$script:VerifyCurly = '\{\{[^}]+\}\}'

function Get-VerifyPlaceholderLines {
    # 回傳有佔位符的行號（1 起算）
    param([string[]]$Lines)
    $out = @(); $inFence = $false; $n = 0
    foreach ($raw in $Lines) {
        $n++
        $l = [string]$raw
        if ($l -match '^\s*(```|~~~)') { $inFence = -not $inFence; if (($l -replace $script:VerifyCurly, '') -match $script:VerifyPlaceholder) { $out += $n }; continue }
        if ($inFence) { $t = $l -replace $script:VerifyCurly, '' }
        else { $t = [regex]::Replace($l, '(`+)(.+?)\1', [Text.RegularExpressions.MatchEvaluator] { param($m) $m.Value -replace '\{\{[^}]+\}\}', '' }) }
        if ($t -match $script:VerifyPlaceholder) { $out += $n }
    }
    return $out   # 呼叫端用 @() 包；不用「, $out」——空陣列會變成一個元素
}
# 證據檔副檔名
$script:EvidenceExt = 'png|jpe?g|gif|webp|webm|mp4|json|txt|log|md|html?|har|zip|xlsx|csv|pdf|trx'
# 新格式生效日：日期早於此的站上關卡報告視為舊格式，不檢查功能編號與證據檔（不回溯）
$script:OnsiteEvidenceCutover = [datetime]'2026-11-23'

function Get-VerifyMdSections {
    # 回傳 H2 清單：{ Title; Body[] }（只取 ## 開頭；### 以下算內文）
    param([string[]]$Lines)
    $out = @(); $cur = $null
    $inFence = $false
    foreach ($raw in $Lines) {
        $l = [string]$raw
        if ($l -match '^\s*```') { $inFence = -not $inFence }
        if (-not $inFence -and $l -match '^##\s+(?<t>.+?)\s*$' -and $l -notmatch '^###') {
            if ($cur) { $out += $cur }
            $cur = [pscustomobject]@{ Title = $Matches['t']; Body = [System.Collections.Generic.List[string]]::new() }
            continue
        }
        if ($cur) { $cur.Body.Add($l) }
    }
    if ($cur) { $out += $cur }
    return , $out
}

function Test-VerifySectionsInOrder {
    # 檢查 H2 是否「恰好」依序是 $Spec（標題含英文關鍵字即可，中文可自由寫），且每節有內容
    param([object[]]$Sections, [object[]]$Spec, [string]$Where, [switch]$AllowExtra)
    $reasons = @()
    $titles = @($Sections | ForEach-Object { $_.Title })
    $hit = @()
    foreach ($s in $Spec) {
        $idx = -1
        for ($i = 0; $i -lt $titles.Count; $i++) { if ($titles[$i] -match [regex]::Escape($s.Key)) { $idx = $i; break } }
        if ($idx -lt 0) { $reasons += "$Where 缺「## $($s.Label)」"; continue }
        $hit += [pscustomobject]@{ Key = $s.Key; Index = $idx }
        $body = @($Sections[$idx].Body | Where-Object { $_.Trim() -ne '' })
        if ($body.Count -eq 0) { $reasons += "$Where「$($s.Label)」是空的" }
    }
    for ($i = 1; $i -lt $hit.Count; $i++) {
        if ($hit[$i].Index -lt $hit[$i - 1].Index) { $reasons += "$Where 小節順序要是：$(($Spec | ForEach-Object { $_.Key }) -join ' → ')"; break }
    }
    if (-not $AllowExtra -and $titles.Count -ne $Spec.Count -and $reasons.Count -eq 0) {
        $reasons += "$Where 要恰好 $($Spec.Count) 個 ## 小節（現在 $($titles.Count) 個：$($titles -join '、')）；補充說明請用 ###"
    }
    return , $reasons
}

function Test-VerifyMap {
    param([string]$VerifyRoot)
    $reasons = @(); $ids = @(); $doc = $null
    $hint = '請先依 hd5-verify skill 建立功能地圖'
    if ([string]::IsNullOrWhiteSpace($VerifyRoot) -or -not (Test-Path -LiteralPath $VerifyRoot -PathType Container)) {
        return [pscustomobject]@{ Passed = $false; Reasons = @("這個專案還沒有功能地圖：找不到 $VerifyRoot。$hint"); FeatureIds = @(); VerifyDoc = $null }
    }
    $docs = @(Get-ChildItem -LiteralPath $VerifyRoot -File -Filter 'verify-*.md')
    if ($docs.Count -ne 1) {
        $reasons += "verify/ 根目錄要有恰好一份 verify-<app>.md（現在 $($docs.Count) 份）。$hint"
    } else {
        $doc = $docs[0]
        $lines = @(Get-Content -LiteralPath $doc.FullName -Encoding UTF8)
        $reasons += Test-VerifySectionsInOrder -Sections (Get-VerifyMdSections $lines) -Spec $script:VerifyDocSections -Where $doc.Name -AllowExtra
        $ph = @(Get-VerifyPlaceholderLines $lines)
        if ($ph.Count) { $reasons += "$($doc.Name) 還有佔位符（第 $(($ph | Select-Object -First 3) -join '、') 行）" }
    }
    $fdir = Join-Path $VerifyRoot 'features'
    if (-not (Test-Path -LiteralPath (Join-Path $fdir 'README.md'))) {
        $reasons += "缺 verify/features/README.md（共同前提、操作慣例、證據格式）。$hint"
    }
    $files = @(Get-ChildItem -LiteralPath $fdir -File -Filter '*.md' -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'README.md' } | Sort-Object Name)
    if ($files.Count -lt $script:VerifyMinFeatures) {
        $reasons += "功能地圖至少要 $($script:VerifyMinFeatures) 個功能檔（verify/features/*.md，現在 $($files.Count) 個）。$hint"
    }
    foreach ($f in $files) {
        $id = [IO.Path]::GetFileNameWithoutExtension($f.Name)
        if ($id -notmatch '^[a-z0-9][a-z0-9-]*$') { $reasons += "功能檔名 $($f.Name) 要是小寫英數與連字號（檔名就是功能編號）"; continue }
        $ids += $id
        $lines = @(Get-Content -LiteralPath $f.FullName -Encoding UTF8)
        $first = @($lines | Where-Object { $_.Trim() -ne '' } | Select-Object -First 1)
        if (-not $first -or $first[0] -notmatch '^#\s+\S') { $reasons += "features/$($f.Name) 第一行要是 # 標題" }
        $secs = Get-VerifyMdSections $lines
        $reasons += Test-VerifySectionsInOrder -Sections $secs -Spec $script:FeatureSections -Where "features/$($f.Name)"
        $drive = @($secs | Where-Object { $_.Title -match 'Driving it' } | Select-Object -First 1)
        if ($drive) {
            $firstBody = @($drive[0].Body | Where-Object { $_.Trim() -ne '' } | Select-Object -First 1)
            if ($firstBody -and $firstBody[0] -notmatch '^\s*(前提|Preconditions)[:：]') { $reasons += "features/$($f.Name)「怎麼操作」第一行要以「前提：」開頭" }
        }
        $ph = @(Get-VerifyPlaceholderLines $lines)
        if ($ph.Count) { $reasons += "features/$($f.Name) 還有佔位符（第 $(($ph | Select-Object -First 3) -join '、') 行）" }
    }
    return [pscustomobject]@{ Passed = ($reasons.Count -eq 0); Reasons = $reasons; FeatureIds = $ids; VerifyDoc = $doc }
}

function Split-VerifyTableRow {
    param([string]$Line)
    $t = $Line.Trim()
    if ($t.StartsWith('|')) { $t = $t.Substring(1) }
    if ($t.EndsWith('|')) { $t = $t.Substring(0, $t.Length - 1) }
    return , @($t -split '\|' | ForEach-Object { $_.Trim() })
}


# ── 驗收退回後的規則（2026-11-25，#2164 送驗 5 次退回 4 次的檢討）──────────────────────────
# 站上關卡報告日期早於此日不檢查下列三條（不回溯；已送出的報告不重判）
$script:OnsiteReworkCutover = [datetime]'2026-11-25'

function Get-VerifyMdTables {
    # 回傳 markdown 表格清單：{ Header[]; Rows[][]; Line（表頭行號，1 起算） }；程式碼區塊內的不算
    param([string[]]$Lines)
    $out = @(); $inFence = $false; $cur = $null
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $l = [string]$Lines[$i]
        if ($l -match '^\s*(```|~~~)') { $inFence = -not $inFence; if ($cur) { $out += $cur; $cur = $null }; continue }
        $isRow = (-not $inFence) -and $l.Trim().StartsWith('|')
        if (-not $isRow) { if ($cur) { $out += $cur; $cur = $null }; continue }
        if ($l -match '^\s*\|[\s:\-|]+\|\s*$') { continue }   # 分隔列
        if (-not $cur) { $cur = [pscustomobject]@{ Header = (Split-VerifyTableRow $l); Rows = [System.Collections.Generic.List[object]]::new(); Line = $i + 1 }; continue }
        $cur.Rows.Add((Split-VerifyTableRow $l))
    }
    if ($cur) { $out += $cur }
    return , $out
}

function Find-VerifyColumn {
    # 表頭裡第一個符合 $Pattern 的欄位索引；沒有回 -1
    param([string[]]$Header, [string]$Pattern)
    for ($k = 0; $k -lt $Header.Count; $k++) { if ($Header[$k] -match $Pattern) { return $k } }
    return -1
}

function Get-ReworkLog {
    # qa/rework-log.md 的退回表（hd5-workflow「驗收退回之後」）：表頭要有「輪次」與「處理類別」欄。
    #   → { Found; Rows[]: { Round; Year; Month; Day; Category; RootCause（「根因類別」欄，沒有這欄＝空字串）; Text } }
    # 輪次欄寫 R{k}，可接日期：R3（11/24）、R3（2026-11-24）；同一輪的續行可只寫 R3 或留空（沿用上一列的輪次）。
    param([string]$Path)
    $rows = @()
    if (-not (Test-Path -LiteralPath $Path)) { return [pscustomobject]@{ Found = $false; Rows = @() } }
    $tables = Get-VerifyMdTables @(Get-Content -LiteralPath $Path -Encoding UTF8)
    $t = $tables | Where-Object { (Find-VerifyColumn $_.Header '^輪次') -ge 0 -and (Find-VerifyColumn $_.Header '處理類別') -ge 0 } | Select-Object -First 1
    if (-not $t) { return [pscustomobject]@{ Found = $false; Rows = @() } }
    $ri = Find-VerifyColumn $t.Header '^輪次'; $ki = Find-VerifyColumn $t.Header '處理類別'; $rci = Find-VerifyColumn $t.Header '根因類別'
    $last = 0
    foreach ($c in $t.Rows) {
        $cell = if ($ri -lt $c.Count) { [string]$c[$ri] } else { '' }
        $m = [regex]::Match($cell, 'R\s*(\d+)')
        $round = if ($m.Success) { [int]$m.Groups[1].Value } else { $last }
        if ($round -le 0) { continue }
        $last = $round
        $y = 0; $mo = 0; $d = 0
        $dm = [regex]::Match($cell, '(?:(\d{4})[-/])?(\d{1,2})[-/](\d{1,2})')
        if ($dm.Success) { if ($dm.Groups[1].Success) { $y = [int]$dm.Groups[1].Value }; $mo = [int]$dm.Groups[2].Value; $d = [int]$dm.Groups[3].Value }
        $rows += [pscustomobject]@{ Round = $round; Year = $y; Month = $mo; Day = $d; Category = $(if ($ki -lt $c.Count) { [string]$c[$ki] } else { '' }); RootCause = $(if ($rci -ge 0 -and $rci -lt $c.Count) { ([string]$c[$rci]).Trim() } else { '' }); Text = ($c -join ' | ') }
    }
    return [pscustomobject]@{ Found = $true; Rows = $rows }
}

function Get-ExternalSamples {
    # sa/external-samples.md 的樣本對照表（hd5-grill 第三節第九分支）：表頭要有「變化」與「真實樣本」欄。
    #   → { Found（有樣本表）; Rows[]: { Name; Sample; Problem（$null＝合格） } }
    # 「真實樣本」合格＝非空且不是佔位符；寫「待提供」要接（誰），例：待提供（PM 黃）。
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return [pscustomobject]@{ Found = $false; Rows = @() } }
    $tables = Get-VerifyMdTables @(Get-Content -LiteralPath $Path -Encoding UTF8)
    $t = $tables | Where-Object { (Find-VerifyColumn $_.Header '^變化') -ge 0 -and (Find-VerifyColumn $_.Header '真實樣本') -ge 0 } | Select-Object -First 1
    if (-not $t) { return [pscustomobject]@{ Found = $false; Rows = @() } }
    $ni = Find-VerifyColumn $t.Header '^變化'; $si = Find-VerifyColumn $t.Header '真實樣本'
    $rows = @()
    foreach ($c in $t.Rows) {
        $name = if ($ni -lt $c.Count) { ([string]$c[$ni]).Replace('`', '').Replace('**', '').Trim() } else { '' }
        if (-not $name -or $name -match '^[—\-–]+$') { continue }
        $s = if ($si -lt $c.Count) { ([string]$c[$si]).Replace('`', '').Trim() } else { '' }
        $problem = $null
        if ($s -eq '' -or $s -match '^[—\-–]+$') { $problem = '「真實樣本」是空的' }
        elseif ($s -match '^待提供') { if ($s -notmatch '^待提供\s*[（(]\s*[^）)\s][^）)]*[）)]') { $problem = '寫了「待提供」但沒寫誰提供（要寫成「待提供（誰）」）' } }
        elseif ($s -match $script:VerifyPlaceholder) { $problem = '「真實樣本」是佔位符' }
        $rows += [pscustomobject]@{ Name = $name; Sample = $s; Problem = $problem }
    }
    return [pscustomobject]@{ Found = $true; Rows = $rows }
}

function Get-OnsiteGateRoundKey {
    # onsite-gate_R{n}[字母].md → { Round = n; Suffix = 字母 }；不是這個檔名格式回 $null
    param([string]$FileName)
    $m = [regex]::Match($FileName, '^onsite-gate_R(\d+)([a-z]?)\.md$', 'IgnoreCase')
    if (-not $m.Success) { return $null }
    return [pscustomobject]@{ Round = [int]$m.Groups[1].Value; Suffix = $m.Groups[2].Value.ToLowerInvariant() }
}

function Get-OnsiteItemKey {
    # 跨輪比對同一項：項目欄開頭是 AC-9、R3-01 這類編號就比編號，否則比整格（去空白）
    param([string]$Item)
    $t = ([string]$Item).Replace('**', '').Trim()
    $first = @($t -split '[\s、，,：:（(]+' | Where-Object { $_ })
    if ($first.Count -and $first[0] -match '^[A-Za-z][A-Za-z0-9.]*-?\d[\w.-]*$') { return $first[0].ToUpperInvariant() }
    return ($t -replace '\s+', '')
}

function Get-OnsiteATable {
    # 站上關卡報告的 A 表（## A. 之後第一個表格）→ { Error（$null＝找到）; Ci（欄名→索引）; Rows[]: { Cells; Item; Result; Feature; Evidence; Raw } }
    param([string[]]$Lines)
    $start = -1
    for ($i = 0; $i -lt $Lines.Count; $i++) { if ($Lines[$i] -match '^##\s*A[.．、\s]') { $start = $i; break } }
    if ($start -lt 0) { return [pscustomobject]@{ Error = '站上關卡報告找不到「## A. 驗收項目」表（格式見 hd5-onsite-gate skill §六）'; Ci = @{}; Rows = @() } }
    $hdr = -1
    for ($i = $start + 1; $i -lt $Lines.Count -and $Lines[$i] -notmatch '^##\s'; $i++) { if ($Lines[$i].Trim().StartsWith('|')) { $hdr = $i; break } }
    if ($hdr -lt 0) { return [pscustomobject]@{ Error = '「## A. 驗收項目」底下沒有表格'; Ci = @{}; Rows = @() } }
    $cols = Split-VerifyTableRow $Lines[$hdr]
    $ci = @{}
    for ($k = 0; $k -lt $cols.Count; $k++) {
        foreach ($name in '項目', '功能', '結果', '證據', '備註') { if ($cols[$k] -match "^$name" -and -not $ci.ContainsKey($name)) { $ci[$name] = $k } }
    }
    $cell = { param($c, $n) if ($ci.ContainsKey($n) -and $ci[$n] -lt $c.Count) { [string]$c[$ci[$n]] } else { '' } }
    $rows = @(); $n = 0
    for ($i = $hdr + 1; $i -lt $Lines.Count; $i++) {
        $l = $Lines[$i]
        if (-not $l.Trim().StartsWith('|')) { break }
        if ($l -match '^\s*\|[\s:\-|]+\|\s*$') { continue }   # 分隔列
        $c = Split-VerifyTableRow $l
        $n++
        $item = if ($ci.ContainsKey('項目')) { & $cell $c '項目' } else { "第 $n 列" }
        $rows += [pscustomobject]@{ Cells = $c; Item = $item; Result = (& $cell $c '結果'); Feature = (& $cell $c '功能'); Evidence = (& $cell $c '證據'); Raw = $l }
    }
    return [pscustomobject]@{ Error = $null; Ci = $ci; Rows = $rows }
}

function Test-OnsiteReworkRules {
    # 驗收退回之後的兩條提醒（2026-11-25，#2164）。回傳**警告**清單，不影響 Passed（使用者 11-25 拍板：需求溝通與人工步驟只提醒、不擋；
    # 擋了容易被敷衍或繞過，真正的防線在產品程式層的測試）。
    #   1. 新打通：qa/rework-log.md 最新一輪退回 R{k} 的日期 ≤ 本關卡日期（沒寫日期＝保守視為在關卡之前）⇒
    #      A 表要有一列標「（新打通）」，或報告有一行「新打通：無（理由）」。
    #   2. 待使用者動作連兩輪：A 表某列結果是「未驗證（待使用者動作…）」，而上一輪關卡（輪次比本輪小的最大一輪，
    #      有 R{m}b 就取 R{m}b）同一項也是 ⇒ 警告，報告有一行「使用者放行：<項目>…（MM-DD）」就不提醒。
    #      同一項＝項目欄開頭的編號（AC-9 這類）相同；沒有編號就比整格（去空白）。
    param([string[]]$Lines, [object[]]$ARows, [string]$QaDir, [string]$CaseDir, [string]$GateFile, $GateDate)
    $warns = @()

    $rw = Get-ReworkLog -Path (Join-Path $QaDir 'rework-log.md')
    if ($rw.Found -and @($rw.Rows).Count) {
        $k = (@($rw.Rows) | Measure-Object -Property Round -Maximum).Maximum
        $dated = @($rw.Rows | Where-Object { $_.Round -eq $k -and $_.Month -gt 0 } | Select-Object -First 1)
        $after = $true
        if ($dated.Count -and $GateDate) {
            $y = if ($dated[0].Year) { $dated[0].Year } else { $GateDate.Year }
            $rd = $null; try { $rd = [datetime]::new($y, $dated[0].Month, $dated[0].Day) } catch { }
            if ($rd -and -not $dated[0].Year -and $rd -gt $GateDate.AddDays(180)) { $rd = $rd.AddYears(-1) }   # 跨年：12/30 退回、01/02 關卡
            if ($rd -and $rd -gt $GateDate.Date) { $after = $false }
        }
        if ($after) {
            $hasNew = @($ARows | Where-Object { $_.Raw -match '[（(]\s*新打通\s*[)）]' }).Count -gt 0
            $none = @($Lines | Where-Object { $_ -match '^\s*[-*>]*\s*\**新打通\**\s*[:：]\s*無\s*[（(]\s*[^）)\s][^）)]*[）)]' }).Count -gt 0
            if (-not $hasNew -and -not $none) {
                $warns += "新打通：qa/rework-log.md 最新一輪退回是 R$k，本輪關卡在那之後，A 表沒有標「（新打通）」的列，也沒有「新打通：無（理由）」。修好後才跑得通的後段流程，請用當初失敗的那筆資料走到最終結果（hd5-onsite-gate 第四節）。過渡：專案有自動化端到端回歸測試涵蓋該流程時可移除"
            }
        }
    }

    $waitPat = '未驗證\s*[（(]\s*待使用者動作'
    $cur = Get-OnsiteGateRoundKey $GateFile
    if ($cur -and @($ARows | Where-Object { $_.Result -match $waitPat }).Count) {
        $prev = @(Get-ChildItem -LiteralPath $QaDir -Filter 'onsite-gate_R*.md' -File -ErrorAction SilentlyContinue | ForEach-Object {
                $pk = Get-OnsiteGateRoundKey $_.Name
                if ($pk -and $pk.Round -lt $cur.Round) { [pscustomobject]@{ File = $_; Round = $pk.Round; Suffix = $pk.Suffix } }
            } | Sort-Object Round, Suffix | Select-Object -Last 1)
        if ($prev.Count) {
            $pt = Get-OnsiteATable @(Get-Content -LiteralPath $prev[0].File.FullName -Encoding UTF8)
            if (-not $pt.Error -and $pt.Ci.ContainsKey('結果')) {
                $prevWait = @{}
                foreach ($row in $pt.Rows) { if ($row.Result -match $waitPat) { $prevWait[(Get-OnsiteItemKey $row.Item)] = $true } }
                $releases = @(foreach ($l in $Lines) {
                        $m = [regex]::Match($l, '使用者放行\s*[:：]\s*(.+?)[（(]\s*(?:\d{4}[-/])?\d{1,2}[-/]\d{1,2}\s*[)）]')
                        if ($m.Success) { ($m.Groups[1].Value -replace '\s+', '').ToUpperInvariant() }
                    })
                foreach ($row in $ARows) {
                    if ($row.Result -notmatch $waitPat) { continue }
                    $key = Get-OnsiteItemKey $row.Item
                    if (-not $prevWait.ContainsKey($key)) { continue }
                    $kk = ($key -replace '\s+', '').ToUpperInvariant()
                    $released = $false
                    foreach ($rl in $releases) { if ($rl.Contains($kk)) { $released = $true; break } }
                    if (-not $released) {
                        $warns += "待使用者動作：「$($row.Item)」上一輪（$($prev[0].File.Name)）已經是「未驗證（待使用者動作）」，這輪又一樣。送驗前請使用者完成並附證據；使用者同意再延一輪就寫一行「使用者放行：$key …（MM-DD）」（hd5-onsite-gate 第七節第 4 項）"
                    }
                }
            }
        }
    }
    return $warns
}

function Test-OnsiteGateEvidence {
    # A 表（驗收項目）每一列：功能欄要對到功能地圖編號；Pass 要有證據，證據檔要真的存在。
    # 2026-11-25 起另提醒退回後的兩條（Test-OnsiteReworkRules → Warnings，不影響 Passed）；工單閘與 verify-map-check -Onsite 都走這裡，判定一致。
    param([string]$Path, [string[]]$FeatureIds, [int]$Round = -1, [string]$RoundTag = '')
    $reasons = @()
    $lines = @(Get-Content -LiteralPath $Path -Encoding UTF8)
    $gateDate = $null
    $dateLine = @($lines | Where-Object { $_ -match '日期[:：]\s*(\d{4}-\d{2}-\d{2})' } | Select-Object -First 1)
    if ($dateLine) {
        $null = $dateLine[0] -match '日期[:：]\s*(\d{4}-\d{2}-\d{2})'
        $gateDate = [datetime]$Matches[1]
        if ($gateDate -lt $script:OnsiteEvidenceCutover) {
            return [pscustomobject]@{ Passed = $true; Reasons = @(); Legacy = $true; Warnings = @() }
        }
    }
    $at = Get-OnsiteATable $lines
    if ($at.Error) { return [pscustomobject]@{ Passed = $false; Reasons = @($at.Error); Legacy = $false; Warnings = @() } }
    $ci = $at.Ci
    foreach ($need in '功能', '結果', '證據') {
        if (-not $ci.ContainsKey($need)) { $reasons += "A 表缺「$need」欄（新格式：| 項目 | 功能 | 結果 | 證據 | 備註 |，見 hd5-onsite-gate skill §六）" }
    }
    if ($reasons.Count) { return [pscustomobject]@{ Passed = $false; Reasons = $reasons; Legacy = $false; Warnings = @() } }

    $qa = Split-Path -Parent $Path
    $evDirs = @($qa)
    if ($RoundTag) { $evDirs = @((Join-Path $qa "onsite-gate_R$RoundTag"), $qa) }
    elseif ($Round -ge 0) { $evDirs = @((Join-Path $qa "onsite-gate_R$Round"), $qa) }
    else {
        $m = [regex]::Match((Split-Path -Leaf $Path), 'R(\d+)[a-z]?\.md$')
        if ($m.Success) { $evDirs = @((Join-Path $qa ([IO.Path]::GetFileNameWithoutExtension((Split-Path -Leaf $Path)))), $qa) }
    }
    foreach ($row in $at.Rows) {
        $item = $row.Item
        $res = [string]$row.Result
        $feat = [string]$row.Feature
        $ev = [string]$row.Evidence
        $isNA = $res -match '不適用'
        $featIds = @($feat -split '[、,，/／\s]+' | Where-Object { $_ -and $_ -notmatch '^[—\-–]+$' })
        if ($featIds.Count -eq 0 -and -not $isNA) {
            $reasons += "「$item」沒有對應功能編號（功能欄填 verify/features/ 的檔名；地圖沒有就先補一個功能檔）"
        }
        foreach ($fid in $featIds) {
            if ($FeatureIds -notcontains $fid) { $reasons += "「$item」對應的功能「$fid」不在功能地圖，請先補 verify/features/$fid.md" }
        }
        if ($res -match '^\s*(\*\*)?Pass') {
            $evTrim = $ev.Trim()
            if ($evTrim -eq '' -or $evTrim -match '^[—\-–]+$') { $reasons += "「$item」標 Pass 但沒有證據"; continue }
            $inline = $evTrim -match '(查詢|SQL|API|HTTP|畫面值|DB)[:：]'
            $filesRef = @([regex]::Matches($evTrim, "[^\s|`、，,()（）]+\.($($script:EvidenceExt))\b", 'IgnoreCase') | ForEach-Object { $_.Value.Trim('`') })
            if ($filesRef.Count -eq 0 -and -not $inline) {
                $reasons += "「$item」標 Pass 但證據欄沒有證據檔名或「查詢：／API：／畫面值：」內容（只寫「OK」「已確認」不算）"
            }
            foreach ($fr in $filesRef) {
                $found = $false
                foreach ($d in $evDirs) { if (Test-Path -LiteralPath (Join-Path $d $fr)) { $found = $true; break } }
                if (-not $found) { $reasons += "「$item」的證據檔 $fr 不存在（要放在 $(Split-Path -Leaf $evDirs[0])/ 或 qa/）" }
            }
        }
    }
    if ($at.Rows.Count -eq 0) { $reasons += 'A 表沒有任何驗收項目' }
    $warnings = @()
    if (-not $gateDate -or $gateDate -ge $script:OnsiteReworkCutover) {
        $warnings = @(Test-OnsiteReworkRules -Lines $lines -ARows $at.Rows -QaDir $qa -CaseDir (Split-Path -Parent $qa) -GateFile (Split-Path -Leaf $Path) -GateDate $gateDate)
    }
    return [pscustomobject]@{ Passed = ($reasons.Count -eq 0); Reasons = $reasons; Legacy = $false; Warnings = $warnings }
}
