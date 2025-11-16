# AGENTS.md — Automation Runbook (LTSC 2021 Clean & Quiet)

**Scope:** Windows 10 Enterprise 2021 LTSC (21H2, build 19044+). We manage only the install scripts.

## Allowed to edit

`SetupComplete.cmd`, `PreOOBE.cmd`, `BootstrapLocalAdmin.ps1`, `CreatePrimaryAdmin.ps1`, `README.md`, `DECISIONS.md`, `SECURITY.md`, `BACKGROUND.md`.
**Forbidden:** new files/folders and edits outside these files.

## Invariants

* **No immediate reboots** inside `SetupComplete.cmd`. Reboot requirements are signaled only via `%WINDIR%\Panther\_needs_reboot.flag` (`Panther flag`) when `RC ∈ {3010, 1641}` or `ALWAYS_REBOOT_AFTER_FIRST_LOGON=1`. `SetupComplete.cmd` never calls `shutdown.exe` and never creates RunOnce entries for shutdown.
* **EOL:** scripts (`.cmd/.ps1`) use CRLF; documentation (`.md`) uses LF.
* Documentation must match actual behavior (paths, logs, steps). Details live in `README.md` and `DECISIONS.md`.
* **CLI/PowerShell style (project-wide):** Commands are authored for **Windows PowerShell 5.1**; external tools are allowed (`reg.exe`, `schtasks.exe`, `shutdown.exe`) with **PowerShell-style** suppression only; avoid `cmd /c` unless required; `reg.exe` uses classic `HKLM\...` paths, PowerShell cmdlets use the registry provider (`HKLM:\...`). Full rules: see **README.md → Project PowerShell/CLI rules**.
* Use `reg.exe` directly. Always inspect `$LASTEXITCODE` after each call. For `DELETE`, return codes `{0,2}` are treated as success.
* In `.cmd/.bat` files, direct PowerShell syntax is **not allowed**. Use it only via `powershell.exe ...` (see README → "Calling PowerShell from CMD scripts").
* In `.cmd/.bat` files `EnableDelayedExpansion` is forbidden. Use plain `%VAR%` expansion and implement branching via labels and subroutines (`goto`, `call :sub`) without relying on delayed expansion.

## Codex CLI Contract

Codex CLI runs locally against this repository’s working copy. Follow these rules.

### Scope

* Single source of truth: `main`.
* Environment: Windows 10/11, PowerShell 5.1, `cmd.exe`, Git for Windows.
* Allowed files: only those explicitly requested in the prompt or listed in this contract. Minimal diffs only.

### Command contract

* Run cmd commands only as:

  ```cmd
  cmd.exe /c "…"
  ```

* Use double quotes only in cmd. Never wrap cmd lines in single quotes.

* Call Windows PowerShell 5.1 explicitly:

  ```cmd
  %SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -NonInteractive …
  ```

  Do not hardcode drive letters for system paths.

* Never run Git from inside `.git` subfolders.

* Before a risky step, print `cd` and the exact command, then execute it and show output. Abort on non-zero exit codes.

### Shell roles

* `cmd.exe` is the primary shell for hooks and Git plumbing.
* Windows PowerShell 5.1 is a tool to run validators, not the outer shell for pipelines.

### EOL/BOM policy

* `*.md` stored with LF. `.cmd/.bat/.ps1` stored with CRLF.
* UTF-8 without BOM everywhere. Zero bytes are forbidden.
* Local guard: `githooks/pre-commit.cmd` materializes staged files then runs `tools/check-eol-bom.ps1 -IncludePaths`.
* CI guard reproduces the same checks on `windows-latest`.

### Minimal-diff rule

Touch only what is required. No reformatting outside changed hunks. Preserve existing EOLs.

### Session hygiene

Prefer one task per CLI session. If scope or shell rules change, start a fresh session.

## Policies

* **Edition gate:** `EditionID == REQUIRED_EDITION` → otherwise **FAIL**.
* **DISM RC policy:** `0` → OK. `3010/1641` → OK **and** write the `Panther flag`. Any other RC → **FAIL** (`FAILED=1`, `exit /b <RC>`).
* **DISM log:** single path for all calls — `%WINDIR%\Logs\DISM\SetupComplete-DISM.log` (use `/LogPath` + `/LogLevel:4`).
* **Logs:** `%WINDIR%\Panther\PreOOBE.log`, `%WINDIR%\Panther\SetupComplete.log` (ISO-8601), and the DISM log above.
* **Winlogon:** `HKLM\...\Winlogon\IgnoreShiftOverride` = **REG_SZ "0"** (not `REG_DWORD`), with no intermediate `"1"`.
* **Bootstrap/primary-admin chain:** `BootstrapLocalAdmin.ps1` must resolve the local Administrators group via SID `S-1-5-32-544`, translate it to an `NTAccount`, and use that identity consistently for both `net localgroup` and ACLs on `.bootstrap.pw`.
* **.bootstrap.pw policy:** `.bootstrap.pw` must be created with inheritance disabled and an explicit ACL granting FullControl only to `NT AUTHORITY\SYSTEM` and the local Administrators group (resolved via SID), Hidden + System attributes, and UTF-8 (no BOM). If ACL application fails, Stage A must fail closed rather than proceeding with a weakened or inherited ACL. Stage B must always attempt to delete `.bootstrap.pw`, record the cleanup state (`removed`, `missing`, or `error`) in its master log, and emit WARN/ERROR entries for non-ideal states. Any relaxation of these guarantees requires an ADR in `DECISIONS.md` and matching updates to `SECURITY.md` before code changes.
* `PreOOBE.cmd` (specialize) invokes `BootstrapLocalAdmin.ps1`. PreOOBE does not touch Winlogon, passwordless settings, RunOnce or scheduled tasks.
* **SetupComplete.cmd:** servicing/logging only. It computes `NEEDS_REBOOT` and writes the `Panther flag` when `RC ∈ {3010, 1641}` or `ALWAYS_REBOOT_AFTER_FIRST_LOGON=1`. It never calls `shutdown.exe` and does not create RunOnce entries for shutdown.
* On any Bootstrap or self-test failure the pipeline switches to recovery mode. In recovery the `\L2C\CreatePrimaryAdmin` task is not registered.

### Reboot orchestration guardrails

* `SetupComplete.cmd` is the only stage that decides whether the unattended pipeline requires a reboot, and it may only communicate that decision via the `Panther flag`.
* Stage B of `CreatePrimaryAdmin.ps1` is the only unattended stage allowed to consume the `Panther flag` and call `shutdown.exe` automatically. It must delete the flag afterward and respect recovery mode (no automatic reboot when `$isRecovery` is true).
* Codex CLI must not introduce RunOnce entries for shutdown or inline `shutdown.exe` calls in other scripts; the `Panther flag` remains the single reboot signal.
* In normal mode Stage B logs the presence of the `Panther flag`, performs its cleanup, reboots, and ensures the flag is removed. In recovery mode Stage B only logs and deletes the flag without reboot, recording this in the master log.
* When editing docs or code, keep the reboot model flag-based end to end and do not add new decision points in other scripts or tasks.

## PR rules

* Minimal diffs grouped per file; no cosmetic changes outside hunks.
* PR description must confirm: edition gate, DISM RC policy, unified `/LogPath`, log locations, `IgnoreShiftOverride`, and formatting (UTF-8 / CRLF vs LF).

## Runbook — one-command smoke path

**Run in an elevated *Windows PowerShell 5.1* console.**

```cmd
schtasks /Create /TN "\L2C\CreatePrimaryAdmin" /TR "powershell.exe -NoProfile -ExecutionPolicy Bypass -File ""%WINDIR%\Setup\Scripts\CreatePrimaryAdmin.ps1""" /SC ONLOGON /RU SYSTEM /RL HIGHEST /F
```

Disclaimer: this is a manual engineering test. Inside `SetupComplete.cmd` no reboot is executed. A deferred reboot can only happen later when Stage B consumes the `Panther flag` that `SetupComplete.cmd` wrote after servicing RC `3010/1641` or when `ALWAYS_REBOOT_AFTER_FIRST_LOGON=1` is set.

*After the task fires, verify (see README for details): `AutoAdminLogon=0`, `ForceAutoLogon=0`, `DefaultPassword` and `AutoLogonCount` removed, `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\DisableCAD=0`, `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Authentication\LogonUI\Ngc\DevicePasswordLessBuildVersion=2`, `bootstrap` disabled, `primaryadmin` is a member of Administrators, task `\L2C\CreatePrimaryAdmin` deleted, and `C:\ProgramData\l2c_master_<timestamp>.log` present.*

*`SetupComplete.cmd` exits with the first failing RC (anything other than `0/3010/1641`) to surface servicing errors.*

**Validation on a fresh VM:**

1. `PreOOBE.cmd` (specialize pass) applies early privacy and security policies and runs `BootstrapLocalAdmin.ps1`. Bootstrap creates or refreshes the temporary `bootstrap` admin, writes `%WINDIR%\Setup\Scripts\.bootstrap.pw` with ACL restricted to SYSTEM and the local Administrators group, and stops there. It does not touch Winlogon, passwordless settings, RunOnce or scheduled tasks.
2. `SetupComplete.cmd` runs after image servicing. When `.bootstrap.pw` is present it prepares Winlogon AutoAdminLogon for `bootstrap`, registers `\L2C\CreatePrimaryAdmin` (SYSTEM, Highest, OnLogon), then performs all hardening and servicing. If servicing returns RC `3010/1641` or `ALWAYS_REBOOT_AFTER_FIRST_LOGON=1` is set, it computes `NEEDS_REBOOT` and writes the `Panther flag`. Any other non-zero RC terminates the script immediately and is recorded as the first failing RC.
3. On the first logon the SYSTEM task `\L2C\CreatePrimaryAdmin` runs `CreatePrimaryAdmin.ps1`. Stage A creates or repairs the primary admin account and ensures membership in the local Administrators group. Stage B always runs, collapses the temporary Winlogon autologon, restores `DisableCAD=0` and `Ngc\DevicePasswordLessBuildVersion=2`, cleans RunOnce tails related to `CreatePrimaryAdmin`, removes `.bootstrap.pw`, and writes `C:\ProgramData\l2c_master_<ts>.log`. In normal mode it also disables the `bootstrap` account, deletes the `\L2C\CreatePrimaryAdmin` task and, if the `Panther flag` exists, logs the requirement, reboots, and deletes the flag. In recovery mode it leaves the `bootstrap` account and scheduled task in place, still resets policies and autologon, removes `.bootstrap.pw`, and if the flag exists it only logs and deletes it without reboot, recording this in the master log.

**Repeat validation (snapshots / new VM):**

* Run `schtasks /Query /TN "\L2C\CreatePrimaryAdmin"`. If the task is missing, register it again (see README → "Registering the master task in Task Scheduler"). Ensure that `.bootstrap.pw` is absent before a manual rerun, or that it contains a lab password with correct ACL and attributes.
* Run `schtasks /Run /TN "\L2C\CreatePrimaryAdmin"` and verify that Stage B again cleans Winlogon state, removes the scheduled task and produces a fresh `l2c_master_<ts>.log`.

**Known fix:** message `ADSI update failed for ${User}:` — see `DECISIONS.md` (ADR about Stage A/Stage B and `$User:` interpolation).
