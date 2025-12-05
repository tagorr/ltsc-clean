# Security notes for the Clean & Quiet Baseline

## Purpose

This baseline favors a quiet, predictable workstation with minimal background network activity and telemetry, using only supported Microsoft mechanisms.

## Scope

* Target: Windows 10 Enterprise LTSC 2021 workstations (21H2, EnterpriseS, build 19044+).
* Environment: standalone or simple networks without corporate integration or automatic proxy discovery requirements.
* Philosophy: official tools only (Policies/Registry, DISM Features & Capabilities, Scheduled Tasks; RunOnce is used only for optional diagnostic helpers), deterministic and idempotent behavior, no reboots inside SetupComplete.

## Intentional trade-offs

* SmartScreen is disabled for Explorer and Edge.
* Windows Defender is minimized using supported preferences. Cloud protection and sample submissions are off.
* Delivery Optimization is set to mode 0 (HTTP-only, no peer-to-peer).
* Windows Update runs in notify-only mode. No drivers, no preview builds, no other Microsoft products, no OS upgrade offers.
* WPAD is disabled via policies on WinINET and WinHTTP. The WinHTTP Auto-Proxy service is not forcibly disabled.
* Edge first run experience is suppressed via policy (`HKLM\SOFTWARE\Policies\Microsoft\Edge\HideFirstRunExperience=1`) to reduce extra first-boot prompts and calls.
* The baseline does not invoke `DISM /Online /Cleanup-Image /StartComponentCleanup` or `/ResetBase` automatically. Any aggressive component cleanup that removes rollback for installed updates is considered an optional, operator-driven hardening step and is not part of the core pipeline.
* Several hardening steps rely on disabling optional Windows features and capabilities via DISM (for example SMB1, Telnet, Remote Assistance, Fax/Scan, PSR, Quick Assist, SNMP). On LTSC images some of these components may be absent or non-selectable; in these cases `SetupComplete.cmd` logs known benign DISM return codes (`-2146498548/2148468748`, `-2146498541/2148468755`) as warnings, sets `HAS_DISM_WARN=1`, and continues. Operators should review `SetupComplete.log` to confirm that any missing components are acceptable for their environment. Unexpected DISM errors remain fatal, set `FAILED=1/DISM_HARD_FAIL=1`, and surface in the final exit code.

## Not a fit if you require

* SmartScreen prompts or Defender cloud protection by policy.
* Peer-to-peer Delivery Optimization or Connected Cache scenarios.
* Automatic proxy discovery (WPAD) for WinHTTP clients.
* Guaranteed rollback of currently installed updates.
* Enterprise hardening stacks enabled by default (for example, MDE onboarding, WDAC, AppLocker, BitLocker enforcement, LAPS, or domain-based baselines).

## Recommendations and compensating controls

* Use least-privilege accounts for daily work; avoid local admin where possible.
* Patch cadence: manually apply quality updates on a predictable schedule after validating on a test VM or sacrificial machine.
* If a proxy is introduced later, configure it explicitly: `netsh winhttp set proxy` or a supported policy. With WPAD disabled, auto-discovery will not occur.
* Consider periodic offline AV scans or a trusted third-party endpoint if organizational policy requires it.
* If you later re-enable Defender’s real-time features, consider testing Attack Surface Reduction (ASR) rules on a VM first.
* Monitor the post-install verification checklist in **README.md → Post-install quick check**, and keep it up to date for reproducibility.

## Operational notes

* The baseline is designed to be idempotent. Re-running the post-install script should not introduce drift.
* Stage B rollback (Winlogon cleanup, removal of any lab RunOnce helpers, bootstrap disable in normal mode) always runs once after Stage A and chooses between normal and recovery paths based on Stage A’s outcome and internal validation, reducing lockout risk by attempting cleanup even when account provisioning fails.
* The script returns a non-zero code if steps failed; always review `%WINDIR%\Panther\SetupComplete.log`.
* Platform compatibility checks (Edition/DisplayVersion/CurrentBuild) fail closed but still route to the shared final RC block: the script logs the mismatch, sets `FAILED=1`, skips autologon/task registration, logs `[RC] returning <FINAL_RC>`, and exits with that code for consistent monitoring.
* **Temporary debug note:** if you temporarily replaced `utilman.exe` with `cmd.exe` for diagnostics, restore the original `utilman.exe` immediately after testing to prevent escalation from the logon screen.
* Any deviation from the principles above may affect predictability. Document exceptions in your fork and update `DECISIONS.md`.

## Reporting and contributions

* For questions or improvements, open a GitHub issue or pull request in the repository.
* Do not post sensitive information or logs containing personal data in public issues.
* Keep contributions aligned with the project principles: official tools only, deterministic and idempotent behavior, and no reboots inside SetupComplete.

## License notice

* This project is provided under the MIT License, without warranty. Review and adapt the baseline to your risk profile before production use.

### Additional clarifications

* UAC remains enabled (it is not lowered).
* `SetupComplete.cmd` never calls `shutdown.exe` and never schedules a reboot via RunOnce. When the final servicing return code is `3010` or `1641`, or when `ALWAYS_REBOOT_AFTER_FIRST_LOGON=1` is set, it only writes `%WINDIR%\Panther\_needs_reboot.flag` and exits. Stage B `CreatePrimaryAdmin.ps1` is the only unattended component that reads this flag after the first interactive logon: in the normal path, only when Stage B succeeded and the flag exists, it logs the requirement, deletes `_needs_reboot.flag`, and performs a single controlled reboot; in recovery mode or when Stage B fails it logs the pending reboot, skips the automatic restart, and leaves the flag as a marker for manual diagnostics.

## Compatibility controls & safety

**Default:** `STRICT_DISPLAYVERSION=0` (best‑effort). For production environments use `STRICT_DISPLAYVERSION=1`.

`STRICT_DISPLAYVERSION=0` allows execution to continue on nearby Windows versions. This is a deliberate portability trade-off with the risk that some steps may not apply or may behave differently due to component changes. For production in uncontrolled environments, enable `STRICT_DISPLAYVERSION=1` and pin `REQUIRED_*` to the target release.

### Controlled reboot (Panther flag)

* `SetupComplete.cmd` never calls `shutdown.exe` and never plans a reboot via RunOnce.
* When the final servicing return code is `3010` or `1641`, or when `ALWAYS_REBOOT_AFTER_FIRST_LOGON=1` is set, it only writes `%WINDIR%\Panther\_needs_reboot.flag` and exits.
* Stage B `CreatePrimaryAdmin.ps1` is the only unattended component that reads the Panther flag after the first interactive logon and, in the **normal** path, only when Stage B succeeded and the flag exists, logs the reboot requirement, deletes the flag and performs a single controlled `shutdown.exe /r /t 0`.
* In the **recovery** path or when Stage B fails, Stage B logs the Panther flag, does not perform an automatic reboot, and leaves the flag in place for manual follow-up.
* Any new `shutdown.exe` invocations or RunOnce-based reboot logic must be treated as a security decision and recorded in `DECISIONS.md` before code changes.

## Logs

The script writes a technical log to `%WINDIR%\Panther\SetupComplete.log`. Entries contain technical messages and timestamps only; personal data is not intentionally logged. Set retention according to your environment’s policy and delete the log after successful validation if required.

`PreOOBE.cmd` writes `%WINDIR%\Panther\PreOOBE.log` and redirects stdout/stderr from `BootstrapLocalAdmin.ps1` into the same file; `BootstrapLocalAdmin.ps1` emits structured `[BOOTSTRAP] [INFO|WARN|ERROR] ...` lines for bootstrap lifecycle steps without logging the password or derived secrets, so the log is safe to review for bootstrap failures.

**Timestamping & DISM logs.** Timestamps are **ISO-8601**, generated via **PowerShell** (`Get-Date -Format o`). All DISM calls write to a centralized log: `%WINDIR%\Logs\DISM\SetupComplete-DISM.log` with `/LogLevel:4`. Return codes are handled uniformly: `0` = success; `3010/1641` = success, reboot required.

Installer reboot suppression is enforced: **MSI** use `REBOOT=ReallySuppress /norestart`, **EXE** are invoked with `/norestart` to avoid any reboot inside SetupComplete.

**Unattend hygiene.** After SetupComplete finishes, remove `%WINDIR%\Panther\Unattend.xml` and `%WINDIR%\Panther\UnattendGC\*.xml`.

## Update (2025-09-19) — Privacy & Account Hardening
- **Deployment precondition:** `PreOOBE.cmd` is **embedded** into `install.wim` at `Windows\Setup\Scripts\`; unattend calls it in `specialize`.

Applied at **specialize** (SYSTEM) using `Microsoft-Windows-Deployment/RunSynchronous`:

- `HKLM\SOFTWARE\Policies\Microsoft\Windows\System\NoLocalPasswordResetQuestions=1`
- `HKLM\SOFTWARE\Policies\Microsoft\Windows\OOBE\DisablePrivacyExperience=1`
- `HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection\AllowTelemetry=0`
- `HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent\DisableTailoredExperiencesWithDiagnosticData=1`
- `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo\Enabled=0`
- `HKLM\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo\DisabledByGroupPolicy=1`
- `HKLM\SOFTWARE\Policies\Microsoft\InputPersonalization\AllowInputPersonalization=0`
- `HKLM\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors\DisableWindowsLocationProvider=1`
- `HKLM\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors\DisableLocation=1`
- `HKLM\SOFTWARE\Policies\Microsoft\FindMyDevice\AllowFindMyDevice=0`

Effect: Privacy wizard suppressed; six corresponding toggles enforced to OFF; local-account security questions disabled.

- Applied at specialize via external `PreOOBE.cmd` (invoked from unattend).

## Temporary storage of the password in Winlogon during autologon

`AutoAdminLogon` requires `HKLM\...\Winlogon\DefaultPassword (REG_SZ)`. This is the password in clear text and it is stored **temporarily**—only for the “priming → first bootstrap logon” phase.

Risk mitigations:
- The `bootstrap` password is temporary; after the first logon `CreatePrimaryAdmin.ps1` deletes `DefaultPassword` and disables autologon (`AutoAdminLogon=0`, `ForceAutoLogon=0`).
- Logs do not contain passwords (only facts and length/classes during generation).
- Storage duration is only until the first `bootstrap` logon.

The primary admin account password is **never** stored in `DefaultPassword`. It comes from a separate file secret `.primaryadmin.pw`; `SetupComplete.cmd` calls `ValidateSecrets.ps1` (passing both secret paths) and decodes the 0–3 exit-code bitmask (bit0=bootstrap, bit1=primary admin) to confirm ACL/attributes before reading anything. It loads the primary secret only when the bitmask reports both secrets as valid and primes autologon only when both secrets have been validated and read. `CreatePrimaryAdmin.ps1` reads the secret directly under SYSTEM during Stage A, so the `\L2C\CreatePrimaryAdmin` task command line contains no password. Winlogon via `DefaultPassword` therefore sees only the temporary `bootstrap` password, not the primary admin password.

## Temporary autologon & secret handling

* While primed, Winlogon holds `DefaultPassword`; Stage B removes it and restores `DisableCAD=0` and `Ngc...=2`.
* Winlogon autologon follows an all-or-nothing model: `SetupComplete.cmd` first writes `DefaultPassword` via PowerShell / `reg.exe`, checks the return code, and only if it is `0` enables `AutoAdminLogon` and `ForceAutoLogon`. On any error, autologon remains disabled, an `[ERROR]` entry is written to the log, and the pipeline falls back to the recovery path instead of leaving a half-primed autologon.
* `.bootstrap.pw` is created by `BootstrapLocalAdmin.ps1` at `%WINDIR%\Setup\Scripts\.bootstrap.pw` with inheritance disabled (`AreAccessRulesProtected=True`), explicit FullControl entries for `NT AUTHORITY\SYSTEM` (S-1-5-18) and the local Administrators group (S-1-5-32-544), and Hidden+System attributes. Creation or ACL/attribute hardening failures stop Stage A instead of leaving a weak secret on disk.
* `.primaryadmin.pw` must be provisioned ahead of time (for example when building `install.wim`) in the same location and with the same ACL and attribute shape as `.bootstrap.pw`. Its contents must be a single non-empty UTF-8 (no BOM) line made only of `A-Z`, `a-z`, `0-9`, `#`, `@`, `_`, and `-`; unsupported characters are rejected before autologon is ever enabled.
* At the start of `SetupComplete.cmd`, `ValidateSecrets.ps1` checks that both secret files are leaf files, have inheritance disabled, carry only the `SYSTEM` and Administrators FullControl ACEs, and include Hidden+System attributes. It never reads the passwords; instead it returns a 0–3 exit-code bitmask (bit0=bootstrap secret valid, bit1=primary admin secret valid) that `SetupComplete.cmd` decodes into `L2C_BOOTSTRAP_PW_ACL_OK` and `L2C_PRIMARYADMIN_PW_ACL_OK` and logs as `[SECTION] Secret ACL validation (bootstrap=X, primaryadmin=Y)`.
* `SetupComplete.cmd` enforces a single gate for temporary logon policy relaxations, Winlogon autologon, and registration of `\L2C\CreatePrimaryAdmin`: `FAILED=0`, `.bootstrap.pw` exists and is non-empty, `.primaryadmin.pw` is present, the validator exit code reports both secrets as valid, and `.primaryadmin.pw` is read successfully. If any condition fails (including either bit being `0` or the validator returning `0` because of an internal error), it logs why, skips autologon and Stage B registration, keeps only safe policy changes, and exits in recovery with a non-zero RC.
* With the gate open, `SetupComplete.cmd` relaxes `DisableCAD`/`DevicePasswordLessBuildVersion`, primes Winlogon with `DefaultUserName=bootstrap`, `DefaultDomainName=%COMPUTERNAME%`, and `DefaultPassword` read from `.bootstrap.pw`, and creates the Stage B task. Passwords never appear in the task definition, RunOnce, or command lines; only `DefaultPassword` holds the temporary bootstrap secret and only until Stage B runs.
* The secrets are expected to exist on disk only between the end of `SetupComplete.cmd` and the end of Stage B. In the normal Stage B path, both secrets are deleted and the scheduled task is removed; in recovery they are intentionally preserved (and logged) for a later retry.
* WARN/ERROR entries about `.bootstrap.pw` or `.primaryadmin.pw` in Stage B logs (ACL, read/validation, delete failures) are intentional signals; operators should treat them as triggers for manual review rather than noise.
* Any relaxation of these `.bootstrap.pw` / `.primaryadmin.pw` requirements (ACL shape, retention beyond Stage B, validation constraints, logging guarantees) must be treated as a security decision and recorded in `DECISIONS.md` before code changes.

## Primary admin password source file (.primaryadmin.pw)

* Path and ownership: `%WINDIR%\Setup\Scripts\.primaryadmin.pw`, created and maintained by the operator (not generated by the scripts). The baseline scripts only read and later delete it.
* Format and encoding: UTF-8 without BOM; only the first line is consumed via `set /p` and must be non-empty as read; allowed characters: `A-Z`, `a-z`, `0-9`, `#`, `@`, `_`, `-`. Whitespace or other characters are invalid; no trimming is applied.
* ACLs and attributes: inheritance disabled; explicit FullControl for `NT AUTHORITY\SYSTEM` and local Administrators only; Hidden+System attributes. `ValidateSecrets.ps1` verifies this shape up front and encodes the result in the exit-code bitmask; if the check fails, `SetupComplete.cmd` treats it as a hard failure and never reads the secret.
* Consumption and lifecycle: `SetupComplete.cmd` reads `.primaryadmin.pw` only after the ACL/attribute check succeeds; if the file is missing, unreadable, empty, or contains unsupported characters, the combined gate fails and autologon/Stage B registration are skipped. Stage A of `CreatePrimaryAdmin.ps1` re-reads the file under SYSTEM and aborts if it cannot load or validate the password. The `\L2C\CreatePrimaryAdmin` task `/TR` contains no password or secret arguments. In the normal Stage B path, both `.bootstrap.pw` and `.primaryadmin.pw` are deleted and the result is logged; in the recovery path, both are preserved, `_needs_reboot.flag` remains, and logs clearly indicate that secrets were retained for manual investigation and possible retry.
* Consequences: the primary admin password is never generated or guessed by the baseline; logs never contain the password itself, only validation outcomes; failure to read or validate `.primaryadmin.pw` stops unattended primary admin provisioning instead of silently weakening security.

## Secret threat model

* Password values never appear in Task Scheduler definitions, command lines, RunOnce keys, or logs; the only storage locations are the hardened on-disk secrets (`.bootstrap.pw` and `.primaryadmin.pw`) with Hidden+System attributes and explicit `SYSTEM` + Administrators ACLs.
* Attempts to weaken those secrets (extra ACEs, inheritance enabled, missing attributes, deleting or emptying `.primaryadmin.pw`, or using unsupported characters) cause `SetupComplete.cmd` to fail closed: no temporary autologon, no Stage B registration, and an exit that requires interactive follow-up using the logs.
* Happy path: both secrets are provisioned correctly, the gate opens once, a single automatic `bootstrap` logon runs Stage B, the system migrates to `primaryadmin`, disables `bootstrap`, removes the secrets and scheduled task, restores logon policies, and (if the Panther flag was present) performs the single controlled reboot.

## Logon policies: temporary relaxation and restore

During priming:
- `DisableCAD=1`, `DevicePasswordLessBuildVersion=0`, clear `LegalNotice*`, `IgnoreShiftOverride=0 (REG_SZ, with no intermediate "1")`.

On rollback:
- `DisableCAD=0`, `DevicePasswordLessBuildVersion=2`, `IgnoreShiftOverride=0 (REG_SZ)`.

The restore guarantee is provided by the idempotent logic in `CreatePrimaryAdmin.ps1`.

In the normal Stage B path:

* `DisableCAD` is returned to `0`, `DevicePasswordLessBuildVersion` is set to `2`, the `bootstrap` account is disabled, the `\L2C\CreatePrimaryAdmin` task is removed, `.bootstrap.pw` and `.primaryadmin.pw` are deleted, and, if the Panther flag is present and Stage B completed successfully in the normal path, it is logged, the flag is deleted, and a single controlled reboot is issued via `shutdown.exe /r /t 0`.

In the recovery Stage B path:

* `DevicePasswordLessBuildVersion` remains `0`, the `bootstrap` account and the `\L2C\CreatePrimaryAdmin` task stay enabled for diagnostics, the password source files are preserved, and, if the Panther flag is present, it is logged, no automatic reboot is performed, and the flag is left in place for operator follow-up.
