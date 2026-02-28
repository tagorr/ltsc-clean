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

function Resolve-IdentityReferenceSafe {
    param(
        [Parameter(Mandatory = $true)]
        $IdentityReference
    )

    $sid = $null
    $raw = ''
    $resolved = $false

    try {
        if ($null -ne $IdentityReference) {
            try { $raw = [string]$IdentityReference } catch { $raw = '' }

            if ($IdentityReference -is [System.Security.Principal.SecurityIdentifier]) {
                try {
                    $sid = $IdentityReference.Value
                    $resolved = $true
                } catch { }
            } else {
                try {
                    $translated = $IdentityReference.Translate([System.Security.Principal.SecurityIdentifier])
                    if ($translated -is [System.Security.Principal.SecurityIdentifier]) {
                        $sid = $translated.Value
                        $resolved = $true
                    }
                } catch { }
            }

            if (-not $resolved) {
                if ($raw -match '^S-1-') {
                    $sid = $raw
                    $resolved = $true
                } elseif ($raw) {
                    try {
                        $nt = New-Object System.Security.Principal.NTAccount($raw)
                        $translated2 = $nt.Translate([System.Security.Principal.SecurityIdentifier])
                        if ($translated2 -is [System.Security.Principal.SecurityIdentifier]) {
                            $sid = $translated2.Value
                            $resolved = $true
                        }
                    } catch { }
                }
            }
        }
    } catch {
        $sid = $null
        $resolved = $false
        if ($null -eq $raw) { $raw = '' }
    }

    if ($null -eq $raw) { $raw = '' }

    return [pscustomobject]@{
        Sid      = $sid
        Raw      = $raw
        Resolved = $resolved
    }
}

function Test-SecretAcl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    function Fail([string]$Why) {
        [Console]::Error.WriteLine(("[SECRETS] FAIL: path={0} reason={1}" -f $Path, $Why))
        return $false
    }

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return (Fail 'missing_or_not_leaf')
    }

    $acl = $null
    try {
        $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    } catch {
        return (Fail ('get_acl_failed: ' + $_.Exception.Message))
    }

    if (-not $acl.AreAccessRulesProtected) {
        return (Fail 'acl_not_protected')
    }

    $sidSystem = 'S-1-5-18'      # SYSTEM
    $sidAdmins = 'S-1-5-32-544'  # BUILTIN\Administrators

    $rightsBySid = @{
        $sidSystem = [System.Security.AccessControl.FileSystemRights]0
        $sidAdmins = [System.Security.AccessControl.FileSystemRights]0
    }
    $presentBySid = @{
        $sidSystem = $false
        $sidAdmins = $false
    }

    foreach ($rule in $acl.Access) {
        if ($null -eq $rule) { return (Fail 'acl_rule_null') }
        if (-not ($rule -is [System.Security.AccessControl.FileSystemAccessRule])) {
            return (Fail ('unexpected_rule_type: ' + $rule.GetType().FullName))
        }

        if ($rule.IsInherited) {
            return (Fail 'inherited_ace_present')
        }

        if ($rule.AccessControlType -ne 'Allow') {
            return (Fail ('non_allow_ace_present: ' + $rule.AccessControlType))
        }

        $idInfo = Resolve-IdentityReferenceSafe -IdentityReference $rule.IdentityReference
        if (-not $idInfo.Resolved) {
            return (Fail ('identity_translate_failed: raw=' + $idInfo.Raw))
        }
        $sid = $idInfo.Sid

        if (($sid -ne $sidSystem) -and ($sid -ne $sidAdmins)) {
            return (Fail ('non_allowed_sid_present: ' + $sid))
        }

        $presentBySid[$sid] = $true
        try {
            $rightsBySid[$sid] = $rightsBySid[$sid] -bor $rule.FileSystemRights
        } catch {
            return (Fail ('acl_rights_merge_failed: ' + $_.Exception.Message))
        }
    }

    if (-not $presentBySid[$sidSystem]) {
        return (Fail 'missing_SYSTEM_ace')
    }
    if (-not $presentBySid[$sidAdmins]) {
        return (Fail 'missing_Administrators_ace')
    }

    $full = [System.Security.AccessControl.FileSystemRights]::FullControl
    $sysRights = $rightsBySid[$sidSystem]
    if ((($sysRights -band $full) -ne $full)) {
        return (Fail ('SYSTEM_rights_not_fullcontrol: ' + $sysRights))
    }

    $admRights = $rightsBySid[$sidAdmins]
    if ((($admRights -band $full) -ne $full)) {
        return (Fail ('Administrators_rights_not_fullcontrol: ' + $admRights))
    }

    $attrs = $null
    try {
        $attrs = [System.IO.File]::GetAttributes($Path)
    } catch {
        $exType = $_.Exception.GetType().FullName
        $exMsg = ($_.Exception.Message -replace "[`r`n]+", ' ')
        return (Fail ("get_attributes_failed: {0}: {1}" -f $exType, $exMsg))
    }
    if (-not ($attrs.HasFlag([System.IO.FileAttributes]::Hidden))) {
        return (Fail ('missing_hidden attrs=' + $attrs))
    }
    if (-not ($attrs.HasFlag([System.IO.FileAttributes]::System))) {
        return (Fail ('missing_system attrs=' + $attrs))
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

    foreach ($rule in $acl.Access) {
        if ($rule.AccessControlType -ne 'Allow') { continue }

        $idInfo = Resolve-IdentityReferenceSafe -IdentityReference $rule.IdentityReference
        $sid = $idInfo.Sid
        $rawId = $idInfo.Raw

        $isRisky = $false
        if ($idInfo.Resolved -and $sid -and ($riskySids -contains $sid)) { $isRisky = $true }
        if (-not $isRisky -and (-not $idInfo.Resolved) -and $rawId -and ($riskyNames -contains $rawId)) { $isRisky = $true }
        if ($idInfo.Resolved -and (-not $isRisky)) { continue }

        $rights = $rule.FileSystemRights
        if ((($rights -band $unsafeRights) -ne 0) -or
            $rights.HasFlag([System.Security.AccessControl.FileSystemRights]::Write) -or
            $rights.HasFlag([System.Security.AccessControl.FileSystemRights]::Modify) -or
            $rights.HasFlag([System.Security.AccessControl.FileSystemRights]::FullControl)) {

            if (-not $idInfo.Resolved) {
                $domainPossible = $false
                if ($rawId -and ($rawId -like '*\*') -and
                    ($rawId -notlike 'BUILTIN\*') -and
                    ($rawId -notlike 'NT AUTHORITY\*') -and
                    ($rawId -notlike 'NT SERVICE\*') -and
                    ($rawId -notlike 'APPLICATION PACKAGE AUTHORITY\*')) {
                    $domainPossible = $true
                }

                $token = '(identity_unresolved_fail_closed)'
                $hint = 'hint=Resolve identity to SID or remove unsafe Allow ACE; rerun validation.'
                if ($domainPossible) {
                    $token = '(identity_unresolved_fail_closed, domain_possible)'
                    $hint = 'hint=Resolve identity to SID (name-resolution, possibly domain/DC/network) or remove unsafe Allow ACE; rerun validation.'
                }

                Write-Error ("[ACLBOUNDARY] Unsafe Allow ACE {0}: path={1} id={2} rights={3} {4}" -f $token, $Path, $rawId, $rights, $hint) -ErrorAction Continue
                return $true
            }

            Write-Error ("[ACLBOUNDARY] Unsafe Allow ACE: path={0} id={1} rights={2}" -f $Path, $sid, $rights) -ErrorAction Continue
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
    [Console]::Error.WriteLine(("Internal error while validating secrets: {0}" -f $_.Exception.Message))
    exit 4
}
