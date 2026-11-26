# grill-gate.ps1 — 質詢輪機制化 gate（PreToolUse hook，攔截 Agent/Task 派發）
#
# 規則（對應 hd5-grill 第五節 checkpoint）：
#   派發 sa-expert                     → 上游必須已有 pm/grill-*.md（PM 需求質詢輪紀錄）
#   派發 csharp/vue3/qa-expert         → 上游必須已有 sa/grill-*.md（SA 設計質詢輪紀錄）
#   pm-expert 與其他 agent             → 不攔（PM 是第一棒，沒有上游）
#
# 有效紀錄的定義：檔案存在，且內容至少出現一個三態標記（已拍板／已查證／已轉單）。
# 跳步：僅當使用者明確要求跳步時，主對話在派發 prompt 中加入 GRILL_GATE=skip 重新派發。
# 2026-11-23：prompt 指到 AI_Service/spec/<案名> 時改呼叫 validate-grill-gate.ps1 檢查該案（含路線閘：有路線就不准跳步，
#   舊案用 SKIP_ROUTE=<理由>）；沒指到案子才走下方舊邏輯。
# 找不到專案脈絡（無 AI_Service 目錄）時放行（fail-open），避免誤傷無關派發。
# 2026-11-24：放行也不再靜默——每條放行路徑都回一行 additionalContext（走哪條路徑、代理、案子、閘 exit 碼），
#   主對話才分得出「跑過且通過」與「根本沒觸發」（試跑時 hook 沒載入卻沒有任何訊號）。
#
# 佈署位置：<專案>/AI_Service/hd5-tools/hooks/（HD5Skills install.ps1 裝入、入版控）；由 <專案>/.claude/settings.json 掛載。

$ErrorActionPreference = 'SilentlyContinue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# 放行：exit 0＋stdout 一行 JSON（Claude Code 把 hookSpecificOutput.additionalContext 交給主對話）
function Pass([string]$how, [string]$agent = '', [string]$case = '', [string]$gateCode = '未呼叫', [string[]]$warnings = @()) {
    $msg = "grill-gate 放行：$how；代理=$(if ($agent) { $agent } else { '（無）' })；案子=$(if ($case) { $case } else { '（未指到）' })；閘 exit=$gateCode"
    foreach ($w in @($warnings | Where-Object { $_ })) { $msg += "`n$w" }   # 閘的「grill-gate 警告：…」（不擋，2026-11-25）
    $json = @{ hookSpecificOutput = @{ hookEventName = 'PreToolUse'; additionalContext = $msg } } | ConvertTo-Json -Compress -Depth 4
    [Console]::Out.WriteLine($json)
    exit 0
}

# 專案：從本 hook 位置往上找 .claude/workflow.json（_hd5-locate.ps1；HD5Skills 裝在 <專案>/AI_Service/hd5-tools/hooks，
# IMOCore 舊位置 <專案>/.claude/hooks 也認得）。不寫死專案資料夾、AI_Service 名稱、工具位置（2026-11-23）。
$locate = Join-Path $PSScriptRoot '..\_hd5-locate.ps1'
if (-not (Test-Path -LiteralPath $locate)) { $locate = Join-Path $PSScriptRoot '_hd5-locate.ps1' }
$hd5 = $null
if (Test-Path -LiteralPath $locate) { . $locate; $hd5 = Get-HD5Project -Start $PSScriptRoot }
$projPrefix = if ($hd5 -and $null -ne $hd5.Prefix) { $hd5.Prefix } else { 'IMOCore/' }
$aiName = if ($hd5) { $hd5.AiService } else { 'AI_Service' }

# ---- 讀 stdin JSON（解析失敗一律放行，gate 絕不能反過來卡死正常流程）----
try {
    # 2026-11-23：stdin 一律用 UTF-8 讀原始位元組。原本 [Console]::In 依系統字碼頁（cp950）解碼，
    # 中文 prompt 變亂碼 ⇒ JSON 解析失敗 ⇒ 下面 catch 放行——中文派發實際上從來沒被擋過。
    $ms = [IO.MemoryStream]::new(); [Console]::OpenStandardInput().CopyTo($ms)
    $raw = [Text.Encoding]::UTF8.GetString($ms.ToArray()).TrimStart([char]0xFEFF)
    $payload = $raw | ConvertFrom-Json
} catch { Pass 'stdin 不是 JSON（未檢查）' }
if (-not $payload -or -not $payload.tool_input) { Pass '沒有 tool_input（未檢查）' }

$toolName = [string]$payload.tool_name
if ($toolName -and $toolName -notin @('Task', 'Agent')) { Pass "工具 $toolName 不是派發（未檢查）" }

$agentType = [string]$payload.tool_input.subagent_type
$prompt    = [string]$payload.tool_input.prompt

# 實作代理由 <專案>/.claude/workflow.json 決定（通用化 2026-11-23）；舊名 csharp／vue3-expert 過渡期當別名。
# $gateMap：代理 → 上游資料夾（舊邏輯用）；$roleMap：代理 → validate-grill-gate 的 -Role
$roleMap = @{ 'sa-expert' = 'sa'; 'qa-expert' = 'qa' }
$wf = if ($hd5) { $hd5.Workflow } else { $null }
if ($wf -and $wf.implementers) {
    foreach ($i in @($wf.implementers)) { foreach ($n in @([string]$i.agent) + @($i.aliases)) { if ($n) { $roleMap[[string]$n] = [string]$i.gateRole } } }
} else {
    $roleMap['backend-expert'] = 'backend'; $roleMap['frontend-expert'] = 'frontend'; $roleMap['csharp-expert'] = 'backend'; $roleMap['vue3-expert'] = 'frontend'
}
$gateMap = @{}
foreach ($k in $roleMap.Keys) { $gateMap[$k] = if ($roleMap[$k] -eq 'sa') { 'pm' } else { 'sa' } }
if (-not $agentType -or -not $gateMap.ContainsKey($agentType)) { Pass '不是要過質詢閘的角色代理（pm 與其他代理不檢查）' $agentType }


$upstream = $gateMap[$agentType]

# ---- 定位專案根：hook cwd 與 payload.cwd，各自再試 IMOCore 子層 ----
$candidates = @()
foreach ($base in @((Get-Location).Path, [string]$payload.cwd)) {
    if ($base) {
        $candidates += $base
        $candidates += (Join-Path $base 'IMOCore')
        if ($projPrefix) { $candidates += (Join-Path $base $projPrefix.TrimEnd('/')) }
    }
}
if ($hd5 -and $hd5.ProjectDir) { $candidates += $hd5.ProjectDir }
$projectRoots = $candidates |
    Where-Object { $_ -and (Test-Path (Join-Path $_ $aiName)) } |
    Select-Object -Unique

# 沒有任何候選根含 AI_Service → 非 IMOCore 專案脈絡，放行
if (-not $projectRoots) { Pass "找不到專案脈絡（候選根都沒有 $aiName/）" $agentType }

# ---- 2026-11-23：prompt 指到某個案子時，改用 validate-grill-gate.ps1 檢查「那個案子」----
# 路線／質詢／功能地圖同一套規則（AGENTS.md「案件路線」）。下方舊邏輯掃的是所有案子的
# spec/*/{pm|sa}/grill-*.md，任何舊案有紀錄就放行，實際上幾乎不擋——只留給「prompt 沒指到案子」的派發。
# $roleMap 已在上面依 workflow.json 建好
$caseMatch = [regex]::Match($prompt, [regex]::Escape($aiName) + '[\\/]+spec[\\/]+([^\\/\s"''\x60）)>，。、]+)')
$fallbackWhy = 'prompt 沒指到案子'
if ($caseMatch.Success) {
    $caseName = $caseMatch.Groups[1].Value
    $fallbackWhy = "prompt 指到 $caseName 但找不到該案子資料夾"
    $caseDir = $projectRoots | ForEach-Object { Join-Path $_ "$aiName/spec/$caseName" } |
        Where-Object { Test-Path -LiteralPath $_ -PathType Container } | Select-Object -First 1
    if ($caseDir) {
        # 質詢閘位置：案子所屬專案的 workflow.json paths.tools → 本 hook 的上一層（HD5Skills tools）→ IMOCore 舊位置
        $gate = $null
        $gateCandidates = @()
        if ($locate -and (Test-Path -LiteralPath $locate)) { $cp = Get-HD5Project -Start $caseDir; if ($cp.Workflow -and $cp.Workflow.paths -and $cp.Workflow.paths.tools) { $gateCandidates += (Join-Path $cp.ToolsDir 'validate-grill-gate.ps1') } }
        $gateCandidates += (Join-Path $PSScriptRoot '..\validate-grill-gate.ps1')
        $gateCandidates += (Join-Path (Split-Path (Split-Path $caseDir -Parent) -Parent) '.agents/skills/imocore-vue3-workflow/scripts/validate-grill-gate.ps1')
        $gate = $gateCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if ($gate) {
            # 用 -Command 而非 -File（11-24 同事回報：端點防護（COMODO）把 -File 執行的腳本關進隔離區）；
            # 每個值都包單引號、內含單引號重複一次——SKIP_ROUTE 等值來自派發 prompt，不能讓它變成指令
            $q = { param($s) "'" + ([string]$s).Replace("'", "''") + "'" }
            $cmd = "& $(& $q $gate) -Role $(& $q $roleMap[$agentType]) -CasePath $(& $q $caseDir)"
            if ($prompt -match 'GRILL_GATE\s*=\s*skip') { $cmd += ' -Skip' }
            $sr = [regex]::Match($prompt, 'SKIP_ROUTE\s*=\s*([^\r\n]+)'); if ($sr.Success) { $cmd += " -SkipRoute $(& $q $sr.Groups[1].Value.Trim())" }
            $sf = [regex]::Match($prompt, 'SKIP_FEATURE_MAP\s*=\s*([^\r\n]+)'); if ($sf.Success) { $cmd += " -SkipFeatureMap $(& $q $sf.Groups[1].Value.Trim())" }
            # 結束碼照 -File 的規則：腳本 exit N ⇒ N；自然結束 ⇒ 0（不能拿腳本裡最後一個外部指令留下的舊 $LASTEXITCODE）；拋例外 ⇒ 1
            $gateArgs = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command',
                ('$global:LASTEXITCODE = 0; ' + $cmd + '; if ($?) { exit 0 } elseif ($LASTEXITCODE) { exit $LASTEXITCODE } else { exit 1 }'))
            # 用 hook 自己這支 PowerShell（不靠 pwsh 別名：Store 版別名從某些工作目錄啟動會「拒絕存取」，
            # 加上本檔 ErrorActionPreference=SilentlyContinue，以前叫不起來會拿到舊的 0 而放行）
            $exe = [Environment]::ProcessPath; if (-not $exe) { $exe = (Get-Process -Id $PID).Path }
            $global:LASTEXITCODE = $null; $gateOut = ''
            try { $gateOut = & $exe @gateArgs 2>&1 | Out-String } catch { $gateOut = $_.Exception.Message }
            $code = $LASTEXITCODE
            if ($code -eq 0) {
                $passLine = @($gateOut -split "`r?`n" | Where-Object { $_ -match 'GRILL_GATE=pass' } | Select-Object -First 1)
                # 2026-11-25：閘的警告（不擋）逐行帶進放行訊息，主對話才看得到
                $warnLines = @($gateOut -split "`r?`n" | Where-Object { $_ -match '^\s*grill-gate 警告：' } | ForEach-Object { $_.Trim() })
                Pass "validate-grill-gate 通過$(if ($passLine) { "（$($passLine[0].Trim())）" })" $agentType $caseName '0' $warnLines
            }
            if ($null -eq $code) {
                [Console]::Error.WriteLine("🔴 grill-gate 攔截：叫不起 validate-grill-gate.ps1（$exe），寧可擋下也不放行。" + [Environment]::NewLine + $gateOut.Trim())
                exit 2
            }
            [Console]::Error.WriteLine("🔴 grill-gate 攔截：派發 $agentType 前，案子 $caseName 沒過 validate-grill-gate.ps1（exit $code）。" + [Environment]::NewLine +
                $gateOut.Trim() + [Environment]::NewLine +
                '路線規則見 AGENTS.md「案件路線」。本規則生效前的舊案在派發 prompt 加一行 SKIP_ROUTE=<理由>；純工具案加 SKIP_FEATURE_MAP=<理由>。')
            exit 2
        }
        $fallbackWhy = "案子 $caseName 找不到 validate-grill-gate.ps1（已找：$($gateCandidates -join '；')）"
    }
}

# ---- 舊邏輯（prompt 沒指到案子）：使用者授權的跳步 escape hatch ----
if ($prompt -match 'GRILL_GATE\s*=\s*skip') { Pass "舊邏輯（$fallbackWhy）：prompt 帶 GRILL_GATE=skip" $agentType }

# ---- 收集上游 grill 紀錄：{root}/{pm|sa}/grill-*.md 及 {root}/AI_Service/spec/*/{pm|sa}/grill-*.md ----
$searched = @()
$grillFiles = @()
foreach ($root in $projectRoots) {
    foreach ($dirPattern in @((Join-Path $root $upstream), (Join-Path $root "$aiName/spec/*/$upstream"))) {
        $searched += $dirPattern
        $dirs = Get-Item -Path $dirPattern -ErrorAction SilentlyContinue | Where-Object { $_.PSIsContainer }
        foreach ($d in $dirs) {
            $grillFiles += Get-ChildItem -Path $d.FullName -Filter 'grill-*.md' -File -ErrorAction SilentlyContinue
        }
    }
}

# ---- 有效性檢查：至少一份紀錄含三態標記 ----
$validFiles = @()
$staleFiles = @()
foreach ($f in $grillFiles) {
    $content = Get-Content -Path $f.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    if ($content -and $content -match '已拍板|已查證|已轉單') { $validFiles += $f }
    else { $staleFiles += $f }
}
if ($validFiles.Count -gt 0) { Pass "舊邏輯（$fallbackWhy）：任一案 $upstream/grill-*.md 有終止標記（$($validFiles.Count) 份）——沒檢查特定案子" $agentType }

# ---- 攔截：exit 2 + stderr（訊息會回饋給主對話的 Claude）----
$roleDesc = if ($upstream -eq 'pm') { 'pm-expert 的需求質詢輪' } else { 'sa-expert 的設計質詢輪' }
$lines = @(
    "🔴 grill-gate 攔截：派發 $agentType 前，找不到有效的上游質詢紀錄 $upstream/grill-*.md。"
)
if ($staleFiles.Count -gt 0) {
    $lines += "找到 $($staleFiles.Count) 份 grill 檔但內容缺少三態標記（已拍板／已查證／已轉單），視為未完成：$(($staleFiles | ForEach-Object { $_.FullName }) -join '、')"
}
$lines += "已搜尋位置：$($searched -join '；')"
$lines += "依 shared-grill-me.md，$roleDesc 為強制步驟：請先完成上游角色的質詢輪並產出 $upstream/grill-{主題}.md（每個決策樹分支須處於 已拍板／已查證／已轉單 三態之一），再重新派發 $agentType。"
$lines += "僅當使用者明確要求跳步時，才可在派發 prompt 中加入 GRILL_GATE=skip 重新派發；不得自行決定跳過。"

[Console]::Error.WriteLine(($lines -join "`n"))
exit 2
