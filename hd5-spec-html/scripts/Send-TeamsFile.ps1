<#
.SYNOPSIS
  （選配工具：需要 Windows＋Teams 桌面版；沒有就人工傳送）
  用這台機器上正在執行的 Teams 桌面版（新版 ms-teams.exe），以目前登入者本人的名義，對指定的人送出一則訊息，可附一個檔案。

.DESCRIPTION
  沒有 Teams API、不需要任何權限或 token：全程操作使用者自己的 Teams 視窗（UI Automation ＋ Win32 訊息）。
  做法整合自 2026-09-03／09-04 三個 session 的實測（規則見 hd5-spec-html/SKILL.md 第九節）：
    1. 開聊天：msteams://teams.microsoft.com/l/chat/0/0?users=<mail>；再用 EnumWindows 依標題「聊天 | <對象>」鎖定聊天視窗
       （🔴 不能用 MainWindowHandle：開會時它指向會議視窗）
    2. 前景化：AttachThreadInput → ShowWindow → SetForegroundWindow，驗 GetForegroundWindow 相等
    3. 附檔：「附加檔案」鈕走 ExpandCollapsePattern → 同一行程內立刻 Invoke「從此裝置上傳」→ #32770「開啟」對話框
       → 檔名欄（控制項 ID 1148）逐字 WM_CHAR → 用 UIA 讀回逐字核對 → Enter
       → 🔴 以「移除附件」鈕的數量判斷附件真的掛上（檔名字串會出現在歷史訊息裡，不能拿來判斷）
    4. 打字：WM_CHAR 逐字投遞到 Chrome_WidgetWin_1 子視窗；每字前驗前景仍是聊天視窗；打完用 TextPattern 讀回，去空白後逐字相符才送
    5. 送出：Button「傳送」或「傳送 (…)」InvokePattern（名稱後綴隨 Teams 版本／Enter 送出設定而變，2026-10-21 實見只叫「傳送」）；
       等到訊息狀態變「已傳送」才算成功
  失敗時附件與草稿留在輸入框、不會送出；重跑前先 -Action Inspect 看草稿是否為空。

  🔴 訊息會以本人名義出現，內容用本人口吻；不要在螢幕鎖定或使用者正在打字時跑（字元會跟著進別的對話框）。

.EXAMPLE
  # 只看：聊天視窗找得到嗎、草稿是不是空的、目前附件幾個
  & ".../Send-TeamsFile.ps1" -To someone@example.com -Peer 王小明 -Action Inspect

.EXAMPLE
  # 送檔＋訊息
  & ".../Send-TeamsFile.ps1" -To someone@example.com -Peer 王小明 -File "D:\spec\spec_1432.html" -MessageFile ".\teams.txt"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$To,
    [Parameter(Mandatory = $true)][string]$Peer,
    [ValidateSet('Inspect', 'Send', 'Clear')][string]$Action = 'Send',
    [string]$File,
    [string]$Message,
    [string]$MessageFile,
    [int]$OpenWaitSec = 6,
    [int]$AttachWaitSec = 45,
    [int]$SentWaitSec = 90
)
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
# 選配工具：只有 Windows＋已登入的 Teams 桌面版能用；其他環境請人工傳檔
if ($env:OS -ne 'Windows_NT') { throw 'Send-TeamsFile.ps1 只能在 Windows＋Teams 桌面版上執行；這台不是 Windows，請改用人工傳送（把 HTML 檔與訊息自己傳給填答者）' }
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
if (-not ('TeamsNative' -as [type])) {
    Add-Type @"
using System; using System.Text; using System.Runtime.InteropServices; using System.Collections.Generic;
public static class TeamsNative {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc p, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr h, EnumProc p, IntPtr l);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern int GetDlgCtrlID(IntPtr h);
  [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool att);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  public static List<IntPtr> Found = new List<IntPtr>();
  public static bool Collect(IntPtr h, IntPtr l) { Found.Add(h); return true; }
  public static string Text(IntPtr h) { var s = new StringBuilder(512); GetWindowTextW(h, s, 512); return s.ToString(); }
  public static string Cls(IntPtr h) { var s = new StringBuilder(256); GetClassNameW(h, s, 256); return s.ToString(); }
  public static uint Pid(IntPtr h) { uint p; GetWindowThreadProcessId(h, out p); return p; }
  public static uint Tid(IntPtr h) { uint p; return GetWindowThreadProcessId(h, out p); }
  public static void Chars(IntPtr h, string s, int delayMs) { foreach (char c in s) { PostMessageW(h, 0x0102, (IntPtr)c, IntPtr.Zero); if (delayMs > 0) System.Threading.Thread.Sleep(delayMs); } }
  public static void Key(IntPtr h, int vk) { PostMessageW(h, 0x0100, (IntPtr)vk, IntPtr.Zero); PostMessageW(h, 0x0101, (IntPtr)vk, IntPtr.Zero); }
}
"@
}
$A = [System.Windows.Automation.AutomationElement]
$TS = [System.Windows.Automation.TreeScope]::Descendants
function Norm([string]$s) { if ($null -eq $s) { '' } else { ($s -replace '\s', '') } }
function Tops { [TeamsNative]::Found.Clear(); [void][TeamsNative]::EnumWindows([TeamsNative+EnumProc]{ param($h, $l) [TeamsNative]::Collect($h, $l) }, [IntPtr]::Zero); return @([TeamsNative]::Found) }
function Kids($h) { [TeamsNative]::Found.Clear(); [void][TeamsNative]::EnumChildWindows($h, [TeamsNative+EnumProc]{ param($a, $b) [TeamsNative]::Collect($a, $b) }, [IntPtr]::Zero); return @([TeamsNative]::Found) }
function Find-ChatWindow {
    $pids = @((Get-Process ms-teams -ErrorAction SilentlyContinue).Id)
    if ($pids.Count -eq 0) { throw 'Teams 桌面版沒有在執行（ms-teams.exe）' }
    foreach ($h in Tops) {
        if (-not [TeamsNative]::IsWindowVisible($h)) { continue }
        if ($pids -notcontains [int][TeamsNative]::Pid($h)) { continue }
        $t = [TeamsNative]::Text($h)
        if ($t -like '*聊天*' -and $t -like "*$Peer*") { return $h }
    }
    return [IntPtr]::Zero
}
function Set-Foreground($h) {
    $me = [TeamsNative]::GetCurrentThreadId(); $fg = [TeamsNative]::GetForegroundWindow(); $ft = [TeamsNative]::Tid($fg)
    [void][TeamsNative]::AttachThreadInput($me, $ft, $true)
    [void][TeamsNative]::ShowWindow($h, 9); [void][TeamsNative]::SetForegroundWindow($h)
    [void][TeamsNative]::AttachThreadInput($me, $ft, $false)
    Start-Sleep -Milliseconds 600
    return ([TeamsNative]::GetForegroundWindow() -eq $h)
}
function Get-Buttons($root, [string]$name) {
    $c = New-Object System.Windows.Automation.PropertyCondition($A::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)
    $out = @(); foreach ($b in $root.FindAll($TS, $c)) { if ($b.Current.Name -eq $name) { $out += $b } }; return $out
}
function Get-Compose($root) {
    $c = New-Object System.Windows.Automation.PropertyCondition($A::ControlTypeProperty, [System.Windows.Automation.ControlType]::Edit)
    foreach ($e in $root.FindAll($TS, $c)) { if ($e.Current.AutomationId -like 'new-message-*') { return $e } }
    return $null
}
function Get-Draft($edit) {
    $t = $edit.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern).DocumentRange.GetText(-1).Trim()
    if ($t -eq '輸入訊息') { return '' } else { return $t }
}
function Get-TypeTarget($chat) {
    foreach ($k in Kids $chat) { if ([TeamsNative]::Cls($k) -eq 'Chrome_WidgetWin_1') { return $k } }
    return $chat
}

# --- 訊息 -------------------------------------------------------------------
if ($MessageFile) { if (-not (Test-Path -LiteralPath $MessageFile)) { throw "找不到訊息檔：$MessageFile" }; $Message = [IO.File]::ReadAllText($MessageFile, [Text.Encoding]::UTF8) }
if ($Message) { $Message = $Message.Trim() }
if ($Action -eq 'Send' -and [string]::IsNullOrWhiteSpace($Message)) { throw 'Send 需要 -Message 或 -MessageFile（Teams 不允許只送附件不寫字）' }
if ($File) { if (-not (Test-Path -LiteralPath $File)) { throw "找不到附件：$File" }; $File = (Resolve-Path -LiteralPath $File).Path }

# --- 1. 開聊天並鎖定視窗 ------------------------------------------------------
$chat = Find-ChatWindow
if ($chat -eq [IntPtr]::Zero) {
    Start-Process ('msteams://teams.microsoft.com/l/chat/0/0?users=' + [Uri]::EscapeDataString($To))
    for ($i = 0; $i -lt $OpenWaitSec * 2 -and $chat -eq [IntPtr]::Zero; $i++) { Start-Sleep -Milliseconds 500; $chat = Find-ChatWindow }
}
if ($chat -eq [IntPtr]::Zero) { throw "找不到標題含「聊天」與「$Peer」的 Teams 視窗（開會中深層連結不一定切得過去；請先手動開啟與 $Peer 的聊天）" }
Write-Host "聊天視窗：$([TeamsNative]::Text($chat))"
$fgOk = Set-Foreground $chat
Write-Host "前景化：$fgOk"
$root = $A::FromHandle($chat)
$edit = Get-Compose $root
if (-not $edit) { throw '找不到輸入框（UIA 樹沒醒或不是聊天視窗）' }
$draft = Get-Draft $edit
$rmBtns = @(Get-Buttons $root '移除附件')
Write-Host "草稿：$($draft.Length) 字｜草稿附件：$($rmBtns.Count) 個"

if ($Action -eq 'Inspect') { if ($draft) { Write-Host "草稿內容：$draft" }; return }
if ($Action -eq 'Clear') {
    $target = Get-TypeTarget $chat
    try { $edit.SetFocus() } catch { }
    for ($i = 0; $i -lt ($draft.Length + 30); $i++) { [TeamsNative]::Key($target, 0x23); [TeamsNative]::Key($target, 0x08) }
    Start-Sleep -Milliseconds 800
    Write-Host "清除後草稿：$((Get-Draft (Get-Compose ($A::FromHandle($chat)))).Length) 字"; return
}
if ($draft) { throw "輸入框已有草稿（$($draft.Length) 字），不覆蓋；先 -Action Clear 或手動清空" }
if ($rmBtns.Count -gt 0) { throw "輸入框已有 $($rmBtns.Count) 個草稿附件，先手動移除再跑（避免重複附件）" }

# --- 2. 附檔 ---------------------------------------------------------------
if ($File) {
    $attach = @(Get-Buttons $root '附加檔案')
    if ($attach.Count -eq 0) { throw '找不到「附加檔案」鈕' }
    $attach[0].GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()
    Start-Sleep -Milliseconds 900
    $mc = New-Object System.Windows.Automation.PropertyCondition($A::ControlTypeProperty, [System.Windows.Automation.ControlType]::MenuItem)
    $item = $null
    foreach ($e in $root.FindAll($TS, $mc)) { if ($e.Current.Name -eq '從此裝置上傳') { $item = $e; break } }
    if (-not $item) { throw '「從此裝置上傳」選單項目沒出現（焦點掉了會自動收起；重跑）' }
    $item.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()

    $dlg = [IntPtr]::Zero
    for ($i = 0; $i -lt 25 -and $dlg -eq [IntPtr]::Zero; $i++) {
        Start-Sleep -Milliseconds 600
        foreach ($h in Tops) { if ([TeamsNative]::IsWindowVisible($h) -and [TeamsNative]::Cls($h) -eq '#32770' -and [TeamsNative]::Text($h) -eq '開啟') { $dlg = $h; break } }
    }
    if ($dlg -eq [IntPtr]::Zero) { throw '「開啟」檔案對話框沒出現' }
    $fileEdit = [IntPtr]::Zero
    foreach ($k in Kids $dlg) { if ([TeamsNative]::Cls($k) -eq 'Edit' -and [TeamsNative]::GetDlgCtrlID($k) -eq 1148) { $fileEdit = $k; break } }
    if ($fileEdit -eq [IntPtr]::Zero) { throw '對話框裡找不到檔名欄（控制項 1148）' }
    for ($i = 0; $i -lt 400; $i++) { [void][TeamsNative]::PostMessageW($fileEdit, 0x0102, [IntPtr]8, [IntPtr]0) }
    Start-Sleep -Milliseconds 300
    [TeamsNative]::Chars($fileEdit, $File, 0)
    Start-Sleep -Milliseconds 900
    $dr = $A::FromHandle($dlg)
    $ac = New-Object System.Windows.Automation.PropertyCondition($A::AutomationIdProperty, '1148')
    $got = $null
    foreach ($e in $dr.FindAll($TS, $ac)) { if ($e.Current.Name.Length -gt 0) { $got = $e.Current.Name; break } }
    if ($got -cne $File) { throw "檔名欄內容與路徑不符（[$got]），已停在對話框，請手動取消" }
    [TeamsNative]::Key($fileEdit, 0x0D); [void][TeamsNative]::PostMessageW($fileEdit, 0x0102, [IntPtr]0x0D, [IntPtr]0)

    $count = 0
    for ($i = 0; $i -lt $AttachWaitSec -and $count -lt 1; $i++) { Start-Sleep -Seconds 1; $count = @(Get-Buttons ($A::FromHandle($chat)) '移除附件').Count }
    if ($count -lt 1) { throw "附件在 $AttachWaitSec 秒內沒有掛上（「移除附件」鈕數=0）" }
    if ($count -gt 1) { throw "草稿附件數 $count 個，不是 1——請手動移除多餘的再送" }
    Write-Host "附件已掛上：$([IO.Path]::GetFileName($File))" -ForegroundColor Green
}

# --- 3. 打字並核對 ------------------------------------------------------------
$root = $A::FromHandle($chat); $edit = Get-Compose $root
try { $edit.SetFocus() } catch { }
$target = Get-TypeTarget $chat
foreach ($ch in $Message.ToCharArray()) {
    if ([TeamsNative]::GetForegroundWindow() -ne $chat) { throw '打字途中前景視窗變了（使用者切走），已中止；先 -Action Clear 再重跑' }
    [void][TeamsNative]::PostMessageW($target, 0x0102, [IntPtr][int]$ch, [IntPtr]0); Start-Sleep -Milliseconds 6
}
Start-Sleep -Milliseconds 1200
$typed = Get-Draft (Get-Compose ($A::FromHandle($chat)))
if ((Norm $typed) -cne (Norm $Message)) { throw "輸入框內容與訊息不符，不送出。輸入框：$typed" }
Write-Host "訊息逐字相符（$($Message.Length) 字）"

# --- 4. 送出並等「已傳送」 ------------------------------------------------------
# 🔴 鈕名不固定：「傳送 (Ctrl+Enter)」／「傳送」都見過，寫死完整名稱會在附件＋草稿都備妥後才失敗
$send = @(Get-Buttons ($A::FromHandle($chat)) '傳送 (Ctrl+Enter)') + @(Get-Buttons ($A::FromHandle($chat)) '傳送')
if ($send.Count -eq 0) {
    $c = New-Object System.Windows.Automation.PropertyCondition($A::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)
    foreach ($b in ($A::FromHandle($chat)).FindAll($TS, $c)) { if ($b.Current.Name -like '傳送 (*)') { $send += $b } }
}
if ($send.Count -eq 0) { throw '找不到「傳送」鈕（草稿與附件留在輸入框，勿重跑；確認後手動按傳送）' }
if ($send.Count -gt 1) { throw "「傳送」鈕有 $($send.Count) 顆，無法判斷，未送出（草稿與附件留在輸入框）" }
$send[0].GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
$head = Norm ($Message.Substring(0, [Math]::Min(12, $Message.Length)))
$state = '未知'; $sec = 0
for ($i = 0; $i -lt [Math]::Ceiling($SentWaitSec / 2); $i++) {
    Start-Sleep -Seconds 2; $sec += 2
    foreach ($e in ($A::FromHandle($chat)).FindAll($TS, [System.Windows.Automation.Condition]::TrueCondition)) {
        $n = $e.Current.Name
        # 狀態字樣的位置因對象而異：對他人是「已傳送 <內容>」，自己的聊天是「<名字> 已傳送 <內容>」——用包含判斷，不用 StartsWith
        if ($n -and $n.Length -gt 6 -and (Norm $n).Contains($head)) {
            if ($n -match '未傳送|傳送失敗') { $state = '失敗'; break }
            if ($n -match '已傳送|已讀') { $state = '已傳送'; break }
            if ($n -match '傳送中') { $state = '傳送中' }
        }
    }
    if ($state -eq '已傳送' -or $state -eq '失敗') { break }
}
if ($state -ne '已傳送') { throw "送出後 $sec 秒狀態仍是「$state」，請到 Teams 目視確認" }
Write-Host "✅ 已傳送給 $Peer（$sec 秒）$(if ($File) { '，含附件 ' + [IO.Path]::GetFileName($File) })" -ForegroundColor Green
