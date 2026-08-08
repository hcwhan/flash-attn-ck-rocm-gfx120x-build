# Resolve ROCm SDK core/devel roots from the installed torch + rocm_sdk packages.
# Single implementation shared by init-fa-build-env.ps1 and fa-toolchain-fingerprint.
# Dot-source only; emits $script:CoreRoot (llvm/compiler tree) and $script:DevelRoot.
param(
    [Parameter(Mandatory = $true)]
    [string]$PythonExe
)

$ErrorActionPreference = "Stop"

$pyCode = @"
import importlib.util, os, subprocess, sys

spec = importlib.util.find_spec('_rocm_sdk_core')
if spec is None:
    raise SystemExit('ERROR: _rocm_sdk_core not found. Install torch[device-...] first.')
core_root = os.path.dirname(spec.origin)

proc = subprocess.run(
    [sys.executable, '-m', 'rocm_sdk', 'path', '--root'],
    capture_output=True,
    text=True,
    check=True,
)
devel_root = proc.stdout.strip()

print(f'CORE_ROOT={core_root}')
print(f'DEVEL_ROOT={devel_root}')
"@

$paths = & $PythonExe -c $pyCode
if ($LASTEXITCODE -ne 0) {
    throw "Failed to locate ROCm SDK paths via $PythonExe"
}

$coreRootLine = $paths | Where-Object { $_ -like 'CORE_ROOT=*' } | Select-Object -First 1
$develRootLine = $paths | Where-Object { $_ -like 'DEVEL_ROOT=*' } | Select-Object -First 1
if (-not $coreRootLine -or -not $develRootLine) {
    throw "Failed to parse ROCm SDK paths from $PythonExe output"
}
$script:CoreRoot = $coreRootLine.Substring('CORE_ROOT='.Length)
$script:DevelRoot = $develRootLine.Substring('DEVEL_ROOT='.Length)
