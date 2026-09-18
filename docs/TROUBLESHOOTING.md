# Troubleshooting

## Purpose and Use

Use this document to diagnose runs that do not complete as expected, including cases where automatic continuation does not occur or the machine remains in retained recovery state.

Start from the symptom you see. Check the current-run logs first, then compare them with the actual machine state before deleting retained artifacts, trying to continue the run by guesswork, or treating the machine as finalized.

## Timestamp Interpretation

CMD logger lines normally use local `yyyy-MM-ddTHH:mm:ss` timestamps with no fractional seconds or timezone offset. `LOCAL_RAW` means normalized timestamp acquisition was unavailable or the date sample changed during that line; interpret the raw value using the originating machine's locale. A later logger call retries normalized-date acquisition. Local clock corrections can make timestamps move backward, and direct or component output may use another timestamp representation or be untimestamped. A `LOCAL_RAW` timestamp alone does not indicate deployment failure.

## Symptom: Automatic Continuation Did Not Happen as Expected

Use this section when the expected continuation does not occur after SetupComplete, or when the machine lands on a normal logon screen instead of the expected continuation path.

Start with `%WINDIR%\Panther\SetupComplete.log`.

Check:

- `[SECTION] System-wide Local GPO baseline` and any following `[ERROR]` about a missing `LGPO.exe`, missing `BaselinePolicies.txt`, or failed import;
- `[SECTION] Secret ACL validation (bootstrap=..., primaryadmin=...)`
- nearby `[WARN]` or `[ERROR]` lines about invalid, missing, unreadable, or malformed secret files, including internal validator errors or malformed primary admin secret content
- `[ERROR] Bootstrap account precondition failed state=...` lines, including `missing`, `disabled`, `ambiguous_or_unusable`, or `query_error`
- `[ACLBOUNDARY]` pre-check and post-check results for the Scripts directory, Stage B script, task definition, and task directory
- any line showing that `\L2C\CreatePrimaryAdmin` was scheduled
- any line showing that Winlogon priming completed, was rolled back, or degraded into manual-login continuation


Interpretation:

- if the mandatory Local GPO prerequisite or import fails, `SetupComplete.cmd` exits through the shared final return-code path before the normal baseline workload, secret validation, Stage B scheduling, or bootstrap autologon priming; a normal logon screen is therefore expected for this early fail-closed path;
- this early final path does not have to emit the recovery banner, because it is reached before the later recovery-and-reboot section;
- `TEMP_LOGON_ROLLBACK_FAILED` warnings are not expected when the mandatory Local GPO path fails before the combined secret gate establishes rollback eligibility; after eligibility is established, such warnings may occur even if the current run did not yet enter the temporary logon-policy write helper;
- if the bootstrap account precondition fails, SetupComplete closes the existing gate before task-directory hardening, task registration, temporary logon-policy writes, or Winlogon priming for that attempt; a retained or valid `.bootstrap.pw` does not prove account usability, and SetupComplete does not repair or re-enable the account;
- if secret validation passed and the scheduled task `\L2C\CreatePrimaryAdmin` was created, that proves only that task registration returned success; it does not prove that continuation preparation completed. Inspect the post-registration trust-boundary evidence, Winlogon/autologon priming outcome, any rollback evidence, and the actual presence or absence of the continuation task;
- if task creation occurred but the post-registration trust-boundary check or later priming path failed, SetupComplete may delete the task, roll back Winlogon state, or do both depending on the failure point; inspect the current log and actual task state to determine what remains;
- successful automatic continuation preparation requires the relevant trust-boundary checks and Winlogon priming to pass together with the expected continuation task state;
- if validation failed, the validator failed internally, or the task was never scheduled, `SetupComplete.cmd` stayed fail-closed and no automatic continuation was armed;
- if the log reports `L2C_AUTOLOGON_DEGRADED`/`manual_login_required=1`, the machine is in a degraded manual-login continuation path; if priming was rolled back without that degraded marker, treat the run as a failure and use the actual task state rather than assuming normal continuation.

A normal logon screen does not always mean that autologon failed. AutoAdminLogon targets the console session, so in environments such as Hyper-V Enhanced Session or other RDP-based views, a logon screen can be expected even when the continuation path was armed correctly.

## Symptom: Defender Privacy Hardening Warning

Use this section when `SetupComplete.log` contains `[DEFENDER-PRIVACY]` WARN or ERROR output, a Defender privacy hardening warning, or a final `SUCCESS_WITH_HARDENING_WARNINGS` result associated with this component.

Interpret the evidence by category:

- exit `2` means the component applied and verified its owned policy and inspected Defender state, but the effective privacy posture could not be guaranteed at that point in time;
- a technical nonzero or missing-script warning means configuration or verification could not be completed reliably and requires investigation;
- neither warning category is, by itself, a pipeline or trusted-continuation failure, so it can coexist with successful secret validation, Stage A, Stage B, cleanup, and finalization.

Allow the normal provisioning reboot to complete and inspect the final Defender state before deciding whether remediation is required. Overall deployment acceptance requires the prepared image's `TamperProtection=REG_DWORD 4` and observed `IsTamperProtected=False`. If Tamper Protection is unexpectedly On, first verify that the exact image used by Setup was prepared offline according to [Operations](OPERATIONS.md); do not attempt a runtime Tamper bypass. For the privacy component's own result, either observed `IsTamperProtected` value can accompany effective `MAPSReporting=0` / `SubmitSamplesConsent=2`, but that narrower rule does not change the overall deployment requirement.

Base privacy-component remediation on an effective `MAPSReporting=0` / `SubmitSamplesConsent=2` mismatch or an actual technical verification failure; use the canonical verification and remediation procedure in [Operations](OPERATIONS.md). The validated deployment does not rely on an automatic Tamper transition.

## Symptom: Behavior Monitoring Is Not Disabled

Use this section when the intended Behavior Monitoring suppression is not observed after deployment. The privacy component's result does not certify this state.

Check the layers independently:

- the Computer records in the parsed `%WINDIR%\System32\GroupPolicy\Machine\Registry.pol` from the `BaselinePolicies.txt` import, including the Behavior Monitoring record and the Defender Threats records;
- `HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection\DisableBehaviorMonitoring` as `REG_DWORD 1`;
- `HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\Threats\Threats_ThreatIdDefaultAction` as `REG_DWORD 1`, plus `HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\Threats\ThreatIdDefaultAction` value `2147741622` as `SZ:6`;
- `Get-MpPreference.DisableBehaviorMonitoring` as `True`;
- `Get-MpComputerStatus.BehaviorMonitorEnabled` as `False`;
- effective `ThreatIDDefaultAction_Ids=2147741622` and `ThreatIDDefaultAction_Actions=6`;
- retained Antivirus, real-time, On-Access, IOAV, applicable NIS, and PUA protection fields.

Treat a missing or wrong Behavior Monitoring or Threats policy record as an import/source problem, a missing or unreadable value as technical uncertainty, and a readable different value as a posture mismatch. If the Local GPO source remains intact while the materialized Behavior Monitoring value disappears, inspect Defender events for `DefenderTamperingRestore` (Threat ID `2147741622`) and the corresponding remediation before treating the source as lost. A successful LGPO return code, `SetupComplete` success, or `ConfigureDefenderPrivacy.ps1` exit `0` is not proof of effective Behavior Monitoring suppression. Record the offline Tamper value, `IsTamperProtected`, the BM layers, and the effective Threat ID mapping separately; if Tamper is On, verify media preparation first. Do not disable or bypass Tamper Protection at runtime, use the transient `HKLM\SOFTWARE\Microsoft\Windows Defender\Threats\ThreatIDDefaultAction` path, or use production `gpupdate /force` as the normal remedy. Use the completed validation record for Security Intelligence reevaluation, WdVerification, and servicing durability evidence before claiming durable suppression.

## Symptom: Stage B Ran but the Final State Is Not Correct

Use this section when Stage B appears to have run, but the resulting machine state does not match the expected final state.

Start with the current-run evidence. Use the most recent `%ProgramData%\l2c_master_<timestamp>.log`, when present, as the primary Stage A/Stage B and teardown record, but treat it as authoritative only for entries it actually contains; its existence does not guarantee both per-secret cleanup-state records. Always inspect `%WINDIR%\Panther\SetupComplete.log` for reboot-finalization diagnostics; obtain or inspect the Stage B process result separately when available. The runtime does not guarantee that this process result is persisted in either log. An exception before secret-cleanup evidence was established, or a master-log persistence/finalization failure, can leave the master log absent or incomplete. If the master log is absent or lacks either cleanup-state record, use `SetupComplete.log` to determine how far continuation progressed and verify actual presence or absence of `%WINDIR%\Setup\Scripts\.bootstrap.pw` and `%WINDIR%\Setup\Scripts\.primaryadmin.pw`.

Check:

- the final `OUTCOME:` line, if a Stage B master log exists, including whether it ends in `SUCCESS`, `FAIL`, or `ABORTED`;
- the Stage A result, including normal no-change outcomes when the account was already in the required local group;
- the Stage B result, including failed or aborted finalization;
- whether logon-policy restore or Winlogon cleanup verification failed, and whether teardown was blocked as a result;
- any per-secret cleanup-state records actually present in the master log, and whether either record is missing;
- actual presence or absence of `%WINDIR%\Setup\Scripts\.bootstrap.pw` and `%WINDIR%\Setup\Scripts\.primaryadmin.pw`, especially when cleanup-state evidence is absent or incomplete;
- whether reboot handling completed or was suppressed;
- whether the process returned reboot-finalization RC 8, unless an earlier nonzero result took precedence.

Focus on the meaning of the evidence rather than on any single line in isolation:

- `OUTCOME: SUCCESS` together with successfully persisted cleanup-state records for both secrets and restoration supports provisioning and teardown success, but does not by itself prove that automatic shutdown scheduling was accepted; if either cleanup-state record is missing, the state remains unproven and the actual file state must be verified; check `SetupComplete.log` and, when available, the separate process result;
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

Use current-run evidence to interpret per-secret cleanup state. When Stage B reaches secret cleanup and successfully persists the relevant evidence, it records one resolved state for each secret. The master log is authoritative only for cleanup-state records it actually contains. An earlier Stage B exception or a master-log persistence/finalization failure can make the master log absent, incomplete, or present without one or both records. Do not infer `skipped` or any other state from an absent record. When cleanup evidence is absent or incomplete, use `%WINDIR%\Panther\SetupComplete.log` to determine how far continuation progressed and verify actual presence or absence of `%WINDIR%\Setup\Scripts\.bootstrap.pw` and `%WINDIR%\Setup\Scripts\.primaryadmin.pw`.

Recorded states that may be compatible with normal completion for a given artifact:

- `removed`, the file was present and deleted successfully;
- `missing`, the file was not present when cleanup was attempted.

Recorded states that indicate retained recovery state or incomplete finalization:

- `error`, deletion failed and the file may still remain on disk;
- `preserved`, the file was intentionally retained for recovery or retry;
- `skipped`, cleanup was not attempted in the current path.

Do not treat `error`, `preserved`, or `skipped` as clean finalization until the retained state is understood in the context of the rest of the evidence.

## Reboot Flag and Suppressed Reboot Cases

Use this section when a reboot did not happen as expected, when reboot handling appears incomplete, or when `%WINDIR%\Panther\_needs_reboot.flag` remains after a degraded run.

The reboot flag preserves a pending reboot requirement across continuation steps. It is not, by itself, proof that the run finished successfully.

Use `%WINDIR%\Panther\SetupComplete.log` and the Stage B master log, if it exists, to determine which case occurred:

- a valid marker was deleted, its absence was positively verified, and marker consumption therefore succeeded before the single shutdown request; when that request returns zero, the controlled reboot request was accepted;
- the flag was cleared and its absence was verified as stale because no pending reboot indicators remained;
- a `force-reboot` marker, or a `need-reboot` marker with pending state `true` or `unknown`, was consumed conservatively before one shutdown request;
- shutdown scheduling failed after marker consumption, the original valid marker was restored and verified, and no automatic retry was issued;
- shutdown scheduling failed and restoration could not be verified; inspect the actual Panther marker state before taking recovery action;
- the flag remained because Stage B failed, recovery mode was entered, or automatic reboot was suppressed;
- continuation could not proceed because no executor task was available, or because no autologon path was available and Stage B would not run until manual logon.

Reboot-finalization RC 8 means the marker probe/classification, marker consumption, shutdown request, or restoration could not complete successfully, unless an earlier nonzero result owns the process result. Successful teardown is not rolled back, and Stage B does not issue a second shutdown request.

If the flag remains after a degraded or failed run, treat it as a sign of retained recovery state or incomplete continuation, not as proof of successful completion.

## When To Return to Other Docs

Use these documents when the question moves beyond troubleshooting itself:

- [Operations](OPERATIONS.md), for routine handling, post-run verification, and operator hygiene;
- [Pipeline Flow](PIPELINE_FLOW.md), to understand where the happy-path sequence should have continued;
- [Security](../SECURITY.md), for secret exposure windows, temporary clear-text storage, and security posture;
- [Decisions](../DECISIONS.md), for design rationale and non-goals.
