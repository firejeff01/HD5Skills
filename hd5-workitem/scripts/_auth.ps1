<#
.SYNOPSIS
  hd5-workitem 的認證（唯一一份）：workitem-ops、fetch-workitem、fetch-related-attachments、upload-case-report 共用。

.DESCRIPTION
  由 _workitem-ops-lib.ps1 與 _devops-lib.ps1 以 dot-source 載入，不可直接執行。
  🔴 不得內嵌 PAT；回傳物件只帶 Authorization 標頭與「來源說明」，任何輸出只印 Source，不印 PAT。

  New-DevOpsAuthContext 取用順序（找到第一個就用）：
    1. -Pat
    2. 環境變數：寫入（-Write）＝AZURE_DEVOPS_PAT_WRITE → AZURE_DEVOPS_PAT；唯讀＝AZURE_DEVOPS_PAT
    3. -PatFile（指定的檔不存在就報錯，不默默改走別的認證）
    4. -ScriptRoot 資料夾的 PAT 檔：寫入＝pat.write.local.txt → pat.local.txt；唯讀＝pat.local.txt
    5. Windows 整合驗證（目前登入帳號，UseDefaultCredentials）——只在 Windows、而且不是雲端網址時；
       雲端（dev.azure.com、*.visualstudio.com）不支援整合驗證，非 Windows 也沒有，這兩種情況沒 PAT 就報錯說明怎麼設。
  -ForceWindows（workitem-ops 的 -UseWindowsAuth）：略過 PAT 直接用整合驗證；雲端或非 Windows 時報錯。
  回傳 @{ Mode = 'PAT'|'Windows'; Source = 說明; Headers = @{Authorization=…} 或 @{} }
  相容 Windows PowerShell 5.1 與 PowerShell 7；必須存成 UTF-8 with BOM。
#>

function Test-HD5CloudDevOpsUrl {
    param([string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return $false }
    try { $h = ([Uri]$Url).Host.ToLowerInvariant() } catch { return $false }
    return ($h -eq 'dev.azure.com' -or $h.EndsWith('.visualstudio.com'))
}

function Test-HD5IsWindows {
    if ($PSVersionTable.PSVersion.Major -lt 6) { return $true }
    return [bool]$IsWindows
}

function New-DevOpsPatHeaders {
    param([Parameter(Mandatory = $true)][string]$Pat)
    return @{ Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$Pat")) }
}

# PAT 檔：取第一行非空白、非 # 開頭的內容。
function Read-DevOpsPatFileLine {
    param([string]$Path)
    $line = Get-Content -LiteralPath $Path -Encoding UTF8 | Where-Object { $_.Trim() -ne '' -and -not $_.TrimStart().StartsWith('#') } | Select-Object -First 1
    if ($null -eq $line -or $line.Trim() -eq '') { return $null }
    return $line.Trim()
}

function New-DevOpsAuthContext {
    param(
        [string]$Pat,
        [string]$PatFile,
        [string]$ScriptRoot,
        [switch]$ForceWindows,
        # 會寫入工單（留言／改狀態／上傳）：環境變數與檔案先找寫入用的那組
        [switch]$Write,
        # 目標網址（工單網址或組織網址）：判斷是不是雲端、組 PAT 申請網址
        [string]$TargetUrl
    )
    $cloud = Test-HD5CloudDevOpsUrl $TargetUrl
    $win = Test-HD5IsWindows
    $scope = if ($Write) { 'Work Items - Read & Write' } else { 'Work Items - Read' }
    # 一定包 @()：單一元素的 if 結果會被拆成字串，[0] 就變成第一個字元
    $envNames = @(if ($Write) { 'AZURE_DEVOPS_PAT_WRITE', 'AZURE_DEVOPS_PAT' } else { 'AZURE_DEVOPS_PAT' })
    $fileNames = @(if ($Write) { 'pat.write.local.txt', 'pat.local.txt' } else { 'pat.local.txt' })

    if ($ForceWindows) {
        if ($cloud) { throw '雲端 Azure DevOps（dev.azure.com／*.visualstudio.com）不支援 Windows 整合驗證，請改用 PAT（拿掉 -UseWindowsAuth）。' }
        if (-not $win) { throw '這台不是 Windows，沒有 Windows 整合驗證，請改用 PAT（拿掉 -UseWindowsAuth）。' }
        return @{ Mode = 'Windows'; Source = '-UseWindowsAuth（Windows 整合驗證）'; Headers = @{} }
    }
    if (-not [string]::IsNullOrWhiteSpace($Pat)) { return @{ Mode = 'PAT'; Source = '-Pat 參數'; Headers = (New-DevOpsPatHeaders -Pat $Pat.Trim()) } }
    foreach ($envName in $envNames) {
        $v = [Environment]::GetEnvironmentVariable($envName)
        if (-not [string]::IsNullOrWhiteSpace($v)) { return @{ Mode = 'PAT'; Source = "環境變數 $envName"; Headers = (New-DevOpsPatHeaders -Pat $v.Trim()) } }
    }
    $files = @()
    if (-not [string]::IsNullOrWhiteSpace($PatFile)) {
        if (-not (Test-Path -LiteralPath $PatFile -PathType Leaf)) { throw "找不到 -PatFile 指定的檔：$PatFile" }
        $files += $PatFile
    }
    if ($ScriptRoot) { foreach ($n in $fileNames) { $files += (Join-Path $ScriptRoot $n) } }
    foreach ($f in $files) {
        if (Test-Path -LiteralPath $f -PathType Leaf) {
            $line = Read-DevOpsPatFileLine -Path $f
            if ($line) { return @{ Mode = 'PAT'; Source = "檔案 $([IO.Path]::GetFileName($f))"; Headers = (New-DevOpsPatHeaders -Pat $line) } }
        }
    }
    if (-not $cloud -and $win) { return @{ Mode = 'Windows'; Source = 'Windows 整合驗證（目前登入帳號）'; Headers = @{} } }

    $why = if ($cloud) { '雲端 Azure DevOps 不支援 Windows 整合驗證' } else { '這台不是 Windows，沒有 Windows 整合驗證' }
    $where = '<Azure DevOps 組織網址>/_usersSettings/tokens（右上角 User settings → Personal access tokens）'
    if ($TargetUrl) {
        try { $u = [Uri]$TargetUrl; $seg = $u.AbsolutePath.Trim('/').Split('/'); $where = "$($u.Scheme)://$($u.Authority)/$($seg[0])/_usersSettings/tokens" } catch { }
    }
    $fileHint = if ($ScriptRoot) { Join-Path $ScriptRoot $fileNames[0] } else { $fileNames[0] }
    throw @"
找不到 Azure DevOps PAT（$why，一定要 PAT）。設定方式擇一（權限：$scope）：
  1. 建立 $fileHint，內容就是一行 PAT（此檔不進版控，範本見同目錄 pat.local.example.txt）
  2. 設環境變數 $($envNames[0])
  3. 呼叫時帶 -PatFile <PAT 檔路徑> 或 -Pat <PAT>
PAT 申請：$where
"@
}
