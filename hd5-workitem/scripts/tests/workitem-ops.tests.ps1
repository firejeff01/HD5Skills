<#
.SYNOPSIS
  hd5-workitem 工單維運（workitem-ops）的離線測試：不連網、不需 PAT、不需網域。

.DESCRIPTION
  執行：pwsh -NoProfile -File <本檔>；Windows PowerShell 5.1：powershell -NoProfile -File <本檔>。最後一行要是 ALL PASSED。
  🔴 全程把 Invoke-RestMethod／Invoke-WebRequest 換成假的（global 函式優先於 cmdlet），任何未預期的呼叫直接失敗，絕不打真的 Azure DevOps。
  涵蓋：語法與 BOM、目標解析、tracker 設定（往上找 tracker.url、type≠azure-devops 拒絕、沒網址報錯、優先序）、
  認證取用順序與不印 PAT、留言 HTML、JSON Patch（含 System.History＋rev）、狀態驗證、上層鏈、
  工單閘（缺驗收結果／站上關卡未通過／功能地圖不合格／ToolsDir 找不到 fail closed／-SkipAcceptanceGate 要理由），
  以及用假 API 跑完整的 update 流程（預覽不寫入、正式寫入、history 模式）。
  需要 HD5 的功能地圖檢查器 _verify-map-lib.ps1：安裝後在上一層（<hd5-tools>/），套件原始碼在 ../../hd5-workflow/tools/。
#>
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
$scripts = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$script:fail = 0
function Check($name, $cond) { if ($cond) { Write-Host "  ok   $name" } else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:fail++ } }

Write-Host '--- parse／BOM ---'
foreach ($f in @(Get-ChildItem -LiteralPath $scripts -Filter *.ps1 -File) + @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter *.ps1 -File)) {
    $tokens = $null; $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count) { $script:fail++; Write-Host "PARSE FAIL $($f.Name)" -ForegroundColor Red; $errors | ForEach-Object { Write-Host "  $($_.Extent.StartLineNumber): $($_.Message)" } }
    else { Write-Host "parse ok  $($f.Name)" }
    $bytes = [IO.File]::ReadAllBytes($f.FullName)
    if (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) { $script:fail++; Write-Host "BOM MISSING $($f.Name)（Windows PowerShell 5.1 會把中文讀成亂碼）" -ForegroundColor Red }
}

# 功能地圖檢查器（工單閘依賴）
$vmLib = $null
foreach ($cand in (Join-Path $scripts '..\_verify-map-lib.ps1'), (Join-Path $scripts '..\..\hd5-workflow\tools\_verify-map-lib.ps1')) {
    if (Test-Path -LiteralPath $cand) { $vmLib = (Resolve-Path -LiteralPath $cand).Path; break }
}
Check '找得到功能地圖檢查器 _verify-map-lib.ps1（安裝位置或套件原始碼）' ([bool]$vmLib)
if (-not $vmLib) { Write-Host "FAILED: $($script:fail)" -ForegroundColor Red; exit 1 }

# 🔴 隔離（hermetic）：把受測腳本與檢查器複製到上層沒有 .claude/workflow.json 的暫存資料夾再測，
#    不管本測試放在套件裡還是裝進專案（專案有自己的 workflow.json），結果都一樣。
$iso = Join-Path ([IO.Path]::GetTempPath()) ("hd5wiiso_" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $iso 'tools\workitem') -Force | Out-Null
Get-ChildItem -LiteralPath $scripts -File -Force | Copy-Item -Destination (Join-Path $iso 'tools\workitem') -Force
Copy-Item -LiteralPath $vmLib -Destination (Join-Path $iso 'tools') -Force
# 退回紀錄閘要用的總帳檢查器（與功能地圖檢查器同一層；它 import check-guard-refs.mjs）
foreach ($n in 'check-rework-ledger.mjs', 'check-guard-refs.mjs') { $src = Join-Path (Split-Path -Parent $vmLib) $n; if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $iso 'tools') -Force } }
$scripts = Join-Path $iso 'tools\workitem'
$vmLib = Join-Path $iso 'tools\_verify-map-lib.ps1'
$vmDir = Split-Path -Parent $vmLib

. (Join-Path $scripts '_workitem-ops-lib.ps1')
. $vmLib

# --- 假網路：任何沒有 handler 的呼叫都直接失敗 ---------------------------------
$global:HD5Net = @()
$global:HD5NetHandler = $null
function global:Invoke-RestMethod {
    [CmdletBinding()]
    param([string]$Uri, [string]$Method = 'Get', $Body, $Headers, [string]$ContentType, [switch]$UseDefaultCredentials, [switch]$SkipCertificateCheck, [string]$OutFile, [switch]$UseBasicParsing)
    $bt = $null
    if ($Body -is [byte[]]) { $bt = [Text.Encoding]::UTF8.GetString($Body) } elseif ($null -ne $Body) { $bt = [string]$Body }
    $global:HD5Net += [pscustomobject]@{ Uri = $Uri; Method = $Method; Body = $bt; HasAuthHeader = [bool]($Headers -and $Headers.Authorization); DefaultCred = [bool]$UseDefaultCredentials; Trust = $(if ($PSVersionTable.PSVersion.Major -ge 6) { [bool]$SkipCertificateCheck } else { $cp = [System.Net.ServicePointManager]::CertificatePolicy; ($null -ne $cp -and $cp.GetType().Name -eq 'TrustAllCertsPolicy') }) }
    if ($global:HD5NetHandler) { return (& $global:HD5NetHandler $Uri $Method $bt) }
    throw 'NETWORK BLOCKED（測試不得連網）'
}
function global:Invoke-WebRequest {
    [CmdletBinding()]
    param([string]$Uri, $Headers, [string]$OutFile, [switch]$UseBasicParsing, [switch]$SkipCertificateCheck, [switch]$UseDefaultCredentials)
    $global:HD5Net += [pscustomobject]@{ Uri = $Uri; Method = 'Download'; Body = $null; HasAuthHeader = $false; DefaultCred = $false }
    throw 'NETWORK BLOCKED（測試不得連網）'
}

# 乾淨的工作目錄（往上找不到 .claude/workflow.json）；環境變數先存起來清掉
$saved = @{}
foreach ($n in 'AZURE_DEVOPS_PROJECT_URL', 'AZURE_DEVOPS_PAT', 'AZURE_DEVOPS_PAT_WRITE') { $saved[$n] = [Environment]::GetEnvironmentVariable($n); [Environment]::SetEnvironmentVariable($n, $null) }
$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ("hd5wi_" + [guid]::NewGuid().ToString('N'))
$clean = Join-Path $tmpRoot 'clean'
New-Item -ItemType Directory -Path $clean -Force | Out-Null
$origLoc = Get-Location
Set-Location -LiteralPath $clean
$utf8 = New-Object Text.UTF8Encoding($false)
function Write-Fixture([string]$path, [string]$text) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
    [IO.File]::WriteAllText($path, $text, $utf8)
}
function New-Proj([string]$name, [string]$json) {
    $p = Join-Path $tmpRoot $name
    Write-Fixture (Join-Path $p '.claude\workflow.json') $json
    return $p
}
$OrgUrl = 'https://dev.azure.com/example-org'
$ProjUrl = 'https://dev.azure.com/example-org/example-project'
$wiOps = Join-Path $scripts 'workitem-ops.ps1'

try {
Check '前提：乾淨目錄往上找不到 workflow.json（否則下面「沒網址」的測試不準）' ($null -eq (Find-HD5WorkflowConfig -Starts @($clean)))
Check '前提：隔離後的腳本位置往上找不到 workflow.json' ($null -eq (Find-HD5WorkflowConfig -Starts @($scripts)))

Write-Host '--- 設定檔起點優先序 ---'
$projP = New-Proj 'projP' ('{ "tracker": { "type": "azure-devops", "url": "https://dev.azure.com/example-org/from-param" } }')
$projW = New-Proj 'projW' ('{ "tracker": { "type": "azure-devops", "url": "https://dev.azure.com/example-org/from-cwd" } }')
Set-Location -LiteralPath $projW
Check '目前工作目錄往上找得到' ((Get-HD5TrackerContext -ScriptRoot $scripts).TrackerUrl -match 'from-cwd')
Check '-ConfigStart 優先於目前工作目錄' ((Get-HD5TrackerContext -ConfigStart $projP -ScriptRoot $scripts).TrackerUrl -match 'from-param')
Check '-ConfigStart 找不到就是沒有設定檔（不退回目前目錄／腳本位置）' ($null -eq (Get-HD5TrackerContext -ConfigStart $clean -ScriptRoot $projW).ConfigPath)
Set-Location -LiteralPath $clean
Check '目前目錄沒有時退到腳本位置往上' ((Get-HD5TrackerContext -ScriptRoot (Join-Path $projW 'AI_Service')).TrackerUrl -match 'from-cwd')

Write-Host '--- Resolve-WorkItemTarget ---'
$a = Resolve-WorkItemTarget "$ProjUrl/_workitems/edit/1432"
Check 'edit url id／project' ($a.Id -eq 1432 -and $a.Project -eq 'example-project' -and $a.Collection -eq 'example-org')
Check 'edit url projectApi／webUrl' ($a.ProjectApi -eq "$ProjUrl/_apis" -and $a.WebUrl -eq "$ProjUrl/_workitems/edit/1432")
$b = Resolve-WorkItemTarget "$ProjUrl/_sprints/backlog/example-project%20Team/example-project/Sprint%201?workitem=77"
Check 'sprint url id／project' ($b.Id -eq 77 -and $b.Project -eq 'example-project')
$c = Resolve-WorkItemTarget "$OrgUrl/_apis/wit/workItems/1528"
Check 'api url：沒有 project' ($c.Id -eq 1528 -and $null -eq $c.Project -and $c.CollectionApi -eq "$OrgUrl/_apis")
$d = Resolve-WorkItemTarget '1751' -ProjectUrl "$ProjUrl/"
Check '號碼＋-ProjectUrl（尾端斜線）' ($d.Id -eq 1751 -and $d.Project -eq 'example-project' -and $d.Collection -eq 'example-org')
$e = Resolve-WorkItemTarget '9' -ProjectUrl 'https://devops.example.com/DefaultCollection/example-project'
Check '自架 Server 形式（collection）' ($e.Origin -eq 'https://devops.example.com' -and $e.Collection -eq 'DefaultCollection')
[Environment]::SetEnvironmentVariable('AZURE_DEVOPS_PROJECT_URL', 'https://dev.azure.com/example-org/env-project')
Check '號碼＋環境變數' ((Resolve-WorkItemTarget '281').Project -eq 'env-project')
[Environment]::SetEnvironmentVariable('AZURE_DEVOPS_PROJECT_URL', $null)
$threw = $false; $msg = ''; try { Resolve-WorkItemTarget '281' | Out-Null } catch { $threw = $true; $msg = $_.Exception.Message }
Check '沒網址：清楚報錯並列出三種給法' ($threw -and $msg -match '-ProjectUrl' -and $msg -match 'AZURE_DEVOPS_PROJECT_URL' -and $msg -match 'tracker\.url')
$threw = $false; try { Resolve-WorkItemTarget 'https://x/y' | Out-Null } catch { $threw = $true }
Check '亂網址報錯' $threw
$threw = $false; try { Resolve-WorkItemTarget '5' -ProjectUrl $OrgUrl | Out-Null } catch { $threw = $true }
Check '專案網址缺 project 段報錯' $threw
$fake = [pscustomobject]@{ id = 1528; fields = [pscustomobject]@{ 'System.TeamProject' = 'example-project' } }
$r = Resolve-WorkItemProject -Target $c -WorkItem $fake
Check '用 TeamProject 補 project' ($r.Project -eq 'example-project' -and $r.ProjectApi -like '*/example-project/_apis')

Write-Host '--- tracker 設定（.claude/workflow.json）---'
$projA = New-Proj 'projA' ('{ "paths": { "aiService": "AI_Service", "tools": "AI_Service/hd5-tools" }, "tracker": { "type": "azure-devops", "url": "' + $ProjUrl + '" } }')
$deep = Join-Path $projA 'AI_Service\spec\case-x\qa'
New-Item -ItemType Directory -Path $deep -Force | Out-Null
$ctxA = Get-HD5TrackerContext -ConfigStart $deep
Check 'tracker.url 從深層資料夾往上找得到' ($ctxA.ConfigPath -like '*projA*workflow.json' -and $ctxA.TrackerUrl -eq $ProjUrl -and $ctxA.TrackerType -eq 'azure-devops')
Check 'ToolsDir 由 paths.tools 推' ($ctxA.ToolsDir -eq [IO.Path]::GetFullPath((Join-Path $projA 'AI_Service\hd5-tools')))
Check '從 .claude 資料夾本身起找也行' ((Get-HD5TrackerContext -ConfigStart (Join-Path $projA '.claude')).TrackerUrl -eq $ProjUrl)
Check '號碼＋workflow.json 的 tracker.url' ((Resolve-WorkItemTarget '42' -Context $ctxA).Project -eq 'example-project')
[Environment]::SetEnvironmentVariable('AZURE_DEVOPS_PROJECT_URL', 'https://dev.azure.com/example-org/env-project')
Check '優先序：環境變數 > tracker.url' ((Resolve-WorkItemTarget '42' -Context $ctxA).Project -eq 'env-project')
Check '優先序：-ProjectUrl > 環境變數' ((Resolve-WorkItemTarget '42' -Context $ctxA -ProjectUrl 'https://dev.azure.com/example-org/param-project').Project -eq 'param-project')
[Environment]::SetEnvironmentVariable('AZURE_DEVOPS_PROJECT_URL', $null)
$threw = $false; try { Assert-HD5AzureDevOpsTracker -Context $ctxA } catch { $threw = $true }
Check 'type＝azure-devops 放行' (-not $threw)
$projN = New-Proj 'projN' '{ "tracker": { "type": "none", "url": "" } }'
$ctxN = Get-HD5TrackerContext -ConfigStart $projN
$threw = $false; $msg = ''; try { Assert-HD5AzureDevOpsTracker -Context $ctxN } catch { $threw = $true; $msg = $_.Exception.Message }
Check 'type＝none 拒絕：「本專案沒有設定 Azure DevOps」' ($threw -and $msg -match '本專案沒有設定 Azure DevOps')
$projJ = New-Proj 'projJ' '{ "tracker": { "type": "jira", "url": "https://jira.example.com/x" } }'
$threw = $false; try { Assert-HD5AzureDevOpsTracker -Context (Get-HD5TrackerContext -ConfigStart $projJ) } catch { $threw = $true }
Check 'type＝其他工單系統也拒絕' $threw
$projT = New-Proj 'projT' '{ "paths": {} }'
$threw = $false; try { Assert-HD5AzureDevOpsTracker -Context (Get-HD5TrackerContext -ConfigStart $projT) } catch { $threw = $true }
Check '沒有 tracker 欄位＝視同 none，拒絕' $threw
$threw = $false; try { Assert-HD5AzureDevOpsTracker -Context (Get-HD5TrackerContext -ConfigStart $clean) } catch { $threw = $true }
Check '沒有設定檔（還沒導入）不拒絕，網址改由參數／環境變數給' (-not $threw)
$global:HD5Net = @()
$threw = $false; $msg = ''
try { & $wiOps "$ProjUrl/_workitems/edit/5" -ConfigStart $projN 6>$null } catch { $threw = $true; $msg = $_.Exception.Message }
Check 'workitem-ops：type＝none 連完整網址也拒絕，且沒有任何網路呼叫' ($threw -and $msg -match '本專案沒有設定 Azure DevOps' -and $global:HD5Net.Count -eq 0)
$threw = $false; $msg = ''
try { & $wiOps '5' -ConfigStart $clean 6>$null } catch { $threw = $true; $msg = $_.Exception.Message }
Check 'workitem-ops：沒網址在連網前報錯' ($threw -and $msg -match 'tracker\.url' -and $global:HD5Net.Count -eq 0)

Write-Host '--- 哪些狀態要過閘 ---'
Check '待驗收要過閘' (Test-DevOpsStateNeedsAcceptanceGate '待驗收')
Check '進行中／空白不用' (-not (Test-DevOpsStateNeedsAcceptanceGate '進行中') -and -not (Test-DevOpsStateNeedsAcceptanceGate ''))
Check 'acceptanceStates 列的狀態要過閘' (Test-DevOpsStateNeedsAcceptanceGate 'Ready for UAT' -AcceptanceStates @('Ready for UAT'))
Check '有 acceptanceStates 時「待驗收」仍要過閘' (Test-DevOpsStateNeedsAcceptanceGate '待驗收' -AcceptanceStates @('Ready for UAT'))
$projS = New-Proj 'projS' ('{ "tracker": { "type": "azure-devops", "url": "' + $ProjUrl + '", "acceptanceStates": ["Ready for UAT"] } }')
Check 'acceptanceStates 從 workflow.json 讀' (@((Get-HD5TrackerContext -ConfigStart $projS).AcceptanceStates) -contains 'Ready for UAT')

Write-Host '--- 認證 ---'
$patDir = Join-Path $tmpRoot 'patdir'; New-Item -ItemType Directory -Path $patDir -Force | Out-Null
$x = New-DevOpsAuthContext -ScriptRoot $patDir
Check '預設 Windows 整合驗證' ($x.Mode -eq 'Windows' -and $x.Headers.Count -eq 0)
$x = New-DevOpsAuthContext -Pat ' abc ' -ScriptRoot $patDir
Check '-Pat 優先且去空白' ($x.Mode -eq 'PAT' -and $x.Headers.Authorization -eq ('Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(':abc'))))
Check '來源說明不含 PAT' ($x.Source -notmatch 'abc')
[Environment]::SetEnvironmentVariable('AZURE_DEVOPS_PAT', 'envpat')
$x = New-DevOpsAuthContext -ScriptRoot $patDir
Check '環境變數 PAT' ($x.Mode -eq 'PAT' -and $x.Source -eq '環境變數 AZURE_DEVOPS_PAT')
Check '-ForceWindows 蓋過環境變數' ((New-DevOpsAuthContext -ScriptRoot $patDir -ForceWindows).Mode -eq 'Windows')
[Environment]::SetEnvironmentVariable('AZURE_DEVOPS_PAT', $null)
Write-Fixture (Join-Path $patDir 'pat.local.txt') "# 註解`n`nfilepat`n"
$x = New-DevOpsAuthContext -ScriptRoot $patDir
Check 'pat.local.txt 略過註解與空行' ($x.Mode -eq 'PAT' -and $x.Source -eq '檔案 pat.local.txt' -and $x.Headers.Authorization -eq ('Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(':filepat'))))
Write-Fixture (Join-Path $patDir 'pat.write.local.txt') "writepat"
Check '寫入（-Write）：pat.write.local.txt 先於 pat.local.txt' ((New-DevOpsAuthContext -ScriptRoot $patDir -Write).Source -eq '檔案 pat.write.local.txt')
Check '唯讀：不看 pat.write.local.txt' ((New-DevOpsAuthContext -ScriptRoot $patDir).Source -eq '檔案 pat.local.txt')
$custom = Join-Path $tmpRoot 'my-secret.pat.txt'; Write-Fixture $custom 'custompat'
$x = New-DevOpsAuthContext -ScriptRoot $patDir -PatFile $custom
Check '-PatFile 先於資料夾內的 pat 檔' ($x.Source -eq '檔案 my-secret.pat.txt' -and $x.Headers.Authorization -eq ('Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(':custompat'))))
$threw = $false; try { New-DevOpsAuthContext -ScriptRoot $patDir -PatFile (Join-Path $tmpRoot 'nope.txt') | Out-Null } catch { $threw = $true }
Check '-PatFile 不存在就報錯（不默默改走別的認證）' $threw

$noPat = Join-Path $tmpRoot 'nopat'; New-Item -ItemType Directory -Path $noPat -Force | Out-Null
Check '沒 PAT＋自架網址：Windows 整合驗證' ((New-DevOpsAuthContext -ScriptRoot $noPat -TargetUrl 'https://devops.example.com/DefaultCollection').Mode -eq 'Windows')
$threw = $false; $msg = ''; try { New-DevOpsAuthContext -ScriptRoot $noPat -TargetUrl $OrgUrl | Out-Null } catch { $threw = $true; $msg = $_.Exception.Message }
Check '沒 PAT＋雲端網址（dev.azure.com）：報錯要 PAT，附該組織申請網址' ($threw -and $msg -match '雲端' -and $msg -match [regex]::Escape("$OrgUrl/_usersSettings/tokens"))
$threw = $false; try { New-DevOpsAuthContext -ScriptRoot $noPat -TargetUrl 'https://example-org.visualstudio.com/DefaultCollection' | Out-Null } catch { $threw = $true }
Check '沒 PAT＋*.visualstudio.com：報錯' $threw
$threw = $false; try { New-DevOpsAuthContext -ScriptRoot $noPat -TargetUrl $OrgUrl -ForceWindows | Out-Null } catch { $threw = $true }
Check '雲端＋-UseWindowsAuth：報錯' $threw
Check '雲端＋有 PAT：用 PAT' ((New-DevOpsAuthContext -ScriptRoot $noPat -TargetUrl $OrgUrl -Pat 'p').Mode -eq 'PAT')

Write-Host '--- 留言 HTML／JSON Patch ---'
Check '純文字編碼＋換行' ((ConvertTo-DevOpsCommentHtml -Text "a<b>&`r`n第二行") -eq "a&lt;b&gt;&amp;<br/>`n第二行")
Check '-Html 原樣' ((ConvertTo-DevOpsCommentHtml -Text '<b>x</b>' -Html) -eq '<b>x</b>')
Check 'null 安全' ((ConvertTo-DevOpsCommentHtml -Text $null) -eq '')
Check '沒東西＝null' ($null -eq (New-DevOpsPatchBody))
$p1 = New-DevOpsPatchBody -State '待驗收'
Check '單一 op 仍是陣列' ($p1.StartsWith('[') -and $p1.EndsWith(']') -and $p1 -match '"path":"/fields/System.State"')
$parsed = (New-DevOpsPatchBody -AssignTo 'someone@example.com' -State '待驗收') | ConvertFrom-Json
Check '兩個 op' (@($parsed).Count -eq 2 -and $parsed[0].path -eq '/fields/System.AssignedTo' -and $parsed[0].value -eq 'someone@example.com')
$ph = (New-DevOpsPatchBody -HistoryHtml '<b>留言</b>' -Rev 7) | ConvertFrom-Json
Check 'System.History＋rev 檢查（test 在最前面）' (@($ph).Count -eq 2 -and $ph[0].op -eq 'test' -and $ph[0].path -eq '/rev' -and $ph[0].value -eq 7 -and $ph[1].path -eq '/fields/System.History' -and $ph[1].value -eq '<b>留言</b>')
Check '只有 rev 沒內容＝null' ($null -eq (New-DevOpsPatchBody -Rev 7))

Write-Host '--- 狀態／上層鏈／顯示 ---'
$states = @([pscustomobject]@{ Name = '待驗收'; Category = 'Resolved' }, [pscustomobject]@{ Name = '完成'; Category = 'Completed' })
Check 'allowed' (Test-DevOpsStateAllowed -State '待驗收' -States $states)
Check 'not allowed' (-not (Test-DevOpsStateAllowed -State '驗收未過' -States $states))
Check 'empty list' (-not (Test-DevOpsStateAllowed -State 'x' -States @()))
function New-FakeItem($id, $parentId, $state = 's', $type = 'Task') {
    $rel = @()
    if ($parentId) { $rel += [pscustomobject]@{ rel = 'System.LinkTypes.Hierarchy-Reverse'; url = "$OrgUrl/_apis/wit/workItems/$parentId" } }
    $rel += [pscustomobject]@{ rel = 'AttachedFile'; url = "$OrgUrl/_apis/wit/attachments/1"; attributes = [pscustomobject]@{ name = 'a.md' } }
    return [pscustomobject]@{ id = $id; rev = 5; fields = [pscustomobject]@{ 'System.Title' = "t$id"; 'System.WorkItemType' = $type; 'System.State' = $state; 'System.TeamProject' = 'example-project'; 'System.AssignedTo' = $null }; relations = $rel }
}
$db = @{ 1432 = (New-FakeItem 1432 1528); 1528 = (New-FakeItem 1528 1); 1 = (New-FakeItem 1 $null) }
$loader = { param($id) $db[[int]$id] }
Check 'parent id' ((Get-DevOpsParentId -WorkItem $db[1432]) -eq 1528)
Check 'no parent -> 0' ((Get-DevOpsParentId -WorkItem $db[1]) -eq 0)
$chain = @(Get-DevOpsAncestors -WorkItem $db[1432] -Loader $loader)
Check '走到頂' ($chain.Count -eq 2 -and $chain[0].id -eq 1528 -and $chain[1].id -eq 1)
Check 'MaxDepth 截斷' (@(Get-DevOpsAncestors -WorkItem $db[1432] -Loader $loader -MaxDepth 1).Count -eq 1)
$loop = @{ 10 = (New-FakeItem 10 20); 20 = (New-FakeItem 20 10) }
$chain = @(Get-DevOpsAncestors -WorkItem $loop[10] -Loader { param($id) $loop[[int]$id] })
Check '防循環' ($chain.Count -eq 1 -and $chain[0].id -eq 20)
Check '父工單讀不到就停' (@(Get-DevOpsAncestors -WorkItem (New-FakeItem 7 999) -Loader { param($id) $null }).Count -eq 0)
$line = Format-DevOpsWorkItemLine ([pscustomobject]@{ id = 5; fields = [pscustomobject]@{ 'System.WorkItemType' = 'Bug'; 'System.Title' = 'T'; 'System.State' = 'S'; 'System.AssignedTo' = $null } })
Check '未指派標示' ($line -eq '#5 [Bug] T｜狀態 S｜指派 （未指派）')

Write-Host '--- 工單閘：總結行判讀 ---'
$featBody = "# 功能`n使用者可見行為。`n## 子功能（Sub-features）`n- a`n## 使用者怎麼到達（How to get to it）`n選單 → A`n## 怎麼操作（Driving it）`n前提：已登入`n1. 點 A → 看到 B`n## 地雷（Gotchas）`n- 無`n"
$docBody = "# verify-x`n## 啟動（Launch）`nx`n## 體檢（Doctor）`nx`n## 操作（Drive）`nx`n## 證據（Evidence）`nx`n## 清理（Cleanup）`nx`n## 工具腳本（Helpers）`nx`n"
function New-VerifyMap([string]$verifyRoot, [string[]]$ids = @('login', 'list', 'edit'), [string]$doc = $docBody) {
    Write-Fixture (Join-Path $verifyRoot 'verify-x.md') $doc
    Write-Fixture (Join-Path $verifyRoot 'features/README.md') "# 功能地圖`n共同前提"
    foreach ($id in $ids) { Write-Fixture (Join-Path $verifyRoot "features/$id.md") $featBody }
}
# 案子放在 <tmp>/gN/AI_Service/spec/case；預設附一份合格功能地圖（<tmp>/gN/AI_Service/verify）。
# 只測總結邏輯的站上關卡報告自動補舊日期（早於證據新格式生效日，不受證據規則影響）。
$script:gi = 0
function New-GateCase([hashtable]$files, [switch]$NoMap, [switch]$BadMap) {
    $script:gi++
    $root = Join-Path $tmpRoot "g$($script:gi)\AI_Service\spec\case"
    New-Item -ItemType Directory -Path (Join-Path $root 'qa') -Force | Out-Null
    foreach ($k in $files.Keys) {
        $t = $files[$k]
        if ($k -like 'onsite-gate*' -and $t -notmatch '日期' -and $t -notmatch '## A\.') { $t = "- 日期：2026-11-20 10:00`n" + $t }
        Write-Fixture (Join-Path $root "qa/$k") $t
    }
    $vr = Join-Path $tmpRoot "g$($script:gi)\AI_Service\verify"
    if ($BadMap) { New-VerifyMap $vr -ids @('login', 'list') }
    elseif (-not $NoMap) { New-VerifyMap $vr }
    return $root
}
function Gate([string]$c) { Test-DevOpsAcceptanceGate -CasePath $c -VerifyLibPath $vmLib }
$g = Gate (New-GateCase @{ 'Codex驗收結果_R1.md' = "x`n總結：通過`n"; 'onsite-gate_R1.md' = "y`n總結：通過`n`n" })
Check '兩關都通過（結尾空行忽略）' ($g.Passed)
$caseOk = New-GateCase @{ 'Codex驗收結果_R1.md' = "總結：通過"; 'onsite-gate_R1.md' = "總結：通過" }
Check '取最新一輪（R1 不通過、R2 通過）' ((Gate (New-GateCase @{ 'Codex驗收結果_R1.md' = "總結：不通過（P0 0／P1 2／P2 1）"; 'Codex驗收結果_R2.md' = "總結：通過"; 'onsite-gate_R1.md' = "總結：通過" })).Passed)
Check 'Codex／Claude 合併取最大輪次；站上關卡取最新' ((Gate (New-GateCase @{ 'Codex驗收結果_R1.md' = "總結：不通過（P0 0／P1 1／P2 0）"; 'Claude驗收結果_R2.md' = "總結：通過"; 'onsite-gate_R2.md' = "總結：通過"; 'onsite-gate_R1.md' = "總結：不通過" })).Passed)
$g = Gate (New-GateCase @{ 'Codex驗收結果_R1.md' = "總結：通過"; 'Codex驗收結果_R2.md' = "總結：不通過（P0 0／P1 1／P2 0）"; 'onsite-gate_R1.md' = "總結：通過" })
Check '最新一輪不通過就擋（即使舊輪通過）' (-not $g.Passed -and ($g.Reasons -join ' ') -match 'R2')
$caseNoOnsite = New-GateCase @{ 'Codex驗收結果_R1.md' = "總結：通過" }
$g = Gate $caseNoOnsite
Check '缺站上關卡報告就擋' (-not $g.Passed -and ($g.Reasons -join ' ') -match '站上關卡')
$g = Gate (New-GateCase @{ 'onsite-gate_R1.md' = "總結：通過" })
Check '缺獨立驗收結果就擋' (-not $g.Passed -and ($g.Reasons -join ' ') -match '缺獨立驗收')
$caseOnsiteFail = New-GateCase @{ 'Codex驗收結果_R1.md' = "總結：通過"; 'onsite-gate_R1.md' = "總結：不通過（AC-2 Fail）" }
$g = Gate $caseOnsiteFail
Check '站上關卡未通過就擋' (-not $g.Passed -and ($g.Reasons -join ' ') -match '站上關卡最新一輪')
Check '「有條件通過」不算通過' (-not (Gate (New-GateCase @{ 'Codex驗收結果_R1.md' = "總結：有條件通過"; 'onsite-gate_R1.md' = "總結：通過" })).Passed)
Check '總結後接「新發現」、粗體＋附註都認得' ((Gate (New-GateCase @{ 'Codex驗收結果_R1.md' = "總結：通過`n新發現：0 筆"; 'onsite-gate_R1.md' = "總結：**通過**（5/5 Pass）" })).Passed)
Check '檔內多個總結取最後一個' (-not (Gate (New-GateCase @{ 'Codex驗收結果_R1.md' = "總結：通過`n...`n總結：不通過（P0 0／P1 1／P2 0）"; 'onsite-gate_R1.md' = "總結：通過" })).Passed)
Check '只剩 P2 的不通過放行（只修 P1）' ((Gate (New-GateCase @{ 'Codex驗收結果_R1.md' = "總結：不通過（P0 0／P1 0／P2 2）"; 'onsite-gate_R1.md' = "總結：通過" })).Passed)
Check 'P0×0、P1×0 寫法也認得' ((Gate (New-GateCase @{ 'Codex驗收結果_R1.md' = "總結：不通過（P0×0、P1×0、P2×1）"; 'onsite-gate_R1.md' = "總結：通過" })).Passed)
Check '有 P1 就擋' (-not (Gate (New-GateCase @{ 'Codex驗收結果_R1.md' = "總結：不通過（P0×0、P1×1、P2×2）"; 'onsite-gate_R1.md' = "總結：通過" })).Passed)
Check '沒有總結行就擋' (-not (Gate (New-GateCase @{ 'Codex驗收結果_R1.md' = "審查內容，沒有總結行"; 'onsite-gate_R1.md' = "總結：通過" })).Passed)
Check '案子資料夾不存在就擋' (-not (Test-DevOpsAcceptanceGate -CasePath (Join-Path $tmpRoot 'no\such\case') -VerifyLibPath $vmLib).Passed)
Check '輪次用數字比（R10 > R9）' ((Gate (New-GateCase @{ 'Codex驗收結果_R10.md' = "總結：通過"; 'Codex驗收結果_R9.md' = "總結：不通過（P0 0／P1 1／P2 0）"; 'onsite-gate_R1.md' = "總結：通過" })).Passed)
Check '認得 _{案號}_ 中綴' ((Gate (New-GateCase @{ 'Codex驗收結果_123_R10.md' = "總結：通過"; 'Codex驗收結果_123_R9.md' = "總結：不通過（P0×0、P1×1、P2×0）"; 'onsite-gate_R3.md' = "總結：通過" })).Passed)
Check '.raw.md 不算結果檔' (-not (Gate (New-GateCase @{ 'Codex驗收結果_R2.raw.md' = "總結：通過"; 'onsite-gate_R1.md' = "總結：通過" })).Passed)
$c = New-GateCase @{ 'onsite-gate_R1.md' = "總結：通過" }
Write-Fixture (Join-Path $c 'qa/codex/Codex驗收結果_R2.md') "總結：通過"
$g = Gate $c
Check '子目錄不認，但提示搬到 qa/ 根目錄' (-not $g.Passed -and ($g.Reasons -join ' ') -match 'codex[\\/]Codex驗收結果_R2\.md')
$g = Gate (New-GateCase @{ 'Codex驗收結果_R1.md' = "總結：受阻（缺實跑結果）"; 'onsite-gate_R1.md' = "總結：通過" })
Check '受阻擋，並提示重送同一輪 R1b' (-not $g.Passed -and ($g.Reasons -join ' ') -match 'R1b')
Check 'R1 受阻、R1b 通過 ⇒ 放行' ((Gate (New-GateCase @{ 'Codex驗收結果_R1.md' = "總結：受阻"; 'Codex驗收結果_R1b.md' = "總結：通過"; 'onsite-gate_R1.md' = "總結：通過" })).Passed)
$g = Gate (New-GateCase @{ 'Codex驗收結果_R1.md' = "總結：通過"; 'onsite-gate_R1.md' = "總結：通過"; 'onsite-gate_R1b.md' = "總結：受阻（站上不是這一版）" })
Check 'R1b 比 R1 新' (-not $g.Passed -and ($g.Reasons -join ' ') -match 'onsite-gate_R1b\.md')
Check 'R2 比 R1b 新' (-not (Gate (New-GateCase @{ 'Codex驗收結果_R1b.md' = "總結：通過"; 'Codex驗收結果_R2.md' = "總結：不通過（P0 0／P1 1／P2 0）"; 'onsite-gate_R1.md' = "總結：通過" })).Passed)
Check 'R1c 比 R1b 新' ((Gate (New-GateCase @{ 'Codex驗收結果_R1.md' = "總結：受阻"; 'Codex驗收結果_R1b.md' = "總結：受阻"; 'Codex驗收結果_R1c.md' = "總結：通過"; 'onsite-gate_R1.md' = "總結：通過" })).Passed)
Check '大寫 R1B 不認' (-not (Gate (New-GateCase @{ 'Codex驗收結果_R1B.md' = "總結：通過"; 'Codex驗收結果_R1.md' = "總結：受阻"; 'onsite-gate_R1.md' = "總結：通過" })).Passed)

Write-Host '--- 工單閘：功能地圖／站上關卡證據／fail closed ---'
$caseNoMap = New-GateCase @{ 'Codex驗收結果_R1.md' = "總結：通過"; 'onsite-gate_R1.md' = "總結：通過" } -NoMap
$g = Gate $caseNoMap
Check '沒有功能地圖＝擋（即使兩關都通過）' (-not $g.Passed -and ($g.Reasons -join ' ') -match '功能地圖：這個專案還沒有功能地圖')
$caseBadMap = New-GateCase @{ 'Codex驗收結果_R1.md' = "總結：通過"; 'onsite-gate_R1.md' = "總結：通過" } -BadMap
$g = Gate $caseBadMap
Check '功能地圖不合格（功能少於 3 個）＝擋' (-not $g.Passed -and ($g.Reasons -join ' ') -match '^功能地圖：')
$g = Test-DevOpsAcceptanceGate -CasePath $caseOk -VerifyLibPath '' -VerifyLibSearched @('X:\nowhere\_verify-map-lib.ps1')
Check '檢查器路徑空白＝fail closed（函式已載入也一樣擋）' (-not $g.Passed -and ($g.Reasons -join ' ') -match 'fail closed' -and ($g.Reasons -join ' ') -match 'nowhere')
$g = Test-DevOpsAcceptanceGate -CasePath $caseOk -VerifyLibPath (Join-Path $tmpRoot 'missing\_verify-map-lib.ps1')
Check '檢查器檔案不存在＝fail closed' (-not $g.Passed -and ($g.Reasons -join ' ') -match 'fail closed')
$okOnsite = "# x R1`n- 日期：2026-11-23 10:00`n`n## A. 驗收項目`n| 項目 | 功能 | 結果 | 證據 | 備註 |`n|---|---|---|---|---|`n| AC-1 清單 | list | Pass | ac1.png | |`n| AC-2 存檔 | edit | Pass | 查詢：SELECT 回 1 筆 | |`n| AC-3 匯出 | list | 未驗證 | — | 缺資料 |`n| AC-4 X | — | 不適用 | — | 理由 |`n`n## B. 平台契約`n| 類別 | 適用 | 結果 | 證據 |`n|---|---|---|---|`n`n新發現：0 筆`n總結：通過`n"
function New-EvCase([string]$onsite, [string[]]$evFiles = @('ac1.png')) {
    $c = New-GateCase @{ 'Codex驗收結果_R1.md' = '總結：通過'; 'onsite-gate_R1.md' = $onsite }
    foreach ($e in $evFiles) { Write-Fixture (Join-Path $c "qa/onsite-gate_R1/$e") 'x' }
    return $c
}
$caseEvOk = New-EvCase $okOnsite
$g = Gate $caseEvOk
Check '新格式全對＝通過' ($g.Passed -and ($g.Details -join ' ') -match 'Pass 都有證據')
$g = Gate (New-EvCase $okOnsite -evFiles @())
Check '證據檔不存在擋' (-not $g.Passed -and ($g.Reasons -join ' ') -match 'ac1\.png 不存在')
$g = Gate (New-EvCase ($okOnsite -replace '\| list \| Pass \| ac1\.png', '| list | Pass | 已確認'))
Check 'Pass 只寫「已確認」擋' (-not $g.Passed)
$g = Gate (New-EvCase ($okOnsite -replace '\| AC-1 清單 \| list', '| AC-1 清單 | report'))
Check 'A 表功能不在地圖擋' (-not $g.Passed -and ($g.Reasons -join ' ') -match 'report')
$g = Gate (New-EvCase ($okOnsite -replace '\| 項目 \| 功能 \| 結果', '| 項目 | 結果'))
Check 'A 表缺功能欄擋' (-not $g.Passed)
$g = Gate (New-EvCase ($okOnsite -replace '2026-11-23', '2026-11-18') -evFiles @())
Check '生效日前的舊報告不回溯' ($g.Passed -and ($g.Details -join ' ') -match '早於新格式生效日')
$c = New-EvCase $okOnsite -evFiles @(); Write-Fixture (Join-Path $c 'qa/ac1.png') 'x'
Check '證據檔放 qa/ 根目錄也認' ((Gate $c).Passed)

Write-Host '--- workitem-ops.ps1 工單閘前置檢查（不連網）---'
$global:HD5Net = @()
function Run-Ops([object[]]$argv) {
    # 陣列 splat 不會把 '-Action' 當參數名，轉成 hashtable：第一個是工單，其後 -名稱 值；後面沒有值的是開關
    $h = @{ WorkItem = [string]$argv[0] }
    for ($i = 1; $i -lt $argv.Count; $i++) {
        $k = ([string]$argv[$i]).TrimStart('-')
        if ($i + 1 -lt $argv.Count -and -not ([string]$argv[$i + 1]).StartsWith('-')) { $h[$k] = $argv[$i + 1]; $i++ } else { $h[$k] = $true }
    }
    $r = [pscustomobject]@{ Threw = $false; Msg = ''; Out = '' }
    try { $r.Out = (& $wiOps @h *>&1 | Out-String) } catch { $r.Threw = $true; $r.Msg = $_.Exception.Message }
    return $r
}
$r = Run-Ops @('99', '-Action', 'update', '-State', '待驗收', '-ConfigStart', $clean)
Check '待驗收沒給 -CasePath：連網前就擋' ($r.Threw -and $r.Msg -match 'CasePath' -and $r.Msg -notmatch 'tracker\.url')
$r = Run-Ops @('99', '-Action', 'update', '-State', '待驗收', '-CasePath', $caseNoOnsite, '-ToolsDir', $vmDir)
Check '缺站上關卡報告：擋並列原因' ($r.Threw -and $r.Msg -match '工單閘未通過' -and $r.Msg -match '站上關卡')
$r = Run-Ops @('99', '-Action', 'update', '-State', '待驗收', '-CasePath', $caseOnsiteFail, '-ToolsDir', $vmDir)
Check '站上關卡未通過：擋' ($r.Threw -and $r.Msg -match '工單閘未通過')
$r = Run-Ops @('99', '-Action', 'update', '-State', '待驗收', '-CasePath', $caseBadMap, '-ToolsDir', $vmDir)
Check '功能地圖不合格：擋' ($r.Threw -and $r.Msg -match '工單閘未通過' -and $r.Msg -match '功能地圖')
$emptyTools = Join-Path $tmpRoot 'empty-tools'; New-Item -ItemType Directory -Path $emptyTools -Force | Out-Null
$r = Run-Ops @('99', '-Action', 'update', '-State', '待驗收', '-CasePath', $caseEvOk, '-ToolsDir', $emptyTools)
Check 'ToolsDir 找不到檢查器：fail closed（關卡全過也擋）' ($r.Threw -and $r.Msg -match 'fail closed' -and $r.Msg -match 'empty-tools')
$projBadTools = New-Proj 'projBadTools' ('{ "paths": { "tools": "no-such-tools" }, "tracker": { "type": "azure-devops", "url": "' + $ProjUrl + '" } }')
$r = Run-Ops @('99', '-Action', 'update', '-State', '待驗收', '-CasePath', $caseEvOk, '-ConfigStart', $projBadTools)
Check 'workflow.json 的 paths.tools 不存在：fail closed' ($r.Threw -and $r.Msg -match 'fail closed' -and $r.Msg -match 'no-such-tools')
$r = Run-Ops @('99', '-Action', 'update', '-State', '待驗收', '-CasePath', $caseEvOk, '-ToolsDir', $vmDir, '-ConfigStart', $clean)
Check '關卡全過：往下走到專案網址檢查（沒網址才停）' ($r.Threw -and $r.Msg -match 'tracker\.url')
$r = Run-Ops @('99', '-Action', 'update', '-State', '待驗收', '-SkipAcceptanceGate', '緊急修正無案子，使用者同意', '-ConfigStart', $clean)
Check '-SkipAcceptanceGate 帶理由：放行並印出理由' ($r.Threw -and $r.Msg -match 'tracker\.url')
$r2 = Run-Ops @('99', '-Action', 'update', '-State', '待驗收', '-SkipAcceptanceGate', '   ', '-ConfigStart', $clean)
Check '-SkipAcceptanceGate 理由空白：不放行' ($r2.Threw -and $r2.Msg -match 'CasePath')
$r = Run-Ops @('99', '-Action', 'update', '-State', '待驗收', '-CasePath', $caseNoOnsite, '-ToolsDir', $vmDir, '-WhatIfOnly', '-ConfigStart', $clean)
Check '-WhatIfOnly 預覽不被關卡擋（只警告）' ($r.Threw -and $r.Msg -match 'tracker\.url')
$r = Run-Ops @('99', '-Action', 'update', '-State', '進行中', '-ConfigStart', $clean)
Check '非待驗收狀態不需要 CasePath' ($r.Threw -and $r.Msg -match 'tracker\.url')
$r = Run-Ops @('99', '-Action', 'update', '-State', 'Ready for UAT', '-ConfigStart', $projS)
Check 'acceptanceStates 列的狀態一樣要 CasePath' ($r.Threw -and $r.Msg -match 'CasePath')
Check '以上全部沒有任何網路呼叫' ($global:HD5Net.Count -eq 0)

Write-Host '--- workitem-ops.ps1 完整流程（假 API）---'
$global:HD5NetHandler = {
    param($Uri, $Method, $BodyText)
    if ($Method -eq 'Get' -and $Uri -match '/wit/workitems/(\d+)\?') { return (New-FakeItem ([int]$Matches[1]) $null '進行中') }
    if ($Uri -match '/workitemtypes/[^/]+/states') { return [pscustomobject]@{ value = @([pscustomobject]@{ name = '進行中'; category = 'InProgress' }, [pscustomobject]@{ name = '待驗收'; category = 'Resolved' }, [pscustomobject]@{ name = '驗收完成'; category = 'Completed' }) } }
    if ($Method -eq 'Get' -and $Uri -match '/workItems/\d+/updates\?') { return [pscustomobject]@{ count = @($global:HD5Updates).Count; value = @($global:HD5Updates) } }
    if ($Method -eq 'Post' -and $Uri -match '/comments\?') { return [pscustomobject]@{ id = 777 } }
    if ($Method -eq 'Get' -and $Uri -match '/comments\?') { return [pscustomobject]@{ comments = @() } }
    if ($Method -eq 'Patch') { return [pscustomobject]@{ id = 42; fields = [pscustomobject]@{ 'System.State' = '待驗收'; 'System.AssignedTo' = [pscustomobject]@{ displayName = 'Someone' } } } }
    throw "未預期的呼叫：$Method $Uri"
}
$common = @('42', '-Action', 'update', '-State', '待驗收', '-CasePath', $caseEvOk, '-ToolsDir', $vmDir, '-ConfigStart', $projA, '-VerifyRoot', ([IO.Path]::GetFullPath((Join-Path $caseEvOk '..\..\verify'))), '-Comment', "第一行`n第二行", '-AssignTo', 'someone@example.com')
$global:HD5Net = @()
$r = Run-Ops ($common + @('-WhatIfOnly', '-Pat', 'SECRETPAT123'))
Check '預覽：成功、目標來自 tracker.url' (-not $r.Threw -and $r.Out -match '即將套用' -and @($global:HD5Net | Where-Object { $_.Uri -like "$ProjUrl/_apis/*" }).Count -gt 0)
Check '預覽：只有讀取，沒有 POST／PATCH' (@($global:HD5Net | Where-Object { $_.Method -ne 'Get' }).Count -eq 0)
Check '預覽：輸出不含 PAT、只寫來源' ($r.Out -notmatch 'SECRETPAT123' -and $r.Out -match '-Pat 參數')
Check '預覽：用 PAT 標頭，不帶 Windows 認證' (@($global:HD5Net | Where-Object { -not $_.HasAuthHeader -or $_.DefaultCred }).Count -eq 0)
$global:HD5Net = @()
$r = Run-Ops ($common + @('-Pat', 'SECRETPAT123'))
$post = @($global:HD5Net | Where-Object { $_.Method -eq 'Post' })
$patch = @($global:HD5Net | Where-Object { $_.Method -eq 'Patch' })
Check '正式（comments）：一則留言＋一次 PATCH' (-not $r.Threw -and $post.Count -eq 1 -and $patch.Count -eq 1 -and $r.Out -match '留言 id=777')
Check '正式：留言是編碼後的 HTML' ($post.Count -eq 1 -and ($post[0].Body | ConvertFrom-Json).text -match '第一行<br/>')
Check '正式：PATCH 含狀態與指派、不含 History' ($patch.Count -eq 1 -and $patch[0].Body -match 'System.State' -and $patch[0].Body -match 'someone@example.com' -and $patch[0].Body -notmatch 'System.History')
Check '正式：用 PAT 標頭、輸出不含 PAT' (@($global:HD5Net | Where-Object { -not $_.HasAuthHeader -or $_.DefaultCred }).Count -eq 0 -and $r.Out -notmatch 'SECRETPAT123')
$global:HD5Net = @()
$r = Run-Ops ($common + @('-Pat', 'SECRETPAT123', '-CommentVia', 'history'))
$post = @($global:HD5Net | Where-Object { $_.Method -eq 'Post' })
$patch = @($global:HD5Net | Where-Object { $_.Method -eq 'Patch' })
Check 'history 模式：不打 comments API，留言寫進同一次 PATCH 的 System.History＋rev 檢查' (-not $r.Threw -and $post.Count -eq 0 -and $patch.Count -eq 1 -and $patch[0].Body -match 'System.History' -and $patch[0].Body -match '"/rev"')
$global:HD5Net = @()
$r = Run-Ops @('42', '-Action', 'update', '-State', '不存在的狀態', '-ConfigStart', $projA, '-Pat', 'SECRETPAT123')
Check '狀態不在型別狀態集：拋錯列出允許值、不寫入' ($r.Threw -and $r.Msg -match '允許：進行中、待驗收' -and @($global:HD5Net | Where-Object { $_.Method -ne 'Get' }).Count -eq 0)
$global:HD5Net = @()
$r = Run-Ops @('42', '-ConfigStart', $projA, '-Pat', 'SECRETPAT123')
Check 'show：讀工單、附件、留言數' (-not $r.Threw -and $r.Out -match '#42' -and $r.Out -match 'a\.md' -and $r.Out -match '留言（0）')
Write-Host '--- 退回紀錄閘：工單歷程退回次數、rework-log、5.1、總帳（2026-11-25）---'
function New-Updates([string[]]$states) {
    $i = 0
    $list = @($states | ForEach-Object { $i++; [pscustomobject]@{ id = $i; fields = [pscustomobject]@{ 'System.State' = [pscustomobject]@{ oldValue = 'x'; newValue = $_ } } } })
    return @($list + @([pscustomobject]@{ id = 90; fields = [pscustomobject]@{ 'System.Title' = [pscustomobject]@{ newValue = 't' } } }, [pscustomobject]@{ id = 91 }))
}
Check '歷程數退回：State 變成「驗收未過」2 次（沒有 State 欄的異動略過）' ((Get-HD5RejectionCount -Updates (New-Updates @('進行中', '待驗收', '驗收未過', '待驗收', '驗收未過', '待驗收')) -RejectedStates @('驗收未過')) -eq 2)
Check '退回狀態名可設定（Rejected）' ((Get-HD5RejectionCount -Updates (New-Updates @('Rejected', 'Active', 'Rejected', 'Rejected')) -RejectedStates @('Rejected')) -eq 3)
Check 'tracker 預設退回／完成狀態＝驗收未過／驗收完成' ((@($ctxA.RejectedStates) -contains '驗收未過') -and (@($ctxA.DoneStates) -contains '驗收完成'))
$projRS = New-Proj 'projRS' ('{ "tracker": { "type": "azure-devops", "url": "' + $ProjUrl + '", "rejectedStates": ["Rejected"], "doneStates": ["Accepted"] } }')
$ctxRS = Get-HD5TrackerContext -ConfigStart $projRS
Check 'workflow.json 的 tracker.rejectedStates／doneStates 覆寫預設' ((@($ctxRS.RejectedStates) -join ',') -eq 'Rejected' -and (@($ctxRS.DoneStates) -join ',') -eq 'Accepted')
Check '驗收完成狀態判定' ((Test-HD5StateIsDone -State '驗收完成' -DoneStates $ctxA.DoneStates) -and -not (Test-HD5StateIsDone -State '待驗收' -DoneStates $ctxA.DoneStates))
$ledgerTool = Join-Path $vmDir 'check-rework-ledger.mjs'
function RG([string]$c, [string]$stage, [int]$k, [string]$tool = $ledgerTool) { Test-HD5ReworkGate -CasePath $c -Stage $stage -Rejections $k -WorkItemId '42' -LedgerTool $tool }
function New-ReworkLog([string[]]$rounds) { "# 退回紀錄`n`n| 輪次 | 退回原因 | 處理類別 | 根因類別 | 錯誤寫法 | 為什麼 | 修正 |`n|---|---|---|---|---|---|---|`n" + (($rounds | ForEach-Object { "| $_ | a | 程式錯誤 | 樣本不足 | 名稱只讀 Name 欄 | b | c |" }) -join "`n") + "`n" }
function New-Report51([int]$n) {
    $rows = (1..$n | ForEach-Object { "| R$_ | a | 樣本不足 | 名稱只讀 Name 欄 | b | c |" }) -join "`n"
    return "# ai-case-report｜#42 x`n`n## 5. 測試與驗收結果`n`n### 5.1 退回檢討`n`n- 送驗 $($n + 1) 次、退回 $n 次`n`n| 輪次 | 退回原因 | 根因類別 | 錯誤寫法 | 為什麼 | 規則 |`n|---|---|---|---|---|---|`n$rows`n`n## 6. 未盡事項`n- 無`n"
}
$ledHead = "| 結案日 | 案號 | 輪次 | 根因類別 | 錯誤寫法 | 原因一句 | 為什麼沒先抓到 | 對應規則 |`n|---|---|---|---|---|---|---|---|`n"
# 每列不同根因類別（同類別兩列會觸發「第 2 次要升級守衛」）
$cats = @('樣本不足', '動作順序', '修後沒重跑', '測試資料形狀')
function New-Ledger([string]$case, [int]$n, [string]$rule = '無（x）') { Write-Fixture (Join-Path (Split-Path -Parent $case) 'rework-ledger.md') ($ledHead + ((1..$n | ForEach-Object { "| 2026-11-25 | #42 | R$_ | $($cats[$_ - 1]) | 名稱只讀 Name 欄 | a | b | $rule |" }) -join "`n") + "`n") }
$cR = New-GateCase @{ 'Codex驗收結果_R1.md' = '總結：通過'; 'onsite-gate_R1.md' = '總結：通過' }
Check '待驗收：歷程沒有退回、沒有總帳 ⇒ 過' ((RG $cR 'accept' 0).Passed)
$g = RG $cR 'accept' 2
Check '🔴 待驗收：歷程退回 2 次、沒有 rework-log ⇒ 擋，說要先記第 1～2 輪' (-not $g.Passed -and ($g.Reasons -join ' ') -match '第 1～2 輪')
Write-Fixture (Join-Path $cR 'qa\rework-log.md') (New-ReworkLog @('R1', 'R1'))
$g = RG $cR 'accept' 2
Check '🔴 待驗收：退回 2 次、rework-log 只有 R1（兩列）⇒ 擋，說要先記第 2 輪' (-not $g.Passed -and ($g.Reasons -join ' ') -match '第 2 輪退回')
Write-Fixture (Join-Path $cR 'qa\rework-log.md') (New-ReworkLog @('R1', 'R2'))
Check '待驗收：退回 2 次、rework-log 記了 R1、R2 ⇒ 過' ((RG $cR 'accept' 2).Passed)
$g = RG $cR 'accept' 2 (Join-Path $tmpRoot 'missing\check-rework-ledger.mjs')
Check '退回 >0 但找不到 check-rework-ledger.mjs ⇒ fail closed' (-not $g.Passed -and ($g.Reasons -join ' ') -match 'fail closed')
Write-Fixture (Join-Path $cR 'ai-case-report.md') "# ai-case-report｜#42 x`n`n## 5. 測試與驗收結果`n- x`n"
$g = RG $cR 'done' 2
Check '🔴 驗收完成：rework-log 2 列、報告沒有 5.1 ⇒ 擋' (-not $g.Passed -and ($g.Reasons -join ' ') -match '5\.1')
Write-Fixture (Join-Path $cR 'ai-case-report.md') (New-Report51 2)
$g = RG $cR 'done' 2
Check '🔴 驗收完成：5.1 有 2 列但總帳沒有本案 ⇒ 擋' (-not $g.Passed -and ($g.Reasons -join ' ') -match '總帳')
New-Ledger $cR 2
Check '驗收完成：rework-log、5.1、總帳都 2 列 ⇒ 過' ((RG $cR 'done' 2).Passed)
# 同一根因類別第 2 次、只有 無（沒有程式守衛）：升級只讓開發端 verify 變紅，工單閘不擋（2026-11-25 使用者拍板）
Write-Fixture (Join-Path (Split-Path -Parent $cR) 'rework-ledger.md') ($ledHead + "| 2026-11-25 | #42 | R1 | 動作順序 | 先新增再抓取沒測 | a | b | 無（x） |`n| 2026-11-25 | #42 | R2 | 動作順序 | 先新增再抓取沒測 | a | b | 無（y） |`n")
Check '🔴 工單閘用 --gate：同類第 2 次沒有程式守衛 ⇒ 改待驗收不擋' ((RG $cR 'accept' 2).Passed)
Check '🔴 工單閘用 --gate：同類第 2 次沒有程式守衛 ⇒ 驗收完成不擋' ((RG $cR 'done' 2).Passed)
Write-Fixture (Join-Path (Split-Path -Parent $cR) 'rework-ledger.md') ($ledHead + "| 2026-11-25 | #42 | R1 | 動作順序 |  | a | b | 無（x） |`n| 2026-11-25 | #42 | R2 | 樣本不足 | 名稱只讀 Name 欄 | a | b | 無（y） |`n")
$g = RG $cR 'done' 2
Check '工單閘照樣查格式：總帳錯誤寫法空白 ⇒ 擋' (-not $g.Passed -and ($g.Reasons -join ' ') -match '錯誤寫法是空的')
Write-Fixture (Join-Path $cR 'qa\rework-log.md') "| 輪次 | 退回原因 | 處理類別 | 根因類別 | 為什麼 | 修正 |`n|---|---|---|---|---|---|`n| R1 | a | 程式錯誤 | 樣本不足 | b | c |`n| R2 | a | 程式錯誤 | 樣本不足 | b | c |`n"
New-Ledger $cR 2
$g = RG $cR 'accept' 2
Check '工單閘：rework-log 缺「錯誤寫法」欄 ⇒ 擋' (-not $g.Passed -and ($g.Reasons -join ' ') -match '錯誤寫法')
Write-Fixture (Join-Path $cR 'qa\rework-log.md') (New-ReworkLog @('R1', 'R2'))
New-Ledger $cR 2 '缺（先記帳）'
$g = RG $cR 'accept' 2
Check '改待驗收時一起跑總帳檢查：對應規則寫自由文字 ⇒ 擋' (-not $g.Passed -and ($g.Reasons -join ' ') -match '看不懂')
Remove-Item -LiteralPath (Join-Path (Split-Path -Parent $cR) 'rework-ledger.md') -Force

Write-Host '--- workitem-ops：退回紀錄閘（假 API）---'
$cF = New-EvCase $okOnsite
$baseF = @('42', '-Action', 'update', '-State', '待驗收', '-CasePath', $cF, '-ToolsDir', $vmDir, '-VerifyRoot', ([IO.Path]::GetFullPath((Join-Path $cF '..\..\verify'))), '-Pat', 'SECRETPAT123')
$global:HD5Updates = New-Updates @('待驗收', '驗收未過', '待驗收', '驗收未過')
$global:HD5Net = @()
$r = Run-Ops ($baseF + @('-ConfigStart', $projA))
Check '🔴 改待驗收：歷程退回 2 次、沒記 rework-log ⇒ 擋、不寫入（有讀歷程）' ($r.Threw -and $r.Msg -match '第 1～2 輪' -and @($global:HD5Net | Where-Object { $_.Method -ne 'Get' }).Count -eq 0 -and @($global:HD5Net | Where-Object { $_.Uri -match '/updates\?' }).Count -ge 1)
$global:HD5Net = @()
$r = Run-Ops ($baseF + @('-ConfigStart', $projA, '-WhatIfOnly'))
Check '改待驗收預覽：退回紀錄不足只印「正式執行會被擋」' (-not $r.Threw -and $r.Out -match '正式執行會被擋' -and $r.Out -match '第 1～2 輪' -and @($global:HD5Net | Where-Object { $_.Method -ne 'Get' }).Count -eq 0)
Write-Fixture (Join-Path $cF 'qa\rework-log.md') (New-ReworkLog @('R1', 'R2'))
$global:HD5Net = @()
$r = Run-Ops ($baseF + @('-ConfigStart', $projA))
Check '改待驗收：rework-log 記滿 2 輪 ⇒ 寫入' (-not $r.Threw -and @($global:HD5Net | Where-Object { $_.Method -eq 'Patch' }).Count -eq 1)
$global:HD5Updates = New-Updates @('Rejected', 'Rejected', 'Rejected')
$global:HD5Net = @()
$r = Run-Ops ($baseF + @('-ConfigStart', $projRS))
Check 'tracker.rejectedStates＝Rejected：歷程 3 次、只記 2 輪 ⇒ 擋第 3 輪' ($r.Threw -and $r.Msg -match '第 3 輪退回')
$global:HD5Updates = @()
$global:HD5Net = @()
$r = Run-Ops @('42', '-Action', 'update', '-State', '驗收完成', '-ConfigStart', $projA, '-Pat', 'SECRETPAT123')
Check '🔴 改驗收完成沒給 -CasePath：連網前就擋' ($r.Threw -and $r.Msg -match 'CasePath' -and $global:HD5Net.Count -eq 0)
$global:HD5Net = @()
$doneF = @('42', '-Action', 'update', '-State', '驗收完成', '-CasePath', $cF, '-ToolsDir', $vmDir, '-ConfigStart', $projA, '-Pat', 'SECRETPAT123')
$r = Run-Ops $doneF
Check '🔴 改驗收完成：rework-log 2 列、沒有結案報告 5.1 ⇒ 擋、不寫入' ($r.Threw -and $r.Msg -match '5\.1' -and @($global:HD5Net | Where-Object { $_.Method -ne 'Get' }).Count -eq 0)
Write-Fixture (Join-Path $cF 'ai-case-report.md') (New-Report51 2)
New-Ledger $cF 2
$global:HD5Net = @()
$r = Run-Ops $doneF
Check '改驗收完成：5.1 與總帳都齊 ⇒ 寫入' (-not $r.Threw -and @($global:HD5Net | Where-Object { $_.Method -eq 'Patch' }).Count -eq 1)

Write-Host '--- 留言不審文字（2026-11-25 使用者拍板：用正規表示式審文字易繞過又誤擋，不擋也不警告）---'
$global:HD5Net = @()
$r = Run-Ops @('42', '-Action', 'update', '-Comment', "第二輪修正完成。`n只按確定不算修改，維持就不用回。", '-ConfigStart', $projA, '-Pat', 'SECRETPAT123')
Check '留言含「維持就不用回」⇒ 照常送出，不擋不警告' (-not $r.Threw -and @($global:HD5Net | Where-Object { $_.Method -eq 'Post' }).Count -eq 1 -and $r.Out -notmatch '句型')
Check '句型清單與檢查函式已移除' (-not (Get-Command Find-HD5DeferToSilencePhrase -ErrorAction SilentlyContinue) -and -not (Get-Command Assert-HD5CommentPhrasing -ErrorAction SilentlyContinue))

Write-Host '--- 認證／憑證（假 API）---'
$projSelf = New-Proj 'projSelf' '{ "tracker": { "type": "azure-devops", "url": "https://devops.example.com/DefaultCollection/example-project" } }'
$global:HD5Net = @()
$r = Run-Ops @('42', '-ConfigStart', $projSelf)
Check '沒 PAT＋自架網址：每個呼叫都帶 UseDefaultCredentials、沒有 PAT 標頭' (-not $r.Threw -and $global:HD5Net.Count -gt 0 -and @($global:HD5Net | Where-Object { -not $_.DefaultCred -or $_.HasAuthHeader }).Count -eq 0)
Check '預設不驗憑證（PS7 帶 -SkipCertificateCheck；5.1 換信任全部的 policy）' (@($global:HD5Net | Where-Object { -not $_.Trust }).Count -eq 0)
$global:HD5Net = @()
$r = Run-Ops @('42', '-ConfigStart', $projSelf, '-StrictCertificate')
Check '-StrictCertificate：不略過憑證檢查' (-not $r.Threw -and $global:HD5Net.Count -gt 0 -and @($global:HD5Net | Where-Object { $_.Trust }).Count -eq 0)
$global:HD5Net = @()
$r = Run-Ops @('42', '-ConfigStart', $projA)
Check '沒 PAT＋雲端網址：報錯要 PAT、沒有網路呼叫' ($r.Threw -and $r.Msg -match 'PAT' -and $global:HD5Net.Count -eq 0)
$global:HD5NetHandler = $null

Write-Host '--- workitem-ops -Action comments：-Id／-ExcludeId（假 API，2026-11-24）---'
$global:HD5NetHandler = {
    param($Uri, $Method, $BodyText)
    if ($Method -eq 'Get' -and $Uri -match '/wit/workitems/(\d+)\?') { return (New-FakeItem ([int]$Matches[1]) $null '進行中') }
    if ($Method -eq 'Get' -and $Uri -match '/comments\?') { return [pscustomobject]@{ comments = @(
        [pscustomobject]@{ id = 4471; text = '<div>完成通知：不該被看到</div>'; createdDate = '2026-11-18'; createdBy = [pscustomobject]@{ displayName = 'B' } },
        [pscustomobject]@{ id = 4467; text = '<div>答覆檔已上傳</div>'; createdDate = '2026-11-17'; createdBy = [pscustomobject]@{ displayName = 'A' } }) } }
    throw "未預期的呼叫：$Method $Uri"
}
$r = Run-Ops @('42', '-Action', 'comments', '-ExcludeId', '4471', '-ConfigStart', $projA, '-Pat', 'SECRETPAT123')
Check '🔴 -ExcludeId 4471：不印那則的內容，只說排除了哪個 id' (-not $r.Threw -and $r.Out -notmatch '不該被看到' -and $r.Out -match '答覆檔已上傳' -and $r.Out -match '已排除 id 4471')
$r = Run-Ops @('42', '-Action', 'comments', '-Id', @(4467, 999), '-ConfigStart', $projA, '-Pat', 'SECRETPAT123')
Check '-Id 4467,999：只印 4467，999 不存在要警告' (-not $r.Threw -and $r.Out -notmatch '不該被看到' -and $r.Out -match '（id 4467）：答覆檔已上傳' -and $r.Out -match '999')
$r = Run-Ops @('42', '-Action', 'comments', '-ConfigStart', $projA, '-Pat', 'SECRETPAT123')
Check '不給篩選：照舊全部列出' (-not $r.Threw -and $r.Out -match '留言 2 則' -and $r.Out -match '不該被看到')

$global:HD5NetHandler = $null
}
finally {
    Set-Location -LiteralPath $origLoc
    foreach ($n in $saved.Keys) { [Environment]::SetEnvironmentVariable($n, $saved[$n]) }
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $iso -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath Function:\global:Invoke-RestMethod -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath Function:\global:Invoke-WebRequest -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:fail) { Write-Host "FAILED: $($script:fail)" -ForegroundColor Red; exit 1 } else { Write-Host 'ALL PASSED' -ForegroundColor Green }
