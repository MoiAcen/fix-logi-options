#Requires -Version 5.1
<#
.SYNOPSIS
    探測 Logitech 進程的健康指標，用來驗證 .Responding 是否可靠。
.DESCRIPTION
    這是「蒐證」工具，不會動到任何進程。目的是回答兩個問題：
      1. LogiOptionsMgr 有沒有主視窗？沒有的話 .Responding 一律回 True、沒有鑑別力。
      2. 當自訂鍵失效的那一刻，哪些指標真的變了？
.PARAMETER Monitor
    開啟連續監看模式：每隔 IntervalSeconds 秒取樣一次並寫入 log。
    讓它開著跑過一次睡眠循環，按鍵死掉時回頭對照 log。
.PARAMETER IntervalSeconds
    監看模式的取樣間隔（秒），預設 15。
.EXAMPLE
    .\Diagnose-LogiHealth.ps1
        單次快照，看 Responding 對哪支進程有意義。
.EXAMPLE
    .\Diagnose-LogiHealth.ps1 -Monitor
        連續監看，Ctrl+C 停止。log 寫到 %TEMP%\LogiHealthProbe.log
#>
param(
    [switch]$Monitor,
    [int]$IntervalSeconds = 15
)

$ErrorActionPreference = 'Stop'
$LogFile   = Join-Path $env:TEMP 'LogiHealthProbe.log'
$Processes = @('LogiOptions', 'LogiOptionsMgr', 'LogiOverlay')

function Write-Probe {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $line
    try { Add-Content -Path $LogFile -Value $line -Encoding Default -ErrorAction Stop } catch { }
}

# 取得單一進程的健康快照（字串）。
function Get-ProcSnapshot {
    param([string]$Name)
    $procs = Get-Process -Name $Name -ErrorAction SilentlyContinue
    if (-not $procs) { return "$Name : 未在執行" }

    $lines = foreach ($p in $procs) {
        $hwnd = 0
        try { $hwnd = [int64]$p.MainWindowHandle } catch { }
        # .Responding 只有在有主視窗時才有意義；無視窗時 .NET 一律回 True。
        $respMeaningful = ($hwnd -ne 0)
        $resp = $null
        try { $resp = $p.Responding } catch { $resp = '讀取失敗' }

        $start = $null
        try { $start = $p.StartTime.ToString('HH:mm:ss') } catch { $start = '未知' }

        $note = if ($respMeaningful) { 'Responding 有意義' } else { '無主視窗→Responding 無鑑別力' }

        "  {0,-16} PID={1,-6} Start={2} hWnd={3} Responding={4} [{5}]" -f `
            $Name, $p.Id, $start, $hwnd, $resp, $note
    }
    return ($lines -join "`n")
}

function Write-FullSnapshot {
    Write-Probe '================ 快照 ================'
    foreach ($name in $Processes) {
        Write-Probe (Get-ProcSnapshot -Name $name)
    }
    # 另外記最近一次喚醒事件，方便和睡眠時機對照。
    try {
        $wake = Get-WinEvent -FilterHashtable @{
            LogName      = 'System'
            ProviderName = 'Microsoft-Windows-Power-Troubleshooter'
            Id           = 1
        } -MaxEvents 1 -ErrorAction SilentlyContinue
        if ($wake) {
            Write-Probe ("  最近一次喚醒事件: {0}" -f $wake.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'))
        }
    } catch { }
}

Write-Probe ("探測開始 (Monitor={0}, 間隔={1}s) log: {2}" -f $Monitor, $IntervalSeconds, $LogFile)

if ($Monitor) {
    Write-Probe '連續監看中，按 Ctrl+C 停止。按鍵失效時請記下當下時間，再回來對照這份 log。'
    while ($true) {
        Write-FullSnapshot
        Start-Sleep -Seconds $IntervalSeconds
    }
} else {
    Write-FullSnapshot
    Write-Probe '單次快照完成。若 LogiOptionsMgr 顯示 hWnd=0，代表 .Responding 不能當健康指標。'
}
