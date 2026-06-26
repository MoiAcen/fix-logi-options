#Requires -Version 5.1
<#
.SYNOPSIS
    重啟 Logitech Options 相關進程，恢復滑鼠自訂鍵功能。
.DESCRIPTION
    由 FixLogiOptions 排程任務呼叫。殺掉 LogiOptions / LogiOptionsMgr / LogiOverlay
    後，重新啟動核心進程 LogiOptionsMgr.exe（會自動帶起子進程）。
    執行紀錄寫入 %TEMP%\FixLogiOptions.log。
    本腳本不需要系統管理員權限。
#>

$ErrorActionPreference = 'Stop'

$LogFile   = Join-Path $env:TEMP 'FixLogiOptions.log'
$Processes = @('LogiOptions', 'LogiOptionsMgr', 'LogiOverlay')

# 預設安裝路徑（僅作為偵測不到執行中進程時的後備）
$DefaultMgrPath = 'C:\ProgramData\Logishrd\LogiOptions\Software\Current\LogiOptionsMgr.exe'

function Write-Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $line
    try {
        Add-Content -Path $LogFile -Value $line -Encoding UTF8 -ErrorAction Stop
    } catch {
        # 連 log 都寫不進去就算了，至少 console 看得到
        Write-Host "[WARN] 無法寫入 log 檔: $LogFile"
    }
}

# 動態解析 LogiOptionsMgr.exe 路徑：
#   1. 優先從正在執行的進程取得實際路徑（最可靠）
#   2. 後備：預設安裝路徑
#   3. 後備：在安裝目錄下遞迴搜尋（版本資料夾不一定叫 Current）
function Get-LogiMgrPath {
    $running = Get-Process -Name 'LogiOptionsMgr' -ErrorAction SilentlyContinue |
        Where-Object { $_.Path } | Select-Object -First 1
    if ($running) { return $running.Path }

    if (Test-Path $DefaultMgrPath) { return $DefaultMgrPath }

    $base = 'C:\ProgramData\Logishrd\LogiOptions\Software'
    if (Test-Path $base) {
        $found = Get-ChildItem -Path $base -Filter 'LogiOptionsMgr.exe' -Recurse -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($found) { return $found.FullName }
    }
    return $null
}

Write-Log '--- FixLogiOptions restart begin ---'

# --- 先解析路徑（必須在殺掉進程之前，否則執行中進程消失就抓不到實際路徑）---
# 正常情況下 LogiOptionsMgr 此刻應該已在執行；若偵測不到，代表它已經掛掉，
# 這正是本腳本要修復的症狀。
$mgrRunningBefore = Get-Process -Name 'LogiOptionsMgr' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($mgrRunningBefore) {
    Write-Log ("偵測到 LogiOptionsMgr 正在執行 (PID: {0})，符合預期。" -f $mgrRunningBefore.Id)
} else {
    Write-Log 'WARN: 未偵測到執行中的 LogiOptionsMgr（正常情況下此刻應在執行）——可能已掛掉，正是要修復的狀況。'
}

$MgrPath = Get-LogiMgrPath
if (-not $MgrPath) {
    Write-Log "ERROR: 無法解析 LogiOptionsMgr.exe 路徑（進程未執行且預設路徑不存在）。"
    Write-Log '請確認是否已安裝 Logitech Options。'
    Write-Log '--- FixLogiOptions restart aborted ---'
    exit 1
}
Write-Log "使用 LogiOptionsMgr 路徑: $MgrPath"

# --- 停止所有已知進程（先 graceful，殘留再 -Force）---
foreach ($name in $Processes) {
    $procs = Get-Process -Name $name -ErrorAction SilentlyContinue
    if ($procs) {
        Write-Log ("停止 {0} (PID: {1})..." -f $name, ($procs.Id -join ', '))
        $procs | Stop-Process -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 500
        $survivors = Get-Process -Name $name -ErrorAction SilentlyContinue
        if ($survivors) {
            Write-Log "強制結束 $name..."
            $survivors | Stop-Process -Force -ErrorAction SilentlyContinue
        }
    } else {
        Write-Log "$name 未在執行。"
    }
}

Write-Log '等待 3 秒後重啟...'
Start-Sleep -Seconds 3

# --- 啟動核心進程（路徑已於前面解析）---
if (-not (Test-Path $MgrPath)) {
    Write-Log "ERROR: 路徑已不存在: $MgrPath"
    Write-Log '--- FixLogiOptions restart aborted ---'
    exit 1
}

Write-Log "啟動 LogiOptionsMgr: $MgrPath"
Start-Process -FilePath $MgrPath

# --- 重啟後存活驗證 ---
Write-Log '等待 5 秒驗證進程存活...'
Start-Sleep -Seconds 5

$mgr = Get-Process -Name 'LogiOptionsMgr' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($mgr) {
    try {
        $aliveSec = [int]((Get-Date) - $mgr.StartTime).TotalSeconds
    } catch {
        $aliveSec = '未知'
    }
    Write-Log ("OK: LogiOptionsMgr 已存活 (PID: {0}, 已執行約 {1} 秒)，重啟成功。" -f $mgr.Id, $aliveSec)
    Write-Log '--- FixLogiOptions restart complete ---'
    exit 0
} else {
    Write-Log 'ERROR: 重啟後 LogiOptionsMgr 未存活，重啟失敗。'
    Write-Log '--- FixLogiOptions restart failed ---'
    exit 1
}
