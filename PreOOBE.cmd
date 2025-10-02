@echo off
REM Windows 10 LTSC 2021 Clean & Quiet — PreOOBE (specialize)
REM Applies privacy/account policies BEFORE OOBE, logs to Panther
REM Encoding: UTF-8 (no BOM), EOL: CRLF

setlocal EnableExtensions EnableDelayedExpansion
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
  REM Timestamp: try WMIC, then PowerShell, then %DATE% %TIME%
  set "TS="
  for /f "tokens=2 delims==" %%# in ('wmic os get LocalDateTime /value 2^>nul ^| find "="') do set "_ldt=%%#"
  if defined _ldt (
    set "TS=!_ldt:~0,4!-!_ldt:~4,2!-!_ldt:~6,2!T!_ldt:~8,2!:!_ldt:~10,2!:!_ldt:~12,2!.!_ldt:~15,3!"
    set "_ldt="
    goto :eof
  )
  for /f %%# in ('powershell -NoProfile -Command "Get-Date -Format o" 2^>nul') do (
    set "TS=%%#"
    goto :eof
  )
  set "TS=%DATE% %TIME%"
goto :eof

:log
  setlocal EnableDelayedExpansion
  set "msg="
  :log_more
    if "%~1"=="" goto log_emit
    set "msg=!msg! %~1"
    shift
    goto log_more
  :log_emit
  call :ts
  >>"%LOGFILE%" echo [!TS!]!msg!
  endlocal & goto :eof

:regadd
  REM Usage: call :regadd "HKLM\path" "ValueName" REG_DWORD "0"
  set "_rk=%~1"
  set "_rv=%~2"
  set "_rt=%~3"
  set "_rd=%~4"
  call :log [STEP] reg add "%_rk%" "%_rv%" %_rt% "%_rd%"
  reg add "%_rk%" /v "%_rv%" /t %_rt% /d %_rd% /f >nul 2>&1
  if errorlevel 1 (
    set "FAILED=1"
    call :log [ERROR] rc=!errorlevel! at "%_rk%" "%_rv%"
  ) else (
    call :log [OK] "%_rk%" "%_rv%"
  )
  set "_rk=" & set "_rv=" & set "_rt=" & set "_rd="
  exit /b 0

:: --------------------------
:: Main
:: --------------------------
:main
call :log [SECTION] PreOOBE start

REM 1) Local account security questions — disable (no questions when resetting local account passwords)
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\Windows\System"                   "NoLocalPasswordResetQuestions"                REG_DWORD "1"

REM 2) OOBE Privacy Settings experience — disable (hide the privacy settings page during OOBE)
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\Windows\OOBE"                     "DisablePrivacyExperience"                     REG_DWORD "1"

REM 3) Diagnostic data — set to 0 (Security). Supported on Enterprise/LTSC; minimizes data collection.
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection"           "AllowTelemetry"                               REG_DWORD "0"

REM 4) Tailored experiences with diagnostic data — disable
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent"             "DisableTailoredExperiencesWithDiagnosticData" REG_DWORD "1"

REM 5) Advertising ID — disable value and enforce via policy
REM    - HKLM\...\AdvertisingInfo Enabled=0 (turns off Advertising ID)
REM    - Policies\...\AdvertisingInfo DisabledByGroupPolicy=1 (enforces via policy)
call :regadd "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo"    "Enabled"                                      REG_DWORD "0"
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo"          "DisabledByGroupPolicy"                        REG_DWORD "1"

REM 6) Input personalization (inking & typing) / online speech — disable
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\InputPersonalization"             "AllowInputPersonalization"                    REG_DWORD "0"

REM 7) Location — disable Windows location provider and location services
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors"       "DisableWindowsLocationProvider"               REG_DWORD "1"
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors"       "DisableLocation"                              REG_DWORD "1"

REM 8) Find my device — disable
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\FindMyDevice"                     "AllowFindMyDevice"                            REG_DWORD "0"

REM 9) Windows Consumer Features — disable (no suggested apps/consumer content)
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent"             "DisableWindowsConsumerFeatures"               REG_DWORD "1"

REM 10) Feedback notifications — do not show “Rate your experience” toasts
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection"           "DoNotShowFeedbackNotifications"               REG_DWORD "1"



if "%FAILED%"=="0" (
  call :log [SECTION] PreOOBE completed successfully
) else (
  call :log [WARN] PreOOBE completed with FAILED=%FAILED%
)

rem Bootstrap: одноразовый локальный админ + автологон
powershell -NoProfile -ExecutionPolicy Bypass -File "%SystemRoot%\Setup\Scripts\BootstrapLocalAdmin.ps1"
endlocal & exit /b %FAILED%

