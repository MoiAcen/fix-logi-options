#Requires -Version 5.1
<#
.SYNOPSIS
    簡易事件補捉 UI：在「正常」與「異常」兩種狀態各抓一次最近事件，再比對差異，
    找出和 Logitech 自訂鍵失效相關的那顆系統事件。
.DESCRIPTION
    用法：
      1. 按鍵還正常時，按【抓取 → 標記正常】。
      2. 按鍵失效後（例如睡眠喚醒後），按【抓取 → 標記異常】。
      3. 按【比對差異】→ 列出「只在異常時出現」的事件，那通常就是元兇。
    不會動到任何進程，純讀取事件日誌。兩份快照存在 %TEMP%\LogiEvents_*.txt。
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:NormalSnap   = $null
$script:AbnormalSnap = $null
$NormalFile   = Join-Path $env:TEMP 'LogiEvents_Normal.txt'
$AbnormalFile = Join-Path $env:TEMP 'LogiEvents_Abnormal.txt'

# 要掃描的事件日誌。System 一定在，含 Power-Troubleshooter / Kernel-Power / Kernel-PnP；
# 裝置相關的 operational log 不一定開啟，用 try/catch 容錯。
$LogNames = @(
    'System',
    'Microsoft-Windows-Kernel-PnP/Configuration',
    'Microsoft-Windows-DeviceSetupManager/Admin'
)

# 抓取最近 N 分鐘的事件，回傳物件陣列（Time/Log/Provider/Id/Message）。
function Get-RecentEvents {
    param([int]$Minutes)
    $start = (Get-Date).AddMinutes(-$Minutes)
    $all = @()
    foreach ($log in $LogNames) {
        try {
            $evts = Get-WinEvent -FilterHashtable @{ LogName = $log; StartTime = $start } -ErrorAction Stop
            foreach ($e in $evts) {
                $msg = ''
                if ($e.Message) { $msg = ($e.Message -split "`r?`n")[0] }
                if ($msg.Length -gt 120) { $msg = $msg.Substring(0, 120) }
                $all += [pscustomobject]@{
                    Time     = $e.TimeCreated
                    Log      = $log
                    Provider = $e.ProviderName
                    Id       = $e.Id
                    Message  = $msg
                }
            }
        } catch {
            # 該 log 不存在或未啟用 → 略過。
        }
    }
    return ($all | Sort-Object Time)
}

# 事件的「身分簽章」：忽略時間，用 Provider+Id 當 key，方便比對。
function Get-Signature {
    param($Evt)
    return ("{0}|{1}" -f $Evt.Provider, $Evt.Id)
}

# 把事件陣列轉成可讀文字（含目前 Logitech 進程狀態一併記錄）。
function Format-Snapshot {
    param($Events, [string]$Label)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine(("===== {0} 快照 @ {1} =====" -f $Label, (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')))

    foreach ($name in @('LogiOptions','LogiOptionsMgr','LogiOverlay')) {
        $p = Get-Process -Name $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($p) {
            $st = try { $p.StartTime.ToString('HH:mm:ss') } catch { '未知' }
            [void]$sb.AppendLine(("  進程 {0}: 執行中 PID={1} Start={2}" -f $name, $p.Id, $st))
        } else {
            [void]$sb.AppendLine(("  進程 {0}: 未在執行" -f $name))
        }
    }
    [void]$sb.AppendLine(("  共 {0} 筆事件:" -f $Events.Count))
    foreach ($e in $Events) {
        [void]$sb.AppendLine(("  [{0}] {1} / Id={2} :: {3}" -f `
            $e.Time.ToString('HH:mm:ss'), $e.Provider, $e.Id, $e.Message))
    }
    return $sb.ToString()
}

# ---------------- 介面 ----------------
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Logitech 事件補捉器'
$form.Size = New-Object System.Drawing.Size(860, 640)
$form.StartPosition = 'CenterScreen'

$lbl = New-Object System.Windows.Forms.Label
$lbl.Text = '回溯分鐘數：'
$lbl.Location = New-Object System.Drawing.Point(12, 16)
$lbl.AutoSize = $true
$form.Controls.Add($lbl)

$num = New-Object System.Windows.Forms.NumericUpDown
$num.Location = New-Object System.Drawing.Point(96, 14)
$num.Minimum = 1; $num.Maximum = 240; $num.Value = 10
$num.Width = 60
$form.Controls.Add($num)

$btnNormal = New-Object System.Windows.Forms.Button
$btnNormal.Text = '抓取 → 標記正常'
$btnNormal.Location = New-Object System.Drawing.Point(170, 12)
$btnNormal.Size = New-Object System.Drawing.Size(140, 30)
$btnNormal.BackColor = [System.Drawing.Color]::FromArgb(200, 240, 200)
$form.Controls.Add($btnNormal)

$btnAbnormal = New-Object System.Windows.Forms.Button
$btnAbnormal.Text = '抓取 → 標記異常'
$btnAbnormal.Location = New-Object System.Drawing.Point(320, 12)
$btnAbnormal.Size = New-Object System.Drawing.Size(140, 30)
$btnAbnormal.BackColor = [System.Drawing.Color]::FromArgb(245, 205, 205)
$form.Controls.Add($btnAbnormal)

$btnDiff = New-Object System.Windows.Forms.Button
$btnDiff.Text = '比對差異（找元兇）'
$btnDiff.Location = New-Object System.Drawing.Point(470, 12)
$btnDiff.Size = New-Object System.Drawing.Size(160, 30)
$form.Controls.Add($btnDiff)

$btnFolder = New-Object System.Windows.Forms.Button
$btnFolder.Text = '開啟存檔位置'
$btnFolder.Location = New-Object System.Drawing.Point(640, 12)
$btnFolder.Size = New-Object System.Drawing.Size(120, 30)
$form.Controls.Add($btnFolder)

$status = New-Object System.Windows.Forms.Label
$status.Location = New-Object System.Drawing.Point(12, 50)
$status.AutoSize = $true
$status.Text = '尚未抓取。先在正常狀態抓一次，失效後再抓一次。'
$form.Controls.Add($status)

$box = New-Object System.Windows.Forms.TextBox
$box.Multiline = $true
$box.ScrollBars = 'Both'
$box.WordWrap = $false
$box.ReadOnly = $true
$box.Font = New-Object System.Drawing.Font('Consolas', 9)
$box.Location = New-Object System.Drawing.Point(12, 76)
$box.Size = New-Object System.Drawing.Size(820, 510)
$box.Anchor = 'Top,Bottom,Left,Right'
$form.Controls.Add($box)

$btnNormal.Add_Click({
    $status.Text = '抓取中...'
    $form.Refresh()
    $script:NormalSnap = Get-RecentEvents -Minutes ([int]$num.Value)
    $text = Format-Snapshot -Events $script:NormalSnap -Label '正常'
    Set-Content -Path $NormalFile -Value $text -Encoding UTF8
    $box.Text = $text
    $status.Text = ("已存正常快照（{0} 筆）→ {1}" -f $script:NormalSnap.Count, $NormalFile)
})

$btnAbnormal.Add_Click({
    $status.Text = '抓取中...'
    $form.Refresh()
    $script:AbnormalSnap = Get-RecentEvents -Minutes ([int]$num.Value)
    $text = Format-Snapshot -Events $script:AbnormalSnap -Label '異常'
    Set-Content -Path $AbnormalFile -Value $text -Encoding UTF8
    $box.Text = $text
    $status.Text = ("已存異常快照（{0} 筆）→ {1}" -f $script:AbnormalSnap.Count, $AbnormalFile)
})

$btnDiff.Add_Click({
    if (-not $script:NormalSnap -or -not $script:AbnormalSnap) {
        [System.Windows.Forms.MessageBox]::Show('請先各抓一次正常與異常快照。','比對差異') | Out-Null
        return
    }
    $normalSigs = @{}
    foreach ($e in $script:NormalSnap) { $normalSigs[(Get-Signature $e)] = $true }

    $onlyAbnormal = $script:AbnormalSnap | Where-Object { -not $normalSigs.ContainsKey((Get-Signature $_)) }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('===== 只在「異常」出現的事件（可疑元兇，由新到舊）=====')
    if (-not $onlyAbnormal) {
        [void]$sb.AppendLine('  無差異。元兇可能不在這些日誌，試著加大回溯分鐘數，或改抓其他 log。')
    } else {
        foreach ($e in ($onlyAbnormal | Sort-Object Time -Descending)) {
            [void]$sb.AppendLine(("  [{0}] {1} / Id={2}`n        {3}" -f `
                $e.Time.ToString('HH:mm:ss'), $e.Provider, $e.Id, $e.Message))
        }
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('→ 把最上面幾顆事件的 Provider + Id 貼回來，我就能把它做成排程發動點。')
    }
    $box.Text = $sb.ToString()
    $status.Text = ("比對完成：異常獨有事件 {0} 筆。" -f @($onlyAbnormal).Count)
})

$btnFolder.Add_Click({
    Start-Process explorer.exe $env:TEMP
})

[void]$form.ShowDialog()
