# Codex CLI Interaction Contract
This repository uses Codex CLI as the sole automation agent. Follow these rules precisely.

Primary goal: deterministic Windows-native execution without multi-layer quoting failures.

## Scope and working directory
1. All work MUST be scoped to the repository root (workspace root). Do not assume CWD stability between harness steps.
2. Do not operate inside `.git` and do not write anything into `.git`.
3. All temporary execution scripts MUST be created only under the repository root’s `.codex_tmp\` directory (repository root obtained via `git rev-parse --show-toplevel`).
4. Do not rely on persistent environment variables across runner steps. Within a single Scripted-mode `.ps1`, setting `$env:` is allowed for that script’s process tree.

## Execution model (Windows-native)
Each step is one harness invocation executed as `cmd.exe /c "<line>"`. Scripted mode may require a prior file-edit operation to create a temporary execution script under `.codex_tmp`. 
In Scripted mode, the emitted `<line>` MUST invoke pinned Windows PowerShell 5.1 via `-File` and MUST NOT add any additional shell wrappers.
Scripted-mode probes MUST determine the repository root at runtime from inside the .ps1 itself: invoke git rev-parse --show-toplevel, capture stdout, remove only the trailing CR/LF (for example: TrimEnd("`r","`n"); do NOT use .Trim()), then
Set-Location to that path before any other work in the probe.
It is forbidden for a probe to hardcode the repository root as any constant absolute path string, regardless of path format, even if that value was obtained earlier in the session.
It is also forbidden to derive the repository root from $PSScriptRoot, $MyInvocation, $PWD, the current working directory as the source of truth for repo root, or from the probe launcher    path.

Blessed probe bootstrap (top of the .ps1):

$repoRoot = & git rev-parse --show-toplevel
Set-Location -LiteralPath $repoRoot

If needed, normalize the captured output by removing only the trailing CR/LF (for example: TrimEnd("`r","`n")) before using it for Set-Location; do NOT use .Trim().
The emitted `<line>` MUST use ASCII punctuation only (no smart quotes).
In emitted inline `<line>`, quoting characters are forbidden: do not use `"` or `'`. If quoting would be needed, use Scripted mode instead. This rule applies to the emitted `<line>` only, not to PowerShell script contents.

- Do not use command chaining operators (`&&`, `||`, command-separator `&`) in inline steps.
- Do not use pipes `|` in inline steps. If piping is required, use Scripted mode (pipelines inside `.ps1` are allowed).
- Inline mode MUST NOT invoke `powershell.exe` with `-Command` (or `-c`).
- Any PowerShell usage in emitted `<line>` is allowed ONLY as the Scripted-mode launcher invoking pinned Windows PowerShell 5.1 via `-File` with required flags. Do not attempt to "carefully quote" `-Command` inside `cmd.exe /c "<line>"`: it is forbidden by policy.
- Anything you would normally do via a PowerShell one-liner (view file ranges, search multi-word patterns, print numbered lines, formatting output) MUST be done in Scripted mode: create or update exactly one single-use `.ps1` probe under the repo-rooted `.codex_tmp\`, anchor to repo root per this document, do the work inside the `.ps1`, and execute it only via pinned Windows PowerShell 5.1 `-File` using an absolute repo-rooted path. No nested shells, no command strings, no helper scripts.
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
- No quoting characters in emitted `<line>` (no `"` and no `'`).
- No conditional logic ("if", parsing output, branching, loops).

Examples (allowed):
- `git status -sb`
- `git diff --name-status --`
- `git rev-parse --show-toplevel`

Inline mode is intentionally "flat" and quote-free. The following forms/patterns MUST NOT appear in an emitted inline `<line>`; if any apply, use Scripted mode instead:
- Any quoting characters: `"` or `'`
- Any CMD metacharacters: `|`, `>`, `>>`, `<`, `&`, `&&`, `||`, `(`, `)`, `^`, `!`
- Any redirection/piping/chaining or multi-command constructs.
- Any attempt to manage the working directory in inline mode: `cd`, `pushd`, `popd` (use `Set-Location` inside the temporary `.ps1` after anchoring to repo root).

### 2) Scripted mode (required for anything non-trivial)
Scripted mode is REQUIRED if the task involves any of the following:
- Conditional logic, branching, parsing output, loops.
- Any quoting that could become multi-layer quoting.
- Any meta characters that commonly break Windows shells.
- Multi-step workflows that must be fail-fast and deterministic.
- Preflight checks that must not self-dirty the working copy.

Scripted mode workflow:
Inside the temporary .ps1, apply the repository-root anchoring rule from ## Execution model (Windows-native) before doing any other work.
1) Write a temporary PowerShell script file only under the repository root’s `.codex_tmp\` directory (repository root obtained via `git rev-parse --show-toplevel`).
2) Execute it via Windows PowerShell 5.1 using `-File` (do not run temporary execution scripts via `-Command`).
3) Cleanup according to the Cleanup policy.

Inline mode follows runner shell constraints (CMD). Scripted mode runs PowerShell 5.1 as a separate process via `-File`. Do not try to mix them.
Remember: regardless of mode, the harness executes each emitted step as `cmd.exe /c "<line>"`; Scripted mode means the emitted `<line>` invokes pinned PowerShell via `-File`.

## Windows quoting failure triggers (force Scripted mode)

Hard triggers (do NOT inline; use Scripted mode):
- Any grep/search pattern that begins with `-` MUST use Scripted mode unless it is a simple inline `git grep -n -F -e <pattern> -- <paths...>` invocation (example pattern: `-SID`).
- Patterns containing whitespace or `:` MUST ALWAYS be implemented in Scripted mode (multi-word patterns cannot be safely expressed inline under `cmd.exe /c "<line>"` due to argv splitting). Examples: `Get-LocalGroup -SID`, `A: SKIP`.
- Inline `git grep` MUST be limited to a single simple fixed-string token and MUST use `-F -e` (for example: `git grep -n -F -e <token> -- <paths...>`). Inline `git grep` MUST NOT use any regex mode (`-E`, `-P`, `--extended-regexp`, `--basic-regexp`, `--perl-regexp`) and MUST NOT use regex constructs as a workaround to emulate multi-word matching (for example `[[:space:]]`, `\s`, `.*` between words). Any search intent beyond a single literal token is a hard trigger: use Scripted mode. 
- Any use of `powershell.exe ... -Command ...` in emitted `<line>` is a hard trigger and is forbidden in inline mode. Use Scripted mode (`-File`) instead.
- Any command requiring pipes, output formatting, output parsing, or branching on output.
- Any PowerShell in inline mode is forbidden, except the Scripted-mode launcher using pinned Windows PowerShell 5.1 via `-File`.
- Any command that previously produced errors like `fatal: unable to resolve revision: ...` due to broken quoting/argv splitting: treat as a quoting failure and move it into Scripted mode with argv-safe invocation.

Forbidden patterns (inline): see `Hard triggers` above and `## Forbidden patterns` below.

Good (Scripted mode; argv-safe). Replace `C:\repo` with the exact value printed earlier by `git rev-parse --show-toplevel`:
```cmd
%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File C:\repo\.codex_tmp\probe.ps1
```

## Temporary execution scripts directory: .codex_tmp
Location:
- the repository root’s `.codex_tmp\` directory (repository root obtained via `git rev-parse --show-toplevel`).

The repository is expected to ignore `.codex_tmp/` via `.gitignore`.

Definitions:
- Temporary execution scripts are `.ps1` files created by the agent under `.codex_tmp` solely to implement Scripted mode for the task at hand. They must not be committed and must be cleaned up per policy.
- Repository scripts are tracked scripts in the repository (for example, `*.ps1` outside `.codex_tmp`) and must never be treated as temporary execution scripts.

Rules:
- Temporary execution scripts MUST be created only under the repository root's `.codex_tmp\` directory (repository root obtained via `git rev-parse --show-toplevel`).
- Temporary execution scripts MUST NOT be created anywhere else in the workspace (including the repository root).
- Temporary execution `.ps1` scripts MUST be created via Codex file editing operations (not via redirection, `Out-File`, or `Set-Content`).
- Repository scripts (tracked `.ps1` files) are not temporary execution scripts and must not be treated as such.

### Temporary probes (single-use)
A temporary execution `.ps1` under `.codex_tmp` is a single-use probe:
- It MUST be self-contained (one file).
- It MUST NOT depend on or create additional helper scripts/modules (no `helper.ps1`, `common.ps1`, `*.psm1`, subfolders, or multi-file toolchains).
- It SHOULD prefer stdout/stderr only.
- Exception: it MAY write at most ONE diagnostic log file per probe under the repo-rooted `.codex_tmp\...` only when necessary (for example: output too large for terminal history or owner explicitly needs an attached log).
- If a diagnostic log is written, encoding MUST be explicitly specified as UTF-8.
- Small local functions inside the same `.ps1` are allowed when used only within that file.

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

CWD may drift between harness steps; do not rely on stable CWD.

Mandatory bootstrap (Scripted mode):
1) Emit: `git rev-parse --show-toplevel`
2) Capture the exact value it prints (repository root path).
   - If it fails, STOP.
   - The printed repo root MUST NOT contain whitespace. If it does, STOP and ask the owner to move the repo to a no-space path (no quoting workarounds).
   - When using the printed repo root value, remove only the trailing CR/LF (for example: TrimEnd("`r","`n"); do NOT use .Trim()).
   - git rev-parse --show-toplevel may print the repository root with forward slashes (example: D:/...). When constructing any absolute Windows paths in emitted <line> (launcher and cleanup), you MUST normalize the repo root to backslashes (\) first, and then append \.codex_tmp\.... Do not use forward slashes in emitted <line> absolute paths.
3) Use absolute paths rooted at that printed value (after backslash normalization as described above) for both script launch and cleanup.

Temporary `.codex_tmp\*.ps1` script paths MUST NOT be quoted in emitted `<line>`.

Example form (replace `C:\repo` with the exact value printed earlier by `git rev-parse --show-toplevel`):
```cmd
%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File C:\repo\.codex_tmp\step.ps1
```

Notes:
* Do not embed script logic into command strings.
* Do not pass a single “mega string” as arguments. Prefer explicit script parameters.

## Cleanup policy
* **Success (exit code 0):** the agent MUST delete the **single** just-executed temporary script file under `.codex_tmp\` **as the next separate step** (do not combine deletion with the launcher step).
* The delete step MUST use the **exact script file path** and MUST delete **only that one file** (no wildcards like `*` or `?`, no directory deletes, no recursive deletes).
* `* Cleanup MUST NOT use force delete flags (for example: 'del /f'). In this harness, '/f' may trigger an interactive confirmation prompt. Use 'del /q <absolute-probe-path>' instead.`
* **Failure (non-zero exit code):** the agent MUST keep the script and print its full path for inspection (do not delete).
* After the cleanup decision (deleted on success, kept on failure), the agent MUST run `git status --porcelain=v1` and confirm **no new tracked changes beyond task scope** and **no new untracked files outside `.codex_tmp`**.

Note: cleanup MUST use the same absolute repository-rooted path form as the launcher. Replace `C:\repo` with the exact value printed earlier by `git rev-parse --show-toplevel`.
Use the normalized backslash form of the repo root (see Mandatory bootstrap) when constructing the launcher path and the del path.

Allowed:
* `del /q C:\repo\.codex_tmp\probe.ps1`

Forbidden:
* `del /q .codex_tmp\probe.ps1`
* `del .codex_tmp\*.ps1`
* `rmdir /s /q .codex_tmp`
* `del /f C:\repo\.codex_tmp\probe.ps1`
* `del /f /q C:\repo\.codex_tmp\probe.ps1`

## Script content requirements (deterministic and fail-fast)
Every temporary execution `.ps1` MUST start with:

1. Strict/fail-fast defaults:

* `Set-StrictMode -Version Latest`
* `$ErrorActionPreference = 'Stop'`

Repository-root anchoring (mandatory):
The following block is normative: copy it verbatim into every temporary probe; do not rewrite, shorten, or partially implement it (including the CR/LF-only trimming line: do not substitute .Trim() for TrimEnd("`r","`n")).
```powershell
$RepoRoot = (& git rev-parse --show-toplevel).TrimEnd("`r","`n")
# Purpose: remove only the trailing CR/LF from git output; broad whitespace trimming is not intended.
if (-not $RepoRoot) { throw "git rev-parse --show-toplevel returned empty output" }

# Normalize to Windows path separators for deterministic behavior in emitted paths and probes.
$RepoRoot = $RepoRoot.Replace('/','\')
if ($RepoRoot -match '\s') { throw "Repo root contains whitespace; unsupported (move repo to a no-space path)" }
Set-Location -LiteralPath $RepoRoot
```

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

#### Argument-safe patterns

Use argv-safe invocation for external tools (no single mega-string), especially for `git grep` patterns that contain spaces, begin with `-`, or contain `:`.

Example (argv-safe + `git grep` RC normalization):
```powershell
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Host "[probe] git grep Get-LocalGroup -SID"
& git @("grep","-n","-F","-e","Get-LocalGroup -SID","--","BootstrapLocalAdmin.ps1")
if ($LASTEXITCODE -eq 0) { exit 0 }
if ($LASTEXITCODE -eq 1) { exit 0 }  # no matches
exit $LASTEXITCODE
```

Rules:
* Prefer `& tool @("arg1","arg2",...)` (or a `$toolArgs = @(...)` array) over building a command string.
* After every external tool call, inspect `$LASTEXITCODE` and fail-fast unless explicitly normalized.
* Only normalize non-zero codes that are documented (example: `git grep` RC=1 as "no matches").

## Forbidden patterns
The following are forbidden in this repository’s execution workflow:

* Running temporary execution scripts via `-Command` instead of `-File`
* HARD STOP: Any emitted `<line>` invoking `powershell.exe` with `-Command` is forbidden. No exceptions, including read-only viewing, searching, printing line ranges, or formatting output.
* PowerShell in emitted `<line>` is allowed ONLY as the pinned `-File` launcher, never `-Command`.
* Embedding non-trivial PowerShell inside `cmd.exe` quoting layers for logic
* Retrying a failed inline step by adding quoting/escaping due to argv splitting or quoting fragility; switch to Scripted mode immediately instead
* Adding extra steps to “check the previous step” (for example via `if errorlevel`) instead of relying on the step’s exit code
* Any “double wrapping” such as `cmd.exe /c "cmd.exe /c ..."`
* Including `cmd.exe /c` in an emitted step command (the harness already supplies it)
* Building a single command string to execute via a shell inside `.ps1` instead of invoking tools directly
* Creating multiple temporary execution `.ps1` files for one investigation when one probe script would suffice
* Building reusable tooling/frameworks under `.codex_tmp` (for example: `common.ps1`, `helper.ps1`, `*.psm1`, subfolders, or multi-file toolchains)
* Growing a probe across retries into a larger multi-mode tool instead of keeping it a single-use probe
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
- Temporary probes SHOULD prefer stdout/stderr only; exception: write at most ONE diagnostic log file under `.codex_tmp\...` when necessary (for example: `.codex_tmp\tool.log`), with encoding explicitly specified as UTF-8.

Capturing output (diagnostic logs):
- Temporary probes SHOULD use stdout/stderr only.
- Exception: if output must be captured, do it only in Scripted mode and write at most ONE diagnostic log file under `.codex_tmp\...`.
- CMD redirection is forbidden (even when writing under `.codex_tmp`).
- Writing logs under `.codex_tmp` is allowed using `Out-File` / `Set-Content` only when the destination is under `.codex_tmp` and encoding is explicitly specified as UTF-8. (BOM is acceptable for diagnostic logs.)
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
4. Read-only probes are NOT exempt: do not use `powershell.exe -Command` from CMD even for quick checks (ranges/bytes); use Scripted mode with pinned PowerShell 5.1 via `-File`.

Replacement for PowerShell one-liners: create or update exactly one single-use `.ps1` probe under the repo-rooted `.codex_tmp\`, anchor to repo root per this document, perform the viewing/searching/printing inside the `.ps1`, and execute it only via pinned Windows PowerShell 5.1 using `-File` with an absolute repo-rooted path. No nested shells, no command strings, no extra helper scripts.

### Blessed probe primitives
Inline probes (only when inline is allowed by this contract and requires no quoting characters in emitted `<line>`):

* `git status -sb`
* `git diff --`
* `git diff --name-status --`
* `git log -n N -- <path>` (inline-only when `<path>` requires no quoting; otherwise Scripted mode)
* `git rev-parse --show-toplevel`
* `git grep` only in the already-allowed inline forms described elsewhere in this contract (use Scripted mode for all other cases)

Scripted probes (temporary execution `.ps1`):

* Use a single `.ps1` file to run direct tool invocations and minimal processing, without nested shells or building command strings.

### Retry model (bounded; non-escalating)
Inline:
* At most one attempt. If it fails, do not retry inline by adding quoting/escaping; switch to Scripted mode immediately.

Scripted:
* Up to two iterations of the same probe (edit the same `.ps1` and re-run), only if each iteration reduces or keeps complexity flat (simplify, remove parsing, switch to a simpler blessed probe). These iterations are only to simplify/clarify the same probe, not to expand it into a larger multi-mode tool.
* Retries MUST NOT increase complexity: no new files beyond the single probe `.ps1`, no additional shell layers, no metacharacters/redirections, no quoting workarounds, and no environment setup steps (installing tools, downloading dependencies).
* If the probe still fails or results remain ambiguous after the limit, STOP and report: repo root used, probe path, commands invoked, exit code, and the last relevant stdout/stderr summary.

### Search

Preferred:

* `git grep` for tracked files.

Forbidden:

* `findstr` is FORBIDDEN as a search tool in this repository (including as fallback).

Fallback:

* If `git grep` is insufficient, use Scripted mode and run `Select-String` inside a temporary execution `.ps1` (do not use `powershell.exe -Command`).

When interpreting results:

* `git grep` exit code 0 means matches found.
* `git grep` exit code 1 means no matches (NOT an error for search).
* `git grep` exit code >= 2 means an error.

If a probe must branch on grep output, implement it in a temporary execution `.ps1` script and normalize `RC=1` explicitly.

### Viewing file ranges (Scripted mode only)

Viewing file line ranges MUST be done in Scripted mode (temporary execution `.ps1`); inline `powershell.exe -Command ...` mega-strings are forbidden.

Sample script:
```powershell
# .codex_tmp\view.ps1
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$path = "docs\INTERACTION_CONTRACT.md"
$c = Get-Content -LiteralPath $path
$c[55..95]
```

Launcher:
Replace `C:\repo` with the exact value printed earlier by `git rev-parse --show-toplevel`:
```cmd
%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File C:\repo\.codex_tmp\view.ps1
```

`git grep` hardening (prevents option-parsing and argv splitting failures):

* Always separate pattern and paths with `--`.
* In inline mode, always pass the pattern via `-e` (this also prevents leading-dash patterns from being mistaken for options).
* If the pattern contains whitespace or `:`, treat it as a Windows quoting trigger and run the search in Scripted mode (argv-safe; no mega-strings).

Required examples (why inline fails; scripted alternative):

* Pattern `Get-LocalGroup -SID` (contains a space): inline CMD splits the pattern into multiple argv tokens unless you add quoting, and nested quoting under `cmd.exe /c "<line>"` is fragile; use Scripted mode.
* Pattern `-SID` (begins with `-`): allowed inline only in the guarded form `git grep -n -F -e -SID -- <paths...>`; otherwise use Scripted mode.
* Pattern `A: SKIP` (contains `:` and a space): inline CMD quoting is fragile; use Scripted mode.

Forbidden patterns (inline): see `Windows quoting failure triggers (force Scripted mode)` above.

Good (inline, safe for simple patterns):
```cmd
git grep -n -F -e -SID -- BootstrapLocalAdmin.ps1
```

Good (required for fragile patterns: spaces / leading dash / colon):
```powershell
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# .codex_tmp\probe.ps1

& git @("grep","-n","-F","-e","Get-LocalGroup -SID","--","BootstrapLocalAdmin.ps1")
if ($LASTEXITCODE -eq 1) { exit 0 }
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

& git @("grep","-n","-F","-e","-SID","--","BootstrapLocalAdmin.ps1")
if ($LASTEXITCODE -eq 1) { exit 0 }
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

& git @("grep","-n","-F","-e","A: SKIP","--","docs/INTERACTION_CONTRACT.md")
if ($LASTEXITCODE -eq 1) { exit 0 }
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
```

Do not use PowerShell `-Command` from CMD for probes/searches that need `Select-String`, formatting, or pipelines. Move the probe into Scripted mode and execute it via pinned PowerShell `-File`.

### Avoid

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
* Capture and store a baseline workspace state using `git status --porcelain=v1` (read-only, no output redirection to tracked paths).
* `.codex_tmp/` is expected to be ignored by `.gitignore` and MUST NOT appear in porcelain output. If it appears, stop and report that `.gitignore` must include `.codex_tmp/`. Do not attempt to modify `.gitignore` unless explicitly instructed.
* If untracked files appear outside `.codex_tmp`, stop and report them. Do not attempt cleanup unless explicitly instructed.

Tracked-file cleanliness policy depends on task type:
* Read-only probe / smoke test tasks: the baseline porcelain output MUST be identical before and after the probe (no new tracked modifications, and no new untracked files outside `.codex_tmp`).
* Tasks that intentionally edit tracked files: run preflight once at the start (before edits). After edits begin, a dirty working copy is expected. Do not fail solely due to tracked modifications, but do not modify any files outside the task scope.

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
12. No emitted `<line>` invoked `powershell.exe -Command` (PowerShell allowed only via pinned `-File` launcher).
13. No use of `findstr` occurred in probes/searches (including fallback).
