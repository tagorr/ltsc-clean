# Validation

## Purpose and Use

Use this document to validate behavior-affecting changes before opening a PR. It applies when a change can affect runtime behavior, installation flow, continuation, recovery behavior, reboot handling, secret handling, or final machine state. It does not cover first-run setup, routine operations, or failure diagnosis.

## What Validation Must Prove

Validation should show that the change behaves as intended without silently weakening the baseline's control flow or recovery posture.

At minimum, validation should establish that:

- the intended path still behaves as expected;
- fail-closed behavior still holds where applicable;
- the current-run evidence matches the observed machine state;
- the change did not introduce drift in completion, cleanup, continuation, reboot, or retained-state semantics relevant to the edited area.

## Validation Levels

Choose the lightest validation level that still proves the behavior you changed.

### Minimal validation

Use this for changes that do not affect runtime behavior, such as:

- documentation-only changes;
- comments-only changes;
- wording or naming cleanup with no behavioral effect;
- non-functional repository maintenance that does not change execution semantics.

Expected result:

- the repository still passes the required preflight and CI expectations for the scope of the change;
- any referenced paths or documentation links remain correct.

### Targeted runtime validation

Use this for localized behavior changes where one bounded runtime path is affected.

Examples:

- a narrow change in logging that also affects control-flow visibility;
- a local change in setup scripting logic;
- a change that affects one specific continuation, cleanup, or validation path.

Expected result:

- the changed path is exercised in a clean VM or equivalent isolated environment;
- the relevant logs and observed machine state confirm the intended behavior.

### Extended validation

Use this for changes that can affect safety boundaries, continuation semantics, or finalization behavior.

Examples:

- secret validation or secret cleanup;
- SetupComplete continuation logic;
- scheduled task registration or retention;
- Winlogon priming, restore, or cleanup;
- reboot handling or reboot suppression;
- recovery transitions or retained recovery state;
- Stage A / Stage B completion semantics;
- final machine state guarantees.

Expected result:

- run the happy path;
- run at least one relevant blocked, degraded, or recovery-oriented scenario for the changed area;
- confirm that both the intended path and the relevant fail-closed behavior still work.

## Validation Environment Expectations

Validate behavior-affecting changes in a clean VM or equivalent isolated test environment.

For runtime smoke validation, prefer a clean VM or a known-good snapshot. Use an environment that matches the supported target closely enough to make the result meaningful. Prefer a fresh machine state unless the scenario explicitly tests rerun behavior, retained state, or repeat execution.

During validation:

- keep the scenario narrow and intentional;
- avoid mixing unrelated experiments in the same run;
- preserve enough evidence to support the PR claim;
- compare the logs with the actual machine state before treating a run as passed.

## Required Runtime Evidence

For behavior-affecting changes, review the runtime evidence that corresponds to the path you exercised.

Core evidence anchors:

- `%WINDIR%\Panther\PreOOBE.log`
- `%WINDIR%\Panther\SetupComplete.log`
- `%ProgramData%\l2c_master_<timestamp>.log`, when Stage B or continuation ran
- the observed machine state after the run

For Defender privacy-profile validation, also preserve the relevant Microsoft Defender Operational event evidence when it is used to explain a state transition. Event evidence supports what changed, but must not be used to invent an unproven cause.

Use the logs to confirm what the pipeline says happened. Use the machine state to confirm that the observed result matches that evidence.

As a practical minimum:

- use `PreOOBE.log` for early bootstrap or setup-preparation questions;
- use `SetupComplete.log` for secret-gate, continuation, recovery, and reboot-path questions;
- use the Stage B master log when continuation ran far enough to produce it;
- verify that retained artifacts, secret cleanup state, scheduled-task state, account state, and reboot state match the expected outcome for the scenario you tested.

## Core Validation Scenarios

Select scenarios based on the type of change. Do not treat every PR as requiring the same runtime depth.

### Happy-path smoke

Use this when the changed area can affect normal completion.

Run the scenario on a fresh VM or known-good snapshot and confirm that:

- the expected path completes cleanly;
- the relevant logs are present and consistent with normal completion;
- when Stage B runs, its final outcome is explicitly successful;
- temporary continuation state is cleaned up on the normal success path;
- retained recovery artifacts do not remain unexpectedly after success;
- the resulting machine state matches the expected normal end state for the path you exercised.

### Recovery or fail-closed smoke

Use this when the changed area can affect gating, validation, cleanup verification, retained-state behavior, or recovery transitions.

Run one deliberate invalid-input, blocked, or gate-closed scenario relevant to the edited area and confirm that:

- unsafe or invalid input does not silently produce normal continuation;
- the blocked or degraded path is explicit in the logs;
- normal continuation state is not armed when the gate should remain closed;
- retained state, if present, is deliberate, legible, and suitable for operator investigation;
- the machine is not misread as finalized when it is not.

### Reboot-handling validation

Use this when the changed area can affect pending reboot semantics, reboot suppression, flag consumption, or continuation across reboot boundaries.

Confirm that:

- reboot-required state is handled as intended for the exercised path;
- any retained reboot flag or suppressed reboot state matches the log evidence;
- the final machine state is consistent with the scenario outcome.

### Rerun or repeat-execution validation

Use this when the changed area can affect idempotency, repeat execution, or handling of already-present state.

Confirm that:

- the changed logic behaves safely when the relevant state already exists;
- normal no-change outcomes are still treated as success where appropriate;
- rerun behavior does not produce misleading completion or cleanup semantics.

### Defender privacy-profile validation

Use this scenario when changing the Defender privacy component, its SetupComplete integration, or its documented contract.

Static validation must confirm that the repository preflight includes and passes the Windows PowerShell 5.1 parse check for `ConfigureDefenderPrivacy.ps1`.

On a clean supported deployment, confirm that:

- `ConfigureDefenderPrivacy.ps1` applies and verifies policy `SpynetReporting=0` and `SubmitSamplesConsent=2`;
- the policy registry result is reported separately from effective `IsTamperProtected`, `MAPSReporting`, and `SubmitSamplesConsent` state;
- an effective `MAPSReporting` or `SubmitSamplesConsent` mismatch produces exit `2` and a non-fatal SetupComplete hardening warning; `IsTamperProtected` is observed only and either value is acceptable;
- a technical nonzero result or missing component is also non-fatal to trusted continuation;
- the Defender warning alone does not block secret validation, primary-admin provisioning, Stage A, Stage B, cleanup, continuation, or reboot;
- final Defender state is checked after the normal provisioning reboot;
- Microsoft Defender Antivirus, real-time protection, behavior monitoring, IOAV protection, and PUA protection remain enabled;
- the retained script can be rerun safely from an elevated Windows PowerShell session;
- repeated execution remains safe, and the verified policy/effective state survives `gpupdate /target:computer /force` and a later normal reboot without requiring another script execution.

Completed clean-deployment validation established the following significant empirical behavior:

- during SetupComplete, both owned policy values verified successfully, effective MAPS/sample state was already `0` / `2`, and `IsTamperProtected` was True;
- the prior component run produced the posture-warning outcome, and SetupComplete recorded one Defender privacy hardening warning, finished `SUCCESS_WITH_HARDENING_WARNINGS`, and returned `0`; that outcome reflected the superseded Tamper Protection gate, not the current contract;
- Stage A, Stage B, cleanup, continuation, and the required reboot still completed successfully;
- without operator Tamper Protection action or a manual component rerun, Microsoft Defender Operational Event ID 5007 later recorded `HKLM\SOFTWARE\Microsoft\Windows Defender\Features\TamperProtection` changing from `0x1` to `0x0` during provisioning/reboot;
- after reboot, the observed `IsTamperProtected` state was `False`, effective MAPS/sample state was `0` / `2`, both owned policy values remained `0` / `2`, local Defender protections remained enabled, and the component remained installed;
- a subsequent elevated manual execution returned PASS for policy verification, PASS for effective-state verification, and exit `0`;
- the verified state survived a forced computer-policy refresh and another normal reboot.

This evidence documents an automatic Tamper Protection transition observed in the tested clean deployment. It does not establish the internal cause, guarantee that the transition will recur, or make the observed `False` state a requirement. Under the current contract, Tamper Protection remains diagnostic only; effective privacy success depends on the MAPS/sample values, and only their mismatch produces the posture warning.

## Scenario Selection by Change Type

Use this section to choose the minimum meaningful validation scope.

- docs-only or comments-only change:
  - minimal validation only.

- repository maintenance with no runtime effect:
  - minimal validation only.

- change to setup scripting that affects one bounded path:
  - targeted runtime validation.

- change to the Defender privacy profile or its SetupComplete integration:
  - targeted runtime validation covering the component's policy/effective-state distinction, non-fatal warning path, final post-reboot state, and retained-script rerun.

- change to SetupComplete flow, continuation logic, or scheduled-task behavior:
  - happy-path smoke plus one deliberate blocked or degraded scenario relevant to that boundary.

- change to secret validation, secret cleanup, or secret-related gating:
  - happy-path smoke plus one deliberate fail-closed or recovery-oriented scenario.

- change to Winlogon priming, restore, cleanup, or manual-login continuation behavior:
  - happy-path smoke plus the relevant degraded-path validation.

- change to reboot handling, reboot suppression, or retained reboot state:
  - happy-path smoke plus reboot-handling validation.

- change to Stage A, Stage B, finalization, or final machine state guarantees:
  - happy-path smoke and any additional scenario needed to prove that failure or retained-state behavior still remains safe and legible.

When in doubt, choose the narrower scenario set that still proves both the intended behavior and the relevant safety boundary.

## What to Record in the PR

When a change affects runtime behavior, include a short validation note in the PR.

That note should make it easy for a reviewer to understand:

- what scenario or scenarios were run;
- what environment was used;
- what outcome was expected;
- what outcome was observed;
- which evidence anchors support that conclusion.

Relevant evidence excerpts are usually enough. Full logs are not required unless the change or failure mode makes them necessary.

## When Validation Becomes Troubleshooting

If a validation run does not produce the expected result, do not treat the scenario as passed and do not improvise a new completion claim around partial evidence.

At that point:

- switch to `docs/TROUBLESHOOTING.md` for diagnosis;
- use `docs/OPERATIONS.md` if retained state or manual recovery boundaries must be handled carefully;
- return to `docs/AUDIT_CHECKLIST.md` only when the goal is a broader repository audit rather than validation of one specific change.

Validation is complete only when the exercised scenario, the current-run evidence, and the observed machine state all agree.