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
    $args = @('ADD', $Key, '/v', $Name, '/t', $Type, '/d', $Data, '/f')
    Start-Process reg.exe -ArgumentList $args -WindowStyle Hidden -Wait | Out-Null
    if ($VerboseLog) { Write-SetupLog "Reg ADD $Key\$Name <$Type> = '$Data'" 'DEBUG' }
  } catch {
    Write-SetupLog "Reg ADD failed: $Key\$Name - $($_.Exception.Message)" 'WARN'
  }
}
function Reg-Del([string]$Key, [string]$Name) {
  try {
    $args = @('DELETE', $Key, '/v', $Name, '/f')
    Start-Process reg.exe -ArgumentList $args -WindowStyle Hidden -Wait -ErrorAction SilentlyContinue | Out-Null
    if ($VerboseLog) { Write-SetupLog "Reg DEL $Key\$Name" 'DEBUG' }
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
  & cmd /c "net user `"$User`"" | Out-Null
  return ($LASTEXITCODE -eq 0)
}
function Ensure-InAdministrators([string]$User) {
  & cmd /c "net localgroup Administrators `"$User`" /add" | Out-Null
  $code = $LASTEXITCODE
  if ($code -eq 0) {
    Write-SetupLog "Added $User to Administrators"
  } elseif ($code -eq 1378) {
    Write-SetupLog "$User already in Administrators" 'DEBUG'
  } else {
    throw "net localgroup Administrators exitcode $code"
  }
}
function Ensure-InGroup([string]$Group, [string]$User) {
  & cmd /c "net localgroup `"$Group`" `"$User`" /add" | Out-Null
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
    Write-SetupLog "ADSI update failed for $User: $($_.Exception.Message)" 'WARN'
  }
}

$rc = 0
try {
  if (-not $RollbackOnly) {
    Write-SetupLog "Begin A: Primary admin creation/config"
    $pwd = if ($PasswordPlain) { $PasswordPlain } else { New-StrongPassword 20 }
    if ($PasswordPlain) { if ($VerboseLog) { Write-SetupLog "Using explicit password via -PasswordPlain" 'DEBUG' } }
    else { if ($VerboseLog) { Write-SetupLog "Generated strong password (len $($pwd.Length), all classes present)" 'DEBUG' } }

    $exists = Get-LocalUserExists $PrimaryUser
    if (-not $exists) {
      & cmd /c "net user `"$PrimaryUser`" `"$pwd`" /add" | Out-Null
      if ($LASTEXITCODE -ne 0) { throw "Failed to create user $PrimaryUser (exitcode $LASTEXITCODE)" }
      & cmd /c "net user `"$PrimaryUser`" /active:yes" | Out-Null
      Write-SetupLog "User $PrimaryUser created and activated"
    } else {
      if ($PasswordPlain) {
        & cmd /c "net user `"$PrimaryUser`" `"$pwd`"" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Failed to set password for $PrimaryUser (exitcode $LASTEXITCODE)" }
        Write-SetupLog "Password updated for $PrimaryUser"
      } else {
        Write-SetupLog "User $PrimaryUser exists; password unchanged"
      }
      & cmd /c "net user `"$PrimaryUser`" /active:yes" | Out-Null
    }

    Set-UserAdsi -User $PrimaryUser -FullName $FullName -Description $Description -NeverExpire:$PasswordNeverExpires
    Ensure-InAdministrators $PrimaryUser
    if ($AddToRemoteDesktopUsers) { Ensure-InGroup 'Remote Desktop Users' $PrimaryUser }
    Write-SetupLog "End A: success"
  } else {
    Write-SetupLog "RollbackOnly specified: skipping Stage A"
  }
}
catch {
  Write-SetupLog "End A: FAILED - $($_.Exception.Message)" 'ERROR'
  $rc = 1
}

try {
  Write-SetupLog "Begin B: Autologon cleanup & policy restore"
  $wl = 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
  Reg-Del $wl 'DefaultPassword'
  Reg-Del $wl 'AutoLogonCount'
  Reg-Add $wl 'AutoAdminLogon' 'REG_SZ' '0'
  Reg-Add $wl 'ForceAutoLogon' 'REG_SZ' '0'
  Reg-Add $wl 'IgnoreShiftOverride' 'REG_DWORD' '0'
  Reg-Add 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'DisableCAD' 'REG_DWORD' '0'
  Reg-Add 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI\Ngc' 'DevicePasswordLessBuildVersion' 'REG_DWORD' '2'
  try {
    & cmd /c "net user bootstrap /active:no" | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-SetupLog "bootstrap deactivated" }
    else { if ($VerboseLog) { Write-SetupLog "bootstrap deactivate exitcode $LASTEXITCODE (ignored)" 'DEBUG' } }
  } catch {}
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
      Start-Process reg.exe -ArgumentList @('DELETE','HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce','/v','CreatePrimaryAdmin','/f') -WindowStyle Hidden -Wait | Out-Null
    }
    Write-SetupLog "RunOnce cleaned"
  } catch {
    Write-SetupLog "RunOnce cleanup warning: $($_.Exception.Message)" 'WARN'
  }
  Write-SetupLog "End B: success"
}
catch {
  Write-SetupLog "End B: FAILED - $($_.Exception.Message)" 'ERROR'
  if ($rc -eq 0) { $rc = 2 }
}

if ($Reboot) {
  Write-SetupLog "Reboot requested"
  Start-Process -FilePath 'shutdown.exe' -ArgumentList @('/r','/t','0') -WindowStyle Hidden
}
exit $rc