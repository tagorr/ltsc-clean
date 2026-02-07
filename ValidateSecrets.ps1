[CmdletBinding(DefaultParameterSetName = 'Secrets')]
param(
    [Parameter(ParameterSetName = 'Secrets', Mandatory = $true)]
    [string]$BootstrapPath,

    [Parameter(ParameterSetName = 'Secrets', Mandatory = $true)]
    [string]$PrimaryAdminPath,

    [Parameter(ParameterSetName = 'AclBoundaryPreStageB', Mandatory = $true)]
    [switch]$CheckAclBoundaryPreStageB,

    [Parameter(ParameterSetName = 'AclBoundaryPostStageB', Mandatory = $true)]
    [switch]$CheckAclBoundaryPostStageB,

    [Parameter(ParameterSetName = 'AclBoundaryPreStageB')]
    [string]$ScriptsDirPath = (Join-Path $env:WINDIR 'Setup\Scripts'),

    [Parameter(ParameterSetName = 'AclBoundaryPreStageB')]
    [string]$StageBScriptPath = (Join-Path $env:WINDIR 'Setup\Scripts\CreatePrimaryAdmin.ps1'),

    [Parameter(ParameterSetName = 'AclBoundaryPostStageB')]
    [string]$TaskDefinitionPath = (Join-Path $env:SystemRoot 'System32\Tasks\L2C\CreatePrimaryAdmin')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

# ACL boundary flags (unsafe when set). Keep 4 reserved for internal error sentinel.
[int]$FLAG_UNSAFE_SCRIPTS_DIR   = 8
[int]$FLAG_UNSAFE_STAGEB_SCRIPT = 16
[int]$FLAG_UNSAFE_TASK_FILE     = 32
[int]$FLAG_UNSAFE_TASK_DIR      = 64

function Test-NonAdminTamperAclUnsafe {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Leaf', 'Container')]
        [string]$ExpectedType
    )

    $pathType = if ($ExpectedType -eq 'Container') { 'Container' } else { 'Leaf' }
    if (-not (Test-Path -LiteralPath $Path -PathType $pathType)) {
        Write-Error "[ACLBOUNDARY] Path missing or wrong type: $Path (expected $ExpectedType)" -ErrorAction Continue
        return $true
    }

    $acl = $null
    try {
        $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    } catch {
        Write-Error "[ACLBOUNDARY] Get-Acl failed for ${Path}: $($_.Exception.Message)" -ErrorAction Continue
        return $true
    }

    $riskySids = @(
        'S-1-1-0',        # Everyone
        'S-1-5-32-545',   # BUILTIN\Users
        'S-1-5-11',       # Authenticated Users
        'S-1-5-4'         # INTERACTIVE
    )

    # Fallback match if IdentityReference.Translate(SID) fails.
    # Keep it limited to exactly the same principals as $riskySids above.
    $riskyNames = @(
        'Everyone',
        'BUILTIN\Users',
        'NT AUTHORITY\Authenticated Users',
        'NT AUTHORITY\INTERACTIVE'
    )

    $unsafeRights =
        [System.Security.AccessControl.FileSystemRights]::WriteData -bor
        [System.Security.AccessControl.FileSystemRights]::AppendData -bor
        [System.Security.AccessControl.FileSystemRights]::WriteAttributes -bor
        [System.Security.AccessControl.FileSystemRights]::WriteExtendedAttributes -bor
        [System.Security.AccessControl.FileSystemRights]::Delete -bor
        [System.Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
        [System.Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [System.Security.AccessControl.FileSystemRights]::TakeOwnership

    # Catch generic/high-level rights explicitly too.
    $unsafeHighLevelRights =
        [System.Security.AccessControl.FileSystemRights]::Write -bor
        [System.Security.AccessControl.FileSystemRights]::Modify -bor
        [System.Security.AccessControl.FileSystemRights]::FullControl -bor
        [System.Security.AccessControl.FileSystemRights]::GenericWrite -bor
        [System.Security.AccessControl.FileSystemRights]::GenericAll

    foreach ($rule in $acl.Access) {
        if ($rule.AccessControlType -ne 'Allow') { continue }

        $sid = $null
        $name = $null
        $rawId = $rule.IdentityReference.Value

        try {
            $sid = ($rule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier])).Value
        } catch {
            # If translation fails, fall back to raw identity string (either SID text or account name).
            if ($rawId -match '^S-\d-\d+-.+') {
                $sid = $rawId
            } else {
                $name = $rawId
            }
        }

        $isRisky = $false
        if ($sid -and ($riskySids -contains $sid)) { $isRisky = $true }
        if (-not $isRisky -and $name -and ($riskyNames -contains $name)) { $isRisky = $true }
        if (-not $isRisky) { continue }

        $rights = $rule.FileSystemRights
        if ((($rights -band $unsafeRights) -ne 0) -or (($rights -band $unsafeHighLevelRights) -ne 0)) {
            $idForLog = if ($sid) { $sid } else { $rawId }
            Write-Error ("[ACLBOUNDARY] Unsafe Allow ACE: path={0} id={1} rights={2}" -f $Path, $idForLog, $rights) -ErrorAction Continue
            return $true
        }
    }

    return $false
}

# Main logic: compute two flags and an exit code as a bitmask:
# bit 0 (1)  bootstrapOk
# bit 1 (2)  primaryOk

try {
    if ($PSCmdlet.ParameterSetName -eq 'AclBoundaryPreStageB') {
        [int]$code = 0

        if (Test-NonAdminTamperAclUnsafe -Path $ScriptsDirPath -ExpectedType Container) {
            $code = $code -bor $FLAG_UNSAFE_SCRIPTS_DIR
        }
        if (Test-NonAdminTamperAclUnsafe -Path $StageBScriptPath -ExpectedType Leaf) {
            $code = $code -bor $FLAG_UNSAFE_STAGEB_SCRIPT
        }

        exit $code
    }

    if ($PSCmdlet.ParameterSetName -eq 'AclBoundaryPostStageB') {
        [int]$code = 0

        if (Test-NonAdminTamperAclUnsafe -Path $TaskDefinitionPath -ExpectedType Leaf) {
            $code = $code -bor $FLAG_UNSAFE_TASK_FILE
        }
        $taskDirPath = Split-Path -Path $TaskDefinitionPath -Parent
        if (Test-NonAdminTamperAclUnsafe -Path $taskDirPath -ExpectedType Container) {
            $code = $code -bor $FLAG_UNSAFE_TASK_DIR
        }

        exit $code
    }

    $bootstrapOk = Test-SecretAcl -Path $BootstrapPath
    $primaryOk   = Test-SecretAcl -Path $PrimaryAdminPath

    [int]$code = 0
    if ($bootstrapOk) { $code = $code -bor 1 } # bit 0
    if ($primaryOk)   { $code = $code -bor 2 } # bit 1

    exit $code
}
catch {
    Write-Error "Internal error while validating secrets: $($_.Exception.Message)" -ErrorAction Continue
    exit 4
}
