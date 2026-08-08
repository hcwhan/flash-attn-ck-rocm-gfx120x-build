param(
    [Parameter(Mandatory = $true)]
    [string]$DistDir,

    [string]$WorkspaceRoot = "",

    [string]$FaCommitSha = "",

    [string]$PythonExe = "python"
)

$ErrorActionPreference = "Stop"

if (-not $WorkspaceRoot) {
    $WorkspaceRoot = Split-Path $PSScriptRoot -Parent
}

$lockPath = Join-Path $WorkspaceRoot "VERSION.lock.json"
$expectedPattern = "flash_attn-*.whl"
$lock = $null
if (Test-Path $lockPath) {
    $lock = Get-Content $lockPath -Raw | ConvertFrom-Json
    if ($lock.expected_wheel_pattern) {
        $expectedPattern = [string]$lock.expected_wheel_pattern
    }
}

$whl = Get-ChildItem (Join-Path $DistDir "*.whl") | Select-Object -First 1
if (-not $whl) {
    throw "No wheel produced in $DistDir"
}

if ($whl.Name -notlike $expectedPattern) {
    throw "Wheel name '$($whl.Name)' does not match expected pattern '$expectedPattern'"
}

Write-Host "Wheel name OK: $($whl.Name)"

$hash = Get-FileHash -Path $whl.FullName -Algorithm SHA256
$sha256Hex = $hash.Hash.ToLowerInvariant()

$checksumPath = Join-Path $DistDir "$($whl.Name).sha256"
"$sha256Hex  $($whl.Name)" | Set-Content -Path $checksumPath -Encoding ascii

$verifyHex = (Get-FileHash -Path $whl.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
if ($verifyHex -ne $sha256Hex) {
    throw "Wheel SHA256 verification failed for $($whl.Name)"
}

$manifest = [ordered]@{
    wheel      = $whl.Name
    sha256     = $sha256Hex
    size_bytes = $whl.Length
}
if ($FaCommitSha) {
    $manifest.flash_attention_commit = $FaCommitSha
}
if ($lock) {
    if ($lock.flash_attention_build_commit) {
        $manifest.flash_attention_build_commit = [string]$lock.flash_attention_build_commit
    }
    if ($lock.flash_attention_min_commit) {
        $manifest.flash_attention_min_commit = [string]$lock.flash_attention_min_commit
    }
    if ($lock.pytorch) {
        $manifest.pytorch = [string]$lock.pytorch
    }
    if ($lock.python) {
        $manifest.python = [string]$lock.python
    }
    if ($lock.gpu_archs) {
        $manifest.gpu_archs = [string]$lock.gpu_archs
    }
}

$manifestPath = Join-Path $DistDir "wheel.manifest.json"
$manifest | ConvertTo-Json | Set-Content -Path $manifestPath -Encoding UTF8

Write-Host "Wheel SHA256: $sha256Hex"
Write-Host "Checksum file: $checksumPath"
Write-Host "Manifest file: $manifestPath"
Write-Host "CPU smoke test: import only (no GPU forward on hosted runners)"

& $PythonExe -m pip install $whl.FullName
if ($LASTEXITCODE -ne 0) {
    throw "pip install failed (exit $LASTEXITCODE)"
}

& $PythonExe -c "from flash_attn import flash_attn_func; import flash_attn_2_cuda; print('OK', flash_attn_2_cuda.__file__); print([x for x in dir(flash_attn_2_cuda) if not x.startswith('_')])"
if ($LASTEXITCODE -ne 0) {
    throw "Import smoke test failed (exit $LASTEXITCODE)"
}
