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

function Get-RegExePath {
  $windir = $env:WINDIR
  if (-not [Environment]::Is64BitProcess -and [Environment]::Is64BitOperatingSystem) {
    return (Join-Path $windir 'sysnative\reg.exe')
  }
  return (Join-Path $windir 'System32\reg.exe')
}

function Convert-RegKeyToHiveAndSubKey([string]$Key) {
  $m = [regex]::Match($Key, '^(?<hive>HKLM|HKCU|HKCR|HKU|HKCC|HKEY_LOCAL_MACHINE|HKEY_CURRENT_USER|HKEY_CLASSES_ROOT|HKEY_USERS|HKEY_CURRENT_CONFIG)\\(?<sub>.+)$')
  if (-not $m.Success) { return $null }
  $h = $m.Groups['hive'].Value.ToUpperInvariant()
  $sub = $m.Groups['sub'].Value
  $hive = $null
  switch ($h) {
    'HKLM' { $hive = [Microsoft.Win32.RegistryHive]::LocalMachine }
    'HKEY_LOCAL_MACHINE' { $hive = [Microsoft.Win32.RegistryHive]::LocalMachine }
    'HKCU' { $hive = [Microsoft.Win32.RegistryHive]::CurrentUser }
    'HKEY_CURRENT_USER' { $hive = [Microsoft.Win32.RegistryHive]::CurrentUser }
    'HKCR' { $hive = [Microsoft.Win32.RegistryHive]::ClassesRoot }
    'HKEY_CLASSES_ROOT' { $hive = [Microsoft.Win32.RegistryHive]::ClassesRoot }
    'HKU' { $hive = [Microsoft.Win32.RegistryHive]::Users }
    'HKEY_USERS' { $hive = [Microsoft.Win32.RegistryHive]::Users }
    'HKCC' { $hive = [Microsoft.Win32.RegistryHive]::CurrentConfig }
    'HKEY_CURRENT_CONFIG' { $hive = [Microsoft.Win32.RegistryHive]::CurrentConfig }
  }
  if ($null -eq $hive) { return $null }
  return [pscustomobject]@{ Hive = $hive; SubKey = $sub }
}

function Test-RegKeyAccessDenied([string]$Key) {
  try {
    $parsed = Convert-RegKeyToHiveAndSubKey -Key $Key
    if (-not $parsed) { return $false }
    $view = if ([Environment]::Is64BitOperatingSystem) { [Microsoft.Win32.RegistryView]::Registry64 } else { [Microsoft.Win32.RegistryView]::Default }
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($parsed.Hive, $view)
    try {
      $sub = $base.OpenSubKey($parsed.SubKey, $true)
      if ($null -eq $sub) {
        $subRO = $base.OpenSubKey($parsed.SubKey, $false)
        if ($null -ne $subRO) {
          $subRO.Dispose()
          return $true
        }
        return $false
      }
      $sub.Dispose()
      return $false
    } finally {
      $base.Dispose()
    }
  } catch [System.UnauthorizedAccessException] {
    return $true
  } catch [System.Security.SecurityException] {
    return $true
  } catch {
    return $false
  }
}

function Reg-Add([string]$Key, [string]$Name, [string]$Type, [string]$Data, [switch]$ReturnCode, [switch]$SuppressWarnOnAccessDenied, [switch]$ReturnResult) {
  $rc = -1
  $rcRaw = -1
  try {
    $regExe = Get-RegExePath
    & "$regExe" ADD $Key /v $Name /t $Type /d $Data /f | Out-Null 2>$null
    $rcRaw = $LASTEXITCODE
    $rc = $rcRaw
    if ($rc -ne 0 -and $SuppressWarnOnAccessDenied) {
      if (Test-RegKeyAccessDenied -Key $Key) {
        $rc = 5
        if ($VerboseLog) { Write-SetupLog ("Reg ADD {0}\{1} blocked (RC=5 AccessDenied suppressed)" -f $Key,$Name) 'DEBUG' }
      }
    }
    if ($VerboseLog) { Write-SetupLog ("Reg ADD {0}\{1} <{2}> = '{3}' (RC={4})" -f $Key,$Name,$Type,$Data,$rc) 'DEBUG' }
    if ($rc -ne 0 -and -not ($SuppressWarnOnAccessDenied -and $rc -eq 5)) { Write-SetupLog ("Reg ADD failed: {0}\{1} (RC={2})" -f $Key,$Name,$rc) 'WARN' }
  } catch {
    $rc = 1
    $rcRaw = $rc
    Write-SetupLog "Reg ADD failed: $Key\$Name - $($_.Exception.Message)" 'WARN'
  }
  if ($ReturnResult) { return [pscustomobject]@{ Raw = $rcRaw; Effective = $rc; Normalized = ($rcRaw -ne $rc) } }
  if ($ReturnCode) { return $rc }
}

function Reg-Del([string]$Key, [string]$Name, [switch]$ReturnCode, [switch]$SuppressWarnOnAccessDenied, [switch]$OkIfMissing, [switch]$ReturnResult) {
  $rc = -1
  $rcRaw = -1
  try {
    $regExe = Get-RegExePath
    & "$regExe" DELETE $Key /v $Name /f | Out-Null 2>$null
    $rcRaw = $LASTEXITCODE
    $rc = $rcRaw
    if ($rc -ne 0 -and $SuppressWarnOnAccessDenied) {
      if (Test-RegKeyAccessDenied -Key $Key) {
        $rc = 5
        if ($VerboseLog) { Write-SetupLog ("Reg DEL {0}\{1} blocked (RC=5 AccessDenied suppressed)" -f $Key,$Name) 'DEBUG' }
      }
    }
    if ($OkIfMissing -and $rcRaw -ne 5 -and $rc -ne 5) {
      $psKey = $null
      if ($Key -match '^(HKLM|HKEY_LOCAL_MACHINE)\\(.+)$') { $psKey = 'HKLM:\' + $Matches[2] }
      elseif ($Key -match '^(HKCU|HKEY_CURRENT_USER)\\(.+)$') { $psKey = 'HKCU:\' + $Matches[2] }
      elseif ($Key -match '^(HKCR|HKEY_CLASSES_ROOT)\\(.+)$') { $psKey = 'HKCR:\' + $Matches[2] }
      elseif ($Key -match '^(HKU|HKEY_USERS)\\(.+)$') { $psKey = 'HKU:\' + $Matches[2] }
      elseif ($Key -match '^(HKCC|HKEY_CURRENT_CONFIG)\\(.+)$') { $psKey = 'HKCC:\' + $Matches[2] }
      if ($psKey) {
        $state = Get-RegValueState -KeyPath $psKey -Name $Name
        if ($state.State -eq 'absent' -and $rc -ne 0 -and $rc -ne 2) { $rc = 0 }
      }
    }
    # Delete is idempotent in our flow: RC=0 is OK, RC=2 is treated as OK; with -OkIfMissing we may normalize non-5 failures to RC=0 only when read-back confirms the value is absent; AccessDenied (RC=5) is never normalized to success
    if ($rc -eq 0 -or $rc -eq 2) {
      if ($VerboseLog) { Write-SetupLog ("Reg DEL {0}\{1} (RC={2})" -f $Key,$Name,$rc) 'DEBUG' }
    } elseif ($SuppressWarnOnAccessDenied -and $rc -eq 5) {
      if ($VerboseLog) { Write-SetupLog ("Reg DEL {0}\{1} blocked (RC=5 AccessDenied suppressed)" -f $Key,$Name) 'DEBUG' }
    } else {
      Write-SetupLog ("Reg DEL failed: {0}\{1} (RC={2})" -f $Key,$Name,$rc) 'WARN'
    }
  } catch {
    $rc = 1
    $rcRaw = $rc
    Write-SetupLog "Reg DEL failed: $Key\$Name - $($_.Exception.Message)" 'WARN'
  }
  if ($ReturnResult) { return [pscustomobject]@{ Raw = $rcRaw; Effective = $rc; Normalized = ($rcRaw -ne $rc) } }
  if ($ReturnCode) { return $rc }
}

function Get-RegValueState([string]$KeyPath, [string]$Name) {
  try {
    $item = Get-ItemProperty -LiteralPath $KeyPath -ErrorAction Stop
    $prop = $item.PSObject.Properties[$Name]
    if ($null -eq $prop) {
      return [pscustomobject]@{ State = 'absent'; Value = $null; Error = $null }
    }
    return [pscustomobject]@{ State = 'present'; Value = $prop.Value; Error = $null }
  } catch {
    $msg = if ($_.Exception -and $_.Exception.Message) { $_.Exception.Message } else { $_.ToString() }
    return [pscustomobject]@{ State = 'error'; Value = $null; Error = $msg }
  }
}

function Test-ZeroDisabled([object]$Value) {
  if ($null -eq $Value) { return $false }
  try {
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [uint32] -or $Value -is [uint64] -or $Value -is [byte]) {
      return ([int64]$Value -eq 0)
    }
    return ($Value.ToString().Trim() -eq '0')
  } catch {
    return $false
  }
}

function Test-WinlogonSanitized([string]$WinlogonKeyPath) {
  $reasons = New-Object System.Collections.Generic.List[string]

  $dp = Get-RegValueState -KeyPath $WinlogonKeyPath -Name 'DefaultPassword'
  if ($dp.State -eq 'error') {
    [void]$reasons.Add(("DefaultPassword read error: {0}" -f $dp.Error))
  } elseif ($dp.State -eq 'present') {
    [void]$reasons.Add('DefaultPassword still present')
  }

  foreach ($name in @('AutoAdminLogon','ForceAutoLogon','AutoLogonCount')) {
    $v = Get-RegValueState -KeyPath $WinlogonKeyPath -Name $name
    if ($v.State -eq 'error') {
      [void]$reasons.Add(("{0} read error: {1}" -f $name, $v.Error))
    } elseif ($v.State -eq 'present' -and -not (Test-ZeroDisabled $v.Value)) {
      [void]$reasons.Add(("{0} not disabled (value={1})" -f $name, $v.Value))
    }
  }

  return [pscustomobject]@{ Ok = ($reasons.Count -eq 0); Reasons = @($reasons) }
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
  try {
    [void](Get-LocalUser -Name $User -ErrorAction Stop)
    return $true
  } catch {
    if ($_.CategoryInfo -and $_.CategoryInfo.Category -eq 'ObjectNotFound') { return $false }
    throw
  }
}
function Ensure-InAdministrators([string]$User) {
  $group = Get-LocalGroup -SID 'S-1-5-32-544' -ErrorAction Stop
  $localUser = Get-LocalUser -Name $User -ErrorAction Stop
  $userSid = [string]$localUser.SID
  $members = @(Get-LocalGroupMember -Group $group.Name -ErrorAction Stop)
  foreach ($m in $members) {
    $memberSid = [string]$m.SID
    if ($memberSid -and ($memberSid -eq $userSid)) {
      Write-SetupLog ("{0} already in {1}" -f $User,$group.Name) 'DEBUG'
      return 1378
    }
  }

  $memberName = "{0}\{1}" -f $env:COMPUTERNAME, $User
  try {
    Add-LocalGroupMember -Group $group.Name -Member $memberName -ErrorAction Stop
    Write-SetupLog ("Added {0} to {1}" -f $User,$group.Name)
    return 0
  } catch {
    $fqid = $_.FullyQualifiedErrorId
    $etype = $null; try { $etype = $_.Exception.GetType().FullName } catch {}
    $msg = if ($_.Exception -and $_.Exception.Message) { $_.Exception.Message } else { $_.ToString() }
    if (($fqid -and ($fqid -match 'MemberExists')) -or ($etype -and ($etype -match 'MemberExists')) -or ($msg -match '(?i)\balready\b.*\bmember\b.*\bgroup\b')) {
      Write-SetupLog ("{0} already in {1} (Add-LocalGroupMember idempotent)" -f $User,$group.Name) 'DEBUG'
      return 1378
    }
    throw
  }
}
function Ensure-InGroup([string]$Group, [string]$User) {
  try {
    $groupObj = $null
    if ($Group -match '^S-1-') {
      $groupObj = Get-LocalGroup -SID $Group -ErrorAction Stop
    } else {
      $groupObj = Get-LocalGroup -Name $Group -ErrorAction Stop
    }
    $localUser = Get-LocalUser -Name $User -ErrorAction Stop
    $userSid = [string]$localUser.SID
    $members = @(Get-LocalGroupMember -Group $groupObj.Name -ErrorAction Stop)
    foreach ($m in $members) {
      $memberSid = [string]$m.SID
      if ($memberSid -and ($memberSid -eq $userSid)) {
        Write-SetupLog ("Ensured {0} in {1}" -f $User,$groupObj.Name)
        return
      }
    }

    $memberName = "{0}\{1}" -f $env:COMPUTERNAME, $User
    try {
      Add-LocalGroupMember -Group $groupObj.Name -Member $memberName -ErrorAction Stop
      Write-SetupLog ("Ensured {0} in {1}" -f $User,$groupObj.Name)
    } catch {
      $fqid = $_.FullyQualifiedErrorId
      $etype = $null; try { $etype = $_.Exception.GetType().FullName } catch {}
      $msg = if ($_.Exception -and $_.Exception.Message) { $_.Exception.Message } else { $_.ToString() }
      if (($fqid -and ($fqid -match 'MemberExists')) -or ($etype -and ($etype -match 'MemberExists')) -or ($msg -match '(?i)\balready\b.*\bmember\b.*\bgroup\b')) {
        Write-SetupLog ("{0} already in {1} (Add-LocalGroupMember idempotent)" -f $User,$groupObj.Name) 'DEBUG'
        return
      }
      throw
    }
  } catch {
    throw
  }
}

function Test-AdministratorsMembership([string]$User) {
  try {
    $group = Get-LocalGroup -SID 'S-1-5-32-544' -ErrorAction Stop
    $localUser = Get-LocalUser -Name $User -ErrorAction Stop
    $userSid = [string]$localUser.SID
    $members = @(Get-LocalGroupMember -Group $group.Name -ErrorAction Stop)
    foreach ($m in $members) {
      $memberSid = [string]$m.SID
      if ($memberSid -and ($memberSid -eq $userSid)) { return $true }
    }
  } catch {
    Write-SetupLog ("LocalAccounts membership check failed for Administrators: {0}" -f $_.Exception.Message) 'WARN'
  }
  return $false
}

$rc = 0
$StageA_Succeeded = $false
$StageA_RC = 0
$StageAAbortReason = $null
$StageB_Succeeded = $false
$WinlogonSanitizedOk = $true

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

    if (-not [Environment]::Is64BitProcess) {
      $StageAAbortReason = 'Stage A requires 64-bit PowerShell process (Is64BitProcess=false)'
      Write-SetupLog $StageAAbortReason 'ERROR'
      throw [System.InvalidOperationException]::new($StageAAbortReason)
    }
    try {
      Import-Module Microsoft.PowerShell.LocalAccounts -ErrorAction Stop
    } catch {
      $StageAAbortReason = "Stage A preflight failed: unable to import Microsoft.PowerShell.LocalAccounts: $($_.Exception.Message)"
      Write-SetupLog $StageAAbortReason 'ERROR'
      throw [System.InvalidOperationException]::new($StageAAbortReason)
    }
    try {
      $requiredCmdlets = @(
        'Get-LocalUser','New-LocalUser','Set-LocalUser','Enable-LocalUser','Remove-LocalUser',
        'Get-LocalGroup','Get-LocalGroupMember','Add-LocalGroupMember'
      )
      foreach ($c in $requiredCmdlets) { [void](Get-Command -Name $c -ErrorAction Stop) }
      $getLocalGroupCmd = Get-Command -Name 'Get-LocalGroup' -ErrorAction Stop
      if (-not $getLocalGroupCmd.Parameters.ContainsKey('SID')) { throw "Get-LocalGroup missing required -SID parameter" }
      if ($PasswordNeverExpires) {
        $setLocalUserCmd = Get-Command -Name 'Set-LocalUser' -ErrorAction Stop
        if (-not $setLocalUserCmd.Parameters.ContainsKey('PasswordNeverExpires')) {
          throw "PasswordNeverExpires requested but Set-LocalUser does not support -PasswordNeverExpires on this system"
        }
      }
      [void](Get-LocalGroup -SID 'S-1-5-32-544' -ErrorAction Stop)
      if ($AddToRemoteDesktopUsers) { [void](Get-LocalGroup -SID 'S-1-5-32-555' -ErrorAction Stop) }
    } catch {
      $StageAAbortReason = "Stage A preflight failed: $($_.Exception.Message)"
      Write-SetupLog $StageAAbortReason 'ERROR'
      throw [System.InvalidOperationException]::new($StageAAbortReason)
    }

    Write-Verbose "Stage A: checking if $PrimaryUser exists"
    $createdNow = $false
    $securePwd = ConvertTo-SecureString -AsPlainText -Force -String $pwd
    try {
      $exists = Get-LocalUserExists $PrimaryUser
      if (-not $exists) {
        Write-Verbose "Stage A: creating local user $PrimaryUser"
        $newArgs = @{ Name = $PrimaryUser; Password = $securePwd; ErrorAction = 'Stop' }
        [void](New-LocalUser @newArgs)
        $createdNow = $true
        Write-SetupLog "User $PrimaryUser created"
      } else {
        Write-Verbose "Stage A: updating password for $PrimaryUser"
        Set-LocalUser -Name $PrimaryUser -Password $securePwd -ErrorAction Stop
        Write-SetupLog "Password updated for $PrimaryUser"
      }

      Enable-LocalUser -Name $PrimaryUser -ErrorAction Stop
      if (-not $createdNow) {
        try {
          & "$env:SystemRoot\System32\net.exe" user "$PrimaryUser" /logonpasswordchg:no | Out-Null 2>$null
          $chgRc = $LASTEXITCODE
          if ($chgRc -eq 0) {
            Write-SetupLog ("Cleared must-change-password-at-logon for {0} (net.exe /logonpasswordchg:no)" -f $PrimaryUser) 'DEBUG'
          } else {
            Write-SetupLog ("Failed to clear must-change-password-at-logon for {0} (net.exe rc={1}); continuing" -f $PrimaryUser,$chgRc) 'WARN'
          }
        } catch {
          Write-SetupLog ("Failed to clear must-change-password-at-logon for {0}: {1}; continuing" -f $PrimaryUser,$_.Exception.Message) 'WARN'
        }
      }

      $setArgs = @{ Name = $PrimaryUser; ErrorAction = 'Stop' }
      $doSet = $false
      if ($FullName) { $setArgs['FullName'] = $FullName; $doSet = $true }
      if ($Description) { $setArgs['Description'] = $Description; $doSet = $true }
      if ($PasswordNeverExpires) { $setArgs['PasswordNeverExpires'] = $true; $doSet = $true }
      if ($doSet) { Set-LocalUser @setArgs }

      Write-Verbose "Stage A: verifying Administrators membership via LocalAccounts"
      $isAdminMember = Test-AdministratorsMembership $PrimaryUser
      if ($isAdminMember) {
        Write-SetupLog "A: SKIP (already member)"
      } else {
        Write-Verbose ("Stage A: adding {0} to Administrators" -f $PrimaryUser)
        $addCode = Ensure-InAdministrators $PrimaryUser
        if ($addCode -eq 1378) {
          Write-SetupLog "A: SKIP (already member)"
        }
      }

      if ($AddToRemoteDesktopUsers) { Ensure-InGroup 'S-1-5-32-555' $PrimaryUser }
    } catch {
      $msg = if ($_.Exception -and $_.Exception.Message) { $_.Exception.Message } else { $_.ToString() }
      Write-SetupLog ("Stage A user provisioning failed for {0}: {1}" -f $PrimaryUser, $msg) 'ERROR'
      if ($createdNow) {
        try {
          Remove-LocalUser -Name $PrimaryUser -ErrorAction Stop
          Write-SetupLog ("Rolled back user {0} after Stage A failure" -f $PrimaryUser) 'WARN'
        } catch {
          Write-SetupLog ("Failed to delete user {0} during rollback: {1}" -f $PrimaryUser, $_.Exception.Message) 'ERROR'
        }
      } else {
        Write-SetupLog ("Skipping deletion because {0} existed before this run" -f $PrimaryUser) 'WARN'
      }
      throw
    }
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
  $wlMsg = 'Winlogon and logon policy reset: begin'
  Write-SetupLog $wlMsg
  $finalLogEntries += ("[{0}] {1}" -f ([DateTime]::UtcNow.ToString('o')), $wlMsg)
  $wl = 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
  $wlRcsRaw = @()
  $wlRcs = @()
  $wlAnyNormalized = $false
  $res = Reg-Del $wl 'DefaultUserName' -ReturnResult -SuppressWarnOnAccessDenied -OkIfMissing; $wlRcsRaw += $res.Raw; $wlRcs += $res.Effective; if ($res.Normalized) { $wlAnyNormalized = $true }
  $res = Reg-Del $wl 'DefaultDomainName' -ReturnResult -SuppressWarnOnAccessDenied -OkIfMissing; $wlRcsRaw += $res.Raw; $wlRcs += $res.Effective; if ($res.Normalized) { $wlAnyNormalized = $true }
  $res = Reg-Del $wl 'DefaultPassword' -ReturnResult -SuppressWarnOnAccessDenied -OkIfMissing; $wlRcsRaw += $res.Raw; $wlRcs += $res.Effective; if ($res.Normalized) { $wlAnyNormalized = $true }
  $res = Reg-Add $wl 'AutoAdminLogon' 'REG_SZ' '0' -ReturnResult -SuppressWarnOnAccessDenied; $wlRcsRaw += $res.Raw; $wlRcs += $res.Effective; if ($res.Normalized) { $wlAnyNormalized = $true }
  $res = Reg-Add $wl 'ForceAutoLogon' 'REG_SZ' '0' -ReturnResult -SuppressWarnOnAccessDenied; $wlRcsRaw += $res.Raw; $wlRcs += $res.Effective; if ($res.Normalized) { $wlAnyNormalized = $true }
  $res = Reg-Add $wl 'AutoLogonCount' 'REG_DWORD' '0' -ReturnResult -SuppressWarnOnAccessDenied; $wlRcsRaw += $res.Raw; $wlRcs += $res.Effective; if ($res.Normalized) { $wlAnyNormalized = $true }
  $res = Reg-Del $wl 'IgnoreShiftOverride' -ReturnResult -SuppressWarnOnAccessDenied -OkIfMissing; $wlRcsRaw += $res.Raw; $wlRcs += $res.Effective; if ($res.Normalized) { $wlAnyNormalized = $true }
  $res = Reg-Add $wl 'IgnoreShiftOverride' 'REG_SZ' '0' -ReturnResult -SuppressWarnOnAccessDenied; $wlRcsRaw += $res.Raw; $wlRcs += $res.Effective; if ($res.Normalized) { $wlAnyNormalized = $true }
  $wlAccessDenied = ($wlRcs -contains 5)
  $cleanRcOnly = $true
  foreach ($rc in $wlRcs) { if ($rc -ne 0 -and $rc -ne 2) { $cleanRcOnly = $false; break } }
  $wlMsg = if ($cleanRcOnly) { 'Winlogon and logon policy reset: attempted' } else { ("Winlogon and logon policy reset: attempted (wlRcs={0})" -f ($wlRcs -join ',')) }
  Write-SetupLog $wlMsg
  $finalLogEntries += ("[{0}] {1}" -f ([DateTime]::UtcNow.ToString('o')), $wlMsg)
  if ($VerboseLog -and $wlAnyNormalized) {
    $wlMsg = ("Winlogon reset rc detail: raw={0} effective={1}" -f ($wlRcsRaw -join ','), ($wlRcs -join ','))
    Write-SetupLog $wlMsg 'DEBUG'
    $finalLogEntries += ("[{0}] {1}" -f ([DateTime]::UtcNow.ToString('o')), $wlMsg)
  }
  if ($wlAccessDenied) { $isRecovery = $true }  # force recovery early (for recovery-specific steps below)
  Reg-Add 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'DisableCAD' 'REG_DWORD' '0'
  if ($isRecovery) {
    Reg-Add 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI\Ngc' 'DevicePasswordLessBuildVersion' 'REG_DWORD' '0'
    Write-SetupLog 'Recovery mode: forcing DevicePasswordLessBuildVersion=0 for troubleshooting' 'WARN'
  } else {
    Reg-Add 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI\Ngc' 'DevicePasswordLessBuildVersion' 'REG_DWORD' '2'
  }

  $wlPs = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
  $wlTest = Test-WinlogonSanitized -WinlogonKeyPath $wlPs
  if (-not $isRecovery -and $wlTest.Ok -and -not $wlAccessDenied) {
    $wlMsg = 'Winlogon cleanup verification passed (reset verified)'
    Write-SetupLog $wlMsg
    $finalLogEntries += ("[{0}] {1}" -f ([DateTime]::UtcNow.ToString('o')), $wlMsg)
  }
  if (-not $wlTest.Ok) {
    $WinlogonSanitizedOk = $false
    Write-SetupLog 'HARD FAIL: Winlogon cleanup verification failed; refusing to teardown executor/bootstrap.' 'ERROR'
    foreach ($reason in $wlTest.Reasons) { Write-SetupLog ("Winlogon verify: {0}" -f $reason) 'ERROR' }
    $finalLogEntries += ("[{0}] HARD FAIL: Winlogon cleanup verification failed; executor/bootstrap teardown suppressed" -f ([DateTime]::UtcNow.ToString('o')))
    foreach ($reason in $wlTest.Reasons) { $finalLogEntries += ("[{0}] Winlogon verify failure: {1}" -f ([DateTime]::UtcNow.ToString('o')), $reason) }
    if ($rc -eq 0) { $rc = 4 }
  }
  if ($wlAccessDenied) {
    $WinlogonSanitizedOk = $false
    $isRecovery = $true
    Write-SetupLog ("HARD FAIL: Winlogon cleanup blocked by ACL (AccessDenied, rc=5); refusing to teardown executor/bootstrap. wlRcs={0}" -f ($wlRcs -join ',')) 'ERROR'
    $finalLogEntries += ("[{0}] HARD FAIL: Winlogon cleanup blocked by ACL (AccessDenied, rc=5); executor/bootstrap teardown suppressed" -f ([DateTime]::UtcNow.ToString('o')))
    $finalLogEntries += ("[{0}] Winlogon cleanup rc summary: {1}" -f ([DateTime]::UtcNow.ToString('o')), ($wlRcs -join ','))
    $finalLogEntries += ("[{0}] Winlogon verify failure: Winlogon cleanup blocked by ACL (AccessDenied, rc=5)" -f ([DateTime]::UtcNow.ToString('o')))
    $finalLogEntries += ("[{0}] Stage B mode forced to recovery due to Winlogon AccessDenied" -f ([DateTime]::UtcNow.ToString('o')))
    if ($rc -eq 0) { $rc = 4 }
  }

  if (-not $isRecovery) {
    if ($WinlogonSanitizedOk) {
      Write-Verbose "Stage B: deactivating bootstrap account"
      & "$env:SystemRoot\System32\net.exe" user bootstrap /active:no | Out-Null 2>$null
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
        & "$env:SystemRoot\System32\schtasks.exe" /Delete /TN '\L2C\CreatePrimaryAdmin' /F | Out-Null 2>$null
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
      Write-SetupLog 'Winlogon cleanup verification failed; leaving bootstrap account enabled and scheduled task retained' 'ERROR'
    }
  } else {
    Write-SetupLog "Recovery mode: bootstrap account remains enabled and scheduled task retained" 'WARN'
  }

  # Stage B: remove transient password source files (best-effort)
  $pwCleanupState = 'skipped'
  $primaryPwCleanupState = 'skipped'
  if (-not $isRecovery -and $WinlogonSanitizedOk) {
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
  } elseif ($isRecovery) {
    Write-SetupLog 'Recovery mode: preserving bootstrap.pw and primaryadmin.pw for another Stage A attempt' 'WARN'
    $pwCleanupState = 'preserved'
    $primaryPwCleanupState = 'preserved'
  } else {
    Write-SetupLog 'Winlogon cleanup verification failed; preserving bootstrap.pw and primaryadmin.pw' 'ERROR'
    $pwCleanupState = 'preserved'
    $primaryPwCleanupState = 'preserved'
  }

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
  } elseif ($StageA_Succeeded -and (-not $WinlogonSanitizedOk)) {
    $outcomeLine = 'OUTCOME: FAIL - Winlogon cleanup verification failed (executor/bootstrap retained)'
  } elseif ($StageA_Succeeded) {
    $outcomeLine = 'OUTCOME: SUCCESS'
  } else {
    $outcomeLine = "OUTCOME: FAIL - Stage A failed (RC=$StageA_RC)"
  }
  $sw = New-Object System.IO.StreamWriter($MasterLogPath, $true, $utf8NoBom)
  $sw.WriteLine($outcomeLine)
  $sw.Dispose()
  $outcomeLevel = if ($SecretCleanupError -or (-not $WinlogonSanitizedOk)) { 'ERROR' } elseif ($StageA_Succeeded -and -not $StageAAbortReason) { 'INFO' } else { 'ERROR' }
  Write-SetupLog $outcomeLine $outcomeLevel
  if ($SecretCleanupError) {
    Write-SetupLog "End B (FAIL - secret cleanup error)" 'ERROR'
    if ($rc -eq 0) { $rc = 3 }
    $StageB_Succeeded = $false
  } elseif (-not $WinlogonSanitizedOk) {
    Write-SetupLog "End B (FAIL - Winlogon cleanup verification failed)" 'ERROR'
    if ($rc -eq 0) { $rc = 4 }
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
