<#
.SYNOPSIS
  hd5-workitem 腳本共用的「找專案設定」：讀 .claude/workflow.json 的 tracker、推專案網址、找功能地圖檢查工具。

.DESCRIPTION
  由 _workitem-ops-lib.ps1／_devops-lib.ps1 以 dot-source 載入，不可直接執行。
  相容 Windows PowerShell 5.1 與 PowerShell 7；必須存成 UTF-8 with BOM。

  找設定檔：從起點往上找 .claude/workflow.json（同 hd5-workflow 的 _hd5-locate.ps1、hd5-spec-html 的 Get-SpecTrackerUrl）。
  起點：有給 -ConfigStart 就只從它往上找（找不到＝沒有設定檔）；沒給就依序 -CasePath → 目前工作目錄 → 腳本所在資料夾，第一個找得到的為準。

  workflow.json 用到的欄位：
    tracker.type               azure-devops｜none。找到設定檔但不是 azure-devops ⇒ 拒絕（本專案沒有設定 Azure DevOps）
    tracker.url                專案網址 https://host/{organization 或 collection}/{project}
    tracker.acceptanceStates   （選填）除了含「待驗收」的狀態以外，還有哪些狀態名要過工單閘，例 ["Ready for UAT"]
    paths.aiService            案子與功能地圖所在資料夾（預設 AI_Service）
    paths.tools                HD5 工具資料夾（預設 AI_Service/hd5-tools；功能地圖檢查器 _verify-map-lib.ps1 在這裡）
#>

function Find-HD5WorkflowConfig {
    param([string[]]$Starts)
    foreach ($s in @($Starts)) {
        if ([string]::IsNullOrWhiteSpace($s)) { continue }
        $d = $s
        try { $d = [IO.Path]::GetFullPath($d) } catch { continue }
        if (Test-Path -LiteralPath $d -PathType Leaf) { $d = Split-Path $d -Parent }
        while ($d) {
            if ((Split-Path $d -Leaf) -eq '.claude' -and (Test-Path -LiteralPath (Join-Path $d 'workflow.json'))) { return (Join-Path $d 'workflow.json') }
            $c = Join-Path $d '.claude\workflow.json'
            if (Test-Path -LiteralPath $c) { return $c }
            $p = Split-Path $d -Parent
            if (-not $p -or $p -eq $d) { break }
            $d = $p
        }
    }
    return $null
}

# 回傳 { ConfigPath; ProjectDir; Workflow; TrackerType; TrackerUrl; AcceptanceStates; AiService; ToolsDir }
# 找不到設定檔時 ConfigPath＝$null，其餘取預設（TrackerType＝$null 代表「沒有設定檔，不判斷」）。
function Get-HD5TrackerContext {
    param([string]$ConfigStart, [string]$CasePath, [string]$ScriptRoot)
    # 優先序：明確參數 -ConfigStart（只從它往上找，找不到就是「沒有設定檔」，不再退到其他起點）
    #        → -CasePath 往上 → 目前工作目錄往上 → 腳本位置往上
    if (-not [string]::IsNullOrWhiteSpace($ConfigStart)) { $starts = @($ConfigStart) }
    else {
        $here = $null
        try { $here = (Get-Location -PSProvider FileSystem).Path } catch { }
        $starts = @($CasePath, $here, $ScriptRoot)
    }
    $cfg = Find-HD5WorkflowConfig -Starts $starts
    $wf = $null; $proj = $null; $type = $null; $url = $null; $acc = @()
    $ai = 'AI_Service'; $tools = $null
    if ($cfg) {
        try { $wf = [IO.File]::ReadAllText($cfg, [Text.Encoding]::UTF8) | ConvertFrom-Json }
        catch { throw "讀不懂 $cfg（JSON 格式錯誤）：$($_.Exception.Message)" }
        $proj = Split-Path (Split-Path $cfg -Parent) -Parent
        $type = 'none'
        if ($wf.tracker) {
            if (-not [string]::IsNullOrWhiteSpace([string]$wf.tracker.type)) { $type = ([string]$wf.tracker.type).Trim() }
            if (-not [string]::IsNullOrWhiteSpace([string]$wf.tracker.url)) { $url = ([string]$wf.tracker.url).Trim() }
            if ($wf.tracker.acceptanceStates) { $acc = @($wf.tracker.acceptanceStates | ForEach-Object { [string]$_ } | Where-Object { $_.Trim() -ne '' }) }
        }
        if ($wf.paths -and -not [string]::IsNullOrWhiteSpace([string]$wf.paths.aiService)) { $ai = [string]$wf.paths.aiService }
        $t = 'AI_Service/hd5-tools'
        if ($wf.paths -and -not [string]::IsNullOrWhiteSpace([string]$wf.paths.tools)) { $t = [string]$wf.paths.tools }
        $tools = [IO.Path]::GetFullPath((Join-Path $proj $t))
    }
    return [pscustomobject]@{
        ConfigPath = $cfg; ProjectDir = $proj; Workflow = $wf
        TrackerType = $type; TrackerUrl = $url; AcceptanceStates = $acc
        AiService = $ai; ToolsDir = $tools
    }
}

# 找到設定檔但 tracker.type 不是 azure-devops ⇒ 拒絕。沒有設定檔（還沒導入 HD5）⇒ 放行，網址要由參數或環境變數給。
function Assert-HD5AzureDevOpsTracker {
    param([Parameter(Mandatory = $true)]$Context)
    if (-not $Context.ConfigPath) { return }
    if ($Context.TrackerType -ne 'azure-devops') {
        throw ("本專案沒有設定 Azure DevOps：$($Context.ConfigPath) 的 tracker.type＝「$($Context.TrackerType)」。" +
               "要用工單工具請先把 tracker.type 改成 azure-devops、tracker.url 填專案網址（https://host/{organization}/{project}），" +
               "或請使用者確認這個專案不走工單系統。")
    }
}

# 專案網址：-ProjectUrl → 環境變數 AZURE_DEVOPS_PROJECT_URL → workflow.json 的 tracker.url。都沒有回 $null。
function Resolve-HD5ProjectUrl {
    param([string]$ProjectUrl, $Context)
    if (-not [string]::IsNullOrWhiteSpace($ProjectUrl)) { return $ProjectUrl.Trim() }
    $e = [Environment]::GetEnvironmentVariable('AZURE_DEVOPS_PROJECT_URL')
    if (-not [string]::IsNullOrWhiteSpace($e)) { return $e.Trim() }
    if ($Context -and -not [string]::IsNullOrWhiteSpace([string]$Context.TrackerUrl)) { return ([string]$Context.TrackerUrl).Trim() }
    return $null
}

function Get-HD5MissingProjectUrlMessage {
    return ('只給工單號碼時需要專案網址（https://host/{organization 或 collection}/{project}），三種給法擇一：' +
            '-ProjectUrl 參數、環境變數 AZURE_DEVOPS_PROJECT_URL、或 .claude/workflow.json 的 tracker.url。')
}

# 功能地圖檢查器 _verify-map-lib.ps1 的位置：-ToolsDir → workflow.json 的 paths.tools → 本資料夾的上一層（安裝在 <hd5-tools>/workitem/ 時）。
# 回傳 { Path（找不到＝$null）; Searched[] }。找不到時工單閘 fail closed（擋，不放行）。
function Resolve-HD5VerifyMapLib {
    param([string]$ToolsDir, $Context, [string]$ScriptRoot)
    $cands = @()
    if (-not [string]::IsNullOrWhiteSpace($ToolsDir)) { $cands += $ToolsDir }
    elseif ($Context -and $Context.ToolsDir) { $cands += $Context.ToolsDir }
    else { if ($ScriptRoot) { $cands += (Join-Path $ScriptRoot '..') } }
    $searched = @()
    foreach ($d in $cands) {
        $p = $null
        try { $p = [IO.Path]::GetFullPath((Join-Path $d '_verify-map-lib.ps1')) } catch { continue }
        $searched += $p
        if (Test-Path -LiteralPath $p -PathType Leaf) { return [pscustomobject]@{ Path = $p; Searched = $searched } }
    }
    return [pscustomobject]@{ Path = $null; Searched = $searched }
}

# 案子根目錄（spec）：workflow.json → <專案>/<aiService>/spec；沒有設定檔回 $null（呼叫端要求 -SpecRoot）。
function Get-HD5DefaultSpecRoot {
    param($Context)
    if ($Context -and $Context.ProjectDir) { return [IO.Path]::GetFullPath((Join-Path $Context.ProjectDir (Join-Path $Context.AiService 'spec'))) }
    return $null
}

# 哪些狀態要過工單閘：狀態名含「待驗收」，或與 workflow.json 的 tracker.acceptanceStates 其中一個完全相同。
function Test-HD5StateNeedsAcceptanceGate {
    param([string]$State, [string[]]$AcceptanceStates)
    if ([string]::IsNullOrWhiteSpace($State)) { return $false }
    # 「待驗收」永遠要過閘（寧可多擋）；acceptanceStates 是再加上去的狀態名（例：英文流程的 Ready for UAT）
    if ($State -match '待驗收') { return $true }
    foreach ($s in @($AcceptanceStates | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) { if ($State.Trim() -eq $s.Trim()) { return $true } }
    return $false
}

# Windows PowerShell 5.1 預設可能沒開 TLS 1.2（雲端 Azure DevOps 只收 1.2 以上）。
function Enable-HD5Tls12 {
    if ($PSVersionTable.PSVersion.Major -ge 6) { return }
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
}
