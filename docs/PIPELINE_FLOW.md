# Pipeline Flow

## Purpose

This document describes the runtime flow of the baseline from Windows Setup entry through finalization.

It shows which component receives control at each step, what each stage does, and which conditions determine continuation, completion, or retained recovery state.

## Preconditions and Inputs

The baseline assumes prepared Windows installation media and uses `Autounattend.xml` in the media root as its canonical answer file.

Runtime scripts are staged under `%WINDIR%\Setup\Scripts`.

`%WINDIR%\Setup\Scripts\.primaryadmin.pw` is a required external input and must be present before the finalization path can succeed.

`%WINDIR%\Setup\Scripts\.bootstrap.pw` is not an external input. It is generated during the flow by `BootstrapLocalAdmin.ps1`.

## Flow Overview

### Step 1. Setup Entry and Unattended Handoff

**Entry**
Windows Setup starts from prepared media and loads `Autounattend.xml`.

**What happens here**

* applies the core unattended setup settings;
* selects the target image;
* keeps the unattended layer intentionally narrow;
* does not create user accounts;
* does not configure autologon;
* does not define `FirstLogonCommands`;
* shapes OOBE toward a local-account-oriented path;
* launches `%WINDIR%\Setup\Scripts\PreOOBE.cmd` during `specialize`.

**Normal exit**
Control passes to `PreOOBE.cmd`.

**Flow meaning**
The answer file starts the baseline, but it does not try to contain the full implementation. It hands the real runtime flow to the scripted pipeline early.

---

### Step 2. Pre-OOBE Preparation

**Entry**
`PreOOBE.cmd` starts during `specialize`.

**What happens here**

* opens `%WINDIR%\Panther\PreOOBE.log`;
* applies early privacy-related policy settings;
* applies early account-related policy settings;
* suppresses part of the OOBE-era noise before later stages begin;
* launches `BootstrapLocalAdmin.ps1`.

**Normal exit**
Control passes to `BootstrapLocalAdmin.ps1`, then returns to the normal setup path.

**Important alternate exit**

* if bootstrap preparation fails, `PreOOBE.cmd` records failure and returns a failing outcome;
* if bootstrap cleanup hits a non-blocking anomaly, `%WINDIR%\Panther\preoobe_warnings.flag` can be left for later visibility.

**Flow meaning**
This is a preparation phase, not the full baseline workload. It shapes the pre-OOBE environment and hands the flow to the temporary bootstrap-account step.

---

### Step 3. Bootstrap Account Provisioning

**Entry**
`BootstrapLocalAdmin.ps1` is launched from `PreOOBE.cmd`.

**What happens here**

* generates a random password for the temporary `bootstrap` account;
* creates or updates the local `bootstrap` user;
* enables the account;
* ensures membership in the local Administrators group;
* creates `%WINDIR%\Setup\Scripts\.bootstrap.pw`;
* writes that file with a protected ACL boundary;
* verifies the secret boundary immediately after creation;
* marks the secret file as hidden and system-protected.

**Normal exit**
The setup path continues with a valid temporary administrator and a protected bootstrap secret available for the later handoff.

**Important alternate exit**

* if secret creation or verification fails, the step fails;
* if cleanup after an earlier bootstrap error also fails, a non-blocking warning marker can remain for later inspection.

**Flow meaning**
This step does not establish the permanent admin state. It creates a temporary controlled bridge that later allows post-install finalization to proceed.

---

### Step 4. Post-Install Orchestration

**Entry**
After the early setup path completes, control reaches `SetupComplete.cmd`.

**What happens here**

* opens `%WINDIR%\Panther\SetupComplete.log`;
* applies the supported LTSC platform gate;
* stops early if the platform contract is not met;
* runs the main servicing and hardening workload;
* applies the majority of the post-install baseline configuration;
* tracks fatal failures, hardening warnings, and degraded continuation conditions.

**Normal exit**
If the platform gate and post-install flow remain valid, the pipeline moves to secret validation and finalization preparation.

**Important alternate exit**

* unsupported platform conditions stop the flow in a fail state;
* fatal servicing failures stop the flow in a fail state;
* non-fatal issues can still allow continuation with warnings or a degraded later handoff.

**Flow meaning**
This is the main control layer of the baseline. It does the heavy post-install work and decides whether the system is ready for the first-logon finalization path.

---

### Step 5. Secret Gate and Finalization Preparation

**Entry**
`SetupComplete.cmd` reaches the handoff point between post-install orchestration and the later finalization path.

**What happens here**

* validates `%WINDIR%\Setup\Scripts\.bootstrap.pw` and `%WINDIR%\Setup\Scripts\.primaryadmin.pw` through `ValidateSecrets.ps1`;
* requires both secrets to remain inside the expected protected boundary;
* reads secret content only after the boundary checks pass;
* requires the bootstrap secret to be present, non-empty, and format-valid;
* requires the primary admin secret to be present, non-empty, and format-valid;
* applies temporary logon-related settings only after the gate opens;
* verifies the ACL boundary for `%WINDIR%\Setup\Scripts` and `CreatePrimaryAdmin.ps1`;
* hardens the `%SystemRoot%\System32\Tasks\L2C` task container;
* registers `\L2C\CreatePrimaryAdmin` as the finalization task;
* verifies the task boundary after registration;
* primes temporary Winlogon autologon for `bootstrap` only after the earlier checks succeed.

**Normal exit**
The first-logon continuation is armed and the flow is ready to transition into the scheduled finalization path.

**Important alternate exit**

* if either secret is missing, invalid, unreadable, or outside the expected boundary, the gate closes and the first-logon finalization path is not armed;
* if task registration or task-boundary validation fails, the automatic continuation is not armed normally;
* if autologon priming cannot be completed cleanly after task registration, the flow does not claim that the unattended handoff is intact; it either preserves a degraded manual-login continuation when the executor remains available or blocks continuation after rollback.

**Flow meaning**
This is the key security-sensitive transition in the whole pipeline. The flow is not considered armed just because setup completed. It is armed only when secret validation, boundary validation, task registration, and autologon priming succeed in sequence.

---

### Step 6. First Logon Handoff

**Entry**
The flow reaches the first interactive logon boundary.

**What happens here**

* the temporary `bootstrap` account reaches the logon boundary;
* if the continuation was armed successfully, the scheduled task `\L2C\CreatePrimaryAdmin` is triggered;
* `CreatePrimaryAdmin.ps1` starts under `SYSTEM`;
* control moves from setup-driven orchestration into final account completion.

**Normal exit**
The flow enters `CreatePrimaryAdmin.ps1` for permanent admin finalization.

**Important alternate exit**

* if automatic continuation could not be armed cleanly, the same boundary may be reached later through a controlled manual-login path rather than a normal unattended handoff.

**Flow meaning**
This is the real handoff between setup orchestration and final system completion. `SetupComplete.cmd` prepares or degrades this transition, but it does not complete the final local state by itself.

---

### Step 7. Permanent Admin Finalization

**Entry**
`CreatePrimaryAdmin.ps1` starts through the first-logon scheduled-task handoff.

**What happens here**

* reads `%WINDIR%\Setup\Scripts\.primaryadmin.pw` under `SYSTEM`;
* validates the permanent admin secret;
* performs **Stage A**, which creates or updates `primaryadmin`;
* enables the permanent local administrator;
* ensures required local group membership;
* if Stage A created a new account and then failed, attempts rollback of that newly created account;
* performs **Stage B**, which removes temporary autologon state;
* restores temporary logon policy changes;
* verifies that cleanup and restoration actually succeeded;
* if teardown is safe, disables `bootstrap`, removes the scheduled task, and removes both secret files;
* writes the final master outcome log.

**Normal exit**
The temporary execution bridge is removed and the machine reaches its intended finalized local-admin state.

**Important alternate exit**

* if Stage A fails, Stage B enters a recovery-oriented path instead of normal teardown;
* if Winlogon cleanup or logon-policy restoration cannot be verified, transient artifacts are intentionally retained;
* if secret cleanup fails, the final outcome is not treated as a clean success.

**Flow meaning**
This is the point where the pipeline either becomes a finalized local baseline or deliberately remains in a recovery posture. The project does not silently claim a clean end state when final cleanup could not be verified.

---

### Step 8. Controlled Completion and Reboot Decision

**Entry**
`CreatePrimaryAdmin.ps1` reaches the end of finalization and evaluates whether the flow can complete cleanly.

**What happens here**

* checks `%WINDIR%\Panther\_needs_reboot.flag`;
* treats reboot as a post-finalization concern, not an early shortcut;
* suppresses automatic reboot if finalization did not complete successfully;
* suppresses automatic reboot in retained recovery posture;
* if finalization succeeded, evaluates the reboot signal and handles reboot conservatively.

**Normal exit**
The machine ends either in a stable post-finalization state or in a controlled reboot transition that follows successful finalization.

**Important alternate exit**

* if finalization did not succeed, reboot is intentionally suppressed so the retained state can be inspected and recovered;
* if the reboot flag is stale, the flow clears it without rebooting;
* if reboot state is uncertain, the project prefers a conservative completion path.

**Flow meaning**
Reboot is part of controlled completion, not a substitute for successful cleanup, policy restoration, or permanent admin finalization.

---

### End State Summary

In the normal successful path:

* `primaryadmin` exists in its intended configured state;
* the temporary `bootstrap` bridge is no longer active;
* the scheduled finalization task has been removed;
* `%WINDIR%\Setup\Scripts\.bootstrap.pw` has been removed;
* `%WINDIR%\Setup\Scripts\.primaryadmin.pw` has been removed;
* temporary Winlogon and logon-policy changes have been restored;
* the machine is left either stable or in a controlled post-finalization reboot transition.

If the flow cannot safely reach that state, the project prefers a visible degraded or recovery posture over a falsely clean success.

## Narrative Walkthrough

The compact flow map above shows how control moves through the baseline. The sections below explain the runtime boundaries that matter most for understanding why the flow is structured this way and what must be true for the machine to reach its intended finalized state.

This narrative is intentionally narrower than an operations guide or troubleshooting reference. It explains the execution model and completion semantics without turning this document into a recovery manual or a line-by-line implementation commentary.


### Runtime Boundaries and Handoffs

The baseline is intentionally split across multiple runtime boundaries rather than being implemented as a single monolithic setup action. `Autounattend.xml` provides the narrow unattended entry point and hands execution into the scripted pipeline at the appropriate time.

`PreOOBE.cmd` shapes the environment before OOBE fully completes and prepares the temporary bootstrap bridge that later stages depend on. `SetupComplete.cmd` then takes over as the main post-install control layer and prepares the transition into first-logon finalization.

The permanent local-admin end state is reached, or intentionally not claimed, only after control crosses into `CreatePrimaryAdmin.ps1`.

### Required Inputs and Generated Runtime Artifacts

The runtime path depends on a small set of inputs and transient artifacts that do not all play the same role. `%WINDIR%\Setup\Scripts\.primaryadmin.pw` is a required external input. The finalization path cannot succeed unless that secret is present, readable under the expected boundary, and acceptable to the validation logic.

By contrast, `%WINDIR%\Setup\Scripts\.bootstrap.pw` is generated inside the flow by `BootstrapLocalAdmin.ps1`. It exists only to support the temporary bootstrap bridge between early setup and later finalization. In the normal successful path, it is not part of the desired end state and should be removed during cleanup.

Other runtime artifacts are created to support controlled continuation, validation, or completion signaling. These include the `\L2C\CreatePrimaryAdmin` scheduled task, the reboot signal at `%WINDIR%\Panther\_needs_reboot.flag`, warning markers such as `%WINDIR%\Panther\preoobe_warnings.flag`, and the final master outcome log. Some of these artifacts are expected to disappear in a clean success path, while others may be retained deliberately when the project chooses recoverability and transparency over a falsely clean completion claim.


### SetupComplete as Orchestration, not Finalization

`SetupComplete.cmd` is the main post-install orchestration layer of the baseline, but it is not the same thing as final system completion. Its role is to apply the supported-platform gate, run the main servicing and hardening workload, validate secrets and execution boundaries, and decide whether the first-logon continuation can be armed normally, degraded into a manual-login path, or blocked before the handoff can be trusted.

This distinction matters because a successful end of `SetupComplete.cmd` does not by itself mean that the permanent local-admin end state already exists. At that point, the system may be prepared for finalization, may require a degraded continuation path, or may remain in recovery posture. The true finalized state depends on what happens later in `CreatePrimaryAdmin.ps1`, not merely on whether setup reached the end of its post-install control layer.

Treating `SetupComplete.cmd` as orchestration rather than full finalization makes the overall model easier to reason about. It separates heavy post-install configuration from the later account-completion and teardown logic, and it keeps the handoff boundary visible instead of hiding it behind an overly broad definition of setup success.

### Security-Sensitive Transition to First Logon

The transition from post-install orchestration to first-logon finalization is one of the most security-sensitive points in the entire baseline. The flow is not considered safely armed just because setup completed and the machine can proceed. It is considered armed only after the expected secret validation, ACL-boundary checks, task registration, post-registration verification, and temporary autologon preparation all succeed in sequence.

This sequence exists to ensure that the automatic continuation path is not trusted prematurely. The bootstrap secret, the permanent-admin secret, the scripts boundary, and the task executor boundary must all remain inside the expected protected surface before the project allows the system to rely on unattended first-logon continuation.

If that sequence cannot be completed cleanly, the project does not pretend that the normal automatic handoff is intact. Instead, it allows the continuation semantics to narrow, degrade, or stop, depending on which condition failed and whether the remaining state can still be trusted for controlled recovery.

### Finalization Semantics

The finalization path in `CreatePrimaryAdmin.ps1` is more than a simple “last step” in the sequence. It is the point where the baseline either reaches its intended steady state or deliberately refuses to claim that it did. Stage A establishes or updates the permanent local administrator state. Stage B then determines whether temporary execution state, temporary logon settings, the scheduled task, and secret artifacts can actually be removed and verified safely.

That means cleanup is not just cosmetic tidying after the important work is done. Cleanup verification is part of completion semantics. A machine is not in the same state when it merely attempted teardown and when it proved that teardown and restoration succeeded. This is why the flow distinguishes between normal completion and retained recovery posture rather than flattening both outcomes into the same notion of success.

The rollback behavior around Stage A also matters. If the flow creates a new permanent account and then fails before that state is safe to keep, the project attempts to avoid leaving behind a partially established final identity. That behavior supports the broader goal of keeping the end state legible and recoverable rather than silently accumulating ambiguous residue.

### Controlled Completion and Recovery Posture

The baseline treats reboot as part of controlled completion, not as an early shortcut and not as a substitute for verified finalization. `%WINDIR%\Panther\_needs_reboot.flag` is evaluated only after the main finalization logic has already determined whether the machine reached a trustworthy post-finalization state.

If finalization did not complete successfully, the project suppresses automatic reboot rather than using restart behavior to blur unresolved teardown or policy-restoration problems. The same conservative principle applies when transient artifacts must be retained for recovery. A retained task, retained secret, retained bootstrap bridge, or retained policy state is not treated as an implementation embarrassment to be hidden. It is treated as a visible indicator that the machine should not be described as cleanly finalized yet.

This completion model is deliberate. The project prefers a visible degraded or retained recovery posture over a falsely clean success claim, because recoverability depends on preserving evidence and preserving control when cleanup could not be verified.

## Scope Boundary

This document describes the runtime sequence, handoff boundaries, and completion semantics of the baseline flow. It is meant to explain how control moves and what conditions define a trustworthy finalized state, not to provide operator procedures or failure-by-failure recovery instructions.

Setup preparation and first-run instructions belong in `docs/QUICK_START.md`. Operator-facing procedures and routine handling belong in `docs/OPERATIONS.md`. Failure analysis and recovery guidance belong in `docs/TROUBLESHOOTING.md`. Deeper structural reasoning and implementation invariants belong in `docs/ARCHITECTURE.md`. Design rationale and ADR history belong in `DECISIONS.md`.