# Security

## Purpose and Use

Use this document as the canonical security view of the baseline.

It describes the security posture, threat boundaries, assumptions, and trade-offs for the supported baseline: Windows 10 Enterprise LTSC 2021 workstations (21H2, build 19044+) in standalone or simple network environments without corporate integration or automatic proxy discovery requirements.

The baseline uses only supported Microsoft mechanisms and favors deterministic, idempotent behavior.

## Intentional trade-offs

- SmartScreen policy layers are disabled for Windows Shell and Edge.
- Microsoft Defender local protections remain enabled, while cloud/reputation verdict paths and sample submission are disabled by policy.
- Delivery Optimization is set to mode 0 (HTTP-only, no peer-to-peer).
- Windows Update runs in notify-only mode. No drivers, no preview builds, no other Microsoft products, no OS upgrade offers.
- WPAD is disabled via policies on WinINET and WinHTTP. The WinHTTP Auto-Proxy service is not forcibly disabled.
- Edge first run experience is suppressed via policy (`HKLM\SOFTWARE\Policies\Microsoft\Edge\HideFirstRunExperience=1`) to reduce extra first-boot prompts and calls.
- The baseline does not invoke `DISM /Online /Cleanup-Image /StartComponentCleanup` or `/ResetBase` automatically. Any aggressive component cleanup that removes rollback for installed updates is considered an optional, operator-driven hardening step and is not part of the core pipeline.
- Several hardening steps rely on disabling selected optional Windows features and capabilities via DISM. On LTSC images, some components may be absent, non-selectable, or otherwise unavailable; these cases are surfaced as warnings rather than treated as silent drift. Unexpected servicing failures remain fatal and do not silently weaken the baseline.

### Defender and SmartScreen Baseline

This baseline does not attempt to disable Microsoft Defender local endpoint protections. Local protections remain ON, while cloud/reputation-driven verdict paths and automatic sample submission are explicitly disabled via policy.

SmartScreen is disabled for Windows Shell and the Edge policy layer to minimize silent outbound reputation/data flows. These settings are enforced via registry policy and orchestration in `SetupComplete.cmd`.

### Edge Browser Removal and Update Suppression

Edge browser removal runs early in `SetupComplete.cmd` as a best-effort hardening layer. Edge SmartScreen policies are still set to disabled before removal, EdgeUpdate services/tasks are disabled best-effort to reduce browser resurrection, and WebView2 runtime is not removed.

- Windows Shell SmartScreen: `HKLM\SOFTWARE\Policies\Microsoft\Windows\System\EnableSmartScreen=0`
- Edge SmartScreen policies: `HKLM\SOFTWARE\Policies\Microsoft\Edge\SmartScreenEnabled=0`; `HKLM\SOFTWARE\Policies\Microsoft\Edge\SmartScreenDnsRequestsEnabled=0`; `HKLM\SOFTWARE\Policies\Microsoft\Edge\SmartScreenForTrustedDownloadsEnabled=0`; `HKLM\SOFTWARE\Policies\Microsoft\Edge\SmartScreenPuaEnabled=0`
- Defender local protections ON: `HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection\DisableRealtimeMonitoring=0`; `HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection\DisableBehaviorMonitoring=0`; `HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection\DisableIOAVProtection=0`; `HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\PUAProtection=1`
- Defender cloud/reputation/data OFF: `HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\Spynet\SpynetReporting=0`; `HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\Spynet\SubmitSamplesConsent=2`; `HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\Spynet\DisableBlockAtFirstSeen=1`; `HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\Spynet\LocalSettingOverrideSpynetReporting=0`; `HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\MpEngine\MpCloudBlockLevel=0`
- Edge lifecycle: early best-effort uninstall via Edge `setup.exe --uninstall --system-level --force-uninstall`; EdgeUpdate services/tasks disabled best-effort; WebView2 not removed
- UX hygiene: `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\DisableEdgeDesktopShortcutCreation=1`

## Not a fit if you require

- SmartScreen prompts or Defender cloud protection by policy.
- Peer-to-peer Delivery Optimization or Connected Cache scenarios.
- Automatic proxy discovery (WPAD) for WinHTTP clients.
- Guaranteed rollback of currently installed updates.
- Enterprise hardening stacks enabled by default (for example, MDE onboarding, WDAC, AppLocker, BitLocker enforcement, LAPS, or domain-based baselines).
- Disabled or lowered UAC behavior.

## Recommendations and compensating controls

- Use least-privilege accounts for daily work; avoid local admin where possible.
- If a proxy is introduced later, configure it explicitly: `netsh winhttp set proxy` or a supported policy. With WPAD disabled, auto-discovery will not occur.
- Consider periodic offline AV scans or a trusted third-party endpoint if organizational policy requires it.
- If you later re-enable Defender's real-time features, consider testing Attack Surface Reduction (ASR) rules on a VM first.

## Compatibility controls & safety

The baseline uses a fail-closed platform compatibility posture by default. Best-effort compatibility is an explicit opt-out for forks or experiments and carries the risk that some steps may not apply or may behave differently on nearby Windows versions.

## Logs

The baseline writes technical logs to `%WINDIR%\Panther\PreOOBE.log` and `%WINDIR%\Panther\SetupComplete.log`. DISM activity, when used, is additionally recorded in `%WINDIR%\Logs\DISM\SetupComplete-DISM.log`.

These logs are intended for technical review and do not intentionally include password values or derived secrets. `BootstrapLocalAdmin.ps1` emits structured lifecycle messages into `PreOOBE.log` without logging the bootstrap password, and the baseline does not intentionally place primary-admin secrets in command lines, task definitions, or intentional log output.

Set retention and deletion of these logs according to your environment's policy.

## Early privacy and account hardening

Part of the baseline's privacy and account hardening is applied early, during `specialize`, through `PreOOBE.cmd`.

This includes suppression of the privacy experience, disabling of selected telemetry- and personalization-related features, and disabling local password reset questions.

Applied controls include:

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

Effect: the privacy wizard is suppressed, the corresponding privacy-related toggles are enforced off, and local-account security questions are disabled.

## Temporary storage of the password in Winlogon during autologon

`AutoAdminLogon` requires `HKLM\...\Winlogon\DefaultPassword (REG_SZ)`. In this baseline, that value is used only temporarily, during the priming-to-first-bootstrap-logon window.

Only the temporary `bootstrap` password is ever written to `DefaultPassword`. The primary admin password is never stored there. It remains in `.primaryadmin.pw`, is validated before use, and is read directly under `SYSTEM` by `CreatePrimaryAdmin.ps1`, so the `\L2C\CreatePrimaryAdmin` task definition and command line contain no password arguments.

Risk mitigations:

- the `bootstrap` password is temporary and is removed after the first logon path is finalized;
- `SetupComplete.cmd` arms autologon only after the relevant gate checks succeed;
- if autologon priming or its non-secret marker handling fails, the baseline rolls back or falls back to manual continuation rather than silently leaving an unsafe state;
- if Winlogon cleanup verification fails, teardown is suppressed and recovery posture is preserved instead of claiming normal completion;
- logs do not intentionally include password values.

## Temporary autologon & secret handling

The baseline uses two temporary on-disk secrets during provisioning: `.bootstrap.pw` and `.primaryadmin.pw` in `%WINDIR%\Setup\Scripts`.

Both secrets are treated as hardened local files: inheritance must be disabled, access must be restricted to `NT AUTHORITY\SYSTEM` and the local Administrators group, and the files must carry the expected protected attributes. Secret validation is fail-closed: if required ACL or attribute checks fail, if required content validation fails, or if the relevant gate conditions are not met, autologon and Stage B registration do not proceed normally.

`.bootstrap.pw` provides the temporary `bootstrap` password used only for the first-logon transition. `.primaryadmin.pw` provides the primary admin password, is operator-supplied rather than generated by the baseline, and is never placed in task arguments or command lines. `CreatePrimaryAdmin.ps1` reads it directly under `SYSTEM`.

In the normal success path, the temporary executor state is removed and both secret files are deleted. Outside that path, secrets may be preserved deliberately for recovery, investigation, or retry rather than being silently discarded.

## Primary admin password source file (.primaryadmin.pw)

- Path and ownership: `%WINDIR%\Setup\Scripts\.primaryadmin.pw`, created and maintained by the operator (not generated by the scripts). The baseline scripts only read and later delete it on the normal success path (otherwise it is preserved for retry).
- Format and encoding: UTF-8 without BOM. The file is treated as a single-line secret; the first line must be non-empty and may contain only `A-Z`, `a-z`, `0-9`, `#`, `@`, `_`, and `-`. Whitespace or other characters are invalid. A trailing end-of-line after the password is fine; leading blank lines render the secret unusable.
- Content rules: the file is treated as a single-line secret. `SetupComplete.cmd` reads the first line only via `set /p`, and Stage A of `CreatePrimaryAdmin.ps1` reads only the first line via `Get-Content -TotalCount 1` and trims the trailing end-of-line. Missing files, empty files, or first lines that are empty or whitespace-only are treated as unusable and keep the gate closed. Additional lines after the first are ignored; this does not weaken security but can mislead operators if the password is placed on a later line.
- ACLs and attributes: inheritance disabled; explicit FullControl for `NT AUTHORITY\SYSTEM` and local Administrators only; Hidden+System attributes. If this required shape is not present, the baseline treats the secret as invalid and does not read it for privileged continuation.
- Consumption and lifecycle: `SetupComplete.cmd` reads `.primaryadmin.pw` only after the required ACL and attribute checks succeed; if the file is missing, unreadable, empty, or contains unsupported characters, the combined gate fails and autologon / Stage B registration are skipped. Stage A of `CreatePrimaryAdmin.ps1` re-reads the file under `SYSTEM` and aborts if it cannot load or validate the password. The `\L2C\CreatePrimaryAdmin` task contains no password or secret arguments, and the `primaryadmin` password is never passed to `net.exe`; it is applied via `Microsoft.PowerShell.LocalAccounts` (`New-LocalUser` / `Set-LocalUser` with a `SecureString`) inside Stage A. In the normal success path, both `.bootstrap.pw` and `.primaryadmin.pw` are deleted; outside that path, they may be preserved for investigation or retry.
- Consequences: the primary admin password is never generated or guessed by the baseline; logs never contain the password itself, only validation outcomes; failure to read or validate `.primaryadmin.pw` stops unattended primary admin provisioning instead of silently weakening security.

## Secret threat model

- For the long-lived primary admin (`primaryadmin`), the password is never placed on any process command line and does not appear in Windows Security 4688 process creation events even when command-line logging is enabled. The baseline does not intentionally log this password anywhere. The value lives only in `.primaryadmin.pw` (Hidden+System, inheritance disabled, explicit `SYSTEM` + local Administrators ACL) and is applied via `Microsoft.PowerShell.LocalAccounts` (`New-LocalUser`/`Set-LocalUser` with a `SecureString`) inside `CreatePrimaryAdmin.ps1`; no `net.exe user <password>` calls remain.
- Stage A failure handling remains fail-closed and observable: if user provisioning fails after Stage A created `primaryadmin` during this run, Stage A attempts best-effort rollback via `Remove-LocalUser` and throws, forcing recovery mode; if the account already existed, Stage A throws without deleting the user. Recovery mode preserves secrets and the bootstrap account so the operator can investigate and retry.
- The temporary `bootstrap` administrator password is set during the early PreOOBE phase by `BootstrapLocalAdmin.ps1` using `Microsoft.PowerShell.LocalAccounts` cmdlets with a `SecureString` password, so `BootstrapLocalAdmin.ps1` does not pass the password as an argument on an external process command line (mitigating exposure in Security 4688 command-line auditing and EDR/telemetry). This is still a short-lived account that is disabled and cleaned up by the end of the pipeline. If hardening of `%WINDIR%\Setup\Scripts\.bootstrap.pw` fails, the baseline treats the bootstrap secret as unusable, keeps the gate closed, and does not register Stage B.
- Password values never appear in Task Scheduler definitions or intentional logs; the only storage locations are the hardened on-disk secrets (`.bootstrap.pw` and `.primaryadmin.pw`) with Hidden+System attributes and explicit `SYSTEM` + Administrators ACLs.
- Attempts to weaken those secrets (extra ACEs, inheritance enabled, missing attributes, deleting or emptying `.primaryadmin.pw`, or using unsupported characters) cause `SetupComplete.cmd` to fail closed: no temporary autologon, no Stage B registration, and an exit that requires interactive follow-up using the logs.
- Stage B logs a cleanup state per secret in the master log (`removed`, `missing`, `error`, `preserved`, or `skipped`). Any `cleanup state=error` is a security-significant deviation: secrets may remain on disk, the run is forced to FAIL, and automatic reboot is suppressed.
- TOCTOU and local administrators/SYSTEM: secret ACL and content checks happen at discrete points in the pipeline (ValidateSecrets.ps1 in SetupComplete, the gate logic in SetupComplete.cmd, and Stage A of CreatePrimaryAdmin.ps1). Note: `.bootstrap.pw` creation itself avoids the write-then-ACL TOCTOU window by applying the intended DACL at creation time and verifying it fail-closed. A local administrator or code running as SYSTEM can still modify `.bootstrap.pw` or `.primaryadmin.pw` between later steps. This is an accepted TOCTOU limitation: the baseline does not attempt to protect against an attacker who already has local administrator or SYSTEM privileges on the machine; its goal is to prevent misconfiguration and secret leakage on otherwise trusted hosts.

## CreatePrimaryAdmin scheduled task tampering boundary (non-admin)

The `\L2C\CreatePrimaryAdmin` task runs as `SYSTEM` so Stage A can apply secrets without passing passwords on task arguments. This baseline does **not*- attempt to defend against attackers who already have local administrator or `SYSTEM` rights.

For the non-admin boundary, `SetupComplete.cmd` validates that these objects do not grant write-like `Allow` rights to `Everyone (S-1-1-0)`, `BUILTIN\Users (S-1-5-32-545)`, `Authenticated Users (S-1-5-11)`, or `INTERACTIVE (S-1-5-4)`:

- `%WINDIR%\Setup\Scripts` (directory)
- `%WINDIR%\Setup\Scripts\CreatePrimaryAdmin.ps1` (file)
- `%SystemRoot%\System32\Tasks\L2C\CreatePrimaryAdmin` (task definition file)
- `%SystemRoot%\System32\Tasks\L2C` (directory)

`SetupComplete.cmd` hardens `%SystemRoot%\System32\Tasks\L2C` before task creation and validates this boundary before and after task registration.

Unsafe rights for this boundary include `WriteData`, `AppendData`, `WriteAttributes`, `WriteExtendedAttributes`, `Delete`, `DeleteSubdirectoriesAndFiles`, `ChangePermissions`, and `TakeOwnership`, as well as broader `Write`, `Modify`, or `FullControl` grants. `Synchronize` alone is not treated as unsafe for this boundary.

Enforcement is fail-closed: if unsafe non-admin write access is detected, the boundary check fails, normal continuation is not trusted, and the result is recorded in `%WINDIR%\Panther\SetupComplete.log`.

## Logon policies: temporary relaxation and restore

During priming:

- `DisableCAD=1`
- `DevicePasswordLessBuildVersion=0`
- `IgnoreShiftOverride=0` (enforced separately as `REG_SZ`)

On rollback or restore:

- `DisableCAD=0`
- `IgnoreShiftOverride=0` (`REG_SZ`)
- `DevicePasswordLessBuildVersion=2` in the normal Stage B path; `0` in the recovery Stage B path

The restore guarantee is provided by the idempotent logic in `CreatePrimaryAdmin.ps1`.

Safety invariant: teardown (disabling `bootstrap`, deleting the `\L2C\CreatePrimaryAdmin` task, and deleting `.bootstrap.pw` / `.primaryadmin.pw`) must not occur unless logon policy restore is verified, even if Winlogon cleanup verification passed.

In the normal path, verified restore allows teardown to proceed. If restore verification fails or the run remains in recovery posture, teardown is suppressed and the temporary executor state and secrets may be preserved for investigation or retry.