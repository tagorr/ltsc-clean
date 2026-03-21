# Quick Start

## Purpose and Use

Use this document to prepare and run the baseline for the first time. It covers:

- required inputs;
- media preparation;
- installation start;
- expected end state.

## Before You Start  
  
- Use supported Windows 10 LTSC 2021 installation media;  
- Use the `Autounattend.xml` file from this repository and place it at the media root;
- Stage these baseline files under `%WINDIR%\Setup\Scripts`:  
  - `PreOOBE.cmd`  
  - `SetupComplete.cmd`  
  - `BootstrapLocalAdmin.ps1`  
  - `ValidateSecrets.ps1`  
  - `CreatePrimaryAdmin.ps1`  
- Create `%WINDIR%\Setup\Scripts\.primaryadmin.pw`; 
- Follow the secret-handling rules in `docs/OPERATIONS.md`.  

Disk and partition selection remains intentionally manual because `Autounattend.xml` does not define `DiskConfiguration` or `InstallTo*`.

## Run the Installation  
  
- Boot the target machine from the prepared media;  
- Select the intended target disk and partition when Windows Setup prompts for it;  
- Do not interrupt the normal path unless recovery becomes necessary.

## Expected End State

- `primaryadmin` is ready as the permanent local administrator;
- the temporary `bootstrap` account has been disabled;
- the `\L2C\CreatePrimaryAdmin` task has been removed;
- `%WINDIR%\Setup\Scripts\.bootstrap.pw` has been removed;
- `%WINDIR%\Setup\Scripts\.primaryadmin.pw` has been removed;
- temporary Winlogon and logon-policy changes have been restored;
- the system is ready for use, or performs a controlled reboot if one is still required.

## If Normal Completion Does Not Happen

If the flow:

- stops;
- degrades into a manual-login continuation;
- retains temporary artifacts for recovery;

refer to:

- `docs/TROUBLESHOOTING.md` for failure analysis and recovery;
- `docs/OPERATIONS.md` for operator procedures;
- `docs/PIPELINE_FLOW.md` for runtime sequence and handoff logic.
