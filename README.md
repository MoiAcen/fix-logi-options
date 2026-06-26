# fix-logi-options

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

> ## 📣 給 Logitech 的一封公開信
>
> 你們的 **Logitech Options** 又又又罷工了。
> 滑鼠的**自訂鍵設定隨機失效**——明明設好的按鍵突然沒反應，核心進程 `LogiOptionsMgr.exe`
> 不是假死就是直接擺爛，要嘛重開軟體、要嘛重開機才會好。
>
> 這個 bug **存在好幾年了**，論壇上一堆人哭，你們依然當沒看到。
> 既然官方不做事，那就由使用者自己寫排程幫你們擦屁股。
> 謝謝 Logitech 讓我有機會練 PowerShell。🙏
>
> *(Logitech Options randomly loses mouse button customizations — a bug that has existed
> for years and Logitech still hasn't fixed. So we fix it ourselves.)*

---

## 這個專案做什麼

註冊一個 Windows 排程任務（`FixLogiOptions`），在以下時機自動**重啟 Logitech Options 進程**，
讓滑鼠自訂鍵恢復作用：

- 🔑 **使用者登入時**
- ⏰ **系統從睡眠/休眠喚醒時**

每次執行會：

1. 結束 `LogiOptions`、`LogiOptionsMgr`、`LogiOverlay` 三支進程（先正常關閉，殘留再強制結束）
2. 等待後重新啟動核心進程 `LogiOptionsMgr.exe`（會自動帶起其他子進程）
3. **驗證進程是否成功存活**，判斷重啟是否成功
4. 將含時間戳的紀錄寫入 `%TEMP%\FixLogiOptions.log`

---

## 系統需求

- Windows 10 或更新版本
- PowerShell 5.1 以上（Windows 10 內建）
- 已安裝 Logitech Options，且核心程式位於預設路徑：
  `C:\ProgramData\Logishrd\LogiOptions\Software\Current\LogiOptionsMgr.exe`
- 安裝/移除排程需要**系統管理員權限**

---

## 使用方法

### 安裝（上服務）

以**系統管理員身分**開啟 PowerShell，執行：

```powershell
.\Install-LogiTask.ps1
```

腳本會先檢查管理員權限與 Logitech Options 是否安裝，通過後才註冊排程。

### 移除（下服務）

以**系統管理員身分**開啟 PowerShell，執行：

```powershell
.\Uninstall-LogiTask.ps1
```

### 手動測試重啟

`Restart-LogiOptions.ps1` 可獨立執行（**不需**管理員權限），用來測試重啟流程：

```powershell
.\Restart-LogiOptions.ps1
```

---

## 檔案說明

| 檔案 | 用途 |
|------|------|
| `Install-LogiTask.ps1` | 註冊排程任務（需管理員權限） |
| `Uninstall-LogiTask.ps1` | 移除排程任務（需管理員權限） |
| `Restart-LogiOptions.ps1` | 實際重啟 Logitech 進程並驗證存活 |
| `LICENSE` | MIT 授權條款 |

執行紀錄位置：`%TEMP%\FixLogiOptions.log`

---

## 授權

MIT — 詳見 [LICENSE](LICENSE)。
Copyright (c) 2026 MoiAcen.
