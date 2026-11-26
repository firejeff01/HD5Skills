# _hd5-locate.ps1 — HD5Skills 工具共用的「找專案」邏輯（dot-source 使用）。2026-11-23。
#
# 為什麼：閘、hook、測試原本各自假設固定的相對位置（.claude/hooks、AI_Service/.agents/skills/imocore-vue3-workflow/scripts），
#   換一個專案、換一個安裝位置就靜默失效。統一用這支：從起點往上找 .claude/workflow.json，找到的那層就是專案資料夾。
#
# Get-HD5Project -Start <路徑> 回傳：
#   ConfigPath   .claude/workflow.json 的完整路徑（找不到＝$null，走舊規則猜）
#   ProjectDir   專案資料夾（.claude 的上一層）
#   Prefix       專案資料夾在 git repo 裡的路徑前綴（例 'IMOCore/'；在 repo 根＝''）
#   AiService    案子／功能地圖所在資料夾（相對專案資料夾；預設 'AI_Service'）
#   ToolsDir     HD5 工具所在資料夾的完整路徑（workflow.json 的 paths.tools；預設＝本檔所在資料夾）
#   Workflow     解析後的 workflow.json（找不到＝$null）

function Find-HD5Config([string]$Start) {
    $d = $Start
    if ($d -and (Test-Path -LiteralPath $d -PathType Leaf)) { $d = Split-Path $d -Parent }
    while ($d) {
        if ((Split-Path $d -Leaf) -eq '.claude' -and (Test-Path -LiteralPath (Join-Path $d 'workflow.json'))) { return (Join-Path $d 'workflow.json') }
        $c = Join-Path $d '.claude\workflow.json'
        if (Test-Path -LiteralPath $c) { return $c }
        $p = Split-Path $d -Parent
        if (-not $p -or $p -eq $d) { break }
        $d = $p
    }
    return $null
}

function Get-HD5GitPrefix([string]$Dir) {
    $pre = (& git -C $Dir rev-parse --show-prefix 2>$null)
    if ($LASTEXITCODE -ne 0 -or $null -eq $pre) { return $null }
    return ([string]$pre -replace '\\', '/')
}

function Get-HD5Project([string]$Start, [switch]$NoGit) {
    # -NoGit（2026-11-25）：不叫 git（Prefix 一律 $null；沒有設定檔時只用路徑規則猜專案）。
    #   質詢閘只要 Workflow，每次呼叫兩次 git 約 0.3 秒，測試情境多了以後超過 install.ps1 的 180 秒上限。
    $cfg = Find-HD5Config $Start
    $wf = $null; $projDir = $null
    if ($cfg) {
        try { $wf = Get-Content -Raw -LiteralPath $cfg -Encoding UTF8 | ConvertFrom-Json } catch { $wf = $null }
        $projDir = Split-Path (Split-Path $cfg -Parent) -Parent
    } else {
        # 沒有設定檔：舊規則——在 <專案>/.claude/… 或 <專案>/AI_Service/… 底下就取那個專案，否則取 git 根
        $full = [IO.Path]::GetFullPath($Start)
        $m = [regex]::Match($full, '^(.*?)[\\/](\.claude|AI_Service)([\\/]|$)')
        if ($m.Success) { $projDir = $m.Groups[1].Value }
        elseif (-not $NoGit) { $top = (& git -C $Start rev-parse --show-toplevel 2>$null); if ($top) { $projDir = $top -replace '/', '\' } }
    }
    $prefix = if ($projDir -and -not $NoGit) { Get-HD5GitPrefix $projDir } else { $null }
    $ai = if ($wf -and $wf.paths -and $wf.paths.aiService) { [string]$wf.paths.aiService } else { 'AI_Service' }
    $tools = if ($wf -and $wf.paths -and $wf.paths.tools -and $projDir) { Join-Path $projDir ([string]$wf.paths.tools) } else { $PSScriptRoot }
    [pscustomobject]@{ ConfigPath = $cfg; ProjectDir = $projDir; Prefix = $prefix; AiService = $ai; ToolsDir = $tools; Workflow = $wf }
}
