# Audit Checklist

Baseline for repository, design, and contract audits.

This checklist is for auditing repository-level invariants, staged execution contracts, ownership boundaries, fail-closed behavior, and contract-bearing documentation claims.

### 1. Repository-wide invariants

* [ ] Critical repository files preserve the encoding, line endings, and file integrity required by the project.
* [ ] No file damage is present that would break parsing, execution, or auditability.
* [ ] PowerShell scripts remain structurally valid for Windows PowerShell 5.1 execution.
* [ ] The repository preflight PowerShell 5.1 parse targets include `ConfigureDefenderPrivacy.ps1`.
* [ ] CMD scripts do not rely on unsafe multi-line parse-time `%VAR%` expansion in control-flow-critical blocks.

### 1.1. Unattended entry contract

* [ ] `Autounattend.xml` selects the intended OS image without requiring edition-picker interaction.
* [ ] `Autounattend.xml` invokes the expected specialize-stage entry into `PreOOBE.cmd`.
* [ ] The unattended entry remains intentionally narrow and does not absorb later-stage logic.

---

### 2. Secret-source and password lifecycle contracts

* [ ] `.bootstrap.pw` is created only by `BootstrapLocalAdmin.ps1` at the expected path under `%WINDIR%\Setup\Scripts`.
* [ ] `.bootstrap.pw` is treated as a single-line secret and is protected by explicit restricted ACLs and hidden/system attributes.
* [ ] `.primaryadmin.pw` is treated as an operator-supplied secret at the expected path under `%WINDIR%\Setup\Scripts`.
* [ ] `ValidateSecrets.ps1` validates secret file ACL/attribute shape without reading password contents and returns an explicit validation result.
* [ ] `SetupComplete.cmd` does not read secret contents before the relevant validation gate succeeds.
* [ ] `SetupComplete.cmd` treats missing, invalid, unreadable, or failed-validation secret inputs as fail-closed conditions.
* [ ] `CreatePrimaryAdmin.ps1` Stage A uses `.primaryadmin.pw` as the only primary-admin password source.
* [ ] No script passes the primary admin password or bootstrap password on process command lines, in task arguments, or into baseline-owned logs.

---

### 3. PreOOBE / bootstrap stage contracts

* [ ] `PreOOBE.cmd` invokes `BootstrapLocalAdmin.ps1` as the specialize-stage bootstrap step.
* [ ] `PreOOBE.cmd` does not take over responsibilities that belong to later stages.
* [ ] `PreOOBE.cmd` routes bootstrap output into `%WINDIR%\Panther\PreOOBE.log`.
* [ ] `BootstrapLocalAdmin.ps1` preserves a defensive PowerShell error-handling posture.
* [ ] `BootstrapLocalAdmin.ps1` creates or refreshes the temporary `bootstrap` account using supported PowerShell local-account mechanisms.
* [ ] `BootstrapLocalAdmin.ps1` writes `.bootstrap.pw` and secures it according to the contract.
* [ ] `BootstrapLocalAdmin.ps1` does not modify Winlogon autologon state, finalization state, or Stage B ownership.

---

### 4. SetupComplete.cmd design contracts

#### 4.1. Structure, failure model, and execution order

* [ ] `SetupComplete.cmd` preserves a deterministic fail-closed control model for servicing, validation, scheduling, and final RC selection.
* [ ] Servicing logic, secret validation, Stage B scheduling, and reboot signaling remain clearly ordered.
* [ ] Platform-gate mismatches fail closed and flow to the shared final return-code path.
* [ ] The mandatory system-wide Local GPO User Configuration gate runs after the platform gate and before the normal baseline workload.
* [ ] `%WINDIR%\Setup\Scripts\LGPO.exe` is treated as a required operator-supplied runtime input, and `%WINDIR%\Setup\Scripts\UserBaselinePolicies.txt` is treated as the required tracked four-entry policy payload.
* [ ] `UserBaselinePolicies.txt` contains exactly the approved `DisableWindowsSpotlightFeatures=1`, `HideSCAMeetNow=1`, `HttpAcceptLanguageOptOut=1`, and `Start_TrackProgs=0` DWORD values under their intended User Configuration registry paths.
* [ ] `SetupComplete.cmd` invokes one `LGPO.exe /t` import for the complete payload.
* [ ] A missing LGPO executable, missing payload, or non-zero import RC fails closed, stops normal baseline processing, and preserves the existing first-fatal-RC and final-RC contract.
* [ ] The Local GPO User Configuration mechanism does not directly write these settings to `HKCU`, run `gpupdate`, or add a first-logon helper.
* [ ] The final RC contract remains deterministic:
  * [ ] fatal servicing failure cannot be masked by later success states;
  * [ ] closed-gate / fail state does not collapse into silent success;
  * [ ] success returns zero.

#### 4.2. Secret gate and Stage B scheduling

* [ ] `.bootstrap.pw` presence and first-line validity are checked before Stage B scheduling or autologon priming.
* [ ] `.primaryadmin.pw` presence, validation state, and first-line validity are checked before Stage B scheduling or autologon priming.
* [ ] `ValidateSecrets.ps1` results are decoded and used as part of the combined gate.
* [ ] Internal validator failure is treated as fail closed.
* [ ] A single combined gate controls:
  * [ ] temporary logon-policy relaxation;
  * [ ] Winlogon autologon priming;
  * [ ] Stage B scheduling.
* [ ] If the combined gate is closed:
  * [ ] Stage B is not scheduled;
  * [ ] autologon is not primed;
  * [ ] recovery posture remains possible.

#### 4.3. Autologon priming and rollback guarantees

* [ ] Autologon priming follows an all-or-nothing model.
* [ ] `SetupComplete.cmd` creates the Stage B executor before committing Winlogon password state.
* [ ] If priming fails after partial setup begins, failure is recorded and rollback is attempted.
* [ ] A failure before temporary logon-policy relaxation is attempted does not invoke its rollback path.
* [ ] A failure after temporary logon-policy relaxation is attempted retains the existing rollback behavior.
* [ ] Partial priming failure does not collapse into silent success-like continuation.

#### 4.4. Stage B task registration and tamper boundary

* [ ] The Stage B executor runs in the intended trusted execution context and invokes the intended finalization entry point.
* [ ] Task registration does not expose secrets through task arguments or equivalent invocation surfaces.
* [ ] `SetupComplete.cmd` enforces the non-admin tamper boundary around:
  * [ ] `%WINDIR%\Setup\Scripts`;
  * [ ] `CreatePrimaryAdmin.ps1`;
  * [ ] the task definition file;
  * [ ] the task directory.
* [ ] Unsafe write-like or control rights for non-admin principals are treated as boundary violations.
* [ ] Task-registration failure is fail closed and blocks autologon priming.

#### 4.5. Reboot signaling model

* [ ] `SetupComplete.cmd` never performs an immediate reboot via `shutdown.exe`.
* [ ] Reboot need is represented through the Panther flag model.
* [ ] Reboot-required servicing RCs (`3010`, `1641`) feed into the reboot-signaling path without changing ownership of reboot execution.
* [ ] The reboot flag path and signaling logic are explicit and deterministic.
* [ ] `SetupComplete.cmd` may signal reboot need, but does not consume the final reboot as a Stage B substitute.

#### 4.6. Defender privacy component

* [ ] `ConfigureDefenderPrivacy.ps1` is the single runtime implementation owner of machine-policy `SpynetReporting=0` and `SubmitSamplesConsent=2`.
* [ ] Fresh-deployment logic does not explicitly configure or clean up `DisableBlockAtFirstSeen`, `LocalSettingOverrideSpynetReporting`, or `MpCloudBlockLevel`.
* [ ] The component verifies its owned registry policy separately from effective `IsTamperProtected`, `MAPSReporting`, and `SubmitSamplesConsent` state.
* [ ] The component observes but never disables or bypasses Tamper Protection.
* [ ] Exit `0` means the effective privacy posture was fully verified, exit `2` means policy/state inspection succeeded but effective posture is not guaranteed, and exit `1` means a technical execution or verification failure.
* [ ] `SetupComplete.cmd` invokes the component through the pinned Windows PowerShell 5.1 executable with `-NoProfile -NonInteractive -ExecutionPolicy Bypass -File` and captures output in `%WINDIR%\Panther\SetupComplete.log`.
* [ ] Exit `2`, technical nonzero results, and a missing component route through the existing non-fatal hardening-warning machinery without setting `FAILED`, `DISM_HARD_FAIL`, or fatal `L2C_FIRST_BAD_RC`, and without closing the trusted-continuation gate.
* [ ] The same idempotent component remains available under `%WINDIR%\Setup\Scripts` for an elevated post-deployment rerun.
* [ ] The two machine policy registry values remain separate from `UserBaselinePolicies.txt` and Local GPO `Registry.pol`; `gpedit.msc` display state is not used as the runtime source of truth.

---

### 5. CreatePrimaryAdmin.ps1 design contracts

#### 5.1. Stage A contracts

* [ ] Stage A reads `.primaryadmin.pw` under SYSTEM as its only primary-admin password source.
* [ ] Stage A uses `Microsoft.PowerShell.LocalAccounts` with `SecureString`, not plaintext external-process password application.
* [ ] Stage A fails closed and does not attempt user creation or password application when required platform, module, or secret-loading preconditions are not met.
* [ ] Stage A records a clear abort reason when it cannot continue.

#### 5.2. Stage B contracts

* [ ] Stage B owns post-logon finalization and teardown decisions.
* [ ] Stage B resets temporary Winlogon autologon state and restores temporary policy relaxations according to mode.
* [ ] Teardown and cleanup occur only when verification confirms that they are safe and eligible.
* [ ] When teardown is not eligible, Stage B preserves the recovery posture required for controlled follow-up.
* [ ] Stage B alone may consume a pending reboot on the normal success path; recovery posture suppresses automatic reboot consumption.

---

### 6. Documentation contract surface

Only contract-bearing documentation claims are audited here.

* [ ] System and architecture description remains aligned with implementation:
  * [ ] `README.md` stays consistent with the high-level system framing and stage model;
  * [ ] `docs/ARCHITECTURE.md` stays consistent with the major system model, boundaries, handoffs, completion semantics, trust boundaries, and reboot model.

* [ ] Security and rationale constraints remain aligned with implementation:
  * [ ] `SECURITY.md` stays consistent with actual secret handling, trust boundaries, recovery posture, and reboot restrictions;
  * [ ] `DECISIONS.md` stays consistent with deliberate behavioral and security constraints that materially shape the implementation.

* [ ] Repository execution and maintenance rules remain aligned with implementation:
  * [ ] `AGENTS.md` stays consistent with repository invariants that agents must not violate;
  * [ ] `CONTRIBUTING.md` stays consistent with contributor obligations for validation discipline, file-handling discipline, and affected-document responsibility.