# Contributing

Thanks for your interest in contributing!

## PR flow (quick)

- Create a feature branch (e.g. `feat/...`, `fix/...`, `docs/...`, `chore/...`).
- Keep commits clean; merges are **squash**.
- Commit prefixes: `feat|fix|docs|chore|ci|refactor|test`.
- Make sure **CI is green** before requesting review.

## PowerShell 5.1 CLI rules (project-specific)

- Use **Windows PowerShell 5.1**. Do **not** use PowerShell 7 syntax or features.
- External tools (`reg.exe`, `schtasks.exe`, `shutdown.exe`) are allowed, but suppression is **only** in PowerShell style: `| Out-Null 2>$null`.
- Registry paths:
  - `reg.exe` uses classic paths, for example `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon`.
  - PowerShell cmdlets (`New/Set/Remove-ItemProperty`) use provider paths, for example `HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon`.
- Do not mix `reg.exe` and PowerShell cmdlets in one logical block **without a clear reason**.
- Reboot via `shutdown.exe /r /t 0` (add `/f` only if needed).
- ASCII quotes only in code examples: `' " - /`. No smart quotes.
- All examples and snippets must be compatible with Windows PowerShell 5.1.

## Line endings (EOL)

- Scripts `*.ps1`, `*.cmd` **must use CRLF**.
- Markdown `*.md` **should use LF**.
- This is enforced by `.gitattributes` and an EOL CI guard (`.github/workflows/eol-guard.yml`).

## VM smoke tests (minimum bar)

These are quick VM checks for PR validation (not a full audit). Use a clean VM or a snapshot.

### Happy-path smoke (fresh VM)

- If available, validate `Autounattend.xml` in WSIM without errors.
- Install and reach OOBE without Microsoft account screens (local flow).
- Verify `PreOOBE.cmd` ran and wrote `%WINDIR%\Panther\PreOOBE.log`.
- Verify `SetupComplete.cmd` ran once and wrote `%WINDIR%\Panther\SetupComplete.log`.
- On the first console logon, Winlogon may perform AutoAdminLogon with `bootstrap`. This is visible on the VM console (for example Hyper-V VMConnect Basic), not on Enhanced (RDP) sessions.
- Verify the scheduled task exists and runs the master:
  - Task name: `\L2C\CreatePrimaryAdmin`
  - It runs `CreatePrimaryAdmin.ps1` as SYSTEM on logon.
- Validate the normal success end state (see `README.md` for details):
  - `C:\ProgramData\l2c_master_<timestamp>.log` exists and contains `OUTCOME: SUCCESS`.
  - `bootstrap` is disabled.
  - The `\L2C\CreatePrimaryAdmin` scheduled task is removed.
  - Winlogon temporary values are cleaned up (for example `DefaultPassword` absent and autologon disabled).
  - `%WINDIR%\Setup\Scripts\.bootstrap.pw` and `.primaryadmin.pw` are removed on the normal success path.
  - If `%WINDIR%\Panther\_needs_reboot.flag` exists and Stage B succeeded in normal mode, Stage B consumes the flag and performs one controlled reboot.

### Recovery-path smoke (gate closed)

Pick one deliberate gate failure and confirm the run stays fail-closed (no Stage B registration / no autologon priming):

- Remove `%WINDIR%\Setup\Scripts\.primaryadmin.pw`, or make it empty, or break its ACL/attributes so `ValidateSecrets.ps1` reports `primaryadmin=0`.
- Verify `SetupComplete.log` shows the combined gate did not pass and that SetupComplete entered recovery mode (skipping extra registrations).
- Confirm the `\L2C\CreatePrimaryAdmin` task is not registered and Winlogon autologon is not primed by SetupComplete.
- Confirm secrets are preserved for operator investigation (recovery entrypoint remains available).

### Attach evidence to PRs (when relevant)

Include small excerpts (or the full files when diagnosing) from:

- `%WINDIR%\Panther\PreOOBE.log`
- `%WINDIR%\Panther\SetupComplete.log`
- `%WINDIR%\Logs\DISM\SetupComplete-DISM.log`
- `C:\ProgramData\l2c_master_<timestamp>.log` (normal or recovery outcome)
  - If Stage B retained `bootstrap` / the executor task / secrets unexpectedly, look for:
    - `HARD FAIL: Logon policy restore verification failed, refusing to teardown executor/bootstrap.`
    - `Teardown blocked due to logon policy restore verification failure; bootstrap/task/secrets retained.`
    - `OUTCOME: FAIL - logon policy restore verification failed (executor/bootstrap retained)`

## Using Codex CLI in this repo

This repo is designed to be edited with Codex CLI under strict constraints.

- Canonical execution and quoting rules live in `docs/INTERACTION_CONTRACT.md`. Follow it when drafting prompts and when interpreting agent output.
- `AGENTS.md` defines the runbook and invariants. Do not introduce changes that break the reboot model (flag-based), secret handling, or recovery posture.
- Keep scope tight: allow-list the exact files Codex may touch. Do not expand scope mid-task.
- Minimal diffs only. No reformatting outside the hunks required by the change.
- Temporary helper scripts (if needed) must live under `<workspace>\.codex_tmp\` only.
- Codex must not perform state-changing Git operations (commit, push, merge, checkout, restore). Read-only Git commands (for example `git status`, `git diff`) are OK when needed for situational awareness.
- Preserve repository encoding and line endings (scripts CRLF, Markdown LF). UTF-8 without BOM, no NUL bytes. CI enforces ASCII-only for tracked `*.cmd`/`*.ps1` ("ASCII Only Guard").
- Prefer Windows-native tooling and pinned Windows PowerShell 5.1 execution rules as documented (avoid PowerShell 7+, avoid multi-layer quoting tricks).

## Shell rules (.cmd/.ps1) and minimal-diff

- `.cmd` guidelines:
  - No Delayed Expansion.
  - Test return codes via `%ERRORLEVEL%`.
  - Use `goto` and `call :sub` for control flow.
- PowerShell target:
  - Windows PowerShell 5.1.
  - Avoid `$ExecutionContext.InvokeCommand.ExpandString` for secrets.
  - Prefer plain arguments or files for passing secrets.
- Minimal-diff principle:
  - Change only the lines required by the PR scope.
  - Avoid cosmetic edits outside the relevant hunks.

- Docs convention:
  - In Markdown, use **one command per fenced code block**.
  - Use an explicit language tag: `powershell` or `cmd`.
  - Each block should be copy-pastable and executable in one go.
  - Avoid multi-command blocks and mixed shells inside a single fenced block.

## VS Code tips

- Set `CRLF` for scripts and `LF` for Markdown in the status bar.
- If your global Git EOL settings conflict with the repo defaults, align them before contributing:

```powershell
git config core.autocrlf false
```
```powershell
git add --renormalize
```

## Before opening a PR

* ✅ EOL checked; no LF-only lines in scripts.
* ✅ PowerShell 5.1 style rules respected.
* ✅ Docs updated if behavior or policies changed (`README.md`, `DECISIONS.md`, `SECURITY.md`, `docs/AUDIT_CHECKLIST.md`).
* ✅ PR title and commits use conventional prefixes.

## CI and checks

* The EOL guard runs on every PR. See the Checks tab for logs.
* If it fails, fix line endings and push to the same branch; the check will re-run automatically.
