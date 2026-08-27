# AGENTS.md

**Scope:** Windows 11 Enterprise LTSC 2024 (`EnterpriseS`, `24H2`, build `26100+`, strict display-version gate). We manage only the install scripts.

## Allowed to edit

`SetupComplete.cmd`, `UserBaselinePolicies.txt`, `PreOOBE.cmd`, `BootstrapLocalAdmin.ps1`, `ConfigureDefenderPrivacy.ps1`, `CreatePrimaryAdmin.ps1`, `ValidateSecrets.ps1`, `README.md`, `DECISIONS.md`, `SECURITY.md`, `CONTRIBUTING.md`, `docs/AUDIT_CHECKLIST.md`, `docs/INTERACTION_CONTRACT.md`, `docs/VALIDATION.md`, `docs/GUIDE.md`, `docs/QUICK_START.md`, `docs/PIPELINE_FLOW.md`, `docs/OPERATIONS.md`, `docs/TROUBLESHOOTING.md`, `docs/ARCHITECTURE.md`.

**Owner-controlled areas** (default: out of scope for agents)

The allow-list in this document is the default scope for agent-initiated edits. The Owner may explicitly authorize exact additional paths for one specific task/PR; that authorization overrides the default restriction only for that task and must be documented in the PR description. A one-off authorization does not add the path to the permanent default allow-list. Permanently adding a path to the default scope requires a separate update to this document.
Files under `tools/` and `.agents/skills/` are owner-controlled. Agents must not create, modify, or delete files in these areas unless the current task explicitly includes those paths in its allow-list.


**Forbidden:**

- Any edits by agents to files that are neither listed in the “Allowed to edit” section above nor explicitly authorized by the Owner for the current task/PR under the exception above.
- Adding a path to the permanent default agent edit scope without, in the same PR:
  - adding it to the “Allowed to edit” list in `AGENTS.md`, and
  - (recommended) backing the change with an ADR that explains why the path belongs in the permanent default scope.
- Carve-out (Interaction Contract): when temporary Codex-created files are genuinely needed, they MAY be created only under the repository root's `.codex_tmp\` directory. This carve-out does not allow creating new files elsewhere.

## Roles and responsibilities

* **Owner (maintainer/operator):** defines the scope for each change, runs Codex CLI locally, reviews diffs, applies changes, performs all state-changing Git actions (commit, push, PR, merge), and remains accountable for final behavior and security posture.
* **ChatGPT:** helps draft prompts, audits, and documentation text. Has no direct access to the repo working copy, cannot run commands or Git actions, and must not claim that tests were executed.
* **Codex CLI:** edits files in the local working copy within the allowed scope, produces minimal diffs, follows `docs/INTERACTION_CONTRACT.md`, does not perform state-changing Git actions, and does not expand scope without explicit instruction. Read-only Git commands (for example `git status`, `git diff`) are allowed when needed for situational awareness.
* **CI (GitHub Actions):** runs automated checks on PRs (for example EOL/BOM/NUL guardrails and ASCII-only scripts via "ASCII Only Guard") and reports status only. CI does not replace human review and does not modify repository content.

## Invariants

* **No immediate reboots** inside `SetupComplete.cmd`. Reboot requirements are signaled only via `%WINDIR%\Panther\_needs_reboot.flag` (`Panther flag`) when `RC ∈ {3010, 1641}` or `ALWAYS_REBOOT_AFTER_FIRST_LOGON=1`. `SetupComplete.cmd` never calls `shutdown.exe`.
* Documentation must match actual behavior (paths, logs, steps). Use `README.md` as the front door, `docs/GUIDE.md` as the documentation router, `DECISIONS.md` for rationale and trade-offs, `SECURITY.md` for security posture, and the relevant `docs/*` owner document for procedural or operational detail.

### Tracked Windows runtime code

These rules govern the installation scripts that run on the supported Windows target. They do not prescribe how Codex executes tools.

* Tracked PowerShell scripts and PowerShell commands launched by tracked runtime code must remain compatible with **Windows PowerShell 5.1**.
* When tracked PowerShell runtime code uses `reg.exe`, use classic registry paths such as `HKLM\...` and inspect `$LASTEXITCODE`. PowerShell registry cmdlets use provider paths such as `HKLM:\...`. Preserve the existing `Reg-Del` idempotency semantics in `CreatePrimaryAdmin.ps1`, including `{0,2}` as successful delete outcomes.
* In tracked `.cmd` files, `EnableDelayedExpansion` is forbidden. Use plain `%VAR%` expansion and implement branching via labels and subroutines (`goto`, `call :sub`) without relying on delayed expansion.
* **CMD parse-time expansion:** inside any parenthesized `(...)` block, it is forbidden to read `%VAR%` for variables that may be set/modified within the same block (including changes caused by `call :sub` invoked from that block). Only acceptable fixes: move the read/log/branch outside the `(...)` block, or use CALL-expansion with `%%VAR%%` (example: `call :log "resolved_path=%%OUT_PATH%%"`).

## Codex repository contract

`docs/INTERACTION_CONTRACT.md` is the canonical contract for repository-operation safety and integrity.

* Work only in the Owner-selected current branch. Do not switch branches.

### EOL/BOM policy

* `*.md` stored with LF. `.cmd/.ps1` stored with CRLF.
* Tracked text files use UTF-8 without BOM. Zero bytes are forbidden in tracked text files.
* Tracked `.cmd` and `.ps1` files are ASCII-only.
* The GitHub EOL guard enforces the EOL policy. Treat .gitattributes as the source of truth for LF vs CRLF expectations.
* UTF-8 without BOM and “no NUL bytes” are required invariants; GitHub CI enforces them for a conservative set of tracked text-like files (see `.github/workflows/eol-guard.yml`). In-repo local hooks do not enforce them.

## Policies

* **Edition gate:** `EditionID == REQUIRED_EDITION` → otherwise **FAIL**.
* **DISM RC policy (SetupComplete.cmd):**
  * `0` → success.
  * `3010/1641` → success, reboot required; set `NEEDS_REBOOT=1` and write the Panther reboot flag.
  * `-2146498548/2148468748` (“feature not recognized in this image”) and `-2146498541/2148468755` (“invalid install state for this feature”) → warning; log as such, set `HAS_DISM_WARN=1`, and treat as success.
  * The state-aware optional-feature probe is separate from the general mutation RC policy: `Disabled` → clean skip, `Enabled` → use the existing disable path, recognized feature-not-found → absent/clean skip, and any unexpected probe failure or unproven state → fail closed.
  * The dedicated SNMP capability probes are a separate best-effort path, not the optional-feature probe contract: probe uncertainty, nonzero probe RCs, or unproven states may warn, skip, and continue; only parsed `Installed` or `Staged` state triggers a removal attempt. Once attempted, `/Remove-Capability` uses the normal DISM mutation policy, so an unexpected removal failure is fatal.
  * Any other RC from a classified DISM mutation or servicing call → fatal servicing error; log it, set `FAILED=1` and `DISM_HARD_FAIL=1`, and capture the first fatal return code in `L2C_FIRST_BAD_RC` via `:track_rc`. Once `DISM_HARD_FAIL` is set, further DISM feature/capability/cleanup calls must be skipped for the rest of the run.
* **DISM log:** single path for all calls — `%WINDIR%\Logs\DISM\SetupComplete-DISM.log` (use `/LogPath` + `/LogLevel:4`).
* **Logs:** `%WINDIR%\Panther\PreOOBE.log`, `%WINDIR%\Panther\SetupComplete.log` (timestamped logger-written lines are normally ISO-8601; some lines may be un-timestamped), and the DISM log above.
* **Defender privacy profile:** `ConfigureDefenderPrivacy.ps1` is the single runtime owner of machine-policy `SpynetReporting=0` and `SubmitSamplesConsent=2`. It verifies those registry values separately from the effective `IsTamperProtected`, `MAPSReporting`, and `SubmitSamplesConsent` state, never disables or bypasses Tamper Protection, and returns `0` for a fully verified posture, `2` for a posture warning, or `1` for a technical failure. `SetupComplete.cmd` converts exit `2`, technical nonzero results, or a missing component into non-fatal hardening warnings only; those outcomes do not close the trusted-continuation gate. The component uses direct machine policy registry values rather than Local GPO `Registry.pol`, remains available for an elevated manual rerun, and does not manage or clean up `DisableBlockAtFirstSeen`, `LocalSettingOverrideSpynetReporting`, or `MpCloudBlockLevel` from historical installations.
* **Winlogon:** `HKLM\...\Winlogon\IgnoreShiftOverride` = **REG_SZ "0"** (not `REG_DWORD`), with no intermediate `"1"`.
* **Bootstrap/primary-admin chain:** `BootstrapLocalAdmin.ps1` must resolve the local Administrators group locale-agnostically via SID `S-1-5-32-544`; use the resolved group identity/name for LocalAccounts group membership operations; and set ACLs on `.bootstrap.pw` using locale-agnostic principals (SID-based principals are acceptable; `NTAccount` translation is optional).
* **No secret-on-CLI (bootstrap):** `BootstrapLocalAdmin.ps1` must not pass the bootstrap password as an argument on an external process command line (no `net.exe user <password>`); it uses `Microsoft.PowerShell.LocalAccounts` cmdlets with a `SecureString` password.
* **.bootstrap.pw policy:** `.bootstrap.pw` must be created with inheritance disabled and an explicit ACL (no deny ACEs) granting FullControl only to `S-1-5-18` (SYSTEM) and `S-1-5-32-544` (BUILTIN\Administrators), Hidden + System attributes, and UTF-8 (no BOM). If ACL application fails, Stage A must fail closed rather than proceeding with a weakened or inherited ACL. Stage B deletes `.bootstrap.pw` and `.primaryadmin.pw` only when `TeardownEligible` and independently verified executor teardown are both true (normal mode, both Winlogon cleanup and logon policy restore are verified, `bootstrap` is disabled, and the continuation task is absent); otherwise it preserves both secrets for recovery/diagnostics. Mutation return codes are diagnostic evidence and do not prove those final states. Stage B records a cleanup state per secret in its master log (`removed`, `missing`, `error`, `preserved`, or `skipped`) and emits WARN/ERROR entries for non-ideal states. Any relaxation of these guarantees requires an ADR in `DECISIONS.md` and matching updates to `SECURITY.md` before code changes.
* `PreOOBE.cmd` (specialize) invokes `BootstrapLocalAdmin.ps1`. PreOOBE does not touch Winlogon, passwordless settings, or scheduled tasks.
* **SetupComplete.cmd:** servicing/logging plus final reboot-obligation selection and signaling after DISM feature/capability servicing, followed by the Stage B gateway (secret validation + gate + optional Stage B scheduling/Winlogon priming when the combined gate is open). When a reboot is required, servicing-driven need preserves `need-reboot`, while `ALWAYS_REBOOT_AFTER_FIRST_LOGON=1` selects `force-reboot` and sets `NEEDS_REBOOT=1`; the final Panther flag is written and positively verified before the gateway opens. Signaling failure keeps Stage B registration and autologon priming closed. It never calls `shutdown.exe`.
* On any Bootstrap or self-test failure the pipeline switches to recovery mode. In recovery the `\L2C\CreatePrimaryAdmin` task is not registered.

### Reboot orchestration guardrails

* `SetupComplete.cmd` is the only stage that originates and records a deferred reboot requirement, and it may communicate that requirement only through the `Panther flag`.
* Stage B of `CreatePrimaryAdmin.ps1` is the only unattended stage allowed to interpret the `Panther flag` and make the final automatic reboot decision. In normal mode it uses the marker semantics together with current pending-reboot evidence. It may delete the flag only when Stage B completes successfully in normal mode; on failure or in recovery it must suppress automatic reboot and may leave the flag in place as a diagnostic marker.
* No tracked script other than Stage B of `CreatePrimaryAdmin.ps1` may call `shutdown.exe` automatically; the `Panther flag` remains the single reboot signal.
* After Stage B completes successfully in normal mode, it first requires a readable, supported Panther marker. A `force-reboot` marker bypasses `Test-SystemRebootPending` and requires reboot; only a readable valid `need-reboot` marker uses that probe, with pending state `true` or `unknown` causing conservative reboot and `false` treated as stale and cleared without reboot. Empty, unreadable, unsupported, or otherwise unclassifiable marker state fails closed without invoking `shutdown.exe`.
* Before automatic reboot, Stage B consumes a valid marker only after deletion and marker absence are positively verified, then invokes `shutdown.exe` once and checks its result. A failed shutdown request attempts to restore and verify the original marker; if verification fails, marker state is not proven. It issues no retry and returns reboot-finalization RC 8 when no earlier nonzero result owns the process result; successful teardown is not rolled back.
* In recovery mode, or if Stage B fails, it never calls `shutdown.exe`. It only logs the presence of the `Panther flag` and the fact that automatic reboot was suppressed, and it may leave the flag in place for operators or later manual runs (see DECISIONS.md for details).
* When editing docs or code, keep the reboot model flag-based end to end and do not add new decision points in other scripts or tasks.

### Audit sessions (Codex CLI)

- `docs/AUDIT_CHECKLIST.md` is the canonical checklist for end-to-end audits of scripts and documentation. It defines the minimum bar for a “full audit”, not the maximum scope.
- There are two explicit audit modes, controlled by the Owner’s prompt.

#### 1. Strict checklist audit

When the Owner explicitly requests a strict checklist audit (for example, “run a strict audit against docs/AUDIT_CHECKLIST.md”):

- Codex must:
  - read `docs/AUDIT_CHECKLIST.md` first;
  - structure its checks and output according to the checklist sections;
  - stay within the checklist scope and avoid introducing extra checks that contradict or extend it.
- The goal of this mode is to verify that the current code and docs fully comply with the agreed checklist, without redefining it on the fly.

#### 2. Full audit (checklist + exploratory)

When the Owner requests a full audit (for example, “run a full audit of SetupComplete.cmd and CreatePrimaryAdmin.ps1”), Codex must:

- treat `docs/AUDIT_CHECKLIST.md` as the baseline:
  - read the checklist first;
  - explicitly cover all relevant sections in its report;
- then, in a separate section such as `Additional findings (outside the checklist)`:
  - report any extra issues, smells, or improvement ideas that are not yet formalized in the checklist;
  - clearly mark that these findings go beyond the current checklist and may later be promoted into new checklist items.

In other words, for full audits the checklist defines the minimum guaranteed coverage, but Codex is encouraged to surface additional findings as long as they are clearly separated from the checklist-based assessment.

#### 3. Narrow edits

For narrow, file-scoped edits (small bugfixes, refactors, localized doc touch-ups), Codex:

- does not have to load `docs/AUDIT_CHECKLIST.md` into context;
- still must follow the applicable rules in this document and `docs/INTERACTION_CONTRACT.md`.

## PR rules

* Minimal diffs grouped per file; no cosmetic changes outside hunks.
* PR description must confirm: edition gate, DISM RC policy, unified `/LogPath`, log locations, `IgnoreShiftOverride`, and formatting (UTF-8 / CRLF vs LF).

## Runbook — manual smoke path (bypasses SetupComplete secret gate)

**Run in an elevated *Windows PowerShell 5.1* console.**

Prerequisite (required): this manual path bypasses the `SetupComplete.cmd` secret validation gate. Run Step 0 to validate `%WINDIR%\Setup\Scripts\.bootstrap.pw` and `%WINDIR%\Setup\Scripts\.primaryadmin.pw` ACL/attributes via `ValidateSecrets.ps1` (SEC-2); proceed only when `ValidateSecrets.ps1` returns `2` or `3` (primaryadmin bit set).

Step 0 (required): SEC-2 secret validation gate (PASS only if `ValidateSecrets.ps1` returns `2` or `3`).

```powershell
$vs = Join-Path $env:WINDIR 'Setup\Scripts\ValidateSecrets.ps1'
if (-not (Test-Path -LiteralPath $vs -PathType Leaf)) { Write-Error "[SEC-2] FAIL: missing ValidateSecrets.ps1 at $vs"; exit 1 }
& $vs -BootstrapPath (Join-Path $env:WINDIR 'Setup\Scripts\.bootstrap.pw') -PrimaryAdminPath (Join-Path $env:WINDIR 'Setup\Scripts\.primaryadmin.pw')
$rc = $LASTEXITCODE
if ($rc -eq 2 -or $rc -eq 3) { Write-Host "[SEC-2] PASS: primaryadmin secret validated (RC=$rc). Proceed to Step 1." }
else { Write-Error "[SEC-2] FAIL: ValidateSecrets RC=$rc. Stop and fix %WINDIR%\Setup\Scripts\.primaryadmin.pw (and %WINDIR%\Setup\Scripts\.bootstrap.pw if present) ACL/attrs before proceeding."; exit 1 }
```

Step 1: register the master task in Task Scheduler.

```cmd
schtasks /Create /TN "\L2C\CreatePrimaryAdmin" /TR "powershell.exe -NoProfile -ExecutionPolicy Bypass -File ""%WINDIR%\Setup\Scripts\CreatePrimaryAdmin.ps1""" /SC ONLOGON /RU SYSTEM /RL HIGHEST /F
```

If Step 0 fails, do not run Step 1.

Disclaimer: this is a manual engineering test. Inside `SetupComplete.cmd` no reboot is executed. A deferred reboot can only happen later when Stage B consumes the `Panther flag` that `SetupComplete.cmd` wrote after servicing RC `3010/1641` or when `ALWAYS_REBOOT_AFTER_FIRST_LOGON=1` is set.

*After a successful normal run, verify the post-run state using `docs/OPERATIONS.md` (`Post-Run Checks`): `AutoAdminLogon=0`, `ForceAutoLogon=0`, `DefaultPassword` removed and `AutoLogonCount` absent or `0`, `HKLM\SOFTWARE\L2C\AutologonPrimed` absent (best-effort), `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\DisableCAD=0`, `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI\Ngc\DevicePasswordLessBuildVersion=2`, `bootstrap` disabled and independently verified, `primaryadmin` is a member of Administrators, task `\L2C\CreatePrimaryAdmin` absent and independently verified, and `C:\ProgramData\l2c_master_<timestamp>.log` present.*

*`SetupComplete.cmd` aggregates a final exit code instead of exiting immediately on the first failure: if `L2C_FIRST_BAD_RC` is set, `FINAL_RC=L2C_FIRST_BAD_RC`; otherwise, if `FAILED==1`, `FINAL_RC=1`; otherwise, if `L2C_AUTOLOGON_DEGRADED==1`, `FINAL_RC=2` (`[FINAL] DEGRADED manual_login_required=1`); otherwise `FINAL_RC=0`. Hard failures take precedence over DEGRADED (`[FINAL] FAIL (FINAL_RC=...)`). When `FINAL_RC=0`, the human-readable final marker is `[FINAL] SUCCESS` or `[FINAL] SUCCESS_WITH_HARDENING_WARNINGS` depending on whether best-effort hardening warnings were collected. Those warnings are best-effort deduplicated and surfaced after `[RC] returning %FINAL_RC%` as `[HARDENING] warn_count_unique=<n> file=<artifact>` plus the warning lines; this transparency does not by itself change the returned RC. DISM warnings (`HAS_DISM_WARN=1`) do not force a failure.*

**Validation on a fresh VM:**

1. `PreOOBE.cmd` (specialize pass) applies early privacy and security policies and runs `BootstrapLocalAdmin.ps1`. Bootstrap creates or refreshes the temporary `bootstrap` admin, writes `%WINDIR%\Setup\Scripts\.bootstrap.pw` with ACL restricted to SYSTEM and the local Administrators group, and stops there. It does not touch Winlogon, passwordless settings, or scheduled tasks.
2. `SetupComplete.cmd` runs in the SetupComplete phase, before the first interactive logon, performs DISM servicing, and applies DISM return-code policy. Known benign servicing codes are treated as warnings, `3010`/`1641` are treated as "reboot required" success outcomes, and unexpected DISM errors set `FAILED=1` and `DISM_HARD_FAIL=1`. A hard-fail stops further DISM-dependent work for the remainder of the run (skips additional feature/capability/cleanup operations), but the script still reaches the final aggregation and exits with `FINAL_RC` (first fatal RC via `L2C_FIRST_BAD_RC`, otherwise `1` if `FAILED=1`, otherwise `2` if `L2C_AUTOLOGON_DEGRADED==1`, otherwise `0`). The human-readable final marker can therefore be `[FINAL] FAIL (FINAL_RC=...)`, `[FINAL] DEGRADED manual_login_required=1`, `[FINAL] SUCCESS`, or `[FINAL] SUCCESS_WITH_HARDENING_WARNINGS`; when hardening warnings exist the log also emits `[HARDENING] warn_count_unique=<n> file=<artifact>` plus the warning lines from the warning file without changing that RC by itself. After its servicing section, `SetupComplete.cmd` selects the final reboot obligation and, when required, writes and positively verifies the `Panther flag` before opening the Stage B gateway (secret validation + gate + optional Stage B scheduling/Winlogon priming); when `FAILED=1` it logs `SetupComplete entered recovery mode; skipping extra registrations` and does not schedule/prime Stage B.
3. On the first logon the SYSTEM task `\L2C\CreatePrimaryAdmin` runs `CreatePrimaryAdmin.ps1`. Stage A creates or repairs the primary admin account and ensures membership in the local Administrators group. Stage B always runs afterwards, collapses the temporary Winlogon autologon and verifies post-action that `DefaultPassword` is absent and autologon values are disabled; pre-teardown verification failures (or read errors) are treated as a hard-fail that keeps `bootstrap` enabled and the scheduled task retained. Stage B restores `DisableCAD=0` and `Ngc\DevicePasswordLessBuildVersion` mode-aware (`2` in normal mode, `0` in recovery), best-effort deletes `HKLM\SOFTWARE\L2C\AutologonPrimed`, attempts to delete `.bootstrap.pw` and `.primaryadmin.pw` only when `TeardownEligible` and independently verified executor teardown are both true (normal mode, both Winlogon cleanup and logon policy restore are verified, `bootstrap` is disabled, and the continuation task is absent; otherwise preserves both secrets), and writes `C:\ProgramData\l2c_master_<ts>.log`. In the normal success path it also disables the `bootstrap` account and deletes the `\L2C\CreatePrimaryAdmin` scheduled task, then independently verifies both final states, so that the temporary bootstrap entry point is removed only when proven absent. If the `Panther flag` exists after Stage B completes successfully in normal mode, Stage B first requires a readable, supported marker: a `force-reboot` marker bypasses pending-reboot probing and requires reboot; only a valid `need-reboot` marker uses current pending-reboot evidence, with `true` or `unknown` causing conservative reboot and `false` clearing stale state without reboot. Empty, unreadable, unsupported, or otherwise unclassifiable markers fail closed without shutdown. In recovery mode or when teardown eligibility is not established, Stage B leaves the `bootstrap` account and scheduled task in place for retry as implemented. Once executor teardown mutations begin, later failures may leave `bootstrap` disabled and/or the scheduled task absent because successful mutations are not rolled back; inspect actual executor state rather than assuming bootstrap sign-in or task registration remain available. Failed normal Stage B and recovery paths suppress automatic reboot, still log the presence of the flag and that the automatic reboot was suppressed, do not call `shutdown.exe`, and may leave the flag in place as a diagnostic marker recorded in the master log.
   Before the single automatic reboot request, Stage B verifies marker absence; if shutdown scheduling fails, it attempts to restore and verify the original marker, issues no automatic retry, and returns reboot-finalization RC 8 when no earlier nonzero result owns the process result. This later reboot-finalization failure does not roll back successful teardown or secret cleanup, and `OUTCOME: SUCCESS` remains the provisioning/teardown result rather than proof that shutdown was accepted.

**Repeat validation (snapshots / new VM):**

* Run `schtasks /Query /TN "\L2C\CreatePrimaryAdmin"`. If the task is missing, register it again using the command shown in Step 1 of this manual smoke path. Ensure that `.bootstrap.pw` is absent before a manual rerun, or that it contains a lab password with correct ACL and attributes.
* Run `schtasks /Run /TN "\L2C\CreatePrimaryAdmin"` and verify that Stage B again cleans Winlogon state and, on success, independently verifies that `bootstrap` is disabled and the scheduled task is absent before producing a fresh `l2c_master_<ts>.log`.
