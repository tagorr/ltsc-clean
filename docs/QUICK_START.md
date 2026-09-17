# Quick Start

## Purpose and Use

Use this document to prepare and run the baseline for the first time. It covers:

- required inputs;
- media preparation;
- installation start;
- expected end state.

## Before You Start  
  
- Use supported Windows 11 Enterprise LTSC 2024 installation media;
- Prepare the selected image offline with Defender Tamper Protection Off; see [Operations](OPERATIONS.md) for details;
- Place `Autounattend.xml` at the media root;
- Stage these baseline files under `%WINDIR%\Setup\Scripts`:  
  - `PreOOBE.cmd`  
  - `SetupComplete.cmd`  
  - `BootstrapLocalAdmin.ps1`  
  - `ConfigureDefenderPrivacy.ps1`
  - `ValidateSecrets.ps1`  
  - `CreatePrimaryAdmin.ps1`  
  - `BaselinePolicies.txt`
- Stage a trusted Microsoft `LGPO.exe` as `%WINDIR%\Setup\Scripts\LGPO.exe`; it is operator-supplied and not included in the repository;
- Create `%WINDIR%\Setup\Scripts\.primaryadmin.pw`; see [Operations](OPERATIONS.md) for secret-handling details;

Disk and partition selection remains intentionally manual because `Autounattend.xml` does not define `DiskConfiguration` or `InstallTo*`.

## Run the Installation  
  
- Boot the target machine from the prepared media;  
- Select the intended target disk and partition when Windows Setup prompts for it;  
- Do not interrupt the normal path unless recovery becomes necessary.

## Expected End State

- `primaryadmin` is ready as the permanent local administrator;
- the temporary `bootstrap` account is disabled and deployment secret files are removed;
- Microsoft Defender Antivirus remains enabled with real-time, On-Access, IOAV, and applicable NIS protection; Tamper Protection and Behavior Monitoring are off;
- temporary logon changes are restored; after the one required final controlled reboot, which ends the temporary interactive `bootstrap` logon session, the normal Windows sign-in screen is shown for manual `primaryadmin` sign-in.

## If Normal Completion Does Not Happen

If the flow:

- stops;
- degrades into a manual-login continuation;
- retains temporary artifacts for recovery;

refer to:

- [Troubleshooting](TROUBLESHOOTING.md) for failure analysis and recovery;
- [Operations](OPERATIONS.md) for operator procedures;
- [Pipeline Flow](PIPELINE_FLOW.md) for runtime sequence and handoff logic.
