# Windows 10 LTSC 2021 - Clean & Quiet Baseline (Official Tools Only)

**Status:** Adopted

**Scope:** Windows 10 Enterprise 2021 LTSC (21H2, EditionID=EnterpriseS, build 19044+)

**Repository:** [https://github.com/tagor-sian/win10-ltsc-2021-clean-quiet-baseline](https://github.com/tagor-sian/win10-ltsc-2021-clean-quiet-baseline)

**License:** MIT

**Description:** A lean, predictable Windows 10 LTSC 2021 baseline with minimal background activity and telemetry. Uses official Microsoft mechanisms only (Policies/Registry, DISM Features & Capabilities, Scheduled Tasks, RunOnce). Conservative, no hacks; deterministic and idempotent. Ships the automation scripts (`PreOOBE.cmd`, `SetupComplete.cmd`, PowerShell helpers); deployment answer files are managed separately.

This document records the decisions, rationale, scope boundaries, and verification steps for the baseline. It is the single source of truth for what the project does and why.

The baseline never auto-generates the primary local admin password. Instead it expects the operator to provide a strong password via `%WINDIR%\Setup\Scripts\.primaryadmin.pw`. `SetupComplete.cmd` reads and validates this secret and passes it into `CreatePrimaryAdmin.ps1` as `-PasswordPlain`. Both password source files (`.bootstrap.pw` and `.primaryadmin.pw`) are removed by Stage B on the normal path and preserved only when Stage B enters the recovery path.

---

---

## Process policy: Agent execution model

- Codex CLI is the sole automation agent; its operational rules live in `AGENTS.md` under the “Codex CLI Contract”.
- A full `docs/INTERACTION_CONTRACT.md` will follow in a separate commit to capture the detailed interaction workflow.

## ADR: Fix PS interpolation in CreatePrimaryAdmin ($User: → ${User}:)

- **Context:** Stage A could fail on the message `ADSI update failed for $User:` — PowerShell 5.1 parsed `$User:` incorrectly and aborted during the ADSI update.

- **Decision:** narrowly replace the text with `ADSI update failed for ${User}:` with no other script changes.

- **Consequences:** fatal Stage A stopper removed; run predictability improved.

- **Related:** see “Idempotent Stage A; guard Stage B” about Stage A idempotence and the Stage B guard.

## 2A. Move servicing from XML into SetupComplete

- **Constraint (SKU):** Target **Windows 10 Enterprise LTSC 2021 (EnterpriseS)** or compatible **Enterprise** SKUs. Reason: `AllowTelemetry=0` (Security level) is supported on Enterprise.

**Decision.** All DISM operations and policies (IE/Edge, Delivery Optimization, telemetry, OneDrive, etc.) run in `SetupComplete.cmd`. The `autounattend.xml` stays minimal (`windowsPE`, `generalize`, `specialize`, `oobeSystem` only), with no `FirstLogonCommands`.

**Motivation.** Predictable phases, a single logging point, no races during OOBE, and idempotent behavior. `SetupComplete.cmd` never performs a reboot. Instead, it decides whether a post install reboot is required and signals that decision via `%WINDIR%\Panther\_needs_reboot.flag` (the “Panther flag”), leaving consumption of that flag to Stage B of `CreatePrimaryAdmin.ps1` after the first interactive logon.

**Constraints.** `SetupComplete.cmd` must not call `shutdown.exe` and must not create RunOnce entries for shutdown. When servicing returns `0`, the script continues without requesting a reboot. When servicing returns `3010/1641` or when `ALWAYS_REBOOT_AFTER_FIRST_LOGON=1` is set, it writes the Panther flag, sets `NEEDS_REBOOT=1`, and leaves the actual reboot to Stage B of `CreatePrimaryAdmin.ps1`, which only performs the controlled shutdown when Stage B succeeded in the normal path and the Panther flag exists; in recovery mode or when Stage B fails, no automatic reboot occurs and the flag can remain for manual diagnostics.

---

## 3A. Contract between files

* `autounattend.xml`: without `FirstLogonCommands`, without `RunSynchronous`, without `ProductKey`; `ComputerName=*`, `TimeZone=Romance Standard Time`, `InstallToAvailablePartition=false`. en-US locales in WinPE and oobeSystem.

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

| `Panther flag` reboot signal | —            | SetupComplete           |`%REBOOT_FLAG%` → `Panther flag` (conditionally when servicing RC is `3010/1641` or `ALWAYS_REBOOT_AFTER_FIRST_LOGON=1`; Stage B of `CreatePrimaryAdmin.ps1` consumes the flag)|

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

* Official tools only: Group Policies and Registry under HKLM, DISM Features & Capabilities, Scheduled Tasks, and RunOnce. No hacks, no unsupported tricks.

* Deterministic and idempotent execution. Safe to re-run without harmful side effects.

* No reboots occur inside SetupComplete. Stage B of `CreatePrimaryAdmin.ps1` is the only unattended component that consumes the `Panther flag`, and a single controlled reboot only happens when Stage B succeeded in the normal path and the flag exists (servicing RC `3010/1641` or `ALWAYS_REBOOT_AFTER_FIRST_LOGON=1`). In recovery mode or when Stage B fails, no automatic reboot is triggered and the Panther flag may remain as a marker for manual follow-up.

* Primary admin password is an external secret: Stage A of `CreatePrimaryAdmin.ps1` never invents or derives it. `SetupComplete.cmd` reads the password from `%WINDIR%\Setup\Scripts\.primaryadmin.pw`, validates it, and passes it via `-PasswordPlain`. On the normal path Stage B deletes both `.bootstrap.pw` and `.primaryadmin.pw`; in recovery they are preserved for another Stage A attempt.

---

## 2. Installation flow

1. Install from media with `Autounattend.xml` (en-US defaults, accept EULA, correct image index, OOBE flows toward local account creation). The `windowsPE` pass selects the OS by `/IMAGE/INDEX=1` and sets `<UserData><AcceptEula>true</AcceptEula>` so the LTSC vs LTSC N picker and the license terms screen never appear; if you use media with a different WIM layout, adjust the index explicitly instead of relying on the image name.

2. After OOBE completes, Windows executes `SetupComplete.cmd` as SYSTEM. In addition to servicing and hardening, `SetupComplete.cmd`:
   * reads `%WINDIR%\Setup\Scripts\.bootstrap.pw` (generated earlier by `BootstrapLocalAdmin.ps1`) and `%WINDIR%\Setup\Scripts\.primaryadmin.pw` (operator-supplied secret for the primary admin);
   * validates the primary admin password read via `set /p` (first line only, must be non-empty as read, allowed character set only);
   * only when both secrets are present and valid and the script has not failed, configures temporary Winlogon settings, primes AutoAdminLogon for `bootstrap`, and registers the `\L2C\CreatePrimaryAdmin` task with `-PasswordPlain` set to the validated primary admin password;
   * if the primary admin secret is missing or invalid, or if `FAILED=1`, logs the condition, rolls back any temporary logon tweaks to safe values, and does not configure autologon or the scheduled task.

3. All post-install configuration runs once, with detailed logging and guarded checks.

4. Post-install configuration completes. `SetupComplete.cmd` writes the `Panther flag` only when servicing returned `3010/1641` or when `ALWAYS_REBOOT_AFTER_FIRST_LOGON=1` is set; in all other cases the flag is not created and no reboot is requested.

5. First interactive sign-in happens. The SYSTEM scheduled task `\L2C\CreatePrimaryAdmin` runs `CreatePrimaryAdmin.ps1`, which always executes Stage B once after Stage A and chooses between a normal and a recovery path based on Stage A’s outcome and internal validation. Stage A of `CreatePrimaryAdmin.ps1` always requires a non-empty `-PasswordPlain` and never reads `.bootstrap.pw` or any other password file; in this baseline the parameter is supplied exclusively by `SetupComplete.cmd` from `.primaryadmin.pw`. In the normal path, Stage B performs its cleanup and, if the Panther flag exists and Stage B completed successfully, it logs the requirement, deletes the flag, and performs a single controlled `shutdown.exe /r /t 0`. In recovery mode or when Stage B fails, Stage B performs as much cleanup as possible, logs any Panther flag, does not reboot automatically, and leaves the flag in place for operator diagnostics.

## 3. File layout and key paths

* Unattended answer file (stored outside this repo, delivered with the media)

  `autounattend.xml` on installation media root.

* Pre-OOBE script inside image

  `%WINDIR%\Setup\Scripts\PreOOBE.cmd`

* SetupComplete script location on media

  `\sources\$OEM$\$$\Setup\Scripts\SetupComplete.cmd`

* Companion PowerShell helpers

  `%WINDIR%\Setup\Scripts\BootstrapLocalAdmin.ps1`, `%WINDIR%\Setup\Scripts\CreatePrimaryAdmin.ps1`

PreOOBE.cmd (specialize) invokes BootstrapLocalAdmin.ps1. PreOOBE does not touch Winlogon/Passwordless/RunOnce/Tasks.

* Password source files inside the image

  `%WINDIR%\Setup\Scripts\.bootstrap.pw` – bootstrap account password, generated by `BootstrapLocalAdmin.ps1` at PreOOBE time.

  `%WINDIR%\Setup\Scripts\.primaryadmin.pw` – primary local admin password, provided by the operator (UTF-8 without BOM, one non-empty line, restricted character set).

  Both files are deleted by Stage B on the normal path and preserved only when Stage B enters the recovery path.

**SetupComplete.cmd:** servicing/logging and bootstrap/admin pipeline priming; never calls `shutdown.exe` or schedules reboots via RunOnce. It computes whether a reboot is required and writes the Panther `_needs_reboot.flag` when needed. When `%WINDIR%\Setup\Scripts\.bootstrap.pw` and `%WINDIR%\Setup\Scripts\.primaryadmin.pw` are present and valid and the script has not failed, it configures temporary Winlogon settings, primes AutoAdminLogon for `bootstrap`, and registers the `\L2C\CreatePrimaryAdmin` task with `-PasswordPlain` set to the validated primary admin password. Stage B of `CreatePrimaryAdmin.ps1` is responsible for consuming the flag and performing the single controlled reboot on the normal path after the first interactive logon.

* **EOL:** scripts (.cmd/.ps1) — CRLF; documentation (.md) — LF.

* Runtime logs (review in this order)

  1. `%WINDIR%\Panther\PreOOBE.log`

  2. `%WINDIR%\Panther\SetupComplete.log`

  3. `%WINDIR%\Logs\DISM\SetupComplete-DISM.log`

* Script header in `SetupComplete.cmd` (compact):

  ```bat

  @echo off

  REM SPDX-License-Identifier: MIT

  REM Copyright (c) 2025 tagor-sian

  REM Source: https://github.com/tagor-sian/win10-ltsc-2021-clean-quiet-baseline

  REM Project: Windows 10 LTSC 2021 - Clean & Quiet Baseline (Official Tools Only)

  setlocal EnableExtensions EnableDelayedExpansion

  set "LOGFILE=%WINDIR%\Panther\SetupComplete.log"

  set "FAILED=0"

  goto :main

  ```

---

## 4. Logging and idempotence

* A dedicated `:log` subroutine writes timestamped lines into `%WINDIR%\Panther\SetupComplete.log`.

* Timestamp generation uses PowerShell (`Get-Date -Format o`), falling back to `%DATE% %TIME%` only if PowerShell fails.

* Each step logs `[SECTION]` and `[STEP]`. Warnings and errors include numeric return codes.

* Groups of related `reg add` operations use a local error flag to produce one consolidated warning.

* Single commands use an immediate `if errorlevel 1` handler on the next line.

* The script returns `%FAILED%` at exit, but never forces a reboot inside SetupComplete.

* Installers are invoked with reboot suppression: **MSI** via `REBOOT=ReallySuppress /norestart`; **EXE** with an equivalent `/norestart` switch to avoid reboots inside SetupComplete.

* **Unattend hygiene:** after `SetupComplete` finishes, remove `%WINDIR%\Panther\Unattend.xml` and `%WINDIR%\Panther\UnattendGC\*.xml`.

---

* **Timestamps:** ISO-8601 in logs via PowerShell (`Get-Date -Format o`).

* **Centralized DISM logging:** every DISM call goes through a runner that appends `/LogPath:%WINDIR%\Logs\DISM\SetupComplete-DISM.log /LogLevel:4`.

* **Return codes:** a single handler treats `0` as success; `3010/1641` as success with reboot required (sets `NEEDS_REBOOT=1`); anything else is failure and sets `FAILED=1`.

* **Config flags (defaults):** `LOG_TS_ENGINE=POWERSHELL`, `REBOOT_ON_RC=1`, `ALWAYS_REBOOT_AFTER_FIRST_LOGON=0`.

## 5. Platform gate

* The script validates it runs on Windows 10 Enterprise 2021 LTSC:

  * `EditionID=EnterpriseS`

  * `DisplayVersion=21H2`

  * `CurrentBuild >= 19044`

See section **5.1** below for details and a sample verification snippet.

---

**Mismatch policy (clarified):**

- **Edition** or **Build** mismatch → log **ERROR** and **exit** without changes.

- **DisplayVersion** mismatch → behavior is controlled by `STRICT_DISPLAYVERSION`:

  - `1` → log **ERROR** and **exit**;

  - `0` → log **WARN** and **continue** (best‑effort).

### 5.1 Platform gate - details and code

```bat

if /i not "%ED%"=="%REQUIRED_EDITION%" exit /b 1

for /f "tokens=1" %%# in ("%CB%") do set /a BUILD=%%#

if %BUILD% LSS %MIN_BUILD% exit /b 1

if /i not "%DV%"=="%REQUIRED_DV%" (

  if "%STRICT_DISPLAYVERSION%"=="1" exit /b 1 else call :log "[WARN] DV mismatch; proceeding"

)

```

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

* **Reboot handling:** never reboot inside `SetupComplete`. If servicing returns `3010` or `1641`, or when `ALWAYS_REBOOT_AFTER_FIRST_LOGON=1` is set, `SetupComplete.cmd` sets `NEEDS_REBOOT=1` and writes the Panther flag so that Stage B of `CreatePrimaryAdmin.ps1` can consume it after the first interactive logon. Stage B clears the flag and performs a single controlled reboot only when Stage B succeeded in the normal path and the flag exists; in recovery mode or when Stage B fails, Stage B logs the pending reboot, skips the automatic restart, and leaves the flag as a marker for manual follow-up.

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

* Reboot path verified. When required, the reboot was executed once by Stage B after consuming the Panther flag; no additional automatic reboots are triggered by SetupComplete.

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

* `autounattend.xml` - unattended installation.

* `SetupComplete.cmd` - post-install baseline script.

---

## 12. Maintainer

* Maintainer: `@tagor-sian`

  [https://github.com/tagor-sian](https://github.com/tagor-sian)

Contributions are welcome via issues and pull requests. Please keep changes aligned with the principles: official tools only, deterministic and idempotent behavior, and no reboots inside SetupComplete.

## Update (2025-09-19)

**Disk selection:** Use Windows Setup UI intentionally: set `OSImage/WillShowUI=Always`, omit `InstallTo` and `InstallToAvailablePartition`. Rationale: avoid unintended writes on multi-disk hosts; preserve control on prod.

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

- Stage B (Winlogon and RunOnce rollback, `bootstrap` deactivation) always runs once after Stage A and selects a normal or recovery path based on Stage A’s outcome and internal validation, guarding any automatic reboot behind Stage B success in the normal path.

- Ban `cmd /c` wrappers in Windows PowerShell 5.1; invoke `net.exe` directly to preserve `$LASTEXITCODE` and reduce noise.

**Consequences:**

- Re-running the script is safe: existing Administrators membership is detected, and Stage B can enter a recovery mode after Stage A failures to clean up Winlogon/RunOnce/bootstrap state as far as possible before an operator intervenes.

- Guarding the Panther-flag-based reboot with Stage B success prevents unwanted reboots when account provisioning or cleanup fails, reducing lockout risk while still providing recovery behavior.

## ADR-006: EOL policy (CRLF for scripts, LF for Markdown)

**Date:** 2025-10-13

**Context.** Windows script hosts (`*.ps1/*.cmd/*.bat`) expect CRLF line endings. Markdown and most tooling are LF-friendly. Mixed/incorrect EOLs caused CI and runtime issues.

**Decision.**

- `.ps1/.cmd/.bat` 뿯↽ CRLF via `.gitattributes` and a CI guard (`.github/workflows/eol-guard.yml`).

- `.md` 뿯↽ LF.

- Other text 뿯↽ `* text=auto` (Git attributes).

**Consequences.**

- Deterministic behavior on Windows hosts.

- PRs that introduce LF-only lines in scripts are blocked by CI until fixed.

- Editors should be configured accordingly (see `CONTRIBUTING.md`).

## ADRs – 2025-11

### ADR: Scheduler over RunOnce for primary-admin bootstrap

- Decision: Use `schtasks` (OnLogon, SYSTEM, Highest) to run `CreatePrimaryAdmin.ps1`.

- Rationale: reliability, service isolation, no race with shell init; avoids RunOnce persistence on failures.

- Status: adopted in `SetupComplete.cmd`.

### ADR: No Delayed Expansion in .cmd

- Decision: `EnableDelayedExpansion` is forbidden in `.cmd/.bat`.

- Rationale: escaping pitfalls with `!`, unpredictable parsing in localized environments; simpler RC handling.

- Status: removed from `SetupComplete.cmd`.

### ADR: `.bootstrap.pw` as transient secret

- Decision: use `%WINDIR%\Setup\Scripts\.bootstrap.pw` (UTF-8 without BOM, one line) as a transient password source for the `bootstrap` account only, generated by `BootstrapLocalAdmin.ps1`.

- Rationale: decouple bootstrap account lifecycle from registry; provide a deterministic handoff to Winlogon priming while keeping the secret out of logs and script arguments.

- Security: ACL both password source files (`.bootstrap.pw` and `.primaryadmin.pw`) to `SYSTEM` and local Administrators only. On the normal path Stage B deletes them after a successful run; in recovery they are preserved for another attempt and should be removed manually once no longer needed.

### ADR: `.primaryadmin.pw` as operator-supplied primary admin secret

**Context:** External audit highlighted a critical lock where the primary admin could be created with a randomly generated password that was never exposed to the operator. The previous flow allowed Stage A to fall back to secrets derived from `.bootstrap.pw`.

**Decision:** Require an explicit `-PasswordPlain` for Stage A of `CreatePrimaryAdmin.ps1`, supplied exclusively by `SetupComplete.cmd` from an operator-managed file `%WINDIR%\Setup\Scripts\.primaryadmin.pw` (UTF-8, one non-empty line, restricted character set). `SetupComplete.cmd` reads and validates this file and only configures AutoAdminLogon and registers the `\L2C\CreatePrimaryAdmin` task when both `.bootstrap.pw` and `.primaryadmin.pw` are present and valid and the script has not failed. Neither script generates or persists the primary admin password beyond Stage B; both password files are deleted on the normal path and preserved only in recovery.

**Status:** adopted in `SetupComplete.cmd` and `CreatePrimaryAdmin.ps1`; documented in `README.md` and `SECURITY.md`.

## [2025-11-12] Harden bootstrap/admin provisioning chain (SetupComplete / BootstrapLocalAdmin / CreatePrimaryAdmin)

### Context

- Capability removal in `SetupComplete.cmd` relied on `dism /Online /Get-Capabilities | findstr "Installed"` which breaks on non-English output.
- Winlogon autologon flipped `AutoAdminLogon`/`ForceAutoLogon` even if the PowerShell write of `DefaultPassword` failed, leaving a stuck autologon without credentials.
- `schtasks /Create \L2C\CreatePrimaryAdmin` was not tracked via `:track_rc`, so failures could be invisible to L2C_FIRST_BAD_RC and exit codes even when task creation failed.
- Stage B of `CreatePrimaryAdmin.ps1` cleaned Winlogon, RunOnce, the scheduled task, and `.bootstrap.pw`, but many failure paths only emitted DEBUG/WARN entries and did not encode the cleanup result for later tooling.
- `.bootstrap.pw` ACLs were recreated using localized “Administrators” names instead of translating the Administrators SID, leaving room for locale regressions.

### Decision

- `SetupComplete.cmd` now calls `dism /Online /Get-CapabilityInfo /CapabilityName:<cap> /English`, parses the `State :` line, and treats DISM/parse failures as `[ERROR]` with `FAILED=1` + `:track_rc`.
- Capability removal only runs for known states (`Installed`, `Staged`); other states log explicit skip reasons rather than silently continuing.
- Winlogon autologon switches are configured only if the `DefaultPassword` PowerShell call returns RC=0; on error the script logs `[ERROR]`, sets `FAILED=1`, and leaves autologon off.
- `schtasks /Create \L2C\CreatePrimaryAdmin` always captures `%ERRORLEVEL%`, logs failures with `[ERROR]`, calls `:track_rc`, and sets `FAILED=1`.
- Final RC policy: `SetupComplete.cmd` returns `L2C_FIRST_BAD_RC` if set; otherwise it returns `1` when `FAILED==1`, else `0`. Each path logs the specific `[RC] returning ...` line.
- `BootstrapLocalAdmin.ps1` resolves the Administrators group via SID `S-1-5-32-544`, reuses the translated `NTAccount` for both `net localgroup` and ACLs, and replaces inherited ACLs on `.bootstrap.pw` with only SYSTEM + Administrators FullControl inside a guarded `try` block.
- `SetupComplete.cmd` reads `%WINDIR%\Setup\Scripts\.bootstrap.pw` and `%WINDIR%\Setup\Scripts\.primaryadmin.pw`, validates the primary admin password read via `set /p` (first line only, must be non-empty as read, allowed character set only), and only when both secrets are present and valid and the script has not failed, it applies temporary Winlogon policies for AutoAdminLogon, configures AutoAdminLogon for `bootstrap` using the secret from `.bootstrap.pw`, and registers the `\L2C\CreatePrimaryAdmin` task with `-PasswordPlain` set to the validated primary admin password. If the primary admin secret is missing or invalid, or if `FAILED=1`, it logs the condition, rolls back temporary logon tweaks to safe values, and does not configure autologon or the scheduled task.
- Stage A of `CreatePrimaryAdmin.ps1` always requires an explicit `-PasswordPlain` parameter and never reads `.bootstrap.pw` or any other password file. In this baseline the parameter is supplied exclusively by `SetupComplete.cmd` from `.primaryadmin.pw`.
- Stage B of `CreatePrimaryAdmin.ps1` now:
  - Deletes `DefaultUserName`, `DefaultDomainName`, and `DefaultPassword`, and resets `AutoAdminLogon`, `ForceAutoLogon`, and `AutoLogonCount`.
  - Logs `net user bootstrap /active:no` success or WARN with the exact RC.
  - Logs WARN for non-zero RCs from `schtasks.exe /Delete` and still surfaces caught exceptions as WARN.
  - Removes RunOnce entries via `Remove-ItemProperty -ErrorAction Stop`, logging WARN per entry on failure, and checks the defensive `reg.exe DELETE` RC (warns unless RC ∈ {0,2}).
  - Tracks cleanup state for both `.bootstrap.pw` and `.primaryadmin.pw` in dedicated variables, logs `removed`/`missing`/`error`/`preserved` states for each, and records the resulting state in the Stage B master log summary.

### Consequences / Impact

- Capability removal is locale-agnostic and reports failures through `[ERROR]` + non-zero exit codes, enabling CI/ops to detect servicing regressions.
- `SetupComplete.cmd` now propagates the first failing RC or a generic FAILED fallback, so monitoring and deployment tooling can rely on exit codes instead of tailing logs.
- Winlogon autologon now has an all-or-nothing contract: either the password write succeeds and autologon is primed, or autologon stays off with explicit error logging.
- `.bootstrap.pw` is guaranteed to be ACLed with only SYSTEM and local Administrators; any deviation aborts bootstrap rather than silently weakening protections.
- Stage B produces deterministic post-bootstrap state (Winlogon, RunOnce, scheduled tasks) and emits machine-readable entries for `.bootstrap.pw` cleanup, improving forensic and automation coverage.
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
  For these codes, `:run_dism` logs a warning, sets `HAS_DISM_WARN=1`, and returns success.
- All other non-success DISM return codes remain fatal. `:run_dism` logs an error, sets `FAILED=1` and `DISM_HARD_FAIL=1`, and `:track_rc` captures the first fatal code in `L2C_FIRST_BAD_RC`. Once `DISM_HARD_FAIL` is set, subsequent DISM feature/capability/cleanup calls are skipped for the rest of the run.
- At the end of `SetupComplete.cmd`, the script aggregates a final exit code: if `L2C_FIRST_BAD_RC` is set, `FINAL_RC=L2C_FIRST_BAD_RC`; otherwise, if `FAILED==1`, `FINAL_RC=1`; otherwise, `FINAL_RC=0`. The script logs “[RC] returning %FINAL_RC%” and exits with that code.

**Consequences:**

- Clean LTSC images where certain optional features are not present or not selectable no longer fail `SetupComplete.cmd` purely because of benign DISM warnings; these conditions remain visible in the log via explicit warning entries and `HAS_DISM_WARN=1`.
- Truly fatal servicing problems still produce a non-zero `FINAL_RC`, trip `DISM_HARD_FAIL`, and stop further feature/capability/cleanup calls, which makes the first failing DISM call and its RC easy to identify in the logs.
- CI pipelines and operators can rely on `FINAL_RC` together with the DISM log classification (success, whitelisted warning, fatal) as the primary signal for pass/fail, instead of guessing from raw DISM return codes alone.
