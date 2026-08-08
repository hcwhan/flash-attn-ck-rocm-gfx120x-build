# Resolve flash-attention build/temp.win-*/Release after build_ext (single CI compile tree).
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

$candidates = @(Get-ChildItem -Path $buildDir -Directory -Filter "temp.win-*")
if ($candidates.Count -ne 1) {
    throw "Expected exactly one build/temp.win-* directory under $buildDir, found $($candidates.Count)"
}

$releaseDir = Join-Path $candidates[0].FullName "Release"
if (-not (Test-Path $releaseDir)) {
    throw "Release directory missing: $releaseDir"
}

$dimToken = if ($OptDim) { "_d${OptDim}_" } else { $null }
$objCount = 0
$dimKernelCount = 0

Get-ChildItem -Path $releaseDir -Recurse -Filter "*.obj" -File |
    ForEach-Object {
        $objCount++
        if ($dimToken -and $_.Name -like "*${dimToken}*") {
            $dimKernelCount++
        }
    }

if ($objCount -lt 1) {
    throw "No .obj files under $releaseDir"
}
if ($dimToken -and $dimKernelCount -lt 1) {
    throw "No *_d${OptDim}_* kernel objects under $releaseDir"
}

$result = [PSCustomObject]@{
    TempRoot       = $candidates[0].FullName
    ReleaseDir     = $releaseDir
    ObjCount       = $objCount
    DimKernelCount = $dimKernelCount
}

Write-Host (
    "Release dir: $($result.ReleaseDir) " +
    "($($result.ObjCount) objs, $($result.DimKernelCount) dim-kernel)"
)

if ($PassThru) {
    return $result
}

return $result.ReleaseDir
