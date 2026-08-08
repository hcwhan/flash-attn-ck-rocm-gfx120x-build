# Resolve repo root (WorkspaceRoot) and build/ script root (BuildRoot).
param(
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceRoot,

    [switch]$LoadVersionLock
)

$script:BuildRoot = Split-Path $PSScriptRoot -Parent
$script:WorkspaceRoot = $WorkspaceRoot

if ($LoadVersionLock) {
    . (Join-Path $script:BuildRoot "config\read-version-lock.ps1") -WorkspaceRoot $WorkspaceRoot
}
