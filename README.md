# Windows 10 LTSC 2021 - Clean & Quiet Baseline (Official Tools Only)

A lean, predictable Windows 10 LTSC 2021 baseline with minimal background activity and telemetry. Uses official Microsoft mechanisms only (Policies/Registry, DISM Features & Capabilities, Scheduled Tasks). Conservative, no hacks; deterministic and idempotent. Includes `PreOOBE.cmd`, `SetupComplete.cmd`, `BootstrapLocalAdmin.ps1` and `CreatePrimaryAdmin.ps1`.

## Scope

- Harden Windows 10 LTSC 2021 using supported policies and servicing only, no unofficial binaries or hacks.
- Provide deterministic automation via `PreOOBE.cmd`, `SetupComplete.cmd`, `BootstrapLocalAdmin.ps1`, and `CreatePrimaryAdmin.ps1` with single-pass logging.
- Expect operators to supply deployment assets (media, `autounattend.xml`) separately; this repo tracks the scripts, decisions, and documentation only.

## Supported SKUs / Requirements

> This baseline is intended for Windows 10 Enterprise LTSC 2021 (EnterpriseS) or compatible Enterprise SKUs.  
> Rationale: the diagnostic data level `AllowTelemetry=0` ("Security") is supported on Enterprise tiers; on non-Enterprise editions the minimum effective level may be higher and behavior may differ.

- Windows 10 Enterprise LTSC 2021 (21H2, EditionID = EnterpriseS, build 19044+)
- No corporate integration required

## Files in this repo

- `PreOOBE.cmd` - specialize-phase privacy policies and bootstrap trigger
- `SetupComplete.cmd` - post-install baseline script (post-OOBE hardening, Panther flag handling, autologon priming)
- `BootstrapLocalAdmin.ps1` - temporary admin creation and bootstrap secret writer (`.bootstrap.pw`), no direct Winlogon or RunOnce manipulation
- `CreatePrimaryAdmin.ps1` - first-login master that finalizes the baseline (Stage A/B, normal vs recovery, controlled reboot)
- `DECISIONS.md` - design decisions and rationale
- `SECURITY.md` - security trade-offs and risk model
- `AGENTS.md` - high-level interaction contracts and agent roles (ChatGPT, Codex CLI, Owner)
- `docs/INTERACTION_CONTRACT.md` - Codex CLI interaction contract (shell choice, quoting rules, safety guardrails)
- `docs/AUDIT_CHECKLIST.md` - end-to-end audit checklist for scripts and documentation
- `CONTRIBUTING.md` - PR rules, PowerShell style, and EOL requirements
- `LICENSE` - MIT

> `autounattend.xml` is maintained in a separate, access-controlled repository and is intentionally not committed here. Follow `DECISIONS.md` §7 for generation and storage guidance.

## Placement

> Pre-OOBE delivery: `PreOOBE.cmd` is embedded into the target OS image (`install.wim`) at  
> `Windows\Setup\Scripts\PreOOBE.cmd`. Unattend (pass `specialize` -> `RunSynchronous`) calls this path inside the deployed OS; it is not read from the installation media.

> Privacy and security policies are applied before OOBE via external `PreOOBE.cmd`, invoked from `autounattend.xml` in pass `specialize` (`Microsoft-Windows-Deployment/RunSynchronous`). The script resides at `%WINDIR%\Setup\Scripts\PreOOBE.cmd` inside the installed OS.

- Put `autounattend.xml` in the root of the installation media.
- Put `SetupComplete.cmd` at:

  ```text
  \sources\$OEM$\$$\Setup\Scripts\SetupComplete.cmd
  ```

* Runtime logs:

  1. `%WINDIR%\Panther\PreOOBE.log` - specialize-phase policies and bootstrap status
  2. `%WINDIR%\Panther\SetupComplete.log` - post-setup baseline run (ISO-8601 timestamps)
  3. `%WINDIR%\Logs\DISM\SetupComplete-DISM.log` - consolidated DISM trace for all servicing actions

### Media layout example

```text
<USB-ROOT>
├─ autounattend.xml
└─ sources
   └─ $OEM$
      └─ $$
         └─ Setup
            └─ Scripts
               └─ SetupComplete.cmd
```

> Note: save `SetupComplete.cmd` as UTF-8 without BOM, with CRLF line endings.

### Image binding (autounattend.xml)

* The answer file targets Index 1 and sets `<cpi:offlineImage name="Windows 10 Enterprise LTSC">`.
* At runtime, Windows Setup selects the image by Index; the `<cpi:offlineImage>` entry is for WSIM validation and self documentation only and does not affect drive letters or media paths.
* If you use another WIM/ESD, update the `name` to exactly match `Get-WindowsImage ... | Select ImageName` output, or remove the `name` attribute and keep `Index=...`.

## Install flow

1. Boot from media with `autounattend.xml`.

2. During pass `specialize`, Windows runs `PreOOBE.cmd` from `%WINDIR%\Setup\Scripts\PreOOBE.cmd`. It applies early privacy and security policies and invokes `BootstrapLocalAdmin.ps1` under SYSTEM. `PreOOBE.cmd` does not touch Winlogon, passwordless, RunOnce, or Task Scheduler.

3. `BootstrapLocalAdmin.ps1` creates the temporary admin account `bootstrap`, assigns a strong password, and writes it to `%WINDIR%\Setup\Scripts\.bootstrap.pw` (UTF-8 no BOM, Hidden+System, ACL: SYSTEM and Administrators). It does not configure autologon and does not schedule the master.

4. After OOBE completes, Windows runs `SetupComplete.cmd` as SYSTEM exactly once. The script:

   * performs baseline servicing and hardening with DISM and registry policies;
   * interprets return codes from servicing: `0` is success; `3010` and `1641` are success with reboot required; anything else is failure (`FAILED=1`);
   * when a reboot is required or `ALWAYS_REBOOT_AFTER_FIRST_LOGON=1` is set, writes `%WINDIR%\Panther\_needs_reboot.flag` instead of rebooting immediately;
   * if `.bootstrap.pw` exists and `FAILED=0`, primes Winlogon autologon for `bootstrap` using the secret from `.bootstrap.pw` and applies temporary logon settings (`DisableCAD=1`, `Ngc\DevicePasswordLessBuildVersion=0`, `IgnoreShiftOverride=0`);
   * creates the scheduled task `\L2C\CreatePrimaryAdmin` (OnLogon, Run as SYSTEM, Run with highest) which will run `CreatePrimaryAdmin.ps1` at the first interactive sign in.
   * if `FAILED=1`, rolls back any temporary logon tweaks to safe values and does not configure autologon or the scheduled task.

5. The system reboots as part of normal Setup. At the first console logon (Hyper-V Basic console), Winlogon performs AutoAdminLogon with `bootstrap`. This is visible only on the console session, not on Hyper-V Enhanced (RDP) sessions.

6. At the first interactive logon, the scheduled task `\L2C\CreatePrimaryAdmin` executes `CreatePrimaryAdmin.ps1` as SYSTEM. The script:

   * runs Stage A to create or update the primary local admin account and group memberships;
   * runs Stage B once after Stage A to roll back temporary logon configuration, disable `bootstrap`, delete the scheduled task and `.bootstrap.pw`, and process the Panther `_needs_reboot.flag`; a controlled reboot only happens when the flag exists and Stage B succeeded in the normal path (recovery mode or Stage B failures do not reboot automatically).

RunOnce is not used by this baseline to start `CreatePrimaryAdmin.ps1` or to drive reboots. Any RunOnce snippets in this repository are strictly for optional lab diagnostics.

## Idempotent master flow (CreatePrimaryAdmin.ps1)

### Group resolution and localization

* Local group names such as Administrators and Remote Desktop Users are resolved from their well known SIDs:

  * `S-1-5-32-544` for the Administrators group
  * `S-1-5-32-555` for the Remote Desktop Users group
* The script initializes:

  * `$script:AdministratorsGroupName`
  * `$script:RemoteDesktopGroupName`
* Resolution is wrapped in `try { ... } catch { ... }`:

  * On success, the script logs real localized group names.
  * On failure, the script logs a WARN entry and falls back to English literals (`Administrators`, `Remote Desktop Users`) so Stage A can still proceed instead of failing at startup.

All places that previously used hard coded English strings now use these resolved variables for `net localgroup`, ADSI group access, and Remote Desktop Users membership.

### Stage A - primary admin creation and setup

* Stage A no longer generates passwords on its own. It uses only explicit secrets:

  * from a parameter like `-PasswordPlain`, or
  * from `%WINDIR%\Setup\Scripts\.bootstrap.pw` in the unattended flow.
* If no valid password is available, Stage A fails fast, logs a clear error, and does not attempt to invent a password.
* Stage A:

  * creates or updates the primary admin account (default name `primaryadmin`);
  * adds the account to the Administrators group using SID based resolution;
  * optionally adds the account to Remote Desktop Users if configured;
  * logs a clear result for Stage A, including return codes and whether membership changes were actually needed.
* Stage A is idempotent. `net.exe localgroup` return code `1378` ("already a member") is treated as success and logged as `A: SKIP (already member)`.

### Stage B - cleanup, Panther flag, normal vs recovery

Stage B always runs once after Stage A. It chooses between a normal path and a recovery path based on Stage A’s outcome and internal validation.

Common work:

* restore Winlogon configuration:

  * clear `DefaultPassword`, `AutoLogonCount`, and other AutoAdminLogon related values;
  * set `AutoAdminLogon=0` and `ForceAutoLogon=0` (REG_SZ);
  * reset `IgnoreShiftOverride` to a safe value;
* reconcile logon related policies:

  * in the normal path, enforce `DisableCAD=0` and `Ngc\DevicePasswordLessBuildVersion=2`;
  * in the recovery path, set `Ngc\DevicePasswordLessBuildVersion=0` to allow a more classic logon experience for diagnostics.

Normal path:

* disables the `bootstrap` account;
* deletes the scheduled task `\L2C\CreatePrimaryAdmin`;
* deletes `%WINDIR%\Setup\Scripts\.bootstrap.pw`;
* removes any leftover `RunOnce` entries added for diagnostics;
* if `%WINDIR%\Panther\_needs_reboot.flag` exists and Stage B completed successfully in normal mode:

  * logs that a reboot is required;
  * deletes the flag before reboot;
  * performs a single controlled reboot via `shutdown.exe /r /t 0`;
* logs an `OUTCOME: Success` entry in the master log in `C:\ProgramData\l2c_master_<timestamp>.log`.

Recovery path:

* keeps `bootstrap` enabled;
* keeps the `\L2C\CreatePrimaryAdmin` scheduled task;
* keeps `.bootstrap.pw` so Stage A can be retried later with the same secret;
* sets `Ngc\DevicePasswordLessBuildVersion=0` and other interactive logon policies so diagnostics can be performed more easily;
* if `_needs_reboot.flag` exists:

  * logs that a reboot had been requested;
  * does not perform an automatic reboot;
  * leaves the flag in place for operator diagnostics;
* logs `OUTCOME: Recovery` with explicit warnings and guidance for manual intervention.

Diagnostics checklist:

* primary admin is present and in Administrators (and Remote Desktop Users if desired);
* `DefaultPassword` and `AutoLogonCount` are absent; `AutoAdminLogon=0` and `ForceAutoLogon=0`;
* `DisableCAD=0` and `DevicePasswordLessBuildVersion=2` in the normal path, `0` in recovery while diagnostics are ongoing;
* `bootstrap` is disabled in the normal path and remains enabled in the recovery path;
* `.bootstrap.pw` has been deleted in the normal path and preserved in recovery;
* in the normal path `_needs_reboot.flag` is cleared after the controlled reboot; in recovery mode or when Stage B fails the flag may remain to signal manual follow-up.

### Bootstrap password source file

* Path: `%WINDIR%\Setup\Scripts\.bootstrap.pw`
* Encoding: UTF-8 without BOM, single line
* ACL: `SYSTEM:(F)`, `Administrators:(F)`
* Attributes: Hidden and System

The file is sensitive. In the normal unattended flow Stage B deletes it on success; if you run the master manually or end up in the recovery path and the file is still present, remove it once you no longer need the bootstrap secret.

### Password generator

* `New-StrongPassword` is retained as a utility function, but Stage A does not use it for `primaryadmin`.
* The character set excludes `&` and `%` to avoid command line quoting issues when a generated password is used in cmd.exe context.

## What this baseline does

> The baseline does not disable `WinHttpAutoProxySvc`. WPAD is controlled via supported WinINET and WinHTTP keys.

* Microsoft Edge controlled via policy (`EdgeUpdate\UpdateDefault=0`, optional `InstallDefault=0`). No uninstall and no scheduler tampering by default.
* SmartScreen off for Explorer and Edge. Windows Defender minimized via supported preferences.
* Diagnostics data level 0; CEIP and WER disabled.
* Delivery Optimization set to mode 0 (HTTP only, no peer to peer).
* Network quieting: WPAD off via WinINET and WinHTTP keys, LLMNR off, Teredo/6to4/ISATAP off.
* OneDrive sync disabled via policy (`DisableFileSyncNGSC=1`). The client is not uninstalled by default.
* Services disabled with guards: SysMain, WSearch, Spooler, DiagTrack, dmwappushsvc, WerSvc, WebClient.
* Features and Capabilities: SMBv1 and PowerShell 2.0 disabled if present; remove Quick Assist, SNMP Client, and WMI SNMP Provider with correct DISM return code handling.
* Windows Update in notify only mode, no drivers, no preview builds, no other Microsoft products, OS upgrade offers blocked.
* Component cleanup with `/ResetBase` to seal the image.

## Post-install quick check

* `%WINDIR%\Panther\SetupComplete.log` exists with no `[ERROR]` entries.
* `netsh winhttp show proxy` reports direct access; no WPAD and no LLMNR.
* Edge and OneDrive are controlled or blocked by policy.
* Windows Update UI shows notify behavior; no drivers or other Microsoft products are auto offered.
* Disabled services remain disabled after reboot.
* DISM capability removals reported success or not applicable.
* `C:\ProgramData\l2c_master_<timestamp>.log` contains an `OUTCOME: Success` entry for the normal path, or a clearly marked `OUTCOME: Recovery` entry when diagnostics are required.

For the full verification list, see `DECISIONS.md` §9 and `docs/AUDIT_CHECKLIST.md` (end-to-end audit checklist for scripts and documentation).

## Troubleshooting: Autologon, master, cleanup

1. Password and autologon

   `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\DefaultPassword` must match the password of the `bootstrap` account. Typos like `Boo...` vs `B00...` will break AutoAdminLogon.

2. Ctrl+Alt+Del

   While bootstrap autologon is primed, the baseline temporarily sets:

   * `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\DisableCAD = 1`

   This is reverted to `0` in the normal Stage B path.

3. Scheduled task presence

   Ensure the scheduled task for the master exists and is configured properly:

   ```cmd
   schtasks /Query /TN "\L2C\CreatePrimaryAdmin"
   ```

   For a manual smoke run:

   ```cmd
   schtasks /Run /TN "\L2C\CreatePrimaryAdmin"
   ```

   The baseline does not use RunOnce to launch `CreatePrimaryAdmin.ps1`.

4. Stage A idempotence

   Return code `1378` from `net localgroup` ("already a member") is normal and should not block the run. The script logs it as a skip.

5. Interpolation bug

   The interpolation bug around `${User}:` vs `$User:` is fixed (see `DECISIONS.md` for the ADR around Stage A and Stage B).

6. RunOnce for diagnostics only

   If you still use `HKLM\...\RunOnce` for an ad hoc diagnostic helper script, ensure it lives under:

   * `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce`

   and not under the Wow6432Node branch. The baseline itself does not depend on RunOnce.

7. Diagnostic launch

   For a one time diagnostic run you can register a helper `.cmd` in `RunOnce` that logs start and finish and calls:

   ```powershell
   CreatePrimaryAdmin.ps1 -Verbose
   ```

   This is diagnostic only. In the unattended baseline `CreatePrimaryAdmin.ps1` is launched solely via the `\L2C\CreatePrimaryAdmin` scheduled task.

### Autologon priming (SetupComplete)

`SetupComplete.cmd` primes Winlogon autologon only when `%WINDIR%\Setup\Scripts\.bootstrap.pw` exists and the script did not fail.

Keys:

* `DefaultUserName = bootstrap`
* `DefaultDomainName = <COMPUTERNAME>`
* `DefaultPassword = <file contents>`
* `AutoAdminLogon = 1` (REG_SZ)
* `ForceAutoLogon = 1` (REG_SZ)
* `AutoLogonCount = 2` (REG_DWORD)

Policies while primed:

* `DisableCAD = 1`
* `Ngc\DevicePasswordLessBuildVersion = 0`
* `IgnoreShiftOverride = 0`

Post conditions on a successful normal run:

* `AutoAdminLogon = 0`
* `ForceAutoLogon = 0`
* `DefaultPassword` is absent
* `RunOnce` does not contain bootstrap or master entries
* `bootstrap` is disabled
* `primaryadmin` is in `Administrators` (and optionally in `Remote Desktop Users`)
* `_needs_reboot.flag` has been removed after a successful normal Stage B run; in recovery mode or after a Stage B failure it may remain to signal that a reboot is still pending

### Logging

* Timestamps are ISO-8601. PowerShell logging uses `Get-Date -Format o`.
* DISM logging is centralized to `%WINDIR%\Logs\DISM\SetupComplete-DISM.log` with `/LogLevel:4`.
* Return codes are interpreted as:

  * `0` - success
  * `3010` / `1641` - success, reboot required (flagged via `_needs_reboot.flag`)
* Installers are invoked with:

  * MSI: `REBOOT=ReallySuppress /norestart`
  * EXE: equivalent `/norestart` switches

## Known trade-offs

See `SECURITY.md` for details. Highlights:

* SmartScreen is disabled and Defender is minimized by design.
* `/ResetBase` removes rollback for currently installed updates.
* With WPAD disabled, proxies must be configured explicitly later.

## License

MIT

## Maintainer

`@tagor-sian` - [https://github.com/tagor-sian](https://github.com/tagor-sian)

## EOL policy and CI guard

This repo enforces line endings:

* Scripts: `*.ps1`, `*.cmd`, `*.bat` -> CRLF
* Markdown: `*.md` -> LF
* Other text: auto detected via Git attributes

Enforcement:

1. `.gitattributes` (normalization at the repo level):

   ```gitattributes
   *.ps1 text eol=crlf
   *.cmd text eol=crlf
   *.bat text eol=crlf
   *.md  text eol=lf
   *     text=auto
   ```

2. CI workflow `.github/workflows/eol-guard.yml` (PR blocking check): the job fails if any script contains LF only lines.

What happens on PRs:

* If a change introduces LF only lines in `*.ps1`, `*.cmd`, or `*.bat`, the workflow fails and merge is blocked until line endings are fixed.

See also `CONTRIBUTING.md` for editor tips and local checks, and the rationale in `DECISIONS.md`.

## Contributing

See `CONTRIBUTING.md` for PR rules, PowerShell 5.1 style, and EOL requirements.

## Decisions (ADR)

See `DECISIONS.md` for the rationale behind key choices. For a structured, end-to-end verification of this baseline, use `docs/AUDIT_CHECKLIST.md` as the canonical audit checklist (Codex CLI uses it as the minimum bar for a full audit).

## Project PowerShell and CLI rules

### SCOPE OF APPLICABILITY (critical)

These rules apply only to:

* interactive Windows PowerShell 5.1 commands (console "Run as administrator")
* project PowerShell scripts (`.ps1`)

These rules do not apply to batch scripts (`.cmd` and `.bat`) such as `SetupComplete.cmd` and `PreOOBE.cmd`. For `.cmd` and `.bat` use pure CMD syntax:

* variables: `%VAR%` (and `!VAR!` when Delayed Expansion is enabled)
* redirection and suppression: `>nul` for STDOUT, `2>nul` for STDERR, `>nul 2>&1` for both
* control flow: `call :label`, `goto`, `if errorlevel`, `for /f`, and similar

Note: the "no `>nul` and `2>nul`" constraint applies only to PowerShell context. In `.cmd` and `.bat` these are valid constructs.

### 0) General principle

* All commands are intended for Windows PowerShell 5.1 (console "Run as administrator").
* External tools such as `reg.exe`, `schtasks.exe`, and `shutdown.exe` are allowed, but suppression and redirection must use PowerShell style.
* Do not use `cmd /c` unless explicitly required.
* In PowerShell 5.1, call external tools directly (`& reg.exe ...`, `& net.exe ...`) with suppression via `| Out-Null 2>$null`; after `reg.exe` check `$LASTEXITCODE`. Do not use `cmd /c` or `Start-Process` for these simple calls.

### 1) Variables and quoting

* Use PowerShell variables (`$wl`, `$env:COMPUTERNAME`) for paths and arguments.
* Single quotes `'...'` are the default (string literal, no interpolation).
* Double quotes `"..."` are used only when variable interpolation or expression evaluation is needed.

### 2) Registry paths

* For `reg.exe`, use classic paths, for example:
  `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon`
* For PowerShell cmdlets (`New-ItemProperty`, `Set-ItemProperty`, `Remove-ItemProperty`), use provider paths:
  `HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon`

### 3) Output suppression

* Hide normal output (STDOUT, stream 1): `| Out-Null`
* Hide errors (STDERR, stream 2): `2>$null`
* Quiet mode for external tools: append both:
  `... | Out-Null 2>$null`
* Do not use `>nul` or `2>nul` in PowerShell (CMD syntax is not valid there).

### 4) Reboot

* Default reboot command:

  ```powershell
  shutdown.exe /r /t 0
  ```

  Add `/f` only when forced shutdown is required.

* Do not replace it with `Restart-Computer` unless clearly specified.

### 5) Anti-patterns

* Do not mix `reg.exe` and PowerShell registry cmdlets without a clear reason.
* Do not use provider style `HKLM:\...` paths in `reg.exe` commands.
* Do not use smart quotes or non ASCII punctuation; stick to regular `'`, `"`, `-`, `/`.
* Do not use PowerShell 7 features or syntax that is incompatible with 5.1.
* In `.cmd` and `.bat` files PowerShell syntax (`$variable`, `| Out-Null`, cmdlets) is forbidden unless wrapped via `powershell.exe ...`.

### Calling PowerShell from CMD scripts (when needed)

Short one liner:

```cmd
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "[DateTime]::Now.ToString('yyyy-MM-dd')"
```

* Inside `-Command "..."` use PowerShell syntax (`$var`, cmdlets).
* Outside, in `.cmd`, use pure CMD (`%VAR%`, `if errorlevel`, and similar).
* To avoid quote escaping issues, alternate quote types as shown or use `-EncodedCommand`.

Capture PowerShell output into a CMD variable:

```cmd
for /f %%G in ('powershell.exe -NoProfile -NonInteractive -Command "[DateTime]::Now.ToString('o')" 2^>nul') do set "TS=%%G"
```

For anything beyond a single expression, do not inline:

```cmd
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\Windows\Setup\Scripts\BootstrapLocalAdmin.ps1" -LogPath "%WINDIR%\Panther\PreOOBE.log"
```

Alternative when quoting is painful: use `-EncodedCommand` with UTF-8 encoded PowerShell code.

### Return codes (short)

* PowerShell: after external tools check `$LASTEXITCODE` (not `$?`).
* CMD: check `%ERRORLEVEL%` with `if errorlevel N ...`.
* Project policy:

  * `0` - success
  * `3010` and `1641` - success, reboot required
    Do not reboot inside `SetupComplete.cmd`; `SetupComplete.cmd` writes `%WINDIR%\Panther\_needs_reboot.flag`, and Stage B in `CreatePrimaryAdmin.ps1` clears the flag and performs a single controlled reboot after the first logon only when Stage B succeeded in the normal path.

For `DISM` and `reg.exe`, log return codes; treat `3010` as a deferred reboot, not as an error.

For detailed Codex CLI invocation and quoting rules, see `docs/INTERACTION_CONTRACT.md` together with `AGENTS.md`.

## Playbooks (insertable blocks)

### Winlogon and autologon (reg.exe from PowerShell)

```powershell
reg add $wl /v AutoLogonCount      /t REG_DWORD /d 2 /f | Out-Null 2>$null
reg add $wl /v IgnoreShiftOverride /t REG_SZ    /d 0 /f | Out-Null 2>$null
```

Reset sticky last user in LogonUI:

```powershell
$logonUI = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI'
reg delete $logonUI /v LastLoggedOnUser    /f | Out-Null 2>$null
reg delete $logonUI /v LastLoggedOnSAMUser /f | Out-Null 2>$null
```

Register master in RunOnce for lab only:

```powershell
$ro = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
reg add $ro /v CreatePrimaryAdmin /t REG_SZ /d 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SystemRoot%\Setup\Scripts\CreatePrimaryAdmin.ps1"' /f | Out-Null 2>$null
```

This snippet is for ad hoc lab testing only. The baseline does not rely on RunOnce to start `CreatePrimaryAdmin.ps1`.

Reboot snippet (for manual tests):

```powershell
shutdown.exe /r /t 0
```

Add `/f` only if you need to force close apps.

### Quick checks

```powershell
reg query 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
```

```powershell
reg query 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
```

```powershell
net user bootstrap
```

### Debug mode

Disable suppression and print return code:

```powershell
reg add $wl /v AutoAdminLogon /t REG_SZ /d 1 /f
"ExitCode: $LASTEXITCODE"
```

## Smoke test (short checklist)

* WSIM validates `autounattend.xml` without errors.
* Setup runs to OOBE with a local path, without Microsoft account screens.
* `SetupComplete.cmd` runs once and writes `%WINDIR%\Panther\SetupComplete.log`.
* If servicing returns `3010` or `1641` or `ALWAYS_REBOOT_AFTER_FIRST_LOGON=1` is set, `SetupComplete.cmd` writes `%WINDIR%\Panther\_needs_reboot.flag`. At the first logon Stage B in `CreatePrimaryAdmin.ps1` clears this flag and performs a single controlled reboot only when Stage B succeeded in normal mode and the flag exists; in recovery mode or when Stage B fails the script logs the pending reboot, skips the automatic restart, and leaves the flag for manual inspection.
* After the reboot:

  * IE, WMP, XPS, Fax/Scan, WorkFolders, PSR are disabled as intended;
  * Edge does not re appear unexpectedly;
  * telemetry and Delivery Optimization follow policy;
  * services and tasks remain disabled as designed.

## Compatibility

`SetupComplete.cmd` is designed for Windows 10 Enterprise LTSC 2021 (21H2, build at least 19044). At the top of the script, compatibility controls allow you to enforce strict version requirements or run in best effort mode.

Default configuration:

```bat
:: --- compatibility controls ---
set "REQUIRED_EDITION=EnterpriseS"
set "REQUIRED_DV=21H2"
set "MIN_BUILD=19044"
set "STRICT_DISPLAYVERSION=0"  :: 1 = hard fail when DV differs, 0 = warning and continue (best-effort)
```

Behavior:

* If `EditionID` is not `EnterpriseS` the script logs an error and exits.
* If `CurrentBuild` is less than `19044` the script logs an error and exits.
* If `DisplayVersion` does not equal `21H2`:

  * with `STRICT_DISPLAYVERSION=1` the script logs an error and exits;
  * with `STRICT_DISPLAYVERSION=0` the script logs a warning and continues in best effort mode.

For controlled production environments set `STRICT_DISPLAYVERSION=1`. For forks and experiments keep `0` and adjust `REQUIRED_*` to your target.

All `SetupComplete.cmd` steps log live timestamps computed inside the script; this helps correlate with DISM and CBS logs and debug issues. Implementation is pure `cmd` without per line PowerShell calls.

## Update (2025-09-19)

* Windows Setup is configured to always show disk and partition selection UI (`WillShowUI=Always`). `InstallTo*` entries were removed to avoid accidental installs to non system disks on multi disk machines.
* OOBE privacy wizard is suppressed via policy, and the six underlying toggles are disabled by policy in `specialize` (applied before OOBE):

  * Diagnostics data (`AllowTelemetry=0`)
  * Tailored experiences (`DisableTailoredExperiencesWithDiagnosticData=1`)
  * Advertising ID (disabled and enforced by policy)
  * Input personalization and online speech (`AllowInputPersonalization=0`)
  * Location (`DisableWindowsLocationProvider=1`, `DisableLocation=1`)
  * Find My Device (`AllowFindMyDevice=0`)
* Local account security questions are disabled (`NoLocalPasswordResetQuestions=1`).

## Install flow and architecture (details)

Short walkthrough of the intended behavior:

1. `PreOOBE.cmd` (pass `specialize`) is invoked from `autounattend.xml` and:

   * applies early privacy and telemetry policies;
   * calls `BootstrapLocalAdmin.ps1` as SYSTEM;
   * does not manipulate Winlogon, passwordless settings, RunOnce, or Task Scheduler.

2. `BootstrapLocalAdmin.ps1`:

   * creates or activates the local account `bootstrap` and assigns a password;
   * writes this password to `%WINDIR%\Setup\Scripts\.bootstrap.pw` (UTF-8 no BOM, Hidden+System, ACL: SYSTEM and Administrators);
   * does not change Winlogon or Ngc, does not create scheduled tasks and does not write RunOnce keys.

3. `SetupComplete.cmd` (runs once after OOBE as SYSTEM) performs:

   * servicing and baseline hardening, logging to `%WINDIR%\Panther\SetupComplete.log` and DISM logs;
   * return code handling: `0` is OK, `3010` and `1641` are OK with deferred reboot, anything else is failure;
   * for `3010` and `1641` or `ALWAYS_REBOOT_AFTER_FIRST_LOGON=1` writes `%WINDIR%\Panther\_needs_reboot.flag` instead of rebooting;
   * if `.bootstrap.pw` exists and `FAILED=0`:

     * applies temporary logon policies for AutoAdminLogon (`DisableCAD=1`, `DevicePasswordLessBuildVersion=0`, `IgnoreShiftOverride=0`);
     * configures AutoAdminLogon for `bootstrap` using the secret from `.bootstrap.pw`;
     * creates the task `\L2C\CreatePrimaryAdmin` (OnLogon, Run as SYSTEM, Highest) to run `CreatePrimaryAdmin.ps1`;
   * if `FAILED=1`, rolls back temporary logon tweaks to safe values and does not configure autologon or scheduled tasks.

4. Reboot and first console logon:

   * AutoAdminLogon signs into the console session as `bootstrap`;
   * in Hyper-V Basic console you see the desktop directly;
   * in Enhanced session (RDP based) you may see a logon screen; this is expected and does not mean AutoAdminLogon failed.

5. At the first interactive logon, the task `\L2C\CreatePrimaryAdmin` runs the master script as SYSTEM:

   * Stage A creates or updates the primary local admin (`primaryadmin` by default) and adds it to required groups;
   * Stage B:

     * in the normal path:

       * restores logon policies (`DisableCAD=0`, `DevicePasswordLessBuildVersion=2`, clears `DefaultPassword` and related values);
       * disables `bootstrap`, deletes the scheduled task and `.bootstrap.pw`;
       * if `_needs_reboot.flag` exists and Stage B completed successfully in normal mode, logs the requirement, deletes the flag, and performs one `shutdown.exe /r /t 0`;
     * in the recovery path:

       * sets `DevicePasswordLessBuildVersion=0`, keeps `bootstrap`, the task, and `.bootstrap.pw` for another attempt;
       * logs any `_needs_reboot.flag`, skips the automatic reboot, and leaves the flag for manual follow up;
       * logs a WARN outcome for manual follow up.

After a successful normal run the system has no AutoAdminLogon configured, `bootstrap` is disabled, `_needs_reboot.flag` is cleared, and `primaryadmin` (or the chosen primary account) is the main administrative identity; in recovery mode or when Stage B fails the flag may remain as a marker for manual action.

## Hyper-V VMConnect: Basic vs Enhanced

* Basic / console mode:

  * provides a direct view of the VM console (like a physical monitor).
  * AutoAdminLogon operates here.
  * there is no shared clipboard; `Ctrl+V` does not paste.
  * the VMConnect menu entry "Clipboard -> Type clipboard text" sends keystrokes to the console session.

* Enhanced session:

  * uses an RDP session with full clipboard support and dynamic resolution.
  * this is not the console.
  * seeing a logon screen here is normal even if the console already auto logged into `bootstrap`.

Practical testing:

* To observe AutoAdminLogon behavior, use Basic mode.
* To copy and paste, use Enhanced mode and log in as the relevant user.
* A single user can have both a console session and an RDP session. For work in a single session, either:

  * log off the console session (for example `logoff 1`) and log into the RDP session, or
  * attach your RDP session to the console using `tscon`.

## Quick start (manual run on an installed VM)

1. Copy to `C:\Windows\Setup\Scripts\`:

   * `BootstrapLocalAdmin.ps1`
   * `CreatePrimaryAdmin.ps1`
   * `SetupComplete.cmd` (and `PreOOBE.cmd` if you want to emulate the full chain)

2. Run `BootstrapLocalAdmin.ps1` as SYSTEM (emulating PreOOBE), for example via Task Scheduler:

   ```powershell
   $a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -File "C:\Windows\Setup\Scripts\BootstrapLocalAdmin.ps1"'
   $p = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
   Register-ScheduledTask -TaskName 'BootstrapLocalAdmin-Once' -Action $a -Principal $p -Settings (New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries) | Out-Null
   Start-ScheduledTask -TaskName 'BootstrapLocalAdmin-Once'
   ```

3. After the task completes, run `SetupComplete.cmd` under SYSTEM to emulate post-setup behavior and configure autologon and the `\L2C\CreatePrimaryAdmin` task.

4. Verify configuration:

   ```powershell
   $wl='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
   Get-ItemProperty $wl | Select DefaultUserName,DefaultDomainName,DefaultPassword,AutoAdminLogon,ForceAutoLogon,AutoLogonCount,DontDisplayLastUserName,IgnoreShiftOverride | Format-List

   reg query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI\Ngc" /v DevicePasswordLessBuildVersion
   reg query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v DisableCAD
   reg query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce"
   schtasks /Query /TN "\L2C\CreatePrimaryAdmin"
   ```

5. Reboot from inside the guest (Start menu -> Restart).

   * In Basic mode you should land directly on the `bootstrap` desktop.
   * In Enhanced mode you will see the logon screen even if the console already auto logged in.

6. Wait for `CreatePrimaryAdmin.ps1` to run via the `\L2C\CreatePrimaryAdmin` task. After it completes, verify:

   * no `DefaultPassword` value under Winlogon;
   * `AutoAdminLogon=0` and `ForceAutoLogon=0` (REG_SZ);
   * `DisableCAD=0`;
   * `DevicePasswordLessBuildVersion=2` in the normal path;
   * `bootstrap` is disabled;
   * `.bootstrap.pw` is deleted in the normal path;
   * `_needs_reboot.flag` is absent after any final reboot in the normal path.

## Acceptance checklist after first logon

* Primary admin (default `primaryadmin`) exists, is active, and is a member of `Administrators` (and optionally `Remote Desktop Users`).
* There is no `DefaultPassword` and no `AutoLogonCount`; `AutoAdminLogon=0`, `ForceAutoLogon=0`, `IgnoreShiftOverride=0`.
* Policies: `DisableCAD=0`, `DevicePasswordLessBuildVersion=2` in the normal path.
* `bootstrap` is disabled (`net user bootstrap /active:no`).
* `RunOnce` does not contain references to `CreatePrimaryAdmin.ps1`.
* `%WINDIR%\Panther\SetupComplete.log` contains clean end markers for SetupComplete.
* `C:\ProgramData\l2c_master_<timestamp>.log` contains `OUTCOME: Success` for the normal path or a clearly marked recovery outcome when applicable.

## Diagnostics (short)

Autologon did not work:

```powershell
$wl='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
Get-ItemProperty $wl | Select DefaultUserName,DefaultDomainName,DefaultPassword,AutoAdminLogon,ForceAutoLogon,AutoLogonCount,DontDisplayLastUserName,IgnoreShiftOverride | Format-List

reg query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI\Ngc" /v DevicePasswordLessBuildVersion
reg query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v DisableCAD
```

Common causes:

* `DefaultPassword` is empty or does not match the `bootstrap` password.
* `AutoAdminLogon` and `ForceAutoLogon` are not `REG_SZ`.
* `DefaultDomainName` does not equal the computer name.
* `LegalNotice*` are configured or `DontDisplayLastUserName=1`.
* `DevicePasswordLessBuildVersion=2` or `DisableCAD=0` remained from a previous configuration.

If you see a logon screen only in Enhanced session but not in the console, remember that AutoAdminLogon targets the console; this is expected.
