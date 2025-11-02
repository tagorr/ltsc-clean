# Contributing

Thanks for your interest in contributing!

## PR flow (quick)
- Create a feature branch (e.g. `feat/...`, `fix/...`, `docs/...`, `chore/...`).
- Keep commits clean; merges are **squash**.
- Commit prefixes: `feat|fix|docs|chore|ci|refactor|test`.
- Make sure **CI is green** before requesting review.

## PowerShell 5.1 CLI rules (project-specific)
- Use **PowerShell 5.1**. Do **not** use PowerShell 7 syntax/features.
- External tools (`reg.exe`, `schtasks.exe`, `shutdown.exe`) are allowed, but suppression **only** in PS style: `| Out-Null 2>$null`.
- Registry paths:
  - `reg.exe` → classic paths, e.g. `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon`
  - PS cmdlets (`New/Set/Remove-ItemProperty`) → provider paths, e.g. `HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon`
- Do not mix `reg.exe` and PS cmdlets in one block **without a clear reason**.
- Reboot via `shutdown.exe /r /t 0` (use `/f` if needed).
- ASCII quotes only: `' " - /`. No smart quotes.
- Examples/snippets must be PS 5.1 compatible.

## Line endings (EOL)
- Scripts `*.ps1`, `*.cmd`, `*.bat` **must use CRLF**.
- Markdown `*.md` **should use LF**.
- Enforced by `.gitattributes` + CI guard (`.github/workflows/eol-guard.yml`).

## Shell rules (.cmd/.ps1) & minimal-diff
- .cmd guidelines: no Delayed Expansion; test RC via %ERRORLEVEL%; branch via `goto`/`call :sub`.
- PowerShell target: Windows PowerShell 5.1; avoid `$ExecutionContext.InvokeCommand.ExpandString` for secrets; prefer plain args or files.
- Minimal-diff principle: change only the lines required by the PR’s scope.

**Local quick check (optional)**
```bash
git ls-files -- '*.ps1' '*.cmd' '*.bat' \
| xargs -I{} sh -c "awk '(/\r$/){next} {exit 1} END{exit 0}' '{}' || echo 'LF-only: {}'"
```

**VS Code tips**

* Set `CRLF` for scripts, `LF` for Markdown (status bar).
* If your global Git EOL is overridden, align with repo defaults:

  ```bash
  git config core.autocrlf false
  git add --renormalize .
  ```

## Before opening a PR

* ✅ EOL checked; no LF-only lines in scripts.
* ✅ PowerShell 5.1 style rules respected.
* ✅ Docs updated if behavior/policies changed (README/DECISIONS).
* ✅ PR title and commits use conventional prefixes.

## CI and checks

* The **EOL guard** runs on every PR. See the **Checks** tab for logs.
* If it fails, fix line endings and push to the same branch; the check will re-run automatically.

