#Requires -Version 5.1
<#
.SYNOPSIS
    即時事件監看 UI：開著它盯住事件流，Logitech 自訂鍵一失效就按下標記，
    元兇事件就在標記線上方最近幾顆。
.DESCRIPTION
    用法：
      1. 按【開始監看】→ 它每隔幾秒把「新冒出來的」事件即時列進時間軸。
      2. 讓電腦照常用 / 睡眠 / 喚醒。按鍵一失效，立刻按【⚠ 標記此刻失效】。
      3. 看標記橫線「上方」最近幾顆事件 → 那通常就是元兇。
      4. 想分辨是崩潰還是卡死：若 Application 日誌跳出 Application Error / .NET
         Runtime，代表 LogiOptionsMgr 崩潰了；若什麼都沒有卻失效，就是卡死。
    純讀取，不會動任何進程。整條時間軸即時存到 %TEMP%\LogiEventTimeline.txt。
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$TimelineFile = Join-Path $env:TEMP 'LogiEventTimeline.txt'

# 要即時監看的日誌。System 含 Power-Troubleshooter / Kernel-Power / Kernel-PnP；
# Application 會記錄程式崩潰（Application Error / .NET Runtime）→ 用來分辨崩潰 vs 卡死；
# 兩個 operational log 不一定啟用，用 try/catch 容錯。
$Logs = @(
    'System',
    'Application',
    'Microsoft-Windows-Kernel-PnP/Configuration',
    'Microsoft-Windows-DeviceSetupManager/Admin'
)

# 會讓我們特別注意的 Provider 關鍵字（睡眠/喚醒/電源/裝置/崩潰）→ 列出來時加 ">>>" 標示。
$HotKeywords = @('Power', 'Kernel-PnP', 'DeviceSetupManager', 'WHEA', 'Application Error', '.NET Runtime', 'Wininit')

$BackfillMinutes  = 15      # 開始監看時先回溯這麼多分鐘的歷史事件，證明讀得到日誌
$script:Watching  = $false
$script:WatchFrom = Get-Date
$script:SeenIds   = @{}      # key: "log#recordid" → 已顯示過，避免重複
$script:PollCount = 0
$script:EventCount = 0
$script:DevPrev   = $null    # 上一次的 Logitech 裝置快照；null 代表尚未建立基準
$script:DevErrShown = $false
$DevPollEvery     = 3        # 每 N 次輪詢才查一次裝置（Get-PnpDevice 較慢，避免卡住介面）

function Add-Line {
    param([string]$Text)
    $box.AppendText($Text + "`r`n")
    try { Add-Content -Path $TimelineFile -Value $Text -Encoding UTF8 -ErrorAction Stop } catch { }
}

# 輪詢一次：把每個日誌中「WatchFrom 之後、還沒顯示過」的事件列出來（由舊到新）。
function Poll-Events {
    $batch = @()
    foreach ($log in $Logs) {
        try {
            $evts = Get-WinEvent -FilterHashtable @{ LogName = $log; StartTime = $script:WatchFrom } -MaxEvents 500 -ErrorAction Stop
            foreach ($e in $evts) {
                $key = "$log#$($e.RecordId)"
                if ($script:SeenIds.ContainsKey($key)) { continue }
                $script:SeenIds[$key] = $true
                $batch += [pscustomobject]@{ Time = $e.TimeCreated; Log = $log; Provider = $e.ProviderName; Id = $e.Id; Event = $e }
            }
        } catch {
            # 該 log 沒有符合的事件或未啟用 → 略過。
        }
    }
    # 高水位推進：下次只從目前最新事件時間往後看（留 2 秒緩衝，同秒事件靠 SeenIds 去重）。
    if ($batch.Count -gt 0) {
        $script:EventCount += $batch.Count
        $maxT = ($batch.Time | Measure-Object -Maximum).Maximum
        $script:WatchFrom = $maxT.AddSeconds(-2)
    }
    foreach ($b in ($batch | Sort-Object Time)) {
        $msg = ''
        if ($b.Event.Message) { $msg = ($b.Event.Message -split "`r?`n")[0] }
        if ($msg.Length -gt 110) { $msg = $msg.Substring(0, 110) }
        $hot = $false
        foreach ($k in $HotKeywords) { if ("$($b.Provider) $msg" -like "*$k*") { $hot = $true; break } }
        $mark = if ($hot) { '>>>' } else { '   ' }
        Add-Line ("{0} [{1}] {2} / Id={3} :: {4}" -f $mark, $b.Time.ToString('HH:mm:ss'), $b.Provider, $b.Id, $msg)
    }
}

# 取得目前存在的 Logitech 裝置快照：InstanceId → "Status | LastArrival"。
# 假設：滑鼠/接收器重新連線（睡眠喚醒、閒置休眠後喚醒）後羅技軟體沒重新接管按鍵。
# LastArrivalDate 變動就代表該裝置重新到達，可和「失效標記」對時間。
function Get-LogiDeviceSnapshot {
    $snap = @{}
    $devs = Get-PnpDevice -PresentOnly -ErrorAction Stop |
        Where-Object { $_.InstanceId -match 'VID_046D|VID&0002046D' }
    foreach ($d in $devs) {
        $arrival = ''
        try {
            $prop = Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_LastArrivalDate' -ErrorAction Stop
            if ($prop.Data) { $arrival = ([datetime]$prop.Data).ToString('MM-dd HH:mm:ss') }
        } catch { }
        $snap[$d.InstanceId] = [pscustomobject]@{
            Name    = $d.FriendlyName
            Status  = [string]$d.Status
            Arrival = $arrival
        }
    }
    return $snap
}

# 輪詢 Logitech 裝置狀態；和上一次比對，有變化就打 ### 。第一次只列出基準清單。
function Poll-Devices {
    try {
        $now = Get-LogiDeviceSnapshot
    } catch {
        if (-not $script:DevErrShown) {
            Add-Line '---- [裝置] 無法查詢 PnP 裝置（Get-PnpDevice 失敗），略過裝置監看 ----'
            $script:DevErrShown = $true
        }
        return
    }
    $stamp = (Get-Date).ToString('HH:mm:ss')
    if ($null -eq $script:DevPrev) {
        Add-Line ("---- [裝置] Logitech 裝置基準（{0} 個）----" -f $now.Count)
        foreach ($id in ($now.Keys | Sort-Object)) {
            $v = $now[$id]
            Add-Line ("    {0} | {1} | 最近到達 {2}" -f $v.Name, $v.Status, $v.Arrival)
        }
        $script:DevPrev = $now
        return
    }
    foreach ($id in ($now.Keys | Sort-Object)) {
        $v = $now[$id]
        if (-not $script:DevPrev.ContainsKey($id)) {
            Add-Line ("### [{0}] 裝置出現：{1} ({2})" -f $stamp, $v.Name, $id)
        } else {
            $o = $script:DevPrev[$id]
            if ($o.Arrival -ne $v.Arrival) {
                Add-Line ("### [{0}] 裝置重新到達：{1} 最近到達 {2} → {3}" -f $stamp, $v.Name, $o.Arrival, $v.Arrival)
            } elseif ($o.Status -ne $v.Status) {
                Add-Line ("### [{0}] 裝置狀態改變：{1} {2} → {3}" -f $stamp, $v.Name, $o.Status, $v.Status)
            }
        }
    }
    foreach ($id in ($script:DevPrev.Keys | Sort-Object)) {
        if (-not $now.ContainsKey($id)) {
            Add-Line ("### [{0}] 裝置消失：{1} ({2})" -f $stamp, $script:DevPrev[$id].Name, $id)
        }
    }
    $script:DevPrev = $now
}

# ---------------- 介面 ----------------
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Logitech 即時事件監看器'
$form.Size = New-Object System.Drawing.Size(900, 640)
$form.StartPosition = 'CenterScreen'

$lbl = New-Object System.Windows.Forms.Label
$lbl.Text = '輪詢秒數：'
$lbl.Location = New-Object System.Drawing.Point(12, 16)
$lbl.AutoSize = $true
$form.Controls.Add($lbl)

$num = New-Object System.Windows.Forms.NumericUpDown
$num.Location = New-Object System.Drawing.Point(84, 14)
$num.Minimum = 2; $num.Maximum = 60; $num.Value = 5
$num.Width = 55
$form.Controls.Add($num)

$btnWatch = New-Object System.Windows.Forms.Button
$btnWatch.Text = '開始監看'
$btnWatch.Location = New-Object System.Drawing.Point(150, 12)
$btnWatch.Size = New-Object System.Drawing.Size(110, 30)
$btnWatch.BackColor = [System.Drawing.Color]::FromArgb(200, 240, 200)
$form.Controls.Add($btnWatch)

$btnMark = New-Object System.Windows.Forms.Button
$btnMark.Text = '⚠ 標記此刻失效'
$btnMark.Location = New-Object System.Drawing.Point(270, 12)
$btnMark.Size = New-Object System.Drawing.Size(150, 30)
$btnMark.BackColor = [System.Drawing.Color]::FromArgb(245, 205, 205)
$form.Controls.Add($btnMark)

$btnProc = New-Object System.Windows.Forms.Button
$btnProc.Text = '記錄進程狀態'
$btnProc.Location = New-Object System.Drawing.Point(430, 12)
$btnProc.Size = New-Object System.Drawing.Size(120, 30)
$form.Controls.Add($btnProc)

$btnFolder = New-Object System.Windows.Forms.Button
$btnFolder.Text = '開啟存檔位置'
$btnFolder.Location = New-Object System.Drawing.Point(560, 12)
$btnFolder.Size = New-Object System.Drawing.Size(120, 30)
$form.Controls.Add($btnFolder)

$btnClear = New-Object System.Windows.Forms.Button
$btnClear.Text = '清空畫面'
$btnClear.Location = New-Object System.Drawing.Point(690, 12)
$btnClear.Size = New-Object System.Drawing.Size(90, 30)
$form.Controls.Add($btnClear)

$status = New-Object System.Windows.Forms.Label
$status.Location = New-Object System.Drawing.Point(12, 50)
$status.AutoSize = $true
$status.Text = '尚未開始。按【開始監看】後它會即時列出新事件；按鍵失效時按【⚠ 標記此刻失效】。'
$form.Controls.Add($status)

$box = New-Object System.Windows.Forms.TextBox
$box.Multiline = $true
$box.ScrollBars = 'Both'
$box.WordWrap = $false
$box.ReadOnly = $true
$box.Font = New-Object System.Drawing.Font('Consolas', 9)
$box.Location = New-Object System.Drawing.Point(12, 76)
$box.Size = New-Object System.Drawing.Size(860, 510)
$box.Anchor = 'Top,Bottom,Left,Right'
$form.Controls.Add($box)

# 輪詢用計時器
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 5000
$timer.Add_Tick({
    Poll-Events
    if (($script:PollCount % $DevPollEvery) -eq 0) { Poll-Devices }
    $status.Text = ("監看中…第 {0} 次輪詢 @ {1}，累計 {2} 筆事件。失效時按【⚠ 標記此刻失效】。" -f `
        $script:PollCount, (Get-Date -Format 'HH:mm:ss'), $script:EventCount)
    $script:PollCount++
})

$btnWatch.Add_Click({
    if (-not $script:Watching) {
        $script:Watching   = $true
        $script:SeenIds    = @{}
        $script:PollCount  = 1
        $script:EventCount = 0
        $timer.Interval    = [int]$num.Value * 1000
        $btnWatch.Text = '停止監看'
        $btnWatch.BackColor = [System.Drawing.Color]::FromArgb(245, 205, 205)
        Add-Line ''
        Add-Line ("==================== 開始監看 @ {0}（每 {1} 秒輪詢）====================" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), [int]$num.Value)
        # 先回溯最近 15 分鐘，立刻看到歷史事件 → 證明日誌讀得到。
        Add-Line ("---- 回溯最近 {0} 分鐘的事件 ----" -f $BackfillMinutes)
        $script:WatchFrom = (Get-Date).AddMinutes(-$BackfillMinutes)
        Poll-Events
        Add-Line ("---- 回溯完畢（{0} 筆），以下為即時新事件 ----" -f $script:EventCount)
        $script:DevPrev = $null
        Poll-Devices
        $status.Text = ("監看中…已回溯 {0} 筆。讓電腦照常用；睡眠喚醒後、按鍵失效時立刻按標記。" -f $script:EventCount)
        $timer.Start()
    } else {
        $timer.Stop()
        $script:Watching = $false
        $btnWatch.Text = '開始監看'
        $btnWatch.BackColor = [System.Drawing.Color]::FromArgb(200, 240, 200)
        Add-Line ("==================== 停止監看 @ {0} ====================" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
        $status.Text = '已停止。時間軸存於 %TEMP%\LogiEventTimeline.txt'
    }
})

$btnMark.Add_Click({
    # 先補抓一次，確保失效前的事件都進來了，再打標記。
    if ($script:Watching) { Poll-Events; Poll-Devices }
    Add-Line '########################################################'
    Add-Line ("############  按鍵失效標記 @ {0}  ############" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    Add-Line '####  看上方最近的 >>> 事件，以及有沒有 ### 裝置重新到達  ####'
    Add-Line '########################################################'
    $status.Text = '已標記失效時刻。看上方最近的 >>> 事件，把 Provider + Id 貼回來。'
})

$btnProc.Add_Click({
    Add-Line ("---- 進程狀態 @ {0} ----" -f (Get-Date -Format 'HH:mm:ss'))
    foreach ($name in @('LogiOptions','LogiOptionsMgr','LogiOverlay')) {
        $p = Get-Process -Name $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($p) {
            $st = try { $p.StartTime.ToString('MM-dd HH:mm:ss') } catch { '未知' }
            $resp = try { $p.Responding } catch { '?' }
            $hwnd = try { [int64]$p.MainWindowHandle } catch { 0 }
            Add-Line ("    {0,-16} PID={1} Start={2} Responding={3} hWnd={4}" -f $name, $p.Id, $st, $resp, $hwnd)
        } else {
            Add-Line ("    {0,-16} 未在執行" -f $name)
        }
    }
})

$btnFolder.Add_Click({ Start-Process explorer.exe $env:TEMP })
$btnClear.Add_Click({ $box.Clear() })

$form.Add_FormClosing({ $timer.Stop() })
[void]$form.ShowDialog()
