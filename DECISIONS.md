# Windows 10 LTSC 2021 - Clean & Quiet Baseline (Official Tools Only)

**Status:** Adopted

**Scope:** Windows 10 Enterprise 2021 LTSC (21H2, EditionID=EnterpriseS, build 19044+)

**Repository:** [https://github.com/tagor-sian/win10-ltsc-2021-clean-quiet-baseline](https://github.com/tagor-sian/win10-ltsc-2021-clean-quiet-baseline)

**License:** MIT

**Description:** A lean, predictable Windows 10 LTSC 2021 baseline with minimal background activity and telemetry. Uses official Microsoft mechanisms only (Policies/Registry, DISM Features & Capabilities, Scheduled Tasks). Conservative, no hacks; deterministic and idempotent. Ships the automation scripts (`PreOOBE.cmd`, `SetupComplete.cmd`, PowerShell helpers) and the canonical `Autounattend.xml` answer file.

This document records the decisions, rationale, scope boundaries, and verification steps for the baseline. It is the single source of truth for what the project does and why.

The baseline never auto-generates the primary local admin password. Instead it expects the operator to provide a strong password via `%WINDIR%\Setup\Scripts\.primaryadmin.pw`. `SetupComplete.cmd` reads and validates this secret to gate Stage B while keeping the `\L2C\CreatePrimaryAdmin` task command line free of secrets; Stage A of `CreatePrimaryAdmin.ps1` reads `.primaryadmin.pw` directly under SYSTEM. Both password source files (`.bootstrap.pw` and `.primaryadmin.pw`) are removed by Stage B on the normal path and preserved in recovery scenarios, including when the SetupComplete gate is closed and Stage B is not scheduled.

---

---

## Process policy: Agent execution model

- Codex CLI is the sole automation agent; its operational rules live in `AGENTS.md` under the “Codex CLI Contract”.
- The interaction contract is maintained in `docs/INTERACTION_CONTRACT.md` and defines the operational rules for agent-assisted changes.

## ADR: Fix PS interpolation in CreatePrimaryAdmin ($User: → ${User}:)

- **Context:** Stage A could fail on the message `ADSI update failed for $User:` — PowerShell 5.1 parsed `$User:` incorrectly and aborted during the ADSI update.

- **Decision:** narrowly replace the text with `ADSI update failed for ${User}:` with no other script changes.

- **Consequences:** fatal Stage A stopper removed; run predictability improved.

- **Related:** see “Idempotent Stage A; guard Stage B” about Stage A idempotence and the Stage B guard.

## 2A. Move servicing from XML into SetupComplete

- **Constraint (SKU):** Target **Windows 10 Enterprise LTSC 2021 (EnterpriseS)** or compatible **Enterprise** SKUs. Reason: `AllowTelemetry=0` (Security level) is supported on Enterprise.

**Decision.** All DISM operations and policies (IE/Edge, Delivery Optimization, telemetry, OneDrive, etc.) run in `SetupComplete.cmd`. The `Autounattend.xml` stays minimal (`windowsPE`, `generalize`, `specialize`, `oobeSystem` only), with no `FirstLogonCommands`.

**Motivation.** Predictable phases, a single logging point, no races during OOBE, and idempotent behavior. `SetupComplete.cmd` never performs a reboot. Instead, it decides whether a post install reboot is required and signals that decision via `%WINDIR%\Panther\_needs_reboot.flag` (the “Panther flag”), leaving consumption of that flag to Stage B of `CreatePrimaryAdmin.ps1` after the first interactive logon.

`SetupComplete.cmd` does not delete a pre-existing `%WINDIR%\Panther\_needs_reboot.flag` on entry; it logs a WARN when the flag already exists and preserves it as a sticky pending reboot marker.

**Constraints.** `SetupComplete.cmd` must not call `shutdown.exe`. When servicing returns `0`, the script continues without requesting a reboot. When servicing returns `3010/1641` or when `ALWAYS_REBOOT_AFTER_FIRST_LOGON=1` is set, it writes the Panther flag, sets `NEEDS_REBOOT=1`, and leaves the actual reboot to Stage B of `CreatePrimaryAdmin.ps1`. In the normal path, when Stage B succeeded and the Panther flag exists, Stage B runs a tri-state pending reboot check (`state=true|false|unknown`, with `true` taking precedence if any reasons exist even if probe errors exist) and then either performs the controlled shutdown (`state=true` or `state=unknown`, conservative) or clears the flag without reboot (`state=false`, stale). Pending reboot indicators are registry markers under Component Based Servicing, Windows Update, Session Manager `PendingFileRenameOperations`/`PendingFileRenameOperations2`, and `HKLM\SOFTWARE\Microsoft\Updates\UpdateExeVolatile`. In recovery mode or when Stage B fails, no automatic reboot occurs and the flag can remain for manual diagnostics.

---

## 3A. Contract between files

* `Autounattend.xml`: without `FirstLogonCommands`, without `ProductKey`; `ComputerName=*`, `TimeZone=Romance Standard Time`, `InstallToAvailablePartition=false`; `specialize` includes a single `RunSynchronous` command `cmd /c "%WINDIR%\Setup\Scripts\PreOOBE.cmd"`. en-US locales in WinPE and oobeSystem.

* `SetupComplete.cmd`: all post install work (DISM, policies, services, tasks), detailed logging, a platform gate for LTSC 2021, idempotent behavior, and, when required, computation of `NEEDS_REBOOT` and writing the Panther flag.

---

## 6A. Table for migrating settings out of XML

- **Pre-OOBE delivery:** `PreOOBE.cmd` is **embedded** into `install.wim` at `Windows\Setup\Scripts\`, and is invoked from unattend (`specialize`/`RunSynchronous`).

| Function               | Before (XML) | Now (SetupComplete) | How it is performed |

|-----------------------|--------------|-------------------------|-----------------|

| IE First Run policy   | FirstLogon   | SetupComplete           | `reg add ... DisableFirstRunCustomize=1` |

| Disable IE feature | FirstLogon   | SetupComplete           | `DISM /Disable-Feature` with a pre-check |

| WMP/XPS/Fax/Scan/PSR  | FirstLogon   | SetupComplete           | `DISM /Disable-Feature` |

| Work Folders          | FirstLogon   | SetupComplete           | `DISM /Disable-Feature` |

| RDC Infrastructure    | FirstLogon   | SetupComplete           | `DISM /Disable-Feature` |

| Edge hardening | Various places | SetupComplete           | EdgeUpdate policies (UpdateDefault=0, optional InstallDefault=0); no uninstall |

| Telemetry/WER        | Various places | SetupComplete           | Policies, services, tasks |

| Delivery Optimization | Various places | SetupComplete           | DO policies (Mode 0) |

| `Panther flag` reboot signal | —            | SetupComplete           |`%REBOOT_FLAG%` → `Panther flag` (written when servicing RC is `3010/1641` or `ALWAYS_REBOOT_AFTER_FIRST_LOGON=1`, and preserved as sticky when pre-existing; Stage B of `CreatePrimaryAdmin.ps1` consumes the flag in normal mode and may clear it as stale when no pending reboot indicators exist)|

---

## 6B. OOBE profile and XML invariants

* No auto-created user and no autologon.

* MSA online screens are hidden; the local path is available.

* `ComputerName=*`, `TimeZone=Romance Standard Time`.

* `InstallToAvailablePartition=false`, manual partitioning.

* en-US locales in WinPE and oobeSystem.

---

## 6C. Quality rules

* All DISM operations include a pre-check and logging.

* Scripts are idempotent; rerunning them is safe.

* `SetupComplete.cmd` never performs a direct reboot and never calls `shutdown.exe`; it only decides whether a reboot is required and signals that via the Panther flag.

## 1. Objectives and principles

* Build a clean, quiet, predictable Windows 10 LTSC 2021 workstation profile.

* Minimal background activity and minimal telemetry.

* Official tools only: Group Policies and Registry under HKLM, DISM Features & Capabilities, Scheduled Tasks. No hacks, no unsupported tricks.

* Deterministic and idempotent execution. Safe to re-run without harmful side effects.

* No reboots occur inside SetupComplete. Stage B of `CreatePrimaryAdmin.ps1` is the only unattended component that consumes the `Panther flag`, and a single controlled reboot only happens when Stage B succeeded in the normal path and the flag exists (servicing RC `3010/1641` or `ALWAYS_REBOOT_AFTER_FIRST_LOGON=1`). When the flag is present but no pending reboot indicators exist, Stage B clears it as stale without reboot. In recovery mode or when Stage B fails, no automatic reboot is triggered and the Panther flag may remain as a marker for manual follow-up.

* Primary admin password is an external secret: Stage A of `CreatePrimaryAdmin.ps1` never invents or derives it. `SetupComplete.cmd` validates the password from `%WINDIR%\Setup\Scripts\.primaryadmin.pw` and registers Stage B without embedding secrets; Stage A reads the same file directly under SYSTEM. On the normal path Stage B deletes both `.bootstrap.pw` and `.primaryadmin.pw`; in recovery they are preserved for another Stage A attempt.

---

## 2. Installation flow

1. Install from media with `Autounattend.xml` (en-US defaults, accept EULA, correct image index, OOBE flows toward local account creation). The `windowsPE` pass selects the OS by `/IMAGE/INDEX=1` and sets `<UserData><AcceptEula>true</AcceptEula>` so the LTSC vs LTSC N picker and the license terms screen never appear; if you use media with a different WIM layout, adjust the index explicitly instead of relying on the image name.

2. After OOBE completes, Windows executes `SetupComplete.cmd` as SYSTEM. In addition to servicing and hardening, `SetupComplete.cmd`:
   * reads `%WINDIR%\Setup\Scripts\.bootstrap.pw` (generated earlier by `BootstrapLocalAdmin.ps1`) and `%WINDIR%\Setup\Scripts\.primaryadmin.pw` (operator-supplied secret for the primary admin);
   * validates the primary admin password read via `set /p` (first line only, must be non-empty as read, allowed character set only);
   * only when both secrets are present and valid and the script has not failed, registers the `\L2C\CreatePrimaryAdmin` executor task first and then primes AutoAdminLogon for `bootstrap` (if any priming sub-step fails after task creation it rolls back Winlogon autologon-related values and attempts best-effort deletion of the task); Stage A reads `.primaryadmin.pw` directly under SYSTEM;
   * if the primary admin secret is missing or invalid, or if `FAILED=1`, logs the condition, rolls back any temporary logon tweaks to safe values, and does not configure autologon or the scheduled task.

3. All post-install configuration runs once, with detailed logging and guarded checks. Reboot requirement is computed from the current run's servicing results and `ALWAYS_REBOOT_AFTER_FIRST_LOGON`, and a pre-existing `%WINDIR%\Panther\_needs_reboot.flag` is preserved as a sticky pending reboot marker; the script does not scan older `SetupComplete.log` content for prior `3010/1641` markers.

4. Post-install configuration completes. `SetupComplete.cmd` writes the `Panther flag` when servicing returned `3010/1641` or when `ALWAYS_REBOOT_AFTER_FIRST_LOGON=1` is set; if a pre-existing flag is detected, it is preserved as a sticky pending reboot marker. In all other cases the flag is not created and no reboot is requested.
   If `SetupComplete.cmd` writes `%WINDIR%\Panther\_needs_reboot.flag` but Stage B was not scheduled (for example, when the gate is closed or task creation fails), `SetupComplete.log` logs `WARN_REBOOT_FLAG_NO_EXECUTOR` with marker/value/executor_task (plus machine-readable `skipped_gate` / `not_scheduled`) and the operator instruction that automatic reboot will NOT happen; manual reboot required after fixing gate or scheduling; then rerun pipeline. Example:
   `[WARN] WARN_REBOOT_FLAG_NO_EXECUTOR Reboot required, but Stage B executor task is unavailable, automatic reboot will NOT happen. marker=%WINDIR%\Panther\_needs_reboot.flag (value=need-reboot). executor_task=\L2C\CreatePrimaryAdmin (skipped_gate=1 not_scheduled=1). Manual reboot required after fixing gate or scheduling, then rerun pipeline.`
   value may be need-reboot or force-reboot.
   SetupComplete may write a standalone `%ProgramData%\l2c_master_<timestamp>.log` entry with a single `[timestamp] WARN_REBOOT_FLAG_NO_EXECUTOR ...` line for centralized triage; this is diagnostic only and does not change control flow or reboot behavior.
   In the normal path, when Stage B succeeded and `%WINDIR%\Panther\_needs_reboot.flag` exists, Stage B logs a pending reboot check with state/reasons/errors (Example: `Pending reboot check: state=<true|false|unknown> reasons=<...> errors=<...>`) and then: `state=true` consumes the flag and reboots, `state=false` treats the flag as stale and clears it without reboot, `state=unknown` logs a WARN and reboots conservatively (policy-driven, recorded in the master log). State precedence: `true` if any reasons exist even if errors exist; `unknown` only if no reasons but probe errors exist; `false` only if no reasons and no errors.

5. First interactive sign-in happens. The SYSTEM scheduled task `\L2C\CreatePrimaryAdmin` runs `CreatePrimaryAdmin.ps1`, which always executes Stage B once after Stage A and chooses between a normal and a recovery path based on Stage A’s outcome and internal validation. Stage A of `CreatePrimaryAdmin.ps1` always reads the secret from `.primaryadmin.pw` under SYSTEM and never falls back to other sources; if the secret is missing or invalid, Stage A fails closed and Stage B runs in recovery. In the normal path, Stage B performs its cleanup and, if the Panther flag exists and Stage B completed successfully, it logs a pending reboot check with state/reasons/errors (Example: `Pending reboot check: state=<true|false|unknown> reasons=<...> errors=<...>`) and then: `state=true` consumes the flag and performs a single controlled `shutdown.exe /r /t 0`; `state=false` treats the flag as stale and clears it without reboot; `state=unknown` logs a WARN and reboots conservatively (policy-driven, recorded in the master log). State precedence: `true` if any reasons exist even if errors exist; `unknown` only if no reasons but probe errors exist; `false` only if no reasons and no errors. In recovery mode or when Stage B fails, Stage B performs as much cleanup as possible, logs any Panther flag, does not reboot automatically, and leaves the flag in place for operator diagnostics.

## 3. File layout and key paths

* Unattended answer file (canonical in this repo; place on installation media root)

  `Autounattend.xml` on installation media root.

* Pre-OOBE script inside image

  `%WINDIR%\Setup\Scripts\PreOOBE.cmd`

* SetupComplete script location on media

  `\sources\$OEM$\$$\Setup\Scripts\SetupComplete.cmd`

* Companion PowerShell helpers

  `%WINDIR%\Setup\Scripts\BootstrapLocalAdmin.ps1`, `%WINDIR%\Setup\Scripts\CreatePrimaryAdmin.ps1`

PreOOBE.cmd (specialize) invokes BootstrapLocalAdmin.ps1. PreOOBE does not touch Winlogon/Passwordless/Tasks.

* Password source files inside the image

  `%WINDIR%\Setup\Scripts\.bootstrap.pw` – bootstrap account password, generated by `BootstrapLocalAdmin.ps1` at PreOOBE time.

  `%WINDIR%\Setup\Scripts\.primaryadmin.pw` – primary local admin password, provided by the operator (UTF-8 without BOM, one non-empty line, restricted character set).

  Both files are deleted by Stage B on the normal path and preserved only when Stage B enters the recovery path.

**SetupComplete.cmd:** servicing/logging and bootstrap/admin pipeline priming; never calls `shutdown.exe`. It computes whether a reboot is required and writes the Panther `_needs_reboot.flag` when needed. When `%WINDIR%\Setup\Scripts\.bootstrap.pw` and `%WINDIR%\Setup\Scripts\.primaryadmin.pw` are present and valid and the script has not failed, it configures temporary Winlogon settings, primes AutoAdminLogon for `bootstrap`, and registers the `\L2C\CreatePrimaryAdmin` task without embedding passwords, relying on Stage A to read `.primaryadmin.pw` under SYSTEM. Stage B of `CreatePrimaryAdmin.ps1` is responsible for consuming or clearing the flag (tri-state pending reboot check: `true`/`false`/`unknown`) and performing the single controlled reboot on the normal path after the first interactive logon when appropriate.

When `FAILED=1` (gate closed or task creation fails), `SetupComplete.cmd` logs recovery mode, skips autologon/task registration, but still completes servicing/hardening and reboot-flag evaluation.

* **EOL:** scripts (.cmd/.ps1) - CRLF; documentation (.md) - LF.

* Runtime logs (review in this order)

  1. `%WINDIR%\Panther\PreOOBE.log`

  2. `%WINDIR%\Panther\SetupComplete.log`

  3. `%WINDIR%\Logs\DISM\SetupComplete-DISM.log`

  4. `%ProgramData%\l2c_master_<timestamp>.log`

  `PreOOBE.cmd` redirects stdout+stderr from `BootstrapLocalAdmin.ps1` into `%WINDIR%\Panther\PreOOBE.log`; `BootstrapLocalAdmin.ps1` emits structured `[BOOTSTRAP] [INFO|WARN|ERROR] ...` lines for bootstrap lifecycle steps without ever logging the password itself.

  The Stage B master log aggregates Stage A/B steps, secret cleanup states, and Panther flag handling, including whether the reboot flag was consumed for reboot, cleared as stale, or suppressed.

* Script header in `SetupComplete.cmd` (compact):

  ```bat

  @echo off

  REM SPDX-License-Identifier: MIT

  REM Copyright (c) 2025 tagor-sian

  REM Source: https://github.com/tagor-sian/win10-ltsc-2021-clean-quiet-baseline

  REM Project: Windows 10 LTSC 2021 - Clean & Quiet Baseline (Official Tools Only)

  setlocal EnableExtensions

  set "LOG=%WINDIR%\Panther\SetupComplete.log"

  set "FAILED=0"

  goto :main

  ```

---

## 4. Logging and idempotence

* A dedicated `:log` subroutine writes timestamped lines into `%WINDIR%\Panther\SetupComplete.log`.

* Timestamp generation uses PowerShell (`Get-Date -Format o`), falling back to `%DATE% %TIME%` only if PowerShell fails.

* Each step logs `[SECTION]` and `[STEP]`. Warnings and errors include numeric return codes.

* `reg add` operations use the `:regadd` helper and log per-entry success or failure.

* DISM calls flow through `:run_dism`/`:track_rc`; once `DISM_HARD_FAIL` is set, further DISM feature/capability calls are skipped for the rest of the run.

* The script aggregates a final exit code: `FINAL_RC=L2C_FIRST_BAD_RC` if set, else `FINAL_RC=1` when `FAILED=1`, else `FINAL_RC=0`; it logs `[RC] returning %FINAL_RC%` before exiting, and never forces a reboot inside SetupComplete.

* Installers are invoked with reboot suppression: **MSI** via `REBOOT=ReallySuppress /norestart`; **EXE** with an equivalent `/norestart` switch to avoid reboots inside SetupComplete.

* **Unattend hygiene:** operator hygiene only; remove `%WINDIR%\Panther\Unattend.xml` and `%WINDIR%\Panther\UnattendGC\*.xml` if required by policy (the scripts do not delete them).

---

* **Timestamps:** ISO-8601 in logs via PowerShell (`Get-Date -Format o`).

* **Centralized DISM logging:** every DISM call goes through a runner that appends `/LogPath:%WINDIR%\Logs\DISM\SetupComplete-DISM.log /LogLevel:4`.

* **Return codes:** `3010/1641` mark success with reboot required (set `NEEDS_REBOOT=1` and write the Panther flag). DISM warnings are explicitly whitelisted; other non-zero RCs set `FAILED=1`, and the first fatal code is captured in `L2C_FIRST_BAD_RC` for `FINAL_RC` aggregation.

* **Config flags (defaults):** `LOG_TS_ENGINE=POWERSHELL`, `ALWAYS_REBOOT_AFTER_FIRST_LOGON=0`.

## 5. Platform gate

* The script validates it runs on Windows 10 Enterprise 2021 LTSC:

  * `EditionID=EnterpriseS`

  * `DisplayVersion=21H2`

  * `CurrentBuild >= 19044`

See section **5.1** below for details and a sample verification snippet.

---

**Mismatch policy (clarified):**

- **Edition** or **Build** mismatch → log **ERROR**, set `FAILED=1`, and jump to the shared final RC tail so `[RC] returning <code>` is still logged.

- **DisplayVersion** mismatch → behavior is controlled by `STRICT_DISPLAYVERSION`:

  - `1` → log **ERROR**, set `FAILED=1`, and jump to the shared final RC tail;

  - `0` → log **WARN** and **continue** (best‑effort).

### 5.1 Platform gate - details and code

```bat

if /i not "%ED%"=="%REQUIRED_EDITION%" (
  call :log "[ERROR] EditionID=%ED% (expected %REQUIRED_EDITION%). Aborting."
  set "FAILED=1"
  goto :l2c_final_rc
)

for /f "tokens=1" %%# in ("%CB%") do set /a BUILD=%%#

if %BUILD% LSS %MIN_BUILD% (
  call :log "[ERROR] CurrentBuild=%CBN% (expected >= %MBN%). Aborting."
  set "FAILED=1"
  goto :l2c_final_rc
)

if /i not "%DV%"=="%REQUIRED_DV%" (
  if "%STRICT_DISPLAYVERSION%"=="1" (
    call :log "[ERROR] DisplayVersion=%DV% (expected %REQUIRED_DV%). Aborting."
    set "FAILED=1"
    goto :l2c_final_rc
  ) else call :log "[WARN] DV mismatch; proceeding"
)

```

Platform gate failures now flow through the same final RC aggregation block as servicing and other failures: `SetupComplete.cmd` computes `FINAL_RC` (preferring `L2C_FIRST_BAD_RC`, otherwise `1` when `FAILED==1`, else `0`), logs `[RC] returning %FINAL_RC%`, and exits with that code. This guarantees a single observable end marker for operators and CI even when the platform is unsupported.

## 6. Major decisions and rationale

### 6.1 Microsoft Edge

* Control Edge via **supported policies** only:

  - `HKLM\SOFTWARE\Policies\Microsoft\EdgeUpdate\UpdateDefault=0`

  - (optional) `InstallDefault=0` to block new channel installs.

* Suppress the Edge first run experience via policy: `HKLM\SOFTWARE\Policies\Microsoft\Edge\HideFirstRunExperience=1` so that launching Edge on the initial login does not show the interactive wizard.

* Do **not** remove Edge binaries and do **not** disable scheduled tasks by default. Those tactics are brittle across updates and are unnecessary when policies control updates/installs.

* Rationale: supported, predictable, and update-resilient behavior.

### 6.2 SmartScreen and Windows Defender

* SmartScreen is disabled for Explorer and for Edge as per profile requirements.

* Windows Defender is minimized using supported preferences:

  * No cloud protection and no sample submissions.

  * Real-time, IOAV, behavior monitoring, and PUA features are off as per this baseline.

  * We do not attempt to bypass Tamper Protection.

* If later a local-only PUA detection is desired, `PUAProtection=1` can be considered. Current baseline uses `0`.

### 6.3 Telemetry, Diagnostics, and WER

* Enterprise-allowed diagnostics level: `AllowTelemetry=0`.

* Feedback, CEIP, diagnostics, and Windows Error Reporting are disabled via policies and tasks.

* `WerSvc` is disabled. Tasks under Diagnostics and WER are disabled with soft handling if missing.

### 6.4 Delivery Optimization

* Delivery Optimization is set to HTTP-only:

  * `HKLM\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization\DODownloadMode=0`

* Rationale: quiet online baseline with no P2P. Mode 0 is supported and reliable across LTSC. Mode 99 (Simple) is more restrictive and typically used for air-gapped scenarios, which is outside this baseline.

### 6.5 Network quieting: WPAD, WinHTTP, LLMNR, IPv6 transition

* WPAD disabled on both stacks:

  * WinINET policy: `HKLM\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\Internet Settings\DisableWpad=1`

  * WinHTTP key: `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\WinHttp\DisableWpad=1`

  * Reset WinHTTP proxy to direct:

    ```

    netsh winhttp reset proxy

    ```

* We do not disable the WinHttpAutoProxySvc service because it can break Windows Update and other WinHTTP clients in proxied or complex network environments. The keys above are the supported and sufficient control plane.

* LLMNR disabled:

  * `HKLM\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient\EnableMulticast=0`

* IPv6 transition technologies disabled if present:

  * `netsh interface teredo set state disabled`

  * `netsh interface 6to4 set state disabled`

  * `netsh interface isatap set state disabled`

### 6.6 OneDrive

* Block the Next Gen Sync Client via policy:

  - `HKLM\SOFTWARE\Policies\Microsoft\Windows\OneDrive\DisableFileSyncNGSC=1`

* Do **not** uninstall the client by default; policy-based disablement is idempotent and survives updates.

### 6.7 Services

* Disabled services with guarded checks:

  * `SysMain`, `WSearch`, `Spooler`, `DiagTrack`, `dmwappushsvc`, `WerSvc`, `WebClient`

* Nonexistent services are logged as info and do not count as failures.

### 6.8 Features and Capabilities

* SMBv1 and PowerShell 2.0 are disabled only if they are enabled, using DISM with no restart.

* Capabilities are removed with correct return code handling:

  * Quick Assist:

    ```

    dism /online /remove-capability /capabilityname:App.Support.QuickAssist~~~~0.0.1.0

    ```

  * SNMP Client:

    ```

    dism /online /remove-capability /capabilityname:SNMP.Client~~~~0.0.1.0

    ```

  * WMI SNMP Provider:

    ```

    dism /online /remove-capability /capabilityname:WMI-SNMP-Provider~~~~0.0.1.0

    ```

* DISM return codes are interpreted precisely:

  * `0` success

  * `3010` success, restart required

  * `1641` success, restart initiated by servicing stack

* Output is appended to the script log for diagnostics.

### 6.9 Windows Update

* Notify-only updates:

  * `AUOptions=2`

* Exclude drivers from quality updates:

  * `ExcludeWUDriversInQualityUpdate=1`

* No preview builds:

  * `ManagePreviewBuilds=1`, `ManagePreviewBuildsPolicyValue=1`

* No other Microsoft products:

  * `AllowMUUpdateService=0`

* Block OS upgrade offers:

  * `DisableOSUpgrade=1`

* Device metadata from Internet is off to reduce background network noise.

### 6.10 UX tweaks

* Autorun and AutoPlay disabled.

* Fast Startup disabled.

* File Explorer quick access recent and frequent items disabled.

* Power plan "Ultimate Performance" activated if it exists.

### 6.11 Component cleanup and reboot

* **Component Store:** the baseline pipeline does **not** run `DISM /Online /Cleanup-Image /StartComponentCleanup` or `/ResetBase` during PreOOBE → SetupComplete → CreatePrimaryAdmin.

* **Rationale:** on a fresh LTSC image without cumulative updates, and with multiple DISM servicing operations on the first boot, online component cleanup tends to hit CBS pending operations (for example `0x800F0806`) and does not provide meaningful benefit. WinSxS cleanup (including any use of `/ResetBase`) is considered a separate, post-install or operator-driven maintenance task outside the scope of this project.

* **Reboot handling:** never reboot inside `SetupComplete`. If servicing returns `3010` or `1641`, or when `ALWAYS_REBOOT_AFTER_FIRST_LOGON=1` is set, `SetupComplete.cmd` sets `NEEDS_REBOOT=1` and writes the Panther flag; if a pre-existing flag is found, it is logged and treated as a sticky pending reboot marker (`NEEDS_REBOOT=1`). Stage B of `CreatePrimaryAdmin.ps1` is the only component that acts on the flag after the first interactive logon. In the normal path, only when Stage B succeeded and the flag exists, Stage B runs the tri-state pending reboot check (state precedence: `true` if any reasons exist even if errors exist; `unknown` only if no reasons but probe errors exist; `false` only if no reasons and no errors; indicators: CBS and Windows Update markers, Session Manager `PendingFileRenameOperations`/`PendingFileRenameOperations2`, and `HKLM\SOFTWARE\Microsoft\Updates\UpdateExeVolatile`) and then: `state=true` consumes the flag and reboots, `state=false` clears the stale flag without reboot, `state=unknown` logs a WARN and reboots conservatively. In recovery mode or when Stage B fails, Stage B logs the pending reboot, does not reboot automatically, and the flag may remain for manual follow-up.

## 7. What we explicitly do not do

* Do not disable WinHttpAutoProxySvc. WPAD is controlled by supported keys instead.

* Do not manipulate undocumented Edge services. Policies and tasks are the supported path.

* Do not write under HKCU from SYSTEM context. All configuration is under HKLM or via policies.

* Do not ACL-deny or delete system folders for feature blocking.

* Do not embed reboots inside SetupComplete.

---

## 8. Risks and trade-offs

* SmartScreen disabled and Defender minimized by design. This reduces protection surface and is a conscious trade-off for a silent profile. Consumers of the baseline must understand and accept the risk.

* Operators who choose to run `DISM /ResetBase` post-install should understand it removes rollback for the currently installed updates.

* With WPAD disabled, environments that later introduce a proxy will require explicit WinHTTP proxy configuration.

---

## 9. Verification checklist after install

* Log exists at `%WINDIR%\Panther\SetupComplete.log` with no `[ERROR]`. Warnings are understood.

* Edge policies applied.

* OneDrive sync policy applied.

* Defender preferences applied as per baseline. SmartScreen disabled for Explorer and Edge.

* WPAD disabled on WinINET and WinHTTP. `netsh winhttp show proxy` reports direct access.

* LLMNR disabled. Teredo, 6to4, ISATAP disabled.

* WU UI shows notify behavior. Drivers and other MS products are not offered automatically, and no OS upgrade offers appear.

* Services `SysMain`, `WSearch`, `Spooler`, `DiagTrack`, `dmwappushsvc`, `WerSvc`, `WebClient` are disabled.

* SMBv1 and PowerShell 2.0 are disabled if they were enabled.

* Quick Assist, SNMP Client, and WMI SNMP Provider capabilities are removed or reported not applicable with correct DISM codes.

* Reboot path verified. When the Panther flag is present and Stage B succeeded in the normal path, Stage B performs the tri-state pending reboot check and either reboots (`state=true`/`state=unknown`) or clears the stale flag without reboot (`state=false`); in recovery mode or when Stage B fails, automatic reboot is suppressed. No additional automatic reboots are triggered by SetupComplete.

* `%WINDIR%\Setup\Scripts\.bootstrap.pw` and `.primaryadmin.pw` do not exist on the normal path; if they are present, you are either in a recovery scenario or running the master manually (see README for expected behavior).

---

## 10. Change control and versioning

* Bump `Version:` in script header when behavior changes, not for comment-only edits.

* Any new feature must meet the principles: official tooling, deterministic, idempotent, no reboots inside SetupComplete.

---

We do not append dated addenda; each decision is integrated into its canonical section (flow, logging, servicing, or feature-specific subsections). The git history acts as the chronological record of changes.

## 11. References in repository

* `README.md` - quick start, file placement, how to read the log, minimal how-to.

* `DECISIONS.md` - this document.

* `SECURITY.md` - enumerates security trade-offs and recommended compensating controls if needed.

* `LICENSE` - MIT.

* `Autounattend.xml` - unattended installation.

* `SetupComplete.cmd` - post-install baseline script.

---

## 12. Maintainer

* Maintainer: `@tagor-sian`

  [https://github.com/tagor-sian](https://github.com/tagor-sian)

Contributions are welcome via issues and pull requests. Please keep changes aligned with the principles: official tools only, deterministic and idempotent behavior, and no reboots inside SetupComplete.

## Update (2025-09-19)

**Disk selection:** Use Windows Setup UI intentionally: omit `DiskConfiguration` and `InstallTo*` in `Autounattend.xml`, so Windows Setup prompts the operator to choose the target disk/partition. Rationale: avoid unintended writes on multi-disk hosts; preserve control on prod.

**Policy application timing:** Apply privacy & local-account policies in `specialize` via `Microsoft-Windows-Deployment/RunSynchronous` so they take effect **before OOBE**.

**Privacy scope covered:** Disable Privacy Experience UI; enforce OFF state for diagnostics, tailored experiences, advertising ID, input personalization/online speech, location, find-my-device.

- **Decision:** Critical HKLM policies for OOBE are moved from inline `RunSynchronousCommand` to external `PreOOBE.cmd` (pass `specialize`), invoked by a **single** command. Motivation: XML validity, readability, escaping limits, centralized logging and RC.

## ADR-001: AutoAdminLogon only for the console (Console)

**Date:** 2025-10-02

**Context:** Need a guaranteed local logon after PreOOBE without network/services.

**Decision:** Use the standard `AutoAdminLogon` Winlogon, which works only for a console session.

**Consequences:** In VMConnect **Enhanced** (RDP) there will always be a logon screen — this is expected and not an autologon bug.

## ADR-002: Registry writes via `reg.exe` with explicit types

**Date:** 2025-10-02

**Context:** The PowerShell registry provider in early tests wrote types incorrectly or did not flush before reboot.

**Decision:** Write all Winlogon/policy keys via `reg.exe` with explicit `REG_SZ`/`REG_DWORD`.

**Consequences:** More verbose code, but predictable types and reliability.

Addendum: Direct `reg.exe` call in PS 5.1: `& reg.exe … | Out-Null 2>$null`; read `$LASTEXITCODE`. For `DELETE` acceptable RCs: `{0,2}` (idempotence).

## ADR-003: RNG shim for WinPS 5.1

**Date:** 2025-10-02

**Context:** Windows PowerShell 5.1 lacks `RandomNumberGenerator.Fill`; a strong password is needed without external modules.

**Decision:** Added `Invoke-RngFill` on `RandomNumberGenerator.Create()` and `New-StrongPassword` (≥20 characters, all classes).

**Consequences:** No external dependencies; consistent cryptography on all hosts.

## ADR-004: Idempotence (arm/rollback)

**Date:** 2025-10-02

**Context:** Scripts may be run repeatedly (manual runs, custom builds).

**Decision:** Operations are safe on repeat: allow code 1378 for `Administrators`; delete values silently if absent; exit only when the target state is reached.

**Consequences:** Stable behavior during regressions/reinstalls.

## ADR-005: Idempotent Stage A; guard Stage B

**Date:** 2025-10-15

**Context:** Previous runs of `CreatePrimaryAdmin.ps1` could attempt to re-add a user to Administrators and proceed with Winlogon rollback even when Stage A partially failed.

**Decision:**

- Stage A performs an ADSI membership pre-check and treats `net.exe localgroup` return codes `0` and `1378` as success, logging `A: SKIP (already member)` when no change is needed.

- Stage B (Winlogon rollback, `bootstrap` deactivation) always runs once after Stage A and selects a normal or recovery path based on Stage A’s outcome and internal validation, guarding any automatic reboot behind Stage B success in the normal path.

- Ban `cmd /c` wrappers in Windows PowerShell 5.1; invoke `net.exe` directly to preserve `$LASTEXITCODE` and reduce noise.

**Consequences:**

- Re-running the script is safe: existing Administrators membership is detected, and Stage B can enter a recovery mode after Stage A failures to clean up Winlogon/bootstrap state as far as possible before an operator intervenes.

- Guarding the Panther-flag-based reboot with Stage B success prevents unwanted reboots when account provisioning or cleanup fails, reducing lockout risk while still providing recovery behavior.

## ADR-006: EOL policy (CRLF for scripts, LF for Markdown)

**Date:** 2025-10-13

**Context.** Windows script hosts (`*.ps1/*.cmd/*.bat`) expect CRLF line endings. Markdown and most tooling are LF-friendly. Mixed/incorrect EOLs caused CI and runtime issues.

**Decision.**

- `.ps1/.cmd/.bat` → CRLF via `.gitattributes` and a CI guard (`.github/workflows/eol-guard.yml`).

- `.md` → LF.

- Other text → `* text=auto` (Git attributes).

**Consequences.**

- Deterministic behavior on Windows hosts.

- PRs that introduce LF-only lines in scripts are blocked by CI until fixed.

- Editors should be configured accordingly (see `CONTRIBUTING.md`).

## ADRs – 2025-11

### ADR: No Delayed Expansion in .cmd

- Decision: `EnableDelayedExpansion` is forbidden in `.cmd/.bat`.

- Rationale: escaping pitfalls with `!`, unpredictable parsing in localized environments; simpler RC handling.

- Status: removed from `SetupComplete.cmd`.

### ADR: `.bootstrap.pw` as transient secret

- Decision: use `%WINDIR%\Setup\Scripts\.bootstrap.pw` (UTF-8 without BOM, one line) as a transient password source for the `bootstrap` account only, generated by `BootstrapLocalAdmin.ps1`.

- Rationale: decouple bootstrap account lifecycle from registry; provide a deterministic handoff to Winlogon priming while keeping the secret out of logs and script arguments.

- Security: ACL both password source files (`.bootstrap.pw` and `.primaryadmin.pw`) to `SYSTEM` and local Administrators only via inherited ACL removal, and require Hidden+System attributes. On the normal path Stage B deletes them after a successful run; in recovery they are preserved for another attempt and should be removed manually once no longer needed.

### ADR: `.primaryadmin.pw` as operator-supplied primary admin secret

**Context:** External audits flagged the leak surface from passing the primary admin password through Task Scheduler and PowerShell command lines and warned against any fallback to derived secrets (for example from `.bootstrap.pw`).

**Decision:** Stage A of `CreatePrimaryAdmin.ps1` now reads `%WINDIR%\Setup\Scripts\.primaryadmin.pw` directly under SYSTEM and aborts if the secret is missing or invalid. `SetupComplete.cmd` still validates the operator-managed file (UTF-8, one non-empty line, restricted character set) but registers `\L2C\CreatePrimaryAdmin` without password arguments so the task XML and process command line contain no secrets. Neither script generates or persists the primary admin password beyond Stage B; both password files are deleted on the normal path and preserved only in recovery. This shrinks the leak surface and aligns with audit expectations.

**Status:** adopted in `SetupComplete.cmd` and `CreatePrimaryAdmin.ps1`; documented in `README.md` and `SECURITY.md`.

## [2025-11-12] Harden bootstrap/admin provisioning chain (SetupComplete / BootstrapLocalAdmin / CreatePrimaryAdmin)

### Context

- Capability removal in `SetupComplete.cmd` relied on `dism /Online /Get-Capabilities | findstr "Installed"` which breaks on non-English output.
- Winlogon autologon flipped `AutoAdminLogon`/`ForceAutoLogon` even if the PowerShell write of `DefaultPassword` failed, leaving a stuck autologon without credentials.
- `schtasks /Create \L2C\CreatePrimaryAdmin` was not tracked via `:track_rc`, so failures could be invisible to L2C_FIRST_BAD_RC and exit codes even when task creation failed.
- Stage B of `CreatePrimaryAdmin.ps1` cleaned Winlogon, the scheduled task, and `.bootstrap.pw`, but many failure paths only emitted DEBUG/WARN entries and did not encode the cleanup result for later tooling.
- `.bootstrap.pw` ACLs were recreated using localized “Administrators” names instead of translating the Administrators SID, leaving room for locale regressions.

### Decision

- `SetupComplete.cmd` now probes capability state via `dism /Online /Get-CapabilityInfo /CapabilityName:<cap> /English` with output captured to a temp file and parsed for the `State :` line (no `dism | findstr` pipelines, so DISM return codes are preserved).
- Fatal probe RCs set `FAILED=1` + `:track_rc` (and `DISM_HARD_FAIL=1`); a missing/unparsable `State :` line logs `[WARN]` and skips removal.
- Capability removal only runs for known states (`Installed`, `Staged`); other states log explicit skip reasons rather than silently continuing.
- Winlogon autologon switches are configured only if the `DefaultPassword` PowerShell call returns RC=0; on error the script logs `[ERROR]`, sets `FAILED=1`, and leaves autologon off.
- `schtasks /Create \L2C\CreatePrimaryAdmin` always captures `%ERRORLEVEL%`, logs failures with `[ERROR]`, calls `:track_rc`, and sets `FAILED=1`.
- Final RC policy: `SetupComplete.cmd` returns `L2C_FIRST_BAD_RC` if set; otherwise it returns `1` when `FAILED==1`, else `0`. Each path logs the specific `[RC] returning ...` line.
- `BootstrapLocalAdmin.ps1` resolves the Administrators group via SID `S-1-5-32-544`, reuses the translated `NTAccount` for both `net localgroup` and ACLs, and replaces inherited ACLs on `.bootstrap.pw` with only SYSTEM + Administrators FullControl inside a guarded `try` block.
- `SetupComplete.cmd` reads `%WINDIR%\Setup\Scripts\.bootstrap.pw` and `%WINDIR%\Setup\Scripts\.primaryadmin.pw`, validates the primary admin password read via `set /p` (first line only, must be non-empty as read; empty first line is rejected, allowed character set only), and only when both secrets are present and valid and the script has not failed, it applies temporary Winlogon policies for AutoAdminLogon, configures AutoAdminLogon for `bootstrap` using the secret from `.bootstrap.pw`, and registers the `\L2C\CreatePrimaryAdmin` task without embedding any password arguments so that secrets do not appear in Task Scheduler or process command lines. If the primary admin secret is missing or invalid, or if `FAILED=1`, it logs the condition, rolls back temporary logon tweaks to safe values, and does not configure autologon or the scheduled task.
- Stage A of `CreatePrimaryAdmin.ps1` reads `.primaryadmin.pw` directly under SYSTEM and never uses `.bootstrap.pw` or command-line parameters for the password. In this baseline the operator-supplied file is the sole source; missing or invalid secrets abort Stage A and force Stage B into recovery.
- Stage B of `CreatePrimaryAdmin.ps1` now:
  - Deletes `DefaultUserName`, `DefaultDomainName`, and `DefaultPassword`, and resets `AutoAdminLogon`, `ForceAutoLogon`, and `AutoLogonCount`.
  - Verifies post-action that Winlogon is sanitized (treats read errors as failure); if verification fails, Stage B hard-fails and refuses to teardown the `bootstrap`/`\L2C\CreatePrimaryAdmin` executor path, preserves `.bootstrap.pw` and `.primaryadmin.pw`, and suppresses automatic reboot.
  - Logs `net user bootstrap /active:no` success or WARN with the exact RC.
  - Logs WARN for non-zero RCs from `schtasks.exe /Delete` and still surfaces caught exceptions as WARN.
  - Tracks cleanup state for both `.bootstrap.pw` and `.primaryadmin.pw` in dedicated variables, logs `removed`/`missing`/`error`/`preserved` states for each, and records the resulting state in the Stage B master log summary.

### Consequences / Impact

- Capability removal is locale-agnostic and reports failures through `[ERROR]` + non-zero exit codes, enabling CI/ops to detect servicing regressions.
- `SetupComplete.cmd` now propagates the first failing RC or a generic FAILED fallback, so monitoring and deployment tooling can rely on exit codes instead of tailing logs.
- Winlogon autologon now has an all-or-nothing contract: either the password write succeeds and autologon is primed, or autologon stays off with explicit error logging.
- `.bootstrap.pw` is guaranteed to be ACLed with only SYSTEM and local Administrators; any deviation aborts bootstrap rather than silently weakening protections.
- Stage B produces deterministic post-bootstrap state (Winlogon, scheduled tasks) and emits machine-readable entries for `.bootstrap.pw` cleanup, improving forensic and automation coverage.
- Both `.bootstrap.pw` and `.primaryadmin.pw` are guaranteed to be ACLed with only SYSTEM and local Administrators; failures to enforce ACLs or to read/validate the primary admin password abort bootstrap rather than silently weakening protections.
- Operators can treat WARN/ERROR patterns (missing password file, task delete RC, etc.) as actionable signals without guessing whether the cleanup actually ran.

### Follow-ups / References

- `SECURITY.md` documents `.bootstrap.pw` and `.primaryadmin.pw` handling requirements and must be updated first if future changes relax ACL expectations.
- `AGENTS.md` continues to enforce locale-agnostic DISM usage, RC policy, SID-based admin resolution, and strict password source file cleanup/logging for any future edits to these scripts.
- `AGENTS.md` also documents the DISM return-code classification (success, reboot, LTSC warning whitelist, fatal) and the FINAL_RC aggregation model for SetupComplete.cmd.

## ADR-007: DISM RC classification and FINAL_RC aggregation

**Date:** 2025-11-23

**Context:** Treating every non-0/3010/1641 DISM return code as fatal caused false failures on LTSC images where optional features (for example Fax/Scan/PSR/Remote Assistance) are missing or non-selectable. SetupComplete.cmd aborted even though the component store was healthy and the hardening intent was satisfied.

**Decision:**

- Whitelist two DISM warning codes and treat them as non-fatal:
  - -2146498548 / 2148468748 (“feature not recognized in this image”).
  - -2146498541 / 2148468755 (“invalid install state for this feature”).
  For these codes, `:run_dism` logs a warning, sets `HAS_DISM_WARN=1`, and does not set `DISM_HARD_FAIL`.
- All other DISM return codes outside `{0, 3010, 1641}` and the warning whitelist remain fatal. `:run_dism` logs an error, sets `FAILED=1` and `DISM_HARD_FAIL=1`, and `:track_rc` captures the first fatal code in `L2C_FIRST_BAD_RC`. Once `DISM_HARD_FAIL` is set, subsequent DISM feature/capability/cleanup calls are skipped for the rest of the run.
- Treat `3010` and `1641` as non-fatal “reboot required” outcomes (success with reboot required). They do not set `DISM_HARD_FAIL` and are not part of the warning whitelist.
- The warning whitelist is intentionally narrow (only the two codes above); expanding it requires operator investigation and explicit documentation updates. In `SetupComplete.cmd`, Stage B scheduling is gated on `FAILED=0`. Any DISM hard-fail that sets `FAILED=1` therefore prevents Stage B scheduling in that run (fail-closed).
- At the end of `SetupComplete.cmd`, the script aggregates a final exit code: if `L2C_FIRST_BAD_RC` is set, `FINAL_RC=L2C_FIRST_BAD_RC`; otherwise, if `FAILED==1`, `FINAL_RC=1`; otherwise, `FINAL_RC=0`. The script logs “[RC] returning %FINAL_RC%” and exits with that code.

**Consequences:**

- Clean LTSC images where certain optional features are not present or not selectable no longer fail `SetupComplete.cmd` purely because of benign DISM warnings; these conditions remain visible in the log via explicit warning entries and `HAS_DISM_WARN=1`.
- Truly fatal servicing problems still produce a non-zero `FINAL_RC`, trip `DISM_HARD_FAIL`, and stop further feature/capability/cleanup calls, which makes the first failing DISM call and its RC easy to identify in the logs.
- CI pipelines and operators can rely on `FINAL_RC` together with the DISM log classification (success, whitelisted warning, fatal) as the primary signal for pass/fail, instead of guessing from raw DISM return codes alone.

## ADR-008: Hardened secrets and a fail-closed Stage B gate

**Date:** 2025-12-02

**Context:** We must run Stage B exactly once under a temporary bootstrap autologon without leaking passwords into task definitions or command lines. Weak ACLs or malformed secrets previously risked half-primed autologon states or unattended primary-admin creation with an unverified password.

**Decision:**

- Maintain two secrets under `%WINDIR%\Setup\Scripts`: `.bootstrap.pw` (generated by `BootstrapLocalAdmin.ps1` for the temporary `bootstrap` account) and `.primaryadmin.pw` (operator-supplied for `primaryadmin`). Both are single-line UTF-8 (no BOM) files with inheritance disabled, explicit FullControl ACEs only for `NT AUTHORITY\SYSTEM` (S-1-5-18) and the local Administrators group (S-1-5-32-544), and Hidden + System attributes.
- `ValidateSecrets.ps1` runs in the `SetupComplete.cmd` gateway after DISM feature/capability servicing and before the Panther reboot-flag evaluation, verifies the ACL/attribute shape of both files without reading passwords, and returns a 0–3 exit-code bitmask (bit0=bootstrap secret valid, bit1=primary admin secret valid); `SetupComplete.cmd` decodes `%ERRORLEVEL%` into `L2C_BOOTSTRAP_PW_ACL_OK` and `L2C_PRIMARYADMIN_PW_ACL_OK` instead of parsing stdout.
- `SetupComplete.cmd` requires `.bootstrap.pw` to exist and be non-empty, and `.primaryadmin.pw` to exist, pass the ACL/attribute check, and be readable with the allowed character set. A single gate (FAILED=0 plus both secrets validated and loaded) controls temporary logon policy relaxation, Winlogon priming for `bootstrap` (`DefaultUserName`/`DefaultDomainName`/`DefaultPassword` read from `.bootstrap.pw`), and registration of the SYSTEM/Highest OnLogon task `\L2C\CreatePrimaryAdmin` without embedding passwords.
- If the gate fails, `SetupComplete.cmd` logs the reason, skips autologon and task creation, and exits in recovery (non-zero RC) rather than leaving partial state.
- Stage A of `CreatePrimaryAdmin.ps1` re-reads `.primaryadmin.pw` under SYSTEM and aborts if it is missing, unreadable, empty, or contains unsupported characters; the password never appears in Task Scheduler definitions, command lines, or logs. Normal Stage B deletes both secrets, removes the task, restores logon policies, disables `bootstrap`, records the Panther flag state in the master log, and applies the tri-state reboot decision when the flag is present (reboot on `state=true`/`state=unknown`, clear as stale on `state=false`); recovery retains the secrets/task for manual review and a later retry. Secret cleanup errors keep `StageB_Succeeded=false` and suppress any automatic reboot even when the flag exists.

**Consequences / Security impact:**

- Secrets live only on disk in hardened files between `SetupComplete.cmd` and the end of Stage B; they never traverse command lines or task XML.
- Any ACL/attribute drift or invalid/missing secret blocks autologon and Stage B, forcing a fail-closed posture with explicit logging.
- The single gate keeps temporary policy relaxation, Winlogon priming, and Stage B scheduling aligned; operators can reason about success/failure from the log without chasing partial configurations.

## ADR-009: Exit-code bitmask replaces stdout parsing for secret validation

**Date:** 2025-12-05

**Context:** Earlier, `ValidateSecrets.ps1` printed `set ...` statements to stdout and `SetupComplete.cmd` parsed them via `for /f ... do call`. That bridge was brittle (locale/encoding dependent) and mingled contract data with free-form output.

**Decision:** `ValidateSecrets.ps1` now encodes its results solely in the process exit code: a 0–3 bitmask where bit0 indicates the bootstrap secret passed ACL/attribute checks and bit1 indicates the primary-admin secret passed, and exit code `4` indicates an internal validator error. The validator runs under `Set-StrictMode -Version Latest` with `$ErrorActionPreference='Stop'` so unexpected conditions surface as errors; internal errors are caught and returned as `4` rather than being mapped to `0`. `SetupComplete.cmd` invokes the validator as a child process, reads `%ERRORLEVEL%`, decodes the bits into `L2C_BOOTSTRAP_PW_ACL_OK` and `L2C_PRIMARYADMIN_PW_ACL_OK`, logs `[SECTION] Secret ACL validation (bootstrap=X, primaryadmin=Y)`, and gates autologon/Stage B registration on both bits being `1`.

**Consequences:**

- The pipeline proceeds only when exit code `3` is returned; any missing/invalid secret keeps the gate closed. An internal validator failure returns `4`, is logged explicitly, sets `FAILED=1`, keeps both ACL flags at `0`, and blocks autologon and Stage B registration.
- The contract remains fail-closed but now differentiates internal errors:
  - `ValidateSecrets.ps1` returns `4` when the validator itself encounters an internal error (for example, unexpected I/O failure or an unhandled exception).
  - `SetupComplete.cmd` treats `RC=4` as a hard validation failure, logs the internal error, sets `FAILED=1`, keeps `bootstrap=0, primaryadmin=0`, and does not register Stage B.
- Operational note: when the gate reports `bootstrap=0, primaryadmin=0` because of `RC` in `0..3`, operators should treat the secrets as unusable and inspect logs; `RC=4` explicitly signals a validator failure and keeps the system in recovery until investigated.
- The exit-code contract is resilient to localization/encoding and keeps stdout available for diagnostics without risking mis-parsed gate data.
- The previous stdout/`for /f` contract is deprecated and removed; future changes to secret validation must keep this exit-code bitmask bridge aligned between `ValidateSecrets.ps1` and `SetupComplete.cmd` and be recorded here before code changes.

## ADR-010: ADSI for primaryadmin password; bootstrap remains native in PreOOBE

**Date:** 2025-12-06

**Context:** Both bootstrap and primaryadmin passwords were previously set via `net.exe user <user> <password> ...`, which surfaces passwords in process command lines and Security 4688 events when command-line logging is enabled.

**Decision:**

For the long-lived `primaryadmin` account:

- The password is applied via the WinNT ADSI provider (`SetPassword` + `SetInfo`) after any `net.exe user ... /add` call that does not include password arguments; no `net.exe user <password>` calls remain.
- When Stage A creates `primaryadmin`, the flow is `net.exe user <PrimaryUser> /add` (no password) → `Set-L2CLocalUserPasswordAdsi` → `net.exe user ... /active:yes`.
- If ADSI password setting fails after a successful `net.exe user <PrimaryUser> /add`, Stage A:
  - logs `Failed to set password via ADSI for <user>: <error>`,
  - attempts rollback via `net.exe user <user> /delete` and logs the delete return code (`Rolled back user ... after password failure (delete rc=...)` or an equivalent delete failure log entry),
  - throws so that Stage A fails closed and forces recovery.
- When the `primaryadmin` account already exists before Stage A, the script only calls `Set-L2CLocalUserPasswordAdsi`. If ADSI fails, Stage A:
  - logs the error,
  - logs `Skipping deletion because <user> existed before this run`,
  - throws; no deletion is attempted for pre-existing accounts.

The temporary `bootstrap` password stays on native OS tooling in PreOOBE because ADSI proved unreliable there; the early-phase exposure is accepted and documented in `SECURITY.md`.

**Consequences:** The `primaryadmin` password no longer appears in process command lines or Security 4688 logs, aligning with audit expectations for the final admin identity. The bootstrap password may still be observable in short-lived command lines or low-level logs during PreOOBE; this is an intentionally accepted, time-bounded risk for a temporary account that is disabled/cleaned up by the end of the pipeline. If `.bootstrap.pw` ACL hardening fails in `BootstrapLocalAdmin.ps1`, the script logs the failure, attempts to delete the secret, and logs whether it was removed, already absent, or failed to delete; when that cleanup leaves the file missing or empty, `ValidateSecrets`/`SetupComplete` decode it as `bootstrap=0`, keep the gate closed, and do not register Stage B. ADSI failures can no longer leave a freshly created `primaryadmin` orphaned with an unset password: the creation is rolled back and recovery mode is entered; for pre-existing `primaryadmin` the account is preserved but the run still fails closed and drops into recovery.
