# Generate bootstrap password (A-Za-z0-9 and safe symbols)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
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

function Write-BootstrapLog {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Message,

        [ValidateSet('INFO','WARN','ERROR')]
        [string] $Level = 'INFO'
    )

    Write-Host ("[BOOTSTRAP] [{0}] {1}" -f $Level, $Message)
}

$exitCode = 0

try {
    $u = 'bootstrap'

    Write-BootstrapLog ("Starting bootstrap for local admin '{0}'" -f $u)

    # Require LocalAccounts cmdlets (avoid secret-on-CLI)
    try {
        Import-Module Microsoft.PowerShell.LocalAccounts -ErrorAction Stop

        $requiredCmdlets = @(
            'Get-LocalUser',
            'New-LocalUser',
            'Set-LocalUser',
            'Enable-LocalUser',
            'Get-LocalGroup',
            'Get-LocalGroupMember',
            'Add-LocalGroupMember'
        )

        foreach ($c in $requiredCmdlets) {
            if (-not (Get-Command -Name $c -ErrorAction SilentlyContinue)) {
                throw [System.Exception]::new("Missing required cmdlet '$c'.")
            }
        }
    } catch {
        Write-BootstrapLog ("LocalAccounts module/cmdlets unavailable: {0}" -f $_.Exception.Message) 'ERROR'
        throw
    }

    $pwSecure = ConvertTo-SecureString -String $PasswordPlain -AsPlainText -Force

    # Ensure user exists; create if missing (rc 0 = created, 2 = already exists)
    Write-BootstrapLog ("Ensuring local user '{0}' exists" -f $u)
    try {
        $existingUser = Get-LocalUser -Name $u -ErrorAction SilentlyContinue
        if ($null -eq $existingUser) {
            New-LocalUser -Name $u -Password $pwSecure -ErrorAction Stop | Out-Null
            Write-BootstrapLog ("Local user '{0}' created" -f $u)
        } else {
            Write-BootstrapLog ("Local user '{0}' already exists" -f $u)
        }
    } catch {
        Write-BootstrapLog ("Failed to create user '{0}': {1}" -f $u, $_.Exception.Message) 'ERROR'
        throw
    }

    # Always set password explicitly and activate
    Write-BootstrapLog ("Setting password and activating '{0}'" -f $u)
    try {
        Set-LocalUser -Name $u -Password $pwSecure -ErrorAction Stop
        Enable-LocalUser -Name $u -ErrorAction Stop
    } catch {
        Write-BootstrapLog ("Failed to set password/activate '{0}': {1}" -f $u, $_.Exception.Message) 'ERROR'
        throw
    }

    # Resolve Administrators via SID to stay locale-agnostic
    $adminsSid = [System.Security.Principal.SecurityIdentifier]'S-1-5-32-544'
    try {
        $adminGroup = (Get-LocalGroup -SID $adminsSid.Value -ErrorAction Stop).Name
    } catch {
        Write-BootstrapLog ("Failed to resolve Administrators group via SID '{0}': {1}" -f $adminsSid.Value, $_.Exception.Message) 'ERROR'
        throw
    }

    Write-BootstrapLog ("Resolved Administrators group as '{0}'" -f $adminGroup)

    # Add to Administrators (2 = already a member)
    Write-BootstrapLog ("Adding '{0}' to local group '{1}'" -f $u, $adminGroup)
    try {
        $members = @(Get-LocalGroupMember -Group $adminGroup -ErrorAction Stop)
        $uFull = ('{0}\{1}' -f $env:COMPUTERNAME, $u)

        $alreadyMember = $false
        foreach ($m in $members) {
            if ($null -ne $m -and $null -ne $m.Name) {
                if ($m.Name -ieq $uFull -or $m.Name -ieq $u -or $m.Name -ieq ('.\{0}' -f $u)) {
                    $alreadyMember = $true
                    break
                }
            }
        }

        if ($alreadyMember) {
            Write-BootstrapLog ("User '{0}' already in Administrators" -f $u)
        } else {
            Add-LocalGroupMember -Group $adminGroup -Member $uFull -ErrorAction Stop
            Write-BootstrapLog ("User '{0}' added to Administrators" -f $u)
        }
    } catch {
        Write-BootstrapLog ("Failed to add '{0}' to Administrators: {1}" -f $u, $_.Exception.Message) 'ERROR'
        throw
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
        try {
            $adminsNtAccount = $adminsSid.Translate([System.Security.Principal.NTAccount])
        } catch {
            Write-BootstrapLog ("Failed to translate Administrators SID '{0}' to NTAccount for ACL: {1}" -f $adminsSid.Value, $_.Exception.Message) 'ERROR'
            throw
        }
        $ruleAdmins = New-Object System.Security.AccessControl.FileSystemAccessRule $adminsNtAccount,'FullControl','Allow'

        [void]$acl.AddAccessRule($ruleSystem)
        [void]$acl.AddAccessRule($ruleAdmins)

        Set-Acl -LiteralPath $pwPath -AclObject $acl

        Write-BootstrapLog ("ACL applied to '{0}' successfully" -f $pwPath)
    } catch {
        Write-BootstrapLog ("Failed to apply ACL to '{0}': {1}" -f $pwPath, $_.Exception.Message) 'ERROR'
        try {
            if (Test-Path -LiteralPath $pwPath) {
                Write-BootstrapLog ("Attempting to delete '{0}' after ACL failure" -f $pwPath) 'WARN'
                Remove-Item -LiteralPath $pwPath -Force -ErrorAction Stop
                Write-BootstrapLog ("Deleted '{0}' after ACL failure" -f $pwPath) 'WARN'
            } else {
                Write-BootstrapLog ("Password file '{0}' does not exist at ACL failure; nothing to delete" -f $pwPath) 'WARN'
            }
        } catch {
            $cleanupMessage = if ($_.Exception -and $_.Exception.Message) { $_.Exception.Message } else { $_.ToString() }
            Write-BootstrapLog ("Failed to delete '{0}' after ACL failure: {1}" -f $pwPath, $cleanupMessage) 'ERROR'
        }
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
