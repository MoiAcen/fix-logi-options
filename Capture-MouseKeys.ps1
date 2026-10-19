#Requires -Version 5.1
<#
.SYNOPSIS
    即時攔截滑鼠按鍵 / 鍵盤事件，用來判斷 Logitech 自訂鍵（上一頁/下一頁）有沒有生效。
.DESCRIPTION
    羅技把實體按鍵重映射成「上一頁/下一頁」後，按下去會送出對應事件：
      - 注入的滑鼠 XBUTTON1(Back) / XBUTTON2(Forward)，或
      - 注入的鍵盤 Alt+Left(Back) / Alt+Right(Forward)。
    失效時同一顆按鍵會「抓成別的 event」或完全無訊息。

    這支工具裝上全域低階 hook（WH_MOUSE_LL + WH_KEYBOARD_LL），把每次事件即時攤開，
    並自動把 Back/Forward 相關事件標上【上一頁】/【下一頁】，injected 事件加 >>>。

    用法：
      1. 按【開始捕捉】。
      2. 正常狀態按一次自訂鍵 → 記下「正常簽章」（應看到【上一頁】/【下一頁】）。
      3. 失效時按同一顆 → 若變成別的事件或無訊息，就是羅技掛了；按【⚠ 標記此刻失效】。

    純觀察、不攔截（永遠 CallNextHookEx 放行），不影響正常使用。
    記錄即時寫到 %TEMP%\LogiMouseKeys.txt。
    注意：若羅技用 WM_APPCOMMAND 送 Back/Forward，低階 hook 攔不到（會顯示無訊息）。
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ---------- C# 低階 hook ----------
# callback 只把事件字串塞進 ConcurrentQueue，UI 由 PowerShell 端的 Timer 排空。
$cs = @'
using System;
using System.Collections.Concurrent;
using System.Runtime.InteropServices;

public static class LlHook
{
    public const int WH_KEYBOARD_LL = 13;
    public const int WH_MOUSE_LL    = 14;

    public const int WM_KEYDOWN    = 0x0100;
    public const int WM_KEYUP      = 0x0101;
    public const int WM_SYSKEYDOWN = 0x0104;
    public const int WM_SYSKEYUP   = 0x0105;

    public const int WM_LBUTTONDOWN = 0x0201;
    public const int WM_LBUTTONUP   = 0x0202;
    public const int WM_RBUTTONDOWN = 0x0204;
    public const int WM_RBUTTONUP   = 0x0205;
    public const int WM_MBUTTONDOWN = 0x0207;
    public const int WM_MBUTTONUP   = 0x0208;
    public const int WM_MOUSEWHEEL  = 0x020A;
    public const int WM_XBUTTONDOWN = 0x020B;
    public const int WM_XBUTTONUP   = 0x020C;

    public const uint LLKHF_INJECTED        = 0x10;
    public const uint LLMHF_INJECTED        = 0x01;
    public const uint LLMHF_LOWER_IL_INJECTED = 0x02;

    public delegate IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    public struct KBDLLHOOKSTRUCT { public uint vkCode; public uint scanCode; public uint flags; public uint time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)]
    public struct MSLLHOOKSTRUCT  { public int x; public int y; public uint mouseData; public uint flags; public uint time; public IntPtr dwExtraInfo; }

    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr SetWindowsHookEx(int idHook, HookProc lpfn, IntPtr hMod, uint dwThreadId);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool UnhookWindowsHookEx(IntPtr hhk);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr GetModuleHandle(string lpModuleName);

    // UI 端讀這個佇列
    public static ConcurrentQueue<string> Queue = new ConcurrentQueue<string>();

    private static IntPtr _kbHook = IntPtr.Zero;
    private static IntPtr _msHook = IntPtr.Zero;
    // 保留 delegate 參考，避免被 GC 回收
    private static HookProc _kbProc;
    private static HookProc _msProc;
    private static bool _altDown = false;

    private static bool Alt() { return _altDown; }

    private static string KeyName(uint vk)
    {
        switch (vk)
        {
            case 0x25: return "Left";
            case 0x26: return "Up";
            case 0x27: return "Right";
            case 0x28: return "Down";
            case 0x08: return "Backspace";
            case 0x0D: return "Enter";
            case 0xA4: case 0xA5: return "Alt";
            case 0xA2: case 0xA3: return "Ctrl";
            case 0xA0: case 0xA1: return "Shift";
        }
        if (vk >= 0x41 && vk <= 0x5A) return ((char)vk).ToString();     // A-Z
        if (vk >= 0x30 && vk <= 0x39) return ((char)vk).ToString();     // 0-9
        if (vk >= 0x70 && vk <= 0x7B) return "F" + (vk - 0x6F);         // F1-F12
        return "VK";
    }

    private static IntPtr KbCallback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0)
        {
            int msg = wParam.ToInt32();
            KBDLLHOOKSTRUCT k = (KBDLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(KBDLLHOOKSTRUCT));
            bool down = (msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN);
            bool up   = (msg == WM_KEYUP   || msg == WM_SYSKEYUP);
            if (k.vkCode == 0xA4 || k.vkCode == 0xA5) { _altDown = down; }  // 追蹤 Alt 狀態

            bool injected = (k.flags & LLKHF_INJECTED) != 0;
            string name = KeyName(k.vkCode);
            string tag = "";
            if (_altDown && k.vkCode == 0x25) tag = "  【上一頁 Back (Alt+Left)】";
            if (_altDown && k.vkCode == 0x27) tag = "  【下一頁 Forward (Alt+Right)】";

            string line = string.Format("KBD   VK=0x{0:X2}({1}) {2} injected={3} Alt={4}{5}",
                k.vkCode, name, (down ? "DOWN" : (up ? "UP" : "?")),
                (injected ? "Yes" : "No"), (_altDown ? "Yes" : "No"), tag);
            Enqueue(line, injected || tag.Length > 0);
        }
        return CallNextHookEx(_kbHook, nCode, wParam, lParam);
    }

    private static IntPtr MsCallback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0)
        {
            int msg = wParam.ToInt32();
            // 忽略滑鼠移動，避免洗版
            if (msg != 0x0200)
            {
                MSLLHOOKSTRUCT m = (MSLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(MSLLHOOKSTRUCT));
                bool injected = (m.flags & (LLMHF_INJECTED | LLMHF_LOWER_IL_INJECTED)) != 0;
                string what = null;
                string tag = "";
                switch (msg)
                {
                    case WM_LBUTTONDOWN: what = "LEFT DOWN"; break;
                    case WM_LBUTTONUP:   what = "LEFT UP"; break;
                    case WM_RBUTTONDOWN: what = "RIGHT DOWN"; break;
                    case WM_RBUTTONUP:   what = "RIGHT UP"; break;
                    case WM_MBUTTONDOWN: what = "MIDDLE DOWN"; break;
                    case WM_MBUTTONUP:   what = "MIDDLE UP"; break;
                    case WM_MOUSEWHEEL:  what = "WHEEL"; break;
                    case WM_XBUTTONDOWN:
                    case WM_XBUTTONUP:
                    {
                        int xb = (int)(m.mouseData >> 16);  // 1=X1, 2=X2
                        string ud = (msg == WM_XBUTTONDOWN) ? "DOWN" : "UP";
                        if (xb == 1) { what = "XBUTTON1 " + ud; tag = "  【上一頁 Back】"; }
                        else if (xb == 2) { what = "XBUTTON2 " + ud; tag = "  【下一頁 Forward】"; }
                        else { what = "XBUTTON? " + ud; }
                        break;
                    }
                }
                if (what != null)
                {
                    string line = string.Format("MOUSE {0} injected={1}{2}", what, (injected ? "Yes" : "No"), tag);
                    Enqueue(line, injected || tag.Length > 0);
                }
            }
        }
        return CallNextHookEx(_msHook, nCode, wParam, lParam);
    }

    private static void Enqueue(string body, bool hot)
    {
        string mark = hot ? ">>>" : "   ";
        string ts = DateTime.Now.ToString("HH:mm:ss.fff");
        Queue.Enqueue(string.Format("{0} [{1}] {2}", mark, ts, body));
    }

    public static void Start()
    {
        if (_msHook != IntPtr.Zero || _kbHook != IntPtr.Zero) return;
        IntPtr hMod = GetModuleHandle(null);
        _kbProc = KbCallback;
        _msProc = MsCallback;
        _kbHook = SetWindowsHookEx(WH_KEYBOARD_LL, _kbProc, hMod, 0);
        _msHook = SetWindowsHookEx(WH_MOUSE_LL,    _msProc, hMod, 0);
    }

    public static void Stop()
    {
        if (_kbHook != IntPtr.Zero) { UnhookWindowsHookEx(_kbHook); _kbHook = IntPtr.Zero; }
        if (_msHook != IntPtr.Zero) { UnhookWindowsHookEx(_msHook); _msHook = IntPtr.Zero; }
    }

    public static bool Running { get { return _msHook != IntPtr.Zero || _kbHook != IntPtr.Zero; } }
}
'@

Add-Type -TypeDefinition $cs -ReferencedAssemblies 'System'

$LogFile = Join-Path $env:TEMP 'LogiMouseKeys.txt'

function Add-Line {
    param([string]$Text)
    $box.AppendText($Text + "`r`n")
    try { Add-Content -Path $LogFile -Value $Text -Encoding UTF8 -ErrorAction Stop } catch { }
}

# ---------------- 介面 ----------------
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Logitech 滑鼠按鍵捕捉器'
$form.Size = New-Object System.Drawing.Size(880, 620)
$form.StartPosition = 'CenterScreen'

$btnCap = New-Object System.Windows.Forms.Button
$btnCap.Text = '開始捕捉'
$btnCap.Location = New-Object System.Drawing.Point(12, 12)
$btnCap.Size = New-Object System.Drawing.Size(120, 30)
$btnCap.BackColor = [System.Drawing.Color]::FromArgb(200, 240, 200)
$form.Controls.Add($btnCap)

$btnMark = New-Object System.Windows.Forms.Button
$btnMark.Text = '⚠ 標記此刻失效'
$btnMark.Location = New-Object System.Drawing.Point(142, 12)
$btnMark.Size = New-Object System.Drawing.Size(150, 30)
$btnMark.BackColor = [System.Drawing.Color]::FromArgb(245, 205, 205)
$form.Controls.Add($btnMark)

$btnClear = New-Object System.Windows.Forms.Button
$btnClear.Text = '清空畫面'
$btnClear.Location = New-Object System.Drawing.Point(302, 12)
$btnClear.Size = New-Object System.Drawing.Size(100, 30)
$form.Controls.Add($btnClear)

$btnFolder = New-Object System.Windows.Forms.Button
$btnFolder.Text = '開啟存檔位置'
$btnFolder.Location = New-Object System.Drawing.Point(412, 12)
$btnFolder.Size = New-Object System.Drawing.Size(120, 30)
$form.Controls.Add($btnFolder)

$status = New-Object System.Windows.Forms.Label
$status.Location = New-Object System.Drawing.Point(12, 50)
$status.AutoSize = $true
$status.Text = '按【開始捕捉】後，正常狀態先按一次自訂鍵記下簽章；失效時再按、比對是否變成別的事件。'
$form.Controls.Add($status)

$box = New-Object System.Windows.Forms.TextBox
$box.Multiline = $true
$box.ScrollBars = 'Both'
$box.WordWrap = $false
$box.ReadOnly = $true
$box.Font = New-Object System.Drawing.Font('Consolas', 10)
$box.Location = New-Object System.Drawing.Point(12, 76)
$box.Size = New-Object System.Drawing.Size(840, 490)
$box.Anchor = 'Top,Bottom,Left,Right'
$form.Controls.Add($box)

# Timer 每 150ms 排空 hook 佇列
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 150
$timer.Add_Tick({
    $line = ''
    while ([LlHook]::Queue.TryDequeue([ref]$line)) {
        Add-Line $line
    }
})

$btnCap.Add_Click({
    if (-not [LlHook]::Running) {
        [LlHook]::Start()
        $timer.Start()
        $btnCap.Text = '停止捕捉'
        $btnCap.BackColor = [System.Drawing.Color]::FromArgb(245, 205, 205)
        Add-Line ''
        Add-Line ("==================== 開始捕捉 @ {0} ====================" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
        Add-Line '   正常：按自訂鍵應出現【上一頁 Back】/【下一頁 Forward】（多半 injected=Yes）'
        $status.Text = '捕捉中…按你的自訂鍵看它變成什麼事件。'
    } else {
        [LlHook]::Stop()
        $timer.Stop()
        $btnCap.Text = '開始捕捉'
        $btnCap.BackColor = [System.Drawing.Color]::FromArgb(200, 240, 200)
        Add-Line ("==================== 停止捕捉 @ {0} ====================" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
        $status.Text = ("已停止。記錄存於 {0}" -f $LogFile)
    }
})

$btnMark.Add_Click({
    Add-Line '########################################################'
    Add-Line ("############  按鍵失效標記 @ {0}  ############" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    Add-Line '####  比對：這條線前後按自訂鍵，事件是否和正常簽章不同  ####'
    Add-Line '########################################################'
    $status.Text = '已標記。把橫線附近幾行（尤其自訂鍵那次）貼回來即可判定。'
})

$btnClear.Add_Click({ $box.Clear() })
$btnFolder.Add_Click({ Start-Process explorer.exe $env:TEMP })

# 關閉時務必解除 hook
$form.Add_FormClosing({
    $timer.Stop()
    [LlHook]::Stop()
})

[void]$form.ShowDialog()
