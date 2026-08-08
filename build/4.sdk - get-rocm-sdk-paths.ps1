# Adapter for CI fingerprint: core ROCm SDK path discovery lives in
# base/get-rocm-sdk-paths.ps1 (the only implementation, shared with
# base/init-fa-build-env.ps1); this wrapper is the build/ entry point for
# 06.fa-toolchain-fingerprint so actions only reference build/.
param(
    [Parameter(Mandatory = $true)]
    [string]$PythonExe
)

$ErrorActionPreference = "Stop"

. (Join-Path (Split-Path $PSScriptRoot -Parent) "base\get-rocm-sdk-paths.ps1") -PythonExe $PythonExe
