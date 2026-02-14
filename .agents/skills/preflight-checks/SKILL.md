---
name: Preflight Checks (LTSC clean)
description: Run tools/preflight.ps1 before proposing or finalizing repo changes to validate static guardrails.
---

Read and follow AGENTS.md and docs/INTERACTION_CONTRACT.md.

# Preflight Checks (LTSC clean)

Run the repo preflight script from the repository root before proposing edits or finalizing changes.

## When to use

- After changing deployment scripts or core runbook documentation, before finalizing.
- Before proposing changes in this repository.

## What it checks

- Parse-only PowerShell validation for `BootstrapLocalAdmin.ps1`, `CreatePrimaryAdmin.ps1`, and `ValidateSecrets.ps1`.
- Required recovery/log anchor strings (preferred docs first, then tracked text files).
- Working tree summary and a conservative heuristic guardrail for potential flow-control edits (skips with INFO if git is unavailable).

## Run

- `%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File tools\preflight.ps1`

## Output expectations

- Deterministic `PASS`/`FAIL` lines per check.
- Exit code `0` when all checks pass, `1` when any check fails.
