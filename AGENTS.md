# AGENTS.md — Automation Runbook (LTSC 2021 Clean & Quiet)

**Scope:** Windows 10 Enterprise 2021 LTSC (21H2, build 19044+). We manage only the install scripts.

## Allowed to edit
`SetupComplete.cmd`, `PreOOBE.cmd`, `BootstrapLocalAdmin.ps1`, `CreatePrimaryAdmin.ps1`, `README.md`, `DECISIONS.md`, `SECURITY.md`, `BACKGROUND.md`.  
**Forbidden:** new files/folders and edits outside these files.

## Invariants
- **No immediate reboots** inside `SetupComplete.cmd`. Reboot only via RunOnce when `RC ∈ {3010, 1641}`.
- Formatting: UTF-8 **no BOM**, **CRLF** line endings everywhere, no trailing spaces; do not reformat outside changed @@ hunks.
- Documentation must match behavior (paths/logs/steps). Details live in `README.md` and `DECISIONS.md`.
- **CLI/PowerShell style (project-wide):** Commands are authored for **Windows PowerShell 5.1**; external tools allowed (`reg.exe`, `schtasks.exe`, `shutdown.exe`) with **PowerShell-style** suppression only; avoid `cmd /c` unless required; `reg.exe` uses classic `HKLM\...` paths, PowerShell cmdlets use the registry provider (`HKLM:\...`). Full rules: see **README.md → Проектные правила PowerShell/CLI**.
- `reg.exe` вызываем напрямую; после вызова читаем `$LASTEXITCODE`; для `DELETE` RC `{0,2}` считаются нормой.

- In `.cmd/.bat` files, direct PowerShell syntax is **not allowed**. Use only via `powershell.exe ...` (see README → "Calling PowerShell from CMD scripts").
## Policies
- **Edition gate:** `EditionID == REQUIRED_EDITION` → otherwise **FAIL**.
- **DISM RC policy:** `0` → OK; `3010/1641` → OK **and** schedule RunOnce `zz-SetupCompleteReboot`; any other RC → **FAIL** (`FAILED=1`, `exit /b <RC>`).
- **DISM log:** single path for all calls — `%WINDIR%\Logs\DISM\SetupComplete-DISM.log` (use `/LogPath` + `/LogLevel:4`).
- **Logs:** `%WINDIR%\Panther\PreOOBE.log`, `%WINDIR%\Panther\SetupComplete.log` (ISO-8601), and the DISM log above.
- **Winlogon:** `HKLM\...\Winlogon\IgnoreShiftOverride` = **REG_SZ "0"** (not `REG_DWORD`), with no intermediate `"1"`.
- **PreOOBE:** invoke `BootstrapLocalAdmin.ps1`, log the `rc`, set `FAILED=1` when `rc≠0`.

## PR rules
- Minimal diffs grouped per file; no cosmetic changes outside hunks.
- PR description must check: edition gate, DISM RC policy, unified `/LogPath`, log locations, `IgnoreShiftOverride`, and formatting (UTF-8/CRLF).

## Runbook — one-command smoke path
**Run in an elevated _Windows PowerShell 5.1_ console.**

```powershell
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v AutoLogonCount   /t REG_DWORD /d 2 /f
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v DisableCAD    /t REG_DWORD /d 1 /f
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v DefaultUserName   /t REG_SZ    /d bootstrap /f
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v DefaultPassword   /t REG_SZ    /d <bootstrap-pass> /f
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v DefaultDomainName /t REG_SZ    /d "$env:COMPUTERNAME" /f
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v AutoAdminLogon    /t REG_SZ    /d 1 /f
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v ForceAutoLogon    /t REG_SZ    /d 1 /f
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" /v CreatePrimaryAdmin /t REG_SZ /d "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $env:WINDIR\Setup\Scripts\CreatePrimaryAdmin.ps1" /f
shutdown.exe /r /t 0
```

*After reboot, verify from README: AutoAdminLogon=0, ForceAutoLogon=0, DefaultPassword removed, RunOnce empty, `bootstrap` disabled, and `primaryadmin` is in Administrators.*
**Known fix:** message `ADSI update failed for ${User}:` — see `DECISIONS.md` (ADR about Stage A/Stage B and `$User:` interpolation).
