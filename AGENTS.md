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

```cmd
schtasks /Create /TN "\L2C\CreatePrimaryAdmin" /TR "powershell.exe -NoProfile -ExecutionPolicy Bypass -File ""%WINDIR%\Setup\Scripts\CreatePrimaryAdmin.ps1""" /SC ONLOGON /RU SYSTEM /RL HIGHEST /F
````

**Дисклеймер:** это ручной инженерный тест. Внутри `SetupComplete.cmd` ребут **не** выполняется; возможен только отложенный ребут при `RC=3010/1641`.

*After the task fires, verify from README: AutoAdminLogon=0, ForceAutoLogon=0, DefaultPassword/AutoLogonCount removed, DisableCAD=0 в обеих ветках, `bootstrap` disabled, `primaryadmin` ∈ Administrators, задача `\L2C\CreatePrimaryAdmin` удалена, в `C:\ProgramData` лежит `l2c_master_<timestamp>.log`.*

**Валидация на стенде:**

1. `SetupComplete.cmd` логирует секцию Bootstrap (маркер `[BOOTSTRAP] PW_SOURCE=...`), постановку `DisableCAD=1`, запись Winlogon и создание задачи `\L2C\CreatePrimaryAdmin`.
2. При первом входе задача запускается под SYSTEM, `CreatePrimaryAdmin.ps1` пишет `Begin/End Stage A/B` в `C:\ProgramData\l2c_master_<ts>.log`.
3. После завершения Stage B: Winlogon «схлопнут», `bootstrap` отключён, `DisableCAD=0` в `Policies\System` и `Winlogon`, `HKLM\...\Authentication\LogonUI\Ngc\DevicePasswordLessBuildVersion=2`, файл `%WINDIR%\Setup\Scripts\.bootstrap.pw` отсутствует, задача `\L2C\CreatePrimaryAdmin` удалена.

**Повторная проверка (snapshots/новая ВМ):**

* Запустить `schtasks /Query /TN "\L2C\CreatePrimaryAdmin"`; при отсутствии задачи зарегистрировать её снова (см. README → «Регистрация мастера в Планировщике»). Убедиться, что `.bootstrap.pw` отсутствует перед ручным перезапуском (или имеет стендовый пароль с корректным ACL/атрибутами).
* Выполнить `schtasks /Run /TN "\L2C\CreatePrimaryAdmin"` и убедиться, что Stage B повторно очищает Winlogon, удаляет задачу и создаёт свежий лог `l2c_master_<ts>.log`.

**Known fix:** message `ADSI update failed for ${User}:` — see `DECISIONS.md` (ADR about Stage A/Stage B and `$User:` interpolation).
