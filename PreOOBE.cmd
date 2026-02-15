@echo off
REM Windows 10 LTSC 2021 Clean & Quiet - PreOOBE (specialize)
REM Applies privacy/account policies BEFORE OOBE, logs to Panther
REM Encoding: UTF-8 (no BOM), EOL: CRLF

setlocal EnableExtensions
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
  for /f %%# in ('"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -Command "Get-Date -Format o" 2^>nul') do (
    set "TS=%%#"
    goto :eof
  )
  set "TS=%DATE% %TIME%"
goto :eof

:log
  set "msg=%*"
  for /f %%G in ('"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -Command "Get-Date -Format o" 2^>nul') do set "ts=%%G"
  >>"%LOGFILE%" echo [%ts%] %msg%
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
call :log [SECTION] PreOOBE start

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
  call :log [SECTION] PreOOBE completed successfully
) else (
  call :log [WARN] PreOOBE completed with FAILED=%FAILED%
)

REM Bootstrap: one-time local admin + autologon
call :log [STEP] Launch BootstrapLocalAdmin.ps1
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%SystemRoot%\Setup\Scripts\BootstrapLocalAdmin.ps1" >> "%LOGFILE%" 2>&1
set "PSRC=%ERRORLEVEL%"
if not "%PSRC%"=="0" (
  set "FAILED=1"
  call :log [ERROR] BootstrapLocalAdmin.ps1 rc=%PSRC%
) else (
  call :log [OK] BootstrapLocalAdmin.ps1 rc=0
)
endlocal & exit /b %FAILED%
