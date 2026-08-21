# Contributing

Thanks for your interest in contributing!

## PR flow (quick)

- Create a feature branch (e.g. `feat/...`, `fix/...`, `docs/...`, `chore/...`).
- Keep commits clean; merges are **squash**.
- Commit prefixes: `feat|fix|docs|chore|ci|refactor|test`.
- Run the repository preflight checks from the repository root before opening a PR.
- Make sure **CI is green** before requesting review.

## Tracked Windows runtime code

These requirements apply to tracked installation scripts that run on the supported Windows target. They do not prescribe how contributors or agents execute ordinary maintenance commands.

- Tracked PowerShell scripts, PowerShell launched by tracked runtime code, and runtime PowerShell examples must remain compatible with **Windows PowerShell 5.1**.
- In tracked PowerShell runtime code:
  - After invoking an external executable whose status controls runtime behavior, inspect `$LASTEXITCODE`.
  - `reg.exe` uses classic paths such as `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon`; PowerShell registry cmdlets use provider paths such as `HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon`.
  - Avoid `$ExecutionContext.InvokeCommand.ExpandString` for secrets, and do not place secrets on external process command lines.
- In tracked `.cmd` files:
  - Do not enable delayed expansion.
  - Test return codes only where `%ERRORLEVEL%` reflects the intended command.
  - Inside parenthesized blocks, do not use ordinary `%ERRORLEVEL%` or `%VAR%` expansion for values that may change within the block; move the read or branch outside the block, or use the permitted CALL-expansion pattern.
  - Use labels and subroutines (`goto`, `call :sub`) where appropriate for runtime-safe state handling and control flow.

## Line endings and tracked-file integrity

- Tracked `*.ps1`, `*.cmd`, and `*.bat` files use CRLF; tracked `*.md` files use LF.
- `.gitattributes` is the source of truth for EOL expectations.
- Tracked text files use UTF-8 without BOM and contain no NUL bytes. Tracked `.cmd` and `.ps1` files are ASCII-only.

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

Do not let agent-generated changes expand scope or bypass repository runtime, validation, or tracked-file integrity requirements.

## Minimal-diff and documentation conventions

- Change only the lines required by the PR scope; avoid cosmetic edits outside the relevant hunks.

- Docs convention:
  - In Markdown, use **one command per fenced code block**.
  - Use an explicit language tag: `powershell` or `cmd`.
  - Each block should be copy-pastable and executable in one go.
  - Avoid multi-command blocks and mixed shells inside a single fenced block.
  - For copy-paste shell snippets, prefer plain ASCII quotes and hyphens where that improves portability.

## Before opening a PR

- ✅ Tracked-file integrity requirements checked.
- ✅ Tracked runtime PowerShell remains Windows PowerShell 5.1 compatible.
- ✅ Repository preflight checks run successfully.
- ✅ Docs updated for every affected document role when the PR changes behavior, boundaries, validation scope, recovery handling, security posture, or system explanation. Use the [Guide](docs/GUIDE.md) to identify the affected documents.
- ✅ Doc references validated: any referenced repo paths in docs still exist (no drift from renames/moves).
- ✅ Commit and squash subjects use conventional prefixes; PR titles may be human-readable.

## CI and checks

- The EOL/BOM/NUL guard runs on pull requests; the ASCII Only Guard runs on pull requests and pushes. See the Checks tab for logs.
- If a guard fails, fix the affected tracked-file integrity issue and push to the same branch; the check will re-run automatically.
- Docs link validation is manual (no automated link checker): when editing docs, verify that referenced repo paths (for example `AGENTS.md`, `docs/INTERACTION_CONTRACT.md`, `.github/workflows/eol-guard.yml`, `.github/workflows/ascii-only.yml`) still exist and match the current tree.
