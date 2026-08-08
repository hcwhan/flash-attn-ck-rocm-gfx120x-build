param(
    [string]$WorkspaceRoot = "",

    [string]$FaSrc = "C:\fa\flash-attention",

    [string]$StagingRoot = "",

    [string]$DistDir = ""
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "paths.ps1") -WorkspaceRoot $WorkspaceRoot
$WorkspaceRoot = $script:WorkspaceRoot

$dest = Join-Path $WorkspaceRoot "build-logs"
New-Item -ItemType Directory -Force -Path $dest | Out-Null

$distSource = if ($DistDir) { $DistDir } else { Join-Path $WorkspaceRoot "dist" }
if (Test-Path $distSource) {
    Copy-Item -Recurse $distSource (Join-Path $dest "dist")
    Write-Host "Collected dist from $distSource"
}

if (Test-Path "$FaSrc\build") {
    Copy-Item -Recurse "$FaSrc\build" (Join-Path $dest "fa-build")
    Write-Host "Collected fa-build from $FaSrc\build"
}

if ($StagingRoot -and (Test-Path $StagingRoot)) {
    Copy-Item -Recurse $StagingRoot (Join-Path $dest "fa-staging")
    Write-Host "Collected fa-staging from $StagingRoot"
}

Write-Host "Build logs collected under $dest"
