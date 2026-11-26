# 功能地圖（verify 文件）檢查器——由工單閘、站上關卡、開工檢查共用。規範：hd5-verify skill
#
#   Test-VerifyMap -VerifyRoot <AI_Service/verify>
#     → { Passed; Reasons[]; FeatureIds[]; VerifyDoc }
#   Test-OnsiteGateEvidence -Path <qa/onsite-gate_R{n}.md> -FeatureIds <ids> [-Round n]
#     → { Passed; Reasons[]; Legacy }
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

function Test-OnsiteGateEvidence {
    # A 表（驗收項目）每一列：功能欄要對到功能地圖編號；Pass 要有證據，證據檔要真的存在。
    param([string]$Path, [string[]]$FeatureIds, [int]$Round = -1, [string]$RoundTag = '')
    $reasons = @()
    $lines = @(Get-Content -LiteralPath $Path -Encoding UTF8)
    $dateLine = @($lines | Where-Object { $_ -match '日期[:：]\s*(\d{4}-\d{2}-\d{2})' } | Select-Object -First 1)
    if ($dateLine) {
        $null = $dateLine[0] -match '日期[:：]\s*(\d{4}-\d{2}-\d{2})'
        if ([datetime]$Matches[1] -lt $script:OnsiteEvidenceCutover) {
            return [pscustomobject]@{ Passed = $true; Reasons = @(); Legacy = $true }
        }
    }
    # 找 A 表：## A. 之後第一個表格
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^##\s*A[.．、\s]') { $start = $i; break } }
    if ($start -lt 0) { return [pscustomobject]@{ Passed = $false; Reasons = @('站上關卡報告找不到「## A. 驗收項目」表（格式見 hd5-onsite-gate skill §六）'); Legacy = $false } }
    $hdr = -1
    for ($i = $start + 1; $i -lt $lines.Count -and $lines[$i] -notmatch '^##\s'; $i++) { if ($lines[$i].Trim().StartsWith('|')) { $hdr = $i; break } }
    if ($hdr -lt 0) { return [pscustomobject]@{ Passed = $false; Reasons = @('「## A. 驗收項目」底下沒有表格'); Legacy = $false } }
    $cols = Split-VerifyTableRow $lines[$hdr]
    $ci = @{}
    for ($k = 0; $k -lt $cols.Count; $k++) {
        foreach ($name in '項目', '功能', '結果', '證據', '備註') { if ($cols[$k] -match "^$name" -and -not $ci.ContainsKey($name)) { $ci[$name] = $k } }
    }
    foreach ($need in '功能', '結果', '證據') {
        if (-not $ci.ContainsKey($need)) { $reasons += "A 表缺「$need」欄（新格式：| 項目 | 功能 | 結果 | 證據 | 備註 |，見 hd5-onsite-gate skill §六）" }
    }
    if ($reasons.Count) { return [pscustomobject]@{ Passed = $false; Reasons = $reasons; Legacy = $false } }

    $qa = Split-Path -Parent $Path
    $evDirs = @($qa)
    if ($RoundTag) { $evDirs = @((Join-Path $qa "onsite-gate_R$RoundTag"), $qa) }
    elseif ($Round -ge 0) { $evDirs = @((Join-Path $qa "onsite-gate_R$Round"), $qa) }
    else {
        $m = [regex]::Match((Split-Path -Leaf $Path), 'R(\d+)[a-z]?\.md$')
        if ($m.Success) { $evDirs = @((Join-Path $qa ([IO.Path]::GetFileNameWithoutExtension((Split-Path -Leaf $Path)))), $qa) }
    }
    $rows = 0
    for ($i = $hdr + 1; $i -lt $lines.Count; $i++) {
        $l = $lines[$i]
        if (-not $l.Trim().StartsWith('|')) { break }
        if ($l -match '^\s*\|[\s:\-|]+\|\s*$') { continue }   # 分隔列
        $c = Split-VerifyTableRow $l
        $rows++
        $item = if ($ci.ContainsKey('項目')) { $c[$ci['項目']] } else { "第 $rows 列" }
        $res = [string]$c[$ci['結果']]
        $feat = [string]$c[$ci['功能']]
        $ev = [string]$c[$ci['證據']]
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
    if ($rows -eq 0) { $reasons += 'A 表沒有任何驗收項目' }
    return [pscustomobject]@{ Passed = ($reasons.Count -eq 0); Reasons = $reasons; Legacy = $false }
}
