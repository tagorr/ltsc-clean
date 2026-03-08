# Operations

This document is the operator-facing runbook for normal execution, routine verification, and controlled manual actions. It should support repeatable use without becoming a design document.

## Intended Use

Use this file during planned execution, reruns, manual verification, and operator-maintained recovery steps that are part of normal repository practice.

## Runbook Structure

### Preparation

Cover the operator-owned inputs, media/image placement expectations, and environment checks needed before execution.

### Normal Execution

Describe the standard execution path and where the operator is expected to observe logs or checkpoints.

### Verification

Collect the routine post-run checks that confirm the baseline reached the intended state.

### Manual Recovery Actions

Capture the bounded operator actions that are part of supported recovery or repeat-validation workflows.

### Evidence Collection

Identify the primary logs and artifacts to preserve when a run needs review.

## Scope Boundary

This file is a runbook, not a symptom index and not a narrative of internal design decisions. Deep rationale stays in `docs/ARCHITECTURE.md`; symptom-led diagnosis stays in `docs/TROUBLESHOOTING.md`.
