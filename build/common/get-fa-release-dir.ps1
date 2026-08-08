# Resolve flash-attention build/temp.win-*/Release after build_ext.
# When -OptDim is set, prefers the tree with the most *_d{OptDim}_* kernel objs.
param(
    [Parameter(Mandatory = $true)]
    [string]$FaSrc,

    [string]$OptDim = "",

    [switch]$PassThru
)

$ErrorActionPreference = "Stop"

$buildDir = Join-Path $FaSrc "build"
if (-not (Test-Path $buildDir)) {
    throw "flash-attention build directory missing: $buildDir"
}

$candidates = @(Get-ChildItem -Path $buildDir -Directory -Filter "temp.win-*" -ErrorAction SilentlyContinue)
if ($candidates.Count -lt 1) {
    throw "No build/temp.win-* directory under $buildDir"
}

$dimToken = if ($OptDim) { "_d${OptDim}_" } else { $null }

function Get-ReleaseDirStats {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ReleaseDir,

        [string]$DimToken
    )

    $objCount = 0
    $dimKernelCount = 0
    $latestUtc = [datetime]::MinValue

    Get-ChildItem -Path $ReleaseDir -Recurse -Filter "*.obj" -File -ErrorAction SilentlyContinue |
        ForEach-Object {
            $objCount++
            if ($_.LastWriteTimeUtc -gt $latestUtc) {
                $latestUtc = $_.LastWriteTimeUtc
            }

            if ($DimToken) {
                if ($_.Name -like "*${DimToken}*") {
                    $dimKernelCount++
                }
            } elseif ($_.Name -match '_d\d+_') {
                $dimKernelCount++
            }
        }

    return [PSCustomObject]@{
        ObjCount       = $objCount
        DimKernelCount = $dimKernelCount
        LatestObjUtc   = $latestUtc
    }
}

$ranked = foreach ($tempRoot in $candidates) {
    $releaseDir = Join-Path $tempRoot.FullName "Release"
    if (-not (Test-Path $releaseDir)) {
        continue
    }

    $stats = Get-ReleaseDirStats -ReleaseDir $releaseDir -DimToken $dimToken
    if ($stats.ObjCount -lt 1) {
        continue
    }
    if ($DimToken -and $stats.DimKernelCount -lt 1) {
        continue
    }

    $scoreObjCount = if ($DimToken) { $stats.DimKernelCount } else { $stats.ObjCount }

    [PSCustomObject]@{
        TempRoot       = $tempRoot.FullName
        ReleaseDir     = $releaseDir
        ObjCount       = $stats.ObjCount
        DimKernelCount = $stats.DimKernelCount
        ScoreObjCount  = $scoreObjCount
        LatestObjUtc   = $stats.LatestObjUtc
    }
}

$best = @(
    $ranked |
        Sort-Object ScoreObjCount, LatestObjUtc, TempRoot -Descending |
        Select-Object -First 1
)
if ($best.Count -lt 1) {
    $hint = if ($DimToken) { " with *_d${OptDim}_* kernel objs" } else { "" }
    throw "No temp.win-*/Release directory with .obj files$hint under $buildDir"
}

Write-Host (
    "Selected Release dir: $($best[0].ReleaseDir) " +
    "($($best[0].ObjCount) objs, $($best[0].DimKernelCount) dim-kernel, temp=$($best[0].TempRoot))"
)

if ($PassThru) {
    return $best[0]
}

return $best[0].ReleaseDir
