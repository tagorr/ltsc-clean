[CmdletBinding()]
param(
    [string]$PasswordPlain
)

# Generate default password if not supplied (A-Za-z2-9 and safe symbols)
if (-not $PasswordPlain -or $PasswordPlain -eq '') {
    $chars = ('A'..'Z') + ('a'..'z') + ('2'..'9') + @('#','@','%','_','-')
    $rnd = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
    $bytes = New-Object byte[] (24)
    try {
        $rnd.GetBytes($bytes)
    } finally {
        $rnd.Dispose()
    }
    $PasswordPlain = -join ($bytes | ForEach-Object { $chars[ $_ % $chars.Count ] })
}

$ts = Get-Date -Format 'yyyy-MM-dd_HHmmss'
$LogPath = Join-Path $env:ProgramData "l2c_bootstrap_$ts.log"
Start-Transcript -Path $LogPath -Append | Out-Null

$ErrorActionPreference = 'Stop'

$exitCode = 0

try {
    $u = 'bootstrap'

    # Ensure user exists; create if missing (rc 0 = created, 2 = already exists)
    & net.exe user $u $PasswordPlain /add /y | Out-Null 2>$null
    $rc = $LASTEXITCODE
    if ($rc -ne 0 -and $rc -ne 2) {
        throw [System.Exception]::new("Failed to create user '$u' (rc=$rc).")
    }

    # Always set password explicitly and activate
    & net.exe user $u $PasswordPlain /active:yes | Out-Null 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw [System.Exception]::new("Failed to set password/activate '$u' (rc=$LASTEXITCODE).")
    }

    # Add to Administrators (1378 = already a member)
    $adminGroup = ([System.Security.Principal.SecurityIdentifier]'S-1-5-32-544').Translate([System.Security.Principal.NTAccount]).Value.Split('\')[-1]
    & net.exe localgroup $adminGroup $u /add | Out-Null 2>$null
    $rc = $LASTEXITCODE
    if ($rc -ne 0 -and $rc -ne 1378) {
        throw [System.Exception]::new("Failed to add '$u' to Administrators (rc=$rc).")
    }

    $pwPath = Join-Path $env:WINDIR 'Setup\Scripts\.bootstrap.pw'

    # Ensure folder exists
    $folder = Split-Path $pwPath -Parent
    if (-not (Test-Path $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }

    # Write as UTF-8 without BOM and no newline noise
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($pwPath, $PasswordPlain, $utf8NoBom)

    # Reset ACL: SYSTEM:(F), Administrators:(F) only
    $acl = New-Object System.Security.AccessControl.FileSecurity
    $rule1 = New-Object System.Security.AccessControl.FileSystemAccessRule('SYSTEM','FullControl','Allow')
    $rule2 = New-Object System.Security.AccessControl.FileSystemAccessRule('Administrators','FullControl','Allow')
    $acl.SetOwner([System.Security.Principal.NTAccount]'SYSTEM')
    $acl.SetAccessRuleProtection($true, $false)  # disable inheritance
    [void]$acl.AddAccessRule($rule1)
    [void]$acl.AddAccessRule($rule2)
    Set-Acl -Path $pwPath -AclObject $acl

    # Hide as system/hidden
    $item = Get-Item $pwPath
    $item.Attributes = 'Hidden','System','Archive'

    Write-Host "[INFO] bootstrap lifecycle completed"
}
catch {
    $exitCode = 1
    if ($_.Exception -and $_.Exception.Message) {
        Write-Error $_.Exception.Message
    } else {
        Write-Error $_
    }
}
finally {
    try { Stop-Transcript | Out-Null } catch { }
}

exit $exitCode
