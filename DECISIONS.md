# Decisions

## Purpose and Use

Use this document as the canonical design-rationale reference for the baseline. It explains what the baseline is designed to achieve, which architectural and product decisions shape it, which boundaries it intentionally keeps, and which trade-offs it makes.

It records the key decisions, rationale, and scope boundaries that define the project. It is about design intent and project boundaries, not about step-by-step operation.

## Baseline principles and scope

This project defines a lean, predictable Windows 10 LTSC 2021 baseline designed to reduce background activity and telemetry while keeping default workstation behavior quiet, legible, and stable.

The supported target is Windows 10 Enterprise LTSC 2021, version 21H2. Closely aligned Enterprise variants are in scope only where the same documented policy assumptions remain valid.

The baseline is intended for standalone or simple-network environments. It is not designed around corporate integration requirements or environments that depend on automatic proxy discovery by default.

The baseline is guided by the following principles:

- Keep the workstation clean, quiet, and predictable.
- Minimize background activity and telemetry.
- Use supported Microsoft mechanisms only.
- Stay conservative and avoid hacks or unsupported tricks.
- Prefer deterministic behavior with legible outcomes.
- Preserve idempotent execution so reruns converge safely without harmful drift.

The project relies on supported Windows control planes such as policy, registry, servicing, and scheduled tasks. It does not try to become a general enterprise management stack, a universal hardening framework, or a broad compatibility layer for unrelated deployment scenarios.

## Core execution and compatibility decisions

### Narrow unattended entry, staged execution

The unattended entry surface is intentionally narrow. The baseline does not try to encode the full machine policy and provisioning model inside the answer file.

Instead, execution is split across bounded stages with distinct responsibilities:

- `PreOOBE.cmd` prepares pre-OOBE state
- `SetupComplete.cmd` applies baseline servicing and system-wide policy as `SYSTEM`
- `CreatePrimaryAdmin.ps1` finalizes the primary admin path and cleanup logic

After OOBE, Windows executes `SetupComplete.cmd` as `SYSTEM`. This staged design keeps the pipeline easier to reason about, easier to recover, and easier to audit.

### Servicing and policy application run in SetupComplete

Servicing and machine-level policy application are intentionally moved into `SetupComplete.cmd`.

DISM operations and system-wide policy controls run there, including the main baseline posture for components such as Edge, Delivery Optimization, telemetry reduction, OneDrive, and selected optional features.

This is a deliberate architectural decision. It concentrates machine-level changes inside one explicit orchestration boundary and makes outcomes easier to observe.

### Compatibility is enforced explicitly

The baseline does not treat broad version similarity as sufficient evidence of compatibility.

It validates the supported platform explicitly against the expected baseline:

- `EditionID=EnterpriseS`
- `DisplayVersion=21H2`
- `CurrentBuild >= 19044`

Edition and build mismatches are treated as unsupported. `DisplayVersion` checking is strict by default, with opt-out allowed only where separately documented.

This compatibility posture is intentional. The baseline prefers a fail-closed outcome over claiming support where policy behavior, telemetry semantics, or servicing assumptions may differ.

### Continuation is gated, not assumed

A successful `SetupComplete.cmd` run is not treated as sufficient evidence that the unattended continuation path remains safe.

Continuation into primary-admin finalization is allowed only after the required validation and setup conditions succeed in sequence, including secret validation, task registration, and the remaining conditions for safe continuation.

If those conditions are not met safely, the normal unattended continuation path is not established.

This protects the boundary between "machine prepared" and "machine safely finalizable."

### Retained recovery state is intentional

If safe finalization cannot be established, the baseline favors deliberately retained, recovery-signaling state over cosmetically clean failure.

Artifacts, handoff state, or recovery entrypoints may be retained as deliberate evidence that finalization did not complete normally.

This is part of the design, not residue. The baseline prefers safe, legible, operator-reviewable failure modes over silent self-cleanup that would blur what actually happened.

### Reboot handling is separated from SetupComplete execution

`SetupComplete.cmd` does not use an immediate reboot as part of its main execution path.

If servicing requires a reboot, that requirement is signaled rather than handled within `SetupComplete.cmd` itself. Reboot handling is treated as a bounded post-servicing concern, not as a mechanism for forcing progression through unfinished state.

This keeps the setup boundary more deterministic and makes intermediate state easier to observe and review.

### Idempotence is a design property

Idempotence is a deliberate execution property of the baseline.

Scripts may be run repeatedly during manual reruns, regressions, or recovery-oriented retries. Operations are designed to remain safe on repeat and to converge toward the intended machine state without harmful drift.

They are also structured so that applicability can be checked before change and outcomes remain distinguishable in logs. Already-satisfied state, no-op transitions, and repeat invocations are expected to remain safe, legible, and reviewable.

### Primary admin provisioning is operator-supplied and secret-safe by design

The baseline never auto-generates or derives the primary local admin password. The operator supplies it explicitly, and the design keeps it off external process command lines and out of task arguments.

The current provisioning decision uses `LocalAccounts` and `SecureString` semantics so password application remains explicit and stays off external command lines. Stage A creates or updates the local user, enables it, and enforces required local group membership through SID-based local group resolution. Failure handling remains fail-closed and observable.

If Stage A created `primaryadmin` during the current run and a later step fails, it attempts best-effort rollback and forces recovery. If the user existed before the current run, it is not deleted on failure.

This preserves a clearer security boundary while keeping retry and recovery behavior explicit.

## Major product decisions and rationale

### Microsoft Edge

The baseline applies a policy-first posture for Edge. It suppresses first-run UX, prevents broken shortcut artifacts, and suppresses EdgeUpdate services and tasks on a best-effort basis to reduce unwanted Edge reappearance and background activity.

The baseline does not remove WebView2 runtime. This keeps browser suppression separate from removal of shared runtime dependencies and avoids turning a quiet-default decision into component eradication.

### SmartScreen and Windows Defender

SmartScreen policy layers are disabled for Windows Shell and Edge.

Windows Defender retains local endpoint protections, while cloud- and reputation-based verdicts and automatic sample submission are disabled by policy. This preserves local protective value while reducing silent outbound reputation and sample flows.

This is a deliberate trade-off, not an omission.

### Telemetry, diagnostics, and Windows Error Reporting

The baseline adopts the lowest supported enterprise telemetry posture, `AllowTelemetry=0`, and suppresses feedback, CEIP, diagnostics, and Windows Error Reporting through supported policy and task controls.

The intended result is a lower-noise enterprise posture that reduces background communication and unsolicited diagnostics traffic without claiming to eliminate every observable signal.

### Delivery Optimization

Delivery Optimization is configured for HTTP-only behavior with no peer-to-peer participation.

This keeps update-related networking more predictable and avoids peer distribution behavior on a quiet baseline. Within LTSC, the baseline uses Mode `0`; more restrictive isolated-network variants are treated as separate scenarios outside its scope.

### Network quieting

The baseline disables WPAD on both WinINET and WinHTTP policy surfaces.

It does not disable `WinHttpAutoProxySvc`. This reduces automatic proxy discovery and related background behavior without overreaching into service disablement that may break Windows Update or other WinHTTP-dependent clients.

This is a quieting decision, not a rejection of proxy-capable environments. Such environments require explicit later configuration.

### OneDrive

The baseline does not forcibly uninstall OneDrive by default. Instead, it prefers policy-based disablement.

This keeps the posture more stable across updates, avoids brittle removal behavior, and suppresses default consumer-facing behavior without treating component removal as the primary goal.

### Features and capabilities

The baseline applies conservative servicing reductions only where the relevant feature is present and enabled.

Legacy surfaces such as SMBv1 and PowerShell 2.0 are disabled only when they are actually enabled. This keeps servicing reductions explicit and bounded, rather than treating absent or already-disabled components as if they still required action.

### Windows Update posture

The baseline uses a restrained Windows Update posture intended to reduce surprise and background churn.

Device metadata retrieval from the Internet is disabled to reduce background network noise. More broadly, the update posture favors a more observable and predictable default state over aggressive automation or built-in update-management logic.

### Component cleanup

The baseline pipeline does not run component store cleanup actions such as `DISM /Online /Cleanup-Image /StartComponentCleanup` or `/ResetBase` as part of the core unattended flow.

These actions are not necessary to define the baseline itself, may interact poorly with early servicing state, and provide little value on a fresh LTSC image without cumulative updates. Aggressive cleanup is therefore treated as a separate, operator-driven maintenance choice rather than part of baseline establishment.

## Explicit non-goals

The baseline does not attempt to do the following:

- Disable `WinHttpAutoProxySvc` as part of WPAD control
- Remove WebView2 as part of Edge suppression
- Write user-scoped configuration under `HKCU` from `SYSTEM` context
- Deny or delete system folders as a feature-blocking technique
- Auto-generate or derive the primary local admin password
- Turn the baseline into a full enterprise hardening stack by default
- Cover domain-based management, MDE onboarding, WDAC, AppLocker, BitLocker enforcement, LAPS, or other enterprise control frameworks out of the box
- Serve as a universal baseline for arbitrary Windows editions or loosely similar builds

These limits are intentional. They keep the baseline narrow in scope, easier to audit, and clear about what it is designed to solve.

## Trade-offs

The baseline adopts a small number of deliberate trade-offs.

SmartScreen policy layers are disabled, and Defender keeps local protections while cloud- and reputation-based verdicts are turned off. This reduces some protection surface in exchange for a quieter machine and fewer silent outbound reputation and sample flows.

WPAD is disabled by default. If a machine later enters an environment that requires proxy use, that proxy must be configured explicitly rather than discovered automatically.

The pipeline does not perform aggressive component-store cleanup as part of baseline setup. This keeps first-run automation narrower and more predictable, but leaves some maintenance choices to the operator instead of embedding them into initial setup.

The execution model is intentionally fail-closed and recovery-oriented. As a result, degraded or incomplete runs may intentionally retain state that requires manual review rather than presenting a falsely clean outcome.

These trade-offs are part of the baseline’s intended posture and should be accepted explicitly by anyone choosing to use it.