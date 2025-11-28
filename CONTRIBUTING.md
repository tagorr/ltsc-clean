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

- Scripts `*.ps1`, `*.cmd`, `*.bat` **must use CRLF**.
- Markdown `*.md` **should use LF**.
- This is enforced by `.gitattributes` and an EOL CI guard (`.github/workflows/eol-guard.yml`).

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