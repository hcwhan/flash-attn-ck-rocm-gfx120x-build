param(
    [Parameter(Mandatory = $true)]
    [string]$DistDir,

    [string]$WorkspaceRoot = "",

    [string]$PythonExe = "python"
)

$ErrorActionPreference = "Stop"

if (-not $WorkspaceRoot) {
    $WorkspaceRoot = Split-Path $PSScriptRoot -Parent
}

$lockPath = Join-Path $WorkspaceRoot "VERSION.lock.json"
$expectedPattern = "flash_attn-*.whl"
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
Write-Host "CPU smoke test: import only (no GPU forward on hosted runners)"

& $PythonExe -m pip install $whl.FullName
if ($LASTEXITCODE -ne 0) {
    throw "pip install failed (exit $LASTEXITCODE)"
}

& $PythonExe -c "from flash_attn import flash_attn_func; import flash_attn_2_cuda; print('OK', flash_attn_2_cuda.__file__); print([x for x in dir(flash_attn_2_cuda) if not x.startswith('_')])"
if ($LASTEXITCODE -ne 0) {
    throw "Import smoke test failed (exit $LASTEXITCODE)"
}
