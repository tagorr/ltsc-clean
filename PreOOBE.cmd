@echo off
REM Windows 11 Enterprise LTSC 2024 Clean & Quiet - PreOOBE (specialize)
REM Applies privacy/account policies BEFORE OOBE, logs to Panther
REM Encoding: UTF-8 (no BOM), EOL: CRLF

setlocal EnableExtensions
set "L2C_LOG_DATE_TOKEN="
set "L2C_LOG_ISO_DATE="
title PreOOBE ^& account policies

set "LOGDIR=%WINDIR%\Panther"
set "LOGFILE=%LOGDIR%\PreOOBE.log"
if not exist "%LOGDIR%" md "%LOGDIR%" >nul 2>&1

set "FAILED=0"

goto :main

:: --------------------------
:: Subroutines
:: --------------------------
:ts
  set "TS="
  set "L2C_LOG_DATE_BEFORE=%DATE%"
  if not "%L2C_LOG_DATE_BEFORE%"=="%L2C_LOG_DATE_TOKEN%" goto :preoobe_ts_refresh
  if not defined L2C_LOG_ISO_DATE goto :preoobe_ts_refresh
  goto :preoobe_ts_sample

:preoobe_ts_refresh
  set "L2C_LOG_DATE_TOKEN="
  set "L2C_LOG_ISO_DATE="
  for /f "delims=" %%# in ('call "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -Command "[DateTime]::Now.ToString('yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture)" 2^>nul') do set "L2C_LOG_ISO_DATE=%%#"
  if not defined L2C_LOG_ISO_DATE goto :preoobe_ts_sample
  if not "%L2C_LOG_ISO_DATE:~4,1%"=="-" goto :preoobe_ts_refresh_invalid
  if not "%L2C_LOG_ISO_DATE:~7,1%"=="-" goto :preoobe_ts_refresh_invalid
  if "%L2C_LOG_ISO_DATE:~9,1%"=="" goto :preoobe_ts_refresh_invalid
  if not "%L2C_LOG_ISO_DATE:~10,1%"=="" goto :preoobe_ts_refresh_invalid
  set "L2C_LOG_DATE_TOKEN=%L2C_LOG_DATE_BEFORE%"
  goto :preoobe_ts_sample

:preoobe_ts_refresh_invalid
  set "L2C_LOG_ISO_DATE="
  goto :preoobe_ts_sample

:preoobe_ts_sample
  set "L2C_LOG_TIME=%TIME%"
  set "L2C_LOG_DATE_AFTER=%DATE%"
  if not "%L2C_LOG_DATE_BEFORE%"=="%L2C_LOG_DATE_AFTER%" goto :preoobe_ts_changed
  if not defined L2C_LOG_ISO_DATE goto :preoobe_ts_raw
  set "L2C_LOG_HMS=%L2C_LOG_TIME:~0,8%"
  if "%L2C_LOG_HMS:~0,1%"==" " set "L2C_LOG_HMS=0%L2C_LOG_HMS:~1%"
  if not "%L2C_LOG_HMS:~2,1%"==":" goto :preoobe_ts_raw
  if not "%L2C_LOG_HMS:~5,1%"==":" goto :preoobe_ts_raw
  if "%L2C_LOG_HMS:~7,1%"=="" goto :preoobe_ts_raw
  set "TS=%L2C_LOG_ISO_DATE%T%L2C_LOG_HMS%"
  goto :eof

:preoobe_ts_changed
  set "L2C_LOG_DATE_TOKEN="
  set "L2C_LOG_ISO_DATE="

:preoobe_ts_raw
  set "TS=LOCAL_RAW %L2C_LOG_DATE_BEFORE% %L2C_LOG_TIME%"
  goto :eof

:log
  set "msg=%*"
  call :ts
  >>"%LOGFILE%" echo [%TS%] %msg%
  exit /b 0

:regadd
  REM Usage: call :regadd "HKLM\path" "ValueName" REG_DWORD "0"
  set "_rk=%~1"
  set "_rv=%~2"
  set "_rt=%~3"
  set "_rd=%~4"
  call :log [STEP] reg add "%_rk%" "%_rv%" %_rt% "%_rd%"
  reg add "%_rk%" /v "%_rv%" /t %_rt% /d %_rd% /f >nul 2>&1
  set "_rc=%ERRORLEVEL%"
  if not "%_rc%"=="0" (
    set "FAILED=1"
    call :log [ERROR] rc=%_rc% at "%_rk%" "%_rv%"
  ) else (
    call :log [OK] "%_rk%" "%_rv%"
  )
  set "_rk=" & set "_rv=" & set "_rt=" & set "_rd=" & set "_rc="
  exit /b 0

:: --------------------------
:: Main
:: --------------------------
:main
call :log ----- PreOOBE started -----
call :log [SECTION] PreOOBE policy phase start

REM 1) Local account security questions - disable (no questions when resetting local account passwords)
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\Windows\System"                   "NoLocalPasswordResetQuestions" ^
        REG_DWORD "1"

REM 2) OOBE Privacy Settings experience - disable (hide the privacy settings page during OOBE)
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\Windows\OOBE"                     "DisablePrivacyExperience" ^
        REG_DWORD "1"

REM 3) Diagnostic data - set to 0 (Security). Supported on Enterprise/LTSC; minimizes data collection.
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection"           "AllowTelemetry" ^
        REG_DWORD "0"

REM 4) Tailored experiences with diagnostic data - disable
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent"             "DisableTailoredExperiencesWithDiagnosticData" ^
        REG_DWORD "1"

REM 5) Advertising ID - disable value and enforce via policy
REM    - HKLM\...\AdvertisingInfo Enabled=0 (turns off Advertising ID)
REM    - Policies\...\AdvertisingInfo DisabledByGroupPolicy=1 (enforces via policy)
call :regadd "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo"    "Enabled" ^
        REG_DWORD "0"
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo"          "DisabledByGroupPolicy" ^
        REG_DWORD "1"

REM 6) Input personalization (inking & typing) / online speech - disable
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\InputPersonalization"             "AllowInputPersonalization" ^
        REG_DWORD "0"

REM 7) Location - disable Windows location provider and location services
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors"       "DisableWindowsLocationProvider" ^
        REG_DWORD "1"
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors"       "DisableLocation" ^
        REG_DWORD "1"

REM 8) Find my device - disable
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\FindMyDevice"                     "AllowFindMyDevice" ^
        REG_DWORD "0"

REM 9) Windows Consumer Features - disable (no suggested apps/consumer content)
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent"             "DisableWindowsConsumerFeatures" ^
        REG_DWORD "1"

REM 10) Feedback notifications - do not show "Rate your experience" toasts
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection"           "DoNotShowFeedbackNotifications" ^
        REG_DWORD "1"

if "%FAILED%"=="0" (
  call :log [SECTION] PreOOBE policy phase complete
) else (
  call :log [WARN] PreOOBE policy phase complete with FAILED=%FAILED%
)

REM Bootstrap: one-time local admin + secret generation only
call :log [STEP] Launch BootstrapLocalAdmin.ps1
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%SystemRoot%\Setup\Scripts\BootstrapLocalAdmin.ps1" >> "%LOGFILE%" 2>&1
set "PSRC=%ERRORLEVEL%"
if not "%PSRC%"=="0" (
  set "FAILED=1"
  call :log [ERROR] BootstrapLocalAdmin.ps1 rc=%PSRC%
) else (
  call :log [OK] BootstrapLocalAdmin.ps1 rc=0
)

REM Non-blocking marker for later Stage B observability (PreOOBE anomalies)
if exist "%WINDIR%\Panther\preoobe_warnings.flag" (
  call :log [WARN] PreOOBE anomaly marker detected: %WINDIR%\Panther\preoobe_warnings.flag
)
call :log ----- PreOOBE finished -----
if "%FAILED%"=="0" (
  call :log [FINAL] SUCCESS
  call :log [RC] returning 0
) else (
  call :log [FINAL] FAIL
  call :log [RC] returning 1
)
endlocal & exit /b %FAILED%
