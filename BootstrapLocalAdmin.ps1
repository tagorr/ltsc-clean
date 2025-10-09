[CmdletBinding()]
param()

function Invoke-RngFill([byte[]]$buffer) {
  $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
  try { $rng.GetBytes($buffer) } finally { $rng.Dispose() }
}

# Minimal, idempotent bootstrap: create temporary admin .\bootstrap,
# arm one-time autologon, register RunOnce for CreatePrimaryAdmin.ps1

$ErrorActionPreference = 'Stop'

function Write-SetupLog {
    param([string]$Message)
    try {
        $log = Join-Path $env:WINDIR 'Panther\SetupComplete.log'
        $line = $Message + "`r`n"
        [System.IO.File]::AppendAllText($log, $line, [Text.UTF8Encoding]::new($false))
    } catch { }
}

function Get-AdministratorsGroupName {
    try {
        $sid = New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-32-544'
        return ($sid.Translate([System.Security.Principal.NTAccount]).Value.Split('\\')[-1])
    } catch {
        return 'Administrators'
    }
}

function New-RandomPassword {
    param([int]$Length = 22)
    # Allowed: A-Za-z0-9 and !@#%+_-
    $chars = ('ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!@#%+_-' ).ToCharArray()
    $buf = New-Object byte[] ($Length)
    Invoke-RngFill($buf)
    $sb = New-Object System.Text.StringBuilder
    foreach ($b in $buf) { [void]$sb.Append($chars[$b % $chars.Length]) }
    $pw = $sb.ToString()
    if ($pw -notmatch '[A-Z]')      { $pw = 'A' + $pw.Substring(1) }
    if ($pw -notmatch '[a-z]')      { $pw = $pw.Substring(0,1) + 'z' + $pw.Substring(2) }
    if ($pw -notmatch '\\d')         { $pw = $pw.Substring(0,2) + '7' + $pw.Substring(3) }
    if ($pw -notmatch '[!@#%+_\\-]') { $pw = $pw.Substring(0,3) + '_' + $pw.Substring(4) }
    return $pw
}

$winlogonPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
$runOncePath  = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'

# Fast idempotency check: autologon/policies already armed?
try {
    $wl = Get-ItemProperty -Path $winlogonPath -ErrorAction SilentlyContinue
    $polCAD = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction SilentlyContinue
    $pwdless = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\PasswordLess\Device' -ErrorAction SilentlyContinue

    $armed = ($null -ne $wl -and
              $wl.DefaultUserName   -eq 'bootstrap' -and
              $wl.DefaultDomainName -eq $env:COMPUTERNAME -and
              ([int]$wl.AutoLogonCount) -gt 0)

    $polOK = (($polCAD -and $polCAD.DisableCAD -eq 1) -and
              ($pwdless -and $pwdless.DevicePasswordLessBuildVersion -eq 0))

    if ($armed -and $polOK) {
        New-Item -Path $runOncePath -Force | Out-Null
        $cmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SystemRoot%\Setup\Scripts\CreatePrimaryAdmin.ps1"'
        New-ItemProperty -Path $runOncePath -Name 'CreatePrimaryAdmin' -Value $cmd -PropertyType String -Force | Out-Null
        Write-SetupLog "[INFO] Bootstrap already armed; RunOnce verified"
        return
    }
} catch { }

# 1) Generate password (do not log or print it)
$pwd = New-RandomPassword

# 2) Create/ensure .\bootstrap is local admin
$adminGroup = Get-AdministratorsGroupName
try {
    $exists = $false
    & cmd.exe /c "net user bootstrap >nul 2>nul"
    if ($LASTEXITCODE -eq 0) { $exists = $true }
    if ($exists) {
        & net.exe user bootstrap $pwd | Out-Null
    } else {
        & net.exe user bootstrap $pwd /add /y | Out-Null
    }
    & net.exe localgroup "$adminGroup" bootstrap /add | Out-Null
} catch {
    Write-SetupLog "[INFO] Failed to create/ensure bootstrap admin: $($_.Exception.Message)"
    throw
}

# 2.5) Enable password-based autologon (disable CAD & Passwordless)
try {
  & reg.exe ADD "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v DisableCAD /t REG_DWORD /d 1 /f | Out-Null
  & reg.exe ADD "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\PasswordLess\Device" /v DevicePasswordLessBuildVersion /t REG_DWORD /d 0 /f | Out-Null
} catch { Write-SetupLog "[INFO] CAD/Passwordless tweak failed" }

# 2.6) Autologon hardening (remove blockers, ignore Shift)
try {
  & reg.exe DELETE "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v LegalNoticeCaption /f | Out-Null
  & reg.exe DELETE "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v LegalNoticeText    /f | Out-Null
  & reg.exe ADD    "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v DontDisplayLastUserName /t REG_DWORD /d 0 /f | Out-Null
  & reg.exe ADD    "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"     /v IgnoreShiftOverride     /t REG_SZ    /d 0 /f | Out-Null
} catch { Write-SetupLog "[INFO] Autologon hardening failed" }

# 3) Arm one-time autologon
try {
    if (-not (Test-Path $winlogonPath)) { New-Item -Path $winlogonPath | Out-Null }
    New-ItemProperty -Path $winlogonPath -Name 'AutoAdminLogon'    -Value '1'               -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $winlogonPath -Name 'AutoLogonCount'    -Value 2                 -PropertyType DWord  -Force | Out-Null
    New-ItemProperty -Path $winlogonPath -Name 'DefaultUserName'   -Value 'bootstrap'       -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $winlogonPath -Name 'DefaultDomainName' -Value $env:COMPUTERNAME -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $winlogonPath -Name 'DefaultPassword'   -Value $pwd              -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $winlogonPath -Name 'ForceAutoLogon'    -Value '1'               -PropertyType String -Force | Out-Null
} catch {
    Write-SetupLog "[INFO] Failed to arm autologon: $($_.Exception.Message)"
    throw
}

# 4) Register RunOnce for the primary admin creation wizard
try {
    New-Item -Path $runOncePath -Force | Out-Null
    $cmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SystemRoot%\Setup\Scripts\CreatePrimaryAdmin.ps1"'
    New-ItemProperty -Path $runOncePath -Name 'CreatePrimaryAdmin' -Value $cmd -PropertyType String -Force | Out-Null
} catch {
    Write-SetupLog "[INFO] Failed to register RunOnce: $($_.Exception.Message)"
    throw
}

# 5) Minimal logging
Write-SetupLog "[INFO] Bootstrap admin created (one-time autologon armed)"
Write-SetupLog "[INFO] RunOnce registered: CreatePrimaryAdmin.ps1"
