# Pipeline Flow

This document describes the successful unattended happy path by stage. Its purpose is to show the intended sequence, hand-offs, and completion conditions without turning into a troubleshooting catalog.

## Intended Use

Use this file when you need to understand what should happen, in order, during a normal run from setup through Stage B completion.

## Stage Outline

### Media And Setup Entry

Capture the high-level role of `Autounattend.xml` and the setup hand-off into `PreOOBE.cmd`.

### PreOOBE

Summarize the specialize-phase bootstrap work and its output artifacts.

### SetupComplete

Summarize servicing, secret validation, Stage B gateway decisions, and reboot-flag signaling.

### First Logon And Stage B

Summarize Stage A and Stage B in the normal path, including the final cleanup and controlled reboot decision point.

### End State

Describe the expected steady-state result after a successful normal run.

## Scope Boundary

This file covers the happy path only. Failure analysis, operator recovery, and low-level invariant reasoning belong in `docs/TROUBLESHOOTING.md`, `docs/OPERATIONS.md`, and `docs/ARCHITECTURE.md`.
