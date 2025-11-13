# AGENTS.md — Automation Runbook (LTSC 2021 Clean & Quiet)

**Scope:** Windows 10 Enterprise 2021 LTSC (21H2, build 19044+). We manage only the install scripts.

## Allowed to edit
`SetupComplete.cmd`, `PreOOBE.cmd`, `BootstrapLocalAdmin.ps1`, `CreatePrimaryAdmin.ps1`, `README.md`, `DECISIONS.md`, `SECURITY.md`, `BACKGROUND.md`.  
**Forbidden:** new files/folders and edits outside these files.

## Invariants
- **No immediate reboots** inside `SetupComplete.cmd`. Reboot only via RunOnce when `RC ∈ {3010, 1641}`.
- **EOL:** скрипты (`.cmd/.ps1`) — CRLF; документация (`.md`) — LF.
- Documentation must match behavior (paths/logs/steps). Details live in `README.md` and `DECISIONS.md`.
- **CLI/PowerShell style (project-wide):** Commands are authored for **Windows PowerShell 5.1**; external tools allowed (`reg.exe`, `schtasks.exe`, `shutdown.exe`) with **PowerShell-style** suppression only; avoid `cmd /c` unless required; `reg.exe` uses classic `HKLM\...` paths, PowerShell cmdlets use the registry provider (`HKLM:\...`). Full rules: see **README.md → Проектные правила PowerShell/CLI**.
- `reg.exe` вызываем напрямую; после вызова читаем `$LASTEXITCODE`; для `DELETE` RC `{0,2}` считаются нормой.

- In `.cmd/.bat` files, direct PowerShell syntax is **not allowed**. Use only via `powershell.exe ...` (see README → "Calling PowerShell from CMD scripts").
- В `.cmd/.bat` запрещено включать `EnableDelayedExpansion`; переменные читаем в `%VAR%`, ветвления реализуем через метки/подпрограммы (`goto`, `call :sub`) без зависимостей от внутри-блочного пере-расширения.

## Codex CLI Contract

Codex CLI runs locally against this repository’s working copy. Follow these rules.

### Scope
- Single source of truth: `main`.
- Environment: Windows 10/11, PowerShell 5.1, cmd.exe, Git for Windows.
- Allowed files: only those explicitly requested in the prompt or in this contract. Minimal diffs only.

### Command contract
- Run cmd commands only as:
  cmd.exe /c "…"
- Use double quotes only in cmd. Never wrap cmd lines in single quotes.
- Call Windows PowerShell 5.1 explicitly:
  %SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -NonInteractive …
  Do not hardcode drive letters for system paths.
- Never run Git from inside `.git` subfolders.
- Before a risky step, print `cd` and the exact command, then execute it and show output. Abort on non-zero exit codes.

### Shell roles
- `cmd.exe` is the primary shell for hooks and Git plumbing.
- PowerShell 5.1 is a tool to run validators, not the outer shell for pipelines.

### EOL/BOM policy
- `*.md` stored LF. `.cmd/.bat/.ps1` stored CRLF.
- UTF-8 without BOM everywhere. Zero bytes forbidden.
- Local guard: githooks/pre-commit.cmd materializes staged files then runs tools/check-eol-bom.ps1 -IncludePaths.
- CI guard reproduces the same checks on windows-latest.

### Minimal-diff rule
Touch only what is required. No reformatting outside changed hunks. Preserve EOLs.

### Session hygiene
Prefer one task per CLI session. If scope or shell rules change, start a fresh session.

## Policies
- **Edition gate:** `EditionID == REQUIRED_EDITION` → otherwise **FAIL**.
- **DISM RC policy:** `0` → OK; `3010/1641` → OK **and** schedule RunOnce `zz-SetupCompleteReboot`; any other RC → **FAIL** (`FAILED=1`, `exit /b <RC>`).
- **DISM log:** single path for all calls — `%WINDIR%\Logs\DISM\SetupComplete-DISM.log` (use `/LogPath` + `/LogLevel:4`).
- **Logs:** `%WINDIR%\Panther\PreOOBE.log`, `%WINDIR%\Panther\SetupComplete.log` (ISO-8601), and the DISM log above.
- **Winlogon:** `HKLM\...\Winlogon\IgnoreShiftOverride` = **REG_SZ "0"** (not `REG_DWORD`), with no intermediate `"1"`.
- **Bootstrap/primary-admin chain:** `BootstrapLocalAdmin.ps1` must resolve the local Administrators group via SID `S-1-5-32-544`, translate it to an `NTAccount`, and use that identity consistently for both `net localgroup` and ACLs on `.bootstrap.pw`.
- **.bootstrap.pw policy:** `.bootstrap.pw` must be created with inheritance disabled and an explicit ACL granting FullControl only to `NT AUTHORITY\SYSTEM` and the local Administrators group (resolved via SID), Hidden+System attributes, and UTF-8 (no BOM). If ACL application fails, Stage A must fail closed rather than proceeding with a weakened or inherited ACL. Stage B must always attempt to delete `.bootstrap.pw`, record the cleanup state (`removed`, `missing`, or `error`) in its master log, and emit WARN/ERROR entries for non-ideal states. Any relaxation of these guarantees requires an ADR in `DECISIONS.md` and matching updates to `SECURITY.md` before code changes.
- PreOOBE.cmd (specialize) invokes BootstrapLocalAdmin.ps1. PreOOBE does not touch Winlogon/Passwordless/RunOnce/Tasks.
**SetupComplete.cmd:** servicing/logging only; schedules a single conditional reboot via RunOnce when RC ∈ {3010, 1641}. No immediate reboot inside `SetupComplete.cmd`.
- При любом сбое Bootstrap/self-test выполняется recovery; задача `\L2C\CreatePrimaryAdmin` в recovery **не** регистрируется.

## PR rules
- Minimal diffs grouped per file; no cosmetic changes outside hunks.
- PR description must check: edition gate, DISM RC policy, unified `/LogPath`, log locations, `IgnoreShiftOverride`, and formatting (UTF-8/CRLF).

## Runbook — one-command smoke path
**Run in an elevated _Windows PowerShell 5.1_ console.**

```cmd
schtasks /Create /TN "\L2C\CreatePrimaryAdmin" /TR "powershell.exe -NoProfile -ExecutionPolicy Bypass -File ""%WINDIR%\Setup\Scripts\CreatePrimaryAdmin.ps1""" /SC ONLOGON /RU SYSTEM /RL HIGHEST /F
```

**Дисклеймер:** это ручной инженерный тест. Внутри `SetupComplete.cmd` ребут **не** выполняется; возможен только отложенный ребут при `RC=3010/1641`.

*After the task fires, verify from README: AutoAdminLogon=0, ForceAutoLogon=0, DefaultPassword/AutoLogonCount removed, `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\DisableCAD=0`, `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Authentication\LogonUI\Ngc\DevicePasswordLessBuildVersion=2`, `bootstrap` disabled, `primaryadmin` ∈ Administrators, задача `\L2C\CreatePrimaryAdmin` удалена, в `C:\ProgramData` лежит `l2c_master_<timestamp>.log`.*
*SetupComplete.cmd exits with the first failing RC (anything other than 0/3010/1641) to surface servicing errors.*

**Валидация на стенде:**

1. `PreOOBE.cmd` (pass specialize) применяет ранние privacy/security-политики и запускает `BootstrapLocalAdmin.ps1`. Bootstrap создаёт/освежает временного `bootstrap`-админа, записывает `%WINDIR%\Setup\Scripts\.bootstrap.pw` с ACL только для SYSTEM + Administrators и на этом заканчивает (Winlogon и Planer не трогает).
2. `SetupComplete.cmd` при наличии `.bootstrap.pw` подготавливает Winlogon-автологон для `bootstrap`, регистрирует `\L2C\CreatePrimaryAdmin` (SYSTEM, Highest, OnLogon), затем выполняет всё хардениг/servicing. RC `3010/1641` приводят к единственному RunOnce `zz-SetupCompleteReboot`, любые другие RC немедленно завершают скрипт с ошибкой (и фиксируются как *first failing RC*).
3. На первом входе задача под SYSTEM запускает `CreatePrimaryAdmin.ps1`: Stage A создаёт/чинит основного администратора, Stage B схлопывает Winlogon-автологон, отключает `bootstrap`, удаляет `.bootstrap.pw`, возвращает `DisableCAD=0` в `Policies\System` и `Ngc\DevicePasswordLessBuildVersion=2`, удаляет задачу и пишет `C:\ProgramData\l2c_master_<ts>.log`.

**Повторная проверка (snapshots/новая ВМ):**

* Запустить `schtasks /Query /TN "\L2C\CreatePrimaryAdmin"`; при отсутствии задачи зарегистрировать её снова (см. README → «Регистрация мастера в Планировщике»). Убедиться, что `.bootstrap.pw` отсутствует перед ручным перезапуском (или имеет стендовый пароль с корректным ACL/атрибутами).
* Выполнить `schtasks /Run /TN "\L2C\CreatePrimaryAdmin"` и убедиться, что Stage B повторно очищает Winlogon, удаляет задачу и создаёт свежий лог `l2c_master_<ts>.log`.

**Known fix:** message `ADSI update failed for ${User}:` — see `DECISIONS.md` (ADR about Stage A/Stage B and `$User:` interpolation).
