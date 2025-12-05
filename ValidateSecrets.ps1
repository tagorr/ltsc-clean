[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$BootstrapPath,

    [Parameter(Mandatory = $true)]
    [string]$PrimaryAdminPath
)

function Test-SecretAcl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    try {
        $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    } catch {
        return $false
    }

    if (-not $acl.AreAccessRulesProtected) {
        return $false
    }

    $allowed = @('S-1-5-18', 'S-1-5-32-544')
    $seen = @()

    foreach ($rule in $acl.Access) {
        $sid = ($rule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier])).Value
        if ($allowed -notcontains $sid) {
            return $false
        }
        if ($rule.AccessControlType -ne 'Allow') {
            return $false
        }
        if (-not ($rule.FileSystemRights.HasFlag([System.Security.AccessControl.FileSystemRights]::FullControl))) {
            return $false
        }
        $seen += $sid
    }

    if ($seen.Count -ne $allowed.Count) {
        return $false
    }

    $unique = $seen | Sort-Object -Unique
    if ($unique.Count -ne $allowed.Count) {
        return $false
    }

    foreach ($sid in $allowed) {
        if ($unique -notcontains $sid) {
            return $false
        }
    }

    $attrs = [System.IO.File]::GetAttributes($Path)
    if (-not ($attrs.HasFlag([System.IO.FileAttributes]::Hidden))) {
        return $false
    }
    if (-not ($attrs.HasFlag([System.IO.FileAttributes]::System))) {
        return $false
    }

    return $true
}

# Main logic: compute two flags and an exit code as a bitmask:
# bit 0 (1)  bootstrapOk
# bit 1 (2)  primaryOk

try {
    $bootstrapOk = Test-SecretAcl -Path $BootstrapPath
    $primaryOk   = Test-SecretAcl -Path $PrimaryAdminPath

    [int]$code = 0
    if ($bootstrapOk) { $code = $code -bor 1 } # bit 0
    if ($primaryOk)   { $code = $code -bor 2 } # bit 1

    exit $code
}
catch {
    # In case of an internal error we treat this as "both invalid" and return exit code 0,
    # so that SetupComplete enters recovery mode.
    # You may log the error details here if needed, but this is not part of the contract.
    exit 0
}
