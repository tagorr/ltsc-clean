# Generate bootstrap password (A-Za-z0-9 and safe symbols)
$chars = [char[]]'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789#@_-'

if (-not $chars -or $chars.Count -eq 0) {
    throw 'Internal error: empty password charset'
}

$rnd   = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
$bytes = New-Object byte[] (24)
try {
    $rnd.GetBytes($bytes)
}
finally {
    $rnd.Dispose()
}

$PasswordPlain = -join ($bytes | ForEach-Object { $chars[ $_ % $chars.Count ] })

$ErrorActionPreference = 'Stop'

function Write-BootstrapLog {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Message,

        [ValidateSet('INFO','WARN','ERROR')]
        [string] $Level = 'INFO'
    )

    Write-Host ("[BOOTSTRAP] [{0}] {1}" -f $Level, $Message)
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

$exitCode = 0

try {
    $u = 'bootstrap'

    Write-BootstrapLog ("Starting bootstrap for local admin '{0}'" -f $u)

    # Ensure user exists; create if missing (rc 0 = created, 2 = already exists)
    Write-BootstrapLog ("Ensuring local user '{0}' exists" -f $u)
    & net.exe user $u /add /y | Out-Null 2>$null
    $rc = $LASTEXITCODE
    if ($rc -ne 0 -and $rc -ne 2) {
        Write-BootstrapLog ("Failed to create user '{0}' (rc={1})" -f $u, $rc) 'ERROR'
        throw [System.Exception]::new("Failed to create user '$u' (rc=$rc).")
    } elseif ($rc -eq 0) {
        Write-BootstrapLog ("Local user '{0}' created" -f $u)
    } else {
        Write-BootstrapLog ("Local user '{0}' already exists" -f $u)
    }

    # Always set password explicitly and activate
    Write-BootstrapLog ("Setting password and activating '{0}'" -f $u)
    Set-L2CLocalUserPasswordAdsi -UserName $u -Password $PasswordPlain
    & net.exe user $u /active:yes | Out-Null 2>$null
    if ($LASTEXITCODE -ne 0) {
        $rc = $LASTEXITCODE
        Write-BootstrapLog ("Failed to set password/activate '{0}' (rc={1})" -f $u, $rc) 'ERROR'
        throw [System.Exception]::new("Failed to set password/activate '$u' (rc=$rc).")
    }

    # Resolve Administrators via SID to stay locale-agnostic
    $adminsSid = [System.Security.Principal.SecurityIdentifier]'S-1-5-32-544'
    $adminsAccount = $adminsSid.Translate([System.Security.Principal.NTAccount])
    $adminGroup = $adminsAccount.Value.Split('\')[-1]

    Write-BootstrapLog ("Resolved Administrators group as '{0}'" -f $adminGroup)

    # Add to Administrators (2 = already a member)
    Write-BootstrapLog ("Adding '{0}' to local group '{1}'" -f $u, $adminGroup)
    & net.exe localgroup $adminGroup $u /add | Out-Null 2>$null
    $rc = $LASTEXITCODE
    if ($rc -ne 0 -and $rc -ne 2) {
        Write-BootstrapLog ("Failed to add '{0}' to Administrators (rc={1})" -f $u, $rc) 'ERROR'
        throw [System.Exception]::new("Failed to add '$u' to Administrators (rc=$rc).")
    } elseif ($rc -eq 0) {
        Write-BootstrapLog ("User '{0}' added to Administrators" -f $u)
    } else {
        Write-BootstrapLog ("User '{0}' already in Administrators" -f $u)
    }

    $pwPath = Join-Path $env:WINDIR 'Setup\Scripts\.bootstrap.pw'

    # Ensure folder exists
    $folder = Split-Path $pwPath -Parent
    Write-BootstrapLog ("Ensuring folder '{0}' exists for .bootstrap.pw" -f $folder)
    if (-not (Test-Path $folder)) {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
    }

    # Write as UTF-8 without BOM and no newline noise
    Write-BootstrapLog ("Writing bootstrap password file to '{0}'" -f $pwPath)
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($pwPath, $PasswordPlain, $utf8NoBom)

    # Reset ACL: SYSTEM:(F), Administrators:(F) only, locale-agnostic
    try {
        Write-BootstrapLog ("Applying ACL to '{0}' (SYSTEM + Administrators, no inheritance)" -f $pwPath)

        $acl = Get-Acl -LiteralPath $pwPath
        $acl.SetAccessRuleProtection($true, $false)
        $acl.Access | ForEach-Object { [void]$acl.RemoveAccessRule($_) }

        $ruleSystem = New-Object System.Security.AccessControl.FileSystemAccessRule 'NT AUTHORITY\SYSTEM','FullControl','Allow'
        $ruleAdmins = New-Object System.Security.AccessControl.FileSystemAccessRule $adminsAccount,'FullControl','Allow'

        [void]$acl.AddAccessRule($ruleSystem)
        [void]$acl.AddAccessRule($ruleAdmins)

        Set-Acl -LiteralPath $pwPath -AclObject $acl

        Write-BootstrapLog ("ACL applied to '{0}' successfully" -f $pwPath)
    } catch {
        Write-BootstrapLog ("Failed to apply ACL to '{0}': {1}" -f $pwPath, $_.Exception.Message) 'ERROR'
        Write-Error ("[ERROR] Failed to apply ACL to '{0}': {1}" -f $pwPath, $_.Exception.Message)
        throw
    }

    # Hide as system/hidden
    Write-BootstrapLog ("Setting Hidden+System attributes on '{0}'" -f $pwPath)
    $item = Get-Item $pwPath
    $item.Attributes = 'Hidden','System','Archive'

    Write-BootstrapLog "Bootstrap lifecycle completed successfully"
}
catch {
    $exitCode = 1
    if ($_.Exception -and $_.Exception.Message) {
        Write-BootstrapLog ("BootstrapLocalAdmin.ps1 failed: {0}" -f $_.Exception.Message) 'ERROR'
        Write-Error $_.Exception.Message
    } else {
        Write-BootstrapLog ("BootstrapLocalAdmin.ps1 failed: {0}" -f $_) 'ERROR'
        Write-Error $_
    }
}

exit $exitCode
