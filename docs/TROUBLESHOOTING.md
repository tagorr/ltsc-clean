# Troubleshooting

This document is the symptom-based diagnostic guide for runs that did not reach the expected normal state. It should help an operator move from an observed problem to the next concrete check.

## Intended Use

Use this file when the pipeline stalls, exits early, lands in recovery, or leaves the machine in an unexpected post-run state.

## Diagnostic Entry Points

### Bootstrap Or PreOOBE Problems

Group symptoms that appear before `SetupComplete.cmd` becomes the main source of truth.

### SetupComplete Gate Or Servicing Problems

Group symptoms related to DISM servicing, secret validation, Stage B scheduling, and reboot-flag decisions.

### First-Logon Or Stage B Problems

Group symptoms related to `CreatePrimaryAdmin.ps1`, teardown suppression, and final-state verification failures.

### Residual State Problems

Group symptoms where the machine is usable but cleanup, reboot handling, or verification is incomplete.

## Diagnostic Method

Keep the structure symptom-first: observed behavior, primary log to inspect, likely boundary involved, and immediate next step.

## Scope Boundary

This file is for diagnosis and next actions. It should not become the full happy-path walkthrough or a general architecture explanation.
