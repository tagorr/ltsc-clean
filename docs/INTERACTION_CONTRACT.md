# Codex CLI Interaction Contract

This document defines repository-specific operation safety and integrity requirements for Codex. It does not prescribe a shell or command-execution transport.

## Scope and working-tree integrity

1. Work within the repository root and only on paths authorized for the current task under the prompt and the scope model in `AGENTS.md`, including any exact-path Owner exception.
2. Do not operate inside `.git` and do not write anything into `.git`.
3. Before mutating repository content, inspect enough working-tree state to identify relevant pre-existing changes and confirm the intended task scope.
4. Treat pre-existing changes as owner work. Do not overwrite, discard, revert, reformat, or otherwise disturb unrelated changes.
5. Keep changes minimal and confined to the authorized task. Do not create files outside the authorized paths except for temporary artifacts permitted below.

## Temporary artifacts

* Create Codex temporary files only under the repository root's `.codex_tmp\` directory, and only when they are genuinely needed for the current task.
* Keep temporary artifacts minimal, narrowly scoped, untracked, and free of secrets, tokens, passwords, credentials, or other secret values. They must never be committed.
* Remove temporary files when they are no longer needed. Cleanup must target the exact known files; do not use wildcards, recursive deletion, or broad directory deletion.
* Failure alone is not a reason to retain a reconstructible temporary artifact.
* A temporary artifact may be retained only when it preserves useful diagnostic evidence that would otherwise be lost or materially difficult to reconstruct. If retained, keep it under `.codex_tmp\` and report its exact path and the reason for retaining it.

## Tracked-file integrity

The detailed tracked-file format rules in `AGENTS.md` are normative:

* Preserve the encoding, line-ending, BOM, NUL, and ASCII requirements defined there.
* Use an editing method that preserves the required encoding and line endings. Do not write tracked files through a mechanism whose encoding or line-ending behavior is ambiguous or uncontrolled.

## Git safety

* Do not perform state-changing Git operations; the Owner performs commit, push, PR, and merge actions.

## Validation and completion

* Run checks required by repository instructions and the smallest additional validation that covers the actual change and its risk surface.
* Validation must not modify tracked files or leave unexpected artifacts.
* Before declaring completion, confirm:
  1. Only authorized tracked files changed.
  2. Pre-existing owner work and unrelated changes remain intact.
  3. Modified tracked files satisfy the repository's encoding, line-ending, BOM, NUL, and ASCII requirements.
  4. Required and proportionate validation passed, or any failure is reported accurately.
  5. No unexpected temporary or untracked artifacts remain; any deliberately retained artifact is under `.codex_tmp\` and is reported with its exact path and reason.

## Output and secret handling

* Never expose secrets, tokens, passwords, credentials, or other secret values in commands, temporary artifacts, diagnostic output, diffs, or reports.
