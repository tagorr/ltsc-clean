[CmdletBinding()]
param(
  [string]$PrimaryUser = 'primaryadmin',
  [string]$FullName = '',
  [string]$Description = '',
  [string]$PasswordPlain = '',
  [switch]$PasswordNeverExpires,
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
function Invoke-RngFill([byte[]]$Buffer) {
  $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
  try { $rng.GetBytes($Buffer) } finally { $rng.Dispose() }
}
function New-StrongPassword([int]$Length = 20) {
  if ($Length -lt 12) { $Length = 12 }
  $upper = "ABCDEFGHIJKLMNOPQRSTUVWXYZ".ToCharArray()
  $lower = "abcdefghijklmnopqrstuvwxyz".ToCharArray()
  $digits = "0123456789".ToCharArray()
  $sym   = "!@#$^*-_=+".ToCharArray()
  $all = ($upper + $lower + $digits + $sym)
  $bytes = New-Object byte[] ($Length)
  Invoke-RngFill $bytes
  $chars = New-Object char[] ($Length)
  $chars[0] = $upper[$bytes[0] % $upper.Length]
  $chars[1] = $lower[$bytes[1] % $lower.Length]
  $chars[2] = $digits[$bytes[2] % $digits.Length]
  $chars[3] = $sym[$bytes[3] % $sym.Length]
  for ($i = 4; $i -lt $Length; $i++) { $chars[$i] = $all[$bytes[$i] % $all.Length] }
  $shuffle = New-Object byte[] ($Length)
  Invoke-RngFill $shuffle
  for ($i = 0; $i -lt $Length; $i++) { $j = $shuffle[$i] % $Length; $t = $chars[$i]; $chars[$i] = $chars[$j]; $chars[$j] = $t }
  -join $chars
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
    $PasswordPlain = $PasswordPlain.Trim()
    if (-not $PasswordPlain) {
      $StageAAbortReason = 'primary admin secret missing (-PasswordPlain is required)'
      throw [System.InvalidOperationException]::new($StageAAbortReason)
    }
    $pwd = $PasswordPlain
    if ($VerboseLog) { Write-SetupLog "Using explicit password via -PasswordPlain" 'DEBUG' }

    Write-Verbose "Stage A: checking if $PrimaryUser exists"
    $exists = Get-LocalUserExists $PrimaryUser
    if (-not $exists) {
      Write-Verbose "Stage A: creating local user $PrimaryUser"
      & net.exe user "$PrimaryUser" "$pwd" /add | Out-Null 2>$null
      if ($LASTEXITCODE -ne 0) { throw "Failed to create user $PrimaryUser (exitcode $LASTEXITCODE)" }
      & net.exe user "$PrimaryUser" /active:yes | Out-Null 2>$null
      if ($LASTEXITCODE -ne 0) { throw "Failed to activate user $PrimaryUser (exitcode $LASTEXITCODE)" }
      Write-SetupLog "User $PrimaryUser created and activated"
    } else {
      if ($PasswordPlain) {
        Write-Verbose "Stage A: updating password for $PrimaryUser"
        & net.exe user "$PrimaryUser" "$pwd" | Out-Null 2>$null
        if ($LASTEXITCODE -ne 0) { throw "Failed to set password for $PrimaryUser (exitcode $LASTEXITCODE)" }
        Write-SetupLog "Password updated for $PrimaryUser"
      } else {
        Write-SetupLog "User $PrimaryUser exists; password unchanged"
      }
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

  # Stage B: remove transient password source file (best-effort)
  $pwCleanupState = 'skipped'
  if (-not $isRecovery) {
    $pwCleanupState = 'unknown'
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
  } else {
    Write-SetupLog 'Recovery mode: preserving bootstrap.pw for another Stage A attempt' 'WARN'
    $pwCleanupState = 'preserved'
  }

  $finalLogEntries += ("[{0}] RunOnce cleanup complete" -f ([DateTime]::UtcNow.ToString('o')))
  if ($pwCleanupState -ne 'unknown') {
    $finalLogEntries += ("[{0}] bootstrap.pw cleanup state={1}" -f ([DateTime]::UtcNow.ToString('o')), $pwCleanupState)
  }
  $finalLogEntries += ("[{0}] Stage B finalize end" -f ([DateTime]::UtcNow.ToString('o')))

  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllLines($MasterLogPath, $finalLogEntries, $utf8NoBom)
  Write-SetupLog ("Master log created: {0}" -f $MasterLogPath)
  if ($StageAAbortReason) {
    $outcomeLine = "OUTCOME: ABORTED - $StageAAbortReason"
  } elseif ($StageA_Succeeded) {
    $outcomeLine = 'OUTCOME: SUCCESS'
  } else {
    $outcomeLine = "OUTCOME: FAIL - Stage A failed (RC=$StageA_RC)"
  }
  $sw = New-Object System.IO.StreamWriter($MasterLogPath, $true, $utf8NoBom)
  $sw.WriteLine($outcomeLine)
  $sw.Dispose()
  $outcomeLevel = if ($StageA_Succeeded -and -not $StageAAbortReason) { 'INFO' } else { 'ERROR' }
  Write-SetupLog $outcomeLine $outcomeLevel
  if ($StageA_Succeeded) {
    Write-SetupLog "End B (SUCCESS)"
  } else {
    Write-SetupLog "End B (RECOVERY COMPLETE)" 'WARN'
  }
  $StageB_Succeeded = $true
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
  if (-not $StageB_Succeeded) {
    Write-SetupLog 'Reboot flag present but Stage B did not complete successfully; suppressing automatic reboot to allow operator inspection' 'WARN'
  } elseif ($isRecovery) {
    Write-SetupLog 'Reboot flag present in recovery mode; not rebooting to allow operator fix' 'WARN'
  } else {
    Write-SetupLog 'Reboot flag detected, initiating restart'
    Remove-Item -LiteralPath $flag -Force -ErrorAction SilentlyContinue
    & "$env:SystemRoot\System32\shutdown.exe" /r /t 0
    exit $rc
  }
}

exit $rc
