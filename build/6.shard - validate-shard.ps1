# Resolve flash-attention build/temp.win-*/Release after build_ext (single CI compile tree).
param(
    [Parameter(Mandatory = $true)]
    [string]$FaSrc,

    [Parameter(Mandatory = $true)]
    [string]$OptDim
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

$dimToken = "_d${OptDim}_"
$objCount = 0
$dimKernelCount = 0

Get-ChildItem -Path $releaseDir -Recurse -Filter "*.obj" -File |
    ForEach-Object {
        $objCount++
        if ($_.Name -like "*${dimToken}*") {
            $dimKernelCount++
        }
    }

if ($objCount -lt 1) {
    throw "No .obj files under $releaseDir"
}
if ($dimKernelCount -lt 1) {
    throw "No *_d${OptDim}_* kernel objects under $releaseDir"
}
foreach ($required in @('.ninja_log', '.ninja_deps')) {
    if (-not (Test-Path (Join-Path $releaseDir $required))) {
        throw "Release dir missing $required: $releaseDir (upload-artifact must set include-hidden-files: true)"
    }
}

Write-Host "Release dir: $releaseDir ($objCount objs, $dimKernelCount dim-kernel)"
return $releaseDir
