param(
    [Parameter(Mandatory = $true)]
    [string]$DistDir,

    [Parameter(Mandatory = $true)]
    [string]$WorkspaceRoot,

    [Parameter(Mandatory = $true)]
    [string]$WorkflowName,

    [string]$ReleaseVariant = ""
)

$ErrorActionPreference = "Stop"

if (-not $env:RELEASE_TAG_PREFIX) {
    . (Join-Path $WorkspaceRoot "base\read-version-lock.ps1") -WorkspaceRoot $WorkspaceRoot
    $env:RELEASE_TAG_PREFIX = $RELEASE_TAG_PREFIX
    $env:RELEASE_NAME = $RELEASE_NAME
    $env:RELEASE_PRERELEASE = $RELEASE_PRERELEASE
}

$whls = @(Get-ChildItem (Join-Path $DistDir "*.whl") -File)
if ($whls.Count -ne 1) {
    throw "Expected exactly one wheel in $DistDir for release, found $($whls.Count)"
}
$whl = $whls[0]

$variantSlug = ""
if ($ReleaseVariant) {
    $variantSlug = ($ReleaseVariant.ToLower() -replace '[^a-z0-9]+', '-').Trim('-')
    if (-not $variantSlug) {
        throw "ReleaseVariant '$ReleaseVariant' did not produce a valid slug"
    }
}

if ($variantSlug) {
    $tag = "$($env:RELEASE_TAG_PREFIX)-$variantSlug-build$($env:GITHUB_RUN_NUMBER)"
    $displayName = "$($env:RELEASE_NAME) ($ReleaseVariant)"
} else {
    $tag = "$($env:RELEASE_TAG_PREFIX)-build$($env:GITHUB_RUN_NUMBER)"
    $displayName = $env:RELEASE_NAME
}
$releaseTitle = "$displayName (build $($env:GITHUB_RUN_NUMBER))"
$bodyPath = Join-Path $env:RUNNER_TEMP "release-body.md"

$manifestPath = Join-Path $DistDir "wheel.manifest.json"
$manifestBlock = ""
if (Test-Path $manifestPath) {
    $manifestBlock = @"

### wheel.manifest.json

```json
$(Get-Content $manifestPath -Raw)
```
"@
}

$body = @"
## $($env:RELEASE_NAME)

| 项 | 值 |
|----|-----|
| Workflow | $WorkflowName |
| Build source | $(if ($ReleaseVariant) { $ReleaseVariant } else { 'default' }) |
| Run | $($env:GITHUB_RUN_NUMBER) |
| Repository commit | $($env:GITHUB_SHA) |
| Wheel | $($whl.Name) |

$manifestBlock
"@

Set-Content -Path $bodyPath -Value $body -Encoding utf8

if (-not $env:GITHUB_OUTPUT) {
    throw "GITHUB_OUTPUT is not set"
}
"tag=$tag" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
"body_path=$bodyPath" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
"prerelease=$($env:RELEASE_PRERELEASE)" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
"release_name=$displayName" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
"release_title=$releaseTitle" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8

Write-Host "Release tag: $tag"
Write-Host "Release body: $bodyPath"
