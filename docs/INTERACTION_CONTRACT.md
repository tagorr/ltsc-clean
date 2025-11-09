# Codex CLI Interaction Contract

This repository uses Codex CLI as the sole automation agent. Follow these rules precisely.

## Scope and shells
1. Work from the repository root, never inside `.git`.
2. Run every step via `cmd.exe /c`. After `/c`, wrap the whole subcommand in a single pair of ASCII double quotes, with no extra outer layers.
3. Windows PowerShell 5.1 may be invoked as a tool only, by its full path:  
   `%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -NonInteractive ...`

## Invariants
1. ASCII double quotes only. No typographic quotes. No single quotes in any `cmd.exe /c` command line, including commit messages.
   Clarification: this ban applies to the CMD portion only; inside PowerShell `-Command` the script may use `'...'`.
2. No `EnableDelayedExpansion` in `.cmd`.
3. Minimal diffs. Do not change text outside edited hunks.
4. File formats:  
   - Markdown `*.md`: LF line endings.  
   - Scripts `.cmd/.bat/.ps1`: CRLF.  
   - UTF-8 without BOM everywhere.
5. Command length must fit the Windows command-line limit, roughly 8191 characters for `cmd.exe`.
6. Do not use `echo`/redirection to generate file contents. Use safe writers only (PowerShell .NET APIs or a patch).
7. One command per fenced code block. No shell prompt prefixes inside code blocks.
8. Fenced code blocks MUST declare language identifiers: use `cmd` for CMD, `powershell` for PowerShell, `diff` for patches.
9. Placeholders use `<PLACEHOLDER>` in UPPERCASE. Do not use `{}` or non-ASCII symbols for placeholders.
10. Prefer single-line commands ≤ 120 characters; if longer, split the action into sequential steps.

## Execution model
1. Print a short step marker, then run the command as a separate step. Markers are short and never contain meta characters. Example marker:  
   `cmd.exe /c "echo WRITE docs/INTERACTION_CONTRACT.md"`
2. Abort on any non-zero exit code.  
   - In CMD steps, do not chain with `||`. Run the command, then a separate check:

```cmd
cmd.exe /c "if errorlevel 1 exit /b 1"
```
  
   - In PowerShell steps, check `$LASTEXITCODE` after external tools and `if(-not $?) { exit 1 }` after internal operations.
3. Do not rely on environment variables across steps. Each `cmd.exe /c` is a new process. If you need data across steps, use files.
4. Markers and commit messages SHOULD be ASCII-only (to avoid console encoding issues).
5. Do not chain with `&&`, `&`, or `||`. Split actions into separate steps. Use the multi-step patterns from Diagnostics.

## Git safety
### Preflight: clean working copy

Before any changes, ensure the working copy is clean (or only contains intended paths for this step):

```cmd
cmd.exe /c "git status --porcelain=v1 > .git\_stat"
```

```cmd
cmd.exe /c "for %G in (.git\_stat) do if %~zG NEQ 0 exit /b 1"
```

```cmd
cmd.exe /c "del /q .git\_stat"
```

1. Never call Git from inside `.git` or its subfolders.

Temporary files under `.git\...` are allowed, but never execute Git from those folders.

2. Work on a feature branch. Use forward slashes `/` in Git path arguments. Always separate paths with `--` in Git commands.
3. Before Git operations, verify you are in a working tree and at the repo root:  
   - `cmd.exe /c "git rev-parse --is-inside-work-tree"` must print `true`.  
   - `cmd.exe /c "git rev-parse --show-toplevel"` must equal `%CD%`; otherwise stop.
4. Stage only intended paths:  
   `cmd.exe /c "git add -- docs/INTERACTION_CONTRACT.md"`
5. Before committing, show staged changes with pager disabled:  
   `cmd.exe /c "git --no-pager diff --cached --name-status --"`
6. Commit without env vars. Use `-m "..."` or `-F <file>`. Always double quotes for `-m`. If you need quotes inside the message, escape them as `\"`.

## EOL and encoding policy
1. For Markdown, verify LF both in index and working tree:  
   `cmd.exe /c "git ls-files --eol -- docs/INTERACTION_CONTRACT.md"`  
   Expect `i/lf w/lf`.
2. Do not use `Out-File` or `Set-Content -Encoding utf8` on PowerShell 5.1, they emit BOM. To write text files use .NET APIs:  
   `[System.IO.File]::WriteAllText($path, $text, [System.Text.UTF8Encoding]::new($false))`
3. Validation order for newly written text files:  
   1) Write the file.  
   2) Validate BOM and NUL.  
   3) Stage the file.  
   4) Verify EOL via `git ls-files --eol`.
4. BOM and NUL validation is mandatory:  
   - First three bytes are not `EF BB BF`.  
   - No `0x00` bytes present.

Additionally, confirm `.gitattributes` applies the expected rule:

```cmd
cmd.exe /c "git check-attr eol -- docs/INTERACTION_CONTRACT.md"
```
_Expect: `eol: lf`._

## Command block formatting
1. Use fenced code blocks with language identifiers for every command.
2. Do not include shell prompts like `PS C:\>` or `C:\>`.
3. Keep commands ASCII-only; avoid curly quotes and non-ASCII punctuation.
4. Use forward slashes `/` in Git paths; backslashes `\` are allowed in PowerShell strings.
5. Marker and Run remain separate blocks.

## Diagnostics and probes
1. Tools that return `1` on “no matches” must be softened. Print `(no matches)` and continue, without masking other errors.
2. Check tool presence before use where applicable. Example for ripgrep:  
   Use a simple multi-step check without chaining:

```cmd
cmd.exe /c "where rg > .git\_rg_present 2>&1"
```
```cmd
cmd.exe /c "for %G in (.git\_rg_present) do if %~zG EQU 0 echo rg not found"
```
```cmd
cmd.exe /c "del /q .git\_rg_present"
```

3. Do not print or echo complex command lines. Use short markers only.

## Logging and secrecy
1. Before every step print the working directory and a short marker. Do not print secrets, tokens or passwords. For sensitive actions, print only the marker.
2. If any step fails, stop immediately. Do not “fix” by inventing unprinted commands.

## Forbidden actions
1. No Git calls in `.git`.  
2. No single quotes in any `cmd.exe /c` line.  
3. No extra quote layers around whole commands.  
4. No delayed expansion.  
5. Do not touch files not listed in the plan.  
6. Do not mask non-zero exit codes (except the explicit “no matches” pattern).  
7. Do not change EOL or encoding against policy.  
8. Do not execute commands that were not preceded by a marker.

## Safe patterns (examples)


### 1) Print marker, then run a simple command
Marker:  
```cmd
cmd.exe /c "echo STATUS short"
```

Run:  
```cmd
cmd.exe /c "git status -s"
```

```cmd
cmd.exe /c "if errorlevel 1 exit /b 1"
```


### 2) Commit without env vars
Marker:  
```cmd
cmd.exe /c "echo COMMIT contract update"
```
Run:  
```cmd
cmd.exe /c "git commit -m \"docs(contract): update interaction contract\""
```

```cmd
cmd.exe /c "if errorlevel 1 exit /b 1"
```


### 3) Diagnostic probe with ripgrep softened
Marker:  
```cmd
cmd.exe /c "echo PROBE heading in AGENTS.md"
```
Run (4 atomic steps, no `&`/`&&`):
```cmd
cmd.exe /c "rg --line-number \"^## \" AGENTS.md > .git\_rg 2>&1"
```
```cmd
cmd.exe /c "for %G in (.git\_rg) do if %~zG EQU 0 echo (no matches) > .git\_rg"
```
```cmd
cmd.exe /c "type .git\_rg"
```
```cmd
cmd.exe /c "del /q .git\_rg"
```


### 4) Validate BOM and NUL bytes (PowerShell one-liner)
*Note: single quotes inside the PowerShell `-Command` text below are part of PowerShell syntax and do **not** violate the “no single quotes in CMD” rule.*
Marker:  
```cmd
cmd.exe /c "echo VALIDATE BOM/NUL docs/INTERACTION_CONTRACT.md"
```
Run:  
```cmd
cmd.exe /c "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -Command "$p='docs\INTERACTION_CONTRACT.md'; $b=[IO.File]::ReadAllBytes($p); if($b.Length -ge 3 -and $b[0]-eq 0xEF -and $b[1]-eq 0xBB -and $b[2]-eq 0xBF){Write-Error 'BOM'; exit 1}; if($b -contains 0){Write-Error 'NUL'; exit 1}; 'OK: no BOM, no NUL'"
```

### 5) Verify LF in index and working tree
Marker:  
```cmd
cmd.exe /c "echo VERIFY EOL docs/INTERACTION_CONTRACT.md"
```
Run:  
```cmd
cmd.exe /c "git ls-files --eol -- docs/INTERACTION_CONTRACT.md"
```

```cmd
cmd.exe /c "if errorlevel 1 exit /b 1"
```


### 6) Stage specific paths and show staged list
Marker:  
```cmd
cmd.exe /c "echo ADD contract file"
```
Run:  
```cmd
cmd.exe /c "git add -- docs/INTERACTION_CONTRACT.md"
```

```cmd
cmd.exe /c "if errorlevel 1 exit /b 1"
```

Marker:  
```cmd
cmd.exe /c "echo SHOW staged"
```
Run:  
```cmd
cmd.exe /c "git --no-pager diff --cached --name-status --"
```

```cmd
cmd.exe /c "if errorlevel 1 exit /b 1"
```


## Acceptance checklist
1. Every **CMD** invocation used `cmd.exe /c "..."` with exactly one outer pair of ASCII double quotes (no extra outer layers).
2. No single quotes in the **CMD layer**. Single quotes **are allowed** inside PowerShell `-Command` text. No smart quotes anywhere.
3. New or modified Markdown files are UTF-8 without BOM and LF, validated by the BOM/NUL one-liner and `git ls-files --eol`.  
4. Git operations executed from repo root, not from `.git`. Work-tree and repo root checks passed.  
5. Staged list shown before commit. Commit done with `-m` or `-F`, no env vars.  
6. Any non-zero exit code stopped the run.
