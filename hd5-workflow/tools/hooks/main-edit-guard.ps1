# main-edit-guard.ps1 — 主對話不准直接改產品程式（PreToolUse hook，攔 Edit／Write／NotebookEdit）
#
# 為什麼（2026-11-23 使用者拍板）：使用者原本理解「下達任務後由主對話判斷派哪個 agent」，
#   但量測顯示 9 月起角色代理只派過 6 次——主對話覺得自己做比較快就自己改了。路線閘（validate-grill-gate）
#   只在「派代理那一刻」檢查，主對話不派、直接改程式時沒有任何東西擋。
#
# 擋的條件（全部成立才擋）：
#   1. 主對話發出的（payload 沒有 agent_id；子代理的呼叫帶 agent_id——2026-11-23 實測確認）
#   2. 改的是產品程式：專案資料夾（IMOCore 線＝IMOCore/）底下、副檔名在 .claude/workflow.json 的 productCode.extensions、
#      不在 productCode.excludeDirs（IMOCore 線：.cs .cshtml .razor .vue .ts .tsx .js；排除 AI_Service／.claude／**/ClientApp/scripts／**/node_modules）
#      excludeDirs 比對（11-23 改）：預設只比「相對專案資料夾的前綴」（scripts/ 只排除 <專案>/scripts/，不會誤排除 frontend/scripts/）；
#      要比任意層要明確寫 **/（例 **/node_modules/）
#   3. 檔案所在 worktree 是工作分支（.claude/workflow.json 的 branches.workBranchPrefix；沒設＝project_）
#   4. 該 worktree 有「進行中的案子」：AI_Service/spec/*/case_spec_content/spec_001.md 寫了路線（四角色｜PM 端已完成｜小問題），
#      且這份 spec_001 是本分支新增或改過的（未 commit，或與 origin/dev 不同）
# 例外：spec_001 有一行「主對話直接改：理由（使用者 MM-DD 同意）」就放行。
# 解析失敗、git 查不到一律放行（fail-open），避免卡死正常流程。
#
# 佈署位置：IMOCore/.claude/hooks/（入版控），由 IMOCore/.claude/settings.json 掛載。測試：tests/main-edit-guard.tests.ps1

$ErrorActionPreference = 'SilentlyContinue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# 專案：從本 hook 位置往上找 .claude/workflow.json（_hd5-locate.ps1；HD5Skills 裝在 <專案>/AI_Service/hd5-tools/hooks，
# IMOCore 舊位置 <專案>/.claude/hooks 也認得）。專案資料夾在 repo 裡的前綴（IMOCore 線＝IMOCore/；repo 根＝空字串）由 git 算。
$locate = Join-Path $PSScriptRoot '..\_hd5-locate.ps1'
if (-not (Test-Path -LiteralPath $locate)) { $locate = Join-Path $PSScriptRoot '_hd5-locate.ps1' }
$hd5 = $null
if (Test-Path -LiteralPath $locate) { . $locate; $hd5 = Get-HD5Project -Start $PSScriptRoot }
$projPrefix = if ($hd5 -and $null -ne $hd5.Prefix) { $hd5.Prefix } else { 'IMOCore/' }
$aiName = if ($hd5) { $hd5.AiService } else { 'AI_Service' }
$projRe = [regex]::Escape($projPrefix)

try {
    # stdin 一律用 UTF-8 讀原始位元組（[Console]::In 依 cp950 解碼，中文路徑會壞——grill-gate.ps1 11-23 實例）
    $ms = [IO.MemoryStream]::new(); [Console]::OpenStandardInput().CopyTo($ms)
    $raw = [Text.Encoding]::UTF8.GetString($ms.ToArray()).TrimStart([char]0xFEFF)
    $payload = $raw | ConvertFrom-Json
} catch { exit 0 }
if (-not $payload -or -not $payload.tool_input) { exit 0 }
if ([string]$payload.tool_name -notin @('Edit', 'Write', 'NotebookEdit', 'MultiEdit')) { exit 0 }
if ($payload.agent_id) { exit 0 }   # 子代理

$file = [string]$payload.tool_input.file_path
if (-not $file) { $file = [string]$payload.tool_input.notebook_path }
if (-not $file) { exit 0 }
if (-not [IO.Path]::IsPathRooted($file) -and $payload.cwd) { $file = Join-Path ([string]$payload.cwd) $file }
$file = [IO.Path]::GetFullPath($file)

# 專案設定（通用化 2026-11-23）：產品程式副檔名、排除目錄、實作代理都由 <專案>/.claude/workflow.json 決定；沒有設定檔用 IMOCore 線的預設
$wf = if ($hd5) { $hd5.Workflow } else { $null }
$productExt = if ($wf -and $wf.productCode.extensions) { @($wf.productCode.extensions | ForEach-Object { ([string]$_).ToLowerInvariant() }) } else { @('.cs', '.cshtml', '.vue', '.ts', '.tsx', '.js', '.razor') }
$excludeDirs = if ($wf -and $wf.productCode.excludeDirs) { @($wf.productCode.excludeDirs | ForEach-Object { [string]$_ }) } else { @('AI_Service/', '.claude/', '**/ClientApp/scripts/', '**/node_modules/') }
# roleHints（選填）：某些目錄歸非實作代理（例 tests/ 歸 qa-expert）；建議派誰時最先比
$roleHints = if ($wf -and $wf.roleHints) { @($wf.roleHints | Where-Object { $_.agent }) } else { @() }
$implementers = if ($wf -and $wf.implementers) { @($wf.implementers) } else {
    @([pscustomobject]@{ agent = 'backend-expert'; extensions = @('.cs', '.cshtml', '.razor'); pathHints = @() },
      [pscustomobject]@{ agent = 'frontend-expert'; extensions = @('.vue', '.ts', '.tsx', '.js'); pathHints = @('ClientApp/') })
}

$ext = [IO.Path]::GetExtension($file).ToLowerInvariant()
if ($ext -notin $productExt) { exit 0 }

# 找檔案所在的 git worktree（新檔案還不存在：往上找到存在的目錄）
$dir = Split-Path $file -Parent
while ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) { $dir = Split-Path $dir -Parent }
if (-not $dir) { exit 0 }
$top = (& git -C $dir rev-parse --show-toplevel 2>$null); if ($LASTEXITCODE -ne 0 -or -not $top) { exit 0 }
$top = [IO.Path]::GetFullPath(($top -replace '/', '\'))
$branch = (& git -C $top rev-parse --abbrev-ref HEAD 2>$null)
# 分支規則讀 workflow.json 的 branches（11-23 king_wu 實測：寫死 project_／origin/dev，feature/* 的專案完全不擋）。
# 沒設 workBranchPrefix ⇒ 退回 IMOCore 線的 project_（hd5-onboard 一開始就要問使用者分支怎麼命名，check-onboard 擋空值）
$workPrefix = if ($wf -and $wf.branches -and [string]$wf.branches.workBranchPrefix) { [string]$wf.branches.workBranchPrefix } else { 'project_' }
$develop = if ($wf -and $wf.branches -and [string]$wf.branches.develop) { [string]$wf.branches.develop } else { 'dev' }
if (-not $branch -or -not $branch.StartsWith($workPrefix) -or $branch -eq $develop) { exit 0 }
$baseRef = $null   # 比對基準：先 origin/<develop>，沒有遠端就本地 <develop>
foreach ($r in @("origin/$develop", $develop)) { & git -C $top rev-parse --verify --quiet $r 2>$null | Out-Null; if ($LASTEXITCODE -eq 0) { $baseRef = $r; break } }

$rel = $file.Substring($top.Length).TrimStart('\', '/') -replace '\\', '/'
if ($rel -notmatch "^$projRe") { exit 0 }
$inProj = $rel.Substring($projPrefix.Length)
# 路徑片段比對：hint 是「相對專案資料夾的前綴」；開頭 **/ 或 -AnyLevel ＝任意層（從目錄邊界開始）
function Test-PathPrefix([string]$path, [string]$hint, [switch]$AnyLevel) {
    $h = ($hint -replace '\\', '/').TrimStart('/')
    $any = [bool]$AnyLevel
    if ($h.StartsWith('**/')) { $any = $true; $h = $h.Substring(3) }
    if (-not $h) { return $false }
    if ($path.StartsWith($h, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    return ($any -and $path.IndexOf('/' + $h, [StringComparison]::OrdinalIgnoreCase) -ge 0)
}
foreach ($d in $excludeDirs) { if (Test-PathPrefix $inProj ([string]$d)) { exit 0 } }

# 進行中的案子
$specRoot = Join-Path $top "$($projPrefix)$aiName/spec"
$active = @()
foreach ($s in @(Get-ChildItem -Path (Join-Path $specRoot '*/case_spec_content/spec_001.md') -File -ErrorAction SilentlyContinue)) {
    $t = Get-Content -Raw -LiteralPath $s.FullName -Encoding UTF8
    $m = [regex]::Match($t, '(?m)^[\s>*-]*\**路線\**\s*[:：]\s*\**\s*(四角色|PM\s*端已完成|小問題)')
    if (-not $m.Success) { continue }
    $sRel = $s.FullName.Substring($top.Length).TrimStart('\', '/') -replace '\\', '/'
    $dirty = (& git -C $top status --porcelain -- $sRel 2>$null)
    $changed = $false
    if ($dirty) { $changed = $true }
    else {
        if ($baseRef) { & git -C $top diff --quiet "$baseRef...HEAD" -- $sRel 2>$null; if ($LASTEXITCODE -eq 1) { $changed = $true } }
    }
    if (-not $changed) { continue }
    if ($t -match '(?m)主對話直接改\s*[:：]\s*\S') { continue }
    $active += [pscustomobject]@{ Case = $s.Directory.Parent.Name; Route = ($m.Groups[1].Value -replace '\s', '') }
}
if ($active.Count -eq 0) { exit 0 }

$a = $active[0]
# 建議派誰：先比 roleHints（例 tests/ 歸 qa-expert），再比實作代理的目錄提示（pathHints），最後比副檔名。
# pathHints 比對＝任意層、從目錄邊界開始（"tests/" 對得到 tests/、src/tests/，對不到 latest/）
$pick = $roleHints | Where-Object { @($_.pathHints) | Where-Object { $_ -and (Test-PathPrefix $inProj ([string]$_) -AnyLevel) } } | Select-Object -First 1
if (-not $pick) { $pick = $implementers | Where-Object { @($_.pathHints) | Where-Object { $_ -and (Test-PathPrefix $inProj ([string]$_) -AnyLevel) } } | Select-Object -First 1 }
if (-not $pick) { $pick = $implementers | Where-Object { @($_.extensions) -contains $ext } | Select-Object -First 1 }
$who = if ($pick) { [string]$pick.agent } else { (@($implementers | ForEach-Object { $_.agent }) -join '／') }
$others = @($implementers | Where-Object { $pick -and $_.agent -ne $pick.agent } | ForEach-Object { $_.agent })
if ($others.Count) { $who += "（其他實作代理：$($others -join '／')）" }
$lines = @(
    "🔴 main-edit-guard 攔截：案子 $($a.Case) 的路線是「$($a.Route)」，產品程式要派代理改，主對話不直接改。",
    "要改的檔：$rel",
    "請派 $who，派工內容寫案子路徑 AI_Service/spec/$($a.Case)、完成條件（指令＋期望值）與熔斷（工具呼叫 100 次就停）。",
    "使用者同意主對話直接改時，在 case_spec_content/spec_001.md 加一行「主對話直接改：理由（使用者 MM-DD 同意）」。"
)
[Console]::Error.WriteLine(($lines -join "`n"))
exit 2
