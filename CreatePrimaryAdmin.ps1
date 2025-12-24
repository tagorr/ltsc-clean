[CmdletBinding()]
param(
  [string]$PrimaryUser = 'primaryadmin',
  [string]$FullName = '',
  [string]$Description = '',
  [bool]$PasswordNeverExpires = $true,
  [switch]$AddToRemoteDesktopUsers,
  [switch]$RollbackOnly,
  [switch]$VerboseLog
)


Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$LogPath = Join-Path $env:WINDIR 'Panther\SetupComplete.log'
$MasterLogPath = Join-Path $env:ProgramData ("l2c_master_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
try {
  $MasterLogDir = Split-Path -Parent $MasterLogPath
  if ($MasterLogDir -and -not (Test-Path -LiteralPath $MasterLogDir)) {
    New-Item -ItemType Directory -Path $MasterLogDir -Force | Out-Null
  }
} catch {}

function Write-SetupLog([string]$Message, [string]$Level = 'INFO') {
  try {
    $ts   = [DateTime]::UtcNow.ToString('o')
    $line = "[{0}] [CreatePrimaryAdmin] {1} {2}" -f $ts, $Level, $Message

    # Ensure directory exists (best-effort, silent)
    try {
      $dir = Split-Path -Parent $LogPath
      if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        [void][System.IO.Directory]::CreateDirectory($dir)
      }
    } catch {}

    $enc = New-Object System.Text.UTF8Encoding($false)  # UTF-8 without BOM
    $sw  = New-Object System.IO.StreamWriter($LogPath, $true, $enc)  # append
    try {
      $sw.WriteLine($line)
    } finally {
      $sw.Dispose()
    }
  } catch {}
}

function Resolve-LocalGroupName {
  param(
    [Parameter(Mandatory = $true)][string]$Sid,
    [Parameter(Mandatory = $true)][string]$Label
  )
  try {
    $val = ([System.Security.Principal.SecurityIdentifier]$Sid).Translate([System.Security.Principal.NTAccount]).Value
    return ($val -split '\\')[-1]
  } catch {
    throw "Unable to resolve $Label ($Sid): $($_.Exception.Message)"
  }
}

try {
  $script:AdministratorsGroupName = Resolve-LocalGroupName -Sid 'S-1-5-32-544' -Label 'Administrators'
} catch {
  $script:AdministratorsGroupName = 'Administrators'
  Write-SetupLog ("Fallback to literal Administrators: {0}" -f $_.Exception.Message) 'WARN'
}
try {
  $script:RemoteDesktopGroupName  = Resolve-LocalGroupName -Sid 'S-1-5-32-555' -Label 'Remote Desktop Users'
} catch {
  $script:RemoteDesktopGroupName = 'Remote Desktop Users'
  Write-SetupLog ("Fallback to literal Remote Desktop Users: {0}" -f $_.Exception.Message) 'WARN'
}

if ($VerboseLog) {
  Write-SetupLog ("Resolved Administrators -> {0}" -f $script:AdministratorsGroupName) 'DEBUG'
  Write-SetupLog ("Resolved Remote Desktop Users -> {0}" -f $script:RemoteDesktopGroupName) 'DEBUG'
}

function Reg-Add([string]$Key, [string]$Name, [string]$Type, [string]$Data) {
  try {
    & reg.exe ADD $Key /v $Name /t $Type /d $Data /f | Out-Null 2>$null
    $rc = $LASTEXITCODE
    if ($VerboseLog) { Write-SetupLog ("Reg ADD {0}\{1} <{2}> = '{3}' (RC={4})" -f $Key,$Name,$Type,$Data,$rc) 'DEBUG' }
    if ($rc -ne 0) { Write-SetupLog ("Reg ADD failed: {0}\{1} (RC={2})" -f $Key,$Name,$rc) 'WARN' }
  } catch {
    Write-SetupLog "Reg ADD failed: $Key\$Name - $($_.Exception.Message)" 'WARN'
  }
}

function Reg-Del([string]$Key, [string]$Name) {
  try {
    & reg.exe DELETE $Key /v $Name /f | Out-Null 2>$null
    $rc = $LASTEXITCODE
    # Idempotent delete: RC=0 (deleted) or RC=2 (value not found) is OK for our flow
    if ($rc -eq 0 -or $rc -eq 2) {
      if ($VerboseLog) { Write-SetupLog ("Reg DEL {0}\{1} (RC={2})" -f $Key,$Name,$rc) 'DEBUG' }
    } else {
      Write-SetupLog ("Reg DEL failed: {0}\{1} (RC={2})" -f $Key,$Name,$rc) 'WARN'
    }
  } catch {
    Write-SetupLog "Reg DEL failed: $Key\$Name - $($_.Exception.Message)" 'WARN'
  }
}

function Test-SystemRebootPending {
  $reasons = New-Object System.Collections.Generic.List[string]
  $errors  = New-Object System.Collections.Generic.List[string]

  function Add-Reason([string]$Reason) {
    try {
      if ($Reason -and -not $reasons.Contains($Reason)) { [void]$reasons.Add($Reason) }
    } catch {}
  }

  function Add-Error([string]$Probe, [object]$Err) {
    try {
      $msg = $null
      if ($Err -and $Err.Exception -and $Err.Exception.Message) { $msg = $Err.Exception.Message }
      elseif ($Err -and $Err.ToString) { $msg = $Err.ToString() }
      if (-not $msg) { $msg = '<unknown error>' }

      $line = "{0}: {1}" -f $Probe, $msg
      if (-not $errors.Contains($line)) { [void]$errors.Add($line) }
    } catch {}
  }

  try {
    $cbs = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing'
    if (Test-Path -LiteralPath (Join-Path $cbs 'RebootPending'))      { Add-Reason 'CBS:RebootPending' }
    if (Test-Path -LiteralPath (Join-Path $cbs 'RebootInProgress'))   { Add-Reason 'CBS:RebootInProgress' }
    if (Test-Path -LiteralPath (Join-Path $cbs 'PackagesPending'))    { Add-Reason 'CBS:PackagesPending' }
    if (Test-Path -LiteralPath (Join-Path $cbs 'PostRebootReporting')){ Add-Reason 'CBS:PostRebootReporting' }
  } catch { Add-Error 'CBS probe' $_ }

  try {
    $wu = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update'
    if (Test-Path -LiteralPath (Join-Path $wu 'RebootRequired'))      { Add-Reason 'WU:RebootRequired' }
    if (Test-Path -LiteralPath (Join-Path $wu 'PostRebootReporting')) { Add-Reason 'WU:PostRebootReporting' }
  } catch { Add-Error 'WU probe' $_ }

  try {
    $sm = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
    if (Test-Path -LiteralPath $sm) {
      $p = Get-ItemProperty -LiteralPath $sm -ErrorAction Stop
      foreach ($n in @('PendingFileRenameOperations', 'PendingFileRenameOperations2')) {
        $prop = $p.PSObject.Properties[$n]
        if ($prop) {
          $v = $prop.Value
          $hasData = $false
          if ($v -is [Array]) {
            foreach ($item in $v) {
              if ($item -and $item.ToString().Trim().Length -gt 0) { $hasData = $true; break }
            }
          } else {
            if ($v -and $v.ToString().Trim().Length -gt 0) { $hasData = $true }
          }
          if ($hasData) { Add-Reason ("SessionManager:{0}" -f $n) }
        }
      }
    }
  } catch { Add-Error 'SessionManager probe' $_ }

  try {
    $upd = 'HKLM:\SOFTWARE\Microsoft\Updates'
    if (Test-Path -LiteralPath $upd) {
      $p = Get-ItemProperty -LiteralPath $upd -ErrorAction Stop
      $prop = $p.PSObject.Properties['UpdateExeVolatile']
      if ($prop) {
        $val = $prop.Value
        $i = 0
        if ($null -ne $val -and [int]::TryParse($val.ToString(), [ref]$i) -and $i -gt 0) {
          Add-Reason 'Installer:UpdateExeVolatile'
        }
      }
    }
  } catch { Add-Error 'Updates probe' $_ }

  $state = if ($reasons.Count -gt 0) { 'true' } elseif ($errors.Count -gt 0) { 'unknown' } else { 'false' }

  return [pscustomobject]@{
    State   = $state
    Reasons = @($reasons)
    Errors  = @($errors)
  }
}

function Get-LocalUserExists([string]$User) {
  & net.exe user "$User" | Out-Null 2>$null
  return ($LASTEXITCODE -eq 0)
}
function Ensure-InAdministrators([string]$User) {
  & net.exe localgroup "$script:AdministratorsGroupName" "$User" /add | Out-Null 2>$null
  $code = $LASTEXITCODE
  if ($code -eq 0) {
    Write-SetupLog ("Added {0} to {1}" -f $User,$script:AdministratorsGroupName)
  } elseif ($code -eq 1378) {
    Write-SetupLog ("{0} already in {1}" -f $User,$script:AdministratorsGroupName) 'DEBUG'
  } else {
    throw ("net localgroup {0} exitcode {1}" -f $script:AdministratorsGroupName,$code)
  }
  return $code
}
function Ensure-InGroup([string]$Group, [string]$User) {
  & net.exe localgroup "$Group" "$User" /add | Out-Null 2>$null
  $code = $LASTEXITCODE
  if ($code -eq 0 -or $code -eq 1378) {
    Write-SetupLog ("Ensured {0} in {1}" -f $User,$Group)
  } else {
    throw "net localgroup '$Group' exitcode $code"
  }
}
function Set-UserAdsi([string]$User, [string]$FullName, [string]$Description, [switch]$NeverExpire) {
  try {
    $u = [ADSI]("WinNT://$env:COMPUTERNAME/$User,user")
    if ($FullName)    { $u.FullName    = $FullName }
    if ($Description) { $u.Description = $Description }
    try { $u.PasswordExpired = 0 } catch {}
    if ($NeverExpire) {
      $UF_DONT_EXPIRE_PASSWD = 0x10000
      $flags = 0; try { $flags = [int]$u.UserFlags } catch {}
      $u.UserFlags = ($flags -bor $UF_DONT_EXPIRE_PASSWD)
    }
    $u.SetInfo()
    if ($VerboseLog) { Write-SetupLog "ADSI updated for $User (FullName/Description/Flags)" 'DEBUG' }
  } catch {
    Write-SetupLog "ADSI update failed for ${User}: $($_.Exception.Message)" 'WARN'
  }
}

function Set-L2CLocalUserPasswordAdsi {
  param(
    [Parameter(Mandatory = $true)]
    [string] $UserName,
    [Parameter(Mandatory = $true)]
    [string] $Password
  )

  $userPath = "WinNT://$env:COMPUTERNAME/$UserName,user"

  try {
    $user = [ADSI] $userPath
  } catch {
    throw "Failed to bind ADSI local user '$UserName'. The account does not exist or cannot be opened."
  }

  try {
    $user.SetPassword($Password)
    $user.SetInfo()
  } catch {
    throw "Failed to set password for local user '$UserName' via ADSI. $($_.Exception.Message)"
  }
}

function Test-AdministratorsMembership([string]$User) {
  try {
    $group = [ADSI]("WinNT://$env:COMPUTERNAME/$script:AdministratorsGroupName,group")
    foreach ($member in @($group.psbase.Invoke('Members'))) {
      $name = $member.GetType().InvokeMember('Name','GetProperty',$null,$member,$null)
      if ($name -and ($name -ieq $User)) { return $true }
    }
  } catch {
    Write-SetupLog ("ADSI membership check failed for {0}: {1}" -f $script:AdministratorsGroupName,$_.Exception.Message) 'WARN'
  }
  return $false
}

$rc = 0
$StageA_Succeeded = $false
$StageA_RC = 0
$StageAAbortReason = $null
$StageB_Succeeded = $false

Write-SetupLog "Begin A: Primary admin creation/config"
try {
  if ($RollbackOnly) {
    Write-SetupLog "RollbackOnly specified: skipping Stage A"
    Write-Verbose "Stage A: RollbackOnly requested; marking as succeeded"
    $StageA_Succeeded = $true
    $StageA_RC = 0
  } else {
    $primaryAdminSecretPath = Join-Path $env:WINDIR 'Setup\Scripts\.primaryadmin.pw'
    try {
      $passwordText = Get-Content -LiteralPath $primaryAdminSecretPath -Encoding utf8 -TotalCount 1 -ErrorAction Stop
      if ($null -eq $passwordText) { $passwordText = '' }
      $passwordText = $passwordText -replace '[\r\n]+$',''
    } catch {
      $StageAAbortReason = "primary admin secret missing or unreadable at $primaryAdminSecretPath"
      throw [System.InvalidOperationException]::new($StageAAbortReason)
    }
    if (-not $passwordText) {
      $StageAAbortReason = "primary admin secret missing or invalid at $primaryAdminSecretPath"
      throw [System.InvalidOperationException]::new($StageAAbortReason)
    }
    if ($passwordText -notmatch '^[A-Za-z0-9#@_-]+$') {
      $StageAAbortReason = "primary admin secret contains unsupported characters at $primaryAdminSecretPath"
      throw [System.InvalidOperationException]::new($StageAAbortReason)
    }
    $pwd = $passwordText
    Write-SetupLog "Primary admin secret loaded from .primaryadmin.pw" 'INFO' 

    Write-Verbose "Stage A: checking if $PrimaryUser exists"
    $exists = Get-LocalUserExists $PrimaryUser
    if (-not $exists) {
      Write-Verbose "Stage A: creating local user $PrimaryUser"
      & net.exe user "$PrimaryUser" /add | Out-Null 2>$null
      if ($LASTEXITCODE -ne 0) { throw "Failed to create user $PrimaryUser (exitcode $LASTEXITCODE)" }
      try {
        Set-L2CLocalUserPasswordAdsi -UserName $PrimaryUser -Password $pwd
      } catch {
        $msg = if ($_.Exception -and $_.Exception.Message) { $_.Exception.Message } else { $_.ToString() }
        Write-SetupLog ("Failed to set password via ADSI for {0}: {1}" -f $PrimaryUser, $msg) 'ERROR'
        & net.exe user "$PrimaryUser" /delete | Out-Null 2>$null
        $delRc = $LASTEXITCODE
        if ($delRc -eq 0) {
          Write-SetupLog ("Rolled back user {0} after password failure (delete rc={1})" -f $PrimaryUser,$delRc) 'WARN'
        } else {
          Write-SetupLog ("Failed to delete user {0} after password failure (rc={1})" -f $PrimaryUser,$delRc) 'ERROR'
        }
        throw
      }
      & net.exe user "$PrimaryUser" /active:yes | Out-Null 2>$null
      if ($LASTEXITCODE -ne 0) { throw "Failed to activate user $PrimaryUser (exitcode $LASTEXITCODE)" }
      Write-SetupLog "User $PrimaryUser created and activated"
    } else {
      Write-Verbose "Stage A: updating password for $PrimaryUser"
      try {
        Set-L2CLocalUserPasswordAdsi -UserName $PrimaryUser -Password $pwd
      } catch {
        $msg = if ($_.Exception -and $_.Exception.Message) { $_.Exception.Message } else { $_.ToString() }
        Write-SetupLog ("Failed to set password via ADSI for existing user {0}: {1}" -f $PrimaryUser, $msg) 'ERROR'
        Write-SetupLog ("Skipping deletion because {0} existed before this run" -f $PrimaryUser) 'WARN'
        throw
      }
      Write-SetupLog "Password updated for $PrimaryUser"
      & net.exe user "$PrimaryUser" /active:yes | Out-Null 2>$null
      if ($LASTEXITCODE -ne 0) { throw "Failed to activate user $PrimaryUser (exitcode $LASTEXITCODE)" }
    }

    Set-UserAdsi -User $PrimaryUser -FullName $FullName -Description $Description -NeverExpire:$PasswordNeverExpires

    Write-Verbose "Stage A: verifying Administrators membership via ADSI"
    $isAdminMember = Test-AdministratorsMembership $PrimaryUser
    if ($isAdminMember) {
      Write-SetupLog "A: SKIP (already member)"
    } else {
      Write-Verbose ("Stage A: adding {0} to {1}" -f $PrimaryUser,$script:AdministratorsGroupName)
      $addCode = Ensure-InAdministrators $PrimaryUser
      if ($addCode -eq 1378) {
        Write-SetupLog "A: SKIP (already member)"
      }
    }

    if ($AddToRemoteDesktopUsers) { Ensure-InGroup $script:RemoteDesktopGroupName $PrimaryUser }
    $StageA_Succeeded = $true
    $StageA_RC = 0
  }
}
catch {
  if ($StageA_RC -eq 0) { $StageA_RC = 1 }
  if (-not $StageAAbortReason) { $StageAAbortReason = $_.Exception.Message }
  Write-SetupLog ("Stage A failed: {0}" -f $StageAAbortReason) 'ERROR'
  $StageA_Succeeded = $false
  $rc = 1
}

if ($StageA_Succeeded) {
  Write-SetupLog "End A (SUCCESS, RC=0)"
}

$isRecovery = -not $StageA_Succeeded
if ($isRecovery) {
  Write-SetupLog ("Stage B running in recovery mode (StageA RC={0})" -f $StageA_RC) 'WARN'
} else {
  Write-SetupLog "Begin B: Autologon cleanup & policy restore"
}

$finalLogEntries = @()
$modeLabel = if ($isRecovery) { 'recovery' } else { 'normal' }
try {
  $finalLogEntries += ("[{0}] Stage B finalize begin (mode={1})" -f ([DateTime]::UtcNow.ToString('o')), $modeLabel)

  Write-Verbose "Stage B: resetting Winlogon autologon state"
  $wl = 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
  Reg-Del $wl 'DefaultUserName'
  Reg-Del $wl 'DefaultDomainName'
  Reg-Del $wl 'DefaultPassword'
  Reg-Add $wl 'AutoAdminLogon' 'REG_SZ' '0'
  Reg-Add $wl 'ForceAutoLogon' 'REG_SZ' '0'
  Reg-Add $wl 'AutoLogonCount' 'REG_DWORD' '0'
  Reg-Del $wl 'IgnoreShiftOverride'
  Reg-Add $wl 'IgnoreShiftOverride' 'REG_SZ' '0'
  Reg-Add 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'DisableCAD' 'REG_DWORD' '0'
  if ($isRecovery) {
    Reg-Add 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI\Ngc' 'DevicePasswordLessBuildVersion' 'REG_DWORD' '0'
    Write-SetupLog 'Recovery mode: forcing DevicePasswordLessBuildVersion=0 for troubleshooting' 'WARN'
  } else {
    Reg-Add 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI\Ngc' 'DevicePasswordLessBuildVersion' 'REG_DWORD' '2'
  }
  $finalLogEntries += ("[{0}] Winlogon and logon policies reset" -f ([DateTime]::UtcNow.ToString('o')))

  if (-not $isRecovery) {
    Write-Verbose "Stage B: deactivating bootstrap account"
    & net.exe user bootstrap /active:no | Out-Null 2>$null
    $bootstrapRC = $LASTEXITCODE
    if ($bootstrapRC -eq 0) {
      Write-SetupLog "bootstrap deactivated"
    } else {
      Write-SetupLog ("bootstrap deactivate exitcode {0}" -f $bootstrapRC) 'WARN'
    }
    $finalLogEntries += ("[{0}] net.exe user bootstrap /active:no rc={1}" -f ([DateTime]::UtcNow.ToString('o')), $bootstrapRC)

    Write-Verbose "Stage B: deleting scheduled task \L2C\CreatePrimaryAdmin"
    $taskDeleteRC = -1
    try {
      & schtasks.exe /Delete /TN '\L2C\CreatePrimaryAdmin' /F | Out-Null 2>$null
      $taskDeleteRC = $LASTEXITCODE
      if ($taskDeleteRC -eq 0) {
        Write-SetupLog "Scheduled task \L2C\CreatePrimaryAdmin removed"
      } elseif ($taskDeleteRC -ne 0) {
        Write-SetupLog ("Scheduled task delete exitcode {0}" -f $taskDeleteRC) 'WARN'
      }
    } catch {
      Write-SetupLog "Scheduled task delete failed: $($_.Exception.Message)" 'WARN'
    }
    $finalLogEntries += ("[{0}] schtasks.exe /Delete rc={1}" -f ([DateTime]::UtcNow.ToString('o')), $taskDeleteRC)
  } else {
    Write-SetupLog "Recovery mode: bootstrap account remains enabled and scheduled task retained" 'WARN'
  }

  Write-Verbose "Stage B: cleaning RunOnce entries"
  try {
    $ro = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
    $me = $MyInvocation.MyCommand.Path
    $props = Get-ItemProperty -LiteralPath $ro -ErrorAction SilentlyContinue
    if ($props) {
      foreach ($n in ($props | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name)) {
        $v = (Get-ItemPropertyValue -LiteralPath $ro -Name $n -ErrorAction SilentlyContinue) 2>$null
        if (($n -eq 'CreatePrimaryAdmin') -or ($v -is [string] -and $me -and ($v -match [regex]::Escape($me))) -or ($v -is [string] -and $v -match 'CreatePrimaryAdmin\.ps1')) {
          try {
            Remove-ItemProperty -LiteralPath $ro -Name $n -ErrorAction Stop
          } catch {
            Write-SetupLog ("RunOnce entry '{0}' removal failed: {1}" -f $n, $_.Exception.Message) 'WARN'
          }
        }
      }
      & reg.exe DELETE HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce /v CreatePrimaryAdmin /f | Out-Null 2>$null # Defensive sweep for stubborn values
      $runOnceRc = $LASTEXITCODE
      if ($runOnceRc -ne 0 -and $runOnceRc -ne 2) {
        Write-SetupLog ("RunOnce reg delete rc={0}" -f $runOnceRc) 'WARN'
      }
    }
    Write-SetupLog "RunOnce cleaned"
  } catch {
    Write-SetupLog "RunOnce cleanup warning: $($_.Exception.Message)" 'WARN'
  }

  # Stage B: remove transient password source files (best-effort)
  $pwCleanupState = 'skipped'
  $primaryPwCleanupState = 'skipped'
  if (-not $isRecovery) {
    $pwCleanupState = 'unknown'
    $primaryPwCleanupState = 'unknown'
    try {
      $pwPath = Join-Path $env:WINDIR 'Setup\Scripts\.bootstrap.pw'
      if (Test-Path -LiteralPath $pwPath) {
        Remove-Item -LiteralPath $pwPath -Force -ErrorAction Stop
        Write-SetupLog "bootstrap.pw removed"
        $pwCleanupState = 'removed'
      } else {
        Write-SetupLog "bootstrap.pw not found during Stage B cleanup" 'WARN'
        $pwCleanupState = 'missing'
      }
    } catch {
      Write-SetupLog ("bootstrap.pw delete error: {0}" -f $_.Exception.Message) 'ERROR'
      $pwCleanupState = 'error'
    }

    try {
      $primaryPwPath = Join-Path $env:WINDIR 'Setup\Scripts\.primaryadmin.pw'
      if (Test-Path -LiteralPath $primaryPwPath) {
        Remove-Item -LiteralPath $primaryPwPath -Force -ErrorAction Stop
        Write-SetupLog "primaryadmin.pw removed"
        $primaryPwCleanupState = 'removed'
      } else {
        Write-SetupLog "primaryadmin.pw not found during Stage B cleanup" 'WARN'
        $primaryPwCleanupState = 'missing'
      }
    } catch {
      Write-SetupLog ("primaryadmin.pw delete error: {0}" -f $_.Exception.Message) 'ERROR'
      $primaryPwCleanupState = 'error'
    }
  } else {
    Write-SetupLog 'Recovery mode: preserving bootstrap.pw and primaryadmin.pw for another Stage A attempt' 'WARN'
    $pwCleanupState = 'preserved'
    $primaryPwCleanupState = 'preserved'
  }

  $finalLogEntries += ("[{0}] RunOnce cleanup complete" -f ([DateTime]::UtcNow.ToString('o')))
  if ($pwCleanupState -ne 'unknown') {
    $finalLogEntries += ("[{0}] bootstrap.pw cleanup state={1}" -f ([DateTime]::UtcNow.ToString('o')), $pwCleanupState)
  }
  if ($primaryPwCleanupState -ne 'unknown') {
    $finalLogEntries += ("[{0}] primaryadmin.pw cleanup state={1}" -f ([DateTime]::UtcNow.ToString('o')), $primaryPwCleanupState)
  }
  $rebootFlagPath = Join-Path $env:WINDIR 'Panther\_needs_reboot.flag'
  $rebootFlagState = if (Test-Path -LiteralPath $rebootFlagPath) { 'present' } else { 'absent' }
  $finalLogEntries += ("[{0}] Panther reboot flag before Stage B decision: {1}" -f ([DateTime]::UtcNow.ToString('o')), $rebootFlagState)
  $finalLogEntries += ("[{0}] Stage B finalize end" -f ([DateTime]::UtcNow.ToString('o')))

  $SecretCleanupError = $false
  if (-not $isRecovery -and $StageA_Succeeded -and (($pwCleanupState -eq 'error') -or ($primaryPwCleanupState -eq 'error'))) {
    $SecretCleanupError = $true
    Write-SetupLog 'Secret cleanup error: .bootstrap.pw and/or .primaryadmin.pw could not be removed' 'ERROR'
  }

  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllLines($MasterLogPath, $finalLogEntries, $utf8NoBom)
  Write-SetupLog ("Master log created: {0}" -f $MasterLogPath)
  if ($StageAAbortReason) {
    $outcomeLine = "OUTCOME: ABORTED - $StageAAbortReason"
  } elseif ($SecretCleanupError) {
    $outcomeLine = 'OUTCOME: FAIL - secret cleanup error (bootstrap/primaryadmin secrets not removed)'
  } elseif ($StageA_Succeeded) {
    $outcomeLine = 'OUTCOME: SUCCESS'
  } else {
    $outcomeLine = "OUTCOME: FAIL - Stage A failed (RC=$StageA_RC)"
  }
  $sw = New-Object System.IO.StreamWriter($MasterLogPath, $true, $utf8NoBom)
  $sw.WriteLine($outcomeLine)
  $sw.Dispose()
  $outcomeLevel = if ($SecretCleanupError) { 'ERROR' } elseif ($StageA_Succeeded -and -not $StageAAbortReason) { 'INFO' } else { 'ERROR' }
  Write-SetupLog $outcomeLine $outcomeLevel
  if ($SecretCleanupError) {
    Write-SetupLog "End B (FAIL - secret cleanup error)" 'ERROR'
    if ($rc -eq 0) { $rc = 3 }
    $StageB_Succeeded = $false
  } elseif ($StageA_Succeeded) {
    Write-SetupLog "End B (SUCCESS)"
    $StageB_Succeeded = $true
  } else {
    Write-SetupLog "End B (RECOVERY COMPLETE)" 'WARN'
    $StageB_Succeeded = $true
  }
}
catch {
  Write-SetupLog ("End B (FAIL) - {0}" -f $_.Exception.Message) 'ERROR'
  $StageB_Succeeded = $false
  try {
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    if (-not (Test-Path -LiteralPath $MasterLogPath)) {
      [System.IO.File]::WriteAllLines($MasterLogPath, @("[$([DateTime]::UtcNow.ToString('o'))] Stage B failure before finalize"), $utf8NoBom)
    }
    $sw = New-Object System.IO.StreamWriter($MasterLogPath, $true, $utf8NoBom)
    $sw.WriteLine("OUTCOME: FAIL - {0}" -f $_.Exception.Message)
    $sw.Dispose()
  } catch {}
  Write-SetupLog ("OUTCOME: FAIL - {0}" -f $_.Exception.Message) 'ERROR'
  if ($rc -eq 0) { $rc = 2 }
}

$flag = Join-Path $env:WINDIR 'Panther\_needs_reboot.flag'
if (Test-Path -LiteralPath $flag) {
  if (-not $utf8NoBom) {
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  }
  if (-not $StageB_Succeeded) {
    Write-SetupLog 'Reboot flag present but Stage B did not complete successfully; suppressing automatic reboot to allow operator inspection' 'WARN'
    $sw = New-Object System.IO.StreamWriter($MasterLogPath, $true, $utf8NoBom)
    try {
      $sw.WriteLine("[{0}] Stage B: Panther reboot suppressed (StageB_Succeeded=false)" -f ([DateTime]::UtcNow.ToString('o')))
    } finally {
      $sw.Dispose()
    }
  } elseif ($isRecovery) {
    Write-SetupLog 'Reboot flag present in recovery mode; not rebooting to allow operator fix' 'WARN'
    $sw = New-Object System.IO.StreamWriter($MasterLogPath, $true, $utf8NoBom)
    try {
      $sw.WriteLine("[{0}] Stage B: Panther reboot suppressed (recovery mode)" -f ([DateTime]::UtcNow.ToString('o')))
    } finally {
      $sw.Dispose()
    }
  } else {
    $forceMarker = 'force-reboot'
    $flagMarker = $null
    try {
      $flagMarker = Get-Content -LiteralPath $flag -TotalCount 1 -ErrorAction Stop | Select-Object -First 1
      if ($flagMarker) { $flagMarker = $flagMarker.Trim() }
    } catch {
      Write-SetupLog ("Failed to read Panther reboot flag marker; proceeding with pending reboot probe: {0}" -f $_.Exception.Message) 'WARN'
      $flagMarker = $null
    }

    if ($flagMarker -and ($flagMarker -ieq $forceMarker)) {
      Write-SetupLog 'Panther reboot flag indicates forced reboot policy; initiating restart' 'WARN'
      try {
        $sw = New-Object System.IO.StreamWriter($MasterLogPath, $true, $utf8NoBom)
        try {
          $sw.WriteLine("[{0}] Stage B: Panther reboot flag forced (marker=force-reboot); initiating automatic restart" -f ([DateTime]::UtcNow.ToString('o')))
        } finally {
          $sw.Dispose()
        }
      } catch {
        Write-SetupLog ("Master log write failed (flag forced): {0}" -f $_.Exception.Message) 'WARN'
      }
      Remove-Item -LiteralPath $flag -Force -ErrorAction SilentlyContinue
      & "$env:SystemRoot\System32\shutdown.exe" /r /t 0
      exit $rc
    }

    $rebootPending = Test-SystemRebootPending
    $stateText = if ($rebootPending.State) { $rebootPending.State } else { 'unknown' }
    $reasonsText = if ($rebootPending.Reasons -and $rebootPending.Reasons.Count -gt 0) { ($rebootPending.Reasons -join ',') } else { 'none' }
    $errorsText = if ($rebootPending.Errors -and $rebootPending.Errors.Count -gt 0) { ($rebootPending.Errors -join ' | ') } else { 'none' }
    Write-SetupLog ("Pending reboot check: state={0} reasons={1} errors={2}" -f $stateText, $reasonsText, $errorsText)

    if ($stateText -eq 'true') {
      Write-SetupLog 'Reboot flag detected, initiating restart'
     try {
    $sw = New-Object System.IO.StreamWriter($MasterLogPath, $true, $utf8NoBom)
    try {
        $sw.WriteLine("[{0}] Stage B: Panther reboot flag consumed, initiating automatic restart" -f ([DateTime]::UtcNow.ToString('o')))
    } finally {
        $sw.Dispose()
    }
} catch {
    Write-SetupLog ("Master log write failed (flag consumed): {0}" -f $_.Exception.Message) 'WARN'
}
      Remove-Item -LiteralPath $flag -Force -ErrorAction SilentlyContinue
      & "$env:SystemRoot\System32\shutdown.exe" /r /t 0
      exit $rc
    } elseif ($stateText -eq 'false') {
      Write-SetupLog 'Panther reboot flag present but system does not indicate a pending reboot; treating flag as stale and clearing it without reboot' 'WARN'
      try {
    $sw = New-Object System.IO.StreamWriter($MasterLogPath, $true, $utf8NoBom)
    try {
        $sw.WriteLine("[{0}] Stage B: Panther reboot flag stale (no pending reboot indicators); clearing flag without reboot" -f ([DateTime]::UtcNow.ToString('o')))
    } finally {
        $sw.Dispose()
    }
} catch {
    Write-SetupLog ("Master log write failed (flag stale): {0}" -f $_.Exception.Message) 'WARN'
}
      Remove-Item -LiteralPath $flag -Force -ErrorAction SilentlyContinue
    } else {
      Write-SetupLog 'Panther reboot flag present but pending reboot state is unknown due to probe errors; rebooting conservatively' 'WARN'
      try {
    $sw = New-Object System.IO.StreamWriter($MasterLogPath, $true, $utf8NoBom)
    try {
        $sw.WriteLine("[{0}] Stage B: Panther reboot flag consumed (pending=unknown due to probe errors); policy=conservative reboot; initiating automatic restart" -f ([DateTime]::UtcNow.ToString('o')))
    } finally {
        $sw.Dispose()
    }
} catch {
    Write-SetupLog ("Master log write failed (flag consumed pending=unknown): {0}" -f $_.Exception.Message) 'WARN'
}
      Remove-Item -LiteralPath $flag -Force -ErrorAction SilentlyContinue
      & "$env:SystemRoot\System32\shutdown.exe" /r /t 0
      exit $rc
    }
  }
}

exit $rc
