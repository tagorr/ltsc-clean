Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-CheckLine {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][bool]$Pass
    )

    if ($Pass) {
        Write-Host ("PASS: {0}" -f $Name)
    } else {
        Write-Host ("FAIL: {0}" -f $Name)
    }
}

function Test-GitAvailable {
    $command = Get-Command git -ErrorAction SilentlyContinue
    return $null -ne $command
}

function Get-RepoRoot {
    if (Test-GitAvailable) {
        $repoRoot = & git rev-parse --show-toplevel 2>$null
        if ($LASTEXITCODE -eq 0 -and $repoRoot) {
            return $repoRoot.TrimEnd("`r", "`n").Replace('/', '\')
        }
    }

    $scriptPath = Split-Path -Parent $PSCommandPath
    return (Resolve-Path -LiteralPath (Join-Path -Path $scriptPath -ChildPath '..')).Path
}

function Get-TrackedTextFiles {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot
    )

    $extensions = @('.cmd', '.bat', '.ps1', '.md', '.txt', '.yml', '.yaml', '.xml', '.json', '.ini', '.cfg', '.reg')
    $files = New-Object System.Collections.Generic.List[string]
    $source = 'filesystem'

    if (Test-GitAvailable) {
        $tracked = & git ls-files
        if ($LASTEXITCODE -eq 0 -and $tracked) {
            foreach ($item in $tracked) {
                if (-not (Test-Path -LiteralPath $item -PathType Leaf)) {
                    continue
                }

                $ext = [System.IO.Path]::GetExtension($item).ToLowerInvariant()
                if ($extensions -contains $ext) {
                    $files.Add($item.Replace('/', '\'))
                }
            }

            $source = 'git ls-files'
        }
    }

    if ($files.Count -eq 0) {
        $all = Get-ChildItem -LiteralPath $RepoRoot -Recurse -File
        foreach ($entry in $all) {
            $ext = $entry.Extension.ToLowerInvariant()
            if ($extensions -notcontains $ext) {
                continue
            }

            $fullPath = $entry.FullName
            if ($fullPath.StartsWith($RepoRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                $relative = $fullPath.Substring($RepoRoot.Length).TrimStart('\')
                $files.Add($relative)
            }
        }
    }

    return @{
        Files  = ($files | Sort-Object -Unique)
        Source = $source
    }
}

function Test-ParseChecks {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot
    )

    $targets = @(
        '.\BootstrapLocalAdmin.ps1',
        '.\CreatePrimaryAdmin.ps1',
        '.\ValidateSecrets.ps1'
    )

    $allPass = $true

    foreach ($target in $targets) {
        $relative = $target.TrimStart('.\').Replace('/', '\')
        $fullPath = Join-Path -Path $RepoRoot -ChildPath $relative

        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
            Write-CheckLine -Name ("PS parse {0}" -f $target) -Pass $false
            Write-Host ("  {0}:0:0 file not found" -f $target)
            $allPass = $false
            continue
        }

        $tokens = $null
        $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($fullPath, [ref]$tokens, [ref]$parseErrors)

        if ($parseErrors -and $parseErrors.Count -gt 0) {
            Write-CheckLine -Name ("PS parse {0}" -f $target) -Pass $false
            foreach ($errorItem in $parseErrors) {
                $line = $errorItem.Extent.StartLineNumber
                $column = $errorItem.Extent.StartColumnNumber
                Write-Host ("  {0}:{1}:{2} {3}" -f $target, $line, $column, $errorItem.Message)
            }
            $allPass = $false
        } else {
            Write-CheckLine -Name ("PS parse {0}" -f $target) -Pass $true
        }
    }

    return $allPass
}

function Test-ReadmeAnchors {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot
    )

    $anchors = @(
        'Stage B running in recovery mode (StageA RC=',
        'Recovery mode: preserving bootstrap.pw and primaryadmin.pw for another Stage A attempt',
        'Reboot flag present in recovery mode; not rebooting to allow operator fix',
        'refusing to teardown executor/bootstrap'
    )

    $preferredFiles = @(
        'README.md',
        'DECISIONS.md',
        'SECURITY.md',
        'CreatePrimaryAdmin.ps1',
        'SetupComplete.cmd'
    ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }

    $fallbackFiles = @(
    $allTextFiles | Where-Object {
        ($preferredFiles -notcontains $_) -and
        (-not $_.StartsWith('tools\', [System.StringComparison]::OrdinalIgnoreCase)) -and
        (-not $_.StartsWith('.agents\', [System.StringComparison]::OrdinalIgnoreCase))
    }
)

    $missing = New-Object System.Collections.Generic.List[string]

    foreach ($anchor in $anchors) {
        $found = $false

        foreach ($path in $preferredFiles) {
            $content = Get-Content -LiteralPath $path -Raw -ErrorAction SilentlyContinue
            if ($content -and $content.Contains($anchor)) {
                $found = $true
                break
            }
        }

        if (-not $found) {
            foreach ($path in $fallbackFiles) {
                $content = Get-Content -LiteralPath $path -Raw -ErrorAction SilentlyContinue
                if ($content -and $content.Contains($anchor)) {
                    $found = $true
                    break
                }
            }
        }

        if (-not $found) {
            $missing.Add($anchor)
        }
    }

    if ($missing.Count -eq 0) {
        Write-CheckLine -Name 'README anchors' -Pass $true
        return $true
    }

    Write-CheckLine -Name 'README anchors' -Pass $false
    foreach ($anchor in $missing) {
        Write-Host ("  missing anchor: {0}" -f $anchor)
        Write-Host ("  searched preferred: {0}" -f (($preferredFiles | Sort-Object -Unique) -join ', '))
        Write-Host ("  searched fallback ({0} files): {1}" -f $fallbackFiles.Count, $textFilesResult.Source)
    }

    return $false
}

function Get-ChangedPathsFromPorcelainLine {
    param(
        [Parameter(Mandatory = $true)][string]$Line
    )

    if ($Line.Length -lt 4) {
        return $null
    }

    $pathPart = $Line.Substring(3)
    if ($pathPart.Contains(' -> ')) {
        $pathPart = $pathPart.Substring($pathPart.IndexOf(' -> ', [System.StringComparison]::Ordinal) + 4)
    }

    return $pathPart.Trim().Trim('"').Replace('/', '\')
}

function Test-ObservabilityGuardrail {
    $result = @{
        Pass    = $true
        Skipped = $false
        Message = $null
    }

    if (-not (Test-GitAvailable)) {
        $result.Skipped = $true
        $result.Message = 'INFO: guardrail skipped (git not available)'
        Write-Host $result.Message
        return $result
    }

    $insideWorkTree = & git rev-parse --is-inside-work-tree 2>$null
    if ($LASTEXITCODE -ne 0 -or ($insideWorkTree -join "`n").Trim() -ne 'true') {
        $result.Skipped = $true
        $result.Message = 'INFO: guardrail skipped (git work tree not available)'
        Write-Host $result.Message
        return $result
    }

    $status = & git status --porcelain=v1
    if ($LASTEXITCODE -ne 0) {
        $result.Skipped = $true
        $result.Message = 'INFO: guardrail skipped (git status unavailable)'
        Write-Host $result.Message
        return $result
    }

    if (-not $status) {
        Write-Host 'INFO: changed files: <none>'
        Write-CheckLine -Name 'observability guardrail' -Pass $true
        return $result
    }

    Write-Host 'INFO: changed files:'
    foreach ($line in $status) {
        Write-Host ("  {0}" -f $line)
    }

    $changedPaths = New-Object System.Collections.Generic.List[string]
    foreach ($line in $status) {
        $parsedPath = Get-ChangedPathsFromPorcelainLine -Line $line
        if ($parsedPath) {
            $changedPaths.Add($parsedPath)
        }
    }

    $watchFiles = @(
        'SetupComplete.cmd',
        'PreOOBE.cmd',
        'BootstrapLocalAdmin.ps1',
        'CreatePrimaryAdmin.ps1',
        'ValidateSecrets.ps1'
    )

    $changedWatched = @()
    foreach ($path in ($changedPaths | Sort-Object -Unique)) {
        $leaf = Split-Path -Leaf $path
        if (($watchFiles -contains $path) -or ($watchFiles -contains $leaf)) {
            $changedWatched += $leaf
        }
    }
    $changedWatched = @($changedWatched | Sort-Object -Unique)

    if ($changedWatched.Count -eq 0) {
        Write-CheckLine -Name 'observability guardrail' -Pass $true
        return $result
    }

    $diffArgs = @('diff', '--')
    foreach ($item in $changedWatched) {
        $diffArgs += $item
    }

    $diffOutputUnstaged = & git @diffArgs
    if ($LASTEXITCODE -ne 0) {
        $result.Pass = $false
        Write-CheckLine -Name 'observability guardrail' -Pass $false
        Write-Host '  potential flow-control changes in monitored files (diff unavailable)'
        return $result
    }

    $diffArgsCached = @('diff', '--cached', '--')
    foreach ($item in $changedWatched) {
        $diffArgsCached += $item
    }

    $diffOutputStaged = & git @diffArgsCached
    if ($LASTEXITCODE -ne 0) {
        $result.Pass = $false
        Write-CheckLine -Name 'observability guardrail' -Pass $false
        Write-Host '  potential flow-control changes in monitored files (diff unavailable)'
        return $result
    }

    $diffOutput = @()
    if ($diffOutputUnstaged) { $diffOutput += $diffOutputUnstaged }
    if ($diffOutputStaged) { $diffOutput += $diffOutputStaged }

    $detected = New-Object System.Collections.Generic.List[string]
    $currentFile = $null
    $currentExt = $null

    $cmdPatterns = @(
        @{ Name = 'if errorlevel'; Regex = '^if\s+errorlevel\b' },
        @{ Name = 'if';           Regex = '^if\b' },
        @{ Name = 'goto';         Regex = '^goto\b' },
        @{ Name = 'exit /b';      Regex = '^exit\s+/b\b' }
    )

    $psPatterns = @(
        @{ Name = 'if/elseif/else'; Regex = '^(if|elseif|else)\b' },
        @{ Name = 'return/throw/break/continue'; Regex = '^(return|throw|break|continue)\b' },
        @{ Name = 'switch'; Regex = '^switch\b' },
        @{ Name = 'try';    Regex = '^try\b' },
        @{ Name = 'catch';  Regex = '^catch\b' }
    )

    foreach ($line in $diffOutput) {
        if ($line.StartsWith('diff --git ')) {
            if ($line -match '^diff --git a\/.+? b\/(.+)$') {
                $currentFile = $Matches[1].Replace('/', '\')
                $currentExt = [System.IO.Path]::GetExtension($currentFile).ToLowerInvariant()
            } else {
                $currentFile = $null
                $currentExt = $null
            }
            continue
        }

        if ($line.StartsWith('+++') -or $line.StartsWith('---')) {
            continue
        }
        if ($line.StartsWith('@@')) {
            continue
        }

        if ($line.StartsWith('+') -or $line.StartsWith('-')) {
            if (-not $currentExt) {
                continue
            }

            $contentText = $line.Substring(1)
            $trimmed = $contentText.TrimStart()
            $trimmedLower = $trimmed.ToLowerInvariant()

            $isCmd = ($currentExt -eq '.cmd' -or $currentExt -eq '.bat')
            $isPs1 = ($currentExt -eq '.ps1')
            if (-not $isCmd -and -not $isPs1) {
                continue
            }

            if ($isCmd) {
                if ($trimmedLower -eq 'rem' -or $trimmedLower.StartsWith('rem ')) { continue }
                if ($trimmedLower.StartsWith('::')) { continue }
                if ($trimmedLower -eq 'echo' -or $trimmedLower.StartsWith('echo ')) { continue }

                foreach ($pattern in $cmdPatterns) {
                    if ($trimmedLower -match $pattern.Regex) {
                        $detected.Add(("cmd:{0}" -f $pattern.Name))
                        break
                    }
                }
            } else {
                if ($trimmedLower.StartsWith('<#')) { continue }
				if ($trimmedLower.StartsWith('#')) { continue }
                if ($trimmedLower.StartsWith('write-host')) { continue }
                if ($trimmedLower.StartsWith('write-setuplog')) { continue }

                foreach ($pattern in $psPatterns) {
                    if ($trimmedLower -match $pattern.Regex) {
                        $detected.Add(("ps:{0}" -f $pattern.Name))
                        break
                    }
                }
            }
        }
    }

    if ($detected.Count -gt 0) {
        $result.Pass = $false
        Write-CheckLine -Name 'observability guardrail' -Pass $false
        Write-Host ("  potential flow-control edits detected in: {0}" -f ($changedWatched -join ', '))
        Write-Host ("  keyword hits: {0}" -f (($detected | Sort-Object -Unique) -join ', '))
    } else {
        Write-CheckLine -Name 'observability guardrail' -Pass $true
    }

    return $result
}

$repoRoot = Get-RepoRoot
Set-Location -LiteralPath $repoRoot

$check1Pass = Test-ParseChecks -RepoRoot $repoRoot
$check2Pass = Test-ReadmeAnchors -RepoRoot $repoRoot
$check3 = Test-ObservabilityGuardrail

Write-Host 'Summary:'
Write-Host ("Check 1: {0}" -f ($(if ($check1Pass) { 'PASS' } else { 'FAIL' })))
Write-Host ("Check 2: {0}" -f ($(if ($check2Pass) { 'PASS' } else { 'FAIL' })))

if ($check3.Skipped) {
    Write-Host ("Check 3: PASS ({0})" -f $check3.Message)
} else {
    Write-Host ("Check 3: {0}" -f ($(if ($check3.Pass) { 'PASS' } else { 'FAIL' })))
}

if ($check1Pass -and $check2Pass -and $check3.Pass) {
    exit 0
}

exit 1
