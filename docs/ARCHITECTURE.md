# Architecture

## Purpose and scope

This document presents the baseline as a staged setup system.

It explains where the major architectural boundaries lie, how control passes between stages, what conditions gate trusted continuation, and what distinguishes preparation, orchestration, finalization, and verified completion.

It makes the system readable as a whole: its components, state transitions, runtime artifacts, trust boundaries, and invariants.

## System overview

This repository implements a controlled Windows 11 Enterprise LTSC 2024 baseline through a staged setup pipeline.

The system begins with a deliberately narrow unattended entry and then moves through early preparation, post-install orchestration, and first-logon finalization.

The answer file starts the pipeline, but it does not contain the implementation model. That model is defined by the scripted stages, their boundaries, and the control logic that governs how the system moves between them.

The baseline is therefore best understood as a staged system rather than as a single installer or a flat sequence of setup scripts.

## Key terms and state language

**Orchestration**  
The phase that prepares the system, applies baseline changes, validates boundaries, and determines whether trusted continuation can be armed. In this project, `SetupComplete.cmd` owns orchestration.

**Continuation**  
The ability of the system to move from setup-time work into the finalization path.

**Trusted continuation**  
A continuation path armed only after the required validation and handoff conditions succeed in sequence.

**Degraded continuation**  
A controlled continuation path in which the finalization executor remains available, but unattended automatic continuation is not trusted and manual login is required.

**Blocked continuation**  
A state in which the pipeline does not trust the handoff enough to arm continuation. The machine must not be interpreted as ready for unattended completion.

**Finalization**  
The phase that establishes permanent local-admin state, restores temporary state where required, and determines whether the machine can be truthfully considered finalized. In this project, `CreatePrimaryAdmin.ps1` owns finalization.

**Verified completion**  
A final state in which the permanent intended state was established, temporary continuation state was restored or removed where appropriate, executor teardown was independently verified (`bootstrap` disabled and `\L2C\CreatePrimaryAdmin` absent), cleanup was performed only when verified safe, and the evidence surfaces support the claim of completion.

**Retained recovery-signaling state**  
A deliberate non-clean state in which selected temporary or control artifacts remain present so the system stays inspectable and recoverable instead of claiming a falsely clean success.

Across the documentation set, the same recovery outcome may be described in different ways. `Recovery posture` is the broad outcome framing, `retained recovery state` is the operational view, and `retained recovery-signaling state` here is the architecture-level view of that same retained condition.

## Major components and execution contexts

### `Autounattend.xml`

`Autounattend.xml` is the narrow setup entry point.

It selects the target image, defines the setup assumptions, biases OOBE toward a local-account-oriented flow, and launches `PreOOBE.cmd` during `specialize`.

It intentionally does not create user accounts, configure autologon, or define `FirstLogonCommands`.

### `PreOOBE.cmd`

`PreOOBE.cmd` is the early-preparation component.

It applies pre-OOBE privacy and account-related policy settings, opens early Panther logging, and launches `BootstrapLocalAdmin.ps1`.

It does not own continuation, scheduled-task preparation, or completion.

### `BootstrapLocalAdmin.ps1`

`BootstrapLocalAdmin.ps1` is the bootstrap-bridge component.

It creates or refreshes the temporary `bootstrap` administrator account, generates `.bootstrap.pw`, and hardens that file at creation time.

Its role is to establish a tightly scoped temporary bridge, not the permanent machine state.

### `SetupComplete.cmd`

`SetupComplete.cmd` is the central orchestration component.

It performs platform compatibility gating, imports the mandatory system-wide Local GPO User Configuration baseline, applies the main baseline configuration, invokes the subordinate Defender privacy component, runs secret validation, checks non-admin tamper boundaries, registers the finalization executor, prepares temporary continuation state when allowed, and decides whether the system should signal a deferred reboot requirement.

Immediately after the platform gate, it executes the operator-supplied Microsoft `LGPO.exe` as `SYSTEM` to import the repository-tracked `UserBaselinePolicies.txt` payload. Successful import is required before the normal workload continues. The resulting persistent Local GPO User Configuration is processed by Windows for user profiles rather than being implemented through direct `HKCU` writes from `SYSTEM`.

It is a critical architectural boundary because it determines whether continuation is armed, degraded, or blocked.

It is not the final completion boundary.

### `ConfigureDefenderPrivacy.ps1`

`ConfigureDefenderPrivacy.ps1` is the machine-level Defender privacy component subordinate to SetupComplete orchestration.

`SetupComplete.cmd` invokes it through the pinned Windows PowerShell 5.1 executable and captures its `[DEFENDER-PRIVACY]` output in `%WINDIR%\Panther\SetupComplete.log`. The same script is intentionally retained under `%WINDIR%\Setup\Scripts` for later execution from an already elevated Windows PowerShell session; this manual reuse is not a separate pipeline stage.

The component is the single implementation owner of machine-policy `SpynetReporting=0` and `SubmitSamplesConsent=2`. It verifies those registry values separately from Defender's effective `IsTamperProtected`, `MAPSReporting`, and `SubmitSamplesConsent` state. It observes but never disables or bypasses Tamper Protection.

Exit `0` means the effective posture was fully verified, exit `2` means policy application and state inspection succeeded but the effective posture could not be guaranteed, and exit `1` means a technical execution or verification failure. `SetupComplete.cmd` converts exit `2`, technical nonzero results, or a missing component into hardening warnings rather than trusted-continuation failures.

The component writes direct machine policy registry values, not Local GPO `Registry.pol`, and remains separate from the `UserBaselinePolicies.txt` Local GPO User Configuration path.

### `ValidateSecrets.ps1`

`ValidateSecrets.ps1` is an enforcement component.

It validates secret ACL and attribute requirements and checks non-admin tamper boundaries for script and task surfaces before and after executor registration.

Its role is broader than helper logic. It formalizes a trust gate that the rest of the pipeline depends on.

### `CreatePrimaryAdmin.ps1`

`CreatePrimaryAdmin.ps1` is the finalization component.

Its Stage A establishes the permanent local administrator state.

Its Stage B restores and verifies the temporary logon state required to establish teardown eligibility, derives whether executor teardown may proceed, attempts executor teardown and independently verifies the final postconditions (`bootstrap` disabled and `\L2C\CreatePrimaryAdmin` absent), performs normal-path secret cleanup only when teardown eligibility and executor verification are both satisfied, emits the master outcome log, and decides whether reboot signaling may be consumed or must remain retained.

This script owns the true end-state boundary of the system.

## Stage boundaries and handoff model

The system moves through a fixed handoff chain:

`Autounattend.xml` -> `PreOOBE.cmd` -> `BootstrapLocalAdmin.ps1` -> `SetupComplete.cmd` -> `CreatePrimaryAdmin.ps1` Stage A -> `CreatePrimaryAdmin.ps1` Stage B

Within the `SetupComplete.cmd` orchestration boundary, control calls `ConfigureDefenderPrivacy.ps1` and then returns to the normal SetupComplete flow. The component is therefore subordinate work inside an existing stage, not an additional handoff stage.

What matters architecturally is not sequence alone, but which component owns the system at each boundary and what may be handed off to the next one.

### Narrow unattended entry

The answer file remains intentionally narrow and hands implementation to the scripted pipeline early.

That boundary keeps the unattended layer simple, reviewable, and aligned with the supported-mechanisms-only posture of the project.

### Early preparation and bootstrap bridge

`PreOOBE.cmd` and `BootstrapLocalAdmin.ps1` prepare early machine state and establish the temporary bootstrap bridge.

This stage does not decide finalization and does not own later continuation or teardown semantics.

### Orchestration boundary

`SetupComplete.cmd` owns orchestration.

It may prepare a continuation path without the machine yet being finalized.

This is the boundary where the system decides whether continuation can be armed at all, and on what terms.

### Finalization boundary

`CreatePrimaryAdmin.ps1` owns finalization.

This is where the permanent admin state is established and where the system determines whether temporary state may be truthfully removed or must be retained for controlled recovery.

Reaching the end of setup is not equivalent to reaching a finalized machine.

## Continuation gates and state transitions

Continuation is gated, not assumed.

The architecture does not treat “next step in sequence” as sufficient proof that control may safely cross a boundary. Trusted continuation must be explicitly armed.

### Compound continuation gate

Trusted continuation depends on a compound chain of conditions, including:

- supported platform compatibility
- successful import of the required system-wide Local GPO User Configuration payload
- required secret presence
- secret ACL and attribute validity
- secret content validity
- non-admin tamper boundary checks on scripts and related surfaces
- successful executor registration
- successful temporary continuation preparation
- successful continuation marker or equivalent state confirmation

Architecturally, what matters is not any single condition in isolation, but the ordered success of the gate as a whole.

The Defender privacy component is intentionally outside this compound gate. Its posture warning, technical nonzero result, or absence may produce a hardening warning, but does not by itself block secret validation, executor registration, autologon preparation, or later finalization.

### Normal continuation

Normal continuation means the finalization executor is registered, the temporary continuation bridge is armed as intended, and the system can proceed into unattended first-logon finalization.

### Degraded continuation

Degraded continuation is a controlled architectural state.

The finalization executor remains available, but the automatic continuation path is no longer trusted. The system therefore requires manual login while preserving enough state for controlled continuation and review.

### Blocked continuation

Blocked continuation means the pipeline does not trust the handoff enough to arm it.

The machine should not be interpreted as ready for unattended completion.

## Trust and privilege boundaries

The architecture uses a layered trust model.

### Operator-supplied versus pipeline-generated secrets

`.primaryadmin.pw` is operator-supplied input.

`.bootstrap.pw` is pipeline-generated transient bridge state.

These are different secret classes and are handled differently by the system.

### Setup-time and SYSTEM execution boundaries

The early pipeline runs within Windows setup-related contexts.

As part of early orchestration, `SetupComplete.cmd` runs the operator-supplied `LGPO.exe` as `SYSTEM`. The operator is responsible for staging that external Microsoft tool, while `UserBaselinePolicies.txt` is tracked by the repository.

The finalization executor runs as `SYSTEM` at highest privilege so that secrets do not need to be carried through task arguments or weaker transport surfaces.

This separation is part of the privilege model.

### Non-admin tamper boundary

Trusted continuation depends in part on whether non-admin principals have unsafe write-like access to the surfaces that matter for handoff, including:

- the scripts directory
- the finalization script
- the task definition
- the task directory

`ValidateSecrets.ps1` proves this boundary with exact SID anchors. Each surface must have owner `SYSTEM (S-1-5-18)` or `BUILTIN\Administrators (S-1-5-32-544)`. An applicable `Allow` ACE with write-like authority is trusted only for `SYSTEM`, `BUILTIN\Administrators`, or the exact `TrustedInstaller` service SID (`S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464`); read-only access from other principals does not by itself violate the boundary. Explicit and inherited applicable ACEs are equivalent, while `InheritOnly` ACEs do not grant authority over the current object. Null or unprovable owner/DACL state fails closed, and SID-native rule enumeration avoids account-name localization as the authority test.

The existing Windows system Scripts tree is validated in place rather than normalized. `SetupComplete.cmd` establishes and explicitly hardens the `Tasks\L2C` task directory before task registration. This is an authority invariant, not exact ACL-template matching or effective-access/token simulation, and the existing per-object result bits remain the handoff protocol. If any boundary is weak or unproven, trusted continuation is not armed.

### Out-of-scope attacker model

This boundary does not claim to resist a local administrator or `SYSTEM` attacker who already controls the machine.

That limitation is explicit and should remain explicit.

### Temporary Winlogon boundary

Temporary autologon-related state is treated as a controlled bridge, not as an ordinary configuration preference.

It is armed only after the continuation gate opens and is removed only when Stage B verifies that restoration is safe and complete.

## Runtime artifacts and lifecycle

The architecture relies on several classes of runtime artifacts.

### External input artifacts

These enter the system from outside the pipeline itself.

- installation media
- `Autounattend.xml`
- staged runtime scripts
- repository-tracked `UserBaselinePolicies.txt`
- operator-supplied `LGPO.exe`
- `.primaryadmin.pw`

Successful import produces persistent system-wide Local GPO User Configuration that Windows processes for user profiles. This policy path does not require direct `HKCU` writes from `SYSTEM`, `gpupdate`, or a first-logon helper.

`ConfigureDefenderPrivacy.ps1` is also staged as a runtime input, but its lifecycle is different from temporary bridge and executor artifacts. It remains installed after normal finalization as a deliberate operational verification/remediation entry point; it is not a secret, a continuation artifact, or retained recovery residue.

### Generated bridge artifacts

These exist to carry the system from one boundary to the next.

- `.bootstrap.pw`
- temporary bootstrap account state
- temporary Winlogon continuation state

### Executor artifacts

These allow the system to cross from orchestration into finalization.

- `\L2C\CreatePrimaryAdmin`

### State markers and control artifacts

These record or carry state across boundaries.

- `HKLM\SOFTWARE\L2C\AutologonPrimed`
- `%WINDIR%\Panther\_needs_reboot.flag`
- warning markers such as `preoobe_warnings.flag`

### Evidence artifacts

These preserve reviewable evidence of what each phase actually did.

- `%WINDIR%\Panther\PreOOBE.log`
- `%WINDIR%\Panther\SetupComplete.log`
- `%WINDIR%\Logs\DISM\SetupComplete-DISM.log`
- `%ProgramData%\l2c_master_<timestamp>.log`

The Defender component's `[DEFENDER-PRIVACY]` policy and effective-state results are captured in `SetupComplete.log`, together with any resulting hardening-warning summary.

### Retained recovery artifacts

Some artifacts may remain intentionally when finalization cannot honestly claim a clean result.
Their presence is part of the recovery-signaling model, not accidental debris.

### Lifecycle principle

An artifact’s presence or absence is architecture-relevant.

Some artifacts disappear on the normal verified path. Some remain as canonical evidence. Some are deliberately retained when the system must remain inspectable or retryable.

## Outcome and completion semantics

This architecture does not use a simple success-versus-failure model.

### Orchestration outcome versus finalization outcome

`SetupComplete.cmd` may complete its orchestration responsibilities without the machine yet being finalized.

Finalization then determines the real end-state of the machine. `CreatePrimaryAdmin.ps1` may:
- finalize successfully
- continue in a degraded but controlled posture
- preserve retained recovery-signaling state
- fail before a truthfully finalized state can be established

These are different architectural outcomes and should remain distinct.

### Verified completion

A machine is not truthfully finalized merely because the last script ran.

A machine is truthfully finalized only when:
- the permanent intended state was established
- temporary continuation state was restored or removed where appropriate
- cleanup was performed only when verified safe
- the evidence surfaces support the claimed outcome

Cleanup is therefore part of completion semantics, not a cosmetic afterthought. Normal success and normal-path secret deletion require verified executor teardown.

The Stage B master-log `OUTCOME: SUCCESS` records successful provisioning and teardown decisions made before reboot finalization; it does not prove that a later automatic shutdown request was accepted.

### Degraded continuation

A degraded path remains a controlled architectural outcome.

It preserves the finalization executor and enough state for manual continuation while avoiding a false claim of trusted unattended completion.

### Retained recovery-signaling state

Retained recovery-signaling state is deliberate.

The project prefers inspectable and retryable retained state over falsely clean success when safe finalization cannot be established.

## Reboot signaling within controlled completion

Reboot is treated as part of controlled completion, not as an inline progress shortcut.

`SetupComplete.cmd` does not perform an immediate reboot.

Instead, it may record deferred reboot requirement through the Panther reboot flag.

That signal is interpreted later by finalization logic.

Stage B is the only place where reboot signaling may be consumed or suppressed as part of the verified completion path. In the current normal baseline, it consumes a valid marker only after deletion and absence verification, then issues one shutdown request. A failed request attempts to restore and verify the original marker; if verification fails, marker state is not proven. It issues no retry and returns RC 8 when no earlier failure code takes precedence; failure and recovery paths suppress automatic reboot.

The distinction between:
- reboot requested
- reboot signaled
- reboot consumed
- reboot suppressed
- reboot flag retained

belongs to the architecture-level state model, not to incidental implementation detail.

## Evidence and observability surfaces

Observability in this system is architectural because state claims depend on reviewable evidence surfaces.

### Phase logs

Each major stage writes to specific evidence locations.

This allows later interpretation of what boundary was crossed, what conditions succeeded, and where the flow stopped or degraded.

### Markers and control state

Markers are not mere leftovers.

They carry state across boundaries and help explain what the system believed about continuation, warning conditions, and deferred reboot requirements.

### Retained artifacts as evidence

A remaining task, a retained secret file, a preserved bridge artifact, or a retained reboot flag can be architecture-level evidence of incomplete, degraded, or intentionally retained state.

### Evidence-first interpretation

Trustworthy interpretation of the machine state comes from reading multiple evidence surfaces together, including:

- current machine state
- logs
- markers
- executor presence or absence
- cleanup states
- retained artifacts

A single isolated signal is not enough to explain the real end state.

## Invariants

These invariants are architecture-level constraints.

### Narrow unattended entry

The answer file remains intentionally narrow.

It must not become the place where full system logic is re-embedded through account creation, autologon, or `FirstLogonCommands`.

### No direct reboot in `SetupComplete.cmd`

`SetupComplete.cmd` must not become a direct reboot owner.

It may signal reboot need, but it must not consume that signal as an immediate shortcut.

### Panther reboot flag as single reboot signal

The Panther reboot flag remains the single deferred reboot signal carried across the orchestration-to-finalization boundary.

### Stage B as reboot consumer

`CreatePrimaryAdmin.ps1` Stage B remains the controlled consumer or suppressor of reboot signaling.

### No secrets on command lines or task arguments

Secrets must not be moved into command-line arguments, task arguments, or intentional logs.

### Gated continuation only

Trusted continuation must be armed only after the full gate chain succeeds in the intended order.

### Verify-driven teardown

Temporary state may be removed only when restoration and cleanup checks verify that it is safe.

### Recovery state is deliberate

Retained recovery-signaling state remains a deliberate architectural outcome, not an accidental side effect.

### Supported mechanisms only

The system remains built on supported Microsoft mechanisms rather than hidden or unsupported shortcuts.

### Idempotence as a system property

Repeatability and controlled re-entry remain architectural properties of the system, not accidental implementation details.