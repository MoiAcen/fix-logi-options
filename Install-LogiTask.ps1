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

$TaskName   = 'FixLogiOptions'
$MgrPath    = 'C:\ProgramData\Logishrd\LogiOptions\Software\Current\LogiOptionsMgr.exe'
$ScriptPath = Join-Path $PSScriptRoot 'Restart-LogiOptions.ps1'

function Write-Log {
    param([string]$Message)
    Write-Host ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)
}

# --- 1. 系統管理員權限檢查 ---
$principalCheck = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principalCheck.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Log 'ERROR: 此腳本必須以系統管理員身分執行。請以「以系統管理員身分執行」開啟 PowerShell 後重試。'
    exit 1
}
Write-Log '系統管理員權限檢查通過。'

# --- 2. 程式存在檢查 ---
if (-not (Test-Path $MgrPath)) {
    Write-Log "ERROR: 找不到 LogiOptionsMgr.exe，路徑: $MgrPath"
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
