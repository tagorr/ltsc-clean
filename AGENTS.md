# AGENTS.md — Automation Runbook (LTSC 2021 Clean & Quiet)

**Scope:** Windows 10 Enterprise 2021 LTSC (21H2, build 19044+). We manage only the install scripts.

## Allowed to edit

`SetupComplete.cmd`, `PreOOBE.cmd`, `BootstrapLocalAdmin.ps1`, `CreatePrimaryAdmin.ps1`, `ValidateSecrets.ps1`, `README.md`, `DECISIONS.md`, `SECURITY.md`, `docs/AUDIT_CHECKLIST.md`.

**Forbidden:**

- Any edits by agents to files that are not listed in the “Allowed to edit” section above.
- Introducing new files for agents to touch without, in the same PR:
  - adding them to the “Allowed to edit” list in `AGENTS.md`, and
  - (recommended) backing the change with an ADR that explains why the new file exists.

## Invariants

* **No immediate reboots** inside `SetupComplete.cmd`. Reboot requirements are signaled only via `%WINDIR%\Panther\_needs_reboot.flag` (`Panther flag`) when `RC ∈ {3010, 1641}` or `ALWAYS_REBOOT_AFTER_FIRST_LOGON=1`. `SetupComplete.cmd` never calls `shutdown.exe`.
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
* CI guard enforces the EOL policy in GitHub (CLGuard). Treat .gitattributes as the source of truth for LF vs CRLF expectations.
* UTF-8 without BOM and “no NUL bytes” are required invariants, but they are not currently enforced by in-repo local hooks. Preserving encoding and avoiding NUL bytes is the responsibility of the operator/coding agent and must be caught via review.

### Minimal-diff rule

Touch only what is required. No reformatting outside changed hunks. Preserve existing EOLs.

### Session hygiene

Prefer one task per CLI session. If scope or shell rules change, start a fresh session.

## Policies

* **Edition gate:** `EditionID == REQUIRED_EDITION` → otherwise **FAIL**.
* **DISM RC policy (SetupComplete.cmd):**
  * `0` → success.
  * `3010/1641` → success, reboot required; set `NEEDS_REBOOT=1` and write the Panther reboot flag.
  * `-2146498548/2148468748` (“feature not recognized in this image”) and `-2146498541/2148468755` (“invalid install state for this feature”) → warning; log as such, set `HAS_DISM_WARN=1`, and treat as success.
  * Any other RC → fatal servicing error; log it, set `FAILED=1` and `DISM_HARD_FAIL=1`, and capture the first fatal return code in `L2C_FIRST_BAD_RC` via `:track_rc`. Once `DISM_HARD_FAIL` is set, further DISM feature/capability/cleanup calls must be skipped for the rest of the run.
* **DISM log:** single path for all calls — `%WINDIR%\Logs\DISM\SetupComplete-DISM.log` (use `/LogPath` + `/LogLevel:4`).
* **Logs:** `%WINDIR%\Panther\PreOOBE.log`, `%WINDIR%\Panther\SetupComplete.log` (ISO-8601), and the DISM log above.
* **Winlogon:** `HKLM\...\Winlogon\IgnoreShiftOverride` = **REG_SZ "0"** (not `REG_DWORD`), with no intermediate `"1"`.
* **Bootstrap/primary-admin chain:** `BootstrapLocalAdmin.ps1` must resolve the local Administrators group via SID `S-1-5-32-544`, translate it to an `NTAccount`, and use that identity consistently for both `net localgroup` and ACLs on `.bootstrap.pw`.
* **.bootstrap.pw policy:** `.bootstrap.pw` must be created with inheritance disabled and an explicit ACL granting FullControl only to `NT AUTHORITY\SYSTEM` and the local Administrators group (resolved via SID), Hidden + System attributes, and UTF-8 (no BOM). If ACL application fails, Stage A must fail closed rather than proceeding with a weakened or inherited ACL. Stage B must always attempt to delete `.bootstrap.pw`, record the cleanup state (`removed`, `missing`, or `error`) in its master log, and emit WARN/ERROR entries for non-ideal states. Any relaxation of these guarantees requires an ADR in `DECISIONS.md` and matching updates to `SECURITY.md` before code changes.
* `PreOOBE.cmd` (specialize) invokes `BootstrapLocalAdmin.ps1`. PreOOBE does not touch Winlogon, passwordless settings, or scheduled tasks.
* **SetupComplete.cmd:** servicing/logging plus the Stage B gateway (secret validation + gate + optional Stage B scheduling/Winlogon priming when the combined gate is open) after DISM feature/capability servicing and before the `Panther flag` reboot logic. It computes `NEEDS_REBOOT` and writes the `Panther flag` when `RC ∈ {3010, 1641}` or `ALWAYS_REBOOT_AFTER_FIRST_LOGON=1`. It never calls `shutdown.exe`.
* On any Bootstrap or self-test failure the pipeline switches to recovery mode. In recovery the `\L2C\CreatePrimaryAdmin` task is not registered.

### Reboot orchestration guardrails

* `SetupComplete.cmd` is the only stage that decides whether the unattended pipeline requires a reboot, and it may only communicate that decision via the `Panther flag`.
* Stage B of `CreatePrimaryAdmin.ps1` is the only unattended stage allowed to read the `Panther flag` and, in normal mode, call `shutdown.exe` automatically. It may delete the flag only when Stage B completes successfully in normal mode; on failure or in recovery it must suppress automatic reboot and may leave the flag in place as a diagnostic marker.
* Codex CLI must not introduce inline `shutdown.exe` calls in other scripts; the `Panther flag` remains the single reboot signal.
* In normal mode, when Stage B completes successfully and the `Panther flag` is present, Stage B logs the pending reboot, finishes its cleanup, deletes the flag, and performs a single controlled reboot.
* In recovery mode, or if Stage B fails, it never calls `shutdown.exe`. It only logs the presence of the `Panther flag` and the fact that automatic reboot was suppressed, and it may leave the flag in place for operators or later manual runs (see DECISIONS.md for details).
* When editing docs or code, keep the reboot model flag-based end to end and do not add new decision points in other scripts or tasks.

### Audit sessions (Codex CLI)

- `docs/AUDIT_CHECKLIST.md` is the canonical checklist for end-to-end audits of scripts and documentation. It defines the minimum bar for a “full audit”, not the maximum scope.
- There are two explicit audit modes, controlled by the Owner’s prompt.

#### 1. Strict checklist audit

When the Owner explicitly requests a strict checklist audit (for example, “run a strict audit against docs/AUDIT_CHECKLIST.md”):

- Codex must:
  - read `docs/AUDIT_CHECKLIST.md` first;
  - structure its checks and output according to the checklist sections;
  - stay within the checklist scope and avoid introducing extra checks that contradict or extend it.
- The goal of this mode is to verify that the current code and docs fully comply with the agreed checklist, without redefining it on the fly.

#### 2. Full audit (checklist + exploratory)

When the Owner requests a full audit (for example, “run a full audit of SetupComplete.cmd and CreatePrimaryAdmin.ps1”), Codex must:

- treat `docs/AUDIT_CHECKLIST.md` as the baseline:
  - read the checklist first;
  - explicitly cover all relevant sections in its report;
- then, in a separate section such as `Additional findings (outside the checklist)`:
  - report any extra issues, smells, or improvement ideas that are not yet formalized in the checklist;
  - clearly mark that these findings go beyond the current checklist and may later be promoted into new checklist items.

In other words, for full audits the checklist defines the minimum guaranteed coverage, but Codex is encouraged to surface additional findings as long as they are clearly separated from the checklist-based assessment.

#### 3. Narrow edits

For narrow, file-scoped edits (small bugfixes, refactors, localized doc touch-ups), Codex:

- does not have to load `docs/AUDIT_CHECKLIST.md` into context;
- still must respect the general invariants from this document (EOL, encodings, minimal diffs, sandbox only, no surprise file scope expansion).

## PR rules

* Minimal diffs grouped per file; no cosmetic changes outside hunks.
* PR description must confirm: edition gate, DISM RC policy, unified `/LogPath`, log locations, `IgnoreShiftOverride`, and formatting (UTF-8 / CRLF vs LF).

## Runbook — one-command smoke path

**Run in an elevated *Windows PowerShell 5.1* console.**

```cmd
schtasks /Create /TN "\L2C\CreatePrimaryAdmin" /TR "powershell.exe -NoProfile -ExecutionPolicy Bypass -File ""%WINDIR%\Setup\Scripts\CreatePrimaryAdmin.ps1""" /SC ONLOGON /RU SYSTEM /RL HIGHEST /F
```

Disclaimer: this is a manual engineering test. Inside `SetupComplete.cmd` no reboot is executed. A deferred reboot can only happen later when Stage B consumes the `Panther flag` that `SetupComplete.cmd` wrote after servicing RC `3010/1641` or when `ALWAYS_REBOOT_AFTER_FIRST_LOGON=1` is set.

*After a successful normal run, verify (see README for details): `AutoAdminLogon=0`, `ForceAutoLogon=0`, `DefaultPassword` and `AutoLogonCount` removed, `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\DisableCAD=0`, `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Authentication\LogonUI\Ngc\DevicePasswordLessBuildVersion=2`, `bootstrap` disabled, `primaryadmin` is a member of Administrators, task `\L2C\CreatePrimaryAdmin` deleted, and `C:\ProgramData\l2c_master_<timestamp>.log` present.*

*`SetupComplete.cmd` aggregates a final exit code instead of exiting immediately on the first failure: if `L2C_FIRST_BAD_RC` is set, `FINAL_RC=L2C_FIRST_BAD_RC`; otherwise, if `FAILED==1`, `FINAL_RC=1`; otherwise `FINAL_RC=0`. Warnings (`HAS_DISM_WARN=1`) do not force a failure. The script logs “[RC] returning %FINAL_RC%” via `:log` and exits with that code.*

**Validation on a fresh VM:**

1. `PreOOBE.cmd` (specialize pass) applies early privacy and security policies and runs `BootstrapLocalAdmin.ps1`. Bootstrap creates or refreshes the temporary `bootstrap` admin, writes `%WINDIR%\Setup\Scripts\.bootstrap.pw` with ACL restricted to SYSTEM and the local Administrators group, and stops there. It does not touch Winlogon, passwordless settings, or scheduled tasks.
2. `SetupComplete.cmd` runs in the SetupComplete phase, before the first interactive logon, performs DISM servicing, and applies DISM return-code policy. Known benign servicing codes are treated as warnings, `3010`/`1641` are treated as “reboot required” success outcomes, and unexpected DISM errors set `FAILED=1` and `DISM_HARD_FAIL=1`. A hard-fail stops further DISM-dependent work for the remainder of the run (skips additional feature/capability/cleanup operations), but the script still reaches the final aggregation and exits with `FINAL_RC` (first fatal RC via `L2C_FIRST_BAD_RC`, otherwise `1` if `FAILED=1`, otherwise `0`). After its servicing section, `SetupComplete.cmd` runs the Stage B gateway (secret validation + gate + optional Stage B scheduling/Winlogon priming) before evaluating/writing the `Panther flag`; when `FAILED=1` it logs `SetupComplete entered recovery mode; skipping extra registrations` and does not schedule/prime Stage B.
3. On the first logon the SYSTEM task `\L2C\CreatePrimaryAdmin` runs `CreatePrimaryAdmin.ps1`. Stage A creates or repairs the primary admin account and ensures membership in the local Administrators group. Stage B always runs afterwards, collapses the temporary Winlogon autologon and verifies post-action that `DefaultPassword` is absent and autologon values are disabled; verification failures (or read errors) are treated as a hard-fail that keeps `bootstrap` enabled and the scheduled task retained. Stage B restores `DisableCAD=0` and `Ngc\DevicePasswordLessBuildVersion=2`, attempts to delete `.bootstrap.pw` and `.primaryadmin.pw` only when Winlogon cleanup verification succeeded (otherwise preserves both secrets), and writes `C:\ProgramData\l2c_master_<ts>.log`. In the normal success path it also disables the `bootstrap` account and deletes the `\L2C\CreatePrimaryAdmin` scheduled task so that the temporary bootstrap entry point is removed. If the `Panther flag` exists and Stage B completes successfully in normal mode, Stage B then logs the pending reboot, deletes the flag, and performs a single controlled reboot. In recovery or failure paths, Stage B leaves the `bootstrap` account and scheduled task in place so that you can sign in again under `bootstrap` and rerun the pipeline, still logs the presence of the flag and that the automatic reboot was suppressed, does not call `shutdown.exe`, and may leave the flag in place as a diagnostic marker recorded in the master log.

**Repeat validation (snapshots / new VM):**

* Run `schtasks /Query /TN "\L2C\CreatePrimaryAdmin"`. If the task is missing, register it again (see README → "Registering the master task in Task Scheduler"). Ensure that `.bootstrap.pw` is absent before a manual rerun, or that it contains a lab password with correct ACL and attributes.
* Run `schtasks /Run /TN "\L2C\CreatePrimaryAdmin"` and verify that Stage B again cleans Winlogon state and, on success, removes the scheduled task and produces a fresh `l2c_master_<ts>.log`.

**Known fix:** message `ADSI update failed for ${User}:` — see `DECISIONS.md` (ADR about Stage A/Stage B and `$User:` interpolation).
