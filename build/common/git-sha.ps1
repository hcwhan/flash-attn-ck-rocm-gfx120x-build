# Normalize git commit SHAs to lowercase full 40-char hex for strict comparison.
function Normalize-GitSha {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Sha,

        [string]$RepoRoot = ""
    )

    $trimmed = $Sha.Trim()
    if (-not ($trimmed -match '^[0-9a-fA-F]{7,40}$')) {
        throw "Invalid git commit SHA: $Sha"
    }

    if ($RepoRoot -and (Test-Path (Join-Path $RepoRoot ".git"))) {
        $resolved = (git -C $RepoRoot rev-parse $trimmed 2>$null)
        if ($LASTEXITCODE -eq 0 -and $resolved) {
            return $resolved.Trim().ToLowerInvariant()
        }
    }

    if ($trimmed.Length -eq 40) {
        return $trimmed.ToLowerInvariant()
    }

    throw "Cannot normalize short SHA without a git repo: $Sha"
}

function Test-GitShaEqual {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Left,

        [Parameter(Mandatory = $true)]
        [string]$Right,

        [string]$RepoRoot = ""
    )

    if (-not $Left -or -not $Right) {
        return $false
    }

    try {
        $leftNorm = Normalize-GitSha -Sha $Left -RepoRoot $RepoRoot
        $rightNorm = Normalize-GitSha -Sha $Right -RepoRoot $RepoRoot
        return ($leftNorm -eq $rightNorm)
    } catch {
        throw "Git SHA comparison failed (Left='$Left', Right='$Right'): $($_.Exception.Message)"
    }
}
