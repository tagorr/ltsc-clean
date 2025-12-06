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
S
### 1.1. Unattended setup UX (image selection & EULA)

* [ ] Installer skips the edition picker (LTSC vs LTSC N) because the answer file selects the OS by `/IMAGE/INDEX=1` in `windowsPE`.
* [ ] License terms / EULA screen does not appear during unattended install because `<UserData><AcceptEula>true</AcceptEula>` is set in `Autounattend.xml`.

---

### 2. Password source files lifecycle (`.bootstrap.pw` and `.primaryadmin.pw`)

* [ ] Documentation (README, DECISIONS, AGENTS, SECURITY) describes:

  * [ ] Where exactly `.bootstrap.pw` is created (`%WINDIR%\Setup\Scripts`), who reads it, and when it must be deleted or preserved (normal vs recovery).
  * [ ] Where `.primaryadmin.pw` is expected to exist (`%WINDIR%\Setup\Scripts`), that it is operator-supplied, who reads it (`SetupComplete.cmd` and Stage A), and when it is deleted or preserved (normal vs recovery).
* [ ] In `BootstrapLocalAdmin.ps1`:

  * [ ] `.bootstrap.pw` is created at the expected path (`%WINDIR%\Setup\Scripts\.bootstrap.pw`).
  * [ ] Content is a single non-empty line (UTF-8 without BOM).
  * [ ] File ACL is restricted (SYSTEM + Administrators only), inheritance disabled, Hidden + System attributes set.
* [ ] In `SetupComplete.cmd`:

  * [ ] `ValidateSecrets.ps1` is invoked near the start with both secret paths, does not read passwords, and returns a 0–3 exit-code bitmask (bit0=bootstrap, bit1=primary admin) that is decoded from `%ERRORLEVEL%` into `L2C_BOOTSTRAP_PW_ACL_OK` and `L2C_PRIMARYADMIN_PW_ACL_OK`, then logged as `[SECTION] Secret ACL validation (bootstrap=..., primaryadmin=...)`.
  * [ ] There is a check for the existence of `.bootstrap.pw` and that the file is not empty (at least one non-empty line).
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
  * [ ] A single combined gate (FAILED==0, `.bootstrap.pw` present/non-empty, `.primaryadmin.pw` present and ACL/attribute OK, allowed characters) controls temporary logon tweaks, autologon priming, and Stage B registration.
  * [ ] For a happy-path run, `SetupComplete.log` shows `[SECTION] Secret ACL validation (bootstrap=1, primaryadmin=1)` before CreatePrimaryAdmin is scheduled; for a deliberate ACL/attribute/absence fault in either secret the log shows at least one `0` and SetupComplete enters the fail-closed/recovery path (no task registration or autologon priming).
* [ ] In `CreatePrimaryAdmin.ps1`:

  * [ ] Stage A reads `%WINDIR%\Setup\Scripts\.primaryadmin.pw` under SYSTEM as its only password source (no `.bootstrap.pw`, no command-line password arguments).
  * [ ] Password application uses the WinNT ADSI provider (`SetPassword` + `SetInfo`); any `net.exe user` calls for `primaryadmin` are limited to `/add` or `/active:yes` with no password arguments.
  * [ ] Behavior is defined for:

    * [ ] Missing, unreadable, or empty `.primaryadmin.pw`.
    * [ ] Read/validation errors surfaced from `.primaryadmin.pw` (ACL, IO, invalid characters).
  * [ ] In case of secret-related problems:

    * [ ] A clear `StageAAbortReason` is set.
    * [ ] Stage A does not attempt to create or modify the user with an invalid or missing password.
    * [ ] Stage B still performs the required cleanup (according to the normal/recovery policy).
  * [ ] For `primaryadmin`, the password value never appears in task XML, command lines, or the baseline's own logs.
  * [ ] With Audit Process Creation + command-line logging enabled, Security 4688 events do not show the `primaryadmin` password on any process command line.

---

### 3. PreOOBE / BootstrapLocalAdmin (Stage 0)

* [ ] `PreOOBE.cmd`:

  * [ ] Launches `BootstrapLocalAdmin.ps1` in the expected way.
  * [ ] Does not modify Winlogon, RunOnce, or logon policies if this is forbidden by design.
  * [ ] Redirects stdout and stderr from `BootstrapLocalAdmin.ps1` into `%WINDIR%\Panther\PreOOBE.log` (no separate bootstrap log file).
* [ ] `BootstrapLocalAdmin.ps1`:

  * [ ] Creates a temporary `bootstrap` account with minimal required rights where applicable.
  * [ ] Sets or updates the password using only expected commands (PowerShell or `net.exe`).
  * [ ] Marks `bootstrap` as active (`/active:yes`) if required by the scenario.
  * [ ] Emits `[BOOTSTRAP] [INFO|WARN|ERROR] ...` lines in `%WINDIR%\Panther\PreOOBE.log` for key lifecycle steps (account creation, password set/activate, Administrators membership, `.bootstrap.pw` write/ACL/attributes).
  * [ ] Bootstrap log entries do not include the password or derived secret values (technical actions/errors only).
  * [ ] Does not leave extra handlers or resources (including RunOnce entries or tasks that are not described in the design).

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
  * [ ] Inside the loop, non-empty lines are checked.
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
  * [ ] Follows an all-or-nothing model: `SetupComplete.cmd` first writes `DefaultPassword` and checks the RC, and only when RC=0 enables `AutoAdminLogon` and `ForceAutoLogon`.
  * [ ] If writing the password fails, autologon remains disabled, an `[ERROR]` is logged, `FAILED=1` is set, and Stage B is not registered.
  * [ ] Temporary logon policy relaxations (`DisableCAD`, `DevicePasswordLessBuildVersion`) occur only when the combined gate passes; skip path logs the gate state.

#### 4.3. CreatePrimaryAdmin task registration (Stage B)

* [ ] Creation of the `\L2C\CreatePrimaryAdmin` task:

  * [ ] Happens only when `FAILED==0`, `HAS_BOOTSTRAP_PW==1`, and a validated primary admin secret is present.
  * [ ] Task parameters: SYSTEM, Highest, OnLogon, path to `CreatePrimaryAdmin.ps1`; `/TR` contains no password or other secret arguments.
* [ ] On `schtasks /Create` error:

  * [ ] RC is tracked via `track_rc`.
  * [ ] `[ERROR] Failed to create scheduled task ...` is logged.
  * [ ] `FAILED=1` is set.
* [ ] In the blocked branch:

  * [ ] The log records that Stage B registration was skipped, with explicit `FAILED` and `HAS_BOOTSTRAP_PW` values.

#### 4.4. Reboot flow (Panther flag, no RunOnce)

* [ ] All code that used to write `shutdown.exe` into RunOnce has been removed.
* [ ] When `ALWAYS_REBOOT_AFTER_FIRST_LOGON==1`:

  * [ ] `NEEDS_REBOOT=1` is set.
  * [ ] Only `call :flag_reboot` is invoked.
* [ ] In the central RC handling:

  * [ ] When RC ∈ {3010, 1641}, `NEEDS_REBOOT=1` is set.
* [ ] When `NEEDS_REBOOT==1`:

  * [ ] `[INFO] Reboot required` is logged.
  * [ ] `:flag_reboot` creates `%REBOOT_FLAG%` (`%WINDIR%\Panther\_needs_reboot.flag`) with predictable content (for example `need-reboot`).
* [ ] Component cleanup and reboot
  * [ ] No `shutdown.exe` calls are present inside `SetupComplete.cmd`.
  * [ ] When `NEEDS_REBOOT==1`, `[INFO] Reboot required` is logged and `%WINDIR%\Panther\_needs_reboot.flag` is created with predictable content.
  * [ ] Stage B of `CreatePrimaryAdmin.ps1` consumes the Panther flag on the normal path and performs at most one controlled reboot when the flag exists.
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

  * [ ] `net user ... /add` and `/active:yes` run in sequence.
  * [ ] `net.exe` errors are checked via `$LASTEXITCODE`.
  * [ ] Logs record success or failure of creation and activation.
* [ ] If the user exists:

  * [ ] The password is updated using the secret from `.primaryadmin.pw`, errors are logged, and RCs are checked.
  * [ ] Finally the user is activated (`/active:yes`) with RC checking.
* [ ] Property updates via `Set-UserAdsi`:

  * [ ] Correctly handle `FullName`, `Description`, `PasswordNeverExpires`.
* [ ] Membership in `Administrators`:

  * [ ] Checked by `Test-AdministratorsMembership`.
  * [ ] Added via `Ensure-InAdministrators`, with meaningful RC handling (including "already a member").
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

---

### 6. CreatePrimaryAdmin.ps1 (Stage B: cleanup, reboot, master log)

#### 6.1. Normal and recovery modes

* [ ] `$isRecovery = -not $StageA_Succeeded`.
* [ ] Logging:

  * [ ] In recovery: `"Stage B running in recovery mode (StageA RC=...)"` with `WARN` level.
  * [ ] In normal mode: `"Begin B: Autologon cleanup & policy restore"`.

#### 6.2. Winlogon and logon policies

* [ ] Always (in both normal and recovery):

  * [ ] `DefaultUserName`, `DefaultDomainName`, and `DefaultPassword` are cleared.
  * [ ] `AutoAdminLogon=0`, `ForceAutoLogon=0`, `AutoLogonCount=0`.
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

#### 6.4. RunOnce cleanup (lab leftovers)

* [ ] Always (in both modes):

  * [ ] Enumerates `HKLM:\...\RunOnce` and removes values related to L2C / CreatePrimaryAdmin / diagnostic helpers (lab leftovers).
  * [ ] Optionally calls `reg.exe DELETE ... /v <lab-helper> /f` as a defensive measure.
  * [ ] All errors are logged as `WARN` but do not break Stage B.
  * [ ] Logs contain a `"RunOnce cleaned"` entry or an explanation of the error.

#### 6.5. Password source files cleanup (best effort)

* [ ] In normal Stage B mode:

  * [ ] Both `.bootstrap.pw` and `.primaryadmin.pw` are deleted when present; success or failure is logged for each.
  * [ ] Cleanup states (`removed`, `missing`, `error`) for each file are recorded in the master log.
* [ ] In recovery mode:

  * [ ] Both secrets are intentionally preserved for another Stage A attempt.
  * [ ] Logs clearly mark that secrets were preserved and that manual cleanup is required after recovery.

#### 6.6. Master log (l2c_master_*.log) and OUTCOME

* [ ] Master log:

  * [ ] Created in `%ProgramData%` with a fixed name pattern and timestamp.
  * [ ] Written using `UTF8Encoding($false)` (no BOM).
* [ ] The master log contains:

  * [ ] Stage B start with the mode label (normal or recovery).
  * [ ] Key steps (Winlogon reset, RunOnce cleanup, `.bootstrap.pw` cleanup).
  * [ ] Stage B completion (`finalize end`).
* [ ] OUTCOME line:

  * [ ] Formed in one of three formats: `SUCCESS`, `FAIL`, or `ABORTED` with a reason.
  * [ ] Written to the same file in the same encoding.
  * [ ] Logged via `Write-SetupLog` with `INFO` or `ERROR` level depending on the outcome.
* [ ] If Stage B fails before finalization:

  * [ ] The master log still receives at least one line indicating an early FAIL.
  * [ ] OUTCOME: FAIL is recorded both in the master log and in SetupComplete.log.
* [ ] For recovery cases:

  * [ ] OUTCOME in the master log and SetupComplete.log clearly indicates that the system requires manual intervention and is not treated as a "successful installation".

#### 6.7. Reboot via Panther flag

* [ ] Panther flag:

  * [ ] `$flag = Join-Path $env:WINDIR 'Panther\_needs_reboot.flag'`.
  * [ ] If the flag exists and Stage B completed successfully in normal mode:

    * [ ] A reboot is performed via `shutdown.exe /r /t 0`, the action is logged, and the flag is deleted.

  * [ ] If the flag exists but Stage B ran in recovery mode:

    * [ ] No automatic reboot is performed; instead a warning is logged that a reboot may be required.
    * [ ] The script does not delete the flag automatically in recovery mode.

  * [ ] If Stage B fails (non-zero return code), regardless of mode:

    * [ ] No automatic reboot is performed, even if the Panther flag exists.
    * [ ] The log clearly records that the reboot was suppressed because Stage B failed.

* [ ] Stage B never triggers an automatic reboot unless Stage B itself succeeded; reboot logic is explicitly gated on Stage B success.

---

### 7. Documentation vs actual code

For each document:

#### 7.1. README.md

* [ ] Pipeline description:

  * [ ] PreOOBE → BootstrapLocalAdmin → SetupComplete → CreatePrimaryAdmin (Stage A/B).
* [ ] Reboot mechanism:

  * [ ] Only the Panther flag and Stage B are mentioned, not RunOnce.
* [ ] Behavior is described for:

  * [ ] RC 0 (no reboot).
  * [ ] RC 3010/1641 (reboot required).
  * [ ] `ALWAYS_REBOOT_AFTER_FIRST_LOGON`.
* [ ] Stage B description:

  * [ ] Stage B is always run (normal or recovery), or any deviation is clearly described.
  * [ ] Matches the actual code.

#### 7.2. DECISIONS.md

* [ ] All decisions regarding:

  * [ ] Using the Panther flag instead of RunOnce.
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
  * [ ] Stage B is not registered.
  * [ ] Logs contain a clear ERROR so that the operator immediately sees what to investigate.
* [ ] When `.primaryadmin.pw` is missing or invalid at the `SetupComplete` stage:

  * [ ] A clear ERROR is logged.
  * [ ] Autologon priming is not configured.
  * [ ] Stage B is not registered.
  * [ ] The state clearly indicates that manual intervention is required.
* [ ] When `.bootstrap.pw` is valid, but Stage A fails (for example `net.exe` error, ACL issue, and so on):

  * [ ] Stage B runs in recovery mode.
  * [ ] Autologon and logon policies are reset.
  * [ ] The Panther flag is processed correctly with recovery restrictions (logged, not deleted, no reboot).
  * [ ] The master log and SetupComplete.log contain enough information for diagnostics.
* [ ] When Stage B fails:

  * [ ] No uncontrolled reboot occurs.
  * [ ] Logs clearly describe where and what failed.
  * [ ] The master log records FAIL with a reason.
* [ ] `%WINDIR%\Setup\Scripts\.bootstrap.pw` and `.primaryadmin.pw` do not exist on the normal path; if they are present, you are either in a recovery scenario or running the master manually (see README for expected behavior).
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
