# Decisions

## Purpose and Use

Use this document as the canonical design-rationale reference for the baseline. It explains what the baseline is designed to achieve, which architectural and product decisions shape it, which boundaries it intentionally keeps, and which trade-offs it makes.

It records the key decisions, rationale, and scope boundaries that define the project. It is about design intent and project boundaries, not about step-by-step operation.

## Baseline principles and scope

This project defines a lean, predictable Windows 11 Enterprise LTSC 2024 baseline designed to reduce background activity and telemetry while keeping default workstation behavior quiet, legible, and stable.

The supported target is Windows 11 Enterprise LTSC 2024 (`EditionID=EnterpriseS`, `DisplayVersion=24H2`, minimum build `26100`, with strict display-version enforcement). Closely aligned Enterprise variants are not treated as supported unless they satisfy the exact runtime gate.

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
- `ConfigureDefenderPrivacy.ps1` implements the bounded Defender cloud/privacy profile under SetupComplete orchestration and remains available for later verification
- `CreatePrimaryAdmin.ps1` finalizes the primary admin path and cleanup logic

After OOBE, Windows executes `SetupComplete.cmd` as `SYSTEM`. This staged design keeps the pipeline easier to reason about, easier to recover, and easier to audit.

### `SkipMachineOOBE` is intentionally retained

`Autounattend.xml` intentionally retains `<SkipMachineOOBE>true</SkipMachineOOBE>` for the validated Windows 11 Enterprise LTSC 2024 unattended flow. Microsoft recommends automating OOBE through granular unattend settings instead of using `SkipMachineOOBE`, but a controlled clean-VM test showed that removing only this setting did not preserve the validated behavior.

Without the setting, Windows produced an enabled `defaultuser0` account with a persistent profile, resumed interactive OOBE after the LTSC-clean provisioning pipeline had completed successfully, exposed the network setup page during the intentionally offline deployment, and entered an `OOBELOCAL` retry loop after the offline path was selected. Restoring the setting in a subsequent clean deployment restored the normal unattended end state.

The project therefore retains the setting as a deliberate compatibility requirement for this flow, not as obsolete residue. It is not replaced with a `UserAccounts`-based OOBE account handoff merely to remove the setting, because doing so would move account creation into the answer-file layer and require redesigning the existing generated-secret bootstrap boundary. The current design generates the temporary bootstrap secret on the target machine and keeps the unattended entry intentionally narrow.

Any future removal or replacement of `SkipMachineOOBE` requires clean-VM evidence that the supported offline flow completes without resumed interactive OOBE or unintended accounts and profiles, while preserving the existing account lifecycle and secret-handling model.

### Servicing and policy application run in SetupComplete

Servicing, machine-level policy orchestration, and system-wide Local GPO User Configuration are intentionally handled in `SetupComplete.cmd`.

DISM operations and system-wide policy controls run there, including the main baseline posture for components such as Edge, Delivery Optimization, telemetry reduction, OneDrive, and selected optional features.

For the four repository-owned user settings in `UserBaselinePolicies.txt`, `SetupComplete.cmd` uses the operator-supplied Microsoft `LGPO.exe` tool to import a system-wide Local GPO User Configuration payload as `SYSTEM`. Windows policy processing then applies that Local GPO state to user profiles; `SetupComplete.cmd` does not write those values directly to `HKCU`.

`UserBaselinePolicies.txt` is tracked by this repository. `LGPO.exe` is external operator-managed tooling and is not acquired or lifecycle-managed by the baseline.

This deliberate architecture concentrates baseline servicing and policy orchestration inside one explicit boundary and makes outcomes easier to observe. Bounded components such as `ConfigureDefenderPrivacy.ps1` can own one reusable policy profile without taking over orchestration.

### Compatibility is enforced explicitly

The baseline does not treat broad version similarity as sufficient evidence of compatibility.

It validates the supported platform explicitly against the expected baseline:

- `EditionID=EnterpriseS`
- `DisplayVersion=24H2`
- `CurrentBuild >= 26100`
- `STRICT_DISPLAYVERSION=1`

Edition and build mismatches are treated as unsupported. `DisplayVersion` checking is strict in the current baseline.

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

### Stage B ACL trust uses exact SID anchors

The Stage B handoff surfaces use a trusted-authority model for ACL validation. A known-bad-principal denylist is not a closed-world security boundary: a specific local user, custom group, domain principal, or other resolved SID can receive write authority without matching a short list of broad principals. The validator therefore accepts write-capable `Allow` authority only when the trustee is exactly `SYSTEM (S-1-5-18)`, `BUILTIN\Administrators (S-1-5-32-544)`, or the exact `TrustedInstaller` service SID (`S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464)`. It accepts only `SYSTEM` or `BUILTIN\Administrators` as owners.

This is intentionally an authority proof, not a claim that arbitrary privileged-looking identities are safe. Other service SIDs, local or domain accounts and groups, and unresolved write-capable trustees are not trusted. Read-only access remains allowed when its rights can be shown to be non-write-capable. Applicable explicit and inherited ACEs are treated alike; `InheritOnly` ACEs do not grant authority over the current object. Null or unprovable DACL or owner state fails closed, and SID-native access-rule enumeration keeps the comparison independent of localized account-name resolution.

The four surfaces are `%WINDIR%\Setup\Scripts`, `CreatePrimaryAdmin.ps1`, the `\L2C\CreatePrimaryAdmin` task definition, and the `\L2C` task directory. The existing Windows system Scripts tree is validated in place rather than normalized, while `SetupComplete.cmd` establishes and hardens the L2C task directory before registration. The model deliberately does not require one exact ACL template or run effective-access/token simulation. Stock-shaped ACLs, including the inheritance-only `CREATOR OWNER` entry and the production task file's explicit `SYSTEM:Read` ACE, pass; the repeated ordinary-user `Modify` regression is rejected with pre-check `RC=16`.

## Major product decisions and rationale

### Microsoft Edge

The baseline applies a policy-first posture for Edge. It suppresses first-run UX, prevents broken shortcut artifacts, and suppresses EdgeUpdate services and tasks on a best-effort basis to reduce unwanted Edge reappearance and background activity.

The baseline does not remove WebView2 runtime. This keeps browser suppression separate from removal of shared runtime dependencies and avoids turning a quiet-default decision into component eradication.

### SmartScreen and Windows Defender

SmartScreen policy layers are disabled for Windows Shell and Edge.

Windows Defender retains local endpoint protections, while cloud/MAPS participation and automatic sample submission are disabled by policy. This preserves local protective value while reducing silent outbound reputation and sample flows.

`SetupComplete.cmd` remains the orchestration owner, but `ConfigureDefenderPrivacy.ps1` is the single implementation owner of `SpynetReporting=0` and `SubmitSamplesConsent=2`. Fresh deployments do not explicitly configure `DisableBlockAtFirstSeen`, `LocalSettingOverrideSpynetReporting`, or `MpCloudBlockLevel`: `DisableBlockAtFirstSeen=1` was removed after observed `DefenderTamperingRestore` / Defender auto-heal behavior made explicit enforcement counterproductive, while `LocalSettingOverrideSpynetReporting` and `MpCloudBlockLevel` are not required for the current two-value privacy contract. The component does not add migration or cleanup behavior for systems produced by older baselines.

The component writes the two machine policy registry values directly rather than creating corresponding Local GPO `Registry.pol` state. This keeps the machine-level Defender privacy profile separate from the `UserBaselinePolicies.txt` Local GPO User Configuration path; `gpedit.msc` may therefore show the related Administrative Template settings as Not Configured even when the owned registry values are correct.

Registry verification proves only that the baseline wrote the policy it owns. The component separately queries Defender for `IsTamperProtected`, `MAPSReporting`, and effective `SubmitSamplesConsent`. It never disables or bypasses Tamper Protection. A point-in-time effective mismatch or technical failure is intentionally surfaced as a non-fatal hardening warning rather than closing the trusted-continuation gate.

The same idempotent script is intentionally retained under `%WINDIR%\Setup\Scripts` so an operator can recheck the final state after provisioning and rerun the profile from an elevated Windows PowerShell session if remediation remains necessary. The design does not assume that Tamper Protection will transition automatically after every deployment.

This is a deliberate trade-off, not an omission.

The baseline also uses the supported Windows Security machine policy to suppress the notification-area presentation and removes only the standard `Run\SecurityHealth` tray autorun registration. This is a narrow quieting change: it does not disable Windows Security or Defender services or local protection, and it avoids broader component removal or unsupported blocking techniques.

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

The dedicated SNMP capability targets `SNMP.Client~~~~0.0.1.0` and `WMI-SNMP-Provider.Client~~~~0.0.1.0` intentionally use a different contract from optional Windows features. They are conservative best-effort reductions: removal is attempted only when the captured probe positively identifies `Installed` or `Staged`, while uncertain or unsupported probe state is not by itself sufficient reason to abort the provisioning pipeline. Once a removal mutation is attempted, unexpected DISM mutation failure remains fatal under the normal servicing policy. Post-removal checking is non-gating, so successful completion does not prove that both capabilities are absent. This is a deliberate trade-off for capability availability and state-reporting variability, not accidental implementation drift.

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
- Disable or bypass Microsoft Defender Tamper Protection
- Migrate or clean historical Defender policy values from older LTSC-clean installations
- Write user-scoped configuration under `HKCU` from `SYSTEM` context
- Deny or delete system folders as a feature-blocking technique
- Auto-generate or derive the primary local admin password
- Turn the baseline into a full enterprise hardening stack by default
- Cover domain-based management, MDE onboarding, WDAC, AppLocker, BitLocker enforcement, LAPS, or other enterprise control frameworks out of the box
- Serve as a universal baseline for arbitrary Windows editions or loosely similar builds

These limits are intentional. They keep the baseline narrow in scope, easier to audit, and clear about what it is designed to solve.

## Trade-offs

The baseline adopts a small number of deliberate trade-offs.

SmartScreen policy layers are disabled, and Defender keeps local protections while the baseline targets cloud/MAPS and automatic sample submission off. If Defender's point-in-time effective state cannot be guaranteed, the result remains visible as a non-fatal hardening warning. This reduces some protection surface in exchange for a quieter machine and fewer silent outbound reputation and sample flows.

WPAD is disabled by default. If a machine later enters an environment that requires proxy use, that proxy must be configured explicitly rather than discovered automatically.

The pipeline does not perform aggressive component-store cleanup as part of baseline setup. This keeps first-run automation narrower and more predictable, but leaves some maintenance choices to the operator instead of embedding them into initial setup.

The execution model is intentionally fail-closed and recovery-oriented. As a result, degraded or incomplete runs may intentionally retain state that requires manual review rather than presenting a falsely clean outcome.

These trade-offs are part of the baseline’s intended posture and should be accepted explicitly by anyone choosing to use it.