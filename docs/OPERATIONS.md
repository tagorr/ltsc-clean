# Operations

## Purpose and Use

Use this document for operator procedures around preparation, secret handling, runtime evidence, manual continuation boundaries, and post-run checks.

The operator is responsible for preparing the installation inputs, reading the current-run evidence, handling retained recovery state appropriately, performing only the supported manual actions described here, and verifying the resulting machine state after the run.

Use `docs/PIPELINE_FLOW.md` for runtime sequence and handoff logic.

Use `docs/TROUBLESHOOTING.md` for diagnosis, failure analysis, and recovery work.

## Preparation Before Installation

Before installation, prepare:

- supported Windows 10 LTSC 2021 installation media;
- `Autounattend.xml` at the media root;
- these baseline files under `%WINDIR%\Setup\Scripts`:
  - `PreOOBE.cmd`
  - `SetupComplete.cmd`
  - `BootstrapLocalAdmin.ps1`
  - `ValidateSecrets.ps1`
  - `CreatePrimaryAdmin.ps1`
- `%WINDIR%\Setup\Scripts\.primaryadmin.pw` as the required operator-supplied secret input.

## Secret Handling Rules

Treat the secret files under `%WINDIR%\Setup\Scripts` as temporary workflow inputs, not as steady-state configuration.

`.primaryadmin.pw` is operator-supplied. `.bootstrap.pw` is pipeline-generated for the temporary `bootstrap` account. In the normal completed path, both files are expected to be removed during finalization. If either file remains after degraded, interrupted, or recovery execution, or if `bootstrap` is still enabled or `\L2C\CreatePrimaryAdmin` is still present, treat it as retained recovery state.

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
- `SetupComplete.log` shows secret-gate results, Stage B registration decisions, recovery transitions, reboot-flag handling, and the SetupComplete-side outcome for the current run.
- `l2c_master_<timestamp>.log`, if present, is the main evidence for Stage A and Stage B outcome, per-secret cleanup state, finalization progress, and reboot handling after continuation.
- `SetupComplete-DISM.log` is the consolidated DISM servicing trace for SetupComplete-time servicing work.

### What to look for first

Before deciding how far the run progressed, check whether:

- `SetupComplete.log` shows the expected current-run outcome;
- the Stage B master log, if present, shows the expected Stage A and Stage B outcome;
- secret cleanup states match the observed secret-file state;
- reboot-flag handling in the logs matches the final machine state.

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

- in the normal completed path, Stage B makes the final reboot decision and either consumes the flag for reboot, clears it as stale, or reboots conservatively on unknown state;
- in recovery or failed finalization, automatic reboot is not performed for you;
- if the flag remains in place after a degraded or failed run, treat it as manual follow-up state, not as proof of successful completion.

Use the current-run evidence, including `SetupComplete.log` and the Stage B master log if it exists, to determine which reboot outcome was reached.

## Post-Run Checks

### State checks

For a normal completed run, confirm the following:

- `primaryadmin` is ready as the permanent local administrator;
- the temporary `bootstrap` account has been disabled;
- the `\L2C\CreatePrimaryAdmin` task has been removed;
- `%WINDIR%\Setup\Scripts\.bootstrap.pw` has been removed;
- `%WINDIR%\Setup\Scripts\.primaryadmin.pw` has been removed;
- temporary Winlogon and logon-policy changes have been restored;
- the system is ready for use, or completes with a controlled reboot if a reboot is still required.

### Evidence checks

Also confirm that the logs support the observed end state:

- `SetupComplete.log` reflects the expected SetupComplete outcome for the current run;
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
