<#
.SYNOPSIS
  把 HD5Skills 工作流裝進一個 repo（任何程式技術）。裝完在 Claude Code 或 Codex 執行 hd5-onboard 掃描專案、產生 AGENTS.md／CLAUDE.md。

.DESCRIPTION
  複製到 <RepoRoot>/<ProjectDir>/（ProjectDir 空＝repo 根；Claude Code 要在這裡啟動）：
    .claude/skills/<skill>/、.agents/skills/<skill>/   HD5Skills 的 skills（Claude 與 Codex 各一份）
    AI_Service/hd5-tools/                             關卡工具與 hook（質詢閘、功能地圖檢查、守衛對帳、grill-gate、main-edit-guard）
    .claude/agents/                                   pm／sa／qa-expert 與實作代理範本（hd5-onboard 會依專案改寫）
    .claude/workflow.json                             通用預設（hd5-onboard 會依掃描結果改）
    AI_Service/hd5-tools/workitem/、hd5-workitem skill  只在 -Tracker azure-devops 時裝（工單工具＋改待驗收前的工單閘）
    .claude/settings.json                             只合併兩支 hook（同 matcher 已有就不加，重跑不重複；一筆都沒加就不寫檔）
    .claude/workflow.json 的 tracker                  -Tracker 時才動：已是同值不寫；否則只改 tracker 那段文字，其他位元組不變
    AI_Service/spec/、AI_Service/verify/              案子與功能地圖的資料夾
  已存在的檔不覆蓋（-Force 才覆蓋）。不產生 AGENTS.md／CLAUDE.md——那是 hd5-onboard 掃描後的工作。
  裝完跑 hook、質詢閘與功能地圖檢查的測試（子程序關 stdin、限時 180 秒）。

  -Update（已導入過的專案更新套件）：只把套件擁有的檔覆蓋成套件版本——.claude/skills/hd5-*、.agents/skills/hd5-*（hd5-workflow／hd5-workitem
  只放 SKILL.md）、<paths.tools>（以專案 workflow.json 為準）底下的工具；工單工具只在專案 tracker.type＝azure-devops（或帶 -Tracker azure-devops）時更新。
  絕不動 AGENTS.md、CLAUDE.md、.claude/agents、workflow.json、settings.json（不合併 hook，只檢查兩支有沒有掛）、spec／verify／onboard、
  PAT 檔（*.local.*、pat*.txt）與使用者自建檔。不刪檔：套件已不含的檔只列出來請人確認。沒導入過就報錯；不能跟 -Force 一起用。

.EXAMPLE
  & ./install.ps1 -RepoRoot D:\work\MyRepo
  & ./install.ps1 -RepoRoot D:\work\MyRepo -ProjectDir src\MyApp
  & ./install.ps1 -RepoRoot D:\work\MyRepo -Tracker azure-devops   （之後才決定用 Azure DevOps，再跑一次補裝即可）
  & ./install.ps1 -RepoRoot D:\work\MyRepo -ProjectDir src\MyApp -Update   （已導入過：套件出新版時只更新 skills 與工具）
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RepoRoot,
    [string]$ProjectDir = '',
    [ValidateSet('none', 'azure-devops')][string]$Tracker = 'none',
    [switch]$Force,
    [switch]$Update,
    [switch]$SkipTests
)
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
if ($Update -and $Force) { throw '-Update 與 -Force 不能同時用：-Update 只覆蓋套件自己的檔（skills、工具），-Force 會連專案的代理、workflow.json 一起覆蓋' }

$kit = $PSScriptRoot
$RepoRoot = [IO.Path]::GetFullPath($RepoRoot)
$top = (& git -C $RepoRoot rev-parse --show-toplevel 2>$null)
if ($LASTEXITCODE -ne 0 -or -not $top) { throw "RepoRoot 不是 git repo：$RepoRoot（先 git init）" }
$ProjectDir = ($ProjectDir -replace '\\', '/').Trim('/')
$prefix = if ($ProjectDir) { "$ProjectDir/" } else { '' }
$proj = if ($ProjectDir) { Join-Path $RepoRoot $ProjectDir } else { $RepoRoot }
New-Item -ItemType Directory -Force $proj | Out-Null
$copied = [Collections.Generic.List[string]]::new(); $skipped = [Collections.Generic.List[string]]::new()

function Copy-One([string]$src, [string]$dst) {
    if ((Test-Path -LiteralPath $dst) -and -not $Force) { $script:skipped.Add($dst.Substring($RepoRoot.Length).TrimStart('\')); return }
    New-Item -ItemType Directory -Force (Split-Path $dst -Parent) | Out-Null
    if ((Get-Item -LiteralPath $src).PSIsContainer) {
        if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Recurse -Force }
        Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force
        Get-ChildItem -LiteralPath $dst -Recurse -File | ForEach-Object { $script:copied.Add($_.FullName) }
    } else { Copy-Item -LiteralPath $src -Destination $dst -Force; $script:copied.Add($dst) }
}

# ── JSON 文字層級最小修改：只動頂層 tracker 那段，其他位元組不變 ──
function Skip-JsonWs([string]$s, [int]$i) { while ($i -lt $s.Length -and [char]::IsWhiteSpace($s[$i])) { $i++ }; return $i }
function Skip-JsonString([string]$s, [int]$i) {   # $s[$i] 是 "；回傳結尾引號後一格
    $i++
    while ($i -lt $s.Length) { $c = $s[$i]; if ($c -eq [char]'\') { $i += 2; continue }; if ($c -eq [char]'"') { return $i + 1 }; $i++ }
    throw 'JSON 字串沒有結束'
}
function Skip-JsonValue([string]$s, [int]$i) {   # 回傳值結尾（不含）
    $c = $s[$i]
    if ($c -eq [char]'"') { return Skip-JsonString $s $i }
    if ($c -eq [char]'{' -or $c -eq [char]'[') {
        $depth = 0
        while ($i -lt $s.Length) {
            $c = $s[$i]
            if ($c -eq [char]'"') { $i = Skip-JsonString $s $i; continue }
            if ($c -eq [char]'{' -or $c -eq [char]'[') { $depth++ } elseif ($c -eq [char]'}' -or $c -eq [char]']') { $depth--; if ($depth -eq 0) { return $i + 1 } }
            $i++
        }
        throw 'JSON 括號沒有結束'
    }
    while ($i -lt $s.Length -and ',}]'.IndexOf($s[$i]) -lt 0 -and -not [char]::IsWhiteSpace($s[$i])) { $i++ }
    return $i
}
function Get-JsonMembers([string]$s, [int]$open) {   # $s[$open] 是 {；回傳 { Members=[{Name,KeyStart,ValStart,ValEnd}], Close }
    $list = [Collections.Generic.List[object]]::new(); $i = Skip-JsonWs $s ($open + 1)
    if ($s[$i] -eq [char]'}') { return [pscustomobject]@{ Members = $list; Close = $i } }
    while ($true) {
        $i = Skip-JsonWs $s $i; if ($s[$i] -ne [char]'"') { throw "JSON 第 $i 字預期鍵名" }
        $ke = Skip-JsonString $s $i; $name = [regex]::Unescape($s.Substring($i + 1, $ke - $i - 2))
        $j = Skip-JsonWs $s $ke; if ($s[$j] -ne [char]':') { throw "JSON 第 $j 字預期 :" }
        $vs = Skip-JsonWs $s ($j + 1); $ve = Skip-JsonValue $s $vs
        $list.Add([pscustomobject]@{ Name = $name; KeyStart = $i; ValStart = $vs; ValEnd = $ve })
        $i = Skip-JsonWs $s $ve
        if ($s[$i] -eq [char]',') { $i++; continue }
        if ($s[$i] -eq [char]'}') { return [pscustomobject]@{ Members = $list; Close = $i } }
        throw "JSON 第 $i 字預期 , 或 }"
    }
}
# 已有 tracker 物件 ⇒ 只換 type 的值（沒有 type 就插在第一個欄位前）；tracker 不是物件 ⇒ 換成物件；沒有 tracker ⇒ 插在最後一個欄位後
function Set-JsonTrackerText([string]$text, [string]$type) {
    $q = '"' + $type + '"'; $obj = "{ `"type`": $q, `"url`": `"`" }"
    $open = Skip-JsonWs $text 0; if ($text[$open] -ne [char]'{') { throw 'workflow.json 不是物件' }
    $top = Get-JsonMembers $text $open
    $tr = @($top.Members | Where-Object Name -eq 'tracker')[0]
    if ($tr) {
        if ($text[$tr.ValStart] -ne [char]'{') { return $text.Substring(0, $tr.ValStart) + $obj + $text.Substring($tr.ValEnd) }
        $inner = Get-JsonMembers $text $tr.ValStart
        $ty = @($inner.Members | Where-Object Name -eq 'type')[0]
        if ($ty) { return $text.Substring(0, $ty.ValStart) + $q + $text.Substring($ty.ValEnd) }
        if (-not $inner.Members.Count) { return $text.Substring(0, $tr.ValStart) + $obj + $text.Substring($tr.ValEnd) }
        $k0 = $inner.Members[0].KeyStart; $ws = $text.Substring($tr.ValStart + 1, $k0 - $tr.ValStart - 1); if (-not $ws) { $ws = ' ' }
        return $text.Substring(0, $k0) + "`"type`": $q," + $ws + $text.Substring($k0)
    }
    if (-not $top.Members.Count) { $nl = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }; return $text.Substring(0, $open + 1) + $nl + "  `"tracker`": $obj" + $nl + $text.Substring($top.Close) }
    $last = $top.Members[$top.Members.Count - 1]; $k0 = $top.Members[0].KeyStart
    $ws = $text.Substring($open + 1, $k0 - $open - 1); if ($ws -notmatch '\n') { $ws = ' ' }   # 沿用第一個欄位前的換行＋縮排
    return $text.Substring(0, $last.ValEnd) + ',' + $ws + "`"tracker`": $obj" + $text.Substring($last.ValEnd)
}

$toolsRel = 'AI_Service/hd5-tools'
if ($Update) {
    # ── -Update：已導入過的專案只更新套件擁有的檔（skills、工具），專案的設定與產物一律不動（11-23 使用者拍板）──
    $wfPath = Join-Path $proj '.claude/workflow.json'
    $hasFlow = (Test-Path -LiteralPath (Join-Path $proj '.claude/skills/hd5-workflow/SKILL.md')) -or (Test-Path -LiteralPath (Join-Path $proj '.agents/skills/hd5-workflow/SKILL.md'))
    if (-not (Test-Path -LiteralPath $wfPath) -or -not $hasFlow) { throw "這個專案還沒導入 HD5Skills（找不到 .claude/workflow.json 或 hd5-workflow skill）：$proj——請改用一般安裝（不帶 -Update）" }
    $wfU = [IO.File]::ReadAllText($wfPath) | ConvertFrom-Json
    if ($wfU.paths.tools) { $toolsRel = ([string]$wfU.paths.tools -replace '\\', '/').Trim('/') }
    $wfTracker = if ($wfU.tracker -is [string]) { $wfU.tracker } else { $wfU.tracker.type }
    if ($wfTracker -eq 'azure-devops') { $Tracker = 'azure-devops' }
    Write-Host "== 更新 HD5Skills（-Update）：$proj（工具：$toolsRel；工單工具：$(if ($Tracker -eq 'azure-devops') { '更新' } else { '不裝' })）"

    $isPersonal = { param($n) $n -like '*.local.*' -or $n -like 'pat*.txt' -or $n -like '*.pat.txt' }   # PAT／個人設定：不複製、不覆蓋、不列
    $updated = [Collections.Generic.List[string]]::new(); $gone = [Collections.Generic.List[string]]::new(); $script:same = 0
    $relP = { param($full) $full.Substring($proj.Length).TrimStart('\', '/') -replace '\\', '/' }
    function Sync-File([string]$src, [string]$dst) {
        if (Test-Path -LiteralPath $dst -PathType Leaf) {
            $a = [IO.File]::ReadAllBytes($src); $b = [IO.File]::ReadAllBytes($dst)
            if ([Linq.Enumerable]::SequenceEqual([byte[]]$a, [byte[]]$b)) { $script:same++; return }
            # 只差行尾（git autocrlf 把 checkout 的檔轉成 CRLF）不算變動、也不覆蓋——否則 Windows 上每次 -Update 都把幾十支檔報成「更新」（11-24 IMOCore 實測 53 支其實只有 3 支有變）
            if ([Array]::IndexOf($a, [byte]0) -lt 0 -and [Array]::IndexOf($b, [byte]0) -lt 0) {
                $enc = [Text.UTF8Encoding]::new($false)
                if ($enc.GetString($a).Replace("`r`n", "`n") -ceq $enc.GetString($b).Replace("`r`n", "`n")) { $script:same++; return }
            }
        }
        New-Item -ItemType Directory -Force (Split-Path $dst -Parent) | Out-Null
        Copy-Item -LiteralPath $src -Destination $dst -Force; $updated.Add((& $relP $dst))
    }
    # 目錄同步：套件有的覆蓋；目標多出來的（不含 PAT、不含 $skipSub 子資料夾）只列出、不刪
    function Sync-Tree([string]$srcDir, [string]$dstDir, [string[]]$skipSub = @()) {
        $srcDir = [IO.Path]::GetFullPath($srcDir); $dstDir = [IO.Path]::GetFullPath($dstDir)
        $own = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($f in Get-ChildItem -LiteralPath $srcDir -Recurse -File -Force) {
            if (& $isPersonal $f.Name) { continue }
            $r = $f.FullName.Substring($srcDir.Length).TrimStart('\', '/') -replace '\\', '/'; [void]$own.Add($r)
            Sync-File $f.FullName (Join-Path $dstDir $r)
        }
        if (-not (Test-Path -LiteralPath $dstDir)) { return }
        foreach ($f in Get-ChildItem -LiteralPath $dstDir -Recurse -File -Force) {
            $r = $f.FullName.Substring($dstDir.Length).TrimStart('\', '/') -replace '\\', '/'
            if ($own.Contains($r) -or (& $isPersonal $f.Name) -or @($skipSub | Where-Object { $r -like "$_/*" }).Count) { continue }
            $gone.Add((& $relP $f.FullName))
        }
    }
    # skills
    $trackerSkillsU = @{ 'hd5-workitem' = 'azure-devops' }
    $skillsU = Get-ChildItem -LiteralPath $kit -Directory | Where-Object { (Test-Path (Join-Path $_.FullName 'SKILL.md')) -and (-not $trackerSkillsU.ContainsKey($_.Name) -or $trackerSkillsU[$_.Name] -eq $Tracker) }
    foreach ($s in $skillsU) {
        foreach ($root in '.claude/skills', '.agents/skills') {
            $dst = Join-Path $proj "$root/$($s.Name)"
            if ($s.Name -eq 'hd5-workflow' -or $s.Name -eq 'hd5-workitem') {
                Sync-File (Join-Path $s.FullName 'SKILL.md') (Join-Path $dst 'SKILL.md')   # 只放 SKILL.md；工具在 $toolsRel
                if (Test-Path -LiteralPath $dst) { Get-ChildItem -LiteralPath $dst -Recurse -File -Force | Where-Object { $_.Name -ne 'SKILL.md' -and -not (& $isPersonal $_.Name) } | ForEach-Object { $gone.Add((& $relP $_.FullName)) } }
            } else { Sync-Tree $s.FullName $dst }
        }
    }
    foreach ($root in '.claude/skills', '.agents/skills') {   # 專案裡有、套件已不含的 hd5-* skill
        $rd = Join-Path $proj $root
        if (Test-Path -LiteralPath $rd) { Get-ChildItem -LiteralPath $rd -Directory -Filter 'hd5-*' | Where-Object { -not (Test-Path (Join-Path $kit "$($_.Name)/SKILL.md")) } | ForEach-Object { $gone.Add("$root/$($_.Name)/") } }
    }
    # 工具（工單工具另外依 tracker）
    Sync-Tree (Join-Path $kit 'hd5-workflow/tools') (Join-Path $proj $toolsRel) @('workitem')
    if ($Tracker -eq 'azure-devops') { Sync-Tree (Join-Path $kit 'hd5-workitem/scripts') (Join-Path $proj "$toolsRel/workitem") }
    # settings.json：不改，只檢查兩支 hook 有沒有掛
    $stP = Join-Path $proj '.claude/settings.json'; $hookCmds = ''
    if (Test-Path -LiteralPath $stP) { try { $hookCmds = @((Get-Content -Raw -LiteralPath $stP -Encoding UTF8 | ConvertFrom-Json).hooks.PreToolUse.hooks.command) -join "`n" } catch { } }
    foreach ($h in 'grill-gate.ps1', 'main-edit-guard.ps1') {
        if ($hookCmds -notmatch [regex]::Escape($h)) { Write-Warning ".claude/settings.json 沒掛 $h（-Update 不改設定）：要補請不帶 -Update 再跑一次一般安裝（只合併 hook、已存在的檔不覆蓋）" }
        # 11-24：hook 改用 pwsh -Command（端點防護會把 -File 執行的腳本關進隔離區）——舊專案的 settings.json 要手動換
        elseif (@($hookCmds -split "`n" | Where-Object { $_ -match [regex]::Escape($h) -and $_ -match '\s-File\s' }).Count) {
            Write-Warning (".claude/settings.json 的 $h 還是舊寫法 pwsh -File（-Update 不改設定）。請手動換成範本裡的 -Command 寫法（結束碼要照 -File 規則，不能只寫 exit `$LASTEXITCODE）" +
                "（範本：$(Join-Path $kit 'hd5-onboard/templates/settings.hooks.json')）")
        }
        # 11-24：找不到 hook 腳本時不再靜默放行（stderr 警告＋additionalContext）——舊專案的 settings.json 要手動換
        elseif (@($hookCmds -split "`n" | Where-Object { $_ -match [regex]::Escape($h) -and $_ -notmatch '>&2' }).Count) {
            Write-Warning (".claude/settings.json 的 $h 找不到腳本時還是靜默放行（舊寫法結尾只有 exit 0；-Update 不改設定）。請手動換成範本寫法（找不到就 stderr 警告＋回一行 additionalContext，仍不擋）" +
                "（範本：$(Join-Path $kit 'hd5-onboard/templates/settings.hooks.json')）")
        }
    }
    Write-Host "  更新 $($updated.Count) 個檔（內容有變）、沒變 $($script:same) 個"
    foreach ($u in $updated | Select-Object -First 20) { Write-Host "    更新 $u" }
    if ($updated.Count -gt 20) { Write-Host "    …另 $($updated.Count - 20) 個" }
    if ($gone.Count) {
        Write-Host "  套件已不含、請確認後手動刪（-Update 不刪檔）：$($gone.Count) 個"
        foreach ($g in $gone) { Write-Host "    $g" }
    }
}
if (-not $Update) {
    Write-Host "== 安裝 HD5Skills：$RepoRoot（專案資料夾：$(if ($ProjectDir) { $ProjectDir } else { '（repo 根）' })）"

    # ── skills（Claude：.claude/skills；Codex：.agents/skills）──
    $trackerSkills = @{ 'hd5-workitem' = 'azure-devops' }   # 只在選了該工單系統時才裝
    $skills = Get-ChildItem -LiteralPath $kit -Directory | Where-Object { (Test-Path (Join-Path $_.FullName 'SKILL.md')) -and (-not $trackerSkills.ContainsKey($_.Name) -or $trackerSkills[$_.Name] -eq $Tracker) }
    foreach ($s in $skills) {
        foreach ($root in '.claude/skills', '.agents/skills') {
            $dst = Join-Path $proj "$root/$($s.Name)"
            if ($s.Name -eq 'hd5-workflow' -or $s.Name -eq 'hd5-workitem') {
                # 只放 SKILL.md；工具裝到 AI_Service/hd5-tools（只有一份，避免兩處漂開）
                Copy-One (Join-Path $s.FullName 'SKILL.md') (Join-Path $dst 'SKILL.md')
            } else { Copy-One $s.FullName $dst }
        }
    }
    # ── 工具 ──
    Copy-One (Join-Path $kit 'hd5-workflow/tools') (Join-Path $proj 'AI_Service/hd5-tools')
    if ($Tracker -eq 'azure-devops') {
        Copy-One (Join-Path $kit 'hd5-workitem/scripts') (Join-Path $proj "$toolsRel/workitem")
        # PAT 檔多一層保險：repo 根 .gitignore 也排除
        $gi = Join-Path $RepoRoot '.gitignore'; $cur = if (Test-Path -LiteralPath $gi) { [IO.File]::ReadAllText($gi) } else { '' }
        $add = @('pat.local.txt', 'pat.write.local.txt', '*.pat.txt') | Where-Object { $cur -notmatch ('(?m)^' + [regex]::Escape($_) + '\s*$') }
        if ($add) {
            $lead = if ($cur -and -not $cur.EndsWith("`n")) { "`n" } else { '' }
            [IO.File]::AppendAllText($gi, $lead + "# HD5Skills：Azure DevOps PAT 不進版控`n" + ($add -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
        }
    }
    New-Item -ItemType Directory -Force (Join-Path $proj 'AI_Service/spec'), (Join-Path $proj 'AI_Service/verify/features') | Out-Null
    # ── 代理（範本；hd5-onboard 會改寫實作代理）──
    $tpl = Join-Path $kit 'hd5-onboard/templates'
    foreach ($n in 'pm-expert', 'sa-expert', 'qa-expert') { Copy-One (Join-Path $tpl "agents/$n.md") (Join-Path $proj ".claude/agents/$n.md") }
    foreach ($n in 'backend-expert', 'frontend-expert') { Copy-One (Join-Path $tpl "agents/$n.template.md") (Join-Path $proj ".claude/agents/$n.md") }
    Copy-One (Join-Path $tpl 'workflow.json.tpl') (Join-Path $proj '.claude/workflow.json')
    if ($Tracker -ne 'none') {
        # 選了工單系統就寫進 workflow.json（工單工具看 tracker.type 決定要不要做事）。
        # 11-23 導入 IMOCore：整份 ConvertTo-Json 重寫會把單行陣列展開、縮排全變 ⇒ 已是同值不寫；要改就只動 tracker 那段（文字層級），解析不了才整份重寫
        $wfPath = Join-Path $proj '.claude/workflow.json'
        $wfBytes = [IO.File]::ReadAllBytes($wfPath); $wfBom = $wfBytes.Length -ge 3 -and $wfBytes[0] -eq 0xEF -and $wfBytes[1] -eq 0xBB -and $wfBytes[2] -eq 0xBF
        $wfRaw = [IO.File]::ReadAllText($wfPath)
        $wf = $wfRaw | ConvertFrom-Json
        $curType = if ($wf.tracker -is [string]) { $wf.tracker } else { $wf.tracker.type }
        if ($curType -eq $Tracker) { Write-Host "  workflow.json 的 tracker.type 已是 $Tracker（不改檔）" }
        else {
            $wfNew = $null
            try {
                $wfNew = Set-JsonTrackerText $wfRaw $Tracker
                $chk = $wfNew | ConvertFrom-Json
                $rest = { param($o) ($o.PSObject.Properties | Where-Object Name -ne 'tracker' | ForEach-Object { "$($_.Name)=$($_.Value | ConvertTo-Json -Depth 20 -Compress)" }) -join "`n" }
                if ($chk.tracker.type -ne $Tracker -or (& $rest $chk) -ne (& $rest $wf)) { $wfNew = $null }
            } catch { $wfNew = $null }
            if ($null -eq $wfNew) {
                Write-Warning "workflow.json 無法只改 tracker 那段（格式解析失敗），改為整份重寫：縮排與單行陣列可能變動，請看 git diff"
                if (-not $wf.PSObject.Properties['tracker'] -or $wf.tracker -isnot [pscustomobject]) { $wf | Add-Member -NotePropertyName tracker -NotePropertyValue ([pscustomobject]@{ type = $Tracker; url = '' }) -Force }
                else { $wf.tracker | Add-Member -NotePropertyName type -NotePropertyValue $Tracker -Force }
                $wfNew = ($wf | ConvertTo-Json -Depth 20) + "`n"
            }
            [IO.File]::WriteAllText($wfPath, $wfNew, [Text.UTF8Encoding]::new($wfBom))
            Write-Host "  workflow.json 的 tracker.type 改成 $Tracker（只動 tracker 那段）"
        }
    }

    # ── settings.json：合併兩支 hook ──
    $settingsPath = Join-Path $proj '.claude/settings.json'
    $settings = if (Test-Path -LiteralPath $settingsPath) { Get-Content -Raw -LiteralPath $settingsPath -Encoding UTF8 | ConvertFrom-Json } else { [pscustomobject]@{} }
    $hk = (Get-Content -Raw -LiteralPath (Join-Path $tpl 'settings.hooks.json') -Encoding UTF8).Replace('{{PREFIX}}', $prefix) | ConvertFrom-Json
    if (-not $settings.PSObject.Properties['hooks']) { $settings | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{}) }
    if (-not $settings.hooks.PSObject.Properties['PreToolUse']) { $settings.hooks | Add-Member -NotePropertyName PreToolUse -NotePropertyValue @() }
    $added = 0
    foreach ($e in @($hk.hooks.PreToolUse)) {
        if (@($settings.hooks.PreToolUse | Where-Object { $_.matcher -eq $e.matcher }).Count) { continue }
        $settings.hooks.PreToolUse = @($settings.hooks.PreToolUse) + $e; $added++
    }
    # 一筆都沒新增就不寫檔（11-23 導入 IMOCore：整份 ConvertTo-Json 重寫讓行尾／縮排全變，git diff 一堆無意義變更）
    if ($added -or -not (Test-Path -LiteralPath $settingsPath)) {
        New-Item -ItemType Directory -Force (Split-Path $settingsPath -Parent) | Out-Null
        [IO.File]::WriteAllText($settingsPath, ($settings | ConvertTo-Json -Depth 20) + "`n", [Text.UTF8Encoding]::new($false))
    }

    Write-Host "  複製 $($copied.Count) 個檔、settings.json 新增 hook $added 筆"
    if ($skipped.Count) { Write-Host "  已存在而跳過 $($skipped.Count) 個（要覆蓋加 -Force）：$(($skipped | Select-Object -First 6) -join '、')$(if ($skipped.Count -gt 6) { '…' })" }
}

# ── 裝完驗證 ──
$fail = 0
if (-not $SkipTests) {
    $exe = [Environment]::ProcessPath
    foreach ($t in @((Join-Path $proj "$toolsRel/hooks/tests/main-edit-guard.tests.ps1"), (Join-Path $proj "$toolsRel/hooks/tests/grill-gate.tests.ps1"), (Join-Path $proj "$toolsRel/tests/validate-grill-gate.tests.ps1"), (Join-Path $proj "$toolsRel/tests/verify-map.tests.ps1")) + @(if ($Tracker -eq 'azure-devops') { (Join-Path $proj "$toolsRel/workitem/tests/workitem-ops.tests.ps1"), (Join-Path $proj "$toolsRel/workitem/tests/devops-lib.tests.ps1") })) {
        $psi = [Diagnostics.ProcessStartInfo]::new($exe)
        # -Command 而非 -File（11-24 同事回報：端點防護（COMODO）把 -File 執行的腳本關進隔離區，寫的檔外面看不到）
        # 結束碼照 -File 的規則：exit N ⇒ N、自然結束 ⇒ 0（不拿舊的 $LASTEXITCODE）、拋例外 ⇒ 1
        $run = "`$global:LASTEXITCODE = 0; & '$($t.Replace("'", "''"))'; if (`$?) { exit 0 } elseif (`$LASTEXITCODE) { exit `$LASTEXITCODE } else { exit 1 }"
        foreach ($x in @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', $run)) { $psi.ArgumentList.Add($x) }
        $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false; $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
        $pr = [Diagnostics.Process]::Start($psi); $pr.StandardInput.Close(); $so = $pr.StandardOutput.ReadToEndAsync(); $null = $pr.StandardError.ReadToEndAsync()
        if (-not $pr.WaitForExit(180000)) { $pr.Kill($true); $out = '（超過 180 秒，已中止）'; $code = -1 } else { $out = $so.Result; $code = $pr.ExitCode }
        $last = ($out.Trim() -split "`n")[-1].Trim(); $ok = $code -eq 0 -and $last -match 'ALL PASSED'
        Write-Host "  $(if ($ok) { '✅' } else { '❌' }) $(Split-Path $t -Leaf)：$last"; if (-not $ok) { $fail++ }
    }
}
Write-Host ''
if ($Update) {
    if ($fail) { Write-Host "❌ 有 $fail 項驗證沒過" -ForegroundColor Red; exit 1 }
    Write-Host '✅ 更新完成（只動套件的 skills 與工具；用 git diff 看改了什麼）' -ForegroundColor Green
    return
}
Write-Host '== 下一步'
Write-Host "  在 $proj 啟動 Claude Code（或 Codex），執行 hd5-onboard：掃描專案、問你補不出來的事、產生 AGENTS.md／CLAUDE.md、實作代理、workflow.json、功能地圖骨架。"
if ($fail) { Write-Host "❌ 有 $fail 項驗證沒過" -ForegroundColor Red; exit 1 }
Write-Host '✅ 安裝完成' -ForegroundColor Green
