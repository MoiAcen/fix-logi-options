#Requires -Version 5.1
<#
.SYNOPSIS
    註冊 FixLogiOptions 排程任務（上服務）。必須以系統管理員身分執行。
.DESCRIPTION
    建立 Windows 排程任務，於「使用者登入」與「系統喚醒」時自動執行
    Restart-LogiOptions.ps1，重啟 Logitech Options 進程以恢復滑鼠自訂鍵。
    執行前會檢查系統管理員權限，並確認 LogiOptionsMgr.exe 是否存在。
#>

$ErrorActionPreference = 'Stop'

$TaskName       = 'FixLogiOptions'
$ScriptPath     = Join-Path $PSScriptRoot 'Restart-LogiOptions.ps1'
$DefaultMgrPath = 'C:\ProgramData\Logishrd\LogiOptions\Software\Current\LogiOptionsMgr.exe'

function Write-Log {
    param([string]$Message)
    Write-Host ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)
}

# 動態解析 LogiOptionsMgr.exe 路徑（執行中進程優先 → 預設路徑 → 遞迴搜尋）
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

# --- 1. 系統管理員權限檢查 ---
$principalCheck = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principalCheck.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Log 'ERROR: 此腳本必須以系統管理員身分執行。請以「以系統管理員身分執行」開啟 PowerShell 後重試。'
    exit 1
}
Write-Log '系統管理員權限檢查通過。'

# --- 2. 程式存在檢查（用 PowerShell 動態偵測路徑）---
# 正常情況下 LogiOptionsMgr 此刻應該已在執行；以執行中進程的實際路徑為優先依據。
$mgrRunning = Get-Process -Name 'LogiOptionsMgr' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($mgrRunning) {
    Write-Log ("偵測到 LogiOptionsMgr 正在執行 (PID: {0})，符合預期。" -f $mgrRunning.Id)
} else {
    Write-Log 'WARN: 未偵測到執行中的 LogiOptionsMgr（正常情況下此刻應在執行）。仍會嘗試以預設路徑安裝。'
}

$MgrPath = Get-LogiMgrPath
if (-not $MgrPath) {
    Write-Log 'ERROR: 找不到 LogiOptionsMgr.exe（進程未執行且預設安裝路徑不存在）。'
    Write-Log '請確認是否已安裝 Logitech Options，安裝後再執行。'
    exit 1
}
Write-Log "找到 LogiOptionsMgr.exe: $MgrPath"

# --- 3. 重啟腳本存在檢查 ---
if (-not (Test-Path $ScriptPath)) {
    Write-Log "ERROR: 找不到重啟腳本: $ScriptPath"
    Write-Log '請確認 Restart-LogiOptions.ps1 與本腳本位於同一資料夾。'
    exit 1
}
Write-Log "找到重啟腳本: $ScriptPath"

# --- 4. 組裝排程任務 ---
Write-Log '組裝排程任務定義...'

$action = New-ScheduledTaskAction `
    -Execute 'powershell.exe' `
    -Argument ('-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $ScriptPath)

# Trigger 1：登入時
$triggerLogon = New-ScheduledTaskTrigger -AtLogOn

# Trigger 2：系統喚醒時（Power-Troubleshooter EventID 1）
# New-ScheduledTaskTrigger 不直接支援事件觸發，改以 CIM 類別建立 event trigger。
$wakeSubscription = @'
<QueryList><Query Id="0" Path="System"><Select Path="System">*[System[Provider[@Name='Microsoft-Windows-Power-Troubleshooter'] and EventID=1]]</Select></Query></QueryList>
'@

$triggerWake = New-CimInstance `
    -CimClass (Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace Root/Microsoft/Windows/TaskScheduler) `
    -ClientOnly
$triggerWake.Enabled      = $true
$triggerWake.Subscription = $wakeSubscription

$principal = New-ScheduledTaskPrincipal `
    -GroupId 'BUILTIN\Users' `
    -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

# --- 5. 註冊任務 ---
Write-Log "註冊排程任務 '$TaskName'..."

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger @($triggerLogon, $triggerWake) `
    -Principal $principal `
    -Settings $settings `
    -Description '在登入與系統喚醒時重啟 Logitech Options 進程，因為 Logitech 自己不修這個 bug。' `
    -Force | Out-Null

Write-Log "排程任務 '$TaskName' 註冊成功。"
Write-Log '觸發時機：使用者登入時、系統喚醒時。'
Write-Log "執行紀錄將寫入: $env:TEMP\FixLogiOptions.log"
Write-Log '完成。'
