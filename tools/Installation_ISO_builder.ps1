#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$SourceWin,
    [string]$RepoRoot,
    [string]$LGPOExe,
    [string]$OutputIso,
    [string]$WorkRoot,
    [string]$OscdimgPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-BuildLog([string]$Message) {
    $line = '{0} {1}' -f [DateTime]::Now.ToString('s'), $Message
    # Detailed timestamped diagnostics belong in the file, not the console.
    if ($script:Build.Log) {
        [IO.File]::AppendAllText($script:Build.Log, $line + "`r`n", [Text.UTF8Encoding]::new($false))
    }
}

function Write-BuildBanner([string]$Title) {
    Write-Host ''
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host ('  ' + $Title) -ForegroundColor Cyan
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host ''
    Write-BuildLog $Title
}

function Write-BuildPhase([int]$Number, [string]$Title) {
    Write-Host ''
    $message = '--- PHASE {0}: {1} ---' -f $Number, $Title
    Write-Host $message -ForegroundColor Yellow
    Write-Host ''
    Write-BuildLog $message
}

function Write-BuildStep([int]$Number, [string]$Message, [switch]$Done) {
    $text = '[{0}/8] {1}' -f $Number, $Message
    if ($Done) {
        Write-Host ($text + ' ') -NoNewline
        Write-Host 'DONE' -ForegroundColor Green
        Write-BuildLog ($text + ' DONE')
    } else {
        Write-Host $text -ForegroundColor Yellow
        Write-BuildLog $text
    }
}

function Get-OutputIsoPath([string]$Value) {
    if (-not [string]::IsNullOrWhiteSpace($Value)) {
        return (Get-LocalPath $Value 'Full output ISO path (including filename)')
    }
    while ($true) {
        try {
            $folder = Get-LocalPath '' 'Output folder for the ISO (folder must already exist)'
            if (-not (Test-Path -LiteralPath $folder -PathType Container)) {
                throw 'That folder does not exist. Enter an existing folder.'
            }
            break
        } catch { Write-Host $_.Exception.Message -ForegroundColor Yellow }
    }
    while ($true) {
        $name = Read-Host 'ISO filename [LTSC-clean.iso]'
        if ([string]::IsNullOrWhiteSpace($name)) { $name = 'LTSC-clean.iso' }
        $name = $name.Trim()
        if ($name.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or
            $name.EndsWith('.') -or $name -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') {
            Write-Host 'Enter a valid filename only, without a folder path.' -ForegroundColor Yellow
            continue
        }
        if (-not $name.EndsWith('.iso', [StringComparison]::OrdinalIgnoreCase)) { $name += '.iso' }
        try {
            $path = Get-LocalPath (Join-Path $folder $name) 'Output ISO file'
            if (Test-Path -LiteralPath $path) {
                Write-Host 'That filename already exists. Enter another name; it will not be overwritten.' -ForegroundColor Yellow
                continue
            }
            return $path
        } catch { Write-Host $_.Exception.Message -ForegroundColor Yellow }
    }
}

function Get-LocalPath([string]$Value, [string]$Prompt) {
    if ([string]::IsNullOrWhiteSpace($Value)) { $Value = Read-Host $Prompt }
    $Value = $Value.Trim()
    if ($Value.StartsWith('"') -and $Value.EndsWith('"')) { $Value = $Value.Trim('"') }
    if ([string]::IsNullOrWhiteSpace($Value)) { throw 'A required path was not supplied.' }
    # No UNC/device paths, ADS, wildcard syntax, control characters or bootdata '#'.
    if ($Value -match '["*?#\x00-\x1f]' -or $Value.StartsWith('\')) {
        throw 'Use a local drive path without wildcards, quotes, control characters or #.'
    }
    if ($Value -notmatch '^[A-Za-z]:\\') {
        $Value = Join-Path (Get-Location).ProviderPath $Value
    }
    if ($Value -notmatch '^[A-Za-z]:\\' -or $Value.Substring(2).Contains(':')) {
        throw 'Only ordinary local drive paths are supported.'
    }
    foreach ($part in $Value.Substring(3).Split('\')) {
        if ($part -notin @('', '.', '..') -and ($part.EndsWith('.') -or $part.EndsWith(' '))) {
            throw 'Path components ending in a dot or space are unsupported.'
        }
    }
    $full = [IO.Path]::GetFullPath($Value)
    if ($full.Length -gt 3) { $full = $full.TrimEnd('\') }
    Assert-NoReparseAncestors $full
    return $full
}

function Assert-NoReparseAncestors([string]$Path) {
    $cursor = $Path
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Reparse points, junctions and mounted-volume paths are unsupported: $cursor"
            }
        }
        $parent = [IO.Directory]::GetParent($cursor)
        if ($null -eq $parent) { break }
        $cursor = $parent.FullName
    }
}

function Test-Within([string]$Path, [string]$Parent) {
    return ($Path.Equals($Parent, [StringComparison]::OrdinalIgnoreCase) -or
        $Path.StartsWith($Parent.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase))
}

function Get-TreeBytes([string]$Root) {
    # Inspect children before descending: never follow a junction during traversal.
    Assert-NoReparseAncestors $Root
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($Root)
    [long]$total = 0
    while ($pending.Count) {
        foreach ($item in Get-ChildItem -LiteralPath $pending.Pop() -Force) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Unexpected reparse point: $($item.FullName)"
            }
            if ($item.PSIsContainer) { $pending.Push($item.FullName) }
            else { $total += $item.Length }
        }
    }
    return $total
}

function Assert-File([string]$Path) {
    Assert-NoReparseAncestors $Path
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Required file missing: $Path" }
}

function Get-PrivateSecurity([switch]$Directory) {
    if ($Directory) { $acl = [Security.AccessControl.DirectorySecurity]::new() }
    else { $acl = [Security.AccessControl.FileSecurity]::new() }
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $identity = [Security.Principal.SecurityIdentifier]::new($sid)
        if ($Directory) {
            $rule = [Security.AccessControl.FileSystemAccessRule]::new($identity, 'FullControl',
                'ContainerInherit, ObjectInherit', 'None', 'Allow')
        } else {
            $rule = [Security.AccessControl.FileSystemAccessRule]::new($identity, 'FullControl', 'Allow')
        }
        [void]$acl.AddAccessRule($rule)
    }
    return $acl
}

function Assert-PrivateAcl([string]$Path) {
    $acl = Get-Acl -LiteralPath $Path
    $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
    $rules = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
    if (-not $acl.AreAccessRulesProtected -or $owner -notin @('S-1-5-18', 'S-1-5-32-544') -or $rules.Count -ne 2) {
        throw "Private ACL/owner verification failed: $Path"
    }
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $found = @($rules | Where-Object { $_.IdentityReference.Value -eq $sid })
        if ($found.Count -ne 1 -or $found[0].IsInherited -or $found[0].AccessControlType -ne 'Allow' -or
            $found[0].FileSystemRights -ne [Security.AccessControl.FileSystemRights]::FullControl -or
            $found[0].PropagationFlags -ne [Security.AccessControl.PropagationFlags]::None) {
            throw "Private ACL entries are not the required SYSTEM/Administrators grants: $Path"
        }
    }
}

function Invoke-Native([string]$File, [string[]]$Arguments, [int[]]$Allowed = @(0), [switch]$Quiet, [switch]$DirectConsole) {
    # Arguments never contain passwords. Native stderr is diagnostic, not the RC.
    Assert-File $File
    $rc = $null
    $savedPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        if ($DirectConsole) {
            # No stream merging or pipeline: the native tool owns its progress line.
            & $File @Arguments
        } else {
            & $File @Arguments 2>&1 | ForEach-Object {
                $text = $_.ToString()
                if (-not $Quiet) { Write-Host $text }
                if ($script:Build.Log) {
                    [IO.File]::AppendAllText($script:Build.Log, $text + "`r`n", [Text.UTF8Encoding]::new($false))
                }
            }
        }
        $rc = $LASTEXITCODE
    } finally { $ErrorActionPreference = $savedPreference }
    if ($null -eq $rc -or $rc -notin $Allowed) { throw "$(Split-Path $File -Leaf) failed (exit $rc). See the build log." }
    Write-BuildLog ("Verified process result: {0}, exit {1}." -f (Split-Path $File -Leaf), $rc)
}

function Get-OwnedMount {
    return ,@(Get-WindowsImage -Mounted -LogPath $script:Build.DismLog -ErrorAction Stop |
        Where-Object { $_.Path.TrimEnd('\') -ieq $script:Build.Mount })
}

function Assert-MountIdentity($Mounts) {
    if ($Mounts.Count -ne 1 -or $Mounts[0].ImagePath -ine $script:Build.Wim -or $Mounts[0].ImageIndex -ne 1) {
        throw 'Mount ownership/identity is unproven; no automatic unmount is allowed.'
    }
}

function Get-OfflineValue([string]$SubKey, [string]$Name) {
    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($script:Build.HiveName + '\' + $SubKey)
    if ($null -eq $key) { throw "Expected offline registry key missing: $SubKey" }
    try {
        if ($key.GetValueNames() -notcontains $Name) { return $null }
        return [pscustomobject]@{ Kind = $key.GetValueKind($Name); Value = $key.GetValue($Name) }
    } finally { $key.Dispose() }
}

function Get-FeaturesSecurity {
    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
        $script:Build.HiveName + '\Microsoft\Windows Defender\Features')
    if ($null -eq $key) { throw 'The offline Defender Features key is missing.' }
    try {
        return $key.GetAccessControl().GetSecurityDescriptorSddlForm(
            [Security.AccessControl.AccessControlSections]'Access, Owner, Group')
    } finally { $key.Dispose() }
}

function Get-OwnedTask {
    # Unfiltered enumeration also supports a host with no tasks at the root.
    # Access/provider failures must never be mistaken for absence.
    return ,@(Get-ScheduledTask -ErrorAction Stop |
        Where-Object { $_.TaskPath -eq '\' -and $_.TaskName -eq $script:Build.TaskName })
}

function Remove-OwnedTask {
    if (-not $script:Build.TaskAttempted) { return }
    $tasks = Get-OwnedTask
    if ($tasks.Count -gt 1) { throw 'Ambiguous preparation task state.' }
    if ($tasks.Count -eq 1) {
        if ($tasks[0].State -in @('Running', 'Queued')) {
            Stop-ScheduledTask -TaskName $script:Build.TaskName -TaskPath '\' -ErrorAction Stop
            $deadline = [DateTime]::UtcNow.AddSeconds(15)
            do {
                Start-Sleep -Milliseconds 200
                $tasks = Get-OwnedTask
                if ($tasks.Count -ne 1) { throw 'Task disappeared while stopping; inspect retained state.' }
            } while ($tasks[0].State -in @('Running', 'Queued') -and [DateTime]::UtcNow -lt $deadline)
        }
        if ($tasks[0].State -notin @('Ready', 'Disabled')) { throw 'Task termination was not confirmed.' }
        Unregister-ScheduledTask -TaskName $script:Build.TaskName -TaskPath '\' -Confirm:$false -ErrorAction Stop
    }
    if ((Get-OwnedTask).Count -ne 0) { throw 'Preparation task removal was not confirmed.' }
    $script:Build.TaskAttempted = $false
}

function Dismount-OfflineHive {
    if (-not $script:Build.HiveLoaded) { return }
    if ($script:Build.TaskAttempted) { throw 'Refusing hive unload while task cleanup is unproven.' }
    Invoke-Native $script:Build.Reg @('unload', ('HKLM\' + $script:Build.HiveName)) -Quiet
    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($script:Build.HiveName)
    if ($null -ne $key) { $key.Dispose(); throw 'Offline hive is still loaded.' }
    $script:Build.HiveLoaded = $false
}

function Set-OfflinePreparation {
    $versionKey = 'Microsoft\Windows NT\CurrentVersion'
    $edition = Get-OfflineValue $versionKey 'EditionID'
    $display = Get-OfflineValue $versionKey 'DisplayVersion'
    $build = Get-OfflineValue $versionKey 'CurrentBuildNumber'
    if ($null -eq $edition -or $null -eq $display -or $null -eq $build -or
        $edition.Value -ne 'EnterpriseS' -or $display.Value -ne '24H2' -or [int]$build.Value -lt 26100) {
        throw 'Offline image must be EnterpriseS / 24H2 / build 26100 or later.'
    }
    $features = 'Microsoft\Windows Defender\Features'
    $beforeSecurity = Get-FeaturesSecurity
    if ($null -ne (Get-OfflineValue $features 'TamperProtectionSource')) {
        throw 'TamperProtectionSource already exists. Supply an original supported image; it will not be removed.'
    }
    $current = Get-OfflineValue $features 'TamperProtection'
    if ($null -eq $current -or $current.Kind -ne 'DWord' -or $current.Value -ne 4) {
        if ((Get-OwnedTask).Count -ne 0) { throw 'Unexpected task-name collision.' }
        $args = 'add "HKLM\{0}\Microsoft\Windows Defender\Features" /v TamperProtection /t REG_DWORD /d 4 /f' -f $script:Build.HiveName
        $action = New-ScheduledTaskAction -Execute $script:Build.Reg -Argument $args
        $principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        $script:Build.TaskAttempted = $true
        Register-ScheduledTask -TaskName $script:Build.TaskName -TaskPath '\' -Action $action -Principal $principal -Settings $settings -ErrorAction Stop | Out-Null
        $previousRun = (Get-ScheduledTaskInfo -TaskName $script:Build.TaskName -TaskPath '\' -ErrorAction Stop).LastRunTime
        Start-ScheduledTask -TaskName $script:Build.TaskName -TaskPath '\' -ErrorAction Stop
        $deadline = [DateTime]::UtcNow.AddSeconds(90)
        $finished = $false
        do {
            Start-Sleep -Milliseconds 250
            $task = Get-OwnedTask
            if ($task.Count -ne 1) { throw 'Preparation task is missing or ambiguous.' }
            $info = Get-ScheduledTaskInfo -TaskName $script:Build.TaskName -TaskPath '\' -ErrorAction Stop
            $finished = ($info.LastRunTime -gt $previousRun -and $task[0].State -eq 'Ready' -and
                $info.LastTaskResult -ne 267009) # SCHED_S_TASK_RUNNING
        } while (-not $finished -and [DateTime]::UtcNow -lt $deadline)
        if (-not $finished) { throw 'Offline preparation task timed out.' }
        if ($info.LastTaskResult -ne 0) { throw "Offline preparation task failed (exit $($info.LastTaskResult))." }
    }
    $actual = Get-OfflineValue $features 'TamperProtection'
    if ($null -eq $actual -or $actual.Kind -ne 'DWord' -or $actual.Value -ne 4) {
        throw 'Offline TamperProtection read-back failed.'
    }
    if ((Get-FeaturesSecurity) -cne $beforeSecurity -or $null -ne (Get-OfflineValue $features 'TamperProtectionSource')) {
        throw 'Offline Defender ACL/source invariant failed.'
    }
    Remove-OwnedTask
    Dismount-OfflineHive
    Write-BuildLog 'Offline image gate and TamperProtection=DWORD 4 verified; task removed, hive unloaded.'
}

function Read-PrimaryPassword {
    Write-Host 'Enter the primaryadmin password twice (masked). Allowed: A-Z a-z 0-9 # @ _ -'
    Write-Host 'Use a strong, unique password. The resulting ISO will contain this password.' -ForegroundColor Yellow
    while ($true) {
        $first = $null; $second = $null
        $a = [IntPtr]::Zero; $b = [IntPtr]::Zero; $accepted = $false
        try {
            $first = Read-Host 'primaryadmin password' -AsSecureString
            $second = Read-Host 'Repeat password' -AsSecureString
            if ($first.Length -eq 0 -or $first.Length -ne $second.Length) {
                Write-Host 'Empty password or confirmation mismatch. Try again.'
                continue
            }
            $a = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($first)
            $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($second)
            $valid = $true; $same = $true
            for ($i = 0; $i -lt $first.Length; $i++) {
                $c = [Runtime.InteropServices.Marshal]::ReadInt16($a, $i * 2)
                if (-not (($c -ge 65 -and $c -le 90) -or ($c -ge 97 -and $c -le 122) -or
                    ($c -ge 48 -and $c -le 57) -or $c -in @(35, 64, 95, 45))) { $valid = $false }
                if ($c -ne [Runtime.InteropServices.Marshal]::ReadInt16($b, $i * 2)) { $same = $false }
            }
            if (-not $valid -or -not $same) { Write-Host 'Unsupported characters or confirmation mismatch. Try again.'; continue }
            $accepted = $true
            return $first
        } finally {
            if ($a -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($a) }
            if ($b -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
            if ($null -ne $second) { $second.Dispose() }
            if (-not $accepted -and $null -ne $first) { $first.Dispose() }
        }
    }
}

function Write-PrimarySecret([string]$Path, [Security.SecureString]$Password) {
    $stream = $null; $bytes = $null; $check = $null; $ptr = [IntPtr]::Zero
    try {
        $acl = Get-PrivateSecurity
        # CreateNew prevents overwrites; DACL and owner are applied BEFORE content.
        $stream = [IO.FileStream]::new($Path, [IO.FileMode]::CreateNew,
            [Security.AccessControl.FileSystemRights]::FullControl, [IO.FileShare]::None,
            4096, [IO.FileOptions]::None, $acl)
        $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
        $bytes = [byte[]]::new($Password.Length)
        for ($i = 0; $i -lt $Password.Length; $i++) {
            $c = [Runtime.InteropServices.Marshal]::ReadInt16($ptr, $i * 2)
            if (-not (($c -ge 65 -and $c -le 90) -or ($c -ge 97 -and $c -le 122) -or
                ($c -ge 48 -and $c -le 57) -or $c -in @(35, 64, 95, 45))) { throw 'Unsupported password format.' }
            $bytes[$i] = [byte]$c
        }
        if ($bytes.Length -eq 0) { throw 'Empty password.' }
        # The accepted alphabet is ASCII, hence also UTF-8 without BOM.
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
        $stream.Dispose(); $stream = $null
        [IO.File]::SetAttributes($Path, [IO.FileAttributes]'Hidden, System')
        Assert-PrivateAcl $Path
        $check = [IO.File]::ReadAllBytes($Path)
        if ($check.Length -ne $bytes.Length) { throw 'Secret content length mismatch.' }
        for ($i = 0; $i -lt $bytes.Length; $i++) {
            if ($check[$i] -ne $bytes[$i]) { throw 'Secret content mismatch.' }
        }
    } catch {
        # Never include an exception which might contain password data.
        throw 'Secret creation or read-back failed; retained workspace is private. No ISO will be published.'
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if ($ptr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
        if ($null -ne $bytes) { [Array]::Clear($bytes, 0, $bytes.Length) }
        if ($null -ne $check) { [Array]::Clear($check, 0, $check.Length) }
    }
}

function Assert-Copy([string]$Source, [string]$Destination) {
    if ((Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash -ne
        (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash) {
        throw "Copied file verification failed: $Destination"
    }
}

function Remove-BuildDirectory([string]$Path) {
    # Called only for the two known child directories, after verified unmount.
    if ($Path -notin @($script:Build.Media, $script:Build.Mount) -or
        -not (Test-Within $Path $script:Build.Workspace) -or $Path -eq $script:Build.Workspace) {
        throw 'Refusing cleanup outside the owned media/mount directories.'
    }
    if ($script:Build.HiveLoaded -or $script:Build.TaskAttempted -or (Get-OwnedMount).Count -ne 0) {
        throw 'Refusing recursive cleanup while servicing resources remain.'
    }
    [void](Get-TreeBytes $Path)
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
    if (Test-Path -LiteralPath $Path) { throw "Directory cleanup was not verified: $Path" }
}

function Invoke-LtscBuild {
    $script:Build = @{
        Log = $null; DismLog = $null; Workspace = $null; MountAttempted = $false
        HiveLoaded = $false; TaskAttempted = $false; Published = $false; ExitCode = 1
        Reg = (Join-Path $env:SystemRoot 'System32\reg.exe')
        Dism = (Join-Path $env:SystemRoot 'System32\dism.exe')
        PowerShell = (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
    }
    $password = $null
    try {
        Write-BuildBanner 'LTSC-CLEAN: INSTALLATION ISO BUILDER'
        Write-BuildPhase 1 'INPUTS AND WORKSPACE'
        Write-BuildStep 1 'Checking requirements and inputs...'
        if ($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5 -or
            $PSVersionTable.PSVersion.Minor -ne 1 -or -not [Environment]::Is64BitProcess) {
            throw 'Use 64-bit Windows PowerShell 5.1 (powershell.exe), not pwsh.exe.'
        }
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        try { $isAdmin = [Security.Principal.WindowsPrincipal]::new($identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
        finally { $identity.Dispose() }
        if (-not $isAdmin) { throw 'Open Windows PowerShell using Run as administrator, then run this script again.' }
        Import-Module Dism -ErrorAction Stop
        Import-Module ScheduledTasks -ErrorAction Stop
        if ((Get-Service -Name Schedule).Status -ne 'Running') { throw 'The Task Scheduler service must be running.' }

        $source = Get-LocalPath $SourceWin 'Extracted Windows distribution folder'
        if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
        if (-not (Test-Path -LiteralPath $RepoRoot -PathType Container)) { $RepoRoot = '' }
        $repo = Get-LocalPath $RepoRoot 'LTSC-clean repository folder'
        $lgpo = Get-LocalPath $LGPOExe 'Full path to LGPO.exe (including the filename)'
        $output = Get-OutputIsoPath $OutputIso
        $outputParent = Split-Path $output -Parent
        if ([IO.Path]::GetExtension($output) -ine '.iso' -or (Test-Path -LiteralPath $output)) {
            throw 'Output must be a new .iso file; existing output is never overwritten.'
        }
        if (-not (Test-Path -LiteralPath $outputParent -PathType Container)) { throw 'Output parent folder does not exist.' }
        Write-Host ''
        Write-Host 'The ISO will be saved to:'
        Write-Host $output -ForegroundColor Cyan
        Write-Host ''
        if (-not $WorkRoot) { $WorkRoot = $outputParent }
        $workParent = Get-LocalPath $WorkRoot 'Existing NTFS workspace parent folder'
        if (-not (Test-Path -LiteralPath $workParent -PathType Container)) { throw 'Workspace parent folder does not exist.' }
        foreach ($path in @($workParent, $outputParent)) {
            $drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($path))
            if ($drive.DriveType -ne 'Fixed' -or $drive.DriveFormat -ne 'NTFS') { throw 'Workspace and output require a fixed local NTFS volume.' }
        }
        foreach ($inputRoot in @($source, $repo)) {
            if ((Test-Within $workParent $inputRoot) -or (Test-Within $output $inputRoot)) {
                throw 'Workspace/output must be outside the source distribution and repository.'
            }
        }
        # Same-volume publication uses an atomic file rename, with no replacement.
        if ([IO.Path]::GetPathRoot($workParent) -ine [IO.Path]::GetPathRoot($output)) {
            throw 'Workspace and output must be on the same NTFS volume.'
        }
        if (-not $OscdimgPath) {
            $standard = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe'
            if (Test-Path -LiteralPath $standard -PathType Leaf) { $OscdimgPath = $standard }
        }
        $oscdimg = Get-LocalPath $OscdimgPath 'Full path to ADK amd64 oscdimg.exe (including the filename)'
        $files = @('PreOOBE.cmd', 'SetupComplete.cmd', 'BootstrapLocalAdmin.ps1',
            'ConfigureDefenderPrivacy.ps1', 'ValidateSecrets.ps1', 'CreatePrimaryAdmin.ps1', 'BaselinePolicies.txt')
        foreach ($name in $files + @('Autounattend.xml')) { Assert-File (Join-Path $repo $name) }
        foreach ($name in @('setup.exe', 'sources\install.wim', 'sources\boot.wim',
            'boot\etfsboot.com', 'efi\microsoft\boot\efisys.bin')) { Assert-File (Join-Path $source $name) }
        foreach ($exe in @($lgpo, $oscdimg, $script:Build.Reg, $script:Build.Dism, $script:Build.PowerShell)) { Assert-File $exe }
        foreach ($exe in @($lgpo, $oscdimg)) {
            $signature = Get-AuthenticodeSignature -LiteralPath $exe
            if ($signature.Status -ne 'Valid' -or $null -eq $signature.SignerCertificate -or
                $signature.SignerCertificate.Subject -notmatch '(?:^|,\s*)O=Microsoft Corporation(?:,|$)') {
                throw "A valid Microsoft signature is required: $exe"
            }
        }
        $conflicts = @(Get-ChildItem -LiteralPath (Join-Path $source 'sources') -Force |
            Where-Object { $_.Name -match '^install.*\.(esd|swm)$' -or $_.Name -eq '$OEM$' -or $_.Name -ieq 'unattend.xml' })
        if ($conflicts.Count) { throw 'Mixed image formats, sources\unattend.xml or $OEM$ customization are unsupported. Use an original distribution.' }
        [xml]$answer = [IO.File]::ReadAllText((Join-Path $repo 'Autounattend.xml'))
        $ns = [Xml.XmlNamespaceManager]::new($answer.NameTable)
        $ns.AddNamespace('u', 'urn:schemas-microsoft-com:unattend')
        $selection = @($answer.SelectNodes('//u:ImageInstall/u:OSImage/u:InstallFrom/u:MetaData', $ns))
        if ($selection.Count -ne 1 -or $selection[0].Key -cne '/IMAGE/INDEX' -or $selection[0].Value -ne '1') {
            throw 'Autounattend.xml must select exactly image index 1.'
        }
        $sourceBytes = Get-TreeBytes $source
        $runId = [Guid]::NewGuid().ToString('N')
        $script:Build.Workspace = Join-Path $workParent ('L2C-build-' + $runId)
        if (Test-Path -LiteralPath $script:Build.Workspace) { throw 'Unexpected workspace collision.' }
        [void][IO.Directory]::CreateDirectory($script:Build.Workspace, (Get-PrivateSecurity -Directory))
        Assert-PrivateAcl $script:Build.Workspace
        $script:Build.Log = Join-Path $script:Build.Workspace 'build.log'
        $script:Build.DismLog = Join-Path $script:Build.Workspace 'dism.log'
        $script:Build.Media = Join-Path $script:Build.Workspace 'media'
        $script:Build.Mount = Join-Path $script:Build.Workspace 'mount'
        $script:Build.Wim = Join-Path $script:Build.Media 'sources\install.wim'
        $script:Build.HiveName = 'L2C_Offline_' + $runId
        $script:Build.TaskName = 'L2C-Prepare-' + $runId
        $candidate = Join-Path $script:Build.Workspace 'output.partial.iso'
        Write-BuildLog ('Private workspace: ' + $script:Build.Workspace)
        Write-BuildLog ('Recovery identifiers: HKLM\' + $script:Build.HiveName + '; task \' + $script:Build.TaskName)
        $info = Get-WindowsImage -ImagePath (Join-Path $source 'sources\install.wim') -Index 1 -LogPath $script:Build.DismLog -ErrorAction Stop
        if ($info.EditionId -ne 'EnterpriseS' -or [string]$info.Architecture -notin @('9', 'x64', 'amd64') -or
            ([version]$info.Version).Major -ne 10 -or ([version]$info.Version).Build -lt 26100) {
            throw 'install.wim index 1 must be Windows 11 Enterprise LTSC 2024 x64 (EnterpriseS, 26100+).'
        }
        # Conservative estimate, not a promise that DISM cannot exhaust the volume.
        $required = 2 * $sourceBytes + [long]$info.ImageSize + 5GB
        $available = ([IO.DriveInfo]::new([IO.Path]::GetPathRoot($workParent))).AvailableFreeSpace
        if ($available -lt $required) { throw ('Insufficient workspace space: allow at least {0:N1} GiB free.' -f ($required / 1GB)) }
        Write-BuildLog ('Image metadata accepted. Estimated required free space: {0:N1} GiB.' -f ($required / 1GB))
        $password = Read-PrimaryPassword
        Write-BuildStep 1 'Requirements and inputs checked.' -Done

        Write-BuildStep 2 'Copying Windows installation files...'
        [void][IO.Directory]::CreateDirectory($script:Build.Media)
        [void][IO.Directory]::CreateDirectory($script:Build.Mount)
        Invoke-Native (Join-Path $env:SystemRoot 'System32\robocopy.exe') @($source, $script:Build.Media,
            '/E', '/COPY:DAT', '/DCOPY:DAT', '/R:2', '/W:2', '/XJ', '/NP', '/NFL', '/NDL') @(0,1,2,3,4,5,6,7) -Quiet
        Write-Host '      Verifying copied installation files. This may take a few minutes...'
        foreach ($name in @('setup.exe', 'sources\install.wim', 'sources\boot.wim',
            'boot\etfsboot.com', 'efi\microsoft\boot\efisys.bin')) {
            Assert-Copy (Join-Path $source $name) (Join-Path $script:Build.Media $name)
        }
        [IO.File]::SetAttributes($script:Build.Wim,
            ([IO.File]::GetAttributes($script:Build.Wim) -band (-bnot [IO.FileAttributes]::ReadOnly)))
        if ((Get-OwnedMount).Count -ne 0) { throw 'Unexpected mount-path collision.' }
        Write-BuildStep 2 'Windows installation files copied and verified.' -Done
        Write-BuildPhase 2 'WINDOWS IMAGE PREPARATION'
        Write-BuildStep 3 'Mounting the Windows image (this may take a few minutes)...'
        $script:Build.MountAttempted = $true
        Invoke-Native $script:Build.Dism @('/Mount-Image', ('/ImageFile:' + $script:Build.Wim),
            '/Index:1', ('/MountDir:' + $script:Build.Mount), '/CheckIntegrity', ('/LogPath:' + $script:Build.DismLog)) -DirectConsole
        $mounted = Get-OwnedMount
        Assert-MountIdentity $mounted
        if ($mounted[0].MountStatus -ne 'Ok' -or $mounted[0].MountMode -ne 'ReadWrite') { throw 'Image is not mounted read/write in a healthy state.' }

        Write-BuildStep 3 'Windows image mounted and verified.' -Done
        Write-BuildStep 4 'Verifying the offline edition and preparing Tamper Protection...'
        $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($script:Build.HiveName)
        if ($null -ne $key) { $key.Dispose(); throw 'Unexpected offline hive-name collision.' }
        Invoke-Native $script:Build.Reg @('load', ('HKLM\' + $script:Build.HiveName),
            (Join-Path $script:Build.Mount 'Windows\System32\Config\SOFTWARE')) -Quiet
        $script:Build.HiveLoaded = $true
        Set-OfflinePreparation

        Write-BuildStep 4 'Offline image preparation verified.' -Done
        Write-BuildStep 5 'Adding installation scripts and administrator password...'
        $scripts = Join-Path $script:Build.Mount 'Windows\Setup\Scripts'
        Assert-NoReparseAncestors $scripts
        $scriptsExisted = Test-Path -LiteralPath $scripts -PathType Container
        [void][IO.Directory]::CreateDirectory($scripts)
        if (-not $scriptsExisted) {
            $scriptsAcl = Get-Acl -LiteralPath $scripts
            $scriptsAcl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
            Set-Acl -LiteralPath $scripts -AclObject $scriptsAcl
        }
        foreach ($name in @('.bootstrap.pw', '.primaryadmin.pw')) {
            if (Test-Path -LiteralPath (Join-Path $scripts $name)) { throw 'Existing deployment secrets found. Supply an original image.' }
        }
        foreach ($name in $files + @('LGPO.exe')) {
            $from = if ($name -eq 'LGPO.exe') { $lgpo } else { Join-Path $repo $name }
            $to = Join-Path $scripts $name
            Assert-NoReparseAncestors $to
            Copy-Item -LiteralPath $from -Destination $to -Force
            $payloadAcl = Get-Acl -LiteralPath $to
            $payloadAcl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
            Set-Acl -LiteralPath $to -AclObject $payloadAcl
            Assert-Copy $from $to
        }
        $validator = Join-Path $scripts 'ValidateSecrets.ps1'
        Invoke-Native $script:Build.PowerShell @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', $validator, '-CheckAclBoundaryPreStageB', '-ScriptsDirPath', $scripts,
            '-StageBScriptPath', (Join-Path $scripts 'CreatePrimaryAdmin.ps1')) -Quiet
        $secret = Join-Path $scripts '.primaryadmin.pw'
        Write-PrimarySecret $secret $password
        $password.Dispose(); $password = $null
        Write-BuildLog 'Checking primaryadmin secret; bootstrap is created later by Windows Setup (expected validator exit 2).'
        Invoke-Native $script:Build.PowerShell @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', $validator, '-BootstrapPath', (Join-Path $scripts '.bootstrap.pw'), '-PrimaryAdminPath', $secret) @(2) -Quiet
        Write-BuildLog 'Primaryadmin secret content, owner, ACL and Hidden/System attributes verified.'
        Copy-Item -LiteralPath (Join-Path $repo 'Autounattend.xml') -Destination (Join-Path $script:Build.Media 'Autounattend.xml') -Force
        Assert-Copy (Join-Path $repo 'Autounattend.xml') (Join-Path $script:Build.Media 'Autounattend.xml')

        Write-BuildStep 5 'Installation files and administrator password verified.' -Done
        Write-BuildStep 6 'Saving and unmounting the image. Do not interrupt...'
        if ($script:Build.HiveLoaded -or $script:Build.TaskAttempted) { throw 'Offline resources were not released.' }
        Assert-MountIdentity (Get-OwnedMount)
        Invoke-Native $script:Build.Dism @('/Unmount-Image', ('/MountDir:' + $script:Build.Mount),
            '/Commit', '/CheckIntegrity', ('/LogPath:' + $script:Build.DismLog)) -DirectConsole
        if ((Get-OwnedMount).Count -ne 0) { throw 'Image unmount was not confirmed.' }
        $script:Build.MountAttempted = $false

        Write-BuildStep 6 'Image saved and unmounted.' -Done
        Write-BuildPhase 3 'ISO CREATION'
        Write-BuildStep 7 'Creating the installation ISO...'
        $boot = '-bootdata:2#p0,e,b"{0}"#pEF,e,b"{1}"' -f
            (Join-Path $script:Build.Media 'boot\etfsboot.com'), (Join-Path $script:Build.Media 'efi\microsoft\boot\efisys.bin')
        Invoke-Native $oscdimg @('-m', '-o', '-u2', '-udfver102', $boot, $script:Build.Media, $candidate) -DirectConsole
        Assert-File $candidate
        if ((Get-Item -LiteralPath $candidate).Length -le 0) { throw 'ISO output is empty.' }
        Set-Acl -LiteralPath $candidate -AclObject (Get-PrivateSecurity)
        Assert-PrivateAcl $candidate

        Write-BuildStep 7 'ISO created and checked.' -Done
        Write-BuildStep 8 'Removing temporary build files and finalizing the ISO...'
        Remove-BuildDirectory $script:Build.Media
        Remove-BuildDirectory $script:Build.Mount
        Assert-NoReparseAncestors $output
        # File.Move on the same volume fails if output appeared during the build.
        [IO.File]::Move($candidate, $output)
        $script:Build.Published = $true
        Assert-PrivateAcl $output
        Write-BuildStep 8 'Temporary build files removed; ISO finalized.' -Done
        Write-BuildLog ('SUCCESS: ' + $output)
        Write-BuildBanner 'INSTALLATION ISO READY'
        Write-Host 'Build completed successfully.' -ForegroundColor Green
        Write-Host ''
        Write-Host 'ISO:'
        Write-Host $output -ForegroundColor Cyan
        Write-Host ''
        Write-Host 'IMPORTANT:' -ForegroundColor Yellow
        Write-Host 'This ISO contains your administrator password.' -ForegroundColor Yellow
        Write-Host 'Keep the ISO and any USB drive made from it private.' -ForegroundColor Yellow
        Write-Host ''
        Write-Host 'Next step:'
        Write-Host 'Write the ISO to a USB drive or test it in a virtual machine.'
        Write-Host ''
        Write-Host 'Build logs:'
        Write-Host $script:Build.Log
        Write-Host $script:Build.DismLog
        Write-BuildLog 'The ISO contains the primaryadmin password. Keep the ISO and any USB copy private.'
        Write-BuildLog ('Logs retained: ' + $script:Build.Workspace)
        $script:Build.ExitCode = 0
        return
    } catch {
        # Report only diagnostics; password operations replace data-bearing errors.
        Write-Host ('FAILED: ' + $_.Exception.Message) -ForegroundColor Red
        if ($script:Build.Log) {
            try { Write-BuildLog ('FAILED: ' + $_.Exception.Message) } catch { Write-Host 'Could not append failure to build.log.' }
        }
        if ($script:Build.Published) { Write-Host ('Output exists but final verification failed; do not use it: ' + $output) -ForegroundColor Red }
        $script:Build.ExitCode = 1
        return
    } finally {
        if ($null -ne $password) { $password.Dispose() }
        # Cleanup is ordered. A task failure blocks hive unload; a hive failure
        # blocks discard. Never recurse into a failed/still-mounted image.
        $released = $true
        try { Remove-OwnedTask } catch { $released = $false; Write-Host ('Task cleanup failed: ' + $_.Exception.Message) -ForegroundColor Red }
        if ($released) {
            try { Dismount-OfflineHive } catch { $released = $false; Write-Host ('Hive cleanup failed: ' + $_.Exception.Message) -ForegroundColor Red }
        }
        if ($released -and $script:Build.MountAttempted) {
            try {
                $mounts = Get-OwnedMount
                if ($mounts.Count) {
                    Assert-MountIdentity $mounts
                    Invoke-Native $script:Build.Dism @('/Unmount-Image', ('/MountDir:' + $script:Build.Mount),
                        '/Discard', ('/LogPath:' + $script:Build.DismLog)) -DirectConsole
                }
                if ((Get-OwnedMount).Count) { throw 'Mount remains registered.' }
                $script:Build.MountAttempted = $false
            } catch { Write-Host ('Discard failed; inspect the mount before any deletion: ' + $_.Exception.Message) -ForegroundColor Red }
        }
        if (-not $script:Build.Published -and $script:Build.Workspace) {
            Write-Host ('Retained private workspace (may contain the password): ' + $script:Build.Workspace) -ForegroundColor Yellow
            if ($script:Build.ContainsKey('HiveName')) {
                Write-Host ('Recovery: hive HKLM\' + $script:Build.HiveName + '; task \' + $script:Build.TaskName + '; mount ' + $script:Build.Mount)
            }
        }
    }
}

# Do not capture the build function's output: native tools need the live console.
Invoke-LtscBuild
exit $script:Build.ExitCode
