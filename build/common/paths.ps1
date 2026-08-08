# Resolve repo root (WorkspaceRoot) and build/ script root (BuildRoot).
param(
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceRoot
)

$script:BuildRoot = Split-Path $PSScriptRoot -Parent
$script:WorkspaceRoot = $WorkspaceRoot
