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
    $scriptDir = Split-Path -Parent $PSCommandPath

    if (Test-GitAvailable) {
        $repoRoot = & git -C $scriptDir rev-parse --show-toplevel 2>$null
        if ($LASTEXITCODE -eq 0 -and $repoRoot) {
            $candidate = $repoRoot.TrimEnd("`r", "`n").Replace('/', '\').TrimEnd('\')
            $scriptFullPath = (Resolve-Path -LiteralPath $PSCommandPath).Path

            $isAncestor = $scriptFullPath.StartsWith(($candidate + '\'), [System.StringComparison]::OrdinalIgnoreCase)
            $expectedScriptPath = Join-Path -Path $candidate -ChildPath 'tools\preflight.ps1'
            $isExpectedScript = $false
            if (Test-Path -LiteralPath $expectedScriptPath -PathType Leaf) {
                $resolvedExpected = (Resolve-Path -LiteralPath $expectedScriptPath).Path
                if ($resolvedExpected.Equals($scriptFullPath, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $isExpectedScript = $true
                }
            }

            if ($isAncestor -or $isExpectedScript) {
                return $candidate
            }
        }
    }

    return (Resolve-Path -LiteralPath (Join-Path -Path $scriptDir -ChildPath '..')).Path
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
        $excludeDirs = @('.git', '.codex_tmp', '.agents', 'tools')
        $queue = New-Object System.Collections.Generic.Queue[string]
        $queue.Enqueue($RepoRoot)

        while ($queue.Count -gt 0) {
            $dir = $queue.Dequeue()

            $childDirs = Get-ChildItem -LiteralPath $dir -Directory -ErrorAction SilentlyContinue
            foreach ($childDir in $childDirs) {
                $skip = $false
                foreach ($ex in $excludeDirs) {
                    if ($childDir.Name.Equals($ex, [System.StringComparison]::OrdinalIgnoreCase)) {
                        $skip = $true
                        break
                    }
                }

                if (-not $skip) {
                    $queue.Enqueue($childDir.FullName)
                }
            }

            $dirFiles = Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue
            foreach ($entry in $dirFiles) {
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

    $runtimeSources = @(
        'CreatePrimaryAdmin.ps1',
        'SetupComplete.cmd'
    ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }

    $docsSources = @(
        'README.md',
        'DECISIONS.md',
        'SECURITY.md'
    ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }

    $textFilesResult = Get-TrackedTextFiles -RepoRoot $RepoRoot
    $allTextFiles = @($textFilesResult.Files)

    $fallbackFiles = @(
    $allTextFiles | Where-Object {
        ($preferredFiles -notcontains $_) -and
        (-not $_.StartsWith('tools\', [System.StringComparison]::OrdinalIgnoreCase)) -and
        (-not $_.StartsWith('.agents\', [System.StringComparison]::OrdinalIgnoreCase))
    }
)

    $missing = New-Object System.Collections.Generic.List[string]
    $docsOnly = New-Object System.Collections.Generic.List[string]
    $outsideRuntime = New-Object System.Collections.Generic.List[string]

    foreach ($anchor in $anchors) {
        $foundInRuntime = $false
        $foundInDocs = $false
        $foundInFallback = $false

        foreach ($path in $runtimeSources) {
            $content = Get-Content -LiteralPath $path -Raw -ErrorAction SilentlyContinue
            if ($content -and $content.Contains($anchor)) {
                $foundInRuntime = $true
                break
            }
        }

        if (-not $foundInRuntime) {
            foreach ($path in $docsSources) {
                $content = Get-Content -LiteralPath $path -Raw -ErrorAction SilentlyContinue
                if ($content -and $content.Contains($anchor)) {
                    $foundInDocs = $true
                    break
                }
            }
        }

        if (-not $foundInRuntime -and -not $foundInDocs) {
            foreach ($path in $fallbackFiles) {
                $content = Get-Content -LiteralPath $path -Raw -ErrorAction SilentlyContinue
                if ($content -and $content.Contains($anchor)) {
                    $foundInFallback = $true
                    break
                }
            }
        }

        if ($foundInRuntime) {
            continue
        }

        if ($foundInDocs) {
            $docsOnly.Add($anchor)
            continue
        }

        if ($foundInFallback) {
            $outsideRuntime.Add($anchor)
            continue
        }

        $missing.Add($anchor)
    }

    if ($missing.Count -eq 0 -and $docsOnly.Count -eq 0 -and $outsideRuntime.Count -eq 0) {
        Write-CheckLine -Name 'README anchors' -Pass $true
        return $true
    }

    Write-CheckLine -Name 'README anchors' -Pass $false
    foreach ($anchor in $docsOnly) {
        Write-Host ("  anchor found only in docs: {0}" -f $anchor)
        Write-Host ("  searched preferred: {0}" -f (($preferredFiles | Sort-Object -Unique) -join ', '))
        Write-Host ("  searched fallback ({0} files): {1}" -f $fallbackFiles.Count, $textFilesResult.Source)
    }

    foreach ($anchor in $outsideRuntime) {
        Write-Host ("  anchor not found in runtime sources: {0}" -f $anchor)
        Write-Host ("  searched preferred: {0}" -f (($preferredFiles | Sort-Object -Unique) -join ', '))
        Write-Host ("  searched fallback ({0} files): {1}" -f $fallbackFiles.Count, $textFilesResult.Source)
    }

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

    $pathPart = $Line.Substring(3).Trim()
    if (-not $pathPart) {
        return $null
    }

    if ($pathPart.Contains(' -> ')) {
        $parts = $pathPart.Split(@(' -> '), 2, [System.StringSplitOptions]::None)
        $oldPath = $parts[0].Trim().Trim('"').Replace('\', '/')
        $newPath = $parts[1].Trim().Trim('"').Replace('\', '/')
        return @{
            OldPath = $oldPath
            NewPath = $newPath
            Paths   = @($oldPath, $newPath)
        }
    }

    $single = $pathPart.Trim('"').Replace('\', '/')
    return @{
        OldPath = $null
        NewPath = $single
        Paths   = @($single)
    }
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

    $watchFiles = @(
        'SetupComplete.cmd',
        'PreOOBE.cmd',
        'BootstrapLocalAdmin.ps1',
        'CreatePrimaryAdmin.ps1',
        'ValidateSecrets.ps1'
    )

    $changedWatchedPathspecs = New-Object System.Collections.Generic.List[string]
    foreach ($line in $status) {
        $parsed = Get-ChangedPathsFromPorcelainLine -Line $line
        if (-not $parsed) {
            continue
        }

        $paths = @($parsed.Paths)
        if (-not $paths -or $paths.Count -eq 0) {
            continue
        }

        $isWatched = $false
        foreach ($p in $paths) {
            $display = $p.Replace('/', '\')
            $leaf = Split-Path -Leaf $display
            if (($watchFiles -contains $display) -or ($watchFiles -contains $leaf)) {
                $isWatched = $true
                break
            }
        }

        if (-not $isWatched) {
            continue
        }

        if ($parsed.NewPath) {
            $changedWatchedPathspecs.Add($parsed.NewPath)
        }
        if ($parsed.OldPath) {
            $changedWatchedPathspecs.Add($parsed.OldPath)
        }
    }
    $changedWatchedPathspecs = @($changedWatchedPathspecs | Sort-Object -Unique)
    $changedWatchedDisplay = @($changedWatchedPathspecs | ForEach-Object { $_.Replace('/', '\') })

    if ($changedWatchedPathspecs.Count -eq 0) {
        Write-CheckLine -Name 'observability guardrail' -Pass $true
        return $result
    }

    $diffArgs = @('diff', '--')
    foreach ($item in $changedWatchedPathspecs) {
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
    foreach ($item in $changedWatchedPathspecs) {
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
    $psInBlockComment = $false
    $psHereTerminator = $null

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
            $psInBlockComment = $false
            $psHereTerminator = $null

            $bIndex = $line.IndexOf(' b/', [System.StringComparison]::Ordinal)
            if ($bIndex -ge 0) {
                $pathPart = $line.Substring($bIndex + 3).Trim()
                if ($pathPart.StartsWith('"') -and $pathPart.EndsWith('"') -and $pathPart.Length -ge 2) {
                    $pathPart = $pathPart.Substring(1, $pathPart.Length - 2)
                }
                $pathPart = $pathPart.Replace('\ ', ' ')

                $currentFile = $pathPart.Replace('/', '\')
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
                $trimmedCmd = $trimmed
                if ($trimmedCmd.StartsWith('@')) {
                    $trimmedCmd = $trimmedCmd.Substring(1).TrimStart()
                }
                $trimmedLowerCmd = $trimmedCmd.ToLowerInvariant()

                if ($trimmedLowerCmd -eq 'rem' -or $trimmedLowerCmd.StartsWith('rem ')) { continue }
                if ($trimmedLowerCmd.StartsWith('::')) { continue }
                if ($trimmedLowerCmd -eq 'echo' -or $trimmedLowerCmd.StartsWith('echo ')) { continue }

                foreach ($pattern in $cmdPatterns) {
                    if ($trimmedLowerCmd -match $pattern.Regex) {
                        $detected.Add(("cmd:{0}" -f $pattern.Name))
                        break
                    }
                }
            } else {
                if (-not $psInBlockComment -and $trimmed.Contains('<#')) { $psInBlockComment = $true }
                if ($psInBlockComment) {
                    if ($trimmed.Contains('#>')) { $psInBlockComment = $false }
                    continue
                }

                if (-not $psHereTerminator) {
                    if ($trimmed -eq '@"') { $psHereTerminator = '"@'; continue }
                    if ($trimmed -eq "@'") { $psHereTerminator = "'@"; continue }
                } else {
                    if ($trimmed -eq $psHereTerminator) { $psHereTerminator = $null }
                    continue
                }

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
        Write-Host ("  potential flow-control edits detected in: {0}" -f ($changedWatchedDisplay -join ', '))
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
