## LTSC-CQ audit checklist (scripts + documentation)

### 1. Repository-wide invariants

* [ ] All PowerShell scripts (`*.ps1`) use:

  * [ ] UTF-8 encoding without BOM.
  * [ ] CRLF line endings.
* [ ] All CMD scripts (`*.cmd`, `*.bat`) use:

  * [ ] ANSI or UTF-8 without BOM (within CI constraints).
  * [ ] CRLF line endings.
* [ ] All Markdown documentation (`*.md`) uses:

  * [ ] UTF-8 encoding without BOM.
  * [ ] LF line endings.
* [ ] Each file satisfies:

  * [ ] No strange control characters, null bytes, or non-standard spaces in critical places.
  * [ ] No mixed EOLs inside a single file.
* [ ] All scripts pass syntax validation:

  * [ ] PowerShell: `Set-StrictMode -Version Latest`, no syntax errors.
  * [ ] CMD: no unclosed quotes, correct structure of `(` `)` blocks.

### 1.1. Unattended setup UX (image selection & EULA)

* [ ] Installer skips the edition picker (LTSC vs LTSC N) because the answer file selects the OS by `/IMAGE/INDEX=1` in `windowsPE`.
* [ ] License terms / EULA screen does not appear during unattended install because `<UserData><AcceptEula>true</AcceptEula>` is set in `Autounattend.xml`.

---

### 2. Password source files lifecycle (`.bootstrap.pw` and `.primaryadmin.pw`)

* [ ] Documentation (README, DECISIONS, AGENTS, SECURITY) describes:

  * [ ] Where exactly `.bootstrap.pw` is created (`%WINDIR%\Setup\Scripts`), who reads it, and when it must be deleted or preserved (normal success vs recovery; Winlogon cleanup verification failures preserve it).
  * [ ] Where `.primaryadmin.pw` is expected to exist (`%WINDIR%\Setup\Scripts`), that it is operator-supplied, who reads it (`SetupComplete.cmd` and Stage A), and when it is deleted or preserved (normal success vs recovery; Winlogon cleanup verification failures preserve it).
* [ ] In `BootstrapLocalAdmin.ps1`:

  * [ ] `.bootstrap.pw` is created at the expected path (`%WINDIR%\Setup\Scripts\.bootstrap.pw`).
  * [ ] Content is a single non-empty line (UTF-8 without BOM).
  * [ ] File ACL is restricted (SYSTEM + Administrators only), inheritance disabled, Hidden + System attributes set.
* [ ] In `SetupComplete.cmd`:

  * [ ] `ValidateSecrets.ps1` is invoked in the gateway block after DISM feature/capability servicing and before the reboot-flag evaluation with both secret paths, does not read passwords, and returns a 0–3 exit-code bitmask (bit0=bootstrap, bit1=primary admin) that is decoded from `%ERRORLEVEL%` into `L2C_BOOTSTRAP_PW_ACL_OK` and `L2C_PRIMARYADMIN_PW_ACL_OK`, then logged as `[SECTION] Secret ACL validation (bootstrap=..., primaryadmin=...)`; exit code `4` is reserved for internal validator errors.
  * [ ] When the validator returns `4`, `SetupComplete.cmd` logs an explicit internal-failure message (rc=4), sets `FAILED=1`, keeps both ACL flags at `0`, and treats both secrets as invalid for gating.
  * [ ] There is a check for the existence of `.bootstrap.pw` and that the first line is non-empty (single-line secret; read via `set /p`, no trimming).
  * [ ] There is a check that `%WINDIR%\Setup\Scripts\.primaryadmin.pw` exists and passes the ACL/attribute flag before it is read.
  * [ ] `.primaryadmin.pw` is read via `set /p` (first line only) only when the ACL/attribute check succeeded, is non-empty as read, and respects the allowed character set/format (`A-Z`, `a-z`, `0-9`, `#`, `@`, `_`, `-`).
  * [ ] If it is missing or empty:

    * [ ] An error is logged, not just a warning.
    * [ ] A failure flag is set (for example `FAILED=1`).
    * [ ] Stage B registration (CreatePrimaryAdmin task) is blocked.
  * [ ] If `.primaryadmin.pw` is missing or invalid:

    * [ ] An `[ERROR]` is logged.
    * [ ] `FAILED=1` is set.
    * [ ] Stage B registration and autologon priming are blocked.
  * [ ] A single combined gate (FAILED==0, `.bootstrap.pw` present/non-empty, `.primaryadmin.pw` present and ACL/attribute OK, allowed characters) controls temporary logon tweaks, autologon priming, and Stage B registration; the gate also stays closed when the validator returns exit code `4` (internal error) because `FAILED=1` is set and both ACL flags remain `0`.
  * [ ] For a happy-path run, `SetupComplete.log` shows `[SECTION] Secret ACL validation (bootstrap=1, primaryadmin=1)` before CreatePrimaryAdmin is scheduled; for a deliberate ACL/attribute/absence fault in either secret the log shows at least one `0` and SetupComplete enters the fail-closed/recovery path (no task registration or autologon priming).
* [ ] `.primaryadmin.pw` formatting checks:

  * [ ] Positive: the file contains exactly one non-empty line with the password; the gate opens and Stage B is registered.
  * [ ] Negative (leading empty line): the first line is empty and the password is on the second line; `SetupComplete.log` shows an `[ERROR]` about empty/disallowed characters, the gate stays closed (no autologon priming), and Stage B is not registered.
* [ ] In `CreatePrimaryAdmin.ps1`:

  * [ ] Stage A reads `%WINDIR%\Setup\Scripts\.primaryadmin.pw` under SYSTEM as its only password source (no `.bootstrap.pw`, no command-line password arguments).
  * [ ] Password application uses `Microsoft.PowerShell.LocalAccounts` (`New-LocalUser`/`Set-LocalUser` with a `SecureString`); no plaintext password is ever passed to external processes.
  * [ ] Stage A fails closed if running under a 32-bit PowerShell process (`Is64BitProcess=false`) or if `Microsoft.PowerShell.LocalAccounts` cannot be imported / required cmdlets are missing.
  * [ ] Behavior is defined for:

    * [ ] Missing, unreadable, or empty `.primaryadmin.pw`.
    * [ ] Read/validation errors surfaced from `.primaryadmin.pw` (ACL, IO, invalid characters).
  * [ ] In case of secret-related problems:

    * [ ] A clear `StageAAbortReason` is set.
    * [ ] Stage A does not attempt to create or modify the user with an invalid or missing password.
    * [ ] Stage B still performs the required cleanup (according to the normal/recovery policy).
  * [ ] For `primaryadmin`, the password value never appears in task XML, command lines, or the baseline's own logs.
  * [ ] With Audit Process Creation + command-line logging enabled, Security 4688 events do not show the `primaryadmin` password on any process command line.
* [ ] Negative test: build an ISO that forces `.bootstrap.pw` ACL hardening to fail (for example by breaking `Set-Acl`), confirm `PreOOBE.log` shows the ACL failure and the delete attempt (success / nothing to delete / failure), verify the run does not leave `.bootstrap.pw` silently with weak ACLs, and observe that `ValidateSecrets`/`SetupComplete` treat the missing/empty secret as `bootstrap=0` so the gate stays closed and Stage B is not registered.

---

### 3. PreOOBE / BootstrapLocalAdmin (Stage 0)

* [ ] `PreOOBE.cmd`:

  * [ ] Launches `BootstrapLocalAdmin.ps1` in the expected way.
  * [ ] Does not modify Winlogon or logon policies if this is forbidden by design.
  * [ ] Redirects stdout and stderr from `BootstrapLocalAdmin.ps1` into `%WINDIR%\Panther\PreOOBE.log` (no separate bootstrap log file).
* [ ] `BootstrapLocalAdmin.ps1`:

  * [ ] Runs with `Set-StrictMode -Version Latest` and `$ErrorActionPreference='Stop'` (same defensive posture as `CreatePrimaryAdmin.ps1`).
  * [ ] Creates a temporary `bootstrap` account with minimal required rights where applicable.
  * [ ] Sets or updates the password using `Microsoft.PowerShell.LocalAccounts` cmdlets (with `SecureString`).
  * [ ] Does not pass the bootstrap password as an argument on any external process command line (for example, no `net.exe user <user> <password> ...`).
  * [ ] Ensures `bootstrap` is enabled (`Enable-LocalUser`) if required by the scenario.
  * [ ] Emits `[BOOTSTRAP] [INFO|WARN|ERROR] ...` lines in `%WINDIR%\Panther\PreOOBE.log` for key lifecycle steps (account creation, password set/activate, Administrators membership, `.bootstrap.pw` write/ACL/attributes).
  * [ ] Bootstrap log entries do not include the password or derived secret values (technical actions/errors only).
  * [ ] Does not leave extra handlers or resources (including tasks that are not described in the design).

---

### 4. SetupComplete.cmd (servicing + gateway stage)

#### 4.1. General structure and flags

* [ ] Flags and helper variables are initialized at the top:

  * [ ] `ALWAYS_REBOOT_AFTER_FIRST_LOGON` (manual reboot after first logon).
  * [ ] `NEEDS_REBOOT` (whether a post-install reboot is required).
  * [ ] `FAILED` (SetupComplete failure).
  * [ ] `HAS_BOOTSTRAP_PW` (valid `.bootstrap.pw`).
  * [ ] `L2C_FIRST_BAD_RC` (first non-success servicing RC).
  * [ ] `REBOOT_FLAG` (path to the Panther flag `%WINDIR%\Panther\_needs_reboot.flag`).
* [ ] All servicing return code (RC) handling:

  * [ ] Uses a single tracking path via `L2C_FIRST_BAD_RC`.
  * [ ] Does not lose the first non-success RC.
* [ ] Execution order: DISM feature/capability servicing occurs before the Stage B gateway (secret validation + gate + optional scheduling/Winlogon priming), and the gateway runs before the Panther reboot-flag evaluation section.
* [ ] Start and end logging:

  * [ ] `----- SetupComplete started -----`.
  * [ ] A clear final entry indicating success or failure.
  * [ ] Final entry of the form `[RC] returning <code>` written via `:log`, where `<code>` equals:
        - `0` on success;
        - the first fatal DISM RC when present (`L2C_FIRST_BAD_RC`);
        - or `1` when `FAILED==1` without a captured fatal RC.
* [ ] Platform gate (EditionID, DisplayVersion, CurrentBuild) does not exit early: on mismatch it logs an ERROR, sets `FAILED=1`, and jumps to the shared final RC label (for example `l2c_final_rc`).
* [ ] All failure scenarios, including platform mismatches, reach the final RC block and emit the tail line `[RC] returning <FINAL_RC>` in `SetupComplete.log`.
* [ ] Single top-level exit path: the final RC block at the shared label logs `[RC] returning <FINAL_RC>` and `exit /b %FINAL_RC%`; no other top-level `exit /b` paths are used for script termination.

#### 4.2. `.bootstrap.pw` check and Stage B gate

* [ ] File check:

  * [ ] `if exist "%PWFILE%" (...)`.
  * [ ] The first line is read only (`set /p`) and must be non-empty (single-line secret; no trimming).
* [ ] If a valid secret is present (`.bootstrap.pw` exists and has content):

  * [ ] `HAS_BOOTSTRAP_PW` is set to `"1"`.
* [ ] If missing or empty:

  * [ ] `HAS_BOOTSTRAP_PW` remains `"0"` or equivalent.
  * [ ] `FAILED=1`.
  * [ ] Log contains `[ERROR] .bootstrap.pw missing or empty; ...`.
* [ ] `.primaryadmin.pw` validation:

  * [ ] Presence and non-empty first-line content at `%WINDIR%\Setup\Scripts\.primaryadmin.pw` is validated using the allowed character set (no trimming).
  * [ ] Invalid or missing `.primaryadmin.pw` logs an `[ERROR]`, sets `FAILED=1`, and blocks Stage B registration and autologon priming.
  * [ ] Stage B/autologon priming proceed only when both `.bootstrap.pw` and `.primaryadmin.pw` are valid and `FAILED==0`.
  * [ ] ACL/attribute flags from `ValidateSecrets.ps1` (`L2C_BOOTSTRAP_PW_ACL_OK`, `L2C_PRIMARYADMIN_PW_ACL_OK`) must be `1`; failures are logged and force `FAILED=1` before the primary admin password is read.
* [ ] Winlogon autologon to `bootstrap`:

  * [ ] Runs only when `HAS_BOOTSTRAP_PW=="1"` and a valid primary admin secret is present and `FAILED==0`.
  * [ ] Follows an all-or-nothing model: `SetupComplete.cmd` first creates the `\L2C\CreatePrimaryAdmin` executor task; only then it writes `DefaultPassword` and checks the RC, and only when RC=0 enables `AutoAdminLogon` and `ForceAutoLogon`.
  * [ ] If any Winlogon priming sub-step fails after task creation (password write or `reg add`), SetupComplete logs one or more `[ERROR]` entries (depending on the failing sub-step), sets `FAILED=1` and `STAGEB_NOT_SCHEDULED=1`, rolls back Winlogon autologon-related values (clears `DefaultUserName`/`DefaultDomainName`, removes `DefaultPassword` (absent), resets `AutoAdminLogon`/`ForceAutoLogon`/`AutoLogonCount`), and attempts best-effort deletion of `\L2C\CreatePrimaryAdmin`.
  * [ ] Temporary logon policy relaxations (`DisableCAD`, `DevicePasswordLessBuildVersion`) occur only when the combined gate passes; skip path logs the gate state.

#### 4.3. CreatePrimaryAdmin task registration (Stage B)

* [ ] Creation of the `\L2C\CreatePrimaryAdmin` task:

  * [ ] Happens only when `FAILED==0`, `HAS_BOOTSTRAP_PW==1`, and a validated primary admin secret is present.
  * [ ] Task parameters: SYSTEM, Highest, OnLogon, path to `CreatePrimaryAdmin.ps1`; `/TR` contains no password or other secret arguments.
* [ ] On `schtasks /Create` error:

  * [ ] RC is tracked via `track_rc`.
  * [ ] `[ERROR] Failed to create scheduled task ...` is logged.
  * [ ] `FAILED=1` is set.
  * [ ] No Winlogon autologon values are written in that run (no `DefaultUserName`/`DefaultDomainName`/`DefaultPassword` and no `AutoAdminLogon`/`ForceAutoLogon`/`AutoLogonCount` changes).
  * [ ] Negative test: force `schtasks /Create` to fail, verify Winlogon autologon values are not written and `STAGEB_NOT_SCHEDULED=1` is set.
* [ ] In the blocked branch:

  * [ ] The log records that Stage B registration was skipped, with explicit `FAILED` and `HAS_BOOTSTRAP_PW` values.

* [ ] When `ALWAYS_REBOOT_AFTER_FIRST_LOGON==1`:

  * [ ] `NEEDS_REBOOT=1` is set.
  * [ ] Only `call :flag_reboot` is invoked.
* [ ] In the central RC handling:

  * [ ] When RC ∈ {3010, 1641}, `NEEDS_REBOOT=1` is set.
* [ ] When `NEEDS_REBOOT==1`:

  * [ ] `[INFO] Reboot required` is logged.
  * [ ] `:flag_reboot` creates `%REBOOT_FLAG%` (`%WINDIR%\Panther\_needs_reboot.flag`) with predictable content (for example `need-reboot`).
  * [ ] If `%REBOOT_FLAG%` already exists at SetupComplete start, a WARN is logged and the flag is preserved as a sticky marker; later, if `NEEDS_REBOOT` is still `0` but the flag exists, `NEEDS_REBOOT` is set to `1` so the flag is re-written during the final evaluation.
* [ ] If `STAGEB_NOT_SCHEDULED==1` when the flag is written, `SetupComplete.log` includes `[WARN] WARN_REBOOT_FLAG_NO_EXECUTOR ...` and SetupComplete writes a standalone `%ProgramData%\l2c_master_<timestamp>.log` entry containing a single `[timestamp] WARN_REBOOT_FLAG_NO_EXECUTOR ...` line for triage.
* [ ] Component cleanup and reboot
  * [ ] No `shutdown.exe` calls are present inside `SetupComplete.cmd`.
  * [ ] When `NEEDS_REBOOT==1`, `[INFO] Reboot required` is logged and `%WINDIR%\Panther\_needs_reboot.flag` is created with predictable content.
  * [ ] Stage B evaluates the tri-state pending reboot probe when the flag exists in normal mode; it reboots on `true`/`unknown` and clears a stale flag without reboot on `false`.
  * [ ] In recovery mode or when Stage B fails, the flag is left in place as a marker for manual follow-up and no automatic reboot is triggered by Stage B.

#### 4.5. Edge first run experience

* [ ] `HKLM\SOFTWARE\Policies\Microsoft\Edge\HideFirstRunExperience` exists and equals `1`.
* [ ] On the first login as the primary admin, launching Edge does not display the interactive first-run wizard.

---

### 5. CreatePrimaryAdmin.ps1 (Stage A: primary admin creation)

#### 5.1. Initialization and logging

* [ ] At the top:

  * [ ] `Set-StrictMode`, `$ErrorActionPreference = 'Stop'`.
  * [ ] `$LogPath` and `$MasterLogPath` are defined.
  * [ ] The directory for `$MasterLogPath` is created up front (Try/Catch, fails quietly on error).
* [ ] Logical initialization:

  * [ ] `$rc = 0`, `$StageA_Succeeded = $false`, `$StageA_RC = 0`, `$StageAAbortReason = $null`.
  * [ ] Log entry `"Begin A: Primary admin creation/config"` is written.

#### 5.2. Parameter handling and password source

* [ ] If `-RollbackOnly` is specified:

  * [ ] Stage A is skipped but considered successful.
  * [ ] `$StageA_Succeeded = $true`, `$StageA_RC = 0`.
* [ ] Stage A reads `%WINDIR%\Setup\Scripts\.primaryadmin.pw` under SYSTEM (UTF-8, first line only) as the required password source; no password is accepted via parameters or alternate files.
* [ ] If the secret is missing, unreadable, empty, or fails validation:

  * [ ] `$StageAAbortReason` is set to a clear description.
  * [ ] A controlled exception is thrown (`throw`), not `exit`.
* [ ] Any password generation paths (if still present) do not contradict the concept:

  * [ ] Either generation is removed, or clearly documented without bypassing the `.primaryadmin.pw` requirement.

#### 5.3. User and group creation/update

* [ ] User existence check:

  * [ ] `Get-LocalUserExists` is logically correct and handles all errors.
* [ ] If the user does not exist:

  * [ ] The user is created via `New-LocalUser` with the password `SecureString`.
  * [ ] Logs record success or failure of creation.
* [ ] If the user exists:

  * [ ] The password is updated using the secret from `.primaryadmin.pw` via `Set-LocalUser -Password` (SecureString).
  * [ ] The user is enabled via `Enable-LocalUser`.
  * [ ] Best-effort: “must change password at next logon” is cleared for pre-existing users via `net.exe user <user> /logonpasswordchg:no` (WARN-only on failure).
* [ ] Property updates via `New-LocalUser` / `Set-LocalUser`:

  * [ ] Correctly handle `FullName`, `Description`, `PasswordNeverExpires`.
* [ ] Membership in `Administrators`:

  * [ ] Ensured via `Ensure-InAdministrators` (no `Get-LocalGroupMember` enumeration).
  * [ ] Verification uses bounded repeat `Add-LocalGroupMember` idempotency (already-member / MemberExists condition, Win32 1378).
  * [ ] Ensure-step code semantics: `Ensure-InAdministrators` returns 1378 for already-member/no-change (Stage A logs `A: SKIP (already member)`), returns 0 when ensured/verified; Stage A overall success still ends with `End A (SUCCESS, RC=0)` when no other errors occur.
* [ ] Membership in `Remote Desktop Users`:

  * [ ] Controlled by `-AddToRemoteDesktopUsers`.
* [ ] On successful Stage A completion:

  * [ ] `$StageA_Succeeded = $true`, `$StageA_RC = 0`.

#### 5.4. Stage A error handling

* [ ] In `catch`:

  * [ ] If `$StageA_RC` is still 0, it is set to 1.
  * [ ] If `$StageAAbortReason` is empty, it receives `$_ .Exception.Message`.
  * [ ] Log entry `"Stage A failed: ..."` is written with `ERROR` level.
  * [ ] `$StageA_Succeeded = $false`.
  * [ ] `$rc = 1`.

#### 5.5. Primary admin LocalAccounts preflight failure (negative test)

* [ ] On a test VM, run `CreatePrimaryAdmin.ps1` under 32-bit PowerShell (for example `C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe`) so Stage A preflight fails.
* [ ] `SetupComplete.log` shows:

  * [ ] Stage A loading `.primaryadmin.pw` (`Primary admin secret loaded from .primaryadmin.pw`).
  * [ ] An error `Stage A requires 64-bit PowerShell process (Is64BitProcess=false)`.
  * [ ] `Stage A failed: ...` followed by `Stage B running in recovery mode (StageA RC=1)` and recovery logs noting secrets/`bootstrap` preserved and outcome `ABORTED` with the preflight failure reason.
* [ ] `C:\ProgramData\l2c_master_*.log` shows:

  * [ ] `mode=recovery`.
  * [ ] `.primaryadmin.pw` and `.bootstrap.pw` cleanup states recorded as preserved.
  * [ ] OUTCOME stating the run was aborted because Stage A preflight failed.
* [ ] VM state after the failed run:

  * [ ] `bootstrap` remains enabled for operator investigation.

---

### 6. CreatePrimaryAdmin.ps1 (Stage B: cleanup, reboot, master log)

#### 6.1. Normal and recovery modes

* [ ] `$isRecovery = -not $StageA_Succeeded`.
* [ ] Logging:

  * [ ] In recovery: `"Stage B running in recovery mode (StageA RC=...)"` with `WARN` level.
  * [ ] In normal mode: `"Begin B: Autologon cleanup & policy restore"`.

#### 6.2. Winlogon and logon policies

* [ ] Always (in both normal and recovery):

  * [ ] Logging for Winlogon reset is two-phase and truthful:
    * [ ] `Winlogon and logon policy reset: begin`
    * [ ] `Winlogon and logon policy reset: attempted` (may include an `(wlRcs=...)` suffix only when any effective RC is outside `{0,2}`)
    * [ ] `Winlogon cleanup verification passed (reset verified)` is emitted only when verification genuinely succeeded (never on failure/recovery paths).
  * [ ] `wlRcs` is based on effective RCs (the script’s interpreted return codes after idempotence and AccessDenied handling), not raw `reg.exe` return codes; when `$VerboseLog` is enabled and any operation has `Raw` ≠ `Effective`, the script emits a DEBUG `Winlogon reset rc detail: raw=... effective=...` line to aid diagnosis.
  * [ ] `DefaultUserName` and `DefaultDomainName` are cleared; `DefaultPassword` is removed (absent).
  * [ ] `AutoAdminLogon`, `ForceAutoLogon`, and `AutoLogonCount` are absent or `0`.
  * [ ] A post-action verification reads `HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon` and treats read errors as failures; if `DefaultPassword` is present or any autologon value is present and not `0`, Stage B hard-fails and refuses to disable `bootstrap` or delete `\L2C\CreatePrimaryAdmin` (and suppresses any automatic reboot).
  * [ ] `IgnoreShiftOverride` is set to `REG_SZ=0`.
  * [ ] `DisableCAD` is set to `0`.
* [ ] Additionally:

  * [ ] In the **normal** path, `DevicePasswordLessBuildVersion` is set back to `2`.
  * [ ] In the **recovery** path, `DevicePasswordLessBuildVersion` is intentionally kept at `0`, and this is logged as a diagnostic (lab / recovery) state instead of a fully "production ready" one.

#### 6.3. `bootstrap` account and CreatePrimaryAdmin task

* [ ] In normal mode:

  * [ ] `net user bootstrap /active:no` is called with RC checking.
  * [ ] The result is logged (success or warning).
  * [ ] The `\L2C\CreatePrimaryAdmin` task is deleted via `schtasks /Delete`, result logged.
* [ ] In recovery mode:

  * [ ] The `bootstrap` account remains active and the task is not deleted.
  * [ ] The log contains a clear entry that `bootstrap` and the task are preserved for manual intervention, as described in SECURITY.md.

#### 6.5. Password source files cleanup (normal vs recovery)

* [ ] In normal Stage B mode:

  * [ ] Both `.bootstrap.pw` and `.primaryadmin.pw` are processed for cleanup when present; the script attempts to delete them only when Winlogon cleanup verification succeeded (`WinlogonSanitizedOk=$true`) and records a cleanup state (`removed`, `missing`, `error`, or `preserved`) for each.
  * [ ] Cleanup states (`removed`, `missing`, `error`, `preserved`) for each file are recorded in the master log.
  * [ ] In the happy path, the most recent master log shows `bootstrap.pw cleanup state=removed` and `primaryadmin.pw cleanup state=removed`.
  * [ ] Any `cleanup state=error` is treated as an audit finding requiring follow-up to confirm secrets are not left on disk.
  * [ ] Any cleanup state `error` for either secret triggers the secret cleanup failure branch: `OUTCOME: FAIL - secret cleanup error ...`, `StageB_Succeeded=$false`, and (when `$rc` was `0`) `rc` is set to `3`.
* [ ] In recovery mode:

  * [ ] Both secrets are intentionally preserved for another Stage A attempt.
  * [ ] Logs clearly mark that secrets were preserved (for example, `Recovery mode: preserving bootstrap.pw and primaryadmin.pw for another Stage A attempt`) and therefore remain on disk until a later successful Stage B cleanup or operator removal.

#### 6.6. Master log (l2c_master_*.log) and OUTCOME

* [ ] Master log:

  * [ ] Created in `%ProgramData%` with a fixed name pattern and timestamp.
  * [ ] Written using `UTF8Encoding($false)` (no BOM).
* [ ] The master log contains:

  * [ ] Stage B start with the mode label (normal or recovery).
  * [ ] Key steps (Winlogon reset, `.bootstrap.pw` cleanup).
  * [ ] Stage B completion (`finalize end`).
* [ ] OUTCOME line:

  * [ ] Formed in one of three formats: `SUCCESS`, `FAIL`, or `ABORTED` with a reason.
  * [ ] Written to the same file in the same encoding.
  * [ ] Logged via `Write-SetupLog` with `INFO` or `ERROR` level depending on the outcome.
  * [ ] Secret cleanup error case emits `OUTCOME: FAIL - secret cleanup error (bootstrap/primaryadmin secrets not removed)`, logs `End B (FAIL - secret cleanup error)` at `ERROR` level, sets `StageB_Succeeded=$false`, and returns `rc=3` when no previous failure code was set.
* [ ] If Stage B fails before finalization:

  * [ ] The master log still receives at least one line indicating an early FAIL.
  * [ ] OUTCOME: FAIL is recorded both in the master log and in SetupComplete.log.
* [ ] For recovery cases:

  * [ ] OUTCOME in the master log and SetupComplete.log clearly indicates that the system requires manual intervention and is not treated as a "successful installation".

#### 6.7. Reboot via Panther flag

* [ ] Panther flag:

  * [ ] `$flag = Join-Path $env:WINDIR 'Panther\_needs_reboot.flag'`.
  * [ ] If the flag exists and Stage B completed successfully in normal mode:

    * [ ] Stage B runs the tri-state pending reboot probe and logs `Pending reboot check: state=<true|false|unknown> reasons=<...> errors=<...>`.
    * [ ] `state=true` → log the reboot action, remove the flag, and call `shutdown.exe /r /t 0`.
    * [ ] `state=false` → log that the flag is stale, remove the flag, and do not reboot.
    * [ ] `state=unknown` → log WARN about probe errors, remove the flag, and reboot conservatively with `shutdown.exe /r /t 0`.
    * [ ] Tri-state probe sources: CBS markers, Windows Update markers, Session Manager `PendingFileRenameOperations`/`PendingFileRenameOperations2`, and `HKLM:\SOFTWARE\Microsoft\Updates\UpdateExeVolatile`.
    * [ ] State precedence: `true` if any reasons exist even if probe errors exist; `unknown` only if no reasons but probe errors exist; `false` only if no reasons and no errors.

  * [ ] If the flag exists but Stage B ran in recovery mode:

    * [ ] No automatic reboot is performed; instead a warning is logged that a reboot may be required.
    * [ ] The script does not delete the flag automatically in recovery mode.

  * [ ] If Stage B fails (non-zero return code), regardless of mode:

    * [ ] No automatic reboot is performed, even if the Panther flag exists (including secret cleanup errors that keep `StageB_Succeeded=$false`).
    * [ ] The log clearly records that the reboot was suppressed because Stage B failed.
  * [ ] The master log records the Panther flag state before the Stage B decision and a clear action line for each outcome:
    * [ ] `Stage B: Panther reboot flag consumed, initiating automatic restart` (`state=true`).
    * [ ] `Stage B: Panther reboot flag stale (no pending reboot indicators); clearing flag without reboot` (`state=false`).
    * [ ] `Stage B: Panther reboot flag consumed (pending=unknown due to probe errors); policy=conservative reboot; initiating automatic restart` (`state=unknown`).
    * [ ] Or a suppression variant (`StageB_Succeeded=false` or `recovery mode`) when no reboot is allowed.

* [ ] Stage B never triggers an automatic reboot unless Stage B itself succeeded; reboot logic is explicitly gated on Stage B success.

---

### 7. Documentation vs actual code

For each document:

#### 7.1. README.md

* [ ] Pipeline description:

  * [ ] PreOOBE → BootstrapLocalAdmin → SetupComplete → CreatePrimaryAdmin (Stage A/B).
* [ ] Reboot mechanism:

  * [ ] Only the Panther flag and Stage B are mentioned.
* [ ] Behavior is described for:

  * [ ] RC 0 (no reboot).
  * [ ] RC 3010/1641 (reboot required).
  * [ ] `ALWAYS_REBOOT_AFTER_FIRST_LOGON`.
* [ ] Stage B description:

  * [ ] Stage B is always run (normal or recovery), or any deviation is clearly described.
  * [ ] Matches the actual code.

#### 7.2. DECISIONS.md

* [ ] All decisions regarding:

  * [ ] Using the Panther flag.
  * [ ] Calling Stage B when Stage A fails (recovery mode).
  * [ ] Policy of "no reboots inside SetupComplete".
* [ ] Tables and state diagrams match the real behavior of the scripts.

#### 7.3. AGENTS.md

* [ ] Roles are described:

  * [ ] Owner, ChatGPT, Codex, CI.
* [ ] Contracts are defined for:

  * [ ] Codex CLI (minimal diffs, EOL, quoting rules, and so on).
  * [ ] SetupComplete and CreatePrimaryAdmin behavior (in brief).
* [ ] The description of how Stage B processes the Panther flag and performs cleanup matches the code.

#### 7.4. SECURITY.md

* [ ] Risks and mitigations are documented for:

  * [ ] `.bootstrap.pw` (creation, storage, deletion).
  * [ ] Winlogon autologon and the all-or-nothing model.
  * [ ] Temporary `bootstrap` account and its role in normal and recovery modes.
* [ ] The text explicitly reflects:

  * [ ] What happens when Stage A fails (recovery mode).
  * [ ] That Stage B in recovery mode does not perform automatic reboot and does not delete the Panther flag; it logs the flag and leaves it in place for operator follow-up.
  * [ ] Differences between normal and recovery regarding `DevicePasswordLessBuildVersion`, `bootstrap` status, and the `\L2C\CreatePrimaryAdmin` task.

#### 7.5. CONTRIBUTING.md

* [ ] Contains guidance on:

  * [ ] EOL and encodings.
  * [ ] How to run tests (VM, scripts).
  * [ ] How to use Codex and CI for validation.
* [ ] All links to files and sections are current and not broken.

---

### 8. Resilience and failure scenarios

* [ ] When `.bootstrap.pw` is missing at the `SetupComplete` stage:

  * [ ] Autologon is not configured.
  * [ ] Stage B is not registered (`schtasks /Query /TN "\L2C\CreatePrimaryAdmin"` fails) and `primaryadmin` is not created.
  * [ ] Logs contain a clear ERROR so that the operator immediately sees what to investigate.
* [ ] When `.primaryadmin.pw` is missing or invalid at the `SetupComplete` stage:

  * [ ] A clear ERROR is logged.
  * [ ] Autologon priming is not configured.
  * [ ] Stage B is not registered (`schtasks /Query /TN "\L2C\CreatePrimaryAdmin"` fails) and `primaryadmin` is not created.
  * [ ] The state clearly indicates that manual intervention is required.
  * [ ] `SetupComplete.log` ends with a non-zero `[RC] returning ...` when the failure is only the closed gate (`FAILED==1` with no captured fatal servicing RC) (observed: `returning 1`).
* [ ] When `.bootstrap.pw` is valid, but Stage A fails (for example LocalAccounts preflight failure, user provisioning failure, and so on):

  * [ ] Stage B runs in recovery mode.
  * [ ] Autologon and logon policies are reset.
  * [ ] The Panther flag is processed correctly with recovery restrictions (logged, not deleted, no reboot).
  * [ ] The master log and SetupComplete.log contain enough information for diagnostics.
* [ ] When Stage B fails:

  * [ ] No uncontrolled reboot occurs.
  * [ ] Logs clearly describe where and what failed.
  * [ ] The master log records FAIL with a reason.
* [ ] `%WINDIR%\Setup\Scripts\.bootstrap.pw` and `.primaryadmin.pw` do not exist on the normal success path; if they are present, you are either in a recovery scenario, after a Winlogon cleanup verification failure, or running the master manually (see README for expected behavior).
* [ ] FINAL_RC aggregation matches behavior: `L2C_FIRST_BAD_RC` wins if present; otherwise `FINAL_RC=1` when `FAILED==1`, else `0`.

---

### 9. CI, git flow, and Codex interaction

* [ ] Any script changes do not break:

  * [ ] EOL guards in CI.
  * [ ] Encoding checks (if present).
* [ ] Commits related to bootstrap, Stage A/B, or reboot:

  * [ ] Have meaningful messages (context, what and why changed).
* [ ] All prompts for Codex CLI:

  * [ ] Explicitly forbid changing EOL and BOM outside of targeted files or hunks.
  * [ ] Require minimal diffs and clear change reports.
  * [ ] Do not initiate actions outside the agreed file list.

### Additional DISM/RC validation

* [ ] `SetupComplete.log` shows `[RC] returning 0` for a passing run. For failing runs, non-zero values must match the `FINAL_RC` rules and the first fatal RC captured in `L2C_FIRST_BAD_RC`.
* [ ] DISM warnings related to missing/not-applicable components on LTSC (whitelisted RCs such as `-2146498548/2148468748` and `-2146498541/2148468755`) are documented as acceptable; any DISM return codes outside `{0, 3010, 1641}` and this warning whitelist must be treated as audit failures and must correspond to a non-zero `FINAL_RC`.
* [ ] Capability probes use `dism /Online /Get-CapabilityInfo /CapabilityName:<cap> /English` with output captured to a temp file; no `dism | findstr` pipelines are used for capability decisions (the raw DISM return code must be preserved for classification).
* [ ] When the probe output lacks a parsable `State :` line, `SetupComplete.cmd` logs a WARN and skips capability removal (no hard-fail is triggered solely by missing state).
* [ ] When a capability probe produces a fatal DISM return code and sets `DISM_HARD_FAIL=1`, `SetupComplete.log` contains an ERROR for that capability probe and WARN entries for subsequent capabilities being skipped due to the prior fatal DISM RC.
