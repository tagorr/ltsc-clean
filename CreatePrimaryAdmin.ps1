[CmdletBinding()]
param(
  [string]$PrimaryUser = 'primaryadmin',
  [string]$FullName = '',
  [string]$Description = '',
  [string]$PasswordPlain = '',
  [switch]$PasswordNeverExpires,
  [switch]$AddToRemoteDesktopUsers,
  [switch]$Reboot,
  [switch]$RollbackOnly,
  [switch]$VerboseLog
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$LogPath = Join-Path $env:WINDIR 'Panther\SetupComplete.log'

function Write-SetupLog([string]$Message, [string]$Level = 'INFO') {
  try {
    $ts = [DateTime]::UtcNow.ToString('o')
    Add-Content -LiteralPath $LogPath -Value "[$ts] [CreatePrimaryAdmin] $Level $Message" -Encoding UTF8 -ErrorAction SilentlyContinue
  } catch {}
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
  $sym   = "!@#$%^&*-_=+".ToCharArray()
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
  & net.exe localgroup Administrators "$User" /add | Out-Null 2>$null
  $code = $LASTEXITCODE
  if ($code -eq 0) {
    Write-SetupLog "Added $User to Administrators"
  } elseif ($code -eq 1378) {
    Write-SetupLog "$User already in Administrators" 'DEBUG'
  } else {
    throw "net localgroup Administrators exitcode $code"
  }
  return $code
}
function Ensure-InGroup([string]$Group, [string]$User) {
  & net.exe localgroup "$Group" "$User" /add | Out-Null 2>$null
  $code = $LASTEXITCODE
  if ($code -eq 0 -or $code -eq 1378) {
    Write-SetupLog "Ensured $User in '$Group'"
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
    $group = [ADSI]("WinNT://$env:COMPUTERNAME/Administrators,group")
    foreach ($member in @($group.psbase.Invoke('Members'))) {
      $name = $member.GetType().InvokeMember('Name','GetProperty',$null,$member,$null)
      if ($name -and ($name -ieq $User)) { return $true }
    }
  } catch {
    Write-SetupLog "ADSI membership check failed for Administrators: $($_.Exception.Message)" 'WARN'
  }
  return $false
}

$rc = 0
$StageA_Succeeded = $false
$StageA_RC = 0

Write-SetupLog "Begin A: Primary admin creation/config"
try {
  if ($RollbackOnly) {
    Write-SetupLog "RollbackOnly specified: skipping Stage A"
    Write-Verbose "Stage A: RollbackOnly requested; marking as succeeded"
    $StageA_Succeeded = $true
  } else {
    $pwd = if ($PasswordPlain) { $PasswordPlain } else { New-StrongPassword 20 }
    if ($PasswordPlain) { if ($VerboseLog) { Write-SetupLog "Using explicit password via -PasswordPlain" 'DEBUG' } }
    else { if ($VerboseLog) { Write-SetupLog "Generated strong password (len $($pwd.Length), all classes present)" 'DEBUG' } }

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
      Write-Verbose "Stage A: adding $PrimaryUser to Administrators"
      $addCode = Ensure-InAdministrators $PrimaryUser
      if ($addCode -eq 1378) {
        Write-SetupLog "A: SKIP (already member)"
      }
    }

    if ($AddToRemoteDesktopUsers) { Ensure-InGroup 'Remote Desktop Users' $PrimaryUser }
    $StageA_Succeeded = $true
  }
}
catch {
  $StageA_RC = 1
  Write-SetupLog ("End A (FAIL, RC={0}) - {1}" -f $StageA_RC, $_.Exception.Message) 'ERROR'
  $rc = 1
}

if ($StageA_Succeeded) {
  $StageA_RC = 0
  Write-SetupLog "End A (SUCCESS, RC=0)"
}

if ($StageA_Succeeded) {
  Write-SetupLog "Begin B: Autologon cleanup & policy restore"
  try {
    Write-Verbose "Stage B: resetting Winlogon autologon state"
    $wl = 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    Reg-Del $wl 'DefaultPassword'
    Reg-Del $wl 'AutoLogonCount'
    Reg-Add $wl 'AutoAdminLogon' 'REG_SZ' '0'
    Reg-Add $wl 'ForceAutoLogon' 'REG_SZ' '0'
    Reg-Del $wl 'IgnoreShiftOverride'
    Reg-Add $wl 'IgnoreShiftOverride' 'REG_SZ' '0'
    Reg-Add 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'DisableCAD' 'REG_DWORD' '0'
    Reg-Add 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI\Ngc' 'DevicePasswordLessBuildVersion' 'REG_DWORD' '2'

    Write-Verbose "Stage B: deactivating bootstrap account"
    & net.exe user bootstrap /active:no | Out-Null 2>$null
    if ($LASTEXITCODE -eq 0) { Write-SetupLog "bootstrap deactivated" }
    else { if ($VerboseLog) { Write-SetupLog "bootstrap deactivate exitcode $LASTEXITCODE (ignored)" 'DEBUG' } }

    Write-Verbose "Stage B: cleaning RunOnce entries"
    try {
      $ro = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
      $me = $MyInvocation.MyCommand.Path
      $props = Get-ItemProperty -LiteralPath $ro -ErrorAction SilentlyContinue
      if ($props) {
        foreach ($n in ($props | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name)) {
          $v = (Get-ItemPropertyValue -LiteralPath $ro -Name $n -ErrorAction SilentlyContinue) 2>$null
          if (($n -eq 'CreatePrimaryAdmin') -or ($v -is [string] -and $me -and ($v -match [regex]::Escape($me))) -or ($v -is [string] -and $v -match 'CreatePrimaryAdmin\.ps1')) {
            try { Remove-ItemProperty -LiteralPath $ro -Name $n -ErrorAction SilentlyContinue } catch {}
          }
        }
        & reg.exe DELETE HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce /v CreatePrimaryAdmin /f | Out-Null 2>$null # Defensive sweep for stubborn values
      }
      Write-SetupLog "RunOnce cleaned"
    } catch {
      Write-SetupLog "RunOnce cleanup warning: $($_.Exception.Message)" 'WARN'
    }

    # Stage B: remove transient password source file (best-effort)
    try {
      $pwPath = Join-Path $env:WINDIR 'Setup\Scripts\.bootstrap.pw'
      if (Test-Path -LiteralPath $pwPath) {
        Remove-Item -LiteralPath $pwPath -Force -ErrorAction Stop
        Write-SetupLog "bootstrap.pw removed"
      } else {
        if ($VerboseLog) { Write-SetupLog "bootstrap.pw not found (ok)" 'DEBUG' }
      }
    } catch {
      Write-SetupLog ("bootstrap.pw delete warning: {0}" -f $_.Exception.Message) 'WARN'
    }

    Write-SetupLog "End B (SUCCESS)"
  }
  catch {
    Write-SetupLog ("End B (FAIL) - {0}" -f $_.Exception.Message) 'ERROR'
    if ($rc -eq 0) { $rc = 2 }
  }
} else {
  Write-SetupLog ("Stage B skipped (Stage A failed, RC={0})" -f $StageA_RC) 'WARN'
}

if ($Reboot) {
  Write-SetupLog "Reboot requested"
  Start-Process -FilePath 'shutdown.exe' -ArgumentList @('/r','/t','0') -WindowStyle Hidden
}
exit $rc
