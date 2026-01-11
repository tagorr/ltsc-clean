# Codex CLI Interaction Contract
This repository uses Codex CLI as the sole automation agent. Follow these rules precisely.

Primary goal: deterministic Windows-native execution without multi-layer quoting failures.

## Scope and working directory
1. All work MUST be performed from the repository root (workspace root).
2. Do not operate inside `.git` and do not write anything into `.git`.
3. All temporary execution scripts MUST be created under `<workspace>\.codex_tmp\` only.
4. Do not rely on persistent environment variables across runner steps. Within a single Scripted-mode `.ps1`, setting `$env:` is allowed for that script’s process tree.

## Execution model (Windows-native)
Each step is one harness invocation executed as `cmd.exe /c "<line>"`. Scripted mode may require a prior file-edit operation to create a temporary execution script under `.codex_tmp`. 
In Scripted mode, the emitted `<line>` MUST invoke pinned Windows PowerShell 5.1 via `-File` and MUST NOT add any additional shell wrappers.
The emitted `<line>` MUST use ASCII punctuation only (no smart quotes).
In the CMD layer (`cmd.exe /c "<line>"`), use ASCII double quotes only (no single quotes). This rule applies to the emitted `<line>` only, not to PowerShell script contents.

- Do not use command chaining operators (`&&`, `||`, command-separator `&`) in inline steps.
- Do not use pipes `|` in inline steps. If piping is required, use Scripted mode (pipelines inside `.ps1` are allowed).
- Do not add an extra `cmd.exe /c` wrapper inside emitted step commands. The harness already runs every step via `cmd.exe /c "<line>"`.
- For any file writes, redirections, and encoding rules, follow the section: "File writes, encoding, and redirections".

Inside `.ps1`, invoke executables directly (for example: `git status`). Use the call operator `&` only when invoking an executable via an explicit path (especially if the path is stored in a variable or contains spaces).

If there is any doubt whether a command is “simple enough” to inline, use Scripted mode.
Keep emitted CMD lines within the Windows command-line length limit (roughly 8191 characters); otherwise use Scripted mode.

## Inline vs Scripted (mandatory decision)
Use exactly one of these modes:

### 1) Inline mode (allowed only for simple single-tool invocations)
Inline mode is allowed only when all of the following are true:
- A single executable invocation with straightforward arguments.
- No pipes, no redirections, no chaining, no nested shells.
- No complex quoting beyond normal path quoting.
- No conditional logic (“if”, parsing output, branching, loops).

Examples (allowed):
- `git status -sb`
- `git diff --name-status --`
- `git rev-parse --show-toplevel`

### 2) Scripted mode (required for anything non-trivial)
Scripted mode is REQUIRED if the task involves any of the following:
- Conditional logic, branching, parsing output, loops.
- Any quoting that could become multi-layer quoting.
- Any meta characters that commonly break Windows shells.
- Multi-step workflows that must be fail-fast and deterministic.
- Preflight checks that must not self-dirty the working copy.

Scripted mode workflow:
1) Write a temporary PowerShell script file under:
   `<workspace>\.codex_tmp\`
2) Execute it via Windows PowerShell 5.1 using `-File` (do not run temporary execution scripts via `-Command`).
3) Cleanup according to the Cleanup policy.

Inline mode follows runner shell constraints (CMD). Scripted mode runs PowerShell 5.1 as a separate process via `-File`. Do not try to mix them.
Remember: regardless of mode, the harness executes each emitted step as `cmd.exe /c "<line>"`; Scripted mode means the emitted `<line>` invokes pinned PowerShell via `-File`.

## Temporary execution scripts directory: .codex_tmp
Location:
- `<workspace>\.codex_tmp\`

The repository is expected to ignore `.codex_tmp/` via `.gitignore`.

Definitions:
- Temporary execution scripts are `.ps1` files created by the agent under `.codex_tmp` solely to implement Scripted mode for the task at hand. They must not be committed and must be cleaned up per policy.
- Repository scripts are tracked scripts in the repository (for example, `*.ps1` outside `.codex_tmp`) and must never be treated as temporary execution scripts.

Rules:
- Temporary execution scripts MUST be created only under `.codex_tmp\`.
- Temporary execution scripts MUST NOT be created anywhere else in the workspace (including the repository root).
- Temporary execution `.ps1` scripts MUST be created via Codex file editing operations (not via redirection, `Out-File`, or `Set-Content`).
- Repository scripts (tracked `.ps1` files) are not temporary execution scripts and must not be treated as such.

## PowerShell pinning (Windows PowerShell 5.1 only)
All scripted execution MUST use Windows PowerShell 5.1 by full pinned path:

`%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe`

Forbidden:
- `pwsh`
- PowerShell 7+
- `powershell` without the pinned full path
- Any use of `-Command` for running temporary execution scripts

## How to run temporary execution scripts (mandatory flags)
When running a temporary execution `.ps1` script, ALWAYS use:
- `-NoProfile`
- `-NonInteractive`
- `-ExecutionPolicy Bypass`
- `-File <path-to-script.ps1>`

Run this command from the repository root so the relative path ".codex_tmp\step.ps1" resolves correctly.

Example:
```cmd
%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ".codex_tmp\step.ps1"
```

Notes:
* Do not embed script logic into command strings.
* Do not pass a single “mega string” as arguments. Prefer explicit script parameters.

## Cleanup policy
- On success (PowerShell exits with code 0 after running the script): delete the temporary execution script.
- On failure (non-zero exit code): keep the script and print its full path for inspection.
- Temporary outputs under `.codex_tmp` may be kept on failure for diagnostics, but should be removed on success.

## Script content requirements (deterministic and fail-fast)
Every temporary execution `.ps1` MUST start with:

1. Strict/fail-fast defaults:

* `Set-StrictMode -Version Latest`
* `$ErrorActionPreference = 'Stop'`

2. A short comment header describing purpose and scope.

3. Exit behavior:

* On success: exit code MUST be 0.
* On failure: exit code MUST be non-zero.

### External executables inside scripts

When calling an external executable, the script MUST:

* Invoke the executable directly (no nested shells).
* Check `$LASTEXITCODE` and treat non-zero as failure unless explicitly normalized.

If a tool uses a non-zero code for “not an error” semantics (example: “no matches”), the script MUST:

* Normalize that code explicitly.
* Document the normalization in a comment.

## Forbidden patterns
The following are forbidden in this repository’s execution workflow:

* Running temporary execution scripts via `-Command` instead of `-File`
* Embedding non-trivial PowerShell inside `cmd.exe` quoting layers for logic
* Adding extra steps to “check the previous step” (for example via `if errorlevel`) instead of relying on the step’s exit code
* Any “double wrapping” such as `cmd.exe /c "cmd.exe /c ..."`
* Including `cmd.exe /c` in an emitted step command (the harness already supplies it)
* Building a single command string to execute via a shell inside `.ps1` instead of invoking tools directly
* Introducing `EnableDelayedExpansion` in tracked `.cmd` / `.bat` scripts


## File writes, encoding, and redirections


### Repository files (tracked content)

Rule: Do not create or modify tracked repository files using redirection or implicit-encoding write commands.  
If output must be captured, do it only in Scripted mode and write only under `.codex_tmp\...` (never into tracked paths).

Forbidden when the destination is a tracked repository path:
- Any redirection (CMD or PowerShell), including `>`, `>>`, `2>`, `2>&1`, `*>` (including `echo ... > file`)
- Any implicit-encoding writes (PowerShell), including `Out-File` and `Set-Content`

Preferred:
- Use Codex file editing operations for tracked repository files.
- If you must capture tool output, write only under `.codex_tmp\...` (for example: `.codex_tmp\tool.log`).

Capturing output (diagnostic logs):
- If output must be captured, do it only in Scripted mode and write only under `.codex_tmp\...`.
- CMD redirection is forbidden (even when writing under `.codex_tmp`).
- Writing logs under `.codex_tmp` is allowed using `Out-File` / `Set-Content` only when the destination is under `.codex_tmp` and encoding is explicitly specified. (BOM is acceptable for diagnostic logs.)
- Prefer `Out-File -Encoding UTF8` (or an explicitly specified encoding) when writing diagnostic logs under `.codex_tmp`.

### Encoding and EOL

- Tracked Markdown (.md): UTF-8 without BOM, LF line endings.
- Tracked scripts (.ps1, .cmd, .bat): UTF-8 without BOM, CRLF line endings.
- Tracked scripts must be ASCII-only (no non-ASCII characters in file contents).
- Temporary execution `.ps1` files under `.codex_tmp`: UTF-8 without BOM.
- Temporary execution scripts under `.codex_tmp` do not require a specific line ending style (LF or CRLF is acceptable). Do not spend effort normalizing EOL for temporary scripts.

## Diagnostics and probes
Principles:

1. Prefer tools that operate on tracked files and repo metadata.
2. Prefer deterministic scopes: explicit paths, no recursive filesystem scans unless required.
3. Avoid fragile shell constructs in probes. If a probe needs logic, use Scripted mode.

### Search

Preferred:

* `git grep` for tracked files.

When interpreting results:

* `git grep` exit code 0 means matches found.
* `git grep` exit code 1 means no matches (NOT an error for search).
* `git grep` exit code >= 2 means an error.

If a probe must branch on grep output, implement it in a temporary execution `.ps1` script and normalize `RC=1` explicitly.

### Avoid

* Do not use `findstr` as a default search tool.
* Do not use file-size heuristics to detect success/failure of a probe.

## Git safety
1. Run all git operations from repository root.
2. Do not run git from inside `.git`.
3. Preflight MUST NOT self-dirty the working copy.
4. Do not modify `.gitignore` unless the user prompt explicitly instructs you to change `.gitignore`.
5. In Git commands that specify paths, always separate paths with `--`.
6. Before committing, review staged changes.

### Preflight (clean working copy without self-dirtying)

Preflight SHOULD be implemented in Scripted mode (temporary execution `.ps1`) to avoid creating artifacts in repo root.

Preflight must:

* Confirm repository root (`git rev-parse --show-toplevel`) matches the current working directory expectations.
* Ensure `.codex_tmp` exists (create it if missing).
* Check the working copy is clean using `git status --porcelain=v1` (read in-memory, no output redirection to repo-root files). If `.codex_tmp` appears, stop and report that `.gitignore` must include `.codex_tmp/`. Do not attempt to modify `.gitignore` unless explicitly instructed.
* `.codex_tmp` is expected to be ignored by `.gitignore` and must not affect preflight cleanliness.
* Fail if the working copy is not clean, unless the task explicitly requires changes.

## Output discipline
1. Print short, stable markers (one line) before major actions.
2. Print full commands only if short and safe (no secrets, no complex quoting).
3. Never print secrets, tokens, or sensitive data.
4. Prefer ASCII-only markers to reduce console encoding ambiguity.

## Formatting rules for commands in responses
1. One command per fenced code block.
2. Use language identifiers for fenced blocks:
   * `cmd` for CMD invocations
   * `powershell` for PowerShell snippets (script contents)
   * `diff` for patches
3. Do not include shell prompts (no `PS C:\...>` or `C:\...>` inside blocks).
4. Using `cmd` in fenced code blocks is only a formatting hint, not an instruction to wrap with `cmd.exe /c`.

## Acceptance checklist
Before declaring success, verify:

1. No emitted `<line>` contained `cmd.exe /c` (the harness already supplies it).
2. No nested wrapping such as `cmd.exe /c "cmd.exe /c ..."` occurred.
3. Temporary execution script used only Windows PowerShell 5.1 pinned path and `-File` with:
   `-NoProfile -NonInteractive -ExecutionPolicy Bypass`
4. No temporary execution script used `-Command` to execute logic.
5. Temporary artifacts were created only under `.codex_tmp`, and cleanup rules were followed:
   * scripts removed on success
   * scripts preserved on failure with the path printed
6. Markdown encoding/EOL constraints are met (UTF-8 without BOM, LF).
7. Tracked scripts (.ps1, .cmd) encoding/EOL constraints are met (UTF-8 without BOM, CRLF).
8. For modified tracked text files, verify no BOM and no NUL bytes (per repo policy).
9. Any probe/search logic normalized non-error exit codes explicitly (example: `git grep RC=1`).
10. No repository files were created/modified via redirection or implicit-encoding output commands.
11. `.codex_tmp/` is ignored via `.gitignore` and does not affect preflight cleanliness.