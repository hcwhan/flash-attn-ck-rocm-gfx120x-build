# Resolve repo root (WorkspaceRoot) and build/ script root (BuildRoot).
# Dot-source from any build/<category>/*.ps1; optional -WorkspaceRoot when caller already knows it.
param(
    [string]$WorkspaceRoot = ""
)

$script:BuildRoot = Split-Path $PSScriptRoot -Parent
if ($WorkspaceRoot) {
    $script:WorkspaceRoot = $WorkspaceRoot
} else {
    $script:WorkspaceRoot = Split-Path $BuildRoot -Parent
}
