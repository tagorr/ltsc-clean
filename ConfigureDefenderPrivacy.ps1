Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$marker = '[DEFENDER-PRIVACY]'

function Write-DefenderPrivacyStatus {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('PASS', 'WARN', 'ERROR')]
        [string]$Level,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $line = '{0} {1}: {2}' -f $marker, $Level, $Message
    if ($Level -eq 'ERROR') {
        [Console]::Error.WriteLine($line)
    } else {
        [Console]::Out.WriteLine($line)
    }
}

try {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $isSystem = ($null -ne $identity.User -and $identity.User.Value -eq 'S-1-5-18')
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    $isAdministrator = $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)

    if (-not ($isSystem -or $isAdministrator)) {
        Write-DefenderPrivacyStatus -Level ERROR -Message 'administrative token or SYSTEM is required; no policy changes were attempted'
        exit 1
    }

    foreach ($commandName in @('Get-MpComputerStatus', 'Get-MpPreference')) {
        if ($null -eq (Get-Command -Name $commandName -CommandType Function, Cmdlet -ErrorAction SilentlyContinue)) {
            throw ("required Defender command unavailable: {0}" -f $commandName)
        }
    }

    $regExe = Join-Path $env:SystemRoot 'System32\reg.exe'
    if (-not (Test-Path -LiteralPath $regExe -PathType Leaf)) {
        throw ("required registry tool unavailable: {0}" -f $regExe)
    }

    $policyKey = 'HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\Spynet'
    $ownedValues = @(
        @{ Name = 'SpynetReporting'; Value = 0 },
        @{ Name = 'SubmitSamplesConsent'; Value = 2 }
    )

    foreach ($ownedValue in $ownedValues) {
        & $regExe add $policyKey /v $ownedValue.Name /t REG_DWORD /d ([string]$ownedValue.Value) /f *> $null
        $regRc = $LASTEXITCODE
        if ($regRc -ne 0) {
            throw ("registry mutation failed: name={0} rc={1}" -f $ownedValue.Name, $regRc)
        }
    }

    $registryKey = $null
    try {
        $registryKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
            'SOFTWARE\Policies\Microsoft\Windows Defender\Spynet',
            $false
        )
        if ($null -eq $registryKey) {
            throw 'owned policy key could not be queried'
        }

        foreach ($ownedValue in $ownedValues) {
            $valueKind = $registryKey.GetValueKind($ownedValue.Name)
            $actualValue = $registryKey.GetValue(
                $ownedValue.Name,
                $null,
                [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
            )
            if ($valueKind -ne [Microsoft.Win32.RegistryValueKind]::DWord -or
                $null -eq $actualValue -or
                [int]$actualValue -ne [int]$ownedValue.Value) {
                throw ("owned policy verification failed: name={0} expected={1}" -f $ownedValue.Name, $ownedValue.Value)
            }
        }
    } finally {
        if ($null -ne $registryKey) {
            $registryKey.Dispose()
        }
    }

    Write-DefenderPrivacyStatus -Level PASS -Message 'policy verified SpynetReporting=0 SubmitSamplesConsent=2'

    # Registry verification proves the owned policy state. Defender cmdlets prove effective state.
    # Tamper Protection is observed only and is never changed by this component.
    $computerStatus = Get-MpComputerStatus -ErrorAction Stop
    $preference = Get-MpPreference -ErrorAction Stop
    if ($null -eq $computerStatus -or
        $null -eq $preference -or
        $null -eq $computerStatus.IsTamperProtected -or
        $null -eq $preference.MAPSReporting -or
        $null -eq $preference.SubmitSamplesConsent) {
        throw 'required Defender effective-state data unavailable'
    }
    $isTamperProtected = [System.Convert]::ToBoolean($computerStatus.IsTamperProtected)
    $mapsReporting = [int]$preference.MAPSReporting
    $submitSamplesConsent = [int]$preference.SubmitSamplesConsent

    if ($mapsReporting -ne 0 -or $submitSamplesConsent -ne 2) {
        Write-DefenderPrivacyStatus -Level WARN -Message ("effective Defender state mismatch IsTamperProtected={0} MAPSReporting={1} SubmitSamplesConsent={2}; rerun this script after resolving Defender policy enforcement" -f $isTamperProtected, $mapsReporting, $submitSamplesConsent)
        exit 2
    }

    Write-DefenderPrivacyStatus -Level PASS -Message ("effective state verified IsTamperProtected={0} MAPSReporting=0 SubmitSamplesConsent=2" -f $isTamperProtected)
    exit 0
} catch {
    $exceptionMessage = $_.Exception.Message -replace '[\r\n]+', ' '
    Write-DefenderPrivacyStatus -Level ERROR -Message ("technical failure type={0} message={1}" -f $_.Exception.GetType().FullName, $exceptionMessage)
    exit 1
}
