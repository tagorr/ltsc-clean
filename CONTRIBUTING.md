# Contributing

Thanks for your interest in contributing!

## PR flow (quick)

- Create a feature branch (e.g. `feat/...`, `fix/...`, `docs/...`, `chore/...`).
- Keep commits clean; merges are **squash**.
- Commit prefixes: `feat|fix|docs|chore|ci|refactor|test`.
- Run the repository preflight checks from the repository root before opening a PR.
- Make sure **CI is green** before requesting review.

## PowerShell 5.1 CLI rules (project-specific)

These rules apply to interactive Windows PowerShell 5.1 commands and to project `.ps1` scripts. They do not replace normal CMD syntax in `.cmd` files.

- Use **Windows PowerShell 5.1**. Do **not** use PowerShell 7 syntax or features.
- External tools (`reg.exe`, `schtasks.exe`, `shutdown.exe`) are allowed, but suppression is **only** in PowerShell style: `| Out-Null 2>$null`. After external tools, check `$LASTEXITCODE`, not `$?`.
- Registry paths:
  - `reg.exe` uses classic paths, for example `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon`.
  - PowerShell cmdlets (`New/Set/Remove-ItemProperty`) use provider paths, for example `HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon`.
- Do not mix `reg.exe` and PowerShell cmdlets in one logical block **without a clear reason**.
- Reboot via `shutdown.exe /r /t 0` (add `/f` only if needed).
- ASCII quotes only in code examples: `' " - /`. No smart quotes.
- Documentation is UTF-8. For copy/paste command blocks, prefer ASCII punctuation (plain quotes and hyphens) to avoid issues in non-UTF8 environments.
- All examples and snippets must be compatible with Windows PowerShell 5.1.
- Do not use `cmd /c` unless it is explicitly required.

## Line endings (EOL)

- Scripts `*.ps1`, `*.cmd` **must use CRLF**.
- Markdown `*.md` **should use LF**.
- This is enforced by `.gitattributes` and an EOL CI guard (`.github/workflows/eol-guard.yml`).

## Validation before PR

If your change can affect pipeline behavior, installation flow, recovery behavior, logon behavior, reboot handling, secret handling, final machine state, or the documented interpretation of those behaviors, validate it in a clean VM or equivalent isolated test environment before opening a PR.

At minimum:

- confirm the intended path behaves as expected;
- check the relevant runtime evidence (`PreOOBE.log`, `SetupComplete.log`, and, when applicable, `l2c_master_<timestamp>.log`);
- confirm the observed machine state matches the expected outcome for that path.

When a change affects runtime behavior, include a short validation note in the PR and attach relevant evidence excerpts when useful.

For the detailed validation procedure and smoke scenarios, see [Validation](docs/VALIDATION.md).

## Agent-assisted editing

If you use Codex CLI or another coding agent in this repository, follow [AGENTS.md](AGENTS.md) and the [Interaction Contract](docs/INTERACTION_CONTRACT.md).

Do not let agent-generated changes expand scope, break repository invariants, or bypass the repository's execution, encoding, and line-ending rules.

## Shell rules (.cmd/.ps1) and minimal-diff

- `.cmd` guidelines:
  - No Delayed Expansion.
  - Test return codes via `%ERRORLEVEL%`.
  - Use `goto` and `call :sub` for control flow.
  - Inside parenthesized blocks, `%VAR%` expansion happens at parse time, not at execution time; do not rely on changing values or return-code-dependent logic there, and prefer `call :sub` when state must be captured safely.
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

## Before opening a PR

- ✅ EOL checked; no LF-only lines in scripts.
- ✅ PowerShell 5.1 style rules respected.
- ✅ Repository preflight checks run successfully.
- ✅ Docs updated for every affected document role when the PR changes behavior, boundaries, validation scope, recovery handling, security posture, or system explanation. Use the [Guide](docs/GUIDE.md) to identify the affected documents.
- ✅ Doc references validated: any referenced repo paths in docs still exist (no drift from renames/moves).
- ✅ PR title and commits use conventional prefixes.

## CI and checks

- The EOL guard runs on every PR. See the Checks tab for logs.
- If it fails, fix line endings and push to the same branch; the check will re-run automatically.
- Docs link validation is manual (no automated link checker): when editing docs, verify that referenced repo paths (for example `AGENTS.md`, `docs/INTERACTION_CONTRACT.md`, `.github/workflows/eol-guard.yml`) still exist and match the current tree.
