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

function New-BootstrapSecretFileSecurity {
    $sec = New-Object System.Security.AccessControl.FileSecurity
    $sec.SetAccessRuleProtection($true, $false)

    $systemSid = [System.Security.Principal.SecurityIdentifier]'S-1-5-18'
    $adminsSid = [System.Security.Principal.SecurityIdentifier]'S-1-5-32-544'

    $ruleSystem = New-Object System.Security.AccessControl.FileSystemAccessRule $systemSid,'FullControl','Allow'
    $ruleAdmins = New-Object System.Security.AccessControl.FileSystemAccessRule $adminsSid,'FullControl','Allow'

    [void]$sec.AddAccessRule($ruleSystem)
    [void]$sec.AddAccessRule($ruleAdmins)

    return $sec
}

function New-BootstrapSecretFileStream {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [System.Security.AccessControl.FileSecurity] $FileSecurity
    )

    $ctor = [System.IO.FileStream].GetConstructor([Type[]]@(
        [string],
        [System.IO.FileMode],
        [System.Security.AccessControl.FileSystemRights],
        [System.IO.FileShare],
        [int],
        [System.IO.FileOptions],
        [System.Security.AccessControl.FileSecurity]
    ))

    if ($null -eq $ctor) {
        throw "BOOTSTRAP_SECRET_SECURE_CREATE_UNAVAILABLE: FileStream create-with-DACL API unavailable in this runtime; refusing to write secret insecurely."
    }

    # CreateNew fails if the file already exists; security is applied at creation time.
    return $ctor.Invoke(@(
        $Path,
        [System.IO.FileMode]::CreateNew,
        [System.Security.AccessControl.FileSystemRights]::FullControl,
        [System.IO.FileShare]::None,
        4096,
        [System.IO.FileOptions]::None,
        $FileSecurity
    ))
}

function Assert-BootstrapSecretFileAcl {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    $acl = Get-Acl -LiteralPath $Path

    # Fail closed: missing/null DACL can be overly permissive (effectively "allow everyone").
    try {
        $sddl = $acl.GetSecurityDescriptorSddlForm([System.Security.AccessControl.AccessControlSections]::Access)
    } catch {
        throw "BOOTSTRAP_SECRET_ACL_VERIFY_FAILED: failed to read DACL SDDL form (Access section)."
    }
    if ([string]::IsNullOrEmpty($sddl) -or ($sddl.IndexOf('D:', [System.StringComparison]::OrdinalIgnoreCase) -lt 0)) {
        throw "BOOTSTRAP_SECRET_ACL_VERIFY_FAILED: missing/null DACL detected (no D: component in SDDL)."
    }

    if (-not $acl.AreAccessRulesProtected) {
        throw "BOOTSTRAP_SECRET_ACL_VERIFY_FAILED: inheritance is not disabled (AreAccessRulesProtected=false)."
    }

    $requiredSids = @('S-1-5-18', 'S-1-5-32-544')
    $forbiddenBroadSids = @{
        'S-1-1-0' = $true      # Everyone
        'S-1-5-11' = $true     # Authenticated Users
        'S-1-5-32-545' = $true # BUILTIN\Users
    }

    $allowedRightsBySid = @{}

    $rulesAll = $acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])
    if ($null -eq $rulesAll -or $rulesAll.Count -eq 0) {
        throw "BOOTSTRAP_SECRET_ACL_VERIFY_FAILED: DACL rule enumeration returned empty; refusing to accept degenerate ACL."
    }

    foreach ($r in $rulesAll) {
        $sidValue = $r.IdentityReference.Value

        if ($r.IsInherited) {
            throw "BOOTSTRAP_SECRET_ACL_VERIFY_FAILED: inherited ACE present for SID '$sidValue'."
        }

        if ($forbiddenBroadSids.ContainsKey($sidValue)) {
            throw "BOOTSTRAP_SECRET_ACL_VERIFY_FAILED: forbidden broad principal SID '$sidValue' present in DACL."
        }

        if ($r.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Deny) {
            throw "BOOTSTRAP_SECRET_ACL_VERIFY_FAILED: deny ACE present for SID '$sidValue'."
        }
        if ($r.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) {
            throw "BOOTSTRAP_SECRET_ACL_VERIFY_FAILED: non-Allow ACE present for SID '$sidValue'."
        }

        if ($r.InheritanceFlags -ne [System.Security.AccessControl.InheritanceFlags]::None) {
            throw "BOOTSTRAP_SECRET_ACL_VERIFY_FAILED: SID '$sidValue' has non-None InheritanceFlags."
        }

        if ($r.PropagationFlags -ne [System.Security.AccessControl.PropagationFlags]::None) {
            throw "BOOTSTRAP_SECRET_ACL_VERIFY_FAILED: SID '$sidValue' has non-None PropagationFlags."
        }

        if ($requiredSids -contains $sidValue) {
            if ($allowedRightsBySid.ContainsKey($sidValue)) {
                $allowedRightsBySid[$sidValue] = ($allowedRightsBySid[$sidValue] -bor $r.FileSystemRights)
            } else {
                $allowedRightsBySid[$sidValue] = $r.FileSystemRights
            }
        }
    }

    foreach ($sid in $requiredSids) {
        if (-not $allowedRightsBySid.ContainsKey($sid)) {
            throw "BOOTSTRAP_SECRET_ACL_VERIFY_FAILED: required principal SID '$sid' missing from DACL."
        }
        if ( ($allowedRightsBySid[$sid] -band [System.Security.AccessControl.FileSystemRights]::FullControl) -ne [System.Security.AccessControl.FileSystemRights]::FullControl ) {
            throw "BOOTSTRAP_SECRET_ACL_VERIFY_FAILED: required principal SID '$sid' does not include FullControl."
        }
    }
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

    $secretFileCreated = $false
    $attemptedSecureCreate = $false
    try {
        if (Test-Path -LiteralPath $pwPath) {
            Write-BootstrapLog ("BOOTSTRAP_SECRET_ALREADY_EXISTS: refusing to overwrite existing secret file '{0}'" -f $pwPath) 'ERROR'
            throw "BOOTSTRAP_SECRET_ALREADY_EXISTS: Secret file already exists at '$pwPath'."
        }

        Write-BootstrapLog ("Creating bootstrap password file securely at '{0}'" -f $pwPath)
        $sec = New-BootstrapSecretFileSecurity

        $stream = $null
        try {
            $attemptedSecureCreate = $true
            $stream = New-BootstrapSecretFileStream -Path $pwPath -FileSecurity $sec
            $secretFileCreated = $true

            # Write as UTF-8 without BOM and no newline noise
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            $bytesToWrite = $utf8NoBom.GetBytes($PasswordPlain)
            $stream.Write($bytesToWrite, 0, $bytesToWrite.Length)
            $stream.Flush()
        }
        finally {
            if ($null -ne $stream) {
                $stream.Dispose()
            }
        }

        Assert-BootstrapSecretFileAcl -Path $pwPath

        # Hide as system/hidden
        Write-BootstrapLog ("Setting Hidden+System attributes on '{0}'" -f $pwPath)
        $item = Get-Item $pwPath
        $item.Attributes = 'Hidden','System','Archive'
    } catch {
        $failureMessage = if ($_.Exception -and $_.Exception.Message) { $_.Exception.Message } else { $_.ToString() }
        Write-BootstrapLog ("Failed while creating/writing/verifying bootstrap secret file '{0}': {1}" -f $pwPath, $failureMessage) 'ERROR'

        if (($attemptedSecureCreate -or $secretFileCreated) -and (Test-Path -LiteralPath $pwPath)) {
            try {
                Write-BootstrapLog ("Attempting to delete '{0}' after bootstrap secret failure" -f $pwPath) 'WARN'
                Remove-Item -LiteralPath $pwPath -Force -ErrorAction Stop
                Write-BootstrapLog ("Deleted '{0}' after bootstrap secret failure" -f $pwPath) 'WARN'
            } catch {
                $cleanupMessage = if ($_.Exception -and $_.Exception.Message) { $_.Exception.Message } else { $_.ToString() }
                Write-BootstrapLog ("BOOTSTRAP_SECRET_DELETE_FAILED: operator action required. Failed to delete '{0}': {1}. Secret may remain on disk with incorrect permissions." -f $pwPath, $cleanupMessage) 'ERROR'
            }
        }

        throw
    }

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
