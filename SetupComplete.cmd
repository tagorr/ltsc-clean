@echo off
REM SPDX-License-Identifier: MIT
REM Windows 10 LTSC 2021 - Clean ^& Quiet Baseline (Official Tools Only)
REM Generated: 2025-09-15
setlocal EnableExtensions

:: ------------ logging ------------
set "LOG=%WINDIR%\Panther\SetupComplete.log"
set "REBOOT_FLAG=%WINDIR%\Panther\_needs_reboot.flag"
del /q "%REBOOT_FLAG%" >nul 2>&1
if not exist "%WINDIR%\Panther" mkdir "%WINDIR%\Panther" >nul 2>&1
if not exist "%WINDIR%\Logs\DISM" mkdir "%WINDIR%\Logs\DISM" >nul 2>&1

:: ------------ config flags ------------
set "LOG_TS_ENGINE=POWERSHELL"
set "REBOOT_ON_RC=1"
set "ALWAYS_REBOOT_AFTER_FIRST_LOGON=0"
set "NEEDS_REBOOT=0"
set "FAILED=0"
call :log "----- SetupComplete started -----"

:: --- compatibility controls ---
set "REQUIRED_EDITION=EnterpriseS"
set "REQUIRED_DV=21H2"
set "MIN_BUILD=19044"
set "STRICT_DISPLAYVERSION=0"  :: 1 = abort on DV mismatch, 0 = warn and continue

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
  exit /b 1
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
  for /f "skip=1 tokens=1,2,*" %%A in (reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion" /v CurrentBuild 2^>nul) do if /I "%%A"=="CurrentBuild" set "CB=%%C"
  set "CB=%CB:"=%"
)
for /f "tokens=1 delims= " %%# in ("%CB%") do set "CBN=%%#"
set /a CBN+=0 >nul 2>&1
call :gate_build
if errorlevel 1 exit /b 1
call :gate_dv
if errorlevel 1 exit /b 1
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
  for /f %%G in ('powershell -NoProfile -Command "Get-Date -Format o" 2^>nul') do set "TS=%%G"
)
if not defined TS (
  for /f %%G in ('powershell -NoProfile -Command "Get-Date -Format \"yyyy-MM-ddTHH:mm:ss\"" 2^>nul') do set "TS=%%G"
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

:disable_feature_if_enabled
REM usage: call :disable_feature_if_enabled FeatureName LogName
set "FN=%~1"
set "LG=%~2"
if not defined FN goto :eof
call :log "[INFO] %LG% - attempting disable"
call :run_dism /Disable-Feature /FeatureName:%FN%
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
  set "FAILED=1"
  call :log "[ERROR] %LG% disable failed (RC=%RC%)"
)
goto :eof

:remove_capability
REM usage: call :remove_capability CapabilityName Friendly
set "CAP=%~1"
set "FR=%~2"
REM Check if capability is installed; if not, skip quietly
for /f "tokens=1,2 delims=:" %%A in ('dism /online /Get-Capabilities ^| findstr /I /C:"%CAP%" ^| findstr /I "Installed"') do set "_cap_state=%%B"
if /I not "%_cap_state%"==" Installed" (
  call :log "[INFO] %FR% not installed (or name not recognized); skipping"
  set "_cap_state="
  goto :eof
)
set "_cap_state="
call :log "[STEP] Remove capability %FR% (%CAP%)"
call :run_dism /Remove-Capability /CapabilityName:%CAP%
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
  set "FAILED=1"
  call :log "[ERROR] Remove capability %FR% failed (RC=%RC%)"
)
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
if /I not "%STRICT_DISPLAYVERSION%"=="1" (
  if defined REQUIRED_DV if /I not "%DV%"=="%REQUIRED_DV%" call :log "[WARN] DisplayVersion=%DV% (expected %REQUIRED_DV%). Proceeding."
  exit /b 0
)
if not defined DV (
  for /f "skip=1 tokens=1,2,*" %%A in ('reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion" /v DisplayVersion 2^>nul') do if /I "%%A"=="DisplayVersion" set "DV=%%C"
)
set "DV=%DV:"=%"
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

:run_dism
REM usage: call :run_dism <DISM-args-without-/Online>
set "CMD=dism /Online %* /Quiet /NoRestart /LogPath:%WINDIR%\Logs\DISM\SetupComplete-DISM.log /LogLevel:4 >nul 2>nul"
call :log "[DISM] %CMD%"
%CMD%
set "RC=%ERRORLEVEL%"
if "%RC%"=="3010" (
  call :log "[DISM] RC=3010 (success, reboot required)"
  set "NEEDS_REBOOT=1"
  call :flag_reboot
  exit /b 0
)
if "%RC%"=="1641" (
  call :log "[DISM] RC=1641 (success, reboot initiated by installer)"
  set "NEEDS_REBOOT=1"
  call :flag_reboot
  exit /b 0
)
if "%RC%"=="0" (
  call :log "[DISM] RC=0 (success)"
  exit /b 0
)
call :log "[DISM] RC=%RC% (error)"
set "FAILED=1"
exit /b %RC%

:run_msi
rem usage: call :run_msi "<msi path>" [more MSI properties]
set "MSI=%~1"
shift
call :log "[MSI] msiexec /i \"%MSI%\" /qn REBOOT=ReallySuppress /norestart %*"
msiexec /i "%MSI%" /qn REBOOT=ReallySuppress /norestart %*
set "RC=%ERRORLEVEL%"
call :handle_rc "MSI" %RC%
exit /b %RC%

:run_exe
rem usage: call :run_exe "<exe path>" [vendor-specific args]; default /quiet /norestart
set "EXE=%~1"
shift
call :log "[EXE] \"%EXE%\" /quiet /norestart %*"
"%EXE%" /quiet /norestart %*
set "RC=%ERRORLEVEL%"
call :handle_rc "EXE" %RC%
exit /b %RC%

:main

REM === [L2C] Winlogon bootstrap + CAD/NGC policies (idempotent) ===
set "WL=HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
set "SYS=HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
set "NGC=HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI\Ngc"

REM Источник пароля (создастся BootstrapLocalAdmin.ps1):
set "PWFILE=%WINDIR%\Setup\Scripts\.bootstrap.pw"
set "HAS_BOOTSTRAP_PW="

if exist "%PWFILE%" (
  for /f "usebackq delims=" %%P in ("%PWFILE%") do if not defined HAS_BOOTSTRAP_PW set "HAS_BOOTSTRAP_PW=1"
) else (
  call :log "[WARN] .bootstrap.pw not found; skipping Winlogon DefaultPassword"
)

REM Временные политики входа
reg add "%SYS%" /v DisableCAD /t REG_DWORD /d 1 /f >nul 2>&1
reg add "%NGC%" /v DevicePasswordLessBuildVersion /t REG_DWORD /d 0 /f >nul 2>&1
reg add "%WL%"  /v IgnoreShiftOverride          /t REG_SZ    /d 0 /f >nul 2>&1

REM Автологон только если известен пароль bootstrap
if defined HAS_BOOTSTRAP_PW (
  reg add "%WL%" /v DefaultUserName    /t REG_SZ    /d bootstrap /f >nul 2>&1
  reg add "%WL%" /v DefaultDomainName  /t REG_SZ    /d "%COMPUTERNAME%" /f >nul 2>&1
  powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "try {$pwPath = Join-Path $env:WINDIR 'Setup\Scripts\.bootstrap.pw'; $pw = Get-Content -LiteralPath $pwPath -Raw; Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name 'DefaultPassword' -Value $pw; exit 0} catch {exit 1}" >nul 2>&1
  reg add "%WL%" /v AutoAdminLogon     /t REG_SZ    /d 1 /f >nul 2>&1
  reg add "%WL%" /v ForceAutoLogon     /t REG_SZ    /d 1 /f >nul 2>&1
  reg add "%WL%" /v AutoLogonCount     /t REG_DWORD /d 2 /f >nul 2>&1
  call :log "[INFO] Winlogon autologon primed for 'bootstrap'"
) else (
  call :log "[WARN] Winlogon autologon not primed (no password source)"
)

REM === [L2C] Schedule CreatePrimaryAdmin as SYSTEM/Highest/OnLogon ===
schtasks /Create /TN "\L2C\CreatePrimaryAdmin" ^
  /TR "powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"%WINDIR%\Setup\Scripts\CreatePrimaryAdmin.ps1\"" ^
  /SC ONLOGON /RU SYSTEM /RL HIGHEST /F >nul 2>&1
if errorlevel 1 (
  call :log "[ERROR] Failed to create scheduled task \L2C\CreatePrimaryAdmin (rc=%ERRORLEVEL%)"
  set "FAILED=1"
) else (
  call :log "[INFO] Scheduled \L2C\CreatePrimaryAdmin (SYSTEM, Highest, OnLogon)"
)

REM === [L2C] Remove legacy RunOnce registration for CreatePrimaryAdmin (only if task created) ===
if not "%FAILED%"=="1" (
  reg delete "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" /v "CreatePrimaryAdmin" /f >nul 2>&1
  set "RC=%ERRORLEVEL%"
  if "%RC%"=="0" (
    call :log "[INFO] Cleared legacy RunOnce entry CreatePrimaryAdmin (RC=0)"
  ) else (
    if "%RC%"=="2" (
      call :log "[INFO] Legacy RunOnce entry CreatePrimaryAdmin already absent (RC=2)"
    ) else (
      call :log "[WARN] Failed to clear legacy RunOnce entry CreatePrimaryAdmin (RC=%RC%)"
    )
  )
) else (
  call :log "[WARN] Skipping RunOnce cleanup because scheduling task failed"
)

REM === [L2C] Recovery gate (no extra registrations on failure) ===
if "%FAILED%"=="1" (
  call :log "[WARN] SetupComplete entered recovery mode; skipping extra registrations"
)

:: ------------ Edge Update policies ------------
call :log "[SECTION] Edge Update policies"
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\EdgeUpdate" "UpdateDefault" "REG_DWORD" "0"
REM Optional: block installs too (uncomment if needed):
REM call :regadd "HKLM\SOFTWARE\Policies\Microsoft\EdgeUpdate" "InstallDefault" "REG_DWORD" "0"

:: ------------ Internet Explorer First Run policy ------------
call :log "[SECTION] IE First Run policy"
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\Internet Explorer\Main" "DisableFirstRunCustomize" "REG_DWORD" "1"
call :log "[SECTION] SmartScreen & Defender"

REM ------------ SmartScreen ^& Defender (preferences only) ------------
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\Windows\System" "EnableSmartScreen" "REG_DWORD" "0"
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\Windows Defender" "SubmitSamplesConsent" "REG_DWORD" "2"
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\Spynet" "SpynetReporting" "REG_DWORD" "0"
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection" "DisableRealtimeMonitoring" "REG_DWORD" "1"
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection" "DisableBehaviorMonitoring" "REG_DWORD" "1"
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection" "DisableIOAVProtection" "REG_DWORD" "1"
call :regadd "HKLM\SOFTWARE\Policies\Microsoft\Windows Defender" "PUAProtection" "REG_DWORD" "0"

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
powershell -NoProfile -ExecutionPolicy Bypass -Command "if(-not (Get-NetFirewallRule -DisplayName 'Block Telemetry Service (DiagTrack)' -ErrorAction SilentlyContinue)) { New-NetFirewallRule -DisplayName 'Block Telemetry Service (DiagTrack)' -Direction Outbound -Action Block -Enabled True -Service DiagTrack -Profile Any }" >nul 2>&1
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
for %%S in (SysMain WSearch Spooler DiagTrack dmwappushsvc WerSvc) do (
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
powershell -NoP -NonI -Command "Get-AppxPackage -AllUsers *XboxGamingOverlay* ^| Remove-AppxPackage" >nul 2>&1

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
  reg load HKU\DefUser "%DEFNTUSER%" >nul 2>&1
  if not errorlevel 1 (
    reg add "HKU\DefUser\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v ShowRecent   /t REG_DWORD /d 0 /f >nul 2>&1
    reg add "HKU\DefUser\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v ShowFrequent /t REG_DWORD /d 0 /f >nul 2>&1
    reg add "HKU\DefUser\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v LaunchTo     /t REG_DWORD /d 1 /f >nul 2>&1
    reg unload HKU\DefUser >nul 2>&1
    call :log "[STEP] Default profile Quick Access configured (new users only)"
  ) else (
    call :log "[WARN] Could not load Default user hive for Quick Access tweaks"
  )
) else (
  call :log "[INFO] Default user hive not found; skipping Quick Access tweaks"
)

:: ------------ Power settings ------------
powercfg -h off >nul 2>&1
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power" /v HiberbootEnabled /t REG_DWORD /d 0 /f >nul 2>&1
powercfg /setactive e9a42b02-d5df-448d-aa00-03f14749eb61 >nul 2>&1

:: ------------ Component cleanup ------------
call :log "[SECTION] Component cleanup"
call :run_dism /Cleanup-Image /StartComponentCleanup /ResetBase
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
  set "FAILED=1"
  call :log "[ERROR] Component cleanup failed (RC=%RC%)"
)

:: ------------ schedule reboot via RunOnce ------------
if "%ALWAYS_REBOOT_AFTER_FIRST_LOGON%"=="1" (
  call :log "[INFO] ALWAYS_REBOOT_AFTER_FIRST_LOGON=1 -> forcing reboot"
  set "NEEDS_REBOOT=1"
  call :flag_reboot
)

call :log "[INFO] Evaluating reboot requirement"
if not "%NEEDS_REBOOT%"=="1" if exist "%REBOOT_FLAG%" set "NEEDS_REBOOT=1"
if not "%NEEDS_REBOOT%"=="1" (
  findstr /i /c:"RC=3010" /c:"RC=1641" "%LOG%" >nul && (
    call :flag_reboot
    set "NEEDS_REBOOT=1"
  )
)

if "%NEEDS_REBOOT%"=="1" (
  call :log "[INFO] Reboot required"
  reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" /v "zz-SetupCompleteReboot" /t REG_SZ /d "%SystemRoot%\System32\shutdown.exe /r /t 5" /f >nul 2>&1
) else (
  call :log "[INFO] No reboot required"
)
call :log "----- SetupComplete finished -----"
exit /b %FAILED%

REM ===== Helpers (Telemetry hardening) =====
:svc_disable
REM Usage: call :svc_disable "ServiceName"
set "_svc=%~1"
sc query "%_svc%" >nul 2>&1 || goto :svc_done
sc stop  "%_svc%" >nul 2>&1
sc config "%_svc%" start= disabled >nul 2>&1
>>"%WINDIR%\Panther\SetupComplete.log" echo [OK] Service "%_svc%" -> Disabled

:svc_done
set "_svc="
exit /b 0

:task_disable
REM Usage: call :task_disable "\Path\To\Task"
schtasks /Query /TN "%~1" >nul 2>&1 || goto :task_done
schtasks /Change /TN "%~1" /Disable >nul 2>&1
>>"%WINDIR%\Panther\SetupComplete.log" echo [OK] Task "%~1" -> Disabled

:task_done
exit /b 0

:after_telemetry_hardening
:ts
  for /f %%# in ('powershell -NoProfile -Command "Get-Date -Format o" 2^>nul') do (
    set "TS=%%#"
    goto :eof
  )
  set "TS=%DATE% %TIME%"
goto :eof

:fw_block_diagtrack
setlocal EnableExtensions
set "RULE=Block Telemetry Service (DiagTrack)"
call :log "[STEP] Ensure firewall rule: %RULE%"
rem check if rule exists
netsh advfirewall firewall show rule name="%RULE%" >nul 2>&1
if errorlevel 1 (
  netsh advfirewall firewall add rule name="%RULE%" dir=out action=block program="%SystemRoot%\System32\svchost.exe" service=diagtrack enable=yes profile=any >nul 2>&1
  set "RC=%ERRORLEVEL%"
  if not "%RC%"=="0" (
    endlocal
    call :log "[ERROR] Failed to add firewall rule (%RC%)."
    exit /b %RC%
  )
  endlocal
  call :log "[OK] Firewall rule added: %RULE%"
  exit /b 0
) else (
  endlocal
  call :log "[OK] Firewall rule already present: %RULE%"
  exit /b 0
)

:flag_reboot
2>nul (>>"%REBOOT_FLAG%" echo .)
exit /b 0
