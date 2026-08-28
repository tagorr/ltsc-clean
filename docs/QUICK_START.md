# Quick Start

## Purpose and Use

Use this document to prepare and run the baseline for the first time. It covers:

- required inputs;
- media preparation;
- installation start;
- expected end state.

## Before You Start  
  
- Use supported Windows 11 Enterprise LTSC 2024 installation media;
- Use the `Autounattend.xml` file from this repository and place it at the media root;
- Stage these baseline files under `%WINDIR%\Setup\Scripts`:  
  - `PreOOBE.cmd`  
  - `SetupComplete.cmd`  
  - `BootstrapLocalAdmin.ps1`  
  - `ConfigureDefenderPrivacy.ps1`
  - `ValidateSecrets.ps1`  
  - `CreatePrimaryAdmin.ps1`  
  - `UserBaselinePolicies.txt`
- Stage a trusted Microsoft `LGPO.exe` as `%WINDIR%\Setup\Scripts\LGPO.exe`; it is operator-supplied and is not tracked or automatically acquired by this repository;
- Create `%WINDIR%\Setup\Scripts\.primaryadmin.pw`; 
- Follow the secret-handling rules in [Operations](OPERATIONS.md).  

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
- `%WINDIR%\Setup\Scripts\ConfigureDefenderPrivacy.ps1` remains available for elevated post-deployment verification or remediation;
- Microsoft Defender Antivirus and its local protections remain enabled;
- after the normal provisioning reboot, the final Defender privacy state is checked as described in [Operations](OPERATIONS.md); a SetupComplete Defender privacy hardening warning does not by itself mean deployment failed;
- temporary Winlogon and logon-policy changes have been restored;
- after successful Stage B provisioning and teardown, the existing controlled reboot is requested when still required; successful teardown does not prove that Windows accepted the shutdown request. A failed request remains visible through the Stage B result (which can be RC 8) and the retained Panther marker when restoration is verified; after an accepted reboot, the normal Windows sign-in screen is shown and `primaryadmin` is signed in manually.

## If Normal Completion Does Not Happen

If the flow:

- stops;
- degrades into a manual-login continuation;
- retains temporary artifacts for recovery;

refer to:

- [Troubleshooting](TROUBLESHOOTING.md) for failure analysis and recovery;
- [Operations](OPERATIONS.md) for operator procedures;
- [Pipeline Flow](PIPELINE_FLOW.md) for runtime sequence and handoff logic.
