[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$BaseRef = 'main'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:FailureCount = 0

function Write-Check {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Problems
    )

    if ($Problems.Count -eq 0) {
        Write-Host ("PASS: {0}" -f $Name)
        return
    }

    Write-Host ("FAIL: {0}" -f $Name)
    foreach ($problem in $Problems) {
        Write-Host ("  {0}" -f ([string]$problem))
    }
    $script:FailureCount++
}

function Invoke-GitReadOnly {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & git @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output   = @($output | ForEach-Object { [string]$_ })
    }
}

function Stop-Preflight {
    Write-Host ("Summary: {0}" -f $(if ($script:FailureCount -eq 0) { 'PASS' } else { 'FAIL' }))
    if ($script:FailureCount -eq 0) { exit 0 }
    exit 1
}

function Test-PowerShellParsing {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot
    )

    foreach ($target in @('BootstrapLocalAdmin.ps1', 'ConfigureDefenderPrivacy.ps1', 'CreatePrimaryAdmin.ps1', 'ValidateSecrets.ps1')) {
        $problems = New-Object System.Collections.Generic.List[string]
        $fullPath = Join-Path -Path $RepoRoot -ChildPath $target

        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
            $problems.Add(("{0}:0:0 file not found" -f $target))
        } else {
            $tokens = $null
            $parseErrors = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile(
                $fullPath,
                [ref]$tokens,
                [ref]$parseErrors
            )
            foreach ($parseError in @($parseErrors)) {
                $problems.Add(("{0}:{1}:{2} {3}" -f
                    $target,
                    $parseError.Extent.StartLineNumber,
                    $parseError.Extent.StartColumnNumber,
                    $parseError.Message))
            }
        }

        Write-Check -Name ("PS 5.1 parse {0}" -f $target) -Problems $problems
    }
}

function Test-GitDiffCheck {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Revision
    )

    $query = Invoke-GitReadOnly -Arguments @('diff', '--check', $Revision, '--')
    $problems = New-Object System.Collections.Generic.List[string]
    if ($query.ExitCode -ne 0) {
        foreach ($line in $query.Output) { $problems.Add($line) }
        if ($problems.Count -eq 0) {
            $problems.Add(("git diff --check exited {0}" -f $query.ExitCode))
        }
    }
    Write-Check -Name $Name -Problems $problems
}

function Test-TrackedTextIntegrity {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string[]]$TrackedFiles
    )

    $textExtensions = @(
        '.ps1', '.psm1', '.psd1', '.cmd', '.bat', '.md',
        '.xml', '.yml', '.yaml', '.json', '.txt'
    )
    $specialNames = @('.gitattributes', '.gitignore')
    $readErrors = New-Object System.Collections.Generic.List[string]
    $invalidUtf8 = New-Object System.Collections.Generic.List[string]
    $bomFiles = New-Object System.Collections.Generic.List[string]
    $nulFiles = New-Object System.Collections.Generic.List[string]
    $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)

    foreach ($relativePath in $TrackedFiles) {
        $name = [System.IO.Path]::GetFileName($relativePath)
        $extension = [System.IO.Path]::GetExtension($relativePath).ToLowerInvariant()
        if ($textExtensions -notcontains $extension -and $specialNames -notcontains $name) { continue }

        $fullPath = Join-Path -Path $RepoRoot -ChildPath $relativePath
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { continue }

        try {
            $bytes = [System.IO.File]::ReadAllBytes($fullPath)
        } catch {
            $readErrors.Add(("{0}: {1}" -f $relativePath, $_.Exception.Message))
            continue
        }

        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            $bomFiles.Add($relativePath)
        }
        if ($bytes -contains [byte]0) { $nulFiles.Add($relativePath) }

        try {
            [void]$strictUtf8.GetString($bytes)
        } catch [System.Text.DecoderFallbackException] {
            $invalidUtf8.Add($relativePath)
        }
    }

    Write-Check -Name 'tracked text files readable' -Problems $readErrors
    Write-Check -Name 'tracked text valid UTF-8' -Problems $invalidUtf8
    Write-Check -Name 'tracked text UTF-8 BOM absent' -Problems $bomFiles
    Write-Check -Name 'tracked text NUL bytes absent' -Problems $nulFiles
}

function Test-TrackedEolPolicy {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot
    )

    $problems = New-Object System.Collections.Generic.List[string]
    $attributesPath = Join-Path -Path $RepoRoot -ChildPath '.gitattributes'
    if (-not (Test-Path -LiteralPath $attributesPath -PathType Leaf)) {
        $problems.Add('.gitattributes not found')
        Write-Check -Name 'tracked EOL policy' -Problems $problems
        return
    }

    $query = Invoke-GitReadOnly -Arguments @('ls-files', '--eol')
    if ($query.ExitCode -ne 0) {
        $problems.Add(("git ls-files --eol exited {0}" -f $query.ExitCode))
        foreach ($line in $query.Output) { $problems.Add($line) }
        Write-Check -Name 'tracked EOL policy' -Problems $problems
        return
    }

    foreach ($line in $query.Output) {
        $tabIndex = $line.IndexOf("`t")
        if ($tabIndex -lt 0) { continue }

        $metadata = $line.Substring(0, $tabIndex)
        if ($metadata -notmatch '\beol=(lf|crlf)\b') { continue }

        $expected = $Matches[1]
        $relativePath = $line.Substring($tabIndex + 1)
        $fullPath = Join-Path -Path $RepoRoot -ChildPath $relativePath
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { continue }

        try {
            $bytes = [System.IO.File]::ReadAllBytes($fullPath)
        } catch {
            $problems.Add(("{0}: read error: {1}" -f $relativePath, $_.Exception.Message))
            continue
        }

        $valid = $true
        if ($expected -eq 'lf') {
            $valid = -not ($bytes -contains [byte]0x0D)
        } else {
            for ($index = 0; $index -lt $bytes.Length; $index++) {
                if ($bytes[$index] -eq 0x0A -and ($index -eq 0 -or $bytes[$index - 1] -ne 0x0D)) {
                    $valid = $false
                    break
                }
                if ($bytes[$index] -eq 0x0D -and ($index + 1 -ge $bytes.Length -or $bytes[$index + 1] -ne 0x0A)) {
                    $valid = $false
                    break
                }
            }
        }

        if (-not $valid) {
            $problems.Add(("{0}: expected {1}" -f $relativePath, $expected.ToUpperInvariant()))
        }
    }

    Write-Check -Name 'tracked EOL policy' -Problems $problems
}

function Test-TrackedScriptAscii {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot
    )

    $problems = New-Object System.Collections.Generic.List[string]
    $query = Invoke-GitReadOnly -Arguments @('ls-files', '--', '*.cmd', '*.ps1')
    if ($query.ExitCode -ne 0) {
        $problems.Add(("git ls-files for scripts exited {0}" -f $query.ExitCode))
        foreach ($line in $query.Output) { $problems.Add($line) }
        Write-Check -Name 'tracked CMD and PowerShell ASCII-only' -Problems $problems
        return
    }

    foreach ($relativePath in $query.Output) {
        if (-not $relativePath) { continue }
        $fullPath = Join-Path -Path $RepoRoot -ChildPath $relativePath
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { continue }

        try {
            $bytes = [System.IO.File]::ReadAllBytes($fullPath)
            foreach ($byte in $bytes) {
                if ($byte -ge 0x80) {
                    $problems.Add($relativePath)
                    break
                }
            }
        } catch {
            $problems.Add(("{0}: read error: {1}" -f $relativePath, $_.Exception.Message))
        }
    }

    Write-Check -Name 'tracked CMD and PowerShell ASCII-only' -Problems $problems
}

function Write-WorkingTreeInfo {
    param(
        [Parameter(Mandatory = $true)][string]$ComparisonBase,
        [Parameter(Mandatory = $true)][string]$HeadCommit
    )

    $branchQuery = Invoke-GitReadOnly -Arguments @('diff', '--name-status', ($ComparisonBase + '..' + $HeadCommit), '--')
    $statusQuery = Invoke-GitReadOnly -Arguments @('status', '--short', '--branch', '--untracked-files=all')
    $tempVisible = Invoke-GitReadOnly -Arguments @('ls-files', '--others', '--exclude-standard', '--', '.codex_tmp/**')
    $tempIgnored = Invoke-GitReadOnly -Arguments @('ls-files', '--others', '--ignored', '--exclude-standard', '--', '.codex_tmp/**')
    $queries = @($branchQuery, $statusQuery, $tempVisible, $tempIgnored)
    $problems = New-Object System.Collections.Generic.List[string]

    foreach ($query in $queries) {
        if ($query.ExitCode -ne 0) {
            $problems.Add(("Git reporting command exited {0}" -f $query.ExitCode))
            foreach ($line in $query.Output) { $problems.Add($line) }
        }
    }
    if ($problems.Count -ne 0) {
        Write-Host 'INFO: working-tree reporting unavailable'
        foreach ($problem in $problems) { Write-Host ("  {0}" -f $problem) }
        return
    }

    Write-Host 'INFO: committed branch delta:'
    if ($branchQuery.Output.Count -eq 0) { Write-Host '  <none>' }
    else { foreach ($line in $branchQuery.Output) { Write-Host ("  {0}" -f $line) } }

    Write-Host 'INFO: current working tree:'
    if ($statusQuery.Output.Count -eq 0) { Write-Host '  <clean>' }
    else { foreach ($line in $statusQuery.Output) { Write-Host ("  {0}" -f $line) } }

    $tempArtifacts = @($tempVisible.Output + $tempIgnored.Output | Where-Object { $_ } | Sort-Object -Unique)
    Write-Host 'INFO: untracked .codex_tmp artifacts:'
    if ($tempArtifacts.Count -eq 0) { Write-Host '  <none>' }
    else { foreach ($path in $tempArtifacts) { Write-Host ("  {0}" -f $path) } }
}

$edition = if ($PSVersionTable.ContainsKey('PSEdition')) { [string]$PSVersionTable.PSEdition } else { '' }
$version = $PSVersionTable.PSVersion
$engineProblems = @()
if ($edition -ne 'Desktop' -or $version.Major -ne 5 -or $version.Minor -ne 1) {
    $engineProblems = @('Run this validator with Windows PowerShell 5.1 for supported-runtime parser fidelity.')
}
Write-Check -Name 'Windows PowerShell 5.1 validator runtime' -Problems $engineProblems
Write-Host ("INFO: powershell-edition={0} version={1}" -f $edition, $version)
if ($engineProblems.Count -ne 0) { Stop-Preflight }

$gitProblems = @()
if ($null -eq (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) {
    $gitProblems = @('git executable not found')
}
Write-Check -Name 'Git available' -Problems $gitProblems
if ($gitProblems.Count -ne 0) { Stop-Preflight }

$scriptPath = (Resolve-Path -LiteralPath $PSCommandPath).Path
$scriptDir = Split-Path -Parent $scriptPath
$rootQuery = Invoke-GitReadOnly -Arguments @('-C', $scriptDir, 'rev-parse', '--show-toplevel')
$worktreeProblems = New-Object System.Collections.Generic.List[string]
if ($rootQuery.ExitCode -ne 0 -or $rootQuery.Output.Count -ne 1) {
    $worktreeProblems.Add('unable to resolve repository root')
    foreach ($line in $rootQuery.Output) { $worktreeProblems.Add($line) }
    Write-Check -Name 'intended Git worktree' -Problems $worktreeProblems
    Stop-Preflight
}

$repoRoot = [System.IO.Path]::GetFullPath($rootQuery.Output[0].Replace('/', '\')).TrimEnd('\')
$insideQuery = Invoke-GitReadOnly -Arguments @('-C', $repoRoot, 'rev-parse', '--is-inside-work-tree')
$trackedScript = Invoke-GitReadOnly -Arguments @('-C', $repoRoot, 'ls-files', '--error-unmatch', '--', 'tools/preflight.ps1')
$expectedScriptPath = Join-Path -Path $repoRoot -ChildPath 'tools\preflight.ps1'
if (-not $expectedScriptPath.Equals($scriptPath, [System.StringComparison]::OrdinalIgnoreCase)) {
    $worktreeProblems.Add(("validator path does not match {0}" -f $expectedScriptPath))
}
if ($insideQuery.ExitCode -ne 0 -or ($insideQuery.Output -join '').Trim() -ne 'true') {
    $worktreeProblems.Add('not inside the intended Git worktree')
}
if ($trackedScript.ExitCode -ne 0) {
    $worktreeProblems.Add('tools/preflight.ps1 is not tracked in this worktree')
}
Write-Check -Name 'intended Git worktree' -Problems $worktreeProblems
if ($worktreeProblems.Count -ne 0) { Stop-Preflight }

Set-Location -LiteralPath $repoRoot
Write-Host ("INFO: repository-root={0}" -f $repoRoot)
Write-Host ("INFO: base-ref={0}" -f $BaseRef)

$baseQuery = Invoke-GitReadOnly -Arguments @('rev-parse', '--verify', ($BaseRef + '^{commit}'))
$headQuery = Invoke-GitReadOnly -Arguments @('rev-parse', '--verify', 'HEAD^{commit}')
$resolutionProblems = New-Object System.Collections.Generic.List[string]
if ($baseQuery.ExitCode -ne 0 -or $baseQuery.Output.Count -ne 1) {
    $resolutionProblems.Add(("unable to resolve base ref: {0}" -f $BaseRef))
    foreach ($line in $baseQuery.Output) { $resolutionProblems.Add($line) }
}
if ($headQuery.ExitCode -ne 0 -or $headQuery.Output.Count -ne 1) {
    $resolutionProblems.Add('unable to resolve HEAD')
    foreach ($line in $headQuery.Output) { $resolutionProblems.Add($line) }
}
Write-Check -Name 'base ref and HEAD resolution' -Problems $resolutionProblems
if ($resolutionProblems.Count -ne 0) { Stop-Preflight }

$baseCommit = $baseQuery.Output[0].Trim()
$headCommit = $headQuery.Output[0].Trim()
$mergeBaseQuery = Invoke-GitReadOnly -Arguments @('merge-base', $baseCommit, $headCommit)
$mergeBaseProblems = @()
if ($mergeBaseQuery.ExitCode -ne 0 -or $mergeBaseQuery.Output.Count -ne 1) {
    $mergeBaseProblems = @($mergeBaseQuery.Output)
    if ($mergeBaseProblems.Count -eq 0) { $mergeBaseProblems = @('unable to resolve comparison base') }
}
Write-Check -Name 'comparison base resolution' -Problems $mergeBaseProblems
if ($mergeBaseProblems.Count -ne 0) { Stop-Preflight }

$comparisonBase = $mergeBaseQuery.Output[0].Trim()
Write-Host ("INFO: base-commit={0}" -f $baseCommit)
Write-Host ("INFO: comparison-base={0}" -f $comparisonBase)
Write-Host ("INFO: head-commit={0}" -f $headCommit)

Test-PowerShellParsing -RepoRoot $repoRoot
Test-GitDiffCheck -Name 'committed branch delta git diff --check' -Revision ($comparisonBase + '..' + $headCommit)
Test-GitDiffCheck -Name 'HEAD-to-working-tree git diff --check' -Revision 'HEAD'

$trackedQuery = Invoke-GitReadOnly -Arguments @('ls-files', '--')
$inventoryProblems = @()
if ($trackedQuery.ExitCode -ne 0) {
    $inventoryProblems = @(("git ls-files exited {0}" -f $trackedQuery.ExitCode)) + @($trackedQuery.Output)
}
Write-Check -Name 'tracked-file inventory' -Problems $inventoryProblems
if ($inventoryProblems.Count -ne 0) { Stop-Preflight }

$trackedFiles = @($trackedQuery.Output | Where-Object { $_ })
Test-TrackedTextIntegrity -RepoRoot $repoRoot -TrackedFiles $trackedFiles
Test-TrackedEolPolicy -RepoRoot $repoRoot
Test-TrackedScriptAscii -RepoRoot $repoRoot

$trackedTempQuery = Invoke-GitReadOnly -Arguments @('ls-files', '--', '.codex_tmp', '.codex_tmp/**')
$trackedTempProblems = @()
if ($trackedTempQuery.ExitCode -ne 0) {
    $trackedTempProblems = @(("git ls-files for .codex_tmp exited {0}" -f $trackedTempQuery.ExitCode)) + @($trackedTempQuery.Output)
}
elseif ($trackedTempQuery.Output.Count -ne 0) { $trackedTempProblems = @($trackedTempQuery.Output) }
Write-Check -Name 'no tracked .codex_tmp artifacts' -Problems $trackedTempProblems

Write-WorkingTreeInfo -ComparisonBase $comparisonBase -HeadCommit $headCommit
Stop-Preflight
