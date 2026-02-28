# Security notes for the Clean & Quiet Baseline

## Purpose

This baseline favors a quiet, predictable workstation with minimal background network activity and telemetry, using only supported Microsoft mechanisms.

## Scope

* Target: Windows 10 Enterprise LTSC 2021 workstations (21H2, EnterpriseS, build 19044+).
* Environment: standalone or simple networks without corporate integration or automatic proxy discovery requirements.
* Philosophy: official tools only (Policies/Registry, DISM Features & Capabilities, Scheduled Tasks), deterministic and idempotent behavior, no reboots inside SetupComplete.

## Intentional trade-offs

* SmartScreen policy layers are disabled for Windows Shell and Edge.
* Microsoft Defender local protections remain enabled, while cloud/reputation verdict paths and sample submission are disabled by policy.
* Delivery Optimization is set to mode 0 (HTTP-only, no peer-to-peer).
* Windows Update runs in notify-only mode. No drivers, no preview builds, no other Microsoft products, no OS upgrade offers.
* WPAD is disabled via policies on WinINET and WinHTTP. The WinHTTP Auto-Proxy service is not forcibly disabled.
* Edge first run experience is suppressed via policy (`HKLM\SOFTWARE\Policies\Microsoft\Edge\HideFirstRunExperience=1`) to reduce extra first-boot prompts and calls.
* The baseline does not invoke `DISM /Online /Cleanup-Image /StartComponentCleanup` or `/ResetBase` automatically. Any aggressive component cleanup that removes rollback for installed updates is considered an optional, operator-driven hardening step and is not part of the core pipeline.
* Several hardening steps rely on disabling optional Windows features and capabilities via DISM (for example SMB1, Telnet, Remote Assistance, Fax/Scan, PSR, Quick Assist, SNMP). Capability removals are gated by `dism /Online /Get-CapabilityInfo` with output captured to a temp file and parsed for the `State :` line (no `dism | findstr` pipelines); missing/unparsable state logs a WARN and skips removal. On LTSC images some of these components may be absent or non-selectable; in these cases `SetupComplete.cmd` logs known benign DISM return codes (`-2146498548/2148468748`, `-2146498541/2148468755`) as warnings, sets `HAS_DISM_WARN=1`, and continues. Operators should review `SetupComplete.log` to confirm that any missing components are acceptable for their environment. Unexpected DISM errors remain fatal, set `FAILED=1/DISM_HARD_FAIL=1`, and surface in the final exit code.

### Defender and SmartScreen Baseline

This baseline does not attempt to disable Microsoft Defender local endpoint protections. Local protections remain ON, while cloud/reputation-driven verdict paths and automatic sample submission are explicitly disabled via policy.

SmartScreen is disabled for Windows Shell and the Edge policy layer to minimize silent outbound reputation/data flows. These settings are enforced via registry policy and orchestration in `SetupComplete.cmd`.

### Edge Browser Removal and Update Suppression

Edge browser removal runs early in `SetupComplete.cmd` as a best-effort guarantee layer. Edge SmartScreen policies are still set to disabled before removal, EdgeUpdate services/tasks are disabled best-effort to reduce browser resurrection, and WebView2 runtime is not removed.

* Windows Shell SmartScreen: `HKLM\SOFTWARE\Policies\Microsoft\Windows\System\EnableSmartScreen=0`
* Edge SmartScreen policies: `HKLM\SOFTWARE\Policies\Microsoft\Edge\SmartScreenEnabled=0`; `HKLM\SOFTWARE\Policies\Microsoft\Edge\SmartScreenDnsRequestsEnabled=0`; `HKLM\SOFTWARE\Policies\Microsoft\Edge\SmartScreenForTrustedDownloadsEnabled=0`; `HKLM\SOFTWARE\Policies\Microsoft\Edge\SmartScreenPuaEnabled=0`
* Defender local protections ON: `HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection\DisableRealtimeMonitoring=0`; `HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection\DisableBehaviorMonitoring=0`; `HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection\DisableIOAVProtection=0`; `HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\PUAProtection=1`
* Defender cloud/reputation/data OFF: `HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\Spynet\SpynetReporting=0`; `HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\Spynet\SubmitSamplesConsent=2`; `HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\Spynet\DisableBlockAtFirstSeen=1`; `HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\Spynet\LocalSettingOverrideSpynetReporting=0`; `HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\MpEngine\MpCloudBlockLevel=0`
* Edge lifecycle: early best-effort uninstall via Edge `setup.exe --uninstall --system-level --force-uninstall`; EdgeUpdate services/tasks disabled best-effort; WebView2 not removed
* UX hygiene: `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\DisableEdgeDesktopShortcutCreation=1`

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
* If you later re-enable Defender's real-time features, consider testing Attack Surface Reduction (ASR) rules on a VM first.
* Monitor the post-install verification checklist in **README.md → Post-install quick check**, and keep it up to date for reproducibility.

## Operational notes

* The baseline is designed to be idempotent. Re-running the post-install script should not introduce drift.
* PowerShell helpers (`BootstrapLocalAdmin.ps1`, `ValidateSecrets.ps1`, `CreatePrimaryAdmin.ps1`) run under `Set-StrictMode -Version Latest` with `$ErrorActionPreference='Stop'` so unexpected errors surface and fail closed via their existing logging and exit code paths.
* Stage B rollback (Winlogon cleanup, bootstrap disable in normal mode) always runs once after Stage A and chooses between normal and recovery paths based on Stage A's outcome and internal validation, reducing lockout risk by attempting cleanup even when account provisioning fails.
* The script returns a non-zero code if steps failed; always review `%WINDIR%\Panther\SetupComplete.log`.
* Platform compatibility checks (Edition/DisplayVersion/CurrentBuild) fail closed but still route to the shared final RC block: the script logs the mismatch, sets `FAILED=1`, skips autologon/task registration, logs `[RC] returning <FINAL_RC>`, and exits with that code for consistent monitoring.
* The Stage B gateway (secret validation, gate evaluation, optional temporary logon tweaks, Stage B scheduling, Winlogon priming) runs after DISM servicing and before the reboot-flag evaluation to avoid scheduling/priming when servicing has already failed fatally.
* When `FAILED=1` at the recovery gate (gate closed or task creation fails), `SetupComplete.cmd` logs recovery mode and skips autologon/task registration, but still evaluates the reboot-flag logic.
* DISM hard-fail policy: only a strict whitelist of known non-fatal warning return codes (for example `3010`, `1641`, and the LTSC "feature not recognized/invalid state" codes) is allowed to continue. Any other non-zero DISM return code is treated as a hard failure that keeps the gate closed and blocks Stage B registration. Operators hitting a new code must review `%WINDIR%\Logs\DISM\SetupComplete-DISM.log` and `%WINDIR%\Panther\SetupComplete.log`, confirm the condition is truly benign, and only then consider extending the whitelist deliberately.
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

## Compatibility controls & safety

**Default:** `STRICT_DISPLAYVERSION=1` (fail-closed). Set `STRICT_DISPLAYVERSION=0` only as an explicit opt-out for best-effort compatibility.

`STRICT_DISPLAYVERSION=0` allows execution to continue on nearby Windows versions. This is a deliberate portability trade-off with the risk that some steps may not apply or may behave differently due to component changes. In baseline fail-closed mode (`STRICT_DISPLAYVERSION=1`), `:gate_dv` reads `DisplayVersion` before the strictness branch and normalizes missing reads to `DV=<missing>` so mismatch logs stay explicit.

### Controlled reboot (Panther flag)

* `SetupComplete.cmd` never calls `shutdown.exe` and never plans a reboot.
* When the final servicing return code is `3010` or `1641`, or when `ALWAYS_REBOOT_AFTER_FIRST_LOGON=1` is set, it signals a pending reboot via `%WINDIR%\Panther\_needs_reboot.flag` (write + verify via `:flag_reboot`); the marker is a single-line ASCII (7-bit) token (`need-reboot` or `force-reboot`) written with CRLF (no BOM) and verified by reading the first line only (PowerShell/.NET writer; process-boundary TYPE capture + first-line-only parsing). I/O failure classification is not based on `%ERRORLEVEL%` from CMD < / > redirections. Terminal verify-time failures abort retries immediately (no FAIL→OK logs in a single run). It does not delete a pre-existing flag on entry, and it preserves the flag as a sticky marker while logging a WARN when the flag already exists. Signaling is observable via `REBOOT_FLAG_SIGNAL_BEGIN` / `REBOOT_FLAG_SIGNAL_OK` / `REBOOT_FLAG_SIGNAL_FAIL`; failures fail closed via `FAILED=1` and tracked RC `9001`.
* If `SetupComplete.cmd` successfully signals `%WINDIR%\Panther\_needs_reboot.flag` (`REBOOT_FLAG_SIGNAL_OK=1`) but Stage B was not scheduled (for example, when the gate is closed or task creation fails), `SetupComplete.log` logs `WARN_REBOOT_FLAG_NO_EXECUTOR` with marker/value/executor_task (plus machine-readable `skipped_gate` / `not_scheduled`) and the operator instruction that automatic reboot will NOT happen; manual reboot required after fixing gate or scheduling; then rerun pipeline. Example:
  `[WARN] WARN_REBOOT_FLAG_NO_EXECUTOR Reboot required, but Stage B executor task is unavailable, automatic reboot will NOT happen. marker=%WINDIR%\Panther\_needs_reboot.flag (value=need-reboot). executor_task=\L2C\CreatePrimaryAdmin (skipped_gate=1 not_scheduled=1). Manual reboot required after fixing gate or scheduling, then rerun pipeline.`
  SetupComplete may write a standalone `%ProgramData%\l2c_master_<timestamp>.log` entry with a single `[timestamp] WARN_REBOOT_FLAG_NO_EXECUTOR ...` line for centralized triage.
* If `SetupComplete.cmd` successfully signals `%WINDIR%\Panther\_needs_reboot.flag` (`REBOOT_FLAG_SIGNAL_OK=1`) but AutoAdminLogon was not armed (degraded mode after Winlogon priming), `SetupComplete.log` logs `WARN_REBOOT_FLAG_NO_AUTOLOGON` to avoid a silent stall: Stage B is scheduled but will not run until a manual logon occurs.
* Stage B `CreatePrimaryAdmin.ps1` is the only unattended component that reads the Panther flag after the first interactive logon and, in the **normal** path, only when Stage B succeeded and the flag exists, performs a tri-state pending reboot check, logs the result (state/reasons/errors), and then either reboots, clears a stale flag without reboot, or reboots conservatively on `unknown`; see `DECISIONS.md` for full semantics.
* In the **recovery** path or when Stage B fails (including secret cleanup errors that keep `StageB_Succeeded=$false`), Stage B logs the Panther flag, does not perform an automatic reboot, and leaves the flag in place for manual follow-up.
* Any new `shutdown.exe` invocations must be treated as a security decision and recorded in `DECISIONS.md` before code changes.

## Logs

The script writes a technical log to `%WINDIR%\Panther\SetupComplete.log`. Entries contain technical messages; many logger-written lines are timestamped, but some lines may be un-timestamped (for example raw tags). Personal data is not intentionally logged. Set retention according to your environment's policy and delete the log after successful validation if required.

`PreOOBE.cmd` writes `%WINDIR%\Panther\PreOOBE.log` and redirects stdout/stderr from `BootstrapLocalAdmin.ps1` into the same file; `BootstrapLocalAdmin.ps1` emits structured `[BOOTSTRAP] [INFO|WARN|ERROR] ...` lines for bootstrap lifecycle steps without logging the password or derived secrets, so the log is safe to review for bootstrap failures.

**Timestamping & DISM logs.** Timestamped logger-written lines are normally **ISO-8601**: `SetupComplete.cmd`/`PreOOBE.cmd` typically generate them via **PowerShell** (`Get-Date -Format o`, local time/offset) when available, and `CreatePrimaryAdmin.ps1` uses `[DateTime]::UtcNow.ToString('o')` (UTC). DISM's log format is tool-defined, but all DISM calls write to a centralized log: `%WINDIR%\Logs\DISM\SetupComplete-DISM.log` with `/LogLevel:4`. Return codes are handled uniformly: `0` = success; `3010/1641` = success, reboot required.

Installer reboot suppression is enforced: **MSI** use `REBOOT=ReallySuppress /norestart`, **EXE** are invoked with `/norestart` to avoid any reboot inside SetupComplete.

**Unattend hygiene.** Operator hygiene only: remove `%WINDIR%\Panther\Unattend.xml` and `%WINDIR%\Panther\UnattendGC\*.xml` if your policy requires it; the scripts do not delete them.

## Update (2025-09-19) - Privacy & Account Hardening
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

`AutoAdminLogon` requires `HKLM\...\Winlogon\DefaultPassword (REG_SZ)`. This is the password in clear text and it is stored **temporarily**-only for the "priming → first bootstrap logon" phase.

Risk mitigations:
- The `bootstrap` password is temporary; after the first logon `CreatePrimaryAdmin.ps1` removes `DefaultPassword` (must be absent) and disables autologon (`AutoAdminLogon`, `ForceAutoLogon`, `AutoLogonCount` absent or `0`), then verifies that the Winlogon state is actually sanitized; verification failures (or read errors) are treated as a hard fail and suppress teardown of `bootstrap` and the `\L2C\CreatePrimaryAdmin` executor.
- `SetupComplete.cmd` writes a non-secret "armed" marker only after Winlogon priming succeeds: `HKLM\SOFTWARE\L2C\AutologonPrimed (REG_DWORD)=1`. If the marker write fails after Winlogon priming, `SetupComplete.cmd` rolls back Winlogon autologon immediately, keeps the executor task for manual continuation, and rolls back temporary logon tweaks to safe values (`DisableCAD=0`, `DevicePasswordLessBuildVersion=2`).
- Delete attempts for already-absent values are treated as idempotent (raw `reg.exe` RCs may be non-zero), but AccessDenied is never treated as success: if Winlogon cleanup attempts are blocked for SYSTEM (AccessDenied), Stage B forces recovery posture, suppresses teardown, and preserves the AccessDenied signal (effective rc=5) even if a later verification probe would observe an already-clean Winlogon state.
- Logs do not contain passwords (only facts and length/classes during generation).
- `SetupComplete.cmd` emits exactly one canonical final status line for autologon arming: `L2C_AUTOLOGON_STATUS armed=... degraded=... marker=HKLM\\SOFTWARE\\L2C\\AutologonPrimed`. Other related log lines are event-only (`..._BEGIN/OK/FAILED/ROLLBACK`) and must not be interpreted as the final armed state.

The primary admin account password is **never** stored in `DefaultPassword`. It comes from a separate file secret `.primaryadmin.pw`; `SetupComplete.cmd` calls `ValidateSecrets.ps1` (passing both secret paths) and decodes the 0-3 exit-code bitmask (bit0=bootstrap, bit1=primary admin) to confirm ACL/attributes before reading anything. Exit code `4` is treated as an internal validator failure and closes the gate, and any other out-of-contract exit code is treated as unexpected execution failure (logged as `[ERROR]` and fail closed). For visibility, `SetupComplete.log` always logs `.primaryadmin.pw` presence and SEC-2 ACL/attributes status (OK/BAD, or skipped/unknown); when `FAILED=1` it does not read `.primaryadmin.pw` content and logs that the content load was skipped due to earlier failure. It loads the primary secret only when the bitmask reports both secrets as valid and primes autologon only when both secrets have been validated and read. `CreatePrimaryAdmin.ps1` reads the secret directly under SYSTEM during Stage A, so the `\L2C\CreatePrimaryAdmin` task command line contains no password. Winlogon via `DefaultPassword` therefore sees only the temporary `bootstrap` password, not the primary admin password.

## Temporary autologon & secret handling

* While primed, Winlogon holds `DefaultPassword`; Stage B removes it and restores `DisableCAD=0` and `Ngc...=2`, and verifies that `DefaultPassword` is absent and autologon values are absent or `0` before teardown proceeds.
* Winlogon autologon follows an all-or-nothing model: `SetupComplete.cmd` creates the `\L2C\CreatePrimaryAdmin` executor task first; only then it writes `DefaultPassword` via PowerShell / `reg.exe`, checks the return code, and only if it is `0` enables `AutoAdminLogon` and `ForceAutoLogon`. After Winlogon priming completes it attempts to write the non-secret arming marker `HKLM\SOFTWARE\L2C\AutologonPrimed=1`. If any priming sub-step fails after task creation (including Winlogon toggle setup), it logs a single `[ERROR]`, rolls back Winlogon autologon-related values, attempts best-effort deletion of the task, and enters SetupComplete recovery mode (`FAILED=1`; extra registrations suppressed). If Winlogon priming succeeded but the marker write fails, `SetupComplete.cmd` rolls back Winlogon autologon, keeps the task, and requires manual login to trigger Stage B.
* `.bootstrap.pw` is created by `BootstrapLocalAdmin.ps1` at `%WINDIR%\Setup\Scripts\.bootstrap.pw` using an atomic create-with-DACL model (CreateNew + FileSecurity: the intended DACL is applied at creation time, then verified fail-closed), with inheritance disabled (protected DACL; `AreAccessRulesProtected=True`) and Hidden+System attributes. Verification fails closed if any inherited ACEs are present, any non-Allow (including Deny) ACEs are present, or any explicit ACE references a SID other than `NT AUTHORITY\SYSTEM` (S-1-5-18) and the local Administrators group (S-1-5-32-544). The validator does not rely on `ACE count == 2`: multiple explicit Allow ACEs for the required SIDs are acceptable as long as each required SID’s effective rights (union of Allow ACE rights) include FullControl. Creation or ACL/attribute hardening failures stop Stage A instead of leaving a weak secret on disk.
* `.primaryadmin.pw` must be provisioned ahead of time (for example when building `install.wim`) in the same location and with the same ACL and attribute shape as `.bootstrap.pw` (validated fail-closed by `ValidateSecrets.ps1` and the `SetupComplete.cmd` gate before it is read). Its contents must be a single non-empty UTF-8 (no BOM) line made only of `A-Z`, `a-z`, `0-9`, `#`, `@`, `_`, and `-`; unsupported characters are rejected before autologon is ever enabled.
* At the start of `SetupComplete.cmd`, `ValidateSecrets.ps1` (StrictMode, `$ErrorActionPreference='Stop'`) checks that both secret files are leaf files, have inheritance disabled (protected DACL; no inherited ACEs), include Hidden+System attributes, and have Allow-only ACEs for `NT AUTHORITY\SYSTEM` (S-1-5-18) and the local Administrators group (S-1-5-32-544) only, where each required SID's effective rights include FullControl. It never reads the passwords; instead it returns a 0-3 exit-code bitmask (bit0=bootstrap secret valid, bit1=primary admin secret valid); an internal validator error is returned as exit code `4`. Identity/SID translation failures are handled as normal validation failures (not `4`) and are logged as `[SECRETS] FAIL: path=... reason=identity_translate_failed: raw=...`. `SetupComplete.cmd` decodes `0..3` only; when `RC=4` it logs a validator failure, sets `FAILED=1`, keeps both flags at `0`, and stays in recovery. Any other out-of-contract validator exit code is treated as unexpected execution failure: it is logged as `[ERROR]`, the gate is closed, and in the secrets gate unexpected-RC branch `:track_rc_secrets` captures the first out-of-contract rc verbatim (including `3010`/`1641`) for final RC aggregation.
* `SetupComplete.cmd` enforces a single gate for temporary logon policy relaxations, Winlogon autologon, and registration of `\L2C\CreatePrimaryAdmin`: `FAILED=0`, `.bootstrap.pw` exists and is non-empty, `.primaryadmin.pw` is present, the validator exit code reports both secrets as valid, and `.primaryadmin.pw` is read successfully. If any condition fails (including either bit being `0` or `RC=4` from the validator), it logs why, skips autologon and Stage B registration, keeps only safe policy changes, and exits in SetupComplete recovery with a non-zero RC.
* `.bootstrap.pw` first-line content is validated against the allowed character set at the `SetupComplete.cmd` gate; invalid characters fail closed (`FAILED=1`), skip autologon/Stage B registration, and emit an explicit `[ERROR]` without logging secret contents.
* With the gate open, `SetupComplete.cmd` relaxes `DisableCAD`/`DevicePasswordLessBuildVersion`, creates the Stage B executor task, and then primes Winlogon with `DefaultUserName=bootstrap`, `DefaultDomainName=%COMPUTERNAME%`, and `DefaultPassword` read from the first line of `.bootstrap.pw`. Passwords never appear in the task definition or command lines; only `DefaultPassword` holds the temporary bootstrap secret and only until Stage B runs (or until SetupComplete rolls it back on a priming failure).
* Marker lifecycle: `SetupComplete.cmd` best-effort deletes `HKLM\SOFTWARE\L2C\AutologonPrimed` when it rolls back Winlogon autologon state, and Stage B of `CreatePrimaryAdmin.ps1` best-effort deletes the same marker during its cleanup (logs `FAILSAFE_MARKER_DELETE attempted/ok/failed ...`).
* PreOOBE anomaly marker (observability only): on `BOOTSTRAP_SECRET_DELETE_FAILED`, `BootstrapLocalAdmin.ps1` best-effort writes `%WINDIR%\Panther\preoobe_warnings.flag` with a stable token (`BOOTSTRAP_SECRET_DELETE_FAILED`). `PreOOBE.cmd` logs a non-blocking WARN when the marker is detected. After `OUTCOME: SUCCESS`, Stage B logs a WARN if the marker exists and attempts best-effort deletion (WARN on delete failure).
* The secrets are expected to exist on disk only from the PreOOBE/bootstrap step (and operator provisioning of `.primaryadmin.pw`) through the end of Stage B in the normal success path. In the normal Stage B path, when `TeardownEligible` is true (normal mode and both Winlogon cleanup and logon policy restore are verified), the scheduled task is removed and both secrets are deleted; otherwise both secrets are preserved; if either delete operation fails (`cleanup state = error`) Stage B is treated as failed, the master log records `OUTCOME: FAIL - secret cleanup error`, `StageB_Succeeded` stays false, and automatic reboot is suppressed even when the Panther flag exists. In recovery they are intentionally preserved (and logged) for a later retry.
* WARN/ERROR entries about `.bootstrap.pw` or `.primaryadmin.pw` in Stage B logs (ACL, read/validation, delete failures) are intentional signals; operators should treat them as triggers for manual review rather than noise.
* Any relaxation of these `.bootstrap.pw` / `.primaryadmin.pw` requirements (ACL shape, retention beyond Stage B, validation constraints, logging guarantees) must be treated as a security decision and recorded in `DECISIONS.md` before code changes.
* The restricted character set and single-line format are deliberate to keep parsing predictable, avoid encoding/logging ambiguity, and ensure the validator and Stage A can reason about the secret safely. Do not widen the allowed set without a recorded security decision in `DECISIONS.md`.
* The Stage B master log (`%ProgramData%\l2c_master_<timestamp>.log`) records the Panther flag state before the Stage B decision and logs whether the flag was consumed for reboot, cleared as stale, or suppressed, giving operators an auditable trail for reboot outcomes.

### ValidateSecrets internal failures

* `ValidateSecrets.ps1` runs under `Set-StrictMode -Version Latest` with `$ErrorActionPreference='Stop'` and can still encounter internal failures (for example an unhandled exception in the validation logic). In those cases it logs diagnostics and exits with code `4`.
* `SetupComplete.cmd` treats exit `4` as a hard validation failure: it logs an explicit internal error, sets `FAILED=1`, and does not register Stage B.
* Any other `ValidateSecrets.ps1` exit code outside `0-3` and `4` in secrets-mode is treated as unexpected/out-of-contract execution failure: `SetupComplete.cmd` logs an `[ERROR]`, sets `FAILED=1`, and does not register Stage B.
* Exit codes `0-3` retain their bitmask meaning; when either bit is `0`, treat the secrets as unusable and use the logs to determine whether misconfigured secret files or validation failures are the root cause.

## Primary admin password source file (.primaryadmin.pw)

* Path and ownership: `%WINDIR%\Setup\Scripts\.primaryadmin.pw`, created and maintained by the operator (not generated by the scripts). The baseline scripts only read and later delete it on the normal success path (otherwise it is preserved for retry).
* Format and encoding: UTF-8 without BOM; only the first line is consumed via `set /p` and must be non-empty as read; allowed characters: `A-Z`, `a-z`, `0-9`, `#`, `@`, `_`, `-`. Whitespace or other characters are invalid. A trailing end-of-line after the password is fine; leading blank lines render the secret unusable.
* Content rules: the file is treated as a single-line secret. `SetupComplete.cmd` reads the first line only via `set /p`, and Stage A of `CreatePrimaryAdmin.ps1` reads only the first line via `Get-Content -TotalCount 1` and trims the trailing end-of-line. Missing files, empty files, or first lines that are empty or whitespace-only are treated as unusable and keep the gate closed. Additional lines after the first are ignored; this does not weaken security but can mislead operators if the password is placed on a later line.
* ACLs and attributes: inheritance disabled; explicit FullControl for `NT AUTHORITY\SYSTEM` and local Administrators only; Hidden+System attributes. `ValidateSecrets.ps1` verifies this shape up front and encodes the result in the exit-code bitmask; if the check fails, `SetupComplete.cmd` treats it as a hard failure and never reads the secret.
* Consumption and lifecycle: `SetupComplete.cmd` reads the first line of `.primaryadmin.pw` via `set /p` only after the ACL/attribute check succeeds; if the file is missing, unreadable, or the first line is empty/whitespace-only or contains unsupported characters, the combined gate fails and autologon/Stage B registration are skipped. Stage A of `CreatePrimaryAdmin.ps1` re-reads the file under SYSTEM and aborts if it cannot load or validate the password. The `\L2C\CreatePrimaryAdmin` task `/TR` contains no password or secret arguments. The `primaryadmin` password is never passed to `net.exe`; it is applied via `Microsoft.PowerShell.LocalAccounts` (`New-LocalUser`/`Set-LocalUser` with a `SecureString`) inside Stage A. In the normal Stage B path, when `TeardownEligible` is true (normal mode and both Winlogon cleanup and logon policy restore are verified), both `.bootstrap.pw` and `.primaryadmin.pw` are deleted and the result is logged; otherwise both are preserved; in the recovery path, both are preserved, `_needs_reboot.flag` remains, and logs clearly indicate that secrets were retained for manual investigation and possible retry.
* Consequences: the primary admin password is never generated or guessed by the baseline; logs never contain the password itself, only validation outcomes; failure to read or validate `.primaryadmin.pw` stops unattended primary admin provisioning instead of silently weakening security.

## Secret threat model

* For the long-lived primary admin (`primaryadmin`), the password is never placed on any process command line and does not appear in Windows Security 4688 process creation events even when command-line logging is enabled. The baseline does not intentionally log this password anywhere. The value lives only in `.primaryadmin.pw` (Hidden+System, inheritance disabled, explicit `SYSTEM` + local Administrators ACL) and is applied via `Microsoft.PowerShell.LocalAccounts` (`New-LocalUser`/`Set-LocalUser` with a `SecureString`) inside `CreatePrimaryAdmin.ps1`; no `net.exe user <password>` calls remain.
* Stage A failure handling remains fail-closed and observable: if user provisioning fails after Stage A created `primaryadmin` during this run, Stage A attempts best-effort rollback via `Remove-LocalUser` and throws, forcing recovery mode; if the account already existed, Stage A throws without deleting the user. Recovery mode preserves secrets and the bootstrap account so the operator can investigate and retry.
* The temporary `bootstrap` administrator password is set during the early PreOOBE phase by `BootstrapLocalAdmin.ps1` using `Microsoft.PowerShell.LocalAccounts` cmdlets with a `SecureString` password, so `BootstrapLocalAdmin.ps1` does not pass the password as an argument on an external process command line (mitigating exposure in Security 4688 command-line auditing and EDR/telemetry). This is still a short-lived account that is disabled and cleaned up by the end of the pipeline. If ACL hardening of `%WINDIR%\Setup\Scripts\.bootstrap.pw` fails in `BootstrapLocalAdmin.ps1`, the script attempts to delete the secret when the file exists on disk and logs the delete attempt/success/failure in `PreOOBE.log`; if the file is already absent there is no separate `nothing-to-delete` log line; when the file ends up missing or empty as a result, `ValidateSecrets`/`SetupComplete` treat it as `bootstrap=0`, keep the gate closed, and do not register Stage B.
* Password values never appear in Task Scheduler definitions or intentional logs; the only storage locations are the hardened on-disk secrets (`.bootstrap.pw` and `.primaryadmin.pw`) with Hidden+System attributes and explicit `SYSTEM` + Administrators ACLs.
* Attempts to weaken those secrets (extra ACEs, inheritance enabled, missing attributes, deleting or emptying `.primaryadmin.pw`, or using unsupported characters) cause `SetupComplete.cmd` to fail closed: no temporary autologon, no Stage B registration, and an exit that requires interactive follow-up using the logs.
* Stage B logs a cleanup state per secret in the master log (`removed`, `missing`, `error`, `preserved`, or `skipped`). Any `cleanup state=error` is a security-significant deviation: secrets may remain on disk, the run is forced to FAIL, and automatic reboot is suppressed. Operational procedures must include locating and securely removing any leftover `.bootstrap.pw` / `.primaryadmin.pw` and investigating why deletion failed.
* Happy path: both secrets are provisioned correctly, the gate opens once, a single automatic `bootstrap` logon runs Stage B, the system migrates to `primaryadmin`, disables `bootstrap`, removes the secrets and scheduled task, restores logon policies, and, if the Panther flag was present, performs the tri-state decision (reboot, stale-clear without reboot, or conservative reboot on unknown).
* TOCTOU and local administrators/SYSTEM: secret ACL and content checks happen at discrete points in the pipeline (ValidateSecrets.ps1 in SetupComplete, the gate logic in SetupComplete.cmd, and Stage A of CreatePrimaryAdmin.ps1). Note: `.bootstrap.pw` creation itself avoids the write-then-ACL TOCTOU window by applying the intended DACL at creation time and verifying it fail-closed. A local administrator or code running as SYSTEM can still modify `.bootstrap.pw` or `.primaryadmin.pw` between later steps. This is an accepted TOCTOU limitation: the baseline does not attempt to protect against an attacker who already has local administrator or SYSTEM privileges on the machine; its goal is to prevent misconfiguration and secret leakage on otherwise trusted hosts.

## CreatePrimaryAdmin scheduled task tampering boundary (non-admin)

The `\L2C\CreatePrimaryAdmin` task runs as `SYSTEM` so Stage A can apply secrets without passing passwords on task arguments. This baseline does **not** attempt to defend against attackers who already have local administrator or `SYSTEM` rights.

Non-admin boundary: `SetupComplete.cmd` validates that these objects do not grant `Allow` write-like rights to `Everyone (S-1-1-0)`, `BUILTIN\Users (S-1-5-32-545)`, `Authenticated Users (S-1-5-11)`, or `INTERACTIVE (S-1-5-4)`:

* `%WINDIR%\Setup\Scripts` (directory)
* `%WINDIR%\Setup\Scripts\CreatePrimaryAdmin.ps1` (file)
* `%SystemRoot%\System32\Tasks\L2C\CreatePrimaryAdmin` (task definition file)
* `%SystemRoot%\System32\Tasks\L2C` (directory)

`SetupComplete.cmd` hardens `%SystemRoot%\System32\Tasks\L2C` before task creation and logs `[ACLBOUNDARY] Hardened task_dir=...`.

Unsafe rights for this boundary are: `WriteData`, `AppendData`, `WriteAttributes`, `WriteExtendedAttributes`, `Delete`, `DeleteSubdirectoriesAndFiles`, `ChangePermissions`, and `TakeOwnership`, plus explicit `Write`/`Modify`/`FullControl` checks.
Note: `icacls` or ACL displays may show additional rights such as `Synchronize` alongside Modify/FullControl. `Synchronize` alone is not the unsafe criterion; the boundary is enforced on write-like and control rights as implemented.

Enforcement: `SetupComplete.cmd` invokes `ValidateSecrets.ps1` ACL boundary modes before and after task registration and fails closed when unsafe.

Evidence: `%WINDIR%\Panther\SetupComplete.log` includes `[ACLBOUNDARY] PASS ...` / `[ACLBOUNDARY] FAIL ...` and `[ACLBOUNDARY] Hardened task_dir=...`; on FAIL it includes structured evidence like `[ERROR] ACLBOUNDARY_TASKDIR_HARDEN_FAILED rc=... step=... dir=...` and may include `icacls` output depending on failure mode. On post-check failure it logs `[ACLBOUNDARY] Task delete rc=...`. On unresolved identity with unsafe Allow rights it can include `[ACLBOUNDARY] Unsafe Allow ACE (identity_unresolved_fail_closed): path=... id=... rights=... hint=Resolve identity to SID or remove unsafe Allow ACE; rerun validation.` or `[ACLBOUNDARY] Unsafe Allow ACE (identity_unresolved_fail_closed, domain_possible): path=... id=... rights=... hint=Resolve identity to SID (name-resolution, possibly domain/DC/network) or remove unsafe Allow ACE; rerun validation.` (`domain_possible` is a heuristic based on `id=X\Y` format, excluding built-in prefixes).


## Logon policies: temporary relaxation and restore

During priming:
- `DisableCAD=1`, `DevicePasswordLessBuildVersion=0` (gate-controlled temporary tweak for AutoAdminLogon). `IgnoreShiftOverride=0 (REG_SZ, with no intermediate "1")` is enforced separately (not gate-controlled).

On rollback:
- `DisableCAD=0`, `IgnoreShiftOverride=0 (REG_SZ)`.
- `DevicePasswordLessBuildVersion=2` in the normal Stage B path; `0` in the recovery Stage B path.

The restore guarantee is provided by the idempotent logic in `CreatePrimaryAdmin.ps1`.

Safety invariant: teardown (disabling `bootstrap`, deleting the `\L2C\CreatePrimaryAdmin` task, deleting `.bootstrap.pw` / `.primaryadmin.pw`) must not occur unless logon policy restore is verified, even if Winlogon cleanup verification passed.

In the normal Stage B path:

* `DisableCAD` is returned to `0`, `DevicePasswordLessBuildVersion` is set to `2`, the `bootstrap` account is disabled, the `\L2C\CreatePrimaryAdmin` task is removed, and (when TeardownEligible is true: normal mode and both Winlogon cleanup and logon policy restore are verified) `.bootstrap.pw` and `.primaryadmin.pw` are deleted; if verification failed, both secrets are preserved. If the Panther flag is present and Stage B completed successfully in the normal path, it is logged and Stage B performs the tri-state decision: `state=true` consumes the flag and reboots, `state=false` clears the stale flag without reboot, `state=unknown` reboots conservatively.

In the recovery Stage B path:

* `DevicePasswordLessBuildVersion` remains `0`, the `bootstrap` account and the `\L2C\CreatePrimaryAdmin` task stay enabled for diagnostics, the password source files are preserved, and, if the Panther flag is present, it is logged, no automatic reboot is performed, and the flag is left in place for operator follow-up.
