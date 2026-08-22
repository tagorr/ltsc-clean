# Windows 10 LTSC 2021 Baseline

This repository defines and applies a controlled baseline for Windows 10 Enterprise LTSC 2021, with a clean, quiet and predictable system profile built on supported Microsoft mechanisms.

It uses a staged deployment pipeline that treats continuation, cleanup, and recovery as explicit, verifiable states.

## Key characteristics
  
- **Staged deployment pipeline.** The baseline moves through explicit preparation, orchestration and finalization boundaries instead of relying on one broad setup phase.  
  
- **Gated continuation.** Normal first-logon continuation is armed only after the required validation and handoff conditions succeed in sequence. A completed setup phase does not, by itself, imply a trusted continuation path.  
  
- **Verify-driven cleanup.** Cleanup and teardown are part of completion semantics, not cosmetic follow-up. Temporary state is removed only when restoration and cleanup checks actually verify.  
  
- **Deliberate recovery posture.** If safe finalization cannot be established, the project retains recovery-signaling state for inspection and controlled recovery instead of claiming a falsely clean success.

## Fit and boundaries

This baseline is intended for a specific system and operating context.

Good fit:

- Windows 10 Enterprise LTSC 2021 systems
- standalone or simple-network environments without enterprise integration by default
- operators who want deterministic setup and reviewable outcomes
- workflows where the primary local admin secret is supplied explicitly by the operator

Not a fit:

- general-purpose hardening across arbitrary Windows editions
- convenience-first setups that expect automatic permanent admin credential generation
- enterprise-heavy environments that expect domain-centric onboarding by default
- aggressive debloat workflows that prioritize removal over controlled baseline behavior

## Pipeline at a glance

1. **`Autounattend.xml`** sets a narrow unattended entry and shapes the OOBE path.

2. **`PreOOBE.cmd`** prepares early machine state before the user logon boundary.

3. **`SetupComplete.cmd`** applies the baseline, invokes the retained `ConfigureDefenderPrivacy.ps1` component, checks the required continuation conditions, and prepares the finalization handoff.

4. **`CreatePrimaryAdmin.ps1`** completes permanent admin finalization, then either tears down temporary state or preserves recovery-signaling state.

## Start here

1. Confirm that your system and environment fit the supported LTSC baseline.
2. Follow [Quick Start](docs/QUICK_START.md) for the initial setup path.
3. Go to [Operations](docs/OPERATIONS.md) for post-run checks and operator handling.

## Documentation map

- [Guide](docs/GUIDE.md) - documentation guide and reading map
- [Quick Start](docs/QUICK_START.md) - minimal setup path
- [Pipeline Flow](docs/PIPELINE_FLOW.md) - runtime sequence and stage flow
- [Operations](docs/OPERATIONS.md) and [Troubleshooting](docs/TROUBLESHOOTING.md) - operations, troubleshooting and recovery guidance
- [Security](SECURITY.md) and [Decisions](DECISIONS.md) - security posture, design rationale and trade-offs
- [Validation](docs/VALIDATION.md) and [Audit Checklist](docs/AUDIT_CHECKLIST.md) - validation and audit checks

## Key trade-offs

These baseline decisions come with explicit trade-offs:

- SmartScreen policy layers are disabled, reducing prompts and reputation-based checks at the cost of SmartScreen-based protection.
- Microsoft Defender local protections remain enabled. The retained privacy component configures cloud/MAPS and automatic sample submission off, and reports a non-fatal warning when the point-in-time effective posture cannot be verified; see [Operations](docs/OPERATIONS.md) for post-deployment verification and remediation.
- Automatic component cleanup is not forced, preserving predictability and reversibility at the cost of a larger system footprint.
- With WPAD disabled, proxy configuration must be made explicitly later.

## Contributing

For repository changes, start with [Contributing](CONTRIBUTING.md).

For Codex CLI or other agent-assisted work, follow [AGENTS.md](AGENTS.md) and the [Interaction Contract](docs/INTERACTION_CONTRACT.md).

## License

MIT License
