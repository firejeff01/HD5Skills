<#
.SYNOPSIS
  代理檔（.claude/agents/*.md）的三方比對合併：以「## 小節」為單位比「基準（上次同步的範本）／新範本／專案現在的檔」。
  install.ps1 -Update 用；純函式，不讀寫檔（測試：tests/agent-merge.tests.ps1）。

  每一節的判定（Norm 後比較：行尾空白、CRLF、節尾空行不算差異）：
    專案＝範本                     ⇒ 不動
    專案沒這節、基準也沒有         ⇒ 範本新加的 ⇒ 插入（接在範本裡前一節的後面）
    專案沒這節、基準有             ⇒ 專案刪掉的 ⇒ 範本沒改就不管；範本改了列衝突
    專案＝基準、範本改了           ⇒ 換成範本
    專案改過、範本＝基準           ⇒ 保留專案的
    專案、範本都跟基準不同         ⇒ 衝突（不動專案，列報告）
    沒有基準（第一次）、內容不同   ⇒ 衝突
    基準有、範本已刪的節           ⇒ 專案沒改過就移除；改過就保留並列備註
  不動的節：受保護的節（「本專案技術架構重點」）；沒有基準時的前言（frontmatter＋第一個 ## 之前的文字，專案常改名、改描述）。
  新基準：每節沒衝突就記範本版本；有衝突就留舊基準（沒有就不記），下次照樣列衝突，直到 -AcceptAgents。
#>

$script:AgentProtectedHeadings = @('本專案技術架構重點')

function Get-AgentNorm([string]$s) {
    if ($null -eq $s) { return $null }
    return ((($s.Replace("`r`n", "`n")) -split "`n" | ForEach-Object { $_.TrimEnd() }) -join "`n").Trim("`n")
}

# 切成 [{ Key; Heading; Text }]：Key '' 是前言；同名的節第二個起 Key 加「#2」；程式碼區塊裡的「## 」不算標題
function Split-AgentSections([string]$text) {
    $lines = $text.Replace("`r`n", "`n") -split "`n"
    $list = [Collections.Generic.List[object]]::new()
    $seen = @{}
    $curKey = ''; $curHead = ''; $buf = [Collections.Generic.List[string]]::new(); $fence = $null
    foreach ($l in $lines) {
        if ($l -match '^\s*(`{3,}|~{3,})') {
            $m = $Matches[1]
            if (-not $fence) { $fence = $m } elseif ($m[0] -eq $fence[0] -and $m.Length -ge $fence.Length) { $fence = $null }
        } elseif (-not $fence -and $l -match '^##\s+(.+?)\s*$') {
            $list.Add([pscustomobject]@{ Key = $curKey; Heading = $curHead; Text = ($buf -join "`n").TrimEnd() })
            $h = $Matches[1]; $seen[$h] = 1 + [int]$seen[$h]
            $curKey = if ($seen[$h] -gt 1) { "$h#$($seen[$h])" } else { $h }; $curHead = $h
            $buf = [Collections.Generic.List[string]]::new()
        }
        $buf.Add($l)
    }
    $list.Add([pscustomobject]@{ Key = $curKey; Heading = $curHead; Text = ($buf -join "`n").TrimEnd() })
    return , $list
}

function Join-AgentSections($sections) {
    return ((@($sections | Where-Object { $_.Text }) | ForEach-Object { $_.Text }) -join "`n`n") + "`n"
}

function Merge-AgentSections {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Project,
        [Parameter(Mandatory)][string]$Template,
        [AllowNull()][string]$Base,
        [switch]$Accept   # 使用者已人工合併完：專案不動，基準整份設成範本
    )
    $secP = Split-AgentSections $Project; $secT = Split-AgentSections $Template
    $hasBase = -not [string]::IsNullOrEmpty($Base)
    $secB = if ($hasBase) { Split-AgentSections $Base } else { $null }
    $map = { param($l) $h = @{}; foreach ($s in $l) { $h[$s.Key] = $s }; $h }
    $Pm = & $map $secP; $Tm = & $map $secT; $Bm = if ($hasBase) { & $map $secB } else { @{} }
    $res = [pscustomobject]@{ Text = $Project; BaseText = $null; Changed = $false; Updated = @(); Added = @(); Removed = @(); Conflicts = @(); Notes = @() }
    if ($Accept) { $res.BaseText = Join-AgentSections $secT; return $res }

    $out = [Collections.Generic.List[object]]::new(); foreach ($s in $secP) { $out.Add($s) }
    $newBase = [Collections.Generic.List[object]]::new()
    $idx = { param($k) for ($i = 0; $i -lt $out.Count; $i++) { if ($out[$i].Key -ceq $k) { return $i } }; return -1 }
    $label = { param($k) if ($k -eq '') { '（前言）' } else { "## $k" } }
    $conflict = { param($k, $why, $b, $p, $t) $res.Conflicts += [pscustomobject]@{ Key = $k; Label = (& $label $k); Reason = $why; Base = $b; Project = $p; Template = $t } }

    for ($ti = 0; $ti -lt $secT.Count; $ti++) {
        $t = $secT[$ti]; $k = $t.Key
        $p = $Pm[$k]; $b = $Bm[$k]
        if ($k -eq '' -and -not $hasBase) { $newBase.Add($t); continue }
        if ($script:AgentProtectedHeadings -contains $t.Heading) { $newBase.Add($t); continue }
        $nt = Get-AgentNorm $t.Text; $np = if ($p) { Get-AgentNorm $p.Text } else { $null }; $nb = if ($b) { Get-AgentNorm $b.Text } else { $null }
        if (-not $p) {
            if ($b) {
                if ($nt -ceq $nb) { $newBase.Add($t) }
                else { & $conflict $k '專案刪掉了這一節，範本後來又改了' $b.Text '' $t.Text; $newBase.Add($b) }
                continue
            }
            if ($k -eq '') { $out.Insert(0, $t) }
            else {
                $at = -1
                for ($j = $ti - 1; $j -ge 0 -and $at -lt 0; $j--) { $at = & $idx $secT[$j].Key }
                if ($at -lt 0) { $at = if ($out.Count -and $out[0].Key -eq '') { 0 } else { -1 } }
                $out.Insert($at + 1, $t)
            }
            $res.Added += (& $label $k); $newBase.Add($t); continue
        }
        if ($np -ceq $nt) { $newBase.Add($t); continue }
        if ($b) {
            if ($np -ceq $nb) { $out[(& $idx $k)] = $t; $res.Updated += (& $label $k); $newBase.Add($t) }
            elseif ($nt -ceq $nb) { $newBase.Add($t) }   # 專案自己改過、範本沒變 ⇒ 保留
            else { & $conflict $k '專案與範本都改過這一節' $b.Text $p.Text $t.Text; $newBase.Add($b) }
        } else {
            $why = if ($hasBase) { '範本新加的一節，專案已有同名的節但內容不同' } else { '沒有基準可比（這個專案第一次做三方比對），內容與範本不同' }
            & $conflict $k $why '' $p.Text $t.Text
        }
    }
    if ($hasBase) {
        foreach ($b in $secB) {
            if ($Tm.ContainsKey($b.Key) -or $b.Key -eq '' -or $script:AgentProtectedHeadings -contains $b.Heading) { continue }
            $p = $Pm[$b.Key]; if (-not $p) { continue }
            if ((Get-AgentNorm $p.Text) -ceq (Get-AgentNorm $b.Text)) { $out.RemoveAt((& $idx $b.Key)); $res.Removed += (& $label $b.Key) }
            else { $res.Notes += "$(& $label $b.Key)：範本已刪除這一節，專案改過，保留" }
        }
    }
    $res.Changed = ($res.Updated.Count + $res.Added.Count + $res.Removed.Count) -gt 0
    if ($res.Changed) { $res.Text = Join-AgentSections $out }
    $res.BaseText = Join-AgentSections $newBase
    return $res
}
