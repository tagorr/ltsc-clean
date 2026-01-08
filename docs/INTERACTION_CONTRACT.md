# Codex CLI Interaction Contract

This repository uses Codex CLI as the sole automation agent. Follow these rules precisely.

## Scope and shells
1. Work from the repository root, never inside `.git`.
2. Choose the shell per step (shell-by-task policy; one step = one process):
   - CMD step: use for `.cmd/.bat` semantics, CMD built-ins, and simple commands where CMD parsing is safe. Run as `cmd.exe /c "..."` with exactly one outer pair of ASCII double quotes (no extra outer layers). Avoid CMD pipes and command chaining (`|`, `&`, `&&`, `||`) and nested quoting; redirections like `>`, `2>`, and `2>&1` are OK for diagnostics/probes and `.git_...` temp files. If escaping/complex parsing would be required (for example heavy `%` expansion or caret escaping), prefer a PowerShell step.
   - PowerShell step: use Windows PowerShell 5.1 as the outer shell when CMD parsing is brittle (search, regex, quoting-heavy commands, structured parsing, pipelines/metacharacters). Keep steps short and reproducible; avoid long inline `-Command` blobs. If logic is non-trivial or `-Command` becomes too long/fragile, prefer a tiny temporary script named `.git_...` in the repository root and invoke it.
3. PowerShell steps MUST invoke Windows PowerShell 5.1 by full path:  
   `%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -NonInteractive ...`

## Invariants
1. In command lines/code blocks: ASCII double quotes only. No typographic quotes. No single quotes in the CMD layer (`cmd.exe /c "..."`).
   Clarification: this ban applies to the CMD portion only; inside PowerShell `-Command` the script may use `'...'`.
2. No `EnableDelayedExpansion` in `.cmd`.
3. Minimal diffs. Do not change text outside edited hunks.
4. File formats:  
   - Markdown `*.md`: LF line endings.  
   - Scripts `.cmd/.bat/.ps1`: CRLF.  
   - UTF-8 without BOM everywhere.
5. Command length must fit the Windows command-line limit, roughly 8191 characters for `cmd.exe`.
6. Do not use `echo` or output redirection (`>`, `>>`, `2>`, `2>&1`) to generate or modify repository source files (especially tracked files). Output redirection to temporary diagnostic/probe files named `.git_...` in the repository root is allowed.
7. One command per fenced code block. No shell prompt prefixes inside code blocks.
8. Fenced code blocks MUST declare language identifiers: use `cmd` for CMD, `powershell` for PowerShell, `diff` for patches.
9. Placeholders use `<PLACEHOLDER>` in UPPERCASE. Do not use `{}` or non-ASCII symbols for placeholders.
10. Prefer single-line commands ≤ 120 characters; if longer, split into sequential steps or (for PowerShell) use a tiny temporary script named `.git_...` in the repository root.

## Execution model
1. Print a short step marker, then run the command as a separate step. Markers are short and never contain meta characters. Example marker:  
   `cmd.exe /c "echo WRITE docs/INTERACTION_CONTRACT.md"`
   Print the full command only when it is short and safe (no secrets; no quoting soup); otherwise print only the marker.
2. Abort on any non-zero exit code by default.
   - Exception (search/probes): `git grep` (and optional `rg`) return `1` for “no matches”; treat `RC=1` as OK and `RC>=2` as an error. Empty output is a valid outcome; do not retry/debug-loop solely because output is empty or `RC=1`.
   - Do not add a separate `cmd.exe /c "if errorlevel ..."` step to “check the previous step”; rely on the step’s process exit code (the harness reports it).
   - In PowerShell steps, check `$LASTEXITCODE` after external tools and `if(-not $?) { exit 1 }` after internal operations.
3. Do not rely on environment variables across steps. Each step is a new process. If you need data across steps, use files. If a step depends on a specific directory, make `cd` an explicit separate step or use explicit paths.
4. Markers and commit messages SHOULD be ASCII-only (to avoid console encoding issues).
5. Do not chain commands with `&&`, `&`, or `||` (command separators). Redirections like `2>&1` are OK. Split actions into separate steps. Use the multi-step patterns from Diagnostics.

## Git safety
### Preflight: clean working copy

Before any changes, ensure the working copy is clean (or only contains intended paths for this step):

```cmd
cmd.exe /c "git status --porcelain=v1 > .git_stat"
```

```cmd
cmd.exe /c "for %G in (.git_stat) do if %~zG NEQ 0 exit /b 1"
```

```cmd
cmd.exe /c "del /q .git_stat"
```

1. Never call Git from inside `.git` or its subfolders.

Temporary files named `.git_...` in the repository root are allowed, but never execute Git from inside `.git` or its subfolders.

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
1. For search/probe tools, `RC=1` on “no matches” is acceptable. Print `(no matches)` and continue, without masking other errors.
   - Search exit codes: `git grep` (and optional `rg`) `RC=0` = matches, `RC=1` = no matches (OK), `RC>=2` = error.
   - Default repo search: prefer `git grep` scoped to explicit paths; prefer fixed strings (`-F`) unless regex is required; avoid whole-tree filesystem scans unless paths are explicitly narrowed.
   - Tracked vs untracked: `git grep` searches tracked files by default. If you need to search an untracked file (for example a draft/copy), do not assume empty output means `git grep` is broken.
   - Untracked fallback (repo-local, explicit file paths only): prefer `git grep --no-index` with explicit file paths only (not directories), or a PowerShell step using `Select-String` scoped to a single explicit file (no recursive scans).
2. Check tool presence before use where applicable. Example for ripgrep (informational probe; exits 0 either way):

```powershell
%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -NonInteractive -Command "$c=Get-Command rg -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1; if($c){'rg found: ' + $c.Source}else{'rg not found'}; exit 0"
```

3. Do not print or echo complex command lines. Always print a short marker; print the full command only when it is short and safe.

## Logging and secrecy
1. Before every step print the working directory and a short marker. Do not print secrets, tokens or passwords. For sensitive actions, print only the marker.
2. If any step fails, stop immediately. Do not “fix” by inventing unprinted commands.

## Forbidden actions
1. No Git calls in `.git`.  
2. No single quotes in any `cmd.exe /c` line.  
3. No extra quote layers around whole commands.  
4. No delayed expansion.  
5. Do not touch files not listed in the plan.  
6. Do not mask non-zero exit codes (except the explicit search/probe “no matches” (`RC=1`) normalization pattern).  
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


### 2) Commit without env vars
Marker:  
```cmd
cmd.exe /c "echo COMMIT contract update"
```
Run:  
```cmd
cmd.exe /c "git commit -m \"docs(contract): update interaction contract\""
```


### 3) Diagnostic probe with git grep (preferred)
Marker:  
```cmd
cmd.exe /c "echo PROBE heading in AGENTS.md"
```
Preferred (PowerShell step; normalizes `RC=1` to success):
```powershell
%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -NonInteractive -Command "$text='<TEXT>'; $paths=@('<PATH>'); git grep -n -F -- $text -- $paths; $rc=$LASTEXITCODE; if($rc -eq 1){'(no matches)'; exit 0}; if($rc -ge 2){exit $rc}; exit 0"
```
If the PowerShell `-Command` becomes too long/fragile, write a tiny temporary script named `.git_...` in the repository root (use simple PowerShell file-write methods; avoid CMD metacharacter escaping), invoke it as a PowerShell step, then delete it.
Avoid `Out-File` / `Set-Content -Encoding utf8` defaults (BOM). Prefer `git grep` over recursive filesystem scans.
Simple (CMD step; if `<TEXT>` contains quotes/regex/backslashes, prefer the PowerShell step):
```cmd
cmd.exe /c "git grep -n -F -- \"<TEXT>\" -- <PATHS>"
```
Optional: `rg` is not required. Use it only when explicitly requested and always constrained to specific files/dirs.


### 4) Validate BOM and NUL bytes (PowerShell one-liner)
*Note: single quotes are allowed inside PowerShell `-Command` text. Single quotes remain forbidden in the CMD layer.*
Marker:  
```cmd
cmd.exe /c "echo VALIDATE BOM/NUL docs/INTERACTION_CONTRACT.md"
```
Run:  
```powershell
%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -NonInteractive -Command "$p='docs\INTERACTION_CONTRACT.md'; $b=[IO.File]::ReadAllBytes($p); if($b.Length -ge 3 -and $b[0]-eq 0xEF -and $b[1]-eq 0xBB -and $b[2]-eq 0xBF){Write-Error 'BOM'; exit 1}; if($b -contains 0){Write-Error 'NUL'; exit 1}; 'OK: no BOM, no NUL'"
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


### 6) Stage specific paths and show staged list
Marker:  
```cmd
cmd.exe /c "echo ADD contract file"
```
Run:  
```cmd
cmd.exe /c "git add -- docs/INTERACTION_CONTRACT.md"
```

Marker:  
```cmd
cmd.exe /c "echo SHOW staged"
```
Run:  
```cmd
cmd.exe /c "git --no-pager diff --cached --name-status --"
```


## Acceptance checklist
1. CMD steps used `cmd.exe /c "..."` with exactly one outer pair of ASCII double quotes (no extra outer layers). PowerShell steps invoked Windows PowerShell 5.1 by full path.
2. No single quotes in the **CMD layer**. Single quotes **are allowed** inside PowerShell `-Command` text. No smart quotes in code blocks/commands.
3. New or modified Markdown files are UTF-8 without BOM and LF, validated by the BOM/NUL one-liner and `git ls-files --eol`.  
4. Git operations executed from repo root, not from `.git`. Work-tree and repo root checks passed.  
5. Staged list shown before commit. Commit done with `-m` or `-F`, no env vars.  
6. Any non-zero exit code stopped the run.
