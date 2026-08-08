# Adapter for CI env export: core lock read lives in base/read-version-lock.ps1
# (the only script that reads VERSION.lock.json directly); this wrapper adds the
# -ExportToGitHubEnv GITHUB_ENV emission used by fa-read-version-lock.
param(
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceRoot,

    [switch]$ExportToGitHubEnv
)

$ErrorActionPreference = "Stop"

. (Join-Path (Split-Path $PSScriptRoot -Parent) "base\read-version-lock.ps1") -WorkspaceRoot $WorkspaceRoot

if ($ExportToGitHubEnv -and $env:GITHUB_ENV) {
    foreach ($name in $VersionLockVars.Keys) {
        "${name}=$($VersionLockVars[$name])" | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8
    }
}
