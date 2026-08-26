# Operations

## Purpose and Use

Use this document for operator procedures around preparation, secret handling, runtime evidence, manual continuation boundaries, and post-run checks.

The operator is responsible for preparing the installation inputs, reading the current-run evidence, handling retained recovery state appropriately, performing only the supported manual actions described here, and verifying the resulting machine state after the run.

Use `docs/PIPELINE_FLOW.md` for runtime sequence and handoff logic.

Use `docs/TROUBLESHOOTING.md` for diagnosis, failure analysis, and recovery work.

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
  - `UserBaselinePolicies.txt`
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
- `SetupComplete.log` shows the mandatory Local GPO User Configuration import, `[DEFENDER-PRIVACY]` policy/effective-state results and any hardening warning, secret-gate results, Stage B registration decisions, recovery transitions, reboot-flag handling, reboot-finalization errors, and the SetupComplete-side outcome for the current run.
- `l2c_master_<timestamp>.log`, if present, is the main evidence for Stage A and Stage B outcome, per-secret cleanup state, and teardown/finalization progress after continuation. Its reboot-preparation entries do not prove that shutdown scheduling was accepted; use `SetupComplete.log` and the process result for reboot-finalization failures.
- `SetupComplete-DISM.log` is the consolidated DISM servicing trace for SetupComplete-time servicing work.

### What to look for first

Before deciding how far the run progressed, check whether:

- `SetupComplete.log` shows `[SECTION] System-wide Local GPO User Configuration baseline` followed by `[INFO] Local GPO User Configuration baseline import succeeded rc=0` on the normal path;
- `SetupComplete.log` shows the Defender privacy policy and effective-state result that was observable when the component ran, plus any corresponding hardening-warning summary;
- `SetupComplete.log` shows the expected current-run outcome;
- the Stage B master log, if present, shows the expected Stage A and Stage B outcome;
- secret cleanup states match the observed secret-file state;
- reboot-flag handling in the logs matches the final machine state;
- if automatic reboot was expected, `SetupComplete.log` and the process result show whether shutdown scheduling was accepted; a master-log preparation entry alone is not acceptance evidence.

Some informational service-state lines may reflect localized `sc query` output and can vary by image language. Treat them as logging detail, not as primary control-flow evidence.

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

A Defender privacy posture warning during SetupComplete is a point-in-time, non-fatal hardening result. Allow the normal provisioning reboot to complete before deciding whether remediation is needed, then use the retained `ConfigureDefenderPrivacy.ps1` as the canonical machine-readable final verification entry point from an already elevated Windows PowerShell session. It independently verifies the owned policy registry values and the effective Defender state; the underlying `Get-MpComputerStatus` and `Get-MpPreference` values remain useful for interpreting the result.

The desired final state is:

- observed `IsTamperProtected` state (`True` or `False`);
- `MAPSReporting=0`;
- effective `SubmitSamplesConsent=2`;
- policy `SpynetReporting=0` and policy `SubmitSamplesConsent=2`;
- Microsoft Defender Antivirus, real-time protection, behavior monitoring, and IOAV protection enabled;
- `PUAProtection=1`.

Windows Security may visibly warn because Tamper Protection is Off. That warning does not mean Microsoft Defender Antivirus or its local protections are disabled.

`IsTamperProtected` may be either `True` or `False`; no Tamper Protection remediation is required when effective MAPS/sample state is `0` / `2`, even if SetupComplete recorded an earlier posture warning.

If effective MAPS/sample state differs from `0` / `2`, inspect the effective Defender policy state and rerun the retained component from an already elevated Windows PowerShell session after resolving the policy enforcement issue. The component does not self-elevate and does not disable or bypass Tamper Protection.

```powershell
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$env:WINDIR\Setup\Scripts\ConfigureDefenderPrivacy.ps1"
```

Read `$LASTEXITCODE` immediately after the command:

- `0` means both owned registry policy values and the desired effective Defender privacy posture were verified;
- `2` means policy application and state inspection completed, but effective `MAPSReporting` or `SubmitSamplesConsent` did not match the required values; inspect the observed Tamper Protection state and effective MAPS/sample state;
- `1` means a technical execution or verification failure.

`-ExecutionPolicy Bypass` applies only to the spawned Windows PowerShell process and does not permanently change PowerShell execution policy.

The component directly manages machine policy registry values; it does not write corresponding Local GPO `Registry.pol` state. `gpedit.msc` may therefore show the related Administrative Template settings as Not Configured even when both the owned policy values and Defender effective state are correct. Do not use that display alone as failure evidence, and do not conflate this machine-level profile with `UserBaselinePolicies.txt`.

### Retained recovery state

If the flow stops or degrades, recovery-related state may remain in place:

- secret files such as `%WINDIR%\Setup\Scripts\.primaryadmin.pw` or `%WINDIR%\Setup\Scripts\.bootstrap.pw`;
- the scheduled task `\L2C\CreatePrimaryAdmin`, if it had already been registered;
- the temporary `bootstrap` account in an enabled state;
- logon-related state that has not yet been fully normalized, such as Winlogon cleanup state, recovery-mode policy state, or `HKLM\SOFTWARE\L2C\AutologonPrimed`;
- `%WINDIR%\Panther\_needs_reboot.flag`, if a reboot is still pending but automatic reboot was suppressed or not completed.

Treat this as retained recovery state, not as normal completion.

### Secret cleanup states

In non-normal runs, use the current-run evidence to determine what cleanup did or did not complete. If the Stage B master log exists, use it to read the per-secret cleanup states:

- `removed`, the file was present and deleted successfully;
- `missing`, the file was not present when cleanup was attempted;
- `error`, deletion failed and the run must not be treated as normal success;
- `preserved`, the secret was intentionally kept for recovery or retry;
- `skipped`, cleanup was not attempted in the current path.

Treat `cleanup state=error` as retained recovery state, not as normal completion. Verify whether a secret remains on disk, and do not treat the machine as finalized until the cleanup failure is understood.

## Reboot Flag Handling

The baseline may use `_needs_reboot.flag` to carry a pending reboot requirement across phases:

- in normal mode after successful Stage B provisioning and teardown, `force-reboot` is consumed without a pending-reboot probe; `need-reboot` with pending state `true` or `unknown` is consumed conservatively, while pending state `false` is stale and is cleared and verified without reboot;
- for a rebooting case, Stage B positively verifies marker absence before issuing the single shutdown request. A zero shutdown result is accepted; a failed or nonzero request attempts to restore and verify the original marker, returns reboot-finalization RC 8 when no earlier failure code owns the result, and issues no automatic retry. If restoration cannot be verified, inspect the actual Panther marker state;
- in recovery or failed finalization, automatic reboot is not performed for you;
- if the flag remains in place after a degraded or failed run, treat it as manual follow-up state, not as proof of successful completion.

`OUTCOME: SUCCESS` in the Stage B master log describes successful provisioning and teardown; it does not by itself prove that shutdown scheduling was accepted. Use the current-run evidence, including `SetupComplete.log` and the Stage B master log if it exists, to determine which reboot outcome was reached. RC 8 identifies reboot-finalization failure when no earlier nonzero result takes precedence.

## Post-Run Checks

### State checks

For a normal completed run, confirm the following:

- `primaryadmin` is ready as the permanent local administrator;
- the temporary `bootstrap` account has been disabled;
- the `\L2C\CreatePrimaryAdmin` task has been removed;
- `%WINDIR%\Setup\Scripts\.bootstrap.pw` has been removed;
- `%WINDIR%\Setup\Scripts\.primaryadmin.pw` has been removed;
- `%WINDIR%\Setup\Scripts\ConfigureDefenderPrivacy.ps1` remains available;
- the machine Local GPO User Configuration contains the four entries defined by `UserBaselinePolicies.txt`;
- after the normal provisioning reboot, the Defender privacy final state matches the verification contract above or any remaining posture warning has been investigated;
- temporary Winlogon and logon-policy changes have been restored;
- when a reboot obligation exists, the existing controlled reboot occurs only after shutdown scheduling is accepted; after reboot, the normal Windows sign-in screen is shown and `primaryadmin` is signed in manually. If no reboot is required or RC 8 is returned, follow the reboot-flag and troubleshooting evidence before treating the run as normally complete.

### Evidence checks

Also confirm that the logs support the observed end state:

- `SetupComplete.log` confirms the successful Local GPO User Configuration import and reflects the expected SetupComplete outcome for the current run;
- the Stage B master log, if present, reflects the expected Stage A and Stage B outcome;
- secret cleanup states match the observed file state;
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
