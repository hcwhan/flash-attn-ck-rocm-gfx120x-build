# Resolve repo root (WorkspaceRoot) and build/ script root (BuildRoot).
param(
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceRoot,

    [switch]$LoadVersionLock
)

$script:BuildRoot = Join-Path (Split-Path $PSScriptRoot -Parent) "build"
$script:WorkspaceRoot = $WorkspaceRoot

if ($LoadVersionLock) {
    . (Join-Path $PSScriptRoot "read-version-lock.ps1") -WorkspaceRoot $WorkspaceRoot
}
