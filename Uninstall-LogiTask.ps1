#Requires -Version 5.1
<#
.SYNOPSIS
    移除 FixLogiOptions 排程任務（下服務）。必須以系統管理員身分執行。
#>

$ErrorActionPreference = 'Stop'

$TaskName = 'FixLogiOptions'

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

# --- 2. 檢查任務是否存在 ---
$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if (-not $existing) {
    Write-Log "排程任務 '$TaskName' 不存在，無需移除。"
    exit 0
}

# --- 3. 移除任務 ---
Write-Log "找到排程任務 '$TaskName'，移除中..."
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
Write-Log "排程任務 '$TaskName' 已成功移除。"
Write-Log '完成。接下來你又要自己面對 Logitech 的 bug 了，祝你好運。'
