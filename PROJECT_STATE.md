# PROJECT_STATE

## 目的與範圍
百變兵團 / Avatar Star 靈敏度工具。支援官方 1~100 與 1~991 模式切換、還原、換算、偵測與診斷。

## 權威版本
- 版本：1.0
- 儲存庫：`Raven03115/AvatarStar-Sensitivity-Tool`
- 分支：`main`
- 核心實作：CMD + Windows PowerShell 5.1

## 已完成
- 自動偵測與手動指定 `AvatarStar.pde`。
- 動態 paired-signature 判斷 Original / 1~991。
- 1~991 套用與官方原版還原。
- 備份、transaction、rollback 與復原保護。
- 標準使用者 + UAC 管理員 Worker。
- 單行掃描進度 UI。
- 診斷匯出與靈敏度換算。

## 測試狀態
- Windows 11 本機：通過。
- Windows 11 Hyper-V：自動偵測、Original <-> 1~991、重開辨識、標準使用者/UAC、中文/空格/括號路徑均通過。
- Windows 10：未實測。

## 啟動方式
雙擊 `啟動_百變兵團靈敏度工具.cmd`。

## 已知事項
Windows 10 若有實際相容性回報，再依診斷資訊處理。
