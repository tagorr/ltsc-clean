---
name: Preflight Checks (LTSC clean)
description: Run tools/preflight.ps1 after tracked edits or for PR readiness to validate static repository invariants.
---

Read and follow AGENTS.md and docs/INTERACTION_CONTRACT.md.

# Preflight Checks (LTSC clean)

Use the repository preflight as static repository and PR-readiness validation. It does not replace runtime validation required by `docs/VALIDATION.md`.

## When to use

- When explicitly requested by the Owner.
- After relevant tracked edits, before finalizing the change.
- During PR-readiness validation and before opening a PR.

Do not require preflight before read-only analysis, design proposals, or the start of every edit.

## What it checks

- Git worktree and comparison-base prerequisites.
- Windows PowerShell 5.1 parse-only validation for the tracked runtime PowerShell scripts.
- Committed branch-delta and current tracked working-tree `git diff --check` coverage.
- Tracked-file EOL, UTF-8/BOM/NUL, and script ASCII invariants.
- Tracked and untracked `.codex_tmp` status plus concise working-tree information.

## Run

- `%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File tools\preflight.ps1`

This launcher selects Windows PowerShell 5.1 so parser checks use the repository's supported runtime. It is not a general shell requirement for Codex.

## Output expectations

- Deterministic `PASS`/`FAIL` lines per check.
- Exit code `0` when all checks pass, `1` when any check fails.
