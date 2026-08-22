# Troubleshooting

## Purpose and Use

Use this document to diagnose runs that do not complete as expected, including cases where automatic continuation does not occur or the machine remains in retained recovery state.

Start from the symptom you see. Check the current-run logs first, then compare them with the actual machine state before deleting retained artifacts, trying to continue the run by guesswork, or treating the machine as finalized.

## Symptom: Automatic Continuation Did Not Happen as Expected

Use this section when the expected continuation does not occur after SetupComplete, or when the machine lands on a normal logon screen instead of the expected continuation path.

Start with `%WINDIR%\Panther\SetupComplete.log`.

Check:

- `[SECTION] System-wide Local GPO User Configuration baseline` and any following `[ERROR]` about a missing `LGPO.exe`, missing `UserBaselinePolicies.txt`, or failed import;
- `[SECTION] Secret ACL validation (bootstrap=..., primaryadmin=...)`
- nearby `[WARN]` or `[ERROR]` lines about invalid, missing, unreadable, or malformed secret files, including internal validator errors or malformed primary admin secret content
- any line showing that `\L2C\CreatePrimaryAdmin` was scheduled
- any line showing that Winlogon priming completed, was rolled back, or degraded into manual-login continuation


Interpretation:

- if the mandatory Local GPO prerequisite or import fails, `SetupComplete.cmd` exits through the shared final return-code path before the normal baseline workload, secret validation, Stage B scheduling, or bootstrap autologon priming; a normal logon screen is therefore expected for this early fail-closed path;
- this early final path does not have to emit the recovery banner, because it is reached before the later recovery-and-reboot section;
- `TEMP_LOGON_ROLLBACK_FAILED` warnings are not expected when failure occurred before temporary logon tweaks were entered; their presence would be inconsistent with this early path;
- if secret validation passed and the scheduled task `\L2C\CreatePrimaryAdmin` was created, SetupComplete completed the preparation needed for first-logon continuation, so the failure happened later; if continuation still did not occur, verify that the scheduled task `\L2C\CreatePrimaryAdmin` is still present.
- if validation failed, the validator failed internally, or the task was never scheduled, `SetupComplete.cmd` stayed fail-closed and no automatic continuation was armed;
- if the task was kept but autologon was rolled back, the machine is in a degraded manual-login continuation path, not in normal unattended completion.

A normal logon screen does not always mean that autologon failed. AutoAdminLogon targets the console session, so in environments such as Hyper-V Enhanced Session or other RDP-based views, a logon screen can be expected even when the continuation path was armed correctly.

## Symptom: Stage B Ran but the Final State Is Not Correct

Use this section when Stage B appears to have run, but the resulting machine state does not match the expected final state.

Start with the current-run evidence. If the most recent `%ProgramData%\l2c_master_<timestamp>.log` exists, use it as the primary Stage B record. Otherwise, use `%WINDIR%\Panther\SetupComplete.log` to determine how far continuation progressed and whether finalization stopped before the master log was written.

Check:

- the final `OUTCOME:` line, if a Stage B master log exists, including whether it ends in `SUCCESS`, `FAIL`, or `ABORTED`;
- the Stage A result, including normal no-change outcomes when the account was already in the required local group;
- the Stage B result, including failed or aborted finalization;
- whether logon-policy restore or Winlogon cleanup verification failed, and whether teardown was blocked as a result;
- whether secret cleanup completed;
- whether reboot handling completed or was suppressed.

Focus on the meaning of the evidence rather than on any single line in isolation:

- `OUTCOME: SUCCESS` together with completed cleanup and restoration supports normal finalization;
- any final fail or aborted outcome means the machine must not be treated as finalized;
- retained task state, retained secrets, an enabled `bootstrap` account, or reboot suppression indicate retained recovery state rather than normal completion.

## Symptom: Failure During PreOOBE or Bootstrap Preparation

Use this section when the run appears to have failed before SetupComplete-based continuation became relevant.

Start with `%WINDIR%\Panther\PreOOBE.log`.

Check:

- `[BOOTSTRAP] [INFO|WARN|ERROR]` entries from `BootstrapLocalAdmin.ps1`
- any PreOOBE `[ERROR]` lines
- the final PreOOBE completion markers and return status

Interpretation:

- if PreOOBE failed, do not jump ahead to Stage B assumptions;
- if bootstrap preparation did not complete successfully, later continuation and cleanup steps may never have become applicable.

## Recovery Mode and Retained Recovery State

When the run stops, degrades, or fails before teardown completes after a verification failure, the machine may remain in retained recovery state. Start with `%WINDIR%\Panther\SetupComplete.log` and look for the recovery banner `*** RECOVERY_MODE_ACTIVE OPERATOR_ACTION_REQUIRED ***`, if present in the current run.

Signs of retained recovery state can include:

- `%WINDIR%\Setup\Scripts\.primaryadmin.pw`
- `%WINDIR%\Setup\Scripts\.bootstrap.pw`
- the scheduled task `\L2C\CreatePrimaryAdmin`
- an enabled `bootstrap` account
- temporary logon settings retained for recovery or continuation
- `HKLM\SOFTWARE\L2C\AutologonPrimed`
- `%WINDIR%\Panther\_needs_reboot.flag`

Treat this as deliberate retained recovery state, not as an acceptable steady state. In this state, automatic reboot may be suppressed and teardown may remain intentionally blocked until the root cause is understood.

## Secret Cleanup States and Their Meaning

In non-normal runs, use the current-run evidence to interpret per-secret cleanup state. If the Stage B master log exists, use it to read those states. Otherwise, use `%WINDIR%\Panther\SetupComplete.log` to determine whether cleanup progressed far enough to record them.

States that may be compatible with normal completion for a given artifact:

- `removed`, the file was present and deleted successfully;
- `missing`, the file was not present when cleanup was attempted.

States that indicate retained recovery state or incomplete finalization:

- `error`, deletion failed and the file may still remain on disk;
- `preserved`, the file was intentionally retained for recovery or retry;
- `skipped`, cleanup was not attempted in the current path.

Do not treat `error`, `preserved`, or `skipped` as clean finalization until the retained state is understood in the context of the rest of the evidence.

## Reboot Flag and Suppressed Reboot Cases

Use this section when a reboot did not happen as expected, when reboot handling appears incomplete, or when `%WINDIR%\Panther\_needs_reboot.flag` remains after a degraded run.

The reboot flag preserves a pending reboot requirement across continuation steps. It is not, by itself, proof that the run finished successfully.

Use `%WINDIR%\Panther\SetupComplete.log` and the Stage B master log, if it exists, to determine which case occurred:

- the flag was consumed for a controlled reboot;
- the flag was cleared as stale because no pending reboot indicators remained;
- the flag was consumed conservatively because it was not clear whether a reboot was still required;
- the flag remained because Stage B failed, recovery mode was entered, or automatic reboot was suppressed;
- continuation could not proceed because no executor task was available, or because no autologon path was available and Stage B would not run until manual logon.

If the flag remains after a degraded or failed run, treat it as a sign of retained recovery state or incomplete continuation, not as proof of successful completion.

## When To Return to Other Docs

Use these documents when the question moves beyond troubleshooting itself:

- [Operations](OPERATIONS.md), for routine handling, post-run verification, and operator hygiene;
- [Pipeline Flow](PIPELINE_FLOW.md), to understand where the happy-path sequence should have continued;
- [Security](../SECURITY.md), for secret exposure windows, temporary clear-text storage, and security posture;
- [Decisions](../DECISIONS.md), for design rationale and non-goals.
