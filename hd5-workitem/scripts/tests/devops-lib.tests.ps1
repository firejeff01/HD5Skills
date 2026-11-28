<#
.SYNOPSIS
  hd5-workitem 讀工單建案／結案報告上傳（_devops-lib、fetch-workitem、fetch-related-attachments、upload-case-report）的離線測試。

.DESCRIPTION
  執行：pwsh -NoProfile -File <本檔>；Windows PowerShell 5.1：powershell -NoProfile -File <本檔>。最後一行要是 ALL PASSED。
  🔴 全程把 Invoke-RestMethod／Invoke-WebRequest 換成假的，任何未預期的呼叫直接失敗，絕不打真的 Azure DevOps。
  涵蓋：語法與 BOM、網址解析、號碼＋專案網址（參數／環境變數／tracker.url／沒網址報錯）、tracker.type≠azure-devops 拒絕、
  HTML→Markdown 與後處理、三級引用偵測與去重、附件清單（含只有一個附件的陣列拆解回歸）、PAT 取用順序與不印 PAT、
  上傳結案報告的前置檢查、預設只預覽、-Upload 才寫入。
#>
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
$scripts = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$script:fail = 0
function Check($name, $cond) { if ($cond) { Write-Host "  ok   $name" } else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:fail++ } }

Write-Host '--- parse／BOM ---'
foreach ($f in '_tracker-config.ps1', '_auth.ps1', '_acceptance-gate.ps1', '_comments.ps1', '_devops-lib.ps1', 'fetch-workitem.ps1', 'fetch-related-attachments.ps1', 'upload-case-report.ps1') {
    $tokens = $null; $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $scripts $f), [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count) { $script:fail++; Write-Host "PARSE FAIL $f" -ForegroundColor Red; $errors | ForEach-Object { Write-Host "  $($_.Extent.StartLineNumber): $($_.Message)" } }
    else { Write-Host "parse ok  $f" }
    $bytes = [IO.File]::ReadAllBytes((Join-Path $scripts $f))
    if (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) { $script:fail++; Write-Host "BOM MISSING $f" -ForegroundColor Red }
}

# 🔴 隔離（hermetic）：把受測腳本複製到上層沒有 .claude/workflow.json 的暫存資料夾再測，
#    不管本測試放在套件裡還是裝進專案（專案有自己的 workflow.json），結果都一樣。
$iso = Join-Path ([IO.Path]::GetTempPath()) ("hd5dliso_" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $iso 'tools\workitem') -Force | Out-Null
Get-ChildItem -LiteralPath $scripts -File -Force | Copy-Item -Destination (Join-Path $iso 'tools\workitem') -Force
# 上傳前的工單閘要用功能地圖檢查器：安裝後在上一層（<hd5-tools>/），套件原始碼在 ../../hd5-workflow/tools/
$vmSrc = $null
foreach ($cand in (Join-Path $scripts '..\_verify-map-lib.ps1'), (Join-Path $scripts '..\..\hd5-workflow\tools\_verify-map-lib.ps1')) {
    if (Test-Path -LiteralPath $cand) { $vmSrc = (Resolve-Path -LiteralPath $cand).Path; break }
}
Check '找得到功能地圖檢查器 _verify-map-lib.ps1（安裝位置或套件原始碼）' ([bool]$vmSrc)
if ($vmSrc) { Copy-Item -LiteralPath $vmSrc -Destination (Join-Path $iso 'tools') -Force }
# 退回紀錄閘的總帳檢查器（同一層；它 import check-guard-refs.mjs）
if ($vmSrc) { foreach ($n in 'check-rework-ledger.mjs', 'check-guard-refs.mjs', 'check-secrets.mjs') { $src = Join-Path (Split-Path -Parent $vmSrc) $n; if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $iso 'tools') -Force } } }
$vmDir = Join-Path $iso 'tools'
$scripts = Join-Path $iso 'tools\workitem'

. (Join-Path $scripts '_devops-lib.ps1')

# --- 假網路 -------------------------------------------------------------------
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
    $global:HD5Net += [pscustomobject]@{ Uri = $Uri; Method = 'Download'; Body = $null; HasAuthHeader = [bool]($Headers -and $Headers.Authorization); DefaultCred = [bool]$UseDefaultCredentials; Trust = $(if ($PSVersionTable.PSVersion.Major -ge 6) { [bool]$SkipCertificateCheck } else { $cp = [System.Net.ServicePointManager]::CertificatePolicy; ($null -ne $cp -and $cp.GetType().Name -eq 'TrustAllCertsPolicy') }) }
    throw 'NETWORK BLOCKED（測試不得連網）'
}

$saved = @{}
foreach ($n in 'AZURE_DEVOPS_PROJECT_URL', 'AZURE_DEVOPS_PAT', 'AZURE_DEVOPS_PAT_WRITE') { $saved[$n] = [Environment]::GetEnvironmentVariable($n); [Environment]::SetEnvironmentVariable($n, $null) }
$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ("hd5dl_" + [guid]::NewGuid().ToString('N'))
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
function Run-Script([string]$file, [hashtable]$h) {
    $r = [pscustomobject]@{ Threw = $false; Msg = ''; Out = '' }
    try { $r.Out = (& (Join-Path $scripts $file) @h *>&1 | Out-String) } catch { $r.Threw = $true; $r.Msg = $_.Exception.Message }
    return $r
}
$Org = 'https://dev.azure.com/example-org'
$ProjUrl = "$Org/example-project"

try {
Check '前提：乾淨目錄往上找不到 workflow.json' ($null -eq (Find-HD5WorkflowConfig -Starts @($clean)))
Check '前提：隔離後的腳本位置往上找不到 workflow.json' ($null -eq (Find-HD5WorkflowConfig -Starts @($scripts)))

Write-Host '--- Resolve-DevOpsWorkItemUrl ---'
$a = Resolve-DevOpsWorkItemUrl "$ProjUrl/_workitems/edit/281"
Check 'edit url id／project' ($a.Id -eq 281 -and $a.Project -eq 'example-project')
Check 'edit url projectApi／collectionApi' ($a.ProjectApi -eq "$ProjUrl/_apis" -and $a.CollectionApi -eq "$Org/_apis")
Check 'backlog url id' ((Resolve-DevOpsWorkItemUrl "$ProjUrl/_backlogs/backlog/example-project%20Team/Stories/?workitem=163").Id -eq 163)
$s = Resolve-DevOpsWorkItemUrl "$ProjUrl/_sprints/backlog/%E5%B0%88%E6%A1%88%E5%B0%8F%E7%B5%84/example-project/Sprint%201?workitem=351"
Check 'sprint backlog url id／project' ($s.Id -eq 351 -and $s.Project -eq 'example-project')
$c = Resolve-DevOpsWorkItemUrl "$Org/_apis/wit/workItems/99"
Check 'api url：沒有 project' ($c.Id -eq 99 -and $null -eq $c.Project)
Check 'web url build' ((Get-DevOpsWorkItemWebUrl -Origin $a.Origin -Collection $a.Collection -Project 'example-project' -Id 5) -eq "$ProjUrl/_workitems/edit/5")

Write-Host '--- 號碼＋專案網址 ---'
$projA = New-Proj 'projA' ('{ "paths": { "aiService": "AI_Service" }, "tracker": { "type": "azure-devops", "url": "' + $ProjUrl + '" } }')
$ctxA = Get-HD5TrackerContext -ConfigStart (Join-Path $projA 'AI_Service\spec')
Check '號碼＋tracker.url（往上找）' ((Resolve-DevOpsWorkItemInput -WorkItem '12' -Context $ctxA) -eq "$ProjUrl/_workitems/edit/12")
Check '號碼＋-ProjectUrl 優先' ((Resolve-DevOpsWorkItemInput -WorkItem '12' -Context $ctxA -ProjectUrl "$Org/p2/") -eq "$Org/p2/_workitems/edit/12")
[Environment]::SetEnvironmentVariable('AZURE_DEVOPS_PROJECT_URL', "$Org/envp")
Check '號碼＋環境變數（先於 tracker.url）' ((Resolve-DevOpsWorkItemInput -WorkItem '12' -Context $ctxA) -eq "$Org/envp/_workitems/edit/12")
[Environment]::SetEnvironmentVariable('AZURE_DEVOPS_PROJECT_URL', $null)
Check '完整網址原樣' ((Resolve-DevOpsWorkItemInput -WorkItem "$ProjUrl/_workitems/edit/3") -eq "$ProjUrl/_workitems/edit/3")
$threw = $false; $msg = ''; try { Resolve-DevOpsWorkItemInput -WorkItem '12' -Context (Get-HD5TrackerContext -ConfigStart $clean) | Out-Null } catch { $threw = $true; $msg = $_.Exception.Message }
Check '沒網址：清楚報錯' ($threw -and $msg -match 'tracker\.url' -and $msg -match 'AZURE_DEVOPS_PROJECT_URL')
Check '預設案子資料夾由 workflow.json 推' ((Get-HD5DefaultSpecRoot -Context $ctxA) -eq [IO.Path]::GetFullPath((Join-Path $projA 'AI_Service\spec')))

Write-Host '--- ConvertFrom-DevOpsHtml ---'
$html = '<div>延續 <a href="' + $ProjUrl + '/_workitems/edit/281" data-vss-mention="version:1.0">#281</a> 的做法</div><div>另見 ' + $ProjUrl + '/_workitems/edit/250 與純文字 #146、#167。</div><div>實體 &#123; 不是工單；<b>粗體</b><br/>&lt;tag&gt;</div><ul><li>項目一</li></ul>'
$md = ConvertFrom-DevOpsHtml $html
Check 'anchor kept as md link' ($md -match '\[#281\]\(https://[^)]+/_workitems/edit/281\)')
Check 'bold' ($md -match '\*\*粗體\*\*')
Check 'entities' ($md -match '<tag>')
Check 'li' ($md -match '- 項目一')
Check 'null safe' ((ConvertFrom-DevOpsHtml $null) -eq '')
$html2 = '<div><b>1. 來源：</b></div><div>由需求方開單 </div><div><br></div><div><b>5. 驗收條件（全部必須通過）：</b></div><ul><li><div>條件 A </div></li><li><div>條件 B</div></li><li><div>條件 C</div></li></ul><div><b>粗體但不是標題</b> 後面還有字</div>'
$md2 = ConvertFrom-DevOpsHtml $html2
Check 'bold pseudo heading -> ##' ($md2 -match '(?m)^## 1\. 來源$')
Check 'bold pseudo heading with paren -> ##' ($md2 -match '(?m)^## 5\. 驗收條件（全部必須通過）$')
Check 'inline bold untouched' ($md2 -match '\*\*粗體但不是標題\*\* 後面還有字')
Check 'no trailing spaces' (-not ($md2 -match '(?m) $'))
Check 'list items contiguous' ($md2 -match '- 條件 A\n- 條件 B\n- 條件 C')
$html3 = '<div><b>分級：</b>小修　｜　<b>類型：</b>bug 修復</div><div><b>1. 來源：</b>#256（某功能）驗收時發現。</div><div><b>4. 主要流程</b>（功能位置：A › B）：</div><ul><li>【重現】步驟一</li></ul>'
$md3 = ConvertFrom-DevOpsHtml $html3
Check 'unnumbered bold label untouched' ($md3 -match '\*\*分級：\*\*小修')
Check 'inline pseudo heading split' ($md3 -match '(?m)^## 1\. 來源\n\n#256（某功能）驗收時發現。$')
Check 'heading followed by paren note' ($md3 -match '(?m)^## 4\. 主要流程\n\n（功能位置：A › B）：$')
Check 'blank line before heading' ($md3 -match '(?m)bug 修復\n\n## 1\. 來源')
$html4 = '<div><b>5. 驗收條件：</b></div><div>   ☑ 可下載範本</div><div>   ☑ 三欄皆必填</div><ul>' + "`n  <li><div>縮排項目</div></li>`n  <li><div>第二項</div></li>`n" + '</ul><div>【待確認】(無)</div><div>【已轉出】(無)</div>'
$md4 = ConvertFrom-DevOpsHtml $html4
Check 'checkbox from ☑' ($md4 -match '(?m)^- \[ \] 可下載範本\n- \[ \] 三欄皆必填$')
Check 'indented list flush-left' ($md4 -match '(?m)^- 縮排項目\n- 第二項$')
Check 'adjacent divs become paragraphs' ($md4 -match '【待確認】\(無\)\n\n【已轉出】\(無\)')
Check 'heading then checkbox list separated by one blank' ($md4 -match '(?m)^## 5\. 驗收條件\n\n- \[ \] 可下載範本')
$fwSrc = [IO.File]::ReadAllText((Join-Path $scripts 'fetch-workitem.ps1'), [Text.Encoding]::UTF8)
Check 'blank line before --- in attach section' ($fwSrc -match "@\('', '', '---', '', '## 工單附件'")
Check 'blank line before --- in related section' ($fwSrc -match "'', '', '---', '',\s*\r?\n\s*'## 引用工單")

Write-Host '--- Get-DevOpsWorkItemRefs ---'
$wi = [pscustomobject]@{
    fields    = @{ 'System.Description' = $html }
    relations = @(
        [pscustomobject]@{ rel = 'System.LinkTypes.Hierarchy-Reverse'; url = "$Org/_apis/wit/workItems/100"; attributes = @{} },
        [pscustomobject]@{ rel = 'System.LinkTypes.Related'; url = "$Org/_apis/wit/workItems/281"; attributes = @{} },
        [pscustomobject]@{ rel = 'AttachedFile'; url = "$Org/_apis/wit/attachments/abc"; attributes = @{ name = 'ai-case-report.md'; resourceCreatedDate = '2026-08-01T00:00:00Z' } },
        [pscustomobject]@{ rel = 'ArtifactLink'; url = 'vstfs:///Git/Commit/x'; attributes = @{ name = 'Fixed in Commit' } },
        [pscustomobject]@{ rel = 'System.LinkTypes.Related'; url = "$Org/_apis/wit/workItems/300"; attributes = @{} }
    )
}
$refs = @(Get-DevOpsWorkItemRefs -WorkItem $wi -Html $html -SelfId 300)
Check 'self excluded' (-not ($refs | Where-Object { $_.Id -eq 300 }))
Check 'parent relation first' ($refs[0].Id -eq 100 -and $refs[0].Tier -eq 'relation' -and $refs[0].Via -eq '父工單')
Check '281 relation wins over anchor (dedupe)' ((@($refs | Where-Object { $_.Id -eq 281 })).Count -eq 1 -and ($refs | Where-Object { $_.Id -eq 281 }).Tier -eq 'relation')
Check '250 bare url = link' (($refs | Where-Object { $_.Id -eq 250 }).Tier -eq 'link')
Check '146／167 text' (($refs | Where-Object { $_.Id -eq 146 }).Tier -eq 'text' -and ($refs | Where-Object { $_.Id -eq 167 }).Tier -eq 'text')
Check 'entity &#123; excluded' (-not ($refs | Where-Object { $_.Id -eq 123 }))
Check 'count 5' ($refs.Count -eq 5)
Check 'empty safe' ((@(Get-DevOpsWorkItemRefs -WorkItem ([pscustomobject]@{ fields = @{}; relations = $null }) -Html '' -SelfId 1)).Count -eq 0)
$oneRef = @(Get-DevOpsWorkItemRefs -WorkItem ([pscustomobject]@{ fields = @{}; relations = $null }) -Html '<div>見 #77</div>' -SelfId 1)
Check 'single ref via @() is flat' ($oneRef.Count -eq 1 -and $oneRef[0] -isnot [array] -and $oneRef[0].Id -eq 77)
Check 'two refs via @() are two elements' ((@(Get-DevOpsWorkItemRefs -WorkItem ([pscustomobject]@{ fields = @{}; relations = $null }) -Html '<div>見 #77 與 #78</div>' -SelfId 1)).Count -eq 2)
Check 'tier label text' ((ConvertTo-DevOpsRefTierLabel -Tier 'text' -Via 'x') -like '*待驗證*')

Write-Host '--- 附件 ---'
$atts = @(Get-DevOpsAttachments -WorkItem $wi)
Check '只有一個附件時 @() 仍是一個元素（陣列拆解回歸）' ($atts.Count -eq 1 -and $atts[0] -isnot [array] -and $atts[0].Name -eq 'ai-case-report.md')
$twoWi = [pscustomobject]@{ relations = @(
    [pscustomobject]@{ rel = 'AttachedFile'; url = 'u1'; attributes = @{ name = 'a.md' } },
    [pscustomobject]@{ rel = 'AttachedFile'; url = 'u2'; attributes = @{ name = 'b.md' } }) }
$two = @(Get-DevOpsAttachments -WorkItem $twoWi)
Check 'two attachments flat' ($two.Count -eq 2 -and $two[1].Name -eq 'b.md')
Check 'no attachments Count=0' ((@(Get-DevOpsAttachments -WorkItem ([pscustomobject]@{ relations = $null }))).Count -eq 0)
Check 'fetch-workitem wraps attachments call in @()' ($fwSrc -match '\$atts\s*=\s*@\(Get-DevOpsAttachments -WorkItem \$wi\)')
Check 'fetch-workitem wraps refs call in @()' ($fwSrc -match '\$refs\s*=\s*@\(Get-DevOpsWorkItemRefs')
$libCode = (Get-Content (Join-Path $scripts '_devops-lib.ps1') -Encoding UTF8 | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
Check 'lib does not use "return ,$x"' (-not ($libCode -match 'return\s*,\s*\$'))
$multi = @(
    [pscustomobject]@{ Name = 'ai-case-report.md'; Url = 'u1'; Created = '2026-08-01T00:00:00Z' },
    [pscustomobject]@{ Name = 'ai-case-report.md'; Url = 'u2'; Created = '2026-09-01T00:00:00Z' },
    [pscustomobject]@{ Name = 'ai-case-report.md'; Url = 'u3'; Created = '2026-08-15T00:00:00Z' })
Check 'latest by date' ((Select-DevOpsLatestAttachment -Attachments $multi).Url -eq 'u2')
Check 'latest fallback last' ((Select-DevOpsLatestAttachment -Attachments @([pscustomobject]@{ Name = 'x'; Url = 'a'; Created = $null }, [pscustomobject]@{ Name = 'x'; Url = 'b'; Created = $null })).Url -eq 'b')
Check 'latest empty' ($null -eq (Select-DevOpsLatestAttachment -Attachments @()))
Check 'safe name' ((Get-DevOpsSafeFileName -Name 'a:b?.md') -eq 'a_b_.md')
$tmpd = Join-Path $tmpRoot 'uniq'; Write-Fixture (Join-Path $tmpd 'x.md') 'a'
Check 'unique path' ((Get-DevOpsUniquePath -Dir $tmpd -Name 'x.md') -like '*x(2).md')

Write-Host '--- 認證（共用 _auth.ps1 的 New-DevOpsAuthContext）---'
function B64([string]$p) { 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$p")) }
$patDir = Join-Path $tmpRoot 'patdir'; New-Item -ItemType Directory -Path $patDir -Force | Out-Null
$threw = $false; $msg = ''
try { New-DevOpsAuthContext -ScriptRoot $patDir -TargetUrl $Org | Out-Null } catch { $threw = $true; $msg = $_.Exception.Message }
Check '雲端沒 PAT：報錯，提示檔名、環境變數、-PatFile 與該組織的申請網址' ($threw -and $msg -match 'pat\.local\.txt' -and $msg -match '環境變數 AZURE_DEVOPS_PAT' -and $msg -match '-PatFile' -and $msg -match [regex]::Escape("$Org/_usersSettings/tokens"))
Check '自架沒 PAT：Windows 整合驗證' ((New-DevOpsAuthContext -ScriptRoot $patDir -TargetUrl 'https://devops.example.com/DefaultCollection').Mode -eq 'Windows')
Write-Fixture (Join-Path $patDir 'pat.local.txt') "# comment`r`n`r`n  readpat  `r`n"
$r = New-DevOpsAuthContext -ScriptRoot $patDir -TargetUrl $Org
Check 'reads pat.local.txt trimmed' ($r.Mode -eq 'PAT' -and $r.Headers.Authorization -eq (B64 'readpat') -and $r.Source -eq '檔案 pat.local.txt')
Check 'write falls back to read pat' ((New-DevOpsAuthContext -ScriptRoot $patDir -Write).Headers.Authorization -eq (B64 'readpat'))
Write-Fixture (Join-Path $patDir 'pat.write.local.txt') 'writepat'
$w2 = New-DevOpsAuthContext -ScriptRoot $patDir -Write
Check 'write prefers pat.write.local.txt' ($w2.Headers.Authorization -eq (B64 'writepat') -and $w2.Source -eq '檔案 pat.write.local.txt')
Check 'read ignores write file' ((New-DevOpsAuthContext -ScriptRoot $patDir).Headers.Authorization -eq (B64 'readpat'))
Check 'param wins' ((New-DevOpsAuthContext -Pat ' p ' -ScriptRoot $patDir).Headers.Authorization -eq (B64 'p'))
$custom = Join-Path $tmpRoot 'elsewhere\team.pat.txt'; Write-Fixture $custom 'custompat'
Check '-PatFile 先於資料夾內的 pat 檔' ((New-DevOpsAuthContext -ScriptRoot $patDir -PatFile $custom).Headers.Authorization -eq (B64 'custompat'))
$threw = $false; try { New-DevOpsAuthContext -ScriptRoot $patDir -PatFile (Join-Path $tmpRoot 'nope.txt') | Out-Null } catch { $threw = $true }
Check '-PatFile 不存在就報錯' $threw
[Environment]::SetEnvironmentVariable('AZURE_DEVOPS_PAT_WRITE', 'envw')
Check 'env write wins over file' ((New-DevOpsAuthContext -ScriptRoot $patDir -Write).Headers.Authorization -eq (B64 'envw'))
Check '唯讀不看 AZURE_DEVOPS_PAT_WRITE' ((New-DevOpsAuthContext -ScriptRoot $patDir).Headers.Authorization -eq (B64 'readpat'))
[Environment]::SetEnvironmentVariable('AZURE_DEVOPS_PAT_WRITE', $null)
Check '來源說明不含 PAT' ($w2.Source -notmatch 'writepat')
$wpw = Get-DevOpsWebParams @{ Uri = 'x'; Headers = @{ Mode = 'Windows'; Source = 's'; Headers = @{} } }
$wpp = Get-DevOpsWebParams @{ Uri = 'x'; Headers = $w2 }
Check 'WebParams：整合驗證換成 UseDefaultCredentials、PAT 換成 Authorization 標頭' ($wpw.UseDefaultCredentials -and -not $wpw.ContainsKey('Headers') -and $wpp.Headers.Authorization -eq (B64 'writepat') -and -not $wpp.ContainsKey('UseDefaultCredentials'))Check '.gitignore 排除 pat 檔' (([IO.File]::ReadAllText((Join-Path $scripts '.gitignore'))) -match '(?m)^pat\.local\.txt$' -and ([IO.File]::ReadAllText((Join-Path $scripts '.gitignore'))) -match '(?m)^pat\.write\.local\.txt$')

Write-Host '--- tracker.type≠azure-devops 拒絕（不連網）---'
$projN = New-Proj 'projN' '{ "tracker": { "type": "none", "url": "" } }'
$global:HD5Net = @()
$r = Run-Script 'fetch-workitem.ps1' @{ WorkItemUrl = "$ProjUrl/_workitems/edit/1"; PeekOnly = $true; ConfigStart = $projN }
Check 'fetch-workitem 拒絕' ($r.Threw -and $r.Msg -match '本專案沒有設定 Azure DevOps')
$r = Run-Script 'fetch-related-attachments.ps1' @{ WorkItemUrl = "$ProjUrl/_workitems/edit/1"; CaseName = 'c'; ConfigStart = $projN }
Check 'fetch-related-attachments 拒絕' ($r.Threw -and $r.Msg -match '本專案沒有設定 Azure DevOps')
$caseN = Join-Path $projN 'AI_Service\spec\c1'
Write-Fixture (Join-Path $caseN 'ai-case-report.md') 'x'
$r = Run-Script 'upload-case-report.ps1' @{ WorkItemUrl = '1'; ReportPath = (Join-Path $caseN 'ai-case-report.md'); ConfigStart = $projN }
Check 'upload-case-report 拒絕' ($r.Threw -and $r.Msg -match '本專案沒有設定 Azure DevOps')
Check '三支都沒有網路呼叫' ($global:HD5Net.Count -eq 0)

Write-Host '--- fetch-workitem 前置檢查（不連網）---'
$r = Run-Script 'fetch-workitem.ps1' @{ WorkItemUrl = "$ProjUrl/_workitems/edit/1"; ConfigStart = $clean }
Check '沒 -CaseName 又沒 -PeekOnly：連網前擋' ($r.Threw -and $r.Msg -match 'PeekOnly')
$r = Run-Script 'fetch-workitem.ps1' @{ WorkItemUrl = '1'; PeekOnly = $true; ConfigStart = $clean }
Check '號碼沒網址：連網前報錯' ($r.Threw -and $r.Msg -match 'tracker\.url')
$r = Run-Script 'fetch-workitem.ps1' @{ WorkItemUrl = "$ProjUrl/_workitems/edit/1"; CaseName = 'c'; ConfigStart = $clean }
Check '沒設定檔又沒 -SpecRoot：報錯不亂寫' ($r.Threw -and $r.Msg -match 'SpecRoot')
Check '以上沒有網路呼叫' ($global:HD5Net.Count -eq 0)

Write-Host '--- fetch-workitem -PeekOnly（假 API）---'
$fakeWi = [pscustomobject]@{ id = 12; rev = 3; fields = [pscustomobject]@{ 'System.Title' = '測試工單標題'; 'System.WorkItemType' = 'Task'; 'System.State' = 'New'; 'System.TeamProject' = 'example-project'; 'System.Description' = '<div>描述內容</div>' }; relations = @() }
# 留言（2026-11-24）：三則，4471 是要排除的那則（內容含「不該被看到」）
$fakeComments = [pscustomobject]@{ comments = @(
    [pscustomobject]@{ id = 4471; text = '<div>完成通知：不該被看到的內容</div>'; createdDate = '2026-11-18T10:00:00Z'; createdBy = [pscustomobject]@{ displayName = '開發者' } },
    [pscustomobject]@{ id = 4467; text = '<div>答覆檔已上傳<br/>請看 spec_1_r1_answer.html</div>'; createdDate = '2026-11-17T09:00:00Z'; createdBy = [pscustomobject]@{ displayName = '需求方' } },
    [pscustomobject]@{ id = 4465; text = '<p>補充：&lt;A&gt; 也要算</p>'; createdDate = '2026-11-16T08:00:00Z'; createdBy = [pscustomobject]@{ displayName = '需求方' } }) }
$global:HD5NetHandler = { param($Uri, $Method, $BodyText) if ($Method -eq 'Get' -and $Uri -match '/wit/workitems/12\?') { return $fakeWi }; if ($Method -eq 'Get' -and $Uri -match '/wit/workItems/12/comments\?') { return $fakeComments }; throw "未預期的呼叫：$Method $Uri" }
$global:HD5Net = @()
$before = @(Get-ChildItem -LiteralPath $projA -Recurse -File).Count
$r = Run-Script 'fetch-workitem.ps1' @{ WorkItemUrl = '12'; PeekOnly = $true; ConfigStart = $projA; Pat = 'SECRETPAT123' }
Check 'PeekOnly：號碼＋tracker.url 讀到工單' (-not $r.Threw -and $r.Out -match '測試工單標題' -and @($global:HD5Net | Where-Object { $_.Uri -like "$ProjUrl/_apis/wit/workitems/12*" -and $_.Uri -notmatch '/comments\?' }).Count -eq 1)
Check 'PeekOnly：留言只列 id／時間／人，不印內容' ($r.Out -match 'id 4465' -and $r.Out -match 'id 4471' -and $r.Out -notmatch '不該被看到' -and $r.Out -notmatch '答覆檔已上傳')
Check 'PeekOnly：不建立任何檔案' (@(Get-ChildItem -LiteralPath $projA -Recurse -File).Count -eq $before)
Check 'PeekOnly：預設不驗憑證' (@($global:HD5Net | Where-Object { -not $_.Trust }).Count -eq 0)
$projSelf = New-Proj 'projSelf' '{ "tracker": { "type": "azure-devops", "url": "https://devops.example.com/DefaultCollection/example-project" } }'
$global:HD5Net = @()
$r = Run-Script 'fetch-workitem.ps1' @{ WorkItemUrl = '12'; PeekOnly = $true; ConfigStart = $projSelf }
Check 'fetch 沒 PAT＋自架網址：用整合驗證（UseDefaultCredentials、沒有 PAT 標頭）' (-not $r.Threw -and $global:HD5Net.Count -gt 0 -and @($global:HD5Net | Where-Object { -not $_.DefaultCred -or $_.HasAuthHeader }).Count -eq 0)
$global:HD5Net = @()
$r = Run-Script 'fetch-workitem.ps1' @{ WorkItemUrl = '12'; PeekOnly = $true; ConfigStart = $projSelf; StrictCertificate = $true }
Check 'fetch -StrictCertificate：不略過憑證檢查' (-not $r.Threw -and $global:HD5Net.Count -gt 0 -and @($global:HD5Net | Where-Object { $_.Trust }).Count -eq 0)
$global:HD5Net = @()
$r = Run-Script 'fetch-workitem.ps1' @{ WorkItemUrl = '12'; PeekOnly = $true; ConfigStart = $projA }
Check 'fetch 沒 PAT＋雲端網址：報錯要 PAT、沒有網路呼叫' ($r.Threw -and $r.Msg -match 'PAT' -and $global:HD5Net.Count -eq 0)
$global:HD5Net = @()
$r = Run-Script 'fetch-workitem.ps1' @{ WorkItemUrl = '12'; PeekOnly = $true; ConfigStart = $projA; Pat = 'SECRETPAT123' }
Check 'PeekOnly：只讀、帶 PAT 標頭、輸出不含 PAT' (@($global:HD5Net | Where-Object { $_.Method -ne 'Get' -or -not $_.HasAuthHeader }).Count -eq 0 -and $r.Out -notmatch 'SECRETPAT123')
$global:HD5Net = @()
$r = Run-Script 'fetch-workitem.ps1' @{ WorkItemUrl = '12'; CaseName = 'case-12'; ConfigStart = $projA; Pat = 'SECRETPAT123'; NoRelated = $true }
$specFile = Join-Path $projA 'AI_Service\spec\case-12\case_spec_content\spec_001.md'
Check '正式抓取：寫到 workflow.json 推出的 spec 資料夾' (-not $r.Threw -and (Test-Path -LiteralPath $specFile) -and ([IO.File]::ReadAllText($specFile, [Text.Encoding]::UTF8)) -match '描述內容')
Check '正式抓取：建立 pm／sa／pg／qa 資料夾' (@('pm', 'sa', 'pg', 'qa' | Where-Object { Test-Path -LiteralPath (Join-Path $projA "AI_Service\spec\case-12\$_") }).Count -eq 4)
$cmFile = Join-Path $projA 'AI_Service\spec\case-12\case_spec_content\comments.md'
$cmText = if (Test-Path -LiteralPath $cmFile) { [IO.File]::ReadAllText($cmFile, [Text.Encoding]::UTF8) } else { '' }
Check '正式抓取：留言寫進 comments.md（舊→新、標 id、HTML 轉文字、換行保留）' ($cmText -match '來源工單：\[#12\]' -and $cmText.IndexOf('id 4465') -lt $cmText.IndexOf('id 4467') -and $cmText -match '補充：<A> 也要算' -and $cmText -match "答覆檔已上傳\r?\n請看")
Check '正式抓取：spec_001.md 末尾指向 comments.md' (([IO.File]::ReadAllText($specFile, [Text.Encoding]::UTF8)) -match '\[comments\.md\]\(comments\.md\)（3 則）')
$r = Run-Script 'fetch-workitem.ps1' @{ WorkItemUrl = '12'; CaseName = 'case-12'; ConfigStart = $projA; Pat = 'SECRETPAT123'; NoRelated = $true; Replace = $true; ExcludeCommentId = @(4471) }
$cmText = [IO.File]::ReadAllText($cmFile, [Text.Encoding]::UTF8)
Check '🔴 -ExcludeCommentId 4471：內容不擷取、只記 id；同工單重抓覆蓋 comments.md' (-not $r.Threw -and $cmText -notmatch '不該被看到' -and $cmText -match '已依指示排除留言 id：4471' -and $cmText -match 'id 4467' -and $r.Out -notmatch '不該被看到')
Write-Fixture (Join-Path $projA 'AI_Service\spec\case-12\case_spec_content\comments.md') "# 工單 #99 留言`n`n> 來源工單：[#99](x)`n"
$r = Run-Script 'fetch-workitem.ps1' @{ WorkItemUrl = '12'; CaseName = 'case-12'; ConfigStart = $projA; Pat = 'SECRETPAT123'; NoRelated = $true; Replace = $true }
Check '同一案子已有別張工單的 comments.md ⇒ 改存 comments-12.md、不覆蓋' (-not $r.Threw -and (Test-Path -LiteralPath (Join-Path $projA 'AI_Service\spec\case-12\case_spec_content\comments-12.md')) -and ([IO.File]::ReadAllText($cmFile, [Text.Encoding]::UTF8)) -match '#99')
$r = Run-Script 'fetch-workitem.ps1' @{ WorkItemUrl = '12'; CaseName = 'case-13'; ConfigStart = $projA; Pat = 'SECRETPAT123'; NoRelated = $true; NoComments = $true }
Check '-NoComments：不打留言 API、不產 comments.md' (-not $r.Threw -and -not (Test-Path -LiteralPath (Join-Path $projA 'AI_Service\spec\case-13\case_spec_content\comments.md')) -and $r.Out -match '留言：已略過')

Write-Host '--- 留言篩選（_comments.ps1，純函式）---'
$sel = Select-HD5Comments -Comments $fakeComments.comments -Id @(4465, 4467, 1) -ExcludeId @(4467)
Check 'Select：-Id 留下指定、-ExcludeId 再拿掉、列出不存在的 id' (@($sel.Comments).Count -eq 1 -and $sel.Comments[0].id -eq 4465 -and ($sel.ExcludedIds -join ',') -eq '4467' -and ($sel.MissingIds -join ',') -eq '1')
$sel = Select-HD5Comments -Comments $fakeComments.comments
Check 'Select：都沒給 ⇒ 全部' (@($sel.Comments).Count -eq 3 -and $sel.ExcludedIds.Count -eq 0)
Check 'Format-HD5CommentLine：一行摘要含 id、HTML 解碼' ((Format-HD5CommentLine $fakeComments.comments[2]) -match '（id 4465）：補充：<A> 也要算$')
$md = Format-HD5CommentsMarkdown -Comments @() -WorkItemId 12 -WorkItemUrl 'u' -FetchError '404'
Check 'Format-HD5CommentsMarkdown：讀取失敗要寫明（不是靜默空白）' ($md -match '留言讀取失敗：404')
$global:HD5NetHandler = $null

Write-Host '--- upload-case-report ---'
$sample = @"
# ai-case-report｜#281 x
- commit：abc1234
## 1. 需求一句話
## 2. 最終驗收條件
## 3. 實際改動範圍
## 5. 測試與驗收結果
## 6. 未盡事項
{{未填}}
"@
Check 'placeholder regex catches' ((@([regex]::Matches($sample, '\{\{[^}]*\}\}'))).Count -eq 1)
Check 'commit line regex' ($sample -match '(?m)^\s*-\s*\**commit')
$caseDir = Join-Path $projA 'AI_Service\spec\c1'
Write-Fixture (Join-Path $caseDir 'ai-case-report.md') $sample
$global:HD5Net = @()
$r = Run-Script 'upload-case-report.ps1' @{ WorkItemUrl = '281'; CaseName = 'c1'; ConfigStart = $projA }
Check '有佔位符：連網前停（不上傳）' ($r.Threw -and $r.Msg -match '沒有上傳' -and $global:HD5Net.Count -eq 0)
Write-Fixture (Join-Path $caseDir 'wrong-name.md') $sample
$r = Run-Script 'upload-case-report.ps1' @{ WorkItemUrl = '281'; ReportPath = (Join-Path $caseDir 'wrong-name.md'); ConfigStart = $projA }
Check '檔名不對就拒絕' ($r.Threw -and $r.Msg -match 'ai-case-report\.md')
$good = ($sample -replace '\{\{未填\}\}', '無') + "`n" + ('內容。' * 80)
Write-Fixture (Join-Path $caseDir 'ai-case-report.md') $good
$fakeTarget = [pscustomobject]@{ id = 281; fields = [pscustomobject]@{ 'System.Title' = '目標工單'; 'System.State' = 'Active'; 'System.TeamProject' = 'example-project' }; relations = @(
    [pscustomobject]@{ rel = 'AttachedFile'; url = 'u1'; attributes = [pscustomobject]@{ name = 'ai-case-report.md'; resourceCreatedDate = '2026-08-01T00:00:00Z' } }) }
$global:HD5NetHandler = {
    param($Uri, $Method, $BodyText)
    if ($Method -eq 'Get' -and $Uri -match '/wit/workitems/281\?') { return $fakeTarget }
    if ($Method -eq 'Get' -and $Uri -match '/wit/workItems/281/updates\?') { return [pscustomobject]@{ count = @($global:HD5Updates).Count; value = @($global:HD5Updates) } }
    if ($Method -eq 'Post' -and $Uri -match '/wit/attachments\?fileName=ai-case-report\.md') { return [pscustomobject]@{ id = 'att1'; url = "$Org/_apis/wit/attachments/att1" } }
    if ($Method -eq 'Patch' -and $Uri -match '/wit/workitems/281\?') { return $fakeTarget }
    throw "未預期的呼叫：$Method $Uri"
}
$global:HD5Net = @()
$r = Run-Script 'upload-case-report.ps1' @{ WorkItemUrl = '281'; CaseName = 'c1'; ConfigStart = $projA; Pat = 'SECRETPAT123' }
Check '預設只預覽：只讀工單、不上傳' (-not $r.Threw -and $r.Out -match '預覽：未上傳' -and $r.Out -match '第 2 版' -and @($global:HD5Net | Where-Object { $_.Method -ne 'Get' }).Count -eq 0)
Check '預覽輸出不含 PAT' ($r.Out -notmatch 'SECRETPAT123' -and $r.Out -match '-Pat 參數')
$global:HD5Net = @()
$r = Run-Script 'upload-case-report.ps1' @{ WorkItemUrl = '281'; CaseName = 'c1'; ConfigStart = $projA; Pat = 'SECRETPAT123'; Upload = $true; WhatIfOnly = $true }
Check '-Upload 與 -WhatIfOnly 同時給：以預覽為準' (-not $r.Threw -and @($global:HD5Net | Where-Object { $_.Method -ne 'Get' }).Count -eq 0)
Check '預覽沒給 -CasePath：不擋，但印出正式上傳會被擋' ($r.Out -match '正式執行會被擋' -and $r.Out -match 'CasePath')

Write-Host '--- upload-case-report：上傳前工單閘（與改待驗收同一套）---'
$featBody = "# 功能`n使用者可見行為。`n## 子功能（Sub-features）`n- a`n## 使用者怎麼到達（How to get to it）`n選單 → A`n## 怎麼操作（Driving it）`n前提：已登入`n1. 點 A → 看到 B`n## 地雷（Gotchas）`n- 無`n"
$docBody = "# verify-x`n## 啟動（Launch）`nx`n## 體檢（Doctor）`nx`n## 操作（Drive）`nx`n## 證據（Evidence）`nx`n## 清理（Cleanup）`nx`n## 工具腳本（Helpers）`nx`n"
$script:ui = 0
# 案子＝<tmp>/uN/AI_Service/spec/case（含合格的 ai-case-report.md），功能地圖＝<tmp>/uN/AI_Service/verify
function New-UpCase([hashtable]$files, [switch]$BadMap) {
    $script:ui++
    $base = Join-Path $tmpRoot "u$($script:ui)\AI_Service"
    $case = Join-Path $base 'spec\case'
    Write-Fixture (Join-Path $case 'ai-case-report.md') $good
    New-Item -ItemType Directory -Path (Join-Path $case 'qa') -Force | Out-Null
    foreach ($k in $files.Keys) { Write-Fixture (Join-Path $case "qa\$k") $files[$k] }
    $vr = Join-Path $base 'verify'
    Write-Fixture (Join-Path $vr 'verify-x.md') $docBody
    Write-Fixture (Join-Path $vr 'features\README.md') "# 功能地圖`n共同前提"
    $ids = if ($BadMap) { @('login', 'list') } else { @('login', 'list', 'edit') }
    foreach ($id in $ids) { Write-Fixture (Join-Path $vr "features\$id.md") $featBody }
    return $case
}
$onsiteOk = "- 日期：2026-11-20 10:00`n總結：通過`n"
$cPass = New-UpCase @{ 'Codex驗收結果_R1.md' = "總結：通過"; 'onsite-gate_R1.md' = $onsiteOk }
$cNoReview = New-UpCase @{ 'onsite-gate_R1.md' = $onsiteOk }
$cOnsiteFail = New-UpCase @{ 'Codex驗收結果_R1.md' = "總結：通過"; 'onsite-gate_R1.md' = "- 日期：2026-11-20 10:00`n總結：不通過（AC-2 Fail）`n" }
$cBadMap = New-UpCase @{ 'Codex驗收結果_R1.md' = "總結：通過"; 'onsite-gate_R1.md' = $onsiteOk } -BadMap
function Up([string]$case, [hashtable]$extra) {
    $h = @{ WorkItemUrl = '281'; ConfigStart = $projA; Pat = 'SECRETPAT123'; ToolsDir = $vmDir }
    if ($case) { $h.ReportPath = (Join-Path $case 'ai-case-report.md'); $h.CasePath = $case; $h.VerifyRoot = [IO.Path]::GetFullPath((Join-Path $case '..\..\verify')) }
    foreach ($k in $extra.Keys) { $h[$k] = $extra[$k] }
    $global:HD5Net = @()
    return (Run-Script 'upload-case-report.ps1' $h)
}
$r = Up $null @{ ReportPath = (Join-Path $cPass 'ai-case-report.md'); Upload = $true }
Check '-Upload 沒給 -CasePath：連網前擋' ($r.Threw -and $r.Msg -match 'CasePath' -and $global:HD5Net.Count -eq 0)
$r = Up $cNoReview @{ Upload = $true }
Check '-Upload 缺獨立驗收結果：擋、沒有網路呼叫' ($r.Threw -and $r.Msg -match '工單閘未通過，不上傳結案報告' -and $r.Msg -match '缺獨立驗收' -and $global:HD5Net.Count -eq 0)
$r = Up $cOnsiteFail @{ Upload = $true }
Check '-Upload 站上關卡未通過：擋' ($r.Threw -and $r.Msg -match '站上關卡最新一輪' -and $global:HD5Net.Count -eq 0)
$r = Up $cBadMap @{ Upload = $true }
Check '-Upload 功能地圖不合格：擋' ($r.Threw -and $r.Msg -match '功能地圖' -and $global:HD5Net.Count -eq 0)
$emptyTools = Join-Path $tmpRoot 'empty-tools'; New-Item -ItemType Directory -Path $emptyTools -Force | Out-Null
$r = Up $cPass @{ Upload = $true; ToolsDir = $emptyTools }
Check '-Upload 檢查器找不到：fail closed（關卡全過也擋）' ($r.Threw -and $r.Msg -match 'fail closed' -and $global:HD5Net.Count -eq 0)
$r = Up $null @{ ReportPath = (Join-Path $cNoReview 'ai-case-report.md'); Upload = $true; SkipAcceptanceGate = '   ' }
Check '-SkipAcceptanceGate 理由空白：不放行' ($r.Threw -and $r.Msg -match 'CasePath' -and $global:HD5Net.Count -eq 0)
$r = Up $null @{ ReportPath = (Join-Path $cNoReview 'ai-case-report.md'); Upload = $true; SkipAcceptanceGate = '緊急修正無案子，使用者同意' }
Check '-SkipAcceptanceGate 有理由：放行上傳，輸出明講略過與理由' (-not $r.Threw -and $r.Out -match '已略過工單閘' -and $r.Out -match '緊急修正無案子' -and @($global:HD5Net | Where-Object { $_.Method -eq 'Post' }).Count -eq 1)
$r = Up $cOnsiteFail @{}
Check '預覽（沒 -Upload）閘沒過：不擋，印出閘結果與「會被擋」' (-not $r.Threw -and $r.Out -match '正式執行會被擋' -and $r.Out -match '站上關卡' -and $r.Out -match '加 -Upload 會被擋' -and @($global:HD5Net | Where-Object { $_.Method -ne 'Get' }).Count -eq 0)
$r = Up $cOnsiteFail @{ Upload = $true; WhatIfOnly = $true }
Check '-Upload＋-WhatIfOnly 閘沒過：當預覽，不擋' (-not $r.Threw -and $r.Out -match '正式執行會被擋' -and @($global:HD5Net | Where-Object { $_.Method -ne 'Get' }).Count -eq 0)
$r = Up $cPass @{}
Check '預覽閘通過：印出通過' (-not $r.Threw -and $r.Out -match '工單閘｜通過')
$global:HD5Net = @()
$h = @{ WorkItemUrl = '281'; ConfigStart = $projSelf; ReportPath = (Join-Path $cPass 'ai-case-report.md'); CasePath = $cPass; VerifyRoot = [IO.Path]::GetFullPath((Join-Path $cPass '..\..\verify')); ToolsDir = $vmDir }
$r = Run-Script 'upload-case-report.ps1' $h
Check 'upload 沒 PAT＋自架網址：用整合驗證' (-not $r.Threw -and $global:HD5Net.Count -gt 0 -and @($global:HD5Net | Where-Object { -not $_.DefaultCred -or $_.HasAuthHeader }).Count -eq 0)
$global:HD5Net = @()
$h.ConfigStart = $projA
$r = Run-Script 'upload-case-report.ps1' $h
Check 'upload 沒 PAT＋雲端網址：報錯要 PAT、沒有網路呼叫' ($r.Threw -and $r.Msg -match 'PAT' -and $global:HD5Net.Count -eq 0)
$auto = Join-Path $projA 'AI_Service\spec\cAuto'
Write-Fixture (Join-Path $auto 'ai-case-report.md') $good
Write-Fixture (Join-Path $auto 'qa\Codex驗收結果_R1.md') '總結：通過'
Write-Fixture (Join-Path $auto 'qa\onsite-gate_R1.md') $onsiteOk
$r = Up $null @{ CaseName = 'cAuto'; VerifyRoot = [IO.Path]::GetFullPath((Join-Path $cPass '..\..\verify')); Upload = $true }
$okAuto = (-not $r.Threw -and $r.Out -match '由 -CaseName 推得' -and @($global:HD5Net | Where-Object { $_.Method -eq 'Post' }).Count -eq 1)
Check '-CaseName 有、-CasePath 沒給：推 <SpecRoot>/<CaseName>，閘通過就上傳' $okAuto
# 失敗時印出實際狀況（2026-11-28：GitHub 的 Windows PowerShell 5.1 上失敗、本機重現不出來）
if (-not $okAuto) {
    Write-Host "       Threw=$($r.Threw) Post=$(@($global:HD5Net | Where-Object { $_.Method -eq 'Post' }).Count) 推得=$($r.Out -match '由 -CaseName 推得')"
    if ($r.Msg) { Write-Host "       Msg：$($r.Msg)" }
    ($r.Out -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 12) | ForEach-Object { Write-Host "       | $_" }
}
$r = Up $null @{ ReportPath = (Join-Path $cPass 'ai-case-report.md'); CaseName = 'no-such-case'; Upload = $true }
Check '-CaseName 推出的資料夾不存在：照樣擋（缺 -CasePath）' ($r.Threw -and $r.Msg -match 'CasePath' -and $global:HD5Net.Count -eq 0)
$r = Up $cPass @{ Upload = $true }
$post = @($global:HD5Net | Where-Object { $_.Method -eq 'Post' }); $patch = @($global:HD5Net | Where-Object { $_.Method -eq 'Patch' })
Check '-Upload：上傳附件＋掛到工單各一次' (-not $r.Threw -and $post.Count -eq 1 -and $patch.Count -eq 1 -and $r.Out -match '已把 ai-case-report\.md（第 2 版）')
Check '-Upload：PATCH 是陣列、只加 AttachedFile relation' ($patch.Count -eq 1 -and $patch[0].Body.TrimStart().StartsWith('[') -and $patch[0].Body -match 'AttachedFile' -and $patch[0].Body -notmatch 'System.State')
Check '-Upload：輸出不含 PAT' ($r.Out -notmatch 'SECRETPAT123')

Write-Host '--- upload-case-report：上傳前工單閘的密鑰掃描（2026-11-28，與改待驗收同一套）---'
$cSec = New-UpCase @{ 'Codex驗收結果_R1.md' = '總結：通過'; 'onsite-gate_R1.md' = $onsiteOk }
$sg = { param([string[]]$a) $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'; try { (& git -C $cSec @a 2>$null) } finally { $ErrorActionPreference = $eap } }
$null = & $sg @('init', '-q'); $null = & $sg @('config', 'user.email', 't@t'); $null = & $sg @('config', 'user.name', 't'); $null = & $sg @('config', 'core.autocrlf', 'false')
Write-Fixture (Join-Path $cSec 'app.cfg') "x=1`n"; $null = & $sg @('add', 'app.cfg'); $null = & $sg @('commit', '-q', '-m', 'base'); $uBase = (& $sg @('rev-parse', 'HEAD'))
Write-Fixture (Join-Path $cSec 'app.cfg') ("x=1`nconn=Server=db;" + 'Pass' + "word=RealOne42;`n"); $null = & $sg @('commit', '-q', '-am', 'secret'); $uHead = (& $sg @('rev-parse', 'HEAD'))
Write-Fixture (Join-Path $cSec 'qa\獨立驗收委託_R1.md') "- 受驗 diff：``git diff $uBase..$uHead```n"
$r = Up $cSec @{ Upload = $true }
Check '🔴 -Upload：其他關卡都過、審過的 diff 有密鑰 ⇒ 連網前擋、不印密鑰原文' ($r.Threw -and $r.Msg -match '疑似密鑰' -and $r.Msg -notmatch 'RealOne42' -and $global:HD5Net.Count -eq 0)
$r = Up $cSec @{}
Check '預覽（沒 -Upload）有密鑰：不擋，印出「正式執行會被擋」與密鑰原因' (-not $r.Threw -and $r.Out -match '正式執行會被擋' -and $r.Out -match '疑似密鑰' -and @($global:HD5Net | Where-Object { $_.Method -ne 'Get' }).Count -eq 0)
Write-Fixture (Join-Path $cSec 'qa\獨立驗收委託_R1.md') "- 受驗 diff：``git diff $uBase..$uBase```n"
$r = Up $cSec @{ Upload = $true }
Check '-Upload：審過的範圍沒有密鑰 ⇒ 上傳' (-not $r.Threw -and @($global:HD5Net | Where-Object { $_.Method -eq 'Post' }).Count -eq 1)

Write-Host '--- upload-case-report：需求方驗收完成後上傳要有 5.1 與退回總帳（2026-11-25）---'
$rl = "# 退回紀錄`n`n| 輪次 | 退回原因 | 處理類別 | 根因類別 | 錯誤寫法 | 為什麼 | 修正 |`n|---|---|---|---|---|---|---|`n| R1 | a | 程式錯誤 | 樣本不足 | 名稱只讀 Name 欄 | b | c |`n"
$cDone = New-UpCase @{ 'Codex驗收結果_R1.md' = '總結：通過'; 'onsite-gate_R1.md' = $onsiteOk; 'rework-log.md' = $rl }
$fakeTarget.fields.'System.State' = '驗收完成'
$global:HD5Updates = @(
    [pscustomobject]@{ id = 1; fields = [pscustomobject]@{ 'System.State' = [pscustomobject]@{ oldValue = '待驗收'; newValue = '驗收未過' } } },
    [pscustomobject]@{ id = 2; fields = [pscustomobject]@{ 'System.State' = [pscustomobject]@{ oldValue = '待驗收'; newValue = '驗收完成' } } })
$r = Up $cDone @{ Upload = $true }
Check '🔴 已驗收完成後上傳：rework-log 1 列、報告沒有 5.1 ⇒ 擋、不上傳（有讀歷程）' ($r.Threw -and $r.Msg -match '5\.1' -and @($global:HD5Net | Where-Object { $_.Method -ne 'Get' }).Count -eq 0 -and @($global:HD5Net | Where-Object { $_.Uri -match '/updates\?' }).Count -ge 1)
$r = Up $cDone @{}
Check '已驗收完成、預覽：印「正式執行會被擋」、不擋不寫' (-not $r.Threw -and $r.Out -match '退回紀錄未通過（正式執行會被擋）' -and $r.Out -match '加 -Upload 會被擋' -and @($global:HD5Net | Where-Object { $_.Method -ne 'Get' }).Count -eq 0)
$fakeTarget.fields.'System.State' = 'Closed'
$r = Up $cDone @{ Upload = $true }
Check '目前狀態已改成別的、但歷程進過「驗收完成」⇒ 一樣要檢查' ($r.Threw -and $r.Msg -match '5\.1')
Write-Fixture (Join-Path $cDone 'ai-case-report.md') ($good + "`n### 5.1 退回檢討`n`n- 送驗 2 次、退回 1 次`n`n| 輪次 | 退回原因 | 根因類別 | 錯誤寫法 | 為什麼 | 規則 |`n|---|---|---|---|---|---|`n| R1 | a | 樣本不足 | 名稱只讀 Name 欄 | b | c |`n")
$r = Up $cDone @{ Upload = $true }
Check '🔴 已驗收完成：5.1 有 1 列、總帳沒有本案 ⇒ 擋' ($r.Threw -and $r.Msg -match '總帳')
Write-Fixture (Join-Path (Split-Path -Parent $cDone) 'rework-ledger.md') "| 結案日 | 案號 | 輪次 | 根因類別 | 錯誤寫法 | 原因一句 | 為什麼沒先抓到 | 對應規則 |`n|---|---|---|---|---|---|---|---|`n| 2026-11-25 | #281 | R1 | 樣本不足 | 名稱只讀 Name 欄 | a | b | 無（x） |`n"
$r = Up $cDone @{ Upload = $true }
Check '已驗收完成：rework-log、5.1、總帳都 1 列 ⇒ 上傳' (-not $r.Threw -and @($global:HD5Net | Where-Object { $_.Method -eq 'Post' }).Count -eq 1)
$fakeTarget.fields.'System.State' = 'Active'
$global:HD5Updates = @()
$cNotDone = New-UpCase @{ 'Codex驗收結果_R1.md' = '總結：通過'; 'onsite-gate_R1.md' = $onsiteOk; 'rework-log.md' = $rl }
$r = Up $cNotDone @{ Upload = $true }
Check '還沒驗收完成（QA 通過後第一次上傳）：不要求 5.1' (-not $r.Threw -and @($global:HD5Net | Where-Object { $_.Method -eq 'Post' }).Count -eq 1)
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
if ($script:fail) { Write-Host "FAILED: $($script:fail)" -ForegroundColor Red; exit 1 } else { Write-Host 'ALL PASSED' -ForegroundColor Green; exit 0 }
