# Operations

## Purpose and Use

Use this document for operator procedures around preparation, secret handling, runtime evidence, manual continuation boundaries, and post-run checks.

The operator is responsible for preparing the installation inputs, reading the current-run evidence, handling retained recovery state appropriately, performing only the supported manual actions described here, and verifying the resulting machine state after the run.

Use `docs/PIPELINE_FLOW.md` for runtime sequence and handoff logic.

Use `docs/TROUBLESHOOTING.md` for diagnosis, failure analysis, and recovery work.

## Offline Tamper Protection Media Preparation

The supported deployment starts from the exact Windows image that Setup will install after that image has been prepared offline. Before first boot, the offline SOFTWARE hive of that selected image must contain:

`HKLM\SOFTWARE\Microsoft\Windows Defender\Features\TamperProtection = REG_DWORD 4`

The preparation contract is:

- preserve the existing ACLs on the Defender `Features` key;
- do not create or synthesize `TamperProtectionSource`;
- commit the prepared image and use that same image for installation;
- verify the resulting first-boot deployment against the final Defender and Behavior Monitoring state in [Validation](VALIDATION.md).

This is an operator-owned media-preparation prerequisite, not a `SetupComplete.cmd` action and not a new runtime stage. The repository does not require one host-side implementation. A genuinely offline WinPE workflow or an equivalent method may satisfy the same contract when it establishes and verifies these conditions; the complete validation record in [Validation](VALIDATION.md) applies to the tested fresh-deployment path.

### Tested Windows-host example

The tested Windows-host approach mounts the selected WIM index, loads its offline SOFTWARE hive under a temporary host registry name, sets only the `TamperProtection` value, and commits the image. Perform the mutation from LocalSystem or an equivalent sufficiently authoritative offline context; an elevated Administrator token may be unable to write the protected key.

For that example:

1. Identify the exact WIM image and index that Windows Setup will install.
2. Mount that index with the Windows servicing tools, then load its `Windows\System32\Config\SOFTWARE` hive under an operator-chosen temporary name such as `HKLM\L2C_OfflineSoftware` (for example, `reg load HKLM\L2C_OfflineSoftware <mount>\Windows\System32\Config\SOFTWARE`).
3. In the loaded hive, confirm the existing `Microsoft\Windows Defender\Features` key, then set only its `TamperProtection` value to `REG_DWORD 4` (for example, `reg add "HKLM\L2C_OfflineSoftware\Microsoft\Windows Defender\Features" /v TamperProtection /t REG_DWORD /d 4 /f`), read it back. If the key is missing or the value cannot be read back, stop. Do not take ownership, rewrite the key ACL, or add a replacement source value merely to complete the edit.
4. Unload the temporary hive (for example, `reg unload HKLM\L2C_OfflineSoftware`), dismount the selected image with its changes committed (for example, the servicing tool's `/Unmount-Image ... /Commit` operation), and verify that the installation media still selects that committed image/index.

If the hive cannot be unloaded cleanly or the value cannot be read back, do not treat the media as prepared. An equivalent offline method must provide the same invariant and commit/use evidence; the temporary hive name and `reg load` sequence are implementation details of this example.

## Preparation Before Installation

Before installation, prepare:

- supported Windows 11 Enterprise LTSC 2024 installation media;
- `Autounattend.xml` at the media root;
- these baseline files under `%WINDIR%\Setup\Scripts`:
  - `PreOOBE.cmd`
  - `SetupComplete.cmd`
  - `BootstrapLocalAdmin.ps1`
  - `ConfigureDefenderPrivacy.ps1`
  - `ValidateSecrets.ps1`
  - `CreatePrimaryAdmin.ps1`
  - `BaselinePolicies.txt`
- a trusted operator-supplied Microsoft `LGPO.exe` staged as `%WINDIR%\Setup\Scripts\LGPO.exe`; this executable is not tracked or automatically acquired by the repository;
- `%WINDIR%\Setup\Scripts\.primaryadmin.pw` as the required operator-supplied secret input.

## Secret Handling Rules

Treat the secret files under `%WINDIR%\Setup\Scripts` as temporary workflow inputs, not as steady-state configuration.

`.primaryadmin.pw` is operator-supplied. `.bootstrap.pw` is pipeline-generated for the temporary `bootstrap` account. In the normal completed path, both files are expected to be removed during finalization. If either file remains after degraded, interrupted, or recovery execution, treat it as retained recovery state.

### Primary admin secret contract

`%WINDIR%\Setup\Scripts\.primaryadmin.pw` must meet these requirements:

- UTF-8 without BOM;
- single-line secret, with only the first line consumed;
- first line must be non-empty;
- no leading or trailing whitespace;
- allowed characters are `A-Z`, `a-z`, `0-9`, `#`, `@`, `_`, and `-`;
- inheritance disabled;
- explicit FullControl only for `NT AUTHORITY\SYSTEM` and local Administrators;
- Hidden and System attributes present.

Additional lines are ignored. The password must be on the first line.

If these requirements are not met, the gate stays closed and the baseline does not arm the normal first-logon continuation.

### Bootstrap secret reference

`%WINDIR%\Setup\Scripts\.bootstrap.pw` is created by the baseline during the bootstrap phase and is not operator-supplied.

Treat it as a temporary secret file with the same protected handling expectations:

- UTF-8 without BOM;
- single-line secret;
- inheritance disabled;
- explicit FullControl only for `NT AUTHORITY\SYSTEM` and local Administrators;
- Hidden and System attributes present.

In the normal completed path, this file is removed during finalization. If it remains, treat it as retained recovery state, not as normal completion.

## Runtime Evidence

Use the current-run logs as the primary evidence for what happened during the run.

### Key log files

- `%WINDIR%\Panther\PreOOBE.log`
- `%WINDIR%\Panther\SetupComplete.log`
- `%ProgramData%\l2c_master_<timestamp>.log`
- `%WINDIR%\Logs\DISM\SetupComplete-DISM.log`

### What each log shows

- `PreOOBE.log` shows specialize-phase policy work, bootstrap provisioning status, and bootstrap output lines that help confirm whether early bootstrap completed cleanly.
- `SetupComplete.log` shows the mandatory combined Local GPO baseline import, `[DEFENDER-PRIVACY]` policy/effective-state results and any hardening warning, secret-gate results, Stage B registration decisions, recovery transitions, reboot-flag handling, reboot-finalization errors, and the SetupComplete-side outcome for the current run.
- `l2c_master_<timestamp>.log`, when present, is the main evidence for Stage A and Stage B outcome, teardown/finalization progress, and any per-secret cleanup-state records it actually contains after continuation. When Stage B reaches secret cleanup and successfully persists the relevant evidence, it records one resolved state for each secret; an earlier Stage B exception or master-log persistence/finalization failure can leave the log absent, incomplete, or without one or both records, so its existence alone does not prove that both records are available. Its reboot-preparation entries do not prove that shutdown scheduling was accepted; use `SetupComplete.log` and the process result for reboot-finalization failures.
- `SetupComplete-DISM.log` is the consolidated DISM servicing trace for SetupComplete-time servicing work.

### What to look for first

Before deciding how far the run progressed, check whether:

- `SetupComplete.log` shows `[SECTION] System-wide Local GPO baseline` followed by `[INFO] Local GPO baseline import succeeded rc=0` on the normal path;
- `SetupComplete.log` shows the Defender privacy policy and effective-state result that was observable when the component ran, plus any corresponding hardening-warning summary;
- `SetupComplete.log` shows the expected current-run outcome;
- the Stage B master log, if present, shows the expected Stage A and Stage B outcome and is authoritative for each cleanup-state record it actually contains;
- each recorded cleanup state matches the observed secret-file state; if either record is absent, correlate `SetupComplete.log` and verify actual file presence or absence instead of inferring a state;
- reboot-flag handling in the logs matches the final machine state;
- if automatic reboot was expected, `SetupComplete.log` and the process result show whether shutdown scheduling was accepted; a master-log preparation entry alone is not acceptance evidence.

## Manual Actions and Recovery Boundaries

### Manual continuation boundaries

If normal completion does not happen, the following operator actions are supported:

- inspect the current-run logs;
- use the supported manual sign-in path if the baseline has degraded into a manual-login continuation;
- follow documented operator and troubleshooting guidance before deleting or replacing retained artifacts.

The following actions are not supported in this state:

- forcing a substitute continuation path without documented recovery guidance;
- treating a degraded manual-login path as equivalent to normal unattended completion;
- deleting retained recovery artifacts before their role is understood;
- treating partial completion as final steady state.

A manual-login continuation is a bounded degraded path, not normal unattended completion. Before proceeding, verify the current-run logs and the actual machine state.

Use `docs/TROUBLESHOOTING.md` when the remaining state must be diagnosed or interpreted in detail.

### Defender privacy final-state verification and remediation

A Defender privacy posture warning during SetupComplete is a point-in-time, non-fatal hardening result. Allow the normal provisioning reboot to complete before deciding whether remediation is needed, then use the retained `ConfigureDefenderPrivacy.ps1` as the canonical machine-readable verification entry point for its two owned privacy policies from an already elevated Windows PowerShell session. It does not apply or certify the Behavior Monitoring Local GPO policy; inspect that policy and its effective/runtime state separately below.

The desired final deployment state is:

- offline `TamperProtection=REG_DWORD 4`;
- observed `IsTamperProtected=False`;
- `MAPSReporting=0`;
- effective `SubmitSamplesConsent=2`;
- policy `SpynetReporting=0` and policy `SubmitSamplesConsent=2`;
- Microsoft Defender Antivirus enabled;
- real-time protection, On-Access protection, IOAV protection, and applicable NIS protection enabled;
- Behavior Monitoring intentionally disabled: the Local GPO Computer record and machine-policy `DisableBehaviorMonitoring=1`, effective `Get-MpPreference.DisableBehaviorMonitoring=True`, and runtime `Get-MpComputerStatus.BehaviorMonitorEnabled=False` agree;
- `PUAProtection=1`.

Windows Security may visibly warn because Tamper Protection is Off. That warning is independent of the intentional Behavior Monitoring disablement and does not indicate that Microsoft Defender Antivirus or the explicitly retained real-time, On-Access, IOAV, NIS, and PUA protections have changed.

The privacy component has narrower semantics: for its own result, either observed `IsTamperProtected` value can accompany effective `MAPSReporting=0` and `SubmitSamplesConsent=2`. That component-level rule does not relax the overall deployment acceptance requirement for Tamper Protection Off.

If effective MAPS/sample state differs from `0` / `2`, inspect the effective Defender policy state and rerun the retained component from an already elevated Windows PowerShell session after resolving the policy enforcement issue. The component does not self-elevate and does not disable or bypass Tamper Protection.

```powershell
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$env:WINDIR\Setup\Scripts\ConfigureDefenderPrivacy.ps1"
```

Read `$LASTEXITCODE` immediately after the command:

- `0` means both owned registry policy values and the desired effective Defender privacy posture were verified;
- `2` means policy application and state inspection completed, but effective `MAPSReporting` or `SubmitSamplesConsent` did not match the required values; inspect the observed Tamper Protection state and effective MAPS/sample state;
- `1` means a technical execution or verification failure.

`-ExecutionPolicy Bypass` applies only to the spawned Windows PowerShell process and does not permanently change PowerShell execution policy.

The component directly manages the two privacy machine-policy registry values; it does not write corresponding Local GPO `Registry.pol` state. `gpedit.msc` may therefore show those privacy Administrative Template settings as Not Configured even when the owned registry values and privacy effective state are correct. Do not use that display alone as failure evidence, and do not conflate this direct privacy profile with the `BaselinePolicies.txt` Local GPO declarations. The BM Computer record must be checked in the Local GPO source and effective/runtime layers separately.

### Retained recovery state

If the flow stops or degrades, recovery-related state may remain in place:

- secret files such as `%WINDIR%\Setup\Scripts\.primaryadmin.pw` or `%WINDIR%\Setup\Scripts\.bootstrap.pw`;
- the scheduled task `\L2C\CreatePrimaryAdmin`, if it had already been registered;
- the temporary `bootstrap` account in an enabled state;
- logon-related state that has not yet been fully normalized, such as Winlogon cleanup state, recovery-mode policy state, or `HKLM\SOFTWARE\L2C\AutologonPrimed`;
- `%WINDIR%\Panther\_needs_reboot.flag`, if a reboot is still pending but automatic reboot was suppressed or not completed.

Treat this as retained recovery state, not as normal completion.

### Secret cleanup states

When investigating a Stage B run, use current-run evidence to determine what cleanup did or did not complete. When Stage B reaches secret cleanup and successfully persists the relevant master-log evidence, the log records one resolved state for each secret. Use each record that is actually present as authoritative for that secret. An earlier Stage B exception can occur before either state is established or appended, and a master-log persistence/finalization failure can leave the log absent or incomplete; a master log may therefore be present without one or both records. A missing record means that the cleanup state is not proven by that evidence surface; do not convert it to any listed state. Correlate `%WINDIR%\Panther\SetupComplete.log` and verify actual presence or absence of `%WINDIR%\Setup\Scripts\.bootstrap.pw` and `%WINDIR%\Setup\Scripts\.primaryadmin.pw` when cleanup evidence is absent or incomplete.

- `removed`, the file was present and deleted successfully;
- `missing`, the file was not present when cleanup was attempted;
- `error`, deletion failed and the run must not be treated as normal success;
- `preserved`, the secret was intentionally kept for recovery or retry;
- `skipped`, cleanup was not attempted in the current path.

Treat a recorded `cleanup state=error` as a security-significant failure and retained recovery state, not as normal completion. Verify whether a secret remains on disk, and do not treat the machine as finalized until the cleanup failure is understood.

## Reboot Flag Handling

The current normal `SetupComplete.cmd` producer always applies `ALWAYS_REBOOT_AFTER_FIRST_LOGON=1` for the final handoff. Any earlier servicing-derived `need-reboot` evidence is intermediate and is superseded by a verified `force-reboot` marker before Stage B is armed. The Panther flag may also carry retained, manual, or externally encountered marker state across phases:

- in the normal successful path after Stage B provisioning and teardown, the verified `force-reboot` marker is consumed without a pending-reboot probe; Stage B also supports valid retained, manual, or external `need-reboot` markers, using pending state `true` or `unknown` for a conservative reboot and treating pending state `false` as stale and clearing it without reboot. The latter is not the normal successful SetupComplete producer outcome;
- for a rebooting case, Stage B positively verifies marker absence before issuing the single shutdown request. A zero shutdown result is accepted; a failed or nonzero request attempts to restore and verify the original marker, returns reboot-finalization RC 8 when no earlier failure code owns the result, and issues no automatic retry. If restoration cannot be verified, inspect the actual Panther marker state;
- in recovery or failed finalization, automatic reboot is not performed for you;
- if the flag remains in place after a degraded or failed run, treat it as manual follow-up state, not as proof of successful completion.

`OUTCOME: SUCCESS` in the Stage B master log describes successful provisioning and teardown; it does not by itself prove that shutdown scheduling was accepted. On the current normal path, that success is followed by consumption of the verified `force-reboot` marker and one controlled reboot request; a successful shutdown result proves only that the request was accepted, and Windows returns to the normal sign-in screen only after the reboot completes. Use the current-run evidence, including `SetupComplete.log` and the Stage B master log if it exists, to distinguish accepted shutdown from reboot-finalization failure. RC 8 identifies reboot-finalization failure when no earlier nonzero result takes precedence.

## Post-Run Checks

### State checks

For a normal completed run, confirm the following:

- `primaryadmin` is ready as the permanent local administrator;
- the temporary `bootstrap` account has been disabled;
- the `\L2C\CreatePrimaryAdmin` task has been removed;
- `%WINDIR%\Setup\Scripts\.bootstrap.pw` has been removed;
- `%WINDIR%\Setup\Scripts\.primaryadmin.pw` has been removed;
- `%WINDIR%\Setup\Scripts\ConfigureDefenderPrivacy.ps1` remains available;
- the machine Local GPO contains the five User entries and the Computer `DisableBehaviorMonitoring=1` entry defined by `BaselinePolicies.txt`;
- the corresponding Machine `Registry.pol`, machine-policy DWORD, effective preference and runtime Behavior Monitoring state agree with the BM validation contract;
- `TamperProtection=REG_DWORD 4` and `IsTamperProtected=False`;
- after the normal provisioning reboot, the Defender privacy final state matches the verification contract above or any remaining posture warning has been investigated;
- temporary Winlogon and logon-policy changes have been restored;
- after successful normal provisioning and teardown, the verified `force-reboot` obligation is consumed and one controlled reboot request is made; that reboot ends the temporary interactive `bootstrap` session. A successful shutdown result proves only that the request was accepted; after the reboot completes, the normal Windows sign-in screen is shown for manual `primaryadmin` sign-in. If RC 8 is returned, follow the reboot-flag and troubleshooting evidence before treating the run as normally complete; `OUTCOME: SUCCESS` alone still describes only provisioning and teardown.

### Evidence checks

Also confirm that the logs support the observed end state:

- `SetupComplete.log` confirms the successful combined Local GPO baseline import and reflects the expected SetupComplete outcome for the current run;
- the Stage B master log, if present, reflects the expected Stage A and Stage B outcome and any cleanup-state records it actually contains; its existence alone does not prove that both per-secret records persisted;
- each recorded cleanup state matches the observed file state; when a record is absent, use `SetupComplete.log` and actual file presence or absence to establish what is known;
- reboot-flag handling in the logs matches the final machine state.

If these conditions are not met, do not assume normal completion.

Use `docs/PIPELINE_FLOW.md` to understand where the flow may have stopped.

Use `docs/TROUBLESHOOTING.md` to analyze why the expected end state was not reached.

### Optional hygiene

If required by policy, remove `%WINDIR%\Panther\Unattend.xml` and `%WINDIR%\Panther\UnattendGC\*.xml` after the run.

This is operator hygiene only. The baseline scripts do not remove these files automatically.

## When To Use Troubleshooting Instead

Use `docs/TROUBLESHOOTING.md` when:

- the flow stops unexpectedly;
- the machine state does not match the expected end state;
- retained recovery state must be interpreted in detail;
- secret handling or cleanup did not complete as expected;
- task removal, logon restoration, or final cleanup could not be verified;
- recovery requires diagnosis rather than routine operator handling.
