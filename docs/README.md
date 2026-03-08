# Documentation Map

This directory holds the deep documentation for the LTSC clean baseline. The root `README.md` remains the public front door; `docs/README.md` is the internal reading map for operators and contributors who need to go deeper.

## Use This Index

Read this file first when you know the topic you need, but not yet the right document. Each file under `docs/` has a distinct role and should stay focused on that role.

## By Audience

### New reader

Start at the root `README.md`, then use `docs/QUICK_START.md` for the first practical run.

### Operator

Use `docs/OPERATIONS.md` for routine execution and verification, and `docs/TROUBLESHOOTING.md` when the observed result does not match the expected flow.

### Reviewer or maintainer

Use `docs/PIPELINE_FLOW.md` for the unattended happy path and `docs/ARCHITECTURE.md` for system boundaries, invariants, and design intent.

## By Task

### First smoke path

`docs/QUICK_START.md`

### Understand the unattended sequence

`docs/PIPELINE_FLOW.md`

### Run or verify the baseline

`docs/OPERATIONS.md`

### Diagnose a failure or unexpected state

`docs/TROUBLESHOOTING.md`

### Understand the model and constraints

`docs/ARCHITECTURE.md`

## Scope Boundary

This file is an index only. It should not become a second root `README.md`, a runbook, or a duplicate of the architecture and troubleshooting documents.
