@echo off
REM SPDX-License-Identifier: MIT
REM Windows 10 LTSC 2021 - Clean ^& Quiet Baseline (Official Tools Only)
setlocal EnableExtensions

:: ------------ logging ------------
set "LOG=%WINDIR%\Panther\SetupComplete.log"
set "REBOOT_FLAG=%WINDIR%\Panther\_needs_reboot.flag"
if not exist "%WINDIR%\Panther" mkdir "%WINDIR%\Panther" >nul 2>&1
if not exist "%WINDIR%\Logs\DISM" mkdir "%WINDIR%\Logs\DISM" >nul 2>&1
if exist "%REBOOT_FLAG%" (
  call :log "[WARN] Pre-existing Panther reboot flag found; treated as a sticky pending reboot marker; it will only be consumed by Stage B in normal mode when safe."
)

:: ------------ config flags ------------
set "LOG_TS_ENGINE=POWERSHELL"
set "ALWAYS_REBOOT_AFTER_FIRST_LOGON=0"
set "REBOOT_FLAG_CONTENT=need-reboot"
set "NEEDS_REBOOT=0"
set "REBOOT_REQUESTED=0"
set "WARN_REBOOT_FLAG_NO_EXECUTOR_EMITTED=0"
set "L2C_AUTOLOGON_ARMED=0"
set "L2C_AUTOLOGON_DEGRADED=0"
set "STAGEB_SKIPPED_GATE=0"
set "STAGEB_NOT_SCHEDULED=0"
set "FAILED=0"
set "DISM_HARD_FAIL="
set "HAS_DISM_WARN="
set "HAS_BOOTSTRAP_PW=0"
set "L2C_BOOTSTRAP_SECRET=%WINDIR%\Setup\Scripts\.bootstrap.pw"
set "L2C_PRIMARYADMIN_SECRET=%WINDIR%\Setup\Scripts\.primaryadmin.pw"
set "L2C_BOOTSTRAP_PW_ACL_OK=0"
set "L2C_BOOTSTRAP_PW_FORMAT_OK=0"
set "L2C_PRIMARYADMIN_PW_ACL_OK=0"
set "L2C_HAS_PRIMARYADMIN_SECRET=0"
set "L2C_PW_ALLOWED=ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789#@_-"
set "L2C_FIRST_BAD_RC="
call :log "----- SetupComplete started -----"

:: --- compatibility controls ---
set "REQUIRED_EDITION=EnterpriseS"
set "REQUIRED_DV=21H2"
set "MIN_BUILD=19044"
set "STRICT_DISPLAYVERSION=1"  :: 1 = abort on DV mismatch, 0 = warn and continue

:: ------------ platform gate ------------

REM --- EditionID read (robust, locale-safe) ---
set "ED="
for /f "skip=1 tokens=1,2,*" %%A in ('reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion" /v EditionID 2^>nul') do if /I "%%A"=="EditionID" set "ED=%%C"
REM Trim potential quotes
set "ED=%ED:"=%"
>>"%WINDIR%\Panther\SetupComplete.log" echo [INFO] Platform EditionID="%ED%"
if /I not "%ED%"=="%REQUIRED_EDITION%" (
  call :log "[ERROR] EditionID=%ED% (expected %REQUIRED_EDITION%). Aborting."
  set "FAILED=1"
  goto :l2c_final_rc
)
REM --- DisplayVersion (robust, locale-safe) ---
set "DV="
for /f "skip=1 tokens=1,2,*" %%A in ('reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion" /v DisplayVersion 2^>nul') do if /I "%%A"=="DisplayVersion" set "DV=%%C"
set "DV=%DV:"=%"
REM --- CurrentBuild (robust, locale-safe) ---
set "CB="
for /f "skip=1 tokens=1,2,*" %%A in ('reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion" /v CurrentBuild 2^>nul') do if /I "%%A"=="CurrentBuild" set "CB=%%C"
set "CB=%CB:"=%"
REM --- Normalize CurrentBuild into CBN (integer) ---
set "CBN="
if not defined CB (
  for /f "skip=1 tokens=1,2,*" %%A in ('reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion" /v CurrentBuild 2^>nul') do if /I "%%A"=="CurrentBuild" set "CB=%%C"
  set "CB=%CB:"=%"
)
for /f "tokens=1 delims= " %%# in ("%CB%") do set "CBN=%%#"
set /a CBN+=0 >nul 2>&1
call :gate_build
if errorlevel 1 (
  set "FAILED=1"
  goto :l2c_final_rc
)
call :gate_dv
if errorlevel 1 (
  set "FAILED=1"
  goto :l2c_final_rc
)
goto :main

:: ------------ functions ------------
:log
setlocal DisableDelayedExpansion
set "MSG=%~1"
if not defined MSG (endlocal & exit /b 0)
set "TS="
if /I "%LOG_TS_ENGINE%"=="WMIC" (
  for /f "tokens=2 delims==." %%G in ('wmic os get LocalDateTime /value 2^>nul ^| find "="') do set "TS_RAW=%%G"
  if defined TS_RAW (
    call set "TS=%TS_RAW:~0,4%-%TS_RAW:~4,2%-%TS_RAW:~6,2%T%TS_RAW:~8,2%:%TS_RAW:~10,2%:%TS_RAW:~12,2%.%TS_RAW:~15,3%"
  )
  set "TS_RAW="
)
if not defined TS if /I "%LOG_TS_ENGINE%"=="POWERSHELL" (
  for /f %%G in ('"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -Command "Get-Date -Format o" 2^>nul') do set "TS=%%G"
)
if not defined TS (
  for /f %%G in ('"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -Command "Get-Date -Format \"yyyy-MM-ddTHH:mm:ss\"" 2^>nul') do set "TS=%%G"
)
if not defined TS set "TS=%DATE:~6,4%-%DATE:~3,2%-%DATE:~0,2%T%TIME:~0,8%"
<nul set /p "=[%TS%] %MSG%" >> "%LOG%"
>> "%LOG%" echo(
endlocal & exit /b 0

:regadd
REM usage: call :regadd <key> <value> <type> <data>
set "RK=%~1"
set "RV=%~2"
set "RT=%~3"
set "RD=%~4"
reg add "%RK%" /v "%RV%" /t %RT% /d %RD% /f >nul 2>&1
if errorlevel 1 (
  call :log "[WARN] reg add failed: %~1 %~2"
) else (
  call :log "[STEP] reg add OK: %~1 %~2=%~4"
)
goto :eof

:l2c_defuser_quickaccess
REM Best-effort. Loads Default user hive to HKU\DefUser and applies a few Explorer defaults.
REM usage: call :l2c_defuser_quickaccess "%SystemDrive%\Users\Default\NTUSER.DAT"
set "L2C_DEFUSER_QA_FAILED=0"

reg load HKU\DefUser "%~1" >nul 2>&1
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
  call :log "[WARN] DEFUSER_LOAD_FAILED rc=%RC% hive=HKU\\DefUser file=%~1"
  goto :eof
)

reg add "HKU\DefUser\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v ShowRecent   /t REG_DWORD /d 0 /f >nul 2>&1
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
  set "L2C_DEFUSER_QA_FAILED=1"
  call :log "[WARN] DEFUSER_REGADD_FAILED rc=%RC% key=HKU\\DefUser\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced name=ShowRecent value=0"
)
reg add "HKU\DefUser\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v ShowFrequent /t REG_DWORD /d 0 /f >nul 2>&1
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
  set "L2C_DEFUSER_QA_FAILED=1"
  call :log "[WARN] DEFUSER_REGADD_FAILED rc=%RC% key=HKU\\DefUser\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced name=ShowFrequent value=0"
)
reg add "HKU\DefUser\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v LaunchTo     /t REG_DWORD /d 1 /f >nul 2>&1
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
  set "L2C_DEFUSER_QA_FAILED=1"
  call :log "[WARN] DEFUSER_REGADD_FAILED rc=%RC% key=HKU\\DefUser\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced name=LaunchTo value=1"
)

reg unload HKU\DefUser >nul 2>&1
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
  set "L2C_DEFUSER_QA_FAILED=1"
  call :log "[WARN] DEFUSER_UNLOAD_FAILED rc=%RC% hive=HKU\\DefUser"
)

if "%L2C_DEFUSER_QA_FAILED%"=="0" (
  call :log "[STEP] Default profile Quick Access configured (new users only)"
) else (
  call :log "[WARN] Default profile Quick Access tweaks incomplete (see prior warnings)"
)
set "L2C_DEFUSER_QA_FAILED="
set "RC="
goto :eof

:l2c_temp_logon_tweaks
REM Best-effort. Do not hard-fail if these cannot be applied.
reg add "%SYS%" /v DisableCAD /t REG_DWORD /d 1 /f >nul 2>&1
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" call :log "[WARN] TEMP_LOGON_TWEAK_FAILED rc=%RC% key=%SYS% name=DisableCAD value=1"
reg add "%NGC%" /v DevicePasswordLessBuildVersion /t REG_DWORD /d 0 /f >nul 2>&1
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" call :log "[WARN] TEMP_LOGON_TWEAK_FAILED rc=%RC% key=%NGC% name=DevicePasswordLessBuildVersion value=0"
set "RC="
goto :eof

:l2c_temp_logon_rollback
REM Best-effort rollback. Do not alter FINAL_RC if rollback fails.
reg add "%SYS%" /v DisableCAD /t REG_DWORD /d 0 /f >nul 2>&1
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" call :log "[WARN] TEMP_LOGON_ROLLBACK_FAILED rc=%RC% key=%SYS% name=DisableCAD value=0"
reg add "%NGC%" /v DevicePasswordLessBuildVersion /t REG_DWORD /d 2 /f >nul 2>&1
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" call :log "[WARN] TEMP_LOGON_ROLLBACK_FAILED rc=%RC% key=%NGC% name=DevicePasswordLessBuildVersion value=2"
set "RC="
goto :eof

:disable_feature_if_enabled
REM usage: call :disable_feature_if_enabled FeatureName LogName
set "FN=%~1"
set "LG=%~2"
if defined DISM_HARD_FAIL (
  call :log "[WARN] Skipping %LG% disable (previous DISM fatal RC)"
  goto :eof
)
if not defined FN goto :eof
call :log "[INFO] %LG% - attempting disable"
call :run_dism /Disable-Feature /FeatureName:%FN%
set "RC=%ERRORLEVEL%"
if defined DISM_HARD_FAIL (
  set "FAILED=1"
  call :log "[ERROR] %LG% disable failed (RC=%RC%)"
)
goto :eof

:remove_capability
REM usage: call :remove_capability CapabilityName Friendly
set "CAP=%~1"
set "FR=%~2"
if defined DISM_HARD_FAIL (
  call :log "[WARN] Skipping capability %FR% removal (previous DISM fatal RC)"
  goto :_cap_cleanup
)
if not defined CAP goto :_cap_cleanup
set "_cap_state="
set "_cap_probe_out=%TEMP%\l2c_cap_probe_%RANDOM%_%RANDOM%.txt"
if exist "%_cap_probe_out%" del /f /q "%_cap_probe_out%" >nul 2>&1
call :run_dism_capture "%_cap_probe_out%" /Get-CapabilityInfo /CapabilityName:%CAP% /English
set "DISM_RC=%L2C_LAST_DISM_RC%"

REM Hard-fail only. Otherwise, try to parse the output even if RC is non-zero.
if defined DISM_HARD_FAIL (
  call :log "[ERROR] Capability state retrieval failed for %FR% (%CAP%) (RC=%DISM_RC%)"
  goto :_cap_cleanup
)

if not "%DISM_RC%"=="0" (
  call :log "[WARN] Capability state retrieval returned RC=%DISM_RC% for %FR% (%CAP%); attempting to parse output anyway"
)
for /f "tokens=2 delims=:" %%S in ('findstr /C:"State :" "%_cap_probe_out%"') do set "_cap_state=%%S"
if not defined _cap_state (
  call :log "[WARN] Capability state missing for %FR% (%CAP%); skipping removal"
  goto :_cap_cleanup
)
set "_cap_state=%_cap_state: =%"
if not defined _cap_state (
  call :log "[WARN] Capability state parse failed for %FR% (%CAP%); skipping removal"
  goto :_cap_cleanup
)
echo [CAP] %FR% state=%_cap_state%>>"%LOG%"
if /i "%_cap_state%"=="Installed" goto :_cap_remove
if /i "%_cap_state%"=="Staged" goto :_cap_remove
if /i "%_cap_state%"=="NotPresent" (
  echo [CAP] %FR% not present, skip removal>>"%LOG%"
  goto :_cap_cleanup
)
if /i "%_cap_state%"=="Unknown" (
  echo [CAP] %FR% unknown, skip removal>>"%LOG%"
  goto :_cap_cleanup
)
echo [CAP] %FR% state=%_cap_state% -> skip removal>>"%LOG%"
goto :_cap_cleanup

:_cap_remove
call :log "[STEP] Remove capability %FR% (%CAP%)"
call :run_dism /Remove-Capability /CapabilityName:%CAP%
set "RC=%ERRORLEVEL%"
if "%RC%"=="0" (
  echo [CAP] %FR% removal succeeded>>"%LOG%"
  goto :_cap_cleanup
)
if defined DISM_HARD_FAIL (
  set "FAILED=1"
  call :log "[ERROR] Remove capability %FR% failed (RC=%RC%)"
) else (
  echo [CAP] %FR% removal returned RC=%RC% (non-fatal)>>"%LOG%"
)
goto :_cap_cleanup

:_cap_cleanup
if defined _cap_probe_out if exist "%_cap_probe_out%" del /f /q "%_cap_probe_out%" >nul 2>&1
set "_cap_state="
set "_cap_probe_out="
set "DISM_RC="
goto :eof

:gate_build
REM -- Ensure CBN (numeric CurrentBuild) and compare with MIN_BUILD if set --
if not defined CB (
  for /f "skip=1 tokens=1,2,*" %%A in ('reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion" /v CurrentBuild 2^>nul') do if /I "%%A"=="CurrentBuild" set "CB=%%C"
)
set "CB=%CB:"=%"
for /f "tokens=1 delims= " %%# in ("%CB%") do set "CBN=%%#"
set /a CBN+=0 >nul 2>&1
>>"%WINDIR%\Panther\SetupComplete.log" echo [INFO] CurrentBuild="%CB%" CBN=%CBN%
if not defined MIN_BUILD (
  call :log "[INFO] MIN_BUILD not set. Skipping build gate."
  exit /b 0
)
for /f "tokens=1 delims= " %%# in ("%MIN_BUILD%") do set "MBN=%%#"
set /a MBN+=0 >nul 2>&1
if %CBN% LSS %MBN% (
  call :log "[ERROR] CurrentBuild=%CBN% (expected >= %MBN%). Aborting."
  exit /b 1
)
exit /b 0

:gate_dv
REM -- DisplayVersion gate; STRICT_DISPLAYVERSION=1 enforces REQUIRED_DV --
if not defined DV (
  for /f "skip=1 tokens=1,2,*" %%A in ('reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion" /v DisplayVersion 2^>nul') do if /I "%%A"=="DisplayVersion" set "DV=%%C"
)
set "DV=%DV:"=%"
if not defined DV set "DV=<missing>"

if /I not "%STRICT_DISPLAYVERSION%"=="1" (
  if defined REQUIRED_DV if /I not "%DV%"=="%REQUIRED_DV%" call :log "[WARN] DisplayVersion=%DV% (expected %REQUIRED_DV%). Proceeding."
  exit /b 0
)

if /I not "%DV%"=="%REQUIRED_DV%" (
  call :log "[ERROR] DisplayVersion=%DV% (expected %REQUIRED_DV%). Aborting."
  exit /b 1
)
exit /b 0

REM ------------ RC handler ^& runners ------------
:handle_rc
set "COMP=%~1"
set "RC=%~2"
if "%RC%"=="0"    (call :log "[%COMP%] RC=0 (success)" & exit /b 0)
if "%RC%"=="3010" (call :log "[%COMP%] RC=3010 (success, reboot required)" & set "NEEDS_REBOOT=1" & call :flag_reboot & exit /b 0)
if "%RC%"=="1641" (call :log "[%COMP%] RC=1641 (success, reboot initiated by installer)" & set "NEEDS_REBOOT=1" & call :flag_reboot & exit /b 0)
call :log "[%COMP%] RC=%RC% (error)"
set "FAILED=1"
exit /b %RC%

:track_rc
REM %1 = RC
if "%~1"=="" exit /b 0
set "RC=%~1"
if "%RC%"=="0" exit /b 0
if "%RC%"=="3010" exit /b 0
if "%RC%"=="1641" exit /b 0
if defined L2C_FIRST_BAD_RC exit /b 0
set "L2C_FIRST_BAD_RC=%RC%"
exit /b 0

:track_rc_secrets
REM %1 = RC
if "%~1"=="" exit /b 0
if defined L2C_FIRST_BAD_RC exit /b 0
set "L2C_FIRST_BAD_RC=%~1"
exit /b 0

:run_dism
REM usage: call :run_dism <DISM-args-without-/Online>
set "CMD=dism /Online %* /Quiet /NoRestart /LogPath:%WINDIR%\Logs\DISM\SetupComplete-DISM.log /LogLevel:4 >nul 2>nul"
call :log "[DISM] %CMD%"
%CMD%
set "RC=%ERRORLEVEL%"
set "L2C_LAST_DISM_RC=%RC%"
call :classify_dism_rc %RC%
exit /b %RC%

:run_dism_capture
REM usage: call :run_dism_capture "<outfile>" <DISM-args-without-/Online>
set "OUT=%~1"
shift
set "CMD=dism /Online %1 %2 %3 %4 %5 %6 %7 %8 %9 /NoRestart /LogPath:%WINDIR%\Logs\DISM\SetupComplete-DISM.log /LogLevel:4"
call :log "[DISM] %CMD%"
%CMD% 1>"%OUT%" 2>&1
set "RC=%ERRORLEVEL%"
set "L2C_LAST_DISM_RC=%RC%"
call :classify_dism_rc %RC%
exit /b %RC%

:classify_dism_rc
REM usage: call :classify_dism_rc <RC>
set "L2C_DISM_RC=%~1"
if "%~1"=="0" goto :dism_ok
if "%~1"=="3010" goto :dism_rc3010
if "%~1"=="1641" goto :dism_rc1641
if "%~1"=="-2146498548" goto :dism_warn_unknown_feature
if "%~1"=="2148468748" goto :dism_warn_unknown_feature
if "%~1"=="-2146498541" goto :dism_warn_invalid_state
if "%~1"=="2148468755" goto :dism_warn_invalid_state
if "%~1"=="-2146498529" goto :dism_fatal
if "%~1"=="2148468767" goto :dism_fatal
if "%~1"=="-2146498283" goto :dism_fatal
if "%~1"=="2148469013" goto :dism_fatal
if "%~1"=="-2147024891" goto :dism_fatal
if "%~1"=="2147942405" goto :dism_fatal
if "%~1"=="87" goto :dism_fatal
if "%~1"=="998" goto :dism_fatal
goto :dism_fatal

:dism_rc3010
call :log "[DISM] RC=3010 (success, reboot required)"
set "NEEDS_REBOOT=1"
call :flag_reboot
exit /b 0

:dism_rc1641
call :log "[DISM] RC=1641 (success, reboot initiated by installer)"
set "NEEDS_REBOOT=1"
call :flag_reboot
exit /b 0

:dism_ok
call :log "[DISM] RC=0 (success)"
exit /b 0

:dism_warn_unknown_feature
set "HAS_DISM_WARN=1"
call :log "[DISM] RC=%L2C_DISM_RC% (warning, feature not recognized in this image)"
exit /b 0

:dism_warn_invalid_state
set "HAS_DISM_WARN=1"
call :log "[DISM] RC=%L2C_DISM_RC% (warning, invalid install state for this feature)"
exit /b 0

:dism_fatal
call :track_rc %L2C_DISM_RC%
set "FAILED=1"
set "DISM_HARD_FAIL=1"
call :log "[DISM] RC=%L2C_DISM_RC% (error)"
exit /b %L2C_DISM_RC%

:run_msi
REM usage: call :run_msi "<msi path>" [more MSI properties]
set "MSI=%~1"
shift
call :log "[MSI] msiexec /i \"%MSI%\" /qn REBOOT=ReallySuppress /norestart %*"
msiexec /i "%MSI%" /qn REBOOT=ReallySuppress /norestart %*
set "RC=%ERRORLEVEL%"
call :track_rc %RC%
call :handle_rc "MSI" %RC%
exit /b %ERRORLEVEL%

:run_exe
REM usage: call :run_exe "<exe path>" [vendor-specific args]; default /quiet /norestart
set "EXE=%~1"
shift
call :log "[EXE] \"%EXE%\" /quiet /norestart %*"
"%EXE%" /quiet /norestart %*
set "RC=%ERRORLEVEL%"
call :track_rc %RC%
call :handle_rc "EXE" %RC%
exit /b %ERRORLEVEL%

:validate_primaryadmin_password
set "L2C_PW_CHECK="
set "L2C_PW_SEEN=0"
if not defined L2C_PRIMARYADMIN_PASSWORD exit /b 1
if "%L2C_PRIMARYADMIN_PASSWORD%"=="" exit /b 1
set "L2C_PW_CHECK=%L2C_PRIMARYADMIN_PASSWORD%"

:_validate_primaryadmin_password_loop
if not defined L2C_PW_CHECK goto :_validate_primaryadmin_password_ok
if "%L2C_PW_CHECK%"=="" if "%L2C_PW_SEEN%"=="1" goto :_validate_primaryadmin_password_ok
set "L2C_PW_CHAR=%L2C_PW_CHECK:~0,1%"
call :is_primaryadmin_char_allowed "%L2C_PW_CHAR%"
if not "%ERRORLEVEL%"=="0" (
  set "L2C_PW_CHAR="
  set "L2C_PW_CHECK="
  set "L2C_PW_SEEN="
  exit /b 1
)
set "L2C_PW_SEEN=1"
set "L2C_PW_CHECK=%L2C_PW_CHECK:~1%"
goto :_validate_primaryadmin_password_loop
:_validate_primaryadmin_password_ok
set "L2C_PW_CHAR="
set "L2C_PW_CHECK="
set "L2C_PW_SEEN="
exit /b 0

:validate_bootstrap_password
set "L2C_PW_CHECK="
set "L2C_PW_SEEN=0"
if not defined L2C_BOOTSTRAP_PASSWORD exit /b 1
if "%L2C_BOOTSTRAP_PASSWORD%"=="" exit /b 1
set "L2C_PW_CHECK=%L2C_BOOTSTRAP_PASSWORD%"

:_validate_bootstrap_password_loop
if not defined L2C_PW_CHECK goto :_validate_bootstrap_password_ok
if "%L2C_PW_CHECK%"=="" if "%L2C_PW_SEEN%"=="1" goto :_validate_bootstrap_password_ok
set "L2C_PW_CHAR=%L2C_PW_CHECK:~0,1%"
call :is_primaryadmin_char_allowed "%L2C_PW_CHAR%"
if not "%ERRORLEVEL%"=="0" (
  set "L2C_PW_CHAR="
  set "L2C_PW_CHECK="
  set "L2C_PW_SEEN="
  exit /b 1
)
set "L2C_PW_SEEN=1"
set "L2C_PW_CHECK=%L2C_PW_CHECK:~1%"
goto :_validate_bootstrap_password_loop
:_validate_bootstrap_password_ok
set "L2C_PW_CHAR="
set "L2C_PW_CHECK="
set "L2C_PW_SEEN="
exit /b 0

:is_primaryadmin_char_allowed
set "L2C_PW_CHAR_TEST=%~1"
if "%L2C_PW_CHAR_TEST%"=="" (
  set "L2C_PW_CHAR_TEST="
  exit /b 1
)
set "L2C_PW_SCAN=%L2C_PW_ALLOWED:%~1=%"
if "%L2C_PW_SCAN%"=="%L2C_PW_ALLOWED%" (
  set "L2C_PW_SCAN="
  set "L2C_PW_CHAR_TEST="
  exit /b 1
)
set "L2C_PW_SCAN="
set "L2C_PW_CHAR_TEST="
exit /b 0

:main

:: ------------ Edge Update policies ------------
call :log "[SECTION] Edge Update policies"
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\EdgeUpdate" "UpdateDefault" "REG_DWORD" "0"
REM Optional: block installs too (uncomment if needed):
REM call :regadd "HKLM\SOFTWARE\Policies\Microsoft\EdgeUpdate" "InstallDefault" "REG_DWORD" "0"

:: ------------ Edge first run experience ------------
call :log "[SECTION] Edge first run experience"
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\Edge" "HideFirstRunExperience" "REG_DWORD" "1"
call :regadd "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer" "DisableEdgeDesktopShortcutCreation" "REG_DWORD" "1"

:: ------------ Edge SmartScreen (best-effort) ------------
call :log "[SECTION] Edge SmartScreen (best-effort)"
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\Edge" "SmartScreenEnabled" "REG_DWORD" "0"
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\Edge" "SmartScreenDnsRequestsEnabled" "REG_DWORD" "0"
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\Edge" "SmartScreenForTrustedDownloadsEnabled" "REG_DWORD" "0"
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\Edge" "SmartScreenPuaEnabled" "REG_DWORD" "0"

:: ------------ Internet Explorer First Run policy ------------
call :log "[SECTION] IE First Run policy"
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\Internet Explorer\Main" "DisableFirstRunCustomize" "REG_DWORD" "1"
call :log "[SECTION] SmartScreen & Defender"

REM ------------ SmartScreen ^& Defender (policy enforced) ------------
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\Windows\System" "EnableSmartScreen" "REG_DWORD" "0"
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection" "DisableRealtimeMonitoring" "REG_DWORD" "0"
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection" "DisableBehaviorMonitoring" "REG_DWORD" "0"
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection" "DisableIOAVProtection" "REG_DWORD" "0"
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\Windows Defender" "PUAProtection" "REG_DWORD" "1"
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\Spynet" "SpynetReporting" "REG_DWORD" "0"
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\Spynet" "SubmitSamplesConsent" "REG_DWORD" "2"
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\Spynet" "DisableBlockAtFirstSeen" "REG_DWORD" "1"
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\Spynet" "LocalSettingOverrideSpynetReporting" "REG_DWORD" "0"
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\MpEngine" "MpCloudBlockLevel" "REG_DWORD" "0"

:: ------------ Early Edge browser removal (guarantee layer) ------------
call :edge_remove

:: ------------ Telemetry / Diagnostics / WER ------------
call :log "[SECTION] Telemetry, Diagnostics, WER"
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting" "Disabled" "REG_DWORD" "1"
REM -- Services: disable and log (keep WerSvc at default/Manual; queue handled by task) --
call :svc_disable "DiagTrack"
call :svc_disable "dmwappushservice"
REM call :svc_disable "WerSvc"
REM -- Scheduled Tasks: CEIP / Appraiser / StartupAppTask / DiskDiagnostic / WER Queue --
call :task_disable "\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser"
call :task_disable "\Microsoft\Windows\Application Experience\ProgramDataUpdater"
call :task_disable "\Microsoft\Windows\Application Experience\StartupAppTask"
call :task_disable "\Microsoft\Windows\Customer Experience Improvement Program\Consolidator"
call :task_disable "\Microsoft\Windows\Customer Experience Improvement Program\AitAgent"
call :task_disable "\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip"
call :task_disable "\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector"
call :task_disable "\Microsoft\Windows\Windows Error Reporting\QueueReporting"
REM Ensure outbound firewall rule bound to DiagTrack exists
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "if(-not (Get-NetFirewallRule -DisplayName 'Block Telemetry Service (DiagTrack)' -ErrorAction SilentlyContinue)) { New-NetFirewallRule -DisplayName 'Block Telemetry Service (DiagTrack)' -Direction Outbound -Action Block -Enabled True -Service DiagTrack -Profile Any }" >nul 2>&1
call :fw_block_diagtrack

:: ------------ Delivery Optimization ------------
call :log "[SECTION] Delivery Optimization"
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization" "DODownloadMode" "REG_DWORD" "0"

:: ------------ Delivery Optimization cache limit ------------
call :log "[SECTION] Delivery Optimization cache limit"
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization" "DOAbsoluteMaxCacheSizeMB" "REG_DWORD" "2048"

:: ------------ Network quieting ------------
call :log "[SECTION] Network"
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\Internet Settings" "DisableWpad" "REG_DWORD" "1"
call :regadd "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\WinHttp" "DisableWpad" "REG_DWORD" "1"
netsh winhttp reset proxy >nul 2>&1
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient" "EnableMulticast" "REG_DWORD" "0"
netsh interface teredo set state disabled >nul 2>&1
netsh interface 6to4   set state disabled >nul 2>&1
netsh interface isatap set state disabled >nul 2>&1

:: ------------ OneDrive ------------
call :log "[SECTION] OneDrive"
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\Windows\OneDrive" "DisableFileSyncNGSC" "REG_DWORD" "1"

:: ------------ Services ------------
call :log "[SECTION] Services"
for %%S in (SysMain WSearch Spooler DiagTrack dmwappushservice WerSvc) do (
  sc config %%S start= disabled >nul 2>&1
  sc stop   %%S >nul 2>&1
)

:: ------------ WebDAV Redirector (WebClient) ------------
call :log "[SECTION] WebClient (WebDAV)"
call :log "[STEP] Disable service: WebClient (WebDAV)"
sc config WebClient start= disabled >nul 2>&1
for /f "tokens=3" %%# in ('sc query WebClient ^| findstr /i "STATE"') do set "S=%%#"
for /f "skip=2 tokens=3" %%# in ('reg query "HKLM\SYSTEM\CurrentControlSet\Services\WebClient" /v Start 2^>nul') do set "StartVal=%%#"
set "SNAME="
if "%S%"=="1" set "SNAME=STOPPED"
if "%S%"=="2" set "SNAME=START_PENDING"
if "%S%"=="3" set "SNAME=STOP_PENDING"
if "%S%"=="4" set "SNAME=RUNNING"
if "%S%"=="5" set "SNAME=CONTINUE_PENDING"
if "%S%"=="6" set "SNAME=PAUSE_PENDING"
if "%S%"=="7" set "SNAME=PAUSED"
call :log "[OK] WebClient Start=%StartVal% State=%S% (%SNAME%)"
sc stop   WebClient >nul 2>&1

:: ------------ Game Bar / Xbox / Game DVR ------------
call :log "[SECTION] GameDVR and Xbox"
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\Windows\GameDVR" "AllowGameDVR" "REG_DWORD" "0"
for %%S in (XblGameSave XboxGipSvc XboxNetApiSvc) do (
  sc config %%S start= disabled >nul 2>&1
  sc stop   %%S >nul 2>&1
)
:: Optional removal of Xbox Game Bar if present (harmless on LTSC if missing)
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -Command "Get-AppxPackage -AllUsers *XboxGamingOverlay* ^| Remove-AppxPackage" >nul 2>&1

:: ------------ Features (DISM /Disable-Feature) ------------
call :log "[SECTION] Features"
call :disable_feature_if_enabled "SMB1Protocol"                      "feat_smb1"
call :disable_feature_if_enabled "MicrosoftWindowsPowerShellV2"      "feat_ps2"
call :disable_feature_if_enabled "Printing-XPSServices-Features"     "feat_xps"
call :disable_feature_if_enabled "FaxServicesClientPackage"          "feat_fax"
call :disable_feature_if_enabled "ScanManagement"                    "feat_scan"
call :disable_feature_if_enabled "WorkFolders-Client"                "feat_workfolders"
call :disable_feature_if_enabled "AppCompatStepsRecorder"            "feat_psr"
call :disable_feature_if_enabled "MSRDC-Infrastructure"              "feat_rdc"
call :disable_feature_if_enabled "Internet-Explorer-Optional-amd64"  "feat_ie"
call :disable_feature_if_enabled "WindowsMediaPlayer"                "feat_wmp"
call :disable_feature_if_enabled "TelnetClient"                      "feat_telnet"
call :disable_feature_if_enabled "TFTP"                              "feat_tftp"
call :disable_feature_if_enabled "RemoteAssistance"                  "feat_ra"

:: ------------ Capabilities (DISM /Remove-Capability) ------------
call :log "[SECTION] Capabilities"
call :remove_capability "App.Support.QuickAssist~~~~0.0.1.0" "QuickAssist"
call :remove_capability "SNMP.Client~~~~0.0.1.0"             "SNMP.Client"
call :remove_capability "WMI-SNMP-Provider.Client~~~~0.0.1.0"       "WMI.SNMP.Provider"

:: ------------ Windows Update policy ------------
call :log "[SECTION] Windows Update"
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" "AUOptions" "REG_DWORD" "2"
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" "ExcludeWUDriversInQualityUpdate" "REG_DWORD" "1"
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" "ManagePreviewBuilds" "REG_DWORD" "1"
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" "ManagePreviewBuildsPolicyValue" "REG_DWORD" "1"
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" "AllowMUUpdateService" "REG_DWORD" "0"
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" "DisableOSUpgrade" "REG_DWORD" "1"
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\Windows\Device Metadata" "PreventDeviceMetadataFromNetwork" "REG_DWORD" "1"

REM ------------ UX ^& Power ------------
call :log "[SECTION] UX ^& Power"
call :regadd "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" "NoDriveTypeAutoRun" "REG_DWORD" "255"
call :regadd "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" "NoAutoRun" "REG_DWORD" "1"
call :regadd "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" "NoAutoPlay" "REG_DWORD" "1"
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\Windows\System" "EnableActivityFeed" "REG_DWORD" "0"
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\Windows\System" "PublishUserActivities" "REG_DWORD" "0"
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\Windows\System" "UploadUserActivities" "REG_DWORD" "0"
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\Windows\Explorer" "DisableSearchBoxSuggestions" "REG_DWORD" "1"
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search" "AllowCloudSearch" "REG_DWORD" "0"
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search" "ConnectedSearchUseWeb" "REG_DWORD" "0"
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search" "BingSearchEnabled" "REG_DWORD" "0"
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\Windows\System" "DisableWebSearch" "REG_DWORD" "1"

:: ------------ Explorer Quick Access defaults for new users ------------
call :log "[SECTION] Explorer Quick Access defaults"
set "DEFNTUSER=%SystemDrive%\Users\Default\NTUSER.DAT"
if exist "%DEFNTUSER%" (
  call :l2c_defuser_quickaccess "%DEFNTUSER%"
) else (
  call :log "[INFO] Default user hive not found; skipping Quick Access tweaks"
)

:: ------------ Power settings ------------
powercfg -h off >nul 2>&1
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" call :log "[WARN] POWERCFG_HIBERNATE_OFF_FAILED rc=%RC%"
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power" /v HiberbootEnabled /t REG_DWORD /d 0 /f >nul 2>&1
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" call :log "[WARN] REGADD_HIBERBOOT_DISABLED_FAILED rc=%RC% key=HKLM\\SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Power name=HiberbootEnabled value=0"
powercfg /setactive e9a42b02-d5df-448d-aa00-03f14749eb61 >nul 2>&1
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" call :log "[WARN] POWERCFG_SETACTIVE_FAILED rc=%RC% scheme=e9a42b02-d5df-448d-aa00-03f14749eb61"

REM === [L2C] Winlogon bootstrap + CAD/NGC policies (idempotent) ===
set "WL=HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
set "SYS=HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
set "NGC=HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI\Ngc"

REM Password source (created by BootstrapLocalAdmin.ps1):
set "PWFILE=%L2C_BOOTSTRAP_SECRET%"

REM Secret ACL/attribute validation (exit code bitmask from ValidateSecrets.ps1)
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass ^
  -File "%WINDIR%\Setup\Scripts\ValidateSecrets.ps1" ^
  -BootstrapPath "%L2C_BOOTSTRAP_SECRET%" ^
  -PrimaryAdminPath "%L2C_PRIMARYADMIN_SECRET%" >>"%LOG%" 2>&1

set "RC=%ERRORLEVEL%"

set "L2C_BOOTSTRAP_PW_ACL_OK=0"
set "L2C_PRIMARYADMIN_PW_ACL_OK=0"

if "%RC%"=="4" (
  set "FAILED=1"
  call :log "[ERROR] Secret validator internal failure (rc=4); treating both secrets as invalid"
  goto :l2c_secrets_rc_done
)

if "%RC%"=="0" goto :l2c_secrets_rc_decode
if "%RC%"=="1" goto :l2c_secrets_rc_decode
if "%RC%"=="2" goto :l2c_secrets_rc_decode
if "%RC%"=="3" goto :l2c_secrets_rc_decode

call :track_rc_secrets %RC%
set "FAILED=1"
call :log "[ERROR] Secret validator returned unexpected rc=%RC%, treating both secrets as invalid and closing the gate."
goto :l2c_secrets_rc_done

:l2c_secrets_rc_decode
set /a TMP=RC ^& 1
set /a L2C_BOOTSTRAP_PW_ACL_OK=TMP
set /a TMP=RC ^& 2
set /a L2C_PRIMARYADMIN_PW_ACL_OK=TMP / 2

:l2c_secrets_rc_done

set "TMP="
call :log "[SECTION] Secret ACL validation (bootstrap=%L2C_BOOTSTRAP_PW_ACL_OK%, primaryadmin=%L2C_PRIMARYADMIN_PW_ACL_OK%)"

REM Bootstrap secret presence check
if exist "%PWFILE%" (
  set "BOOTSTRAP_CHECK="
  REM Read the first line of the file, standard set /p VAR=<FILE syntax
  set /p BOOTSTRAP_CHECK=<"%PWFILE%"
)
if defined BOOTSTRAP_CHECK set "HAS_BOOTSTRAP_PW=1"
set "L2C_BOOTSTRAP_PW_FORMAT_OK=0"
if defined BOOTSTRAP_CHECK (
  set "L2C_BOOTSTRAP_PASSWORD=%BOOTSTRAP_CHECK%"
  call :validate_bootstrap_password
  if errorlevel 1 (
    set "FAILED=1"
    set "L2C_BOOTSTRAP_PW_FORMAT_OK=0"
    call :log "[ERROR] bootstrap password is empty or contains unsupported characters; only A-Z, a-z, 0-9, #, @, _ and - are allowed. Stage B registration and autologon priming will be skipped."
  ) else (
    set "L2C_BOOTSTRAP_PW_FORMAT_OK=1"
  )
  set "L2C_BOOTSTRAP_PASSWORD="
)
set "BOOTSTRAP_CHECK="

:after_pw_check
REM Bootstrap secret gate
if not "%HAS_BOOTSTRAP_PW%"=="1" (
  set "FAILED=1"
  call :log "[ERROR] .bootstrap.pw missing or empty; Stage B registration will be skipped."
)
if "%HAS_BOOTSTRAP_PW%"=="1" if not "%L2C_BOOTSTRAP_PW_ACL_OK%"=="1" (
  set "FAILED=1"
  call :log "[ERROR] .bootstrap.pw ACL/attributes invalid; expected SYSTEM + Administrators FullControl, no inheritance, Hidden+System."
)

REM Primary admin secret status (always logged)
if exist "%L2C_PRIMARYADMIN_SECRET%" (
  call :log "[INFO] .primaryadmin.pw present (path=%L2C_PRIMARYADMIN_SECRET%)."
) else (
  call :log "[WARN] .primaryadmin.pw missing (path=%L2C_PRIMARYADMIN_SECRET%)."
)
if not exist "%L2C_PRIMARYADMIN_SECRET%" (
  call :log "[INFO] .primaryadmin.pw ACL/attributes check skipped (file missing)."
) else (
  if not defined L2C_PRIMARYADMIN_PW_ACL_OK (
    call :log "[INFO] .primaryadmin.pw ACL/attributes status unknown (validation not run)."
  ) else (
    if "%L2C_PRIMARYADMIN_PW_ACL_OK%"=="1" (
      call :log "[INFO] .primaryadmin.pw ACL/attributes OK."
    ) else (
      call :log "[WARN] .primaryadmin.pw ACL/attributes BAD."
    )
  )
)

REM Primary admin secret SEC-2 gate: ACL/attributes must be valid before reading
if "%FAILED%"=="0" (
  if exist "%L2C_PRIMARYADMIN_SECRET%" (
    if not "%L2C_PRIMARYADMIN_PW_ACL_OK%"=="1" (
      set "FAILED=1"
      call :log "[ERROR] .primaryadmin.pw ACL/attributes invalid; expected SYSTEM + Administrators FullControl, no inheritance, Hidden+System."
    )
  )
)

REM Primary admin secret presence and load gate
if "%FAILED%"=="0" (
  if not exist "%L2C_PRIMARYADMIN_SECRET%" (
    call :log "[ERROR] primary admin secret file \"%L2C_PRIMARYADMIN_SECRET%\" not found; Stage B registration will be skipped."
  ) else (
    REM Read and validate primary admin password only if SEC-2 passed for .primaryadmin.pw
    if "%L2C_PRIMARYADMIN_PW_ACL_OK%"=="1" (
      set "L2C_PRIMARYADMIN_PASSWORD="
      REM Read the password, ignoring Hidden/System attributes
      set /p L2C_PRIMARYADMIN_PASSWORD=<"%L2C_PRIMARYADMIN_SECRET%"
      REM TEMP: skip trimming; empty is validated by validate_primaryadmin_password helper
      call :validate_primaryadmin_password
      if errorlevel 1 (
        call :log "[ERROR] primary admin password is empty or contains unsupported characters; only A-Z, a-z, 0-9, #, @, _ and - are allowed. Stage B registration will be skipped."
      ) else (
        set "L2C_HAS_PRIMARYADMIN_SECRET=1"
        call :log "[INFO] primary admin secret loaded from .primaryadmin.pw"
      )
    )
  )
) else (
  call :log "[INFO] primary admin secret content load skipped because FAILED=1 (earlier failure)."
)

REM If we are still not in FAILED, require that primary admin secret has been successfully loaded
if "%FAILED%"=="0" if not "%L2C_HAS_PRIMARYADMIN_SECRET%"=="1" (
  set "FAILED=1"
)

set "L2C_PRIMARYADMIN_PASSWORD="

REM Temporary logon policies
if "%FAILED%"=="0" if "%HAS_BOOTSTRAP_PW%"=="1" if "%L2C_BOOTSTRAP_PW_FORMAT_OK%"=="1" if "%L2C_HAS_PRIMARYADMIN_SECRET%"=="1" if "%L2C_BOOTSTRAP_PW_ACL_OK%"=="1" if "%L2C_PRIMARYADMIN_PW_ACL_OK%"=="1" (
  REM Temp logon relax, only if secret present
  call :l2c_temp_logon_tweaks
) else (
  call :log "[INFO] Skipping temp logon tweaks (gate FAILED=%FAILED%, HAS_BOOTSTRAP_PW=%HAS_BOOTSTRAP_PW%, L2C_BOOTSTRAP_PW_FORMAT_OK=%L2C_BOOTSTRAP_PW_FORMAT_OK%, L2C_HAS_PRIMARYADMIN_SECRET=%L2C_HAS_PRIMARYADMIN_SECRET%, L2C_BOOTSTRAP_PW_ACL_OK=%L2C_BOOTSTRAP_PW_ACL_OK%, L2C_PRIMARYADMIN_PW_ACL_OK=%L2C_PRIMARYADMIN_PW_ACL_OK%)."
)
reg add "%WL%" /v IgnoreShiftOverride /t REG_SZ /d 0 /f >nul 2>&1
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
  call :log "[ERROR] IgnoreShiftOverride set failed rc=%RC% key=%WL% name=IgnoreShiftOverride value=0"
  call :track_rc %RC%
  set "FAILED=1"
  set "STAGEB_NOT_SCHEDULED=1"
  goto :l2c_recovery_and_reboot
)

REM === [L2C] Schedule CreatePrimaryAdmin as SYSTEM/Highest/OnLogon; then prime Winlogon autologon ===
REM Autologon only if the bootstrap password is known and SEC-2 passed for both secrets
if "%FAILED%"=="0" if "%HAS_BOOTSTRAP_PW%"=="1" if "%L2C_BOOTSTRAP_PW_FORMAT_OK%"=="1" if "%L2C_HAS_PRIMARYADMIN_SECRET%"=="1" if "%L2C_BOOTSTRAP_PW_ACL_OK%"=="1" if "%L2C_PRIMARYADMIN_PW_ACL_OK%"=="1" (
  call :l2c_stageb_schedule_and_prime
) else (
  call :log "[WARN] Winlogon autologon not primed (gate FAILED=%FAILED%, HAS_BOOTSTRAP_PW=%HAS_BOOTSTRAP_PW%, L2C_BOOTSTRAP_PW_FORMAT_OK=%L2C_BOOTSTRAP_PW_FORMAT_OK%, L2C_HAS_PRIMARYADMIN_SECRET=%L2C_HAS_PRIMARYADMIN_SECRET%, L2C_BOOTSTRAP_PW_ACL_OK=%L2C_BOOTSTRAP_PW_ACL_OK%, L2C_PRIMARYADMIN_PW_ACL_OK=%L2C_PRIMARYADMIN_PW_ACL_OK%)"
  call :log "[INFO] Stage B registration skipped due to gate (FAILED=%FAILED%, HAS_BOOTSTRAP_PW=%HAS_BOOTSTRAP_PW%, L2C_BOOTSTRAP_PW_FORMAT_OK=%L2C_BOOTSTRAP_PW_FORMAT_OK%, L2C_HAS_PRIMARYADMIN_SECRET=%L2C_HAS_PRIMARYADMIN_SECRET%, L2C_BOOTSTRAP_PW_ACL_OK=%L2C_BOOTSTRAP_PW_ACL_OK%, L2C_PRIMARYADMIN_PW_ACL_OK=%L2C_PRIMARYADMIN_PW_ACL_OK%)."
  set "STAGEB_SKIPPED_GATE=1"
  set "STAGEB_NOT_SCHEDULED=1"
)

:l2c_recovery_and_reboot
REM === [L2C] Recovery gate (no extra registrations on failure) ===
if "%FAILED%"=="1" (
  call :log "[WARN] SetupComplete entered recovery mode; skipping extra registrations"
  call :log "[WARN] *** RECOVERY_MODE_ACTIVE OPERATOR_ACTION_REQUIRED ***"
  call :log "[WARN] Recovery active, operator action required. Teardown blocked; executor/bootstrap and secrets may be retained until manual resolution."
  call :log "[WARN] See README.md Recovery runbook."
)

:: ------------ mark reboot requirement via panther flag ------------
if "%ALWAYS_REBOOT_AFTER_FIRST_LOGON%"=="1" (
  call :log "[INFO] ALWAYS_REBOOT_AFTER_FIRST_LOGON=1 -> forcing reboot"
  set "REBOOT_FLAG_CONTENT=force-reboot"
  set "NEEDS_REBOOT=1"
  call :flag_reboot
)

call :log "[INFO] Evaluating reboot requirement"
if not "%NEEDS_REBOOT%"=="1" if exist "%REBOOT_FLAG%" set "NEEDS_REBOOT=1"

if "%NEEDS_REBOOT%"=="1" (
  call :log "[INFO] Reboot required"
  set "REBOOT_REQUESTED=1"
  call :flag_reboot
) else (
call :log "[INFO] No reboot required"
)

if "%NEEDS_REBOOT%"=="1" call :l2c_reboot_flag_warns

:l2c_final_rc
call :log "----- SetupComplete finished -----"

REM --- final RC calculation ---
set "FINAL_RC=0"
if defined L2C_FIRST_BAD_RC set "FINAL_RC=%L2C_FIRST_BAD_RC%"
if "%FINAL_RC%"=="0" if "%FAILED%"=="1" set "FINAL_RC=1"

REM if the final RC is not 0, roll back temporary logon policies
if not "%FINAL_RC%"=="0" (
  call :l2c_temp_logon_rollback
)

if "%FINAL_RC%"=="0" (
  if "%L2C_AUTOLOGON_DEGRADED%"=="1" (
    set "FINAL_RC=2"
    call :log "[FINAL] DEGRADED manual_login_required=%MANUAL_LOGIN_REQUIRED%"
  ) else (
    call :log "[FINAL] SUCCESS"
  )
) else (
  call :log "[FINAL] FAIL (FINAL_RC=%FINAL_RC%)"
)

call :log "[RC] returning %FINAL_RC%"
exit /b %FINAL_RC%

:winlogon_handle_default_password
REM Handle the result of setting Winlogon DefaultPassword.
REM Input: ERRORLEVEL from the PowerShell command.
REM Use the global WL and FAILED.

if errorlevel 1 goto :winlogon_defaultpassword_failed
set "RC=%ERRORLEVEL%"
call :track_rc %RC%

reg add "%WL%" /v AutoAdminLogon     /t REG_SZ    /d 1 /f >nul 2>&1
if errorlevel 1 goto :winlogon_autoadminlogon_failed

reg add "%WL%" /v ForceAutoLogon     /t REG_SZ    /d 1 /f >nul 2>&1
if errorlevel 1 goto :winlogon_forceautologon_failed

reg add "%WL%" /v AutoLogonCount     /t REG_DWORD /d 2 /f >nul 2>&1
if errorlevel 1 goto :winlogon_autologoncount_failed

call :log "[INFO] Winlogon autologon primed for 'bootstrap'"
call :log "[INFO] L2C_MARKER_WRITE_BEGIN key=HKLM\\SOFTWARE\\L2C name=AutologonPrimed value=1"
reg add "HKLM\SOFTWARE\L2C" /v AutologonPrimed /t REG_DWORD /d 1 /f >nul 2>&1
if errorlevel 1 goto :winlogon_marker_write_failed
set "L2C_AUTOLOGON_ARMED=1"
set "L2C_AUTOLOGON_DEGRADED=0"
call :log "[INFO] L2C_MARKER_WRITE_OK key=HKLM\\SOFTWARE\\L2C name=AutologonPrimed value=1"
exit /b 0

:winlogon_defaultpassword_failed
set "RC=%ERRORLEVEL%"
call :track_rc %RC%
set "FAILED=1"
call :log "[ERROR] Winlogon DefaultPassword setup failed (RC=%RC%)"
exit /b %RC%

:winlogon_autoadminlogon_failed
set "RC=%ERRORLEVEL%"
call :track_rc %RC%
set "FAILED=1"
call :log "[ERROR] Winlogon AutoAdminLogon setup failed (RC=%RC%)"
exit /b %RC%

:winlogon_forceautologon_failed
set "RC=%ERRORLEVEL%"
call :track_rc %RC%
set "FAILED=1"
call :log "[ERROR] Winlogon ForceAutoLogon setup failed (RC=%RC%)"
exit /b %RC%

:winlogon_autologoncount_failed
set "RC=%ERRORLEVEL%"
call :track_rc %RC%
set "FAILED=1"
call :log "[ERROR] Winlogon AutoLogonCount setup failed (RC=%RC%)"
exit /b %RC%

:winlogon_marker_write_failed
set "RC=%ERRORLEVEL%"
call :log "[ERROR] L2C_MARKER_WRITE_FAILED key=HKLM\\SOFTWARE\\L2C name=AutologonPrimed rc=%RC%"
call :log "[ERROR] L2C_DEGRADED_ENTERED manual_login_required=1"
set "MANUAL_LOGIN_REQUIRED=1"
call :winlogon_rollback_autologon
set "L2C_AUTOLOGON_ARMED=0"
set "L2C_AUTOLOGON_DEGRADED=1"
call :log "[INFO] L2C_TEMP_LOGON_TWEAKS_ROLLBACK_BEGIN DisableCAD=0 DevicePasswordLessBuildVersion=2"
reg add "%SYS%" /v DisableCAD /t REG_DWORD /d 0 /f >nul 2>&1
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" call :log "[WARN] L2C_TEMP_LOGON_TWEAKS_ROLLBACK_WARN rc=%RC%"
reg add "%NGC%" /v DevicePasswordLessBuildVersion /t REG_DWORD /d 2 /f >nul 2>&1
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" call :log "[WARN] L2C_TEMP_LOGON_TWEAKS_ROLLBACK_WARN rc=%RC%"
call :log "[INFO] L2C_TEMP_LOGON_TWEAKS_ROLLBACK_DONE"
exit /b 0

:l2c_stageb_schedule_and_prime
REM Schedule Stage B executor first, then prime Winlogon autologon only on success (atomicity).
REM [L2C] ACL boundary pre-check (non-admin tamper boundary): Scripts dir + Stage B script target
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass ^
  -File "%WINDIR%\Setup\Scripts\ValidateSecrets.ps1" ^
  -CheckAclBoundaryPreStageB >>"%LOG%" 2>&1
set "RC=%ERRORLEVEL%"

if "%RC%"=="4" (
  call :track_rc %RC%
  call :log "[ERROR] [ACLBOUNDARY] Pre-check validator internal error (rc=4); refusing to schedule Stage B"
  set "FAILED=1"
  set "STAGEB_NOT_SCHEDULED=1"
  exit /b 0
)

REM Fail closed on unexpected validator exit codes (treat as validator execution failure).
if not "%RC%"=="0" if not "%RC%"=="8" if not "%RC%"=="16" if not "%RC%"=="24" (
  call :track_rc %RC%
  call :log "[ERROR] [ACLBOUNDARY] Pre-check validator failed with unexpected rc=%RC%; refusing to schedule Stage B"
  set "FAILED=1"
  set "STAGEB_NOT_SCHEDULED=1"
  exit /b 0
)

set "ACL_UNSAFE=0"

set /a TMP=RC ^& 8
if not "%TMP%"=="0" (
  call :log "[ERROR] [ACLBOUNDARY] FAIL scripts_dir=%WINDIR%\Setup\Scripts rc=%RC%"
  icacls "%WINDIR%\Setup\Scripts" >>"%LOG%" 2>&1
  set "ACL_UNSAFE=1"
)

set /a TMP=RC ^& 16
if not "%TMP%"=="0" (
  call :log "[ERROR] [ACLBOUNDARY] FAIL stageb_script=%WINDIR%\Setup\Scripts\CreatePrimaryAdmin.ps1 rc=%RC%"
  icacls "%WINDIR%\Setup\Scripts\CreatePrimaryAdmin.ps1" >>"%LOG%" 2>&1
  set "ACL_UNSAFE=1"
)

if "%ACL_UNSAFE%"=="1" (
  call :track_rc %RC%
  set "FAILED=1"
  set "STAGEB_NOT_SCHEDULED=1"
  set "ACL_UNSAFE="
  set "TMP="
  exit /b 0
)

call :log "[ACLBOUNDARY] PASS scripts_dir=%WINDIR%\Setup\Scripts"
call :log "[ACLBOUNDARY] PASS stageb_script=%WINDIR%\Setup\Scripts\CreatePrimaryAdmin.ps1"
set "ACL_UNSAFE="
set "TMP="

REM [L2C] Harden task container ACL to prevent inheriting AU:FW from \Tasks (non-admin tamper boundary).
if not exist "%SystemRoot%\System32\Tasks\L2C" (
  mkdir "%SystemRoot%\System32\Tasks\L2C" >nul 2>&1
  if errorlevel 1 goto :l2c_taskdir_harden_failed_mkdir
)

REM Break inheritance and REMOVE inherited ACEs (language-neutral via SIDs), then remove risky principals.
icacls "%SystemRoot%\System32\Tasks\L2C" /inheritance:r >nul 2>&1
if errorlevel 1 goto :l2c_taskdir_harden_failed_inheritance_r
icacls "%SystemRoot%\System32\Tasks\L2C" /remove:g "*S-1-5-11" "*S-1-5-32-545" >nul 2>&1
if errorlevel 1 goto :l2c_taskdir_harden_failed_remove_g

REM Ensure SYSTEM and Administrators have FullControl explicitly.
icacls "%SystemRoot%\System32\Tasks\L2C" /grant:r "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-544:(OI)(CI)F" >nul 2>&1
if errorlevel 1 goto :l2c_taskdir_harden_failed_grant_r

call :log "[ACLBOUNDARY] Hardened task_dir=%SystemRoot%\System32\Tasks\L2C (inheritance removed; AU/Users removed; SYSTEM/Admins granted F)"

schtasks /Create /TN "\L2C\CreatePrimaryAdmin" ^
  /TR "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"%WINDIR%\Setup\Scripts\CreatePrimaryAdmin.ps1\"" ^
  /SC ONLOGON /RU SYSTEM /RL HIGHEST /F >nul 2>&1
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
  call :track_rc %RC%
  call :log "[ERROR] Failed to create scheduled task \L2C\CreatePrimaryAdmin (rc=%RC%)"
  set "FAILED=1"
  set "STAGEB_NOT_SCHEDULED=1"
  exit /b 0
) else (
  call :log "[INFO] Scheduled \L2C\CreatePrimaryAdmin (SYSTEM, Highest, OnLogon)"
)

REM [L2C] ACL boundary post-check (non-admin tamper boundary): task definition file + parent dir
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass ^
  -File "%WINDIR%\Setup\Scripts\ValidateSecrets.ps1" ^
  -CheckAclBoundaryPostStageB >>"%LOG%" 2>&1
set "RC=%ERRORLEVEL%"

if "%RC%"=="4" (
  call :track_rc %RC%
  call :log "[ERROR] [ACLBOUNDARY] Post-check validator internal error (rc=4); deleting task and refusing to prime Winlogon"
  call :aclboundary_task_delete_and_log
  set "FAILED=1"
  set "STAGEB_NOT_SCHEDULED=1"
  set "TMP="
  exit /b 0
)

REM Fail closed on unexpected validator exit codes (treat as validator execution failure).
if not "%RC%"=="0" if not "%RC%"=="32" if not "%RC%"=="64" if not "%RC%"=="96" (
  call :track_rc %RC%
  call :log "[ERROR] [ACLBOUNDARY] Post-check validator failed with unexpected rc=%RC%; deleting task and refusing to prime Winlogon"
  call :aclboundary_task_delete_and_log
  set "FAILED=1"
  set "STAGEB_NOT_SCHEDULED=1"
  set "TMP="
  exit /b 0
)

set "ACL_UNSAFE=0"

set /a TMP=RC ^& 32
if not "%TMP%"=="0" (
  call :log "[ERROR] [ACLBOUNDARY] FAIL task_def=%SystemRoot%\System32\Tasks\L2C\CreatePrimaryAdmin rc=%RC%"
  icacls "%SystemRoot%\System32\Tasks\L2C\CreatePrimaryAdmin" >>"%LOG%" 2>&1
  set "ACL_UNSAFE=1"
)

set /a TMP=RC ^& 64
if not "%TMP%"=="0" (
  call :log "[ERROR] [ACLBOUNDARY] FAIL task_dir=%SystemRoot%\System32\Tasks\L2C rc=%RC%"
  icacls "%SystemRoot%\System32\Tasks\L2C" >>"%LOG%" 2>&1
  set "ACL_UNSAFE=1"
)

if "%ACL_UNSAFE%"=="1" (
  call :track_rc %RC%
  call :log "[ERROR] [ACLBOUNDARY] Post-check unsafe (rc=%RC%); deleting task and refusing to prime Winlogon"
  call :aclboundary_task_delete_and_log
  set "FAILED=1"
  set "STAGEB_NOT_SCHEDULED=1"
  set "ACL_UNSAFE="
  set "TMP="
  exit /b 0
)

call :log "[ACLBOUNDARY] PASS task_def=%SystemRoot%\System32\Tasks\L2C\CreatePrimaryAdmin"
call :log "[ACLBOUNDARY] PASS task_dir=%SystemRoot%\System32\Tasks\L2C"
set "ACL_UNSAFE="
set "TMP="

call :l2c_prime_winlogon_autologon
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
  call :l2c_autologon_prime_failed_after_task %RC%
)
call :log "[INFO] L2C_AUTOLOGON_STATUS armed=%L2C_AUTOLOGON_ARMED% degraded=%L2C_AUTOLOGON_DEGRADED% marker=HKLM\SOFTWARE\L2C\AutologonPrimed"
exit /b 0

:l2c_taskdir_harden_failed_mkdir
set "RC=%ERRORLEVEL%"
call :log "[ERROR] ACLBOUNDARY_TASKDIR_HARDEN_FAILED rc=%RC% step=mkdir dir=%SystemRoot%\System32\Tasks\L2C"
call :track_rc %RC%
set "FAILED=1"
set "STAGEB_NOT_SCHEDULED=1"
exit /b %RC%

:l2c_taskdir_harden_failed_inheritance_r
set "RC=%ERRORLEVEL%"
call :log "[ERROR] ACLBOUNDARY_TASKDIR_HARDEN_FAILED rc=%RC% step=inheritance_r dir=%SystemRoot%\System32\Tasks\L2C"
call :track_rc %RC%
set "FAILED=1"
set "STAGEB_NOT_SCHEDULED=1"
exit /b %RC%

:l2c_taskdir_harden_failed_remove_g
set "RC=%ERRORLEVEL%"
call :log "[ERROR] ACLBOUNDARY_TASKDIR_HARDEN_FAILED rc=%RC% step=remove_g dir=%SystemRoot%\System32\Tasks\L2C"
call :track_rc %RC%
set "FAILED=1"
set "STAGEB_NOT_SCHEDULED=1"
exit /b %RC%

:l2c_taskdir_harden_failed_grant_r
set "RC=%ERRORLEVEL%"
call :log "[ERROR] ACLBOUNDARY_TASKDIR_HARDEN_FAILED rc=%RC% step=grant_r dir=%SystemRoot%\System32\Tasks\L2C"
call :track_rc %RC%
set "FAILED=1"
set "STAGEB_NOT_SCHEDULED=1"
exit /b %RC%

:l2c_prime_winlogon_autologon
REM Prime Winlogon autologon. Assumes Stage B task already exists.
reg add "%WL%" /v DefaultUserName    /t REG_SZ    /d bootstrap /f >nul 2>&1
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
  call :track_rc %RC%
  exit /b %RC%
)

reg add "%WL%" /v DefaultDomainName  /t REG_SZ    /d "%COMPUTERNAME%" /f >nul 2>&1
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
  call :track_rc %RC%
  exit /b %RC%
)

"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "try {$pwPath = Join-Path $env:WINDIR 'Setup\Scripts\.bootstrap.pw'; $pw = Get-Content -LiteralPath $pwPath -TotalCount 1 -ErrorAction Stop; Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name 'DefaultPassword' -Value $pw; exit 0} catch {exit 1}" >nul 2>&1
call :winlogon_handle_default_password
exit /b %ERRORLEVEL%

:l2c_autologon_prime_failed_after_task
REM Autologon priming failed after Stage B task creation: roll back Winlogon and remove executor (best-effort).
set "RC=%~1"
call :log "[ERROR] Winlogon autologon priming failed after scheduling Stage B; rolling back Winlogon state and deleting \L2C\CreatePrimaryAdmin (rc=%RC%)"
set "FAILED=1"
set "STAGEB_NOT_SCHEDULED=1"
call :winlogon_rollback_autologon
call :stageb_task_delete_best_effort
exit /b 0

:winlogon_rollback_autologon
REM Best-effort rollback of Winlogon autologon state (clears password/user/domain and disables autologon).
REM Use the global WL.

reg add "%WL%" /v AutoAdminLogon /t REG_SZ /d 0 /f >nul 2>&1
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
  call :track_rc %RC%
  call :log "[WARN] Failed to set Winlogon AutoAdminLogon=0 (RC=%RC%)"
)

reg add "%WL%" /v ForceAutoLogon /t REG_SZ /d 0 /f >nul 2>&1
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
  call :track_rc %RC%
  call :log "[WARN] Failed to set Winlogon ForceAutoLogon=0 (RC=%RC%)"
)

reg add "%WL%" /v AutoLogonCount /t REG_DWORD /d 0 /f >nul 2>&1
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
  call :track_rc %RC%
  call :log "[WARN] Failed to set Winlogon AutoLogonCount=0 (RC=%RC%)"
)

reg delete "%WL%" /v DefaultPassword /f >nul 2>&1
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" if not "%RC%"=="2" (
  call :track_rc %RC%
  call :log "[ERROR] Failed to delete Winlogon DefaultPassword (RC=%RC%)"
)

reg delete "%WL%" /v DefaultUserName /f >nul 2>&1
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" if not "%RC%"=="2" (
  call :track_rc %RC%
  call :log "[WARN] Failed to delete Winlogon DefaultUserName (RC=%RC%)"
)

reg delete "%WL%" /v DefaultDomainName /f >nul 2>&1
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" if not "%RC%"=="2" (
  call :track_rc %RC%
  call :log "[WARN] Failed to delete Winlogon DefaultDomainName (RC=%RC%)"
)

call :log "[INFO] L2C_MARKER_DELETE_ATTEMPT key=HKLM\\SOFTWARE\\L2C name=AutologonPrimed"
reg delete "HKLM\SOFTWARE\L2C" /v AutologonPrimed /f >nul 2>&1
set "RC=%ERRORLEVEL%"
if "%RC%"=="0" (
  call :log "[INFO] L2C_MARKER_DELETE_OK key=HKLM\\SOFTWARE\\L2C name=AutologonPrimed"
) else if "%RC%"=="2" (
  call :log "[INFO] L2C_MARKER_DELETE_OK key=HKLM\\SOFTWARE\\L2C name=AutologonPrimed"
) else (
  call :track_rc %RC%
  call :log "[WARN] L2C_MARKER_DELETE_FAILED key=HKLM\\SOFTWARE\\L2C name=AutologonPrimed rc=%RC%"
)

exit /b 0

:aclboundary_task_delete_and_log
REM Best-effort delete of the Stage B executor task with deterministic RC logging.
REM Does not use delayed expansion. Always returns 0 to keep callers fail-closed elsewhere.

schtasks /Delete /TN "\L2C\CreatePrimaryAdmin" /F >nul 2>&1
set "RC_DEL=%ERRORLEVEL%"

if "%RC_DEL%"=="0" (
  call :log "[INFO] [ACLBOUNDARY] Task delete rc=%RC_DEL%"
) else (
  call :track_rc %RC_DEL%
  call :log "[WARN] [ACLBOUNDARY] Task delete rc=%RC_DEL%"
)

set "RC_DEL="
exit /b 0

:stageb_task_delete_best_effort
schtasks /Delete /TN "\L2C\CreatePrimaryAdmin" /F >nul 2>&1
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
  call :track_rc %RC%
  call :log "[WARN] Failed to delete scheduled task \L2C\CreatePrimaryAdmin (rc=%RC%)"
)
exit /b 0

:edge_remove
setlocal EnableExtensions
call :log "[SECTION] Early Edge browser removal"
set "EDGE_SETUP="
set "EDGE_SETUP_X86="
set "EDGE_SETUP_X64="
set "EDGE_RC=0"
set "EDGE_EXE_PRESENT=0"
set "EDGE_UNINSTALL_KEY_PRESENT=0"
set "EDGE_WEBVIEW2_UNINSTALL_PRESENT=0"
set "EDGE_UNINSTALL_SIGNAL_KNOWN=1"
set "EDGE_UNINSTALL_QUERY_RC=0"
set "EDGE_TASK=\Microsoft\EdgeUpdate\MicrosoftEdgeUpdateTaskMachineCore"
set "EDGE_VERIFY_ATTEMPT=1"

call :log "[INFO] EdgeUpdate hardening begin (best-effort)."

sc query edgeupdate >nul 2>&1
if errorlevel 1 (
  call :log "[INFO] EdgeUpdate service edgeupdate not present; skip disable."
) else (
  call :svc_disable "edgeupdate"
  "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "try { $s = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\edgeupdate' -Name Start -ErrorAction Stop).Start; if ($s -eq 4) { exit 0 } else { exit 1 } } catch { exit 2 }" >nul 2>&1
  if errorlevel 2 (
    call :log "[WARN] EdgeUpdate service edgeupdate disable verification failed (cannot read Start); continuing."
  ) else if errorlevel 1 (
    call :log "[WARN] EdgeUpdate service edgeupdate disable may have failed (Start!=4); continuing."
  ) else (
    call :log "[INFO] EdgeUpdate service edgeupdate disabled (best-effort)."
  )
)

sc query edgeupdatem >nul 2>&1
if errorlevel 1 (
  call :log "[INFO] EdgeUpdate service edgeupdatem not present; skip disable."
) else (
  call :svc_disable "edgeupdatem"
  "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "try { $s = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\edgeupdatem' -Name Start -ErrorAction Stop).Start; if ($s -eq 4) { exit 0 } else { exit 1 } } catch { exit 2 }" >nul 2>&1
  if errorlevel 2 (
    call :log "[WARN] EdgeUpdate service edgeupdatem disable verification failed (cannot read Start); continuing."
  ) else if errorlevel 1 (
    call :log "[WARN] EdgeUpdate service edgeupdatem disable may have failed (Start!=4); continuing."
  ) else (
    call :log "[INFO] EdgeUpdate service edgeupdatem disabled (best-effort)."
  )
)

schtasks /Query /TN "%EDGE_TASK%" >nul 2>&1
if errorlevel 1 (
  call :log "[INFO] EdgeUpdate task not present: %EDGE_TASK%"
) else (
  call :task_disable "%EDGE_TASK%"
  schtasks /Query /TN "%EDGE_TASK%" /XML | findstr /I /C:"<Enabled>false</Enabled>" >nul 2>&1
  if errorlevel 1 (
    call :log "[WARN] EdgeUpdate task disable may have failed: %EDGE_TASK%; continuing."
  ) else (
    call :log "[INFO] EdgeUpdate task disabled: %EDGE_TASK%"
  )
)

set "EDGE_TASK=\Microsoft\EdgeUpdate\MicrosoftEdgeUpdateTaskMachineUA"
schtasks /Query /TN "%EDGE_TASK%" >nul 2>&1
if errorlevel 1 (
  call :log "[INFO] EdgeUpdate task not present: %EDGE_TASK%"
) else (
  call :task_disable "%EDGE_TASK%"
  schtasks /Query /TN "%EDGE_TASK%" /XML | findstr /I /C:"<Enabled>false</Enabled>" >nul 2>&1
  if errorlevel 1 (
    call :log "[WARN] EdgeUpdate task disable may have failed: %EDGE_TASK%; continuing."
  ) else (
    call :log "[INFO] EdgeUpdate task disabled: %EDGE_TASK%"
  )
)
set "EDGE_TASK="

if defined ProgramFiles(x86) (
  for /f "delims=" %%V in ('dir /b /ad /o-n "%ProgramFiles(x86)%\Microsoft\Edge\Application" 2^>nul') do (
    if not defined EDGE_SETUP_X86 if exist "%ProgramFiles(x86)%\Microsoft\Edge\Application\%%V\Installer\setup.exe" set "EDGE_SETUP_X86=%ProgramFiles(x86)%\Microsoft\Edge\Application\%%V\Installer\setup.exe"
  )
)

if not defined EDGE_SETUP_X86 if defined ProgramFiles (
  for /f "delims=" %%V in ('dir /b /ad /o-n "%ProgramFiles%\Microsoft\Edge\Application" 2^>nul') do (
    if not defined EDGE_SETUP_X64 if exist "%ProgramFiles%\Microsoft\Edge\Application\%%V\Installer\setup.exe" set "EDGE_SETUP_X64=%ProgramFiles%\Microsoft\Edge\Application\%%V\Installer\setup.exe"
  )
)

if defined EDGE_SETUP_X86 (
  set "EDGE_SETUP=%EDGE_SETUP_X86%"
) else if defined EDGE_SETUP_X64 (
  set "EDGE_SETUP=%EDGE_SETUP_X64%"
)

if defined EDGE_SETUP (
  call :log "[INFO] Edge setup.exe selected: %EDGE_SETUP%"
  call :log "[INFO] Running Edge uninstall with wait semantics."
  start "" /wait "%EDGE_SETUP%" --uninstall --system-level --force-uninstall >nul 2>&1
  set "EDGE_RC=%ERRORLEVEL%"
  call :log "[INFO] Edge uninstall RC=%EDGE_RC%"
  if not "%EDGE_RC%"=="0" (
    call :log "[WARN] Edge browser removal returned RC=%EDGE_RC%; continuing (best-effort)."
  )
) else (
  call :log "[WARN] Edge setup.exe not found under Program Files paths; skipping uninstall step."
)

:edge_verify_retry
set "EDGE_EXE_PRESENT=0"
if defined ProgramFiles(x86) (
  if exist "%ProgramFiles(x86)%\Microsoft\Edge\Application\msedge.exe" (
    set "EDGE_EXE_PRESENT=1"
    call :log "[INFO] Edge verification: msedge.exe still present at %ProgramFiles(x86)%\Microsoft\Edge\Application\msedge.exe (attempt %EDGE_VERIFY_ATTEMPT%/3)."
  ) else (
    call :log "[INFO] Edge verification: msedge.exe absent at %ProgramFiles(x86)%\Microsoft\Edge\Application\msedge.exe"
  )
) else (
  call :log "[INFO] Edge verification: ProgramFiles(x86) is undefined; x86 path check skipped."
)

if defined ProgramFiles (
  if exist "%ProgramFiles%\Microsoft\Edge\Application\msedge.exe" (
    set "EDGE_EXE_PRESENT=1"
    call :log "[INFO] Edge verification: msedge.exe still present at %ProgramFiles%\Microsoft\Edge\Application\msedge.exe (attempt %EDGE_VERIFY_ATTEMPT%/3)."
  ) else (
    call :log "[INFO] Edge verification: msedge.exe absent at %ProgramFiles%\Microsoft\Edge\Application\msedge.exe"
  )
) else (
  call :log "[INFO] Edge verification: ProgramFiles is undefined; x64 path check skipped."
)

if "%EDGE_EXE_PRESENT%"=="0" goto :edge_verify_done
if "%EDGE_VERIFY_ATTEMPT%"=="3" goto :edge_verify_done
call :log "[INFO] Edge verification retry pending (attempt %EDGE_VERIFY_ATTEMPT%/3); waiting 2 seconds."
timeout /t 2 /nobreak >nul 2>&1
set /a EDGE_VERIFY_ATTEMPT+=1 >nul 2>&1
goto :edge_verify_retry

:edge_verify_done
if "%EDGE_EXE_PRESENT%"=="0" if not "%EDGE_VERIFY_ATTEMPT%"=="1" call :log "[INFO] Edge verification passed after retry attempt %EDGE_VERIFY_ATTEMPT%."

"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$browser=$false;$wv2=$false;$paths=@('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*');foreach($p in $paths){$items=Get-ItemProperty -Path $p -ErrorAction SilentlyContinue;foreach($i in $items){if($i.DisplayName -eq 'Microsoft Edge'){$browser=$true};if($i.DisplayName -eq 'Microsoft Edge WebView2 Runtime'){$wv2=$true}}};if($browser -and $wv2){exit 12};if($browser){exit 10};if($wv2){exit 11};exit 0" >nul 2>&1
set "EDGE_UNINSTALL_QUERY_RC=%ERRORLEVEL%"
if "%EDGE_UNINSTALL_QUERY_RC%"=="10" set "EDGE_UNINSTALL_KEY_PRESENT=1"
if "%EDGE_UNINSTALL_QUERY_RC%"=="11" set "EDGE_WEBVIEW2_UNINSTALL_PRESENT=1"
if "%EDGE_UNINSTALL_QUERY_RC%"=="12" (
  set "EDGE_UNINSTALL_KEY_PRESENT=1"
  set "EDGE_WEBVIEW2_UNINSTALL_PRESENT=1"
)
if not "%EDGE_UNINSTALL_QUERY_RC%"=="0" if not "%EDGE_UNINSTALL_QUERY_RC%"=="10" if not "%EDGE_UNINSTALL_QUERY_RC%"=="11" if not "%EDGE_UNINSTALL_QUERY_RC%"=="12" (
  set "EDGE_UNINSTALL_SIGNAL_KNOWN=0"
  call :log "[WARN] Edge uninstall registry signal: exact-match query failed (RC=%EDGE_UNINSTALL_QUERY_RC%); signal=unknown, continuing (informational only)."
)

if "%EDGE_UNINSTALL_SIGNAL_KNOWN%"=="1" (
  if "%EDGE_UNINSTALL_KEY_PRESENT%"=="1" (
    call :log "[INFO] Edge uninstall registry signal: Browser uninstall entry present (DisplayName exact match: Microsoft Edge) (informational only)."
  ) else (
    call :log "[INFO] Edge uninstall registry signal: Browser uninstall entry absent (DisplayName exact match: Microsoft Edge) (informational only)."
  )
  if "%EDGE_WEBVIEW2_UNINSTALL_PRESENT%"=="1" call :log "[INFO] Edge uninstall registry signal: WebView2 uninstall entry present and ignored for browser-presence signal (informational only)."
) else (
  call :log "[INFO] Edge uninstall registry signal: unknown (informational only)."
)

if "%EDGE_EXE_PRESENT%"=="0" (
  call :log "[INFO] Edge removal verification result: PASS (msedge.exe absent)."
) else (
  call :log "[WARN] Edge removal verification result: FAIL after %EDGE_VERIFY_ATTEMPT% attempts (msedge.exe still present); continuing (best-effort)."
)

endlocal & exit /b 0

REM ===== Helpers (Telemetry hardening) =====
:svc_disable
REM Usage: call :svc_disable "ServiceName"
set "_svc=%~1"
sc query "%_svc%" >nul 2>&1 || goto :svc_done
sc stop  "%_svc%" >nul 2>&1
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" call :log "[WARN] SERVICE_STOP_FAILED rc=%RC% service=%_svc%"
sc config "%_svc%" start= disabled >nul 2>&1
set "RC=%ERRORLEVEL%"
if "%RC%"=="0" (
  call :log "[OK] Service ""%_svc%"" -> Disabled"
) else (
  call :log "[WARN] SERVICE_DISABLE_FAILED rc=%RC% service=%_svc%"
)

:svc_done
set "_svc="
set "RC="
exit /b 0

:task_disable
REM Usage: call :task_disable "\Path\To\Task"
schtasks /Query /TN "%~1" >nul 2>&1 || goto :task_done
schtasks /Change /TN "%~1" /Disable >nul 2>&1
set "RC=%ERRORLEVEL%"
if "%RC%"=="0" (
  call :log "[OK] Task ""%~1"" -> Disabled"
) else (
  call :log "[WARN] TASK_DISABLE_FAILED rc=%RC% task=%~1"
)

:task_done
set "RC="
exit /b 0

:after_telemetry_hardening
:ts
  for /f %%# in ('"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -Command "Get-Date -Format o" 2^>nul') do (
    set "TS=%%#"
    goto :eof
  )
  set "TS=%DATE% %TIME%"
goto :eof

:fw_block_diagtrack
setlocal EnableExtensions
set "RULE=Block Telemetry Service (DiagTrack)"
call :log "[STEP] Ensure firewall rule: %RULE%"
REM check if rule exists
netsh advfirewall firewall show rule name="%RULE%" >nul 2>&1
if errorlevel 1 (
  netsh advfirewall firewall add rule name="%RULE%" dir=out action=block program="%SystemRoot%\System32\svchost.exe" service=diagtrack enable=yes profile=any >nul 2>&1
  if errorlevel 1 goto :fw_block_diagtrack_add_failed
  endlocal
  call :log "[OK] Firewall rule added: %RULE%"
  exit /b 0
) else (
  endlocal
  call :log "[OK] Firewall rule already present: %RULE%"
  exit /b 0
)

:fw_block_diagtrack_add_failed
set "RC=%ERRORLEVEL%"
endlocal & set "RC=%RC%"
call :log "[ERROR] Failed to add firewall rule (%RC%)."
exit /b %RC%

:master_log_warn_reboot_flag_no_executor
set "MASTER_LOG_PATH="
for /f %%G in ('"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -Command "$p = Join-Path $env:ProgramData ('l2c_master_{0:yyyyMMdd_HHmmss}.log' -f (Get-Date)); Write-Output $p" 2^>nul') do set "MASTER_LOG_PATH=%%G"
if not defined MASTER_LOG_PATH exit /b 0
if not exist "%ProgramData%" mkdir "%ProgramData%" >nul 2>&1
set "MASTER_LOG_TS="
for /f %%G in ('"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -Command "[DateTime]::UtcNow.ToString('o')" 2^>nul') do set "MASTER_LOG_TS=%%G"
if not defined MASTER_LOG_TS exit /b 0
>> "%MASTER_LOG_PATH%" echo [%MASTER_LOG_TS%] WARN_REBOOT_FLAG_NO_EXECUTOR Reboot required, but Stage B executor task is unavailable, automatic reboot will NOT happen. marker=%REBOOT_FLAG% (value=%REBOOT_FLAG_CONTENT%). executor_task=\L2C\CreatePrimaryAdmin (skipped_gate=%STAGEB_SKIPPED_GATE% not_scheduled=%STAGEB_NOT_SCHEDULED%). Manual reboot required after fixing gate or restoring Stage B task registration, then rerun pipeline.
exit /b 0

:l2c_reboot_flag_warns
if not "%NEEDS_REBOOT%"=="1" exit /b 0

if "%REBOOT_FLAG_SIGNAL_OK%"=="1" if "%REBOOT_REQUESTED%"=="1" if "%STAGEB_NOT_SCHEDULED%"=="1" if not "%WARN_REBOOT_FLAG_NO_EXECUTOR_EMITTED%"=="1" (
  call :log "[WARN] WARN_REBOOT_FLAG_NO_EXECUTOR Reboot required, but Stage B executor task is unavailable, automatic reboot will NOT happen. marker=%REBOOT_FLAG% (value=%REBOOT_FLAG_CONTENT%). executor_task=\L2C\CreatePrimaryAdmin (skipped_gate=%STAGEB_SKIPPED_GATE% not_scheduled=%STAGEB_NOT_SCHEDULED%). Manual reboot required after fixing gate or restoring Stage B task registration, then rerun pipeline."
  call :master_log_warn_reboot_flag_no_executor
  if defined MASTER_LOG_PATH call :log "[WARN] WARN_REBOOT_FLAG_NO_EXECUTOR master_log=%MASTER_LOG_PATH%"
  set "WARN_REBOOT_FLAG_NO_EXECUTOR_EMITTED=1"
)
if "%REBOOT_FLAG_SIGNAL_OK%"=="1" if "%L2C_AUTOLOGON_DEGRADED%"=="1" if not "%L2C_AUTOLOGON_ARMED%"=="1" (
  call :log "[WARN] WARN_REBOOT_FLAG_NO_AUTOLOGON Reboot required, but autologon is not armed (degraded=1); Stage B will not run until manual login. marker=%REBOOT_FLAG% (value=%REBOOT_FLAG_CONTENT%). executor_task=\\L2C\\CreatePrimaryAdmin."
)
exit /b 0

:flag_reboot
set "REBOOT_REQUESTED=1"
set "REBOOT_FLAG_SIGNAL_OK=0"
set "REBOOT_FLAG_WRITE_RC="
set "REBOOT_FLAG_READ_RC="
set "REBOOT_FLAG_REASON="
set "REBOOT_FLAG_OBSERVED_CLASS="
set "REBOOT_FLAG_OBSERVED="

call :log "[INFO] REBOOT_FLAG_SIGNAL_BEGIN marker=%REBOOT_FLAG% expected=%REBOOT_FLAG_CONTENT%"

REM Guard: expected content must be defined
if not defined REBOOT_FLAG_CONTENT (
  set "REBOOT_FLAG_REASON=content_undefined"
  set "REBOOT_FLAG_OBSERVED_CLASS=unset"
  goto :reboot_flag_fail
)

REM Fast-path: already correct and readable
if not exist "%REBOOT_FLAG%" goto :reboot_flag_write_attempt

REM Directory detection (NUL-trick is unreliable in this environment)
dir /ad "%REBOOT_FLAG%" 2>nul | find "<DIR>" >nul
if not errorlevel 1 (
  set "REBOOT_FLAG_REASON=directory"
  set "REBOOT_FLAG_OBSERVED_CLASS=directory"
  goto :reboot_flag_fail
)

set "REBOOT_FLAG_OBSERVED="
call :reboot_flag_read_firstline_checked
if "%REBOOT_FLAG_READ_IOERR%"=="1" goto :reboot_flag_fast_read_failed
if not "%REBOOT_FLAG_READ_RC%"=="0" goto :reboot_flag_fast_read_failed
goto :reboot_flag_read_ok
:reboot_flag_fast_read_failed
set "REBOOT_FLAG_REASON=read_failed"
set "REBOOT_FLAG_OBSERVED_CLASS=unreadable"
goto :reboot_flag_fail
:reboot_flag_read_ok
if /I not "%REBOOT_FLAG_OBSERVED%"=="%REBOOT_FLAG_CONTENT%" goto :reboot_flag_write_attempt

set "REBOOT_FLAG_SIGNAL_OK=1"
call :log "[INFO] REBOOT_FLAG_SIGNAL_OK already_present=1 marker=%REBOOT_FLAG% value=%REBOOT_FLAG_CONTENT%"
exit /b 0

:reboot_flag_write_attempt

REM Preflight: if marker path is a directory, fail explicitly before any write/read
dir /ad "%REBOOT_FLAG%" 2>nul | find "<DIR>" >nul
if not errorlevel 1 (
  set "REBOOT_FLAG_REASON=directory"
  set "REBOOT_FLAG_OBSERVED_CLASS=directory"
  set "REBOOT_FLAG_WRITE_RC="
  set "REBOOT_FLAG_READ_RC="
  goto :reboot_flag_fail
)

REM Write attempts (write_rc is diagnostic-only)
REM IMPORTANT: Avoid multi-line (...) blocks here. cmd.exe expands variables at parse-time inside blocks,
REM which can corrupt retry logic without delayed expansion (forbidden).

REM Attempt #1
call :reboot_flag_write_once
call :reboot_flag_verify_expected_after_write
if "%REBOOT_FLAG_VERIFY_HARDFAIL%"=="1" goto :reboot_flag_fail
if "%REBOOT_FLAG_VERIFY_OK%"=="1" goto :reboot_flag_write_ok
call :log "[WARN] REBOOT_FLAG_WRITE_RETRY attempt=1 marker=%REBOOT_FLAG% write_rc=%REBOOT_FLAG_WRITE_RC%"

REM Retry #2
call :reboot_flag_write_once
call :reboot_flag_verify_expected_after_write
if "%REBOOT_FLAG_VERIFY_HARDFAIL%"=="1" goto :reboot_flag_fail
if "%REBOOT_FLAG_VERIFY_OK%"=="1" echo DIAG_WRITE_RETRY_OK attempt=2 marker=%REBOOT_FLAG%
if "%REBOOT_FLAG_VERIFY_OK%"=="1" goto :reboot_flag_write_ok
call :log "[WARN] REBOOT_FLAG_WRITE_RETRY attempt=2 marker=%REBOOT_FLAG% write_rc=%REBOOT_FLAG_WRITE_RC%"

REM Retry #3
call :reboot_flag_write_once
call :reboot_flag_verify_expected_after_write
if "%REBOOT_FLAG_VERIFY_HARDFAIL%"=="1" goto :reboot_flag_fail
if "%REBOOT_FLAG_VERIFY_OK%"=="1" echo DIAG_WRITE_RETRY_OK attempt=3 marker=%REBOOT_FLAG%
if "%REBOOT_FLAG_VERIFY_OK%"=="1" goto :reboot_flag_write_ok

set "REBOOT_FLAG_WRITE_RC_LOG=%REBOOT_FLAG_WRITE_RC%"
if "%REBOOT_FLAG_WRITE_RC_LOG%"=="0" set "REBOOT_FLAG_WRITE_RC_LOG="
call :log "[ERROR] REBOOT_FLAG_WRITE_FAILED marker=%REBOOT_FLAG% expected=%REBOOT_FLAG_CONTENT% write_rc=%REBOOT_FLAG_WRITE_RC_LOG%"
cmd.exe /d /c "dir /a ""%REBOOT_FLAG%"" 2>&1"
cmd.exe /d /c "attrib ""%REBOOT_FLAG%"" 2>&1"
cmd.exe /d /c "icacls ""%REBOOT_FLAG%"" 2>&1"
cmd.exe /d /c "icacls ""%SystemRoot%\Panther"" 2>&1"
set "REBOOT_FLAG_REASON=write_failed"
set "REBOOT_FLAG_OBSERVED_CLASS=unwritable"
goto :reboot_flag_fail

:reboot_flag_write_ok
set "REBOOT_FLAG_SIGNAL_OK=1"
call :log "[INFO] REBOOT_FLAG_SIGNAL_OK marker=%REBOOT_FLAG% expected=%REBOOT_FLAG_CONTENT% write_rc=%REBOOT_FLAG_WRITE_RC% read_rc=%REBOOT_FLAG_READ_RC%"
exit /b 0

:reboot_flag_write_once
REM Write to marker. Do not trust ERRORLEVEL from redirection as authoritative.
REM Auditor-confirmed: redirection failures can be masked (stderr only, ERRORLEVEL=0), and same-line 2> capture
REM can miss errors when < or > redirection fails (redirection ordering). Classification is verify-driven.
%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$p=$env:REBOOT_FLAG;$c=$env:REBOOT_FLAG_CONTENT;[System.IO.File]::WriteAllText($p,$c + [char]13 + [char]10,[System.Text.Encoding]::ASCII)" 1>nul 2>nul
set "REBOOT_FLAG_WRITE_RC=%ERRORLEVEL%"
exit /b 0

:reboot_flag_read_firstline_checked
REM Read first line from marker. Do not trust ERRORLEVEL from set /p + < redirection as authoritative.
REM Auditor-confirmed: same-line 2> capture can miss errors when < redirection fails (redirection ordering).
REM Avoid < redirection entirely by using TYPE in a child cmd.exe process; capture stderr at the process boundary.
set "REBOOT_FLAG_READ_IOERR=0"
set "REBOOT_FLAG_IOERR_SZ=0"
set "REBOOT_FLAG_IOERR_OUT=%TEMP%\l2c_reboot_flag_read_%RANDOM%_%RANDOM%.out"
set "REBOOT_FLAG_IOERR_FILE=%TEMP%\l2c_reboot_flag_read_%RANDOM%_%RANDOM%.err"
del /q "%REBOOT_FLAG_IOERR_OUT%" >nul 2>&1
del /q "%REBOOT_FLAG_IOERR_FILE%" >nul 2>&1
set "REBOOT_FLAG_OBSERVED="
cmd.exe /d /q /c "type ""%REBOOT_FLAG%""" 1>"%REBOOT_FLAG_IOERR_OUT%" 2>"%REBOOT_FLAG_IOERR_FILE%"
set "REBOOT_FLAG_READ_RC=%ERRORLEVEL%"
if not exist "%REBOOT_FLAG_IOERR_OUT%" set "REBOOT_FLAG_READ_IOERR=1"
if not exist "%REBOOT_FLAG_IOERR_FILE%" set "REBOOT_FLAG_READ_IOERR=1"
if exist "%REBOOT_FLAG_IOERR_FILE%" for %%G in ("%REBOOT_FLAG_IOERR_FILE%") do set "REBOOT_FLAG_IOERR_SZ=%%~zG"
if exist "%REBOOT_FLAG_IOERR_OUT%" set /p REBOOT_FLAG_OBSERVED=<"%REBOOT_FLAG_IOERR_OUT%"
del /q "%REBOOT_FLAG_IOERR_OUT%" >nul 2>&1
del /q "%REBOOT_FLAG_IOERR_FILE%" >nul 2>&1
if not "%REBOOT_FLAG_IOERR_SZ%"=="0" set "REBOOT_FLAG_READ_IOERR=1"
exit /b 0

:reboot_flag_verify_expected_after_write
REM Verify marker contains expected content (authoritative). Do not rely on ERRORLEVEL from redirection alone.
set "REBOOT_FLAG_VERIFY_OK=0"
set "REBOOT_FLAG_VERIFY_HARDFAIL=0"
dir /ad "%REBOOT_FLAG%" 2>nul | find "<DIR>" >nul
if not errorlevel 1 (
  set "REBOOT_FLAG_REASON=directory"
  set "REBOOT_FLAG_OBSERVED_CLASS=directory"
  set "REBOOT_FLAG_VERIFY_HARDFAIL=1"
  exit /b 0
)
if not exist "%REBOOT_FLAG%" exit /b 0
call :reboot_flag_read_firstline_checked
if "%REBOOT_FLAG_READ_IOERR%"=="1" goto :reboot_flag_verify_read_failed
if not "%REBOOT_FLAG_READ_RC%"=="0" goto :reboot_flag_verify_read_failed
if /I "%REBOOT_FLAG_OBSERVED%"=="%REBOOT_FLAG_CONTENT%" set "REBOOT_FLAG_VERIFY_OK=1"
exit /b 0
:reboot_flag_verify_read_failed
set "REBOOT_FLAG_REASON=read_failed"
set "REBOOT_FLAG_OBSERVED_CLASS=unreadable"
set "REBOOT_FLAG_VERIFY_HARDFAIL=1"
exit /b 0

:reboot_flag_fail
REM Freeze RCs before any further commands so logs cannot accidentally drift
set "REBOOT_FLAG_WRITE_RC_FINAL=%REBOOT_FLAG_WRITE_RC%"
set "REBOOT_FLAG_READ_RC_FINAL=%REBOOT_FLAG_READ_RC%"
REM ERRORLEVEL is diagnostic-only for redirection/set /p. Avoid misleading "write_failed/read_failed with rc=0".
if /I "%REBOOT_FLAG_REASON%"=="write_failed" if "%REBOOT_FLAG_WRITE_RC_FINAL%"=="0" set "REBOOT_FLAG_WRITE_RC_FINAL="
if /I "%REBOOT_FLAG_REASON%"=="read_failed" if "%REBOOT_FLAG_READ_RC_FINAL%"=="0" set "REBOOT_FLAG_READ_RC_FINAL="
call :log "[ERROR] REBOOT_FLAG_SIGNAL_FAIL reason=%REBOOT_FLAG_REASON% marker=%REBOOT_FLAG% expected=%REBOOT_FLAG_CONTENT% observed_class=%REBOOT_FLAG_OBSERVED_CLASS% write_rc=%REBOOT_FLAG_WRITE_RC_FINAL% read_rc=%REBOOT_FLAG_READ_RC_FINAL%"
set "FAILED=1"
call :track_rc 9001
exit /b 0
