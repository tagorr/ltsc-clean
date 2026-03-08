# Architecture

This document describes the high-level system model for the LTSC clean baseline. It should explain the major components, boundaries, and invariants that shape the implementation without duplicating the runbook.

## Intended Use

Use this file when you need to understand why the pipeline is structured the way it is, which stage owns which decision, and which invariants must remain stable across future changes.

## Model

### Components

Identify the main scripts, secrets, logs, and scheduled-task hand-offs that make up the baseline.

### Stage Boundaries

Describe what belongs to `PreOOBE.cmd`, `SetupComplete.cmd`, and `CreatePrimaryAdmin.ps1`, and what each stage must not do.

### Control Gates

Describe the major gating points such as edition checks, secret validation, Stage B scheduling, and reboot signaling.

### Invariants

Describe the cross-cutting rules that must remain true, such as the Panther flag reboot model, fail-closed secret handling, and explicit final-state cleanup.

### Documentation Boundaries

Record how this file differs from `docs/PIPELINE_FLOW.md`, `docs/OPERATIONS.md`, and `docs/TROUBLESHOOTING.md`.

## Scope Boundary

This file is architectural context, not an execution checklist. Step-by-step procedures and symptom-led diagnosis belong in the runbook and troubleshooting documents.
