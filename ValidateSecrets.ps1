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

$bootstrapOk = Test-SecretAcl -Path $BootstrapPath
$primaryOk = Test-SecretAcl -Path $PrimaryAdminPath

Write-Output ("set L2C_BOOTSTRAP_PW_ACL_OK={0}" -f ($(if ($bootstrapOk) { '1' } else { '0' })))
Write-Output ("set L2C_PRIMARYADMIN_PW_ACL_OK={0}" -f ($(if ($primaryOk) { '1' } else { '0' })))
