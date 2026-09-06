@echo off
setlocal EnableExtensions DisableDelayedExpansion
chcp 950 >nul
title Avatar Star Sensitivity Tool
color 07
mode con: cols=110 lines=36 >nul 2>&1

set "TOOLVER=1.0"
set "BACKEND=%~dp0AvatarStar_Backend.ps1"
set "WORKER=%~dp0AvatarStar_AdminWorker.ps1"
set "STARTWORKER=%~dp0AvatarStar_StartAdminWorker.ps1"
set "SENDREQUEST=%~dp0AvatarStar_SendRequest.ps1"
set "WAITPROGRESS=%~dp0AvatarStar_WaitProgress.ps1"
set "CHECKWORKER=%~dp0AvatarStar_CheckWorker.ps1"
set "SHOWCANDIDATES=%~dp0AvatarStar_ShowCandidates.ps1"
set "USERDISCOVERY=%~dp0AvatarStar_UserDiscovery.ps1"

set "P=                     "
set "ADMIN_OK=0"

if not exist "%BACKEND%" goto MissingFiles
if not exist "%WORKER%" goto MissingFiles
if not exist "%STARTWORKER%" goto MissingFiles
if not exist "%SENDREQUEST%" goto MissingFiles
if not exist "%WAITPROGRESS%" goto MissingFiles
if not exist "%CHECKWORKER%" goto MissingFiles
if not exist "%SHOWCANDIDATES%" goto MissingFiles
if not exist "%USERDISCOVERY%" goto MissingFiles

set "SESSION=%TEMP%\AvatarStarTool_%RANDOM%_%RANDOM%"
mkdir "%SESSION%" >nul 2>&1
if errorlevel 1 goto SessionError
set "STATEFILE=%SESSION%\result.txt"
set "STOPFILE=%SESSION%\stop.flag"

call :ClearGameState
call :ClearResponse

cls
echo.
echo.
echo.
echo %P%                     Avatar Star Sensitivity Tool
echo %P%                              v%TOOLVER%
echo.
echo %P%正在取得系統管理員權限...
echo.

powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%STARTWORKER%" -SessionDir "%SESSION%" -ToolVersion "%TOOLVER%" >nul 2>&1
if errorlevel 1 goto AdminStartupError
set "ADMIN_OK=1"

call :Detect
goto Main

:MissingFiles
cls
echo.
echo.
echo.
echo %P%                     Avatar Star Sensitivity Tool
echo.
echo %P%[X] 工具檔案不完整，請重新解壓縮完整 ZIP。
echo.
echo %P%按任意鍵關閉...
pause >nul
goto EndNoSession

:SessionError
cls
echo.
echo.
echo.
echo %P%[X] 無法建立工具工作階段暫存資料夾。
echo.
echo %P%按任意鍵關閉...
pause >nul
goto EndNoSession

:AdminStartupError
cls
echo.
echo.
echo.
echo %P%                     Avatar Star Sensitivity Tool
echo %P%                              v%TOOLVER%
echo.
echo %P%[X] 未能啟動隱藏的管理員 Worker。
echo.
echo %P%若 Windows 顯示 UAC，請允許本工具使用系統管理員權限。
echo %P%可見 CMD 本身不會重新以管理員模式啟動。
echo.
echo %P%按任意鍵關閉...
pause >nul
goto End

:ClearResponse
set "REQUESTID="
set "STATUS="
set "MESSAGE="
set "RESULT="
set "FOLDER="
set "PDE="
set "PDESTATUS="
set "SIZE="
set "HASH="
set "STATE="
set "LABEL="
set "COMPAT="
set "GAMEVERSION="
set "SOURCE="
set "CANDIDATECOUNT="
set "SEARCHINCOMPLETE="
set "HIPINPUT="
set "THEORY="
set "RECOMMENDED="
set "REACHABLE="
set "MATCHCOUNT="
set "PATCH1OFFSET="
set "PATCH2OFFSET="
set "PATCH1BYTES="
set "PATCH2BYTES="
set "KNOWNSAMPLE="
set "RECOVERY="
set "RECOVERYMESSAGE="
set "ANALYSISMETHOD="
set "STABLE="
set "ANALYSISERROR="
set "CLEARSTATE="
exit /b

:ClearGameState
set "GAME_FOLDER="
set "GAME_PDE="
set "GAME_PDESTATUS=NOTFOUND"
set "GAME_SIZE="
set "GAME_HASH="
set "GAME_STATE=Unknown"
set "GAME_LABEL=未知"
set "GAME_COMPAT=UNVERIFIED"
set "GAME_VERSION=無法讀取"
set "GAME_SOURCE="
set "GAME_MATCHCOUNT="
set "GAME_PATCH1OFFSET="
set "GAME_PATCH2OFFSET="
set "GAME_PATCH1BYTES="
set "GAME_PATCH2BYTES="
set "GAME_KNOWNSAMPLE="
set "GAME_RECOVERY=NO"
set "GAME_RECOVERYMESSAGE="
set "GAME_ANALYSISMETHOD="
set "GAME_STABLE="
set "GAME_ANALYSISERROR="
exit /b

:ReadResult
if not exist "%STATEFILE%" exit /b
for /f "usebackq tokens=1,* delims==" %%A in ("%STATEFILE%") do set "%%A=%%B"
exit /b

:AdoptGameState
if /i not "%PDESTATUS%"=="FOUND" exit /b
set "GAME_FOLDER=%FOLDER%"
set "GAME_PDE=%PDE%"
set "GAME_PDESTATUS=%PDESTATUS%"
set "GAME_SIZE=%SIZE%"
set "GAME_HASH=%HASH%"
set "GAME_STATE=%STATE%"
set "GAME_LABEL=%LABEL%"
set "GAME_COMPAT=%COMPAT%"
set "GAME_VERSION=%GAMEVERSION%"
set "GAME_SOURCE=%SOURCE%"
set "GAME_MATCHCOUNT=%MATCHCOUNT%"
set "GAME_PATCH1OFFSET=%PATCH1OFFSET%"
set "GAME_PATCH2OFFSET=%PATCH2OFFSET%"
set "GAME_PATCH1BYTES=%PATCH1BYTES%"
set "GAME_PATCH2BYTES=%PATCH2BYTES%"
set "GAME_KNOWNSAMPLE=%KNOWNSAMPLE%"
set "GAME_RECOVERY=%RECOVERY%"
set "GAME_RECOVERYMESSAGE=%RECOVERYMESSAGE%"
set "GAME_ANALYSISMETHOD=%ANALYSISMETHOD%"
set "GAME_STABLE=%STABLE%"
set "GAME_ANALYSISERROR=%ANALYSISERROR%"
exit /b

:CheckWorker
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%CHECKWORKER%" -SessionDir "%SESSION%" >nul 2>&1
if errorlevel 1 (
    set "ADMIN_OK=0"
    exit /b 1
)
set "ADMIN_OK=1"
exit /b 0

:WorkerAction
set "WACTION=%~1"
call :ClearResponse
call :CheckWorker
if errorlevel 1 (
    set "STATUS=ERROR"
    set "MESSAGE=管理員 Worker 已停止或工作階段已鎖定；請重新啟動工具。"
    if /i "%WACTION%"=="Apply991" call :ClearGameState
    if /i "%WACTION%"=="Restore" call :ClearGameState
    if /i "%WACTION%"=="Recover" call :ClearGameState
    exit /b
)

del /q "%STATEFILE%" >nul 2>&1
set "AVATARSTAR_REQ_TARGET=%WA_TARGET%"
set "AVATARSTAR_REQ_CONVERT=%WA_CONVERT%"
set "AVATARSTAR_REQ_VALUE=%WA_VALUE%"
set "AVATARSTAR_REQ_ZOOM=%WA_ZOOM%"
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%SENDREQUEST%" -SessionDir "%SESSION%" -Action "%WACTION%" >nul 2>&1
set "SEND_RC=%ERRORLEVEL%"
set "AVATARSTAR_REQ_TARGET="
set "AVATARSTAR_REQ_CONVERT="
set "AVATARSTAR_REQ_VALUE="
set "AVATARSTAR_REQ_ZOOM="
set "WA_TARGET="
set "WA_CONVERT="
set "WA_VALUE="
set "WA_ZOOM="
if not "%SEND_RC%"=="0" (
    set "STATUS=ERROR"
    set "MESSAGE=無法送出管理員 Worker 要求；Worker 可能已停止或工作階段已鎖定。"
    set "ADMIN_OK=0"
    if /i "%WACTION%"=="Apply991" call :ClearGameState
    if /i "%WACTION%"=="Restore" call :ClearGameState
    if /i "%WACTION%"=="Recover" call :ClearGameState
    exit /b
)

powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%WAITPROGRESS%" -SessionDir "%SESSION%"
call :ReadResult
if not defined STATUS (
    set "STATUS=ERROR"
    set "MESSAGE=管理員後端沒有回傳可驗證的結果。"
)
if /i "%STATUS%"=="ERROR" (
    if /i "%CLEARSTATE%"=="YES" call :ClearGameState
)
call :CheckWorker >nul 2>&1
exit /b

:UserContextAction
set "UACTION=%~1"
call :ClearResponse
call :CheckWorker
if errorlevel 1 (
    set "STATUS=ERROR"
    set "MESSAGE=管理員 Worker 已停止；請重新啟動工具。"
    set "ADMIN_OK=0"
    exit /b
)

del /q "%STATEFILE%" >nul 2>&1
set "AVATARSTAR_USER_TARGET=%UA_TARGET%"
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%USERDISCOVERY%" -BackendPath "%BACKEND%" -SessionDir "%SESSION%" -Action "%UACTION%" -ToolVersion "%TOOLVER%"
set "USERDISC_RC=%ERRORLEVEL%"
set "AVATARSTAR_USER_TARGET="
set "UA_TARGET="
call :ReadResult
if not defined STATUS (
    set "STATUS=ERROR"
    set "MESSAGE=原始使用者偵測後端沒有回傳可驗證的結果。"
)
call :CheckWorker >nul 2>&1
exit /b

:Detect
call :ClearGameState
cls
echo.
echo.
echo.
echo %P%                         正在偵測遊戲位置
echo.
call :UserContextAction Locate
if /i "%STATUS%"=="OK" (
    call :AdoptGameState
    exit /b
)
if /i "%STATUS%"=="MULTIPLE" (
    call :ChooseMultiple
    exit /b
)
exit /b

:ChooseMultiple
cls
echo.
echo.
echo.
echo %P%                         找到多個遊戲安裝
echo.
echo %P%同一優先層級找到多份 AvatarStar.pde，沒有足夠證據替你亂選。
echo %P%請選擇目前實際使用的安裝：
echo.
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%SHOWCANDIDATES%" -SessionDir "%SESSION%"
echo %P%[0]  取消
echo.
set "MCHOICE="
set /p "MCHOICE=%P%選擇 > "
if "%MCHOICE%"=="0" exit /b
if not defined MCHOICE goto ChooseMultiple
set "WA_VALUE=%MCHOICE%"
call :WorkerAction SelectCandidate
if /i "%STATUS%"=="OK" (
    call :AdoptGameState
    exit /b
)
cls
echo.
echo.
echo.
echo %P%[X] %MESSAGE%
echo.
echo %P%按任意鍵重新選擇...
pause >nul
goto ChooseMultiple

:Main
call :CheckWorker >nul 2>&1
cls
echo.
echo.
echo %P%                     Avatar Star Sensitivity Tool
echo %P%                              v%TOOLVER%
echo.
if defined GAME_FOLDER goto MainHasFolder
echo %P%遊戲位置      尚未找到
goto MainAfterFolder

:MainHasFolder
echo %P%遊戲位置      %GAME_FOLDER%

:MainAfterFolder
echo %P%遊戲版本      %GAME_VERSION%
if /i "%GAME_PDESTATUS%"=="FOUND" goto MainPdeFound
echo %P%PDE 狀態      尚未找到
goto MainAfterPde

:MainPdeFound
echo %P%PDE 狀態      已找到

:MainAfterPde
echo %P%目前模式      %GAME_LABEL%
if /i "%GAME_COMPAT%"=="SUPPORTED" goto MainCompatSupported
if /i "%GAME_COMPAT%"=="RECOVERY" goto MainCompatRecovery
echo %P%修改相容性    尚未驗證
goto MainAfterCompat

:MainCompatSupported
echo %P%修改相容性    已支援
goto MainAfterCompat

:MainCompatRecovery
echo %P%修改相容性    需先復原

:MainAfterCompat
if "%ADMIN_OK%"=="1" goto MainAdminOK
echo %P%管理員權限    Worker 已停止 / 工作階段已鎖定
goto MainAfterAdmin

:MainAdminOK
echo %P%管理員權限    已取得

:MainAfterAdmin
echo.
echo %P%--------------------------------------------------------------------
echo.
echo %P%[1]  套用 1~991     每格 = 原版 0.1
echo %P%[2]  還原官方原版 1~100
echo %P%[3]  靈敏度換算 / 查看公式
echo %P%[4]  重新偵測 / 手動指定遊戲位置
echo %P%[5]  查看詳細狀態
echo %P%[6]  匯出診斷報告
echo %P%[0]  離開
echo.
echo %P%--------------------------------------------------------------------
echo.
set "CHOICE="
set /p "CHOICE=%P%選擇 > "
if "%CHOICE%"=="1" goto Apply991
if "%CHOICE%"=="2" goto Restore
if "%CHOICE%"=="3" goto Calculator
if "%CHOICE%"=="4" goto Location
if "%CHOICE%"=="5" goto Details
if "%CHOICE%"=="6" goto Diagnostic
if "%CHOICE%"=="0" goto End
goto Main

:NeedPatchable
if not defined GAME_FOLDER goto NeedPatchableNoGame
if /i not "%GAME_PDESTATUS%"=="FOUND" goto NeedPatchableNoGame
if /i "%GAME_COMPAT%"=="RECOVERY" goto NeedPatchableRecovery
if /i not "%GAME_COMPAT%"=="SUPPORTED" goto NeedPatchableUnsupported
exit /b 0

:NeedPatchableNoGame
cls
echo.
echo.
echo.
echo %P%                         尚未找到遊戲
echo.
echo %P%請先使用主選單 [4] 重新偵測或手動指定位置。
echo.
echo %P%按任意鍵返回...
pause >nul
exit /b 1

:NeedPatchableRecovery
cls
echo.
echo.
echo.
echo %P%                         偵測到未完成修改
echo.
echo %P%%GAME_RECOVERYMESSAGE%
echo.
echo %P%工具可先執行安全復原，確認檔案回到可驗證狀態後再繼續。
echo.
set "CONFIRM="
set /p "CONFIRM=%P%是否先執行安全復原？ Y/N > "
if /i not "%CONFIRM%"=="Y" exit /b 1
call :WorkerAction Recover
if /i "%PDESTATUS%"=="FOUND" call :AdoptGameState
if /i not "%STATUS%"=="OK" goto NeedPatchableRecoveryFailed
if /i not "%GAME_COMPAT%"=="SUPPORTED" goto NeedPatchableRecoveryFailed
exit /b 0

:NeedPatchableRecoveryFailed
color 07
cls
echo.
echo.
echo.
echo %P%                              復原結果
echo.
echo %P%[X] %MESSAGE%
echo.
echo %P%按任意鍵返回...
pause >nul
exit /b 1

:NeedPatchableUnsupported
cls
echo.
echo.
echo.
echo %P%                         修改相容性尚未驗證
echo.
echo %P%AvatarStar.pde 已找到，但沒有找到「唯一且可驗證」的靈敏度結構。
if defined GAME_ANALYSISERROR echo %P%分析狀態      尚未完成（可匯出診斷報告）
echo %P%工具不會因檔案大小、舊 Hash 或舊固定 offset 而強制修改。
echo %P%可使用 [5] 查看實際 match / bytes，或 [6] 匯出診斷報告。
echo.
echo %P%按任意鍵返回...
pause >nul
exit /b 1

:Apply991
call :NeedPatchable
if errorlevel 1 goto Main
cls
echo.
echo.
echo.
echo %P%                         套用 1~991 模式
echo.
echo %P%遊戲位置  %GAME_FOLDER%
echo %P%目前模式  %GAME_LABEL%
echo.
echo %P%每增加 1 格 = 原版增加 0.1
echo %P%修改前會重新完整分析 PDE，並建立完整原版備份。
echo.
set "CONFIRM="
set /p "CONFIRM=%P%確定繼續？ Y/N > "
if /i not "%CONFIRM%"=="Y" goto Main
call :WorkerAction Apply991
if /i "%PDESTATUS%"=="FOUND" call :AdoptGameState
goto ShowResult

:Restore
call :NeedPatchable
if errorlevel 1 goto Main
cls
echo.
echo.
echo.
echo %P%                         還原官方原版
echo.
echo %P%遊戲位置  %GAME_FOLDER%
echo %P%目前模式  %GAME_LABEL%
echo.
set "CONFIRM="
set /p "CONFIRM=%P%確定還原 1~100 官方原版？ Y/N > "
if /i not "%CONFIRM%"=="Y" goto Main
call :WorkerAction Restore
if /i "%PDESTATUS%"=="FOUND" call :AdoptGameState
goto ShowResult

:ShowResult
color 07
cls
echo.
echo.
echo.
echo %P%                              執行結果
echo.
if /i "%STATUS%"=="OK" goto ShowResultOK
echo %P%[X] %MESSAGE%
echo.
goto ShowResultEnd

:ShowResultOK
echo %P%[OK] %MESSAGE%
echo.
if defined GAME_FOLDER echo %P%遊戲位置  %GAME_FOLDER%
if defined GAME_LABEL echo %P%目前模式  %GAME_LABEL%

:ShowResultEnd
echo.
echo %P%按任意鍵返回...
pause >nul
goto Main

:Calculator
cls
echo.
echo.
echo.
echo %P%                       靈敏度換算 / 查看公式
echo.
echo %P%1~991 模式
echo %P%  原版 -^> 新值：新值 = 10 x 原版值 - 9
echo %P%  新值 -^> 原版：原版值 = ^(新值 + 9^) / 10
echo %P%  每增加 1 格 = 原版增加 0.1
echo.
echo %P%--------------------------------------------------------------------
echo.
echo %P%[1]  原版值 -^> 1~991
echo %P%[2]  1~991 -^> 原版值
echo.
echo %P%[5]  靈敏度 x 瞄準鏡 1:1 計算
echo.
echo %P%[0]  返回
echo.
set "C="
set /p "C=%P%選擇 > "
if "%C%"=="0" goto Main
if "%C%"=="5" goto VisualDefault
set "CMODE="
if "%C%"=="1" set "CMODE=OldTo991"
if "%C%"=="2" set "CMODE=Mode991ToOld"
if not defined CMODE goto Calculator
set "V="
set /p "V=%P%輸入數值 > "
set "WA_CONVERT=%CMODE%"
set "WA_VALUE=%V%"
call :WorkerAction Convert
cls
echo.
echo.
echo.
echo %P%                              換算結果
echo.
if /i "%STATUS%"=="OK" goto CalculatorOK
echo %P%[X] %MESSAGE%
goto CalculatorEnd

:CalculatorOK
echo %P%結果 = %RESULT%

:CalculatorEnd
echo.
echo %P%按任意鍵返回...
pause >nul
goto Calculator

:VisualDefault
set "VMZOOM=3.4"
goto VisualMode

:VisualCustom
cls
echo.
echo.
echo.
echo %P%                         自訂倍率
echo.
set "VMZOOM="
set /p "VMZOOM=%P%輸入瞄準鏡倍率 > "
if not defined VMZOOM set "VMZOOM=3.4"
goto VisualMode

:VisualMode
cls
echo.
echo.
echo.
echo %P%                 靈敏度 x 瞄準鏡 1:1 計算
echo.
echo %P%預設瞄準鏡倍率約 3.4x
if not "%VMZOOM%"=="3.4" echo %P%目前使用瞄準鏡倍率 %VMZOOM%x
echo.
color 0C
echo %P%填入一般靈敏度，而非瞄準鏡靈敏度
color 07
echo.
echo %P%[1]  1~991 一般靈敏度
echo %P%[2]  原版一般靈敏度
echo %P%[3]  自訂倍率
echo %P%[0]  返回
echo.
set "VCHOICE="
set /p "VCHOICE=%P%選擇 > "
if "%VCHOICE%"=="0" goto Calculator
if "%VCHOICE%"=="3" goto VisualCustom
set "VINPUTMODE="
if "%VCHOICE%"=="1" set "VINPUTMODE=Mode991"
if "%VCHOICE%"=="2" set "VINPUTMODE=Original"
if not defined VINPUTMODE goto VisualMode
set "VINPUT="
set /p "VINPUT=%P%輸入一般靈敏度 > "
set "WA_CONVERT=%VINPUTMODE%"
set "WA_VALUE=%VINPUT%"
set "WA_ZOOM=%VMZOOM%"
call :WorkerAction VisualMatch
cls
echo.
echo.
echo.
echo %P%                              計算結果
echo.
if /i not "%STATUS%"=="OK" goto VisualError
echo %P%一般靈敏度        %HIPINPUT%
echo %P%1:1 理論值        %THEORY%
if /i "%REACHABLE%"=="YES" goto VisualReachable
echo %P%建議設定          超出目前可調範圍
goto VisualDone

:VisualReachable
echo %P%建議設定          %RECOMMENDED%
goto VisualDone

:VisualError
echo %P%[X] %MESSAGE%

:VisualDone
echo.
echo %P%按任意鍵返回...
pause >nul
goto VisualMode

:Location
cls
echo.
echo.
echo.
echo %P%                         遊戲位置偵測
echo.
echo %P%[1]  重新自動偵測
echo %P%[2]  手動指定遊戲位置
echo %P%[0]  返回
echo.
set "L="
set /p "L=%P%選擇 > "
if "%L%"=="0" goto Main
if "%L%"=="1" goto AutoLocation
if "%L%"=="2" goto ManualLocation
goto Location

:AutoLocation
call :Detect
if defined GAME_FOLDER goto AutoLocationFound
cls
echo.
echo.
echo.
echo %P%                              偵測結果
echo.
echo %P%[X] %MESSAGE%
echo.
echo %P%只有完全找不到 AvatarStar.pde 時才會啟動全磁碟 fallback。
echo %P%若仍找不到，工具資料夾會自動產生 AvatarStar_Detection_Diagnostic.txt。
echo.
echo %P%按任意鍵返回...
pause >nul
goto Location

:AutoLocationFound
cls
echo.
echo.
echo.
echo %P%                              偵測結果
echo.
echo %P%[OK] 已找到 AvatarStar.pde。
echo.
echo %P%遊戲位置      %GAME_FOLDER%
echo %P%遊戲版本      %GAME_VERSION%
echo %P%目前模式      %GAME_LABEL%
if /i "%GAME_COMPAT%"=="SUPPORTED" (
    echo %P%修改相容性    已支援
) else if /i "%GAME_COMPAT%"=="RECOVERY" (
    echo %P%修改相容性    需先復原
) else (
    echo %P%修改相容性    尚未驗證
)
if defined GAME_SOURCE echo %P%找到方式      %GAME_SOURCE%
echo.
echo %P%按任意鍵返回...
pause >nul
goto Main

:ManualLocation
cls
echo.
echo.
echo.
echo %P%                         手動指定遊戲位置
echo.
echo %P%可以貼上 AvatarStar 資料夾、AvatarStar.pde、client.exe 或 AvatarStar.exe。
echo.
set "MANUAL="
set /p "MANUAL=%P%路徑 > "
if not defined MANUAL goto Location
call :ClearGameState
set "UA_TARGET=%MANUAL%"
call :UserContextAction Inspect
if /i "%STATUS%"=="OK" (
    call :AdoptGameState
    goto ManualLocationOK
)
cls
echo.
echo.
echo.
echo %P%                              驗證結果
echo.
echo %P%[X] %MESSAGE%
echo.
echo %P%舊的遊戲位置狀態已清除；工具沒有修改任何 PDE。
echo %P%若指定位置實際存在，請提供 AvatarStar_Detection_Diagnostic.txt。
echo.
echo %P%按任意鍵返回...
pause >nul
goto Location

:ManualLocationOK
cls
echo.
echo.
echo.
echo %P%                              驗證結果
echo.
echo %P%[OK] 已找到 AvatarStar.pde。
echo.
echo %P%遊戲位置      %GAME_FOLDER%
echo %P%遊戲版本      %GAME_VERSION%
echo %P%目前模式      %GAME_LABEL%
if /i "%GAME_COMPAT%"=="SUPPORTED" (
    echo %P%修改相容性    已支援
) else if /i "%GAME_COMPAT%"=="RECOVERY" (
    echo %P%修改相容性    需先復原
) else (
    echo %P%修改相容性    尚未驗證
)
echo.
echo %P%按任意鍵返回...
pause >nul
goto Main

:Details
cls
echo.
echo.
echo.
echo %P%                              詳細狀態
echo.
echo %P%工具版本      %TOOLVER%
echo %P%支援修改      官方原版 ^<^> 1~991
echo %P%定位方式      動態成對 signature；已知固定 offset 不作為相容性門檻
echo.
if not defined GAME_FOLDER goto DetailsNoFolder
echo %P%遊戲資料夾    %GAME_FOLDER%
echo %P%遊戲版本      %GAME_VERSION%
echo %P%PDE           %GAME_PDE%
echo %P%PDE 大小      %GAME_SIZE% bytes
echo %P%SHA-256       %GAME_HASH%
echo %P%樣本辨識      %GAME_KNOWNSAMPLE%
echo %P%目前模式      %GAME_LABEL%
echo %P%Signature 數  %GAME_MATCHCOUNT%
echo %P%Patch #1      %GAME_PATCH1OFFSET%   %GAME_PATCH1BYTES%
echo %P%Patch #2      %GAME_PATCH2OFFSET%   %GAME_PATCH2BYTES%
echo %P%分析穩定      %GAME_STABLE%
if defined GAME_ANALYSISERROR echo %P%分析狀態      尚未完成（可匯出診斷報告）
if defined GAME_SOURCE echo %P%找到方式      %GAME_SOURCE%
if /i "%GAME_RECOVERY%"=="YES" echo %P%復原狀態      %GAME_RECOVERYMESSAGE%
goto DetailsStatusDone

:DetailsNoFolder
echo %P%遊戲資料夾    尚未找到
echo %P%遊戲版本      無法讀取
echo %P%目前模式      未知

:DetailsStatusDone
echo.
echo %P%--------------------------------------------------------------------
echo.
echo %P%按任意鍵返回...
pause >nul
goto Main

:Diagnostic
if defined GAME_FOLDER goto DiagnosticHasGame
call :NeedPatchableNoGame
goto Main

:DiagnosticHasGame
cls
echo.
echo.
echo.
echo %P%                         匯出診斷報告
echo.
echo %P%報告會包含遊戲路徑、版本、PDE Hash、signature offsets 與 bytes。
echo %P%請在你願意分享這些本機路徑資訊時再把報告傳給別人。
echo.
set "CONFIRM="
set /p "CONFIRM=%P%確定匯出？ Y/N > "
if /i not "%CONFIRM%"=="Y" goto Main
call :WorkerAction Diagnostic
if /i "%PDESTATUS%"=="FOUND" call :AdoptGameState
goto ShowResult

:End
if defined SESSION (
    >"%STOPFILE%" echo STOP
    >nul 2>&1 ping 127.0.0.1 -n 3
    rmdir /s /q "%SESSION%" >nul 2>&1
)
color 07
endlocal
exit /b

:EndNoSession
color 07
endlocal
exit /b
