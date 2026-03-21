# Documentation Guide

## Purpose and Use

Use this document as the guide to the repository documentation set. If you are new to the repository, start with the root `README.md`, then return here to find the right document for your task.

This guide points you to the right document; it does not replace the documents themselves. The linked documents remain the canonical sources for setup, runtime flow, operations, troubleshooting, security, design rationale, audit work, and contribution rules.

## Document Map

### Core workflow documents

#### `docs/QUICK_START.md`
Read this first for the minimal practical path through a first run.

It covers required inputs, installation start, and smoke-level confirmation that the baseline reached the expected end state.

#### `docs/PIPELINE_FLOW.md`
Read this to understand the intended happy-path runtime sequence.

It explains stage boundaries, handoffs, continuation logic, and completion semantics across the happy-path flow.

#### `docs/OPERATIONS.md`
Read this for operator procedures and evidence handling.

It covers preparation, secret handling, current-run evidence, retained artifacts, manual continuation boundaries, and post-run verification.

#### `docs/TROUBLESHOOTING.md`
Read this when the run does not complete as expected.

It is organized around symptoms, likely causes, evidence anchors, and next diagnostic steps for failed, incomplete, or degraded runs.

#### `docs/ARCHITECTURE.md`
Read this for the high-level system model behind the baseline.

It covers the major components, trust boundaries, and invariants that shape the implementation without repeating the full stage-by-stage flow.

#### `docs/VALIDATION.md`
Read this before opening a PR for a behavior-affecting change.

It covers practical validation scope, runtime evidence, and smoke-level scenarios for proving that the changed path still behaves as intended.

#### `docs/AUDIT_CHECKLIST.md`
Read this for repository, design, and contract audit work.

It covers repository invariants, staged execution contracts, ownership boundaries, fail-closed behavior, and contract-bearing documentation claims.

### Project reference documents

#### `SECURITY.md`
Read this for the canonical security view of the project.

It covers secret handling, threat boundaries, guarantees, limitations, and security assumptions that should not be inferred only from flow or operational documents.

#### `DECISIONS.md`
Read this to understand why the project is designed the way it is.

It records key design choices, trade-offs, and explicit non-goals that define the project boundary.

#### `CONTRIBUTING.md`
Read this when you want to make repository changes responsibly.

It covers contribution rules, maintenance expectations, and documentation responsibilities that come with code or behavior changes.